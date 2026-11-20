#!/usr/bin/env bats
# fleet-agent, the one launcher of the fleet-agent image: what `up` hands docker (the port sshd
# answers on, the volumes that hold every login, only the authorized_keys file, a cpuset so nproc
# inside is honest), that it reuses a container only when nothing it was started with changed, that
# `down` never removes a volume, and that the CI smoke still finds probe_hosts' readiness probe in
# fleet-dispatch, so a reworded probe fails here and not only in the image job.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  FLEET_AGENT="$REPO_ROOT/.local/bin/fleet-agent"
  export DOCKER_LOG="$SANDBOX/docker.log"
  export FLEET_AGENT_KEYS="$SANDBOX/authorized_keys"
  echo 'ssh-ed25519 AAAA test' >"$FLEET_AGENT_KEYS"
  # docker: log each call. `inspect` answers with $DOCKER_SPEC as the container's spec label, and
  # fails when it is unset (no container yet); `image inspect` prints one fixed image id.
  cat >"$SANDBOX/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >>"$DOCKER_LOG"
case "$1 $2" in
  "inspect "*) [ -n "${DOCKER_SPEC:-}" ] || exit 1; echo "$DOCKER_SPEC" ;;
  "image inspect") echo sha256:img ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/docker"
  printf '#!/bin/sh\necho 8\n' >"$SANDBOX/bin/nproc" && chmod +x "$SANDBOX/bin/nproc"
  export FLEET_AGENT_MEM=4g
}

@test "up starts the image behind sshd with the home and host-key volumes, the keys file and a cpuset" {
  run "$FLEET_AGENT" up
  assert_success
  assert_output --partial 'started ghcr.io/kblack0610/fleet-agent:latest on port 2223 (6 cores, 4g)'
  run grep '^run ' "$DOCKER_LOG"
  assert_output --partial '-p 2223:22'
  assert_output --partial '--restart unless-stopped'
  assert_output --partial '--cpuset-cpus 0-5'
  assert_output --partial '-v fleet-agent-home:/home/kblack0610'
  assert_output --partial '-v fleet-agent-hostkeys:/etc/ssh/keys'
  assert_output --partial "-v $FLEET_AGENT_KEYS:/etc/fleet-agent/authorized_keys:ro"
  assert_output --partial "--label fleet-agent.spec=sha256:img 2223 6 4g $FLEET_AGENT_KEYS"
  refute_output --partial '/.ssh:'
}

@test "up reuses a container started from the same image with the same settings" {
  DOCKER_SPEC="sha256:img 2223 6 4g $FLEET_AGENT_KEYS" run "$FLEET_AGENT" up
  assert_success
  assert_output --partial 'fleet-agent: up ('
  run cat "$DOCKER_LOG"
  assert_output --partial 'start fleet-agent'
  refute_output --partial 'run -d'
}

@test "up replaces a container whose settings changed, and says its sessions end" {
  DOCKER_SPEC="sha256:img 2223 6 4g $FLEET_AGENT_KEYS" FLEET_AGENT_PORT=2224 run "$FLEET_AGENT" up
  assert_success
  assert_output --partial 'replacing fleet-agent ends its tmux sessions'
  run grep '^run ' "$DOCKER_LOG"
  assert_output --partial '-p 2224:22'
}

@test "up refuses more cores than the box has" {
  FLEET_AGENT_CPUS=9 run "$FLEET_AGENT" up
  assert_failure 2
  assert_output --partial 'FLEET_AGENT_CPUS=9, this box has 8'
  [ ! -e "$DOCKER_LOG" ]
}

@test "up refuses with no authorized_keys, since no one could log in" {
  FLEET_AGENT_KEYS="$SANDBOX/none" run "$FLEET_AGENT" up
  assert_failure 2
  assert_output --partial 'missing or empty'
  [ ! -e "$DOCKER_LOG" ]
}

@test "down removes the container and never a volume" {
  run "$FLEET_AGENT" down
  assert_success
  assert_output --partial 'volumes kept'
  run cat "$DOCKER_LOG"
  assert_output 'rm -f fleet-agent'
}

@test "an unknown verb prints usage and exits 2" {
  run "$FLEET_AGENT" sideways
  assert_failure 2
  assert_output --partial 'usage: fleet-agent up|down|status|shell'
}

@test "the smoke reads probe_hosts' readiness probe out of fleet-dispatch" {
  run "$REPO_ROOT/tests/fleet-agent-smoke.sh" --probe
  assert_success
  assert_output --partial 'test -f "$HOME/.agent/.sync/peer" && echo 1 || echo 0'
  assert_output --partial 'echo kit; fleet-dispatch kit'
  refute_output --partial "'\\''"
}
