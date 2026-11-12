---
name: fleet-pace
description: >-
  Keep the machine busy but responsive (about 70% CPU): assess load, hold a resource, park sessions, GO in batches, pace check. Use for "the machine is melting", "stop all the agents", "is there room for more", "lift the hold". Session progress is shepherd.
metadata:
  category: monitoring
  tags: [agents, fleet, load, thermal, hold]
  reviewed: 2026-11-11
  # The hand-typed forms that hang or kill the machine; hand_methods.py denies them. The Grep and Glob
  # half of the root-search deny is block-root-search.sh.
  replaces:
    - match: |-
        (?:^|[^A-Za-z0-9_.-])pkill(?:[ \t]+[^;&|\s]+)*[ \t]+(?:-[a-eg-zA-Z0-9]*f[A-Za-z0-9]*|--full)(?:[ \t;&|)"']|$)
      use: "`pkill -x <name>`, or kill a PID you hold: `$!`, a pidfile, or `pgrep -x <name>`. To search or write about the command, break the phrase, e.g. `rg 'pkill[ ]-f'`"
      mode: deny
      why: "a -f pattern also matches this command's own shell and other sessions' processes, so it kills them (a test-file pattern once killed every worktree's bats run; 291 session-days of the lesson before the guard)"
    - match: |-
        (?m)\A(?=.*(?:^|[;&|(`]|\$\(|xargs(?:\s+[^;&|\s]+)*)[ \t]*(?:sudo[ \t]+)?kill(?:\s|$))(?=.*(?:^|[^A-Za-z0-9_.-])pgrep(?:[ \t]+[^;&|\s]+)*[ \t]+(?:-[a-eg-zA-Z0-9]*f[A-Za-z0-9]*|--full)(?:[ \t;&|)"']|$))
      use: "`pgrep -x <name>`, or a PID you hold, before `kill`"
      mode: deny
      why: "the -f pattern is on the shell's own command line, so the pgrep matches that shell and the kill takes it down"
    - match: |-
        (?:^|[\s;&|(){}`])(?:\S*/)?(?:(?:find|bfs|fd|fdfind|rg|ugrep)|e?grep(?=[^;&|()`\n]{0,400}\s(?:-[A-Za-z0-9]*[rR][A-Za-z0-9]*|--(?:dereference-)?recursive)(?=\s|$)))(?=\s)(?![^;&|()`\n]{0,400}\s(?:-xdev|-mount|--one-file-system)(?=\s|$))[^;&|()`\n]{0,400}?\s(?<!-path\s)(?<!-ipath\s)(?<!-wholename\s)(?<!-iwholename\s)(?<!-newer\s)(?<!-samefile\s)(?<!-regex\s)/(?:mnt(?:/nas(?:/(?:private|public))?)?)?/*(?=\s|[;&|()`]|$)
      use: "search the working directory (a repo's code, submodules included, is under it) or a named subdirectory; to search the share, name a subdirectory of it, or add `-xdev` / `--one-file-system`"
      mode: deny
      why: "a recursive walk from / or /mnt enters the CIFS mount /mnt/nas and blocks on it for tens of minutes (2026-10-29: three sessions, load 28 on 24 cores at 0% CPU); a new network mount adds its path here"
---

# fleet-pace

The machine-room role of `fleet-lead` (Binks). It was written down after 2026-10-23: about 15 sessions each started headless Unity runs, load reached 96 on 24 cores, Tctl reached 95.8 C, and the timing-sensitive test classes went red. Stopping them took an improvised process-tree trace, a hand-built kill, a dozen one-off messages, and a second kill when shell loops respawned the editors. This skill makes that a three-verb routine, and a fleet left idle is the same failure in the other direction.

## Scope and triggers

Covers keeping the machine busy but responsive (about 70% CPU): assess load, hold a resource, park sessions, GO in batches, the pace check.

Use for "the machine is melting", "stop all the agents", "is there room for more", "lift the hold". Session progress and nudges: `shepherd`.

## Tools

- `fleet-assess` prints headroom (load against cores, Tctl, memory with its stall and swap used, threads blocked on I/O), the GitHub REST calls left this hour in the emptier of its two per-user buckets (a `github:` line; `(actions/workflows)` names the bucket `gh run list`, `gh run view` and `gh workflow run` spend, which `gh api rate_limit` does not show; LOW under `FLEET_GH_LOW` with over 20 minutes to the reset, naming the scripts whose gh calls are running), active holds, a verdict, one row per heavy process (pid, CPU, nice, class, tmux session, worktree, command, and the pane as `<server>/<pane id>`, which `fleet-sessions` reads to mark only that pane's agent WORKING heavy; a last TREE column sums the process and all its descendants, and a runner whose children are each under the line gets a row showing its own low CPU and that sum), and a `blocked on I/O` table for any process over 5 minutes old with a thread in D state (thread count, age, wchan, the file it holds open). `--watch-probe` prints one line and exits 1 on HOLD; `--blocked` prints only the blocked rows, tab-separated.
- `agent-hold set | grant | release | check | list` is the durable pause, and `grant` is GO for named sessions while the hold stays. The session preflight prints every active hold. unity-core-playground's `scripts/test/run.sh`, `two-process.sh` and `scripts/authoring/unity-method.sh` wait while `unity` is held (#825) and take one of a few run slots, so a `unity` hold stops new runs even from sessions and `shell`-class loops that never read your message. Other resources are held only by message.
- `claude-acct park <target>` exits a session's claude and keeps its pane, writing the resume to `~/.agent/parked/<key>`; `claude-acct unpark <target>` resumes it there on the account with room. A target is `[server/]session`, `[server/]session:window` or a pane id `%N`; name the window or pane when the tmux session holds more than one claude (the hub `dotfiles` session does), and the ledger key is then `session:window`. A parked session costs no tokens: no background task finishing and no message can wake it to re-read its context. A pause sent as a message costs one full-context turn, and the session keeps waking on its own waits: on 2026-11-02 those wakes were 48% of the fleet's tokens.
- The `fleet-thermal` sentinel watch runs `fleet-assess --thermal-probe` every minute and pages on a state change. A trip means "run `assess`", and a clear means "run `go`". A trip holds until load is under 1x cores, so one overload is one page, with Sentinel's 24h reminder if it lasts.

The class column tells you how each consumer can be stopped:

| Class | What it is | How it stops |
|---|---|---|
| `claude` | a Claude session drove it | parked (`claude-acct park`) when idle or waiting on GitHub, a `fleet-comms` message when busy, plus the hold |
| `shell` | a tmux pane with no Claude, usually a suite loop | the hold at the resource gate, or a kill. It has no inbox |
| `agentctl` | an agentctl unit | `agentctl stop <name>` |
| `unit` | another systemd user service (its name in the session column) | `systemctl --user stop <name>` |
| `ci` | a job of this host's CI runner pool (cgroup under `ci.slice`; the runner slice is in the session column) | `machine-mode` runner slots: a busy runner finishes its job, then takes no new one. A stuck job: cancel its run (`gh run cancel`), never a kill |
| `orphan` | reparented to init, its driver gone | nothing will reap it; a kill, with the human's OK |

## Verdicts

| Verdict | Meaning |
|---|---|
| HOLD | Over the high mark (load at 1.75x cores, or memory under 10% free, or memory stall (PSI some avg10) at 20% or more, which is swapping while MemAvailable still reads fine, or Tctl at 95 with load at 1.5x), or between the marks while a machine hold is set (any hold but those in `FLEET_NOT_LOAD_HOLDS`, default `dispatch mac-desktop`, which pause work or the mac-mini desktop and say nothing about load) |
| CLEAR | A hold is set and the machine is under the low mark (load under 1x cores, memory at 25% free or more, stall under 5%). Safe to send GO |
| OK | Nothing held, nothing over the line |

The gap between the marks is deliberate. A hold set at 1.75x and lifted at 1.7x would flap and page on every sample. The high mark is where the CPU runs out of idle time: on 2026-10-26 load 46 on 24 cores (1.9x) read OK against the old 3x mark while `top` showed 0% idle, and the human had to point at it. When you report a pass, check what the human sees (`top`'s idle), not only the verdict. Load is the main signal; temperature alone is not. This box is a Zen 4 part, which boosts until it reaches 95 C, so readings in the 90s with one busy thread are normal. The thresholds are the `FLEET_*` variables at the top of `fleet-assess`, and that block is the one place to change them.

Under-use is a fault too, but never fix it by moving gates. A playground gate always runs on the pool, and a gate queued past an hour is a CI bug to report (`docs/operations/ci.md` rules 2 and 9). A player build (`PlaygroundBuild.Build*`) on the workstation is never in budget (rule 3): it starts one shader compiler per core.

## Verb: `assess`

1. Run `fleet-assess`. Quote the headroom line and the verdict to the user as given, and the `github:` line when it says LOW: the limit is per user, so when it runs out every gh call in the fleet fails until the reset. Name the scripts it lists, and tell sessions not to retry gh in a loop.
2. Group the rows by worktree and class. Run `ListAgents` and match its names to the SESSION column.
3. Say who is consuming what, and how each can be stopped (the class table). Name any batch job whose pane is not yet lowered (hold step 3; `agent-hold show <resource>` lists the lowered units): it is competing with the human's desktop. The NI column does not say: ananicy-cpp runs every shell at nice -4.
   A thread blocked on I/O adds 1 to load and 0 to CPU, so when load is well above what `top` shows busy, the blocked table explains the gap. Read it before blaming Unity.
4. On HOLD, recommend `hold` and the resource name. On CLEAR, recommend `go`. On OK, stop there and send nothing.

## Verb: `hold <resource> "<reason>"`

Go down the ladder only as far as you need to:

1. **Set the hold.** `agent-hold set <resource> --roster <the claude sessions> "<reason with the numbers>"`. This pages low (Binks acts on it, the human does not) and makes every new session and every gate see it.
2. **Park the Claude sessions on the roster that are not mid-turn**, by `activity` in `fleet-sessions --json`, skipping `manual`:
   - `idle`: `claude-acct park <session>`. No message: it is told why when it is unparked.
   - `shell`: `claude-acct park <session> --stop-shells`. It parks only when every background shell is a wait on GitHub (`gh-run-wait`, `gh run watch`, `gh pr checks --watch`, an `until ... gh ...; do sleep` loop), and refuses a local gate, suite or Unity run, which the hold's gate already holds; leave that one running.
   - `busy`: one `fleet-comms` PAUSE message naming the hold, and park it on a later pass once it reads idle.
   - `waiting`: the human's; leave it.
3. **Lower the priority** of batch consumers that are still running: `agent-hold lower <resource> <pid>...` with the PID column of `fleet-assess`. It sets `CPUWeight=1` (default 100) on each pid's tmux pane scope or agentctl unit, so everything in that pane, including children started later, gets about 1% of a contended CPU, and it records the unit on the hold; `agent-hold release` restores it. The weight covers the whole pane, the session's claude too, which is what a hold asks of it. It refuses a desktop terminal's or app's scope, which is the human's, and the caller's own pane. A release that cannot restore a live unit keeps the hold and says so; run it again. Check with `systemctl --user show <unit> -p CPUWeight`. Not renice: ananicy-cpp types bash and zsh nice -4 and resets every new child to it, so on 2026-11-07 583 threads reniced to 19 under 20 sessions left the nice share at 0.4%. Not ionice either: these NVMe disks run kyber, which ignores I/O priority. This is reversible and needs no ask.
4. **Kill only when the human asks.** Then kill only batch process trees (the driving `run.sh`, its `timeout`, the editor), and never an interactive editor, meaning a Unity without `-batchmode`. The CPU throttles itself at 95 C, so the hardware is safe while the human decides, and a killed run is lost work.

Shell loops will respawn whatever you kill until their gate honors the hold. If a loop keeps coming back, kill its driving loop (the `shell`-class ancestor) with the human's OK, and do not re-kill its children over and over.

Report the before and after numbers from `fleet-assess`.

## Verb: `go <resource>`

1. Run `fleet-assess`. Continue only on CLEAR. On HOLD, say what is still over the line and stop.
2. Stage the restart, because nothing paces it for you. Keep the hold set and `agent-hold grant <resource> <s1> <s2> <s3>`, at most 3 sessions per pass: first the owners of a nightly red (the NIGHTLY rows' `owners` in `fleet-sessions --json`), then per `~/.agent/shepherd/orders.md`, then whose work unblocks others (a red PR). The grant is the GO: `agent-hold check` passes for those sessions, so a run already queued on the hold starts by itself. A granted session that is PARKED gets `claude-acct unpark <session>` and no message: the resume tells it it was parked and to re-check what it waited on. Message each other one: "you are granted `<resource>`; a queued run starts by itself, start any new run one at a time, and set no override". On each later pass that still reads CLEAR, grant the next 3. A standing exemption from the human (a session that may run under a hold) is a grant too, made right after the `set`.
3. After the last batch has had GO and a pass still reads CLEAR, `agent-hold release <resource>`. It restores every unit `lower` slowed and prints the roster; unpark any of it still parked.
4. If a pass reads HOLD again, the batch was too wide: `agent-hold set <resource>` again, which drops every grant, tell the sessions that had one to start nothing new, and tell the human. 2026-10-26: GO to all 7 sessions at once took load from 28.8 back to 69 on 24 cores within 15 minutes.

## Pace check

What a `fleet-lead pass` runs for a `pace:`, `blocked:` or `limit:` due line, or when its pace reading shows HOLD or idle under 5%. Run `fleet-assess` and read idle from a real sample: `top -bn2 -d2 | grep '^%Cpu' | tail -1`. Never `top -bn1`: its only frame averages since boot and can read idle at 50% while a 2-second sample reads 15%.

- Over the top (HOLD, or idle under 5%): run the `hold` verb. If one process tree is the cause, name it. A player build on the workstation (`PlaygroundBuild.Build*`, one shader compiler per core) is never in budget; tell the human and kill it only with their OK.
- A `pace:` line naming a hold while the machine reads CLEAR: run `go`.
- A `pace: parked <targets>` line (sessions parked while the machine reads CLEAR with no hold): `claude-acct unpark` each target. A session parked on its budget is left off the line, because that park paged the human, who decides when it resumes.
- A gate queued or running past about an hour (`gh run list --status queued`, or a pane waiting on `ci-gate.sh`): report it once per run as a CI bug (one agent-board row, or `agent-ask` when it blocks a session), and leave the gate where it is (`docs/operations/ci.md` rule 9).
- Blocked on I/O (a `blocked:` due line, or rows in the `blocked on I/O` table that a second pass still shows): a recursive search (`find`, `bfs`, `fd`, `rg`, `grep -r`, `ugrep`, or Claude's own Grep/Glob, whose comm is its version, like `2.1.312`) only reads, so `kill` it without asking and send its session one `fleet-comms` line: "your search from `/` was walking the NAS for <age>; I killed it. Search your worktree or a named directory." That line is the one message a WORKING session ever gets. Anything else blocked (a build, copy or test on a network mount, a hung mount) goes to the human with the open path; never kill it. Blocked threads are not CPU, so they are never a reason to hold Unity. 2026-10-29: three searches from `/` walked `/mnt/nas` for 25-43 minutes, load 28 at 0% CPU, and no pass saw them; `block-root-search.sh` now denies the call.
- An account out of usage (`claude-acct status` shows it at 100% of its week or its 5h window): `fleet-shepherd due` prints one `limit:` line per live session on it, and the pass answers each. A gateway session counts when the `litellm-team` source is spent (`on gateway` in the line), and `claude-acct status` shows the spend the gateway refuses at. Idle: run the line's `claude-acct move <target> --to <account>`, which exits that claude and resumes the same conversation in the same pane on the account `claude-acct room` named. In a dialog: list it for the human, then `fleet-shepherd skip` the line. Busy or running shells: no line; it comes due once idle, so a gate or test is never cut off. Never add `--stop-shells` to a limit move, and never move a session `~/.agent/shepherd/orders.md` marks CI-first without asking the human first. No account has room: one line per account; tell the human once, since only they can log in or add usage, and skip it. Which account carries new work is `claude-acct room`'s call (the account-usage-leverage item), not this move's.
- A session on an account with room that still stopped on the limit (the `stopped on the usage limit` line, or the pane shows "weekly limit" or "/login", or for a gateway session "Budget has been exceeded"; read the pane first, since that line is only a text match): `claude-acct move <target>` (`--dry-run` shows the plan), or the `stopped on its gateway budget` line's own command. It refuses a busy session, an open dialog, a session already on that account, and one with background shells running, which it lists; move it on a later pass. Never answer /exit's "Move to background": it forks the conversation into a `claude daemon` session left on the old account, a second agent in the same worktree once that account resets.
- Otherwise the pace is fine; say the numbers in one line.

## Do NOT

The fleet-wide list is in `fleet-lead`; these are this role's own.

- Lift a hold on a timer, or because the session that set it went quiet. Lift it on CLEAR.
- Read the machine mode's lower runner and Unity slots, or its lower level, as a pace failure. The mode is the human's word on how much of the machine is free; only `machine-mode` changes it, and no mode holds dispatch.
- Tell a session to run with `UNITY_TEST_IGNORE_HOLD` or `UNITY_TEST_SLOTS`. They are for a person in their own shell, and `slots.sh` ignores them in an agent session. GO is `agent-hold grant`, which ends with the hold; the flag never ended, and on 2026-10-28 all 6 Unity runs live under a hold carried it.
- Treat a Tctl reading in the 90s on its own as an emergency.
- Edit the sentinel watch to go quiet while it is tripped. It is red because the machine is, and the clear edge is the GO signal.
- GO a run for a session whose row has `conflicts: true`. The run tests a tree that cannot merge; the conflict is resolved first.
- Hold back sessions while the machine is under budget, or report "nothing to act on" while `top` shows the box idle with work queued. Both are pace failures.

## Related

- `fleet-lead`: the pass that routes pace lines here.
- `fleet-comms`: the PAUSE and GO message wording.
- `sentinel`: hosts the `fleet-thermal` watch that trips `assess`.
