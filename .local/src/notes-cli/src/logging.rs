//! Structured, append-only logging so failures are diagnosable instead of silent.
//! Every command writes `[ts] [LEVEL] cmd: msg` to `~/.local/state/notes/journal.log`.
//! WARN/ERROR are always echoed to stderr; INFO only with `--verbose`.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

pub struct Logger {
    path: PathBuf,
    verbose: bool,
}

impl Logger {
    pub fn new(path: PathBuf, verbose: bool) -> Self {
        Logger { path, verbose }
    }

    fn emit(&self, level: &str, cmd: &str, msg: &str) {
        let ts = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%z");
        let line = format!("[{ts}] [{level}] {cmd}: {msg}\n");
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = f.write_all(line.as_bytes());
        }
        if self.verbose || level == "WARN" || level == "ERROR" {
            eprintln!("{level} {cmd}: {msg}");
        }
    }

    pub fn info(&self, cmd: &str, msg: &str) {
        self.emit("INFO", cmd, msg);
    }
    pub fn warn(&self, cmd: &str, msg: &str) {
        self.emit("WARN", cmd, msg);
    }
    #[allow(dead_code)]
    pub fn error(&self, cmd: &str, msg: &str) {
        self.emit("ERROR", cmd, msg);
    }
}
