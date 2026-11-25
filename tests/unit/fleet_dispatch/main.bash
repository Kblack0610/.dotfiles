# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch.bats and fleet_dispatch_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

# --- candidates --------------------------------------------------------------------------

# --- row gates (queue-held-to-board, ar-3121): a row waits on the board, not in the queue ----------

# gate_rbw -- rbw lists what rbw.list holds (nothing until a test writes it); each call is logged.
gate_rbw() {
  stub rbw-fake 'echo "rbw $*" >> "$NOTES_FIXTURE/rbw.calls"; case "$1" in unlocked) ;; list) cat "$NOTES_FIXTURE/rbw.list" 2>/dev/null || true ;; *) exit 9 ;; esac'
  export AGENT_QUEUE_RBW=rbw-fake
}
# gate_ask <id> <status> [answered_by] -- an ask with no options, as agent-ask files it.
gate_ask() {
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: %s\nstatus: %s\nanswer: go\nanswered_by: %s\nquestion: q?\n' "$1" "$2" "${3:-}" > "$HOME/.agent/asks/game/$1.md"
}
# item_tags <slug> -> the queue item's tags: line
item_tags() { sed -n 's/^tags: //p' "$AGENT_QUEUE_DIR"/*/*-"$1".md; }

# skipv <key> <rule> [reason] [clear] -- a skip verdict on a game agent row, under the current policy
skipv() {
  verdict game agent "$1" skip
  jq -c --arg k "$1" --arg r "$2" --arg why "${3:-r}" --argjson c "${4:-true}" \
    'if .key == $k then .rule = $r | .reason = $why | .clear = $c else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

# exits_fixture -- one game agent row per exit, a dispatch, and the open row a waits skip names
exits_fixture() {
  printf '%s\n' '- (design) a product call' '- (needs-person) a device run' '- (waits) waits on another' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  local k
  for k in gx-1 gx-2 gx-4 gx-5 gx-6 gx-7 gx-9; do row game agent "$k" "- [ ] row $k $T <!-- id:$k -->"; done
  row game agent gx-3 "- [ ] row gx-3 #low $T <!-- id:gx-3 -->"
  : > "$NOTES_FIXTURE/board.rows"
  for k in gx-1 gx-2 gx-3 gx-4 gx-5 gx-6 gx-7 gx-9; do board_row game agent "$k" '[]' '[]'; done
  skipv gx-1 unclear r false; skipv gx-2 design; skipv gx-3 needs-person
  skipv gx-4 waits 'waits on gx-9 landing'; skipv gx-5 waits 'after feat/x lands'
  skipv gx-6 waits 'after kblack0610/dotfiles#3021 merges'
  verdict game agent gx-7 dispatch
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
}

# offkind_fixture -- agent rows of kinds kinds.json turns off (decide #high, design #low), an epic, a decide
# parent an open row names in #of/, and a plain fix; none judged
offkind_fixture() {
  project game beta "$SANDBOX/repos/game"
  row game agent gd-1 "- [ ] decide(game): pick the map $T #high <!-- id:gd-1 -->"
  row game agent gd-2 "- [ ] design(game): a new menu look $T #low <!-- id:gd-2 -->"
  row game agent gd-3 "- [ ] epic(game): the whole season #high <!-- id:gd-3 -->"
  row game agent gd-4 "- [ ] decide(game): a parent call #high <!-- id:gd-4 -->"
  row game agent gd-5 "- [ ] fix(game): a child of gd-4 $T #of/gd-4 <!-- id:gd-5 -->"
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent gd-1 '[]' '[]'; board_row game agent gd-2 '[]' '[]'; board_row game agent gd-3 '[]' '[]'
  board_row game agent gd-4 '[]' '[]'; board_row game agent gd-5 '["of/gd-4"]' '[]'
  jq -c '.type = (.raw | capture("^- \\[ \\] (?<t>[a-z]+)\\(").t)' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b"
  mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
}

# sized_fixture -- agent rows sized by their #size/ tag, none judged but gs-5: gs-1 L, gs-2 XL and #requested, gs-3 an L
# epic, gs-4 L behind an #after/ gate, gs-5 L judged needs-person, gs-6 L with a goal: nobody planned through dispatch,
# gs-7 M, gs-8 an L parent of gs-9 (open) and gs-14 (doing), gs-11 L behind a #pr/ gate, gs-12 L whose one verdict
# is a failed one, gs-10 L in a draft project
sized_fixture() {
  project game beta "$SANDBOX/repos/game"
  project pre draft "$SANDBOX/repos/pre"
  local k
  row game agent gs-1 "- [ ] feat(game): the whole store #size/l $T <!-- id:gs-1 -->"
  row game agent gs-2 "- [ ] feat(game): the whole shop #size/xl #requested $T <!-- id:gs-2 -->"
  row game agent gs-3 "- [ ] epic(game): the season #size/l <!-- id:gs-3 -->"
  row game agent gs-4 "- [ ] feat(game): after the store #size/l $T #after/gs-7 <!-- id:gs-4 -->"
  row game agent gs-5 "- [ ] feat(game): a playtest build #size/l $T <!-- id:gs-5 -->"
  row game agent gs-6 "- [ ] feat(game): the briefed store #size/l $T <!-- id:gs-6 -->"
  row game agent gs-7 "- [ ] fix(game): a small one #size/m $T <!-- id:gs-7 -->"
  row game agent gs-8 "- [ ] feat(game): the parent #size/l $T <!-- id:gs-8 -->"
  row game agent gs-9 "- [ ] fix(game): its child #size/s $T #of/gs-8 <!-- id:gs-9 -->"
  row game agent gs-11 "- [ ] feat(game): after a pr #size/l $T #pr/o/r/5 <!-- id:gs-11 -->"
  row game agent gs-12 "- [ ] feat(game): a failed session #size/l $T <!-- id:gs-12 -->"
  row game agent gs-14 "- [/] fix(game): its other child #size/s $T #of/gs-8 <!-- id:gs-14 -->"
  row pre agent gs-10 "- [ ] feat(pre): a concept #size/l $T <!-- id:gs-10 -->"
  : > "$NOTES_FIXTURE/board.rows"
  for k in gs-1 gs-2 gs-3 gs-5 gs-6 gs-7 gs-8 gs-12; do board_row game agent "$k" '[]' '[]'; done
  board_row game agent gs-4 '["after/gs-7"]' '[]'; board_row game agent gs-9 '["of/gs-8"]' '[]'
  board_row game agent gs-11 '["pr/o/r/5"]' '[]'; board_row game agent gs-14 '["of/gs-8"]' '[]'
  board_row pre agent gs-10 '[]' '[]'
  jq -c '.size = (.raw | capture("#size/(?<s>[a-z]+)").s) | .type = (.raw | capture("^- \\[.\\] (?<t>[a-z]+)\\(").t)
    | if .id == "gs-2" then .requested = true else . end
    | if .id == "gs-14" then .state = "doing" else . end
    | if .id == "gs-6" then .details = ["goal: a person wrote this"] else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b"
  mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  verdict game agent gs-5 skip
  jq -c 'if .key == "gs-5" then .rule = "needs-person" | .size = "L" else . end' "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" \
    && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  # one failed record: latest_verdicts drops it, so only the raw file says the session failed
  jq -cn '{project: "game", lane: "agent", key: "gs-12", verdict: "failed", at: "2026-11-23T00:00:00-0800"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

# private_or_skip <what> -> $PRIVATE, the private checkout (read-only: the account home suite_home
# kept), or the test skips naming <what> it left unchecked.
private_or_skip() {
  load '../helpers/private'
  PRIVATE="${DOTFILES_PRIVATE:-${ACCOUNT_HOME:-}/.dotfiles-private}"
  has_private || skip "no private checkout at $PRIVATE: $1 unchecked"
}

# --- picks -------------------------------------------------------------------------------

# --- judge -------------------------------------------------------------------------------

# epic_fixture [leaf...] -- epic gm-20 on the human sheet and the named leaves under it (#of/gm-20) on
# the agent board, each `<id>:<type>:<size>`, in the shape notes board --json gives them.
epic_fixture() {
  local l id type size
  project game beta "$SANDBOX/repos/game"
  export PLAN_DIRS="$SANDBOX/plans"; mkdir -p "$PLAN_DIRS"
  row game human gm-20 '- [ ] epic(ui): players see their rank #size/l <!-- id:gm-20 -->'
  : > "$NOTES_FIXTURE/board.rows"
  jq -cn '{profile: "bnb", project: "game", lane: "human", id: "gm-20", state: "open", type: "epic", size: "l", parent: null, tags: []}' >> "$NOTES_FIXTURE/board.rows"
  for l in "$@"; do
    IFS=: read -r id type size <<<"$l"
    row game agent "$id" "- [ ] $type(ui): story $id #size/$size #of/gm-20 <!-- id:$id -->"
    jq -cn --arg i "$id" --arg t "$type" --arg s "$size" \
      '{profile: "bnb", project: "game", lane: "agent", id: $i, state: "open", type: $t, size: $s, parent: "gm-20", requested: false, tags: ["of/gm-20"]}' >> "$NOTES_FIXTURE/board.rows"
  done
}
epic_take() { promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-20"}')" "" "epic(ui): players see their rank" "$@"; }

# conf_keys <file>: the DISPATCH_* keys a conf sets, sorted; code_keys: fleet-dispatch's DISPATCH_CONF_KEYS
conf_keys() { sed -n 's/^\(DISPATCH_[A-Z0-9_]*\)=.*/\1/p' "$1" | sort; }
code_keys() { sed -n '/^DISPATCH_CONF_KEYS=(/,/^)/p' "$REPO_ROOT/.local/bin/fleet-dispatch" | grep -oE 'DISPATCH_[A-Z0-9_]+' | grep -vx DISPATCH_CONF_KEYS | sort; }

# age_sightings <minutes> -- every row sprint-stalled has seen unowned was first seen that long ago.
age_sightings() {
  local f="$FLEET_DISPATCH_DIR/sprint-stalled.tsv"
  awk -F'\t' -v OFS='\t' -v d="$(( $1 * 60 ))" '{ $3 -= d; print }' "$f" > "$f.new" && mv "$f.new" "$f"
}

# pool_prom -- a curl that answers prom_q as Prometheus would: the idle comparison keeps the unity pool
# while $NOTES_FIXTURE/busy of its 14 slots is under half, and github_pool_workflow puts repo `game`'s
# workflows on it. Each query goes to $NOTES_FIXTURE/curl.log.
pool_prom() {
  stub curl 'printf "%s\n" "$*" >> "$NOTES_FIXTURE/curl.log"
case "$*" in
  *github_pool_workflow*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"pool\":\"unity\",\"repo\":\"game\"},\"value\":[0,\"3\"]}]}}" ;;
  *) if [ "$(cat "$NOTES_FIXTURE/busy")" -lt 7 ]; then r="{\"metric\":{\"pool\":\"unity\"},\"value\":[0,\"0.2\"]}"; else r=""; fi
     echo "{\"status\":\"success\",\"data\":{\"result\":[$r]}}" ;;
esac'
}

# picks_order -> the row ids a dry fill of 4 would queue, in order.
picks_order() { DRY=1 JUDGE_RC='' fill_day 4 | grep -oE ': (ap|gm)-[0-9]+ \[' | tr -d ':[ ' | paste -sd' '; }

# --- pass order: a class under its min_live (ar-4890) ------------------------------------------

# ar-4890, 2026-11-23 13:25: unity at 1 of its min_live 6 while the pass spent its start cap on four
# reds and a cleanup row first, agent-queue listing every red at the top. game is a class with a
# minimum; app's reds and cleanup row are in other classes.
short_game_classes() {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  jq -n --argjson m "$1" '{on: true, window_days: 7, classes: [
    {name: "bug", share: 15, tags: ["red"]},
    {name: "cleanup", share: 10, tags: ["cleanup"]},
    {name: "unity", share: 20, projects: ["game"], min_live: $m},
    {name: "rest", share: 10, default: true}]}' > "$AGENT_QUEUE_CLASSES"
}
