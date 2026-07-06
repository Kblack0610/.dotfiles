#!/usr/bin/env bash
# regen-lab-feed.sh — regenerate ONLY the <!-- AUTO:START -->…<!-- AUTO:END --> block
# of a lab project's summary.md at ~/.notes/lab/projects/current/{name}/summary.md.
#
# The lab is the human↔agent project BUS (the slow, durable layer between the fast
# ~/.agent runtime and the canonical in-repo CHANGELOG). This script owns the AGENT
# side of each project's summary.md — the "## ← Release & status feed" AUTO block —
# rolled up deterministically from git + ~/.agent. The HUMAN side ("## Status",
# "## → For the agents") is never touched: everything above AUTO:START is preserved
# byte-for-byte, exactly like regen-anchor.sh does for project anchors.
#
#   regen-lab-feed.sh <lab-project>     # e.g. placemyparents, binks
#   regen-lab-feed.sh --all             # every project under projects/current/
#
# Deterministic + idempotent: same inputs → same AUTO block. No network, no LLM,
# zero token cost. Changelog PROSE (what shipped) stays with the LLM-driven release
# skills; this writer only mirrors mechanical state.
set -euo pipefail

HOOKS_DIR="$HOME/.dotfiles/.config/shared-hooks"
MAP_FILE="$HOOKS_DIR/project-map.json"
# Overridable for testing against a scratch copy; defaults to the real lab dir.
LAB_CURRENT="${LAB_CURRENT:-$HOME/.notes/lab/projects/current}"

START='<!-- AUTO:START — maintained by /lab-sync (regen-lab-feed.sh); edits below are overwritten -->'
END='<!-- AUTO:END -->'

# --- resolve canonical project name (lab → canonical) ----------------------
# Order: explicit `<!-- canonical: NAME -->` marker in summary.md (authoritative)
#   → project-map alias whose value we can match → fuzzy (lab name as-is) → "".
resolve_canonical() {
  local lab="$1" summary="$2" canon=""
  if [ -f "$summary" ]; then
    canon=$(grep -oE '<!--[[:space:]]*canonical:[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*-->' "$summary" 2>/dev/null \
      | head -1 | sed -E 's/.*canonical:[[:space:]]*([A-Za-z0-9_.-]+).*/\1/' || true)
  fi
  if [ -z "$canon" ] && command -v jq >/dev/null 2>&1 && [ -f "$MAP_FILE" ]; then
    # alias key == lab name?  (e.g. an alias "placemyparents": "bnb-platform")
    canon=$(jq -r --arg n "$lab" '(.aliases[$n] // empty)' "$MAP_FILE" 2>/dev/null || true)
    # else lab name is itself a canonical (a project-map value)?
    if [ -z "$canon" ]; then
      canon=$(jq -r --arg n "$lab" '.paths | to_entries[] | select(.value==$n) | .value' "$MAP_FILE" 2>/dev/null | head -1 || true)
    fi
  fi
  [ -z "$canon" ] && canon="$lab"   # fuzzy fallback: assume lab name == canonical
  printf '%s' "$canon"
}

# --- resolve local repo path from a canonical name -------------------------
resolve_repo() {
  local canon="$1" repo=""
  if command -v jq >/dev/null 2>&1 && [ -f "$MAP_FILE" ]; then
    repo=$(jq -r --arg n "$canon" '.paths | to_entries[] | select(.value==$n) | .key' "$MAP_FILE" 2>/dev/null | head -1 || true)
  fi
  printf '%s' "$repo"
}

# --- resolve open PRs for a repo (best-effort; empty on any failure) --------
# Prints up to 4 open, non-draft PRs as "#NUM title" lines. Silent + empty when
# gh is missing, unauthenticated, offline, or the repo has no GitHub remote — so
# the feed stays deterministic offline and headless.
open_prs() {
  local repo="$1" filt="$2"
  [ -n "$repo" ] && [ -d "$repo/.git" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  # gh infers owner/repo from the cwd's git remote (its `-R` flag wants owner/repo,
  # not a filesystem path), so run from inside the repo. In a monorepo, an optional
  # title filter keeps one app's cockpit from listing another app's PRs.
  # gh's own --jq can't take `--arg`, so pipe the JSON to standalone jq for the filter.
  command -v jq >/dev/null 2>&1 || return 0
  ( cd "$repo" && gh pr list --state open --limit 20 --json number,title,isDraft 2>/dev/null ) \
    | jq -r --arg f "${filt:-}" '.[] | select(.isDraft | not) | select($f=="" or (.title|test($f))) | "#\(.number) \(.title)"' 2>/dev/null | head -4 || true
}

# --- resolve the current release tag (highest semver, not describe-from-HEAD) ---
# `git describe --abbrev=0` walks HEAD's ancestry, so it misses a newer tag cut on a
# commit HEAD can't reach (e.g. placemyparents-v1.8.15). Pick the highest version tag
# instead, robust across monorepo (product-prefixed) and single-repo layouts:
#   1. `<!-- tagglob: PATTERN -->` in summary.md (override), else
#   2. highest `<lab>-v*` tag (monorepo product prefix), else
#   3. highest `v*` tag (single-product repo), else
#   4. `git describe --tags --abbrev=0` (last resort).
latest_tag() {
  local repo="$1" lab="$2" summary="$3" glob="" t=""
  [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1 || return 0
  if [ -f "$summary" ]; then
    glob=$(grep -oE '<!--[[:space:]]*tagglob:[[:space:]]*[^ ]+[[:space:]]*-->' "$summary" 2>/dev/null \
      | head -1 | sed -E 's/.*tagglob:[[:space:]]*([^ ]+)[[:space:]]*-->/\1/' || true)
  fi
  # An explicit tagglob is authoritative — resolve strictly, never fall through to
  # `describe` (which would return an unrelated product's tag in a monorepo).
  if [ -n "$glob" ]; then
    git -C "$repo" tag --list "$glob" --sort=-v:refname 2>/dev/null | head -1
    return 0
  fi
  [ -z "$t" ] && t=$(git -C "$repo" tag --list "${lab}-v*" --sort=-v:refname 2>/dev/null | head -1)
  [ -z "$t" ] && t=$(git -C "$repo" tag --list "v*" --sort=-v:refname 2>/dev/null | head -1)
  [ -z "$t" ] && t=$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)
  printf '%s' "$t"
}

# --- cockpit sources of truth (all best-effort; degrade to omission) --------
# Per-project config via a `<!-- cockpit: vikunja=3 release-epic=29 pathfilter=apps/x branch=develop -->`
# marker in summary.md. Vikunja rows need a token (VIKUNJA_MCP_TOKEN); when absent (e.g. the
# headless weekly run) the TRACKER inner block is PRESERVED, not stripped (see process_project).
VK_BASE="https://vikunja.kblab.me/api/v1"

cockpit_cfg() { # $1=summary $2=key  → value or ""
  [ -f "$1" ] || return 0
  grep -oE '<!--[[:space:]]*cockpit:[^>]*-->' "$1" 2>/dev/null | head -1 \
    | grep -oE "$2=[^[:space:]]+" | head -1 | sed -E "s/^$2=//" || true
}

vk_tok()   { printf '%s' "${VIKUNJA_MCP_TOKEN:-${VIKUNJA_API_TOKEN:-}}"; }
vk_ready() { [ -n "$(vk_tok)" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }
vk_get()   { vk_ready || return 0; curl -s --max-time 6 -H "Authorization: Bearer $(vk_tok)" "$VK_BASE$1" 2>/dev/null || true; }

# "Merged since the last tag" — the real built-unshipped scope, path-filtered per app.
shipping_next() { # $1=repo $2=tag $3=branch $4=pathfilter
  local repo="$1" tag="$2" branch="$3" pf="$4" ref
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$tag" ] && command -v git >/dev/null 2>&1 || return 0
  ref="origin/$branch"
  git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || ref="$branch"
  git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 0
  # PR-numbered subjects only; skip release/deploy plumbing merges; newest first, cap 6
  git -C "$repo" log "${tag}..${ref}" --pretty='%s' -- ${pf:-.} 2>/dev/null \
    | grep -E '\(#[0-9]+\)' | grep -vE '^Merge |release/|deploy/' | head -6 || true
}

# Highest-version OPEN Vikunja release ticket for this product under the release epic
# → sets NR_VER/NR_ID/NR_CHK/NR_APPROVAL. $2 filters titles to this product (e.g. placemyparents).
next_release() { # $1=release-epic $2=product-prefix
  NR_VER=""; NR_ID=""; NR_CHK=""; NR_APPROVAL=""
  local epic="$1" name="$2" tasks best desc total checked
  [ -n "$epic" ] && vk_ready || return 0
  tasks=$(vk_get "/projects/$epic/tasks")
  [ -n "$tasks" ] || return 0
  # candidate titles: open, and versioned for THIS product; pick the highest version (sort -V)
  best=$(printf '%s' "$tasks" \
    | jq -r --arg n "$name" '.[]? | select(.done==false) | select(.title|test($n+"-v[0-9]")) | .title' 2>/dev/null \
    | sort -V | tail -1)
  [ -n "$best" ] || return 0
  NR_ID=$(printf '%s' "$tasks" | jq -r --arg t "$best" 'first(.[]? | select(.title==$t) | .id) // empty' 2>/dev/null)
  NR_VER=$(printf '%s' "$best" | grep -oE 'v[0-9][0-9.]*' | head -1 || true)
  desc=$(vk_get "/tasks/$NR_ID" | jq -r '.description // ""' 2>/dev/null || true)
  total=$(printf '%s' "$desc" | grep -cE '\- \[[ xX]\]' || true)
  checked=$(printf '%s' "$desc" | grep -cE '\- \[[xX]\]' || true)
  [ "${total:-0}" -gt 0 ] 2>/dev/null && NR_CHK="${checked}/${total}"
  if printf '%s' "$desc" | grep -qiE '\- \[[xX]\][^]]*HUMAN' 2>/dev/null; then NR_APPROVAL="approved"; else NR_APPROVAL="pending"; fi
  return 0
}

# In-Development (label 1), not done, across a project root + its direct children.
in_progress() { # $1=root-project-id  → "- Area: task" lines
  local root="$1" kids pid pname
  [ -n "$root" ] && vk_ready || return 0
  kids=$(vk_get "/projects" | jq -r --arg r "$root" '.[]? | select(.parent_project_id==($r|tonumber)) | "\(.id)\t\(.title)"' 2>/dev/null || true)
  { printf '%s\t%s\n' "$root" ""; printf '%s\n' "$kids"; } | while IFS=$'\t' read -r pid pname; do
    [ -n "$pid" ] || continue
    vk_get "/projects/$pid/tasks" \
      | jq -r --arg n "$pname" '.[]? | select(.done==false) | select((.labels//[])|any(.id==1)) | "- \(if $n=="" then "" else $n+": " end)\(.title)"' 2>/dev/null || true
  done
}

# --- build the AUTO feed block for one project -----------------------------
# A compact, human-first dashboard: what version we're on, what's in flight
# (open PRs), and the last few commits. Agent-runtime detail (plan counts, evals,
# wind-downs) lives in the anchor — the lab feed is the human view. Every live
# row is guarded so the block regenerates identically offline.
# A source-of-truth cockpit: shipped version, what's shipping next (git log since the tag),
# the tracker view (next-release ticket + in-progress tickets), open PRs, recent commits, and
# drill-down links. Deterministic git/gh rows always regenerate; the Vikunja TRACKER inner
# block is preserved when no token is present (headless), never stripped.
auto_block() {
  local lab="$1" canon="$2" repo="$3"
  local anchor="$HOME/.agent/anchors/$canon.md"
  local proj_dir="$LAB_CURRENT/$lab" summary="$LAB_CURRENT/$lab/summary.md"

  # per-project cockpit config (marker overrides; sensible fallbacks)
  local epic root pf branch
  epic=$(cockpit_cfg "$summary" release-epic)
  root=$(cockpit_cfg "$summary" vikunja)
  pf=$(cockpit_cfg "$summary" pathfilter)
  branch=$(cockpit_cfg "$summary" branch)
  [ -n "$branch" ] || branch=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  [ -n "$branch" ] || branch=main

  echo "$START"
  echo "## ← Release & status feed"
  echo "_Source-of-truth mirror: git + GitHub + Vikunja · maintained by lab-sync · do not hand-edit; add notes above._"
  echo

  # shipped version (authoritative git tag), else repo-less fallback to lab vX.Y.Z.md
  local tag tagdate labver
  tag=$(latest_tag "$repo" "$lab" "$summary")
  [ -n "$tag" ] && tagdate=$(git -C "$repo" log -1 --format=%cs "$tag" 2>/dev/null || true)
  labver=$(ls -1 "$proj_dir"/v*.md 2>/dev/null | sed 's#.*/##; s/\.md$//' | sort -V | tail -1 || true)
  if [ -n "$tag" ]; then
    echo "**shipped \`$tag\`**${tagdate:+ ($tagdate)}"
  elif [ -n "$labver" ]; then
    echo "**\`$canon\` · $labver** — _(no git tag resolved)_"
  else
    echo "**\`$canon\`** — _(no version resolved; set \`<!-- canonical: NAME -->\` to map a repo)_"
  fi
  echo

  # shipping next — merged since the tag (deterministic; always regenerated)
  local sn; sn=$(shipping_next "$repo" "$tag" "$branch" "$pf")
  if [ -n "$sn" ]; then
    echo "**Shipping next** — merged to \`$branch\` since \`$tag\`:"
    printf '%s\n' "$sn" | sed 's/^/- /'
    echo
  fi

  # tracker view (Vikunja): regenerate if a token is present, else preserve the existing block
  echo "<!-- TRACKER:START -->"
  NR_ID=""; NR_VER=""; NR_CHK=""; NR_APPROVAL=""
  if vk_ready; then
    next_release "$epic" "$lab"
    if [ -n "$NR_VER" ]; then
      echo "**Next release \`$NR_VER\`**${NR_CHK:+ — verification $NR_CHK checked}${NR_APPROVAL:+ · approval $NR_APPROVAL}${NR_ID:+ · ticket #$NR_ID}"
      echo
    fi
    local ip n; ip=$(in_progress "$root")
    if [ -n "$ip" ]; then
      n=$(printf '%s\n' "$ip" | grep -c . || true)
      echo "**In progress** (Vikunja · In Development):"
      printf '%s\n' "$ip" | head -8
      { [ "${n:-0}" -gt 8 ] && echo "- …(+$((n-8)) more)"; } || true
      echo
    fi
  else
    [ -n "${PRESERVED_TRACKER:-}" ] && printf '%s\n' "$PRESERVED_TRACKER"
  fi
  echo "<!-- TRACKER:END -->"

  # in flight — open PRs (optionally title-filtered for a monorepo app)
  local prs; prs=$(open_prs "$repo" "$(cockpit_cfg "$summary" prfilter)")
  if [ -n "$prs" ]; then
    echo "**In flight** (open PRs)"
    printf '%s\n' "$prs" | sed 's/^/- /'
    echo
  fi

  # recent — last 2 commits
  if [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1; then
    local commits; commits=$(git -C "$repo" log --oneline -2 2>/dev/null || true)
    if [ -n "$commits" ]; then
      echo "**Recent**"
      printf '%s\n' "$commits" | sed 's/^/- `/; s/$/`/'
      echo
    fi
  fi

  # drill-down links
  local links="Drill down:"
  { [ -n "$NR_ID" ] && links="$links release ticket [#$NR_ID](https://vikunja.kblab.me/tasks/$NR_ID) ·"; } || true
  { [ -n "$root" ] && links="$links board [vikunja](https://vikunja.kblab.me/projects/$root) ·"; } || true
  { [ -f "$anchor" ] && links="$links anchor \`~/.agent/anchors/$canon.md\` ·"; } || true
  links="$links plans \`~/.agent/plans/$canon/\`"
  { [ -f "$proj_dir/changelog.md" ] && links="$links · changelog \`changelog.md\`"; } || true
  echo "$links"
  echo "$END"
}

# --- splice the AUTO block into a project's summary.md ----------------------
process_project() {
  local lab="$1"
  local proj_dir="$LAB_CURRENT/$lab"
  local summary="$proj_dir/summary.md"
  if [ ! -d "$proj_dir" ]; then
    echo "skip: no such lab project: $lab ($proj_dir)" >&2; return 1
  fi

  # Preserve the existing Vikunja TRACKER inner block so a headless run (no token) never
  # strips tracker rows that an interactive /lab-sync wrote. auto_block reuses this global
  # when vk_ready is false.
  PRESERVED_TRACKER=""
  if [ -f "$summary" ]; then
    PRESERVED_TRACKER=$(awk '/TRACKER:START/{f=1;next} /TRACKER:END/{f=0} f' "$summary" 2>/dev/null || true)
  fi

  local canon repo repo_over
  canon=$(resolve_canonical "$lab" "$summary")
  repo=$(resolve_repo "$canon")
  # `<!-- cockpit: repo=NAME -->` overrides the git repo (e.g. a lab project whose code
  # lives in a shared monorepo) while keeping its own canonical for readback/anchor.
  repo_over=$(cockpit_cfg "$summary" repo)
  [ -n "$repo_over" ] && repo=$(resolve_repo "$repo_over")

  # scaffold a minimal bus-shaped summary.md if missing
  if [ ! -f "$summary" ]; then
    {
      echo "# $lab"
      echo "<!-- canonical: $canon -->"
      echo "<!-- cockpit: vikunja= release-epic= pathfilter= branch= prfilter= -->"
      echo
      echo "## → For the agents"
      echo "_Type wants / tasks / direction here — read at session start (preflight injects it). Agents scope each into a Vikunja ticket, which then surfaces in the cockpit below. lab-sync never edits this section._"
      echo "- _(nothing yet — type a want)_"
      echo
      echo "<!-- STATUS:START — an agent writes a dated \"where we are\" note here; do not hand-edit -->"
      echo "_(no status yet)_"
      echo "<!-- STATUS:END -->"
      echo
      auto_block "$lab" "$canon" "$repo"
    } > "$summary"
    echo "scaffolded bus summary: $summary (canonical: $canon)"
    return 0
  fi

  # ensure markers exist; if not, append a fresh feed block at the end
  if ! grep -qF 'AUTO:START' "$summary"; then
    { echo; auto_block "$lab" "$canon" "$repo"; } >> "$summary"
    echo "appended feed block: $summary (canonical: $canon)"
    return 0
  fi

  # replace only the AUTO block in place (preserve everything above byte-for-byte)
  local tmp body
  tmp="$(mktemp)"; body="$(mktemp)"
  awk -v startpat='AUTO:START' -v endpat='AUTO:END' '
    index($0, startpat) { print "@@AUTO@@"; skip=1; next }
    index($0, endpat)   { skip=0; next }
    skip { next }
    { print }
  ' "$summary" > "$body"
  {
    while IFS= read -r line; do
      if [ "$line" = "@@AUTO@@" ]; then
        auto_block "$lab" "$canon" "$repo"
      else
        printf '%s\n' "$line"
      fi
    done < "$body"
  } > "$tmp"
  mv "$tmp" "$summary"
  rm -f "$body"
  echo "regenerated feed block: $summary (canonical: $canon)"
}

# --- main ------------------------------------------------------------------
if [ "${1:-}" = "--all" ]; then
  found=0
  for d in "$LAB_CURRENT"/*/; do
    [ -d "$d" ] || continue
    process_project "$(basename "$d")" || true
    found=1
  done
  [ "$found" = 1 ] || echo "no lab projects under $LAB_CURRENT"
elif [ -n "${1:-}" ]; then
  process_project "$1"
else
  echo "usage: regen-lab-feed.sh <lab-project> | --all" >&2
  exit 2
fi
