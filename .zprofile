# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# ~/.local/bin and rustup's ~/.cargo/bin for login shells that never read .zshrc (zsh -lc, agent
# sessions), set before profile-apply runs. Without cargo/bin a distro /usr/bin/cargo wins and
# tests/rust.sh cannot find rustup to honor tests/rust-toolchain (razer-laptop, hc-1096).
# typeset -U keeps .zshrc's own prepends from listing them twice in an interactive login shell.
typeset -U path PATH
path=("$HOME/.local/bin" "$HOME/.cargo/bin" $path)

# Profile-based startup (only on TTY, not SSH or existing graphical session)
if [[ -z "$SSH_CONNECTION" && -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" ]]; then
    if [[ -f "$HOME/.local/bin/profile-apply" ]]; then
        source "$HOME/.local/bin/profile-apply"
    fi
fi
