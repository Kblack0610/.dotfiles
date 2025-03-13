Need to install dconf for linux, set up flatpak and brew process for any remaining work needed

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

# Mac reqs
- Preferences -> Apperance: Dark, Accent Color: Purple
- System Settings -> Keyboard, Set Key Repeat to "Fast" and Delay until repeat to "Short" (haven't tried this yet)
- System Settings -> Shortcuts, Add App Shortcuts "Minimize" and "Minimise" to random long key combos to overwrite cmd+m
- System Settings -> Control Center, Set Automatically hide and show menu bar to "Always"
- System Settings -> Control Center -> Soundm Set to "Always show in menu bar"
- [Raycast](https://www.raycast.com/)
    - Disabled Spotlight search in keyboard shortcuts
    - Import config from `.dotfiles/mac/Raycast.rayconfig`
- [Aerospace](https://github.com/nikitabobko/AeroSpace)

# Linux reqs
have various build scripts to install tools and dependencies. need to clean up flow for that.
-  install picom, spicetify (for spotify), i3, and i3status 

# Audio
- alsamixer
- pavucontrol (volume control)
- audacity (mixing)
- pipewire (audio)


# Keyboards 
-- make sure to set up in src file
qmk setup kblack0610/qmk_firmware -H ~/src/qmk_firmware


