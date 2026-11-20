#!/usr/bin/env bash
# fleet-agent-smoke.sh <image>: prove a fleet-agent image is a worker, the way fleet-dispatch sees one.
# Starts it with fleet-agent up on throwaway volumes, waits for sshd, then runs fleet-dispatch's own
# readiness probe (probe_hosts) over fleet-hosts.sh's own ssh path (_fh_ssh). A fresh node must read
# not ready with no claude in its kit (the negative control: no peer store, no account token); the same
# node with placeholder tokens and a peer store must read ready with claude in its kit. Run by
# .github/workflows/fleet-agent.yml; never touches the fleet-agent-home volume or a real login.
#
#   fleet-agent-smoke.sh --probe   print the probe it would run, and exit (tests/unit/fleet_agent.bats)
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

# The probe is the one probe_hosts runs, read from fleet-dispatch, so this cannot drift from it: the
# single-quoted word after `sh -c` on its fleet_host_run line, unquoted by the shell itself.
probe_line=$(grep -m1 "fleet_host_run \"\$name\" sh -c '.*\.sync/peer" "$repo/.local/bin/fleet-dispatch") ||
  { echo "smoke: no readiness probe found in fleet-dispatch probe_hosts" >&2; exit 1; }
probe_word=${probe_line#*sh -c }
probe_word=${probe_word%% _ \$listed*}
eval "probe=$probe_word"
[ "${1:-}" != --probe ] || { printf '%s\n' "$probe"; exit 0; }

image=${1:?usage: fleet-agent-smoke.sh <image> | --probe}
run=smoke-$$
work=$(mktemp -d)
port=${SMOKE_PORT:-2299}

cleanup() {
  docker rm -f "$run" >/dev/null 2>&1 || true
  docker volume rm "$run-home" "$run-hostkeys" >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || sudo rm -rf "$work"
}
trap cleanup EXIT

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

# shellcheck source=../.local/lib/fleet-hosts.sh
. "$repo/.local/lib/fleet-hosts.sh"
on_node() {
  _fh_ssh kblack0610@127.0.0.1 -p "$port" -i "$work/key" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -- "$@"
}
# ready_line <probe output> -> its third line, wt plus a peer store (1 or 0); kit_line -> the line after `kit`.
ready_line() { sed -n 3p <<<"$1"; }
kit_line() { sed -n '/^kit$/{n;p;q}' <<<"$1"; }

out=$(on_node sh -c "$probe" _)
echo "fresh node probe: $(tr '\n' ' ' <<<"$out")"
[ "$(ready_line "$out")" = 0 ] || { echo "smoke: a node with no peer store read ready" >&2; exit 1; }
[[ " $(kit_line "$out") " != *" claude "* ]] || { echo "smoke: claude is in the kit of a node with no account token" >&2; exit 1; }
on_node fleet-node signin | sed 's/^/  signin: /' || true

# Placeholder sign-ins, the shape `claude-acct token push` and `store-sync join` leave: a token copy per
# account (no rbw in the image, so claude-acct reads the copy) and the peer-store mark.
docker exec -u kblack0610 "$run" sh -c '
  dir=${XDG_CONFIG_HOME:-$HOME/.config}/claude-acct/tokens
  mkdir -p "$dir" ~/.agent/.sync && chmod 700 "$dir" && touch ~/.agent/.sync/peer
  while read -r name _; do
    case "$name" in "" | "#"*) continue ;; esac
    printf "sk-ant-oat01-smoke-%s" "$name" >"$dir/$name"
  done <~/.config/claude-acct/accounts'
out=$(on_node sh -c "$probe" _)
echo "signed-in node probe: $(tr '\n' ' ' <<<"$out")"
[ "$(ready_line "$out")" = 1 ] || { echo "smoke: a node with a peer store did not read ready" >&2; exit 1; }
[[ " $(kit_line "$out") " == *" claude "* ]] || { echo "smoke: claude is not in the kit of a node with every token" >&2; exit 1; }
for tool in "claude --version" "tmux -V" "codex --version" "opencode --version"; do
  # shellcheck disable=SC2086 # each entry is a command and its flag
  echo "  $tool: $(on_node $tool 2>&1 | sed -n 1p)"
done
on_node sh -c 'command -v agent-panel agent-web wt fleet-dispatch' >/dev/null ||
  { echo "smoke: a fleet tool is missing from PATH in the image" >&2; exit 1; }
echo "smoke: ok"
