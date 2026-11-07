//! `ps`-based process table + pane→Claude pid mapping.
//!
//! This is the portable replacement for the old `/proc`-walking logic. macOS
//! has no `/proc`, but both macOS/BSD and Linux/procps support
//! `ps -axo pid=,ppid=`, which gives us the full child→parent edge list.

use std::collections::HashMap;
use std::process::Command;

use anyhow::{Context, Result};

/// Child-pid → parent-pid for every live process.
pub struct ProcMap {
    ppid: HashMap<u32, u32>,
}

impl ProcMap {
    /// Capture the live process table via `ps -axo pid=,ppid=`.
    pub fn capture() -> Result<Self> {
        let out = Command::new("ps")
            .args(["-axo", "pid=,ppid="])
            .output()
            .context("failed to run `ps -axo pid=,ppid=`")?;
        let text = String::from_utf8_lossy(&out.stdout);
        let mut ppid = HashMap::new();
        for line in text.lines() {
            let mut it = line.split_whitespace();
            if let (Some(p), Some(pp)) = (it.next(), it.next()) {
                if let (Ok(p), Ok(pp)) = (p.parse::<u32>(), pp.parse::<u32>()) {
                    ppid.insert(p, pp);
                }
            }
        }
        Ok(Self { ppid })
    }

    /// Is this pid a live process?
    pub fn is_live(&self, pid: u32) -> bool {
        self.ppid.contains_key(&pid)
    }

    /// Does a live process in `claude_pids` sit above `pid`?
    fn has_claude_ancestor(&self, pid: u32, claude_pids: &[u32]) -> bool {
        let mut cur = pid;
        for _ in 0..20 {
            let Some(&pp) = self.ppid.get(&cur) else { return false };
            if pp <= 1 {
                return false;
            }
            if claude_pids.contains(&pp) {
                return true;
            }
            cur = pp;
        }
        false
    }

    /// Build a map from any ancestor pid → the Claude pid below it.
    ///
    /// For each live Claude pid we walk *up* its ancestry (claude → shell →
    /// tmux server …) and record every ancestor as pointing back at that
    /// Claude pid. A pane reports the shell's pid as `pane_pid`; after this
    /// pass, resolving pane→Claude is an O(1) lookup. Mirrors the old
    /// `__build_claude_pid_map` bash routine.
    ///
    /// A Claude with a live Claude above it (an sdk-cli session a skill or
    /// hook runs under an interactive one) is skipped: the pane is the outer
    /// one's. Left in, both walk the same ancestors and the pane resolved to
    /// whichever the caller's pid order put last, so a queue item's own session
    /// dropped off the list on some reads and reap failed it live (ar-932).
    pub fn pane_to_claude(&self, claude_pids: &[u32]) -> HashMap<u32, u32> {
        let mut map = HashMap::new();
        for &cpid in claude_pids {
            if !self.is_live(cpid) || self.has_claude_ancestor(cpid, claude_pids) {
                continue;
            }
            map.insert(cpid, cpid); // direct hit (claude is the pane process)
            let mut cur = cpid;
            let mut depth = 0;
            while depth < 20 {
                let Some(&pp) = self.ppid.get(&cur) else { break };
                if pp <= 1 {
                    break;
                }
                map.insert(pp, cpid);
                cur = pp;
                depth += 1;
            }
        }
        map
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map_from(edges: &[(u32, u32)]) -> ProcMap {
        ProcMap {
            ppid: edges.iter().copied().collect(),
        }
    }

    #[test]
    fn walks_ancestry_to_claude_pid() {
        // tmux(100) -> shell(200) -> claude(300)
        let pm = map_from(&[(300, 200), (200, 100), (100, 1)]);
        let m = pm.pane_to_claude(&[300]);
        assert_eq!(m.get(&300), Some(&300)); // direct
        assert_eq!(m.get(&200), Some(&300)); // pane shell resolves to claude
        assert_eq!(m.get(&100), Some(&300)); // tmux server too (harmless)
    }

    #[test]
    fn nested_claude_never_takes_the_pane_from_the_outer_one() {
        // tmux(100) -> shell(200) -> claude(300) -> bash(400) -> claude(500, sdk-cli)
        let pm = map_from(&[(500, 400), (400, 300), (300, 200), (200, 100), (100, 1)]);
        // Either order of the caller's pids resolves the pane to the outer Claude.
        for pids in [[300, 500], [500, 300]] {
            let m = pm.pane_to_claude(&pids);
            assert_eq!(m.get(&200), Some(&300), "{pids:?}");
            assert_eq!(m.get(&300), Some(&300), "{pids:?}");
            assert_eq!(m.get(&500), None, "{pids:?}");
        }
    }

    #[test]
    fn sibling_claudes_in_other_panes_both_map() {
        // tmux(100) -> shell(200) -> claude(300); tmux(100) -> shell(210) -> claude(310)
        let pm = map_from(&[(300, 200), (310, 210), (200, 100), (210, 100), (100, 1)]);
        let m = pm.pane_to_claude(&[300, 310]);
        assert_eq!(m.get(&200), Some(&300));
        assert_eq!(m.get(&210), Some(&310));
    }

    #[test]
    fn skips_dead_claude_pids() {
        let pm = map_from(&[(200, 100)]);
        let m = pm.pane_to_claude(&[999]);
        assert!(m.is_empty());
    }
}
