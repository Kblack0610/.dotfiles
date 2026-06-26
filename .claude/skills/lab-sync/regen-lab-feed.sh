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
LAB_CURRENT="$HOME/.notes/lab/projects/current"

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

# --- build the AUTO feed block for one project -----------------------------
auto_block() {
  local lab="$1" canon="$2" repo="$3"
  local plan_dir="$HOME/.agent/plans/$canon"
  local eval_dir="$HOME/.agent/evals/$canon"
  local sess_dir="$HOME/.agent/sessions/$canon"
  local anchor="$HOME/.agent/anchors/$canon.md"
  local proj_dir="$LAB_CURRENT/$lab"

  echo "$START"
  echo "## ← Release & status feed"
  echo "_Maintained by lab-sync — mechanical mirror of git + ~/.agent. Do not hand-edit; add notes above._"
  echo

  # canonical + repo
  if [ -n "$repo" ]; then
    echo "- **Repo:** \`$repo\` · canonical \`$canon\`"
  else
    echo "- **Canonical project:** \`$canon\` _(no local repo resolved; set \`<!-- canonical: NAME -->\` in this file to map it)_"
  fi

  # latest release/tag — prefer git, fall back to the lab's own v*.md files
  local tag="" tagdate=""
  if [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1; then
    tag=$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)
    [ -n "$tag" ] && tagdate=$(git -C "$repo" log -1 --format=%cs "$tag" 2>/dev/null || true)
  fi
  local labver
  labver=$(ls -1 "$proj_dir"/v*.md 2>/dev/null | sed 's#.*/##; s/\.md$//' | sort -V | tail -1 || true)
  if [ -n "$tag" ]; then
    echo "- **Latest tag:** \`$tag\`${tagdate:+ ($tagdate)}${labver:+ · lab checklist: \`$labver\`}"
  elif [ -n "$labver" ]; then
    echo "- **Active version (lab):** \`$labver\` _(no git tag resolved)_"
  fi

  # active plans
  if [ -d "$plan_dir" ]; then
    local n newest
    n=$(ls -1 "$plan_dir" 2>/dev/null | grep -vxE 'active|archive|_archive|tasks|backlog|planning|checkpoints' | grep -c '.' || true)
    newest=$(ls -t "$plan_dir"/*.md 2>/dev/null | head -1 | sed 's#.*/##' || true)
    echo "- **Active plans:** ${n:-0} in \`~/.agent/plans/$canon/\`${newest:+ · newest \`$newest\`}"
  fi

  # latest eval (+ overall score if parseable)
  if [ -d "$eval_dir" ]; then
    local latest_eval score
    latest_eval=$(ls -t "$eval_dir"/*.md 2>/dev/null | head -1 || true)
    if [ -n "$latest_eval" ]; then
      score=$(grep -oiE 'Overall:[[:space:]]*[0-9]+(\.[0-9]+)?/10' "$latest_eval" 2>/dev/null | tail -1 || true)
      echo "- **Latest eval:** \`$(basename "$latest_eval")\`${score:+ — ${score}}"
    fi
  fi

  # last session wind-down
  if [ -d "$sess_dir" ]; then
    local lastsess
    lastsess=$(ls -t "$sess_dir"/*.md 2>/dev/null | head -1 | sed 's#.*/##' || true)
    [ -n "$lastsess" ] && echo "- **Last wind-down:** \`$lastsess\`"
  fi

  # recent commits (best-effort)
  if [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1; then
    local commits
    commits=$(git -C "$repo" log --oneline -3 2>/dev/null || true)
    if [ -n "$commits" ]; then
      echo "- **Recent commits:**"
      printf '%s\n' "$commits" | sed 's/^/    - `/; s/$/`/'
    fi
  fi

  # links row
  local links="Links:"
  [ -f "$anchor" ] && links="$links anchor \`~/.agent/anchors/$canon.md\` ·"
  links="$links plans \`~/.agent/plans/$canon/\` · evals \`~/.agent/evals/$canon/\`"
  [ -f "$proj_dir/changelog.md" ] && links="$links · changelog \`changelog.md\`"
  echo
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

  local canon repo
  canon=$(resolve_canonical "$lab" "$summary")
  repo=$(resolve_repo "$canon")

  # scaffold a minimal bus-shaped summary.md if missing
  if [ ! -f "$summary" ]; then
    {
      echo "# $lab"
      echo
      echo "<!-- canonical: $canon -->"
      echo
      echo "## Status"
      echo "- _(what / why / status / active version)_"
      echo
      echo "## → For the agents"
      echo "_Open comments / suggestions / tasks for the agents — read at session start (preflight injects it). \`- [ ]\` = task. lab-sync never edits this section._"
      echo "- _(nothing yet)_"
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
