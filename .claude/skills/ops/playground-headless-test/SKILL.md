---
name: playground-headless-test
description: >-
  Run unity-core-playground tests on the runner pool: one class, a merge gate, the nightly; an agent session runs no Unity here. Use for "run the tests", "gate this PR", "is this green". Why CI keeps going red: ci-cleanup. Not for a live editor.
metadata:
  category: ops
  tags: [unity, testing, ci, playground, headless]
  system: [tests]
  reviewed: 2026-11-24
  # The hand-typed forms this skill's scripts replace; hand_methods.py denies them.
  replaces:
    - match: 'Logs/gate\.txt.*pr-body|pr-body.*Logs/gate\.txt'
      use: scripts/test/gate-and-land.sh (flags in its header; docs/operations/ci.md step 2)
      where: unity-core-playground
      why: the gate line, the PR and the landing are one script; a hand copy drifts from ci.md step 2
    - match: '-batchmode\b.*\s-runTests\b|\s-runTests\b.*-batchmode\b'
      use: a pool run of the class (step 2), or gate-and-land.sh to gate
      where: unity-core-playground(?!.*asset-library)
      why: an agent session runs no Unity test on the workstation, which is the human's; a bare Unity also skips the hold and the run slots, and a -host on 7770 joins the human's game
    # Each row below matches the script in command position (after a wrapper such as env, timeout or xargs too), per
    # command segment, so reading or linting it is allowed. A relative ./run.sh is left to the script's own refusal.
    - match: '(?:^|[;&|({\n!]|(?<![\w./-])(?:(?:then|do|else|exec|time|nohup|nice|sudo|xargs|command|setsid|stdbuf|env|timeout)(?:\s+(?:-\S*|\d\S*|[A-Za-z_]\w*=\S*))*|(?:bash|sh)(?:\s+-(?!n\b)\S*)*)(?=\s))\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:Q\s+)?(?:\S*/)?scripts/test/(?:run|two-process|multi-process)\.sh\b'
      use: push, then gh workflow run test.yml --ref <branch> -f classes=affected -f only=<Namespace.Class> (step 2); gate with scripts/test/gate-and-land.sh
      where: unity-core-playground(?!.*asset-library)
      why: an agent session runs no Unity test on the workstation, which is the human's; each script refuses one too
    - match: '(?:^|[;&|({\n!]|(?<![\w./-])(?:(?:then|do|else|exec|time|nohup|nice|sudo|xargs|command|setsid|stdbuf|env|timeout)(?:\s+(?:-\S*|\d\S*|[A-Za-z_]\w*=\S*))*|(?:bash|sh)(?:\s+-(?!n\b)\S*)*)(?=\s))\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:Q\s+)?(?:\S*/)?scripts/test/suite\.sh\b(?:(?![^;&|\n]*--(?:editmode-)?classes\b)|(?=[^;&|\n]*--(?:only|all-red)\b))'
      use: scripts/test/gate-and-land.sh, committed (step 5), which hands the gate to the pool
      where: unity-core-playground(?!.*asset-library)
      why: a whole suite or a gate that stays here runs Unity on the workstation; only --classes hands it to the pool, and suite.sh refuses the rest in an agent session
    - match: '(?:^|[;&|({\n!]|(?<![\w./-])(?:(?:then|do|else|exec|time|nohup|nice|sudo|xargs|command|setsid|stdbuf|env|timeout)(?:\s+(?:-\S*|\d\S*|[A-Za-z_]\w*=\S*))*|(?:bash|sh)(?:\s+-(?!n\b)\S*)*)(?=\s))\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:Q\s+)?(?:\S*/)?scripts/test/in-docker\.sh\b(?:(?![^;&|\n]*--method\b)|(?=[^;&|\n]*--(?:suite|multi|two|build|load|player|play|filter)\b))'
      use: push, then gh workflow run test.yml --ref <branch> -f classes=affected -f only=<Namespace.Class> (step 2)
      where: unity-core-playground(?!.*asset-library)
      why: in-docker.sh runs run.sh in a container on the workstation, where run.sh's agent-session refusal cannot see the session
    - match: '-batchmode\b.*\s-executeMethod\b|\s-executeMethod\b.*-batchmode\b'
      use: scripts/authoring/unity-method.sh <Namespace.Class.Method>
      where: unity-core-playground(?!.*asset-library)
      unless: 'cd [^;&|]*asset-library'
      why: a bare Unity -batchmode skips the hold and the run slots (slots.sh)
    # A hand cancel of this repo's runs: from its checkout, naming it with -R, in the api path, by GH_REPO or a cd on the
    # same line. gh-workflows' own row lets `# own:` and `# stuck:` through; these do not, since the script is the one path
    # that checks the run's jobs first.
    - match: '(?:^|[;&|(){}\s/])gh(?:\s+(?:-R|--repo[\s=])\s*\S+)*\s+(?:run\s+cancel(?![\w-])|api\s(?:[^;&|\n]*actions/runs/[^/\s]+/(?:force-)?cancel(?![\w-])))'
      use: 'scripts/test/gh-run-cancel.sh <run> "<why>" (or --stuck "<live step>"): it refuses a run a Unity job has started (docs/operations/ci.md rule 7) and logs caller, run and reason'
      where: unity-core-playground
      unless: '(?:-R|--repo[\s=])\s*[\w.-]+/(?!unity-core-playground(?![\w.-]))[\w.-]+'
      why: sessions cancelled started gate shards by hand under `# own:` as superseded, runs 46041044210, 45318303563 and 45277619723, with nothing on record but the token's owner (ucp-2089)
    - match: '(?:^|[;&|(){}\s/])gh\s+(?:(?:-R|--repo[\s=])\s*\S*unity-core-playground\S*\s+run\s+cancel(?![\w-])|run\s+cancel\s[^;&|\n]*(?:-R|--repo[\s=])\s*\S*unity-core-playground|api\s[^;&|\n]*unity-core-playground/actions/runs/[^/\s]+/(?:force-)?cancel(?![\w-]))'
      use: 'scripts/test/gh-run-cancel.sh <run> "<why>" from a unity-core-playground checkout (or --stuck "<live step>"): it refuses a run a Unity job has started (docs/operations/ci.md rule 7) and logs caller, run and reason'
      why: sessions cancelled started gate shards by hand under `# own:` as superseded, run 45277619723 with -R from outside the checkout (ucp-2089)
    - match: '(?:GH_REPO=\S*unity-core-playground|(?:^|[;&|(){}\s])cd\s+\S*unity-core-playground)[^\n]*?(?:^|[;&|(){}\s/])gh\s(?:[^;&|\n]*\s)?(?:run\s+cancel(?![\w-])|api\s[^;&|\n]*actions/runs/[^/\s]+/(?:force-)?cancel(?![\w-]))'
      use: 'scripts/test/gh-run-cancel.sh <run> "<why>" from a unity-core-playground checkout (or --stuck "<live step>"): it refuses a run a Unity job has started (docs/operations/ci.md rule 7) and logs caller, run and reason'
      why: the same hand cancel with the repo named by GH_REPO or a cd into the checkout on the same line, which the cwd and -R rows do not see (ucp-2089 review)
---

# Playground headless test

Runs the playground's tests on the BNB runner pool, never on the workstation, which is the human's and is shared with every other session, and turns a run into a merge decision. In an agent session (`CLAUDECODE=1`) `run.sh` and `suite.sh` refuse a local run and the rows above deny the hand-typed forms; a person's own shell is not refused. Every CI rule lives in the repo's `docs/operations/ci.md` (Rules); this file restates none of them. When the two disagree, the doc wins and this file gets fixed in the same turn.

## Scope and triggers

- When iterating on one test class while writing or fixing it, on the pool.
- When gating and landing a playground PR.
- When a `Tests (all)` run on main is red and you need to read it.

Not for MCP-driven play in an editor: CLAUDE.md "Driving the sandbox over MCP". Not for why reds recur across many runs, or what a nightly red belongs to - that is `ci-cleanup`. Taking a red nightly to green: `fix-ci`.

## Steps

1. Check holds first: `agent-hold list`. What a `unity` hold pauses and how a run waits it out: the repo's `docs/development/testing.md`, Headless.
2. Iterate on one class at a time on the pool. Commit and push the branch (the pool tests what is pushed), then
   `gh workflow run test.yml --ref <branch> -f classes=affected -f only=<Namespace.Class>` (space-separate several; PlayMode only, no EditMode). Take the run id from `gh run list --workflow test.yml --branch <branch> --limit 1` and wait with `gh-run-wait <run-id>` in the background; the `block-poll.py` hook denies a foreground wait loop. An EditMode fixture has no one-class run: it runs in the branch's gate (step 5), which runs EditMode first. A gate red prints this same command as its "Reproduce on the pool" line (`gate-verdict.py`).
3. Read the counts in the run's summary and its shard's `test-runs-playmode-<n>` artifact, as `docs/operations/ci.md` says for a red gate. `0/0`, or an `only=` class that ran no test, means the name matched nothing (a typo, or an EditMode fixture), not that tests passed. Failure detail is in that shard's `results.xml` and `editor.log`.
4. Prove a new check can fail: plant one fault per assertion (a bad asset, an entry removed from an allow list) in a commit, push, run the class on the pool as in step 2, see it red, revert it in a new commit, push, and confirm `git status` is clean in the repo and in `External/asset-library`.
5. Gate and land in the background with `scripts/test/gate-and-land.sh`, committed, as `docs/operations/ci.md`, One change, start to finish, step 2 says (its flags: the script's header). It ends in `agent-land`, which waits for Checks, merges and closes the board row, so a green gate wakes you once, already landed. Its Rules decide where it runs, what it picks, when to gate again after merging main, and what a FAIL means; do not pick the place or the classes by hand.
6. At session start, read main's last nightly as `docs/operations/ci.md` rule 10 says.

## Do NOT

- Do not run any Unity test on the workstation from an agent session: no `run.sh`, `two-process.sh`, `multi-process.sh`, `suite.sh` without `--classes`, `in-docker.sh` beyond `--method`, or Unity `-runTests` (the rows above deny them; the scripts refuse too). The whole suite and player builds stay off it for everyone (`docs/operations/ci.md` rule 3).
- Do not call Unity `-runTests` or `-executeMethod` by hand (the guard denies both; an editor method runs through `scripts/authoring/unity-method.sh`) or use port 7770: a `-host` that cannot bind joins the human's game.
- Do not stop Unity with `pkill -f` or a `pgrep -f` waiter; they match your own shell. Filter `ps -eo pid,comm,args` on `$(2)=="Unity"`.
- Do not touch `External/unity-core` (checkout, merge, commit) while a run uses that tree.
