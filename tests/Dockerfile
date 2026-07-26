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

FROM debian:trixie-slim

# Pinned so a CI run and a laptop run agree, and so a distro bump cannot silently change
# what is under test. Override to sweep versions:
#   docker build --build-arg TMUX_REF=3.4 ...
ARG TMUX_REF=3.7b
ARG FZF_REF=0.74.1
# The linters are pinned too, and that is not fussiness: a new shellcheck release finds new
# things, so an unpinned lint gate goes red on a repo nobody touched. Bumping these is a
# deliberate, reviewable diff -- which is also when the severity ratchet gets revisited.
ARG SHELLCHECK_REF=v0.11.0
ARG SHFMT_REF=v3.13.1

ENV DEBIAN_FRONTEND=noninteractive

# ncurses-term supplies the xterm-256color terminfo entry the harness pins TERM to; without
# it tmux falls back and the rendered grid differs. `column` comes from bsdextrautils on
# trixie (it moved out of bsdmainutils), and fleet.sh shells out to it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl gawk git jq less procps sed tar xz-utils \
      ncurses-base ncurses-bin ncurses-term bsdextrautils \
      libevent-dev libncurses-dev bison pkg-config make gcc \
    && rm -rf /var/lib/apt/lists/*

# tmux from source. Debian trixie ships 3.5a; the author's machine runs 3.7b, and floating
# panes only exist from 3.7. Release tarballs ship a generated ./configure, so no autogen.
RUN curl -fsSL -o /tmp/tmux.tar.gz \
      "https://github.com/tmux/tmux/releases/download/${TMUX_REF}/tmux-${TMUX_REF}.tar.gz" \
    && tar xf /tmp/tmux.tar.gz -C /tmp \
    && cd "/tmp/tmux-${TMUX_REF}" \
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
# having to install a linter. shellcheck ships a static binary; shfmt is a single Go binary.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) sc_arch=x86_64; sh_arch=amd64 ;; \
         arm64) sc_arch=aarch64; sh_arch=arm64 ;; \
         *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/sc.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_REF}/shellcheck-${SHELLCHECK_REF}.linux.${sc_arch}.tar.xz" \
    && tar xf /tmp/sc.tar.xz -C /tmp \
    && install -m 0755 "/tmp/shellcheck-${SHELLCHECK_REF}/shellcheck" /usr/local/bin/shellcheck \
    && curl -fsSL -o /usr/local/bin/shfmt \
      "https://github.com/mvdan/sh/releases/download/${SHFMT_REF}/shfmt_${SHFMT_REF}_linux_${sh_arch}" \
    && chmod 0755 /usr/local/bin/shfmt \
    && rm -rf /tmp/sc.tar.xz "/tmp/shellcheck-${SHELLCHECK_REF}" \
    && shellcheck --version | grep version: \
    && shfmt --version

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
