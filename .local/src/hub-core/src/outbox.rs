//! The Outbox tab's reader, for both hub surfaces: the outbox as the editor holds it
//! (`notes outbox show --json`) and what intake did today (`notes log --day <today> --json`, the
//! ingest record `status/inbox.md` is drawn from). The writer is `notes outbox put --base`, run
//! by agent-web, which this reader never calls: a read cannot change the file.

use crate::session_actions::Runner;
use serde::{Deserialize, Serialize};

/// The intake steps "Handled today" lists. `moved` (outbox -> an inbox) is left out: the same
/// sweep files the line a moment later, and the filing is the step that names the row.
const HANDLED: [&str; 5] = ["filed", "dup", "planned", "left", "refused"];

/// The outbox as `notes outbox show --json` prints it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Doc {
    pub path: String,
    /// What `put --base` takes: the items' hash when they were read.
    pub hash: String,
    /// The `## Outbox` items, the text the page edits.
    pub text: String,
    /// Lines the sweep has not taken yet.
    pub waiting: usize,
}

/// One intake step from the ingest record.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Step {
    pub ts: String,
    pub action: String,
    pub from: String,
    pub to: String,
    pub lane: String,
    pub text: String,
    pub id: Option<String>,
    pub why: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct View {
    pub doc: Doc,
    /// Today's steps, newest first.
    pub handled: Vec<Step>,
    /// `3 filed, 1 left`: one count per action, in [`HANDLED`] order, zeros left out.
    pub counts: String,
}

/// The outbox alone; agent-web reads its path to know which directory to watch.
pub fn doc(runner: &dyn Runner) -> Result<Doc, String> {
    let argv = ["notes", "outbox", "show", "--json"].map(String::from);
    parse_doc(&runner.run(&argv)?)
}

/// A doc as `show --json` and `put` print it.
pub fn parse_doc(json: &str) -> Result<Doc, String> {
    serde_json::from_str(json).map_err(|e| format!("notes outbox show --json: {e}"))
}

pub fn read(runner: &dyn Runner, today: &str) -> Result<View, String> {
    let doc = doc(runner)?;
    let argv = ["notes", "log", "--day", today, "--json"].map(String::from);
    // A day with no record yet is an empty log, not an error for the page.
    let log = runner.run(&argv).unwrap_or_default();
    Ok(build(doc, &log))
}

/// The view from the doc and the record's JSON lines; a line that does not parse is skipped.
pub fn build(doc: Doc, log: &str) -> View {
    let mut handled: Vec<Step> = log
        .lines()
        .filter_map(|l| serde_json::from_str::<Step>(l).ok())
        .filter(|s| HANDLED.contains(&s.action.as_str()))
        .collect();
    handled.reverse();
    let counts = HANDLED
        .iter()
        .filter_map(|a| {
            let n = handled.iter().filter(|s| s.action == *a).count();
            (n > 0).then(|| format!("{n} {a}"))
        })
        .collect::<Vec<_>>()
        .join(", ");
    View {
        doc,
        handled,
        counts,
    }
}

/// `HH:MM` of an RFC 3339 stamp, or the stamp when it has no time.
pub fn clock(ts: &str) -> &str {
    ts.get(11..16).unwrap_or(ts)
}

/// One step as the page says it: `filed ar-12 in agent-runtime: <words>`, or
/// `left: <words> (why: ...)`.
pub fn say(s: &Step) -> String {
    let id = s.id.as_deref().map(|i| format!(" {i}")).unwrap_or_default();
    let place = if s.to.is_empty() {
        String::new()
    } else {
        format!(" in {}", s.to)
    };
    let why = s
        .why
        .as_deref()
        .filter(|w| !w.is_empty())
        .map(|w| format!(" (why: {w})"))
        .unwrap_or_default();
    format!("{}{id}{place}: {}{why}", s.action, s.text)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(String, Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            if argv[1] == "outbox" {
                assert_eq!(argv, ["notes", "outbox", "show", "--json"]);
                return Ok(self.0.clone());
            }
            assert_eq!(argv, ["notes", "log", "--day", "2026-11-05", "--json"]);
            self.1.clone()
        }
    }

    const LOG: &str = r#"{"ts":"2026-11-05T07:20:39-08:00","action":"moved","from":"outbox","to":"demo","lane":"","text":"one"}
{"ts":"2026-11-05T07:20:44-08:00","action":"filed","from":"demo","to":"demo","lane":"agent","text":"one","id":"de-3"}
not json
{"ts":"2026-11-05T08:00:00-08:00","action":"edited","from":"demo","to":"","lane":"","text":"x"}
{"ts":"2026-11-05T09:10:00-08:00","action":"left","from":"outbox","to":"","lane":"","text":"tidy stuff","why":"too vague"}"#;

    #[test]
    fn the_doc_and_todays_intake_steps_newest_first() {
        let doc = r#"{"path":"/n/outbox.md","hash":"ab","text":"- [ ] two","waiting":1}"#;
        let v = read(&Fake(doc.into(), Ok(LOG.into())), "2026-11-05").unwrap();
        assert_eq!(v.doc.hash, "ab");
        assert_eq!(v.doc.text, "- [ ] two");
        let said: Vec<String> = v.handled.iter().map(say).collect();
        assert_eq!(
            said,
            [
                "left: tidy stuff (why: too vague)",
                "filed de-3 in demo: one"
            ],
            "moved and edited are not intake steps here; a torn line is skipped"
        );
        assert_eq!(v.counts, "1 filed, 1 left");
        assert_eq!(clock(&v.handled[0].ts), "09:10");
    }

    #[test]
    fn no_record_today_is_an_empty_log_and_a_bad_doc_says_which_command() {
        let doc = r#"{"path":"p","hash":"h","text":"","waiting":0}"#;
        let v = read(&Fake(doc.into(), Err("no record".into())), "2026-11-05").unwrap();
        assert!(v.handled.is_empty());
        assert_eq!(v.counts, "");
        let e = read(&Fake("nope".into(), Ok(String::new())), "2026-11-05").unwrap_err();
        assert!(e.starts_with("notes outbox show --json"), "{e}");
    }
}
