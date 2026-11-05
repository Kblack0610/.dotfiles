#!/usr/bin/env bats
# The Keys table in .local/src/tmux/README.md is the one list of every key .tmux.conf binds.
# It drifted before: Prefix+O stayed documented after the bind went, and a new bind landed with no
# row. Both directions are checked, from the files as text, so no tmux server is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CONF="$REPO_ROOT/.tmux.conf"
  DOC="$REPO_ROOT/.local/src/tmux/README.md"
}

# The keys .tmux.conf binds, as the doc writes them: `Prefix+K` for the prefix table, `K` for -n.
# copy-mode-vi and the tags table are one row each, checked by the last test.
bound() {
  awk '
    /^[[:space:]]*(bind|bind-key)[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      n = split(line, F, /[[:space:]]+/); root = 0
      for (i = 2; i <= n; i++) {
        if (F[i] == "-n") { root = 1; continue }
        if (F[i] == "-T") break
        if (F[i] ~ /^-/) continue
        print (root ? F[i] : "Prefix+" F[i]); break
      }
    }' "$CONF" | sort -u
}

# The first column of the Keys table, one backticked key per line.
documented() {
  awk '/^## Keys/ { on = 1; next } /^## / { on = 0 } on && /^\| `/ { split($0, C, "|"); print C[2] }' "$DOC" |
    grep -o '`[^`]*`' | tr -d '`' | sort -u
}

@test "every bound key has a row in the Keys table" {
  run comm -23 <(bound) <(documented)
  assert_output ''
}

@test "every Prefix key in the Keys table is bound" {
  run comm -13 <(bound) <(documented | grep -E '^(Prefix\+|M-)')
  assert_output ''
}

@test "the copy-mode and tag tables have their rows" {
  grep -q '^| copy mode `v` / `y` / `Y` |' "$DOC"
  grep -q '^| `Prefix+t` / `Prefix+C-t` | Tag this window' "$DOC"
}
