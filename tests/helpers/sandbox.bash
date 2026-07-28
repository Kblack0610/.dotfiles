# Sandbox: every test runs against a throwaway $HOME with stub binaries on PATH.
#
# The subjects under test are already env-injectable, which is why this is short:
#   notes-cockpit.sh  STATE/MODEF/PFILTER are $TMPDIR-rooted (:32,:37,:66)
#                     NOTES_COCKPIT_ALIASES (:43), NOTES_COCKPIT_REPOS (:47)
#   agent-ask         ASK_ROOT under $HOME/.agent/asks
# So redirecting HOME + TMPDIR relocates all persistent state for free.
#
# The sandbox path deliberately contains a space (asdf's test suite does the same) so
# any unquoted expansion in the subject fails loudly here instead of on someone's laptop.

# tests/{unit,integ,ui}/x.bats -> repo root is two levels up from the test dir.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
export REPO_ROOT TESTS_DIR

COCKPIT="$REPO_ROOT/.local/src/tmux/notes-cockpit.sh"
FLEET="$REPO_ROOT/.local/src/tmux/fleet.sh"
COCKPIT_SESSION_SH="$REPO_ROOT/.local/src/tmux/cockpit.sh"
STATUS_SH="$REPO_ROOT/.local/src/tmux/claude-status.sh"
AGENT_ASK="$REPO_ROOT/.local/bin/agent-ask"
ASK_RESUME="$REPO_ROOT/.local/bin/ask-resume"
# NOTE: agent-bridge.sh was folded into notes-cockpit's bridge view (459519ad) and deleted;
# its former $BRIDGE export is gone with it. fleet.sh is the headless-side surface now.
# The REAL agentctl, by path. `agentctl` on PATH is a stub (fleet.sh's mutation verbs are
# asserted through it), so a test of agentctl's own contract must not go through PATH.
AGENTCTL_BIN="$REPO_ROOT/.local/bin/agentctl"
# The shared board parser. Exported so a subject can find it even though sandbox_init
# rewrites $HOME, which is where the deployed copy would otherwise live.
AGENT_BOARD_LIB="$REPO_ROOT/.local/lib/agent-board.sh"
export COCKPIT FLEET COCKPIT_SESSION_SH STATUS_SH AGENT_ASK ASK_RESUME AGENTCTL_BIN AGENT_BOARD_LIB

# sandbox_init [fixture-name]
# Builds $SANDBOX with an isolated HOME/TMPDIR, puts stubs first on PATH, and seeds
# fixture data by copy (never by running the real tool).
sandbox_init() {
  local fixture="${1:-basic}"

  SANDBOX="${BATS_TEST_TMPDIR}/sb space"   # the space is intentional
  mkdir -p "$SANDBOX"/{home,tmp,bin,fixture}

  export HOME="$SANDBOX/home"
  export TMPDIR="$SANDBOX/tmp"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_CACHE_HOME="$HOME/.cache"
  export XDG_DATA_HOME="$HOME/.local/share"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$HOME/.agent/asks"

  # Resolve the real binaries BEFORE the stub dir goes on PATH. The UI tier must drive a
  # genuine tmux server; `command tmux` is not enough, since `command` bypasses functions
  # and aliases but still honours PATH and would find the stub.
  REAL_TMUX="${REAL_TMUX:-$(command -v tmux || true)}"
  REAL_FZF="${REAL_FZF:-$(command -v fzf || true)}"
  export REAL_TMUX REAL_FZF

  # Detach from any inherited tmux session. A test must never be able to address the server
  # its own runner happens to be sitting in.
  #
  # TMUX_TMPDIR is set as a third line of defence ONLY, and is explicitly NOT trusted:
  # tmux ignores it whenever $TMUX is set, and falls back to /tmp if the directory is
  # missing. Real isolation is the `-S` flag the ui tier's shim pins onto every call
  # (tmux_harness.bash), on a host that has no sessions to lose (tests/Dockerfile).
  unset TMUX TMUX_PANE
  export TMUX_TMPDIR="$SANDBOX/tmp"

  # Stub dir wins over anything real.
  export PATH="$SANDBOX/bin:$PATH"
  cp "$TESTS_DIR/helpers/stubs/"* "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/"*

  # The REPO's own bins, on PATH. Not stubs -- the real scripts, which is the point: the
  # cockpit shells out to `agent-ask` by name, and its whole state lives under $HOME
  # (`ASKS_ROOT="$HOME/.agent/asks"`), which is already sandboxed. There is nothing to fake.
  #
# This existed as a FALSE PASS for as long as no test needed it. A developer's own
  # `~/.local/bin` is on PATH, so `agent-ask` resolved on a laptop and resolved NOWHERE on
  # a clean runner -- the bridge's question rows simply vanished in CI while every local
  # run stayed green. cockpit_bridge.bats opens with a guard against that coming back.
  #
  # COPIED, never symlinked. A symlink here points back into the working tree, and a test
  # that overrides one of these with `cat > "$SANDBOX/bin/<x>"` (wave_start.bats does,
  # legitimately) writes straight THROUGH the link and truncates the real script in the
  # repo. That is a test suite silently editing its own subject.
  local b
  for b in agent-ask ask-resume; do
    [ -f "$REPO_ROOT/.local/bin/$b" ] || continue
    cp "$REPO_ROOT/.local/bin/$b" "$SANDBOX/bin/$b"
    chmod +x "$SANDBOX/bin/$b"
  done

  # Fixture data the `notes` stub reads. Seeded by copy, never by running the real tool.
  export NOTES_FIXTURE="$SANDBOX/fixture"
  if [ -d "$TESTS_DIR/fixtures/$fixture" ]; then
    cp -r "$TESTS_DIR/fixtures/$fixture/." "$NOTES_FIXTURE/"
  fi
  : > "$NOTES_FIXTURE/calls.log"   # stub CLIs append every invocation here

  # Cockpit machine-local config: point at the sandbox, empty by default.
  export NOTES_COCKPIT_ALIASES="$NOTES_FIXTURE/aliases"
  export NOTES_COCKPIT_REPOS="$NOTES_FIXTURE/repos"
  [ -f "$NOTES_COCKPIT_ALIASES" ] || : > "$NOTES_COCKPIT_ALIASES"
  [ -f "$NOTES_COCKPIT_REPOS" ] || : > "$NOTES_COCKPIT_REPOS"

  # fleet.sh's four data roots. They already default under $HOME, so the HOME redirect
  # above relocates them for free; they are exported explicitly anyway so a test can point
  # one at an empty dir to exercise the "nothing here" branch without touching the others.
  export AGENTCTL_CONF_DIR="$HOME/.config/agentctl/agents"
  export AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export WATCH_DIR="$HOME/.agent/watches"
  export WATCH_STATE_DIR="$HOME/.local/state/watch-companion"
  mkdir -p "$AGENTCTL_CONF_DIR" "$AGENTCTL_STATE_DIR" "$WATCH_DIR" "$WATCH_STATE_DIR"

  # Deterministic terminal env. fzf's own suite pins glyphs the same way so that
  # assertions never depend on upstream default cosmetics.
  export TERM=xterm-256color
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
  # Quoted empties, not bare `PS1=` -- shellcheck reads the latter as a botched assignment
  # (SC1007) and it is genuinely ambiguous to a reader.
  export PS1='' PROMPT_COMMAND='' HISTFILE=''
  unset "${!FZF_@}" 2>/dev/null || true
  export FZF_DEFAULT_OPTS="--no-scrollbar --pointer='>' --marker='>'"

  # Tell the subjects they are under test, so paths that exec/become or spawn a
  # nested fzf can no-op instead of hijacking the terminal.
  export NOTES_COCKPIT_TEST=1
}

# seed_runner <name> [activity-line]
# A runner exists because its .conf exists — that is the whole roster contract fleet.sh
# enforces, so seeding one is exactly "drop a conf in".
seed_runner() {
  local name="$1" activity="${2:-}"
  printf 'NAME=%s\nKIND=oneshot\nCOMMAND=/bin/true\n' "$name" > "$AGENTCTL_CONF_DIR/$name.conf"
  if [ -n "$activity" ]; then
    mkdir -p "$AGENTCTL_STATE_DIR/$name"
    printf '[2026-07-24T12:00:00-07:00] %s\n' "$activity" >> "$AGENTCTL_STATE_DIR/$name/activity.log"
  fi
}

# seed_status <name> <state> [project] [item] [updated-epoch]
# The runner status contract (agentctl `report`): key=value at <state>/<name>/status.
# Written here by hand rather than by shelling out to `agentctl report` on purpose -- a
# reader test must pin the FILE FORMAT, so it still fails if the writer stops honouring it.
seed_status() {
  local name="$1" state="$2" project="${3:-}" item="${4:-}" updated="${5:-}"
  mkdir -p "$AGENTCTL_STATE_DIR/$name"
  { printf 'state=%s\n' "$state"
    printf 'project=%s\n' "$project"
    printf 'item=%s\n' "$item"
    printf 'detail=\n'
    printf 'updated=%s\n' "${updated:-$(date +%s)}"
  } > "$AGENTCTL_STATE_DIR/$name/status"
}

# seed_watch <name> <state> [description] [lastrun-epoch]
seed_watch() {
  local name="$1" state="$2" desc="${3:-}" lastrun="${4:-}"
  { printf 'name: %s\n' "$name"
    [ -n "$desc" ] && printf 'description: %s\n' "$desc"
    printf 'probe: http\ninterval: 5m\n'
  } > "$WATCH_DIR/$name.yaml"
  printf '%s' "$state" > "$WATCH_STATE_DIR/$name.state"
  [ -n "$lastrun" ] && printf '%s' "$lastrun" > "$WATCH_STATE_DIR/$name.lastrun"
  return 0
}

# seed_watch_folded <name> <state> — a watch whose description is a YAML folded block.
# Several real manifests use `>-`; a naive one-line grep renders the literal ">-".
seed_watch_folded() {
  local name="$1" state="$2"
  cat > "$WATCH_DIR/$name.yaml" <<EOF
name: $name
description: >-
  first line of the folded description
  second line that must be joined
probe: http
interval: 5m
EOF
  printf '%s' "$state" > "$WATCH_STATE_DIR/$name.state"
}

# fleet_field <type> <field-no> — the given field of every row of a type, ANSI stripped.
fleet_field() {
  "$FLEET" --list 2>/dev/null | awk -F'\t' -v t="$1" -v n="$2" '$1==t { print $n }' | strip_ansi
}

# The log of stub CLI invocations, one shell-quoted command per line.
calls() { cat "$NOTES_FIXTURE/calls.log" 2>/dev/null; }

# assert_called <substring> -- a stub CLI was invoked with a matching command line
assert_called() {
  if ! grep -qF -- "$1" "$NOTES_FIXTURE/calls.log" 2>/dev/null; then
    {
      echo "expected a stub call matching: $1"
      echo "-- actual calls --"
      cat "$NOTES_FIXTURE/calls.log" 2>/dev/null
      echo "-----------------"
    } >&2
    return 1
  fi
}

# assert_not_called <substring>
assert_not_called() {
  if grep -qF -- "$1" "$NOTES_FIXTURE/calls.log" 2>/dev/null; then
    echo "unexpected stub call matching: $1" >&2
    return 1
  fi
}

# Strip SGR sequences before comparing. The cockpit colours rows inline
# (C_BOX/C_HEAD/C_PROJ/... at notes-cockpit.sh:54-60), so raw comparison is unstable.
# Mirrors bats-core's own filter_control_sequences.
strip_ansi() { sed -E $'s,\x1b\\[[0-9;]*[a-zA-Z],,g'; }

# NOTE: deliberately no `field()` helper here -- agent-ask defines its own field(), and a
# sourced subject must never have its functions shadowed by the harness.
