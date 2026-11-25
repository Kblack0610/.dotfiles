#!/usr/bin/env bash
# Run the test suite inside the disposable container defined by tests/Dockerfile.
#
# This is the ONLY supported way to run the tmux UI tier. See the long comment at the top
# of the Dockerfile for why: tmux's env-var isolation fails silently, so the UI tier is
# gated on being inside this container and refuses to run on a real machine.
#
# Usage:
#   ./docker.sh                     # the full suite (unit + integ + ui)
#   ./docker.sh test-ui-inner       # just the tmux UI tier
#   ./docker.sh test-fast           # unit + integ, inside the container
#   ./docker.sh --shell             # interactive shell in the image, for debugging
#   TMUX_REF=3.4 ./docker.sh        # sweep a different tmux
#   TMUX_STOCK=1 ./docker.sh ...    # 3.8 without .local/src/tmux/patched: a negative control
#   ./docker.sh --image             # print the image tag and exit (CI keys its image cache on it)
#   ./docker.sh --build             # build the image if it is missing, and exit
#   ./docker.sh --run <cmd> [args]  # one command in the image, from the repo root (CI's cargo builds)
#   DOCKER_NETWORK=bridge ./docker.sh test-rust   # a run that needs the network (crates, npm)
#   TEST_IMAGE_KIND=lean ./docker.sh ...          # a smaller image: lean, rust or full (the default); see below
#
# Run inside the image (a CI job-pod job), it runs the target or --run command in place.
#
# The argument is a make target run INSIDE the container, so it must be an -inner
# target. `./docker.sh test-ui` looks right and is not: the Makefile's test-ui is the
# HOST entry point and re-invokes this script, which then fails with "docker not found"
# from inside the container. Use test-ui-inner, or `make test-ui` from the host.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

TMUX_REF="${TMUX_REF:-3.8}"
TMUX_STOCK="${TMUX_STOCK:-}"
FZF_REF="${FZF_REF:-0.74.1}"
RUST_TOOLCHAIN="$(<"$HERE/rust-toolchain")"
# The phone render harness's playwright-core (tests/agent-web/phone/render.mjs). Bump it here.
PLAYWRIGHT_CORE=1.62.1
CONTEXT="$REPO/.local/src/tmux/patched"
DOCKER="${DOCKER:-docker}"
# The suite needs no network; a run that fetches crates or npm packages asks for it by name.
DOCKER_NETWORK="${DOCKER_NETWORK:-none}"

# The image comes in three sizes, the Dockerfile's stages: lean (the tmux-free tiers and lint),
# rust (lean plus the toolchain: the notes job) and full (plus chromium, tmux and fzf: the ui and
# rust jobs, and every local run). A CI job sets TEST_IMAGE_KIND to the smallest stage that has what
# it runs, because each pool pod loads its image over a link shared with dozens of others
# (ar-5632). Each kind has its own tag, so its own cache entry and its own present check.
KIND="${TEST_IMAGE_KIND:-full}"
case "$KIND" in
  lean | rust | full) ;;
  *) echo "docker.sh: TEST_IMAGE_KIND is lean, rust or full, not '$KIND'" >&2; exit 2 ;;
esac
# The full image's tag has no kind in it: it is the one a local run and every older note know.
KIND_TAG="${KIND}-"
[ "$KIND" != full ] || KIND_TAG=

# One build identity: the default tag ends in a hash of everything the image is built from
# (the Dockerfile, the context and the build args), so an image already present under that
# tag is that build and is not built again. CI restores it from the Actions cache keyed on
# the same tag (.github/actions/test-image). An image named by COCKPIT_TEST_IMAGE carries no
# hash, so it is always built.
build_hash() {
  {
    cat "$HERE/Dockerfile"
    (cd "$CONTEXT" && find -L . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    printf '%s\n' "$TMUX_REF" "$TMUX_STOCK" "$FZF_REF" "$RUST_TOOLCHAIN" "$PLAYWRIGHT_CORE"
  } | sha256sum | cut -c1-12
}
if [ -n "${COCKPIT_TEST_IMAGE:-}" ]; then
  IMAGE="$COCKPIT_TEST_IMAGE"
else
  IMAGE="cockpit-tests:${KIND_TAG}tmux${TMUX_REF}${TMUX_STOCK:+-stock}-fzf${FZF_REF}-$(build_hash)"
fi

if [ "${1:-}" = "--image" ]; then
  echo "$IMAGE"
  exit 0
fi

# Already inside the image (its ENV sets COCKPIT_TEST_DISPOSABLE): a tests.yml job whose job
# container is the image runs here, in the job pod the node's containerd started from it, so the
# node keeps one copy where every dind pod loaded its own (ar-6016). The run is what `docker run`
# below would do, in place: the image's entrypoint gives this uid a passwd entry, and CI keeps its
# cargo registry in the checkout. Its environment is already this one, so nothing is passed through.
if [ -n "${COCKPIT_TEST_DISPOSABLE:-}" ]; then
  case "${1:-}" in
    --build) exit 0 ;;
    --shell) echo "docker.sh: already in the test image" >&2; exit 2 ;;
  esac
  [ -x "$HERE/vendor/bats-core/bin/bats" ] || "$HERE/bootstrap.sh"
  [ -z "${CI:-}" ] || export CARGO_HOME="$REPO/.cargo-ci"
  cd "$REPO"
  if [ "${1:-}" = "--run" ]; then
    shift
    [ $# -gt 0 ] || { echo "docker.sh: --run needs a command" >&2; exit 2; }
    exec /usr/local/bin/test-entry "$@"
  fi
  exec /usr/local/bin/test-entry make -C tests "${@:-test-container}"
fi

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
[ -x "$HERE/vendor/bats-core/bin/bats" ] || "$HERE/bootstrap.sh"

if [ -z "${COCKPIT_TEST_IMAGE:-}" ] && "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> image $IMAGE (present, not rebuilt)"
else
  echo "==> image $IMAGE ($KIND, tmux $TMUX_REF, fzf $FZF_REF)"
  # The context is the patch directory: the one thing the image copies.
  # --pull: a newer debian base under the same tag rebuilds every layer, apt included, so a
  # host's layer cache cannot carry last week's packages into this week's image.
  "$DOCKER" build --pull \
    --build-arg "TMUX_REF=$TMUX_REF" \
    --build-arg "TMUX_STOCK=$TMUX_STOCK" \
    --build-arg "FZF_REF=$FZF_REF" \
    --build-arg "RUST_TOOLCHAIN=$RUST_TOOLCHAIN" \
    --build-arg "PLAYWRIGHT_CORE=$PLAYWRIGHT_CORE" \
    --target "$KIND" -t "$IMAGE" -f "$HERE/Dockerfile" "$CONTEXT" >/dev/null
  # A new hash leaves the old image tagged, and prune skips tagged images, so drop this
  # tmux/fzf pair's older builds here. One another run is still using stays.
  if [ -z "${COCKPIT_TEST_IMAGE:-}" ]; then
    "$DOCKER" image ls --format '{{.Repository}}:{{.Tag}}' cockpit-tests | grep -F "${IMAGE%-*}-" |
      grep -vxF "$IMAGE" | xargs -r "$DOCKER" rmi >/dev/null 2>&1 || true
  fi
fi
[ "${1:-}" = "--build" ] && exit 0

# --network none      the default (DOCKER_NETWORK above): nothing can phone home
# --init              reap orphans. A crashed test can leave fzf/tmux children behind, and
#                     without an init as PID 1 they survive as zombies inside the run.
# --user host:uid     artifacts land owned by the developer instead of root. That UID has no
#                     passwd entry in the image, so USER is passed and the image's entrypoint
#                     adds one under that name (tests/Dockerfile).
# --rm                nothing persists but what is written into the bind mount
# --shm-size          chromium (the phone render harness) runs out of docker's 64 MB /dev/shm
run_args=(
  --rm --init
  --network "$DOCKER_NETWORK"
  --user "$(id -u):$(id -g)"
  --env "USER=$(id -un)"
  --shm-size 1g
  --volume "$REPO:/work"
  --workdir /work
)
# In CI the cargo registry goes in the checkout, so it outlives the container and actions/cache
# keeps it. A local run leaves it in the container, so no worktree grows a registry of its own.
[ -n "${CI:-}" ] && run_args+=(--env CARGO_HOME=/work/.cargo-ci)

# Git WORKTREE support. In a worktree, `.git` is a FILE containing
# `gitdir: /path/to/main/.git/worktrees/<name>`, which lives OUTSIDE this bind mount - so
# `git ls-files` inside the container fails and the lint gate would see zero files. Mount
# the main repo's .git at the same absolute path the pointer names, so the indirection
# resolves. Read-only: the tests never need to write to git.
if [ -f "$REPO/.git" ]; then
  main_gitdir="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$main_gitdir" ] && [ -d "$main_gitdir" ]; then
    run_args+=(--volume "$main_gitdir:$main_gitdir:ro")
    echo "==> worktree detected; also mounting $main_gitdir (ro) so git resolves"
  fi
fi
# The host's settings a run reads, each only when set. Passed through empty, BATS_FLAGS would
# override the Makefile's `BATS_FLAGS ?=` default -- make treats a set-but-empty environment
# variable as a definition -- silently dropping --print-output-on-failure.
# CI turns a missing prerequisite (the agent-panel build session_send.bats drives) from a skip
# into a failure, so a red cannot hide as a skip there. JUNIT=1 writes the JUnit reports CI
# uploads (tests/Makefile). RUST_JOBS and CARGO_INCREMENTAL are the rust job's (tests/rust.sh),
# TILECAST_READ_TOKEN the Tilecast schema check's (tests/agent-web/tilecast-schema.sh). CI_CPU_MILLI
# is the runner pod's CPU request: the container sees the host's cores, so tests/cpus.sh needs it.
# No path goes through: the checkout is /work in here, so a path is passed as /work/...
# Each goes by name alone, so docker reads the value from this environment and a token never
# sits in the docker command line.
for v in BATS_FLAGS CI CI_CPU_MILLI JUNIT RUST_JOBS CARGO_INCREMENTAL TILECAST_READ_TOKEN; do
  [ -n "${!v:-}" ] && export "${v?}" && run_args+=(--env "$v")
done

if [ "${1:-}" = "--shell" ]; then
  shift
  exec "$DOCKER" run -it "${run_args[@]}" "$IMAGE" bash "$@"
fi
if [ "${1:-}" = "--run" ]; then
  shift
  # With no command, docker would run the image's CMD: the whole container suite.
  [ $# -gt 0 ] || { echo "docker.sh: --run needs a command" >&2; exit 2; }
  exec "$DOCKER" run "${run_args[@]}" "$IMAGE" "$@"
fi

targets=("${@:-test-container}")
exec "$DOCKER" run "${run_args[@]}" "$IMAGE" make -C tests "${targets[@]}"
