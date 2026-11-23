# shellcheck shell=bash
# cpu-temp.sh - the one CPU temperature reader, sourced by fleet-assess and boot-cause.
#
# read_tctl -> Tctl from the k10temp hwmon (AMD), else the hottest thermal zone, else "-", in C to one
# decimal. An AMD desktop has no thermal zones, only hwmon: a zone-only reader saw 0 C on every
# boot-cause sample while the box died four times under load (2026-11-19 to 11-23).
# Roots, for tests: CPU_TEMP_HWMON (default /sys/class/hwmon), CPU_TEMP_THERMAL (default /sys/class/thermal).
# FLEET_HOT_TCTL is the throttle point (C), the one threshold fleet-assess holds at and boot-cause calls
# thermal-suspect at: this Zen part boosts until Tctl reads 95, so low 90s under load are by design.
: "${FLEET_HOT_TCTL:=95}"
read_tctl() {
  local h z v max=''
  for h in "${CPU_TEMP_HWMON:-/sys/class/hwmon}"/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] || continue
    v=$(cat "$h/temp1_input" 2>/dev/null)
    [[ $v =~ ^[0-9]+$ ]] || continue
    awk -v v="$v" 'BEGIN { printf "%.1f\n", v / 1000 }'
    return
  done
  for z in "${CPU_TEMP_THERMAL:-/sys/class/thermal}"/thermal_zone*/temp; do
    # A zone that answers a read with EINVAL reads as empty, and some ACPI zones report a negative
    # sentinel: both are skipped, not fatal.
    v=$(cat "$z" 2>/dev/null)
    [[ $v =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] || continue
    if [ -z "$max" ] || [ "$v" -gt "$max" ]; then max=$v; fi
  done
  if [ -n "$max" ] && [ "$max" != 0 ]; then awk -v v="$max" 'BEGIN { printf "%.1f\n", v / 1000 }'; else echo -; fi
}
