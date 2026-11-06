#!/usr/bin/env bats
# work-update: job configs over _default, the facts a draft is written from, save (lint, never
# send) and kept (the edit size between draft and sent). notes is stubbed to a sandbox job root,
# comms-lint is the repo's own with a stub prose checker.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/work-update"
  export WORK_UPDATE_JOBS="$SANDBOX/jobs" DAYLOG_DIR="$SANDBOX/daylog" JOBROOT="$SANDBOX/job"
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml"
  export COMMS_PROSE_CHECK="$SANDBOX/check.py"
  printf 'import sys\nsys.exit(0)\n' >"$COMMS_PROSE_CHECK"
  mkdir -p "$WORK_UPDATE_JOBS" "$DAYLOG_DIR" "$JOBROOT/log"
  cat >"$WORK_UPDATE_JOBS/_default.toml" <<'EOF'
eod_channel = "client-eod"
weekly_channel = "client-weekly"
eod_prompt = "prompts/eod.md"
weekly_prompt = "prompts/weekly.md"
weekly_day = "Friday"
repos = []
EOF
  cat >"$WORK_UPDATE_JOBS/acme.toml" <<'EOF'
notes_profile = "acme"
repos = ["fleet"]
section_names = { fleet = "Fleet Platform" }
EOF
  cat >"$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"path root") echo "$JOBROOT" ;;
*"path daily-dir") echo "$JOBROOT/log" ;;
*) exit 1 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
  cat >"$DAYLOG_DIR/2026-11-05.json" <<'EOF'
{"merged": [
 {"repo": "fleet", "title": "feat(api): devices report health", "url": "https://x/fleet/pull/7"},
 {"repo": "other", "title": "chore: not this job", "url": "https://x/other/pull/1"}]}
EOF
  echo "- paired with Sam on the health check" >"$JOBROOT/log/2026-11-05.md"
  # the work ledger: agent-queue list serves $SANDBOX/items, and fails while it is missing
  export WORK_UPDATE_QUEUE="$SANDBOX/bin/queue-stub" TZ=UTC
  printf '#!/usr/bin/env bash\nexec cat "%s"\n' "$SANDBOX/items" >"$WORK_UPDATE_QUEUE"
  chmod +x "$WORK_UPDATE_QUEUE"
  : >"$SANDBOX/items"
}

@test "a job is its file over _default, and an unknown job names the ones there are" {
  run "$SUBJECT" config acme
  assert_success
  run python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['repos'], d['weekly_day'], d['job'])" "$output"
  assert_output "['fleet'] Friday acme"
  run "$SUBJECT" config nope
  assert_failure 2
  assert_output --partial "jobs: acme"
}

@test "facts lists the job's merged PRs under its section names, and its daily note" {
  run "$SUBJECT" facts acme eod --date 2026-11-05
  assert_success
  assert_output --partial "- 2026-11-05 [Fleet Platform] feat(api): devices report health (https://x/fleet/pull/7)"
  refute_output --partial "not this job"
  assert_output --partial "paired with Sam"
  assert_output --partial "Channel: client-eod."
}

@test "facts groups the day by the job's work items, longest first, with their minutes and a day total" {
  printf '%s\n' \
    '{"slug":"health","title":"devices report health","pr":"o/fleet#7","work_min":"45","finished":"2026-11-05T12:00:00Z"}' \
    '{"slug":"lint","title":"lint the api","pr":"o/fleet#8","work_min":"90","finished":"2026-11-05T13:00:00Z"}' \
    '{"slug":"untimed","title":"docs","pr":"o/fleet#9","finished":"2026-11-05T14:00:00Z"}' \
    '{"slug":"other-repo","pr":"o/other#1","work_min":"30","finished":"2026-11-05T12:00:00Z"}' \
    '{"slug":"bare-pr","pr":"7","work_min":"30","finished":"2026-11-05T12:00:00Z"}' \
    '{"slug":"next-day","pr":"o/fleet#10","work_min":"30","finished":"2026-11-06T12:00:00Z"}' >"$SANDBOX/items"
  run "$SUBJECT" facts acme eod --date 2026-11-05
  assert_success
  run grep -A4 '^## Work items' <<<"$output"
  assert_output "$(printf '%s\n' '## Work items' \
    '- 2026-11-05 [Fleet Platform] lint the api (90 min, #8, lint)' \
    '- 2026-11-05 [Fleet Platform] devices report health (45 min, #7, health)' \
    '- 2026-11-05 [Fleet Platform] docs (? min, #9, untimed)' \
    '- 2026-11-05 total: 135 min over 3 item(s), 1 with no time')"
}

@test "facts says when the work ledger cannot be read, and still lists the PRs (negative control)" {
  rm "$SANDBOX/items"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$WORK_UPDATE_QUEUE"
  run "$SUBJECT" facts acme eod --date 2026-11-05
  assert_success
  assert_output --partial "- (the work ledger could not be read)"
  assert_output --partial "devices report health (https://x/fleet/pull/7)"
}

@test "save lints the draft on the job's channel and saves it either way; it never sends" {
  run "$SUBJECT" save acme eod --date 2026-11-05 - <<'EOF'
Hey team! Wrapping up for the day.

**Fleet Platform**
- Devices now report their health, so a dead player shows up in the dashboard.
EOF
  assert_success
  assert_output --partial "lint: passes"
  assert [ -f "$JOBROOT/updates/2026-11-05-eod.md" ]
  long=$(printf 'word %.0s' $(seq 1 120))
  run "$SUBJECT" save acme eod --date 2026-11-04 - <<<"Hey team.

- $long"
  assert_failure 1
  assert_output --partial "item-too-long"
  assert [ -f "$JOBROOT/updates/2026-11-04-eod.md" ]
}

@test "kept saves what was sent beside the draft and records the edit size" {
  printf 'Hey team!\n\n- Devices report health.\n' | "$SUBJECT" save acme eod --date 2026-11-05 - >/dev/null
  run "$SUBJECT" kept acme eod --date 2026-11-05 - <<<"Hey team!

- Devices report health now, and the dashboard shows dead players."
  assert_success
  assert_output --regexp "kept: .*2026-11-05-eod.sent.md, [0-9]+% of the draft changed"
  run jq -r '.kind + " " + (.edit_pct > 0 | tostring)' "$JOBROOT/updates/kept.jsonl"
  assert_output "eod true"
  run "$SUBJECT" report --since 3650d
  assert_success
  assert_output --partial "acme: 1 drafts, 1 kept, median edit"
}

@test "a weekly's facts carry the week's EODs, the sent text over the draft" {
  mkdir -p "$JOBROOT/updates"
  echo "draft of monday" >"$JOBROOT/updates/2026-11-03-eod.md"
  echo "sent on monday" >"$JOBROOT/updates/2026-11-03-eod.sent.md"
  echo "draft of tuesday" >"$JOBROOT/updates/2026-11-04-eod.md"
  run "$SUBJECT" facts acme weekly --date 2026-11-05
  assert_success
  assert_output --partial "2026-11-02 to 2026-11-05"
  assert_output --partial "sent on monday"
  refute_output --partial "draft of monday"
  assert_output --partial "draft of tuesday"
}

@test "kept without a saved draft is refused: there is nothing to measure against" {
  run "$SUBJECT" kept acme eod --date 2026-11-01 - <<<"sent text"
  assert_failure 2
  assert_output --partial "no draft"
}
