# dotfiles — lessons

## CRITICAL: never `ln -s` a new dir into `~/.config` — use stow
The `apply_dotfiles` function in `~/.dotfiles/.local/src/installation_scripts/base_functions.sh` does this sequence on every install_mac run:
```bash
[[ -f ~/.bashrc ]] && rm -f ~/.bashrc
[[ -f ~/.zshrc ]] && rm -f ~/.zshrc
stow .
```
If `stow .` aborts for any reason (most commonly: a pre-existing non-stow symlink or file at one of stow's targets), the `rm` already happened and the shell is left with no rc → no starship, no aliases, broken prompt.

**Rule:** when adding any new dotfiles-managed config, create it under `~/.dotfiles/.config/<name>/` and immediately run `cd ~/.dotfiles && stow .` (or just `stow -d ~/.dotfiles -t ~ .`). Do NOT do `ln -s ~/.dotfiles/.config/<name> ~/.config/<name>` — it works in the moment but will sabotage the next install_mac.

**Why:** Manual symlinks aren't owned by stow, so stow refuses to overwrite them. The user's bootstrap deletes `~/.zshrc`/`~/.bashrc` BEFORE running stow, so a stow-abort = broken shell.

**How to apply:** Default to `stow .` after creating any new config dir under `~/.dotfiles/`. If recovering: `rm` the offending manual symlink, `cd ~/.dotfiles && stow .`, verify `~/.zshrc` and `~/.bashrc` symlinks exist.

## macOS process detection: use case-insensitive grep
`pgrep -lf aerospace` returns empty even when AeroSpace is running — the macOS app's process name is `AeroSpace` (capitalized). Always use `pgrep -lif <name>` (or `pgrep -lf '[Aa]erospace'`) when checking GUI-app daemons on macOS, because Apple/SwiftUI apps usually capitalize.

**How to apply:** when checking whether a Mac GUI app is running, always pass `-i` to pgrep (or grep its `.app` bundle name with proper case).

## SketchyBar: plugin scripts do NOT inherit sketchybarrc's env
The sketchybar daemon is started by launchd with a minimal environment. When it invokes plugin scripts (via update_freq, event subscribe, or `--trigger`), they get that minimal env — **not** the env from the bash subprocess that sourced `sketchybarrc`. So `export GOLD=...` in `colors.sh` is visible to `items/*.sh` (which run inline during sketchybarrc), but invisible to `plugins/*.sh`.

**Why:** sketchybarrc runs as a one-shot bash subprocess; its exports die with it. The daemon spawns plugin scripts fresh from its own launchd-inherited env.

**How to apply:** every plugin that uses palette or icon vars must `source "$HOME/.config/sketchybar/colors.sh"` (and/or `icons.sh`) at the top. Symptom of getting this wrong: items render with `color=0x0` (fully transparent) so the bar looks empty.

## AeroSpace `after-startup-command` is array-of-aerospace-commands, not argv
Each entry in `after-startup-command` is a single string that AeroSpace parses as one of its own commands. Wrong syntax gives the cryptic `Unrecognized subcommand 'Expected'` parse error and aerospace refuses to load the whole config (silently — no notification, just a `reload-config` failure).

**Why:** `after-startup-command` and `exec-on-workspace-change` look similar but have different schemas. The former takes aerospace commands (strings), the latter takes argv passed to exec.

**How to apply:** for sketchybar startup state, handle initial-render inside the consumer (e.g. sketchybar's items/spaces.sh manually triggers `aerospace_workspace_change` on startup), rather than wiring `after-startup-command`. Always `aerospace reload-config` after editing aerospace.toml and check the exit code.

## Stow drift: some configs are hardlinked, not symlinked
`~/.config/aerospace/aerospace.toml` shares an inode with `~/.dotfiles/.config/aerospace/aerospace.toml` (`stat -f '%i'` matches) but is NOT a stow symlink. Editing either path edits both, but stow won't see it as managed.

**Why:** unclear how it got into that state; possibly an older install script used `cp -al` or `ln` (not `ln -s`) before switching to stow.

**How to apply:** if `stat -f '%i %N' path1 path2` returns identical inodes but `ls -la` shows neither as a symlink, they're hardlinked. Re-stowing requires deleting one copy first. Don't be confused by `readlink` returning empty — that just means "not a symlink", which a hardlink isn't.
