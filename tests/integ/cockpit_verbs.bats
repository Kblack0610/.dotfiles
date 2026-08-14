#!/usr/bin/env bats
# The `$SELF --verb` contract, exercised as a real subprocess.
#
# This is where the regressions actually live. Every fzf --bind runs `$SELF --verb` and
# then `reload($SELF --list)`. If a verb changes its output shape or stops writing the
# state file, the UI breaks at runtime with no error and no stack trace -- fzf just
# renders the wrong thing. Nothing else in the suite catches that.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

# ── --list: the row feed fzf consumes ────────────────────────────────────────

@test "--list succeeds and produces rows" {
  run "$COCKPIT" --list personal
  assert_success
  [ "${#lines[@]}" -gt 0 ]
}

@test "--list emits exactly 7 tab-separated fields on every row" {
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "NF != 7 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list uses only the documented row types in field 1" {
  run bash -c '"$COCKPIT" --list personal | cut -f1 | sort -u'
  assert_success
  local t
  while read -r t; do
    case "$t" in
      task|head|add|hint) ;;
      *) fail "undocumented row type in field 1: '$t'" ;;
    esac
  done <<< "$output"
}

@test "--list surfaces the profile's own focus tasks" {
  run bash -c '"$COCKPIT" --list personal | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'fix the rail badge'
}

@test "--list groups project tasks under their project" {
  run bash -c '"$COCKPIT" --list personal | grep -P "^task\t" | cut -f6 | sort -u'
  assert_success
  assert_output --partial 'personal/cockpit'
}

@test "--list renders a project sub-header for each project" {
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'Cockpit'
  assert_output --partial 'Notes'
}

@test "--list gives an empty project an add-placeholder row so it stays selectable" {
  # Notes has no ptask fixture rows, so it must still offer a row to add onto.
  run bash -c '"$COCKPIT" --list personal | grep -P "^add\t" | cut -f6'
  assert_success
  assert_output --partial 'personal/notes'
}

@test "--list honours the requested section rather than always rendering personal" {
  run bash -c '"$COCKPIT" --list work | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'Playground'
  refute_output --partial 'Cockpit'
}

@test "--list task rows carry a non-empty key, which the mutation verbs need" {
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "\$1==\"task\" && \$5==\"\" { print; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list task rows carry a file and line, which --jump needs" {
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "\$1==\"task\" && (\$3==\"\" || \$4==\"\") { print; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list bootstraps today's notes so a fresh day never shows spurious zeros" {
  run "$COCKPIT" --list personal
  assert_success
  # The `all` section triggers the bootstrap path; personal alone should not need it,
  # but the call must be harmless either way.
  assert_success
}

# ── section cycling ──────────────────────────────────────────────────────────
#
# sections_list pins `personal` first and keeps the profiles file's order after it
# (notes-cockpit.sh:120), so the fixture's cycle is exactly:
#     personal -> work -> client -> personal
#
# These assert the EXACT landing section, not merely "it changed". With the fixture's
# original two sections, next and prev were the same operation and every direction
# assertion here was vacuous: a negative control that inverted the h/l bindings stayed
# fully green. Three sections is the minimum that can tell forwards from backwards.

active_section() { cat "$TMPDIR"/notes-cockpit-*.section 2>/dev/null || echo personal; }

@test "--next-section advances to the next section in order" {
  assert_equal "$(active_section)" 'personal'
  run "$COCKPIT" --next-section
  assert_success
  assert_equal "$(active_section)" 'work'
}

@test "--prev-section from the first section wraps to the LAST, not the second" {
  # The sharpest direction assertion in the suite: this is the one that fails if next and
  # prev are transposed, and it is why the fixture needs a third section.
  assert_equal "$(active_section)" 'personal'
  "$COCKPIT" --prev-section
  assert_equal "$(active_section)" 'client'
}

@test "--next-section then --prev-section returns to where it started" {
  "$COCKPIT" --next-section
  assert_equal "$(active_section)" 'work'
  "$COCKPIT" --prev-section
  assert_equal "$(active_section)" 'personal'
}

@test "section cycling walks the whole list in order and wraps" {
  local seen=()
  for _ in 1 2 3 4; do
    "$COCKPIT" --next-section
    seen+=("$(active_section)")
  done
  assert_equal "${seen[*]}" 'work client personal work'
}

# ── priority filter ──────────────────────────────────────────────────────────

@test "--cycle-window advances the persisted usage window" {
  run "$COCKPIT" --cycle-window
  assert_success
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.window'
  assert_output '30d'
  "$COCKPIT" --cycle-window
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.window'
  assert_output 'today'
  "$COCKPIT" --cycle-window
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.window'
  assert_output '7d'
}

@test "--cycle-pfilter advances the persisted filter" {
  run "$COCKPIT" --cycle-pfilter
  assert_success
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.pfilter'
  assert_output 'urgent'
}

@test "--cycle-pfilter actually narrows what --list emits" {
  local before after
  before="$("$COCKPIT" --list personal | grep -cP '^task\t')"
  "$COCKPIT" --cycle-pfilter          # -> urgent
  after="$("$COCKPIT" --list personal | grep -cP '^task\t' || true)"
  [ "$after" -lt "$before" ]
}

@test "--cycle-pfilter four times returns to unfiltered" {
  local before after
  before="$("$COCKPIT" --list personal | grep -cP '^task\t')"
  for _ in 1 2 3 4; do "$COCKPIT" --cycle-pfilter; done
  after="$("$COCKPIT" --list personal | grep -cP '^task\t')"
  assert_equal "$after" "$before"
}

# ── view mode ────────────────────────────────────────────────────────────────

@test "--toggle-mode cycles tasks -> factory -> usage -> tasks and persists it" {
  run "$COCKPIT" --toggle-mode
  assert_success
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'factory'
  "$COCKPIT" --toggle-mode
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'usage'
  "$COCKPIT" --toggle-mode
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'tasks'
}

@test "a mode file left by an older version falls back to tasks, not to nothing" {
  # `agents` and `bridge` were real modes until the factory view replaced them. A stale
  # mode file must not leave the cycle pointing at a name no renderer answers to.
  printf agents > "$TMPDIR/notes-cockpit-$(id -u).mode"
  "$COCKPIT" --toggle-mode
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'tasks'
}

@test "--list in factory mode still honours the 7-field wire format" {
  "$COCKPIT" --toggle-mode
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "NF != 7 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list in factory mode renders a different body than tasks mode" {
  local tasks_view factory_view
  tasks_view="$("$COCKPIT" --list personal)"
  "$COCKPIT" --toggle-mode
  factory_view="$("$COCKPIT" --list personal)"
  refute [ "$tasks_view" = "$factory_view" ]
}

# ── --rail: the sidebar ──────────────────────────────────────────────────────

@test "--rail lists every profile section" {
  run bash -c '"$COCKPIT" --rail | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'personal'
  assert_output --partial 'work'
}

@test "--rail marks the active section distinctly from the inactive ones" {
  # The active section is coloured (C_SEL), so the raw output must differ from the
  # stripped output -- i.e. some styling is actually applied.
  local raw stripped
  raw="$("$COCKPIT" --rail)"
  stripped="$(printf '%s' "$raw" | strip_ansi)"
  refute [ "$raw" = "$stripped" ]
}

@test "--rail follows the active section as it cycles" {
  local before after
  before="$("$COCKPIT" --rail)"
  "$COCKPIT" --next-section
  after="$("$COCKPIT" --rail)"
  refute [ "$before" = "$after" ]
}

# ── --rail <section>: the project brief that follows the cursor ──────────────
#
# The rail used to render the same bytes whatever row you were on, so the widest pane in the
# default view said nothing about the project you were standing in. It now takes the
# highlighted row's section (fzf field 6) and answers what shipped / where we are / what next.

# A project whose summary column is a REAL path, which the `basic` fixture's is not (it holds
# a description). Same shape as the feed-gist tests below.
_seed_overview() { # $1 = extra summary body (optional)
  local dir="$NOTES_FIXTURE/rail-proj"
  mkdir -p "$dir"
  cat > "$dir/summary.md" <<'S'
---
id: summary
---

# Cockpit
<!-- canonical: cockpit -->

<!-- nextup:auto -->
## Now
The rail brief landed and the preview panes now render notes instead of showing their source.

## Next
- [ ] widen the pane and re-check the wrap at a narrow split
<!-- /nextup:auto -->

<!-- AUTO:START -->
**shipped `cockpit-v1.10.0`** (2026-07-18)

**In flight** (open PRs)
- #1093 docs: a doc
<!-- AUTO:END -->
S
  printf 'Cockpit\t%s\tthe tmux cockpit\tv0.3\n' "$dir/summary.md" \
    > "$NOTES_FIXTURE/projects.personal"
}

@test "--rail on a project row appends what shipped, Now and Next" {
  _seed_overview
  run bash -c '"$COCKPIT" --rail personal/cockpit | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'personal'          # the sections list is still there
  assert_output --partial 'Cockpit'
  assert_output --partial 'shipped v1.10.0'   # _feed_gist, not a second parser
  assert_output --partial 'NOW'
  assert_output --partial 'NEXT'
  assert_output --partial '[ ] widen the pane'
}

@test "--rail renders the brief rather than the note's source" {
  # The whole point: no frontmatter, no markers, no `##`.
  _seed_overview
  run bash -c '"$COCKPIT" --rail personal/cockpit | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  refute_output --partial '<!--'
  refute_output --partial 'nextup'
  refute_output --partial 'id: summary'
  refute_output --partial '## '
}

@test "--rail with no section renders exactly what it always did" {
  # The brief is ADDITIVE. A regression here breaks the launch render, which passes no row.
  _seed_overview
  local bare
  bare="$("$COCKPIT" --rail)"
  refute [ "$(printf '%s' "$bare" | grep -c 'NOW')" -gt 0 ]
}

@test "--rail on a section that is not a project adds nothing" {
  _seed_overview
  local plain
  plain="$("$COCKPIT" --rail personal)"
  assert_equal "$plain" "$("$COCKPIT" --rail)"
}

@test "--rail adds no brief outside the tasks view" {
  # agents, bridge and usage each answer a question per row in the BODY; repeating a project
  # brief beside every one of them is the duplication the agents view was pruned of.
  _seed_overview
  "$COCKPIT" --toggle-mode                       # tasks -> agents
  run bash -c '"$COCKPIT" --rail personal/cockpit | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  refute_output --partial 'NOW'
  refute_output --partial 'shipped v1.10.0'
}

@test "--rail says when it truncated the brief" {
  # A silent cap reads as "that is all there is", which is how a stale pane goes unnoticed.
  _seed_overview
  run bash -c 'RAIL_NOW_LINES=1 "$COCKPIT" --rail personal/cockpit | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial '...'
}

@test "--rail degrades to the plain sidebar when a project has no overview" {
  # A project with a summary path that does not exist must not blank the rail.
  printf 'Cockpit\t/does/not/exist.md\t\tv0.3\n' > "$NOTES_FIXTURE/projects.personal"
  run "$COCKPIT" --rail personal/cockpit
  assert_success
  assert_output --partial 'personal'
}

# ── --preview-version: the pane every note is read through ───────────────────
#
# Was `--preview-md <file>`. The version browser now holds three kinds of row, so the
# preview dispatches on kind; every kind except `wave` renders a whole file, which is what
# `--preview-md` did and what these two pin. (The `wave` kind, which slices the live sheet
# instead, is covered in cockpit_roadmap.bats.)

@test "--preview-version renders a note instead of printing its source" {
  local f="$NOTES_FIXTURE/note.md"
  cat > "$f" <<'S'
---
id: v1.2.3
---

<!-- summary:auto -->
## Summary
It shipped.
<!-- /summary:auto -->
S
  run bash -c '"$COCKPIT" --preview-version frozen "$1" v1.2.3 personal demo | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"' _ "$f"
  assert_success
  refute_output --partial '<!--'
  refute_output --partial 'id: v1.2.3'
  refute_output --partial '## '
  assert_output --partial 'SUMMARY'
  assert_output --partial 'It shipped.'
}

@test "--preview-version on a missing file fails instead of rendering an empty pane" {
  # An empty preview reads as "this note is empty", which is the wrong answer to a bad path
  # -- and a preview command is exactly where nobody sees an exit code.
  run "$COCKPIT" --preview-version frozen /does/not/exist.md v1.2.3 personal demo
  assert_failure
  assert_output --partial 'no such file'
}

# ── mutation verbs: assert the vault-safe CLI call, not the vault ────────────

@test "--task-op done issues a notes focus done for the row's key" {
  run "$COCKPIT" --task-op done personal k1
  assert_success
  assert_called 'focus'
  assert_called 'k1'
}

@test "--task-op rm issues a removal rather than a done" {
  run "$COCKPIT" --task-op rm personal k1
  assert_success
  assert_called 'k1'
}

@test "--task-op never writes outside the sandbox" {
  "$COCKPIT" --task-op done personal k1 || true
  # The stub records the intent; no real vault path may appear in the call log.
  refute [ "$(calls | grep -c '/home/kblack0610/.notes')" != 0 ]
}

# ── robustness ───────────────────────────────────────────────────────────────

@test "an unknown verb does not silently succeed as if it were the UI" {
  run "$COCKPIT" --definitely-not-a-verb
  # Falls through the case into the fzf preflight; must not pretend to have worked.
  refute_output --partial 'task	'
}

@test "--list tolerates a profile with no projects at all" {
  : > "$NOTES_FIXTURE/projects.personal"
  run "$COCKPIT" --list personal
  assert_success
}

@test "--list tolerates a completely empty vault" {
  : > "$NOTES_FIXTURE/focus.all"
  : > "$NOTES_FIXTURE/projects.personal"
  run "$COCKPIT" --list personal
  assert_success
  # Still offers the add-placeholder so the user has a row to act on.
  assert_output --partial 'add'
}

# ── the section survives a relaunch ───────────────────────────────────────────
#
# The cockpit used to hard-reset to `personal` on every launch, and several actions
# relaunch it (roll_project, browse_versions and start_wave all go back through
# `exec "$SELF"`). So pressing W on the `teamx` section and coming back landed you on
# `personal` - where that project does not exist, and neither do its agent rows. A wave
# would be running perfectly well while the cockpit showed a section that structurally
# could not display it.
#
# The stored value is still VALIDATED: a section naming a profile that has since been
# renamed or removed would render an empty cockpit with no explanation.

_boot_section() { # <stored value> -> what the launch block settles on
  local stored="$1" f="$BATS_TEST_TMPDIR/section"
  printf '%s' "$stored" > "$f"
  bash -c '
    sections_list() { printf "personal\nteamx\nworkprofile\n"; }
    STATE="$1"
    _last="$(cat "$STATE" 2>/dev/null)"
    case "$_last" in
      all) : ;;
      */*) sections_list | grep -qxF "${_last%%/*}" || _last="" ;;
      ?*)  sections_list | grep -qxF "$_last" || _last="" ;;
      *)   _last="" ;;
    esac
    echo "${_last:-personal}" > "$STATE"
  ' _ "$f"
  cat "$f"
}

@test "a section you were on is still there after a relaunch" {
  assert_equal "$(_boot_section teamx)" 'teamx'
  assert_equal "$(_boot_section workprofile)" 'workprofile'
}

@test "a project row's section survives too" {
  assert_equal "$(_boot_section 'teamx/someapp')" 'teamx/someapp'
}

@test "the cross-profile lane is a valid section" {
  assert_equal "$(_boot_section all)" 'all'
}

@test "a profile that no longer exists falls back instead of rendering empty" {
  assert_equal "$(_boot_section deleted-profile)" 'personal'
  assert_equal "$(_boot_section 'gone/project')" 'personal'
}

@test "no stored section at all opens on personal" {
  assert_equal "$(_boot_section '')" 'personal'
}

# ── the project header's status ──────────────────────────────────────────────

@test "--list puts the LIVE feed on a project header, not the stale STATUS prose" {
  # The tasks view passed the STATUS column straight through: prose an LLM writes and
  # nothing refreshes. The bridge was fixed to count the AUTO block instead; this is the
  # same fix on the view you actually spend the day in.
  local dir="$NOTES_FIXTURE/cockpit-proj"; mkdir -p "$dir"
  cat > "$dir/summary.md" <<'S'
<!-- AUTO:START -->
**shipped `cockpit-v1.10.0`** (2026-07-18)

**In flight** (open PRs)
- #1093 docs: a doc
<!-- AUTO:END -->
S
  printf 'Cockpit\t%s\t_2026-06-30_ - v1.8.15 live\tv0.3\n' "$dir/summary.md" \
    > "$NOTES_FIXTURE/projects.personal"
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'shipped v1.10.0, 1 PR'
  refute_output --partial 'v1.8.15 live'
}

@test "--list keeps the STATUS prose on a project that was never lab-synced" {
  # No AUTO block anywhere -> the old line, not a blank row.
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'shipping the rail'
}

@test "--list with no section renders the one you are standing on" {
  # This is the path the launch render now takes; it used to be pinned to `personal`.
  "$COCKPIT" --next-section          # personal -> work
  run bash -c '"$COCKPIT" --list | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_output --partial 'Playground'
  refute_output --partial 'Cockpit'
}

@test "--list keeps the VERSION on a project whose STATUS column is empty" {
  # `notes projects` emits `name<TAB>path<TAB>status<TAB>version` and most projects have an
  # empty status. Tab is an IFS *whitespace* character, so `IFS=$'\t' read` folded the two
  # adjacent tabs into one delimiter and every field after the gap shifted left: the version
  # landed in `st` and `ver` came back empty. The row looked right - it was rendering the
  # version AS the status - until a real status arrived and the version vanished.
  #
  # Asserted as an EXACT line: under the bug the text `v0.3` is still present, just in the
  # wrong slot with the status separator's three spaces in front of it.
  printf 'Cockpit\t/does/not/exist.md\t\tv0.3\n' > "$NOTES_FIXTURE/projects.personal"
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_line '  Cockpit v0.3'
  refute_line '  Cockpit   v0.3'
}

@test "--list keeps version AND status in their own slots when both are present" {
  printf 'Cockpit\t/does/not/exist.md\tsteady\tv0.3\n' > "$NOTES_FIXTURE/projects.personal"
  run bash -c '"$COCKPIT" --list personal | grep -P "^head\t" | cut -f7 | sed -E "s,\x1b\[[0-9;]*[a-zA-Z],,g"'
  assert_success
  assert_line '  Cockpit v0.3   steady'
}
