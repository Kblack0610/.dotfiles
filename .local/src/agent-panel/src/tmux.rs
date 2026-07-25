//! Thin wrappers over the `tmux` CLI: list-panes, capture-pane, switch-client.

use std::process::Command;

/// One tmux pane, parsed from a tab-separated `list-panes -F` row.
pub struct Pane {
    pub session: String,
    pub window_index: String,
    pub current_path: String,
    pub pid: u32,
    pub title: String,
    /// Window tags set via Prefix+a (see .local/src/tmux/tags.sh), rendered by
    /// tmux itself from the `@tag_*` window options. Empty when untagged.
    pub tags: String,
}

/// All panes across all sessions. Empty (not an error) when tmux isn't running.
pub fn list_panes() -> Vec<Pane> {
    let fmt = "#{session_name}\t#{window_index}\t#{pane_current_path}\t#{pane_pid}\t#{pane_title}\t\
               #{?@tag_important,important ,}#{?@tag_pinned,pinned ,}#{?@tag_agent,agent ,}#{?@tag_group,#{@tag_group} ,}";
    let Ok(out) = Command::new("tmux").args(["list-panes", "-a", "-F", fmt]).output() else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut panes = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 4 {
            continue;
        }
        let Ok(pid) = f[3].parse::<u32>() else {
            continue;
        };
        panes.push(Pane {
            session: f[0].to_string(),
            window_index: f[1].to_string(),
            current_path: f[2].to_string(),
            pid,
            title: f.get(4).copied().unwrap_or("").to_string(),
            tags: f.get(5).copied().unwrap_or("").trim().to_string(),
        });
    }
    panes
}

/// Capture a pane's visible buffer. `escapes` keeps SGR colour codes (`-e`);
/// `start` is the scrollback start line (negative looks back).
pub fn capture_pane(target: &str, escapes: bool, start: i32) -> String {
    let start_arg = start.to_string();
    let mut args = vec!["capture-pane", "-p", "-J", "-t", target, "-S", &start_arg];
    if escapes {
        args.push("-e");
    }
    Command::new("tmux")
        .args(&args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// The caller's current `session:window`, or None when run outside tmux.
pub fn current_target() -> Option<String> {
    std::env::var_os("TMUX")?;
    let out = Command::new("tmux")
        .args(["display-message", "-p", "#{session_name}:#{window_index}"])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// Jump to a target — `switch-client` inside tmux, `attach` outside it.
pub fn jump(target: &str) {
    let inside = std::env::var_os("TMUX").is_some();
    let (verb, flag) = if inside {
        ("switch-client", "-t")
    } else {
        ("attach", "-t")
    };
    let _ = Command::new("tmux").args([verb, flag, target]).status();
}
