# if set to "random", it will load a random themeto know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="robbyrussell"
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell", "agnoster" )

# Stop insecure messages
ZSH_DISABLE_COMPFIX="true"

# NOTE: need to put bindkey -vi and plugins after importing oh-my-zsh
export ZSH="${HOME}/.oh-my-zsh"
source $ZSH/oh-my-zsh.sh

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Disable use of ! and !! for commands
# This can interfere when ! is used in other commands, just disabling as I dont use ! or !!
setopt NO_HIST_EXPAND

# LANGUAGES

# node version manager
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

# Add golang to path if it is installed
if [ -d "/usr/local/go/bin" ]; then
    export PATH=$PATH:/usr/local/go/bin
fi

#Tmux
if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ]; then
  exec tmux
fi

[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
)

# load .bash_profile
if [ -f $HOME/.bash_profile ]; then 
    . $HOME/.bash_profile;
fi

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# vi mode
bindkey -v
# fix small delay when entering vi mode
# https://www.reddit.com/r/vim/comments/60jl7h/zsh_vimode_no_delay_entering_normal_mode/
KEYTIMEOUT=1
# ctrl-p & ctrl-n to behave like arrow keys
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search
bindkey '^R' history-incremental-search-backward


