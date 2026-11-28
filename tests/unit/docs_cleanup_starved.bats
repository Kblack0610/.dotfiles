#!/usr/bin/env bats
# agentctl-docs-cleanup queues its pass where the queue lets it start (high, tagged cleanup), and a
# pass that sat queued past DOCS_CLEANUP_STARVED_DAYS is a failure, not another quiet NOOP night.
# A pass the add filed as a board row (exit 5, QUEUE.md "Admission") and left unstarted that long is starved the same way. agent-queue, notes and skill-drift are stubs; the stub queue records what it was asked to add.
# Each drifted area is its own pass, add and row line (ar-5138): the stub baseline drifts in docs alone unless SKILLS_JSON adds a skills finding.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  export PATH="$BIN:$PATH" # the runner unit declares ~/.local/bin on PATH; the script no longer does
  mkdir -p "$BIN" "$HOME/.local/lib" "$HOME/.agent/lessons"
  cp "$BATS_TEST_DIRNAME/../../.local/bin/agentctl-docs-cleanup" "$BATS_TEST_DIRNAME/../../.local/bin/lessons" "$BATS_TEST_DIRNAME/../../.local/bin/docs-renamed-paths" "$BIN/"
  # shape-grow --stock is a stub: STOCK_OUT is its answer, STOCK_RC its exit; it records its arguments.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$HOME/stock.args"\n[ -z "${STOCK_OUT-}" ] || printf "%%s\\n" "$STOCK_OUT"\nexit "${STOCK_RC:-0}"\n' > "$BIN/shape-grow"
  printf 'proof_outcome() { printf "%%s\\n" "$2" >> "$BATS_TEST_TMPDIR/verdicts"; }\n' > "$HOME/.local/lib/agent-proof.sh" # each night's verdict, one a line
  printf '#!/usr/bin/env bash\necho docs-cleanup\n' > "$BIN/agentctl"
  cat > "$BIN/agent-queue" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) if [ "$2" = docs-cleanup-pass ]; then echo "${LEGACY_JSON:-{\}}"; else echo "${ITEM_JSON:-{\}}"; fi ;;
  add) printf '%s\n' "$@" >> "$ADD_LOG"
       printf '%s\t%s\n' "$7" "${13}" >> "$ADD_LOG.tsv" # its slug and task
       rc="${ADD_RC:-0}"; case "$7" in *-skills) rc="${ADD_RC_SKILLS:-$rc}" ;; esac # ADD_RC_SKILLS: the skills area's own code
       if [ "$rc" = 6 ]; then # notes' refusal: the daily cap unless GATE_REFUSAL says the gate
         echo "agent-queue: no story row filed on agent-runtime: ${GATE_REFUSAL:-agent-runtime has taken its 10 new agent rows for today (10 so far, intake_daily_cap in the notes config)}" >&2
       fi
       if [ "$rc" = 5 ]; then
         n=$(cat "$ROW_SEQ" 2>/dev/null || echo 9); echo $((n + 1)) > "$ROW_SEQ"
         echo "agent-queue: only the board fills the queue: an agent or a script files a board row and dispatch pulls it (QUEUE.md \"Admission\")" >&2
         echo "held $7 -> agent-runtime:${ROW_ID:-ar-$n}"
       fi
       exit "$rc" ;;
esac
STUB
  cat > "$BIN/notes" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "board --json") cat "$HOME/board.json" ;;
  "knowledge lint") echo '{"total":0}' ;;
esac
STUB
  printf '#!/usr/bin/env bash\n' > "$BIN/knowledge-retired"
  cat > "$BIN/skill-drift" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --json) if [ -n "${SKILLS_JSON:-}" ]; then echo "$SKILLS_JSON"; else echo '{"findings":[]}'; fi ;;
  --docs) echo '{"drift":3}' ;;
  --dups) echo '{"pairs":60,"max":60,"over":0}' ;;
esac
STUB
  chmod +x "$BIN"/*
  export AGENTCTL_INBOX="$BATS_TEST_TMPDIR/inbox" DOCS_CLEANUP_LESSONS="$HOME/.agent/lessons" ADD_LOG="$BATS_TEST_TMPDIR/add.log" ROW_SEQ="$BATS_TEST_TMPDIR/row.seq"
}

@test "a pass queued 3 days ago and never started is a failure" {
  ITEM_JSON="{\"state\":\"queued\",\"queued\":\"$(date -u -d '3 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'starved: queued since'
}

@test "negative control: a pass queued an hour ago is still open, not starved" {
  ITEM_JSON="{\"state\":\"queued\",\"queued\":\"$(date -u -d '1 hour ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still queued, not queuing another'
}

@test "a running pass is never starved, however old its queued time" {
  ITEM_JSON="{\"state\":\"running\",\"queued\":\"$(date -u -d '9 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still running'
}

@test "the pass is queued at high, tagged cleanup" {
  run "$BIN/agentctl-docs-cleanup"
  assert_success
  run cat "$ADD_LOG"
  assert_line --index 0 add
  assert_line --index 8 --  '--priority'
  assert_line --index 9 high
  assert_line --index 10 -- '--tags'
  assert_line --index 11 cleanup
}

@test "a queued pass with no readable queued time is a failure, not a fresh pass" {
  ITEM_JSON='{"state":"queued","queued":""}' run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'no readable queued time'
}

@test "a pass held by another hold (after, focus) is the queue's choice, not starved" {
  ITEM_JSON="{\"state\":\"queued\",\"hold\":\"after other-slug\",\"queued\":\"$(date -u -d '5 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'still queued'
}

@test "a queued pass nothing holds still starves" {
  ITEM_JSON="{\"state\":\"queued\",\"queued\":\"$(date -u -d '3 days ago' +%FT%TZ)\"}" run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'starved: queued since'
}

@test "a board-only add files the pass as a board row, which is the open pass until the board drops it (P1, #2419)" {
  printf '{"rows":[{"project":"agent-runtime","id":"ar-9","state":"open"}]}\n' > "$HOME/board.json"
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  run cut -f1,2 "$AGENTCTL_INBOX/row"
  assert_output "$(printf 'agent-runtime\tar-9')"
  rm "$ADD_LOG"
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'is board row ar-9 on agent-runtime, open, not filing another'
  assert [ ! -e "$ADD_LOG" ]
  printf '{"rows":[{"project":"agent-runtime","id":"ar-9","state":"doing"}]}\n' > "$HOME/board.json"
  printf 'agent-runtime\tar-9\t%s\n' "$(date -d '9 days ago' +%s)" > "$AGENTCTL_INBOX/row"
  run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'ar-9 on agent-runtime, doing'
}

@test "a board row left unstarted past the limit is starved; one the board dropped files the next pass" {
  printf '{"rows":[{"project":"agent-runtime","id":"ar-9","state":"open"}]}\n' > "$HOME/board.json"
  mkdir -p "$AGENTCTL_INBOX"
  printf 'agent-runtime\tar-9\t%s\n' "$(date -d '3 days ago' +%s)" > "$AGENTCTL_INBOX/row"
  run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'starved: board row ar-9 on agent-runtime filed'
  printf '{"rows":[]}\n' > "$HOME/board.json"
  ADD_RC=5 ROW_ID=ar-10 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert [ -e "$ADD_LOG" ]
  run cut -f2 "$AGENTCTL_INBOX/row"
  assert_output ar-10
}

@test "two drifted areas file two passes, each naming its one area, under two slugs and two row lines (ar-5138)" {
  SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  run cut -f1 "$ADD_LOG.tsv"
  assert_output "$(printf 'docs-cleanup-pass-skills\ndocs-cleanup-pass-docs')"
  run cut -f2 "$ADD_LOG.tsv"
  assert_line --index 0 --partial "Docs-cleanup area skills: run the"
  assert_line --index 0 --partial ': skills 1. '
  refute_line --index 0 --partial 'global docs'
  assert_line --index 1 --partial "Docs-cleanup area docs: run the"
  assert_line --index 1 --partial ': global docs 3. '
  refute_line --index 1 --partial 'skills 1'
  run grep -c -- '--repeat' "$ADD_LOG"
  assert_output 2
  run cut -f1,2,4 "$AGENTCTL_INBOX/row"
  assert_output "$(printf 'agent-runtime\tar-9\tskills\nagent-runtime\tar-10\tdocs')"
}

@test "a second night re-files only the area whose row closed; the open one is left, and starved past the limit (ar-5138)" {
  SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  rm "$ADD_LOG.tsv"
  # ar-9 (skills) is still open on the board; ar-10 (docs) closed
  printf '{"rows":[{"project":"agent-runtime","id":"ar-9","state":"open"}]}\n' > "$HOME/board.json"
  SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'pass docs-cleanup-pass-skills is board row ar-9 on agent-runtime, open, not filing another'
  run cut -f1 "$ADD_LOG.tsv"
  assert_output docs-cleanup-pass-docs
  run cut -f2,4 "$AGENTCTL_INBOX/row"
  assert_output "$(printf 'ar-9\tskills\nar-11\tdocs')"
  # Past the limit the open area is starved, and the closed one is still filed that night.
  rm "$ADD_LOG.tsv"
  sed -i "1s/^\(agent-runtime\tar-9\t\)[0-9]*/\1$(date -d '3 days ago' +%s)/" "$AGENTCTL_INBOX/row"
  SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'pass docs-cleanup-pass-skills starved: board row ar-9 on agent-runtime filed'
  assert_output --partial '; also filed docs-cleanup-pass-docs as board row ar-12 on agent-runtime'
  run cut -f1 "$ADD_LOG.tsv"
  assert_output docs-cleanup-pass-docs
  run cut -f2,4 "$AGENTCTL_INBOX/row"
  assert_output "$(printf 'ar-9\tskills\nar-12\tdocs')"
}

@test "a pass still active under the bare slug from before the split holds every area that night (ar-5138)" {
  LEGACY_JSON='{"state":"running"}' SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial 'pass docs-cleanup-pass (every area) still running, not queuing another'
  [ ! -e "$ADD_LOG.tsv" ] || fail "an area was filed beside the old pass"
  # NEGATIVE CONTROL: once it is done the areas file as usual
  LEGACY_JSON='{"state":"done"}' SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  run cut -f1 "$ADD_LOG.tsv"
  assert_output "$(printf 'docs-cleanup-pass-skills\ndocs-cleanup-pass-docs')"
}

@test "a pass the board's daily cap refuses (exit 6) is a NOOP night that files again next night, not FAILED" {
  ADD_RC=6 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial "docs-cleanup-pass-docs held by the board's daily cap, filed again next night"
  run tail -n 1 "$BATS_TEST_TMPDIR/verdicts"
  assert_output NOOP
  [ ! -s "$AGENTCTL_INBOX/row" ] || fail "a held pass kept a row line"
  # the next night the cap has room: the same area files its row
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  run tail -n 1 "$BATS_TEST_TMPDIR/verdicts"
  assert_output WORKED
}

@test "negative control: any other refusal of the add still fails the night" {
  ADD_RC=1 run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial 'could not file pass docs-cleanup-pass-docs'
  run tail -n 1 "$BATS_TEST_TMPDIR/verdicts"
  assert_output FAILED
}

@test "a cap that holds the pass every night past the limit is a starved night, FAILED" {
  mkdir -p "$AGENTCTL_INBOX"; date -d '3 days ago' +%s > "$AGENTCTL_INBOX/held"
  ADD_RC=6 run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial "held by the board's daily cap every night since"
  # a night the pass files clears the streak
  ADD_RC=5 run "$BIN/agentctl-docs-cleanup"
  assert_success
  [ ! -e "$AGENTCTL_INBOX/held" ] || fail "the held streak outlived a filed night"
}

@test "an intake gate refusal (exit 6 that is not the cap) still fails the night" {
  GATE_REFUSAL='the agent-runtime board is gated' ADD_RC=6 run "$BIN/agentctl-docs-cleanup"
  assert_failure 1
  assert_output --partial "the board's intake gate refused pass docs-cleanup-pass-docs"
}

@test "one area filed and one held by the cap is a WORKED night naming both" {
  SKILLS_JSON='{"findings":[{"type":"NOCMD"}]}' ADD_RC=5 ADD_RC_SKILLS=6 run "$BIN/agentctl-docs-cleanup"
  assert_success
  assert_output --partial "docs-cleanup-pass-skills held by the board's daily cap"
  run tail -n 1 "$BATS_TEST_TMPDIR/verdicts"
  assert_output WORKED
  run cut -f4 "$AGENTCTL_INBOX/row"
  assert_output docs
}
