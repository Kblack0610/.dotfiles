#!/usr/bin/env bats
# load.sh: the waybar load chip. The bar is this machine's load from /proc/loadavg; the
# hover is every machine from the cc:host_* rules. What these pin: a missing value is -,
# never 0 (Macs and Pis have no temp series); a hot OTHER machine shows on the bar without
# hovering; and a dead Prometheus keeps the local number but never shows stale rows.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/load.sh"
  export CC_PROM_URL=http://prom.test CC_SELF=workstation LOAD_CORES=24
  export FX="$BATS_TEST_TMPDIR"
  export LOAD_LOADAVG="$FX/loadavg"
  echo "12.00 10.00 9.00 3/900 1234" > "$LOAD_LOADAVG"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/hosts.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  hosts workstation:23.3:24:0.57:0.58:85 razer-laptop:13.1:16:0.48:0.27:58 \
    mac-mini:1.6:8:0.16:0.43: pi-a:0.1:4:0.02:0.2: pi-b:0.05:4:0.01:0.1:
}

# hosts name:load1:cores:cpu:mem:temp ... (an empty field means no series at all)
hosts() {
  python3 - "$FX/hosts.json" "$@" <<'PY'
import json, sys
res = []
for spec in sys.argv[2:]:
    h, *vals = spec.split(":")
    for k, v in zip(["load1", "cores", "cpu_busy_ratio", "mem_used_ratio", "temp_c"], vals):
        if v:
            res.append({"metric": {"__name__": f"cc:host_{k}", "host": h}, "value": [0, v]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

tip() { jq -r .tooltip <<< "$output"; }

@test "the bar is this machine's load, coloured by load per core" {
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "LOAD <span color='#a6e34a'>12.0</span>"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "past 1.5 per core the local load is red and the class critical" {
  echo "40.00 10.00 9.00 3/900 1234" > "$LOAD_LOADAVG"
  run "$MODULE"
  assert_output --partial "#ef5734'>40.0<"
  assert_equal "$(jq -r .class <<< "$output")" critical
}

@test "rows run worst load per core first, and a missing temp reads -, never 0" {
  run "$MODULE"
  run tip
  assert_line --index 2 --regexp '^workstation '
  assert_line --index 3 --regexp '^razer-laptop '
  assert_line --index 4 --regexp '^mac-mini .*16% +43% +-$'
  refute_output --partial "0C"
}

@test "near-idle machines fold into one idle line, sorted" {
  run "$MODULE"
  run tip
  assert_output --partial "idle: pi-a, pi-b"
  refute_line --regexp '^pi-a '
}

@test "a hot OTHER machine adds a gold ! to the bar and paints its temp red" {
  hosts workstation:23.3:24:0.57:0.58:85 asus-laptop:6:16:0.4:0.3:94
  run "$MODULE"
  assert_output --partial "<span color='#ffcc2f'>!</span>"
  run tip
  assert_output --partial "<span color='#ef5734'>  94C</span>"
}

# Negative control for the above: this machine has its own temperature chips, so its heat
# alone must not raise the !, or the ! would be on whenever the workstation works hard.
@test "...but this machine running hot does not" {
  hosts workstation:23.3:24:0.57:0.58:96 razer-laptop:13.1:16:0.48:0.27:58
  run "$MODULE"
  refute_output --partial "'>!<"
}

@test "an overloaded other machine counts as hot too" {
  hosts workstation:3:24:0.1:0.5:60 hp-victus:40:24:0.99:0.6:70
  run "$MODULE"
  assert_output --partial "<span color='#ffcc2f'>!</span>"
}

@test "Prometheus down: the local load stays, the tooltip says so, no machine rows" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "LOAD <span color='#a6e34a'>12.0</span>"
  run tip
  assert_output --partial "fleet telemetry unavailable (http://prom.test)"
  refute_output --partial "razer-laptop"
}

@test "no cc:host_* series says the rules are missing instead of an empty table" {
  hosts
  run "$MODULE"
  run tip
  assert_output --partial "no cc:host_* series"
}
