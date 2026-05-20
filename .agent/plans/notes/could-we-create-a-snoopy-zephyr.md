# Pacman Game for SWAS

## Context

SWAS is a multi-screen MQTT-synchronized experience platform. Currently all experiences are video-based (controller selects a story → webviewer plays videos). This adds a Pacman game as a new interactive experience:

- **Controller screen** — 4 directional arrow buttons (+ Start/Pause). Publishes real-time input via MQTT.
- **Game screen** (webviewer) — renders classic Pacman: maze, dots, power pellets, 4 ghosts, score/lives. Receives direction input and game control messages via MQTT.

This is a standalone addition — nothing in the existing experience pipeline is modified.

---

## Architecture Decisions

| Question | Decision |
|---|---|
| MQTT topology | Single topic `swas/pacman-game`, two message types discriminated by `type: 'direction' \| 'control'` |
| Controller | New `pacmanController` type in existing controller app (reuses MQTT infra) |
| WebViewer | Early-return branch in `App.tsx` for `receiver.name === 'pacmanGame'` — clean isolation, zero risk to existing receivers |
| Game rendering | HTML5 Canvas with a pure-TS game engine (no DOM coupling, testable in isolation) |
| Game loop | `setInterval` at 10 Hz for game ticks; `requestAnimationFrame` at 60fps for canvas draw |

---

## MQTT Message Schema

```typescript
// Topic: swas/pacman-game (bidirectional — controller publishes, webviewer subscribes)

type PacmanDirection = 'up' | 'down' | 'left' | 'right';

interface PacmanDirectionMessage {
  type: 'direction';
  direction: PacmanDirection;
  messageId: string;   // uuid, for dedup
  timestamp: number;   // Date.now() on controller
}

interface PacmanControlMessage {
  type: 'control';
  action: 'start' | 'pause' | 'resume' | 'reset';
  messageId: string;
  timestamp: number;
}
```

---

## Files to Create

### WebViewer

| File | Description |
|---|---|
| `client/webviewer/src/game/pacmanTypes.ts` | Shared TS types: GameState, Ghost, Cell enum, PacmanDirection |
| `client/webviewer/src/game/pacmanMaze.ts` | Classic 28×31 maze as a `Cell[][]` constant; `CELL_SIZE = 24` |
| `client/webviewer/src/game/pacmanEngine.ts` | Pure functions: `createInitialState()`, `tick(state, dir)`, `applyControl(state, action)` |
| `client/webviewer/src/game/pacmanRenderer.ts` | Pure canvas draw: `drawFrame(ctx, state, maze)` — walls, dots, Pacman, ghosts, HUD |
| `client/webviewer/src/hooks/usePacmanMQTT.ts` | Subscribes to `swas/pacman-game`; returns `{ direction, controlAction }` |
| `client/webviewer/src/components/PacmanGame.tsx` | Canvas component — owns rAF loop, 10Hz game tick, forwards props into engine |
| `client/webviewer/src/components/PacmanGameApp.tsx` | Top-level for pacmanGame receiver: calls `usePacmanMQTT`, renders `<PacmanGame>` |

### Controller

| File | Description |
|---|---|
| `client/controller/src/contexts/PacmanContext.tsx` | Wraps MQTT publish: `publishDirection(dir)`, `publishControl(action)`, local `gameStatus` |
| `client/controller/src/components/PacmanController.tsx` | UI: fullscreen dark bg, 3×3 D-pad grid, Start/Pause/Reset at top. `onPointerDown` fires immediately + repeats at 100ms while held |
| `client/controller/src/routes/PacmanPage.tsx` | Route wrapper for `<PacmanController>` |

---

## Files to Modify

### Config (append-only, zero risk)

**`client/controller/controllers.config.json`** — add:
```json
{ "name": "pacmanController", "buildName": "pacmanController", "station": "pacman-game", "type": "brightSignPlayer" }
```

**`client/webviewer/receivers.config.json`** — add:
```json
{ "name": "pacmanGame", "station": "pacman-game", "type": "brightSignPlayer", "resolution": "1920x1080" }
```

### Code Changes (minimal, localized)

**`client/webviewer/src/App.tsx`** — add 3-line early-return after `receiver` is resolved (~line 190):
```tsx
if (receiver.name === 'pacmanGame') return <PacmanGameApp />;
```

**`client/controller/src/App.tsx`** — add routing branch for `pacmanController` (mirrors existing branch pattern):
```tsx
if (controller.name === 'pacmanController') {
  return <Route path="/" element={<PacmanPage />} errorElement={<RouteErrorBoundary />} />;
}
```

**`client/controller/package.json`** + **`client/webviewer/package.json`** — add `dev:pacman` convenience scripts.

---

## Pacman Game Design

- **Maze**: Classic 28×31 grid, canvas 672×744px, CSS-scaled to fill viewport
- **Pacman**: Grid-aligned movement, 10 cells/sec, mouth animation on each tick
- **Ghosts (4)**: Blinky (red/chase), Pinky (pink/4-ahead), Inky (cyan/vector), Clyde (orange/scatter-if-close)
- **Ghost AI**: At each aligned tile, pick direction minimizing Manhattan distance to target. No reversing. Frightened = random.
- **Scoring**: Dot = 10pts, Power Pellet = 50pts, Ghost = 200/400/800/1600pts chain
- **Lives**: 3. Game over → idle screen awaiting `start` command
- **Win**: All dots eaten → level + 1, maze reset, ghosts speed up slightly

---

## Implementation Sequence

1. Config entries (controllers.config.json, receivers.config.json)
2. `pacmanTypes.ts` + `pacmanMaze.ts` — data only
3. `pacmanEngine.ts` — pure logic, verify with console tests
4. `pacmanRenderer.ts` — canvas drawing
5. `PacmanGame.tsx` + `PacmanGameApp.tsx`
6. `usePacmanMQTT.ts`
7. `App.tsx` 3-line change (webviewer) — last webviewer touch
8. `PacmanContext.tsx` + `PacmanController.tsx` + `PacmanPage.tsx`
9. `App.tsx` routing branch (controller)
10. Dev script shortcuts

---

## Verification

1. Start broker + `dev:pacman` scripts for both controller and webviewer
2. Open webviewer on `localhost` → should show idle Pacman screen (maze, "Press START") ✅
3. Open controller on another tab/device → should show 4-arrow D-pad + Start button ✅
4. Press Start → Pacman begin animation, ghost movement starts ✅
5. Press arrow buttons → Pacman changes direction ✅
6. Verify direction delay feels real-time (< 50ms on LAN) ✅
7. Eat power pellet → ghosts go blue, eating ghost scores chain ✅
8. Lose all lives → "Game Over" screen, Start restarts ✅
9. Confirm no existing experience is affected (open signatureWallController, verify stories still work) ✅

## Phase 2 — Wall Simulation (COMPLETED)

Wall-shaped maze with physical device positions as obstacles:
- Canvas: 2048×1024 (12ft) or 3872×1024 (20ft), exact wall resolution
- Cell size: 32px → 64×32 grid (12ft) or 121×32 grid (20ft)
- Device regions derived from `product-video-names.png` pixel analysis
- Ghost house in open corridor between the two large TVs
- Controller preview panel (static SVG) shows 12ft WALL LAYOUT with device zones

### Files added/changed:
- `client/webviewer/src/game/pacmanTypes.ts` — Added `WallSize`, `MazeConfig`
- `client/webviewer/src/game/wallMaze.ts` — Wall maze generator (new)
- `client/webviewer/src/game/pacmanEngine.ts` — Threaded `MazeConfig` through all functions
- `client/webviewer/src/game/pacmanRenderer.ts` — Uses `MazeConfig` for dimensions/cell size
- `client/webviewer/src/components/PacmanGame.tsx` — Uses wall maze by default
- `client/controller/src/types/wallLayout.ts` — Device zone data for controller preview (new)
- `client/controller/src/components/PacmanController.tsx` — Added wall preview SVG

### Phase 3 (future): Controller live state preview
Webviewer publishes `swas/pacman-state` topic every 3 ticks with Pacman/ghost positions. Controller subscribes and renders live mini-map overlay on the wall preview.

---

## Safety Notes

- Early-return guard prevents `attractorVideo: undefined` crash if `pacmanGame` ever ran existing video pipeline
- Pacman receiver has no `attractorVideo` field — safe because it never enters the video code path
- All new files are additive; no shared utilities modified
- `pacmanEngine.ts` uses immutable state (returns new object each tick) — no side effects to debug
