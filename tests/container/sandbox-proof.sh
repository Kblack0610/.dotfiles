#!/usr/bin/env bash
# sandbox-proof.sh - prove a lane sandbox profile against the real sandbox runtime, in a
# disposable container, never on this account and never with a live model call.
#
# Two modes, one per way lib/sandbox.sh applies a profile; the check labels below say what each
# proves, and every denial has an unsandboxed control that must succeed.
#   default: a claude lane (sandbox_claude_settings): srt with the profile and the git common dir
#            writable but its hooks and config.
#   --srt:   a harness that names `sandbox:` in harnesses.json (fleet-dispatch's opencode launch):
#            the real sandbox_srt_settings and sandbox_env_clear from this checkout, with the
#            launch's --ro config and key and --rw config_dir; its negative control turns the
#            profile's denyRead and the env clear off.
#
# Usage: tests/container/sandbox-proof.sh [profile.json]   (default ~/.config/agentctl/sandbox/lane.json)
#        tests/container/sandbox-proof.sh --srt <profile.json>
# Needs docker and network. Exit 0 when every check holds.
set -euo pipefail

MODE=claude
[ "${1:-}" != --srt ] || { MODE=srt; shift; [ -n "${1:-}" ] || { echo "--srt needs a profile: the default lane profile lists GitHub, which this mode must deny" >&2; exit 2; }; }
PROFILE="$(readlink -f "${1:-$HOME/.config/agentctl/sandbox/lane.json}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../.local/src/agent-run/lib/sandbox.sh"
# The pin the installer puts on this host, so the proof runs the srt a lane runs.
SRT_VERSION="${SRT_VERSION:-$(grep -oE 'sandbox-runtime@[0-9.]+' "$HERE/../../.local/src/installation_scripts/packages.conf" | head -n1 | cut -d@ -f2 || true)}"
[ -n "$SRT_VERSION" ] || { echo "no sandbox-runtime pin in packages.conf; set SRT_VERSION" >&2; exit 2; }
IMAGE="lane-sandbox-proof:srt$SRT_VERSION"
DOCKER="${DOCKER:-docker}"
jq -e '.sandbox | type == "object"' "$PROFILE" >/dev/null || { echo "not a sandbox profile: $PROFILE" >&2; exit 2; }
if [ "$MODE" = claude ]; then
  # The proof needs one listed host to reach; the profile must list it.
  jq -e '.sandbox.network.allowedDomains | index("api.github.com")' "$PROFILE" >/dev/null \
    || { echo "the proof reaches api.github.com as the listed host, and $PROFILE does not list it" >&2; exit 2; }
  LISTED=api.github.com
else
  # The listed host to reach: the profile's first plain hostname (no wildcard, no port).
  LISTED=$(jq -r '[.sandbox.network.allowedDomains[]? | select(test("^[a-z0-9.-]+$"))][0] // empty' "$PROFILE")
  [ -n "$LISTED" ] || { echo "$PROFILE lists no plain hostname for the proof to reach" >&2; exit 2; }
fi

"$DOCKER" build -q -t "$IMAGE" - >/dev/null <<EOF
FROM node:22-trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends bubblewrap socat ripgrep git curl ca-certificates jq >/dev/null \
 && npm install -g --silent @anthropic-ai/sandbox-runtime@$SRT_VERSION && useradd -m lane
USER lane
WORKDIR /home/lane
EOF

# bwrap needs user namespaces and its own /proc, which docker's default seccomp and apparmor
# profiles and its masked /proc paths refuse ("Can't mount proc on /proc"). The profile keeps its
# name (lib/sandbox.sh loads SANDBOX_PROFILE=<name> from its dir).
exec "$DOCKER" run --rm -i --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
  -e MODE="$MODE" -e LISTED="$LISTED" -e NAME="$(basename "$PROFILE" .json)" \
  -v "$PROFILE:/profiles/$(basename "$PROFILE"):ro" -v "$(readlink -f "$LIB"):/sandbox.sh:ro" "$IMAGE" bash -s <<'INNER'
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
cd ~/wt

if [ "$MODE" = srt ]; then
  # The launch's own files, as fleet-dispatch passes them: the harness config and key read-only,
  # its config_dir (the run dir inside it) writable.
  mkdir -p ~/.dotfiles-private ~/state/cfgdir/run/tmp ~/conf
  echo 'PRIVATE-RULE' > ~/.dotfiles-private/AGENTS.md
  echo '{"model": "x"}' > ~/conf/eval.json; echo 'sk-fake' > ~/state/fleet.key
  role_die() { echo "refused: $*"; exit 78; }
  # shellcheck source=/dev/null
  . /sandbox.sh
  SANDBOX_DIR=/profiles SANDBOX_PROFILE=$NAME GH_TOKEN_FILE=''
  sandbox_load
  why=$(sandbox_srt_refusal); [ -z "$why" ] || { echo "srt cannot hold a run here: $why"; exit 1; }
  sandbox_srt_settings --ro ~/conf/eval.json --ro ~/state/fleet.key --rw ~/state/cfgdir > ~/srt.json
  jq '.filesystem.denyRead = []' ~/srt.json > ~/srt-open.json
  jail="$(sandbox_env_clear) TMPDIR=$HOME/state/cfgdir/run/tmp"
  export LITELLM_MASTER_KEY=sk-master-fake
  # argv after --, never one string: srt takes a lone quoted string as a command NAME.
  sb() { eval "$jail"' srt --settings ~/srt.json -- "$@"'; }
  sb_open() { srt --settings ~/srt-open.json -- "$@"; }
  # ~/.gitconfig is masked inside, so a commit names its author on the command line; otherwise it
  # fails on identity and passes the read-only check for the wrong reason.
  ident=(-c user.name=lane -c user.email=lane@example.invalid)
  jq --arg c "$common" '.filesystem.allowWrite += [$c]' ~/srt.json > ~/srt-rw.json
  sb_rw() { eval "$jail"' srt --settings ~/srt-rw.json -- "$@"'; }

  check ok     "sandbox: runs a command at all"              sb cat /etc/hostname
  [ "$fail" = 0 ] || { echo "the sandbox itself does not start; the denials below would prove nothing"; exit 1; }
  check ok     "control: read the private repo"              cat ~/.dotfiles-private/AGENTS.md
  check ok     "control: reach an unlisted host"             curl -sf --max-time 15 -o /dev/null https://example.com
  check ok     "control: reach GitHub"                       curl -sf --max-time 15 -o /dev/null https://api.github.com/zen
  check ok     "control: the master key is in the env"       printenv LITELLM_MASTER_KEY
  check ok     "control: write beside the config"            touch ~/conf/control
  check ok     "control: plant a hook in the common dir"     touch "$common/hooks/control"
  check ok     "control: git commit"                         git "${ident[@]}" commit -q --allow-empty -m control
  check ok     "profile off: read the private repo"          sb_open cat ~/.dotfiles-private/AGENTS.md
  check ok     "profile off: read the fake ssh key"          sb_open cat ~/.ssh/id_fake
  check ok     "env clear off: the master key reaches srt"   sb_open printenv LITELLM_MASTER_KEY
  check ok     "common dir writable: git commit"             sb_rw git "${ident[@]}" commit -q --allow-empty -m rw
  check denied "sandbox: read the private repo"              sb cat ~/.dotfiles-private/AGENTS.md
  check denied "sandbox: read the fake ssh key"              sb cat ~/.ssh/id_fake
  check denied "sandbox: read the fake gh token"             sb cat ~/.config/gh/hosts.yml
  check denied "sandbox: the master key is in the env"       sb printenv LITELLM_MASTER_KEY
  check ok     "sandbox: read the harness config"            sb cat ~/conf/eval.json
  check ok     "sandbox: read the harness key"               sb cat ~/state/fleet.key
  check denied "sandbox: write the harness config"           sb touch ~/conf/eval.json
  # A masked path is an empty tmpfs inside, so a write there succeeds and vanishes with the run:
  # what counts is whether the file is on disk afterwards.
  lands() { [ ! -e "$1" ] || { echo "proof bug: $1 exists before the write"; exit 1; }; sb touch "$1"; [ -e "$1" ]; }
  check ok     "sandbox: a write in the cwd lands"           lands ~/wt/inside
  check ok     "sandbox: a write in the config_dir lands"    lands ~/state/cfgdir/run/inside
  check denied "sandbox: a write outside them lands"         lands ~/outside
  check denied "sandbox: a write beside the config lands"    lands ~/conf/beside
  check ok     "sandbox: git status in the worktree"         sb git status --short
  check denied "sandbox: git commit (common dir read-only)"  sb git "${ident[@]}" commit -q --allow-empty -m lane
  check denied "sandbox: move the shared repo's refs"        sb git update-ref refs/heads/x HEAD
  check denied "sandbox: plant a hook in the common dir"     sb touch "$common/hooks/post-commit"
  check denied "sandbox: reach an unlisted host"             sb curl -sf --max-time 15 -o /dev/null https://example.com
  check denied "sandbox: reach GitHub (no gh, no push)"      sb curl -sf --max-time 15 -o /dev/null https://api.github.com/zen
  # Any HTTP answer counts: the gateway wants a key the proof does not have.
  check ok     "sandbox: reach the listed host ($LISTED)"    sb curl -s --max-time 15 -o /dev/null "https://$LISTED/"
  exit "$fail"
fi

# srt settings: the profile's sandbox keys, plus the cwd (Claude Code makes it writable itself,
# srt does not) and the git common dir with its hooks and config denied, as lib/sandbox.sh adds.
jq --arg c "$common" --arg cwd "$HOME/wt" '.sandbox | {network: {allowedDomains: (.network.allowedDomains // []), deniedDomains: []},
  filesystem: {denyRead: (.filesystem.denyRead // []), allowWrite: ((.filesystem.allowWrite // []) + [$cwd, $c]), denyWrite: ((.filesystem.denyWrite // []) + [$c + "/hooks", $c + "/config"])}}' \
  "/profiles/$NAME.json" > ~/with-common.json
jq '.filesystem.allowWrite -= [$c]' --arg c "$common" ~/with-common.json > ~/no-common.json
# argv after --, never one string: srt takes a lone quoted string as a command NAME, and reads
# a command's own short flags (curl -sS) as its own without the --.
sb() { srt --settings ~/with-common.json -- "$@"; }

# A sandbox that cannot start denies everything, which would pass every denial below: this one
# must run first, and nothing after it counts when it fails.
check ok     "sandbox: runs a command at all"       sb cat /etc/hostname
[ "$fail" = 0 ] || { echo "the sandbox itself does not start; the denials below would prove nothing"; exit 1; }
check ok     "control: read the fake ssh key"       cat ~/.ssh/id_fake
check ok     "control: reach an unlisted host"      curl -sf --max-time 15 -o /dev/null https://example.com
check denied "sandbox: read the fake ssh key"       sb cat ~/.ssh/id_fake
check denied "sandbox: read the fake gh token"      sb cat ~/.config/gh/hosts.yml
check denied "sandbox: reach an unlisted host"      sb curl -sf --max-time 15 -o /dev/null https://example.com
check ok     "sandbox: reach a listed host"         sb curl -sf --max-time 15 -o /dev/null "https://$LISTED/zen"
check denied "sandbox: write outside cwd and roots" sb touch ~/outside
check ok     "sandbox: write in the cwd"            sb touch ~/wt/inside
check ok     "sandbox: git commit from a worktree"  sb git commit -q --allow-empty -m lane
check denied "sandbox: plant a hook in the common dir"  sb touch "$common/hooks/post-commit"
check denied "sandbox: set git config in the common dir" sb git config core.fsmonitor /tmp/x
check ok     "control: set git config unsandboxed"     git config core.fsmonitor false
check denied "sandbox without the common dir: git commit" srt --settings ~/no-common.json -- git commit -q --allow-empty -m lane2
exit "$fail"
INNER
