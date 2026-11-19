#!/usr/bin/env bats
# One writer for the sheets (ar-3684): no script, hook, lib, skill or tool in either dotfiles repo
# writes a lab task sheet (`<project>/README.md`, `agent/README.md`) or the outbox (`outbox.md`)
# except through `notes`, whose writer gate decides what a session may file. A redirect, tee, mv or
# cp onto one, an in-place edit, or a python open for writing is a second writer that skips it.
# notes-cli itself and test fixtures are out of scope; the private repo is scanned when checked out.

# Not a sheet, though the path matches: flow-review writes its report as <lab>/docs/reviews/<slug>/README.md.
ALLOWED='\.claude/skills/authoring/flow-review/scripts/extract-artifact\.py:'

# sheet_writes <dir...>: every line under those dirs that writes a sheet path, as file:line:text.
sheet_writes() {
  local f='(README|outbox)\.md' v='\$\{?(sheet|SHEET|board|BOARD|board_file|BOARD_FILE|outbox|OUTBOX|human_sheet|agent_board)\b'
  LC_ALL=C.UTF-8 grep -rnIE --exclude-dir=.git --exclude-dir=tests --exclude-dir=notes-cli --exclude-dir=target \
    --exclude-dir=node_modules --exclude='*.bats' \
    -e "(^|[[:space:]])[0-9]?>>?[[:space:]]*\"?[^ |;&)]*$f" \
    -e "tee( -a)?[[:space:]]+\"?[^ |;&)]*$f" \
    -e "(mv|cp)( -f)?[[:space:]]+[^|;&]*$f\"?[[:space:]]*(\)|;|&|$)" \
    -e "\b(sed|perl|awk|ed|sponge)\b[^|;]*(-[a-zA-Z]*i\b|inplace)[^|;]*$f" \
    -e "open\(.*$f.*,[[:space:]]*[\"'][wa]" \
    -e "$f[^#]*\.write_text\(" \
    -e "(^|[[:space:]])[0-9]?>>?[[:space:]]*\"?$v" \
    -e "(tee( -a)?|sed -i[^ ]*( [^ |;]+)*)[[:space:]]+\"?$v" \
    "$@" 2>/dev/null
}

roots() {
  local root private
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  private="${DOTFILES_PRIVATE:-${ACCOUNT_HOME:-$HOME}/.dotfiles-private}"
  for r in "$root" "$private"; do
    for d in .claude .config .local/bin .local/lib .local/src; do
      [ -d "$r/$d" ] && echo "$r/$d"
    done
  done
}

@test "nothing in either repo writes a sheet or the outbox but notes" {
  mapfile -t dirs < <(roots)
  [ "${#dirs[@]}" -gt 0 ]
  run bash -c "$(declare -f sheet_writes); sheet_writes $(printf '%q ' "${dirs[@]}") | grep -vE '$ALLOWED'"
  [ -z "$output" ] || { echo "write these through notes (ptask add/edit, outbox add/put), or list why here:" >&2; echo "$output" >&2; return 1; }
}

@test "NEGATIVE CONTROL: each way of writing a sheet is caught, and a read is not" {
  d="$BATS_TEST_TMPDIR/src/.local/bin"
  mkdir -p "$d"
  cat >"$d/writer" <<'EOF'
printf '# x\n' > "$proj_dir/README.md"
echo "- [ ] x" >> "$vault/outbox.md"
sed -i 's/a/b/' "$lab/agent/README.md"
echo x | tee -a "$dir/agent/README.md"
mv "$tmp" "$proj/README.md"
open(os.path.join(lab, "README.md"), "w")
printf '%s\n' "$row" >> "$sheet"
EOF
  cat >"$d/reader" <<'EOF'
grep -c '^- \[ \]' "$proj_dir/README.md"
[ -f "$lab/agent/README.md" ] && cat "$vault/outbox.md" > /dev/null
open(os.path.join(lab, "README.md")).read()
EOF
  run sheet_writes "$d"
  [ "$(grep -c '/writer:' <<<"$output")" -eq 7 ] || { echo "$output" >&2; return 1; }
  ! grep -q '/reader:' <<<"$output"
}
