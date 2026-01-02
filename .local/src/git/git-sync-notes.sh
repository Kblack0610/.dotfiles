#!/bin/bash
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_notes_sync -o IdentitiesOnly=yes -o BatchMode=yes"

cd "$HOME/.notes" || exit 1

git pull origin master || true
git add .
git commit -m "Auto-commit $(date +%Y-%m-%d)" || true
git push origin master
