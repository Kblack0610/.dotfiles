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
printf 'run item=%s\n' "${AGENT_QUEUE_ITEM:-}" >> "$NOTES_FIXTURE/calls.log"
EOF
  chmod +x "$SANDBOX/bin/agentctl-run"

  # A model resume is a queue item (agent-queue's own suite pins what add writes). The stub
  # records each call with the session env it saw, files the item running, and AQ_REFUSE makes
  # the add fail as an unknown project would.
  cat > "$SANDBOX/bin/agent-queue" <<'EOF'
#!/usr/bin/env bash
printf 'agent-queue %s | sid=%s item=%s\n' "$*" "${CLAUDE_CODE_SESSION_ID:-}" "${AGENT_QUEUE_ITEM:-}" >> "$NOTES_FIXTURE/calls.log"
case "$1" in
  add) [ -z "${AQ_REFUSE:-}" ] || { echo "agent-queue: unknown project" >&2; exit 1; }
       while [ "$1" != --slug ]; do shift; done; echo "running $(tr A-Z a-z <<<"$2") -> /q/running/x.md" ;;
  show) printf '{"state":"%s","row":"%s","pr":"%s"}\n' "${AQ_STATE:-running}" "${AQ_ROW:-}" "${AQ_PR:-}" ;;
  list) [ -z "${AQ_LIVE:-}" ] || printf '{"slug":"%s","state":"queued","row":"%s"}\n' "$AQ_LIVE" "${AQ_LIVE_ROW:-}" ;;
  move) [ -z "${AQ_MOVE_FAIL:-}" ] || exit 1 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/agent-queue"

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
# agent-web, fleet.sh and the CLI all answer through `agent-ask answer`, so the resume has to
# follow from it (its queued delivery, `deliver`) or an answer given on one of them goes nowhere.

@test "answering a gate runs its resume, once, with no separate ask-resume call" {
  unset AGENT_ASK_NO_RESUME
  local id; id="$(gate alpha)"
  run "$AGENT_ASK" answer "$id" approve
  assert_success
  run "$AGENT_ASK" deliver --all
  assert_success
  run calls
  assert_output --partial 'agentctl-run --agent ask-resume -p /captain alpha go'
  # The note names the resume, the one place it went.
  run "$AGENT_ASK" show "$id"
  assert_line 'delivery_note: its resume'
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
  "$AGENT_ASK" deliver --all
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
  run "$AGENT_ASK" deliver --all
  assert_success
  run bash -c '"$AGENT_ASK" show "$1" | sed -n "s/^status: //p;s/^delivery: //p"' _ "$id"
  assert_output $'answered\ndone'
}

# -- a live asker carries on --
# ar-5961: ask MFLKKY's judge answer at post ran its prompt resume headless beside the live asker
# tr-181, which committed that session's uncommitted diff and opened trader PR #232 as a second copy.

# live_judge: post's judge answers a ship_deploy ask at once with `approve`.
live_judge() {
  export AGENT_ASK_DELAY_RULES=ship_deploy@repo=0 AGENT_ASK_JUDGE_CMD="$BATS_TEST_TMPDIR/judge"
  unset AGENT_ASK_NO_JUDGE
  cat > "$BATS_TEST_TMPDIR/judge" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"type":"ship_deploy","decisions":[{"decision":"d","impact":{"evidence":"q impact","level":"self"},"knowledge":{"evidence":"","met":false},"external":{"evidence":"","met":false},"taste":{"evidence":"","met":false},"unclear-ask":{"evidence":"","met":false},"against-precedent":{"evidence":"","met":false},"reversible":{"evidence":"q reversible","met":true},"grounded":{"evidence":"q grounded","met":true}}],"reason":"rules say go","answer":"approve"}'
SH
  chmod +x "$BATS_TEST_TMPDIR/judge"
}

@test "a judge answer at post goes to the asking session, and its prompt resume does not start" {
  bats_require_minimum_version 1.5.0
  unset AGENT_ASK_NO_RESUME
  live_judge
  local opts=(--project alpha --options 'approve=go ahead|hold=wait' --recommend approve --resume '/captain alpha go')
  run --separate-stderr env CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post "${opts[@]}" 'Cut the branch?'
  assert_success
  local id="$output"
  [[ "$stderr" == *"resume did not start: the asking session has the answer"* ]]
  assert_not_called 'agentctl-run'
  run "$AGENT_ASK" show "$id"
  assert_line 'answered_by: judge'
  refute_line 'resumed_at: '
  run "$AGENT_ASK" resumable alpha
  assert_output ''
  # Negative control: a script with no session reads no answer, so its resume runs.
  env -u CLAUDE_CODE_SESSION_ID "$AGENT_ASK" post "${opts[@]}" 'Cut the other branch?' >/dev/null 2>&1
  assert_called 'agentctl-run --agent ask-resume -p /captain alpha go'
}

@test "an answer typed into the live asker starts no prompt resume; a run: resume still runs" {
  unset AGENT_ASK_NO_RESUME
  printf '{"session_id":"sid-1","pane":"%%1","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  local id; id="$(CLAUDE_CODE_SESSION_ID=sid-1 gate alpha)"
  "$AGENT_ASK" answer "$id" approve 2>/dev/null; "$AGENT_ASK" deliver --all 2>/dev/null
  assert_called "agent-panel send --pane %1 Answer to ask $id: approve"
  assert_not_called 'agentctl-run'
  run "$AGENT_ASK" show "$id"
  assert_line --partial 'not its resume: the live session on the ask has the answer'
  refute_line 'resumed_at: '
  # The answer did not go in (another send held the pane): a board row carries it, never a headless run.
  touch "$NOTES_FIXTURE/agent-panel.busy"
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project alpha --resume '/captain alpha again' 'Cut it again?')"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null; "$AGENT_ASK" deliver --all 2>/dev/null
  assert_not_called 'agentctl-run'
  assert_called 'notes ptask'
  rm "$NOTES_FIXTURE/agent-panel.busy"
  # Negative control: a `run:` resume is the asking script's own step, so it runs beside the session.
  printf '#!/usr/bin/env bash\nprintf "own-step %%s\\n" "$*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/own-step"
  chmod +x "$SANDBOX/bin/own-step"
  id="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project alpha --resume 'run: own-step' 'Step on?')"
  "$AGENT_ASK" answer "$id" yes 2>/dev/null; "$AGENT_ASK" deliver --all 2>/dev/null
  assert_called "own-step $id"
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

@test "under a systemd unit the resume leaves the unit's cgroup through a scope; outside one it does not" {
  # A oneshot's cgroup kills every child when it exits, setsid ones too.
  cat > "$SANDBOX/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
while [ "${1#--}" != "$1" ]; do shift; done
"$@"
EOF
  chmod +x "$SANDBOX/bin/systemd-run"
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  INVOCATION_ID=abc run ask-resume "$id"
  assert_success
  run calls
  assert_output --partial 'systemd-run --user --scope --quiet setsid -f env AGENT_QUEUE_ITEM=ask-resume-'
  assert_output --partial $'\nagentctl-run --agent ask-resume -p /captain alpha go'
  # negative control: a resume started outside a unit uses setsid alone
  : > "$NOTES_FIXTURE/calls.log"
  id="$(gate beta)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  env -u INVOCATION_ID ask-resume "$id"
  run calls
  refute_output --partial 'systemd-run'
  assert_output --partial 'agentctl-run --agent ask-resume -p /captain beta go'
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

@test "a run: resume runs its command with the ask id, once, and no model" {
  printf '#!/usr/bin/env bash\necho "consumer $*" >> "$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/consumer"
  chmod +x "$SANDBOX/bin/consumer"
  local id; id="$("$AGENT_ASK" post --project alpha --kind gate \
    --options 'alpha=file it on alpha|drop=take it out' --resume 'run:consumer --answer' 'Which project is this line about?')"
  "$AGENT_ASK" answer "$id" alpha >/dev/null 2>&1
  run ask-resume --dry-run "$id"
  assert_output --partial "would run: consumer --answer $id"
  ask-resume "$id"
  ask-resume --all
  # The answer also reads the queue for items held on the ask (agent-ask start_held), so only the
  # consumer's own calls are counted.
  run grep '^consumer ' "$NOTES_FIXTURE/calls.log"
  assert_output "consumer --answer $id"
}

# -- its queue item --
# A model resume used to run with no queue item (QUEUE.md "Intake channels", ar-4154): its work
# and its adds were nobody's, and a session that had answered the ask lent it its own identity.

@test "a model resume runs as a queue item from ask:<id>, not as the answering session" {
  local id slug; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  slug="ask-resume-$(tr A-Z a-z <<<"$id")"
  CLAUDE_CODE_SESSION_ID=answerer AGENT_QUEUE_ITEM=answerer-item run ask-resume "$id"
  assert_success
  run grep '^agent-queue add' "$NOTES_FIXTURE/calls.log"
  assert_output "agent-queue add --running --repeat --project alpha --from ask:$id --slug ask-resume-$id --title chore(asks): resume answered ask $id /captain alpha go | sid= item="
  run grep -F "agent-queue set $slug origin=ask" "$NOTES_FIXTURE/calls.log"
  assert_success
  # The session works under the item, and its exit closes the item it left running.
  run grep '^run item=' "$NOTES_FIXTURE/calls.log"
  assert_output "run item=$slug"
  run grep '^agent-queue move' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "agent-queue move $slug done --status ok"
  # The run's session id is claimed on the item before it starts, and the run is that session.
  run grep -o "agent-queue claim $slug --sid [0-9a-f-]*" "$NOTES_FIXTURE/calls.log"
  assert_success
  local sid="${output##* }"
  [ -n "$sid" ]
  run grep -F -- "--session-id $sid" "$NOTES_FIXTURE/calls.log"
  assert_success
}

@test "a model resume that opened a PR and did not land it leaves its item in review, not done" {
  local id slug; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  slug="ask-resume-$(tr A-Z a-z <<<"$id")"
  AQ_PR=o/r#9 run ask-resume "$id"
  run grep '^agent-queue move' "$NOTES_FIXTURE/calls.log"
  assert_output "agent-queue move $slug review | sid= item=$slug"
}

@test "a failed model resume closes its item failed" {
  printf '#!/usr/bin/env bash\nexit 7\n' > "$SANDBOX/bin/agentctl-run"
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run ask-resume "$id"  # the stub setsid runs it in the foreground, so its exit is the run's
  run grep '^agent-queue move' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "done --status failed"
}

@test "a close agent-queue refuses is logged with the whole move line it passed, state included" {
  local id slug
  mkdir -p "$AGENTCTL_STATE_DIR/ask-resume"
  _closing() { # $1=agentctl-run exit code; the env of the call is the caller's
    id="$(gate alpha)"
    "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
    slug="ask-resume-$(tr A-Z a-z <<<"$id")"
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$SANDBOX/bin/agentctl-run"
    : > "$AGENTCTL_STATE_DIR/ask-resume/alpha.log"
    ask-resume "$id" 2>/dev/null || true  # the stub setsid is foreground, so the exit is the run's
  }
  # the wrapper's own stderr goes to the project's resume log
  local log="$AGENTCTL_STATE_DIR/ask-resume/alpha.log"
  AQ_MOVE_FAIL=1 _closing 0
  run cat "$log"
  assert_output "ask-resume: $slug is left open: agent-queue move $slug done --status ok"
  run grep -c "^agent-queue move $slug done --status ok " "$NOTES_FIXTURE/calls.log"
  assert_output 1
  AQ_MOVE_FAIL=1 _closing 7
  run cat "$log"
  assert_output "ask-resume: $slug is left open: agent-queue move $slug done --status failed"
  run grep -c "^agent-queue move $slug done --status failed " "$NOTES_FIXTURE/calls.log"
  assert_output 1
  AQ_MOVE_FAIL=1 AQ_PR='o/r#9' _closing 0
  run cat "$log"
  assert_output "ask-resume: $slug is left open: agent-queue move $slug review"
  run grep -c "^agent-queue move $slug review " "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "an item agent-queue refuses leaves the ask resumable and runs no model" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  AQ_REFUSE=1 run ask-resume "$id"
  assert_failure
  assert_output --partial "$id not resumed: agent-queue did not file its item"
  run calls
  refute_output --partial 'agentctl-run'
  run bash -c '"$AGENT_ASK" resumable alpha | cut -f1'
  assert_output "$id"
  # negative control: once the add goes in, the same ask resumes
  run ask-resume "$id"
  assert_success
  run calls
  assert_output --partial 'agentctl-run --agent ask-resume'
}

@test "a run: resume files no queue item: it is the asking script's own step" {
  printf '#!/usr/bin/env bash\n:\n' >"$SANDBOX/bin/consumer"
  chmod +x "$SANDBOX/bin/consumer"
  local id; id="$("$AGENT_ASK" post --project alpha --kind gate \
    --options 'alpha=file it|drop=drop it' --resume 'run:consumer' 'Which project?')"
  "$AGENT_ASK" answer "$id" alpha >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  ask-resume "$id"
  run grep '^agent-queue add' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

# -- a start of an item (ar-6089: ask VmlrxU's resume named ar-5588, cancelled when its park requeued it) --

fleet_dispatch_stub() {
  printf '#!/usr/bin/env bash\nprintf "fleet-dispatch %%s\\n" "$*" >> "$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
}

start_ask() { # $1=resume
  local id; id="$("$AGENT_ASK" post --project alpha --kind gate --options 'a=yes|b=no' --resume "$1" 'Grant it?')" || return 1
  "$AGENT_ASK" answer "$id" a >/dev/null 2>&1
  : > "$NOTES_FIXTURE/calls.log"
  printf '%s\n' "$id"
}

@test "post refuses a --resume that opens with a fleet command and no run: prefix" {
  run "$AGENT_ASK" post --project alpha --kind gate --options 'a=yes|b=no' \
    --resume 'fleet-dispatch start --item ar-1' 'Grant it?'
  assert_failure 2
  assert_output --partial "Write it 'run: fleet-dispatch start --item ar-1'"
}

@test "post takes a prose resume that starts with an ordinary word, a slash command, and a run: command" {
  local r
  for r in 'continue the work' '/captain alpha go' 'run: fleet-dispatch start --item ar-1'; do
    run "$AGENT_ASK" post --project alpha --kind gate --options 'a=yes|b=no' --resume "$r" 'Grant it?'
    assert_success
  done
}

@test "a run: start of a live item runs as written" {
  fleet_dispatch_stub
  local id; id="$(start_ask 'run: fleet-dispatch start --item ar-1')"
  AQ_STATE=queued ask-resume "$id"
  run calls
  assert_output --partial 'fleet-dispatch start --item ar-1'
}

@test "a run: start of an ended item names the live item on its row" {
  fleet_dispatch_stub
  local id; id="$(start_ask 'run: fleet-dispatch start --item ar-1')"
  AQ_STATE=done AQ_ROW=p:ar-1 AQ_LIVE=ar-1b AQ_LIVE_ROW=p:ar-1 ask-resume "$id"
  run calls
  assert_output --partial 'fleet-dispatch start --item ar-1b'
  # a start is a whole command: no ask id after it
  assert_output --regexp 'start --item ar-1b$'
  refute_output --regexp 'start --item ar-1( |$)'
}

@test "a run: start of an ended item with no live item on its row starts nothing and marks the ask resumed" {
  fleet_dispatch_stub
  local id; id="$(start_ask 'run: fleet-dispatch start --item ar-1')"
  AQ_STATE=done AQ_ROW=p:ar-1 AQ_LIVE=other AQ_LIVE_ROW=p:other run ask-resume "$id"
  assert_success
  assert_output --partial 'nothing runs'
  run calls
  refute_output --partial 'fleet-dispatch'
  run "$AGENT_ASK" resumable alpha
  assert_output ''
}
