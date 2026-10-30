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

@test "runner numbers ride beside the text, since mqtt2prom drops text" {
  printf '1000000' > "$NOTES_FIXTURE/systemctl.show.agentctl@alpha.service.ExecMainStartTimestampMonotonic"
  printf '4500000' > "$NOTES_FIXTURE/systemctl.show.agentctl@alpha.service.ExecMainExitTimestampMonotonic"
  run "$PUB" --dry-run
  assert_success
  p="$(payload agents/testhost/runner/alpha <(printf '%s\n' "$output"))"
  assert_equal "$(jq -c '[.updated_epoch, .duration_s, .outcome_code]' <<< "$p")" '[1789700000,3,0]'
}

@test "outcome_code: 0 ok, 1 warn, 2 fail, null when no outcome is recorded" {
  local w c
  for w in WORKED:0 NOOP:0 BLOCKED:1 PENDING:1 FAILED:2 STALLED:2; do
    printf '%s' "${w%:*}" > "$AGENTCTL_STATE_DIR/alpha/last-outcome"
    c="$(jq -r .outcome_code <<< "$(payload agents/testhost/runner/alpha <("$PUB" --dry-run))")"
    assert_equal "${w%:*} $c" "${w%:*} ${w#*:}"
  done
  rm "$AGENTCTL_STATE_DIR/alpha/last-outcome"
  assert_equal "$(jq -r .outcome_code <<< "$(payload agents/testhost/runner/alpha <("$PUB" --dry-run))")" null
}

@test "duration_s is null while a run is in flight or when the unit never ran" {
  run "$PUB" --dry-run
  assert_equal "$(jq -r .duration_s <<< "$(payload agents/testhost/runner/alpha <(printf '%s\n' "$output"))")" null
  # exit stamp from the previous run, start stamp from the one running now
  printf '9000000' > "$NOTES_FIXTURE/systemctl.show.agentctl@alpha.service.ExecMainStartTimestampMonotonic"
  printf '4500000' > "$NOTES_FIXTURE/systemctl.show.agentctl@alpha.service.ExecMainExitTimestampMonotonic"
  run "$PUB" --dry-run
  assert_equal "$(jq -r .duration_s <<< "$(payload agents/testhost/runner/alpha <(printf '%s\n' "$output"))")" null
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
  assert_equal "$(jq -r .since_epoch <<< "$p")" 1789000000
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

@test "each session carries its bucket from the fleet state document, joined by target" {
  printf 'a:1\t\xe2\x9c\x93\tplatform\tt1\na:2\t~\tplatform\tt2\n' > "$NOTES_FIXTURE/agent-panel.list"
  mkdir -p "$XDG_STATE_HOME/fleet"
  echo '{"schema":1,"generated_at":"2026-10-28T20:00:00Z","sessions":[{"target":"a:1","bucket":"NEEDS"}]}' \
    > "$XDG_STATE_HOME/fleet/state.json"
  run "$PUB" --quiet
  assert_success
  p="$(payload agents/testhost/summary/sessions)"
  assert_equal "$(jq -r '.sessions[0].bucket' <<< "$p")" NEEDS
  # a session the document has not seen yet has no bucket; it is never guessed
  assert_equal "$(jq -r '.sessions[1].bucket' <<< "$p")" null
  assert_equal "$(jq -c .buckets <<< "$p")" '{"NEEDS":1,"unknown":1}'
  assert_equal "$(jq -r .fleet_state_at <<< "$p")" 2026-10-28T20:00:00Z
  assert_equal "$(jq -r .needs <<< "$(payload agents/testhost/sessions/platform)")" 1
}

@test "no fleet state document: sessions still publish, with no bucket" {
  printf 'a:1\t~\tplatform\tt1\n' > "$NOTES_FIXTURE/agent-panel.list"
  run "$PUB" --quiet
  assert_success
  p="$(payload agents/testhost/summary/sessions)"
  assert_equal "$(jq -r .state <<< "$p")" 1
  assert_equal "$(jq -r '.sessions[0].bucket' <<< "$p")" null
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

# ── numeric fields for Prometheus ─────────────────────────────────────────────
# mqtt2prom (kpetremann/mqtt-exporter) keeps only numeric/boolean JSON fields, so the
# text `state` never reaches Prometheus. These booleans are what the Command Center
# dashboard counts; without them "watches tripped" and "runners failed" cannot be drawn.

@test "a watch carries tripped and stale booleans" {
  local now; now="$(date +%s)"
  seed_watch fresh-ok OK '' "$(( now - 60 ))"
  seed_watch dead-ok  OK '' "$(( now - 3600 ))"
  printf '%s' "$(( now - 60 ))" > "$WATCH_STATE_DIR/skill-drift.lastrun"
  run "$PUB" --quiet
  assert_success
  local t f d
  t="$(payload agents/testhost/watch/skill_drift)"
  f="$(payload agents/testhost/watch/fresh_ok)"
  d="$(payload agents/testhost/watch/dead_ok)"
  assert_equal "$(jq -c '[.tripped, .stale]' <<< "$t")" '[true,false]'
  assert_equal "$(jq -c '[.tripped, .stale]' <<< "$f")" '[false,false]'
  assert_equal "$(jq -c '[.tripped, .stale]' <<< "$d")" '[false,true]'
}

@test "a runner whose last run STALLED, or whose state is error, is failed" {
  seed_runner beta
  seed_status beta error dotfiles 'x' 1789700000
  seed_runner gamma
  seed_status gamma idle dotfiles 'x' 1789700000
  printf 'STALLED' > "$AGENTCTL_STATE_DIR/gamma/last-outcome"
  run "$PUB" --quiet
  assert_success
  assert_equal "$(jq -r .failed <<< "$(payload agents/testhost/runner/alpha)")" false
  assert_equal "$(jq -r .failed <<< "$(payload agents/testhost/runner/beta)")" true
  assert_equal "$(jq -r .failed <<< "$(payload agents/testhost/runner/gamma)")" true
  assert_equal "$(jq -r '.running | type' <<< "$(payload agents/testhost/runner/alpha)")" boolean
}
