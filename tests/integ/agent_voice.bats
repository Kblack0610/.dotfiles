#!/usr/bin/env bats
# agent-voice: a gungan take typed into a live session's pane through `agent-panel send`, behind
# the one-pane guard (.local/lib/agent-pane.sh), or started as a new session. agent-panel,
# agent-notify and fzf are the sandbox stubs; gungan, kitty, notify-send, agent-queue and
# fleet-dispatch are stubs written here. Every call lands in calls.log.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  AV="$REPO_ROOT/.local/bin/agent-voice"
  export XDG_RUNTIME_DIR="$SANDBOX/run"
  mkdir -p "$XDG_RUNTIME_DIR"
  stub gungan 'cat "$NOTES_FIXTURE/gungan.out" 2>/dev/null; exit 0'
  stub kitty ':'
  stub notify-send ':'
  stub agent-queue 'cat > "$NOTES_FIXTURE/queue.stdin"; echo "queued said-it -> /q/said-it.md"'
  stub fleet-dispatch '[ -f "$NOTES_FIXTURE/start.fail" ] && exit 1; echo "started x"'
  printf '{"paths":{"/r/dot":"dotfiles","/r/dot2":"dotfiles","/r/game":"unity-core"}}\n' > "$SANDBOX/map.json"
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
}

stub() { # <name> <body>: a stub that logs its argv, then runs BODY
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$NOTES_FIXTURE/calls.log"\n%s\n' "$1" "$2" > "$SANDBOX/bin/$1"
  chmod +x "$SANDBOX/bin/$1"
}

row() { # <pane> <target> [status] [idle_since]
  printf '{"pane":"%s","target":"%s","status":"%s","idle_since":%s,"project":"dotfiles","doing":"Bash: x"}\n' \
    "$1" "$2" "${3:-idle}" "${4:-0}"
}

@test "send --to tmux: types the text into that session's pane" {
  { row hub/%7 hub/dot:1; row hub/%8 hub/dot:2; } > "$NOTES_FIXTURE/agent-panel.list"
  run "$AV" send --to tmux:hub/dot:2 "Fix the flaky test."
  assert_success
  assert_output 'sent to hub/%8'
  assert_equal "$(grep '^agent-panel send' "$NOTES_FIXTURE/calls.log")" 'agent-panel send --pane hub/%8 Fix the flaky test.'
}

@test "send --to pane: reads the text from stdin" {
  row hub/%7 hub/dot:1 > "$NOTES_FIXTURE/agent-panel.list"
  run "$AV" send --to pane:hub/%7 <<< "Ship it."
  assert_success
  assert_equal "$(grep '^agent-panel send' "$NOTES_FIXTURE/calls.log")" 'agent-panel send --pane hub/%7 Ship it.'
}

@test "the guard: a dead target, a dialog, or two panes for one target type nothing" {
  row hub/%7 hub/dot:1 waiting > "$NOTES_FIXTURE/agent-panel.list"
  run "$AV" send --to tmux:hub/dot:1 "hello"
  assert_equal "$status" 2
  run "$AV" send --to tmux:hub/gone:1 "hello"
  assert_equal "$status" 2
  { row hub/%7 hub/dot:1; row hub/%9 hub/dot:1; } > "$NOTES_FIXTURE/agent-panel.list"
  run --separate-stderr "$AV" send --to tmux:hub/dot:1 "hello"
  assert_equal "$status" 2
  assert_line --partial 'hub/%9'
  assert_not_called 'agent-panel send'
}

@test "an Enter the pane did not take exits 3" {
  row hub/%7 hub/dot:1 > "$NOTES_FIXTURE/agent-panel.list"
  touch "$NOTES_FIXTURE/agent-panel.unsent"
  run "$AV" send --to pane:hub/%7 "hello"
  assert_equal "$status" 3
}

@test "send --to new: queues the text for the project, then starts that item" {
  run "$AV" send --to new:dotfiles "Add a voice hotkey."
  assert_success
  assert_equal "$(cat "$NOTES_FIXTURE/queue.stdin")" 'Add a voice hotkey.'
  run grep -c '^agent-queue add --project dotfiles --from human$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c '^fleet-dispatch start --item said-it$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  assert_not_called 'agent-panel send'
}

@test "a new session that cannot start says it stays queued" {
  touch "$NOTES_FIXTURE/start.fail"
  run "$AV" send --to new:dotfiles "x"
  assert_failure
  assert_output --partial 'queued said-it'
}

@test "targets: the paged session first, then idle by newest, busy, no dialogs, then new per project" {
  {
    row hub/%1 hub/a:1 busy 50
    row hub/%2 hub/b:1 idle 10
    row hub/%3 hub/c:1 idle 30
    row hub/%4 hub/d:1 waiting 99
    row hub/%5 hub/e:1 busy 1
  } > "$NOTES_FIXTURE/agent-panel.list"
  stub agent-notify 'printf "2026-11-05T10:00:00-08:00\tnormal\tt\tm\ttmux:hub/b:1\n2026-11-05T11:00:00-08:00\tnormal\tt\tm\ttmux:hub/e:1\n2026-11-05T12:00:00-08:00\tnormal\tt\tm\n"'
  run "$AV" targets
  assert_success
  assert_equal "$(cut -f1 <<< "$output" | paste -sd' ')" \
    'pane:hub/%5 pane:hub/%3 pane:hub/%2 pane:hub/%1 new:dotfiles new:unity-core'
  assert_line --partial $'pane:hub/%5\tpaged  hub/e:1'
}

@test "the hotkey: a starting press opens nothing; the stopping press opens the picker on the text" {
  run "$AV"
  assert_success
  assert_not_called kitty
  echo "Say hello." > "$NOTES_FIXTURE/gungan.out"
  run "$AV"
  assert_success
  run grep -c '^gungan --print record$' "$NOTES_FIXTURE/calls.log"
  assert_output 2
  local take
  take="$(grep '^kitty' "$NOTES_FIXTURE/calls.log" | sed 's/.* pick //')"
  assert_equal "$(cat "$take")" 'Say hello.'
}

@test "pick: Esc sends nothing and drops the take" {
  row hub/%7 hub/dot:1 > "$NOTES_FIXTURE/agent-panel.list"
  echo "hello" > "$SANDBOX/take"
  run "$AV" pick "$SANDBOX/take"
  assert_success
  assert_not_called 'agent-panel send'
  assert [ ! -f "$SANDBOX/take" ]
}

@test "pick: the chosen row is sent" {
  row hub/%7 hub/dot:1 > "$NOTES_FIXTURE/agent-panel.list"
  stub fzf 'cat > /dev/null; printf "pane:hub/%%7\\tx\\n"'
  echo "hello there" > "$SANDBOX/take"
  run "$AV" pick "$SANDBOX/take"
  assert_success
  assert_equal "$(grep '^agent-panel send' "$NOTES_FIXTURE/calls.log")" 'agent-panel send --pane hub/%7 hello there'
}
