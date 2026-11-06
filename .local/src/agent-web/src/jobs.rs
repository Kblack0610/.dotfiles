//! The Jobs tab: every job that runs on its own, from hub-core's `jobs`, and one run's log.
//! The list is filtered and sorted here by `hub_core::table`, so the page only draws.

use std::sync::Arc;
use std::time::{Duration, Instant};

use hub_core::jobs::{self, Job, Jobs, LogRef, Opts, Paths, Source};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

/// The default list folds concurrent tabs, quick reloads and every keystroke in the search
/// into one collection; a one-job history (`name=`) is asked for by a click and is always fresh.
const CACHE: Duration = Duration::from_secs(15);
/// The longest history a request may ask for: the journal and the exporter hold about a day,
/// the ledgers longer.
const MAX_WINDOW_SECS: i64 = 7 * 24 * 3600;

/// What to collect (`name`, `window`, `source`) and the table view over it (`q`, `s`,
/// `sort`, `dir`, the same keys the page keeps in its URL).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct JobsQuery {
    pub name: Option<String>,
    pub window: Option<i64>,
    pub source: Option<Source>,
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// The collection with the view applied: the rows it keeps, and the controls that drew them.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    window_secs: i64,
    jobs: Vec<&'a Job>,
    errors: &'a [String],
    table: Summary,
}

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, Arc<Jobs>)>>);

/// Collect what `q` names, off the async workers.
async fn collect(q: &JobsQuery) -> Result<Jobs, String> {
    let mut opts = Opts {
        name: q.name.clone().filter(|n| !n.is_empty()),
        ..Opts::default()
    };
    if let Some(w) = q.window {
        opts.window_secs = w.clamp(60, MAX_WINDOW_SECS);
    }
    if let Some(s) = q.source {
        opts.sources = vec![s];
    }
    tokio::task::spawn_blocking(move || jobs::collect(&Paths::from_env(), &opts))
        .await
        .map_err(|e| e.to_string())
}

fn render(js: &Jobs, q: &JobsQuery) -> String {
    let view = View::new::<Job>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&js.jobs);
    let out = Shown {
        at: js.at,
        window_secs: js.window_secs,
        jobs: rows,
        errors: &js.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when collecting itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "jobs": [], "errors": [e] }).to_string()
}

impl Cache {
    /// The view `q` asks for. The plain collection (no name, window or source) is shared for
    /// `CACHE`, and every view is applied to it outside the lock.
    pub async fn get(&self, q: JobsQuery) -> String {
        let plain = q.name.is_none() && q.window.is_none() && q.source.is_none();
        let js = if plain {
            let mut c = self.0.lock().await;
            match c.as_ref().filter(|(at, _)| at.elapsed() < CACHE) {
                Some((_, js)) => Ok(js.clone()),
                None => collect(&q).await.map(|js| {
                    let js = Arc::new(js);
                    *c = Some((Instant::now(), js.clone()));
                    js
                }),
            }
        } else {
            collect(&q).await.map(Arc::new)
        };
        js.map_or_else(failed, |js| render(&js, &q))
    }
}

/// The log behind a row. `raw` is the row's own `log` object as JSON, which `read_log` checks.
/// The outer error is a reference that does not parse; the inner one, a log that cannot be read.
pub async fn log(raw: String) -> Result<Result<String, String>, String> {
    let r: LogRef = serde_json::from_str(&raw).map_err(|e| format!("bad log reference: {e}"))?;
    tokio::task::spawn_blocking(move || jobs::read_log(&Paths::from_env(), &r))
        .await
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::jobs::State;

    #[test]
    fn the_body_is_the_rows_the_view_keeps_with_its_controls() {
        let mut a = Job::new(Source::Ci, "playground / Tests", State::Done);
        a.ok = Some(false);
        a.started = Some(100);
        let mut b = Job::new(Source::Agentctl, "dream", State::Done);
        b.started = Some(200);
        let js = Jobs {
            at: 300,
            window_secs: 86400,
            jobs: vec![a, b, Job::new(Source::Ci, "platform / e2e", State::Running)],
            errors: vec![],
        };
        let q = JobsQuery {
            q: "source:ci".into(),
            sort: "started".into(),
            dir: "asc".into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&js, &q)).unwrap();
        let names: Vec<&str> = v["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|j| j["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            ["playground / Tests", "platform / e2e"],
            "no start sorts last"
        );
        assert_eq!(v["table"]["total"], 3);
        assert_eq!(v["table"]["dir"], "asc");
        assert_eq!(v["table"]["states"][4]["name"], "failed");
        assert_eq!(v["table"]["states"][4]["n"], 1);
        assert_eq!(v["table"]["facets"][0]["on"], "ci");
    }
}
