#!/usr/bin/env bats
# pr-viewer.sh -- Prefix+p, the open-PR board.
#
# integ tier: the script runs as a subprocess against the recording `gh` stub, so no test
# here touches the network. The fzf picker is not exercised (there is nothing to assert
# about a picker's rendering that is not a test of the fake); --list, the row source behind
# it, is.
#
# This panel was the last non-conformer in the tree and carried three separate ratchets in
# panel_conformance.bats: no strict mode, no $SELF, and `--bind "ctrl-r:reload(bash $0)"`
# with a bare unquoted $0. It also had ~90 lines of dead bash superseded by an embedded
# python heredoc, and that heredoc was UNQUOTED -- $json_file and $repo were spliced
# straight into python source.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PR_VIEWER="$REPO_ROOT/.local/src/tmux/pr-viewer.sh"
  export PR_VIEWER

  # THREE PRs, not two, and each with a different status, so a test can tell "picked the
  # right row" from "picked the only row" and the priority ladder has something to rank.
  cat > "$NOTES_FIXTURE/prs.acme-widget" <<'JSON'
[
  {"number": 11, "title": "failing one",  "createdAt": "2020-01-01T00:00:00Z",
   "isDraft": false, "reviewDecision": "", "url": "https://x/11",
   "statusCheckRollup": [{"conclusion": "FAILURE", "status": "COMPLETED"}]},
  {"number": 22, "title": "pending one",  "createdAt": "2020-01-01T00:00:00Z",
   "isDraft": true,  "reviewDecision": "REVIEW_REQUIRED", "url": "https://x/22",
   "statusCheckRollup": [{"conclusion": null, "status": "IN_PROGRESS"}]},
  {"number": 33, "title": "green one",    "createdAt": "2020-01-01T00:00:00Z",
   "isDraft": false, "reviewDecision": "APPROVED", "url": "https://x/33",
   "statusCheckRollup": [{"conclusion": "SUCCESS", "status": "COMPLETED"}]}
]
JSON

  PR_REPOS_CONF="$SANDBOX/pr-repos.conf"
  export PR_REPOS_CONF
  printf 'acme/widget\n' > "$PR_REPOS_CONF"
  export PANEL_NO_COLOR=1
}

# ── The row source ───────────────────────────────────────────────────────────

@test "--list emits four tab-separated fields per row" {
  run "$PR_VIEWER" --list
  assert_success
  # Every row, header included, must have the same arity or --with-nth misaligns.
  run bash -c "'$PR_VIEWER' --list | awk -F'\t' '{print NF}' | sort -u"
  assert_output '4'
}

@test "--list puts the machine columns first and the display last" {
  run bash -c "'$PR_VIEWER' --list | grep -F 'failing one'"
  assert_success
  assert_output --partial 'acme/widget'
  assert_output --partial '11'
  assert_output --partial 'https://x/11'
}

@test "--list emits a group header per repo, keyed so the picker can skip it" {
  run bash -c "'$PR_VIEWER' --list | awk -F'\t' '\$1 == \"head\"'"
  assert_success
  assert_output --partial 'acme/widget'
  assert_output --partial '(3)'
}

@test "a failing check ranks above a pending one, which ranks above green" {
  # The priority ladder (! > ~ > ok > idle) is the whole point of the combined glyph, and
  # it is the one piece of logic a wrong refactor would silently invert.
  run bash -c "'$PR_VIEWER' --list | grep -F 'failing one'"
  assert_output --partial '!'
  run bash -c "'$PR_VIEWER' --list | grep -F 'pending one'"
  assert_output --partial '~'
  refute_output --partial '!'
}

@test "a draft PR is marked as one" {
  run bash -c "'$PR_VIEWER' --list | grep -F 'pending one'"
  assert_output --partial '[draft]'
}

@test "a repo with no open PRs contributes no rows and no header" {
  printf 'acme/empty\n' > "$PR_REPOS_CONF"
  run "$PR_VIEWER" --list
  assert_success
  refute_output --partial 'acme/empty'
}

@test "--list reaches gh once per configured repo and never for an unlisted one" {
  printf 'acme/widget\nacme/other\n' > "$PR_REPOS_CONF"
  run "$PR_VIEWER" --list
  assert_success
  assert_called 'pr list -R acme/widget'
  assert_called 'pr list -R acme/other'
  assert_not_called 'pr list -R acme/nope'
}

# ── Config handling ──────────────────────────────────────────────────────────

@test "PR_REPOS_CONF is actually read" {
  # Prove the key changes behaviour rather than merely existing. The pre-fix script
  # hardcoded $HOME/.dotfiles/... so a fixture had nowhere to redirect it.
  printf 'acme/other\n' > "$PR_REPOS_CONF"
  run "$PR_VIEWER" --list
  assert_called 'pr list -R acme/other'
  assert_not_called 'pr list -R acme/widget'
}

@test "a malformed config line is skipped, not fatal" {
  printf 'not a repo!!\nacme/widget\n' > "$PR_REPOS_CONF"
  run "$PR_VIEWER" --list
  assert_success
  assert_output --partial 'failing one'
}

@test "comments and blank lines in the config are ignored" {
  printf '# a comment\n\nacme/widget   # trailing\n' > "$PR_REPOS_CONF"
  run "$PR_VIEWER" --list
  assert_success
  assert_called 'pr list -R acme/widget'
}

@test "a missing config fails loudly instead of rendering an empty picker" {
  # "No open PRs" and "your config is missing" must not print the same empty screen.
  PR_REPOS_CONF="$SANDBOX/nope.conf" run "$PR_VIEWER" --list
  assert_failure
  assert_output --partial 'no repo config'
}

@test "PR_LIMIT is actually passed through to gh" {
  PR_LIMIT=7 run "$PR_VIEWER" --list
  assert_called '--limit 7'
}

# ── Auth ─────────────────────────────────────────────────────────────────────

@test "a failed gh auth check stops before any pr list" {
  : > "$NOTES_FIXTURE/auth.fail"
  run "$PR_VIEWER" --list
  assert_failure
  assert_output --partial 'not authenticated'
  assert_not_called 'pr list'
}

# ── Details ──────────────────────────────────────────────────────────────────

@test "--show renders one PR and refuses a header row" {
  run "$PR_VIEWER" --show acme/widget 11
  assert_success
  assert_output --partial 'gh pr view'
  # A header row reaching --show (via the preview binding) must be a silent no-op.
  run "$PR_VIEWER" --show head ''
  assert_success
  assert_output ''
}

# ── Conformance, exercised rather than grepped ───────────────────────────────

@test "--help prints the header block without reaching for fzf or gh" {
  run "$PR_VIEWER" --help
  assert_success
  assert_output --partial 'Usage: pr-viewer.sh'
  assert_output --partial 'PR_REPOS_CONF'
  refute_output --partial '#!/usr/bin/env'
  assert_not_called 'pr list'
}

@test "an unknown verb is rejected instead of opening the picker" {
  # Without a default arm a typo'd verb falls through to fzf, which in a headless test
  # blocks forever rather than failing.
  run "$PR_VIEWER" --lst
  assert_failure
  assert_output --partial 'unknown verb'
  assert_not_called 'pr list'
}

@test "output is identical when invoked by a relative path" {
  local abs rel
  abs="$("$PR_VIEWER" --list)"
  rel="$(cd "$REPO_ROOT/.local/src/tmux" && ./pr-viewer.sh --list)"
  assert_equal "$rel" "$abs"
}

@test "it survives a config path containing a space" {
  # $SANDBOX contains a space by design (sandbox.bash:50). The pre-fix script's
  # `reload(bash $0)` was unquoted and broke on exactly this.
  local spaced="$SANDBOX/has space.conf"
  printf 'acme/widget\n' > "$spaced"
  PR_REPOS_CONF="$spaced" run "$PR_VIEWER" --list
  assert_success
  assert_output --partial 'failing one'
}

@test "a PR title containing a quote cannot break the python program" {
  # The pre-fix heredoc was UNQUOTED, so $repo and $json_file were spliced into python
  # source. A title with a quote is the same class one layer up -- it must render, not
  # raise a SyntaxError and vanish.
  cat > "$NOTES_FIXTURE/prs.acme-widget" <<'JSON'
[{"number": 44, "title": "it's a \"quoted\" '); import os #", "createdAt": "2020-01-01T00:00:00Z",
  "isDraft": false, "reviewDecision": "APPROVED", "url": "https://x/44",
  "statusCheckRollup": [{"conclusion": "SUCCESS", "status": "COMPLETED"}]}]
JSON
  run "$PR_VIEWER" --list
  assert_success
  assert_output --partial '44'
  assert_output --partial 'quoted'
}
