# Test suite for the tmux and shell surfaces.
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
# regress suite for the same reason. Only the two host-safe tiers, which start none, may use
# `bats --jobs` (FAST_PAR below).
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

# JUNIT=1 (CI sets it) makes each bats run also write a JUnit report.xml under
# artifacts/junit/<run>/, which tests.yml uploads and its report job draws per test.
# Any other value, 0 included, leaves it off.
JUNIT ?=
junit_on  = $(filter 1,$(JUNIT))
junit_dir = $(ARTIFACTS)/junit/$(1)
junit     = $(if $(junit_on),--report-formatter junit -o $(call junit_dir,$(1)))
junit_mk  = $(if $(junit_on),mkdir -p $(call junit_dir,$(1)) &&)

# Wall-clock cap for the ui tier (seconds). Generous enough for a cold container on a slow
# runner, short enough that a blocked test fails the job instead of hanging it.
UI_TIMEOUT  ?= 420

.PHONY: test test-fast test-pr test-unit test-integ test-files test-ui test-ui-inner test-container \
        test-docker test-rust lint fmt bootstrap clean clean-vendor help

help:
	@echo "make bootstrap    vendor bats-core + helpers (once)"
	@echo ""
	@echo "host-safe (no tmux server started):"
	@echo "  make test-pr      the files the PR gate picks for this change (PR_BASE=<rev>, default the merge-base with origin/main)"
	@echo "  make test-fast    unit + integ, every file (main and the nightly run it; CI shards it: shard.sh)"
	@echo "  make test-files   FILES=... only these (the stop-hook picks them)"
	@echo "  make test-unit    sourced-function tests"
	@echo "  make test-integ   --verb contract tests"
	@echo "  make lint         shellcheck + shfmt + house rules over tracked shell scripts"
	@echo "  make test-rust    cargo test/clippy/fmt over the tracked Rust crates (CRATES=<dirs> for some)"
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

# The unit and integ tiers run their files in parallel when GNU parallel is there (bats needs
# it for --jobs). Integ serial was the full tier's critical path on CI: 308 s and 405 s for two
# shards of 296 s predicted each (run 42983385857), against 5 minutes for the whole gate. Its
# files are as isolated as unit's: helpers/sandbox gives each test its own HOME and TMPDIR under
# BATS_TEST_TMPDIR, and the files that skip the sandbox are stdin-to-stdout hook checks or set
# HOME to that dir themselves; shell_tests_scope.bats registers a worktree in the real repo at a
# per-test path. Three wall-clock budgets (agent_ask, questions_panel, agentctl_report) run at
# one job per core, so they share a core no more than serially. A test that shares a fixed
# path, a port or setup_file state with another breaks that, and goes red here first.
# Jobs are the cores free now, not every core: on 2026-11-07 three local gates at --jobs 24
# each held a 24-core box at 54% sys and 8% idle, which shut the dispatcher's idle gate for
# every other session (ar-885). Busy is the larger of the 1-minute load and the processes
# running this instant (field 4 of /proc/loadavg, less this one), because the average lags
# a minute and gates started together would all read it low. Free is nproc minus busy,
# rounded, floor 2. UNIT_LOADAVG is the load source, a file in /proc/loadavg's format; a
# missing or empty one gives 2. On CI (CI set, as GitHub Actions does) the runner is the job's
# own machine and its load is its own setup, which gave a 4-core runner 2 jobs: it gets nproc.
UNIT_LOADAVG ?= /proc/loadavg
UNIT_JOBS ?= $(if $(CI),$(shell nproc 2>/dev/null || echo 2),$(shell awk -v c="$$(nproc 2>/dev/null || echo 2)" -f $(HERE)unit-jobs.awk $(UNIT_LOADAVG) 2>/dev/null || echo 2))
FAST_PAR  := $(if $(shell command -v parallel 2>/dev/null),--jobs $(UNIT_JOBS))

test-unit: $(BATS)
	@$(if $(FAST_PAR),echo "==> unit tier: bats $(FAST_PAR)",echo "==> unit tier: serial (no GNU parallel)")
	@$(call junit_mk,unit) $(BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,unit) $(HERE)unit

test-integ: $(BATS)
	@$(call junit_mk,integ) $(BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,integ) $(HERE)integ

# The Stop hook's entry (the files 60-shell-tests.sh picked for the change) and CI's (one shard.sh shard).
# One bats run over every file, in parallel like test-unit and test-integ, so one report names
# every red.
test-files: $(BATS)
	@$(call junit_mk,files) $(BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,files) $(FILES)

# The local gate: the fast-tier files tests/pick.sh picks for the change from PR_BASE to the
# working tree (untracked files too), the set the PR's CI gate runs. Why: sessions ran the whole
# fast tier, about 4,900 tests, as their gate, several at once, and with the runners off that held
# this 24-core box at load 63 (ar-1652). A change pick.sh cannot scope (the harness) still gets the
# whole tier; no change runs nothing, and a missing base is an error, never a silent full run.
PR_BASE ?= $(shell git -C "$(HERE)" merge-base HEAD origin/main 2>/dev/null)
test-pr: $(BATS)
	@[ -n "$(PR_BASE)" ] || { echo "test-pr: no merge-base with origin/main: git fetch origin, or pass PR_BASE=<rev>" >&2; exit 2; }; \
	diff=$$(git -C "$(HERE).." diff --name-only "$(PR_BASE)") || exit 2; \
	new=$$(git -C "$(HERE).." ls-files --others --exclude-standard) || exit 2; \
	changed=$$(printf '%s\n%s\n' "$$diff" "$$new" | grep . | sort -u); \
	[ -n "$$changed" ] || { echo "test-pr: no change against $(PR_BASE)"; exit 0; }; \
	files=$$(for t in unit integ; do PICK_CHANGED="$$changed" "$(HERE)pick.sh" $$t "$(PR_BASE)" || exit 1; done) || exit 1; \
	[ -n "$$files" ] || { echo "test-pr: no fast-tier file picked"; exit 0; }; \
	$(MAKE) --no-print-directory -C "$(HERE)" test-files FILES="$$(sed 's|^|$(HERE)|' <<<"$$files" | tr '\n' ' ')"

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
	@$(call junit_mk,ui) timeout --foreground $(UI_TIMEOUT) $(BATS) $(BATS_FLAGS) $(call junit,ui) $(HERE)ui \
	  || { rc=$$?; [ $$rc -eq 124 ] && { echo "ui tier TIMED OUT after $(UI_TIMEOUT)s (a test is probably blocked on an attach)" >&2; \
	       $(if $(junit_on),printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="timeout" tests="1" failures="1" errors="0" skipped="0"><testcase classname="ui" name="ui tier timed out after $(UI_TIMEOUT)s"><failure message="timed out; a test is probably blocked on an attach"/></testcase></testsuite></testsuites>\n' >$(call junit_dir,ui)/report.xml;) }; exit $$rc; }

# What the container's default CMD runs: everything, in one pass.
test-container: test-fast test-ui-inner

# One implementation, in lint.sh, shared with CI. The severity ratchet and
# the file list both live there, so a local green cannot mean a CI red.
lint:
	@$(HERE)lint.sh

# The Rust crates (notes-cli, agent-panel, agent-web, timebox). Same shape as `lint`: one
# implementation in rust.sh, shared with CI, carrying its own ratchet.
#
# Deliberately NOT part of test-fast. test-fast is the Stop-hook gate and is measured in
# seconds; a cold cargo build is ~20s and would tax every single turn. It is also
# deliberately not part of test-container -- the test image has no Rust toolchain, and
# rust.sh skips cleanly when cargo is absent rather than going red on that.
test-rust:
	@$(HERE)rust.sh $(CRATES)

clean:
	@rm -rf $(ARTIFACTS)
	@echo "cleaned $(ARTIFACTS) (vendor/ kept; make clean-vendor to drop it)"

clean-vendor:
	@rm -rf $(VENDOR)
