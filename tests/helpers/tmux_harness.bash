# Drive a subject in a real tmux server and assert on the rendered cell grid.
#
# NOT a popup. `tmux display-popup` is untestable: it is a client-side overlay drawn onto
# the client's tty (popup.c is written entirely against `client->tty`), so with no client
# attached it fails with `no current client` rc=1 and never runs the command, and even with
# a pty client attached it never appears in `list-panes` and `capture-pane` cannot read it.
# junegunn hit the same wall in fzf's suite and stubs display-popup out with a PATH shim
# (fzf test/test_tmux.rb). The popup is a one-line binding in .tmux.conf; the script is the
# testable surface, so we run it as an ordinary pane command.
#
# Isolation follows tmux's own regress/Makefile: a private server socket plus `-f /dev/null`,
# because without the latter the developer's ~/.tmux.conf (custom prefix, mouse on, a
# different default-terminal) leaks straight into the subject under test.
#
# ISOLATION IS A FLAG, AND ONLY A FLAG.
# Two env-var approaches look like they isolate a server and do not:
#   * $TMUX_TMPDIR is ignored whenever $TMUX is set -- i.e. whenever you are working inside
#     tmux, which is precisely when you are editing tmux scripts -- and silently falls back
#     to /tmp when the directory does not exist. Verified both ways on 3.7b.
#   * `command tmux` still honours PATH, so it finds a stub instead of bypassing one.
# So every call here goes through ONE mechanism: a PATH shim (tmux_shim) that pins `-S
# <socket-inside-this-test's-sandbox>` onto every invocation. The shim covers the subject
# too -- cockpit.sh runs plain `tmux` internally, as it must, and gets scoped for free.
# And because the flag can still be got wrong, the whole tier additionally refuses to run
# outside the disposable container (require_disposable_host).

TM_SOCKET=""        # absolute socket path, inside $SANDBOX
TM_TARGET=""
TM_LAST_SCREEN=""

# Geometry is pinned. tmux's default is 80x24, and with the default `window-size latest`
# any client that attaches to the server silently resizes the window underneath the test.
TM_WIDTH="${TM_WIDTH:-100}"
TM_HEIGHT="${TM_HEIGHT:-30}"

# tmux_shim -- replace the fake `tmux` stub on PATH with a shim onto the REAL tmux, pinned
# to this test's own socket. Must run after sandbox_init (which creates $SANDBOX/bin and
# resolves $REAL_TMUX before the stub dir shadows it).
#
# Every tmux call in the ui tier -- the harness's own, and any the SUBJECT makes -- resolves
# through here, which is what makes "plain `tmux` inside cockpit.sh" safe to test.
# `-f /dev/null` is pinned here too, so no config can leak in from anywhere.
tmux_shim() {
  : "${SANDBOX:?sandbox_init must run first}"
  : "${REAL_TMUX:?no real tmux found on PATH}"
  TM_SOCKET="$SANDBOX/tmux.sock"
  cat > "$SANDBOX/bin/tmux" <<SHIM
#!/usr/bin/env bash
# Generated per test by tmux_harness.bash. Pins every invocation to one private server.
exec "$REAL_TMUX" -S "$TM_SOCKET" -f /dev/null "\$@"
SHIM
  chmod +x "$SANDBOX/bin/tmux"
}

# tmux_passthrough_shim -- a `tmux` on PATH that is the REAL binary with nothing added.
#
# For servers.sh only. That script's entire purpose is managing SEVERAL servers on several
# sockets, so it calls `tmux -L <name>` itself; pinning `-S` over the top would collapse
# every world onto one socket and make the thing under test untestable.
#
# Isolation therefore comes from $TMUX_TMPDIR (which servers.sh reads directly, for
# SOCKET_DIR) plus the container. That is the mechanism documented elsewhere here as unsafe,
# and it IS unsafe on a real machine - $TMUX overrides it and a missing dir falls back to
# /tmp. Inside the container both holes are closed: sandbox_init unsets TMUX and creates the
# directory, and there is no other tmux server in the image to reach. require_disposable_host
# has already refused to let this run anywhere else.
tmux_passthrough_shim() {
  : "${SANDBOX:?sandbox_init must run first}"
  : "${REAL_TMUX:?no real tmux found on PATH}"
  [ -d "${TMUX_TMPDIR:?}" ] || mkdir -p "$TMUX_TMPDIR"
  [ -z "${TMUX:-}" ] || { echo "refusing: \$TMUX is set" >&2; return 1; }
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_TMUX" > "$SANDBOX/bin/tmux"
  chmod +x "$SANDBOX/bin/tmux"
}

# tmux_kill_named <name...> -- tear down servers created by name under $TMUX_TMPDIR.
# Paired with tmux_passthrough_shim, where there is no single TM_SOCKET to kill.
tmux_kill_named() {
  local n
  for n in "$@"; do
    [ -n "$n" ] || continue
    TMUX_TMPDIR="${TMUX_TMPDIR:?}" "${REAL_TMUX:?}" -L "$n" kill-server 2>/dev/null || true
  done
}

# tmux_start <command...> -- boot an isolated server running the command in window 0
tmux_start() {
  [ -n "$TM_SOCKET" ] || tmux_shim
  _tm new-session -d -x "$TM_WIDTH" -y "$TM_HEIGHT" "$@" </dev/null
  _tm set-option -g window-size manual 2>/dev/null || true
  _tm set-option -g status off 2>/dev/null || true
  TM_TARGET="$(_tm list-panes -F '#{pane_id}' | head -1)"
}

# The shim, called by absolute path. Not `tmux` via PATH: a test that forgot tmux_shim would
# then silently drive the fake stub and every screen would come back empty.
_tm() { "${SANDBOX:?}/bin/tmux" "$@"; }

# tmux_stop -- kill the server and assert it actually died. tmux's own suite treats a
# surviving server as a test failure, and a leaked server poisons the next test.
tmux_stop() {
  # Refuse to kill anything we cannot prove is ours. An empty TM_SOCKET, or one outside this
  # test's sandbox, means the shim was never installed and the call would land on whatever
  # server tmux picks by default. Cheap guard, catastrophic failure mode.
  [ -n "$TM_SOCKET" ] || return 0
  case "$TM_SOCKET" in
    "${SANDBOX:?}"/*) ;;
    *) echo "refusing to kill tmux socket outside the sandbox: $TM_SOCKET" >&2; return 1 ;;
  esac
  _tm kill-server 2>/dev/null || true
  local deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    _tm has-session 2>/dev/null || { TM_SOCKET=""; return 0; }
    sleep 0.05
  done
  echo "tmux server on socket $TM_SOCKET did not exit" >&2
  TM_SOCKET=""
  return 1
}

# screen -- the rendered grid, ANSI stripped.
# Only -p and -J are used. Verified across tmux 3.3a/3.4/3.7b: plain -p and -pJ are stable,
# but -T hard-fails rc=1 on <=3.3a and -N's padding length changed at 3.4. `capture-pane -e`
# byte assertions are avoided entirely -- tmux's own committed expectation file for it
# changed three times across 3.2a..3.7b.
screen() {
  TM_LAST_SCREEN="$(_tm capture-pane -p -J -t "${1:-$TM_TARGET}" 2>/dev/null)"
  printf '%s\n' "$TM_LAST_SCREEN" | strip_ansi
}

screen_has()     { screen | grep -qF -- "$1"; }
screen_lacks()   { ! screen | grep -qF -- "$1"; }
screen_matches() { screen | grep -qE -- "$1"; }

# tmux_keys <key...> -- key names (Enter, Escape, C-a, Up) go through tmux's lookup.
tmux_keys() { _tm send-keys -t "$TM_TARGET" "$@"; }
# tmux_type <string> -- literal text; -l disables key-name lookup, so a literal "q" or
# "Enter" is typed rather than interpreted.
tmux_type() { _tm send-keys -t "$TM_TARGET" -l "$*"; }

# wait_until <shell-expression> -- poll until it succeeds, or fail with the screen attached.
#
# This is the whole anti-flake story, ported from fzf's test/lib/common.rb (10s budget,
# 50ms poll). Demonstrated necessary: a bare capture-pane immediately after starting a pane
# returns nothing, while the identical check passes ~100ms later. The expression is BOTH the
# wait condition and the assertion, so there is no "wait for X, then assert X" gap and no
# bare `sleep` anywhere in the suite.
wait_until() {
  local expr="$1" timeout="${2:-${WAIT_TIMEOUT:-10}}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if eval "$expr"; then return 0; fi
    sleep 0.05
  done
  {
    echo "timed out after ${timeout}s waiting for: $expr"
    dump_screen
  } >&2
  return 1
}

# dump_screen -- fenced screen dump, the way fzf prints one on timeout.
dump_screen() {
  local fence_o fence_c
  fence_o="$(printf '>%.0s' {1..72})"
  fence_c="$(printf '<%.0s' {1..72})"
  echo "$fence_o"
  screen 2>/dev/null || echo "(no screen: server gone)"
  echo "$fence_c"
}

# save_artifacts <name> -- persist the failing screen for CI upload.
save_artifacts() {
  local name="${1:-${BATS_TEST_NAME:-unknown}}"
  local dir="$REPO_ROOT/tests/artifacts"
  mkdir -p "$dir"
  { echo "# $BATS_TEST_DESCRIPTION"; echo "# $(date -Is)"; dump_screen; } \
    > "$dir/${name//[^a-zA-Z0-9_-]/_}.screen" 2>/dev/null || true
}

# Standard UI teardown: on failure keep the evidence, always kill the server.
ui_teardown() {
  if [ "${BATS_TEST_COMPLETED:-0}" != 1 ]; then save_artifacts; fi
  tmux_stop || true
}

# require_disposable_host -- HARD GATE. The ui tier starts real tmux servers and sends real
# keys; on a developer's machine a single mis-scoped call can destroy every live session.
# So this tier runs only where there is nothing to lose: inside tests/Dockerfile's image,
# which has no host tmux server, no $TMUX, and a private /tmp.
#
# This FAILS rather than skips, on purpose. A skip is how a safety tier quietly stops
# running and nobody notices for a month.
#
# Both signals are required. /.dockerenv alone would green-light any container someone
# happens to be in; the env marker alone could be exported by hand on a real host. There is
# deliberately NO override flag -- an escape hatch here is exactly how the accident happened.
require_disposable_host() {
  if [ ! -f /.dockerenv ] || [ -z "${COCKPIT_TEST_DISPOSABLE:-}" ]; then
    {
      echo "REFUSING to run a tmux ui test outside the disposable test container."
      echo "  /.dockerenv present : $([ -f /.dockerenv ] && echo yes || echo no)"
      echo "  COCKPIT_TEST_DISPOSABLE : ${COCKPIT_TEST_DISPOSABLE:-<unset>}"
      echo "  TMUX : ${TMUX:-<unset>}"
      echo
      echo "  Run:  make -C tests test-ui        (builds + runs the container)"
      echo "  Why:  tests/Dockerfile, top comment."
    } >&2
    return 1
  fi
  # Belt and braces: inside the container $TMUX must not be set. If it somehow is, the shim's
  # -S still wins, but a set $TMUX means an assumption is wrong and that is worth stopping on.
  if [ -n "${TMUX:-}" ]; then
    echo "REFUSING: \$TMUX is set inside the test container ($TMUX)." >&2
    return 1
  fi
}

# Preconditions for a UI test. The disposable-host gate FAILS (see above); a missing tool
# only skips, since that is an environment gap rather than a hazard.
require_tmux() {
  require_disposable_host || return 1

  # Drop the fzf STUB, exactly as tmux_shim drops the tmux stub, and for the same
  # reason: sandbox_init copies every stub onto PATH, but this tier drives the REAL
  # cockpit and needs the real binary behind it.
  #
  # The stub exists so the FAST tier cannot hang -- fzf opens /dev/tty and blocks
  # forever on a machine with a terminal -- and it delivers that by exiting 130
  # immediately. Here that is fatal in a way that reads as unrelated: the cockpit
  # aborts before painting, and every test dies at `start_cockpit' failed with
  # nothing on screen to explain why.
  #
  # Removed BEFORE the check below, so "fzf not installed" keeps meaning the real
  # binary is absent rather than being satisfied by the stub we just planted.
  [ -n "${SANDBOX:-}" ] && rm -f "$SANDBOX/bin/fzf"

  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v fzf  >/dev/null 2>&1 || skip "fzf not installed"
}
