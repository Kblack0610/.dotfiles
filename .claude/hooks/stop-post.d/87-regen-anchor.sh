#!/bin/bash
# Stop-post: regenerate this project's anchor AUTO block, so the next session's
# preflight injects a current one.
#
# regen-anchor.sh was wired to NOTHING. Its only caller was a skill a human had to
# invoke by hand, and the result was an AUTO block two months stale: the dotfiles
# anchor advertised its latest eval as 2026-06-08 while the directory held
# 2026-08-09, and the file's Aug mtime came from someone hand-appending BELOW the
# AUTO:END marker. Nothing failed, because a stale generated block and a fresh one
# render identically -- the same class of silent drift as the lab index rendering
# every project as a dash.
#
# It matters more now than it did: the session preflight stopped listing plans and
# lessons itself and delegates both to this block. Delegating to a generator nobody
# runs would be a straight regression, so the generator gets a caller in the same
# change.
#
# Ordered AFTER 85-sync-plans.sh on purpose: that hook is what copies this session's
# plans into ~/.agent/plans/{project}/, and the anchor's "Active plans" section reads
# that directory. Running first would publish the previous session's list.
#
# Cheap enough to run every Stop: pure bash + jq over a handful of directory listings,
# no network. And it only WRITES when the content actually changed (md_splice's cmp
# guard), which is what keeps ~/.agent -- a git repo with a 15-minute auto-commit --
# from gaining a meaningless anchor commit every turn.
#
# Never blocks; always exits 0. --rotate is deliberately NOT passed: rotation rewrites
# a hand-curated section, which a hook must not do behind a human's back.

set -uo pipefail

# The DEPLOYED path, not the repo path. ~/.claude/skills is flat and stable:
# skill-deploy flattens <category>/<name> while linking, so this keeps resolving
# across a re-categorisation and across a skill moving between the public and
# private repos. The repo path did neither - it broke the moment project-index
# moved into memory/.
REGEN="$HOME/.claude/skills/project-index/regen-anchor.sh"
[ -x "$REGEN" ] || exit 0

# --- project ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
# Guarded source, same reason as 85-sync-plans.sh: under stow --no-folding this hook can
# run from a commit that lands before the symlink does.
if [ -r "$HOME/.config/shared-hooks/project-name.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.config/shared-hooks/project-name.sh"
fi
if declare -F resolve_project_name >/dev/null 2>&1; then
  PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
else
  PROJECT_NAME=$(basename "$PROJECT_DIR")
  PROJECT_NAME=${PROJECT_NAME#.}
fi
[ -n "$PROJECT_NAME" ] || exit 0

# Only refresh an anchor that already exists. Scaffolding one is a deliberate act
# (`/project-index`), and a Stop hook that mints project files for every directory
# anyone opens is how ~/.agent filled with namespaces nobody reads.
[ -f "$HOME/.agent/anchors/$PROJECT_NAME.md" ] || exit 0

timeout 20 "$REGEN" "$PROJECT_NAME" >/dev/null 2>&1 || true

exit 0
