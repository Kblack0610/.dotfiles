#!/usr/bin/env bats
# kblab-menu: the site list comes from home-config, the picked line is cut back to its url and
# handed to xdg-open, and a cancelled menu opens nothing. Every external command is a stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/kblab-menu"
  BIN="$SANDBOX/menu-bin"; OPENED="$SANDBOX/opened"; FOCUSED="$SANDBOX/focused"; NOTES="$SANDBOX/notes"
  mkdir -p "$BIN" "$SANDBOX/hc/scripts"
  export HOME_CONFIG="$SANDBOX/hc" PATH="$BIN:$PATH" OPENED FOCUSED NOTES
  cat >"$HOME_CONFIG/scripts/gen-ha-launcher.py" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --list-sites ] || exit 2
printf 'Zeta\tOps\thttps://zeta.example\nAgents\tOther\thttps://agents.example\n'
EOF
  chmod +x "$HOME_CONFIG/scripts/gen-ha-launcher.py"
  stub xdg-open 'echo "$1" >>"$OPENED"'
  stub hyprctl 'echo "$*" >>"$FOCUSED"'
  stub notify-send 'echo "$2" >>"$NOTES"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }

@test "the picked site opens and Firefox takes focus" {
  stub wofi 'grep Agents'
  run "$SUBJECT"
  assert_success
  assert_equal "$(cat "$OPENED")" "https://agents.example"
  assert_equal "$(cat "$FOCUSED")" 'dispatch focuswindow class:^(firefox)$'
}

@test "the menu lists sites sorted with name, group and url" {
  stub wofi 'cat >"$OPENED.menu"; exit 1'
  run "$SUBJECT"
  assert_success
  assert_equal "$(head -1 "$OPENED.menu")" "Agents  |  Other  |  https://agents.example"
}

@test "a cancelled menu opens nothing" {
  stub wofi 'cat >/dev/null; exit 1'
  run "$SUBJECT"
  assert_success
  assert [ ! -e "$OPENED" ]
}

@test "a missing home-config says so and opens nothing" {
  stub wofi 'grep Agents'
  HOME_CONFIG="$SANDBOX/nope" run "$SUBJECT"
  assert_failure
  assert [ ! -e "$OPENED" ]
  run cat "$NOTES"
  assert_output --partial "home-config not found"
}
