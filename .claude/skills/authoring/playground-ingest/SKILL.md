---
name: playground-ingest
description: "Bring an Asset Store pack into the BNB asset-library and then into a unity-core-playground game, in the order the repo runbook gives, ending on its Done when list. Use when the user says \"bring this pack in\", \"ingest X into the library\", \"add this asset store pack to the game\", \"make these items usable in <game>\", or after asset-store-audit marked a pack Adopt. It is a thin driver: the procedure lives in the playground's docs/authoring/asset-library.md (Bringing a package in) and the library's docs/ingesting-a-pack.md, and this skill only says where to start, what to read, and which traps have cost sessions hours. Not for deciding whether a pack is worth bringing in (that is asset-store-audit, run it first), not for adding a map or character that uses library art (that is playground-new-content), and not for running tests (that is playground-headless-test)."
metadata:
  category: authoring
  tags: [unity, asset-library, ingest, addressables, playground]
  reviewed: "2026-10-26"
---

# Playground ingest

Takes one downloaded Asset Store pack to a library package a playground game places, with the pin moved forward, the items loadable, and the checks green. The repo docs are the source of truth; when this skill and a doc disagree, the doc wins and this file gets fixed in the same turn.

## When to Use

- When a pack has an Adopt verdict and should become a `com.blacknbrown.lib.*` package.
- When library items exist but a game cannot load them (`InvalidKeyException`, missing from a picker).

Not for judging a pack: that is `asset-store-audit`. Not for a map or character built from library art: that is `playground-new-content`.

## Steps

1. Read the runbook in full before touching anything: `docs/authoring/asset-library.md` "Bringing a package in" (steps 0 to 11, Traps, Done when) in the playground checkout, and `docs/ingesting-a-pack.md` in `External/asset-library`.
2. Step 0 is the audit. If the pack has no `asset-store-audit` verdict yet, run that skill first. A quick shader check needs no Unity: untar the `.unitypackage` and grep each material's `m_Shader` GUID (builtin fileID 211 is `Particles/Standard Unlit`, which ShaderRemap upgrades; a GUID pointing at a `.shader` or `.cfxrshader` inside the pack is a custom shader the ingest does not refuse: its material keeps pointing into `Assets/_Raw` and draws magenta until ShaderRemap maps it, and `tools/lint-package.py` fails the package).
3. Work in a fresh playground worktree (`wt new`), never the main checkout. Check out the library with `scripts/setup/asset-library.sh`, never a bare `git submodule update` (that starts a full LFS copy). The ingest itself runs in a library worktree (`git -C <library> worktree add ~/.worktrees/asset-library-<slug> -b <branch> origin/master`, Library reflinked from the shared checkout). If `worktree add` was interrupted, it leaves the branch and a half-made directory behind: remove the directory, `git worktree prune`, then add on the existing branch.
   - The library compiles against the shared `~/dev/bnb/games/engine/unity-core` checkout by absolute path, not a pin. If that checkout is behind what library master uses, the ingest fails to compile; `git -C <unity-core> pull --ff-only` it while no editor has it open.
   - `EffectProfiles.IngestCli` (and its siblings) rewrite every profile asset on each run, adding new default fields. Revert the profiles you did not touch before committing.
4. Follow the runbook steps in order. The ones sessions skip and pay for later:
   - restart Unity after adding the package to `package.json` before running the ingest CLIs;
   - a recipe or humanoid set change lands in unity-core first, then the relink, in the order the runbook gives;
   - `git lfs push --all origin master` in the library when anything was missing on the remote;
   - `CatalogAddressablesSetup.RefreshCli -catalogs <name>.catalog`, then the ItemLibrary refresh, then rebuild the scene that shows the art;
   - a `-hd` package needs the runner copies refreshed before the manifest PR.
5. Push the library side, then move the pin forward in the playground (`scripts/test/pin-forward.sh origin/main` must pass) and add the manifest line only for packages a game places.
6. Gate and land per playground-headless-test: push, `scripts/test/ci-gate.sh`, its line in the PR body, `gh pr checks <n> --watch`, squash merge.
7. Tick every box in the runbook's Done when, `LibraryContentTests` included (no built-in shader, no Premultiply Lit glass, every item prefab addressable).

## Do NOT

- Do not hand-edit generated scenes, prefabs or Addressables group YAML; rerun the builder or CLI that owns them.
- Do not stage `External/asset-library` from a tree where `asset-library.sh` did not finish cleanly.
- Do not add a package to the manifest that no game places; it costs every runner and every clone.
- Do not restate the runbook here. A step that changed goes into `asset-library.md`, then this list if it is a trap.
