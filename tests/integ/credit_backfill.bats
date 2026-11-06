#!/usr/bin/env bats
# credit-backfill: propose writes one reviewable TSV per repo from the queue, the plans and the
# FAIL criteria; apply writes the reviewed lines through notes ptask and agent-queue set.
#
# gh is a stub serving PR file lists; agent-queue is the repo's own; apply runs the real notes
# against a sandbox vault (NOTES_BIN, as inbox_plan.bats), so those cases skip without it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CB="$REPO_ROOT/.local/bin/credit-backfill"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  export PROJECT_MAP_FILE="$AGENT_QUEUE_PROJECT_MAP"
  export CREDIT_BACKFILL_DIR="$SANDBOX/bf" CREDIT_BACKFILL_CACHE="$SANDBOX/cache"
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
  # gh api repos/<r>/pulls/N[/files]: served from $GH_PRS/N.json; N.err is a failure with that
  # message, and no fixture a 404, as gh gives. The stub answers the --jq the script asks for.
  cat >"$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >>"$NOTES_FIXTURE/gh.log"
p="${2#repos/*/pulls/}" f="$GH_PRS/${p%/files}.json"
[ ! -f "${f%.json}.err" ] || { cat "${f%.json}.err" >&2; exit 1; }
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$p" in */files) jq -r '.files[]?.path' "$f" ;; *) jq -r '.additions + .deletions' "$f" ;; esac
SH
  printf '#!/bin/sh\ncat "$NOTES_FIXTURE/criteria-$1.json" 2>/dev/null\n' >"$SANDBOX/bin/system-check"
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/gh" "$SANDBOX/bin/system-check" "$SANDBOX/bin/fleet-dispatch"
  mkdir -p "$GH_PRS" "$CREDIT_BACKFILL_PLANS/game" "$CREDIT_BACKFILL_LIVE_PLANS"
}

# pr <N> <added+deleted> <path>... -- a PR fixture.
pr() { local n="$1" size="$2"; shift 2; jq -n --argjson s "$size" '{additions: $s, deletions: 0, files: [$ARGS.positional[] | {path: .}]}' --args "$@" >"$GH_PRS/$n.json"; }
# done_item <slug> <pr> [<plan> <phase>] -- a landed item on the repo's own project; `phases:` is
# written as add --plan writes it, since set has no verb for it.
done_item() { local s="$1" n="$2" aq="$REPO_ROOT/.local/bin/agent-queue"
  "$aq" add --project game --slug "$s" "$s" >/dev/null 2>&1
  "$aq" set "$s" pr="acme/game#$n" ${3:+plan="$3"} >/dev/null
  [ -z "${4:-}" ] || sed -i "0,/^plan: /s//phases: $4\nplan: /" "$AGENT_QUEUE_DIR"/queued/*-"$s".md
  "$aq" move "$s" done --status ok >/dev/null; }
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

@test "propose survives a PR gh cannot read: the story is filed at size m with no credit move; a 404 is asked once, a rate limit again" {
  printf '{"additions": 0, "deletions": 0, "files": []}\n' >"$GH_PRS/31.json"
  echo "gh: API rate limit exceeded (HTTP 403)" >"$GH_PRS/33.err"
  done_item empty 31
  done_item gone 32
  done_item limited 33
  run "$CB" propose game
  assert_success
  run lines
  assert_line 'story|-|game|-|m|done|pr:31|empty|empty'
  assert_line 'story|-|game|-|m|done|pr:32|gone|gone'
  assert_line 'story|-|game|-|m|done|pr:33|limited|limited'
  refute_line --partial 'attr|'
  : >"$NOTES_FIXTURE/gh.log"
  "$CB" propose game
  run cat "$NOTES_FIXTURE/gh.log"
  assert_output 'gh api repos/acme/game/pulls/33 --jq .additions + .deletions'
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

@test "apply refuses an epic whose system is still ?" {
  printf '# p\n# kind\n%s\n' $'epic\tx\tgame\t?\t-\topen\tplan:x\t-\tsomething\t' >"$SANDBOX/q.tsv"
  mkdir -p "$CREDIT_BACKFILL_DIR" && mv "$SANDBOX/q.tsv" "$CREDIT_BACKFILL_DIR/game.tsv"
  run "$CB" apply game
  assert_failure; assert_output --partial "column 4 is ?): x"
}
