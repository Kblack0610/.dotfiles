#!/usr/bin/env bats
# credit-backfill: propose writes one reviewable TSV per repo from the queue, the plans and the
# FAIL criteria; apply writes the reviewed lines through notes ptask and agent-queue set.
#
# schedules-sync is a stub serving the PR store from per-PR fixtures, each PR a real commit in the
# sandbox checkout (its diff gives the files and size); agent-queue is the repo's own; apply runs the real notes
# against a sandbox vault (NOTES_BIN, as inbox_plan.bats), so those cases skip without it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CB="$REPO_ROOT/.local/bin/credit-backfill"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  export PROJECT_MAP_FILE="$AGENT_QUEUE_PROJECT_MAP"
  export CREDIT_BACKFILL_DIR="$SANDBOX/bf" SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  export CREDIT_BACKFILL_PLANS="$SANDBOX/plans" CREDIT_BACKFILL_LIVE_PLANS="$SANDBOX/live"
  export CREDIT_BACKFILL_SYSTEM_CHECK="$SANDBOX/bin/system-check" GH_PRS="$SANDBOX/prs"
  unset CLAUDE_CODE_SESSION_ID
  REPO="$SANDBOX/repos/game"
  git init -q "$REPO" && git -C "$REPO" remote add origin https://github.com/acme/game.git
  # One repo, two games under it (arena, level) and the repo's own sheet (game).
  jq -n --arg r "$REPO" '{paths: {($r): "game"}, trackers: {
      "game": {code: "gm", lab: "personal", type: "game"},
      "arena": {repo: "game", path: "Assets/Arena", code: "ar", lab: "personal", type: "game"},
      "level": {repo: "game", path: "Assets/Level", code: "lv", lab: "personal", type: "game"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  printf '#!/bin/sh\nexec "%s/.local/bin/agent-queue" "$@"\n' "$REPO_ROOT" >"$SANDBOX/bin/agent-queue"
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  # schedules-sync prs <r> ...: the rows in $GH_PRS/N.json, newest first; $GH_PRS/store.err fails
  # the read with that message, as a stale store does.
  cat >"$SANDBOX/bin/schedules-sync" <<'SH'
#!/usr/bin/env bash
echo "schedules-sync $*" >>"$NOTES_FIXTURE/ss.log"
[ ! -f "$GH_PRS/store.err" ] || { cat "$GH_PRS/store.err" >&2; exit 1; }
cat "$GH_PRS"/*.json 2>/dev/null | jq -s 'sort_by(-.number)'
SH
  printf '#!/bin/sh\ncat "$NOTES_FIXTURE/criteria-$1.json" 2>/dev/null\n' >"$SANDBOX/bin/system-check"
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/schedules-sync" "$SANDBOX/bin/system-check" "$SANDBOX/bin/fleet-dispatch"
  mkdir -p "$GH_PRS" "$CREDIT_BACKFILL_PLANS/game" "$CREDIT_BACKFILL_LIVE_PLANS"
}

# pr <N> <lines> <path>... -- PR N's merge commit in the checkout, adding <lines> lines split over
# the paths (the remainder on the first), and its store row with that merge sha.
pr() { local n="$1" size="$2" p i k; shift 2
  for p in "$@"; do
    k=$((size / $#)); [ "$p" != "$1" ] || k=$((k + size % $#))
    mkdir -p "$REPO/$(dirname "$p")"
    for ((i = 0; i < k; i++)); do echo "pr $n line $i"; done >>"$REPO/$p"
    git -C "$REPO" add "$p"
  done
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "pr $n"
  jq -n --argjson n "$n" --arg sha "$(git -C "$REPO" rev-parse HEAD)" '{number: $n, state: "MERGED", merge_sha: $sha, merged_at: null}' >"$GH_PRS/$n.json"; }
# merged <N> <day> -- PR N merged at noon UTC on <day>.
merged() { local f="$GH_PRS/$1.json"; jq --arg t "$2T12:00:00Z" '.merged_at = $t' "$f" >"$f.new" && mv "$f.new" "$f"; }
# done_item <slug> <pr> [<plan> <phase>] -- a landed item on the repo's own project with no merged:,
# as items closed before agent-queue required one are (so its pr: goes on after the close); `phases:`
# is written as add --plan writes it, since set has no verb for it.
done_item() { local s="$1" n="$2" aq="$REPO_ROOT/.local/bin/agent-queue"
  "$aq" add --project game --slug "$s" "$s" >/dev/null 2>&1
  [ -z "${3:-}" ] || "$aq" set "$s" plan="$3" >/dev/null
  [ -z "${4:-}" ] || sed -i "0,/^plan: /s//phases: $4\nplan: /" "$AGENT_QUEUE_DIR"/queued/*-"$s".md
  "$aq" move "$s" done --status ok >/dev/null
  "$aq" set "$s" pr="acme/game#$n" >/dev/null; }
lines() { grep -v '^#' "$CREDIT_BACKFILL_DIR/game.tsv" | cut -f1-9 | tr '\t' '|'; }

@test "propose credits an item to the game its PR's files belong to, and keeps a shared one home" {
  pr 11 40 Assets/Arena/A.cs Assets/Arena/B.cs Assets/Shared/S.cs
  pr 12 40 Assets/Shared/S.cs
  done_item arena-fix 11
  done_item shared-fix 12
  run "$CB" propose game
  assert_success; assert_output --partial "1 attr, 0 epic, 2 story"
  run lines
  assert_line 'attr|-|arena|-|-|-|touches:arena|arena-fix|from game'
  assert_line 'story|-|arena|-|s|done|pr:11|arena-fix|arena-fix'
  assert_line 'story|-|game|-|s|done|pr:12|shared-fix|shared-fix'
}

@test "propose turns a plan of phases into an epic: ticked and item-landed phases close, deferred drops, a stale open one is left out" {
  pr 21 900 Assets/Level/L.cs
  pr 22 300 Assets/Level/M.cs
  printf '%s\n' '# Level: a harder second act' '' '## Phases' '' '- [x] P1 boss room (#21)' '- [ ] P2 checkpoints' \
    '- [-] P3 hard mode: deferred' '- [ ] P4 the rest' >"$CREDIT_BACKFILL_PLANS/game/act-two.md"
  done_item act-two-p2 22 "$CREDIT_BACKFILL_PLANS/game/act-two.md" 2
  touch -d '30 days ago' "$CREDIT_BACKFILL_PLANS/game/act-two.md"
  run "$CB" propose game
  assert_success
  run lines
  assert_line 'epic|act-two|level|gameplay|-|open|plan:act-two|-|Level: a harder second act'
  assert_line 'story|act-two|level|-|l|done|pr:21|-|P1 boss room (#21)'
  assert_line 'story|act-two|level|-|m|done|pr:22|act-two-p2|P2 checkpoints'
  assert_line 'story|act-two|level|-|m|deferred|why:deferred in plan act-two|-|P3 hard mode: deferred'
  refute_output --partial 'P4 the rest'
  # The item's plan is an epic here, so it is not filed again as a lone story.
  refute_line --partial 'story|-|'
  # A fresh plan's open phase is filed, open, naming its plan for whoever picks it up.
  touch "$CREDIT_BACKFILL_PLANS/game/act-two.md"
  "$CB" propose game
  run lines
  assert_line 'story|act-two|level|-|m|open|-|-|P4 the rest (plan act-two, phase 4)'
}

@test "propose files at size m with no credit move a PR that changed no file, is not in the store, or whose commit the checkout lacks; the store is read once" {
  pr 31 0
  jq -n '{number: 33, state: "MERGED", merge_sha: "0123456789abcdef0123456789abcdef01234567", merged_at: null}' >"$GH_PRS/33.json"
  done_item empty 31
  done_item gone 32
  done_item unfetched 33
  run "$CB" propose game
  assert_success
  assert_output --partial "lacks #33's merge commit 0123456789ab, so it is sized m: fetch it"
  run lines
  assert_line 'story|-|game|-|m|done|pr:31|empty|empty'
  assert_line 'story|-|game|-|m|done|pr:32|gone|gone'
  assert_line 'story|-|game|-|m|done|pr:33|unfetched|unfetched'
  refute_line --partial 'attr|'
  run cat "$NOTES_FIXTURE/ss.log"
  assert_output 'schedules-sync prs acme/game --state merged'
  # a checkout whose origin is on Forgejo reads the store under its host
  git -C "$REPO" remote set-url origin https://git.example.test/acme/game.git; : >"$NOTES_FIXTURE/ss.log"
  run "$CB" propose game
  run cat "$NOTES_FIXTURE/ss.log"
  assert_output 'schedules-sync prs git.example.test/acme/game --state merged'
}

@test "propose stops with the store's reason when the PR store cannot answer, so no size reads as unknown" {
  pr 11 40 Assets/Arena/A.cs
  done_item arena-fix 11
  echo "acme/game: PR store last synced 2h ago" >"$GH_PRS/store.err"
  run "$CB" propose game
  assert_failure; assert_output --partial "PR store: acme/game: PR store last synced 2h ago"
  [ ! -e "$CREDIT_BACKFILL_DIR/game.tsv" ]
}

@test "propose files a typed project's FAIL criteria as stories under one epic per system" {
  printf '%s\n' '{"systems": [{"id": "docs", "criteria": [{"criterion": "`docs/look.md` exists", "result": "FAIL"}, {"criterion": "a README", "result": "PASS"}]},' \
    '{"id": "ci", "criteria": [{"criterion": "a gate", "result": "PASS"}]}]}' >"$NOTES_FIXTURE/criteria-arena.json"
  run "$CB" propose game
  assert_success
  run lines
  assert_line 'epic|std:arena:docs|arena|docs|-|open|-|-|docs to standard'
  assert_line 'story|std:arena:docs|arena|-|s|open|-|-|docs: docs/look.md exists'
  refute_output --partial 'std:arena:ci'
}

# rows <project> -> every task row on its sheet and its agent board.
rows() { grep -rh '^- \[' "$HOME/.notes/lab/projects/current/$1" "$HOME/.notes/lab/agents" 2>/dev/null | sort -u; }

notes_vault() {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  local p
  for p in game arena level; do
    mkdir -p "$HOME/.notes/lab/projects/current/$p"
    printf '# %s\n\nVersion: v0.1.0\n\n## Tasks\n\n' "$p" >"$HOME/.notes/lab/projects/current/$p/README.md"
    : >"$HOME/.notes/lab/projects/current/$p/summary.md"
  done
  mkdir -p "$HOME/.config/notes"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  export NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
}

@test "apply writes the epic on the sheet, its stories closed on the board, the item moved and linked, and the plan its epic: line" {
  pr 11 40 Assets/Arena/A.cs
  pr 21 40 Assets/Level/L.cs
  # Added before notes is on PATH: an item from before every add filed its story row (#1133).
  done_item arena-fix 11
  notes_vault
  printf '%s\n' '# Level: done' '' '## Phases' '' '- [x] P1 one (#21)' '- [x] P2 two (#21)' >"$CREDIT_BACKFILL_PLANS/game/lv-done.md"
  "$CB" propose game
  run "$CB" apply game
  assert_success; assert_output --partial "5 lines applied"
  run rows level
  assert_line --regexp '^- \[x\] epic\(gameplay\): Level: done .*id:lv-1 '
  assert_line --regexp '^- \[x\] feat\(gameplay\): P1 one \(#21\) #size/s #of/lv-1 .*pr:21'
  run rows arena
  assert_line --regexp '^- \[x\] feat\(arena\): arena-fix #size/s .*pr:11'
  f="$(find "$AGENT_QUEUE_DIR" -name "*-arena-fix.md")"
  grep -qx 'project: arena' "$f"
  grep -qx 'touches: arena' "$f"
  grep -qE '^row: arena:ar-[0-9]+$' "$f"
  grep -qx 'epic: lv-1' "$CREDIT_BACKFILL_PLANS/level/lv-done.md"
  [ ! -e "$CREDIT_BACKFILL_PLANS/game/lv-done.md" ]
  # Every line now carries its id, so a rerun writes nothing.
  run "$CB" apply game
  assert_success; assert_output --partial "0 lines applied"
}

@test "apply closes a story on its PR's merge day and an epic on its last story's, not on the apply day" {
  pr 11 40 Assets/Arena/A.cs
  pr 21 40 Assets/Level/L.cs
  pr 22 40 Assets/Level/M.cs
  merged 11 2026-10-05; merged 21 2026-10-03; merged 22 2026-10-04
  done_item arena-fix 11
  notes_vault
  printf '%s\n' '# Level: done' '' '## Phases' '' '- [x] P1 one (#21)' '- [x] P2 two (#22)' >"$CREDIT_BACKFILL_PLANS/game/lv-done.md"
  "$CB" propose game
  run "$CB" apply game
  assert_success
  today="$(date +%F)"
  run rows arena
  assert_line --regexp '^- \[x\] feat\(arena\): arena-fix .*done:2026-10-05 pr:11'
  run rows level
  assert_line --regexp '^- \[x\] feat\(gameplay\): P1 one \(#21\) .*done:2026-10-03 pr:21'
  assert_line --regexp '^- \[x\] feat\(gameplay\): P2 two \(#22\) .*done:2026-10-04 pr:22'
  assert_line --regexp '^- \[x\] epic\(gameplay\): Level: done .*done:2026-10-04 '
  refute_output --partial "done:$today"
}

@test "apply closes a story today when the PR store has no merge day for it, and redate then moves it, one project at a time" {
  pr 11 40 Assets/Arena/A.cs
  pr 21 40 Assets/Level/L.cs
  pr 22 40 Assets/Level/M.cs
  done_item arena-fix 11
  notes_vault
  printf '%s\n' '# Level: done' '' '## Phases' '' '- [x] P1 one (#21)' '- [x] P2 two (#22)' >"$CREDIT_BACKFILL_PLANS/game/lv-done.md"
  "$CB" propose game
  run "$CB" apply game
  assert_output --partial "pr:21): no merge day in the PR store, closed today"
  today="$(date +%F)"
  run rows level
  assert_line --regexp "^- \[x\] feat\(gameplay\): P1 one .*done:$today pr:21"
  merged 11 2026-10-05; merged 21 2026-10-03; merged 22 2026-10-04
  run "$CB" redate propose game
  assert_success; assert_output --partial "4 to re-date"
  run grep -v '^#' "$CREDIT_BACKFILL_DIR/game.redate.tsv"
  assert_line --regexp "^arena	ar-[0-9]+	$today	2026-10-05	pr:11	\$"
  assert_line --regexp "^level	lv-1	$today	2026-10-04	plan:lv-done	\$"
  # The human reviews one project: only its lines are written, and a rerun writes none.
  run "$CB" redate apply game level
  assert_success; assert_output --partial "3 rows re-dated in level"
  run rows level
  assert_line --regexp '^- \[x\] feat\(gameplay\): P1 one .*done:2026-10-03 pr:21'
  assert_line --regexp '^- \[x\] epic\(gameplay\): Level: done .*done:2026-10-04 '
  run rows arena
  assert_line --regexp "^- \[x\] feat\(arena\): arena-fix .*done:$today pr:11"
  run "$CB" redate apply game level
  assert_output --partial "0 rows re-dated in level"
  run "$CB" redate propose game
  assert_failure; assert_output --partial "delete it to propose again"
  rm "$CREDIT_BACKFILL_DIR/game.redate.tsv"
  run "$CB" redate propose game
  assert_output --partial "1 to re-date"
}

@test "apply refuses an epic whose system is still ?" {
  printf '# p\n# kind\n%s\n' $'epic\tx\tgame\t?\t-\topen\tplan:x\t-\tsomething\t' >"$SANDBOX/q.tsv"
  mkdir -p "$CREDIT_BACKFILL_DIR" && mv "$SANDBOX/q.tsv" "$CREDIT_BACKFILL_DIR/game.tsv"
  run "$CB" apply game
  assert_failure; assert_output --partial "column 4 is ?): x"
}

@test "propose tags a store-worded plan with the store system, whose Applies cell is store" {
  pr 31 300 Assets/Store/S.cs
  printf '%s\n' '# Steam: the store page listing' '' '## Phases' '' '- [x] P1 capsule art (#31)' '- [ ] P2 trailer' >"$CREDIT_BACKFILL_PLANS/game/steam-page.md"
  run "$CB" propose game
  assert_success
  run lines
  assert_line --regexp '^epic\|steam-page\|[^|]*\|store\|'
}
