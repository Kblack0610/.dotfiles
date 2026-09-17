//! Thin wrappers over the `tmux` CLI: list-panes, capture-pane, and the jump.
//!
//! Sessions live on several tmux SERVERS, one per socket (`hub`, `lab`, ... see
//! `.local/src/tmux/servers.sh`). A bare `tmux` only reaches `$TMUX`'s server, or the
//! `default` socket from outside tmux, which does not exist here. So every call names
//! its server with `-L`, and a target is `<server>/<session>:<window>`.

use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One tmux pane, parsed from a tab-separated `list-panes -F` row.
pub struct Pane {
    pub server: String,
    pub session: String,
    pub window_index: String,
    pub current_path: String,
    pub pid: u32,
    pub title: String,
    /// Window tags set via Prefix+a (see .local/src/tmux/tags.sh), rendered by
    /// tmux itself from the `@tag_*` window options. Empty when untagged.
    pub tags: String,
}

/// `<server>/<session>:<window>`.
pub fn qualify(server: &str, session: &str, window: &str) -> String {
    format!("{server}/{session}:{window}")
}

/// Split a target into its server and the `session:window` tmux understands.
/// Server names come from socket filenames, so they never contain `/`.
pub fn split(target: &str) -> (Option<&str>, &str) {
    match target.split_once('/') {
        Some((srv, local)) if !srv.is_empty() => (Some(srv), local),
        _ => (None, target),
    }
}

fn tmux(server: Option<&str>) -> Command {
    let mut c = Command::new("tmux");
    if let Some(srv) = server {
        c.args(["-L", srv]);
    }
    c
}

/// The socket path of the server we are inside, from `$TMUX` (`<socket>,<pid>,<n>`).
fn own_socket() -> Option<PathBuf> {
    let v = std::env::var("TMUX").ok()?;
    let sock = v.split(',').next()?;
    (!sock.is_empty()).then(|| PathBuf::from(sock))
}

/// Name of the server we are inside, or None outside tmux.
pub fn current_server() -> Option<String> {
    own_socket()?
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
}

/// tmux's socket directory: `$TMUX`'s own when inside, else `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`.
fn socket_dir() -> Option<PathBuf> {
    if let Some(dir) = own_socket().as_deref().and_then(Path::parent) {
        return Some(dir.to_path_buf());
    }
    let uid = Command::new("id").arg("-u").output().ok()?;
    let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
    let base = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".into());
    Some(PathBuf::from(base).join(format!("tmux-{uid}")))
}

/// Servers with a live process behind their socket, sorted. A socket file can outlive
/// its server, so only ones that answer `has-session` count (same rule as
/// servers.sh `live_servers`).
pub fn servers() -> Vec<String> {
    let Some(dir) = socket_dir() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_socket()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| {
            tmux(Some(name))
                .arg("has-session")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        })
        .collect();
    names.sort();
    names
}

/// All panes across every server. Empty (not an error) when tmux isn't running.
pub fn list_panes() -> Vec<Pane> {
    servers().iter().flat_map(|srv| list_server_panes(srv)).collect()
}

fn list_server_panes(server: &str) -> Vec<Pane> {
    let fmt = "#{session_name}\t#{window_index}\t#{pane_current_path}\t#{pane_pid}\t#{pane_title}\t\
               #{?@tag_important,important ,}#{?@tag_pinned,pinned ,}#{?@tag_agent,agent ,}#{?@tag_group,#{@tag_group} ,}";
    let Ok(out) = tmux(Some(server)).args(["list-panes", "-a", "-F", fmt]).output() else {
        return Vec::new();
    };
    parse_panes(server, &String::from_utf8_lossy(&out.stdout))
}

fn parse_panes(server: &str, text: &str) -> Vec<Pane> {
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
            server: server.to_string(),
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
    let (server, local) = split(target);
    let start_arg = start.to_string();
    let mut args = vec!["capture-pane", "-p", "-J", "-t", local, "-S", &start_arg];
    if escapes {
        args.push("-e");
    }
    tmux(server)
        .args(&args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// The caller's current `<server>/<session>:<window>`, or None when run outside tmux.
pub fn current_target() -> Option<String> {
    let server = current_server()?;
    let out = Command::new("tmux")
        .args(["display-message", "-p", "#{session_name}:#{window_index}"])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then(|| format!("{server}/{s}"))
}

/// Jump to a target. Within the server we are already in, that is `switch-client`.
/// Anything else is a cross-server hop, which tmux has no command for; `tmx goto`
/// owns it (detach-client -E + attach, and it records the Prefix+L way back), so
/// this delegates rather than growing a second copy of the hop.
pub fn jump(target: &str) {
    let (server, local) = split(target);
    let here = current_server();
    match server {
        Some(srv) if here.as_deref() != Some(srv) => {
            let _ = Command::new(tmx_path()).args(["goto", srv, local]).status();
        }
        _ if here.is_some() => {
            let _ = Command::new("tmux").args(["switch-client", "-t", local]).status();
        }
        _ => {
            let _ = tmux(server).args(["attach", "-t", local]).status();
        }
    }
}

/// `tmx` from PATH, else the dotfiles install location: Hyprland's `exec` PATH does
/// not carry ~/.local/bin, and the pin launches this binary from there.
fn tmx_path() -> PathBuf {
    let on_path = std::env::var_os("PATH").and_then(|p| {
        std::env::split_paths(&p)
            .map(|d| d.join("tmx"))
            .find(|c| c.is_file())
    });
    on_path.unwrap_or_else(|| {
        let home = std::env::var_os("HOME").unwrap_or_default();
        PathBuf::from(home).join(".local/bin/tmx")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualifies_and_splits_targets() {
        let t = qualify("lab", "platform-agent-5", "2");
        assert_eq!(t, "lab/platform-agent-5:2");
        assert_eq!(split(&t), (Some("lab"), "platform-agent-5:2"));
        // an unqualified target stays usable against the enclosing server
        assert_eq!(split("dotfiles:1"), (None, "dotfiles:1"));
        assert_eq!(split("/dotfiles:1"), (None, "/dotfiles:1"));
    }

    #[test]
    fn parses_panes_with_their_server() {
        let text = "hub\t0\t/home/u\t42\t✳ title\tpinned \nshort\trow\n";
        let panes = parse_panes("hub", text);
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0].server, "hub");
        assert_eq!(panes[0].pid, 42);
        assert_eq!(panes[0].tags, "pinned");
    }
}
