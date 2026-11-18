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
# reads XDG_CONFIG_HOME/gh). The account and tool dirs, tokens and live-state pointers an agent
# session exports are unset, as on a CI runner.
#
# ACCOUNT_HOME: the HOME the run started with, READ-ONLY, for the tests that pin the live overlay
# docs and catalogs (pipelines_doc, rules_register, departments_catalog, ...). A test never writes
# under it; where it lacks the overlay (CI), those tests skip as before.

setup_suite() {
  export ACCOUNT_HOME="$HOME"
  export HOME="$BATS_SUITE_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
  unset CLAUDE_CONFIG_DIR GH_CONFIG_DIR CODEX_HOME GNUPGHOME \
    GH_TOKEN GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN \
    AGENT_QUEUE_ITEM AGENTCTL_STATE AGENTCTL_STATE_DIR AGENT_STATE_HOST FLEET_HOSTS_JSON
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
}
