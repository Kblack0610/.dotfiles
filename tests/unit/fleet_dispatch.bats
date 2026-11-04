#!/usr/bin/env bats
# fleet-dispatch: which rows may start an unattended session, and the bookkeeping around it.
# Everything that could launch, claim or judge is a stub; calls.log records what it would do.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_DISPATCH_DIR="$HOME/.agent/dispatch"
  export DISPATCH_PROFILES=bnb DISPATCH_SERVER=lab
  export DISPATCH_PROJECT_MAP="$SANDBOX/map.json"
  export DISPATCH_POLICY="$SANDBOX/policy.md"
  export DISPATCH_WORKERS="$SANDBOX/workers.json"
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  export DISPATCH_LOADAVG="$SANDBOX/loadavg"
  export DISPATCH_JUDGE_CMD=judge-stub   # on PATH: the command is a word list, and the sandbox path has a space
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  echo 'policy' > "$DISPATCH_POLICY"
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
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$DISPATCH_PROJECT_MAP" AGENT_QUEUE_START=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# started_item <slug> <session> [origin] [area] [from] [state] [project] -- a started queue item on
# that session (<server>:<name>, or a bare name on lab): the one record of a running session.
started_item() {
  local d="$AGENT_QUEUE_DIR/${6:-running}"; mkdir -p "$d"
  {
    printf 'slug: %s\nproject: %s\nmode: oneshot\npriority: normal\nfrom: %s\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n' "$1" "${7:-game}" "${5:-human}"
    printf 'started: 2026-11-03T10:00:00Z\nsession: %s\n' "$2"
    [ -z "${3:-}" ] || printf 'origin: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'area: %s\n' "$4"
    [[ "${5:-}" != board:* ]] || printf 'lane: human\nprofile: bnb\n'
    printf -- '---\n%s\n' "$1"
  } > "$d/20261103-100000-$1.md"
}

# A notes stand-in with state: rows.<project>.<lane> holds "key<TAB>raw line", and `start`
# toggles the first open row whose key contains the query, as the real CLI does.
stub_notes() {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
F="$NOTES_FIXTURE"; printf 'notes %s\n' "$*" >> "$F/calls.log"
args=(); lane=human
while [ $# -gt 0 ]; do
  case "$1" in --profile) shift 2 ;; --agent) lane=agent; shift ;; *) args+=("$1"); shift ;; esac
done
case "${args[0]}" in
  projects) cat "$F/projects" 2>/dev/null ;;
  ptask)
    p="${args[1]}"; f="$F/rows.$p.$lane"; [ -f "$f" ] || exit 0
    case "${args[2]}" in
      list) awk -F'\t' -v f="$f" '$2 ~ /^- \[[ \/]\]/ { print f "\t" NR "\t" $1 "\t" $2 }' "$f" ;;
      start) q="${args[3]}"
        awk -F'\t' -v OFS='\t' -v q="$q" '!done && index($1, q) && $2 ~ /^- \[[ \/]\]/ {
            if ($2 ~ /^- \[ \]/) sub(/^- \[ \]/, "- [/]", $2); else sub(/^- \[\/\]/, "- [ ]", $2); done = 1 }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
    esac ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
}

# project <name> <stage> <repo-dir|-> : a sheet, a registry entry, and a projects line
project() {
  printf 'Version: v1.0.0 #%s\n' "$2" > "$SANDBOX/sheets/$1.md"
  printf '%s\t%s\t\tv1.0.0\n' "$1" "$SANDBOX/sheets/$1.md" >> "$NOTES_FIXTURE/projects"
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

@test "candidates: the asks worker takes only #ask rows, only in its project, never tier 3" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  echo '{"asks": {"max_tier": 9, "projects": ["game"], "only_tag": "ask"}}' > "$DISPATCH_WORKERS"
  row game agent 'real ask' '- [ ] real ask #ask #worker/asks #tier/2'
  row game agent 'tagged no ask' '- [ ] tagged no ask #worker/asks #tier/2'
  row game agent 'lookalike' '- [ ] lookalike #asks #worker/asks #tier/2'
  row game agent 'tier three' '- [ ] tier three #ask #worker/asks #tier/3'
  row game agent 'other worker' '- [ ] other worker #ask #worker/fleet #tier/1'
  row app agent 'wrong project' '- [ ] wrong project #ask #worker/asks #tier/2'

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
  started_item other-work game-agent-3 run
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
}

board_workers() {
  echo '{"asks": {"max_tier": 2, "projects": ["game"], "only_tag": "ask"},
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

@test "the shipped registry: asks, then the human's assignments, then the game's agent board, never tier 3" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json"
  project unity-playground beta "$SANDBOX/repos/game"
  project platform prod "$SANDBOX/repos/app"
  row unity-playground agent 'an ask' '- [ ] an ask #ask #worker/asks #tier/2'
  row unity-playground agent 'assigned' "- [ ] assigned $T"
  row unity-playground agent 'plain' '- [ ] plain'
  row unity-playground agent 'tier three' '- [ ] tier three #tier/3'
  row unity-playground human 'human plain' '- [ ] human plain'
  row platform agent 'platform plain' '- [ ] platform plain'
  run cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.wrank) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'an ask=asks,assigned=fleet,plain=board'
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
  started_item other-work game-agent-3 run wilds
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

@test "judge asks for an area and keeps it" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" DISPATCH-VERDICTS-START "{\"project\":\"p\",\"lane\":\"agent\",\"key\":\"k\",\"verdict\":\"skip\",\"area\":\"wilds\"}" DISPATCH-VERDICTS-END'
  run judge '{"project":"p","stage":"beta","lane":"agent","key":"k","text":"- [ ] k","prio":2}'
  assert_success
  assert_equal "$(jq -r .area "$FLEET_DISPATCH_DIR/verdicts.jsonl")" wilds
  grep -q '"area"' "$NOTES_FIXTURE/prompt" || fail "the prompt does not ask for an area"
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

@test "judge keeps well-formed verdicts between the markers and drops the rest" {
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
thinking out loud {"project":"x"}
DISPATCH-VERDICTS-START
{"project":"game","lane":"human","key":"fix crash","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","reason":"small bug"}
not json
{"project":"game","lane":"human","key":"other","verdict":"maybe"}
DISPATCH-VERDICTS-END
EOF
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","tier":1,"line":"abc"}'
  assert_success
  assert_equal "$(wc -l < "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 1
  assert_equal "$(jq -r '"\(.verdict) \(.tier) \(.line) \(.policy == "'"$(policy_sig)"'")"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'dispatch 1 abc true'
}

@test "judge fails loudly when the model returns no verdicts at all" {
  echo 'UserPromptSubmit operation blocked by hook' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  assert_failure
  assert_output --partial 'no verdicts for 1 row(s)'
}

@test "judge runs the model call outside the caller's directory and cleans up after it" {
  stub judge-stub 'pwd > "$NOTES_FIXTURE/judge.cwd"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  echo 'no markers' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  cwd=$(cat "$NOTES_FIXTURE/judge.cwd")
  [ "$cwd" != "$PWD" ]
  [ ! -e "$cwd" ]
}

@test "judge sends prod rows before alpha rows when the batch is capped" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" DISPATCH-VERDICTS-START "{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\"}" DISPATCH-VERDICTS-END'
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":2}'
  assert_success
  run grep -c '"project":"p"' "$NOTES_FIXTURE/prompt"
  assert_output 1
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 0
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
  assert_output --partial 'would queue: game (beta) human, fleet, fix crash on load: fix crash on load'
  assert_not_called 'wt new'
  assert_not_called 'start fix crash'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/running" 2>/dev/null)" ] || fail "dry run queued an item"
}

@test "run fills the queue from the board, then starts that item on a detached lab session" {
  game_ready
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued game: fix crash on load'
  assert_output --partial 'started game-agent-1'
  assert_called 'ptask game start fix crash on load'
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  f=$(qitem running fix-crash-on-load)
  [ -n "$f" ] || fail "the promoted item is not running"
  assert_equal "$(qfield "$f" from)" 'board:game:fix crash on load'
  assert_equal "$(qfield "$f" priority) $(qfield "$f" lane) $(qfield "$f" profile) $(qfield "$f" area)" 'low human bnb fix crash on load'
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" model)" 'lab:game-agent-1 run opus'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  # The session lands through agent-land, which closes the item and its row: the brief names no ptask.
  assert_called 'Merge with agent-land <N> (AGENT_QUEUE_ITEM=fix-crash-on-load is set)'
  assert_called 'promoted from the board row "fix crash on load"'
  run grep -c 'ptask game done' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_called 'tmux -L lab set-option -t =game-agent-1: @dispatch game: fix-crash-on-load'
  [ ! -e "$FLEET_DISPATCH_DIR/live" ] || fail "wrote the retired dispatch/live ledger"
  # The session holds a runner slot on its area, read from the item alone.
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output 'game/fix crash on load'
}

@test "fill promotes picks into the queue with no gate and starts nothing; --dry-run lists them" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run
  assert_success
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load: fix crash on load'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial 'queued game: fix crash on load'
  [ -n "$(qitem queued fix-crash-on-load)" ] || fail "not queued"
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
  agent-queue cancel fix-crash-on-load
  run cmd_reap
  assert_success
  assert_output --partial 'un-started game: fix crash on load (queue item fix-crash-on-load ended cancelled)'
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
  assert_output --partial 'queued game: fix crash on load'
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
    --row 'tidy the loader' --server default --brief "$SANDBOX/brief.md"
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "run starts nothing while the human is here, and says who saw them" {
  game_ready
  stub fleet-presence 'echo "here 3 desktop"'
  refuses 'not away (here 3 desktop)'
}

@test "run starts nothing while presence cannot be read" {
  game_ready
  stub fleet-presence 'echo "unread - hypridle"'
  refuses 'not away (unread - hypridle)'
  stub fleet-presence 'exit 2'
  refuses 'not away (fleet-presence unreadable)'
}

@test "run starts nothing while a shared fault is firing, one rule at a time" {
  game_ready
  local rule
  for rule in starved throughput-drop blind; do
    stub fleet-bench "jq -cn --argjson e \$(date +%s) '{rule: \"$rule\", scope: \"pool:unity\", epoch: \$e}'"
    refuses "finding firing: $rule pool:unity"
  done
}

@test "run starts nothing on a blind row that carries no time" {
  game_ready
  stub fleet-bench "echo '{\"rule\":\"blind\",\"scope\":\"sampler\"}'"
  refuses 'finding firing: blind sampler'
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
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'not away (here 0 tmux)'
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
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" NOOP
  rm -f "$HOME/.local/state/agentctl/fleet-dispatch/last-outcome"
  stub fleet-presence 'echo "away 45 tmux"'
  : > "$NOTES_FIXTURE/rows.game.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'no row qualifies'
  assert_equal "$(outcome)" NOOP
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
  echo 'no markers' > "$NOTES_FIXTURE/judge.out"
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
  assert_output --partial 'live dispatched sessions'
  assert_not_called 'wt new'
}

# --- reap --------------------------------------------------------------------------------

@test "reap fails a board item whose session ended without closing it, un-starts its row, records failed" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  started_item fix-crash game-agent-1 run '' 'board:game:fix crash'
  run cmd_reap
  assert_success
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl")" failed
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)" status)" failed
}

@test "reap leaves a board item its session closed ok, and its row, alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [x] fix crash'
  started_item fix-crash game-agent-1 run '' 'board:game:fix crash'
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
  started_item fix-crash game-agent-1 run
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  assert_success
  [ -n "$(qitem running fix-crash)" ] || fail "moved a working session's item"
  assert_not_called 'start'
}

# 2026-11-03: a plan item sat in running/ at its plan, and the Overview's "Waiting for you" was empty.
@test "reap moves an item to waiting while its session waits on the human or owns a pending ask, and back after" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1
  started_item q game-agent-2
  printf 'game-agent-1\ngame-agent-2\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'printf "%s\n" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"waiting\"}" "{\"target\":\"lab/game-agent-2:1\",\"status\":\"idle\"}"'
  stub agent-ask 'printf "a1\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-03\tgame-agent-2\n"'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting p)" ] || fail "the session at its plan is not waiting"
  [ -n "$(qitem waiting q)" ] || fail "the session with a pending ask is not waiting"

  stub agent-panel 'printf "%s\n" "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running p)" ] && [ -n "$(qitem running q)" ] || fail "an answered session stayed waiting"
}

@test "reap moves nothing when it cannot read the sessions or the asks" {
  project game beta "$SANDBOX/repos/game"
  started_item p game-agent-1 '' '' human waiting
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

@test "start --brief claims the row, promotes it to an item, and starts that item on the named server" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'tidy the loader' '- [ ] tidy the loader'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent \
    --row 'tidy the loader' --server default --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'started game-agent-1: game: tidy-the-loader'
  grep -qF -- '- [/] tidy the loader' "$NOTES_FIXTURE/rows.game.agent" || fail "row not claimed"
  assert_called "new --server default --detach -c $SANDBOX/repos/game"
  assert_called 'tmux -L default set-option -t =game-agent-1: @dispatch game: tidy-the-loader'
  f=$(qitem running tidy-the-loader)
  [ -n "$f" ] || fail "the row's item is not running"
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" lane) $(qfield "$f" profile)" 'default:game-agent-1 hand agent bnb'
  assert_equal "$(qfield "$f" from)" 'board:game:tidy the loader'
  # One /one-shot: the item's brief adds it, so the row brief's own is dropped.
  assert_equal "$(grep -o '/one-shot' "$NOTES_FIXTURE/cmd" | wc -l)" 1
  grep -qF 'AGENT_QUEUE_ITEM=tidy-the-loader' "$NOTES_FIXTURE/cmd" || fail "the session does not know its item"
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
  assert_called "tmux -L default new-session -d -s fix-crash -c $SANDBOX/repos/game claude --permission-mode bypassPermissions --resume abc-123"
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
    --row 'tidy the loader' --server default --brief "$SANDBOX/brief.md"
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
  assert_output game/wilds
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

# night_keys -> the board keys of the queued night items, sorted.
night_keys() {
  agent-queue list --json --state queued | jq -r 'select((" " + (.tags // "") + " ") | contains(" night ")) | .from | ltrimstr("board:agent-runtime:")' | sort | paste -sd, -
}

fill() { run "$REPO_ROOT/.local/bin/fleet-dispatch" fill "$@"; }

@test "night: a tier-3 agent-runtime row is promoted as a night item with its brief, started on the board, no session" {
  night_ready
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3 #high'
  night_verdict 'wt done never reaps' wt

  fill
  assert_success
  assert_output --partial 'queued agent-runtime: wt done never reaps'
  f=$(qitem queued wt-done-never-reaps)
  [ -n "$f" ] || fail "no night item"
  assert_equal "$(qfield "$f" tags) $(qfield "$f" priority) $(qfield "$f" area)" 'night low wt'
  assert_equal "$(qfield "$f" from)" 'board:agent-runtime:wt done never reaps'
  [ "$(state_of 'wt done never reaps')" = '- [/]' ] || fail "row not started"
  run agent-queue show wt-done-never-reaps
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

@test "night: only rows tier 3 alone holds back; asks, decisions, devices, the human's machine and lower tiers stay out" {
  night_ready
  row agent-runtime agent 'ask row' '- [ ] fix the ask row #ask #tier/3'
  row agent-runtime agent 'decide: fold it' '- [ ] decide: fold it #tier/3'
  row agent-runtime agent 'pad run' '- [ ] fix the pad controller switch #tier/3'
  row agent-runtime agent 'waybar row' '- [ ] waybar: fix pulse colours #tier/3'
  row agent-runtime agent 'tier two' '- [ ] fix the tier two row #tier/2'
  row agent-runtime agent 'unclear' '- [ ] fix something somewhere #tier/3'
  row agent-runtime agent 'started' '- [/] fix the started row #tier/3'
  row agent-runtime agent 'untagged' '- [ ] fix the untagged row'
  for k in 'ask row' 'decide: fold it' 'pad run' 'waybar row' 'tier two' 'started' 'untagged'; do night_verdict "$k"; done
  night_verdict unclear unclear false

  run night_rows ''
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'unclear,untagged'
  fill
  assert_success
  assert_equal "$(night_keys)" 'untagged'
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
  assert_output --partial 'could not queue agent-runtime row, un-started: fix it'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "night: a cancelled night item (default profile, no profile: line) hands its row back" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it'
  fill
  [ "$(state_of 'fix it')" = '- [/]' ] || fail "row not started"
  [ -z "$(qfield "$(qitem queued fix-it)" profile)" ] || fail "fixture should carry no profile"
  agent-queue cancel fix-it
  run cmd_reap
  assert_output --partial 'un-started agent-runtime: fix it (queue item fix-it ended cancelled)'
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
  [ -n "$(qitem queued fix-it)" ] || fail "not queued for the night"
  assert_not_called 'wt new'
  AGENT_QUEUE_NOW=02:00 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/alt claude'
  assert_called '/one-shot --pr-only fix it'
  [ -n "$(qitem running fix-it)" ] || fail "night item not started in its window"
}

@test "night: the judge is asked for tier3_only on new rows, and keeps it" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  cat > "$NOTES_FIXTURE/judge.out" <<'J'
DISPATCH-VERDICTS-START
{"project": "agent-runtime", "lane": "agent", "key": "fix it", "tier": 3, "size": "S", "area": "hooks", "clear": true, "agent_only": true, "tier3_only": true, "verdict": "skip", "reason": "tier 3"}
DISPATCH-VERDICTS-END
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
  assert_line --index 0 'ready     game (beta) human, fleet, fix crash on load: fix crash on load'
  assert_line --index 1 'unjudged  game (beta) human: add a new map'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run --json
  assert_equal "$(jq -r '"\(.state) \(.key)"' <<<"$output" | paste -sd, -)" 'ready fix crash on load,unjudged add a new map'
  assert_not_called 'judge called'
  assert_not_called 'wt new'
  assert_not_called 'start '
  [ -z "$(ls "$AGENT_QUEUE_DIR"/*/ 2>/dev/null)" ] || fail "fill --dry-run queued an item"
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

@test "a queue item runs /one-shot in bypass mode, a night item --pr-only, a plan item in plan mode" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug n --tags night "do n"
  agent-queue add --project game --slug p --mode plan "plan p"
  for s in a n p; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial 'AGENT_QUEUE_ITEM=a claude --model opus --permission-mode bypassPermissions'
  assert_output --partial '/one-shot do a'
  assert_output --partial '/one-shot --pr-only do n'
  assert_output --partial 'AGENT_QUEUE_ITEM=p claude --model opus --permission-mode plan --allow-dangerously-skip-permissions'
  refute_output --partial '/one-shot plan p'
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

@test "the human's queue item starts while the human is here, past a board-filled one that waits for away" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  agent-queue add --project game --slug from-board --from board:game:x "x"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'the human is not away'
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
  assert_output --partial 'would start queue item mine: game oneshot normal'
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
