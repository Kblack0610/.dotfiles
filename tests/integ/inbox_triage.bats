#!/usr/bin/env bats
# agentctl-inbox-triage: inbox lines become typed rows, through `notes ptask file` only.
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
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\nprintf "%%s\\n" "$2" > "$NOTES_FIXTURE/prompt.txt"\ncat "$NOTES_FIXTURE/model.out" 2>/dev/null\n' >"$SANDBOX/bin/model-stub"
  chmod +x "$SANDBOX/bin/model-stub"
}

# sheet <inbox lines> <task lines>: scratch's sheet.
sheet() { printf '# scratch\n\nVersion: v0.1.0\n\n## Inbox\n%b\n## Tasks\n%b\n' "$1" "$2" >"$SHEET"; }
# answer <json line>...: what the model replies.
answer() { { echo INBOX-TRIAGE-START; printf '%s\n' "$@"; echo INBOX-TRIAGE-END; } >"$NOTES_FIXTURE/model.out"; }
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
  grep -qx '1. the gun sound is off since the top-down patch' "$NOTES_FIXTURE/prompt.txt" || fail "the line never reached the model"
  [ -f "$HOME/.local/state/agentctl/inbox-triage/last-outcome" ] || fail "no proof published"
  grep -q WORKED "$HOME/.local/state/agentctl/inbox-triage/last-outcome"
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
  sheet '' '- [ ] the menu flickers on resize #ask #high <!-- id:sc-4 -->\n- [ ] menu flicker again <!-- id:sc-5 -->\n- [ ] other needs a logo <!-- id:sc-6 -->\n- [ ] scratch <!-- id:sc-7 -->\n- [/] the save is slow <!-- id:sc-8 -->\n'
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
  assert_output --regexp '- \[ \] fix\(ui\): the menu flickers on resize #size/s #ask .*#high.*id:sc-4'
  assert_output --partial '  was: the menu flickers on resize #ask'
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
