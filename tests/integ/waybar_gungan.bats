#!/usr/bin/env bats
# custom/gungan: the red mic on the bar while a gungan voice take runs. What these pin: the module
# reads `gungan status` and refreshes on RTMIN+9 (the signal gungan fires on every start and stop),
# it is not gated (a hot mic is a privacy indicator), it sits beside the passthrough pill on both
# profiles, and a click stops a stream but never touches a record take, whose stop belongs to the
# caller that started it (--type, or agent-voice's --print).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  BASE="$REPO_ROOT/.config/waybar/config.base"
  mkdir -p "$HOME/.local/bin"
}

# gungan_stub <status json>: a gungan whose status prints JSON and whose other verbs are logged.
gungan_stub() {
  printf '#!/usr/bin/env bash\nif [ "$1" = status ]; then printf "%%s\\n" %q; else echo "$*" >> "%s/gungan.calls"; fi\n' \
    "$1" "$BATS_TEST_TMPDIR" > "$HOME/.local/bin/gungan"
  chmod +x "$HOME/.local/bin/gungan"
}

click() { # runs the module's on-click the way waybar does, through sh -c
  local line cmd
  line="$(grep -o '"on-click": ".*gungan stream"' "$BASE")"
  cmd="$(jq -r '."on-click"' <<< "{$line}")"
  sh -c "$cmd" || true
}

@test "the module reads gungan status on signal 9, ungated, beside passthrough on both profiles" {
  run grep -c '"exec": "$HOME/.local/bin/gungan status",$' "$BASE"
  assert_output 1
  run grep -A6 '"custom/gungan": {' "$BASE"
  assert_line --partial '"signal": 9,'
  refute_output --partial 'modules.sh gate'
  for f in config.desktop config.laptop; do
    run grep -A1 '"custom/passthrough",$' "$REPO_ROOT/.config/waybar/$f"
    assert_line --partial '"custom/gungan"'
  done
}

@test "a click during a stream stops the stream" {
  gungan_stub '{"text": "x", "tooltip": "Gungan: Streaming...", "class": "recording"}'
  click
  assert_equal "$(cat "$BATS_TEST_TMPDIR/gungan.calls")" 'stream'
}

@test "a click during a record take, or with nothing running, does nothing" {
  gungan_stub '{"text": "x", "tooltip": "Gungan: Recording...", "class": "recording"}'
  click
  gungan_stub '{"text": "", "tooltip": "", "class": ""}'
  click
  assert [ ! -e "$BATS_TEST_TMPDIR/gungan.calls" ]
}
