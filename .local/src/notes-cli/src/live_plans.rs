//! The plans still being worked that name an open epic: what an `epic: new` shortlist reads beside
//! the board, so a plan for work an open epic already owns is shown before a twin epic is filed
//! (2026-11-24: ar-5349 copied ar-4724, whose plan was live). Whether a plan is live and which epic
//! it names is `.local/lib/plan-phases.sh`'s (`plan_open`, `_epic_line`), the one reader the queue
//! and fleet-sessions use: this module only picks the files to ask it about.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// A plan that is live work and names an open epic on its `epic: <id>` line.
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

/// The stowed plan reader, `~/.local/lib/plan-phases.sh`.
pub(crate) fn lib() -> PathBuf {
    crate::config::home().join(".local/lib/plan-phases.sh")
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

/// Every plan under `root` for `board` ([`dirs`]) that `lib` reads as live and whose epic is one of
/// `epics`. A plan in two directories (a session's copy and its project's cache) is the first one
/// found, by file name, whatever it says: a finished `_live` copy hides a stale cache. Only a first
/// copy with an `epic:` line naming one of `epics` ([`names_one`], a superset of the reader's) is
/// asked about, all in one `bash`, so thousands of plans cost one process. A reader that cannot run
/// lists no plans and says why on stderr.
pub(crate) fn read(root: &Path, board: &str, epics: &HashSet<String>, lib: &Path) -> Vec<LivePlan> {
    if epics.is_empty() {
        return Vec::new();
    }
    let mut seen = HashSet::new();
    let mut asked: Vec<(String, PathBuf, String)> = Vec::new();
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
            let Some(name) = f.file_name().map(|n| n.to_string_lossy().into_owned()) else {
                continue;
            };
            if !seen.insert(name.clone()) {
                continue;
            }
            let Ok(text) = fs::read_to_string(&f) else {
                continue;
            };
            if names_one(&text, epics) {
                asked.push((format!("{d}/{name}"), f, title(&text)));
            }
        }
    }
    if asked.is_empty() {
        return Vec::new();
    }
    let out = Command::new("bash")
        .arg("-c")
        .arg(r#"source "$1" || exit 2; shift
            for f; do plan_open "$f" || continue; e=$(_epic_line epic "$f"); [ -n "$e" ] && printf '%s\t%s\n' "$f" "$e"; done"#)
        .arg("live-plans")
        .arg(lib)
        .args(asked.iter().map(|a| &a.1))
        .output();
    let out = match out {
        Ok(o) if o.status.success() => o.stdout,
        Ok(o) => {
            eprintln!(
                "live plans: {} exited {}, so no plan is listed",
                lib.display(),
                o.status.code().unwrap_or(-1)
            );
            return Vec::new();
        }
        Err(e) => {
            eprintln!("live plans: bash cannot run ({e}), so no plan is listed");
            return Vec::new();
        }
    };
    let live: Vec<(PathBuf, String)> = String::from_utf8_lossy(&out)
        .lines()
        .filter_map(|l| {
            let (f, e) = l.split_once('\t')?;
            Some((PathBuf::from(f), e.to_string()))
        })
        .collect();
    asked
        .into_iter()
        .filter_map(|(file, path, title)| {
            let epic = live.iter().find(|(f, _)| *f == path)?.1.clone();
            epics
                .contains(&epic)
                .then_some(LivePlan { file, title, epic })
        })
        .collect()
}

/// Does a line `epic: <id>` name one of `epics`, the id followed by no digit: every plan the
/// reader's `_epic_line` would give one of them, and some it would not (a fenced example), which
/// the reader then settles.
fn names_one(text: &str, epics: &HashSet<String>) -> bool {
    text.lines().any(|l| {
        let Some(rest) = l.strip_prefix("epic:") else {
            return false;
        };
        let rest = rest.trim_start_matches([' ', '\t']);
        epics.iter().any(|e| {
            rest.strip_prefix(e.as_str())
                .is_some_and(|t| !t.starts_with(|c: char| c.is_ascii_digit()))
        })
    })
}

/// The first `# ` title outside a code fence, or nothing.
fn title(text: &str) -> String {
    let mut fenced = false;
    text.lines()
        .find_map(|l| {
            if l.starts_with("```") {
                fenced = !fenced;
                return None;
            }
            l.strip_prefix("# ").filter(|_| !fenced)
        })
        .map_or(String::new(), |t| t.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The repo's own plan reader, the one `read` runs.
    fn repo_lib() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../lib/plan-phases.sh")
    }

    #[test]
    fn names_one_takes_an_open_epic_id_and_not_a_longer_one() {
        let e: HashSet<String> = ["ar-12".to_string()].into();
        assert!(names_one("x\nepic: ar-12\n", &e));
        assert!(names_one("epic:\tar-12 (the dispatch epic)\n", &e));
        assert!(names_one("epic: ar-12abc\n", &e));
        assert!(!names_one("epic: ar-123\n", &e));
        assert!(!names_one("epic: new epic(ui): a lobby\n", &e));
        assert!(!names_one("Epic: ar-12\n", &e));
    }

    #[test]
    fn read_asks_the_shell_reader_about_first_copies_naming_an_open_epic() {
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
        // finished here, so its stale cache under brd/ is not read
        w(
            "_live/b.md",
            "# Done\n\nepic: br-2\n\n## Phases\n- [x] P1\n",
        );
        w(
            "brd/b.md",
            "# Done, stale cache\n\nepic: br-2\n\n## Phases\n- [ ] P1\n",
        );
        w("_live/c.md", "# No epic\n\n## Phases\n- [ ] P1\n");
        // a fenced example ahead of the real line: the reader takes the real one
        w(
            "_live/f.md",
            "# Fenced\n\n```\nepic: br-1\n```\n\nepic: br-3\n\n## Phases\n- [ ] P1\n",
        );
        w(
            "brd/a.md",
            "# Lobby work, cached\n\nepic: br-1\n\n## Phases\n- [ ] P1\n",
        );
        w("brd/d.md", "# Board plan\n\nepic: br-3\n");
        w(
            "brd/s.md",
            "# Gone\n\nSuperseded by br-1.\n\nepic: br-1\n\n## Phases\n- [ ] P1\n",
        );
        w("brd/z.md", "# Closed epic\n\nepic: br-9\n");
        w("other/e.md", "# Elsewhere\n\nepic: br-1\n");
        let epics: HashSet<String> = ["br-1", "br-2", "br-3"].map(String::from).into();
        let got: Vec<(String, String, String)> = read(&root, "brd", &epics, &repo_lib())
            .into_iter()
            .map(|p| (p.file, p.title, p.epic))
            .collect();
        assert_eq!(
            got,
            [
                ("_live/a.md".into(), "Lobby work".into(), "br-1".into()),
                ("_live/f.md".into(), "Fenced".into(), "br-3".into()),
                ("brd/d.md".into(), "Board plan".into(), "br-3".into()),
            ]
        );
        // a reader that cannot be sourced lists nothing
        assert!(read(&root, "brd", &epics, &root.join("missing.sh")).is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
