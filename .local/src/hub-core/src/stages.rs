//! The Ladder inner tab of Projects, both surfaces: the stage gate, the nightly stage filer and
//! which row kinds dispatch runs, then where each staged project stands on its next stage, then
//! every Requirements row of stages.md. Three stores, each read once here (dashboards rule 8):
//!
//! | part         | store |
//! |--------------|-------|
//! | projects     | `stages.json`, written by the private `agentctl-project-index` nightly stage pass |
//! | requirements | `project-stage-check --requirements --json`, the one stages.md parser |
//! | kinds        | `~/.config/fleet-dispatch/kinds.json`, `enabled` per row kind |
//!
//! Every number is the check's own count; this module only orders the rows and words the lines,
//! so the TUI and the web print the same. A store that could not be read says so in
//! `hub_core::reading`'s words, never as an empty table (rule 6).

use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::links::{Kind, Link};
use crate::reading::{self, State};
use crate::session_actions::Runner;
use crate::table::{Row, Val};
use crate::vocab::Level;

/// stages.json is written once a night; a day and a half without a new one is a stopped filer.
pub const STALE_SECS: i64 = 36 * 3600;

/// Where the doc a surface links in the tab's head lives.
pub const DOC: &str = "~/.local/src/docs/stages.md";

/// The check-kind words both surfaces print, the mockup's: a predicate that runs, a human
/// sign-off, and a row with no check yet (a TODO, never a failure: rule 6).
pub const TEST: &str = "test";
pub const HUMAN: &str = "human";
pub const NOT_YET: &str = "not yet";

/// A project's state words: the check could not run, a row of its next stage fails, or none does.
pub const NOT_READ: &str = reading::NOT_READ;
pub const FAILING: &str = "failing";
pub const MET: &str = "met";

#[derive(Clone, Debug)]
pub struct Paths {
    pub stages: PathBuf,
    pub kinds: PathBuf,
}

impl Paths {
    /// The stores' homes, each movable by the env its writer reads (`AGENTCTL_INBOX` for the
    /// project-index runner, `DISPATCH_KINDS` for fleet-dispatch).
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let var = |k: &str| {
            std::env::var(k)
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        Paths {
            stages: var("AGENTCTL_INBOX")
                .unwrap_or_else(|| home.join(".local/state/agentctl/project-index"))
                .join("stages.json"),
            kinds: var("DISPATCH_KINDS")
                .unwrap_or_else(|| home.join(".config/fleet-dispatch/kinds.json")),
        }
    }
}

/// One staged project on its next stage (prod checks itself), as the nightly pass counted it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Project {
    pub name: String,
    pub profile: String,
    pub stage: String,
    pub next: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub met: u32,
    pub total: u32,
    pub fail: u32,
    pub todo: u32,
    pub human: u32,
    /// Rows `project-stage-check --file` filed on the agent sheet, still open and closed.
    pub filed_open: u32,
    pub filed_closed: u32,
    /// Why the check could not run; its counts are then unknown, never zero.
    pub error: Option<String>,
    /// Where `stage` sits on the ladder, lowest first; what the STAGE column sorts by.
    #[serde(skip_deserializing)]
    pub stage_rank: Option<usize>,
    /// `failing`, `met` or `not read`, and the cells both surfaces print.
    #[serde(skip_deserializing)]
    pub state: &'static str,
    #[serde(skip_deserializing)]
    pub met_says: String,
    #[serde(skip_deserializing)]
    pub filed_says: String,
}

impl Project {
    pub fn key(&self) -> String {
        format!("{}/{}", self.profile, self.name)
    }

    fn worded(mut self, ladder: &[String]) -> Project {
        self.stage_rank = ladder.iter().position(|s| *s == self.stage);
        self.state = match (&self.error, self.fail) {
            (Some(_), _) => NOT_READ,
            (None, 0) => MET,
            _ => FAILING,
        };
        self.met_says = match self.error {
            Some(_) => NOT_READ.into(),
            None => format!("{}/{}", self.met, self.total),
        };
        self.filed_says = format!("{}/{}", self.filed_open, self.filed_closed);
        self
    }

    /// Worst first: a check that could not run, then the most failing rows.
    fn order(&self) -> (u8, std::cmp::Reverse<u32>) {
        let s = match self.state {
            NOT_READ => 0,
            FAILING => 1,
            _ => 2,
        };
        (s, std::cmp::Reverse(self.fail))
    }
}

fn word(s: &str) -> Val {
    if s.is_empty() {
        Val::None
    } else {
        Val::Text(s.to_string())
    }
}

impl Row for Project {
    const COLUMNS: &'static [&'static str] = &[
        "project", "type", "stage", "next", "met", "failing", "filed",
    ];
    const STATES: &'static [&'static str] = &["all", FAILING, MET, NOT_READ];
    const FACETS: &'static [&'static str] = &["type", "stage"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["stage", "met", "failing"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            FAILING,
            "a row of its next stage fails its check; the nightly pass files each as a story",
        ),
        (MET, "every row of its next stage that has a check passes"),
        (
            NOT_READ,
            "project-stage-check could not run; the opened row says why",
        ),
    ];
    const TONES: &'static [(&'static str, Level)] = &[
        (FAILING, Level::Bad),
        (MET, Level::Ok),
        (NOT_READ, Level::Bad),
    ];

    fn val(&self, col: &str) -> Val {
        match col {
            "project" => word(&self.name),
            "type" => word(self.kind.as_deref().unwrap_or("")),
            "stage" => word(&self.stage),
            "next" => word(&self.next),
            "met" if self.error.is_some() || self.total == 0 => Val::None,
            "met" => Val::Num(f64::from(self.met) / f64::from(self.total)),
            "failing" if self.error.is_some() => Val::None,
            "failing" => Val::Num(f64::from(self.fail)),
            "filed" => Val::Num(f64::from(self.filed_open)),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.state == s
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            "stage" => self.stage_rank.map_or(Val::None, |r| Val::Num(r as f64)),
            _ => self.val(col),
        }
    }

    fn link(&self, col: &str) -> Option<Link> {
        (col == "project").then(|| Link::to(Kind::Project, self.key()))
    }
}

/// One Requirements row of stages.md, as `project-stage-check --requirements --json` reads it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Requirement {
    pub stage: String,
    pub applies: Vec<String>,
    pub requirement: String,
    /// The Check cell: a predicate in backticks, `human`, or `not yet...` with what it waits on.
    pub check: String,
    /// `predicate`, `human` or `not-yet`, the script's word; `says` is the one printed.
    pub kind: String,
    /// The skills the requirement names that exist, the ones that do the work.
    pub skills: Vec<String>,
    #[serde(skip_deserializing)]
    pub says: &'static str,
    #[serde(skip_deserializing)]
    pub stage_rank: Option<usize>,
}

impl Row for Requirement {
    const COLUMNS: &'static [&'static str] = &["stage", "applies", "requirement", "check", "by"];
    const STATES: &'static [&'static str] = &["all", TEST, HUMAN, NOT_YET];
    const FACETS: &'static [&'static str] = &["stage", "applies", "check"];
    const LEAD: &'static str = "requirement";
    const GLANCE: &'static [&'static str] = &["stage", "applies", "check"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            TEST,
            "a shell check project-stage-check runs; a failing one is filed nightly",
        ),
        (HUMAN, "the human signs it off; never filed"),
        (
            NOT_YET,
            "no check exists yet; it reports as TODO, never as a failure",
        ),
    ];

    fn val(&self, col: &str) -> Val {
        match col {
            "stage" => word(&self.stage),
            "applies" => word(&self.applies.join(", ")),
            "requirement" => word(&self.requirement),
            "check" => word(self.says),
            "by" => word(&self.skills.join(", ")),
            _ => Val::None,
        }
    }

    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "applies" => self.applies.iter().map(|a| word(a)).collect(),
            "by" => self.skills.iter().map(|a| word(a)).collect(),
            _ => vec![self.val(col)],
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.says == s
    }

    fn text(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}\n{}",
            self.stage,
            self.applies.join(" "),
            self.requirement,
            self.check,
            self.skills.join(" ")
        )
        .to_lowercase()
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            "stage" => self.stage_rank.map_or(Val::None, |r| Val::Num(r as f64)),
            _ => self.val(col),
        }
    }
}

fn kind_says(kind: &str) -> &'static str {
    match kind {
        "predicate" => TEST,
        "human" => HUMAN,
        _ => NOT_YET,
    }
}

/// The tab, as both surfaces print it: each line word for word, each table's rows ordered.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Ladder {
    pub ladder: Vec<String>,
    /// `Gate` line: from when a failing row blocks a stage move.
    pub gate_says: String,
    pub gate_level: Level,
    /// `Filer` line: the nightly stage pass, when it last ran and what it did.
    pub filer_says: String,
    pub filer_level: Level,
    /// `Kinds` line: the row kinds dispatch runs, and the ones it leaves for the human.
    pub kinds_says: String,
    pub kinds_level: Level,
    pub projects: Vec<Project>,
    /// Why there are no project rows, when it is not that none is staged; empty when read.
    pub projects_says: String,
    pub requirements: Vec<Requirement>,
    pub requirements_says: String,
    /// Projects whose check fails or could not run: the inner tab's count.
    pub failing: usize,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Snapshot {
    generated_at: String,
    ladder: Vec<String>,
    file: Filed,
    projects: Vec<Project>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Filed {
    filed: u32,
    met: u32,
    epics: u32,
    errors: u32,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Reqs {
    enforced_from: Option<String>,
    requirements: Vec<Requirement>,
}

#[derive(Deserialize)]
struct KindConf {
    #[serde(default)]
    rank: i64,
    #[serde(default)]
    enabled: bool,
}

/// Reads the three stores and words the tab; never fails as a whole, each part says its own state.
pub fn read(runner: &dyn Runner, paths: &Paths, now: DateTime<Local>) -> Ladder {
    let snap = std::fs::read_to_string(&paths.stages);
    let reqs = runner
        .run(&[
            "project-stage-check".into(),
            "--requirements".into(),
            "--json".into(),
        ])
        .and_then(|out| {
            serde_json::from_str::<Reqs>(&out)
                .map_err(|e| format!("project-stage-check --requirements: {e}"))
        });
    build(snap, reqs, kinds(&paths.kinds), now)
}

/// The kinds on and off, lowest rank first, then by name.
fn kinds(path: &Path) -> Result<(Vec<String>, Vec<String>), String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let map: std::collections::BTreeMap<String, KindConf> =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut all: Vec<(&String, &KindConf)> = map.iter().collect();
    all.sort_by_key(|(k, c)| (c.rank, (*k).clone()));
    let pick = |on: bool| {
        all.iter()
            .filter(|(_, c)| c.enabled == on)
            .map(|(k, _)| (*k).clone())
            .collect()
    };
    Ok((pick(true), pick(false)))
}

/// The tab from what each store answered: `snap` the stages.json text (a missing file is a filer
/// that has not run), `reqs` the parsed requirements, `kinds` the kinds on and off.
fn build(
    snap: std::io::Result<String>,
    reqs: Result<Reqs, String>,
    kinds: Result<(Vec<String>, Vec<String>), String>,
    now: DateTime<Local>,
) -> Ladder {
    let mut out = Ladder::default();

    // Projects and the filer line.
    let (snap, snap_state) = match snap {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (Snapshot::default(), State::Never),
        Err(e) => (
            Snapshot::default(),
            State::NotRead(format!("stages.json: {e}")),
        ),
        Ok(text) => match serde_json::from_str::<Snapshot>(&text) {
            Err(e) => (
                Snapshot::default(),
                State::NotRead(format!("stages.json: {e}")),
            ),
            Ok(s) => {
                let at = DateTime::parse_from_rfc3339(&s.generated_at)
                    .ok()
                    .map(|t| t.timestamp());
                let state = match at {
                    None => State::NotRead("stages.json has no generated_at".into()),
                    Some(t) => State::of_age(Some(t), now.timestamp(), STALE_SECS),
                };
                (s, state)
            }
        },
    };
    out.ladder = snap.ladder.clone();
    let what = "nightly stage pass";
    match &snap_state {
        State::Live => {
            let f = &snap.file;
            let at = DateTime::parse_from_rfc3339(&snap.generated_at)
                .map(|t| t.with_timezone(&now.timezone()))
                .ok();
            let when = at.map_or_else(String::new, |t| {
                if t.date_naive() == now.date_naive() {
                    format!("{} today", t.format("%H:%M"))
                } else {
                    t.format("%m-%d %H:%M").to_string()
                }
            });
            out.filer_says = format!(
                "nightly, last {when}: {} filed, {} met and closed, {} epics opened",
                f.filed, f.met, f.epics
            );
            if f.errors > 0 {
                out.filer_says += &format!(", {} failed to write", f.errors);
                out.filer_level = Level::Bad;
            }
        }
        // The rows of a stale snapshot still show, under a filer line that says it stopped.
        s => {
            out.filer_says = s.sentence(what);
            out.filer_level = s.level();
        }
    }
    if !matches!(snap_state, State::Never | State::NotRead(_)) {
        let mut rows: Vec<Project> = snap
            .projects
            .into_iter()
            .map(|p| p.worded(&out.ladder))
            .collect();
        rows.sort_by(|a, b| {
            a.order()
                .cmp(&b.order())
                .then(b.stage_rank.cmp(&a.stage_rank))
                .then(a.name.cmp(&b.name))
        });
        out.failing = rows.iter().filter(|p| p.state != MET).count();
        out.projects = rows;
    } else {
        out.projects_says = snap_state.sentence(what);
    }

    // Requirements and the gate line.
    match reqs {
        Ok(r) => {
            out.gate_says = gate(r.enforced_from.as_deref(), now.date_naive());
            out.gate_level = if r.enforced_from.is_some() {
                Level::Ok
            } else {
                Level::Warn
            };
            out.requirements = r
                .requirements
                .into_iter()
                .map(|mut q| {
                    q.says = kind_says(&q.kind);
                    q.stage_rank = out.ladder.iter().position(|s| *s == q.stage);
                    q
                })
                .collect();
        }
        Err(e) => {
            let s = State::NotRead(e);
            out.gate_says = s.sentence("the gate");
            out.gate_level = s.level();
            out.requirements_says = s.sentence("the requirements");
        }
    }

    // Kinds.
    match kinds {
        Ok((on, off)) => {
            out.kinds_says = format!(
                "on {}; off {}",
                if on.is_empty() {
                    "none".into()
                } else {
                    on.join(" ")
                },
                if off.is_empty() {
                    "none".into()
                } else {
                    off.join(" ")
                }
            );
        }
        Err(e) => {
            let s = State::NotRead(e);
            out.kinds_says = s.sentence("kinds.json");
            out.kinds_level = s.level();
        }
    }
    out
}

/// The gate line from stages.md's `Enforced from:` date.
fn gate(from: Option<&str>, today: NaiveDate) -> String {
    let Some(from) = from else {
        return "stages.md names no Enforced from date, so a failing row only reports".into();
    };
    match NaiveDate::parse_from_str(from, "%Y-%m-%d") {
        Ok(d) if d > today => {
            let days = (d - today).num_days();
            format!(
                "report only until {from} (in {days} day{}), then a failing row blocks a stage move",
                if days == 1 { "" } else { "s" }
            )
        }
        Ok(_) => format!("enforced since {from}: a failing row blocks a stage move"),
        Err(_) => format!("stages.md's Enforced from date {from:?} is not a date"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;
    use chrono::TimeZone;

    fn now() -> DateTime<Local> {
        Local.with_ymd_and_hms(2026, 11, 13, 9, 0, 0).unwrap()
    }

    fn snap(at: DateTime<Local>) -> String {
        serde_json::json!({
            "generated_at": at.to_rfc3339(),
            "ladder": ["draft", "dev", "alpha", "beta", "prod"],
            "file": {"filed": 4, "met": 1, "epics": 0, "errors": 0},
            "projects": [
                {"name": "calm", "profile": "personal", "stage": "beta", "next": "prod", "type": "app",
                 "met": 9, "total": 9, "fail": 0, "todo": 2, "human": 1, "filed_open": 0, "filed_closed": 3},
                {"name": "busy", "profile": "bnb", "stage": "alpha", "next": "beta", "type": "game",
                 "met": 7, "total": 24, "fail": 4, "todo": 8, "human": 3, "filed_open": 4, "filed_closed": 0},
                {"name": "lost", "profile": "bnb", "stage": "dev", "next": "alpha",
                 "filed_open": 0, "filed_closed": 0, "error": "lost is not checked out here"}
            ]
        })
        .to_string()
    }

    fn reqs() -> Result<Reqs, String> {
        Ok(serde_json::from_value(serde_json::json!({
            "enforced_from": "2026-11-19",
            "requirements": [
                {"stage": "draft", "applies": ["base"], "requirement": "A lab sheet", "check": "`true`", "kind": "predicate", "skills": []},
                {"stage": "alpha", "applies": ["game", "app"], "requirement": "Plays through", "check": "human", "kind": "human", "skills": ["game-eval"]},
                {"stage": "beta", "applies": ["store"], "requirement": "A page", "check": "not yet: a probe", "kind": "not-yet", "skills": []}
            ]
        }))
        .unwrap())
    }

    fn kinds_ok() -> Result<(Vec<String>, Vec<String>), String> {
        Ok((vec!["fix".into(), "feat".into()], vec!["legal".into()]))
    }

    #[test]
    fn projects_lead_with_the_unread_then_the_most_failing_and_say_their_cells() {
        let l = build(Ok(snap(now())), reqs(), kinds_ok(), now());
        let names: Vec<_> = l.projects.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["lost", "busy", "calm"]);
        let busy = &l.projects[1];
        assert_eq!(
            (busy.state, busy.met_says.as_str(), busy.filed_says.as_str()),
            (FAILING, "7/24", "4/0")
        );
        assert_eq!(busy.stage_rank, Some(2));
        // A check that could not run has no counts, never a zero.
        assert_eq!(
            (l.projects[0].state, l.projects[0].met_says.as_str()),
            (NOT_READ, NOT_READ)
        );
        assert_eq!(l.projects[0].val("failing"), Val::None);
        assert_eq!(l.failing, 2);
        assert_eq!(
            l.filer_says,
            "nightly, last 09:00 today: 4 filed, 1 met and closed, 0 epics opened"
        );
        assert_eq!(l.kinds_says, "on fix feat; off legal");
        assert_eq!(
            l.gate_says,
            "report only until 2026-11-19 (in 6 days), then a failing row blocks a stage move"
        );
    }

    #[test]
    fn a_missing_or_broken_snapshot_says_so_and_a_stale_one_keeps_its_rows() {
        let gone = build(
            Err(std::io::ErrorKind::NotFound.into()),
            reqs(),
            kinds_ok(),
            now(),
        );
        assert!(gone.projects.is_empty());
        assert_eq!(gone.projects_says, "No nightly stage pass yet");
        assert_eq!(gone.filer_level, Level::Warn);
        let bad = build(Ok("{".into()), reqs(), kinds_ok(), now());
        assert!(
            bad.projects_says.starts_with("Not read: stages.json"),
            "{}",
            bad.projects_says
        );
        let old = now() - chrono::Duration::hours(40);
        let stale = build(Ok(snap(old)), reqs(), kinds_ok(), now());
        assert_eq!(stale.projects.len(), 3);
        assert!(
            stale
                .filer_says
                .starts_with("Nightly stage pass stopped reporting"),
            "{}",
            stale.filer_says
        );
        // NEGATIVE CONTROL: a fresh one is Live, no state words on the filer line.
        assert_eq!(
            build(Ok(snap(now())), reqs(), kinds_ok(), now()).filer_level,
            Level::Ok
        );
    }

    #[test]
    fn requirements_print_the_mockup_words_and_filter_by_each_applies_tag() {
        let l = build(Ok(snap(now())), reqs(), kinds_ok(), now());
        let says: Vec<_> = l.requirements.iter().map(|r| r.says).collect();
        assert_eq!(says, [TEST, HUMAN, NOT_YET]);
        let pick = |q: &str, s: &str| {
            View::new::<Requirement>(q, s, "", "")
                .apply(&l.requirements)
                .iter()
                .map(|r| r.requirement.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(pick("applies:app", ""), ["Plays through"]);
        assert_eq!(pick("", NOT_YET), ["A page"]);
        assert_eq!(pick("game-eval", ""), ["Plays through"]);
        // NEGATIVE CONTROL: a tag no row carries keeps nothing.
        assert!(pick("applies:infra", "").is_empty());
    }

    #[test]
    fn an_unreadable_requirement_list_or_kinds_file_says_so() {
        let l = build(
            Ok(snap(now())),
            Err("exit 2".into()),
            Err("kinds.json: gone".into()),
            now(),
        );
        assert_eq!(l.requirements_says, "Not read: exit 2");
        assert_eq!(l.gate_level, Level::Warn);
        assert_eq!(l.kinds_says, "Not read: kinds.json: gone");
        assert!(l.requirements.is_empty());
    }

    #[test]
    fn the_gate_reports_before_its_date_and_enforces_from_it() {
        let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        assert_eq!(
            gate(Some("2026-11-19"), d("2026-11-18")),
            "report only until 2026-11-19 (in 1 day), then a failing row blocks a stage move"
        );
        assert_eq!(
            gate(Some("2026-11-19"), d("2026-11-19")),
            "enforced since 2026-11-19: a failing row blocks a stage move"
        );
        assert!(gate(None, d("2026-11-19")).contains("only reports"));
    }

    #[test]
    fn kinds_order_by_rank_then_name_and_split_on_enabled() {
        let dir = std::env::temp_dir().join(format!("hub-stages-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("kinds.json");
        std::fs::write(&f, r#"{"feat":{"rank":1,"enabled":true},"fix":{"rank":0,"enabled":true},"legal":{"rank":1,"enabled":false},"chore":{"rank":1,"enabled":true}}"#).unwrap();
        let got = kinds(&f);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(
            got.unwrap(),
            (
                vec!["fix".into(), "chore".into(), "feat".into()],
                vec!["legal".into()]
            )
        );
    }
}
