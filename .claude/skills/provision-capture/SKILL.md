---
name: provision-capture
description: Fold a feature you just set up by hand into the dotfiles provisioning system so a fresh-machine install reproduces it. Use when you've just installed/configured something manually (a peripheral, service, package, PAM/config edit) and want it captured following the repo's convention — triggers like "we just set up X by hand", "fold this into provisioning", "capture this feature", "make sure provisioning is up to date", "add this to the installer". Produces an idempotent setup_<feature>() in the OS installer + a .config/<feature>/README.md runbook. Does NOT replace packages.conf for the cross-OS CLI/GUI floor.
---

# provision-capture

When a feature gets wired up interactively (e.g. a fingerprint reader: `pacman -S
fprintd libfprint` + `fprintd-enroll` + PAM edits), that work lives only in shell
history — a fresh-machine `install_all()` would not reproduce it. This skill folds
it into the dotfiles provisioning system using the repo's established 3-part
convention so nothing stays in shell-history-only state.

The provisioning system lives at `~/.dotfiles/.local/src/installation_scripts/`.
The canonical examples to mirror are `setup_printing()` /
`setup_fingerprint()` in `linux/install_arch.sh` and `.config/cups/README.md` /
`.config/fprintd/README.md`.

## The 3-part convention

### 1. Packages — inline, not in the catalog
Feature-specific packages install **inline** inside the `setup_<feature>()`
function (via `install_pacman_package` / `install_aur_package` / the apt
equivalent). Do **not** add them to `packages.conf` — that file holds only the
cross-OS CLI/GUI **floor** consumed by `install_basics/tools/terminal/gui/runtime`.
Only add to `packages.conf` if the thing is a general cross-OS CLI/GUI tool the
user wants on every machine.

### 2. Setup function — idempotent, wired into install_all()
Write `setup_<feature>()` in the right OS installer
(`linux/install_arch.sh`, `linux/install_debian.sh`, `mac/install_mac.sh`).
Requirements:
- Open with `log_section "..."`; use `log_info` / `log_warning` for steps
  (helpers from `base_functions.sh`).
- **Every mutation is guarded by an "already done" check** — this is the
  load-bearing property. Re-running `install_all()` must be a no-op:
  - package installs: `install_pacman_package` already short-circuits if present.
  - file edits: `grep -q <marker> <file>` before editing; skip if found.
  - config files: only write if absent or content differs.
  - services: `systemctl enable --now` is already idempotent.
  - conditional targets: skip cleanly (`[[ -f ... ]] || continue`) when an
    optional file/stack isn't present on this box.
- **Never automate steps that need a human or touch runtime auth state** —
  physical enrollment, password entry, token edits. Surface the exact command as
  a `log_warning` instead of silently skipping it.
- Wire the call into `install_all()` under the right section comment.

### 3. Runbook — .config/<feature>/README.md
Mirror `.config/cups/README.md` / `.config/fprintd/README.md`:
**Quick Setup** (copy-paste block) → **Packages** table → **Configuration**
(what files change, why) → **Troubleshooting** → **Installation Script** pointer
back to the `setup_<feature>()` function. Include a lockout/safety warning for
anything auth- or boot-critical (PAM, display manager, bootloader).

## Procedure

1. **Classify** what was done: packages? a service to enable? a config/PAM edit?
   a peripheral driver? Each maps to a guarded step in the function.
2. **Reconstruct the exact commands** from the session (what was actually run by
   hand), then translate each into an idempotent, guarded step.
3. **Write `setup_<feature>()`** in the OS installer; wire it into `install_all()`.
4. **Write `.config/<feature>/README.md`.**
5. **Verify** (see below).
6. If the feature warrants a standalone reference (an always-on service, not a
   one-time setup), consider a runbook in `.config/<feature>/` per the
   SENTINEL.md/DREAMING.md convention instead of (or alongside) the README.

## Verify

- `bash -n .local/src/installation_scripts/linux/install_arch.sh` (syntax).
- **Idempotency**: reason through (or dry-run in a scratch shell) a second
  invocation — every guard must report "already …" and add zero duplicate edits.
  For a line-insert, confirm `grep -c <marker> <file>` stays at 1 after re-run.
- Confirm a fresh-machine `install_all()` would reproduce the feature with **no**
  manual steps except those correctly surfaced as `log_warning` (physical /
  auth-state actions).

## Boundaries

- Don't touch `packages.conf` for feature-specific packages (convention #1).
- Don't automate auth-token / history / sqlite / runtime-state edits (matches the
  global Auth-State Safety rule).
- One feature per `setup_<feature>()` + one `.config/<feature>/README.md`.
