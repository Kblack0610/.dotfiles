#!/usr/bin/env bats
# The link between the two views.
#
# `tasks` is your task sheet and `bridge` is the agent queue. They are SEPARATE surfaces on
# purpose — the human lane must stay usable without knowing anything about agents. But a
# wave that stops to ask you something is genuinely both: an item on your list and a
# question in the queue. A `<!-- ask:<id> -->` stamp on the sheet line is the join.
#
# Without it the links ran one way only — the board named the sheet, the ask named the
# board, and the sheet named nothing — so a scoped, blocked wave showed up on the human's
# own list as three ordinary unchecked boxes, and the only evidence lived in a view they
# were not standing in.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  cat > "$SANDBOX/bin/agent-notify" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/agent-notify"
  SHEET="$SANDBOX/sheet.md"
  export SHEET
}

gate() {
  "$AGENT_ASK" post --project alpha --kind gate \
    --options 'approve|hold|cancel' --resume '/wave alpha start' \
    'Create the 3 tickets and cut the branch?'
}

row() { # $1=rawtext -> the rendered row
  bash -c 'source "$COCKPIT"; _task_row personal "$1" 3 k1 personal/alpha "$2"' _ "$SHEET" "$1"
}

# ── rendering ────────────────────────────────────────────────────────────────

@test "an untagged human line is untouched by any of this" {
  run row '- [ ] call the attorney re the BAA'
  assert_output --partial '[ ]'
  refute_output --partial 'needs you'
  refute_output --partial '[!]'
}

@test "an #ai line with no stamp is an ordinary unchecked item" {
  run row '- [ ] ALW search #ai'
  assert_output --partial '[ ]'
  refute_output --partial 'needs you'
}

@test "an #ai line stamped with a PENDING gate reads as needing you" {
  local id; id="$(gate)"
  run row "- [ ] ALW search #ai <!-- ask:$id -->"
  assert_output --partial '[!]'
  assert_output --partial 'needs you'
}

@test "the gate row carries the answer vocabulary, so the choice is on screen" {
  local id; id="$(gate)"
  run row "- [ ] ALW search #ai <!-- ask:$id -->"
  assert_output --partial 'approve|hold|cancel'
}

@test "the stamp itself never leaks into the display text" {
  local id; id="$(gate)"
  run row "- [ ] ALW search #ai <!-- ask:$id -->"
  refute_output --partial '<!--'
  refute_output --partial "ask:$id"
  assert_output --partial 'ALW search'
}

# A wave that dies between the human answering and the sheet being re-stamped would leave
# a stamp pointing at a settled question. Offering to answer it again is worse than useless:
# the second answer goes nowhere and looks like it worked.
@test "a stamp pointing at an ANSWERED ask renders as an ordinary item" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run row "- [ ] ALW search #ai <!-- ask:$id -->"
  assert_output --partial '[ ]'
  refute_output --partial 'needs you'
}

@test "a stamp pointing at a CANCELLED ask renders as an ordinary item" {
  local id; id="$(gate)"
  "$AGENT_ASK" cancel "$id" >/dev/null 2>&1
  run row "- [ ] ALW search #ai <!-- ask:$id -->"
  refute_output --partial 'needs you'
}

@test "a stamp naming an ask that does not exist renders as an ordinary item" {
  run row '- [ ] ALW search #ai <!-- ask:deadbeef -->'
  assert_output --partial '[ ]'
  refute_output --partial 'needs you'
}

@test "a ticket stamp still renders its id — the gate path did not displace it" {
  run row '- [ ] ALW search #ai <!-- vk:601 -->'
  assert_output --partial '#601'
  refute_output --partial 'needs you'
}

@test "the row wire is still 7 fields with a gate on it" {
  local id; id="$(gate)"
  run bash -c 'source "$COCKPIT"; _task_row personal /f.md 3 k1 personal/alpha "- [ ] x #ai <!-- ask:'"$id"' -->" | awk -F"\t" "{print NF}"'
  assert_output '7'
}

# ── answering in place ───────────────────────────────────────────────────────

@test "enter on a gated sheet line answers the ask instead of opening the file" {
  local id; id="$(gate)"
  printf '## Wave: v1.0.1 (current)\n- [ ] human line\n- [ ] ALW search #ai <!-- ask:%s -->\n' "$id" > "$SHEET"
  run bash -c 'source "$COCKPIT"; _enter_action task personal "$1" 3' _ "$SHEET"
  assert_output --partial "--answer $id"
  refute_output --partial '--jump'
}

@test "enter on an ordinary line still opens the file" {
  local id; id="$(gate)"
  printf '## Wave: v1.0.1 (current)\n- [ ] human line\n- [ ] ALW search #ai <!-- ask:%s -->\n' "$id" > "$SHEET"
  run bash -c 'source "$COCKPIT"; _enter_action task personal "$1" 2' _ "$SHEET"
  assert_output --partial '--jump task'
  refute_output --partial '--answer'
}

@test "enter on a gated line reloads the list, so the row updates in place" {
  local id; id="$(gate)"
  printf -- '- [ ] x #ai <!-- ask:%s -->\n' "$id" > "$SHEET"
  run bash -c 'source "$COCKPIT"; _enter_action task personal "$1" 1' _ "$SHEET"
  assert_output --partial 'reload('
}

@test "enter on a line whose gate was already answered opens the file, not the picker" {
  local id; id="$(gate)"
  printf -- '- [ ] x #ai <!-- ask:%s -->\n' "$id" > "$SHEET"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run bash -c 'source "$COCKPIT"; _enter_action task personal "$1" 1' _ "$SHEET"
  assert_output --partial '--jump task'
}

@test "_line_ask_at on a missing file is silent, not an error" {
  run bash -c 'source "$COCKPIT"; _line_ask_at /no/such/file.md 3'
  assert_success
  assert_output ''
}

# ── answering RESUMES ────────────────────────────────────────────────────────

# The whole point. Before this, `answer_ask` set a field on disk and stopped: the cockpit
# was a write-only surface for decisions.
@test "answering from the cockpit runs the ask's resume command" {
  cat > "$SANDBOX/bin/wave-start" <<'EOF'
#!/usr/bin/env bash
printf 'wave-start %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/wave-start"
  local id; id="$(gate)"
  # answer_ask shells out to fzf when it has options; drive the no-options path via stdin
  bash -c 'source "$COCKPIT"; answer_ask "$1" ""' _ "$id" <<<'approve'
  # the resume is backgrounded off the keypress so the picker returns instantly
  local i=0; while [ $i -lt 40 ] && ! grep -q wave-start "$NOTES_FIXTURE/calls.log" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  run cat "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'wave-start alpha --verb start'
}

@test "the answer is recorded even though the resume is backgrounded" {
  local id; id="$(gate)"
  bash -c 'source "$COCKPIT"; answer_ask "$1" ""' _ "$id" <<<'approve'
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^status: //p"' _ "$id"
  assert_output 'answered'
}
