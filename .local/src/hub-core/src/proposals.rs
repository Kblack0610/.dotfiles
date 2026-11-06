//! What analysis streams propose to the human: the open records of `agent-propose`, its only
//! writer, for Home's Proposals section on both surfaces. An accept or a reject goes through
//! the same CLI, which runs the verb, so neither surface decides what a proposal does.

use serde::{Deserialize, Serialize};

use crate::session_actions::Runner;
use crate::table::{Row, Val};

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Proposal {
    pub id: String,
    pub stream: String,
    pub project: String,
    pub title: String,
    pub why: String,
    pub evidence: String,
    pub verb: String,
    /// What an accept will run, from the CLI that runs it.
    pub does: String,
    pub created: String,
    pub expires: String,
    /// Why the last accept failed; such a proposal stays open.
    pub error: Option<String>,
}

impl Proposal {
    /// When it was filed, in epoch seconds.
    pub fn at(&self) -> Option<i64> {
        chrono::DateTime::parse_from_rfc3339(&self.created)
            .ok()
            .map(|t| t.timestamp())
    }
}

/// The Proposals table on both surfaces. A chip is what an accept does.
impl Row for Proposal {
    const COLUMNS: &'static [&'static str] = &["stream", "project", "proposal", "created", "verb"];
    const STATES: &'static [&'static str] = &["all", "queue", "row", "none"];
    const FACETS: &'static [&'static str] = &["stream", "project"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| Val::Text(s.to_string());
        match col {
            "stream" => text(&self.stream),
            "project" => text(&self.project),
            "proposal" => text(&self.title),
            "verb" => text(&self.verb),
            "created" => self.at().map_or(Val::None, |t| Val::Num(t as f64)),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.verb == s
    }
}

fn argv(args: &[&str]) -> Vec<String> {
    std::iter::once("agent-propose")
        .chain(args.iter().copied())
        .map(String::from)
        .collect()
}

/// The open proposals, newest first.
pub fn read(runner: &dyn Runner) -> Result<Vec<Proposal>, String> {
    let out = runner.run(&argv(&["list", "--json"]))?;
    let mut rows: Vec<Proposal> =
        serde_json::from_str(&out).map_err(|e| format!("agent-propose list: {e}"))?;
    rows.reverse();
    Ok(rows)
}

/// "12 from 4 streams", worded once for both surfaces.
pub fn heading(rows: &[Proposal]) -> String {
    let mut streams: Vec<&str> = rows.iter().map(|p| p.stream.as_str()).collect();
    streams.sort_unstable();
    streams.dedup();
    let word = if streams.len() == 1 {
        "stream"
    } else {
        "streams"
    };
    format!("{} from {} {word}", rows.len(), streams.len())
}

fn is_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

fn decide(runner: &dyn Runner, verb: &str, id: &str) -> Result<String, String> {
    if !is_id(id) {
        return Err("bad proposal id".into());
    }
    runner.run(&argv(&[verb, id]))
}

/// `agent-propose accept <id>`: runs the proposal's verb, then records the decision.
pub fn accept(runner: &dyn Runner, id: &str) -> Result<String, String> {
    decide(runner, "accept", id)
}

/// `agent-propose reject <id>`: records the decision; the verb never runs.
pub fn reject(runner: &dyn Runner, id: &str) -> Result<String, String> {
    decide(runner, "reject", id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;
    use std::cell::RefCell;

    struct Fake {
        out: Result<String, String>,
        calls: RefCell<Vec<Vec<String>>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.to_vec());
            self.out.clone()
        }
    }

    fn fake(out: Result<&str, &str>) -> Fake {
        Fake {
            out: out.map(String::from).map_err(String::from),
            calls: RefCell::default(),
        }
    }

    const LIST: &str = r#"[
      {"id":"aa","stream":"dream","project":"dotfiles","title":"Keep plain tables","verb":"none",
       "does":"nothing runs: the decision is recorded","created":"2026-10-21T10:00:00Z","key":"k"},
      {"id":"bb","stream":"ci-failures","project":"playground","title":"Own the Multi timeout",
       "verb":"queue","does":"agent-queue add --project playground -- x","error":"it failed",
       "created":"2026-11-05T10:00:00Z"}]"#;

    #[test]
    fn read_is_newest_first_and_keeps_what_accept_runs() {
        let rows = read(&fake(Ok(LIST))).unwrap();
        assert_eq!(rows[0].id, "bb");
        assert_eq!(rows[0].does, "agent-queue add --project playground -- x");
        assert_eq!(rows[0].error.as_deref(), Some("it failed"));
        assert_eq!(rows[1].error, None);
    }

    #[test]
    fn a_failed_read_says_why() {
        assert_eq!(read(&fake(Err("no jq"))).unwrap_err(), "no jq");
        assert!(read(&fake(Ok("not json")))
            .unwrap_err()
            .starts_with("agent-propose list:"));
    }

    #[test]
    fn heading_counts_rows_and_streams() {
        let rows = read(&fake(Ok(LIST))).unwrap();
        assert_eq!(heading(&rows), "2 from 2 streams");
        assert_eq!(heading(&rows[..1]), "1 from 1 stream");
    }

    #[test]
    fn the_table_filters_by_verb_and_column_and_sorts_by_time() {
        let rows = read(&fake(Ok(LIST))).unwrap();
        let ids =
            |v: View| -> Vec<String> { v.apply(&rows).iter().map(|p| p.id.clone()).collect() };
        let view = |q, s, sort, dir| View::new::<Proposal>(q, s, sort, dir);
        assert_eq!(ids(view("", "queue", "", "")), ["bb"]);
        assert_eq!(ids(view("project:dot", "", "", "")), ["aa"]);
        assert_eq!(ids(view("", "", "created", "asc")), ["aa", "bb"]);
    }

    #[test]
    fn accept_and_reject_each_run_their_own_verb() {
        let f = fake(Ok("ok"));
        accept(&f, "0a1b").unwrap();
        reject(&f, "0a1b").unwrap();
        let calls = f.calls.borrow();
        assert_eq!(calls[0], ["agent-propose", "accept", "0a1b"]);
        assert_eq!(calls[1], ["agent-propose", "reject", "0a1b"]);
    }

    #[test]
    fn a_bad_id_never_reaches_the_cli() {
        let f = fake(Ok("ok"));
        for id in ["", "--by", "../x", "0A"] {
            assert!(accept(&f, id).is_err(), "{id}");
        }
        assert!(f.calls.borrow().is_empty());
    }
}
