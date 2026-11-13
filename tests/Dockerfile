# The disposable machine the tmux UI tier runs on.
#
# WHY THIS EXISTS
# ---------------
# A tmux UI test has to start a real tmux server and send it keys. Run that on the
# developer's own account and it shares /tmp/tmux-$UID with their live sessions, so a
# single unscoped `tmux kill-server` -- in a teardown, in a subject script, in a stray
# probe -- destroys every session they have open. That is not theoretical; it happened
# twice in one evening while this suite was being written.
#
# Careful test code cannot fix that, because the two obvious isolation mechanisms both
# fail silently:
#   * `TMUX_TMPDIR=<sandbox>` is IGNORED when $TMUX is set (i.e. whenever you are inside
#     tmux, which is exactly when you are working on tmux scripts), and falls back to
#     /tmp when the directory does not exist. Verified both ways on tmux 3.7b.
#   * `command tmux` still honours PATH, so it finds a stub rather than bypassing one.
# Only an explicit `-S <path>` / `-L <name>` FLAG actually isolates a server, which is
# why tmux's own regress suite and fzf's test/test_tmux.rb both use one.
#
# So the suite uses the flag AND runs on a machine with nothing to lose. In here there is
# no host tmux server, no $TMUX, and a private /tmp: even a maximally buggy test can only
# kill the server it started. tests/helpers/tmux_harness.bash refuses to run the UI tier
# outside this container, so the unsafe path is unreachable rather than merely discouraged.
#
# Built and run by tests/docker.sh; `make -C tests test-ui` is the entry point.

# The linters are pinned, and that is not fussiness: a new shellcheck release finds new
# things, so an unpinned lint gate goes red on a repo nobody touched. Bumping these is a
# deliberate, reviewable diff -- which is also when the severity ratchet gets revisited.
# Each comes from its project's official image (a static binary at /bin, amd64 and arm64),
# pinned by digest, from the registry the base image already needs. Not the GitHub release
# asset: that one can answer 504 for longer than any curl retry waits.
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck
FROM mvdan/shfmt:v3.13.1@sha256:f22f3936140be1ba02d493b5d2b91d0e8b4af93fd903e7f46c477822bca4a3be AS shfmt

FROM debian:trixie-slim

# Pinned so a CI run and a laptop run agree, and so a distro bump cannot silently change
# what is under test. Override to sweep versions:
#   docker build --build-arg TMUX_REF=3.4 ...
# TMUX_STOCK=1 leaves 3.8 unpatched, for a regression test's negative control.
ARG TMUX_REF=3.8
ARG TMUX_STOCK=
ARG FZF_REF=0.74.1

ENV DEBIAN_FRONTEND=noninteractive

# ncurses-term supplies the xterm-256color terminfo entry the harness pins TERM to; without
# it tmux falls back and the rendered grid differs. `column` comes from bsdextrautils on
# trixie (it moved out of bsdmainutils), and fleet.sh shells out to it.
# nodejs runs tab_keeper.bats (`node --test`); openssl and xxd sign release-state's store JWTs.
# lua5.4 loads the Hyprland Lua config for helpers/hypr-lua-dump.lua.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl gawk git jq less procps sed tar xz-utils \
      ncurses-base ncurses-bin ncurses-term bsdextrautils \
      libevent-dev libncurses-dev bison pkg-config make gcc \
      python3 python3-yaml sqlite3 nodejs openssl xxd lua5.4 \
    && rm -rf /var/lib/apt/lists/*

# The tmux and fzf downloads below go to GitHub's release CDN, which answers a 504 now and then,
# and a cold build (any change to what tests/docker.sh hashes) downloads them again. curl reads
# this file, so the retry lives in one place and each download keeps its plain `curl -fsSL`.
RUN printf 'retry = 8\nretry-delay = 15\nretry-all-errors\n' > /root/.curlrc

# python3 + PyYAML are RUNTIME dependencies of a subject, not build tools:
# sentinel-manifest parses and validates watch manifests with them. Without python3 the
# whole `sentinel_manifest` suite fails with `env: 'python3': No such file or directory`;
# with python3 but no PyYAML it fails with the subject's own honest refusal,
# `sentinel-manifest: PyYAML is required`. Both were red; both are fixed here.
#
# That was invisible because of WHICH job runs the whole suite. The `ui` tier runs only
# tests/ui/, and `fast` runs on the bare runner where python3 exists -- only the weekly
# DRIFT sweep runs every tier inside this image, so the failure surfaced once a week in a
# job nobody was watching, and both PR-gating tiers stayed green. A gate that runs weekly
# and is never read is the same as no gate.

# tmux from source. Debian trixie ships 3.5a; the author's machine runs 3.8 with the patch in
# .local/src/tmux/patched, which is this image's build context, so what is tested is what runs.
# Floating panes only exist from 3.7. Release tarballs ship a generated ./configure, so no
# autogen; `git apply` keeps the source's timestamps from asking for one.
COPY tree-mode-self-kill.patch /tmp/tree-mode-self-kill.patch
RUN curl -fsSL -o /tmp/tmux.tar.gz \
      "https://github.com/tmux/tmux/releases/download/${TMUX_REF}/tmux-${TMUX_REF}.tar.gz" \
    && tar xf /tmp/tmux.tar.gz -C /tmp \
    && cd "/tmp/tmux-${TMUX_REF}" \
    && if [ "$TMUX_REF" = 3.8 ] && [ -z "$TMUX_STOCK" ]; then git apply --whitespace=nowarn /tmp/tree-mode-self-kill.patch; fi \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/tmux* \
    && tmux -V

# fzf from the pinned release binary rather than apt. The cockpit's bindings use `transform`
# (fzf >= 0.45) and `become` (>= 0.38), and apt's version is version roulette across distros.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) fzf_arch=amd64 ;; \
         arm64) fzf_arch=arm64 ;; \
         *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/fzf.tar.gz \
      "https://github.com/junegunn/fzf/releases/download/v${FZF_REF}/fzf-${FZF_REF}-linux_${fzf_arch}.tar.gz" \
    && tar xf /tmp/fzf.tar.gz -C /usr/local/bin fzf \
    && rm -f /tmp/fzf.tar.gz \
    && fzf --version

# shellcheck + shfmt, so `tests/docker.sh lint` runs the exact gate CI runs without anyone
# having to install a linter.
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=shfmt /bin/shfmt /usr/local/bin/shfmt
RUN shellcheck --version | grep version: && shfmt --version

# THE MARKER. tmux_harness.bash's require_disposable_host() checks for this together with
# /.dockerenv, and hard-fails the test otherwise. Both are needed: the env var alone could
# be exported on a real host, and /.dockerenv alone would green-light any container.
ENV COCKPIT_TEST_DISPOSABLE=1

# Deterministic terminal env, matching what the harness expects. Repeated in sandbox_init
# so the cheaper tiers get it too; set here so an interactive `docker run ... bash` debug
# session behaves the same as a test run.
ENV TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8

# The repo is bind-mounted here by tests/docker.sh, and the container runs as the invoking
# host UID so any artifact it writes is owned by the developer, not root. That UID has no
# /etc/passwd entry, so $HOME is set explicitly -- tmux and bash both need a writable one.
WORKDIR /work
ENV HOME=/tmp/testhome
RUN mkdir -p /tmp/testhome && chmod 1777 /tmp/testhome

CMD ["make", "-C", "tests", "test-container"]
