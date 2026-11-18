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
  PRIV="${DEPARTMENTS_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}"
  CAT="$PRIV/.config/agentctl/departments.tsv"
  MAP="$PRIV/.config/shared-hooks/project-map.json"
  [ -f "$CAT" ] || skip "no department catalog at $CAT"
  [ -f "$MAP" ] || skip "no project-map.json at $MAP"
}

# Data rows of a catalog file: tab-separated, comments and blank lines dropped.
rows() { awk '!/^#/ && NF' "$1"; }

# The one department list, from the catalog's own "# departments:" line.
departments() { sed -n 's/^# departments: //p' "$CAT"; }

# The checkout of a repo-key (a value of paths in project-map.json): the first mapped path that
# is a directory here; empty when unmapped or not cloned.
repo_dir() {
  local p
  while IFS= read -r p; do [ -d "$p" ] && { printf '%s\n' "$p"; return; }; done \
    < <(jq -r --arg k "$1" '.paths | to_entries[] | select(.value == $k) | .key' "$MAP")
  return 0
}

# source_state <kind> <source>: ok, missing, or notcloned (a repo the map names but this machine
# has not cloned, or a ~/.notes path where the notes checkout is absent, is not judged, the same
# rule project-stage-check follows).
source_state() {
  local kind=$1 src=$2 r d f tag path m
  local -a hits
  case "$kind" in
    runner) [ -f "$PRIV/.config/agentctl/agents/$src.conf" ] && echo ok || echo missing ;;
    skill)
      for r in "$PUB" "$PRIV"; do
        compgen -G "$r/.claude/skills/$src/SKILL.md" >/dev/null && { echo ok; return; }
        compgen -G "$r/.claude/skills/*/$src/SKILL.md" >/dev/null && { echo ok; return; }
      done
      echo missing ;;
    exporter)
      for r in "$PUB" "$PRIV"; do [ -x "$r/.local/bin/$src" ] && { echo ok; return; }; done
      echo missing ;;
    workflow)
      d=$(repo_dir "${src%%:*}")
      [ -n "$d" ] || { echo notcloned; return; }
      f=${src#*:}
      for r in .github/workflows .forgejo/workflows; do [ -f "$d/$r/$f" ] && { echo ok; return; }; done
      echo missing ;;
    file)
      path=${src%%#*}
      tag=
      [ "$path" = "$src" ] || tag=${src#*#}
      case "$path" in
        '~/'*)
          case "$path" in '~/.notes/'*) [ -d "$HOME/.notes" ] || { echo notcloned; return; } ;; esac
          path="$HOME/${path#\~/}" ;;
        *:*)
          d=$(repo_dir "${path%%:*}")
          [ -n "$d" ] || { echo notcloned; return; }
          path="$d/${path#*:}" ;;
        *) echo missing; return ;;
      esac
      mapfile -t hits < <(compgen -G "$path")
      [ "${#hits[@]}" -gt 0 ] || { echo missing; return; }
      if [ -n "$tag" ]; then
        for m in "${hits[@]}"; do grep -qF -- "\`$tag\`" "$m" || { echo missing; return; }; done
      fi
      echo ok ;;
    *) echo missing ;;
  esac
}

# Rows of a catalog split on a unit separator, so an empty field stays a field (read with a tab
# IFS collapses consecutive tabs).
rows_us() { rows "$1" | tr '\t' '\037'; }

# missing_rows <catalog>: each row whose source does not exist, as department/source (kind).
missing_rows() {
  local dept src kind proj rec st
  while IFS=$'\037' read -r dept src kind proj rec; do
    st=$(source_state "$kind" "$src")
    [ "$st" = missing ] && printf '%s/%s (%s)\n' "$dept" "$src" "$kind"
  done < <(rows_us "$1")
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
  # The catalog's ~ and repo paths are the account's (ACCOUNT_HOME, helpers/suite_home.bash); read only.
  local HOME="${ACCOUNT_HOME:-$HOME}"
  run missing_rows "$CAT"
  assert_success
  assert_output ''
}

@test "the check judges rows: the catalog does not resolve mostly to skipped repos" {
  local ok=0 skipped=0 total=0 dept src kind proj rec st HOME="${ACCOUNT_HOME:-$HOME}"
  while IFS=$'\037' read -r dept src kind proj rec; do
    total=$((total + 1))
    st=$(source_state "$kind" "$src")
    [ "$st" = ok ] && ok=$((ok + 1))
    [ "$st" = notcloned ] && skipped=$((skipped + 1))
  done < <(rows_us "$CAT")
  echo "ok $ok, not judged $skipped, of $total" >&2
  [ "$total" -gt 0 ]
  [ $((skipped * 2)) -le "$total" ] || skip "most rows name repos not cloned here ($skipped of $total)"
  [ "$ok" -gt 0 ]
}

# The fixture is a tiny tree and project map, so no branch of source_state depends on this
# machine's clones.
@test "negative control: each kind flags a missing source and passes a present one" {
  local fx="$BATS_TEST_TMPDIR/fx" t="$BATS_TEST_TMPDIR/bogus.tsv"
  mkdir -p "$fx/repo/.github/workflows" "$fx/home/.notes" "$fx/priv/.config/agentctl/agents" "$fx/priv/.claude/skills/g/real-skill" "$fx/priv/.local/bin"
  : >"$fx/repo/.github/workflows/real.yml"
  : >"$fx/priv/.config/agentctl/agents/real-runner.conf"
  : >"$fx/priv/.claude/skills/g/real-skill/SKILL.md"
  : >"$fx/priv/.local/bin/real-exporter"; chmod +x "$fx/priv/.local/bin/real-exporter"
  printf 'has `real-tag` here\n' >"$fx/home/.notes/doc.md"
  printf '{"paths":{"%s":"fixture-repo"}}\n' "$fx/repo" >"$fx/map.json"
  MAP="$fx/map.json" PRIV="$fx/priv" PUB="$fx/none" HOME="$fx/home"
  local g b good bad
  good='runner:real-runner skill:real-skill exporter:real-exporter workflow:fixture-repo:real.yml file:~/.notes/doc.md#real-tag file:fixture-repo:.github/workflows/real.yml'
  bad='runner:no-such skill:no-such exporter:no-such workflow:fixture-repo:no-such.yml file:~/.notes/doc.md#no-such-tag file:~/no/such/file file:fixture-repo:no/such'
  for g in $good; do assert_equal "$(source_state "${g%%:*}" "${g#*:}")" ok; done
  for b in $bad; do assert_equal "$(source_state "${b%%:*}" "${b#*:}")" missing; done
  # A repo the map does not give a checkout for, or an absent notes tree, is not judged.
  assert_equal "$(source_state workflow other-repo:x.yml)" notcloned
  rm -rf "$HOME/.notes"
  assert_equal "$(source_state file '~/.notes/doc.md#real-tag')" notcloned
  # missing_rows names the bad rows of a catalog, and only those.
  printf '# departments: analytics\nanalytics\treal-runner\trunner\t*\tx\nanalytics\tno-such-runner\trunner\t*\tx\n' >"$t"
  run missing_rows "$t"
  assert_success
  assert_output 'analytics/no-such-runner (runner)'
}
