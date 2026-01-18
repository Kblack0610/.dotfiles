# For installation

dotfiles, use stow to symlink to proper config locations

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
