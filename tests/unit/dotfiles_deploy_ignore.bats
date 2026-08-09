#!/usr/bin/env bats
# dotfiles-deploy's stow-ignore matcher, sourced directly. The cheapest tier that can
# actually fail here, and the one that decides the two questions the whole tool rests on:
#
#   WHAT DEPLOYS      get an ignore rule slightly too wide and the tool stops seeing a
#                     mirror it should repair; slightly too narrow and it demands that a
#                     README or a macOS-only config be linked into $HOME.
#   WHO OWNS A PATH   README.md, .gitignore and .stow-local-ignore are tracked in BOTH
#                     repos. They are only NOT a dual-ownership conflict because stow
#                     ignores all three in both. That answer is produced entirely by the
#                     rules below, so it is pinned here rather than left to inspection.
#
# Every rule asserted here was re-derived empirically against GNU Stow 2.4.1 (`stow -v3
# --simulate` over a fixture package) rather than read out of the man page, because the
# man page does not make rules 2 and 4 obvious and getting either wrong is silent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/dotfiles-deploy"
}

# ign <pattern-lines...> — load an ignore list from a here-doc-ish argument list.
ign() {
  local d="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$d"
  printf '%s\n' "$@" > "$d/.stow-local-ignore"
  load_ignore "$d"
}

# ── rule 1: a pattern with a slash is path-anchored, one without is a basename ───

@test "an anchored top-level pattern excludes only the top-level file" {
  ign '^/README\.md$'
  stow_ignored 'README.md'          || fail 'top-level README.md should be ignored'
  ! stow_ignored '.local/bin/README.md' || fail '.local/bin/README.md is a DIFFERENT file and deploys'
  ! stow_ignored 'sub/README.md'    || fail 'sub/README.md deploys'
}

@test "a slashless pattern matches the basename at any depth" {
  ign 'hypr'
  stow_ignored '.config/hypr'       || fail '.config/hypr should be ignored'
  stow_ignored '.local/bin/hypr'    || fail 'a basename pattern is not depth-limited'
  stow_ignored 'hypr'               || fail 'top level too'
}

# ── rule 2: implicit anchoring at BOTH ends ──────────────────────────────────
# Without this, `hypr` would eat `xhyprx` and `notes` would eat every notes-* script in
# .local/bin. That is a whole category of file silently not deploying, which is exactly
# the failure this tool exists to end.

@test "patterns are anchored, so a substring is not a match" {
  ign 'hypr' 'notes'
  ! stow_ignored '.local/bin/xhyprx'   || fail 'xhyprx must not match hypr'
  ! stow_ignored '.local/bin/notes.txt' || fail 'notes.txt must not match notes'
  ! stow_ignored '.local/bin/notes-sync' || fail 'notes-sync must not match notes'
}

@test "an anchored path pattern does not match a longer path with the same prefix" {
  ign '^/\.git$'
  stow_ignored '.git'          || fail
  ! stow_ignored '.gitignore'  || fail '.gitignore is not .git'
  ! stow_ignored '.gitmodules' || fail
}

# ── rule 3: an ignored directory prunes its subtree ──────────────────────────

@test "ignoring a directory ignores everything under it, at any depth" {
  ign '^/\.config/hypr$'
  stow_ignored '.config/hypr'                       || fail
  stow_ignored '.config/hypr/hyprland.conf'         || fail 'a child of an ignored dir deploys'
  stow_ignored '.config/hypr/scripts/deep/thing.sh' || fail 'pruning is not depth-limited'
  ! stow_ignored '.config/hyprpaper.conf'           || fail 'a sibling with a longer name deploys'
  ! stow_ignored '.local/hypr/x.conf'               || fail 'a different path with the same leaf deploys'
}

# ── rule 4: the package's own ignore file is ALWAYS ignored ──────────────────
# This is the hinge for dual ownership. The PUBLIC repo's .stow-local-ignore does not list
# .stow-local-ignore, and both repos track the file -- so if stow did not special-case it,
# it would be a genuine two-owner conflict and this tool would refuse to run on a machine
# that is in fact correctly configured.

@test ".stow-local-ignore never deploys, even when the list does not mention it" {
  ign '^/\.git$'
  stow_ignored '.stow-local-ignore' || fail 'stow always excludes the package ignore file'
}

@test "a NESTED .stow-local-ignore is an ordinary file and does deploy" {
  # Verified against real stow: only the package-root one is special-cased.
  ign '^/\.git$'
  ! stow_ignored 'deep/nest/.stow-local-ignore' || fail 'only the top-level one is special'
}

# ── list parsing ─────────────────────────────────────────────────────────────

@test "blank lines and comments are skipped, not compiled into patterns" {
  ign '# a comment' '' '   ' '^/README\.md$'
  stow_ignored 'README.md' || fail
  # If '' had become a pattern it would anchor to ^()$ and match nothing, but a '#...'
  # line compiled as a regex is a live hazard: it would match a literal filename.
  ! stow_ignored '# a comment' || fail 'a comment line must not act as a pattern'
  ! stow_ignored 'anything.txt' || fail
}

@test "surrounding whitespace is trimmed off a pattern" {
  ign '  ^/README\.md$  '
  stow_ignored 'README.md' || fail 'an untrimmed pattern would never match anything'
}

# ── the no-ignore-file fallback ──────────────────────────────────────────────

@test "a repo with no .stow-local-ignore falls back to stow's defaults, not to nothing" {
  # "Ignore nothing" is the dangerous default: it would claim .git, every editor backup
  # file and the README as deploy paths and demand they be linked into $HOME.
  load_ignore "$BATS_TEST_TMPDIR/no-such-repo"
  [ "${#IGNORE_PATS[@]}" -gt 0 ] || fail 'the fallback list came back EMPTY'
  stow_ignored '.git'        || fail
  stow_ignored 'README.md'   || fail
  stow_ignored 'notes.txt~'  || fail 'editor backups are in stow default list'
  ! stow_ignored '.local/bin/tool' || fail 'a real file still deploys'
}

# ── the real lists, as shipped ───────────────────────────────────────────────
# Fixtures reproducing what both repos actually ship. Copies rather than reads of the live
# files, so this pins the ANSWER ("these three never deploy, so they are not a conflict")
# and keeps failing if someone edits a live list in a way that breaks it.

@test "the three paths tracked by BOTH repos are ignored by BOTH, so nothing is dual-owned" {
  local p
  # public list, as shipped
  ign '^/\.git$' '^/\.gitignore$' '^/\.gitmodules$' '^/\.github$' '^/AGENTS\.md$' '^/README\.md$'
  for p in README.md .gitignore .stow-local-ignore; do
    stow_ignored "$p" || fail "public repo would deploy $p, making it dual-owned"
  done
  # private list, as shipped
  ign '^/\.git$' '^/\.gitignore$' '^/\.stow-local-ignore$' '^/README\.md$'
  for p in README.md .gitignore .stow-local-ignore; do
    stow_ignored "$p" || fail "private repo would deploy $p, making it dual-owned"
  done
}

@test "the public list does not accidentally swallow a real deploy path" {
  # Every entry in the public list is a top-level anchor, so nothing under .local/bin or
  # .local/lib may be caught by it. A regression here silently shrinks the manifest.
  ign '^/\.git$' '^/\.gitignore$' '^/\.github$' '^/AGENTS\.md$' '^/README\.md$' \
      '^/\.local/src/installation_scripts$' '^/etc$' '^/\.config/hypr$' '^/\.config/waybar$'
  local p
  for p in .local/bin/dotfiles-deploy .local/bin/dotfiles-drift .local/lib/agent-board.sh \
           .config/shared-hooks/lab-roots.sh .local/src/tmux/fleet.sh; do
    ! stow_ignored "$p" || fail "the public list wrongly excludes $p"
  done
  # and it DOES catch what it is meant to
  stow_ignored '.local/src/installation_scripts/install_arch.sh' || fail
  stow_ignored '.config/waybar/style.css' || fail
}
