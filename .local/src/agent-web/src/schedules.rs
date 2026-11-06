//! The Schedules tab: everything scheduled and why, from hub-core's `schedules`. The list is
//! filtered and sorted here by `hub_core::table`, so the page only draws.

use std::sync::Arc;
use std::time::{Duration, Instant};

use hub_core::fleet::Paths;
use hub_core::schedules::{self, Schedule, Schedules};
use hub_core::session_actions::System;
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

/// A read takes seconds (unit properties, Prometheus, CI state) and a schedule changes by the
/// hour, so tabs, reloads and each keystroke of a search share one read for this long.
const CACHE: Duration = Duration::from_secs(60);

/// The table view, the same keys the page keeps in its URL.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// The read with the view applied: the rows it keeps, and the controls that drew them.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    summary: &'a str,
    rows: Vec<&'a Schedule>,
    errors: &'a [String],
    table: Summary,
}

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, Arc<Schedules>)>>);

fn render(s: &Schedules, q: &Query) -> String {
    let view = View::new::<Schedule>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&s.rows);
    let out = Shown {
        at: s.at,
        summary: &s.summary,
        rows,
        errors: &s.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

impl Cache {
    /// The view `q` asks for, over the shared read and outside its lock.
    pub async fn get(&self, q: Query) -> String {
        let read = {
            let mut c = self.0.lock().await;
            match c.as_ref().filter(|(at, _)| at.elapsed() < CACHE) {
                Some((_, s)) => Ok(s.clone()),
                None => {
                    let read = tokio::task::spawn_blocking(|| {
                        schedules::read(&Paths::from_env(), &System)
                    });
                    read.await.map_err(|e| e.to_string()).map(|s| {
                        let s = Arc::new(s);
                        *c = Some((Instant::now(), s.clone()));
                        s
                    })
                }
            }
        };
        read.map_or_else(failed, |s| render(&s, &q))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_body_is_the_rows_the_view_keeps_with_its_controls() {
        let blank = Schedule::default();
        let row = |kind: &str, name: &str, streak| {
            let mut r = blank.clone();
            r.kind = kind.into();
            r.name = name.into();
            r.streak = streak;
            r
        };
        let s = Schedules {
            at: 300,
            summary: "2 scheduled, 1 red".into(),
            rows: vec![row("ci", "app / Tests", -3), row("timer", "dream", 9)],
            errors: vec![],
        };
        let q = Query {
            s: "red".into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&s, &q)).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["name"], "app / Tests");
        assert_eq!(v["summary"], "2 scheduled, 1 red");
        assert_eq!(v["table"]["total"], 2);
    }

    #[test]
    fn a_failed_read_still_gives_the_tab_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
