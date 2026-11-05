---
name: rigor
description: >-
  Modifier (`/rigor <ask>`, `/rigor /one-shot X`): staff-architect mode. Investigate fully, design modular and reusable for the stated load, nothing sloppy or flaky. Use for "do it properly", "best practices", "no shortcuts". Autonomy is my:go.
metadata:
  category: workstreams
  tags: [modifier, architecture, quality, investigation]
  reviewed: "2026-11-05"
---

# rigor

Work like a staff architect who has to own the result for years. Put `/rigor` in front of an ask or another skill (`/rigor /one-shot <task>`, `/rigor /my:autopilot`). It applies from that turn until the human says to drop it.

Rigor means correct and simple. A design with more layers than the problem needs is as sloppy as one with too few.

The global Core Principles already apply: Simplicity First, One Source of Truth, Subtract First, No sleep-and-hope timing. This skill names them and does not restate them.

## Steps

Do the four stages in order. End each one with its exit line in the reply. A stage you cannot exit is the thing to report.

### 1. Investigate

- Read the real code path end to end before proposing anything. Cite `file:line`, and never reconstruct a function from its name.
- List every reader and writer of what you will touch: callers, configs, tests, docs, dashboards.
- Before you write a fix, grep for the one that already exists one file over.
- For wide scope, use parallel Explore agents. For live systems, use `deep-research-code`. For a failure with an unclear cause, use `root-cause-analyst`.
- Exit line: `verified: ...` and `assumed: ...`, two separate lists.

### 2. Design

- Reuse what is there before you write anything new, and extend the existing pattern before you add a second one.
- Put a module seam where a second real caller or a test needs it, and nowhere else. Depend on interfaces; reaching into another module's internals couples the two.
- State the load as a number (rows, requests, files, sessions), and pick the simplest design that meets it with headroom. Without a number, "scalable" means nothing.
- Content and tuning go in config. Code holds the mechanism and its defaults.
- Name what this replaces and delete it in the same change.
- Exit line: `design: <one sentence>`, `rejected: <alternative> because <cost>`.

### 3. Build

- No N+1 queries, no unbounded loops or reads, no full scans where an index or a lookup exists. Measure before you optimise anything else.
- Validate input and handle errors at boundaries (I/O, network, user input, process exit codes), and fail loudly. Do not add defensive checks for states that cannot happen.
- Make the code deterministic: no timing guesses, no retry or longer timeout that hides a flake, and no reliance on test order or ambient state.
- Keep the diff the size of the problem, and match the surrounding style.
- Exit line: `built: <files>`, plus anything left out and why.

### 4. Verify

- Write a test that fails without the change and passes with it. That is the negative control. Shell and TUI work goes through `shell-test-harness`.
- Run the change on the real surface too: the actual CLI, service or page.
- Run `final-pass`, then `code-review` at high before the PR.
- Exit line: `proved: <command and result>`, `not proved: <what and why>`.

## Do NOT

- Do not abstract for imagined futures: no plugin system for one implementation, no generic framework for one use, no config knob nobody asked for.
- Do not add a shim, fallback or second copy to route around a broken layer. Fix the layer, or say it is blocked.
- Do not mark a flaky test as passing with a retry, a skip or a sleep. Find the race.
- Do not write "should work". Either it was run, or it goes under `not proved`.
- Do not stretch the answer to look thorough. The exit lines are the evidence, so write each one once and concretely.
