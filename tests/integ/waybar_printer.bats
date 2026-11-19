#!/usr/bin/env bats
# printer.sh: the waybar 3D printer chip. What these pin: the module is gated and in group/status
# after custom/ci; a print reads its percent with the slicer's time left (Moonraker metadata, not
# file progress); a print still at 0s reads heat; no answer reads a dim icon; Klipper not ready is
# amber; the A1 is bright when its port accepts, dim when not; with no address set the chip is hidden;
# in every state the text fits 10 characters, so the chip cannot push the bar off a 1920px screen.
# curl is a stub serving fixtures, and the A1 port is a local listener.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  export FX="$BATS_TEST_TMPDIR"
  export CC_NEPTUNE_URL=http://neptune.test
  # Port 1 on loopback refuses at once: the A1 reads off unless a test listens.
  export CC_A1_ADDR=127.0.0.1:1
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
case "$*" in
  *server/files/metadata*) cat "$FX/meta.json" 2>/dev/null ;;
  *) cat "$FX/query.json" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
}

teardown() {
  [[ -n ${LISTENER:-} ]] && kill "$LISTENER" 2>/dev/null
  true
}

# neptune <state> <progress> <duration>: the Moonraker objects query for one print.
neptune() {
  jq -n --arg s "$1" --argjson p "$2" --argjson d "$3" '{result: {status: {
    print_stats: {state: $s, filename: "shell_0.4n_0.16mm_PLA.gcode", print_duration: $d},
    virtual_sdcard: {progress: $p},
    extruder: {temperature: 219.6, target: 220}, heater_bed: {temperature: 60.2, target: 60}}}}' > "$FX/query.json"
}

chip() { run "$W/printer.sh"; assert_success; TEXT="$(jq -r .text <<< "$output")"; TIP="$(jq -r .tooltip <<< "$output")"; CLASS="$(jq -r .class <<< "$output")"; }

@test "the module is gated, on signal 10, in group/status after custom/ci, and in the registry" {
  run grep -A8 '"custom/printer": {' "$W/config.base"
  assert_line --partial '"exec": "$HOME/.config/waybar/modules.sh gate custom/printer $HOME/.config/waybar/printer.sh",'
  assert_line --partial '"signal": 10,'
  run grep -A1 '"custom/ci",$' "$W/config.base"
  assert_line --partial '"custom/printer"'
  run grep -x 'printer|3D printers|custom/printer' "$W/modules.registry"
  assert_success
}

@test "a print reads its percent, with the slicer's time left on hover" {
  neptune printing 0.43 3600
  echo '{"result": {"estimated_time": 7200.4}}' > "$FX/meta.json"
  chip
  assert_equal "$TEXT" "󰐫 43% <span alpha='50%'>A1</span>"
  assert_equal "$TIP" "Neptune: printing
shell_0.4n_0.16mm_PLA.gcode
43%, 1h00m in, about 1h00m left
nozzle 220/220C, bed 60/60C

A1: no answer at 127.0.0.1:1"
}

@test "without metadata the time left falls back to file progress" {
  neptune printing 0.5 1800
  chip
  assert_output --partial '50%, 0h30m in, about 0h30m left'
}

@test "a print at 0s printed is still heating" {
  neptune printing 0 0
  chip
  assert_equal "$TEXT" "󰐫 heat <span alpha='50%'>A1</span>"
}

@test "paused is amber with its class, error is red, done is green" {
  neptune paused 0.2 600; chip
  assert_equal "$TEXT" "<span color='#ffcc2f'>󰐫 20%</span> <span alpha='50%'>A1</span>"
  assert_equal "$CLASS" warn
  neptune error 0 0; chip
  assert_equal "$CLASS" critical
  assert_output --partial '󰐫 err'
  neptune complete 1 7200; chip
  assert_output --partial "<span color='#a6e34a'>󰐫 done</span>"
}

@test "no answer from either printer dims both" {
  CURL_FAIL=1 chip
  assert_equal "$TEXT" "<span alpha='50%'>󰐫</span> <span alpha='50%'>A1</span>"
  assert_line --partial 'so the slicer cannot send to it'
}

@test "Moonraker up with Klipper not ready is amber and names the reason" {
  echo '{"error": {"code": 503, "message": "Klippy Host not connected"}}' > "$FX/query.json"
  chip
  assert_equal "$CLASS" warn
  assert_output --partial 'Klippy Host not connected'
}

@test "the A1 reads on when its port accepts" {
  # The listener writes its port to a fifo once it listens; the read blocks until then (10s guard).
  mkfifo "$FX/port"
  python3 -c 'import socket,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
f=open(sys.argv[1],"w"); f.write("%d\n" % s.getsockname()[1]); f.close()
while True: s.accept()' "$FX/port" 3>&- &
  LISTENER=$!
  read -r -t 10 port < "$FX/port"
  export CC_A1_ADDR="127.0.0.1:$port"
  neptune standby 0 0
  chip
  assert_equal "$TEXT" "󰐫 A1"
}

@test "with no address set the chip is hidden" {
  unset CC_NEPTUNE_URL CC_A1_ADDR
  chip
  assert_equal "$TEXT" ""
}

@test "an idle printer with no file keeps its temperatures in place" {
  neptune standby 0 0
  jq '.result.status.print_stats.filename = ""' "$FX/query.json" > "$FX/q" && mv "$FX/q" "$FX/query.json"
  chip
  assert_equal "$TIP" "Neptune: standby
nozzle 220/220C, bed 60/60C

A1: no answer at 127.0.0.1:1"
}

@test "a zero slicer estimate falls back to file progress, and 57% reads 57" {
  neptune printing 0.57 570
  echo '{"result": {"estimated_time": 0}}' > "$FX/meta.json"
  chip
  assert_output --partial '57%, 0h09m in, about 0h07m left'
}

@test "a missing heater reads 0, not a crash" {
  neptune printing 0.5 1800
  jq 'del(.result.status.heater_bed)' "$FX/query.json" > "$FX/q" && mv "$FX/q" "$FX/query.json"
  chip
  assert_output --partial 'bed 0/0C'
}

@test "one printer configured and off reads its dim icon alone" {
  unset CC_A1_ADDR
  CURL_FAIL=1 chip
  assert_equal "$TEXT" "<span alpha='50%'>󰐫</span>"
}

@test "an answer that is not JSON is a wrong address, not Klipper" {
  echo '<html>502</html>' > "$FX/query.json"
  chip
  assert_equal "$CLASS" warn
  assert_output --partial 'not as Moonraker'
}

@test "every state fits the bar: at most MAX_CHARS visible characters" {
  # The status cluster already fills a 1920px bar; the first version of this chip read
  # `Neptune 21%  A1 on` and pushed the right side over the workspaces (2026-11-17).
  MAX_CHARS=10
  echo '{"result": {"estimated_time": 7200}}' > "$FX/meta.json"
  for st in "printing 1 3600" "printing 0 0" "paused 0.5 60" "error 0 0" "complete 1 60" "standby 0 0" notjson notready; do
    case $st in
      notjson) echo "<html>502</html>" > "$FX/query.json" ;;
      notready) echo '{"error": {"message": "Klippy Host not connected"}}' > "$FX/query.json" ;;
      # shellcheck disable=SC2086  # the state, progress and duration are three words on purpose
      *) neptune $st ;;
    esac
    chip
    vis="$(sed 's/<[^>]*>//g' <<< "$TEXT")"
    (( ${#vis} <= MAX_CHARS )) || fail "$st reads '$vis', ${#vis} chars, over $MAX_CHARS"
  done
}
