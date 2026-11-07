#!/usr/bin/env bats
# custom/audio-input: the input apps hear and the switch between the rig's inputs. What these
# pin: the chip is on the desktop bar beside a pulseaudio chip with no mic part, and nowhere on
# the laptop; set resolves a glob to the live node and changes only the default; next and prev
# wrap; a rig input with REAPER closed is amber; a failed set pages and leaves the default alone;
# watch prints on a server or source event and only when the line changed. pactl and pw-link are
# stubs over files in $FX; `pactl subscribe` reads a fifo, so each event is driven by the test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  M="$W/audio_input.sh"
  export FX="$BATS_TEST_TMPDIR"
  export AUDIO_INPUTS="$FX/inputs.conf"
  cat > "$AUDIO_INPUTS" <<'EOF'
# key|bar|label|source glob
m|Mic|Mic direct|alsa_input.usb-UMC-00.HiFi__Mic4__source*

g|Gtr|Rig Guitar|rig_guitar
b|G+M|Rig Mix UMC|rig_mix_umc
EOF
  printf '%s\n' 48 rig_mix_umc 58 rig_guitar 100 alsa_input.usb-UMC-00.HiFi__Mic4__source.2 \
    113 alsa_input.usb-Brio | paste - - > "$FX/sources"
  echo alsa_input.usb-UMC-00.HiFi__Mic4__source.2 > "$FX/default"
  echo no > "$FX/mute"
  printf '%s\n' 'REAPER:out1' 'REAPER:out2' > "$FX/ports"
  cat > "$SANDBOX/bin/pactl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "list short sources") cat "$FX/sources" ;;
  get-default-source) cat "$FX/default" ;;
  set-default-source*) grep -q "	$2$" "$FX/sources" || exit 1; echo "$2" > "$FX/default"; echo "$*" >> "$FX/pactl.log" ;;
  get-source-volume*) echo "Volume: mono: 65536 / 85% / 0.00 dB" ;;
  get-source-mute*) echo "Mute: $(cat "$FX/mute")"; [[ -p $FX/ack ]] && echo rendered > "$FX/ack" ;;
  "-f json list sources") echo '[{"name":"alsa_input.usb-Brio","description":"Brio 101 Mono"}]' ;;
  subscribe) cat "$FX/events" ;;
  *) echo "pactl stub: $*" >> "$FX/pactl.log"; exit 1 ;;
esac
STUB
  printf '#!/usr/bin/env bash\ncat "$FX/ports"\n' > "$SANDBOX/bin/pw-link"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/notify.log"\n' > "$SANDBOX/bin/notify-send"
  chmod +x "$SANDBOX/bin/pactl" "$SANDBOX/bin/pw-link" "$SANDBOX/bin/notify-send"
}

teardown() {
  [[ -n ${MOD:-} ]] && kill "$MOD" 2>/dev/null
  true
}

# start: run watch, its lines into fd 4, the subscribe fifo open on fd 5, and on fd 6 one ack per
# render (the mute stub writes it), which tells a render that printed nothing from one not yet run.
start() {
  mkfifo "$FX/out" "$FX/events" "$FX/ack"
  exec 6<> "$FX/ack"
  "$M" watch > "$FX/out" 3>&- &
  MOD=$!
  exec 4< "$FX/out" 5> "$FX/events"
}

rendered() { read -r -t 10 -u 6 _ || fail "no render"; }

# next_line: the module's next line, or TIMEOUT (a guard, not a wait: each line is event-driven).
next_line() { read -r -t 10 -u 4 LINE || LINE=TIMEOUT; }

field() { jq -r ".$1" <<<"$LINE"; }

@test "the chip is on the desktop bar after pulseaudio, which drops its mic; not on the laptop" {
  run grep -A1 '"pulseaudio",$' "$W/config.desktop"
  assert_line --partial '"custom/audio-input"'
  run grep -A6 '"pulseaudio": {' "$W/config.desktop"
  refute_output --partial 'format_source'
  run grep -c 'custom/audio-input' "$W/config.laptop"
  assert_output 0
  run grep -A4 '"custom/audio-input": {' "$W/config.base"
  assert_output --partial 'audio_input.sh watch'
  refute_output --partial '"interval"'
}

@test "each pinbar-input leaf sets the input of its own key" {
  run awk '/^submap = pinbar-input$/,/^submap = pinbar-utils$/' "$REPO_ROOT/.config/hypr/conf.d/leader.conf"
  local leaves
  leaves="$(grep -E '^bindpd = ,[a-z], .*audio_input.sh set ' <<<"$output")"
  [[ -n $leaves ]]
  while read -r line; do
    [[ $line =~ ^bindpd\ =\ ,([a-z]),.*audio_input\.sh\ set\ ([a-z])$ ]]
    assert_equal "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done <<<"$leaves"
  run grep -c 'bindpd = ,i, inputs >, submap, pinbar-input' "$REPO_ROOT/.config/hypr/conf.d/leader.conf"
  assert_output 1
}

@test "with no list the chip prints nothing and exits" {
  AUDIO_INPUTS="$FX/absent" run "$M" watch
  assert_success
  assert_output '{"text":""}'
}

@test "watch shows the current input, its volume and the list with it marked" {
  start
  next_line
  assert_equal "$(field class)" ok
  [[ $(field text) == *" Mic" ]]
  assert_equal "$(field tooltip | head -1)" '<b>Mic direct</b>  85%'
  field tooltip | grep -qx '<tt>> m</tt>  Mic direct'
  field tooltip | grep -qx '<tt>  g</tt>  Rig Guitar'
}

@test "set resolves the glob to the live node and changes only the default" {
  echo rig_guitar > "$FX/default"
  run "$M" set m
  assert_success
  assert_equal "$(cat "$FX/default")" alsa_input.usb-UMC-00.HiFi__Mic4__source.2
  run "$M" set b
  assert_equal "$(cat "$FX/default")" rig_mix_umc
  run cat "$FX/pactl.log"
  refute_output --partial 'move-source-output'
  refute_output --partial 'pactl stub'
}

@test "next and prev wrap; next from an input outside the list picks the first" {
  "$M" prev
  assert_equal "$(cat "$FX/default")" rig_mix_umc
  "$M" next
  assert_equal "$(cat "$FX/default")" alsa_input.usb-UMC-00.HiFi__Mic4__source.2
  "$M" next
  assert_equal "$(cat "$FX/default")" rig_guitar
  echo alsa_input.usb-Brio > "$FX/default"
  "$M" next
  assert_equal "$(cat "$FX/default")" alsa_input.usb-UMC-00.HiFi__Mic4__source.2
}

@test "a failed set pages and leaves the default alone" {
  run "$M" set z
  assert_failure
  grep -q -- '-u critical' "$FX/notify.log"
  sed -i '/rig_mix_umc/d' "$FX/sources"
  run "$M" set b
  assert_failure
  assert_output --partial 'Rig Mix UMC is not connected'
  assert_equal "$(cat "$FX/default")" alsa_input.usb-UMC-00.HiFi__Mic4__source.2
}

@test "a rig input with REAPER closed is amber; muted and outside-the-list are classed" {
  echo rig_guitar > "$FX/default"
  : > "$FX/ports"
  start
  next_line
  assert_equal "$(field class)" warn
  field tooltip | grep -q 'REAPER is closed'
  echo yes > "$FX/mute"
  echo "Event 'change' on source #58" >&5
  next_line
  assert_equal "$(field class)" muted
  echo no > "$FX/mute"
  echo alsa_input.usb-Brio > "$FX/default"
  echo "Event 'change' on server #0" >&5
  next_line
  assert_equal "$(field class)" other
  [[ $(field text) == *" Brio 101 Mon" ]]
}

@test "watch prints on a server event only when the line changed, and ignores other events" {
  start
  next_line
  rendered
  echo "Event 'new' on sink-input #9" >&5
  echo "Event 'change' on server #0" >&5
  rendered
  echo rig_mix_umc > "$FX/default"
  echo "Event 'change' on server #0" >&5
  rendered
  next_line
  [[ $(field text) == *" G+M" ]]
}
