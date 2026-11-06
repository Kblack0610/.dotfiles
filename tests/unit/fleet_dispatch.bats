#!/usr/bin/env bats
# fleet-dispatch: which rows may start an unattended session, and the bookkeeping around it.
# Everything that could launch, claim or judge is a stub; calls.log records what it would do.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_DISPATCH_DIR="$HOME/.agent/dispatch"
  sandbox_worlds
  export DISPATCH_PROFILES=bnb
  export DISPATCH_PROJECT_MAP="$SANDBOX/map.json"
  export DISPATCH_POLICY="$SANDBOX/policy.md"
  export DISPATCH_WORKERS="$SANDBOX/workers.json"
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  export DISPATCH_LOADAVG="$SANDBOX/loadavg"
  export DISPATCH_JUDGE_CMD=judge-stub   # on PATH: the command is a word list, and the sandbox path has a space
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  printf '%s\n' 'policy' '- (fits) dispatch' '- (tier3) tier 3' '- (unclear) not clear' > "$DISPATCH_POLICY"
  mkdir -p "$SANDBOX/repos/game" "$SANDBOX/repos/app" "$SANDBOX/sheets"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub_notes
  stub agent-hold 'exit 0'
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  stub fleet-presence 'echo "away 45 tmux"'
  stub fleet-bench 'exit 0'
  stub top 'printf "%%Cpu(s):  1.0 us,  1.0 sy,  0.0 ni, 98.0 id,  0.0 wa\n%%Cpu(s):  5.0 us,  5.0 sy,  0.0 ni, 90.0 id,  0.0 wa\n"'
  stub fleet-shepherd 'exit 1'
  stub claude-acct 'exit 0'   # main account; a test that wants the alt one restubs it
  stub model-lane 'echo "{\"dispatch_model\":\"opus\"}"'
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  stub judge-stub 'echo "judge called" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  # The real agent-queue, copied (never linked: a test that restubs it must not write through).
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  # The ladder `notes projects --stages` prints; the stub answers projects lists only.
  export LAB_STAGES="draft dev alpha beta prod"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$DISPATCH_PROJECT_MAP" AGENT_QUEUE_START=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# started_item <slug> <session> [origin] [area] [from] [state] [project] -- a started queue item on
# that session (<server>:<name>): the one record of a running session.
started_item() {
  local d="$AGENT_QUEUE_DIR/${6:-running}"; mkdir -p "$d"
  {
    printf 'slug: %s\nproject: %s\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n' "$1" "${7:-game}" "${5:-human}"
    printf 'started: 2026-11-03T10:00:00Z\nsession: %s\n' "$2"
    [ -z "${3:-}" ] || printf 'origin: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'area: %s\n' "$4"
    [[ "${5:-}" != board:* ]] || printf 'lane: human\nprofile: bnb\n'
    printf -- '---\n%s\n' "$1"
  } > "$d/20261103-100000-$1.md"
}

# A notes stand-in with state: rows.<project>.<lane> holds "key<TAB>raw line". `start` sets one
# row to [/] and `unstart` back to [ ], as the real CLI does, and a row already there is left
# unchanged: the row whose line is the query under --exact, else the one with that id, else the
# first whose key contains it. A row going to [/] with no id gets the next gm-N and the id goes
# out on its own line, unless the fixture says the project has no code (nocode.<project>).
stub_notes() {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
F="$NOTES_FIXTURE"; printf 'notes %s\n' "$*" >> "$F/calls.log"
args=(); lane=human; exact=0
while [ $# -gt 0 ]; do
  case "$1" in --profile) shift 2 ;; --agent) lane=agent; shift ;; --exact) exact=1; shift ;; --) shift ;; *) args+=("$1"); shift ;; esac
done
case "${args[0]}" in
  projects) cat "$F/projects" 2>/dev/null ;;
  ptask)
    p="${args[1]}"; f="$F/rows.$p.$lane"; [ -f "$f" ] || exit 0
    case "${args[2]}" in
      list) awk -F'\t' -v f="$f" '$2 ~ /^- \[[ \/]\]/ { print f "\t" NR "\t" $1 "\t" $2 }' "$f" ;;
      start|unstart)
        n=$(cat "$F"/rows.*.* | grep -c 'id:gm-'); [ ! -f "$F/nocode.$p" ] || n=''
        Q="${args[3]}" awk -F'\t' -v OFS='\t' -v exact="$exact" -v n="$n" -v out="$f.out" -v verb="${args[2]}" '
          BEGIN { q = ENVIRON["Q"] }
          !done && $2 ~ /^- \[[ \/]\]/ && (exact ? $2 == q : (index($2, "id:" q " ") || index($1, q))) {
            done = 1
            if (verb == "unstart") {
              if (sub(/^- \[\/\]/, "- [ ]", $2)) print "unstarted " $2 > out; else print "unchanged " $2 > out
            } else if ($2 ~ /^- \[\/\]/) print "unchanged " $2 > out
            else {
              sub(/^- \[ \]/, "- [/]", $2); print "started " $2 > out
              if (n != "" && $2 !~ /id:/) { id = "gm-" (n + 1); $2 = $2 " <!-- id:" id " -->"; print "  id:" id > out }
            }
          }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f"
        [ -f "$f.out" ] || { echo "no open task matches" >&2; exit 1; }
        cat "$f.out"; rm -f "$f.out" ;;
    esac ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
}

# project <name> <stage> <repo-dir|-> : a project dir, a registry entry, and a projects line. The
# stage sits on README.md while the listing names summary.md, the shape `notes projects` prints for
# a profile whose index links the summary (bnb): the reader must find the front page itself.
project() {
  mkdir -p "$SANDBOX/sheets/$1"
  printf 'Version: v1.0.0 #%s\n' "$2" > "$SANDBOX/sheets/$1/README.md"
  printf '# %s\n' "$1" > "$SANDBOX/sheets/$1/summary.md"
  printf '%s\t%s\t\tv1.0.0\n' "$1" "$SANDBOX/sheets/$1/summary.md" >> "$NOTES_FIXTURE/projects"
  local m='{"trackers":{},"paths":{}}'; [ -f "$DISPATCH_PROJECT_MAP" ] && m=$(cat "$DISPATCH_PROJECT_MAP")
  if [ "$3" = - ]; then
    jq --arg p "$1" '.trackers[$p] = {repo: null}' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  else
    jq --arg p "$1" --arg d "$3" '.trackers[$p] = {repo: $p} | .paths[$d] = $p' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  fi
}

row() { printf '%s\t%s\n' "$3" "$4" >> "$NOTES_FIXTURE/rows.$1.$2"; }

# A tagged row the fleet worker may take.
T='#worker/fleet #tier/1'

# line_of <project> <lane> <key> -> the line signature of that fixture row, as candidates computes it
# (nothing when there is no such row, as for the synthetic candidates the picks tests build).
line_of() {
  local text
  text=$(awk -F'\t' -v k="$3" '$1 == k { print $2; exit }' "$NOTES_FIXTURE/rows.$1.$2" 2>/dev/null)
  [ -z "$text" ] || printf '%s' "$text" | sig
}

# verdict <project> <lane> <key> <verdict> [size] [tier] [area] -- made under the current policy for the row's current text
verdict() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg p "$1" --arg l "$2" --arg k "$3" --arg v "$4" --arg s "${5:-S}" --argjson t "${6:-1}" \
    --arg sig "$(policy_sig)" --arg line "$(line_of "$1" "$2" "$3")" --arg a "${7-$3}" \
    '{project: $p, lane: $l, key: $k, verdict: $v, size: $s, tier: $t, area: $a, clear: true, agent_only: true,
      reason: "r", policy: $sig, line: $line}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

# --- candidates --------------------------------------------------------------------------

@test "candidates: draft and notes-only projects, started rows and judged rows are left out" {
  project game beta "$SANDBOX/repos/game"
  project idea draft "$SANDBOX/repos/app"
  project notesonly prod -
  row game human 'fix crash' "- [ ] fix crash #high $T"
  row game human 'taken row' "- [/] taken row $T"
  row game agent 'judged row' "- [ ] judged row $T"
  row idea human 'draft row' "- [ ] draft row $T"
  row notesonly human 'paper row' "- [ ] paper row $T"
  verdict game agent 'judged row' skip

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
  assert_equal "$(jq -r '"\(.stage) \(.lane) \(.prio) \(.tier) \(.repo)"' <<<"$output")" "beta human 1 1 $SANDBOX/repos/game"
}

@test "candidates: a dev project is built by agents; a project with no stage is not" {
  project build dev "$SANDBOX/repos/game"
  project unset '' "$SANDBOX/repos/app"
  row build human 'dev row' "- [ ] dev row #high $T"
  row unset human 'unset row' "- [ ] unset row #high $T"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.project) \(.stage)"' <<<"$output")" 'build dev'
}

@test "candidates: only rows assigned to this worker, at a tier it may take" {
  project game beta "$SANDBOX/repos/game"
  row game human 'untagged' '- [ ] untagged #high'
  row game human 'tier only' '- [ ] tier only #tier/1'
  row game human 'other worker' '- [ ] other worker #worker/night #tier/1'
  row game human 'no tier' '- [ ] no tier #worker/fleet'
  row game human 'too high' '- [ ] too high #worker/fleet #tier/2'
  row game human 'assigned' "- [ ] assigned $T"
  row game human 'stamped' '- [ ] stamped <!-- #worker/fleet #tier/1 -->'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'assigned'
}

@test "candidates: a ci: or infra: row is tier 3 and never a candidate, however it is tagged" {
  project game beta "$SANDBOX/repos/game"
  echo '{"fleet": {"max_tier": 9}}' > "$DISPATCH_WORKERS"   # even a registry that asks for everything
  row game agent 'ci: suite.sh retries a batch' "- [ ] ci: suite.sh retries a batch $T"
  row game agent 'infra: bump the runner' "- [ ] INFRA: bump the runner $T"
  row game agent 'typed ci' "- [ ] ci(runner): retry the batch $T"
  row game agent 'typed infra' "- [ ] infra(k3s): bump the runner $T"
  row game agent 'scoped ci' "- [ ] fix(ci): the gate times out $T"
  row game agent 'gate row' '- [ ] gate row #worker/fleet #tier/3'
  row game agent 'tier two' '- [ ] tier two #worker/fleet #tier/2'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'tier two'
}

@test "candidates: a worker missing from the registry takes nothing" {
  project game beta "$SANDBOX/repos/game"
  row game human 'assigned' "- [ ] assigned $T"
  echo '{}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
}

@test "candidates: the requested worker takes only #requested rows, only in its project, never tier 3" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  echo '{"requested": {"max_tier": 9, "projects": ["game"], "only_tag": "requested"}}' > "$DISPATCH_WORKERS"
  row game agent 'real ask' '- [ ] real ask #requested #worker/requested #tier/2'
  row game agent 'tagged no ask' '- [ ] tagged no ask #worker/requested #tier/2'
  row game agent 'lookalike' '- [ ] lookalike #requests #worker/requested #tier/2'
  row game agent 'tier three' '- [ ] tier three #requested #worker/requested #tier/3'
  row game agent 'other worker' '- [ ] other worker #requested #worker/fleet #tier/1'
  row app agent 'wrong project' '- [ ] wrong project #requested #worker/requested #tier/2'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'real ask'
}

@test "candidates: a worker with no projects or only_tag is unlimited by them" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'one' "- [ ] one $T"
  row app agent 'two' "- [ ] two $T"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'one,two'
}

@test "candidates: a verdict from an older policy, or for the row's older text, is judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'stale policy' "- [ ] stale policy $T"
  row game agent 'retagged' "- [ ] retagged $T"
  row game agent 'current' "- [ ] current $T"
  row game agent 'died' "- [ ] died $T"
  verdict game agent 'stale policy' dispatch
  verdict game agent 'current' skip
  echo 'policy v2' > "$DISPATCH_POLICY"
  verdict game agent 'current' skip
  jq -cn --arg sig "$(policy_sig)" '{project: "game", lane: "agent", key: "retagged", verdict: "skip", policy: $sig, line: "old"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn '{project: "game", lane: "agent", key: "died", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'stale policy,retagged'
}

@test "candidates: a live dispatched session does not hold its project" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  started_item other-work lab:game-agent-3 run
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
}

board_workers() {
  echo '{"requested": {"max_tier": 2, "projects": ["game"], "only_tag": "requested"},
         "fleet": {"max_tier": 1},
         "board": {"max_tier": 2, "projects": ["game"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
}

@test "candidates: an untagged worker takes untagged agent rows of its project, at its own tier" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  board_workers
  row game agent 'plain' '- [ ] plain #high'
  row game agent 'tier one' '- [ ] tier one #tier/1'
  row game agent 'tier three' '- [ ] tier three #tier/3'
  row game agent 'ci: a gate' '- [ ] ci: a gate'
  row game agent 'someone else' '- [ ] someone else #worker/night'
  row game human 'human sheet' '- [ ] human sheet'
  row app agent 'other project' '- [ ] other project'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.worker)/\(.tier)"' <<<"$output" | paste -sd,)" 'plain=board/2,tier one=board/1'
}

@test "candidates: the human sheet stays opt-in" {
  project game beta "$SANDBOX/repos/game"
  board_workers
  row game human 'plain' '- [ ] plain'
  row game human 'tier only' '- [ ] tier only #tier/1'
  row game human 'assigned' "- [ ] assigned $T"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'assigned'
}

@test "the shipped registry: requested, then the human's assignments, then the game's agent board, never tier 3" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json"
  project unity-core-playground beta "$SANDBOX/repos/game"
  project platform prod "$SANDBOX/repos/app"
  row unity-core-playground agent 'an ask' '- [ ] an ask #requested #worker/requested #tier/2'
  row unity-core-playground agent 'assigned' "- [ ] assigned $T"
  row unity-core-playground agent 'plain' '- [ ] plain'
  row unity-core-playground agent 'tier three' '- [ ] tier three #tier/3'
  row unity-core-playground human 'human plain' '- [ ] human plain'
  row platform agent 'platform plain' '- [ ] platform plain'
  run cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.wrank) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'an ask=requested,assigned=fleet,plain=board'
}

# --- picks -------------------------------------------------------------------------------

@test "picks: only S or M, clear, agent-only dispatch verdicts, several per project, urgent then prod first" {
  c() { jq -cn --arg p "$1" --arg s "$2" --arg k "$3" --argjson pr "$4" \
        '{profile: "bnb", project: $p, stage: $s, lane: "human", key: $k, prio: $pr, tier: 1, line: ""}'; }
  cands=$(c alpha1 alpha a 0; c beta1 beta b 1; c beta1 beta b2 1; c prod1 prod p 1; c skipme prod s 0; c big prod L 0)
  verdict alpha1 human a dispatch
  verdict beta1 human b dispatch
  verdict beta1 human b2 dispatch
  verdict prod1 human p dispatch
  verdict skipme human s skip
  verdict big human L dispatch L        # a dispatch verdict on a large row still does not launch

  run picks "$cands" 4
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'a p b b2'
}

@test "picks: a medium row launches" {
  verdict game human k dispatch M
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

# c_area <key> <prio>: a candidate on project game
c_area() { jq -cn --arg k "$1" --argjson pr "$2" '{profile: "bnb", project: "game", stage: "beta", lane: "agent", key: $k, prio: $pr, tier: 2, line: ""}'; }

@test "picks: never two on one area in a pass, the more urgent wins, whatever the case" {
  cands=$(c_area low 3; c_area top 0; c_area other 3)
  verdict game agent low dispatch S 1 wilds
  verdict game agent top dispatch S 1 Wilds
  verdict game agent other dispatch S 1 skyline
  run picks "$cands" 3
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'top other'
}

@test "picks: skips an area an active item holds, and takes it once that item is closed" {
  verdict game agent k dispatch S 1 wilds
  started_item other-work lab:game-agent-3 run wilds
  run picks "$(c_area k 1)" 1
  assert_output ''
  agent-queue move other-work done --status ok >/dev/null
  run picks "$(c_area k 1)" 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

@test "picks: the same area name in another project is not busy" {
  verdict other agent k dispatch S 1 wilds
  started_item other-work lab:game-agent-3 run wilds
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run picks '{"project":"other","stage":"beta","lane":"agent","key":"k","prio":1,"tier":2,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

@test "picks: a verdict naming no area does not launch" {
  verdict game agent k dispatch S 1 ''
  run picks "$(c_area k 1)" 1
  assert_output ''
}

@test "picks: an ask outranks a more urgent row of a later worker" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson pr "$3" '{project: "game", stage: "beta", lane: "agent", key: $k, wrank: $w, prio: $pr, tier: 2, line: ""}'; }
  cands=$(c urgent 2 0; c theask 0 3)
  verdict game agent urgent dispatch
  verdict game agent theask dispatch
  run picks "$cands" 1
  assert_equal "$(jq -r .key <<<"$output")" theask
  # On one area too: the ask keeps the area, and the urgent row waits.
  verdict game agent urgent dispatch S 1 wilds
  verdict game agent theask dispatch S 1 wilds
  run picks "$cands" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" theask
}

@test "suggest: every open agent row and each human row a worker takes, auto or not, with its verdict and held area; it never judges" {
  echo '{"fleet": {"max_tier": 1, "projects": ["game"]}}' > "$DISPATCH_WORKERS"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  mkdir -p "$SANDBOX/repos/sketch"
  project sketch draft "$SANDBOX/repos/sketch"
  row game agent 'game judged' "- [ ] game judged #high $T"
  row game agent 'game busy' "- [ ] game busy $T"
  row game agent 'game new' "- [ ] game new $T"
  row app agent 'app row' "- [ ] app row #high $T"
  row game human 'game human' "- [ ] game human $T"
  row app human 'app human' "- [ ] app human $T"
  row sketch agent 'sketch row' "- [ ] sketch row $T"
  verdict game agent 'game judged' dispatch
  verdict game agent 'game busy' dispatch S 1 combat
  started_item other lab:other-1 run combat
  run cmd_suggest
  assert_success
  assert_output "auto  dispatch  game game judged  [fleet, #high, beta]
auto  unjudged  game game human  [fleet, beta]
auto  dispatch  game game busy (area held)  [fleet, beta]
auto  unjudged  game game new  [fleet, beta]
man   unjudged  app app row  [#high, alpha]"
  refute_output --partial 'app human'
  refute_output --partial 'sketch'
  run grep -c 'judge called' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A changed policy makes every cached verdict stale, so the list says unjudged, not dispatch.
  echo 'policy v2' > "$DISPATCH_POLICY"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.verdict)/\(.auto)"' <<<"$output" | paste -sd' ')" \
    'game judged=unjudged/true game human=unjudged/true game busy=unjudged/true game new=unjudged/true app row=unjudged/false'
}

@test "suggest: says so when no project has an open agent row" {
  project game beta "$SANDBOX/repos/game"
  run cmd_suggest
  assert_success
  assert_output 'suggest: no open agent row'
  run cmd_suggest --json
  assert_success
  assert_output ''
}

@test "rank: project priority, then due date, then worker, row priority, stage and age, each named in why" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  sed -i '1s/$/ #prio\/focus/' "$SANDBOX/sheets/game/README.md"
  project app alpha "$SANDBOX/repos/app"
  printf '## Inbox\n- [ ] a row that says #prio/high is not the head\n' >> "$SANDBOX/sheets/app/README.md"
  row app agent 'app urgent' "- [ ] app urgent #urgent $T"
  row app agent 'app due' "- [ ] app due #due1105 $T"
  row game agent 'game low' "- [ ] game low #low $T #c1101"
  row game agent 'game high new' "- [ ] game high new #high $T #c1104"
  row game agent 'game high' "- [ ] game high #high $T #c1020"
  run cmd_candidates
  assert_success
  run jq -sr "$RANK_JQ"'rank[] | "\(.key): \(.why)"' <<<"$output"
  assert_output "game high: focus project, fleet, #high, beta, 16d old
game high new: focus project, fleet, #high, beta, 1d old
game low: focus project, fleet, #low, beta, 4d old
app due: due today, fleet, alpha
app urgent: fleet, #urgent, alpha"
}

@test "rank: with no project priority, due or created date, the order is worker, row priority, stage" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson pr "$3" --arg st "$4" \
    "$RANK_JQ"'{key: $k, wrank: $w, prio: $pr, stage: $st, text: "- [ ] \($k)"} | rank_fields("2026-11-05"; "")'; }
  cands=$(c alpha-urgent 1 0 alpha; c prod-high 1 1 prod; c beta-high 1 1 beta; c asked 0 2 alpha)
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'asked alpha-urgent prod-high beta-high'
  # A low project's urgent row waits behind a normal project's normal row.
  run jq -sr "$RANK_JQ"'[.[] | rank_fields("2026-11-05"; if .k == "l" then "low" else "" end)] | rank | map(.k) | join(" ")' \
    <<<'{"k":"l","wrank":0,"prio":0,"stage":"prod"} {"k":"n","wrank":1,"prio":2,"stage":"alpha"}'
  assert_output 'n l'
}

@test "picks: a focus project's row goes before a more urgent row elsewhere, one area each" {
  c() { jq -cn --arg p "$1" --arg k "$2" --argjson pr "$3" --arg pp "$4" \
    "$RANK_JQ"'{project: $p, stage: "beta", lane: "agent", key: $k, wrank: 1, prio: $pr, tier: 1, line: "", text: "- [ ] \($k)"} | rank_fields("2026-11-05"; $pp)'; }
  cands=$(c app urgent 0 ""; c game later 2 focus)
  verdict app agent urgent dispatch
  verdict game agent later dispatch
  run picks "$cands" 1
  assert_equal "$(jq -r .key <<<"$output")" later
  run picks "$cands" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'later urgent'
}

@test "judge schema requires an area and the verdict keeps it" {
  stub judge-stub 'printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"agent\",\"key\":\"k\",\"verdict\":\"skip\",\"rule\":\"unclear\",\"area\":\"wilds\"}]}"'
  run judge '{"project":"p","stage":"beta","lane":"agent","key":"k","text":"- [ ] k","prio":2}'
  assert_success
  assert_equal "$(jq -r .area "$FLEET_DISPATCH_DIR/verdicts.jsonl")" wilds
  jq -e '.properties.verdicts.items.required | index("area")' "$BATS_TEST_DIRNAME/../../.config/fleet-dispatch/verdicts.schema.json" >/dev/null ||
    fail "the schema does not ask for an area"
}

@test "picks: a verdict that judged the row a higher tier than its tag, or gave no tier, does not launch" {
  c() { jq -cn --arg p "$1" --arg k "$2" '{profile: "bnb", project: $p, stage: "beta", lane: "human", key: $k, prio: 1, tier: 1, line: ""}'; }
  cands=$(c ok a; c higher b; c notier n)
  verdict ok human a dispatch S 1
  verdict higher human b dispatch S 3
  verdict notier human n dispatch S null
  run picks "$cands" 3
  assert_success
  assert_equal "$(jq -r .project <<<"$output" | paste -sd' ')" 'ok'
}

@test "picks: a dispatch verdict from an older policy does not launch" {
  verdict game human k dispatch
  echo 'policy v2' > "$DISPATCH_POLICY"
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_output ''
}

@test "picks: no room means no picks" {
  verdict game human k dispatch
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1}' 0
  assert_output ''
}

# --- judge -------------------------------------------------------------------------------

@test "judge keeps well-formed verdicts from the reply object and drops the rest" {
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
{"verdicts":[{"project":"game","lane":"human","key":"fix crash","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","rule":"fits","reason":"small bug"},{"project":"game","lane":"human","key":"other","verdict":"maybe"}]}
EOF
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","tier":1,"line":"abc"}'
  assert_success
  assert_equal "$(wc -l < "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 1
  assert_equal "$(jq -r '"\(.verdict) \(.tier) \(.line) \(.policy == "'"$(policy_sig)"'")"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'dispatch 1 abc true'
}

@test "judge: the old marker-wrapped reply yields no verdicts" {
  printf '%s\n' DISPATCH-VERDICTS-START '{"project":"game","lane":"human","key":"a","verdict":"dispatch","rule":"fits"}' DISPATCH-VERDICTS-END > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error the reply had no verdicts'
}

@test "judge fails loudly when the model returns no verdicts at all" {
  echo 'UserPromptSubmit operation blocked by hook' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  assert_failure
  assert_output --partial 'no verdicts for 1 row(s)'
}

@test "judge: each verdict names its policy rule and the call it came from" {
  stub judge-stub 'echo "$AGENTCTL_CALL_ID" > "$NOTES_FIXTURE/call.id"; cat "$NOTES_FIXTURE/judge.out"'
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
{"verdicts":[{"project":"game","lane":"human","key":"a","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","rule":"fits","reason":"small"},{"project":"game","lane":"human","key":"b","verdict":"skip","rule":"vibes","reason":"x"},{"project":"game","lane":"human","key":"c","verdict":"skip","reason":"no rule"}]}
EOF
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c; c d)"
  assert_success
  local id; id=$(cat "$NOTES_FIXTURE/call.id")
  [ -n "$id" ]
  v() { jq -r --arg k "$1" --arg id "$id" 'select(.key == $k) | "\(.verdict) \(.rule // "-") \(.judge_call == $id) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  assert_equal "$(v a)" 'dispatch fits true small'
  assert_equal "$(v b)" 'error - true rule "vibes" is not in the policy'
  assert_equal "$(v c)" 'error - true rule "" is not in the policy'
  assert_equal "$(v d)" 'error - true the reply had no verdict for this row'
  # An error holds nothing: those rows are judged again; the dispatch verdict holds.
  assert_equal "$(judged_keys | cut -f3 | paste -sd' ')" 'a'
}

@test "judge: a failed call is an error verdict for every row, with its reason, and the rows are judged again" {
  stub judge-stub 'echo "rate limited" >&2; exit 7'
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_output --partial 'judge call failed'
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error call failed (exit 7): rate limited '
  assert_equal "$(judged_keys)" ''
  # negative control: a reply that is not the schema object is an error verdict too, never silence
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  stub judge-stub 'echo "UserPromptSubmit operation blocked by hook"'
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error the reply had no verdicts'
}

@test "judge runs the model call outside the caller's directory and cleans up after it" {
  stub judge-stub 'pwd > "$NOTES_FIXTURE/judge.cwd"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  cwd=$(cat "$NOTES_FIXTURE/judge.cwd")
  [ "$cwd" != "$PWD" ]
  [ ! -e "$cwd" ]
}

@test "judge sends rows in rank order when the batch is capped: prod before alpha at one priority, an urgent alpha first" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":2}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":2}'
  assert_success
  run grep -c '"project":"p"' "$NOTES_FIXTURE/prompt"
  assert_output 1
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 0
  # The same cap picks the picks order, not a second one: row priority comes before stage.
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":2}'
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 1
}

# --- run ---------------------------------------------------------------------------------

game_ready() {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash on load' "- [ ] fix crash on load #high $T"
  verdict game human 'fix crash on load' dispatch
}

# The two rows that started this: dispatch picked the first on 2026-10-27 under the old,
# untiered policy, and the second was next. Cached verdicts from then must not launch.
@test "run: the 2026-10-27 ci rows, with their old cached dispatch verdicts, start nothing" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'ci: suite.sh retries a batch that dies before any class starts' \
    '- [ ] ci: suite.sh retries a batch that dies before any class starts #high'
  row game agent 'main rebuild drift: buildall moves prefabs, commit a rebuild on main' \
    '- [ ] main rebuild drift: buildall moves prefabs, commit a rebuild on main #high'
  mkdir -p "$FLEET_DISPATCH_DIR"
  for k in 'ci: suite.sh retries a batch that dies before any class starts' \
           'main rebuild drift: buildall moves prefabs, commit a rebuild on main'; do
    jq -cn --arg k "$k" '{project: "game", lane: "agent", key: $k, verdict: "dispatch", size: "S",
      clear: true, agent_only: true}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'no row qualifies'
  assert_not_called 'judge called'
}

@test "run --dry-run names the pick and launches, claims and records nothing" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would queue: game (beta) human, fleet, fix crash on load, high: fix crash on load'
  assert_not_called 'wt new'
  assert_not_called 'start fix crash'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/running" 2>/dev/null)" ] || fail "dry run queued an item"
}

@test "run fills the queue from the board, then starts that item on a detached lab session" {
  game_ready
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued game: gm-1'
  assert_output --partial 'started game-agent-1'
  assert_called 'ptask game --exact start -- - [ ] fix crash on load'
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  f=$(qitem running gm-1)
  [ -n "$f" ] || fail "the promoted item is not running"
  assert_equal "$(qfield "$f" from)" 'board:game:gm-1'
  assert_equal "$(qfield "$f" priority) $(qfield "$f" lane) $(qfield "$f" profile) $(qfield "$f" area)" 'high human bnb fix crash on load'
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" model)" 'lab:game-agent-1 run opus'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  # The session lands through agent-land, which closes the item and its row: the brief names no ptask.
  assert_called 'Merge with agent-land <N> (AGENT_QUEUE_ITEM=gm-1 is set)'
  assert_called 'promoted from the board row "gm-1"'
  assert_called 'The PR body carries the line "Item: gm-1" and the line "Task: gm-1".'
  run grep -c 'ptask game done' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_called 'tmux -L lab set-option -t =game-agent-1: @dispatch game: gm-1'
  [ ! -e "$FLEET_DISPATCH_DIR/live" ] || fail "wrote the retired dispatch/live ledger"
  # The session holds a runner slot on its area, read from the item alone.
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output 'game/fix crash on load light'
}

@test "fill promotes picks into the queue with no gate and starts nothing; --dry-run lists them" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load, high: fix crash on load [fleet, #high, beta]'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial 'queued game: gm-1'
  [ -n "$(qitem queued gm-1)" ] || fail "not queued"
  assert_not_called 'wt new'
}

@test "a queued board item holds its area against another pick" {
  game_ready
  row game human 'fix crash on save' "- [ ] fix crash on save $T"
  verdict game human 'fix crash on save' dispatch S 1 'fix crash on load'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  refute_output --partial 'ready'
}

@test "a board item that ends failed or cancelled hands its row back once, recorded failed" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  agent-queue cancel gm-1
  run cmd_reap
  assert_success
  assert_output --partial 'un-started game: gm-1 (queue item gm-1 ended cancelled)'
  grep -qF -- '- [ ] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not un-started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r .verdict)" failed
  run cmd_reap
  refute_output --partial 'un-started'
}

@test "run claims a row at the top of a board too big for one pipe buffer" {
  game_ready
  # A real board: grep -q stops at the first line while notes is still writing the rest.
  awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "filler row %d\t- [ ] filler row %d padded to make the board larger\n", i, i }' \
    >> "$NOTES_FIXTURE/rows.game.human"
  run promote "$(jq -cn --arg t "- [ ] fix crash on load #high $T" '{profile: "bnb", project: "game", lane: "human",
    key: "fix crash on load", text: $t, area: "load"}')" "" "fix crash on load"
  assert_success
  assert_output --partial 'queued game: gm-1'
}

@test "promote: the slug is the row's id, the from joins on it, and the priority is the row's" {
  project game beta "$SANDBOX/repos/game"
  row game human 'urgent one' '- [ ] urgent one #urgent <!-- id:gm-7 -->'
  row game human 'low one' '- [ ] low one #low <!-- id:gm-8 -->'
  row game human 'bare one' '- [ ] bare one <!-- id:gm-9 -->'
  for k in 7:urgent 8:low 9:high; do
    run promote "$(jq -cn --arg k "gm-${k%:*}" '{profile: "bnb", project: "game", lane: "human", key: $k}')" "" task
    assert_success
    assert_output --partial "queued game: gm-${k%:*}"
    f=$(qitem queued "gm-${k%:*}")
    [ -n "$f" ] || fail "no item for gm-${k%:*}"
    assert_equal "$(qfield "$f" priority) $(qfield "$f" from)" "${k#*:} board:game:gm-${k%:*}"
  done
  assert_equal "$(grep -c 'id:gm-' "$NOTES_FIXTURE/rows.game.human")" 3
}

@test "promote: a row start could not give an id is un-started and refused, with no item" {
  project game beta "$SANDBOX/repos/game"
  row game human 'the row' '- [ ] the row'
  touch "$NOTES_FIXTURE/nocode.game"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "the row"}')" "" "the row"
  assert_failure
  assert_output --partial 'row has no id and start gave it none'
  grep -qF -- '- [ ] the row' "$NOTES_FIXTURE/rows.game.human" || fail "row left started"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "an id-less row got an item"
}

@test "fleet-dispatch promote --raw queues the row the Board showed; a row that changed or started is refused" {
  project game beta "$SANDBOX/repos/game"
  row game human 'the row' '- [ ] the row #low <!-- id:gm-3 -->'
  row game human 'taken' '- [/] taken <!-- id:gm-4 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] the row as it read before <!-- id:gm-3 -->'
  assert_failure
  assert_output --partial 'so it changed'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [/] taken <!-- id:gm-4 -->'
  assert_failure
  assert_output --partial 'row no longer open'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a refused row got an item"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] the row #low <!-- id:gm-3 -->'
  assert_success
  assert_output --partial 'queued game: gm-3'
  f=$(qitem queued gm-3)
  assert_equal "$(qfield "$f" priority) $(qfield "$f" from) $(qfield "$f" lane)" 'low board:game:gm-3 human'
  grep -qF -- '- [/] the row #low' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
}

@test "fill --dry-run keys a row by its id and shows the priority it would queue at" {
  project game beta "$SANDBOX/repos/game"
  row game human gm-5 "- [ ] fix crash on load #low $T <!-- id:gm-5 -->"
  verdict game human gm-5 dispatch S 1 load
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, load, low: gm-5 [fleet, #low, beta]'
}

@test "run starts nothing while dispatch is held" {
  game_ready
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held'
  assert_not_called 'wt new'
}

@test "run starts nothing while the cluster is red or unreadable, and says why" {
  game_ready
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'infra: k3s domain red'
  assert_not_called 'wt new'
}

@test "run starts nothing over the load pace" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over the'
  assert_not_called 'wt new'
}

# refuses <text>: this pass stopped at a gate and said so, with everything else passing.
refuses() {
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial "$1"
  assert_not_called 'wt new'
  assert_not_called 'judge called'
}

@test "run starts nothing when no account has room under its weekly pace" {
  game_ready
  stub claude-acct 'exit 1'
  refuses 'no account has room under its weekly pace'
}

@test "room gone by the start: BLOCKED names the closest account and how far past its pace, from room's own line" {
  game_ready
  # the gate's ask finds room; the start's ask, a moment later, finds none
  stub claude-acct '[ "$1" = room ] || exit 0
n=$(cat "$NOTES_FIXTURE/room.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$NOTES_FIXTURE/room.n"
[ "$n" = 0 ] && { echo /home/u/.claude-personal; exit 0; }
echo "claude-acct: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 10:40 at this rate" >&2; exit 1'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item gm-1 waits: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), runs out Mon 10:40 at this rate'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'
}

@test "run starts nothing when account usage cannot be read" {
  game_ready
  stub claude-acct 'exit 2'
  refuses 'account usage unreadable'
}

@test "a run start lands on the account room names, never pick" {
  game_ready
  stub claude-acct '[ "$1" = room ] && { echo /home/u/.claude-personal; exit 0; }; echo /wrong/pick'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  assert_not_called '/wrong/pick'
}

@test "a hand start still goes ahead when no account has room" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  stub claude-acct '[ "$1" = room ] && exit 1; echo /home/u/.claude-personal'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "run while the human is here starts one board item an hour, and queues the rest for when they leave" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PER_PASS=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(grep -c 'present start: queue item' "$LOG")" 1
  assert_equal "$(outcome)" WORKED
  # The hour's start is used: the next pass starts nothing, and says why.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(outcome)" NOOP
  # An hour on, the trickle has room again.
  sed -i "s/^- [0-9-]* [0-9:]* present start:/- $(date -d '-61 min' '+%Y-%m-%d %H:%M') present start:/" "$LOG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 2
}

@test "run with DISPATCH_PRESENT_PER_HOUR=0 starts no board item while the human is here, and still queues it" {
  game_ready
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PRESENT_PER_HOUR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1; the human is here'
  assert_not_called 'wt new'
  [ -n "$(qitem queued gm-1)" ] || fail "the row was not queued"
  assert_equal "$(outcome)" NOOP
  # Away, the same item starts.
  stub fleet-presence 'echo "away 45 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called 'wt new'
}

@test "run counts unreadable presence as here: the board starts at the trickle, not the away rate" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  export DISPATCH_PER_PASS=3
  stub fleet-presence 'exit 2'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
}

@test "run tops the queue up from the board while fewer than DISPATCH_LOW_WATER items are runnable" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=3
  agent-queue add --project game --slug mine "mine"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: mine'
  assert_output --partial 'runnable 0 is under the low water 3'
  # Both rows queued to reach the mark; the pass's one start went to the human's item.
  [ -n "$(qitem queued gm-1)" ] && [ -n "$(qitem queued gm-2)" ] || fail "the board did not top the queue up"
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(outcome)" WORKED
}

@test "run at or over DISPATCH_LOW_WATER does not read the board, and 0 reads it only for an empty queue" {
  game_ready
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  agent-queue add --project game --slug one "one"
  agent-queue add --project game --slug two "two"
  agent-queue add --project game --slug three "three"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'low water'
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the board was read over the low water"
  export DISPATCH_LOW_WATER=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -z "$(qitem queued gm-1)" ] || fail "low water 0 read the board with items runnable"
}

# finding <rule> <scope> [repos json] -- one finding row fleet-bench reports as firing now
finding() { jq -cn --arg r "$1" --arg s "$2" --argjson repos "${3:-null}" --arg b "${4:-}" --argjson e "$(date +%s)" '{rule: $r, scope: $s, repos: $repos, epoch: $e} + (if $b == "" then {} else {bind: $b} end)'; }
# findings <row>... -- fleet-bench reports exactly those rows
findings() { printf '%s\n' "$@" > "$SANDBOX/findings.out"; stub fleet-bench "cat '$SANDBOX/findings.out'"; }

# two_items: a game item at the head of the queue and an app item behind it, both the human's
two_items() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project game --slug fix-game --priority high "fix the game"
  agent-queue add --project app --slug fix-app --priority low "fix the app"
}

@test "a starved pool or a starved host that names no repos holds every item" {
  game_ready
  findings "$(finding starved pool:unity)"
  refuses 'finding firing: gm-1 (starved pool:unity), every queue item waits'
  findings "$(finding starved workstation)"
  refuses 'finding firing: gm-1 (starved workstation)'
}

@test "a blind finding holds nothing: a reader's gap is not a fault" {
  game_ready
  findings "$(finding blind merges:unity-core-playground-agent-40-b)" '{"rule":"blind","scope":"sampler"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1'
}

@test "a starved pool holds only the items whose repo waits in it, and the pass starts the next one" {
  two_items
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

@test "a pool starved on labels holds nothing: a held session would not free it" {
  two_items
  # 2026-11-05: a frame sweep pinned to one host starved pool:other, and dispatch held the repo for 7h.
  findings "$(finding starved pool:other '["game"]' labels)" "$(finding starved pool:unity '["game"]' labels)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game'
}

@test "a pool starved on capacity still holds its repo's items" {
  two_items
  findings "$(finding starved pool:unity '["game"]' capacity)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

# held_game_app_row: a game queue item a starved unity pool holds, and an app board row it does not
held_game_app_row() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project game --slug fix-game --priority high "fix the game"
  row app human 'fix app crash' "- [ ] fix app crash #high $T"
  verdict app human 'fix app crash' dispatch
  findings "$(finding starved pool:unity '["game"]')"
}

# 2026-11-05: held unity items kept every pass off the board for 7h, so the rows filed to fix the
# hold never started.
@test "every queue item a finding holds sends the pass on to the board, and an unheld row starts" {
  held_game_app_row
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_output --partial 'queued app: '
  assert_output --partial 'started game-agent-1: app: '
  assert_equal "$(outcome)" WORKED
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

@test "a pass past held queue items that starts no board row either is BLOCKED by the hold, never NOOP" {
  held_game_app_row
  stub fleet-presence 'echo "here 0 tmux"'
  DISPATCH_PRESENT_PER_HOUR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_output --partial 'queued app: gm-1'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
  # No row qualifies: the hold still names the pass. (The row the first pass queued is closed first.)
  agent-queue move gm-1 done --status cancelled >/dev/null
  stub fleet-presence 'echo "away 45 tmux"'
  : > "$NOTES_FIXTURE/rows.app.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
}

@test "a held queue item whose board row is held too stays BLOCKED and starts nothing" {
  held_game_app_row
  findings "$(finding starved pool:unity '["game","app"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued app: '
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
}

@test "a throughput drop holds only the items on that project's repo, an alias included" {
  two_items
  findings "$(finding throughput-drop game)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started game-agent-1: app: fix-app'
  agent-queue add --project game --slug fix-game-2 --priority low "fix it again"
  jq '.aliases = {gm: "game"}' "$DISPATCH_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$DISPATCH_PROJECT_MAP"
  findings "$(finding throughput-drop gm)" "$(finding starved pool:light '["elsewhere"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started'
  assert_output --partial 'finding firing: fix-game (throughput-drop gm), fix-game-2 (throughput-drop gm), every queue item waits'
  for n in 3 4; do agent-queue add --project game --slug "fix-game-$n" --priority low "fix it $n"; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'finding firing: fix-game (throughput-drop gm), fix-game-2 (throughput-drop gm), fix-game-3 (throughput-drop gm), 1 more, every queue item waits'
}

@test "run --dry-run names each held item and the one that would start while a pool its head feeds is starved" {
  two_items
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'queue item fix-game waits: starved pool:unity'
  assert_output --partial 'would start queue item fix-app: app oneshot low'
  assert_not_called 'wt new'
}

@test "run starts up to DISPATCH_PER_PASS queue items a pass, past the held ones" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  agent-queue add --project app --slug fix-app-3 "fix the app once more"
  export DISPATCH_PER_PASS=2
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'started queue item fix-app' <<<"$output")" 2
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 2
  assert_equal "$(outcome)" WORKED
}

@test "run --dry-run names every item a pass would start" {
  two_items
  export DISPATCH_PER_PASS=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would start queue item fix-game: game oneshot high'
  assert_output --partial 'would start queue item fix-app: app oneshot low'
  assert_not_called 'wt new'
}

@test "a pass reads the gate again before each later start, and stops there still WORKED" {
  two_items
  export DISPATCH_PER_PASS=3
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "99.0 99.0 99.0 1/1 1" > "$DISPATCH_LOADAVG"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-game'
  assert_output --partial 'the pass stops after 1 started'
  refute_output --partial 'started queue item fix-app'
  refute_output --partial 'under-used'
  assert_equal "$(outcome)" WORKED
}

@test "with DISPATCH_PER_PASS at 1 a pass starts only the head" {
  two_items
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-game'
  refute_output --partial 'started queue item fix-app'
}

# The model-lane stub runs just before the pass's launch: here it is another start that took the head.
@test "an item another start took between the pick and the launch is not FAILED, and the pass goes on" {
  two_items
  export DISPATCH_PER_PASS=2
  stub model-lane '[ -n "$(ls "$AGENT_QUEUE_DIR/queued" | grep fix-game)" ] && agent-queue move fix-game running >/dev/null; echo "{}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item fix-game was started by another start'
  assert_output --partial 'started queue item fix-app'
  refute_output --partial 'could not start'
  assert_equal "$(outcome)" WORKED
}

@test "a pass whose only item another start took publishes NOOP" {
  two_items
  agent-queue cancel fix-app >/dev/null
  stub model-lane 'agent-queue move fix-game running >/dev/null; echo "{}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'another start took the 1 queue item(s) this pass picked'
  assert_equal "$(outcome)" NOOP
}

@test "a start waits for another start of a queue item to claim its own, and leaves it queued past the wait" {
  two_items
  export DISPATCH_START_WAIT=0
  mkdir -p "$FLEET_DISPATCH_DIR"; exec 7>"$FLEET_DISPATCH_DIR/.start.lock"; flock 7
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-app
  exec 7>&-
  assert_failure
  assert_output --partial 'another start held the queue lock for 0s; fix-app stays queued'
  [ -n "$(qitem queued fix-app)" ] || fail "fix-app stays queued"
  assert_not_called 'wt new'
}

@test "a pass a limit stopped while work waits and the gates are open says which limit, still WORKED" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'under-used: started 1, DISPATCH_PER_PASS is the limit while 2 runnable wait'
  grep -q 'under-used: started 1, DISPATCH_PER_PASS is the limit, 2 runnable left' "$FLEET_DISPATCH_DIR/log.md" || fail "the log records it"
  assert_equal "$(outcome)" WORKED
}

@test "headroom counts what could start now against each limit" {
  two_items
  export DISPATCH_PER_PASS=1 DISPATCH_MAX_LIVE=6
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.could_start, .per_pass_limited, .runnable, .slots_free, .idle_room, .held] | @tsv' <<<"$output")" $'2\ttrue\t2\t6\t60\t'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'could start now: 2 of 2 runnable (a pass starts up to 1)'
  assert_not_called 'wt new'
}

@test "headroom is 0 and names what holds: a gate, or every run unit used" {
  two_items
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .could_start <<<"$output")" 0
  assert_equal "$(jq -r .held <<<"$output")" "load 99.0 on $(nproc) cores is over the 0.7 pace"
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  export DISPATCH_MAX_LIVE=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" $'0\tDISPATCH_MAX_LIVE: every run unit is used'
}

@test "headroom counts live sessions started by hand apart from run slots, and names the held kind" {
  two_items
  started_item run-one lab:lab-run-1 run
  started_item hand-one lab:lab-hand-1 hand
  printf 'lab-run-1\nlab-hand-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  export DISPATCH_MAX_LIVE=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .live_hand, .held_kind] | @tsv' <<<"$output")" $'1\t1\tslots'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'run units: 1/1 used, 0 free (heavy 2, light 1), 1 more started by hand'
  export DISPATCH_MAX_LIVE=6
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .held_kind <<<"$output")" load
  echo '0.1 0.1 0.1 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.held, .held_kind] | @tsv' <<<"$output")" $'fleet-assess says HOLD\tassess'
}

@test "a run from a shell reads the DISPATCH_* tuning from the agentctl conf; the environment wins" {
  mkdir -p "$HOME/.config/agentctl/agents"
  printf "NAME=fleet-dispatch\nDISPATCH_MAX_LIVE=24\nDISPATCH_MAX_LOAD='1.5'\nDISPATCH_PER_PASS=3\n" > "$HOME/.config/agentctl/agents/fleet-dispatch.conf"
  two_items
  run env -u DISPATCH_MAX_LIVE -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.max_live, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'24\t3\t1.5'
  DISPATCH_MAX_LIVE=2 run env -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .max_live <<<"$output")" 2
}

@test "run starts past a finding that stopped firing, or one that is not a shared fault" {
  game_ready
  stub fleet-bench "jq -cn --argjson e \$(( \$(date +%s) - 21 * 60 )) '{rule: \"starved\", scope: \"pool:unity\", epoch: \$e}'
    jq -cn --argjson e \$(date +%s) '{rule: \"host-overload\", scope: \"mac-studio\", epoch: \$e}'"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1'
}

@test "run starts nothing while the findings cannot be read" {
  game_ready
  stub fleet-bench 'exit 2'
  refuses 'findings unreadable'
  stub fleet-bench 'echo not json'
  refuses 'findings unreadable'
}

@test "run starts nothing while the GitHub budget is low or unreadable" {
  game_ready
  stub fleet-assess '[ "$1" = --github ] && echo "github: 10/5000 REST calls left, resets 13:00, LOW"; exit 0'
  refuses 'LOW'
  stub fleet-assess '[ "$1" = --github ] && echo "github: rate limit unreadable"; exit 0'
  refuses 'github budget unreadable'
  stub fleet-assess 'exit 0'
  refuses 'github budget unreadable'
}

@test "run reads real idle from the second top frame: the first is since boot" {
  game_ready
  stub top 'printf "%%Cpu(s):  1.0 us,  1.0 sy,  0.0 ni, 98.0 id,  0.0 wa\n%%Cpu(s): 60.0 us,  5.0 sy, 25.0 ni, 10.0 id,  0.0 wa\n"'
  refuses 'real idle 10.0% is under 30%'
}

@test "run starts nothing while real idle cannot be read" {
  game_ready
  stub top 'exit 1'
  refuses 'real idle unreadable'
}

@test "run --dry-run names what would stop a real pass and still lists the picks" {
  game_ready
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'load 30.00 on'
  assert_output --partial 'would queue: game'
  assert_not_called 'wt new'
}

# outcome: what the pass told fleet-liveness, through the real agent-proof.sh the sandbox links.
# agentctl calls a run that says nothing STALLED.
outcome() { cat "$HOME/.local/state/agentctl/fleet-dispatch/last-outcome" 2>/dev/null; }

@test "run publishes WORKED only for a session it really started" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" WORKED
}

@test "run publishes NOOP when a gate stops it or no row qualifies" {
  game_ready
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" NOOP
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  rm -f "$HOME/.local/state/agentctl/fleet-dispatch/last-outcome"
  stub fleet-presence 'echo "away 45 tmux"'
  : > "$NOTES_FIXTURE/rows.game.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'no row qualifies'
  assert_equal "$(outcome)" NOOP
}

@test "run publishes BLOCKED when a gate leaves a queue item waiting, NOOP when the human held dispatch" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item fix-game waits'
  assert_equal "$(outcome)" BLOCKED
  stub agent-hold 'echo "dispatch held"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held (agent-hold'
  assert_equal "$(outcome)" NOOP
  assert_not_called 'wt new'
}

@test "run publishes BLOCKED when a finding holds every queue item" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game "fix the game" >/dev/null
  stub fleet-bench '[ "$1" = findings ] && echo "{\"rule\":\"starved\",\"scope\":\"host\"}"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'every queue item waits'
  assert_equal "$(outcome)" BLOCKED
}

@test "run publishes FAILED when it could not start what it picked" {
  game_ready
  stub wt 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure
  assert_equal "$(outcome)" FAILED
}

@test "run publishes FAILED when it could not judge" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure
  assert_equal "$(outcome)" FAILED
}

@test "a dry run publishes nothing, past a gate or at one" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_equal "$(outcome)" ''
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_equal "$(outcome)" ''
}

@test "run starts nothing once the live cap is reached" {
  game_ready
  export DISPATCH_MAX_LIVE=1
  project other beta "$SANDBOX/repos/other"
  row other human 'other work' '- [/] other work'
  started_item other-work lab:other-agent-1 run '' 'board:other:other work' running other
  printf 'other-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 1 of 1 run units'
  assert_not_called 'wt new'
}

@test "a heavy item waits at 5 of 6 run units while a light one behind it starts" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_MAX_LIVE=6
  # Two heavy and one light live session: 2 + 2 + 1 = 5 units.
  local s
  for s in h1 h2 l1; do started_item "$s" "lab:game-agent-$s" run "area-$s"; done
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/running/*-h1.md "$AGENT_QUEUE_DIR"/running/*-h2.md
  printf 'game-agent-h1\ngame-agent-h2\ngame-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  assert_equal "$(live_units)" 5
  agent-queue add --project game --slug big-one --weight heavy "big one"
  agent-queue add --project game --slug small-one --priority low --weight light "small one"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'game: small-one'
  [ -n "$(qitem queued big-one)" ] || fail "the heavy item started past the unit budget"
  [ -n "$(qitem running small-one)" ] || fail "the light item did not start"
}

@test "a heavy item alone at 5 of 6 run units is a full fleet: NOOP, not BLOCKED" {
  project game beta "$SANDBOX/repos/game"
  local s
  for s in h1 h2 l1; do started_item "$s" "lab:game-agent-$s" run "area-$s"; done
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/running/*-h1.md "$AGENT_QUEUE_DIR"/running/*-h2.md
  printf 'game-agent-h1\ngame-agent-h2\ngame-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug big-one --weight heavy "big one"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'heavy needs 2 run units, 1 free'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  [ -n "$(qitem queued big-one)" ] || fail "the heavy item left the queue"
}

# --- reap --------------------------------------------------------------------------------

@test "reap fails a board item whose session ended without closing it, un-starts its row, records failed" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  run cmd_reap
  assert_success
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl")" failed
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
}

@test "reap leaves a board item its session closed ok, and its row, alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [x] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  agent-queue move fix-crash done --status ok >/dev/null
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  assert_not_called 'start'
  # Closed, it holds no slot even while the human reuses its tmux session.
  run live_runs
  assert_output ''
}

@test "reap leaves a live session's item running while it neither waits nor asks" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-1 run
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "moved a working session's item"
  # 2026-11-04: the weight field after state read as "runningheavy", and every pass re-moved every live item.
  ! grep -q reaped "$FLEET_DISPATCH_DIR/log.md" 2>/dev/null || fail "reaped an item already in its state: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  assert_not_called 'start'
}

# 2026-11-03: a plan item sat in running/ at its plan, and the Overview's "Waiting for you" was empty.
@test "reap moves an item to waiting while its session waits on the human or owns a pending ask, and back after" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1
  started_item q lab:game-agent-2
  printf 'game-agent-1\ngame-agent-2\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'printf "%s\n" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"waiting\"}" "{\"target\":\"lab/game-agent-2:1\",\"status\":\"idle\"}"'
  stub agent-ask 'printf "a1\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-03\tgame-agent-2\n"'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting p)" ] || fail "the session at its plan is not waiting"
  [ -n "$(qitem waiting q)" ] || fail "the session with a pending ask is not waiting"

  stub agent-panel 'printf "%s\n" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}" "{\"target\":\"lab/game-agent-2:1\",\"status\":\"idle\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running p)" ] && [ -n "$(qitem running q)" ] || fail "an answered session stayed waiting"
}

# 2026-11-05: about a fifth of running items were dead: a shell kept the tmux session after claude
# exited, or a hub-window item had no session of its own, and reap read both as live forever.
@test "reap settles an item whose claude exited though its tmux session lives; a parked pane, another agent and a fresh start are kept" {
  project game beta "$SANDBOX/repos/game"
  started_item gone lab:game-agent-1
  started_item parked lab:game-agent-2
  started_item codex lab:game-agent-3
  sed -i 's/^agent: claude/agent: codex/' "$AGENT_QUEUE_DIR"/running/*-codex.md
  started_item fresh lab:game-agent-4
  sed -i "s/^started: .*/started: $(date -u +%FT%TZ)/" "$AGENT_QUEUE_DIR"/running/*-fresh.md
  started_item kept lab:game-agent-5
  printf 'game-agent-%s\n' 1 2 3 4 5 > "$NOTES_FIXTURE/tmux.sessions.lab"
  mkdir -p "$HOME/.agent/parked"; : > "$HOME/.agent/parked/game-agent-2:1"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-5:1\",\"status\":\"busy\",\"session_id\":\"s5\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-gone.md 2>/dev/null)" ] || fail "an item whose claude exited stayed active"
  for k in parked codex fresh kept; do [ -n "$(qitem running "$k")" ] || fail "reaped $k"; done
}

@test "reap settles a hub-window item once none of its Claude sessions is live, and keeps one whose session is" {
  project game beta "$SANDBOX/repos/game"
  started_item hubgone '' && started_item hublive ''
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h1 h2/' "$AGENT_QUEUE_DIR"/running/*-hubgone.md
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h3/' "$AGENT_QUEUE_DIR"/running/*-hublive.md
  stub agent-panel 'echo "{\"target\":\"hub/dotfiles:2\",\"status\":\"idle\",\"session_id\":\"h3\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-hubgone.md 2>/dev/null)" ] || fail "a hub item with no live session stayed active"
  [ -n "$(qitem running hublive)" ] || fail "reaped a hub item whose session is live"
  grep -q 'reaped h2' "$FLEET_DISPATCH_DIR/log.md" || fail "the log does not name the session: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  stub agent-panel 'exit 0'
  started_item hubblind ''
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h9/' "$AGENT_QUEUE_DIR"/running/*-hubblind.md
  run cmd_reap
  [ -n "$(qitem running hubblind)" ] || fail "reaped on an empty panel"
}

@test "reap moves nothing when it cannot read the sessions or the asks" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1 '' '' human waiting
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'exit 1'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem waiting p)" ] || fail "moved an item on an unreadable agent-panel"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 1'
  run cmd_reap
  [ -n "$(qitem waiting p)" ] || fail "moved an item on an unreadable agent-ask"
}

# --- start: the one launch path for every agent-started session --------------------------
# 2026-10-28: only `run` tagged @dispatch and kept a record, so restored and hand-launched
# sessions showed no [dispatch] and an agent tagged two by hand with set-option.

@test "start --brief claims the row, promotes it to an item, and starts that item on the agent world" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'started game-agent-1: game: gm-1'
  grep -qF -- '- [/] tidy the loader' "$NOTES_FIXTURE/rows.game.agent" || fail "row not claimed"
  assert_called "new --server lab --detach -c $SANDBOX/repos/game"
  assert_called 'tmux -L lab set-option -t =game-agent-1: @dispatch game: gm-1'
  f=$(qitem running gm-1)
  [ -n "$f" ] || fail "the row's item is not running"
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" lane) $(qfield "$f" profile)" 'lab:game-agent-1 hand agent bnb'
  assert_equal "$(qfield "$f" from)" 'board:game:gm-1'
  # One /one-shot: the item's brief adds it, so the row brief's own is dropped.
  assert_equal "$(grep -o '/one-shot' "$NOTES_FIXTURE/cmd" | wc -l)" 1
  grep -qF 'AGENT_QUEUE_ITEM=gm-1' "$NOTES_FIXTURE/cmd" || fail "the session does not know its item"
}

@test "start --brief refuses a row that is not open, and starts nothing" {
  project game beta "$SANDBOX/repos/game"
  row game human 'taken' '- [/] taken'
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row taken --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'row no longer open'
  assert_not_called 'wt new'
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "queued an item"
}

@test "start --resume opens its own session on the named server running claude --resume, and leaves the sheet alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game \
    --server default --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "tmux -L default new-session -d -s fix-crash -c $SANDBOX/repos/game env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
  assert_called 'tmux -L default set-option -t =fix-crash: @dispatch game: resumed'
  assert_not_called 'start fix crash'
  assert_not_called 'wt new'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "touched the row"
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "a restore with no item wrote one"
}

@test "start --resume --item re-attaches the started item to the new session; a queued item or a --row is refused" {
  project game beta "$SANDBOX/repos/game"
  started_item fix-crash lab:game-agent-9 run '' 'board:game:fix crash'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session fix-crash \
    --cwd "$SANDBOX/repos/game" --resume abc-123 --item fix-crash
  assert_success
  assert_called 'tmux -L default set-option -t =fix-crash: @dispatch game: fix-crash'
  f=$(qitem running fix-crash)
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin)" 'default:fix-crash resume'

  agent-queue add --project game --slug later "later" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session s2 --cwd "$SANDBOX/repos/game" --resume x --item later
  assert_failure
  assert_output --partial 'later is queued'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --server default --session s3 \
    --cwd "$SANDBOX/repos/game" --resume x
  assert_failure
  assert_output --partial 'not --row'
  assert_not_called 'new-session -d -s s2'
  assert_not_called 'new-session -d -s s3'
}

@test "start runs claude on the account claude-acct picks, for a brief and for a resume" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf 'brief\n' > "$SANDBOX/brief.md"
  stub claude-acct 'echo /home/u/.claude-personal'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --agent \
    --row 'tidy the loader' --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default \
    --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "fix-crash -c $SANDBOX/repos/game CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --permission-mode bypassPermissions --resume abc-123"
}

@test "start --resume never lands in a session that already exists on that server" {
  project game beta "$SANDBOX/repos/game"
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default \
    --session dotfiles --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_failure
  assert_output --partial 'already exists on default'
  assert_not_called 'new-session'
  assert_not_called 'set-option'
}

@test "start takes --server only for a resume: a new session goes to the agent world" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --server hub --brief "$SANDBOX/brief.md"
  assert_failure 2
  assert_output --partial '--server is for --resume'
  assert_not_called 'wt new'
}

@test "start refuses to guess when no world declares @agents" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  printf 'brief\n' > "$SANDBOX/brief.md"
  rm "$HOME/.config/tmux-servers/lab.conf"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row 'fix crash' --brief "$SANDBOX/brief.md"
  assert_failure 1
  assert_output --partial 'no world declares @agents'
  assert_not_called 'wt new'
}

@test "start refuses a call that is not exactly one launch" {
  printf 'brief\n' > "$SANDBOX/brief.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row r
  assert_failure
  assert_output --partial 'exactly one of --brief, --item or --resume'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --row r --brief "$SANDBOX/brief.md" --resume x
  assert_failure
  assert_output --partial 'exactly one of --brief, --item or --resume'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --brief "$SANDBOX/brief.md"
  assert_failure
  assert_output --partial 'needs the --row'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --resume x --cwd "$SANDBOX"
  assert_failure
  assert_output --partial 'needs --session and --cwd'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project
  assert_failure
  assert_output --partial '--project needs a value'
  assert_not_called 'wt new'
  assert_not_called 'new-session'
}

@test "reap reads the server from the item: a live session on default is kept, one gone from it is settled" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash default:game-agent-1 run '' 'board:game:fix crash'
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  stub agent-panel 'exit 0'; stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "reaped a session live on the server its item names"
  assert_not_called 'start'

  # The same name live on lab only is not this session.
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "kept an item whose session is gone from its server"
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
}

@test "a live hand launch or restore holds none of the runner's slots; its own sessions do" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  started_item restored lab:restored resume
  started_item by-hand lab:by-hand hand
  printf 'restored\nby-hand\ngame-agent-9\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output ''
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'

  started_item mine lab:game-agent-9 run wilds
  run live_runs
  assert_output 'game/wilds light'
}

# --- night: tier 3 to an open PR ---------------------------------------------------------

# night_ready: the agent-runtime board in the default profile, every gate passing.
night_ready() {
  export DISPATCH_NIGHT_PROFILE='' DISPATCH_NIGHT_PROJECTS=agent-runtime
  project agent-runtime alpha "$SANDBOX/repos/app"
}

# night_verdict <key> [area] [tier3_only] [size] -- a tier-3 skip under the current policy for the row's text
night_verdict() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg k "$1" --arg a "${2-$1}" --argjson t3 "${3:-true}" --arg s "${4:-S}" --arg sig "$(policy_sig)" \
    --arg line "$(line_of agent-runtime agent "$1")" \
    '{project: "agent-runtime", lane: "agent", key: $k, verdict: "skip", size: $s, tier: 3, area: $a,
      clear: true, agent_only: true, tier3_only: $t3, reason: "tier 3", policy: $sig, line: $line}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

state_of() { awk -F'\t' -v k="$1" '$1 == k { print substr($2, 1, 5) }' "$NOTES_FIXTURE/rows.agent-runtime.agent"; }

# night_keys -> the fixture names of the rows behind the queued night items, sorted.
night_keys() {
  local id
  agent-queue list --json --state queued | jq -r 'select((" " + (.tags // "") + " ") | contains(" night ")) | .from | ltrimstr("board:agent-runtime:")' |
    while read -r id; do awk -F'\t' -v q="id:$id " 'index($2, q) { print $1 }' "$NOTES_FIXTURE/rows.agent-runtime.agent"; done | sort | paste -sd, -
}

fill() { run "$REPO_ROOT/.local/bin/fleet-dispatch" fill "$@"; }

@test "night: a tier-3 agent-runtime row is promoted as a night item with its brief, started on the board, no session" {
  night_ready
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3 #high'
  night_verdict 'wt done never reaps' wt

  fill
  assert_success
  assert_output --partial 'queued agent-runtime: gm-1'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "no night item"
  assert_equal "$(qfield "$f" tags) $(qfield "$f" priority) $(qfield "$f" area)" 'night high wt'
  assert_equal "$(qfield "$f" from)" 'board:agent-runtime:gm-1'
  [ "$(state_of 'wt done never reaps')" = '- [/]' ] || fail "row not started"
  run agent-queue show gm-1
  assert_output --partial 'wt done never reaps (worktree.sh:213)'
  assert_output --partial 'Where: worktree.sh:213'
  assert_output --partial 'Merge gate: make -C tests test-fast'
  assert_output --partial 'Open the PR, do not merge.'
  assert_output --partial 'do not mark it done'
  assert_not_called 'wt new'
  assert_not_called 'judge called'
}

@test "night: a tier-3 row never becomes a merging item, even with a dispatch verdict" {
  night_ready
  echo '{"board": {"max_tier": 9, "projects": ["agent-runtime"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  row agent-runtime agent 'drop the dead timer' '- [ ] drop the dead timer #tier/3'
  verdict agent-runtime agent 'drop the dead timer' dispatch S 3 timer
  night_verdict 'drop the dead timer' timer

  run cmd_candidates
  assert_output ''
  run picks "$(all_open)" 5
  assert_output ''
  fill
  assert_equal "$(night_keys)" 'drop the dead timer'
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
}

@test "night: only rows tier 3 alone holds back; a requested row goes, decisions, devices, the human's machine and lower tiers stay out" {
  night_ready
  row agent-runtime agent 'requested row' '- [ ] fix the requested row #requested #tier/3'
  row agent-runtime agent 'decide: fold it' '- [ ] decide: fold it #tier/3'
  row agent-runtime agent 'typed decide' '- [ ] decide(board): fold it #tier/3'
  row agent-runtime agent 'pad run' '- [ ] fix the pad controller switch #tier/3'
  row agent-runtime agent 'waybar row' '- [ ] waybar: fix pulse colours #tier/3'
  row agent-runtime agent 'tier two' '- [ ] fix the tier two row #tier/2'
  row agent-runtime agent 'unclear' '- [ ] fix something somewhere #tier/3'
  row agent-runtime agent 'started' '- [/] fix the started row #tier/3'
  row agent-runtime agent 'untagged' '- [ ] fix the untagged row'
  for k in 'requested row' 'decide: fold it' 'typed decide' 'pad run' 'waybar row' 'tier two' 'started' 'untagged'; do night_verdict "$k"; done
  night_verdict unclear unclear false

  run night_rows ''
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'requested row,unclear,untagged'
  fill
  assert_success
  assert_equal "$(night_keys)" 'requested row,untagged'
}

@test "night: at most 3 active, one an area: subtract or fix first, then observer rows, then oldest #high" {
  night_ready
  row agent-runtime agent 'add a panel' '- [ ] add a panel for y #high'
  row agent-runtime agent 'kpi: board_open' '- [ ] kpi: board_open past threshold #high'
  row agent-runtime agent 'add a column' '- [ ] add a column to z #high'
  row agent-runtime agent 'retire the timer' '- [ ] retire the dead timer #low'
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #low'
  row agent-runtime agent 'add w' '- [ ] add w #low'
  night_verdict 'add a panel'; night_verdict 'kpi: board_open'; night_verdict 'add a column'
  night_verdict 'retire the timer' timers; night_verdict 'retire the hook' timers; night_verdict 'add w'

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | paste -sd,)" 'retire the hook,kpi: board_open,add a column'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  [ "$(state_of 'retire the hook')" = '- [ ]' ] || fail "fill --dry-run started a row"
  fill
  assert_success
  assert_equal "$(night_keys)" 'add a column,kpi: board_open,retire the hook'
  [ "$(state_of 'add a panel')" = '- [ ]' ] || fail "a fourth row was started"
  fill
  assert_equal "$(agent-queue list --json --state queued | grep -c .)" 3
}

@test "night: a row agent-queue will not take is un-started again" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it'
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  stub agent-queue '[ "$1" = add ] && { echo "no room" >&2; exit 1; }; exec "$(dirname "$0")/agent-queue.real" "$@"'
  fill
  assert_output --partial 'could not queue agent-runtime row, un-started: gm-1'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "night: a cancelled night item (default profile, no profile: line) hands its row back" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it'
  fill
  [ "$(state_of 'fix it')" = '- [/]' ] || fail "row not started"
  [ -z "$(qfield "$(qitem queued gm-1)" profile)" ] || fail "fixture should carry no profile"
  agent-queue cancel gm-1
  run cmd_reap
  assert_output --partial 'un-started agent-runtime: gm-1 (queue item gm-1 ended cancelled)'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "night: a night item waits outside the night window, then starts --pr-only on the account room names" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it' hooks
  stub claude-acct '[ "$1" = room ] && echo "/acct/alt"; exit 0'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "app-agent-1"'
  export AGENT_QUEUE_NIGHT=01:00-06:00
  AGENT_QUEUE_NOW=12:00 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'no row qualifies'
  [ -n "$(qitem queued gm-1)" ] || fail "not queued for the night"
  assert_not_called 'wt new'
  AGENT_QUEUE_NOW=02:00 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/alt claude'
  assert_called '/one-shot --pr-only fix it'
  [ -n "$(qitem running gm-1)" ] || fail "night item not started in its window"
}

@test "night: the judge is asked for tier3_only on new rows, and keeps it" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  cat > "$NOTES_FIXTURE/judge.out" <<'J'
{"verdicts":[{"project": "agent-runtime", "lane": "agent", "key": "fix it", "tier": 3, "size": "S", "area": "hooks", "clear": true, "agent_only": true, "tier3_only": true, "verdict": "skip", "rule": "tier3", "reason": "tier 3"}]}
J
  fill
  assert_success
  assert_called 'judge called'
  assert_equal "$(night_keys)" 'fix it'
  [ "$(jq -r .tier3_only "$FLEET_DISPATCH_DIR/verdicts.jsonl")" = true ]
}

@test "fill --dry-run lists ready picks then unjudged rows, and never judges, claims or launches" {
  game_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load, high: fix crash on load [fleet, #high, beta]'
  assert_line --index 1 'unjudged  game (beta) human: add a new map'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run --json
  assert_equal "$(jq -r '"\(.state) \(.key)"' <<<"$output" | paste -sd, -)" 'ready fix crash on load,unjudged add a new map'
  assert_not_called 'judge called'
  assert_not_called 'wt new'
  assert_not_called 'start '
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "fill --dry-run queued an item"
}

@test "night: a run pass promotes night rows past a shut account gate and a full queue; a decision row and a dispatch hold stay out" {
  night_ready
  project game beta "$SANDBOX/repos/game"
  for n in 1 2 3 4; do agent-queue add --project game --slug "work-$n" --priority high "work $n" >/dev/null; done
  stub claude-acct '[ "$1" = room ] && { echo "claude-acct: no account has room under its weekly pace and after its live sessions" >&2; exit 1; }; exit 0'
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3'
  row agent-runtime agent 'decide: fold it' '- [ ] decide: fold it #tier/3'
  night_verdict 'wt done never reaps' wt
  night_verdict 'decide: fold it' fold

  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queued 1 for the night; '
  assert_equal "$(night_keys)" 'wt done never reaps'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'

  # Negative control: the same row under a dispatch hold is not promoted.
  row agent-runtime agent 'drop the dead timer' '- [ ] drop the dead timer #tier/3'
  night_verdict 'drop the dead timer' timer
  stub agent-hold 'echo "dispatch held"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(night_keys)" 'wt done never reaps'
}

@test "a pass whose judge fails still starts its queue item, and says it could not judge" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'could not judge the new rows'
  assert_called 'judge called'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  # The pass then tops the queue up from the board, where the failed judge is its last word.
  assert_equal "$(outcome)" FAILED
}

@test "policy_sig: a workers.json edit keeps every verdict fresh; a policy edit judges again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'judged' "- [ ] judged $T"
  verdict game agent 'judged' skip
  echo '{"fleet": {"max_tier": 1, "lane": "agent"}}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
  echo 'policy v3' > "$DISPATCH_POLICY"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'judged'
}

@test "judge shares a capped batch across projects: each project's best row, then each one's next" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":2}'
  assert_success
  # Rank alone would send p1, p2, p3 and never a1.
  assert_equal "$(grep -o '"key":"[a-z0-9]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd, -)" 'p1,a1,p2'
}

@test "run --dry-run never calls the judge and leaves verdicts.jsonl as it was" {
  game_ready
  night_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  row agent-runtime agent 'unjudged night' '- [ ] fix the unjudged night row #tier/3'
  cp "$FLEET_DISPATCH_DIR/verdicts.jsonl" "$SANDBOX/verdicts.before"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would queue: game (beta) human, fleet, fix crash on load'
  assert_not_called 'judge called'
  cmp -s "$SANDBOX/verdicts.before" "$FLEET_DISPATCH_DIR/verdicts.jsonl" || fail "a dry run wrote verdicts"
}

@test "gate names every closed gate, room's own reason included; a dispatch hold is the only answer when it holds" {
  stub claude-acct '[ "$1" = room ] && { echo "claude-acct: no account has room under its weekly pace and after its live sessions" >&2; exit 1; }; exit 0'
  echo '99.00 99.00 99.00 1/1 1' > "$DISPATCH_LOADAVG"
  run gate
  assert_output --regexp '^no account has room under its weekly pace and after its live sessions; load 99.00 on [0-9]+ cores is over the [0-9.]+ pace$'
  stub claude-acct 'exit 2'
  run gate
  assert_output --partial 'account usage unreadable; load 99.00'
  stub agent-hold 'exit 1'
  run gate
  assert_output 'held (agent-hold dispatch)'
}

# --- the queue ---------------------------------------------------------------------------

qfield() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1"; }
qitem() { ls "$AGENT_QUEUE_DIR"/"$1"/*-"$2".md 2>/dev/null; }

@test "run starts the queue head before any board row, on its repo, and the item records the session" {
  game_ready
  agent-queue add --project game --slug low-one --priority low "low"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_not_called 'ptask game start fix crash on load'
  f=$(qitem running fix-menu)
  [ -n "$f" ] || fail "fix-menu is not running"
  assert_equal "$(qfield "$f" session)" lab:game-agent-1
  assert_equal "$(qfield "$f" account)" main
  [ -n "$(qitem queued low-one)" ] || fail "only one start a pass"
}

@test "a run start logs its model-lane pick and stamps lane_run on the item, at the dispatch floor" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-7 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called 'model-lane classify Fix the menu sides --floor sonnet'
  assert_called 'claude --model sonnet'
  assert_called 'model-lane log --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" lane_run)" 'sonnet run-7'
}

@test "a failing model-lane still starts the item, on opus, with no lane_run" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called 'claude --model opus'
  assert_not_called 'model-lane log'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run that was never logged"
}

@test "a queue item runs /one-shot in bypass mode, a night item --pr-only, a plan item in plan mode" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug n --tags night "do n"
  agent-queue add --project game --slug p --mode plan "plan p"
  for s in a n p; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial 'AGENT_QUEUE_ITEM=a env -u CLAUDE_CONFIG_DIR claude --model opus --permission-mode bypassPermissions'
  assert_output --partial '/one-shot do a'
  assert_output --partial '/one-shot --pr-only do n'
  assert_output --partial 'AGENT_QUEUE_ITEM=p env -u CLAUDE_CONFIG_DIR claude --model opus --permission-mode plan --allow-dangerously-skip-permissions'
  refute_output --partial '/one-shot plan p'
  # An item with no board row still names itself in its PR body, and names no Task line.
  assert_output --partial 'The PR body carries the line "Item: a".'
}

@test "start --item waits for the new claude's mode footer, answering a trust prompt, and says when it never shows" {
  project game beta "$SANDBOX/repos/game"
  stub claude-acct '[ "$1" = trust ] && { echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"; exit "$(cat "$NOTES_FIXTURE/trust.rc" 2>/dev/null || echo 0)"; }; exit 0'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug p --mode plan "plan p"
  cmd_start --item a >/dev/null || fail "start a"
  echo 1 > "$NOTES_FIXTURE/trust.rc"
  run cmd_start --item p
  assert_success
  assert_output --partial 'game-agent-1: claude did not show "plan mode on"; look at its pane'
  assert_called 'claude-acct trust lab =game-agent-1: bypass permissions on'
  assert_called 'claude-acct trust lab =game-agent-1: plan mode on'
  [ -n "$(qitem running p)" ] || fail "p is running even when its footer never showed"
}

@test "start --item refuses an item that is not queued, and a failed launch leaves it queued" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug a "do a"
  stub wt 'exit 1'
  run cmd_start --item a
  assert_failure
  [ -n "$(qitem queued a)" ] || fail "a left queued/"
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'no queue item: nope'
}

@test "the human's queue item starts while the human is here, past a board-filled one the spent trickle holds" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  export DISPATCH_PRESENT_PER_HOUR=0
  agent-queue add --project game --slug from-board --from board:game:x "x"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  agent-queue add --project game --slug mine "mine"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: mine'
}

@test "a queue item still waits on every other gate, and a dry run names it and starts nothing" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held (agent-hold dispatch), queue item mine waits'
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would start queue item mine: game oneshot high'
  assert_not_called 'wt new'
  [ -n "$(qitem queued mine)" ] || fail "dry run moved the item"
}

@test "reap closes a queue item whose session ended: ok with a PR, failed without; a closed one is left alone" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug b "do b"
  agent-queue add --project game --slug c "do c"
  stub wt 'echo "game-$WT_N"'
  for s in a b c; do WT_N=$s cmd_start --item "$s" >/dev/null; done
  agent-queue set a pr=12
  agent-queue move c done --status ok
  printf 'game-c\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  assert_success
  assert_output --partial 'failed queue item b'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-a.md)" status)" ok
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-b.md)" status)" failed
}

# pr_item <state> -- a board item on a gone session, its PR o/game#12 in <state> per the gh stub,
# its row started, and the project's checkout a real clone whose origin/main holds one commit (OID).
pr_item() {
  git init -q --bare "$SANDBOX/origin.git"
  git -c init.defaultBranch=main init -q "$SANDBOX/repos/game"
  git -C "$SANDBOX/repos/game" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix crash (#12)"
  git -C "$SANDBOX/repos/game" remote add origin "$SANDBOX/origin.git"
  git -C "$SANDBOX/repos/game" push -q origin HEAD:main
  OID=$(git -C "$SANDBOX/repos/game" rev-parse HEAD)
  project game beta "$SANDBOX/repos/game"
  row game agent 'fix crash' '- [/] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  agent-queue set fix-crash pr=o/game#12 lane=agent >/dev/null
  printf '%s %s\n' "$1" "${2:-$OID}" > "$NOTES_FIXTURE/pr.state"
  stub gh 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ -s "$NOTES_FIXTURE/pr.state" ] || exit 1; cat "$NOTES_FIXTURE/pr.state"'
}

@test "reap: a gone session's merged PR closes the item ok with merged:, and its started row on merge proof" {
  pr_item MERGED
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
  # The reap and the settle are on the chain log, as the runner's own writes.
  run grep -o 'stage dispatch --action [a-z]* --from game --item fix-crash.* -- .*' "$NOTES_FIXTURE/calls.log"
  assert_output - <<OUT
stage dispatch --action reaped --from game --item fix-crash --why item was running --by fleet-dispatch -- session game-agent-1 gone
stage dispatch --action settled --from game --item fix-crash --id fix crash --pr o/game#12 --sha $OID --by fleet-dispatch -- row closed on merge proof
OUT
}

@test "reap: a merged PR whose commit is not on origin/main closes the item but never the row" {
  pr_item MERGED 0123456789abcdef0123456789abcdef01234567
  run cmd_reap
  assert_success
  refute_output --partial 'closed game'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" ok
  run grep -c 'ptask .* done ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  grep -q 'row left started, no merge proof' "$FLEET_DISPATCH_DIR"/log.md || fail "no reason logged"
}

@test "reap: a gone session's open PR moves its item to waiting once, row untouched" {
  pr_item OPEN
  run cmd_reap
  assert_output --partial 'waiting queue item fix-crash (PR o/game#12 open'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" waiting
  run cmd_reap
  refute_output --partial 'waiting queue item'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" waiting
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row moved"
}

@test "reap: a gone session's closed PR fails its item and hands the row back" {
  pr_item CLOSED
  run cmd_reap
  assert_output --partial 'failed queue item fix-crash (PR o/game#12 closed unmerged)'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row still started"
}

@test "reap: an item moved while reap reads its PR is left as it is, no note written" {
  pr_item OPEN
  # gh answers after a human requeued the item: the move reap planned is from a state it no longer has.
  stub gh 'agent-queue move fix-crash queued >/dev/null; cat "$NOTES_FIXTURE/pr.state"'
  run cmd_reap
  assert_success
  refute_output --partial 'waiting queue item'
  f=$(qitem queued fix-crash)
  [ -n "$f" ] || fail "the requeue was undone"
  assert_equal "$(qfield "$f" note)" ''
}

@test "reap: a PR gh cannot read leaves the item where it is" {
  pr_item OPEN
  : > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_success
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" running
}

# ── orphan rows: started with no queue item ─────────────────────────────────
# orphan_seen <project> <key> <hours ago> -- reap first saw that agent row orphaned that long ago.
orphan_seen() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf 'bnb\t%s\t%s\t%s\n' "$1" "$2" "$(( $(date +%s) - $3 * 3600 ))" >> "$FLEET_DISPATCH_DIR/orphans.tsv"
}

@test "reap: an agent row started with no queue item is un-started only once it stays orphaned DISPATCH_ORPHAN_HOURS" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 '- [/] fix x <!-- id:gm-1 -->'
  run cmd_reap
  assert_success
  grep -qF -- '- [/] fix x' "$NOTES_FIXTURE/rows.game.agent" || fail "un-started on first sight"
  grep -qP '^bnb\tgame\tgm-1\t[0-9]+$' "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "first sighting not recorded"
  : > "$FLEET_DISPATCH_DIR/orphans.tsv"; orphan_seen game gm-1 73
  run cmd_reap
  assert_output --partial 'un-started game: gm-1'
  grep -qF -- '- [ ] fix x' "$NOTES_FIXTURE/rows.game.agent" || fail "row still started"
  assert_equal "$(jq -r 'select(.key == "gm-1") | .verdict + ": " + .reason' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'failed: started 72h with no queue item'
  ! grep -q gm-1 "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "un-started row still tracked"
}

@test "reap: a row an active item names, and a human-lane row, are never orphans" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-2 '- [/] linked <!-- id:gm-2 -->'
  row game human 'mine' '- [/] the human is on it'
  started_item linked lab:game-agent-9 '' '' 'board:game:gm-2' queued
  sed -i 's/^lane: human$/lane: agent/' "$AGENT_QUEUE_DIR"/queued/*-linked.md
  orphan_seen game gm-2 96
  run cmd_reap
  assert_success
  grep -qF -- '- [/] linked' "$NOTES_FIXTURE/rows.game.agent" || fail "a linked row was un-started"
  grep -qF -- '- [/] the human is on it' "$NOTES_FIXTURE/rows.game.human" || fail "a human row was un-started"
  [ ! -s "$FLEET_DISPATCH_DIR/orphans.tsv" ] || fail "tracked: $(cat "$FLEET_DISPATCH_DIR/orphans.tsv")"
}

@test "reap: a queue it cannot read un-starts no orphan" {
  export DISPATCH_NIGHT_PROFILE=bnb
  project game beta "$SANDBOX/repos/game"
  row game agent gm-3 '- [/] fix y <!-- id:gm-3 -->'
  orphan_seen game gm-3 96
  stub agent-queue 'exit 1'
  run cmd_reap
  grep -qF -- '- [/] fix y' "$NOTES_FIXTURE/rows.game.agent" || fail "un-started blind"
  grep -q gm-3 "$FLEET_DISPATCH_DIR/orphans.tsv" || fail "first sighting lost"
}

@test "reap: a session several Claudes share says nothing about one item, so it never flips to waiting and a false waiting comes back" {
  started_item shared-1 hub:dotfiles
  started_item shared-2 hub:dotfiles '' '' human waiting
  started_item alone lab:game-agent-1
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'printf "%s\n" "{\"target\":\"hub/dotfiles:1\",\"status\":\"waiting\"}" "{\"target\":\"hub/dotfiles:2\",\"status\":\"busy\"}" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"waiting\"}" "{\"target\":\"lab/game-agent-1:2\",\"status\":\"shell\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem running shared-1)" ] || fail "a shared session flipped its item to waiting"
  [ -n "$(qitem running shared-2)" ] || fail "a false waiting on a shared session stayed"
  # Negative control: a shell window does not make a session shared, so its one Claude still counts.
  [ -n "$(qitem waiting alone)" ] || fail "a session with one Claude stopped reading as waiting"
}

# --- starved -----------------------------------------------------------------------------

# queued_item <slug> <priority> <queued> [tags] [after]
queued_item() {
  local d="$AGENT_QUEUE_DIR/queued"; mkdir -p "$d"
  {
    printf 'slug: %s\nproject: game\nmode: oneshot\npriority: %s\nfrom: human\nagent: claude\nqueued: %s\n' "$1" "$2" "$3"
    [ -z "${4:-}" ] || printf 'tags: %s\n' "$4"
    [ -z "${5:-}" ] || printf 'after: %s\n' "$5"
    printf -- '---\n%s\n' "$1"
  } > "$d/20261103-100000-$1.md"
}

@test "starved: an urgent or high item runnable over the limit with no run start in that time fails and names it; holds, low, new, a recent run start and a dispatch hold do not, a hand start does not clear it" {
  local old new
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item fresh urgent "$new"
  queued_item low-old low "$old"
  queued_item tagged-old high "$old" at:23:59
  queued_item after-old urgent "$old" '' never-done
  run cmd_starved
  assert_success
  assert_output ''
  queued_item stuck high "$old"
  . "$HOME/.local/lib/agent-proof.sh"; mkdir -p "$(proof_state_dir)/fleet-dispatch"
  [[ "$(proof_state_dir)" == "$HOME"/* || "$(proof_state_dir)" == "$SANDBOX"/* ]]   # never the live state dir
  echo '[t] outcome=NOOP load 30 on 24 cores is over the 0.7 pace' > "$(proof_state_dir)/fleet-dispatch/activity.log"
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  assert_output --partial 'last pass: [t] outcome=NOOP load 30'
  refute_output --partial 'fresh'
  refute_output --partial 'low-old'
  refute_output --partial 'tagged-old'
  refute_output --partial 'after-old'
  # A queue the passes are moving is not starved: a run start in the window clears it; a
  # redispatch or a hand start does not, since neither proves the run pass works.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (redispatch) for game: queue item x, resume 1\n' "$(date '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item other\n' "$(date -d '-2 hours' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_output --partial 'last run start: '"$(date -d '-2 hours' '+%Y-%m-%d')"
  printf -- '- %s started game-agent-2 on lab (hand) for game: queue item other2\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # The load gates are fleet-thermal's alarm, so they hold rather than starve; any other gate trips.
  run cmd_starved
  assert_failure
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (load 30.00 on'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
  # Load plus any other closed gate is not held by load: it still starves.
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  stub claude-acct '[ "$1" = room ] && exit 1; exit 0'
  run cmd_starved
  assert_failure
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub claude-acct 'exit 0'
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  stub claude-acct 'exit 1'
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  stub claude-acct 'exit 0'
  stub agent-hold 'exit 1'
  run cmd_starved
  assert_success
  assert_output --partial 'dispatch is held'
}

# board_item <slug> <queued>: a queued high item promoted from a board row
board_item() {
  queued_item "$1" high "$2"
  sed -i "s/^from: human/from: board:game:$1/" "$AGENT_QUEUE_DIR/queued/20261103-100000-$1.md"
}

# 2026-11-05: 220 rows sat unjudged since 11-02 while every pass stopped at held queue items.
@test "starved: board rows nobody judged while the human was away that long trip it; a recent judge or a short absence does not" {
  game_ready
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  stub fleet-presence 'echo "away 90 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial '1 board rows unjudged, none judged since never'
  # Away for less than the window: the first pass has not had its turn yet.
  stub fleet-presence 'echo "away 10 tmux"'
  run cmd_starved
  assert_success
  # The human is here: the board waits for them to leave, by design.
  stub fleet-presence 'echo "here 0 tmux"'
  run cmd_starved
  assert_success
  # A judge inside the window: the board is turning.
  stub fleet-presence 'echo "away 90 tmux"'
  verdict game human 'fix crash on load' dispatch
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"; mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_success
  # An old judge and an unjudged row: starved again.
  touch -d '-2 hours' "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_failure
  assert_output --partial '1 board rows unjudged, none judged since '"$(date -d '-2 hours' +%Y-%m-%d)"
}

@test "starved: a board item waits out the human's presence once the trickle is spent, and counts from when they left" {
  local old
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  board_item gm-1 "$old"
  stub fleet-presence 'echo "here 0 tmux"'
  DISPATCH_PRESENT_PER_HOUR=0 run cmd_starved
  assert_success
  assert_output ''
  # With the trickle open the item could start while they are here, so two hours unstarted is starved.
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
  stub fleet-presence 'echo "away 5 tmux"'
  run cmd_starved
  assert_success
  assert_output ''
  stub fleet-presence 'echo "away 90 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
  # Nobody attached or logged in: away with no minutes, so the item counts from when it was queued.
  stub fleet-presence 'echo "away - none"'
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
}

@test "starved: runnable under the low water with a row a pass would pick and no run start in twice the limit trips it; a recent start, low water 0 or nothing to pick does not" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial 'runnable 0 under the low water 3 with no run start since'
  assert_output --partial '1 board row(s) a pass would pick'
  DISPATCH_LOW_WATER=0 run cmd_starved
  assert_success
  # A run start 90 minutes ago: past the item limit but inside twice it, so the top-up is turning.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item x\n' "$(date -d '-90 min' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # Nothing a pass would pick: the row was judged a skip.
  verdict game human 'fix crash on load' skip
  run cmd_starved
  assert_success
}

@test "stats: the low water, whether runnable is under it, and the present trickle's starts this hour" {
  local new
  new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item one high "$new"
  mkdir -p "$FLEET_DISPATCH_DIR"
  { printf -- '- %s present start: queue item a (DISPATCH_PRESENT_PER_HOUR=1)\n' "$(date -d '-10 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s present start: queue item b (DISPATCH_PRESENT_PER_HOUR=1)\n' "$(date -d '-70 min' '+%Y-%m-%d %H:%M')"; } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{low_water, under_low_water, present_per_hour, present_starts_1h}' <<<"$output")" \
    '{"low_water":3,"under_low_water":1,"present_per_hour":1,"present_starts_1h":1}'
  DISPATCH_LOW_WATER=1 run cmd_stats
  assert_equal "$(jq -c '.under_low_water' <<<"$output")" 0
}

@test "stats: runnable work and its age, reap moves in the last hour, flapping items" {
  local old new t
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck high "$old"
  queued_item low-new low "$new"
  queued_item after-old urgent "$old" '' never-done   # held by its after:, so not runnable
  mkdir -p "$FLEET_DISPATCH_DIR"
  t() { date -d "-$1 minutes" '+%Y-%m-%d %H:%M'; }
  {
    printf -- '- %s started game-agent-1 on lab (run) for game: queue item old\n' "$(t 120)"
    printf -- '- %s reaped game-agent-1: queue item old running -> waiting\n' "$(t 110)"
    printf -- '- %s started game-agent-2 on lab (run) for game: queue item a\n' "$(t 40)"
    printf -- '- %s started game-agent-3 on lab (hand) for game: queue item b\n' "$(t 30)"
    printf -- '- %s started game-agent-4 on lab (redispatch) for game: queue item c, resume 1\n' "$(t 20)"
    for m in 45 30 15; do printf -- '- %s reaped game-agent-3: queue item b running -> waiting\n' "$(t $m)"; done
    printf -- '- %s reaped game-agent-2: queue item a waiting -> running\n' "$(t 10)"
    printf -- '- %s reaped game-agent-9: session gone, queue item z done with PR 7\n' "$(t 5)"
  } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable, .runnable_urgent, .starved]' <<<"$output")" '[2,1,false]'
  assert_equal "$(jq -c '[.reaped_1h, .flapping_items, .flapping]' <<<"$output")" '[5,1,["b"]]'
  # The oldest runnable item is the 2h one, give or take the test's own runtime.
  jq -e '.oldest_runnable_s >= 7190 and .oldest_runnable_s <= 7300 and .oldest_urgent_s == .oldest_runnable_s' <<<"$output"
  jq -e '.last_run_start_epoch != null' <<<"$output"
  # The whole queue rides along, as agent-queue counts it: 3 queued, 1 held after a phase.
  assert_equal "$(jq -c '[.queued, .held, .held_after, .held_pr, .held_time, .running, .waiting]' <<<"$output")" '[3,1,1,0,0,0,0]'
  jq -e '.done_6h == 0 and .added_6h == 3' <<<"$output"
  # Only numbers, booleans and the one list, so mqtt2prom keeps every fact it needs.
  assert_equal "$(jq -c '[to_entries[] | select(.value | type == "string")] | length' <<<"$output")" 0
}

@test "a real pass leaves its headroom for stats; a dry pass, or one older than three passes, gives none" {
  two_items
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  [ ! -e "$FLEET_DISPATCH_DIR/headroom.json" ] || fail "a dry pass wrote the snapshot"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(jq -r '[.could_start, .runnable] | @tsv' "$FLEET_DISPATCH_DIR/headroom.json")" $'1\t1'
  run cmd_stats
  assert_equal "$(jq -r .could_start <<<"$output")" 1
  assert_equal "$(jq -c '[.room_live_runs, .room_max_live, .room_live_hand, .room_held_slots, .room_held_load]' <<<"$output")" '[0,6,0,0,0]'
  touch -d '-46 minutes' "$FLEET_DISPATCH_DIR/headroom.json"
  run cmd_stats
  assert_equal "$(jq -c '[.could_start, .room_max_live]' <<<"$output")" '[null,null]'
}

@test "stats fails, saying so, when the queue is unreadable" {
  stub agent-queue 'exit 1'
  run cmd_stats
  assert_failure
  assert_output '{"error":"agent-queue unreadable"}'
}

@test "start --resume --window opens a window of a live session, keeps a plan mode, and leaves its label alone" {
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "new-window -d -P -F #{pane_id} -t =dotfiles: -n crash -c $SANDBOX/repos/game env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume abc-123"
  assert_not_called 'new-session'
  assert_not_called 'set-option'
}

@test "start --resume --window makes the session when it is not there yet, named as asked" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called "new-session -d -s dotfiles -n crash -c $SANDBOX/repos/game env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume abc-123"
}

# world <instance> <pane lines...> -- what a stub server answers; no instance is a server that is down.
world() {
  printf '%s' "$1" > "$NOTES_FIXTURE/world.instance"; shift
  printf '%s\n' "$@" > "$NOTES_FIXTURE/world.panes"
}

record_setup() {
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR" "$HOME/.claude/sessions"
  : > "$TMUX_SERVERS_DIR/hub.conf"
  stub tmux 'case "$*" in
    *display-message*) [ -s "$NOTES_FIXTURE/world.instance" ] || exit 1; cat "$NOTES_FIXTURE/world.instance"; echo ;;
    *list-panes*) cat "$NOTES_FIXTURE/world.panes" ;;
  esac'
  stub agent-notify 'echo "agent-notify $*" >> "$NOTES_FIXTURE/calls.log"'
  stub agent-panel 'cat "$NOTES_FIXTURE/panel.json"'
  echo '{"pane":"hub/%1","session_id":"conv-1","cwd":"/work/tree"}' > "$NOTES_FIXTURE/panel.json"
  PANE1=$'%1\037dotfiles\037crash\037/shell/dir' PANE2=$'%2\037dotfiles\037zsh\037/plain/dir'
  RECORD="$FLEET_DISPATCH_DIR/panes/hub.json" LOST="$FLEET_DISPATCH_DIR/panes/hub.lost.json"
}

@test "record keeps each pane's session, window and cwd, with the conversation found under the pane" {
  record_setup
  world '10 1000' "$PANE1" "$PANE2"
  echo '{"pane":"lab/%2","session_id":"another-world","cwd":"/x"}' >> "$NOTES_FIXTURE/panel.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_equal "$(jq -c '[.server, .instance]' "$RECORD")" '["hub","10 1000"]'
  assert_equal "$(jq -c '.panes[0]' "$RECORD")" '{"session":"dotfiles","window":"crash","cwd":"/work/tree","claude":"conv-1"}'
  assert_equal "$(jq -c '.panes[1]' "$RECORD")" '{"session":"dotfiles","window":"zsh","cwd":"/plain/dir","claude":""}'
  assert_not_called 'agent-notify'
}

@test "record keeps the last record when agent-panel fails, and still sees a server die" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  stub agent-panel 'exit 1'
  world '10 1000' "$PANE2"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_output --partial 'agent-panel failed'
  assert_equal "$(jq -r '.panes[0].claude' "$RECORD")" conv-1
  world ''
  "$REPO_ROOT/.local/bin/fleet-dispatch" record 2>/dev/null
  assert_called 'tmux hub server died 1 conversation(s)'
  [ -f "$LOST" ] || fail "record not kept as lost"
}

@test "record pages once when a server dies and keeps its last record for restore" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_success
  assert_called 'agent-notify -p high -t tmux hub server died 1 conversation(s) were on it'
  [ -f "$LOST" ] && [ ! -f "$RECORD" ] || fail "record not kept as lost"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_equal "$(grep -c 'agent-notify' "$NOTES_FIXTURE/calls.log")" 1
}

@test "record sees a server restarted between two records, and a later empty death keeps the lost record" {
  record_setup
  world '10 1000' "$PANE1"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  world '11 2000' "$PANE2"
  "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_called 'tmux hub server died 1 conversation(s)'
  assert_equal "$(jq -r '.panes[0].claude' "$LOST")" conv-1
  assert_equal "$(jq -r .instance "$RECORD")" '11 2000'
  world ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_called 'tmux hub server died 0 conversation(s)'
  assert_equal "$(jq -r '.panes[0].claude' "$LOST")" conv-1
  [ ! -f "$RECORD" ] || fail "an empty record stayed"
}

# lost_pane <window> <cwd> <id> -- one more pane on the lost hub record.
lost_pane() {
  local f="$FLEET_DISPATCH_DIR/panes/hub.lost.json"
  mkdir -p "${f%/*}"
  [ -f "$f" ] || echo '{"server":"hub","instance":"1 1","panes":[]}' > "$f"
  jq --arg w "$1" --arg c "$2" --arg i "$3" '.panes += [{session: "dotfiles", window: $w, cwd: $c, claude: $i}]' "$f" > "$f.new"
  mv "$f.new" "$f"
}

transcript() {
  mkdir -p "$HOME/.claude/projects/some-project"
  printf '%s\n' "$2" > "$HOME/.claude/projects/some-project/$1.jsonl"
}

restore_setup() {
  project game beta "$SANDBOX/repos/game"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR" "$HOME/.claude/sessions" "$HOME/.agent/spin-down"
  stub tmx 'echo "tmx $*" >> "$NOTES_FIXTURE/calls.log"'
  stub agent-panel 'exit 0'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
}

@test "restore reopens each conversation in its last mode and skips what must not come back" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane planned "$G" conv-plan
  lost_pane working "$G" conv-work
  lost_pane armed "$G" conv-armed
  lost_pane closed "$G" conv-closed
  lost_pane alive "$G" conv-alive
  lost_pane moved "$SANDBOX/no-such-dir" conv-moved
  lost_pane shell "$G" ''
  transcript conv-plan '{"permissionMode":"bypassPermissions"}
{"type":"permission-mode","permissionMode":"plan"}'
  transcript conv-work '{"permissionMode":"bypassPermissions"}'
  : > "$HOME/.agent/spin-down/game__conv-armed.request"
  : > "$HOME/.agent/spin-down/game__conv-closed.fired"
  printf '{"pid":%s,"sessionId":"conv-alive"}' "$$" > "$HOME/.claude/sessions/$$.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_called 'tmx ensure hub'
  assert_called "-n planned -c $G env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan"
  assert_called "-n working -c $G env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-work"
  for skipped in conv-armed conv-closed conv-alive conv-moved; do assert_not_called "--resume $skipped"; done
  assert_output --partial 'hub:dotfiles:armed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:closed: wound down on purpose, skipped'
  assert_output --partial 'hub:dotfiles:alive: already running, skipped'
  assert_output --partial 'claude --resume conv-moved'
  assert_output --partial 'hub:dotfiles:shell: no conversation, not reopened'
  assert_output --partial 'hub: reopened 2, failed 0'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.restored.json" ] && [ ! -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] ||
    fail "a finished restore left its record"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_output --partial 'no lost server on record'
}

@test "restore reopens a conversation with the queue item that lists it, and a joined window takes no session" {
  restore_setup
  G="$SANDBOX/repos/game"
  lost_pane working "$G" conv-item
  CLAUDE_CODE_SESSION_ID=conv-item agent-queue add --project game --running --slug hub-work "hub work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_success
  assert_output --partial 'hub:dotfiles:working: reopened in bypassPermissions for queue item hub-work'
  assert_called "-n working -c $G AGENT_QUEUE_ITEM=hub-work env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-item"
  f=$(qitem running hub-work)
  assert_equal "$(qfield "$f" origin)" resume
  assert_equal "$(qfield "$f" session)" ''
}

@test "restore keeps the record when a reopen fails, so a rerun finishes it" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  stub tmux 'case "$*" in *new-window*) exit 1 ;; *has-session*) exit 0 ;; esac'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore
  assert_failure
  assert_output --partial 'hub: reopened 0, failed 1'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] || fail "lost the record"
}

@test "restore --dry-run says what it would do and touches nothing" {
  restore_setup
  lost_pane one "$SANDBOX/repos/game" conv-1
  transcript conv-1 '{"permissionMode":"plan"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" restore --dry-run
  assert_success
  assert_output --partial "would reopen conv-1 in $SANDBOX/repos/game (plan)"
  assert_not_called 'tmx ensure'
  assert_not_called '--resume'
  [ -f "$FLEET_DISPATCH_DIR/panes/hub.lost.json" ] || fail "a dry run consumed the record"
}
