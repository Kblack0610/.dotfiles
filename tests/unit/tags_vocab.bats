#!/usr/bin/env bats
# tags.sh's VOCABULARY: the pure mapping from a tag string to a tmux option and to a tmux
# filter expression. No server is touched, so this is the cheap tier.
#
# This mapping is load-bearing well beyond the tag UI. cleanup.sh, stale-detector.sh and
# wind-down.sh all decide what NOT to kill by asking `tmux-tags protected`, which is defined
# entirely in terms of PROTECT_TAGS and the option names built here. A silent drift between
# "the tag the user set" and "the option the filter looks for" means a window marked pinned
# gets killed anyway, on a timer, with no error.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.local/src/tmux/tags.sh"
}

# ── the safety vocabulary ────────────────────────────────────────────────────

@test "PROTECT_TAGS is exactly pinned and important" {
  # Pinned to the literal set on purpose. Widening it silently (say, adding 'agent') would
  # make automated cleanup refuse to reap agent windows and quietly fill the server;
  # narrowing it would let a pinned window be killed. Either way a reviewer should have to
  # change this line deliberately.
  assert_equal "${PROTECT_TAGS[*]}" 'pinned important'
}

@test "every protect tag is a real tag in the vocabulary" {
  # A typo here would make `protected` never match, so nothing would ever be protected --
  # and it would fail OPEN, silently, since has_tag on an unknown option just returns false.
  local t
  for t in "${PROTECT_TAGS[@]}"; do
    in_list "$t" "${FLAG_TAGS[@]}" "${VALUED_TAGS[@]}" \
      || fail "protect tag '$t' is not in FLAG_TAGS or VALUED_TAGS"
  done
}

@test "the documented flag and valued tags are the ones actually defined" {
  assert_equal "${FLAG_TAGS[*]}" 'important pinned agent'
  assert_equal "${VALUED_TAGS[*]}" 'group'
}

# ── tag_opt: tag string -> tmux option ───────────────────────────────────────

@test "tag_opt maps a flag tag to its option with value 1" {
  run tag_opt important
  assert_success
  assert_output '@tag_important 1'
}

@test "tag_opt maps every flag tag, not just the first" {
  run tag_opt pinned; assert_output '@tag_pinned 1'
  run tag_opt agent;  assert_output '@tag_agent 1'
}

@test "tag_opt maps a valued tag to its option carrying the value" {
  run tag_opt group:work
  assert_success
  assert_output '@tag_group work'
}

@test "tag_opt rejects a value on a flag tag" {
  # `important:1` would otherwise write a surprising option and read back inconsistently.
  run tag_opt important:yes
  assert_failure
  assert_output --partial 'flag tag'
}

@test "tag_opt rejects a valued tag with no value" {
  run tag_opt group
  assert_failure
  assert_output --partial 'needs a value'
}

@test "tag_opt rejects an unknown tag and names the vocabulary" {
  run tag_opt nonsense
  assert_failure
  assert_output --partial 'unknown tag'
  assert_output --partial 'important'
}

@test "tag_opt keeps a value containing a hyphen intact" {
  run tag_opt group:home-lab
  assert_success
  assert_output '@tag_group home-lab'
}

@test "tag_opt splits on the FIRST colon, so a value may contain one" {
  run tag_opt group:a:b
  assert_success
  assert_output '@tag_group a:b'
}

# ── tag_filter: tag string -> tmux filter ────────────────────────────────────

@test "tag_filter on a bare flag tests the option's presence" {
  run tag_filter pinned
  assert_success
  assert_output '#{@tag_pinned}'
}

@test "tag_filter on a bare valued tag matches any value" {
  run tag_filter group
  assert_success
  assert_output '#{@tag_group}'
}

@test "tag_filter on a valued tag with a value pins to that value" {
  run tag_filter group:work
  assert_success
  assert_output '#{==:#{@tag_group},work}'
}

@test "tag_filter rejects an unknown tag rather than matching everything" {
  # The dangerous failure: a filter that silently becomes empty matches EVERY window, so
  # `tmux-tags kill --tag typo` would target the whole server instead of nothing.
  run tag_filter nonsense
  assert_failure
  refute_output --partial '#{'
}

# ── any_tag_filter / tags_format: built FROM the vocabulary ──────────────────

@test "any_tag_filter mentions every tag in the vocabulary" {
  local f; f="$(any_tag_filter)"
  local t
  for t in "${FLAG_TAGS[@]}" "${VALUED_TAGS[@]}"; do
    [[ "$f" == *"@tag_${t}"* ]] || fail "any_tag_filter omits @tag_${t}: $f"
  done
}

@test "any_tag_filter combines the tags with OR, not AND" {
  # AND would make `ls` show only windows carrying every tag at once -- i.e. almost nothing.
  local f; f="$(any_tag_filter)"
  [[ "$f" == *'#{||:'* ]] || fail "expected an || expression, got: $f"
  refute [ "$(printf '%s' "$f" | grep -c '#{&&:')" != 0 ]
}

@test "tags_format renders every tag in the vocabulary" {
  local f; f="$(tags_format)"
  local t
  for t in "${FLAG_TAGS[@]}" "${VALUED_TAGS[@]}"; do
    [[ "$f" == *"@tag_${t}"* ]] || fail "tags_format omits @tag_${t}"
  done
}

@test "tags_format prints a valued tag as name:value, not a bare 1" {
  local f; f="$(tags_format)"
  [[ "$f" == *'group:#{@tag_group}'* ]] || fail "group should render its value: $f"
}

# ── split_target ─────────────────────────────────────────────────────────────

@test "split_target pulls -t out and leaves the rest of the argv" {
  split_target add important -t @7
  assert_equal "$TARGET_ARG" '@7'
  assert_equal "${ARGV_REST[*]}" 'add important'
}

@test "split_target accepts --target as well as -t" {
  split_target --target @9 clear
  assert_equal "$TARGET_ARG" '@9'
  assert_equal "${ARGV_REST[*]}" 'clear'
}

@test "split_target finds -t wherever it sits in the argv" {
  split_target -t @3 add pinned
  assert_equal "$TARGET_ARG" '@3'
  assert_equal "${ARGV_REST[*]}" 'add pinned'
}

@test "split_target leaves TARGET_ARG empty when no target is given" {
  split_target get
  assert_equal "$TARGET_ARG" ''
  assert_equal "${ARGV_REST[*]}" 'get'
}

@test "split_target resets state between calls" {
  # ARGV_REST and TARGET_ARG are globals; a stale value from the previous verb would send a
  # write to the wrong window.
  split_target add pinned -t @1
  split_target get
  assert_equal "$TARGET_ARG" ''
  assert_equal "${ARGV_REST[*]}" 'get'
}

# ── sourcing is inert ────────────────────────────────────────────────────────

@test "sourcing tags.sh runs no subcommand" {
  # The guard exists so this file can source the script. If it regressed, sourcing would
  # execute the default `ls` verb against whatever tmux it could reach.
  run bash -c 'source "$REPO_ROOT/.local/src/tmux/tags.sh"; echo SOURCED-CLEAN'
  assert_success
  assert_output --partial 'SOURCED-CLEAN'
  refute_output --partial 'WIN'        # the ls header
  refute_output --partial 'No tagged windows'
}
