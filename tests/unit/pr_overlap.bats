#!/usr/bin/env bats
# pr-overlap.sh: after `gh pr create` opens a PR, tells the session which other open PRs change its files.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/pr-overlap.sh"
  FIX="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$FIX/bin"
  # gh: `pr list` serves the list fixture; every call is logged.
  cat >"$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIX/calls.log"
[ -f "$FIX/fail" ] && exit 1
[ "$1 $2" = "pr list" ] && cat "$FIX/list"
STUB
  chmod +x "$FIX/bin/gh"
  export FIX PATH="$FIX/bin:$PATH"
  jq -n '[{number: 7, title: "mine", files: [{path: "a.sh"}, {path: "b.sh"}]},
          {number: 5, title: "feat(x): peer", files: [{path: "b.sh"}, {path: "c.sh"}]},
          {number: 4, title: "fix(y): apart", files: [{path: "d.sh"}]}]' >"$FIX/list"
}

payload() { jq -cn --arg c "$1" --arg o "$2" '{tool_name: "Bash", tool_input: {command: $c}, tool_response: {stdout: $o, stderr: ""}}'; }
# hook <command> <stdout> -- run the hook; $output is the context it hands the session, empty when silent.
hook() {
  run bash "$HOOK" <<<"$(payload "$1" "$2")"
  assert_success
  [ -z "$output" ] || output="$(jq -er '.hookSpecificOutput | select(.hookEventName == "PostToolUse") | .additionalContext' <<<"$output")"
}

@test "a new PR that shares a file with an open PR names that PR and the shared file, and no other" {
  hook 'cd ~/wt && gh pr create --title t --body-file b' 'https://github.com/o/r/pull/7'
  assert_output --partial 'pr-overlap: #7 changes files that other open PRs in o/r also change'
  assert_output --partial '#5 feat(x): peer: b.sh'
  refute_output --partial '#4'
  refute_output --partial '#7 mine'
}

@test "no shared file, another command, a mention of the command, or a create that printed no URL is silent; only a create calls gh" {
  jq '.[1].files = [{path: "c.sh"}]' "$FIX/list" >"$FIX/l" && mv "$FIX/l" "$FIX/list"
  hook 'gh pr create -f' 'https://github.com/o/r/pull/7'
  assert_output ''
  hook 'gh pr view 7' 'https://github.com/o/r/pull/7'
  assert_output ''
  hook "echo 'run gh pr create later'; gh pr list" 'https://github.com/o/r/pull/7'
  assert_output ''
  hook 'gh pr create -f' 'pull request create failed'
  assert_output ''
  assert_equal "$(grep -c . "$FIX/calls.log")" 1
}

@test "a gh failure, or a new PR not in the list, is silent" {
  touch "$FIX/fail"
  hook 'gh pr create -f' 'https://github.com/o/r/pull/7'
  assert_output ''
  rm "$FIX/fail"
  hook 'gh pr create -f' 'https://github.com/o/r/pull/9'
  assert_output ''
}

@test "at most five PRs are named, and a long overlap names three files and a count" {
  jq -n '[{number: 7, title: "mine", files: ([{path: "a.sh"}] + [range(0; 5) | {path: "f\(.).sh"}])},
          {number: 20, title: "wide", files: [range(0; 5) | {path: "f\(.).sh"}]}]
    + [range(1; 9) | {number: ., title: "p\(.)", files: [{path: "a.sh"}]}]' >"$FIX/list"
  hook 'gh pr create -f' 'https://github.com/o/r/pull/7'
  assert_equal "$(grep -c '^  #' <<<"$output")" 5
  assert_output --partial '#20 wide: f0.sh, f1.sh, f2.sh and 2 more'
}
