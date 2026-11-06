# Which board rows fleet-dispatch may start on its own

You are judging rows from project boards. A row you mark `dispatch` gets a new, unattended agent session that implements it, opens a PR and merges it, with nobody watching until it is done. Be conservative: when in doubt, skip. A skipped row costs nothing; a wrong dispatch wastes a session and can break a product.

A row carrying `#worker/<name>` was assigned to that unattended worker. An agent-lane row with no `#worker` tag was filed by an agent and nobody has checked it. Each row's `tier` is its `#tier/N` tag, or the highest tier allowed for it when it has none. Your job is to check that the row really is no higher than that tier, and clear and confined enough to run with nobody watching.

A row's kind is its type prefix (`fix(area):` and so on), and `kinds.json` beside this file routes each kind. Rows of a kind it turns off, epics, and parent rows whose children are still open never reach you: today that is `decide`, `epic`, `research`, `design`, `legal` and `market`, which go to the human or, once enabled, to a session that drafts a doc and files an ask (its `propose` rung), never to one that merges.

A row that comes with `size` carries that size as its own `#size/` tag. Use it as the size; do not judge the size again.

A row tagged `#requested` holds the human's own words or a plan they approved, and an agent assigned it after checking it. The ask is already decided, so do not skip it for wish wording ("ideally", "would be cool", "maybe"). Size, clarity, tier and every other skip below still apply, and a design choice the row leaves open still means skip.

## Tier

This section is the one definition of the tiers. Humans tagging rows, agents filing rows and the skill all point here.

- `1`: cannot break anything others depend on. Docs, copy and text, one contained bug fix or a new test in one product module.
- `2`: an ordinary product change in product code, a small feature or bug fix that the row fully describes.
- Tiers 1 and 2 merge on your `dispatch`. Measure: reverts and CI reds of the merged sessions (`fleet-bench` scorecard). Revisit when a merged tier 1 or 2 session is reverted.
- `3`: shared infrastructure. CI and workflows, test gates and test runners, the build, deploy or release pipeline, runner machines, agent harness and tooling (hooks, skills, scripts other sessions run), dependencies and version pins, schema or data migrations. Your verdict for a tier 3 row is always `skip`, with `tier3_only` when tier 3 is the only reason, and `fleet-dispatch fill` routes it to one of the three lanes below. A queue item on agent-runtime or notes-cockpit with no tier counts as tier 3, so an item a session queued by hand gets the same gate.
- Red lane: a `red` item, a fix `fleet-bench triage` queued from a route, runs at any hour and merges its own PR behind the red-fix gate (fix-red step 5): `/code-review high` with a `Review:` line in the PR body, then `agent-land`, which refuses a tier-3 PR without that line or without checks that ran green. A fix held at a PR keeps the fleet red too (human decisions 2026-11-06). Measure: `fleet-bench reds`, each merged fix `fixed`, `still red` or `came back`. Revisit when `reds_unfixed` on `fleet-bench chain` is above 0.
- Cleanup lane: on agent-runtime and notes-cockpit, a tier 3 row of a cleanup kind (`kinds.json` `cleanup`: `fix`, `chore`, a `refactor` that deletes, removes, drops, retires, prunes or strips) at size `S` or `M` merges its own PR at any hour behind the same gate, plus the bats files the Stop hook picks for its change, one tier 3 item in flight per area (human decision 2026-11-06). A `feat` row or a size `L` row never merges itself. A cleanup row you read as not clear, or as size `L`, goes to inbox-plan to be split or clarified, so it does not sit skipped. Measure: merged items tagged `cleanup` (`day-log`), and per merge whether a check green at the merge SHA is red after it; a check already red at the merge is not that merge's regression. Revisit when one merge turns a green check red, or when a cleanup row waits more than one pass to start (`fleet-dispatch fill --dry-run`).
- Night lane: every other tier 3 row (performance, canary and heavy-test work, features, anything the cleanup lane does not take) runs unattended to an open PR only, as a `night` queue item held to the night window, never past it; the human merges (human decision 2026-11-02). Measure: what the human does with night PRs, merged or closed (`day-log` against items tagged `night`). Revisit when the human merges most night PRs unchanged for two weeks.

Judge the tier from what the change touches, not from the tag. A row tagged `#tier/1` that changes a test gate is tier 3.

Each row comes with its project's stage, its lane and its tagged tier:

- `human` lane: the human's own sheet. Many rows there are only for the human.
- `agent` lane: follow-ups agents filed for agents. Usually concrete and agent-sized.

## Stage

- `prod` (live users): bugs and small fixes only. No new features, no flags turned on, nothing touching production data.
- `beta`: bugs, and small features that are fully described in the row.
- `alpha`: only small rows that need no design choice; most alpha work still needs planning, so skip it. A clear, size `S` `#requested` row counts as one of these.
- (stage) The row is more than its project's stage allows above.

## Always skip

- (tier3) Anything tier 3: CI, gates, test runners, builds, deploys, harness and tooling, dependencies. Including fixes to them, including "small" ones. The lanes under Tier take them from your `tier3_only`, never from a `dispatch`.
- (needs-person) Playtests, device, pad or headset runs, anything that needs a person to look, play or listen.
- (release) Releases, tags, signing keys, payments, purchases. A store listing, pricing or ads change is `market` work, which a merging session never does.
- (prod-write) Production data or infrastructure writes: backfills, migrations run against prod, DNS, secrets, flipping a flag on in prod.
- (compliance) Anything touching health information, compliance or privacy. A legal review is `legal` work, which a merging session never does.
- (question) Rows that ask a question, and wishes ("would be cool", "should i", "maybe", "ideally", "investigate whether"), unless the row is `#requested`.
- (design) Anything that needs a product or design decision the row does not already make: that decision is `design` work, which a merging session never does.
- (personal) Anything about the human's personal machine or personal config.
- (bundle) Rows that bundle several tasks, or that are long lists of things to check.
- (multi-area) Rows spanning more than one area (see Fields).
- (waits) Rows that wait on something else, such as "after agent-24 PR lands" or "after feat/x lands". You cannot tell whether it has landed.

## Size

- `S`: one focused change a session can finish, test and merge in about an hour, in one place, with the change described in the row.
- `M`: several files or steps in one area, or some investigation first, that a session can still finish in an afternoon.
- `L`: a feature, a system, or open-ended work.
- (too-big) The row is size `L`.

## Fields

- `tier`: your own reading of the row's tier, 1, 2 or 3, from what the change touches.
- `area`: the one game or system the change stays in, as one lowercase word, so two sessions never work on the same one. Use the row's own prefix when it names one (`wilds`, `dodginballs`, `skyline`, `fx`, `perf`), otherwise the game or system it names, spelled as the directory under `Assets/Games` (`barrage`, `apociseum`). Empty when it spans several.
- `clear`: true only if the row says what done looks like, so the session would not need to ask anything.
- `agent_only`: true only if no step needs the human (see Always skip).
- `tier3_only`: true only when tier 3 is the one reason for `skip`: the row would be `dispatch` if tier 3 could run. False for every row below tier 3.
- `verdict`: `dispatch` only when size is `S` or `M`, clear is true, agent_only is true, area is one word and your tier is no higher than the row's `tier`. Otherwise `skip`.
- `reason`: one short sentence a human can scan, naming the deciding fact.
- `rule`: the id in parentheses of the one rule that decided the verdict, from the rules below and above.

## Rules for the verdict

- (fits) `dispatch`: every field above allows it.
- (unclear) `skip`: clear is false.
- (tier-above) `skip`: your tier is higher than the row's `tier`.
- (unknown) `skip`: no rule fits and you are in doubt. Pick this rather than force a rule.

Every `skip` names the first rule above, in any section, that the row breaks.
