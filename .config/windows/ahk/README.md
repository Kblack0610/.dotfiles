# Win-key ownership (GlazeWM)

Every GlazeWM binding in `../glazewm/config.yaml` uses `lwin` as the mod key, for Hyprland muscle-memory parity. Windows fights back. This directory plus `../scripts/win-key-ownership.ps1` is what makes `lwin` actually usable.

## The problem

Windows opens the Start menu on a Win **keyup** that saw no other keydown in between. GlazeWM swallows the bound key (`1`, `h`, `e`, ...) inside its `WH_KEYBOARD_LL` hook, so Explorer sees a clean `LWin down -> LWin up` and pops Start on top of whatever GlazeWM just did.

It is a race, not a misconfiguration. Hold `lwin` for about a second and GlazeWM wins; tap it quickly and Explorer wins. That timing dependence is the signature - if you see it, you are looking at this bug and not something else.

Upstream: [glzr-io/glazewm#1215](https://github.com/glzr-io/glazewm/issues/1215), open and untriaged, filed against 3.9.1. GlazeWM v3.1.0 fixed this class of bug ([#589](https://github.com/glzr-io/glazewm/issues/589), [#158](https://github.com/glzr-io/glazewm/issues/158)) and it regressed. Nothing through 3.10.1 addresses it, so upgrading is not the fix.

Reaching the desktop over a remote-desktop session makes it noticeably worse: network jitter compresses keystroke timing on the remote side, so more presses land inside the losing window.

## The fix, in two layers

Both are required. Neither is sufficient alone.

### Layer 1 - registry (`../scripts/win-key-ownership.ps1`)

Three per-user values, all reversible with `-Revert`.

| Value | Admin? | Effect | Cost |
|---|---|---|---|
| `DisabledHotkeys` = `DEFGHJKNQRTV123456789` | no | Explorer stops claiming exactly the `Win+<key>` combos GlazeWM binds, so `lwin+e` / `lwin+d` / `lwin+r` / `lwin+g` / `lwin+<n>` stop double-firing | Those combos stop working as Windows shortcuts. Anything GlazeWM does not bind (`Win+Shift+S`, `Win+P`, `Win+X`, `Win+.`) is untouched |
| `LowLevelHooksTimeout` = `10000` | no | Windows is slower to silently evict GlazeWM's keyboard hook under load | Takes effect on next sign-in |
| `DisableLockWorkstation` = `1` | **yes** | `lwin+l` focuses right instead of locking the session | "Lock" disappears from the Start menu; Ctrl+Alt+Del still locks |

Two things worth knowing about this table:

- **`DisabledHotkeys`, not the `NoWinKeys` policy.** `NoWinKeys` is the recipe you will find in [GlazeWM discussion #1206](https://github.com/glzr-io/glazewm/discussions/1206), and it is blunter and worse here: it kills *every* Win hotkey and it lives in the `Policies` subtree that needs admin. `DisabledHotkeys` is per-key, needs no admin, and genuinely releases the keys rather than just suppressing the shell's handler. It is a string of virtual-key characters - letters uppercase, one char per key, no separators - and each entry covers every Win combo using that key, so `V` covers `Win+V` and `Win+Shift+V` alike. That is what we want, since GlazeWM binds both `lwin+<n>` and `lwin+shift+<n>`. Explorer reads it only at shell start.
- **`DisableLockWorkstation` needs elevation even though it is under HKCU.** Managed Windows images ACL the `HKCU\...\Policies` subtree read-only for the user. Running the script unelevated applies the other two and tells you what it skipped; `win-key-task` from WSL gets you one UAC prompt that finishes the job.

`Win+L` deserves a note: it is a Secure Attention Sequence handled by winlogon **before any user-mode hook**, so GlazeWM physically cannot intercept it. `DisableLockWorkstation` is the only fix short of rebinding `lwin+l`.

Two keys are deliberately not in the string. `L` cannot be disabled this way (winlogon, see above). `Tab` is not an alphanumeric key and its encoding in `DisabledHotkeys` is undocumented, so it is left to the Layer 2 mask rather than guessed at.

**Layer 1 does not stop the bare-Win Start menu.** Only the Win+`<key>` combos. That is what Layer 2 is for.

### Layer 2 - AHK mask key (`glazewm-winkey.ahk`)

Sends a harmless unassigned keystroke on each physical `LWin` press, so Explorer's chord tracking is dirty and the keyup never reads as a bare Win tap. `~` passes `LWin` straight through, so GlazeWM's hook still sees it as a modifier and every binding keeps working.

Two things that are easy to get wrong:

- **`vkE8`, not `vk07`.** Every copy of this trick online uses `vk07`, which was unassigned before Windows 10 and now **opens the Game Bar**. `vkE8` is unassigned; `vkFF` is what AutoHotkey's [own v2 docs](https://www.autohotkey.com/docs/v2/lib/A_MenuMaskKey.htm) use.
- **It must run elevated.** An unelevated process cannot send keystrokes to an elevated window, so the mask silently stops working whenever an elevated window has focus. GlazeWM already runs elevated; match it. `apply-windows-configs` registers the scheduled task with highest privileges for exactly this reason - a Startup-folder shortcut cannot launch elevated without a UAC prompt every sign-in.

## Deploying

From WSL, two steps:

```sh
apply-windows-configs    # copies the .ahk and applies the no-admin registry values
win-key-task             # one UAC prompt: the admin registry value + the logon task
```

On a fresh Windows box, `apply_configs.ps1` does the first and points you at the second. AutoHotkey itself comes from `install_packages.ps1` (`AutoHotkey.AutoHotkey`).

Destination is `%USERPROFILE%\.dotfiles-win\ahk\glazewm-winkey.ahk`, run at logon by scheduled task `dotfiles-glazewm-winkey`.

## Verifying

Registry:

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name DisabledHotkeys
Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LowLevelHooksTimeout
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name DisableLockWorkstation
```

`DisabledHotkeys` only takes effect once Explorer restarts (`Stop-Process -Name explorer -Force`), and `LowLevelHooksTimeout` on next sign-in. After that, check `lwin+e` opens exactly one window (GlazeWM's, not Explorer's), `lwin+r` enters resize mode with no Run dialog, and `lwin+l` focuses right without locking.

The mask, reproducing the upstream bug's own repro:

1. **Fast-tap** `lwin+1` through `lwin+5`, twenty times. Zero Start menus. Before the fix this leaks and holding `lwin` for a second does not - that contrast is the confirmation.
2. Tap and release `lwin` alone. No Start menu.
3. Focus an **elevated** window (admin Terminal) and repeat 1 and 2. This is what proves the elevation requirement was actually met.
4. `lwin+h/j/k/l`, `lwin+shift+<n>`, `lwin+d`, `lwin+g` all still fire - confirms the mask did not steal `LWin` from GlazeWM.
5. Retest after a few hours. The symptom is intermittent, so one clean pass is necessary but not sufficient.

Do **not** validate by hot-reloading GlazeWM repeatedly. `wm-reload-config` re-applies every `move --workspace` rule to every open window and will shred a live layout. One edit, one reload.

## Reverting

From WSL, one command undoes both layers (one UAC prompt):

```sh
win-key-task --unregister
```

Then sign out and back in. To stop the mask immediately without unwinding anything:

```powershell
Stop-Process -Name AutoHotkey* -Force
```

GlazeWM itself is never modified, so there is no state to restore on that side.

## If the mask still misses

`~LWin::Send "{Blind}{vkE8}"` has [documented reliability complaints](https://www.autohotkey.com/boards/viewtopic.php?p=553069). The script uses a hardened form with an auto-repeat guard. Fallback ladder, in order:

1. Swap the mask to `vkFF`.
2. Send the mask on keyup as well as keydown.
3. Last resort - revert `config.yaml`'s mod key to `alt`. GlazeWM ships `alt` as its default for precisely this reason, and the config header already documents that path.
