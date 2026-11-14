//! `/widget`: the phone's home-screen widget, a page of a few status cards that a web-widget app
//! snapshots. The cards are Home's own (`hub_core::cards`), put in the page as JSON, so the widget
//! makes one request with no cookie. It opens for a signed-in browser or for `?t=` matching the
//! widget key (`auth::widget_token`), and that key opens this page only: never `/api/*`, a write
//! or a keystroke route.

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use hub_core::cards::{self, Card};
use serde::Deserialize;

use crate::{auth, Shared};

#[derive(Deserialize)]
pub struct WidgetQuery {
    /// The widget key.
    t: Option<String>,
    /// The cards to show, by card id, comma separated; `cards::WIDGET` when absent.
    cards: Option<String>,
}

/// A signed-in browser, or a request carrying the current widget key.
fn allowed(s: &crate::AppState, headers: &HeaderMap, t: Option<&str>) -> bool {
    crate::signed_in(s, headers).is_some() || key_opens(t, auth::widget_token().as_deref())
}

/// The key opens the page only when one is set and the request names it exactly.
fn key_opens(t: Option<&str>, key: Option<&str>) -> bool {
    t.zip(key).is_some_and(|(t, key)| auth::matches(t, key))
}

/// The card ids a `cards=` list names, or the default set.
fn names(list: Option<&str>) -> Vec<&str> {
    match list.map(|l| {
        l.split(',')
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .collect::<Vec<_>>()
    }) {
        Some(n) if !n.is_empty() => n,
        _ => cards::WIDGET.to_vec(),
    }
}

pub async fn page(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<WidgetQuery>,
) -> Response {
    if !allowed(&s, &headers, q.t.as_deref()) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let (mut all, home) = tokio::join!(crate::cards::read(&s), crate::home_read(&s));
    let now = hub_core::jobs::now();
    all.extend(home_cards(home, now));
    let shown = cards::pick(all, &names(q.cards.as_deref()));
    let data = serde_json::json!({ "at": now, "cards": shown });
    Html(crate::assets::widget(&data)).into_response()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_opens_the_page_only_when_set_and_named_exactly() {
        assert!(key_opens(Some("k3y"), Some("k3y")));
        // Negative controls: no key file, no key given, a wrong or a prefix key.
        assert!(!key_opens(Some(""), None));
        assert!(!key_opens(None, Some("k3y")));
        assert!(!key_opens(Some("k3"), Some("k3y")));
        assert!(!key_opens(Some("nope"), Some("k3y")));
    }

    #[test]
    fn the_page_carries_the_cards_and_no_string_in_them_closes_its_script() {
        let page = crate::assets::widget(
            &serde_json::json!({ "at": 1, "cards": [{ "title": "</script><b>" }] }),
        );
        assert!(
            page.contains(r#""title":"\u003c/script>\u003cb>""#),
            "{page}"
        );
        assert_eq!(
            page.matches("</script>").count(),
            4,
            "the page's own four, no more"
        );
        assert!(!page.contains("{{"), "every mark filled");
    }

    #[test]
    fn names_reads_the_list_or_falls_back_to_the_default() {
        assert_eq!(names(Some("alerts, needs,,")), ["alerts", "needs"]);
        assert_eq!(names(Some(" , ")), cards::WIDGET);
        assert_eq!(names(None), cards::WIDGET);
    }

    #[test]
    fn a_home_that_could_not_be_read_is_no_data_on_both_cards() {
        let c = home_cards(Err("fleet-sessions: timed out".into()), 0);
        assert!(c
            .iter()
            .all(|c| c.level == hub_core::home::Level::Nodata && c.error.is_some()));
    }
}
