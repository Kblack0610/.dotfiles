#!/usr/bin/env bats
# laptop-kbd: turns the built-in keyboard off and on by unbinding its HID interfaces. Driven
# against a fake sysfs tree whose control files are read-only, so every write goes through a sudo
# stub that does what the kernel would: unbind drops the interface's driver link, drivers_probe
# restores it unless the interface is one no driver claims (.0002, as on the real N-KEY).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  [ "$(id -u)" != 0 ] || skip "root writes the read-only fake sysfs directly, bypassing the sudo stub"

  KBD="$REPO_ROOT/.local/bin/laptop-kbd"
  export LAPTOP_KBD_SYSFS="$BATS_TEST_TMPDIR/sys root"
  export SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  local s=$LAPTOP_KBD_SYSFS
  mkdir -p "$s/bus/hid/drivers/asus" "$s/class/input"
  local i
  for i in 0001 0002 0003; do
    mkdir -p "$s/bus/hid/devices/0003:0B05:19B6.$i"
  done
  # Inputs as the kernel lays them out: class/input/inputN links to the device's own dir. keyd's
  # is virtual, and the laptop keyboard's own input is named like a keyboard (as on some ASUS).
  add_input 1 "devices/virtual/input" "keyd virtual keyboard"
  add_input 5 "bus/hid/devices/0003:0B05:19B6.0001/input" "Asus Keyboard"
  ln -s ../../drivers/asus "$s/bus/hid/devices/0003:0B05:19B6.0001/driver"
  ln -s ../../drivers/asus "$s/bus/hid/devices/0003:0B05:19B6.0003/driver"
  : >"$s/bus/hid/drivers/asus/unbind"
  : >"$s/bus/hid/drivers_probe"
  chmod 444 "$s/bus/hid/drivers/asus/unbind" "$s/bus/hid/drivers_probe"

  cat >"$SANDBOX/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# sudo stub: only `sudo tee <sysfs file>`, emulating the kernel's response to the write.
[ "$1" = tee ] || { echo "sudo stub: unexpected $*" >&2; exit 1; }
v=$(cat); f=$2; hid="$LAPTOP_KBD_SYSFS/bus/hid"
echo "$f <- $v" >>"$SUDO_LOG"
case "$f" in
  */unbind) rm "$hid/devices/$v/driver" ;;
  */drivers_probe) case "$v" in *.0002) ;; *) ln -s ../../drivers/asus "$hid/devices/$v/driver" ;; esac ;;
esac
EOF
  chmod +x "$SANDBOX/bin/sudo"
}

add_input() {
  local s=$LAPTOP_KBD_SYSFS
  mkdir -p "$s/$2/input$1"
  echo "$3" >"$s/$2/input$1/name"
  ln -s "$s/$2/input$1" "$s/class/input/input$1"
}

plug_corne() { add_input 2 "devices/virtual/misc/uhid/0005:0000:0000.0007/input" "ken corne Keyboard"; } # Bluetooth, via uhid

@test "status reports on and each interface's driver, and is the default" {
  run "$KBD"
  assert_success
  assert_line --index 0 "laptop keyboard: on"
  assert_line "  0003:0B05:19B6.0001  driver: asus"
  assert_line "  0003:0B05:19B6.0002  driver: (none)"
}

@test "off unbinds every bound interface through sudo and reports off" {
  plug_corne
  run "$KBD" off
  assert_success
  assert_line "other keyboard: ken corne Keyboard"
  assert_line "laptop keyboard: off"
  run cat "$SUDO_LOG"
  assert_line --partial "drivers/asus/unbind <- 0003:0B05:19B6.0001"
  assert_line --partial "drivers/asus/unbind <- 0003:0B05:19B6.0003"
  refute_line --partial "0003:0B05:19B6.0002"
  run "$KBD" status
  assert_line --index 0 "laptop keyboard: off"
}

@test "off refuses with no other keyboard: keyd's virtual one and the laptop's own input do not count" {
  run "$KBD" off
  assert_failure
  assert_output --partial "no other keyboard found"
  [ ! -e "$SUDO_LOG" ]
}

@test "off --force skips the other-keyboard check" {
  run "$KBD" off --force
  assert_success
  assert_line "laptop keyboard: off"
}

@test "on probes the unbound interfaces back and reports on" {
  plug_corne
  "$KBD" off >/dev/null
  run "$KBD" on
  assert_success
  assert_line "laptop keyboard: on"
  run "$KBD" status
  assert_line "  0003:0B05:19B6.0001  driver: asus"
  assert_line "  0003:0B05:19B6.0003  driver: asus"
}

@test "toggle flips the state each run" {
  plug_corne
  run "$KBD" toggle
  assert_success
  assert_line "laptop keyboard: off"
  run "$KBD" toggle
  assert_success
  assert_line "laptop keyboard: on"
}

@test "a failed sudo write dies naming the file and how to restore" {
  printf '#!/usr/bin/env bash\necho "sudo: incorrect password" >&2; exit 1\n' >"$SANDBOX/bin/sudo"
  run "$KBD" off --force
  assert_failure
  assert_output --partial "sudo: incorrect password"
  assert_output --partial "drivers/asus/unbind failed"
  assert_output --partial "'laptop-kbd on' restores"
}

@test "a mistyped flag or extra argument is a usage error, not a silent no-force" {
  plug_corne
  for args in "off --forse" "on --force" "status x" "off --force x"; do
    # shellcheck disable=SC2086
    run "$KBD" $args
    assert_failure 2
  done
  [ ! -e "$SUDO_LOG" ]
}

@test "LAPTOP_KBD_ID matches in lowercase too" {
  LAPTOP_KBD_ID=0b05:19b6 run "$KBD" status
  assert_success
  assert_line --index 0 "laptop keyboard: on"
}

@test "off when already off and on when already on write nothing" {
  run "$KBD" on
  assert_line "laptop keyboard: already on"
  "$KBD" off --force >/dev/null
  rm "$SUDO_LOG"
  run "$KBD" off
  assert_line "laptop keyboard: already off"
  [ ! -e "$SUDO_LOG" ]
}

@test "a missing device names LAPTOP_KBD_ID; --help works without one" {
  LAPTOP_KBD_ID=FFFF:FFFF run "$KBD" status
  assert_failure
  assert_output --partial "LAPTOP_KBD_ID"
  LAPTOP_KBD_ID=FFFF:FFFF run "$KBD" --help
  assert_success
  assert_output --partial "laptop-kbd off [--force]"
}

@test "an unknown command prints usage and exits 2" {
  run "$KBD" bogus
  assert_failure 2
  assert_output --partial "laptop-kbd toggle"
}
