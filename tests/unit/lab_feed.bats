#!/usr/bin/env bats
# lab-feed.sh is the ONE parser for a project's release feed, read by two surfaces that
# used to disagree: the cockpit's project rows (Prefix+t) and `lab/projects/index.md`
# (Prefix+H). The index half was broken for months and nobody could see it, because an
# index that cannot resolve a version and an index with nothing to report both print `—`.
#
# So these tests assert EXACT values, never "not empty". The failure mode this file exists
# to catch is a parser that returns a plausible-looking nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$LAB_FEED_LIB"
  PROJ="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$PROJ"
}

# mk_summary <project> — body on stdin
mk_summary() {
  mkdir -p "$PROJ/$1"
  cat > "$PROJ/$1/summary.md"
}

# mk_sheet <project> — body on stdin
mk_sheet() {
  mkdir -p "$PROJ/$1"
  cat > "$PROJ/$1/README.md"
}

# f <n> <project> [file] — field n of the project's fields line
f() {
  lab_feed_fields "$PROJ/$1/${3:-summary.md}" | cut -f"${2}"
}

# ── the whole row, for a project that has everything ─────────────────────────

seed_alpha() {
  mk_summary alpha <<'S'
# alpha
<!-- nextup:auto -->
## Next
- [ ] Implement Done group visibility #ai
- [ ] a second thing
<!-- /nextup:auto -->

<!-- STATUS:START -->
_2026-07-28_ — v1.11.0 open on v1.10.0. A second sentence that must not reach the row.
<!-- STATUS:END -->

<!-- AUTO:START -->
**shipped `alpha-v1.10.0`** (2026-07-18)

**Shipping next** — merged to `develop` since `alpha-v1.10.0`:
- fix: one
- fix: two

**In progress** (tracker):
- Area: a ticket
- Area: another ticket

**In flight** (open PRs)
- #1093 docs: a doc
<!-- AUTO:END -->
S
  mk_sheet alpha <<'S'
# alpha
Version: v1.11.0
S
}

@test "a full feed resolves all eight fields" {
  seed_alpha
  assert_equal "$(f alpha 1)" 'v1.10.0'                          # shipped
  assert_equal "$(f alpha 2)" '2'                                # to ship
  assert_equal "$(f alpha 3)" '2'                                # tickets
  assert_equal "$(f alpha 4)" '1'                                # PRs
  assert_equal "$(f alpha 5)" 'Implement Done group visibility'  # next
  assert_equal "$(f alpha 6)" 'v1.11.0 open on v1.10.0'          # status
  assert_equal "$(f alpha 7)" '2026-07-18'                       # shipped date
  assert_equal "$(f alpha 8)" '2026-07-28'                       # status date
}

@test "the sheet's open version is NOT a field" {
  # `notes projects` column 4 owns it (projects.rs::open_version), and that rule has a
  # fallback this file cannot see: no `Version:` line means the next patch above the
  # highest recorded version. alpha's sheet says v1.11.0 and no field carries it — a
  # consumer that wants the open version asks the CLI, so there is only ever one answer.
  # Exact-line match, not substring: alpha's STATUS narrative legitimately MENTIONS
  # v1.11.0 ("v1.11.0 open on v1.10.0"), so a substring grep would pass for the wrong
  # reason. What must not exist is a FIELD whose whole value is the sheet's version.
  seed_alpha
  local hits
  hits="$(lab_feed_fields "$PROJ/alpha/summary.md" | tr '\t' '\n' | grep -cx 'v1.11.0' || true)"
  assert_equal "$hits" '0'
}

@test "the row is exactly eight fields even when the project has nothing" {
  # The empty-field case is the one that breaks a consumer: `IFS=$'\t' read` collapses a
  # run of tabs, so a project with no next-up item shifts every later field left.
  mk_summary bare <<'S'
# bare
just prose, never lab-synced.
S
  assert_equal "$(lab_feed_fields "$PROJ/bare/summary.md" | awk -F'\t' '{print NF}')" '8'
  assert_equal "$(f bare 1)" ''
  assert_equal "$(f bare 2)" '0'
}

@test "the counts are read from the file, not invented" {
  # The negative control: a SECOND project with different numbers must produce different
  # output. A parser that returned a constant would pass every assertion above.
  seed_alpha
  mk_summary beta <<'S'
<!-- AUTO:START -->
**shipped `beta-v0.4.2`** (2026-01-02)

**Shipping next** — merged since `beta-v0.4.2`:
- feat: only one

**In flight** (open PRs)
- #1 a
- #2 b
- #3 c
<!-- AUTO:END -->
S
  assert_equal "$(f beta 1)" 'v0.4.2'
  assert_equal "$(f beta 2)" '1'
  assert_equal "$(f beta 3)" '0'
  assert_equal "$(f beta 4)" '3'
  assert_equal "$(f beta 7)" '2026-01-02'
  # and alpha still reads as alpha
  assert_equal "$(f alpha 2)" '2'
  assert_equal "$(f alpha 4)" '1'
  assert_equal "$(f alpha 7)" '2026-07-18'
}

# ── version ──────────────────────────────────────────────────────────────────

@test "the product prefix is stripped from a monorepo tag" {
  mk_summary gamma <<'S'
<!-- AUTO:START -->
**shipped `gamma-v1.10.0`** (2026-07-18)
<!-- AUTO:END -->
S
  assert_equal "$(f gamma 1)" 'v1.10.0'
}

@test "the REPO-LESS version line resolves a version, not just a git tag" {
  # A lab project with frozen versions and no repo behind it states the same fact in a
  # different sentence. Reading only the `shipped` shape is why every personal project
  # rendered blank.
  mk_summary delta <<'S'
<!-- AUTO:START -->
**`delta` · v0.0.1** — _(no git tag resolved)_
<!-- AUTO:END -->
S
  assert_equal "$(f delta 1)" 'v0.0.1'
}

@test "a bare version with no tag and no date still resolves" {
  mk_summary eps <<'S'
<!-- AUTO:START -->
**shipped `v2.0.0`**
<!-- AUTO:END -->
S
  assert_equal "$(f eps 1)" 'v2.0.0'
  assert_equal "$(f eps 7)" ''
}

# ── counts ───────────────────────────────────────────────────────────────────

@test "an elided ticket list reports the REAL total, not the visible rows" {
  # `- …(+10 more)` is itself a bullet. Counting it as a ticket AND adding its number is
  # an off-by-one in the only direction nobody would catch: the total still looks plausible.
  mk_summary zeta <<'S'
<!-- AUTO:START -->
**In progress** (tracker):
- Area: one
- Area: two
- …(+10 more)
<!-- AUTO:END -->
S
  assert_equal "$(f zeta 3)" '12'
}

@test "a section that is present but empty counts zero" {
  mk_summary eta <<'S'
<!-- AUTO:START -->
**shipped `v2.0.0`** (2026-07-18)

**Shipping next** — merged since:

**In flight** (open PRs)
S
  assert_equal "$(f eta 1)" 'v2.0.0'
  assert_equal "$(f eta 2)" '0'
  assert_equal "$(f eta 4)" '0'
}

# ── the sheet model ──────────────────────────────────────────────────────────

@test "handed a project SHEET, the feed is read from the sibling summary" {
  # `notes projects` returns README.md for a sheet-model project; lab-sync writes the feed
  # into summary.md beside it. Without the hop every such project reads as having no feed.
  mk_summary theta <<'S'
<!-- AUTO:START -->
**shipped `v3.1.0`** (2026-05-05)

**In flight** (open PRs)
- #7 a pr
<!-- AUTO:END -->
S
  mk_sheet theta <<'S'
# theta
Version: v3.2.0
S
  assert_equal "$(f theta 1 README.md)" 'v3.1.0'
  assert_equal "$(f theta 4 README.md)" '1'
}

# ── what is next ─────────────────────────────────────────────────────────────

@test "next falls back to the sheet when there is no nextup block" {
  mk_summary iota <<'S'
<!-- AUTO:START -->
**shipped `v1.0.0`** (2026-02-02)
<!-- AUTO:END -->
S
  mk_sheet iota <<'S'
# iota
Version: v1.1.0

## Wave: v1.1.0 (current)
- [ ] wire the thing to the other thing #high
- [ ] a later thing
S
  assert_equal "$(f iota 5)" 'wire the thing to the other thing'
}

@test "an empty checkbox is a placeholder, not the next task" {
  # Live sheets end with a bare `- [ ]` somebody left behind. Rendering it as the project's
  # direction is worse than rendering nothing.
  mk_summary kappa <<'S'
# kappa
S
  mk_sheet kappa <<'S'
- [ ]
- [ ] the real next task
S
  assert_equal "$(f kappa 5)" 'the real next task'
}

@test "a checked item is never next" {
  mk_summary lambda <<'S'
# lambda
S
  mk_sheet lambda <<'S'
- [x] already done
- [ ] not done
S
  assert_equal "$(f lambda 5)" 'not done'
}

@test "a long next item is truncated at a word boundary" {
  mk_summary mu <<'S'
# mu
S
  mk_sheet mu <<'S'
- [ ] Mobile client: FairEmail / Thunderbird-for-Android, decided later
S
  # Not "Thunderbird-for-Andro..." (reads as a rendering bug) and not "FairEmail /..."
  # (a dangling separator reads as a broken string).
  assert_equal "$(f mu 5)" 'Mobile client: FairEmail...'
}

@test "a single unbreakable word is hard-cut rather than dropped" {
  mk_summary nun <<'S'
# nun
S
  mk_sheet nun <<'S'
- [ ] aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
S
  local got; got="$(f nun 5)"
  assert_equal "${#got}" '51'          # 48 chars + the ASCII '...' marker
  assert_equal "${got: -3}" '...'
}

# ── the status narrative ─────────────────────────────────────────────────────

@test "the STATUS placeholder is not a status" {
  mk_summary nu <<'S'
<!-- STATUS:START -->
_(no status yet)_
<!-- STATUS:END -->
S
  assert_equal "$(f nu 6)" ''
  assert_equal "$(f nu 8)" ''
}

@test "only the first sentence of the narrative reaches the row" {
  mk_summary xi <<'S'
<!-- STATUS:START -->
_2026-07-28_ — the first sentence. the second one.
<!-- STATUS:END -->

<!-- AUTO:START -->
**`xi` · v0.0.1** — _(no git tag resolved)_
<!-- AUTO:END -->
S
  assert_equal "$(f xi 6)" 'the first sentence'
  assert_equal "$(f xi 7)" ''            # nothing shipped, so no shipped date
  assert_equal "$(f xi 8)" '2026-07-28'
}

@test "the shipped date and the narrative's date are kept apart" {
  # The live shape this was found in: a feed saying v9.0.0 shipped in August, next to
  # prose written in January still claiming v1.8.15 is live. Collapsing the two dates is
  # what let the stale sentence pass for current.
  mk_summary omicron <<'S'
<!-- STATUS:START -->
_2026-01-01_ — v1.8.15 live.
<!-- STATUS:END -->

<!-- AUTO:START -->
**shipped `v9.0.0`** (2026-08-01)
<!-- AUTO:END -->
S
  assert_equal "$(f omicron 1)" 'v9.0.0'
  assert_equal "$(f omicron 6)" 'v1.8.15 live'
  assert_equal "$(f omicron 7)" '2026-08-01'
  assert_equal "$(f omicron 8)" '2026-01-01'
}

# ── the gist, which is what the cockpit rows render ──────────────────────────

@test "lab_feed_gist joins only the parts that have something to say" {
  seed_alpha
  run lab_feed_gist "$PROJ/alpha/summary.md"
  assert_output 'shipped v1.10.0, 2 to ship, 2 open, 1 PR'
}

@test "lab_feed_gist is silent for a project with no feed" {
  mk_summary pi <<'S'
# pi
prose only.
S
  run lab_feed_gist "$PROJ/pi/summary.md"
  assert_success
  assert_output ''
}

@test "lab_feed_gist is silent on a missing file" {
  run lab_feed_gist "$BATS_TEST_TMPDIR/nope.md"
  assert_success
  assert_output ''
}

@test "lab_feed_gist survives a row with empty text fields" {
  # The collapse bug from the consumer's side: rho has no next-up item and no status, so
  # its row carries adjacent tabs. Read with tab as IFS those collapse, the counts arrive
  # as prose, and the arithmetic errors out instead of printing a row.
  mk_summary rho <<'S'
<!-- AUTO:START -->
**shipped `v5.0.0`** (2026-06-06)

**In flight** (open PRs)
- #1 a
- #2 b
<!-- AUTO:END -->
S
  run lab_feed_gist "$PROJ/rho/summary.md"
  assert_success
  assert_output 'shipped v5.0.0, 2 PRs'
}

# ── the plural landmine ──────────────────────────────────────────────────────
#
# These two must be run from a `set -e` CALLER, not through bats' `run`. The whole point
# is a status that only propagates when -e is active: `run` swallows it, which is why the
# 1-PR case above ("joins only the parts that have something to say", via seed_alpha) has
# been passing all along while the same input killed the private regen script outright.
#
# `bash -e -c` is the harness because it is what the real callers are — regen-lab-feed.sh
# and regen-project-index.sh both open with `set -euo pipefail`.

# gist_under_e <file> — source the lib and call the gist from a `set -e` shell.
gist_under_e() {
  bash -e -c '. "$1"; lab_feed_gist "$2"' _ "$LAB_FEED_LIB" "$1"
}

@test "lab_feed_gist survives a set -e caller at exactly one open PR" {
  # The landmine. `PR$([ "$prs" -gt 1 ] && printf s)` exits 1 at prs==1, the assignment
  # carries that status, and -e kills the caller — emitting NOTHING, so the row reads as
  # "no feed" rather than as a failure. One PR is the single arming value: zero
  # short-circuits on the preceding `[`, two or more make `printf s` succeed.
  mk_summary sigma <<'S'
<!-- AUTO:START -->
**shipped `v5.0.0`** (2026-06-06)

**In flight** (open PRs)
- #1 a
<!-- AUTO:END -->
S
  run gist_under_e "$PROJ/sigma/summary.md"
  assert_success
  assert_output 'shipped v5.0.0, 1 PR'
}

@test "lab_feed_gist under a set -e caller pluralises from two PRs up" {
  # The control that proves the test above is testing the arming value and not just
  # "does it run": same shell, same path, one more PR.
  mk_summary tau <<'S'
<!-- AUTO:START -->
**shipped `v5.0.0`** (2026-06-06)

**In flight** (open PRs)
- #1 a
- #2 b
<!-- AUTO:END -->
S
  run gist_under_e "$PROJ/tau/summary.md"
  assert_success
  assert_output 'shipped v5.0.0, 2 PRs'
}

@test "lab_feed_gist under a set -e caller is silent, not fatal, with no feed" {
  # The other end of the same class: zero PRs takes the short-circuit path, which must
  # also not trip -e. Silence here is the correct answer and must arrive as exit 0.
  mk_summary upsilon <<'S'
# upsilon
prose only.
S
  run gist_under_e "$PROJ/upsilon/summary.md"
  assert_success
  assert_output ''
}
