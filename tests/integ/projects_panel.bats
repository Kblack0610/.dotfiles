#!/usr/bin/env bats
# projects.sh -- Prefix+p, the projects finder.
#
# integ tier: the script runs as a subprocess against the recording `notes` stub, so no test
# here reads or writes a vault. The picker itself is not driven (the fzf stub aborts); what
# is asserted is the data behind it (--list), the action each key maps to (--key), the exact
# `notes` write each write verb issues, the hub request Enter makes (--board) and the hub
# call the preview makes (--preview).

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

@test "a row is the summary: stage, open and urgent; the rest is the preview's" {
  run bash -c "'$PROJECTS_SH' --list | sed -n 2p | cut -f5"
  assert_output ' alpha  9 open  1 urgent'
  run bash -c "'$PROJECTS_SH' --list | sed -n 3p | cut -f5"
  assert_output ' alpha  2 open'
  run bash -c "'$PROJECTS_SH' --list | sed -n 1p | cut -f5"
  assert_output ' prod   clear'
  # Unstaged keeps the column, so the counts stay lined up.
  run bash -c "'$PROJECTS_SH' --list | sed -n 4p | cut -f5"
  assert_output '        3 open'
}

@test "rows are numbered for the digit hotkeys and show the name only" {
  run bash -c "'$PROJECTS_SH' --list | cut -f4"
  assert_line --index 0 --regexp '^1 site +$'
  assert_line --index 3 --regexp '^4 work +$'
  refute_output --partial 'longprof'
  # ...but only on screen: column 1 goes to `notes --profile`, so it stays whole.
  run bash -c "'$PROJECTS_SH' --list | sed -n 4p | cut -f1"
  assert_output 'longprofilename'
}

# --- keys -----------------------------------------------------------------------

@test "a letter is a hotkey while browsing and types itself while searching" {
  run "$PROJECTS_SH" --key list j
  assert_output 'down'
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key list j
  assert_output 'put(j)'
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key list x
  assert_output 'put(x)'
}

@test "Esc steps out one layer: the search box, then the filter, then the view" {
  FZF_INPUT_STATE=enabled FZF_QUERY=manor run "$PROJECTS_SH" --key list esc
  assert_output 'hide-input'
  # A filter to clear: show the input so the bind's bare clear-query can land...
  FZF_INPUT_STATE=hidden FZF_QUERY=manor run "$PROJECTS_SH" --key list esc
  assert_output 'show-input'
  # ...and esc-after hides it again; after a plain hide it leaves things alone.
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key list esc-after
  assert_output 'hide-input'
  FZF_INPUT_STATE=hidden run "$PROJECTS_SH" --key list esc-after
  assert_output 'ignore'
  FZF_INPUT_STATE=hidden run "$PROJECTS_SH" --key list esc
  assert_output 'abort'
}

@test "a digit jumps to that row and opens it" {
  run "$PROJECTS_SH" --key list 3
  assert_output 'pos(3)+print(enter)+accept'
  run "$PROJECTS_SH" --key list enter
  assert_output 'print(enter)+accept'
}

@test "o opens the project on the hub Board like Enter, e opens its sheet in the hub editor" {
  run "$PROJECTS_SH" --key list o
  assert_output 'print(enter)+accept'
  run "$PROJECTS_SH" --key list e
  assert_output 'print(edit)+accept'
  # Searching, both letters type themselves.
  FZF_INPUT_STATE=enabled run "$PROJECTS_SH" --key list e
  refute_output --partial 'accept'
}

@test "d toggles the drafts both ways" {
  run "$PROJECTS_SH" --key list d
  assert_output --partial 'change-prompt(all projects> )'
  assert_output --partial '--list --drafts)'
  FZF_PROMPT='all projects> ' run "$PROJECTS_SH" --key list d
  assert_output --partial 'change-prompt(projects> )'
  refute_output --partial '--drafts'
}

@test "an unbound key does nothing" {
  run "$PROJECTS_SH" --key list z
  assert_output 'ignore'
}

# --- writes -------------------------------------------------------------------

@test "archive needs a y, and anything else writes nothing" {
  run bash -c "printf 'n\n' | '$PROJECTS_SH' --archive bnb big-alpha"
  run grep -c -F -- '--archive' "$NOTES_FIXTURE/calls.log"
  assert_output '0'
  run bash -c "printf 'y\n' | '$PROJECTS_SH' --archive bnb big-alpha"
  run grep -F -- '--archive' "$NOTES_FIXTURE/calls.log"
  assert_output 'notes --profile bnb projects --archive big-alpha'
}

@test "--board asks the hub for its Board searched to the project, then goes to its window" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for c in hub tmx; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$c" "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/$c"
    chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$PROJECTS_SH" --board bnb big-alpha
  assert_success
  run cat "$BATS_TEST_TMPDIR/calls"
  assert_output $'hub tab projects bnb/big-alpha\ntmx goto hub hub:board'
}

@test "--preview prints the hub's card for the project at the preview's width" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "COLUMNS=$COLUMNS hub $*"\n' >"$BATS_TEST_TMPDIR/bin/hub"
  chmod +x "$BATS_TEST_TMPDIR/bin/hub"
  FZF_PREVIEW_COLUMNS=61 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$PROJECTS_SH" --preview bnb big-alpha
  assert_success
  assert_output 'COLUMNS=61 hub --once --tab projects bnb/big-alpha'
}

@test "--preview without hub says so and succeeds, so the pane is never an error" {
  local d nohub=''
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do [ -x "$d/hub" ] || nohub="$nohub:$d"; done
  PATH="${nohub#:}" run "$PROJECTS_SH" --preview bnb big-alpha
  assert_success
  assert_output --partial 'hub not on PATH'
}

@test "the task verbs are gone: the hub Board is the one task view" {
  for v in --tasks --header --task-add --task-move --task-done; do
    run "$PROJECTS_SH" "$v" bnb big-alpha
    assert_failure
    assert_output --partial 'unknown verb'
  done
}

# --- the panel contract ---------------------------------------------------------

@test "--help prints the header, keys included" {
  run "$PROJECTS_SH" --help
  assert_success
  assert_output --partial 'Verbs:'
  assert_output --partial 'hub Projects'
  assert_output --partial '--preview'
  assert_output --partial 'hub notes editor'
  refute_output --partial '#!'
}

@test "an unknown verb is rejected, not treated as the picker" {
  run "$PROJECTS_SH" --nope
  assert_failure
  assert_output --partial 'unknown verb'
}
