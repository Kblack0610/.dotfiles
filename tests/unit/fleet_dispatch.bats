#!/usr/bin/env bats
# fleet-dispatch: which rows may start an unattended session, and the bookkeeping around it.
# Everything that could launch, claim or judge is a stub; calls.log records what it would do.

# acct <name:reasons[:dir[:why]]>... -> claude-acct room --json answers these accounts, best rank
# first (main's dir is empty), with claude-acct's pick (the first with room) and its refusal
# sentence when there is none. reasons is ok, or every refusal joined by commas (pace, reserve,
# five_hour, committed, capped, unread); why is the first refusal's words, a stock sentence when not
# given. Each ask is counted in room.n, and acct.<n>.json, when present, answers ask n (from 0).
# Every other verb exits 0.
acct() {
  local spec name reasons dir why rank=0 rows='[]'
  for spec in "$@"; do
    IFS=: read -r name reasons dir why <<<"$spec"
    rank=$((rank + 1))
    rows=$(jq -c --arg n "$name" --arg r "$reasons" --arg d "$dir" --arg w "$why" --argjson k "$rank" '
      ($r | split(",") | map(select(. != "ok"))) as $no
      | {pace: "1 point over its weekly pace", reserve: "90% of its week used, inside the last 15% kept for the human",
         five_hour: "its 5h window at 90%", committed: "its 2 live sessions use the rest of its week before the reset",
         capped: "out of its week", unread: "its usage cannot be read"} as $stock
      | . + [{name: $n, dir: $d, state: (if $no == ["unread"] then "unread" else "ok" end), rank: $k,
              room: {ok: ($no == []), reason: ($no[0] // "ok"), reasons: $no, capped: ($no | index("capped") != null),
                     why: (if $no == [] then "it has room" elif $w != "" then $w else $stock[$no[0]] end)}}]' <<<"$rows")
  done
  jq -c '([.[] | select(.room.ok)] | first | .name) as $p
    | ([.[] | select(.state != "unread")] | first) as $c
    | {pick: $p, accounts: .,
       why: (if $p then null elif any(.[]; .state == "unread") then "no account has room and one cannot be read"
             elif $c == null then "no account has room under its weekly pace and after its live sessions"
             else "no account has room; \($c.name) is the closest, \($c.room.why)" end)}' <<<"$rows" > "$NOTES_FIXTURE/acct.json"
  rm -f "$NOTES_FIXTURE/room.n"
  stub claude-acct '[ "$1 ${2:-}" = "room --json" ] || exit 0
n=$(cat "$NOTES_FIXTURE/room.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$NOTES_FIXTURE/room.n"
if [ -e "$NOTES_FIXTURE/acct.$n.json" ]; then cat "$NOTES_FIXTURE/acct.$n.json"; else cat "$NOTES_FIXTURE/acct.json"; fi'
}

# cpu <us> <sy> <ni> <id> -> each real idle sample window adds these jiffies to /proc/stat, and the
# last sample is gone, so the next gate reads (ni + id) of the four as free. sleep is the window.
cpu() {
  echo "$1 $3 $2 $4" > "$DISPATCH_PROC_STAT.step"
  rm -f "$FLEET_DISPATCH_DIR/idle"
}

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
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  export DISPATCH_LOADAVG="$SANDBOX/loadavg"
  export DISPATCH_JUDGE_CMD=judge-stub   # on PATH: the command is a word list, and the sandbox path has a space
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  export DISPATCH_PROJECT_FLOOR=0   # off unless a test is about it ("project floor:"), so an idle-held machine stays held
  export DISPATCH_START_LOAD=0   # a start adds no pending load unless a test is about it, whatever the runner's cores
  printf '%s\n' 'policy' '- (fits) dispatch' '- (tier3) tier 3' '- (unclear) not clear' > "$DISPATCH_POLICY"
  mkdir -p "$SANDBOX/repos/game" "$SANDBOX/repos/app" "$SANDBOX/sheets"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub_notes
  stub agent-hold 'exit 0'
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  stub fleet-presence 'echo "away 45 tmux"'
  stub fleet-bench 'exit 0'
  # Since boot the machine was 98% idle; the window is what the gate reads.
  export DISPATCH_PROC_STAT="$SANDBOX/stat"
  echo 'cpu  1000 0 1000 98000 0 0 0 0 0 0' > "$DISPATCH_PROC_STAT"
  stub sleep 'echo "sleep $*" >> "$NOTES_FIXTURE/calls.log"; read -r a b c d < "$DISPATCH_PROC_STAT.step"; read -r _ u n s i _ < "$DISPATCH_PROC_STAT"
echo "cpu  $((u + a)) $((n + b)) $((s + c)) $((i + d)) 0 0 0 0 0 0" > "$DISPATCH_PROC_STAT"'
  cpu 5 5 0 90
  stub fleet-shepherd 'exit 1'
  acct main:ok   # main account with room; a test that wants the alt one restubs it
  stub model-lane 'echo "{\"dispatch_model\":\"opus\"}"'
  # Spilling to Lazer is off but in its own tests (spill_ready): an account test means the accounts.
  export DISPATCH_SPILL_MAX_LIVE=0
  stub lazer-spend 'exit 1'
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
# mask_sid <log>... -> each launch's random `--session-id <uuid>` becomes `--session-id SID`, so a test
# can assert the whole command line.
mask_sid() { sed -i -E 's/--session-id [0-9a-f-]{36}/--session-id SID/g' "$@"; }

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
  row)   # `row parse`: a stand-in for the grammar's home (notes-cli), enough for these fixtures: type(area): with a type in kinds.json
    while IFS= read -r l; do
      t=$(sed -nE 's/^(- \[.\] )?([a-z]+)\([a-z0-9-]+\):.*/\2/p' <<<"$l")
      if [ -n "$t" ] && jq -e --arg t "$t" 'has($t)' "$DISPATCH_KINDS" >/dev/null 2>&1; then printf '%s\t-\t%s\t1\n' "$t" "$l"
      else printf -- '-\t-\t%s\t0\n' "$l"; fi
    done ;;
  board) if [ -f "$F/board.rows" ]; then jq -sc '{rows: .}' "$F/board.rows"; else echo '{"rows": []}'; fi ;;
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
      done)   # closed rows leave `list`, as the real board's do
        Q="${args[3]}" awk -F'\t' -v OFS='\t' '
          !hit && $2 ~ /^- \[[ \/]\]/ && (index($2, "id:" ENVIRON["Q"] " ") || index($1, ENVIRON["Q"])) { hit = 1; sub(/^- \[[ \/]\]/, "- [x]", $2) }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
      tag)   # tag --add <tag> <id>: the tag goes in ahead of the row's marker
        Q="${args[5]}" T="${args[4]}" awk -F'\t' -v OFS='\t' '
          !done && index($2, "id:" ENVIRON["Q"] " ") { done = 1; sub(/ <!--/, " #" ENVIRON["T"] " <!--", $2) } { print }' "$f" > "$f.new" &&
          mv "$f.new" "$f" ;;
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

# board_row <project> <lane> <id> <tags json> <details json> -- that fixture row as `notes board
# --json` gives it (its raw line from rows.<project>.<lane>), with tags and details
board_row() {
  jq -cn --arg p "$1" --arg l "$2" --arg i "$3" --argjson t "$4" --argjson d "$5" \
    --arg raw "$(awk -F'\t' -v k="$3" '$1 == k { print $2; exit }' "$NOTES_FIXTURE/rows.$1.$2")" \
    '{profile: "bnb", project: $p, lane: $l, id: $i, state: "open", tags: $t, details: $d, raw: $raw, text: $raw}' \
    >> "$NOTES_FIXTURE/board.rows"
}

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
      rule: "fits", reason: "r", policy: $sig, line: $line}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
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

@test "candidates: a lane's row kinds come from one notes row parse, not one per row" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): one $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] chore(game): two $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): three $T <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] bare row $T <!-- id:gm-4 -->"
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.key):\(.kind)"' <<<"$output" | paste -sd,)" 'gm-1:fix,gm-2:chore,gm-3:feat,gm-4:'
  assert_equal "$(grep -c '^notes row parse' "$NOTES_FIXTURE/calls.log")" 1
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
  jq -cn --arg sig "$(policy_sig)" '{project: "game", lane: "agent", key: "retagged", verdict: "skip", rule: "fits", policy: $sig, line: "old"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn '{project: "game", lane: "agent", key: "died", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'stale policy,retagged'
}

@test "candidates: the judge reads a row's details, and an edit to them re-judges only a verdict that recorded them" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] fix the jump $T <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] old verdict $T <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] no details $T <!-- id:ga-3 -->"
  board_row game agent ga-1 '[]' '["the jump clips on ledges", "repro: level 2"]'
  board_row game agent ga-2 '[]' '["first words"]'
  verdict game agent ga-2 skip   # from before details were read: no dsig
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; cat "$NOTES_FIXTURE/judge.out"'
  echo '{"verdicts":[{"project":"game","lane":"agent","key":"ga-1","tier":1,"size":"S","clear":true,"agent_only":true,"area":"jump","verdict":"dispatch","rule":"fits","reason":"small"},{"project":"game","lane":"agent","key":"ga-3","tier":1,"size":"S","clear":false,"agent_only":true,"area":"x","verdict":"skip","rule":"unclear","reason":"vague"}]}' > "$NOTES_FIXTURE/judge.out"
  run judge "$(cmd_candidates)"
  assert_success
  grep -qF '"key":"ga-1","text":"- [ ] fix the jump' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  grep -qF '"details":"the jump clips on ledges\nrepro: level 2"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  # negative control: a row with no details sends none
  run grep -F '"key":"ga-3"' "$NOTES_FIXTURE/prompt"
  refute_output --partial '"details"'
  run cmd_candidates
  assert_output ''
  # Details change under all three: ga-1's verdict recorded them and is judged again; ga-2's is
  # older than dsig and holds on its text; ga-3 recorded "none", so new details re-judge it too.
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent ga-1 '[]' '["the jump clips on ledges", "repro: level 3"]'
  board_row game agent ga-2 '[]' '["other words"]'
  board_row game agent ga-3 '[]' '["now it has some"]'
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'ga-1,ga-3'
}

@test "candidates: a #plan row waits for inbox-plan and suggest says so" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] define me $T #plan <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] ready $T <!-- id:ga-2 -->"
  board_row game agent ga-1 '["plan"]' '[]'
  board_row game agent ga-2 '[]' '[]'
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'ga-2'
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | join("; ")' <<<"$output")" 'waits on a plan'
  assert_equal "$(jq -r 'select(.key == "ga-2") | .blocked | length' <<<"$output")" 0
}

# plan_fixture -- agent rows skipped by each kind of rule, one already planned, one edited since,
# a human row, and one row already waiting on its plan
plan_fixture() {
  printf '%s\n' '- (design) needs a product call' '- (bundle) several tasks' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  local k
  for k in ga-1 ga-2 ga-3 ga-4 ga-5 ga-7; do row game agent "$k" "- [ ] row $k $T <!-- id:$k -->"; done
  row game agent ga-6 "- [ ] row ga-6 #plan $T <!-- id:ga-6 -->"
  row game human gh-1 "- [ ] row gh-1 $T <!-- id:gh-1 -->"
  for k in ga-1 ga-2 ga-4 ga-5 ga-7; do board_row game agent "$k" '[]' '[]'; done
  board_row game agent ga-3 '[]' '["goal: already planned"]'
  board_row game agent ga-6 '["plan"]' '[]'
  board_row game human gh-1 '[]' '[]'
  rule() { verdict game "$1" "$2" skip; jq -c --arg r "$3" 'if .key == "'"$2"'" then .rule = $r else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  rule agent ga-1 unclear; rule agent ga-2 design; rule agent ga-3 unclear; rule agent ga-5 unclear
  rule agent ga-7 bundle; rule human gh-1 unclear
  verdict game agent ga-4 dispatch
  # ga-5 was edited after its verdict
  sed -i 's/row ga-5/row ga-5 now longer/' "$NOTES_FIXTURE/rows.game.agent"
  : > "$NOTES_FIXTURE/board.rows"
  for k in ga-1 ga-2 ga-4 ga-5 ga-7; do board_row game agent "$k" '[]' '[]'; done
  board_row game agent ga-3 '[]' '["goal: already planned"]'
  board_row game agent ga-6 '["plan"]' '[]'
  board_row game human gh-1 '[]' '[]'
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
}

@test "plan_skips: tags agent rows skipped as undefined and never planned, then kicks inbox-plan" {
  plan_fixture
  plan_skips
  assert_equal "$PLAN_TAGGED" 2
  run grep -o 'ptask game --agent tag --add plan [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-1
ptask game --agent tag --add plan ga-7'
  # negative controls: a design skip, a planned row, a dispatch, an edited row and a human row
  run grep -E 'tag --add plan (ga-2|ga-3|ga-4|ga-5|ga-6|gh-1)' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # ga-6 already waits, so inbox-plan's unit is started
  grep -qx -- '--user start --no-block agentctl@inbox-plan.service' "$NOTES_FIXTURE/systemctl.log"
}

@test "plan_skips: a cleanup row read as not clear or size L under a tier-3 skip goes to inbox-plan; a feature, a clear M row, or a human-only skip does not" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_CLEANUP_PROJECTS=game
  row game agent ga-8 "- [ ] chore(game): prune the cache $T <!-- id:ga-8 -->"
  row game agent ga-9 "- [ ] fix(game): the sweep never retries $T <!-- id:ga-9 -->"
  row game agent ga-10 "- [ ] feat(game): a new page $T <!-- id:ga-10 -->"
  row game agent ga-11 "- [ ] chore(game): drop the dead flag $T <!-- id:ga-11 -->"
  row game agent ga-12 "- [ ] fix(game): the score $T #size/m <!-- id:ga-12 -->"
  row game agent ga-13 "- [ ] fix(game): the headset drops the pad $T <!-- id:ga-13 -->"
  row game agent ga-14 "- [ ] chore(game): remove the old store build $T <!-- id:ga-14 -->"
  : > "$NOTES_FIXTURE/board.rows"
  for k in ga-8 ga-9 ga-10 ga-11 ga-12 ga-13 ga-14; do board_row game agent "$k" '[]' '[]'; done
  t3() { verdict game agent "$1" skip "$2" 3; jq -c --argjson c "$3" 'if .key == "'"$1"'" then .rule = "tier3" | .tier3_only = true | .clear = $c else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  t3 ga-8 S false; t3 ga-9 L true; t3 ga-10 S false; t3 ga-11 M true; t3 ga-12 L true
  # unclear or L, but held by a rule only the human clears: a device run, a release
  human() { verdict game agent "$1" skip L 3; jq -c 'if .key == "'"$1"'" then .rule = "'"$2"'" | .tier3_only = false | .clear = false else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  human ga-13 needs-person; human ga-14 release
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
  plan_skips
  assert_equal "$PLAN_TAGGED" 2
  run grep -o 'ptask game --agent tag --add plan [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-8
ptask game --agent tag --add plan ga-9'
  # negative controls: a feature (not cleanup), a clear M cleanup row, an L verdict the row's own
  # #size/m overrides, and unclear L rows a needs-person or release skip holds for the human
  run grep -E 'tag --add plan (ga-10|ga-11|ga-12|ga-13|ga-14)' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "plan_skips: stops at DISPATCH_PLAN_BACKLOG open #plan rows, and 0 turns it off" {
  plan_fixture
  DISPATCH_PLAN_BACKLOG=2 plan_skips
  assert_equal "$PLAN_TAGGED" 1
  : > "$NOTES_FIXTURE/calls.log"
  DISPATCH_PLAN_BACKLOG=0 plan_skips
  assert_equal "$PLAN_TAGGED" 0
  run grep -c 'board --json' "$NOTES_FIXTURE/calls.log"
  assert_output 0
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

@test "the shipped registry: the AI systems and the home cluster have a day worker, under the same tier ceiling; finance has none" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json"
  mkdir -p "$SANDBOX/repos/ar" "$SANDBOX/repos/hc" "$SANDBOX/repos/fin"
  project agent-runtime alpha "$SANDBOX/repos/ar"
  project home-config alpha "$SANDBOX/repos/hc"
  project finance alpha "$SANDBOX/repos/fin"
  row agent-runtime agent 'ar fix' '- [ ] fix(intake): retry a failed sweep'
  row agent-runtime agent 'ar ci' '- [ ] ci(runners): the pool'
  row home-config agent 'hc row' '- [ ] chore(dns): tidy a record'
  row finance agent 'fin row' '- [ ] chore(budget): a sheet'
  run cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.key) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'ar fix=infra,hc row=infra'
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
  assert_output "auto  unjudged  game game human  [fleet, #high, beta]
auto  dispatch  game game judged  [fleet, #high, beta]
auto  dispatch  game game busy  [fleet, #high, beta]  blocked: area held by a queue item
auto  unjudged  game game new  [fleet, #high, beta]
man   unjudged  app app row  [#high, alpha]  blocked: no worker covers app"
  refute_output --partial 'app human'
  refute_output --partial 'sketch'
  run grep -c 'judge called' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A changed policy makes every cached verdict stale, so the list says unjudged, not dispatch.
  echo 'policy v2' > "$DISPATCH_POLICY"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.verdict)/\(.auto)"' <<<"$output" | paste -sd' ')" \
    'game human=unjudged/true game judged=unjudged/true game busy=unjudged/true game new=unjudged/true app row=unjudged/false'
}

@test "suggest: each row no worker takes names why: no cover, the night path's skip word or its gap, the tier ceiling, size, the judge" {
  echo '{"personal": {"max_tier": 2, "projects": ["game"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  export DISPATCH_NIGHT_PROJECTS="night"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  mkdir -p "$SANDBOX/repos/night"
  project night alpha "$SANDBOX/repos/night"
  row app agent 'app row' "- [ ] app row"
  row night agent 'night sudo' "- [ ] chore(box): run it with sudo"
  row night agent 'night plain' "- [ ] chore(box): tidy the docs"
  row game agent 'game ci' "- [ ] ci(game): the runner pool #tier/3"
  row game agent 'game big' "- [ ] feat(game): a whole new mode #size/l"
  row game agent 'game skip' "- [ ] feat(game): a skipped one"
  verdict game agent 'game skip' skip
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  assert_equal "$(b 'app row')" 'no worker covers app'
  assert_equal "$(b 'night sudo')" 'night skip: sudo'
  assert_equal "$(b 'night plain')" 'night only: no day worker covers night'
  assert_equal "$(b 'game ci')" 'tier 3: past the unattended ceiling'
  assert_equal "$(b 'game big')" 'size/l: too big for a pick'
  assert_equal "$(b 'game skip')" 'judge: skip, r'
  # active: no repo here has a commit, so a row nobody takes is never marked worked on today.
  assert_equal "$(jq -r 'select(.key == "app row") | .active' <<<"$output")" false
}

@test "rank: a cleanup kind (kinds.json) of an AI system outranks the rest of its bucket; a feature, docs or an adding refactor there, or a fix elsewhere, does not" {
  echo '{"personal": {"max_tier": 2, "projects": ["game", "app"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  export DISPATCH_CLEANUP_PROJECTS="app"
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'game fix' "- [ ] fix(game): the score is wrong #urgent"
  row app agent 'app feat' "- [ ] feat(app): a new page #urgent"
  row app agent 'app fix' "- [ ] fix(app): the sweep never retries #low"
  row app agent 'app stale' "- [ ] chore(app): prune the stale cache #low"
  row app agent 'app docs' "- [ ] docs(app): explain the sweep #urgent"
  row app agent 'app split' "- [ ] refactor(app): split the loader #urgent"
  row app agent 'app delete' "- [ ] refactor(app): delete the old loader #low"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'app fix app stale app delete game fix app feat app docs app split'
  assert_equal "$(jq -r 'select(.key == "app fix") | .why' <<<"$output")" 'cleanup, personal, #low, bug, beta'
  assert_equal "$(jq -r 'select(.key == "game fix") | .cleanup' <<<"$output")" 1
  # Empty scope turns it off: back to row priority.
  DISPATCH_CLEANUP_PROJECTS="" run cmd_suggest --json
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'game fix app feat app docs app split app fix app stale app delete'
}

@test "row_priority: a cleanup row of an AI system promotes as high whatever its #low; a feature there stays low" {
  export DISPATCH_CLEANUP_PROJECTS="app"
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low' app)" high
  assert_equal "$(row_priority '- [ ] feat(app): a new page #low' app)" low
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low' game)" low
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low')" low
}

@test "rank: cleanup goes first, then due and #requested rows; a lookalike tag is not #requested" {
  c() { jq -cn --arg k "$1" --argjson pr "$2" --argjson cl "$3" --arg t "$4" \
    "$RANK_JQ"'{key: $k, wrank: 0, prio: $pr, cleanup: $cl, stage: "beta", text: "- [ ] \($k) \($t)"} | rank_fields("2026-11-05"; "")'; }
  cands=$(c urgent 0 1 '#urgent'; c cleanup 1 0 '#low'; c asked 3 1 '#low #requested'; c due 1 1 '#high #due1105'
    c lookalike 1 1 '#requested-ish')
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'cleanup due asked urgent lookalike'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "asked") | .why' <<<"$cands"
  assert_output 'requested, #low, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "cleanup") | .why' <<<"$cands"
  assert_output --regexp '^cleanup, '
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
app due: due today, fleet, #high, alpha
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

# kinds_match <kinds.json> -- its keys are notes-cli's ROW_TYPES, no more and no fewer, and every
# entry carries the fields dispatch and shepherd read
kinds_match() {
  local types keys
  types=$(sed -n '/const ROW_TYPES/,/];/p' "$REPO_ROOT/.local/src/notes-cli/src/projects.rs" | grep -oE '"[a-z]+"' | tr -d '"' | sort)
  [ -n "$types" ] || { echo "no ROW_TYPES read from projects.rs"; return 1; }
  keys=$(jq -r 'keys[]' "$1" | sort)
  [ "$types" = "$keys" ] || { echo "kinds.json keys differ from ROW_TYPES:"; diff <(echo "$types") <(echo "$keys"); return 1; }
  jq -e 'to_entries | all(.value | (.rank | type) == "number" and (.entry | type) == "string"
    and (.rung | IN("build", "propose", "human")) and (.exit | type) == "string"
    and (.stages | type) == "array" and (.enabled | type) == "boolean")' "$1" >/dev/null || { echo "an entry lacks a field"; return 1; }
}

@test "kinds: kinds.json names every notes-cli row type and no other, each with rank, entry, rung, exit, stages and enabled" {
  run kinds_match "$DISPATCH_KINDS"
  assert_success
  # negative controls: a key ROW_TYPES lacks, a type missing, and an entry with no rung each fail
  jq '. + {bug: .fix}' "$DISPATCH_KINDS" > "$SANDBOX/extra.json"
  run kinds_match "$SANDBOX/extra.json"
  assert_failure
  jq 'del(.perf)' "$DISPATCH_KINDS" > "$SANDBOX/fewer.json"
  run kinds_match "$SANDBOX/fewer.json"
  assert_failure
  jq 'del(.fix.rung)' "$DISPATCH_KINDS" > "$SANDBOX/norung.json"
  run kinds_match "$SANDBOX/norung.json"
  assert_failure
}

@test "rank: a fix row goes before a feat row of the same priority, and why calls it a bug" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game feat' "- [ ] feat(game): a new mode #high $T #c1020"
  row game agent 'game fix' "- [ ] fix(game): the score is wrong #high $T #c1104"
  row game agent 'game urgent feat' "- [ ] feat(game): the menu #urgent $T #c1104"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game urgent feat,game fix,game feat'
  assert_equal "$(jq -r 'select(.key == "game fix") | .why' <<<"$output")" 'fleet, #high, bug, beta, 1d old'
  assert_equal "$(jq -r 'select(.key == "game feat") | .why' <<<"$output")" 'fleet, #high, beta, 16d old'
}

@test "rank: a row with no priority tag ranks as #high, by age among them" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game high' "- [ ] game high #high $T #c1104"
  row game agent 'game bare' "- [ ] game bare $T #c1001"
  row game agent 'game low' "- [ ] game low #low $T #c0901"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game bare,game high,game low'
  assert_equal "$(jq -r 'select(.key == "game bare") | "\(.why) \(.priority)"' <<<"$output")" 'fleet, #high, beta, 35d old high'
}

@test "candidates: a kind that is off, off in the project or not at the stage, and a parent row, never reach the judge; suggest says why" {
  jq -n '{fix: {rank: 0, label: "bug", entry: "/one-shot", rung: "build", exit: "pr", stages: ["beta", "alpha"], enabled: true},
          feat: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", stages: ["beta", "alpha"], enabled: true, off: ["app"]},
          chore: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", stages: ["prod"], enabled: true},
          decide: {rank: 1, entry: "", rung: "human", exit: "ask", stages: [], enabled: false},
          epic: {rank: 1, entry: "", rung: "human", exit: "none", stages: [], enabled: false}}' > "$SANDBOX/kinds.json"
  export DISPATCH_KINDS="$SANDBOX/kinds.json"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  row game agent gm-1 "- [ ] fix(game): the score is wrong $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] decide(game): which mode first $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] chore(game): tidy the docs $T <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] epic(game): the new mode $T <!-- id:gm-4 -->"
  row game agent gm-5 "- [ ] fix(game): the mode's parent story $T <!-- id:gm-5 -->"
  row game agent gm-6 "- [ ] fix(game): one leaf of it #of/gm-5 $T <!-- id:gm-6 -->"
  row app agent ap-1 "- [ ] feat(app): a new page $T <!-- id:ap-1 -->"
  row app agent ap-2 "- [ ] plain app row $T <!-- id:ap-2 -->"
  board_row game agent gm-6 '["of/gm-5"]' '[]'
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-6,ap-2'
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  assert_equal "$(b gm-2)" 'kind decide is off'
  assert_equal "$(b gm-3)" 'kind chore does not dispatch at beta'
  assert_equal "$(b gm-4)" 'kind epic is off'
  assert_equal "$(b gm-5)" 'a parent: open rows name it in #of/'
  assert_equal "$(b ap-1)" 'kind feat is off in app'
  assert_equal "$(b gm-1)" ''
  # A closed child holds nothing: with no open row naming it, the parent is a row like any other.
  : > "$NOTES_FIXTURE/board.rows"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-5,gm-6,ap-2'
}

@test "size: a row's #size/ tag is its size: the judge reads it as given and picks trust it over the judge" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] small by tag #size/s $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] large by tag #size/l $T <!-- id:gm-2 -->"
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; echo "{\"verdicts\":[]}"'
  run judge "$(cmd_candidates)"   # an empty reply fails the pass; only the prompt matters here
  grep -qF '"key":"gm-1","text":"- [ ] small by tag #size/s #worker/fleet #tier/1 <!-- id:gm-1 -->","tier":1,"size":"S"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  : > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  # The judge calls the small row L and the large one S: the tags win.
  verdict game agent gm-1 dispatch L 1 one
  verdict game agent gm-2 dispatch S 1 two
  run picks "$(VERDICTS=/dev/null cmd_candidates)" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" gm-1
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "gm-2") | .blocked | join("; ")' <<<"$output")" 'size/l: too big for a pick'
  assert_equal "$(jq -r 'select(.key == "gm-1") | .size' <<<"$output")" S
}

@test "size_back: the judge's size goes onto an unsized row, and the verdict holds for the tagged text" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] unsized $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] sized #size/m $T <!-- id:gm-2 -->"
  row game agent 'no id' "- [ ] no id yet $T"
  echo '{"verdicts":[{"project":"game","lane":"agent","key":"gm-1","tier":1,"size":"S","clear":true,"agent_only":true,"area":"a","verdict":"dispatch","rule":"fits","reason":"r"},{"project":"game","lane":"agent","key":"gm-2","tier":1,"size":"S","clear":true,"agent_only":true,"area":"b","verdict":"dispatch","rule":"fits","reason":"r"},{"project":"game","lane":"agent","key":"no id","tier":1,"size":"M","clear":true,"agent_only":true,"area":"c","verdict":"dispatch","rule":"fits","reason":"r"}]}' > "$NOTES_FIXTURE/judge.out"
  judge "$(cmd_candidates)"
  run grep -F ' tag --add ' "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'ptask game --agent tag --add size/s gm-1'
  refute_output --partial 'gm-2'
  refute_output --partial 'no id'
  run awk -F'\t' '$1 == "gm-1" { print $2 }' "$NOTES_FIXTURE/rows.game.agent"
  assert_output "- [ ] unsized $T #size/s <!-- id:gm-1 -->"
  # Not judged twice: the verdict holds for the row's new text.
  run cmd_candidates
  assert_output ''
}

@test "item_brief: a session starts on its kind's entry, by the item's type or its title's prefix; /one-shot otherwise" {
  jq '.fix.entry = "/fix-skill" | .design.entry = "/one-pager"' "$REPO_ROOT/.config/fleet-dispatch/kinds.json" > "$SANDBOX/kinds.json"
  export DISPATCH_KINDS="$SANDBOX/kinds.json"
  it() { jq -cn --arg t "$1" --arg ty "$2" '{slug: "s", mode: "oneshot", title: $t, task: $t} + (if $ty != "" then {type: $ty} else {} end)'; }
  run item_brief "$(it 'fix(game): the score' '')"
  assert_line --index 0 '/fix-skill fix(game): the score'
  run item_brief "$(it 'the score is wrong' design)"
  assert_line --index 0 '/one-pager the score is wrong'
  run item_brief "$(it 'feat(game): a mode' '')"
  assert_line --index 0 '/one-shot feat(game): a mode'
  run item_brief "$(it 'decide(game): which' '')"   # a kind with no entry
  assert_line --index 0 '/one-shot decide(game): which'
  run item_brief "$(it 'plain task' '')"
  assert_line --index 0 '/one-shot plain task'
  run item_brief "$(it 'fix(game): the score' '')" opencode
  assert_line --index 0 'Read ~/.claude/skills/fix-skill/SKILL.md and follow it for this task:'
}

@test "item_brief: a doc+ask kind ends on a doc in the lab docs and an ask recorded on the item, never a PR" {
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "r", "mode": "oneshot", "project": "game", "title": "research(game): which engine", "task": "research(game): which engine", "type": "research", "row": "game:ar-9", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 '/deep-research-code research(game): which engine'
  assert_output --partial 'a research row: it ends on a doc and an ask, never a PR'
  assert_output --partial 'agent-queue set r report=<doc path> ask=<ask id>; notes ptask game --agent done "ar-9" --proof doc:<doc path>; agent-queue move r done --status ok'
  refute_output --partial 'agent-land'
  refute_output --partial 'Item: r'
  # a code kind still lands a PR (negative control)
  run item_brief '{"slug": "f", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}'
  assert_output --partial 'Merge with agent-land <N>'
  refute_output --partial 'report=<doc path>'
}

@test "item_brief: a proof kind (release) starts its skill and ends on live proof on the item and its row, never agent-land; its board rows stay off" {
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "rel", "mode": "oneshot", "project": "game", "title": "release(steam): cut all 3pm, upload beta", "task": "release(steam): cut all 3pm, upload beta", "row": "game:ar-7", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 '/release release(steam): cut all 3pm, upload beta'
  assert_output --partial 'a release row: it ends on the live proof its skill names, never a PR or agent-land'
  assert_output --partial 'agent-queue set rel note="<proof>"; notes ptask game --agent done "ar-7" --proof "<proof>"; agent-queue move rel done --status ok'
  assert_output --partial 'If a step needs a decision from the human'
  refute_output --partial 'Merge with agent-land'
  refute_output --partial 'Item: rel'
  # the kind comes from the item's type too, and with no row there is no row to close
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "ship the games", "task": "ship the games", "type": "release"}'
  assert_line --index 0 '/release ship the games'
  assert_output --partial 'agent-queue set rel note="<proof>"; agent-queue move rel done --status ok'
  refute_output --partial 'notes ptask'
  # a night tag adds no --pr-only and a tier-3 item no merge gate: a release opens no PR
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "agent-runtime", "title": "release(steam): x", "task": "release(steam): x", "tags": "night tier3"}'
  assert_line --index 0 '/release release(steam): x'
  refute_output --partial 'red-fix gate'
  # a headless harness gets no wind-down and no window to leave open
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "release(steam): x", "task": "release(steam): x"}' opencode
  assert_line --index 0 'Read ~/.claude/skills/release/SKILL.md and follow it for this task:'
  assert_output --partial 'agent-queue move rel done --status ok.'
  assert_output --partial 'nobody watches this run'
  refute_output --partial 'wind-down'
  refute_output --partial 'leaving this window open'
  # a release board row never dispatches on its own: the human starts it, or /release queues it
  load_kinds
  assert_equal "$(kind_off release game beta)" 'kind release is off'
  # a feat item still starts /one-shot and lands a PR (negative control)
  run item_brief '{"slug": "f", "mode": "oneshot", "project": "game", "title": "feat(game): a mode", "task": "feat(game): a mode"}'
  assert_line --index 0 '/one-shot feat(game): a mode'
  assert_output --partial 'Merge with agent-land <N>'
  refute_output --partial 'note="<proof>"'
}

@test "reap: a gone session with no PR but its report recorded closes its item ok, not failed" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug d "research(game): which engine"
  stub wt 'echo "game-d"'
  cmd_start --item d >/dev/null
  agent-queue set d report="$SANDBOX/doc.md" ask=abc123
  run cmd_reap
  assert_success
  refute_output --partial 'failed queue item d'
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/done/*/*-d.md)" status)" ok
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

@test "picks: a dispatch verdict from an older policy still launches while its rule stands, not once the rule is gone" {
  verdict game human k dispatch
  echo 'policy v2' >> "$DISPATCH_POLICY"
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
  printf '%s\n' 'policy' '- (tier3) tier 3' > "$DISPATCH_POLICY"
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
  # A question blocks one step, and reap, not the session, moves the item to waiting.
  assert_called 'only that step is blocked, not the task'
  run grep -cE 'agent-queue move gm-1 waiting|then stop and leave' "$NOTES_FIXTURE/calls.log"
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

@test "promote: a row whose item already finished ok is never queued again; a human row goes back recorded failed" {
  project game beta "$SANDBOX/repos/game"
  row game human 'landed one' '- [ ] landed one <!-- id:gm-7 -->'
  row game agent 'landed two' '- [ ] landed two <!-- id:gm-8 -->'
  for k in gm-7 gm-8; do
    agent-queue add --project game --from "board:game:$k" --slug "$k" "x" >/dev/null
    agent-queue move "$k" done --status ok >/dev/null
  done
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-7"}')" "" task
  assert_failure
  assert_output --partial 'row un-started, recorded failed: gm-7 already finished ok'
  grep -qF -- '- [ ] landed one' "$NOTES_FIXTURE/rows.game.human" || fail "human row left started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r '.key + " " + .verdict')" "gm-7 failed"
  # An agent row stays started for the orphan pass, which closes it on its item's merge proof.
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-8"}')" "" task
  assert_failure
  assert_output --partial 'row left started for the orphan pass: gm-8 already finished ok'
  grep -qF -- '- [/] landed two' "$NOTES_FIXTURE/rows.game.agent" || fail "agent row un-started"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished row was queued again"
}

@test "fleet-dispatch promote: the human's Start queues a row whose item finished ok, as a repeat" {
  project game beta "$SANDBOX/repos/game"
  row game human 'landed one' '- [ ] landed one <!-- id:gm-7 -->'
  agent-queue add --project game --from "board:game:gm-7" --slug gm-7 "x" >/dev/null
  agent-queue move gm-7 done --status ok >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] landed one <!-- id:gm-7 -->'
  assert_success
  assert_output --partial "queued game: gm-7"
  [ -n "$(qitem queued gm-7)" ] || fail "the human's Start did not queue the row"
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

@test "fleet-dispatch promote --tags puts the tags on the item; without it the item has none" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix one' '- [ ] fix one #low <!-- id:gm-5 -->'
  row game human 'fix two' '- [ ] fix two #low <!-- id:gm-6 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --tags night --raw '- [ ] fix one #low <!-- id:gm-5 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-5)" tags)" night
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] fix two #low <!-- id:gm-6 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-6)" tags)" ""
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --tags
  assert_failure 2
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
  acct main:pace
  refuses 'no account has room; main is the closest, 1 point over its weekly pace'
}

# room_on_floor: the one account's verdict refuses it for its pace alone, so it has room only while
# a floor lifts the pace reason.
room_on_floor() {
  acct alt:pace:/home/u/.claude-personal
  cpu 60 30 0 10
}

@test "under DISPATCH_RUN_FLOOR a run start goes past the weekly pace and real idle, and says so" {
  game_ready
  room_on_floor
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  export DISPATCH_RUN_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'on the run floor (DISPATCH_RUN_FLOOR=2)'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  assert_equal "$(outcome)" WORKED
}

@test "the run floor counts this pass's starts: past it the pace holds again; 0 is no floor" {
  two_items
  room_on_floor
  export DISPATCH_PER_PASS=3 DISPATCH_RUN_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-game on the run floor'
  assert_output --partial 'over its weekly pace; real idle 10.0% is under 30%, the pass stops after 1 started'
  refute_output --partial 'started queue item fix-app'
  # the negative control: no floor, the same room and idle start nothing
  export DISPATCH_RUN_FLOOR=0
  rm -f "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
}

# 2026-11-05/06: every account over its pace held dispatch for a day, and each run-floor start
# cleared the only alarm. The hold is what stopped; a floor start goes past it without ending it.
@test "a hold stands across a run-floor start, and a start past an open gate ends it" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  export DISPATCH_PER_PASS=1 DISPATCH_RUN_FLOOR=0
  acct "main:pace::5 points over its weekly pace (17% used, 7% of its week gone, 5 points of slack)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  [ -s "$d/held_since" ] || fail "a BLOCKED pass left no held_since"
  echo "$(( $(date +%s) - 13 * 3600 - 30 ))" > "$d/held_since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output 'Dispatch stopped 13h00m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
  room_on_floor
  export DISPATCH_RUN_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-game on the run floor'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 13h00m: no account has room'
  # Negative control: an account with room again, and the next start ends the hold.
  acct alt:ok:/home/u/.claude-personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-app'
  assert_equal "$(outcome)" WORKED
  [ ! -e "$d/held_since" ] || fail "a start past an open gate left the hold standing"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_success
  assert_output ''
}

# 2026-11-06 (P3 live): the pass's own fleet-bench triage reported NOOP under AGENTCTL_NAME=fleet-dispatch,
# which ended the hold at the top of every pass, so the Stopped line never reached its threshold.
@test "the pass's fleet-bench triage reports under its own name and leaves the hold standing" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  export AGENTCTL_NAME=fleet-dispatch DISPATCH_PER_PASS=1 DISPATCH_RUN_FLOOR=0
  stub fleet-bench '[ "$1" = triage ] || exit 0; . "$HOME/.local/lib/agent-proof.sh"; proof_outcome "${AGENTCTL_NAME:-fleet-bench}" NOOP "every row already current"'
  acct "main:pace::5 points over its weekly pace"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  echo "$(( $(date +%s) - 2 * 3600 - 30 ))" > "$d/held_since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 2h00m: no account has room'
  grep -q 'every row already current' "$HOME/.local/state/agentctl/fleet-bench/activity.log" || fail "triage's outcome went nowhere"
  ! grep -q 'every row already current' "$d/activity.log" || fail "triage reported as fleet-dispatch"
}

@test "the run floor never lifts the load pace or a room refusal it cannot lift" {
  game_ready
  room_on_floor
  export DISPATCH_RUN_FLOOR=2
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over the'
  assert_not_called 'wt new'
  # an account in its reserve: room refuses whatever the slack
  echo "0.10 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  acct main:reserve
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'inside the last 15% kept for the human'
  assert_not_called 'wt new'
}

@test "the run floor lifts the pace reason alone: pace with the 5h window, committed burn or the reserve still refuses" {
  game_ready
  cpu 60 30 0 10
  export DISPATCH_RUN_FLOOR=2
  for r in pace,five_hour pace,committed reserve,pace; do
    acct "alt:$r:/home/u/.claude-personal"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_output --partial 'no account has room; alt is the closest'
    assert_not_called 'wt new'
  done
  # Negative control: the same account refused for its pace alone starts on the floor.
  acct alt:pace:/home/u/.claude-personal
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'on the run floor (DISPATCH_RUN_FLOOR=2)'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "a floor start takes an account with room before a better-ranked one past its pace" {
  game_ready
  export DISPATCH_RUN_FLOOR=2
  acct alt:pace:/home/u/.claude-personal bnb:ok:/home/u/.claude-bnb
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'on the run floor'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-bnb claude --model'
  assert_not_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude'
}

@test "dispatch reads room --json: no slack override, no prose parse, and starved asks once for both its reads" {
  run grep -nE 'CLAUDE_ACCT_PACE_SLACK_PCT|claude-acct room($|[^ ]| [^-])|#claude-acct: ' "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_failure
  queued_item old high "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"
  acct main:pace
  run cmd_starved
  assert_failure
  assert_equal "$(cat "$NOTES_FIXTURE/room.n")" 1
}

# 2026-11-06: reds sat queued behind a machine held by Unity CI (load 1.4x, 96.5 C), which the run
# floor does not lift. The human chose a floor of red starts of its own.
red_held_machine() {
  project game beta "$SANDBOX/repos/game"
  room_on_floor
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_RED_FLOOR=2
}

@test "red floor: a red starts past fleet-assess HOLD, load, real idle and the weekly pace; a plain item does not" {
  red_held_machine
  agent-queue add --project game --slug p --priority urgent "plain p" >/dev/null
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  # Negative control first: no red floor, the same machine starts nothing.
  export DISPATCH_RED_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD'
  assert_not_called 'wt new'
  export DISPATCH_RED_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item r on the red floor (DISPATCH_RED_FLOOR=2)'
  refute_output --partial 'started queue item p'
  assert_called 'account=.claude-personal'
  assert_equal "$(outcome)" WORKED
}

@test "red floor: it counts this pass's red starts, and past it the machine gates hold again" {
  red_held_machine
  export DISPATCH_RED_FLOOR=1
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project game --slug r2 --tags 'red cause:b' "fix r2" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r1 on the red floor'
  assert_output --partial 'the pass stops after 1 started'
  refute_output --partial 'started queue item r2'
}

@test "red floor: open only for a red start, under DISPATCH_RED_FLOOR counting live reds and this pass's" {
  live_reds() { printf '%s\n' "${LIVE[@]}"; }
  export DISPATCH_RED_FLOOR=2
  LIVE=(a); RED_PASS=1 run red_floor_open; assert_success
  LIVE=(a b); RED_PASS=1 run red_floor_open; assert_failure
  LIVE=(a); RED_STARTED=1 RED_PASS=1 run red_floor_open; assert_failure
  LIVE=(); RED_PASS=0 run red_floor_open; assert_failure
  LIVE=(); DISPATCH_RED_FLOOR=0 RED_PASS=1 run red_floor_open; assert_failure
}

@test "red floor: agent-hold and an account in its reserve still hold a red" {
  red_held_machine
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  stub agent-hold 'exit 0'
  acct main:reserve
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'inside the last 15% kept for the human'
  assert_not_called 'wt new'
}

# 2026-11-06 (P3 live): a red started on the red floor at 13:03 past a load hold while an account
# had room, and the hold that had stood since 10:48 ended: settle asked only for account room.
@test "red floor: a red start past the machine gates leaves the hold standing, with an account's room too" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  red_held_machine
  acct alt:ok:/home/u/.claude-personal
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  mkdir -p "$d"; echo "$(( $(date +%s) - 3 * 3600 - 30 ))" > "$d/held_since"; printf 'fleet-assess says HOLD' > "$d/held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r on the red floor'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 3h00m: fleet-assess says HOLD'
  # Negative control: the machine gates open, and the next start ends the hold.
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  cpu 5 5 0 90
  agent-queue add --project game --slug r2 --tags 'red cause:cd34' "fix r2" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r2'
  refute_output --partial 'r2 on the red floor'
  [ ! -e "$d/held_since" ] || fail "a start past open gates left the hold standing"
  [ ! -e "$d/held_why" ] || fail "a start past open gates left held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_success
  assert_output ''
}

# 2026-11-07: Unity and fleet work held every slot while trader's requested plans waited 5h behind
# real idle; no floor lifted it for a project nothing was working on.
idle_held_machine() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  room_on_floor
  acct alt:ok:/home/u/.claude-personal
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  export DISPATCH_RUN_FLOOR=0 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
}

@test "project floor: an idle project's first item starts past real idle; a busy project's waits" {
  idle_held_machine
  agent-queue add --project game --slug busy "game work" >/dev/null
  agent-queue move busy running >/dev/null
  agent-queue add --project game --slug g2 "more game work" >/dev/null
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project app --slug a2 "more app work" >/dev/null
  # Negative control first: no project floor, the same machine starts nothing.
  export DISPATCH_PROJECT_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'real idle'
  assert_not_called 'wt new'
  export DISPATCH_PROJECT_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item a1 on the project floor (DISPATCH_PROJECT_FLOOR=1)'
  refute_output --partial 'started queue item g2'
  refute_output --partial 'started queue item a2'
}

@test "project floor: one start a project even with room for more" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=2
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project app --slug a2 "more app work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item a1 on the project floor'
  refute_output --partial 'started queue item a2'
}

@test "project floor: an account past its pace, load and agent-hold still hold an idle project's item" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=1
  agent-queue add --project app --slug a1 "app work" >/dev/null
  acct alt:pace:/home/u/.claude-personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  acct alt:ok:/home/u/.claude-personal
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'is over the'
  assert_not_called 'wt new'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
}

@test "project floor: light items of idle projects, open only on a project pass under DISPATCH_PROJECT_FLOOR" {
  local items
  items=$(printf '%s\n' '{"slug":"g1","project":"game"}' '{"slug":"a1","project":"app"}' '{"slug":"a2","project":"app"}' '{"slug":"x1","project":"x"}')
  items+=$'\n''{"slug":"h1","project":"y","weight":"heavy"}'
  BUSY_PROJECTS=game run idle_project_items "$items"
  assert_output "$(printf '%s\n' '{"slug":"a1","project":"app"}' '{"slug":"a2","project":"app"}' '{"slug":"x1","project":"x"}')"
  export DISPATCH_PROJECT_FLOOR=1
  PROJECT_PASS=1 run project_floor_open; assert_success
  PROJECT_PASS=1 PROJECT_STARTED=1 run project_floor_open; assert_failure
  PROJECT_PASS=0 run project_floor_open; assert_failure
  DISPATCH_PROJECT_FLOOR=0 PROJECT_PASS=1 run project_floor_open; assert_failure
}

@test "starved names an item held on a cancelled ask, which no answer can release" {
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: dead1\nstatus: cancelled\nquestion: q?\n' > "$HOME/.agent/asks/game/dead1.md"
  printf 'id: live1\nstatus: pending\nquestion: q?\n' > "$HOME/.agent/asks/game/live1.md"
  agent-queue add --project game --slug k8 --tags 'ask:dead1' "kalshi p8" >/dev/null
  agent-queue add --project game --slug k9 --tags 'ask:live1' "waits on the human" >/dev/null
  # A machine held by load still names the dead hold and fails.
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_failure
  assert_output --partial 'held on an ask that can never be answered:'
  assert_output --partial 'k8 (game, ask:dead1 (cancelled))'
  refute_output --partial 'k9'
}

@test "room gone by the start: BLOCKED names the closest account and how far past its pace, from room's own line" {
  game_ready
  # the gate's ask finds room; the start's ask, a moment later, finds none
  acct alt:ok:/home/u/.claude-personal
  mv "$NOTES_FIXTURE/acct.json" "$NOTES_FIXTURE/acct.0.json"
  acct "alt:pace:/home/u/.claude-personal:1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack)"
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item gm-1 waits: no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack)'
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
  acct alt:ok:/home/u/.claude-personal
  stub claude-acct '[ "$1" = room ] && { cat "$NOTES_FIXTURE/acct.json"; exit 0; }; echo /wrong/pick'
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

@test "run at or over DISPATCH_LOW_WATER, with the cleanup floor off, does not read the board, and 0 reads it only for an empty queue" {
  game_ready
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2 DISPATCH_CLEANUP_FLOOR=0
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

@test "run over DISPATCH_LOW_WATER still tops cleanup rows up to DISPATCH_CLEANUP_FLOOR, as high, and nothing else" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  project game beta "$SANDBOX/repos/game"
  row game human 'new map' "- [ ] feat(game): a new map #high $T"
  row game human 'crash' "- [ ] fix(game): crash on load #low $T"
  verdict game human 'new map' dispatch S 1 maps
  verdict game human 'crash' dispatch S 1 crash
  agent-queue add --project game --slug one "one"
  agent-queue add --project game --slug two "two"
  agent-queue add --project game --slug three "three"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'runnable cleanup 0 is under the floor 2, topping cleanup up from the board'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "the floor did not promote the cleanup row"
  assert_equal "$(qfield "$f" title) | $(qfield "$f" priority) | $(qfield "$f" tags)" 'fix(game): crash on load | high | cleanup tier1'
  [ -z "$(qitem queued gm-2)" ] || fail "the floor promoted a row that is not cleanup"
}

@test "run with DISPATCH_CLEANUP_FLOOR cleanup items already runnable does not read the board, so a fresh cleanup row waits" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1 DISPATCH_CLEANUP_FLOOR=2
  project game beta "$SANDBOX/repos/game"
  row game human 'crash' "- [ ] fix(game): crash on load $T"
  verdict game human 'crash' dispatch S 1 crash
  agent-queue add --project game --slug c1 --tags cleanup "c1"
  agent-queue add --project game --slug c2 --tags cleanup "c2"
  agent-queue add --project game --slug c3 --tags cleanup "c3"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  # the pass starts c1, which leaves 2 runnable cleanup items: the floor is met (low water is 1, so only the floor decides)
  assert_output --partial 'started game-agent-1: game: c1'
  refute_output --partial 'under the floor'
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the floor read the board with the cleanup floor met"
  # negative control: with the floor at 3 the next pass starts c2, leaves 1 cleanup item, and promotes the same row
  export DISPATCH_CLEANUP_FLOOR=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'runnable cleanup 1 is under the floor 3'
  [ -n "$(qitem queued gm-1)" ] || fail "under the floor the cleanup row was not promoted"
}

@test "the cleanup floor's fill reads and judges only cleanup rows of the cleanup projects; a plain fill judges them all" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PROFILES=bnb
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game human 'new map' "- [ ] feat(game): a new map $T"
  row game human 'crash' "- [ ] fix(game): crash on load $T"
  row app human 'app crash' "- [ ] fix(app): crash on open $T"
  stub judge-stub 'printf "%s\n" "$@" > "$NOTES_FIXTURE/judge.prompt"; echo "{\"verdicts\":[]}"'
  DRY=0 JUDGE_RC='' fill_day 2 cleanup || true
  run cat "$NOTES_FIXTURE/judge.prompt"
  assert_output --partial '"key":"crash"'
  refute_output --partial '"key":"new map"'
  refute_output --partial '"key":"app crash"'
  # negative control: without the floor, the same fill judges every row
  rm -f "$NOTES_FIXTURE/judge.prompt"
  DRY=0 JUDGE_RC='' fill_day 2 || true
  run cat "$NOTES_FIXTURE/judge.prompt"
  assert_output --partial '"key":"new map"'
  assert_output --partial '"key":"app crash"'
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
  assert_output --partial 'could start now: 2 of 2 runnable (a pass starts up to 1, level mid)'
  assert_not_called 'wt new'
}

@test "headroom counts sessions started in the last few minutes against the load room, though the load has not moved" {
  two_items
  export DISPATCH_START_LOAD=1 DISPATCH_START_LOAD_MIN=5
  mkdir -p "$FLEET_DISPATCH_DIR"
  { printf -- '- %s started s1 on agents (hand) for app: queue item a\n' "$(date -d '-1 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s started s2 on agents (hand) for app: queue item b\n' "$(date -d '-2 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s started s3 on agents (hand) for app: queue item c\n' "$(date -d '-30 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s present start: queue item d\n' "$(date -d '-1 min' '+%Y-%m-%d %H:%M')"; } > "$FLEET_DISPATCH_DIR/log.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.starting, .load_pending, .load_room] | @tsv' <<<"$output")" "$(printf '2\t2.0\t%s' "$(awk -v c="$(nproc)" 'BEGIN { printf "%g", c * 0.7 - 0.1 - 2 }')")"
}

@test "a loop of hand starts is held once the starts not yet in the load fill the room, and an older start no longer counts" {
  two_items
  export DISPATCH_START_LOAD="$(nproc)" DISPATCH_START_LOAD_MIN=5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'2\t0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-app
  assert_success
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'0\t1'
  assert_equal "$(jq -r .held <<<"$output")" "load 0.10 plus $(nproc).0 for 1 started in the last 5 min on $(nproc) cores is over the 0.7 pace"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial "plus $(nproc).0 for 1 started in the last 5 min"
  # the start ages out of the window: the load average has had its minutes
  sed -i "s/^- [0-9-]* [0-9:]* started /- $(date -d '-6 min' '+%Y-%m-%d %H:%M') started /" "$FLEET_DISPATCH_DIR/log.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'1\t0'
}

@test "a pass's own earlier start counts against the load room too" {
  two_items
  export DISPATCH_START_LOAD="$(nproc)" DISPATCH_PER_PASS=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_output --partial 'for 1 started in the last 5 min on'
  assert_output --partial 'the pass stops after 1 started'
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

@test "the machine-mode level scales the start limits where they are read; mid is the conf's own" {
  mkdir -p "$HOME/.config/agentctl/agents"
  printf "NAME=fleet-dispatch\nDISPATCH_MAX_LIVE=24\nDISPATCH_MAX_LOAD='1.5'\nDISPATCH_PER_PASS=3\n" > "$HOME/.config/agentctl/agents/fleet-dispatch.conf"
  two_items
  run env -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.level, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'mid\t3\t1.5'
  mkdir -p "$HOME/.agent"; echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"
  run env -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.level, .per_pass, .load_cap / '"$(nproc)"', .max_live] | @tsv' <<<"$output")" $'high\t6\t2.1\t24'
  # Night items too, and into names of their own: the exported DISPATCH_* a child reads stay the conf's.
  export DISPATCH_PER_PASS=3 DISPATCH_NIGHT_MAX=6
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_equal "$PER_PASS $NIGHT_MAX $DISPATCH_PER_PASS $DISPATCH_NIGHT_MAX" "6 12 3 6"
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

# 2026-11-07 (ar-34, ar-5): one 2 s top frame swung 17-41%, and nice-19 Unity work counted as busy.
@test "real idle is the window's /proc/stat delta with nice counted free, not the since-boot total" {
  game_ready
  cpu 60 5 25 10
  export DISPATCH_MIN_IDLE=40
  refuses 'real idle 35.0% is under 40%'
  assert_called "sleep $DISPATCH_IDLE_WINDOW"
}

@test "headroom: a high-nice sample opens the idle gate; a forced 5% idle still holds" {
  two_items
  export DISPATCH_MIN_IDLE=20
  cpu 30 5 55 10
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.could_start, .idle, .min_idle, .held] | @tsv' <<<"$output")" $'2\t65.0\t20\t'
  # Negative control: the same sample with the nice time busy is under the floor.
  cpu 85 5 0 10
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .held <<<"$output")" 'real idle 10.0% is under 20%'
  cpu 90 5 0 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" $'0\treal idle 5.0% is under 20%'
}

@test "one real idle sample serves every gate for a window, then the next read samples again" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(grep -c '^sleep ' "$NOTES_FIXTURE/calls.log")" 1
  echo "$(( $(date +%s) - DISPATCH_IDLE_WINDOW )) 90.0" > "$FLEET_DISPATCH_DIR/idle"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(grep -c '^sleep ' "$NOTES_FIXTURE/calls.log")" 2
}

@test "real idle: a sample from the future is no sample, and a floor start takes none" {
  game_ready
  echo "$(( $(date +%s) + 3600 )) 99.0" > "$FLEET_DISPATCH_DIR/idle"
  cpu 85 5 0 10
  run real_idle
  assert_output '10.0'
  # Negative control: the same gate off every floor waits out a sample.
  rm -f "$FLEET_DISPATCH_DIR/idle" "$NOTES_FIXTURE/calls.log"
  floor_open() { return 0; }
  run gate
  assert_not_called 'sleep'
  floor_open() { return 1; }
  run gate
  assert_output --partial 'real idle 10.0% is under 30%'
  assert_called "sleep $DISPATCH_IDLE_WINDOW"
}

@test "run starts nothing while real idle cannot be read" {
  game_ready
  rm -f "$DISPATCH_PROC_STAT"
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
  grep -q 'outcome=FAILED why: could not judge the new rows (the reply had no verdicts)' \
    "$HOME/.local/state/agentctl/fleet-dispatch/activity.log"
}

@test "a judge budget stop leaves no error verdict, and a pass with nothing else to do is BLOCKED, exit 0" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  stub judge-stub 'echo "agentctl-run: dispatch-judge over its daily budget" >&2; exit 75'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'judge stopped at its budget'
  assert_equal "$(outcome)" BLOCKED
  grep -q 'outcome=BLOCKED why: budget: could not judge the new rows (stopped at its budget)' \
    "$HOME/.local/state/agentctl/fleet-dispatch/activity.log" || fail "$(cat "$HOME/.local/state/agentctl/fleet-dispatch/activity.log")"
  # touched, not written: board_starved reads the mtime, and this stop is already published
  [ -f "$FLEET_DISPATCH_DIR/verdicts.jsonl" ] && [ ! -s "$FLEET_DISPATCH_DIR/verdicts.jsonl" ] || fail "$(cat "$FLEET_DISPATCH_DIR/verdicts.jsonl")"
}

@test "a judge budget stop does not stop the pass: a row the cache already judged still starts" {
  game_ready
  row game human 'fix the new crash' "- [ ] fix the new crash $T"
  stub judge-stub 'exit 75'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'judge stopped at its budget'
  assert_equal "$(outcome)" WORKED
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

# approved_plan <name> <session> [phases] -- a plan file and its ledger line, as plan-approved.sh writes it.
approved_plan() {
  export PLAN_LEDGER="$SANDBOX/approved.jsonl"
  printf '# Plan\n\n## Phases\n\n%b\n' "${3:-- [x] one\n- [ ] two\n- [ ] three}" > "$SANDBOX/$1.md"
  jq -nc --arg p "$SANDBOX/$1.md" --arg s "$2" --argjson e "$(date +%s)" \
    '{epoch: $e, plan: $p, project: "game", session: $s, cwd: "/x"}' >> "$PLAN_LEDGER"
}

@test "reap queues the open phases of an approved plan whose session is gone, as night items, and starts nothing" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  run reconcile_plans
  assert_success
  run agent-queue list --json --state queued
  assert_equal "$(jq -r .slug <<<"$output" | paste -sd,)" 'orphan-p2,orphan-p3'
  assert_equal "$(jq -r .tags <<<"$output" | sort -u)" 'night'
  assert_equal "$(jq -r .from <<<"$output" | sort -u)" 'auto:plans'
  grep -q 'orphan.md for the night' "$FLEET_DISPATCH_DIR/log.md"
}

@test "reap queues nothing for a live session, a recent transcript, a finished plan or a plan an item names" {
  stub agent-ask 'echo live-session'
  approved_plan live live-session
  approved_plan fresh fresh-session
  mkdir -p "$HOME/.claude-x/projects/p"; : > "$HOME/.claude-x/projects/p/fresh-session.jsonl"
  approved_plan finished gone-session '- [x] one\n- [-] two'
  approved_plan none gone-session 'no checklist here'
  approved_plan named gone-session
  agent-queue add --project game --from shepherd --slug peer "carry on with $SANDBOX/named.md" >/dev/null
  run reconcile_plans
  assert_success
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" peer
}

@test "reap reads a queue too big for one argument: plans_orphaned finds the orphan and honours an item that names a plan" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  approved_plan named gone-session
  # 600 items of about 1 KB each: past MAX_ARG_STRLEN (128 KB), so --argjson would fail with E2BIG
  stub agent-queue 'pad=$(head -c 1000 /dev/zero | tr "\0" x)
for i in $(seq 600); do printf "{\"slug\":\"i%s\",\"task\":\"%s\"}\n" "$i" "$pad"; done
printf "{\"slug\":\"last\",\"task\":\"carry on with %s/named.md\"}\n" "'"$SANDBOX"'"'
  run plans_orphaned
  assert_success
  assert_equal "$(jq -r .plan <<<"$output")" "$SANDBOX/orphan.md"
}

@test "plans_orphaned fails when the queue cannot be read: agent-queue exits 1, or prints what is not JSON" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  stub agent-queue 'exit 1'
  run plans_orphaned
  assert_failure
  stub agent-queue 'echo not json'
  run plans_orphaned
  assert_failure
}

@test "reap acts on nothing when it cannot read the sessions, or when reconcile is off" {
  approved_plan orphan gone-session
  stub agent-ask 'exit 1'
  run reconcile_plans
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
  stub agent-ask 'echo other-session'
  DISPATCH_PLAN_RECONCILE=0 run reconcile_plans
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
}

@test "reap queues a plan once: a phase that failed or was cancelled does not come back" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  reconcile_plans
  agent-queue cancel orphan-p3 >/dev/null
  agent-queue cancel orphan-p2 >/dev/null
  run reconcile_plans
  assert_success
  assert_equal "$(agent-queue list --json --state queued | jq -r .slug)" ''
}

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
@test "reap moves an item to waiting while its session waits on the human or stopped on a pending ask, and back after" {
  project game beta "$SANDBOX/repos/game"
  started_item p lab:game-agent-1
  started_item q lab:game-agent-2
  started_item r lab:game-agent-3
  started_item s lab:game-agent-4
  printf 'game-agent-%s\n' 1 2 3 4 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'for x in 1:waiting 2:idle 3:busy 4:shell; do echo "{\"target\":\"lab/game-agent-${x%:*}:1\",\"status\":\"${x#*:}\"}"; done'
  stub agent-ask 'for n in 2 3 4; do printf "a$n\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-03\tgame-agent-$n\n"; done'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting p)" ] || fail "the session at its plan is not waiting"
  [ -n "$(qitem waiting q)" ] || fail "the session stopped on a pending ask is not waiting"
  # carrying on past its ask: busy, or in a shell (agent-panel's own working pair, so a gate never flaps)
  [ -n "$(qitem running r)" ] && [ -n "$(qitem running s)" ] || fail "a session still working past its ask moved to waiting"

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
  export DISPATCH_REAP_CONFIRM=0   # the second witness has its own test
  cmd_reap >/dev/null
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
  export DISPATCH_REAP_CONFIRM=0   # the second witness has its own test
  cmd_reap >/dev/null
  run cmd_reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-hubgone.md 2>/dev/null)" ] || fail "a hub item with no live session stayed active"
  [ -n "$(qitem running hublive)" ] || fail "reaped a hub item whose session is live"
  grep -q 'reaped h2' "$FLEET_DISPATCH_DIR/log.md" || fail "the log does not name the session: $(cat "$FLEET_DISPATCH_DIR/log.md")"
  stub agent-panel 'exit 0'
  started_item hubblind ''
  sed -i '/^session: *$/d; s/^agent: claude/agent: claude\nsessions: h9/' "$AGENT_QUEUE_DIR"/running/*-hubblind.md
  cmd_reap >/dev/null
  run cmd_reap
  [ -n "$(qitem running hubblind)" ] || fail "reaped on an empty panel"
}

# 2026-11-07 ar-900: one agent-panel read under load 33 left a live session out, and reap failed an
# urgent item whose re-read a minute later listed it. A miss is one witness; the gone verdict needs a
# second reap, DISPATCH_REAP_CONFIRM seconds or more later, that misses it too.
@test "reap fails a live-looking item only on two misses: one miss keeps it, a sighting between resets it, a quick re-run is no witness" {
  project game beta "$SANDBOX/repos/game"
  started_item flaky lab:game-agent-1 '' '' board:game:gm-7
  sed -i 's/^agent: claude/agent: claude\nsessions: s1\nrow: game:gm-7/' "$AGENT_QUEUE_DIR"/running/*-flaky.md
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-ask 'exit 0'
  miss() { stub agent-panel 'echo "{\"target\":\"lab/other-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'; }
  seen() { stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\",\"session_id\":\"s1\"}"'; }
  mark="$FLEET_DISPATCH_DIR/reap-miss/flaky"
  # The 09:35 read: a non-empty panel that leaves the session out. One miss is not the verdict.
  miss; run cmd_reap; assert_success
  [ -n "$(qitem running flaky)" ] || fail "one agent-panel miss failed the item"
  [ -s "$mark" ] || fail "the miss was not recorded"
  # A re-run seconds later shares the same load, so it is no second witness.
  run cmd_reap
  [ -n "$(qitem running flaky)" ] || fail "a re-run inside DISPATCH_REAP_CONFIRM counted as a second witness"
  # The next read lists it: the miss is forgotten, and a later single miss starts over.
  seen; run cmd_reap
  [ -n "$(qitem running flaky)" ] && [ ! -e "$mark" ] || fail "a sighting did not clear the miss"
  miss; run cmd_reap
  [ -n "$(qitem running flaky)" ] || fail "a miss after a sighting failed the item"
  # A second miss a reap later (the mark aged past DISPATCH_REAP_CONFIRM) settles it, and its close
  # drops the mark at once, so an item agent-queue reopen puts back starts with no miss on record.
  echo $(( $(date +%s) - DISPATCH_REAP_CONFIRM - 1 )) > "$mark"
  run cmd_reap; assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-flaky.md 2>/dev/null)" ] || fail "two misses a reap apart did not settle the item"
  [ ! -e "$mark" ] || fail "the closed item's mark survived its close"
  # A mark whose slug is no longer active (an item closed some other way) is pruned on a pass that read
  # active items; a pass that read none (the queue may not have been readable) keeps them.
  echo 1 > "$mark"
  run cmd_reap
  [ -e "$mark" ] || fail "a pass that read no active item pruned the marks"
  started_item other lab:game-agent-1
  run cmd_reap
  [ ! -e "$mark" ] || fail "a stale mark survived a reap that read active items"
}

# Confirmed gone stays gone: settle_item leaves an item whose PR is open waiting, and it must not
# re-enter the mark-then-confirm cycle, logging a fresh miss and settling half as often.
@test "reap keeps a confirmed miss for an item it leaves waiting on its open PR" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  sed -i 's/^agent: claude$/agent: claude\nsessions: old-1/' "$AGENT_QUEUE_DIR"/waiting/*-fix-crash.md
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-1:1\",\"status\":\"busy\",\"session_id\":\"new-1\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0
  for _ in 1 2 3 4; do cmd_reap >/dev/null; done
  [ -n "$(qitem waiting fix-crash)" ] || fail "the item left waiting"
  [ -e "$FLEET_DISPATCH_DIR/reap-miss/fix-crash" ] || fail "the confirmed mark was dropped"
  run grep -c 'is not on agent-panel' "$FLEET_DISPATCH_DIR/log.md"
  assert_output 1
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

@test "start --row matches the row's id whatever its case, and queues the item under the lower-case id" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 '- [ ] tidy the loader <!-- id:gm-1 -->'
  printf '/one-shot tidy the loader\n' > "$SANDBOX/brief.md"
  stub wt 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; printf "%s\n" "$WT_NEW_CMD" > "$NOTES_FIXTURE/cmd"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game --agent --row GM-1 --brief "$SANDBOX/brief.md"
  assert_success
  assert_output --partial 'started game-agent-1: game: gm-1'
  [ -n "$(qitem running gm-1)" ] || fail "the row's item is not running under gm-1"
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
  # --resume keeps the conversation's id, so the item claims that one: the session's own start no longer does.
  assert_equal "$(qfield "$f" sessions)" 'abc-123'

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
  # The session id is chosen at launch and claimed on the item here, before the session's preflight.
  sid=$(grep -o -- '--session-id [0-9a-f-]*' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d' ' -f2)
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "no session id in the launch: $sid"
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/running/*.md)" sessions)" "$sid"
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
      clear: true, agent_only: true, tier3_only: $t3, rule: "tier3", reason: "tier 3", policy: $sig, line: $line}' \
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

@test "night: a tier-3 row that is not cleanup never becomes a merging item, even with a dispatch verdict" {
  night_ready
  echo '{"board": {"max_tier": 9, "projects": ["agent-runtime"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  row agent-runtime agent 'add the timer panel' '- [ ] feat(timer): add a timer panel #tier/3'
  verdict agent-runtime agent 'add the timer panel' dispatch S 3 timer
  night_verdict 'add the timer panel' timer

  run cmd_candidates
  assert_output ''
  run picks "$(all_open)" 5
  assert_output ''
  fill
  assert_equal "$(night_keys)" 'add the timer panel'
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
}

@test "cleanup lane: a tier-3 cleanup row S or M is a merging item at noon behind the red-fix gate; feat, a deps bump, L and night rows are not" {
  night_ready
  export AGENT_QUEUE_NIGHT=01:00-06:00 AGENT_QUEUE_NOW=12:00
  row agent-runtime agent 'drop the dead timer' '- [ ] chore(timer): drop the dead timer #tier/3 #low'
  row agent-runtime agent 'prune the hooks' '- [ ] refactor(hooks): prune the dead hooks #tier/3'
  row agent-runtime agent 'add a panel' '- [ ] feat(panel): add a timer panel #tier/3'
  # A chore that bumps a dependency is shared infrastructure (DISPATCH_CLEANUP_NOT), not cleanup.
  row agent-runtime agent 'bump jq' '- [ ] chore(deps): bump jq to 1.8 #tier/3'
  night_verdict 'drop the dead timer' timer; night_verdict 'prune the hooks' hooks true L; night_verdict 'add a panel' panel; night_verdict 'bump jq' jq

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "ready") | "\(.key) \(.worker)"' <<<"$output")" 'drop the dead timer tier3-cleanup'
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | sort | paste -sd, -)" 'add a panel,bump jq'
  fill
  assert_success
  f=$(agent-queue list --json --state queued | jq -r 'select(.title | test("drop the dead timer")) | .slug')
  [ -n "$f" ] || fail "the cleanup row was not queued"
  run agent-queue show "$f" --json
  assert_equal "$(jq -r '"\(.tags) | \(.priority) | \(.hold // "")"' <<<"$output")" 'cleanup tier3 | high | '
  run item_brief "$output"
  refute_output --partial -- '--pr-only'
  assert_output --partial 'agent-land refuses a tier-3 PR without that line'
  assert_output --partial 'Merge with agent-land'
  # The L cleanup row is neither merging nor night: plan_skips sends it to inbox-plan.
  [ "$(state_of 'prune the hooks')" = '- [ ]' ] || fail "an L cleanup row was started"
  assert_equal "$(night_keys)" 'add a panel,bump jq'
}

@test "cleanup lane: a tier-3 cleanup pick ranks with its project's #prio, as a day pick does" {
  night_ready
  sed -i '1s/$/ #prio\/focus/' "$SANDBOX/sheets/agent-runtime/README.md"
  row agent-runtime agent 'drop the dead timer' '- [ ] chore(timer): drop the dead timer #tier/3'
  night_verdict 'drop the dead timer' timer
  run t3_cleanup_picks "$(night_rows '')"
  assert_success
  assert_equal "$(jq -r '"\(.pprio) \(.why)"' <<<"$output")" '0 cleanup, focus project, tier3-cleanup, #high, alpha'
}

@test "item_tier: an untiered item on a harness project is tier 3, whoever queued it; a tier tag, the text, or another project says otherwise" {
  t() { jq -cn --arg p "$1" --arg tags "$2" --arg title "$3" '{slug: "s", mode: "oneshot", project: $p, tags: $tags, title: $title, task: $title}'; }
  assert_equal "$(item_tier "$(t agent-runtime '' 'chore(hooks): prune them')")" 3
  assert_equal "$(item_tier "$(t notes-cockpit '' 'fix: x')")" 3
  assert_equal "$(item_tier "$(t agent-runtime 'cleanup tier2' 'fix: x')")" 2
  assert_equal "$(item_tier "$(t agent-runtime '' 'fix: x #tier/1')")" 1
  assert_equal "$(item_tier "$(t game '' 'fix: x')")" 1
  assert_equal "$(item_tier "$(t game 'night' 'fix: x')")" 3
  # A hand-added harness item is told the gate at start, and agent-land reads the same answer.
  run item_brief "$(t agent-runtime '' 'chore(hooks): prune them')"
  assert_output --partial 'This is tier 3 (harness or tooling)'
  run item_brief "$(t game '' 'fix: x')"
  refute_output --partial 'This is tier 3'
  agent-queue add --project agent-runtime --slug hand "chore(hooks): prune them" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier hand
  assert_success
  assert_output 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier nosuch
  assert_failure
}

@test "night: only rows tier 3 alone holds back; a requested row goes, decisions, devices, the human's machine and lower tiers stay out" {
  night_ready
  row agent-runtime agent 'requested row' '- [ ] fix the requested row #requested #tier/3'
  row agent-runtime agent 'decide(app): fold it' '- [ ] decide(app): fold it #tier/3'
  row agent-runtime agent 'typed decide' '- [ ] decide(board): fold it #tier/3'
  row agent-runtime agent 'pad run' '- [ ] fix the pad controller switch #tier/3'
  row agent-runtime agent 'waybar row' '- [ ] waybar: fix pulse colours #tier/3'
  row agent-runtime agent 'tier two' '- [ ] fix the tier two row #tier/2'
  row agent-runtime agent 'unclear' '- [ ] fix something somewhere #tier/3'
  row agent-runtime agent 'started' '- [/] fix the started row #tier/3'
  row agent-runtime agent 'untagged' '- [ ] fix the untagged row'
  for k in 'requested row' 'decide(app): fold it' 'typed decide' 'pad run' 'waybar row' 'tier two' 'started' 'untagged'; do night_verdict "$k"; done
  night_verdict unclear unclear false

  run night_rows ''
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'requested row,unclear,untagged'
  fill
  assert_success
  assert_equal "$(night_keys)" 'requested row,untagged'
}

@test "night: a #requested row takes a slot ahead of an older #high row" {
  night_ready
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #high'
  row agent-runtime agent 'route the reds' '- [ ] route the reds to owners #requested #low'
  night_verdict 'retire the hook' timers; night_verdict 'route the reds' reds
  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | paste -sd,)" 'route the reds,retire the hook'
}

@test "night: at most 3 active, one an area: observer rows first, then #high, newest first" {
  night_ready
  row agent-runtime agent 'add a panel' '- [ ] add a panel for y #high'
  row agent-runtime agent 'shorter briefs' '- [ ] shorter briefs for night items #kpi/board_open #high'
  row agent-runtime agent 'add a column' '- [ ] add a column to z #high'
  row agent-runtime agent 'retire the timer' '- [ ] retire the dead timer #low'
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #low'
  row agent-runtime agent 'add w' '- [ ] add w #low'
  night_verdict 'add a panel'; night_verdict 'shorter briefs'; night_verdict 'add a column'
  night_verdict 'retire the timer' timers; night_verdict 'retire the hook' timers; night_verdict 'add w'

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | paste -sd,)" 'shorter briefs,add a column,add a panel'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  [ "$(state_of 'shorter briefs')" = '- [ ]' ] || fail "fill --dry-run started a row"
  fill
  assert_success
  assert_equal "$(night_keys)" 'add a column,add a panel,shorter briefs'
  [ "$(state_of 'retire the hook')" = '- [ ]' ] || fail "a fourth row was started"
  fill
  assert_equal "$(agent-queue list --json --state queued | grep -c .)" 3
}

@test "night: a typed finding and a #kpi/ row rank as observer rows, the word kpi in a body does not" {
  night_ready
  row agent-runtime agent 'add a kpi chip' '- [ ] add a kpi: chip to the hub #high'
  row agent-runtime agent 'check kpi' '- [ ] check(kpi): board_open past threshold #low'
  row agent-runtime agent 'tagged' '- [ ] shorter briefs #kpi/ask_answered_pct #low'
  night_verdict 'add a kpi chip'; night_verdict 'check kpi'; night_verdict 'tagged'

  fill --dry-run --json
  # Both observer rows rank ahead of the #high row that only names kpi in its body.
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | tail -1)" 'add a kpi chip'
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | head -2 | sort | paste -sd,)" 'check kpi,tagged'
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
  acct alt:ok:/acct/alt
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
  acct
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3'
  row agent-runtime agent 'decide(app): fold it' '- [ ] decide(app): fold it #tier/3'
  night_verdict 'wt done never reaps' wt
  night_verdict 'decide(app): fold it' fold

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

@test "policy_sig: a workers.json edit keeps every verdict fresh; a policy edit judges again, and keeps the old verdict meanwhile" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'judged' "- [ ] judged $T"
  verdict game agent 'judged' skip
  echo '{"fleet": {"max_tier": 1, "lane": "agent"}}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
  echo 'policy v3' >> "$DISPATCH_POLICY"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'judged'
  # The edit voids nothing: the old verdict still counts as the row's verdict.
  run cmd_suggest --json
  assert_equal "$(jq -r .verdict <<<"$output")" skip
}

@test "judge: after a policy edit rows with no verdict go first, then a stale dispatch, then a stale skip; a reply that names no rule keeps the stale verdict" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"game\",\"lane\":\"agent\",\"key\":\"oldskip\",\"verdict\":\"skip\",\"rule\":\"nope\"}]}"'
  project game beta "$SANDBOX/repos/game"
  row game agent 'oldskip' "- [ ] oldskip $T"
  row game agent 'olddisp' "- [ ] olddisp $T"
  row game agent 'fresh' "- [ ] fresh $T"
  verdict game agent 'oldskip' skip
  verdict game agent 'olddisp' dispatch
  echo 'policy v2' >> "$DISPATCH_POLICY"
  cand() { jq -nc --arg k "$1" --arg l "$(line_of game agent "$1")" '{project:"game",stage:"beta",lane:"agent",key:$k,text:("- [ ] " + $k),prio:1,line:$l}'; }
  DISPATCH_JUDGE_MAX=3 run judge "$(cand oldskip)
$(cand olddisp)
$(jq -nc '{project:"game",stage:"beta",lane:"agent",key:"fresh",text:"- [ ] fresh",prio:1}')"
  assert_equal "$(grep -o '"key":"[a-z]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd,)" 'fresh,olddisp,oldskip'
  # The reply named a rule the policy lacks: that is an error record, and it leaves both stale verdicts in force.
  assert_equal "$(latest_verdicts | jq -r 'select(.key == "oldskip" or .key == "olddisp") | .verdict' | paste -sd,)" 'dispatch,skip'
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

@test "judge: a cleanup row goes first within a round, never ahead of it; a project with no cleanup row still gets its slot" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1,"cleanup":0}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}'
  assert_success
  # Cleanup ahead of the rounds sent p1, p2, p3 and never a1.
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
  acct
  echo '99.00 99.00 99.00 1/1 1' > "$DISPATCH_LOADAVG"
  run gate
  assert_output --regexp '^no account has room under its weekly pace and after its live sessions; load 99.00 on [0-9]+ cores is over the [0-9.]+ pace$'
  stub claude-acct 'exit 2'
  run gate
  assert_output --partial 'account usage unreadable (claude-acct room --json gave no answer); load 99.00'
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
  assert_not_called 'model-lane classify Fix the menu sides --floor sonnet --size'
  assert_called 'claude --model sonnet'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" lane_run)" 'sonnet run-7'
}

@test "the model-lane pick reads the item's headline and #size tag, never its body or weight" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high --weight heavy --title "fix(menu): sides overlap" \
    "Fix the menu sides #size/s. Repo note: dotfiles-land says which repo; merge and deploy when done." >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"llm\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-7 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'model-lane classify fix(menu): sides overlap --floor sonnet --size s'
  assert_not_called 'model-lane classify Fix the menu sides'
  assert_not_called 'weight'
  assert_called 'model-lane log --item fix-menu --task fix(menu): sides overlap --lane sonnet'
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

@test "red: a red item merges its own PR: no --pr-only, and its brief names fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r"
  cmd_start --item r >/dev/null || fail "start r"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial '/one-shot fix r'
  refute_output --partial '--pr-only'
  assert_output --partial 'read ~/.claude/skills/fix-red/SKILL.md first'
  assert_output --partial 'Merge with agent-land <N>'
}

@test "canary: a canary item starts on its task as written: no /one-shot and no PR or landing lines" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug c --from canary --tags 'night canary' "Canary eval c: run fleet-bench canary start c" >/dev/null
  cmd_start --item c >/dev/null || fail "start c"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --regexp 'bypassPermissions Canary\\ eval\\ c:\\ run\\ fleet-bench\\ canary\\ start\\ c$'
  refute_output --partial '/one-shot'
  refute_output --partial 'agent-land'
  refute_output --partial 'PR body'
}

@test "red: a plain item's brief does not name fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug p --tags 'night' "fix p"
  cmd_start --item p >/dev/null || fail "start p"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial 'fix-red'
}

@test "next_items keeps the queue's order (agent-queue owns it), drops a waiting board item and a gateway one" {
  runnable() {
    printf '%s\n' '{"slug":"r1","waits":false,"tags":"red"}' '{"slug":"w","waits":true}' '{"slug":"c","waits":false,"tags":"cleanup"}' \
      '{"slug":"g","waits":false,"agent":"lazer"}' '{"slug":"a","waits":false}'
  }
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'r1 c a '
}

@test "next_items from the real queue: a low red, then high cleanup, then an older plain high" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug plain "plain"
  agent-queue add --project game --slug tidy --tags cleanup "tidy"
  agent-queue add --project game --slug broke --priority low --tags 'red cause:ab12' "broke"
  stub fleet-presence 'echo away 0 x'
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'broke tidy plain '
}

@test "red: a board item with the red tag does not wait while the human is here, a plain one does" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug p --from board:game:p "plain"
  agent-queue add --project game --slug r --from board:game:r --tags 'red cause:ab12' "red one"
  stub fleet-presence 'echo here 0 x'
  present_left() { echo 0; }
  run runnable
  assert_success
  assert_equal "$(jq -r 'select(.slug == "p") | .waits' <<<"$output")" true
  assert_equal "$(jq -r 'select(.slug == "r") | .waits' <<<"$output")" false
}

# ar-545: on 2026-11-06 dispatch was held and every start was a hand, plan or after: start, which
# defaulted to opus (35 opus items to 5 sonnet). The pick lives in cmd_start, so every start gets it.
@test "a hand start with no --model starts the model-lane pick and logs the run" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-8 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_called 'model-lane classify Fix the menu sides --floor sonnet'
  assert_called 'claude --model sonnet'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" origin) $(qfield "$f" lane_run)" 'sonnet hand run-8'
}

# ar-617: the Queue table's SIZE column reads the item, not the board, so start writes the size the
# task's #size/ tag gives next to account= and model=, in any case as row_size reads it; an
# unsized item gets no size line.
@test "start --item writes size= from the task's #size/ tag, and none for an unsized item" {
  game_ready
  agent-queue add --project game --slug sized "Fix the menu sides #size/M" >/dev/null
  agent-queue add --project game --slug plain "Fix the menu top" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item sized
  assert_success
  assert_equal "$(qfield "$(qitem running sized)" size)" m
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item plain
  assert_success
  ! grep -q '^size:' "$(qitem running plain)" || fail "wrote a size for an unsized item"
}

@test "a hand start whose model-lane fails starts opus and logs nothing" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_called 'model-lane classify'
  assert_called 'claude --model opus'
  assert_not_called 'model-lane log'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run that was never logged"
}

@test "an explicit --model wins over the lane: no classify, no log" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-8 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --model opus
  assert_success
  assert_called 'claude --model opus'
  assert_not_called 'model-lane'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run for a model the human chose"
}

@test "triage: a run pass triages before it counts its room, and a dry run does not" {
  stub fleet-bench 'echo "fleet-bench $*" >> "$NOTES_FIXTURE/calls.log"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_not_called 'fleet-bench triage'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called 'fleet-bench triage'
}

@test "triage: a failed triage is named in the pass and turns a quiet pass FAILED, and the pass still runs" {
  stub fleet-bench '[ "$1" = triage ] && { echo "board unreadable"; exit 1; }; exit 0'
  TRIAGE_FAILED='board unreadable' DRY=1
  run settle NOOP 'nothing to do'
  assert_output --partial 'triage failed (board unreadable); nothing to do'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'triage failed (board unreadable)'
}

@test "a queue item runs /one-shot in bypass mode, a night item --pr-only, a plan item in plan mode" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug n --tags night "do n"
  agent-queue add --project game --slug p --mode plan "plan p"
  for s in a n p; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial 'AGENT_QUEUE_ITEM=a env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode bypassPermissions'
  assert_output --partial '/one-shot do a'
  assert_output --partial '/one-shot --pr-only do n'
  assert_output --partial 'AGENT_QUEUE_ITEM=p env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode plan --allow-dangerously-skip-permissions'
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
  agent-queue set a pr=12 merged=0123abcd
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

# 2026-11-07: ar-255 sat waiting on its open PR, its lane got a new Claude, and reap read that one
# as the item's: back to running, and fleet-sessions held the new session STALLED on it.
@test "reap: a recycled lane is not the session of an item that records its own ids" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  sed -i 's/^agent: claude$/agent: claude\nsessions: old-1/' "$AGENT_QUEUE_DIR"/waiting/*-fix-crash.md
  started_item mine lab:game-agent-2
  sed -i 's/^agent: claude$/agent: claude\nsessions: s2/' "$AGENT_QUEUE_DIR"/running/*-mine.md
  started_item lane lab:game-agent-3
  started_item away lab:game-agent-4
  sed -i 's/^agent: claude$/agent: claude\nsessions: s4/' "$AGENT_QUEUE_DIR"/running/*-away.md
  printf 'game-agent-%s\n' 1 2 3 4 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'for x in 1:busy:new-1 2:idle:s2 3:busy:s3 4:busy:new-4; do IFS=: read -r n st id <<<"$x"; echo "{\"target\":\"lab/game-agent-$n:1\",\"status\":\"$st\",\"session_id\":\"$id\"}"; done
    echo "{\"target\":\"hub/dotfiles:5\",\"status\":\"waiting\",\"session_id\":\"s4\"}"'
  stub agent-ask 'printf "a1\tgame\t\tpending\tquestion\tq?\ta|b\t\t\t\tb\t2026-11-07\tgame-agent-2\t\t\ts2\n"'
  run cmd_reap
  assert_success
  [ -n "$(qitem waiting fix-crash)" ] || fail "a new Claude in the lane flipped the item back to running"
  # its own Claude, matched by id, stopped on an ask: waiting; no ids recorded: the lane decides
  [ -n "$(qitem waiting mine)" ] || fail "the item's own Claude on a pending ask did not read waiting"
  [ -n "$(qitem running lane)" ] || fail "an item with no ids lost its lane"
  [ -n "$(qitem waiting away)" ] || fail "the flip read the lane's busy Claude, not the item's own waiting one"
  # agent-panel lists no codex thread, so a codex item's ids say nothing and its lane still decides
  started_item cx lab:game-agent-5 '' '' human waiting
  sed -i 's/^agent: claude$/agent: codex\nsessions: thread-1/' "$AGENT_QUEUE_DIR"/waiting/*-cx.md
  printf 'game-agent-%s\n' 1 2 3 4 5 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-5:1\",\"status\":\"waiting\",\"session_id\":\"c5\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem waiting cx)" ] || fail "a codex item's thread ids flipped it to running"
  # a running item whose lane went to another Claude settles on its open PR: the passes above missed it once already
  agent-queue move fix-crash running >/dev/null
  DISPATCH_REAP_CONFIRM=0 run cmd_reap
  assert_output --partial 'waiting queue item fix-crash (PR o/game#12 open'
  # its own Claude back on the panel: running is left alone
  agent-queue move fix-crash running >/dev/null
  stub agent-panel 'echo "{\"target\":\"hub/dotfiles:3\",\"status\":\"busy\",\"session_id\":\"old-1\"}"'
  stub agent-ask 'exit 0'
  run cmd_reap
  [ -n "$(qitem running fix-crash)" ] || fail "reaped an item whose own Claude is live"
}

@test "reap: a --pr-only item its session left waiting closes ok with merged: once the PR merges" {
  pr_item OPEN
  agent-queue move fix-crash waiting >/dev/null
  run cmd_reap
  assert_equal "$(agent-queue show fix-crash --json | jq -r .state)" waiting
  printf 'MERGED %s\n' "$OID" > "$NOTES_FIXTURE/pr.state"
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  f=$(ls "$AGENT_QUEUE_DIR"/done/*/*-fix-crash.md)
  assert_equal "$(qfield "$f" status) $(qfield "$f" merged)" "ok $OID"
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

# landed_item <state> [pr] -- pr_item's item closed ok by its own session with no merged: recorded,
# as a --pr-only run left it before agent-queue refused that close (the store still holds those):
# the row stays started and no active item names it.
landed_item() {
  export DISPATCH_NIGHT_PROFILE=bnb
  pr_item "$1"
  agent-queue set fix-crash pr= >/dev/null
  agent-queue move fix-crash done --status ok >/dev/null
  agent-queue set fix-crash "pr=${2:-o/game#12}" >/dev/null
}

@test "reap: a done item's PR merged after its session closed it records merged: and closes the row on merge proof" {
  landed_item MERGED
  run cmd_reap
  assert_success
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR o/game#12 merged)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .merged)" "$OID"
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
}

@test "reap: a done item with merged: recorded closes its row with no gh call" {
  landed_item MERGED
  agent-queue set fix-crash "merged=$OID" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  ! grep -q '^gh ' "$NOTES_FIXTURE/calls.log" || fail "read gh for a recorded merge"
}

@test "reap: an item with one PR per repo closes its row on its first PR's merge proof" {
  # NEGATIVE CONTROL: the whole list as one ref gave merge_proof "pr 9" and a two-sha commit, so no proof.
  landed_item MERGED 'o/game#12 o/tools#9'
  agent-queue set fix-crash "merged=$OID 1111111111111111111111111111111111111111" >/dev/null
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:12 commit:${OID:0:12}"
}

@test "reap: an item whose PR is in another of the project's repos proves its commit in that repo's checkout" {
  # NEGATIVE CONTROL: proved in the project's own checkout (game), the tools commit read
  # "evidence ... is not a commit in .../repos/game" and the row stayed started every pass (ar-965).
  landed_item MERGED 'o/tools#9'
  git init -q --bare "$SANDBOX/tools.git"
  git -c init.defaultBranch=main init -q "$SANDBOX/repos/tools"
  git -C "$SANDBOX/repos/tools" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "tools fix (#9)"
  git -C "$SANDBOX/repos/tools" remote add origin "$SANDBOX/tools.git"
  git -C "$SANDBOX/repos/tools" push -q origin HEAD:main
  TOID=$(git -C "$SANDBOX/repos/tools" rev-parse HEAD)
  jq --arg d "$SANDBOX/repos/tools" '.trackers.tools = {repo: "tools"} | .paths[$d] = "tools"' "$DISPATCH_PROJECT_MAP" > "$SANDBOX/map.next"
  mv "$SANDBOX/map.next" "$DISPATCH_PROJECT_MAP"
  agent-queue set fix-crash "merged=$TOID" >/dev/null
  run cmd_reap
  assert_output --partial 'closed game: fix crash'
  run grep -F 'ptask game --agent done fix crash' "$NOTES_FIXTURE/calls.log"
  assert_output "notes --profile bnb ptask game --agent done fix crash --proof pr:9 commit:${TOID:0:12}"
}

@test "reap: an item whose PR names a repo with no checkout leaves its row started" {
  landed_item MERGED 'o/tools#9'
  agent-queue set fix-crash "merged=$OID" >/dev/null
  run cmd_reap
  refute_output --partial 'closed game'
  grep -qF 'no merge proof: no checkout of the repo o/tools#9 names' "$FLEET_DISPATCH_DIR"/log.md || fail "no reason logged"
}

@test "reap: a done item's open PR keeps its row started past the orphan grace" {
  landed_item OPEN
  orphan_seen game 'fix crash' 73
  run cmd_reap
  assert_success
  refute_output --partial 'un-started'
  grep -qF -- '- [/] fix crash' "$NOTES_FIXTURE/rows.game.agent" || fail "row lost its start"
}

@test "reap: a done item's PR closed unmerged leaves the row to the orphan timer" {
  landed_item CLOSED
  orphan_seen game 'fix crash' 73
  run cmd_reap
  assert_output --partial 'un-started game: fix crash'
}

# bare_pr <body> -- landed_item with pr=12, and a gh that runs its real -q filter over a merged PR with
# that body, so the filter itself is under test.
bare_pr() {
  landed_item MERGED 12
  jq -n --arg o "$OID" --arg b "$1" '{state: "MERGED", mergeCommit: {oid: $o}, body: $b}' > "$NOTES_FIXTURE/pr.json"
  stub gh 'printf "gh %s in %s\n" "$*" "$PWD" >> "$NOTES_FIXTURE/calls.log"; jq -r "${@: -1}" "$NOTES_FIXTURE/pr.json"'
}

@test "reap: a bare pr: reads the project's checkout and counts a PR whose body has the item's stamp" {
  bare_pr $'Summary\r\nItem: fix-crash\r\nTask: gm-1'
  run cmd_reap
  assert_output --partial 'closed game: fix crash (queue item fix-crash, PR 12 merged)'
  assert_equal "$(agent-queue show fix-crash --json | jq -r .merged)" "$OID"
  grep -q "^gh pr view 12 .* in $SANDBOX/repos/game$" "$NOTES_FIXTURE/calls.log" || fail "not read from the project's checkout"
}

@test "reap: a bare pr: whose PR stamps another item, even one this slug prefixes, never closes the row" {
  bare_pr $'Summary\nItem: fix-crash-two'
  run cmd_reap
  assert_success
  refute_output --partial 'closed game'
  assert_equal "$(agent-queue show fix-crash --json | jq -r '.merged // "none"')" none
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
  local old new ago2h
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  ago2h=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  queued_item fresh urgent "$new"
  queued_item low-old low "$old"
  # A dated tag a day out: an at:HH:MM tag is past its time for part of every day.
  queued_item tagged-old high "$old" "at:$(date -d '+1 day' +%Y-%m-%dT%H:%M)"
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
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item other\n' "$ago2h" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_output --partial "last run start: $ago2h"
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
  acct main:pace
  run cmd_starved
  assert_failure
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:ok
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  acct main:pace
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  acct main:ok
  stub agent-hold 'exit 1'
  run cmd_starved
  assert_success
  assert_output --partial 'dispatch is held'
}

# hold_for <minutes ago> <why>: the hold agent-proof.sh keeps for fleet-dispatch.
hold_for() {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"; mkdir -p "$d"
  echo "$(( $(date +%s) - $1 * 60 ))" > "$d/held_since"; printf '%s' "$2" > "$d/held_why"
}

@test "starved: a hold standing the limit trips it, led by the Stopped line, and a run start does not clear it; a younger hold or none does not" {
  queued_item fresh low "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  acct main:pace
  hold_for 30 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  run cmd_starved
  assert_success
  assert_output ''
  hold_for 125 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_line --index 0 'Dispatch stopped 2h05m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
  # A hold by load alone is fleet-thermal's alarm, as before.
  acct main:ok
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load'
  # Negative control: no hold, and the same run start clears it.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:pace
  rm "$HOME/.local/state/agentctl/fleet-dispatch/held_since"
  run cmd_starved
  assert_success
}

@test "stopped: a finding names its items without their pools, a long reason is cut at a clause, --json carries the line" {
  hold_for 90 'queued 2 for the night; finding firing: dbs-7-boss (starved pool:other), house-sleep-dinner (starved pool:other), 5 more, every queue item waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: finding firing: dbs-7-boss, house-sleep-dinner, 5 more. Clears when its finding stops firing.'
  hold_for 3000 'no account has room; bnb is the closest, 98% of its week used, inside the last 15% kept for the human, and a great many more words that will not fit, runs out Fri 10:35 at this rate, queue item x waits'
  run cmd_stopped
  assert_failure
  [ "${#output}" -le 160 ] || fail "${#output} characters: $output"
  assert_output --partial 'Dispatch stopped 2d2h: no account has room; bnb is the closest, 98% of its week used'
  run cmd_stopped --json
  jq -e '.runner == "fleet-dispatch" and (.line | startswith("Dispatch stopped 2d2h")) and (.since | type == "number")' <<<"$output"
}

# 2026-11-06 (P3 live): with every account full and spill open, gate names no account, so each pass
# fleet-assess held too read "held by load" and queue-starved cleared five times under one hold.
@test "starved: an account hold under a load hold still starves while a spill may start" {
  queued_item stuck high "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  spill_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before spill_ready set it
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  hold_for 125 'no account has room; alt is the closest, 4 points over its weekly pace'
  run gate
  assert_output 'fleet-assess says HOLD'
  run cmd_starved
  assert_failure
  assert_line --index 0 --partial 'Dispatch stopped 2h05m: no account has room'
  # Negative control: an account with room, and the same load hold is fleet-thermal's alarm.
  acct alt:ok:/home/u/.claude-personal
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
}

@test "stats: held_s is how long the hold has stood, 0 with none" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_stats
  assert_equal "$(jq -c .held_s <<<"$output")" 0
  hold_for 90 'fleet-assess says HOLD, queue item one waits'
  run cmd_stats
  jq -e '.held_s >= 5400 and .held_s < 5500' <<<"$output"
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
  local judged; judged=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  touch -d "$judged" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_failure
  assert_output --partial "1 board rows unjudged, none judged since ${judged% *}"
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
  queued_item stuck urgent "$old"
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

@test "stats: runnable_urgent counts only urgent items a start would take; high ones, chained ones and a gateway agent's are not in it" {
  local old
  old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item urgent-ok urgent "$old"
  queued_item urgent-chained urgent "$old" '' never-done
  queued_item high-a high "$old"
  queued_item high-b high "$old"
  queued_item urgent-gateway urgent "$old"
  sed -i 's/^agent: claude$/agent: opencode/' "$AGENT_QUEUE_DIR"/queued/*-urgent-gateway.md
  export DISPATCH_STARVED_MIN=100000
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high]' <<<"$output")" '[1,2]'
  jq -e '.oldest_urgent_s >= 10790 and .oldest_urgent_s <= 10900 and .oldest_high_s >= 10790 and .oldest_high_s <= 10900' <<<"$output"
  # No urgent item a start would take: none counted and no age, not the high ones' age.
  rm "$AGENT_QUEUE_DIR"/queued/*-urgent-ok.md
  run cmd_stats
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high, .oldest_urgent_s]' <<<"$output")" '[0,2,null]'
  jq -e '.oldest_high_s >= 10790' <<<"$output"
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

@test "stats: open board rows by lane; an unreadable board leaves them out, never 0" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  notes() { echo '{"rows":[{"lane":"agent"},{"lane":"agent"},{"lane":"human"},{"lane":"playtest"},{"lane":"focus"}]}'; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{board_agent, board_human, board_playtest}' <<<"$output")" '{"board_agent":2,"board_human":1,"board_playtest":1}'
  notes() { return 1; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c 'has("board_agent")' <<<"$output")" false
}

@test "stats fails, saying so, when the queue is unreadable" {
  stub agent-queue 'exit 1'
  run cmd_stats
  assert_failure
  assert_output '{"error":"agent-queue unreadable"}'
}

@test "a started session's launch line labels its spans with the project and queue item" {
  # A pane gets the tmux server's environment, so only the launch line can say this; off the LAN
  # the snippet defines nothing, and every other start test here runs that way.
  project game beta "$SANDBOX/repos/game"
  transcript abc-123 '{"permissionMode":"plan"}'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.default"
  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/claude-telemetry.sh" "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"
  stub getent 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session dotfiles \
    --window crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'OTEL_RESOURCE_ATTRIBUTES='
  assert_called 'project=game'
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

# ar-70: on 2026-11-03 a hand resume of an unapproved plan item came back in bypass with no item.
@test "start --resume with no --item finds the item that lists the conversation, and a plan item with no mode on record stays in plan" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  CLAUDE_CODE_SESSION_ID=conv-plan agent-queue add --project game --running --mode plan --slug plan-work "plan work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session planned \
    --cwd "$SANDBOX/repos/game" --resume conv-plan
  assert_success
  assert_called "-c $SANDBOX/repos/game AGENT_QUEUE_ITEM=plan-work env -u CLAUDE_CONFIG_DIR claude --permission-mode plan --allow-dangerously-skip-permissions --resume conv-plan"
  assert_called 'set-option -t =planned: @dispatch game: plan-work'
  f=$(qitem running plan-work)
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin)" 'default:planned resume'

  # Once the transcript shows the plan approved, the resume goes on in the mode it ran in.
  transcript conv-plan '{"permissionMode":"plan"}
{"permissionMode":"bypassPermissions"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --server default --session planned2 \
    --cwd "$SANDBOX/repos/game" --resume conv-plan
  assert_success
  assert_called "AGENT_QUEUE_ITEM=plan-work env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-plan"
}

@test "start --resume refuses a conversation still running, and one two items list without --item" {
  project game beta "$SANDBOX/repos/game"
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  mkdir -p "$HOME/.claude/sessions"
  printf '{"pid":%s,"sessionId":"conv-live"}' "$$" > "$HOME/.claude/sessions/$$.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s1 \
    --cwd "$SANDBOX/repos/game" --resume conv-live
  assert_failure
  assert_output --partial 'conv-live is still running'

  CLAUDE_CODE_SESSION_ID=conv-two agent-queue add --project game --running --slug one "one" >/dev/null
  CLAUDE_CODE_SESSION_ID=conv-two agent-queue add --project game --running --slug two "two" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s2 \
    --cwd "$SANDBOX/repos/game" --resume conv-two
  assert_failure
  assert_output --partial 'more than one item'
  assert_output --partial 'pass --item'
  assert_not_called 'new-session'

  # Only an ambiguous lookup refuses: a queue that cannot answer (none installed) resumes with no item.
  stub agent-queue 'echo "agent-queue: command not found" >&2; exit 127'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --project game --server default --session s3 \
    --cwd "$SANDBOX/repos/game" --resume conv-two
  assert_success
  assert_called "-s s3 -c $SANDBOX/repos/game env -u CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --resume conv-two"
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

# --- gateway harnesses: `start --harness` ---------------------------------------------------

# A harness map, a key file and a gateway that says $1 of $150 is spent (default 1).
harness_ready() {
  game_ready
  printf 'sk-test\n' > "$SANDBOX/eval.key"
  printf 'sk-glm\n' > "$SANDBOX/glm.key"
  jq -n --arg k "$SANDBOX/eval.key" --arg c "$SANDBOX/eval.json" --arg gk "$SANDBOX/glm.key" --arg gc "$SANDBOX/eval-glm.json" '{
    gateway: {url: "https://gw.test", key_file: $k},
    harnesses: {
      "claude-lazer": {timeout_min: 180, models: {sonnet: "sonnet"}},
      opencode: {config: $c, timeout_min: 180, models: {sonnet: "litellm/claude-sonnet-5", qwen: "litellm/code (qwen-3-coder)"}},
      glm: {launcher: "opencode", config: $gc, key_file: $gk, timeout_min: 180, models: {glm: "litellm/reasoning (glm-5.3)"}},
      codex: {account: "chatgpt", room: "agent-codex room", timeout_min: 120, models: {sol: "gpt-6.1-sol"}},
      "claude-cloud": {launcher: "claude-cloud", room: "claude-acct room", timeout_min: 90, models: {cloud: "cloud"}}}}' > "$SANDBOX/harnesses.json"
  export DISPATCH_HARNESSES="$SANDBOX/harnesses.json"
  stub curl "cat > \"\$NOTES_FIXTURE/curl.stdin\"; echo \"curl \$*\" >> \"\$NOTES_FIXTURE/calls.log\"; echo '{\"info\":{\"spend\":${1:-1},\"max_budget\":150}}'"
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" != log ] || echo run-9'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  stub tmux 'exit 0'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
}

@test "--harness opencode launches a standalone run on the overlay, claims its session and logs under eval" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model qwen
  assert_success
  assert_called 'env -u LITELLM_MASTER_KEY timeout 180m opencode run --standalone --auto --session ses_eval'
  assert_called '--title fix-menu --model litellm/code\ \(qwen-3-coder\) --agent build'
  assert_called 'OPENCODE_CONFIG='
  assert_called '</dev/null'
  assert_not_called 'claude --model'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane eval --by human --harness opencode --picked qwen --ran qwen'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account) $(qfield "$f" lane_run)" 'opencode qwen gateway run-9'
  grep -q 'ses_eval' <<<"$(qfield "$f" sessions)" || fail "the run's session id is not on the item"
  grep -qF "$(qfield "$f" sessions | tr -d '[] ' | cut -d, -f1)" "$NOTES_FIXTURE/calls.log" || fail "claimed id is not the launched one"
}

@test "--harness glm runs opencode on its own overlay and reads the glm key's budget, not the eval key's" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness glm --model glm
  assert_success
  assert_called "OPENCODE_CONFIG='$SANDBOX/eval-glm.json'"
  assert_called '--model litellm/reasoning\ \(glm-5.3\)'
  grep -q 'Bearer sk-glm' "$NOTES_FIXTURE/curl.stdin" || fail "the budget was not read with the glm key"
  # one gateway call, so the stdin file the stub overwrites per call is the whole story
  assert_equal "$(grep -c '^curl' "$NOTES_FIXTURE/calls.log")" 1
  ! grep -q 'sk-test' "$NOTES_FIXTURE/curl.stdin" || fail "the eval key reached the glm lane"
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model)" 'glm glm'
}

@test "--harness glm refuses once its key is spent, and starts nothing" {
  harness_ready
  stub curl "echo '{\"info\":{\"spend\":50,\"max_budget\":50}}'"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness glm --model glm
  assert_failure
  assert_output --partial 'the glm key is spent'
  assert_not_called 'opencode run'
}

@test "the key goes to the gateway on stdin, never on the command line" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_success
  assert_called 'https://gw.test/key/info'
  assert_not_called 'sk-test'
  grep -q 'Bearer sk-test' "$NOTES_FIXTURE/curl.stdin" || fail "curl was not handed the key"
}

@test "an opencode brief reads the skill and carries its own closing rules, not the ones for a watched pane" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_success
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it'
  assert_called 'pr=<owner/repo#N>'
  assert_called 'Run agent-land in the foreground'
  assert_not_called '/one-shot Fix'
  assert_not_called 'agent-ask post'
}

@test "--harness claude-lazer runs the wrapper on the eval key with the queue tag, off the account" {
  harness_ready
  stub claude-acct 'echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness claude-lazer --model sonnet
  assert_success
  assert_called 'env -u CLAUDE_CONFIG_DIR -u LITELLM_MASTER_KEY CLAUDE_LAZER_KEY='
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called 'AGENT_HARNESS=claude-lazer ANTHROPIC_CUSTOM_HEADERS=x-litellm-tags:\ queue:fix-menu claude-lazer --model sonnet --session-id SID --permission-mode bypassPermissions'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane eval --by human --harness claude-lazer --picked sonnet --ran sonnet'
  assert_not_called 'claude-acct pick'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" account)" 'claude-lazer gateway'
}

@test "a queue start drops DISPATCH_DROP_TOOLS, unless the task names one, ultracode or /loop, or the knob is empty" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug plain "fix the menu"
  agent-queue add --project game --slug uc "ultracode the importer"
  agent-queue add --project game --slug lp "/loop 5m check the deploy"
  agent-queue add --project game --slug wf "run a Workflow over the PRs"
  for s in plain uc lp wf; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  DISPATCH_DROP_TOOLS='' && agent-queue add --project game --slug off "fix the footer" && cmd_start --item off >/dev/null || fail "start off"
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial 'AGENT_QUEUE_ITEM=plain env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "only plain drops tools: $(cat "$NOTES_FIXTURE/cmds.log")"
  assert_line --index 4 --partial 'AGENT_QUEUE_ITEM=off env -u CLAUDE_CONFIG_DIR claude --model opus --session-id SID --permission-mode'
  # A value that is not a list of tool names never reaches the command line.
  DISPATCH_DROP_TOOLS='Bash(rm:*);x' && agent-queue add --project game --slug bad "fix the header" >/dev/null
  run cmd_start --item bad
  assert_output --partial 'DISPATCH_DROP_TOOLS is not a comma list of tool names'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "a bad knob reached the command line"
}

# --- lane sandbox: DISPATCH_SANDBOX_PROFILE (the pattern is tests/integ/agent_run_sandbox.bats) ---

# A repo with a worktree-able git dir, and a profile that tries to switch every hard gate off.
sandbox_ready() {
  project game beta "$SANDBOX/repos/game"
  git init -q "$SANDBOX/repos/game"
  export AGENTCTL_SANDBOX_DIR="$SANDBOX/sbx"
  SANDBOX_DIR=$AGENTCTL_SANDBOX_DIR   # lib/sandbox.sh read it when this file was sourced
  mkdir -p "$AGENTCTL_SANDBOX_DIR"
  cat > "$AGENTCTL_SANDBOX_DIR/lane.json" <<'JSON'
{"sandbox": {"enabled": false, "failIfUnavailable": false, "allowUnsandboxedCommands": true,
  "network": {"allowedDomains": ["github.com"], "strictAllowlist": false},
  "filesystem": {"denyRead": ["~/.ssh", "/etc/fake-cred"], "allowWrite": ["~/.agent"]}},
 "permissions": {"deny": ["Bash(rm -rf /)"]}}
JSON
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
}
# launch_settings -> the JSON the last launch line passed to --settings
launch_settings() { eval "printf %s $(grep -m1 -e '--settings' "$NOTES_FIXTURE/cmds.log" | sed -E 's/.* --settings (.*) --permission-mode.*/\1/')"; }

@test "with no DISPATCH_SANDBOX_PROFILE a start has no --settings and keeps the ambient GitHub token (control)" {
  sandbox_ready
  agent-queue add --project game --slug open "fix the menu"
  cmd_start --item open >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial '--settings'
  refute_output --partial 'GH_TOKEN'
}

@test "a sandboxed start passes the profile with every hard gate forced on, the git common dir writable, and no GitHub token" {
  sandbox_ready
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug closed "fix the menu"
  cmd_start --item closed >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial 'AGENT_QUEUE_ITEM=closed '
  assert_output --partial 'env -u GH_TOKEN -u GITHUB_TOKEN claude --model opus'
  common="$(cd "$SANDBOX/repos/game/.git" && pwd -P)"
  run jq -c '[.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowUnsandboxedCommands, .sandbox.network.strictAllowlist, .sandbox.filesystem.allowWrite]' <<<"$(launch_settings)"
  assert_output "[true,true,false,true,[\"~/.agent\",\"$common\"]]"
  run jq -r '.permissions.deny[]' <<<"$(launch_settings)"
  assert_line 'Bash(rm -rf /)'
  assert_line 'Read(~/.ssh/**)'
  assert_line 'Edit(//etc/fake-cred)'
  [ -n "$(qitem running closed)" ] || fail "the item did not start"
}

@test "DISPATCH_SANDBOX_GH_TOKEN_FILE gives the pane the token by file: its value is never on the launch line" {
  sandbox_ready
  printf 'scoped-token\n' > "$SANDBOX/lane.token"
  DISPATCH_SANDBOX_PROFILE=lane DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/lane.token"
  agent-queue add --project game --slug tok "fix the menu"
  cmd_start --item tok >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial "GH_TOKEN=\"\$(tr -d '[:space:]' < ${SANDBOX// /\\ }/lane.token)\" env -u GITHUB_TOKEN claude --model opus"
  refute_output --partial 'scoped-token'
  # The pane's shell can read it that way.
  run sh -c "$(grep -om1 'GH_TOKEN=.* env -u GITHUB_TOKEN' "$NOTES_FIXTURE/cmds.log") printenv GH_TOKEN"
  assert_output scoped-token
  # An unreadable token file refuses the start.
  DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/missing"
  agent-queue add --project game --slug tok2 "fix the footer"
  run cmd_start --item tok2
  assert_failure
  assert_output --partial 'is not a readable, non-empty file'
}

@test "a missing or malformed profile refuses the start: wt never runs and the item stays queued (negative control)" {
  sandbox_ready
  agent-queue add --project game --slug nope "fix the menu"
  DISPATCH_SANDBOX_PROFILE=absent
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'Refusing to run unsandboxed'
  assert_output --partial 'nothing started'
  printf '{"sandbox": {"filesystem": {"allowWrite": "~/.agent"}}}\n' > "$AGENTCTL_SANDBOX_DIR/bad.json"
  DISPATCH_SANDBOX_PROFILE=bad
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'not a valid profile'
  [ ! -e "$NOTES_FIXTURE/cmds.log" ] || fail "a session started without the sandbox it asked for"
  [ -n "$(qitem queued nope)" ] || fail "the item left the queue"
}

@test "a start on a harness that cannot enforce the profile is refused, not run open" {
  harness_ready
  sandbox_ready
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug cx "fix the menu"
  run cmd_start --item cx --harness codex --model sol
  assert_failure 2
  assert_output --partial "cannot enforce lane sandbox 'lane'"
  assert_not_called 'wt new'
}

@test "with a sandbox profile set the spill is shut, so a pass waits BLOCKED instead of failing every Lazer start" {
  DISPATCH_SPILL_MAX_LIVE=2
  DISPATCH_SANDBOX_PROFILE=
  run spill_shut
  refute_output --partial 'DISPATCH_SANDBOX_PROFILE'
  DISPATCH_SANDBOX_PROFILE=lane
  run spill_shut
  assert_output --partial 'DISPATCH_SANDBOX_PROFILE is set'
}

@test "a claude --resume reopens under the same profile" {
  sandbox_ready
  : > "$NOTES_FIXTURE/tmux.sessions.default"
  export DISPATCH_SANDBOX_PROFILE=lane
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --profile bnb --project game \
    --server default --session fix-crash --cwd "$SANDBOX/repos/game" --resume abc-123
  assert_success
  assert_called 'env -u GH_TOKEN -u GITHUB_TOKEN claude --settings '
  assert_called '--permission-mode bypassPermissions --resume abc-123'
}

@test "an item queued with --agent and a model starts on them with no flags" {
  harness_ready
  agent-queue add --project game --slug by-field --agent opencode --priority high "Fix it" >/dev/null
  agent-queue set by-field model=sonnet >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item by-field
  assert_success
  assert_called 'opencode run --standalone'
}

@test "a claude start is unchanged: no eval log, no gateway read; it claims the id it launches with" {
  harness_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  sid=$(grep -o -- '--session-id [0-9a-f-]*' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d' ' -f2)
  [ -n "$sid" ] || fail "no session id in the launch"
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called "claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode bypassPermissions \$'/one-shot Fix"
  assert_not_called 'curl'
  assert_not_called 'lane eval'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" account) $(qfield "$f" sessions)" "claude main $sid"
}

@test "gateway starts refuse what would mislabel or overspend, and the item stays queued" {
  harness_ready
  refuses() { local want="$1"; shift; run "$REPO_ROOT/.local/bin/fleet-dispatch" start "$@"; assert_failure; assert_output --partial "$want"; }
  refuses 'unknown harness: nope' --item fix-menu --harness nope --model sonnet
  refuses 'has no model opus' --item fix-menu --harness claude-lazer --model opus
  refuses 'needs --model' --item fix-menu --harness opencode
  refuses '--harness needs --item' --project game --harness opencode --model sonnet
  refuses 'a resume stays on what it ran' --resume abc --harness opencode --model sonnet
  agent-queue add --project game --slug planned --mode plan --priority high "Think" >/dev/null
  refuses 'cannot wait on a plan' --item planned --harness opencode --model sonnet
  rm "$DISPATCH_HARNESSES"
  refuses 'no harness map' --item fix-menu --harness opencode --model sonnet
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "a refused item left the queue"
}

@test "a spent key and a gateway that cannot answer both refuse the start" {
  harness_ready 150
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_failure
  assert_output --partial 'the opencode key is spent'
  stub curl 'exit 22'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness opencode --model sonnet
  assert_failure
  assert_output --partial "cannot read the opencode key's budget"
  assert_not_called 'wt new'
}

# A plan-billed harness: agent-codex room says whether the ChatGPT plan has use left (default yes).
codex_room() { stub agent-codex "echo \"agent-codex \$*\" >> \"\$NOTES_FIXTURE/calls.log\"; echo '${2:-codex (plus): room}'; exit ${1:-0}"; }

@test "--harness codex runs agent-codex on the plan login, gated by room and not the gateway, with a headless brief" {
  harness_ready
  codex_room
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_success
  assert_called 'agent-codex room'
  assert_not_called 'curl'
  assert_called 'AGENT_QUEUE_ITEM=fix-menu env -u LITELLM_MASTER_KEY -u OPENAI_API_KEY -u CODEX_API_KEY timeout 120m agent-codex run -m gpt-6.1-sol --dangerously-bypass-approvals-and-sandbox'
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it'
  assert_called 'Run agent-land in the foreground'
  assert_not_called '/one-shot Fix'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'codex sol chatgpt'
}

# --- claude-cloud: a #cloud-ok item runs as a Claude cloud session ---------------------------

cloud_ready() {
  harness_ready
  git -C "$SANDBOX/repos/game" init -q
  git -C "$SANDBOX/repos/game" remote add origin git@github.com:acme/game.git
  agent-queue add --project game --slug cloud-fix --priority high --tags cloud-ok "Fix the menu text" >/dev/null
}

@test "a cloud-ok item starts as a cloud session with no --harness: claude-cloud-run on the claude account, a self-contained brief, no model-lane" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_success
  assert_called 'AGENT_QUEUE_ITEM=cloud-fix env -u CLAUDE_CONFIG_DIR CLOUD_TIMEOUT_MIN=90 claude-cloud-run cloud-fix acme/game'
  assert_called 'The PR body carries the line "Item: cloud-fix"'
  assert_not_called '/one-shot'
  assert_not_called 'model-lane'
  assert_not_called 'curl'
  f=$(qitem running cloud-fix)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" model) $(qfield "$f" account)" 'claude-cloud cloud main'
}

@test "a cloud-ok item with no room on the plan stays queued, as a local one would" {
  cloud_ready
  stub claude-acct '[ "$1" = room ] && { echo "no account has room"; exit 1; }; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_failure
  assert_output --partial 'claude-cloud has no room'
  [ -n "$(qitem queued cloud-fix)" ] || fail "the item left the queue"
}

@test "an item without cloud-ok never routes to a cloud session" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu
  assert_success
  assert_not_called 'claude-cloud-run'
  assert_called 'claude --model'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" claude
}

@test "a cloud session refuses a plan item, a tier 3 item and a repo off GitHub, and the item stays queued" {
  cloud_ready
  agent-queue add --project game --slug cloud-plan --mode plan --tags cloud-ok "Think" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-plan --harness claude-cloud
  assert_failure
  assert_output --partial 'cannot wait on a plan'
  agent-queue add --project game --slug cloud-t3 --tags 'cloud-ok tier3' "Fix the gate" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-t3
  assert_failure
  assert_output --partial 'is tier 3'
  git -C "$SANDBOX/repos/game" remote set-url origin git@forge.example:acme/game.git
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix
  assert_failure
  assert_output --partial 'no GitHub repo for a cloud session'
  for k in cloud-plan cloud-t3 cloud-fix; do [ -n "$(qitem queued "$k")" ] || fail "$k left the queue"; done
  assert_not_called 'claude-cloud-run'
}

@test "item_brief for claude-cloud names the Item and Task lines and leaves out local tooling" {
  run item_brief '{"slug": "cloud-fix", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}' claude-cloud
  assert_success
  assert_output --partial 'fix(game): x'
  assert_output --partial 'The PR body carries the line "Item: cloud-fix"'
  assert_output --partial 'Never merge it'
  refute_output --partial '/one-shot'
  refute_output --partial 'agent-land <N>'
}

# claude-cloud-run: claude, gh and script are stubs; the real agent-queue records the PR.
cloud_run_ready() {
  agent-queue add --project game --slug cloud-fix --priority high --tags cloud-ok "Fix the menu text" >/dev/null
  agent-queue move cloud-fix running >/dev/null
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"; echo "Session: https://claude.ai/code/session_01AbC"'
  stub gh 'echo "gh $*" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/prs.json"'
  export CLOUD_POLL_SEC=0 CLAUDE_BIN=claude
}

@test "claude-cloud-run records the session URL, finds the PR by its exact Item line, and parks the item waiting on it" {
  cloud_run_ready
  printf '%s\n' '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}, {"number": 8, "createdAt": "2099-01-01T00:00:00Z", "body": "Item: cloud-fix-extra"}, {"number": 9, "createdAt": "2099-01-01T00:00:00Z", "body": "text\r\nItem: cloud-fix\r\nmore"}]' > "$NOTES_FIXTURE/prs.json"
  run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_success
  assert_called 'claude --cloud do the task'
  assert_called 'gh pr list --repo acme/game --state all --search "Item: cloud-fix" in:body'
  f=$(qitem waiting cloud-fix)
  [ -n "$f" ] || fail "the item is not waiting"
  assert_equal "$(qfield "$f" pr)" 'acme/game#9'
  grep -q 'https://claude.ai/code/session_01AbC' "$f" || fail "the session URL is not on the item"
}

@test "claude-cloud-run exits 1 at once when the create fails, and polls nothing" {
  cloud_run_ready
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"; exit 3'
  CLOUD_TIMEOUT_MIN=60 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_not_called 'gh pr list'
  grep -q 'create failed (exit 3)' "$(qitem running cloud-fix)" || fail "the item is not flagged"
}

@test "claude-cloud-run names a gh failure instead of reading it as no PR yet, and never takes an older PR" {
  cloud_run_ready
  stub gh 'echo "gh auth: not logged in" >&2; exit 1'
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_output --partial 'gh pr list failed: gh auth: not logged in'
  stub gh 'cat "$NOTES_FIXTURE/prs.json"'
  echo '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  [ -n "$(qitem running cloud-fix)" ] || fail "an older PR moved the item"
}

@test "a cloud-ok item that names a model, or a start with --model, stays on a local claude" {
  cloud_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item cloud-fix --model opus
  assert_success
  assert_not_called 'claude-cloud-run'
  assert_called 'claude --model opus'
}

@test "claude-cloud-run past its timeout with no PR exits 1 and flags the item, which stays running" {
  cloud_run_ready
  echo '[{"number": 8, "body": "Item: other"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  f=$(qitem running cloud-fix)
  [ -n "$f" ] || fail "the item left running"
  grep -q 'opened no PR in 0 min' "$f" || fail "the item is not flagged"
}

@test "codex refuses a spent plan and a plan item, and the item stays queued" {
  harness_ready
  codex_room 1 'codex (plus): week spent'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-menu --harness codex --model sol
  assert_failure
  assert_output --partial 'codex has no room: codex (plus): week spent'
  codex_room
  agent-queue add --project game --slug planned --mode plan --priority high "Think" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item planned --harness codex --model sol
  assert_failure
  assert_output --partial 'codex runs to its end and cannot wait on a plan'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "a refused item left the queue"
}

@test "resume refuses an item that ran on a gateway harness" {
  harness_ready
  started_item gw-run lab:game-agent-1
  sed -i 's/^agent: claude/agent: opencode/' "$(qitem running gw-run)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item gw-run --resume abc
  assert_failure
  assert_output --partial '--resume is for claude'
}

@test "a pass never starts an eval item (agent: opencode): it goes on to the claude item behind it" {
  harness_ready
  agent-queue add --project game --slug gw-first --agent opencode --priority urgent "Eval" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem queued gw-first)" ] || fail "a pass started a gateway item"
  [ -n "$(qitem running fix-menu)" ] || fail "the claude item behind it did not start"
}

@test "reap settles a claude-lazer item whose claude exited, like claude's; an opencode one waits for its session to end" {
  project game beta "$SANDBOX/repos/game"
  started_item lazer lab:game-agent-1
  sed -i 's/^agent: claude/agent: claude-lazer/' "$AGENT_QUEUE_DIR"/running/*-lazer.md
  started_item oc lab:game-agent-2
  sed -i 's/^agent: claude/agent: opencode/' "$AGENT_QUEUE_DIR"/running/*-oc.md
  printf 'game-agent-%s\n' 1 2 > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0   # a miss settles on the second reap
  "$REPO_ROOT/.local/bin/fleet-dispatch" reap >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-lazer.md 2>/dev/null)" ] || fail "a claude-lazer item whose claude exited stayed active"
  [ -n "$(qitem running oc)" ] || fail "an opencode run was settled while its session lives"
}

# --- spill to Lazer: a run pass past every account's cap ------------------------------------

# Every account past its pace, spilling on (cap 2, line 80%), lazer-reserve on its own key, the
# Lazer pool $1 of $250 spent (default 100, 40%), the key $2 of $100 (default 1), and model-lane
# putting every task on Sonnet.
spill_ready() {
  harness_ready
  printf 'sk-reserve\n' > "$SANDBOX/reserve.key"
  jq --arg k "$SANDBOX/reserve.key" '.harnesses["lazer-reserve"] = {launcher: "claude-lazer", key_file: $k, timeout_min: 180, models: {sonnet: "sonnet"}}' \
    "$DISPATCH_HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$DISPATCH_HARNESSES"
  acct "alt:pace:/home/u/.claude-personal:4 points over its weekly pace"
  stub lazer-spend "echo '{\"spend\":${1:-100},\"max_budget\":250}'"
  stub curl "cat > \"\$NOTES_FIXTURE/curl.stdin\"; echo \"curl \$*\" >> \"\$NOTES_FIXTURE/calls.log\"; echo '{\"info\":{\"spend\":${2:-1},\"max_budget\":100}}'"
  sonnet_lane
  export DISPATCH_SPILL_MAX_LIVE=2 DISPATCH_SPILL_POOL_PCT=80
}
sonnet_lane() { stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; case "$1" in log) echo run-9 ;; classify) echo "{\"lane\":\"${LANE:-sonnet}\",\"by\":\"rule\",\"model\":\"${LANE:-sonnet}\",\"dispatch_model\":\"${LANE:-sonnet}\"}" ;; esac'; }

@test "past every account's cap a pass spills a Sonnet-lane item to Lazer on the claude-reserve key" {
  spill_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on Lazer (lazer-reserve, sonnet), spilled: no account has room; alt is the closest'
  assert_equal "$(outcome)" WORKED
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called 'claude-lazer --model sonnet --session-id SID --permission-mode bypassPermissions'
  assert_called 'reserve.key AGENT_HARNESS=lazer-reserve '
  assert_not_called 'eval.key'
  grep -q 'Bearer sk-reserve' "$NOTES_FIXTURE/curl.stdin" || fail "the budget check read another key"
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet --harness lazer-reserve'
  # the verdict that let it spill is the one logged: model-lane is asked once, not again by cmd_start
  [ "$(grep -c '^model-lane classify' "$NOTES_FIXTURE/calls.log")" -eq 1 ]
  assert_not_called '--lane eval'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" account) $(qfield "$f" origin) $(qfield "$f" model)" 'lazer-reserve gateway run sonnet'
}

@test "a spill start leaves the account hold standing: the Stopped line keeps its duration" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  spill_ready
  mkdir -p "$d"; echo "$(( $(date +%s) - 3 * 3600 - 30 ))" > "$d/held_since"; printf 'no account has room; alt is the closest, 4 points over its weekly pace' > "$d/held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-menu on Lazer'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 3h00m: no account has room'
}

@test "spill refuses an Opus-lane item and says so, and a later pass does not ask model-lane again that day" {
  spill_ready
  export LANE=opus
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'no account has room; alt is the closest, 4 points over its weekly pace, and no queue item may spill to Lazer: fix-menu (model-lane puts it on opus)'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'
  rm -f "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fix-menu (model-lane puts it on opus)'
  assert_not_called 'model-lane classify'
  [ -n "$(qitem queued fix-menu)" ] || fail "an Opus item left the queue"
}

@test "spill skips an item past the tier ceiling and goes on to the Sonnet item behind it" {
  spill_ready
  agent-queue add --project game --slug ci-first --priority urgent "ci: the runner retries a dead batch" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item ci-first may not spill to Lazer: tier 3 is past the unattended ceiling'
  [ -n "$(qitem queued ci-first)" ] || fail "a tier 3 item spilled"
  [ -n "$(qitem running fix-menu)" ] || fail "the Sonnet item behind it did not spill"
}

@test "spill: an untiered item on a harness project is tier 3 and waits; a red one there still spills" {
  spill_ready
  export DISPATCH_CLEANUP_PROJECTS=game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item fix-menu may not spill to Lazer: tier 3 is past the unattended ceiling'
  [ -n "$(qitem queued fix-menu)" ] || fail "an untiered harness item spilled"
  agent-queue add --project game --slug red-sweep --priority urgent --tags 'red cause:ab12' "fix the dead sweep" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item red-sweep on Lazer'
  [ -n "$(qitem running red-sweep)" ] || fail "a red on a harness project did not spill"
}

@test "spill holds when the pool is at its line, the key is spent, or the gateway cannot answer" {
  spill_ready 200
  refuses 'no account has room; alt is the closest, 4 points over its weekly pace (spill to Lazer shut: the Lazer pool is at 80%, the line is DISPATCH_SPILL_POOL_PCT=80%)'
  assert_equal "$(outcome)" BLOCKED
  stub lazer-spend "echo '{\"spend\":100,\"max_budget\":250}'"
  stub curl "cat > /dev/null; echo '{\"info\":{\"spend\":100,\"max_budget\":100}}'"
  refuses 'spill to Lazer shut: the lazer-reserve key is spent ($0 left)'
  stub lazer-spend 'exit 1'
  refuses "spill to Lazer shut: the Lazer pool's spend is unreadable"
  # a map with no lazer-reserve key_file never falls back to the gateway's (eval) key
  jq 'del(.harnesses["lazer-reserve"].key_file)' "$DISPATCH_HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$DISPATCH_HARNESSES"
  : > "$NOTES_FIXTURE/calls.log"
  refuses "spill to Lazer unset: $DISPATCH_HARNESSES has no lazer-reserve with its own key_file"
  run cat "$NOTES_FIXTURE/calls.log"
  refute_output --partial 'curl'
}

@test "spill never lifts another gate: load holds it" {
  spill_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  refuses 'over the'
  assert_not_called 'claude-lazer'
}

@test "spill stops at DISPATCH_SPILL_MAX_LIVE, counting this pass's own, and 0 turns it off" {
  spill_ready
  agent-queue add --project game --slug fix-next --priority high "Fix the next menu" >/dev/null
  export DISPATCH_PER_PASS=3 DISPATCH_SPILL_MAX_LIVE=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on Lazer'
  assert_output --partial 'full: 1 of DISPATCH_SPILL_MAX_LIVE=1 spill sessions live), the pass stops after 1 started'
  [ -n "$(qitem queued fix-next)" ] || fail "a spill went past the cap"
  # a live spill from an earlier pass counts the same
  rm -f "$NOTES_FIXTURE/calls.log"
  refuses 'full: 1 of DISPATCH_SPILL_MAX_LIVE=1 spill sessions live'
  # off: the account stop reads as it did before spilling
  export DISPATCH_SPILL_MAX_LIVE=0
  refuses 'no account has room; alt is the closest, 4 points over its weekly pace, queue item fix-next waits'
  refute_output --partial 'spill'
}

@test "reap settles a lazer-reserve item whose claude exited: its launcher is claude-lazer" {
  spill_ready
  started_item spilled lab:game-agent-1
  sed -i 's/^agent: claude/agent: lazer-reserve/' "$AGENT_QUEUE_DIR"/running/*-spilled.md
  stub agent-panel 'echo "{\"target\":\"lab/game-agent-9:1\",\"status\":\"busy\",\"session_id\":\"s9\"}"'
  stub agent-ask 'exit 0'
  export DISPATCH_REAP_CONFIRM=0   # a miss settles on the second reap
  "$REPO_ROOT/.local/bin/fleet-dispatch" reap >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  assert_success
  [ -n "$(ls "$AGENT_QUEUE_DIR"/done/*/*-spilled.md 2>/dev/null)" ] || fail "a spilled item whose claude exited stayed active"
}
