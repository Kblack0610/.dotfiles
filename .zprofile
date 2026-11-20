# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# Profile-based startup (only on TTY, not SSH or existing graphical session)
if [[ -z "$SSH_CONNECTION" && -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" ]]; then
    if [[ -f "$HOME/.local/bin/profile-apply" ]]; then
        source "$HOME/.local/bin/profile-apply"
    fi
fi

# ~/.local/bin for login shells that never read .zshrc (zsh -lc); .zshrc adds it for interactive ones.
path=("$HOME/.local/bin" ${path:#$HOME/.local/bin})
