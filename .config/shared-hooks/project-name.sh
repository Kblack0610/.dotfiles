#!/bin/bash
# Resolve a canonical project name from an absolute path.
# Sourced by session-preflight.sh, stop hooks, etc. Single source of truth.
#
#   . project-name.sh
#   resolve_project_name /home/kblack0610/.dotfiles   # -> dotfiles
#
# Resolution order (first match wins):
#   1. App inside a monorepo (see below) via `apps.<repo>`.
#   2. Exact path lookup in project-map.json `paths`.
#   3. The containing repo's canonical name.
#   4. basename (leading dot stripped) looked up in `aliases`.
#   5. basename (leading dot stripped) as-is.
#
# The app step runs BEFORE the exact-path lookup on purpose. A monorepo root is normally
# registered in `paths` (bnb-platform), so checking `paths` first would short-circuit and
# make the main checkout resolve to the repo while a WORKTREE of it -- which has no `paths`
# entry -- resolved to the app. Same branch, two different answers, silently.
#
# APP-IN-MONOREPO (step 2). A repo like bnb-platform holds many independently
# released apps, and each should be its own project for tickets/plans/lessons.
# Two things make that work across the ~35 worktrees of a single repo:
#
#   a. The repo is normalized through `git rev-parse --git-common-dir`, so every
#      worktree (platform-agent-2, platform-baa-gate, ...) collapses to the one
#      canonical repo. Absolute `paths` entries cannot do this — they would need
#      one entry per worktree per app, and would silently rot as worktrees churn.
#   b. Apps are keyed by REPO-RELATIVE path in `apps.<repo>`, so those same
#      relative keys apply in every worktree. Longest prefix wins, which is what
#      makes apps/alpha/api resolve to `alpha` and not `api`.
#
# At the REPO ROOT the cwd carries no app, so the BRANCH decides: a branch named
# `<type>/<app>/<rest>` resolves to <app>, but only if <app> is a registered app
# of that repo — an unregistered second segment (refactor/packages/...) correctly
# falls through to the repo. This matters because most worktrees are checked out
# at the root on a fix/<app>/... branch, and CONTRIBUTING.md mandates that naming.
# Repo-wide work (chore/ci-cache, docs/...) has no app segment and stays the repo.

resolve_project_name() {
  local abs_path="$1"
  local map_file="${PROJECT_MAP_FILE:-$HOME/.config/shared-hooks/project-map.json}"
  local base="${abs_path##*/}"
  base="${base#.}"

  if [ -f "$map_file" ] && command -v jq >/dev/null 2>&1; then
    local hit repo_name=""

    if command -v git >/dev/null 2>&1; then
      local top common repo rel seg app branch cand
      top=$(git -C "$abs_path" rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$top" ]; then
        # Collapse any worktree to the canonical repo checkout.
        common=$(git -C "$abs_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
        repo="${common%/.git}"; repo="${repo%/}"
        [ -n "$repo" ] || repo="$top"

        repo_name=$(jq -r --arg p "$repo" '.paths[$p] // empty' "$map_file" 2>/dev/null || true)
        [ -n "$repo_name" ] || repo_name=$(jq -r --arg b "${repo##*/}" '.aliases[$b] // empty' "$map_file" 2>/dev/null || true)

        if [ -n "$repo_name" ]; then
          # (a) longest repo-relative path prefix -> app
          rel="${abs_path#"$top"}"; rel="${rel#/}"
          seg="$rel"
          while [ -n "$seg" ]; do
            app=$(jq -r --arg r "$repo_name" --arg s "$seg" \
              '.apps[$r][$s] // empty' "$map_file" 2>/dev/null || true)
            if [ -n "$app" ]; then echo "$app"; return 0; fi
            case "$seg" in */*) seg="${seg%/*}" ;; *) seg="" ;; esac
          done

          # (b) ONLY at the worktree root, a <type>/<app>/<rest> branch names the app.
          #     Gated on an empty $rel on purpose: a cwd anywhere inside the tree is
          #     positive evidence about which app is meant, and it must win. Consulting
          #     the branch from apps/beta on a fix/alpha/... branch
          #     would answer "alpha" for a directory that is plainly not it.
          #     Validated against the registered apps, so a non-app second segment
          #     (refactor/packages/...) falls through to the repo.
          branch=""
          [ -z "$rel" ] && branch=$(git -C "$abs_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
          case "$branch" in
            */*/*)
              seg="${branch#*/}"; seg="${seg%%/*}"
              for cand in "$seg" "${seg%-web}" "${seg%-api}" "${seg%-mobile}"; do
                app=$(jq -r --arg r "$repo_name" --arg a "$cand" \
                  '(.apps[$r] // {}) | to_entries | map(select(.value == $a)) | (.[0].value // empty)' \
                  "$map_file" 2>/dev/null || true)
                if [ -n "$app" ]; then echo "$app"; return 0; fi
              done
              ;;
          esac
        fi
      fi
    fi

    # No app matched. An exact path registration wins over the bare repo name, so a
    # sub-directory can still be pinned by absolute path when that is what is wanted.
    hit=$(jq -r --arg p "$abs_path" '.paths[$p] // empty' "$map_file" 2>/dev/null || true)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi

    if [ -n "$repo_name" ]; then echo "$repo_name"; return 0; fi

    hit=$(jq -r --arg b "$base" '.aliases[$b] // empty' "$map_file" 2>/dev/null || true)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  fi

  echo "$base"
}
