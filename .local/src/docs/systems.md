# Project systems

What each part of a project is, and the criteria that say it is built to standard. This is one level below `stages.md`: a stage says how far along the whole project is, and a system says how well one part of it is built.

- A system id is the area of an epic row, as in `epic(ui): live main menus`. Every feature therefore sits under a system, and a project breaks down as project -> system -> feature -> story -> work item -> PR.
- The layers: `base` applies to every project, then the overlay for its type (`game`, `app`, `infra`, from `type` in `project-map.json`, the same field `stages.md` reads). A project's own parts map up to these ids where its code lives. For the games, each playground `systems` id (`match-hud`, `shop`, `world`) carries its system in the playground's `docs/authoring/adding-a-game-systems.md`, and this doc does not list them.
- `project-system-check <name>` (the same as `project-stage-check <name> --systems`) runs the Criteria rows that apply to the project. It prints one line per row and met/total per system. `--system <id>` runs one system, and `--json` prints the counts and each row. It exits 1 when a row FAILs.
- A stage that requires a system calls it from a `stages.md` row (`project-stage-check "$NAME" --system docs`) and does not copy its predicates. A requirement that is only about a stage, such as a CHANGELOG for beta, stays in `stages.md`.

## Systems

| System | Applies | What it is |
| --- | --- | --- |
| ci | base | Build and CI: a clean build from a fresh clone, and the checks every PR runs |
| tests | base | The automated tests and where they run |
| deploy | base | How a build reaches each target, and how it rolls back |
| telemetry | base | Logs, errors, crashes and health signals from running builds |
| docs | base | The README, the architecture doc and the standards a contributor reads first |
| security | base | Secrets, dependencies and who can reach what |
| gameplay | game | The core loop and its content: modes, rules, levels, progression |
| ui | game, app | Screens, menus and HUD: navigation, layout at every size, text |
| input | game | Controls on every supported device, and rebinding |
| netcode | game | Multiplayer: hosting, joining, state sync, authority, the dedicated server |
| save | game | What persists between sessions, and how it survives an update |
| audio | game | Music, effects, the mix and the volume settings |
| perf | game, app | Frame time, load time and memory against a budget on the target hardware |
| look | game | Art direction: style, palette, lighting and effects, one consistent look |
| onboarding | game, app | The first minutes: first-run flow and tutorial |
| store | game, app | Store listings, content rating and release channels |
| auth | app | Sign-in, sessions and roles |
| data | app | Schema, migrations, backups and retention |
| payments | app | Purchases and subscriptions, verified server-side |
| recovery | infra | Rebuilding the host or service from nothing: backups, restore, runbook |

## Criteria

A row's `Applies` narrows it inside its system: a `ui` row for `game` only skips apps. The `Check` cell is written and run exactly as in `stages.md` "Requirements": a backticked shell predicate run from the project's root with `NAME`, `TYPE`, `REPO`, `ROOT` and `LAB` set, `human`, or text naming what checks it today. For a game in the playground, `ROOT` is its folder (`Assets/Games/DodginBalls`), so a row that reads the game's id uses `$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')`.

| System | Applies | Criterion | Check | Why |
| --- | --- | --- | --- | --- |
| ci | base | A CI workflow in the repo runs on every PR | `ls "$REPO"/.github/workflows/*.y*ml "$REPO"/.forgejo/workflows/*.y*ml 2>/dev/null \| grep -q .` | A check that only runs on a laptop is skipped on the day it matters |
| ci | base | The merge gate finishes in minutes; the full suite runs on main or nightly | not yet: needs the forge API (`ci-cost` measures it by hand) | A gate past an hour holds every PR behind it |
| tests | base | Automated tests are in the repo | `git -C "$REPO" ls-files \| grep -Eqi '(^\|/)(tests?\|__tests__\|spec)/\|\.(test\|spec)\.\|Tests?\.cs$'` | Untested code is re-broken by the next change to it |
| tests | game | A play test loads the game and plays a round headless | not yet: `EveryGameLoadsPlayTests` covers the load only | Most game breaks only show once a round is running |
| deploy | base | Deploys are a script or workflow, never hand steps | not yet | A hand step is the one that gets skipped under pressure |
| deploy | base | The deploy doc says how to roll back | `grep -qil rollback docs/operations/*.md "$REPO"/docs/operations/*.md 2>/dev/null` | A rollback first worked out during an outage takes hours |
| telemetry | base | Errors and crashes from running builds reach a place the human reads | not yet | A fault nobody sees is found by a user |
| docs | base | A README with build, run and test | `[ -f README.md ]` | It is the first thing a new contributor or agent reads |
| docs | base | `docs/architecture.md` | `[ -f docs/architecture.md ]` | Without it every session rebuilds the system's shape from the code |
| docs | base | A standards file, or a link to the shared one | `grep -rqil --include='*.md' standards README.md docs` | Review has nothing to hold a change to without one |
| security | base | No secret files are tracked | `git -C "$REPO" rev-parse --git-dir >/dev/null && ! git -C "$REPO" ls-files \| grep -Eq '(^\|/)\.env$\|\.pem$\|\.key$\|id_rsa'` | A committed secret is leaked for good once pushed |
| security | base | A secret scan gates commits or PRs | `grep -rqil -e gitleaks -e trufflehog -e 'secret scan' "$REPO"/.github "$REPO"/.githooks "$REPO"/.pre-commit-config.yaml 2>/dev/null` | People do not spot a token in a diff reliably |
| security | game, app | Dependencies pinned by a lockfile | `ls "$REPO"/pnpm-lock.yaml "$REPO"/package-lock.json "$REPO"/Packages/packages-lock.json "$REPO"/Cargo.lock 2>/dev/null \| grep -q .` | An unpinned dependency changes the build without a commit |
| gameplay | game | A design doc for the game in `docs/games/` | `ls "$REPO"/docs/games/ 2>/dev/null \| grep -qi "^$(basename "$ROOT")"` | The rules must be readable without opening the editor |
| gameplay | game | Tuning numbers live in config files that the code reads | human | Content changes without a code change (content is data) |
| ui | game, app | Every screen works with keyboard and gamepad or touch, no mouse needed | not yet | A screen the controller cannot reach is a dead end on a console or phone |
| ui | game, app | Layouts hold at every supported resolution and aspect | not yet: `ui-audit` checks it by hand | Most UI bugs are a size nobody tried |
| ui | game, app | Player-facing text comes from one table, ready to localise | not yet | Strings spread through code cannot be translated or proofread |
| input | game | Every action works on keyboard and mouse and on a gamepad | human | Players use whichever they have |
| input | game | Bindings can be changed in settings and are kept | not yet | Fixed bindings shut out players with other layouts or needs |
| netcode | game | The dedicated server image is named in the build profile | `jq -e '.image' "$REPO/scripts/build/games/$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]').json"` | Hosting on a player's machine does not scale past friends |
| netcode | game | Plays at 150 ms latency and 2% loss without visible rubber-banding | human | Real players are not on a LAN |
| save | game | Saved data carries a version, and an old save loads after an update | not yet | An update that wipes progress loses the player |
| save | game | A crash mid-save never corrupts the save | not yet | A corrupt save loses more than the session did |
| audio | game | Master, music and effects volumes in settings, kept between runs | not yet | Players mute a game they cannot balance |
| audio | game | Every screen and core action has sound | human | Silence reads as broken |
| perf | game, app | A budget written down per target: frame time, load time, memory | not yet | Without a number, slow is an opinion |
| perf | game, app | A test holds the build to that budget | not yet: per game today (`ApociseumSweepPlayTests`) | A budget nothing checks drifts one change at a time |
| look | game | A look doc names the style, palette and lighting | `ls "$REPO"/docs/games/ 2>/dev/null \| grep -Eqi "^$(basename "$ROOT").*(look\|hd)"` | Without one, every new asset pulls the style a different way |
| look | game | Each area reviewed against it from screenshots | human | Drift is visible only next to the reference (`game-eval`) |
| onboarding | game, app | A new player reaches the core loop without outside help | human | Players who are lost in the first minutes do not come back |
| store | game, app | The listing text and art are kept in the repo | `[ -d "$REPO/store/$(basename "$ROOT" \| tr '[:upper:]' '[:lower:]')" ] \|\| [ -d store ]` | A listing edited only in the console cannot be reviewed or restored |
| auth | app | Sign-in uses the platform's shared auth package, never a copy | not yet | A second auth path is a second set of holes |
| data | app | Schema changes are migrations in the repo | `git -C "$REPO" ls-files \| grep -qi '/migrations/'` | A schema changed by hand cannot be replayed on the next environment |
| data | app | Backups run, and a restore has been done | human | A backup that was never restored is a guess |
| payments | app | Purchases are verified server-side from the store receipt | not yet | A client-only check is free content for anyone with a proxy |
| recovery | infra | A runbook rebuilds it from nothing | not yet | The host dies when the person who built it is away |
| recovery | infra | Backups run, and a restore has been done | human | A backup that was never restored is a guess |

## Changing this doc

A new system needs a row in Systems before any criterion names it; the runner refuses a Criteria row whose system is not in that table. A new criterion cites the failure it prevents in `Why`, as `planning.md` requires, and a system stays under about 15 rows so the list is still read. The `docs` criteria gate the `dev` stage through `stages.md`, so changing them changes that gate.
