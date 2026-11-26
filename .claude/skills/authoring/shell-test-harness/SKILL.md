---
name: shell-test-harness
description: >-
  Test a dotfiles shell or TUI surface: three-tier bats suite, a negative control, ui tier only in the container. Use for "add tests for X", "is X tested", "harness this", or before landing shell work.
metadata:
  category: authoring
  tags: [testing, shell, bats, dotfiles]
  system: [tests]
  reviewed: "2026-11-23"
  # The local test runs CI replaces; hand_methods.py denies them in an agent session (a human
  # terminal never reaches the hook). The four rows share one command-position prefix (after a
  # separator, a shell, sudo, xargs, a loop or if keyword, or VAR=x): change all four together.
  replaces:
    - match: |-
        (?:^|[;&|(){}`\n!])\s*(?:(?:sudo(?:\s+-\S+)*|nice(?:\s+-n\s*\S+)?|time|env|exec|command|xargs(?:\s+-\S+)*|timeout\s+\S+|(?:ba|z|da)?sh(?:\s+-\S+)*|do|then|else|if|while|until|!|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*(?:\S*/)?g?make(?=\s)[^;&|()`\n]{0,300}?\s(?:test(?:-[\w-]+)?|lint)(?=[\s;&|)]|$)
      use: &ci "push the branch and let the PR's CI run it: `shell tests` runs what `tests/pick.sh` picks (`tests/pick.sh unit origin/main`, and `integ`, lists them without running; the picks are on the run's Summary page), `rust` the crates, `lint` the lint, and agent-land waits for those checks. A negative control is a pushed commit that breaks the subject, read red in CI, then reverted (shell-test-harness section 3)"
      mode: deny
      where: &dotfiles '(?:^|/)(?:\.dotfiles|\.worktrees/dotfiles-(?!private-)[^/]+)(?:/|$)'
      why: &load "agent test runs held the workstation at load 40 on 28 cores, about 500% CPU of bats in dotfiles worktrees, which holds dispatch (2026-11-23, epic ar-4846); CI runs the same files off it"
    - match: |-
        (?:^|[;&|(){}`\n!])\s*(?:(?:sudo(?:\s+-\S+)*|nice(?:\s+-n\s*\S+)?|time|env|exec|command|xargs(?:\s+-\S+)*|timeout\s+\S+|(?:ba|z|da)?sh(?:\s+-\S+)*|do|then|else|if|while|until|!|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*(?:\S*/)?(?:bats|run-bats\.sh|docker\.sh|rust\.sh|rust-crates\.sh|lint\.sh|lint-files\.sh|fleet-agent-smoke\.sh)(?=[\s;&|)]|$)
      use: *ci
      mode: deny
      where: *dotfiles
      why: *load
    - match: |-
        (?:^|[;&|(){}`\n!])\s*(?:(?:sudo(?:\s+-\S+)*|nice(?:\s+-n\s*\S+)?|time|env|exec|command|xargs(?:\s+-\S+)*|timeout\s+\S+|(?:ba|z|da)?sh(?:\s+-\S+)*|do|then|else|if|while|until|!|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*(?:\S*/)?cargo(?=\s)[^;&|()`\n]{0,200}?\s(?:test|nextest)(?=[\s;&|)]|$)
      use: *ci
      mode: deny
      where: *dotfiles
      why: *load
    # From any cwd: a dotfiles tests path named in the command (`make -C ~/.dotfiles/tests`, the
    # suite scripts by path, or a `cd` into a dotfiles checkout before the run).
    - match: |-
        (?:^|[;&|(){}`\n!])\s*(?:(?:sudo(?:\s+-\S+)*|nice(?:\s+-n\s*\S+)?|time|env|exec|command|xargs(?:\s+-\S+)*|timeout\s+\S+|(?:ba|z|da)?sh(?:\s+-\S+)*|do|then|else|if|while|until|!|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*(?:(?:\S*/)?g?make(?=\s)[^;&|()`\n]{0,300}?\s-C\s*\S*(?:\.dotfiles|\.worktrees/dotfiles-(?!private-)[^/\s]+)/tests/?\s[^;&|()`\n]{0,300}?(?<=\s)(?:test(?:-[\w-]+)?|lint)(?=[\s;&|)]|$)|\S*(?:\.dotfiles|\.worktrees/dotfiles-(?!private-)[^/\s]+)/tests/(?:vendor/bats-core/bin/bats|run-bats\.sh|docker\.sh|rust\.sh|rust-crates\.sh|lint\.sh|lint-files\.sh|fleet-agent-smoke\.sh)(?=[\s;&|)]|$)|cd\s+\S*(?:\.dotfiles|\.worktrees/dotfiles-(?!private-)[^/\s]+)\S*\s*(?:&&|;)\s*(?:\S*/)?(?:g?make(?=\s)[^;&|()`\n]{0,300}?\s(?:test(?:-[\w-]+)?|lint)|(?:\S*/)?(?:bats|run-bats\.sh)|cargo(?=\s)[^;&|()`\n]{0,200}?\s(?:test|nextest))(?=[\s;&|)]|$))
      use: *ci
      mode: deny
      why: *load
---

# shell-test-harness

How shell work gets tested and landed in this repo. The suite lives in `tests/`; this is the procedure around it.

The founding incident: writing the tmux UI tests destroyed every live tmux session on this machine, twice in one evening. Not because the test code was careless, but because the tests could *reach* the user's sessions at all. Everything below follows from that.

```
    pick a tier  ->  write the test  ->  push  ->  WATCH IT FAIL in CI  ->  CI green  ->  land
                          |                              |
                   host-safe or                    negative control
                   container-only?                   (not optional)
```

**CI is the gate, and the only place an agent session runs a test.** The PR's CI run of what `tests/pick.sh` picks is the test run; nothing runs on the workstation first. The forms that would run one here (`make -C tests test-*` and `lint`, `tests/run-bats.sh`, a direct `bats`, `tests/docker.sh`, `tests/rust.sh`, `cargo test`) are this skill's `metadata.replaces` rows, which `hand_methods.py` denies in an agent session inside a dotfiles checkout; a human's own terminal never reaches the hook. Why: on 2026-11-23 agent test runs held the workstation at load 40 on 28 cores (about 500% CPU of bats), which held dispatch, while CI already ran the same files (epic ar-4846). `tests/pick.sh unit origin/main` (and `integ`, `rust`) prints what the PR will pick without running it.

## Scope and triggers

Test a shell or TUI surface in this repo correctly, then land it. Covers the three-tier bats suite in `tests/` (unit = sourced functions, integ = the `$SELF --verb` contract, ui = a REAL tmux server), the hard rule that anything starting a real server/daemon runs ONLY in the disposable container, the mandatory negative control (a test that cannot fail is not a test), and the pre-flight checks that stop you clobbering a concurrent session. Use when adding or changing any script under `.local/src/tmux/`, `.local/bin/`, `.config/shared-hooks/`, or a stop-hook check; when asked to "add tests for X", "is X tested", "harness this", "make sure this is tested properly"; or before landing shell work. Do NOT run the ui tier on this machine (it starts real tmux servers and has destroyed live sessions), do NOT trust `TMUX_TMPDIR` or `command tmux` as isolation, do NOT let a gate report success on an empty input list, and do NOT claim a test works until you have watched it fail. Hands landing off to ingest-prs (its Dirty working tree section fans a dirty tree into PRs) and dotfiles-land (public/private routing).

## 0. Pre-flight: are you alone in this checkout?

Several agent sessions share `~/.dotfiles`. Skipping this has already cost a session's work.

```bash
git worktree list          # another session's worktree? a `+` marks a checked-out branch
git branch --show-current  # are you even on the branch you think?
git status --short         # is this dirt yours?
git fetch origin && git log --oneline HEAD..origin/main   # how stale are you?
```

If the shared checkout is busy, or you are about to make a multi-step change, **take a worktree** (the convention other sessions already follow):

```bash
wt new                    # cuts it under ~/.worktrees/, opens a tmux session, lands you there
```

Every worktree lives flat under `~/.worktrees/<repo>-<slug>` - never in `$SCRATCH`, never nested in the repo. If you need raw git rather than `wt`, keep the location and fetch first:

```bash
git fetch origin && git worktree add ~/.worktrees/dotfiles-<name> -b pr/<name> origin/main
```

Restore anything you touched in the shared tree **before** leaving it. Re-`fetch` immediately before each landing step, not once at the start - `origin/main` moved three times during one session, and two planned PRs turned out to be work someone else had already landed. `wt done` from inside the worktree reaps it when the work has landed.

Container caveat: inside a worktree `.git` is a *file* pointing at the main repo, so `tests/docker.sh` mounts the main `.git` read-only. That is already handled; do not fight it.

## 1. Pick a tier

| Tier | What it tests | Runs where | Cost |
|---|---|---|---|
| `unit` | sourced functions, no subprocess | anywhere | ~1s |
| `integ` | the `$SELF --verb` contract, as a subprocess, against stub CLIs | anywhere | ~3s |
| `ui` | a REAL tmux server, real keystrokes, rendered screen | **container only** | ~20s |

Choose by what the thing under test *is*:

- **Pure logic** (parse a row, map a tag to an option, classify a pane) -> `unit`. Needs a source guard in the subject: `[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0` above the dispatch. Add it if missing.
- **A verb's output shape** (`--list` emits 7 tab-separated fields; `--task-op done` shells out to the right command) -> `integ`, using the stubs in `tests/helpers/stubs/`.
- **A test needs its own `gh` or `tmux` answers** -> `gh_script` / `tmux_script` (`tests/helpers/sandbox.bash`): the body is sourced by the shared stub in place of its canned answers. In the unit and integ tiers never write a second `gh` or `tmux` into `$SANDBOX/bin` (the ui tier's `tmux_harness.bash` shim is the one exception).
- **State that IS tmux state** (a window option, a session's existence, what a keypress renders) -> `ui`. There is nothing to assert against a stub here: faking `set-option`/`show-options` only tests the fake.

Prefer the cheapest tier that can actually fail. The suite caught a real routing bug in a 40ms unit test.

## 2. THE CONTAINER RULE

**Anything that starts a real server, daemon, or long-lived process runs only inside `tests/Dockerfile`'s image. Never on this machine.**

`require_disposable_host()` enforces it: it **fails** (never skips - a skip is how a safety tier quietly stops running) unless `/.dockerenv` *and* an image-set env marker are both present. There is deliberately **no override flag**.

The suite's entry points, which CI calls and a human may run in their own terminal (an agent session pushes instead):

```bash
make -C tests test-pr       # the files the PR gate picks for this change
make -C tests test-fast     # unit + integ, every file: main and the nightly run it
make -C tests test-ui       # delegates to docker.sh; never invokes tmux on the host
tests/docker.sh test-container   # everything, in the container
tests/docker.sh lint            # the lint gate, same one CI runs
```

Two "isolation" mechanisms that **do not work** - verified on tmux 3.7b, do not re-derive:

- `TMUX_TMPDIR=<sandbox>` is **ignored whenever `$TMUX` is set** (i.e. whenever you are inside tmux, which is exactly when you work on tmux scripts), and silently falls back to `/tmp` if the directory does not exist.
- `command tmux` still honours `PATH`, so it finds a stub instead of bypassing one.

Only an explicit `-S <path>` / `-L <name>` **flag** isolates a tmux server. That is why the harness installs a PATH shim pinning `-S` (`tmux_shim`) - it covers the *subject's* bare `tmux` calls too, which is the only way to test a script that must keep calling `tmux` plainly.

Exception, and the only one: a subject whose whole job is managing several servers (`servers.sh`) must keep calling `tmux -L` itself. Use `tmux_passthrough_shim`; isolation is then `TMUX_TMPDIR` **plus** the container, which is sound there because the container has no `$TMUX` and nothing to lose. Never on a real machine.

**Never execute a destructive command to verify the guard that prevents it.** Assert on the guard's *decision* (make it print what it would do), not the outcome of doing it. Running `tmux kill-server` to check whether it was safe to run `tmux kill-server` is what caused the second outage.

## 3. Write the negative control. Not optional.

A test that has never failed is a guess. For every behaviour you claim to cover, break the subject and confirm the test notices. CI is where it runs:

```bash
# invert a binding / transpose two verbs / drop a field / rename a constant, in the subject only
git commit -m "test: negative control, breaks <subject>" <subject> && git push
gh pr checks <N>              # it MUST go red, and the run's Summary must name the right case
git revert --no-edit HEAD && git push   # the PR's next run is green again
```

Do it before `agent-land`, never during it: a PR head that is red while you work on it is normal, and `agent-land` waits only on the head it lands, the revert's green run. A break that needs the test and the subject changed together goes in the same commit and the same revert. The PR body names the red run as the proof. A guard's own close-but-wrong inputs (a quoted phrase, a near-miss path) go in the test as allow cases beside the deny ones, so that half of the control runs in every CI run.

This is not ceremony. Real results from doing it:

- 7 direction assertions were **passing while asserting nothing** - the fixture had 2 sections, so `next` and `prev` were the same operation. Fixed by adding a third and asserting the *exact* landing element.
- Inverting `h`/`l` -> 3 ui tests fail. Transposing the section verbs -> 4 integ tests fail in 53ms. Dropping a wire-format field -> 17 tests fail. Collapsing every tmux world onto one socket -> 10 ui tests fail.

**Rule of three for anything cyclic or ordered**: a fixture needs 3 or more elements, and the assertion must name the expected element. With 2, forwards and backwards are indistinguishable.

## 4. Gate hygiene: silence is not success

Every failure mode in this repo's tooling has been *silent success*. Watch for it:

- A gate that derives its input list at runtime must treat an **empty list as failure**. `tests/lint.sh` once reported "clean" having checked zero files, because `git ls-files` failed. "Nothing to check" and "everything passed" print the same green.
- A **skip** in a safety tier is how it quietly stops running. Fail instead.
- After writing a config key, **prove something reads it** - change the value and observe different behaviour. `severity=` in `.shellcheckrc` is silently ignored (it is CLI-only), so the lint gate looked configured while every warning still failed the run.
- Any suite driving an interactive tool needs a **wall-clock cap** (`UI_TIMEOUT`). bats has no per-test timeout, and a test that reaches an attach path (`tmux attach` with no terminal) blocks *forever* rather than failing - one wedged a run for 10 minutes and reported nothing.
- Before asserting "unknown verb is rejected", read the dispatch's **default arm**. A catch-all that treats the word as *data* is not an error path: in `tmx` a bare word is a server name, so `tmx not-a-verb` is a valid request that attaches and hangs.

## 5. Run the gates

The gate is the PR's CI: push, and `agent-land` waits for the `gate` check, which is red unless every job ran and passed. Nothing runs on the host first.

The lint ratchet lives in `tests/lint.sh` (`SEVERITY`, currently `error`), shared by make and CI so a local green cannot mean a CI red. Move it one notch per PR - `error -> warning -> info -> style` - and re-measure before each step; do not jump to `style`, that is a permanently red check nobody reads.

CI (`.github/workflows/tests.yml`), under the doctrine in `~/.local/src/docs/ci.md`; this repo's PR budget is a p90 of 5 minutes, and each job's own `timeout-minutes` in `tests.yml` is its hang guard, never a lever. Every job runs where the repo variable `LINUX_RUNNER_LIGHT` says, by the human's decision (2026-11-23, ar-5018, after the account sat at its hosted parallel-job cap with 105 jobs queued): set to `["self-hosted","light"]` it is the home pool, whose runners need only docker; deleted (`gh variable delete LINUX_RUNNER_LIGHT -R Kblack0610/.dotfiles`) it is GitHub-hosted `ubuntu-24.04`, free on this public repo. A fork's PR always runs hosted, since a pool runner would run a stranger's code on the LAN, and `fleet-agent.yml` stays hosted because it frees disk with sudo; the `runs-on` is written once, as the YAML anchor `&pool` on the first job, and every other job is `*pool`. Every job's tools come from the one test image (`tests/Dockerfile`, cached by `.github/actions/test-image`), so a `tests.yml` step never installs a tool on the runner or asks which runner it is on (`tests/unit/ci_gate.bats` checks the installs). The variable stays unset until the pool's online `.dotfiles` seats cover the peak-hour demand, which is the not-cancelled `tests.yml` runs in the busiest hour of the last 24h times the job-minutes a run takes (the sum of its jobs' started-to-completed time), divided by 60. Measure that before setting it. On 2026-11-24 UTC (ar-5033) the demand was about 42 seats against 3 online and 9 at most, and the numbers are in the plan `ck-report-only-draws-nested-owl` Results.
- `fast` on the runner. A pull request runs what `tests/pick.sh` picks (the `test_picked` function in `.local/lib/test-pick.sh`) plus `tests/broad.txt`; main, the schedule and a dispatch run the whole tier, and so does a PR that touches the harness or whose diff cannot be read. The pick line ("picked N of M" or "full: <why>") is on the run's Summary page. A PR green and main red means the picker missed a dependency: teach `test_picked` it, with a case in `tests/unit/test_pick.bats`.
- `tests/shard.sh` splits the files across the matrix by the per-file seconds the `weights` job reads from the newest green main run's JUnit (`shard.sh --junit`), so there is no table to regenerate. Each shard writes its predicted and actual seconds to the Summary. A shard near its cap: split its heaviest file in two (a file never spans shards, and a shard spends about 4 minutes on image pull and start before bats, so no file may weigh past about 220 s): the second half is `<file>_part2.bats`, its setup in a `common.bash` both load, with `# shard-seconds: N` in its first lines until main's table lists it; or add a shard: raise the tier's `FAST_SHARDS` in the weights job env (`shard.sh --matrix` sizes the matrix from the pick, one shard per `SHARD_SECONDS`, and `unit/shard.bats` rejects a hand-listed shard).
- The image has three stages, `lean` (the tmux-free tiers and lint) -> `rust` (the notes job) -> `full` (ui, rust and every local run), and each job's env `TEST_IMAGE_KIND` in `tests.yml` names the smallest one with what it runs (`unit/ci_gate.bats` checks the list). Why: a pool pod has its own docker daemon, so every job restores its image from the Actions cache, and with dozens of pods at once that ran at about 2.5 MB/s: the 943 MB image timed out every job in the restore on 2026-11-25 (ar-5632). A tool goes in the earliest stage whose jobs need it; a new job names its kind. A pool runner now pulls the image from the LAN registry (hc-1067, home-config `apps/ci-registry`, the push store with login) when the `CI_REGISTRY_PASSWORD` secret and `CI_REGISTRY` variable are set, and a pull that fails fails the job within about 6 minutes, with no cache restore or build behind it (ar-5959); hosted runners cannot reach the registry and restore from the cache or build. Once pool runs prove the pull, the cleanup row removes the stages. The `image` job runs first in every run and is the one place a pool pod builds: it asks the registry for the three stage tags (a manifest read, about 20 s with the pod) and builds and pushes what is missing, and every job that loads the image `needs` it (`unit/ci_gate.bats`). Why: when the tag changed on 2026-11-25, 34 pods missed the registry at once, 20 of them built and pushed it, and the notes job cold-built the rust stage under its 10-minute guard and was killed before it could push, so the stage stayed missing (ar-5740). A pool pod's load job never builds and no load job pushes. A run on a Dockerfile change, or the first one of an ISO week, spends the cold build in `image` once; if that passes its guard, split the build, never raise the timeout.
- `fast` and `lint` run in the lean image as their job container when the repo variable `LINUX_RUNNER_JOB_POD` is set (`["self-hosted","linux","x64","job-pod"]`, home-config `arc-repo-dotfiles-pods`) and the `image` job found the image in the registry. The node's containerd pulls it once for every job pod on that node, where each dind pod docker-loaded its own 1 GB (ar-6016: deskslim-1/2 at 31-54% iowait). `tests/docker.sh` then runs in place, and their test-image steps skip. Otherwise, as on a fork, a registry miss or with the variable deleted, they run on `&pool` as before (`&job-pod` falls back to it; `unit/ci_gate.bats`). ui, rust and notes stay on the pool, because the ui tier needs a docker container.
  - The `image` job names both the image and the job-pod pool (its `job-pod` output), and `&job-pod` reads only those, so the pool and the container always agree. A `--failed` rerun reuses the image job and its outputs, so it goes back to the job pods even after the variable is deleted: to roll a red run off them, rerun the whole run (`gh run rerun <id>`) or push a new head, so the `image` job reads the variable again. A run reads the variable when it is created, not when its `image` job starts, so a run queued before the delete still goes to the job pods: rerun it whole too (main run 45717307293, created 22:55:51Z, ran its fast shards on the job pods after the 22:57:11Z delete). Why: on 2026-11-25 two `--failed` reruns after the rollback (45699808153, 45700315154) took the old image but read the deleted variable for their runner, ran the job container on a `&pool` runner, and lint-files found no usable git repository.
- `ui` in the same image you used locally, `lint` likewise, plus a weekly tmux-version drift sweep. `push` is restricted to `main` on purpose - `branches: ['**']` makes every job run twice.

The `rust` job runs `make test-rust CRATES=...` on what `tests/pick.sh rust` picks on a pull request: the crates whose directory or `tests/rust-inputs.txt` lines the change touches, plus the crates that depend on them by path; a change to the rust gate files runs all of them, and so does main. A crate that reads a new file outside its directory adds a line there (`unit/pick.bats` fails until it does). `fmt` and `clippy` block every run, pull requests included (clippy was main-only from #2086 to this change, and a lint then reached main red first); `shfmt` is gone. Measured 2026-11-16 from `~/.local/state/ci/jobs.jsonl` (successful jobs, started to completed), 24h windows around #2057 (test image built once per content hash), #2086 (fmt blocks, clippy main-only, shfmt deleted) and #2090 (toolchain pin; all three merged 2026-11-13 to 14, so a window cannot split them): the lint job went from p50 130 s / p90 149 s to 102 s / 126 s, all of it in the first window after #2057 (its `lint` step 122 s to 79 s, plus a 14 s image restore step); dropping shfmt moved it about 2 s. A rust job that runs the crates (Rust gate step at least 30 s) went from p50 272 s / p90 320 s to 224 s / 254 s on PRs (n=30 and 41) and from 290 s / 332 s to 270 s / 304 s on pushes (n=45 and 86), where clippy still runs. The PR figures are the clippy-free interval; with clippy back on PRs the PR job returns toward the push figure. Judge the rust job by those jobs only: most PRs skip the crates, so the all-jobs p50 follows the share that ran them (29% to 28%, 59% on 11-14).

## 6. Land it

One concern per PR. Hand off rather than improvising:

- **`ingest-prs`** ("Dirty working tree") - fan a mixed dirty tree into scoped PRs.
- **`dotfiles-land`** - decide public `~/.dotfiles` vs private `~/.dotfiles-private` (`git check-ignore` decides; a cross-repo change is two PRs).
- **`gh-workflows`** - PR mechanics.

Then update the durable layer, which is not optional either: a lesson in `~/.agent/lessons/{project}.md` for anything a future session would otherwise re-derive, and this SKILL.md when the procedure itself changed. A lesson records what happened; the skill is what the next run actually reads - patch the source, not just the diary.

## Coverage: aim at risk, not at line count

Coverage that ignores blast radius is theatre. Rank by what a bug *does*:

1. Scripts that **delete** things (`wind-down.sh`, and any future reaper) and whatever they consult to decide what to spare. A detector that finds dead windows should only REPORT, printing the `kill-window` command instead of running it, because a false positive there costs a scrollback nobody can recover.
2. Scripts whose purpose **is** a safety property (`servers.sh` - the socket split bounds a kill's blast radius; assert it, do not leave it as a comment).
3. Everything the user touches daily.
4. The rest.

A guard that **fails open** deserves a test pinning its vocabulary to a literal. `tmux-tags protected` reads window options; `has_tag` on a missing option is simply false, so any drift between the tag a user sets and the option the guard reads means a pinned window is reaped anyway, on a timer, with no error.

## Boundaries

- Never run the `ui` tier, or any real-server test, outside the container. No override flag exists; do not add one.
- Never `git checkout-index -a -f` to "tidy up" - it overwrites the working tree from the index and destroys unstaged work. `git reset` (mixed) unstages safely. Tar the dirty tree before any multi-step git surgery.
- Never push or merge another session's branch to satisfy a hook. Report it instead.
- Never claim something is verified without the CI run that shows it. If a tier could not run, say which and why.
- Never run a test on the workstation from an agent session, a single file included: push and read CI.
