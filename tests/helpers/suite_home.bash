# suite_home: every bats run starts with a throwaway HOME, before any test file is read.
#
# tests/{unit,integ,ui}/setup_suite.bash source this, and bats loads that file on its own for any
# run whose first file sits in that tier: through run-bats.sh, the Makefile, CI, or the vendored
# bats called by hand. A test that calls sandbox_init gets its own HOME on top; a test that never
# does (77 files on 2026-11-17) still cannot reach the account's files.
# Why: tests/unit/fleet_node.bats ran before it called sandbox_init and wrote {} over every Claude
# account's .credentials.json and deleted ~/.config/gh/hosts.yml, signing out the fleet
# (2026-11-17; install_modules.bats did the same on 2026-11-06).
#
# The XDG homes follow HOME, since a desktop session exports them pointing at the real ones (gh
# reads XDG_CONFIG_HOME/gh). The account and tool dirs are unset, as on a CI runner.

setup_suite() {
  export HOME="$BATS_SUITE_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
  unset CLAUDE_CONFIG_DIR GH_CONFIG_DIR CODEX_HOME GNUPGHOME
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
}
