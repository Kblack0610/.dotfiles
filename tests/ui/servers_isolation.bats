#!/usr/bin/env bats
# Tier 3: servers.sh (on PATH as `tmx`) against REAL tmux servers.
#
# The first test in this file is the one that matters. servers.sh exists for exactly one
# safety property - "a single `tmux kill-server` takes out every session at once, because
# they share one process... splitting hub / lab into their own sockets makes that blast
# radius exactly one server wide" (servers.sh:11-16). That was a claim in a comment. Here it
# is an assertion.
#
# Isolation note: this file uses tmux_passthrough_shim, NOT the -S shim the other ui tests
# use. servers.sh manages several servers on several sockets and calls `tmux -L <name>`
# itself; pinning -S over the top would collapse every world onto one socket and make the
# subject untestable. Isolation is therefore $TMUX_TMPDIR (which servers.sh reads directly
# for SOCKET_DIR) plus the container - see the helper's comment for why that is sound here
# and nowhere else.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  tmux_passthrough_shim
  # Names that cannot collide with the real hub/lab even if isolation ever regressed.
  SRV_A="batsalpha$$"
  SRV_B="batsbeta$$"
}

teardown() {
  tmux_kill_named "${SRV_A:-}" "${SRV_B:-}"
  return 0
}

# manifest <server> <line...> -- write a .conf for a server
manifest() {
  local srv="$1"; shift
  printf '%s\n' "$@" > "$TMUX_SERVERS_DIR/$srv.conf"
}

sessions_of() { "${REAL_TMUX}" -L "$1" list-sessions -F '#{session_name}' 2>/dev/null; }
server_alive() { "${REAL_TMUX}" -L "$1" has-session 2>/dev/null; }

# ── THE safety property ──────────────────────────────────────────────────────

@test "killing one server leaves the other completely untouched" {
  # This is the entire reason the server layer exists. If it ever regresses, a stray
  # kill-server reaches every session again - which is precisely how this repo's own test
  # suite destroyed live work before it was containerised.
  manifest "$SRV_A" "one $HOME" "two $HOME"
  manifest "$SRV_B" "three $HOME" "four $HOME"
  "$TMX" ensure "$SRV_A"
  "$TMX" ensure "$SRV_B"
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'one two '
  assert_equal "$(sessions_of "$SRV_B" | sort | tr '\n' ' ')" 'four three '

  "${REAL_TMUX}" -L "$SRV_A" kill-server 2>/dev/null || true

  run server_alive "$SRV_A"; assert_failure   # the one we killed is gone
  run server_alive "$SRV_B"; assert_success   # the other is untouched
  assert_equal "$(sessions_of "$SRV_B" | sort | tr '\n' ' ')" 'four three '
}

@test "a session in one server is invisible from the other" {
  # The corollary the cockpit relies on: choose-tree is server-scoped by construction, so
  # Prefix+w in hub can never list lab's sessions.
  manifest "$SRV_A" "alpha-only $HOME"
  manifest "$SRV_B" "beta-only $HOME"
  "$TMX" ensure "$SRV_A"
  "$TMX" ensure "$SRV_B"
  run bash -c "'${REAL_TMUX}' -L '$SRV_A' list-sessions -F '#{session_name}'"
  assert_output --partial 'alpha-only'
  refute_output --partial 'beta-only'
}

# ── ensure: boot path and repair path are the same command ───────────────────

@test "ensure creates every session named in the manifest" {
  manifest "$SRV_A" "daily $HOME" "dotfiles $HOME" "config $HOME"
  run "$TMX" ensure "$SRV_A"
  assert_success
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'config daily dotfiles '
}

@test "ensure is idempotent: a second run creates nothing new" {
  manifest "$SRV_A" "one $HOME" "two $HOME"
  "$TMX" ensure "$SRV_A"
  local first; first="$(sessions_of "$SRV_A" | sort)"
  run "$TMX" ensure "$SRV_A"
  assert_success
  assert_output --partial '0 created'
  assert_equal "$(sessions_of "$SRV_A" | sort)" "$first"
}

@test "ensure rebuilds only the session that went missing" {
  # The repair path. It must never rename, move or kill the survivors.
  manifest "$SRV_A" "one $HOME" "two $HOME" "three $HOME"
  "$TMX" ensure "$SRV_A"
  "${REAL_TMUX}" -L "$SRV_A" kill-session -t '=two'
  refute [ "$(sessions_of "$SRV_A" | grep -cx two)" = 1 ]
  run "$TMX" ensure "$SRV_A"
  assert_output --partial '1 created'
  assert_output --partial '2 already up'
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'one three two '
}

@test "ensure reports counts so the repair path is observable" {
  manifest "$SRV_A" "one $HOME" "two $HOME"
  run "$TMX" ensure "$SRV_A"
  assert_output --partial '2 created'
  assert_output --partial '0 already up'
}

# ── manifest parsing ─────────────────────────────────────────────────────────

@test "a server with no manifest still boots one session named after it" {
  # Not an error: an ad-hoc server should be usable without declaring it first.
  run "$TMX" ensure "$SRV_A"
  assert_success
  assert_output --partial 'no manifest'
  assert_equal "$(sessions_of "$SRV_A")" "$SRV_A"
}

@test "manifest comments and blank lines are skipped, not turned into sessions" {
  manifest "$SRV_A" "# a comment" "" "real $HOME" "# another"
  "$TMX" ensure "$SRV_A"
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'real '
}

@test "a leading ~ in the manifest expands to \$HOME" {
  # Manifests are written with ~, which the shell never expands for us here.
  manifest "$SRV_A" "tilde ~"
  "$TMX" ensure "$SRV_A"
  assert_equal "$(sessions_of "$SRV_A")" 'tilde'
  # `tilde:` and NOT `=tilde` -- the `=` exact-match prefix is valid only for SESSION
  # targets; against a pane target tmux fails with "can't find pane" and returns nothing.
  # servers.sh:131 documents this trap for its own send-keys call, and this test walked
  # straight into it: the empty result read as "~ did not expand" rather than "bad target".
  run bash -c "'${REAL_TMUX}' -L '$SRV_A' display-message -p -t 'tilde:' '#{pane_current_path}'"
  assert_output "$HOME"
}

@test "a missing directory falls back to HOME instead of aborting the world" {
  # One bad line must not cost you every other session in the manifest.
  manifest "$SRV_A" "good $HOME" "bad /no/such/dir/anywhere" "alsogood $HOME"
  "$TMX" ensure "$SRV_A"
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'alsogood bad good '
}

@test "a manifest line with a name but no directory is skipped" {
  manifest "$SRV_A" "nodir" "withdir $HOME"
  "$TMX" ensure "$SRV_A"
  assert_equal "$(sessions_of "$SRV_A" | sort | tr '\n' ' ')" 'withdir '
}

# ── ls ───────────────────────────────────────────────────────────────────────

@test "ls reports a session count for a running server" {
  manifest "$SRV_A" "one $HOME" "two $HOME"
  "$TMX" ensure "$SRV_A"
  run "$TMX" ls
  assert_success
  assert_output --partial "$SRV_A"
  assert_output --partial '2 session(s)'
}

@test "ls always offers the known servers, even when nothing is running" {
  run "$TMX" ls
  assert_success
  assert_output --partial 'hub'
  assert_output --partial 'lab'
  assert_output --partial '(not running)'
}

@test "ls reports a killed server as not running rather than keeping a stale count" {
  # A socket FILE can outlive its server, so ls must probe rather than trust the directory.
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  run "$TMX" ls; assert_output --partial '1 session(s)'
  "${REAL_TMUX}" -L "$SRV_A" kill-server 2>/dev/null || true
  run "$TMX" ls
  refute_output --partial "$SRV_A               1 session(s)"
}

# ── refusals ─────────────────────────────────────────────────────────────────
#
# NOTE: there is deliberately no "unknown verb" test here. In tmx a bare word IS a server
# name (`Verbs: <name> · ensure <name> · ls · ...`), so `tmx not-a-verb` is a valid request
# to hop to a server called not-a-verb - it creates one and calls `exec tmux attach`, which
# blocks forever with no terminal. Asserting a failure there would hang the suite, which is
# exactly what it did when first written.

@test "ensure with no server name refuses instead of guessing one" {
  run "$TMX" ensure
  assert_failure
  assert_output --partial 'needs a server name'
}

@test "ensure never leaves a half-built world when the name is missing" {
  run "$TMX" ensure
  assert_failure
  # No socket should have been created for an empty name.
  refute [ -S "${TMUX_TMPDIR}/tmux-$(id -u)/" ]
}
