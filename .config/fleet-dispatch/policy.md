# Which board rows fleet-dispatch may start on its own

You are judging rows from project boards. A row you mark `dispatch` gets a new, unattended agent session that implements it, opens a PR and merges it, with nobody watching until it is done. Be conservative: when in doubt, skip. A skipped row costs nothing; a wrong dispatch wastes a session and can break a product.

A row carrying `#worker/<name>` was assigned to that unattended worker. An agent-lane row with no `#worker` tag was filed by an agent and nobody has checked it. Each row's `tier` is its `#tier/N` tag, or the highest tier allowed for it when it has none.

A row's kind is its type prefix (`fix(area):` and so on), and `kinds.json` beside this file routes each kind. Rows of a kind it turns off, epics, and parent rows whose children are still open never reach you: today that is `decide`, `epic`, `design`, `legal` and `market`, which go to the human or, once enabled, to a session that drafts a doc and files an ask (its `propose` rung), never to one that merges. `research` is enabled on that rung, so its rows do reach you.

A row that comes with `size` carries that size as its own `#size/` tag. Use it as the size; do not judge the size again.

A row tagged `#requested` holds the human's own words or a plan they approved, and an agent assigned it after checking it. The ask is already decided, so do not skip it for wish wording ("ideally", "would be cool", "maybe"). Size, clarity, tier and every other skip below still apply, and a design choice the row leaves open still means skip.

## Tier

This section is the one definition of the tiers. Humans tagging rows, agents filing rows and the skill all point here.

- `1`: cannot break anything others depend on. Docs, copy and text, one contained bug fix or a new test in one product module.
- `2`: an ordinary product change in product code, a small feature or bug fix that the row fully describes.
- Tiers 1 and 2 merge on your `dispatch`. Measure: reverts and CI reds of the merged sessions (`fleet-bench` scorecard). Revisit when a merged tier 1 or 2 session is reverted.
- `3`: shared infrastructure. CI and workflows, test gates and test runners, the build, deploy or release pipeline, runner machines, agent harness and tooling (hooks, skills, scripts other sessions run), dependencies and version pins, schema or data migrations. Judge a tier 3 row like any other: a `dispatch` sends it to the tier-3 gate below, never to a plain merge. A queue item on agent-runtime or notes-cockpit with no tier counts as tier 3, so an item a session queued by hand gets the same gate.
- Tier-3 gate: a `red` item (a fix `fleet-bench triage` queued from a route) and a tier 3 row you `dispatch` of any project at stage `dev` or later, run at any hour and merge their own PR behind the red-fix gate (fix-red step 5): `/code-review high` with a `Review:` line in the PR body and the bats files the Stop hook picks for the change, then `agent-land`, which refuses a tier-3 PR without that line or without checks that ran green. Only the human-merge list never starts unattended: release cuts, secrets and auth, and production data migrations (`DISPATCH_T3_SKIP`, ask BwiKfB 2026-11-21), plus money rows and every row of a project that stays with the human, finance (`DISPATCH_T3_HUMAN_PROJECTS`). A row whose `#after` gates cleared starts without a verdict, so the gate takes it only with a `#tier/3` tag. A cleanup row (`kinds.json` `cleanup`: `fix`, `chore`, a `refactor` that deletes, removes, drops, retires, prunes or strips) on agent-runtime or notes-cockpit ranks first. Measure: `fleet-bench reds` (each merged red fix `fixed`, `still red` or `came back`), and per merged tier-3 item whether a check green at the merge SHA is red after it; a check already red at the merge is not that merge's regression. Revisit when one merge turns a green check red, or when `reds_unfixed` on `fleet-bench chain` is above 0.

Judge the tier from what the change touches, not from the tag. A row tagged `#tier/1` that changes a test gate is tier 3.

Each row comes with its project's stage, its lane and its tagged tier:

- `human` lane: the human's own sheet. Many rows there are only for the human.
- `agent` lane: follow-ups agents filed for agents. Not always concrete or agent-sized.

## Stage

- `prod` (live users): bugs and small fixes only. No new features, no flags turned on, nothing touching production data.
- `beta`: bugs, and small features that are fully described in the row.
- `alpha`: judged as `beta`; `too-big` and `unclear` decide size and clarity, not the stage.
- (stage) The row is more than its project's stage allows above.

## Always skip

A skip does not park a row: `fleet-dispatch` gives each agent-lane skip the exit its rule names (`skip_exits`), so pick the rule that names the real blocker.
- plan: `unclear`, `bundle`, `too-big`, `multi-area`, `stage`, `question`, `tier-above` and `unknown` tag the row `#plan`, and inbox-plan splits or rewrites it.
- human: `needs-person`, `release`, `prod-write`, `compliance`, `personal` and `design` move the row off the agent lane: an `#urgent`, `#high`, bare or `#requested` row to the human sheet, a `#low` one to `improvements.md`.
- `waits`: an `#after/<row>` or `#pr/<owner>/<repo>/<N>` gate on the row or PR your reason names, when the row otherwise fits; else plan. Name the row id or `owner/repo#N` in the reason when you know it.

- (needs-person) Playtests, device, pad or headset runs, anything that needs a person to look, play or listen.
- (release) Releases, tags, signing keys, payments, purchases. A store listing, pricing or ads change is `market` work, which a merging session never does.
- (prod-write) Production data or infrastructure writes: backfills, migrations run against prod, DNS, secrets, flipping a flag on in prod.
- (compliance) Anything touching health information, compliance or privacy. A legal review is `legal` work, which a merging session never does.
- (question) Rows that ask a question, and wishes ("would be cool", "should i", "maybe", "ideally", "investigate whether"), unless the row is `#requested`.
- (design) Anything that needs a product or design decision the row does not already make: that decision is `design` work, which a merging session never does.
- (personal) Anything about the human's personal machine or personal config.
- (bundle) Rows that bundle several tasks, or that are long lists of things to check.
- (multi-area) Rows spanning more than one area (see Fields).
- (waits) Rows that wait on something else, such as "after agent-24 PR lands" or "after feat/x lands". The queue holds the row on an `after` or `pr:` gate until that lands, so name what it waits on.

## Size

- `S`: one focused change a session can finish, test and merge in about an hour, in one place, with the change described in the row.
- `M`: several files or steps in one area, or some investigation first, that a session can still finish in an afternoon.
- `L`: a feature, a system, or open-ended work.
- (too-big) The row is size `L`.

## Fields

- `tier`: your own reading of the row's tier, 1, 2 or 3, from what the change touches.
- `area`: the one game or system the change stays in, as one lowercase word, so two sessions never work on the same one. Use the row's own prefix when it names one (`wilds`, `dodginballs`, `skyline`, `fx`, `perf`), otherwise the game or system it names, spelled as the directory under `Assets/Games` (`shapecity`, `apociseum`). Empty when it spans several.
- `clear`: true only if the row says what done looks like, so the session would not need to ask anything.
- `agent_only`: true only if no step needs the human (see Always skip).
- `verdict`: `dispatch` only when size is `S` or `M`, clear is true, agent_only is true, area is one word and your tier is no higher than the row's `tier`. Otherwise `skip`.
- `reason`: one short sentence a human can scan, naming the deciding fact.
- `rule`: the id, written without its parentheses (`stage`, never `(stage)`), of the one rule that decided the verdict, from the rules below and above.

## Rules for the verdict

- (fits) `dispatch`: every field above allows it.
- (unclear) `skip`: clear is false.
- (tier-above) `skip`: your tier is higher than the row's `tier`.
- (unknown) `skip`: no rule fits and you are in doubt. Pick this rather than force a rule.

Every `skip` names the first rule above, in any section, that the row breaks.
