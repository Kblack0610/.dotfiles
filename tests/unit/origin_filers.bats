#!/usr/bin/env bats
# Every --origin a script passes to `notes ptask add` names a writer on the default
# agent_direct_filers list (notes-cli config.rs DIRECT_FILERS), or is `plan`. A name off the list sends
# that script's rows to the outbox with exit 4 when a session runs it (ar-3249). notes vouches for an
# --origin only from the process (the runner's AGENTCTL_NAME or the parent script's basename, ar-3684),
# so a script's --origin is its own name. Both repos' .local/bin are scanned; the private one when it
# is checked out.

load '../helpers/private'

setup() {
  # The suite runs under a throwaway HOME, so the checkout is found from the account's.
  PRIVATE="${DOTFILES_PRIVATE:-${ACCOUNT_HOME:-$HOME}/.dotfiles-private}"
}

# origins: one `<file>:<name>` line per --origin a ptask-calling script in either .local/bin passes.
origins() {
  local root dirs
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  dirs=("$root/.local/bin")
  ! has_private || dirs+=("$PRIVATE/.local/bin")
  grep -rIlE ptask "${dirs[@]}" | grep -v claude-recall | xargs grep -oE -- '--origin[", ]+[a-z-]+' \
    | sed -E 's/:--origin[", ]+/:/' | sort -u
}

@test "every --origin in both .local/bin is a default direct filer or plan, under its own script's name" {
  has_private || echo "# private unchecked: no checkout at $PRIVATE" >&3
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  filers="$(sed -n '/^const DIRECT_FILERS/,/^\];/p' "$root/.local/src/notes-cli/src/config.rs" | grep -oE '"[a-z-]+"' | tr -d '"')"
  [ -n "$filers" ]
  used="$(origins)"
  [ -n "$used" ]
  while IFS=: read -r file name; do
    base="${file##*/}"
    if [ "$name" = plan ]; then
      [ "$base" = agent-queue ] || { echo "$file passes --origin plan, which notes vouches for only from agent-queue" >&2; return 1; }
      continue
    fi
    grep -qxF "$name" <<<"$filers" || { echo "$file: --origin $name is not in DIRECT_FILERS" >&2; return 1; }
    [ "$name" = "$base" ] || { echo "$file passes --origin $name, which notes vouches for only from a script named $name" >&2; return 1; }
  done <<<"$used"
}
