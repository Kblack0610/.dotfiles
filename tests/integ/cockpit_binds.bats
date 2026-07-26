#!/usr/bin/env bats
# Bind-coverage lint.
#
# The cockpit is re-entrant: fzf --bind actions shell back into `$SELF --verb`. A verb
# named in a bind but missing from the dispatch `case` is invisible until someone presses
# that key, and then it fails silently inside fzf's execute() with no error surfaced. The
# reverse -- a case arm nothing invokes -- is dead code. Neither is detectable by running
# the script, only by cross-referencing the two lists. Ten lines of grep, and it catches
# the single most likely regression in this architecture.
#
# Verbs are invoked from two places, both of which must be scanned:
#   1. the static --bind block            `$SELF --list`
#   2. _enter_action's dynamic actions    printf 'execute(%s --answer ...)' "$SELF"

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

# Every verb the script invokes on itself.
invoked_verbs() {
  grep -oE '(\$SELF|%s) --[a-z-]+' "$COCKPIT" \
    | grep -oE -- '--[a-z-]+' | sort -u
}

# Every verb the dispatch case handles.
dispatched_verbs() {
  sed -n '/^case "\${1:-}" in$/,/^esac$/p' "$COCKPIT" \
    | grep -oE '^  --[a-z-]+\)' | tr -d ' )' | sort -u
}

@test "the lint can actually see both lists" {
  # Guards the lint itself: if the greps stop matching (someone reformats the case block),
  # the two tests below would pass vacuously.
  [ "$(invoked_verbs | wc -l)" -ge 10 ]
  [ "$(dispatched_verbs | wc -l)" -ge 10 ]
}

@test "every verb invoked from a bind has a dispatch arm" {
  local missing
  missing="$(comm -23 <(invoked_verbs) <(dispatched_verbs))"
  if [ -n "$missing" ]; then
    {
      echo "These verbs are invoked but have no arm in the dispatch case."
      echo "Pressing the bound key would fail silently inside fzf's execute():"
      printf '  %s\n' $missing
    } >&2
    return 1
  fi
}

@test "every dispatch arm is reachable from some bind" {
  local orphan
  orphan="$(comm -13 <(invoked_verbs) <(dispatched_verbs))"
  if [ -n "$orphan" ]; then
    {
      echo "These dispatch arms are never invoked -- dead code, or a bind that was dropped:"
      printf '  %s\n' $orphan
    } >&2
    return 1
  fi
}

@test "every invoked verb actually runs without erroring out" {
  # A dispatch arm can exist and still be broken. Smoke-run each read-only verb.
  local v
  for v in --list --rail --next-section --prev-section --cycle-pfilter --toggle-mode --help-view; do
    run "$COCKPIT" "$v"
    [ "$status" -eq 0 ] || fail "verb $v exited $status: $output"
  done
}

@test "the documented verb list in the header comment stays in sync with dispatch" {
  # notes-cockpit.sh:27-28 documents the modes. Drift there is a docs bug, not a crash,
  # so this asserts only that the big ones are still mentioned.
  local header; header="$(sed -n '1,30p' "$COCKPIT")"
  local v
  for v in --list --rail --add --move --new-project --archive-project --restore-project; do
    grep -qF -- "$v" <<< "$header" || fail "verb $v is dispatched but undocumented in the header comment"
  done
}

@test "fzf bind actions reference SELF, never a bare script name" {
  # A bare `notes-cockpit.sh --list` would depend on PATH and break under display-popup.
  run grep -nE '(execute|reload|become|preview)\([^)]*notes-cockpit\.sh' "$COCKPIT"
  assert_failure
}

@test "every reload() in a bind reloads through a real verb" {
  # reload($SELF --list) is the refresh contract; a typo here empties the picker.
  local bad
  bad="$(grep -oE 'reload\(\$SELF --[a-z-]+' "$COCKPIT" | grep -oE -- '--[a-z-]+' | sort -u \
         | comm -23 - <(dispatched_verbs))"
  [ -z "$bad" ] || fail "reload() references undispatched verbs: $bad"
}
