#!/usr/bin/env bats
# The cockpit's AGENTS view: _project_agents, _version_start, _canon_list.
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
  demo) printf 'live0001\tbusy\tdemo\tfeat/x\t%s\twriting the thing\n' "\$(( \$(date +%s) - 600 ))"
        printf 'live0002\twaiting\tdemo\tmain\t%s\tneeds a decision\n' "\$(( \$(date +%s) - 120 ))" ;;
  alias-repo) printf 'live0003\tidle\talias-repo\tmain\t%s\tsecond canonical\n' "\$(( \$(date +%s) - 60 ))" ;;
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
    case "$t" in sess|head|hint|runner) ;; *) fail "unknown row type '$t'" ;; esac
  done
}

# ── several runtime names per vault project ──────────────────────────────────

@test "_canon_list splits and trims a multi-name marker" {
  assert_equal "$(_canon_list 'a, b')" "$(printf 'a\nb')"
  assert_equal "$(_canon_list 'solo')" 'solo'
}

@test "a project claiming two canonical names gathers from both" {
  run render 'demo, alias-repo'
  assert_output --partial 'writing the thing'
  assert_output --partial 'second canonical'
}

# ── the headless runner ──────────────────────────────────────────────────────

@test "a delivery-loop runner on THIS project is shown" {
  run render demo demo 'draining the queue'
  assert_output --partial 'draining the queue'
}

@test "a delivery-loop runner on another project is not" {
  run render demo other 'draining the queue'
  refute_output --partial 'draining the queue'
}
