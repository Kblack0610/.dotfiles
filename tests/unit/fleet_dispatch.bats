#!/usr/bin/env bats
# fleet-dispatch: which rows may start an unattended session, and the bookkeeping around it.
# Everything that could launch, claim or judge is a stub; calls.log records what it would do.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_DISPATCH_DIR="$HOME/.agent/dispatch"
  export DISPATCH_PROFILES=bnb DISPATCH_SERVER=lab
  export DISPATCH_PROJECT_MAP="$SANDBOX/map.json"
  export DISPATCH_POLICY="$SANDBOX/policy.md"
  export DISPATCH_LOADAVG="$SANDBOX/loadavg"
  export DISPATCH_JUDGE_CMD=judge-stub   # on PATH: the command is a word list, and the sandbox path has a space
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  echo 'policy' > "$DISPATCH_POLICY"
  mkdir -p "$SANDBOX/repos/game" "$SANDBOX/repos/app" "$SANDBOX/sheets"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub_notes
  stub agent-hold 'exit 0'
  stub fleet-assess 'exit 0'
  stub wave-lock 'exit 1'
  stub model-lane 'echo "{\"dispatch_model\":\"opus\"}"'
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  stub judge-stub 'echo "judge called" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# A notes stand-in with state: rows.<project>.<lane> holds "key<TAB>raw line", and `start`
# toggles the first open row whose key contains the query, as the real CLI does.
stub_notes() {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
F="$NOTES_FIXTURE"; printf 'notes %s\n' "$*" >> "$F/calls.log"
args=(); lane=human
while [ $# -gt 0 ]; do
  case "$1" in --profile) shift 2 ;; --agent) lane=agent; shift ;; *) args+=("$1"); shift ;; esac
done
case "${args[0]}" in
  projects) cat "$F/projects" 2>/dev/null ;;
  ptask)
    p="${args[1]}"; f="$F/rows.$p.$lane"; [ -f "$f" ] || exit 0
    case "${args[2]}" in
      list) awk -F'\t' -v f="$f" '$2 ~ /^- \[[ \/]\]/ { print f "\t" NR "\t" $1 "\t" $2 }' "$f" ;;
      start) q="${args[3]}"
        awk -F'\t' -v OFS='\t' -v q="$q" '!done && index($1, q) && $2 ~ /^- \[[ \/]\]/ {
            if ($2 ~ /^- \[ \]/) sub(/^- \[ \]/, "- [/]", $2); else sub(/^- \[\/\]/, "- [ ]", $2); done = 1 }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
    esac ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
}

# project <name> <stage> <repo-dir|-> : a sheet, a registry entry, and a projects line
project() {
  printf 'Version: v1.0.0 #%s\n' "$2" > "$SANDBOX/sheets/$1.md"
  printf '%s\t%s\t\tv1.0.0\n' "$1" "$SANDBOX/sheets/$1.md" >> "$NOTES_FIXTURE/projects"
  local m='{"trackers":{},"paths":{}}'; [ -f "$DISPATCH_PROJECT_MAP" ] && m=$(cat "$DISPATCH_PROJECT_MAP")
  if [ "$3" = - ]; then
    jq --arg p "$1" '.trackers[$p] = {repo: null}' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  else
    jq --arg p "$1" --arg d "$3" '.trackers[$p] = {repo: $p} | .paths[$d] = $p' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  fi
}

row() { printf '%s\t%s\n' "$3" "$4" >> "$NOTES_FIXTURE/rows.$1.$2"; }

verdict() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg p "$1" --arg l "$2" --arg k "$3" --arg v "$4" --arg s "${5:-S}" \
    '{project: $p, lane: $l, key: $k, verdict: $v, size: $s, clear: true, agent_only: true, reason: "r"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

# --- candidates --------------------------------------------------------------------------

@test "candidates: draft and notes-only projects, started rows and judged rows are left out" {
  project game beta "$SANDBOX/repos/game"
  project idea draft "$SANDBOX/repos/app"
  project notesonly prod -
  row game human 'fix crash' '- [ ] fix crash #high'
  row game human 'taken row' '- [/] taken row'
  row game agent 'judged row' '- [ ] judged row'
  row idea human 'draft row' '- [ ] draft row'
  row notesonly human 'paper row' '- [ ] paper row'
  verdict game agent 'judged row' skip

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
  assert_equal "$(jq -r '"\(.stage) \(.lane) \(.prio) \(.repo)"' <<<"$output")" "beta human 1 $SANDBOX/repos/game"
}

@test "candidates: a project whose wave lock is held is left alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  stub wave-lock 'exit 0'
  run cmd_candidates
  assert_output ''
}

@test "candidates: a project with a live dispatched session is left alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [ ] fix crash'
  mkdir -p "$FLEET_DISPATCH_DIR/live"
  printf 'project=game\n' > "$FLEET_DISPATCH_DIR/live/game-agent-3"
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_candidates
  assert_output ''
}

# --- picks -------------------------------------------------------------------------------

@test "picks: only small, clear, agent-only dispatch verdicts, one per project, urgent then prod first" {
  c() { jq -cn --arg p "$1" --arg s "$2" --arg k "$3" --argjson pr "$4" \
        '{profile: "bnb", project: $p, stage: $s, lane: "human", key: $k, prio: $pr}'; }
  cands=$(c alpha1 alpha a 0; c beta1 beta b 1; c beta1 beta b2 1; c prod1 prod p 1; c skipme prod s 0; c big prod L 0)
  verdict alpha1 human a dispatch
  verdict beta1 human b dispatch
  verdict beta1 human b2 dispatch
  verdict prod1 human p dispatch
  verdict skipme human s skip
  verdict big human L dispatch M        # a dispatch verdict on a medium row still does not launch

  run picks "$cands" 3
  assert_success
  assert_equal "$(jq -r .project <<<"$output" | paste -sd' ')" 'alpha1 prod1 beta1'
}

@test "picks: no room means no picks" {
  verdict game human k dispatch
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1}' 0
  assert_output ''
}

# --- judge -------------------------------------------------------------------------------

@test "judge keeps well-formed verdicts between the markers and drops the rest" {
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
thinking out loud {"project":"x"}
DISPATCH-VERDICTS-START
{"project":"game","lane":"human","key":"fix crash","size":"S","clear":true,"agent_only":true,"verdict":"dispatch","reason":"small bug"}
not json
{"project":"game","lane":"human","key":"other","verdict":"maybe"}
DISPATCH-VERDICTS-END
EOF
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash"}'
  assert_success
  assert_equal "$(wc -l < "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 1
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl")" dispatch
}

@test "judge fails loudly when the model returns no verdicts at all" {
  echo 'UserPromptSubmit operation blocked by hook' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  assert_failure
  assert_output --partial 'no verdicts for 1 row(s)'
}

@test "judge sends prod rows before alpha rows when the batch is capped" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" DISPATCH-VERDICTS-START "{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\"}" DISPATCH-VERDICTS-END'
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":2}'
  assert_success
  run grep -c '"project":"p"' "$NOTES_FIXTURE/prompt"
  assert_output 1
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 0
}

# --- run ---------------------------------------------------------------------------------

game_ready() {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash on load' '- [ ] fix crash on load #high'
  verdict game human 'fix crash on load' dispatch
}

@test "run --dry-run names the pick and launches, claims and records nothing" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would start: game (beta) human: fix crash on load'
  assert_not_called 'wt new'
  assert_not_called 'start fix crash'
  [ ! -d "$FLEET_DISPATCH_DIR/live" ] || [ -z "$(ls "$FLEET_DISPATCH_DIR/live")" ] || fail "dry run wrote a ledger"
}

@test "run starts the row, opens a detached lab session, tags it and writes the ledger" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1'
  assert_called 'ptask game start fix crash on load'
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_called 'tmux -L lab set-option -t =game-agent-1 @dispatch game: fix crash on load'
  assert_equal "$(sed -n 's/^key=//p' "$FLEET_DISPATCH_DIR/live/game-agent-1")" 'fix crash on load'
}

@test "run claims a row at the top of a board too big for one pipe buffer" {
  game_ready
  # A real board: grep -q stops at the first line while notes is still writing the rest.
  awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "filler row %d\t- [ ] filler row %d padded to make the board larger\n", i, i }' \
    >> "$NOTES_FIXTURE/rows.game.human"
  run launch "$(jq -cn --arg r "$SANDBOX/repos/game" '{profile: "bnb", project: "game", stage: "beta",
    lane: "human", key: "fix crash on load", text: "- [ ] fix crash on load #high", repo: $r, prio: 1}')"
  assert_success
  assert_output --partial 'started game-agent-1'
}

@test "run starts nothing while dispatch is held" {
  game_ready
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held'
  assert_not_called 'wt new'
}

@test "run starts nothing over the load pace" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over the'
  assert_not_called 'wt new'
}

@test "run starts nothing once the live cap is reached" {
  game_ready
  export DISPATCH_MAX_LIVE=1
  mkdir -p "$FLEET_DISPATCH_DIR/live"
  printf 'project=other\n' > "$FLEET_DISPATCH_DIR/live/other-agent-1"
  printf 'other-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'live dispatched sessions'
  assert_not_called 'wt new'
}

# --- reap --------------------------------------------------------------------------------

@test "reap un-starts the row of a session that ended without it done, and records failed" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  mkdir -p "$FLEET_DISPATCH_DIR/live"
  printf 'project=game\nprofile=bnb\nlane=human\nkey=fix crash\n' > "$FLEET_DISPATCH_DIR/live/game-agent-1"
  run cmd_reap
  assert_success
  grep -qF -- '- [ ] fix crash' "$NOTES_FIXTURE/rows.game.human" || fail "row still started"
  assert_equal "$(jq -r .verdict "$FLEET_DISPATCH_DIR/verdicts.jsonl")" failed
  [ ! -e "$FLEET_DISPATCH_DIR/live/game-agent-1" ] || fail "ledger entry kept"
}

@test "reap drops the ledger of a finished row without touching the sheet" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [x] fix crash'
  mkdir -p "$FLEET_DISPATCH_DIR/live"
  printf 'project=game\nprofile=bnb\nlane=human\nkey=fix crash\n' > "$FLEET_DISPATCH_DIR/live/game-agent-1"
  run cmd_reap
  assert_not_called 'start'
  [ ! -e "$FLEET_DISPATCH_DIR/live/game-agent-1" ] || fail "ledger entry kept"
}

@test "reap leaves a live session alone" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' '- [/] fix crash'
  mkdir -p "$FLEET_DISPATCH_DIR/live"
  printf 'project=game\nprofile=bnb\nlane=human\nkey=fix crash\n' > "$FLEET_DISPATCH_DIR/live/game-agent-1"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_reap
  [ -e "$FLEET_DISPATCH_DIR/live/game-agent-1" ] || fail "reaped a live session"
  assert_not_called 'start'
}
