# Claude-acct usage sources

`claude-acct` turns every model pool, the Claude subscription accounts and every other source, into one usage row for `status`, `room`, `check pace`, `textfile` (`claude_acct.prom`) and the Costs tab. Claude accounts are listed in `~/.config/claude-acct/accounts` (tokens: [claude-acct-tokens.md](claude-acct-tokens.md)), and every other source in `~/.config/claude-acct/sources`. The format of a sources row, its kinds and its options, and every command are documented once, in the header of `.local/bin/claude-acct`.

Every `claude_account_*` series carries `email="<the account's login>"` beside `account` and `kind`, so usage history follows the Anthropic account when a folder is re-logged in; a row with no known email (a non-Claude kind, a dir with no `.claude.json`) has no `email` label. A login change or a failed `.claude.json` read changes the labelset, so a query that does not aggregate `email` away (`max by (account)`) sees a new series for up to the 5-minute staleness window.

## Add a source

A provider behind the LiteLLM gateway (a z.ai plan, say) needs no new kind and no code: it is a gateway route plus a `litellm-key` row.

1. **Route and key.** Add the provider's route, with any deployment budget or rpm, to home-config `apps/litellm/config.yaml`, and mint a scoped virtual key for it (home-config `apps/litellm/README.md`, "Create a key"). Put the key file on each host that spends from it, mode `0600`, beside the others (`~/.local/state/agentctl/<name>.key`).

2. **Sources row.** Add the row to this repo's `.config/claude-acct/sources` (stowed to `~/.config/claude-acct/sources`) by PR, under a comment saying what the source is and why its caps are what they are, as `go` and `nim` have:
   ```
   <name> litellm-key ~/.local/state/agentctl/<name>.key max_live=N
   ```
   The other options (`rpm` and `run_rpm`, `run_usd`, `parent`, `reserve`, `alert`, `priority`, `host`) are in the `claude-acct` header.

3. **Consumers.** For `fleet-dispatch`, give the harness that runs on it `"source": "<name>"` in `~/.config/agentctl/harnesses.json` (private overlay), with its models and key file, and for a free or prompt-training provider its `"sandbox"`, `"config_dir"` and `"projects"`, as the `opencode-go` entry has them. An `agentctl` runner spends from its harness's source unless its conf sets `SOURCE=<name>`.

4. **Verify.**
   ```sh
   claude-acct models <name>           # the model ids its key may call; exit 0
   claude-acct room --source <name>    # its verdict: exit 0 room, 1 refused, 2 unread, 3 no such source here
   claude-acct status                  # its row renders beside the accounts
   ```
   `claude-acct check pace` is fleet-wide: its exit 1 can be another source's, so read the new source's verdict from `room --source`.
