#!/usr/bin/env bats
# scratch.sh (Prefix+A, and Prefix+F inside it): the verb contract against the tmux, tmx and
# fleet-dispatch stubs. The popup overlay itself cannot run headless (CONVENTIONS.md), so the
# binds are asserted as text and the verbs as processes.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SCRATCH="$REPO_ROOT/.local/src/tmux/scratch.sh"
  export SCRATCH_HANDOFF="$SANDBOX/state/scratch-handoff" SCRATCH_EXIT_TIMEOUT=0.2

  # A live process stands in for the scratch Claude: its session file is matched by pid.
  sleep 30 & CLAUDE_PID=$!
  WORK="$(dirname "$SANDBOX")/scratch-work"; mkdir -p "$WORK" "$HOME/.claude/sessions"
  export STUB_PANE_ID=%42
  session_file idle
  : > "$NOTES_FIXTURE/tmux.sessions.lab"   # lab is up and holds nothing yet

  cat > "$SANDBOX/bin/fleet-dispatch" <<'EOF'
#!/usr/bin/env bash
printf 'fleet-dispatch START_ORIGIN=%s %s\n' "${START_ORIGIN:-}" "$*" >> "$NOTES_FIXTURE/calls.log"
exit "${STUB_FD_RC:-0}"
EOF
  chmod +x "$SANDBOX/bin/fleet-dispatch"
}

teardown() { kill "$CLAUDE_PID" 2>/dev/null || true; }

# session_file <status> [tmux field] -- the file Claude keeps for the scratch's process.
session_file() {
  jq -n --arg s "$1" --arg t "${2:-scratch:@9.%42}" --arg c "$WORK" \
    '{sessionId: "0ca2e847-af9c-4107-acf6-0398e86a3e6e", cwd: $c, name: "paste idea", status: $s, tmux: $t}' \
    > "$HOME/.claude/sessions/$CLAUDE_PID.json"
}

@test "send resumes the scratch's conversation in its own lab session, then closes the scratch" {
  run "$SCRATCH" send
  assert_success
  assert_called "respawn-pane -k -t =scratch:"
  assert_called "fleet-dispatch START_ORIGIN=scratch start --resume 0ca2e847-af9c-4107-acf6-0398e86a3e6e --cwd $WORK --server lab --session paste-idea"
  assert_called "tmux -L hub kill-session -t =scratch"
  run cat "$SCRATCH_HANDOFF"
  assert_output "lab paste-idea"
}

@test "send refuses mid-turn and touches nothing" {
  session_file busy
  run "$SCRATCH" send
  assert_failure
  assert_output --partial "mid-turn"
  assert_not_called "respawn-pane"
  assert_not_called "fleet-dispatch"
  assert_not_called "kill-session"
}

@test "send finds the Claude by the scratch's pane, not any Claude" {
  # Negative control: the same file on another session's pane is not the scratch.
  session_file idle "dotfiles:@9.%42"
  run "$SCRATCH" send
  assert_failure
  assert_output --partial "no Claude is running in the scratch"
  assert_not_called "fleet-dispatch"
}

@test "a failed start puts the conversation back in the scratch and does not hop" {
  STUB_FD_RC=1 run "$SCRATCH" send
  assert_failure
  assert_output --partial "claude --resume 0ca2e847"
  assert_called "claude-acct run --resume 0ca2e847-af9c-4107-acf6-0398e86a3e6e"
  assert_not_called "kill-session"
  [ ! -e "$SCRATCH_HANDOFF" ]
}

@test "a name already taken on lab gets the id appended" {
  printf 'paste-idea\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$SCRATCH" send
  assert_success
  assert_called "--session paste-idea-0ca2"
}

# A tmux in front of the stub: the attach "ends" with whatever a send would have left.
attach_ends_with() {
  mkdir -p "$SANDBOX/front"
  cat > "$SANDBOX/front/tmux" <<EOF
#!/usr/bin/env bash
case " \$* " in *" new-session "*) [ -n "$1" ] && { mkdir -p "${SCRATCH_HANDOFF%/*}"; printf '%s\n' "$1" > "$SCRATCH_HANDOFF"; } ;; esac
exec "$SANDBOX/bin/tmux" "\$@"
EOF
  chmod +x "$SANDBOX/front/tmux"
  PATH="$SANDBOX/front:$PATH"
}

@test "open attaches the scratch on hub, in the directory it was opened from" {
  attach_ends_with ""
  run "$SCRATCH" open "$WORK"
  assert_success
  assert_called "tmux -L hub new-session -A -s scratch -c $WORK claude-acct run"
  assert_not_called "tmx goto"
}

@test "open hops to where a send went once the attach ends" {
  attach_ends_with "lab paste-idea"
  run "$SCRATCH" open "$WORK"
  assert_success
  assert_called "tmx goto lab paste-idea"
  [ ! -e "$SCRATCH_HANDOFF" ]
}

@test "popup opens on the client tmx names" {
  cat > "$SANDBOX/bin/tmx" <<'EOF'
#!/usr/bin/env bash
printf 'tmx %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
[ "$1" = client ] && echo "lab /dev/pts/7"
EOF
  run "$SCRATCH" popup
  assert_success
  assert_called "tmux -L lab display-popup -c /dev/pts/7 -E -w 100% -h 100%"
}

@test "Prefix+A toggles: closes inside the scratch, opens the popup anywhere else" {
  run grep -E "^bind A if -F '#\{==:#\{session_name\},scratch\}' detach-client 'display-popup .*scratch.sh open" "$REPO_ROOT/.tmux.conf"
  assert_success
}

@test "Prefix+F sends from inside the scratch and still cuts a worktree everywhere else" {
  run grep -E "^bind F if -F '#\{==:#\{session_name\},scratch\}' 'run-shell -b .*scratch.sh send.*' 'run-shell -b .*wt new" "$REPO_ROOT/.tmux.conf"
  assert_success
}
