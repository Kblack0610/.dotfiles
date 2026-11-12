#!/usr/bin/env bats
# fleet-pace's metadata.replaces rows, read from the real SKILL.md through hand_methods.py: a -f kill
# pattern and a recursive search from a network mount's ancestor are denied; a kill by name or PID, a
# search that stays on one filesystem or inside the share, and quoted or heredoc text are not.
# block_root_search.bats keeps the Grep and Glob half of the root-search deny.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  GUARD="$REPO/.claude/hooks/hand_methods.py"
  export CLAUDE_SKILLS="$BATS_TEST_TMPDIR/skills" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CLAUDE_SKILLS"
  ln -s "$REPO/.claude/skills/monitoring/fleet-pace" "$CLAUDE_SKILLS/fleet-pace"
}

# decision <command>: deny, or allow when the guard prints nothing.
decision() {
  local out
  out=$(jq -nc --arg c "$1" '{tool_name:"Bash", cwd:"/home/u/wt", tool_input:{command:$c}}' | python3 "$GUARD")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

# reason <command>: the deny reason the guard prints.
reason() {
  jq -nc --arg c "$1" '{tool_name:"Bash", cwd:"/home/u/wt", tool_input:{command:$c}}' | python3 "$GUARD" \
    | jq -r .hookSpecificOutput.permissionDecisionReason
}

@test "the rows parse with no lint problem" {
  run python3 "$GUARD" --check "$CLAUDE_SKILLS/fleet-pace/SKILL.md"
  assert_success
  assert_output ""
}

@test "pkill -f is denied in any clause and flag spelling; the reason names the skill and pkill -x" {
  for c in 'pkill -f foo' 'sleep 1; pkill -9 -f "bats.*x"' 'sudo pkill -f x' 'x && pkill --full y' 'pkill -9f z' 'LC_ALL=C pkill -f w' \
    'bash -c "pkill -f foo"' 'if true; then pkill -f foo; fi' 'timeout 5 pkill -f foo' 'xargs -r pkill -f' \
    'pkill -u me -f foo' 'pkill -U 1000 -f foo' '/usr/bin/pkill -f x' 'echo pkill -f'; do
    run decision "$c"
    assert_output deny
  done
  run reason 'pkill -f x'
  assert_output --partial 'hand-methods: '
  assert_output --partial 'fleet-pace'
  assert_output --partial 'pkill -x <name>'
}

@test "a pgrep -f whose matches get killed is denied, with the kill before or after it" {
  for c in 'kill $(pgrep -f foo)' 'pgrep -f foo | xargs kill -9' 'pgrep -f foo | xargs -r sudo kill' $'pgrep -f foo\nkill $x'; do
    run decision "$c"
    assert_output deny
  done
}

@test "negative control: a kill by name, a read-only pgrep -f and a broken or quoted phrase all pass" {
  for c in 'pkill -x foo' 'pkill foo' 'pkill -9 foo' 'pkill -x foo-fbar' 'pgrep -af claude' 'pgrep -f foo; git checkout -b kill-switch' \
    'pgrep -f x; ls kill/' 'rg -n "pkill[ ]-f" f' 'my-pkill -f x' 'ls -f; pkill -x foo' 'ls' \
    'git commit -m "no pkill -f here"' $'cat <<EOF\npkill -f x\nEOF'; do
    run decision "$c"
    assert_output allow
  done
}

@test "no tracked script or config line runs a -f kill: the guard sees only agent Bash calls" {
  # A hypr bind runs under sh -c, so a -f pattern kills that shell first and the rest of the line
  # never runs (keybindings.conf Super+Ctrl+R did; waybar/pin.sh's stop had the same form). The
  # row is the one definition of the bad form, so each line goes through it.
  cd "$REPO"
  local line hits=()
  while IFS= read -r line; do
    [ "$(decision "${line#*:*:}")" = allow ] || hits+=("$line")
  done < <(git grep -nwI -e pkill -e pgrep -- . ':!tests' ':!*.md' ':!.claude/skills' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)')
  [ "${#hits[@]}" -eq 0 ] || { printf '%s\n' "${hits[@]}"; false; }
}

@test "the 2026-10-29 shell forms are denied" {
  for c in 'bfs -S dfs / -name CutscenePlayer.cs' \
           'cd x && find / -name FallLine.cs -not -path "*/Library/*" 2>/dev/null | head' \
           'grep -rln "class BallCarrier" /' 'rg BallCarrier /mnt' 'rg BallCarrier /mnt/nas/' 'find /mnt/nas/public -name x'; do
    run decision "$c"
    assert_output deny
  done
  run reason 'rg x /'
  assert_output --partial 'fleet-pace'
  assert_output --partial 'a named subdirectory'
}

@test "staying on the local filesystem, non-recursive grep, and scoped roots are allowed" {
  for c in 'find / -xdev -name a' 'rg --one-file-system foo /' 'find -mount / -name a' 'grep foo /etc/hosts' \
           'rg foo /home/u/wt' 'find . -path /mnt -prune' 'ls /' 'echo / | wc' 'rg foo /mnt/nas/private/photos/2024' \
           'find /mnt/nas/private/photos -name a' 'cat /mnt/nas/private/x | grep foo' 'grep -n foo ./a /tmp' 'git log --grep=x'; do
    run decision "$c"
    assert_output allow
  done
}

@test "quoted and heredoc text that names a root search is not a search" {
  for c in 'git commit -m "fix: find / -name x no longer hangs"' \
           "agent-queue add 'rg foo /mnt is denied by the guard'" \
           $'git commit -F - <<\'EOF\'\nfix: grep -rn foo /\nEOF' \
           $'cat <<EOF\nfind / -name x\nEOF\necho done' \
           $'git commit -m "multi\nline <<EOF find / -name x\nend"'; do
    run decision "$c"
    assert_output allow
  done
}

@test "negative control: the same search as code, after a quoted or heredoc part, is still denied" {
  for c in 'git commit -m "msg" && find / -name x' \
           $'cat <<EOF\nnote\nEOF\nrg foo /mnt' \
           "bash -c 'find / -name x'" \
           'find "/" -name x' \
           "grep -rn 'a b' '/mnt'" \
           'echo "$(find / -name x)"' \
           'eval "find / -name x"' \
           'ssh host "find / -name x"' \
           "watch -n1 'find / -name x'" \
           $'echo "a" # it\'s\nfind / -name x' \
           'sudo find / -name x' '/usr/bin/find / -name x' 'x; find -L / -type f'; do
    run decision "$c"
    assert_output deny
  done
}
