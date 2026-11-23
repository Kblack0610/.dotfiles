#!/usr/bin/env bats
# A runner's instructions are files its conf names as PROMPT (agentctl README, "What an agent is"),
# and judge-eval scores a lane only under its current prompt_sha (judges.md): a scored conf (SCORE=)
# with no PROMPT mixes every past version of its prompt into one score. This guard reads every conf:
# (a) a scored one names a PROMPT, (b) each PROMPT file resolves, $HOME mapped to this repo or the
# private one as stow maps it, and expands (its includes found), and (c) its prompt_sha moves when
# the file or any file it includes changes, on a copy. The live confs are the private repo's
# ($DOTFILES_PRIVATE), skipped where it is not checked out (public CI); the negative controls run
# each check on a broken fixture.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/private'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIVATE="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}"
  # shellcheck source=../../.local/lib/prompt-render.sh
  . "$REPO_ROOT/.local/lib/prompt-render.sh"
  T="$BATS_TEST_TMPDIR"
}

# conf_key <conf> <key>: the key's value, the conf sourced with HOME spelled `~`.
conf_key() { ( HOME='~'; . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }

# resolve <path> <root>...: a `~/` path's file under the first root that has it, else the path itself.
resolve() {
  local f="$1" r; shift
  [ "${f#\~/}" != "$f" ] || { printf '%s' "$f"; return; }
  for r; do [ -f "$r/${f#\~/}" ] && { printf '%s' "$r/${f#\~/}"; return; }; done
  printf '%s' "$f"
}

# closure <file>: the file and every file it includes, one per line.
closure() {
  local f="$1" inc
  printf '%s\n' "$f"
  grep -o '{{> *[^}]*}}' "$f" | sed -E 's/^\{\{> *//; s/ *\}\}$//' | while IFS= read -r inc; do
    closure "$(dirname "$f")/$inc"
  done
}

# check_confs <conf dir> <root>...: prints one line per fault, and fails when there is one.
check_confs() {
  local dir="$1" c name prompts f path bad=0; shift
  for c in "$dir"/*.conf; do
    name="$(basename "$c" .conf)" prompts="$(conf_key "$c" PROMPT)"
    if [ -z "$prompts" ]; then
      [ -z "$(conf_key "$c" SCORE)" ] || { echo "$name: SCORE=$(conf_key "$c" SCORE) names no PROMPT"; bad=1; }
      continue
    fi
    while IFS= read -r f; do
      path="$(resolve "$f" "$@")"
      [ -f "$path" ] || { echo "$name: PROMPT $f is in no repo"; bad=1; continue; }
      prompt_expand "$path" >/dev/null 2>&1 || { echo "$name: PROMPT $f does not expand: $(prompt_expand "$path" 2>&1 >/dev/null)"; bad=1; }
    done < <(tr ':' '\n' <<<"$prompts")
  done
  return "$bad"
}

# check_sha_moves <file> <root>: on a copy of the file and its includes under <root>, a byte added
# to each one changes the file's prompt_sha. Prints the ones that did not.
check_sha_moves() {
  local top="$1" root="$2" copy="$T/copy" f rel base bad=0
  rm -rf "$copy"
  while IFS= read -r f; do
    rel="$(realpath -m --relative-to="$root" "$f")"
    mkdir -p "$copy/$(dirname "$rel")" && cp "$f" "$copy/$rel"
  done < <(closure "$top")
  rel="$(realpath -m --relative-to="$root" "$top")"
  base="$(prompt_sha "$copy/$rel")" || return 1
  while IFS= read -r f; do
    f="$copy/$(realpath -m --relative-to="$root" "$f")"
    cp "$f" "$f.orig" && printf 'x' >> "$f"
    [ "$(prompt_sha "$copy/$rel")" != "$base" ] || { echo "$rel: a change to $(basename "$f") left its prompt_sha at $base"; bad=1; }
    mv "$f.orig" "$f"
  done < <(closure "$top")
  return "$bad"
}

@test "every scored conf names a PROMPT, and each PROMPT file is in a repo and expands" {
  has_private || skip "no private checkout at $PRIVATE: the live confs are unchecked"
  run check_confs "$PRIVATE/.config/agentctl/agents" "$REPO_ROOT" "$PRIVATE"
  assert_success
}

@test "each live PROMPT file's prompt_sha moves when it or a file it includes changes" {
  has_private || skip "no private checkout at $PRIVATE: the live confs are unchecked"
  local c f path root n=0
  for c in "$PRIVATE"/.config/agentctl/agents/*.conf; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      path="$(resolve "$f" "$REPO_ROOT" "$PRIVATE")"
      root="$REPO_ROOT"; [ "${path#"$PRIVATE"/}" = "$path" ] || root="$PRIVATE"
      run check_sha_moves "$path" "$root"
      assert_success
      n=$((n + 1))
    done < <(conf_key "$c" PROMPT | tr ':' '\n')
  done
  [ "$n" -gt 0 ] || fail "no conf names a PROMPT"
}

@test "negative control: a scored conf with no PROMPT, and a PROMPT in no repo, both fail" {
  mkdir -p "$T/agents" "$T/pub/.config/x" "$T/priv"
  printf 'A {{> rules/r.md}}\n' > "$T/pub/.config/x/p.md"
  printf 'SCORE=s\nPROMPT="$HOME/.config/x/p.md"\n' > "$T/agents/ok.conf"
  run check_confs "$T/agents" "$T/pub" "$T/priv"
  assert_failure
  assert_output --partial 'ok: PROMPT ~/.config/x/p.md does not expand'
  mkdir -p "$T/pub/.config/x/rules" && printf 'rule\n' > "$T/pub/.config/x/rules/r.md"
  run check_confs "$T/agents" "$T/pub" "$T/priv"
  assert_success
  printf 'SCORE=s\n' > "$T/agents/bare.conf"
  printf 'SCORE=s\nPROMPT="$HOME/.config/x/p.md:$HOME/.config/x/gone.md"\n' > "$T/agents/two.conf"
  run check_confs "$T/agents" "$T/pub" "$T/priv"
  assert_failure
  assert_output --partial 'bare: SCORE=s names no PROMPT'
  assert_output --partial 'two: PROMPT ~/.config/x/gone.md is in no repo'
  refute_output --partial 'ok:'
}

@test "negative control: a prompt_sha blind to an included file fails the sha check" {
  mkdir -p "$T/root/.config/x/rules"
  printf 'A {{> rules/r.md}}\n' > "$T/root/.config/x/p.md"
  printf 'rule\n' > "$T/root/.config/x/rules/r.md"
  run check_sha_moves "$T/root/.config/x/p.md" "$T/root"
  assert_success
  prompt_sha() { git hash-object "$1"; }   # hashes the file alone, not its includes
  run check_sha_moves "$T/root/.config/x/p.md" "$T/root"
  assert_failure
  assert_output --partial 'a change to r.md left its prompt_sha'
}
