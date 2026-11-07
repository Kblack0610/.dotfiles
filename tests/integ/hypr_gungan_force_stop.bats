#!/usr/bin/env bats
# gungan-force-stop.sh (Super+Ctrl+R): every kill is a pid it checked, never a -f pattern. What
# these pin: a stream's gungan subshell, client and the client's pw-record die; a record take's
# pw-record and whisper-cpp die by name plus the take's file; a pw-record or whisper-cpp on any
# other file lives; a stale pidfile whose pid is no stream client is not signalled; the lock and
# pidfile go, the bar is signalled and the notice is posted. Fakes are bash or sleep exec'd
# through links of the real names, so /proc/<pid>/comm reads true. GUNGAN_REC points the take
# into the test dir and a pkill stub swallows the waybar signal, so no live take or bar is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  STOP="$REPO_ROOT/.config/hypr/scripts/gungan-force-stop.sh"
  T="$BATS_TEST_TMPDIR"
  export XDG_RUNTIME_DIR="$T/run" GUNGAN_REC="$T/gungan_recording"
  mkdir -p "$XDG_RUNTIME_DIR" "$T/fake"
  for n in gungan pw-record whisper-cpp; do ln -s "$(command -v bash)" "$T/fake/$n"; done
  mkfifo "$T/hold" "$T/ready"
  REAL_PKILL="$(command -v pkill)"
  printf '#!/usr/bin/env bash\n[ "$1" = -RTMIN+9 ] && { echo "$*" >> "%s/calls"; exit 0; }\nexec %q "$@"\n' "$T" "$REAL_PKILL" > "$SANDBOX/bin/pkill"
  printf '#!/usr/bin/env bash\necho "notify-send $*" >> "%s/calls"\n' "$T" > "$SANDBOX/bin/notify-send"
  chmod +x "$SANDBOX/bin/pkill" "$SANDBOX/bin/notify-send"
  PIDS=()
}

teardown() {
  local p
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
}

# fake <name> <arg...>: a process named <name> holding <args> in its command line, blocked on a
# fifo read (a builtin, so no child outlives it). Its pid in $FAKE.
fake() {
  local n="$1"; shift
  "$T/fake/$n" -c 'read -r _ <> "$1"' "$n" "$T/hold" "$@" >/dev/null 2>&1 </dev/null 3>&- &
  FAKE=$!
  disown "$FAKE"
  PIDS+=("$FAKE")
}

alive() { kill -0 "$1" 2>/dev/null; }

@test "a stream: its gungan subshell, client and the client's pw-record die, by pid" {
  # gungan's cmd_stream: a subshell (comm gungan) backgrounds the client and records its pid; the
  # client runs its own pw-record. Each reports on the ready fifo once its part is up.
  cat > "$T/sub.sh" <<'EOF'
bash -c '"$1" -c "read -r _ <> \"\$1\"" pw-record "$2" - & echo "rec $!" > "$3"; read -r _ <> "$2"' \
  stream_client.py "$FAKE_DIR/pw-record" "$HOLD" "$READY" &
echo $! > "$XDG_RUNTIME_DIR/gungan_stream.pid"
echo sub > "$READY"
read -r _ <> "$HOLD"
EOF
  exec 5<> "$T/ready"
  FAKE_DIR="$T/fake" HOLD="$T/hold" READY="$T/ready" "$T/fake/gungan" "$T/sub.sh" >/dev/null 2>&1 </dev/null 3>&- &
  sub=$!
  disown "$sub"
  PIDS+=("$sub")
  read -r -u 5 a b
  read -r -u 5 c d
  rec="$b$d"
  client="$(cat "$XDG_RUNTIME_DIR/gungan_stream.pid")"
  PIDS+=("$rec" "$client")
  run ps -o comm= -p "$sub" -p "$rec"
  assert_output $'gungan\npw-record'

  run "$STOP"
  assert_success
  for p in "$sub" "$client" "$rec"; do
    run alive "$p"
    assert_failure
  done
  assert [ ! -e "$XDG_RUNTIME_DIR/gungan_stream.pid" ]
}

@test "a record take: pw-record and whisper-cpp on the take die, the same names on other files live" {
  fake pw-record --format=s16 "$GUNGAN_REC.wav"
  rec=$FAKE
  fake whisper-cpp -m model.bin -f "$GUNGAN_REC.wav"
  asr=$FAKE
  fake pw-record --format=s16 "$T/other.wav"
  other_rec=$FAKE
  fake whisper-cpp -f "$T/other.wav"
  other_asr=$FAKE
  touch "$GUNGAN_REC.lock"

  run "$STOP"
  assert_success
  for p in "$rec" "$asr"; do
    run alive "$p"
    assert_failure
  done
  for p in "$other_rec" "$other_asr"; do
    run alive "$p"
    assert_success
  done
  assert [ ! -e "$GUNGAN_REC.lock" ]
  run cat "$T/calls"
  assert_line '-RTMIN+9 -x waybar'
  assert_line 'notify-send Gungan Force killed'
}

@test "a stale pidfile whose pid is no stream client is not signalled, and the pidfile goes" {
  fake pw-record "$T/other.wav"
  bystander=$FAKE
  echo "$bystander" > "$XDG_RUNTIME_DIR/gungan_stream.pid"
  run "$STOP"
  assert_success
  run alive "$bystander"
  assert_success
  assert [ ! -e "$XDG_RUNTIME_DIR/gungan_stream.pid" ]
}
