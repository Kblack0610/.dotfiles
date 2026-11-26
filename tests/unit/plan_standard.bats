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

# systems_stub: project-stage-check's systems (ci, ui), what an `epic: new` line's system is checked against.
systems_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/project-stage-check" <<'SH'
#!/usr/bin/env bash
[ "$2 $3" = "--list --json" ] && [ -z "${NO_SYSTEMS:-}" ] && echo '[{"id":"ci"},{"id":"ui"}]'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/project-stage-check"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# epic_new <shortlist>: stubs for what an `epic: new` line is checked against: the systems, and the
# one shortlist `notes ptask similar --epic --json` prints (a JSON array); any other call prints nothing.
epic_new() {
  labbed
  systems_stub
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/sim.json"
  cat > "$BATS_TEST_TMPDIR/bin/notes" <<SH
#!/usr/bin/env bash
[ -z "\${NO_SIMILAR:-}" ] || exit 1
case " \$* " in *" similar --epic --json "*) cat "$BATS_TEST_TMPDIR/sim.json" ;; esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/notes"
}

# proposal <title> <overlap> -> a base plan proposing <title>, with <overlap> on its Overlap: line.
proposal() {
  printf 'epic: new %s\n\n' "$1"
  base | sed "s|^- Overlap: .*|- Overlap: $2|"
}

@test "an epic: new proposal passes once its shortlist is named on Overlap:" {
  epic_new '[{"id":"lb-1","percent":40,"text":"x","kind":"row","lane":"human"},{"id":"","percent":30,"text":"y","kind":"row","lane":"human"},{"id":"lb-2","percent":35,"text":"z","kind":"row","lane":"agent"}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1 is the ci standing epic, lb-2 a ci story.')"
  assert_success
  assert_output ''
}

@test "an epic: new proposal is denied for each shortlist id Overlap: does not name" {
  epic_new '[{"id":"lb-1","percent":40,"text":"x","kind":"row","lane":"human"},{"id":"lb-2","percent":35,"text":"z","kind":"row","lane":"agent"}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1 is other work.'; echo; echo '- Existing: lb-2 is read here, not on Overlap.')"
  assert_output --partial 'plan-standard: 1 gap'
  assert_output --partial 'Overlap: does not name lb-2'
}

@test "the shortlist is the one notes ptask add shows: its rows, epics and plans all need naming" {
  epic_new '[{"id":"lb-1","percent":90,"kind":"row"},{"id":"lb-2","percent":80,"kind":"row"},{"id":"lb-7","percent":12,"kind":"epic"},{"id":"lb-8","percent":14,"kind":"plan","text":"plan _live/p.md serves lb-8: lobby"},{"id":"lb-7","percent":11,"kind":"plan"}]'
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1, lb-2, lb-7 and lb-8 are other work.')"
  assert_output ''
  run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'lb-1 and lb-2 are other work.')"
  assert_output --partial 'does not name lb-7 lb-8'
}

@test "an epic: new proposal needs a listed system, no priority and a feature title" {
  epic_new '[]'
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
  NO_SIMILAR=1 run gate labbed "$(proposal 'epic(ui): a lobby the player can open' 'none.')"
  assert_output --partial 'printed no shortlist'
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
  # A fenced example above the real line is no epic: the real one is checked.
  run gate untyped "$(printf '```\nepic: ot-2\n```\nepic: ot-1\n\n'; base)"
  assert_output ''
  # Overlap lists other work, so with no epic: line it does not move an exempt project onto a board.
  run gate untyped "$(base | sed 's|^- Overlap: .*|- Overlap: ot-1 checked, unrelated.|')"
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
  epic_new '[]'
  run gate labbed "$(printf '```\nepic: new epic(ui): a lobby\n```\n\n'; base)"
  assert_output --partial 'No epic: <id> line'
}

# The real notes (NOTES_BIN, set by the CI notes job; skips without it) on a board where six rows
# outrank an open epic, lb-9, and a live plan serves lb-9. 2026-11-24: ar-5349 copied ar-4724, whose
# epic no row shortlist showed.
crowded_board() {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  labbed
  systems_stub
  # ptask add gives an epic an id from its tracker's code
  jq '.trackers.labbed.code = "lb"' "$HOME/.config/shared-hooks/project-map.json" > "$BATS_TEST_TMPDIR/m.json"
  mv "$BATS_TEST_TMPDIR/m.json" "$HOME/.config/shared-hooks/project-map.json"
  ln -sf "$NOTES_BIN" "$BATS_TEST_TMPDIR/bin/notes"
  # the live plans notes reads are the stowed plan reader's
  mkdir -p "$HOME/.local/lib"
  ln -sf "$(cd "$ROOT" && pwd)/.local/lib/plan-phases.sh" "$HOME/.local/lib/plan-phases.sh"
  local proj="$HOME/.notes/lab/projects/current/labbed" w n=10
  : > "$proj/summary.md"
  {
    printf '# labbed\n\nVersion: v0.1.0\n\n## Inbox\n\n## Tasks\n'
    for w in alpha bravo charlie delta echo foxtrot; do
      n=$((n + 1))
      printf -- '- [ ] feat(ui): a lobby the player can open with friends %s #low <!-- id:lb-%s -->\n' "$w" "$n"
    done
    printf -- '- [ ] epic(ui): friends gather in one lobby <!-- id:lb-9 -->\n'
  } > "$proj/README.md"
  printf '# labbed agent\n\n## Tasks\n- [ ] fix(ci): a story #low <!-- id:lb-2 -->\n' > "$proj/agent/README.md"
  mkdir -p "$HOME/.agent/plans/_live" "$HOME/.config/notes"
  printf '# Lobby screens the player opens with friends\n\nepic: lb-9\n\n## Phases\n\n- [ ] P1 the lobby\n' > "$HOME/.agent/plans/_live/lobby.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' > "$HOME/.config/notes/config.toml"
  export NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
}

@test "end to end: an epic: new shortlist names the open epic and live plan that rows outrank" {
  crowded_board
  t='epic(ui): a lobby the player can open with friends'
  run notes ptask labbed similar --epic --json -- "$t"
  assert_success
  [ "$(jq -c '[.[] | select(.id == "lb-9") | .kind]' <<<"$output")" = '["epic","plan"]' ] || fail "lb-9 as epic and plan: $output"
  [ "$(jq '[.[] | select(.kind == "row")] | length' <<<"$output")" = 5 ] || fail "five rows: $output"
  run gate labbed "$(proposal "$t" 'lb-11, lb-12, lb-13, lb-14 and lb-15 are other work.')"
  assert_output --partial 'Overlap: does not name lb-9'
  run gate labbed "$(proposal "$t" 'lb-11, lb-12, lb-13, lb-14 and lb-15 are other work; lb-9 is a social lobby, other work.')"
  assert_output ''
  # notes ptask add, from a session the human opened, refuses the epic until lb-9 is checked too
  run env CLAUDE_CODE_SESSION_ID=feedface0123 AGENT_QUEUE_ITEM= AGENTCTL_NAME= notes ptask labbed add --checked lb-11,lb-12,lb-13,lb-14,lb-15 -- "$t"
  [ "$status" -eq 5 ] || fail "exit $status: $output"
  assert_output --partial $'lb-9\t'
  assert_output --partial 'plan _live/lobby.md serves lb-9'
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
