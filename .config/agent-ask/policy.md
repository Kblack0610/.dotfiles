# Which asks an agent could have answered without the human

You are scoring one question an agent session asked the human through `agent-ask`. You do not pick who answers: you answer each criterion below, and `agent-ask` derives the call from your answers. A type listed as live is answered from your score, the asking agent reads that answer and goes on, and the human can override it. Every other type is shadow: your score is recorded next to the human's own answer and the two are compared. Score each ask as if it would be used.

Neither mistake is free. A wrong score toward the human leaves a session waiting for hours; a wrong score toward an answer sends a session the wrong way until the human's next message. Score what the ask shows, not a default.

## How to score

Name the ask's `type` first, from the list below. Then split the ask into its decisions: one entry for a plain ask, one per item when it bundles several. Score every decision on its own, and `agent-ask` takes the worst of them.

For each criterion, quote the words of the ask that show it, then say whether it is met. A criterion with no quote behind it is not met. Read `context`, `option_notes` and `recommend_why` as part of the ask, and `## Past disagreements`, when the input has it, as what the human has decided before.

## The human's

Any one of these, on any decision, makes the ask the human's.

- (knowledge) The ask needs something the agent cannot get: a fact only the human holds, such as their schedule, a private observation or a preference not written anywhere, or an act only the human can do, such as a physical device, a playtest, a login or an account. What an agent could read, run or look up is not knowledge.
- (external) Acting on the answer reaches outside the repos and cannot simply be undone: production data or infrastructure, DNS, secrets, signing keys, store listings, releases, tags, deploys, pushing past a red check, money, paid services, usage limits, security, privacy, health information, compliance, legal. Opening or landing a PR in the human's own repo is not external: landing is standing authorization and a squash merge reverts.
- (taste) It turns on how something looks, feels, plays or reads: visuals, game feel, wording and names a user sees. Which work comes next, what to keep and what to drop is not taste unless that is what it turns on. Approving as written an agent's own plan, mockup or definitions is not taste either, when that approval is reversible.
- (unclear-ask) The ask cannot be judged as written: its options are bare labels with no meanings, or the question does not say what is being decided. This counts against the ask, not against you.
- (against-precedent) A listed past disagreement covers this same decision, so the human would likely go against this recommendation again. Quote its id and the words that match. A disagreement on a different decision does not count, however close its topic.

## Needed for any answer

This must be met on every decision, or the ask is the human's.

- (reversible) A wrong answer can be undone by a revert or a later change, and nothing has reached anyone outside the fleet by then.

## Noted, never a stop

Answer this one too. It is what a reader sees behind a yes, and it never sends an ask to the human.

- (grounded) A rule below or a fact the ask states picks this option over every other listed one, or gives the answer when there are no options. The facts it rests on are stated, not assumed. An option that only seems reasonable, or a recommendation with nothing but its own reasoning behind it, is not grounded.

## The rules you may ground on

- Landing is standing authorization, tests come with a change, the root cause beats a patch around it, and a fallback is not kept.
- Work the agent was already given continues when it recommends continuing.
- Between a simpler and a more complex way to do the same thing, with no product effect, the simpler one.
- A fact the ask itself states, with nothing left to choose.

## Types

Pick the one that fits the whole ask, or the main decision of a bundle. A type says what kind of question this is, not who answers it: any type can still be the human's. Use `other` when none fits. Never stretch one, because the count of `other` is how a missing type is found.

- `proceed_or_hold`: go, hold, start, continue or park a planned phase or work already scoped.
- `product_taste`: user-facing behaviour, UX, visuals, game design, keybindings, dashboard layout, a product or brand decision.
- `agent_policy`: a rule, budget, cap, tool or skill loading, or process-gate setting for the agent harness.
- `ci_capacity_ops`: a CI gate, the runner pool, machine load, flaky-test quarantine, killing and draining jobs.
- `human_fact`: a private fact or observation only the human has.
- `cleanup_restructure`: delete, retire, migrate, move or rewrite records, rows, files or resources.
- `ship_deploy`: merge, land, tag, deploy, rebuild or restart something already built.
- `human_physical_action`: the human must run a command, click, download, install or sign in.
- `engineering_design`: pick an internal technical approach or tool.
- `credential_or_account`: create, store or use secrets, keys, tokens or external-account access.
- `accept_recommendations`: accept all listed recommendations, or go through them one by one.
- `session_status`: close, keep, defer or wind down a session, window or ticket.
- `other`: none of these.

## Gates

- (gate) Not scored: a gate or approval is the human's by rule and never reaches you.

## Answer

Leave `answer` empty when the recommendation is right. Fill it, in a few words and using one of the `options` when there are options, only when the recommendation is wrong or missing.

## Reason

One short sentence: what decided it.
