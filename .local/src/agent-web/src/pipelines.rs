//! Infra's Pipelines view: one row per workflow of each repo, from hub-core's `pipelines` over
//! the builds read the Runs and Tests sections share (`builds::current`) and state.json, the
//! night runners and their timers. The list is filtered and sorted here by `hub_core::table`,
//! so the page only draws; its view keys carry an `l` prefix (`lq`, `ls`, `lsort`, `ldir`; Pools has `p`). An
//! opened row reads `/api/pipelines/detail?repo=&file=`. A state.json write pushes the
//! `pipelines` event and drops the kept read; a ledger append pushes `builds`, which drops the
//! runs this view is built over.

use hub_core::pipelines::{self, Pipeline, Pipelines, Sources};
use hub_core::queue::Item;
use hub_core::session_actions::System;
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::builds;
use crate::cache::{off, ReadCache};

/// The sources change by the hour (a sync, a timer firing), and their read lists systemd's
/// timers, so tabs and keystrokes share one read for this long.
const CACHE_SECS: u64 = 60;
static SOURCES: ReadCache<Sources, CACHE_SECS> = ReadCache::new();

/// The table view, under the section's own key prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub lq: String,
    pub ls: String,
    pub lsort: String,
    pub ldir: String,
}

/// An opened pipeline: its repo (slug or project name) and its file (path or file name).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct DetailQuery {
    pub repo: String,
    pub file: String,
}

#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    red: usize,
    rows: Vec<&'a Pipeline>,
    errors: &'a [String],
    table: Summary,
}

fn render(p: &Pipelines, q: &Query) -> String {
    let view = View::new::<Pipeline>(&q.lq, &q.ls, &q.lsort, &q.ldir);
    let (rows, mut table) = view.summary(&p.rows);
    table.links = hub_core::table::links(&rows);
    let out = Shown {
        at: p.at,
        red: p.red,
        rows,
        errors: &p.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the section can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

async fn sources() -> Result<std::sync::Arc<Sources>, String> {
    SOURCES.get((), off(|| pipelines::sources(&System))).await
}

/// The view `q` asks for.
pub async fn get(q: Query, items: (Vec<Item>, Option<String>)) -> String {
    let read = async {
        let b = builds::current(items).await?;
        let s = sources().await?;
        let mut p = pipelines::pipelines(&s, &b.rows);
        p.errors.extend(b.errors.iter().cloned());
        Ok::<_, String>(p)
    };
    read.await.map_or_else(failed, |p| render(&p, &q))
}

/// The pipeline `q` names, opened; the error is a request that names none.
pub async fn detail(q: DetailQuery, items: (Vec<Item>, Option<String>)) -> Result<String, String> {
    let b = builds::current(items).await?;
    let s = sources().await?;
    let d = pipelines::detail(&s, &b.rows, &q.repo, &q.file)
        .ok_or_else(|| format!("{} has no pipeline {}", q.repo, q.file))?;
    serde_json::to_string(&d).map_err(|e| e.to_string())
}

/// Drop the kept sources, so the page's refetch after a state.json write sees it.
pub async fn forget() {
    SOURCES.clear().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(state: &str, name: &str, trigger: &str) -> Pipeline {
        let mut r = Pipeline::default();
        r.state = state.into();
        r.repo = "Org/app".into();
        r.project = "app".into();
        r.pipeline = name.into();
        r.file = format!(".github/workflows/{name}.yml");
        r.trigger = trigger.into();
        r.last_id = Some(7);
        r
    }

    fn sample() -> Pipelines {
        Pipelines {
            at: 300,
            summary: "2 pipelines in 1 repos, 1 red, 0 held from the night".into(),
            red: 1,
            rows: vec![
                row("red", "tests", "dispatch, cron"),
                row("ok", "lint", "pr"),
            ],
            errors: vec![],
        }
    }

    fn body(q: Query) -> serde_json::Value {
        serde_json::from_str(&render(&sample(), &q)).unwrap()
    }

    #[test]
    fn the_body_is_the_rows_the_view_keeps_with_its_controls_and_links() {
        let v = body(Query::default());
        assert_eq!(v["rows"].as_array().unwrap().len(), 2);
        assert_eq!(v["red"], 1);
        assert_eq!(v["table"]["total"], 2);
        assert_eq!(v["table"]["links"][0]["last"], "#infra/runs/app%2F7");
        assert_eq!(v["table"]["links"][0]["repo"], "#projects/app");
        let v = body(Query {
            lq: "trigger:cron".into(),
            ..Default::default()
        });
        let names: Vec<&str> = v["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["pipeline"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["tests"], "one word of a joined trigger finds it");
        let v = body(Query {
            ls: "ok".into(),
            ..Default::default()
        });
        assert_eq!(v["rows"][0]["pipeline"], "lint");
    }

    #[test]
    fn a_failed_read_still_gives_the_section_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
