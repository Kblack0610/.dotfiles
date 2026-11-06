#!/usr/bin/env bats
# Every bind in .tmux.conf, in every table, carries a -N note: the note is the key's row in
# `keys` (Prefix+K), the one list of what each key does. A hand-kept README table drifted
# before (a row outlived its bind, a bind landed with no row), so the doc is the bind itself.
# Read from the file as text, so no tmux server is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CONF="$REPO_ROOT/.tmux.conf"
}

# Every bind line as "<line>: <table> <key>", with a third field "noted" when it has a -N note.
binds() {
  awk '
    /^[[:space:]]*(bind|bind-key)[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      noted = (line ~ /^(bind|bind-key)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-N[[:space:]]+"[^"]+"/)
      rest = line; sub(/^(bind|bind-key)[[:space:]]+/, "", rest)
      table = "prefix"
      while (rest ~ /^-/) {
        if (rest ~ /^-N[[:space:]]+"/) { sub(/^-N[[:space:]]+"[^"]*"[[:space:]]*/, "", rest); continue }
        if (rest ~ /^-T[[:space:]]/) { sub(/^-T[[:space:]]+/, "", rest); table = rest; sub(/[[:space:]].*/, "", table)
                                       sub(/^[^[:space:]]+[[:space:]]+/, "", rest); continue }
        if (rest ~ /^-n[[:space:]]/) table = "root"
        sub(/^-[a-zA-Z]+[[:space:]]+/, "", rest)
      }
      key = rest; sub(/[[:space:]].*/, "", key)
      print NR ": " table " " key (noted ? " noted" : "")
    }' "$CONF"
}

@test "the parser sees binds in the prefix, root, copy-mode-vi and tags tables" {
  # Guards the guard: a parse that matched nothing would pass the note test by vacuum.
  run binds
  assert_output --regexp ': prefix K( |$)'
  assert_output --regexp ': root M-h( |$)'
  assert_output --regexp ': copy-mode-vi v( |$)'
  assert_output --regexp ': tags Escape( |$)'
}

@test "every bind in every table has a -N note" {
  # The output is the list of binds without one.
  run bash -c "$(declare -f binds); CONF='$CONF' binds | grep -v ' noted\$'"
  assert_output ''
}
