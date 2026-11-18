#!/usr/bin/env bats
# .config/agent-panel/typed-prefixes.conf is the one table of prompts the fleet types into a session
# as if the human had. A writer whose text the table misses reads as the human typing: the session
# is held open for the human keep (agent-panel) and its asks are settled by the fleet's own prompt
# (agent-ask settle-session, the 2026-11-16 /wind-down incident). agent-panel's cargo test holds the
# Rust reader to the same golden.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  . "$REPO_ROOT/.local/lib/typed-prefixes.sh"
}

# The literal text each writer types, up to its first expansion: one line per text.
writer_texts() {
  local b="$REPO_ROOT/.local/bin" l="$REPO_ROOT/.local/lib"
  sed -n 's/^: "${RESTORE_PROMPT:=\([^$%]*\).*/\1/p' "$b/fleet-dispatch"
  sed -n 's/.*\(This is agent-queue item \)\$.*/\1/p' "$b/fleet-dispatch" | sort -u
  sed -n 's/^WAKE_TEXT="${CLAUDE_ACCT_WAKE_TEXT:-\([^$}]*\)}"$/\1/p' "$l/claude-acct-auth.sh"
  sed -n 's/.*cmd="\(\/wind-down[^"]*\)".*/\1/p' "$b/fleet-shepherd"
  sed -n 's/.*"\(Answer to ask \)\$.*/\1/p' "$b/agent-ask" | sort -u
  sed -n 's/.*p="\(This session was [a-z]*\) .*/\1/p' "$b/claude-acct"
}

every_writer_typed() {
  local t n=0
  while IFS= read -r t; do
    n=$((n + 1))
    fleet_typed "$t" || { echo "no line of $TYPED_PREFIXES starts: $t"; return 1; }
  done < <(writer_texts)
  # restore, brief, wake, wind-down, answer, parked, moved: a writer that moved its text drops out here
  [ "$n" -ge 7 ] || { echo "found $n writer texts, want 7"; return 1; }
}

@test "the shell reader and claude-recall agree with the shared golden" {
  local want p t got
  run python3 -I - "$REPO_ROOT/.local/bin/claude-recall" "$REPO_ROOT/tests/fixtures/typed-prompts.tsv" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("claude_recall", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("claude_recall", loader))
loader.exec_module(mod)
for ln in open(sys.argv[2], encoding="utf-8"):
    ln = ln.rstrip("\n")
    if ln and not ln.startswith("#"):
        want, p = ln.split("\t", 1)
        got = "fleet" if mod.fleet_typed(p.replace("\\n", "\n")) else "human"
        if got != want:
            print(f"claude-recall: want {want}, got {got}: {p}")
EOF
  assert_success
  assert_output ''
  while IFS=$'\t' read -r want p; do
    [[ -z "$want" || "$want" == \#* ]] && continue
    t=$(printf '%b' "$p")
    if fleet_typed "$t"; then got=fleet; else got=human; fi
    [ "$got" = "$want" ] || { echo "typed-prefixes.sh: want $want, got $got: $p"; return 1; }
  done < "$REPO_ROOT/tests/fixtures/typed-prompts.tsv"
}

@test "every writer types a text the table calls fleet-typed" {
  run every_writer_typed
  assert_success
  # Negative control: a table missing the answer line misses agent-ask's writer.
  grep -v '^task Answer to ask$' "$TYPED_PREFIXES" > "$SANDBOX/typed.conf"
  TYPED_PREFIXES="$SANDBOX/typed.conf" run every_writer_typed
  assert_failure
  assert_output --partial 'starts: Answer to ask'
}

@test "a missing table says so and calls nothing fleet-typed" {
  TYPED_PREFIXES="$SANDBOX/none.conf" run fleet_typed "/wind-down"
  assert_failure
  assert_output --partial 'typed-prefixes: no entries'
}
