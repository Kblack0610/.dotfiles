#!/usr/bin/env bats
# Every --origin a script passes to `notes ptask --agent add` names a writer on the default
# agent_direct_filers list (notes-cli config.rs DIRECT_FILERS), or is `plan`. A name off the list sends
# that script's rows to the outbox with exit 4 when a session runs it (ar-3249).


@test "every --origin in .local/bin is a default direct filer or plan" {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  filers="$(sed -n '/^const DIRECT_FILERS/,/^\];/p' "$root/.local/src/notes-cli/src/config.rs" | grep -oE '"[a-z-]+"' | tr -d '"')"
  [ -n "$filers" ]
  used="$(grep -rIlE ptask "$root/.local/bin" | grep -v claude-recall | xargs grep -hoE -- '--origin[", ]+[a-z-]+' | sed -E 's/--origin[", ]+//' | sort -u)"
  [ -n "$used" ]
  while IFS= read -r name; do
    [ "$name" = plan ] && continue
    grep -qxF "$name" <<<"$filers" || { echo "--origin $name is not in DIRECT_FILERS" >&2; return 1; }
  done <<<"$used"
}
