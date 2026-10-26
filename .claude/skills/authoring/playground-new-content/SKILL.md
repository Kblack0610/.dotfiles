---
name: playground-new-content
description: "Add a new map, character (player body family, enemy, boss, story person, townsfolk) or game to unity-core-playground by its authoring guide, ending on the guide's Done when list. Use when the user says \"add a map\", \"new level\", \"build out a new area\", \"add an enemy / boss / NPC / talker\", \"new playable body\", \"add a new game or mode\", or \"level design for X\". It is a thin driver: the procedure lives in the playground's docs/authoring/ guides (adding-a-map.md, adding-a-character.md, adding-a-game.md) and docs/development/standards.md, and this skill says which guide, what to read first, and the rules that most often get broken. Not for bringing new art into the library (that is playground-ingest) and not for running tests (that is playground-headless-test)."
metadata:
  category: authoring
  tags: [unity, level-design, characters, playground, authoring]
  reviewed: "2026-10-26"
---

# Playground new content

Gets a new map, character or game into the playground the way the repo's guides and standards require, so it passes the tests that check them on the first gate. The guides are the source of truth; when this file and a guide disagree, the guide wins and this file gets fixed in the same turn.

## When to Use

- When adding a map or level (greybox or HD, a venue, a dungeon or seeded level).
- When adding a player body family, an enemy, a boss, a story person or townsfolk.
- When adding a new game or a mode inside one.

Not for new art from the Asset Store: that is `playground-ingest`, and it comes first.

## Steps

1. Read, in the playground checkout: `docs/development/standards.md` and unity-core's `docs/standards.md`, then the guide for the job:
   - a map: `docs/authoring/adding-a-map.md` (Steps, Naming, Budgets, Bots and navigation, Done when);
   - a character: `docs/authoring/adding-a-character.md` (the section for its kind, then Done when);
   - a game or mode: `docs/authoring/adding-a-game.md`, then the map guide for its scene.
2. Work in a fresh worktree (`wt new`), cut from `origin/main`.
3. Follow the guide's steps in order, through the builders and CLIs it names. The rules that most often get broken:
   - scenes, `_boot` UI and player prefabs are generated from code; change the builder, never the YAML;
   - an HD map's greybox is derived from it (`DeriveGreyboxesCli`, `SetProxy`), never laid out by hand;
   - a grown humanoid is 1.8 m by 0.6 m and its family's `modelHeight` matches `CapsuleHeight`;
   - a new game's player is POLYGON, other bodies come through `bodiesFrom`;
   - an encounter's enemies are an `EnemyPack`; a game's people and set pieces sit under its own `[Game <game>]` root;
   - a game with more than one fight at once names a `scale` preset; bots route only around box colliders;
   - every feature is networked from the first cut, and animation is never networked;
   - a gameplay rule change ships behind a per-game JSON switch, off by default.
4. Write the doc for what you added (games in `docs/games/<game>.md`, with an Over MCP section if it can be driven), a row in the games table, and at most one row in CLAUDE.md's MCP table.
5. Gate and land per playground-headless-test, then tick the guide's Done when list in the PR body.

## Do NOT

- Do not start from a solo prototype; there is no un-networked first cut.
- Do not invent budgets or naming; use what the guide lists, and add a measured number to the guide when you set one.
- Do not restate a guide here. A step that changed goes into the guide.
