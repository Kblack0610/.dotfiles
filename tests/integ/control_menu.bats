#!/usr/bin/env bats
# control-menu: every waybar chip's hover from the keyboard (leader Space). What these pin: the
# rows are modules.registry and nothing else; what a chip runs and what a click does come from the
# waybar config, so a hidden chip still lists and previews; a registry row the config lacks is
# shown, never dropped; a failing chip shows why; Pango becomes terminal text. The last test parses
# the real config.base and config.pin-full, so a comment added mid-line fails here first.

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
  assert_equal "$(cut -f1 <<< "$output" | tr '\n' ' ')" "ok bad gone "
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
  assert_equal "${#lines[@]}" "$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/.config/waybar/modules.registry")"
}
