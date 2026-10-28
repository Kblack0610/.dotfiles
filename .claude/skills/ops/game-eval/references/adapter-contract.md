# Adapter contract

Each game repo answers these headings in ONE doc (unity-core-playground: `docs/operations/game-eval.md`), with a section per lane. The skill reads it at step 0; when a heading has no answer yet, that is a finding to file, not a step to skip.

## Shared

- **Platforms:** which ones ship (editor, desktop, Android, Quest, dedicated server) and how to run each.
- **Builds:** how to get a player build cheaply, what must never be built on the shared workstation, who runs device checks.
- **Capture and marks:** how to switch capture on and drop a mark on each platform, and where the files land (editor and device paths, how to pull them).
- **Boards:** the agent board and the human sheet commands for this repo.
- **Standards:** where the repo's rules live.

## Perf section

- Per-platform frame budgets (median and p95 ms, GC per frame, server tick), kept as data.
- Quiet baseline spot per game.
- Profiler markers that exist and where to add new ones.
- Bisect switches (turning a system off at runtime).
- The probe pattern (how to add a repeatable measurement for a spot) and the baseline doc numbers go into.

## Look section

- Reference view per game and how named views are declared.
- How to render a view without playing, at each graphics tier and art set.
- The gallery the shots publish to.
- The look rules (world art direction, UI theme rules) and the docs that hold them.
