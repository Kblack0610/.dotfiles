#!/usr/bin/env bash
# worktree.sh - the worktree panel. On PATH as `wt`.
#
# Usage: worktree.sh [verb]
#
# Verbs:
#   (no verb)         pick a worktree. Enter lands in its session, ctrl-n cuts a new one,
#                     ctrl-x reaps the row under the cursor, ctrl-r reloads.  [Prefix+F]
#   new [-c <dir>]    cut a fresh worktree off the repo containing <dir> (default $PWD),
#                     open a tmux session rooted in it, and land there.       [Prefix+C-f]
#   reap [<path>]     remove one worktree, but ONLY when it is clean, landed (merged or
#                     pushed) and has no live tmux session. Refuses with the reason
#                     otherwise. There is no --force.
#   gc [<repo>] [-n]  reap every eligible worktree and NAME the ones it kept. With no repo,
#                     everything under $WT_ROOT; with one, that repo's linked worktrees.
#   --list            the rows, TSV. The data behind the picker, split out so it is
#                     assertable without a terminal.
#   preview <path>    the picker's preview pane for one worktree.
#   --help, -h        this text
#
# THE WORKTREE IS THE AGENT. `agent-N` is not a persistent workspace slot; it is the Nth
# worktree alive in this system right now - allocated by `new`, freed by `reap`, and the
# number is reused once it is free. That is why nothing here has to teach the other surfaces
# a new concept: `agent-panel` (Prefix+g) already parses a session named `<repo>-agent-N`
# into project + agent number, and it enumerates live tmux panes, which ARE the live
# worktrees.
#
# So the layout is FLAT and the basename carries the identity:
#
#   ~/.worktrees/<repo>-agent-N        directory basename
#              == <repo>-agent-N       tmux session name  (sessionizer.sh:session_name)
#              -> project <repo>       agent-panel render.rs:project_from_path
#              -> label   N:<window>   agent-panel render.rs:short_target
#
# Nesting these under ~/.worktrees/<repo>/ would make the basename `agent-N`, which loses
# the repo and breaks all three at once.
#
# CAVEAT, dotfiles only: stow symlinks point at ~/.dotfiles (~/.local/src/tmux ->
# ../../.dotfiles/.local/src/tmux), so edits made in a dotfiles worktree are NOT deployed.
# You are exercising the repo copy, not the live one. Run scripts by their path inside the
# worktree; do not expect `wt` on PATH to be the one you just edited.

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

WT_ROOT="${WT_ROOT:-$HOME/.worktrees}"
# The command a new session's first window runs. Empty = a plain shell, which is the honest
# default: `new` is a worktree primitive, and what you run in it is your business.
WT_NEW_CMD="${WT_NEW_CMD:-}"
# Repo discovery for --list, so the picker sees worktrees of repos that have none under
# $WT_ROOT yet (platform's siblings, for one). Same file the hooks resolve projects through.
WT_PROJECT_MAP="${WT_PROJECT_MAP:-$HOME/.config/shared-hooks/project-map.json}"

# ── Repo plumbing ────────────────────────────────────────────────────────────

# wt_main_repo <dir> -- the MAIN checkout of the repo containing <dir>.
#
# Via --git-common-dir, so it gives the same answer from inside a linked worktree as from
# the main one. That matters: `wt new` run inside `dotfiles-agent-1` must cut
# `dotfiles-agent-2`, not `dotfiles-agent-1-agent-1`.
wt_main_repo() {
  local common
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
  */.git) printf '%s\n' "${common%/.git}" ;;
  *) return 1 ;; # bare repo: no working tree to name a worktree after
  esac
}

# wt_repo_name <main-repo> -- the name a worktree of this repo carries.
#
# Leading dot stripped (`.dotfiles` -> `dotfiles`) and dots folded to underscores. The fold
# is sessionizer.sh:38's rule and is not cosmetic: tmux reads `.` as the window separator
# inside a target, so `-t my.project` addresses window "project" of session "my".
wt_repo_name() {
  local base
  base="$(basename "$1")"
  base="${base#.}"
  printf '%s\n' "$base" | tr . _
}

# wt_default_branch <main-repo> -- what this repo calls its trunk.
wt_default_branch() {
  local ref
  if ref=$(git -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s\n' "${ref##*/}"
    return 0
  fi
  for ref in main master develop; do
    if git -C "$1" show-ref --verify --quiet "refs/heads/$ref" 2>/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# wt_base_ref <main-repo> <branch> -- prefer origin/<branch>; fall back to the local branch
# so this still works offline, or in a fixture repo with no remote.
wt_base_ref() {
  if git -C "$1" rev-parse --verify --quiet "origin/$2" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$2"
  elif git -C "$1" rev-parse --verify --quiet "$2" >/dev/null 2>&1; then
    printf '%s\n' "$2"
  else
    return 1
  fi
}

# wt_is_linked <path> -- true only for a LINKED worktree. In the main checkout --git-dir and
# --git-common-dir are the same path; in a linked one --git-dir is <common>/worktrees/<name>.
# This is the guard that stops `reap` ever pointing at a main checkout.
wt_is_linked() {
  local gd common
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$gd" != "$common" ]
}

wt_branch_of() { git -C "$1" branch --show-current 2>/dev/null; }

wt_dirty_count() { git -C "$1" status --porcelain 2>/dev/null | grep -c ''; }

# wt_landed <path> <base-ref> -- has this worktree's work gone somewhere durable?
#
# Two ways to qualify, and either is enough: HEAD is already an ancestor of the trunk
# (merged), or every commit is on its upstream (pushed, PR open, review pending). A branch
# that is only ever pushed would never be reapable under the first test alone, and waiting
# for the merge to land locally would keep worktrees alive for days after they are done.
wt_landed() {
  git -C "$1" merge-base --is-ancestor HEAD "$2" 2>/dev/null && return 0
  git -C "$1" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1 &&
    [ -z "$(git -C "$1" rev-list '@{upstream}..HEAD' 2>/dev/null)" ]
}

# ── tmux state ───────────────────────────────────────────────────────────────

wt_live_sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null; }

wt_session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

# ── Eligibility ──────────────────────────────────────────────────────────────

# wt_reap_reason <path> -- print why <path> may NOT be reaped; print nothing and return 0
# when it may. The ONE place the policy lives, so the picker's glyph, `reap` and `gc` can
# never disagree about what is safe.
wt_reap_reason() {
  local path="$1" main def base dirty up

  [ -d "$path" ] || {
    printf 'no such directory\n'
    return 1
  }
  wt_is_linked "$path" || {
    printf 'a main checkout, not a worktree\n'
    return 1
  }

  dirty=$(wt_dirty_count "$path")
  [ "$dirty" -eq 0 ] || {
    printf 'dirty (%s uncommitted)\n' "$dirty"
    return 1
  }

  main=$(wt_main_repo "$path") || {
    printf 'cannot resolve its repo\n'
    return 1
  }
  def=$(wt_default_branch "$main") || {
    printf 'cannot resolve the default branch\n'
    return 1
  }
  base=$(wt_base_ref "$main" "$def") || {
    printf 'no %s to compare against\n' "$def"
    return 1
  }

  if ! wt_landed "$path" "$base"; then
    if up=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) && [ -n "$up" ]; then
      printf 'unpushed commits (ahead of %s)\n' "$up"
    else
      printf 'not merged into %s, and no upstream to push to\n' "$base"
    fi
    return 1
  fi

  # A LIVE SESSION IS NEVER REAPED, attached or not. "Clean and pushed" is a snapshot, not a
  # promise: an agent working detached in this worktree is clean-and-pushed for a moment after
  # every push, and a `gc` that happened to run in that window would delete the tree out from
  # under it mid-turn. Being unattached says nothing about whether anything is running there.
  # This is why wind-down reaps only AFTER it has killed the window -- by then there is no
  # session, and the check passes honestly.
  if wt_session_exists "$(basename "$path")"; then
    printf 'its tmux session is live\n'
    return 1
  fi

  return 0
}

# ── Rows ─────────────────────────────────────────────────────────────────────

# wt_scan_repos -- every main repo worth listing worktrees for, one absolute path per line.
wt_scan_repos() {
  {
    local d p
    for d in "$WT_ROOT"/*; do
      [ -d "$d" ] || continue
      wt_main_repo "$d"
    done
    if panel_have jq && [ -f "$WT_PROJECT_MAP" ]; then
      while IFS= read -r p; do
        [ -d "$p" ] && wt_main_repo "$p"
      done < <(jq -r '.paths | keys[]' "$WT_PROJECT_MAP" 2>/dev/null)
    fi
  } 2>/dev/null | sort -u
}

# wt_worktrees_of <main-repo> -- `path<TAB>branch` for every LINKED worktree, main excluded.
wt_worktrees_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null |
    awk -v main="$1" '
      /^worktree /  { path = substr($0, 10); branch = "" ; next }
      /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
      /^detached$/  { branch = "(detached)" }
      /^$/          { if (path != "" && path != main) print path "\t" branch; path = "" }
      END           { if (path != "" && path != main) print path "\t" branch }
    '
}

# One row: path, name, branch, state, then the human label LAST so --with-nth can hide the
# rest. State is a single machine-readable word, which is what the tests assert on.
wt_row() {
  local path="$1" branch="$2" base="$3" sessions="$4"
  local name dirty state glyph note

  name="$(basename "$path")"
  dirty=$(wt_dirty_count "$path")

  if [ "$dirty" -gt 0 ]; then
    state=dirty
    glyph="$G_ATTN"
    note="$dirty uncommitted"
  elif ! wt_landed "$path" "$base"; then
    state=unlanded
    glyph="$G_IDLE"
    note="not landed"
  else
    state=reapable
    glyph="$G_OK"
    note="reapable"
  fi

  # A live session is the loudest fact about a worktree you are choosing between, so it wins
  # the glyph -- but not the state, which is about whether the work is safe to throw away.
  if printf '%s\n' "$sessions" | grep -qxF "$name"; then
    glyph="$G_BUSY"
    note="$note, session live"
  fi

  printf '%s\t%s\t%s\t%s\t%s %-28s %s%s%s  %s%s%s\n' \
    "$path" "$name" "$branch" "$state" \
    "$(panel_paint "$glyph")" "$name" \
    "$C_BOX" "$branch" "$C_OFF" \
    "$C_DIM" "$note" "$C_OFF"
}

cmd_list() {
  local sessions main repo def base line path branch
  sessions="$(wt_live_sessions)"

  while IFS= read -r main; do
    [ -n "$main" ] || continue
    def=$(wt_default_branch "$main") || continue
    base=$(wt_base_ref "$main" "$def") || continue
    while IFS= read -r line; do
      path="${line%%$PANEL_TAB*}"
      branch="${line#*$PANEL_TAB}"
      [ -n "$path" ] && wt_row "$path" "$branch" "$base" "$sessions"
    done < <(wt_worktrees_of "$main")
  done < <(wt_scan_repos)
}

cmd_preview() {
  local path="${1:-}" reason
  [ -n "$path" ] || return 0
  panel_head "$(basename "$path")"
  printf '%s%s%s\n\n' "$C_DIM" "$path" "$C_OFF"

  if [ ! -d "$path" ]; then
    panel_hint 'directory is gone'
    return 0
  fi

  printf '%sbranch%s  %s\n' "$C_DIM" "$C_OFF" "$(wt_branch_of "$path")"
  if reason=$(wt_reap_reason "$path"); then
    printf '%sreap%s    %s%s%s\n' "$C_DIM" "$C_OFF" "$C_SEL" 'eligible' "$C_OFF"
  else
    printf '%sreap%s    %sheld: %s%s\n' "$C_DIM" "$C_OFF" "$C_INP" "$reason" "$C_OFF"
  fi

  printf '\n'
  panel_head 'status'
  git -C "$path" status --short 2>/dev/null | head -20
  printf '\n'
  panel_head 'commits'
  git -C "$path" log --oneline -8 2>/dev/null
}

# ── Verbs ────────────────────────────────────────────────────────────────────

# wt_next_n <repo-name> <main-repo> -- the lowest N with BOTH the directory and the branch
# free.
#
# Both, not just the directory: a refused reap leaves `agent-N` behind, and
# `worktree add -b agent-N` on an existing branch fails outright. Gaps are filled (1, 2, 4
# alive -> 3) so the numbers stay small enough to say out loud, which is the whole point of
# agent-panel labelling a row `3:1`.
wt_next_n() {
  local repo="$1" main="$2" n=1
  while [ "$n" -le 99 ]; do
    if [ ! -e "$WT_ROOT/$repo-agent-$n" ] &&
      ! git -C "$main" show-ref --verify --quiet "refs/heads/agent-$n" 2>/dev/null; then
      printf '%s\n' "$n"
      return 0
    fi
    n=$((n + 1))
  done
  panel_fail "no free slot: $WT_ROOT/$repo-agent-{1..99} are all taken" || return 1
}

# wt_ensure_session <name> <dir> -- panel_ensure_session, plus the one thing it cannot do.
wt_ensure_session() {
  local name="$1" dir="$2"
  [ -n "$WT_NEW_CMD" ] || {
    panel_ensure_session "$name" "$dir"
    return
  }
  tmux has-session -t "=$name" 2>/dev/null && return 0
  tmux new-session -ds "$name" -c "$dir" "$WT_NEW_CMD"
}

cmd_new() {
  local dir="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
    -c | --cwd)
      dir="${2:-}"
      shift 2 || panel_die "-c needs a directory"
      ;;
    *) panel_die "new: unknown arg: $1" ;;
    esac
  done
  [ -d "$dir" ] || panel_die "not a directory: $dir"

  local main repo def base n path branch name
  main=$(wt_main_repo "$dir") || panel_die "not inside a git repository: $dir"
  repo=$(wt_repo_name "$main")

  # Best-effort: an offline machine still gets a worktree, just off the last-known trunk.
  git -C "$main" fetch origin --quiet 2>/dev/null || panel_warn "fetch failed; cutting off the local trunk"

  def=$(wt_default_branch "$main") || panel_die "cannot resolve the default branch of $main"
  base=$(wt_base_ref "$main" "$def") || panel_die "no $def in $main to branch from"
  n=$(wt_next_n "$repo" "$main") || return 1

  path="$WT_ROOT/$repo-agent-$n"
  branch="agent-$n"
  name="$repo-agent-$n"

  mkdir -p "$WT_ROOT" || panel_die "cannot create $WT_ROOT"
  git -C "$main" worktree add "$path" -b "$branch" "$base" >&2 ||
    panel_die "git worktree add failed: $path"

  wt_ensure_session "$name" "$path" || panel_die "could not create session $name"
  printf '%s\n' "$name"
  panel_focus_session "$name"
}

# wt_land <path> -- ensure the session for an EXISTING worktree, then go there.
wt_land() {
  local path="$1" name
  [ -d "$path" ] || panel_die "no such worktree: $path"
  name="$(basename "$path")"
  wt_ensure_session "$name" "$path" || panel_die "could not create session $name"
  panel_focus_session "$name"
}

cmd_reap() {
  local path="${1:-$PWD}" reason main name
  path="$(realpath "$path" 2>/dev/null)" || panel_die "no such path: ${1:-$PWD}"

  if reason=$(wt_reap_reason "$path"); then
    :
  else
    panel_fail "kept $(basename "$path"): $reason" || return 1
  fi

  main=$(wt_main_repo "$path") || panel_die "cannot resolve the repo for $path"
  name="$(basename "$path")"

  # From the MAIN repo, never from inside the directory being removed. git's own dirty check
  # runs again here, which is a second lock on the same door -- deliberately, because
  # wt_reap_reason's snapshot and this moment are not the same instant.
  git -C "$main" worktree remove "$path" || panel_fail "git worktree remove refused $path" || return 1

  printf 'reaped %s\n' "$name"
}

cmd_gc() {
  local dry=0 repo='' arg
  for arg in "$@"; do
    case "$arg" in
    -n | --dry-run) dry=1 ;;
    -*) panel_die "gc: unknown flag: $arg" ;;
    *) repo="$arg" ;;
    esac
  done

  local -a candidates=()
  local d line path
  if [ -n "$repo" ]; then
    [ -d "$repo" ] || panel_die "not a directory: $repo"
    repo=$(wt_main_repo "$repo") || panel_die "not inside a git repository: $repo"
    while IFS= read -r line; do
      candidates+=("${line%%$PANEL_TAB*}")
    done < <(wt_worktrees_of "$repo")
  else
    for d in "$WT_ROOT"/*; do
      [ -d "$d" ] && candidates+=("$d")
    done
  fi

  # An empty candidate list is a RESULT, not a success. Every silent-success bug in this
  # tree has looked exactly like a sweep that ran over nothing and said "done".
  if [ "${#candidates[@]}" -eq 0 ]; then
    panel_hint "no worktrees to consider${repo:+ in $repo}"
    return 0
  fi

  local reaped=0 kept=0 reason
  for path in "${candidates[@]}"; do
    if reason=$(wt_reap_reason "$path"); then
      if [ "$dry" -eq 1 ]; then
        printf '%swould reap%s  %s\n' "$C_SEL" "$C_OFF" "$(basename "$path")"
      else
        cmd_reap "$path" >/dev/null && printf '%sreaped%s      %s\n' "$C_SEL" "$C_OFF" "$(basename "$path")"
      fi
      reaped=$((reaped + 1))
    else
      printf '%skept%s        %-28s %s%s%s\n' "$C_INP" "$C_OFF" "$(basename "$path")" "$C_DIM" "$reason" "$C_OFF"
      kept=$((kept + 1))
    fi
  done

  printf '\n%s of %s reapable, %s kept%s\n' "$reaped" "${#candidates[@]}" "$kept" \
    "$([ "$dry" -eq 1 ] && printf ' (dry run, nothing removed)')"
}

# ── Picker ───────────────────────────────────────────────────────────────────

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  panel_fzf_table

  local me picked
  me="$(printf '%q' "$SELF")"

  picked="$(cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --with-nth=5 \
    --prompt='worktree > ' \
    --header='enter land · ctrl-n new · ctrl-x reap · ctrl-r reload' \
    --bind="ctrl-n:become($me new)" \
    --bind="ctrl-x:execute($me reap {1} || (printf '\n[any key]'; read -r -n1))+reload($me --list)" \
    --bind="ctrl-r:reload($me --list)" \
    "$(panel_fzf_preview right 45)" \
    --preview="$me preview {1}" |
    cut -f1)"

  [ -n "$picked" ] || return 0
  wt_land "$picked"
}

# ── The test seam ────────────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
--list) cmd_list ;;
new)
  shift
  cmd_new "$@"
  ;;
reap)
  shift
  cmd_reap "$@"
  ;;
gc)
  shift
  cmd_gc "$@"
  ;;
preview)
  shift
  cmd_preview "$@"
  ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
