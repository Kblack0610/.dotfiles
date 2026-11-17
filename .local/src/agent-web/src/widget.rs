//! `/widget`: the phone's home-screen widget, a page of a few status cards that a web-widget app
//! snapshots. The cards are Home's own (`hub_core::cards`), put in the page as JSON, so the widget
//! makes one request with no cookie. It opens for a signed-in browser or for `?t=` matching the
//! widget key (`auth::widget_token`), and that key opens this page only: never `/api/*`, a write
//! or a keystroke route. Each hit the key opens is kept in `last_hit_file`, since reqlog says
//! nothing of a request that answered in time, and each refusal is logged with its reason, since
//! reqlog says nothing of a 401 either.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
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

/// The key opens the page only when one is set and the request names it exactly.
fn key_opens(t: Option<&str>, key: Option<&str>) -> bool {
    t.zip(key).is_some_and(|(t, key)| auth::matches(t, key))
}

/// Why a request with no session was refused, for the log line the README's troubleshooting
/// row greps.
fn refusal(t: Option<&str>, key: Option<&str>) -> &'static str {
    match (t, key) {
        (None, _) => "no key in the URL",
        (Some(_), None) => "no key set on the server",
        (Some(_), Some(_)) => "key does not match",
    }
}

/// The request's user agent, capped at `UA_MAX` characters.
fn user_agent(headers: &HeaderMap) -> String {
    let ua = headers
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok());
    ua.unwrap_or("-").chars().take(UA_MAX).collect()
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
    // A signed-in browser, or a request carrying the current widget key.
    let key = auth::widget_token();
    let by_key = key_opens(q.t.as_deref(), key.as_deref());
    if !by_key && crate::signed_in(&s, &headers).is_none() {
        // reqlog says nothing of a 401, so a widget app holding an old key would look the same
        // as one that never reaches the server.
        let why = refusal(q.t.as_deref(), key.as_deref());
        eprintln!(
            "agent-web: widget refused: {why}: ua={:?}",
            user_agent(&headers)
        );
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let (mut all, home) = tokio::join!(crate::cards::read(&s), crate::home_read(&s));
    let now = hub_core::jobs::now();
    all.extend(home_cards(home, now));
    let names = names(q.cards.as_deref());
    // A name no card has (a typo in the URL) is said on the widget, never silently one card fewer.
    let missing: Vec<&str> = names
        .iter()
        .copied()
        .filter(|n| !all.iter().any(|c| c.tab == *n))
        .collect();
    let shown = cards::pick(all, &names);
    let data = serde_json::json!({ "at": now, "cards": shown, "missing": missing });
    // Only the key's hits: the widget app holds the key, and a signed-in browser opening the page
    // without it would hide a widget that stopped refreshing.
    if by_key {
        let hit = serde_json::json!({ "at": now, "cards": names, "ua": user_agent(&headers) });
        // Two hits a few seconds apart may land in either order: a skew of seconds against a 2h
        // watch.
        tokio::task::spawn_blocking(move || {
            let f = last_hit_file();
            if let Err(e) = record(&f, &hit) {
                eprintln!("agent-web: widget hit not recorded: {}: {e}", f.display());
            }
        });
    }
    // Asks, titles and costs: kept by no cache, browser history included.
    (
        [(header::CACHE_CONTROL, "no-store, private")],
        Html(crate::assets::widget(&data)),
    )
        .into_response()
}

/// The widget's last hit, read by the Sentinel watch `agent-web-widget-fresh`.
fn last_hit_file() -> PathBuf {
    agent_panel::session::home().join(".local/state/agent-web/widget.json")
}

/// The most of a user agent kept: enough to tell the widget app from curl.
const UA_MAX: usize = 200;

/// Writes the hit whole, through a temp file of its own, so two widgets that refresh at once
/// never leave a torn file.
fn record(f: &Path, hit: &serde_json::Value) -> std::io::Result<()> {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    if let Some(dir) = f.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = f.with_extension(format!("tmp.{}", SEQ.fetch_add(1, Ordering::Relaxed)));
    let wrote = std::fs::write(&tmp, hit.to_string()).and_then(|()| std::fs::rename(&tmp, f));
    if wrote.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    wrote
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
    fn a_refusal_names_which_side_lacks_the_key() {
        // The README's troubleshooting row greps these words.
        assert_eq!(refusal(None, Some("k3y")), "no key in the URL");
        assert_eq!(refusal(None, None), "no key in the URL");
        assert_eq!(refusal(Some("k3y"), None), "no key set on the server");
        assert_eq!(refusal(Some("old"), Some("k3y")), "key does not match");
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
    fn a_hit_makes_its_directory_and_the_next_one_replaces_it_whole() {
        let dir = std::env::temp_dir().join(format!("agent-web-widget-{}", std::process::id()));
        let f = dir.join("state/widget.json");
        let first =
            serde_json::json!({ "at": 10, "cards": ["needs", "red"], "ua": "WebsiteWidget" });
        let next = serde_json::json!({ "at": 20, "cards": ["alerts"], "ua": "-" });
        record(&f, &first).unwrap();
        record(&f, &next).unwrap();
        let hit: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&f).unwrap()).unwrap();
        assert_eq!(hit, next);
        let left = std::fs::read_dir(f.parent().unwrap()).unwrap().count();
        assert_eq!(left, 1, "no temp file left behind");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_hit_file_is_the_path_the_watch_reads() {
        assert!(last_hit_file().ends_with(".local/state/agent-web/widget.json"));
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
