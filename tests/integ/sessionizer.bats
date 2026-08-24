#!/usr/bin/env bats
# sessionizer.sh -- Prefix+f, the one picker that reaches outside the current tmux world.
#
# integ tier: the script runs as a subprocess against the recording tmux stub, so every
# assertion is "which tmux command did it actually issue". The fzf picker itself is not
# exercised here (there is nothing to assert about a picker's rendering that is not a test of
# the fake); the row source behind it, --list, is.
#
# This is the first panel migrated onto panel-lib.sh, and it was the worst conformer: no strict
# mode, a bare `| fzf` with no flags, no dependency check, an unquoted `[[ -z $TMUX ]]`, and a
# `pgrep tmux` probe standing in for the switch-vs-attach question.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SESSIONIZER="$REPO_ROOT/.local/src/tmux/sessionizer.sh"
  export SESSIONIZER

  # A fixture tree with THREE candidate roots, so a test can tell "found the right one" from
  # "found the only one". One root deliberately does not exist, to cover the filter.
  #
  # The candidates are REPOS now, so every fixture that has to appear in --list carries a
  # `.git`. A bare directory is no longer a row, which is the point of the change and is
  # asserted below rather than assumed here.
  mkdir -p "$SANDBOX/roots/alpha/proj-one/.git" \
    "$SANDBOX/roots/alpha/not-a-repo/src" \
    "$SANDBOX/roots/alpha/proj-one/vendored/.git" \
    "$SANDBOX/roots/alpha/proj-one/parked-repo/.git" \
    "$SANDBOX/roots/alpha/proj-one/vendor/third-party/.git" \
    "$SANDBOX/roots/alpha/proj-one/.claude/worktrees/agent-abc123/.git" \
    "$SANDBOX/roots/alpha/node_modules/should-be-pruned/.git" \
    "$SANDBOX/roots/beta/my.dotted.project/.git" \
    "$SANDBOX/roots/beta/.dotted-root/.git" \
    "$SANDBOX/roots/selfrepo/.git/hooks" \
    "$SANDBOX/roots/selfrepo/inner/deeper"

  # Two repos nested one level inside proj-one, identical on disk apart from this file. Only
  # `vendored` is DECLARED, so the pair is the whole nesting rule and its negative control:
  # whatever separates them cannot be depth, position, or the prune list.
  printf '[submodule "vendored"]\n\tpath = vendored\n\turl = git@example.com:x/vendored.git\n' \
    > "$SANDBOX/roots/alpha/proj-one/.gitmodules"

  # Worktrees, read from $WT_ROOT's default ($HOME/.worktrees, and $HOME is the sandbox). A
  # LINKED worktree's .git is a FILE; the plain directory beside it is the negative control.
  mkdir -p "$HOME/.worktrees/proj-one-agent-1" "$HOME/.worktrees/not-a-worktree"
  printf 'gitdir: /nowhere/.git/worktrees/proj-one-agent-1\n' > "$HOME/.worktrees/proj-one-agent-1/.git"

  # A repo under ~/.agent, which is deliberately NOT a root: the agent runtime axis carries one
  # directory per project per axis, so it used to contribute a colliding row for every project
  # it had ever seen.
  mkdir -p "$HOME/.agent/plans/proj-one/.git"
  # COLON-separated, like PATH: $SANDBOX contains a space by design, and a space-delimited
  # list cannot express such a path at all. The first draft of the script used spaces and this
  # fixture is what exposed it.
  export SESSIONIZER_ROOTS="$SANDBOX/roots/alpha:$SANDBOX/roots/beta:$SANDBOX/roots/selfrepo:$SANDBOX/roots/nonexistent"

  # Two worlds that DECLARE directories, which is the routing table. Written with `~` the
  # way the real manifests are -- and necessarily so: $SANDBOX contains a space and the
  # manifest format is whitespace-delimited, so a literal sandbox path could not be
  # expressed here at all. That is the format's documented limitation, not a test dodge.
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  # A declared directory INSIDE a repo, which is the real ~/.notes/lab: a subdirectory of the
  # ~/.notes repo, so no repo walk can ever produce it and only the manifest can.
  mkdir -p "$HOME/declared-hub" "$HOME/declared-notes" "$HOME/dev/declared-lab" \
    "$HOME/declared-hub/inside" "$HOME/host-repo/.git" "$HOME/host-repo/declared-sub"
  printf 'ownname ~/declared-hub\nhub ~/declared-notes  nvim\nsub ~/host-repo/declared-sub\n' \
    > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'platform ~/dev/declared-lab\n' > "$TMUX_SERVERS_DIR/lab.conf"
}

# in_world <server> -- what the tmux stub reports for #{socket_path}. $TMUX has to be set
# too: an unset $TMUX is the outside-tmux branch, which is a different case entirely.
in_world() {
  export TMUX=/tmp/fake,1,0
  export STUB_SOCKET="/tmp/tmux-1000/$1"
}

# ── The name fold ────────────────────────────────────────────────────────────

@test "a dot in the directory name is folded to an underscore" {
  # tmux treats `.` as the window/pane separator in a target, so `-t my.project` addresses
  # window "project" of session "my". An unsanitised name silently addresses something else.
  run "$SESSIONIZER" --name "$SANDBOX/roots/beta/my.dotted.project"
  assert_success
  assert_output 'my_dotted_project'
}

@test "a leading dot is stripped rather than folded" {
  # `~/.dotfiles` is the project `dotfiles` everywhere else (project-name.sh), and
  # tmux-servers/hub.conf names its session `dotfiles` by hand. Folding gave `_dotfiles`, so
  # Prefix+f opened a SECOND session on the same directory.
  run "$SESSIONIZER" --name "$SANDBOX/roots/beta/.dotted-root"
  assert_success
  assert_output 'dotted-root'
}

@test "an ordinary name is passed through untouched" {
  run "$SESSIONIZER" --name "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_output 'proj-one'
}

@test "--name without a directory is rejected" {
  run "$SESSIONIZER" --name
  assert_failure
  assert_output --partial 'needs a directory'
}

# ── The row source ───────────────────────────────────────────────────────────

@test "--list finds the repos under every existing root" {
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial 'roots/alpha/proj-one'
  assert_line --partial 'roots/beta/my.dotted.project'
}

@test "--list leaves out a directory that is not a repo" {
  # The whole change in one assertion. A deep walk listed every directory under every root:
  # 1521 rows on the Mac, 1048 of them inside ~/.dotfiles, and 20+ of them sharing a basename
  # with another row -- and a session name IS the basename.
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'not-a-repo'
}

@test "--list drops a nested repo the one above it DECLARES as a submodule" {
  # A declared submodule is a pinned dependency sitting at a commit somebody else chose
  # (.dotfiles/.local/src/gungan). Nobody opens a session on one.
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial 'roots/alpha/proj-one'
  refute_output --partial 'vendored'
}

@test "--list keeps a nested repo NOBODY declared, which is where the work happens" {
  # ~/dev/bnb/games/engine holds unity-core, unity-core-harness and unity-core-playground as
  # gitlinks with no .gitmodules, each on its own feature branch. Dropping every nested repo
  # hid all three behind `engine`, on every machine, with no way to tell from the picker.
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial 'proj-one/parked-repo'
}

@test "--list prunes a third-party checkout by its directory name" {
  # Nesting is allowed now, so `vendor` has to earn its place in the prune list the way
  # node_modules does -- tests/vendor/bats-core is a real repo the walk would otherwise reach.
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'third-party'
}

@test "--list prunes the agent worktrees parked under .claude" {
  # platform/.claude/worktrees holds seven hash-named checkouts. They are real repos one level
  # inside a repo, so only the prune list keeps `agent-a19fdac4d8219d148` from being a session.
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'agent-abc123'
}

@test "a root that is itself a repo collapses to exactly one row" {
  # ~/.dotfiles is both a root and a repo, and it was 1048 of the 1521 rows on its own. One
  # repo, one session, no matter how deep it goes.
  run "$SESSIONIZER" --list
  assert_success
  assert_line "$SANDBOX/roots/selfrepo"
  refute_output --partial 'selfrepo/inner'
}

@test "--list carries the worktrees, which is the row source it used to miss entirely" {
  # ~/.worktrees was never a root, so the one directory kind this setup creates on purpose
  # (Prefix+F) was the one kind the picker could not reach.
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial '.worktrees/proj-one-agent-1'
}

@test "--list rejects a plain directory sitting in the worktree root" {
  # A linked worktree's .git is a FILE. Listing whatever else got parked in $WT_ROOT would
  # hand back a path `wt` does not consider a worktree at all.
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'not-a-worktree'
}

@test "--list carries a declared directory that lives INSIDE a repo" {
  # The real ~/.notes/lab: a subdirectory of the ~/.notes repo, and a row the repo walk can
  # never produce. The manifest is the routing table, so what it names is a place to work.
  run "$SESSIONIZER" --list
  assert_success
  assert_line --partial 'host-repo/declared-sub'
}

@test "the default roots do not include ~/.agent, repo or not" {
  # The agent runtime axis holds one directory per project per axis, so it produced several
  # rows per project -- and `~/.agent/plans/dotfiles` named its session `dotfiles`, the same
  # name as the dotfiles repo. Fixture is a REPO under ~/.agent, so exclusion is the root list
  # doing it, not the repo test.
  SESSIONIZER_ROOTS= run "$SESSIONIZER" --list
  assert_success
  refute_output --partial '.agent'
}

@test "--list prunes the directories it is configured to prune" {
  run "$SESSIONIZER" --list
  assert_success
  refute_output --partial 'node_modules'
  refute_output --partial '.git'
}

@test "SESSIONIZER_PRUNE is actually read" {
  # Prove the config key changes behaviour rather than merely existing. With the default prune
  # list replaced by something irrelevant, the repo hiding under node_modules must reappear.
  SESSIONIZER_PRUNE='nothing-matches-this' run "$SESSIONIZER" --list
  assert_output --partial 'node_modules/should-be-pruned'
}

@test "SESSIONIZER_DEPTH is actually read" {
  # Depth now bounds how far down a REPO may sit, so the fixture is a repo rather than a bare
  # directory. Its .git is one level deeper again, which the walk has to account for.
  mkdir -p "$SANDBOX/roots/alpha/a/b/c/d/deep-one/.git"
  SESSIONIZER_DEPTH=9 run "$SESSIONIZER" --list
  assert_output --partial 'deep-one'
  SESSIONIZER_DEPTH=1 run "$SESSIONIZER" --list
  refute_output --partial 'deep-one'
}

@test "--list fails loudly when no configured root exists" {
  # "Nothing to show" and "your config is wrong" must not print the same empty picker.
  SESSIONIZER_ROOTS="$SANDBOX/nope-one:$SANDBOX/nope-two" run "$SESSIONIZER" --list
  assert_failure
  assert_output --partial 'none of the configured roots exist'
}

# ── Landing in a session ─────────────────────────────────────────────────────

@test "inside tmux it switches the client rather than attaching" {
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'switch-client -t proj-one'
  assert_not_called 'attach -t'
}

@test "outside tmux it attaches instead of issuing a doomed switch-client" {
  # The pre-migration bug: with a server already running, the old code created the session
  # detached and then called switch-client with no client attached, which fails. `pgrep tmux`
  # was never the right question -- $TMUX is.
  run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'attach -t proj-one'
  assert_not_called 'switch-client'
}

@test "an existing session is reused, not recreated" {
  # The tmux stub answers has-session with rc 0, so the session always "exists". Creating one
  # anyway would clobber a live session's directory.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'has-session -t =proj-one'
  assert_not_called 'new-session'
}

@test "the session is addressed with the exact-match prefix" {
  # `has-session -t proj` would match a session merely PREFIXED with proj. The `=` makes it
  # exact, which is what keys ensure-vs-create correctly.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_called 'has-session -t =proj-one'
}

@test "a dotted directory reaches tmux already folded" {
  # The end-to-end version of the fold test: what matters is the name tmux SEES.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/beta/my.dotted.project"
  assert_success
  assert_called 'switch-client -t my_dotted_project'
  assert_not_called 'my.dotted.project'
}

@test "a dot-directory reaches tmux as the project's own session, not a second one" {
  # The end-to-end half of the strip. `assert_not_called '_dotted-root'` is the negative
  # control: it is exactly the name the old rule sent, and it is what put two sessions on one
  # directory.
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/beta/.dotted-root"
  assert_success
  assert_called 'switch-client -t dotted-root'
  assert_not_called '_dotted-root'
}

@test "a path that is not a directory is rejected before any tmux call" {
  run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one/nope"
  assert_failure
  assert_output --partial 'not a directory'
  assert_not_called 'new-session'
  assert_not_called 'switch-client'
}

# ── Which world a directory belongs to ───────────────────────────────────────
#
# The manifests in .config/tmux-servers/ already say where each declared directory lives.
# Before this, the picker ignored them and created the session on whatever socket happened
# to enclose it -- so Prefix+f on ~/dev/bnb/platform from hub built a SECOND `platform`
# beside lab's. Same disease as the leading-dot fold above, one layer up.

@test "--route reports the world that declares a directory" {
  run "$SESSIONIZER" --route "$HOME/dev/declared-lab"
  assert_success
  assert_output 'lab platform'
}

@test "--route uses the MANIFEST's session name, not the basename" {
  # hub.conf calls ~/declared-notes `hub`. Landing it as `declared-notes` would be a second
  # session on a directory that already has one -- which is the real ~/.notes case.
  run "$SESSIONIZER" --route "$HOME/declared-notes"
  assert_success
  assert_output 'hub hub'
}

@test "--route says here for a directory no manifest declares" {
  run "$SESSIONIZER" --route "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_output 'here proj-one'
}

@test "--route matches the declared directory EXACTLY, not its subdirectories" {
  # A subdir of a declared repo is its own piece of work, and it is not what the manifest
  # named. Routing it would drag you across worlds for a directory nobody registered.
  run "$SESSIONIZER" --route "$HOME/declared-hub/inside"
  assert_success
  assert_output 'here inside'
}

@test "a declared directory in ANOTHER world is handed to tmx, not created here" {
  # THE feature. Standing in lab, picking a hub-declared directory must hop, and must not
  # quietly build a duplicate on lab's socket.
  in_world lab
  run "$SESSIONIZER" "$HOME/declared-hub"
  assert_success
  assert_called 'tmx goto hub ownname'
  assert_not_called 'new-session'
  assert_not_called 'switch-client'
}

@test "a declared directory in THIS world is entered locally, with no hop" {
  # No detach for a session that is already right here -- that would be the jank with
  # nothing to show for it.
  in_world hub
  run "$SESSIONIZER" "$HOME/declared-hub"
  assert_success
  assert_called 'switch-client -t ownname'
  assert_not_called 'tmx goto'
}

@test "an UNdeclared directory still opens right here, whatever world that is" {
  # The blast radius of the whole change: only declared directories behave differently.
  in_world lab
  run "$SESSIONIZER" "$SANDBOX/roots/alpha/proj-one"
  assert_success
  assert_called 'switch-client -t proj-one'
  assert_not_called 'tmx goto'
}

@test "outside tmux, a declared directory still routes to its world" {
  # No enclosing world means nothing to compare against, so the manifest is the only
  # answer there is. tmx land attaches on the far side.
  run "$SESSIONIZER" "$HOME/dev/declared-lab"
  assert_success
  assert_called 'tmx goto lab platform'
  assert_not_called 'attach -t'
}

@test "a manifest that does not exist leaves every directory local" {
  # The picker must not depend on the manifests being there: a fresh machine, or a
  # TMUX_SERVERS_DIR typo, should degrade to the old behaviour rather than dying.
  in_world lab
  TMUX_SERVERS_DIR="$SANDBOX/no-such-manifests" run "$SESSIONIZER" "$HOME/declared-hub"
  assert_success
  assert_called 'switch-client -t declared-hub'
  assert_not_called 'tmx goto'
}

@test "a commented-out manifest line does not declare anything" {
  printf '# ownname ~/declared-hub\n' > "$TMUX_SERVERS_DIR/hub.conf"
  run "$SESSIONIZER" --route "$HOME/declared-hub"
  assert_success
  assert_output 'here declared-hub'
}

# ── Conformance, exercised rather than grepped ───────────────────────────────

@test "--help prints the header block without reaching for fzf" {
  run "$SESSIONIZER" --help
  assert_success
  assert_output --partial 'Usage: sessionizer.sh'
  assert_output --partial 'SESSIONIZER_ROOTS'
  refute_output --partial '#!/usr/bin/env'
}

@test "an unknown verb is rejected instead of being treated as a directory" {
  # The dispatch has to distinguish a flag typo from a real path argument: `--lst` must error,
  # while a bare word is still a directory to visit.
  run "$SESSIONIZER" --lst
  assert_failure
  assert_output --partial 'unknown verb'
  assert_not_called 'new-session'
}

@test "output is identical when invoked by a relative path" {
  # fzf --bind and display-popup both re-invoke a panel from wherever they happen to be.
  local abs rel
  abs="$("$SESSIONIZER" --list)"
  rel="$(cd "$REPO_ROOT/.local/src/tmux" && ./sessionizer.sh --list)"
  assert_equal "$rel" "$abs"
}

@test "it survives a sandbox path containing a space" {
  # $SANDBOX contains a space by design (sandbox.bash:32). This is the whole reason: the
  # pre-migration script built find arguments and a session name without strict quoting.
  mkdir -p "$SANDBOX/roots/alpha/has space here/.git"
  run "$SESSIONIZER" --list
  assert_output --partial 'has space here'
  TMUX=/tmp/fake,1,0 run "$SESSIONIZER" "$SANDBOX/roots/alpha/has space here"
  assert_success
  assert_called 'switch-client -t has space here'
}
