# The disposable machine the tests run on, and the one toolchain CI has: every tests.yml job that
# runs tests (fast, ui, rust, notes, lint) runs in this image through tests/docker.sh, so a runner
# needs only docker and a label (~/.local/src/docs/ci.md). A tool a test needs goes here, never in
# a workflow step (tests/unit/ci_gate.bats).
#
# Why the ui tier needs a disposable machine:
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

# shellcheck is pinned, and that is not fussiness: a new shellcheck release finds new
# things, so an unpinned lint gate goes red on a repo nobody touched. Bumping it is a
# deliberate, reviewable diff -- which is also when the severity ratchet gets revisited.
# It comes from the project's official image (a static binary at /bin, amd64 and arm64),
# pinned by digest, from the registry the base image already needs. Not the GitHub release
# asset: that one can answer 504 for longer than any curl retry waits.
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck

FROM debian:trixie-slim

# Pinned so a CI run and a laptop run agree, and so a distro bump cannot silently change
# what is under test. Override to sweep versions:
#   docker build --build-arg TMUX_REF=3.4 ...
# TMUX_STOCK=1 leaves 3.8 unpatched, for a regression test's negative control.
ARG TMUX_REF=3.8
ARG TMUX_STOCK=
ARG FZF_REF=0.74.1
# tests/rust-toolchain and the phone harness's playwright-core, passed by tests/docker.sh, which
# hashes them into the tag. No default: the build context cannot read the repo's pin.
ARG RUST_TOOLCHAIN
ARG PLAYWRIGHT_CORE

ENV DEBIAN_FRONTEND=noninteractive

# ncurses-term supplies the xterm-256color terminfo entry the harness pins TERM to; without
# it tmux falls back and the rendered grid differs. `column` comes from bsdextrautils on
# trixie (it moved out of bsdmainutils), and fleet.sh shells out to it.
# nodejs runs tab_keeper.bats (`node --test`); openssl and xxd sign release-state's store JWTs.
# lua5.4 loads the Hyprland Lua config for helpers/hypr-lua-dump.lua.
# inotify-tools: agent-ask wait-delivered, the questions panel's wait for an answer to go out.
# neovim: notes_mobile.bats, where the phone launcher switches its running editor to today.
# parallel lets the unit and integ tiers run with bats --jobs (tests/Makefile FAST_PAR).
# sqlite3: session_outcomes.bats builds a fixture opencode DB. stow: dotfiles_deploy.bats checks
# its links against stow itself. npm installs the phone harness's playwright-core and the
# tilecast checker (tests/agent-web). unzip unpacks bun.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl gawk git jq less procps sed tar xz-utils unzip \
      ncurses-base ncurses-bin ncurses-term bsdextrautils \
      libevent-dev libncurses-dev bison pkg-config make gcc \
      python3 python3-yaml sqlite3 nodejs npm openssl xxd lua5.4 inotify-tools neovim parallel stow \
    && rm -rf /var/lib/apt/lists/*

# The downloads below (bun, tmux, fzf) go to GitHub's release CDN, which answers a 504 now and then,
# and a cold build (any change to what tests/docker.sh hashes) downloads them again. curl reads
# this file, so the retry lives in one place and each download keeps its plain `curl -fsSL`.
RUN printf 'retry = 8\nretry-delay = 15\nretry-all-errors\n' > /root/.curlrc

# python3 + PyYAML are RUNTIME dependencies of a subject, not build tools:
# sentinel-manifest parses and validates watch manifests with them. Without python3 the
# whole `sentinel_manifest` suite fails with `env: 'python3': No such file or directory`;
# with python3 but no PyYAML it fails with the subject's own honest refusal,
# `sentinel-manifest: PyYAML is required`. Both were red; both are fixed here.

# bun runs the hunk extensions' TypeScript tests (unit/hunk_*.bats), which skip without it off CI
# and fail without it on CI. Pinned by version and each zip's sha256 (bump all three), so a new
# bun cannot turn the gate red on a repo nobody touched.
ARG BUN_VERSION=1.4.5
RUN case "$(dpkg --print-architecture)" in \
      amd64) zip=bun-linux-x64 sha=94559b3b528995a49452f9f2404cec74f2efd7d06e0a000a8cd214b02c3666eb ;; \
      arm64) zip=bun-linux-aarch64 sha=18656a3bf0ea5641f5796ae4213b75255579a70a0fded2f337933785568cdf84 ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${zip}.zip" \
    && echo "$sha  /tmp/bun.zip" | sha256sum -c - \
    && unzip -q /tmp/bun.zip -d /tmp && install -m 755 "/tmp/${zip}/bun" /usr/local/bin/bun \
    && rm -rf /tmp/bun.zip "/tmp/${zip}" \
    && bun --version

# Rust at tests/rust-toolchain, with clippy and rustfmt: the rust job, the notes job's notes build
# and the ui tier's agent-panel build. rustup-init is pinned by version and sha256. Before tmux, so
# a TMUX_REF sweep reuses this layer. World-writable, like the official rust image, because the
# container runs as the host's UID; tests/docker.sh points CARGO_HOME at /work/.cargo-ci, so the
# registry lands in the checkout where CI's cache step saves it.
ARG RUSTUP_VERSION=1.29.3
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN : "${RUST_TOOLCHAIN:?build through tests/docker.sh, which passes tests/rust-toolchain}" \
    && case "$(dpkg --print-architecture)" in \
      amd64) t=x86_64 sha=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55 ;; \
      arm64) t=aarch64 sha=9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282 ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${t}-unknown-linux-gnu/rustup-init" \
    && echo "$sha  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y -q --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN" -c clippy,rustfmt \
    && rm /tmp/rustup-init \
    && chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME" \
    && cargo --version && cargo clippy --version && cargo fmt --version

# The phone render harness (tests/agent-web/phone/render.mjs): playwright-core at the pinned
# version and the chromium it names, with chromium's system libraries (--with-deps, as root here).
# render.mjs finds playwright-core by PLAYWRIGHT_CORE_DIR and the browser by PLAYWRIGHT_BROWSERS_PATH.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PLAYWRIGHT_CORE_DIR=/opt/agent-web-phone/node_modules/playwright-core
RUN : "${PLAYWRIGHT_CORE:?build through tests/docker.sh, which passes the playwright-core pin}" \
    && npm install --silent --no-save --no-package-lock --no-audit --no-fund --prefix /opt/agent-web-phone "playwright-core@${PLAYWRIGHT_CORE}" \
    && node "$PLAYWRIGHT_CORE_DIR/cli.js" install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# tmux and fzf go in /opt/ui/bin, which only the ui tier puts on PATH (tests/Makefile
# test-ui-inner): the unit and integ tiers must not need either, since they drive subjects through
# the fake tmux stub, and a test that reaches for a real binary goes red in the fast job.
#
# tmux from source. Debian trixie ships 3.5a, the mac-mini 3.6a (stock, like every version but
# 3.8); the author's machine runs 3.8 with the patch in
# .local/src/tmux/patched, which is this image's build context, so what is tested is what runs.
# Floating panes only exist from 3.7. Release tarballs ship a generated ./configure, so no
# autogen; `git apply` keeps the source's timestamps from asking for one.
COPY tree-mode-self-kill.patch /tmp/tree-mode-self-kill.patch
RUN curl -fsSL -o /tmp/tmux.tar.gz \
      "https://github.com/tmux/tmux/releases/download/${TMUX_REF}/tmux-${TMUX_REF}.tar.gz" \
    && tar xf /tmp/tmux.tar.gz -C /tmp \
    && cd "/tmp/tmux-${TMUX_REF}" \
    && if [ "$TMUX_REF" = 3.8 ] && [ -z "$TMUX_STOCK" ]; then git apply --whitespace=nowarn /tmp/tree-mode-self-kill.patch; fi \
    && ./configure --prefix=/opt/ui \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/tmux* \
    && /opt/ui/bin/tmux -V

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
    && tar xf /tmp/fzf.tar.gz -C /opt/ui/bin fzf \
    && rm -f /tmp/fzf.tar.gz \
    && /opt/ui/bin/fzf --version

# shellcheck, so `tests/docker.sh lint` runs the exact gate CI runs without anyone
# having to install a linter.
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
RUN shellcheck --version | grep version:

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
