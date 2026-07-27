#!/usr/bin/env bats
# favourites.sh -- Prefix+s stars the agent in the current pane, Prefix+o reopens it later.
#
# The registry is a TSV of {tool, session_id, cwd, label, added_at}, which makes almost all of
# this assertable without a terminal: the row source, the wire format, the remove path, and
# which tmux commands a restore issues.
#
# Migrated onto panel-lib.sh. It carried the one LIVE relative-path break of the eleven:
# SELF="$0" while re-invoking $SELF from five separate fzf actions, so launching it by a
# relative path made every ctrl-x / ctrl-r / ctrl-a / preview inside the picker fail.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  FAV="$REPO_ROOT/.local/src/tmux/favourites.sh"
  export FAV
  export FAVOURITES_STATE_DIR="$SANDBOX/fav-state"
  export CLAUDE_SESSIONS_DIR="$SANDBOX/claude-sessions"
  export OPENCODE_DB="$SANDBOX/no-such-opencode.db"
  mkdir -p "$CLAUDE_SESSIONS_DIR" "$SANDBOX/proj-alpha" "$SANDBOX/proj.dotted"

  REG="$FAVOURITES_STATE_DIR/favourites.tsv"
  export REG
}

# THREE favourites, so a test can tell "picked the right row" from "picked the only row".
seed_three() {
  mkdir -p "$FAVOURITES_STATE_DIR"
  {
    printf 'claude\tsess-one\t%s\tfirst label\t2026-07-01\n' "$SANDBOX/proj-alpha"
    printf 'opencode\tsess-two\t%s\tsecond label\t2026-07-02\n' "$SANDBOX/proj-alpha"
    printf 'claude\tsess-three\t%s\tthird label\t2026-07-03\n' "$SANDBOX/proj.dotted"
  } > "$REG"
}

# ── The registry as a wire format ────────────────────────────────────────────

@test "_list emits one row per favourite, four tab-separated fields" {
  # The field count is a contract: cmd_open's fzf passes {1} {2} {3} into _preview and
  # `remove`, so a row that grows or loses a column silently misroutes both.
  seed_three
  run "$FAV" _list
  assert_success
  assert_equal "$(grep -c . <<< "$output")" 3
  assert_equal "$(awk -F'\t' 'NR==1{print NF}' <<< "$output")" 4
}

@test "_list carries tool, id and cwd in the first three fields, in that order" {
  seed_three
  run "$FAV" _list
  local line2
  line2="$(sed -n 2p <<< "$output")"
  assert_equal "$(cut -f1 <<< "$line2")" 'opencode'
  assert_equal "$(cut -f2 <<< "$line2")" 'sess-two'
  assert_equal "$(cut -f3 <<< "$line2")" "$SANDBOX/proj-alpha"
}

@test "_list on an empty registry succeeds and emits nothing" {
  # An empty picker and a crashed one must not look the same to the caller.
  run "$FAV" _list
  assert_success
  assert_output ''
}

@test "remove drops exactly the addressed favourite" {
  # Keyed on tool AND id: two tools can hold the same session id.
  seed_three
  run "$FAV" remove opencode sess-two
  assert_success
  run "$FAV" _list
  assert_equal "$(grep -c . <<< "$output")" 2
  refute_output --partial 'sess-two'
  assert_output --partial 'sess-one'
  assert_output --partial 'sess-three'
}

@test "remove of an absent favourite leaves the registry intact" {
  seed_three
  run "$FAV" remove claude nope-not-here
  run "$FAV" _list
  assert_equal "$(grep -c . <<< "$output")" 3
}

# ── Restore ──────────────────────────────────────────────────────────────────

@test "restore resumes the exact session id, not a fresh agent" {
  # The whole point of a favourite: `claude --resume <id>`. Losing the id silently downgrades
  # a restore into "open a new chat here", which looks like it worked.
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_success
  assert_called 'claude --resume sess-one'
}

@test "restore falls back to a bare agent when the id is stale" {
  # `|| claude` in the inner command. Asserted as text because the fallback only fires inside
  # the spawned shell, which is not this process.
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_called '|| claude'
}

@test "restore uses the opencode flag for an opencode favourite" {
  TMUX=/tmp/fake,1,0 run "$FAV" restore opencode sess-two "$SANDBOX/proj-alpha"
  assert_success
  assert_called 'opencode --session sess-two'
}

@test "restore reuses an existing session and addresses it exactly" {
  # The stub answers has-session rc 0, so the session always exists. Creating one anyway
  # would clobber a live session's directory.
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_called 'has-session -t =proj-alpha'
  assert_not_called 'new-session'
}

@test "restore opens the agent in a NEW window named after the tool" {
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_called 'new-window -t =proj-alpha'
  assert_called '-n claude'
}

@test "restore always creates the window, inside tmux or out" {
  # Pre-migration this branched on `pgrep -x tmux`: with no server running it took an
  # attached new-session path and skipped new-window entirely, so the SAME verb produced
  # either a session-with-one-window or a session-plus-window depending on an unrelated
  # process check. Now the shape is identical and only the focus call differs.
  run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_success
  assert_called 'new-window -t =proj-alpha'
  assert_called 'attach -t proj-alpha'
  assert_not_called 'switch-client'
}

@test "restore switches the client when already inside tmux" {
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/proj-alpha"
  assert_called 'switch-client -t proj-alpha'
  assert_not_called 'attach -t'
}

@test "a dotted directory becomes a dot-free session name" {
  # tmux reads `.` as the window/pane separator in a target, so proj.dotted would address
  # window "dotted" of session "proj".
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-three "$SANDBOX/proj.dotted"
  assert_success
  assert_called 'has-session -t =proj_dotted'
  assert_not_called '=proj.dotted'
}

@test "restore refuses when the directory is gone, before touching tmux" {
  TMUX=/tmp/fake,1,0 run "$FAV" restore claude sess-one "$SANDBOX/deleted-since"
  assert_failure
  assert_output --partial 'directory gone'
  assert_not_called 'new-window'
  assert_not_called 'new-session'
}

@test "restore rejects an unknown tool rather than guessing a command" {
  TMUX=/tmp/fake,1,0 run "$FAV" restore ollama sess-one "$SANDBOX/proj-alpha"
  assert_failure
  assert_output --partial 'unknown tool'
  assert_not_called 'new-window'
}

@test "restore with the wrong number of arguments is rejected" {
  run "$FAV" restore claude sess-one
  assert_failure
  assert_output --partial 'usage: restore'
}

# ── Conformance, exercised rather than grepped ───────────────────────────────

# fzf_recorder -- an fzf that logs its own argv and exits 130, never reading stdin.
#
# Not a fake of anything under assertion: it is the instrument that makes the picker's
# COMMAND LINE inspectable. Exiting 130 (fzf's own cancel code) also means it can never block
# a headless run, which is the one way an integ test can hang forever.
fzf_recorder() {
  cat > "$SANDBOX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTES_FIXTURE/fzf-argv.log"
exit 130
EOF
  chmod +x "$SANDBOX/bin/fzf"
  : > "$NOTES_FIXTURE/fzf-argv.log"
}

fzf_argv() { cat "$NOTES_FIXTURE/fzf-argv.log" 2>/dev/null; }

@test "every \$SELF re-invocation handed to fzf is an ABSOLUTE path" {
  # THE regression this migration fixes, and it has to be asserted on the picker's argv --
  # not on _list's output. SELF="$0" was re-invoked from five fzf actions (preview, ctrl-x
  # remove, two reloads, ctrl-a become), so a relative launch broke all five while _list
  # itself, which never touches $SELF, kept working. Comparing _list output therefore proves
  # nothing: verified by reverting to SELF="$0", where such a test still passed.
  seed_three
  fzf_recorder
  cd "$REPO_ROOT/.local/src/tmux"
  run ./favourites.sh open        # RELATIVE launch, which is the whole point
  fzf_argv | grep -q . || fail "fzf was never invoked -- the recorder saw nothing"

  # Pull every path this script handed back to itself out of the actions.
  local refs
  refs="$(fzf_argv | grep -oE '[^ (]*favourites\.sh' | sort -u)"
  [ -n "$refs" ] || fail "no self-reference found in fzf's argv: $(fzf_argv)"
  local r
  while read -r r; do
    case "$r" in
    /*) ;;
    *) fail "fzf action re-invokes a RELATIVE path ($r) -- it would not resolve inside the picker" ;;
    esac
  done <<< "$refs"
}

@test "the fzf actions cover every documented key, through \$SELF" {
  # A bind that names a verb the script does not dispatch fails silently inside fzf's
  # execute(). Cross-reference the two lists, the way cockpit_binds.bats does per-script.
  seed_three
  fzf_recorder
  run "$FAV" open
  local argv; argv="$(fzf_argv)"
  assert_regex "$argv" 'ctrl-x:execute-silent\(.*remove'
  assert_regex "$argv" 'ctrl-r:reload\(.*_list'
  assert_regex "$argv" 'ctrl-a:become\(.*add-pick'
  assert_regex "$argv" '_preview'
  local verb
  for verb in remove _list add-pick _preview; do
    grep -qE "^ *${verb}\)|\|${verb}\)" "$FAV" || fail "fzf invokes '$verb' but the dispatch has no arm for it"
  done
}

@test "the picker uses the modern comma-form preview window" {
  # One dialect across all panels; this file previously spelled it right:60%:wrap.
  seed_three
  fzf_recorder
  run "$FAV" open
  assert_regex "$(fzf_argv)" '--preview-window=right,60%,border-left,wrap'
}

@test "diagnostics reach stderr, not just the tmux flash" {
  # The old die() sent the reason to `tmux display-message` and only fell back to stderr if
  # that failed -- so a scripted caller with a live tmux server got an exit code and nothing
  # else. panel_warn always writes stderr.
  run --separate-stderr "$FAV" restore ollama sess-one "$SANDBOX/proj-alpha"
  assert_failure
  [[ "$stderr" == *'unknown tool'* ]] || fail "expected the reason on stderr, got: $stderr"
}

@test "--help prints the header block" {
  run "$FAV" --help
  assert_success
  assert_output --partial 'Session favourites'
  assert_output --partial 'Registry:'
  refute_output --partial '#!/usr/bin/env'
}

@test "an unknown subcommand is rejected" {
  run "$FAV" bogus
  assert_failure
  assert_output --partial 'unknown subcommand: bogus'
}

@test "FAVOURITES_STATE_DIR is actually read" {
  # Proves the config key changes behaviour. Without it this whole file would be testing the
  # developer's real registry.
  seed_three
  FAVOURITES_STATE_DIR="$SANDBOX/somewhere-else" run "$FAV" _list
  assert_success
  assert_output ''
}

@test "the registry survives a state dir containing a space" {
  # $SANDBOX contains a space by design (sandbox.bash:32).
  export FAVOURITES_STATE_DIR="$SANDBOX/fav state dir"
  REG="$FAVOURITES_STATE_DIR/favourites.tsv"
  seed_three
  run "$FAV" _list
  assert_success
  assert_equal "$(grep -c . <<< "$output")" 3
}
