#!/usr/bin/env bash
# worktree.sh - the worktree panel. On PATH as `wt`.
#
# Usage: worktree.sh [verb]
#
# Verbs:
#   new [-c <dir>] [--server <name>] [--detach] [--claude] [--host <worker>] [--base <commit>]
#                     cut a fresh worktree off the repo containing <dir> (default $PWD),
#                     open a tmux session rooted in it, and land there. Reuses the lowest
#                     IDLE agent-N (reapable, see `reap`) before cutting a new one: an idle
#                     one is reset onto the trunk in place, keeping its ignored build caches.
#                     Inside tmux it lands you in the new session AT ONCE; the fetch and
#                     checkout then run in that session's first pane, where you can watch
#                     them (and read any error), and the pane becomes your shell.
#                     The session goes on the agent world (worlds.sh), and you hop there,
#                     whichever world you pressed the key in. --server opens it on that
#                     tmux server instead; --detach opens it without going there. Together
#                     they let a caller with no tmux of its own (fleet-dispatch, from a
#                     timer) start a session. --claude starts Claude in it (`claude-acct
#                     run`, the launcher `cl` uses): the one "new agent for this repo"
#                     that Prefix+p c, Prefix+f ctrl-n and Prefix+g ctrl-n all call.
#                     --host runs the same `new` on a fleet worker over ssh (fleet-hosts.sh),
#                     detached; <dir> is then a path on the worker. --base <commit> cuts
#                     the branch from that commit, not the trunk (fleet-dispatch: a phase
#                     stacked on its dependency's open PR), refused when it is not there
#                     after the fetch.
#                                                                               [Prefix+F]
#   (no verb)         pick a worktree. Enter lands in its session, ctrl-n cuts a new one,
#                     ctrl-x reaps the row under the cursor, ctrl-r reloads. Typed, NOT
#                     bound to a key: Prefix+F cuts a worktree outright rather than
#                     opening anything to choose from.
#   done [<name>]     THE CLEANUP. Kill this worktree's session and reap the worktree, in
#                     one go, safe to run FROM INSIDE that session.          [Prefix+X]
#                     From a Claude session in it, the kill waits for that session's Stop
#                     hook (wind-down arm); otherwise it is a timed job on the tmux server.
#   reap [<path>]     remove one worktree, but ONLY when it is clean, landed (merged or
#                     pushed) and has no live tmux session. Refuses with the reason
#                     otherwise. There is no --force.
#   revive <path> [--branch <b>]
#                     put a reaped worktree back at <path> (directly under $WT_ROOT), on <b>
#                     when it is still here, on its trunk remote or on origin, else on a new branch off the trunk,
#                     so a conversation that ran there can `claude --resume` (agent-ask reopen).
#                     Refuses a path or session name another tree holds now.
#   revive <file.bundle>
#                     put an archived tree back at its old path from its bundle, its
#                     uncommitted work back in the files. The bundle stays.
#   archive <path>    save a HELD tree (nobody in it, work on no remote) to a verified bundle
#                     under ~/.agent/archive/worktrees/<repo>/, uncommitted work included,
#                     then remove it. Refuses a landed or claimed tree. rc 1 kept, 2 failed.
#   bundle-state <file.bundle>
#                     print whether the commits an archive bundle holds have landed: `landed`,
#                     `unlanded<TAB><what><TAB><branch>` (what: n commits, uncommitted work, or both) or `unknown<TAB><why>`, rc 0, 1, 2. The
#                     gc runner deletes an old bundle only on `landed`.
#   gc [<repo>] [-n] [--tsv]
#                     reap every eligible worktree and NAME the ones it kept, one state word
#                     per tree (README: "Worktree states"). With no repo, everything under
#                     $WT_ROOT; with one, that repo's linked worktrees. --tsv prints
#                     state, action, name, path, reason per tree and no total.
#                     An orphan daemon in Library/ does not hold a tree: gc ends it and names its pid.
#   orphans [-n]      end every orphan daemon in a Unity project's Library/ (any path, not
#                     only $WT_ROOT) whose editor is gone, and name each by pid.
#   --list            the rows, TSV. The data behind the picker, split out so it is
#                     assertable without a terminal.
#   preview <path>    the picker's preview pane for one worktree.
#   --help, -h        this text
#
# THE WORKTREE IS THE AGENT. `agent-N` is not a persistent workspace slot; it is the Nth
# worktree alive in this system right now - allocated by `new`, freed by `reap`, and the
# number is reused once it is free. An IDLE slot counts as free: a worktree nobody is in
# (no session, no pane) whose work has landed is recycled in place by `new` rather than
# stepped over, so the highest N tracks how many agents are running, not how many ever ran. That is why nothing here has to teach the other surfaces
# a new concept: `agent-panel` (Prefix+g) already parses a session named `<repo>-agent-N`
# into project + agent number, and it enumerates live tmux panes, which ARE the live
# worktrees.
#
# So the layout is FLAT and the basename carries the identity:
#
#   ~/.worktrees/<repo>-agent-N        directory basename
#              == <repo>-agent-N       tmux session name  (panel_session_name)
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
. "${SELF%/*}/worlds.sh" || exit 1
# origin-repo.sh, and the one Forgejo client (so_forge_remote, so_forgejo_*).
# shellcheck source=../../lib/session-outcomes.sh
. "${SELF%/*}/../../lib/session-outcomes.sh" || exit 1
# shellcheck source=../../lib/agent-merge-proof.sh
. "${SELF%/*}/../../lib/agent-merge-proof.sh" || exit 1   # merge_proof_branch, for wt_default_branch
# shellcheck source=../../../.config/shared-hooks/project-name.sh
. "${PROJECT_NAME_LIB:-${SELF%/*}/../../../.config/shared-hooks/project-name.sh}" || exit 1

WT_ROOT="${WT_ROOT:-$HOME/.worktrees}"
# The command a new session's first window runs. Empty = a plain shell, which is the honest
# default: `new` is a worktree primitive, and what you run in it is your business.
WT_NEW_CMD="${WT_NEW_CMD:-}"
# The tmux server `new --server` targets. Empty = whichever server $TMUX points at. Every
# tmux call in this script goes through the function below, so one setting routes them
# all; a call that names its own server with -L (the cross-server liveness checks) is
# passed through untouched.
WT_SERVER=""
tmux() {
  if [ -n "$WT_SERVER" ] && [ "${1:-}" != -L ]; then
    command tmux -L "$WT_SERVER" "$@"
  else
    command tmux "$@"
  fi
}
# Repo discovery for --list, so the picker sees worktrees of repos that have none under
# $WT_ROOT yet (platform's siblings, for one). Same file the hooks resolve projects through.
WT_PROJECT_MAP="${WT_PROJECT_MAP:-$(project_map_file)}"
# Where the DEFERRED reap reports to. `done` kills the terminal that asked for it, so the
# outcome has nowhere to be printed; a refusal that nobody can read is the same as a silent
# one. Mirrors wind-down's fire.log, for the same reason.
WT_LOG="${WT_LOG:-$HOME/.agent/wt/done.log}"
# Where `new` takes its per-repo lock. Prefix+F runs in the background now, so nothing
# serializes two presses any more; without the lock both pick the same slot.
WT_LOCK_DIR="${WT_LOCK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wt}"
# agent-queue's store (its AQ_DIR): an active item there that names a tree's session owns it.
WT_QUEUE_DIR="${AGENT_QUEUE_DIR:-$HOME/.agent/queue}"
# Git prints this beside its own hint to unlock, so it is what the reader of a refusal acts on.
WT_HOLD_REASON='held by wt: wt done or wt reap frees it and refuses a live session; do not unlock it or use -f -f'

# ── Repo plumbing ────────────────────────────────────────────────────────────

# wt_main_repo <dir> -- the MAIN checkout of the repo containing <dir>.
#
# Via --git-common-dir, so it gives the same answer from inside a linked worktree as from
# the main one. That matters: `wt new` run inside `dotfiles-agent-1` must cut
# `dotfiles-agent-2`, not `dotfiles-agent-1-agent-1`. A submodule's common dir is
# <super>/.git/modules/<name>, whose core.worktree names its checkout; a bare repo has none.
# The probe is needed: --git-dir with no core.worktree takes the cwd as the toplevel. A
# deinitialised submodule keeps core.worktree, so the checkout must still exist.
wt_main_repo() {
  local common top
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
  */.git) printf '%s\n' "${common%/.git}" ;;
  *)
    git --git-dir="$common" config --get core.worktree >/dev/null 2>&1 || return 1
    top=$(git --git-dir="$common" rev-parse --show-toplevel 2>/dev/null) && [ -d "$top" ] || return 1
    printf '%s\n' "$top"
    ;;
  esac
}

# wt_repo_name <main-repo> -- the name a worktree of this repo carries.
#
# Leading dot stripped (`.dotfiles` -> `dotfiles`), interior dots folded. Same rule as every
# other session name, and it lives in panel-lib:panel_session_name -- see the note there for
# why each half matters.
wt_repo_name() { panel_session_name "$1"; }

# wt_trunk_remote <repo> -- the remote this repo lands on: its Forgejo remote when it is
# Forgejo-canonical (so_forge_remote, the rule agent-land and fleet-sessions' forge_of use), else
# origin. home-config's origin is the GitHub mirror, which lags the forge, and razer-laptop's clone
# has no origin at all: `fetch origin` failed every dispatch start there and cut each session off
# a local master 414 commits behind forgejo/master (ar-3218, 2026-11-24).
wt_trunk_remote() {
  local r rc=0
  r=$(so_forge_remote "$1" 2>/dev/null) || rc=$?
  case "$rc" in
  0) ;;
  2) panel_warn "$1 is Forgejo-canonical but no remote is on SO_FORGEJO_HOSTS; using origin"; r=origin ;;
  *) r=origin ;;
  esac
  printf '%s\n' "${r%% *}"
}

# wt_default_branch <main-repo> -- what this repo calls its trunk.
#
# `git config wt.trunk <branch>` wins over the trunk remote's default (merge_proof_branch), for a repo whose GitHub default is
# not where work lands. bnb/platform defaults to `main` (production manifests) but merges
# into `develop`: cutting from main put every agent on a stale base, and judging reap against
# main kept any worktree whose work had landed on develop but not been released yet.
wt_default_branch() {
  local ref
  if ref=$(git -C "$1" config --get wt.trunk 2>/dev/null) && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  if ref=$(MERGE_PROOF_REMOTE=$(wt_trunk_remote "$1") merge_proof_branch "$1"); then
    printf '%s\n' "$ref"
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

# wt_base_ref <main-repo> <branch> -- prefer <trunk remote>/<branch>; fall back to the local branch
# so this still works offline, or in a fixture repo with no remote.
wt_base_ref() {
  local remote
  remote=$(wt_trunk_remote "$1")
  if git -C "$1" rev-parse --verify --quiet "$remote/$2" >/dev/null 2>&1; then
    printf '%s/%s\n' "$remote" "$2"
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

# wt_is_husk <path> -- true when <path> has no .git and holds nothing but what a tool rewrote
# after the worktree was removed: whole cache dirs (WT_HUSK_CACHES), and a few named files
# (WT_HUSK_FILES) a Unity editor, Claude Code or pnpm writes into a project it still has open.
# Such a dir is no worktree, so nothing git-based ever reaped it, and it pinned its agent-N
# slot for good: 2026-11-03, 15 of them, eight holding a slot number. Anything else in a
# git-less dir may be someone's only copy of their work, so it stays out.
WT_HUSK_CACHES=' Library Logs Temp obj UserSettings node_modules '
WT_HUSK_FILES=' .claude/settings.local.json Packages/manifest.json Packages/packages-lock.json pnpm-lock.yaml '
wt_is_husk() {
  local e f
  [ -d "$1" ] && [ ! -e "$1/.git" ] || return 1
  for e in "$1"/* "$1"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    case "$WT_HUSK_CACHES" in *" ${e##*/} "*) continue ;; esac
    # Only a named file or its parent dir is walked; any other entry, even an empty dir, is kept.
    case "$WT_HUSK_FILES" in *" ${e##*/} "* | *" ${e##*/}/"*) ;; *) return 1 ;; esac
    while IFS= read -r -d '' f; do
      case "$WT_HUSK_FILES" in *" ${f#"$1"/} "*) ;; *) return 1 ;; esac
    done < <(find "$e" ! -type d -print0 2>/dev/null)
  done
}

wt_branch_of() { git -C "$1" branch --show-current 2>/dev/null; }

# wt_branch_name <main-repo> <n> -- the branch a cut of slot <n> starts on:
# `agent-<n>-<UTC yymmdd-HHMMSS>`, a name no earlier cut used, local or on a remote (a counter
# follows when one did, as two cuts of a slot in one second do). The slot number is reused; a
# branch name never is. GitHub keeps a PR's head after the PR merges or closes, so a reused
# `agent-N` met an old origin/agent-N: the push was rejected non-fast-forward and
# `gh pr create` opened a PR on the stale head (dotfiles #1546, #1579, #1650, #1661, #1666;
# ar-1121).
wt_branch_name() {
  local stem b i=1 remote
  remote=$(wt_trunk_remote "$1")
  stem="agent-$2-$(date -u +%y%m%d-%H%M%S)"
  b="$stem"
  while git -C "$1" show-ref --quiet "refs/heads/$b" "refs/remotes/origin/$b" "refs/remotes/$remote/$b"; do
    i=$((i + 1))
    b="$stem-$i"
  done
  printf '%s\n' "$b"
}

# wt_dirty_count <path> -- uncommitted changes that are WORK. One shape is not counted: a
# submodule left on an older commit after its superproject moved (`SC..`: commit changed,
# nothing modified or untracked inside, nothing staged) whose checkout is already on one of
# its remotes. That is a stale pointer, not work -- `submodule update` fixes it and loses
# nothing. Counting it pinned 17 of 29 unity-core-playground slots, every one dirty only
# because the trunk bumped External/unity-core underneath it, so `new` ratcheted to agent-31.
#
# A status that FAILS is not a clean tree: rc 1, printing git's first error line. Counting its
# empty output as 0 let a razer-laptop slot whose submodule .git a canary run had overwritten
# with a bare sha read clean and landed, so dispatch picked it to recycle on every pass and
# `git switch` refused on the files the run left (ar-6220).
wt_dirty_count() {
  local n=0 kind xy sub p st
  if ! st=$(git -C "$1" status --porcelain=v2 2>/dev/null); then
    st=$(git -C "$1" status --porcelain=v2 2>&1 >/dev/null)
    printf '%s\n' "${st%%$'\n'*}"
    return 1
  fi
  while read -r kind xy sub _ _ _ _ _ p; do
    [ -n "$kind" ] || continue
    if [ "$kind $xy $sub" = '1 .M SC..' ] && wt_submodule_pushed "$1/$p"; then
      continue
    fi
    n=$((n + 1))
  done <<<"$st"
  printf '%s\n' "$n"
}

# wt_submodule_pushed <dir> [<rev>] -- true when <rev> (default: the submodule's checked-out
# commit) is on a remote ref.
wt_submodule_pushed() {
  [ -n "$(git -C "$1" for-each-ref --count=1 --contains "${2:-HEAD}" refs/remotes 2>/dev/null)" ]
}

# wt_landed <path> <base-ref> -- has this worktree's work gone somewhere durable?
#
# Two ways to qualify, and either is enough: HEAD is already an ancestor of the trunk
# (merged), or every commit is on its upstream (pushed, PR open, review pending). A branch
# that is only ever pushed would never be reapable under the first test alone, and waiting
# for the merge to land locally would keep worktrees alive for days after they are done.
#
# A third: a PR from this branch was MERGED (wt_merged_pr_heads: GitHub, or Forgejo for a
# Forgejo-canonical repo), and HEAD is that PR's head, or has moved on from it by clean merges
# of the trunk only (wt_nothing_only_here). A squash merge puts a new commit on the trunk, so
# HEAD is never its ancestor, and the forge deletes the branch, so there is no upstream left
# either. Without this every squash-merged worktree was held as "not merged" forever
# (2026-10-23: unity-core-playground had several of those at 15-20 GB each; 2026-11-18: 4 of
# 55 home-config trees after the prune, whose PRs are on Forgejo, not the GitHub mirror).
#
# A fourth: HEAD is on any remote branch, whatever the local branch tracks. A tree cut with
# `worktree add -b <b> origin/main` tracks origin/main, and a plain `git push origin <b>` never
# moves that, so its pushed work read as "unpushed" (2026-11-18: 86 of 132 held trees, every
# ref live on its server). Trusted only for a repo wt_fetch_pruned fetched with --prune in
# this run, so a branch deleted on the server is never taken for pushed work; the picker
# fetches nothing and so never applies it.
wt_landed() {
  git -C "$1" merge-base --is-ancestor HEAD "$2" 2>/dev/null && return 0
  if git -C "$1" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1 &&
    [ -z "$(git -C "$1" rev-list '@{upstream}..HEAD' 2>/dev/null)" ]; then
    return 0
  fi
  local main
  if main=$(wt_main_repo "$1" 2>/dev/null) && printf '%s\n' "${WT_PRUNED_REPOS-}" | grep -qxF "$main" &&
    wt_submodule_pushed "$1"; then
    return 0
  fi
  local branch heads
  branch=$(git -C "$1" symbolic-ref --short -q HEAD) || return 1
  heads=$(wt_merged_pr_heads "$1" "$branch") && [ -n "$heads" ] || return 1
  # shellcheck disable=SC2086 # one oid a word, each checked to be hex
  wt_nothing_only_here "$1" $heads
}

# wt_nothing_only_here <path> <rev>... -- true when every commit HEAD reaches past the remote
# refs and the <rev>s is a merge whose combined diff is empty. A clean merge adds nothing; a
# conflict resolution or an edit made in the merge does, and `--cc` shows it. A <rev> this repo
# lacks is ignored, which only keeps the tree. With HEAD at a <rev> the walk is empty: landed.
wt_nothing_only_here() {
  local dir="$1" out c parents diff
  shift
  # --ignore-missing would drop an unborn HEAD too, and an empty walk reads as landed.
  git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null || return 1
  out=$(git -C "$dir" rev-list --ignore-missing --parents HEAD --not --remotes "$@" 2>/dev/null) || return 1
  while read -r c parents; do
    [ -n "$c" ] || continue
    [[ "$parents" == *' '* ]] || return 1
    # A failed diff-tree prints nothing too, so its status is read apart from its output.
    diff=$(git -C "$dir" diff-tree --no-commit-id --cc "$c" 2>/dev/null) || return 1
    [ -z "$diff" ] || return 1
  done <<<"$out"
  return 0
}

# wt_fetch_pruned <main>... -- fetch every remote of each repo with --prune, at most once per run:
# each repo tried goes on WT_FETCHED_REPOS, each that fetched cleanly on WT_PRUNED_REPOS (both
# exported, so the $(...) subshells the reap policy runs in see them). A repo whose fetch fails
# stays off the second list, so its trees are judged without the remote-branch rule: offline only
# ever keeps a tree, and the fetch is not retried for every tree of that repo.
wt_fetch_pruned() {
  local main
  for main in "$@"; do
    printf '%s\n' "${WT_FETCHED_REPOS-}" | grep -qxF "$main" && continue
    WT_FETCHED_REPOS="${WT_FETCHED_REPOS:+$WT_FETCHED_REPOS$'\n'}$main"
    if timeout "${WT_FETCH_TIMEOUT:-120}" git -C "$main" fetch --all --prune --quiet >/dev/null 2>&1; then
      WT_PRUNED_REPOS="${WT_PRUNED_REPOS:+$WT_PRUNED_REPOS$'\n'}$main"
    else
      panel_warn "fetch --prune failed in $main; its pushed-branch trees stay held this run"
    fi
  done
  export WT_FETCHED_REPOS WT_PRUNED_REPOS
}

# wt_work_reason_fetched <path> -- wt_work_reason, asked again after a pruned fetch of its repo when
# the first answer kept the work (rc 1) and that repo was not tried this run, so only a tree the
# remote-branch rule could still clear waits on the network. `reap` and `done` judge through this;
# gc fetches every repo up front, and the picker never fetches.
wt_work_reason_fetched() {
  local reason rc main
  reason=$(wt_work_reason "$1")
  rc=$?
  if [ "$rc" -eq 1 ] && main=$(wt_main_repo "$1" 2>/dev/null) &&
    ! printf '%s\n' "${WT_FETCHED_REPOS-}" | grep -qxF "$main"; then
    wt_fetch_pruned "$main"
    reason=$(wt_work_reason "$1")
    rc=$?
  fi
  [ -z "$reason" ] || printf '%s\n' "$reason"
  return "$rc"
}

# wt_merged_pr_heads <dir> <branch> -- the head oid of each MERGED PR from <branch>, one a line,
# read from the forge <dir> lands on (so_forge_remote, the rule agent-land uses): Forgejo through
# its API, else GitHub through gh. home-config's origin is the GitHub mirror, which has no PRs,
# so asking gh held its trees merged on Forgejo (2026-11-18). Fails closed: no jq, gh or token,
# an unlisted host, a network error or an oid that is not hex print nothing, which keeps a tree.
wt_merged_pr_heads() {
  local fj rc main def slug
  panel_have jq || return 1
  fj=$(so_forge_remote "$1")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    main=$(wt_main_repo "$1") && def=$(wt_default_branch "$main") || return 1
    so_forgejo_auth "${fj#* }" || return 1
    # One PR for the base/head pair, found after its branch is deleted too (a branch with more
    # than one may read as not merged, which only keeps it). Base and branch are percent-encoded;
    # the branch keeps its slashes, which the API reads as part of the head.
    # One try: a proxy that refuses with a plain 403 would otherwise sleep ~35 s per tree.
    SO_FORGEJO_GATE_TRIES=1 so_forgejo_get "${fj#* }" "pulls/$(jq -rn --arg x "$def" '$x|@uri')/$(jq -rn --arg x "$2" '$x|@uri|gsub("%2F";"/")')" 2>/dev/null |
      jq -r 'select(.merged == true) | .head.sha // empty' 2>/dev/null | grep -E '^[0-9a-f]{40,64}$'
    return 0
  fi
  [ "$rc" -eq 1 ] || return 1
  slug=$(origin_repo "$1" github.com) && panel_have gh || return 1
  timeout 20 gh pr list -R "$slug" --head "$2" --state merged --json headRefName,headRefOid,state 2>/dev/null |
    jq -r --arg b "$2" '.[] | select(.state == "MERGED" and .headRefName == $b) | .headRefOid' 2>/dev/null |
    grep -E '^[0-9a-f]{40,64}$'
  return 0
}

# wt_pr_merged_at <dir> <branch> <head> -- true when a MERGED PR on <branch> has <head> as its
# head, by wt_merged_pr_heads' fail-closed answer.
wt_pr_merged_at() {
  wt_merged_pr_heads "$1" "$2" | grep -qxF "$3"
}

# wt_submodule_list <path> -- `<name><TAB><path>` for each submodule in <path>'s .gitmodules.
wt_submodule_list() {
  local key sub
  git -C "$1" config -z -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null |
    while IFS=$'\n' read -r -d '' key sub; do
      key=${key#submodule.}
      printf '%s\t%s\n' "${key%.path}" "$sub"
    done
}

# wt_heal_submodule_urls <path> -- restore from .gitmodules any submodule URL that names a
# module store under a .git dir. That config is shared by every worktree, a store is one
# clone's private state and never a remote, and git refuses a local path for a submodule clone,
# so one such value broke every clone in the repo (2026-11-08, unity-core-playground). Any other
# URL, a deliberate local mirror included, is left alone.
wt_heal_submodule_urls() {
  local name sub url
  while IFS=$'\t' read -r name sub; do
    url=$(git -C "$1" config --get "submodule.$name.url") || continue
    case "$url" in */.git/*modules/*) ;; *) continue ;; esac
    panel_warn "$sub had the URL $url in the shared git config; restoring the one in .gitmodules"
    git -C "$1" submodule sync --quiet -- "$sub" >&2 || panel_warn "could not restore the URL of $sub"
  done < <(wt_submodule_list "$1")
}

# wt_empty_submodules <path> -- the submodules git was asked to fill (a URL in the config) that
# have no checkout in <path>. A module with no index was cloned but never checked out: the
# clone landed and the pinned commit was not in it.
wt_empty_submodules() {
  local name sub
  while IFS=$'\t' read -r name sub; do
    git -C "$1" config --get "submodule.$name.url" >/dev/null 2>&1 || continue
    # The .git test first: without one, git -C answers for the enclosing worktree.
    [ -e "$1/$sub/.git" ] &&
      [ -e "$(git -C "$1/$sub" rev-parse --path-format=absolute --git-path index 2>/dev/null)" ] ||
      printf '%s\n' "$sub"
  done < <(wt_submodule_list "$1")
}

# wt_submodule_worktrees <path> -- print the first linked worktree of any initialised
# submodule of <path>; nothing, and rc 1, when there are none. A worktree cut from a
# submodule (`git -C External/unity-core worktree add ~/.worktrees/unity-core-x`) keeps its
# git dir INSIDE this worktree's .git/modules, so removing this one orphans that one.
#
# One whose dir is gone (git marks it prunable) holds nothing but its HEAD, so it counts only
# while that commit is on no remote ref. Counting every one kept a tree for good over a scratch
# worktree deleted with its /tmp dir (2026-11-07: unity-core-playground-unity63b, two pushed).
# The main worktree is the first record, skipped by position: git names a submodule's by its
# .git/modules dir.
wt_submodule_worktrees() {
  local sub path head prunable
  while read -r _ sub _; do
    [ -e "$1/$sub/.git" ] || continue
    while IFS=$'\t' read -r path head prunable; do
      if [ "$prunable" != prunable ]; then
        printf '%s\n' "$path"
        return 0
      fi
      wt_submodule_pushed "$1/$sub" "$head" && continue
      printf '%s (its dir is gone and %s is on no remote)\n' "$path" "${head:0:12}"
      return 0
    done < <(git -C "$1/$sub" worktree list --porcelain 2>/dev/null |
      awk 'BEGIN { RS = ""; FS = "\n" }
        NR > 1 {
          p = ""; h = pr = "-" # a placeholder, as read collapses an empty tab-split field
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^worktree /) p = substr($i, 10)
            else if ($i ~ /^HEAD /) h = substr($i, 6)
            else if ($i ~ /^prunable/) pr = "prunable"
          }
          print p "\t" h "\t" pr
        }')
  done < <(git -C "$1" submodule status 2>/dev/null)
  return 1
}

# wt_editor_open <path> -- true when a Unity editor has <path> open. An editor holds no tmux
# pane, so the session checks miss it, and deleting a project under it loses its scene edits.
# Hub-launched editors run as unityhub-unity-editor-* with a lowercase -projectpath. An editor's
# working directory is its project, so one opened through a symlink or a differently spelled
# path counts too.
wt_editor_open() {
  local pid
  for pid in $(wt_pids_inside "$1"); do
    case "$(cat "${WT_PROC_ROOT:-/proc}/$pid/comm" 2>/dev/null)" in Unity* | unityhub-unity*) return 0 ;; esac
  done
  ps -eo comm=,args= 2>/dev/null |
    awk -v p="$1" '
      $1 !~ /^(Unity|unityhub-unity)/ { next }
      {
        # By text, not by field: a project path may hold spaces.
        at = index(tolower($0), " -projectpath ")
        if (!at) next
        rest = substr($0, at + 14)
        if (rest == p || index(rest, p " ") == 1) found = 1
      }
      END { exit !found }'
}

# ── tmux state ───────────────────────────────────────────────────────────────

# EVERY SERVER, not just this one. Agents run in `lab` while you sit in `hub`
# (servers.sh), so asking only the server the key was pressed on saw a worktree with a Claude
# working in it as idle: Prefix+F from hub would recycle it and `gc` would reap it, both
# under a live agent. wt_tmux_all runs one tmux query on the current server, then on each
# other live one, and concatenates the answers.
#
# wt_current_server -- the server $TMUX points at, by name (`default` outside tmux).
wt_current_server() {
  local cur="${TMUX:-}"
  cur="${cur%%,*}"
  cur="${cur##*/}"
  printf '%s\n' "${cur:-default}"
}

# wt_other_servers -- live servers other than the one calls go to (WT_SERVER, else $TMUX's).
wt_other_servers() {
  local cur="${WT_SERVER:-$(wt_current_server)}" s
  while IFS= read -r s; do
    [ -n "$s" ] && [ "$s" != "${cur:-default}" ] && printf '%s\n' "$s"
  done < <(tmux_live_servers)
  return 0
}

wt_tmux_all() {
  local s
  tmux "$@" 2>/dev/null
  while IFS= read -r s; do
    tmux -L "$s" "$@" 2>/dev/null
  done < <(wt_other_servers)
}

wt_live_sessions() { wt_tmux_all list-sessions -F '#{session_name}'; }

# wt_session_server <name> -- the server a live session of that name is on, rc 1 if none.
wt_session_server() {
  local s
  tmux has-session -t "=$1" 2>/dev/null && { printf '%s\n' "${WT_SERVER:-$(wt_current_server)}"; return 0; }
  while IFS= read -r s; do
    tmux -L "$s" has-session -t "=$1" 2>/dev/null && { printf '%s\n' "$s"; return 0; }
  done < <(wt_other_servers)
  return 1
}

wt_session_exists() { wt_session_server "$1" >/dev/null; }

# wt_pane_inside <path> -- true when any tmux pane, in ANY session, sits in <path> or below.
# The session-name check alone misses a pane that cd'd in from elsewhere: a Claude started in
# the main checkout's session and pointed at the worktree is just as live as one in its own.
wt_pane_inside() {
  wt_tmux_all list-panes -a -F '#{pane_current_path}' |
    awk -v p="$1" '$0 == p || index($0, p "/") == 1 { found = 1 } END { exit !found }'
}

# wt_pids_inside <path> [exe] -- pids whose working directory (or, with `exe`, whose
# executable) is <path> or below. A process of another user cannot be read, and is not ours
# to keep the tree for.
wt_pids_inside() {
  local path
  path=$(printf '%s' "$1" | sed 's/[][*?\\]/\\&/g') # -lname takes a glob; the path is literal
  find "${WT_PROC_ROOT:-/proc}"/[0-9]*/"${2:-cwd}" -maxdepth 0 \( -lname "$path" -o -lname "$path/*" \) -print 2>/dev/null |
    awk -F/ '{ print $(NF - 1) }'
}

# wt_orphans_inside <path> -- daemons nobody owns: the binary is under <path>/Library, and the
# parent is init or the user manager. Unity's gamedev-mcp-server is the case: it outlives its
# editor, and from #652 to 2026-11-02 its cwd pinned merged clean trees until 11 were killed by
# hand. Its parent is systemd from the start, so this does not prove the editor is gone:
# wt_occupied_reason asks wt_editor_open first. Library/ is Unity's regenerable cache, so a
# server someone left running from a build directory is never matched.
wt_orphans_inside() {
  local proc="${WT_PROC_ROOT:-/proc}" pid ppid
  for pid in $(wt_pids_inside "$1/Library" exe); do
    ppid=$(awk '$1 == "PPid:" { print $2 }' "$proc/$pid/status" 2>/dev/null)
    if [ "$ppid" = 1 ] || [ "$(cat "$proc/$ppid/comm" 2>/dev/null)" = systemd ]; then
      printf '%s\n' "$pid"
    fi
  done
}

# wt_await_exit <pid>... -- wait for pids to exit. The timeout is a guard: the caller looks
# at what is still there afterwards.
WT_SETTLE_SECS="${WT_SETTLE_SECS:-30}"
wt_await_exit() {
  waitpid --exited --timeout "$WT_SETTLE_SECS" "$@" >/dev/null 2>&1 || :
}

# wt_end_orphans <path> -- ask the orphans in <path> to exit, once wt_reap_reason has passed.
# rc 1 when one is still there afterwards, so the tree is kept and says why.
wt_end_orphans() {
  local pids
  pids=$(wt_orphans_inside "$1")
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids 2>/dev/null
  # shellcheck disable=SC2086
  wt_await_exit $pids
  [ -z "$(wt_orphans_inside "$1")" ] || panel_fail "kept $(basename "$1"): an orphan daemon outlived SIGTERM"
}

# wt_process_inside <path> -- true when any process but an orphan has its working directory
# in <path> or below. A build, a test run or a subagent's shell holds no tmux pane, and a tree
# deleted under one fails it halfway.
wt_process_inside() {
  local pids
  pids=$(wt_pids_inside "$1")
  [ -n "$pids" ] || return 1
  [ -n "$(grep -vxFf <(wt_orphans_inside "$1") <<<"$pids")" ]
}

# ── Eligibility ──────────────────────────────────────────────────────────────

# wt_work_reason <path> -- print why <path> still holds WORK; nothing, and rc 0, when the
# work is safely elsewhere; rc 2 when <path> is no worktree at all (gone, git-less and not a
# husk, a main checkout, or a .git git cannot resolve), so wt_state need not probe it again.
#
# Split out of wt_reap_reason for exactly one caller: `done` kills its own session, so the live-session rule below would refuse it every single time. `done`
# has to ask "is the work safe?" while the session is still up, which is this question, and
# leave "is anything running there?" to the deferred reap that runs after the kill.
#
# Keeping it as one function with a flag was the alternative. Two questions that are asked at
# two different MOMENTS are not one question with an argument.
wt_work_reason() {
  local path="$1" main def base dirty up

  [ -d "$path" ] || {
    printf 'no such directory\n'
    return 2
  }
  if [ ! -e "$path/.git" ]; then
    wt_is_husk "$path" && return 0
    printf 'no git, and it holds more than tool caches\n'
    return 2
  fi
  wt_is_linked "$path" || {
    printf 'a main checkout, not a worktree\n'
    return 2
  }

  dirty=$(wt_dirty_count "$path") || {
    printf 'git status fails: %s\n' "$dirty"
    return 1
  }
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

  local nested
  if nested=$(wt_submodule_worktrees "$path"); then
    printf 'a submodule worktree lives off it: %s\n' "$nested"
    return 1
  fi

  if ! wt_landed "$path" "$base"; then
    if up=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) && [ -n "$up" ]; then
      printf 'unpushed commits (ahead of %s)\n' "$up"
    else
      printf 'not merged into %s, and no upstream to push to\n' "$base"
    fi
    return 1
  fi

  return 0
}

# wt_reap_reason <path> -- print why <path> may NOT be reaped; nothing, and rc 0, when it may.
# The ONE place the reap policy lives, so the picker's glyph, `reap` and `gc` can never
# disagree about what is safe. --fetch judges the work through wt_work_reason_fetched (reap);
# the picker and `new` ask without it, so they never wait on the network.
wt_reap_reason() {
  local reason work=wt_work_reason
  [ "${2:-}" != --fetch ] || work=wt_work_reason_fetched
  reason=$("$work" "$1") || {
    printf '%s\n' "$reason"
    return 1
  }
  reason=$(wt_occupied_reason "$1") || {
    printf '%s\n' "$reason"
    return 1
  }
  return 0
}

# wt_occupied_reason <path> -- print what is running in <path>; nothing, and rc 0, when
# nobody is in it. Split out so `gc` can tell a tree held for work someone is still doing
# from one whose owner is gone, which is the tree nobody will ever come back to.
wt_occupied_reason() {
  # A LIVE SESSION IS NEVER REAPED, attached or not. "Clean and pushed" is a snapshot, not a
  # promise: an agent working detached in this worktree is clean-and-pushed for a moment after
  # every push, and a `gc` that happened to run in that window would delete the tree out from
  # under it mid-turn. Being unattached says nothing about whether anything is running there.
  # This is why wind-down -- and now `done` -- reap only AFTER the kill: by then there is no
  # session, and the check passes honestly rather than being waived.
  if wt_session_exists "$(panel_session_name "$1")"; then
    printf 'its tmux session is live\n'
    return 1
  fi
  if wt_pane_inside "$1"; then
    printf 'a tmux pane is open inside it\n'
    return 1
  fi
  if wt_editor_open "$1"; then
    printf 'a Unity editor has it open\n'
    return 1
  fi
  if wt_process_inside "$1"; then
    printf 'a running process is inside it\n'
    return 1
  fi
  # Another tool's git lock is git's own "do not remove this": a runner that reuses one tree
  # every pass holds it so gc does not reap it between passes.
  local reason
  if reason=$(wt_foreign_lock "$1"); then
    printf 'git-locked: %s\n' "${reason:-no reason given}"
    return 1
  fi
  # The queue is the owner of record, and it outlives a crash: tmux died with the machine, so
  # the 2026-11-17 boot catch-up gc reaped 12 trees of running items as landed before
  # fleet-dispatch restore could bring their sessions back (ar-2657).
  if reason=$(wt_queue_claim "$1"); then
    printf '%s\n' "$reason"
    return 1
  fi

  return 0
}

# wt_queue_claim <path> -- print why the queue owns <path>: the first running, waiting or review
# item whose `session:` (`<server>:<name>`, or a bare name) is <path>'s session; rc 1 when none.
# Frontmatter only: the body is the task text, which may quote any session line. A queue it
# cannot read claims the tree too: a reaper that fails open is the bug this check exists for.
wt_queue_claim() {
  local name f out rc
  local -a files=()
  name=$(panel_session_name "$1")
  for f in "$WT_QUEUE_DIR"/{running,waiting,review}/*.md; do
    [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  out=$(awk -v n="$name" '
    FNR == 1 { slug = ""; s = ""; k = split(FILENAME, p, "/"); st = p[k - 1] }
    /^---$/ { if (s == n) { found = 1; exit } nextfile }
    /^slug: / { slug = substr($0, 7) }
    /^session: / { s = substr($0, 10); sub(/^[^:]*:/, "", s); sub(/[ \t\r]+$/, "", s) }
    END { if (found) printf "queue item %s (%s) names its session\n", slug, st; exit !found }
  ' "${files[@]}" 2>&1)
  rc=$?
  [ "$rc" -ne 1 ] || return 1
  [ "$rc" -eq 0 ] || out="the agent queue could not be read (awk rc $rc)"
  printf '%s\n' "$out"
}

# wt_foreign_lock <path> -- print the reason of a git lock on linked worktree <path> that is not
# wt's own hold; rc 1 when it has no lock or only wt's. wt's is told by the prefix of
# WT_HOLD_REASON, so rewording the rest of it, or a slot an older wt locked, still reads as wt's.
wt_foreign_lock() {
  local gd reason
  [ -f "$1/.git" ] || return 1
  gd=$(<"$1/.git")
  gd=${gd#gitdir: }
  case "$gd" in /*) ;; *) gd="$1/$gd" ;; esac
  [ -f "$gd/locked" ] || return 1
  reason=$(<"$gd/locked") || return 1
  [[ "$reason" != "${WT_HOLD_REASON%%:*}:"* ]] || return 1
  printf '%s' "$reason"
}

# The one state word gc prints per tree, derived each pass and never stored. The states table
# in .local/src/tmux/README.md names the same words; tests/unit/worktree.bats pins the two.
WT_GC_STATES='landed husk claimed held not-a-worktree'

# wt_state <path> -- print `<state><TAB><reason>`, the state one of WT_GC_STATES. Built on the
# same two checks as wt_reap_reason, each run once: landed and husk are exactly the trees
# wt_reap_reason passes. The reason is the work one first, as wt_reap_reason gives it.
wt_state() {
  local work rc occ
  # Never judged through the link: it may point at a main checkout or anyone's tree.
  if [ -L "$1" ]; then
    printf 'not-a-worktree\ta symlink to %s\n' "$(readlink "$1")"
    return 0
  fi
  work=$(wt_work_reason "$1")
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'not-a-worktree\t%s\n' "$work"
  elif ! occ=$(wt_occupied_reason "$1"); then
    printf 'claimed\t%s\n' "${work:-$occ}"
  elif [ "$rc" -ne 0 ]; then
    printf 'held\t%s\n' "$work"
  elif wt_is_husk "$1"; then
    printf 'husk\t\n'
  else
    printf 'landed\t\n'
  fi
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
# The main is the first record, skipped by position: in a submodule git names it by its
# .git/modules dir, which matches no checkout path.
wt_worktrees_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null |
    awk '
      /^worktree /  { n++; path = substr($0, 10); branch = "" ; next }
      /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
      /^detached$/  { branch = "(detached)" }
      /^$/          { if (n > 1 && path != "") print path "\t" branch; path = "" }
      END           { if (n > 1 && path != "") print path "\t" branch }
    '
}

# One row: path, name, branch, state, then the human label LAST so --with-nth can hide the
# rest. State is a single machine-readable word, which is what the tests assert on.
wt_row() {
  local path="$1" branch="$2" base="$3" sessions="$4"
  local name dirty state glyph note

  name="$(basename "$path")"
  if ! dirty=$(wt_dirty_count "$path"); then
    state=dirty
    glyph="$G_ATTN"
    note="git status fails"
  elif [ "$dirty" -gt 0 ]; then
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

# wt_next_slot <repo-name> <main-repo> -- `N<TAB>fresh` or `N<TAB>recycle` for the
# lowest agent-N that `new` may take.
#
# fresh: the directory is gone and no session holds the name. A branch left from an earlier
# cut does not pin the slot: every cut starts on a new name (wt_branch_name), so nothing
# here ever resets an old branch, and `wt gc` prunes the merged ones.
#
# recycle: the directory is a worktree of THIS repo and wt_reap_reason passes -- clean,
# landed, no session, no pane. The same predicate that would let `gc` delete it, so reusing
# it can lose nothing that deleting it would not. Without this, a session killed any way but
# `wt done` pins its slot forever and N ratchets (unity-core-playground reached agent-15 with
# eight of those idle).
#
# RECYCLE BEATS FRESH, whatever the numbers: the lowest idle slot wins, and a fresh slot is
# cut only when no idle one exists (1 busy, 2 free, 3 idle -> 3). A fresh slot is a full
# checkout with cold build state; on unity-core-playground that is the freeze Prefix+F was
# known for plus a Unity reimport, and it was taking hole 15 while 20 and 27 sat idle. Small
# numbers are nice for agent-panel's `3:1` labels, not worth minutes per agent.
wt_next_slot() {
  local repo="$1" main="$2" n=1 path owner fresh=''
  while [ "$n" -le 99 ]; do
    path="$WT_ROOT/$repo-agent-$n"
    if [ -e "$path" ]; then
      # wt_reap_reason includes the live-session and open-pane checks, on every server, but
      # only AFTER its git work check: ~1s a slot on unity-core-playground (status across a
      # 150k-file submodule), with nothing on screen yet. A live session pins the slot either
      # way, and asking tmux first is 45ms.
      if ! wt_session_exists "$repo-agent-$n" &&
        owner=$(wt_main_repo "$path") && [ "$owner" = "$main" ] &&
        wt_reap_reason "$path" >/dev/null; then
        printf '%s\trecycle\n' "$n"
        return 0
      fi
    elif [ -z "$fresh" ] && ! wt_session_exists "$repo-agent-$n"; then
      # A live session pins its slot even with the directory gone. Its worktree can be
      # removed out from under it (an agent running `rm -rf` or `remove -f -f` past
      # wt_hold), and handing the slot out again landed the new worktree in the OLD session:
      # wt_ensure_session found the name taken and reused it, so you arrived among panes
      # still sitting in the deleted directory.
      #
      # With no session, a hold that outlived its directory is dropped here: `rm -rf` or a husk
      # reap leaves the entry, and `prune` skips a locked one, so it would pin the slot for good.
      # An unlocked entry (a reap killed after its unlock) is dropped too: unlock fails on it, so
      # it must not gate the remove, or `git worktree add` refuses the path (ar-5133).
      { git -C "$main" worktree unlock "$path"; git -C "$main" worktree remove "$path"; } 2>/dev/null || :
      fresh="$n"
    fi
    n=$((n + 1))
  done
  if [ -n "$fresh" ]; then
    printf '%s\tfresh\n' "$fresh"
    return 0
  fi
  panel_fail "no free slot: $WT_ROOT/$repo-agent-{1..99} are all taken or busy" || return 1
}

# wt_recycle <path> <n> <base> -- put an idle worktree on a new branch (wt_branch_name) at <base>.
#
# In place rather than reap + add: the tree is clean, so a switch loses nothing tracked, and
# the ignored build state (Unity's Library/, node_modules) survives, which is minutes saved
# per agent. The branch it was on goes the way `reap` sends it -- `-d`, never `-D`.
wt_recycle() {
  local path="$1" branch base="$3" old main
  wt_end_orphans "$path" || return 1
  old="$(wt_branch_of "$path")"
  main=$(wt_main_repo "$path") || return 1
  branch=$(wt_branch_name "$main" "$2")
  git -C "$path" switch --quiet -c "$branch" "$base" >&2 || return 1
  # Bring the already-initialised submodules to what <base> records; wt_dirty_count waved
  # through a stale one as idle, so this is where it stops being stale. A failure that leaves a
  # checkout behind (offline, commit not fetchable) leaves the tree usable, so it warns. One
  # that leaves a submodule EMPTY does not: a session started on that tree has no engine to
  # build against, so the recycle fails and `new` starts nothing.
  #
  # NEVER smudge LFS here. A submodule's LFS store lives in ITS gitdir, one per worktree, so a
  # plain update re-downloads everything that store lacks: on unity-core-playground that was
  # 4.2 GB of External/asset-library, 20+ minutes behind Prefix+F with no output. Repos that
  # carry LFS submodules own the fetch (that one: scripts/setup/asset-library.sh, a shared
  # store plus reflinked checkout). `lfs checkout` then fills in whatever the module's
  # CONFIGURED store already holds, offline; anything it lacks stays a pointer for the repo's
  # own setup to fetch, which is exactly the state a fresh `worktree add` is in.
  #
  # And only on the files this update CHANGED. A bare `lfs checkout` scans the whole tree
  # (asset-library: 28k LFS files, 20s+); given paths it is 0.07s. wt_reap_reason already
  # proved the tree clean, so an unmoved file holds nothing its last checkout did not fill in.
  # A module with no recorded HEAD (initialised by this update) gets the full checkout.
  local heads empty=''
  wt_heal_submodule_urls "$path"
  heads=$(git -C "$path" submodule foreach --quiet --recursive \
    'printf "%s %s\n" "$displaypath" "$(git rev-parse HEAD)"' 2>/dev/null)
  # Take each new submodule commit from the MAIN checkout's copy first. wt_prepare's fetch
  # already brought it there (git fetches submodules on demand when a pointer moves), but
  # every worktree has its own submodule store, so `update` went back to the network for it:
  # ~1s of ssh to github for unity-core, against 8ms locally. Anything the main copy lacks
  # is left to `update`, which fetches it from the network as before.
  #
  # Into a REF, refs/wt/main: `update` counts a commit as present only when a ref reaches it
  # (FETCH_HEAD does not; the skip test above is that same rule), and NOT under refs/remotes, where wt_submodule_pushed would take a
  # commit that only the main checkout has for a pushed one.
  WT_MAIN="$main" git -C "$path" submodule foreach --quiet --recursive '
    git cat-file -e "$sha1^{commit}" 2>/dev/null &&
      [ -z "$(git rev-list -n 1 "$sha1" --not --all 2>/dev/null)" ] && exit 0
    [ -e "$WT_MAIN/$displaypath/.git" ] || exit 0
    git fetch --quiet --no-tags "$WT_MAIN/$displaypath" "+$sha1:refs/wt/main" >/dev/null 2>&1 || true' >&2
  if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$path" submodule update --recursive --quiet >&2; then
    empty=$(wt_empty_submodules "$path")
    [ -n "$empty" ] || panel_warn "submodules in $path are not at $base; run git submodule update there"
  fi
  if panel_have git-lfs; then
    WT_SUB_HEADS="$heads" git -C "$path" submodule foreach --quiet --recursive '
      old=$(printf "%s\n" "$WT_SUB_HEADS" | while IFS= read -r l; do
        [ "${l% *}" = "$displaypath" ] && printf %s "${l##* }"; done)
      [ -z "$old" ] && { git lfs checkout >/dev/null 2>&1 || true; exit 0; }
      # Empty means nothing to fill, and xargs without -r (not on BSD) would run a bare
      # `lfs checkout` -- the full scan -- on no input.
      [ -z "$(git diff --name-only --diff-filter=d "$old" HEAD)" ] && exit 0
      git diff --name-only -z --diff-filter=d "$old" HEAD |
        xargs -0 git lfs checkout -- >/dev/null 2>&1 || true' >&2
  fi
  if [ -n "$old" ]; then
    git -C "$main" branch -d "$old" >/dev/null 2>&1 ||
      panel_warn "kept branch $old: git will not safely delete it"
  fi
  [ -z "$empty" ] || panel_fail "$path has empty submodules: ${empty//$'\n'/, } (see the git error above)" || return 1
  return 0
}

# wt_lock <path> -- take the lock at <path>, or return 1 while a live process holds it.
#
# A symlink whose target is the holder's pid: `ln -s` is atomic and carries the pid in the
# same step, where mkdir-then-write leaves a window with a lock and no owner. flock would do,
# but the Mac has none. A lock whose pid is dead (the holder was SIGKILLed past its EXIT
# trap) is taken over.
wt_lock() {
  local lock="$1" pid
  mkdir -p "${lock%/*}" 2>/dev/null || return 1
  ln -s "$$" "$lock" 2>/dev/null && return 0
  pid=$(readlink "$lock" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 1
  rm -f "$lock"
  ln -s "$$" "$lock" 2>/dev/null
}

# wt_to_agent_world [<session>] -- send this run's sessions to the agent world (`@agents`, lab),
# from whichever world the key was pressed in, or from no tmux at all: every worktree session
# lives there, the human's and the dispatched ones alike, and only main checkouts sit in hub.
# A <session> already live on some server stays there: a second session on the same directory
# would be a second Claude in it. An explicit --server still wins. Inside tmux the client has to
# cross servers too, which WT_HOP tells wt_focus.
WT_HOP=0
wt_to_agent_world() {
  local session="${1:-}" world=''
  [ -z "$WT_SERVER" ] || return 0
  [ -z "$session" ] || world="$(wt_session_server "$session")"
  [ -n "$world" ] || world="$(world_agents)"
  [ -n "$world" ] && [ "$world" != "$(wt_current_server)" ] || return 0
  WT_SERVER="$world"
  panel_in_tmux && WT_HOP=1
  return 0
}

# wt_focus <session> -- go there. switch-client cannot cross servers; tmx owns the hop.
wt_focus() {
  if [ "$WT_HOP" = 1 ]; then
    panel_need tmx
    tmx goto "$WT_SERVER" "$1"
  else
    panel_focus_session "$1"
  fi
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
  local dir="$PWD" detach=0 host='' pin=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --base)
      pin="${2:-}"
      [ -n "$pin" ] || panel_die "--base needs a commit"
      shift 2
      ;;
    --host)
      host="${2:-}"
      [ -n "$host" ] || panel_die "--host needs a fleet worker name"
      shift 2
      ;;
    -c | --cwd)
      dir="${2:-}"
      shift 2 || panel_die "-c needs a directory"
      ;;
    --server)
      WT_SERVER="${2:-}"
      [ -n "$WT_SERVER" ] || panel_die "--server needs a tmux server name"
      shift 2
      # The session goes to that server, not the caller's, so take the outside-tmux path:
      # prepare here, then create the session detached.
      unset TMUX
      ;;
    -d | --detach)
      detach=1
      shift
      ;;
    --claude)
      WT_NEW_CMD='claude-acct run'
      shift
      ;;
    *) panel_die "new: unknown arg: $1" ;;
    esac
  done
  [ -z "$host" ] || [ -z "$pin" ] || panel_die "--base does not go with --host"
  [ -z "$host" ] || { wt_new_remote "$host" "$dir"; return; }
  # tmux reports a pane whose directory was deleted as `<path> (deleted)`, which is how Linux
  # reads /proc/<pid>/cwd. `new` only needs the REPO, so the same path re-created is as good
  # as the original; if nothing is there now, say so rather than "not a directory".
  case "$dir" in
  *' (deleted)')
    dir="${dir% (deleted)}"
    [ -d "$dir" ] || panel_die "this pane's directory was deleted: $dir (cd into the repo and retry)"
    ;;
  esac
  [ -d "$dir" ] || panel_die "not a directory: $dir"

  local main repo def slot n kind path name lock start
  main=$(wt_main_repo "$dir") || panel_die "not inside a git repository: $dir"
  repo=$(wt_repo_name "$main")

  wt_to_agent_world

  lock="$WT_LOCK_DIR/new-$repo.lock"
  wt_lock "$lock" || panel_die "already preparing a worktree for $repo"
  # shellcheck disable=SC2064 # expand $lock now: it is local, and gone by the time EXIT fires
  trap "rm -f $(printf '%q' "$lock")" EXIT

  # Prefix+F runs this with its output thrown away, so until the session exists the status
  # line is the only place to say anything.
  # `command tmux`: the message is for the client that pressed the key, which is on $TMUX's
  # server even when the session is headed for another.
  panel_in_tmux && command tmux display-message -d 20000 "wt: finding a free $repo slot..." 2>/dev/null

  # The slot is chosen BEFORE the fetch, against the trunk already on disk: that is what makes
  # landing instant. Safe, because the trunk only moves forward -- a worktree landed on the
  # old tip is landed on the new one.
  def=$(wt_default_branch "$main") || panel_die "cannot resolve the default branch of $main"
  wt_base_ref "$main" "$def" >/dev/null || panel_die "no $def in $main to branch from"
  slot=$(wt_next_slot "$repo" "$main") || return 1
  n="${slot%%$PANEL_TAB*}"
  kind="${slot#*$PANEL_TAB}"
  path="$WT_ROOT/$repo-agent-$n"
  name="$repo-agent-$n"

  # In tmux: create the session now, running the slow half in its first pane, and go there.
  # Doing that work in the background first meant ~20 s of nothing (a whole asset-library
  # fetch, once), then a switch-client that yanked you out of wherever you had gone since.
  # From here the live session is what claims the slot -- wt_next_slot skips any slot with
  # one -- so the lock is released on return and a second press takes the NEXT slot.
  if panel_in_tmux; then
    command tmux display-message "wt: $kind $name, opening it" 2>/dev/null
    start="$path"
    [ "$kind" = recycle ] || start="$main"
    # WT_NEW_CMD rides as an argument: the pane gets the SERVER's environment, not ours, and
    # `new-session -e` would leave it in the session's, where every later window inherits it.
    tmux new-session -ds "$name" -c "$start" \
      "$(printf '%q ' "$SELF" _prepare "$main" "$path" "$n" "$kind" "$WT_NEW_CMD" "$pin")" ||
      panel_die "could not create session $name"
    printf '%s\n' "$name"
    if [ "$detach" = 1 ]; then
      :
    else
      wt_focus "$name"
    fi
    return 0
  fi

  wt_prepare "$main" "$path" "$n" "$kind" "$pin" || exit 1
  wt_ensure_session "$name" "$path" || panel_die "could not create session $name"
  printf '%s\n' "$name"
  [ "$detach" = 1 ] || panel_focus_session "$name"
}

# wt_new_remote <host> <dir> -- `new` on a fleet worker (fleet-hosts.sh): the same verb runs
# there over ssh, detached (a remote session has no client here to focus), on the same tmux
# server, with WT_NEW_CMD passed as its environment. <dir> is a path on the worker. Prints the
# session name the worker printed.
wt_new_remote() {
  local host="$1" dir="$2" out args=(new --detach -c "$dir")
  # shellcheck source=../../lib/fleet-hosts.sh
  . "${FLEET_HOSTS_LIB:-${SELF%/*}/../../lib/fleet-hosts.sh}" || exit 1
  [ -z "${WT_SERVER:-}" ] || args+=(--server "$WT_SERVER")
  out=$(fleet_host_run "$host" WT_NEW_CMD="${WT_NEW_CMD:-}" wt "${args[@]}") ||
    panel_die "could not open a session on $host"
  printf '%s\n' "${out##*$'\n'}"
}

# wt_hold <path> -- git-lock a worktree, so that only `reap` can remove it.
#
# wt_reap_reason binds only the callers that ask it. On 2026-11-06 a session cleaning up after
# its finished run typed `git worktree remove` on dotfiles-agent-4, 57 s after dispatch had
# re-cut that slot for another session; the tree was clean, so git let it go. A lock is the one
# check git makes itself, so it binds every harness, the WorktreeRemove hook and any script:
# `remove`, `remove --force` and `move` refuse, and `prune` skips it. Only `rm -rf` and
# `remove -f -f` get past, and wt_next_slot clears what those leave.
wt_hold() {
  local out
  out=$(git -C "$1" worktree lock --reason "$WT_HOLD_REASON" "$1" 2>&1) && return 0
  case "$out" in
  *'already locked'*) ;;
  *) panel_warn "could not lock $(basename "$1"): $out" ;;
  esac
}

# wt_prepare <main> <path> <n> <recycle|fresh> [<commit>] -- the slow half of `new`: fetch, then start a
# new branch (wt_branch_name) at the trunk, or at <commit> when one is pinned (`new --base`: it must
# exist after the fetch, else the cut fails rather than falling back to the trunk), by resetting the
# idle worktree in place or cutting a fresh one.
wt_prepare() {
  local main="$1" path="$2" n="$3" kind="$4" pin="${5:-}" def base
  # Best-effort: an offline machine still gets a worktree, just off the last-known trunk.
  git -C "$main" fetch "$(wt_trunk_remote "$main")" --quiet || panel_warn "fetch failed; cutting off the local trunk"
  if [ -n "$pin" ]; then
    base=$(git -C "$main" rev-parse --verify --quiet "$pin^{commit}") ||
      panel_fail "--base $pin is no commit in $main after the fetch" || return 1
  else
    def=$(wt_default_branch "$main") || panel_fail "cannot resolve the default branch of $main" || return 1
    base=$(wt_base_ref "$main" "$def") || panel_fail "no $def in $main to branch from" || return 1
  fi

  if [ "$kind" = recycle ]; then
    wt_recycle "$path" "$n" "$base" || panel_fail "could not reset idle worktree $path onto $base" || return 1
    panel_warn "reusing idle $(basename "$path"), reset onto $base"
  else
    mkdir -p "$WT_ROOT" || panel_fail "cannot create $WT_ROOT" || return 1
    git -C "$main" worktree add "$path" -b "$(wt_branch_name "$main" "$n")" "$base" >&2 ||
      panel_fail "git worktree add failed: $path" || return 1
    # A fresh tree leaves its submodules to the repo's own setup, which needs a working URL.
    wt_heal_submodule_urls "$path"
  fi
  wt_link_vendor "$main" "$path"
  wt_hold "$path"
}

# wt_link_vendor <main> <path> -- link the tree's tests/vendor (bats and its helpers, git-ignored,
# cloned once into the main checkout by `make -C tests bootstrap`) to the main checkout's, so
# tests/run-bats.sh runs there with no search. Sessions in trees without it hunted for bats with
# `find /` (109 hand-methods denies in 7 days to 2026-11-23). Nothing to do when the main checkout
# has none, the tree has one already, or the repo does not ignore the path (a link would be dirt).
wt_link_vendor() {
  local src="$1/tests/vendor" v="$2/tests/vendor"
  [ -d "$src" ] && [ -d "$2/tests" ] && [ ! -e "$v" ] && [ ! -L "$v" ] || return 0
  git -C "$2" check-ignore -q tests/vendor || return 0
  ln -s -- "$src" "$v" || panel_warn "could not link $v to $src"
  return 0
}

# cmd_prepare <main> <path> <n> <kind> [<cmd>] -- `_prepare`, the first pane of a session
# `new` opened inside tmux. Not for typing: it does wt_prepare in the foreground, then BECOMES
# the pane's command (`new`'s WT_NEW_CMD) or shell -- in the worktree on success, in the main
# checkout on failure with the error left on screen.
cmd_prepare() {
  local main="$1" path="$2" n="$3" kind="$4" cmd="${5:-}" pin="${6:-}" what
  what="cutting $(basename "$path")"
  [ "$kind" = recycle ] && what="reusing idle $(basename "$path")"
  printf '%swt: %s, fetching and checking out...%s\n' "$C_DIM" "$what" "$C_OFF"
  if wt_prepare "$main" "$path" "$n" "$kind" "$pin"; then
    printf '%swt: ready.%s\n' "$C_SEL" "$C_OFF"
    cd "$path" || exit 1
    [ -n "$cmd" ] && exec "${SHELL:-/bin/sh}" -c "$cmd"
    exec "${SHELL:-/bin/sh}" -l
  fi
  printf '\n%swt: %s FAILED, see above. This shell is in %s.%s\n' "$C_ERR" "$what" "$main" "$C_OFF"
  cd "$main" || exit 1
  exec "${SHELL:-/bin/sh}" -l
}

# wt_land <path> -- ensure the session for an EXISTING worktree, then go there.
wt_land() {
  local path="$1" name
  [ -d "$path" ] || panel_die "no such worktree: $path"
  name="$(basename "$path")"
  wt_to_agent_world "$name"
  wt_ensure_session "$name" "$path" || panel_die "could not create session $name"
  wt_focus "$name"
}

# wt_settle <path> -- after the kill and before the reap: let the killed session's processes
# finish exiting, so the reap does not count them. `kill-session` only SIGHUPs the panes and
# returns, and the reap ran in that same instant: from #681 to 2026-11-03, 57 of the last 60
# done.log lines were "a running process is inside it", for slots whose sessions were gone.
# A process whose BINARY lives in the tree (Unity's gamedev-mcp-server, in Library/) is
# reparented to systemd and never exits, so it is told to. Nothing is waited on or killed
# while a session or pane is still in the tree (a window-scope wind-down): reap refuses that
# anyway. waitpid's timeout is a guard; whatever is still there afterwards is what reap reports.
wt_settle() {
  local path="$1" pids
  wt_session_exists "$(panel_session_name "$path")" && return 0
  wt_pane_inside "$path" && return 0
  pids=$(wt_pids_inside "$path" exe)
  # shellcheck disable=SC2086 # one pid per word
  [ -z "$pids" ] || kill -TERM $pids 2>/dev/null
  pids=$( { wt_pids_inside "$path"; wt_pids_inside "$path" exe; } | sort -u)
  # shellcheck disable=SC2086
  [ -z "$pids" ] || wt_await_exit $pids
}

cmd_reap() {
  local settle=0 path reason main name branch
  [ "${1:-}" = --after-kill ] && settle=1 && shift
  path="$(realpath "${1:-$PWD}" 2>/dev/null)" || panel_die "no such path: ${1:-$PWD}"
  [ "$settle" -eq 0 ] || wt_settle "$path"
  if reason=$(wt_reap_reason "$path" --fetch); then
    :
  else
    panel_fail "kept $(basename "$path"): $reason" || return 1
  fi
  wt_end_orphans "$path" || return 1

  name="$(basename "$path")"
  # A husk has no worktree for git to remove, and wt_reap_reason has just proved it holds
  # nothing but tool caches and nobody is in it.
  if wt_is_husk "$path"; then
    rm -rf -- "$path" || panel_fail "could not remove $path" || return 1
    printf 'reaped %s (no git, tool caches only)\n' "$name"
    return 0
  fi

  main=$(wt_main_repo "$path") || panel_die "cannot resolve the repo for $path"
  # Captured BEFORE the removal -- afterwards there is no worktree left to ask.
  branch="$(wt_branch_of "$path")"

  # From the MAIN repo, never from inside the directory being removed. git's own dirty check
  # runs again here, which is a second lock on the same door -- deliberately, because
  # wt_reap_reason's snapshot and this moment are not the same instant.
  #
  # Except for submodules: git refuses ANY worktree with an initialised submodule ("working
  # trees containing submodules cannot be moved or removed"), clean or not, so `done` never
  # removed a unity-core-playground worktree and they piled up at 15-20 GB each. wt_dirty_count
  # already counts edits, untracked files and unpushed commits inside submodules, so a tree it
  # calls clean is safe to remove with --force; the count is taken again right before.
  #
  # The policy passed above, so wt_hold's lock comes off here, and a refusal puts it back: the
  # tree is staying. A tree that never had one fails the unlock harmlessly. Another tool's lock
  # stays on even if it appeared after the policy check, so git refuses the removal below.
  local out dirty
  wt_foreign_lock "$path" >/dev/null || git -C "$main" worktree unlock "$path" 2>/dev/null || :
  if ! out=$(git -C "$main" worktree remove "$path" 2>&1); then
    case "$out" in
    *'containing submodules'*)
      dirty=$(wt_dirty_count "$path") && [ "$dirty" -eq 0 ] &&
        out=$(git -C "$main" worktree remove --force "$path" 2>&1) && out=''
      ;;
    esac
    if [ -n "$out" ]; then
      wt_hold "$path"
      panel_fail "git worktree remove refused $path: $out" || return 1
    fi
  fi

  # Take the branch with it: every cut starts a new one (wt_branch_name), so a branch reap
  # leaves behind is never used again.
  #
  # `-d`, never `-D`. git's own safe-delete refuses a branch that is not merged into HEAD or
  # its upstream -- which is very nearly reap's own "landed" rule, enforced independently by
  # git. If it refuses, the branch stays and we say so; there is no forcing here either.
  if [ -n "$branch" ] && [ "$branch" != '(detached)' ]; then
    if git -C "$main" branch -d "$branch" >/dev/null 2>&1; then
      printf 'reaped %s (branch %s deleted)\n' "$name" "$branch"
    else
      printf 'reaped %s (branch %s kept: git will not safely delete it)\n' "$name" "$branch"
    fi
    return 0
  fi

  printf 'reaped %s\n' "$name"
}

# wt_repo_of_name <basename> -- the main repo whose worktrees are named `<repo>-...` with this
# basename, the longest repo name winning (`dotfiles-private-agent-1` is not dotfiles'). A reaped
# tree leaves git nothing to ask, so the name is all there is to go on.
wt_repo_of_name() {
  local main repo best='' len=0
  while IFS= read -r main; do
    [ -n "$main" ] || continue
    repo=$(wt_repo_name "$main")
    case "$1" in "$repo"-?*) [ "${#repo}" -le "$len" ] || { best="$main" len=${#repo}; } ;; esac
  done < <(wt_scan_repos)
  [ -n "$best" ] && printf '%s\n' "$best"
}

# cmd_revive <path> [--branch <b>] -- put a reaped worktree back at <path>, for a conversation
# that has to resume there: `claude --resume` finds a session by the directory it ran in, and a
# session that closed over its own ask had its clean tree reaped by wind-down (agent-ask reopen).
# On <b> when that branch is still here, on its trunk remote or on origin, else on a new branch off the trunk, as
# `new` cuts one; held like any tree `new` makes. Under `new`'s lock, so a cut cannot take the
# slot mid-add. A tree already at <path> on <b> is left as it is; anything else there, or a
# live session under the name, is another session's slot now, and is refused.
cmd_revive() {
  local path='' branch='' name main repo n def base lock remote
  while [ $# -gt 0 ]; do
    case "$1" in
    --branch) branch="${2:-}"; shift 2 || panel_die "--branch needs a value" ;;
    *) path="$1"; shift ;;
    esac
  done
  [ -n "$path" ] || panel_die "usage: wt revive <path> [--branch <b>]"
  case "$path" in
  *.bundle)
    [ -f "$path" ] || panel_die "no such bundle: $path"
    [ -z "$branch" ] || panel_die "--branch does not apply to a bundle: it revives on its own branch"
    wt_revive_bundle "$(realpath "$path")"
    return
    ;;
  esac
  # A conversation started in a subdirectory revives the whole tree.
  case "$path" in "$WT_ROOT"/*/*) path="${path#"$WT_ROOT"/}" && path="$WT_ROOT/${path%%/*}" ;; esac
  name="${path##*/}"
  [ "$branch" != HEAD ] || branch=''
  # A tree still there is kept unless it is on another branch: then `new` re-cut the slot.
  if [ -e "$path" ] || [ -L "$path" ]; then
    wt_is_linked "$path" && { [ -z "$branch" ] || [ "$(wt_branch_of "$path")" = "$branch" ]; } ||
      panel_die "$name is taken: another tree is there now"
    printf 'kept %s\n' "$name"
    return 0
  fi
  [ "${path%/*}" = "$WT_ROOT" ] || panel_die "not a worktree path: $path is not directly under $WT_ROOT"
  ! wt_session_exists "$name" || panel_die "$name is taken: a live session holds the name"
  main=$(wt_repo_of_name "$name") || panel_die "no repo cuts worktrees named like $name"
  repo=$(wt_repo_name "$main")
  lock="$WT_LOCK_DIR/new-$repo.lock"
  wt_lock "$lock" || panel_die "already preparing a worktree for $repo"
  # shellcheck disable=SC2064 # expand $lock now: it is local, and gone by the time EXIT fires
  trap "rm -f $(printf '%q' "$lock")" EXIT
  remote=$(wt_trunk_remote "$main")
  git -C "$main" fetch "$remote" --quiet || panel_warn "fetch failed; reviving off the local refs"
  # A registration that outlived its directory (`rm -rf` past wt_hold) would make git refuse the
  # add: wt's own hold comes off and prune drops it. Another tool's lock stays, and the add fails.
  local held
  held=$(git -C "$main" worktree list --porcelain 2>/dev/null | awk -v w="worktree $path" \
    '$0 == w { f = 1; next } /^worktree / { f = 0 } f && /^locked/ { sub(/^locked ?/, ""); print; exit }')
  [[ "$held" != "${WT_HOLD_REASON%%:*}:"* ]] || git -C "$main" worktree unlock "$path" 2>/dev/null || :
  git -C "$main" worktree prune 2>/dev/null || :
  def=$(wt_default_branch "$main") || panel_die "cannot resolve the default branch of $main"
  [ "$branch" != "$def" ] || branch=''
  mkdir -p "$WT_ROOT" || panel_die "cannot create $WT_ROOT"
  if [ -n "$branch" ] && git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$main" worktree add --quiet "$path" "$branch" >&2 || panel_die "git worktree add failed: $path"
  elif [ -n "$branch" ] && git -C "$main" show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
    git -C "$main" worktree add --quiet "$path" -b "$branch" "$remote/$branch" >&2 || panel_die "git worktree add failed: $path"
  elif [ -n "$branch" ] && git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$main" worktree add --quiet "$path" -b "$branch" "origin/$branch" >&2 || panel_die "git worktree add failed: $path"
  else
    base=$(wt_base_ref "$main" "$def") || panel_die "no $def in $main to branch from"
    n="${name#"$repo"-}"
    branch=$(wt_branch_name "$main" "${n#agent-}")
    git -C "$main" worktree add --quiet "$path" -b "$branch" "$base" >&2 || panel_die "git worktree add failed: $path"
  fi
  wt_heal_submodule_urls "$path"
  wt_hold "$path"
  printf 'revived %s on %s\n' "$name" "$branch"
}

# The one ref a bundle carries, in the main repo only while one is written or read back:
# branch/<name> (or detached) at the archive commit, whose tree is the tree's files and whose
# parent is its HEAD. That commit is on no remote, so `--not --remotes` never drops the ref, even
# for a tree whose only work is uncommitted on a pushed HEAD.
WT_ARCHIVE_REFS=refs/wt-archive
# Archive and revive both write the namespace, so both take this lock.
wt_archive_lock() { printf '%s/archive-%s.lock' "$WT_LOCK_DIR" "$1"; }
wt_archive_refs_clear() {
  git -C "$1" for-each-ref --format='delete %(refname)' "$WT_ARCHIVE_REFS/" | git -C "$1" update-ref --stdin
}

# cmd_archive <path> -- save a held tree's work to a verified bundle, then remove the tree: the
# end of a tree nobody is in whose work exists nowhere else (README "Worktree states", held).
# Uncommitted changes, untracked files included and ignored ones (Library/, builds, .env) not,
# go into the archive commit through a temporary index, so the tree's own index is not touched.
# The bundle holds that commit and its history minus what any remote has, at
# $WT_ARCHIVE_DIR/<repo>/<name>@<UTC stamp>.bundle; `wt revive <bundle>` puts it back. The tree
# goes only once `git bundle verify` passes. rc 1 when the policy keeps the tree (landed,
# claimed, a submodule holds work, a nested repo is no submodule), 2 when its state cannot be read or the bundle could not be
# written or verified.
cmd_archive() {
  local path name work rc occ main repo out sub lock
  [ ! -L "${1:?usage: wt archive <path>}" ] || panel_die "not a worktree: $1 is a symlink"
  path="$(realpath "$1" 2>/dev/null)" || panel_die "no such path: $1"
  name=${path##*/}
  work=$(wt_work_reason_fetched "$path")
  case $? in
  0) panel_fail "kept $name: its work has landed, so wt reap removes it"; return 1 ;;
  1) ;;
  *) panel_fail "kept $name: $work"; return 2 ;;
  esac
  occ=$(wt_occupied_reason "$path") || { panel_fail "kept $name: $occ"; return 1; }
  ! out=$(wt_submodule_worktrees "$path") || { panel_fail "kept $name: a submodule worktree lives off it: $out"; return 1; }
  # A bundle of the superproject holds none of a submodule's own commits or edits.
  while IFS=$'\t' read -r _ sub; do
    [ -e "$path/$sub/.git" ] || continue
    [ -z "$(git -C "$path/$sub" status --porcelain 2>/dev/null)" ] && wt_submodule_pushed "$path/$sub" ||
      { panel_fail "kept $name: submodule $sub holds work its bundle would not save"; return 1; }
  done < <(wt_submodule_list "$path")

  main=$(wt_main_repo "$path") || { panel_fail "kept $name: cannot resolve its repo"; return 2; }
  repo=$(wt_repo_name "$main")
  lock=$(wt_archive_lock "$repo")
  wt_lock "$lock" || { panel_fail "kept $name: another archive or revive of $repo is running"; return 2; }
  wt_archive_refs_clear "$main"
  wt_archive_tree "$path" "$main" "$repo"
  rc=$?
  wt_archive_refs_clear "$main"
  rm -f "$lock"
  return "$rc"
}

# wt_unsaved_gitlinks <path> <tree> -- each gitlink path in <tree> that <path>'s .gitmodules does
# not name; cmd_archive has checked each named one clean and pushed. quotePath off keeps a
# non-ASCII path raw, as .gitmodules has it; a path git still quotes (a tab, a quote) never
# matches, so it is refused, never passed.
wt_unsaved_gitlinks() {
  local ls
  ls=$(git -C "$1" -c core.quotePath=false ls-tree -r "$2") || return 1
  # The leading blank line keeps the first file non-empty, so NR == FNR never spills into the second.
  awk -F'\t' 'NR == FNR { ok[$0] = 1; next } substr($1, 1, 7) == "160000 " && !($2 in ok) { print $2 }' \
    <(echo; wt_submodule_list "$1" | cut -f2) <(printf '%s\n' "$ls")
}

# wt_archive_tree <path> <main> <repo> -- cmd_archive's bundle-verify-remove, under its lock.
wt_archive_tree() {
  local path="$1" main="$2" repo="$3" name branch head ref tree idx snap dir file out rc
  name=${path##*/}
  branch=$(wt_branch_of "$path")
  head=$(git -C "$path" rev-parse HEAD) || { panel_fail "kept $name: no HEAD"; return 2; }
  if [ -n "$branch" ]; then ref="$WT_ARCHIVE_REFS/branch/$branch"; else ref="$WT_ARCHIVE_REFS/detached"; fi
  idx=$(mktemp) || return 2
  # A copy of the tree's own index keeps its stat cache, so add -A hashes only what changed (a
  # Unity tree is 15-20 GB); a tree with no index starts from HEAD.
  if { cp "$(git -C "$path" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null ||
    GIT_INDEX_FILE=$idx git -C "$path" read-tree HEAD; } && out=$(GIT_INDEX_FILE=$idx git -C "$path" add -A 2>&1) &&
    tree=$(GIT_INDEX_FILE=$idx git -C "$path" write-tree); then
    rm -f "$idx"
  else
    rm -f "$idx"
    # A nested repo with no commit fails add -A ("does not have a commit checked out"); name it.
    out=$(grep -m1 -e '^error:' -e '^fatal:' <<<"$out")
    panel_fail "kept $name: could not snapshot its uncommitted work${out:+: $out}"
    return 2
  fi
  # add -A stores a nested repo that is no submodule as a bare gitlink, its files and history
  # left out, and the forced remove below would delete them (ar-3313).
  out=$(wt_unsaved_gitlinks "$path" "$tree") || { panel_fail "kept $name: cannot list the repos nested in it"; return 2; }
  [ -z "$out" ] || {
    panel_fail "kept $name: nested git repo ${out//$'\n'/, } is no submodule, so its bundle would not save it; push and remove it, or make it a submodule"
    return 1
  }
  # Made even when the files match HEAD: an empty commit still names HEAD as its parent.
  snap=$(git -C "$path" commit-tree "$tree" -p "$head" -m "wt archive: $name, uncommitted work included") &&
    git -C "$main" update-ref "$ref" "$snap" ||
    { panel_fail "kept $name: could not commit its uncommitted work"; return 2; }

  dir="${WT_ARCHIVE_DIR:-$HOME/.agent/archive/worktrees}"
  mkdir -p "$dir/$repo" && chmod 700 "$dir" || { panel_fail "kept $name: cannot create $dir/$repo"; return 2; }
  file="$dir/$repo/$name@$(date -u +%Y%m%dT%H%M%SZ).bundle"
  out=$(git -C "$main" bundle create "$file" "$ref" --not --remotes 2>&1) &&
    out=$(git -C "$main" bundle verify "$file" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$file"
    panel_fail "kept $name: its bundle did not verify: ${out##*$'\n'}"
    return 2
  fi

  # The bundle holds the work, so the removal is forced past the edits it saved; another tool's
  # lock was refused above, and wt's own hold comes off here.
  git -C "$main" worktree unlock "$path" 2>/dev/null || :
  out=$(git -C "$main" worktree remove --force "$path" 2>&1) ||
    { wt_hold "$path"; panel_fail "kept $name (bundle kept at $file): git worktree remove refused: $out"; return 2; }
  [ -z "$branch" ] || git -C "$main" branch -D "$branch" >/dev/null 2>&1 || :
  printf 'archived %s to %s\n' "$name" "$file"
}

# cmd_bundle_state <file.bundle> -- whether the commits an archive bundle holds have landed, read
# from the repo the bundle was cut from, so the runner that prunes old bundles never deletes the
# only copy of unlanded work (ar-4470). Landed: the tree's HEAD at archive time is on the trunk,
# on a remote branch, or is the head of a merged PR (a squash merge leaves the commits on no remote).
# Prints `landed`, `unlanded<TAB><commits><TAB><branch|detached>` or `unknown<TAB><why>`; rc 0, 1, 2.
# Uncommitted work in the bundle is not counted: only unlanded commits are the trap's subject.
cmd_bundle_state() {
  local file="${1:?usage: wt bundle-state <file.bundle>}" name main repo heads ref branch='' head def base n what lock rc=0
  [ -f "$file" ] || { printf 'unknown\tno such bundle\n'; return 2; }
  name=${file##*/}
  name=${name%@*}
  main=$(wt_repo_of_name "$name") || { printf 'unknown\tno repo cuts worktrees named like %s\n' "$name"; return 2; }
  repo=$(wt_repo_name "$main")
  git -C "$main" bundle verify -q "$file" >/dev/null 2>&1 || { printf 'unknown\tthe bundle does not verify against %s\n' "$main"; return 2; }
  heads=$(git -C "$main" bundle list-heads "$file") || { printf 'unknown\tcannot read the bundle\n'; return 2; }
  ref=$(awk -v p="$WT_ARCHIVE_REFS/" '$2 ~ "^" p "(branch/|detached$)" { print $2; exit }' <<<"$heads")
  [ -n "$ref" ] || { printf 'unknown\tnot a wt archive\n'; return 2; }
  case "$ref" in "$WT_ARCHIVE_REFS"/branch/*) branch=${ref#"$WT_ARCHIVE_REFS"/branch/} ;; esac
  lock=$(wt_archive_lock "$repo")
  wt_lock "$lock" || { printf 'unknown\tan archive or revive of %s is running\n' "$repo"; return 2; }
  wt_archive_refs_clear "$main"
  if git -C "$main" fetch -q "$file" "+$ref:$ref" 2>/dev/null &&
    head=$(git -C "$main" rev-parse --verify "$ref^" 2>/dev/null); then
    def=$(wt_default_branch "$main") && base=$(wt_base_ref "$main" "$def") || base=''
    n=$(git -C "$main" rev-list --count "$head" --not --remotes 2>/dev/null) || n=''
    if [ -z "$n" ]; then
      printf 'unknown\tcannot count its commits\n'
      rc=2
    else
      # The archive commit sits on HEAD with the uncommitted files in its tree: that work is on no
      # remote whatever HEAD's state, so it alone keeps the bundle.
      what=''
      if [ "$n" -gt 0 ] && ! { [ -n "$base" ] && git -C "$main" merge-base --is-ancestor "$head" "$base"; } &&
        ! { [ -n "$branch" ] && wt_pr_merged_at "$main" "$branch" "$head"; }; then
        what="$n commits"
      fi
      git -C "$main" diff --quiet "$head" "$ref" 2>/dev/null || what="${what:+$what and }uncommitted work"
      if [ -z "$what" ]; then
        printf 'landed\n'
      else
        printf 'unlanded\t%s\t%s\n' "$what" "${branch:-detached}"
        rc=1
      fi
    fi
  else
    printf 'unknown\tcannot read the archive commit\n'
    rc=2
  fi
  wt_archive_refs_clear "$main"
  rm -f "$lock"
  return "$rc"
}

# wt_revive_bundle <bundle> -- put an archived tree back at $WT_ROOT/<name> from the bundle
# `wt archive` wrote: its branch (or detached HEAD) at the archived commit, and its uncommitted
# work back in the files, uncommitted again. The bundle stays, its mtime reset so the runner's
# retention counts from this revive.
wt_revive_bundle() {
  local file="$1" name path main repo heads ref branch='' snap base lock alock
  name=${file##*/}
  name=${name%@*}
  path="$WT_ROOT/$name"
  { [ ! -e "$path" ] && [ ! -L "$path" ]; } || panel_die "$name is taken: another tree is there now"
  ! wt_session_exists "$name" || panel_die "$name is taken: a live session holds the name"
  main=$(wt_repo_of_name "$name") || panel_die "no repo cuts worktrees named like $name"
  repo=$(wt_repo_name "$main")
  git -C "$main" bundle verify -q "$file" >/dev/null 2>&1 || panel_die "$file does not verify against $main"
  heads=$(git -C "$main" bundle list-heads "$file") || panel_die "cannot read $file"
  ref=$(awk -v p="$WT_ARCHIVE_REFS/" '$2 ~ "^" p "(branch/|detached$)" { print $2; exit }' <<<"$heads")
  [ -n "$ref" ] || panel_die "$file is not a wt archive"
  case "$ref" in "$WT_ARCHIVE_REFS"/branch/*) branch=${ref#"$WT_ARCHIVE_REFS"/branch/} ;; esac
  lock="$WT_LOCK_DIR/new-$repo.lock"
  alock=$(wt_archive_lock "$repo")
  wt_lock "$lock" || panel_die "already preparing a worktree for $repo"
  wt_lock "$alock" || { rm -f "$lock"; panel_die "an archive or revive of $repo is running"; }
  # shellcheck disable=SC2064 # expand now: these are local, and gone by the time EXIT fires
  trap "wt_archive_refs_clear $(printf '%q' "$main"); rm -f $(printf '%q %q' "$lock" "$alock")" EXIT
  wt_archive_refs_clear "$main"
  git -C "$main" fetch -q "$file" "+$ref:$ref" || panel_die "cannot fetch from $file"
  snap=$(git -C "$main" rev-parse --verify "$ref^{commit}") && base=$(git -C "$main" rev-parse --verify "$snap^") ||
    panel_die "$file holds no archive commit"
  mkdir -p "$WT_ROOT" || panel_die "cannot create $WT_ROOT"
  if [ -z "$branch" ]; then
    git -C "$main" worktree add --quiet --detach "$path" "$base" >&2 || panel_die "git worktree add failed: $path"
  elif git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    [ "$(git -C "$main" rev-parse "refs/heads/$branch")" = "$base" ] ||
      panel_die "branch $branch exists here at another commit; revive it by hand from $file"
    git -C "$main" worktree add --quiet "$path" "$branch" >&2 || panel_die "git worktree add failed: $path"
  else
    git -C "$main" worktree add --quiet -b "$branch" "$path" "$base" >&2 || panel_die "git worktree add failed: $path"
  fi
  git -C "$path" restore --source="$snap" --worktree -- . || panel_warn "could not put back the uncommitted work; it is commit $snap"
  touch -- "$file"
  wt_heal_submodule_urls "$path"
  wt_hold "$path"
  printf 'revived %s from %s on %s\n' "$name" "$file" "${branch:-a detached HEAD}"
}

# wt_other_claude <session> -- print "<window index> <pane id>" for each Claude agent in <session>
# other than the pane `done` was run from ($TMUX_PANE, on the caller's own server), nothing when
# there is none; rc 2 when agent-panel cannot say. `done` kills the whole session by name, so a
# second window running claude dies with it. agent-panel finds an agent by its session file in
# the pane's process tree, which holds where pane_current_command shows a version string, `node`
# or the wrapper; a read it could not finish is refused, not read as "no agent".
wt_other_claude() {
  local srv rows me=''
  srv=$(wt_session_server "$1") || return 0
  [ -z "${TMUX_PANE:-}" ] || me="$(wt_current_server)/$TMUX_PANE"
  rows=$(agent-panel list --json 2>/dev/null) || return 2
  jq -r --arg s "$srv" --arg t "$1" --arg me "$me" \
    'select((.harness // "claude") == "claude" and .server == $s and .tmux_session == $t and .pane != $me) | "\(.target | split(":")[-1]) \(.pane | split("/")[-1])"' <<<"$rows"
}

# wt_done_arm <path> <name> -- arm the wind-down teardown for the Claude session `done` was
# run from, when that is the session being cleaned up: a Claude session (its id is in the
# env) whose pane is in <name>'s session, at <path>. Anything else (the keybinding, a plain
# shell, `done <other>`) has no Stop hook to wait for and takes the timed kill below.
wt_done_arm() {
  local sess cwd top
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 1
  # arm records the worktree to reap only under WT_ROOT; without it the kill would run and no reap.
  case "$1" in "$WT_ROOT"/*) ;; *) return 1 ;; esac
  sess="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)"
  cwd="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null)"
  [ "$sess" = "$2" ] && [ -n "$cwd" ] || return 1
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && [ "$top" = "$1" ] || return 1
  "${SELF%/*}/wind-down.sh" arm --session >/dev/null
}

# done [<name|path>] -- the whole cleanup, from INSIDE the session it is cleaning up.
#
# You cannot do this by hand, and that is the entire reason this verb exists: `tmux
# kill-session` takes your own shell with it, so any `wt reap` you chained after it never
# runs. The work has to be handed to something that outlives you, and the tmux SERVER is
# right there -- `run-shell -b` is a persistent daemon's job queue. wind-down has done it
# this way since the macOS nohup bug; this is the same trick with a name.
#
# The safety checks happen HERE, before anything is killed, because afterwards there is no
# terminal left to print a refusal to. A worktree holding real work must be refused while
# you can still read why.
cmd_done() {
  local target="${1:-$PWD}" path name reason other

  case "$target" in
  */*) path="$(realpath "$target" 2>/dev/null)" ;;
  *) path="$(realpath "$WT_ROOT/$target" 2>/dev/null)" ;; # a bare name means a worktree
  esac
  [ -n "$path" ] && [ -d "$path" ] || panel_die "no such worktree: $target"

  # Climb to the worktree ROOT. The keybinding passes #{pane_current_path}, which is wherever
  # you happened to cd to -- and from <worktree>/tests, basename gives "tests", so the kill
  # would miss and `git worktree remove` would simply error. wind-down learned this the same
  # way; --show-toplevel is the answer in both.
  path="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" ||
    panel_die "not inside a git worktree: $target"
  name="$(basename "$path")"

  # Ask about the WORK, not the session -- the session is the thing we are about to kill, so
  # wt_reap_reason would refuse every time by design.
  reason=$(wt_work_reason_fetched "$path") || panel_die "kept $name: $reason"

  # The kill below is by session name, and a session can hold more than the window `done` was
  # run from: a second window running claude would die with it, mid-turn. Refused here, while
  # the reason can still be read; close this window alone (wind-down, no --session) and run
  # `done` from the last one.
  other=$(wt_other_claude "$name") || panel_die "kept $name: agent-panel could not say whether another window runs claude"
  other=${other%%$'\n'*}
  [ -z "$other" ] || panel_die "kept $name: window ${other% *} (pane ${other#* }) still runs claude; close only this window, then run done from the last one"

  if ! panel_in_tmux && ! wt_session_exists "$name"; then
    # Nothing to defer around: no session to kill and no shell to lose.
    cmd_reap "$path"
    return
  fi

  # Run from a Claude session in its own worktree session, the kill is the Stop hook's, not
  # a timer's: a `sleep 1` kill lands mid-turn, before the session's Stop hooks (register,
  # plan sync, spend, the wind-down fire) have run. Arming the wind-down sentinel hands the
  # kill and the reap to the Stop pipeline, last in line, and `fire` runs `reap --after-kill`.
  if wt_done_arm "$path" "$name"; then
    printf 'done: armed %s; its session closes at the next clean Stop, then its worktree is reaped unless something still holds it (log: %s)\n' \
      "$name" "$HOME/.agent/spin-down/fire.log"
    return
  fi

  local me logf
  me="$(printf '%q' "$SELF")"
  logf="$WT_LOG"
  mkdir -p "$(dirname "$logf")" 2>/dev/null

  # kill THEN reap, in one chain on the server. The deferred reap re-runs the FULL policy
  # including the live-session check -- which passes honestly by then, because the session it
  # would have objected to is the one just killed. Nothing is waived anywhere.
  #
  # `-c /` is load-bearing. A run-shell job starts in the cwd of the client that asked for it,
  # which is this shell, inside the tree: the chain and the reap it starts then held the tree
  # themselves, wt_process_inside saw them, and every `done` since #652 was kept.
  #
  # The whole chain writes to $logf and exits 0. A refused reap exits 1, and tmux shows any
  # run-shell output or non-zero status in the active pane, even with -b: the refusal reason
  # is in done.log already, so nothing else may reach the pane.
  tmux run-shell -b -c / "{ sleep 1; $(printf '%q' "${SELF%/*}/close.sh") session '$name'; $me reap --after-kill '$path'; } >> '$logf' 2>&1; true" 2>/dev/null ||
    panel_die "could not schedule the teardown on the tmux server"

  printf 'done: killing %s, then reaping its worktree unless something still holds it (log: %s)\n' "$name" "$logf"
}

# wt_prune_branches <main> <dry> -- delete the slot branches (agent-N, agent-N-<stamp>,
# worktree-agent-*) that
# are merged into the trunk and checked out in no worktree, which `reap` leaves when `-d`
# refused at the time (2026-11-06: 11 in dotfiles, 5 in private). `-d`, never `-D`, so git
# re-checks every one. Prints one line per branch: "deleted <b>" or "kept <b>".
wt_prune_branches() {
  local main="$1" dry="$2" def base b wtpath
  def=$(wt_default_branch "$main") || return 0
  base=$(wt_base_ref "$main" "$def") || return 0
  while IFS=' ' read -r b wtpath; do
    [ -z "$wtpath" ] || continue
    case "$b" in
    agent-[0-9] | agent-[0-9][0-9] | worktree-agent-*) ;;
    agent-[0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*) ;;
    agent-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*) ;;
    *) continue ;;
    esac
    if [ "$dry" -eq 1 ]; then
      printf 'would delete %s\n' "$b"
    elif git -C "$main" branch -d "$b" >/dev/null 2>&1; then
      printf 'deleted %s\n' "$b"
    else
      printf 'kept %s\n' "$b"
    fi
  done < <(git -C "$main" branch --merged "$base" --format='%(refname:short) %(worktreepath)' 2>/dev/null)
}

cmd_gc() {
  local dry=0 tsv=0 repo='' arg
  for arg in "$@"; do
    case "$arg" in
    -n | --dry-run) dry=1 ;;
    --tsv) tsv=1 ;;
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
    # A submodule's worktree goes first: it pins the superproject tree its git dir lives in,
    # so reaping it first frees that tree in this pass rather than the next night's.
    local -a later=()
    for d in "$WT_ROOT"/* "$WT_ROOT"/.[!.]*; do
      [ -d "$d" ] || continue
      # A dot dir is a tool's (.preview, .xdg-agent18) unless it is a linked worktree (.git
      # FILE): judged by wt_work_reason alone, a git-less one with only caches would read as a
      # reapable husk, and one holding a clone would be listed as kept every night.
      case "${d##*/}" in .*) [ -f "$d/.git" ] || continue ;; esac
      if [ -f "$d/.git" ] && [[ "$(<"$d/.git")" == 'gitdir: '*/modules/*/worktrees/* ]]; then
        candidates+=("$d")
      else
        later+=("$d")
      fi
    done
    candidates+=(${later[@]+"${later[@]}"})
  fi

  # An empty candidate list is a RESULT, not a success. Every silent-success bug in this
  # tree has looked exactly like a sweep that ran over nothing and said "done".
  if [ "${#candidates[@]}" -eq 0 ]; then
    # A repo whose every tree is gone can still hold merged slot branches `-d` refused earlier.
    if [ -n "$repo" ]; then
      wt_prune_branches "$repo" "$dry" | sed "s|^|${repo##*/}: |" >&2
    fi
    if [ "$tsv" -eq 1 ]; then
      panel_hint "no worktrees to consider${repo:+ in $repo}" >&2
    else
      panel_hint "no worktrees to consider${repo:+ in $repo}"
    fi
    return 0
  fi

  # One pruned fetch per repo before any tree is judged, so wt_landed's remote-branch rule
  # reads the servers' branches as they are now. Never through a symlink: gc skips those, so it
  # does not fetch in the repo one points into.
  local main
  for path in "${candidates[@]}"; do
    [ ! -L "$path" ] && [ -f "$path/.git" ] && main=$(wt_main_repo "$path" 2>/dev/null) || continue
    wt_fetch_pruned "$main"
  done

  # Each tree gets one state (wt_state) and one action. HELD is the tree nobody will come back
  # for: kept for its work (dirty, unlanded) by an owner that is gone, so gc names it every
  # night rather than keeping it silently (2026-11-02: 30 of 70 playground trees, some for weeks).
  # A symlink, a main checkout or a dir git cannot resolve is NOT-A-WORKTREE and is skipped, so
  # it no longer inflates that count (2026-11-06: 12 of 44 "stranded" were such entries).
  local reaped=0 skipped=0 line state action hue reason ends out states='' w by=''
  local -a mains=()
  for path in "${candidates[@]}"; do
    line=$(wt_state "$path")
    state=${line%%$'\t'*} reason=${line#*$'\t'}
    # The repos whose branches get pruned, taken before the reap (afterwards the tree is gone).
    # Never through a not-a-worktree entry: a symlink or a plain dir with its own clone is not
    # a repo gc manages.
    if [ "$state" != not-a-worktree ] && main=$(wt_main_repo "$path" 2>/dev/null); then
      [[ " ${mains[*]-} " == *" $main "* ]] || mains+=("$main")
    fi
    action=kept hue=$C_INP
    case "$state" in
    landed | husk)
      # gc runs unattended, so a daemon it ends goes in the log by pid.
      ends=$(wt_orphans_inside "$path" | paste -sd, -)
      if [ "$dry" -eq 1 ]; then
        action='would reap' hue=$C_SEL reaped=$((reaped + 1))
      elif out=$(cmd_reap "$path" 2>&1 >/dev/null); then
        action=reaped hue=$C_SEL reaped=$((reaped + 1))
      else
        # Still the state it was judged in; the reason says why the reap refused.
        reason=$out
      fi
      [ -z "$ends" ] || reason+="${reason:+ }(orphan daemon $ends)"
      ;;
    not-a-worktree)
      action=skipped
      skipped=$((skipped + 1))
      ;;
    esac
    states+="$state"$'\n'

    if [ "$tsv" -eq 1 ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$action" "${path##*/}" "$path" "$reason"
    else
      printf '%s%-10s%s  %-28s %-14s %s%s%s\n' "$hue" "$action" "$C_OFF" "${path##*/}" "$state" "$C_DIM" "$reason" "$C_OFF"
    fi
  done

  # After the loop, so a branch whose tree was reaped just now (and kept by `-d`) is seen too.
  local pruned='' got
  for main in ${mains[@]+"${mains[@]}"}; do
    got=$(wt_prune_branches "$main" "$dry" | sed "s|^|${main##*/}: |")
    [ -z "$got" ] || pruned+="${pruned:+$'\n'}$got"
  done

  if [ "$tsv" -eq 1 ]; then
    [ -z "$pruned" ] || printf '%s\n' "$pruned" >&2
    return 0
  fi
  [ -z "$pruned" ] || printf '\nbranches:\n%s\n' "$pruned"
  for w in $WT_GC_STATES; do
    by+="${by:+, }$w $(grep -cx -- "$w" <<<"$states")"
  done
  printf '\n%s of %s reapable, %s kept, %s skipped; %s%s\n' "$reaped" "${#candidates[@]}" \
    "$((${#candidates[@]} - reaped - skipped))" "$skipped" "$by" \
    "$([ "$dry" -eq 1 ] && printf ' (dry run, nothing removed)')"
}

# WT_ORPHAN_KEEP -- what a closed pane's scope may hold that is not left over, matched against
# /proc/<pid>/comm: a tmux server started from a pane (its own panes have their own scopes, so
# ending it would end every session on it) and rbw's agent, which holds the unlocked vault that
# every session reads, and the ssh and gpg agents, which hold keys other sessions use.
WT_ORPHAN_KEEP="${WT_ORPHAN_KEEP:-tmux: server|rbw-agent|ssh-agent|gpg-agent}"
WT_SYSTEMCTL="${WT_SYSTEMCTL:-systemctl}"
WT_TMUX="${WT_TMUX:-tmux}"

# wt_live_panes -- "<server pid> <pane pid>" for each pane of each of this user's tmux servers that
# answers. One call a server, so a server lists every pane or none: one that does not answer lists
# none, and wt_closed_pane_scopes skips its scopes rather than read them as closed.
wt_live_panes() {
  local srv
  while IFS= read -r srv; do
    timeout 5 "$WT_TMUX" -L "$srv" list-panes -a -F '#{pid} #{pane_pid}' 2>/dev/null
  done < <(tmux_servers_all)
}

# wt_closed_pane_scopes -- "<unit> <cgroup>" for each pane scope whose pane is gone. tmux puts each
# pane in a scope described "tmux child pane <pid> launched by process <server pid>", and so does
# `claude-acct scope` for an agent session it moves out of one ("tmux child pane <pid> runs ...
# launched by process <server pid>"); what the pane started stays in it after the pane closes,
# whatever it is: a test run, a build, a browser.
# A scope is closed when its server answered without that pane, or its server has exited; one whose
# server is alive but did not answer is skipped, and so is the scope this process runs in. Scopes are
# listed before panes, so a pane opened in between is live, not closed. No systemctl (macOS): none.
wt_closed_pane_scopes() {
  local proc="${WT_PROC_ROOT:-/proc}" scopes live own unit pane spid cg
  command -v "$WT_SYSTEMCTL" >/dev/null 2>&1 || return 0
  scopes=$("$WT_SYSTEMCTL" --user show --property=Id,Description,ControlGroup "tmux-spawn-*.scope" "agent-*.scope" 2>/dev/null |
    awk -F= '$1 == "Id" { id = $2 } $1 == "ControlGroup" { cg = $2 }
      $1 == "Description" { n = split($2, w, " "); if (w[1] == "tmux" && w[3] == "pane") { pane = w[4]; spid = w[n] } }
      /^$/ { if (pane != "") print id, pane, spid, cg; id = cg = pane = spid = "" }
      END { if (pane != "") print id, pane, spid, cg }')
  live=$(wt_live_panes)
  own=$(sed -n "s/^0:://p" "$proc/$$/cgroup" 2>/dev/null)
  while read -r unit pane spid cg; do
    [ -n "$unit" ] || continue
    [ "$cg" = "$own" ] && continue
    grep -qx "$spid $pane" <<<"$live" && continue
    if ! grep -q "^$spid " <<<"$live"; then
      case "$(cat "$proc/$spid/comm" 2>/dev/null)" in tmux*) continue ;; esac # alive but silent
    fi
    printf '%s %s\n' "$unit" "$cg"
  done <<<"$scopes"
}

# wt_scope_leftovers <cgroup> -- the live pids in a closed pane's scope, but for WT_ORPHAN_KEEP. A
# zombie is already dead, waiting on its parent, so it is not one. Nor is a descendant of a tmux
# server in the scope: a server started from a pane lives in that pane's scope, and so does every
# `run-shell` job it runs, which belongs to the live server, not the closed pane. Why: wind-down's
# `run-shell -b` reap ran in the lab server's scope, and orphan-gc killed it inside `git worktree
# remove`, leaving a registered worktree with no directory that held dispatch FAILED (ar-5133).
wt_scope_leftovers() {
  local proc="${WT_PROC_ROOT:-/proc}" procs="${WT_CGROUP_ROOT:-/sys/fs/cgroup}$1/cgroup.procs" pid comm stat p d servers=' '
  while read -r pid; do
    [ "$(cat "$proc/$pid/comm" 2>/dev/null)" != 'tmux: server' ] || servers+="$pid "
  done 2>/dev/null < "$procs"
  while read -r pid; do
    comm=$(cat "$proc/$pid/comm" 2>/dev/null) stat=$(cat "$proc/$pid/stat" 2>/dev/null)
    [[ "$comm" =~ ^($WT_ORPHAN_KEEP)$ ]] && continue
    [[ "${stat##*) }" == Z* ]] && continue
    if [ "$servers" != ' ' ]; then
      p=$pid d=0
      while [ "${p:-0}" -gt 1 ] && [ "$d" -lt 64 ]; do
        p=$(awk '$1 == "PPid:" { print $2; exit }' "$proc/$p/status" 2>/dev/null) d=$((d + 1))
        [[ "$servers" == *" $p "* ]] && continue 2
      done
    fi
    printf '%s\n' "$pid"
  done 2>/dev/null < "$procs"
}

# wt_scope_keeps <cgroup> -- true when the scope holds a process WT_ORPHAN_KEEP spares, so
# cgroup.kill, which ends every process in it, is off.
wt_scope_keeps() {
  local proc="${WT_PROC_ROOT:-/proc}" pid
  while read -r pid; do
    [[ "$(cat "$proc/$pid/comm" 2>/dev/null)" =~ ^($WT_ORPHAN_KEEP)$ ]] && return 0
  done 2>/dev/null < "${WT_CGROUP_ROOT:-/sys/fs/cgroup}$1/cgroup.procs"
  return 1
}

# WT_KILL_ROUNDS -- how many times a scope with a kept process is read and SIGKILLed by pid: a
# leftover that forks between the read and the kill leaves a child the next round ends.
WT_KILL_ROUNDS="${WT_KILL_ROUNDS:-3}"

# cmd_orphans [-n] -- end what nobody owns any more on this node: a Unity daemon whose editor is
# gone, in any project with ProjectSettings/ (the plugin stops its gamedev-mcp-server only on a
# clean quit, and reap ends one only in a landed tree, ar-228), and whatever a closed tmux pane
# left running, of any kind (wt_closed_pane_scopes; bats runs of ended sessions ran 25 hours,
# ar-3269). Each gets SIGTERM and WT_SETTLE_SECS to exit; a closed pane's leftover that outlives
# it gets SIGKILL. The orphan-gc runner runs this on a cadence: nothing signals the exit of a
# process that is not our child, and a pane can end with its whole server. rc 1 when one outlived
# its last signal, named by pid and project or scope.
cmd_orphans() {
  local dry=0 arg root pids rc=0 n=0
  for arg in "$@"; do
    case "$arg" in
    -n | --dry-run) dry=1 ;;
    *) panel_die "orphans: unknown argument: $arg" ;;
    esac
  done
  while IFS= read -r root; do
    [ -d "$root/ProjectSettings" ] || continue
    wt_editor_open "$root" && continue
    pids=$(wt_orphans_inside "$root" | paste -sd, -)
    [ -n "$pids" ] || continue
    n=$((n + 1))
    if [ "$dry" -eq 1 ]; then
      printf 'would end %s  %s\n' "$pids" "$root"
    elif wt_end_orphans "$root" 2>/dev/null; then
      printf 'ended %s  %s\n' "$pids" "$root"
    else
      printf 'failed %s  %s: outlived SIGTERM\n' "$pids" "$root"
      rc=1
    fi
  # Each dir above a /Library/ in a binary's path is a candidate root; ProjectSettings/ picks the
  # project, so one under a dir named Library is still found.
  done < <(find "${WT_PROC_ROOT:-/proc}"/[0-9]*/exe -maxdepth 0 -lname '*/Library/*' -printf '%l\n' 2>/dev/null |
    awk -F'/Library/' '{ p = $1; print p; for (i = 2; i < NF; i++) { p = p "/Library/" $i; print p } }' | sort -u)
  local unit cg what pid left
  while read -r unit cg; do
    pids=$(wt_scope_leftovers "$cg")
    [ -n "$pids" ] || continue
    n=$((n + 1))
    what=$(for pid in $pids; do cat "${WT_PROC_ROOT:-/proc}/$pid/comm" 2>/dev/null; done | sort | uniq -c |
      awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s%s x%d", sep, $0, c; sep = ", " }')
    if [ "$dry" -eq 1 ]; then
      printf 'would end %s  %s (%s)\n' "$(paste -sd, - <<<"$pids")" "$unit" "$what"
      continue
    fi
    # shellcheck disable=SC2086 # one pid per word
    kill -TERM $pids 2>/dev/null
    # shellcheck disable=SC2086
    wt_await_exit $pids
    left=$(wt_scope_leftovers "$cg")
    if [ -z "$left" ]; then
      printf 'ended %s  %s (%s)\n' "$(paste -sd, - <<<"$pids")" "$unit" "$what"
      continue
    fi
    # What outlives SIGTERM gets SIGKILL: bats sandboxes that respawned each other ran on past every
    # SIGTERM pass (ar-4050). A scope that holds nothing kept takes cgroup.kill, which ends all of it
    # at once, forks included; one with a kept process, or a kernel with no cgroup.kill, SIGKILL by
    # pid, read again each round for what forked between the read and the kill.
    if ! wt_scope_keeps "$cg" && { echo 1 > "${WT_CGROUP_ROOT:-/sys/fs/cgroup}$cg/cgroup.kill"; } 2>/dev/null; then
      # shellcheck disable=SC2086
      wt_await_exit $left
      left=$(wt_scope_leftovers "$cg")
    fi
    local round=0
    while [ -n "$left" ] && [ "$round" -lt "$WT_KILL_ROUNDS" ]; do
      # shellcheck disable=SC2086
      kill -KILL $left 2>/dev/null
      # shellcheck disable=SC2086
      wt_await_exit $left
      left=$(wt_scope_leftovers "$cg") round=$((round + 1))
    done
    if [ -z "$left" ]; then
      printf 'ended %s  %s (%s) by SIGKILL\n' "$(paste -sd, - <<<"$pids")" "$unit" "$what"
    else
      printf 'failed %s  %s: outlived SIGKILL\n' "$(paste -sd, - <<<"$left")" "$unit"
      rc=1
    fi
  done < <(wt_closed_pane_scopes)
  [ "$n" -gt 0 ] || panel_hint 'no orphans'
  return "$rc"
}

# ── Picker ───────────────────────────────────────────────────────────────────

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  panel_fzf_table
  panel_fzf_layout

  local me picked
  me="$(printf '%q' "$SELF")"

  picked="$(cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --with-nth=5 \
    --prompt='worktree > ' \
    --header='enter land · ctrl-n new · ctrl-x reap · ctrl-r reload' \
    --bind="ctrl-n:become($me new)" \
    --bind="ctrl-x:execute($me reap {1} || (printf '\n[any key]'; read -r -n1))+reload($me --list)" \
    --bind="ctrl-r:reload($me --list)" \
    "${PANEL_FZF_LAYOUT[@]}" \
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
_prepare)
  shift
  cmd_prepare "$@"
  ;;
done)
  shift
  cmd_done "$@"
  ;;
reap)
  shift
  cmd_reap "$@"
  ;;
revive)
  shift
  cmd_revive "$@"
  ;;
archive)
  shift
  cmd_archive "$@"
  ;;
bundle-state)
  shift
  cmd_bundle_state "$@"
  ;;
gc)
  shift
  cmd_gc "$@"
  ;;
orphans)
  shift
  cmd_orphans "$@"
  ;;
preview)
  shift
  cmd_preview "$@"
  ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
