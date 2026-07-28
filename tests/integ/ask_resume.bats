#!/usr/bin/env bats
# ask-resume: the producer half of the human<->agent loop.
#
# `agent-ask answer` records a decision and notifies. For an entire release cycle that was
# ALL that happened — a wave posted a gate, the human answered `approve` in the cockpit, and
# the wave stayed blocked forever because no code path anywhere turned the answer back into
# an action. agent-ask's own header promised "a later fire consumes the answer"; nothing did.
#
# So the contract under test is narrow and specific: an answered ask carrying a `resume`
# command runs that command EXACTLY ONCE, and stops being resumable the moment it has.

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

  # wave-start is the harness a `/wave` resume goes through (it owns the per-app lock, the
  # log and the status contract). Stub it, and record every invocation.
  cat > "$SANDBOX/bin/wave-start" <<'EOF'
#!/usr/bin/env bash
printf 'wave-start %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/wave-start"

  cat > "$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/claude"
}

# post a gate whose resume is a wave start; returns the id
gate() { # $1=project
  "$AGENT_ASK" post --project "${1:-alpha}" --kind gate \
    --options 'approve|hold|cancel' --resume "/wave ${1:-alpha} start" \
    'Create the tickets and cut the branch?'
}

calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

# ── the queue ────────────────────────────────────────────────────────────────

@test "GUARD: ask-resume under test is the sandbox copy, not a symlink into the repo" {
  run command -v ask-resume
  assert_output "$SANDBOX/bin/ask-resume"
  assert [ ! -L "$SANDBOX/bin/ask-resume" ]
}

@test "a pending ask is not resumable — nothing has been decided yet" {
  gate alpha >/dev/null
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "an answered ask with a resume command IS resumable" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" resumable alpha | cut -f1,3'
  assert_output "$(printf '%s\t/wave alpha start' "$id")"
}

@test "an answered ask with NO resume command is never resumable" {
  local id; id="$("$AGENT_ASK" post --project alpha --kind question 'just wondering?')"
  "$AGENT_ASK" answer "$id" ok >/dev/null 2>&1
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "a cancelled ask is never resumable, however it was answered" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" cancel "$id" >/dev/null 2>&1
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "resumable --all spans projects" {
  local a b
  a="$(gate alpha)"; b="$(gate beta)"
  "$AGENT_ASK" answer "$a" approve >/dev/null 2>&1
  "$AGENT_ASK" answer "$b" approve >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" resumable --all | cut -f2 | sort | tr "\n" " "'
  assert_output 'alpha beta '
}

# ── marking ──────────────────────────────────────────────────────────────────

@test "mark-resumed takes an ask out of the queue" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  "$AGENT_ASK" mark-resumed "$id" >/dev/null 2>&1
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "mark-resumed is idempotent and does not restamp" {
  local id first
  id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  "$AGENT_ASK" mark-resumed "$id" >/dev/null 2>&1
  first="$("$AGENT_ASK" show "$id" | sed -n 's/^resumed_at: //p')"
  "$AGENT_ASK" mark-resumed "$id" >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" show '"$id"' | sed -n "s/^resumed_at: //p"'
  assert_output "$first"
}

# ── running ──────────────────────────────────────────────────────────────────

@test "a /wave resume goes through wave-start, not a bare claude" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run ask-resume "$id"
  assert_success
  run calls
  assert_output --partial 'wave-start alpha --verb start'
  refute_output --partial 'claude '
}

@test "the verb from the resume command is carried through" {
  local id
  id="$("$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold' \
        --resume '/wave alpha ship' 'merge it?')"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ask-resume "$id"
  run calls
  assert_output --partial 'wave-start alpha --verb ship'
}

# The single most important test in this file. Resuming twice means two scope-outs of the
# same items, which means duplicate tickets on a real tracker and two branches for one wave.
@test "an ask resumes EXACTLY ONCE across repeated drains" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ask-resume --all
  ask-resume --all
  ask-resume --all
  run bash -c 'grep -c "^wave-start" "$NOTES_FIXTURE/calls.log"'
  assert_output '1'
}

@test "the ask is marked BEFORE the command runs, so a crash cannot loop forever" {
  # A resume that dies must still leave the queue: these commands create tickets and cut
  # branches, so retrying one on every fire is worse than needing a human.
  cat > "$SANDBOX/bin/wave-start" <<'EOF'
#!/usr/bin/env bash
printf 'wave-start %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
exit 1
EOF
  chmod +x "$SANDBOX/bin/wave-start"
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ask-resume --all || true
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "resuming an id with no pending resume is a silent no-op, not an error" {
  # The cockpit calls this on EVERY answer. An ordinary question must not print or fail.
  local id; id="$("$AGENT_ASK" post --project alpha --kind question 'just wondering?')"
  "$AGENT_ASK" answer "$id" ok >/dev/null 2>&1
  run ask-resume "$id"
  assert_success
  assert_output ''
}

@test "resuming an unknown id is a silent no-op" {
  run ask-resume nosuchid
  assert_success
  assert_output ''
}

@test "--dry-run reports the command and runs nothing" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run ask-resume --dry-run --all
  assert_output --partial 'would run: wave-start alpha --verb start'
  run calls
  refute_output --partial 'wave-start'
  # and it is still queued, because nothing consumed it
  run bash -c '"$AGENT_ASK" resumable alpha | wc -l'
  assert_output '1'
}

@test "a non-wave resume falls back to a headless claude" {
  local id
  id="$("$AGENT_ASK" post --project alpha --kind gate --options 'approve|hold' \
        --resume '/captain status' 'carry on?')"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run ask-resume --dry-run "$id"
  assert_output --partial "would run: claude -p '/captain status'"
}

# The Lazer route is a CLIENT proxy. delivery-loop exports ANTHROPIC_BASE_URL pointing at
# it, and a resume inherits that env unless it is scrubbed — which would push a personal
# project's notes-vault content through a client's infrastructure.
@test "the Anthropic transport env is scrubbed before a resume runs" {
  cat > "$SANDBOX/bin/wave-start" <<'EOF'
#!/usr/bin/env bash
printf 'base=%s key=%s\n' "${ANTHROPIC_BASE_URL:-unset}" "${ANTHROPIC_AUTH_TOKEN:-unset}" \
  >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/wave-start"
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ANTHROPIC_BASE_URL=https://llm.example.invalid ANTHROPIC_AUTH_TOKEN=secret ask-resume "$id"
  run calls
  assert_output --partial 'base=unset key=unset'
}
