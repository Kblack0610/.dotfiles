# OpenClaw Setup

This directory is the dotfiles-managed source of truth for the durable parts of the local OpenClaw setup.

Tracked here:

- `openclaw.base.json5` - base gateway and agent configuration
- `exec-approvals.base.json` - baseline exec allowlists for local agents
- `workspaces/` - starter `AGENTS.md` files for agent-specific workspaces
- `setup-openclaw.sh` - bootstrap script that materializes the local setup under `~/.openclaw`

Not tracked here:

- gateway tokens
- provider API keys
- auth profiles
- sessions, logs, sqlite files, or other runtime state

## Bootstrap

```bash
~/.dotfiles/.config/openclaw/setup-openclaw.sh
```

The script:

1. Creates the local workspace and log directories under `~/.openclaw/`
2. Installs the base config if `~/.openclaw/openclaw.json` does not exist
3. Copies starter `AGENTS.md` files into agent workspaces if they do not exist
4. Installs the baseline exec approvals file if it does not exist
5. Adds any missing allowlist entries for detected local binaries
6. Validates the resulting config with OpenClaw

Use `--force` to overwrite the local base config and starter workspace prompts.

## Next steps after bootstrap

```bash
openclaw dashboard
openclaw models auth login
```

Recommended first cloud fallback to add later:

- Anthropic or OpenAI via `openclaw models auth login`

The shipped base config is local-first. It assumes your MLX endpoints are reachable and leaves cloud auth to your local OpenClaw auth store.
