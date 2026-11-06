#!/usr/bin/env bats
# ask-resume: the producer half of the human<->agent loop.
#
# `agent-ask answer` records a decision and notifies. For an entire release cycle that was
# ALL that happened - an agent posted a gate, the human answered `approve` in the cockpit, and
# the work stayed blocked forever because no code path anywhere turned the answer back into
# an action. agent-ask's own header promised "a later fire consumes the answer"; nothing did.
#
# So the contract under test is narrow and specific: an answered ask carrying a `resume`
# command runs that command EXACTLY ONCE, and stops being resumable the moment it has.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # A resume runs headless through agentctl-run. Stub it, and record every invocation.
  cat > "$SANDBOX/bin/agentctl-run" <<'EOF'
#!/usr/bin/env bash
printf 'agentctl-run %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/agentctl-run"

  # ask-resume detaches with `setsid -f`. Run the command in the foreground instead, so the
  # call is on disk before ask-resume returns and no test has to wait for it.
  cat > "$SANDBOX/bin/setsid" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -f ] && shift
"$@"
EOF
  chmod +x "$SANDBOX/bin/setsid"
}

# post a gate whose resume is a headless command; returns the id
gate() { # $1=project
  "$AGENT_ASK" post --project "${1:-alpha}" --kind gate \
    --options 'approve=go ahead|hold=wait|cancel=drop it' --resume "/captain ${1:-alpha} go" \
    'Create the tickets and cut the branch?'
}

calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

# -- the queue --

@test "GUARD: ask-resume under test is the sandbox copy, not a symlink into the repo" {
  run command -v ask-resume
  assert_output "$SANDBOX/bin/ask-resume"
  assert [ ! -L "$SANDBOX/bin/ask-resume" ]
}

@test "a pending ask is not resumable - nothing has been decided yet" {
  gate alpha >/dev/null
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "an answered ask with a resume command IS resumable" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run bash -c '"$AGENT_ASK" resumable alpha | cut -f1,3'
  assert_output "$(printf '%s\t/captain alpha go' "$id")"
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

# -- marking --

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

# -- answering is starting --
# agent-web, fleet.sh and the CLI all answer through `agent-ask answer`, so the resume
# has to happen there or an answer given on one of them goes nowhere.

@test "answering a gate runs its resume, once, with no separate ask-resume call" {
  unset AGENT_ASK_NO_RESUME
  local id; id="$(gate alpha)"
  run "$AGENT_ASK" answer "$id" approve
  assert_success
  run calls
  assert_output --partial 'agentctl-run --agent ask-resume -p /captain alpha go'
  run "$AGENT_ASK" resumable alpha
  assert_output ''
  ask-resume --all
  run bash -c 'grep -c "^agentctl-run" "$NOTES_FIXTURE/calls.log"'
  assert_output '1'
}

@test "answering a plain question resumes nothing and still succeeds" {
  unset AGENT_ASK_NO_RESUME
  local id; id="$("$AGENT_ASK" post --project alpha --kind question 'just wondering?')"
  run "$AGENT_ASK" answer "$id" ok
  assert_success
  run calls
  refute_output --partial 'agentctl-run'
}

@test "a resume that fails does not fail the answer, and the answer is recorded" {
  unset AGENT_ASK_NO_RESUME
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agentctl-run"
  chmod +x "$SANDBOX/bin/agentctl-run"
  local id; id="$(gate alpha)"
  run "$AGENT_ASK" answer "$id" approve
  assert_success
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^status: //p"' _ "$id"
  assert_output 'answered'
}

# -- running --

@test "a resume runs headless as the ask-resume agent, with a turn cap" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run ask-resume "$id"
  assert_success
  run calls
  assert_output --partial 'agentctl-run --agent ask-resume -p /captain alpha go --max-turns 60'
}

# The single most important test in this file. Resuming twice means two scope-outs of the
# same items, which means duplicate tickets on a real tracker and two branches for one task.
@test "an ask resumes EXACTLY ONCE across repeated drains" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ask-resume --all
  ask-resume --all
  ask-resume --all
  run bash -c 'grep -c "^agentctl-run" "$NOTES_FIXTURE/calls.log"'
  assert_output '1'
}

@test "the ask is marked BEFORE the command runs, so a crash cannot loop forever" {
  # A resume that dies must still leave the queue: these commands create tickets and cut
  # branches, so retrying one on every fire is worse than needing a human.
  cat > "$SANDBOX/bin/agentctl-run" <<'EOF'
#!/usr/bin/env bash
printf 'agentctl-run %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
exit 1
EOF
  chmod +x "$SANDBOX/bin/agentctl-run"
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  ask-resume --all || true
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}

@test "resuming an id with no pending resume is a silent no-op, not an error" {
  # `agent-ask answer` calls this on EVERY answer. An ordinary question must not print or fail.
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
  assert_output --partial "would run: agentctl-run --agent ask-resume -p '/captain alpha go'"
  run calls
  refute_output --partial 'agentctl-run'
  # and it is still queued, because nothing consumed it
  run bash -c '"$AGENT_ASK" resumable alpha | wc -l'
  assert_output '1'
}
