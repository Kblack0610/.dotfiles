//! `/widget.json`: Home's status cards (`hub_core::cards`) as a Tilecast widget document
//! (`hub_core::widget_doc`) for the phone's native widget app. It opens for a signed-in browser or
//! for the widget key (`auth::widget_token`) as `?t=` or a bearer header, and that key opens this
//! document and the push routes only: never `/api/*`, another write or a keystroke route. Each hit
//! the key opens is kept in `last_hit_file` and appended to `hits_file`, since reqlog says nothing
//! of a request that answered in time, and each refusal is logged with its reason, since reqlog
//! says nothing of a 401 either. With an https `AGENT_WEB_BASE_URL` the document names
//! `push::REGISTER`, where the app registers for pushes (`push`), the one write the key opens.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use hub_core::cards::{self, Card};
use hub_core::widget_doc;
use serde::Deserialize;

use crate::{auth, Shared};

#[derive(Deserialize)]
pub struct WidgetQuery {
    /// The widget key.
    pub(crate) t: Option<String>,
    /// The cards to show, by card id, comma separated; absent, every card in Home's order.
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
    // Lossy, so a client sending bytes past ASCII is kept as itself, never as "-".
    let ua = headers
        .get(header::USER_AGENT)
        .map(|v| String::from_utf8_lossy(v.as_bytes()));
    ua.as_deref().unwrap_or("-").chars().take(UA_MAX).collect()
}

/// The client's address as the tunnel gives it: Cloudflare's `CF-Connecting-IP`, else the first
/// `X-Forwarded-For` entry, else "-". A LAN hit through the ingress gets Traefik's service load
/// balancer pod (10.42.x) for every client, and a direct one on the port gets "-". Capped at
/// `IP_MAX`, since both are the client's to write when the request did not come through Cloudflare.
fn client_ip(headers: &HeaderMap) -> String {
    let first = |name: &str| {
        let v = headers.get(name)?.to_str().ok()?.split(',').next()?.trim();
        (!v.is_empty()).then_some(v)
    };
    let ip = first("cf-connecting-ip").or_else(|| first("x-forwarded-for"));
    ip.unwrap_or("-").chars().take(IP_MAX).collect()
}

/// The card ids a `cards=` list names, or None when it names none.
fn listed(list: Option<&str>) -> Option<Vec<&str>> {
    let n: Vec<_> = list?
        .split(',')
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .collect();
    (!n.is_empty()).then_some(n)
}

/// The key as `?t=`, or as `Authorization: Bearer <key>`: the Tilecast app's way, which keeps
/// it out of URLs the tunnel or a proxy may log.
fn given_key<'a>(t: Option<&'a str>, headers: &'a HeaderMap) -> Option<&'a str> {
    t.or_else(|| {
        headers
            .get(header::AUTHORIZATION)?
            .to_str()
            .ok()?
            .strip_prefix("Bearer ")
            .map(str::trim)
    })
}

/// Whether the request opens the widget: Some(true) by the current widget key, Some(false) for a
/// signed-in browser, None when refused, its reason logged.
pub(crate) fn opens(s: &Shared, headers: &HeaderMap, t: Option<&str>) -> Option<bool> {
    let key = auth::widget_token();
    let given = given_key(t, headers);
    if key_opens(given, key.as_deref()) {
        return Some(true);
    }
    if crate::signed_in(s, headers).is_some() {
        return Some(false);
    }
    // reqlog says nothing of a 401, so a widget app holding an old key would look the same as one
    // that never reaches the server.
    let why = refusal(given, key.as_deref());
    eprintln!(
        "agent-web: widget refused: {why}: ua={:?}",
        user_agent(headers)
    );
    None
}

pub(crate) fn refused() -> Response {
    (StatusCode::UNAUTHORIZED, "unauthorized").into_response()
}

/// Every card a widget can name, in Home's order: Needs you and Main red, then the grid.
pub(crate) async fn all_cards(s: &Shared) -> Vec<Card> {
    let (grid, home) = tokio::join!(crate::cards::read(s), crate::home_read(s));
    let mut all = home_cards(home, hub_core::jobs::now());
    all.extend(grid);
    all
}

/// The cards `names` lists, in its order (None: every card, in Home's order), the names no card
/// has, and when they were read.
async fn read<'a>(s: &Shared, names: Option<&[&'a str]>) -> (Vec<Card>, Vec<&'a str>, i64) {
    let all = all_cards(s).await;
    let now = hub_core::jobs::now();
    let Some(names) = names else {
        return (all, Vec::new(), now);
    };
    // A name no card has (a typo in the URL) is said on the widget, never silently one card fewer.
    let missing = names
        .iter()
        .copied()
        .filter(|n| !all.iter().any(|c| c.tab == *n))
        .collect();
    (cards::pick(all, names), missing, now)
}

/// Keeps a key hit in `last_hit_file` and appends it, with the route and the client's address,
/// to `hits_file`, off the request's path. Only the key's hits: the widget app holds the key, and
/// a signed-in browser opening the widget without it would hide one that stopped refreshing. Two
/// hits a few seconds apart may land in either order: a skew of seconds against a 2h watch.
fn keep_hit(headers: &HeaderMap, hit: serde_json::Value) {
    let mut line = hit.clone();
    line["route"] = "/widget.json".into();
    line["ip"] = client_ip(headers).into();
    tokio::task::spawn_blocking(move || {
        let said = |f: PathBuf, wrote: std::io::Result<()>| {
            if let Err(e) = wrote {
                eprintln!("agent-web: widget hit not recorded: {}: {e}", f.display());
            }
        };
        said(last_hit_file(), record(&last_hit_file(), &hit));
        said(hits_file(), append(&hits_file(), &line));
    });
}

/// Asks, titles and costs: kept by no cache, browser history included.
pub(crate) const NO_STORE: (header::HeaderName, &str) =
    (header::CACHE_CONTROL, "no-store, private");

/// `/widget.json`: the cards as a Tilecast widget document. `AGENT_WEB_BASE_URL` makes its taps
/// open the card's tab.
pub async fn doc(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<WidgetQuery>,
) -> Response {
    let Some(by_key) = opens(&s, &headers, q.t.as_deref()) else {
        return refused();
    };
    let (shown, missing, now) = read(&s, listed(q.cards.as_deref()).as_deref()).await;
    let base = std::env::var("AGENT_WEB_BASE_URL").ok();
    let mut d = widget_doc::document(&shown, &missing, now, base.as_deref());
    d.push = base.as_deref().and_then(push_register);
    if by_key {
        let ua = user_agent(&headers);
        let hit = serde_json::json!({
            "at": now,
            "cards": shown.iter().map(|c| c.tab).collect::<Vec<_>>(),
            "client": "tilecast",
            "version": app_version(&ua),
            "ua": ua,
        });
        keep_hit(&headers, hit);
    }
    ([NO_STORE], Json(d)).into_response()
}

/// The register URL under `base`, which the format allows only as https; the app sends its auth
/// there only when it has the document's origin, so `base` must be the address the app fetches.
fn push_register(base: &str) -> Option<widget_doc::Push> {
    base.starts_with("https://").then(|| widget_doc::Push {
        register: format!("{}{}", base.trim_end_matches('/'), crate::push::REGISTER),
    })
}

/// The version in a `Tilecast/<version>` user agent (the format's Fetching section), or None.
fn app_version(ua: &str) -> Option<&str> {
    ua.strip_prefix("Tilecast/")?
        .split_whitespace()
        .next()
        .filter(|v| !v.is_empty())
}

/// The widget's last hit, read by the Sentinel watch `agent-web-widget-fresh`.
fn last_hit_file() -> PathBuf {
    agent_core::session::home().join(".local/state/agent-web/widget.json")
}

/// Every hit the key opened, one JSON line each, read by the Sentinel watch
/// `agent-web-widget-foreign`, which pages on a user agent that is not the widget app's.
fn hits_file() -> PathBuf {
    agent_core::session::home().join(".local/state/agent-web/widget-hits.jsonl")
}

/// The most of a user agent kept: enough to tell the widget app from curl.
const UA_MAX: usize = 200;

/// The most of a client address kept: an IPv6 address is at most 45 characters.
const IP_MAX: usize = 64;

/// Appends the hit as one line in one write, so lines from two hits at once never interleave.
fn append(f: &Path, hit: &serde_json::Value) -> std::io::Result<()> {
    if let Some(dir) = f.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let line = format!("{hit}\n");
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(f)?
        .write_all(line.as_bytes())
}

/// Writes the hit whole, through a temp file of its own, so two widgets that refresh at once
/// never leave a torn file.
pub(crate) fn record(f: &Path, hit: &serde_json::Value) -> std::io::Result<()> {
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
    fn the_key_comes_from_the_url_or_a_bearer_header() {
        let mut h = HeaderMap::new();
        assert_eq!(given_key(None, &h), None);
        h.insert(header::AUTHORIZATION, "Bearer k3y".parse().unwrap());
        assert_eq!(given_key(None, &h), Some("k3y"));
        assert_eq!(given_key(Some("url"), &h), Some("url"));
        // Negative control: another scheme is no key.
        h.insert(header::AUTHORIZATION, "Basic k3y".parse().unwrap());
        assert_eq!(given_key(None, &h), None);
    }

    #[test]
    fn the_app_version_is_read_from_a_tilecast_user_agent_only() {
        assert_eq!(app_version("Tilecast/0.1.0"), Some("0.1.0"));
        assert_eq!(app_version("Tilecast/0.1.0 (Android 15)"), Some("0.1.0"));
        assert_eq!(app_version("Tilecast/"), None);
        assert_eq!(app_version("curl/8.0"), None);
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
    fn the_hit_files_are_the_paths_the_watches_read() {
        assert!(last_hit_file().ends_with(".local/state/agent-web/widget.json"));
        assert!(hits_file().ends_with(".local/state/agent-web/widget-hits.jsonl"));
    }

    #[test]
    fn each_hit_appends_one_line_and_keeps_the_ones_before() {
        let dir = std::env::temp_dir().join(format!("agent-web-hits-{}", std::process::id()));
        let f = dir.join("state/widget-hits.jsonl");
        let first = serde_json::json!({ "at": 10, "ua": "Tilecast/0.1.0", "ip": "203.0.113.7" });
        let next = serde_json::json!({ "at": 20, "ua": "curl/8.0", "ip": "-" });
        append(&f, &first).unwrap();
        append(&f, &next).unwrap();
        let lines: Vec<serde_json::Value> = std::fs::read_to_string(&f)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines, [first, next]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_client_ip_is_cloudflares_then_the_first_forwarded_hop() {
        let mut h = HeaderMap::new();
        assert_eq!(client_ip(&h), "-");
        h.insert(
            "x-forwarded-for",
            " 198.51.100.20 , 192.0.2.1".parse().unwrap(),
        );
        assert_eq!(client_ip(&h), "198.51.100.20");
        h.insert("cf-connecting-ip", "203.0.113.7".parse().unwrap());
        assert_eq!(client_ip(&h), "203.0.113.7");
        // Negative controls: an empty header is no address, and a long one is capped.
        h.insert("cf-connecting-ip", "".parse().unwrap());
        assert_eq!(client_ip(&h), "198.51.100.20");
        h.insert("x-forwarded-for", "".parse().unwrap());
        assert_eq!(client_ip(&h), "-");
        h.insert("x-forwarded-for", "9".repeat(500).parse().unwrap());
        assert_eq!(client_ip(&h).len(), IP_MAX);
    }

    #[test]
    fn a_user_agent_past_ascii_is_kept_not_dropped() {
        let mut h = HeaderMap::new();
        assert_eq!(user_agent(&h), "-");
        let ua = header::HeaderValue::from_bytes(b"Bot\xc3\xa9/1").unwrap();
        h.insert(header::USER_AGENT, ua);
        assert_eq!(user_agent(&h), "Bot\u{e9}/1");
    }

    #[test]
    fn the_document_names_the_register_route_under_an_https_base_only() {
        assert_eq!(
            push_register("https://agents.example.com/")
                .unwrap()
                .register,
            "https://agents.example.com/widget/push-register"
        );
        // Negative control: the format allows push.register only as https.
        assert_eq!(push_register("http://10.0.0.5:8790"), None);
    }

    #[test]
    fn a_cards_list_reads_its_names_and_an_empty_one_reads_every_card() {
        assert_eq!(listed(Some("alerts, needs,,")), Some(vec!["alerts", "needs"]));
        // No default list: None reads every card.
        assert_eq!(listed(Some(" , ")), None);
        assert_eq!(listed(None), None);
        assert_eq!(listed(Some("red")), Some(vec!["red"]));
    }

    #[test]
    fn the_default_order_is_homes_needs_and_red_then_the_grid() {
        let home = home_cards(Err("x".into()), 0);
        let tabs: Vec<_> = home.iter().map(|c| c.tab).collect();
        assert_eq!(tabs, cards::ORDER[..2]);
    }

    #[test]
    fn a_home_that_could_not_be_read_is_no_data_on_both_cards() {
        let c = home_cards(Err("fleet-sessions: timed out".into()), 0);
        assert!(c
            .iter()
            .all(|c| c.level == hub_core::home::Level::Nodata && c.error.is_some()));
    }
}
