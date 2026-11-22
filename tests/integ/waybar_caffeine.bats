#!/usr/bin/env bats
# caffeine.sh: the waybar keep-awake chip. What these pin: the chip is gated, polled and in the
# registry, and both profiles carry it in place of the built-in idle_inhibitor; with no hold it reads
# off; a toggle starts the hold as its own user unit (not a child of the bar, which desk.service kills
# with its cgroup) running systemd-inhibit --what=idle, and the chip reads on; a second toggle stops
# that unit and the chip reads off, and signals the bar so Noctalia redraws too; Noctalia shows the
# same gated chip, so `modules.sh off caffeine` hides it on either bar.
# systemctl and systemd-run are stubs over one state file: present means the unit is active.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  export UNIT_STATE="$BATS_TEST_TMPDIR/unit.active"
  cat > "$SANDBOX/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$UNIT_STATE"
STUB
  cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "--user is-active --quiet waybar-caffeine") [ -e "$UNIT_STATE" ] ;;
  "--user stop waybar-caffeine") rm -f "$UNIT_STATE" ;;
  *) echo "unexpected systemctl $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/systemd-run" "$SANDBOX/bin/systemctl"
}

chip() { run "$W/caffeine.sh"; assert_success; CLASS="$(jq -r .class <<< "$output")"; }

@test "the module is gated, polled, on signal 10, in the registry, and replaces idle_inhibitor in both profiles" {
  run grep -A9 '"custom/caffeine": {' "$W/config.base"
  assert_line --partial '"exec": "$HOME/.config/waybar/modules.sh gate custom/caffeine $HOME/.config/waybar/caffeine.sh",'
  assert_line --partial '"interval": 10,'
  assert_line --partial '"signal": 10,'
  run grep -c '^caffeine|.*|custom/caffeine$' "$W/modules.registry"
  assert_output 1
  for p in config.desktop config.laptop; do
    run grep -c '"custom/caffeine",' "$W/$p"; assert_output 1
    run grep -c '"idle_inhibitor"' "$W/$p"; assert_output 0
  done
}

@test "with no hold the chip reads off" {
  chip
  assert_equal "$CLASS" deactivated
}

@test "a toggle starts the hold as its own user unit holding idle, and the chip reads on" {
  run "$W/caffeine.sh" toggle
  assert_success
  run cat "$UNIT_STATE"
  assert_output --regexp '^--user .*--unit=waybar-caffeine systemd-inhibit --what=idle '
  chip
  assert_equal "$CLASS" activated
}

@test "a second toggle stops the unit, and the chip reads off" {
  echo held > "$UNIT_STATE"
  chip
  assert_equal "$CLASS" activated
  run "$W/caffeine.sh" toggle
  assert_success
  assert [ ! -e "$UNIT_STATE" ]
  chip
  assert_equal "$CLASS" deactivated
}

@test "an unknown verb is a usage error" {
  run "$W/caffeine.sh" bogus
  assert_failure 2
  assert_output --partial usage
}

@test "a toggle signals the chip, so Noctalia redraws it at once" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/desk.calls"\n' "$BATS_TEST_TMPDIR" > "$HOME/.local/bin/desk"
  chmod +x "$HOME/.local/bin/desk"
  run "$W/caffeine.sh" toggle
  assert_success
  run cat "$BATS_TEST_TMPDIR/desk.calls"
  assert_output 'signal custom/caffeine'
}

@test "Noctalia's caffeine is the same gated chip, its click acting rather than opening a hover" {
  run grep -A3 '^\[widget.caffeine\]$' "$REPO_ROOT/.config/noctalia/config.toml"
  assert_line 'type = "dotfiles/chips:chip"'
  assert_line 'module = "custom/caffeine"'
  assert_line 'dropdown = false'
}
