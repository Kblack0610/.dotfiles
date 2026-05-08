# Dotfiles

Personal dotfiles managed with GNU Stow. Beyond plain config, this repo also hosts the source-of-truth for a multi-tool agentic shell (Claude / Codex / Gemini / OpenCode), an installer for fresh Linux/macOS/Windows-WSL machines, and a handful of local utilities.

## Layout

| Path | What's there |
|---|---|
| `.zshrc`, `.bashrc`, `.commonrc`, `.tmux.conf`, `.gitconfig`, `.zprofile` | Shell + terminal multiplexer + git base config |
| `.config/nvim/` | Neovim config (lua) |
| `.config/{kitty,fish,zellij,wofi}/` | Terminal, shell, multiplexer, launcher |
| `.config/{hypr,waybar,aerospace,karabiner,keyd}/` | Window manager + bar + key remapping (Linux + macOS) |
| `.config/windows/{glazewm,powershell,terminal,wsl,zebar,scripts}/` | Windows + WSL counterparts |
| `.config/{k9s,lazydocker,jesseduffield/lazygit}/` | Cluster + container + git TUIs |
| `.config/rulesync-global/` | **Source of truth** for shared AI rules + MCP servers (fan-out to Claude/Codex/Gemini/OpenCode) |
| `.config/codex/` | Codex sync scripts (`sync-ai-global-config.sh`), Codex skills, project-checks heuristics |
| `.config/shared-hooks/` | `project-map.json`, session preflight, eval reporter, stale-plan archiver — used by all AI tools |
| `.config/{openclaw,agentctl,infra-dash,llm-judge,playwright,profile,smug}/` | Local agent/orchestration runtime config |
| `.claude/` | Claude Code harness — agents, skills, slash commands, hooks, llm-judge, settings (see below) |
| `.opencode/`, `.cursor/`, `.codeium/`, `.serena/` | Per-tool runtime state |
| `.local/bin/` | Personal scripts on `$PATH` |
| `.local/src/installation_scripts/` | Bootstrap installers (`install.sh`, `bootstrap.sh`, `linux/install_arch.sh`, `linux/install_debian.sh`, `linux/install_wsl.sh`, `mac/`, `windows/`, `android/`) |
| `.local/src/{adb-controller,android-suite,claude-wrapper,gungan,infra-dash,profile-switch,theme,tmux,system,systemd}/` | Local tooling and helper scripts |
| `.githooks/post-commit` | Repo-local git hooks |
| `.fonts/` | Bundled fonts |
| `Media/` | Wallpapers / lock screen assets |
| `AGENTS.md` | Codex root agent instructions (kept at repo root because Codex auto-loads it) |
| `.ai-rc`, `.k8s-rc` | Sourced by `.commonrc` for AI/k8s shell helpers |

## Submodules

Tracked in `.gitmodules`:

| Submodule | Path | Description |
|---|---|---|
| [android-suite](https://github.com/Kblack0610/android-suite) | `.local/src/android-suite/` | Android device provisioning and debloating |
| [claude-wrapper](https://github.com/Kblack0610/claude-wrapper) | `.local/src/claude-wrapper/` | Multi-account rotation wrapper for the Claude CLI |

(`.claude/` and `.local/src/tmux/` are plain directories — not submodules.)

## Installation

```bash
git clone --recursive https://github.com/Kblack0610/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow .
```

Already cloned without `--recursive`?

```bash
git submodule update --init --recursive
```

For a full machine bootstrap (packages, dotfiles, AI configs, hooks), use the installer that matches the host:

```bash
~/.dotfiles/.local/src/installation_scripts/install.sh           # autodetect
# or run the OS-specific entry directly:
~/.dotfiles/.local/src/installation_scripts/linux/install_arch.sh
~/.dotfiles/.local/src/installation_scripts/linux/install_debian.sh
~/.dotfiles/.local/src/installation_scripts/linux/install_wsl.sh
~/.dotfiles/.local/src/installation_scripts/mac/install.sh
```

The package catalog is in `installation_scripts/packages.conf`; OS-specific scripts source `base_functions.sh`. See `installation_scripts/README.md`.

### Manual reqs not handled by the installer

- [Floorp](https://floorp.app/en) (Firefox-based browser)
- [Kitty Terminal](https://sw.kovidgoyal.net/kitty/binary/) ([icon](https://github.com/DinkDonk/kitty-icon))
- [Stow](https://formulae.brew.sh/formula/stow)
- [zsh](https://github.com/ohmyzsh/ohmyzsh/wiki/Installing-ZSH) + [oh-my-zsh](https://ohmyz.sh/#install)
- oh-my-zsh plugins (clone into `~/.oh-my-zsh/custom/plugins`):
  [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions),
  [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
- [Hack font](https://sourcefoundry.org/hack/) + [Nerd Font Symbols](https://www.nerdfonts.com/font-downloads) (Kitty doesn't need a patched font, symbols-only is enough)
- [Neovim](https://github.com/neovim/neovim/blob/master/INSTALL.md), [tmux](https://github.com/tmux/tmux/wiki), [fzf](https://github.com/junegunn/fzf), [ripgrep](https://github.com/BurntSushi/ripgrep), [lazygit](https://github.com/jesseduffield/lazygit)

After cloning + reqs, run `stow .` to symlink everything into `~`.

## Post-stow setup

Some configs can't be symlinked (random profile names). Run these after stow:

```bash
~/.dotfiles/.config/firefox/install.sh   # Floorp/Firefox bottom tabs + Catppuccin
```

## Updating submodules

```bash
git submodule update --remote --merge                          # all
git submodule update --remote .local/src/android-suite         # one
```

## Shared AI configuration (Claude / Codex / Gemini / OpenCode)

Shared rules and MCP server definitions live once in `.config/rulesync-global/.rulesync/` and fan out to each tool's home directory.

```bash
# install rulesync (one-time)
curl -fsSL https://github.com/dyoshikawa/rulesync/releases/latest/download/install.sh | bash

# sync to ~/.claude, ~/.codex, ~/.gemini, ~/.config/opencode
~/.dotfiles/.config/codex/sync-ai-global-config.sh
```

Editing rules: change `.config/rulesync-global/.rulesync/rules/overview.md` (canonical) or `AGENTS.md` (Codex root) and re-run the sync. There's also an `update-rules` skill that handles the right-scope-and-sync flow — see "Claude harness" below.

## Claude harness (`.claude/`)

This dir is loaded by Claude Code as the project's harness layer:

- **`.claude/CLAUDE.md`** — workflow rules (plan-first, verification, lessons loop, memory routing, eval format).
- **`.claude/agents/`** — 25 specialized subagents (`kb-product-owner`, `kb-architect`, `kb-developer`, `kb-qa`, `kb-coordinator`, plus security/python/frontend/backend/devops/perf/refactoring/quality/learning/research/etc.).
- **`.claude/skills/`** — domain skills auto-invoked by name. Currently:
  `notes-system`, `gh-workflows`, `k8s-ops`, `cloudflare-ops`, `forgejo-ops`, `mem0-ops`, `adb-ops`, `bnb-quality-gates`, `bug-bash`, `bug-bash-wrapup`, `one-pager`, `placemyparents-release`.
- **`.claude/commands/`** — 51 slash commands across four namespaces:
  `/sc:*` (analyze, build, design, implement, improve, troubleshoot, …), `/my:*` (claude-edit, fix-ci, fresh, judge, monitor-pr, pr-merge-flow, worktree-recycle, …), `/kb:*` (workflow, implement, ci, ci-analyze), `/daily:*` (analysis, standup, summary, slack), plus `binks`, `feature`, `remember`.
- **`.claude/hooks/`** — Stop-hook gate runs `stop-checks.d/` (git/node/cargo/python/go health), then `stop-post.d/85-sync-plans.sh` (mirror plans → `~/.agent/plans/{project}/`) and `stop-post.d/90-eval-gate.sh` (eval block + lessons capture). Plus `block-pip.sh`, `large-file-warning.sh`, `llm-judge.sh`.
- **`.claude/settings.json` / `settings.local.json`** — permissions, env, hook wiring.

The Claude rules and the Codex `AGENTS.md` are deliberately kept in sync via the rulesync source — don't drift one from the other.

## OpenClaw

OpenClaw has a separate bootstrap because durable config is tracked here and runtime state stays in `~/.openclaw/`:

```bash
~/.dotfiles/.config/openclaw/setup-openclaw.sh
```

Installs the tracked base config, starter workspaces, and baseline exec approvals without touching provider auth or other ephemeral state. Runtime shape: one front-door `home-orchestrator` agent delegates to workers for ops diagnosis, ops changes, and PR work.

## Keyboards

```bash
qmk setup kblack0610/qmk_firmware -H ~/src/qmk_firmware
```

## Filesystem conventions

- `~/.bin` — apps
- `~/src` — source
- `~/dev` — projects
- `~/.local/bin` — scripts
- `~/Media` — music, videos
- `~/tmp` — scratch
- `~/.agent/{plans,lessons,evals}/{project}/` — per-project agent state (separate repo, populated by Claude/Codex hooks)
- `~/.notes/` — shell-driven journal/knowledge repo

Ubuntu-required (created by the OS, kept around):

- `~/Documents`, `~/Downloads`, `~/snap`
