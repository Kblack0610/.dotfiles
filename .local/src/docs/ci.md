# How CI works

The one home for CI doctrine across every repo the fleet works in. Each rule is one line: the rule, why, and the repo or PR that proved it. A repo's own CI doc holds its specifics (where its picker lives, its shards, its runners) and links here for the rest; it never restates a rule from this page. The global rule "A merge gate finishes in minutes" (`~/.claude/CLAUDE.md`) is the invariant core of this page.

## Tiers

- The PR gate runs what the change can affect plus a small broad set. Why: a run-everything gate held playground PRs 3 to 15 hours (playground `docs/operations/ci.md` rule 1, #993, #1553); the platform scopes by the turbo graph (`PIPELINES.md` "CI cost policy").
- The picker fails open: a lookup failure, a root config change or a harness change runs everything, and the job summary says which. Why: a picker that fails closed reports green on work it never ran (platform `.github/actions/affected`).
- A picker that misses a dependency is taught that dependency, with a test and a replay of past picks; the gate is never widened. Why: each widening grows the gate back to the full suite (playground rule 1).
- Every push to main, or a nightly on main, runs the full suite. Why: branch protection does not require up-to-date branches, so the run after the merge is the only test of the merged tree (platform `PIPELINES.md`).
- A red on main stops the line: find the PR that broke it and land the fix or a revert before your own work. Why: excusing main's reds per branch kept the playground nightly red 11 of 14 nights (playground rule 5).

## Budgets

- Each repo declares a p90 wall budget for its PR gate in its CI doc; the fleet default is 10 minutes. Why: "minutes" without a number cannot be checked, and the per-repo table below shows who has one.
- `timeout-minutes` is a hang guard of at least 2 to 3 times the budget, never a lever to pass a slow run. Why: a generous timeout lets a hung job hold a runner for hours; playground job timeouts of 240 to 720 minutes did that (G2I digest, "Gate shape").
- A gate that queues or runs past about an hour is a CI bug: report it and fix it, never reroute or restart it. Why: playground rule 9; the G2I digest counted 319 playground gate runs over an hour ("Gate shape").
- Every budget has an alert that fires when p90 over the last N runs passes it. Why: a budget nobody watches erodes. Dotfiles tests grew from about 1,960 on 11-01 to 4,623 on 11-10; shards (#1414, 11-07) cut unit to about 3 minutes and it was back to about 8.5 three days later, with nothing watching (plan dotfiles-ci-minutes-doctrine, measured on run 42923495293).

## Speed levers, in this order

1. Pick less: affected-only, and skip heavy jobs on a docs-only change. Why: the cheapest minute is one not run (platform `.github/filters/docs.yml`; dotfiles `fleet_dispatch.bats` picked in 16 of 19 main commits by a name it only stubs).
2. Cut fixed per-job cost before adding shards. Why: each shard pays setup again; platform measured 4 shards at about 40 billed minutes a run against 26 for 2 (`PIPELINES.md`, 2026-09-24).
3. Run cheap work first: before the push, then with a draft tier. Every repo commits a `.githooks/pre-push`, switched on in every clone by the global dispatcher in dotfiles (`.config/git/hooks/`, `docs/operations/git-hooks.md`), that runs the repo's offline checks picked by changed path (docs, lint, unit and compile checks), with its lint tools pinned in one file the hook and CI both read; it chains `git lfs pre-push "$@"` where the repo uses LFS, stays under about 10 seconds, and CI runs the same checks again as the authority. A session cannot skip it: `skip-guard` (`.claude/hooks/skip-guard.py`) denies `--no-verify`, a moved `core.hooksPath` and a direct push to a default branch. In CI the expensive tier starts only on a PR ready for review. Why: 289 of 1,075 playground reds in 14 days were docs budgets, actionlint and compile errors a local run finds in seconds (plan catch-cheap-reds-before-push; playground `scripts/test/checks-local.sh`, #2945); platform `.github/actions/ci-tier`; `stages.md` checks the hook at dev.
4. Build once and fan out, with one build identity (version, target, flags) every consumer keys on. Why: a build per shard multiplies the slowest step (G2I digest, "Gate shape"; null-cookie-merry-cocke P10).
5. Shard by weights measured from the last main run, never a hand table. Why: a committed weights file drifted until one dotfiles shard ran 514s against 301s predicted (same plan, same run).
6. Only then add runners or slots, with a measured before and after. Why: capacity costs money every month and hides the first five problems, so a capacity change needs a measured benefit (null-cookie-merry-cocke "Spot and capacity").
- Every lever ranks deletion first: a change that removes a step, knob or duplicate beats one that adds. Why: global Subtract First; playground rule 13.

## Gate correctness

- One aggregate check is the required one, and it goes red on missing work: a missing shard, missing results, or a job that skipped when it was expected. Why: a required check that only reads what ran can go green on nothing (platform `E2E Summary` with `tools/check-e2e-expectations.mjs`).
- A PR that loosens a gate waits for the human. Every repo's PR runs gate-guard (`.github/workflows/gate-guard.yml` in dotfiles, called from a thin `.github/workflows/gate-guard.yml` in each repo, on `pull_request_target` so it runs from the base branch). It holds an edit to a file the repo's `.github/gate-files` lists, a raised baseline or threshold, a dropped job and an added `continue-on-error` (the rules: `.local/bin/gate-guard`). The human passes a held PR by applying the `gate-change` label; skip-guard denies an agent applying it. Why: an agent could loosen a gate in the same PR that needed it, and every merge gate trusted the PR it judged (plan everything-should-wondrous-snail P3; 11 of 3,049 dotfiles merges in the 30 days to 2026-11-25 would have waited).
- Cancel superseded PR runs of your own PR only, never another PR's run to jump the runner queue (queue order is the pool's job; `gh run cancel` is denied without `# own:` or `# stuck:`, gh-workflows row; the marker is a self-declaration, and `fleet-shepherd sweep-cancel`, a script the hook does not see, is the one sanctioned cancel of a failing sweep's run, and its `ghost-runs` the one of a GitHub run queued past `FLEET_SHEPHERD_GHOST_AGE_H` with no jobs, main included, deleted when GitHub refuses both cancels with HTTP 409 (ask 44Ljyz; a delete it answers 403 "Could not delete the workflow run" is `undeletable`, asked again once every `FLEET_SHEPHERD_GHOST_AGE_H`, ask VBMlNu), since a run with no job tests nothing and so is no test of the merged tree); never cancel a run on main or a gate whose test job has started. Why: cancelling a started gate threw away finished shards (playground rule 7, #1005, #1007); a lander that cancelled 19 other PRs' runs made their landers re-push and the pool churn (#2526, 2026-11-18, ar-3299); main runs are the only test of the merged tree (platform `PIPELINES.md`, dotfiles `tests.yml` concurrency).
- Test the SHA you name: a PR body, a release or a nightly records the commit it tested, and a green on an older commit does not carry forward past a change it depends on. Why: playground rule 4 and its stale-green re-gate.
- Gates never poll with `gh run watch`; share one cached run list per machine. Why: per-gate polling spent the account's API limit for the whole fleet (playground rule 8, #1194).
- A green head lands behind a base that moved when the base asks no up-to-date branch (dotfiles' ruleset has `strict_required_status_checks_policy` false) and its new files can affect no test the head's run picked (`agent-land` `moved_misses_pick`, by `tests/pick.sh`); otherwise it is merged up and re-run once, then lands behind a second move. Before the gate, a behind head whose own run is already pending or green is waited on first, not merged up (`head_checks_live`), and a head that is itself a merge-up counts that run as its one re-check, since a re-run after a checks timeout otherwise restarts that run every time (ar-5865). A move whose commits change a file the head changes never lands behind: it is merged up and re-run again, and past `CATCHUP_OVERLAP_WAITS` runs agent-land exits 3 (`base_touches_head`; #2962 landed behind #2963 on the same two files and main went red). Why: a full run outlasting main's next merge was re-run until a saturated pool cut it (ar-6019). A guard cut is a red, never a pass.

## Runners

- A CI job's tools come from one image; a runner is docker plus a label, chosen once per workflow. No step installs a tool on the runner (apt, rustup, a setup action), and the runner choice is one YAML anchor every job references. Why: dotfiles jobs got their tools three ways (runner apt, the test image, runner rustup), so a move to the home pool meant installing the same tools on every pool host, checking for them in CI and keeping three lists in step (plan ck-report-only-draws-nested-owl; dotfiles `tests/unit/ci_gate.bats` checks it there). Other repos adopt it when they next touch CI.

- A pool pod loads a shared image and never builds it: one job per run, ahead of the jobs that need the image, makes the registry hold it, and the rest only pull. Why: a tag change sent every pod to the registry at once (dotfiles 2026-11-25: 34 misses, 20 pushes of one tag, a 1 GbE link full), and the stage built inside a job's hang guard was killed before it pushed, so every later run missed again (dotfiles `tests.yml` `image`, ar-5740). The registry host's link is the shared resource: a pod pulls a few hundred MB, so what a run adds is its pod count times the image, and a job that can skip loading the image does (lever 1). A job whose whole run is in the image takes it as its job container on a job-pod runner, so the node's containerd keeps one copy for every pod there where each dind pod wrote its own (dotfiles `fast` and `lint`, ar-6016). A seed pushes each stage as it finishes, so a Dockerfile change that outruns the seed job's 25 min guard on a saturated pool (2026-11-25: lean 17 min, rust 3.5, full cut) leaves the finished stages in the registry and the next run builds only the rest: the guard stays and the next push completes the seed. A load that fails to pull fails in about 6 minutes at most and goes no further: no Actions cache restore (a WAN path at 1 to 2 MB/s) and no build, since either one behind a failed pull ran the ui job into its 25 minute guard silently (dotfiles run 45636762520, ar-5959). A pull that fails there is a registry pull failure in the sense of Red handling step 3, and its log line carries the seconds. Measured 2026-11-25 (zot access log, ci-registry-push on ms-a2 at 111% CPU): a lean pull is about 280 MB, rust adds about 230, full adds about 430 more, and a run pulls about 10 GB (30 fast shards x lean, ui and rust x full, notes, lint), served at about 30 MB/s in all (18 GB in ten minutes at the peak), so seven runs at once need about 40 minutes of registry time. Fewer bytes per pod or a faster registry host is the cure; the host is cluster side (home-config).
- A test file is a floor under its shard: a shard with one heavy file ends no sooner than that file, and a pod spends about 4 minutes on image pull and first start before bats (dotfiles run 45622726820: five shards, each one file of 266 to 430 s, cut at the 10 min guard while the table was right). No file weighs past about 220 s: split it in two (`<file>_part2.bats`, setup in a shared `common.bash`) and never add shards for it. Why: more shards also mean more simultaneous image pulls from one registry link (dotfiles `tests/shard.sh`, ar-5740).

## Red handling

One decision list. Walk it top to bottom for every red.

1. Classify the red from its log and the same-commit history, never by rerunning it (`ci-cleanup` Reds buckets: infra, timeout, test, check, derived, pending).
2. A test red is fixed, its cause reverted, or quarantined with an owner, an expiry of at most two weeks, and a board row. Why: a quarantine without an expiry is permanent (`fix-ci`).
3. A rerun is allowed only for a red classified infra with evidence: the log shows a runner lost, a network or transport error, a rate limit or a registry pull failure, before the job's main work started. A test assertion or a timeout inside the tests is never infra. The infra cause is filed on the board or queue first. A rerun never turns a test red green. Why: blanket reruns hide flakes until main is red every night (the G2I digest rejects a client auto-retry workflow for this reason).
4. No automatic retry, at the job or the test level. Why: the same.
5. Never raise a timeout or a ceiling to pass. Why: it moves the hang guard into the budget (Budgets above).

## Harness changes

- A change to the CI harness or the picker ships with a test and a negative control that proves the test can fail. Why: a gate that cannot fail is not a gate (playground rule 13; dotfiles `shell-test-harness` section 3).
- A gate that cannot enumerate its inputs fails rather than reporting clean. Why: dotfiles lesson 2026-07-26; a silent empty pick is a green on nothing.
- A cost or speed change is measured before and after with the same script and window, and the measured number replaces the plan's estimate. Why: a saving measured with another script or window cannot be credited to the lever (skill `ci-cleanup`, Cost step 5, playground `docs/operations/ci-cost.md` log).

## Analysis

- Read PRs from the PR store (`schedules-sync prs`) and runs from the local run ledger (`schedules-sync runs`, the playground's `~/.local/state/unity-test-runs/runs.tsv`) and `ci-failures.py` and `ci-cost.py`, with their caches; never sweep `gh api` live in a loop. A pass rate is `hub ci pass` (hub_core `builds::verdict`: green over green plus red, each attempt a run, cancelled and skipped left out), never a second formula. Why: a session hit a GitHub 403 on 2026-11-10, and the account's 5,000 calls an hour are shared by every session.
- Quote only a number counted in this session or read from a dated doc. Why: an uncounted number cannot be compared next time (skill `ci-cleanup`).

## Client bars

- A client's CI bar is an overlay that applies only in that client's repos, never to ours. G2I: every test runs on the PR, no job over 45 minutes, nothing nightly. Source: `~/.notes/employment/jobs/g2i/best-practices.md`, "Gate shape".

## Per-repo CI docs

| Repo | CI doc | PR gate budget (p90) | Gate shape | Budget alert |
| --- | --- | --- | --- | --- |
| unity-core-playground | `~/dev/bnb/games/engine/unity-core-playground/docs/operations/ci.md` (cost: `ci-cost.md`) | 15 min, `.github/ci-budgets.json` `tiers.gate`, judged by `scripts/ci/ci-cost.py --days 1` (p90 114 min on 2026-11-13) | affected classes on the pool, nightly runs every class | Sentinel `playground-gate-budget`, hourly |
| platform | `~/dev/bnb/platform/docs/deployment/PIPELINES.md` | not declared (fleet default 10) | turbo affected plus draft tier, full on develop/main and nightly | none yet |
| dotfiles | skill `shell-test-harness`, section 5 | 5 min, provisional (`rules.jsonl`; PR p90 was 9.0 min on 2026-11-10, before the picked gate) | picked set plus broad set, full on main; shards weighed by the last green main JUnit; every job in the `tests/Dockerfile` image on the `&pool` runner: `gh variable set LINUX_RUNNER_LIGHT -R Kblack0610/.dotfiles -b '["self-hosted","light"]'` is the home pool, `gh variable delete LINUX_RUNNER_LIGHT -R Kblack0610/.dotfiles` is GitHub-hosted, a fork PR is always hosted | Sentinel `dotfiles-gate-budget`, hourly |
| dotfiles-private, home-config, unity-core, unity-core-harness, bnb-game-servers, dodginballs, binks-agent-orchestrator, personal-sites, crypto-indexer | none yet | fleet default 10 | none written | none yet |

A repo that adds a CI doc adds its row here in the same PR.
