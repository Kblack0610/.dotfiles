//! The Reports tab's reader, for both hub surfaces: every file in the refs day folders, as
//! `notes report list --json --all` prints them (notes-cli `report.rs` owns the contract, the
//! kinds and the stream rule), shaped into the tab's sections. Today holds the reports that need
//! the human, then the stream (today's reports and unread ones under a week old, the `stream`
//! flag the CLI sets), then today's digests and the human's own captures; Archive holds every
//! other report by day. The one writer is `notes report read`, which agent-web calls when a
//! report is opened ([`read_argv`]); this reader never changes a file.

use serde::{Deserialize, Serialize};

use crate::display::fmt::counted;
use crate::links::{Kind, Link};
use crate::session_actions::Runner;

/// The archive days listed before the rest fold into "+N older days": the layout's fold.
pub const ARCHIVE_DAYS: usize = crate::layout::FOLD_ROWS;
/// The longest id `notes report read` is handed: a date, a dash and a slug.
const MAX_ID: usize = 200;

/// One line of `notes report list --json`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Entry {
    pub id: String,
    /// `report`, `digest` (a generated file) or `capture` (no frontmatter: the human's).
    pub kind: String,
    pub date: String,
    pub title: String,
    pub summary: String,
    pub from: String,
    pub needs_you: bool,
    pub created: String,
    pub read: Option<String>,
    /// In the stream: today's, or an unread report under a week old (notes-cli's rule).
    pub stream: bool,
    /// The wikilink target `notes show` opens.
    pub target: String,
}

impl Entry {
    fn is_report(&self) -> bool {
        self.kind == "report"
    }

    fn unread(&self) -> bool {
        self.is_report() && self.read.as_deref().unwrap_or("").is_empty()
    }
}

/// One row as both surfaces draw it.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Row {
    pub id: String,
    pub kind: String,
    pub date: String,
    pub title: String,
    /// The summary's first line, under the title.
    pub lead: String,
    pub summary: String,
    pub from: String,
    /// When it was filed (RFC 3339), the time beside the row.
    pub at: String,
    /// The state word: `needs you`, `unread`, `read`, else the kind.
    pub state: &'static str,
    /// The state's hue: `warn` for a report that needs the human, `""` else.
    pub level: &'static str,
    pub unread: bool,
    /// The note `notes show` opens, whose body the row unfolds to.
    pub target: String,
    /// This row's own place on the tab.
    pub link: Link,
}

impl Row {
    fn of(e: &Entry) -> Row {
        let (state, level) = match (e.is_report(), e.needs_you, e.unread()) {
            (true, true, true) => ("needs you", "warn"),
            (true, _, true) => ("unread", ""),
            (true, _, false) => ("read", ""),
            (false, ..) if e.kind == "digest" => ("digest", ""),
            (false, ..) => ("capture", ""),
        };
        Row {
            id: e.id.clone(),
            kind: e.kind.clone(),
            date: e.date.clone(),
            title: e.title.clone(),
            lead: e.summary.lines().next().unwrap_or("").trim().to_string(),
            summary: e.summary.clone(),
            from: e.from.clone(),
            at: e.created.clone(),
            state,
            level,
            unread: e.unread(),
            target: e.target.clone(),
            link: Link::to(Kind::Report, e.id.clone()),
        }
    }
}

/// A section of the Today inner tab, its id the layout's.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Section {
    pub id: &'static str,
    pub title: &'static str,
    /// Drawn shut: the reference reads, not the ones to act on.
    pub folded: bool,
    pub rows: Vec<Row>,
}

/// One archived day: its reports that left the stream.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Day {
    pub date: String,
    /// `4 reports, 1 unread`.
    pub count: String,
    pub rows: Vec<Row>,
}

/// A headline figure over the sections.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Tile {
    pub label: &'static str,
    pub n: usize,
    pub level: &'static str,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct View {
    pub today: String,
    pub tiles: Vec<Tile>,
    pub sections: Vec<Section>,
    /// `2 unread moved to archive`: unread reports past the stream's week; empty with none.
    pub moved: String,
    pub archive: Vec<Day>,
    /// Archive days past [`ARCHIVE_DAYS`], left out.
    pub older_days: usize,
    /// Unread reports in the stream: the nav's badge.
    pub unread: usize,
}

/// A day note's refs as one line on the Daily tab, linking to that day on the Reports tab.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DayLine {
    pub label: &'static str,
    /// `3 reports, 1 unread, 2 digests, 1 note`.
    pub text: String,
    pub link: Link,
}

fn list(runner: &dyn Runner, since: Option<&str>) -> Result<Vec<Entry>, String> {
    let mut argv = vec!["notes", "report", "list", "--json", "--all"];
    if let Some(d) = since {
        argv.extend(["--since", d]);
    }
    let argv: Vec<String> = argv.into_iter().map(String::from).collect();
    parse(&runner.run(&argv)?)
}

/// `notes report list --json` output: one object per line.
pub fn parse(out: &str) -> Result<Vec<Entry>, String> {
    out.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).map_err(|e| format!("notes report list --json: {e}")))
        .collect()
}

/// The tab as of `today` (YYYY-MM-DD, local).
pub fn read(runner: &dyn Runner, today: &str) -> Result<View, String> {
    Ok(build(&list(runner, None)?, today))
}

/// The sections from the CLI's rows, which come newest day first and newest first in a day.
pub fn build(all: &[Entry], today: &str) -> View {
    let rows = |keep: &dyn Fn(&Entry) -> bool| -> Vec<Row> {
        all.iter().filter(|e| keep(e)).map(Row::of).collect()
    };
    let needs = rows(&|e| e.stream && e.needs_you && e.unread());
    let stream = rows(&|e| e.stream && e.is_report() && !(e.needs_you && e.unread()));
    let digests = rows(&|e| e.date == today && e.kind == "digest");
    let captures = rows(&|e| e.date == today && e.kind == "capture");
    let unread = all.iter().filter(|e| e.stream && e.unread()).count();
    let moved = all.iter().filter(|e| !e.stream && e.unread()).count();
    let reports_today = all
        .iter()
        .filter(|e| e.date == today && e.is_report())
        .count();
    let mut archive: Vec<Day> = vec![];
    for e in all.iter().filter(|e| e.is_report() && !e.stream) {
        match archive.last_mut() {
            Some(d) if d.date == e.date => d.rows.push(Row::of(e)),
            _ => archive.push(Day {
                date: e.date.clone(),
                count: String::new(),
                rows: vec![Row::of(e)],
            }),
        }
    }
    let older_days = archive.len().saturating_sub(ARCHIVE_DAYS);
    archive.truncate(ARCHIVE_DAYS);
    for d in &mut archive {
        let unread = d.rows.iter().filter(|r| r.unread).count();
        d.count = with_unread(counted(d.rows.len(), "report"), unread);
    }
    let tiles = vec![
        Tile {
            label: "unread",
            n: unread,
            level: "",
        },
        Tile {
            label: "needs you",
            n: needs.len(),
            level: if needs.is_empty() { "" } else { "warn" },
        },
        Tile {
            label: "today",
            n: reports_today,
            level: "",
        },
        Tile {
            label: "digests",
            n: digests.len(),
            level: "",
        },
    ];
    let section = |id, title, folded, rows| Section {
        id,
        title,
        folded,
        rows,
    };
    View {
        today: today.to_string(),
        tiles,
        sections: vec![
            section("needs", "Needs you", false, needs),
            section("stream", "Today", false, stream),
            section("digests", "Digests", true, digests),
            section("captures", "Your notes", true, captures),
        ],
        moved: if moved == 0 {
            String::new()
        } else {
            format!("{moved} unread moved to archive")
        },
        archive,
        older_days,
        unread,
    }
}

fn with_unread(count: String, unread: usize) -> String {
    if unread == 0 {
        count
    } else {
        format!("{count}, {unread} unread")
    }
}

/// The Daily tab's line for `date`: its reports, digests and captures counted, linking to that
/// day on the Reports tab. None for a day with no refs, or when they could not be read (the
/// note itself was read).
pub fn day_line(runner: &dyn Runner, date: &str) -> Option<DayLine> {
    let all = list(runner, Some(date)).ok()?;
    day_line_of(&all, date)
}

fn day_line_of(all: &[Entry], date: &str) -> Option<DayLine> {
    let day: Vec<&Entry> = all.iter().filter(|e| e.date == date).collect();
    let n = |kind: &str| day.iter().filter(|e| e.kind == kind).count();
    let unread = day.iter().filter(|e| e.unread()).count();
    let parts: Vec<String> = [
        (n("report"), "report"),
        (n("digest"), "digest"),
        (n("capture"), "note"),
    ]
    .into_iter()
    .filter(|(k, _)| *k > 0)
    .map(|(k, unit)| match unit {
        "report" => with_unread(counted(k, unit), unread),
        _ => counted(k, unit),
    })
    .collect();
    (!parts.is_empty()).then(|| DayLine {
        label: "Refs",
        text: parts.join(", "),
        link: Link::to(Kind::Report, date),
    })
}

/// What marking report `id` read runs, or why it is refused first: an id is a date and a
/// lowercase slug (notes-cli checks the rest), so nothing else reaches the CLI.
pub fn read_argv(id: &str) -> Result<Vec<String>, &'static str> {
    let ok = id.len() <= MAX_ID
        && id.len() > 11
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if !ok {
        return Err("not a report id (<date>-<slug>)");
    }
    Ok(["notes", "report", "read", "--", id]
        .map(String::from)
        .to_vec())
}

/// Mark report `id` read.
pub fn mark_read(runner: &dyn Runner, id: &str) -> Result<(), String> {
    runner.run(&read_argv(id)?).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    const TODAY: &str = "2026-11-24";
    // What `notes report list --json --all` prints for a fixture vault: today's needs-you report,
    // a read and an unread report today, an unread one from yesterday (still in the stream), a
    // read one and an unread one past the week (archive), a digest and a pasted capture.
    const LIST: &str = concat!(
        r#"{"id":"2026-11-24-ups-switch","kind":"report","date":"2026-11-24","slug":"ups-switch","title":"UPS switch","summary":"Load fell 76% -> 41%\nUSB link still down","from":"ar-1","needs_you":true,"created":"2026-11-24T15:40:00-08:00","updated":"2026-11-24T15:40:00-08:00","read":null,"stream":true,"target":"journal/refs/2026-11-24/ups-switch","path":"/v/ups-switch.md"}"#,
        "\n",
        r#"{"id":"2026-11-24-board-pass","kind":"report","date":"2026-11-24","slug":"board-pass","title":"Board cleanup pass 3","summary":"212 -> 168 open rows","from":"ar-2","needs_you":false,"created":"2026-11-24T11:15:00-08:00","updated":"","read":"2026-11-24T12:00:00-08:00","stream":true,"target":"journal/refs/2026-11-24/board-pass","path":"/v/board-pass.md"}"#,
        "\n",
        r#"{"id":"2026-11-24-flakes","kind":"report","date":"2026-11-24","slug":"flakes","title":"Nightly flake readout","summary":"4 flaky specs","from":"","needs_you":false,"created":"2026-11-24T07:02:00-08:00","updated":"","read":null,"stream":true,"target":"journal/refs/2026-11-24/flakes","path":"/v/flakes.md"}"#,
        "\n",
        r#"{"id":"2026-11-24-briefing","kind":"digest","date":"2026-11-24","slug":"briefing","title":"Briefing","summary":"","from":"","needs_you":false,"created":"2026-11-24T06:00:00-08:00","updated":"","read":null,"stream":true,"target":"journal/refs/2026-11-24/briefing","path":"/v/briefing.md"}"#,
        "\n",
        r#"{"id":"2026-11-24-paste","kind":"capture","date":"2026-11-24","slug":"paste","title":"paste","summary":"","from":"","needs_you":false,"created":"2026-11-24T09:00:00-08:00","updated":"","read":null,"stream":true,"target":"journal/refs/2026-11-24/paste","path":"/v/paste.md"}"#,
        "\n",
        r#"{"id":"2026-11-23-yday","kind":"report","date":"2026-11-23","slug":"yday","title":"Yesterday's","summary":"one","from":"","needs_you":false,"created":"2026-11-23T10:00:00-08:00","updated":"","read":null,"stream":true,"target":"journal/refs/2026-11-23/yday","path":"/v/yday.md"}"#,
        "\n",
        r#"{"id":"2026-11-23-old-digest","kind":"digest","date":"2026-11-23","slug":"old-digest","title":"Briefing","summary":"","from":"","needs_you":false,"created":"","updated":"","read":null,"stream":false,"target":"journal/refs/2026-11-23/old-digest","path":"/v/x.md"}"#,
        "\n",
        r#"{"id":"2026-11-10-old","kind":"report","date":"2026-11-10","slug":"old","title":"Old read","summary":"x","from":"","needs_you":false,"created":"2026-11-10T10:00:00-08:00","updated":"","read":"2026-11-10T11:00:00-08:00","stream":false,"target":"journal/refs/2026-11-10/old","path":"/v/old.md"}"#,
        "\n",
        r#"{"id":"2026-11-10-lost","kind":"report","date":"2026-11-10","slug":"lost","title":"Old unread","summary":"y","from":"","needs_you":true,"created":"2026-11-10T09:00:00-08:00","updated":"","read":null,"stream":false,"target":"journal/refs/2026-11-10/lost","path":"/v/lost.md"}"#,
        "\n",
    );

    fn view() -> View {
        build(&parse(LIST).unwrap(), TODAY)
    }

    fn ids(rows: &[Row]) -> Vec<&str> {
        rows.iter().map(|r| r.id.as_str()).collect()
    }

    #[test]
    fn today_holds_needs_you_then_the_stream_then_digests_and_captures() {
        let v = view();
        let titles: Vec<&str> = v.sections.iter().map(|s| s.title).collect();
        assert_eq!(titles, ["Needs you", "Today", "Digests", "Your notes"]);
        assert_eq!(ids(&v.sections[0].rows), ["2026-11-24-ups-switch"]);
        assert_eq!(v.sections[0].rows[0].state, "needs you");
        assert_eq!(v.sections[0].rows[0].level, "warn");
        assert_eq!(v.sections[0].rows[0].lead, "Load fell 76% -> 41%");
        // Today's read one stays, marked read; yesterday's unread one is still in the stream.
        assert_eq!(
            ids(&v.sections[1].rows),
            [
                "2026-11-24-board-pass",
                "2026-11-24-flakes",
                "2026-11-23-yday"
            ]
        );
        assert_eq!(v.sections[1].rows[0].state, "read");
        assert_eq!(v.sections[1].rows[1].state, "unread");
        // Only today's digests and captures, and never as reports.
        assert_eq!(ids(&v.sections[2].rows), ["2026-11-24-briefing"]);
        assert_eq!(ids(&v.sections[3].rows), ["2026-11-24-paste"]);
        assert!(v.sections[2].folded && v.sections[3].folded);
    }

    #[test]
    fn a_capture_never_reaches_the_stream_or_the_counts() {
        // Negative control: the pasted file lists as a capture, so no report section holds it.
        let v = view();
        for s in &v.sections[..2] {
            assert!(s.rows.iter().all(|r| r.kind == "report"), "{}", s.title);
        }
        assert!(v
            .archive
            .iter()
            .flat_map(|d| &d.rows)
            .all(|r| r.kind == "report"));
        // ups-switch, flakes and yday are unread in the stream; board-pass is read.
        assert_eq!(v.unread, 3);
    }

    #[test]
    fn the_tiles_and_the_archive_by_day() {
        let v = view();
        let tiles: Vec<(&str, usize)> = v.tiles.iter().map(|t| (t.label, t.n)).collect();
        assert_eq!(
            tiles,
            [
                ("unread", 3),
                ("needs you", 1),
                ("today", 3),
                ("digests", 1)
            ]
        );
        assert_eq!(v.tiles[1].level, "warn");
        // An unread report past the week leaves the stream with a count line, never piles up.
        assert_eq!(v.moved, "1 unread moved to archive");
        assert_eq!(v.archive.len(), 1);
        let d = &v.archive[0];
        assert_eq!(d.date, "2026-11-10");
        assert_eq!(d.count, "2 reports, 1 unread");
        assert_eq!(ids(&d.rows), ["2026-11-10-old", "2026-11-10-lost"]);
        assert_eq!(v.older_days, 0);
    }

    #[test]
    fn archive_days_past_the_fold_are_counted_not_listed() {
        let rows: Vec<Entry> = (0..ARCHIVE_DAYS + 3)
            .map(|i| Entry {
                id: format!("2025-01-01-r{i}"),
                kind: "report".into(),
                date: format!("day-{i:03}"),
                read: Some("x".into()),
                ..Default::default()
            })
            .collect();
        let v = build(&rows, TODAY);
        assert_eq!(v.archive.len(), ARCHIVE_DAYS);
        assert_eq!(v.older_days, 3);
        assert!(v.moved.is_empty());
    }

    #[test]
    fn a_row_links_to_itself_on_the_tab() {
        let v = view();
        assert_eq!(
            v.sections[0].rows[0].link.href(),
            "#reports/2026-11-24-ups-switch"
        );
    }

    #[test]
    fn the_daily_line_counts_one_day() {
        let all = parse(LIST).unwrap();
        let l = day_line_of(&all, TODAY).unwrap();
        assert_eq!(l.text, "3 reports, 1 unread, 1 digest, 1 note");
        assert_eq!(l.link.href(), "#reports/2026-11-24");
        // The 10th: two reports, one unread, and nothing else.
        assert_eq!(
            day_line_of(&all, "2026-11-10").unwrap().text,
            "2 reports, 1 unread"
        );
        assert_eq!(day_line_of(&all, "2026-11-01"), None);
    }

    struct Fake {
        out: &'static str,
        calls: RefCell<Vec<Vec<String>>>,
    }
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.to_vec());
            Ok(self.out.to_string())
        }
    }

    #[test]
    fn the_reader_and_the_mark_run_the_cli() {
        let f = Fake {
            out: LIST,
            calls: RefCell::default(),
        };
        let v = read(&f, TODAY).unwrap();
        assert_eq!(v.unread, 3);
        assert!(day_line(&f, TODAY).is_some());
        mark_read(&f, "2026-11-24-flakes").unwrap();
        let calls = f.calls.borrow();
        assert_eq!(calls[0], ["notes", "report", "list", "--json", "--all"]);
        assert_eq!(
            calls[1],
            ["notes", "report", "list", "--json", "--all", "--since", TODAY]
        );
        assert_eq!(
            calls[2],
            ["notes", "report", "read", "--", "2026-11-24-flakes"]
        );
    }

    #[test]
    fn a_bad_id_never_reaches_the_cli() {
        for id in [
            "",
            "--all",
            "2026-11-24",
            "2026-11-24-A",
            "../x",
            "2026-11-24-a b",
        ] {
            assert!(read_argv(id).is_err(), "{id}");
        }
        assert!(read_argv("2026-11-24-ok-1").is_ok());
    }

    #[test]
    fn a_bad_line_is_an_error_not_an_empty_tab() {
        assert!(parse("{not json}\n").is_err());
        assert_eq!(parse("\n").unwrap(), vec![]);
    }
}
