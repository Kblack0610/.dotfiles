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

    /// Build a map from any ancestor pid → the Claude pid below it.
    ///
    /// For each live Claude pid we walk *up* its ancestry (claude → shell →
    /// tmux server …) and record every ancestor as pointing back at that
    /// Claude pid. A pane reports the shell's pid as `pane_pid`; after this
    /// pass, resolving pane→Claude is an O(1) lookup. Mirrors the old
    /// `__build_claude_pid_map` bash routine, last-writer-wins.
    pub fn pane_to_claude(&self, claude_pids: &[u32]) -> HashMap<u32, u32> {
        let mut map = HashMap::new();
        for &cpid in claude_pids {
            if !self.is_live(cpid) {
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
    fn skips_dead_claude_pids() {
        let pm = map_from(&[(200, 100)]);
        let m = pm.pane_to_claude(&[999]);
        assert!(m.is_empty());
    }
}
