#!/usr/bin/env bats
# The second half of fleet_dispatch.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/main.bash.
# shard-seconds: 162 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/main'

@test "item_tier: an untiered item on a harness project is tier 3, whoever queued it; a tier tag, the text, or another project says otherwise" {
  t() { jq -cn --arg p "$1" --arg tags "$2" --arg title "$3" '{slug: "s", mode: "oneshot", project: $p, tags: $tags, title: $title, task: $title}'; }
  assert_equal "$(item_tier "$(t agent-runtime '' 'chore(hooks): prune them')")" 3
  assert_equal "$(item_tier "$(t notes-cockpit '' 'fix: x')")" 3
  assert_equal "$(item_tier "$(t agent-runtime 'cleanup tier2' 'fix: x')")" 2
  assert_equal "$(item_tier "$(t agent-runtime '' 'fix: x #tier/1')")" 1
  assert_equal "$(item_tier "$(t game '' 'fix: x')")" 1
  assert_equal "$(item_tier "$(t game 'night' 'fix: x')")" 1
  # A hand-added harness item is told the gate at start, and agent-land reads the same answer.
  run item_brief "$(t agent-runtime '' 'chore(hooks): prune them')"
  assert_output --partial 'This is tier 3 (harness or tooling)'
  run item_brief "$(t game '' 'fix: x')"
  refute_output --partial 'This is tier 3'
  agent-queue add --project agent-runtime --slug hand "chore(hooks): prune them" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier hand
  assert_success
  assert_output 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier nosuch
  assert_failure
}

@test "tier3 gate: only rows tier 3 alone holds back; a requested row goes, decisions, devices, the human's machine and lower tiers stay out" {
  pr_lane_ready
  row agent-runtime agent 'requested row' '- [ ] fix the requested row #requested #tier/3'
  row agent-runtime agent 'decide(app): fold it' '- [ ] decide(app): fold it #tier/3'
  row agent-runtime agent 'typed decide' '- [ ] decide(board): fold it #tier/3'
  row agent-runtime agent 'pad run' '- [ ] fix the pad controller switch #tier/3'
  row agent-runtime agent 'waybar row' '- [ ] waybar: fix pulse colours #tier/3'
  row agent-runtime agent 'tier two' '- [ ] fix the tier two row #tier/2'
  row agent-runtime agent 'unclear' '- [ ] fix something somewhere #tier/3'
  row agent-runtime agent 'started' '- [/] fix the started row #tier/3'
  row agent-runtime agent 'untagged' '- [ ] fix the untagged row'
  for k in 'requested row' 'decide(app): fold it' 'typed decide' 'pad run' 'waybar row' 'tier two' 'started' 'untagged'; do pr_lane_verdict "$k"; done
  pr_lane_verdict unclear unclear false

  run t3_rows ''
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'requested row,unclear,untagged'
  DISPATCH_PER_PASS=5 fill
  assert_success
  assert_equal "$(pr_lane_keys)" 'requested row,untagged'
}

@test "tier3 gate: a #requested row takes a slot ahead of an older #high row" {
  pr_lane_ready
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #high'
  row agent-runtime agent 'route the reds' '- [ ] route the reds to owners #requested #low'
  pr_lane_verdict 'retire the hook' timers; pr_lane_verdict 'route the reds' reds
  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "ready" and .worker == "tier3") | .key' <<<"$output" | paste -sd,)" 'route the reds,retire the hook'
}

@test "tier3 gate: no area holds a row (two share timers), up to the pass limit: observer rows first, then #high, newest first" {
  pr_lane_ready
  row agent-runtime agent 'add a panel' '- [ ] add a panel for y #high'
  row agent-runtime agent 'shorter briefs' '- [ ] shorter briefs for tier3 items #kpi/board_open #high'
  row agent-runtime agent 'add a column' '- [ ] add a column to z #high'
  row agent-runtime agent 'retire the timer' '- [ ] retire the dead timer #low'
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #low'
  row agent-runtime agent 'add w' '- [ ] add w #low'
  pr_lane_verdict 'add a panel'; pr_lane_verdict 'shorter briefs'; pr_lane_verdict 'add a column'
  pr_lane_verdict 'retire the timer' timers; pr_lane_verdict 'retire the hook' timers; pr_lane_verdict 'add w'

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "ready" and .worker == "tier3") | .key' <<<"$output" | paste -sd,)" 'shorter briefs,add a column,add a panel,add w,retire the hook,retire the timer'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  [ "$(state_of 'shorter briefs')" = '- [ ]' ] || fail "fill --dry-run started a row"
  DISPATCH_PER_PASS=3 fill
  assert_success
  assert_equal "$(pr_lane_keys)" 'add a column,add a panel,shorter briefs'
  [ "$(state_of 'retire the hook')" = '- [ ]' ] || fail "a fourth row was started"
}

@test "tier3 gate: a typed finding and a #kpi/ row rank as observer rows, the word kpi in a body does not" {
  pr_lane_ready
  row agent-runtime agent 'add a kpi chip' '- [ ] add a kpi: chip to the hub #high'
  row agent-runtime agent 'check kpi' '- [ ] check(kpi): board_open past threshold #low'
  row agent-runtime agent 'tagged' '- [ ] shorter briefs #kpi/ask_answered_pct #low'
  pr_lane_verdict 'add a kpi chip'; pr_lane_verdict 'check kpi'; pr_lane_verdict 'tagged'

  fill --dry-run --json
  # Both observer rows rank ahead of the #high row that only names kpi in its body.
  assert_equal "$(jq -r 'select(.state == "ready" and .worker == "tier3") | .key' <<<"$output" | tail -1)" 'add a kpi chip'
  assert_equal "$(jq -r 'select(.state == "ready" and .worker == "tier3") | .key' <<<"$output" | head -2 | sort | paste -sd,)" 'check kpi,tagged'
}

@test "tier3 gate: a row agent-queue will not take is un-started again" {
  pr_lane_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  pr_lane_verdict 'fix it'
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  stub agent-queue '[ "$1" = add ] && { echo "no room" >&2; exit 1; }; exec "$(dirname "$0")/agent-queue.real" "$@"'
  fill
  assert_output --partial 'could not queue agent-runtime row, un-started: gm-1'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "tier3 gate: a cancelled tier3 item (default profile, no profile: line) hands its row back" {
  pr_lane_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  pr_lane_verdict 'fix it'
  fill
  [ "$(state_of 'fix it')" = '- [/]' ] || fail "row not started"
  # Every tier-3 item names its profile now; drop the line to prove the default-profile hand-back still holds.
  sed -i "/^profile: /d" "$(qitem queued gm-1)"
  agent-queue cancel gm-1
  run cmd_reap
  assert_output --partial 'un-started agent-runtime: gm-1 (queue item gm-1 ended cancelled)'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "tier3 gate: the judge reads a new row as tier 3, and its dispatch goes to the gate; its skip does not" {
  pr_lane_ready
  row agent-runtime agent 'fix it' '- [ ] fix it'
  row agent-runtime agent 'vague' '- [ ] fix something'
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; cat "$NOTES_FIXTURE/judge.out"'
  cat > "$NOTES_FIXTURE/judge.out" <<'J'
{"verdicts":[{"project": "agent-runtime", "lane": "agent", "key": "fix it", "tier": 3, "size": "S", "area": "hooks", "clear": true, "agent_only": true, "verdict": "dispatch", "rule": "fits", "reason": "tier 3"},
{"project": "agent-runtime", "lane": "agent", "key": "vague", "tier": 3, "size": "S", "area": "hooks", "clear": false, "agent_only": true, "verdict": "skip", "rule": "unclear", "reason": "not clear"}]}
J
  DISPATCH_PER_PASS=5 fill
  assert_success
  # an untagged agent-runtime row goes to the judge as its tier-3 copy, so tier 3 is the highest it may dispatch at
  grep -qF '"key":"fix it"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  grep -F '"key":"fix it"' "$NOTES_FIXTURE/prompt" | grep -qF '"tier":3' || fail "$(cat "$NOTES_FIXTURE/prompt")"
  assert_equal "$(pr_lane_keys)" 'fix it'
}

@test "policy_sig: a workers.json edit keeps every verdict fresh; a policy edit that keeps the rule is not judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'judged' "- [ ] judged $T"
  verdict game agent 'judged' skip
  echo '{"fleet": {"max_tier": 1, "lane": "agent"}}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
  echo 'policy v3' >> "$DISPATCH_POLICY"
  # 2026-11-07: re-judging every unchanged row after an edit spent the judge's day budget by 06:20.
  run cmd_candidates
  assert_output ''
  # The edit voids nothing: the old verdict still counts as the row's verdict.
  run cmd_suggest --json
  assert_equal "$(jq -r .verdict <<<"$output")" skip
}

@test "policy rename: a verdict whose rule id left the policy reads unjudged and is judged again, one whose id stays keeps its verdict (ar-4831)" {
  # #3255 removed the alpha rule but kept the id (stage), so 576 rows kept their "Size M at alpha" skip. A changed rule gets a new id.
  printf '%s\n' '- (stage-scope) the row is more than its project stage allows' >> "$DISPATCH_POLICY"
  project game alpha "$SANDBOX/repos/game"
  row game agent 'kept' "- [ ] kept $T"
  row game agent 'stale' "- [ ] stale $T"
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg sig "made-under-an-older-policy" --arg k kept --arg l "$(line_of game agent kept)" \
    '{project: "game", lane: "agent", key: $k, verdict: "skip", rule: "stage-scope", reason: "r", policy: $sig, line: $l}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn --arg sig "made-under-an-older-policy" --arg k stale --arg l "$(line_of game agent stale)" \
    '{project: "game", lane: "agent", key: $k, verdict: "skip", rule: "stage", reason: "Size M at alpha", policy: $sig, line: $l}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'stale'
  run cmd_suggest --json
  assert_equal "$(jq -r '"\(.key)=\(.verdict)"' <<<"$output" | paste -sd' ')" 'kept=skip stale=unjudged'
}

@test "judge: a reply that names no rule is an error record, and the verdict from an older policy stays in force" {
  stub judge-stub 'printf "%s\n" "{\"verdicts\":[{\"project\":\"game\",\"lane\":\"agent\",\"key\":\"olddisp\",\"verdict\":\"skip\",\"rule\":\"nope\"}]}"'
  project game beta "$SANDBOX/repos/game"
  row game agent 'olddisp' "- [ ] olddisp $T"
  verdict game agent 'olddisp' dispatch
  echo 'policy v2' >> "$DISPATCH_POLICY"
  run judge "$(jq -nc --arg l "$(line_of game agent olddisp)" '{project:"game",stage:"beta",lane:"agent",key:"olddisp",text:"- [ ] olddisp",prio:1,line:$l}')"
  assert_equal "$(jq -r 'select(.key == "olddisp") | .verdict' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | paste -sd,)" 'dispatch,error'
  assert_equal "$(latest_verdicts | jq -r 'select(.key == "olddisp") | .verdict')" dispatch
}

@test "judge shares a capped batch across projects: each project's best row, then each one's next" {
  # the first call's prompt: the rows it leaves out are asked for again in a second one
  stub judge-stub '[ -e "$NOTES_FIXTURE/prompt" ] || printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":2}'
  assert_success
  # Rank alone would send p1, p2, p3 and never a1.
  assert_equal "$(grep -o '"key":"[a-z0-9]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd, -)" 'p1,a1,p2'
}

@test "judge: a cleanup row goes first within a round, never ahead of it; a project with no cleanup row still gets its slot" {
  # the first call's prompt: the rows it leaves out are asked for again in a second one
  stub judge-stub '[ -e "$NOTES_FIXTURE/prompt" ] || printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1,"cleanup":0}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}'
  assert_success
  # Cleanup ahead of the rounds sent p1, p2, p3 and never a1.
  assert_equal "$(grep -o '"key":"[a-z0-9]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd, -)" 'p1,a1,p2'
}

@test "gate names every closed gate, room's own reason included; a dispatch hold is the only answer when it holds" {
  acct
  echo '99.00 99.00 99.00 1/1 1' > "$DISPATCH_LOADAVG"
  run gate
  assert_output --regexp '^no account has room under its weekly pace and after its live sessions, and no other source has room; load 99.00 on [0-9]+ cores is over the [0-9.]+ pace$'
  stub claude-acct 'exit 2'
  run gate
  assert_output --partial 'account usage unreadable (claude-acct room --json gave no answer); load 99.00'
  stub agent-hold 'exit 1'
  run gate
  assert_output 'held (agent-hold dispatch)'
  stub agent-hold 'echo "held: dispatch since 2026-11-12T09:04:57-0800 by binks: load 72.9; no new sessions"; exit 1'
  run gate
  assert_output 'held (agent-hold dispatch) by binks: load 72.9; no new sessions'
}

@test "red: a red item merges its own PR: no --pr-only, and its brief names fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r"
  cmd_start --item r >/dev/null || fail "start r"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial '/one-shot fix r'
  refute_output --partial '--pr-only'
  assert_output --partial 'read ~/.claude/skills/fix-red/SKILL.md first'
  assert_output --partial 'Merge with agent-land <N>'
  refute_output --partial 'this is its escalation'
  # reflective-penguin P2: triage's escalation of a red whose fixes did not hold is the root-cause pass
  : > "$NOTES_FIXTURE/cmds.log"
  agent-queue add --project game --slug r2 --tags 'red cause:cd34 escalate retry:r' "fix r again" >/dev/null
  cmd_start --item r2 >/dev/null || fail "start r2"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial 'this is its escalation: before any fix, do the root-cause pass of fix-red section 3'
  refute_output --partial 'this is its cause item'
  # ar-6018: a cause item's brief lists each earlier fix's PR, read from the queue by fleet-bench triage --backs
  : > "$NOTES_FIXTURE/cmds.log"
  stub fleet-bench "echo \"\$*\" >> '$NOTES_FIXTURE/fb.log'; printf 'ar-1\to/r#5\t2026-11-20T00:00:00Z\nar-3\to/r#6\t2026-11-21T00:00:00Z\nprobe\t/st/links.out\n'"
  agent-queue add --project game --slug r3 --tags 'red watch cause:ef56 cause retry:ar-1,ar-3' "check(watch): links tripped since x" >/dev/null
  cmd_start --item r3 >/dev/null || fail "start r3"
  run cat "$NOTES_FIXTURE/fb.log"
  assert_output --regexp '^triage --backs ef56 [0-9]+ links$'
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial 'came back after each earlier fix merged: o/r#5 (item ar-1, finished 2026-11-20T00:00:00Z), o/r#6 (item ar-3, finished 2026-11-21T00:00:00Z). So this is its cause item'
  assert_output --partial 'before and after (fix-red step 5); the probe output now is in /st/links.out. Before any fix'
}

@test "promote: --model pins the item's model, as triage's escalation does; without it the item names none" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'deep one' '- [ ] deep one <!-- id:gm-8 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --agent --project game --profile bnb --model opus --raw '- [ ] deep one <!-- id:gm-8 -->'
  assert_success
  run agent-queue show gm-8
  assert_line 'model: opus'
  # NEGATIVE CONTROL: a plain promote leaves the model to the lane
  row game agent 'plain one' '- [ ] plain one <!-- id:gm-9 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --agent --project game --profile bnb --raw '- [ ] plain one <!-- id:gm-9 -->'
  assert_success
  run agent-queue show gm-9
  refute_line --partial 'model:'
}

@test "canary: a canary item starts on its task as written: no /one-shot and no PR or landing lines" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug c --from canary --tags canary "Canary eval c: run fleet-bench canary start c" >/dev/null
  cmd_start --item c >/dev/null || fail "start c"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --regexp 'bypassPermissions Canary\\ eval\\ c:\\ run\\ fleet-bench\\ canary\\ start\\ c$'
  refute_output --partial '/one-shot'
  refute_output --partial 'Run agent-land in the foreground'
  refute_output --partial 'PR body'
}

@test "red: a plain item's brief does not name fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug p --tags 'ui' "fix p"
  cmd_start --item p >/dev/null || fail "start p"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial 'fix-red'
}

@test "next_items keeps the queue's order (agent-queue owns it) and keeps a gateway one" {
  runnable() {
    printf '%s\n' '{"slug":"r1","tags":"red"}' '{"slug":"c","tags":"cleanup"}' '{"slug":"g","agent":"lazer"}' '{"slug":"a"}'
  }
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'r1 c g a '
}

@test "next_items from the real queue: a low red, then the high items by queued time; a cleanup tag does not reorder" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug plain "plain"
  agent-queue add --project game --slug tidy --tags cleanup "tidy"
  agent-queue add --project game --slug broke --priority low --tags 'red cause:ab12' "broke"
  stub fleet-presence 'echo away 0 x'
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'broke plain tidy '
}

@test "next_items from the real queue: a sprint item goes after red and urgent, before the project rank and a plain high item" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug plain "plain"
  agent-queue add --project game --slug sp --tags sprint "sprint row"
  agent-queue add --project game --slug urg --priority urgent "urgent"
  agent-queue add --project game --slug broke --priority low --tags 'red cause:ab12' "broke"
  stub fleet-presence 'echo away 0 x'
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'broke urg sp plain '
}

@test "sprint rank: a row an open sprint holds is picked ahead of an urgent row of another project, and its item carries the sprint tag" {
  export DISPATCH_PROFILES=bnb
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  # app sorts before game on a tie, so the sprint row belongs to game: only the sprint rank can put it first.
  row app human ap-1 "- [ ] fix(app): menu text #urgent $T <!-- id:ap-1 -->"
  row game human gm-9 "- [ ] fix(game): crash on load #high $T <!-- id:gm-9 -->"
  verdict app human ap-1 dispatch S 1 menu
  verdict game human gm-9 dispatch S 1 crash
  # Negative control: with no sprint in the feed the other project's row is next.
  [[ "$(DRY=1 JUDGE_RC='' fill_day 1)" == *ap-1* ]] || fail "no sprint: ap-1 should be next: $(DRY=1 JUDGE_RC='' fill_day 1)"
  # A sprint of game with the row open and one done, and a queued sprint of app that has not started.
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-9", state: "open"}, {id: "gm-8", state: "done"}]},
           {project: "app", queued: true, tasks: [{id: "ap-1", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  DRY=0 JUDGE_RC='' fill_day 1
  [ -n "$(qitem queued gm-9)" ] || fail "the sprint row was not queued first: $(ls "$AGENT_QUEUE_DIR/queued")"
  [ -z "$(qitem queued ap-1)" ] || fail "a queued sprint's row ranked as the open sprint's"
  grep -q '^tags:.*sprint' "$(qitem queued gm-9)" || fail "the item has no sprint tag: $(cat "$(qitem queued gm-9)")"
}

@test "sprint rank: an open-version row the window left out ranks as sprint once it unblocks, with no relock, after the committed row" {
  export DISPATCH_PROFILES=bnb
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row app human ap-1 "- [ ] fix(app): menu text #urgent $T <!-- id:ap-1 -->"
  # gm-7 waited #after/ a row that has since closed, so the lock left it out. It is #urgent and on the sheet
  # and its area sorts first (picks breaks a tie by area), so only the committed-first key puts gm-9 ahead.
  row game agent gm-7 "- [ ] fix(game): unblocked row #urgent $T <!-- id:gm-7 -->"
  row game agent gm-9 "- [ ] fix(game): committed row #high $T <!-- id:gm-9 -->"
  verdict game agent gm-7 dispatch S 1 boot
  verdict app human ap-1 dispatch S 1 menu
  verdict game agent gm-9 dispatch S 1 crash
  # NEGATIVE CONTROL: a sprint read from its snapshot alone ranks the unblocked row behind the other project's.
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-9", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  assert_equal "$(picks_order)" 'gm-9 ap-1 gm-7'
  # The feed lists it under the open sprint's `uncommitted`: the next pass ranks it as sprint, no relock run.
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-9", state: "open"}], uncommitted: ["gm-7", "gm-9"]},
           {project: "app", queued: true, tasks: [], uncommitted: ["ap-1"]}]' > "$NOTES_FIXTURE/board.sprints"
  assert_equal "$(picks_order)" 'gm-9 gm-7 ap-1'
  [[ "$(DRY=1 JUDGE_RC='' fill_day 4)" == *'open sprint, uncommitted'* ]] || fail "the why does not name it: $(DRY=1 JUDGE_RC='' fill_day 4)"
  DRY=0 JUDGE_RC='' fill_day 2
  grep -q '^tags:.*sprint' "$(qitem queued gm-7)" || fail "the uncommitted row's item has no sprint tag: $(cat "$(qitem queued gm-7)")"
}

@test "sprint-stalled: an open sprint row with no item, session or open gate for an hour trips, named with its verdict; gated, parent, started, human-lane and out-of-sprint rows do not; queued it clears (ar-4333)" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): committed and unowned $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] fix(game): waits on gm-1 $T #after/gm-1 <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] fix(game): left out at the lock, unowned $T <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] feat(game): a parent $T <!-- id:gm-4 -->"
  row game agent gm-5 "- [ ] fix(game): the parent's child #of/gm-4 $T #after/gm-1 <!-- id:gm-5 -->"
  row game agent gm-6 "- [/] fix(game): a session holds it $T <!-- id:gm-6 -->"
  row game agent gm-7 "- [ ] fix(game): not in the sprint $T <!-- id:gm-7 -->"
  row game human gm-8 "- [ ] fix(game): the human's own $T <!-- id:gm-8 -->"
  verdict game agent gm-1 skip
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-1", state: "open"}, {id: "gm-2", state: "open"}, {id: "gm-4", state: "open"},
           {id: "gm-6", state: "doing"}, {id: "gm-8", state: "open"}], uncommitted: ["gm-3", "gm-5"]}]' > "$NOTES_FIXTURE/board.sprints"
  # The first sighting starts the clock: under the hour nothing trips.
  run cmd_sprint_stalled
  assert_success
  assert_output --partial '(2 unowned for less)'
  assert_equal "$(cut -f2 "$FLEET_DISPATCH_DIR/sprint-stalled.tsv" | paste -sd,)" 'gm-1,gm-3'
  age_sightings 61
  run cmd_sprint_stalled
  assert_failure
  assert_output --partial '  gm-1 (game, 61 min); last verdict skip: r'
  assert_output --partial '  gm-3 (game, uncommitted, 61 min); never judged'
  assert_line --index -1 '2 open sprint row(s) stalled: gm-1, gm-3 (fleet-dispatch suggest says why each waits)'
  for k in gm-2 gm-4 gm-5 gm-6 gm-7 gm-8; do refute_output --partial "  $k ("; done
  # Queued, the row is owned: it drops out, and the other still trips.
  board_item gm-1 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_sprint_stalled
  assert_failure
  refute_output --partial '  gm-1 ('
  assert_line --index -1 '1 open sprint row(s) stalled: gm-3 (fleet-dispatch suggest says why each waits)'
  # A row that leaves the sprint and comes back counts from its new sighting.
  jq -nc '[{project: "game", queued: false, tasks: [], uncommitted: []}]' > "$NOTES_FIXTURE/board.sprints"
  run cmd_sprint_stalled
  assert_success
  jq -nc '[{project: "game", queued: false, tasks: [], uncommitted: ["gm-3"]}]' > "$NOTES_FIXTURE/board.sprints"
  run cmd_sprint_stalled
  assert_success
  # A dispatch hold is on purpose: nothing trips, and the clock restarts.
  age_sightings 61
  stub agent-hold 'exit 1'
  run cmd_sprint_stalled
  assert_success
  assert_output --partial 'dispatch is held (agent-hold)'
  [ ! -e "$FLEET_DISPATCH_DIR/sprint-stalled.tsv" ] || fail "the sightings outlived the hold"
}

@test "sprint-stalled: a queue or gate read that fails is unreadable (rc 2), never a trip" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): unowned $T <!-- id:gm-1 -->"
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-1", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  stub agent-queue 'exit 1'
  run cmd_sprint_stalled
  assert_failure 2
  assert_output --partial 'unreadable: agent-queue gate --all failed'
  unset GATES_LOADED
  stub_list='case "$1" in list) exit 1 ;; *) exec "'"$SANDBOX"'/bin/aq-real" "$@" ;; esac'
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/aq-real"
  stub agent-queue "$stub_list"
  run cmd_sprint_stalled
  assert_failure 2
  assert_output --partial 'unreadable: agent-queue list --json failed'
  # An empty worker table or a board feed with no sprints reads as no rows to cmd_candidates: rc 2, and
  # an hour of sightings that would trip survives it.
  stub agent-queue 'exec "'"$SANDBOX"'/bin/aq-real" "$@"'
  printf 'game\tgm-1\t%s\n' "$(( $(date +%s) - 61 * 60 ))" > "$FLEET_DISPATCH_DIR/sprint-stalled.tsv"
  cp "$DISPATCH_WORKERS" "$SANDBOX/workers.keep"
  echo '{}' > "$DISPATCH_WORKERS"
  run cmd_sprint_stalled
  assert_failure 2
  assert_output --partial 'unreadable: no workers in'
  cp "$SANDBOX/workers.keep" "$DISPATCH_WORKERS"
  cp "$SANDBOX/bin/notes" "$SANDBOX/notes.keep"
  stub notes 'case "$1" in board) echo "{\"rows\": []}" ;; *) exit 1 ;; esac'
  run cmd_sprint_stalled
  assert_failure 2
  assert_output --partial 'unreadable: notes board --json failed or has no sprints'
  grep -q "^game$(printf '\t')gm-1$(printf '\t')" "$FLEET_DISPATCH_DIR/sprint-stalled.tsv" || fail "an unreadable pass wiped the sightings"
  # Control: with both reads restored the same sightings trip.
  cp "$SANDBOX/notes.keep" "$SANDBOX/bin/notes"
  run cmd_sprint_stalled
  assert_failure 1
  assert_output --partial '  gm-1 (game, 61 min)'
}

@test "idle pool rank: fill reads the pool from prometheus and picks a row on an idle pool ahead of another project's on a tie, naming and logging it; a busy pool or no knob gives no boost" {
  export DISPATCH_PROFILES=bnb DISPATCH_CLASSES="$SANDBOX/classes.json"
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  # These fixture rows carry no feed rank, so they tie, and app sorts before game: only the term puts game's first.
  row app human ap-1 "- [ ] fix(app): menu text #high $T <!-- id:ap-1 -->"
  row game human gm-9 "- [ ] fix(game): crash on load #high $T <!-- id:gm-9 -->"
  verdict app human ap-1 dispatch S 1 menu
  verdict game human gm-9 dispatch S 1 crash
  pool_prom
  echo '{"idle_pool": {"pools": ["unity"], "busy_below": 0.5}}' > "$DISPATCH_CLASSES"
  # Negative controls: a busy pool (12 of 14), then an idle one with no knob, leave app's row first.
  echo 12 > "$NOTES_FIXTURE/busy"
  [ "$(picks_order)" = "ap-1 gm-9" ] || fail "busy pool: $(picks_order)"
  grep -q 'cc:pool_busy{pool=~"unity"} / cc:pool_slots{pool=~"unity"} < 0.5' "$NOTES_FIXTURE/curl.log" || fail "idle query: $(cat "$NOTES_FIXTURE/curl.log")"
  echo 3 > "$NOTES_FIXTURE/busy"
  [ "$(DISPATCH_CLASSES=/dev/null picks_order)" = "ap-1 gm-9" ] || fail "no knob: $(DISPATCH_CLASSES=/dev/null picks_order)"
  [ "$(picks_order)" = "gm-9 ap-1" ] || fail "idle pool: $(picks_order)"
  [[ "$(DRY=1 JUDGE_RC='' fill_day 1)" == *"gm-9 [idle pool unity,"* ]] || fail "why: $(DRY=1 JUDGE_RC='' fill_day 1)"
  # A real pick logs the term.
  DRY=0 JUDGE_RC='' fill_day 1
  [ -n "$(qitem queued gm-9)" ] || fail "gm-9 was not queued: $(ls "$AGENT_QUEUE_DIR/queued")"
  grep -q 'rank term idle pool unity: game human row gm-9' "$FLEET_DISPATCH_DIR/log.md" || fail "no rank-term log line: $(cat "$FLEET_DISPATCH_DIR/log.md")"
}

@test "idle pool rank: the term breaks ties inside one head of the feed rank (due, priority, #requested), above age, and moves no row past another head; with no pool idle the feed order stands" {
  # frank is head * 1e6 + created day (notes-cli Rank::key): head 19 #urgent, 21 #high, 23 #low, no due date.
  r() { jq -cn --arg k "$1" --arg p "$2" --argjson fr "$3" --arg pi "$4" \
        '{project: $p, stage: "beta", lane: "human", key: $k, frank: $fr} + (if $pi != "" then {pool_idle: $pi} else {} end)'; }
  rows=$(r ap-1 app 21020000 ''; r gm-9 game 21020010 unity; r gm-7 game 23019000 unity; r ap-2 app 19020020 ''; r ap-3 app 21020005 '')
  order() { jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")'; }
  assert_equal "$(order <<<"$rows")" "ap-2 gm-9 ap-1 ap-3 gm-7"
  # Negative control: no row on an idle pool, so the feed's own order.
  assert_equal "$(jq -c 'del(.pool_idle)' <<<"$rows" | order)" "ap-2 ap-1 ap-3 gm-9 gm-7"
}

@test "runnable: a board item is runnable while the human is here, red or plain, and counts from when it was queued" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug p --from board:game:p "plain"
  agent-queue add --project game --slug r --from board:game:r --tags 'red cause:ab12' "red one"
  stub fleet-presence 'echo here 0 x'
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | sort | tr '\n' ' ')" 'p r '
  assert_equal "$(jq -r 'select(.t == (.queued | fromdateiso8601)) | .slug' <<<"$output" | sort | tr '\n' ' ')" 'p r '
}

@test "a queue item runs /one-shot in bypass mode, a tier3 item behind the red-fix gate, a plan item in plan mode" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug n --tags tier3 "do n"
  agent-queue add --project game --slug p --mode plan "plan p"
  for s in a n p; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial "AGENT_QUEUE_ITEM=a ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode bypassPermissions"
  assert_output --partial '/one-shot do a'
  assert_output --partial '/one-shot do n'
  refute_output --partial -- '--pr-only'
  assert_output --partial 'This is tier 3 (harness or tooling)'
  assert_output --partial "AGENT_QUEUE_ITEM=p ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode plan --allow-dangerously-skip-permissions"
  refute_output --partial '/one-shot plan p'
  # An item with no board row still names itself in its PR body, and names no Task line.
  assert_output --partial 'The PR body carries the line "Item: a".'
}

@test "starved: an urgent or high item runnable over the limit with no run start in that time fails and names it; holds, low, new, a recent run start and a dispatch hold do not, a hand start does not clear it" {
  local old new ago2h
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  ago2h=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  queued_item fresh urgent "$new"
  queued_item low-old low "$old"
  # A dated tag a day out: an at:HH:MM tag is past its time for part of every day.
  queued_item tagged-old high "$old" "at:$(date -d '+1 day' +%Y-%m-%dT%H:%M)"
  queued_item after-old urgent "$old" '' never-done
  run cmd_starved
  assert_success
  assert_output ''
  queued_item stuck high "$old"
  . "$HOME/.local/lib/agent-proof.sh"; mkdir -p "$(proof_state_dir)/fleet-dispatch"
  [[ "$(proof_state_dir)" == "$HOME"/* || "$(proof_state_dir)" == "$SANDBOX"/* ]]   # never the live state dir
  echo '[t] outcome=NOOP load 30 on 24 cores is over the 0.7 pace' > "$(proof_state_dir)/fleet-dispatch/activity.log"
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  assert_output --partial 'last pass: [t] outcome=NOOP load 30'
  refute_output --partial 'fresh'
  refute_output --partial 'low-old'
  refute_output --partial 'tagged-old'
  refute_output --partial 'after-old'
  # A queue the passes are moving is not starved: a run start in the window clears it; a
  # redispatch or a hand start does not, since neither proves the run pass works.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (redispatch) for game: queue item x, resume 1\n' "$(date '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item other\n' "$ago2h" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_output --partial "last run start: $ago2h"
  printf -- '- %s started game-agent-2 on lab (hand) for game: queue item other2\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # The load gates are fleet-thermal's alarm, so they hold rather than starve; any other gate trips.
  run cmd_starved
  assert_failure
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (load 30.00 on'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
  # Load plus any other closed gate is not held by load: it still starves.
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:pace
  run cmd_starved
  assert_failure
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:ok
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  acct main:pace
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  acct main:ok
  stub agent-hold 'exit 1'
  run cmd_starved
  assert_success
  assert_output --partial 'dispatch is held'
}

# 2026-11-10: four human urgent items sat 2h behind an account over its weekly pace while run-floor
# starts kept `starved` silent: a run start in the window cleared everything.
@test "starved: an urgent item no pass started is named even when a run pass started another item in the window" {
  local old; old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  # Negative control: a high item the same fresh run start covers is not starved.
  queued_item moving high "$old"
  run cmd_starved
  assert_success
  assert_output ''
  queued_item stuck urgent "$old"
  acct main:pace
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (urgent'
  # A fresh urgent item is not yet starved.
  rm "$AGENT_QUEUE_DIR"/queued/*-stuck.md
  queued_item new-urgent urgent "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_starved
  assert_success
}

# 2026-11-22: an urgent item sat 100 min behind "starved pool:unity" while the probe's last pass named
# another item's run-floor start, so the gate holding it showed nowhere the watch reads (ar-3172).
@test "starved names the firing finding that holds each waiting item, none an urgent item goes past, and unreadable findings" {
  local old; old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck high "$old"
  queued_item rush urgent "$old"
  acct main:pace
  # Negative control: no finding fires, so no item carries a gate.
  findings
  run cmd_starved
  assert_failure
  assert_output --partial "stuck (high, queued $old)"
  refute_output --partial 'held by finding'
  findings "$(finding starved pool:unity)"
  run cmd_starved
  assert_failure
  assert_output --partial "stuck (high, queued $old, held by finding starved pool:unity)"
  # An urgent item goes past a starved pool (pool_pass), so the pool is not what holds it.
  assert_output --partial "rush (urgent, queued $old)"
  # A finding scoped to another repo holds nothing here.
  findings "$(finding starved pool:unity '["other-repo"]')"
  run cmd_starved
  assert_failure
  assert_output --partial "stuck (high, queued $old)"
  # Unreadable findings hold every item in a pass, and the probe says so.
  stub fleet-bench 'exit 1'
  run cmd_starved
  assert_failure
  assert_output --partial "stuck (high, queued $old, findings unreadable, which hold it)"
}

# 2026-11-10: the same four sat 4h, 2h of it under a dispatch hold that read as "nothing is starved" (ar-1432).
@test "starved: neither a dispatch hold nor load clears an urgent item from the human; an agent's urgent and a fresh one still read as held" {
  local old; old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  stub agent-hold 'echo "held: dispatch since 2026-11-10T09:00:00-0800 by binks: load 72.9; no new sessions"; exit 1'
  # Negative controls: an agent's urgent item and a fresh human one wait on the hold by design.
  queued_item agents urgent "$old"
  sed -i 's/^from: human/from: shepherd/' "$AGENT_QUEUE_DIR/queued/20261103-100000-agents.md"
  queued_item fresh urgent "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_starved
  assert_success
  assert_output --partial 'dispatch is held'
  queued_item mine urgent "$old"
  run cmd_starved
  assert_failure
  assert_output --partial "dispatch is held (agent-hold dispatch) by binks: load 72.9; no new sessions; the human's urgent items wait on it"
  assert_output --partial 'mine (urgent from the human'
  refute_output --partial 'agents'
  refute_output --partial 'fresh'
  # Load alone holds the agent's urgent item; the human's still trips.
  stub agent-hold 'exit 0'
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  rm "$AGENT_QUEUE_DIR"/queued/*-mine.md
  run cmd_starved
  assert_success
  assert_output --partial 'held by load'
  # An item with no from: line is the human's (agent-queue's default), and the load verdict is named.
  queued_item mine urgent "$old"
  sed -i '/^from: /d' "$AGENT_QUEUE_DIR/queued/20261103-100000-mine.md"
  run cmd_starved
  assert_failure
  assert_output --partial "held by load (load 30.00 on"
  assert_output --partial "the human's urgent items wait on it"
  assert_output --partial 'mine (urgent from the human'
}

@test "starved: a high item behind a fleet at its pace target is held, not starved, whatever gate is closed; one under it, a stale count, an urgent item or a standing hold starves" {
  local old; old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck high "$old"
  acct main:pace
  export DISPATCH_TARGET_PRESENT=3 DISPATCH_TARGET_AWAY=3
  fleet_state 3
  run cmd_starved
  assert_success
  assert_output --partial 'held by a full fleet (3 live sessions, the away pace target is 3)'
  # Negative control: one under the target the account gate binds, and the item starves.
  fleet_state 2
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  # A stale fleet state document reads no live count, so it holds nothing here.
  fleet_state 3 30
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  # A red item behind a full fleet starves: the red floor goes past the pace target.
  queued_item stuck-red high "$old" 'red cause:ab'
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck-red (high, red'
  rm "$AGENT_QUEUE_DIR"/queued/*-stuck-red.md
  fleet_state 3
  # A fresh ask behind a full fleet starves too: it may preempt like an urgent item (runs_now, ar-3468).
  queued_item stuck-ask high "$old" requested
  sed -i "s/^queued: /asked: $(date +%F)\nqueued: /" "$AGENT_QUEUE_DIR"/queued/*-stuck-ask.md
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck-ask (high, ask'
  # Negative control: asked before DISPATCH_ASK_FRESH_H, it is a high item and the full fleet holds it.
  sed -i "s/^asked: .*/asked: $(date -d '-3 days' +%F)/" "$AGENT_QUEUE_DIR"/queued/*-stuck-ask.md
  run cmd_starved
  assert_success
  rm "$AGENT_QUEUE_DIR"/queued/*-stuck-ask.md
  # A standing hold still trips at a full fleet, led by its Stopped line.
  fleet_state 3
  hold_for 125 'no account has room; main is the closest, 5 points over its weekly pace, queue item stuck waits'
  run cmd_starved
  assert_failure
  assert_line --index 0 --partial 'Dispatch stopped 2h05m: no account has room'
  rm "$HOME/.local/state/agentctl/fleet-dispatch/held_since"
  # An urgent item may preempt a runner session at a full fleet, so it still starves.
  queued_item hot urgent "$old"
  run cmd_starved
  assert_failure
  assert_output --partial 'hot (urgent'
}

@test "starved: a hold standing the limit trips it, led by the Stopped line, and a run start does not clear it; a younger hold or none does not" {
  queued_item fresh low "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  acct main:pace
  hold_for 30 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  run cmd_starved
  assert_success
  assert_output ''
  hold_for 125 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_line --index 0 'Dispatch stopped 2h05m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
  # A hold by load alone is fleet-thermal's alarm, as before.
  acct main:ok
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load'
  # Negative control: no hold, and the same run start clears it.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:pace
  rm "$HOME/.local/state/agentctl/fleet-dispatch/held_since"
  run cmd_starved
  assert_success
}

@test "stopped: a finding names its items without their pools, a long reason is cut at a clause, --json carries the line and the whole reason" {
  hold_for 90 'finding firing: dbs-7-boss (starved pool:other), house-sleep-dinner (starved pool:other), 5 more, every queue item waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: finding firing: dbs-7-boss, house-sleep-dinner, 5 more. Clears when its finding stops firing.'
  hold_for 3000 'no account has room; bnb is the closest, 98% of its week used, inside the last 15% kept for the human, and a great many more words that will not fit, runs out Fri 10:35 at this rate, queue item x waits'
  run cmd_stopped
  assert_failure
  [ "${#output}" -le 160 ] || fail "${#output} characters: $output"
  assert_output --partial 'Dispatch stopped 2d2h: no account has room; bnb is the closest, 98% of its week used'
  run cmd_stopped --json
  jq -e '.runner == "fleet-dispatch" and (.line | startswith("Dispatch stopped 2d2h")) and (.since | type == "number")' <<<"$output"
  # NEGATIVE CONTROL for the cut: the line is cut to 160, why is the whole reason, past the cut (ar-4985)
  run jq -r '.why, .clears' <<<"$output"
  assert_line 'no account has room; bnb is the closest, 98% of its week used, inside the last 15% kept for the human, and a great many more words that will not fit'
  assert_line 'Clears when an account is back under its pace'
}

@test "stopped: the human's agent-hold reads as held with its own reason and how to release it" {
  hold_for 120 'held (agent-hold dispatch) by dotfiles: human: until the next queue is set up, queue item x waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 2h00m: held by dotfiles: human: until the next queue is set up. Clears with agent-hold release dispatch.'
}

@test "stopped: every pass note ahead of the gate is dropped, and a judge budget stop alone clears at its reset" {
  hold_for 90 'could not judge the new rows (stopped at its budget); tagged 1 for a plan; no account has room; bnb is the closest, 4 points over its weekly pace, queue item x waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: no account has room; bnb is the closest, 4 points over its weekly pace. Clears when an account is back under its pace.'
  hold_for 90 'could not judge the new rows (the retry for 3 left-out row(s) stopped at its budget); no account has room; bnb is the closest'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: no account has room; bnb is the closest. Clears when an account is back under its pace.'
  hold_for 90 'budget: could not judge the new rows (stopped at its budget); tagged 1 for a plan; no new row to judge'
  run cmd_stopped
  assert_failure
  assert_output "Dispatch stopped 1h30m: budget: could not judge the new rows; no new row to judge. Clears when dispatch-judge's daily budget resets."
}

# 2026-11-06 (P3 live): with every account full and another source open, gate names no account, so each pass
# fleet-assess held too read "held by load" and queue-starved cleared five times under one hold.
@test "starved: an account hold under a load hold still starves while another source has room" {
  queued_item stuck high "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  route_ready
  srcs codex:ok:5
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  hold_for 125 'no account has room; alt is the closest, 4 points over its weekly pace'
  run gate
  assert_output 'fleet-assess says HOLD'
  run cmd_starved
  assert_failure
  assert_line --index 0 --partial 'Dispatch stopped 2h05m: no account has room'
  # Negative control: an account with room, and the same load hold is fleet-thermal's alarm.
  acct alt:ok:/home/u/.claude-personal
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
}

@test "stats: held_s is how long the hold has stood, 0 with none" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_stats
  assert_equal "$(jq -c .held_s <<<"$output")" 0
  hold_for 90 'fleet-assess says HOLD, queue item one waits'
  run cmd_stats
  jq -e '.held_s >= 5400 and .held_s < 5500' <<<"$output"
}

# 2026-11-05: 220 rows sat unjudged since 11-02 while every pass stopped at held queue items.
@test "starved: board rows nobody judged that long trip it, the human here or away; a recent judge or a full fleet does not" {
  game_ready
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  local p; for p in 'away 90 tmux' 'away 10 tmux' 'here 0 tmux'; do
    stub fleet-presence "echo '$p'"
    run cmd_starved
    assert_failure
    assert_output --partial '1 board rows unjudged, none judged since never'
  done
  # A fleet at its pace target never reaches the fill, so the rows wait on sessions finishing.
  acct main:pace
  export DISPATCH_TARGET_PRESENT=3 DISPATCH_TARGET_AWAY=3
  fleet_state 3
  run cmd_starved
  assert_success
  refute_output --partial 'unjudged'
  # Negative control: one under the target, and the same rows starve.
  fleet_state 2
  run cmd_starved
  assert_failure
  assert_output --partial '1 board rows unjudged'
  # A judge inside the window: the board is turning.
  verdict game human 'fix crash on load' dispatch
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"; mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_success
  # An old judge and an unjudged row: starved again.
  local judged; judged=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  touch -d "$judged" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_failure
  assert_output --partial "1 board rows unjudged, none judged since ${judged% *}"
}

@test "starved: a board item counts from when it was queued, the human here or away" {
  local old
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  board_item gm-1 "$old"
  local p; for p in 'here 0 tmux' 'away 5 tmux' 'away - none'; do
    stub fleet-presence "echo '$p'"
    run cmd_starved
    assert_failure
    assert_output --partial 'gm-1 (high'
  done
}

@test "starved: runnable under the low water with a row a pass would pick and no run start in twice the limit trips it; a recent start, low water 0 or nothing to pick does not" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial 'runnable 0 under the low water 3 with no run start since'
  assert_output --partial '1 board row(s) a pass would pick'
  DISPATCH_LOW_WATER=0 run cmd_starved
  assert_success
  # A run start 90 minutes ago: past the item limit but inside twice it, so the top-up is turning.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item x\n' "$(date -d '-90 min' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # Nothing a pass would pick: the row was judged a skip.
  verdict game human 'fix crash on load' skip
  run cmd_starved
  assert_success
}

@test "stats: the low water and whether runnable is under it" {
  local new
  new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item one high "$new"
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{low_water, under_low_water}' <<<"$output")" '{"low_water":3,"under_low_water":1}'
  DISPATCH_LOW_WATER=1 run cmd_stats
  assert_equal "$(jq -c '.under_low_water' <<<"$output")" 0
}

@test "stats: moves that follow a session, a start or the session's own park are not a flap; reap making one move twice is" {
  mkdir -p "$FLEET_DISPATCH_DIR"
  t() { date -d "-$1 minutes" '+%Y-%m-%d %H:%M'; }
  {
    # 11-10: a hand session asked, was answered, asked again, was answered: reap followed it each time.
    printf -- '- %s reaped game-agent-3: queue item asked running -> waiting\n' "$(t 50)"
    printf -- '- %s reaped game-agent-3: queue item asked waiting -> running\n' "$(t 40)"
    printf -- '- %s reaped game-agent-3: queue item asked running -> waiting\n' "$(t 30)"
    printf -- '- %s reaped game-agent-3: queue item asked waiting -> running\n' "$(t 20)"
    # Something put it back in running between reap's two moves to waiting.
    printf -- '- %s reaped game-agent-5: queue item undone running -> waiting\n' "$(t 45)"
    printf -- '- %s reaped game-agent-5: queue item undone running -> waiting\n' "$(t 35)"
    printf -- '- %s reaped game-agent-5: queue item undone waiting -> running\n' "$(t 25)"
    # A redispatch start sets running, and the session parking itself in review is its own move.
    printf -- '- %s reaped game-agent-6: queue item restarted running -> waiting\n' "$(t 48)"
    printf -- '- %s started game-agent-7 on lab (redispatch) for game: queue item restarted, resume 1\n' "$(t 44)"
    printf -- '- %s reaped game-agent-7: queue item restarted running -> waiting\n' "$(t 38)"
    printf -- '- %s reaped game-agent-7: queue item restarted waiting -> running\n' "$(t 33)"
    printf -- '- %s reaped game-agent-8: queue item parked waiting -> running\n' "$(t 42)"
    printf -- '- %s reaped game-agent-8: queue item parked review -> waiting\n' "$(t 32)"
    printf -- '- %s reaped game-agent-8: queue item parked waiting -> review\n' "$(t 22)"
  } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.reaped_1h, .flapping_items, .flapping]' <<<"$output")" '[13,1,["undone"]]'
}

@test "stats: runnable work and its age, reap moves in the last hour, flapping items" {
  local old new t
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck urgent "$old"
  queued_item low-new low "$new"
  queued_item after-old urgent "$old" '' never-done   # held by its after:, so not runnable
  mkdir -p "$FLEET_DISPATCH_DIR"
  t() { date -d "-$1 minutes" '+%Y-%m-%d %H:%M'; }
  {
    printf -- '- %s started game-agent-1 on lab (run) for game: queue item old\n' "$(t 120)"
    printf -- '- %s reaped game-agent-1: queue item old running -> waiting\n' "$(t 110)"
    printf -- '- %s started game-agent-2 on lab (run) for game: queue item a\n' "$(t 40)"
    printf -- '- %s started game-agent-3 on lab (hand) for game: queue item b\n' "$(t 30)"
    printf -- '- %s started game-agent-4 on lab (redispatch) for game: queue item c, resume 1\n' "$(t 20)"
    for m in 45 30 15; do printf -- '- %s reaped game-agent-3: queue item b running -> waiting\n' "$(t $m)"; done
    printf -- '- %s reaped game-agent-2: queue item a waiting -> running\n' "$(t 10)"
    printf -- '- %s reaped game-agent-9: session gone, queue item z done with PR 7\n' "$(t 5)"
  } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable, .runnable_urgent]' <<<"$output")" '[2,1]'
  # ar-2310: the starved verdict is the queue-starved watch's; recomputing it here cost 18s.
  jq -e 'has("starved") | not' <<<"$output"
  assert_equal "$(jq -c '[.reaped_1h, .flapping_items, .flapping]' <<<"$output")" '[5,1,["b"]]'
  # The oldest runnable item is the 2h one, give or take the test's own runtime.
  jq -e '.oldest_runnable_s >= 7190 and .oldest_runnable_s <= 7300 and .oldest_urgent_s == .oldest_runnable_s' <<<"$output"
  jq -e '.last_run_start_epoch != null' <<<"$output"
  # The whole queue rides along, as agent-queue counts it: 3 queued, and no hold count: gated work is a board row.
  assert_equal "$(jq -c '[.queued, .running, .waiting, has("held"), has("held_after")]' <<<"$output")" '[3,0,0,false,false]'
  jq -e '.done_6h == 0 and .added_6h == 3' <<<"$output"
  # Only numbers, booleans and the one list, so mqtt2prom keeps every fact it needs.
  assert_equal "$(jq -c '[to_entries[] | select(.value | type == "string")] | length' <<<"$output")" 0
}

@test "stats: a queue bigger than one argument may be still reads (the real one was 361 KB)" {
  local new i body
  new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  body=$(head -c 2000 /dev/zero | tr '\0' x)
  for i in $(seq 1 80); do queued_item "big-$i" low "$new"; printf '%s\n' "$body" >> "$AGENT_QUEUE_DIR/queued/20261103-100000-big-$i.md"; done
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  [ "$(agent-queue list --json --state queued | wc -c)" -gt 131072 ] || skip "agent-queue list --json no longer carries the body"
  run cmd_stats
  assert_success
  assert_equal "$(jq -r .runnable <<<"$output")" 80
}

@test "stats: runnable_urgent counts only urgent items a start would take: a gateway agent's is, high ones and chained ones are not" {
  local old
  old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item urgent-ok urgent "$old"
  queued_item urgent-chained urgent "$old" '' never-done
  queued_item high-a high "$old"
  queued_item high-b high "$old"
  queued_item urgent-gateway urgent "$old"
  sed -i 's/^agent: claude$/agent: opencode/' "$AGENT_QUEUE_DIR"/queued/*-urgent-gateway.md
  export DISPATCH_STARVED_MIN=100000
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high]' <<<"$output")" '[2,2]'
  jq -e '.oldest_urgent_s >= 10790 and .oldest_urgent_s <= 10900 and .oldest_high_s >= 10790 and .oldest_high_s <= 10900' <<<"$output"
  # No urgent item a start would take: none counted and no age, not the high ones' age.
  rm "$AGENT_QUEUE_DIR"/queued/*-urgent-ok.md "$AGENT_QUEUE_DIR"/queued/*-urgent-gateway.md
  run cmd_stats
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high, .oldest_urgent_s]' <<<"$output")" '[0,2,null]'
  jq -e '.oldest_high_s >= 10790' <<<"$output"
  # A fresh ask counts as urgent and not as high, since it runs now as one does (runs_now, ar-3468).
  sed -i "s/^queued: /asked: $(date +%F)\ntags: requested\nqueued: /" "$AGENT_QUEUE_DIR"/queued/*-high-a.md
  run cmd_stats
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high]' <<<"$output")" '[1,1]'
}

@test "promote: the promoted row leaves the candidates snapshot at once, every other row stays" {
  project game beta "$SANDBOX/repos/game"
  row game human 'urgent one' '- [ ] urgent one #urgent <!-- id:gm-7 -->'
  mkdir -p "${CANDIDATES%/*}"
  printf '%s\n' '{"project":"game","lane":"human","key":"gm-7"}' '{"project":"game","lane":"agent","key":"gm-7"}' \
    '{"project":"game","lane":"human","key":"gm-8"}' > "$CANDIDATES"
  touch -d '2026-11-09 08:07' "$CANDIDATES"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-7"}')" "" task
  assert_success
  assert_equal "$(jq -r '.lane + ":" + .key' "$CANDIDATES" | paste -sd' ')" "agent:gm-7 human:gm-8"
  assert_equal "$(date -r "$CANDIDATES" +%H:%M)" 08:07   # `as of` stays the pass's time
}

@test "stats: Board is the agent board and its backlog from notes board totals; an unreadable or older board leaves them out, never 0" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  notes() { echo '{"rows":[{"lane":"agent","state":"open"}],"totals":{"open":4,"doing":1,"human":1,"agent":2,"playtest":1,"backlog":3,"sprint":{"open":5,"committed":9}}}'; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{board_agent, board_backlog}' <<<"$output")" '{"board_agent":2,"board_backlog":3}'
  # Sprints are per project (the projects chip), and all-lane totals live on the hub: not on the feed.
  assert_equal "$(jq -c '[has("board_total"), has("board_sprint_open")]' <<<"$output")" '[false,false]'
  notes() { echo '{"rows":[{"lane":"agent","state":"open"}]}'; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c 'has("board_agent")' <<<"$output")" false
  notes() { return 1; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c 'has("board_agent")' <<<"$output")" false
}

@test "stats fails, saying so, when the queue is unreadable" {
  stub agent-queue 'exit 1'
  run cmd_stats
  assert_failure
  assert_output '{"error":"agent-queue unreadable"}'
}

@test "a queue start drops CLAUDE_AUTO_DROP_TOOLS from the launch env, unless the task names one, ultracode or /loop, or it is empty" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug plain "fix the menu"
  agent-queue add --project game --slug uc "ultracode the importer"
  agent-queue add --project game --slug lp "/loop 5m check the deploy"
  agent-queue add --project game --slug wf "run a Workflow over the PRs"
  for s in plain uc lp wf; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  agent-queue add --project game --slug off "fix the footer" && CLAUDE_AUTO_DROP_TOOLS='' cmd_start --item off >/dev/null || fail "start off"
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  # The default is claude-telemetry.sh's, the one list every automated start reads.
  assert_line --index 0 --partial "AGENT_QUEUE_ITEM=plain ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode"
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "only plain drops tools: $(cat "$NOTES_FIXTURE/cmds.log")"
  assert_line --index 4 --partial "AGENT_QUEUE_ITEM=off ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --session-id SID --permission-mode"
  # A value that is not a list of tool names never reaches the command line.
  agent-queue add --project game --slug bad "fix the header" >/dev/null
  CLAUDE_AUTO_DROP_TOOLS='Bash(rm:*);x' run cmd_start --item bad
  assert_output --partial 'CLAUDE_AUTO_DROP_TOOLS is not a comma list of tool names'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "a bad list reached the command line"
  # With the file that holds the list gone, a start says so and drops none.
  rm "$HOME/.config/shared-hooks/claude-telemetry.sh"
  agent-queue add --project game --slug gone "fix the sidebar" >/dev/null
  run cmd_start --item gone
  assert_output --partial 'claude-telemetry.sh is missing, so this start drops no tools'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "a start with no list file dropped tools"
}

@test "a task keeps the dropped tools only when it names one exactly: a CI task's workflow or artifacts drops them (ar-857)" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug ci "fix the tests.yml workflow and its workflow_dispatch input"
  agent-queue add --project game --slug art "purge gh-artifacts-nas, then Artifacts older than a week"
  agent-queue add --project game --slug wfs "list the Workflows that failed"
  agent-queue add --project game --slug wf "run a Workflow over the PRs"
  for s in ci art wfs wf; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial "AGENT_QUEUE_ITEM=ci ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID"
  assert_line --index 1 --partial "AGENT_QUEUE_ITEM=art ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID"
  assert_line --index 2 --partial "AGENT_QUEUE_ITEM=wfs ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID"
  # Negative control: the tool named as a word keeps every tool.
  assert_line --index 3 --partial "AGENT_QUEUE_ITEM=wf ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --session-id SID"
}

@test "with no DISPATCH_SANDBOX_PROFILE a start has no --settings and keeps the ambient GitHub token (control)" {
  sandbox_ready
  agent-queue add --project game --slug open "fix the menu"
  cmd_start --item open >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial '--settings'
  refute_output --partial 'GH_TOKEN'
}

@test "a sandboxed start passes the profile with every hard gate forced on, the git common dir writable, and no GitHub token" {
  sandbox_ready
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug closed "fix the menu"
  cmd_start --item closed >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial 'AGENT_QUEUE_ITEM=closed '
  assert_output --partial 'env -u GH_TOKEN -u GITHUB_TOKEN claude --model opus'
  common="$(cd "$SANDBOX/repos/game/.git" && pwd -P)"
  run jq -c '[.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowUnsandboxedCommands, .sandbox.network.strictAllowlist, .sandbox.filesystem.allowWrite]' <<<"$(launch_settings)"
  assert_output "[true,true,false,true,[\"~/.agent\",\"$common\"]]"
  run jq -r '.permissions.deny[]' <<<"$(launch_settings)"
  assert_line 'Bash(rm -rf /)'
  assert_line 'Read(~/.ssh/**)'
  assert_line 'Edit(//etc/fake-cred)'
  [ -n "$(qitem running closed)" ] || fail "the item did not start"
}

@test "DISPATCH_SANDBOX_GH_TOKEN_FILE gives the pane the token by file: its value is never on the launch line" {
  sandbox_ready
  printf 'scoped-token\n' > "$SANDBOX/lane.token"
  DISPATCH_SANDBOX_PROFILE=lane DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/lane.token"
  agent-queue add --project game --slug tok "fix the menu"
  cmd_start --item tok >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial "GH_TOKEN=\"\$(tr -d '[:space:]' < ${SANDBOX// /\\ }/lane.token)\" env -u GITHUB_TOKEN claude --model opus"
  refute_output --partial 'scoped-token'
  # The pane's shell can read it that way.
  run sh -c "$(grep -om1 'GH_TOKEN=.* env -u GITHUB_TOKEN' "$NOTES_FIXTURE/cmds.log") printenv GH_TOKEN"
  assert_output scoped-token
  # An unreadable token file refuses the start.
  DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/missing"
  agent-queue add --project game --slug tok2 "fix the footer"
  run cmd_start --item tok2
  assert_failure
  assert_output --partial 'is not a readable, non-empty file'
}

@test "a missing or malformed profile refuses the start: wt never runs and the item stays queued (negative control)" {
  sandbox_ready
  agent-queue add --project game --slug nope "fix the menu"
  DISPATCH_SANDBOX_PROFILE=absent
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'Refusing to run unsandboxed'
  assert_output --partial 'nothing started'
  printf '{"sandbox": {"filesystem": {"allowWrite": "~/.agent"}}}\n' > "$AGENTCTL_SANDBOX_DIR/bad.json"
  DISPATCH_SANDBOX_PROFILE=bad
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'not a valid profile'
  [ ! -e "$NOTES_FIXTURE/cmds.log" ] || fail "a session started without the sandbox it asked for"
  [ -n "$(qitem queued nope)" ] || fail "the item left the queue"
}

@test "a start on a harness that cannot enforce the profile is refused, not run open" {
  harness_ready
  sandbox_ready
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug cx "fix the menu"
  run cmd_start --item cx --harness codex --model sol
  assert_failure 2
  assert_output --partial "cannot enforce lane sandbox 'lane'"
  assert_not_called 'wt new'
}

@test "item_brief: a verify item starts on its own task and closes on proof, never a PR, whatever its title parses as" {
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "verify-gm-5-3", "mode": "oneshot", "project": "agent-runtime", "title": "check(ui): verify gm-5 ranked matches", "task": "Verify epic gm-5 on game.", "type": "check", "tags": "verify", "row": "game:gm-9", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 'Verify epic gm-5 on game.'
  assert_output --partial 'a verify row: it ends on live proof, never a PR or agent-land'
  assert_output --partial 'agent-queue set verify-gm-5-3 note="<proof>"; notes ptask game --agent done "gm-9" --proof "<proof>"; agent-queue move verify-gm-5-3 done --status ok'
  refute_output --partial '/one-shot'
  refute_output --partial 'red-fix gate'
  refute_output --partial 'already opened'
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$it" opencode
  assert_line --index 0 'Verify epic gm-5 on game.'
  refute_output --partial 'SKILL.md'
  # negative control: without the tag the same check item is a /one-shot that lands a PR
  run item_brief "${it/\"tags\": \"verify\", /}"
  assert_line --index 0 --partial '/one-shot'
}

@test "item_brief: a measure-only item, by its measure tag or a headline opening with re-measure, closes on proof, never a PR (ar-1079)" {
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "ar-793", "mode": "oneshot", "project": "agent-runtime", "title": "perf(claude): re-measure Claude Code startup after the ar-491 fix", "task": "Re-measure startup.", "type": "perf", "row": "game:ar-793", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 'Re-measure startup.'
  assert_output --partial 'a measure row: it ends on live proof, never a PR or agent-land'
  refute_output --partial '/one-shot'
  refute_output --partial 'red-fix gate'
  tagged='{"slug": "m", "mode": "oneshot", "project": "agent-runtime", "title": "perf(ci): the 24h numbers after #812", "task": "Read the window.", "type": "perf", "tags": "measure", "lane": "agent"}'
  run item_brief "$tagged"
  assert_line --index 0 'Read the window.'
  assert_output --partial 'a measure row: it ends on live proof'
  # Negative control: a perf fix that only names a measured number is still a /one-shot that lands a PR.
  run item_brief '{"slug": "p", "mode": "oneshot", "project": "agent-runtime", "title": "perf(ci): settle burst slots on measured load", "task": "Settle slots.", "type": "perf", "lane": "agent"}'
  assert_line --index 0 --partial '/one-shot'
}

@test "pr_line: an item with no PR names none, so its session is never told to check out PR null" {
  run pr_line '{"slug": "a", "pr": null}'
  assert_output ''
  run pr_line '{"slug": "a"}'
  assert_output ''
  run pr_line '{"slug": "a", "pr": "o/game#12"}'
  assert_output --partial 'already opened o/game#12'
}

@test "item_brief for claude-cloud names the Item and Task lines and leaves out local tooling" {
  run item_brief '{"slug": "cloud-fix", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}' claude-cloud
  assert_success
  assert_output --partial 'fix(game): x'
  assert_output --partial 'The PR body carries the line "Item: cloud-fix"'
  assert_output --partial 'Never merge it'
  refute_output --partial '/one-shot'
  refute_output --partial 'agent-land <N>'
}

@test "claude-cloud-run records the session URL, finds the PR by its exact Item line, and parks the item in review on it" {
  cloud_run_ready
  printf '%s\n' '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}, {"number": 8, "createdAt": "2099-01-01T00:00:00Z", "body": "Item: cloud-fix-extra"}, {"number": 9, "createdAt": "2099-01-01T00:00:00Z", "body": "text\r\nItem: cloud-fix\r\nmore"}]' > "$NOTES_FIXTURE/prs.json"
  run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_success
  assert_called 'claude --cloud do the task'
  assert_called 'gh pr list --repo acme/game --state all --search "Item: cloud-fix" in:body'
  f=$(qitem review cloud-fix)
  [ -n "$f" ] || fail "the item is not in review"
  assert_equal "$(qfield "$f" pr)" 'acme/game#9'
  grep -q 'https://claude.ai/code/session_01AbC' "$f" || fail "the session URL is not on the item"
}

@test "claude-cloud-run exits 1 at once when the create fails, and polls nothing" {
  cloud_run_ready
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"; exit 3'
  CLOUD_TIMEOUT_MIN=60 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_not_called 'gh pr list'
  grep -q 'create failed (exit 3)' "$(qitem running cloud-fix)" || fail "the item is not flagged"
}

@test "claude-cloud-run names a gh failure instead of reading it as no PR yet, and never takes an older PR" {
  cloud_run_ready
  gh_script 'echo "gh auth: not logged in" >&2; exit 1'
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_output --partial 'gh pr list failed: gh auth: not logged in'
  gh_script 'cat "$NOTES_FIXTURE/prs.json"'
  echo '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  [ -n "$(qitem running cloud-fix)" ] || fail "an older PR moved the item"
}

@test "claude-cloud-run past its timeout with no PR exits 1 and flags the item, which stays running" {
  cloud_run_ready
  echo '[{"number": 8, "body": "Item: other"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  f=$(qitem running cloud-fix)
  [ -n "$f" ] || fail "the item left running"
  grep -q 'opened no PR in 0 min' "$f" || fail "the item is not flagged"
}

@test "route keeps an excluded kind of work off a headless harness, pinned or not, and fails closed on an unreadable list" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES MATRIX=$HOME/.config/fleet-bench/matrix.json   # the sourced script read both before route_ready set them
  local it v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  v='{"candidates":[{"harness":"claude","model":"sonnet","fit":0},{"harness":"codex","model":"sol","fit":0}]}'
  ACCT_ROWS='{"accounts":[],"sources":[{"name":"codex","rank":1,"room":{"ok":true,"why":"it has room"}}]}'
  refused() { ! route "$1" "$v" || fail "routed to $ROUTE_HARNESS: $1"; assert_equal "$ROUTE_WHY" "$2"; }
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"deploy the new ingress"}' \
    "codex: runs headless, and this is deploy work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"rotate the SOPS key"}' \
    "codex: runs headless, and this is secrets work (excluded in $MATRIX); claude: no account has room"
  # A Unity stack item the human requested needs the editor; the tag counts as #requested.
  refused '{"slug":"x","project":"arena","mode":"oneshot","title":"the ball sticks to the wall","tags":"requested"}' \
    "codex: runs headless, and this is unity-editor work (excluded in $MATRIX); claude: no account has room"
  # Pinned is no way around it.
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix prod dns","agent":"codex","model":"sol"}' \
    "codex: runs headless, and this is prod work (excluded in $MATRIX)"
  # An item with no title is read by its task's first line, the headline every log uses.
  refused '{"slug":"x","project":"game","mode":"oneshot","task":"\n  kubectl apply the ingress\nmore"}' \
    "codex: runs headless, and this is deploy work (excluded in $MATRIX); claude: no account has room"
  # Live host ops: the 2026-11-10 Codex item that drained and deregistered 4 runners (its task's first line), deregister, systemctl.
  refused '{"slug":"x","project":"game","mode":"oneshot","task":"fix(ci): razer-laptop runners run 3-5x slow. Find the host cause or drain it."}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"deregister the razer runners from the org"}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"sudo systemctl --user restart the runner units on asus"}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  # Negative controls: near misses (product, not prod; a drain with no host or runner; systemctl status; unregister with no runner; the word null, which the
  # kind-less mode entries would match if they read as a "null" pattern), the same tag off the Unity stack, and plain work route to codex.
  # (codex holds unity_gate here, so the Unity item reaches the exclusion list this test is about.)
  harness_set '.harnesses.codex.capabilities = ["unity_gate"]'
  for it in '{"slug":"x","project":"game","mode":"oneshot","title":"fix the product page"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"fix(mem0): drain lines end in a backslash"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"show systemctl status of the runner in the panel"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"unregister the service worker on logout"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"a null kind prints as null in the menu"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"open the editor pane","tags":"requested"}' \
    '{"slug":"x","project":"arena","mode":"oneshot","title":"fix the menu sides"}'; do
    route "$it" "$v" || fail "refused ($ROUTE_WHY): $it"
    assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'codex sol'
  done
  # Claude takes excluded work as before.
  ACCT_RC=0
  route '{"slug":"x","project":"game","mode":"oneshot","title":"deploy the new ingress"}' "$v" || fail "claude refused: $ROUTE_WHY"
  assert_equal "$ROUTE_HARNESS" claude
  # An unreadable list keeps every headless harness off, never open.
  ACCT_RC=1 MATRIX="$SANDBOX/no-matrix.json"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu sides"}' \
    "codex: runs headless, and the exclusion list $SANDBOX/no-matrix.json is unreadable or has a bad match; claude: no account has room"
  # So does a `match` that is not a valid ERE: grep's error is not a miss.
  jq '.excluded[0].match = "(deploy"' "$HOME/.config/fleet-bench/matrix.json" > "$SANDBOX/bad-match.json"
  MATRIX="$SANDBOX/bad-match.json"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu sides"}' \
    "codex: runs headless, and the exclusion list $SANDBOX/bad-match.json is unreadable or has a bad match; claude: no account has room"
}

@test "route keeps a fleet worker's item and a sandboxed one on claude" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  local it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu"}' v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  v='{"candidates":[{"harness":"claude","model":"sonnet","fit":0},{"harness":"codex","model":"sol","fit":0}]}'
  ACCT_ROWS='{"accounts":[],"sources":[{"name":"codex","rank":1,"room":{"ok":true,"why":"it has room"}}]}'
  route "$it" "$v" || fail "nothing set: codex with room did not take it ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'codex sol'
  PLACE_HOST=razer-laptop HOST_KIT[razer-laptop]=claude   # the worker has claude, and lists no codex
  ! route "$it" "$v" || fail "a worker's item routed to $ROUTE_HARNESS"
  assert_equal "$ROUTE_WHY" 'codex: placed on razer-laptop, which does not run it (its kit and fleet_harnesses, fleet-dispatch hosts); claude: no account has room'
  # Negative control: a worker whose kit has no claude does not take the claude pick either.
  HOST_KIT[razer-laptop]=''
  ! route "$it" "$v" || fail "a kit-less worker's item routed to $ROUTE_HARNESS"
  assert_equal "$ROUTE_WHY" 'codex: placed on razer-laptop, which does not run it (its kit and fleet_harnesses, fleet-dispatch hosts); claude: placed on razer-laptop, which does not run it (fleet-dispatch hosts)'
  PLACE_HOST='' DISPATCH_SANDBOX_PROFILE=lane
  ! route "$it" "$v" || fail "a sandboxed item routed to $ROUTE_HARNESS"
  assert_equal "$ROUTE_WHY" "codex: it lacks the lane_sandbox capability (capabilities in $HARNESSES): no launcher applies a lane profile; claude: no account has room"
}

# A capability the map declares gates what route() hands a harness: a stack-bound one (unity_gate) gates the
# PR-opening kinds of that stack's projects, so a harness lacking it is refused and one listing it is not;
# adding a harness or a capability is a map entry, never code.
@test "route refuses a PR item of a capability's stack to a harness that lacks it, and takes it once the map lists it" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  local it='{"slug":"x","project":"arena","mode":"oneshot","title":"fix the arena menu"}' v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  v='{"candidates":[{"harness":"codex","model":"sol","fit":0},{"harness":"lazer-reserve","model":"sonnet","fit":1}]}'
  ACCT_ROWS='{"accounts":[],"sources":[{"name":"codex","rank":1,"room":{"ok":true,"why":"it has room"}},{"name":"reserve","rank":2,"room":{"ok":true,"why":"it has room"}}]}'
  route "$it" "$v" || fail "lazer-reserve lists unity_gate and was refused ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" lazer-reserve
  # codex lists none: it is refused with the map's why, and lazer-reserve takes it.
  assert_equal "$(harness_needs_why codex "$it" 1 0 || true)" "it lacks the unity_gate capability (capabilities in $HARNESSES): a unity PR needs the CI gate line"
  # A harness map entry is all it takes: listing it there lets codex take the item.
  harness_set '.harnesses.codex.capabilities = ["unity_gate"]'
  route "$it" "$v" || fail "codex lists unity_gate and was refused ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" codex
  # A project outside the stack needs nothing.
  harness_set '.harnesses.codex.capabilities = []'
  harness_needs_why codex '{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu"}' 1 0
  # A verify row only reports (kinds.json does not register it), so it needs no gate either.
  harness_needs_why codex '{"slug":"x","project":"arena","type":"verify","mode":"oneshot","title":"verify the arena menu"}' 1 0
  # A canary replays a merged PR and opens none, so it needs no gate.
  harness_needs_why codex '{"slug":"x","project":"arena","mode":"oneshot","title":"canary","tags":"canary","canary":"c1"}' 1 0
}

@test "an unreadable stack list fails the capability check closed" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES
  local it='{"slug":"x","project":"arena","mode":"oneshot","title":"fix the arena menu"}' rc=0 out
  printf 'not json\n' > "$HOME/.config/fleet-bench/matrix.json"
  out=$(harness_needs_why codex "$it" 1 0) || rc=$?
  assert_equal "$rc" 2
  assert_equal "$out" "the stack list $MATRIX is unreadable, so what arena needs is unknown"
}

@test "a metered harness is overflow: only a promoted class or its trial pick, only with no account room, only tier 1" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  local it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu"}' v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  ACCT_ROWS='{"accounts":[{"dir":"/home/u/.claude-personal","rank":1}],"sources":[{"name":"paid","rank":0.5,"room":{"ok":true,"why":"it has room"}}]}'
  # A plain fallback fit: paid has room and ranks first, but no score put it there.
  v='{"candidates":[{"harness":"claude","model":"opus","fit":0},{"harness":"paid","model":"glm","fit":1}]}'
  ! route "$it" "$v" || fail "an unscored paid fallback took the item"
  assert_equal "$ROUTE_WHY" 'claude: no account has room; paid: pay-per-use, so it takes only a class it was promoted for or its trial pick'
  # Promoted for the class, with no account room: the overflow takes it.
  v='{"promoted":["paid:glm"],"candidates":[{"harness":"paid","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":0}]}'
  route "$it" "$v" || fail "a promoted paid with room did not take the item ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'paid glm'
  # The trial pick counts the same.
  v='{"trial":"paid:glm","candidates":[{"harness":"paid","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":1}]}'
  route "$it" "$v" || fail "the paid trial pick did not take the item ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" paid
  # Negative control: an account with room takes it, though paid ranks first at the same fit.
  ACCT_RC=0
  v='{"promoted":["paid:glm"],"candidates":[{"harness":"paid","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":0}]}'
  route "$it" "$v" || fail "nothing set: claude with room did not take it ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" claude
  # Past tier 1 it waits rather than spend.
  ACCT_RC=1 it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu","tags":"tier2"}'
  ! route "$it" "$v" || fail "a tier-2 item went to paid"
  assert_equal "$ROUTE_WHY" 'paid: pay-per-use takes tier-1 work only, and this is tier 2; claude: no account has room'
  # A pinned item (a canary) is the human's pairing: none of this applies.
  it='{"slug":"x","project":"game","mode":"oneshot","title":"canary","agent":"paid","model":"glm","tags":"tier2"}'
  route "$it" '' || fail "a pinned paid item was refused ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" paid
}

@test "routing never lifts another gate: load holds it" {
  route_ready
  srcs codex:ok:5
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  refuses 'over the'
  assert_not_called 'agent-codex'
}

@test "the gate opens on another source's room, and with none says so" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES
  refuses 'no account has room; alt is the closest, 4 points over its weekly pace, and no other source has room'
  srcs codex:ok:5
  run gate
  refute_output --partial 'no account has room'
  # A source no harness spends opens nothing.
  srcs lazer:ok:5
  run gate
  assert_output --partial 'and no other source has room'
}

@test "hosts lists the roster with what a pass reads from each worker" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_success
  assert_equal "$(jq -r '"\(.name) \(.dest) \(.free) \(.why)"' <<<"$output")" 'razer-laptop kb@192.0.2.26 1 '
  assert_called 'ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 22 kb@192.0.2.26'
}

@test "hosts names the queued items no worker could take, heavy and plan ones too, and why" {
  # 2026-11-19: Razer sat idle while the board's work was in repos it had not cloned. A heavy
  # item and a plan item are placeable since ar-2891, so a repo no worker clones is their gap too.
  mkdir -p "$SANDBOX/repos/game" "$SANDBOX/repos/site"
  project game beta "$SANDBOX/repos/game"
  project site beta "$SANDBOX/repos/site"
  worker '2.0 16 1 50'
  queued_item in-game low "$(date -u +%FT%TZ)"
  for s in site-a site-b site-heavy site-plan; do
    queued_item "$s" low "$(date -u +%FT%TZ)"
    sed -i 's/^project: game$/project: site/' "$(qitem queued "$s")"
  done
  sed -i 's/^mode: oneshot$/&\nweight: heavy/' "$(qitem queued site-heavy)"
  sed -i 's/^mode: oneshot$/&\nplan: p.md/' "$(qitem queued site-plan)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  assert_output --partial "unplaceable: site, 4 queued items: no worker clones $SANDBOX/repos/site"
  # Negative control: the item in a repo the worker clones is placeable, so no line names game.
  refute_output --partial 'unplaceable: game'
  # A harness no worker runs is the other reason; --json stays one row per worker.
  sed -i 's/^agent: claude$/agent: codex/' "$(qitem queued in-game)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'unplaceable: game, 1 queued item: no worker runs codex ready'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  refute_output --partial unplaceable
  # A codex item that resumes its thread here (its rollout is in this machine's ~/.codex) stays
  # here by design, so it is no gap (host_agent).
  jq -n '{harnesses: {codex: {source: "codex", end_classifier: "codex", headless: true, resume: true, timeout_min: 120, models: {sol: "gpt-6.1-sol"}}}}' > "$SANDBOX/harnesses.json"
  export DISPATCH_HARNESSES="$SANDBOX/harnesses.json"
  codex_ran in-game th-1
  [ -f "$(qitem queued in-game)" ]
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  refute_output --partial 'unplaceable: game'
  assert_output --partial 'unplaceable: site'
}

@test "a worker whose probe finds no checkout of a repo it lists takes no item of it, and hosts says so" {
  # 2026-11-24 (ar-5245): razer-laptop listed unity-core-playground but never cloned it, so every pass placed
  # an item there and its wt died with "not a directory", leaving the item queued for the next pass.
  mkdir -p "$SANDBOX/repos/game"
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  queued_item in-game low "$(date -u +%FT%TZ)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  refute_output --partial unplaceable
  refute_output --partial 'no checkout'
  echo "$SANDBOX/repos/game" > "$NOTES_FIXTURE/ssh.missing"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  assert_output --partial "unplaceable: game, 1 queued item: razer-laptop lists $SANDBOX/repos/game but has no checkout there"
  assert_output --partial "; no checkout of $SANDBOX/repos/game"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_equal "$(jq -r '.missing[0]' <<<"$output")" "$SANDBOX/repos/game"
}

@test "hosts counts a worker's Claude items past the reap grace with no transcript as stuck at start" {
  # 2026-11-18: 27 sessions sat on razer-laptop's first-run screen for hours and nothing paged.
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  remote_item working; sed -i 's/^session: .*/&\nsessions: aaa-1 aaa-2\naccount: .claude-bnb/' "$(qitem running working)"
  remote_item picker;  sed -i 's/^session: .*/&\nsessions: bbb-1\naccount: main/' "$(qitem running picker)"
  remote_item booting; sed -i "s/^started: .*/started: $(date -u +%FT%TZ)/; s/^session: .*/&\nsessions: ccc-1/" "$(qitem running booting)"
  remote_item plain;   sed -i 's/^session: .*/&\nsessions: ddd-1/' "$(qitem running plain)"
  # The worker's home: the stub ssh runs each command here. claude-acct link makes an account's
  # projects a link to main's, so find must follow it. The item with no account has had its turn.
  mkdir -p "$HOME/.claude/projects/-w" "$HOME/.claude-bnb"
  ln -s "$HOME/.claude/projects" "$HOME/.claude-bnb/projects"
  : > "$HOME/.claude/projects/-w/aaa-2.jsonl"
  : > "$HOME/.claude/projects/-w/ddd-1.jsonl"
  cd "$HOME"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_success
  assert_equal "$(jq -r .stuck <<<"$output")" 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial '1 stuck at start'
  # Once it writes its transcript it is not stuck; a worker that does not answer is unknown, not 0.
  : > "$HOME/.claude/projects/-w/bbb-1.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_equal "$(jq -r .stuck <<<"$output")" 0
  echo 255 > "$NOTES_FIXTURE/ssh.rc"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_equal "$(jq -r .stuck <<<"$output")" null
}

@test "a worker gone from the roster cannot answer for its item, so reap settles it by its PR" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  remote_item fix-crash
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  sed -i 's/^\( *\)razer-laptop:$/\1other-laptop:/' "$FLEET_INVENTORY"; unset FLEET_HOSTS_JSON
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "held an item whose host left the roster"
}

@test "focus: candidates keep every project's rows, and suggest names no focus hold" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'game row' "- [ ] game row $T"
  row app agent 'app row' "- [ ] app row $T"
  row app agent 'app asked' "- [ ] app asked #requested $T"
  # Negative control: with no focus, every row is a candidate too.
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'app asked,app row,game row'
  focus_on game
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'app asked,app row,game row'
  SUGGEST=1 run cmd_candidates
  assert_equal "$(jq -r 'select(.key == "app row") | .off // ""' <<<"$output")" ''
}

@test "focus: a focus project ranks nothing: the more urgent row elsewhere goes first, and why names no project" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  focus_on game
  row app agent 'app asked' "- [ ] app asked #requested #urgent $T"
  row game agent 'game row' "- [ ] game row #low $T"
  ranked app agent 'app asked' "$(fk 3 0 0)"
  ranked game agent 'game row' "$(fk 3 2 1)"
  run cmd_candidates
  assert_success
  run jq -sr "$RANK_JQ"'rank[] | "\(.key): \(.why)"' <<<"$output"
  assert_line --index 0 --partial 'app asked: '
  assert_line --index 1 --partial 'game row: '
  refute_output --partial 'project'
}

@test "focus: promote tags a #requested row's item requested, which puts it in the requested class" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row app human 'asked one' '- [ ] asked one #requested <!-- id:gm-7 -->'
  row app human 'plain one' '- [ ] plain one <!-- id:gm-8 -->'
  row app human 'asked two' '- [ ] asked two #requested <!-- id:gm-9 -->'
  focus_on game
  for k in 7 8; do
    run promote "$(jq -cn --arg k "gm-$k" '{profile: "bnb", project: "app", lane: "human", key: $k}')" "" task
    assert_success
  done
  run promote "$(jq -cn '{profile: "bnb", project: "app", lane: "human", key: "gm-9"}')" requested task
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-7)" tags)" requested
  assert_equal "$(qfield "$(qitem queued gm-8)" tags)" ''
  assert_equal "$(qfield "$(qitem queued gm-9)" tags)" requested
  run agent-queue list --json --state queued
  assert_equal "$(jq -r 'select(.slug == "gm-8") | .hold // "none"' <<<"$output")" none
}

@test "focus: a focus with no work does not trip starved" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project app --slug a1 --priority low "app work" >/dev/null
  focus_on game
  run cmd_starved
  assert_success
  refute_output --partial 'focus:'
}

@test "focus: headroom names the focus and counts the runnable items it has; stats publishes the project count" {
  two_items
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -c '[.focus, .focus_runnable, .runnable]' <<<"$output")" '[[],0,2]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  refute_output --partial 'focus:'
  focus_on game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -c '[.focus, .focus_runnable, .runnable]' <<<"$output")" '[["game"],1,2]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'focus:     game, whose release windows run as sprints; 1 runnable item(s) of it'
  run cmd_stats
  assert_equal "$(jq -c '[.focus_projects, has("held_focus")]' <<<"$output")" '[1,false]'
}

@test "pass order: the reds the red floor has slots for, then the short items, then reds past the floor and cleanup" {
  local items
  items=$(printf '%s\n' '{"slug":"r1","tags":"red"}' '{"slug":"w1","tags":"red watch"}' '{"slug":"r2","tags":"red"}' \
    '{"slug":"c1","tags":"cleanup tier3"}' '{"slug":"u1","tags":"","short":true}' '{"slug":"u2","short":true}')
  red_floor_slots() { echo 2; }
  assert_equal "$(pass_order "$items" | jq -r .slug | tr '\n' ' ')" 'w1 r1 u1 u2 r2 c1 '
  # No red floor slot (DISPATCH_RED_FLOOR=0, or the floor full): the short items lead every red.
  red_floor_slots() { echo 0; }
  assert_equal "$(pass_order "$items" | jq -r .slug | tr '\n' ' ')" 'u1 u2 r1 w1 r2 c1 '
  # Negative control: with no short item and no slot the order is agent-queue's.
  assert_equal "$(pass_order "$(jq -c 'del(.short)' <<<"$items")" | jq -r .slug | tr '\n' ' ')" 'r1 w1 r2 c1 u1 u2 '
  assert_equal "$(pass_order '')" ''
}

@test "pass order: the human's urgent item keeps its place ahead of the short items; an urgent red past the floor does not" {
  local items
  items=$(printf '%s\n' '{"slug":"r1","tags":"red","priority":"urgent"}' '{"slug":"r2","tags":"red","priority":"urgent"}' \
    '{"slug":"h1","priority":"urgent"}' '{"slug":"u1","short":true}' '{"slug":"c1","tags":"cleanup"}')
  red_floor_slots() { echo 1; }
  assert_equal "$(pass_order "$items" | jq -r .slug | tr '\n' ' ')" 'r1 h1 u1 r2 c1 '
  # Negative control: h1 at high is no runs_now item, so the short item goes ahead of it.
  assert_equal "$(pass_order "$(jq -c 'if .slug == "h1" then .priority = "high" else . end' <<<"$items")" | jq -r .slug | tr '\n' ' ')" 'r1 u1 r2 h1 c1 '
  # Input jq cannot read is named and passed on in queue order, never dropped.
  run pass_order 'not json'
  assert_output --partial 'pass_order: jq could not read'
  assert_output --partial 'not json'
}

@test "pass order: a run pass fills a short class's gap ahead of a red past the red floor and a cleanup row" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  export DISPATCH_RED_FLOOR=1 DISPATCH_PER_PASS=2
  agent-queue add --project app --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project app --slug r2 --tags 'red cause:b' "fix r2" >/dev/null
  agent-queue add --project app --slug c1 --priority high --tags 'cleanup tier3' "chore: c1" >/dev/null
  agent-queue add --project game --slug g1 --priority low "game g1" >/dev/null
  # Negative control first: no minimum, so the pass's two starts go in agent-queue's order, reds first.
  short_game_classes 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_equal "$(grep -o 'would start queue item [a-z0-9]*' <<<"$output" | tr '\n' ' ')" 'would start queue item r1 would start queue item r2 '
  short_game_classes 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item r1'
  assert_output --partial 'started queue item g1'
  refute_output --partial 'started queue item r2'
  refute_output --partial 'started queue item c1'
}

@test "pass order: a short class's item starts past the weekly pace alone; a plain item waits" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  acct alt:pace:/home/u/.claude-personal
  export DISPATCH_RUN_FLOOR=0 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  agent-queue add --project app --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug g1 --priority low "game g1" >/dev/null
  # Negative control first: the class at its minimum, so the weekly pace holds every item.
  short_game_classes 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
  short_game_classes 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'the items of a class under its classes.json min_live start past the weekly pace'
  assert_output --partial 'started queue item g1 on the class floor, past the weekly pace'
  refute_output --partial 'started queue item p'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "pass order: the class floor lifts the pace reason alone: the reserve, the 5h window, committed burn and load still hold" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_RUN_FLOOR=0 DISPATCH_RED_FLOOR=0
  short_game_classes 1
  agent-queue add --project game --slug g1 --priority low "game g1" >/dev/null
  for r in pace,five_hour pace,committed reserve,pace; do
    acct "alt:$r:/home/u/.claude-personal"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_output --partial 'no account has room; alt is the closest'
    assert_not_called 'wt new'
  done
  acct alt:pace:/home/u/.claude-personal
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'is over the'
  assert_not_called 'wt new'
}

# stale_fixture -- game agent rows skipped (DISPATCH_TODAY 2026-11-26, DISPATCH_STALE_DAYS 14): sx-1 #high since
# 11-01 (judged again 11-20 on the same text), sx-2 #low since 11-01, sx-3 #low since 11-01 that sx-7 gates
# #after/ on, sx-4 skipped 11-01 on older text and 11-20 on this one, sx-5 #low edited since its skip, sx-6
# #plan, sx-7 gated on sx-3, sx-8 a parent of open sx-9, sx-9 dispatched 11-01
stale_fixture() {
  printf '%s\n' '- (needs-person) a device run' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TODAY=2026-11-26
  row game agent sx-1 "- [ ] fix(game): crash on load #high $T <!-- id:sx-1 -->"
  row game agent sx-2 "- [ ] chore(game): tidy the menu #low $T <!-- id:sx-2 -->"
  row game agent sx-3 "- [ ] chore(game): rename the scene #low $T <!-- id:sx-3 -->"
  row game agent sx-4 "- [ ] fix(game): rewritten row $T <!-- id:sx-4 -->"
  row game agent sx-5 "- [ ] chore(game): edited row #low $T <!-- id:sx-5 -->"
  row game agent sx-6 "- [ ] fix(game): waits on its plan #plan $T <!-- id:sx-6 -->"
  row game agent sx-7 "- [ ] fix(game): after the rename #after/sx-3 $T <!-- id:sx-7 -->"
  row game agent sx-8 "- [ ] feat(game): the parent $T <!-- id:sx-8 -->"
  row game agent sx-9 "- [ ] fix(game): a child #of/sx-8 $T <!-- id:sx-9 -->"
  local k
  for k in sx-1 sx-2 sx-3 sx-5 sx-6 sx-7 sx-8; do skipv "$k" unclear 'which scene is meant'; done
  skipv sx-4 needs-person 'needs a device'
  verdict game agent sx-9 dispatch
  # sx-1 judged again on the same text on 11-20; sx-4 skipped on 11-01 on an older text, then on its own on 11-20
  jq -c --arg old 2026-11-01T09:00:00-08:00 --arg new 2026-11-20T09:00:00-08:00 '
    if .key == "sx-4" then (.line = "oldtext" | .at = $old), (.at = $new)
    elif .key == "sx-1" then (.at = $old), (.at = $new) else .at = $old end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  sed -i 's/edited row/edited row, now clear/' "$NOTES_FIXTURE/rows.game.agent"
  stub agent-ask 'printf "%s\n" "agent-ask $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" = post ] && echo "ask-$(grep -c "^agent-ask post" "$NOTES_FIXTURE/calls.log")"; exit 0'
}

@test "ask_stale_skips: a skip held 14 days asks about a #high row or a #low one another row gates on, and keeps a #low one in improvements.md and drops it" {
  # NEGATIVE CONTROL: before ar-2933 nothing revisited a skip, so all three sat on the board for good.
  stale_fixture
  run ask_stale_skips --dry-run
  assert_success
  assert_output "$(printf 'ask\tgame\tsx-1\tunclear\t25\ndrop\tgame\tsx-2\tunclear\t25\nask\tgame\tsx-3\tunclear\t25\nstale: ask 2 drop 1')"
  run ask_stale_skips
  assert_success
  assert_line 'asked about game: sx-1 (skipped 25 days, unclear, ask ask-1)'
  assert_line 'dropped game: sx-2 to improvements.md (skipped 25 days, unclear)'
  assert_line 'asked about game: sx-3 (skipped 25 days, unclear, ask ask-2)'
  local post; post=$(grep '^agent-ask post' "$NOTES_FIXTURE/calls.log" | head -1)
  [[ $post == *'--kind gate --project game'* ]] || fail "not a gate for game: $post"
  [[ $post == *"start=start the row as it reads now, past the judge's skip|drop=drop the row from the board"* ]] || fail "options: $post"
  [[ $post == *'skipped it since 2026-11-01 (unclear: which scene is meant)'* ]] || fail "context: $post"
  [[ $post == *'Keep board row sx-1, which dispatch has skipped for 25 days?'* ]] || fail "question: $post"
  grep -q '#ask/ask-1/start <!-- id:sx-1 -->' "$NOTES_FIXTURE/rows.game.agent" || fail "sx-1 not gated on its ask"
  grep -q 'improve game --why dispatch skipped it (unclear: which scene is meant) for 25 days.* -- chore(game): tidy the menu #low' "$NOTES_FIXTURE/calls.log" || fail "sx-2 not kept in improvements.md"
  grep -q 'ptask game --agent drop sx-2 --why kept in game improvements.md: dispatch skipped it' "$NOTES_FIXTURE/calls.log" || fail "sx-2 not dropped with its why"
  # each asked row is gated now, so a second pass asks nothing again
  run ask_stale_skips --dry-run
  assert_output 'stale: '
}

@test "ask_stale_skips: a row fleet-bench triage filed by key is never asked about or dropped, however old its skip (ar-6265)" {
  stale_fixture
  row game agent sx-10 "- [ ] check(watch): board-chain tripped since 2026-11-05, expected: x #high $T <!-- id:sx-10 -->"
  row game agent sx-11 "- [ ] fix(hold): briefing went red #low $T <!-- id:sx-11 -->"
  skipv sx-10 needs-person 'Watch pages the human'; skipv sx-11 unclear 'which hold'
  jq -c 'if (.key | IN("sx-10", "sx-11")) then .at = "2026-11-01T09:00:00-08:00" else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run ask_stale_skips --dry-run
  assert_success
  refute_output --partial 'sx-10'
  refute_output --partial 'sx-11'
  # NEGATIVE CONTROL: the fixture's plain stale rows are still asked about or dropped
  assert_output --partial "$(printf 'ask\tgame\tsx-1\tunclear\t25')"
  assert_output --partial "$(printf 'drop\tgame\tsx-2\tunclear\t25')"
}

@test "ask_stale_skips: DISPATCH_STALE_MAX caps a day, DISPATCH_STALE_DAYS 0 is off, and a failed gate cancels the ask" {
  stale_fixture
  DISPATCH_STALE_DAYS=0 run ask_stale_skips
  assert_output ''
  run grep -c '^agent-ask' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  mv "$SANDBOX/bin/notes" "$SANDBOX/bin/notes-real"
  stub notes '[[ " $* " == *" tag "* ]] && exit 1; exec notes-real "$@"'
  DISPATCH_STALE_MAX=1 run ask_stale_skips
  assert_success
  assert_output --partial 'ask_stale_skips: could not gate game agent row sx-1 on ask ask-1'
  grep -q '^agent-ask cancel ask-1' "$NOTES_FIXTURE/calls.log" || fail "ask not cancelled"
  run grep -c '^agent-ask post' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # the cap is the day's: the failed try counted, so a second pass today tries nothing
  DISPATCH_STALE_MAX=1 run ask_stale_skips
  assert_output ''
  run grep -c '^agent-ask post' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}
