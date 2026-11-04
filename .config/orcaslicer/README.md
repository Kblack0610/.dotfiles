# OrcaSlicer (desktop)

Native OrcaSlicer from the AUR slices for the Neptune 4 Pro and the Bambu A1. The presets are not kept here: they live in home-config at `apps/orcaslicer/profiles/`, and the k3s slicer reads the same files. Preset changes, gcode naming and version bumps are covered in `~/dev/home/home-config/apps/orcaslicer/README.md`.

## Quick Setup

```bash
paru -S orca-slicer
~/dev/home/home-config/apps/orcaslicer/desktop-link.sh   # OrcaSlicer closed
```

## Packages

| Package | Source | Purpose |
|---------|--------|---------|
| `orca-slicer` | AUR | The slicer, `/usr/bin/orca-slicer` |
| `sops`, `age` | pacman | `desktop-link.sh` decrypts the A1 LAN code |

## Configuration

`desktop-link.sh` (idempotent) sets up `~/.config/OrcaSlicer`:

- `user/default/filament` and `user/default/process` are symlinks to the home-config folders, so a preset saved in Orca shows in `git -C ~/dev/home/home-config status`.
- `user/default/machine` is a real folder. The Neptune presets are per-file symlinks; the A1 preset is a local copy (mode 600) with the LAN code and serial filled from `apps/orcaslicer/bambu-a1-secret.yaml`, so the code never reaches the public repo.
- `OrcaSlicer.conf` is seeded once, then its download folder is set to `~/3d-prints/_inbox` and its export and recent folders to `~/3d-prints`.

Never save an A1 machine preset change back into the repo by hand: copy the edit into `profiles/machine/` with the code and serial left as `@A1_ACCESS_CODE@` and `@A1_SERIAL@`.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `orca-slicer` opens a browser tab on port 3333 | An old Docker wrapper in `~/.local/bin` shadows the native binary | Remove the wrapper; `command -v orca-slicer` must print `/usr/bin/orca-slicer` |
| The Neptune or A1 printer is missing from the list | Presets not linked, or OrcaSlicer was open while linking | Close Orca, re-run `desktop-link.sh` |
| `desktop-link.sh` fails at `sops -d` | The age key is not at `~/.config/sops/age/keys.txt` | Restore the key, re-run |

## Installation Script

`setup_3d_printing()` in `.local/src/installation_scripts/linux/install_arch.sh`.
