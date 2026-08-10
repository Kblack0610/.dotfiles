#!/usr/bin/env bash
# pr-viewer.sh - open pull requests across the configured repos, grouped by repo.
#
# Usage: pr-viewer.sh [verb]
#
# Verbs:
#   --list        the rows, TSV, one per line. The data behind the picker, split out so it
#                 is assertable without a terminal.
#   --help, -h    this text
#   (no verb)     open the picker
#
# Row format (TSV), machine columns first, display last:
#   1 repo · 2 number · 3 url · 4 DISPLAY
# A group header is a row whose repo column is literally `head`, so the picker can skip it
# the same way the other grouped surfaces do.
#
# Config: PR_REPOS_CONF (default: pr-repos.conf beside this script), one owner/repo per
# line, `#` comments ignored.

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

# Every tunable is ${VAR:-default} right here. The old absolute
# "$HOME/.dotfiles/.local/src/tmux/pr-repos.conf" broke the moment the repo moved and made
# this panel untestable, because a fixture had nowhere to redirect it (CONVENTIONS.md).
PR_REPOS_CONF="${PR_REPOS_CONF:-$PANEL_DIR/pr-repos.conf}"
PR_LIMIT="${PR_LIMIT:-50}"
PR_TITLE_WIDTH="${PR_TITLE_WIDTH:-45}"

# ── Config ───────────────────────────────────────────────────────────────────
# Emit one validated owner/repo per line. A malformed line warns and is skipped rather than
# aborting: one typo in the config should not take the whole panel down.
read_repos() {
  [ -f "$PR_REPOS_CONF" ] || {
    panel_fail "no repo config at $PR_REPOS_CONF (one owner/repo per line)"
    return 1
  }
  local line
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    if [[ "$line" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
      printf '%s\n' "$line"
    else
      panel_warn "skipping malformed repo: $line"
    fi
  done < "$PR_REPOS_CONF"
}

# ── Rows ─────────────────────────────────────────────────────────────────────
# One `gh` call per repo. The heredoc is QUOTED, so nothing from the config or from a PR
# title is ever interpolated into python source -- the old form used an unquoted <<PYTHON
# and spliced $json_file and $repo straight into the program text.
#
# The JSON travels in the ENVIRONMENT, not on stdin: stdin is already carrying the program
# itself (`python3 -` reads the heredoc), so piping the data there makes the two collide and
# python tries to parse the JSON as source. Env also keeps the old /tmp/pr-viewer-$$ scratch
# directory (and its `rm -rf`) out of the picture entirely.
_repo_rows() {
  local repo="$1" json
  json="$(gh pr list -R "$repo" \
    --json number,title,createdAt,isDraft,reviewDecision,statusCheckRollup,url \
    --limit "$PR_LIMIT" --state open 2>/dev/null)" || return 0
  [ -n "$json" ] && [ "$json" != "[]" ] || return 0

  PR_JSON="$json" python3 - "$repo" "$PR_TITLE_WIDTH" \
    "$C_SEL" "$C_DIM" "$C_OFF" "$G_ATTN" "$G_BUSY" "$G_OK" "$G_IDLE" <<'PYTHON'
import json, os, sys
from datetime import datetime, timezone

repo, width, c_sel, c_dim, c_off, g_attn, g_busy, g_ok, g_idle = sys.argv[1:10]
width = int(width)
prs = json.loads(os.environ['PR_JSON'])

def age(iso):
    try:
        created = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        s = (datetime.now(timezone.utc) - created).total_seconds()
    except Exception:
        return '?'
    for cutoff, div, unit in ((3600, 60, 'm'), (86400, 3600, 'h'),
                              (604800, 86400, 'd'), (2592000, 604800, 'w')):
        if s < cutoff:
            return f'{int(s / div)}{unit}'
    return f'{int(s / 2592000)}mo'

def ci_glyph(checks):
    if not checks:
        return g_idle
    if any(c.get('conclusion') in ('FAILURE', 'ERROR') for c in checks):
        return g_attn
    if any(c.get('status') in ('PENDING', 'QUEUED', 'IN_PROGRESS') for c in checks):
        return g_busy
    return g_ok

def review_glyph(decision):
    return {'APPROVED': g_ok, 'CHANGES_REQUESTED': g_attn,
            'REVIEW_REQUIRED': g_busy}.get(decision, g_idle)

# Priority: ! > ~ > OK > idle. Kept identical to the previous implementation.
def combined(ci, rev):
    if g_attn in (ci, rev):
        return g_attn
    if g_busy in (ci, rev):
        return g_busy
    return g_ok if ci == rev == g_ok else g_idle

rows = []
for pr in prs:
    ci = ci_glyph(pr.get('statusCheckRollup') or [])
    rev = review_glyph(pr.get('reviewDecision') or '')
    draft = f' {c_dim}[draft]{c_off}' if pr.get('isDraft') else ''
    display = '  %s #%-5s %-*s %5s  [%s CI][%s Rev]%s' % (
        combined(ci, rev), pr.get('number', ''), width,
        (pr.get('title') or '')[:width], age(pr.get('createdAt') or ''),
        ci, rev, draft)
    rows.append((combined(ci, rev), pr.get('number', ''), pr.get('url', ''), display))

# The header carries the per-repo status roll-up, so it has to be emitted alongside the
# rows rather than by the caller (which would have to re-derive the glyphs).
summary = ''.join(g for g in (g_attn, g_busy, g_ok)
                  if any(r[0] == g for r in rows))
print('head\t\t\t%s--- %s %s (%d) ---%s' % (c_sel, repo, summary, len(rows), c_off))
for _, number, url, display in rows:
    print('%s\t%s\t%s\t%s' % (repo, number, url, display))
PYTHON
}

cmd_list() {
  panel_need gh
  panel_need python3

  # `gh auth status` was checked while `gh` itself never was, so a machine without gh
  # reported an auth problem. Check the binary first, then the credential.
  gh auth status >/dev/null 2>&1 || {
    panel_fail "not authenticated with gh (run: gh auth login)"
    return 1
  }

  local repo n=0
  while IFS= read -r repo; do
    n=$((n + 1))
    _repo_rows "$repo"
  done < <(read_repos)

  # An empty repo list is a broken config, not an empty result set -- say so rather than
  # rendering a blank picker that reads as "no open PRs".
  [ "$n" -gt 0 ] || panel_fail "no valid repos in $PR_REPOS_CONF"
}

# ── Picker ───────────────────────────────────────────────────────────────────
cmd_pick() {
  panel_need fzf

  panel_fzf_opts
  panel_fzf_table

  local picked repo number url
  picked="$(cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --with-nth=4.. \
    --prompt='pr > ' \
    --header=$'enter=open in browser | ctrl-d=details | ctrl-r=reload\n' \
    --bind="ctrl-r:reload($(printf '%q' "$SELF") --list)" \
    --bind="ctrl-d:execute($(printf '%q' "$SELF") --show {1} {2} | less -R)" \
    "$(panel_fzf_preview right 45)" \
    --preview="$(printf '%q' "$SELF") --show {1} {2}")"

  [ -n "$picked" ] || return 0
  IFS=$'\t' read -r repo number url _ <<< "$picked"
  # Selecting a group header is a no-op, not an error.
  [ "$repo" != head ] && [ -n "$url" ] || return 0
  gh pr view "$number" -R "$repo" --web >/dev/null 2>&1
}

# ── Details ──────────────────────────────────────────────────────────────────
# Used by both the preview window and ctrl-d, so the two can never disagree.
cmd_show() {
  local repo="${1:-}" number="${2:-}"
  [ -n "$repo" ] && [ "$repo" != head ] && [ -n "$number" ] || return 0
  panel_have gh || {
    panel_hint 'gh not on PATH'
    return 0
  }
  gh pr view "$number" -R "$repo" 2>/dev/null || panel_hint "could not read $repo#$number"
}

# ── The test seam ────────────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
--list) cmd_list ;;
--show) shift && cmd_show "$@" ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
