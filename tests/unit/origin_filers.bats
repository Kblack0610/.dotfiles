#!/usr/bin/env bats
# Every --origin a script passes to `notes ptask add` names a writer on the default
# agent_direct_filers list (notes-cli config.rs DIRECT_FILERS), or is `plan`. A name off the list sends
# that script's rows to the outbox with exit 4 when a session runs it (ar-3249). notes vouches for an
# --origin only from the process (the runner's AGENTCTL_NAME or the parent script's basename, ar-3684),
# so a script's --origin is its own name. Both repos' .local/bin are scanned; the private one when it
# is checked out.


@test "every --origin in both .local/bin is a default direct filer or plan" {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  private="${DOTFILES_PRIVATE:-${ACCOUNT_HOME:-$HOME}/.dotfiles-private}"
  dirs=("$root/.local/bin")
  [ ! -d "$private/.local/bin" ] || dirs+=("$private/.local/bin")
  filers="$(sed -n '/^const DIRECT_FILERS/,/^\];/p' "$root/.local/src/notes-cli/src/config.rs" | grep -oE '"[a-z-]+"' | tr -d '"')"
  [ -n "$filers" ]
  used="$(grep -rIlE ptask "${dirs[@]}" | grep -v claude-recall | xargs grep -hoE -- '--origin[", ]+[a-z-]+' | sed -E 's/--origin[", ]+//' | sort -u)"
  [ -n "$used" ]
  while IFS= read -r name; do
    [ "$name" = plan ] && continue
    grep -qxF "$name" <<<"$filers" || { echo "--origin $name is not in DIRECT_FILERS" >&2; return 1; }
  done <<<"$used"
}

@test "a script passes --origin only under its own name (or plan from agent-queue)" {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  while IFS=: read -r file name; do
    base="${file##*/}"
    [ "$name" = "$base" ] && continue
    [ "$name" = plan ] && [ "$base" = agent-queue ] && continue
    echo "$file passes --origin $name, which notes vouches for only from a script named $name" >&2
    return 1
  done < <(grep -rIlE ptask "$root/.local/bin" | grep -v claude-recall | xargs grep -oE -- '--origin[", ]+[a-z-]+' | sed -E 's/:--origin[", ]+/:/' | sort -u)
}
