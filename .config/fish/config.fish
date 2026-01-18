source /usr/share/cachyos-fish-config/cachyos-config.fish
# cowsay "hello"
# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end

# Fish Shell Configuration

#SSH
# if test -z (pgrep ssh-agent)
#     eval (ssh-agent -c)
#     set -Ux SSH_AUTH_SOCK $SSH_AUTH_SOCK
#     set -Ux SSH_AGENT_PID $SSH_AGENT_PID
# end
trap "kill $SSH_AGENT_PID" exit
trap "ssh-agent -k" exit
if test -z (pgrep ssh-agent | string collect)
    eval (ssh-agent -c)
    set -Ux SSH_AUTH_SOCK $SSH_AUTH_SOCK
    set -Ux SSH_AGENT_PID $SSH_AGENT_PID
end

# This file is based on the user's .zshrc settings.

# --- Zsh-like Configuration ---
# Fish doesn't have themes like Zsh, but we can use Starship for the prompt.
# eval "$(starship init fish)" is handled by Starship's own setup.

# --- History Settings ---
# Fish manages history automatically, but we can set limits.
set -g fish_history_max_size 5000

# Fish also handles duplicate history entries and history sharing automatically,
# so no specific commands are needed for those Zsh options.

# --- Plugins and Sourcing ---
# Fish has its own plugin manager. The most common is Fisher.
# You would need to install Fisher first: curl -sL https://git.io/fisher | source
# Then install plugins like this: fisher install <plugin-name>
# These plugins are similar to the ones you had in Zsh:
# fisher install jethrokuan/z (for zsh-autosuggestions equivalent)
# fisher install edc/bass (for sourcing bash scripts, if needed)

# Sourcing zsh-syntax-highlighting and fzf
# Fish has built-in autosuggestions and syntax highlighting, so you don't need these.
# fzf for Fish is usually installed separately and adds its own functions.
# [ -f ~/.fzf.fish ] && source ~/.fzf.fish

# Autojump
# The autojump package for Fish typically installs its own configuration.
# The following line would be needed if it doesn't:
# source /usr/share/autojump/autojump.fish

# --- Key Bindings and Editor Mode ---
# Fish handles vi-mode with a single command.
fish_vi_key_bindings

# Ctrl-P, Ctrl-N, and Ctrl-R mappings
# Fish has built-in history search, but we can rebind them.
bind \cn history-search-forward
bind \cp history-search-backward
bind \cr history-search-backward

# --- Environment Variables ---
# Use `set -x` to export environment variables.
set -x ZSH_DISABLE_COMPFIX "true"
set -x HISTSIZE 5000
set -x HISTFILE ~/.zsh_history
set -x SAVEHIST 5000
set -x HISTDUP "erase"
set -x KEYTIMEOUT 1
set -x MANPAGER "/snap/nvim/current/usr/bin/nvim +Man!"
set -x MANWIDTH 999
set -x UNITY_PATH "$HOME/src/Unity/Hub/Editor/6000.0.43f1/Editor/Unity"
set -x NVM_DIR "$HOME/.nvm"
set -x XDG_CONFIG_HOME "$HOME/.config"

# Sourcing nvm, if it exists
if test -f "$NVM_DIR/nvm.sh"
    source "$NVM_DIR/nvm.sh"
end

# Add golang to path if it is installed
if test -d "/usr/local/go/bin"
    set -x PATH $PATH /usr/local/go/bin
end

# Add other tool paths
set -x PATH $PATH $HOME/.maestro/bin
set -x PATH $PATH $HOME/src/go/bin/bluetuith
set -x PATH $PATH $HOME/.npm-global/bin

# --- Aliases ---
# Use the `abbr` command for simple aliases (abbreviations).
abbr nvr "nvr . -s"
abbr n "nvim ."
abbr g "git"
abbr f ". $HOME/.local/src/fzf/dev.sh"
abbr h ". $HOME/.local/src/fzf/history.sh"
abbr e "exit"
abbr vi "nvim --listen /tmp/nvim-server.pipe"
abbr ct "kitty @ set-tab-title"
abbr lg "lazygit"
abbr sysz "$HOME/.bin/sysz"
abbr python "/usr/bin/python3"

# --- Functions ---
# For more complex scripts, create a function.
function x11-clip-wrap-widgets
    # Fish doesn't have widgets like Zsh. This function's logic would need to be
    # re-implemented using Fish's event handlers or hooks, which is more complex.
    # It is not a direct one-to-one translation.
end

# Check for cowsay and fortune at startup
if test -x /usr/games/cowsay -a -x /usr/games/fortune
    fortune | cowsay
else if test -x /opt/homebrew/bin/cowsay -a -x /opt/homebrew/bin/fortune
    fortune | cowsay
end

# Sourcing .bash_profile
# if test -f "$HOME/.bash_profile"
#     source "$HOME/.bash_profile"
# end

# Set local NPM package directory and add to path
set -x NPM_PACKAGES "$HOME/.npm-packages"
set -x NODE_PATH "$NPM_PACKAGES/lib/node_modules" $NODE_PATH
set -x PATH "$NPM_PACKAGES/bin" $PATH

# Manually unset and set MANPATH
set -e MANPATH
set -x MANPATH "$NPM_PACKAGES/share/man" (manpath)
