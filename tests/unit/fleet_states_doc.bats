#!/usr/bin/env bats
# The bucket table in .local/src/docs/fleet-states.md is the one definition of every fleet-sessions
# bucket. This guard reads it as text and fails when (a) the bucket words fleet-sessions emits differ
# from the table's, (b) a row lacks an actor, action or pinning test, (c) a pinning test name has no
# `@test`, or (d) a row whose actor is the shepherd is missing from fleet-shepherd's due functions.
# The close table there drives the close flow's checks: (e) its Step ids and verdict words, in order,
# must be the `# step:<id>` tagged branches of close_verdict in CLOSE_JQ, and (f) the committed
# fleet-close-flow.svg must be close-flow-svg's output of it.
# The Owners table names one writer per shared fact: (g) its forbidden copy matches nothing outside the
# writer file, (h) the writer functions (shell or Rust) exist and take the lock the row names, and (i)
# its pins exist (a bats @test, or a Rust test fn).
# Each check takes its files as arguments, so the negative controls run it on a broken copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOC="$REPO_ROOT/.local/src/docs/fleet-states.md"
  SESSIONS="$REPO_ROOT/.local/bin/fleet-sessions"
  SHEPHERD="$REPO_ROOT/.local/bin/fleet-shepherd"
  SVG="$REPO_ROOT/.local/src/docs/fleet-close-flow.svg"
  GEN="$REPO_ROOT/.local/bin/close-flow-svg"
  PRIVATE="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}"
}

# rows <doc> -> bucket, actor, action and pinned, one row of the bucket table per line, split by
# \037: a tab is whitespace to `read`, so an empty cell between two would vanish
rows() {
  awk -F'|' '/^\| Bucket \| Entry facts/ {t = 1; next}
    t && /^\| ---/ {next}
    t && !/^\|/ {exit}
    t { for (i = 2; i <= 7; i++) gsub(/^ +| +$/, "", $i); print $2 "\037" $5 "\037" $6 "\037" $7 }' "$1"
}

# emitted <fleet-sessions> -> each bucket word it prints: `echo "WORD ...` in session_bucket and its
# helpers, and `printf 'NIGHTLY\t...`, `printf 'CHECKOUT\t...` and `printf 'SHARED\t...` for the rows that are not sessions
# (its other printf lines are caches)
emitted() {
  grep -oE "echo \"[A-Z]{4,} |printf '(NIGHTLY|CHECKOUT|SHARED)" "$1" | grep -oE '[A-Z]{4,}' | sort -u
}

check_words() { # <doc> <fleet-sessions>
  diff <(rows "$1" | cut -d$'\037' -f1 | sort -u) <(emitted "$2") || { echo "table (<) and fleet-sessions (>) differ"; return 1; }
}

check_cells() { # <doc>
  local b actor action pinned bad=0
  [ "$(rows "$1" | wc -l)" -gt 0 ] || { echo "no bucket table in $1"; return 1; }
  while IFS=$'\037' read -r b actor action pinned; do
    for c in actor action pinned; do [ -n "${!c}" ] || { echo "$b: no $c"; bad=1; }; done
    [[ "$pinned" == *'`'* ]] || { echo "$b: pinned names no test"; bad=1; }
  done < <(rows "$1")
  return "$bad"
}

# pins_missing: reads "<row> US <test name>" lines and prints one for each name no `@test` has;
# a bare snake_case name may instead be a Rust test, `fn <name>()` under .local/src
pins_missing() {
  local b name bad=0
  while IFS=$'\037' read -r b name; do
    grep -rqF --include='*.bats' "@test \"$name\"" "$REPO_ROOT/tests/" && continue
    [[ "$name" =~ ^[a-z0-9_]+$ ]] && grep -rqE --include='*.rs' "^\s*fn $name\(\)" "$REPO_ROOT/.local/src/" && continue
    echo "$b: no @test \"$name\""; bad=1
  done
  return "$bad"
}

# pin_lines <col> -> "<first cell> US <code span>" for each code span in cell <col> of \037 rows
pin_lines() { awk -F'\037' -v c="$1" '{ n = split($c, p, "`"); for (i = 2; i <= n; i += 2) print $1 "\037" p[i] }'; }

check_pinned() { rows "$1" | pin_lines 4 | pins_missing; } # <doc>

check_shepherd() { # <doc> <fleet-shepherd>
  local b bad=0 body
  body="$(awk '/^[a-z_]*due\(\) \{/,/^}/' "$2")"
  while IFS= read -r b; do
    grep -qF "\"$b\"" <<<"$body" || { echo "$b: its actor is the shepherd, but no due function reads it"; bad=1; }
  done < <(rows "$1" | awk -F'\037' 'tolower($2) ~ /shepherd/ {print $1}')
  return "$bad"
}

# close_rows <doc> -> "<step> <verdict>" for each row of the close table, in order: the Step cell
# without its backticks and the first word of the Verdict cell
close_rows() {
  awk -F'|' '/^\| Step \| Group \| Facts \| Verdict \|/ {t = 1; next}
    t && /^\|---/ {next}
    t && !/^\|/ {exit}
    t { gsub(/[` ]/, "", $2); v = $5; sub(/^ +/, "", v); match(v, /^[a-z]+/); print $2, substr(v, 1, RLENGTH) }' "$1"
}

# close_tags <fleet-sessions> -> "<step> <verdict>" for each branch of close_verdict in CLOSE_JQ, in
# order: its `# step:<id>` tag and the first `verdict: "..."` from that line on, up to the `end;`
# that closes the chain
close_tags() {
  awk '/def close_verdict\(/ {on = 1}
    !on {next}
    match($0, /# step:[a-z0-9-]+/) { if (id != "") print id, v; id = substr($0, RSTART + 7, RLENGTH - 7); v = "" }
    id != "" && v == "" && match($0, /verdict: "[a-z]+"/) { v = substr($0, RSTART + 10, RLENGTH - 11) }
    / end;/ { if (id != "") print id, v; exit }' "$1"
}

check_steps() { # <doc> <fleet-sessions>
  [ "$(close_rows "$1" | wc -l)" -gt 0 ] || { echo "no close table in $1"; return 1; }
  diff <(close_rows "$1") <(close_tags "$2") || { echo "close table (<) and CLOSE_JQ step tags (>) differ"; return 1; }
}

check_svg() { # <doc> <svg>
  diff <("$GEN" --doc "$1" --out -) "$2" > /dev/null || { echo "$2 is not close-flow-svg's output of $1: run close-flow-svg"; return 1; }
}

# owner_rows <doc> -> fact, writer, home, copy, lock and pinned, one row of the Owners table per line,
# split by \037. `\|` in a cell is the regex's alternation, not a cell border.
owner_rows() {
  awk '/^\| Fact \| Writer \| Home \| Forbidden copy \|/ {t = 1; next}
    t && /^\| ---/ {next}
    t && !/^\|/ {exit}
    t { gsub(/\\\|/, "\036"); n = split($0, c, "|"); out = ""
        for (i = 2; i < n; i++) { gsub(/^ +| +$/, "", c[i]); gsub(/\036/, "|", c[i]); out = out (i > 2 ? "\037" : "") c[i] }
        print out }' "$1"
}

# spans <cell> -> its code spans, one per line
spans() { awk -F'`' '{ for (i = 2; i <= NF; i += 2) print $i }' <<<"$1"; }

# fn_body <file> <function> -> the function's lines, from `name() {` (in a .rs file, an unindented
# `fn name(`, `pub` or not) to the first unindented `}`
fn_body() {
  local rs=0; [[ "$1" != *.rs ]] || rs=1
  awk -v f="$2" -v rs="$rs" '
    !on && (rs ? $0 ~ ("^(pub(\\([a-z]+\\))? )?fn " f "[(<]") : index($0, f "() {") == 1) {on = 1}
    on {print} on && /^}/ {exit}' "$1"
}

# takes_flock <file> <function> -> exit 0 when the function's code, comments aside, takes a flock:
# `flock` in shell, std's `File::lock` or `try_lock` (flock(2) on Unix) in Rust
takes_flock() {
  local re='\bflock\b'; [[ "$1" != *.rs ]] || re='\bflock\b|\.(try_)?lock\(\)'
  fn_body "$1" "$2" | grep -vE '^\s*(#|//)' | grep -qE "$re"
}

# owned_files -> every tracked file the forbidden copies are checked in: this repo's fleet code and,
# where it is checked out, the private repo's bin
owned_files() {
  git -C "$REPO_ROOT" ls-files -- "$REPO_ROOT/.local/bin/" "$REPO_ROOT/.local/lib/" "$REPO_ROOT/.local/src/" "$REPO_ROOT/.config/shared-hooks/" "$REPO_ROOT/.claude/hooks/" |
    grep -vE '\.(md|svg|bats)$' | sed "s|^|$REPO_ROOT/|"
  [ ! -d "$PRIVATE/.git" ] || git -C "$PRIVATE" ls-files -- .local/bin | grep -vE '\.(md|svg|bats)$' | sed "s|^|$PRIVATE/|"
}

check_owner_cells() { # <doc>
  local fact writer home copy lock pinned c file fn f lk body bad=0 fns
  [ "$(owner_rows "$1" | wc -l)" -gt 0 ] || { echo "no Owners table in $1"; return 1; }
  while IFS=$'\037' read -r fact writer home copy lock pinned; do
    for c in writer home copy lock pinned; do [ -n "${!c}" ] || { echo "$fact: no $c"; bad=1; }; done
    mapfile -t fns < <(spans "$writer")
    file=${fns[0]%%:*}; fns[0]=${fns[0]#*:}
    [ -f "$REPO_ROOT/$file" ] || { echo "$fact: no writer $file"; bad=1; continue; }
    lk=-; [ "$lock" = - ] || lk=$(spans "$lock")
    [ "$lk" = - ] || takes_flock "$REPO_ROOT/$file" "$lk" || { echo "$fact: its lock $lk takes no flock"; bad=1; }
    # A writer span after the first is a function in the same file, or `<file>:<fn>` in another.
    for fn in "${fns[@]}"; do
      f=$file; [[ $fn != *:* ]] || { f=${fn%%:*}; fn=${fn#*:}; }
      body=$(fn_body "$REPO_ROOT/$f" "$fn")
      [ -n "$body" ] || { echo "$fact: $f has no function $fn"; bad=1; continue; }
      [ "$lk" = - ] || [ "$lk" = "$fn" ] || grep -vE '^\s*(#|//)' <<<"$body" | grep -qw "$lk" ||
        { echo "$fact: $fn does not take its lock $lk"; bad=1; }
    done
  done < <(owner_rows "$1")
  return "$bad"
}

check_owner_copies() { # <doc> <file>...
  local doc=$1 fact writer home copy lock pinned file re hits bad=0; shift
  while IFS=$'\037' read -r fact writer home copy lock pinned; do
    file=$(spans "$writer" | head -1); file="$REPO_ROOT/${file%%:*}"; re=$(spans "$copy" | head -1)
    grep -qE -e "$re" </dev/null; [ $? -ne 2 ] || { echo "$fact: its forbidden copy is not a valid regex: $re"; bad=1; continue; }
    hits=$(printf '%s\0' "$@" | xargs -0 grep -nIE -e "$re" -- 2>/dev/null | awk -v w="$file:" 'index($0, w) != 1')
    [ -z "$hits" ] || { printf '%s: a copy outside its writer:\n%s\n' "$fact" "$hits"; bad=1; }
  done < <(owner_rows "$doc")
  return "$bad"
}

check_owner_pins() { owner_rows "$1" | pin_lines 6 | pins_missing; } # <doc>

@test "the bucket table names exactly the buckets fleet-sessions emits" {
  run check_words "$DOC" "$SESSIONS"
  assert_success
  assert_equal "$(rows "$DOC" | cut -d$'\037' -f1 | paste -sd' ')" "PARKED NEEDS STALLED WORKING LANDED DONE CHAT NIGHTLY SHARED CHECKOUT"
}

@test "every bucket row has an actor, an action and a pinning test that exists" {
  run check_cells "$DOC"
  assert_success
  run check_pinned "$DOC"
  assert_success
}

@test "every bucket the shepherd acts on is read by one of its due functions" {
  run check_shepherd "$DOC" "$SHEPHERD"
  assert_success
}

@test "negative controls: a stray bucket word, a missing row, an empty cell, a dead test name and an unread bucket all fail" {
  local t="$BATS_TEST_TMPDIR"
  { cat "$SESSIONS"; echo '  echo "UNCLEAR stray"'; } > "$t/sessions"
  run check_words "$DOC" "$t/sessions"
  assert_failure
  assert_output --partial '> UNCLEAR'
  grep -v '^| CHAT |' "$DOC" > "$t/no-chat.md"
  run check_words "$t/no-chat.md" "$SESSIONS"
  assert_failure
  assert_output --partial '> CHAT'
  sed '/^| LANDED |/ s/| The quiet timer, then fleet-dispatch reap |/| |/' "$DOC" > "$t/no-actor.md"
  run check_cells "$t/no-actor.md"
  assert_failure
  assert_output 'LANDED: no actor'
  sed -E '/^\| CHAT \|/ s/gets no pass line/gets a pass line/' "$DOC" > "$t/dead.md"
  run check_pinned "$t/dead.md"
  assert_failure
  assert_output --partial 'CHAT: no @test "a CHAT row gets a pass line'
  sed -E 's/"CHAT"/"CHATTY"/g' "$SHEPHERD" > "$t/shepherd"
  run check_shepherd "$DOC" "$t/shepherd"
  assert_failure
  assert_output 'CHAT: its actor is the shepherd, but no due function reads it'
}

@test "the close table's step ids and verdicts, in order, are the tagged branches of close_verdict" {
  run check_steps "$DOC" "$SESSIONS"
  assert_success
}

@test "the committed close flow SVG is close-flow-svg's output of the close table" {
  run check_svg "$DOC" "$SVG"
  assert_success
}

@test "negative controls: an untagged branch, a renamed step, a moved verdict, a hand-edited SVG and a table edit with no regenerate all fail" {
  local t="$BATS_TEST_TMPDIR"
  sed 's/ # step:held$//' "$SESSIONS" > "$t/untagged"
  run check_steps "$DOC" "$t/untagged"
  assert_failure
  assert_output --partial 'close table (<) and CLOSE_JQ step tags (>) differ'
  sed 's/^| `held` |/| `kept` |/' "$DOC" > "$t/renamed.md"
  run check_steps "$t/renamed.md" "$SESSIONS"
  assert_failure
  assert_output --partial '< kept keep'
  sed '/^| `dialog` |/ s/| keep |$/| now |/' "$DOC" > "$t/moved.md"
  run check_steps "$t/moved.md" "$SESSIONS"
  assert_failure
  assert_output --partial '< dialog now'
  sed 's/KEEP: land it/KEEP: ship it/' "$SVG" > "$t/hand.svg"
  run check_svg "$DOC" "$t/hand.svg"
  assert_failure
  sed '/^| `unlanded` |/ s/a blocker names unlanded work/a blocker names work not landed/' "$DOC" > "$t/edited.md"
  run check_svg "$t/edited.md" "$SVG"
  assert_failure
  : > "$t/empty.md"
  run "$GEN" --doc "$t/empty.md" --out -
  assert_failure 2
  assert_output --partial 'no close table'
}

@test "every Owners row names a writer that exists, a lock it takes, and pinning tests that exist" {
  run check_owner_cells "$DOC"
  assert_success
  run check_owner_pins "$DOC"
  assert_success
}

@test "no Owners row's forbidden copy appears outside its writer" {
  mapfile -t files < <(owned_files)
  run check_owner_copies "$DOC" "${files[@]}"
  assert_success
}

@test "negative controls: a planted copy, a missing writer, a lock a writer skips, a bad pattern and a dead pin all fail" {
  local t="$BATS_TEST_TMPDIR"
  mapfile -t files < <(owned_files)
  printf ': "${WAKE_BATCH:=3}"\n' > "$t/wake-pace.sh"
  printf 'c="$HOME/.config/claude-acct/pace.conf"\n' > "$t/reader"
  printf 'if grep -q %s "$plan"; then :; fi\n' "'^- \\[-\\]'" > "$t/agent-land"
  run check_owner_copies "$DOC" "${files[@]}" "$t/wake-pace.sh" "$t/reader" "$t/agent-land"
  assert_failure
  assert_output --partial "The pace numbers"
  assert_output --partial "$t/wake-pace.sh:"
  assert_output --partial "$t/reader:1:"
  assert_output --partial "A plan's phases"
  assert_output --partial "$t/agent-land:1:"
  sed '/^| Who parked/ s/`.local\/bin\/claude-acct:park_flow`/`.local\/bin\/claude-acct:park_flown`/' "$DOC" > "$t/no-writer.md"
  run check_owner_cells "$t/no-writer.md"
  assert_failure
  assert_output --partial '.local/bin/claude-acct has no function park_flown'
  sed '/^| Who parked/ s/| `park_lock` |/| `park_unlock` |/' "$DOC" > "$t/no-lock.md"
  run check_owner_cells "$t/no-lock.md"
  assert_failure
  assert_output --partial 'its lock park_unlock takes no flock'
  sed '/^| Who parked/ s/(also `cmd_unpark`)/(also `record`)/' "$DOC" > "$t/skips.md"
  run check_owner_cells "$t/skips.md"
  assert_failure
  assert_output --partial 'record does not take its lock park_lock'
  sed '/^| One shepherd pass/ s/`FLEET_SHEPHERD_RUN_LOCKED=`/`FLEET_SHEPHERD_RUN_LOCKED=(`/' "$DOC" > "$t/bad-re.md"
  run check_owner_copies "$t/bad-re.md" "${files[@]}"
  assert_failure
  assert_output --partial 'is not a valid regex: FLEET_SHEPHERD_RUN_LOCKED=('
  sed '/^| One shepherd pass/ s/exits 75 having sampled nothing/exits 75/' "$DOC" > "$t/dead.md"
  run check_owner_pins "$t/dead.md"
  assert_failure
  assert_output --partial 'past FLEET_SHEPHERD_CHECK_WAIT exits 75"'
}

@test "negative controls for a Rust writer: a planted raw typer, a missing fn, a fn that skips the lock, a lock with no flock and a dead Rust pin all fail" {
  local t="$BATS_TEST_TMPDIR" row='/^| Keystrokes into a Claude pane/'
  mapfile -t files < <(owned_files)
  # main's close_sample line (fleet-shepherd before P9)
  printf '%s\n' '    if tmux -L "$server" send-keys -t "$pane" -l "$cmd" && tmux -L "$server" send-keys -t "$pane" Enter; then' > "$t/typer"
  run check_owner_copies "$DOC" "${files[@]}" "$t/typer"
  assert_failure
  assert_output --partial 'Keystrokes into a Claude pane'
  assert_output --partial "$t/typer:1:"
  sed "$row s/send.rs:message\`/send.rs:messages\`/" "$DOC" > "$t/no-fn.md"
  run check_owner_cells "$t/no-fn.md"
  assert_failure
  assert_output --partial '.local/src/agent-core/src/send.rs has no function messages'
  sed "$row s/send.rs:message\` (/send.rs:message\` (also \`deliver\`; /" "$DOC" > "$t/rs-skips.md"
  run check_owner_cells "$t/rs-skips.md"
  assert_failure
  assert_output --partial 'deliver does not take its lock lock_pane'
  sed "$row s/dialog.rs:answer_in/dialog.rs:answer/" "$DOC" > "$t/rs-other-file.md"
  run check_owner_cells "$t/rs-other-file.md"
  assert_failure
  assert_output --partial 'answer does not take its lock lock_pane'
  sed "$row s/| \`lock_pane\` |/| \`pane_key\` |/" "$DOC" > "$t/rs-no-lock.md"
  run check_owner_cells "$t/rs-no-lock.md"
  assert_failure
  assert_output --partial 'its lock pane_key takes no flock'
  sed "$row s/then_goes\`/then_goes_now\`/" "$DOC" > "$t/rs-dead.md"
  run check_owner_pins "$t/rs-dead.md"
  assert_failure
  # Only the tail: the whole name in quotes here would be the @test the check finds.
  assert_output --partial 'finish_then_goes_now"'
}
