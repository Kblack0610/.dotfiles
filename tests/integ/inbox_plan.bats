#!/usr/bin/env bats
# agentctl-inbox-plan: a #plan row gets its plan as detail lines and loses the tag, through
# `notes ptask --exact edit` and `ptask add` only.
#
# The real notes against a sandbox vault, as inbox_triage.bats: the CI rust job builds notes
# and sets NOTES_BIN; without it every case skips.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  PLAN="$REPO_ROOT/.local/bin/agentctl-inbox-plan"
  PROJ="$HOME/.notes/lab/projects/current"
  SHEET="$PROJ/scratch/README.md"
  mkdir -p "$PROJ/scratch" "$HOME/.config/notes" "$SANDBOX/code/scratch"
  : >"$PROJ/scratch/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  printf '{"paths": {"%s": "scratch"}, "trackers": {"scratch": {"code": "sc"}}}\n' "$SANDBOX/code/scratch" >"$PROJECT_MAP_FILE"
  export INBOX_PLAN_CMD=model-stub
  printf '#!/usr/bin/env bash\necho called >> "$NOTES_FIXTURE/model.log"\nprintf "%%s\\n" "$@" > "$NOTES_FIXTURE/args.txt"\ncat "$NOTES_FIXTURE/model.out" 2>/dev/null\nrc="$(sed -n "$(wc -l <"$NOTES_FIXTURE/model.log")p" "$NOTES_FIXTURE/model.rc" 2>/dev/null)"\nexit "${rc:-0}"\n' >"$SANDBOX/bin/model-stub"
  chmod +x "$SANDBOX/bin/model-stub"
}

sheet() { printf '# scratch\n\nVersion: v0.1.0\n\n## Inbox\n\n## Tasks\n%b\n' "$1" >"$SHEET"; }
answer() { { echo INBOX-PLAN-START; echo "$1"; echo INBOX-PLAN-END; } >"$NOTES_FIXTURE/model.out"; }
record() { cat "$HOME/.local/state/notes/ingest.jsonl" 2>/dev/null; }

@test "a #plan row gets goal, approach, checks and its split rows, and loses the tag" {
  sheet '- [ ] feat(brand): a brand kit #size/s #plan #high <!-- id:sc-1 -->\n  was: brand kit for the studio\n- [ ] fix(ui): the menu flickers #low <!-- id:sc-2 -->\n'
  answer '{"goal": "one kit with logo, colors and type", "approach": ["collect the assets", "write the guide"], "checks": ["the guide renders"], "size": "l", "split": ["docs(brand): the brand guide #size/m", "feat(brand): the logo set #size/s"]}'
  run "$PLAN"
  assert_success
  assert_output --partial 'planned 1, split into 2 rows, refused 0'
  run cat "$SHEET"
  assert_output --regexp '- \[ \] feat\(brand\): a brand kit #size/l .*id:sc-1'
  refute_output --partial '#plan'
  assert_output --partial '  was: brand kit for the studio'
  assert_output --partial '  goal: one kit with logo, colors and type'
  assert_output --partial '  approach: collect the assets'
  assert_output --partial '  check: the guide renders'
  assert_output --partial '  split: 2 rows under sc-1'
  assert_output --regexp 'docs\(brand\): the brand guide #size/m .*#of/sc-1'
  refute_output --partial 'part of sc-1'
  grep -q 'The row: feat(brand): a brand kit #size/s #plan' "$NOTES_FIXTURE/args.txt" || fail "the row never reached the model"
  grep -q 'was: brand kit for the studio' "$NOTES_FIXTURE/args.txt" || fail "its details never reached the model"
  grep -q 'sc-2	fix(ui): the menu flickers' "$NOTES_FIXTURE/args.txt" || fail "the open rows never reached the model"
  grep -qx -- '--add-dir' "$NOTES_FIXTURE/args.txt" || fail "the code was not offered"
  grep -qx "$SANDBOX/code/scratch" "$NOTES_FIXTURE/args.txt"
  run record
  assert_output --regexp '"action":"planned".*"id":"sc-1"'
  assert_output --partial 'split into 2 rows'
  grep -q WORKED "$HOME/.local/state/agentctl/inbox-plan/last-outcome"
}

@test "a plan puts its row under an open epic it names, and an epic it invents costs only the tag" {
  sheet '- [ ] epic(audio): the sound pass #size/l <!-- id:sc-9 -->\n- [ ] fix(audio): the gun sound #size/s #plan <!-- id:sc-1 -->\n'
  answer '{"goal": "the gun plays on time", "approach": ["trace it"], "checks": ["it plays"], "size": "s", "split": [], "epic": "sc-9"}'
  run "$PLAN"
  assert_success
  assert_output --partial 'planned 1'
  run cat "$SHEET"
  assert_output --regexp 'fix\(audio\): the gun sound .*#of/sc-9 .*id:sc-1'
  grep -q 'sc-9	scratch	epic(audio): the sound pass' "$NOTES_FIXTURE/args.txt" || fail "the epics never reached the model"
  grep -q 'research design market legal' "$NOTES_FIXTURE/args.txt" || fail "the split types are stale"

  sheet '- [ ] fix(audio): the gun sound #size/s #plan <!-- id:sc-1 -->\n'
  answer '{"goal": "the gun plays on time", "approach": ["trace it"], "checks": ["it plays"], "size": "s", "split": [], "epic": "sc-404"}'
  run "$PLAN"
  assert_success
  assert_output --partial 'planned 1'
  run cat "$SHEET"
  refute_output --partial '#of/'
  assert_output --partial '  goal: the gun plays on time'
}

@test "a plan with no goal is refused, recorded, and not asked for again" {
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n'
  answer '{"approach": ["something"]}'
  run "$PLAN"
  assert_failure
  assert_output --partial 'refused 1'
  run cat "$SHEET"
  assert_output --partial '#plan'
  run record
  assert_output --regexp '"action":"refused".*the plan had no goal'
  grep -q 'outcome=FAILED .*why: scratch: the plan had no goal$' "$HOME/.local/state/agentctl/inbox-plan/activity.log"
  run "$PLAN"
  assert_success
  assert_output --partial 'planned 0'
  [ "$(wc -l <"$NOTES_FIXTURE/model.log")" = 1 ] || fail "asked the model again"
}

@test "a failed model call keeps its stderr in the log and its first words in the outcome" {
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n'
  printf '#!/usr/bin/env bash\necho "harness: claude exited 1" >&2\nexit 1\n' >"$SANDBOX/bin/model-stub"
  run "$PLAN"
  assert_failure
  assert_output --partial 'harness: claude exited 1'
  grep -q 'outcome=FAILED .*why: scratch sc-1: model call failed: harness: claude exited 1$' \
    "$HOME/.local/state/agentctl/inbox-plan/activity.log"
}

@test "no #plan row: no model call; --dry-run writes nothing" {
  sheet '- [ ] fix(ui): the menu flickers #low <!-- id:sc-2 -->\n'
  run "$PLAN"
  assert_success
  [ ! -e "$NOTES_FIXTURE/model.log" ] || fail "the model ran with nothing to plan"
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n'
  answer '{"goal": "a kit", "approach": [], "checks": [], "size": "m", "split": []}'
  before="$(cat "$SHEET")"
  run "$PLAN" --dry-run
  assert_success
  assert_output --partial 'would plan [scratch] sc-1 -> feat(brand): a brand kit #size/m'
  [ "$(cat "$SHEET")" = "$before" ] || fail "a dry run wrote the sheet"
  [ -z "$(record)" ] || fail "a dry run wrote the record"
}

# One exit code per model call, in order; a call past the list exits 0.
rcs() { printf '%s\n' "$@" >"$NOTES_FIXTURE/model.rc"; }
outcome() { cat "$HOME/.local/state/agentctl/inbox-plan/last-outcome"; }

@test "a budget stop ends the pass BLOCKED with exit 75: one call, no refusal, the rows wait" {
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n- [ ] fix(ui): the menu #plan <!-- id:sc-2 -->\n'
  rcs 75
  run "$PLAN"
  assert_failure 75
  assert_output --partial 'stopped at its budget'
  refute_output --partial 'model call failed'
  assert_equal "$(wc -l <"$NOTES_FIXTURE/model.log")" 1
  assert_equal "$(outcome)" BLOCKED
  run tail -n 1 "$HOME/.local/state/agentctl/inbox-plan/activity.log"
  assert_output --regexp 'outcome=BLOCKED budget: .*why: stopped at its budget'
  run record
  refute_output --partial '"action":"refused"'
  assert_equal "$(grep -c '#plan' "$SHEET")" 2
}

@test "a row planned before the budget stop stays planned, and the pass is BLOCKED" {
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n- [ ] fix(ui): the menu #plan <!-- id:sc-2 -->\n'
  answer '{"goal": "one kit", "approach": ["collect"], "checks": ["renders"], "size": "s", "split": []}'
  rcs 0 75
  run "$PLAN"
  assert_failure 75
  assert_output --partial 'planned 1'
  assert_equal "$(outcome)" BLOCKED
  assert_equal "$(grep -c '#plan' "$SHEET")" 1
}

@test "a row that failed before the budget stop keeps the pass FAILED, exit 1" {
  sheet '- [ ] feat(brand): a brand kit #plan <!-- id:sc-1 -->\n- [ ] fix(ui): the menu #plan <!-- id:sc-2 -->\n'
  rcs 1 75
  run "$PLAN"
  assert_failure 1
  assert_output --partial 'model call failed'
  assert_equal "$(outcome)" FAILED
}
