#!/usr/bin/env bats
# Tier 3: the control menu (leader Space) through real fzf on a real tmux server. The first
# chip's hover is in the preview on open, moving the cursor moves the preview to the next chip,
# Enter runs that chip's click and closes, Esc closes. Container only.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim
  ln -sf "${REAL_FZF:?no real fzf}" "$SANDBOX/bin/fzf"
  W="$XDG_CONFIG_HOME/waybar"
  mkdir -p "$W"
  cp "$REPO_ROOT/.config/waybar/pango.sh" "$W/"
  export FX="$BATS_TEST_TMPDIR"
  printf 'ok|A good chip|custom/ok\nbad|A failing chip|custom/bad\n' > "$W/modules.registry"
  cat > "$FX/ok.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn '{text: "OK 3", tooltip: "<b>Good hover</b> line one\nline two", class: "ok"}'
EOF
  printf '#!/usr/bin/env bash\necho "prometheus down" >&2\nexit 4\n' > "$FX/bad.sh"
  chmod +x "$FX/ok.sh" "$FX/bad.sh"
  cat > "$W/config.base" <<EOF
{
    "custom/ok": {"exec": "\$HOME/.config/waybar/modules.sh gate custom/ok $FX/ok.sh", "on-click": "echo left > $FX/clicked"},
    "custom/bad": {"exec": "$FX/bad.sh"}
}
EOF
}

teardown() { ui_teardown; }

open_menu() { TM_WIDTH=140 TM_HEIGHT=30 tmux_start "$REPO_ROOT/.local/bin/control-menu"; }
keep_screen() { mkdir -p "$REPO_ROOT/tests/artifacts"; screen >"$REPO_ROOT/tests/artifacts/control_menu_$1.screen"; }
gone() { ! _tm has-session 2>/dev/null; }

@test "the first chip's hover shows on open, the cursor moves the preview, Esc closes" {
  open_menu
  wait_until 'screen_has "Good hover line one"'
  wait_until 'screen_matches "A good chip +OK 3"'
  screen_has "enter click   alt-enter right-click"
  keep_screen open
  tmux_keys Down
  wait_until 'screen_has "custom/bad: exit 4, no output"'
  screen_has "prometheus down"
  screen_lacks "Good hover"
  tmux_keys Escape
  wait_until gone
}

@test "Enter runs the selected chip's click and closes the menu" {
  open_menu
  wait_until 'screen_has "Good hover"'
  tmux_keys Enter
  wait_until gone
  wait_until '[ -s "$FX/clicked" ]'
  assert_equal "$(cat "$FX/clicked")" left
}
