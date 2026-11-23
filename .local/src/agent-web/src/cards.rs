//! `/api/home/cards`: Home's status cards (`hub_core::cards`) in `cards::ORDER`: Needs you and Main
//! red from Home's read, then the grid, one card per tab (and Done today), each from that tab's own
//! kept read, so a card and its tab show the same numbers. The page, the widget and the push all
//! read this one list. It is its own read beside `/api/home` because it runs ten readers, and
//! Home's Needs you table must not wait on them. The Board
//! card maps the board Home itself keeps (`HomeParts`), so the grid adds no `notes board` read.

use axum::extract::State;
use axum::Json;
use hub_core::cards::{self, Card};
use hub_core::projects;
use hub_core::releases::{self, Releases};
use hub_core::session_actions::System;

use crate::cache::{off, ReadCache};
use crate::Shared;

/// release-state's read takes seconds and Home re-reads on every queue event, so the card keeps
/// one for half a minute; the Releases tab reads its own fresh.
static RELEASES: ReadCache<Releases, 30> = ReadCache::new("releases-card");

/// A read as the grid takes it, through any pointer the cache keeps it behind.
fn got<T: ?Sized, P: std::ops::Deref<Target = T>>(r: &Result<P, String>) -> cards::Got<'_, T> {
    Some(r.as_ref().map(|p| &**p).map_err(String::as_str))
}

pub async fn get(State(s): State<Shared>) -> Json<Vec<Card>> {
    Json(read(&s).await)
}

/// Every Home card, in Home's order: Needs you and Main red, then the grid. `/api/home/cards`
/// sends it whole and the widget picks its cards from it.
pub(crate) async fn read(s: &Shared) -> Vec<Card> {
    let (grid, home) = tokio::join!(grid(s), crate::home_read(s));
    let mut all = home_cards(home, hub_core::jobs::now());
    all.extend(grid);
    all
}

/// Needs you and Main red, from Home's read; a Home that could not be read is NO DATA on both.
fn home_cards(home: Result<hub_core::home::Home, String>, now: i64) -> Vec<Card> {
    match home {
        Ok(h) => vec![cards::needs(&h, now), cards::main_red(&h)],
        Err(e) => vec![
            Card::failed("needs", "Needs you", "", e.clone()),
            Card::failed("red", "Main red", "", e),
        ],
    }
}

/// The grid, a card per tab after the two Home cards.
async fn grid(s: &Shared) -> Vec<Card> {
    let (infra, mut queue, verdict, sessions, alerts, costs, schedules, projects, home) = tokio::join!(
        s.infra.infra(),
        s.queue.queue(),
        crate::queue::verdict(),
        s.session_table.read(s),
        s.alerts.read(&s.infra),
        crate::costs::read(),
        s.schedules.read(&s.alerts),
        crate::projects::GATHERED.get((), off(projects::gather)),
        s.home.get((), crate::HomeParts::read),
    );
    let board = match &home {
        Ok(p) => p.board.as_ref().map_err(String::as_str),
        Err(e) => Err(e.as_str()),
    };
    // The Queue card's Flow rows and room parts.
    queue.verdict = Some(verdict);
    let items = queue.items.clone();
    // The day-log read keeps its last parse until the record changes (`phone::merged_today`).
    let (releases, pipeline, merged) = tokio::join!(
        RELEASES.get((), off(move || releases::read(&System, &items))),
        off(hub_core::pipeline::read),
        off(hub_core::phone::merged_today),
    );
    let merged = merged.ok().flatten();
    // A worker that died is a failed read, said on the Queue card, never no bottleneck.
    let pipeline = pipeline.and_then(|r| r);
    cards::grid(&cards::Reads {
        sessions: Some(
            sessions
                .as_ref()
                .map(|r| r.rows.as_slice())
                .map_err(String::as_str),
        ),
        board: Some(board),
        queue: Some(Ok(&queue)),
        merged: merged.as_deref(),
        now: hub_core::jobs::now(),
        pipeline: Some(&pipeline),
        alerts: Some(alerts.as_ref().map_err(String::as_str)),
        infra: Some(Ok(&infra)),
        costs: got(&costs),
        releases: got(&releases),
        schedules: got(&schedules),
        projects: got(&projects),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needs_you_and_main_red_lead_in_homes_order() {
        let mut all = home_cards(Ok(hub_core::home::Home::default()), 0);
        all.extend(cards::grid(&Default::default()));
        let tabs: Vec<_> = all.iter().map(|c| c.tab).collect();
        assert_eq!(
            tabs,
            cards::ORDER,
            "the page and the widget draw every card, Needs you first"
        );
    }

    #[test]
    fn a_home_that_could_not_be_read_is_no_data_on_both_cards() {
        let c = home_cards(Err("fleet-sessions: timed out".into()), 0);
        assert!(c
            .iter()
            .all(|c| c.level == hub_core::home::Level::Nodata && c.error.is_some()));
    }
}
