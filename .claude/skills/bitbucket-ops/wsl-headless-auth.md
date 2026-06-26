# Bitbucket CLI headless auth on WSL — happy path & runbook

Goal: run the `bitbucket` Rust CLI in WSL with **zero GUI prompts, zero typing per session**.
Solved 2026-06-19. This is the authoritative happy-path doc; SKILL.md links here.

---

## TL;DR happy path (already set up on this machine)

1. Open a new WSL shell. `.zshrc` auto-unlocks the keyring (no prompt).
2. Run any command: `bitbucket auth status` → `✓ Authenticated`.

That's it. The sections below document *why* it works and *how to rebuild it* if it breaks.

---

## Why this is non-trivial (root cause)

Two hard constraints, both verified against the binary (`bitbucket 0.3.18`, crate `bitbucket-cli`):

1. **The CLI stores credentials ONLY in a Secret Service keyring** (`keyring-3.6.3` +
   `dbus-secret-service`). There is **no env-var or plaintext-file fallback** for stored
   creds. `BITBUCKET_USERNAME` / `BITBUCKET_API_KEY` are NOT read at command time — they
   only help pre-seed an interactive login.
2. **gnome-keyring always starts its `login` collection LOCKED**, even when the keyring
   password is empty. An empty password does **not** auto-unlock; it only makes the one
   required unlock **non-interactive**. On WSLg a locked keyring surfaces as a **GUI unlock
   dialog** ("lockring") that can't be driven headlessly — this was the original blocker.

Also: app passwords are deprecated (removed 2026-07-28). **API tokens with scopes are the
only credential.** And `bitbucket auth login` reads the username from a **TTY only** (not a
pipe/env), and the username for the REST API must be your **Atlassian account email**, not
your Bitbucket handle.

---

## The three pieces that make the happy path work

### 1. Credential: API token (not app password)
- Create at: Bitbucket → Account settings → Security → **Create and manage API tokens →
  Create API token with scopes** → select **Bitbucket** app → set expiry → assign scopes
  (Repositories r/w, Pull requests r/w, Pipelines read). Token shown once.
- Username for the CLI/REST API = **Atlassian account email** (e.g. `keblack@deloitte.ca`).
- git-over-HTTPS (separate use case) = username `x-bitbucket-api-token-auth`, token as
  password. Old `username:token` git syntax no longer works.

### 2. Keyring: `login.keyring` with an EMPTY password
- One-time reset turned the password-protected `login` keyring into an empty-password one
  so it can be unlocked non-interactively.
- Backup of the original is at `~/.local/share/keyrings.bak-<date>-keyring-reset`.

### 3. Session glue: `.zshrc` auto-unlock block
- Real file: `~/.dotfiles/.zshrc` (stow-managed; `~/.zshrc` is a symlink — **edit the real
  file**, never the symlink).
- Logic: on shell start, probe whether the `login` collection is locked; if so, replace the
  daemon with one unlocked via empty password. Idempotent — no-op when already unlocked.

```sh
# --- Secret Service for bitbucket-cli / libsecret (WSL has no desktop session) ---
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}"
  if [ "$(busctl --user get-property org.freedesktop.secrets \
            /org/freedesktop/secrets/collection/login \
            org.freedesktop.Secret.Collection Locked 2>/dev/null)" != "b false" ]; then
    printf '\n' | gnome-keyring-daemon --replace --daemonize \
      --components=secrets,pkcs11,ssh --unlock >/dev/null 2>&1
  fi
fi
```

### Optional: `~/.config/bitbucket/secrets.env` (chmod 600)
Holds `BITBUCKET_USERNAME` (email), `BITBUCKET_API_KEY` (token), `BITBUCKET_DEFAULT_WORKSPACE`.
Sourced by `.zshrc`. Since the token now lives in the keyring, this file is **only needed to
re-login**. You may blank `BITBUCKET_API_KEY` if you don't want the token sitting in a file.

---

## Verify (happy path)

```bash
# 1. keyring unlocked?
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login \
  org.freedesktop.Secret.Collection Locked        # expect: b false

# 2. CLI authenticated? (this makes a real authenticated API call)
bitbucket auth status                             # expect: ✓ Authenticated, your name

# 3. a real read
bitbucket pr list techdataassets/<repo>
```

---

## Rebuild from scratch (if creds are lost / new machine)

```bash
# A. Reset login keyring to empty password (BACK UP FIRST)
cp -a ~/.local/share/keyrings ~/.local/share/keyrings.bak-$(date +%Y%m%d)   # run yourself; Date.now blocked in agent
# kill keyring daemons by PID (do NOT use `pkill -f gnome-keyring-daemon` — it self-matches the shell)
for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null); case "$c" in *gnome-keyring-daemon*) kill -KILL "${d#/proc/}";; esac; done
rm -f ~/.local/share/keyrings/login.keyring
printf '\n' | gnome-keyring-daemon --replace --daemonize --components=secrets,pkcs11,ssh --unlock

# B. Log in (TTY prompt; paste token; username = Atlassian email)
bitbucket auth login --api-key -w techdataassets

# C. Verify
bitbucket auth status
```

> The login prompt is TTY-only. To drive it non-interactively (CI), use a pseudo-tty
> (python `pty`, or `expect`) feeding the email then the token — env vars alone won't fill it.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| GUI unlock dialog pops / command **hangs** | `login` keyring locked | Run the `.zshrc` unlock block, or `printf '\n' \| gnome-keyring-daemon --replace --daemonize --components=secrets,pkcs11,ssh --unlock` |
| `auth status` hangs forever (exit 124 on timeout) | keyring locked OR no Secret Service on the bus | Check `busctl --user list \| grep secrets`; ensure `DBUS_SESSION_BUS_ADDRESS` is set |
| `Failed to store credential in keyring` | Secret Service unreachable (no D-Bus) | Don't unset `DBUS_SESSION_BUS_ADDRESS`; ensure daemon running |
| `Error: Failed to read username` | piping to the interactive login | Use a real TTY / pseudo-tty; login can't read username from a pipe |
| HTTP 401/410 on previously-working auth | app password hit a brownout / removal | Migrate to an API token (the whole point of this doc) |
| `auth status` ✓ but real calls say **"Authentication failed"** / raw API returns **401** even after the keyring is unlocked | **API token expired or revoked** — the keyring still holds the stale token. NOT a keyring/doc bug. | Confirm with `curl -s -o /dev/null -w '%{http_code}' -u "$BITBUCKET_USERNAME:$BITBUCKET_API_KEY" https://api.bitbucket.org/2.0/user` (401 = dead). Regenerate the API token, update `secrets.env`, re-login. A **403** instead means the token is valid but lacks access to that workspace (wrong account/scopes). |
| `Refusing to write through symlink` editing `.zshrc` | `~/.zshrc` is a stow symlink | Edit `~/.dotfiles/.zshrc` |
| Shell dies when killing the daemon | `pkill -f gnome-keyring-daemon` matched the shell's own cmdline | Kill by explicit PID via `/proc/*/cmdline` scan instead |

## Recovery (undo the keyring reset)
```bash
cp -a ~/.local/share/keyrings.bak-<date>-keyring-reset/login.keyring ~/.local/share/keyrings/login.keyring
# then restart the daemon (it will prompt for the original password on next access)
```

## Security note
The empty-password keyring protects stored creds with **file permissions only** (`~/.local/
share/keyrings/`, mode 600) — same posture as the chmod-600 `secrets.env`. Acceptable on a
single-user WSL dev box. Do not replicate empty-password keyrings onto shared/multi-user hosts.
