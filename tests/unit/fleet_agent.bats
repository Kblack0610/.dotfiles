#!/usr/bin/env bats
# fleet-agent, the one launcher of the fleet-agent image: what `up` hands docker (the port sshd
# answers on, the volumes that hold every login, a cpuset so nproc inside is honest), that `down`
# never removes a volume, and that the CI smoke still finds probe_hosts' readiness probe in
# fleet-dispatch, so a reworded probe fails here and not only in the image job.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  FLEET_AGENT="$REPO_ROOT/.local/bin/fleet-agent"
  export DOCKER_LOG="$SANDBOX/docker.log"
  # docker: log each call; a container that does not exist yet has no inspect answer.
  cat >"$SANDBOX/bin/docker" <<'EOF'
#!/bin/sh
echo "$*" >>"$DOCKER_LOG"
case "$1" in inspect) exit 1 ;; esac
exit 0
EOF
  chmod +x "$SANDBOX/bin/docker"
  printf '#!/bin/sh\necho 8\n' >"$SANDBOX/bin/nproc" && chmod +x "$SANDBOX/bin/nproc"
  export FLEET_AGENT_MEM=4g
}

@test "up starts the image behind sshd with the home and host-key volumes and a cpuset" {
  run "$FLEET_AGENT" up
  assert_success
  assert_output --partial 'started ghcr.io/kblack0610/fleet-agent:latest on port 2223 (6 cores, 4g)'
  run grep '^run ' "$DOCKER_LOG"
  assert_output --partial '-p 2223:22'
  assert_output --partial '--restart unless-stopped'
  assert_output --partial '--cpuset-cpus 0-5'
  assert_output --partial '-v fleet-agent-home:/home/kblack0610'
  assert_output --partial '-v fleet-agent-hostkeys:/etc/ssh/keys'
  assert_output --partial ":/home/kblack0610/.ssh:ro"
}

@test "up refuses more cores than the box has" {
  FLEET_AGENT_CPUS=9 run "$FLEET_AGENT" up
  assert_failure 2
  assert_output --partial 'FLEET_AGENT_CPUS=9, this box has 8'
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
