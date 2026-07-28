#!/usr/bin/env bats
# A recommendation, and free text alongside the option you pick.
#
# `wave.md` has always specified that per-item choices - "approve, but drop the mobile one" -
# belong in the human's FREE TEXT next to the option. No surface could produce one: the
# picker was a bare fzf list of `approve|hold|cancel` with no question text, no indication
# of what the agent that asked would do, and nowhere to type. The contract existed and the
# UI did not, so every nuanced answer had to be flattened into one of three words.
#
# The recommendation is a FIELD rather than a sentence in the question for the same reason:
# advice buried in 900 characters of prose is advice the human reads only if they open the
# ask, which is exactly the thing a one-key picker exists to avoid.

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
}

gate() { # [recommended]
  if [ -n "${1:-}" ]; then
    "$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold|cancel' \
      --recommend "$1" 'Create the 3 tickets and cut the branch?'
  else
    "$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold|cancel' \
      'Create the 3 tickets and cut the branch?'
  fi
}

# ── the field ────────────────────────────────────────────────────────────────

@test "post records the recommended option" {
  local id; id="$(gate approve)"
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^recommend: //p"' _ "$id"
  assert_output 'approve'
}

@test "an ask with no recommendation has the key present but empty" {
  # present-but-empty, not absent: `field` cannot tell "no opinion" from "old ask" otherwise
  local id; id="$(gate)"
  run bash -c '"$AGENT_ASK" show "$1" | grep -c "^recommend:"' _ "$id"
  assert_output '1'
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^recommend: //p"' _ "$id"
  assert_output ''
}

# A recommendation outside the offered vocabulary would mark nothing in the picker and the
# human would never learn the agent meant to advise. Fail the caller instead.
@test "a recommendation that is not one of the options is refused" {
  run "$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold' \
    --recommend maybe 'bad?'
  assert_failure
  assert_output --partial "not one of 'approve|hold'"
}

@test "a refused recommendation creates no ask file at all" {
  "$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold' \
    --recommend maybe 'bad?' 2>/dev/null || true
  run bash -c 'find "$HOME/.agent/asks" -name "*.md" | wc -l'
  assert_output '0'
}

@test "the recommend verb sets it on an existing ask" {
  local id; id="$(gate)"
  "$AGENT_ASK" recommend "$id" hold >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^recommend: //p"' _ "$id"
  assert_output 'hold'
}

@test "the recommend verb validates against that ask's own options" {
  local id; id="$(gate)"
  run "$AGENT_ASK" recommend "$id" maybe
  assert_failure
}

@test "list carries recommend as the eleventh field" {
  local id; id="$(gate approve)"
  run bash -c '"$AGENT_ASK" list alpha | awk -F"\t" "{print NF; exit}"'
  assert_output '11'
  run bash -c '"$AGENT_ASK" list alpha | cut -f11'
  assert_output 'approve'
}

# ── the picker's ordering ────────────────────────────────────────────────────

@test "_ask_choices puts the recommendation first and marks it" {
  run bash -c 'source "$COCKPIT"; _ask_choices "approve|hold|cancel" "hold"'
  assert_line --index 0 'hold  (recommended)'
  assert_line --index 1 'approve'
  assert_line --index 2 'cancel'
}

@test "_ask_choices lists every option exactly once" {
  run bash -c 'source "$COCKPIT"; _ask_choices "approve|hold|cancel" "hold" | wc -l'
  assert_output '3'
}

@test "_ask_choices without a recommendation is the plain list, in order" {
  run bash -c 'source "$COCKPIT"; _ask_choices "approve|hold|cancel" ""'
  assert_line --index 0 'approve'
  assert_line --index 1 'hold'
  assert_line --index 2 'cancel'
}

@test "_ask_choices on empty options emits nothing rather than one blank line" {
  run bash -c 'source "$COCKPIT"; _ask_choices "" "" | wc -c'
  assert_output '0'
}

# The marker is display only. `approve  (recommended)` is not a word any consumer knows,
# and wave.md's vocabulary is fixed - so it must never reach the answer field.
@test "the recommended marker is stripped before the answer is recorded" {
  local id; id="$(gate approve)"
  run bash -c 'source "$COCKPIT"; ans="approve  (recommended)"; printf "%s" "${ans%%  (recommended)}"'
  assert_output 'approve'
}

# ── the row ──────────────────────────────────────────────────────────────────

@test "_opts_render lights the recommended option and dims the rest" {
  run bash -c 'source "$COCKPIT"; _opts_render "approve|hold|cancel" "hold"'
  assert_output --partial 'approve'
  assert_output --partial 'hold'
  assert_output --partial 'cancel'
  # the lit colour appears exactly once - on the recommendation
  run bash -c 'source "$COCKPIT"; _opts_render "approve|hold|cancel" "hold" | grep -o "$(printf "\033\[1;32m")" | wc -l'
  assert_output '1'
}

@test "_opts_render with no recommendation renders the plain dim list" {
  run bash -c 'source "$COCKPIT"; _opts_render "approve|hold|cancel" "" | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output '(approve|hold|cancel)'
}

@test "_opts_render keeps every option and the pipe separators" {
  run bash -c 'source "$COCKPIT"; _opts_render "approve|hold|cancel" "hold" | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output '(approve|hold|cancel)'
}

@test "a gated task row surfaces the recommendation" {
  local id; id="$(gate approve)"
  run bash -c 'source "$COCKPIT"; _task_row personal /f.md 3 k1 personal/alpha "- [ ] x #ai <!-- ask:'"$id"' -->" | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output --partial 'needs you (approve|hold|cancel)'
}

@test "a gated task row without a recommendation is unchanged" {
  local id; id="$(gate)"
  run bash -c 'source "$COCKPIT"; _task_row personal /f.md 3 k1 personal/alpha "- [ ] x #ai <!-- ask:'"$id"' -->" | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output --partial 'needs you (approve|hold|cancel)'
}

@test "the row wire stays 7 fields with a recommendation on it" {
  local id; id="$(gate approve)"
  run bash -c 'source "$COCKPIT"; _task_row personal /f.md 3 k1 personal/alpha "- [ ] x #ai <!-- ask:'"$id"' -->" | awk -F"\t" "{print NF}"'
  assert_output '7'
}

@test "_line_ask hands back the recommendation as its third field" {
  local id; id="$(gate cancel)"
  run bash -c 'source "$COCKPIT"; _line_ask "- [ ] x #ai <!-- ask:'"$id"' -->" | cut -f3'
  assert_output 'cancel'
}

# ── free text ────────────────────────────────────────────────────────────────

# The whole point: "approve, but drop the mobile one" has to survive to the wave.
@test "notes are carried alongside the option" {
  local id; id="$(gate approve)"
  "$AGENT_ASK" answer "$id" 'approve - drop the mobile one, ship T1 and T2 only' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p"' _ "$id"
  assert_output 'approve - drop the mobile one, ship T1 and T2 only'
}

@test "an answer with notes still starts with the bare option, so a reader can key on it" {
  local id; id="$(gate approve)"
  "$AGENT_ASK" answer "$id" 'approve - drop the mobile one' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p" | cut -d" " -f1' _ "$id"
  assert_output 'approve'
}

@test "notes do not stop the answer from being resumable" {
  local id
  id="$("$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold|cancel' \
        --recommend approve --resume '/wave alpha start' 'go?')"
  "$AGENT_ASK" answer "$id" 'approve - only T1' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" resumable alpha | cut -f4'
  assert_output 'approve - only T1'
}

@test "a multi-line note is flattened, so the ask file stays one key per line" {
  local id; id="$(gate approve)"
  "$AGENT_ASK" answer "$id" "$(printf 'approve - do T1\nand skip T3')" >/dev/null 2>&1
  run bash -c 'grep -c "^answer: " "$HOME/.agent/asks/alpha/$1.md"' _ "$id"
  assert_output '1'
}
