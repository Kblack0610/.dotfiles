//! The task board: every project's open rows as `notes board --json` prints them, for agent-web's
//! Board tab and the hub TUI's. `notes` is the sheets' only writer, so this module never opens a
//! sheet: it reads the feed through a `Runner` and writes with `notes ptask ... --exact`, which
//! matches the row's raw line byte for byte and writes nothing when the row changed since the
//! read (design: notes-cli README, "The task feed").

use serde::{Deserialize, Serialize};

use crate::queue::PRIORITIES;
use crate::session_actions::Runner;

/// The lanes a board can write. `focus` rows are in the feed too, read-only: `notes focus`
/// owns the daily note.
pub const LANES: [&str; 3] = ["human", "agent", "playtest"];

/// One project, listed even with no open rows so a board can offer `add` on it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Project {
    pub profile: String,
    pub project: String,
    pub dir: String,
    pub version: Option<String>,
    pub open: usize,
    pub agent_open: usize,
    pub playtest_open: usize,
}

/// One open row. `raw` is the line as it stands, what a write passes back.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Row {
    pub profile: String,
    /// None on a focus row.
    pub project: Option<String>,
    pub lane: String,
    pub wave: Option<String>,
    pub game: Option<String>,
    pub state: String,
    pub priority: String,
    pub tier: Option<u8>,
    pub worker: Option<String>,
    pub ask: bool,
    pub target: Option<String>,
    pub text: String,
    pub tags: Vec<String>,
    pub marker: Option<String>,
    pub since: Option<String>,
    pub sheet: String,
    pub line: usize,
    pub raw: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Feed {
    pub projects: Vec<Project>,
    pub rows: Vec<Row>,
}

pub fn feed(runner: &dyn Runner) -> Result<Feed, String> {
    let out = runner.run(&["notes".into(), "board".into(), "--json".into()])?;
    serde_json::from_str(&out).map_err(|e| format!("notes board --json: {e}"))
}

/// What a write does to one row, or the row it adds.
#[derive(Clone, Debug, PartialEq)]
pub enum Verb {
    /// `to` plans it into a later wave (`vX.Y.Z`); `game` is the playtest heading.
    Add {
        text: String,
        priority: String,
        to: Option<String>,
        game: Option<String>,
    },
    /// Exactly one of `proof` and `unverified`; `notes` refuses a bare done.
    Done {
        raw: String,
        proof: Option<String>,
        unverified: Option<String>,
    },
    /// Toggles `[ ]` and `[/]`. Not on the playtest lane.
    Start {
        raw: String,
    },
    Rm {
        raw: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Write {
    pub profile: String,
    pub project: String,
    pub lane: String,
    pub verb: Verb,
}

/// A profile or project name: what `notes` itself names them, so nothing else reaches argv.
fn is_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn one_line(s: &str) -> bool {
    !s.trim().is_empty() && !s.contains(['\n', '\r'])
}

fn is_version(s: &str) -> bool {
    let Some(v) = s.strip_prefix('v') else {
        return false;
    };
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// Something a row's own text would not say: a non-high priority is the row's `#urgent` or
/// `#low` tag, and high is no tag at all, as `ptask add` reads it.
fn with_priority(text: &str, priority: &str) -> String {
    let text = text.trim();
    let tag = format!("#{priority}");
    if priority == "high" || text.split_whitespace().any(|w| w == tag) {
        text.to_string()
    } else {
        format!("{text} {tag}")
    }
}

/// The argv for one write, or why it is refused. Every free-text value goes after `--`, so a
/// row's `- [ ]` and a text starting with `-` stay values.
pub fn argv(w: &Write) -> Result<Vec<String>, String> {
    if !is_name(&w.profile) || !is_name(&w.project) {
        return Err("pick a project".into());
    }
    if !LANES.contains(&w.lane.as_str()) {
        return Err("the lane is human, agent or playtest".into());
    }
    let playtest = w.lane == "playtest";
    let mut a: Vec<String> = ["notes", "ptask", &w.project, "--profile", &w.profile]
        .into_iter()
        .map(String::from)
        .collect();
    match w.lane.as_str() {
        "agent" => a.push("--agent".into()),
        "playtest" => a.push("--playtest".into()),
        _ => {}
    }
    let tail = match &w.verb {
        Verb::Add {
            text,
            priority,
            to,
            game,
        } => {
            if !one_line(text) {
                return Err("type the task, on one line".into());
            }
            if !PRIORITIES.contains(&priority.as_str()) {
                return Err("priority is urgent, high or low".into());
            }
            a.push("add".into());
            if let Some(v) = to.as_deref().filter(|v| !v.is_empty()) {
                if playtest || !is_version(v) {
                    return Err("a wave is vX.Y.Z, and a playtest check has none".into());
                }
                a.extend(["--to".into(), v.into()]);
            }
            if let Some(g) = game.as_deref().filter(|g| !g.is_empty()) {
                if !playtest || !one_line(g) {
                    return Err("a game heading is for a playtest check".into());
                }
                a.extend(["--game".into(), g.trim().into()]);
            }
            with_priority(text, priority)
        }
        Verb::Done {
            raw,
            proof,
            unverified,
        } => {
            let proof = proof.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let why = unverified
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            a.extend(["--exact".into(), "done".into()]);
            match (proof, why) {
                (Some(p), None) if one_line(p) => a.extend(["--proof".into(), p.into()]),
                (None, Some(u)) if one_line(u) => a.extend(["--unverified".into(), u.into()]),
                _ => return Err("done needs a proof (pr:N, a URL) or why it has none".into()),
            }
            raw.clone()
        }
        Verb::Start { raw } => {
            if playtest {
                return Err("a playtest check has no in-progress state".into());
            }
            a.extend(["--exact".into(), "start".into()]);
            raw.clone()
        }
        Verb::Rm { raw } => {
            a.extend(["--exact".into(), "rm".into()]);
            raw.clone()
        }
    };
    let is_row = one_line(&tail) && tail.starts_with("- [");
    if !matches!(w.verb, Verb::Add { .. }) && !is_row {
        return Err("that is not a row's line".into());
    }
    a.extend(["--".into(), tail]);
    Ok(a)
}

/// Run one write: `notes`' output, or its stderr (a stale row says nothing matched).
pub fn apply(runner: &dyn Runner, w: &Write) -> Result<String, String> {
    runner.run(&argv(w)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fake {
        out: Result<&'static str, &'static str>,
        calls: RefCell<Vec<Vec<String>>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.to_vec());
            self.out.map(String::from).map_err(String::from)
        }
    }

    fn w(lane: &str, verb: Verb) -> Write {
        Write {
            profile: "bnb".into(),
            project: "demo".into(),
            lane: lane.into(),
            verb,
        }
    }

    fn add(text: &str, priority: &str, to: Option<&str>, game: Option<&str>) -> Verb {
        Verb::Add {
            text: text.into(),
            priority: priority.into(),
            to: to.map(String::from),
            game: game.map(String::from),
        }
    }

    const RAW: &str = "- [ ] ship it #urgent <!-- pr:3 -->";

    #[test]
    fn the_feed_parses_and_a_focus_row_has_no_project() {
        let f = Fake {
            out: Ok(
                r#"{"projects":[{"profile":"bnb","project":"demo","dir":"/d","version":"v1.0.0","open":1,"agent_open":0,"playtest_open":0}],
                "rows":[{"profile":"personal","project":null,"lane":"focus","state":"open","priority":"high","text":"x","tags":[],"sheet":"/n","line":4,"raw":"- [ ] x","later":"kept out"}]}"#,
            ),
            calls: RefCell::default(),
        };
        let feed = feed(&f).unwrap();
        assert_eq!(feed.projects[0].version.as_deref(), Some("v1.0.0"));
        assert_eq!((feed.rows[0].project.clone(), feed.rows[0].line), (None, 4));
        assert_eq!(f.calls.borrow()[0], ["notes", "board", "--json"]);
        let bad = Fake {
            out: Ok("not json"),
            calls: RefCell::default(),
        };
        assert!(feed_err(&bad).contains("notes board --json"));
    }

    fn feed_err(f: &Fake) -> String {
        feed(f).unwrap_err()
    }

    #[test]
    fn writes_name_the_lane_and_pass_the_row_after_the_separator() {
        assert_eq!(
            argv(&w(
                "human",
                add("fix the menu", "urgent", Some("v1.2.0"), None)
            ))
            .unwrap(),
            [
                "notes",
                "ptask",
                "demo",
                "--profile",
                "bnb",
                "add",
                "--to",
                "v1.2.0",
                "--",
                "fix the menu #urgent"
            ]
        );
        assert_eq!(
            argv(&w("agent", add("-lead dash", "high", None, None))).unwrap()[5..],
            ["--agent", "add", "--", "-lead dash"],
            "high is no tag"
        );
        assert_eq!(
            argv(&w(
                "playtest",
                add("ball clips", "low", None, Some("Arena"))
            ))
            .unwrap()[5..],
            [
                "--playtest",
                "add",
                "--game",
                "Arena",
                "--",
                "ball clips #low"
            ]
        );
        let done = Verb::Done {
            raw: RAW.into(),
            proof: Some("pr:12".into()),
            unverified: None,
        };
        assert_eq!(
            argv(&w("agent", done)).unwrap()[5..],
            ["--agent", "--exact", "done", "--proof", "pr:12", "--", RAW]
        );
        let done = Verb::Done {
            raw: RAW.into(),
            proof: Some(" ".into()),
            unverified: Some("played it".into()),
        };
        assert_eq!(
            argv(&w("human", done)).unwrap()[5..],
            ["--exact", "done", "--unverified", "played it", "--", RAW]
        );
        assert_eq!(
            argv(&w("human", Verb::Rm { raw: RAW.into() })).unwrap()[5..],
            ["--exact", "rm", "--", RAW]
        );
    }

    #[test]
    fn writes_refuse_what_notes_would_misread() {
        let rm = |raw: &str| Verb::Rm { raw: raw.into() };
        let bad = [
            w("focus", rm(RAW)),
            w("human", rm("not a row")),
            w("human", rm("- [ ] two\n- [ ] lines")),
            w("playtest", Verb::Start { raw: RAW.into() }),
            w("human", add("x", "normal", None, None)),
            w("human", add("  ", "high", None, None)),
            w("human", add("x", "high", Some("next"), None)),
            w("playtest", add("x", "high", Some("v1.0.0"), None)),
            w("human", add("x", "high", None, Some("Arena"))),
            w(
                "human",
                Verb::Done {
                    raw: RAW.into(),
                    proof: None,
                    unverified: None,
                },
            ),
            w(
                "human",
                Verb::Done {
                    raw: RAW.into(),
                    proof: Some("pr:1".into()),
                    unverified: Some("both".into()),
                },
            ),
            Write {
                project: "--all".into(),
                ..w("human", rm(RAW))
            },
            Write {
                profile: "a b".into(),
                ..w("human", rm(RAW))
            },
        ];
        for b in bad {
            assert!(argv(&b).is_err(), "{b:?}");
        }
    }

    #[test]
    fn a_stale_row_comes_back_as_the_error_and_nothing_else_runs() {
        let f = Fake {
            out: Err("no open task matches"),
            calls: RefCell::default(),
        };
        let e = apply(&f, &w("human", Verb::Rm { raw: RAW.into() })).unwrap_err();
        assert_eq!(e, "no open task matches");
        assert_eq!(f.calls.borrow().len(), 1);
        let none = Fake {
            out: Ok(""),
            calls: RefCell::default(),
        };
        assert!(apply(&none, &w("focus", Verb::Rm { raw: RAW.into() })).is_err());
        assert!(
            none.calls.borrow().is_empty(),
            "a refused write runs nothing"
        );
    }
}
