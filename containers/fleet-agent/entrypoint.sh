#!/bin/sh
# fleet-agent-entrypoint: install the host's authorized keys, sync the image's seed into the HOME
# volume, then run sshd. What the image owns follows the image: the dotfiles tree exactly, the
# installed tools refreshed. Everything else in the seed only fills gaps, so a login, a repo clone
# or ~/.agent is never overwritten. The sync runs only when the volume was last synced from another
# image, and a failed one still starts sshd, so the worker stays reachable to fix it.
set -eu
user=${FLEET_USER:?}
home=/home/$user
seed=/opt/fleet/home

[ -s /etc/ssh/keys/ssh_host_ed25519_key ] ||
  ssh-keygen -q -t ed25519 -N '' -C "fleet-agent@$(hostname)" -f /etc/ssh/keys/ssh_host_ed25519_key

# A root-owned copy, so sshd's StrictModes passes whatever uid owns the file on the host.
install -D -m 644 /etc/fleet-agent/authorized_keys "/etc/ssh/authorized_keys/$user" ||
  echo "fleet-agent: no /etc/fleet-agent/authorized_keys mounted; no one can ssh in" >&2

if ! cmp -s "$seed/.fleet-agent-rev" "$home/.fleet-agent-rev"; then
  echo "fleet-agent: syncing $(cat "$seed/.fleet-agent-rev") into $home"
  chown "$user:" "$home"
  # The rev is copied last, so a sync that stops part way runs again on the next start.
  runuser -u "$user" -- sh -eu -c '
    seed=$1 home=$2
    export HOME=$home
    rsync -a --delete "$seed/.dotfiles/" "$home/.dotfiles/"
    for d in .local/bin .local/share/claude .local/lib .cargo/bin .rustup; do
      [ -d "$seed/$d" ] || continue
      mkdir -p "$home/$d" && rsync -a "$seed/$d/" "$home/$d/"
    done
    rsync -a --ignore-existing --exclude=.fleet-agent-rev "$seed/" "$home/"
    cd "$home/.dotfiles" && stow --no-folding --restow .
    # the installer links skills the same way (deploy_skills), so a new or renamed one reaches the volume
    .local/bin/skill-deploy --adopt --quiet || echo "fleet-agent: skill-deploy reported conflicts" >&2
    cp "$seed/.fleet-agent-rev" "$home/.fleet-agent-rev"
  ' sync "$seed" "$home" ||
    echo "fleet-agent: the sync failed (above); sshd starts anyway, fix it over ssh and restart" >&2
fi

exec /usr/sbin/sshd -D -e
