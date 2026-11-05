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
    pub version: Option<String>,
    pub game: Option<String>,
    pub state: String,
    pub priority: String,
    pub tier: Option<u8>,
    pub worker: Option<String>,
    pub ask: bool,
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
    /// `to` aims it at a later release (`vX.Y.Z`); `game` is the playtest heading.
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
    /// Queues the row: `fleet-dispatch promote` starts it and adds its queue item, the same
    /// path a fill takes. An open row only, and not on the playtest lane.
    Start { raw: String },
    /// Closes the row undelivered and keeps it: exactly one of `why` and `dup` (the id of the
    /// row it duplicates); `notes` refuses a drop with no reason.
    Drop {
        raw: String,
        why: Option<String>,
        dup: Option<String>,
    },
    /// Onto another project's sheet (aimed at release `to` if given), or with no project aimed
    /// at release `to` on its own sheet. At least one of the two.
    Move {
        raw: String,
        project: Option<String>,
        to: Option<String>,
    },
    /// One release sooner (clamped at the open version).
    Promote { raw: String },
    /// One release later (the next patch past the last).
    Demote { raw: String },
    /// New text; the checkbox, place and tags stay.
    Edit { raw: String, text: String },
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

fn is_row(s: &str) -> bool {
    one_line(s) && s.starts_with("- [")
}

/// The argv for one write, or why it is refused. Every free-text value goes after `--`, so a
/// row's `- [ ]` and a text starting with `-` stay values; Start's is the value of `--raw`.
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
                    return Err("a version is vX.Y.Z, and a playtest check has none".into());
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
            if !is_row(raw) {
                return Err("that is not a row's line".into());
            }
            let mut a: Vec<String> = [
                "fleet-dispatch",
                "promote",
                "--project",
                &w.project,
                "--profile",
                &w.profile,
            ]
            .into_iter()
            .map(String::from)
            .collect();
            if w.lane == "agent" {
                a.push("--agent".into());
            }
            a.extend(["--raw".into(), raw.clone()]);
            return Ok(a);
        }
        Verb::Drop { raw, why, dup } => {
            let why = why.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let dup = dup.as_deref().map(str::trim).filter(|s| !s.is_empty());
            a.extend(["--exact".into(), "drop".into()]);
            match (why, dup) {
                (Some(y), None) if one_line(y) => a.extend(["--why".into(), y.into()]),
                (None, Some(d)) if one_line(d) => a.extend(["--dup".into(), d.into()]),
                _ => return Err("drop needs why, or the id of the row it duplicates".into()),
            }
            raw.clone()
        }
        Verb::Move { .. } | Verb::Promote { .. } | Verb::Demote { .. } | Verb::Edit { .. }
            if playtest =>
        {
            return Err(
                "a playtest check has no version and no edit: drop it and add it again".into(),
            );
        }
        Verb::Move { raw, project, to } => {
            let project = project.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let to = to.as_deref().map(str::trim).filter(|s| !s.is_empty());
            if project.is_none() && to.is_none() {
                return Err("move to a project, a version (vX.Y.Z), or both".into());
            }
            a.extend(["--exact".into(), "move".into()]);
            if let Some(p) = project {
                if !is_name(p) {
                    return Err("that is not a project name".into());
                }
                a.extend(["--project".into(), p.into()]);
            }
            if let Some(v) = to {
                if !is_version(v) {
                    return Err("a version is vX.Y.Z".into());
                }
                a.extend(["--to".into(), v.into()]);
            }
            raw.clone()
        }
        Verb::Promote { raw } => {
            a.extend(["--exact".into(), "promote".into()]);
            raw.clone()
        }
        Verb::Demote { raw } => {
            a.extend(["--exact".into(), "demote".into()]);
            raw.clone()
        }
        Verb::Edit { raw, text } => {
            if !one_line(text) {
                return Err("type the new text, on one line".into());
            }
            a.extend([
                "--exact".into(),
                "edit".into(),
                "--text".into(),
                text.trim().into(),
            ]);
            raw.clone()
        }
    };
    if !matches!(w.verb, Verb::Add { .. }) && !is_row(&tail) {
        return Err("that is not a row's line".into());
    }
    a.extend(["--".into(), tail]);
    Ok(a)
}

/// Run one write: its output, or its stderr (a stale row says nothing matched).
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

    fn drop(why: Option<&str>, dup: Option<&str>) -> Verb {
        Verb::Drop {
            raw: RAW.into(),
            why: why.map(Into::into),
            dup: dup.map(Into::into),
        }
    }

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
            argv(&w("human", drop(Some("stale"), None))).unwrap()[5..],
            ["--exact", "drop", "--why", "stale", "--", RAW]
        );
        assert_eq!(
            argv(&w("human", drop(Some(" "), Some("ar-142")))).unwrap()[5..],
            ["--exact", "drop", "--dup", "ar-142", "--", RAW]
        );
    }

    // Start is the queue's door, not a checkbox: a row started here gets an item, as a fill's does.
    #[test]
    fn start_goes_through_fleet_dispatch_promote() {
        assert_eq!(
            argv(&w("agent", Verb::Start { raw: RAW.into() })).unwrap(),
            [
                "fleet-dispatch",
                "promote",
                "--project",
                "demo",
                "--profile",
                "bnb",
                "--agent",
                "--raw",
                RAW
            ]
        );
        assert!(!argv(&w("human", Verb::Start { raw: RAW.into() }))
            .unwrap()
            .contains(&"--agent".to_string()));
    }

    #[test]
    fn move_version_and_edit_pass_the_row_after_the_separator() {
        let mv = |project: Option<&str>, to: Option<&str>| Verb::Move {
            raw: RAW.into(),
            project: project.map(String::from),
            to: to.map(String::from),
        };
        assert_eq!(
            argv(&w("human", mv(Some("other"), None))).unwrap()[5..],
            ["--exact", "move", "--project", "other", "--", RAW]
        );
        assert_eq!(
            argv(&w("agent", mv(Some("other"), Some("v2.0.0")))).unwrap()[5..],
            [
                "--agent",
                "--exact",
                "move",
                "--project",
                "other",
                "--to",
                "v2.0.0",
                "--",
                RAW
            ]
        );
        assert_eq!(
            argv(&w("human", mv(Some(" "), Some("v1.3.0")))).unwrap()[5..],
            ["--exact", "move", "--to", "v1.3.0", "--", RAW],
            "a blank project is no project"
        );
        assert_eq!(
            argv(&w("human", Verb::Promote { raw: RAW.into() })).unwrap()[5..],
            ["--exact", "promote", "--", RAW]
        );
        assert_eq!(
            argv(&w("agent", Verb::Demote { raw: RAW.into() })).unwrap()[5..],
            ["--agent", "--exact", "demote", "--", RAW]
        );
        let edit = Verb::Edit {
            raw: RAW.into(),
            text: " -ship it today ".into(),
        };
        assert_eq!(
            argv(&w("human", edit)).unwrap()[5..],
            ["--exact", "edit", "--text", "-ship it today", "--", RAW]
        );
    }

    #[test]
    fn writes_refuse_what_notes_would_misread() {
        let gone = |raw: &str| Verb::Drop {
            raw: raw.into(),
            why: Some("stale".into()),
            dup: None,
        };
        let bad = [
            w("human", drop(None, None)),
            w("human", drop(Some("x"), Some("ar-1"))),
            w("human", drop(Some("two\nlines"), None)),
            w("focus", gone(RAW)),
            w("human", gone("not a row")),
            w("human", gone("- [ ] two\n- [ ] lines")),
            w("playtest", Verb::Start { raw: RAW.into() }),
            w(
                "human",
                Verb::Start {
                    raw: "not a row".into(),
                },
            ),
            w("human", add("x", "normal", None, None)),
            w("human", add("  ", "high", None, None)),
            w("human", add("x", "high", Some("next"), None)),
            w("playtest", add("x", "high", Some("v1.0.0"), None)),
            w("human", add("x", "high", None, Some("Arena"))),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: None,
                    to: Some(" ".into()),
                },
            ),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: Some("a b".into()),
                    to: None,
                },
            ),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: None,
                    to: Some("next".into()),
                },
            ),
            w(
                "playtest",
                Verb::Move {
                    raw: RAW.into(),
                    project: Some("other".into()),
                    to: None,
                },
            ),
            w("playtest", Verb::Promote { raw: RAW.into() }),
            w(
                "human",
                Verb::Edit {
                    raw: RAW.into(),
                    text: "two\nlines".into(),
                },
            ),
            w(
                "human",
                Verb::Edit {
                    raw: "not a row".into(),
                    text: "x".into(),
                },
            ),
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
                ..w("human", gone(RAW))
            },
            Write {
                profile: "a b".into(),
                ..w("human", gone(RAW))
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
        let e = apply(&f, &w("human", drop(Some("stale"), None))).unwrap_err();
        assert_eq!(e, "no open task matches");
        assert_eq!(f.calls.borrow().len(), 1);
        let none = Fake {
            out: Ok(""),
            calls: RefCell::default(),
        };
        assert!(apply(&none, &w("focus", drop(Some("stale"), None))).is_err());
        assert!(
            none.calls.borrow().is_empty(),
            "a refused write runs nothing"
        );
    }
}
