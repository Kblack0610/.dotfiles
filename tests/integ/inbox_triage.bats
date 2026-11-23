#!/usr/bin/env bats
# agentctl-inbox-triage: outbox and inbox lines become typed rows, through `notes outbox move`
# and `notes ptask file` only.
#
# The real notes against a sandbox vault: the triager's whole job is the CLI's refusals and
# writes, which a stub would only echo back. The CI rust job builds notes and sets NOTES_BIN;
# without it every case skips, so a stale binary in target/ never fails the Stop tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  TRIAGE="$REPO_ROOT/.local/bin/agentctl-inbox-triage"
  PROJ="$HOME/.notes/lab/projects/current"
  SHEET="$PROJ/scratch/README.md"
  mkdir -p "$PROJ/scratch" "$PROJ/other" "$HOME/.config/notes"
  : >"$PROJ/scratch/summary.md"
  : >"$PROJ/other/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# other' '' 'Version: v0.1.0' '' '## Inbox' '' '## Tasks' '' >"$PROJ/other/README.md"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  echo '{"trackers": {"scratch": {"code": "sc"}, "other": {"code": "ot"}}}' >"$PROJECT_MAP_FILE"
  export INBOX_TRIAGE_CMD=model-stub INBOX_BACKLOG_CMD=model-stub
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\ncat > "$NOTES_FIXTURE/prompt.txt"\ncat "$NOTES_FIXTURE/model.out" 2>/dev/null\n' >"$SANDBOX/bin/model-stub"
  chmod +x "$SANDBOX/bin/model-stub"
  # The planner's start, recorded: no unit ever starts from a test.
  printf '#!/usr/bin/env bash\necho "$*" >> "$NOTES_FIXTURE/systemctl.log"\n' >"$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/systemctl"
  # The inbox page's triage score: judge-eval's cell, canned in judge.json; none written, no score.
  printf '#!/usr/bin/env bash\n[ "$*" = "inbox-triage --json" ] && cat "$NOTES_FIXTURE/judge.json" 2>/dev/null\n' >"$SANDBOX/bin/judge-eval"
  chmod +x "$SANDBOX/bin/judge-eval"
  systems ''
}

# systems <id:aliases>...: the system list `project-stage-check scratch --list` prints (TSV, or
# --json), the vocabulary the triager and `notes ptask` read; none given, it knows no project,
# so a project-stage-check on the host never decides a test's rows.
systems() {
  local s id al tsv="" json=""
  for s in "$@"; do
    [ -n "$s" ] || continue
    id="${s%%:*}" al="${s#*:}"; [ "$al" = "$s" ] && al=""
    tsv+="$id"$'\t'doc$'\t'"$al"$'\t'"the $id"$'\n'
    json+="${json:+,}{\"id\":\"$id\",\"source\":\"doc\",\"aliases\":$(jq -cn --arg a "$al" '$a | split(",") | map(select(. != ""))'),\"is\":\"the $id\"}"
  done
  printf '%s' "$tsv" >"$NOTES_FIXTURE/systems.tsv"
  printf '[%s]' "$json" >"$NOTES_FIXTURE/systems.json"
  cat >"$SANDBOX/bin/project-stage-check" <<'STUB'
#!/usr/bin/env bash
[ "$1" = scratch ] && [ "$2" = --list ] && [ -s "$NOTES_FIXTURE/systems.tsv" ] || { echo "unknown project $1" >&2; exit 2; }
if [ "${3:-}" = --json ]; then cat "$NOTES_FIXTURE/systems.json"; else cat "$NOTES_FIXTURE/systems.tsv"; fi
STUB
  chmod +x "$SANDBOX/bin/project-stage-check"
}

# sheet <inbox lines> <task lines>: scratch's sheet.
sheet() { printf '# scratch\n\nVersion: v0.1.0\n\n## Inbox\n%b\n## Tasks\n%b\n' "$1" "$2" >"$SHEET"; }
# answer <json line>...: what the model replies.
answer() { { echo INBOX-TRIAGE-START; printf '%s\n' "$@"; echo INBOX-TRIAGE-END; } >"$NOTES_FIXTURE/model.out"; }
outbox() { printf '# Outbox\n\n## Outbox\n%b' "$1" >"$HOME/.notes/outbox.md"; }
inbox() { sed -n '/^## Inbox/,/^## Tasks/p' "$SHEET"; }
tasks() { sed -n '/^## Tasks/,$p' "$SHEET"; }

@test "a notes with no row types asks no model, keeps the line and says why" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays late #high #size/s"]}'
  # Replace the link, never write through it: it points at the built binary.
  rm -f "$SANDBOX/bin/notes"
  printf '#!/usr/bin/env bash\n[ "$1" = row ] && exit 2\nexec "%s" "$@"\n' "$NOTES_BIN" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$TRIAGE"
  assert_output --partial 'notes row types failed'
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "the model was asked with no type list"
  run inbox
  assert_output --partial 'gun sound'
}

@test "end to end: a raw line is filed as one typed row with an id, its words as the detail" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays off since the top-down patch #high #size/s"]}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 1, left 0, refused 0'
  run inbox
  refute_output --partial 'gun sound'
  run tasks
  assert_output --regexp '- \[ \] fix\(audio\): the gun sound plays off since the top-down patch .*#high.*id:sc-1.*filed:[0-9]{4}-[0-9]{2}-[0-9]{2}'
  assert_output --partial '  was: the gun sound is off since the top-down patch'
  [ "$(grep -c 'fix(audio)' "$SHEET")" = 1 ] || fail "filed more than once: $(cat "$SHEET")"
  grep -qx '1. \[scratch\] the gun sound is off since the top-down patch' "$NOTES_FIXTURE/prompt.txt" || fail "the line never reached the model"
  grep -qF "type is one of $("$NOTES_BIN" row types); a bug is fix." "$NOTES_FIXTURE/prompt.txt" || fail "the row types never reached the model"
  # The --priority pass's rubric, so the row is filed with the priority that pass would give it (ar-1615).
  grep -q "red on main" "$NOTES_FIXTURE/prompt.txt" || fail "the route call lost the priority rubric"
  # An agent-lane row is #requested, so the rubric makes it high; filed without one, the --priority pass re-tags it (ar-1633).
  grep -q 'lane agent is filed #requested, so the person asked for it: it is #high' "$NOTES_FIXTURE/prompt.txt" || fail "the route call lost the agent-lane priority"
  # A row names the file it changes, so the trainee floor can take it (fleet-dispatch trainee-pool).
  grep -q 'Never add or guess one the words do not name' "$NOTES_FIXTURE/prompt.txt" || fail "the route call lost the file rule"
  [ -f "$HOME/.local/state/agentctl/inbox-triage/last-outcome" ] || fail "no proof published"
  grep -q WORKED "$HOME/.local/state/agentctl/inbox-triage/last-outcome"
  [ ! -e "$NOTES_FIXTURE/systemctl.log" ] || fail "the planner started with no #plan row"
}

@test "a failed model call keeps its stderr in the log and its own reason in the outcome" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  printf '#!/usr/bin/env bash\necho "You have hit your weekly limit - resets 7pm"\necho "harness: claude exited 1" >&2\nexit 1\n' >"$SANDBOX/bin/model-stub"
  run "$TRIAGE"
  assert_failure
  assert_output --partial 'harness: claude exited 1'
  assert_output --partial 'model call failed: You have hit your weekly limit - resets 7pm'
  st="$HOME/.local/state/agentctl/inbox-triage"
  grep -qx FAILED "$st/last-outcome"
  grep -q 'outcome=FAILED .*model call failed: You have hit your weekly limit - resets 7pm' "$st/activity.log"
  grep -q '"action":"sweep-stopped".*"why":"model call failed: You have hit your weekly limit - resets 7pm"' "$HOME/.local/state/notes/ingest.jsonl" || fail "$(cat "$HOME/.local/state/notes/ingest.jsonl")"
  inbox | grep -q 'the gun sound is off'
}

@test "a failed board read names notes' own error in the log and the outcome" {
  # 2026-11-10: the board read failed for 15 hours and the log said only "notes board --json
  # failed", because notes' stderr went to /dev/null.
  sheet '- the gun sound is off since the top-down patch\n' ''
  rm -f "$SANDBOX/bin/notes"
  printf '#!/usr/bin/env bash\n[ "$*" = "board --json" ] && { echo "error: sheet other: bad heading" >&2; exit 2; }\nexec "%s" "$@"\n' "$NOTES_BIN" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$TRIAGE"
  assert_failure
  assert_output --partial 'notes board --json failed (exit 2): error: sheet other: bad heading'
  grep -q 'outcome=FAILED .*notes board --json failed (exit 2): error: sheet other: bad heading' "$HOME/.local/state/agentctl/inbox-triage/activity.log"
  inbox | grep -q 'the gun sound is off'
}

@test "a budget stop ends the sweep BLOCKED with exit 75: one call, no refusal, the lines wait" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\nexit 75\n' >"$SANDBOX/bin/model-stub"
  INBOX_TRIAGE_PASSES=3 run "$TRIAGE"
  assert_failure 75
  assert_output --partial 'route: stopped at its budget'
  assert_output --partial 'left 1, refused 0'
  refute_output --partial 'model call failed'
  [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 1 ] || fail "model calls: $(wc -l < "$NOTES_FIXTURE/model.log")"
  st="$HOME/.local/state/agentctl/inbox-triage"
  grep -qx BLOCKED "$st/last-outcome"
  grep -q 'outcome=BLOCKED budget: .*why: stopped at its budget' "$st/activity.log" || fail "$(cat "$st/activity.log")"
  grep -q '"action":"sweep-stopped"' "$HOME/.local/state/notes/ingest.jsonl" || fail "the stopped sweep was not recorded"
  inbox | grep -q 'the gun sound is off'
}

@test "--backlog: a budget stop ends the pass BLOCKED with exit 75 after one call, and any other exit stays FAILED" {
  sheet '' '- [ ] fix(ui): the menu <!-- id:sc-1 -->\n'
  printf '%s\n' '- [ ] fix(ui): the other menu <!-- id:ot-1 -->' >>"$PROJ/other/README.md"
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\nexit 75\n' >"$SANDBOX/bin/model-stub"
  run "$TRIAGE" --backlog
  assert_failure 75
  [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 1 ] || fail "model calls: $(wc -l < "$NOTES_FIXTURE/model.log")"
  st="$HOME/.local/state/agentctl/inbox-backlog"
  grep -qx BLOCKED "$st/last-outcome"
  grep -q 'outcome=BLOCKED budget: backlog: ' "$st/activity.log" || fail "$(cat "$st/activity.log")"
  # negative control: an exit that is not the budget's is still a failed pass
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/model-stub"
  run "$TRIAGE" --backlog
  assert_failure 1
  grep -qx FAILED "$st/last-outcome"
}

@test "--backlog: its calls go to the inbox-backlog agent, never the intake sweep's, so a cleanup cannot spend intake's budget" {
  sheet '' '- [ ] fix(ui): the menu <!-- id:sc-1 -->\n'
  printf '#!/usr/bin/env bash\necho intake >> "$NOTES_FIXTURE/model.log"\nexit 1\n' >"$SANDBOX/bin/intake-stub"
  chmod +x "$SANDBOX/bin/intake-stub"
  printf '%s\n' INBOX-TRIAGE-START '{"n": 1, "action": "keep"}' INBOX-TRIAGE-END >"$NOTES_FIXTURE/model.out"
  INBOX_TRIAGE_CMD=intake-stub run "$TRIAGE" --backlog
  assert_success
  assert_equal "$(cat "$NOTES_FIXTURE/model.log")" called
  grep -qx NOOP "$HOME/.local/state/agentctl/inbox-backlog/last-outcome"
  [ ! -e "$HOME/.local/state/agentctl/inbox-triage/last-outcome" ] || fail "the backlog pass reported as the intake sweep"
  # negative control: a runner that names itself keeps its own name
  AGENTCTL_NAME=inbox-triage run "$TRIAGE" --backlog
  assert_success
  grep -qx NOOP "$HOME/.local/state/agentctl/inbox-triage/last-outcome"
}

@test "a reply with no answer block names that reason in the outcome" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  echo 'I could not decide.' >"$NOTES_FIXTURE/model.out"
  run "$TRIAGE"
  assert_failure
  st="$HOME/.local/state/agentctl/inbox-triage"
  grep -qx FAILED "$st/last-outcome"
  grep -q 'outcome=FAILED .*why: route: the model returned no answer block$' "$st/activity.log" \
    || fail "$(cat "$st/activity.log")"
}

@test "a call stopped at its per-call cap halves the batch and the next pass asks again at that size" {
  sheet '- one\n- two\n- three\n- four\n- five\n' ''
  answer '{"n": 1, "action": "skip", "why": "a note"}' '{"n": 2, "action": "skip", "why": "a note"}'
  # Capped (calls.sh's CALLS_RC_CAPPED) on any call of more than two lines.
  printf '%s\n' '#!/usr/bin/env bash' 'echo called >> "$NOTES_FIXTURE/model.log"' 'cat > "$NOTES_FIXTURE/prompt.txt"' \
    'if [ "$(grep -cE "^[0-9]+\. \[" "$NOTES_FIXTURE/prompt.txt")" -gt 2 ]; then exit 76; fi' \
    'cat "$NOTES_FIXTURE/model.out"' >"$SANDBOX/bin/model-stub"
  INBOX_TRIAGE_MAX=8 INBOX_TRIAGE_PASSES=2 run "$TRIAGE"
  assert_success
  assert_output --partial 'route: the call stopped at its per-call cap with 5 items; the next carries 2'
  [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 2 ] || fail "model calls: $(wc -l < "$NOTES_FIXTURE/model.log")"
  [ "$(grep -cE '^[0-9]+\. \[' "$NOTES_FIXTURE/prompt.txt")" = 2 ] || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  # The clean full call of two grew it a quarter, rounded up.
  assert_output --partial 'batch 3'
}

@test "a failed call that is not a cap leaves the batch at its max (negative control)" {
  sheet '- one\n- two\n- three\n' ''
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\nexit 1\n' >"$SANDBOX/bin/model-stub"
  INBOX_TRIAGE_MAX=8 run "$TRIAGE"
  assert_failure
  assert_output --partial 'batch 8'
  [ ! -e "$HOME/.local/state/agentctl/inbox-triage/batch" ] || fail "a plain failure resized the batch"
}

@test "end to end: a typed line is filed word for word, a typed row is left alone, and no model runs" {
  sheet '- [ ] chore(build): drop the old cache #low\n' '- [ ] fix(ui): the menu flickers #high <!-- id:sc-4 -->\n'
  run "$TRIAGE"
  assert_success
  [ ! -f "$NOTES_FIXTURE/model.log" ] || fail "the model ran for a typed line"
  run tasks
  assert_output --partial '- [ ] fix(ui): the menu flickers #high <!-- id:sc-4 -->'
  assert_output --regexp 'chore\(build\): drop the old cache .*#low.*id:sc-5'
  refute_output --partial 'was:'
  run inbox
  refute_output --partial 'old cache'
}

@test "a pasted list splits into one line per ask, each routes alone, and the heading rides on each with no model" {
  outbox '- [ ] the game asks #p:scratch\n    - [ ] chore(build): one #low\n    - [ ] chore(build): two #low #p:other\n'
  run "$TRIAGE"
  assert_success
  [ ! -f "$NOTES_FIXTURE/model.log" ] || fail "the model ran for typed lines"
  run tasks
  assert_output --partial 'chore(build): one'
  assert_output --partial 'under: the game asks'
  refute_output --partial 'two'
  run grep -c 'chore(build): two' "$PROJ/other/README.md"
  assert_output 1
  run grep -c '"action":"split"' "$HOME/.local/state/notes/ingest.jsonl"
  assert_output 1
}

@test "a block indented as a whole in an inbox the board counts as empty is read, and a dry run writes nothing" {
  sheet '    - [ ] chore(build): one #low\n    - [ ] chore(build): two #low\n' ''
  before="$(cat "$SHEET")"
  run "$TRIAGE" --dry-run
  assert_success
  assert_equal "$(cat "$SHEET")" "$before"
  run "$TRIAGE"
  assert_success
  run tasks
  assert_output --partial 'chore(build): one'
  assert_output --partial 'chore(build): two'
}

@test "a list on a profile with automation = false is left exactly as written" {
  printf '[profile.gig]\nroot = "~/.notes/gig"\nautomation = false\n' >>"$HOME/.config/notes/config.toml"
  G="$HOME/.notes/gig/projects/current/hands-off"
  mkdir -p "$G"
  : >"$G/summary.md"
  printf '# hands-off\n\nVersion: v0.1.0\n\n## Inbox\n- [ ] heading\n  - [ ] one\n  - [ ] two\n\n## Tasks\n' >"$G/README.md"
  before="$(cat "$G/README.md")"
  run notes board --json
  assert_output --partial 'hands-off'
  run "$TRIAGE"
  assert_success
  assert_equal "$(cat "$G/README.md")" "$before"
}

@test "a list under a typed line stays one item" {
  sheet '- [ ] chore(build): one job #low\n  - [ ] step one\n  - [ ] step two\n' ''
  run "$TRIAGE"
  assert_success
  [ ! -f "$NOTES_FIXTURE/model.log" ] || fail "the model ran for a typed line"
  [ "$(tasks | grep -c '^- \[ \] chore')" = 1 ] || fail "$(tasks)"
  # the steps are the row's brief: stored escaped, so none is a row of its own
  run tasks
  assert_output --partial '  - \[ ] step two'
  run notes board --json
  [ "$(jq '[.rows[] | select(.text | test("step (one|two)"))] | length' <<<"$output")" = 0 ] || fail "a step is a board row: $output"
}

@test "the lane rule names the projects dispatch covers (fleet-dispatch covered), and only when it covers some" {
  sheet '- the gun sound is off\n' ''
  answer '{"n": 1, "action": "skip", "why": "test"}'
  # A stub, so neither half reads the host's own fleet-dispatch: first it covers nothing.
  printf '#!/usr/bin/env bash\n' >"$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  run "$TRIAGE"
  refute_output --partial 'failed'
  run grep -c 'agents do the work unattended' "$NOTES_FIXTURE/prompt.txt"
  assert_output 0
  printf '#!/usr/bin/env bash\n[ "$1" = covered ] && printf "scratch\\nother\\n"\n' >"$SANDBOX/bin/fleet-dispatch"
  rm -f "$HOME/.local/state/notes/ingest.jsonl"
  run "$TRIAGE"
  run grep -o 'lane is agent unless a step needs a person.*: scratch, other\.' "$NOTES_FIXTURE/prompt.txt"
  assert_success
}

# ar-4018: Needs you holds only what the human can do, and minting a credential for a service we run is an agent's job (Auth-State Safety, fleet-asks).
@test "the credential rule sends a mint for a service we run to the agent lane, and keeps an outside account with the person" {
  sheet '- mint the grafana api key into sops\n' ''
  answer '{"n": 1, "action": "skip", "why": "test"}'
  run "$TRIAGE"
  refute_output --partial 'failed'
  run grep -c 'A line that asks for a credential, token or key for a service we run' "$NOTES_FIXTURE/prompt.txt"
  assert_output 1
  run grep -o 'only an outside account (GitHub, a store, a broker, a SaaS) or the persons own login stays lane human' "$NOTES_FIXTURE/prompt.txt"
  assert_success
}

@test "a skipped line, an untyped row and a row the grammar flags all stay in the inbox" {
  sheet '- maybe the boss is too easy?\n- the save button\n- the jump is floaty\n' ''
  answer '{"n": 1, "action": "skip"}' '{"n": 2, "action": "file", "rows": ["make the save button work"]}' \
    '{"n": 3, "action": "file", "rows": ["fix(move): the jump is floaty #medium"]}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 0, left 1, refused 2'
  run inbox
  assert_output --partial '- maybe the boss is too easy?'
  assert_output --partial '- the save button'
  assert_output --partial '- the jump is floaty'
  run tasks
  refute_output --partial 'save button'
  refute_output --partial 'floaty'
  # recorded as left and refused, so the next sweep sends nothing until the words change
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 0, left 0, refused 0'
  [ "$(wc -l <"$NOTES_FIXTURE/model.log")" = 1 ] || fail "the model was asked again"
  run jq -r '.action + " " + .text' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'left maybe the boss is too easy?'
  assert_line 'refused the save button'
  assert_line 'refused the jump is floaty'
}

@test "a filed want is stamped #requested by the writer on the agent board, and its channel is recorded" {
  sheet '- the gun sound is off\n- the menu is slow\n' ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays late #high #size/s"], "lane": "agent", "why": "names the gun"}' \
    '{"n": 2, "action": "file", "rows": ["fix(ui): the menu is slow #high #size/s"]}'
  run env -u AGENT_QUEUE_ITEM -u CLAUDE_CODE_SESSION_ID AGENTCTL_NAME=inbox-triage "$TRIAGE"
  assert_success
  # Each filing names its writer and how it was decided; a sweep that handled lines says so.
  run jq -r 'select(.action == "filed" or .action == "sweep") | [.action, .by, .why] | join(" | ")' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'filed | inbox-triage | model: names the gun'
  assert_line 'filed | inbox-triage | model: no why'
  assert_line --regexp '^sweep \| inbox-triage \| moved 0 from the outbox, filed 2, left 0, refused 0'
  grep -q 'why: a few words on a file or a dup too' "$NOTES_FIXTURE/prompt.txt" || fail "the prompt asks for no why on a filing"
  grep -qE 'fix\(audio\): the gun sound plays late .*#requested' "$PROJ/scratch/agent/README.md" || fail "$(cat "$PROJ/scratch/agent/README.md")"
  run tasks
  refute_output --partial '#requested'
  [ "$(grep -c '"want":"human"' "$HOME/.local/state/notes/ingest.jsonl")" = 2 ] || fail "$(cat "$HOME/.local/state/notes/ingest.jsonl")"
}

@test "a duplicate joins its open row, and a line about another project moves there" {
  sheet '- menu still flickers on resize\n- other needs a logo\n' '- [ ] fix(ui): the menu flickers <!-- id:sc-4 -->\n'
  answer '{"n": 1, "action": "dup", "id": "sc-4"}' \
    '{"n": 2, "action": "file", "rows": ["feat(brand): a logo #size/s"], "project": "other"}'
  run "$TRIAGE"
  assert_success
  grep -qF -- '- [ ] fix(ui): the menu flickers <!-- id:sc-4 -->' "$SHEET"
  grep -qx '  was: menu still flickers on resize' "$SHEET" || fail "$(cat "$SHEET")"
  grep -qE 'feat\(brand\): a logo .*id:ot-1' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  run inbox
  refute_output --partial 'flickers'
  refute_output --partial 'logo'
}

@test "a duplicate of another project's row joins it on that project's board" {
  sheet '- the logo is blurry on retina\n' ''
  printf '%s\n' '# other' '' 'Version: v0.1.0' '' '## Inbox' '' '## Tasks' '- [ ] fix(brand): the logo blurs on hi-dpi screens <!-- id:ot-3 -->' >"$PROJ/other/README.md"
  answer '{"n": 1, "action": "dup", "id": "ot-3"}'
  run "$TRIAGE"
  assert_success
  grep -qx '  was: the logo is blurry on retina' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  run inbox
  refute_output --partial 'blurry'
}

@test "a duplicate of an agent-board row joins it there" {
  sheet '- which lane should a game take\n' ''
  mkdir -p "$PROJ/scratch/agent"
  printf '# scratch agent\n\n## Tasks\n- [ ] decide(lanes): which lane a game takes <!-- id:sc-7 -->\n' >"$PROJ/scratch/agent/README.md"
  answer '{"n": 1, "action": "dup", "id": "sc-7"}'
  run "$TRIAGE"
  assert_success
  grep -qx '  was: which lane should a game take' "$PROJ/scratch/agent/README.md" || fail "$(cat "$PROJ/scratch/agent/README.md")"
  run inbox
  refute_output --partial 'which lane'
}

@test "--dry-run writes nothing" {
  sheet '- the gun sound is off\n' ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): gun sound"]}'
  before="$(cat "$SHEET")"
  run "$TRIAGE" --dry-run
  assert_success
  assert_output --partial 'would file [scratch]'
  assert_equal "$(cat "$SHEET")" "$before"
}

@test "--backlog: open rows are rewritten, moved, dropped or joined as the model says, each through ptask" {
  sheet '' '- [ ] the menu flickers on resize #requested #high <!-- id:sc-4 -->\n- [ ] menu flicker again <!-- id:sc-5 -->\n- [ ] other needs a logo <!-- id:sc-6 -->\n- [ ] scratch <!-- id:sc-7 -->\n- [/] the save is slow <!-- id:sc-8 -->\n'
  # rows reach the model sorted by text: sc-5, sc-6, sc-7, sc-4, sc-8; a row in progress is never dropped
  answer '{"n": 1, "action": "dup", "id": "sc-4"}' '{"n": 2, "action": "rewrite", "row": "feat(brand): a logo #size/s", "project": "other"}' \
    '{"n": 3, "action": "drop", "why": "a header, not a task"}' \
    '{"n": 4, "action": "rewrite", "row": "fix(ui): the menu flickers on resize #size/s"}' \
    '{"n": 5, "action": "drop", "why": "in progress anyway"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'backlog: rewrote 2, moved 1, dropped 2, kept 1, refused 0'
  grep -qx '2. \[sc-6\] other needs a logo' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  run tasks
  assert_output --regexp '- \[ \] fix\(ui\): the menu flickers on resize #size/s #requested .*#high.*id:sc-4'
  assert_output --partial '  was: the menu flickers on resize #requested'
  # a dropped row is no finished work, so it leaves Done at once for the version note
  refute_output --partial 'menu flicker again'
  run cat "$PROJ/scratch/agent/versions/v0.1.0.md"
  assert_output --regexp '- \[x\] menu flicker again .*dup:sc-4'
  assert_output --regexp '- \[x\] scratch .*dropped: triage: a header, not a task'
  run tasks
  assert_output --partial '- [/] the save is slow <!-- id:sc-8 -->'
  refute_output --partial 'logo'
  # rewritten, then moved by its id, its old words with it
  grep -q 'feat(brand): a logo #size/s.*id:sc-6' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  grep -qx '  was: other needs a logo' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
}

@test "a filed row keeps an #of/ naming an open epic of its project and only loses a bad one" {
  sheet '- the gun sound is off\n- the menu flickers\n' '- [ ] epic(audio): the sound pass #size/l <!-- id:sc-9 -->\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound is off #high #size/s #of/sc-9"]}' \
    '{"n": 2, "action": "file", "rows": ["fix(ui): the menu flickers #low #size/s #of/sc-404"]}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 2, left 0, refused 0'
  run tasks
  assert_output --regexp 'fix\(audio\): the gun sound is off .*#of/sc-9'
  assert_output --partial 'fix(ui): the menu flickers'
  refute_output --partial 'sc-404'
  grep -q 'sc-9	scratch	epic(audio): the sound pass' "$NOTES_FIXTURE/prompt.txt" || fail "the epics never reached the model"
}

@test "--backlog: a rewrite keeps an #of/ naming an open epic and only loses a bad one" {
  sheet '' '- [ ] epic(audio): the sound pass #size/l <!-- id:sc-9 -->\n- [ ] gun sound is off #low <!-- id:sc-1 -->\n- [ ] menu flickers #low <!-- id:sc-2 -->\n'
  answer '{"n": 1, "action": "keep"}' \
    '{"n": 2, "action": "rewrite", "row": "fix(audio): the gun sound is off #size/s #of/sc-9"}' \
    '{"n": 3, "action": "rewrite", "row": "fix(ui): the menu flickers #size/s #of/sc-404"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  run tasks
  assert_output --regexp 'fix\(audio\): the gun sound is off .*#of/sc-9'
  assert_output --partial 'fix(ui): the menu flickers'
  refute_output --partial 'sc-404'
  grep -q 'sc-9	scratch	epic(audio): the sound pass' "$NOTES_FIXTURE/prompt.txt" || fail "the epics never reached the model"
}

@test "--backlog: a plan's finish row stays on its board, and a rewrite must keep its plan slug, which ask-sweep finds it by" {
  sheet '' '- [ ] finish alpha-plan-lazy-otter: 2 phases left, next: p3 the gate #requested <!-- id:sc-1 -->\n- [ ] finish beta-plan-tidy-crow: 1 phases left, next: p2 docs #requested <!-- id:sc-2 -->\n- [ ] finish gamma_plan.v2: 3 phases left, next: p1 #requested <!-- id:sc-3 -->\n'
  # sorted by text: alpha (sc-1), beta (sc-2), gamma (sc-3)
  answer '{"n": 1, "action": "rewrite", "row": "chore(ci): finish plan lazy-otter, 2 phases left #size/m"}' \
    '{"n": 2, "action": "rewrite", "row": "chore(docs): finish beta-plan-tidy-crow, 1 phase left #size/s", "project": "other"}' \
    '{"n": 3, "action": "rewrite", "row": "chore(ci): finish the gamma plan, 3 phases left #size/m"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'rewrote 1, moved 0, dropped 0, kept 2'
  assert_output --partial 'sc-1 kept: the rewrite drops plan slug alpha-plan-lazy-otter'
  assert_output --partial 'sc-2 stays: ask-sweep finds plan beta-plan-tidy-crow'
  run tasks
  assert_output --partial 'finish alpha-plan-lazy-otter: 2 phases left'
  assert_output --partial 'chore(docs): finish beta-plan-tidy-crow, 1 phase left'
  assert_output --partial 'finish gamma_plan.v2: 3 phases left'
}

# keyed_row_left <row text>: a row fleet-bench keys by its prefix (lib/board-keys.sh) is never
# listed to the model, so it keeps its words. It sorts first, so the answer for row 1, were it
# listed, would rewrite it: the menu row taking that answer shows it was not (ar-2482).
keyed_row_left() {
  sheet '' "- [ ] $1 <!-- id:sc-1 -->\n- [ ] the menu flickers <!-- id:sc-2 -->\n"
  answer '{"n": 1, "action": "rewrite", "row": "fix(ui): the menu flickers #size/s"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'rewrote 1, moved 0, dropped 0, kept 0'
  grep -qF -- "$1" "$NOTES_FIXTURE/prompt.txt" && fail "the keyed row reached the model"
  run tasks
  assert_output --partial "- [ ] $1 <!-- id:sc-1 -->"
  assert_output --partial 'fix(ui): the menu flickers'
}

@test "--backlog: a check(watch) row fleet-bench keys is left as it is" {
  keyed_row_left 'check(watch): disk-free tripped since 2026-11-01, expected: disk-free is healthy.'
}
@test "--backlog: a check(alert) row fleet-bench keys is left as it is" {
  keyed_row_left 'check(alert): NodeDown hp-victus firing, alertmanager-fleet tripped since 2026-11-01, expected: -'
}
@test "--backlog: a check(red) row fleet-bench keys is left as it is" {
  keyed_row_left 'check(red): watch voice-puck is red'
}
@test "--backlog: a check(lesson) guard row fleet-bench keys is left as it is" {
  keyed_row_left 'check(lesson): guard 0a1b2c3d: lesson "x" (a.md, last 2026-11-01) was found again in 4 dream sweeps'
}
@test "--backlog: a fix(hold) row fleet-bench keys is left as it is" {
  keyed_row_left 'fix(hold): ci-lint went red after cleanup merge ar-1 (pr 12): -'
}
@test "--backlog: a fix(logs) row fleet-bench keys is left as it is" {
  keyed_row_left 'fix(logs): dream error 0a1b2c3d: Traceback in the sweep'
}
@test "--backlog: a fix(unit) row fleet-bench keys is left as it is" {
  keyed_row_left 'fix(unit): foo.service failed: exit-code'
}
@test "--backlog: a fix(runner) row fleet-bench keys is left as it is" {
  keyed_row_left 'fix(runner): dream is FAILED: no detail'
}

@test "--backlog: an answer cached for a keyed row before it was left alone is neither reported nor applied" {
  local raw='- [ ] fix(unit): foo.service failed: exit-code <!-- id:sc-1 -->' cache
  sheet '' "$raw\n"
  cache="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/inbox-triage/backlog-scratch.jsonl"
  mkdir -p "$(dirname "$cache")"
  jq -cn --arg r "$raw" '{lane: "human", raw: $r, action: "rewrite", id: "", project: "", row: "fix(systemd): foo fails #size/s", why: "", epic: "", priority: ""}' >"$cache"
  run "$TRIAGE" --backlog --report
  assert_success
  assert_output --partial 'Open rows read: 0 (agent 0, human 0) on 0 projects. Judged: 0.'
  assert_line '| rewrite | 0 |'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  run tasks
  assert_output --partial "$raw"
  refute_output --partial 'fix(systemd)'
}

@test "--backlog: an untyped rewrite, a dup of itself, a dup of no listed row and a drop of a heading change nothing" {
  sheet '' '- [ ] the menu flickers <!-- id:sc-4 -->\n- [ ] the save is slow <!-- id:sc-5 -->\n- [ ] the jump is floaty <!-- id:sc-6 -->\n'
  # sorted by text: jump (sc-6), menu (sc-4), save (sc-5)
  answer '{"n": 1, "action": "rewrite", "row": "make the jump less floaty"}' '{"n": 2, "action": "dup", "id": "sc-4"}' \
    '{"n": 3, "action": "dup", "id": "sc-99"}' '{"n": 4, "action": "drop", "why": "just the project name"}'
  printf '%s\n' '- [ ] world <!-- id:sc-7 -->' '    - [ ] dust in the air' >>"$SHEET"
  before="$(cat "$SHEET")"
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'rewrote 0, moved 0, dropped 0, kept 4, refused 1'
  assert_equal "$(cat "$SHEET")" "$before"
  grep -qx '   - dust in the air' "$NOTES_FIXTURE/prompt.txt" || fail "the child row never reached the model"
}

@test "--backlog --dry-run on the agent board: one line per command, the homes named, nothing written" {
  echo '{"trackers": {"scratch": {"code": "sc"}, "other": {"code": "ot", "repo": "scratch"}}}' >"$PROJECT_MAP_FILE"
  sheet '' ''
  mkdir -p "$PROJ/scratch/agent"
  printf '%s\n' '# scratch agent board' '' '## Inbox' '' '## Tasks' '- [ ] other needs a logo <!-- id:sc-6 -->' >"$PROJ/scratch/agent/README.md"
  answer '{"n": 1, "action": "rewrite", "row": "feat(brand): a logo #size/s", "project": "other"}'
  before="$(cat "$PROJ/scratch/agent/README.md")"
  run "$TRIAGE" --dry-run --backlog --project scratch
  assert_success
  assert_line --regexp '^would run: notes ptask scratch --agent --exact edit --was --text .*id:sc-6'
  assert_line 'would run: notes ptask scratch --agent move --project other sc-6'
  grep -q 'other (in scratch)' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  assert_equal "$(cat "$PROJ/scratch/agent/README.md")" "$before"
}

@test "--backlog --dry-run keeps its answers; a second dry run and the apply reuse them, and the apply leaves a row new since alone" {
  cache="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/inbox-triage/backlog-scratch.jsonl"
  sheet '' '- [ ] the menu flickers on resize <!-- id:sc-4 -->\n- [ ] menu flicker again <!-- id:sc-5 -->\n- [ ] scratch <!-- id:sc-7 -->\n- [ ] audio pass <!-- id:sc-2 -->\n    - [ ] the gun is late\n- [ ] jump is floaty <!-- id:sc-3 -->\n'
  # sorted by text: sc-2, sc-3, sc-5, sc-7, sc-4; a heading (sc-2) is never dropped, and the cache keeps it a keep
  answer '{"n": 1, "action": "drop", "why": "a heading"}' '{"n": 2, "action": "keep"}' '{"n": 3, "action": "dup", "id": "sc-4"}' \
    '{"n": 4, "action": "drop", "why": "a header, not a task"}' '{"n": 5, "action": "rewrite", "row": "fix(ui): the menu flickers on resize #size/s"}'
  before="$(cat "$SHEET")"
  run "$TRIAGE" --dry-run --backlog --project scratch
  assert_success
  assert_output --partial 'backlog: rewrote 1, moved 0, dropped 2, kept 2'
  assert_output --partial "answers kept in $cache"
  assert_equal "$(cat "$SHEET")" "$before"
  [ "$(wc -l <"$cache")" = 5 ] || fail "$(cat "$cache")"
  # A second dry run (one stopped at its budget, say) resumes: its answers come from the cache.
  : >"$NOTES_FIXTURE/model.log"
  run "$TRIAGE" --dry-run --backlog --project scratch
  assert_success
  assert_output --partial 'backlog: rewrote 1, moved 0, dropped 2, kept 2'
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the second dry run asked the model again"
  [ "$(wc -l <"$cache")" = 5 ]
  # The apply writes what the dry run printed, though the model would now say drop. A row new or
  # changed since has no reviewed answer, so it is left as it is with no model call, and the heading
  # whose child went stays.
  sed -i -e '/the gun is late/d' -e 's/jump is floaty/jump is too floaty/' "$SHEET"
  printf '%s\n' '- [ ] zebra row <!-- id:sc-9 -->' >>"$SHEET"
  answer '{"n": 1, "action": "drop", "why": "never asked"}' '{"n": 2, "action": "drop", "why": "never asked"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'backlog: rewrote 1, moved 0, dropped 2, kept 3'
  assert_output --partial 'scratch (human): 2 rows new or changed since the dry run left as they are'
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the apply asked the model $(wc -l <"$NOTES_FIXTURE/model.log") times"
  [ ! -e "$cache" ] || fail "the apply left its cache"
  run tasks
  assert_output --regexp 'fix\(ui\): the menu flickers on resize #size/s .*id:sc-4'
  assert_output --partial '- [ ] audio pass <!-- id:sc-2 -->'
  assert_output --partial 'jump is too floaty'
  refute_output --partial 'menu flicker again'
  assert_output --partial 'zebra row'
  run cat "$PROJ/scratch/agent/versions/v0.1.0.md"
  assert_output --regexp '- \[x\] menu flicker again .*dup:sc-4'
  assert_output --regexp '- \[x\] scratch .*dropped: triage: a header, not a task'
}

@test "--backlog: an apply whose write is refused keeps the cache, so the retry writes the reviewed verdict, not a new one" {
  cache="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/inbox-triage/backlog-scratch.jsonl"
  sheet '' '- [ ] the menu flickers on resize <!-- id:sc-4 -->\n'
  answer '{"n": 1, "action": "rewrite", "row": "fix(ui): the menu flickers on resize #size/s"}'
  run "$TRIAGE" --dry-run --backlog --project scratch
  assert_success
  # Replace the link, never write through it: it points at the built binary.
  rm -f "$SANDBOX/bin/notes"
  printf '#!/usr/bin/env bash\n[ "$1" = ptask ] && [[ " $* " == *" edit "* ]] && exit 1\nexec "%s" "$@"\n' "$NOTES_BIN" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  : >"$NOTES_FIXTURE/model.log"
  run "$TRIAGE" --backlog --project scratch
  assert_output --partial 'refused 1'
  [ -s "$cache" ] || fail "the refused apply removed its cache"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  answer '{"n": 1, "action": "keep"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the retry asked the model again"
  [ ! -e "$cache" ] || fail "the apply left its cache"
  run tasks
  assert_output --regexp 'fix\(ui\): the menu flickers on resize #size/s .*id:sc-4'
}

# agent_board <task lines>: scratch's agent board.
agent_board() { mkdir -p "$PROJ/scratch/agent"; printf '# scratch agent board\n\n## Inbox\n\n## Tasks\n%b' "$1" >"$PROJ/scratch/agent/README.md"; }

@test "--backlog: by the rubric a raise tags a row up, an improvement leaves the agent board for improvements.md, a done closes; ideas.md is untouched" {
  printf '# scratch - ideas\n\nmine, by hand\n' >"$PROJ/scratch/ideas.md"
  cp "$PROJ/scratch/ideas.md" "$BATS_TEST_TMPDIR/ideas.before"
  sheet '' ''
  agent_board '- [ ] a: the save crashes on quit #low <!-- id:sc-1 -->\n- [ ] b: a glow on the menu like #12 #low <!-- id:sc-2 -->\n- [ ] c: ship the logo, done in #12 #low <!-- id:sc-3 -->\n- [ ] d: a bloom pass #requested #low <!-- id:sc-4 -->\n- [ ] e: prod is down #urgent <!-- id:sc-5 -->\n- [ ] f: polish the hud #low <!-- id:sc-6 -->\n    - [ ] the ammo count\n- [ ] g: finish beta-plan-tidy-crow: 1 phases left, next: p2 docs #low <!-- id:sc-7 -->\n'
  answer '{"n": 1, "action": "raise", "priority": "high", "why": "a fault every player hits"}' \
    '{"n": 2, "action": "improvement", "why": "polish nobody asked for"}' \
    '{"n": 3, "action": "done", "why": "says done in #12"}' \
    '{"n": 4, "action": "improvement", "why": "a nice-to-have"}' \
    '{"n": 5, "action": "raise", "priority": "high", "why": "lower it"}' \
    '{"n": 6, "action": "improvement", "why": "a heading"}' \
    '{"n": 7, "action": "done", "why": "a plan finish row"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'backlog: rewrote 0, moved 0, dropped 0, kept 4, refused 0, raised 1, improvements 1, done 1'
  # The rubric and each row's own priority reach the model; an untagged row shows none.
  grep -q 'Not a row at all: a nice-to-have' "$NOTES_FIXTURE/prompt.txt" || fail "the rubric never reached the model"
  grep -q 'Never add or guess one the words do not name' "$NOTES_FIXTURE/prompt.txt" || fail "the backlog call lost the file rule"
  grep -qx '1. \[sc-1\] (#low) a: the save crashes on quit' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  board="$PROJ/scratch/agent/README.md"
  grep -q 'a: the save crashes on quit .*#high' "$board" || fail "$(cat "$board")"
  grep -q 'a: the save crashes on quit .*#low' "$board" && fail "the raise kept #low"
  grep -q '\[ \] d: a bloom pass' "$board" || fail "a #requested row became an improvement"
  grep -q '\[ \] e: prod is down #urgent' "$board" || fail "a raise lowered a row"
  grep -q '\[ \] f: polish the hud' "$board" || fail "a heading over child rows left the board"
  grep -q '\[ \] g: finish beta-plan-tidy-crow' "$board" || fail "a plan's finish row left its board"
  grep -q '\[ \] b: a glow' "$board" && fail "the improvement stayed on the board"
  run cat "$PROJ/scratch/agent/versions/v0.1.0.md"   # an agent board has no Version: line; its rows file under the human sheet's open version
  assert_output --regexp 'b: a glow on the menu .*dropped: triage: improvement: kept in improvements.md'
  assert_output --regexp 'c: ship the logo.*dropped: triage: done: says done in #12'
  run cat "$PROJ/scratch/improvements.md"
  assert_output --partial '- b: a glow on the menu like #12 ('
  refute_output --partial '#low'
  refute_output --partial 'bloom'
  cmp "$PROJ/scratch/ideas.md" "$BATS_TEST_TMPDIR/ideas.before" || fail "ideas.md changed"
}

@test "--backlog: the human's own board never loses a row to an improvement (negative control: the same answer on the agent board moves it)" {
  sheet '' '- [ ] a glow on the menu #low <!-- id:sc-2 -->\n'
  answer '{"n": 1, "action": "improvement", "why": "polish nobody asked for"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'kept 1, refused 0, raised 0, improvements 0'
  run tasks
  assert_output --partial '- [ ] a glow on the menu'
  [ ! -e "$PROJ/scratch/improvements.md" ] || fail "a human row became an improvement"
  sheet '' ''
  agent_board '- [ ] a glow on the menu #low <!-- id:sc-2 -->\n'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  assert_output --partial 'improvements 1'
}

@test "--backlog --report: the dry run's kept answers by verdict, the old rows, and counts that add up to the rows read; nothing written" {
  sheet '' '- [ ] the human list row <!-- id:sc-9 -->\n'
  agent_board '- [ ] a: the save crashes on quit #low <!-- id:sc-1 -->\n- [ ] b: a glow on the menu | bright #low <!-- id:sc-2 -->\n- [ ] c: the save crash again #low <!-- id:sc-3 -->\n- [ ] d: old and fine #low <!-- id:sc-4 filed:2026-01-02 -->\n'
  answer '{"n": 1, "action": "raise", "priority": "high", "why": "a fault every player hits"}' \
    '{"n": 2, "action": "improvement", "why": "polish nobody asked for"}' \
    '{"n": 3, "action": "dup", "id": "sc-1"}'
  run "$TRIAGE" --backlog --report
  assert_success
  assert_output --partial 'Open rows read: 5 (agent 4, human 1) on 1 projects. Judged: 0. Not judged yet: 5.'
  # The human board's call gets the same canned answers: its one row is raised too.
  run "$TRIAGE" --dry-run --backlog --project scratch
  assert_success
  before="$(cat "$PROJ/scratch/agent/README.md")"
  : >"$NOTES_FIXTURE/model.log"
  run "$TRIAGE" --backlog --report
  assert_success
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the report asked the model"
  assert_equal "$(cat "$PROJ/scratch/agent/README.md")" "$before"
  [ ! -e "$PROJ/scratch/improvements.md" ] || fail "the report wrote an improvement"
  # d had no answer: not judged, and the 4 judged plus it make the 5 read.
  assert_output --partial 'Judged: 4. Not judged yet: 1.'
  assert_line '| raise | 2 |'
  assert_line '| improvement | 1 |'
  assert_line '| dup | 1 |'
  assert_line '| not judged yet | 1 |'
  assert_line '| scratch | sc-1 | agent | a: the save crashes on quit | #high: a fault every player hits |'
  assert_line '| scratch | sc-2 | agent | b: a glow on the menu / bright | polish nobody asked for |'
  assert_line '| scratch | sc-3 | agent | c: the save crash again | dup of sc-1 |'
  assert_line --regexp '^## Agent rows open since before .* \(1\)$'
  assert_line '| scratch | sc-4 | 2026-01-02 | d: old and fine | not judged yet |'
  # A row changed since its answer counts as not judged: the apply would leave it too.
  sed -i 's/a: the save crashes on quit/a: the save crashes on exit/' "$PROJ/scratch/agent/README.md"
  run "$TRIAGE" --backlog --report
  assert_output --partial 'Judged: 3. Not judged yet: 2.'
  # --project limits it to one board: another project's rows and answers stay out.
  run "$TRIAGE" --backlog --report --project nosuch
  assert_success
  assert_output --partial 'Open rows read: 0 (agent 0, human 0) on 0 projects. Judged: 0. Not judged yet: 0.'
}

@test "--report without --backlog, or with --priority, is refused and asks no model" {
  run "$TRIAGE" --report
  assert_failure 2
  assert_output --partial '--report goes with --backlog'
  run "$TRIAGE" --backlog --report --priority
  assert_failure 2
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "a model was asked"
}

@test "outbox: a #p: line moves and files with no model, and the inbox page says where it went" {
  sheet '' ''
  mkdir -p "$HOME/.notes/lab/inbox"   # the capture inbox: a machine without one publishes no page
  outbox '- [ ] chore(build): drop the old cache #low #p:scratch\n- [ ] stays for the model\n'
  answer '{"n": 1, "action": "skip", "why": "no project named"}'
  # The page's triage score is judge-eval's inbox-triage cell, read as given: never counted again.
  echo '{"agents":[{"agent":"inbox-triage","score_7d":{"text":"n<30","title":"7d, 1 of 1 right, 0 pending, triage-untouched"}}]}' >"$NOTES_FIXTURE/judge.json"
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 1 from the outbox, filed 1, left 1, refused 0'
  run tasks
  assert_output --regexp 'chore\(build\): drop the old cache .*#low.*id:sc-1'
  refute_output --partial '#p:'
  run cat "$HOME/.notes/outbox.md"
  refute_output --partial 'old cache'
  assert_output --partial '- [ ] stays for the model'
  grep -qx '1. \[outbox\] stays for the model' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  page="$(find "$HOME/.notes" -path '*status/inbox.md' | head -1)"
  [ -n "$page" ] || fail "no inbox page"
  run cat "$page"
  assert_output --regexp '[0-9]{2}:[0-9]{2} filed \[\[[^]]*\|sc-1\]\] scratch: chore\(build\): drop the old cache'
  refute_output --partial '  - from: outbox'
  assert_output --regexp '[0-9]{2}:[0-9]{2} left \(outbox\): stays for the model'
  assert_output --partial '  - why: no project named'
  assert_output --partial '; triage score n<30 (7d, 1 of 1 right, 0 pending, triage-untouched)'
  # judge-eval giving no cell leaves the score off the page, not a second count in its place.
  rm "$NOTES_FIXTURE/judge.json"
  run notes ingest page
  assert_success
  assert_output --partial 'no triage score on the inbox page'
  run cat "$page"
  refute_output --partial 'triage score'
  refute_output --partial 'triage kept'
  grep -q '"row":"chore(build): drop the old cache"' "$HOME/.local/state/notes/ingest.jsonl" || fail "the filed row's words were not recorded"
  ! grep -q '"action":"sweep-stopped"' "$HOME/.local/state/notes/ingest.jsonl" || fail "a clean sweep recorded a stop"
  run jq -r 'select(.action == "moved" or .action == "filed") | .action + " " + .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'moved #p: tag'
  assert_line 'filed typed'
  # The trace follows the line from the outbox to the row it became.
  run notes log --trace 'old cache'
  assert_success
  assert_line --regexp ' moved outbox -> scratch.*: chore\(build\): drop the old cache.*\[#p: tag\]$'
  assert_line --regexp ' filed sc-1 scratch.*\[typed\]$'
}

@test "outbox: a #p: word that names no project goes to the model with the word as a hint, and is routed, not refused" {
  sheet '' ''
  outbox '- [ ] chore(build): drop the old cache #p:scrach\n- [ ] fix(ui): a gap in the hud #p:scratch\n- [ ] still unknown #p:nowhere\n'
  answer '{"n": 1, "action": "file", "rows": ["chore(build): drop the old cache #low #size/s"], "project": "scratch"}' \
    '{"n": 2, "action": "skip", "why": "no such project"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 2 from the outbox, filed 2, left 1, refused 0'
  assert_output --partial '#p:scrach names no project, left for the model'
  # the exact tag moved with no model; the two misses were the model's batch, with the word as a hint
  grep -qx '1. \[outbox\] chore(build): drop the old cache #p:scrach (tagged #p:scrach, which is no project; it may name one of the projects above)' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  grep -q '^2. \[outbox\] still unknown #p:nowhere (tagged #p:nowhere' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  ! grep -q "a gap in the hud" "$NOTES_FIXTURE/prompt.txt" || fail "an exact #p: line reached the model"
  run tasks
  assert_output --regexp 'chore\(build\): drop the old cache .*id:sc-[12]'
  assert_output --regexp 'fix\(ui\): a gap in the hud'
  refute_output --partial '#p:'
  run cat "$HOME/.notes/outbox.md"
  assert_output --partial 'still unknown #p:nowhere'
  refute_output --partial 'old cache'
  # the one the model passed over is recorded as left, so the next sweep does not ask again
  rm -f "$NOTES_FIXTURE/model.log"
  run "$TRIAGE"
  assert_success
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "a recorded line was asked again"
}

@test "outbox: an <id>: line answers its open row with no model, closing a decide row; an id with no open row is left" {
  sheet '' '- [ ] decide(squad): followers that fight with you #low <!-- id:sc-1 -->\n- [ ] feat(ui): a colour for the squad <!-- id:sc-2 -->\n'
  mkdir -p "$PROJ/scratch/agent"
  printf '# scratch agent\n\n## Tasks\n- [ ] decide(lanes): which lane a game takes <!-- id:sc-3 -->\n' >"$PROJ/scratch/agent/README.md"
  outbox '- [ ] sc-1: yes, build it after the bully fix\n- [ ] sc-2: the blue one #p:scrach\n- [ ] sc-3: the agent lane\n- [ ] zz-9: yes\n- [ ] stays for the model\n'
  answer '{"n": 1, "action": "skip", "why": "no project named"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 3 from the outbox, filed 3, left 2, refused 0'
  # Only the line that is no answer reaches the model.
  grep -qx '1. \[outbox\] stays for the model' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  run grep -c '^[0-9]*\. \[' "$NOTES_FIXTURE/prompt.txt"
  assert_output 1
  run tasks
  assert_output --regexp '\[x\] decide\(squad\): followers that fight with you .*ingest:[0-9-]{10}'
  assert_output --partial 'sc-1: yes, build it after the bully fix'
  assert_output --regexp '\[ \] feat\(ui\): a colour for the squad'
  assert_output --partial 'sc-2: the blue one'
  run cat "$PROJ/scratch/agent/README.md"
  assert_output --regexp '\[x\] decide\(lanes\): which lane a game takes .*ingest:'
  assert_output --partial 'sc-3: the agent lane'
  run cat "$HOME/.notes/outbox.md"
  refute_output --partial 'sc-1:'
  refute_output --partial 'sc-2:'
  assert_output --partial '- [ ] zz-9: yes'
  assert_output --partial '- [ ] stays for the model'
  run "$NOTES_BIN" ingest page
  page="$(find "$HOME/.notes" -path '*status/inbox.md' | head -1)"
  [ -n "$page" ] || { mkdir -p "$HOME/.notes/lab/inbox"; "$NOTES_BIN" ingest page; page="$(find "$HOME/.notes" -path '*status/inbox.md' | head -1)"; }
  run cat "$page"
  assert_output --partial 'left (outbox): zz-9: yes'
  assert_output --partial 'why: no open row zz-9'
}

@test "outbox: the model routes a line to its project, flags it for a plan, and a dup joins the open row's project" {
  sheet '' '- [ ] fix(ui): the menu flickers <!-- id:sc-4 -->\n'
  outbox '- [ ] other needs a whole brand kit\n  logo, colours, a font\n- [ ] the menu flickers again\n- [ ] a line for nowhere\n'
  answer '{"n": 1, "action": "file", "rows": ["feat(brand): a brand kit #size/l"], "project": "other", "plan": true}' \
    '{"n": 2, "action": "dup", "id": "sc-4", "project": "other"}' \
    '{"n": 3, "action": "file", "rows": ["chore(x): nowhere #size/s"], "project": "nowhere"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 2 from the outbox, filed 2, left 0, refused 1'
  grep -qE 'feat\(brand\): a brand kit #size/l #plan .*id:ot-1' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  grep -qx '  logo, colours, a font' "$PROJ/other/README.md" || fail "the details did not travel: $(cat "$PROJ/other/README.md")"
  grep -qx '  was: the menu flickers again' "$SHEET" || fail "$(cat "$SHEET")"
  run cat "$HOME/.notes/outbox.md"
  assert_output --partial '- [ ] a line for nowhere'
  refute_output --partial 'brand kit'
  refute_output --partial 'flickers'
  run jq -r '[.action, .from, .to, .text] | join(" ")' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'moved outbox other other needs a whole brand kit'
  assert_line 'filed other other other needs a whole brand kit'
  assert_line 'moved outbox scratch the menu flickers again'
  assert_line 'dup scratch scratch the menu flickers again'
  assert_line --regexp '^refused outbox  a line for nowhere'
  grep -qx -- '--user start --no-block agentctl@inbox-plan.service' "$NOTES_FIXTURE/systemctl.log" || fail "the planner was not started"
}

@test "outbox: the person's own #plan and #go reach the row when the model drops them; a plain line gets neither" {
  sheet '' ''
  outbox '- [ ] other needs a logo #plan #go\n- [ ] other needs a font\n'
  answer '{"n": 1, "action": "file", "rows": ["feat(brand): a logo #size/m"], "project": "other", "plan": false}' \
    '{"n": 2, "action": "file", "rows": ["feat(brand): a font #size/s"], "project": "other", "plan": false}'
  run "$TRIAGE"
  assert_success
  grep -qE 'feat\(brand\): a logo #size/m #plan #go .*id:ot-' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  run grep 'a font' "$PROJ/other/README.md"
  assert_success
  refute_output --partial '#plan'
  refute_output --partial '#go'
}

@test "outbox: a plan only the model asked for gets #go, so only the person's own #plan holds the row for review" {
  sheet '' ''
  outbox '- [ ] other needs a logo\n- [ ] other needs a font #plan\n- [ ] other needs a color\n'
  answer '{"n": 1, "action": "file", "rows": ["feat(brand): a logo #size/m"], "project": "other", "plan": true}' \
    '{"n": 2, "action": "file", "rows": ["feat(brand): a font #size/s"], "project": "other", "plan": true}' \
    '{"n": 3, "action": "file", "rows": ["feat(brand): a color #size/s #plan"], "project": "other", "plan": false}'
  run "$TRIAGE"
  assert_success
  grep -qE 'feat\(brand\): a logo #size/m #plan #go .*id:ot-' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  # a #plan the model wrote into its row text, with plan false, is the model's too
  grep -qE 'feat\(brand\): a color #size/s #plan #go .*id:ot-' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  # negative control: the person's own #plan, with no #go, is theirs to review
  run grep 'a font' "$PROJ/other/README.md"
  assert_output --partial '#plan'
  refute_output --partial '#go'
}

@test "outbox: the routing prompt names the homes and the shared-code rule, as --backlog does" {
  echo '{"trackers": {"scratch": {"code": "sc"}, "other": {"code": "ot", "repo": "scratch"}}}' >"$PROJECT_MAP_FILE"
  sheet '' ''
  outbox '- [ ] other needs a logo\n'
  answer '{"n": 1, "action": "file", "rows": ["feat(brand): a logo #size/s"], "project": "other"}'
  run "$TRIAGE"
  assert_success
  run cat "$NOTES_FIXTURE/prompt.txt"
  assert_output --partial 'other (in scratch)'
  assert_output --partial "the shared code under them, belongs on the repo's project"
  assert_output --partial 'a host or the cluster belongs on home-config'
  assert_output --partial 'read each with its neighbours'
  assert_output --partial 'own is a second, separate answer'
  assert_output --partial 'A line marked asked before has had its neighbours filed already'
  assert_output --partial '"action": "dup", "line": 4'
}

@test "outbox: a repeat of a line above joins the row that line filed, even when its answer comes first" {
  sheet '' ''
  outbox '- [ ] the bench can be picked up\n- [ ] make the bench not throwable\n'
  answer '{"n": 2, "action": "dup", "line": 1}' \
    '{"n": 1, "action": "file", "rows": ["fix(room): the bench cannot be picked up or thrown #size/s"], "project": "scratch"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 2 from the outbox, filed 2, left 0, refused 0'
  [ "$(grep -c 'id:sc-' "$SHEET")" = 1 ] || fail "one row expected: $(cat "$SHEET")"
  grep -qx '  was: the bench can be picked up' "$SHEET" || fail "$(cat "$SHEET")"
  grep -qx '  was: make the bench not throwable' "$SHEET" || fail "the repeat did not join the row: $(cat "$SHEET")"
  run jq -r '[.action, .from, .to, .id // "", .text] | join(" ")' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'dup scratch scratch sc-1 make the bench not throwable'
}

@test "outbox: a repeat joins its row on the lane the CLI filed it on, and the person's own id: words never name the row" {
  sheet '' '- [ ] fix(ui): an old row <!-- id:sc-9 -->\n'
  outbox '- [ ] the scratch build breaks, see id:sc-9 #agent\n- [ ] scratch build still broken\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(build): the build breaks #size/s"], "project": "scratch", "lane": "human"}' \
    '{"n": 2, "action": "dup", "line": 1}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 2 from the outbox, filed 2, left 0, refused 0'
  grep -qx '  was: scratch build still broken' "$PROJ/scratch/agent/README.md" || fail "$(cat "$PROJ/scratch/agent/README.md")"
  run grep -c 'was:' "$SHEET"
  assert_output 0
}

@test "outbox: a repeat of a line that filed no row is left, saying so (negative control)" {
  sheet '' ''
  outbox '- [ ] a thought\n- [ ] the same thought\n'
  answer '{"n": 1, "action": "skip", "why": "a thought"}' '{"n": 2, "action": "dup", "line": 1}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 0 from the outbox, filed 0, left 2'
  run jq -r 'select(.action == "left") | .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'dup of line 1, which filed no row'
}

@test "outbox: a line left before the triager last changed is asked again; one left since is not" {
  sheet '' ''
  outbox '- [ ] the scratch menu flickers\n'
  mkdir -p "$HOME/.local/state/notes"
  rec() { jq -cn --arg ts "$1" '{ts: $ts, action: "left", from: "outbox", to: "", text: "the scratch menu flickers", why: "unclear which project", stage: "intake"}' >"$HOME/.local/state/notes/ingest.jsonl"; }
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the menu flickers #size/s"], "project": "scratch"}'
  rec "$(date -d '+1 day' --iso-8601=seconds)"
  run "$TRIAGE"
  assert_success
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "a line left after the triager changed was asked again"
  grep -q 'the scratch menu flickers' "$HOME/.notes/outbox.md" || fail "the line moved"
  rec '2000-01-01T00:00:00.5-08:00'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 1 from the outbox, filed 1'
  grep -q 'fix(ui): the menu flickers' "$SHEET" || fail "$(cat "$SHEET")"
}

@test "outbox: a left line records the projects of the nearest lines filed above and below it, once each" {
  sheet '' ''
  outbox '- [ ] the scratch lobby is slow\n- [ ] a thought\n- [ ] the other menu is slow\n- [ ] another thought\n- [ ] the other font is small\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(net): the lobby is slow #size/s"], "project": "scratch"}' \
    '{"n": 2, "action": "skip", "why": "unclear which project"}' \
    '{"n": 3, "action": "file", "rows": ["fix(ui): the menu is slow #size/s"], "project": "other"}' \
    '{"n": 4, "action": "skip", "why": "unclear which project"}' \
    '{"n": 5, "action": "file", "rows": ["fix(ui): the font is small #size/s"], "project": "other"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 3 from the outbox, filed 3, left 2'
  run jq -r 'select(.action == "left") | "\(.text): \(.near // "")"' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'a thought: scratch,other'
  assert_line 'another thought: other'
}

@test "outbox: a line asked again names where its neighbours went, and keeps that when it is left again" {
  sheet '' ''
  outbox '- [ ] the menu flickers\n'
  mkdir -p "$HOME/.local/state/notes"
  jq -cn '{ts: "2000-01-01T01:00:01.1-08:00", action: "left", from: "outbox", to: "", text: "the menu flickers", why: "unclear which project", near: "scratch,other", stage: "intake"}' >"$HOME/.local/state/notes/ingest.jsonl"
  answer '{"n": 1, "action": "skip", "why": "still unclear"}'
  run "$TRIAGE"
  assert_success
  run grep -F '1. [outbox] the menu flickers' "$NOTES_FIXTURE/prompt.txt"
  assert_output '1. [outbox] the menu flickers (asked before: the lines written beside it went to other and scratch)'
  run jq -r 'select(.action == "left") | .near' "$HOME/.local/state/notes/ingest.jsonl"
  assert_output $'scratch,other\nother,scratch'
}

@test "outbox: a line goes where its own words point, over its neighbours' project; empty or unknown own leaves project (negative controls)" {
  sheet '' ''
  outbox '- [ ] the scratch lobby is slow\n- [ ] a central bank of money\n- [ ] the scratch font is small\n- [ ] the scratch menu is slow\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(net): the lobby is slow #size/s"], "project": "scratch", "own": "scratch"}' \
    '{"n": 2, "action": "file", "rows": ["feat(bank): a central bank of money #size/m"], "project": "scratch", "own": "other"}' \
    '{"n": 3, "action": "file", "rows": ["fix(ui): the font is small #size/s"], "project": "scratch", "own": ""}' \
    '{"n": 4, "action": "file", "rows": ["fix(ui): the menu is slow #size/s"], "project": "scratch", "own": "nosuchproject"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial "line 2's own words point to other, its neighbours to scratch: filed on other"
  grep -q 'feat(bank): a central bank of money' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  run grep -c 'bank' "$SHEET"
  assert_output 0
  grep -q 'fix(ui): the font is small' "$SHEET" || fail "$(cat "$SHEET")"
  grep -q 'fix(ui): the menu is slow' "$SHEET" || fail "$(cat "$SHEET")"
}

@test "outbox: a line never left carries no asked-before mark (negative control)" {
  sheet '' ''
  outbox '- [ ] the scratch menu flickers\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the menu flickers #size/s"], "project": "scratch"}'
  run "$TRIAGE"
  assert_success
  run cat "$NOTES_FIXTURE/prompt.txt"
  refute_output --partial '(asked before:'
}

@test "outbox: a left record with a bad ts is only asked again itself; a refusal beside it still holds" {
  sheet '' ''
  outbox '- [ ] the scratch menu flickers\n- [ ] a refused line\n'
  mkdir -p "$HOME/.local/state/notes"
  { jq -cn '{ts: "2026-13-45 not a time at all", action: "left", from: "outbox", to: "", text: "the scratch menu flickers", why: "x", stage: "intake"}'
    jq -cn --arg ts "$(date --iso-8601=seconds)" '{ts: $ts, action: "refused", from: "outbox", to: "", text: "a refused line", why: "x", stage: "intake"}'
  } >"$HOME/.local/state/notes/ingest.jsonl"
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the menu flickers #size/s"], "project": "scratch"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 1 from the outbox, filed 1, left 0'
  run cat "$NOTES_FIXTURE/prompt.txt"
  refute_output --partial 'a refused line'
}

@test "outbox: a record line whose near is not a string keeps every other refusal; an empty record says nothing about parsing" {
  sheet '' ''
  outbox '- [ ] the scratch menu flickers\n- [ ] a refused line\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the menu flickers #size/s"], "project": "scratch"}'
  mkdir -p "$HOME/.local/state/notes"
  : >"$HOME/.local/state/notes/ingest.jsonl"
  run "$TRIAGE" --dry-run
  assert_success
  refute_output --partial 'did not parse'
  { jq -cn '{ts: "2026-11-09T20:00:00-05:00", action: "left", from: "outbox", to: "", text: "an old line", why: "x", near: 7, stage: "intake"}'
    jq -cn --arg ts "$(date --iso-8601=seconds)" '{ts: $ts, action: "refused", from: "outbox", to: "", text: "a refused line", why: "x", stage: "intake"}'
  } >"$HOME/.local/state/notes/ingest.jsonl"
  run "$TRIAGE"
  assert_success
  refute_output --partial 'did not parse'
  run cat "$NOTES_FIXTURE/prompt.txt"
  refute_output --partial 'a refused line'
}

@test "--watch: a sweep at start and one after a burst of saves, and inotifywait ending ends the runner" {
  sheet '' ''
  outbox ''
  # Two saves in one burst, then the watch ends: the debounce reads both before one sweep.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$NOTES_FIXTURE/watch.args"\necho "$HOME/.notes/outbox.md"\necho "$HOME/.notes/outbox.md"\n' >"$SANDBOX/bin/inotifywait"
  chmod +x "$SANDBOX/bin/inotifywait"
  INBOX_SWEEP_QUIET=1 run "$TRIAGE" --watch
  assert_failure 1
  [ "$(grep -c 'moved 0 from the outbox' <<<"$output")" = 2 ] || fail "$output"
  assert_output --partial 'inotifywait ended'
  grep -qx "$HOME/.notes" "$NOTES_FIXTURE/watch.args" || fail "$(cat "$NOTES_FIXTURE/watch.args")"
  grep -qx "$PROJ/scratch" "$NOTES_FIXTURE/watch.args" || fail "$(cat "$NOTES_FIXTURE/watch.args")"
  [ ! -f "$NOTES_FIXTURE/model.log" ] || fail "an empty sweep called the model"
}

@test "--watch: a budget stop is not a failed sweep; it runs again on the backoff, which notices a raise" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  outbox ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays off #high #size/s"]}'
  mkfifo "$NOTES_FIXTURE/events"
  printf '#!/usr/bin/env bash\ncat "$NOTES_FIXTURE/events"\n' >"$SANDBOX/bin/inotifywait"
  chmod +x "$SANDBOX/bin/inotifywait"
  printf '%s\n' '#!/usr/bin/env bash' 'echo called >> "$NOTES_FIXTURE/model.log"' 'cat > "$NOTES_FIXTURE/prompt.txt"' \
    'if [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 1 ]; then exit 75; fi' \
    'cat "$NOTES_FIXTURE/model.out"' ': > "$NOTES_FIXTURE/events"' >"$SANDBOX/bin/model-stub"
  INBOX_SWEEP_QUIET=1 INBOX_RETRY_S=1 run "$TRIAGE" --watch
  assert_failure 1
  assert_output --partial 'the sweep stopped at its budget; it runs again in 1s'
  refute_output --partial 'the sweep failed'
  assert_output --partial 'filed 1, left 0, refused 0'
}

@test "--watch: a failed sweep runs again on the backoff with no save, and a clean one waits for a save" {
  sheet '- the gun sound is off since the top-down patch\n' ''
  outbox ''
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays off #high #size/s"]}'
  mkfifo "$NOTES_FIXTURE/events"
  # The watch has no saves to report: it holds until the second model call closes the fifo.
  printf '#!/usr/bin/env bash\ncat "$NOTES_FIXTURE/events"\n' >"$SANDBOX/bin/inotifywait"
  chmod +x "$SANDBOX/bin/inotifywait"
  # The first call hits a usage limit; the second answers and then ends the watch.
  printf '%s\n' '#!/usr/bin/env bash' 'echo called >> "$NOTES_FIXTURE/model.log"' 'cat > "$NOTES_FIXTURE/prompt.txt"' \
    'if [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 1 ]; then echo "You have hit your weekly limit" >&2; exit 1; fi' \
    'cat "$NOTES_FIXTURE/model.out"' ': > "$NOTES_FIXTURE/events"' >"$SANDBOX/bin/model-stub"
  INBOX_SWEEP_QUIET=1 INBOX_RETRY_S=1 run "$TRIAGE" --watch
  assert_failure 1
  assert_output --partial 'model call failed: You have hit your weekly limit'
  assert_output --partial 'the sweep failed; it runs again in 1s'
  assert_output --partial 'filed 1, left 0, refused 0'
  # The retry's time is the runner's own next= (the Workers next column has no timer to read),
  # and the clean sweep clears it.
  grep -qE '^agentctl report --name inbox-triage .*; retry [0-9]{2}:[0-9]{2} next=[0-9]+$' "$NOTES_FIXTURE/calls.log" \
    || fail "$(cat "$NOTES_FIXTURE/calls.log")"
  [ "$(grep '^agentctl report --name inbox-triage' "$NOTES_FIXTURE/calls.log" | tail -1 | grep -o 'next=.*')" = 'next=' ] \
    || fail "$(cat "$NOTES_FIXTURE/calls.log")"
  # The negative control: after the clean sweep the watch waited for a save, so no third call.
  [ "$(wc -l < "$NOTES_FIXTURE/model.log")" = 2 ] || fail "model calls: $(wc -l < "$NOTES_FIXTURE/model.log")"
  run tasks
  assert_output --partial 'fix(audio): the gun sound plays off'
}

@test "inbox page: notes inbox ack folds a handled row into +N reviewed, --undo brings it back, a bad key writes nothing" {
  sheet '' ''
  outbox '- [ ] chore(build): drop the old cache #p:scratch\n'
  run "$TRIAGE"
  assert_success
  mkdir -p "$HOME/.notes/lab/inbox"
  "$NOTES_BIN" ingest page
  page="$(find "$HOME/.notes" -path '*status/inbox.md' | head -1)"
  [ -n "$page" ] || fail "no inbox page"
  key="$(grep -o '<!-- ack:[^ ]* -->' "$page" | head -1 | sed 's/<!-- ack:\(.*\) -->/\1/')"
  [ -n "$key" ] || fail "no tickable row: $(cat "$page")"
  grep -qE '^- \[ \] [0-9]{2}:[0-9]{2} filed \[\[[^]]*\|sc-1\]\] ' "$page" || fail "$(cat "$page")"
  run "$NOTES_BIN" inbox ack 2026-01-01T00:00:00+00:00
  assert_failure
  assert_output --partial 'no ingest event'
  [ ! -e "$HOME/.local/state/notes/inbox-ack.jsonl" ] || fail "a bad key wrote a mark"
  run "$NOTES_BIN" inbox ack -- "$key"
  assert_success
  run cat "$page"
  assert_output --partial '- +1 reviewed'
  assert_output --regexp '  - \[x\] [0-9]{2}:[0-9]{2} filed \[\[[^]]*\|sc-1\]\] '
  refute_output --regexp '^- \[ \] [0-9]{2}:[0-9]{2} filed \[\[[^]]*\|sc-1\]\] '
  run "$NOTES_BIN" inbox ack --undo -- "$key"
  assert_success
  run cat "$page"
  refute_output --partial '- +1 reviewed'
  assert_output --regexp '- \[ \] [0-9]{2}:[0-9]{2} filed \[\[[^]]*\|sc-1\]\] '
}

# ask-stub: the read-only answer call. It records the prompt and what it was run with, and replies
# with $NOTES_FIXTURE/ask.out.
ask_stub() {
  printf '#!/usr/bin/env bash\necho "$*" >> "$NOTES_FIXTURE/ask.log"\ncat > "$NOTES_FIXTURE/ask-prompt.txt"\ncat "$NOTES_FIXTURE/ask.out" 2>/dev/null\n' >"$SANDBOX/bin/ask-stub"
  chmod +x "$SANDBOX/bin/ask-stub"
  export INBOX_ASK_CMD=ask-stub
}

@test "outbox: a #ask line is answered into today's notes inbox, leaves the outbox, files no row and starts no routing call" {
  sheet '' ''
  ask_stub
  printf '%s\n' 'INBOX-ANSWER-START' 'Yes, the mac is fine.' 'up 3 days, load 0.2' 'INBOX-ANSWER-END' >"$NOTES_FIXTURE/ask.out"
  outbox '- [ ] #ask is my mac ok? #p:scratch\n'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'moved 0 from the outbox, filed 0, left 0, refused 0, answered 1'
  run cat "$HOME/.notes/outbox.md"
  refute_output --partial 'mac'
  run cat "$HOME/.notes/lab/inbox/$(date +%F).md"
  assert_output --regexp '- [0-9]{2}:[0-9]{2} ask: is my mac ok\? - Yes, the mac is fine\.'
  assert_output --partial '  up 3 days, load 0.2'
  refute_output --partial '#ask'
  run tasks
  refute_output --partial 'mac'
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "the routing model was called for a lone question"
  grep -q 'Question: is my mac ok?' "$NOTES_FIXTURE/ask-prompt.txt" || fail "$(cat "$NOTES_FIXTURE/ask-prompt.txt")"
  grep -q 'Change nothing' "$NOTES_FIXTURE/ask-prompt.txt" || fail "the prompt never said read-only"
  grep -qx -- '-p' "$NOTES_FIXTURE/ask.log" || fail "$(cat "$NOTES_FIXTURE/ask.log")"
  grep -q WORKED "$HOME/.local/state/agentctl/inbox-triage/last-outcome"
}

@test "outbox: a tags-first #investigate line runs the longer look, its findings in today's notes inbox under its own word" {
  sheet '' ''
  ask_stub
  export INBOX_INVESTIGATE_CMD='ask-stub investigate'
  { echo INBOX-ANSWER-START; echo 'Disk 3 is resyncing.'; seq -f 'evidence %g' 1 14; echo INBOX-ANSWER-END; } >"$NOTES_FIXTURE/ask.out"
  outbox '- [ ] #p:scratch #high #investigate why is the nas slow\n'
  run "$TRIAGE" --dry-run
  assert_success
  assert_line 'would investigate [outbox] - [ ] #p:scratch #high #investigate why is the nas slow'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'answered 1'
  run cat "$HOME/.notes/lab/inbox/$(date +%F).md"
  assert_output --regexp '- [0-9]{2}:[0-9]{2} investigate: why is the nas slow - Disk 3 is resyncing\.'
  # negative control: a #ask reply stops at 12 lines, so line 14 is the longer look's alone
  assert_output --partial '  evidence 14'
  grep -qx -- 'investigate -p' "$NOTES_FIXTURE/ask.log" || fail "not the investigate call: $(cat "$NOTES_FIXTURE/ask.log")"
  grep -q 'Question: why is the nas slow' "$NOTES_FIXTURE/ask-prompt.txt" || fail "$(cat "$NOTES_FIXTURE/ask-prompt.txt")"
  grep -q 'the next step you would take' "$NOTES_FIXTURE/ask-prompt.txt" || fail "not the investigate prompt"
  grep -q 'Change nothing' "$NOTES_FIXTURE/ask-prompt.txt" || fail "the prompt never said read-only"
  run tasks
  refute_output --partial 'nas'
}

@test "outbox: a #ask line beside other lines never reaches the routing call, and --dry-run answers nothing" {
  sheet '' ''
  ask_stub
  printf '%s\n' 'INBOX-ANSWER-START' 'Fine.' 'INBOX-ANSWER-END' >"$NOTES_FIXTURE/ask.out"
  outbox '- [ ] is the nas up? #ask\n- [ ] stays for the model\n'
  answer '{"n": 1, "action": "skip", "why": "no project named"}'
  run "$TRIAGE" --dry-run
  assert_success
  assert_line 'would answer [outbox] - [ ] is the nas up? #ask'
  [ ! -e "$NOTES_FIXTURE/ask.log" ] || fail "a dry run called the model"
  run "$TRIAGE"
  assert_success
  assert_output --partial 'answered 1'
  grep -qx '1. \[outbox\] stays for the model' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  ! grep -q 'nas up' "$NOTES_FIXTURE/prompt.txt" || fail "the question was routed"
  run cat "$HOME/.notes/outbox.md"
  refute_output --partial 'nas up'
  assert_output --partial 'stays for the model'
}

@test "outbox: a #ask answer with no block leaves the line, recorded refused so the next sweep does not ask again" {
  sheet '' ''
  ask_stub
  printf 'no markers here\n' >"$NOTES_FIXTURE/ask.out"
  outbox '- [ ] #ask is my mac ok?\n'
  run "$TRIAGE"
  assert_failure
  run cat "$HOME/.notes/outbox.md"
  assert_output --partial '#ask is my mac ok?'
  [ ! -e "$HOME/.notes/lab/inbox/$(date +%F).md" ] || fail "an answer was written with no block"
  [ "$(wc -l <"$NOTES_FIXTURE/ask.log")" = 1 ] || fail "asked more than once in a sweep"
  run "$TRIAGE"
  [ "$(wc -l <"$NOTES_FIXTURE/ask.log")" = 1 ] || fail "the refused question was asked again"
}

@test "the area comes from the project's systems and an unlinked row goes under its standing epic" {
  systems ui:menu docs
  sheet '- the pause menu feels slow\n- the gun sound is off\n' ''
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the pause menu opens slowly #size/s"]}' \
    '{"n": 2, "action": "file", "rows": ["fix(audio): the gun sound is off #size/s"]}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 2, left 0, refused 0'
  grep -qx 'scratch: ui, docs (also: menu=ui)' "$NOTES_FIXTURE/prompt.txt" || fail "the systems never reached the model: $(cat "$NOTES_FIXTURE/prompt.txt")"
  run tasks
  assert_output --regexp 'epic\(ui\): ui to standard .*id:sc-1'
  assert_output --regexp 'fix\(ui\): the pause menu opens slowly .*#of/sc-1'
  # NEGATIVE CONTROL: an area that is no system stays unlinked.
  assert_output --regexp 'fix\(audio\): the gun sound is off [^<]*<!-- id:'
  refute_line --regexp 'gun sound is off .*#of/'
  [ "$(grep -c 'to standard' "$SHEET")" = 1 ] || fail "$(cat "$SHEET")"
}

@test "a new capability files its epic #new first and the rows under it; a bad epic is dropped, never the rows" {
  systems ui docs
  sheet '- a pause menu i can open mid match\n- make the credits roll\n' ''
  answer '{"n": 1, "action": "file", "rows": ["feat(ui): a pause menu with resume and quit #size/m"], "epic": "epic(ui): a pause menu the player can open mid-match"}' \
    '{"n": 2, "action": "file", "rows": ["feat(credits): roll the credits #size/s"], "epic": "epic(credits): credits that roll"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 2, left 0, refused 0'
  grep -q '"epic": "epic(<system>)' "$NOTES_FIXTURE/prompt.txt" || fail "the new-epic rule never reached the model"
  run tasks
  assert_output --regexp 'epic\(ui\): a pause menu the player can open mid-match .*#new.*id:sc-1'
  assert_output --regexp 'feat\(ui\): a pause menu with resume and quit .*#of/sc-1'
  refute_output --partial 'ui to standard'
  # credits is no system of scratch: no epic, the row filed as it came.
  refute_output --partial 'epic(credits)'
  assert_output --regexp 'feat\(credits\): roll the credits [^<]*<!-- id:'
  refute_line --regexp 'roll the credits .*#of/'
}

@test "--backlog: a rewrite may carry a new epic, filed #new before the row goes under it" {
  systems ui
  sheet '' '- [ ] pause menu #low <!-- id:sc-1 -->\n'
  answer '{"n": 1, "action": "rewrite", "row": "feat(ui): a pause menu with resume and quit #size/m", "epic": "epic(ui): a pause menu mid-match"}'
  run "$TRIAGE" --backlog --project scratch
  assert_success
  grep -qx 'scratch: ui' "$NOTES_FIXTURE/prompt.txt" || fail "the systems never reached the model"
  run tasks
  assert_output --regexp 'epic\(ui\): a pause menu mid-match .*#new.*id:sc-2'
  assert_output --regexp 'feat\(ui\): a pause menu with resume and quit .*#of/sc-2.*id:sc-1'
}

@test "--backlog --priority: each untagged row gets the model's priority through ptask tag, a tagged row is not asked, a bad answer writes nothing" {
  export INBOX_PRIORITY_CMD=model-stub
  sheet '' '- [ ] the save is slow <!-- id:sc-4 -->\n- [ ] the menu flickers #requested <!-- id:sc-5 -->\n- [ ] the jump is floaty <!-- id:sc-6 -->\n- [ ] the logo #low <!-- id:sc-7 -->\n'
  # a profile with automation = false: its rows never reach the model
  printf '[profile.gig]\nroot = "~/.notes/gig"\nautomation = false\n' >>"$HOME/.config/notes/config.toml"
  mkdir -p "$HOME/.notes/gig/projects/current/gp"
  : >"$HOME/.notes/gig/projects/current/gp/summary.md"
  printf '# gp\n\nVersion: v0.1.0\n\n## Tasks\n- [ ] the gig row <!-- id:gp-1 -->\n' >"$HOME/.notes/gig/projects/current/gp/README.md"
  gig_before="$(cat "$HOME/.notes/gig/projects/current/gp/README.md")"
  # rows reach the model in sheet order: sc-4, sc-5, sc-6
  answer '{"n": 1, "priority": "low"}' '{"n": 2, "priority": "high"}' '{"n": 3, "priority": "medium"}'
  # run from a session: the record still names inbox-priority, the lane judge-eval scores these by
  CLAUDE_CODE_SESSION_ID=feedface0123 run "$TRIAGE" --backlog --priority
  assert_success
  assert_output --partial 'priority: tagged 2, left 0, refused 0'
  run notes log --json --action tagged
  assert_equal "$(jq -sc 'map([.id, .by, .why])' <<<"$output")" '[["sc-4","inbox-priority","+#low"],["sc-5","inbox-priority","+#high"]]'
  grep -qx '2. \[sc-5\] the menu flickers #requested' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  refute grep -q 'logo\|gig row' "$NOTES_FIXTURE/prompt.txt"
  grep -q "red on main" "$NOTES_FIXTURE/prompt.txt" || fail "the rubric lost its red-on-main clause"
  grep -qF 'low: real work with a named benefit' "$NOTES_FIXTURE/prompt.txt" || fail "the priority pass lost the new low"
  grep -qF 'still tag it low here' "$NOTES_FIXTURE/prompt.txt" || fail "the priority pass does not say what to answer for a nice-to-have"
  # epic membership is no reason for high: every row has an epic, so it made most rows high (ar-2943)
  grep -q "Being filed under an open epic (#of/<epic id>) is not a reason" "$NOTES_FIXTURE/prompt.txt" || fail "the rubric lost its epic clause"
  refute grep -q "belongs to one of the open epics" "$NOTES_FIXTURE/prompt.txt"
  run tasks
  assert_output --regexp 'the save is slow .*#low.*id:sc-4'
  assert_output --regexp 'the menu flickers .*#high.*id:sc-5'
  assert_output --regexp '\[ \] the jump is floaty <!-- id:sc-6 -->'
  assert_equal "$(cat "$HOME/.notes/gig/projects/current/gp/README.md")" "$gig_before"
}

@test "--retag-high also asks the #high rows, and a new priority replaces the old one" {
  export INBOX_PRIORITY_CMD=model-stub
  sheet '' '- [ ] the save is slow #high <!-- id:sc-4 -->\n- [ ] the menu flickers #high <!-- id:sc-5 -->\n- [ ] the logo #low <!-- id:sc-7 -->\n'
  answer '{"n": 1, "priority": "high"}' '{"n": 2, "priority": "urgent"}'
  run "$TRIAGE" --backlog --priority --retag-high --project scratch
  assert_success
  assert_output --partial 'priority: tagged 1, left 0'
  refute grep -q 'logo' "$NOTES_FIXTURE/prompt.txt"
  run tasks
  assert_output --regexp 'the save is slow #high <!-- id:sc-4 -->'
  assert_output --regexp 'the menu flickers #urgent <!-- id:sc-5 -->'
  refute_output --partial 'flickers #high'
}

# NEGATIVE CONTROL: --priority alone would run the inbox sweep's model call; it is refused.
@test "--priority without --backlog is refused and asks no model" {
  run "$TRIAGE" --priority
  assert_failure 2
  assert_output --partial '--priority goes with --backlog'
  [ ! -e "$NOTES_FIXTURE/model.log" ]
}

@test "--backlog --size: each row with no points gets the model's points and their size band, a pointed row or an epic is not asked, an off-scale answer writes nothing" {
  export INBOX_SIZE_CMD=model-stub
  sheet '' '- [ ] epic(ui): menus #epic <!-- id:sc-3 -->\n- [ ] the save is slow #size/s <!-- id:sc-4 -->\n- [ ] the menu flickers <!-- id:sc-5 -->\n- [ ] the jump is floaty <!-- id:sc-6 -->\n- [ ] the logo #pts/2 #size/s <!-- id:sc-7 -->\n  - [ ] a child step <!-- id:sc-8 -->\n'
  # rows reach the model in sheet order: sc-4, sc-5, sc-6; a second answer for n 1 is ignored
  answer '{"n": 1, "pts": 5}' '{"n": 1, "pts": 1}' '{"n": 2, "pts": 13}' '{"n": 3, "pts": 4}'
  CLAUDE_CODE_SESSION_ID=feedface0123 run "$TRIAGE" --backlog --size --project scratch
  assert_success
  assert_output --partial 'size: scored 2, left 1, refused 0'
  run notes log --json --action tagged
  assert_equal "$(jq -sc 'map([.id, .by])' <<<"$output")" '[["sc-4","inbox-size"],["sc-5","inbox-size"]]'
  refute grep -q 'logo\|epic(ui)\|child step' "$NOTES_FIXTURE/prompt.txt"
  grep -q 'should be split' "$NOTES_FIXTURE/prompt.txt" || fail "the rubric never reached the model"
  run tasks
  assert_output --regexp 'the save is slow #pts/5 #size/m <!-- id:sc-4 -->'
  refute_output --partial 'slow #size/s'
  assert_output --regexp 'the menu flickers #pts/13 #size/l <!-- id:sc-5 -->'
  assert_output --regexp '\[ \] the jump is floaty <!-- id:sc-6 -->'
}

# NEGATIVE CONTROL: --size with --priority would run two passes' writes under one name; refused.
@test "--size without --backlog, or with --priority, is refused and asks no model" {
  run "$TRIAGE" --size
  assert_failure 2
  assert_output --partial '--size goes with --backlog'
  run "$TRIAGE" --backlog --size --priority
  assert_failure 2
  [ ! -e "$NOTES_FIXTURE/model.log" ]
}

@test "--backlog --link: each unparented row gets the model's system and epic, else its standing epic; a linked row or an epic is not asked" {
  export INBOX_PRIORITY_CMD=model-stub
  systems ui:menu docs
  sheet '' '- [ ] epic(ui): a pause menu mid-match <!-- id:sc-1 -->\n- [ ] fix(sound): resume flickers #size/s <!-- id:sc-2 -->\n- [ ] feat(menu): a quit button #size/s <!-- id:sc-3 -->\n- [ ] fix(ui): the logo blurs #size/s <!-- id:sc-4 -->\n- [ ] fix(ui): the menu lags #size/s #of/sc-1 <!-- id:sc-5 -->\n- [ ] fix(net): the lobby drops #size/s <!-- id:sc-6 -->\n'
  # rows reach the model in sheet order: sc-2, sc-3, sc-4, sc-6
  answer '{"n": 1, "system": "ui"}' '{"n": 2, "system": "docs", "of": "sc-1"}' '{"n": 3, "system": "ui", "of": "sc-99"}' '{"n": 4, "system": "netcode"}'
  run "$TRIAGE" --backlog --link --project scratch
  assert_success
  assert_output --partial 'link: feature 1, standing 2, new epics 0, left 1, refused 0'
  grep -qx 'scratch: ui, docs (also: menu=ui)' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  refute grep -q 'menu lags\|^[0-9]*\. \[sc-1\]' "$NOTES_FIXTURE/prompt.txt"
  run tasks
  # a free area becomes the system id and goes under the filed standing epic
  assert_output --regexp 'fix\(ui\): resume flickers #size/s #of/sc-7 <!-- id:sc-2 -->'
  assert_output --regexp 'epic\(ui\): ui to standard .*id:sc-7'
  # an alias area stays, and the open epic named is its parent
  assert_output --regexp 'feat\(menu\): a quit button #size/s #of/sc-1 <!-- id:sc-3 -->'
  # an epic id the board does not have falls back to the standing epic
  assert_output --regexp 'fix\(ui\): the logo blurs #size/s #of/sc-7 <!-- id:sc-4 -->'
  # NEGATIVE CONTROL: a system the project lacks leaves the row as it was
  assert_output --regexp '\[ \] fix\(net\): the lobby drops #size/s <!-- id:sc-6 -->'
}

@test "--backlog --link --dry-run writes nothing and keeps its answers; a second dry run and the apply reuse them with no model call" {
  export INBOX_PRIORITY_CMD=model-stub; link="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/inbox-triage"
  systems ui
  sheet '' '- [ ] fix(sound): resume flickers #size/s <!-- id:sc-2 -->\n- [ ] fix(ui): pause menu #size/m <!-- id:sc-3 -->\n'
  answer '{"n": 1, "system": "ui"}' '{"n": 2, "system": "ui", "epic": "epic(ui): a pause menu mid-match"}'
  before="$(cat "$SHEET")"
  run "$TRIAGE" --backlog --link --dry-run --project scratch
  assert_success
  assert_output --partial 'would run: notes ptask scratch --exact edit --link --text fix\(ui\):\ resume\ flickers\ #size/s'
  assert_output --partial 'link: feature 1, standing 1, new epics 1'
  assert_equal "$(cat "$SHEET")" "$before"
  [ "$(wc -l <"$link/link-scratch.jsonl")" = 2 ]
  # A second dry run (one stopped at its budget, say) resumes: its answers come from the cache.
  : >"$NOTES_FIXTURE/model.log"
  run "$TRIAGE" --backlog --link --dry-run --project scratch
  assert_success
  assert_output --partial 'link: feature 1, standing 1, new epics 1'
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the second dry run asked the model again"
  [ "$(wc -l <"$link/link-scratch.jsonl")" = 2 ]
  # A row filed after the dry run has no reviewed answer, so the apply leaves it unlinked.
  sed -i '/id:sc-3 -->/a - [ ] fix(ui): quit lags #size/s <!-- id:sc-1 -->' "$SHEET"
  answer '{"n": 1, "system": "docs"}'
  run "$TRIAGE" --backlog --link --project scratch
  assert_success
  assert_output --partial 'scratch (human): 1 rows new or changed since the dry run left as they are'
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the apply asked the model again"
  [ ! -e "$link/link-scratch.jsonl" ] || fail "the apply left its cache"
  run tasks
  assert_output --regexp 'fix\(ui\): resume flickers #size/s #of/sc-4 <!-- id:sc-2 -->'
  assert_output --regexp 'epic\(ui\): a pause menu mid-match .*#new.*id:sc-5'
  assert_output --regexp 'fix\(ui\): pause menu #size/m #of/sc-5 <!-- id:sc-3 -->'
  assert_output --partial '- [ ] fix(ui): quit lags #size/s <!-- id:sc-1 -->'
}

@test "--backlog --link counts a new epic once, a bad epic not at all, and leaves child rows and a tag-first row as they are" {
  export INBOX_PRIORITY_CMD=model-stub
  systems ui
  sheet '' '- [ ] feat(ui): pause menu #size/s <!-- id:sc-3 -->\n  - [ ] fix(ui): sub task <!-- id:sc-4 -->\n- [ ] fix(ui): resume button #size/s <!-- id:sc-5 -->\n- [ ] fix(ui): quit lags #size/s <!-- id:sc-6 -->\n- [ ] #high fix(sound): resume flickers <!-- id:sc-2 -->\n'
  answer '{"n": 1, "system": "ui", "epic": "epic(ui): a pause menu mid-match"}' '{"n": 2, "system": "ui", "epic": "epic(ui): a pause menu mid-match"}' \
    '{"n": 3, "system": "ui", "epic": "a pause menu"}' '{"n": 4, "system": "ui"}'
  run "$TRIAGE" --backlog --link --dry-run --project scratch
  assert_success
  assert_output --partial 'link: feature 2, standing 1, new epics 1'
  refute grep -q 'sub task' "$NOTES_FIXTURE/prompt.txt"
  run "$TRIAGE" --backlog --link --project scratch
  assert_success
  assert_output --partial 'link: feature 2, standing 1, new epics 1'
  run tasks
  [ "$(grep -c 'epic(ui): a pause menu mid-match' <<<"$output")" = 1 ] || fail "$output"
  assert_output --partial '  - [ ] fix(ui): sub task <!-- id:sc-4 -->'
  assert_output --partial '- [ ] #high fix(sound): resume flickers <!-- id:sc-2 -->'
  assert_output --regexp 'fix\(ui\): quit lags #size/s #of/sc-[0-9]+ <!-- id:sc-6 -->'
}

# A backlog past the 128 KB one argument holds: the rows and the cache must not go to jq as arguments.
@test "--backlog --link replays its cache for a backlog past 128 KB" {
  export INBOX_PRIORITY_CMD=model-stub; link="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}/inbox-triage"
  systems ui
  long="$(printf 'x%.0s' {1..70000})"
  sheet '' "- [ ] fix(ui): pause menu $long #size/s <!-- id:sc-2 -->\n"
  answer '{"n": 1, "system": "ui"}'
  run "$TRIAGE" --backlog --link --dry-run --project scratch
  assert_success
  : >"$NOTES_FIXTURE/model.log"
  run "$TRIAGE" --backlog --link --project scratch
  assert_success
  refute_output --partial 'Argument list too long'
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the apply asked the model again"
  run tasks
  assert_output --regexp 'fix\(ui\): pause menu x+ #size/s #of/sc-3 <!-- id:sc-2 -->'
}

# NEGATIVE CONTROL: --link alone would run the inbox sweep's model call; it is refused.
@test "--link without --backlog, or with --priority, is refused and asks no model" {
  run "$TRIAGE" --link
  assert_failure 2
  assert_output --partial '--link goes with --backlog'
  run "$TRIAGE" --backlog --priority --link
  assert_failure 2
  [ ! -e "$NOTES_FIXTURE/model.log" ]
}

# ask_setup: the real agent-ask against the sandbox's ask store, its judge and resume off, so a
# test reads the posted ask and answers it by hand.
ask_setup() {
  ln -sf "$AGENT_ASK" "$SANDBOX/bin/agent-ask"
  export AGENT_ASK_NO_JUDGE=1 AGENT_ASK_NO_RESUME=1
}
# the_ask: the one posted ask's file.
the_ask() { find "$HOME/.agent/asks" -name '*.md' -type f; }
# ask_about <words>: the id of the ask whose question holds <words>.
ask_about() { basename "$(grep -l "^question: .*$1" "$HOME"/.agent/asks/*/*.md)" .md; }

@test "outbox: a line the router cannot place asks the human which project, as an approval, once" {
  ask_setup
  sheet '' ''
  outbox '- [ ] the menu flickers after a match\n- [ ] the logo is too dark\n'
  answer '{"n": 1, "action": "ask", "projects": ["other", "nowhere", "scratch"], "why": "a menu is in both"}' \
    '{"n": 2, "action": "file", "rows": ["fix(brand): the logo is too dark #size/s"], "project": "other"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'asked you 1'
  grep -q 'ask: an \[outbox\] line that is a task, but neither it nor its neighbours say which project' "$NOTES_FIXTURE/prompt.txt" || fail "the ask action never reached the model"
  [ "$(the_ask | wc -l)" = 1 ] || fail "asks: $(the_ask)"
  f="$(the_ask)"
  grep -qx 'kind: approval' "$f" || fail "$(cat "$f")"
  grep -qx 'question: Which project is this outbox line for: "the menu flickers after a match"?' "$f" || fail "$(cat "$f")"
  # Only board projects, in the model's order, then drop.
  grep -qx 'options: other|scratch|drop' "$f" || fail "$(cat "$f")"
  grep -qx 'recommend: other' "$f" || fail "$(cat "$f")"
  grep -qx 'resume: run:agentctl-inbox-triage --answer' "$f" || fail "$(cat "$f")"
  grep -qx 'context: Your outbox line: the menu flickers after a match. Written after it: the logo is too dark. The projects it could go to: other scratch' "$f" || fail "$(cat "$f")"
  grep -q 'the menu flickers after a match' "$HOME/.notes/outbox.md" || fail "the asked line left the outbox"
  run jq -r 'select(.action == "asked") | [.from, .why, .text] | join(" ")' "$HOME/.local/state/notes/ingest.jsonl"
  assert_output "outbox $(basename "$f" .md) the menu flickers after a match"
  # The next sweep neither routes it again nor asks again.
  rm -f "$NOTES_FIXTURE/model.log"
  run "$TRIAGE"
  assert_success
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "an asked line was routed again: $(cat "$NOTES_FIXTURE/prompt.txt")"
  [ "$(the_ask | wc -l)" = 1 ] || fail "asked twice"
}

@test "outbox: the answer moves the asked line to its project, and the next sweep files it" {
  ask_setup
  sheet '' ''
  outbox '- [ ] the menu flickers after a match\n'
  answer '{"n": 1, "action": "ask", "projects": ["other", "scratch"], "why": "a menu is in both"}'
  run "$TRIAGE"
  assert_success
  id="$(basename "$(the_ask)" .md)"
  run agent-ask answer "$id" scratch
  assert_success
  run "$TRIAGE" --answer "$id"
  assert_success
  grep -q 'the menu flickers after a match' "$HOME/.notes/outbox.md" && fail "the line is still in the outbox"
  inbox | grep -q 'the menu flickers after a match' || fail "not in scratch's inbox: $(cat "$SHEET")"
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the menu flickers after a match #size/s"]}'
  run "$TRIAGE"
  assert_success
  grep -qx '1. \[scratch\] the menu flickers after a match' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  tasks | grep -q 'fix(ui): the menu flickers after a match' || fail "$(cat "$SHEET")"
}

@test "outbox: a drop answer takes the asked line out and files nothing; an answer naming no project leaves it" {
  ask_setup
  sheet '' ''
  outbox '- [ ] the menu flickers after a match\n- [ ] a note about lunch\n'
  answer '{"n": 1, "action": "ask", "projects": ["other", "scratch"], "why": "a menu is in both"}' \
    '{"n": 2, "action": "ask", "projects": ["scratch"], "why": "a guess"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'asked you 2'
  menu="$(ask_about 'menu flickers')" lunch="$(ask_about lunch)"
  agent-ask answer "$menu" drop
  run "$TRIAGE" --answer "$menu"
  assert_success
  grep -q 'menu flickers' "$HOME/.notes/outbox.md" && fail "a dropped line stayed"
  jq -e 'select(.action == "dropped" and .text == "the menu flickers after a match")' "$HOME/.local/state/notes/ingest.jsonl" >/dev/null || fail "no dropped record"
  agent-ask answer "$lunch" nowhere
  run "$TRIAGE" --answer "$lunch"
  assert_success
  grep -q 'a note about lunch' "$HOME/.notes/outbox.md" || fail "a line with no project left the outbox"
  jq -e 'select(.action == "left" and (.why | test("names no project")))' "$HOME/.local/state/notes/ingest.jsonl" >/dev/null || fail "not left with why"
  [ "$(grep -c 'id:' "$SHEET" "$PROJ/other/README.md" | awk -F: '{s += $2} END {print s}')" = 0 ] || fail "a row was filed"
}

@test "outbox: a line with a clear project asks nothing, and a project's inbox line never asks (negative control)" {
  ask_setup
  sheet '- the gun sound is off\n' ''
  outbox '- [ ] other needs a brand kit\n'
  answer '{"n": 1, "action": "file", "rows": ["feat(brand): a brand kit #size/l"], "project": "other"}' \
    '{"n": 2, "action": "ask", "projects": ["other"], "why": "unsure"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'asked you 0'
  [ -z "$(the_ask 2>/dev/null)" ] || fail "an ask was posted: $(the_ask)"
  inbox | grep -q 'the gun sound is off' || fail "the inbox line moved"
}

@test "outbox: over the per-sweep cap a line is held unrecorded, and the next sweep asks it" {
  ask_setup
  sheet '' ''
  outbox '- [ ] one thing\n- [ ] two thing\n'
  answer '{"n": 1, "action": "ask", "projects": ["other"], "why": "w"}' '{"n": 2, "action": "ask", "projects": ["scratch"], "why": "w"}'
  INBOX_ASK_PROJECT_MAX=1 run "$TRIAGE"
  assert_success
  assert_output --partial 'asked you 1'
  [ "$(the_ask | wc -l)" = 1 ] || fail "asks: $(the_ask)"
  [ "$(grep -c '"text":"two thing"' "$HOME/.local/state/notes/ingest.jsonl")" = 0 ] || fail "the held line was recorded: $(cat "$HOME/.local/state/notes/ingest.jsonl")"
  answer '{"n": 1, "action": "ask", "projects": ["scratch"], "why": "w"}'
  INBOX_ASK_PROJECT_MAX=1 run "$TRIAGE"
  assert_success
  grep -qx '1. \[outbox\] two thing' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  [ "$(the_ask | wc -l)" = 2 ] || fail "asks: $(the_ask)"
}

@test "outbox: --answer reads a project through punctuation and case, moves nothing under --dry-run, and needs an id" {
  ask_setup
  sheet '' ''
  outbox '- [ ] the menu flickers after a match\n'
  answer '{"n": 1, "action": "ask", "projects": ["other", "scratch"], "why": "w"}'
  run "$TRIAGE"
  id="$(basename "$(the_ask)" .md)"
  run "$TRIAGE" --dry-run --answer "$id"
  assert_failure
  assert_output --partial 'no answer yet'
  agent-ask answer "$id" 'Scratch, the menu one'
  run "$TRIAGE" --dry-run --answer "$id"
  assert_success
  assert_output --partial 'would move [outbox -> scratch]'
  grep -q 'menu flickers' "$HOME/.notes/outbox.md" || fail "a dry run moved the line"
  run "$TRIAGE" --answer
  assert_failure 2
  run "$TRIAGE" --answer "$id"
  assert_success
  inbox | grep -q 'the menu flickers after a match' || fail "$(cat "$SHEET")"
}

# A session's follow-up (`#from/<writer>`) is never filed with no model: the model sees the open
# rows closest to it, a repeat joins its twin, a skip leaves the line, and a row is not #requested.
@test "session line: a typed one goes to the model with its closest rows, joins its twin as a dup, and is not #requested" {
  sheet '- [ ] fix(ui): the pause menu flickers on resume #agent #from/ab12cd34\n' '- [ ] fix(ui): the pause menu flickers when resuming <!-- id:sc-4 -->\n- [ ] fix(audio): the volume slider is stuck <!-- id:sc-5 -->\n'
  answer '{"n": 1, "action": "dup", "id": "sc-4", "why": "same flicker"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 1'
  [ -s "$NOTES_FIXTURE/model.log" ] || fail "a typed session line took the no-model path"
  grep -qE '^1	sc-4	[0-9]+	human	fix\(ui\): the pause menu flickers when resuming' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  grep -q 'Closest open rows to each inbox line' "$NOTES_FIXTURE/prompt.txt"
  run grep -c 'volume slider' "$NOTES_FIXTURE/prompt.txt"
  assert_output 0   # the unrelated row is not in the model's view
  run inbox
  refute_output --partial 'flickers'
  grep -q '  was: fix(ui): the pause menu flickers on resume #agent #from/ab12cd34' "$SHEET" || fail "$(cat "$SHEET")"
  [ "$(grep -c 'pause menu' "$SHEET")" = 2 ] || fail "a row was filed: $(cat "$SHEET")"
}

# The person's own inbox line is shown its closest rows too, never its project's whole board,
# which on a large board costs more than the sweep's day budget.
@test "inbox line: an untyped one is shown its closest rows, not every open row of its project" {
  sheet '- the pause menu flickers on resume\n' '- [ ] fix(ui): the pause menu flickers when resuming <!-- id:sc-4 -->\n- [ ] fix(audio): the volume slider is stuck <!-- id:sc-5 -->\n'
  answer '{"n": 1, "action": "dup", "id": "sc-4", "why": "same flicker"}'
  run "$TRIAGE"
  assert_success
  grep -qE '^1	sc-4	[0-9]+	human	fix\(ui\): the pause menu flickers when resuming' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  run grep -c 'volume slider' "$NOTES_FIXTURE/prompt.txt"
  assert_output 0   # the unrelated row is not in the model's view
  refute grep -q 'A line tagged #from/<writer>' "$NOTES_FIXTURE/prompt.txt"   # the session rule stays off for the person's line
  grep -q '  was: the pause menu flickers on resume' "$SHEET" || fail "$(cat "$SHEET")"
}

@test "inbox line: beside an outbox line, the outbox still lists the newest rows and the inbox line its closest" {
  sheet '- the pause menu flickers on resume\n' '- [ ] fix(ui): the pause menu flickers when resuming <!-- id:sc-4 -->\n- [ ] fix(audio): the volume slider is stuck <!-- id:sc-5 -->\n'
  outbox '- [ ] add a credits screen\n'
  answer '{"n": 1, "action": "skip", "why": "no project named"}' '{"n": 2, "action": "dup", "id": "sc-4", "why": "same flicker"}'
  run "$TRIAGE"
  assert_success
  grep -qx 'sc-5	scratch	human	fix(audio): the volume slider is stuck' "$NOTES_FIXTURE/prompt.txt" || fail "the outbox line lost the newest rows: $(cat "$NOTES_FIXTURE/prompt.txt")"
  grep -qE '^[0-9]+	sc-4	[0-9]+	human	fix\(ui\): the pause menu flickers when resuming' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
}

@test "session line: with no twin it files on the agent board without #requested, while a human line beside it still gets it" {
  sheet '- [ ] fix(ui): the pause menu flickers on resume #agent #from/ab12cd34\n- the gun sound is off\n' '- [ ] fix(audio): the volume slider is stuck <!-- id:sc-5 -->\n'
  answer '{"n": 1, "action": "file", "rows": ["fix(ui): the pause menu flickers on resume #low #size/s"], "lane": "agent"}' \
    '{"n": 2, "action": "file", "rows": ["fix(audio): the gun sound plays late #high #size/s"], "lane": "agent"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 2'
  agent="$PROJ/scratch/agent/README.md"
  grep -E 'pause menu flickers' "$agent" | grep -vq '#requested' || fail "a session row was stamped: $(cat "$agent")"
  grep -qE 'gun sound plays late .*#requested' "$agent" || fail "the human row lost its stamp: $(cat "$agent")"
  [ "$(jq -r 'select(.action == "filed" and (.text | test("#from/"))) | .want // "none"' "$HOME/.local/state/notes/ingest.jsonl")" = none ] || fail "a session filing named a channel"
}

@test "session line: a skip removes it with its reason as dropped; a human line the model skips stays (negative control)" {
  sheet '- [ ] chore(x): a note to self about nothing #from/ab12cd34\n- maybe the boss is too easy?\n' ''
  answer '{"n": 1, "action": "skip", "why": "asks for no work"}' '{"n": 2, "action": "skip"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'dropped 1'
  run inbox
  refute_output --partial 'note to self'
  assert_output --partial 'maybe the boss is too easy?'
  run jq -r 'select(.action == "dropped") | .action + " | " + .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'dropped | model: asks for no work'
  # a second sweep asks nothing: the dropped line is gone and the human one is recorded left
  run "$TRIAGE"
  assert_success
  [ "$(wc -l <"$NOTES_FIXTURE/model.log")" = 1 ] || fail "the model was asked again"
}

@test "session line: one in the outbox that the model skips leaves the outbox, recorded dropped" {
  sheet '' ''
  outbox '- [ ] chore(x): a note to self about nothing #from/ab12cd34\n- [ ] a human thought\n'
  answer '{"n": 1, "action": "skip", "why": "no work"}' '{"n": 2, "action": "skip"}'
  run "$TRIAGE"
  assert_success
  run cat "$HOME/.notes/outbox.md"
  refute_output --partial 'note to self'
  assert_output --partial 'a human thought'
  run jq -r 'select(.action == "dropped") | .from + " | " + .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'outbox | model: no work'
}

@test "session line: --dry-run says what it would drop and file, and writes nothing" {
  sheet '- [ ] chore(x): a note to self about nothing #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "skip", "why": "no work"}'
  cp "$SHEET" "$BATS_TEST_TMPDIR/before"
  run "$TRIAGE" --dry-run
  assert_success
  assert_output --partial 'would drop [scratch]'
  diff "$SHEET" "$BATS_TEST_TMPDIR/before" || fail "a dry run wrote"
}

@test "session line: a notes with no similar verb asks no model and leaves the line" {
  sheet '- [ ] fix(ui): the pause menu flickers #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "skip"}'
  rm -f "$SANDBOX/bin/notes"
  printf '#!/usr/bin/env bash\n[ "$3" = similar ] && exit 2\n[ "$4" = similar ] && exit 2\nexec "%s" "$@"\n' "$NOTES_BIN" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$TRIAGE"
  assert_failure
  assert_output --partial 'notes ptask similar failed'
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "the model was asked with no candidates"
  run inbox
  assert_output --partial 'pause menu flickers'
}

@test "session line: an improvement verdict keeps it in improvements.md, files no row, and leaves ideas.md byte for byte" {
  printf '# scratch - ideas\n\nmine, by hand\n' >"$PROJ/scratch/ideas.md"
  cp "$PROJ/scratch/ideas.md" "$BATS_TEST_TMPDIR/ideas.before"
  sheet '- [ ] chore(ui): a nicer empty state for the lobby #agent #from/ab12cd34\n' ''
  outbox '- [ ] chore(x): could also colour the log lines #from/ab12cd34 #p:other\n'
  # the outbox line is numbered first, then the inbox's
  answer '{"n": 1, "action": "improvement", "project": "other", "why": "could also"}' \
    '{"n": 2, "action": "improvement", "project": "scratch", "why": "polish nobody asked for"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'improvements 2'
  assert_output --partial 'filed 0'
  run inbox
  refute_output --partial 'empty state'
  run tasks
  refute_output --partial 'empty state'
  run grep -c 'could also' "$HOME/.notes/outbox.md"
  assert_output 0
  run cat "$PROJ/scratch/improvements.md"
  assert_output --partial '# scratch - improvements'
  assert_output --partial '- chore(ui): a nicer empty state for the lobby ('
  refute_output --partial '#from/'
  run cat "$PROJ/other/improvements.md"
  assert_output --partial '- chore(x): could also colour the log lines ('
  cmp "$PROJ/scratch/ideas.md" "$BATS_TEST_TMPDIR/ideas.before" || fail "ideas.md changed"
  [ ! -e "$PROJ/other/ideas.md" ] || fail "an ideas.md was made"
  run jq -r 'select(.action == "improvement") | .to + " | " + .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'scratch | model: polish nobody asked for'
  assert_line 'other | model: could also'
  run jq -r 'select(.action == "dropped") | .from + " | " + .why' "$HOME/.local/state/notes/ingest.jsonl"
  assert_line 'scratch | improvement: kept in scratch improvements.md'
  grep -q 'improvements 2' "$HOME/.local/state/agentctl/inbox-triage/activity.log" || fail "no improvements count in the activity log"
}

@test "session line: the same line with a file verdict still files a row, and no improvements.md appears (negative control)" {
  sheet '- [ ] chore(ui): a nicer empty state for the lobby #agent #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "file", "rows": ["chore(ui): a nicer empty state for the lobby #low #size/s"], "lane": "agent"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'filed 1'
  assert_output --partial 'improvements 0'
  [ ! -e "$PROJ/scratch/improvements.md" ] || fail "improvements.md was written"
  grep -q 'empty state' "$PROJ/scratch/agent/README.md" || fail "no row"
}

@test "improvement verdict: a person's line, and a project not on the board, stay where they are (negative controls)" {
  sheet '- the lobby could use a nicer empty state\n- [ ] chore(x): another #agent #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "improvement", "project": "scratch", "why": "polish"}' \
    '{"n": 2, "action": "improvement", "project": "nosuch", "why": "polish"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'improvements 0'
  run inbox
  assert_output --partial 'nicer empty state'
  assert_output --partial 'another'
  [ ! -e "$PROJ/scratch/improvements.md" ] || fail "improvements.md was written"
}

@test "improvement verdict: a failed write leaves the line and records no refusal, so the next sweep retries it" {
  sheet '- [ ] chore(ui): a nicer empty state #agent #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "improvement", "project": "scratch", "why": "polish"}'
  # a directory where improvements.md belongs makes notes improve fail
  mkdir "$PROJ/scratch/improvements.md"
  run "$TRIAGE"
  assert_output --partial 'improvements 0'
  run inbox
  assert_output --partial 'nicer empty state'
  run jq -r 'select(.action == "refused" or .action == "left") | .text' "$HOME/.local/state/notes/ingest.jsonl"
  refute_output --partial 'empty state'
  # fixed, the same line goes through on the next sweep
  rmdir "$PROJ/scratch/improvements.md"
  run "$TRIAGE"
  assert_success
  assert_output --partial 'improvements 1'
  run inbox
  refute_output --partial 'empty state'
  grep -q 'nicer empty state' "$PROJ/scratch/improvements.md" || fail "not kept"
}

@test "improvement verdict: --dry-run says what it would keep and writes nothing" {
  sheet '- [ ] chore(ui): a nicer empty state #agent #from/ab12cd34\n' ''
  answer '{"n": 1, "action": "improvement", "project": "scratch", "why": "polish"}'
  cp "$SHEET" "$BATS_TEST_TMPDIR/before"
  run "$TRIAGE" --dry-run
  assert_success
  assert_output --partial 'would improve [scratch -> scratch]'
  diff "$SHEET" "$BATS_TEST_TMPDIR/before" || fail "a dry run wrote"
  [ ! -e "$PROJ/scratch/improvements.md" ] || fail "a dry run wrote improvements.md"
}

@test "the priority rubric: low is real work with a named benefit, a nice-to-have is an improvement, on the route call and the priority pass alike" {
  sheet '- the gun sound is off\n' ''
  answer '{"n": 1, "action": "skip"}'
  run "$TRIAGE"
  grep -qF 'low: real work with a named benefit' "$NOTES_FIXTURE/prompt.txt" || fail "the route call lost the new low"
  grep -qF 'is an improvement, and it is kept in the project' "$NOTES_FIXTURE/prompt.txt" || fail "the route call lost the improvement rule"
  grep -qF 'improvement: only for a line tagged #from/' "$NOTES_FIXTURE/prompt.txt" || fail "the improvement action is not offered"
  ! grep -qF 'including ideas, polish' "$NOTES_FIXTURE/prompt.txt" || fail "the old catch-all low is back"
}

# An epic proposal: an unattended writer's `epic(` add reaches the outbox as a session line
# (`notes ptask add` exits 4), and triage alone decides it, through epic_new and the CLI's checks.
# propose <epic text>: the add a queue item makes, so the outbox line is the writer's own.
propose() {
  run env AGENT_QUEUE_ITEM=fix-x CLAUDE_CODE_SESSION_ID= AGENTCTL_NAME= notes ptask scratch add -- "$1"
  assert_failure 4
}
events() { jq -r 'select(.action == "dup" or .action == "filed" or .action == "dropped" or .action == "refused" or .action == "left") | .action + " | " + (.id // "-") + " | " + (.why // "") + " | " + .text' "$HOME/.local/state/notes/ingest.jsonl"; }

@test "epic proposal: a file verdict files it #new through epic_new, the line joins it, and #plan/ is on the verdict's event" {
  systems ui
  sheet '' '- [ ] fix(ui): the pause menu flickers <!-- id:sc-4 -->\n'
  propose 'epic(ui): a pause menu the player can open mid-match #plan/pause-menu'
  grep -q '#p:scratch #from/fix-x epic(ui): a pause menu' "$HOME/.notes/outbox.md" || fail "$(cat "$HOME/.notes/outbox.md")"
  answer '{"n": 1, "action": "file", "rows": ["epic(ui): a pause menu the player can open mid-match #high"], "why": "new capability"}'
  run "$TRIAGE"
  assert_success
  grep -qF 'is a proposed epic, not a row' "$NOTES_FIXTURE/prompt.txt" || fail "the proposal rule never reached the model"
  grep -qE 'never asked about\.$' "$NOTES_FIXTURE/prompt.txt" && grep -qE 'always says why\.$' "$NOTES_FIXTURE/prompt.txt" || fail "a session paragraph ends in a stray quote"
  run tasks
  assert_output --regexp 'epic\(ui\): a pause menu the player can open mid-match #new.*id:sc-[0-9]+'
  refute_output --partial '#high'
  assert_output --partial '  was: #from/fix-x epic(ui): a pause menu the player can open mid-match #plan/pause-menu'
  [ "$(grep -c 'epic(ui): a pause menu' "$SHEET")" = 2 ] || fail "one epic and its was: line: $(cat "$SHEET")"
  eid="$(grep -o 'epic(ui): a pause menu the player.*id:sc-[0-9]*' "$SHEET" | grep -o 'sc-[0-9]*$')"
  run inbox
  refute_output --partial 'pause menu'
  run events
  assert_line --regexp "^dup \| $eid \| epic proposal: filed as new epic $eid; model: new capability \| .*#plan/pause-menu"
  run notes log --trace '#plan/pause-menu'
  assert_success
  assert_output --partial "$eid"
}

@test "epic proposal: one an open epic already covers joins its twin, and a system that is none of the project's is refused and stays" {
  systems ui
  sheet '' '- [ ] epic(ui): a pause menu the player can open mid-match <!-- id:sc-7 -->\n'
  propose 'epic(ui): stop a running game to rest #plan/again'
  propose 'epic(audio): a mixer the player can tune #plan/mixer'
  answer '{"n": 1, "action": "file", "rows": ["epic(ui): a pause menu the player can open mid-match"], "why": "new"}' \
    '{"n": 2, "action": "file", "rows": ["epic(audio): a mixer the player can tune"], "why": "new"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'refused 1'
  [ "$(grep -c '^- \[ \] epic(' "$SHEET")" = 1 ] || fail "a second epic was filed: $(cat "$SHEET")"
  run events
  assert_line --regexp '^dup \| sc-7 \| epic proposal: twin of open epic sc-7; model: new \| .*#plan/again'
  assert_line --regexp '^refused \| - \| epic proposal not filed: epic\(audio\) names no system of scratch.* \| .*#plan/mixer'
  run inbox
  assert_output --partial 'a mixer the player can tune'
  refute_output --partial 'pause menu'
}

@test "epic proposal: dup joins the open epic it names; a dup of a row that is no epic leaves the line (negative control)" {
  systems ui
  sheet '' '- [ ] epic(ui): menus the player can open <!-- id:sc-7 -->\n- [ ] fix(ui): the pause menu flickers <!-- id:sc-4 -->\n'
  propose 'epic(ui): a pause menu mid-match #plan/dup-ok'
  propose 'epic(ui): a settings menu mid-match #plan/dup-bad'
  answer '{"n": 1, "action": "dup", "id": "sc-7", "why": "menus covers it"}' '{"n": 2, "action": "dup", "id": "sc-4", "why": "same menu"}'
  run "$TRIAGE"
  assert_success
  run events
  assert_line --regexp '^dup \| sc-7 \| epic proposal: joins open epic sc-7; model: menus covers it \| .*#plan/dup-ok'
  assert_line --regexp '^left \| - \| dup of sc-4, which is no open epic \| .*#plan/dup-bad'
  grep -q '  was: #from/fix-x epic(ui): a pause menu mid-match #plan/dup-ok' "$SHEET" || fail "$(cat "$SHEET")"
  run inbox
  assert_output --partial 'a settings menu mid-match'
  [ "$(grep -c '^- \[ \] epic(' "$SHEET")" = 1 ] || fail "an epic was filed: $(cat "$SHEET")"
}

@test "epic proposal: skip and improvement drop it with their why and #plan/ on the event; a skip with no why stays" {
  systems ui
  sheet '' ''
  propose 'epic(ui): fix the flicker #plan/skip-me'
  propose 'epic(ui): a nicer lobby colour #plan/improve-me'
  propose 'epic(ui): a lobby the player can browse #plan/no-why'
  answer '{"n": 1, "action": "skip", "why": "a fix, not an outcome"}' \
    '{"n": 2, "action": "improvement", "project": "scratch", "why": "polish nobody asked for"}' \
    '{"n": 3, "action": "skip"}'
  run "$TRIAGE"
  assert_success
  assert_output --partial 'dropped 1'
  assert_output --partial 'improvements 1'
  run events
  assert_line --regexp '^dropped \| - \| model: a fix, not an outcome \| .*#plan/skip-me'
  assert_line --regexp '^dropped \| - \| improvement: kept in scratch improvements.md \| .*#plan/improve-me'
  assert_line --regexp '^left \| - \| skip of an epic proposal with no why \| .*#plan/no-why'
  grep -q 'a nicer lobby colour' "$PROJ/scratch/improvements.md" || fail "not kept"
  run inbox
  assert_output --partial 'a lobby the player can browse'
  refute_output --partial 'flicker'
  refute grep -q '^- \[ \] epic(' "$SHEET"
}

@test "epic proposal: --dry-run says it would file the epic and join the line, and writes nothing" {
  systems ui
  sheet '' ''
  outbox '- [ ] #from/fix-x epic(ui): a pause menu mid-match #plan/dry\n'
  answer '{"n": 1, "action": "file", "project": "scratch", "rows": ["epic(ui): a pause menu mid-match"], "why": "new"}'
  cp "$HOME/.notes/outbox.md" "$BATS_TEST_TMPDIR/outbox.before"
  cp "$SHEET" "$BATS_TEST_TMPDIR/before"
  run "$TRIAGE" --dry-run
  assert_success
  assert_output --partial "would run: notes ptask scratch add -- epic\(ui\):\ a\ pause\ menu\ mid-match\ #new"
  assert_output --regexp 'would file \[scratch\] .*--dup \\<the\\ new\\ epic\\>'
  diff "$SHEET" "$BATS_TEST_TMPDIR/before" || fail "a dry run wrote"
  diff "$HOME/.notes/outbox.md" "$BATS_TEST_TMPDIR/outbox.before" || fail "a dry run moved"
}
