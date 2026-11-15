# Debugging adapter contract

A repo that gets debugged often answers these headings in ONE doc, so the `debug` spine never hardcodes a repo's tools. Where it lives: `docs/development/debugging.md` in unity-core-playground; elsewhere the repo's development docs, linked from its CLAUDE.md or docs index. An adapter grows from real need: write a heading's answer the first time a debug session needs it and the repo does not hold it, in that session's PR. Link to the repo's existing docs instead of restating them.

- **Reproduce.** How to run one test or one case, how to write a repro test (which framework, which tier), and how many runs settle an intermittent failure.
- **Live target.** How to tell which copy, process, editor, build or host is the one running, and its commit.
- **Logs.** Where each process writes (editor, player, server, device, CI artifact), per run, and how to pull a remote one.
- **Fast checks.** The quickest way to see compile, type or config errors without a full run.
- **Crashes.** Where crash reports land, and how to symbolicate a native stack (symbol files, tools).
- **Switches.** Verbose logging, runtime toggles that turn a system off, and the build-and-test command a `git bisect run` script wraps.
- **Debugger.** How to attach one to each process kind, if anyone does.
- **Traps.** The repo's gotchas docs and lessons file.
