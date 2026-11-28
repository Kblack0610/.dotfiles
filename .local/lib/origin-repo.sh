# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# origin-repo.sh - the one parse of a checkout's origin URL into <owner>/<repo>, for every script
# that asks gh (or a cache keyed by repo) about a checkout: agent-land, fleet-sessions,
# credit-backfill, session-outcomes.sh, fleet-bench, fleet-dispatch and tmux/worktree.sh. Pinned by
# tests/unit/origin_repo.bats.
# And the one test of which forge is a checkout's canonical one (fleet-dispatch, fleet-bench),
# and the one way a headless runner reaches a GitHub origin (github_over_https).
# And the one reader of a checkout's place in its repo: main_checkout (its main checkout, the same
# from a linked worktree) and is_linked_checkout (whether it is a linked worktree). tmux/worktree.sh
# (wt_main_repo, wt_is_linked), tmux/worlds.sh, agent-ask, agent-queue, dotfiles-autopull, fleet-bench,
# fleet-dispatch and fleet-worker-panel.sh read them here. fleet-worker-panel.sh runs on a worker
# from text, so fleet_host_panel sends this file ahead of it.

# origin_repo <dir> [host] -> <owner>/<repo> of <dir>'s origin remote: the URL's last two path
# parts, trailing slashes and .git dropped, so https://host/o/r(.git)(/), git@host:o/r.git and
# ssh://git@host:port/o/r.git all give o/r. Nothing and rc 1 when <dir> is empty or has no
# origin, or when [host] is given and the origin's host is not it (case-insensitive). <dir> is
# required: `git -C ""` reads the current directory, which would answer for the wrong checkout.
origin_repo() {
  local url
  [ -n "${1:-}" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) && [ -n "$url" ] || return 1
  [ -z "${2:-}" ] || [ "$(url_host "$url")" = "${2,,}" ] || return 1
  url_repo "$url"
}

# url_repo <url> -> <owner>/<repo> of a remote URL, as origin_repo reads it.
url_repo() { sed -E 's#/+$##; s#\.git$##; s#.*[/:]([^/:]+/[^/:]+)$#\1#' <<<"$1"; }

# main_checkout <dir> -> the MAIN checkout of the repo containing <dir>, rc 1 for none.
#
# Via --git-common-dir, so it gives the same answer from inside a linked worktree as from the main
# one: `wt new` run inside `dotfiles-agent-1` must cut `dotfiles-agent-2`, not
# `dotfiles-agent-1-agent-1`. A submodule's common dir is <super>/.git/modules/<name>, whose
# core.worktree names its checkout; a bare repo has none. The probe is needed: --git-dir with no
# core.worktree takes the cwd as the toplevel. A deinitialised submodule keeps core.worktree, so the
# checkout must still exist.
main_checkout() {
  local common top
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
  */.git) printf '%s\n' "${common%/.git}" ;;
  *)
    git --git-dir="$common" config --get core.worktree >/dev/null 2>&1 || return 1
    top=$(git --git-dir="$common" rev-parse --show-toplevel 2>/dev/null) && [ -d "$top" ] || return 1
    printf '%s\n' "$top"
    ;;
  esac
}

# is_linked_checkout <dir> -- rc 0 only inside a LINKED worktree. In a main checkout (a submodule's
# too) --git-dir and --git-common-dir are the same path; in a linked one --git-dir is
# <common>/worktrees/<name>. The guard that stops `reap` ever pointing at a main checkout. rc 1 for
# a directory outside any repo.
is_linked_checkout() {
  local gitdir common
  { read -r gitdir && read -r common; } < <(git -C "${1:-.}" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  [ -n "${gitdir:-}" ] && [ -n "${common:-}" ] && [ "$gitdir" != "$common" ]
}

# origin_host <dir> -> the host of <dir>'s origin remote, lower-cased (url_host); nothing for a
# path origin, and rc 1 with no origin.
origin_host() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) && [ -n "$url" ] || return 1
  url_host "$url"
}

# url_host <url> -> the host of a remote URL, lower-cased: the authority, then past any
# user:password@ (an @ may be in the password), then before a port or the scp form's `:path`.
url_host() {
  local host=${1#*://}
  host=${host%%/*} host=${host##*@} host=${host%%:*}
  printf '%s\n' "${host,,}"
}

# host_is_github <host> -- exit 0 when <host> may serve a GitHub repo: github.com, ssh.github.com or a
# github.com-<name> ssh alias, or no host at all (a path origin). The one list of them.
host_is_github() { case "${1,,}" in ''|github.com|ssh.github.com|github.com-*) return 0 ;; *) return 1 ;; esac; }

# origin_on_github <dir> -- exit 0 when <dir>'s origin may be a GitHub repo (host_is_github). rc 1 for
# any other host, or no origin.
origin_on_github() {
  local host
  host=$(origin_host "$1") || return 1
  host_is_github "$host"
}

# store_name <host> <owner/repo> -> the PR store's key of a repo (`schedules-sync repos`): owner/repo on
# GitHub (host_is_github), host/owner/repo anywhere else. The one host rule: git-release.sh,
# credit-backfill, fleet-sessions and agent-land all build the key through it. A Forgejo host that is
# an alias of the store's is mapped by so_store_key (session-outcomes.sh), the caller's step.
store_name() { if host_is_github "$1"; then printf '%s\n' "$2"; else printf '%s/%s\n' "${1,,}" "$2"; fi; }

# origin_store_name <dir> -> store_name of <dir>'s origin remote; nothing and rc 1 with no origin.
origin_store_name() {
  local repo host
  repo=$(origin_repo "$1") && host=$(origin_host "$1") || return 1
  store_name "$host" "$repo"
}

# forge_marked <checkout> -- exit 0 when the checkout commits the mirror workflow, the marker that
# says Forgejo is the repo's canonical forge (home-config), whether or not failover is on.
forge_marked() { [ -n "$1" ] && { [ -f "$1/.forgejo/workflows/mirror-to-github.yaml" ] || [ -f "$1/.forgejo/workflows/mirror-to-github.yml" ]; }; }

# forge_repo_name <checkout> -> the repo's name on its GitHub mirror (the key of its failover state):
# the last path part of the first remote on github.com, else the name of the main checkout's directory,
# so every worktree of a repo reads one state file. forge-guard.py's repo_name is the same rule.
forge_repo_name() {
  local rn url
  for rn in $(git -C "$1" remote 2>/dev/null); do
    url=$(git -C "$1" remote get-url --push "$rn" 2>/dev/null) || continue
    case "$(url_host "$url")" in github.com|ssh.github.com|github.com-*) url_repo "$url" | sed 's#.*/##'; return 0 ;; esac
  done
  basename "$(main_checkout "$1")"
}

# forge_failover_file <checkout> -> the path of the repo's failover state file. Its one writer is
# forge-failover; it exists exactly while the repo lands on GitHub.
forge_failover_file() { printf '%s/%s\n' "${FORGE_STATE_DIR:-$HOME/.local/state/forge}" "$(forge_repo_name "$1")"; }

# forge_failover_on <checkout> -- exit 0 while forge-failover has the repo landing on GitHub.
# An empty or missing state directory answers without a git call: every reader asks per checkout.
forge_failover_on() { compgen -G "${FORGE_STATE_DIR:-$HOME/.local/state/forge}/*" >/dev/null && [ -f "$(forge_failover_file "$1")" ]; }

# forge_canonical <checkout> -- exit 0 when the repo's canonical forge is Forgejo: it commits the
# mirror workflow, the marker forge-guard.py reads (home-config), and forge-failover is not on. With
# failover on, every reader (agent-land, forge-guard, fleet-dispatch, project-map) sees a GitHub repo.
forge_canonical() { forge_marked "$1" && ! forge_failover_on "$1"; }

# github_over_https -- route this process's git traffic for github.com over HTTPS, so the gh
# credential helper (its token is in ~/.config/gh/hosts.yml, readable with nobody logged in)
# authenticates instead of an ssh-agent key. A runner's boot catch-up starts before any login
# loads a key: on 2026-11-17 07:40 trader-research-sync and skill-toggle both failed `git fetch`
# with `Permission denied (publickey)`. It appends to GIT_CONFIG_COUNT, so it keeps any env config
# already set and the checkout's remote stays as it is. Per runner, not in agentctl@.service: the
# gh token has no `workflow` scope, so a push of a workflow file over HTTPS is refused.
github_over_https() {
  local n=${GIT_CONFIG_COUNT:-0} from
  for from in git@github.com: ssh://git@github.com/ ssh://git@github.com:22/; do
    export "GIT_CONFIG_KEY_$n=url.https://github.com/.insteadOf" "GIT_CONFIG_VALUE_$n=$from"
    n=$((n + 1))
  done
  export GIT_CONFIG_COUNT=$n GIT_TERMINAL_PROMPT=0
}
