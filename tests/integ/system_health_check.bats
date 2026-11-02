#!/usr/bin/env bats
# system-health-check names the failed units, so the briefing line says what to restart.
#
# It used to print "5 user service(s) failed". fleet-state.path and agent-mqtt-sessions.path
# sat failed from 2026-10-28 behind that count, which named nothing. systemctl is a stub here:
# a test never fails a real unit.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/src/system/system-health-check.sh"
  OUT="$XDG_CACHE_HOME/system-health"
  # No network: ping answers with no loss.
  printf '#!/usr/bin/env bash\necho "5 packets transmitted, 5 received, 0%% packet loss"\n' > "$SANDBOX/bin/ping"
  # `systemctl [--user] --failed --no-legend --plain`, served from one fixture per scope.
  cat > "$SANDBOX/bin/systemctl" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --user "*) f="$SANDBOX/failed.user" ;;
  *) f="$SANDBOX/failed.system" ;;
esac
[ -f "\$f" ] && cat "\$f"
exit 0
SH
  chmod +x "$SANDBOX/bin/ping" "$SANDBOX/bin/systemctl"
}

report() { cat "$OUT"/system-health-*.md; }

@test "each failed user unit is named in Issues Detected, with what to do" {
  printf '%s\n' \
    'fleet-state.path          loaded failed failed Refresh the fleet state document' \
    'agent-mqtt-sessions.path  loaded failed failed Push fleet state changes' > "$SANDBOX/failed.user"
  run "$SUBJECT"
  assert_success
  run report
  assert_output --partial '- user units failed: fleet-state.path, agent-mqtt-sessions.path -> do: systemctl --user status <unit>'
  assert_output --partial '| Failed Services | 2 user / 0 system |'
  refute_output --partial 'system units failed'
}

@test "no failed unit: no unit line, and the count is zero" {
  run "$SUBJECT"
  assert_success
  run report
  assert_output --partial '| Failed Services | 0 user / 0 system |'
  refute_output --partial 'units failed'
}

@test "a failed system unit is named on its own line" {
  echo 'nfs-mount.service loaded failed failed NAS' > "$SANDBOX/failed.system"
  run "$SUBJECT"
  assert_success
  run report
  assert_output --partial '- system units failed: nfs-mount.service'
  refute_output --partial 'user units failed'
}
