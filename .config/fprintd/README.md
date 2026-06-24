# Fingerprint Auth (fprintd + PAM)

Fingerprint login/sudo/polkit on Arch (CachyOS) using a DigitalPersona U.are.U
reader (USB `05ba:000a`, driven by libfprint's `uru4000` driver).

## Quick Setup

```bash
# Install the service + driver library
sudo pacman -S --needed fprintd libfprint

# Enroll a finger (physical — press and lift repeatedly until enroll-completed)
fprintd-enroll

# Verify enrollment works before touching PAM
fprintd-verify

# Wire fingerprint as the FIRST auth line of each stack (sufficient = password
# still works as fallback). Re-running is safe — only adds the line if absent.
for f in sudo sddm polkit-1; do
  [ -f "/etc/pam.d/$f" ] && ! grep -q pam_fprintd.so "/etc/pam.d/$f" && \
    sudo sed -i '0,/^auth/s//auth      sufficient  pam_fprintd.so\n&/' "/etc/pam.d/$f"
done
```

> ⚠️ **Lockout safety:** keep a root shell open in a separate terminal while
> editing PAM, and test in a *second* terminal before closing it. Using
> `sufficient` (not `required`) means the password remains a working fallback —
> do not change it to `required`.

## Packages

| Package    | Purpose                                                        |
|------------|---------------------------------------------------------------|
| fprintd    | D-Bus fingerprint enrollment/verification service             |
| libfprint  | Driver library (`uru4000` backs the DigitalPersona reader)    |

## PAM Configuration

`pam_fprintd.so` is inserted as the **first** `auth` line in each target stack:

| File                  | Covers                                  |
|-----------------------|-----------------------------------------|
| `/etc/pam.d/sudo`     | `sudo` on the command line              |
| `/etc/pam.d/sddm`     | SDDM graphical login                    |
| `/etc/pam.d/polkit-1` | GUI admin prompts (only if file exists) |

Example resulting `/etc/pam.d/sudo`:

```
auth      sufficient  pam_fprintd.so
auth      include     system-auth
...
```

`sufficient` means: if the fingerprint matches, auth succeeds immediately; if it
fails or times out, PAM falls through to the password line. Note: Firefox saved-
password autofill uses Firefox's own master password, **not** PAM — the reader
does not cover it.

## Enrollment

```bash
fprintd-enroll              # enroll the default finger (press/lift, not swipe)
fprintd-enroll -f left-index-finger   # enroll a specific finger
fprintd-list "$USER"        # list enrolled fingers
fprintd-verify              # test a live match
fprintd-delete "$USER"      # remove all enrolled prints
```

## Troubleshooting

**Reader not detected / not claimed**
```bash
lsusb | grep -i finger      # expect: DigitalPersona ... Fingerprint Reader
fprintd-list "$USER"        # if it errors, the service can't see the device
```

**`enroll-stage-failed` / bad scans** — keep pressing; it retries the same stage.
The U.are.U 4000 is a press/touch sensor (flat finger, lift, repeat), not a swipe.

**Fingerprint prompt never appears for sudo** — confirm the line landed:
```bash
grep -n pam_fprintd.so /etc/pam.d/sudo
```

**Remove fingerprint auth** — delete the `pam_fprintd.so` line from the relevant
`/etc/pam.d/*` file(s).

## Installation Script

This setup is automated in the dotfiles installation:
- `.local/src/installation_scripts/linux/install_arch.sh` — `setup_fingerprint()` function
