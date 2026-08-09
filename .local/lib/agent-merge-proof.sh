# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# agent-merge-proof.sh — is this ticket's work actually ON the integration branch?
#
# The companion question to agent-proof.sh. That file asks "did the agent do
# anything"; this one asks "is the thing it claims to have shipped really there".
# Both exist because the cheap answer is a lie that reads as success:
#
#   * `gh pr view --json state,mergedAt` reports the state of a PR OBJECT. A PR
#     can be merged and its content still not be reachable from the branch you
#     integrate on — reverted, force-pushed over, merged to the wrong base.
#   * A tracker's close-on-merge webhook reports that the WEBHOOK fired.
#   * A `STATUS: DONE` sentinel on disk reports what the agent believed.
#
# None of the three consults the git graph, and until this file existed nothing
# in the kb pipeline ever did — `git merge-base --is-ancestor` appeared nowhere.
# We have already been bitten: an agent reported `completed · 16h` after dying
# on a model outage, and the row stayed green because every check agreed with
# the agent instead of with git.
#
# Ported from Kampe/Herdforge `pkg/sync/boarddone.go`, which carries its own
# incident: cards moved to done while the merge had been REFUSED by a gate,
# because the board write was chained behind a pipe whose tail exited 0. Their
# framing is the right one — "marking done is a claim about reality, and nothing
# checked it".
#
# Usage:
#   source "$HOME/.local/lib/agent-merge-proof.sh"
#   proof="$(merge_proof "$repo" "$ref" "$(merge_proof_branch "$repo")" "$sha")"
#   case $? in
#     0) : ;;                       # $proof is a printable, recordable proof
#     1) echo "$proof" >&2; exit 1;; # honest refusal: no evidence
#     *) exit 2;;                    # hard error: a claim was WRONG, or misconfig
#   esac
#
# Exit codes are three-valued on purpose. "No proof yet" is a normal blocked
# outcome a caller can retry; "you handed me a SHA that is not on the branch" is
# a false claim and must never be allowed to degrade into the first case.

# ── ref hygiene ───────────────────────────────────────────────────────────────

# merge_proof_normalize_ref REF — FAC-018 and FAC-18 are the same ticket.
# A zero-padded ref misses the board, and misses the commit-message search too.
merge_proof_normalize_ref() {
  printf '%s' "${1:-}" | sed -E 's/^([A-Za-z]+-)0+([0-9])/\1\2/'
}

# _merge_proof_ere_safe REF — refuse a ref carrying ERE metacharacters.
#
# Fail closed rather than build a pattern that means something other than what
# the caller asked. Real refs are alphanumerics, hyphens and underscores
# (FAC-18, 559, PMP-1204); anything else is either a bug upstream or an attempt
# to make the grep match more than the ticket.
_merge_proof_ere_safe() {
  case "${1:-}" in
    '' ) return 1 ;;
    *[!A-Za-z0-9_-]* ) return 1 ;;
    * ) return 0 ;;
  esac
}

# ── branch resolution ─────────────────────────────────────────────────────────

# merge_proof_branch REPO_DIR — the branch work integrates ON.
#
# NOT hardcoded to main, which is where the Go original can get away with being
# lazy. bnb/platform integrates on `develop` (kb/sprint step 6 pulls develop
# between tickets); this repo integrates on `main`. Getting this wrong is the
# quiet failure mode — proving content is on `main` when the team merges to
# `develop` refuses every true claim.
#
# Order: explicit override -> the remote's own HEAD -> first existing of the
# conventional names. Never guesses silently: echoes nothing and returns 1 if it
# cannot tell, so a caller cannot proceed against an unknown branch.
merge_proof_branch() {
  local repo="${1:?merge_proof_branch: repo dir required}" head b
  if [ -n "${MERGE_PROOF_BRANCH:-}" ]; then printf '%s' "$MERGE_PROOF_BRANCH"; return 0; fi
  head="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head" ]; then printf '%s' "${head#origin/}"; return 0; fi
  for b in develop main master; do
    if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then
      printf '%s' "$b"; return 0
    fi
  done
  return 1
}

# ── the proof itself ──────────────────────────────────────────────────────────

# merge_proof REPO_DIR REF BRANCH [EVIDENCE_SHA]
#
# 0 -> stdout is a human-readable proof, safe to record on a board row.
# 1 -> stdout is an honest refusal. No evidence exists (yet).
# 2 -> stderr says why this is a hard error, not a retryable "not yet".
#
# Order of proof, strongest first:
#   1. an explicit EVIDENCE_SHA that is an ancestor of origin/BRANCH;
#   2. a commit on origin/BRANCH naming REF.
#
# (2) is weaker but necessary: tickets have shipped with zero commits naming
# them, and squash merges put the ref in the PR body rather than the subject.
merge_proof() {
  local repo="${1:?merge_proof: repo dir required}"
  local ref="${2:?merge_proof: ticket ref required}"
  local branch="${3:?merge_proof: integration branch required}"
  local evidence="${4:-}"
  local short hit pat

  ref="$(merge_proof_normalize_ref "$ref")"
  if ! _merge_proof_ere_safe "$ref"; then
    echo "merge_proof: refusing ref '$ref' — not a plain ticket ref" >&2
    return 2
  fi
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "merge_proof: '$repo' is not a git repository" >&2
    return 2
  fi

  # Refresh the remote-tracking ref. An explicit refspec, not a bare
  # `git fetch origin BRANCH`, so the tracking ref is definitely updated rather
  # than only FETCH_HEAD. Offline is tolerated — we then judge against whatever
  # origin/BRANCH we last saw, which can only ever make us MORE conservative
  # (stale = fewer commits = a true claim may be refused, never a false one
  # accepted).
  git -C "$repo" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true

  if ! git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    echo "merge_proof: no origin/$branch in $repo — cannot prove anything" >&2
    return 2
  fi

  if [ -n "$evidence" ]; then
    if ! git -C "$repo" rev-parse --verify --quiet "${evidence}^{commit}" >/dev/null 2>&1; then
      echo "merge_proof: REFUSING — evidence '$evidence' is not a commit in $repo" >&2
      return 2
    fi
    if ! git -C "$repo" merge-base --is-ancestor "$evidence" "origin/$branch" 2>/dev/null; then
      # Hard error, NOT a fall-through to the grep. A caller that names a SHA is
      # making a specific claim; if that claim is false the weaker check finding
      # some other commit would launder a lie into a proof.
      echo "merge_proof: REFUSING — evidence $evidence is not an ancestor of origin/$branch" >&2
      return 2
    fi
    short="$(git -C "$repo" rev-parse --short "$evidence" 2>/dev/null)"
    printf 'evidence commit %s is an ancestor of origin/%s' "$short" "$branch"
    return 0
  fi

  # Both boundaries are explicit because git's POSIX ERE has no \b.
  #
  # Trailing (from the Go): without it FAC-18 is satisfied by a commit naming
  # FAC-180. Leading (ours, NOT in the Go): their refs are always PREFIX-N, but
  # ours can be a bare vikunja id, and a bare `559` with only a trailing
  # boundary is satisfied by `1559`. A ticket proved done by an unrelated
  # ticket's commit is exactly the class of lie this file exists to stop.
  pat="(^|[^0-9A-Za-z_-])${ref}([^0-9]|\$)"
  hit="$(git -C "$repo" log "origin/$branch" -E --grep="$pat" --format='%h %s' -1 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    printf 'origin/%s carries a commit naming %s: %s' "$branch" "$ref" "$hit"
    return 0
  fi

  printf 'no evidence on origin/%s that %s shipped' "$branch" "$ref"
  return 1
}

# ── write read-back ───────────────────────────────────────────────────────────

# merge_proof_readback LABEL CMD... — prove the tracker write actually persisted.
#
# Herdforge's reason, which we have no cause to doubt: "board APIs are known to
# report success on writes that did not persist." Our own vikunja backend is
# worse than that — tb_done swallows the label and bucket writes with `|| true`
# and never checks the `done:true` POST at all, so a 200-with-error-body is
# indistinguishable from success.
#
# CMD must print the ticket's post-write state on stdout. Anything other than
# `done` (case/space insensitive) is a failure, INCLUDING an empty answer: a
# tracker that cannot tell us the state has not confirmed the write.
merge_proof_readback() {
  local label="${1:?merge_proof_readback: label required}"; shift
  [ "$#" -gt 0 ] || { echo "merge_proof_readback: no read-back command given" >&2; return 2; }
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [ "$rc" -ne 0 ]; then
    echo "merge_proof_readback: $label — read-back command failed (rc=$rc); write NOT confirmed" >&2
    return 2
  fi
  if [ "$out" != "done" ]; then
    echo "merge_proof_readback: $label — tracker reports '${out:-<empty>}', not done; write NOT confirmed" >&2
    return 2
  fi
  printf 'read-back confirms %s is done' "$label"
  return 0
}
