# Claude Wrapper

Multi-account rotation wrapper for Claude CLI with automatic rate-limit fallback and concurrent session support.

## Features

- **4-Account Rotation** - Automatically rotates between up to 4 Claude.ai OAuth accounts
- **Rate-Limit Fallback** - Detects rate limits and switches to next available account
- **Concurrent Sessions** - Run multiple Claude sessions simultaneously with different accounts
- **Status Tracking** - JSON state file tracks account usage and rotation
- **Desktop Notifications** - Optional libnotify integration for rate-limit alerts
- **Profile Management** - Easy setup and rotation of OAuth tokens

## Why This Exists

Claude CLI is amazing but has rate limits. If you have multiple Claude.ai accounts (personal, work, etc.), this wrapper lets you:
- Seamlessly rotate between accounts when you hit rate limits
- Run multiple concurrent Claude sessions without conflicts
- Never interrupt your flow when rate-limited

## Quick Start

```bash
# Install
git clone https://github.com/Kblack0610/claude-wrapper.git
cd claude-wrapper
./install.sh

# Set up your accounts (interactive)
claude-rotate-setup

# Use claude normally - rotation happens automatically!
claude "what is the meaning of life?"

# Check account status
claude --status
```

## Installation

### Option 1: Install Script

```bash
git clone https://github.com/Kblack0610/claude-wrapper.git
cd claude-wrapper
./install.sh
```

This will:
1. Symlink `bin/claude-wrapper` to `~/.local/bin/claude`
2. Back up your existing `claude` binary to `claude-real`
3. Make the wrapper scripts executable

### Option 2: Manual

```bash
# Move your existing claude binary
mv ~/.local/bin/claude ~/.local/bin/claude-real

# Symlink the wrapper
ln -s /path/to/claude-wrapper/bin/claude-wrapper ~/.local/bin/claude
ln -s /path/to/claude-wrapper/bin/claude-notify ~/.local/bin/claude-notify
ln -s /path/to/claude-wrapper/bin/claude-rotate-setup ~/.local/bin/claude-rotate-setup
```

## Setup

### 1. Get OAuth Tokens

For each Claude account:

1. Log into https://claude.ai in your browser
2. Open DevTools (F12) → Application → Local Storage
3. Find `sessionKey` value
4. Copy the OAuth token (starts with `sk-ant-...`)

### 2. Configure Profiles

Run the interactive setup:

```bash
claude-rotate-setup
```

Or manually create profile files:

```bash
mkdir -p ~/.claude/profiles
echo "YOUR_TOKEN_HERE" > ~/.claude/profiles/1.token
echo "YOUR_TOKEN_HERE" > ~/.claude/profiles/2.token
# ... up to 4.token
```

### 3. Initialize State

The wrapper will auto-create `~/.claude/rotation/state.json` on first run.

## Usage

### Normal Usage

Just use `claude` as you normally would:

```bash
claude "help me debug this code"
claude --profile sonnet "write a story"
```

The wrapper:
- Automatically picks the best available account
- Rotates on rate limits
- Logs all operations

### Force Specific Account

```bash
claude -p 1 "use account 1"
claude -p 2 "use account 2"
# ... up to -p 4
```

### Check Account Status

```bash
claude --status
```

Shows:
- Active account
- Last used timestamps
- Rate limit status
- Available accounts

### Concurrent Sessions

Each terminal/session gets its own account automatically via `CLAUDE_CODE_OAUTH_TOKEN` environment variable injection.

## File Structure

```
~/.claude/
├── profiles/
│   ├── 1.token          # Account 1 OAuth token
│   ├── 2.token          # Account 2 OAuth token
│   ├── 3.token          # Account 3 OAuth token
│   └── 4.token          # Account 4 OAuth token
├── rotation/
│   ├── state.json       # Current rotation state
│   └── log.jsonl        # Rotation event log
└── mcp.json             # MCP server config (optional)
```

## How It Works

1. **Account Selection**
   - Wrapper checks `state.json` for last used account
   - Rotates to next account in sequence
   - Updates state file with timestamp

2. **Rate Limit Detection**
   - Monitors Claude CLI output for rate-limit errors
   - Auto-switches to next account on detection
   - Sends desktop notification (if `notify-send` available)

3. **Token Injection**
   - Sets `CLAUDE_CODE_OAUTH_TOKEN` environment variable
   - Passes through to `claude-real` binary
   - Each session gets isolated token

## Utilities

### claude-notify

Desktop notification helper for rate-limit alerts.

```bash
claude-notify "Rate limit hit! Switching to account 2"
```

### claude-rotate-setup

Interactive setup wizard for configuring accounts.

```bash
claude-rotate-setup [--force]
```

## Troubleshooting

### "claude-real not found"

The wrapper looks for the actual Claude binary at `~/.local/bin/claude-real`. If you haven't backed it up:

```bash
# Download Claude CLI fresh
curl -fsSL https://claude.ai/install.sh | sh

# Move it to claude-real
mv ~/.local/bin/claude ~/.local/bin/claude-real
```

### Tokens Expired

Claude OAuth tokens expire periodically. Re-run `claude-rotate-setup` to update them.

### State File Corrupted

Delete and reinitialize:

```bash
rm ~/.claude/rotation/state.json
claude --status  # Will recreate
```

## Configuration

The wrapper uses these environment variables (optional):

- `CLAUDE_WRAPPER_MAX_ACCOUNTS` - Max accounts (default: 4)
- `CLAUDE_WRAPPER_NOTIFY` - Enable notifications (default: auto-detect)
- `CLAUDE_CODE_OAUTH_TOKEN` - Direct token override

## Logs

All rotation events are logged to `~/.claude/rotation/log.jsonl`:

```json
{"timestamp":"2026-01-30T01:00:00Z","event":"rotate","from":1,"to":2,"reason":"rate_limit"}
{"timestamp":"2026-01-30T01:05:00Z","event":"rotate","from":2,"to":3,"reason":"scheduled"}
```

## Uninstall

```bash
# Restore original claude binary
mv ~/.local/bin/claude-real ~/.local/bin/claude

# Remove wrapper symlinks
rm ~/.local/bin/claude-notify
rm ~/.local/bin/claude-rotate-setup

# Optionally remove state
rm -rf ~/.claude/rotation
```

## Contributing

Found a bug? Want a feature? Open an issue or PR!

## License

MIT - Use freely, modify as needed.

## Credits

Built for power users who love Claude CLI and hate rate limits.
