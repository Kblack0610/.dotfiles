#!/usr/bin/env bats
# projects.sh -- Prefix+P, the projects switcher.
#
# integ tier: the script runs as a subprocess against the recording `notes` stub, so no test
# here reads or writes a vault. The picker itself is not driven (the fzf stub aborts); what
# is asserted is the data behind it (--list, --tasks, --header), the action each key maps to
# (--key), and the exact `notes` write each write verb issues.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PROJECTS_SH="$REPO_ROOT/.local/src/tmux/projects.sh"
  export PROJECTS_SH PANEL_NO_COLOR=1

  # Five projects across three profiles: one per stage plus an unstaged one, so the sort has
  # an order to get wrong, and a draft so the filter has something to drop. Two alphas with
  # different open counts pin the tie-break.
  printf '%s\n' \
    $'bnb\tsmall-alpha\talpha\tv1.0.0\t2\t0\t2\t0\t0\t0\t/v/small/README.md' \
    $'bnb\tbig-alpha\talpha\tv1.0.0\t9\t1\t5\t3\t4\t7\t/v/big/README.md' \
    $'personal\tidea\tdraft\tv0.0.1\t1\t0\t1\t0\t0\t0\t/v/idea/README.md' \
    $'longprofilename\twork\t\tv0.0.1\t3\t0\t3\t0\t0\t0\t/v/work/README.md' \
    $'personal\tsite\tprod\tv2.0.0\t0\t0\t0\t0\t0\t0\t/v/site/README.md' \
    >"$NOTES_FIXTURE/stats"

  # Task rows out of priority order, one in progress, one carrying a comment and a wave tag.
  printf '%s\n' \
    $'/v/big/README.md\t7\tlow one\t- [ ] low one #low #v1.0.0' \
    $'/v/big/README.md\t8\tplain\t- [ ] plain' \
    $'/v/big/README.md\t9\tfix (boss) [x]\t- [/] fix (boss) [x] #urgent <!-- since 2026-10-01 -->' \
    $'/v/big/README.md\t10\thigh one\t- [ ] high one #high' \
    >"$NOTES_FIXTURE/ptask.bnb.big-alpha"
}

# --- the row source -----------------------------------------------------------

@test "--list hides drafts and sorts prod, alpha by open count, then unstaged" {
  run bash -c "'$PROJECTS_SH' --list | cut -f2"
  assert_success
  assert_output $'site\nbig-alpha\nsmall-alpha\nwork'
}

@test "--list --drafts adds the draft last" {
  run bash -c "'$PROJECTS_SH' --list --drafts | cut -f2"
  assert_output $'site\nbig-alpha\nsmall-alpha\nwork\nidea'
}

@test "--list keeps the machine columns first, then the label search reads, then the counts" {
  run bash -c "'$PROJECTS_SH' --list | sed -n 2p | cut -f1-3"
  assert_output $'bnb\tbig-alpha\t/v/big/README.md'
  run bash -c "'$PROJECTS_SH' --list | awk -F'\t' '{print NF}' | sort -u"
  assert_output '5'
}

@test "a row shows its counts and leaves the zeros out" {
  run bash -c "'$PROJECTS_SH' --list | sed -n 2p | cut -f5"
  assert_output --partial '9 open  1 urgent  5 high  3 low  +4 planned  agent 7'
  run bash -c "'$PROJECTS_SH' --list | sed -n 3p | cut -f5"
  assert_output --partial '2 open  2 high'
  refute_output --partial 'urgent'
  refute_output --partial 'agent'
  run bash -c "'$PROJECTS_SH' --list | sed -n 1p | cut -f5"
  assert_output --partial 'clear'
}

@test "rows are numbered for the digit hotkeys and the profile is cut to fit" {
  run bash -c "'$PROJECTS_SH' --list | cut -f4"
  assert_line --index 0 --regexp '^1 site '
  assert_line --index 3 --regexp '^4 work +longprof$'
  refute_output --partial 'longprofilename'
  # ...but only on screen: column 1 goes to `notes --profile`, so it stays whole.
  run bash -c "'$PROJECTS_SH' --list | sed -n 4p | cut -f1"
  assert_output 'longprofilename'
}

@test "--tasks puts urgent first and strips the checkbox, tags and comment" {
  run bash -c "'$PROJECTS_SH' --tasks bnb big-alpha | cut -f4"
  assert_success
  assert_line --index 0 'urgent ~ fix (boss) [x]'
  assert_line --index 1 'high   high one'
  assert_line --index 2 'low    low one'
  assert_line --index 3 '       plain'
}

@test "--tasks keeps path, line and the CLI's key, which the write verbs match on" {
  run bash -c "'$PROJECTS_SH' --tasks bnb big-alpha | sed -n 1p | cut -f1-3"
  assert_output $'/v/big/README.md\t9\tfix (boss) [x]'
}

@test "--header counts the one project asked for" {
  run "$PROJECTS_SH" --header bnb big-alpha
  assert_output 'big-alpha v1.0.0  9 open  1 urgent  5 high  3 low  +4 planned  agent 7'
}

# --- keys -----------------------------------------------------------------------

@test "a letter is a hotkey while browsing and types itself while searching" {
  run "$PROJECTS_SH" --key list j
  assert_output 'down'
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key list j
  assert_output 'put(j)'
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key tasks x
  assert_output 'put(x)'
}

@test "Esc steps out one layer: the search box, then the filter, then the view" {
  FZF_INPUT_STATE=enabled FZF_QUERY=manor run "$PROJECTS_SH" --key tasks esc
  assert_output 'hide-input'
  # A filter to clear: show the input so the bind's bare clear-query can land...
  FZF_INPUT_STATE=hidden FZF_QUERY=manor run "$PROJECTS_SH" --key tasks esc
  assert_output 'show-input'
  # ...and esc-after hides it again; after a plain hide it leaves things alone.
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key tasks esc-after
  assert_output 'hide-input'
  FZF_INPUT_STATE=hidden run "$PROJECTS_SH" --key tasks esc-after
  assert_output 'ignore'
  FZF_INPUT_STATE=hidden run "$PROJECTS_SH" --key list esc
  assert_output 'abort'
}

@test "a digit jumps to that row and opens it, carrying the drafts state" {
  run "$PROJECTS_SH" --key list 3
  assert_output 'pos(3)+print(enter)+print(main)+accept'
  FZF_PROMPT='all projects> ' run "$PROJECTS_SH" --key list 3
  assert_output 'pos(3)+print(enter)+print(drafts)+accept'
}

@test "d toggles the drafts both ways" {
  run "$PROJECTS_SH" --key list d
  assert_output --partial 'change-prompt(all projects> )'
  assert_output --partial '--list --drafts)'
  FZF_PROMPT='all projects> ' run "$PROJECTS_SH" --key list d
  assert_output --partial 'change-prompt(projects> )'
  refute_output --partial '--drafts'
}

@test "a task write passes the row as a placeholder, never as spliced text" {
  run "$PROJECTS_SH" --key tasks x
  assert_output --partial '--task-done "$PROJECTS_P" "$PROJECTS_N" {3})'
  assert_output --partial 'transform-header('
}

@test "an unbound key does nothing" {
  run "$PROJECTS_SH" --key list z
  assert_output 'ignore'
}

# --- writes -------------------------------------------------------------------

@test "done with a proof passes it through" {
  run bash -c "printf 'pr:12\n' | '$PROJECTS_SH' --task-done bnb big-alpha 'fix (boss) [x]'"
  assert_success
  run grep -F 'ptask big-alpha done' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask big-alpha done --proof pr:12 fix (boss) [x]'
}

@test "done with no proof says so with --unverified rather than a bare done" {
  run bash -c "printf '\n' | '$PROJECTS_SH' --task-done bnb big-alpha 'plain'"
  run grep -F 'ptask big-alpha done' "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'done --unverified checked off by hand in the projects popup plain'
}

@test "archive needs a y, and anything else writes nothing" {
  run bash -c "printf 'n\n' | '$PROJECTS_SH' --archive bnb big-alpha"
  run grep -c -F -- '--archive' "$NOTES_FIXTURE/calls.log"
  assert_output '0'
  run bash -c "printf 'y\n' | '$PROJECTS_SH' --archive bnb big-alpha"
  run grep -F -- '--archive' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb projects --archive big-alpha'
}

@test "add takes the text then a priority, and tags it" {
  # A picker that answers instead of aborting, ahead of the sandbox's stub on PATH.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ncat >/dev/null\necho urgent\n' >"$BATS_TEST_TMPDIR/bin/fzf"
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash -c "printf 'new thing\n' | '$PROJECTS_SH' --task-add bnb big-alpha"
  run grep -F 'ptask big-alpha add' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask big-alpha add new thing #urgent'
}

@test "move offers the profile's other projects and moves by --project" {
  printf '%s\n' $'big-alpha\t/s\t\tv1' $'small-alpha\t/s\t\tv1' >"$NOTES_FIXTURE/projects.bnb"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Records what it was offered, then picks the first offer.
  printf '#!/bin/sh\ntee "%s/offered" | head -1\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/fzf"
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$PROJECTS_SH" --task-move bnb big-alpha 'plain'
  assert_success
  run cat "$BATS_TEST_TMPDIR/offered"
  assert_output 'small-alpha'
  run grep -F 'ptask big-alpha move' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb ptask big-alpha move --project small-alpha plain'
}

# --- the panel contract ---------------------------------------------------------

@test "--help prints the header, keys included" {
  run "$PROJECTS_SH" --help
  assert_success
  assert_output --partial 'Verbs:'
  assert_output --partial 'Keys, task view:'
  refute_output --partial '#!'
}

@test "an unknown verb is rejected, not treated as the picker" {
  run "$PROJECTS_SH" --nope
  assert_failure
  assert_output --partial 'unknown verb'
}
