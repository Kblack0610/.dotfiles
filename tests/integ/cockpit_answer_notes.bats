#!/usr/bin/env bats
# Saying WHY, not just what.
#
# The note step existed but was announced only AFTER an option had been chosen, which made
# it undiscoverable in the way that matters: you cannot decide "approve, but only T1 and T2"
# if you believe the three words are the whole answer. The header now says a note is coming
# before you commit, and the prompt asks for a reason rather than for "notes".
#
# This is not decoration. `wave.md` acts on the reasoning - "approve, drop the mobile one",
# "hold, wait for the 1.11.0 release" - and an option on its own records WHAT was decided
# and never why.

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
  # answer_ask backgrounds a resume; keep every binary it can reach inside the sandbox
  local b
  for b in wave-start claude; do
    cat > "$SANDBOX/bin/$b" <<EOF
#!/usr/bin/env bash
printf '$b %s\n' "\$*" >> "\$NOTES_FIXTURE/calls.log"
EOF
    chmod +x "$SANDBOX/bin/$b"
  done
}

teardown() {
  local i=0
  while [ $i -lt 50 ] && pgrep -f "$SANDBOX" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
  return 0
}

gate() {
  "$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold|cancel' \
    --recommend approve 'Create the 3 tickets and cut the branch?'
}

# ── the picker announces it ──────────────────────────────────────────────────

# The whole fix. Before this the header was the question alone, so the note step was
# invisible until you had already committed to one of three words.
@test "the picker header says a note comes next, before you choose" {
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT"'
  assert_output --partial 'enter picks - then say WHY, or what to change (optional)'
}

@test "the header still carries the question itself" {
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT"'
  assert_output --partial '$question'
  assert_output --partial 'fold -s -w'
}

@test "the note line is present even for an ask with no question text" {
  # The QUESTION is the conditional part; the note affordance is appended unconditionally,
  # so an ask with no question text still tells you a reason is wanted.
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT" | grep -cF "hdr=\"\${hdr}enter picks"'
  assert_output '1'
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT" | grep -F "hdr=\"\${hdr}enter picks" | grep -c "^\s*\["'
  assert_output '0'   # not guarded by a [ -n "$question" ] test
}

@test "the prompt asks for a reason, not for notes" {
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT"'
  assert_output --partial 'why, or what to change?'
}

@test "skipping is still offered, so approving stays two keys" {
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT"'
  assert_output --partial '(enter to skip)'
}

@test "what was actually sent is echoed back when a note was added" {
  run bash -c 'sed -n "/^answer_ask/,/^}/p" "$COCKPIT"'
  assert_output --partial 'sending:'
}

# ── the answer that results ──────────────────────────────────────────────────

@test "a reason is carried through to the ask" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" 'hold - wait for the 1.11.0 release first' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p"' _ "$id"
  assert_output 'hold - wait for the 1.11.0 release first'
}

@test "the option is still the first word, so a reader can key on it" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" 'approve - only T1 and T2, drop the mobile one' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p" | cut -d" " -f1' _ "$id"
  assert_output 'approve'
}

@test "an answer with no reason is exactly the bare option" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" 'approve' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p"' _ "$id"
  assert_output 'approve'
}

@test "a reason survives into the resumable queue, where the producer reads it" {
  local id
  id="$("$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold|cancel' \
        --recommend approve --resume '/wave alpha start' 'go?')"
  "$AGENT_ASK" answer "$id" 'approve - drop the mobile one' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" resumable alpha | cut -f4'
  assert_output 'approve - drop the mobile one'
}

@test "a reason containing a hyphen is not truncated at the separator" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" 'approve - ship T1, hold T2 - it needs a migration' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^answer: //p"' _ "$id"
  assert_output 'approve - ship T1, hold T2 - it needs a migration'
}

@test "a reason with a pipe does not corrupt the options-shaped fields" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" 'hold - blocked on A|B decision' >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" list alpha | cut -f7'
  assert_output 'approve|hold|cancel'
}

@test "a reason keeps the ask on one key per line" {
  local id; id="$(gate)"
  "$AGENT_ASK" answer "$id" "$(printf 'approve - do T1\nand skip T3')" >/dev/null 2>&1
  run bash -c 'grep -c "^answer: " "$HOME/.agent/asks/alpha/$1.md"' _ "$id"
  assert_output '1'
}

# ── the marker never leaks ───────────────────────────────────────────────────

@test "picking the recommended option records the bare word, not the marker" {
  run bash -c 'source "$COCKPIT"; a="approve  (recommended)"; printf "%s" "${a%%  (recommended)}"'
  assert_output 'approve'
}

@test "the recommended marker cannot survive into an answer with a reason" {
  local id; id="$(gate)"
  run bash -c 'source "$COCKPIT"; a="approve  (recommended)"; a="${a%%  (recommended)}"; printf "%s - %s" "$a" "only T1"'
  assert_output 'approve - only T1'
}
