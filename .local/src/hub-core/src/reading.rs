//! One reading state for every source, card and cell a dashboard shows (dashboards.md rule 6:
//! absence is never a verdict). A source that is off, has never reported, could not be read or
//! stopped reporting says which in these words; only `Live` may show its value as a verdict, so an
//! empty list, a blank cell or a zero never stands in for "we do not know".

use chrono::{Local, TimeZone};
use serde::Serialize;

use crate::vocab::Level;

/// The cell word for a read that failed; the long form adds the reason.
pub const NOT_READ: &str = "not read";
/// The cell word for a source that has reported nothing yet: unknown, never up and never zero.
pub const NO_DATA: &str = "no data";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", content = "detail", rename_all = "snake_case")]
pub enum State {
    /// Turned off on purpose, so nothing is expected and nothing is wrong.
    Off,
    /// Nothing has reported yet.
    Never,
    /// The read failed; the reason names the source and why.
    NotRead(String),
    /// The newest reading is older than the source's cadence allows; the epoch it was taken at.
    Stale(i64),
    /// Read and fresh.
    Live,
}

impl State {
    /// `Live` when `newest` is at most `max_age` seconds before `now`, `Stale` past it, `Never`
    /// with no reading at all.
    pub fn of_age(newest: Option<i64>, now: i64, max_age: i64) -> State {
        match newest {
            None => State::Never,
            Some(t) if now - t > max_age => State::Stale(t),
            Some(_) => State::Live,
        }
    }

    /// The sentence a surface shows for the source `what` (`fleet state`, `Monitor`); empty for
    /// `Live`, whose value speaks for itself.
    pub fn words(&self, what: &str) -> String {
        match self {
            State::Off => format!("{what} is off"),
            State::Never => format!("no {what} yet"),
            State::NotRead(why) => format!("{NOT_READ}: {why}"),
            State::Stale(at) => format!("{what} stopped reporting at {}", hm(*at)),
            State::Live => String::new(),
        }
    }

    /// `words` as a sentence of its own, capitalised: `Not read: release-state could not be read.`
    pub fn sentence(&self, what: &str) -> String {
        let w = self.words(what);
        let mut c = w.chars();
        c.next()
            .map_or_else(String::new, |f| f.to_uppercase().chain(c).collect())
    }

    /// The short word for a table cell.
    pub fn cell(&self) -> &'static str {
        match self {
            State::Off => "off",
            State::Never => NO_DATA,
            State::NotRead(_) => NOT_READ,
            State::Stale(_) => "stale",
            State::Live => "",
        }
    }

    /// Off and Live need nothing; every other state needs a look, and none is ever green.
    pub fn level(&self) -> Level {
        match self {
            State::Off | State::Live => Level::Ok,
            _ => Level::Warn,
        }
    }
}

/// A reading's time as the dashboards print one: `11-12 13:05`, local.
pub fn hm(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map_or_else(|| t.to_string(), |d| d.format("%m-%d %H:%M").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absence_is_never_a_verdict() {
        // no reading is Never, an old one Stale, and neither is green nor empty words
        for s in [
            State::of_age(None, 1000, 60),
            State::of_age(Some(900), 1000, 60),
            State::NotRead("ssh: no route".into()),
        ] {
            assert_eq!(s.level(), Level::Warn, "{s:?}");
            assert!(!s.words("fleet state").is_empty(), "{s:?}");
            assert!(!s.cell().is_empty(), "{s:?}");
        }
        assert_eq!(State::of_age(Some(950), 1000, 60), State::Live);
        assert_eq!(State::of_age(Some(900), 1000, 60), State::Stale(900));
        assert_eq!(State::Never.words("fleet state"), "no fleet state yet");
        assert_eq!(State::NotRead("x: y".into()).words("any"), "not read: x: y");
        assert!(State::Stale(900)
            .words("Monitor")
            .starts_with("Monitor stopped reporting at "));
        assert_eq!(State::Off.level(), Level::Ok);
        assert_eq!(State::NotRead("x.".into()).sentence("any"), "Not read: x.");
    }

    /// The files allowed to spell an empty-state word, per file, outside tests and comments:
    /// only agent-web's mirror of `NOT_READ` and `NO_DATA`, which the browser cannot import. Any
    /// other file writing one by hand fails this test (dashboards.md rule 6).
    const HAND_WRITTEN: &[(&str, usize)] = &[("agent-web/static/ui.js", 2)];

    /// A string, template or HTML text that is or starts with an empty-state word, in any case
    /// (`"Not read: x"`, `'NO DATA'`, `>no data from x<`); the words inside a longer sentence
    /// (`2 channels not read`) are that sentence's own.
    const NEEDLES: &[&str] = &[
        "\"not read",
        "'not read",
        "`not read",
        ">not read",
        "\"no data",
        "'no data",
        "`no data",
        ">no data",
        "\"never\"",
        "'never'",
    ];

    fn count(path: &std::path::Path) -> usize {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let body = text.split("#[cfg(test)]").next().unwrap_or("");
        body.lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .map(|l| {
                let l = l.to_lowercase();
                NEEDLES.iter().map(|n| l.matches(n).count()).sum::<usize>()
            })
            .sum()
    }

    fn files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                files(&p, out);
            } else if p.extension().is_some_and(|x| x == "rs" || x == "js") {
                out.push(p);
            }
        }
    }

    #[test]
    fn empty_state_words_come_from_one_place() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let mut all = vec![];
        for d in [
            "hub-core/src",
            "hub-tui/src",
            "agent-web/src",
            "agent-web/static",
        ] {
            files(&src.join(d), &mut all);
        }
        assert!(all.len() > 50, "the scan found only {} files", all.len());
        let mut found: Vec<(String, usize)> = all
            .iter()
            .filter(|p| !p.ends_with("hub-core/src/reading.rs"))
            .map(|p| {
                let rel = p.strip_prefix(&src).unwrap().to_string_lossy().into_owned();
                (rel, count(p))
            })
            .filter(|(_, n)| *n > 0)
            .collect();
        found.sort();
        let ui = std::fs::read_to_string(src.join("agent-web/static/ui.js")).unwrap();
        assert!(
            ui.contains(&format!(
                "const NOT_READ = \"{NOT_READ}\", NO_DATA = \"{NO_DATA}\";"
            )),
            "agent-web/static/ui.js no longer mirrors NOT_READ and NO_DATA"
        );
        let want: Vec<(String, usize)> = HAND_WRITTEN
            .iter()
            .map(|(f, n)| (f.to_string(), *n))
            .collect();
        assert_eq!(
            found, want,
            "hand-written empty-state words changed: use hub_core::reading (State, NOT_READ, \
             NO_DATA), or lower HAND_WRITTEN when a file adopts it"
        );
    }
}
