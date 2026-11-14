//! Projects' Ladder inner tab: the gate, filer and kinds lines, Projects by stage and the
//! Requirements of stages.md, from `hub_core::stages` (the rows and words the hub TUI draws).
//! Two tables, each with its own key prefix because the project list keeps the plain ones:
//! `/api/stages` is Projects by stage (`lq`, `ls`, `lsort`, `ldir`) with the tab's lines, and
//! `/api/stages/requirements` the Requirements (`rq`, `rs`, `rsort`, `rdir`). Both views narrow
//! one kept read, which the `stages` event (a new stages.json) drops.

use std::sync::Arc;

use axum::extract::Query;
use axum::Json;
use hub_core::stages::{self, Ladder, Paths, Project, Requirement};
use hub_core::table::{links, Summary, View};
use serde::{Deserialize, Serialize};

use crate::cache::{off, ReadCache};

/// A strip click and the two tables' reads share one run of `project-stage-check --requirements`.
const CACHE_SECS: u64 = 10;
static READ: ReadCache<Ladder, CACHE_SECS> = ReadCache::new();

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct LadderQuery {
    lq: String,
    ls: String,
    lsort: String,
    ldir: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct ReqQuery {
    rq: String,
    rs: String,
    rsort: String,
    rdir: String,
}

#[derive(Serialize)]
struct ShownProjects<'a> {
    rows: Vec<&'a Project>,
    says: &'a str,
    gate_says: &'a str,
    gate_level: hub_core::vocab::Level,
    filer_says: &'a str,
    filer_level: hub_core::vocab::Level,
    kinds_says: &'a str,
    kinds_level: hub_core::vocab::Level,
    failing: usize,
    doc: &'static str,
    filer_href: String,
    table: Summary,
}

#[derive(Serialize)]
struct ShownReqs<'a> {
    rows: Vec<&'a Requirement>,
    says: &'a str,
    table: Summary,
}

fn projects(l: &Ladder, q: &LadderQuery) -> serde_json::Value {
    let view = View::new::<Project>(&q.lq, &q.ls, &q.lsort, &q.ldir);
    let (rows, mut table) = view.summary(&l.projects);
    table.links = links(&rows);
    serde_json::to_value(ShownProjects {
        rows,
        says: &l.projects_says,
        gate_says: &l.gate_says,
        gate_level: l.gate_level,
        filer_says: &l.filer_says,
        filer_level: l.filer_level,
        kinds_says: &l.kinds_says,
        kinds_level: l.kinds_level,
        failing: l.failing,
        doc: stages::DOC,
        filer_href: hub_core::links::Link::to(hub_core::links::Kind::Schedule, "project-index")
            .href(),
        table,
    })
    .unwrap_or_default()
}

fn requirements(l: &Ladder, q: &ReqQuery) -> serde_json::Value {
    let view = View::new::<Requirement>(&q.rq, &q.rs, &q.rsort, &q.rdir);
    let (rows, table) = view.summary(&l.requirements);
    serde_json::to_value(ShownReqs {
        rows,
        says: &l.requirements_says,
        table,
    })
    .unwrap_or_default()
}

async fn current() -> Arc<Ladder> {
    let read = READ
        .get((), async {
            off(|| {
                stages::read(
                    &hub_core::session_actions::System,
                    &Paths::from_env(),
                    chrono::Local::now(),
                )
            })
            .await
        })
        .await;
    // `off` fails only when the blocking task panicked; each part's own failure is in its words.
    read.unwrap_or_else(|e| {
        Arc::new(Ladder {
            projects_says: format!("{}: {e}", hub_core::reading::NOT_READ),
            requirements_says: format!("{}: {e}", hub_core::reading::NOT_READ),
            ..Default::default()
        })
    })
}

pub async fn get(Query(q): Query<LadderQuery>) -> Json<serde_json::Value> {
    Json(projects(&*current().await, &q))
}

pub async fn get_requirements(Query(q): Query<ReqQuery>) -> Json<serde_json::Value> {
    Json(requirements(&*current().await, &q))
}

/// Drop the kept read, so the page's refetch after a new stages.json sees it.
pub async fn forget() {
    READ.clear().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ladder() -> Ladder {
        let p = |name: &str, state: &'static str| Project {
            name: name.into(),
            profile: "bnb".into(),
            state,
            ..Default::default()
        };
        Ladder {
            projects: vec![p("busy", "failing"), p("calm", "met")],
            requirements: vec![Requirement {
                stage: "dev".into(),
                says: "test",
                ..Default::default()
            }],
            gate_says: "report only".into(),
            failing: 1,
            ..Default::default()
        }
    }

    #[test]
    fn each_table_narrows_its_own_rows_by_its_own_keys() {
        let uri: axum::http::Uri = "/api/stages?ls=met&rs=human&q=other".parse().unwrap();
        let Query(lq) = Query::<LadderQuery>::try_from_uri(&uri).unwrap();
        let Query(rq) = Query::<ReqQuery>::try_from_uri(&uri).unwrap();
        let got = projects(&ladder(), &lq);
        assert_eq!(got["rows"].as_array().unwrap().len(), 1);
        assert_eq!(got["rows"][0]["name"], "calm");
        assert_eq!(
            (got["table"]["total"].as_u64(), got["failing"].as_u64()),
            (Some(2), Some(1))
        );
        assert_eq!(got["gate_says"], "report only");
        assert_eq!(got["table"]["links"][0]["project"], "#projects/bnb%2Fcalm");
        // NEGATIVE CONTROL: the requirements' `human` chip keeps no `test` row.
        let r = requirements(&ladder(), &rq);
        assert_eq!(r["rows"].as_array().unwrap().len(), 0);
        assert_eq!(r["table"]["total"], 1);
    }
}
