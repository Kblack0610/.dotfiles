#!/usr/bin/env bats
# skill-drift --docs: DEADPATH, NOCMD, ADMIT, KNOB and LINEREF over the global doc set, the deterministic
# baseline the nightly docs-cleanup pass starts from. Each test builds a doc with a
# real and a dead reference and asserts only the dead one is reported.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  mkdir -p "$HOME/real"
}

@test "a dead path is reported with its doc and line, a live one is not" {
  printf '# doc\nSee ~/real for it.\nAnd ~/gone/file.md too.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs
  assert_failure 1
  assert_output --partial '~/gone/file.md'
  assert_output --partial '(line 3)'
  refute_output --partial '~/real '
  assert_output --partial '1 finding(s) across 1 doc(s)'
}

@test "a command missing from PATH inside a bash fence is NOCMD" {
  printf '```bash\nno-such-tool-xyz --flag\nls -la\n```\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_failure 1
  run jq -r '.findings[] | "\(.type) \(.item)"' <<< "$output"
  assert_output 'NOCMD no-such-tool-xyz'
}

@test "a clean doc set exits 0 and json names the doc count" {
  printf 'Only ~/real here.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_success
  run jq -r '"\(.docs) \(.drift)"' <<< "$output"
  assert_output '1 0'
}

@test "an empty doc set refuses to report success" {
  DRIFT_DOCS="$HOME/missing.md" run "$DRIFT" --docs
  assert_failure 2
}

@test "a placeholder path is checked by its concrete directory only" {
  # Cut at the <, `p<N>/` read as a missing `~/real/p`; a brace list still
  # names its dead directory.
  printf 'Save to `~/real/p<N>/`, `~/real/{a,b}.md` and `~/gone/{a,b}.md`.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '.findings[] | .item' <<< "$output"
  assert_output '~/gone'
}

@test "comments, heredoc bodies and multi-line quoted strings in a fence are not commands" {
  printf '%s\n' '```bash' \
    '# invert a binding / swap two verbs' \
    "gh api graphql -f query='" \
    '  number' \
    "'" \
    "cat <<'EOF' > ~/x" \
    'changelog -- not a tool' \
    'EOF' \
    'no-such-tool-xyz --flag' \
    '```' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '.findings[] | select(.type == "NOCMD") | .item' <<< "$output"
  # negative control: the real missing tool after them is still found
  assert_output 'no-such-tool-xyz'
}

@test "a shell function the doc defines is not NOCMD, a missing tool beside it is" {
  printf '%s\n' '```bash' \
    'mem0() { curl -fsS "$@"; }' \
    'mem0 -X POST "$URL/search"' \
    'function ui-bounds { :; }' \
    'ui-bounds --text x' \
    'no-such-tool-xyz --flag' \
    'deploy-xyz --now' \
    '```' \
    '```js' \
    'deploy-xyz() { }' \
    '```' \
    'Prose naming lint-xyz() is not a definition either.' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | select(.type == "NOCMD") | .item] | sort | join(" ")' <<< "$output"
  # a definition in a js fence does not excuse deploy-xyz in the bash fence
  assert_output 'deploy-xyz no-such-tool-xyz'
}

@test "an @ is part of a path (agentctl@.service), a dead one keeps it in the report" {
  touch "$HOME/real/agentctl@.service"
  printf 'Unit `~/real/agentctl@.service` and `~/real/gone@.service`.\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '.findings[] | .item' <<< "$output"
  # negative control: the missing unit is still found, whole
  assert_output '~/real/gone@.service'
}

@test "a space is part of a path inside backticks only" {
  mkdir -p "$HOME/real/App Support"
  touch "$HOME/real/App Support/x.md"; mkdir -p "$HOME/real/Bare Dir"; touch "$HOME/real/Bare Dir/z.md"
  printf '%s\n' \
    'In ticks `~/real/App Support/x.md` and `~/real/App Support/x.md --flag`.' \
    'Bare ~/real/Bare Dir/z.md is cut at the space.' \
    'Dead in ticks `~/real/Nope Dir/y.md`.' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | .item] | sort | join(" ")' <<< "$output"
  # the live spans pass; the bare line and the dead span are still reported
  assert_output '~/real/Bare ~/real/Nope'
}

@test "a spaced backtick path works in the \$HOME form and with several trailing words" {
  mkdir -p "$HOME/real/App Support"
  touch "$HOME/real/App Support/x.md"
  printf '%s\n' \
    'Home form `$HOME/real/App Support/x.md` and `~/real/App Support/x.md then more words`.' \
    'Dead with words `$HOME/real/Nope Dir/y.md and more`.' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | .item] | join(" ")' <<< "$output"
  assert_output '~/real/Nope'
}

@test "another host's path is not a dead path: scp-style host:~/ and ~/Library off macOS" {
  [ "$(uname -s)" != Darwin ] || skip "~/Library is checked on macOS"
  printf 'Token at `mac-mini:~/gone/token`.\nOpen ~/Library/Application Support/X.\nBut ~/gone/here is dead.\nPATH=$HOME/gone/a:~/gone/b\nFiles:~/gone/c\n' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_failure 1
  run jq -r '.findings[] | "\(.type) \(.item)"' <<< "$output"
  assert_output "$(printf 'DEADPATH ~/gone/a\nDEADPATH ~/gone/b\nDEADPATH ~/gone/c\nDEADPATH ~/gone/here')"
}

# KNOB reads the defaults from the scripts beside skill-drift, so the test takes the
# real default from the script rather than restating it.
knob_default() { grep -oE "^: \"\\\$\\{$1:=[0-9]+" "$REPO_ROOT/.local/bin/fleet-dispatch" | grep -oE '[0-9]+$'; }

@test "KNOB: a number that is not the knob's effective value is reported, the right one is not" {
  def=$(knob_default PLANNED_REBOOT_WINDOW_S)
  [ -n "$def" ]
  mkdir -p "$HOME/.config/agentctl/agents"
  printf 'DISPATCH_TARGET_PRESENT=30\n' > "$HOME/.config/agentctl/agents/fleet-dispatch.conf"
  printf '%s\n' \
    'Fill to `DISPATCH_TARGET_PRESENT` (50) while here.' \
    'A lost server waits `PLANNED_REBOOT_WINDOW_S` ('"$def"').' \
    'A lost server waits PLANNED_REBOOT_WINDOW_S (default '"$((def + 1))"').' \
    'Present fill is DISPATCH_TARGET_PRESENT is 30.' \
    'At night `DISPATCH_TARGET_PRESENT` is 40.' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | select(.type == "KNOB") | "\(.item) \(.detail)"] | join("\n")' <<< "$output"
  # a conf-only knob reads the conf (fleet-dispatch holds no default for its tuning), a default-only knob
  # uses its default, and a number that ends the sentence is still read
  assert_output "$(printf 'DISPATCH_TARGET_PRESENT states 50, the effective value is 30 (default none) (line 1)\nPLANNED_REBOOT_WINDOW_S states %s, the effective value is %s (default %s) (line 3)\nDISPATCH_TARGET_PRESENT states 40, the effective value is 30 (default none) (line 5)' "$((def + 1))" "$def" "$def")"
}

@test "KNOB: a bare name, a unit, a per-lane knob and a claim naming the conf pass" {
  def=$(knob_default PLANNED_REBOOT_WINDOW_S)
  mkdir -p "$HOME/.config/agentctl/agents"
  printf 'PLANNED_REBOOT_WINDOW_S=30\nLANE_CAP_XYZ=2\nSAME_CAP_XYZ=2\n' > "$HOME/.config/agentctl/agents/a.conf"
  printf 'LANE_CAP_XYZ=8\nSAME_CAP_XYZ=2\n' > "$HOME/.config/agentctl/agents/b.conf"
  printf '%s\n' \
    'Set `PLANNED_REBOOT_WINDOW_S` to taste.' \
    'Held `PLANNED_REBOOT_WINDOW_S` (30m) is a duration.' \
    'Each lane sets `LANE_CAP_XYZ` (8).' \
    'Two lanes set `SAME_CAP_XYZ` (5), one number each.' \
    'A fraction `PLANNED_REBOOT_WINDOW_S` is 30.5 here.' \
    '`PLANNED_REBOOT_WINDOW_S` ('"$def"'; the conf sets 30) live.' \
    '`PLANNED_REBOOT_WINDOW_S` ('"$def"'; the conf sets 31) is wrong.' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | select(.type == "KNOB") | .detail] | join("\n")' <<< "$output"
  # negative control: the claim with the wrong conf value is still caught
  assert_output "states $def with the conf at 31, the effective value is 30 (default $def) (line 7)"
}

@test "LINEREF: a path:N past the end of a real file is reported, by ~/ and by repo path" {
  printf 'a\nb\nc\n' > "$HOME/real/f.txt"
  mkdir -p "$HOME/repo/bin"
  git -C "$HOME/repo" init -q
  printf 'x\ny\n' > "$HOME/repo/bin/tool"
  printf '%s\n' \
    'See `~/real/f.txt:3` and `~/real/f.txt:4`.' \
    'A range ~/real/f.txt:2-9 and ~/real/f.txt:1-3.' \
    'Gone ~/gone/f.txt:9 is a dead path, not a line ref.' \
    'In repo `bin/tool:2` and `bin/tool:5`, another repo `src/x.ts:400`.' > "$HOME/repo/doc.md"
  DRIFT_DOCS="$HOME/repo/doc.md" run "$DRIFT" --docs --json
  run jq -r '[.findings[] | select(.type == "LINEREF") | .item] | sort | join(" ")' <<< "$output"
  assert_output 'bin/tool:5 ~/real/f.txt:2-9 ~/real/f.txt:4'
}

@test "ADMIT: a --from add with no pull is board-only, the passing forms are not" {
  printf '%s\n' \
    'Queue it: `agent-queue add --priority high --from board:p:<owner row> --slug x "t"`.' \
    'Take it: `agent-queue add --running --from board:p:1 "t"`.' \
    'Promote: `AGENT_QUEUE_PULL=dispatch agent-queue add --from board:p:2 "t"`.' \
    'By hand: `agent-queue add --from human "t"`, or `agent-queue add --from <src> "t"`.' \
    'Shepherd: `agent-queue add --from shepherd "t"` files a board row (exit 5).' \
    '```bash' \
    'agent-queue add --project p \' \
    '  --from auto:x "t"' \
    '```' > "$HOME/doc.md"
  DRIFT_DOCS="$HOME/doc.md" run "$DRIFT" --docs --json
  assert_failure 1
  run jq -r '[.findings[] | select(.type == "ADMIT") | "\(.item) \(.detail | split("`")[1])"] | join("\n")' <<< "$output"
  assert_output "$(printf 'doc.md:1 --from board:p:<owner row>\ndoc.md:7 --from auto:x')"
}
