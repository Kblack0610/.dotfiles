#!/usr/bin/env bats
# boot-cause: how the previous boot ended is classified from what survives it. journalctl, curl, upsc
# and the sysfs power tree are stubs read from $FIX, so every path (clean, panic, OOM, battery, UPS,
# house power event, silent death) is driven deterministically with no real journal or network.
# The silent-death test is the negative control: with nothing present no other cause may fire.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BC="$ROOT/.local/bin/boot-cause"
  FIX="$BATS_TEST_TMPDIR/fix"; BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FIX" "$BIN" "$FIX/pstore" "$FIX/power/AC0" "$FIX/power/BAT0" "$FIX/thermal/thermal_zone0" "$FIX/hwmon"
  printf '%s\n' '#!/bin/bash
args="$*"
[ -e "$FIX/noprev" ] && exit 1
case $args in
  *" -k "*) cat "$FIX/kern" 2>/dev/null ;;
  *short-unix*) cat "$FIX/tail_unix" ;;
  *"-o cat"*) cat "$FIX/tail_cat" ;;
esac' > "$BIN/journalctl"
  printf '%s\n' '#!/bin/bash
[ -e "$FIX/prom.json" ] || exit 7
cat "$FIX/prom.json"' > "$BIN/curl"
  printf '%s\n' '#!/bin/bash
[ -e "$FIX/ups" ] || exit 1
case $1 in -l) echo myups ;; *) case $2 in ups.status) sed -n 1p "$FIX/ups" ;; battery.charge) sed -n 2p "$FIX/ups" ;; esac ;; esac' > "$BIN/upsc"
  chmod +x "$BIN"/*
  export FIX PATH="$BIN:$PATH"
  export BOOT_CAUSE_HOST=testhost BOOT_CAUSE_BOOT_ID=boot-now BOOT_CAUSE_BOOT_EPOCH=1795000600
  export BOOT_CAUSE_DIR="$BATS_TEST_TMPDIR/rec" BOOT_CAUSE_STATE="$BATS_TEST_TMPDIR/state"
  export BOOT_CAUSE_PSTORE="$FIX/pstore" BOOT_CAUSE_POWER="$FIX/power" BOOT_CAUSE_THERMAL="$FIX/thermal" BOOT_CAUSE_HWMON="$FIX/hwmon"
  echo Mains > "$FIX/power/AC0/type"; echo 1 > "$FIX/power/AC0/online"
  echo Battery > "$FIX/power/BAT0/type"; echo 90 > "$FIX/power/BAT0/capacity"; echo Discharging > "$FIX/power/BAT0/status"
  echo 51000 > "$FIX/thermal/thermal_zone0/temp"
}

# journal_end <unix text lines...> -- the previous boot's last lines, as both views of journalctl.
journal_end() {
  : > "$FIX/tail_unix"; : > "$FIX/tail_cat"
  local t=1795000000 l
  for l in "$@"; do
    printf '%s.000001 testhost systemd[1]: %s\n' "$t" "$l" >> "$FIX/tail_unix"
    printf '%s\n' "$l" >> "$FIX/tail_cat"
    t=$((t + 1))
  done
}
last_row() { tail -n1 "$BOOT_CAUSE_DIR/testhost.jsonl"; }
cause() { last_row | jq -r .cause; }

@test "a log ending on the power-off target is a clean shutdown" {
  journal_end 'Stopped target Basic System.' 'Reached target System Power Off.' 'Journal stopped'
  run "$BC" record
  assert_success
  assert_equal "$(cause)" clean-shutdown
}

@test "a log ending on the reboot target is a clean reboot" {
  journal_end 'Reached target System Reboot.' 'Shutting down.'
  run "$BC" record
  assert_equal "$(cause)" clean-reboot
}

@test "a Journal stopped line far from the end is a journald restart, not a shutdown" {
  local pad=() i
  for i in $(seq 30); do pad+=("app: line $i"); done
  journal_end 'Journal stopped' 'Journal started' "${pad[@]}"
  run "$BC" record
  assert_equal "$(cause)" silent-death
}

@test "a pstore dump saved after the log stopped is a kernel panic" {
  journal_end 'app: working'
  touch -d @1795000300 "$FIX/pstore/dmesg-efi-1"
  run "$BC" record
  assert_equal "$(cause)" kernel-panic
  assert_equal "$(last_row | jq -r .confidence)" high
}

@test "a kernel OOM line before the end is out-of-memory" {
  journal_end 'app: working'
  echo 'Out of memory: Killed process 4242 (java)' > "$FIX/kern"
  run "$BC" record
  assert_equal "$(cause)" out-of-memory
  run jq -r '.evidence[]' <<<"$(last_row)"
  assert_output --partial 'Killed process 4242'
}

@test "a GPU fault line is a gpu-fault" {
  journal_end 'app: working'
  echo 'NVRM: Xid (PCI:0000:01:00): 79, GPU has fallen off the bus.' > "$FIX/kern"
  run "$BC" record
  assert_equal "$(cause)" gpu-fault
}

@test "a last sample on battery at 3% is battery-exhausted" {
  journal_end 'app: working'
  echo 0 > "$FIX/power/AC0/online"; echo 3 > "$FIX/power/BAT0/capacity"
  "$BC" sample
  run env BOOT_CAUSE_BOOT_EPOCH=$(( $(date +%s) + 60 )) "$BC" record   # the sample is older than the boot it explains
  assert_equal "$(cause)" battery-exhausted
}

@test "a last sample with the UPS on battery is ups-on-battery" {
  journal_end 'app: working'
  printf "OB DISCHRG\n61\n" > "$FIX/ups"
  "$BC" sample
  run env BOOT_CAUSE_BOOT_EPOCH=$(( $(date +%s) + 60 )) "$BC" record
  assert_equal "$(cause)" ups-on-battery
  assert_equal "$(last_row | jq -r .last_sample.ups.charge_pct)" 61
}

@test "other hosts booting in the same window make it a house power event, and this host is not counted" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[
    {metric:{instance:"self:9100"},value:[0,"1795000600"]},
    {metric:{instance:"b:9100"},value:[0,"1795000580"]},
    {metric:{instance:"c:9100"},value:[0,"1795000610"]},
    {metric:{instance:"10.0.0.4:9100"},value:[0,"1795000650"]},
    {metric:{instance:"d:9100"},value:[0,"1790000000"]}]}}' > "$FIX/prom.json"
  run "$BC" record
  assert_equal "$(cause)" house-power-event
  assert_equal "$(last_row | jq -r .hosts_rebooted_with)" 3
}

@test "two other hosts booting with it are not enough" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[
    {metric:{instance:"self:9100"},value:[0,"1795000600"]},
    {metric:{instance:"b:9100"},value:[0,"1795000580"]},
    {metric:{instance:"c:9100"},value:[0,"1795000610"]}]}}' > "$FIX/prom.json"
  run "$BC" record
  assert_equal "$(cause)" silent-death
}

# samples.log line: sample_line <epoch> <ac true|false> <battery pct> [ups status]
# sample_line <epoch> <ac> <battery%> [<ups status>] [<cpu C|null>] [<kernel>] [<load1>]
sample_line() {
  mkdir -p "$BOOT_CAUSE_STATE"
  jq -nc --argjson e "$1" --argjson ac "$2" --argjson p "$3" --arg u "${4-}" --argjson t "${5:-null}" --arg k "${6-}" \
    --argjson l "${7:-1}" \
    '{epoch:$e, ac_online:$ac, battery_pct:$p, ups:(if $u == "" then null else {status:$u} end), cpu_temp_c:$t, load1:$l}
     + (if $k == "" then {} else {kernel:$k} end)' >> "$BOOT_CAUSE_STATE/samples.log"
}

@test "a clean shutdown whose last line is only the power-off target is still clean" {
  journal_end 'Stopped target Basic System.' 'Reached target System Power Off.'
  run "$BC" record
  assert_equal "$(cause)" clean-shutdown
}

@test "the sample the new boot already wrote does not hide the dead boot's last one" {
  journal_end 'app: working'
  sample_line 1795000590 false 3
  sample_line 1795000620 true 90   # this boot's first sample, after boot_epoch 1795000600
  run "$BC" record
  assert_equal "$(cause)" battery-exhausted
}

@test "a sample from long before the log stopped is not evidence" {
  journal_end 'app: working'
  sample_line 1794990000 false 3
  run "$BC" record
  assert_equal "$(cause)" silent-death
  run jq -r '.gaps[]' <<<"$(last_row)"
  assert_output --partial 'no power sample'
}

@test "apcupsd ONBATT and LOWBATT count as on battery, ONLINE does not" {
  journal_end 'app: working'
  sample_line 1795000590 true 100 'ONBATT'
  run "$BC" record
  assert_equal "$(cause)" ups-on-battery
  rm "$BOOT_CAUSE_DIR/testhost.jsonl"; : > "$BOOT_CAUSE_STATE/samples.log"
  sample_line 1795000590 true 100 'ONLINE'
  run "$BC" record
  assert_equal "$(cause)" silent-death
}

@test "an OOM kill in the log does not outrank a last sample on UPS battery" {
  journal_end 'app: working'
  echo 'Out of memory: Killed process 1 (x)' > "$FIX/kern"
  sample_line 1795000590 true 100 'OB DISCHRG'
  run "$BC" record
  assert_equal "$(cause)" ups-on-battery
}

@test "a thermal zone that errors on read does not stop the sample" {
  mkdir -p "$FIX/thermal/thermal_zone1"
  : > "$FIX/thermal/thermal_zone1/temp"   # what a zone that answers EINVAL reads as
  run "$BC" sample
  assert_success
  assert_equal "$(wc -l < "$BOOT_CAUSE_STATE/samples.log")" 1
  assert_equal "$(jq -r .cpu_temp_c "$BOOT_CAUSE_STATE/samples.log")" 51
}

@test "the k10temp hwmon is the CPU temperature, over every thermal zone" {
  mkdir -p "$FIX/hwmon/hwmon0" "$FIX/hwmon/hwmon1"
  echo nvme > "$FIX/hwmon/hwmon0/name"; echo 99000 > "$FIX/hwmon/hwmon0/temp1_input"
  echo k10temp > "$FIX/hwmon/hwmon1/name"; echo 88500 > "$FIX/hwmon/hwmon1/temp1_input"
  run "$BC" sample
  assert_success
  assert_equal "$(jq -r .cpu_temp_c "$BOOT_CAUSE_STATE/samples.log")" 88.5
  assert_equal "$(jq -r .kernel "$BOOT_CAUSE_STATE/samples.log")" "$(uname -r)"
}

@test "a box with no k10temp and no thermal zone reads the CPU as unread, not 0" {
  rm -rf "$FIX/thermal/thermal_zone0"
  run "$BC" sample
  assert_success
  assert_equal "$(jq -r .cpu_temp_c "$BOOT_CAUSE_STATE/samples.log")" null
}

@test "a silent death whose last sample was at the throttle point is thermal-suspect" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  sample_line 1795000590 true 100 '' 96.5
  run "$BC" record
  assert_equal "$(cause)" thermal-suspect
  run jq -r '.evidence[]' <<<"$(last_row)"
  assert_output --partial '96.5 C'
}

@test "a threshold that is not a number stops the record, saying so" {
  journal_end 'app: working'
  run env FLEET_HOT_TCTL=95C "$BC" record
  assert_failure
  assert_output --partial 'FLEET_HOT_TCTL must be a number'
}

@test "with no fresh sample the kernel comes from the dead boot's banner" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  echo 'Linux version 7.3.5-1-cachyos (linux-cachyos@cachyos) #1 SMP' > "$FIX/kern"
  run "$BC" record
  assert_equal "$(last_row | jq -r .previous.kernel)" 7.3.5-1-cachyos
}

@test "a last sample under the throttle point stays a silent death" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  sample_line 1795000590 true 100 '' 80
  run "$BC" record
  assert_equal "$(cause)" silent-death
}

@test "the record names the kernel and how many boots on it ended unclean, and the peak before death" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  mkdir -p "$BOOT_CAUSE_DIR"
  for sd in unclean unclean clean; do
    jq -nc --arg s "$sd" '{boot_id:"old", previous:{shutdown:$s, kernel:"7.3.5-1"}}' >> "$BOOT_CAUSE_DIR/testhost.jsonl"
  done
  jq -nc '{boot_id:"older", previous:{shutdown:"unclean", kernel:"7.3.4-1"}}' >> "$BOOT_CAUSE_DIR/testhost.jsonl"
  sample_line 1795000530 true 100 '' 70 7.3.5-1 39.4
  sample_line 1795000590 true 100 '' 81 7.3.5-1 22
  run "$BC" record
  assert_equal "$(last_row | jq -r .previous.kernel)" 7.3.5-1
  run jq -r '.evidence[]' <<<"$(last_row)"
  assert_output --partial 'kernel 7.3.5-1: 3 of 4 recorded boots on it ended unclean'
  assert_output --partial 'peak over the last 2 samples: load 39.4, CPU 81 C'
}

@test "a device battery and an offline USB port do not make the host look like it is on battery" {
  mkdir -p "$FIX/power/mouse" "$FIX/power/usb0"
  echo Battery > "$FIX/power/mouse/type"; echo 3 > "$FIX/power/mouse/capacity"; echo Device > "$FIX/power/mouse/scope"
  echo USB > "$FIX/power/usb0/type"; echo 0 > "$FIX/power/usb0/online"
  run "$BC" sample
  assert_equal "$(jq -r .battery_pct "$BOOT_CAUSE_STATE/samples.log")" 90
  assert_equal "$(jq -r .ac_online "$BOOT_CAUSE_STATE/samples.log")" true
}

@test "last on a previous-boot-not-in-journal record states no log end it does not have" {
  touch "$FIX/noprev"
  "$BC" record
  run "$BC" last
  assert_success
  refute_output --partial 'previous log stopped'
}

@test "silent death keeps the last log and names what could not be checked" {
  journal_end 'app: working' 'app: the last thing it said'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  run "$BC" record
  assert_success
  assert_equal "$(cause)" silent-death
  assert_equal "$(last_row | jq -r '.last_log[-1]')" 'app: the last thing it said'
  run jq -r '.gaps[]' <<<"$(last_row)"
  assert_output --partial 'no power sample'
  run "$BC" last
  assert_output --partial 'gap: no power sample'
  assert_output --partial 'the last thing it said'
}

@test "with a sample but no UPS the gap says the UPS state is unknown" {
  journal_end 'app: working'
  jq -n '{status:"success",data:{result:[]}}' > "$FIX/prom.json"
  "$BC" sample
  run env BOOT_CAUSE_BOOT_EPOCH=$(( $(date +%s) + 60 )) "$BC" record
  run jq -r '.gaps[]' <<<"$(last_row)"
  assert_output --partial 'no UPS reachable'
  refute_output --partial 'no power sample'
}

@test "an unreachable Prometheus is a named gap, not a skipped check" {
  journal_end 'app: working'
  run "$BC" record
  run jq -r '.gaps[]' <<<"$(last_row)"
  assert_output --partial 'Prometheus did not answer'
  assert_equal "$(last_row | jq -r .hosts_rebooted_with)" null
}

@test "a journal with no previous boot is recorded as that, with the fix named" {
  touch "$FIX/noprev"
  run "$BC" record
  assert_success
  assert_equal "$(cause)" previous-boot-not-in-journal
  run jq -r '.gaps[]' <<<"$(last_row)"
  assert_output --partial 'persistent journal'
}

@test "a second record in the same boot adds nothing" {
  journal_end 'Reached target System Power Off.'
  "$BC" record
  run "$BC" record
  assert_output --partial 'already recorded'
  assert_equal "$(wc -l < "$BOOT_CAUSE_DIR/testhost.jsonl")" 1
}

@test "sample keeps only the last ten samples" {
  for _ in $(seq 13); do "$BC" sample; done
  assert_equal "$(wc -l < "$BOOT_CAUSE_STATE/samples.log")" 10
}

@test "the units and enable links exist" {
  U="$ROOT/.config/systemd/user"
  grep -q 'boot-cause sample' "$U/boot-cause-sample.service"
  grep -q 'boot-cause record' "$U/boot-cause-record.service"
  [ -L "$U/default.target.wants/boot-cause-record.service" ]
  [ -L "$U/timers.target.wants/boot-cause-sample.timer" ]
}
