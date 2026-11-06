//! `notes log --steps`: the record replayed into the chain's steps, inbox to done, so one
//! reader says how many items each step took in and let out, how long the ones it let out sat
//! there, and what the record believes is still in it. The state files (sheets, the queue dirs)
//! say what is in a step now; `fleet-bench pipeline` sets this beside them, and a gap between
//! the two is a writer that skipped the record.
//!
//! Each hop has its own subject: an intake line by its words, a board row by its id, a queue
//! item by its slug. A hop hands one subject to the next (`filed` ends the line and starts the
//! row, `item-added` with a row id ends the row and starts the item), so each subject is in at
//! most one step. Steps come from the action, not the event's `stage` field, which older
//! events lack.

use crate::ingest::Event;
use chrono::{DateTime, Duration, FixedOffset};
use serde::Serialize;
use std::collections::HashMap;

/// The chain's steps, in order. `done` is terminal: it counts arrivals, never what sits in it.
pub const STEPS: [&str; 6] = ["inbox", "backlog", "queued", "running", "waiting", "done"];

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
enum Key {
    Line(String),
    Row(String),
    Item(String),
}

/// One subject's move: to `to` (`None` leaves the chain), out of `from` when the record never
/// saw it arrive.
struct Move {
    key: Key,
    to: Option<&'static str>,
    from: Option<&'static str>,
}

fn step(name: &str) -> Option<&'static str> {
    STEPS.iter().copied().find(|s| *s == name)
}

/// An intake line's subject: its words without the project tag, case and spacing folded, so
/// the outbox line, the inbox line it moved to and the line the sweep filed are one subject.
fn line_key(text: &str) -> Key {
    let t = crate::md::without_agent_tag(&crate::md::without_project_tag(text)).to_lowercase();
    Key::Line(t.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// The moves one event makes. The action-to-step table lives here and only here.
fn moves(e: &Event) -> Vec<Move> {
    let id = e.id.clone().filter(|i| !i.is_empty());
    let item = e.item.clone().filter(|i| !i.is_empty());
    let mv = |key, to, from| Move { key, to, from };
    match e.action.as_str() {
        "added" if e.from == "outbox" => vec![mv(line_key(&e.text), Some("inbox"), None)],
        "moved" if e.from == "outbox" || e.from == "focus" => {
            vec![mv(line_key(&e.text), Some("inbox"), None)]
        }
        "filed" => {
            let mut v = vec![mv(line_key(&e.text), None, Some("inbox"))];
            v.extend(id.map(|i| mv(Key::Row(i), Some("backlog"), None)));
            v
        }
        "dup" => vec![mv(line_key(&e.text), None, Some("inbox"))],
        "added" => id
            .map(|i| vec![mv(Key::Row(i), Some("backlog"), None)])
            .unwrap_or_default(),
        "done" | "dropped" | "archived" => id
            .map(|i| vec![mv(Key::Row(i), None, Some("backlog"))])
            .unwrap_or_default(),
        "item-added" => {
            let mut v: Vec<Move> = id
                .map(|i| mv(Key::Row(i), None, Some("backlog")))
                .into_iter()
                .collect();
            v.extend(item.map(|i| mv(Key::Item(i), step(&e.to), None)));
            v
        }
        // `why` is "<from> -> <to> (<status>)", so a move of an item the record never saw
        // arrive still says which step it left.
        "item-moved" => {
            let was = e
                .why
                .as_deref()
                .and_then(|w| w.split(" -> ").next())
                .and_then(step);
            item.map(|i| vec![mv(Key::Item(i), step(&e.to), was)])
                .unwrap_or_default()
        }
        "item-cancelled" => item
            .map(|i| vec![mv(Key::Item(i), None, None)])
            .unwrap_or_default(),
        _ => vec![],
    }
}

/// One step's numbers.
#[derive(Serialize, Debug, PartialEq, Default)]
pub struct Row {
    pub step: &'static str,
    /// What the record holds in the step now (none for `done`).
    pub open: usize,
    /// Minutes the oldest of those has sat there.
    pub oldest_min: Option<i64>,
    pub in_1h: usize,
    pub out_1h: usize,
    pub in_24h: usize,
    pub out_24h: usize,
    /// Minutes in the step of the subjects that left it in the last 24 hours, where the record
    /// saw them arrive.
    pub dwell_n: usize,
    pub dwell_p50_min: Option<i64>,
    pub dwell_p90_min: Option<i64>,
}

/// Nearest-rank percentile of sorted `v`.
fn pct(v: &[i64], p: usize) -> Option<i64> {
    (!v.is_empty()).then(|| v[((v.len() * p).div_ceil(100)).max(1) - 1])
}

/// Replay `events`, oldest first, as of `now`.
pub fn replay(events: &[Event], now: DateTime<FixedOffset>) -> Vec<Row> {
    let mut at: HashMap<Key, (&'static str, DateTime<FixedOffset>)> = HashMap::new();
    let mut rows: Vec<Row> = STEPS
        .iter()
        .map(|s| Row {
            step: s,
            ..Default::default()
        })
        .collect();
    let mut dwell: Vec<Vec<i64>> = vec![vec![]; STEPS.len()];
    let idx = |s: &str| STEPS.iter().position(|x| *x == s).unwrap_or(0);
    let (h1, h24) = (now - Duration::hours(1), now - Duration::hours(24));
    for e in events {
        let Ok(ts) = DateTime::parse_from_rfc3339(&e.ts) else {
            continue;
        };
        for m in moves(e) {
            let was = at.get(&m.key).copied();
            let left = was.map(|(s, _)| s).or(m.from);
            if left.is_some() && left == m.to {
                continue;
            }
            if let Some(s) = left {
                let r = &mut rows[idx(s)];
                r.out_24h += usize::from(ts > h24);
                r.out_1h += usize::from(ts > h1);
                if let Some((_, since)) = was.filter(|_| ts > h24) {
                    dwell[idx(s)].push((ts - since).num_minutes());
                }
            }
            match m.to {
                Some(s) => {
                    let r = &mut rows[idx(s)];
                    r.in_24h += usize::from(ts > h24);
                    r.in_1h += usize::from(ts > h1);
                    at.insert(m.key, (s, ts));
                }
                None => {
                    at.remove(&m.key);
                }
            }
        }
    }
    for (s, since) in at.values() {
        if *s == "done" {
            continue;
        }
        let r = &mut rows[idx(s)];
        r.open += 1;
        let age = (now - *since).num_minutes();
        r.oldest_min = Some(r.oldest_min.map_or(age, |o| o.max(age)));
    }
    for (r, d) in rows.iter_mut().zip(dwell.iter_mut()) {
        d.sort_unstable();
        r.dwell_n = d.len();
        r.dwell_p50_min = pct(d, 50);
        r.dwell_p90_min = pct(d, 90);
    }
    rows
}

fn cell(v: Option<i64>) -> String {
    v.map_or("-".into(), |m| m.to_string())
}

/// `notes log --steps`: one line per step, or one JSON object per step with `--json`.
pub fn print(p: &crate::config::Profile, json: bool) -> anyhow::Result<i32> {
    let events = crate::ingest::all(p);
    let rows = replay(&events, chrono::Local::now().fixed_offset());
    if json {
        for r in &rows {
            println!("{}", serde_json::to_string(r)?);
        }
        return Ok(0);
    }
    println!(
        "{:<8} {:>5} {:>7} {:>6} {:>7} {:>6} {:>5}",
        "step", "open", "oldest", "in24h", "out24h", "p50", "p90"
    );
    for r in &rows {
        println!(
            "{:<8} {:>5} {:>7} {:>6} {:>7} {:>6} {:>5}",
            r.step,
            if r.step == "done" {
                "-".into()
            } else {
                r.open.to_string()
            },
            cell(r.oldest_min),
            r.in_24h,
            r.out_24h,
            cell(r.dwell_p50_min),
            cell(r.dwell_p90_min)
        );
    }
    println!(
        "minutes; open is what the record holds, from {}",
        events
            .first()
            .map_or("-", |e| e.ts.get(..16).unwrap_or(&e.ts))
    );
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(ts: &str, action: &str, from: &str, to: &str, text: &str) -> Event {
        Event {
            ts: format!("2026-11-05T{ts}:00-08:00"),
            action: action.into(),
            from: from.into(),
            to: to.into(),
            text: text.into(),
            ..Default::default()
        }
    }

    fn with(mut e: Event, id: Option<&str>, item: Option<&str>, why: Option<&str>) -> Event {
        e.id = id.map(Into::into);
        e.item = item.map(Into::into);
        e.why = why.map(Into::into);
        e
    }

    fn now() -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339("2026-11-05T20:00:00-08:00").unwrap()
    }

    fn get<'a>(rows: &'a [Row], s: &str) -> &'a Row {
        rows.iter().find(|r| r.step == s).unwrap()
    }

    /// One line from the outbox to a merge, plus a hand-queued item that never had a row.
    #[test]
    fn a_full_chain_hands_one_subject_to_the_next() {
        let events = vec![
            ev("10:00", "added", "outbox", "", "fix the menu #p:ucp"),
            ev("10:05", "moved", "outbox", "ucp", "Fix the  menu"),
            with(
                ev("10:20", "filed", "ucp", "ucp", "fix the menu"),
                Some("ucp-9"),
                None,
                None,
            ),
            with(
                ev("11:20", "item-added", "ucp", "queued", "fix the menu"),
                Some("ucp-9"),
                Some("fix-menu"),
                None,
            ),
            with(
                ev("12:20", "item-moved", "ucp", "running", "fix the menu"),
                Some("ucp-9"),
                Some("fix-menu"),
                Some("queued -> running (ok)"),
            ),
            with(
                ev("13:20", "item-moved", "ucp", "done", "fix the menu"),
                Some("ucp-9"),
                Some("fix-menu"),
                Some("running -> done (ok)"),
            ),
            with(
                ev("19:30", "item-added", "dotfiles", "running", "hand job"),
                None,
                Some("hand"),
                None,
            ),
        ];
        let rows = replay(&events, now());
        let inbox = get(&rows, "inbox");
        assert_eq!((inbox.open, inbox.in_24h, inbox.out_24h), (0, 1, 1));
        assert_eq!(inbox.dwell_p50_min, Some(20));
        assert_eq!(get(&rows, "backlog").dwell_p50_min, Some(60));
        assert_eq!(get(&rows, "queued").dwell_p50_min, Some(60));
        let running = get(&rows, "running");
        assert_eq!(
            (running.open, running.in_24h, running.out_24h, running.in_1h),
            (1, 2, 1, 1)
        );
        assert_eq!(running.oldest_min, Some(30));
        assert_eq!(get(&rows, "done").in_24h, 1);
        assert_eq!(get(&rows, "done").open, 0);
    }

    /// An item the record never saw queued still leaves the step its move names, with no dwell.
    #[test]
    fn a_move_before_the_record_counts_out_without_dwell() {
        let events = vec![with(
            ev("15:00", "item-moved", "x", "done", "t"),
            None,
            Some("old"),
            Some("waiting -> done (ok)"),
        )];
        let rows = replay(&events, now());
        let w = get(&rows, "waiting");
        assert_eq!((w.out_24h, w.dwell_n, w.open), (1, 0, 0));
    }

    #[test]
    fn a_row_closed_without_a_queue_item_leaves_backlog() {
        let events = vec![
            with(
                ev("09:00", "added", "ucp", "", "row"),
                Some("ucp-1"),
                Some("writer"),
                None,
            ),
            with(
                ev("09:30", "done", "ucp", "", "row"),
                Some("ucp-1"),
                Some("writer"),
                None,
            ),
        ];
        let rows = replay(&events, now());
        let b = get(&rows, "backlog");
        assert_eq!((b.open, b.out_24h, b.dwell_p90_min), (0, 1, Some(30)));
        // The writer's own item is not a subject of a row write.
        assert_eq!(
            get(&rows, "queued").in_24h + get(&rows, "running").in_24h,
            0
        );
    }

    #[test]
    fn nearest_rank_percentiles() {
        let v: Vec<i64> = (1..=10).collect();
        assert_eq!((pct(&v, 50), pct(&v, 90)), (Some(5), Some(9)));
        assert_eq!(pct(&[], 50), None);
    }
}
