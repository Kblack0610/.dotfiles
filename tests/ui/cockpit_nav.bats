#!/usr/bin/env bats
# Tier 3: drive the cockpit through a REAL tmux server and assert on the rendered grid.
#
# Deliberately NOT a popup. `tmux display-popup` requires an attached client and its
# contents are unreadable by capture-pane even when one exists (see tmux_harness.bash).
# The popup is a one-line binding in .tmux.conf; this runs the same script as an ordinary
# pane command, which is the part that can actually break.
#
# Every assertion goes through wait_until. There are no bare sleeps: a bare capture-pane
# immediately after starting a pane returns an empty screen, and the identical check
# passes ~100ms later.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
}

teardown() { ui_teardown; }

# Boot the cockpit and wait for first paint.
# Readiness is the SECTIONS rail, not a prompt: the cockpit launches with --no-input, so
# the `search >` prompt only exists after `i` opens the input.
start_cockpit() {
  tmux_start "$COCKPIT"
  wait_until 'screen_has "SECTIONS"'
}

# ── it renders at all ────────────────────────────────────────────────────────

@test "the cockpit paints its rail and key header" {
  start_cockpit
  wait_until 'screen_has "SECTIONS"'
  wait_until 'screen_has "enter open"'
  wait_until 'screen_has "? keys"'
}

@test "the cockpit renders the profile's tasks" {
  start_cockpit
  wait_until 'screen_has "fix the rail badge"'
}

@test "the cockpit renders project sub-headers" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  wait_until 'screen_has "Notes"'
}

@test "the sidebar rail lists every profile" {
  start_cockpit
  wait_until 'screen_has "personal"'
  wait_until 'screen_has "work"'
}

@test "no raw tab characters or wire-format fields leak into the display" {
  start_cockpit
  wait_until 'screen_has "fix the rail badge"'
  # fzf slices with --with-nth=7.., so fields 1-6 must never be visible.
  refute [ "$(screen | grep -c '^task')" != 0 ]
  refute [ "$(screen | grep -c '/vault/daily.md')" != 0 ]
}

# ── section cycling: h / l ───────────────────────────────────────────────────
#
# Direction is asserted by naming the section that must appear, never by "the screen
# changed". Each section's PROJECT sub-headers are unique to it and appear only in the body
# of the active section, so they identify it unambiguously:
#     personal -> Cockpit, Notes    work -> Playground    client -> Ingest
# Cycle order is personal -> work -> client -> personal (notes-cockpit.sh:120).
#
# The earlier versions of these two tests asserted only that the body changed, which a
# negative control proved blind: inverting the h/l bindings left them green, because the
# fixture had two sections and next/prev were therefore the same operation.

@test "l advances to the NEXT section, not the previous one" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  tmux_keys l
  wait_until 'screen_has "Playground"'    # work, the section after personal
  wait_until 'screen_lacks "Ingest"'      # NOT client, which is the one before it
}

@test "h retreats to the PREVIOUS section, wrapping to the last" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  tmux_keys h
  wait_until 'screen_has "Ingest"'        # client, wrapping backwards off personal
  wait_until 'screen_lacks "Playground"'  # NOT work, which is the one after it
}

@test "h and l are inverses" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  tmux_keys l
  wait_until 'screen_has "Playground"'
  tmux_keys h
  wait_until 'screen_has "Cockpit"'
  wait_until 'screen_lacks "Playground"'
}

@test "cycling reaches the work profile's own project" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  # Walk forward until the other profile's project shows up, or give up loudly.
  local found=0
  for _ in 1 2 3 4; do
    tmux_keys l
    if wait_until 'screen_has "Playground"' 2; then found=1; break; fi
  done
  [ "$found" = 1 ] || { dump_screen; fail "cycling never reached the work section"; }
}

# ── priority filter: p ───────────────────────────────────────────────────────

@test "p filters the view down to urgent tasks" {
  start_cockpit
  wait_until 'screen_has "fix the rail badge"'   # #urgent
  wait_until 'screen_has "tidy the sidebar"'     # untagged
  tmux_keys p
  wait_until 'screen_lacks "tidy the sidebar"'
  wait_until 'screen_has "fix the rail badge"'
}

@test "cycling p all the way round restores the unfiltered view" {
  start_cockpit
  wait_until 'screen_has "tidy the sidebar"'
  tmux_keys p; wait_until 'screen_lacks "tidy the sidebar"'
  tmux_keys p; tmux_keys p; tmux_keys p
  wait_until 'screen_has "tidy the sidebar"'
}

# ── view mode: a ─────────────────────────────────────────────────────────────

@test "a toggles from the tasks view into the agents view" {
  start_cockpit
  wait_until 'screen_has "fix the rail badge"'
  tmux_keys a
  wait_until 'screen_lacks "fix the rail badge"'
}

@test "a cycles all four views and returns to tasks" {
  # tasks -> agents -> bridge -> usage -> tasks (notes-cockpit.sh toggle_mode).
  start_cockpit
  wait_until 'screen_has "fix the rail badge"'
  tmux_keys a
  wait_until 'screen_lacks "fix the rail badge"'   # agents
  tmux_keys a
  wait_until 'screen_lacks "fix the rail badge"'   # bridge
  tmux_keys a
  wait_until 'screen_lacks "fix the rail badge"'   # usage
  wait_until 'screen_has "usage ·"'                # ...and it is REALLY the usage view:
                                                   # three `screen_lacks` in a row would
                                                   # pass on any view that merely lacks
                                                   # the task, including a broken render.
  tmux_keys a
  wait_until 'screen_has "fix the rail badge"'     # back to tasks
}

# ── modal input: i ───────────────────────────────────────────────────────────

@test "the input is hidden until i opens it" {
  start_cockpit
  wait_until 'screen_has "SECTIONS"'
  # --no-input at launch: no search prompt on screen yet.
  refute [ "$(screen | grep -c 'search >')" != 0 ]
  tmux_keys i
  wait_until 'screen_has "search >"'
}

@test "while searching, a nav key types instead of cycling the section" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  tmux_keys i
  wait_until 'screen_has "search >"'
  # `l` is a nav key in normal mode; in search mode it must be typed, not eat the section.
  tmux_type "l"
  wait_until 'screen_matches "search > *l"'
  wait_until 'screen_has "Cockpit"'
}

@test "escape leaves search mode and rebinds the nav keys" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  tmux_keys i
  wait_until 'screen_has "search >"'
  tmux_keys Escape
  # Wait for the input to actually hide before sending a nav key. The esc bind is a
  # transform that clears the query, hides the input and rebinds the modal keys; sending
  # `l` before that lands types it into the search box instead of cycling the section.
  wait_until 'screen_lacks "search >"'
  tmux_keys l
  wait_until 'screen_lacks "Cockpit"'
}

# ── help ─────────────────────────────────────────────────────────────────────

@test "? opens the help view" {
  start_cockpit
  wait_until 'screen_has "SECTIONS"'
  tmux_keys '?'
  wait_until 'screen_has "keys"'
}

# ── the rail's counts ────────────────────────────────────────────────────────

@test "the rail shows a per-section task count" {
  start_cockpit
  # personal has 3 focus tasks in the fixture, work has 1.
  wait_until 'screen_matches "personal"'
  wait_until 'screen_matches "3"'
  wait_until 'screen_matches "work"'
}

# ── it stays alive ───────────────────────────────────────────────────────────

@test "the cockpit survives a burst of navigation without dying" {
  start_cockpit
  wait_until 'screen_has "Cockpit"'
  local k
  for k in j j k l h p p j a a; do tmux_keys "$k"; done
  # Still painting the rail: the process did not crash out of fzf.
  wait_until 'screen_has "SECTIONS"'
}

# ── the launch render ────────────────────────────────────────────────────────

@test "the cockpit opens on the section it was left on, rail and body agreeing" {
  # The launch was pinned to `list_section personal` while the rail preview -- and every
  # `reload($SELF --list)` after the first keypress -- followed $STATE. So relaunching on
  # any other section opened with the sidebar pointing at one section and the body listing
  # another, and the two surfaces openly disagreed about where you were standing. Every
  # action that re-execs the cockpit (V, o, g, W) comes back through this render.
  #
  # Asserted on the BODY, which is the half that was wrong: `Playground` is a project of
  # `work` and appears only inside `work`'s listing.
  printf 'work' > "$TMPDIR/notes-cockpit-${UID:-$(id -u)}.section"
  start_cockpit
  wait_until 'screen_has "Playground"'
  wait_until 'screen_lacks "Cockpit"'   # personal's project — what the body used to show
}
