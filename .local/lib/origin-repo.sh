# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# origin-repo.sh - the one parse of a checkout's origin URL into <owner>/<repo>, for every script
# that asks gh (or a cache keyed by repo) about a checkout: agent-land, fleet-sessions,
# credit-backfill, session-outcomes.sh and tmux/worktree.sh. Pinned by tests/unit/origin_repo.bats.
# And the one test of which forge is a checkout's canonical one (fleet-dispatch, fleet-bench).

# origin_repo <dir> [host] -> <owner>/<repo> of <dir>'s origin remote: the URL's last two path
# parts, trailing slashes and .git dropped, so https://host/o/r(.git)(/), git@host:o/r.git and
# ssh://git@host:port/o/r.git all give o/r. Nothing and rc 1 when <dir> is empty or has no
# origin, or when [host] is given and the origin's host is not it (case-insensitive). <dir> is
# required: `git -C ""` reads the current directory, which would answer for the wrong checkout.
origin_repo() {
  local url host
  [ -n "${1:-}" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) && [ -n "$url" ] || return 1
  if [ -n "${2:-}" ]; then
    # The authority, then past any user:password@ (an @ may be in the password), then before a port
    # or the scp form's `:path`.
    host=${url#*://} host=${host%%/*} host=${host##*@} host=${host%%:*}
    [ "${host,,}" = "${2,,}" ] || return 1
  fi
  sed -E 's#/+$##; s#\.git$##; s#.*[/:]([^/:]+/[^/:]+)$#\1#' <<<"$url"
}

# origin_off_github <dir> -- exit 0 when <dir>'s origin names a host that is not github.com (a Forgejo
# clone such as External/asset-library), so gh can never read its PRs. A path origin names no host.
origin_off_github() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) && [[ "$url" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// || "$url" =~ ^[^/]+: ]] \
    && ! origin_repo "$1" github.com >/dev/null
}

# forge_canonical <checkout> -- exit 0 when the repo's canonical forge is Forgejo: it commits the
# mirror workflow, the marker forge-guard.py reads (home-config).
forge_canonical() { [ -n "$1" ] && { [ -f "$1/.forgejo/workflows/mirror-to-github.yaml" ] || [ -f "$1/.forgejo/workflows/mirror-to-github.yml" ]; }; }
