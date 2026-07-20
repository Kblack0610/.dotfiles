#!/usr/bin/env bash
# fleet-enroll - put THIS machine on the fleet, in one command.
#
#   ./enroll.sh --name gp-mac --group workplace
#
# Works on Linux (systemd user timer) and macOS (launchd agent). Self-contained:
# a machine needs NOTHING else from this repo - it fetches push.sh itself. That
# matters for managed/corporate hosts, where cloning a personal dotfiles checkout
# is clutter you would rather not have to justify.
#
# ORDER IS DELIBERATE: it PROBES before installing anything. Gatus answers an
# unknown key with 404 and push.sh always exits 0 by contract, so a misconfigured
# host installs cleanly and then reports nothing, forever, with no error anywhere.
# That failure mode is exactly how four machines went unnoticed for weeks. So: no
# heartbeat, no agent.
set -euo pipefail

PUSH_URL="https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/fleet-pulse/push.sh"
CFG_DIR="$HOME/.config/fleet-pulse"
SRC_DIR="$HOME/.local/src/fleet-pulse"

NAME=""; GROUP=""; GATUS=""; TOKEN=""; TOKEN_FILE=""

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m %s\n' "$*"; }

usage() {
    cat <<'USAGE'
usage: enroll.sh --name <fleet-name> --group <group> [options]

  --name   NAME     this machine's fleet key, e.g. gp-mac, lazer-machine, windows
  --group  GROUP    workplace | homelab   (must match apps/gatus-fleet/configmap.yaml)
  --gatus  URL      fleet endpoint (default: existing GATUS_BASE, else prompt)
  --token  TOKEN    shared bearer token (avoid: visible in ps; prefer the prompt)
  --token-file F    read the token from a file
  --probe-only      push once and report; install nothing

The name+group pair IS the gatus key (<group>_<name>). Get either wrong and the
push 404s silently.
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)       NAME="${2:-}"; shift 2 ;;
        --group)      GROUP="${2:-}"; shift 2 ;;
        --gatus)      GATUS="${2:-}"; shift 2 ;;
        --token)      TOKEN="${2:-}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
        --probe-only) PROBE_ONLY=1; shift ;;
        -h|--help)    usage ;;
        *) die "unknown arg: $1  (--help)" ;;
    esac
done
PROBE_ONLY="${PROBE_ONLY:-0}"

[ -n "$NAME" ]  || die "--name is required (e.g. gp-mac)"
[ -n "$GROUP" ] || die "--group is required (workplace | homelab)"
case "$NAME" in *[!a-z0-9-]*) die "--name must be kebab-case: [a-z0-9-] only. The status bars match a space-separated roster, so a space or capital can never be rostered." ;; esac
case "$GROUP" in *[!a-z0-9-]*) die "--group must be kebab-case: [a-z0-9-] only" ;; esac

case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *) die "unsupported OS: $(uname -s) (Windows: use enroll.ps1)" ;;
esac

mkdir -p "$CFG_DIR" "$SRC_DIR"

# --- endpoint -------------------------------------------------------------
if [ -z "$GATUS" ] && [ -r "$CFG_DIR/env" ]; then
    # shellcheck disable=SC1091
    . "$CFG_DIR/env" 2>/dev/null || true
    GATUS="${GATUS_BASE:-}"
fi
if [ -z "$GATUS" ]; then
    printf 'fleet endpoint (e.g. https://fleet.your.lan): '
    read -r GATUS
fi
[ -n "$GATUS" ] || die "no fleet endpoint given"
GATUS="${GATUS%/}"

# --- token ----------------------------------------------------------------
if [ -n "$TOKEN_FILE" ]; then
    [ -r "$TOKEN_FILE" ] || die "cannot read --token-file $TOKEN_FILE"
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ] && [ -r "$CFG_DIR/token" ]; then
    TOKEN="$(tr -d '[:space:]' < "$CFG_DIR/token")"
    [ -n "$TOKEN" ] && ok "using existing token at $CFG_DIR/token"
fi
if [ -z "$TOKEN" ]; then
    # Prompted, not an argument: a token on the command line lands in ps output
    # and your shell history.
    printf 'shared fleet token (input hidden): '
    stty -echo 2>/dev/null || true; read -r TOKEN; stty echo 2>/dev/null || true; printf '\n'
fi
[ -n "$TOKEN" ] || die "no token given"

# --- pusher ---------------------------------------------------------------
if [ ! -x "$SRC_DIR/push.sh" ]; then
    say "fetching push.sh"
    curl -fsSL -o "$SRC_DIR/push.sh" "$PUSH_URL" || die "could not fetch push.sh from $PUSH_URL"
    chmod +x "$SRC_DIR/push.sh"
    ok "installed $SRC_DIR/push.sh"
else
    ok "push.sh already present"
fi

# --- PROBE: the go/no-go, BEFORE anything is written ----------------------
# Probe through a TEMP token file so a failed/--probe-only run leaves the machine
# exactly as it found it. Writing config first meant --probe-only clobbered a
# live env file - and since that file also carries FLEET_ROSTER, it silently
# knocked the glyph back into the API-derived mode this whole system exists to
# avoid. Touch nothing until the heartbeat is proven.
say "probing as ${GROUP}_${NAME} (nothing is written until this succeeds)"
PROBE_TOKEN="$(mktemp "${TMPDIR:-/tmp}/fleet-probe.XXXXXX")"
chmod 600 "$PROBE_TOKEN"
trap 'rm -f "$PROBE_TOKEN"' EXIT INT TERM
printf '%s' "$TOKEN" > "$PROBE_TOKEN"

out="$(FLEET_NAME="$NAME" FLEET_GROUP="$GROUP" GATUS_BASE="$GATUS" FLEET_TOKEN_FILE="$PROBE_TOKEN" "$SRC_DIR/push.sh" 2>&1)" || true
printf '  %s\n' "$out"
case "$out" in
    *"HTTP 200"*) ok "heartbeat accepted" ;;
    *404*) die "gatus does not know ${GROUP}_${NAME}. Declare it as an external-endpoint in apps/gatus-fleet/configmap.yaml (and check --name/--group), then re-run." ;;
    *) die "no heartbeat. Endpoint unreachable, token rejected, or egress blocked. NOT installing an agent that would fail silently." ;;
esac
[ "$PROBE_ONLY" = "1" ] && { say "--probe-only: nothing written, nothing installed"; exit 0; }

# --- config (only now that the heartbeat is proven) -----------------------
# Only fleet-WIDE facts here. Identity (FLEET_NAME/FLEET_GROUP) deliberately does
# not live in this file: on machines that stow it from a shared overlay it is
# identical everywhere, so a name here would make every host claim to be the same
# one. Identity goes in the per-machine launcher below.
#
# UPDATE IN PLACE, never overwrite: this file may also carry FLEET_ROSTER and
# other fleet-wide settings this script knows nothing about.
if [ ! -e "$CFG_DIR/env" ]; then
    printf '# written by fleet-pulse enroll.sh\n: "${GATUS_BASE:=%s}"\n' "$GATUS" > "$CFG_DIR/env"
    ok "created $CFG_DIR/env (GATUS_BASE=$GATUS)"
elif grep -q "GATUS_BASE:=${GATUS}}" "$CFG_DIR/env" 2>/dev/null; then
    ok "env already points at $GATUS - left untouched"
else
    tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-env.XXXXXX")"
    if grep -q 'GATUS_BASE' "$CFG_DIR/env"; then
        sed "s|GATUS_BASE:=[^}]*|GATUS_BASE:=${GATUS}|" "$CFG_DIR/env" > "$tmp"
    else
        { cat "$CFG_DIR/env"; printf '\n: "${GATUS_BASE:=%s}"\n' "$GATUS"; } > "$tmp"
    fi
    cat "$tmp" > "$CFG_DIR/env"   # cat, not mv: preserve the stow symlink
    rm -f "$tmp"
    ok "updated GATUS_BASE=$GATUS (other settings preserved)"
fi

if [ ! -e "$CFG_DIR/token" ] || [ "$(tr -d '[:space:]' < "$CFG_DIR/token" 2>/dev/null)" != "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$CFG_DIR/token"
    chmod 600 "$CFG_DIR/token"
    ok "token written (mode 600)"
else
    ok "token already present"
fi

# --- launcher (per-machine identity lives here) ---------------------------
if [ "$OS" = macos ]; then
    PLIST="$HOME/Library/LaunchAgents/com.kblack.fleet-pulse.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    # Same guard as the systemd path: if this is a stow symlink into a dotfiles
    # repo, `cat >` would write THROUGH it and silently edit a tracked file.
    if [ -L "$PLIST" ]; then
        die "$PLIST is a symlink (stow-managed -> $(readlink "$PLIST")). Writing it would edit your dotfiles repo. Either edit that file directly, or 'rm $PLIST' and re-run to get a machine-local one."
    fi
    if [ -e "$PLIST" ]; then
        ok "$PLIST already exists - left untouched"
        say "identity comes from that plist, NOT from this run; delete it and re-run to regenerate"
        launchctl load -w "$PLIST" 2>/dev/null || true
        printf '\n\033[32mAlready enrolled\033[0m -> %s\n' "$GATUS"
        exit 0
    fi
    say "installing launchd agent"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.kblack.fleet-pulse</string>
    <!-- Identity lives here, not in ~/.config/fleet-pulse/env: that file can be
         stowed identically to every machine, so a name in it would make every
         host claim to be the same one. -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>FLEET_NAME=$NAME FLEET_GROUP=$GROUP $SRC_DIR/push.sh</string>
    </array>
    <key>StartInterval</key><integer>60</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/tmp/fleet-pulse.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/fleet-pulse.err.log</string>
</dict>
</plist>
PLIST_EOF
    launchctl load -w "$PLIST"
    ok "launchd agent loaded (every 60s)"
    say "verify:  tail -f /tmp/fleet-pulse.out.log"
else
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    # NEVER overwrite an existing unit. On a stow-managed machine these paths are
    # symlinks INTO the dotfiles repo, so `cat >` writes THROUGH the symlink and
    # silently edits tracked files - it already ate After=network-online.target
    # once, which would have let a boot-time push fire before the network was up.
    if [ -e "$UNIT_DIR/fleet-pulse.service" ]; then
        ok "fleet-pulse.service already exists - left untouched"
        say "identity comes from that unit (or push.sh's defaults), NOT from this run"
        say "if it reports under the wrong name, edit it: Environment=FLEET_NAME=$NAME"
    else
        say "installing systemd user timer"
        cat > "$UNIT_DIR/fleet-pulse.service" <<UNIT_EOF
[Unit]
Description=Fleet Pulse - push this machine's liveness heartbeat to gatus
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=FLEET_NAME=$NAME
Environment=FLEET_GROUP=$GROUP
ExecStart=$SRC_DIR/push.sh
UNIT_EOF
        ok "wrote fleet-pulse.service"
    fi
    if [ ! -e "$UNIT_DIR/fleet-pulse.timer" ]; then
        cat > "$UNIT_DIR/fleet-pulse.timer" <<'UNIT_EOF'
[Unit]
Description=Push fleet-pulse heartbeat every minute

[Timer]
OnCalendar=*:0/1
Persistent=true

[Install]
WantedBy=timers.target
UNIT_EOF
        ok "wrote fleet-pulse.timer"
    else
        ok "fleet-pulse.timer already exists - left untouched"
    fi
    systemctl --user daemon-reload
    systemctl --user enable --now fleet-pulse.timer
    ok "systemd timer enabled (every 60s)"

    # WSL: keep the user manager - and therefore the timer - alive once the last
    # terminal closes. Without linger, systemd tears the user session down with
    # your last shell, so the heartbeat stops while the distro is still running
    # and the glyph reads "this machine died" the moment you close a tab.
    if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        if loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null; then
            ok "linger enabled (WSL) - the timer survives closing your last terminal"
        else
            say "WARNING: could not enable linger. The timer stops when you close your last WSL terminal."
            say "  fix:  sudo loginctl enable-linger ${USER:-$(id -un)}"
        fi
    fi

    # VERIFY THROUGH THE UNIT - the probe above proves nothing about this.
    #
    # The probe ran in YOUR shell, with your environment. The service runs under
    # the systemd user manager, which does NOT inherit it - most notably a proxy
    # (WSL's autoProxy exports one into login shells ONLY). So the probe can pass
    # while every scheduled push fails, and push.sh exits 0 by contract, so
    # nothing anywhere would ever say so. That is the same
    # installs-clean-then-reports-nothing-forever failure the probe exists to
    # prevent, just moved one context over. Scope the log read to THIS run: a
    # stale "HTTP 200" from a previous enroll would read as a pass.
    say "verifying the push from the SERVICE's context (not your shell's)"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl --user start fleet-pulse.service 2>/dev/null || true
    unit_out="$(journalctl --user -u fleet-pulse --since "$since" --no-pager 2>/dev/null || true)"
    case "$unit_out" in
        *"HTTP 200"*)
            ok "the service itself pushed - the timer will too"
            ;;
        *)
            printf '\n\033[33mPARTIAL:\033[0m the timer is installed, but its first push did NOT succeed.\n'
            printf '  Your shell probe reached gatus, so the token and endpoint are fine.\n'
            printf '  The SERVICE context is what failed - most likely it has no proxy.\n\n'
            if [ -n "$unit_out" ]; then printf '%s\n' "$unit_out" | sed 's/^/    /'; else printf '    (no journal output)\n'; fi
            cat <<VERIFY_EOF

  WSL autoProxy only exports the proxy into login shells. The systemd user
  manager reads ~/.config/environment.d instead:

    mkdir -p ~/.config/environment.d
    printf 'HTTPS_PROXY=%s\\nHTTP_PROXY=%s\\nNO_PROXY=localhost,127.0.0.1\\n' \\
        "\$HTTPS_PROXY" "\$HTTP_PROXY" > ~/.config/environment.d/proxy.conf
    systemctl --user daemon-reload && systemctl --user restart fleet-pulse.service

  ${GROUP}_${NAME} will stay stale until that push succeeds.
VERIFY_EOF
            exit 1
            ;;
    esac
    say "verify:  systemctl --user status fleet-pulse.service"
fi

printf '\n\033[32mEnrolled as %s_%s\033[0m -> %s\n' "$GROUP" "$NAME" "$GATUS"
printf 'Add "%s" to FLEET_ROSTER on every machine that renders the glyph, or it will not be counted.\n' "$NAME"
