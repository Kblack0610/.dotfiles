# stack-review: tools per stack

Use only what is installed or declared by the repo. Read-only modes only. Wrap each in `timeout 300`. Missing tools are a Gates finding, not a reason to install something.

## Any stack

| Need | Tool | Read-only invocation |
|---|---|---|
| Size by language | `tokei`, `scc` | `tokei --sort lines`, `scc --by-file -s lines` |
| Largest files | git + wc | `git ls-files -z \| xargs -0 wc -l 2>/dev/null \| sort -rn \| head -25` |
| Copy-paste duplication | `jscpd` | `jscpd --silent --reporters console --min-lines 8 <dirs>` |
| Failing scheduled units | systemd | `systemctl --user --failed`, `systemctl --failed` |
| Dangling symlinks | find | `find . -xtype l -not -path './.git/*'` |
| Referenced-but-missing paths | grep | grep config/units/docs for paths, then `test -e` each |
| CI history | `gh` | `gh run list --limit 30 --json conclusion,name` |
| Time a hot path | `hyperfine`, `time` | `hyperfine --warmup 1 '<cmd>'` against a copy of real data |
| CPU of a scheduled unit | systemd | `journalctl --user -u <unit>` "Consumed" lines; `systemctl --user show -p CPUUsageNSec <unit>` |
| Tracked but not deployed | find + test | for a stow/copy repo, `test -e` each tracked runtime path under the deploy target |

## TypeScript / JavaScript

| Need | Tool |
|---|---|
| Types | `tsc --noEmit` (or the repo's `typecheck` script) |
| Unused files/exports/deps | `knip` |
| Import cycles / boundary rules | `madge --circular`, `dependency-cruiser --validate` |
| Lint | whatever the repo runs (`oxlint`, `eslint`, `biome`) - never introduce a second linter |
| Bundle weight | `vite build --mode analyze`, `next build` output, `source-map-explorer` |
| Duplicate deps | `pnpm why <pkg>`, `syncpack list-mismatches` |

## Rust

| Need | Tool |
|---|---|
| Lints | `cargo clippy --all-targets -- -W clippy::pedantic` (report only the repo-relevant ones) |
| Format drift | `cargo fmt --check` |
| Unused deps | `cargo machete`, `cargo +nightly udeps` |
| Duplicate dep versions | `cargo tree -d` |
| Crate topology | multiple crates with no workspace = separate `target/`, lockfiles, CI runs |

## Shell (bash/zsh/sh)

| Need | Tool |
|---|---|
| Lint | `shellcheck -S warning` (note the repo's configured severity separately) |
| Format | `shfmt -d` |
| Process spawns in loops | grep for `\$\(.*(jq\|sed\|awk\|grep\|python)` inside `while read` loops |
| Unbounded network | grep `curl\|gh \|wget` without `timeout`/`--max-time` on hook/hot paths |
| Repeated helpers | `git ls-files -z '*.sh' \| xargs -0 realpath -e \| sort -u \| xargs grep -hoE '^[a-z_]+\(\)' \| sort \| uniq -c \| sort -rn` - names defined in 3+ files (dedupe by realpath first, or symlinks count twice) |

## Python

| Need | Tool |
|---|---|
| Lint | `ruff check` |
| Dead code | `vulture --min-confidence 80` |
| Types | `mypy` / `pyright` if the repo uses one |
| Import cycles | `pydeps --show-cycles`, `import-linter` |

## Go

| Need | Tool |
|---|---|
| Vet / lint | `go vet ./...`, `staticcheck ./...`, `golangci-lint run` |
| Dead code | `deadcode ./...` |
| Module graph | `go mod graph`, `go mod why` |

## Lua / Neovim

| Need | Tool |
|---|---|
| Format | `stylua --check .` |
| Lint | `luacheck .`, `selene .` |

## Databases / services (when the stack has them)

| Need | Tool |
|---|---|
| Slow queries | `pg_stat_statements` top by total time; ORM query logs on one request for N+1 |
| Missing indexes | `EXPLAIN` on the top queries; FKs without an index |
| Unbounded tables/logs | row counts and growth over time; anything with no TTL or retention |
