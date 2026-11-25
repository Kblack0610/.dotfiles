#!/usr/bin/env bats
# plan-standard.sh: the gate reads planning.md, so these run against the real doc. It checks the
# Epic, Phases and Chain rules only; a plan with thin or missing sections passes.

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

ROOT="$BATS_TEST_DIRNAME/../.."
HOOK="$ROOT/.claude/hooks/plan-standard.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/src/docs" "$HOME/.config/shared-hooks" "$HOME/.config/agentctl" "$HOME/docs"
  ln -s "$(cd "$ROOT" && pwd)/.local/src/docs/planning.md" "$HOME/.local/src/docs/planning.md"
  ln -s "$(cd "$ROOT" && pwd)/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/project-name.sh"
  : > "$HOME/docs/standards.md"
  cat > "$HOME/.config/shared-hooks/project-map.json" <<'JSON'
{"paths": {}, "trackers": {
  "agame": {"type": "game"}, "anapp": {"type": "app"}, "aninfra": {"type": "infra"},
  "untyped": {}, "gig": {"client": "acme"}}}
JSON
  for p in agame anapp aninfra untyped gig; do mkdir -p "$HOME/work/$p"; done
  unset PROJECT_MAP_FILE
}

# base -> a plan that passes the base standard.
base() {
  cat <<EOF
# A plan

## Changes

Adds: one doc row.
Removes: nothing.
Files: no rows.
Net: +1 row.

## Context

The ask, and what done looks like.

## Approach

What we will do.

Rejected: the other way.

## Reviewed

- Existing: the readers.
- Overlap: no open rows.
- Standards: \`~/docs/standards.md\`

## Risks

Small, and reversible.

## Verification

Real surface, negative control, live when deployed.
EOF
}

# without <section> reads a plan on stdin and drops that section.
without() { awk -v h="## $1" '/^## /{skip = ($0 == h)} !skip'; }

@test "the sections table is not checked: a plan with none of them passes" {
  run gate aninfra "$(printf '# A plan\n\nDo the thing.\n')"
  assert_output ''
  run gate agame "$(base | without Verification | without Risks)"
  assert_output ''
  run gate aninfra "$(base | sed 's/^Small, and reversible\.$/n\/a/' | sed '/Standards:/d')"
  assert_output ''
}

gate() { # gate <project> <plan>
  jq -nc --arg c "$HOME/work/$1" --arg p "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "ExitPlanMode", cwd: $c, tool_input: {plan: $p}}' \
    | bash "$HOOK"
}

prompt() { # prompt <project> <mode>
  jq -nc --arg c "$HOME/work/$1" --arg m "$2" \
    '{hook_event_name: "UserPromptSubmit", permission_mode: $m, cwd: $c}' | bash "$HOOK"
}

@test "a complete base plan passes for an untyped project" {
  run gate untyped "$(base)"
  assert_success
  assert_output ''
}


# phases <n> -> a ## Phases section with n open lines and one ticked one.
phases() { printf '\n## Phases\n\n- [x] P1 done (#1)\n'; for i in $(seq "$1"); do printf -- '- [ ] P%s p\n' "$((i + 1))"; done; }

@test "a multi-phase plan that runs in one session is denied" {
  run gate untyped "$(base; printf '\nRun with /one-shot, one phase after another in this session.\n'; phases 2)"
  assert_output --partial 'plan-standard: 1 gap'
  assert_output --partial '2 open phases run as a chain'
  assert_output --partial 'never \"Run with /one-shot, one phase after another in this session\"'
  run gate untyped "$(base; printf '\nAll of this is harness work, run attended in a single session.\n'; phases 3)"
  assert_output --partial '3 open phases run as a chain'
}

@test "one open phase, or session words that run nothing, pass the chain check" {
  run gate untyped "$(base; printf '\nRun with /one-shot, one phase after another in this session.\n'; phases 1)"
  assert_output ''
  run gate untyped "$(base; printf '\nAnswers given in this session: none.\nP1 was built in this session.\n'; phases 2)"
  assert_output ''
  run gate untyped "$(base; printf '\nThe old text said "Run phases back to back in this session".\n'; phases 2)"
  assert_output ''
  run gate untyped "$(base; printf '\n```\nrun it all in this session\n```\n'; phases 2)"
  assert_output ''
  run gate untyped "$(base; printf '\nNever run phases in this session; file them as a chain.\n'; phases 2)"
  assert_output ''
}

@test "the chain check counts open phases as the queue does" {
  [ -r "$ROOT/.local/lib/plan-phases.sh" ] # the parser the hook sources
  run gate untyped "$(base; printf '\nRun them all in one session.\n\n## Phases\n\n* [ ] p1\n* [ ] p2\n')"
  assert_output --partial '2 open phases run as a chain'
  run gate untyped "$(base; printf '\nRun them all in one session.\n\n## Phases\n\n- [ ] p1\n  - [ ] a step inside p1\n')"
  assert_output ''
}

@test "a phase marker agent-queue add --plan would refuse is denied, one it accepts passes" {
  # POSITIVE CONTROL: a consumed result, a comma list and (independent) all pass.
  run gate untyped "$(base; printf '\n## Phases\n\n- [ ] P1 one (independent)\n- [ ] P2 two (after 1; needs the parser from P1)\n- [ ] P3 three (after 1, 2; needs both outputs)\n')"
  assert_output ''
  # NEGATIVE CONTROLS, each the parser's own refusal.
  run gate untyped "$(base; printf '\n## Phases\n\n- [ ] P1 one\n- [ ] P2 two (after 1)\n')"
  assert_output --partial 'plan-standard: 1 gap'
  assert_output --partial 'phase 2: (after 1) names no result it consumes'
  run gate untyped "$(base; printf '\n## Phases\n\n- [ ] P1 one\n- [ ] P2 two (after 1, since it edits ship.sh)\n')"
  assert_output --partial 'waits on a shared file'
  run gate untyped "$(base; printf '\n## Phases\n\n- [ ] P1 one\n- [ ] P2 one\n- [ ] P3 three (after 1 and 2)\n')"
  assert_output --partial '(after 1 and 2) does not parse'
  # A plan with no Phases checklist is never run through the parser.
  run gate untyped "$(base; printf '\nThe wait is (after 1) in prose.\n')"
  assert_output ''
}

@test "plan mode gets the Chain and Phases rules, and no section list" {
  run prompt aninfra plan
  assert_success
  assert_output --partial 'additionalContext'
  assert_output --partial 'Chain: a plan with more than one'
  assert_output --partial 'Phases: a plan with more than one'
  refute_output --partial 'three rules'
  refute_output --partial 'Epic:'
  refute_output --partial '## Target'
  refute_output --partial 'Depth:'
  # The rule lines arrive without their Why: history.
  refute_output --partial 'Why:'
}

# A project with a board must name an epic( row; one without (every project above) is exempt.
labbed() {
  jq '.trackers.labbed = {"lab": "personal"}' "$HOME/.config/shared-hooks/project-map.json" > "$BATS_TEST_TMPDIR/m.json"
  mv "$BATS_TEST_TMPDIR/m.json" "$HOME/.config/shared-hooks/project-map.json"
  mkdir -p "$HOME/work/labbed" "$HOME/.notes/lab/projects/current/labbed/agent"
  printf -- '- [ ] epic(ci): ci to standard #high <!-- id:lb-1 -->\n' > "$HOME/.notes/lab/projects/current/labbed/README.md"
  printf -- '- [ ] fix(ci): a story #of/lb-1 <!-- id:lb-2 -->\n' > "$HOME/.notes/lab/projects/current/labbed/agent/README.md"
}

@test "a project with a board needs an epic: line naming an epic row" {
  labbed
  run gate labbed "$(base)"
  assert_output --partial 'No epic: <id> line'
  run gate labbed "$(printf 'epic: lb-1\n\n'; base)"
  assert_success
  assert_output ''
}

@test "an epic: line naming a story or a missing id is denied" {
  labbed
  run gate labbed "$(printf 'epic: lb-2\n\n'; base)"
  assert_output --partial 'epic: lb-2 is not an epic( row'
  run gate labbed "$(printf 'epic: lb-999\n\n'; base)"
  assert_output --partial 'epic: lb-999 is not an epic( row'
}

@test "an epic: line inside a code fence does not count" {
  labbed
  run gate labbed "$(printf '```\nepic: lb-1\n```\n\n'; base)"
  assert_output --partial 'No epic: <id> line'
}

@test "an example checklist inside a code fence is not a second phase, so its epic may be a standing one" {
  labbed
  run gate labbed "$(printf 'epic: lb-1\n\n'; base; printf '\n## Phases\n\n- [ ] one\n\n```\n- [ ] a\n- [ ] b\n```\n')"
  assert_output ''
}

@test "a plan with Phases needs a feature epic, not a standing to-standard one" {
  labbed
  printf -- '- [ ] epic(ci): move jobs to standard runners #high <!-- id:lb-3 -->\n' >> "$HOME/.notes/lab/projects/current/labbed/README.md"
  run gate labbed "$(printf 'epic: lb-1\n\n'; base; phases 1)"
  assert_output --partial 'epic: lb-1 is a standing'
  run gate labbed "$(printf 'epic: lb-3\n\n'; base; phases 1)"
  assert_output ''
}

@test "a one-phase checklist may name a standing to-standard epic" {
  labbed
  run gate labbed "$(printf 'epic: lb-1\n\n'; base; printf '\n## Phases\n\n- [ ] the task\n')"
  assert_output ''
}

@test "plan mode names the Epic: rule only where it is checked" {
  labbed
  run prompt labbed plan
  assert_output --partial 'Epic:'
  refute_output --partial 'Why:'
  rm -rf "$HOME/.notes/lab"
  run prompt labbed plan
  refute_output --partial 'Epic:'
}

@test "a machine with no lab sheets skips the epic check" {
  labbed
  rm -rf "$HOME/.notes/lab"
  run gate labbed "$(base)"
  assert_output ''
}

@test "a project with no board needs no epic line" {
  run gate untyped "$(base)"
  refute_output --partial 'epic'
}

# epic_new <similar human> <similar agent>: stubs for what an `epic: new` line is checked against:
# project-stage-check's systems (ci, ui) and `notes ptask similar` per lane (JSON arrays).
epic_new() {
  labbed
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/sim.human"
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/sim.agent"
  cat > "$BATS_TEST_TMPDIR/bin/project-stage-check" <<'SH'
#!/usr/bin/env bash
[ "$2 $3" = "--list --json" ] && [ -z "${NO_SYSTEMS:-}" ] && echo '[{"id":"ci"},{"id":"ui"}]'
SH
  cat > "$BATS_TEST_TMPDIR/bin/notes" <<SH
#!/usr/bin/env bash
case " \$* " in *" --agent "*) cat "$BATS_TEST_TMPDIR/sim.agent" ;; *" similar "*) cat "$BATS_TEST_TMPDIR/sim.human" ;; esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# proposal <title> <overlap> -> a base plan proposing <title>, with <overlap> on its Overlap: line.
proposal() {
  printf 'epic: new %s\n\n' "$1"
  base | sed "s|^- Overlap: .*|- Overlap: $2|"
}

@test "an epic: new proposal passes once its shortlist is named on Overlap:" {
  epic_new '[{"id":"lb-1","percent":40,"text":"x"},{"id":"","percent":30,"text":"y"}]' '[{"id":"lb-2","percent":35,"text":"z"}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1 is the ci standing epic, lb-2 a ci story.')"
  assert_success
  assert_output ''
}

@test "an epic: new proposal is denied for each shortlist id Overlap: does not name" {
  epic_new '[{"id":"lb-1","percent":40,"text":"x"}]' '[{"id":"lb-2","percent":35,"text":"z"}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1 is other work.'; echo; echo '- Existing: lb-2 is read here, not on Overlap.')"
  assert_output --partial 'plan-standard: 1 gap'
  assert_output --partial 'Overlap: does not name lb-2'
}

@test "the shortlist is the top 5 of both lanes merged, as notes ptask add shows it" {
  epic_new '[{"id":"lb-1","percent":90},{"id":"lb-2","percent":80},{"id":"lb-3","percent":70}]' '[{"id":"lb-4","percent":60},{"id":"lb-5","percent":50},{"id":"lb-9","percent":21}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1, lb-2, lb-3, lb-4 and lb-5 are other work.')"
  assert_output ''
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1, lb-2, lb-3 and lb-4 are other work.')"
  assert_output --partial 'does not name lb-5'
  refute_output --partial 'lb-9'
}

@test "an epic: new proposal needs a listed system, no priority and a feature title" {
  epic_new '[]' '[]'
  run gate labbed "$(proposal 'epic(gameplay): school days' 'none.')"
  assert_output --partial 'names epic(gameplay), no system of labbed: one of ci,ui'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open #low' 'none.')"
  assert_output --partial 'carries a priority, which notes refuses on an epic'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'none.')"
  assert_output ''
  run gate labbed "$(proposal 'epic(ui): ui to standard' 'none.')"
  assert_output --partial 'title, which notes and project-stage-check file'
  run gate labbed "$(proposal 'epic(ui) a lobby' 'none.')"
  assert_output --partial 'is no epic(<system>): <outcome>'
  NO_SYSTEMS=1 run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'none.')"
  assert_output --partial 'printed no system list'
}

# other: a second board, code ot, whose sheet holds epic ot-1 and story ot-2, and whose one system is
# gameplay (labbed's, code lb, are ci and ui); the stub lists each board's own.
other() {
  epic_new '[]' '[]'
  jq '.trackers.other = {"lab": "personal", "code": "ot"} | .trackers.labbed.code = "lb"' "$HOME/.config/shared-hooks/project-map.json" > "$BATS_TEST_TMPDIR/m.json"
  mv "$BATS_TEST_TMPDIR/m.json" "$HOME/.config/shared-hooks/project-map.json"
  mkdir -p "$HOME/.notes/lab/projects/current/other"
  printf -- '- [ ] epic(gameplay): school days <!-- id:ot-1 -->\n- [ ] fix(gameplay): a story #of/ot-1 <!-- id:ot-2 -->\n' > "$HOME/.notes/lab/projects/current/other/README.md"
  cat > "$BATS_TEST_TMPDIR/bin/project-stage-check" <<'SH'
#!/usr/bin/env bash
case "$1" in other) echo '[{"id":"gameplay"}]' ;; *) echo '[{"id":"ci"},{"id":"ui"}]' ;; esac
SH
}

@test "a plan naming another project's epic is checked for that project, not the session's cwd (ar-5288)" {
  other
  run gate untyped "$(printf 'epic: ot-2\n\n'; base)"
  assert_output --partial 'gap(s) for other'
  assert_output --partial 'epic: ot-2 is not an epic( row'
  run gate untyped "$(printf 'epic: ot-1\n\n'; base)"
  assert_output ''
}

@test "an epic: new whose Overlap rows are another project's is checked on that board, else on the cwd's (ar-5288)" {
  other
  run gate labbed "$(proposal 'epic(gameplay): a lobby the player can open' 'ot-1 is the epic it grows.')"
  assert_output ''
  run gate labbed "$(proposal 'epic(gameplay): a lobby the player can open' 'none.')"
  assert_output --partial "no system of labbed: one of ci,ui; labbed is this session's board"
  run gate labbed "$(proposal 'epic(gameplay): a lobby the player can open' 'ot-1 and lb-2 are other work.')"
  assert_output --partial 'no system of labbed'
}

@test "an epic: new line inside a code fence is no proposal" {
  epic_new '[]' '[]'
  run gate labbed "$(printf '```\nepic: new epic(ui): a lobby\n```\n\n'; base)"
  assert_output --partial 'No epic: <id> line'
}

@test "plan mode injects once per session" {
  tp="$BATS_TEST_TMPDIR/t.jsonl"
  : > "$tp"
  run bash -c "jq -nc --arg c '$HOME/work/aninfra' --arg t '$tp' '{hook_event_name: \"UserPromptSubmit\", permission_mode: \"plan\", cwd: \$c, transcript_path: \$t}' | bash '$HOOK'"
  assert_output --partial 'additionalContext'
  printf '%s\n' "$output" >> "$tp"
  run bash -c "jq -nc --arg c '$HOME/work/aninfra' --arg t '$tp' '{hook_event_name: \"UserPromptSubmit\", permission_mode: \"plan\", cwd: \$c, transcript_path: \$t}' | bash '$HOOK'"
  assert_success
  assert_output ''
}

@test "other modes get nothing" {
  run prompt aninfra default
  assert_output ''
}

@test "a missing doc fails open" {
  rm "$HOME/.local/src/docs/planning.md"
  run gate aninfra "$(base)"
  assert_success
  assert_output ''
}

@test "an empty plan fails open" {
  run gate aninfra ''
  assert_success
  assert_output ''
}
