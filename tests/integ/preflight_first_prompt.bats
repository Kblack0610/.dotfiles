#!/usr/bin/env bats
# session-preflight.sh on UserPromptSubmit: the first prompt of a session gets the project's lessons
# that match it, less the ones turn 1 already carried, logged as delivered; a later prompt and a
# prompt nothing matches get nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  ln -s "$REPO_ROOT/.local/bin/lessons" "$SANDBOX/bin/lessons"
  mkdir -p "$HOME/.config/shared-hooks" "$HOME/.agent/lessons" "$SANDBOX/run"
  DEPLOY="$SANDBOX/deploy"; mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/"{session-preflight.sh,project-name.sh,stop-session-changes.py} "$DEPLOY/"
  HOOK="$DEPLOY/session-preflight.sh"
  export XDG_RUNTIME_DIR="$SANDBOX/run"
  REPO="$SANDBOX/repo"; mkdir -p "$REPO"
  # The preflight's project dir decides the lessons file, not the payload cwd (another dir here).
  export CLAUDE_PROJECT_DIR="$REPO"
  L="$HOME/.agent/lessons/repo.md"
  cat > "$L" <<'EOF'
# repo lessons

- 2026-10-01: **Waybar chips cost width.** A new waybar chip costs about 54 px of the bar.
- 2026-10-02: **A waybar chip needs a click target.** The chip width sets it.
- 2026-10-03: **Nightly reds need one owner.** Nobody owns the nightly test run.
EOF
}

prompt() { # SID PROMPT
  jq -nc --arg s "$1" --arg p "$2" --arg c "$SANDBOX" \
    '{hook_event_name: "UserPromptSubmit", session_id: $s, prompt: $p, cwd: $c}' | bash "$HOOK"
}

@test "the first prompt gets its matched lessons, logged; the second prompt gets nothing" {
  run prompt s1 "make the waybar chip width smaller"
  assert_success
  ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$output")
  assert_equal "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" UserPromptSubmit
  [[ "$ctx" == "## Lessons for this work (2 matched on the first prompt)"$'\n'* ]] || fail "header: $ctx"
  [[ "$ctx" == *"Waybar chips cost width"* && "$ctx" == *"click target"* ]] || fail "lessons: $ctx"
  [[ "$ctx" != *"Nightly reds"* ]] || fail "a lesson nothing matched: $ctx"
  run cat "$HOME/.agent/lessons/_delivered/$(date +%Y-%m).tsv"
  assert_output --regexp "^$(date +%F)	repo	[0-9a-f]{8},[0-9a-f]{8}$"
  run prompt s1 "make the waybar chip width smaller"
  assert_success
  assert_output ""
}

@test "a first prompt nothing matches adds nothing and still counts; one under three words does not count" {
  run prompt s2 "continue"
  assert_output ""
  [ ! -e "$SANDBOX/run/lessons-shown/s2.done" ]
  run prompt s2 "set up the kubernetes ingress"
  assert_success
  assert_output ""
  [ -e "$SANDBOX/run/lessons-shown/s2.done" ]
  run prompt s2 "make the waybar chip width smaller"
  assert_output ""
}

@test "what the preflight showed is left out and the count says what is left; all of it shown adds nothing" {
  # What turn 1 carried, as the SessionStart branch records it for the first prompt.
  mkdir -p "$SANDBOX/run/lessons-shown"
  lessons pick --matched "$L" "waybar chip click target" | grep 'click target' > "$SANDBOX/run/lessons-shown/s3"
  run prompt s3 "make the waybar chip width smaller"
  ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$output")
  [[ "$ctx" == "## Lessons for this work (1 matched on the first prompt)"$'\n'* ]] || fail "header: $ctx"
  [[ "$ctx" == *"Waybar chips cost width"* && "$ctx" != *"click target"* ]] || fail "lessons: $ctx"
  [ ! -e "$SANDBOX/run/lessons-shown/s3" ] || fail "the shown file outlived the first prompt"
  lessons pick --matched "$L" "waybar chip width" > "$SANDBOX/run/lessons-shown/s4"
  run prompt s4 "make the waybar chip width smaller"
  assert_output ""
}

@test "the preflight records its lessons for the session, and nothing once the first prompt is past" {
  git -C "$REPO" init -q .
  # The preflight hands out only the lessons that match the work, which for a dispatched session is its item's title.
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' \
    "'{\"title\":\"x P2: waybar chip click target\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_ITEM=x-p2
  bash "$HOOK" <<<'{"source":"startup","session_id":"s5"}' >/dev/null
  run cat "$SANDBOX/run/lessons-shown/s5"
  assert_success
  assert_line --index 0 --partial "## Lessons"
  prompt s5 "set up the kubernetes ingress" >/dev/null
  bash "$HOOK" <<<'{"source":"resume","session_id":"s5"}' >/dev/null
  [ ! -e "$SANDBOX/run/lessons-shown/s5" ] || fail "a resume after the first prompt left a file"
}

@test "a prompt far past the argument size limit is cut, not dropped" {
  { printf 'make the waybar chip width smaller '; head -c 300000 /dev/zero | tr '\0' x; } > "$SANDBOX/big"
  run bash -c 'jq -nc --rawfile p "$1" "{hook_event_name: \"UserPromptSubmit\", session_id: \"s6\", prompt: \$p}" | bash "$2"' _ "$SANDBOX/big" "$HOOK"
  assert_success
  [[ "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" == *"Waybar chips cost width"* ]] || fail "$output"
}

@test "a session id that is not a plain token writes nothing" {
  run prompt "../x" "make the waybar chip width smaller"
  assert_output ""
  git -C "$REPO" init -q .
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && echo %s\n' \
    "'{\"title\":\"x P2: waybar chip click target\"}'" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  AGENT_QUEUE_ITEM=x-p2 bash "$HOOK" <<<'{"source":"startup","session_id":"../x"}' >/dev/null
  [ ! -e "$SANDBOX/x" ] && [ ! -e "$SANDBOX/run/x" ]
  [ -z "$(ls -A "$SANDBOX/run/lessons-shown" 2>/dev/null)" ] || fail "an unsafe id wrote: $(ls "$SANDBOX/run/lessons-shown")"
}
