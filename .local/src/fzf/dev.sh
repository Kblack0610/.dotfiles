#!/usr/bin/env zsh 
# Specify additional directories to search for
dirs=(
  "$HOME/.dotfiles"
  "$HOME/.notes"
  "$HOME/dev"
  "$HOME/Work"
  # "$HOME/Documents"
  # "$HOME/bin"
  # "$HOME/dev/*"
  # "$HOME/Work/*"
  # Add more directories as needed
)

# Specify directories to exclude from search
blacklist_dirs=(
  # Add directories you want to exclude
  # "$HOME/.dotfiles/backup"
  # "$HOME/dev/archived_projects"
  # "$HOME/Work/legacy"
)

# Build the find command with exclusions
find_cmd="find ${dirs[@]} -not -path \"*/\.git/*\" -not -path \"*/\node_modules/*\""

# Add blacklist directories to exclusions
for blacklist_dir in "${blacklist_dirs[@]}"; do
  if [ -n "$blacklist_dir" ]; then
    find_cmd+=" -not -path \"$blacklist_dir/*\""
  fi
done

# Execute the find command and pipe to fzf
dir=$(eval "$find_cmd" -print 2> /dev/null | fzf)

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
