# Dotfiles

Personal dotfiles managed with GNU Stow and git submodules.

## Submodules

This repo uses git submodules for reusable tools:

| Submodule | Location | Description |
|-----------|----------|-------------|
| [claude-config](https://github.com/Kblack0610/claude-config) | `.claude/` | Claude Code configuration with 27 agents, 26+ commands, and MCP servers |
| [claude-wrapper](https://github.com/Kblack0610/claude-wrapper) | `tools/claude-wrapper/` | Multi-account rotation wrapper for Claude CLI |
| [android-suite](https://github.com/Kblack0610/android-suite) | `.local/src/android-suite/` | Android device provisioning and debloating suite |
| [tmux-suite](https://github.com/Kblack0610/tmux-suite) | `.local/src/tmux/` | Tmux productivity scripts (1800+ lines) for agent orchestration and session management |

## Installation

Clone with submodules:

```bash
git clone --recursive https://github.com/Kblack0610/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
stow .
```

Or if already cloned, initialize submodules:

```bash
git submodule update --init --recursive
```

## Updating Submodules

```bash
# Update all submodules to latest
git submodule update --remote --merge

# Or update specific submodule
git submodule update --remote .claude
```

## For installation

Dotfiles use stow to symlink to proper config locations

reqs for installation (not complete):
- Install [Floorp (firefox based browser)](https://floorp.app/en)
- Install [Kitty Terminal](https://sw.kovidgoyal.net/kitty/binary/) (best kitty [icon](https://github.com/DinkDonk/kitty-icon))
- Install [Stow](https://formulae.brew.sh/formula/stow)
- Install [zsh](https://github.com/ohmyzsh/ohmyzsh/wiki/Installing-ZSH)
- Install [oh-my-zsh](https://ohmyz.sh/#install)
- Install zsh-autosuggestions and zsh-syntax-highlighting
    clone the repos to .oh-my-zsh/custom/plugins
    - [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)
    - [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
- Install [Hack Font(NOT patched)](https://sourcefoundry.org/hack/)
- Install [Nerd Font(Symbols ONLY)](https://www.nerdfonts.com/font-downloads) - Kitty doesnt require patched fonts, only symbols is fine
- Install [Neovim](https://github.com/neovim/neovim/blob/master/INSTALL.md)
- Install [Tmux](https://github.com/tmux/tmux/wiki)
- Install [fzf](https://github.com/junegunn/fzf?tab=readme-ov-file#using-git)
- Install [ripgrep](https://github.com/BurntSushi/ripgrep)
- Install [lazygit](https://github.com/jesseduffield/lazygit)

once stow is installed, run "stow ." to symlink

# Post-stow setup

Some configs can't be symlinked (random profile names). Run these after stow:

```bash
# Firefox/Floorp - bottom tabs + Catppuccin theme
~/.dotfiles/.config/firefox/install.sh
```

# Keyboards 
-- make sure to set up in src file
qmk setup kblack0610/qmk_firmware -H ~/src/qmk_firmware

filesystem:
- bin : apps
- src : source
- dev: projects
- .local/bin: scripts
- media: music, videos, etc
- tmp: for temp files

required by ubuntu:
- Documents
- Downloads
- snap (fuck snap)
