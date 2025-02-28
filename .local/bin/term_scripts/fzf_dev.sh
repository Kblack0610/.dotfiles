#!/usr/bin/env zsh 
# Specify additional directories to search for
dirs=(
  "$HOME/.dotfiles"
  "$HOME/bin"
  "$HOME/dev"
  "$HOME/dev/*"
  "$HOME/Work"
  "$HOME/Work/*"
  "$HOME/Documents"
  # Add more directories as needed
)

# dir=$(find "${dirs[@]}" -maxdepth 4 -type d -not -path "*/\.git/*" -not -path "*/\node_modules/*" -print 2> /dev/null | fzf)
dir=$(find "${dirs[@]}" -not -path "*/\.git/*" -not -path "*/\node_modules/*" -print 2> /dev/null | fzf)

if [ -n "$dir" ]; then
    if [ -f "$dir" ]; then
      # echo "It's a file"
      cd "$(dirname $dir)" || echo "Failed to change directory to: $dir"
      nvim "$dir" || echo "Failed to change directory to: $dir"
    else
      # echo "It's not a file"
      cd "$dir" || echo "Failed to change directory to: $dir"
    fi
else
  echo "No directory selected"
fi
