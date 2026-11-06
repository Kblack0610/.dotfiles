#!/usr/bin/env bats
# `sessions search`, the table behind prefix R: a title prints whole, a project gets 20
# columns, a row with no title falls back to its first prompt capped at one row's worth,
# and only sessions a human started are listed unless --all.
# `claude-recall` is a stub reporting nothing new, so the fixture index is what is read.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SUBJECT="$REPO_ROOT/.local/bin/sessions"
  export CLAUDE_RECALL="$SANDBOX/bin/claude-recall"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CLAUDE_RECALL"; chmod +x "$CLAUDE_RECALL"

  TITLE='Waybar right-side overflow and agent chips across both monitors, wrapped'
  PROMPT="$(printf 'prompt%.0s ' {1..30})"
  mkdir -p "$HOME/.agent/sessions"
  # id project updated mtime cwd branch title titles_all first last files prs kind
  printf '%s\t' aaaaaaaa-1 dotfiles-agent-runtime-x - 200 /w main "$TITLE" "$TITLE" first last f.sh - hand \
    | sed 's/\t$/\n/' > "$HOME/.agent/sessions/index.tsv"
  printf '%s\t' bbbbbbbb-2 proj - 100 /w main - - "$PROMPT" last f.sh - hand \
    | sed 's/\t$/\n/' >> "$HOME/.agent/sessions/index.tsv"
  for k in runner dispatched; do
    printf '%s\t' "cccccccc-$k" proj - 50 /w main "a $k pass" "a $k pass" first last f.sh - "$k" \
      | sed 's/\t$/\n/' >> "$HOME/.agent/sessions/index.tsv"
  done
}

@test "a long title prints whole" {
  run "$SUBJECT" search overflow
  assert_success
  assert_output --partial "$TITLE"
}

@test "the project column holds 20 characters and the header lines up with it" {
  run "$SUBJECT" search overflow
  assert_line --index 0 --regexp '^ID +AGE +LIVE +PROJECT {15}WHAT$'
  assert_output --partial 'dotfiles-agent-runti  Waybar'
}

@test "a row with no title falls back to its first prompt, capped at 80 characters" {
  run "$SUBJECT" search prompt
  assert_success
  assert_output --partial "${PROMPT:0:80}"
  refute_output --partial "${PROMPT:0:81}"
}

@test "search matches words the row does not show" {
  run "$SUBJECT" search f.sh
  assert_output --partial "$TITLE"
  assert_output --partial 'proj'
}

@test "runner and dispatched sessions are hidden unless --all" {
  run "$SUBJECT" search pass
  assert_success
  refute_output --partial 'a runner pass'
  refute_output --partial 'a dispatched pass'
  run "$SUBJECT" search --all pass
  assert_output --partial 'a runner pass'
  assert_output --partial 'a dispatched pass'
}

@test "an index from before the kind column still lists every row, then rebuilds" {
  logging_recall
  cut -f1-12 "$HOME/.agent/sessions/index.tsv" > "$HOME/old.tsv"
  mv "$HOME/old.tsv" "$HOME/.agent/sessions/index.tsv"
  run "$SUBJECT" _filter --cached pass
  assert_output --partial 'a runner pass'
  run "$SUBJECT" index
  run cat "$HOME/recall.log"
  assert_output 'recall cards'
}

@test "--pick opens a picker with no preview pane" {
  mkdir -p "$SANDBOX/bin"
  printf '#!/usr/bin/env bash\necho "$*" > "$HOME/fzf.args"\ncat >/dev/null\n' > "$SANDBOX/bin/fzf"
  chmod +x "$SANDBOX/bin/fzf"
  run "$SUBJECT" compact --pick
  run cat "$HOME/fzf.args"
  assert_success
  refute_output --partial 'preview'
  assert_output --partial '--wrap'
}

# The recall stub, logging each run: a refresh is a claude-recall run.
logging_recall() {
  printf '#!/usr/bin/env bash\necho "recall $*" >> "$HOME/recall.log"\n' > "$CLAUDE_RECALL"
}

@test "a keystroke filters the cached index and never runs claude-recall" {
  logging_recall
  run "$SUBJECT" _filter --cached overflow
  assert_success
  assert_output --partial "$TITLE"
  refute [ -e "$HOME/recall.log" ]
  # Negative control: without --cached the same filter refreshes first.
  run "$SUBJECT" _filter overflow
  assert [ -e "$HOME/recall.log" ]
}

@test "the window opens on the cached index and refreshes it detached, not under the cursor" {
  logging_recall
  mkdir -p "$SANDBOX/bin"
  printf '#!/usr/bin/env bash\necho "$*" > "$HOME/fzf.args"\ncat > "$HOME/fzf.rows"\n' > "$SANDBOX/bin/fzf"
  printf '#!/usr/bin/env bash\necho "setsid $*" >> "$HOME/setsid.log"\n' > "$SANDBOX/bin/setsid"
  chmod +x "$SANDBOX/bin/fzf" "$SANDBOX/bin/setsid"
  run script -qec "$(printf '%q ' "$SUBJECT" search)" /dev/null
  run cat "$HOME/fzf.rows"
  assert_output --partial "$TITLE"
  refute [ -e "$HOME/recall.log" ]
  run cat "$HOME/setsid.log"
  assert_output --regexp '^setsid -f .*/sessions index$'
  run cat "$HOME/fzf.args"
  assert_output --partial '_filter --cached {q}'
  refute_output --partial 'start:'
}
