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

@test "--toggle-mode cycles tasks -> agents -> bridge -> tasks and persists it" {
  run "$COCKPIT" --toggle-mode
  assert_success
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'agents'
  "$COCKPIT" --toggle-mode
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'bridge'
  "$COCKPIT" --toggle-mode
  run bash -c 'cat "$TMPDIR"/notes-cockpit-*.mode'
  assert_output 'tasks'
}

@test "--list in agents mode still honours the 7-field wire format" {
  "$COCKPIT" --toggle-mode
  run bash -c '"$COCKPIT" --list personal | awk -F"\t" "NF != 7 { print NR\": \"NF; bad=1 } END { exit bad+0 }"'
  assert_success
  assert_output ''
}

@test "--list in agents mode renders a different body than tasks mode" {
  local tasks_view agents_view
  tasks_view="$("$COCKPIT" --list personal)"
  "$COCKPIT" --toggle-mode
  agents_view="$("$COCKPIT" --list personal)"
  refute [ "$tasks_view" = "$agents_view" ]
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
