#!/usr/bin/env bats
# The cockpit's AGENTS view: _project_agents, _version_start, canon_namespaces.
#
# The view answers "who is working this project, and what did the finished ones
# cost for the version we are building". It used to render pending asks and the
# sprint blackboard as well - read from the SAME sources as the bridge view, so a
# project whose only state was one pending ask rendered identical bytes in both.
# The anti-duplication tests below are the regression guard for that.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  export PROM_URL='http://127.0.0.1:1' PROM_TIMEOUT=1
  ln -sf "$REPO_ROOT/.local/bin/agent-usage" "$SANDBOX/bin/agent-usage"

  # Stub `sessions rows` so the view is asserted against fixed live rows rather
  # than whatever Claude sessions happen to be running on the machine.
  cat > "$SANDBOX/bin/sessions" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "rows" ] || exit 0
case "\${2:-}" in
  demo) printf 'live0001\tbusy\tdemo\tfeat/x\t%s\twriting the thing\tinteractive\n' "\$(( \$(date +%s) - 600 ))"
        printf 'live0002\twaiting\tdemo\tmain\t%s\tneeds a decision\tinteractive\n' "\$(( \$(date +%s) - 120 ))"
        printf 'live0004\tidle\tdemo\tmain\t%s\t-\theadless\n' "\$(( \$(date +%s) - 60 ))" ;;
  alias-repo) printf 'live0003\tidle\talias-repo\tmain\t%s\tsecond canonical\tinteractive\n' "\$(( \$(date +%s) - 60 ))" ;;
esac
EOF
  chmod +x "$SANDBOX/bin/sessions"

  mkdir -p "$HOME/.agent/sessions/demo"
  cat > "$HOME/.agent/sessions/demo/sessions.jsonl" <<'EOF'
{"session_id":"fin00001","project":"demo","edits":9,"title":"shipped in this version","updated":5000,"cost_usd":3.25,"tokens":{"total":1500000},"models":["m1"],"duration_s":60}
{"session_id":"fin00002","project":"demo","edits":4,"title":"PREVIOUS VERSION WORK","updated":100,"cost_usd":9.99,"tokens":{"total":500},"models":["m1"],"duration_s":10}
EOF

  PROJ="$HOME/vault/demo"
  mkdir -p "$PROJ/versions"
  printf '# demo\n\nVersion: v0.0.2\n' > "$PROJ/README.md"
  printf '# demo\n\nVersion: v0.0.1\n<!-- rolled: 1000 -->\n' > "$PROJ/versions/v0.0.1.md"
  export PROJ

  source "$COCKPIT"
  C_DIM=''; C_OFF=''; C_PROJ=''; C_INP=''; C_SEL=''; C_BOX=''; C_HEAD=''
}

# $3 of _project_agents is the project name; the full set of ~/.agent namespaces its
# state can live in is derived from the registry by canon_namespaces. Tests that care
# about the two-namespace case override that lookup rather than smuggling a list through
# the argument - passing "a, b" there is exactly the bug the split fixed, because every
# other consumer (agent-ask, sprint items, checkpoints) uses the name verbatim.
render() { _project_agents personal demo "${1:-demo}" "$PROJ/README.md" "${2:-}" "${3:-}"; }


# ── the version boundary ─────────────────────────────────────────────────────

@test "_version_start reads the rolled marker off the newest frozen note" {
  assert_equal "$(_version_start "$PROJ/README.md")" '1000'
}

@test "_version_start prefers the marker over the file mtime" {
  # Regenerating an old release's summary rewrites the note; if mtime decided the
  # boundary, that would silently drag the window forward by months.
  touch -d '2030-01-01' "$PROJ/versions/v0.0.1.md"
  assert_equal "$(_version_start "$PROJ/README.md")" '1000'
}

@test "_version_start falls back to mtime when there is no marker" {
  sed -i '/rolled:/d' "$PROJ/versions/v0.0.1.md"
  touch -d '2001-02-03 04:05:06' "$PROJ/versions/v0.0.1.md"
  assert_equal "$(_version_start "$PROJ/README.md")" "$(stat -c %Y "$PROJ/versions/v0.0.1.md")"
}

@test "_version_start yields 0 when nothing has been released" {
  assert_equal "$(_version_start '')" '0'
  assert_equal "$(_version_start "$HOME/vault/nope/README.md")" '0'
}

# ── no duplication of the bridge ─────────────────────────────────────────────

@test "the agents view emits no ask rows - the bridge owns questions" {
  run render
  refute_output --partial $'ask\t'
}

@test "the agents view emits no sprint row - the bridge owns work items" {
  run render
  refute_output --partial $'sprint\t'
}

# ── live sessions ────────────────────────────────────────────────────────────

@test "live sessions render with status, branch and what they are doing" {
  run render
  assert_output --partial 'writing the thing'
  assert_output --partial '~ busy'
  assert_output --partial 'feat/x'
}

@test "a session waiting on the human is marked distinctly" {
  run render
  assert_output --partial '! waiting'
  assert_output --partial 'needs a decision'
}

@test "live rows carry no cost - a running session's usage is incomplete" {
  local line; line="$(render | grep 'writing the thing')"
  refute [ -n "$(printf '%s' "$line" | grep '\$')" ]
}

# ── finished sessions, scoped to the current version ─────────────────────────

@test "finished sessions from this version are shown with their telemetry" {
  run render
  assert_output --partial 'shipped in this version'
  assert_output --partial '$3.25'
  assert_output --partial '1.5M tok'
}

@test "finished sessions from a previous version are excluded" {
  run render
  refute_output --partial 'PREVIOUS VERSION WORK'
}

@test "the footer totals only this version's sessions" {
  run render
  assert_output --partial '1 session - 9 edits'
}

# ── the wire format ──────────────────────────────────────────────────────────

@test "every row emits exactly 7 tab-separated fields" {
  # fzf slices rows with --delimiter=$'\t' --with-nth='7..'; a moved field breaks
  # the UI at runtime with no error.
  local bad; bad="$(render | awk -F'\t' 'NF != 7 {print NF": "$0}')"
  assert_equal "$bad" ''
}

@test "every row type is one _enter_action can dispatch" {
  local t
  for t in $(render | cut -f1 | sort -u); do
    case "$t" in sess|head|hint|runner|wave) ;; *) fail "unknown row type '$t'" ;; esac
  done
}

# ── the namespaces a project's state can live in ─────────────────────────────
#
# This used to be a `<!-- canonical: a, b -->` marker inside each summary.md, parsed by
# canonical_of / canonicals_of / _canon_list. The marker did not point into the runtime
# namespace, it MINTED names nothing else had heard of. The relation it actually carried
# -- "a session registers under the REPO it ran in" -- is `trackers.<project>.repo` in
# project-map.json, which already existed and is already validated.

mk_map() { MAPF="$BATS_TEST_TMPDIR/map.json"; cat > "$MAPF"; export PROJECT_MAP_FILE="$MAPF"; }

@test "canon_namespaces returns the project, then the repo it belongs to" {
  mk_map <<'J'
{ "trackers": { "notes-cockpit": { "repo": "dotfiles" } } }
J
  assert_equal "$(canon_namespaces notes-cockpit | tr '\n' ' ')" 'notes-cockpit dotfiles '
}

@test "a project with no repo relation yields only itself" {
  mk_map <<'J'
{ "trackers": { "gsuite-comms": { "repo": null } } }
J
  assert_equal "$(canon_namespaces gsuite-comms)" 'gsuite-comms'
}

@test "an unregistered project still yields itself, never nothing" {
  # The cockpit passes this straight on as a project name. Returning empty would render
  # the row as idle for a project that is being actively worked.
  mk_map <<'J'
{ "trackers": {} }
J
  assert_equal "$(canon_namespaces whatever)" 'whatever'
}

@test "a repo equal to the project name is not emitted twice" {
  mk_map <<'J'
{ "trackers": { "dotfiles": { "repo": "dotfiles" } } }
J
  assert_equal "$(canon_namespaces dotfiles)" 'dotfiles'
}

@test "canon_namespaces survives a missing or unreadable registry" {
  # This file is PUBLIC and the registry is PRIVATE, so a public-only checkout has no
  # map at all. Degrading to "just the project name" is correct; failing is not.
  export PROJECT_MAP_FILE="$BATS_TEST_TMPDIR/nope.json"
  run canon_namespaces demo
  assert_success
  assert_output 'demo'
}

@test "a project whose state lives under the repo gathers from both" {
  mk_map <<'J'
{ "trackers": { "demo": { "repo": "alias-repo" } } }
J
  run render demo
  assert_output --partial 'writing the thing'
  assert_output --partial 'second canonical'
}

# ── the headless runner ──────────────────────────────────────────────────────

@test "a delivery-loop runner on THIS project is shown" {
  canon_namespaces() { printf 'demo\n'; }
  run render demo demo 'draining the queue'
  assert_output --partial 'draining the queue'
}

@test "a delivery-loop runner on another project is not" {
  canon_namespaces() { printf 'demo\n'; }
  run render demo other 'draining the queue'
  refute_output --partial 'draining the queue'
}

# ── a wave you started, before it has filed anything ─────────────────────────
#
# A scope-out runs for minutes before it writes a board, posts an ask or touches a
# ticket. With no row for that window, pressing W looked like nothing happened - which
# is what made the same wave get started three times.

wave_lock() { # <app> <pid>
  mkdir -p "$HOME/.local/state/agentctl/wave"
  printf '%s\n' "$2" > "$HOME/.local/state/agentctl/wave/$1.pid"
}

teardown() { [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null; return 0; }

@test "a headless run is not rendered as an idle session" {
  run render
  assert_output --partial '~ headless'
  # the giveaway of the old behaviour: a dim `o idle` with no other signal
  refute_output --regexp 'o idle.*\(just started\)'
}

@test "a live wave lock puts a scoping row on the project" {
  sleep 60 & HOLDER=$!
  wave_lock demo "$HOLDER"
  run render
  assert_output --partial '~ wave'
  assert_output --partial 'nothing filed yet'
}

@test "the scoping row disappears once the wave is gone" {
  sleep 0 & local dead=$!; wait "$dead" 2>/dev/null || true
  wave_lock demo "$dead"
  run render
  refute_output --partial '~ wave'
}

@test "a junk lock file does not fake a running wave" {
  wave_lock demo 'not-a-pid'
  run render
  refute_output --partial '~ wave'
}

@test "the wave row keeps the 7-field wire format" {
  sleep 60 & HOLDER=$!
  wave_lock demo "$HOLDER"
  local bad; bad="$(render | awk -F'\t' 'NF != 7 {print NF": "$0}')"
  assert_equal "$bad" ''
}
