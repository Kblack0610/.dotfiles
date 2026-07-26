#!/usr/bin/env bash
# Run the test suite inside the disposable container defined by tests/Dockerfile.
#
# This is the ONLY supported way to run the tmux UI tier. See the long comment at the top
# of the Dockerfile for why: tmux's env-var isolation fails silently, so the UI tier is
# gated on being inside this container and refuses to run on a real machine.
#
# Usage:
#   ./docker.sh                     # the full suite (unit + integ + ui)
#   ./docker.sh test-ui             # just the tmux UI tier
#   ./docker.sh test-fast           # unit + integ, inside the container
#   ./docker.sh --shell             # interactive shell in the image, for debugging
#   TMUX_REF=3.4 ./docker.sh        # sweep a different tmux
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

TMUX_REF="${TMUX_REF:-3.7b}"
FZF_REF="${FZF_REF:-0.74.1}"
IMAGE="${COCKPIT_TEST_IMAGE:-cockpit-tests:tmux${TMUX_REF}-fzf${FZF_REF}}"
DOCKER="${DOCKER:-docker}"

command -v "$DOCKER" >/dev/null 2>&1 || {
  echo "docker not found. Install it, or run only the tmux-free tiers: make -C tests test-fast" >&2
  exit 1
}
"$DOCKER" info >/dev/null 2>&1 || {
  echo "cannot talk to the docker daemon (is it running, and are you in the docker group?)" >&2
  exit 1
}

# Vendor bats on the HOST, before the container starts, so the container itself needs no
# network. Cloning inside would also write into the bind mount as a different UID.
[ -x "$HERE/vendor/bats-core/bin/bats" ] || make -C "$HERE" bootstrap

echo "==> image $IMAGE (tmux $TMUX_REF, fzf $FZF_REF)"
"$DOCKER" build \
  --build-arg "TMUX_REF=$TMUX_REF" \
  --build-arg "FZF_REF=$FZF_REF" \
  -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" >/dev/null

# --network none      the suite needs no network; nothing can phone home
# --init              reap orphans. A crashed test can leave fzf/tmux children behind, and
#                     without an init as PID 1 they survive as zombies inside the run.
# --user host:uid     artifacts land owned by the developer instead of root
# --rm                nothing persists but what is written into the bind mount
run_args=(
  --rm --init
  --network none
  --user "$(id -u):$(id -g)"
  --volume "$REPO:/work"
  --workdir /work
)
# Only forward BATS_FLAGS when the caller actually set it. Passing it through empty would
# override the Makefile's `BATS_FLAGS ?=` default -- make treats a set-but-empty environment
# variable as a definition -- silently dropping --print-output-on-failure.
[ -n "${BATS_FLAGS:-}" ] && run_args+=(--env "BATS_FLAGS=$BATS_FLAGS")

if [ "${1:-}" = "--shell" ]; then
  shift
  exec "$DOCKER" run -it "${run_args[@]}" "$IMAGE" bash "$@"
fi

targets=("${@:-test-container}")
exec "$DOCKER" run "${run_args[@]}" "$IMAGE" make -C tests "${targets[@]}"
