# Look lane

Style, design and look of game worlds and UI: lighting, art direction, consistency, scale, how each graphics tier holds up, and whether menus and HUDs follow the theme.

## Patterns (read first)

- A game with no written taste, or a `Draft` taste no one corrected: every review then grades against someone's guess.
- Set dressing, sky or a prop out-contrasting or out-saturating the players, threats and pickups.
- Raw colours and sizes in UI instead of the theme's tokens; a page keeping its own copy of a shared widget.
- Fixed pixel sizes where the layout should flex; text that drops below the type scale at small sizes.
- Materials upgraded from a legacy shader drawing wrong in the current pipeline (white or black squares, wrong transparency).
- Two art sets on one screen (low poly beside realistic, two body families in one crowd) without a reason.
- A grade, fog or sky set by hand in one scene that the game's shared look settings should carry.
- A tier cutting something the game's look depends on (bloom, shadows, fog, foliage), or the top tier adding nothing.
- Scale off against the project's world scale (doors, steps, props, characters).
- Lighting that hides the play space: unreadable silhouettes, flat ambient, no contrast between walkable and blocked.

## Rule out the harness

Graphics tier and art set (HD on or off), an editor still compiling shaders (renders black or unlit), unbaked lighting, a debug overlay, a camera that is not the player's. Compare against the game's reference view at the same tier before calling it a look problem.

## Capture and localize

- Shots: the spot's named view at the lowest and the default tier (and the HD set where installed), beside the game's reference view, never a single shot.
- Localize to the layer that owns it: scene art, material or shader, the game's look settings, the sky, the tier, the body or crowd set, a UI rule.
- Draw cost of the view (renderers, materials, triangles) goes beside the shot; a view that looks right but costs too much is a perf-lane row.

## Probe

A named view in the game's data (adapter: how views are declared), so the gallery shoots it on every refresh and a regression shows as a changed picture.

## Row title

`look: <game>/<view>: <issue>; cause <pattern> (<n> instances); view <name>`

Taste calls (which direction a game's look should go) are the human's: put the shots and the options on one human-sheet row, do not pick for them.

## Review list

Per game: every named view at the lowest and default tier, graded against the game's taste and each of the repo's review tests (pass, drift or fail, with a one-line reason and the rule it breaks); the reference view against the game's look settings; art-set mix; scale; the UI gallery against the repo's UI rules. The pass is not done until every view has a grade: a table of view x test in the report, and each fail filed as a row.

## Prove

Before/after shots of the same view and tier in the PR body, and the refreshed gallery link after merge.
