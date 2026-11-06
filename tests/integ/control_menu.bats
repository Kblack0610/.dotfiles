#!/usr/bin/env bats
# control-menu: every waybar chip's hover from the keyboard (leader Space). What these pin: the
# rows are modules.registry and nothing else; what a chip runs and what a click does come from the
# waybar config, so a hidden chip still lists and previews; a registry row the config lacks is
# shown, never dropped; a failing chip shows why; Pango becomes terminal text; the window rows are
# the described exec binds with the chord that reaches each. The real-config test parses
# config.base and config.pin-full, so a comment added mid-line fails here first.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MENU="$REPO_ROOT/.local/bin/control-menu"
  W="$XDG_CONFIG_HOME/waybar"
  mkdir -p "$W" "$XDG_STATE_HOME/waybar"
  cp "$REPO_ROOT/.config/waybar/pango.sh" "$W/"
  export FX="$BATS_TEST_TMPDIR"
  cat > "$W/modules.registry" <<'EOF'
# key|label|ids
ok|A good chip|custom/ok
bad|A failing chip|custom/bad
gone|Not in the config|custom/gone
EOF
  cat > "$FX/ok.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn '{text: "<b>OK</b> 3", tooltip: "<b>Head</b> <span color='"'"'#ff0000'"'"'>red</span> after\nline two &amp; more", class: "ok"}'
EOF
  printf '#!/usr/bin/env bash\necho "prometheus down" >&2\nexit 4\n' > "$FX/bad.sh"
  chmod +x "$FX/ok.sh" "$FX/bad.sh"
  # hyprctl: `binds -j` serves $FX/binds.json (no binds unless a test writes some), anything
  # else is logged, so no test reaches the live compositor.
  echo '[]' > "$FX/binds.json"
  cat > "$SANDBOX/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "binds -j" ] && exec cat "$FX/binds.json"
printf '%s\n' "$*" >> "$FX/dispatched"
EOF
  chmod +x "$SANDBOX/bin/hyprctl"
  # hub: `tabs` lists two, `--once --tab X` prints a page; kitty logs what it would open.
  export HUB="$FX/hub"
  cat > "$HUB" <<'EOF'
#!/usr/bin/env bash
[ "$*" = tabs ] && exec printf 'home\tHome\tWhat needs me?\nqueue\tQueue\tWhat will agents do next?\n'
echo "hub page: $* at ${COLUMNS:-?} columns"
EOF
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FX/opened"\n' > "$SANDBOX/bin/kitty"
  chmod +x "$HUB" "$SANDBOX/bin/kitty"
  # The gate prefix points at a modules.sh that does not exist: the menu must run what is behind it.
  cat > "$W/config.base" <<EOF
// -*- mode: jsonc -*-
{
    // a whole-line comment
    "custom/ok": {
        "exec": "\$HOME/.config/waybar/modules.sh gate custom/ok $FX/ok.sh",
        "on-click": "echo left > $FX/clicked",
        "on-click-right": "echo right > $FX/clicked"
    },
    "custom/bad": {
        "exec": "\$HOME/.config/waybar/modules.sh gate custom/bad $FX/bad.sh",
        "on-click": "xdg-open https://example.com/x"
    }
}
EOF
}

@test "rows are the registry in order; a chip the config lacks is named, not dropped" {
  run "$MENU" rows
  assert_success
  assert_equal "$(cut -f1 <<< "$output" | tr '\n' ' ')" "ok bad gone hub hub "
  assert_line --partial "(not in the waybar config: custom/gone)"
}

@test "rows --live carry each chip's bar text without markup; a chip hidden on the bar still lists" {
  echo custom/ok > "$XDG_STATE_HOME/waybar/modules.off"
  run "$MENU" rows --live
  assert_success
  assert_line --regexp $'^ok\tok +A good chip +OK 3 +\\(hidden on bar\\)$'
  assert_line --regexp $'^bad\t.*A failing chip +-$'
}

@test "preview runs the command behind the gate and turns Pango into terminal colour" {
  run "$MENU" preview ok
  assert_success
  assert_line --index 0 $'\e[1mHead\e[0m \e[38;2;255;0;0mred\e[0m after'
  assert_line --index 1 "line two & more"
  assert_line "enter: echo left > $FX/clicked"
  assert_line "alt-enter: echo right > $FX/clicked"
}

@test "a failing chip's preview says its exit code and stderr, not a blank pane" {
  run "$MENU" preview bad
  assert_success
  assert_line "custom/bad: exit 4, no output"
  assert_line "prometheus down"
  assert_line "enter: xdg-open https://example.com/x"
  refute_line --partial "alt-enter"
}

@test "click runs the chip's on-click, and right runs its on-click-right" {
  mkfifo "$FX/clicked"
  run "$MENU" click ok
  assert_success
  run timeout 5 cat "$FX/clicked"
  assert_output left
  run "$MENU" click ok right
  run timeout 5 cat "$FX/clicked"
  assert_output right
}

@test "a click the chip does not have fails and says so" {
  run "$MENU" click bad right
  assert_failure
  assert_output "bad has no on-click-right"
}

# Super+D, the leader entry (two chords reach it; the first wins), a nested leaf, an Esc back to
# a parent that must not count as the way in, an undescribed bind, and a non-exec described one.
write_binds() {
  jq -n '[
    {submap: "", modmask: 64, key: "D", dispatcher: "exec", arg: "wofi --show drun", has_description: true, description: "app launcher"},
    {submap: "", modmask: 64, key: "Q", dispatcher: "killactive", arg: "", has_description: false, description: ""},
    {submap: "", modmask: 72, key: "R", dispatcher: "exec", arg: "gungan stream", has_description: true, description: "stream transcription"},
    {submap: "", modmask: 64, key: "A", dispatcher: "submap", arg: "pinbar", has_description: true, description: "pin leader"},
    {submap: "", modmask: 5, key: "A", dispatcher: "submap", arg: "pinbar", has_description: true, description: "pin leader"},
    {submap: "pinbar", modmask: 0, key: "a", dispatcher: "exec", arg: "kitty -e agent-panel", has_description: true, description: "agent panel"},
    {submap: "pinbar", modmask: 0, key: "a", dispatcher: "exec", arg: "pin-hint.sh close", has_description: false, description: ""},
    {submap: "pinbar", modmask: 0, key: "u", dispatcher: "submap", arg: "pinbar-utils", has_description: true, description: "utils >"},
    {submap: "pinbar-utils", modmask: 0, key: "t", dispatcher: "submap", arg: "pinbar-timebox", has_description: true, description: "timebox >"},
    {submap: "pinbar-timebox", modmask: 0, key: "escape", dispatcher: "submap", arg: "pinbar-utils", has_description: true, description: "back"},
    {submap: "pinbar-timebox", modmask: 0, key: "p", dispatcher: "exec", arg: "timebox pause", has_description: true, description: "pause"}
  ]' > "$FX/binds.json"
}

@test "window rows: each described exec bind after the chips, with the chord that reaches it" {
  write_binds
  run "$MENU" rows
  assert_success
  assert_equal "$(cut -f1 <<< "$output" | tr '\n' ' ')" "ok bad gone hub hub win win win win "
  assert_line $'win\twindow    app launcher                       Super+D\twofi --show drun'
  assert_line --regexp $'^win\twindow +stream transcription +Super\\+Alt\\+R\tgungan stream$'
  assert_line --regexp $'^win\twindow +agent panel +Super\\+A a\tkitty -e agent-panel$'
  assert_line --regexp $'^win\twindow +pause +Super\\+A u t p\ttimebox pause$'
  refute_output --partial "pin-hint.sh close"
  refute_output --partial "utils >"
}

@test "a window row's Enter runs its bind through hyprctl dispatch exec; its preview names it" {
  write_binds
  run "$MENU" preview win "timebox pause"
  assert_success
  assert_line "timebox pause"
  run "$MENU" click win left "timebox pause"
  assert_success
  assert_equal "$(cat "$FX/dispatched")" "dispatch exec timebox pause"
  run "$MENU" click win left
  assert_failure
}

@test "hub rows are hub tabs; the preview is that tab's page and Enter opens it as a popup" {
  run "$MENU" rows
  assert_success
  assert_line --regexp $'^hub\thub +Queue +What will agents do next\\?\tqueue$'
  FZF_PREVIEW_COLUMNS=61 run "$MENU" preview hub queue
  assert_success
  assert_line "hub page: --once --tab queue at 61 columns"
  assert_line "enter: hub --popup --tab queue"
  mkfifo "$FX/opened"
  run "$MENU" click hub left queue
  assert_success
  run timeout 5 cat "$FX/opened"
  assert_output "--class floating-term -e $HUB --popup --tab queue"
}

@test "pango_ansi: a close restores the tag still open; NO_COLOR strips; entities decode" {
  . "$W/pango.sh"
  run pango_ansi <<< "<b>a <span alpha='60%'>b</span> c</b> &lt;x&gt;"
  assert_output $'\e[1ma \e[2mb\e[0m\e[1m c\e[0m <x>'
  NO_COLOR=1 run pango_ansi <<< "<tt><b>a</b> <span color='#a6e34a'>b</span></tt>"
  assert_output "a b"
}

@test "the real waybar config parses, and every registry chip has an exec in it" {
  for f in config.base config.pin-full modules.registry; do
    ln -sf "$REPO_ROOT/.config/waybar/$f" "$W/$f"
  done
  run "$MENU" rows
  assert_success
  refute_output --partial "not in the waybar config"
  assert_equal "$(grep -cvE $'^(hub|win)\t' <<< "$output")" "$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/.config/waybar/modules.registry")"
}
