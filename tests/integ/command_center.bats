#!/usr/bin/env bats
# command-center.sh lays out the cc:* recording rules and judges nothing itself. These pin
# the two things that make it trustworthy: it shows exactly what Prometheus says, and when
# Prometheus cannot be read it shows NOTHING rather than the last (possibly green) frame.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CC="$REPO_ROOT/.local/src/tmux/command-center.sh"
  export NO_COLOR=1 COLUMNS=140 LINES=40 CC_PROM_URL=http://prom.test
  # curl stub: answers the cc:* query from $CC_FIXTURE, the red-items query with one item,
  # and fails outright when CURL_FAIL is set.
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
case "$*" in
  *'cc:.+'*) cat "$CC_FIXTURE" ;;
  *) printf '{"status":"success","data":{"result":[{"metric":{"item":"watch mac_studio_mlx"},"value":[0,"1"]}]}}' ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  export CC_FIXTURE="$BATS_TEST_TMPDIR/cc.json"
  python3 - "$CC_FIXTURE" <<'PY'
import json, sys
rows = [("cc:overall_status", None, "2"), ("cc:domain_status", "k3s", "0"), ("cc:domain_status", "llm", "2"),
        ("cc:domain_status", "spend", "1"), ("cc:k3s_nodes_ready", None, "8"), ("cc:k3s_nodes_total", None, "8"),
        ("cc:lazer_spend_usd", None, "4.06"), ("cc:lazer_budget_usd", None, "250"), ("cc:asks_open", None, "0"),
        ("cc:sessions_attention", None, "0")]
res = [{"metric": dict({"__name__": n}, **({"domain": d} if d else {})), "value": [0, v]} for n, d, v in rows]
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

tile_status() { # tile_status <title> -> the badge word under that tile's title
  awk -v t="$1" '
    { n = split($0, cells, /\| /) }
    index($0, t) { for (i = 1; i <= n; i++) if (index(cells[i], t)) col = i; grab = 1; next }
    grab { split($0, c2, /\| /); s = c2[col]; gsub(/[| ]+/, " ", s); print s; exit }' <<< "$output"
}

@test "each tile shows the status its cc:domain_status series says" {
  run "$CC" --once
  assert_success
  assert_equal "$(tile_status 'CLUSTER home-k3s' | xargs)" 'OK'
  assert_equal "$(tile_status 'LLM' | xargs)" 'RED'
  assert_equal "$(tile_status 'SPEND' | xargs)" 'WARN'
  assert_equal "$(tile_status 'OVERALL' | xargs)" 'RED'
}

@test "numbers come straight from the cc:* series" {
  run "$CC" --once
  assert_output --partial 'nodes 8/8 ready'
  assert_output --partial 'lazer $4.06 of $250.00'
  assert_output --partial 'red now: watch mac_studio_mlx'
}

@test "a domain with no series reads NO DATA, never OK" {
  run "$CC" --once
  assert_equal "$(tile_status 'MACHINES' | xargs)" 'NO DATA'
}

@test "Prometheus unreachable: the board says so and shows no tile at all" {
  CURL_FAIL=1 run "$CC" --once
  assert_failure
  assert_output --partial 'QUERY FAILED'
  refute_output --partial 'OK'
  refute_output --partial 'CLUSTER'
}

@test "rules not loaded (no cc:* series) is a failure, not an empty green board" {
  printf '{"status":"success","data":{"result":[]}}' > "$CC_FIXTURE"
  run "$CC" --once
  assert_failure
  assert_output --partial 'recording rules not loaded'
}

@test "a terminal too short for the grid gets one line per domain, every domain still shown" {
  LINES=12 run "$CC" --once
  assert_success
  refute_output --partial '+----'
  assert_output --regexp 'RED +LLM'
  assert_output --regexp 'OK +CLUSTER home-k3s +nodes 8/8 ready'
  assert_output --regexp 'NO DATA +MACHINES'
}

@test "every tile row is the same width, whatever the badge says" {
  run "$CC" --once
  local widths
  widths="$(grep -E '^[|+]' <<< "$output" | awk '{ print length($0) }' | sort -u | wc -l)"
  assert_equal "$widths" 1
}
