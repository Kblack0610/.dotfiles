//! `hub board --json`: the task feed joined with what only the hub knows, for a view that draws a
//! sheet as it stands (nvim's virtual text) and writes nothing into it. Per project, one head line
//! (stage, version, done share, version ETA, playtests waiting); per row, the words beside it (its
//! queue state, its forecast day, an epic's leaf rollup). Every number comes from `notes`
//! (`board --json`, `projects --stats --json`) or `projects::forecast`; this module only says
//! them, so the sheet and the hub print the same words.

use serde::Serialize;
use serde_json::{json, Value};

use crate::projects::{self, Card, Stats};
use crate::tasks::{self, Feed, Row};

/// One project's head line, for the sheets under `dir`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Head {
    pub profile: String,
    pub project: String,
    pub dir: String,
    pub text: String,
}

/// The words beside one row of a sheet (`line` is 1-based).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Hint {
    pub sheet: String,
    pub line: usize,
    pub text: String,
}

/// `v2.1.0 #alpha  55%  ETA ~11-21  playtest 114 waiting`: the mockup's head, minus the
/// project name a sheet already shows.
pub fn head_line(c: &Card, playtest_open: usize, today: chrono::NaiveDate) -> String {
    let mut s = c.version.clone().unwrap_or_else(|| "no version".into());
    if !c.stage.is_empty() {
        s += &format!(" #{}", c.stage);
    }
    if let Some(p) = c.percent {
        s += &format!("  {p}%");
    }
    s += &format!("  {}", projects::eta_words(c, today));
    if playtest_open > 0 {
        s += &format!("  playtest {playtest_open} waiting");
    }
    s
}

/// How much of the next child's text an epic's words carry, in chars, so the line fits beside
/// the row.
const NEXT_MAX: usize = 48;

/// The epic's words: `40% leaves, 3 open, next db-12 <text>`.
fn epic_text(e: &projects::EpicRollup, rows: &[&Row]) -> String {
    let total = e.open_weight + e.done_weight;
    let mut s = match total {
        0 => "no leaves".to_string(),
        t => format!("{}% leaves", e.done_weight * 100 / t),
    };
    let kids: Vec<&&Row> = rows
        .iter()
        .filter(|r| r.parent.as_deref() == Some(e.id.as_str()))
        .collect();
    s += &format!(", {} open", kids.len());
    if let Some(k) = kids.first() {
        let words: Vec<&str> = k
            .text
            .split_whitespace()
            .filter(|w| !w.starts_with('#'))
            .collect();
        let title = crate::text::cap(&words.join(" "), NEXT_MAX);
        s += &format!(", next {} {title}", k.id.as_deref().unwrap_or(""));
    }
    s
}

/// Each row's words, in the feed's sheet order: an epic its rollup; a row a queue item works its
/// item's state; a Next up row its forecast day.
pub fn hints(feed: &Feed, stats: &[Stats]) -> Vec<Hint> {
    let rows = feed.open_rows(None);
    let mut out = Vec::new();
    for r in &rows {
        let mut words: Vec<String> = Vec::new();
        if r.section.as_deref() == Some("epics") {
            let e = stats
                .iter()
                .filter(|s| s.profile == r.profile && Some(s.name.as_str()) == r.project.as_deref())
                .flat_map(|s| &s.epics)
                .find(|e| Some(e.id.as_str()) == r.id.as_deref());
            if let Some(e) = e {
                words.push(epic_text(e, &rows));
            }
        }
        // A forecast is drawn on Next up only: Now is under way and Backlog's is a far guess.
        let next = r.section.as_deref() == Some("next");
        let when = r.when_with(r.forecast.as_deref().filter(|_| next));
        if !when.is_empty() {
            words.push(when);
        }
        if !words.is_empty() {
            out.push(Hint {
                sheet: r.sheet.clone(),
                line: r.line,
                text: words.join("  "),
            });
        }
    }
    out
}

/// The heads of every project with a card.
pub fn heads(feed: &Feed, cards: &[Card], today: chrono::NaiveDate) -> Vec<Head> {
    feed.projects
        .iter()
        .filter_map(|p| {
            let c = cards
                .iter()
                .find(|c| c.name == p.project && c.profile == p.profile)?;
            Some(Head {
                profile: p.profile.clone(),
                project: p.project.clone(),
                dir: p.dir.clone(),
                text: head_line(c, p.playtest_open, today),
            })
        })
        .collect()
}

/// The day a feed was read, what its forecasts count from.
pub(crate) fn today_of(feed: &Feed) -> chrono::NaiveDate {
    chrono::NaiveDate::parse_from_str(&feed.today, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Local::now().date_naive())
}

/// The feed with each open row's `forecast` and `queue` filled in, and the stats and queue it
/// read them from; a source that failed is named in `feed.errors`, its words left off.
fn read(
    runner: &dyn crate::session_actions::Runner,
) -> Result<(Feed, Vec<Stats>, crate::queue::Queue), String> {
    let mut feed = tasks::feed(runner)?;
    let queue = crate::queue::Queue::read(runner);
    feed.errors.extend(queue.errors.iter().cloned());
    let stats = projects::stats(runner).unwrap_or_else(|e| {
        feed.errors.push(e);
        Vec::new()
    });
    let today = today_of(&feed);
    projects::forecast(&mut feed, &stats, today);
    feed.queue_states(&queue.items);
    Ok((feed, stats, queue))
}

/// What a board reads (the hub's and agent-web's): the task feed with its forecasts and queue
/// states, so both draw the words `hub board --json` gives nvim.
pub fn feed(runner: &dyn crate::session_actions::Runner) -> Result<Feed, String> {
    read(runner).map(|(f, _, _)| f)
}

/// `hub board --json`: `{today, heads, hints, errors}`, what a sheet draws beside itself. The
/// rows stay with `notes board --json` and the boards that read them through `feed`, so a
/// README opened in nvim decodes a few KB, not every row.
pub fn gather() -> Value {
    let runner = crate::session_actions::System;
    let (feed, stats, queue) = match read(&runner) {
        Ok(r) => r,
        Err(e) => return json!({"errors": [e]}),
    };
    let cards = projects::build(
        &stats,
        Some(&feed),
        &projects::fleet_state(),
        Some(&queue),
        chrono::Utc::now(),
    )
    .cards;
    json!({
        "today": feed.today,
        "heads": heads(&feed, &cards, today_of(&feed)),
        "hints": hints(&feed, &stats),
        "errors": feed.errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::{EpicRollup, Progress};
    use crate::tasks::Project;

    fn day(s: &str) -> chrono::NaiveDate {
        chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn row(id: &str, section: &str, rank: u64, weight: u32) -> Row {
        Row {
            profile: "personal".into(),
            project: Some("db".into()),
            lane: "agent".into(),
            id: Some(id.into()),
            text: format!("row {id} #size/s"),
            section: Some(section.into()),
            rank,
            weight,
            sheet: "/n/db/agent/README.md".into(),
            line: rank as usize,
            ..Row::default()
        }
    }

    fn stats(closed_weight_28d: u32) -> Stats {
        Stats {
            profile: "personal".into(),
            name: "db".into(),
            stage: "alpha".into(),
            progress: Progress {
                closed_weight_28d,
                ..Progress::default()
            },
            epics: vec![EpicRollup {
                id: "db-1".into(),
                open_weight: 6,
                done_weight: 4,
                ..EpicRollup::default()
            }],
            ..Stats::default()
        }
    }

    // A row's forecast sums the weight ranked ahead of it in sheet order, at the 28-day rate: 28
    // weight closed in 28 days is one a day, so the third unit of work lands on day three.
    #[test]
    fn the_forecast_walks_the_sheet_order_at_the_close_rate() {
        let mut feed = Feed {
            rows: vec![
                row("db-5", "backlog", 1, 1),
                row("db-3", "next", 9, 1),
                row("db-2", "now", 50, 1),
                row("db-1", "epics", 1, 8),
                row("db-4", "next", 10, 3),
            ],
            ..Feed::default()
        };
        forecast_of(&mut feed, 28);
        let got: Vec<(&str, Option<&str>)> = feed
            .rows
            .iter()
            .map(|r| (r.id.as_deref().unwrap(), r.forecast.as_deref()))
            .collect();
        assert_eq!(
            got,
            [
                ("db-5", Some("2026-11-15")),
                ("db-3", Some("2026-11-11")),
                ("db-2", Some("2026-11-10")),
                ("db-1", None),
                ("db-4", Some("2026-11-14")),
            ],
            "now first, then next by rank, then backlog; the epic adds nothing"
        );
        // Negative control: no closes in 28 days is no forecast, never a guess.
        forecast_of(&mut feed, 0);
        assert!(feed.rows.iter().all(|r| r.forecast.is_none()));
    }

    fn forecast_of(feed: &mut Feed, closed: u32) {
        projects::forecast(feed, &[stats(closed)], day("2026-11-09"));
    }

    #[test]
    fn a_parent_row_weighs_nothing_and_gets_no_day() {
        let mut kid = row("db-8", "next", 2, 1);
        kid.parent = Some("db-7".into());
        let mut feed = Feed {
            rows: vec![row("db-7", "next", 1, 8), kid],
            ..Feed::default()
        };
        forecast_of(&mut feed, 28);
        assert_eq!(feed.rows[0].forecast, None);
        assert_eq!(feed.rows[1].forecast.as_deref(), Some("2026-11-10"));
    }

    #[test]
    fn hints_say_the_queue_state_the_forecast_and_the_epic_rollup() {
        let mut kid = row("db-3", "next", 9, 1);
        kid.parent = Some("db-1".into());
        kid.queue = Some("queued".into());
        let mut running = row("db-2", "now", 5, 1);
        running.queue = Some("running".into());
        let mut feed = Feed {
            rows: vec![
                row("db-1", "epics", 1, 1),
                running,
                kid,
                row("db-9", "backlog", 1, 1),
            ],
            ..Feed::default()
        };
        forecast_of(&mut feed, 28);
        let got: Vec<(usize, String)> = hints(&feed, &[stats(28)])
            .into_iter()
            .map(|h| (h.line, h.text))
            .collect();
        assert_eq!(
            got,
            [
                (1, "40% leaves, 1 open, next db-3 row db-3".to_string()),
                (5, "running".to_string()),
                (9, "queued  ~11-11".to_string()),
            ],
            "a backlog row with no item gets no words"
        );
    }

    #[test]
    fn the_head_line_reads_like_the_mockup() {
        let c = Card {
            version: Some("v2.1.0".into()),
            stage: "alpha".into(),
            percent: Some(55),
            eta_days: Some(12),
            ..Card::default()
        };
        assert_eq!(
            head_line(&c, 114, day("2026-11-09")),
            "v2.1.0 #alpha  55%  ETA ~11-21  playtest 114 waiting"
        );
        let none = Card {
            eta_days: None,
            ..c.clone()
        };
        assert_eq!(
            head_line(&none, 0, day("2026-11-09")),
            "v2.1.0 #alpha  55%  no ETA (no closes in 28d)"
        );
        let feed = Feed {
            projects: vec![Project {
                profile: "personal".into(),
                project: "db".into(),
                dir: "/n/db".into(),
                ..Project::default()
            }],
            ..Feed::default()
        };
        let named = Card {
            profile: "personal".into(),
            name: "db".into(),
            ..c
        };
        assert_eq!(heads(&feed, &[named], day("2026-11-09"))[0].dir, "/n/db");
    }
}
