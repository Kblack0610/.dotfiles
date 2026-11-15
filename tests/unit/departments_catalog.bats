#!/usr/bin/env bats
# departments.tsv (private overlay, ~/.config/agentctl/) says which runner, workflow, skill,
# exporter or file feeds which department tab of a product page. A row that names a source that
# is gone makes a tab show a pipeline that never runs, so every row is checked against the tree.
# The last test is the negative control: a catalog with bogus sources must be flagged.
# Skipped where the private overlay is absent (public CI); it runs in the Stop fast tier.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIV="${DEPARTMENTS_PRIVATE_REPO:-$HOME/.dotfiles-private}"
  CAT="$PRIV/.config/agentctl/departments.tsv"
  MAP="$PRIV/.config/shared-hooks/project-map.json"
  [ -f "$CAT" ] || skip "no department catalog at $CAT"
  [ -f "$MAP" ] || skip "no project-map.json at $MAP"
}

# Data rows of a catalog file: tab-separated, comments and blank lines dropped.
rows() { awk '!/^#/ && NF' "$1"; }

# The one department list, from the catalog's own "# departments:" line.
departments() { sed -n 's/^# departments: //p' "$CAT"; }

# The checkout of a repo-key (a value of paths in project-map.json); empty when unmapped.
repo_dir() { jq -r --arg k "$1" 'first(.paths | to_entries[] | select(.value == $k) | .key) // empty' "$MAP"; }

# source_state <kind> <source>: ok, missing, or notcloned (a repo the map names but this machine
# has not cloned is not judged, the same rule project-stage-check follows).
source_state() {
  local kind=$1 src=$2 r d f tag path
  case "$kind" in
    runner) [ -f "$PRIV/.config/agentctl/agents/$src.conf" ] && echo ok || echo missing ;;
    skill)
      for r in "$PUB" "$PRIV"; do
        compgen -G "$r/.claude/skills/*/$src/SKILL.md" >/dev/null && { echo ok; return; }
      done
      echo missing ;;
    exporter)
      for r in "$PUB" "$PRIV"; do [ -x "$r/.local/bin/$src" ] && { echo ok; return; }; done
      echo missing ;;
    workflow)
      d=$(repo_dir "${src%%:*}")
      [ -n "$d" ] && [ -d "$d" ] || { echo notcloned; return; }
      f=${src#*:}
      for r in .github/workflows .forgejo/workflows; do [ -f "$d/$r/$f" ] && { echo ok; return; }; done
      echo missing ;;
    file)
      path=${src%%#*}
      tag=
      [ "$path" = "$src" ] || tag=${src#*#}
      case "$path" in
        '~/'*) path="$HOME/${path#\~/}" ;;
        *:*)
          d=$(repo_dir "${path%%:*}")
          [ -n "$d" ] && [ -d "$d" ] || { echo notcloned; return; }
          path="$d/${path#*:}" ;;
        *) echo missing; return ;;
      esac
      compgen -G "$path" >/dev/null || { echo missing; return; }
      [ -z "$tag" ] || grep -qF "\`$tag\`" $path || { echo missing; return; }
      echo ok ;;
    *) echo missing ;;
  esac
}

# missing_rows <catalog>: each row whose source does not exist, as department/source (kind).
missing_rows() {
  local dept src kind proj rec st
  while IFS=$'\t' read -r dept src kind proj rec; do
    st=$(source_state "$kind" "$src")
    [ "$st" = missing ] && printf '%s/%s (%s)\n' "$dept" "$src" "$kind"
  done < <(rows "$1")
  return 0
}

@test "the catalog has a departments line and every row has five fields, none empty" {
  [ -n "$(departments)" ]
  run awk -F'\t' '!/^#/ && NF && (NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "") {print NR": "$0}' "$CAT"
  assert_success
  assert_output ''
}

@test "every row names a listed department, and every listed department has a row" {
  local d have
  have=$(rows "$CAT" | cut -f1 | sort -u)
  for d in $(departments); do grep -qx "$d" <<<"$have" || { echo "no row for $d"; return 1; }; done
  run comm -13 <(tr ' ' '\n' <<<"$(departments)" | sort -u) <(sort -u <<<"$have")
  assert_success
  assert_output ''
}

@test "every row has a known kind" {
  run awk -F'\t' '!/^#/ && NF && $3 !~ /^(runner|workflow|skill|exporter|file)$/ {print NR": "$0}' "$CAT"
  assert_success
  assert_output ''
}

@test "every row's project is * or a project in project-map.json" {
  run comm -23 <(rows "$CAT" | cut -f4 | grep -vx '\*' | sort -u) <(jq -r '.trackers | keys[] | select(startswith("_") | not)' "$MAP" | sort -u)
  assert_success
  assert_output ''
}

@test "no department lists the same source for the same project twice" {
  run bash -c "awk '!/^#/ && NF' '$CAT' | cut -f1,2,4 | sort | uniq -d"
  assert_success
  assert_output ''
}

@test "every named runner, workflow, skill, exporter and file exists" {
  run missing_rows "$CAT"
  assert_success
  assert_output ''
}

@test "the check judges rows: most of the catalog resolves to a real source, not to a skipped repo" {
  local ok=0 total=0 dept src kind proj rec
  while IFS=$'\t' read -r dept src kind proj rec; do
    total=$((total + 1))
    [ "$(source_state "$kind" "$src")" = ok ] && ok=$((ok + 1))
  done < <(rows "$CAT")
  echo "ok $ok of $total" >&2
  [ "$total" -gt 0 ] && [ $((ok * 2)) -gt "$total" ]
}

@test "negative control: a catalog naming sources that do not exist is flagged, row by row" {
  local t="$BATS_TEST_TMPDIR/bogus.tsv"
  cp "$CAT" "$t"
  printf 'analytics\tno-such-runner\trunner\t*\tx\nlegal\tno-such-skill\tskill\t*\tx\nmoney\tno-such-exporter\texporter\t*\tx\nmarketing\tbnb-platform:no-such.yml\tworkflow\t*\tx\nsupport\t~/no/such/file\tfile\t*\tx\nmarketing\t~/.notes/lab/bnb/projects/current/bnb-studios/docs/marketing/pipelines.md#no-such-tag\tfile\t*\tx\n' >>"$t"
  run missing_rows "$t"
  assert_success
  assert_line 'analytics/no-such-runner (runner)'
  assert_line 'legal/no-such-skill (skill)'
  assert_line 'money/no-such-exporter (exporter)'
  assert_line 'support/~/no/such/file (file)'
  # A workflow row is only judged where its repo is cloned.
  [ -d "$(repo_dir bnb-platform)" ] && assert_line 'marketing/bnb-platform:no-such.yml (workflow)'
  assert_line --partial '#no-such-tag (file)'
}
