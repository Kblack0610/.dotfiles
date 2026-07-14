# fleet-pulse

One shared "my whole setup is healthy" glyph across every machine's status bar:
Linux (Waybar), Mac (SketchyBar), Windows (GlazeWM/Zebar).

## How it works

Each machine PUSHES a liveness heartbeat every 60s to gatus (a token-authed
external-endpoint per host, all in the `fleet` group). Each machine's status bar
then POLLS the gatus statuses API and renders ONE glyph, judging freshness itself:

- green  = every ROSTER host reported success AND within 180s
- amber  = >=1 host never-reported/stale/failing (API still reachable)
- red    = statuses API unreachable

Staleness is computed bar-side (not by gatus), so a pusher that dies leaves a
stale last-result and correctly shows amber. No machine depends on another being
awake - an off machine just goes amber on the others.

### The roster is load-bearing

`FLEET_ROSTER` (in `~/.config/fleet-pulse/env`) is the list of machines that
SHOULD be reporting. The bars count against it rather than against the API's own
rows, and that distinction is the whole ballgame:

**Gatus only materializes an external-endpoint when it receives that host's FIRST
push.** A machine that is configured server-side but has never enrolled is not
"stale" and not "failing" - it is absent from `/api/v1/endpoints/statuses`
entirely. Deriving the roster from the API therefore drew the denominator from the
same set as the numerator: every host present was a host that had pushed, so
`healthy == total` held trivially and the glyph went GREEN while four of five
machines had never been heard from once. The bug hid itself.

So: absent from the API + present in the roster = `NEVER REPORTED` = amber.

If `FLEET_ROSTER` is unset the bars fall back to the API-derived list (the old
behaviour) and say so in the tooltip - it cannot see an unenrolled host, so treat
it as a degraded mode, not a default.

```
[Linux]      --push--\
[Mac]        --push---\
[Windows]    --push----> gatus external-endpoints (fleet group)
[work-laptop]--push---/            |
[vdi]        --push--/             v
       each machine's bar --poll /api/v1/endpoints/statuses--> one glyph
                                   ^
                    counted against FLEET_ROSTER, not against this list
```

## Components

| Piece | Path | Repo |
|-------|------|------|
| Cluster: fleet external-endpoints | `apps/gatus/configmap.yaml` (`external-endpoints`) | home-config |
| Cluster: shared token secret | `apps/gatus/fleet-token-secret.sops.yaml` -> deployment env `FLEET_TOKEN` | home-config |
| Per-machine config (endpoint + roster) | `~/.config/fleet-pulse/env` (`GATUS_BASE`, `FLEET_ROSTER`) | dotfiles-private |
| Shared pusher (Linux + Mac) | `~/.local/src/fleet-pulse/push.sh` | dotfiles |
| Linux timer | `~/.config/systemd/user/fleet-pulse.{service,timer}` | dotfiles |
| Linux widget | `~/.config/waybar/fleet_pulse.sh` + `custom/fleet` in `config.{base,desktop,laptop}` | dotfiles |
| Mac pusher (launchd) | `~/.config/launchd/com.kblack.fleet-pulse.plist` (runs `push.sh` FLEET_NAME=mac) | dotfiles |
| Mac widget | `sketchybar/items/fleet.sh` + `plugins/fleet.sh` (+ `sketchybarrc` source) | dotfiles |
| Windows pusher | `.config/windows/scripts/fleet-push.ps1` + `installation_scripts/windows/setup_fleet_pulse.ps1` | dotfiles |
| Windows widget | BLOCKED - zebar pack `kblack-minimal` sources not in repo | dotfiles |

The shared bearer token is one value: encrypted in the cluster secret, and stored
per-machine in the private overlay (`~/.dotfiles-private/.config/fleet-pulse/token`,
stowed to `~/.config/fleet-pulse/token`) - never in the public repo.

`GATUS_BASE` and `FLEET_ROSTER` live beside it in `~/.config/fleet-pulse/env` and
are sourced by `push.sh`, the waybar module, and the sketchybar plugin - so
re-pointing the fleet is ONE edit per machine, not one per module. The env file
uses `${VAR:=default}` so an explicit override from the caller's environment still
wins (plain assignment clobbered it and made the modules untestable). Windows has
no shell env file; it uses `setx GATUS_BASE` / `setx FLEET_NAME` instead.

## Deploy (do these in order)

### 1. Cluster (home-config) - REQUIRED FIRST; nothing pushes 200 until this lands

LANDED. `apps/gatus/configmap.yaml` carries the `external-endpoints` block and the
SOPS `FLEET_TOKEN` secret is deployed; `fleet_linux-cachyos` reports today.

Verify (reads the endpoint from your env file rather than hardcoding it):
```bash
. ~/.config/fleet-pulse/env
curl -s "$GATUS_BASE/api/v1/endpoints/statuses" | jq -r '.[] | select(.group=="fleet") | .key'
```

Note that only hosts which have pushed at least once appear there - that is the
behaviour the roster exists to compensate for.

### 2. Linux (this machine) - already applied + verified

Pusher, timer, and waybar module are live.

Manual checks:
```bash
~/.local/src/fleet-pulse/push.sh            # expect HTTP 200
systemctl --user list-timers fleet-pulse.timer
~/.config/waybar/fleet_pulse.sh             # amber until every roster host enrolls
```

### 3. Mac

The dotfiles (incl. `push.sh`, sketchybar items, plist) sync via the normal
dotfiles path; the token arrives via the private overlay. Then:
```bash
launchctl load -w ~/Library/LaunchAgents/com.kblack.fleet-pulse.plist   # or your load path
sketchybar --reload
```
Expect `fleet_mac` to green on the dashboard and the sketchybar dot to go green.

### 4. Windows

```powershell
# set the shared token once (same value as the cluster secret):
setx FLEET_TOKEN "<the-token>"
# the endpoint has no usable default in the public repo - REQUIRED.
# use the same value as GATUS_BASE in ~/.config/fleet-pulse/env on Linux/Mac:
setx GATUS_BASE "https://fleet.your.lan"
# only if this host is not the plain 'windows' key (e.g. a work laptop or VDI):
setx FLEET_NAME "work-laptop"
# re-open the shell so the env vars land, then register the 1-min Scheduled Task:
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\setup_fleet_pulse.ps1
Start-ScheduledTask -TaskName fleet-pulse
```
Expect `fleet_windows` to green on the dashboard.

The task registers at `RunLevel Limited` / `LogonType Interactive` - a user-level
task needing no admin rights, which is what makes it viable on a managed corporate
machine. Probe a managed host in this order before assuming it works: push once by
hand and confirm HTTP 200, then confirm the task registers, then reboot and confirm
`Get-ScheduledTask fleet-pulse` survives (a non-persistent VDI may not keep it).

Zebar widget: still blocked. The `kblack-minimal` pack referenced by
`.config/windows/zebar/settings.json` isn't in the repo. To finish the Windows
GLYPH: locate the pack under `%USERPROFILE%\.glzr\zebar\`, add its sources to the
repo, then inject a small element that fetches `/api/v1/endpoints/statuses`,
filters the `fleet` group, and colors a dot (green/amber/red) with the same
freshness rule. The pusher above works regardless.

## Reading the token / rotating it

The token lives encrypted at `apps/gatus/fleet-token-secret.sops.yaml`. To read it
(e.g. to set `FLEET_TOKEN` on Windows):
```bash
sops -d ~/dev/home/home-config/apps/gatus/fleet-token-secret.sops.yaml | grep FLEET_TOKEN
```
To rotate: regenerate, re-encrypt the secret, and update the per-machine token files.

One shared token currently authenticates every machine, which means any holder can
forge a heartbeat for any host in the fleet. That is tolerable while the holders
are all machines you own; it stops being tolerable once the token sits on a
corporate-managed laptop and a VDI. Per-device tokens are the planned follow-up -
gatus supports a distinct `token:` per external-endpoint, so the change is
server-side config plus a different value in each machine's token file.
