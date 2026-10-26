//! Kick `lab-refresh` after a verb that changes which projects exist or where rows live.
//!
//! A project change reaches four generated surfaces (each project's feed, every profile's
//! index, both boards), and this CLI writes only the sheet. Leaving the rest to a human or
//! agent to remember is how the combined index went stale on 2026-10-26, so the verbs that
//! change project shape start the refresh themselves.
//!
//! It runs detached, because a full refresh takes about 12 s and the verb's own write is
//! already done. `lab-refresh` lives in the private overlay, so a machine without it, or a
//! run with `NOTES_NO_LAB_REFRESH` set, simply skips it. Failures go to the log file named
//! below rather than the terminal the verb has already returned to.

use std::fs::OpenOptions;
use std::process::{Command, Stdio};

const BIN: &str = "lab-refresh";
const SKIP_ENV: &str = "NOTES_NO_LAB_REFRESH";

pub fn kick() {
    if std::env::var_os(SKIP_ENV).is_some() {
        return;
    }
    let Some(home) = std::env::var_os("HOME") else { return };
    let log_dir = std::path::Path::new(&home).join(".local/log");
    let _ = std::fs::create_dir_all(&log_dir);
    let stderr = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_dir.join("lab-refresh.log"))
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null());
    // A missing binary is the normal case on a machine without the private overlay.
    let _ = Command::new(BIN)
        .arg("-q")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr)
        .spawn();
}
