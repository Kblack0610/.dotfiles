#!/usr/bin/env bats
# agent-mqtt-publish: the agent fleet mirrored into Home Assistant over MQTT discovery.
#
# The broker is a stub that appends `topic<TAB>payload` per call, so these pin what HA
# would receive. Three properties carry the file:
#   DIFF     a repeat run with nothing changed sends nothing; a change sends only that topic.
#   DELETE   a runner whose conf goes away gets an empty retained discovery message,
#            or HA keeps a ghost sensor forever.
#   INERT    with no broker configured it is a silent no-op, because agentctl calls it
#            from every status write on every machine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PUB="$REPO_ROOT/.local/bin/agent-mqtt-publish"
  PUBLOG="$NOTES_FIXTURE/mqtt.log"
  : > "$PUBLOG"
  cat > "$SANDBOX/bin/mosquitto_pub" <<'EOF'
#!/usr/bin/env bash
t="" m=""
while [ $# -gt 0 ]; do
  case "$1" in -t) t="$2"; shift 2 ;; -m) m="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${MQTT_STUB_FAIL:-}" ] && exit 1
printf '%s\t%s\n' "$t" "$m" >> "$NOTES_FIXTURE/mqtt.log"
EOF
  chmod +x "$SANDBOX/bin/mosquitto_pub"

  export AGENT_MQTT_HOST=stub AGENT_MQTT_HOST_ID=testhost TZ=UTC

  seed_runner alpha
  seed_status alpha working bnb-platform 'sprint resume' 1789700000
  printf 'WORKED' > "$AGENTCTL_STATE_DIR/alpha/last-outcome"
  seed_watch skill-drift TRIP
  printf '1789000000' > "$WATCH_STATE_DIR/skill-drift.since"
}

payload() { awk -F'\t' -v t="$1" '$1 == t { sub(/^[^\t]*\t/, ""); print }' "${2:-$PUBLOG}" | tail -1; }

@test "unconfigured: no broker host means no output and no broker call" {
  unset AGENT_MQTT_HOST
  run "$PUB"
  assert_success
  assert_output ''
  [ ! -s "$PUBLOG" ]
}

@test "runner state and attributes land on its state topic" {
  run "$PUB" --quiet
  assert_success
  p="$(payload agents/testhost/runner/alpha)"
  assert_equal "$(jq -r .state <<< "$p")" working
  assert_equal "$(jq -r .project <<< "$p")" bnb-platform
  assert_equal "$(jq -r .item <<< "$p")" 'sprint resume'
  assert_equal "$(jq -r .last_outcome <<< "$p")" WORKED
  assert_equal "$(jq -r .updated <<< "$p")" '2026-09-18T02:53:20+00:00'
}

@test "discovery config names a stable entity and points at the state topic" {
  run "$PUB" --quiet
  c="$(payload homeassistant/sensor/agent_testhost_runner_alpha/config)"
  assert_equal "$(jq -r .default_entity_id <<< "$c")" sensor.agent_alpha
  assert_equal "$(jq -r .unique_id <<< "$c")" agent_testhost_runner_alpha
  assert_equal "$(jq -r .state_topic <<< "$c")" agents/testhost/runner/alpha
  assert_equal "$(jq -r .expire_after <<< "$c")" 900
}

@test "a tripped watch is published with its since timestamp" {
  run "$PUB" --quiet
  p="$(payload agents/testhost/watch/skill_drift)"
  assert_equal "$(jq -r .state <<< "$p")" TRIP
  assert_equal "$(jq -r .since <<< "$p")" '2026-09-10T00:26:40+00:00'
  c="$(payload homeassistant/sensor/agent_testhost_watch_skill_drift/config)"
  assert_equal "$(jq -r .default_entity_id <<< "$c")" sensor.agent_watch_skill_drift
}

@test "live sessions are counted by agent-panel glyph" {
  printf 'a:1\t~\tp1\tt1\nb:1\t!\tp2\tt2\nc:1\t✓\tp3\tt3\n' > "$NOTES_FIXTURE/agent-panel.list"
  run "$PUB" --quiet
  p="$(payload agents/testhost/summary/sessions)"
  assert_equal "$(jq -r .state <<< "$p")" 3
  assert_equal "$(jq -r .working <<< "$p")" 1
  assert_equal "$(jq -r .attention <<< "$p")" 1
}

@test "sessions are grouped per project like the waybar module, most urgent status wins" {
  printf 'a:1\t~\tplatform\tt1\na:2\t!\tplatform\tt2\nb:1\t\xe2\x9c\x93\tdotfiles\tt3\n' > "$NOTES_FIXTURE/agent-panel.list"
  run "$PUB" --quiet
  assert_success
  p="$(payload agents/testhost/sessions/platform)"
  assert_equal "$(jq -r .state <<< "$p")" attention
  assert_equal "$(jq -r .glyphs <<< "$p")" '~!'
  assert_equal "$(jq -r .count <<< "$p")" 2
  assert_equal "$(jq -r .state <<< "$(payload agents/testhost/sessions/dotfiles)")" idle
  c="$(payload homeassistant/sensor/agent_testhost_sessions_platform/config)"
  assert_equal "$(jq -r .default_entity_id <<< "$c")" sensor.agent_sessions_platform
}

@test "a project whose last session closed is deleted from HA" {
  printf 'a:1\t~\tplatform\tt1\nb:1\t~\tdotfiles\tt3\n' > "$NOTES_FIXTURE/agent-panel.list"
  "$PUB" --quiet
  : > "$PUBLOG"
  printf 'b:1\t~\tdotfiles\tt3\n' > "$NOTES_FIXTURE/agent-panel.list"
  run "$PUB" --quiet
  assert_success
  grep -qxF "homeassistant/sensor/agent_testhost_sessions_platform/config"$'\t' "$PUBLOG"
  run grep -qxF "homeassistant/sensor/agent_testhost_sessions_dotfiles/config"$'\t' "$PUBLOG"
  assert_failure
}

@test "diff: a second run with nothing changed sends nothing" {
  "$PUB" --quiet
  [ -s "$PUBLOG" ]
  : > "$PUBLOG"
  run "$PUB" --quiet
  assert_success
  [ ! -s "$PUBLOG" ]
}

@test "diff: a status change sends exactly that runner's state topic" {
  "$PUB" --quiet
  : > "$PUBLOG"
  seed_status alpha error bnb-platform 'boom' 1789700100
  run "$PUB" --quiet
  assert_success
  assert_equal "$(wc -l < "$PUBLOG")" 1
  assert_equal "$(jq -r .state <<< "$(payload agents/testhost/runner/alpha)")" error
}

@test "diff: a changed discovery config also resends that entity's state" {
  "$PUB" --quiet
  : > "$PUBLOG"
  # Simulate a config change by corrupting the cached copy of alpha's discovery payload.
  printf 'stale' > "$HOME/.local/state/agent-mqtt/sent/homeassistant%sensor%agent_testhost_runner_alpha%config"
  run "$PUB" --quiet
  assert_success
  assert_equal "$(wc -l < "$PUBLOG")" 2
  [ -n "$(payload agents/testhost/runner/alpha)" ]
}

@test "full: republishes everything even when unchanged (feeds expire_after)" {
  "$PUB" --quiet
  n="$(wc -l < "$PUBLOG")"
  : > "$PUBLOG"
  run "$PUB" --full --quiet
  assert_success
  assert_equal "$(wc -l < "$PUBLOG")" "$n"
}

@test "delete: a runner whose conf is removed gets empty retained config and state" {
  "$PUB" --quiet
  : > "$PUBLOG"
  rm "$AGENTCTL_CONF_DIR/alpha.conf"
  run "$PUB" --quiet
  assert_success
  grep -qxF "homeassistant/sensor/agent_testhost_runner_alpha/config"$'\t' "$PUBLOG"
  grep -qxF "agents/testhost/runner/alpha"$'\t' "$PUBLOG"
}

@test "negative control: a runner that still exists is NOT deleted" {
  "$PUB" --quiet
  : > "$PUBLOG"
  seed_runner beta
  run "$PUB" --quiet
  assert_success
  run grep -qxF "homeassistant/sensor/agent_testhost_runner_alpha/config"$'\t' "$PUBLOG"
  assert_failure
}

@test "broker down: fails fast, and the next run retries what was not sent" {
  MQTT_STUB_FAIL=1 run "$PUB" --quiet
  assert_failure
  [ ! -s "$PUBLOG" ]
  run "$PUB" --quiet
  assert_success
  [ -n "$(payload agents/testhost/runner/alpha)" ]
}

@test "dry-run prints the snapshot and never calls the broker" {
  run "$PUB" --dry-run
  assert_success
  assert_output --partial $'agents/testhost/runner/alpha\t'
  [ ! -s "$PUBLOG" ]
}
