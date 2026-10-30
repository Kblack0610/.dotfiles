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
