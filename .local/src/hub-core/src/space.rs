//! A project's knowledge space: the one read behind the page's Knowledge tab, on agent-web and
//! the hub TUI. `notes projects <name> --json` owns the files and the sheet's numbers (the lab
//! dir's docs, the repo's docs, ADRs and CHANGELOG head, the agent runtime's plans, lessons,
//! sessions and outcomes, the knowledge notes that name the project, the stage, the waves, the
//! cadence); this module adds what `notes` does not own, the project's open asks
//! (`agent-ask`) and live queue items (`agent-queue`), and says the words. A source that fails
//! is named in `errors` and the rest of the space still shows. Field list: notes-cli README,
//! "The project page".

use serde::{Deserialize, Serialize};

use crate::boards::{self, Ask, AskSet};
use crate::queue::{self, Item};
use crate::session_actions::Runner;

/// One file in a list: its path from the list's root, its first heading and its modified day.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Doc {
    pub path: String,
    pub title: String,
    pub modified: String,
}

/// A knowledge note that names the project, and why: `path`, `frontmatter` or `body`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Note {
    pub path: String,
    pub title: String,
    pub why: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Counts {
    pub open: usize,
    pub done: usize,
    pub planned: usize,
    pub agent: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Status {
    pub headline: String,
    pub date: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WaveProgress {
    pub open: usize,
    pub done: usize,
}

/// A version on the roadmap: the open one, a later one rows are aimed at, or a shipped one.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Wave {
    pub version: String,
    pub state: String,
    pub goal: String,
    pub progress: WaveProgress,
}

/// The cadence the stage promises against the one the cuts measured.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cadence {
    pub target_days: i64,
    /// Median days between the last few cuts; None with fewer than two dated cuts.
    pub measured_days: Option<i64>,
    pub cuts: usize,
    pub last_cut: Option<String>,
    pub due_on: Option<String>,
    pub due: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Registry {
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub path: Option<String>,
    pub branch: Option<String>,
    pub tag_glob: Option<String>,
    pub code: Option<String>,
    pub has_repo: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tracker {
    pub system: Option<String>,
    pub github: Option<String>,
    pub forgejo: Option<String>,
    pub urls: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Lab {
    pub dir: String,
    pub core: Vec<Doc>,
    pub docs: Vec<Doc>,
    pub versions: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Repo {
    pub repo: String,
    pub root: String,
    pub readme: bool,
    pub docs: Vec<Doc>,
    pub adrs: Vec<Doc>,
    pub changelog_head: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Lessons {
    pub path: Option<String>,
    pub count: usize,
    pub modified: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Agent {
    pub plans: Vec<Doc>,
    pub sessions: Vec<Doc>,
    pub outcomes: Vec<Doc>,
    pub lessons: Lessons,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Space {
    pub project: String,
    pub profile: String,
    pub stage: String,
    pub version: String,
    pub goal: String,
    pub counts: Counts,
    pub status: Status,
    pub waves: Vec<Wave>,
    pub cadence: Cadence,
    pub registry: Registry,
    pub tracker: Tracker,
    pub lab: Lab,
    /// None for a project with no repo, or none cloned here: an empty section, never an error.
    pub repo: Option<Repo>,
    pub agent: Agent,
    pub knowledge: Vec<Note>,
    /// The project's open asks (`agent-ask list --pending`).
    #[serde(skip_deserializing)]
    pub asks: Vec<Ask>,
    /// The project's live queue items (`agent-queue list --state active`).
    #[serde(skip_deserializing)]
    pub queue: Vec<Item>,
    #[serde(skip_deserializing)]
    pub errors: Vec<String>,
}

/// The cadence as a sentence: `every 14 days promised, 16 measured over 8 cuts, due 2026-12-02`.
pub fn cadence_says(c: &Cadence) -> String {
    let mut s = format!("every {} days promised", c.target_days);
    match c.measured_days {
        Some(m) => s += &format!(", {m} measured over {} cuts", c.cuts),
        None => s += ", none measured yet",
    }
    if let Some(d) = &c.due_on {
        s += &format!(", due {d}{}", if c.due { " (due now)" } else { "" });
    }
    s
}

/// The page: `notes projects <name> --json`, then the project's asks and queue items.
pub fn read(runner: &dyn Runner, name: &str) -> Result<Space, String> {
    if !crate::projects::safe_name(name) {
        return Err(format!("refusing project name {name:?}"));
    }
    let out = runner.run(&[
        "notes".into(),
        "projects".into(),
        name.into(),
        "--json".into(),
    ])?;
    let mut s: Space =
        serde_json::from_str(&out).map_err(|e| format!("notes projects {name} --json: {e}"))?;
    let mine = |p: &str| p.eq_ignore_ascii_case(&s.project);
    match boards::ask_list(runner, AskSet::Pending) {
        Ok(asks) => s.asks = asks.into_iter().filter(|a| mine(&a.project)).collect(),
        Err(e) => s.errors.push(format!("agent-ask list: {e}")),
    }
    match queue::list(runner, "active") {
        Ok(items) => s.queue = items.into_iter().filter(|i| mine(&i.project)).collect(),
        Err(e) => s.errors.push(format!("agent-queue list: {e}")),
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(Vec<(&'static str, Result<String, String>)>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            let head = argv.first().map(String::as_str).unwrap_or("");
            self.0
                .iter()
                .find(|(k, _)| *k == head)
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| Err(format!("no answer for {head}")))
        }
    }

    const PAGE: &str = r#"{"project":"garden","profile":"personal","stage":"dev","version":"v0.2.0",
        "counts":{"open":3,"done":9,"planned":1,"agent":2},
        "status":{"headline":"beds dug","date":"2026-11-20"},
        "waves":[{"version":"v0.2.0","state":"current","goal":"","progress":{"open":3,"done":9}}],
        "cadence":{"target_days":7,"measured_days":9,"cuts":4,"last_cut":"2026-11-18","due_on":"2026-11-25","due":true},
        "registry":{"type":"app","has_repo":true},
        "tracker":{"system":"board","urls":[]},
        "lab":{"dir":"/x","core":[{"path":"README.md","title":"Garden","modified":"2026-11-01"}],"docs":[],"versions":2},
        "repo":null,
        "agent":{"plans":[],"sessions":[],"outcomes":[],"lessons":{"path":null,"count":0,"modified":""}},
        "knowledge":[{"path":"projects/garden/soil.md","title":"Soil","why":"path"}]}"#;

    #[test]
    fn the_page_joins_only_this_projects_asks_and_queue_items() {
        let queue = r#"{"slug":"a-1","state":"running","project":"garden"}
{"slug":"a-2","state":"queued","project":"other"}"#;
        let r = Fake(vec![
            ("notes", Ok(PAGE.into())),
            ("agent-ask", Ok(String::new())),
            ("agent-queue", Ok(queue.into())),
        ]);
        let s = read(&r, "garden").unwrap();
        assert_eq!(s.stage, "dev");
        assert_eq!(s.lab.core[0].title, "Garden");
        assert_eq!(s.knowledge[0].why, "path");
        assert!(s.repo.is_none());
        assert_eq!(
            s.queue.iter().map(|i| i.slug.as_str()).collect::<Vec<_>>(),
            ["a-1"]
        );
        assert!(s.errors.is_empty(), "{:?}", s.errors);
    }

    #[test]
    fn a_failed_ask_or_queue_read_is_named_and_the_page_still_shows() {
        let r = Fake(vec![
            ("notes", Ok(PAGE.into())),
            ("agent-ask", Err("down".into())),
            ("agent-queue", Err("down".into())),
        ]);
        let s = read(&r, "garden").unwrap();
        assert_eq!(s.project, "garden");
        assert_eq!(s.errors.len(), 2);
        assert!(s.errors[0].starts_with("agent-ask list"));
    }

    #[test]
    fn a_name_notes_does_not_know_is_an_error_not_an_empty_page() {
        let r = Fake(vec![("notes", Err("no current project named 'x'".into()))]);
        assert!(read(&r, "x").is_err());
        assert!(read(&r, "../etc").is_err());
    }

    #[test]
    fn the_cadence_reads_as_promised_against_measured() {
        let s: Space = serde_json::from_str(PAGE).unwrap();
        assert_eq!(
            cadence_says(&s.cadence),
            "every 7 days promised, 9 measured over 4 cuts, due 2026-11-25 (due now)"
        );
        let none = Cadence {
            target_days: 14,
            ..Default::default()
        };
        assert_eq!(
            cadence_says(&none),
            "every 14 days promised, none measured yet"
        );
    }
}
