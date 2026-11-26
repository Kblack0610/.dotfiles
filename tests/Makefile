# Test suite for the tmux and shell surfaces.
#
# Three tiers, cheapest first:
#   unit   sourced bash functions, no subprocess          ~1s   host-safe
#   integ  the `$SELF --verb` contract, as a subprocess    ~5s   host-safe
#   ui     driven through a real tmux server               ~1-2min  CONTAINER ONLY
#
# The first two tiers never start a tmux server, so they run anywhere -- they are CI's `fast`
# job (an agent session runs none of this on the workstation). The ui tier starts real servers and sends real keys, so it runs ONLY
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
# Every host-tier run goes through run-bats.sh, which owns the bats run dir and removes it
# however the run ends.
RUN_BATS  := $(HERE)run-bats.sh
ARTIFACTS := $(HERE)artifacts

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
	@echo "  make test-fast    unit + integ, every file (a push to main and the Monday schedule run it; CI shards it: shard.sh)"
	@echo "  make test-files   FILES=... only these (CI's shards call it)"
	@echo "  make test-unit    sourced-function tests"
	@echo "  make test-integ   --verb contract tests"
	@echo "  make lint         shellcheck + house rules over tracked shell scripts"
	@echo "  make test-rust    cargo test/clippy/fmt over the tracked Rust crates (CRATES=<dirs> for some, CLIPPY=0 skips clippy, RUST_JOBS=<n> gates n at once)"
	@echo ""
	@echo "container-only (real tmux servers; NEVER runs on this machine):"
	@echo "  make test-ui      the tmux ui tier, inside docker"
	@echo "  make test-docker  the whole suite inside docker"
	@echo "  make test         test-fast here, then test-ui in docker"
	@echo ""
	@echo "  ./docker.sh --shell   interactive shell in the test image"

bootstrap: $(BATS)
# bootstrap.sh holds the pinned refs and needs no make, so CI and docker.sh call it directly.
$(BATS):
	@$(HERE)bootstrap.sh

test: test-fast test-ui

test-fast: test-unit test-integ

# The unit and integ tiers run their files in parallel when GNU parallel is there (bats needs
# it for --jobs). Integ serial was the full tier's critical path on CI: 308 s and 405 s for two
# shards of 296 s predicted each (run 42983385857), against 5 minutes for the whole gate. Its
# files are as isolated as unit's: helpers/sandbox gives each test its own HOME and TMPDIR under
# BATS_TEST_TMPDIR, and the files that skip the sandbox are stdin-to-stdout hook checks or set
# HOME to that dir themselves; files that register a worktree in the real repo do so at a
# per-test path. Three wall-clock budgets (agent_ask, questions_panel, agentctl_report) run at
# one job per core, so they share a core no more than serially. A test that shares a fixed
# path, a port or setup_file state with another breaks that, and goes red here first.
# Jobs are the cores free now, not every core: on 2026-11-07 three local gates at --jobs 24
# each held a 24-core box at 54% sys and 8% idle, which shut the dispatcher's idle gate for
# every other session (ar-885). Locally that number is `auto`, and run-bats.sh sizes it once
# its slot is granted (unit-jobs.awk, UNIT_LOADAVG: ar-3403): sized here, at parse time, it was
# read before the wait for the slot, and suites released together all forked that many workers.
# On CI (CI set, as GitHub Actions does) the runner is the job's own machine and its load is its
# own setup, which gave a 4-core runner 2 jobs: it gets its cpus (cpus.sh: nproc, held down to the
# cgroup quota or the pod's CPU request, which nproc ignores: 32 jobs in a 370m pod, ar-5586), and
# run-bats.sh takes no slot.
UNIT_JOBS ?= $(if $(CI),$(shell $(HERE)cpus.sh),auto)
FAST_PAR  := $(if $(shell command -v parallel 2>/dev/null),--jobs $(UNIT_JOBS))

test-unit: $(BATS)
	@$(if $(FAST_PAR),echo "==> unit tier: bats $(FAST_PAR)",echo "==> unit tier: serial (no GNU parallel)")
	@$(call junit_mk,unit) $(RUN_BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,unit) $(HERE)unit

test-integ: $(BATS)
	@$(call junit_mk,integ) $(RUN_BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,integ) $(HERE)integ

# CI's entry (one shard.sh shard) and a session's by hand (the files tests/pick.sh picks).
# One bats run over every file, in parallel like test-unit and test-integ, so one report names
# every red.
test-files: $(BATS)
	@$(call junit_mk,files) $(RUN_BATS) $(BATS_FLAGS) $(FAST_PAR) $(call junit,files) $(FILES)

# The local gate: the fast-tier files tests/pick.sh picks for the change from PR_BASE to the
# working tree (untracked files too), the set the PR's CI gate runs. Why: sessions ran the whole
# fast tier, about 4,900 tests, as their gate, several at once, and with the runners off that held
# this 24-core box at load 63 (ar-1652). A change pick.sh cannot scope (the harness) still gets the
# whole tier; no change runs nothing, and a missing base is an error, never a silent full run.
PR_BASE ?= $(shell git -C "$(HERE)" merge-base HEAD origin/main 2>/dev/null)
test-pr: $(BATS)
	@[ -n "$(PR_BASE)" ] || { echo "test-pr: no merge-base with origin/main: git fetch origin, or pass PR_BASE=<rev>" >&2; exit 2; }; \
	diff=$$(git -C "$(HERE).." diff --no-renames --name-only "$(PR_BASE)") || exit 2; \
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
	@# The image keeps tmux and fzf in /opt/ui/bin, off the fast tiers' PATH (tests/Dockerfile).
	@# Hard wall-clock cap. bats has no per-test timeout, and a ui test that reaches an
	@# attaching code path (`tmux attach` with no terminal) blocks FOREVER rather than
	@# failing - one such test wedged a run for 10 minutes before it was caught. Without
	@# this a hung test burns the whole CI job and reports nothing useful.
	@$(call junit_mk,ui) PATH=/opt/ui/bin:$$PATH timeout --foreground $(UI_TIMEOUT) $(BATS) $(BATS_FLAGS) $(call junit,ui) $(HERE)ui \
	  || { rc=$$?; [ $$rc -eq 124 ] && { echo "ui tier TIMED OUT after $(UI_TIMEOUT)s (a test is probably blocked on an attach)" >&2; \
	       $(if $(junit_on),printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="timeout" tests="1" failures="1" errors="0" skipped="0"><testcase classname="ui" name="ui tier timed out after $(UI_TIMEOUT)s"><failure message="timed out; a test is probably blocked on an attach"/></testcase></testsuite></testsuites>\n' >$(call junit_dir,ui)/report.xml;) }; exit $$rc; }

# What the container's default CMD runs: everything, in one pass.
test-container: test-fast test-ui-inner

# One implementation, in lint.sh, shared with CI. The severity ratchet and
# the file list both live there, so a local green cannot mean a CI red.
lint:
	@$(HERE)lint.sh

# The Rust crates (notes-cli, agent-panel, agent-web, timebox). Same shape as `lint`: one
# implementation in rust.sh, shared with CI; its header says which gates block where.
#
# Deliberately NOT part of test-fast or test-container: a cold cargo build is minutes, and the
# rust job runs it beside the bats tiers, in the same image (`tests/docker.sh test-rust`, with
# DOCKER_NETWORK=bridge for the crates). rust.sh skips cleanly where cargo is absent.
test-rust:
	@$(HERE)rust.sh $(CRATES)

clean:
	@rm -rf $(ARTIFACTS)
	@echo "cleaned $(ARTIFACTS) (vendor/ kept; make clean-vendor to drop it)"

clean-vendor:
	@rm -rf $(VENDOR)
