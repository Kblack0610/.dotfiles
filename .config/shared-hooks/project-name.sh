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
#   4. basename (leading dot stripped) looked up in the name index (project_lookup).
#   5. Under the worktree root with no checkout left: the registered repo its
#      <repo>-<slug> name starts with.
#   6. basename (leading dot stripped): a repo's checkout name, or outside any repo
#      a registered key, else the reserved `_unscoped`.
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

# ── the name index: any spelling of a project -> its key ─────────────────────
#
# A key names itself; then, per tracker sorted by key, each of its `names` and each `/`-suffix of
# its `github` and `forgejo` slugs; then each `paths` checkout's basename. First entry wins, every
# spelling lowercased, a leading dot also stripped. A lookup tries each `/`-suffix of the name,
# longest first. The Rust copy is the `project-map` crate; tests/fixtures/project-names.tsv is
# read by a test of each (rule: docs/operations/release-state.md, "Project identity").
# shellcheck disable=SC2016
_PN_JQ_DEFS='
def _pn_sfx: ascii_downcase | split("/") | map(select(. != "")) as $s
  | range(0; $s | length) as $i | $s[$i:] | join("/") | (., ltrimstr(".")) | select(. != "");
def _pn_pairs:
  . as $m
  | ($m.trackers // {} | to_entries | map(select(.key != "default" and (.value | type) == "object")) | sort_by(.key)) as $t
  | ((($m.paths // {} | .[] | strings), ($t[] | .key)) | [ascii_downcase, ., "key"]),
    ($t[] | .key as $k | .value
      | ((.names // [] | arrays | .[] | strings | ascii_downcase | [., $k, "names"]),
         ((.github, .forgejo) | strings | _pn_sfx | [., $k, "slug"]))),
    ($m.paths // {} | to_entries | sort_by(.key)[] | .value as $k | select($k | type == "string")
      | .key | split("/") | last | ascii_downcase | (., ltrimstr(".")) | select(. != "") | [., $k, "path"]);
def _pn_index: reduce _pn_pairs as $p ({}; if has($p[0]) then . else .[$p[0]] = $p[1] end);
def _pn_lookup($i): first(_pn_sfx | $i[.] // empty) // empty;
def _pn_canon($i): . as $n | (_pn_lookup($i) // ($n | split("/") | map(select(. != "")) | last // "" | ltrimstr(".")));
'

# project_lookup <name> -> the key <name> spells, or "" (status 1) when no entry names it.
project_lookup() {
  local map_file hit; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 1
  hit=$(jq -r --arg n "$1" "$_PN_JQ_DEFS"' _pn_index as $i | $n | _pn_lookup($i)' "$map_file" 2>/dev/null) || true
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# project_canonical <name> -> the key <name> spells, else its last path segment without a leading
# dot (`Kblack0610/.dotfiles` -> `dotfiles`). The one shell answer to "which project is this name".
project_canonical() {
  project_lookup "$1" && return 0
  local n="${1%/}"; n="${n##*/}"; printf '%s\n' "${n#.}"
}

# project_index_json -> the name index as one {"<spelling>": "<key>"} object, for a jq program
# that resolves many names in one pass (`--argjson idx`, then `$idx[<lowercased name>]`).
project_index_json() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || { echo '{}'; return 0; }
  jq -c "$_PN_JQ_DEFS"' _pn_index' "$map_file" 2>/dev/null || echo '{}'
}

# project_spellings -> every index entry as `<spelling>\t<key>\t<source>` (key, names, slug,
# path), including the ones a first entry shadowed: what project-map-doctor checks for a
# spelling that names two keys.
project_spellings() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r "$_PN_JQ_DEFS"' _pn_pairs | @tsv' "$map_file" 2>/dev/null || true
}

# project_of_code <code> -> the project whose row ids carry <code> (`ar` -> agent-runtime), or "".
project_of_code() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg c "$1" 'first(.trackers // {} | to_entries[] | select((.value | objects | .code) == $c) | .key) // empty' \
    "$map_file" 2>/dev/null || true
}

# resolve_project [dir] -> the canonical project for <dir> (default $PWD). The one entry point
# for a script that wants "the project I am in"; four scripts each wrapped resolve_project_name
# with their own copy and their own basename fallback. A hook passes "${CLAUDE_PROJECT_DIR:-$PWD}".
resolve_project() {
  resolve_project_name "${1:-$PWD}"
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

# project_of_repos_json <repo-name>... -> {"<repo>": "<project>"} for forge repo names
# (`.dotfiles`, `Studio/platform`), the question a PR list asks; one jq call over the
# name index, each name project_canonical's answer.
project_of_repos_json() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] || map_file=/dev/null
  printf '%s\n' "$@" | jq -Rn --slurpfile m <(cat "$map_file" 2>/dev/null; echo '{}') "$_PN_JQ_DEFS"'
    ($m[0] // {} | _pn_index) as $i
    | [inputs | select(. != "") | {key: ., value: _pn_canon($i)}] | from_entries'
}

# project_slug <project> -> a short name for a row that has no room: `trackers.<project>.slug`
# when the registry sets one, else the name itself up to 8 characters, else the initials of
# its hyphenated parts (unity-core-playground -> ucp), else its first 8 characters.
project_slug() {
  local own name="$1" part out=""
  own="$(project_field "$name" slug)"
  [ -n "$own" ] && { printf '%s\n' "$own"; return 0; }
  if [ "${#name}" -le 8 ]; then printf '%s\n' "$name"; return 0; fi
  if [[ "$name" == *-* ]]; then
    for part in ${name//-/ }; do out+="${part:0:1}"; done
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "${name:0:8}"
}

# ── the registry's THIRD relation: project -> the version it has SHIPPED ──────
#
# project_field <project> <key> -> one scalar from `trackers.<project>`, or "".
#
# The registry owns each project's wiring (lab, type, path, branch, tagGlob, prFilter);
# a `<!-- cockpit: -->` marker in its summary.md used to. Own entry only, never the
# `repo`'s: a `tagGlob` read from the parent would name the parent's tags.
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
  project_tag_scope "$1" || return 0
  if [ "$_PTS_SCOPED" = 0 ]; then
    git_latest_tag "$_PTS_REPO" "$1" "$_PTS_GLOB"
  else
    git_product_tag "$_PTS_REPO" "$1" "$_PTS_GLOB"
  fi
}

# project_release_lib - load git-release.sh ($GIT_RELEASE_LIB, else the stowed copy) into the
# calling shell; 1 when it is missing. The one loader, for project_tag_scope and for a caller
# that needs the library's pure helpers (git_version_ge, git_tag_date) in its own shell.
project_release_lib() {
  local lib="${GIT_RELEASE_LIB:-$HOME/.local/lib/git-release.sh}"
  [ -f "$lib" ] || return 1
  # shellcheck source=/dev/null
  . "$lib" 2>/dev/null
}

# project_tag_scope <project> -> sets _PTS_REPO, _PTS_SCOPED (0: the project IS its repo, 1: a
# product inside one), _PTS_GLOB (the registry's tagGlob) and _PTS_BUILDS (its `buildTags`
# globs, space-separated), and loads git-release.sh. Returns 1 when the project has no checkout
# or the library is missing. The one place that decides which tag family a project owns, for the
# newest tag and for the list. `buildTags` names per-build tags (`v0.5.0-shapecity3`) that are
# history only: they never own the version, so a game keeps waiting for its own
# `<game>-vX.Y.Z` family (project_version_owner). One owner per tag: a declared tagGlob loses
# every other project's buildTags in the same repo (`v* !v*-shapecity*`, _gr_pats), so the
# playground's `v*` no longer lists a game's build. A ladder glob is never that broad here.
project_tag_scope() {
  local repo not
  _PTS_REPO="$(project_repo_path "$1")"
  [ -n "$_PTS_REPO" ] && [ -d "$_PTS_REPO/.git" ] || return 1
  project_release_lib || return 1
  repo="$(project_repo_name "$1")"
  _PTS_GLOB="$(project_field "$1" tagGlob)"
  { IFS= read -r _PTS_BUILDS; IFS= read -r not; } < <(jq -r --arg n "$1" --arg r "$repo" '
    (.trackers // {}) as $t
    | ($t[$n].buildTags // [] | arrays | join(" ")),
      ([$t | to_entries[] | select(.key != $n and (.value | type) == "object" and (.value.repo // .key) == $r)
        | .value.buildTags // [] | arrays | .[] | "!" + .] | join(" "))' "$(project_map_file)" 2>/dev/null) || true
  [ -n "$_PTS_GLOB" ] && [ -n "$not" ] && _PTS_GLOB="$_PTS_GLOB $not"
  if [ "$repo" = "$1" ]; then _PTS_SCOPED=0; else _PTS_SCOPED=1; fi
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
  project_tag_scope "$1" || return 0   # loads git_tag_version here, not in project_release_tag's subshell
  tag="$(project_release_tag "$1")"
  [ -n "$tag" ] || return 0
  # Both tag shapes (`shipper-v1.11.0`, `v2.3.4`) give `v<version>`; see git_tag_version.
  printf 'v%s' "$(git_tag_version "$tag")"
}

# project_version_owner <project> [shipped] -> what owns its version number (stages.md, "Versions"):
#   tag    a release tag ships it, and the sheet follows the tag (agentctl-wave-roll)
#   build  a game with no tag yet: it waits for its own `<game>-vX.Y.Z` family, never the
#          sheet counter, so a cadence cut cannot mint a number its builds will not carry
#   sheet  nothing ships a build: the sheet's counter, cut on its stage's cadence
# [shipped] is project_release_version's answer when the caller has it, so tags are read once.
project_version_owner() {
  local shipped
  if [ $# -ge 2 ]; then shipped="$2"; else shipped="$(project_release_version "$1")"; fi
  if [ -n "$shipped" ]; then echo tag
  elif [ "$(project_field "$1" type)" = game ]; then echo build
  else echo sheet; fi
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

# project_board <repo or project> -> the notes board its rows go on, or "" when it has none: its
# `owner` (a repo whose work counts on a project in its checkout: dotfiles -> agent-runtime), else
# its `board` (a repo with no sheet that files on another's: dotfiles-private -> agent-runtime), else
# itself when it has a `lab`, else the first lab project inside it (a monorepo -> its first app with a sheet).
project_board() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg n "$1" '
    (.trackers // {}) as $t
    | (if ($t[$n] | type) == "object" then $t[$n] else {} end) as $own
    | if ($own.owner // "") != "" then $own.owner
      elif ($own.board // "") != "" then $own.board
      elif ($own.lab // "") != "" then $n
      else [$t | to_entries[] | select(.value | type == "object")
            | select(.value.repo == $n and (.value.lab // "") != "") | .key][0] // empty end
  ' "$map_file" 2>/dev/null || true
}

# project_inherited <repo or project> <field> -> its own value, else the one value shared by
# every project under it, else "". `.dotfiles` has no type of its own, but both its projects
# are infra.
project_inherited() {
  local own name vals
  own="$(project_field "$1" "$2")"
  [ -n "$own" ] && { printf '%s\n' "$own"; return 0; }
  vals="$(project_lab_names "$1" | while IFS= read -r name; do project_field "$name" "$2"; done | sort -u)"
  [ -n "$vals" ] && [ "$(wc -l <<<"$vals")" -eq 1 ] && printf '%s\n' "$vals"
  return 0
}

# project_keys -> every registered project key, sorted, one per line: the `paths` names
# plus the object-valued tracker keys. `default` is the tracker fallback, not a project,
# and a string-valued `_comment*` key is documentation. The one definition of "the
# projects": project-map-doctor checks against it and `regen-anchor.sh --all` walks it.
project_keys() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    [(.paths // {}) | .[]]
    + [(.trackers // {}) | to_entries[] | select(.value | type == "object") | .key
       | select(. != "default")]
    | unique[]' "$map_file" 2>/dev/null || true
}

# project_anchor_keys -> the keys that get an anchor at ~/.agent/anchors/<key>.md: every
# project key except one with a `repo` and no `path`. No directory resolves to such a key
# (notes-cockpit, agent-runtime: lab projects about a repo's tooling), so no preflight would
# read its anchor; its lab line is in the repo's anchor instead.
project_anchor_keys() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 0
  project_keys | jq -rR --slurpfile m "$map_file" '
    . as $k | ($m[0].trackers[$k] // {}) as $t
    | select(($t | type) != "object" or ($t.repo // "") == "" or ($t.path // "") != "")'
}

# project_known <name> -> 0 when <name> is itself a project key (a `paths` value or an object
# tracker other than `default`), 1 when it is not (another spelling of one, such as monorepo or
# waybar, or an unknown name), 2 when there is no registry.
project_known() {
  local map_file; map_file="$(project_map_file)"
  [ -f "$map_file" ] && command -v jq >/dev/null 2>&1 || return 2
  jq -e --arg n "$1" "$_PN_JQ_DEFS"' _pn_index[$n | ascii_downcase] == $n' "$map_file" >/dev/null 2>&1
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
        [ -n "$repo_name" ] || repo_name=$(project_lookup "${repo##*/}" || true)

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

    hit=$(project_lookup "$base" || true)
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

    # Outside any repo, a basename is a project only when the registry knows it. $HOME,
    # /tmp, a session scratchpad or ~/.cache are no project, and naming them by basename
    # minted ~/.agent keys (kblack0610, scratchpad, tmp) that the dream swept nightly.
    # They share the one reserved key; a leading `_` marks a key that is no project.
    # A repo under the temp dir is outside any project too: a lane that `git init`s a
    # `mktemp -d` and runs codex there minted tmp.XXXXXXXXXX outcome keys.
    local tmp_root="${TMPDIR:-/tmp}" in_tmp=0 where="$abs_path"
    [ -n "${top:-}" ] && where="${repo:-$abs_path}"
    case "$where" in "${tmp_root%/}"/?*) in_tmp=1 ;; esac
    if { [ -z "${top:-}" ] || [ "$in_tmp" = 1 ]; } && ! project_known "$base"; then echo "_unscoped"; return 0; fi
  fi

  echo "$base"
}
