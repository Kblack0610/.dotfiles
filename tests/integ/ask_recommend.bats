#!/usr/bin/env bats
# A recommendation, and free text alongside the option you pick.
#
# `wave.md` has always specified that per-item choices - "approve, but drop the mobile one" -
# belong in the human's FREE TEXT next to the option. No surface could produce one: the
# picker was a bare fzf list of `approve|hold|cancel` with no question text, no indication
# of what the agent that asked would do, and nowhere to type. The contract existed and the
# UI did not, so every nuanced answer had to be flattened into one of three words.
#
# The recommendation is a FIELD rather than a sentence in the question: advice buried in 900
# characters of prose is advice the human reads only if they open the ask, which is exactly
# the thing a one-key picker exists to avoid.

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
  # the field count is pinned in agent_ask.bats
  local id; id="$(gate approve)"
  run bash -c '"$AGENT_ASK" list alpha | cut -f11'
  assert_output 'approve'
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
