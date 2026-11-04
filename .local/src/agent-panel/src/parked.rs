//! Parked sessions: the ledgers `claude-acct park` writes, one file per tmux session under
//! `$CLAUDE_ACCT_PARKED_DIR` (default `~/.agent/parked`), `key=value` lines. claude-acct is
//! the only writer; this reads them so a parked session, whose claude has exited, still
//! shows as a row. A file starting with `.` is a ledger still being written: skipped.

use std::fs;
use std::path::{Path, PathBuf};

/// One park ledger.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parked {
    /// The tmux session name (the file name).
    pub session: String,
    pub server: String,
    /// `<server>/<session>:<window>`, as park recorded it.
    pub target: String,
    /// The pane's `%N` on `server`.
    pub pane: String,
    pub session_id: String,
    pub cwd: String,
    /// The account dir it was parked from (empty: the default account).
    pub from: String,
    /// `park` or `move` (a move whose resume did not finish).
    pub why: String,
    /// Epoch seconds it was parked.
    pub parked: u64,
}

/// `$CLAUDE_ACCT_PARKED_DIR`, else `~/.agent/parked`, as claude-acct resolves it.
pub fn root() -> PathBuf {
    std::env::var_os("CLAUDE_ACCT_PARKED_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::session::home().join(".agent").join("parked"))
}

fn get<'a>(text: &'a str, key: &str) -> &'a str {
    text.lines()
        .find_map(|l| l.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
        .unwrap_or("")
}

/// Parse one ledger; None when it names no server (not a ledger claude-acct would resume).
pub fn parse(session: &str, text: &str) -> Option<Parked> {
    let server = get(text, "server");
    if server.is_empty() {
        return None;
    }
    let target = match get(text, "target") {
        "" => format!("{server}/{session}"),
        t => t.to_string(),
    };
    Some(Parked {
        session: session.to_string(),
        server: server.to_string(),
        target,
        pane: get(text, "pane").to_string(),
        session_id: get(text, "session_id").to_string(),
        cwd: get(text, "cwd").to_string(),
        from: get(text, "from").to_string(),
        why: get(text, "why").to_string(),
        parked: get(text, "parked").parse().unwrap_or(0),
    })
}

/// Every ledger under `root`, sorted by session name.
pub fn load(root: &Path) -> Vec<Parked> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<Parked> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                return None;
            }
            parse(&name, &fs::read_to_string(e.path()).ok()?)
        })
        .collect();
    out.sort_by(|a, b| a.session.cmp(&b.session));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_ledgers_and_skips_one_being_written() {
        let root = std::env::temp_dir().join(format!("agent-panel-parked-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("agent-1"),
            "session=agent-1\nserver=lab\ntarget=lab/agent-1:1\npane=%5\ndirect=0\npid=101\n\
             session_id=sid-1\ncwd=/home/u/wt\nfrom=/home/u/.claude-bnb\nstatus=idle\nwhy=park\n\
             parked=1700000000\nresume=claude --resume sid-1\n",
        )
        .unwrap();
        // An older ledger with no window in its target.
        fs::write(root.join("agent-2"), "server=hub\npane=%9\nwhy=move\n").unwrap();
        fs::write(root.join(".agent-3.Xy12ab"), "server=lab\n").unwrap();
        fs::write(root.join("junk"), "not a ledger\n").unwrap();

        let got = load(&root);
        let _ = fs::remove_dir_all(&root);
        assert_eq!(got.len(), 2, "{got:?}");
        assert_eq!(got[0].target, "lab/agent-1:1");
        assert_eq!(got[0].pane, "%5");
        assert_eq!(got[0].from, "/home/u/.claude-bnb");
        assert_eq!(got[0].parked, 1_700_000_000);
        assert_eq!(got[1].target, "hub/agent-2");
        assert_eq!(got[1].why, "move");
    }

    #[test]
    fn a_missing_dir_is_nothing_parked() {
        assert!(load(Path::new("/nonexistent/agent-panel-parked")).is_empty());
    }
}
