//! The "Red fixes" section on Infra, both surfaces: each red the triage queued as a `red` queue
//! item in the last `DAYS`, and whether its fix held. `fleet-bench reds --json` owns the rows and
//! the outcome words (fixed, came back, still red, ...), so this module only types them, splits
//! them into open and settled, orders the open ones worst first and words the summary line.

use serde::{Deserialize, Deserializer, Serialize};

use crate::session_actions::Runner;

/// The window: fleet-bench's own default (`REDS_DAYS`), passed so the summary's "in 7d" is true.
pub const DAYS: u32 = 7;

/// The open outcomes, worst first: a merged fix whose red is back or never went, then no fix, an
/// unmerged PR, and the ones still in hand. An outcome not listed here or in `SETTLED` sorts last
/// among the open ones, so a new word from fleet-bench is never hidden as settled.
pub const OPEN: [&str; 6] = [
    "came back",
    "still red",
    "no fix",
    "needs merge",
    "fixing",
    "queued",
];
/// The outcomes that need nothing: the fix held, the red cleared itself, or the item was dropped.
pub const SETTLED: [&str; 3] = ["fixed", "cleared", "cancelled"];

/// One red queue item, as `fleet-bench reds --json` prints it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Red {
    pub slug: String,
    /// `<area> <name>` (`watch playground-nightly`), else the item's title.
    #[serde(default)]
    pub red: String,
    /// The `cause:` tag: a commit or the fault's key.
    #[serde(default)]
    pub cause: Option<String>,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub queued: Option<String>,
    #[serde(default)]
    pub finished: Option<String>,
    /// As the queue item stores it: `owner/repo#N`, a URL, or a bare number.
    #[serde(default, deserialize_with = "text")]
    pub pr: Option<String>,
    /// The merge commit, once merged.
    #[serde(default, deserialize_with = "text")]
    pub merged: Option<String>,
    /// Minutes from queued to finished, for a merged fix.
    #[serde(default)]
    pub fix_min: Option<i64>,
    pub outcome: String,
    /// Where the PR opens, when `pr` says enough to build it; filled here, never read.
    #[serde(default, skip_deserializing)]
    pub pr_url: Option<String>,
}

/// A queue field that is a string, a number or null, as text.
fn text<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(match serde_json::Value::deserialize(d)? {
        serde_json::Value::Null => None,
        serde_json::Value::String(s) if s.is_empty() => None,
        serde_json::Value::String(s) => Some(s),
        v => Some(v.to_string()),
    })
}

/// A PR as a link: a URL as it is, `owner/repo#N` on GitHub, anything else (a bare number, a
/// list) none, since it names no repo.
pub fn pr_url(pr: &str) -> Option<String> {
    let pr = pr.trim();
    if pr.starts_with("https://") || pr.starts_with("http://") {
        return Some(pr.to_string());
    }
    let (repo, n) = pr.split_once('#')?;
    let (owner, name) = repo.split_once('/')?;
    let word = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    (word(owner) && word(name) && !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
        .then(|| format!("https://github.com/{owner}/{name}/pull/{n}"))
}

impl Red {
    /// True while the red needs something: anything but fixed, cleared or cancelled.
    pub fn open(&self) -> bool {
        !SETTLED.contains(&self.outcome.as_str())
    }

    /// How long ago it was queued, as `text::age` words; `-` when the time does not parse.
    pub fn age(&self, now: i64) -> String {
        self.queued
            .as_deref()
            .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
            .map_or("-".into(), |t| crate::text::age(now - t.timestamp()))
    }

    fn rank(&self) -> usize {
        OPEN.iter()
            .position(|o| *o == self.outcome)
            .unwrap_or(OPEN.len())
    }
}

/// The rows split for the section: the open ones worst first (oldest first within an outcome),
/// the settled ones newest first, and the one-line summary both surfaces print.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Reds {
    pub open: Vec<Red>,
    pub settled: Vec<Red>,
    pub summary: String,
}

fn argv() -> Vec<String> {
    ["fleet-bench", "reds", "--json", "--days", &DAYS.to_string()]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// `fleet-bench reds --json --days DAYS`, split. A failed run or a line that is not a row is an
/// error, never an empty (green-looking) list.
pub fn read(runner: &dyn Runner) -> Result<Reds, String> {
    let out = runner.run(&argv())?;
    let rows = out
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            serde_json::from_str::<Red>(l).map_err(|e| format!("fleet-bench reds --json: {e}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(split(rows))
}

/// The rows as the section shows them; see `Reds`.
pub fn split(rows: Vec<Red>) -> Reds {
    let (mut open, mut settled): (Vec<Red>, Vec<Red>) = rows
        .into_iter()
        .map(|mut r| {
            r.pr_url = r.pr.as_deref().and_then(pr_url);
            r
        })
        .partition(Red::open);
    open.sort_by(|a, b| a.rank().cmp(&b.rank()).then(a.queued.cmp(&b.queued)));
    settled.sort_by(|a, b| b.queued.cmp(&a.queued));
    let summary = summary(&open, &settled);
    Reds {
        open,
        settled,
        summary,
    }
}

/// `2 open: 1 came back, 1 fixing | 5 fixed, 1 cancelled in 7d, fix p50 34m`. The p50 is
/// fleet-bench's `red_fix_min_p50`: the lower median of every merged fix's minutes.
fn summary(open: &[Red], settled: &[Red]) -> String {
    if open.is_empty() && settled.is_empty() {
        return format!("no red fix queued in the last {DAYS} days");
    }
    let counts = |rows: &[Red], order: &[&str]| -> Vec<String> {
        let mut words: Vec<&str> = order.to_vec();
        for r in rows {
            if !words.contains(&r.outcome.as_str()) {
                words.push(&r.outcome);
            }
        }
        words
            .iter()
            .filter_map(|w| {
                let n = rows.iter().filter(|r| r.outcome == *w).count();
                (n > 0).then(|| format!("{n} {w}"))
            })
            .collect()
    };
    let head = if open.is_empty() {
        "none open".to_string()
    } else {
        format!("{} open: {}", open.len(), counts(open, &OPEN).join(", "))
    };
    let done = if settled.is_empty() {
        format!("none settled in {DAYS}d")
    } else {
        format!("{} in {DAYS}d", counts(settled, &SETTLED).join(", "))
    };
    let mut mins: Vec<i64> = open
        .iter()
        .chain(settled)
        .filter_map(|r| r.fix_min)
        .collect();
    mins.sort_unstable();
    let p50 = mins
        .get(mins.len().saturating_sub(1) / 2)
        .map(|m| format!(", fix p50 {}", crate::queue::dur(Some(*m))))
        .unwrap_or_default();
    format!("{head} | {done}{p50}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fixed(Result<&'static str, &'static str>, RefCell<Vec<String>>);
    impl Runner for Fixed {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            *self.1.borrow_mut() = argv.to_vec();
            self.0.map(String::from).map_err(String::from)
        }
    }

    fn fixed(out: Result<&'static str, &'static str>) -> Fixed {
        Fixed(out, RefCell::new(vec![]))
    }

    // One of each outcome, in no useful order, with the field types fleet-bench prints.
    const OUT: &str = concat!(
        r#"{"slug":"ar-1","red":"watch a","cause":null,"state":"done","queued":"2026-11-05T10:00:00Z","finished":"2026-11-05T10:34:00Z","pr":"Kblack0610/.dotfiles#1185","merged":"0a982c08","fix_min":34,"outcome":"fixed"}"#,
        "\n",
        r#"{"slug":"ar-2","red":"watch playground-nightly","cause":"4be3eead","state":"queued","queued":"2026-11-06T17:31:45Z","finished":null,"pr":null,"merged":null,"fix_min":null,"outcome":"queued"}"#,
        "\n",
        r#"{"slug":"ar-3","red":"runner dream","cause":null,"state":"done","queued":"2026-11-04T09:00:00Z","finished":"2026-11-04T10:00:00Z","pr":"https://git.example.org/k/home-config/pulls/9","merged":"abc","fix_min":60,"outcome":"came back"}"#,
        "\n",
        r#"{"slug":"ar-4","red":"unit x","state":"running","queued":"2026-11-06T12:00:00Z","pr":null,"outcome":"fixing"}"#,
        "\n",
        r#"{"slug":"ar-5","red":"watch b","state":"done","queued":"2026-11-03T08:00:00Z","pr":986,"merged":null,"outcome":"needs merge"}"#,
        "\n",
        r#"{"slug":"ar-6","red":"watch c","state":"done","queued":"2026-11-06T01:00:00Z","outcome":"cancelled"}"#,
        "\n",
        r#"{"slug":"ar-7","red":"watch d","state":"done","queued":"2026-11-02T08:00:00Z","fix_min":20,"merged":"def","outcome":"still red"}"#,
        "\n",
        r#"{"slug":"ar-8","red":"watch e","state":"done","queued":"2026-11-01T08:00:00Z","outcome":"no fix"}"#,
        "\n",
        r#"{"slug":"ar-9","red":"watch f","state":"done","queued":"2026-11-06T02:00:00Z","outcome":"cleared"}"#,
        "\n",
    );

    #[test]
    fn read_runs_reds_and_splits_open_worst_first_from_settled() {
        let f = fixed(Ok(OUT));
        let r = read(&f).unwrap();
        assert_eq!(f.1.borrow().join(" "), "fleet-bench reds --json --days 7");
        let slugs = |rows: &[Red]| rows.iter().map(|r| r.slug.clone()).collect::<Vec<_>>();
        assert_eq!(
            slugs(&r.open),
            ["ar-3", "ar-7", "ar-8", "ar-5", "ar-4", "ar-2"],
            "came back, still red, no fix, needs merge, fixing, queued"
        );
        assert_eq!(slugs(&r.settled), ["ar-9", "ar-6", "ar-1"], "newest first");
        assert_eq!(
            r.summary,
            "6 open: 1 came back, 1 still red, 1 no fix, 1 needs merge, 1 fixing, 1 queued | 1 fixed, 1 cleared, 1 cancelled in 7d, fix p50 34m"
        );
    }

    #[test]
    fn a_pr_reads_as_text_and_links_when_it_names_a_repo() {
        let r = read(&fixed(Ok(OUT))).unwrap();
        let by = |s: &str| {
            r.open
                .iter()
                .chain(&r.settled)
                .find(|x| x.slug == s)
                .unwrap()
        };
        assert_eq!(by("ar-5").pr.as_deref(), Some("986"), "a number is text");
        assert_eq!(by("ar-5").pr_url, None, "a bare number names no repo");
        assert_eq!(
            by("ar-1").pr_url.as_deref(),
            Some("https://github.com/Kblack0610/.dotfiles/pull/1185")
        );
        assert_eq!(
            by("ar-3").pr_url.as_deref(),
            Some("https://git.example.org/k/home-config/pulls/9")
        );
        assert_eq!(by("ar-2").pr, None);
        let at = chrono::DateTime::parse_from_rfc3339("2026-11-06T19:31:45Z").unwrap();
        assert_eq!(by("ar-2").age(at.timestamp()), "2h");
        assert_eq!(Red::default().age(0), "-");
        assert_eq!(pr_url("a/b#1 #2, c/d#3"), None, "a list is not one PR");
    }

    #[test]
    fn a_failed_run_or_a_bad_line_is_an_error_never_an_empty_list() {
        let e = read(&fixed(Err("reds: cannot read the queue"))).unwrap_err();
        assert!(e.contains("cannot read the queue"), "{e}");
        let bad = concat!(
            r#"{"slug":"ar-1","red":"watch a","outcome":"fixed"}"#,
            "\nnot json\n"
        );
        let e = read(&fixed(Ok(bad))).unwrap_err();
        assert!(e.starts_with("fleet-bench reds --json:"), "{e}");
        let e = read(&fixed(Ok(r#"{"slug":"ar-1","red":"watch a"}"#))).unwrap_err();
        assert!(
            e.contains("outcome"),
            "a row with no outcome is not a row: {e}"
        );
    }

    #[test]
    fn the_summary_says_when_nothing_is_open_or_queued() {
        let r = read(&fixed(Ok(""))).unwrap();
        assert!(r.open.is_empty() && r.settled.is_empty());
        assert_eq!(r.summary, "no red fix queued in the last 7 days");
        let one = r#"{"slug":"ar-1","red":"watch a","fix_min":150,"merged":"x","outcome":"fixed"}"#;
        assert_eq!(
            read(&fixed(Ok(one))).unwrap().summary,
            "none open | 1 fixed in 7d, fix p50 2h"
        );
        let two = concat!(
            r#"{"slug":"ar-1","red":"a","outcome":"fixing"}"#,
            "\n",
            r#"{"slug":"ar-2","red":"b","outcome":"retrying"}"#,
        );
        let r = read(&fixed(Ok(two))).unwrap();
        assert_eq!(
            r.summary,
            "2 open: 1 fixing, 1 retrying | none settled in 7d"
        );
        assert_eq!(
            r.open[1].outcome, "retrying",
            "an unknown outcome is open, last"
        );
    }
}
