#!/usr/bin/env bash
# fleet-agent-smoke.sh <image>: prove a fleet-agent image is a worker, the way fleet-dispatch sees one.
# Starts it with fleet-agent up on throwaway volumes, waits for sshd, then runs fleet-dispatch's own readiness probe
# over ssh, as _fh_ssh does: a fresh node must read 0 (nothing signed in), and the same node with
# placeholder logins must read 1. Run by .github/workflows/fleet-agent.yml; never touches the
# fleet-agent-home volume or a real login.
set -euo pipefail

image=${1:?usage: fleet-agent-smoke.sh <image>}
repo=$(cd "$(dirname "$0")/.." && pwd)
run=smoke-$$
work=$(mktemp -d)
port=${SMOKE_PORT:-2299}

cleanup() {
  docker rm -f "$run" >/dev/null 2>&1 || true
  docker volume rm "$run-home" "$run-hostkeys" >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || sudo rm -rf "$work"
}
trap cleanup EXIT

# The probe is fleet-dispatch's, read from it, so this cannot drift from what dispatch runs.
probe=$(grep -o "sh -c '[^']*fleet-node ready[^']*'" "$repo/.local/bin/fleet-dispatch" | sed "s/^sh -c '//; s/'\$//")
[ -n "$probe" ] || { echo "smoke: no readiness probe found in fleet-dispatch" >&2; exit 1; }

mkdir -m 700 "$work/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cp "$work/key.pub" "$work/ssh/authorized_keys"
# sshd's StrictModes wants ~/.ssh owned by the user (uid 1000 in the image).
[ "$(id -u)" = 1000 ] || sudo chown -R 1000:1000 "$work/ssh"

FLEET_AGENT_NAME=$run FLEET_AGENT_SSH=$work/ssh FLEET_AGENT_PORT=$port FLEET_AGENT_IMAGE=$image \
  "$repo/.local/bin/fleet-agent" up
# sshd prints this line once the entrypoint's sync is done and it accepts connections.
timeout 300 grep -m1 -q 'Server listening' < <(docker logs -f "$run" 2>&1) ||
  { docker logs "$run" | tail -40; echo "smoke: sshd never came up" >&2; exit 1; }

on_node() {
  # shellcheck disable=SC2016 # $HOME and $PATH are the container shell's
  ssh -n -T -i "$work/key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR kblack0610@127.0.0.1 'PATH="$HOME/.local/bin:$PATH" exec env' "$(printf '%q ' "$@")"
}

out=$(on_node sh -c "$probe")
echo "fresh node probe: $(echo "$out" | tr '\n' ' ')"
[ "$(echo "$out" | tail -1)" = 0 ] || { echo "smoke: a node with no logins read ready" >&2; exit 1; }
on_node fleet-node signin | sed 's/^/  signin: /' || true

docker exec -u kblack0610 "$run" sh -c '
  while read -r name dir; do
    case "$name" in "" | "#"*) continue ;; esac
    if [ "$dir" = - ]; then dir=$HOME/.claude; else dir=$HOME/${dir#\~/}; fi
    mkdir -p "$dir" && echo "{}" >"$dir/.credentials.json"
  done <~/.dotfiles/.config/claude-acct/accounts
  mkdir -p ~/.config/gh ~/.dotfiles-private/.git ~/.agent/.git && echo "github.com: {}" >~/.config/gh/hosts.yml'
out=$(on_node sh -c "$probe")
echo "signed-in node probe: $(echo "$out" | tr '\n' ' ')"
[ "$(echo "$out" | tail -1)" = 1 ] || { echo "smoke: a fully signed-in node did not read ready" >&2; exit 1; }
on_node claude --version
echo "smoke: ok"
