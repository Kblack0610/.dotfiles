#!/usr/bin/env bats
# repo-layout-check: the tracked tree of a repo against ~/.local/src/docs/layout.md. Each test
# builds a throwaway git repo. The negative control is the repo the plan describes: a loose
# scripts/night.json and a root entry with no table row, which must fail on both counts.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/.local/bin/repo-layout-check"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/docs" "$R/scripts/release" "$R/config"
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  cat > "$R/docs/architecture.md" <<'DOC'
# Architecture

## Layout

| Path | Holds |
| --- | --- |
| `scripts/` | Repo tooling |
| `scripts/release/` | Release gate |
| `config/` | Shared config |
| `docs/` | Docs |
| `*.md` | Root docs |
| `.github/` | CI |

## Other

| `bogus/` | not in the Layout section |
DOC
  echo go > "$R/scripts/release/gate.sh"
  echo '{}' > "$R/config/nightly.json"
  echo hi > "$R/README.md"
  mkdir -p "$R/.github"; echo x > "$R/.github/ci.yml"
}

commit() { git -C "$R" add -A && git -C "$R" commit -qm c; }

@test "a grouped repo with a full table passes" {
  commit
  run "$SUBJECT" "$R"
  assert_success
  assert_output ''
}

@test "NEGATIVE CONTROL: a loose scripts/night.json and an unlisted root entry both fail" {
  echo '{}' > "$R/scripts/night.json"
  mkdir "$R/extras"; echo x > "$R/extras/a"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "config file 'scripts/night.json' at the top of scripts/"
  assert_output --partial "top-level entry 'extras' has no row"
}

@test "a loose non-config script at the top of scripts/ fails, a subsystem file does not" {
  echo go > "$R/scripts/build.sh"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "loose file 'scripts/build.sh'"
  refute_output --partial "gate.sh"
}

@test "tools/ is held to the same rule as scripts/" {
  mkdir "$R/tools"; echo go > "$R/tools/x.sh"
  sed -i 's#^| `config/`#| `tools/` | Tooling |\n| `config/`#' "$R/docs/architecture.md"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "loose file 'tools/x.sh'"
}

@test "a config-shaped file under docs/ fails" {
  echo '{}' > "$R/docs/perf-budgets.json"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "config file 'docs/perf-budgets.json' under docs/"
}

@test "a table row outside the Layout section does not count" {
  mkdir "$R/bogus"; echo x > "$R/bogus/a"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "top-level entry 'bogus' has no row"
}

@test "a repo with no architecture doc fails once, naming the table" {
  git -C "$R" rm -qf docs/architecture.md 2>/dev/null || rm "$R/docs/architecture.md"
  commit
  run "$SUBJECT" "$R"
  assert_failure 1
  assert_output --partial "no layout table"
  refute_output --partial "has no row"
}

@test "--ref reads the tree at that rev, not the working tree" {
  commit
  mkdir "$R/extras"; echo x > "$R/extras/a"; git -C "$R" add -A
  run "$SUBJECT" "$R"
  assert_failure 1
  run "$SUBJECT" --ref HEAD "$R"
  assert_success
}

@test "a path that is not a git repo exits 2" {
  run "$SUBJECT" "$BATS_TEST_TMPDIR"
  assert_failure 2
}
