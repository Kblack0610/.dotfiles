#!/usr/bin/env bats
# .local/lib/prom.sh is sourced from zsh as well as bash. zsh ties some lower-case names to its own
# state (path to PATH, status to $?), so a function local by one of those names breaks a zsh caller:
# `local path` in _prom_get emptied PATH and every query failed (ar-2000-prom-zsh). CI has no zsh,
# so this reads the source.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "prom.sh declares no local zsh ties to its own state" {
  run grep -nE '^\s*local\b[^#]*\b(path|status|argv|options|commands|functions|aliases|parameters|pipestatus|fpath|cdpath|manpath|module_path)\b' "$ROOT/.local/lib/prom.sh"
  [ "$status" -eq 1 ]
}

@test "the guard above trips on a zsh tie (negative control)" {
  printf 'f() {\n  local path=$1 out\n}\n' > "$BATS_TEST_TMPDIR/bad.sh"
  run grep -nE '^\s*local\b.*\b(path|status|argv)\b' "$BATS_TEST_TMPDIR/bad.sh"
  [ "$status" -eq 0 ]
}
