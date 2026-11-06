#!/usr/bin/env bats
# comms-lint: a message checked against its channel in the shipped channels.toml, and the
# report over a sandboxed ledger and files. The prose checker is a stub, so these tests pin
# comms-lint's own rules, not de-ai-writing's.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/comms-lint"
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml"
  export COMMS_PROSE_CHECK="$SANDBOX/check.py"
  # check.py stub: an "em dash" line is a hard finding; suspect words never fail
  cat > "$COMMS_PROSE_CHECK" <<'EOF'
import sys
t = sys.stdin.read()
hard = "em dash" in t
print("  line 1: SUSPECT WORD: 'robust'")
if hard:
    print("  line 1: DASH: em dash")
sys.exit(1 if hard or "robust" in t else 0)
EOF
  # The queue's reader prints nothing here, so no live queue reaches a report.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/agent-queue"; chmod +x "$SANDBOX/bin/agent-queue"
}

@test "a plain page passes" {
  run "$SUBJECT" --channel page --priority high - <<< "Nightly tests have been red for 5 days. Pick an owner on the agent board."
  assert_success
  refute_output
}

@test "negative control: today's Sentinel page fails on ids, plumbing and caps" {
  run "$SUBJECT" --channel page --priority urgent - <<< "[playground-nightly] STILL TRIP after 5d — exit 1 (want 0) | at: GitHub Actions | do: read the log"
  assert_failure 1
  assert_output --partial "lead-id"
  assert_output --partial "non-ascii: U+2014"
  assert_output --partial "probe plumbing"
  assert_output --partial "probe internals"
  assert_output --partial "all-caps status word"
}

@test "a recovery may not buzz; the same text at low passes the priority rule" {
  run "$SUBJECT" --channel page --priority high - <<< "Nightly tests recovered."
  assert_failure 1
  assert_output --partial "quiet-buzzed"
  run "$SUBJECT" --channel page --priority low - <<< "Nightly tests recovered."
  assert_success
  # Sentinel's all-clear wording.
  run "$SUBJECT" --channel page --priority high - <<< "Home cluster nodes back to normal after 2h."
  assert_failure 1
  assert_output --partial "quiet-buzzed"
}

@test "ids may follow the point but not lead it" {
  run "$SUBJECT" --channel page - <<< "dotfiles#910 is stuck on the fast tier timeout."
  assert_failure 1
  assert_output --partial "lead-id"
  run "$SUBJECT" --channel page - <<< "The fleet-liveness fix is stuck on the fast tier timeout (dotfiles#910)."
  assert_success
  run "$SUBJECT" --channel page - <<< "lusBbd (unity-core-playground): resume the Shape City session?"
  assert_failure 1
  assert_output --partial "lead-id"
}

@test "a page has a length budget" {
  long=$(printf 'Nightly tests are red. %.0s' {1..20})
  run "$SUBJECT" --channel page - <<< "$long"
  assert_failure 1
  assert_output --partial "too-long"
}

@test "a briefing is linted whole, and caps only its Needs you items" {
  printf -- '---\ngenerated: true\n---\n# Morning briefing\n\n3 things need you.\n\n## Needs you\n\n1. Answer 18 open asks.\n2. Merge the dispatch fix.\n3. Check the AWS alarm.\n\n## Still open\n\n- One.\n- Two.\n- Three.\n- Four.\n- Five.\n- Six.\n' > "$SANDBOX/b.md"
  run "$SUBJECT" --channel briefing "$SANDBOX/b.md"
  assert_success
  # Negative control: a runbook hint below Needs you fails now that the whole page is read.
  printf -- '\n## Fleet\n\n- [fleet-liveness] TRIPPED -> do: `agentctl list`, then a runbook hint\n' >> "$SANDBOX/b.md"
  run "$SUBJECT" --channel briefing "$SANDBOX/b.md"
  assert_failure 1
  assert_output --partial "a runbook hint"
  for i in 4 5 6 7; do echo "$i. Another thing." >> "$SANDBOX/c.md"; done
  { printf '3 things need you.\n\n## Needs you\n\n1. One.\n2. Two.\n3. Three.\n'; cat "$SANDBOX/c.md"; } > "$SANDBOX/b2.md"
  run "$SUBJECT" --channel briefing "$SANDBOX/b2.md"
  assert_failure 1
  assert_output --partial "items: 7 items, budget 5"
}

@test "emoji: a page allows none, a client EOD allows a budget" {
  run "$SUBJECT" --channel page - <<< "Shipped the fix 🚀"
  assert_failure 1
  assert_output --partial "emoji"
  run "$SUBJECT" --channel client-eod - <<< "Hey team! Wrapping up for the day. Shipped the fix 🚀"
  assert_success
}

@test "prose channels run the prose checker: hard rules fail, suspect words do not" {
  run "$SUBJECT" --channel status - <<< $'Done\n- shipped it, em dash here\nNext\n- more'
  assert_failure 1
  assert_output --partial "prose: line 1: DASH: em dash"
  run "$SUBJECT" --channel status - <<< $'Done\n- a robust fix\nNext\n- more'
  assert_success
}

@test "status requires its sections" {
  run "$SUBJECT" --channel status - <<< "I did some things today."
  assert_failure 1
  assert_output --partial "missing: Done section"
  assert_output --partial "missing: Next section"
}

@test "a rundown is in the status shape: Done, Next and Needs you are required" {
  run "$SUBJECT" --channel rundown - <<< $'Merged since 19:00: 12 PRs.\nHealth: 24 working.'
  assert_failure 1
  assert_output --partial "missing: Done section"
  assert_output --partial "missing: Needs you section"
  run "$SUBJECT" --channel rundown - <<< $'Moving, two late.\n## Done\n- x #1\n## Doing\n- y\n## Next\n- z\n## Needs you\n- Nothing.'
  assert_success
}

@test "a wind-down note and a one-line lab status pass status; the old wrap-up shape does not" {
  cat > "$SANDBOX/note.md" <<'EOF'
# Session wrap-up - 2026-11-05

**Project:** dotfiles

The rundown and the shipped page now read in the status shape.

## Done
- The rundown reads as Done, Doing, Next and Needs you (dotfiles#946)

## Doing
- Nothing.

## Next
- Score PR bodies at land.

## Needs you
- Nothing.
EOF
  run "$SUBJECT" --channel status "$SANDBOX/note.md"
  assert_success
  run "$SUBJECT" --channel status - <<< "The status shape is in. Done: rundown (#946). Doing: nothing. Next: PR bodies. Needs you: nothing."
  assert_success
  run "$SUBJECT" --channel status - <<'EOF'
# Session wrap-up - 2026-11-04

## What happened
- Did the rundown.

## Next step
- PR bodies.
EOF
  assert_failure 1
  assert_output --partial "missing: Done section"
}

@test "a missing prose checker is a usage error, never a silent pass" {
  export COMMS_PROSE_CHECK="$SANDBOX/nope.py"
  run "$SUBJECT" --channel status - <<< $'Done\n- x\nNext\n- y'
  assert_failure 2
  assert_output --partial "prose checker not found"
}

@test "usage errors exit 2" {
  run "$SUBJECT" --channel nope - <<< "x"
  assert_failure 2
  run "$SUBJECT" --channel page - <<< ""
  assert_failure 2
  printf '[channel.x]\nmax_lenght = 3\n' > "$SANDBOX/bad.toml"
  COMMS_CHANNELS="$SANDBOX/bad.toml" run "$SUBJECT" channels
  assert_failure 2
  assert_output --partial "unknown key(s) max_lenght"
}

@test "report counts buzzes and recoveries that buzzed from the ledger" {
  now=$(date -Iseconds)
  mkdir -p "$HOME/.local/state/agent-notify"
  printf '%s\thigh\tSentinel: x\t[x] RECOVERED - exit 0\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  printf '%s\thigh\task\tAnswer the trader question.\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  printf '%s\tlow\tSentinel: x\tFan is back to normal.\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  printf '2020-01-01T00:00:00+00:00\thigh\told\told page\n' >> "$HOME/.local/state/agent-notify/log"
  run "$SUBJECT" report --since 1d --channel page --json
  assert_success
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['page']; print(d['messages'], d['buzzed'], d['quiet_that_buzzed'], d['pass_pct'])" "$output"
  assert_output "3 2 1 67"
  run "$SUBJECT" report --since 1d --channel page
  assert_success
  assert_line --partial "Comms, last 1d: 3 messages, 67% meet the standard."
}

@test "snapshot stores the 7d and 28d reports; line and kpi read the newest, and kpi refuses a stale one" {
  export COMMS_SNAPSHOT_DIR="$SANDBOX/comms" KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"   # no PR bodies reach the sandbox
  run "$SUBJECT" kpi --json
  assert_failure 1
  assert_output --partial "no comms snapshot"
  now=$(date -Iseconds)
  mkdir -p "$HOME/.local/state/agent-notify"
  printf '%s\thigh\tSentinel: x\t[x] RECOVERED - exit 0\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  printf '%s\thigh\task\tAnswer the trader question.\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  echo buzzes_per_day_max=15 > "$KPI_THRESHOLDS"
  run "$SUBJECT" snapshot --date 2026-11-05
  assert_success
  assert_output --partial "comms 2026-11-05: 7d 50% of 2 messages meet the standard, phone buzzed 0.3 times a day (most 15); lowest: page 50%."
  run "$SUBJECT" kpi --json
  assert_success
  assert_output '{"buzzes_per_day": {"7d": 0.3, "28d": 0.1}, "comms_pass_pct": {"7d": 50, "28d": 50}, "rows_pass_pct": {"7d": null, "28d": null}, "date": "2026-11-05"}'
  # an older day's file never wins over the newest
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['date']='2026-11-01'; json.dump(d, open(sys.argv[2],'w'))" \
    "$COMMS_SNAPSHOT_DIR/2026-11-05.json" "$COMMS_SNAPSHOT_DIR/2026-11-01.json"
  run "$SUBJECT" line
  assert_output --partial "comms 2026-11-05:"
  python3 -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['made_epoch']-=3*86400; json.dump(d, open(p,'w'))" \
    "$COMMS_SNAPSHOT_DIR/2026-11-05.json"
  run "$SUBJECT" kpi --json
  assert_failure 1
  assert_output --partial "72h old"
  run "$SUBJECT" line
  assert_success
}

@test "report scores merged PR bodies from gh, and says so when gh cannot answer" {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/gh.log"
[ -f "$SANDBOX/gh.fail" ] && { echo "gh: offline" >&2; exit 1; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
long=$(printf 'word %.0s' $(seq 1 40))
printf '[{"body":"Bodies are scored at land.\\n\\nRemoves: nothing.","closedAt":"%s","number":1,"repository":{"name":"r"}},' "$now"
printf '{"body":"%s","closedAt":"%s","number":2,"repository":{"name":"r"}}]\n' "$long" "$now"
EOF
  chmod +x "$SANDBOX/bin/gh"
  export SANDBOX PATH="$SANDBOX/bin:$PATH"
  run "$SUBJECT" report --since 1d --channel pr-body --json
  assert_success
  run grep -c -- '--author=@me --merged-at >=' "$SANDBOX/gh.log"
  assert_output 1
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['pr-body']; print(d['messages'], d['pass_pct'])" "$(COMMS_CHANNELS="$COMMS_CHANNELS" "$SUBJECT" report --since 1d --channel pr-body --json)"
  assert_output "2 50"
  touch "$SANDBOX/gh.fail"
  run "$SUBJECT" report --since 1d --channel pr-body
  assert_success
  assert_output --partial "source unreadable: gh search prs"
}

@test "report finds client updates under a job root at any depth" {
  for d in acme/updates beta/client/updates; do
    mkdir -p "$HOME/.notes/employment/jobs/$d"
    printf 'Hey team!\n\n- Shipped the health check.\n' > "$HOME/.notes/employment/jobs/$d/2026-11-05-eod.md"
  done
  touch "$HOME/.notes/employment/jobs/acme/updates/2026-11-05-eod.sent.md"
  run "$SUBJECT" report --since 1d --channel client-eod --json
  assert_success
  run python3 -c "import json,sys; print(json.loads(sys.argv[1])['channels']['client-eod']['messages'])" "$output"
  assert_output 2
}

@test "the shipped channels.toml loads and every channel is listed" {
  run "$SUBJECT" channels
  assert_success
  for c in page briefing morning rundown status pr-body client-eod client-weekly board proof ask queue fleet-log; do
    assert_output --partial "$c"
  done
}

@test "a ledger line with no fields of its own is a shape finding, dated by the page before it" {
  now=$(date -Iseconds)
  mkdir -p "$HOME/.local/state/agent-notify"
  printf '%s\tnormal\tbriefing\tTwo things need you.\nstale (carried 3x): run the DR drill\n' "$now" >> "$HOME/.local/state/agent-notify/log"
  printf '2020-01-01T00:00:00+00:00\tnormal\told\tOld page.\nold tail\n' >> "$HOME/.local/state/agent-notify/log"
  run "$SUBJECT" report --since 1d --channel page --json
  assert_success
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['page']; print(d['messages'], d['passed'], d['findings'])" "$output"
  assert_output "2 1 {'shape': 1}"
}

@test "a command source lints its reader's records; a reject is a shape finding; rows keep their own pass rate" {
  cat > "$SANDBOX/bin/reader" <<'EOF'
#!/usr/bin/env bash
now=$(date -Iseconds)
printf '%s\n' "$*" > "$SANDBOX/reader.args"
printf '{"ts":"%s","text":"fix(x): a clean row","path":"ar-1"}\n' "$now"
printf '{"ts":"%s","text":"fix(x): an \\u2014 dash","path":"ar-2"}\n' "$now"
printf '{"ts":"%s","text":"- 09:00 nudge","reject":"no UTC stamp"}\n' "$now"
printf '{"ts":"%s","text":"a human row \\u2014","by":"human"}\n' "$now"
printf '{"ts":"%s","text":"a bot row \\u2014","by":"bot"}\n' "$now"
printf '{"ts":1,"text":"too old"}\n'
printf 'not json\n'
printf '{"text":"no time"}\n'
EOF
  chmod +x "$SANDBOX/bin/reader"
  export SANDBOX
  { sed -n '/^\[defaults\]/,/^$/p' "$COMMS_CHANNELS"
    printf '[ids]\npatterns = []\n\n[channel.rows]\ngroup = "rows"\nlead_ids = false\n'
    printf 'source = { kind = "command", cmd = ["reader", "--days", "{days}"], skip = { by = ["human", "bot"] } }\n'
    printf '\n[channel.page]\nsource = { kind = "ledger", path = "~/.local/state/agent-notify/log" }\n'
  } > "$SANDBOX/rows.toml"
  mkdir -p "$HOME/.local/state/agent-notify"
  printf '%s\tnormal\tx\tThe nightly is green again.\n' "$(date -Iseconds)" >> "$HOME/.local/state/agent-notify/log"
  export COMMS_CHANNELS="$SANDBOX/rows.toml"
  run "$SUBJECT" report --since 1d --json
  assert_success
  run cat "$SANDBOX/reader.args"
  assert_output "--days 2"
  run python3 -c "import json,sys; d=json.loads(sys.argv[1]); r=d['channels']['rows']; print(r['group'], r['messages'], r['passed'], sorted(r['findings'])); s=d['summary']; print(s['messages'], s['pass_pct'], s['rows'], s['rows_pass_pct'])" "$("$SUBJECT" report --since 1d --json)"
  assert_line --index 0 "rows 3 1 ['non-ascii', 'shape']"
  assert_line --index 1 "1 100 3 33"
  run "$SUBJECT" report --since 1d
  assert_line --partial "1 messages, 100% meet the standard. 3 rows, 33% meet their notation."
  # A reader line that is not JSON, or has no time, is counted on stderr, never dropped in silence.
  assert_line --partial "2 unreadable record(s) (not JSON, or no time) from reader --days 2"
  # A reader that cannot run says so on stderr, never a silent pass.
  rm "$SANDBOX/bin/reader"
  run "$SUBJECT" report --since 1d --channel rows
  assert_success
  assert_output --partial "source unreadable: reader --days 2"
}

@test "a proof cites a reference; negative control: words alone fail" {
  run "$SUBJECT" --channel proof - <<< "merged and verified live"
  assert_failure 1
  assert_output --partial "no-ref"
  for p in "pr:982" "dotfiles#926 #936, private#404" "commit 29ed5f8" "https://github.com/x/y/pull/3"; do
    run "$SUBJECT" --channel proof - <<< "$p"
    assert_success
  done
}

@test "an ask is linted on its question and context, not its bookkeeping" {
  mkdir -p "$HOME/.agent/asks/dotfiles"
  printf 'id: aB3dEf\nproject: dotfiles\nquestion: dotfiles#910 is stuck. Rerun it?\ncontext: The fast tier timed out.\noptions: a|b\noption_notes: rerun|wait\n' > "$HOME/.agent/asks/dotfiles/aB3dEf.md"
  printf 'id: Cd4eFg\nproject: dotfiles\nsession: /home/x/caf\xc3\xa9\nquestion: Rerun the fast tier (dotfiles#910)?\n' > "$HOME/.agent/asks/dotfiles/Cd4eFg.md"
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['ask']; print(d['messages'], d['passed'], sorted(d['findings']))" "$("$SUBJECT" report --since 1d --channel ask --json)"
  assert_output "2 1 ['lead-id']"
}

@test "an ask whose options do not each say what they do fails bare-options; a gate's default does not" {
  mkdir -p "$HOME/.agent/asks/dotfiles"
  printf 'id: aaaaa1\nquestion: Rerun the fast tier?\noptions: a|b\noption_notes: rerun|\n' > "$HOME/.agent/asks/dotfiles/aaaaa1.md"
  printf 'id: aaaaa2\nquestion: Merge the fix?\noptions: go|later\n' > "$HOME/.agent/asks/dotfiles/aaaaa2.md"
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['ask']; print(d['messages'], d['passed'], sorted(d['findings']))" "$("$SUBJECT" report --since 1d --channel ask --json)"
  assert_output "2 0 ['bare-options']"
  # Negative controls: meanings on every option, and a gate's defaulted approve|hold, pass.
  printf 'id: aaaaa1\nquestion: Rerun the fast tier?\noptions: a|b\noption_notes: rerun|wait\n' > "$HOME/.agent/asks/dotfiles/aaaaa1.md"
  printf 'id: aaaaa2\nkind: gate\nquestion: Merge the fix?\noptions: approve|hold\n' > "$HOME/.agent/asks/dotfiles/aaaaa2.md"
  run python3 -c "import json,sys; d=json.loads(sys.argv[1])['channels']['ask']; print(d['messages'], d['passed'], sorted(d['findings']))" "$("$SUBJECT" report --since 1d --channel ask --json)"
  assert_output "2 2 []"
}

@test "every fixture in the replay corpus fails or passes its channel as filed" {
  # tests/fixtures/comms/<channel>/{pass,fail}/*: real messages and rows, hosts replaced.
  # A rule change that lets a filed failure through, or fails a filed pass, fails here.
  n=0
  for f in "$REPO_ROOT"/tests/fixtures/comms/*/*/*; do
    want=$(basename "$(dirname "$f")") ch=$(basename "$(dirname "$(dirname "$f")")")
    run "$SUBJECT" --channel "$ch" "$f"
    if [ "$want" = fail ]; then
      [ "$status" -eq 1 ] || fail "$ch/fail/$(basename "$f") passed: $output"
    else
      [ "$status" -eq 0 ] || fail "$ch/pass/$(basename "$f") failed: $output"
    fi
    n=$((n + 1))
  done
  [ "$n" -ge 12 ] || fail "only $n fixtures found"
}
