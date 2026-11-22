#!/usr/bin/env bats
# One home per figure (docs/dashboards.md rules 2 and 8): the waybar chips, the tmux scripts, the
# figure CLIs (day-log fleet-bench fleet-shepherd agent-ask) and agent-mqtt-publish lay out
# hub-core's figures and count none themselves (tests/agent-web/chips.test.mjs over its allowlist
# tests/agent-web/figure-sites.json, which scans .config/waybar/*.sh, .local/src/tmux/*.sh and
# those CLIs). The hub-core half, every card figure on every surface from one fixture, is
# hub-core's phone::tests::every_card_figure_reads_the_same_on_every_surface. Skips where node is absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v node >/dev/null 2>&1 || skip "node not installed"
}

@test "waybar chips, tmux scripts, figure CLIs and agent-mqtt-publish count no fleet figure beyond the allowlist" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/chips.test.mjs"
  assert_success
}
