//! `/api/home/cards`: Home's status grid (`hub_core::cards`), one card per tab, each from that
//! tab's own kept read, so a card and its tab show the same numbers. It is its own read beside
//! `/api/home` because it reads eight tabs, and Home's Needs you must not wait on them.

use axum::extract::State;
use axum::Json;
use hub_core::cards::{self, Card};
use hub_core::projects::{self, Projects};
use hub_core::releases;
use hub_core::session_actions::System;

use crate::cache::{off, ReadCache};
use crate::Shared;

/// The Projects tab reads its list fresh on each open; the card keeps one for a minute, the
/// cadence Home re-reads at, so the grid does not run its CLIs on every repaint.
static PROJECTS: ReadCache<Projects, 60> = ReadCache::new();

/// A read as the grid takes it, through any pointer the cache keeps it behind.
fn got<T: ?Sized, P: std::ops::Deref<Target = T>>(r: &Result<P, String>) -> cards::Got<'_, T> {
    Some(r.as_ref().map(|p| &**p).map_err(String::as_str))
}

pub async fn get(State(s): State<Shared>) -> Json<Vec<Card>> {
    let (infra, queue, sessions, alerts, costs, schedules, projects) = tokio::join!(
        s.infra.infra(),
        s.queue.queue(),
        s.session_table.read(),
        s.alerts.read(&s.infra),
        crate::costs::read(),
        s.schedules.read(),
        PROJECTS.get((), off(projects::gather)),
    );
    let items = queue.items.clone();
    let (releases, pipeline) = tokio::join!(
        off(move || releases::read(&System, &items)),
        off(hub_core::pipeline::read),
    );
    let pipeline = pipeline.ok();
    Json(cards::grid(&cards::Reads {
        sessions: Some(
            sessions
                .as_ref()
                .map(|r| r.rows.as_slice())
                .map_err(String::as_str),
        ),
        queue: Some(Ok(&queue)),
        pipeline: pipeline.as_ref(),
        alerts: Some(alerts.as_ref().map_err(String::as_str)),
        infra: Some(Ok(&infra)),
        costs: got(&costs),
        releases: Some(releases.as_ref().map_err(String::as_str)),
        schedules: got(&schedules),
        projects: got(&projects),
    }))
}
