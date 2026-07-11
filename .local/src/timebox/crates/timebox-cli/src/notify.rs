//! Side-channel effects for a lap boundary: a desktop/ntfy notification via the repo's
//! `agent-notify` fan-out helper, and an optional sound. Both swallow all errors — a
//! failed notification or missing audio tool must never fail the CLI (mirrors
//! `agent-notify`'s own always-exit-0 contract).

use std::path::Path;
use std::process::{Command, Stdio};

/// Fire a notification through `~/.local/bin/agent-notify` (on PATH). `urgency` is one
/// of `low|normal|high`.
pub fn notify(title: &str, urgency: &str, msg: &str) {
    let _ = Command::new("agent-notify")
        .args(["-t", title, "-p", urgency, msg])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Play a sound file with whichever PipeWire/Pulse player is available. Detached; errors
/// ignored.
pub fn play_sound(path: &Path) {
    for bin in ["pw-play", "paplay"] {
        let ok = Command::new(bin)
            .arg(path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .is_ok();
        if ok {
            return;
        }
    }
}

/// Run the configured flash command (a screen-flash helper) detached. Errors ignored.
/// `cmd` is split on whitespace; the first token is the program.
pub fn flash(cmd: &str) {
    let mut parts = cmd.split_whitespace();
    let Some(prog) = parts.next() else {
        return;
    };
    let _ = Command::new(prog)
        .args(parts)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}
