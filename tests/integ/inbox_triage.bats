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
  export INBOX_TRIAGE_CMD=model-stub
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\ncat > "$NOTES_FIXTURE/prompt.txt"\ncat "$NOTES_FIXTURE/model.out" 2>/dev/null\n' >"$SANDBOX/bin/model-stub"
  chmod +x "$SANDBOX/bin/model-stub"
  # The planner's start, recorded: no unit ever starts from a test.
  printf '#!/usr/bin/env bash\necho "$*" >> "$NOTES_FIXTURE/systemctl.log"\n' >"$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/systemctl"
}

# sheet <inbox lines> <task lines>: scratch's sheet.
sheet() { printf '# scratch\n\nVersion: v0.1.0\n\n## Inbox\n%b\n## Tasks\n%b\n' "$1" "$2" >"$SHEET"; }
# answer <json line>...: what the model replies.
answer() { { echo INBOX-TRIAGE-START; printf '%s\n' "$@"; echo INBOX-TRIAGE-END; } >"$NOTES_FIXTURE/model.out"; }
outbox() { printf '# Outbox\n\n## Outbox\n%b' "$1" >"$HOME/.notes/outbox.md"; }
inbox() { sed -n '/^## Inbox/,/^## Tasks/p' "$SHEET"; }
tasks() { sed -n '/^## Tasks/,$p' "$SHEET"; }

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
  inbox | grep -q 'the gun sound is off'
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
  assert_output --regexp '- \[x\] menu flicker again .*dup:sc-4'
  assert_output --regexp '- \[x\] scratch .*dropped: triage: a header, not a task'
  assert_output --partial '- [/] the save is slow <!-- id:sc-8 -->'
  refute_output --partial 'logo'
  # rewritten, then moved by its id, its old words with it
  grep -q 'feat(brand): a logo #size/s.*id:sc-6' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
  grep -qx '  was: other needs a logo' "$PROJ/other/README.md" || fail "$(cat "$PROJ/other/README.md")"
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

@test "outbox: a #p: line moves and files with no model, and the inbox page says where it went" {
  sheet '' ''
  mkdir -p "$HOME/.notes/lab/inbox"   # the capture inbox: a machine without one publishes no page
  outbox '- [ ] chore(build): drop the old cache #low #p:scratch\n- [ ] stays for the model\n'
  answer '{"n": 1, "action": "skip", "why": "no project named"}'
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
  assert_output --partial 'triage kept 1 of 1 as filed (7d)'
  grep -q '"row":"chore(build): drop the old cache"' "$HOME/.local/state/notes/ingest.jsonl" || fail "the filed row's words were not recorded"
}

@test "outbox: an <id>: line answers its open row with no model, closing a decide row; an id with no open row is left" {
  sheet '' '- [ ] decide(squad): followers that fight with you #low <!-- id:sc-1 -->\n- [ ] feat(ui): a colour for the squad <!-- id:sc-2 -->\n'
  mkdir -p "$PROJ/scratch/agent"
  printf '# scratch agent\n\n## Tasks\n- [ ] decide(lanes): which lane a game takes <!-- id:sc-3 -->\n' >"$PROJ/scratch/agent/README.md"
  outbox '- [ ] sc-1: yes, build it after the bully fix\n- [ ] sc-2: the blue one\n- [ ] sc-3: the agent lane\n- [ ] zz-9: yes\n- [ ] stays for the model\n'
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
