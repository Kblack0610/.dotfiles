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

# ── rows / preview: the cross-server view (prefix A) ─────────────────────────
#
# `rows` is the data behind `pick-all`, split out from the fzf call precisely so it can be
# asserted without a terminal. Field layout is <server> <session> <window> <display>, and
# the window field is what distinguishes a session header row from a window row.

@test "rows reaches ACROSS servers - the one thing choose-tree and sesh cannot do" {
  # The whole point of the view. prefix w is server-scoped by construction and sesh follows
  # $TMUX into one server, so a list containing BOTH worlds is the only new capability here.
  manifest "$SRV_A" "alpha-only $HOME"
  manifest "$SRV_B" "beta-only $HOME"
  "$TMX" ensure "$SRV_A"
  "$TMX" ensure "$SRV_B"
  run "$TMX" rows
  assert_success
  assert_output --partial 'alpha-only'
  assert_output --partial 'beta-only'
}

@test "rows emits a session header with an empty window field, and a row per window" {
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  "${REAL_TMUX}" -L "$SRV_A" new-window -t 'one:' 2>/dev/null

  # Header: third field empty. Window rows: third field is the index.
  run bash -c "'$TMX' rows | awk -F'\t' '\$2==\"one\" && \$3==\"\"' | wc -l"
  assert_output '1'
  run bash -c "'$TMX' rows | awk -F'\t' '\$2==\"one\" && \$3!=\"\"' | wc -l"
  assert_output '2'
}

@test "a window row carries what is actually running in it" {
  # The reason per-window rows are worth having: the row has to say something useful about
  # the window, not just repeat its number.
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  run bash -c "'$TMX' rows | awk -F'\t' '\$3!=\"\" {print \$4}'"
  assert_success
  assert_output --regexp '(bash|sh|zsh)'
}

@test "a session row explains itself: where it is and what is running in it" {
  # There is no preview pane, so the row IS the explanation. If it stops carrying the
  # path and the running command, the list goes back to being a wall of bare names.
  # Created directly rather than through the manifest: the manifest is whitespace
  # delimited, and this sandbox's $HOME deliberately contains a space, so a path under
  # it cannot be expressed there. Real manifests name space-free paths.
  mkdir -p "$HOME/where-i-am"
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  "${REAL_TMUX}" -L "$SRV_A" new-session -d -s explained -c "$HOME/where-i-am"

  run bash -c "'$TMX' rows | awk -F'\t' '\$2==\"explained\" && \$3==\"\" {print \$4}'"
  assert_success
  assert_output --partial '~/where-i-am'       # where, with $HOME collapsed to ~
  assert_output --regexp '(bash|sh|zsh)'       # what is running
}

@test "rows offers the server itself, so one list also replaces the server picker" {
  # A server row is the only row with BOTH the session and window fields empty; that is
  # what tells pick-all to hop the whole world rather than land on a session.
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  run bash -c "'$TMX' rows | awk -F'\t' '\$1==\"$SRV_A\" && \$2==\"\" && \$3==\"\"' | wc -l"
  assert_output '1'
}

@test "both views exist: ls feeds the compact picker, rows feeds the full one" {
  # They answer different questions - "which world" vs "where is that window" - so
  # neither may quietly absorb the other. `pick` was deleted once as superseded and
  # had to come back; this is the assertion that stops that happening silently.
  manifest "$SRV_A" "one $HOME" "two $HOME"
  "$TMX" ensure "$SRV_A"

  run "$TMX" ls                       # the compact view's data: one row per SERVER
  assert_success
  assert_output --partial "$SRV_A"
  refute_output --partial 'one'       # sessions are the preview, not the list

  run "$TMX" rows                     # the full view's data: sessions AND windows
  assert_success
  assert_output --partial 'one'
  assert_output --partial 'two'
}

# ── land with an explicit target ─────────────────────────────────────────────
#
# `land` ends in `exec tmux attach`, which cannot succeed without a terminal - so these
# assert the side effect that happens BEFORE the attach. That is the whole of the new code
# path: resolve the picked row to a session, and select the picked window on the way in.

@test "land <session>:<window> selects that window before attaching" {
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  "${REAL_TMUX}" -L "$SRV_A" new-window -t 'one:' 2>/dev/null

  # Read the real indices back: base-index differs between configs.
  local first last
  first="$("${REAL_TMUX}" -L "$SRV_A" list-windows -t '=one' -F '#{window_index}' | head -1)"
  last="$("${REAL_TMUX}" -L "$SRV_A" list-windows -t '=one' -F '#{window_index}' | tail -1)"
  [ "$first" != "$last" ]                       # the fixture must actually have two
  "${REAL_TMUX}" -L "$SRV_A" select-window -t "one:$first" 2>/dev/null

  run "$TMX" land "$SRV_A" "one:$last"   # attach fails (no tty); select-window already ran
  run bash -c "'${REAL_TMUX}' -L '$SRV_A' display-message -p -t one '#{window_index}'"
  assert_output "$last"
}

@test "land falls back to resume when the picked session died since it was listed" {
  # A picker row is a snapshot. Landing on a session that has gone must not error out.
  manifest "$SRV_A" "one $HOME"
  "$TMX" ensure "$SRV_A"
  run "$TMX" land "$SRV_A" 'vanished-session'
  refute_output --partial 'no server running'
  run server_alive "$SRV_A"; assert_success
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
