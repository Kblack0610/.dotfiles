#!/usr/bin/env bats
# The bucket table in .local/src/docs/fleet-states.md is the one definition of every fleet-sessions
# bucket. This guard reads it as text and fails when (a) the bucket words fleet-sessions emits differ
# from the table's, (b) a row lacks an actor, action or pinning test, (c) a pinning test name has no
# `@test`, or (d) a row whose actor is the shepherd is missing from fleet-shepherd's due functions.
# The close table there drives the close flow's checks: (e) its Step ids and verdict words, in order,
# must be the `# step:<id>` tagged branches of close_verdict in CLOSE_JQ, and (f) the committed
# fleet-close-flow.svg must be close-flow-svg's output of it.
# The Owners table names one writer per shared fact; `.local/bin/fact-owners check` reads it (g) its
# forbidden copy matches nothing outside the writer file, (h) the writer functions (shell or Rust)
# exist and take the lock the row names, (i) its pins exist (a bats @test, or a Rust test fn), (j) the
# generated rules of .config/fact-owners/rules.json find no vocabulary list, raw two-field read or
# untagged schema field outside a row's home, and (k) every known copy is Debt naming an open row,
# with the count at or under `Debt pinned`. A writer or pin spelled `private:<...>` resolves in
# the private repo ($DOTFILES_PRIVATE), and is skipped where that repo is not checked out (public CI).
# Each check takes its files as arguments, so the negative controls run it on a broken copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/private'
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
# a `private:<name>` pin is a quoted test name in the private repo's tests/*.sh, unchecked without that repo
pins_missing() {
  local b name bad=0
  while IFS=$'\037' read -r b name; do
    if [[ $name == private:* ]]; then
      has_private || continue
      grep -rqF --include='*.sh' "\"${name#private:}\"" "$PRIVATE/tests/" && continue
      echo "$b: no private test \"${name#private:}\""; bad=1; continue
    fi
    grep -rqF --include='*.bats' "@test \"$name\"" "$REPO_ROOT/tests/" && continue
    [[ "$name" =~ ^[a-z0-9_]+$ ]] && grep -rqE --include='*.rs' "^\s*fn $name\(\)" "$REPO_ROOT/.local/src/" && continue
    echo "$b: no @test \"$name\""; bad=1
  done
  return "$bad"
}

# pin_lines <col> -> "<first cell> US <code span>" for each code span in cell <col> of \037 rows
pin_lines() { awk -F'\037' -v c="$1" '{ n = split($c, p, "`"); for (i = 2; i <= n; i += 2) print $1 "\037" p[i] }'; }

check_pinned() { rows "$1" | pin_lines 4 | pins_missing; } # <doc>

# A due function reads a bucket by its quoted name, or, for a finished one (fleet-sessions'
# BUCKET_FINISHED, the state document's vocab.finished), through FIN_JQ's `finished`.
check_shepherd() { # <doc> <fleet-shepherd> <fleet-sessions>
  local b bad=0 body fin
  body="$(awk '/^[a-z_]*due\(\) \{/,/^}/' "$2")"
  fin=" $(sed -n 's/^BUCKET_FINISHED="\(.*\)"$/\1/p' "$3") "
  while IFS= read -r b; do
    grep -qF "\"$b\"" <<<"$body" && continue
    [[ "$fin" == *" $b "* ]] && grep -qw finished <<<"$body" && continue
    echo "$b: its actor is the shepherd, but no due function reads it"; bad=1
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

# The Owners table is checked by .local/bin/fact-owners, the one checker (this file is its CI run). These wrappers hand it this test's PRIVATE (a stand-in repo in the negative controls) and
# keep each check's output for the assertions below.
FACT_OWNERS() { DOTFILES_PRIVATE="$PRIVATE" "$REPO_ROOT/.local/bin/fact-owners" "$@"; }

# owned_files -> every tracked file the forbidden copies are checked in, from fact-owners
owned_files() { FACT_OWNERS files; }

check_owner_cells() { out=$(FACT_OWNERS check --doc "$1" --cells) || { echo "$out"; return 1; }; } # <doc>
check_owner_pins() { out=$(FACT_OWNERS check --doc "$1" --pins) || { echo "$out"; return 1; }; } # <doc>
check_owner_copies() { # <doc> <file>...
  local doc=$1 out; shift
  out=$(FACT_OWNERS check --doc "$doc" --copies "$@") || { echo "$out"; return 1; }
}

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
  run check_shepherd "$DOC" "$SHEPHERD" "$SESSIONS"
  assert_success
}

@test "negative controls: a stray bucket word, a missing row, an empty cell, a dead test name, an unread bucket and an unread finished set all fail" {
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
  run check_shepherd "$DOC" "$t/shepherd" "$SESSIONS"
  assert_failure
  assert_output 'CHAT: its actor is the shepherd, but no due function reads it'
  sed -E 's/\(finished or /(false or /' "$SHEPHERD" > "$t/no-finished"
  run check_shepherd "$DOC" "$t/no-finished" "$SESSIONS"
  assert_failure
  assert_output --partial 'DONE: its actor is the shepherd, but no due function reads it'
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
  has_private || echo "# private: rows unchecked, no checkout at $PRIVATE" >&3
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
  printf ': "${WAKE_BUDGET:=3}"\n' > "$t/wake-pace.sh"
  printf 'c="$HOME/.config/claude-acct/pace.conf"\n' > "$t/reader"
  printf 'if grep -q %s "$plan"; then :; fi\n' "'^- \\[-\\]'" > "$t/agent-land"
  # the copies P5 deleted: hub capacity's own origin test and Home's own ETA clock
  printf '%s\n' '.filter(|s| s["item"]["origin"].as_str() == Some("run"))' > "$t/capacity.rs"
  printf '%s\n' '    (Some(e), Some(n)) if e < n' > "$t/home.rs"
  # the copy P14 deleted: session-outcomes's own CI-poll regex beside time-use.conf
  printf '%s\n' '  def ci_poll: "\\bgh\\s+(run\\s+(view|watch|list)|pr\\s+checks)\\b";' > "$t/outcomes.sh"
  # the copies the finished-vocab fix deleted: hub-core's own finished set, in both spellings
  printf '%s\n' '    let done = rows.iter().filter(|r| r.bucket == "DONE").count();' > "$t/cards.rs"
  printf '%s\n' '    !matches!(self.bucket.as_str(), "NEEDS" | "STALLED" | "DONE" | "PARKED")' > "$t/table.rs"
  # the copy the parked-ask fix deleted: fleet-sessions' own pending test, which counted a parked ask
  printf '%s\n' '$0 == "status: pending" { p = 1 }' > "$t/asks"
  # the admission, typed-prompt and project-name rows: a second admission test, a prefix test of its own, agent-panel's old strip
  printf 'pull_ok() { true; }\n[ -n "${AGENT_QUEUE_PULL:-}" ]\n' > "$t/filer"
  printf '%s\n' '    if s.startswith(("Answer to ask", "x")):' > "$t/recall"
  printf '%s\n' 'fn strip_agent_suffix(s: &str) -> &str { s }' > "$t/render.rs"
  # the default-branch row: fleet-assess's own symref read and agent-codex's origin/HEAD with a guessed fallback, deleted for merge_proof_ref
  printf '%s\n' '  base="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"' \
    '  trunk=$(git rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null && echo origin/HEAD || echo origin/main)' > "$t/branch"
  # the copies #2845 deleted: phone.rs's own waiting (three kinds counted apart from Home::waiting) and its
  # own kind split; line 2 is the need-split shape, a second Home::split
  printf '%s\n' '        .filter(|n| matches!(n.kind, Kind::Ask | Kind::Session | Kind::Queue))' \
    '        self.needs.iter().filter(|need| need.need == *k).count(),' \
    '    let of = |k: Kind| waiting.iter().filter(|n| n.kind == k).count();' > "$t/phone.rs"
  # the stale-age copies the one conf replaced: the minutes env default, and a literal beside hub-core's const
  printf '%s\n' '  [ "$age" -le "${FLEET_STATE_STALE_MIN:-5}" ]' 'pub const FLEET_STATE_STALE_SECS: i64 = 300;' > "$t/stale"
  run check_owner_copies "$DOC" "${files[@]}" "$t/wake-pace.sh" "$t/reader" "$t/agent-land" "$t/capacity.rs" "$t/home.rs" "$t/filer" "$t/recall" "$t/render.rs" "$t/asks" "$t/cards.rs" "$t/table.rs" "$t/outcomes.sh" "$t/branch" "$t/stale" "$t/phone.rs"
  assert_failure
  assert_output --partial "The pace numbers"
  assert_output --partial "$t/wake-pace.sh:"
  assert_output --partial "$t/reader:1:"
  assert_output --partial "A plan's phases"
  assert_output --partial "$t/agent-land:1:"
  assert_output --partial "Who started a session or item"
  assert_output --partial "$t/capacity.rs:1:"
  assert_output --partial "Whether a session's open plan phase is overdue"
  assert_output --partial "$t/home.rs:1:"
  assert_output --partial "Which command is a test run or a CI poll"
  assert_output --partial "$t/outcomes.sh:1:"
  assert_output --partial "Whether an ask is pending"
  assert_output --partial "$t/asks:1:"
  assert_output --partial "$t/filer:1:"
  assert_output --partial "$t/filer:2:"
  assert_output --partial "$t/recall:1:"
  assert_output --partial "The Needs you count"
  assert_output --partial "$t/phone.rs:1:"
  assert_output --partial "$t/phone.rs:2:"
  assert_output --partial "$t/phone.rs:3:"
  assert_output --partial "$t/render.rs:1:"
  assert_output --partial "A repo's default branch"
  assert_output --partial "$t/branch:1:"
  assert_output --partial "$t/branch:2:"
  assert_output --partial "Which buckets are finished"
  assert_output --partial "$t/cards.rs:1:"
  assert_output --partial "$t/table.rs:1:"
  assert_output --partial "How old the state document may be"
  assert_output --partial "$t/stale:1:"
  assert_output --partial "$t/stale:2:"
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

@test "negative controls for a private writer: a planted key reader, a missing fn, a fn that skips the lock, a lock with no flock and a dead private pin all fail; with no private checkout the row is skipped" {
  local t="$BATS_TEST_TMPDIR" row='/^| One page per fact/' w
  # A stand-in private repo, so this runs where the real one is not checked out.
  PRIVATE="$t/priv"; w="$PRIVATE/.local/bin/agent-notify"
  git init -q "$PRIVATE"; mkdir -p "$PRIVATE/.local/bin" "$PRIVATE/tests"
  printf '%s\n' 'KEYS="$LEDGER.keys"' 'ledger_lock() {' '  flock -w 5 9' '}' 'record_page() {' '  ledger_lock' '}' > "$w"
  printf 'same "%s"\n' 'a repeat inside the window buzzes once' 'two pages with one key raised at once buzz once' 'a lock it cannot take says so' 'a page no channel took and nothing spooled gives its key back: the retry is news' > "$PRIVATE/tests/agent-notify.sh"
  run check_owner_cells "$DOC"
  assert_success
  run check_owner_pins "$DOC"
  assert_success
  printf 'k="$HOME/.local/state/agent-notify/log.keys"\n' > "$t/reader"
  run check_owner_copies "$DOC" "$w" "$t/reader"
  assert_failure
  assert_output --partial 'One page per fact'
  assert_output --partial "$t/reader:1:"
  refute_output --partial "$w:"
  sed "$row s/agent-notify:record_page\`/agent-notify:record_pages\`/" "$DOC" > "$t/no-fn.md"
  run check_owner_cells "$t/no-fn.md"
  assert_failure
  assert_output --partial '.local/bin/agent-notify has no function record_pages'
  printf '%s\n' 'ledger_lock() {' '  flock -w 5 9' '}' 'record_page() {' '  dedupe_page' '}' > "$w"
  run check_owner_cells "$DOC"
  assert_failure
  assert_output --partial 'record_page does not take its lock ledger_lock'
  printf '%s\n' 'ledger_lock() {' '  :' '}' 'record_page() {' '  ledger_lock' '}' > "$w"
  run check_owner_cells "$DOC"
  assert_failure
  assert_output --partial 'its lock ledger_lock takes no flock'
  sed "$row s/private:a lock it cannot take says so/private:a lock it cannot take says so twice/" "$DOC" > "$t/dead.md"
  run check_owner_pins "$t/dead.md"
  assert_failure
  assert_output --partial 'no private test "a lock it cannot take says so twice"'
  PRIVATE="$t/absent"
  run check_owner_cells "$t/no-fn.md"
  assert_success
  run check_owner_pins "$t/dead.md"
  assert_success
}

@test "the forbidden copies are looked for in skill scripts under .claude/ too, not only its hooks" {
  run owned_files
  assert_success
  assert_output --partial "/.claude/skills/memory/project-index/regen-anchor.sh"
  assert_output --partial "/.claude/hooks/stop-post.d/85-sync-plans.sh"
}

@test "fact-owners check passes on the real tree: every copy is owned or debt, the pin holds, the generated rules and schema tags hold" {
  run env DOTFILES_PRIVATE="$PRIVATE" "$REPO_ROOT/.local/bin/fact-owners" check
  assert_success
}

@test "negative controls for the generated rules: a fresh vocabulary list, a jq read of status and pr, a Python read and an owned writer's own read are each found or left alone" {
  local t="$BATS_TEST_TMPDIR/tree" copies
  mkdir -p "$t/hub-core/src"
  # a bucket list spelled in a new Rust reader, the kind of copy that left LANDED out
  printf '%s\n' '    let done = ["NEEDS", "STALLED", "DONE", "LANDED"];' > "$t/hub-core/src/cards.rs"
  # the landed test in jq, and in Python, each in a file no row lists
  printf '%s\n' "jq -r 'select(.status == \"ok\" and .pr != null) | .slug'" > "$t/fresh-shipped"
  printf '%s\n' 'if item["status"] == "ok" and item.get("pr"):' > "$t/fresh-shipped.py"
  # two bucket words are not a list of the vocabulary
  printf '%s\n' 'let a = ["DONE", "STALLED"];' > "$t/hub-core/src/ok.rs"
  # a comment does not count
  printf '%s\n' '// ["NEEDS", "STALLED", "DONE"]' > "$t/hub-core/src/note.rs"
  run env DOTFILES_PRIVATE="$PRIVATE" "$REPO_ROOT/.local/bin/fact-owners" check --generated "$t/hub-core/src/cards.rs" "$t/fresh-shipped" "$t/fresh-shipped.py" "$t/hub-core/src/ok.rs" "$t/hub-core/src/note.rs"
  assert_failure
  assert_output --partial "buckets: a copy outside its home"
  assert_output --partial "$t/hub-core/src/cards.rs:1: a list of 4 session-bucket words"
  assert_output --partial "landed: a copy outside its home"
  assert_output --partial "$t/fresh-shipped:1: reads status and pr|merged together"
  assert_output --partial "$t/fresh-shipped.py:1: reads status and pr|merged together"
  refute_output --partial "ok.rs"
  refute_output --partial "note.rs"
}

@test "negative controls for debt: a copy not listed, a stale entry, a missing file, a count above the pin and one below it all fail" {
  local t="$BATS_TEST_TMPDIR" n
  n=$(DOTFILES_PRIVATE="$PRIVATE" "$REPO_ROOT/.local/bin/fact-owners" count --debt)
  # a debt entry dropped without lowering the pin
  sed '/^| `kinds`/ s/`.local\/bin\/fleet-bench` (ar-5455); //' "$DOC" > "$t/dropped.md"
  run FACT_OWNERS check --doc "$t/dropped.md" --debt
  assert_failure
  assert_output --partial "are below Debt pinned"
  # an entry whose file holds no copy any more, one whose file is gone, and a pin under the count
  sed -e '/^| `room-verdict`/ s/| - |$/| `.local\/bin\/fact-owners` (ar-5455) |/' \
    -e '/^| One shepherd pass/ s/| - |$/| `.local\/bin\/no-such-file` (ar-5455) |/' \
    -e "s/^Debt pinned: .*/Debt pinned: $((n - 1))/" "$DOC" > "$t/bad.md"
  run FACT_OWNERS check --doc "$t/bad.md" --debt
  assert_failure
  assert_output --partial "debt .local/bin/fact-owners (ar-5455) is no longer a copy"
  assert_output --partial "debt .local/bin/no-such-file does not exist"
  assert_output --partial "are above Debt pinned $((n - 1))"
  # a copy of the account list in a file no Debt cell lists
  mkdir -p "$t/hub-core/src"
  printf '%s\n' 'let names = ["main", "alt", "bnb"];' > "$t/hub-core/src/fresh.rs"
  run FACT_OWNERS check --doc "$DOC" --generated "$t/hub-core/src/fresh.rs"
  assert_failure
  assert_output --partial "accounts: a copy outside its home"
  assert_output --partial "$t/hub-core/src/fresh.rs:1: a list of 3 account words"
}

@test "negative controls for schema tags and config keys: a tag with no row, a schema doc with no tag, a key the conf lacks, a reader that never reads it and a vocabulary rule that reads no words all fail" {
  local t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/repo/.config/fact-owners" "$t/repo/.local/bin" "$t/repo/docs"
  cp "$REPO_ROOT/.config/fact-owners/rules.json" "$t/repo/.config/fact-owners/"
  # a copy of the repo's rules pointed at a scratch tree: a tag naming no row, then an untagged doc
  printf '%s\n' '| field | <!-- derived: no-such-row --> |' > "$t/repo/docs/schema.md"
  python3 - "$t/repo/.config/fact-owners/rules.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["vocab"], d["raw"] = [{"row": "buckets", "name": "empty", "source": {"words": []}, "home": []}], []
d["schema_docs"] = ["docs/schema.md"]
d["config_keys"] = [{"conf": "conf.json", "key": "absent", "reader": ".local/bin/reader:load"},
                    {"conf": "conf.json", "key": "rung", "reader": ".local/bin/reader:load"}]
json.dump(d, open(p, "w"))
PY
  cp "$REPO_ROOT/.local/bin/fact-owners" "$t/repo/.local/bin/fact-owners"
  printf '%s\n' '{"build": {"rung": "x"}}' > "$t/repo/conf.json"
  printf '%s\n' 'load() {' '  :' '}' > "$t/repo/.local/bin/reader"
  run env DOTFILES_PRIVATE="$PRIVATE" "$t/repo/.local/bin/fact-owners" check --doc "$DOC" --generated "$t/repo/.local/bin/reader"
  assert_failure
  assert_output --partial "tagged derived: no-such-row with no Owners row"
  assert_output --partial "rule empty: its source {\"words\": []} yields no words"
  assert_output --partial "config key absent: not in conf.json"
  assert_output --partial "its reader .local/bin/reader:load never reads it"
  printf '%s\n' 'no tag here' > "$t/repo/docs/schema.md"
  run env DOTFILES_PRIVATE="$PRIVATE" "$t/repo/.local/bin/fact-owners" check --doc "$DOC" --generated "$t/repo/.local/bin/reader"
  assert_output --partial "a schema doc with no \`<!-- derived: <row> -->\` tag"
}

@test "negative controls for the row-id, item-active, size-tag and priority rows: a fresh copy of each is found" {
  local t="$BATS_TEST_TMPDIR"
  printf '%s\n' "  id=\"\$(grep -o 'id:[a-z0-9]*-[0-9]*' <<<\"\$out\")\"" > "$t/marker"
  printf '%s\n' "  jq 'select(.state == \"running\" or .state == \"review\" or .state == \"waiting\")'" > "$t/active"
  printf '%s\n' '  [[ "$text" == *"#size/"* ]] || text+=" #size/s"' > "$t/size"
  printf '%s\n' '  case "$p" in urgent) echo 0 ;; high) echo 1 ;; low) echo 3 ;; esac' > "$t/prio"
  run check_owner_copies "$DOC" "$t/marker" "$t/active" "$t/size" "$t/prio"
  assert_failure
  for f in marker active size prio; do assert_output --partial "$t/$f:1:"; done
}

@test "number-formatters: a formatter written again and a hand-built plural either way round are found, a test helper is not" {
  local t="$BATS_TEST_TMPDIR"
  printf '%s\n' 'pub fn usd_opt(c: Option<f64>) -> String { String::new() }' > "$t/a.rs"
  printf '%s\n' 'let s = if n == 1 { "" } else { "s" };' > "$t/b.rs"
  printf '%s\n' 'let s = if n != 1 { "s" } else { "" };' > "$t/c.rs"
  printf '%s\n' 'fn live() {}' '#[cfg(test)]' 'mod tests {' '    fn age(secs: f64) -> u8 { 0 }' '}' > "$t/d.rs"
  run check_owner_copies "$DOC" "$t/a.rs" "$t/b.rs" "$t/c.rs" "$t/d.rs"
  assert_failure
  assert_output --partial "$t/a.rs:1:"
  assert_output --partial "$t/b.rs:1:"
  assert_output --partial "$t/c.rs:1:"
  refute_output --partial "$t/d.rs"
}
