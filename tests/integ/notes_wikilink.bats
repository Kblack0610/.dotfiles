#!/usr/bin/env bats
# notes.nvim `gf` on a [[wikilink]]: the link must open the file it names.
#
# The daily footer and the knowledge MOC write links with spaces in the path and with an
# `|alias`. Vanilla gf stops at both, so those links looked fine and opened nothing - and no
# test noticed, because every notes-cli test checks the TEXT of a link and none follows it.
# This one follows it, in a real headless nvim against a fixture vault.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT/knowledge/archive" "$VAULT/status" "$VAULT/journal/daily"
  printf '# hit\n' > "$VAULT/knowledge/archive/Hit list for removal.md"
  printf '# watches\n' > "$VAULT/status/watches.md"
  printf '# plain\n' > "$VAULT/plain.txt"
  NOTE="$VAULT/journal/daily/2026-10-14.md"
  printf '%s\n' \
    '- [[knowledge/archive/Hit list for removal|Hit list]]' \
    '- Watches: [[status/watches]] and [[status/watches|Watches]]' \
    '- not a link: plain.txt' \
    '- [[nowhere/at all]]' > "$NOTE"
}

# Put the cursor on line $1 at the first byte of $2, run follow(), print the buffer's path.
follow() {
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "set path=$VAULT suffixesadd=.md" \
    -c "edit $NOTE" \
    -c "lua local l = vim.fn.getline($1); vim.api.nvim_win_set_cursor(0, {$1, (l:find('$2', 1, true)) - 1})" \
    -c "lua require('notes.wikilink').follow()" \
    -c "lua io.stdout:write(vim.api.nvim_buf_get_name(0) .. '\n')" \
    -c 'qa!' 2>/dev/null
}

@test "a link with spaces in its path opens the file" {
  run follow 1 'Hit list for'
  assert_output "$VAULT/knowledge/archive/Hit list for removal.md"
}

@test "the alias half of a link opens the target, not a file named after the label" {
  run follow 1 'Hit list]]'
  assert_output "$VAULT/knowledge/archive/Hit list for removal.md"
  run follow 2 'Watches]]'
  assert_output "$VAULT/status/watches.md"
}

@test "with two links on a line, the one under the cursor wins" {
  run follow 2 'status/watches]] and'
  assert_output "$VAULT/status/watches.md"
}

@test "off a wikilink it is still the builtin gf" {
  run follow 3 'plain.txt'
  assert_output "$VAULT/plain.txt"
}

@test "a link to nothing stays on the note" {
  run follow 4 'nowhere'
  assert_output "$NOTE"
}
