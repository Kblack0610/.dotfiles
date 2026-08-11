---
name: consolidate
description: Logic implemented N ways that wants one shared home
cap: 6
applies-to: any
---

# Recipe: consolidate

Find the things this repo does more than one way, and give each of them one home. Lower cap than `cleanup` because these items are judgement-heavy and touch more files each.

The failure mode this recipe exists for is not ugliness, it is **silent divergence**. Two copies of a rule do not fail when they disagree - they each keep working, on different answers, and which one you get depends on which caller you came in through. That is only discovered later and by surprise.

## Discovery

**Repeated invocation recipes** - the highest-yield probe, and the one no dedup tool finds, because the copies are not textually identical. Pick the handful of external commands and hot internal helpers this repo leans on, and count the distinct ways each is called.

```bash
rg -n 'gh (pr|run) (view|list|checks)' --stats     # CLI recipes
rg -n 'curl -s.*api'                               # hand-rolled API calls
rg -n '<internal-helper-name>'
```

A hit means: N call sites each parsing the same output with their own flags. Compare the flags and the parsing, not just the count - the interesting finding is that they **already disagree** (one checks `mergedAt`, another checks `state`, a third adds a git-graph proof). Say so in the item; that is what makes it worth doing.

**A shared helper that exists and is bypassed** - the strongest possible finding, because the destination is already written and the change is a deletion.

```bash
# for each lib/util in the shared location, who sources it vs who reimplements it
ls lib/ packages/*/src/                            # the shared homes
rg -n 'source .*<lib>|from .*<lib>|require.*<lib>' # who uses it
```

A hit means: a helper exists, and some callers hand-roll it anyway. Propose the bypass sites, naming the helper.

**Duplicated constants and thresholds** - the same magic value, or worse, two values for one concept.

```bash
rg -n '<the-url>|<the-timeout>|<the-path>' --stats
```

Two *different* values for one concept is a bug, not a cleanup - propose it high, and say both values in the item.

**Copy-pasted blocks**

```bash
jscpd --min-lines 8 --reporters console    # if present
```

Treat its output as a lead, not a finding. Most of what it reports is coincidental shape (config literals, test scaffolds). Only propose a block that encodes a **rule** - something that would need changing in both places when the rule changes.

**Structural near-copies of a document or config** - two skills, agents or manifests where one is the other with nouns swapped. Diff them and count how much is genuinely distinct; under about a third means the copy should inherit rather than restate.

## Item shape

Name what is duplicated, how many copies, and where it should live. The destination is what makes it a task rather than an observation.

Good:

```
move the PR-merged check into lib/agent-merge-proof.sh; 4 call sites disagree today #ai
route the 3 hand-rolled vikunja curls through the ticket CLI #ai
fold the stall threshold constant into one place; it is 30min in one file and 45 in another #ai
make wave-overseer inherit sprint-overseer instead of restating 130 lines #ai
```

Bad:

```
reduce duplication #ai                        <- no target, no destination
extract a shared util #ai                     <- which logic, into where
dedupe the tests #ai                          <- test scaffolding SHOULD repeat
```

**What not to propose.** Test setup, fixtures and config literals are allowed to repeat - forcing them behind a helper makes tests read worse and couples cases that should stay independent. Two things that look alike but change for different reasons are not duplication, and merging them is the mistake this recipe would otherwise cause. If you cannot name the single rule both copies encode, leave it.
