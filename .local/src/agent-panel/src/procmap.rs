//! `ps`-based process table + pane→Claude pid mapping.
//!
//! This is the portable replacement for the old `/proc`-walking logic. macOS
//! has no `/proc`, but both macOS/BSD and Linux/procps support
//! `ps -axo pid=,ppid=`, which gives us the full child→parent edge list.

use std::collections::HashMap;
use std::process::Command;

use anyhow::{Context, Result};

/// Child pid to parent pid for every live process, and each one's command name.
pub struct ProcMap {
    ppid: HashMap<u32, u32>,
    comm: HashMap<u32, String>,
}

impl ProcMap {
    /// Capture the live process table via `ps -axo pid=,ppid=,comm=`.
    pub fn capture() -> Result<Self> {
        let out = Command::new("ps")
            .args(["-axo", "pid=,ppid=,comm="])
            .output()
            .context("failed to run `ps -axo pid=,ppid=,comm=`")?;
        anyhow::ensure!(
            out.status.success(),
            "`ps -axo pid=,ppid=,comm=` exited {}",
            out.status
        );
        Ok(Self::parse(&String::from_utf8_lossy(&out.stdout)))
    }

    /// The `ps -axo pid=,ppid=,comm=` lines; comm is the rest of the line (macOS gives a path).
    fn parse(text: &str) -> Self {
        let (mut ppid, mut comm) = (HashMap::new(), HashMap::new());
        // Columns are space-padded, so take each number off the front and keep the rest whole.
        let field = |s: &str| {
            let s = s.trim_start();
            let end = s.find(char::is_whitespace).unwrap_or(s.len());
            (s[..end].to_string(), s[end..].to_string())
        };
        for line in text.lines() {
            let (p, rest) = field(line);
            let (pp, rest) = field(&rest);
            if let (Ok(p), Ok(pp)) = (p.parse::<u32>(), pp.parse::<u32>()) {
                ppid.insert(p, pp);
                comm.insert(p, rest.trim().to_string());
            }
        }
        Self { ppid, comm }
    }

    /// Is this pid a live process?
    pub fn is_live(&self, pid: u32) -> bool {
        self.ppid.contains_key(&pid)
    }

    /// The ancestors of `pid`, nearest first, up to 20 levels and short of init.
    fn ancestors(&self, pid: u32) -> impl Iterator<Item = u32> + '_ {
        std::iter::successors(Some(pid), |p| self.ppid.get(p).copied())
            .skip(1)
            .take(20)
            .take_while(|&p| p > 1)
    }

    /// The outermost `codex` process below `pane_pid` (the pane's own process included), the
    /// lowest pid of two such siblings so a refresh reads the same one, or None.
    /// A Codex run in a pane is the fleet's other harness: it has no `~/.claude/sessions` file, so
    /// the pane-to-Claude map never sees it.
    pub fn codex_below(&self, pane_pid: u32) -> Option<u32> {
        let is_codex = |p: &u32| {
            self.comm
                .get(p)
                .is_some_and(|c| c.rsplit('/').next() == Some("codex"))
        };
        self.ppid
            .keys()
            .filter(|p| is_codex(p))
            .filter(|&&p| p == pane_pid || self.ancestors(p).any(|a| a == pane_pid))
            .filter(|&&p| !self.ancestors(p).any(|a| is_codex(&a)))
            .min()
            .copied()
    }

    /// Build a map from any ancestor pid → the Claude pid below it.
    ///
    /// For each live Claude pid we walk *up* its ancestry (claude → shell →
    /// tmux server …) and record every ancestor as pointing back at that
    /// Claude pid. A pane reports the shell's pid as `pane_pid`; after this
    /// pass, resolving pane→Claude is an O(1) lookup.
    ///
    /// A Claude with a live Claude above it (an sdk-cli session run under an
    /// interactive one) is skipped: the pane is the outer one's. Both would
    /// otherwise claim the same ancestors and the caller's pid order would
    /// pick the pane's Claude.
    pub fn pane_to_claude(&self, claude_pids: &[u32]) -> HashMap<u32, u32> {
        let mut map = HashMap::new();
        for &cpid in claude_pids {
            if !self.is_live(cpid) || self.ancestors(cpid).any(|p| claude_pids.contains(&p)) {
                continue;
            }
            map.insert(cpid, cpid); // direct hit (claude is the pane process)
            for pp in self.ancestors(cpid) {
                map.insert(pp, cpid);
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
            comm: HashMap::new(),
        }
    }

    #[test]
    fn parses_ps_lines_with_their_command_names() {
        let pm = ProcMap::parse(
            "  100     1 tmux: server\n  200   100 zsh\n  300   200 /usr/bin/codex\n",
        );
        assert!(pm.is_live(300));
        assert_eq!(pm.comm.get(&100).map(String::as_str), Some("tmux: server"));
        assert_eq!(pm.codex_below(200), Some(300));
    }

    #[test]
    fn codex_below_finds_the_outermost_codex_under_the_pane_only() {
        // pane shell(200) -> timeout(210) -> bash(220) -> codex(300) -> codex(310, its helper)
        // another pane shell(400) -> claude(500)
        let pm = ProcMap::parse(
            "200 100 zsh\n210 200 timeout\n220 210 bash\n300 220 codex\n310 300 codex\n400 100 zsh\n500 400 claude\n",
        );
        assert_eq!(pm.codex_below(200), Some(300));
        assert_eq!(pm.codex_below(400), None);
        assert_eq!(pm.codex_below(999), None);
        // two sibling runs under one shell: the lower pid, whatever the table's order
        let pm = ProcMap::parse("200 100 zsh\n320 200 codex\n300 200 codex\n");
        assert_eq!(pm.codex_below(200), Some(300));
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
    fn three_deep_nesting_resolves_to_the_outermost() {
        // shell(200) -> claude(300) -> claude(400) -> claude(500)
        let pm = map_from(&[(500, 400), (400, 300), (300, 200), (200, 100), (100, 1)]);
        let m = pm.pane_to_claude(&[500, 400, 300]);
        assert_eq!(m.get(&200), Some(&300));
        assert_eq!(m.get(&400), None);
    }

    #[test]
    fn nested_claude_keeps_the_pane_when_the_outer_one_is_not_in_the_list() {
        let pm = map_from(&[(500, 400), (400, 300), (300, 200), (200, 100), (100, 1)]);
        let m = pm.pane_to_claude(&[500]);
        assert_eq!(m.get(&200), Some(&500));
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
