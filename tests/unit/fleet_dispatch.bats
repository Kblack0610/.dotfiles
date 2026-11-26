#!/usr/bin/env bats
# fleet-dispatch, which rows and queue items are candidates, how the judge rules on them, and how picks rank.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.
# One of two files, split so CI shards can spread them (the other is fleet_dispatch_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in fleet_dispatch/main.bash.

load 'fleet_dispatch/main'

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

@test "candidates: a row costs no hasher of its own: line and details sigs come in one batch, and held reads a map (ar-4512)" {
  local u=$'\xc3\xbcn\xc3\xafcode'   # multibyte text, which the batch must hash byte for byte
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): one $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] chore(game): two #low $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): three $u \$HOME [x] $T <!-- id:gm-3 -->"
  board_row game agent gm-1 '[]' '["the jump clips on ledges", "repro: level 2"]'
  board_row game agent gm-3 '[]' "[\"$u: a \\\"quoted\\\" word\"]"
  verdict game agent gm-2 skip
  # The batch hash is the one sig gives, string by string.
  for s in 'fix(game): one' "$u \$HOME [x] * @" '["a", "b\\nc"]'; do
    SIG_OF=(); sigs_load "$s"; sig_set "$s"
    assert_equal "$SIG" "$(printf '%s' "$s" | sig)"
  done
  # The baseline, every sig made by a fork: then each row's sig must match it.
  SIG_OF=()
  local want; want=$(cmd_candidates | jq -c '[.key, .line, .dsig]')
  stub sha256sum "echo x >> $(printf %q "$SANDBOX/sha.calls"); exec $(command -v sha256sum) \"\$@\""
  SIG_OF=()
  run cmd_candidates
  assert_success
  assert_equal "$(jq -c '[.key, .line, .dsig]' <<<"$output")" "$want"
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-3'
  # One hash, the policy's (judged_keys), however many rows.
  assert_equal "$(wc -l < "$SANDBOX/sha.calls")" 1
  # held: a verdict's exact line and dsig, its line with any details, or a failure's "*" for both.
  held_load "$(printf '%s\n' $'p\tagent\tk1\tL\tD' $'p\tagent\tk2\tL\t*' $'p\tagent\tk3\t*\t*')"
  held p agent k1 L D
  ! held p agent k1 L E
  ! held p agent k1 M D
  held p agent k2 L E
  ! held p agent k2 M E
  held p agent k3 M E
  ! held p human k3 M E
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

@test "candidates: the requested worker takes only #requested rows, in any project, never tier 3" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  echo '{"requested": {"max_tier": 9, "only_tag": "requested"}}' > "$DISPATCH_WORKERS"
  row game agent 'real ask' '- [ ] real ask #requested #worker/requested #tier/2'
  row game agent 'tagged no ask' '- [ ] tagged no ask #worker/requested #tier/2'
  row game agent 'lookalike' '- [ ] lookalike #requests #worker/requested #tier/2'
  row game agent 'tier three' '- [ ] tier three #requested #worker/requested #tier/3'
  row game agent 'other worker' '- [ ] other worker #requested #worker/fleet #tier/1'
  row app agent 'other project' '- [ ] other project #requested #worker/requested #tier/2'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'real ask,other project'
}

@test "candidates: stage decides which projects dispatch: a prod project's row is judged, an off project's is refused with the off-list reason, a draft's is not read" {
  board_workers
  mkdir -p "$SANDBOX/repos/web" "$SANDBOX/repos/fin" "$SANDBOX/repos/sketch"
  project webapp prod "$SANDBOX/repos/web"
  project finance beta "$SANDBOX/repos/fin"
  project sketch draft "$SANDBOX/repos/sketch"
  export DISPATCH_OFF_PROJECTS=finance
  row webapp agent 'web fix' '- [ ] fix(api): the login redirect loops'
  row finance agent 'fin fix' '- [ ] fix(ledger): the totals are off'
  row finance agent 'fin ci' '- [ ] ci(ledger): cache the test deps #tier/3'
  row sketch agent 'sketch row' '- [ ] fix(ui): the button is off'
  off='no worker covers finance: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human'

  OFF_SAY=1 run --separate-stderr cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.worker)"' <<<"$output" | paste -sd,)" 'web fix=board'
  assert_equal "$stderr" "fleet-dispatch: $off"
  # Judged: the next judge call gets the prod row, never a finance row, from the day or the tier-3 path.
  run --separate-stderr unjudged_rows
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'web fix'
  # Only the command and a pass's judge read say it (OFF_SAY), so the many reads of one pass log it once.
  assert_equal "$stderr" ''
  # suggest lists each finance row with the off-list reason, never auto.
  run --separate-stderr cmd_suggest --json
  assert_equal "$(jq -r 'select(.project == "finance") | "\(.key)=\(.auto)/\(.blocked | join("; "))"' <<<"$output" | paste -sd,)" \
    "fin fix=false/$off,fin ci=false/$off"
  run cmd_covered
  assert_output 'webapp'
  # Negative control: with no off list, finance dispatches like any project at its stage.
  OFF_SAY=1 DISPATCH_OFF_PROJECTS='' run --separate-stderr cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'fin fix,web fix'
  assert_equal "$stderr" ''
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

@test "candidates: a verdict whose rule the policy dropped, or for the row's older text, is judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'stale policy' "- [ ] stale policy $T"
  row game agent 'retagged' "- [ ] retagged $T"
  row game agent 'current' "- [ ] current $T"
  row game agent 'died' "- [ ] died $T"
  row game agent 'died twice' "- [ ] died twice $T"
  verdict game agent 'stale policy' dispatch
  verdict game agent 'current' skip
  echo 'policy v2' > "$DISPATCH_POLICY"
  verdict game agent 'current' skip
  jq -cn --arg sig "$(policy_sig)" '{project: "game", lane: "agent", key: "retagged", verdict: "skip", rule: "fits", policy: $sig, line: "old"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  # One failure expires the row's verdict, so it is judged again; DISPATCH_FIX_TRIES (2) hold it.
  verdict game agent 'died' dispatch
  verdict game agent 'died twice' dispatch
  jq -cn '{project: "game", lane: "agent", key: "died", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn '{project: "game", lane: "agent", key: "died twice", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn '{project: "game", lane: "agent", key: "died twice", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'stale policy,retagged,died'
}

@test "candidates: an edit that adds #of/, a priority tag or a comment field keeps the verdict; a scope or title edit re-judges" {
  project game beta "$SANDBOX/repos/game"
  local k
  for k in linked prio scoped titled; do row game agent "$k" "- [ ] chore(plan): $k it $T <!-- id:$k -->"; verdict game agent "$k" skip; done
  : > "$NOTES_FIXTURE/rows.game.agent"
  row game agent linked "- [ ] chore(plan): linked it $T #of/ga-1 <!-- id:linked -->"
  row game agent prio "- [ ] chore(plan): prio it   $T #high <!-- id:prio run:3 -->"
  row game agent scoped "- [ ] chore(gameplay): scoped it $T <!-- id:scoped -->"
  row game agent titled "- [ ] chore(plan): titled it now $T <!-- id:titled -->"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'scoped,titled'
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

@test "candidates: a row with the retired backlog token is a candidate like any board row, so work never stops" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] nice to have #low $T <!-- id:ga-1 tier:backlog -->"
  row game agent ga-2 "- [ ] on the board $T <!-- id:ga-2 -->"
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'ga-1,ga-2'
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | length' <<<"$output")" 0
}

@test "row gates: a #rbw/ row waits on the board while rbw lacks it, the human's Start too; once listed it is promoted unjudged, the gate on its item and off its row" {
  project game beta "$SANDBOX/repos/game"
  gate_rbw
  row game agent ga-1 "- [ ] fix(game): wire the keys $T #rbw/infra/x <!-- id:ga-1 -->"
  run cmd_candidates
  assert_success
  assert_output ''
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | join("; ")' <<<"$output")" 'waits on rbw infra/x (not in rbw yet)'
  run cmd_promote --project game --agent --raw "- [ ] fix(game): wire the keys $T #rbw/infra/x <!-- id:ga-1 -->"
  assert_failure
  assert_output --partial 'skip game: ga-1 waits on rbw infra/x (not in rbw yet)'
  run grep -c 'ptask game --agent --exact start' "$NOTES_FIXTURE/calls.log"
  assert_output 0

  printf 'infra\tx\n' > "$NOTES_FIXTURE/rbw.list"
  rm -f "$NOTES_FIXTURE/rbw.calls"
  GATES_LOADED=''; load_gates   # as cmd_run does, once a pass
  DRY=0 JUDGE_RC='' fill_day 2
  # Committed work: no judge call and no verdict, yet it is queued.
  run grep -c 'judge called' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  [[ " $(item_tags ga-1) " == *" rbw:infra/x "* ]]
  run grep -c 'ptask game --agent tag --remove rbw/infra/x ga-1' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  assert_equal "$(cut -f2 "$NOTES_FIXTURE/rows.game.agent")" "- [/] fix(game): wire the keys $T <!-- id:ga-1 -->"
  # One rbw list for the whole pass, however many reads of the board it made.
  run grep -c '^rbw list' "$NOTES_FIXTURE/rbw.calls"
  assert_output 1
}

@test "row gates: a gate's value keeps its case: #rbw/infra/Key waits on Key, not key, and its item holds rbw:infra/Key" {
  # notes lower-cases .tags; read from there, every #ask/<id> gate named no ask (2026-11-18).
  project game beta "$SANDBOX/repos/game"
  gate_rbw
  printf 'infra\tkey\n' > "$NOTES_FIXTURE/rbw.list"
  row game agent ga-1 "- [ ] fix(game): wire the keys $T #rbw/infra/Key <!-- id:ga-1 -->"
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | join("; ")' <<<"$output")" 'waits on rbw infra/Key (not in rbw yet)'
  printf 'infra\tKey\n' > "$NOTES_FIXTURE/rbw.list"
  GATES_LOADED=''; load_gates
  DRY=0 JUDGE_RC='' fill_day 2
  [[ " $(item_tags ga-1) " == *" rbw:infra/Key "* ]]
  run grep -c 'ptask game --agent tag --remove rbw/infra/Key ga-1' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "row gates: a #hold/ row whose id or epic the hold grants is a candidate and promotes; an ungranted one waits (ar-5237)" {
  project game beta "$SANDBOX/repos/game"
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  # The real agent-hold over setup's always-clear stub: the copied agent-queue calls the one beside it.
  cp "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  agent-hold set critical --kind resource --by coordinator "lockdown" >/dev/null
  agent-hold grant critical ga-1 ga-50 >/dev/null
  row game agent ga-1 "- [ ] fix(game): granted by its id $T #hold/critical <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] fix(game): granted by its epic $T #hold/critical #of/ga-50 <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] fix(game): granted nothing $T #hold/critical <!-- id:ga-3 -->"
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd' ')" 'ga-1 ga-2'
  run cmd_suggest --json
  [ -n "$(jq -r 'select(.key == "ga-3") | .blocked | join("; ")' <<<"$output")" ]
  run cmd_promote --project game --agent --raw "- [ ] fix(game): granted nothing $T #hold/critical <!-- id:ga-3 -->"
  assert_failure
  assert_output --partial 'skip game: ga-3 waits on'
  GATES_LOADED=''; load_gates
  DRY=0 JUDGE_RC='' fill_day 2
  # The item keeps the gate, and agent-queue reads the same grant at its start.
  [[ " $(item_tags ga-1) " == *" hold:critical "* ]]
  [[ " $(item_tags ga-2) " == *" hold:critical "* ]]
  run ls "$AGENT_QUEUE_DIR"/*/*-ga-3.md
  assert_failure
}

@test "row gates: #after/<row-id> holds the row until that row closes done" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] feat(game): the map first <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] feat(game): then its doors $T #after/ga-1 <!-- id:ga-2 -->"
  run cmd_candidates
  assert_output ''
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "ga-2") | .blocked | join("; ")' <<<"$output")" 'waits on after ga-1 (open)'
  notes ptask game --agent done ga-1
  run cmd_candidates
  assert_equal "$(jq -r '"\(.key) \(.gated) \(.gates)"' <<<"$output")" 'ga-2 true after/ga-1'
  # A gated row is never judged.
  run unjudged_rows
  assert_output ''
}

@test "pull-after promotes the open rows gated #after/<id>, that row counted clear: high starts at once, normal and low wait their turn, another pending gate holds" {
  project game beta "$SANDBOX/repos/game"
  gate_rbw
  row game agent ga-1 "- [/] feat(game): the map first <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] feat(game): then its doors $T #high #after/ga-1 <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] feat(game): the paint $T #low #after/ga-1 <!-- id:ga-3 -->"
  row game agent ga-4 "- [ ] feat(game): the keys $T #after/ga-1 #rbw/infra/x <!-- id:ga-4 -->"
  row game agent ga-5 "- [ ] feat(game): unrelated $T <!-- id:ga-5 -->"
  row game agent ga-7 "- [ ] feat(game): the sounds $T #normal #after/ga-1 <!-- id:ga-7 -->"
  cmd_start() { echo "start $*" >> "$NOTES_FIXTURE/started"; }
  run cmd_pull_after ga-1
  assert_success
  assert_output --partial "pull-after ga-1: ga-3 is low priority, so a pass starts it in its turn"
  assert_output --partial "pull-after ga-1: ga-7 is normal priority, so a pass starts it in its turn"
  assert_equal "$(cat "$NOTES_FIXTURE/started")" "start --item ga-2"
  assert_equal "$(agent-queue list --state queued --json | jq -r .slug | sort | paste -sd,)" "ga-2,ga-3,ga-7"
  assert_output --partial "skip game: ga-4 waits on rbw infra/x"
  # The row it could not queue is in the log, which outlives the closing session's stderr; ga-2 is not.
  run grep -c 'pull-after ga-1: row ga-4 was not queued: skip game: ga-4 waits on rbw infra/x' "$LOG"
  assert_output 1
  run grep -c 'row ga-2 was not queued' "$LOG"
  assert_output 0
  run grep -c 'ptask game --agent tag --remove after/ga-1 ga-2' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # Negative controls: no id is usage, and under the dispatch hold nothing is pulled.
  run cmd_pull_after
  assert_failure 2
  row game agent ga-6 "- [ ] feat(game): the roof $T #after/ga-1 <!-- id:ga-6 -->"
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run cmd_pull_after ga-1
  assert_success
  assert_output --partial "dispatch is held"
  [ -z "$(agent-queue list --state queued --json | jq -r 'select(.slug == "ga-6") | .slug')" ]
}

@test "pull-after --queue-only queues the rows gated on the closed row and starts none" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [/] feat(game): the map first <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] feat(game): then its doors $T #high #after/ga-1 <!-- id:ga-2 -->"
  cmd_start() { echo "start $*" >> "$NOTES_FIXTURE/started"; }
  run cmd_pull_after --queue-only ga-1
  assert_success
  assert_equal "$(agent-queue list --state queued --json | jq -r .slug | paste -sd,)" "ga-2"
  [ ! -e "$NOTES_FIXTURE/started" ]
}

@test "pull-after starts every high row gated on the closed row, though a start reads stdin" {
  # Every row gated on the closed one is read, whatever a start reads from stdin (chain-after-stuck).
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [/] feat(game): the map first <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] feat(game): then its doors $T #high #after/ga-1 <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] feat(game): the paint $T #low #after/ga-1 <!-- id:ga-3 -->"
  row game agent ga-4 "- [ ] feat(game): then its roof $T #high #after/ga-1 <!-- id:ga-4 -->"
  cmd_start() { cat >/dev/null; echo "start $*" >> "$NOTES_FIXTURE/started"; }
  run cmd_pull_after ga-1
  assert_success
  assert_equal "$(paste -sd, "$NOTES_FIXTURE/started")" "start --item ga-2,start --item ga-4"
  assert_equal "$(agent-queue list --state queued --json | jq -r .slug | sort | paste -sd,)" "ga-2,ga-3,ga-4"
}

@test "row gates: cleared gates commit an agent row only, the human's row still needs its verdict, and a gated row keeps its verdict's area" {
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  project game beta "$SANDBOX/repos/game"
  # at/0000 is past at any hour, so both rows' gates are clear.
  row game human gh-1 "- [ ] feat(game): the human's row $T #at/0000 <!-- id:gh-1 -->"
  row game agent ga-2 "- [ ] feat(game): the agent's row $T #at/0000 <!-- id:ga-2 -->"
  run cmd_candidates
  assert_equal "$(jq -r '"\(.lane) \(.key) \(.gated)"' <<<"$output" | sort | paste -sd,)" 'agent ga-2 true,human gh-1 null'
  run unjudged_rows
  assert_equal "$(jq -r .key <<<"$output")" gh-1
  # A skip verdict does not hold committed work, but the area it names does.
  verdict game agent ga-2 skip S 1 wilds
  started_item other-work lab:game-agent-3 run wilds
  run picks "$(all_open)" 2
  assert_output ''
  agent-queue move other-work done --status ok >/dev/null
  run picks "$(all_open)" 2
  assert_equal "$(jq -r '"\(.key) \(.area)"' <<<"$output")" 'ga-2 wilds'
}

@test "row gates: #ask/<id> holds until the ask is answered, the judge's answer too, and the cleared ask goes onto the item" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] feat(game): ship it $T #ask/a1 <!-- id:ga-1 -->"
  gate_ask a1 pending
  run cmd_candidates
  assert_output ''
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | join("; ")' <<<"$output")" 'waits on ask a1 (pending)'
  gate_ask a1 answered judge
  DRY=0 JUDGE_RC='' fill_day 2
  [[ " $(item_tags ga-1) " == *" ask:a1 "* ]]
}

@test "row gates: a gate read that fails starts no board row, and says so" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] fix(game): plain $T <!-- id:ga-1 -->"
  verdict game agent ga-1 dispatch
  stub agent-queue 'exit 1'
  run all_open
  assert_output --partial 'agent-queue gate --all failed (exit 1), so no board row starts this pass'
  refute_output --partial '"key"'
}

@test "skip_exits: each skip takes its rule's exit (plan, the human sheet, improvements.md, an #after/ or #pr/ gate); a dispatch moves nothing" {
  exits_fixture
  skip_exits
  assert_equal "$PLAN_TAGGED" 2
  assert_equal "$EXITS_TAKEN" 6
  run grep -oE 'ptask game --agent tag --add [^ ]+ gx-[0-9]+' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan gx-1
ptask game --agent tag --add after/gx-9 gx-4
ptask game --agent tag --add plan gx-5
ptask game --agent tag --add pr/kblack0610/dotfiles/3021 gx-6'
  # a bare design skip goes on the human sheet, a #low needs-person one to improvements.md, each without
  # its #worker/ tag, and each agent row is dropped naming where it went
  grep -qxF 'notes --profile bnb ptask game add row gx-2 #tier/1 (agent row gx-2) --origin fleet-dispatch' "$NOTES_FIXTURE/calls.log"
  grep -qxF 'notes --profile bnb improve game --why dispatch skipped it (needs-person): r -- row gx-3 #low #tier/1' "$NOTES_FIXTURE/calls.log"
  grep -q 'id:gx-2 dropped: on the game sheet: dispatch skipped it (design)' "$NOTES_FIXTURE/rows.game.agent"
  grep -q 'id:gx-3 dropped: kept in game improvements.md' "$NOTES_FIXTURE/rows.game.agent"
  # each exit is on record, and the verdict that carries it is not taken again
  assert_equal "$(jq -r 'select(.exit) | "\(.key)=\(.exit)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | paste -sd,)" \
    'gx-1=plan,gx-2=sheet,gx-3=improve,gx-4=after/gx-9,gx-5=plan,gx-6=pr/kblack0610/dotfiles/3021'
  : > "$NOTES_FIXTURE/calls.log"
  skip_exits
  assert_equal "$EXITS_TAKEN" 0
  run grep -E 'tag --add|improve|ptask game add|drop' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # negative control: the dispatch verdict's row was never touched
  run grep -c 'gx-7' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "skip_exits: a #low row that is health work goes to the human sheet, not improvements.md (ar-5401)" {
  exits_fixture
  touch "$NOTES_FIXTURE/improve.health"
  skip_exits
  assert_equal "$EXITS_TAKEN" 6
  grep -q 'ptask game add row gx-3 #low #tier/1 (agent row gx-3)' "$NOTES_FIXTURE/calls.log" || fail "no sheet row for the health row"
  grep -q 'id:gx-3 dropped: on the game sheet: dispatch skipped it (needs-person)' "$NOTES_FIXTURE/rows.game.agent" || fail "$(cat "$NOTES_FIXTURE/rows.game.agent")"
  run grep -c 'improve game --why' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_equal "$(jq -r 'select(.key == "gx-3" and .exit) | .exit' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" sheet
}

@test "skip_exits: --dry-run lists a health row's exit as the sheet's, not improve (ar-5401)" {
  exits_fixture
  touch "$NOTES_FIXTURE/improve.health"
  run skip_exits --dry-run
  assert_success
  assert_line 'sheet	game	gx-3	needs-person'
  assert_output --partial 'exits: gate 2 plan 2 sheet 2'
}

@test "skip_exits: --dry-run lists each row's exit and the counts, and writes nothing" {
  exits_fixture
  cp "$FLEET_DISPATCH_DIR/verdicts.jsonl" "$SANDBOX/before"
  run skip_exits --dry-run
  assert_success
  assert_output 'plan	game	gx-1	unclear
sheet	game	gx-2	design
improve	game	gx-3	needs-person
after/gx-9	game	gx-4	waits
plan	game	gx-5	waits
pr/kblack0610/dotfiles/3021	game	gx-6	waits
exits: gate 2 improve 1 plan 2 sheet 1'
  cmp "$FLEET_DISPATCH_DIR/verdicts.jsonl" "$SANDBOX/before"
  run grep -E 'tag --add|improve game --why|ptask game add|drop' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "skip_exits: a waits gate needs an open row and a verdict that otherwise fits; a planned row still skipped by a plan rule is held on the agent board" {
  exits_fixture
  # the reason names no open row (zz-404 is not on the board), or the row is not clear: plan
  skipv gx-4 waits 'waits on zz-404'; skipv gx-6 waits 'waits on gx-9' false
  # gx-1 was planned and the judge read that plan (its dsig) and still skips it; gx-5's verdict predates any dsig
  jq -c 'if .id == "gx-1" or .id == "gx-5" then .details = ["goal: split it"] else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b"
  mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  jq -c --arg d "$(detail_sig '"goal: split it"')" 'if .key == "gx-1" then .dsig = $d else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run skip_exits --dry-run
  assert_output --partial 'hold	game	gx-1	unclear'
  assert_output --partial 'plan	game	gx-4	waits'
  assert_output --partial 'plan	game	gx-6	waits'
  refute_output --partial 'gx-5'
  refute_output --partial 'after/'
}

@test "skip_exits: no person is needed for a spent plan exit or a human rule marked agent_only true, so it is held on the agent board; a person's rule keeps its level on the sheet; a check(epics) row takes no exit (ar-5968)" {
  exits_fixture
  row game agent gp-1 "- [ ] row gp-1 #high #why/red-main $T <!-- id:gp-1 -->"
  row game agent gp-2 "- [ ] row gp-2 #high #requested $T <!-- id:gp-2 -->"
  row game agent gp-3 "- [ ] row gp-3 #high $T <!-- id:gp-3 -->"
  row game agent gp-4 "- [ ] check(epics): verify gm-1 #high $T <!-- id:gp-4 -->"
  row game agent gp-5 "- [ ] row gp-5 #high $T <!-- id:gp-5 -->"
  row game agent gp-6 "- [ ] row gp-6 #high $T <!-- id:gp-6 -->"
  for k in gp-1 gp-2 gp-3 gp-4 gp-6; do board_row game agent "$k" '[]' '["goal: split it"]'; done
  board_row game agent gp-5 '[]' '[]'
  jq -c 'if .id == "gp-2" then .requested = true elif .id == "gp-4" then .type = "check" | .area = "epics" else . end' \
    "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b" && mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  # gp-1, gp-2 and gp-4 were planned and the judge read the plan (dsig) and still skips them; gp-3 by a rule that names
  # a person; gp-5 is a design skip the judge marked agent_only (not yet planned), gp-6 the same, planned
  skipv gp-1 unclear; skipv gp-2 unclear; skipv gp-3 design; skipv gp-4 unclear
  SKIPV_AO=true skipv gp-5 design; SKIPV_AO=true skipv gp-6 design
  jq -c --arg d "$(detail_sig '"goal: split it"')" 'if (.key | IN("gp-1", "gp-2", "gp-3", "gp-4", "gp-6")) then .dsig = $d else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  : > "$NOTES_FIXTURE/calls.log"
  run skip_exits --dry-run
  assert_output --partial 'hold	game	gp-1	unclear'
  assert_output --partial 'hold	game	gp-6	design'
  assert_output --partial 'plan	game	gp-5	design'
  skip_exits
  # a person's rule files its sheet row at the level it had
  grep -qxF "notes --profile bnb ptask game add row gp-3 #high #tier/1 (agent row gp-3) --origin fleet-dispatch" "$NOTES_FIXTURE/calls.log" ||
    fail "gp-3 not kept: $(grep 'gp-3' "$NOTES_FIXTURE/calls.log")"
  # NEGATIVE CONTROL: no held row files a sheet row, drops its agent row or reaches improvements.md
  run grep -E 'ptask game add row gp-[1256]|drop gp-[1256]|improve game.*gp-[1256]' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # gp-5 is tagged for its plan first, the epic check is untouched
  grep -qE 'tag --add plan gp-5' "$NOTES_FIXTURE/calls.log" || fail "gp-5 not planned"
  run grep -c 'gp-4' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # the hold is on record, costs no exit, and a second pass takes nothing again
  assert_equal "$(jq -r 'select(.key | startswith("gp-")) | select(.exit) | "\(.key)=\(.exit)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | sort | paste -sd,)" \
    'gp-1=hold,gp-2=hold,gp-3=sheet,gp-5=plan,gp-6=hold'
  assert_equal "$EXITS_HELD" 3
  : > "$NOTES_FIXTURE/calls.log"
  skip_exits
  assert_equal "$EXITS_HELD" 0
  run grep -E 'gp-[1236]' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "skip_exits: an agent row of a kind kinds.json turns off leaves the lane, #high to the human sheet and #low to improvements.md; an epic, a parent and a fix stay" {
  offkind_fixture
  : > "$NOTES_FIXTURE/calls.log"
  run skip_exits --dry-run
  assert_success
  assert_output 'sheet	game	gd-1	kind
improve	game	gd-2	kind
exits: improve 1 sheet 1'
  run grep -E 'improve game --why|ptask game add|drop' "$NOTES_FIXTURE/calls.log"
  assert_failure
  skip_exits
  assert_equal "$EXITS_TAKEN" 2
  grep -qxF 'notes --profile bnb ptask game add decide(game): pick the map #tier/1 #high (agent row gd-1) --origin fleet-dispatch' "$NOTES_FIXTURE/calls.log"
  grep -qxF 'notes --profile bnb improve game --why dispatch never starts it: kind design is off (kinds.json) -- design(game): a new menu look #tier/1 #low' "$NOTES_FIXTURE/calls.log"
  grep -q 'id:gd-1 dropped: on the game sheet: dispatch never starts it: kind decide is off' "$NOTES_FIXTURE/rows.game.agent"
  assert_equal "$(jq -r 'select(.exit) | "\(.key)=\(.exit)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | paste -sd,)" 'gd-1=sheet,gd-2=improve'
  run grep -E 'gd-[345]' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # each exit is on record, so a second pass over the same board (as after a drop that failed) files no copy
  : > "$NOTES_FIXTURE/calls.log"
  skip_exits
  assert_equal "$EXITS_TAKEN" 0
  # nor does a row whose latest verdict carries an earlier judge exit (a waits skip sent to a plan)
  verdict game agent gd-1 skip
  jq -c 'if .key == "gd-1" and .verdict == "skip" and .rule != "kind" then .rule = "waits" | .exit = "plan" else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run skip_exits --dry-run
  refute_output --partial 'gd-1'
}

@test "skip_exits: every skip rule in the shipped policy has exactly one exit" {
  one_exit() {
    local r n bad=''
    for r in $(judge_rules "$1"); do
      [ "$r" != fits ] || continue
      n=0
      [[ " $DISPATCH_PLAN_RULES " != *" $r "* ]] || n=$((n + 1))
      [[ " $DISPATCH_HUMAN_RULES " != *" $r "* ]] || n=$((n + 1))
      [ "$r" != waits ] || n=$((n + 1))
      [ "$n" = 1 ] || bad+=" $r"
    done
    [ -z "$bad" ] || { echo "no single exit:$bad"; return 1; }
  }
  run one_exit "$REPO_ROOT/.config/fleet-dispatch/policy.md"
  assert_success
  # negative control: a rule with no exit is caught
  cp "$REPO_ROOT/.config/fleet-dispatch/policy.md" "$SANDBOX/p.md"; echo '- (new-rule) a new skip' >> "$SANDBOX/p.md"
  run one_exit "$SANDBOX/p.md"
  assert_failure
  assert_output 'no single exit: new-rule'
}

@test "skip_exits: tags agent rows skipped as undefined and never planned, then kicks inbox-plan" {
  plan_fixture
  skip_exits
  assert_equal "$PLAN_TAGGED" 2
  run grep -o 'ptask game --agent tag --add plan [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-1
ptask game --agent tag --add plan ga-7'
  # negative controls: a design skip (the human's), a planned row, a dispatch, an edited row and a human row
  run grep -E 'tag --add plan (ga-2|ga-3|ga-4|ga-5|ga-6|gh-1)' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # ga-6 already waits, so inbox-plan's unit is started
  grep -qx -- '--user start --no-block agentctl@inbox-plan.service' "$NOTES_FIXTURE/systemctl.log"
}

@test "skip_exits: a requested row gets #go beside #plan, so inbox-plan does not hold it for the person's review" {
  plan_fixture
  jq -c 'if .id == "ga-7" then .requested = true else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b" && mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  skip_exits
  run grep -o 'ptask game --agent tag --add plan.* ga-[0-9]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-1
ptask game --agent tag --add plan --add go ga-7'
}

@test "verdicts: the latest verdict per row, plan true on a skip by a DISPATCH_PLAN_RULES rule (fleet-bench next_up_blocked)" {
  plan_fixture
  run cmd_verdicts
  assert_success
  assert_equal "$(jq -r 'select(.plan) | .key' <<<"$output" | sort | paste -sd,)" 'ga-1,ga-3,ga-5,ga-7,gh-1'
  # negative controls: a design skip and a dispatch are no split's to make
  assert_equal "$(jq -r 'select(.plan | not) | .key' <<<"$output" | sort | paste -sd,)" 'ga-2,ga-4'
  DISPATCH_PLAN_RULES=bundle run cmd_verdicts
  assert_equal "$(jq -r 'select(.plan) | .key' <<<"$output" | paste -sd,)" 'ga-7'
}

@test "skip_exits: a too-big skip queues one split per row: a second pass, a planned row and a stale verdict queue none" {
  printf '%s\n' '- (too-big) an L row' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  row game agent ga-20 "- [ ] feat(game): the whole store $T <!-- id:ga-20 -->"
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent ga-20 '[]' '[]'
  verdict game agent ga-20 skip L
  jq -c '.rule = "too-big"' "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  cp "$FLEET_DISPATCH_DIR/verdicts.jsonl" "$SANDBOX/v0"
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
  skip_exits
  assert_equal "$PLAN_TAGGED" 1
  run grep -c 'tag --add plan ga-20' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # without its exit on record (the first verdict only): the board now carries the tag, so nothing more
  cp "$SANDBOX/v0" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '["plan"]' '[]'
  skip_exits
  assert_equal "$PLAN_TAGGED" 0
  # inbox-plan wrote its goal and dropped the tag, and the verdict predates it: still none
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '[]' '["goal: split into stories"]'
  skip_exits
  assert_equal "$EXITS_TAKEN" 0
  # negative control on the signature: the row was edited after its verdict, so it waits for a new one
  sed -i 's/the whole store/the whole store and more/' "$NOTES_FIXTURE/rows.game.agent"
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '[]' '[]'
  skip_exits
  assert_equal "$EXITS_TAKEN" 0
  run grep -c 'tag --add plan ga-20' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "skip_exits: a row sized L or XL takes the plan exit with no verdict; an epic, a parent, a gated row, a failed one, a draft project's and a human skip keep theirs, and a planned one still L is held on the agent board" {
  printf '%s\n' '- (needs-person) a device run' >> "$DISPATCH_POLICY"
  sized_fixture
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
  run skip_exits --dry-run
  assert_success
  assert_output 'plan	game	gs-1	too-big
plan	game	gs-2	too-big
sheet	game	gs-5	needs-person
plan	game	gs-6	too-big
exits: plan 3 sheet 1'
  : > "$NOTES_FIXTURE/calls.log"
  skip_exits
  assert_equal "$PLAN_TAGGED" 3
  run grep -o 'tag --add plan --add go gs-2\|tag --add plan gs-[16]' "$NOTES_FIXTURE/calls.log"
  assert_output 'tag --add plan gs-1
tag --add plan --add go gs-2
tag --add plan gs-6'
  # the exit is on record, so a second pass over the same board (the tag not yet seen) plans nothing twice
  jq -c 'if .id == "gs-6" then .details = [] else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b" && mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  run skip_exits --dry-run
  assert_output --regexp '^exits: *$'
  # inbox-plan planned gs-1 and left it L: no person is needed to split it, so the recorded plan exit holds it, once
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent gs-1 '[]' '["goal: split it"]'
  jq -c '.size = "l" | .type = "feat"' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b" && mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  run skip_exits --dry-run
  assert_output 'hold	game	gs-1	too-big
exits: hold 1'
  : > "$NOTES_FIXTURE/calls.log"
  skip_exits
  run grep -E 'ptask game add|drop gs-1' "$NOTES_FIXTURE/calls.log"
  assert_failure
  run skip_exits --dry-run
  assert_output --regexp '^exits: *$'
}

@test "skip_exits: plan tags stop at DISPATCH_PLAN_BACKLOG open #plan rows, and the other exits go on" {
  plan_fixture
  DISPATCH_PLAN_BACKLOG=0 skip_exits
  assert_equal "$PLAN_TAGGED" 0
  assert_equal "$EXITS_TAKEN" 1   # ga-2, a design skip, to the human sheet
  run grep -c 'tag --add plan' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # ga-6 is the one #plan row open, so a room of 2 tags one more
  DISPATCH_PLAN_BACKLOG=2 skip_exits
  assert_equal "$PLAN_TAGGED" 1
}

@test "skip_exits: a row in progress takes no exit; DISPATCH_EXIT_MAX caps a pass and the next takes the rest" {
  exits_fixture
  jq -c 'if .id == "gx-1" then .state = "doing" else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b"
  mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  DISPATCH_EXIT_MAX=2 skip_exits
  assert_equal "$EXITS_TAKEN" 2
  skip_exits
  assert_equal "$EXITS_TAKEN" 3
  # gx-1 is doing: a session holds it, so it is never tagged, filed or dropped
  run grep -c 'gx-1' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_equal "$(jq -r 'select(.exit) | .key' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | sort | paste -sd,)" 'gx-2,gx-3,gx-4,gx-5,gx-6'
}

@test "skip_exits: a row filed whose agent row will not drop keeps its exit on record, so no later pass files it again" {
  exits_fixture
  np() { [[ " $* " != *" drop "* ]] || return 1; local p=$1; shift; notes --profile "$p" "$@"; }
  run skip_exits
  assert_output --partial 'skip_exits: game gx-2 is on the game sheet, but the agent row would not drop: drop it by hand'
  assert_equal "$(jq -r 'select(.key == "gx-2") | .exit // empty' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" sheet
  : > "$NOTES_FIXTURE/calls.log"
  run skip_exits
  run grep -c 'ptask game add' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "skip_exits: a #low row an open row gates #after/ on goes to the human sheet, not improvements.md, so the gate has a row to follow" {
  exits_fixture
  row game agent gx-8 "- [ ] row gx-8 #after/gx-3 $T <!-- id:gx-8 -->"
  board_row game agent gx-8 '["after/gx-3"]' '[]'
  skip_exits
  grep -qxF 'notes --profile bnb ptask game add row gx-3 #low #tier/1 (agent row gx-3) --origin fleet-dispatch' "$NOTES_FIXTURE/calls.log"
  grep -q 'id:gx-3 dropped: on the game sheet' "$NOTES_FIXTURE/rows.game.agent"
  run grep -c 'improve game' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_equal "$(jq -r 'select(.key == "gx-3") | .exit // empty' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" sheet
}

@test "skip_exits: a row sent to the sheet takes its dependents' #after/ gates along in the same pass, so queue-starved never reads them dead (ar-3172)" {
  printf '%s\n' '- (needs-person) a device run' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  row game agent gx-2 "- [ ] row gx-2 $T <!-- id:gx-2 -->"
  row game agent gx-8 "- [ ] row gx-8 $T #after/gx-2 <!-- id:gx-8 -->"
  # the notes stand-in files no sheet row, so the copy the sheet exit writes is there from the start
  row game human hm-2 "- [ ] row gx-2 (agent row gx-2) <!-- id:hm-2 -->"
  skipv gx-2 needs-person
  skip_exits
  grep -q 'id:gx-2 dropped: on the game sheet' "$NOTES_FIXTURE/rows.game.agent"
  # NEGATIVE CONTROL: before ar-3172 gx-8 kept #after/gx-2 until the next pass's reap
  grep -q '^- \[ \] row gx-8 .*#after/hm-2 <!-- id:gx-8 -->' <(cut -f2 "$NOTES_FIXTURE/rows.game.agent")
  GATES_LOADED=''
  run dead_holds
  assert_output ''
}

@test "skip_exits: exits takes --dry-run or nothing; any other argument is a usage error that moves no row" {
  exits_fixture
  run skip_exits --dryrun
  assert_failure 2
  assert_output --partial 'usage: fleet-dispatch exits [--dry-run]'
  run grep -cE 'tag --add|improve|ptask game add|drop' "$NOTES_FIXTURE/calls.log"
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

@test "candidates: an untagged worker takes untagged agent rows of any project, at its own tier" {
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
  assert_equal "$(jq -r '"\(.key)=\(.worker)/\(.tier)"' <<<"$output" | paste -sd,)" 'plain=board/2,tier one=board/1,other project=board/2'
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

@test "the shipped registry: requested, then the human's assignments, then every project's agent board, never tier 3" {
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
  assert_equal "$(jq -sr 'sort_by(.wrank) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'an ask=requested,assigned=fleet,plain=board,platform plain=board'
}

@test "the shipped registry: the AI systems and the home cluster have a day worker, under the same tier ceiling; an off project (finance, in the conf) has none" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json" DISPATCH_OFF_PROJECTS=finance
  mkdir -p "$SANDBOX/repos/ar" "$SANDBOX/repos/hc" "$SANDBOX/repos/fin"
  project agent-runtime alpha "$SANDBOX/repos/ar"
  project home-config alpha "$SANDBOX/repos/hc"
  project finance alpha "$SANDBOX/repos/fin"
  row agent-runtime agent 'ar fix' '- [ ] fix(intake): retry a failed sweep'
  row agent-runtime agent 'ar ci' '- [ ] ci(runners): the pool'
  row home-config agent 'hc row' '- [ ] chore(dns): tidy a record'
  row finance agent 'fin row' '- [ ] chore(budget): a sheet'
  OFF_SAY=1 run --separate-stderr cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.key) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'ar fix=board,hc row=board'
  assert_equal "$stderr" 'fleet-dispatch: no worker covers finance: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human'
}

@test "picks: only S or M, clear, agent-only dispatch verdicts, several per project, sooner feed rank then prod first" {
  c() { jq -cn --arg p "$1" --arg s "$2" --arg k "$3" --argjson fr "$4" \
        '{profile: "bnb", project: $p, stage: $s, lane: "human", key: $k, frank: $fr, tier: 1, line: ""}'; }
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

@test "picks: never two on one area in a pass, the sooner feed rank wins, whatever the case" {
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

@test "picks: a row that names a game holds that game, not the system word of its prefix" {
  project game beta "$SANDBOX/repos/game"
  mkdir -p "$SANDBOX/repos/game/Assets/Games/ShapeCity" "$SANDBOX/repos/game/Assets/Games/DodginBalls" "$SANDBOX/repos/game/Assets/Games/Vehicles3D"
  ct() { jq -cn --arg k "$1" --arg t "$2" --arg r "$SANDBOX/repos/game" '{profile: "bnb", project: "game", repo: $r, stage: "beta", lane: "agent", key: $k, frank: 1, tier: 2, line: "", text: $t}'; }
  local k
  for k in dodge shape cars plain; do verdict game agent "$k" dispatch S 1 gameplay; done
  # An item in ShapeCity holds ShapeCity alone; two other games start side by side, stamped with their game.
  started_item other-work lab:game-agent-3 run shapecity
  run picks "$(ct dodge '- [ ] fix(gameplay): DodginBalls bots miss'; ct shape '- [ ] fix(gameplay): ShapeCity bots throw'; ct cars '- [ ] fix(gameplay): vehicles3d wheels <!-- id:x -->')" 3
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd' ')" 'cars dodge'
  assert_equal "$(jq -r .area <<<"$output" | sort | paste -sd' ')" 'dodginballs vehicles3d'
  # A row that names no game keeps the verdict's area, and an item on that area holds it.
  started_item gp-work lab:game-agent-4 run gameplay
  run picks "$(ct plain '- [ ] fix(gameplay): shared ball physics'; ct dodge '- [ ] fix(gameplay): DodginBalls bots miss')" 2
  assert_equal "$(jq -r .key <<<"$output")" dodge
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

@test "picks: at one feed rank, an ask outranks a row of a later worker" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson fr "$3" '{project: "game", stage: "beta", lane: "agent", key: $k, wrank: $w, frank: $fr, tier: 2, line: ""}'; }
  cands=$(c urgent 2 5; c theask 0 5)
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
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  export DISPATCH_OFF_PROJECTS=app
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
  assert_output "auto  unjudged  game game human  [fleet, #normal, beta]
auto  dispatch  game game judged  [fleet, #high, beta]
auto  dispatch  game game busy  [fleet, #normal, beta]  blocked: area held by a queue item
auto  unjudged  game game new  [fleet, #normal, beta]
man   unjudged  app app row  [#high, alpha]  blocked: no worker covers app: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human"
  refute_output --partial 'app human'
  refute_output --partial 'sketch'
  run grep -c 'judge called' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A policy that drops the rule the verdicts name leaves them unusable, so the list says unjudged, not dispatch.
  echo 'policy v2' > "$DISPATCH_POLICY"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.verdict)/\(.auto)"' <<<"$output" | paste -sd' ')" \
    'game human=unjudged/true game judged=unjudged/true game busy=unjudged/true game new=unjudged/true app row=unjudged/false'
}

@test "suggest: each row no worker takes names why: an off project, the tier-3 gate's skip word, a tier-3 row in any project, no worker on its lane, size, the judge" {
  echo '{"board": {"max_tier": 2, "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  export DISPATCH_OFF_PROJECTS=app
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  mkdir -p "$SANDBOX/repos/night"
  project night alpha "$SANDBOX/repos/night"
  row app agent 'app row' "- [ ] app row"
  row app agent 'app low' "- [ ] app low #tier/1"
  row night agent 'night sudo' "- [ ] chore(box): run it with sudo #tier/3"
  row night agent 'night plain' "- [ ] chore(box): tidy the docs"
  row game agent 'game ci' "- [ ] ci(game): the runner pool #tier/3"
  row game agent 'game big' "- [ ] feat(game): a whole new mode #size/l"
  row game agent 'game skip' "- [ ] feat(game): a skipped one"
  verdict game agent 'game skip' skip
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  # Stage decides: every row of a project at dev or later has a worker, but an off project's; a
  # tier-3 row of any of them is the gate's, unless a skip word keeps it with the human.
  assert_equal "$(b 'app row')" 'no worker covers app: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human'
  assert_equal "$(b 'app low')" 'no worker covers app: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human'
  assert_equal "$(b 'night sudo')" 'tier3 skip: sudo'
  assert_equal "$(b 'night plain')" ''
  assert_equal "$(jq -r 'select(.key == "night plain") | .worker' <<<"$output")" board
  assert_equal "$(b 'game ci')" 'tier3 only: the tier-3 gate takes it'
  assert_equal "$(b 'game big')" 'size/l: too big for a pick'
  assert_equal "$(b 'game skip')" 'judge: skip, r'
  # active: no repo here has a commit, so a row nobody takes is never marked worked on today.
  assert_equal "$(jq -r 'select(.key == "app row") | .active' <<<"$output")" false
  # With no untagged worker on the agent lane, an untiered row is the tier-3 gate's, and a tier-1 one has no path.
  run nobody_why "$(echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"; workers)" agent '- [ ] chore(box): tidy the docs'
  assert_output 'tier3 only: no day worker reads the agent lane'
  run nobody_why "$(workers)" agent '- [ ] chore(box): tidy the docs #tier/1'
  assert_output 'no untagged worker reads the agent lane'
}

@test "rank: a cleanup kind (kinds.json) of an AI system outranks the rest of its bucket; a feature, docs or an adding refactor there, or a fix elsewhere, does not" {
  echo '{"personal": {"max_tier": 2, "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
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
  for k in 'game fix' 'app feat' 'app docs' 'app split'; do ranked "${k%% *}" agent "$k" "$(fk 3 0 1)"; done
  for k in 'app fix' 'app stale' 'app delete'; do ranked app agent "$k" "$(fk 3 2 1)"; done
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'app fix app stale app delete game fix app feat app docs app split'
  assert_equal "$(jq -r 'select(.key == "app fix") | .why' <<<"$output")" 'cleanup, personal, #low, bug, beta'
  assert_equal "$(jq -r 'select(.key == "game fix") | .cleanup' <<<"$output")" 1
  # Empty scope turns it off: back to the feed rank.
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

@test "rank: cleanup goes first, then the feed rank; why names due and #requested, and a lookalike tag is not #requested" {
  c() { jq -cn --arg k "$1" --argjson fr "$2" --argjson cl "$3" --arg t "$4" --argjson pr "$5" \
    "$RANK_JQ"'{key: $k, wrank: 0, prio: $pr, frank: $fr, cleanup: $cl, stage: "beta", text: "- [ ] \($k) \($t)"} | rank_fields("2026-11-05")'; }
  cands=$(c urgent "$(fk 3 0 1)" 1 '#urgent' 0; c cleanup "$(fk 3 2 1)" 0 '#low' 3; c asked "$(fk 3 2 0)" 1 '#low #requested' 3
    c due "$(fk 1 1 1)" 1 '#high #due1105' 1; c lookalike "$(fk 3 1 1)" 1 '#requested-ish' 1)
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'cleanup due urgent lookalike asked'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "asked") | .why' <<<"$cands"
  assert_output 'requested, #low, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "due") | .why' <<<"$cands"
  assert_output 'due today, #high, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "lookalike") | .why' <<<"$cands"
  assert_output '#high, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "cleanup") | .why' <<<"$cands"
  assert_output --regexp '^cleanup, '
}

@test "suggest: reads the profiles run reads (DISPATCH_PROFILES), never a list derived from notes projects --stats" {
  export DISPATCH_PROFILES="bnb personal"
  project game beta "$SANDBOX/repos/game"
  row game agent 'game row' "- [ ] game row $T"
  run cmd_suggest --json
  assert_success
  assert_equal "$(grep -c '^notes --profile bnb projects' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(grep -c '^notes --profile personal projects' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(grep -c '^notes --profile [a-z]* projects' "$NOTES_FIXTURE/calls.log")" 2
  run grep -c -- '--stats' "$NOTES_FIXTURE/calls.log"
  assert_output 0
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

@test "rank: the feed rank (due, priority, age) orders every project's rows, each named in why; a focus project ranks nothing" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  focus_on game
  project app alpha "$SANDBOX/repos/app"
  row app agent 'app urgent' "- [ ] app urgent #urgent $T"
  row app agent 'app due' "- [ ] app due #due1105 $T"
  row game agent 'game low' "- [ ] game low #low $T #c1101"
  row game agent 'game high new' "- [ ] game high new #high $T #c1104"
  row game agent 'game high' "- [ ] game high #high $T #c1020"
  ranked app agent 'app urgent' "$(fk 3 0 1)"
  ranked app agent 'app due' "$(fk 1 1 1)"
  ranked game agent 'game low' "$(fk 3 2 1 2026-11-01)"
  ranked game agent 'game high new' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game high' "$(fk 3 1 1 2026-10-20)"
  run cmd_candidates
  assert_success
  run jq -sr "$RANK_JQ"'rank[] | "\(.key): \(.why)"' <<<"$output"
  assert_output "app due: due today, fleet, #normal, alpha
app urgent: fleet, #urgent, alpha
game high: fleet, #high, beta, 16d old
game high new: fleet, #high, beta, 1d old
game low: fleet, #low, beta, 4d old"
}

@test "rank: at one feed rank, the order is worker, then stage; the row's own tags decide nothing" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson pr "$3" --arg st "$4" \
    "$RANK_JQ"'{key: $k, wrank: $w, prio: $pr, frank: 21000000, stage: $st, text: "- [ ] \($k)"} | rank_fields("2026-11-05")'; }
  cands=$(c alpha-urgent 1 0 alpha; c prod-high 1 1 prod; c beta-high 1 1 beta; c asked 0 2 alpha)
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'asked prod-high beta-high alpha-urgent'
}

@test "kinds: kinds.json names every notes-cli row type and no other, each with rank, entry, rung, exit and enabled, and none with stages or off" {
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
  jq '.fix.stages = ["dev"]' "$DISPATCH_KINDS" > "$SANDBOX/stages.json"
  run kinds_match "$SANDBOX/stages.json"
  assert_failure
}

@test "rank: at one feed rank a fix row goes before a feat row, and why calls it a bug" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game feat' "- [ ] feat(game): a new mode #high $T #c1104"
  row game agent 'game fix' "- [ ] fix(game): the score is wrong #high $T #c1104"
  row game agent 'game urgent feat' "- [ ] feat(game): the menu #urgent $T #c1104"
  ranked game agent 'game feat' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game fix' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game urgent feat' "$(fk 3 0 1 2026-11-04)"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game urgent feat,game fix,game feat'
  assert_equal "$(jq -r 'select(.key == "game fix") | .why' <<<"$output")" 'fleet, #high, bug, beta, 1d old'
  assert_equal "$(jq -r 'select(.key == "game feat") | .why' <<<"$output")" 'fleet, #high, beta, 1d old'
}

@test "rank: a row with no priority tag, which the feed ranks as #normal, reads as #normal in why and priority" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game high' "- [ ] game high #high $T #c1104"
  row game agent 'game bare' "- [ ] game bare $T #c1001"
  row game agent 'game low' "- [ ] game low #low $T #c0901"
  ranked game agent 'game high' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game bare' "$(fk 3 1 1 2026-10-01)"
  ranked game agent 'game low' "$(fk 3 2 1 2026-09-01)"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game bare,game high,game low'
  assert_equal "$(jq -r 'select(.key == "game bare") | "\(.why) \(.priority)"' <<<"$output")" 'fleet, #normal, beta, 35d old normal'
}

@test "rank: a row the feed aims at its project's target ranks by the feed and its why says release due; its own sooner #due wins" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game plain' "- [ ] game plain $T #c1001"
  row game agent 'game aimed' "- [ ] game aimed $T #c1002"
  ranked game agent 'game plain' "$(fk 3 1 1 2026-10-01)"
  # notes-cli puts the aimed row in the due-soon bucket from the Target: day and says so in release_due.
  board_row game agent 'game aimed' '[]' '[]' "$(fk 2 1 1 2026-10-02)"
  sed -i '$s/}$/,"release_due":"2026-11-06"}/' "$NOTES_FIXTURE/board.rows"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game aimed,game plain'
  assert_equal "$(jq -r 'select(.key == "game aimed") | .why' <<<"$output")" 'release due in 1d, fleet, #normal, beta, 34d old'
  # Its own #due today is sooner than the target: the why names the row's own date.
  run jq -nr "$RANK_JQ"'{text: "- [ ] x #due1105", release_due: "2026-11-06", prio: 1, stage: "beta"} | rank_fields("2026-11-05") | .why'
  assert_output 'due today, #high, beta'
}

@test "rank: within a project the feed's rank decides, even against the row's own tags; a row the feed does not rank goes last" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game low' "- [ ] game low #low $T #c1104"
  row game agent 'game urgent' "- [ ] game urgent #urgent #due1105 $T #c1001"
  row game agent 'game unranked' "- [ ] game unranked #urgent #due1101 $T #c0901"
  # The feed puts the #low row first: dispatch reads that, it does not re-derive one from the tags.
  ranked game agent 'game low' 5
  ranked game agent 'game urgent' 7
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.frank)"' <<<"$output" | paste -sd,)" 'game low=5,game urgent=7,game unranked=null'
  # Negative control: swap the feed's ranks and the order follows them, text unchanged.
  : > "$NOTES_FIXTURE/board.rows"
  ranked game agent 'game low' 7
  ranked game agent 'game urgent' 5
  ranked game agent 'game unranked' 6
  run cmd_suggest --json
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game urgent,game unranked,game low'
}

@test "candidates: a kind that is off and a parent row never reach the judge; suggest says why" {
  jq -n '{fix: {rank: 0, label: "bug", entry: "/one-shot", rung: "build", exit: "pr", enabled: true},
          feat: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", enabled: true},
          chore: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", enabled: false},
          decide: {rank: 1, entry: "", rung: "human", exit: "ask", enabled: false},
          epic: {rank: 1, entry: "", rung: "human", exit: "none", enabled: false}}' > "$SANDBOX/kinds.json"
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
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-6,ap-1,ap-2'
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  assert_equal "$(b gm-2)" 'kind decide is off'
  assert_equal "$(b gm-3)" 'kind chore is off'
  assert_equal "$(b gm-4)" 'kind epic is off'
  assert_equal "$(b gm-5)" 'a parent: open rows name it in #of/'
  # negative control: an enabled kind at an alpha project is the stage's to judge, not the registry's
  assert_equal "$(b ap-1)" ''
  assert_equal "$(b gm-1)" ''
  # A closed child holds nothing: with no open row naming it, the parent is a row like any other.
  : > "$NOTES_FIXTURE/board.rows"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-5,gm-6,ap-1,ap-2'
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

@test "item_brief: an item held on an ask is told the human's answer, in the cloud brief too" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  printf 'id: d1\nquestion: which label?\nstatus: answered\nanswer: a\nanswered_by: human\noptions: a|b\noption_notes: accept it|write by hand\n' > "$AGENT_ASK_ROOT/game/d1.md"
  agent-ask() { "$REPO_ROOT/.local/bin/agent-ask" "$@"; }
  it() { jq -cn --arg t "$1" '{slug: "s", mode: "oneshot", title: "plain task", task: "plain task", tags: $t}'; }
  local line='The human already decided this in ask d1, so follow it: which label? Answer: a (accept it)'
  run item_brief "$(it 'ask:d1=a+b')"
  assert_line "$line"
  run item_brief "$(it 'ask:d1=a+b')" claude-cloud
  assert_line "$line"
  # Negative control: no ask tag, no such line.
  run item_brief "$(it '')"
  refute_output --partial 'already decided'
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
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$(it 'fix(game): the score' '')" opencode
  assert_line --index 0 'Read ~/.claude/skills/fix-skill/SKILL.md and follow it for this task:'
}

@test "item_brief: a repo whose canonical forge is Forgejo merges with agent-land too, which lands it through that API (ar-1213)" {
  project game beta "$SANDBOX/repos/game"
  mkdir -p "$SANDBOX/repos/game/.forgejo/workflows"; : > "$SANDBOX/repos/game/.forgejo/workflows/mirror-to-github.yaml"
  it='{"slug": "hc", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}'
  run item_brief "$it"
  assert_output --partial 'Merge with agent-land <N> (AGENT_QUEUE_ITEM=hc is set)'
  refute_output --partial 'landing.md'
  echo '{"harnesses": {"codex": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$it" codex
  assert_output --partial 'Right after the PR opens, run: agent-queue set hc pr='
  assert_output --partial 'Run agent-land in the foreground'
}

@test "every brief that starts or resumes a Claude session has a line agent-panel reads as not the human" {
  # agent-panel's human_at skips a prompt typed-prefixes.conf calls fleet-typed; a brief without
  # one reads as the human typing and holds the session open for the human keep.
  local b
  . "$REPO_ROOT/.local/lib/typed-prefixes.sh"
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  marked() { fleet_typed "$1" || { echo "no line of typed-prefixes.conf starts: $1"; return 1; }; }
  for b in \
    '{"slug": "s", "mode": "oneshot", "project": "game", "title": "plain task", "task": "plain task"}' \
    '{"slug": "s", "mode": "oneshot", "project": "game", "title": "plain task", "task": "plain task", "tags": "ui"}' \
    '{"slug": "s", "mode": "oneshot", "project": "game", "title": "x", "task": "x", "pr": "o/r#1", "fix_tries": "1 abc"}' \
    '{"slug": "s", "mode": "oneshot", "project": "game", "title": "x", "task": "x", "pr": "o/r#1", "pr_owner": "land", "land_tries": "1 abc"}' \
    '{"slug": "r", "mode": "oneshot", "project": "game", "title": "research(game): which", "task": "research(game): which", "type": "research", "row": "game:ar-9", "lane": "agent"}' \
    '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "ship the games", "task": "ship the games", "type": "release"}'; do
    marked "$(item_brief "$b")"
  done
  marked "$(resume_brief '{"slug": "s", "end_reason": "limit"}')"
  marked "$(resume_brief '{"slug": "s"}')"
  marked "$(trainee_batch_task trainee-batch-1 '{"slug": "s", "task": "x", "trainee": "trn"}')"
  # Negative control: the raw task alone is the human's words, unmarked.
  run marked "plain task"
  assert_failure
}

@test "item_brief: a doc+ask kind ends on a doc in the lab docs and an ask recorded on the item, never a PR" {
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "r", "mode": "oneshot", "project": "game", "title": "research(game): which engine", "task": "research(game): which engine", "type": "research", "row": "game:ar-9", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 '/deep-research-code research(game): which engine'
  assert_output --partial 'a research row: it ends on a doc and an ask, never a PR'
  assert_output --partial 'agent-queue set r report=<doc path> ask=<ask id>; notes ptask game --agent done "ar-9" --proof doc:<doc path>; agent-queue move r done --status ok'
  refute_output --partial 'Run agent-land in the foreground'
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
  assert_output --partial 'a release row: it ends on live proof, never a PR or agent-land'
  assert_output --partial 'agent-queue set rel note="<proof>"; notes ptask game --agent done "ar-7" --proof "<proof>"; agent-queue move rel done --status ok'
  assert_output --partial 'If a step needs a decision from the human'
  refute_output --partial 'Merge with agent-land'
  refute_output --partial 'Item: rel'
  # the kind comes from the item's type too, and with no row there is no row to close
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "ship the games", "task": "ship the games", "type": "release"}'
  assert_line --index 0 '/release ship the games'
  assert_output --partial 'agent-queue set rel note="<proof>"; agent-queue move rel done --status ok'
  refute_output --partial 'notes ptask'
  # a tier-3 item gets no merge gate: a release opens no PR
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "agent-runtime", "title": "release(steam): x", "task": "release(steam): x", "tags": "tier3"}'
  assert_line --index 0 '/release release(steam): x'
  refute_output --partial 'red-fix gate'
  # a headless harness gets no wind-down and no window to leave open
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "release(steam): x", "task": "release(steam): x"}' opencode
  assert_line --index 0 'Read ~/.claude/skills/release/SKILL.md and follow it for this task:'
  assert_output --partial 'agent-queue move rel done --status ok.'
  assert_output --partial 'agent-queue requeue rel --ask <id>, and stop: the answer starts this item again'
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
  printf '%s\n' 'policy' '- (other) another rule' > "$DISPATCH_POLICY"
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_output ''
}

@test "picks: no room means no picks" {
  verdict game human k dispatch
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1}' 0
  assert_output ''
}

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
  stub judge-stub 'echo "$AGENTCTL_CALL_ID" >> "$NOTES_FIXTURE/call.id"; cat "$NOTES_FIXTURE/judge.out"'
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
{"verdicts":[{"project":"game","lane":"human","key":"a","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","rule":"fits","reason":"small"},{"project":"game","lane":"human","key":"b","verdict":"skip","rule":"vibes","reason":"x"},{"project":"game","lane":"human","key":"c","verdict":"skip","reason":"no rule"}]}
EOF
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c; c d)"
  assert_success
  local id retry; id=$(sed -n 1p "$NOTES_FIXTURE/call.id"); retry=$(sed -n 2p "$NOTES_FIXTURE/call.id")
  [ -n "$id" ] && [ -n "$retry" ] && [ "$id" != "$retry" ]
  v() { jq -r --arg k "$1" --arg id "$id" 'select(.key == $k) | "\(.verdict) \(.rule // "-") \(.judge_call == $id) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  assert_equal "$(v a)" 'dispatch fits true small'
  assert_equal "$(v b)" 'error - true rule "vibes" is not in the policy'
  assert_equal "$(v c)" 'error - true rule "" is not in the policy'
  # d was left out twice (the retry's reply has no d either), so its error names the retry's call
  assert_equal "$(v d)" 'error - false neither the reply nor its retry had a verdict for this row'
  assert_equal "$(jq -r 'select(.key == "d") | .judge_call' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" "$retry"
  # An error holds nothing: those rows are judged again; the dispatch verdict holds.
  assert_equal "$(judged_keys | cut -f3 | paste -sd' ')" 'a'
}

@test "judge: a row the reply left out is asked for again, alone, and the retry's verdict leaves no error (ar-1645)" {
  # First call: a verdict for a only. Second call: one for b. Each call's id and prompt are kept.
  stub judge-stub 'n=$(( $(cat "$NOTES_FIXTURE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$NOTES_FIXTURE/n"
    echo "$AGENTCTL_CALL_ID" >> "$NOTES_FIXTURE/call.id"; printf "%s" "$2" > "$NOTES_FIXTURE/prompt.$n"
    cat "$NOTES_FIXTURE/judge.out.$n"'
  r() { jq -cn --arg k "$1" '{verdicts: [{project: "game", lane: "human", key: $k, tier: 1, size: "S", clear: true, agent_only: true, verdict: "dispatch", rule: "fits", reason: "small"}]}'; }
  r a > "$NOTES_FIXTURE/judge.out.1"; r b > "$NOTES_FIXTURE/judge.out.2"
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b)"
  assert_success
  assert_output --partial 'left out 1 row(s), asking again'
  assert_equal "$(cat "$NOTES_FIXTURE/n")" 2
  # the retry sends only the row left out, counted as such
  grep -qF 'There are 1 rows above. Return exactly 1 verdicts' "$NOTES_FIXTURE/prompt.2" || fail "$(cat "$NOTES_FIXTURE/prompt.2")"
  run grep -c '"key":"a"' "$NOTES_FIXTURE/prompt.2"
  assert_output 0
  # no error line; each verdict names the call that made it, and both rows are judged
  assert_equal "$(jq -r 'select(.verdict == "error")' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" ''
  assert_equal "$(jq -r 'select(.key == "b") | .judge_call' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" "$(sed -n 2p "$NOTES_FIXTURE/call.id")"
  assert_equal "$(judged_keys | cut -f3 | sort | paste -sd' ')" 'a b'
}

@test "judge: a row the retry leaves out too is an error verdict; a retry that fails names why, one stopped at its budget leaves none (negative control)" {
  stub judge-stub 'n=$(( $(cat "$NOTES_FIXTURE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$NOTES_FIXTURE/n"
    [ "$n" = 1 ] || [ -z "${RETRY_EXIT:-}" ] || { echo "rate limited" >&2; exit "$RETRY_EXIT"; }
    echo "{\"verdicts\":[{\"project\":\"game\",\"lane\":\"human\",\"key\":\"a\",\"verdict\":\"skip\",\"rule\":\"unclear\",\"reason\":\"x\"}]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  e() { jq -r 'select(.verdict == "error") | "\(.key) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  run judge "$(c a; c b)"
  assert_success
  assert_equal "$(cat "$NOTES_FIXTURE/n")" 2
  assert_equal "$(e)" 'b neither the reply nor its retry had a verdict for this row'
  assert_equal "$(judged_keys | cut -f3 | paste -sd' ')" 'a'
  # the retry call fails: b's error says so
  rm -f "$NOTES_FIXTURE/n" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  RETRY_EXIT=7 run judge "$(c a; c b)"
  assert_success
  assert_equal "$(e)" 'b the reply had no verdict for this row, and the retry call failed (exit 7): rate limited '
  # the retry stops at its budget: no verdict on b at all, so the next pass judges it, and the
  # pass gets the budget code (settle names the stop) while a's verdict stands
  rm -f "$NOTES_FIXTURE/n" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  RETRY_EXIT=75 run judge "$(c a; c b)"
  assert_equal "$status" 75
  assert_output --partial 'the retry for 1 left-out row(s) stopped at its budget'
  assert_equal "$(e)" ''
  assert_equal "$(jq -r .key "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'a'
}

@test "judge: the prompt numbers the rows and asks for exactly that many verdicts" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; echo "{\"verdicts\":[]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c)"   # an empty reply fails the pass; only the prompt matters here
  run grep -c '^[0-9]*\. {"project":"game"' "$NOTES_FIXTURE/prompt"
  assert_output 3
  grep -q '^3\. {"project":"game","stage":"beta","lane":"human","key":"c"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  grep -qF 'There are 3 rows above. Return exactly 3 verdicts' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
}

@test "judge: the call's schema holds the reply to exactly as many verdicts as rows (ucp-469)" {
  DISPATCH_SCHEMA="$REPO_ROOT/.config/fleet-dispatch/verdicts.schema.json"
  stub judge-stub '[ "$1" = --schema ] && cp "$2" "$NOTES_FIXTURE/schema.json"; echo "{\"verdicts\":[]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c)"
  assert_equal "$(jq -c '.properties.verdicts | [.minItems, .maxItems]' "$NOTES_FIXTURE/schema.json")" '[3,3]'
  # the rule is one of the policy's ids, so "(stage-scope)" with the policy's parentheses cannot be answered
  assert_equal "$(jq -c '.properties.verdicts.items.properties.rule.enum' "$NOTES_FIXTURE/schema.json")" \
    '["fits","unclear"]'
  # the rest is the conf's schema, unchanged
  assert_equal "$(jq -S 'del(.properties.verdicts.minItems, .properties.verdicts.maxItems, .properties.verdicts.items.properties.rule.enum)' "$NOTES_FIXTURE/schema.json")" \
    "$(jq -S . "$DISPATCH_SCHEMA")"
  # negative control: a schema that cannot be read makes no call and no verdict, so the rows are judged again
  rm -f "$NOTES_FIXTURE/schema.json" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; DISPATCH_SCHEMA="$SANDBOX/missing.json"
  run judge "$(c a)"
  assert_failure
  assert_output --partial 'no readable schema'
  assert [ ! -e "$NOTES_FIXTURE/schema.json" ]
  assert [ ! -s "$FLEET_DISPATCH_DIR/verdicts.jsonl" ]
  # and so does one whose verdicts are not where the reply puts them
  echo '{"type":"object","properties":{"rows":{"type":"array"}}}' > "$SANDBOX/moved.json"; DISPATCH_SCHEMA="$SANDBOX/moved.json"
  run judge "$(c a)"
  assert_failure
  assert [ ! -e "$NOTES_FIXTURE/schema.json" ]
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

@test "judge sends rows in rank order when the batch is capped: prod before alpha at one feed rank, a sooner alpha first" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","frank":21000000}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","frank":21000000}'
  assert_success
  run grep -c '"project":"p"' "$NOTES_FIXTURE/prompt"
  assert_output 1
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 0
  # The same cap picks the picks order, not a second one: the feed rank comes before stage.
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","frank":19000000}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","frank":21000000}'
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 1
}

@test "end-reasons.sh: the ends that say nothing about the model, one list for every reader" {
  . "$REPO_ROOT/.local/lib/end-reasons.sh"
  unrated_end limit || fail "limit is unrated"
  unrated_end handoff || fail "a handoff (agent-queue handoff) is unrated"
  ! unrated_end timeout || fail "a timeout rates the model"   # negative control
  ! unrated_end "" || fail "no end is not unrated"
  assert_equal "$(unrated_json)" '["refused","limit","provider","cut","handoff"]'
}

@test "judged_keys: a failure expires the row's verdicts; DISPATCH_FIX_TRIES since its last cleared hold it" {
  mkdir -p "$FLEET_DISPATCH_DIR"
  v() { jq -cn --arg k "$1" --arg v "$2" '{project: "game", lane: "human", key: $k, verdict: $v, reason: "t", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  verdict game human a dispatch; v a failed   # one failure: no hold, and the dispatch before it is gone
  verdict game human b dispatch; v b failed; verdict game human b dispatch   # judged again after it: that verdict stands
  v c failed; v c failed                       # at the limit: held
  v d failed; v d failed; v d cleared          # the ask's cleared starts the count again
  v e failed; v e failed; v e cleared; v e failed; v e failed   # and two more failures hold again
  echo '{"project": "game", "lane": "hu' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"   # a torn append
  v f failed; v f failed                       # a line after it is still read
  assert_equal "$(judged_keys | cut -f3,4 | paste -sd' ')" "$(printf 'b\t%s c\t* e\t* f\t*' "$(line_of game human b)")"
  # latest_verdicts agrees: a held row reads failed, an expired one reads nothing, a re-judged one its new verdict
  assert_equal "$(latest_verdicts | jq -r '"\(.key)=\(.verdict)"' | paste -sd' ')" 'b=dispatch c=failed e=failed f=failed'
  # DISPATCH_FIX_TRIES=1 is the old rule: one failure holds
  DISPATCH_FIX_TRIES=1
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }' | paste -sd' ')" 'a b c e f'
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

@test "promote: a row an open sprint holds gets the sprint tag from any path, a queued sprint's row and a plain row do not" {
  project game beta "$SANDBOX/repos/game"
  row game human sp-1 '- [ ] in the sprint #urgent <!-- id:sp-1 -->'
  row game human sp-2 '- [ ] in a queued sprint #urgent <!-- id:sp-2 -->'
  row game human sp-3 '- [ ] plain #urgent <!-- id:sp-3 -->'
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-1", state: "open"}]},
           {project: "game", queued: true, tasks: [{id: "sp-2", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  local k
  for k in sp-1 sp-2 sp-3; do
    run promote "$(jq -cn --arg k "$k" '{profile: "bnb", project: "game", lane: "human", key: $k}')" "" task
    assert_success
  done
  grep -q '^tags:.*sprint' "$(qitem queued sp-1)" || fail "the sprint row has no sprint tag: $(cat "$(qitem queued sp-1)")"
  ! grep -q '^tags:.*sprint' "$(qitem queued sp-2)" || fail "a queued sprint's row got the tag"
  ! grep -q '^tags:.*sprint' "$(qitem queued sp-3)" || fail "a plain row got the tag"
}

@test "promote: the slug is the row's id, the from joins on it, and the priority is the row's" {
  project game beta "$SANDBOX/repos/game"
  row game human 'urgent one' '- [ ] urgent one #urgent <!-- id:gm-7 -->'
  row game human 'low one' '- [ ] low one #low <!-- id:gm-8 -->'
  row game human 'bare one' '- [ ] bare one <!-- id:gm-9 -->'
  row game human 'normal one' '- [ ] normal one #normal <!-- id:gm-10 -->'
  row game human 'high one' '- [ ] high one #high <!-- id:gm-11 -->'
  # A bare row is the row grammar's default, normal (priority.md), as is a #normal one.
  for k in 7:urgent 8:low 9:normal 10:normal 11:high; do
    run promote "$(jq -cn --arg k "gm-${k%:*}" '{profile: "bnb", project: "game", lane: "human", key: $k}')" "" task
    assert_success
    assert_output --partial "queued game: gm-${k%:*}"
    f=$(qitem queued "gm-${k%:*}")
    [ -n "$f" ] || fail "no item for gm-${k%:*}"
    assert_equal "$(qfield "$f" priority) $(qfield "$f" from)" "${k#*:} board:game:gm-${k%:*}"
  done
  assert_equal "$(grep -c 'id:gm-' "$NOTES_FIXTURE/rows.game.human")" 5
}

@test "promote: a row whose item already finished ok is never queued again; a human row goes back recorded failed" {
  project game beta "$SANDBOX/repos/game"
  for k in gm-7 gm-8; do
    agent-queue add --project game --from "board:game:$k" --slug "$k" "x" >/dev/null
    agent-queue move "$k" done --status ok >/dev/null
  done
  # Rows written after the close: an ok close now closes its row, and these model rows left open before it did.
  row game human 'landed one' '- [ ] landed one <!-- id:gm-7 -->'
  row game agent 'landed two' '- [ ] landed two <!-- id:gm-8 -->'
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-7"}')" "" task
  assert_failure
  assert_output --partial 'row un-started, recorded failed: gm-7 already finished ok'
  grep -qF -- '- [ ] landed one' "$NOTES_FIXTURE/rows.game.human" || fail "human row left started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r '.key + " " + .verdict')" "gm-7 failed"
  # a retry cannot change it, so this one failure holds the row (hold, in_force)
  assert_equal "$(judged_keys | awk -F'\t' '$4 == "*" { print $3 }')" gm-7
  # An agent row stays started for the orphan pass, which closes it on its item's merge proof.
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-8"}')" "" task
  assert_failure
  assert_output --partial 'row left started for the orphan pass: gm-8 already finished ok'
  grep -qF -- '- [/] landed two' "$NOTES_FIXTURE/rows.game.agent" || fail "agent row un-started"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished row was queued again"
}

@test "promote: a row whose item finished ok under another slug is not queued again" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --from "board:game:gm-9" --slug game-gm-9 "x" >/dev/null
  agent-queue move game-gm-9 done --status ok >/dev/null
  # Written after the close, which now closes its row: a row left open before it did.
  row game agent 'landed three' '- [ ] landed three <!-- id:gm-9 -->'
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-9"}')" "" task
  assert_failure
  assert_output --partial 'gm-9 already finished ok on its own item game-gm-9'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished row was queued again"
}

@test "promote: a failed item, or an ok one on a row with a longer key, leaves the row to be queued" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'retry' '- [ ] retry <!-- id:gm-9 -->'
  agent-queue add --project game --from "board:game:gm-9" --slug game-gm-9 "x" >/dev/null
  agent-queue move game-gm-9 done --status failed >/dev/null
  agent-queue add --project game --from "board:game:gm-9x" --slug game-gm-9x "x" >/dev/null
  agent-queue move game-gm-9x done --status ok >/dev/null
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-9"}')" "" task
  assert_success
  assert_output --partial 'queued game: gm-9'
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

# promote --dispatch is a capped pull like dispatch's own, where a caller with no queue item is otherwise
# the human's hand start: fleet-bench triage promotes its reds with it, so the cap holds them (ar-3659).
# NEGATIVE CONTROL: with --dispatch ignored, the promote queues past the cap and this fails.
@test "fleet-dispatch promote --dispatch is held at the cap; the human's Start is not" {
  unset AGENT_QUEUE_ITEM AGENT_QUEUE_PULL   # the human at a terminal, whatever session runs the suite
  project game beta "$SANDBOX/repos/game"
  row game agent 'fix one' '- [ ] fix one #low <!-- id:gm-5 -->'
  agent-queue add --project game --slug filler "fills the cap" >/dev/null
  export AGENT_QUEUE_CAP=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --agent --dispatch --project game --profile bnb --tags red --raw '- [ ] fix one #low <!-- id:gm-5 -->'
  assert_failure
  assert_output --partial 'held by admission'
  [ -z "$(qitem queued gm-5)" ] || fail "a dispatch pull went past the cap"
  grep -qF -- '- [ ] fix one #low' "$NOTES_FIXTURE/rows.game.agent" || fail "the held row was left started"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --agent --project game --profile bnb --tags red --raw '- [ ] fix one #low <!-- id:gm-5 -->'
  assert_success
  [ -n "$(qitem queued gm-5)" ] || fail "the human's Start was held by the cap"
}

@test "fleet-dispatch promote --tags puts the tags on the item; without it the item has none" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix one' '- [ ] fix one #low <!-- id:gm-5 -->'
  row game human 'fix two' '- [ ] fix two #low <!-- id:gm-6 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --tags ui --raw '- [ ] fix one #low <!-- id:gm-5 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-5)" tags)" ui
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] fix two #low <!-- id:gm-6 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-6)" tags)" ""
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --tags
  assert_failure 2
}

# A dispatched session's add --plan files one row naming the plan (plan_row_task). NEGATIVE CONTROL:
# before ar-3262 promote queued that row as one oneshot item, gm-7, whose session ran every phase.
@test "promote: a plan row is queued as the plan's chain, the row on its rows: line and left started" {
  project game beta "$SANDBOX/repos/game"
  printf '# pp\n\nepic: gm-1\n\n## Phases\n\n- [x] P1 done (#1)\n- [ ] P2 two\n' > "$SANDBOX/pp.md"
  row game agent 'plan pp' '- [ ] plan pp: run its open phases #low <!-- id:gm-7 -->'
  board_row game agent gm-7 '[]' "$(jq -cn --arg d "$(plan_row_task "$SANDBOX/pp.md")" '[$d]')"
  # Called, not run: PROMOTED is what a caller (cmd_start, pull-after) reads after it.
  promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-7"}')" "" "plan pp: run its open phases" > "$SANDBOX/out" ||
    fail "promote failed: $(cat "$SANDBOX/out")"
  grep -qF 'queued game: gm-7' "$SANDBOX/out" || fail "no queued line: $(cat "$SANDBOX/out")"
  [ -z "$(qitem queued gm-7)" ] || fail "the plan row was queued as one item"
  f=$(qitem queued pp-p2)
  [ -n "$f" ] || fail "no chain item for P2"
  assert_equal "$(qfield "$f" plan) $(qfield "$f" phases) $(qfield "$f" from) $(qfield "$f" priority)" "$(realpath "$SANDBOX/pp.md") 2 auto:plan-row low"
  assert_equal "$PROMOTED" pp-p2
  assert_equal "$(plan_rows "$SANDBOX/pp.md")" gm-7
  grep -qF -- '- [/] plan pp' "$NOTES_FIXTURE/rows.game.agent" || fail "the plan row is not left started"
  # A row whose plan is gone is handed back with a failed verdict, never queued as one item for every phase.
  row game agent 'plan gone' '- [ ] plan gone: run its open phases <!-- id:gm-8 -->'
  board_row game agent gm-8 '[]' "$(jq -cn --arg d "$(plan_row_task "$SANDBOX/gone.md")" '[$d]')"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-8"}')" "" "plan gone: run its open phases"
  assert_failure
  assert_output --partial 'row un-started, recorded failed: its plan'
  [ -z "$(qitem queued gm-8)" ] || fail "a row whose plan is gone was queued as one item"
  grep -qF -- '- [ ] plan gone' "$NOTES_FIXTURE/rows.game.agent" || fail "a row whose plan is gone was left started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r '.key + " " + .verdict')" "gm-8 failed"
  # A plan row whose phases all landed has no item for the orphan pass to close it on: it goes back the same way.
  printf '# one\n\n## Phases\n\n- [ ] P1 one\n' > "$SANDBOX/one.md"
  agent-queue add --project game --from human --slug one-p1 "x" >/dev/null
  agent-queue move one-p1 done --status ok >/dev/null
  row game agent 'plan one' '- [ ] plan one: run its open phases <!-- id:gm-10 -->'
  board_row game agent gm-10 '[]' "$(jq -cn --arg d "$(plan_row_task "$SANDBOX/one.md")" '[$d]')"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-10"}')" "" "plan one: run its open phases"
  assert_failure
  assert_output --partial 'row un-started, recorded failed: every phase of'
  grep -qF -- '- [ ] plan one' "$NOTES_FIXTURE/rows.game.agent" || fail "an all-landed plan row was left started"
  [ -z "$(plan_rows "$SANDBOX/one.md")" ] || fail "an all-landed plan got a rows: line"
}

# lifecycle.md "Taking an epic on" (take_epic). NEGATIVE CONTROL: before ar-2977 the human's Start
# queued the epic row as one item, gm-20, whose one session held the whole epic.
@test "promote: an epic on the board path is never one item; the human's Start tags its s and m stories #requested" {
  epic_fixture gm-21:feat:s gm-22:fix:m gm-23:feat:l gm-25:design:s
  epic_take repeat > "$SANDBOX/out" || fail "promote failed: $(cat "$SANDBOX/out")"
  grep -qF 'took game epic gm-20: its stories dispatch leaf by leaf from the board, 2 tagged #requested; gm-23 need a plan' "$SANDBOX/out" ||
    fail "no took line: $(cat "$SANDBOX/out")"
  [ -z "$(qitem queued gm-20)" ] || fail "the epic was queued as one item"
  assert_equal "$PROMOTED" ""
  grep -qF -- '- [ ] epic(ui)' "$NOTES_FIXTURE/rows.game.human" || fail "the epic row was started"
  assert_equal "$(grep -c '#requested' "$NOTES_FIXTURE/rows.game.agent")" 2
  grep -F 'gm-23' "$NOTES_FIXTURE/rows.game.agent" | grep -qvF '#requested' || fail "the l story was tagged #requested"
  grep -F 'gm-25' "$NOTES_FIXTURE/rows.game.agent" | grep -qvF '#requested' || fail "a story whose kind does not dispatch was tagged #requested"
  # a take that is not the human's Start (a pull after its gate cleared) tags nothing
  epic_fixture gm-31:feat:s
  epic_take > "$SANDBOX/out" || fail "promote failed: $(cat "$SANDBOX/out")"
  ! grep -F 'gm-31' "$NOTES_FIXTURE/rows.game.agent" | grep -qF '#requested' || fail "a take that was not the human's Start tagged a story"
}

@test "promote: an epic with an open decide leaf, or no story and no plan, waits and takes nothing" {
  epic_fixture gm-21:feat:s gm-24:decide:s
  run epic_take repeat
  assert_failure
  assert_output --partial 'epic gm-20 waits on the human: open decide row gm-24'
  ! grep -qF '#requested' "$NOTES_FIXTURE/rows.game.agent" || fail "a story of a held epic was tagged"
  rm -f "$NOTES_FIXTURE/rows.game.agent"
  epic_fixture
  run epic_take repeat
  assert_failure
  assert_output --partial 'epic gm-20 has nothing to take'
  [ -z "$(ls "$AGENT_QUEUE_DIR"/queued/ 2>/dev/null)" ] || fail "something was queued: $(ls "$AGENT_QUEUE_DIR"/queued/)"
}

@test "promote: an epic whose only plan is superseded has nothing to take, not a plan to wait on (ar-3466)" {
  stub agent-ask 'echo other-session'
  epic_fixture
  printf '# ep\n\nSuperseded by #9\n\nepic: gm-20\n\n## Phases\n\n- [ ] P1 one\n' > "$PLAN_DIRS/old.md"
  run epic_take repeat
  assert_failure
  refute_output --partial 'waits on the human: its plan old.md'
}

@test "promote: an epic with an approved plan is queued as its chain once; an unapproved plan holds it" {
  stub agent-ask 'echo other-session'
  epic_fixture gm-21:feat:s
  printf '# ep\n\nepic: gm-20\n\n## Phases\n\n- [ ] P1 one\n' > "$PLAN_DIRS/wait.md"
  run epic_take repeat
  assert_failure
  assert_output --partial 'waits on the human: its plan wait.md has no approval in the last 30 days'
  rm "$PLAN_DIRS/wait.md"
  approved_plan ep gone-session "- [x] one\n- [ ] two"
  sed -i 's/^# Plan$/# Plan\n\nepic: gm-20/' "$SANDBOX/ep.md"
  mv "$SANDBOX/ep.md" "$PLAN_DIRS/ep.md"
  jq -c --arg p "$PLAN_DIRS/ep.md" '.plan = $p' "$PLAN_LEDGER" > "$SANDBOX/l" && mv "$SANDBOX/l" "$PLAN_LEDGER"
  epic_take repeat > "$SANDBOX/out" || fail "promote failed: $(cat "$SANDBOX/out")"
  grep -qF 'took game epic gm-20: the chain of ep.md' "$SANDBOX/out" || fail "no took line: $(cat "$SANDBOX/out")"
  f=$(qitem queued ep-p2)
  [ -n "$f" ] || fail "no chain item for P2: $(ls "$AGENT_QUEUE_DIR"/queued/)"
  assert_equal "$(qfield "$f" from) $(qfield "$f" priority)" "auto:epics low"
  [ -z "$(qitem queued gm-20)" ] || fail "the epic was queued as one item"
  grep -qF -- '- [ ] epic(ui)' "$NOTES_FIXTURE/rows.game.human" || fail "the epic row was started"
  ! grep -qF '#requested' "$NOTES_FIXTURE/rows.game.agent" || fail "the chain path tagged a board story"
  # taken again: its chain is in flight, so nothing is queued twice
  n=$(ls "$AGENT_QUEUE_DIR"/queued/ | wc -l)
  epic_take repeat > "$SANDBOX/out" || fail "a second take failed: $(cat "$SANDBOX/out")"
  assert_equal "$(ls "$AGENT_QUEUE_DIR"/queued/ | wc -l)" "$n"
  # a chain whose phases were filed on their gated board rows (agent-queue exit 5) is taken, never a failure
  stub agent-queue 'case "$1" in list) exit 0 ;; add) exit 5 ;; *) exit 1 ;; esac'
  epic_take repeat > "$SANDBOX/out" || fail "a held chain read as a failure: $(cat "$SANDBOX/out")"
  grep -qF 'took game epic gm-20: the chain of ep.md' "$SANDBOX/out" || fail "no took line for a held chain: $(cat "$SANDBOX/out")"
}

@test "run starts nothing when no account has room under its weekly pace" {
  game_ready
  acct main:pace
  refuses 'no account has room; main is the closest, 1 point over its weekly pace'
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

@test "starved names a board row gated on a cancelled ask, which no answer can release" {
  project game beta "$SANDBOX/repos/game"
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: dead1\nstatus: cancelled\nquestion: q?\n' > "$HOME/.agent/asks/game/dead1.md"
  printf 'id: live1\nstatus: pending\nquestion: q?\n' > "$HOME/.agent/asks/game/live1.md"
  # The queue holds no gated item (agent-queue add files it on its row), so a dead gate is a row's.
  row game agent gm-8 "- [ ] feat(game): kalshi p8 $T #ask/dead1 <!-- id:gm-8 -->"
  row game agent gm-9 "- [ ] feat(game): waits on the human $T #ask/live1 <!-- id:gm-9 -->"
  # A machine held by load still names the dead gate and fails.
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_failure
  assert_output --partial 'board rows gated on what can never clear:'
  assert_output --partial 'gm-8 (game, #ask/dead1: '
  refute_output --partial 'gm-9'
}

@test "starved names a board row gated #after a row that does not exist, and not one gated on an open row (ar-4017)" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] feat(game): the base $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] feat(game): waits on the base $T #after/gm-1 <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): waits on a row nobody filed $T #after/gm-404 <!-- id:gm-3 -->"
  row game agent gm-5 "- [x] feat(game): a row that was dropped $T <!-- id:gm-5 dropped: stale -->"
  row game agent gm-4 "- [ ] feat(game): waits on a dropped row $T #after/gm-5 <!-- id:gm-4 -->"
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_failure
  assert_output --partial 'board rows gated on what can never clear:'
  assert_output --partial 'gm-3 (game, #after/gm-404: after gm-404: no board row has that id)'
  assert_output --partial 'gm-4 (game, #after/gm-5: after gm-5: that row was dropped'
  refute_output --partial 'gm-2 ('
}

@test "run starts nothing when account usage cannot be read" {
  game_ready
  stub claude-acct 'exit 2'
  refuses 'account usage unreadable'
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

@test "a starved pool that names no repos holds every item" {
  game_ready
  findings "$(finding starved pool:unity)"
  refuses 'finding firing: gm-1 (starved pool:unity), every queue item waits'
}

@test "headroom counts what could start now against each limit" {
  two_items
  export DISPATCH_PER_PASS=1 DISPATCH_TARGET_AWAY=6 DISPATCH_STARVED_MIN=45
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.could_start, .per_pass_limited, .runnable, .slots_free, .held] | @tsv' <<<"$output")" $'2\ttrue\t2\t6\t'
  # The dispatch step's bound in the pipeline snapshot; the hold's start is read live from `stopped`, never here
  assert_equal "$(jq -c '[.starved_min, has("held_since")]' <<<"$output")" '[45,false]'
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
    printf -- '- %s started s3 on agents (hand) for app: queue item c\n' "$(date -d '-30 min' '+%Y-%m-%d %H:%M')"; } > "$FLEET_DISPATCH_DIR/log.md"
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

@test "headroom is 0 and names what holds: a gate, or every run unit used" {
  two_items
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .could_start <<<"$output")" 0
  assert_equal "$(jq -r .held <<<"$output")" "load 99.0 on $(nproc) cores is over the 0.7 pace"
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  export DISPATCH_TARGET_AWAY=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" $'0\tpace target: 0 live sessions, the away target is 0'
}

# 2026-11-17 (ar-2851): the 0.9 pace held 150+ runnable items for an hour on a load average a spike
# and disk waits held up, with the CPU 66% idle. The pace reads the lower of load and the cores busy now.
@test "the load pace judges the cores busy now: a high load average with an idle CPU holds no start, a busy CPU does" {
  two_items
  local c; c=$(nproc)
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  echo "$(( $(date +%s) - 60 )) 0 0" > "$DISPATCH_CPU_SAMPLES"
  echo 'cpu  60 20 20 900 0 0 0 0 0 0' > "$DISPATCH_PROC_STAT"   # 100 of 1000 jiffies busy
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  local busy; busy=$(awk -v c="$c" 'BEGIN { printf "%.1f", c * 0.1 }')
  jq -e --argjson b "$busy" '.could_start == 2 and .held == null and .load == $b and .load1 == 99 and .cpu_busy == $b' <<<"$output" >/dev/null ||
    fail "the pace did not read the $busy cores busy: $output"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --regexp "\(1-min load 99(\.0)?, [0-9.]+ cores busy; the pace reads the lower\)"
  # Every core busy: the CPU is at the pace too, so load holds and the reason names both readings.
  echo 'cpu  900 50 50 0 0 0 0 0 0 0' > "$DISPATCH_PROC_STAT"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" "$(printf '0\tload %s.0 (1-min load 99.0, %s.0 cores busy; the pace reads the lower) on %s cores is over the 0.7 pace' "$c" "$c" "$c")"
  # Waiting on its disks is busy too: a new session's git and installs would fight for them.
  echo 'cpu  60 20 20 100 800 0 0 0 0 0' > "$DISPATCH_PROC_STAT"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .could_start <<<"$output")" 0
}

@test "the load pace reads load average alone when no CPU sample is from the last minutes, or one is too young to read" {
  two_items
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  echo 'cpu  60 20 20 900 0 0 0 0 0 0' > "$DISPATCH_PROC_STAT"
  local now; now=$(date +%s)
  for t in $(( now - 400 )) $(( now - 5 )); do
    echo "$t 0 0" > "$DISPATCH_CPU_SAMPLES"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
    jq -e '.could_start == 0 and .cpu_busy == null' <<<"$output" >/dev/null || fail "a sample at $t read as busy: $output"
    assert_equal "$(jq -r .held <<<"$output")" "load 99.0 on $(nproc) cores is over the 0.7 pace"
  done
  # The newest sample old enough wins over an older one, and a younger one is passed over.
  printf '%s 0 0\n%s 50 500\n%s 99 990\n' $(( now - 200 )) $(( now - 60 )) $(( now - 5 )) > "$DISPATCH_CPU_SAMPLES"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  jq -e --argjson b "$(awk -v c="$(nproc)" 'BEGIN { printf "%.1f", c * 50 / 500 }')" '.cpu_busy == $b' <<<"$output" >/dev/null ||
    fail "the pace did not read the sample of 60 s ago: $output"
}

@test "the minute record keeps the CPU samples of the last five minutes for the load pace; a worker's keeps none" {
  local now; now=$(date +%s)
  printf '%s 0 0\n' $(( now - 400 )) $(( now - 200 )) $(( now - 100 )) > "$DISPATCH_CPU_SAMPLES"
  echo 'cpu  60 20 20 800 100 0 0 0 0 0' > "$DISPATCH_PROC_STAT"
  FLEET_LEASE_STUB_RC=1 run "$REPO_ROOT/.local/bin/fleet-dispatch" record
  assert_equal "$(wc -l < "$DISPATCH_CPU_SAMPLES")" 3
  assert_equal "$(head -n 1 "$DISPATCH_CPU_SAMPLES")" "$(( now - 200 )) 0 0"
  assert_equal "$(tail -n 1 "$DISPATCH_CPU_SAMPLES" | cut -d' ' -f2-)" '200 1000'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" record --here
  assert_equal "$(wc -l < "$DISPATCH_CPU_SAMPLES")" 3
}

@test "headroom counts live sessions started by hand apart from run slots, and names the held kind" {
  two_items
  started_item run-one lab:lab-run-1 run
  started_item hand-one lab:lab-hand-1 hand
  printf 'lab-run-1\nlab-hand-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  export DISPATCH_TARGET_AWAY=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .live_hand, .held_kind] | @tsv' <<<"$output")" $'1\t1\tslots'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'run units: 1/1 used, 0 free (heavy 2, light 1), 1 more started by hand'
  export DISPATCH_TARGET_AWAY=6
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .held_kind <<<"$output")" load
  # the load the gate judged: the pace reading plus the recent starts, never the reading alone
  assert_equal "$(jq -r '[.load_at_hold == ((.load + .load_pending) * 100 | round / 100), .load_at_hold > .load_cap] | @tsv' <<<"$output")" $'true\ttrue'
  echo '0.1 0.1 0.1 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.held, .held_kind, .load_at_hold] | @tsv' <<<"$output")" $'fleet-assess says HOLD\tassess\t'
}

@test "a run from a shell reads the DISPATCH_* tuning from the agentctl conf; the environment wins" {
  dispatch_conf NAME=fleet-dispatch DISPATCH_TARGET_AWAY=24 "DISPATCH_MAX_LOAD='1.5'" DISPATCH_PER_PASS=3
  two_items
  run env -u DISPATCH_TARGET_AWAY -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.max_live, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'24\t3\t1.5'
  DISPATCH_TARGET_AWAY=2 run env -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .max_live <<<"$output")" 2
}

@test "a conf that lost a tuning key, or no conf, exits 78 naming each missing key; the fixture conf runs" {
  two_items
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  sed 's/^DISPATCH_RED_FLOOR=/DISPATCH_RED_FLOR=/' "$REPO_ROOT/tests/fixtures/fleet-dispatch.conf" > "$DISPATCH_CONF"
  run env -u DISPATCH_RED_FLOOR "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_failure 78
  assert_output --partial "$DISPATCH_CONF does not set DISPATCH_RED_FLOOR (each a bare KEY=VALUE line, no trailing comment); that conf is the one home"
  run env -u DISPATCH_PER_PASS DISPATCH_CONF="$SANDBOX/none.conf" "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_failure 78
  assert_output --partial "$SANDBOX/none.conf does not set DISPATCH_PER_PASS DISPATCH_ORPHAN_HOURS"
}

@test "a worker with no conf still answers the verbs it runs for the dispatcher; restore without --here still exits 78" {
  run env -u DISPATCH_PER_PASS DISPATCH_CONF="$SANDBOX/none.conf" "$REPO_ROOT/.local/bin/fleet-dispatch" kit
  assert_success
  refute_output --regexp 'does not set|unbound'
  run env -u DISPATCH_PER_PASS DISPATCH_CONF="$SANDBOX/none.conf" DISPATCH_HARNESSES="$SANDBOX/none.json" "$REPO_ROOT/.local/bin/fleet-dispatch" harness-ready nim
  assert_success
  assert_output "nim: no harness map at $SANDBOX/none.json"
  run env -u DISPATCH_PER_PASS DISPATCH_CONF="$SANDBOX/none.conf" "$REPO_ROOT/.local/bin/fleet-dispatch" restore --dry-run
  assert_failure 78
  assert_output --partial "does not set DISPATCH_PER_PASS"
}

@test "the fixture conf sets exactly DISPATCH_CONF_KEYS, and the code holds no default for any of them" {
  [ "$(code_keys | wc -l)" -gt 40 ]
  assert_equal "$(conf_keys "$REPO_ROOT/tests/fixtures/fleet-dispatch.conf")" "$(code_keys)"
  run grep -nE "^: \"\\\$\\{($(code_keys | paste -sd'|')):?=" "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_output ''
}

@test "the private agentctl conf sets every one of DISPATCH_CONF_KEYS, so the live fleet never exits 78 on a key" {
  private_or_skip "the conf's keys are"
  conf="$PRIVATE/.config/agentctl/agents/fleet-dispatch.conf"
  [ -f "$conf" ]
  # Every key, not exactly them: the private conf lands first, so it may carry a key the public code
  # does not read yet.
  run comm -13 <(conf_keys "$conf") <(code_keys)
  assert_output ''
}

@test "the machine-mode level scales the start limits where they are read; mid is the conf's own" {
  dispatch_conf NAME=fleet-dispatch DISPATCH_TARGET_AWAY=24 "DISPATCH_MAX_LOAD='1.5'" DISPATCH_PER_PASS=3
  two_items
  run env -u DISPATCH_TARGET_AWAY -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.level, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'mid\t3\t1.5'
  mkdir -p "$HOME/.agent"; echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"
  run env -u DISPATCH_TARGET_AWAY -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  # Rounded: 1.65 x 28 cores / 28 reads 1.6500000000000001 in jq.
  assert_equal "$(jq -r '[.level, .per_pass, (.load_cap / '"$(nproc)"' * 100 | round / 100), .max_live] | @tsv' <<<"$output")" $'high\t6\t1.65\t24'
  # The exported DISPATCH_* a child reads stay the conf's.
  export DISPATCH_PER_PASS=3
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_equal "$PER_PASS $DISPATCH_PER_PASS" "6 3"
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

@test "preempt: a parked runner session holds no run unit" {
  five_of_six_units
  assert_equal "$(live_units)" 5
  ledger game-agent-h1 park
  assert_equal "$(live_units)" 3
  rm "$HOME/.agent/parked/game-agent-h1"; mkdir -p "$HOME/.agent/parked"; : > "$HOME/.agent/parked/game-agent-l1:2"
  assert_equal "$(live_units)" 4
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

@test "a live hand launch or restore holds none of the runner's slots; its own sessions do" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  started_item restored lab:restored resume
  started_item by-hand lab:by-hand hand
  # 2026-11-18: a session's own --running record, which writes no origin, is the human's: it holds
  # no slot.
  started_item legacy lab:legacy
  printf 'restored\nby-hand\nlegacy\ngame-agent-9\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output ''
  run live_hand
  assert_equal "$(wc -l <<<"$output")" 3
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'

  started_item mine lab:game-agent-9 run wilds
  run live_runs
  assert_output 'game/wilds light'
}

@test "tier3 gate: a tier-3 agent-runtime row is promoted as a tier3 item that merges behind the red-fix gate, started on the board, no session" {
  pr_lane_ready
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3 #high'
  pr_lane_verdict 'wt done never reaps' wt

  fill
  assert_success
  assert_output --partial 'queued agent-runtime: gm-1'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "no tier3 item"
  assert_equal "$(qfield "$f" tags) $(qfield "$f" priority) $(qfield "$f" area)" 'tier3 high wt'
  assert_equal "$(qfield "$f" from)" 'board:agent-runtime:gm-1'
  [ "$(state_of 'wt done never reaps')" = '- [/]' ] || fail "row not started"
  run item_brief "$(agent-queue show gm-1 --json)"
  assert_output --partial 'wt done never reaps (worktree.sh:213)'
  assert_output --partial 'This is tier 3 (harness or tooling), and it merges only behind the red-fix gate'
  refute_output --partial -- '--pr-only'
  assert_not_called 'wt new'
  assert_not_called 'judge called'
}

@test "tier3 gate: a playground fix(ci) row is queued as a merging tier3 item; a release cut or an auth row stays with the human" {
  mkdir -p "$SANDBOX/repos/pg"
  project unity-core-playground beta "$SANDBOX/repos/pg"
  row unity-core-playground agent 'retry probe' '- [ ] fix(ci): retry the flaky runner probe #tier/3'
  row unity-core-playground agent 'cut it' '- [ ] chore(build): cut the release for v2 #tier/3'
  row unity-core-playground agent 'oauth' '- [ ] fix(build): refresh the oauth token on the runners #tier/3'
  pr_lane_verdict 'retry probe' ci true S unity-core-playground
  pr_lane_verdict 'cut it' release true S unity-core-playground
  pr_lane_verdict 'oauth' runners true S unity-core-playground

  run t3_rows ''
  assert_equal "$(jq -r '"\(.project) \(.key)"' <<<"$output" | paste -sd,)" 'unity-core-playground retry probe'
  DISPATCH_PER_PASS=5 fill
  assert_success
  assert_output --partial 'queued unity-core-playground:'
  run agent-queue list --json --state queued
  assert_equal "$(jq -r '"\(.project) \(.tags)"' <<<"$output" | paste -sd,)" 'unity-core-playground tier3'
  run item_brief "$(agent-queue list --json --state queued | jq -c 'select(.project == "unity-core-playground")')"
  assert_output --partial 'fix(ci): retry the flaky runner probe'
  assert_output --partial 'agent-land refuses a tier-3 PR without that line'
  refute_output --partial -- '--pr-only'
}

@test "tier3 gate: auth, migration and money word forms, every row of an off project, and an untagged gated row stay out; a tagged gated row is taken" {
  export DISPATCH_OFF_PROJECTS=finance
  mkdir -p "$SANDBOX/repos/pg" "$SANDBOX/repos/fin"
  project unity-core-playground beta "$SANDBOX/repos/pg"
  project finance beta "$SANDBOX/repos/fin"
  row unity-core-playground agent 'authn' '- [ ] fix(build): rotate the authentication keys on the runners #tier/3'
  row unity-core-playground agent 'schema' '- [ ] chore(ci): add a schema migration step #tier/3'
  row unity-core-playground agent 'pay' '- [ ] fix(ci): stub the payments test server #tier/3'
  row unity-core-playground agent 'skill' '- [ ] chore(ci): skill authoring lint step #tier/3'
  row finance agent 'recon' '- [ ] fix(ci): reconcile the March statement #tier/3'
  row unity-core-playground agent pg-1 '- [ ] fix(ci): the probe first <!-- id:pg-1 -->'
  row unity-core-playground agent pg-2 '- [ ] feat(tools): then its retry #after/pg-1 <!-- id:pg-2 -->'
  row unity-core-playground agent pg-3 '- [ ] feat(tools): then its timeout #tier/3 #after/pg-1 <!-- id:pg-3 -->'
  notes ptask unity-core-playground --agent done pg-1

  run t3_rows ''
  assert_equal "$(jq -r '"\(.key) \(.gated)"' <<<"$output" | sort | paste -sd,)" 'pg-3 true,skill null'
  run off_project finance
  assert_output 'no worker covers finance: it is on DISPATCH_OFF_PROJECTS, so its rows stay with the human'
}

@test "tier3 gate: a tier-3 row is never a day pick, even with a dispatch verdict: the tier-3 gate queues it" {
  pr_lane_ready
  echo '{"board": {"max_tier": 9, "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  row agent-runtime agent 'add the timer panel' '- [ ] feat(timer): add a timer panel #tier/3'
  verdict agent-runtime agent 'add the timer panel' dispatch S 3 timer
  pr_lane_verdict 'add the timer panel' timer

  run cmd_candidates
  assert_output ''
  run picks "$(all_open)" 5
  assert_output ''
  fill
  assert_equal "$(pr_lane_keys)" 'add the timer panel'
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
}
