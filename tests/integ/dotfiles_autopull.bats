#!/usr/bin/env bats
# dotfiles-autopull: the stowed checkouts (~/.dotfiles, ~/.dotfiles-private) follow their upstream,
# fast-forward only. Each checkout is a clone of a fixture bare origin under the sandbox $HOME; a
# second clone stands in for a merged PR. No live checkout is touched.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  PULL="$REPO_ROOT/.local/bin/dotfiles-autopull"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset DOTFILES_DIR DOTFILES_PRIVATE DOTFILES_AUTOPULL_INTERVAL CLAUDE_SKILLS
  PUB="$HOME/.dotfiles" PRIV="$HOME/.dotfiles-private"
  pair pub "$PUB"
  pair priv "$PRIV"
}

# pair <name> <checkout> -> a bare origin, the checkout cloned from it, and $SANDBOX/<name>-up, a
# second clone that pushes the "merged" commits
pair() {
  git init -q --bare -b main "$SANDBOX/$1.git"
  git clone -q "$SANDBOX/$1.git" "$SANDBOX/$1-up" 2>/dev/null
  printf 'v1\n' >"$SANDBOX/$1-up/f"
  git -C "$SANDBOX/$1-up" add f && git -C "$SANDBOX/$1-up" commit -qm v1 && git -C "$SANDBOX/$1-up" push -q origin HEAD:main
  git clone -q "$SANDBOX/$1.git" "$2"
}

# merge <name> <content> -> origin's main gets a commit that sets f to <content>
merge() {
  printf '%s\n' "$2" >"$SANDBOX/$1-up/f"
  git -C "$SANDBOX/$1-up" commit -qam "$2" && git -C "$SANDBOX/$1-up" push -q origin HEAD:main
}

# add_upstream <name> <path> <content> -> origin's main gets a commit that adds <path>
add_upstream() {
  mkdir -p "$SANDBOX/$1-up/$(dirname "$2")"
  printf '%s\n' "$3" >"$SANDBOX/$1-up/$2"
  git -C "$SANDBOX/$1-up" add "$2" && git -C "$SANDBOX/$1-up" commit -qm "add $2" && git -C "$SANDBOX/$1-up" push -q origin HEAD:main
}

head_of() { git -C "$1" rev-parse HEAD; }

@test "--now from a worktree of the public repo fast-forwards ~/.dotfiles, and only it" {
  git -C "$PUB" worktree add -q "$SANDBOX/pub-wt" -b feat
  merge pub v2
  merge priv v2
  priv_before=$(head_of "$PRIV")
  run "$PULL" --now "$SANDBOX/pub-wt"
  assert_success
  assert_output --regexp '^~/\.dotfiles: fast-forwarded main [0-9a-f]{8}\.\.[0-9a-f]{8}$'
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(head_of "$PRIV")" "$priv_before"
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial '~/.dotfiles: fast-forwarded main'
}

@test "a fast-forward links the files it added into \$HOME and leaves a physical copy alone" {
  export DOTFILES_DEPLOY="$REPO_ROOT/.local/bin/dotfiles-deploy"
  rm -rf "$PRIV" # both fixtures track f; one repo keeps the manifest free of dual ownership
  printf 'local\n' >"$HOME/f"
  add_upstream pub .local/bin/new-tool v1
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --regexp '^~/\.dotfiles: fast-forwarded main [0-9a-f]{8}\.\.[0-9a-f]{8}$'
  assert_line --index 1 '~: linked 1 missing file(s) into $HOME (dotfiles-deploy --apply --missing)'
  assert_equal "$(readlink -f "$HOME/.local/bin/new-tool")" "$(readlink -f "$PUB/.local/bin/new-tool")"
  [ ! -L "$HOME/f" ] || fail 'a physical copy was converted on pull'
  assert_equal "$(cat "$HOME/f")" local
}

@test "a failed attach after a fast-forward is named on the line, and the pull still succeeds" {
  printf '#!/bin/sh\necho refused: stub\nexit 2\n' >"$SANDBOX/deploy-stub" && chmod +x "$SANDBOX/deploy-stub"
  export DOTFILES_DEPLOY="$SANDBOX/deploy-stub"
  merge pub v2
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'fast-forwarded main'
  assert_line --index 1 --partial 'dotfiles-deploy --apply --missing failed (exit 2); report in'
  assert_equal "$(cat "$PUB/f")" v2
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'dotfiles-deploy --apply --missing exited 2, its report:'
  assert_output --partial '    refused: stub'
}

@test "the shell pass moves both checkouts, then links what both added in one deploy run" {
  export DOTFILES_DEPLOY="$REPO_ROOT/.local/bin/dotfiles-deploy"
  printf 'local\n' >"$HOME/f"
  add_upstream priv .stow-local-ignore '^/f$'
  add_upstream pub .local/bin/new-tool v1
  add_upstream priv .local/bin/priv-tool v1
  run "$PULL"
  assert_success
  assert_equal "$(readlink -f "$HOME/.local/bin/new-tool")" "$(readlink -f "$PUB/.local/bin/new-tool")"
  assert_equal "$(readlink -f "$HOME/.local/bin/priv-tool")" "$(readlink -f "$PRIV/.local/bin/priv-tool")"
  [ ! -L "$HOME/f" ] || fail 'a physical copy was converted on pull'
  run grep -c 'linked' "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output 1
  run grep -c 'fast-forwarded main' "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output 2
}

@test "the shell pass links a file another tool's pull added, though it moves nothing itself" {
  export DOTFILES_DEPLOY="$REPO_ROOT/.local/bin/dotfiles-deploy"
  rm -rf "$PRIV"
  add_upstream pub .local/bin/hand-pulled v1
  git -C "$PUB" pull -q
  run "$PULL"
  assert_success
  assert_equal "$(readlink -f "$HOME/.local/bin/hand-pulled")" "$(readlink -f "$PUB/.local/bin/hand-pulled")"
  run grep -c 'fast-forwarded main' "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output 0
}

@test "--now links a file another tool's pull added, though the checkout is already current" {
  export DOTFILES_DEPLOY="$REPO_ROOT/.local/bin/dotfiles-deploy"
  rm -rf "$PRIV"
  printf 'local\n' >"$HOME/f"
  add_upstream pub .local/bin/hand-pulled v1
  git -C "$PUB" pull -q
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'already current'
  assert_line --index 1 '~: linked 1 missing file(s) into $HOME (dotfiles-deploy --apply --missing)'
  assert_equal "$(readlink -f "$HOME/.local/bin/hand-pulled")" "$(readlink -f "$PUB/.local/bin/hand-pulled")"
}

@test "a fast-forward that adds a SKILL.md links the skill, flat" {
  export DOTFILES_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  add_upstream pub .claude/skills/ops/new-skill/SKILL.md v1
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'fast-forwarded main'
  assert_line --index 1 '~: updated 1 skill link(s) in ~/.claude/skills (skill-deploy)'
  assert_equal "$(readlink -f "$HOME/.claude/skills/new-skill")" "$(readlink -f "$PUB/.claude/skills/ops/new-skill")"
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'updated 1 skill link(s)'
}

@test "a fast-forward that moves a skill's category repoints its link" {
  export DOTFILES_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  add_upstream pub .claude/skills/ops/moved-skill/SKILL.md v1
  run "$PULL" --now "$PUB"
  assert_success
  git -C "$SANDBOX/pub-up" mv .claude/skills/ops .claude/skills/infra
  git -C "$SANDBOX/pub-up" commit -qm move && git -C "$SANDBOX/pub-up" push -q origin HEAD:main
  run "$PULL" --now "$PUB"
  assert_line --index 1 '~: updated 1 skill link(s) in ~/.claude/skills (skill-deploy)'
  assert_equal "$(readlink -f "$HOME/.claude/skills/moved-skill")" "$(readlink -f "$PUB/.claude/skills/infra/moved-skill")"
}

@test "a fast-forward that deletes a skill removes its link" {
  export DOTFILES_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  add_upstream pub .claude/skills/ops/gone-skill/SKILL.md v1
  run "$PULL" --now "$PUB"
  assert_success
  git -C "$SANDBOX/pub-up" rm -rq .claude/skills/ops
  git -C "$SANDBOX/pub-up" commit -qm delete && git -C "$SANDBOX/pub-up" push -q origin HEAD:main
  run "$PULL" --now "$PUB"
  assert_line --index 1 '~: updated 1 skill link(s) in ~/.claude/skills (skill-deploy)'
  [ ! -L "$HOME/.claude/skills/gone-skill" ] || fail 'the deleted skill kept its link'
}

@test "a fast-forward that changes no skill links adds no line, and one that does heals a skill a hand pull left unlinked" {
  export DOTFILES_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  add_upstream pub .claude/skills/ops/one/SKILL.md v1
  run "$PULL" --now "$PUB"
  assert_success
  merge pub v2
  run "$PULL" --now "$PUB"
  assert_success
  assert_output --regexp '^~/\.dotfiles: fast-forwarded main [0-9a-f]{8}\.\.[0-9a-f]{8}$'
  add_upstream pub .claude/skills/ops/hand-pulled/SKILL.md v1
  git -C "$PUB" pull -q
  merge pub v3
  run "$PULL" --now "$PUB"
  assert_line --index 1 '~: updated 1 skill link(s) in ~/.claude/skills (skill-deploy)'
  assert_equal "$(readlink -f "$HOME/.claude/skills/hand-pulled")" "$(readlink -f "$PUB/.claude/skills/ops/hand-pulled")"
}

@test "a skill-deploy conflict after a fast-forward is named on the line, logged, and the pull still succeeds" {
  export DOTFILES_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy"
  mkdir -p "$HOME/.claude/skills/in-the-way"
  printf 'hand-made\n' >"$HOME/.claude/skills/in-the-way/SKILL.md"
  add_upstream pub .claude/skills/ops/in-the-way/SKILL.md v1
  add_upstream pub .claude/skills/ops/fine/SKILL.md v1
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'fast-forwarded main'
  assert_line --index 1 --partial 'updated 1 skill link(s), then skill-deploy failed (exit 1) on: in-the-way; report in'
  assert_equal "$(cat "$HOME/.claude/skills/in-the-way/SKILL.md")" hand-made
  assert_equal "$(readlink -f "$HOME/.claude/skills/fine")" "$(readlink -f "$PUB/.claude/skills/ops/fine")"
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'skill-deploy --quiet exited 1, its report:'
  assert_output --partial '    CONFLICT  in-the-way'
}

@test "the shell pass links the skills both checkouts added in one skill-deploy run" {
  printf '#!/bin/sh\necho ran >>"$SANDBOX/skill-deploy.calls"\nexec "$REAL_SKILL_DEPLOY" "$@"\n' >"$SANDBOX/skill-stub" && chmod +x "$SANDBOX/skill-stub"
  export SANDBOX REAL_SKILL_DEPLOY="$REPO_ROOT/.local/bin/skill-deploy" DOTFILES_SKILL_DEPLOY="$SANDBOX/skill-stub"
  add_upstream pub .claude/skills/ops/pub-skill/SKILL.md v1
  add_upstream priv .claude/skills/ops/priv-skill/SKILL.md v1
  run "$PULL"
  assert_success
  assert_output ''
  assert_equal "$(wc -l <"$SANDBOX/skill-deploy.calls")" 1
  assert_equal "$(readlink -f "$HOME/.claude/skills/pub-skill")" "$(readlink -f "$PUB/.claude/skills/ops/pub-skill")"
  assert_equal "$(readlink -f "$HOME/.claude/skills/priv-skill")" "$(readlink -f "$PRIV/.claude/skills/ops/priv-skill")"
}

@test "--now from the private repo fast-forwards ~/.dotfiles-private" {
  merge priv v2
  run "$PULL" --now "$PRIV"
  assert_success
  assert_output --regexp '^~/\.dotfiles-private: fast-forwarded main '
  assert_equal "$(cat "$PRIV/f")" v2
}

@test "negative control: a dirty file the merge would overwrite stays put, and the line names it" {
  merge pub v2
  printf 'local edit\n' >"$PUB/f"
  before=$(head_of "$PUB")
  run "$PULL" --now "$PUB"
  assert_success
  assert_output --regexp '^~/\.dotfiles: not fast-forwarded, main stays at [0-9a-f]{8}: local files in the way: f$'
  assert_equal "$(head_of "$PUB")" "$before"
  assert_equal "$(cat "$PUB/f")" 'local edit'
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'local files in the way: f'
}

@test "a dirty file the merge does not touch does not block it, and keeps its edit" {
  printf 'g1\n' >"$SANDBOX/pub-up/g"
  git -C "$SANDBOX/pub-up" add g && git -C "$SANDBOX/pub-up" commit -qm g && git -C "$SANDBOX/pub-up" push -q origin HEAD:main
  git -C "$PUB" pull -q
  merge pub v2
  printf 'mine\n' >"$PUB/g"
  run "$PULL" --now "$PUB"
  assert_output --partial 'fast-forwarded main'
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(cat "$PUB/g")" mine
}

@test "local commits its upstream lacks: left alone and said" {
  merge pub v2
  printf 'h\n' >"$PUB/h" && git -C "$PUB" add h && git -C "$PUB" commit -qm local
  before=$(head_of "$PUB")
  run "$PULL" --now "$PUB"
  assert_output '~/.dotfiles: not fast-forwarded, main has local commits its upstream lacks'
  assert_equal "$(head_of "$PUB")" "$before"
}

@test "already current: says so" {
  run "$PULL" --now "$PUB"
  assert_output --regexp '^~/\.dotfiles: main already current at [0-9a-f]{8}$'
}

@test "--now for a repo that is not a stowed checkout prints nothing and moves nothing" {
  merge pub v2
  git init -q "$SANDBOX/other"
  run "$PULL" --now "$SANDBOX/other"
  assert_success
  assert_output ''
  assert_equal "$(cat "$PUB/f")" v1
  run "$PULL" --now "$SANDBOX/not-a-dir"
  assert_success
  assert_output ''
}

@test "the shell pass moves both checkouts, then holds off until the interval passes" {
  merge pub v2
  merge priv v2
  run "$PULL"
  assert_success
  assert_output ''
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(cat "$PRIV/f")" v2
  merge priv v3
  run "$PULL"
  assert_equal "$(cat "$PRIV/f")" v2
  DOTFILES_AUTOPULL_INTERVAL=0 run "$PULL"
  assert_equal "$(cat "$PRIV/f")" v3
}

@test "the shell pass with no private checkout still moves the public one" {
  rm -rf "$PRIV"
  merge pub v2
  run "$PULL"
  assert_success
  assert_equal "$(cat "$PUB/f")" v2
}

@test "an untracked file at a path the merge adds stays put, and the line names it" {
  printf 'g1\n' >"$SANDBOX/pub-up/g"
  git -C "$SANDBOX/pub-up" add g && git -C "$SANDBOX/pub-up" commit -qm g && git -C "$SANDBOX/pub-up" push -q origin HEAD:main
  printf 'mine\n' >"$PUB/g"
  run "$PULL" --now "$PUB"
  assert_output --regexp ': local files in the way: g$'
  assert_equal "$(cat "$PUB/g")" mine
}

@test "the silent shell pass logs a checkout it could not move" {
  git -C "$PRIV" checkout -q --detach
  run "$PULL"
  assert_output ''
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial '~/.dotfiles-private: detached HEAD, left alone'
}

# rust_tool <crate> <bin> <mtime> -> $PUB/.local/src/<crate> holds a built <bin> dated @<mtime>, linked
# from ~/.local/bin as build_local_rust_tools links it; `cargo` is a stub that logs its directory and
# exits 101 when $SANDBOX/cargo.fail exists, or dates every built binary now when $SANDBOX/cargo.builds
# exists (a crate or path dependency changed), else touches nothing (a no-op build).
rust_tool() {
  local crate="$PUB/.local/src/$1"
  mkdir -p "$crate/target/release" "$HOME/.local/bin"
  : >"$crate/Cargo.toml"
  : >"$crate/target/release/$2" && touch -d "@$3" "$crate/target/release/$2"
  ln -sfn "$crate/target/release/$2" "$HOME/.local/bin/$2"
  cat >"$SANDBOX/bin/cargo" <<'STUB'
#!/bin/sh
printf 'cargo %s in %s\n' "$*" "$PWD" >>"$NOTES_FIXTURE/calls.log"
[ -e "$SANDBOX/cargo.fail" ] && { echo 'error[E0425]: stub'; exit 101; }
[ -e "$SANDBOX/cargo.builds" ] && touch target/release/*
exit 0
STUB
  chmod +x "$SANDBOX/bin/cargo"
  export SANDBOX
}

# unit <bin> <state> <started> -> the systemctl stub serves <bin>.service as <state> since @<started>
unit() {
  printf '%s\n' "$2" >"$NOTES_FIXTURE/systemctl.show.$1.service.ActiveState"
  printf '@%s\n' "$3" >"$NOTES_FIXTURE/systemctl.show.$1.service.ActiveEnterTimestamp"
}

@test "a fast-forward that changes a crate rebuilds its tool and restarts the unit running the old binary" {
  rust_tool agent-web agent-web 500
  rust_tool hub-tui hub 500
  unit agent-web active 1000
  touch "$SANDBOX/cargo.builds"
  merge pub v2
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'fast-forwarded main'
  assert_line '~: rebuilt agent-web (cargo build --release)'
  assert_line '~: rebuilt hub (cargo build --release)'
  assert_line '~: restarted agent-web.service on the new agent-web'
  assert_called "cargo build --release --quiet in $PUB/.local/src/agent-web"
  assert_called "cargo build --release --quiet in $PUB/.local/src/hub-tui"
  assert_called 'systemctl --user restart agent-web.service'
  assert_not_called 'systemctl --user restart hub.service'
}

@test "a current tool is not restarted, and one built by hand after its unit started is, though the checkout did not move" {
  rust_tool agent-web agent-web 500
  unit agent-web active 1000
  run "$PULL" --now "$PUB"
  assert_success
  refute_line --partial 'rebuilt'
  refute_line --partial 'restarted'
  assert_called "cargo build --release --quiet in $PUB/.local/src/agent-web"
  assert_not_called 'systemctl --user restart'
  touch -d @2000 "$PUB/.local/src/agent-web/target/release/agent-web"
  run "$PULL" --now "$PUB"
  assert_success
  refute_line --partial 'rebuilt'
  assert_line '~: restarted agent-web.service on the new agent-web'
}

@test "a unit that is not running is never started" {
  rust_tool agent-web agent-web 500
  unit agent-web inactive 1000
  touch "$SANDBOX/cargo.builds"
  run "$PULL" --now "$PUB"
  assert_success
  assert_line '~: rebuilt agent-web (cargo build --release)'
  assert_not_called 'systemctl --user restart'
}

@test "a failed build is named on the line and logged, the old binary and its unit stay, and the pull still succeeds" {
  rust_tool agent-web agent-web 500
  unit agent-web active 1000
  touch "$SANDBOX/cargo.fail"
  merge pub v2
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --index 0 --partial 'fast-forwarded main'
  assert_line --partial '~: cargo build of agent-web failed (exit 101), the binary on disk stays; report in'
  assert_not_called 'systemctl --user restart'
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'error[E0425]: stub'
}

@test "negative control: a link into another tree's target/release is not built" {
  rust_tool agent-web agent-web 500
  mkdir -p "$SANDBOX/elsewhere/.local/src/x/target/release"
  : >"$SANDBOX/elsewhere/.local/src/x/Cargo.toml"
  : >"$SANDBOX/elsewhere/.local/src/x/target/release/x"
  ln -sfn "$SANDBOX/elsewhere/.local/src/x/target/release/x" "$HOME/.local/bin/x"
  run "$PULL" --now "$PUB"
  assert_success
  assert_called "in $PUB/.local/src/agent-web"
  assert_not_called "in $SANDBOX/elsewhere"
}

@test "a failed build still restarts a unit older than the binary on disk, and an empty budget builds nothing" {
  rust_tool agent-web agent-web 2000
  unit agent-web active 1000
  touch "$SANDBOX/cargo.fail"
  run "$PULL" --now "$PUB"
  assert_success
  assert_line --partial '~: cargo build of agent-web failed (exit 101)'
  assert_line '~: restarted agent-web.service on the new agent-web'
  rm "$SANDBOX/cargo.fail"
  : >"$NOTES_FIXTURE/calls.log"
  DOTFILES_AUTOPULL_BUILD_SECS=0 run "$PULL" --now "$PUB"
  assert_success
  assert_line '~: build budget of 0s spent, agent-web not rebuilt'
  assert_not_called 'cargo build'
}

# runner <name> <kind> <mtime> -> an agentctl conf for <name> whose COMMAND runs ~/.local/bin/<name>,
# a link to a script in the public checkout dated @<mtime>, as stow links one
runner() {
  mkdir -p "$PUB/.local/bin" "$HOME/.local/bin" "$AGENTCTL_CONF_DIR"
  : >"$PUB/.local/bin/$1" && touch -d "@$3" "$PUB/.local/bin/$1"
  ln -sfn "$PUB/.local/bin/$1" "$HOME/.local/bin/$1"
  printf 'NAME=%s\nKIND=%s\nCOMMAND="$HOME/.local/bin/%s --watch"\n' "$1" "$2" "$1" >"$AGENTCTL_CONF_DIR/$1.conf"
}

@test "a persistent runner whose script changed after its unit started is restarted, a current one is not (ar-1633)" {
  runner triage persistent 2000
  runner watcher persistent 500
  unit agentctl@triage active 1000
  unit agentctl@watcher active 1000
  run "$PULL" --now "$PUB"
  assert_success
  assert_line '~: restarted agentctl@triage.service on the new triage'
  assert_called 'systemctl --user restart agentctl@triage.service'
  assert_not_called 'systemctl --user restart agentctl@watcher.service'
}

@test "negative control: a oneshot runner, or a persistent one that is not running, is never restarted" {
  runner nightly oneshot 2000
  runner triage persistent 2000
  unit agentctl@nightly active 1000
  unit agentctl@triage inactive 1000
  run "$PULL" --now "$PUB"
  assert_success
  refute_line --partial 'restarted'
  assert_not_called 'systemctl --user restart'
}

@test "a quoted KIND, \${HOME} in a single-quoted COMMAND and a later COMMAND line read as agentctl's source would" {
  runner triage persistent 2000
  runner old persistent 2000
  printf '%s\n' "NAME=triage" "KIND='persistent'" 'COMMAND="$HOME/.local/bin/old"' "COMMAND='\${HOME}/.local/bin/triage --watch'" >"$AGENTCTL_CONF_DIR/triage.conf"
  rm "$AGENTCTL_CONF_DIR/old.conf"
  unit agentctl@triage active 1000
  run "$PULL" --now "$PUB"
  assert_success
  assert_line '~: restarted agentctl@triage.service on the new triage'
  refute_line --partial 'on the new old'
}
