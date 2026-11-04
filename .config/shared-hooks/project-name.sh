#!/bin/bash
# Resolve a canonical project name from an absolute path.
# Sourced by session-preflight.sh, stop hooks, etc. Single source of truth.
#
#   . project-name.sh
#   resolve_project_name /home/kblack0610/.dotfiles   # -> dotfiles
#
# Resolution order (first match wins):
#   1. App inside a repo (see below): a `trackers` entry with `repo` + `path`.
#   2. Exact path lookup in project-map.json `paths`.
#   3. The containing repo's canonical name.
#   4. basename (leading dot stripped) looked up in `aliases`.
#   5. Under the worktree root with no checkout left: the registered repo its
#      <repo>-<slug> name starts with.
#   6. basename (leading dot stripped) as-is.
#
# The app step runs BEFORE the exact-path lookup on purpose. A monorepo root is normally
# registered in `paths` (bnb-platform), so checking `paths` first would short-circuit and
# make the main checkout resolve to the repo while a WORKTREE of it -- which has no `paths`
# entry -- resolved to the app. Same branch, two different answers, silently.
#
# APP-IN-REPO (step 1). A repo like bnb-platform holds many independently
# released apps (and unity-core-playground many games), and each should be its own
# project for tickets/plans/lessons. A project declares where it lives once, in its
# `trackers` entry: `repo` (the repo's registry key) and `path` (repo-relative).
# Two things make that work across the ~35 worktrees of a single repo:
#
#   a. The repo is normalized through `git rev-parse --git-common-dir`, so every
#      worktree (platform-agent-2, platform-baa-gate, ...) collapses to the one
#      canonical repo. Absolute `paths` entries cannot do this — they would need
#      one entry per worktree per app, and would silently rot as worktrees churn.
#   b. `path` is REPO-RELATIVE, so the same entry applies in every worktree.
#      Longest prefix wins, which is what makes apps/alpha/api resolve to `alpha`
#      and not `api`.
#
# At the REPO ROOT the cwd carries no app, so the BRANCH decides: a branch named
# `<type>/<app>/<rest>` resolves to <app>, but only if <app> is a tracker key with
# that `repo` and a `path`: an unregistered second segment (refactor/packages/...) correctly
# falls through to the repo. This matters because most worktrees are checked out
# at the root on a fix/<app>/... branch, and CONTRIBUTING.md mandates that naming.
# Repo-wide work (chore/ci-cache, docs/...) has no app segment and stays the repo.

# project_map_file -> the ONE path to the registry.
#
# Five files each defined this for themselves and one of them was WRONG:
# regen-project-index.sh looked in `~/.dotfiles/.config/shared-hooks/`, where the file
# has never existed (it is private, and reaches ~/.config/shared-hooks/ by stow). Every
# lookup there returned empty, silently, so the lab index lost every git-derived row and
# said so in no way at all.
#
# The STOWED path, not either repo's, because the file is private and the public tree
# must not name a private path. PROJECT_MAP_FILE still overrides, which is what the
# private shell profile sets and what the tests use.
project_map_file() {
  printf '%s' "${PROJECT_MAP_FILE:-$HOME/.config/shared-hooks/project-map.json}"
}

# ── the registry's OTHER relation: project -> repo ────────────────────────────
#
# resolve_project_name answers "what project is this PATH", which is the question
# the hooks ask. The three functions below answer the inverse, which is the
# question every lab/notes surface asks: given a project NAME, what repo is it,
# and which projects belong to a given repo?
#
# `trackers.<project>.repo` is that relation and it is already correct in the
# registry (notes-cockpit -> dotfiles, time-tangle -> bnb-platform). It had four
# hand-rolled copies, one of which had lost the hop entirely — which is why the
# lab index rendered no git tag at all for notes-cockpit and time-tangle.
#
# THE JQ TRAP, and the reason these live here rather than being inlined again:
# `.trackers` contains a documentation key whose value is a STRING
# (`_comment_lab_projects`). A bare `.trackers | to_entries[] | .value.repo` dies
# with `Cannot index string with string`, and in a caller running under `set -e`
# — the session preflight is one — that takes the whole turn-1 context with it,
# printing nothing. Every iterating jq below therefore carries
# `select(.value | type == "object")`. Do not inline one of these without it.

# project_repo_name <project> -> the repo NAME that owns it, or the project name
# itself when it is its own repo.
project_repo_name() {
  local proj="$1" map_file rn=""
  map_file="$(project_map_file)"
  if [ -f "$map_file" ] && command -v jq >/dev/null 2>&1; then
    # `select(type == "object")` guards the string-valued comment key, in case a
    # caller passes its name.
    rn=$(jq -r --arg n "$proj" \
      '(.trackers[$n] // empty) | select(type == "object") | (.repo // empty)' \
      "$map_file" 2>/dev/null || true)
  fi
  printf '%s' "${rn:-$proj}"
}

# project_repo_path <project> -> the repo's CHECKOUT PATH, or "".
#
# Two hops, because a project need not be a repo: an app in a monorepo, or a
# product whose sessions register under the repo they ran in. First
# project -> repo name, then the `paths` reverse lookup to a checkout.
project_repo_path() {
  local proj="$1" map_file repo_name repo=""
  map_file="$(project_map_file)"
  repo_name="$(project_repo_name "$proj")"
  if [ -f "$map_file" ] && command -v jq >/dev/null 2>&1; then
    repo=$(jq -r --arg n "$repo_name" \
      '.paths | to_entries[] | select(.value == $n) | .key' \
      "$map_file" 2>/dev/null | head -1 || true)
  fi
  printf '%s' "$repo"
}

# ── the registry's THIRD relation: project -> the version it has SHIPPED ──────
#
# project_field <project> <key> -> one scalar from `trackers.<project>`, or "".
#
# The registry owns each project's wiring (lab, type, path, branch, root, releaseEpic,
# tagGlob, prFilter); a `<!-- cockpit: -->` marker in its summary.md used to. Own entry
# only: `inherits` merges tracker config (labels, epics), and a field like `tagGlob`
# copied from a parent would name the parent's tags.
project_field() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg n "$1" --arg k "$2" '
    (.trackers[$n] // {}) | select(type == "object") | .[$k] // empty
    | select(type != "object" and type != "array")' "$map_file" 2>/dev/null || true
}

# project_release_tag <project> -> the newest shipped TAG (`time-tangle-web-v1.0.1`), or "".
#
# The one place that decides which tags belong to a project. A project that IS its repo
# takes git_latest_tag's full ladder, where a bare `v*` cannot collide with a sibling. An
# app inside a monorepo takes product-scoped globs only: git_latest_tag would fall
# through to bare `v*` and hand back a SIBLING's tag - measured: `time-tangle` resolved
# to a different app's mobile tag entirely. The registry's `tagGlob` overrides both, for
# a product whose tag prefix is not its name (the portfolio ships `portfolio-v*`).
project_release_tag() {
  local proj="$1" repo lib glob
  repo="$(project_repo_path "$proj")"
  [ -n "$repo" ] && [ -d "$repo/.git" ] || return 0

  lib="${GIT_RELEASE_LIB:-$HOME/.local/lib/git-release.sh}"
  [ -f "$lib" ] || return 0
  # shellcheck source=/dev/null
  . "$lib" 2>/dev/null || return 0

  glob="$(project_field "$proj" tagGlob)"
  if [ "$(project_repo_name "$proj")" = "$proj" ]; then
    git_latest_tag "$repo" "$proj" "$glob"
  else
    git_product_tag "$repo" "$proj" "$glob"
  fi
}

# project_release_version <project> -> `v1.11.0`, or "" if it ships nothing.
#
# THE EMPTY STRING IS THE INTERESTING ANSWER. It is the one discriminator the wave
# needs, and it needs no new config key to express:
#
#   non-empty -> a SHIPPING APP. The app owns the version. The notes sheet must
#                track the next RELEASE and never mint a number of its own.
#   empty     -> a NOTES-ONLY project (agent-runtime, notes-cockpit, gsuite-comms:
#                no repo artifact, no tags). The sheet counter is the only counter
#                there is, and it is already correct. Nothing changes for these.
#
# Why this function exists at all: the notes CLI has ZERO knowledge of app versions
# - no package.json read, no tag read - so its `vX.Y.Z` counter and the app's real
# release tags were two counters in one namespace with no link in either direction.
# A wave rolled `v1.11.1` and `v1.11.2` into the notes while the app's newest tag was
# still `v1.11.0`; nothing errored, and the wave had named itself after two versions
# that will never ship. This is the read side of that link.
#
# Prints the bare VERSION, not the tag: callers want `v1.11.0`, not `<app>-v1.11.0`.
project_release_version() {
  local tag
  tag="$(project_release_tag "$1")"
  [ -n "$tag" ] || return 0
  # Tag -> bare version, for BOTH tag shapes. `##*-v` strips a product prefix
  # (`shipper-v1.11.0` -> `1.11.0`) but leaves an unprefixed tag untouched
  # (`v2.3.4` -> `v2.3.4`), so the `#v` normalises that second case instead of
  # emitting `vv2.3.4`. Caught by the single-product-repo test, not by reading it.
  local ver="${tag##*-v}"
  printf 'v%s' "${ver#v}"
}

# project_lab_names <repo> -> every project belonging to that repo, one per line.
#
# The INVERSE of project_repo_name, and the join the session preflight needs: a
# session in ~/.dotfiles resolves to `dotfiles`, but the human's project boards
# for it are filed under `agent-runtime` and `notes-cockpit`. Joining those two
# namespaces by directory name — which is what the preflight did — produces an
# empty intersection for every session anyone actually opens.
#
# A repo that is itself a registered project is included, so a caller gets one
# complete list rather than a list plus a special case.
project_lab_names() {
  local repo="$1" map_file
  map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || { printf '%s\n' "$repo"; return 0; }
  jq -r --arg n "$repo" '
    .trackers // {}
    | to_entries[]
    | select(.value | type == "object")
    | select(.value.repo == $n or .key == $n)
    | .key
  ' "$map_file" 2>/dev/null || true
}

# project_known <name> -> 0 when <name> is a canonical project in the registry (a repo's
# project, a tracker, or what an alias resolves to), 1 when it is not (an alias
# itself, such as monorepo or waybar, or an unknown name), 2 when there is no registry.
project_known() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 2
  jq -e --arg n "$1" '
    [(.paths // {} | .[]),
     (.trackers // {} | to_entries[] | select(.value | type == "object") | .key),
     (.aliases // {} | .[])] | index($n) != null' "$map_file" >/dev/null 2>&1
}

resolve_project_name() {
  local abs_path="$1"
  local map_file; map_file="$(project_map_file)"
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
        # An unregistered repo is named by its checkout, never by a worktree or subdir.
        base="${repo##*/}"; base="${base#.}"

        repo_name=$(jq -r --arg p "$repo" '.paths[$p] // empty' "$map_file" 2>/dev/null || true)
        [ -n "$repo_name" ] || repo_name=$(jq -r --arg b "${repo##*/}" '.aliases[$b] // empty' "$map_file" 2>/dev/null || true)

        if [ -n "$repo_name" ]; then
          # (a) longest repo-relative path prefix -> app
          rel="${abs_path#"$top"}"; rel="${rel#/}"
          seg="$rel"
          while [ -n "$seg" ]; do
            app=$(jq -r --arg r "$repo_name" --arg s "$seg" \
              '[.trackers // {} | to_entries[] | select(.value | type == "object")
                | select(.value.repo == $r and .value.path == $s) | .key][0] // empty' \
              "$map_file" 2>/dev/null || true)
            if [ -n "$app" ]; then echo "$app"; return 0; fi
            case "$seg" in */*) seg="${seg%/*}" ;; *) seg="" ;; esac
          done

          # (b) ONLY at the worktree root, a <type>/<app>/<rest> branch names the app.
          #     Gated on an empty $rel on purpose: a cwd anywhere inside the tree is
          #     positive evidence about which app is meant, and it must win. Consulting
          #     the branch from apps/beta on a fix/alpha/... branch
          #     would answer "alpha" for a directory that is plainly not it.
          #     Validated against the repo's tracker entries that carry a `path`, so a
          #     non-app second segment
          #     (refactor/packages/...) falls through to the repo.
          branch=""
          [ -z "$rel" ] && branch=$(git -C "$abs_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
          case "$branch" in
            */*/*)
              seg="${branch#*/}"; seg="${seg%%/*}"
              for cand in "$seg" "${seg%-web}" "${seg%-api}" "${seg%-mobile}"; do
                app=$(jq -r --arg r "$repo_name" --arg a "$cand" \
                  '.trackers[$a] | objects | select(.repo == $r and (.path // "") != "") | $a' \
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

    # A path under the worktree root that is no checkout (reaped while its session ran,
    # or a husk an Editor wrote Logs/ into afterwards) names its repo only by the
    # <repo>-<slug> convention `wt` keeps. The longest registered checkout basename that
    # prefixes it wins, so unity-core-playground-agent-12 is unity-core-playground. Without
    # this each such session filed plans and lessons under its own worktree name.
    local wt_root="${WT_ROOT:-$HOME/.worktrees}" wt_name
    if [ -z "${top:-}" ]; then
      case "$abs_path" in
        "$wt_root"/?*)
          wt_name="${abs_path#"$wt_root"/}"; wt_name="${wt_name%%/*}"
          hit=$(jq -r --arg w "$wt_name" '
            [.paths // {} | to_entries[]
             | (.key | split("/") | last | ltrimstr(".")) as $b
             | select($b != "" and ($w == $b or ($w | startswith($b + "-"))))
             | {l: ($b | length), v: .value}]
            | max_by(.l) | .v // empty' "$map_file" 2>/dev/null || true)
          if [ -n "$hit" ]; then echo "$hit"; return 0; fi
          ;;
      esac
    fi
  fi

  echo "$base"
}
