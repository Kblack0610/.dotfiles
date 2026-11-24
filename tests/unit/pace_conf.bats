#!/usr/bin/env bats
# pace-conf and lib/pace-conf.sh: a pace.conf key's value in force is a window in force now, else the
# standing override, else the pace.conf line, and `pace-conf` is the one writer of the overrides.
# A window that ends falls back with no timer, so each case runs at a fixed clock (PACE_NOW).

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export PACE_OVERRIDES="$SANDBOX/pace-overrides" PACE_NOW=1800000000 TZ=UTC
  PC="$REPO_ROOT/.local/bin/pace-conf"
  DEFAULT=$(sed -n 's/^BURN_OVER_PCT=//p' "$REPO_ROOT/.config/claude-acct/pace.conf")
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/pace-conf.sh"
}

H=3600

@test "pace_get: a window in force beats the standing override, which beats pace.conf; an ended window falls back by itself" {
  assert_equal "$(pace_get BURN_OVER_PCT)" "$DEFAULT"
  assert_equal "$(pace_source BURN_OVER_PCT)" default
  run "$PC" set BURN_OVER_PCT 100
  assert_success
  assert_equal "$(pace_get BURN_OVER_PCT)" 100
  assert_equal "$(pace_source BURN_OVER_PCT)" override
  run "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW + 2 * H))"
  assert_success
  assert_equal "$(pace_get BURN_OVER_PCT)" 300
  assert_equal "$(pace_source BURN_OVER_PCT)" "window $((PACE_NOW + 2 * H))"
  # a window ahead is not in force yet
  run "$PC" set BURN_OVER_PCT 50 --from "@$((PACE_NOW + 3 * H))" --until "@$((PACE_NOW + 4 * H))"
  assert_success
  assert_equal "$(pace_get BURN_OVER_PCT)" 300
  PACE_NOW=$((PACE_NOW + 3 * H + 1)) && assert_equal "$(pace_get BURN_OVER_PCT)" 50
  # past both windows, with no write and no timer, the standing value is back
  PACE_NOW=$((PACE_NOW + 2 * H)) && assert_equal "$(pace_get BURN_OVER_PCT)" 100
  run "$PC" end BURN_OVER_PCT
  assert_success
  assert_equal "$(pace_get BURN_OVER_PCT)" "$DEFAULT"
  # another key is untouched by any of it
  assert_equal "$(pace_get RESERVE_PCT)" "$(sed -n 's/^RESERVE_PCT=//p' "$REPO_ROOT/.config/claude-acct/pace.conf")"
}

@test "pace-conf set refuses a key with no _MAX line, a value that is not a number or is over the max, and writes nothing" {
  run "$PC" set BURN_OVER_PCT 100
  assert_success
  cp "$PACE_OVERRIDES" "$SANDBOX/before"
  run "$PC" set RESERVE_PCT 5
  assert_failure 1
  assert_output --partial 'RESERVE_PCT is not editable: pace.conf has no RESERVE_PCT_MAX line'
  run "$PC" set NO_SUCH_KEY 5
  assert_failure 1
  assert_output --partial 'NO_SUCH_KEY is not a key in'
  run "$PC" set 'BURN_OVER_PCT=1' 5
  assert_failure 1
  run "$PC" set BURN_OVER_PCT 3e2
  assert_failure 1
  assert_output --partial "'3e2' is not a plain number"
  run "$PC" set BURN_OVER_PCT -5
  assert_failure 1
  run "$PC" set BURN_OVER_PCT 1001
  assert_failure 1
  assert_output --partial 'over BURN_OVER_PCT'"'"'s max of 1000'
  run "$PC" set BURN_OVER_PCT 1000
  assert_success
  # negative control: the refusals left the row as it was; the accepted 1000 replaced it
  run cat "$PACE_OVERRIDES"
  assert_output "BURN_OVER_PCT|1000|$PACE_NOW||hand"
  refute_output --partial '|100|'
  [ "$(cat "$SANDBOX/before")" = "BURN_OVER_PCT|100|$PACE_NOW||hand" ]
}

@test "a window must end in the future, after its start, within PACE_WINDOW_MAX_DAYS, and overlap no other of its key" {
  days=$(sed -n 's/^PACE_WINDOW_MAX_DAYS=//p' "$REPO_ROOT/.config/claude-acct/pace.conf")
  run "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW - 1))"
  assert_failure 1
  assert_output --partial 'is not in the future'
  run "$PC" set BURN_OVER_PCT 300 --from "@$((PACE_NOW + 2 * H))" --until "@$((PACE_NOW + H))"
  assert_failure 1
  assert_output --partial 'is not after the start'
  run "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW + days * 86400 + 1))"
  assert_failure 1
  assert_output --partial "longer than PACE_WINDOW_MAX_DAYS ($days days)"
  run "$PC" set BURN_OVER_PCT 300 --until 'not a time'
  assert_failure 1
  assert_output --partial "cannot read the time 'not a time'"
  run "$PC" set BURN_OVER_PCT 300 --from "@$PACE_NOW"
  assert_failure 1
  assert_output --partial '--from needs --until'
  [ ! -s "$PACE_OVERRIDES" ]
  # the cap itself is taken
  run "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW + days * 86400))"
  assert_success
  # one that overlaps is refused, one that starts where it ends is not
  run "$PC" set BURN_OVER_PCT 50 --from "@$((PACE_NOW + H))" --until "@$((PACE_NOW + 2 * H))"
  assert_failure 1
  assert_output --partial "it overlaps the BURN_OVER_PCT window 300"
  assert_output --partial "pace-conf end BURN_OVER_PCT @$PACE_NOW"
  run "$PC" set BURN_OVER_PCT 50 --from "@$((PACE_NOW + days * 86400))" --until "@$((PACE_NOW + days * 86400 + H))"
  assert_success
  [ "$(grep -c . "$PACE_OVERRIDES")" = 2 ]
}

@test "pace-conf end: a window in force ends now, one ahead is removed, and no FROM ends only the standing one" {
  "$PC" set BURN_OVER_PCT 100
  "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW + H))"
  "$PC" set BURN_OVER_PCT 50 --from "@$((PACE_NOW + 2 * H))" --until "@$((PACE_NOW + 3 * H))"
  run "$PC" end BURN_OVER_PCT "@$PACE_NOW"
  assert_success
  assert_output 'BURN_OVER_PCT: 100 now (override)'
  run "$PC" end BURN_OVER_PCT "@$((PACE_NOW + 2 * H))"
  assert_success
  run cat "$PACE_OVERRIDES"
  assert_output "BURN_OVER_PCT|100|$PACE_NOW||hand"
  # a window that is not there, or has ended, is refused and the file is kept
  run "$PC" end BURN_OVER_PCT "@$((PACE_NOW + 9 * H))"
  assert_failure 1
  assert_output --partial 'has no window that starts at'
  run "$PC" end BURN_OVER_PCT
  assert_success
  assert_output "BURN_OVER_PCT: $DEFAULT now (default)"
  run "$PC" end BURN_OVER_PCT
  assert_failure 1
  assert_output --partial 'BURN_OVER_PCT has no standing override'
  run "$PC" end RESERVE_PCT
  assert_failure 1
  assert_output --partial 'not editable'
}

@test "pace-conf --json lists every pace.conf key with its value, source and default, and the schedule with each row's state" {
  "$PC" set BURN_OVER_PCT 100
  "$PC" set BURN_OVER_PCT 300 --until "@$((PACE_NOW + H))"
  "$PC" set BURN_OVER_PCT 50 --from "@$((PACE_NOW + 2 * H))" --until "@$((PACE_NOW + 3 * H))"
  run --separate-stderr "$PC" --json
  assert_success
  assert_equal "$(jq '.keys | length' <<<"$output")" "$(grep -cE '^[A-Z][A-Z0-9_]*=' "$REPO_ROOT/.config/claude-acct/pace.conf")"
  assert_equal "$(jq -c '.keys[] | select(.key == "BURN_OVER_PCT") | [.value, .source, .until, .default, .editable, .max]' <<<"$output")" \
    "[300,\"window\",$((PACE_NOW + H)),$DEFAULT,true,1000]"
  assert_equal "$(jq -c '.keys[] | select(.key == "RESERVE_PCT") | [.source, .until, .editable, .max]' <<<"$output")" '["default",null,false,null]'
  assert_equal "$(jq -c '[.now, .window_max_days]' <<<"$output")" "[$PACE_NOW,7]"
  assert_equal "$(jq -c '[.schedule[] | [.value, .from, .until, .by, .state]]' <<<"$output")" \
    "[[100,$PACE_NOW,null,\"hand\",\"shadowed\"],[300,$PACE_NOW,$((PACE_NOW + H)),\"hand\",\"in_force\"],[50,$((PACE_NOW + 2 * H)),$((PACE_NOW + 3 * H)),\"hand\",\"upcoming\"]]"
  # the text list says the same: the window and its end, the default beside it
  run "$PC"
  assert_success
  assert_line --regexp '^BURN_OVER_PCT +300 +window to [A-Z][a-z]{2} 15 09:00 +'"$DEFAULT"' +editable, 0 to 1000$'
  assert_line --regexp '^RESERVE_PCT +[0-9]+ +default '
  # each window names the start that end takes, since the minute alone does not match one set from now
  assert_line "  BURN_OVER_PCT 50 from $(date -d "@$((PACE_NOW + 2 * H))" '+%a %d %H:%M') until $(date -d "@$((PACE_NOW + 3 * H))" '+%a %d %H:%M'), by hand; pace-conf end BURN_OVER_PCT @$((PACE_NOW + 2 * H))"
  # past the window the standing row is in force again, and the ended one is out of the schedule
  PACE_NOW=$((PACE_NOW + H)) run --separate-stderr "$PC" --json
  assert_equal "$(jq -c '[.schedule[] | .state]' <<<"$output")" '["in_force","upcoming"]'
}

@test "a malformed row stops pace_get and names the file; pace-conf end drops it, and a set from the hub records agent-web" {
  echo 'BURN_OVER_PCT|lots|0||hand' > "$PACE_OVERRIDES"
  run --separate-stderr pace_get BURN_OVER_PCT
  assert_output ''
  [[ "$stderr" == *"a BURN_OVER_PCT row in $PACE_OVERRIDES is not key|value|from|until|by"* ]] || fail "$stderr"
  run --separate-stderr "$PC" --json
  assert_failure 1
  assert_equal "$(jq -c '.keys[] | select(.key == "BURN_OVER_PCT") | [.value, .source]' <<<"$output")" '[null,"malformed"]'
  # the text list keeps its columns with the value empty
  run "$PC"
  assert_failure 1
  assert_line --regexp '^BURN_OVER_PCT +- +malformed +'"$DEFAULT"' +editable'
  run "$PC" end BURN_OVER_PCT
  assert_success
  assert_output --partial 'dropped a malformed BURN_OVER_PCT row'
  assert_equal "$(pace_get BURN_OVER_PCT)" "$DEFAULT"
  # the hub's runner sets AGENT_AUDITED to its own pid, the tool's parent; one inherited from
  # further up is a hand run
  AGENT_AUDITED=1 "$PC" set BURN_OVER_PCT 100
  run cat "$PACE_OVERRIDES"
  assert_output "BURN_OVER_PCT|100|$PACE_NOW||hand"
  AGENT_AUDITED=$BASHPID "$PC" set BURN_OVER_PCT 200
  run cat "$PACE_OVERRIDES"
  assert_output "BURN_OVER_PCT|200|$PACE_NOW||agent-web"
}

@test "a write prunes ended windows and replaces the file whole, leaving no temp file" {
  printf 'BURN_OVER_PCT|300|%s|%s|hand\n' "$((PACE_NOW - 2 * H))" "$((PACE_NOW - H))" > "$PACE_OVERRIDES"
  assert_equal "$(pace_get BURN_OVER_PCT)" "$DEFAULT"
  "$PC" set BURN_OVER_PCT 100
  run cat "$PACE_OVERRIDES"
  assert_output "BURN_OVER_PCT|100|$PACE_NOW||hand"
  run find "$SANDBOX" -maxdepth 1 -name 'pace-overrides.?*' ! -name 'pace-overrides.lock'
  assert_output ''
}
