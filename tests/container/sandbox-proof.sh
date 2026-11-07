#!/usr/bin/env bash
# sandbox-proof.sh - prove a lane sandbox profile against the real sandbox runtime, in a
# disposable container, never on this account and never with a live claude call.
#
# Claude Code's sandbox is @anthropic-ai/sandbox-runtime (bwrap + socat proxy on Linux), and
# its `srt` CLI takes the same filesystem and network keys a profile's `sandbox` object holds.
# This runs srt with the profile (plus the git common dir lib/sandbox.sh adds) and checks,
# each against an unsandboxed control that must succeed:
#   - a planted fake credential under a denyRead path cannot be read
#   - an unlisted host cannot be reached, a listed one can
#   - a write outside the cwd and allowWrite fails
#   - `git commit` works from a worktree, and fails without the common dir (why it is added)
#
# Usage: tests/container/sandbox-proof.sh [profile.json]   (default ~/.config/agentctl/sandbox/lane.json)
# Needs docker and network. Exit 0 when every check holds.
set -euo pipefail

PROFILE="$(readlink -f "${1:-$HOME/.config/agentctl/sandbox/lane.json}")"
SRT_VERSION="${SRT_VERSION:-0.0.81}"
IMAGE="lane-sandbox-proof:srt$SRT_VERSION"
DOCKER="${DOCKER:-docker}"
jq -e '.sandbox | type == "object"' "$PROFILE" >/dev/null || { echo "not a sandbox profile: $PROFILE" >&2; exit 2; }
# The proof needs one listed host to reach; the profile must list it.
jq -e '.sandbox.network.allowedDomains | index("api.github.com")' "$PROFILE" >/dev/null \
  || { echo "the proof reaches api.github.com as the listed host, and $PROFILE does not list it" >&2; exit 2; }

"$DOCKER" build -q -t "$IMAGE" - >/dev/null <<EOF
FROM node:22-trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends bubblewrap socat ripgrep git curl ca-certificates jq >/dev/null \
 && npm install -g --silent @anthropic-ai/sandbox-runtime@$SRT_VERSION && useradd -m lane
USER lane
WORKDIR /home/lane
EOF

# bwrap needs user namespaces and its own /proc, which docker's default seccomp and apparmor
# profiles and its masked /proc paths refuse ("Can't mount proc on /proc").
exec "$DOCKER" run --rm -i --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
  -v "$PROFILE:/profile.json:ro" "$IMAGE" bash -s <<'INNER'
set -uo pipefail
fail=0
check() { # check <want ok|denied> <label> <cmd...>
  local want="$1" label="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=denied; fi
  if [ "$got" = "$want" ]; then echo "PASS  $label ($got)"; else echo "FAIL  $label (wanted $want, got $got)"; fail=1; fi
}
git config --global user.name lane; git config --global user.email lane@example.invalid
mkdir -p ~/.ssh ~/.config/gh
echo 'FAKE-PRIVATE-KEY' > ~/.ssh/id_fake
echo 'oauth_token: FAKE' > ~/.config/gh/hosts.yml
git init -q ~/repo && git -C ~/repo commit -q --allow-empty -m init && git -C ~/repo worktree add -q ~/wt -b lane
common="$(git -C ~/wt rev-parse --path-format=absolute --git-common-dir)"
# srt settings: the profile's sandbox keys, plus the cwd (Claude Code makes it writable itself,
# srt does not) and the git common dir lib/sandbox.sh adds.
jq --arg c "$common" --arg cwd "$HOME/wt" '.sandbox | {network: {allowedDomains: (.network.allowedDomains // []), deniedDomains: []},
  filesystem: {denyRead: (.filesystem.denyRead // []), allowWrite: ((.filesystem.allowWrite // []) + [$cwd, $c]), denyWrite: []}}' \
  /profile.json > ~/with-common.json
jq '.filesystem.allowWrite -= [$c]' --arg c "$common" ~/with-common.json > ~/no-common.json
# argv after --, never one string: srt takes a lone quoted string as a command NAME, and reads
# a command's own short flags (curl -sS) as its own without the --.
sb() { srt --settings ~/with-common.json -- "$@"; }
cd ~/wt

# A sandbox that cannot start denies everything, which would pass every denial below: this one
# must run first, and nothing after it counts when it fails.
check ok     "sandbox: runs a command at all"       sb cat /etc/hostname
[ "$fail" = 0 ] || { echo "the sandbox itself does not start; the denials below would prove nothing"; exit 1; }
check ok     "control: read the fake ssh key"       cat ~/.ssh/id_fake
check ok     "control: reach an unlisted host"      curl -sf --max-time 15 -o /dev/null https://example.com
check denied "sandbox: read the fake ssh key"       sb cat ~/.ssh/id_fake
check denied "sandbox: read the fake gh token"      sb cat ~/.config/gh/hosts.yml
check denied "sandbox: reach an unlisted host"      sb curl -sf --max-time 15 -o /dev/null https://example.com
check ok     "sandbox: reach a listed host"         sb curl -sf --max-time 15 -o /dev/null https://api.github.com/zen
check denied "sandbox: write outside cwd and roots" sb touch ~/outside
check ok     "sandbox: write in the cwd"            sb touch ~/wt/inside
check ok     "sandbox: git commit from a worktree"  sb git commit -q --allow-empty -m lane
check denied "sandbox without the common dir: git commit" srt --settings ~/no-common.json -- git commit -q --allow-empty -m lane2
exit "$fail"
INNER
