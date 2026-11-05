#!/usr/bin/env bats
# token-filter.sh (the Bash rewrite hook) and the token-filter CLI. rtk and agent-notify are
# stubs, so the suite pins the hook's contract, not rtk's filters: fail-open on every path,
# skips, the rtk-vcs method, the breaker, the PostToolUse re-run hint, and verify's replay.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/token-filter.sh"
  TF="$BATS_TEST_DIRNAME/../../.local/bin/token-filter"
  D="$BATS_TEST_TMPDIR"
  export TOKEN_FILTER_STATE="$D/state" TOKEN_FILTER_CACHE="$D/cache" TOKEN_FILTER_CONF="$D/conf"
  mkdir -p "$D/bin" "$TOKEN_FILTER_STATE" "$TOKEN_FILTER_CONF"
  # rtk stub: rewrite maps git/grep/wc to `rtk <cmd>` (exit 3, as rtk-oss 1.1.0 does without
  # allow rules), "slow" to the timeout exit, anything else to "no equivalent". `rtk wc`
  # prints padding, so verify sees the filtered output grow.
  cat > "$D/bin/rtk" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk 1.1.0" ;;
  rewrite) case "$2" in
    git*|grep*|wc*) echo "rtk $2"; exit 3 ;;
    slow*) exit 124 ;;
    *) exit 1 ;;
  esac ;;
  wc) shift; wc "$@"; printf '%0500d\n' 0 ;;
  *) exec "$@" ;;
esac
EOF
  printf '#!/bin/sh\necho "$@" >> "%s/notified"\n' "$D" > "$D/bin/agent-notify"
  chmod +x "$D/bin/rtk" "$D/bin/agent-notify"
  export PATH="$D/bin:$PATH"
  echo rtk > "$TOKEN_FILTER_STATE/mode"
}

pre() { jq -nc --arg c "$1" --arg id "${2:-t1}" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s",tool_use_id:$id,tool_input:{command:$c,description:"d",timeout:9}}' \
  | bash "$HOOK"; }
post() { jq -nc --arg id "$1" --arg err "$2" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:$id,tool_response:{stdout:"",stderr:$err}}' \
  | bash "$HOOK"; }

@test "off, or no mode file, passes every command through untouched" {
  rm "$TOKEN_FILTER_STATE/mode"
  run pre "git status"
  assert_success
  assert_output ""
  echo off > "$TOKEN_FILTER_STATE/mode"
  run pre "git status"
  assert_output ""
}

@test "rtk rewrites the command, keeps the other inputs, and never decides permission" {
  run pre "git status" g1
  assert_success
  [ "$(jq -r .hookSpecificOutput.updatedInput.command <<<"$output")" = "rtk git status" ]
  [ "$(jq -c '.hookSpecificOutput.updatedInput | [.description,.timeout]' <<<"$output")" = '["d",9]' ]
  [ "$(jq '.hookSpecificOutput | has("permissionDecision")' <<<"$output")" = false ]
  run grep -c '"id":"g1"' "$TOKEN_FILTER_CACHE/rewrites.jsonl"
  assert_output 1
}

@test "RTK_DISABLED, an rtk command, a tracked skip and a local skip are left alone" {
  printf '# why\n(^|[;&|(] *)git +stash\\b\n' > "$TOKEN_FILTER_CONF/skip"
  printf '(^|[;&|(] *)git +log\\b\n' > "$TOKEN_FILTER_STATE/skip"
  for c in "RTK_DISABLED=1 git status" "rtk git status" "git stash list" "cd x && git log -3"; do
    run pre "$c"
    assert_success
    assert_output ""
  done
  run pre "git status"
  assert_output --partial "rtk git status"
}

@test "rtk-vcs rewrites git but leaves searches exact" {
  echo rtk-vcs > "$TOKEN_FILTER_STATE/mode"
  run pre "grep -rn foo ."
  assert_output ""
  run pre "git status"
  assert_output --partial "rtk git status"
}

@test "no rtk equivalent, a rewrite timeout, garbage input: exit 0, command unchanged" {
  run pre "python3 x.py"
  assert_success
  assert_output ""
  run pre "slow thing"
  assert_success
  assert_output ""
  run grep -c rewrite-timeout "$TOKEN_FILTER_CACHE/failures.jsonl"
  assert_output 1
  run bash "$HOOK" <<<"not json"
  assert_success
  assert_output ""
}

@test "five rtk failures in an hour trip the breaker to off and page once" {
  rm "$D/bin/rtk"
  PATH="$D/bin:/usr/bin:/bin"  # no real rtk either
  for i in 1 2 3 4 5 6; do
    run pre "git status" "m$i"
    assert_success
    assert_output ""
  done
  [ "$(cat "$TOKEN_FILTER_STATE/mode")" = off ]
  run jq -r 'select(.by=="breaker") | "\(.from)->\(.method)"' "$TOKEN_FILTER_STATE/methods.jsonl"
  assert_output "rtk->off"
  [ "$(wc -l < "$D/notified")" -eq 1 ]
}

@test "an rtk error in a rewritten command's output becomes a re-run hint" {
  pre "git status" g1 >/dev/null
  run post g1 $'error: unexpected argument \'--x\' found\n\nUsage: rtk git status'
  assert_success
  assert_output --partial "RTK_DISABLED=1 git status"
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = PostToolUse ]
  run post g1 "On branch main"
  assert_output ""
  run post never-rewritten "Usage: rtk git status"
  assert_output ""
}

@test "PostToolUseFailure reads the error field" {
  pre "grep -rn x ." g2 >/dev/null
  run bash "$HOOK" <<<'{"hook_event_name":"PostToolUseFailure","tool_use_id":"g2","error":"[rtk] error: filter failed"}'
  assert_output --partial '"PostToolUseFailure"'
  assert_output --partial "RTK_DISABLED=1 grep -rn x ."
}

@test "use logs each switch; skip add, list and rm touch only the local file" {
  run "$TF" use rtk-vcs --reason test
  assert_output "method rtk -> rtk-vcs"
  [ "$(jq -r '"\(.by)|\(.reason)"' "$TOKEN_FILTER_STATE/methods.jsonl")" = "token-filter use|test" ]
  echo '(^|[;&|(] *)ls\b' > "$TOKEN_FILTER_CONF/skip"
  "$TF" skip add '(^|[;&|(] *)tree\b' --why 'test rule'
  run "$TF" skip
  assert_output --partial "tracked"
  assert_output --partial "  1  (^|[;&|(] *)tree\\b"
  "$TF" skip rm 1
  [ "$(grep -vc '^#' "$TOKEN_FILTER_STATE/skip")" -eq 0 ]
  [ "$(cat "$TOKEN_FILTER_CONF/skip")" = '(^|[;&|(] *)ls\b' ]
}

@test "doctor passes with the hook registered, fails without it" {
  export TOKEN_FILTER_SETTINGS="$D/settings.json"
  jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{command:"bash ~/.claude/hooks/token-filter.sh"}]}],
               PostToolUse:[{matcher:"Bash",hooks:[{command:"bash ~/.claude/hooks/token-filter.sh"}]}]}}' > "$TOKEN_FILTER_SETTINGS"
  run "$TF" doctor
  assert_success
  assert_output --partial "ok:"
  echo '{}' > "$TOKEN_FILTER_SETTINGS"
  run "$TF" doctor
  assert_failure
  assert_output --partial "not a PreToolUse hook"
}

@test "verify replays read-only history only, flags growth, and --apply skips the shape" {
  W="$D/work"
  mkdir -p "$W" "$D/projects/p"
  echo hello > "$W/f"
  export CLAUDE_TRANSCRIPTS="$D/projects"
  for c in "wc -c f" "git status" "rm -rf f" "grep -n hello f > out"; do
    jq -nc --arg c "$c" --arg w "$W" '{type:"assistant",cwd:$w,message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'
  done > "$D/projects/p/s.jsonl"
  run "$TF" verify --days 1 --json
  assert_failure
  [ "$(jq -r '"\(.replayed) \(.bad)"' <<<"$output")" = "2 1" ]
  [ "$(jq -r '.bad_cmds[0] | "\(.verdict) \(.cmd)"' <<<"$output")" = "grew wc -c f" ]
  [ -f "$W/f" ]
  [ ! -e "$W/out" ]
  run "$TF" verify --days 1 --apply
  assert_success
  assert_output --partial "skip added"
  run pre "wc -c f"
  assert_output ""
}
