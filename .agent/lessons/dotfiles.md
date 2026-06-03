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

## WSL: run Windows-side commands via `powershell.exe` (and `cmd.exe`, `wsl.exe`) directly
From inside WSL you can invoke `powershell.exe -NoProfile -Command '...'` (or `cmd.exe /c ...`) and it executes on the Windows host. PATH includes `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/`. This means scripts under `.local/src/installation_scripts/windows/` (bootstrap.ps1, apply_configs.ps1, etc.) are runnable end-to-end from a WSL session — no need to RDP in or push and pull via OneDrive just to test.

**Why:** WSL interop. The `binfmt_misc` registration for `.exe` files routes execution back to the Windows host, and `$env:USERPROFILE` etc. resolve to the Windows-side user (e.g. `C:\Users\keblack`). Confirmed live: `powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'` returns the Windows PowerShell version, not a WSL stub.

**How to apply:** when the user says "install" or "run X" and the work targets Windows, don't claim "I can't from here." Just call `powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<path>'`. Translate WSL paths to Windows paths with `wslpath -w '/path/in/wsl'` when passing to Windows-side tools. Heads-up: the Windows-side `$env:USERPROFILE\.dotfiles\` is a separate clone from this WSL `~/.dotfiles` -- running `sync_dotfiles.ps1` pulls/clones into the Windows copy.

## NEVER copy the whole `.dotfiles` repo onto the Windows side (no `C:\Users\<u>\.dotfiles`)
The legacy `bootstrap.ps1` / `sync_dotfiles.ps1` flow clones the repo to `%USERPROFILE%\.dotfiles` so `apply_configs.ps1` can copy individual config files into their native Windows homes. **The user does NOT want this anymore.** A Windows-side mirror means two diverging copies, manual git pulls on the VDI side, and a giant 1+ GB tree the corporate AV scans. The repo lives at `/root/.dotfiles` inside WSL, period.

**Why:** explicit user instruction during the WezTerm migration: they reacted strongly to `C:\Users\keblack\.dotfiles` being created. The Linux-side install (`install_arch.sh` + `stow`) is the canonical source; Windows-side just needs the few rendered configs (wezterm.lua, settings.json, etc.) at their target paths.

**How to apply:** to deploy a Windows-side config, copy ONLY the destination file (or that one config dir) directly from `/mnt/c/...` to its target. e.g.:
```sh
mkdir -p /mnt/c/Users/keblack/.config/wezterm
cp /root/.dotfiles/.config/windows/wezterm/wezterm.lua \
   /mnt/c/Users/keblack/.config/wezterm/wezterm.lua
```
Or invoke the relevant single PowerShell installer step; never run `sync_dotfiles.ps1`, never robocopy the whole tree, never set up `%USERPROFILE%\.dotfiles`. If a Windows-side script references `%USERPROFILE%\.dotfiles`, either point it at `\\wsl$\Debian\root\.dotfiles` or rewrite it to take the source path as a parameter.

## Bulk-copy WSL -> /mnt/c is much faster than robocopy through \\wsl$
Robocopy from a Windows-side PowerShell against a `\\wsl$\<distro>\...` source enumerates files over SMB and hangs for many minutes on a normal-sized dotfiles tree. Inverting the direction -- `cp -r /root/.dotfiles/<subdir> /mnt/c/Users/<user>/.dotfiles/<subdir>` from inside WSL -- runs in seconds.

**Why:** the 9P/SMB bridge that exposes WSL files to Windows is slower than the direct ext4-on-vhdx -> NTFS-on-/mnt/c hop the WSL kernel provides. Same data, very different throughput.

**How to apply:** when seeding a Windows-side copy of files that live in WSL, do the copy from WSL into `/mnt/c/...`. Use `tar -cf - . | (cd dst && tar -xf -)` if you need to honor an exclude list and don't have rsync. Reserve robocopy for Windows-to-Windows or Windows-to-WSL-incoming copies.

## WezTerm on Azure VDI over RDP: set `front_end = 'WebGpu'`
Default `front_end = 'OpenGL'` (glium) fails on the Deloitte Azure VDI with `Failed to create window: The OpenGL implementation is too old to work with glium`. The RDP-exposed virtual display only advertises a very old OpenGL profile (sub-3.3). Setting `config.front_end = 'WebGpu'` in `wezterm.lua` switches to DX12/Vulkan via WGPU, which the RDP display does support.

**Why:** Azure VDI (and most enterprise RDP setups) virtualize the GPU and present a fixed-function-style OpenGL surface. WezTerm's glium pipeline expects OpenGL 3.3 core; WGPU happily uses whatever modern DX12/Vulkan-compatible backend Windows offers.

**How to apply:** any Windows-VDI WezTerm config should ship with `config.front_end = 'WebGpu'`. If WebGpu also fails (very locked-down VDI without DX12), fall back to `'Software'` (CPU-rendered; slow but works on anything). Symptom of getting this wrong: WezTerm prints the glium error and exits immediately on launch; no window appears.

## PowerShell 5.1 reads .ps1 files as Windows-1252 unless a UTF-8 BOM is present
A UTF-8 em-dash (`—`, bytes `E2 80 94`) inside a double-quoted string gets re-decoded as `âEUR"` -- and the trailing `0x94` byte is `RIGHT DOUBLE QUOTATION MARK` in Windows-1252, which **prematurely closes the string**. Cascade: "Missing closing '}' in statement block" errors a hundred lines below where the real problem lives. Symptom seen: install_packages.ps1 reported parse errors at line 159 when the actual bad byte was on line 91.

**Why:** Windows PowerShell 5.1 (built into Win10/11 by default) defaults to the active code page (cp1252 on most en-US installs) for any .ps1 without a BOM. PowerShell 7+ defaults to UTF-8 and is fine. `file` reporting `UTF-8 text` does not mean PS5.1 will read it that way.

**How to apply:** in any .ps1 we edit, avoid non-ASCII characters (em-dashes, curly quotes, en-dashes) inside double-quoted strings. Comments with em-dashes happen to be tolerated because the parser doesn't scan them for string terminators, but a stray non-ASCII byte that lands on `0x91/0x93/0x94/0x95` in cp1252 will look like a quote. Cheap rule: use `--` for em-dashes, `'...'` straight quotes everywhere. If you genuinely need UTF-8 content, add a BOM by writing the file with `Out-File -Encoding utf8BOM` or save explicitly as UTF-8-with-BOM.

## GlazeWM under Azure AVD web client: `lwin`/`rwin` bindings cannot work; use `alt`
Swapping GlazeWM keybindings from `alt+...` to `lwin+...` parses fine, GlazeWM's `WH_KEYBOARD_LL` hook is installed correctly, and `errors.log` shows no problem -- but the bindings silently never fire when the session is reached through the **Azure AVD browser web client** (`client.wvd.microsoft.com` or `windows.cloud.microsoft`). Symptom seen: full glazewm restart, fresh config, no parse errors, lwin+1 etc. do absolutely nothing.

**Why:** Chromium has `navigator.keyboard.lock(['MetaLeft','MetaRight'])` which would let the AVD web tab capture the Windows key in JS-initiated fullscreen, but **Microsoft deliberately omits Meta from the AVD web client's locked-key set**. Instead they ship a translated one-shot: `Alt+F3` sends a single discrete LWin tap to the remote (good for opening Start, useless as a held modifier). So a local Win-key press is consumed by the local OS shell and never reaches the remote session. No `keyboardhook:i:1`, no host-pool flag, no hidden setting changes this for the web client -- only the native Windows App / MSRDC client (which has a kernel-adjacent hook) honors `keyboardhook` and forwards raw LWin. References: Microsoft Learn "Use features of the Remote Desktop Web client" (Alt+F3 mapping), GlazeWM README explicitly recommending `alt` over `lwin` because "the OS reserves Windows-key combos."

**How to apply:** if the user accesses this dotfiles setup via the AVD browser, keep the GlazeWM mod key as `alt`. Do NOT propose `lwin`/`rwin`/`win`/`cmd` modifiers -- they parse but never trigger. If `lwin`-style bindings are required, three workarounds (in order of friction): (a) bind to `ralt` instead -- GlazeWM distinguishes LAlt/RAlt at the hook layer and the web client preserves the L/R extended-key bit; AltGr-layout caveat (RAlt synthesizes LCtrl+RAlt on US-Intl/German, requires `ralt+ctrl+...`); (b) install AHK v2 *on the remote VM* with `#InstallKeybdHook` + `AppsKey::LWin` (or `ScrollLock::LWin`) and start it before GlazeWM, so GlazeWM's hook sees synthesized LWin -- PowerToys Keyboard Manager has known issues remapping *into* LWin (PowerToys#19936), AHK is more reliable; (c) install the native Windows App locally (built-in `mstsc.exe` cannot subscribe to AVD workspaces -- only the Windows App can). Also: AVD Keyboard Lock for the *other* system keys (Esc, Alt+Tab, etc.) only activates when fullscreen is entered via the AVD toolbar's diagonal-arrows button, not F11 -- the Keyboard Lock spec rejects user-initiated fullscreen.

## HARD RULE: push Windows configs from WSL with `apply-windows-configs`, never `apply_configs.ps1`
When you are inside WSL and need to push a dotfiles change to a Windows-side destination, you **must** use `.local/bin/apply-windows-configs`. Do **not** invoke `.local/src/installation_scripts/windows/apply_configs.ps1` (or shell out to PowerShell to run it). The only two exceptions:

1. **WSL is genuinely unavailable** — e.g., you're already in a Windows-only shell (post-bootstrap, fresh-OS install) with no WSL distro running.
2. **The change needs admin** — specifically the Firefox/Floorp `policies.json` copy under `Program Files\<browser>\distribution\`. That's the only path `apply-windows-configs` intentionally skips, and the only one that requires an elevated shell. For that case, tell the user to run the PS1 elevated themselves — do not try to auto-elevate.

**Why:** WSL -> `/mnt/c` uses the WSL kernel's direct ext4-on-vhdx -> NTFS-on-/mnt/c hop, which is dramatically faster than PowerShell driving `Copy-Item`/`robocopy` against the same paths via the SMB bridge (same root cause as the robocopy lesson above). It also keeps the user in their working shell — no context switch, no second terminal, no permission-prompt cascade.

**How to apply:**
- Default to `apply-windows-configs` (it's already on `$PATH` via `.local/bin`).
- Use `--dry-run` first if you're unsure what it will touch. Use `--win-user NAME` to override the auto-detected Windows username.
- The script hits both Windows Terminal package GUIDs (`_8wekyb3d8bbwe` stable + `_8wekyb3d8bbce` Preview) and both PowerShell profile paths (PS7's `Documents\PowerShell` and PS5.1's `Documents\WindowsPowerShell`), so you don't need to know which is installed.
- When you add a new source -> destination pair, **add it to both scripts** (`apply-windows-configs` and `apply_configs.ps1`) so they stay in lock-step. The PS1 is still the source-of-truth for the canonical path list and the admin-only Firefox policy install.
- If you ever find yourself about to type `powershell.exe ... apply_configs.ps1`, stop — that's the antipattern this rule exists to prevent.

## Hyper-V VDI guests without GPU-PV: Firefox HW offload is unrecoverable, don't re-debug
Inside a Hyper-V Gen2 VM with no GPU-Partitioning / DDA passthrough (`Win32_ComputerSystem.Model = "Virtual Machine"`, only adapters are `Microsoft Hyper-V Video` + `Microsoft Remote Display Adapter`), Firefox cannot offload anything. `about:support` reports `Compositing: WebRender (Software)` and `Hardware Decoding: Unsupported` for every codec. Locking GPU prefs via `policies.json` is *correct* (real win on any non-VDI Windows box), but doesn't do anything here.

**Why:** The Hyper-V Video VMBUS adapter is *display-only* — paired with `Microsoft Basic Render Driver` (WARP, CPU) for rendering. `MOZ_GFX_SPOOF_*` env vars and `layers.acceleration.force-enabled` clear the gfxInfo blocklist text but only reveal WARP behind the curtain — "hardware" compositing in name only, often slower than software WebRender. `media.hardware-video-decoding.force-enabled` *cannot* bypass `FEATURE_FAILURE_BROKEN_TEXTURE_SHARING` because that's a runtime WMF probe, not a static blocklist. Running Firefox under WSL2 via `/dev/dxg` is strictly worse — dxg routes to the same host WARP adapter plus WSLg's broken DRI3/dma-buf for Firefox video.

**How to apply:** if a Windows host has only `Microsoft Hyper-V Video` and/or `Microsoft Remote Display Adapter` in `Win32_VideoController` and `HypervisorPresent=true`, treat Firefox GPU offload as impossible at this layer. Pivot to CPU-cutting prefs (`layout.frame_rate=30`, `media.av1.enabled=false`, `dom.ipc.processCount=4`, `gfx.webrender.software.opengl=true`, `image.animation_mode=once`). Ship those as a VDI overlay (`.config/firefox/policies.vdi.json`) that `apply_configs.ps1` deep-merges only when no real GPU adapter (vendor name matches `NVIDIA|AMD|Radeon|Intel\(R\)|GeForce|Quadro|Tesla|Arc`) is visible -- they're net losses on a real-GPU box (capped fps, software compositor preferred over real GPU, AV1 disabled). The infra-side fix the user can ask for is GPU-P on Win Server 2025 hosts or AVD NVads-A10 / NVv4 session host pool.

## WSL -> `C:\Program Files\...` is admin-walled regardless of WSL permissions; route through `Start-Process -Verb RunAs`
Copying from WSL into `/mnt/c/Program Files/...` fails with `Permission denied` (mkdir/cp/rm) even as root in WSL, because the kernel-side `9p`/`drvfs` mount honors NTFS ACLs and Program Files is admin-only. Trying to elevate from WSL by `sudo cp` does nothing — WSL's sudo is a Linux-side concept.

**Why:** WSL interop runs as the *unelevated* Windows user. Linux root has no relationship to Windows admin.

**How to apply:** stage the file in a user-writable Windows location first (e.g. `cp /root/x /mnt/c/Users/<user>/x`), then trigger UAC with `powershell.exe -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command','...'"`. The Start-Process Verb=RunAs pops the UAC prompt on the Windows host; the user clicks yes; the elevated session does the privileged copy and exits; the outer powershell.exe returns control to WSL. Pair this with `diff -q` against the destination afterwards to confirm the elevated copy actually landed.

## zsh eats `$env:VAR` PowerShell expressions; single-quote when invoking powershell.exe from zsh
Running `powershell.exe -File "$env:USERPROFILE\..."` from zsh fails with "Processing -File ':USERPROFILE\\...' failed". zsh parsed `$env` as an undefined shell var (empty) and left `:USERPROFILE\...` as the literal argument. PowerShell never saw the `$env:` syntax.

**Why:** `$env:VAR` is PowerShell-native syntax. zsh sees `$env` as a shell variable, not a namespace selector. Double quotes in zsh still permit shell expansion.

**How to apply:** when invoking `powershell.exe` from zsh, wrap any PowerShell-syntax expression in **single quotes** so zsh leaves it alone, e.g. `powershell.exe -NoProfile -File '$env:USERPROFILE\.dotfiles\...\script.ps1'`. If you need shell interpolation on the zsh side too, build the path with `wslpath -w "$linux_path"` first, then pass the resulting `C:\...` string in single quotes.
