#!/usr/bin/env bats
# Tier 3: `agent-panel send`, the one way anything types into a Claude pane, against a real tmux
# pane running a reader that behaves like Claude Code's input box: bracketed paste on, a paste
# drawn only once its input has gone idle, and an Enter that lands before that draw dropped,
# leaving the text in the box. Whether an Enter is dropped is the reader's held state, not a
# clock window on the Enter (the 300ms idle clock gates only the draw), so send's first Enter,
# pressed once it sees the paste drawn, is taken on any load (2026-11-09: a busy run exited 3
# when both Enters missed a 300ms window, ar-1251).
# READER_DEAF=1 never takes an Enter.
# READER_BUSY=1 draws it as a busy Claude pane does: a spinner whose timer redraws every 100ms
# above a ruled box. 2026-10-30: a board answer sat unsent in a busy pane, because send judged
# the whole screen and the spinner passed for both the paste drawn and the Enter taken.
# 2026-11-05: answers from the questions panel sat unsent in the session because agent-ask
# pasted and pressed Enter at once. Container only; needs the agent-panel binary (CI builds it).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim
  # Built in this image (tests.yml ui job: tests/docker.sh --run cargo build ...).
  BIN="$REPO_ROOT/.local/src/agent-panel/target/debug/agent-panel"
  if [ ! -x "$BIN" ]; then
    [ -n "${CI:-}" ] && { echo "agent-panel is not built at $BIN" >&2; return 1; }
    skip "build agent-panel first (DOCKER_NETWORK=bridge tests/docker.sh --run cargo build --manifest-path .local/src/agent-panel/Cargo.toml)"
  fi
  LOG="$SANDBOX/submitted.log"
  READER="$SANDBOX/reader.sh"
  # The reader draws its input box as `> <text>` and appends each submitted line to $LOG.
  cat > "$READER" <<'SH'
#!/usr/bin/env bash
# A paste is held (in buf, not drawn) until no input but dropped Enters has come for draw_us and
# no paste is still arriving; ticks of the read timeout notice that. An Enter while held, or any
# Enter with READER_DEAF, is dropped.
log="$1" busy="${READER_BUSY:-}" deaf="${READER_DEAF:-}" draw_us=300000 tick=0
stty -icanon -echo
printf '\e[?2004h'
buf="" shown="" pasting=0 held=0 last_at=0 seq=""
draw() {
  if [ -n "$busy" ]; then
    printf '\e[H* Working... (%s)\e[K\n\e[K\n────────\e[K\n> %s\e[K\n────────\e[K\n  esc to interrupt\e[K' "$tick" "$shown"
  else
    printf '\r\e[K> %s' "$shown"
  fi
}
now_us() { local t="${EPOCHREALTIME/./}"; printf '%s' "$t"; }
draw
while :; do
  wait=()
  if [ -n "$busy" ] || [ "$held" = 1 ]; then wait=(-t 0.1); fi
  IFS= read -r -s -n1 -d '' "${wait[@]}" c; rc=$?
  # A read that times out still returns a byte that arrived as the timer fired (bash keeps
  # partial input on a timeout), so a timeout is a tick and that byte is still input.
  if [ "$rc" -gt 128 ]; then
    tick=$((tick + 1))
    if [ "$held" = 1 ] && [ "$pasting" = 0 ] && [ $(( $(now_us) - last_at )) -ge "$draw_us" ]; then held=0; shown="$buf"; fi
    draw; [ -n "$c" ] || continue
  elif [ "$rc" != 0 ]; then break; fi
  { [ "$held" = 1 ] && [ "$pasting" = 0 ] && [[ "$c" == $'\r' || "$c" == $'\n' ]]; } || last_at="$(now_us)"
  if [ -n "$seq" ] || [ "$c" = $'\e' ]; then
    seq+="$c"
    case "$seq" in
      $'\e[200~') pasting=1; seq="" ;;
      $'\e[201~') pasting=0; held=1; seq="" ;;
      $'\e'|$'\e['|$'\e[2'|$'\e[20'|$'\e[200'|$'\e[201') ;;
      *) seq="" ;;
    esac
    continue
  fi
  if [ "$pasting" = 1 ]; then buf+="$c"; continue; fi
  case "$c" in
    $'\r'|$'\n')
      { [ "$held" = 1 ] || [ -n "$deaf" ]; } && continue
      printf '%s\n' "$buf" >> "$log"; buf=""; shown=""; printf '\r\e[Ksent\n'; draw ;;
    *) buf+="$c"; [ "$held" = 1 ] || shown="$buf"; draw ;;
  esac
done
SH
  chmod +x "$READER"
  tmux_start "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has ">"'
}

teardown() { ui_teardown; }

@test "send waits for the paste to be drawn, so the Enter is taken and the box is empty" {
  run "$BIN" send --pane "$PANE" 'Answer to ask AbC123: yes'
  assert_success
  wait_until '[ -s "$LOG" ]'
  run cat "$LOG"
  assert_output 'Answer to ask AbC123: yes'
  wait_until 'screen | tail -1 | grep -qx "> *"'
}

@test "negative control: paste then an immediate Enter leaves the text unsent in the box" {
  printf 'Answer to ask AbC123: yes' | _tm load-buffer -b t -
  _tm paste-buffer -p -d -b t -t "$TM_TARGET"
  _tm send-keys -t "$TM_TARGET" Enter
  wait_until 'screen_has "> Answer to ask AbC123: yes"'
  [ ! -s "$LOG" ]
}

@test "a pane that never takes the Enter is reported, not passed as sent" {
  tmux_stop
  tmux_start env READER_DEAF=1 "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has ">"'
  run "$BIN" send --pane "$PANE" 'never'
  assert_failure 3
  assert_output --partial 'did not take the Enter'
  [ ! -s "$LOG" ]
}

@test "a busy pane: the answer is submitted, not left in its box while the spinner moves" {
  tmux_stop
  tmux_start env READER_BUSY=1 "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has "esc to interrupt"'
  run "$BIN" send --pane "$PANE" 'Answer to ask AbC123: yes'
  assert_success
  wait_until '[ -s "$LOG" ]'
  run cat "$LOG"
  assert_output 'Answer to ask AbC123: yes'
}

@test "a busy pane that never takes the Enter is reported, though its spinner keeps moving" {
  tmux_stop
  tmux_start env READER_BUSY=1 READER_DEAF=1 "$READER" "$LOG"
  PANE="x/$TM_TARGET"
  wait_until 'screen_has "esc to interrupt"'
  run "$BIN" send --pane "$PANE" 'never'
  assert_failure 3
  assert_output --partial 'did not take the Enter'
  [ ! -s "$LOG" ]
}

@test "--no-submit types only" {
  run "$BIN" send --pane "$PANE" --no-submit 'draft'
  assert_success
  wait_until 'screen_has "> draft"'
  [ ! -s "$LOG" ]
}
