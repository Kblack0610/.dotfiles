#!/bin/sh
# fleet-agent-entrypoint: sync the image's seed into the HOME volume, then run sshd.
# What the image owns follows the image: the dotfiles tree exactly, the installed tools refreshed.
# Everything else in the seed only fills gaps, so a login, a repo clone or ~/.agent is never
# overwritten. The sync runs only when the volume was last synced from another image.
set -eu
user=${FLEET_USER:?}
home=/home/$user
seed=/opt/fleet/home

[ -s /etc/ssh/keys/ssh_host_ed25519_key ] ||
  ssh-keygen -q -t ed25519 -N '' -C "fleet-agent@$(hostname)" -f /etc/ssh/keys/ssh_host_ed25519_key

if ! cmp -s "$seed/.fleet-agent-rev" "$home/.fleet-agent-rev"; then
  echo "fleet-agent: syncing $(cat "$seed/.fleet-agent-rev") into $home"
  chown "$user:" "$home"
  runuser -u "$user" -- sh -eu -c '
    seed=$1 home=$2
    rsync -a --delete "$seed/.dotfiles/" "$home/.dotfiles/"
    for d in .local/bin .local/share/claude .local/lib .cargo/bin .rustup; do
      [ -d "$seed/$d" ] || continue
      mkdir -p "$home/$d" && rsync -a "$seed/$d/" "$home/$d/"
    done
    rsync -a --ignore-existing --exclude=.fleet-agent-rev "$seed/" "$home/"
    cd "$home/.dotfiles" && stow --no-folding --restow .
    cp "$seed/.fleet-agent-rev" "$home/.fleet-agent-rev"
  ' sync "$seed" "$home"
fi

exec /usr/sbin/sshd -D -e
