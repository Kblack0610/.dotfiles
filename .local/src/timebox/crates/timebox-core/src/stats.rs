//! Minimal Phase-1 stats: per-operation active seconds *today*, folded from the event
//! log. Any richer stat (lap drift, weekly trends, per-op histograms) is a different
//! fold over the same log with no migration — that's the whole point of logging events.

use crate::event::{Event, EventKind};
use chrono::{DateTime, Duration, Local, Timelike};
use std::collections::BTreeMap;

/// Sum active (running) seconds per stopwatch that fall within today's window
/// `[midnight, now]`. Intervals are reconstructed by pairing start/resume with
/// stop/pause/reset; an interval still open at the end is closed at `now` (live tail).
/// Intervals are clamped to the today window, so a session spanning midnight is
/// counted only for its portion after midnight.
pub fn today_totals(events: &[Event], now: DateTime<Local>) -> BTreeMap<String, i64> {
    let midnight = now - Duration::seconds(i64::from(now.num_seconds_from_midnight()));

    // Sort a copy by timestamp so out-of-order appends (rare) don't corrupt the fold.
    let mut evs: Vec<&Event> = events.iter().collect();
    evs.sort_by_key(|e| e.ts);

    let mut running_since: BTreeMap<String, DateTime<Local>> = BTreeMap::new();
    let mut totals: BTreeMap<String, i64> = BTreeMap::new();

    let add = |totals: &mut BTreeMap<String, i64>, sw: &str, a: DateTime<Local>, b: DateTime<Local>| {
        let lo = a.max(midnight);
        let hi = b.min(now);
        if hi > lo {
            *totals.entry(sw.to_string()).or_insert(0) += (hi - lo).num_seconds();
        }
    };

    for e in evs {
        match e.kind {
            EventKind::Start | EventKind::Resume => {
                running_since.insert(e.sw.clone(), e.ts);
            }
            EventKind::Stop | EventKind::Pause | EventKind::Reset => {
                if let Some(since) = running_since.remove(&e.sw) {
                    add(&mut totals, &e.sw, since, e.ts);
                }
            }
            _ => {}
        }
    }
    // Close any still-running interval at `now`.
    for (sw, since) in running_since {
        add(&mut totals, &sw, since, now);
    }
    totals
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(kind: EventKind, sw: &str, ts: DateTime<Local>) -> Event {
        Event::new(ts, kind, sw)
    }
    fn base() -> DateTime<Local> {
        // A fixed mid-day instant so the whole session lands inside "today".
        DateTime::parse_from_rfc3339("2026-07-10T12:00:00-07:00")
            .unwrap()
            .with_timezone(&Local)
    }
    fn at(b: DateTime<Local>, s: i64) -> DateTime<Local> {
        b + Duration::seconds(s)
    }

    #[test]
    fn sums_a_completed_interval() {
        let b = base();
        let evs = vec![
            ev(EventKind::Start, "deep-work", at(b, 0)),
            ev(EventKind::Stop, "deep-work", at(b, 120)),
        ];
        let totals = today_totals(&evs, at(b, 200));
        assert_eq!(totals["deep-work"], 120);
    }

    #[test]
    fn counts_open_interval_up_to_now() {
        let b = base();
        let evs = vec![ev(EventKind::Start, "email", at(b, 0))];
        let totals = today_totals(&evs, at(b, 45));
        assert_eq!(totals["email"], 45);
    }

    #[test]
    fn pause_resume_only_counts_active() {
        let b = base();
        let evs = vec![
            ev(EventKind::Start, "op", at(b, 0)),
            ev(EventKind::Pause, "op", at(b, 100)),
            ev(EventKind::Resume, "op", at(b, 1000)),
            ev(EventKind::Stop, "op", at(b, 1050)),
        ];
        let totals = today_totals(&evs, at(b, 2000));
        assert_eq!(totals["op"], 150); // 100 + 50, not the 900 paused
    }
}
