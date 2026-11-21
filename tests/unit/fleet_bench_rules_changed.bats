#!/usr/bin/env bats
# fleet-bench rules --changed: every rule line a merged PR added or removed, read from GitHub.
# A gh stub serves the merged-PR list and each PR's diff (an excerpt of dotfiles #1179, the PR that
# added "never explain ... unless asked"), and two sandbox clones stand in for the config repos.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  export BENCH_LIB_DIR="$REPO_ROOT/.local/lib"
  pub="$SANDBOX/pub" priv="$SANDBOX/priv"
  git init -q "$pub" && git -C "$pub" remote add origin https://github.com/o/.dotfiles.git
  git init -q "$priv" && git -C "$priv" remote add origin git@github.com:o/.dotfiles-private.git
  export BENCH_CANARY_CONFIG_REPOS="$pub:$priv" GH_FIX="$SANDBOX/gh"
  mkdir -p "$GH_FIX"
  # gh pr list -R <slug> ... prints $GH_FIX/<repo>.json; gh pr diff <n> -R <slug> prints $GH_FIX/<n>.diff.
  gh_script <<'EOF'
echo "$*" >> "$GH_FIX/calls"
slug=""; prev=""; for a in "$@"; do [ "$prev" = -R ] && slug="$a"; prev="$a"; done
case "$1 $2" in
  "pr list") cat "$GH_FIX/${slug##*/}.json" ;;
  "pr diff") cat "$GH_FIX/$3.diff" ;;
  *) exit 9 ;;
esac
EOF
  cat > "$GH_FIX/.dotfiles.json" <<'EOF'
[{"number": 1179, "title": "docs(skills): comms-standard covers answers in chat", "mergedAt": "2026-11-06T18:00:00Z",
  "files": [{"path": ".claude/skills/messaging/comms-standard/SKILL.md"}, {"path": ".local/bin/usage-cleanup"}]},
 {"number": 1180, "title": "fix(x): a script only", "mergedAt": "2026-11-06T19:00:00Z",
  "files": [{"path": ".local/bin/x"}]},
 {"number": 1100, "title": "docs(rules): merged before the window", "mergedAt": "2026-11-05T23:00:00Z",
  "files": [{"path": "CLAUDE.md"}]}]
EOF
  cat > "$GH_FIX/.dotfiles-private.json" <<'EOF'
[{"number": 507, "title": "docs(rules): answer system questions from its instruments", "mergedAt": "2026-11-06T17:29:17Z",
  "files": [{"path": ".claude/CLAUDE.md"}, {"path": ".config/opencode/AGENTS.md"}]}]
EOF
  cat > "$GH_FIX/1179.diff" <<'EOF'
diff --git a/.claude/skills/messaging/comms-standard/SKILL.md b/.claude/skills/messaging/comms-standard/SKILL.md
index 1111111..2222222 100644
--- a/.claude/skills/messaging/comms-standard/SKILL.md
+++ b/.claude/skills/messaging/comms-standard/SKILL.md
@@ -1,3 +1,3 @@
-reviewed: "2026-11-01"
+reviewed: "2026-11-05"
@@ -74,2 +74,4 @@
 **UI text** (agent-web, the hub TUI, trader, any page the human reads):
+
+- Use the system's own names (shepherd, dispatch, lane, pace, queue item, pass) without defining them, and never explain how a piece of the system works unless asked.
diff --git a/.local/bin/usage-cleanup b/.local/bin/usage-cleanup
index 3333333..4444444 100755
--- a/.local/bin/usage-cleanup
+++ b/.local/bin/usage-cleanup
@@ -1,1 +1,1 @@
-echo old
+echo new never shown
EOF
  cat > "$GH_FIX/507.diff" <<'EOF'
diff --git a/.claude/CLAUDE.md b/.claude/CLAUDE.md
index 5555555..6666666 100644
--- a/.claude/CLAUDE.md
+++ b/.claude/CLAUDE.md
@@ -56,1 +56,1 @@
-- Answer from the instrument that table names.
+- Answer from the instrument that table names: the answer is what changed since, why, and the lever you would pull.
diff --git a/.config/opencode/AGENTS.md b/.config/opencode/AGENTS.md
index 7777777..8888888 100644
--- a/.config/opencode/AGENTS.md
+++ b/.config/opencode/AGENTS.md
@@ -30,1 +30,1 @@
+- Answer from the instrument that table names: the answer is what changed since, why, and the lever you would pull.
EOF
}

@test "rules --changed: each rule line a merged PR added or removed, from both config repos" {
  run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  assert_success
  t=$'\t'
  assert_line --index 0 "dotfiles${t}1179${t}docs(skills): comms-standard covers answers in chat${t}.claude/skills/messaging/comms-standard/SKILL.md${t}+${t}- Use the system's own names (shepherd, dispatch, lane, pace, queue item, pass) without defining them, and never explain how a piece of the system works unless asked."
  assert_line --index 1 "dotfiles-private${t}507${t}docs(rules): answer system questions from its instruments${t}.claude/CLAUDE.md${t}-${t}- Answer from the instrument that table names."
  assert_line --index 2 "dotfiles-private${t}507${t}docs(rules): answer system questions from its instruments${t}.claude/CLAUDE.md${t}+${t}- Answer from the instrument that table names: the answer is what changed since, why, and the lever you would pull."
  [ "${#lines[@]}" -eq 3 ]
}

@test "negative control: a script, a generated copy, a frontmatter date and a PR before the window list nothing" {
  run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  refute_output --partial "never shown"
  refute_output --partial "opencode"
  refute_output --partial "reviewed:"
  refute_output --partial "1100"
  run grep -c 'pr diff 1180' "$GH_FIX/calls"
  assert_output 0
}

@test "rules --changed takes epoch seconds and passes the window to GitHub's search" {
  run "$SUBJECT" rules --changed "$(date -u -d 2026-11-06T00:00:00Z +%s)"
  assert_success
  run grep -c -- '--search merged:>=2026-11-06T00:00:00Z' "$GH_FIX/calls"
  assert_output 2
}

@test "rules --changed fails, never lists nothing, when GitHub cannot be read" {
  rm "$GH_FIX/.dotfiles-private.json"
  gh_script 'exit 1'
  run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  assert_failure
  assert_output --partial "gh pr list failed for o/.dotfiles"
}

@test "rules --changed rejects a time it cannot read" {
  run "$SUBJECT" rules --changed yesterdayish
  assert_failure 2
  assert_output --partial "not a time"
}

@test "a PR with 100 files is read whole, and a rename into a nested standards file is listed" {
  # gh lists only a PR's first 100 files, so this one's file list shows no rule file at all.
  jq '. + [{number: 1181, title: "chore: a sweep", mergedAt: "2026-11-06T20:00:00Z",
            files: [range(100) | {path: "x/\(.)"}]}]' "$GH_FIX/.dotfiles.json" > "$GH_FIX/j" && mv "$GH_FIX/j" "$GH_FIX/.dotfiles.json"
  cat > "$GH_FIX/1181.diff" <<'DIFF'
diff --git a/docs/notes.md b/docs/agent/standards.md
similarity index 90%
rename from docs/notes.md
rename to docs/agent/standards.md
@@ -1,1 +1,1 @@
+1. A rule moved into the standards file.
DIFF
  run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  assert_success
  assert_output --partial $'1181\tchore: a sweep\tdocs/agent/standards.md\t+\t1. A rule moved into the standards file.'
}

@test "rules --changed fails when a repo merged as many PRs as one list reads" {
  RULES_CHANGED_MAX_PRS=3 run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  assert_failure
  assert_output --partial "3 PRs merged in o/.dotfiles since 2026-11-06T00:00:00Z, the most one list reads"
}

@test "rules --changed fails when GitHub answers with something that is not JSON" {
  echo "rate limit exceeded" > "$GH_FIX/.dotfiles.json"
  run "$SUBJECT" rules --changed 2026-11-06T00:00:00Z
  assert_failure
  assert_output --partial "gh pr list for o/.dotfiles did not return JSON"
}
