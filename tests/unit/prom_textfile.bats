#!/usr/bin/env bats
# prom-textfile.sh: how fleet-sessions, fleet-bench and day-log publish to node_exporter's
# textfile collector. A scrape must never read half a file, a failed producer must not
# replace the last good one, and a machine with no collector must not notice.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/prom-textfile.sh"
}

lines() { printf 'm 1\n'; }

@test "no collector directory: nothing is written, nothing is run, and it succeeds" {
  ran() { touch "$SANDBOX/ran"; }
  run prom_textfile x.prom ran
  assert_success
  assert_output ''
  [ ! -e "$PROM_TEXTFILE_DIR" ]
  [ ! -e "$SANDBOX/ran" ]
}

@test "the file is renamed into place, world-readable, with no temp file left" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  run prom_textfile x.prom lines
  assert_success
  assert_equal "$(cat "$PROM_TEXTFILE_DIR/x.prom")" 'm 1'
  [ -n "$(find "$PROM_TEXTFILE_DIR/x.prom" -perm 0644)" ]
  assert_equal "$(ls -A "$PROM_TEXTFILE_DIR")" x.prom
}

@test "a producer that fails leaves the last good file and no temp file" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  prom_textfile x.prom lines
  broken() { printf 'm 2\n'; return 1; }
  run prom_textfile x.prom broken
  assert_failure
  assert_equal "$(cat "$PROM_TEXTFILE_DIR/x.prom")" 'm 1'
  assert_equal "$(ls -A "$PROM_TEXTFILE_DIR")" x.prom
}

@test "gauge: label values are escaped, a null value drops its series, a boolean is 1 or 0" {
  run jq -rn "$PROM_JQ"'gauge("m"; "A help."; ([{a: "x\"y\\z\nw"}, 3], [{a: "gone"}, null], [{a: "b"}, true], [{}, 2.5]))'
  assert_success
  assert_output "$(cat <<'EOF'
# HELP m A help.
# TYPE m gauge
m{a="x\"y\\z\nw"} 3
m{a="b"} 1
m 2.5
EOF
)"
}

@test "the collector dir is the first of PROM_TEXTFILE_DIRS that exists: the workstation's, else a k3s node's" {
  local ws="$SANDBOX/node_exporter/textfile" k3s="$SANDBOX/node-exporter-textfile"
  export PROM_TEXTFILE_DIRS="$ws:$k3s"
  run prom_textfile_default_dir
  assert_output "$ws"
  mkdir -p "$k3s"
  run prom_textfile_default_dir
  assert_output "$k3s"
  mkdir -p "$ws"
  run prom_textfile_default_dir
  assert_output "$ws"
}

@test "target: a given dir is used as is; none given reads PROM_TEXTFILE_DIR, and no collector is status 1 with no output" {
  run prom_textfile_target "$SANDBOX/given"
  assert_success
  assert_output "$SANDBOX/given"
  run prom_textfile_target
  assert_failure
  assert_output ''
  mkdir -p "$PROM_TEXTFILE_DIR"
  run prom_textfile_target
  assert_success
  assert_output "$PROM_TEXTFILE_DIR"
}

@test "the units' ConditionPathIsDirectory lines are PROM_TEXTFILE_DIRS, so a unit skips exactly where the tool would" {
  local unit want have
  unset PROM_TEXTFILE_DIRS
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/prom-textfile.sh"
  want="$(tr ':' '\n' <<< "$PROM_TEXTFILE_DIRS")"
  for unit in fleet-local-gates claude-acct-usage; do
    have="$(sed -n 's/^ConditionPathIsDirectory=|//p' "$REPO_ROOT/.config/systemd/user/$unit.service")"
    assert_equal "$have" "$want"
  done
}

@test "a set PROM_TEXTFILE_DIR wins over the list, and a given dir over both" {
  local ws="$SANDBOX/node_exporter/textfile" k3s="$SANDBOX/node-exporter-textfile"
  mkdir -p "$ws" "$k3s"
  export PROM_TEXTFILE_DIRS="$ws:$k3s" PROM_TEXTFILE_DIR="$k3s"
  run prom_textfile_target
  assert_output "$k3s"
  run prom_textfile_target "$ws"
  assert_output "$ws"
}
