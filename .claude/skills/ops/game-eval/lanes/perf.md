# Perf lane

Lag, hitches, low fps, GC spikes, server tick. Network feel under load is not this lane: send it to the repo's multiplayer ladder.

## Patterns (read first)

- Per-frame or per-tick work without a reason, where an event or a slower cadence would do.
- Searching the scene (find-by-type, find-by-name) in a hot path instead of a registry or a cached reference.
- Allocation in a loop: boxing enumerators, LINQ, string building, new collections per frame.
- No pooling for things spawned and destroyed often (projectiles, fx, bodies).
- No LOD, culling or cap: far things posed, ticked or drawn as often as near ones; no limit on how many run.
- Work every peer does that only the server needs, or the reverse.
- A one-off budget or quality switch in one system instead of the shared tier knob.
- A hitch from loading, building or spawning on the frame it is needed instead of ahead of it.

## Rule out the harness

Editor overhead (the editor's own loop, inspector, Scene view, an attached profiler, MCP traffic), an unfocused or hidden window (editors throttle), vsync or a frame cap, other heavy jobs on the machine, a debug build. Read the mark's editor share and focus flags first; when the cost is still unclear, the same spot in a player build per the adapter decides it.

## Capture and localize

- Numbers: frame median, p95, max; CPU vs GPU ms; GC per frame; server tick ms and catch-up frames. Two runs a side, same machine and build, against the adapter's per-platform budget.
- CPU: the profiler marker table, children included, largest first.
- GPU: the frame debugger or RenderDoc on desktop; on Quest the `hz-perfetto-debug` / `hz-simpleperf-debug` skills.
- Hitch: the allocation table for the frame plus what spawned or loaded on it.

## Probe

A repeatable measurement of the spot in the repo's probe class (adapter: probe pattern), logging the same numbers, so a fix A/Bs and the next regression shows.

## Row title

`perf: <game>/<spot> <platform>: <symptom> <numbers vs budget>; cause <pattern> (<n> instances); probe <cmd>`

## Review list

Per game: what runs per frame and per tick on each peer; marker coverage of the hot systems; bisect switch coverage; probe numbers against each platform's budget; the patterns above, grepped.

## Prove

Before/after from the probe, two runs a side, into the repo's baseline doc with date, machine and commit.
