# GitHub App for the fleet's gh reads

Every agent account runs `gh` as the same GitHub user, so the whole fleet shares one 5,000 an hour REST budget, and adding an account adds no budget. On 2026-11-10 that budget hit 0 at 22:36 and again at 04:36 PST: pushes, merges and sentinel probes all failed until the reset. A GitHub App installation has its own 5,000 an hour, one per installation, so reads sent there stop competing with the writes that only your token can do.

## How it works

`.local/bin/gh` sits ahead of the real `gh` on PATH. For each call it:

1. Decides whether the call is a read it can route: `run list|view|download`, `pr checks|diff`, `pr list|view` and `issue list|view` with `--json`, `workflow list|view`, `release list|view|download`, and `gh api` GETs under `repos/<owner>/`.
2. Finds the repo owner from `-R`, `GH_REPO`, a github.com URL argument, the `gh api` path, or the directory's origin when that is its only GitHub remote.
3. Asks `gh-app token <owner>` for that owner's installation token and runs the real `gh` with `GH_TOKEN` set to it.

Everything else stays on your token: writes (`pr create`, `pr merge`, `pr edit`, `api -X POST`), anything with `@me`, `gh api graphql`, `rate_limit`, an owner with no installation, and a caller that set `GH_TOKEN` itself. PRs and merges keep your name.

Every call, routed or not, gets one row in `~/.local/state/gh-calls/<YYYY-MM-DD>.tsv`: epoch, bucket (`user`, `app:<owner>`, `user:app-error`, `env`), exit code, caller (the script that ran gh, `zsh` for an agent's own command), `$AGENT_QUEUE_ITEM`, and the command. Files older than 7 days are deleted. When the user budget runs LOW, `fleet-assess` names the top spenders from this log.

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
| A routed read fails with `Resource not accessible by integration` | The App lacks that read permission | Add it as Read-only in the App's settings, then accept the new permission on each installation |
| An owner's reads stay on `user` | No installation for that owner, or it covers selected repos only | Install on that account with All repositories |
| A session's `gh` is not the wrapper | `~/.local/bin/gh` is not stowed yet | Re-run the dotfiles deploy so stow links the new file |
