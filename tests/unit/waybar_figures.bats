#!/usr/bin/env bats
# One home per figure (docs/dashboards.md rules 2 and 8): the waybar chips and agent-mqtt-publish
# lay out hub-core's figures and count none themselves (tests/agent-web/chips.test.mjs, which
# scans .config/waybar/*.sh: ai_agents.sh ci_runners.sh fleet_pulse.sh health.sh load.sh
# machines.sh needs.sh pin-hint.sh projects.sh queue.sh webcam.sh and the rest, plus
# agent-mqtt-publish). The hub-core half, every card figure on every surface from one fixture, is
# hub-core's phone::tests::every_card_figure_reads_the_same_on_every_surface. Skips where node is absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v node >/dev/null 2>&1 || skip "node not installed"
}

@test "waybar chips and agent-mqtt-publish count no fleet figure beyond the allowlist" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/chips.test.mjs"
  assert_success
}
