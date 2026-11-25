# dotfiles-repos.sh: where the two stowed dotfiles repos are, and the test that a dir is a repo
# root. Sourced by dotfiles-deploy, dotfiles-drift, skill-deploy and skill-drift.

PUB="${DOTFILES:-$HOME/.dotfiles}"
PRIV="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}"

# is_repo_root <dir> - is <dir> the root of a git working tree?
#
# NOT `[ -d "$dir/.git" ]`, which is FALSE for a git WORKTREE: there `.git` is a regular file
# holding `gitdir: <main>/.git/worktrees/<name>`. Worktrees are the working convention in these
# repos, and that test made dotfiles-deploy and dotfiles-drift skip the tree being worked in and
# still print clean. `rev-parse --show-toplevel` is worktree-blind; comparing it with <dir> keeps
# a SUBDIRECTORY of an unrelated checkout (a mistyped DOTFILES_PRIVATE) from passing as a repo.
is_repo_root() {
  local dir="$1" top
  [ -d "$dir" ] || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  [ "$(readlink -f -- "$top")" = "$(readlink -f -- "$dir")" ]
}
