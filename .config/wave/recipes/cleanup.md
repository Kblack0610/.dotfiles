---
name: cleanup
description: Dead code, unused deps, version mismatches, stale paths and debt markers
cap: 8
applies-to: any
---

# Recipe: cleanup

Things the repo is carrying that nothing uses. The findings are cheap to verify and cheap to review, which is what makes this a good first wave on a project nobody has swept in a while.

## Discovery

Run what applies; skip any probe whose tool is absent (see the hard rules in `README.md`).

**Dead exports and unreferenced files** - the biggest single source of items.

```bash
knip --reporter json                 # JS/TS monorepos; the authoritative one
cargo +nightly udeps --all-targets   # Rust
```

No such tool? Fall back to a reference count on the public surface: for each exported symbol in a package's entry point, `rg -w '<symbol>'` across the repo and treat one hit (its own definition) as unreferenced. Slow and noisier, so cap it to the one or two packages most likely to have drifted.

A hit means: the symbol/file is reachable from no entry point. **Verify before proposing** - a symbol used only by tests, only by a generated file, or re-exported through a barrel will show as unused and is not. Public API of a published package is never dead by this test.

**Unused and mismatched dependencies**

```bash
syncpack list-mismatches       # the same dep pinned differently across workspaces
knip --dependencies            # declared in package.json, imported nowhere
cargo tree --duplicates
```

A hit means: either a dep to drop, or two versions of one library in the tree. Mismatches are the better item - they are a real class of bug (two copies of a context/allocator) and the fix is mechanical.

**Stale paths in docs and config** - the failure this whole repo keeps hitting: a path moved, nothing errored, and the doc kept pointing at where it used to be.

```bash
# every path-shaped string in docs/config, checked for existence
rg -oN --no-filename '(\./|~/)[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+' \
   --glob '*.md' --glob '*.json' --glob '*.y*ml' \
  | sort -u | while read -r p; do [ -e "${p/#\~/$HOME}" ] || echo "MISSING $p"; done
```

A hit means: a doc, config key or script references something that is not there.

The two anchors do the real work. Requiring a `./` or `~/` prefix **and** at least two path segments is what makes this probe usable: the obvious version (any `/`-prefixed word) matches prose like "PR /556.md" and buries one real finding in a hundred. Run on this repo, the tightened form returns a single hit and it is a true one - `README.md` telling Mac users to run `installation_scripts/mac/install.sh`, which is named `install_mac.sh`. Nothing errored when it was renamed, and nothing ever will.

Still eyeball the output for URLs, glob patterns and deliberate example placeholders.

**Debt markers with an owner**

```bash
rg -n 'TODO|FIXME|HACK|XXX' --stats
git log -S'TODO' --oneline -1 -- <file>    # how old is this one
```

A hit is only an item when the marker names something actionable and specific. A two-year-old `// TODO: refactor` is not an item, it is a comment to delete. Prefer markers that describe a known-wrong behaviour.

**Commented-out code blocks** - three or more consecutive commented code lines. Almost always safe to delete and almost never worth a human's attention, so it makes a good filler item when the cap is not full.

## Item shape

One line, imperative, naming the place and the count. Group by location so a wave item is one coherent sub-branch, not a scatter.

Good:

```
drop 4 unused exports from packages/ui/src/index.ts #ai
align the two react versions in apps/web and packages/ui #ai
fix 6 dead paths in docs/operations/ runbooks #ai
delete the commented-out legacy auth block in api/src/middleware/session.ts #ai
```

Bad:

```
remove dead code #ai                 <- no location, no scope, never done
clean up TODOs #ai                   <- unbounded
upgrade react to 19 #ai              <- a major bump, not maintenance; out of scope
```

Grouping rule: one item per **file or package**, not one per symbol. Four unused exports in one file is one item; four unused exports across four packages is four items, and probably too many for one wave - take the two worst and say so.
