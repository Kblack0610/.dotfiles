# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# origin-repo.sh - the one parse of a checkout's origin URL into <owner>/<repo>, for every script
# that asks gh (or a cache keyed by repo) about a checkout: agent-land, fleet-sessions,
# credit-backfill, session-outcomes.sh and tmux/worktree.sh. Pinned by tests/unit/origin_repo.bats.
# And the one test of which forge is a checkout's canonical one (fleet-dispatch, fleet-bench),
# and the one way a headless runner reaches a GitHub origin (github_over_https).

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

# origin_on_github <dir> -- exit 0 when <dir>'s origin may be a GitHub repo: its host is github.com,
# ssh.github.com or a github.com-<name> ssh alias, or it is a path origin (no host). rc 1 for any
# other host, or no origin.
origin_on_github() {
  local host
  host=$(origin_host "$1") || return 1
  case "$host" in ''|github.com|ssh.github.com|github.com-*) return 0 ;; *) return 1 ;; esac
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
  basename "$(dirname "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
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
