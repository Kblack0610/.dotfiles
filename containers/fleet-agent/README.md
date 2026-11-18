# fleet-agent

The whole agent runtime in one image, so a fleet worker runs on any Linux box with docker. The image is `fleet-node install` (the same definition a native host runs) behind sshd. CI publishes `ghcr.io/kblack0610/fleet-agent:<sha>` and `:latest` on every main merge that touches it (`.github/workflows/fleet-agent.yml`). One tag pins the whole runtime.

## Run a worker

```bash
fleet-agent up          # pull and start; docker restarts it after a reboot
fleet-agent status      # container, image, and what is left to sign in
fleet-agent shell       # sign in here: claude then /login (per account), gh auth login
fleet-agent down        # remove the container; volumes and logins stay
```

Then add the box to `fleet_workers` in home-config's inventory with `ansible_port: 2223`. `fleet-dispatch hosts` reads it `open` once `fleet-node ready` passes inside.

## What lives where

| Path | Owner | Survives a new image |
| --- | --- | --- |
| `/home/kblack0610` | volume `fleet-agent-home` | yes: Claude accounts, `~/.claude.json`, gh, repo clones, `~/.agent` |
| `~/.dotfiles`, `~/.local/{bin,lib,share/claude}`, `~/.cargo/bin`, `~/.rustup` | the image (`/opt/fleet/home`) | replaced by the entrypoint when the image changes |
| `/etc/ssh/keys` | volume `fleet-agent-hostkeys` | yes, so known_hosts keeps matching |
| `~/.ssh` | the host's, read-only | it is the host's |

HOME is one volume because Claude rewrites `~/.claude.json` by rename, so a mount of that one file would break. The entrypoint syncs the image seed into HOME only when the image changed: the dotfiles tree mirrors exactly, the tools refresh, everything else only fills gaps, so a login is never overwritten.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `fleet-dispatch hosts` says "something to sign in" | an account, gh, the overlay or the store is missing | `fleet-agent status`, then `fleet-agent shell` and do each line |
| Every account signed out after a `docker volume rm` | the logins were in that volume | sign in again; `fleet-agent down` never removes volumes |
| `nproc` inside reads the whole box | started without `fleet-agent` | `fleet-agent down && fleet-agent up`; it sets a cpuset |
