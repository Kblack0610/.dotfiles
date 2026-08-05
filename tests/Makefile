# Test suite for the tmux cockpit surfaces.
#
# Three tiers, cheapest first:
#   unit   sourced bash functions, no subprocess          ~1s   host-safe
#   integ  the `$SELF --verb` contract, as a subprocess    ~5s   host-safe
#   ui     driven through a real tmux server               ~1-2min  CONTAINER ONLY
#
# The first two tiers never start a tmux server, so they run anywhere -- they are what the
# stop-hook gates on. The ui tier starts real servers and sends real keys, so it runs ONLY
# inside the disposable container (see Dockerfile for the full why: env-var isolation in
# tmux fails silently, and a stray kill-server on a real machine takes out live sessions).
# `make test-ui` therefore delegates to docker.sh rather than running bats directly.
#
# tmux tests are NOT parallel-safe: upstream tmux sets `.NOTPARALLEL: all` on its own
# regress suite for the same reason. Only the unit tier may use `bats --jobs`.
.NOTPARALLEL:

SHELL     := /bin/bash
HERE      := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
VENDOR    := $(HERE)vendor
BATS      := $(VENDOR)/bats-core/bin/bats
ARTIFACTS := $(HERE)artifacts

# Pinned so a CI run and a laptop run agree.
BATS_REF    := v1.12.0
SUPPORT_REF := v0.3.0
ASSERT_REF  := v2.1.0

BATS_FLAGS ?= --print-output-on-failure --timing

# Wall-clock cap for the ui tier (seconds). Generous enough for a cold container on a slow
# runner, short enough that a blocked test fails the job instead of hanging it.
UI_TIMEOUT  ?= 420

.PHONY: test test-fast test-unit test-integ test-ui test-ui-inner test-container \
        test-docker lint fmt corpus-check bootstrap clean clean-vendor help

help:
	@echo "make bootstrap    vendor bats-core + helpers (once)"
	@echo ""
	@echo "host-safe (no tmux server started):"
	@echo "  make test-fast    unit + integ            <- stop-hook gate"
	@echo "  make test-unit    sourced-function tests"
	@echo "  make test-integ   --verb contract tests"
	@echo "  make lint         shellcheck + shfmt + house rules over tracked shell scripts"
	@echo "  make corpus-check ADVISORY: do the board fixtures still match ~/.agent/plans?"
	@echo ""
	@echo "container-only (real tmux servers; NEVER runs on this machine):"
	@echo "  make test-ui      the tmux ui tier, inside docker"
	@echo "  make test-docker  the whole suite inside docker"
	@echo "  make test         test-fast here, then test-ui in docker"
	@echo ""
	@echo "  ./docker.sh --shell   interactive shell in the test image"

bootstrap: $(BATS)
$(BATS):
	@mkdir -p $(VENDOR)
	@echo "==> vendoring bats-core $(BATS_REF) + helpers into tests/vendor"
	@git clone --quiet --depth 1 --branch $(BATS_REF) \
		https://github.com/bats-core/bats-core.git      $(VENDOR)/bats-core
	@git clone --quiet --depth 1 --branch $(SUPPORT_REF) \
		https://github.com/bats-core/bats-support.git   $(VENDOR)/bats-support
	@git clone --quiet --depth 1 --branch $(ASSERT_REF) \
		https://github.com/bats-core/bats-assert.git    $(VENDOR)/bats-assert
	@echo "==> ok: $$($(BATS) --version)"

test: test-fast test-ui

test-fast: test-unit test-integ

test-unit: $(BATS)
	@$(BATS) $(BATS_FLAGS) $(HERE)unit

test-integ: $(BATS)
	@$(BATS) $(BATS_FLAGS) $(HERE)integ

# Host entry point for the ui tier: hand off to the container. Running bats over ui/ on a
# real machine is not a supported path -- require_disposable_host() fails every test there.
test-ui:
	@$(HERE)docker.sh test-ui-inner

test-docker:
	@$(HERE)docker.sh test-container

# The actual ui run. Guarded twice: here for a readable message, and again per-test in
# require_disposable_host() so `bats ui/` typed by hand cannot slip past this Makefile.
test-ui-inner: $(BATS)
	@if [ -z "$$COCKPIT_TEST_DISPOSABLE" ] || [ ! -f /.dockerenv ]; then \
	  echo "REFUSING: the ui tier starts real tmux servers and must not run on this machine."; \
	  echo "          Run 'make -C tests test-ui', which runs it inside the test container."; \
	  exit 1; \
	fi
	@mkdir -p $(ARTIFACTS)
	@# Hard wall-clock cap. bats has no per-test timeout, and a ui test that reaches an
	@# attaching code path (`tmux attach` with no terminal) blocks FOREVER rather than
	@# failing - one such test wedged a run for 10 minutes before it was caught. Without
	@# this a hung test burns the whole CI job and reports nothing useful.
	@timeout --foreground $(UI_TIMEOUT) $(BATS) $(BATS_FLAGS) $(HERE)ui \
	  || { rc=$$?; [ $$rc -eq 124 ] && echo "ui tier TIMED OUT after $(UI_TIMEOUT)s (a test is probably blocked on an attach)" >&2; exit $$rc; }

# What the container's default CMD runs: everything, in one pass.
test-container: test-fast test-ui-inner

# One implementation, in lint.sh, shared with the Stop hook and CI. The severity ratchet and
# the file list both live there, so a local green cannot mean a CI red.
lint:
	@$(HERE)lint.sh

clean:
	@rm -rf $(ARTIFACTS)
	@echo "cleaned $(ARTIFACTS) (vendor/ kept; make clean-vendor to drop it)"

clean-vendor:
	@rm -rf $(VENDOR)

# Advisory drift check, never a gate: it reads LIVE state (~/.agent/plans), which differs
# per machine and is empty in CI. Same precedent as runner_contract.bats reading the real
# agentctl roster -- a fixture corpus can only ever confirm the fixture. Always exits 0;
# read its output.
corpus-check:
	@./corpus-check.sh
