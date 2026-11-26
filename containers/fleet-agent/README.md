# fleet-agent

The whole agent runtime in one image, so a fleet worker runs on any Linux box with docker. The image is `fleet-node install` (the same definition a native host runs) behind sshd. CI publishes `ghcr.io/kblack0610/fleet-agent:<sha>` and `:latest` on every main merge that touches it, and nightly with the rest of main (`.github/workflows/fleet-agent.yml`). One tag pins the whole runtime. While the package is private, a box runs `docker login ghcr.io` once before `fleet-agent up`.

## Run a worker

```bash
fleet-agent up          # pull and start; docker restarts it after a reboot. A changed image or setting replaces it, ending its tmux sessions
fleet-agent status      # container, image, and what is left to sign in
fleet-agent shell       # sign in here: gh auth login, then clone the private overlay
fleet-agent down        # remove the container; volumes and logins stay
```

Each Claude account signs in with its setup token, pushed from a machine with rbw unlocked: `claude-acct token push <host>`, where `<host>` is an ssh alias for the container's port. No `/login` runs in the container.

Then add the box to `fleet_workers` in home-config's inventory with `ansible_port: 2223`. `fleet-dispatch hosts` reads it ready once `wt` is on PATH and `~/.agent` is a peer store (`store-sync join`) and `~/.notes` is a clone (`notes-sync-bootstrap.sh`), and lists `claude` in its kit once `fleet-node ready claude` passes inside.

## Build and test it

```bash
docker build -f containers/fleet-agent/Containerfile -t fleet-agent:dev .   # from the repo root, about 5 min
tests/fleet-agent-smoke.sh fleet-agent:dev                                 # what CI runs; throwaway volumes only
```

`~/.dotfiles` inside is a snapshot of one commit's files with no git history (`~/.fleet-agent-rev` names the commit and the build time), so the installer skips submodules and git hooks there.

## What lives where

| Path | Owner | Survives a new image |
| --- | --- | --- |
| `/home/kblack0610` | volume `fleet-agent-home` | yes: account tokens (`~/.config/claude-acct/tokens`), `~/.claude*`, `~/.claude.json`, gh, repo clones, `~/.agent` |
| `~/.dotfiles`, `~/.local/{bin,lib,share/claude}`, `~/.cargo/bin`, `~/.rustup` | the image (`/opt/fleet/home`) | replaced by the entrypoint when the image changes |
| `/etc/ssh/keys` | volume `fleet-agent-hostkeys` | yes, so known_hosts keeps matching |
| `~/.ssh` | the home volume, writable (known_hosts, a deploy key) | yes |
| `/etc/ssh/authorized_keys/kblack0610` | the host's `~/.ssh/authorized_keys` (`FLEET_AGENT_KEYS`), mounted read-only and copied root-owned at each start | it is the host's; no private key enters the container |

HOME is one volume because Claude rewrites `~/.claude.json` by rename, so a mount of that one file would break. The entrypoint syncs the image seed into HOME only when the image changed: the dotfiles tree mirrors exactly, the tools refresh, everything else only fills gaps, so a login is never overwritten.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `fleet-dispatch hosts` lists no claude in the worker's kit | an account has no token in the container | `fleet-agent status` names it; `claude-acct token push <host>` from a machine with rbw |
| `fleet-dispatch hosts` reads the worker not ready | no peer store (`~/.agent/.sync/peer`) | `fleet-agent shell`, then `store-sync join` |
| `fleet-dispatch hosts` says the worker has no `~/.notes` clone | the vault was never cloned there | run `.local/src/git/notes-sync-bootstrap.sh` in the container |
| Every account signed out after a `docker volume rm` | the logins were in that volume | sign in again; `fleet-agent down` never removes volumes |
| `nproc` inside reads the whole box | started without `fleet-agent` | `fleet-agent down && fleet-agent up`; it sets a cpuset |
| `fleet-agent up` says it could not pull and there is no local copy | the GHCR package is private and this box is not logged in | `docker login ghcr.io` with a token that can read packages, or make the package public |
| ssh is refused after the host's authorized_keys changed | the entrypoint copies it at start | `docker restart fleet-agent` |
| `docker logs fleet-agent` shows `the sync failed` | a stow conflict or rsync error in the home volume; sshd still started | ssh in, clear the conflicting file, `docker restart fleet-agent`; the sync reruns until it completes |
