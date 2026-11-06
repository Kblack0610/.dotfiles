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
| `.config/shared-hooks/` | `project-map.json`, session preflight, stale-plan archiver — used by all AI tools |
| `.config/{agentctl,playwright,profile}/` | Local agent/orchestration runtime config |
| `.claude/` | Claude Code harness — agents, skills, slash commands, hooks, settings (see below) |
| `.opencode/`, `.cursor/`, `.codeium/` | Per-tool runtime state |
| `.local/bin/` | Personal scripts on `$PATH` |
| `.local/src/installation_scripts/` | Bootstrap installers (`install.sh`, `bootstrap.sh`, `linux/install_arch.sh`, `linux/install_debian.sh`, `linux/install_wsl.sh`, `mac/`, `windows/`, `android/`) |
| `.local/src/{adb-controller,android-suite,gungan,profile-switch,theme,tmux,system,systemd}/` | Local tooling and helper scripts |
| `.githooks/post-commit` | Repo-local git hooks |
| `.fonts/` | Bundled fonts |
| `Media/` | Wallpapers / lock screen assets |
| `AGENTS.md` | Codex root agent instructions (kept at repo root because Codex auto-loads it) |
| `.ai-rc`, `.k8s-rc` | Sourced by `.commonrc` for AI/k8s shell helpers |

## Cockpit (tmux)

The tmux cockpit (`.tmux.conf`, `.local/src/tmux/`, `.config/tmux-servers/`) has its own docs: [overview](docs/overview.md), [architecture](docs/architecture.md), [deploy](docs/operations/deploy.md), and the key table in `.local/src/tmux/README.md`.

- Build: nothing for the scripts. The Rust parts (`agent-panel`, `hub`) are built by the installer, or `cargo build --release` in their crate under `.local/src/`.
- Run: `stow --no-folding .`, then `tmx ensure hub` and `tmx hop hub`. `Prefix+r` re-reads the config.
- Test: `make -C tests bootstrap` once, then `make -C tests test-fast` (unit + integ, host-safe). The tmux ui tier runs only in the container: `make -C tests test-ui`.
- Standards: `.local/src/tmux/CONVENTIONS.md` (panel rules, each with the test that enforces it).

## Agent runtime

The agent fleet (`agentctl` runners, `agentctl-run`, `agent-queue`, `fleet-dispatch`, `fleet-sessions`, `agent-land`, `agent-ask`) has its own docs: [overview](docs/overview.md#agent-runtime), [architecture](docs/architecture.md#agent-runtime), [deploy](docs/operations/deploy.md#deploying-agent-runtime). Runner confs and runbooks are in the private overlay, at `~/.config/agentctl/`.

- Build: nothing for the scripts. The views (`agent-web`, `hub`, `agent-panel`) are built by the installer, or `cargo build --release` in their crate under `.local/src/`.
- Run: `stow --no-folding .` in both repos, then `agentctl reload` and `agentctl list`. `agentctl pause` stops every oneshot runner, `agentctl resume` lifts it.
- Test: `make -C tests bootstrap` once, then `make -C tests test-fast`, or `make -C tests test-files FILES=unit/runner_contract.bats` for one file. `make -C tests test-rust` covers the crates.
- Standards: `.local/src/docs/standards.md` (each invariant with the test that holds it).

## Submodules

Tracked in `.gitmodules`:

| Submodule | Path | Description |
|---|---|---|
| [android-suite](https://github.com/Kblack0610/android-suite) | `.local/src/android-suite/` | Android device provisioning and debloating |
| [gungan-speak](https://github.com/Kblack0610/gungan-speak) | `.local/src/gungan/` | Gungan voice / TTS helpers |

(`.claude/` and `.local/src/tmux/` are plain directories, not submodules.)

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

- **`.claude/CLAUDE.md`** — workflow rules (plan-first, verification, lessons loop, memory routing).
- **`.claude/agents/`** - subagents, each with an explicit tool ceiling: the generic specialists here (`deep-research-agent`, `technical-writer`, `quality-engineer`, `root-cause-analyst`, `security-engineer`, `compliance-counsel`); the `kb-*` delivery pipeline and `release-coordinator` live in the private overlay. Which ones actually run: `claude-recall stats --kind agent`.
- **`.claude/skills/`** — 53 domain skills invoked by name; the canonical index is the list in `.claude/CLAUDE.md`, which spans both this repo and the private overlay.
- **`.claude/commands/`** - 17 slash commands across four namespaces, counting the private overlay's:
  `/sc:*` (analyze, manual-test, research), `/my:*` (autopilot, fix-ci, go, worktree-recycle), `/kb:*` (workflow, implement, ci), `/daily:*` (analysis, standup, summary), plus `dream` and `remember`.

  These counts are load-bearing only as a rough orientation — treat `ls ~/.claude/{agents,skills,commands}` as the truth, since the live registry merges this repo with the private overlay.
- **`.claude/hooks/`** - Stop-hook gate runs `stop-checks.d/` (git/node/cargo/python/go/shell-test health), then `stop-post.d/` (session register, plan sync to `~/.agent/plans/{project}/`, focus reconcile, anchor regen, ask-filed check, wind-down). Plus PreToolUse guards such as `block-pip.sh` and `large-file-warning.sh`. Topology and the per-script list: `.claude/hooks/README.md`.
- **`.claude/settings.json` / `settings.local.json`** — permissions, env, hook wiring.

The Claude rules and the Codex `AGENTS.md` are deliberately kept in sync via the rulesync source — don't drift one from the other.

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
