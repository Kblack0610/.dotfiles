---
name: shell-test-harness
description: Test a shell or TUI surface in this repo correctly, then land it. Covers the three-tier bats suite in `tests/` (unit = sourced functions, integ = the `$SELF --verb` contract, ui = a REAL tmux server), the hard rule that anything starting a real server/daemon runs ONLY in the disposable container, the mandatory negative control (a test that cannot fail is not a test), and the pre-flight checks that stop you clobbering a concurrent session. Use when adding or changing any script under `.local/src/tmux/`, `.local/bin/`, `.config/shared-hooks/`, or a stop-hook check; when asked to "add tests for X", "is X tested", "harness this", "make sure this is tested properly"; or before landing shell work. Do NOT run the ui tier on this machine (it starts real tmux servers and has destroyed live sessions), do NOT trust `TMUX_TMPDIR` or `command tmux` as isolation, do NOT let a gate report success on an empty input list, and do NOT claim a test works until you have watched it fail. Hands landing off to ingest-worktree (fan a dirty tree into PRs) and dotfiles-land (public/private routing).
metadata:
  category: authoring
  tags: [testing, shell, bats, dotfiles]
  reviewed: "2026-07-27"
---

# shell-test-harness

How shell work gets tested and landed in this repo. The suite lives in `tests/`; this is the procedure around it.

The founding incident: writing the tmux UI tests destroyed every live tmux session on this machine, twice in one evening. Not because the test code was careless, but because the tests could *reach* the user's sessions at all. Everything below follows from that.

```
    pick a tier  ->  write the test  ->  WATCH IT FAIL  ->  run the gates  ->  land
                          |                    |
                   host-safe or          negative control
                   container-only?         (not optional)
```

## 0. Pre-flight: are you alone in this checkout?

Several agent sessions share `~/.dotfiles`. Skipping this has already cost a session's work.

```bash
git worktree list          # another session's worktree? a `+` marks a checked-out branch
git branch --show-current  # are you even on the branch you think?
git status --short         # is this dirt yours?
git fetch origin && git log --oneline HEAD..origin/main   # how stale are you?
```

If the shared checkout is busy, or you are about to make a multi-step change, **take a worktree** (the convention other sessions already follow):

```bash
wt new                    # cuts it under ~/.worktrees/, opens a tmux session, lands you there
```

Every worktree lives flat under `~/.worktrees/<repo>-<slug>` - never in `$SCRATCH`, never nested in the repo. If you need raw git rather than `wt`, keep the location and fetch first:

```bash
git fetch origin && git worktree add ~/.worktrees/dotfiles-<name> -b pr/<name> origin/main
```

Restore anything you touched in the shared tree **before** leaving it. Re-`fetch` immediately before each landing step, not once at the start - `origin/main` moved three times during one session, and two planned PRs turned out to be work someone else had already landed. `wt done` from inside the worktree reaps it when the work has landed.

Container caveat: inside a worktree `.git` is a *file* pointing at the main repo, so `tests/docker.sh` mounts the main `.git` read-only. That is already handled; do not fight it.

## 1. Pick a tier

| Tier | What it tests | Runs where | Cost |
|---|---|---|---|
| `unit` | sourced functions, no subprocess | anywhere | ~1s |
| `integ` | the `$SELF --verb` contract, as a subprocess, against stub CLIs | anywhere | ~3s |
| `ui` | a REAL tmux server, real keystrokes, rendered screen | **container only** | ~20s |

Choose by what the thing under test *is*:

- **Pure logic** (parse a row, map a tag to an option, classify a pane) -> `unit`. Needs a source guard in the subject: `[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0` above the dispatch. Add it if missing.
- **A verb's output shape** (`--list` emits 7 tab-separated fields; `--task-op done` shells out to the right command) -> `integ`, using the stubs in `tests/helpers/stubs/`.
- **State that IS tmux state** (a window option, a session's existence, what a keypress renders) -> `ui`. There is nothing to assert against a stub here: faking `set-option`/`show-options` only tests the fake.

Prefer the cheapest tier that can actually fail. The suite caught a real routing bug in a 40ms unit test.

## 2. THE CONTAINER RULE

**Anything that starts a real server, daemon, or long-lived process runs only inside `tests/Dockerfile`'s image. Never on this machine.**

`require_disposable_host()` enforces it: it **fails** (never skips - a skip is how a safety tier quietly stops running) unless `/.dockerenv` *and* an image-set env marker are both present. There is deliberately **no override flag**.

```bash
make -C tests test-fast     # unit + integ, host-safe, what the Stop hook gates on
make -C tests test-ui       # delegates to docker.sh; never invokes tmux on the host
tests/docker.sh test-container   # everything, in the container
tests/docker.sh lint            # the lint gate, same one CI runs
tests/docker.sh --shell         # interactive shell in the image, for debugging
```

Two "isolation" mechanisms that **do not work** - verified on tmux 3.7b, do not re-derive:

- `TMUX_TMPDIR=<sandbox>` is **ignored whenever `$TMUX` is set** (i.e. whenever you are inside tmux, which is exactly when you work on tmux scripts), and silently falls back to `/tmp` if the directory does not exist.
- `command tmux` still honours `PATH`, so it finds a stub instead of bypassing one.

Only an explicit `-S <path>` / `-L <name>` **flag** isolates a tmux server. That is why the harness installs a PATH shim pinning `-S` (`tmux_shim`) - it covers the *subject's* bare `tmux` calls too, which is the only way to test a script that must keep calling `tmux` plainly.

Exception, and the only one: a subject whose whole job is managing several servers (`servers.sh`) must keep calling `tmux -L` itself. Use `tmux_passthrough_shim`; isolation is then `TMUX_TMPDIR` **plus** the container, which is sound there because the container has no `$TMUX` and nothing to lose. Never on a real machine.

**Never execute a destructive command to verify the guard that prevents it.** Assert on the guard's *decision* (make it print what it would do), not the outcome of doing it. Running `tmux kill-server` to check whether it was safe to run `tmux kill-server` is what caused the second outage.

## 3. Write the negative control. Not optional.

A test that has never failed is a guess. For every behaviour you claim to cover, break the subject and confirm the test notices:

```bash
cp <subject> /tmp/x.bak
trap 'cp /tmp/x.bak <subject>' EXIT      # restore even if you bail
# invert a binding / transpose two verbs / drop a field / rename a constant
<run the tier>                            # it MUST fail, and name the right thing
```

This is not ceremony. Real results from doing it:

- 7 direction assertions were **passing while asserting nothing** - the fixture had 2 sections, so `next` and `prev` were the same operation. Fixed by adding a third and asserting the *exact* landing element.
- Inverting `h`/`l` -> 3 ui tests fail. Transposing the section verbs -> 4 integ tests fail in 53ms. Dropping a wire-format field -> 17 tests fail. Collapsing every tmux world onto one socket -> 10 ui tests fail.

**Rule of three for anything cyclic or ordered**: a fixture needs 3 or more elements, and the assertion must name the expected element. With 2, forwards and backwards are indistinguishable.

## 4. Gate hygiene: silence is not success

Every failure mode in this repo's tooling has been *silent success*. Watch for it:

- A gate that derives its input list at runtime must treat an **empty list as failure**. `tests/lint.sh` once reported "clean" having checked zero files, because `git ls-files` failed. "Nothing to check" and "everything passed" print the same green.
- A **skip** in a safety tier is how it quietly stops running. Fail instead.
- After writing a config key, **prove something reads it** - change the value and observe different behaviour. `severity=` in `.shellcheckrc` is silently ignored (it is CLI-only), so the lint gate looked configured while every warning still failed the run.
- Any suite driving an interactive tool needs a **wall-clock cap** (`UI_TIMEOUT`). bats has no per-test timeout, and a test that reaches an attach path (`tmux attach` with no terminal) blocks *forever* rather than failing - one wedged a run for 10 minutes and reported nothing.
- Before asserting "unknown verb is rejected", read the dispatch's **default arm**. A catch-all that treats the word as *data* is not an error path: in `tmx` a bare word is a server name, so `tmx not-a-verb` is a valid request that attaches and hangs.

## 5. Run the gates

```bash
make -C tests test-fast        # the Stop hook runs this; must be green
tests/docker.sh test-container # all tiers
tests/docker.sh lint           # shellcheck at the current ratchet + shfmt (advisory)
```

The lint ratchet lives in `tests/lint.sh` (`SEVERITY`, currently `error`), shared by make, the Stop hook and CI so a local green cannot mean a CI red. Move it one notch per PR - `error -> warning -> info -> style` - and re-measure before each step; do not jump to `style`, that is a permanently red check nobody reads.

CI (`.github/workflows/tests.yml`): `fast` on the runner, `ui` in the same image you used locally, `lint` likewise, plus a weekly tmux-version drift sweep. `push` is restricted to `main` on purpose - `branches: ['**']` makes every job run twice.

## 6. Land it

One concern per PR. Hand off rather than improvising:

- **`ingest-worktree`** - fan a mixed dirty tree into scoped PRs.
- **`dotfiles-land`** - decide public `~/.dotfiles` vs private `~/.dotfiles-private` (`git check-ignore` decides; a cross-repo change is two PRs).
- **`gh-workflows`** - PR mechanics.

Then update the durable layer, which is not optional either: a lesson in `~/.agent/lessons/{project}.md` for anything a future session would otherwise re-derive, and this SKILL.md when the procedure itself changed. A lesson records what happened; the skill is what the next run actually reads - patch the source, not just the diary.

## Coverage: aim at risk, not at line count

Coverage that ignores blast radius is theatre. Rank by what a bug *does*:

1. Scripts that **delete** things (`wind-down.sh`, and any future reaper) and whatever they consult to decide what to spare. `cockpit.sh stale` is the counter-example worth copying: it finds dead windows and deliberately only REPORTS, printing the `kill-window` command instead of running it, because a false positive there costs a scrollback nobody can recover.
2. Scripts whose purpose **is** a safety property (`servers.sh` - the socket split bounds a kill's blast radius; assert it, do not leave it as a comment).
3. Everything the user touches daily.
4. The rest.

A guard that **fails open** deserves a test pinning its vocabulary to a literal. `tmux-tags protected` reads window options; `has_tag` on a missing option is simply false, so any drift between the tag a user sets and the option the guard reads means a pinned window is reaped anyway, on a timer, with no error.

## Boundaries

- Never run the `ui` tier, or any real-server test, outside the container. No override flag exists; do not add one.
- Never `git checkout-index -a -f` to "tidy up" - it overwrites the working tree from the index and destroys unstaged work. `git reset` (mixed) unstages safely. Tar the dirty tree before any multi-step git surgery.
- Never push or merge another session's branch to satisfy a hook. Report it instead.
- Never claim something is verified without the command output. If a tier could not run, say which and why.
