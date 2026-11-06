# Which board rows fleet-dispatch may start on its own

You are judging rows from project boards. A row you mark `dispatch` gets a new, unattended agent session that implements it, opens a PR and merges it, with nobody watching until it is done. Be conservative: when in doubt, skip. A skipped row costs nothing; a wrong dispatch wastes a session and can break a product.

A row carrying `#worker/<name>` was assigned to that unattended worker. An agent-lane row with no `#worker` tag was filed by an agent and nobody has checked it. Each row's `tier` is its `#tier/N` tag, or the highest tier allowed for it when it has none. Your job is to check that the row really is no higher than that tier, and clear and confined enough to run with nobody watching.

A row tagged `#requested` holds the human's own words or a plan they approved, and an agent assigned it after checking it. The ask is already decided, so do not skip it for wish wording ("ideally", "would be cool", "maybe"). Size, clarity, tier and every other skip below still apply, and a design choice the row leaves open still means skip.

## Tier

This section is the one definition of the tiers. Humans tagging rows, agents filing rows and the skill all point here.

- `1`: cannot break anything others depend on. Docs, copy and text, one contained bug fix or a new test in one product module.
- `2`: an ordinary product change in product code, a small feature or bug fix that the row fully describes.
- `3`: shared infrastructure. CI and workflows, test gates and test runners, the build, deploy or release pipeline, runner machines, agent harness and tooling (hooks, skills, scripts other sessions run), dependencies and version pins, schema or data migrations. Tier 3 never gets a merging session, whatever the row is tagged.
- Tier 3 may run unattended to an open PR only, as a `night` queue item, never past it (human decision 2026-11-02). A `red` item, a fix `fleet-bench triage` queued from a route, may open that PR at any hour; it still stops there (human decision 2026-11-06, timing only). `fleet-dispatch fill` promotes those rows from `tier3_only` below; your verdict for a tier 3 row is still `skip`.

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

- (tier3) Anything tier 3: CI, gates, test runners, builds, deploys, harness and tooling, dependencies. Including fixes to them, including "small" ones.
- (needs-person) Playtests, device, pad or headset runs, anything that needs a person to look, play or listen.
- (release) Store listings, releases, tags, signing keys, payments, purchases, pricing, ads.
- (prod-write) Production data or infrastructure writes: backfills, migrations run against prod, DNS, secrets, flipping a flag on in prod.
- (compliance) Anything touching health information, compliance, privacy or legal review.
- (question) Rows that start with `decide:` or ask a question, and wishes ("would be cool", "should i", "maybe", "ideally", "investigate whether"), unless the row is `#requested`.
- (design) Anything that needs a product or design decision the row does not already make.
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
