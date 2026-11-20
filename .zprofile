# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# ~/.local/bin for login shells that never read .zshrc (zsh -lc), set before profile-apply runs;
# typeset -U keeps .zshrc's own prepend from listing it twice in an interactive login shell.
typeset -U path PATH
path=("$HOME/.local/bin" $path)

# Profile-based startup (only on TTY, not SSH or existing graphical session)
if [[ -z "$SSH_CONNECTION" && -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" ]]; then
    if [[ -f "$HOME/.local/bin/profile-apply" ]]; then
        source "$HOME/.local/bin/profile-apply"
    fi
fi
