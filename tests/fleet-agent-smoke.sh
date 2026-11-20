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
  rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$work/key"

FLEET_AGENT_NAME=$run FLEET_AGENT_KEYS=$work/key.pub FLEET_AGENT_PORT=$port FLEET_AGENT_IMAGE=$image \
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

# check_probe <label> <ready 0|1> <claude in kit: yes|no> -- run the probe once and hold it to both:
# its third line (wt plus a peer store) and whether the line after `kit` names claude.
check_probe() {
  local out ready kit claude=no
  out=$(on_node sh -c "$probe" _)
  echo "$1 probe: $(tr '\n' ' ' <<<"$out")"
  ready=$(sed -n 3p <<<"$out")
  kit=$(sed -n '/^kit$/{n;p;q}' <<<"$out")
  [[ " $kit " != *" claude "* ]] || claude=yes
  [ "$ready" = "$2" ] || { echo "smoke: $1 node read ready=$ready, want $2" >&2; exit 1; }
  [ "$claude" = "$3" ] || { echo "smoke: $1 node kit is '$kit', want claude in it: $3" >&2; exit 1; }
}

check_probe fresh 0 no
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
check_probe signed-in 1 yes

on_node sh -c 'for t in claude tmux codex opencode agent-panel agent-web wt fleet-dispatch; do
  command -v "$t" >/dev/null || { echo "smoke: $t is not on PATH in the image" >&2; exit 1; }; done
  claude --version; tmux -V'
echo "smoke: ok"
