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
  st="$HOME/.local/state/agentctl/inbox-triage"
  grep -qx BLOCKED "$st/last-outcome"
  grep -q 'outcome=BLOCKED budget: backlog: ' "$st/activity.log" || fail "$(cat "$st/activity.log")"
  # negative control: an exit that is not the budget's is still a failed pass
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/model-stub"
  run "$TRIAGE" --backlog
  assert_failure 1
  grep -qx FAILED "$st/last-outcome"
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
  run tasks
  assert_output --partial '  - [ ] step two'
}

@test "the lane rule names the projects an untagged agent worker takes, and only with such a worker" {
  sheet '- the gun sound is off\n' ''
  answer '{"n": 1, "action": "skip", "why": "test"}'
  run "$TRIAGE"
  refute_output --partial 'failed'
  run grep -c 'agents do the work unattended' "$NOTES_FIXTURE/prompt.txt"
  assert_output 0
  echo '{"board": {"lane": "agent", "untagged": true, "projects": ["scratch"]}, "x": {"projects": ["other"]}}' >"$SANDBOX/w.json"
  export DISPATCH_WORKERS="$SANDBOX/w.json"
  rm -f "$HOME/.local/state/notes/ingest.jsonl"
  run "$TRIAGE"
  run grep -o 'lane is agent unless a step needs a person.*: scratch\.' "$NOTES_FIXTURE/prompt.txt"
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
  answer '{"n": 1, "action": "file", "rows": ["fix(audio): the gun sound plays late #high #size/s"], "lane": "agent"}' \
    '{"n": 2, "action": "file", "rows": ["fix(ui): the menu is slow #high #size/s"]}'
  run "$TRIAGE"
  assert_success
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
  ! grep -q '"action":"sweep-stopped"' "$HOME/.local/state/notes/ingest.jsonl" || fail "a clean sweep recorded a stop"
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
  assert_output --partial 'but a line that plainly fits another project'
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
  run "$TRIAGE" --backlog --priority
  assert_success
  assert_output --partial 'priority: tagged 2, left 0, refused 0'
  grep -qx '2. \[sc-5\] the menu flickers #requested' "$NOTES_FIXTURE/prompt.txt" || fail "$(cat "$NOTES_FIXTURE/prompt.txt")"
  refute grep -q 'logo\|gig row' "$NOTES_FIXTURE/prompt.txt"
  grep -q "red on main" "$NOTES_FIXTURE/prompt.txt" || fail "the rubric lost its red-on-main clause"
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
  answer '{"n": 1, "system": "docs"}'
  run "$TRIAGE" --backlog --link --project scratch
  assert_success
  [ ! -s "$NOTES_FIXTURE/model.log" ] || fail "the apply asked the model again"
  [ ! -e "$link/link-scratch.jsonl" ] || fail "the apply left its cache"
  run tasks
  assert_output --regexp 'fix\(ui\): resume flickers #size/s #of/sc-4 <!-- id:sc-2 -->'
  assert_output --regexp 'epic\(ui\): a pause menu mid-match .*#new.*id:sc-5'
  assert_output --regexp 'fix\(ui\): pause menu #size/m #of/sc-5 <!-- id:sc-3 -->'
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
