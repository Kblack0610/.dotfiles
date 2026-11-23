# Claude-acct usage sources

`claude-acct` turns every model pool, the Claude subscription accounts and every other source, into one usage row for `status`, `room`, `check pace`, `textfile` (`claude_acct.prom`) and the Costs tab. Claude accounts are listed in `~/.config/claude-acct/accounts` (tokens: [claude-acct-tokens.md](claude-acct-tokens.md)), and every other source in `~/.config/claude-acct/sources`. The format of a sources row, its kinds and its options, and every command are documented once, in the header of `.local/bin/claude-acct`.

## Add a source

A provider behind the LiteLLM gateway (a z.ai plan, say) needs no new kind and no code: it is a gateway route plus a `litellm-key` row.

1. **Route and key.** Add the provider's route, with any deployment budget or rpm, to home-config `apps/litellm/config.yaml`, and mint a scoped virtual key for it (home-config `apps/litellm/README.md`, "Create a key"). Put the key file on each host that spends from it, mode `0600`, beside the others (`~/.local/state/agentctl/<name>.key`).

2. **Sources row.** Add one line to `~/.config/claude-acct/sources`:
   ```
   <name> litellm-key ~/.local/state/agentctl/<name>.key max_live=N [rpm=N run_rpm=N] [run_usd=N] [parent=<pool>] [priority=low] [host=a,b]
   ```
   `max_live`, or `rpm` over `run_rpm`, caps its live queue items; `run_usd` paces a route that has a deployment budget; `host=` keeps the row to the machines that hold the key file.

3. **Consumers.** For `fleet-dispatch`, give the harness that runs on it `"source": "<name>"` in `~/.config/agentctl/harnesses.json` (private overlay), with its models and key file, plus `"sandbox"` and `"projects"` for a free or prompt-training provider. An `agentctl` runner spends from its harness's source unless its conf sets `SOURCE=<name>`.

4. **Verify.**
   ```sh
   claude-acct models <name>           # the model ids its key may call; exit 0
   claude-acct room --source <name>    # its verdict: exit 0 room, 1 refused, 2 unread
   claude-acct status                  # its row renders beside the accounts
   claude-acct check pace              # it reads, and is inside its pace line and reserve
   ```
