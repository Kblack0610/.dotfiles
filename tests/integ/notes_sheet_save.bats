#!/usr/bin/env bats
# markdown.lua's on-save sweep of a project sheet goes through `notes sheet-sweep`, the one
# writer of the sheet layout: a save lays `## Tasks` out in Now / Next up / Backlog / Done and
# dates a box ticked by hand. With no CLI the save still writes, unswept.
#
# Loads the real plugin config in a headless nvim (render-markdown stubbed), like
# notes_save_sweep.bats. Needs nvim and the crate built (`cargo build` in notes-cli); skips
# otherwise, so the CI fast tier skips it by design.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPEC="$REPO_ROOT/.config/nvim/lua/kennethblack/plugins/markdown.lua"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  BIN=""
  for b in release debug; do
    [[ -x "$REPO_ROOT/.local/src/notes-cli/target/$b/notes" ]] && { BIN="$REPO_ROOT/.local/src/notes-cli/target/$b"; break; }
  done
  [[ -n "$BIN" ]] || skip "notes-cli not built"
  SHEET="$BATS_TEST_TMPDIR/demo/README.md"
  mkdir -p "${SHEET%/*}"
  cat > "$SHEET" <<'EOF'
# demo
Version: v0.1.0

## Inbox

## Tasks
- [ ] someday #low
- [x] ticked by hand
- [ ] fire #urgent
EOF
}

save() {
  cat > "$BATS_TEST_TMPDIR/t.lua" <<EOF
vim.g.mapleader = " "
package.loaded["render-markdown"] = { setup = function() end }
dofile("$SPEC")[1].config()
vim.cmd("edit $SHEET")
vim.bo.filetype = "markdown"
vim.cmd "silent write"
EOF
  PATH="$1" nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

@test "save lays the sheet out in sections and dates a hand-ticked row" {
  run save "$BIN:$PATH"
  assert_success
  today=$(date +%F)
  run cat "$SHEET"
  assert_output "# demo
Version: v0.1.0

## Inbox

## Tasks
### Next up
- [ ] fire #urgent
- [ ] someday #low
- [ ] 

---
### Done
- [x] ticked by hand <!-- done:$today -->"
}

# NEGATIVE CONTROL: no CLI, so nothing sweeps, and the save still lands.
@test "with no notes CLI the save writes the buffer unswept" {
  before=$(cat "$SHEET")
  run save "/usr/bin:/bin"
  assert_success
  run cat "$SHEET"
  assert_output "$before"
}
