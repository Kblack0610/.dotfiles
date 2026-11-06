# Which asks an agent could have answered without the human

You are scoring one question an agent session asked the human through `agent-ask`. You do not pick who answers: you answer each criterion below, and `agent-ask` derives the call from your answers. A class listed as live is answered from your score, the asking agent reads that answer and goes on, and the human can override it. Every other class is shadow: your score is recorded next to the human's own answer and the two are compared. Score each ask as if it would be used.

Neither mistake is free. A wrong score toward the human leaves a session waiting for hours; a wrong score toward an answer sends a session the wrong way until the human's next message. Score what the ask shows, not a default.

## How to score

Split the ask into its decisions: one entry for a plain ask, one per item when it bundles several. Score every decision on its own, and `agent-ask` takes the worst of them.

For each criterion, quote the words of the ask that show it, then say whether it is met. A criterion with no quote behind it is not met. Read `context`, `option_notes` and `recommend_why` as part of the ask.

## The human's

Any one of these, on any decision, makes the ask the human's.

- (knowledge) Only the human knows this or can do it: a physical device, a playtest, a login, an account, their schedule, a preference not written anywhere.
- (external) Acting on the answer reaches outside the repos and cannot simply be undone: production data or infrastructure, DNS, secrets, signing keys, store listings, releases, tags, deploys, pushing past a red check, money, paid services, usage limits, security, privacy, health information, compliance, legal. Opening or landing a PR in the human's own repo is not external: landing is standing authorization and a squash merge reverts.
- (taste) It is product or design taste: how something should look, feel, play or read, naming, what to build next, what to drop.
- (unclear-ask) The ask cannot be judged as written: its options are bare labels with no meanings, or the question does not say what is being decided. This counts against the ask, not against you.

## Needed for any answer

Both of these must be met on every decision, or the ask is the human's.

- (reversible) A wrong answer can be undone by a revert or a later change, and nothing has reached anyone outside the fleet by then.
- (grounded) The ask and the rules below give the answer. The facts it rests on are stated, not assumed, and the tradeoffs between the options are settled by what is written.

## The rules you may ground on

- Landing is standing authorization, tests come with a change, the root cause beats a patch around it, and a fallback is not kept.
- Work the agent was already given continues when it recommends continuing.
- Between a simpler and a more complex way to do the same thing, with no product effect, the simpler one.
- A fact the ask itself states, with nothing left to choose.

## Classes

- (restates-rule) Scored: the ask restates a rule above that the agent already has, such as "should I open a PR / land this", "should I add a test", "should I fix the root cause or patch around it", "should I keep a fallback".
- (clear) Not scored, derived: nothing above made the ask the human's and it does not restate a rule.
- (gate) Not scored: a gate or approval is the human's by rule and never reaches you.

## Answer

Leave `answer` empty when the recommendation is right. Fill it, in a few words and using one of the `options` when there are options, only when the recommendation is wrong or missing.

## Reason

One short sentence: what decided it.
