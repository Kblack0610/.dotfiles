# kernel-modules-hook (Arch, CachyOS)

A kernel upgrade without a reboot removes `/usr/lib/modules/$(uname -r)`, the modules of the kernel still running. Anything that needs a module loaded after that fails until the next boot: on 2026-11-18 the xpad gamepad driver would not load. `kernel-modules-hook` (Arch `extra`) keeps that tree in place.

## Setup

`setup_kernel_modules_hook` in `.local/src/installation_scripts/linux/install_arch.sh` does it, as the `kernelmods` module (on by default):

```bash
sudo pacman -S --needed kernel-modules-hook
sudo systemctl enable linux-modules-cleanup.service
```

Run only this step: `INSTALL_ONLY=kernelmods ./.local/src/installation_scripts/linux/install_arch.sh`.

## How it works

| Piece | What it does |
|---|---|
| `10-linux-modules-pre.hook` | Before a transaction that installs or upgrades any `usr/lib/modules/*/vmlinuz` (linux-cachyos included), copies `/usr/lib/modules/$(uname -r)` to `/usr/lib/modules/backup/` |
| `10-linux-modules-post.hook` | After it, copies the backup back into `/usr/lib/modules/` without overwriting anything, then removes `backup/` |
| `linux-modules-cleanup.service` | At boot (`basic.target`), moves every `/usr/lib/modules/<version>` that is neither the running kernel nor owned by a package to `/usr/lib/modules/.old/` |
| `tmpfiles.d/linux-modules-cleanup.conf` | Deletes entries in `/usr/lib/modules/.old/` older than 4 weeks |

The service is what stops old trees from piling up; without it enabled, each upgrade leaves one behind.

## Check

```bash
pacman -Q kernel-modules-hook
systemctl is-enabled linux-modules-cleanup.service   # enabled
ls /usr/lib/modules/                                 # after an upgrade, before the reboot: the running version is still listed
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `modprobe: FATAL: Module xpad not found in directory /lib/modules/<version>` after an upgrade | The upgrade ran before the hook was installed, so that tree is already gone. Reboot into the new kernel; the next upgrade keeps it. |
| Old versions pile up in `/usr/lib/modules/` | `linux-modules-cleanup.service` is not enabled: `sudo systemctl enable linux-modules-cleanup.service`, then reboot. |
