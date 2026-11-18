# GitHub App for the fleet's gh reads

Every agent account runs `gh` as the same GitHub user, so the whole fleet shares one 5,000 an hour REST budget, and adding an account adds no budget. On 2026-11-10 that budget hit 0 at 22:36 and again at 04:36 PST: pushes, merges and sentinel probes all failed until the reset. A GitHub App installation has its own 5,000 an hour, one per installation, so reads sent there stop competing with the writes that only your token can do.

## How it works

`.local/bin/gh` sits ahead of the real `gh` on PATH. For each call it:

1. Decides whether the call is a read it can route: `run list|view|download`, `pr checks|diff`, `pr list|view` and `issue list|view` with `--json`, `workflow list|view`, `release list|view|download`, and `gh api` GETs under `repos/<owner>/`.
2. Finds the repo owner from `-R`, `GH_REPO`, a github.com URL argument, the `gh api` path, or the directory's origin when that is its only GitHub remote.
3. Asks `gh-app token <owner>` for that owner's installation token and runs the real `gh` with `GH_TOKEN` set to it.

Everything else stays on your token: writes (`pr create`, `pr merge`, `pr edit`, `api -X POST`), anything with `@me`, a `--watch` (it can outlive the token's hour), `gh api graphql`, `rate_limit`, a `GH_HOST` other than github.com, an owner with no installation, and a caller that set `GH_TOKEN` itself. PRs and merges keep your name.

When GitHub refuses the App's token for a read (HTTP 401 or 403, or `Resource not accessible by integration`), the wrapper reruns it on your token, so a broken App slows nothing down. After a failed mint, `gh-app` skips the App for 5 minutes instead of waiting on the network for every call; `gh-app status` clears that.

Every call, routed or not, gets one row in `~/.local/state/gh-calls/<YYYY-MM-DD>.tsv`: epoch, bucket (`user`, `app:<owner>`, `user:app-error`, `user:app-denied`, `env`), exit code, caller (the script that ran gh, `zsh` for an agent's own command), `$AGENT_QUEUE_ITEM`, and the command with bodies, fields and headers blanked (`secret`, `variable` and `auth` keep only their subcommand). The files are mode 600, and files older than 7 days are deleted. When the user budget runs LOW, `fleet-assess` names the top spenders from this log.

With no App configured, the wrapper only logs and passes every call straight through.

## Setup (one time, by you)

1. Create the App at https://github.com/settings/apps/new. Name it something like `kb-fleet-reader`, use any homepage URL, and turn off the webhook.
2. Repository permissions, all **Read-only**: Actions, Checks, Commit statuses, Contents, Issues, Metadata, Pull requests. Grant nothing with write access: the wrapper only sends reads, and a read-only App cannot post even by mistake.
3. Under "Where can this GitHub App be installed?", pick "Any account" so your organization can install it too.
4. Generate a private key and save it as `~/.config/gh-app/fleet.pem` with `chmod 600`.
5. Install the App on your account and on each organization whose repos the fleet works in, each with **All repositories**. An installation scoped to selected repositories is skipped (`gh-app` exits 2), because it would 404 the owner's other repos.
6. Write `~/.config/gh-app/fleet.env`:

   ```sh
   GH_APP_ID=<the App ID from the App's settings page>
   GH_APP_KEY_FILE=$HOME/.config/gh-app/fleet.pem
   ```

7. Check it with `gh-app status`. Each installation should print its REST calls left.

The config and key are per machine. Repeat steps 4 and 6 on the mac-mini to route its reads too.

## The shared budget

The App is the lever that adds budget; until it is set up (`gh-app status` prints `off`) every read spends the user's 5,000 an hour, so the wrapper also keeps one shared reading of it. Whoever calls `gh` first in a 30 second window renews `~/.local/state/gh-calls/budget` with `gh api rate_limit` (free, never counted); every other process reads the file. Below `GH_BUDGET_RESERVE` (1,000) calls left, every read exits 75 with `gh: N REST calls left ... waits for the reset at HH:MM` and a `user:deferred` log row, except a read from the human at a terminal and one with a `GH_RESERVE_CALLERS` program anywhere above it in the process tree (`agent-land gh-run-wait gate-and-land.sh ci-gate.sh gate-line.py night.sh agentctl-playground-night`, through `timeout`, `bash -c` or `xargs`). Every write and the `rate_limit` probe never wait, and a call on the App's token is never deferred. The list names who may spend the reserve. The list it replaced named who waits, so each new script spent the reserve, and `ci-cost.py --phases` took the budget to 14 on 2026-11-17. `tests/unit/gh_wrapper.bats` pins each case.

The hour the budget ran out (2026-11-13 05:35Z to 06:35Z, 4,651 calls, all on the user token because the App was off):

| Caller | Calls | What |
|---|---|---|
| playground gate pollers (`gate-line.py`, `ci-gate.sh`, run as `bash`) | 2,021 | `test.yml` runs per branch 409, `pulls/N` 387, issue events 410, `landing-slot` 145, runs lists 167 |
| `schedules-sync` | 628 | run reads for the Builds section, already conditional (ETag) |
| `ci-failures.py` | 336 | annotations, jobs and logs of finished runs |
| `fleet-sessions` | 300 | 287 of them `repo view` for the default branch, now kept an hour (`FLEET_BASE_TTL`) |
| `gh-run-wait` | 202 | one `run view` a minute per waiting session |

The gate pollers are the largest and are not deferrable: a tournament gate is a decision. Cutting them is queued as its own item in the playground repo.

The reserve has held since it landed (2026-11-13 19:04Z): on 2026-11-14 the budget dipped under it once (03Z, 58 deferred reads) and no night logged a 403. The day still spent 3,000 to 5,100 an hour, so it runs close. The top callers on the user token that day:

| Caller | Calls/day | What | Owner |
|---|---|---|---|
| playground gate pollers (`bash`, `ci-gate.sh`) | 27,371 | `pr view` per branch 3,219; `gh_rate_wait`'s two header probes after every failed call, limit or not, 4,326 | playground items for `gh_rate_wait` and the `gate-line.py` start path |
| `schedules-sync` | 21,107 | one `runs/N` read per run, 8,127 for the playground | its own item: cache finished runs, batch per repo |
| `agent-queue` | 6,625 | 5,241 failed `pr view` of home-config PRs on the GitHub mirror, uncached | this change (re-measure on the next day's log): `pr_state` reads a Forgejo-canonical PR from Forgejo (`so_pr_view`), off the GitHub budget, and caches a failed read for `AGENT_QUEUE_PR_TTL` (120 s) |
| `fleet-assess` | 3,011 | the `-i actions/workflows` header probe, every pass (it reads `X-Ratelimit-Resource: core` now, the bucket `rate_limit` already shows for free) | its own item: cache the probe for the cadence |

## Reading the log

```sh
# top callers on your token in the last hour
awk -F'\t' -v s=$(( $(date +%s) - 3600 )) '$1 >= s && $2 ~ /^user/ { n[$4]++ } END { for (c in n) print n[c], c }' \
  ~/.local/state/gh-calls/$(date +%F).tsv | sort -rn | head
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gh-app status` prints `off` | No `~/.config/gh-app/fleet.env` | Setup step 6 |
| Log rows read `user:app-error` | Minting failed: wrong App ID, unreadable key, or no network to api.github.com | `gh-app token <owner>` prints the error |
| Log rows read `user:app-denied` | GitHub refused the App's token (a missing read permission, an uninstalled App, or its own limit spent); the read reran on your token | Add the permission as Read-only in the App's settings and accept it on each installation, or reinstall |
| An owner's reads stay on `user` | No installation for that owner, or it covers selected repos only | Install on that account with All repositories |
| A session's `gh` is not the wrapper | `~/.local/bin/gh` is not stowed yet | Re-run the dotfiles deploy so stow links the new file |
| `gh: HOME is <dir>, not <home>: a sandboxed caller never reaches GitHub`, exit 3 | The caller runs under a HOME that is not the account's, as a test does, and `gh` on its PATH is this wrapper, not the test's stub | Put the stub first on PATH in the test; the refusal is the point, never work around it |
| `gh: N REST calls left, under the 1000 kept for gates and merges; <caller> waits for the reset`, exit 75 | The shared budget is under `GH_BUDGET_RESERVE` and no `GH_RESERVE_CALLERS` program is above the read | Nothing: it reads again after the reset. A gate or merge that sees it runs under a program the list does not name; add that program to `GH_RESERVE_CALLERS` in `.local/bin/gh`. `rm ~/.local/state/gh-calls/budget` forces a fresh reading |
