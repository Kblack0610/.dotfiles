#!/usr/bin/env bats
# Tier 3: tags.sh against a REAL tmux server.
#
# This has to be the ui tier. A tag IS tmux state - a window user-option - so there is
# nothing to assert against a stub: `set-option -w` and `show-options -w` are the storage
# layer, and faking them would only test the fake.
#
# The `protected` verb is the reason this file matters most. wind-down.sh:174 asks it what
# NOT to kill. It fails OPEN: has_tag on a missing option is simply false, so any drift
# between the tag a user sets and the option `protected` reads means a pinned window is
# reaped anyway, on a timer, silently.
#
# (cleanup.sh and stale-detector.sh were the other two consumers. Both were deleted once it
# turned out they were reachable only from launcher.sh and dashboard.sh, which were
# themselves bound only by commented-out lines in .tmux.conf. The kill path that survives
# is wind-down.sh.)

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1

  TAGS="$REPO_ROOT/.local/src/tmux/tags.sh"
  # tags.sh calls plain `tmux`, so the -S shim scopes both it and us to one private server.
  tmux_start "sleep 600"
  # A second and third window, so filters have something to exclude. No `-t <session>`:
  # that resolves to index 0, which window 0 already holds ("index 0 in use"). Bare
  # new-window takes the next free index in the current session, which is what we want.
  _tm new-window -d "sleep 600"
  _tm new-window -d "sleep 600"
  mapfile -t WIN < <(_tm list-windows -a -F '#{window_id}')
}

teardown() { ui_teardown; }

# ── round trip ───────────────────────────────────────────────────────────────

@test "add then get returns the tag" {
  "$TAGS" add important -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"
  assert_success
  assert_output --partial 'important'
}

@test "a tag lands on the addressed window only" {
  "$TAGS" add important -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[1]}"
  refute_output --partial 'important'
}

@test "two tags coexist on one window" {
  "$TAGS" add important -t "${WIN[0]}"
  "$TAGS" add pinned    -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"
  assert_output --partial 'important'
  assert_output --partial 'pinned'
}

@test "toggle sets then unsets" {
  "$TAGS" toggle pinned -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"; assert_output --partial 'pinned'
  "$TAGS" toggle pinned -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"; refute_output --partial 'pinned'
}

@test "rm drops one tag and leaves the others" {
  "$TAGS" add important -t "${WIN[0]}"
  "$TAGS" add pinned    -t "${WIN[0]}"
  "$TAGS" rm  pinned    -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"
  assert_output --partial 'important'
  refute_output --partial 'pinned'
}

@test "clear drops every tag on the window" {
  "$TAGS" add important -t "${WIN[0]}"
  "$TAGS" add agent     -t "${WIN[0]}"
  "$TAGS" add group:work -t "${WIN[0]}"
  "$TAGS" clear -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"
  refute_output --partial 'important'
  refute_output --partial 'agent'
  refute_output --partial 'group'
}

@test "a valued tag round-trips with its value" {
  "$TAGS" add group:homelab -t "${WIN[0]}"
  run "$TAGS" get -t "${WIN[0]}"
  assert_output --partial 'group:homelab'
}

# ── the reason tags are options and not names ────────────────────────────────

@test "a tag survives the window being renamed" {
  # The whole design rationale (tags.sh:11): the zsh precmd hook rewrites the window name to
  # the git branch on EVERY prompt, so a name-based marker is wiped the moment you hit
  # enter. If this ever fails, tags silently stop protecting anything during normal use.
  "$TAGS" add pinned -t "${WIN[0]}"
  _tm rename-window -t "${WIN[0]}" 'some-branch-name'
  run "$TAGS" get -t "${WIN[0]}"
  assert_output --partial 'pinned'
}

# ── protected: the guard the kill-scripts trust ──────────────────────────────

@test "protected succeeds for a pinned window and names the reason" {
  "$TAGS" add pinned -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"
  assert_success
  assert_output --partial 'pinned'
}

@test "protected succeeds for an important window" {
  "$TAGS" add important -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"
  assert_success
  assert_output --partial 'important'
}

@test "protected FAILS for an untagged window" {
  run "$TAGS" protected -t "${WIN[1]}"
  assert_failure
}

@test "protected FAILS for a window tagged only 'agent'" {
  # The sharp edge of the guard. `agent` is a real tag but NOT a protect tag, so an agent
  # window must stay reapable - if this started passing, cleanup would refuse to reap agent
  # windows and the server would fill up with dead ones.
  "$TAGS" add agent -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"
  assert_failure
}

@test "protected FAILS for a window tagged only with a group" {
  "$TAGS" add group:work -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"
  assert_failure
}

@test "protected stops protecting once the tag is cleared" {
  "$TAGS" add pinned -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"; assert_success
  "$TAGS" clear -t "${WIN[0]}"
  run "$TAGS" protected -t "${WIN[0]}"; assert_failure
}

@test "protected still answers for a window whose name changed" {
  "$TAGS" add important -t "${WIN[0]}"
  _tm rename-window -t "${WIN[0]}" 'feat-something'
  run "$TAGS" protected -t "${WIN[0]}"
  assert_success
}

# ── enumeration: targets / ls ────────────────────────────────────────────────

@test "targets lists a tagged window and omits untagged ones" {
  "$TAGS" add pinned -t "${WIN[0]}"
  run "$TAGS" targets
  assert_success
  assert_output --partial "${WIN[0]}"
  refute_output --partial "${WIN[1]}"
}

@test "targets --tag filters to that tag" {
  "$TAGS" add pinned    -t "${WIN[0]}"
  "$TAGS" add important -t "${WIN[1]}"
  run "$TAGS" targets --tag important
  assert_output --partial "${WIN[1]}"
  refute_output --partial "${WIN[0]}"
}

@test "targets --tag on a valued tag can pin to one value" {
  "$TAGS" add group:work -t "${WIN[0]}"
  "$TAGS" add group:home -t "${WIN[1]}"
  run "$TAGS" targets --tag group:home
  assert_output --partial "${WIN[1]}"
  refute_output --partial "${WIN[0]}"
}

@test "targets is empty when nothing is tagged, and still succeeds" {
  run "$TAGS" targets
  assert_success
  assert_output ''
}

@test "ls --json emits parseable JSON carrying the tag" {
  "$TAGS" add pinned -t "${WIN[0]}"
  run bash -c "'$TAGS' ls --json | jq -r '.[0].tags[0]'"
  assert_success
  assert_output 'pinned'
}

@test "ls --json is an empty array when nothing is tagged" {
  run bash -c "'$TAGS' ls --json | jq -r 'length'"
  assert_success
  assert_output '0'
}

# ── refusals ─────────────────────────────────────────────────────────────────

@test "adding an unknown tag fails and writes nothing" {
  run "$TAGS" add nonsense -t "${WIN[0]}"
  assert_failure
  run "$TAGS" get -t "${WIN[0]}"
  refute_output --partial 'nonsense'
}

@test "an unknown subcommand fails rather than defaulting to a listing" {
  run "$TAGS" not-a-verb
  assert_failure
  assert_output --partial 'unknown subcommand'
}

# ── session favourites ───────────────────────────────────────────────────────

@test "fav toggles the session option, and again clears it" {
  sess=$(_tm display-message -p -t "${WIN[0]}" '#{session_name}')
  "$TAGS" fav -t "$sess"
  run "$TAGS" fav ls
  assert_output "$sess"
  "$TAGS" fav -t "$sess"
  run "$TAGS" fav ls
  assert_output ''
}

@test "a favourite is a session option every window of it reads, not a window tag" {
  # status-left, Prefix+w and agent-panel all read #{@fav} from a window or pane format;
  # that only works while tmux falls back from the window to its session's options.
  "$TAGS" fav on -t "${WIN[0]}"
  run _tm display-message -p -t "${WIN[1]}" '#{?@fav,fav,no}'
  assert_output 'fav'
  run "$TAGS" get -t "${WIN[1]}"
  refute_output --partial 'fav'
  run _tm show-options -wqv -t "${WIN[1]}" @fav
  assert_output ''
}

@test "fav off on a session that is not a favourite succeeds and changes nothing" {
  run "$TAGS" fav off -t "${WIN[0]}"
  assert_success
  run "$TAGS" fav ls
  assert_output ''
}

@test "fav refuses a session that does not exist and an unknown verb" {
  run "$TAGS" fav -t no-such-session
  assert_failure
  assert_output --partial 'no such session'
  run "$TAGS" fav sideways -t "${WIN[0]}"
  assert_failure
  assert_output --partial 'usage: fav'
  run "$TAGS" fav on off -t "${WIN[0]}"
  assert_failure
  run "$TAGS" fav ls -t "${WIN[0]}"
  assert_failure
  run "$TAGS" fav ls
  assert_output ''
}

@test "fav works on a session whose name holds a #" {
  _tm rename-session -t "${WIN[0]}" 'a#b'
  run "$TAGS" fav on -t "${WIN[0]}"
  assert_success
  run "$TAGS" fav ls
  assert_output 'a#b'
}
