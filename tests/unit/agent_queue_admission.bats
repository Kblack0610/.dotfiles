#!/usr/bin/env bats
# Only the board fills the queue: agent-queue's pull_ok and hand_caller decide which adds may go in,
# and every other add files a board row and exits 5. Three things depend on that rule and drift
# from it silently, so this file pins each:
#   (a) every script that calls `agent-queue add` is one the rule admits (--running, an
#       AGENT_QUEUE_PULL its caller sets, the human) or one that handles exit 5. A new caller that
#       does neither reads its add as failed, or as an item that never exists.
#   (b) the conditions in pull_ok and hand_caller are the COND table below, and QUEUE.md's
#       "Admission" "May add" bullet names each of them (QUEUE.md is private: skipped without it).
#   (c) skill-drift's ADMIT check names the conditions it can decide statically.
# Each check takes its files or roots as arguments, so the negative controls run it on a planted copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/private'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  PRIVATE="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}"
  QDOC="$PRIVATE/.config/agentctl/QUEUE.md"
}


# --- (a) callers ----------------------------------------------------------------

# How far below the call its exit-5 handling may sit: the call often spans a few continuation lines.
HELD_SPAN=12
# Exit-5 handling: an rc test, a case arm, or a parse of the `held <slug> -> <board>:<id>` line.
HELD_RE='-eq "?5"?|-eq "?\$AQ_EX_HELD"?|^[[:space:]]*5\)|\^held '

# The callers the code cannot classify by itself. <file>|<fixed string on the call line>|<class>|<proof>|<why>
#   pull   <proof> is <file>:<fixed string>, the caller that runs this one with AGENT_QUEUE_PULL set
#   human  <proof> is a string the call line must not hold: with no --from the add is the human's
KNOWN=(
  'fleet-bench|$BENCH_CANARY_QUEUE_CMD add|pull|fleet-dispatch:AGENT_QUEUE_PULL=dispatch fleet-bench canary queue|dispatch tops the canaries up as its own pull'
  'agent-propose|"agent-queue", "add"|human|--from|run by the human accepting a proposal (hub, agent-propose accept)'
)

# calls <root> -> "<file>\t<line>\t<text>" for each line under <root>/.local/bin that runs an add: the
# command at the start of a line, after $( or |, after env assignments, or as a JSON argv. Prose
# naming it (a die message, a brief) and agent-queue itself are not callers.
calls() {
  local d="$1/.local/bin"
  [ -d "$d" ] || return 0
  grep -rnE '(^[[:space:]]*|\$\(|\|[[:space:]]*|[A-Z_]+=[^[:space:]]+[[:space:]]+)agent-queue add|"agent-queue", *"add"|\$[A-Z_]*QUEUE_CMD add' "$d" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | sed -E 's/^([^:]+):([0-9]+):/\1\t\2\t/' \
    | awk -F'\t' '$1 !~ /\/agent-queue$/'
}

# classify <root> <file> <line> <text> -> the class, or nothing when it has none
classify() {
  local root="$1" f="$2" n="$3" text="$4" e kf ks kc kp base
  base="$(basename "$f")"
  case "$text" in *--running*) echo running; return ;; esac
  [[ "$text" =~ AGENT_QUEUE_PULL=[^[:space:]]+[[:space:]].*agent-queue\ add ]] && { echo pull; return; }
  sed -n "$n,$((n + HELD_SPAN))p" "$f" | grep -qE -- "$HELD_RE" && { echo held; return; }
  for e in "${KNOWN[@]}"; do
    IFS='|' read -r kf ks kc kp _ <<<"$e"
    [ "$kf" = "$base" ] && [[ "$text" == *"$ks"* ]] || continue
    case "$kc" in
      pull) grep -qF -- "${kp#*:}" "$root/.local/bin/${kp%%:*}" 2>/dev/null && echo pull ;;
      human) [[ "$text" != *"$kp"* ]] && echo human ;;
    esac
    return
  done
}

check_callers() { # <root>...
  local root f n text bad=0 seen=0
  for root in "$@"; do
    while IFS=$'\t' read -r f n text; do
      seen=$((seen + 1))
      [ -n "$(classify "$root" "$f" "$n" "$text")" ] && continue
      echo "${f#"$root/"}:$n: an agent-queue add that is neither --running, an AGENT_QUEUE_PULL, the human, nor handles exit 5 (QUEUE.md \"Admission\"); handle 5 or add it to KNOWN"
      bad=1
    done < <(calls "$root")
  done
  [ "$seen" -gt 0 ] || { echo "no agent-queue add callers found under $*"; return 1; }
  return "$bad"
}

@test "every agent-queue add caller is admitted or handles exit 5" {
  run check_callers "$REPO_ROOT"
  assert_success
  if has_private; then
    run calls "$PRIVATE"
    [ -z "$output" ] || { run check_callers "$PRIVATE"; assert_success; }
  else
    echo "# private: $PRIVATE is not a checkout, its callers unchecked" >&3
  fi
}

@test "every KNOWN entry still names a call line" {
  local e kf ks
  for e in "${KNOWN[@]}"; do
    IFS='|' read -r kf ks _ <<<"$e"
    calls "$REPO_ROOT" | awk -F'\t' -v f="$kf" '$1 ~ ("/" f "$")' | grep -qF -- "$ks" || { echo "KNOWN $kf: no call holds $ks"; return 1; }
  done
}

@test "negative control: a planted caller that ignores exit 5 fails, one that handles it passes" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/.local/bin"
  printf '%s\n' '#!/bin/sh' 'out=$(agent-queue add --project p --from auto:x "t")' 'echo "$out"' > "$root/.local/bin/filer"
  run check_callers "$root"
  assert_failure
  assert_output --partial '.local/bin/filer:2: an agent-queue add'
  printf '%s\n' '#!/bin/sh' 'out=$(agent-queue add --project p --from auto:x "t")' 'rc=$?; [ "$rc" -eq 5 ] && echo held' > "$root/.local/bin/filer"
  run check_callers "$root"
  assert_success
}

@test "negative control: a pull caller whose AGENT_QUEUE_PULL is gone fails" {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/.local/bin"
  cp "$REPO_ROOT/.local/bin/fleet-bench" "$root/.local/bin/"
  sed 's/AGENT_QUEUE_PULL=dispatch fleet-bench canary queue/fleet-bench canary queue/' "$REPO_ROOT/.local/bin/fleet-dispatch" > "$root/.local/bin/fleet-dispatch"
  run check_callers "$root"
  assert_failure
  assert_output --partial '.local/bin/fleet-bench:'
}

# --- (b) and (c): pull_ok and hand_caller against QUEUE.md and ADMIT ------------------

# <function>;<condition as the code writes it>;<phrase QUEUE.md's "May add" names it by, - none>;<string skill-drift's check_admit decides it by, - when ADMIT cannot>
# `;` separates because a case arm (`in hand | resume)`) holds a `|`.
COND=(
  'pull_ok;[ -n "$1" ];`--running`;--running'
  'pull_ok;[ -n "${AGENT_QUEUE_PULL:-}" ];`AGENT_QUEUE_PULL=dispatch`;AGENT_QUEUE_PULL='
  'pull_ok;[ -n "${AGENT_QUEUE_PULL:-}" ];`AGENT_QUEUE_PULL=hand`;AGENT_QUEUE_PULL='
  'hand_caller;[ -z "$2" ];no `--from`;--from'
  'hand_caller;[ "$1" = human ];other than `human`;"human"'
  'hand_caller;[ -n "${AGENT_QUEUE_ITEM:-}" ];no `AGENT_QUEUE_ITEM`;-'
  'hand_caller;[ -n "$f" ];-;-'
  'hand_caller;in hand | resume);`origin` is `hand` or `resume`;-'
)

# fn_body <file> <function> -> its lines, from `name() {` to the first unindented `}`, or the one line
fn_body() {
  awk -v f="$2" 'index($0, f "() {") == 1 {on = 1} on {print} on && (/^}/ || /; }$/) {exit}' "$1"
}

# conds <agent-queue> -> "<function>;<condition>" for each test and case arm in pull_ok and hand_caller
conds() {
  local fn
  for fn in pull_ok hand_caller; do
    fn_body "$1" "$fn" | grep -vE '^[[:space:]]*#' | grep -oE '\[ [^]]+ \]|in [a-z |]+\)' | sed "s/^/$fn;/"
  done | sort -u
}

check_conds() { # <agent-queue>
  diff <(printf '%s\n' "${COND[@]}" | cut -d';' -f1-2 | sort -u) <(conds "$1") ||
    { echo "COND (<) and pull_ok/hand_caller (>) differ: update QUEUE.md \"Admission\" and skill-drift's check_admit, then COND"; return 1; }
}

# may_add <QUEUE.md> -> the "May add" bullet of its ## Admission section
may_add() { awk '/^## /{on = ($0 == "## Admission")} on && /^- May add:/' "$1"; }

check_doc() { # <QUEUE.md>
  local e fn c p bullet bad=0
  bullet="$(may_add "$1")"
  [ -n "$bullet" ] || { echo "no \"- May add:\" bullet under ## Admission in $1"; return 1; }
  for e in "${COND[@]}"; do
    IFS=';' read -r fn c p _ <<<"$e"
    [ "$p" = - ] || [[ "$bullet" == *"$p"* ]] || { echo "May add does not name $p ($fn: $c)"; bad=1; }
  done
  return "$bad"
}

check_admit_names() { # <skill-drift>
  local e fn c t body bad=0
  body="$(fn_body "$1" check_admit)"
  [ -n "$body" ] || { echo "$1 has no check_admit"; return 1; }
  for e in "${COND[@]}"; do
    IFS=';' read -r fn c _ t <<<"$e"
    [ "$t" = - ] || [[ "$body" == *"$t"* ]] || { echo "check_admit does not decide by $t ($fn: $c)"; bad=1; }
  done
  return "$bad"
}

@test "pull_ok and hand_caller test exactly the COND conditions" {
  run check_conds "$AQ"
  assert_success
}

@test "QUEUE.md Admission's May add names every condition" {
  has_private || skip "private: $PRIVATE is not a checkout, QUEUE.md unchecked"
  run check_doc "$QDOC"
  assert_success
}

@test "skill-drift's ADMIT decides by every condition it can" {
  run check_admit_names "$DRIFT"
  assert_success
}

@test "negative control: a new condition in pull_ok fails the pin" {
  sed 's/^pull_ok() { \[ -n "\$1" \] ||/pull_ok() { [ -n "$1" ] || [ "$2" = canary ] ||/' "$AQ" > "$BATS_TEST_TMPDIR/aq"
  run check_conds "$BATS_TEST_TMPDIR/aq"
  assert_failure
  assert_output --partial '> pull_ok;[ "$2" = canary ]'
}

@test "negative control: a May add bullet that drops a condition fails" {
  printf '%s\n' '## Admission' '' '- May add: dispatch'"'"'s pull (`AGENT_QUEUE_PULL=dispatch`), `AGENT_QUEUE_PULL=hand`, `--running`, and the human: no `--from` other than `human` (no `AGENT_QUEUE_ITEM`).' '## Next' > "$BATS_TEST_TMPDIR/q.md"
  run check_doc "$BATS_TEST_TMPDIR/q.md"
  assert_failure
  assert_output 'May add does not name `origin` is `hand` or `resume` (hand_caller: in hand | resume))'
}

@test "negative control: an ADMIT that stops reading --running fails" {
  sed '/^check_admit() {/,/^}/ s/--running/--RUN/g; /^check_admit() {/,/^}/ s/AGENT_QUEUE_PULL=/AQ_PULL=/g' "$DRIFT" > "$BATS_TEST_TMPDIR/drift"
  run check_admit_names "$BATS_TEST_TMPDIR/drift"
  assert_failure
  assert_output --partial 'check_admit does not decide by AGENT_QUEUE_PULL='
}
