#!/usr/bin/env bats
# cpu-temp.sh: read_tctl, the one CPU temperature reader fleet-assess and boot-cause source. Fake
# hwmon and thermal trees under CPU_TEMP_HWMON and CPU_TEMP_THERMAL, never the real sysfs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CPU_TEMP_HWMON="$BATS_TEST_TMPDIR/hwmon" CPU_TEMP_THERMAL="$BATS_TEST_TMPDIR/thermal"
  mkdir -p "$CPU_TEMP_HWMON" "$CPU_TEMP_THERMAL"
  # shellcheck source=../../.local/lib/cpu-temp.sh
  . "$ROOT/.local/lib/cpu-temp.sh"
}

zone() { mkdir -p "$CPU_TEMP_THERMAL/thermal_zone$1"; echo "$2" > "$CPU_TEMP_THERMAL/thermal_zone$1/temp"; }

@test "k10temp Tctl wins over a hotter thermal zone" {
  mkdir -p "$CPU_TEMP_HWMON/hwmon3"
  echo k10temp > "$CPU_TEMP_HWMON/hwmon3/name"; echo 72875 > "$CPU_TEMP_HWMON/hwmon3/temp1_input"
  zone 0 99000
  run read_tctl
  assert_output 72.9
}

@test "with no k10temp the hottest zone is read" {
  zone 0 41000; zone 1 63500
  run read_tctl
  assert_output 63.5
}

@test "nothing readable is -, the form fleet-assess's verdict takes" {
  zone 0 ''; zone 1 -273150; zone 2 0
  run read_tctl
  assert_equal "$output" -   # assert_output - would read stdin
}

@test "the throttle point defaults to 95 and an override stands" {
  assert_equal "$FLEET_HOT_TCTL" 95
  run env FLEET_HOT_TCTL=90 bash -c ". '$ROOT/.local/lib/cpu-temp.sh'; echo \$FLEET_HOT_TCTL"
  assert_output 90
}
