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
| Cluster: fleet external-endpoints | `apps/gatus-fleet/configmap.yaml` (`external-endpoints`) | home-config |
| Cluster: shared token secret | `apps/gatus-fleet/fleet-token-secret.sops.yaml` -> deployment env `FLEET_TOKEN` | home-config |
| Per-machine config (endpoint + roster) | `~/.config/fleet-pulse/env` (`GATUS_BASE`, `FLEET_ROSTER`) | dotfiles-private |
| Shared pusher (Linux + Mac) | `~/.local/src/fleet-pulse/push.sh` | dotfiles |
| Linux timer | `~/.config/systemd/user/fleet-pulse.{service,timer}` | dotfiles |
| Linux widget | `~/.config/waybar/fleet_pulse.sh` + `custom/fleet` in `config.{base,desktop,laptop}` | dotfiles |
| Mac pusher (launchd) | `~/.config/launchd/com.kblack.fleet-pulse.plist` (runs `push.sh` FLEET_NAME=mac) | dotfiles |
| Mac widget | `sketchybar/items/fleet.sh` + `plugins/fleet.sh` (+ `sketchybarrc` source) | dotfiles |
| Windows pusher (native only) | `.config/windows/scripts/fleet-push.ps1` + `installation_scripts/windows/setup_fleet_pulse.ps1` | dotfiles |
| Windows-via-WSL pusher | `push.sh` + the systemd user timer, enrolled INSIDE WSL (see below) | dotfiles |
| Windows widget | BLOCKED - zebar pack `kblack-minimal` sources not in repo | dotfiles |

The shared bearer token is one value: encrypted in the cluster secret, and stored
per-machine in the private overlay (`~/.dotfiles-private/.config/fleet-pulse/token`,
stowed to `~/.config/fleet-pulse/token`) - never in the public repo.

`GATUS_BASE`, `FLEET_ROSTER` and `FLEET_GROUP` live beside it in
`~/.config/fleet-pulse/env` and are sourced by `push.sh`, the waybar module, and
the sketchybar plugin - so re-pointing the fleet is ONE edit per machine, not one
per module. The env file uses `${VAR:=default}` so an explicit override from the
caller's environment still wins (plain assignment clobbered it and made the
modules untestable). Windows has no shell env file; it uses `setx GATUS_BASE` /
`setx FLEET_NAME` / `setx FLEET_GROUP` instead.

### FLEET_GROUP: gatus keys are `<group>_<name>`

A host's key is its group AND its name, so `FLEET_GROUP` must match the group the
host is declared under server-side (`homelab` for personal computers, `workplace`
for the work laptop / VDI). **A wrong group is a silent HTTP 404, not an auth
error** - the push just quietly does nothing, and by contract `push.sh` still exits
0. This bit once already: the prefix was hardcoded `fleet_`, so every push 404'd
the moment the fleet grew groups. The log now prints the full key for exactly this
reason - `push failed for linux-cachyos` hid the half of the key that was wrong.

## Deploy (do these in order)

### 1. Cluster (home-config) - REQUIRED FIRST; nothing pushes 200 until this lands

LANDED. `apps/gatus-fleet/configmap.yaml` carries the `external-endpoints` block and
the SOPS `FLEET_TOKEN` secret is deployed; `homelab_linux-cachyos` reports today.
(`apps/gatus` is the separate APPS dashboard - machines live on the `gatus-fleet`
instance at your fleet endpoint. They are two different gatus instances; don't edit
the wrong one.)

Verify (reads the endpoint from your env file rather than hardcoding it):
```bash
. ~/.config/fleet-pulse/env
curl -s "$GATUS_BASE/api/v1/endpoints/statuses" | jq -r '.[].key' | sort
#   homelab_linux-cachyos, workplace_lazer-machine, k3s_pi5-master, android_h0001, ...
```

The single `fleet` group is gone - keys are now `<group>_<name>` across `homelab`,
`workplace`, `k3s`, and `android`. Filtering on `.group=="fleet"` returns nothing.

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
Expect that Mac's key (`homelab_mac-studio` / `homelab_mac-mini`, or
`workplace_gp-mac`) to green on the dashboard and the sketchybar dot to go green.

### 4. Windows

**If you use the box through WSL, enroll INSIDE WSL and stop reading here.** That
covers the VDI, and it is strictly better on it:

```bash
# in WSL (needs [boot] systemd=true in /etc/wsl.conf - install_wsl.sh already writes it)
~/.dotfiles/.local/src/fleet-pulse/enroll.sh --name lazer-machine --group workplace
```

Why not the PowerShell path there:

- **It flashes a console window every 60 seconds and you cannot stop it.** The task
  runs `powershell.exe -WindowStyle Hidden`, but `conhost.exe` allocates and paints
  the console *before* PowerShell parses its own arguments and hides itself. Hidden
  loses the race, 1440 times a day. The real fix is `-LogonType S4U` (session 0, no
  desktop), but that needs `SeBatchLogonRight`, which a locked-down corporate image
  may deny - and a non-persistent VDI may not keep the task across a reboot anyway.
- **WSL needs no Windows admin and no Windows scheduler at all**, so it sidesteps
  both of those. You have root inside WSL, which is all systemd wants.
- It is the same `push.sh` + timer Linux and Mac already run - no Windows-only code
  path to maintain.

The usual objection - *WSL's uptime is not Windows' uptime, so this measures the
wrong thing* - is real on a laptop and void on a VDI: the VDI only exists while you
are logged into it, so "am I in the VDI" IS the liveness question. If you ever use
the machine WITHOUT WSL, that objection comes back and you want the native path.

Two WSL-specific gotchas, both handled by `enroll.sh`:

- **linger.** Without `loginctl enable-linger`, systemd tears the user manager down
  with your last shell, so the heartbeat stops when you close your final terminal
  even though the distro is still up.
- **the proxy.** `.wslconfig`'s `autoProxy=true` exports proxy vars into *login
  shells only*. A systemd unit is started by PID 1 and inherits none of it, so the
  enroll probe (your shell) can pass while every scheduled push (the service)
  fails - and `push.sh` exits 0 by contract, so nothing would ever say so. That is
  why `enroll.sh` re-verifies through the unit's own journal, not the probe. If it
  reports PARTIAL, put the proxy in `~/.config/environment.d/`, which the systemd
  user manager *does* read.

#### Native Windows (no WSL)

```powershell
# set the shared token once (same value as the cluster secret):
setx FLEET_TOKEN "<the-token>"
# the endpoint has no usable default in the public repo - REQUIRED.
# use the same value as GATUS_BASE in ~/.config/fleet-pulse/env on Linux/Mac:
setx GATUS_BASE "https://fleet.your.lan"
# only if this host is not the plain 'windows' key (e.g. a work laptop or VDI):
setx FLEET_NAME "work-laptop"
# the group this host is declared under server-side. workplace for work boxes,
# homelab for a personal desktop. Wrong group = silent 404.
setx FLEET_GROUP "workplace"
# re-open the shell so the env vars land, then register the 1-min Scheduled Task:
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\setup_fleet_pulse.ps1
Start-ScheduledTask -TaskName fleet-pulse
```
Expect that host to green on the dashboard.

### Managed / corporate hosts: you do NOT need the dotfiles

`fleet-push.ps1` is self-contained - four env vars and one HTTPS POST. Nothing else
in this repo is involved at run time, so a work laptop or VDI does not need a
personal dotfiles checkout just to send a heartbeat (and having one on a monitored
machine is clutter you would rather not have to explain). Drop that single file
anywhere and point the installer at it:

```powershell
setx FLEET_TOKEN "<the-token>" ; setx GATUS_BASE "https://fleet.your.lan"
setx FLEET_NAME "work-laptop"  ; setx FLEET_GROUP "workplace"
# re-open the shell, then PROBE FIRST - never register a task that pushes into the void:
powershell -ExecutionPolicy Bypass -File C:\path\to\fleet-push.ps1
#   expect: fleet-pulse: pushed workplace_work-laptop success=true
powershell -ExecutionPolicy Bypass -File .\setup_fleet_pulse.ps1 -PushScript C:\path\to\fleet-push.ps1
Start-ScheduledTask -TaskName fleet-pulse
```

The task registers at `RunLevel Limited` / `LogonType Interactive` - a user-level
task needing no admin rights, which is what makes it viable on a managed corporate
machine. **The cost of `Interactive` is the 60s console flash** (see above); it buys
no-admin, and on a box you drive through WSL that trade is not worth making. Probe a
managed host in this order before assuming it works: push once by hand and confirm
HTTP 200, then confirm the task registers, then reboot and confirm
`Get-ScheduledTask fleet-pulse` survives (a non-persistent VDI may not keep it).

Zebar widget: still blocked. The `kblack-minimal` pack referenced by
`.config/windows/zebar/settings.json` isn't in the repo. To finish the Windows
GLYPH: locate the pack under `%USERPROFILE%\.glzr\zebar\`, add its sources to the
repo, then inject a small element that fetches `/api/v1/endpoints/statuses`,
filters the `fleet` group, and colors a dot (green/amber/red) with the same
freshness rule. The pusher above works regardless.

## Reading the token / rotating it

The token lives encrypted at `apps/gatus-fleet/fleet-token-secret.sops.yaml`. To read
it (e.g. to set `FLEET_TOKEN` on Windows):
```bash
sops -d ~/dev/home/home-config/apps/gatus-fleet/fleet-token-secret.sops.yaml | grep FLEET_TOKEN
```
To rotate: regenerate, re-encrypt the secret, and update the per-machine token files.

One shared token currently authenticates every machine, which means any holder can
forge a heartbeat for any host in the fleet. That is tolerable while the holders
are all machines you own; it stops being tolerable once the token sits on a
corporate-managed laptop and a VDI. Per-device tokens are the planned follow-up -
gatus supports a distinct `token:` per external-endpoint, so the change is
server-side config plus a different value in each machine's token file.
