---
name: harden
description: Untested paths, unchecked failures, and gates that pass on empty input
cap: 6
applies-to: any
---

# Recipe: harden

Coverage where its absence would actually cost something. Not a coverage-percentage chase: a repo can be 90% covered and still have every one of its failure paths untested, because failure paths are the hard ones to write.

Bias every probe toward **recently changed** and **blast-radius** code. Untested code that has not moved in a year is not the risk; untested code three sessions touched last week is.

## Discovery

**Recently changed, still untested**

```bash
git log --since='6 weeks ago' --name-only --pretty=format: | sort | uniq -c | sort -rn | head -30
```

For each hot file, look for a sibling test. A hit means: the code most likely to be wrong is the code nothing checks. Weight by what the file does - a formatter is not a payment path.

**Unchecked failures** - the language's own quiet-failure shape.

```bash
rg -n 'catch\s*\([^)]*\)\s*\{\s*\}|catch.*\{\s*//' --stats   # swallowed exceptions
rg -n '\.unwrap\(\)|\.expect\(' --stats                       # Rust panics
rg -n '\|\| true|2>/dev/null' --stats                         # shell: errors discarded
rg -n 'set -e' --files-without-match --glob '*.sh'            # shell: no error exit at all
```

A hit means: a failure that cannot surface. `|| true` and `2>/dev/null` are often correct and deliberate (this repo's own libs use them to keep a timer-driven daemon alive on an expected-empty case) - the finding is one with **no comment saying why**.

**A gate that passes on empty input** - the specific failure this system keeps hitting, and always worth a probe. Any check that iterates a list and reports success: what does it do when the list is empty? A linter given no files, a test runner matching no tests, a verifier handed no rows. Each reports a clean pass, indistinguishable from having actually checked something.

```bash
rg -n 'for .* in .*; do' --glob '*.sh' -A3 | rg -B1 'exit 0|PASS|ok'
```

A hit is an item when the surrounding gate has no "refuse an empty list" guard.

**Error paths with no test** - for each module's tests, count cases asserting success vs asserting a specific failure. A test file with zero failure assertions is the finding, and it is a common one.

**A test that cannot fail** - the worst thing this probe can find, because it counts as coverage while checking nothing. Look for: no assertion at all, an assertion on a value the test itself computed, a `skip` that is always taken, a cyclic/list check with fewer than 3 fixture elements. Propose these ahead of any missing-test item; a wrong signal is worse than no signal.

## Item shape

Name the surface and the specific case, not a coverage number. Done means the test exists and you have watched it fail against the unfixed code.

Good:

```
test the three failure paths of the release preflight; today only the happy path is covered
give the board reader a negative control; the cyclic test passes on a 1-element fixture
handle the swallowed catch in api/src/jobs/fanout.ts and cover the retry
make the lint gate refuse an empty file list instead of reporting pass
```

Bad:

```
increase test coverage to 80%        <- a number, not a behaviour
add tests                            <- unbounded
write e2e for the app                <- a project, not a wave item
```

**Every item on this recipe carries the negative-control requirement**: a new test is not done until it has been observed failing against the unfixed code. A test that cannot fail is not a test, and this recipe is the one most able to mass-produce them.
