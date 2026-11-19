#!/usr/bin/env bats
# gh-login-guard.py: a session's command may not change this host's gh login (ar-2876). The
# home is the suite's throwaway one, with a fixture hosts.yml; the guard only reads it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/gh-login-guard.py"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_CONFIG_HOME GH_CONFIG_DIR
  G="$HOME/.config/gh"
  mkdir -p "$G" "$HOME/work"
  echo 'github.com:' > "$G/hosts.yml"
}

at() { jq -nc --arg c "$1" --arg d "$HOME/work" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'gh-login-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "gh auth login, logout, refresh and switch are denied, saying the login is the human's" {
  local c
  for c in "gh auth logout" "gh auth logout -h github.com -u Kblack0610" "gh auth login --with-token < /tmp/t" \
    "gh auth refresh -s admin:org" "gh auth switch" "command gh auth logout" "bash -c 'gh auth logout'" \
    "HOME=\$HOME gh auth logout" "GH_CONFIG_DIR=$G gh auth login"; do
    run at "$c"
    denied
  done
  assert_output --partial 'only the human signs it back in'
  assert_output --partial 'no PAT'
}

@test "every way to remove or overwrite the gh config dir is denied" {
  local c
  for c in "rm -f ~/.config/gh/hosts.yml" "rm -rf $G" "rm -rf \$HOME/.config" "rm -rf ~/.config/g*" \
    "cd ~/.config && rm -rf gh" "eval rm -rf ~/.config/gh" "mv ~/.config/gh /tmp/gh.bak" "mv ~/.config ~/cfg" \
    "cp /tmp/hosts.yml ~/.config/gh/hosts.yml" "cp -t ~/.config/gh /tmp/h" "ln -sf /tmp/h $G/hosts.yml" \
    "echo x > ~/.config/gh/hosts.yml" "echo x &> $G/hosts.yml" "echo > \"\$HOME/.config/gh/hosts.yml\"" \
    "sed -i s/a/b/ ~/.config/gh/hosts.yml" "find ~/.config/gh -delete" "truncate -s0 $G/hosts.yml" \
    "printf x | tee -a ~/.config/gh/hosts.yml" "unlink $G/hosts.yml" "dd if=/dev/null of=$G/hosts.yml" \
    "find ~/.config -delete" "find ~/work ~/.config/gh -delete" "find ~/.config/gh -type f -exec rm {} +" \
    "rsync -a --delete /tmp/empty/ ~/.config/" "find ~ -name 'hosts.*' -delete"; do
    run at "$c"
    denied
  done
}

@test "\$XDG_CONFIG_HOME/gh and \$GH_CONFIG_DIR are guarded too" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" GH_CONFIG_DIR="$BATS_TEST_TMPDIR/ghdir"
  run at "rm -rf $XDG_CONFIG_HOME/gh"
  denied
  run at "rm -f \$GH_CONFIG_DIR/hosts.yml"
  denied
  assert_output --partial "$GH_CONFIG_DIR"
  run at "tee $GH_CONFIG_DIR/hosts.yml"
  denied
  run at "HOME=/tmp/h gh auth logout"
  denied
}

@test "reads, other gh calls, a throwaway gh home and unrelated writes pass" {
  local c
  for c in "gh auth status" "gh auth token" "gh pr list" "gh api user" "cat ~/.config/gh/hosts.yml" \
    "cp ~/.config/gh/hosts.yml /tmp/x" "GH_CONFIG_DIR=/tmp/fake gh auth login --with-token" "HOME=/tmp/h gh auth logout" \
    "mv a.txt ~/" "rm -rf ~/work/foo" "rm -rf ~/.config/other" "find ~ -name '*.tmp' -delete" "ls 2>&1 >/dev/null" \
    "echo a >&2" "sed -i s/a/b/ ~/work/f" "rm -rf \$UNSET_VAR/gh" \
    "git commit -m \"fix > ~/.config/gh/hosts.yml handling\"" "cp -r x ~/" "find ~/work -exec ls {} +"; do
    run at "$c"
    allowed
  done
}

@test "a tool other than Bash passes" {
  run bash -c "jq -nc '{tool_name:\"Read\", tool_input:{file_path:\"$G/hosts.yml\"}}' | python3 '$GUARD'"
  allowed
}

@test "settings.json runs it on every Bash call and denies Edit and Write into the gh dir" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("gh-login-guard"))' "$BATS_TEST_DIRNAME/../../.claude/settings.json"
  assert_output 'python3 ~/.claude/hooks/gh-login-guard.py || true'
  run jq -r '.permissions.deny[] | select(. == "Edit(~/.config/gh/**)")' "$BATS_TEST_DIRNAME/../../.claude/settings.json"
  assert_output 'Edit(~/.config/gh/**)'
}

@test "a gh home the hook cannot resolve is not a throwaway one" {
  run at "D=~/.config/gh; GH_CONFIG_DIR=\$D gh auth logout"
  denied
  run at "GH_CONFIG_DIR=\$(echo ~/.config/gh) gh auth logout"
  denied
}
