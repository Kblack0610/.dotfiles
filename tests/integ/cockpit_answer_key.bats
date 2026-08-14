#!/usr/bin/env bats
# One key that answers whatever is waiting on you.
#
# Answering already worked - enter on a `[!] needs you` row - but you had to FIND the row
# first, which means knowing which project the question is against and standing in the right
# section. Twice in one day the same person went looking for it and landed on `g`
# (accept "next up" suggestions), because that screen shows a list of statements and asks
# you to accept them, which is exactly what someone hunting for an approval gate expects.
#
# So: a banner that says a question exists wherever you are, a `!` key that opens it, and a
# `g` screen that says what it actually does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  cat > "$SANDBOX/bin/agent-notify" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/agent-notify"
}

gate() { # $1=project
  "$AGENT_ASK" post --project "${1:-alpha}" --kind gate --options 'approve|hold|cancel' \
    --recommend approve "gate for ${1:-alpha}?"
}

# ── the banner ───────────────────────────────────────────────────────────────

@test "with nothing pending the tasks view carries no banner" {
  run bash -c 'source "$COCKPIT"; _ask_banner'
  assert_output ''
}

@test "a pending question puts a banner on the tasks view" {
  gate alpha >/dev/null
  run bash -c 'source "$COCKPIT"; _ask_banner | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output --partial '1 question waiting on you'
  assert_output --partial 'press ! to answer'
}

@test "the banner counts every project, not just the section you are on" {
  gate alpha >/dev/null; gate beta >/dev/null; gate gamma >/dev/null
  run bash -c 'source "$COCKPIT"; _ask_banner | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output --partial '3 questions waiting on you'
}

@test "the banner pluralises" {
  gate alpha >/dev/null
  run bash -c 'source "$COCKPIT"; _ask_banner | sed "s/\x1b\[[0-9;]*m//g"'
  refute_output --partial 'questions'
  gate beta >/dev/null
  run bash -c 'source "$COCKPIT"; _ask_banner | sed "s/\x1b\[[0-9;]*m//g"'
  assert_output --partial 'questions'
}

@test "an ANSWERED question leaves no banner behind" {
  local id; id="$(gate alpha)"
  "$AGENT_ASK" answer "$id" approve >/dev/null 2>&1
  run bash -c 'source "$COCKPIT"; _ask_banner'
  assert_output ''
}

@test "the banner is a hint row and keeps the 7-field wire" {
  gate alpha >/dev/null
  run bash -c 'source "$COCKPIT"; _ask_banner | awk -F"\t" "{print \$1, NF}"'
  assert_output 'hint 7'
}

@test "the banner appears in the rendered tasks view, above the projects" {
  gate alpha >/dev/null
  run bash -c '"$COCKPIT" --list personal | sed "s/\x1b\[[0-9;]*m//g" | head -1'
  assert_output --partial 'waiting on you'
}

@test "the banner does NOT appear in the factory view, which is already a question list" {
  gate alpha >/dev/null
  run bash -c 'printf factory > "${TMPDIR:-/tmp}/notes-cockpit-$(id -u).mode"; "$COCKPIT" --list personal | sed "s/\x1b\[[0-9;]*m//g"'
  refute_output --partial 'press ! to answer'
  # Prove the factory view actually rendered, so the refute above is not passing on empty
  # output. Anchored on the view's OWN empty state rather than on the ask: an ask is only
  # rendered against a project that exists in the vault, and this fixture's projects are
  # not `alpha`, so the correct render here IS the empty state.
  assert_output --partial 'nothing in flight'
}

# ── which one it opens ───────────────────────────────────────────────────────

@test "_oldest_pending returns the id and its options" {
  local id; id="$(gate alpha)"
  run bash -c 'source "$COCKPIT"; _oldest_pending | cut -f1,2'
  assert_output "$(printf '%s\tapprove|hold|cancel' "$id")"
}

@test "_oldest_pending is silent when nothing is pending" {
  run bash -c 'source "$COCKPIT"; _oldest_pending'
  assert_output ''
}

@test "_oldest_pending crosses projects" {
  gate zulu >/dev/null
  run bash -c 'source "$COCKPIT"; _oldest_pending | cut -f3'
  assert_output 'zulu'
}

@test "_oldest_pending ignores answered and cancelled asks" {
  local a b
  a="$(gate alpha)"; b="$(gate beta)"
  "$AGENT_ASK" answer "$a" approve >/dev/null 2>&1
  "$AGENT_ASK" cancel "$b" >/dev/null 2>&1
  run bash -c 'source "$COCKPIT"; _oldest_pending'
  assert_output ''
}

@test "answer_next says so rather than opening an empty picker" {
  run bash -c 'source "$COCKPIT"; answer_next'
  assert_success
  assert_output --partial 'nothing is waiting on you'
}

# ── the key is actually wired ────────────────────────────────────────────────

@test "! is bound, and reaches the --answer-next verb" {
  run grep -F -- '--bind "!:execute($SELF --answer-next)' "$COCKPIT"
  assert_success
}

@test "--answer-next is a real dispatch arm" {
  run bash -c 'grep -cE "^  --answer-next\)" "$COCKPIT"'
  assert_output '1'
}

@test "! is modal, so typing it while searching does not fire the picker" {
  run bash -c 'grep -E "^MODAL=" "$COCKPIT"'
  assert_output --partial '!'
}

@test "the always-visible header advertises the answer key" {
  run grep -F -- "--header='! answer" "$COCKPIT"
  assert_success
}

@test "the help screen distinguishes ! from g" {
  run bash -c '"$COCKPIT" --help-view'
  assert_output --partial 'answer the oldest question waiting on you'
  assert_output --partial 'not questions to answer'
}

# ── the screen that kept catching people ─────────────────────────────────────

# `g` shows a list of statements under "accept for <project> >" and asks you to accept
# them. Someone hunting for an approval gate lands there and reasonably believes they found
# it. The list is SUGGESTIONS, and accepting adds them to the sheet.
@test "the g screen says it ADDS to the sheet rather than accepting an answer" {
  run bash -c 'sed -n "/^accept_next/,/^}/p" "$COCKPIT"'
  assert_output --partial "add to \$name's sheet"
  assert_output --partial 'SUGGESTIONS from the overview'
}

@test "the g screen points at the answer key for people who wanted that instead" {
  run bash -c 'sed -n "/^accept_next/,/^}/p" "$COCKPIT"'
  assert_output --partial 'to answer one, esc then press !'
}
