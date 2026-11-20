# Changelog

Notable changes to the dotfiles and the agent runtime built on them, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

- This repo has no release tags. Versions are the agent-runtime lab versions (`~/.notes/lab/projects/current/agent-runtime/versions/<v>.md`), rolled by the lab; a heading here is added when the lab rolls one.
- An entry is one line: what changed for a user of the repo, then its board item and PR, as in the commit subject. Refactors and docs-only edits stay out unless they change behavior.
- Before the first entry below, the history is `git log` and the lab version notes.
- The file is in `.stow-local-ignore`, so it never deploys to `$HOME`.

## [Unreleased]

### Changed

- `hub`, `agent-web`: Infra, Machines opens with a Space section, the cluster's cores and memory by class (ci, apps, agents, docker, other, free), and a machine's page lists those classes where it had one OTHER and IDLE lump (ar-3694).
- `agent-queue`: `desk_head` reads queued headers in one pass, halving every hub read over agent-queue (ar-2359, #2254).
- `release-state`: a branch is read from the remote it tracks, so a lagging origin mirror no longer skews it (ar-2575, #2248).

### Fixed

- `agent-queue`, `fleet-sessions`: a `1b.` sub-phase line takes no place in a plan's numbering and `add --plan` skips it, so adding one no longer makes a queued item read another phase as ticked (ar-1277).
- `agent-queue`: `add --plan` reads `(independent; note)` markers and numbers phases by their `P<N>` label, not their place in the list (ar-1850).
- `agent-queue`: `--since` takes `7d` and `7` as days back, never a silent zero (ar-2430, #2258).
- `agent-queue`: `agent-land`'s item step retries a lock timeout (ar-2422, #2257).
- `fleet-sessions`: three false reads from the 2026-11-14 fleet pass (ar-2426, #2259).
- `shepherd`: a misread or missing plan never draws a close nudge (ar-2368, #2252).
- `dispatch`: starved pages an urgent from:human item that a dispatch hold or load keeps waiting (ar-1432, #2246).
- `notes`: a `--backlog` rewrite title over 80 chars moves to a detail line (ar-2207, #2255).
- `views`: the timebox panel key hint fits, so `q close` shows (ar-1784, #2253).
- `agent-web`: a local sign-in key opens the dashboard when Forgejo is down (ar-2357, #2251).
- `bench`: triage retires a `fix(logs)` row once its error stops recurring (ar-727, #2250).

### Security

- A sandboxed lane in a plain clone is denied `.git/commondir` (ar-2581, #2256).
- A sandboxed codex lane can no longer write the git common dir's hooks and config (ar-2528, #2249).
