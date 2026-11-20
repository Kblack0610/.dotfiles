# Repo layout

Where things go in a repo: code, tooling, config, tests and docs. A project's own `docs/architecture.md` holds its layout table and the stage check reads it; this doc holds the rules every repo's table is held to. `content is data` (global `CLAUDE.md`) says rosters and tuning live in config; this says where that config lives.

Each rule is one line with its why and its check. `repo-layout-check <repo>` runs the rules marked `tool`, and `systems.md` calls it from a `docs` row, so `project-stage-check <name> --systems --system docs --file` files one story under the project's `epic(docs)` when the row fails. The story names the failing row, not the gaps: run `repo-layout-check <repo>` for the list. A rule marked `review` is read by `stack-review` (3c, structure) and in code review.

## Rules

1. The top level is the stack's code roots, `scripts/` for repo tooling, `config/` for shared data, `docs/`, `tests/` when tests are not colocated, and files whose tool fixes their path (`package.json`, `Packages/manifest.json`, `.github/`, `renovate.json`). Every top-level entry has a row in the layout table. Why: platform's root has 51 entries and nothing says why each is there. Check: tool.
2. `scripts/` (or `tools/`) holds one folder per subsystem and no loose files (a `README` or a dotfile such as `.gitkeep` may sit at the top). Why: the playground's release code is five loose files beside a `release/` folder, and `build.sh` sits beside `build/`. Check: tool.
3. A subsystem folder owns its code, its own config and its tests, so moving or deleting it is one directory. Why: modular means one place to look. Check: review.
4. Config read by more than one subsystem, or by product code, lives in `config/<topic>/`, never in one reader's folder, in `docs/`, or at the root. Product code never reads a path under `scripts/`. Why: `night.json` in the playground's `scripts/`, `docs/operations/perf-budgets.json` read by Unity tests, and `scripts/build/games/*.json` read by 25 files plus `BuildGame.cs`. Check: tool for a config-shaped file (json, yaml, yml, toml, txt, conf) at the top of `scripts/` or `tools/` or anywhere under `docs/`; review for the rest.
5. A roster or set has one file, and code reads that file instead of restating it as a constant. Why: the playground's nightly workflow list lives in five places. Check: review.
6. One test layout per repo, stated in the layout table. Why: the playground has `scripts/test/tests/` plus 15 test files colocated with their code. Check: review.
7. Generated files, locks and runtime state are not tracked. Why: `.notes` tracks `.inbox.lock` and `.wrangler/cache`. Check: not yet.
8. The layout table sits in `docs/architecture.md` under `## Layout`, its first column backticked paths, one row per top-level entry and per `scripts/` or `tools/` subsystem folder. Why: `systems.md` already requires that doc, so this adds no file. Check: tool.

A stow repo such as dotfiles mirrors `$HOME`, so its table documents that tree. Rule 2 applies to a `scripts/` or `tools/` folder only, so a flat `.local/bin` (on PATH) is allowed. A table path may be a shell glob (`*.md`), so one row can cover a family of root files. A project that is a folder of a monorepo is not checked on its own: the monorepo's own project entry is.

## The table

```
## Layout

| Path | Holds |
| --- | --- |
| `scripts/` | Repo tooling, one folder per subsystem |
| `scripts/release/` | Release gate and publish |
| `config/` | Config read by more than one subsystem |
| `docs/` | These docs |
```

`repo-layout-check` matches a tracked top-level entry to a row by its path with the trailing `/` dropped.

## Changing this doc

A new rule cites the failure it prevents in its why, names its check, and the doc stays under 15 rules. A rule a tool checks changes together with `repo-layout-check` and its test, `tests/unit/repo_layout_check.bats`.
