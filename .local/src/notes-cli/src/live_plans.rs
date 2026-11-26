//! The plans still being worked that name an epic: what an `epic: new` shortlist reads beside
//! the board, so a plan for work an open epic already owns is shown before a twin epic is filed
//! (2026-11-24: ar-5349 copied ar-4724, whose plan was live). The reading of a plan is
//! `.local/lib/plan-phases.sh`'s (`plan_open`, `plan_superseded`, `_epic_line`), the one the
//! queue and fleet-sessions use.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

/// A plan that is not finished and names an epic on its `epic: <id>` line.
pub(crate) struct LivePlan {
    /// Its directory under the plans root and its file name, `_live/x.md`.
    pub file: String,
    /// Its `# ` title.
    pub title: String,
    /// The id on its `epic:` line.
    pub epic: String,
}

/// `~/.agent/plans`, under `$HOME` so a test's sandbox redirects it.
pub(crate) fn root() -> PathBuf {
    crate::config::home().join(".agent/plans")
}

/// The plan directories a board's plans are in: `_live` (every session's), the board's own, and
/// each project the project map files on this board (`owner` or `board`), as `project_board` in
/// `project-name.sh` resolves one.
fn dirs(board: &str) -> Vec<String> {
    let mut v = vec!["_live".to_string(), board.to_string()];
    if let Some(reg) = project_map::cached() {
        for (name, t) in reg.trackers() {
            let on = ["owner", "board"]
                .iter()
                .any(|k| t.get(*k).and_then(|v| v.as_str()) == Some(board));
            if on && !v.iter().any(|d| d == name) {
                v.push(name.to_string());
            }
        }
    }
    v
}

/// Every plan under `root` for `board` ([`dirs`]) that is not finished ([`open`]) and names an
/// epic. A plan in two directories (a session's copy and its project's cache) is read once, by
/// file name, from the first.
pub(crate) fn read(root: &Path, board: &str) -> Vec<LivePlan> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for d in dirs(board) {
        let Ok(entries) = fs::read_dir(root.join(&d)) else {
            continue;
        };
        let mut files: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "md") && p.is_file())
            .collect();
        files.sort();
        for f in files {
            let name = f.file_name().map(|n| n.to_string_lossy().into_owned());
            let Some(name) = name.filter(|n| !seen.contains(n)) else {
                continue;
            };
            let Ok(text) = fs::read_to_string(&f) else {
                continue;
            };
            let Some(epic) = epic_line(&text).filter(|_| open(&text)) else {
                continue;
            };
            seen.insert(name.clone());
            out.push(LivePlan {
                file: format!("{d}/{name}"),
                title: title(&text),
                epic,
            });
        }
    }
    out
}

/// The `# ` title, or nothing.
fn title(text: &str) -> String {
    text.lines()
        .find_map(|l| l.strip_prefix("# "))
        .map_or(String::new(), |t| t.trim().to_string())
}

/// The id of the first `epic: <code>-<N>` line (`_epic_line`): an `epic: new` proposal names none.
fn epic_line(text: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let rest = l.strip_prefix("epic:")?.trim_start();
        let end = rest
            .find(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'))
            .unwrap_or(rest.len());
        let id = &rest[..end];
        let (code, n) = id.rsplit_once('-')?;
        let ok = !code.is_empty()
            && !code.contains('-')
            && !n.is_empty()
            && n.bytes().all(|b| b.is_ascii_digit());
        ok.then(|| id.to_string())
    })
}

/// Is the plan live work (`plan_open`): not superseded, and a `## Phases` item still `- [ ]`,
/// or no checklist and no `## Results` yet.
fn open(text: &str) -> bool {
    if superseded(text) {
        return false;
    }
    let (mut total, mut left, mut inp) = (0, 0, false);
    for l in text.lines() {
        if l.starts_with("## ") {
            inp = l == "## Phases" || l.starts_with("## Phases ") || l.starts_with("## Phases\t");
            continue;
        }
        if !inp {
            continue;
        }
        let mark = l
            .strip_prefix("- [")
            .or_else(|| l.strip_prefix("* ["))
            .and_then(|r| {
                let mut c = r.chars();
                let m = c.next()?;
                c.as_str().starts_with("] ").then_some(m)
            });
        match mark {
            Some('x' | 'X' | '-') => total += 1,
            Some(' ') => {
                total += 1;
                left += 1;
            }
            _ => {}
        }
    }
    if total == 0 {
        return !text
            .lines()
            .any(|l| l.to_ascii_lowercase().starts_with("## results"));
    }
    left > 0
}

/// Does the first line under the `# ` title say `Superseded by` (`plan_superseded`).
fn superseded(text: &str) -> bool {
    text.lines()
        .skip_while(|l| !l.starts_with("# "))
        .skip(1)
        .find(|l| !l.trim().is_empty())
        .is_some_and(|l| {
            l.trim_start_matches(['>', '*', '_', ' '])
                .to_ascii_lowercase()
                .starts_with("superseded by")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_is_live_while_a_phase_is_open_or_it_has_no_checklist_and_no_results() {
        let p = |body: &str| format!("# Title\n\nepic: ar-7\n\n{body}");
        assert!(open(&p("## Phases\n\n- [x] P1 a (#1)\n- [ ] P2 b\n")));
        assert!(!open(&p("## Phases\n\n- [x] P1 a\n- [-] P2 b\n")));
        assert!(open(&p("## Context\n\nwork\n")));
        assert!(!open(&p("## Results\n\nlanded #3\n")));
        // an indented item is a step, and an item under another heading is no phase
        assert!(!open(&p(
            "## Phases\n\n- [x] P1 a\n  - [ ] step\n\n## Notes\n- [ ] x\n"
        )));
        assert!(!open(
            "# T\n\nSuperseded by ar-4724 (`_live/x.md`).\n\n## Phases\n- [ ] P1\n"
        ));
    }

    #[test]
    fn the_epic_line_names_an_id_and_a_proposal_names_none() {
        assert_eq!(epic_line("x\nepic: ar-4724\n").as_deref(), Some("ar-4724"));
        assert_eq!(
            epic_line("epic: ar-12 (the dispatch epic)\n").as_deref(),
            Some("ar-12")
        );
        assert_eq!(epic_line("epic: new epic(ui): a lobby\n"), None);
        assert_eq!(epic_line("Epic: ar-1\n"), None);
    }

    #[test]
    fn read_takes_the_live_and_board_dirs_and_skips_finished_and_unepiced_plans() {
        let root = std::env::temp_dir().join(format!("live-plans-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for d in ["_live", "brd", "other"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        let w = |f: &str, s: &str| fs::write(root.join(f), s).unwrap();
        w(
            "_live/a.md",
            "# Lobby work\n\nepic: br-1\n\n## Phases\n- [ ] P1\n",
        );
        w(
            "_live/b.md",
            "# Done\n\nepic: br-2\n\n## Phases\n- [x] P1\n",
        );
        w("_live/c.md", "# No epic\n\n## Phases\n- [ ] P1\n");
        w(
            "brd/a.md",
            "# Lobby work, cached\n\nepic: br-1\n\n## Phases\n- [ ] P1\n",
        );
        w("brd/d.md", "# Board plan\n\nepic: br-3\n");
        w("other/e.md", "# Elsewhere\n\nepic: ot-1\n");
        let got: Vec<(String, String, String)> = read(&root, "brd")
            .into_iter()
            .map(|p| (p.file, p.title, p.epic))
            .collect();
        assert_eq!(
            got,
            [
                ("_live/a.md".into(), "Lobby work".into(), "br-1".into()),
                ("brd/d.md".into(), "Board plan".into(), "br-3".into()),
            ]
        );
        let _ = fs::remove_dir_all(&root);
    }
}
