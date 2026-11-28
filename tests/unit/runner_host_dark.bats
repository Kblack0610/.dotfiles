#!/usr/bin/env bats
# runner-host-dark, the probe of the Sentinel watch runner-host-dark: a self-hosted runner host
# trips only when every registered runner has been offline for the whole window.
# curl is a stub that answers each query from $FIX: a range query from online.tsv, each host's
# online count as "<host> <from-epoch> <count>" steps, read at every 60s step of the asked range;
# gaps lists the epochs the exporter gave no reading; an instant query from reg, "<host> <count>"
# lines. Each query it was asked is appended to $FIX/queries.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RHD="$ROOT/.local/bin/runner-host-dark"
  FIX="$BATS_TEST_TMPDIR/fix"; BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FIX" "$BIN"
  cat > "$BIN/curl" <<'EOF'
#!/bin/bash
[ -e "$FIX/down" ] && exit 7
for a in "$@"; do
  case $a in query=*) q=${a#query=}; printf '%s\n' "$q" >> "$FIX/queries" ;; start=*) s=${a#start=} ;; end=*) e=${a#end=} ;; step=*) st=${a#step=} ;; esac
done
inst() { jq -Rn '{status:"success",data:{resultType:"vector",result:[inputs | select(length > 0) | split(" ") | {metric:{host:.[0]},value:[0,.[1]]}]}}' < "$FIX/$1" 2>/dev/null; }
case ${s:-} in
  ?*)
    awk -v s="$s" -v e="$e" -v st="$st" 'FILENAME == ARGV[1] { gap[$1] = 1; next }
      { h[$1] = 1; n[$1]++; from[$1, n[$1]] = $2; val[$1, n[$1]] = $3 }
      END { for (t = s; t <= e; t += st) { if (t in gap) continue
              for (x in h) { v = ""; for (i = 1; i <= n[x]; i++) if (from[x, i] <= t) v = val[x, i]
                             if (v != "") print x, t, v } } }' "$FIX/gaps" "$FIX/online.tsv" \
      | jq -Rn '{status:"success",data:{resultType:"matrix",result:([inputs | split(" ")] | group_by(.[0])
          | map({metric:{host:.[0][0]},values:(map([(.[1] | tonumber), .[2]]) | sort_by(.[0]))}))}}' ;;
  *) inst reg ;;
esac
EOF
  chmod +x "$BIN/curl"
  export FIX PATH="$BIN:$PATH" HOME="$BATS_TEST_TMPDIR"
  : > "$FIX/gaps"
  printf 'mac-mini 2\nms-a2 3\n' > "$FIX/reg"
  # Now, for every case: the window is END-600 .. END.
  END=1795000000
}

# online <host> <from-offset-seconds> <count> ...: steps of that host's online count, offsets from END.
online() {
  local h=$1; shift
  while [ $# -gt 0 ]; do printf '%s %s %s\n' "$h" $((END + $1)) "$2" >> "$FIX/online.tsv"; shift 2; done
}

@test "every runner offline for the whole 10 minutes trips and names the host" {
  online mac-mini -3600 2 -700 0
  online ms-a2 -3600 3
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_line 'dark: mac-mini all 2 runners offline for 10m or more'
  assert_line 'ok: ms-a2 3 of 3 online'
  assert_line 'reason: mac-mini (2 runners) offline for 10m or more'
}

@test "one runner online keeps the host OK (negative control for the trip above)" {
  online mac-mini -3600 2 -700 1
  online ms-a2 -3600 3
  run "$RHD" --for 10m --at "$END"
  assert_success
  assert_line 'ok: mac-mini 1 of 2 online'
  refute_output --partial 'reason:'
}

@test "offline for 9 minutes stays OK; the trip comes at 10" {
  online mac-mini -3600 2 -540 0
  online ms-a2 -3600 3
  run "$RHD" --for 10m --at "$END"
  assert_success
  assert_line 'ok: mac-mini all 2 offline, for under 10m'
  run "$RHD" --for 10m --at $((END + 60))
  assert_failure 1
  assert_line --partial 'dark: mac-mini'
}

@test "a host with no registered runner is not judged, and the ARC scale sets' hosts are never read" {
  online mac-mini -3600 0
  online ms-a2 -3600 3
  echo 'ms-a2 3' > "$FIX/reg"
  run "$RHD" --for 10m --at "$END"
  assert_success
  refute_output --partial mac-mini
  local q
  while IFS= read -r q; do
    [[ $q == *'host!~"unknown|arc|arc-.+"'* ]] || fail "a query that reads the ARC hosts: $q"
  done < "$FIX/queries"
}

@test "no registered runner host at all says so and passes" {
  online ms-a2 -3600 3
  : > "$FIX/reg"
  run "$RHD" --for 10m --at "$END"
  assert_success
  assert_output 'ok: no self-hosted runner host is registered'
}

@test "a registered host with no online row counts as zero online once the exporter answers" {
  # The online query adds a 0 row for every registered host, so a host has no row only on a scrape
  # that dropped it; read as nothing online, never as a skip.
  online ms-a2 -3600 3
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_line 'dark: mac-mini all 2 runners offline for 10m or more'
}

@test "exporter gaps never count as offline: readings must cover the window's start" {
  online mac-mini -3600 2 -3000 0
  online ms-a2 -3600 3
  local t; for t in -600 -540 -480; do echo $((END + t)) >> "$FIX/gaps"; done
  run "$RHD" --for 10m --at "$END"
  assert_success
  assert_line 'ok: mac-mini all 2 offline, but the exporter readings start inside the window'
}

@test "a gap inside the window still trips a host that read zero on both sides of it" {
  online mac-mini -3600 2 -3000 0
  online ms-a2 -3600 3
  echo $((END - 300)) >> "$FIX/gaps"
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_line --partial 'dark: mac-mini'
}

@test "no exporter reading now is unreadable, never a dark host" {
  online mac-mini -3600 0
  online ms-a2 -3600 0
  local t; for t in -60 0; do echo $((END + t)) >> "$FIX/gaps"; done
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_output 'unreadable: the runner exporter gave no runner state (github_runner_state) now'
}

@test "Prometheus down is unreadable" {
  touch "$FIX/down"
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_output --partial 'unreadable: Prometheus did not answer'
}

@test "replay: a 45-minute outage like the mac-mini's on 2026-11-12 trips 10 minutes in and clears once one is back" {
  # Both runners offline from END-2700 to END; no page went out for any of it.
  online mac-mini -7200 2 -2700 0 0 2
  online ms-a2 -7200 3
  local at want
  for at in -2160 -2100 -60 60; do
    case $at in -2160|60) want=0 ;; *) want=1 ;; esac
    run "$RHD" --for 10m --at $((END + at))
    assert_equal "$status" "$want"
  done
}

@test "the window comes from --for, and a malformed one is refused" {
  online mac-mini -3600 2 -400 0
  online ms-a2 -3600 3
  run "$RHD" --for 5m --at "$END"
  assert_failure 1
  assert_line 'reason: mac-mini (2 runners) offline for 5m or more'
  run "$RHD" --for 10min
  assert_failure 2
}

@test "a reading the judging cannot parse is unreadable, never a quiet OK" {
  online mac-mini -3600 0
  online ms-a2 -3600 3
  echo 'mac-mini two' > "$FIX/reg"
  run "$RHD" --for 10m --at "$END"
  assert_failure 1
  assert_line 'unreadable: runner-host-dark could not judge the readings Prometheus gave'
}

@test "an option missing its value, or -h, prints the usage and exits 2" {
  run timeout 5 "$RHD" --for
  assert_failure 2
  assert_output --partial 'runner-host-dark [--for 10m]'
  run timeout 5 "$RHD" --at
  assert_failure 2
  run "$RHD" -h
  assert_failure 2
  assert_output 'runner-host-dark [--for 10m] [--at <epoch|date>]'
}
