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
- Every budget has an alert that fires when p90 over the last N runs passes it. Why: a budget nobody watches erodes. Dotfiles tests grew from about 1,960 on 11-01 to 4,623 on 11-10; shards (#1414, 11-07) cut unit to about 3 minutes and it was back to about 8.5 three days later, with nothing watching.

## Speed levers, in this order

1. Pick less: affected-only, and skip heavy jobs on a docs-only change. Why: the cheapest minute is one not run (platform `.github/filters/docs.yml`; dotfiles `fleet_dispatch.bats` picked in 16 of 19 main commits by a name it only stubs).
2. Cut fixed per-job cost before adding shards. Why: each shard pays setup again; platform measured 4 shards at about 40 billed minutes a run against 26 for 2 (`PIPELINES.md`, 2026-09-24).
3. Run cheap work first, with a draft tier. Why: most reds show in build, typecheck and unit, so the expensive tier starts only on a PR ready for review (platform `.github/actions/ci-tier`).
4. Build once and fan out, with one build identity (version, target, flags) every consumer keys on. Why: a build per shard multiplies the slowest step (G2I digest, "Gate shape"; null-cookie-merry-cocke P10).
5. Shard by weights measured from the last main run, never a hand table. Why: a committed weights file drifted until one dotfiles shard ran 514s against 301s predicted.
6. Only then add runners or slots, with a measured before and after. Why: capacity costs money every month and hides the first five problems, so a capacity change needs a measured benefit (null-cookie-merry-cocke "Spot and capacity").
- Every lever ranks deletion first: a change that removes a step, knob or duplicate beats one that adds. Why: global Subtract First; playground rule 13.

## Gate correctness

- One aggregate check is the required one, and it goes red on missing work: a missing shard, missing results, or a job that skipped when it was expected. Why: a required check that only reads what ran can go green on nothing (platform `E2E Summary` with `tools/check-e2e-expectations.mjs`).
- Cancel superseded PR runs; never cancel a run on main or a gate whose test job has started. Why: cancelling a started gate threw away finished shards (playground rule 7, #1005, #1007); main runs are the only test of the merged tree (platform `PIPELINES.md`, dotfiles `tests.yml` concurrency).
- Test the SHA you name: a PR body, a release or a nightly records the commit it tested, and a green on an older commit does not carry forward past a change it depends on. Why: playground rule 4 and its stale-green re-gate.
- Gates never poll with `gh run watch`; share one cached run list per machine. Why: per-gate polling spent the account's API limit for the whole fleet (playground rule 8, #1194).

## Red handling

One decision list. Walk it top to bottom for every red.

1. Classify the red from its log and the same-commit history, never by rerunning it (`ci-failures` buckets: infra, timeout, test, check, derived, pending).
2. A test red is fixed, its cause reverted, or quarantined with an owner, an expiry of at most two weeks, and a board row. Why: a quarantine without an expiry is permanent (`playground-nightly-fix`).
3. A rerun is allowed only for a red classified infra with evidence (runner lost, network, rate limit, registry pull) and only after that infra cause is filed on the board or queue. A rerun never turns a test red green. Why: blanket reruns hide flakes until main is red every night (the G2I digest rejects a client auto-retry workflow for this reason).
4. No automatic retry, at the job or the test level. Why: the same.
5. Never raise a timeout or a ceiling to pass. Why: it moves the hang guard into the budget (Budgets above).

## Harness changes

- A change to the CI harness or the picker ships with a test and a negative control that proves the test can fail. Why: a gate that cannot fail is not a gate (playground rule 13; dotfiles `shell-test-harness` section 3).
- A gate that cannot enumerate its inputs fails rather than reporting clean. Why: dotfiles lesson 2026-07-26; a silent empty pick is a green on nothing.
- A cost or speed change is measured before and after with the same script and window, and the measured number replaces the plan's estimate. Why: a saving measured with another script or window cannot be credited to the lever (skill `ci-cost` step 6, playground `docs/operations/ci-cost.md` log).

## Analysis

- Read runs from the local run ledger (`schedules-sync runs`, the playground's `~/.local/state/unity-test-runs/runs.tsv`) and the `ci-failures` and `ci-cost` scripts, with their caches; never sweep `gh api` live in a loop. Why: a session hit a GitHub 403 on 2026-11-10, and the account's 5,000 calls an hour are shared by every session.
- Quote only a number counted in this session or read from a dated doc. Why: an uncounted number cannot be compared next time (skills `ci-cost`, `ci-failures`).

## Client bars

- A client's CI bar is an overlay that applies only in that client's repos, never to ours. G2I: every test runs on the PR, no job over 45 minutes, nothing nightly. Source: `~/.notes/employment/jobs/g2i/best-practices.md`, "Gate shape".

## Per-repo CI docs

| Repo | CI doc | PR gate budget (p90) | Gate shape | Budget alert |
| --- | --- | --- | --- | --- |
| unity-core-playground | `~/dev/bnb/games/engine/unity-core-playground/docs/operations/ci.md` (cost: `ci-cost.md`) | not declared; plan null-cookie-merry-cocke targets 30 min, then 15 | affected classes on the pool, nightly runs every class | none yet |
| platform | `~/dev/bnb/platform/docs/deployment/PIPELINES.md` | not declared (fleet default 10) | turbo affected plus draft tier, full on develop/main and nightly | none yet |
| dotfiles | skill `shell-test-harness`, section 5 | 5 min | picked set plus broad set, full on main | planned (plan dotfiles-ci-minutes-doctrine P6) |
| dotfiles-private, home-config, unity-core, unity-core-harness, bnb-game-servers, dodginballs, binks-agent-orchestrator, personal-sites, crypto-indexer | none yet | fleet default 10 | none written | none yet |

A repo that adds a CI doc adds its row here in the same PR.
