//! The page, its static assets, and the headers every response carries.
//!
//! Everything is embedded at build time. The page links each asset as `/static/<name>?v=<version>`,
//! where the version is a hash of every asset, so a browser keeps them for a year
//! (`immutable`) and a new build is a new URL: one changed file never serves stale beside fresh.
//! The page itself is `no-cache`, so it always names the current version.

use std::sync::OnceLock;

use axum::body::Bytes;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

const INDEX: &str = include_str!("index.html");
pub const LOGIN: &str = include_str!("login.html");
/// Where the page and every CSS file name the asset version: web-kit's tokens.css versions the
/// fonts with it (`css_names_the_fonts_at_the_current_version`).
const VERSION_MARK: &str = "{{v}}";
/// Where the page takes its tab list.
const NAV_MARK: &str = "{{nav}}";

const JS: &str = "text/javascript; charset=utf-8";
const CSS: &str = "text/css; charset=utf-8";
const WOFF2: &str = "font/woff2";

/// `(name, content type, body)`. tokens.css, shell.css, kb-shell.js and the fonts are web-kit's
/// (`../../web-kit`, shared with every kblab site), served flat beside agent-web's own.
/// ui.js is the shared helpers, md.js the markdown renderer,
/// app.js the open session and the event stream, sessions.js the Sessions table, waiting.js the answer cards, home.js the Home tab;
/// each other script is one board tab.
const FILES: &[(&str, &str, &[u8])] = &[
    (
        "tokens.css",
        CSS,
        include_bytes!("../../web-kit/tokens.css"),
    ),
    ("shell.css", CSS, include_bytes!("../../web-kit/shell.css")),
    (
        "kb-shell.js",
        JS,
        include_bytes!("../../web-kit/kb-shell.js"),
    ),
    ("app.css", CSS, include_bytes!("../static/app.css")),
    ("ui.js", JS, include_bytes!("../static/ui.js")),
    ("md.js", JS, include_bytes!("../static/md.js")),
    ("charts.js", JS, include_bytes!("../static/charts.js")),
    ("convo.js", JS, include_bytes!("../static/convo.js")),
    ("app.js", JS, include_bytes!("../static/app.js")),
    ("waiting.js", JS, include_bytes!("../static/waiting.js")),
    ("home.js", JS, include_bytes!("../static/home.js")),
    ("outbox.js", JS, include_bytes!("../static/outbox.js")),
    ("watch.js", JS, include_bytes!("../static/watch.js")),
    ("log.js", JS, include_bytes!("../static/log.js")),
    ("infra.js", JS, include_bytes!("../static/infra.js")),
    ("table.js", JS, include_bytes!("../static/table.js")),
    ("flow.js", JS, include_bytes!("../static/flow.js")),
    ("jobs.js", JS, include_bytes!("../static/jobs.js")),
    ("ci.js", JS, include_bytes!("../static/ci.js")),
    ("schedules.js", JS, include_bytes!("../static/schedules.js")),
    ("alerts.js", JS, include_bytes!("../static/alerts.js")),
    ("releases.js", JS, include_bytes!("../static/releases.js")),
    ("nav.js", JS, include_bytes!("../static/nav.js")),
    ("costs.js", JS, include_bytes!("../static/costs.js")),
    ("sessions.js", JS, include_bytes!("../static/sessions.js")),
    ("queue.js", JS, include_bytes!("../static/queue.js")),
    ("board.js", JS, include_bytes!("../static/board.js")),
    ("projects.js", JS, include_bytes!("../static/projects.js")),
    ("shepherd.js", JS, include_bytes!("../static/shepherd.js")),
    ("work.js", JS, include_bytes!("../static/work.js")),
    ("actions.js", JS, include_bytes!("../static/actions.js")),
    ("fleet.js", JS, include_bytes!("../static/fleet.js")),
    ("focus.js", JS, include_bytes!("../static/focus.js")),
    (
        "inter.woff2",
        WOFF2,
        include_bytes!("../../web-kit/inter.woff2"),
    ),
    (
        "jetbrains-mono.woff2",
        WOFF2,
        include_bytes!("../../web-kit/jetbrains-mono.woff2"),
    ),
];

/// A year: the longest lifetime caches honour. The URL changes whenever the bytes do.
const IMMUTABLE: &str = "private, max-age=31536000, immutable";
/// Store it, but ask the server before every use.
const REVALIDATE: &str = "no-cache";
/// Inline `style="..."` attributes carry per-element colours (`--c`), so styles allow inline;
/// scripts do not, and nothing loads from anywhere but this origin.
const CSP: &str = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
    img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; \
    form-action 'self'; frame-ancestors 'none'";

struct Built {
    version: String,
    index: String,
    files: Vec<(&'static str, &'static str, Bytes)>,
}

fn built() -> &'static Built {
    static BUILT: OnceLock<Built> = OnceLock::new();
    BUILT.get_or_init(|| {
        let page = INDEX.replace(NAV_MARK, &nav_html());
        let mut h = fnv(FNV_OFFSET, page.as_bytes());
        for (name, _, body) in FILES {
            h = fnv(fnv(h, name.as_bytes()), body);
        }
        let version = format!("{:012x}", h & 0xffff_ffff_ffff);
        let files = FILES
            .iter()
            .map(|&(name, ctype, body)| {
                let body = if ctype == CSS {
                    let css = String::from_utf8_lossy(body).replace(VERSION_MARK, &version);
                    Bytes::from(css)
                } else {
                    Bytes::from_static(body)
                };
                (name, ctype, body)
            })
            .collect();
        Built {
            index: page.replace(VERSION_MARK, &version),
            version,
            files,
        }
    })
}

/// The sidebar's tabs under their group headings, from `hub_core::layout`. Three tabs carry a
/// count that their own script fills in.
fn nav_html() -> String {
    let mut html = String::new();
    let mut group = "";
    for t in &hub_core::layout::TABS {
        if t.group != group {
            group = t.group;
            html += &format!("<div class=\"kb-group\">{group}</div>\n");
        }
        let badge = match t.id {
            "home" => "<span id=\"ask-badge\"></span>",
            "queue" => "<span id=\"queue-badge\"></span>",
            "sessions" => "<span id=\"wait-badge\"></span>",
            _ => "",
        };
        html += &format!("<button id=\"tab-{}\">{}{badge}</button>\n", t.id, t.title);
    }
    html
}

/// FNV-1a, 64-bit: stable across builds and Rust versions, unlike `DefaultHasher`, so the
/// same bytes always give the same URL and a rebuild alone never empties browser caches.
const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn fnv(h: u64, bytes: &[u8]) -> u64 {
    bytes
        .iter()
        .fold(h, |h, &b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3))
}

/// The app page, with the current asset version in its links.
pub fn index() -> &'static str {
    &built().index
}

/// One asset. Only a request naming the current version may be cached for good; any other
/// (an old page, a hand-typed URL) is revalidated, so it never pins a stale copy.
pub fn file(name: &str, v: Option<&str>) -> Response {
    let b = built();
    let Some((_, ctype, body)) = b.files.iter().find(|(n, _, _)| *n == name) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let cache = if v == Some(b.version.as_str()) {
        IMMUTABLE
    } else {
        REVALIDATE
    };
    (
        [
            (header::CONTENT_TYPE, *ctype),
            (header::CACHE_CONTROL, cache),
        ],
        body.clone(),
    )
        .into_response()
}

/// Headers for every response: no MIME sniffing, no full URL leaked to another origin, and on
/// a page the CSP, plus `no-cache` so it always names the current assets.
pub async fn headers(mut res: Response) -> Response {
    let h = res.headers_mut();
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    let html = h
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("text/html"));
    if html {
        h.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(CSP),
        );
        h.entry(header::CACHE_CONTROL)
            .or_insert(HeaderValue::from_static(REVALIDATE));
    }
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The phone render harness (tests/agent-web/phone/render.mjs) serves exactly this page and CSP.
    #[test]
    #[ignore = "writes files; run by the phone render harness"]
    fn dump_index_for_phone_harness() {
        let out =
            std::env::var("AGENT_WEB_INDEX_OUT").expect("AGENT_WEB_INDEX_OUT is the output path");
        std::fs::write(&out, index()).unwrap();
        std::fs::write(format!("{out}.csp"), CSP).unwrap();
        let roles = serde_json::to_string(&hub_core::table::phone_tables()).unwrap();
        std::fs::write(format!("{out}.roles"), roles).unwrap();
    }

    const APP_JS: &str = include_str!("../static/app.js");
    const FLEET_JS: &str = include_str!("../static/fleet.js");
    const WAITING_JS: &str = include_str!("../static/waiting.js");

    /// The quoted names in the `[...]` or `{...}` after `const <name> = ` in `js`.
    fn js_list(js: &str, name: &str) -> Vec<String> {
        let at = js
            .find(&format!("const {name} = "))
            .unwrap_or_else(|| panic!("no {name}"));
        let rest = &js[at..];
        let body = &rest[..rest.find(';').unwrap()];
        body.split('"')
            .skip(1)
            .step_by(2)
            .map(String::from)
            .collect()
    }

    /// The keys of a `const <name> = { key: [...], ... };` column map.
    fn col_keys<'a>(js: &'a str, name: &str) -> Vec<&'a str> {
        let at = js.find(name).expect("no column map");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        body.split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect()
    }

    #[test]
    fn the_web_tables_headers_are_hub_cores_columns() {
        // Rule 8: the web draws the columns hub_core::table sorts and filters, every one of them.
        use hub_core::table::Row;
        let jobs = include_str!("../static/jobs.js");
        assert_eq!(
            col_keys(jobs, "const JOB_COLS = {"),
            hub_core::jobs::Job::COLUMNS
        );
        let actions = include_str!("../static/actions.js");
        assert_eq!(
            col_keys(actions, "const ACTION_COLS = {"),
            hub_core::actions::Action::COLUMNS
        );
        assert_eq!(
            col_keys(include_str!("../static/work.js"), "const WORK_COLS = {"),
            hub_core::worklog::Work::COLUMNS
        );
    }

    #[test]
    fn the_schedules_headers_are_hub_cores_columns() {
        // Rule 8, less `result` and `repo`: the state and the name say them, and they still sort
        // and filter.
        use hub_core::table::Row;
        let js = include_str!("../static/schedules.js");
        let at = js.find("const SCHED_COLS = {").expect("no SCHED_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        let all = hub_core::schedules::Schedule::COLUMNS;
        assert_eq!(keys, all[..all.len() - 2]);
        assert_eq!(all[all.len() - 2..], ["result", "repo"]);
    }

    #[test]
    fn the_candidates_headers_are_hub_cores_columns() {
        // qCandRow writes its cells in this order, so the map must be COLUMNS, in order.
        use hub_core::table::Row;
        assert_eq!(
            col_keys(include_str!("../static/queue.js"), "const CAND_COLS = {"),
            hub_core::queue::Candidate::COLUMNS
        );
    }

    #[test]
    fn the_releases_headers_are_hub_cores_columns() {
        // Rule 8, less `channel` and `id`: they only filter, an opened app lists its channels.
        use hub_core::table::Row;
        let js = include_str!("../static/releases.js");
        let at = js.find("const REL_COLS = {").expect("no REL_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        let all = hub_core::releases::App::COLUMNS;
        assert_eq!(keys, all[..all.len() - 2]);
        assert_eq!(all[all.len() - 2..], ["channel", "id"]);
    }

    #[test]
    fn the_builds_headers_are_hub_cores_columns() {
        // Rule 8: the CI run tables draw the first columns hub_core::builds sorts and filters;
        // `forge` and `event` are dropdowns, `title` the open row's heading, and `id` and `pr`
        // only a query's (a run's record `id:=`, a PR's runs `pr:=`).
        use hub_core::table::Row;
        let js = include_str!("../static/ci.js");
        let at = js.find("const BLD_COLS = {").expect("no BLD_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        let all = hub_core::builds::Run::COLUMNS;
        assert_eq!(keys, all[..all.len() - 5]);
        assert_eq!(
            all[all.len() - 5..],
            ["forge", "event", "title", "id", "pr"]
        );
    }

    #[test]
    fn the_fleet_headers_are_hub_cores_columns() {
        // Rule 8: the Fleet table draws the columns hub_core::fleet::who sorts and filters.
        use hub_core::table::Row;
        let at = FLEET_JS
            .find("const FLEET_COLS = {")
            .expect("no FLEET_COLS");
        let body = &FLEET_JS[at..at + FLEET_JS[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        assert_eq!(keys, hub_core::fleet::who::Who::COLUMNS);
    }

    #[test]
    fn the_project_headers_are_hub_cores_columns() {
        // Rule 8, as above; `"7d"` is a quoted key, so quotes come off each key here.
        use hub_core::table::Row;
        let js = include_str!("../static/projects.js");
        let at = js.find("const P_COLS = {").expect("no P_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim().trim_matches('"')))
            .filter(|k| !k.is_empty())
            .collect();
        assert_eq!(keys, hub_core::projects::Card::COLUMNS);
    }

    #[test]
    fn the_session_headers_are_hub_cores_columns() {
        // Rule 8, as above; `item`, `source` and `session` are search keys with no column here.
        use hub_core::table::Row;
        let js = include_str!("../static/sessions.js");
        let at = js.find("const SESSION_COLS = {").expect("no SESSION_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        let columns = hub_core::session_table::SessionRow::COLUMNS;
        assert_eq!(keys, columns[..columns.len() - 3]);
    }

    #[test]
    fn the_queue_tab_draws_the_line_and_a_click_picks_a_step() {
        let flow = include_str!("../static/flow.js");
        let queue = include_str!("../static/queue.js");
        assert!(flow.contains("function railHtml(") && flow.contains("data-rail="));
        assert!(queue.contains("railHtml(qfl.data.line") && queue.contains("[data-rail]"));
        assert!(
            !queue.contains("qfl.data.flow"),
            "/api/flow carries the line now"
        );
    }

    #[test]
    fn need_kinds_are_the_readers() {
        // docs/dashboards.md rule 8: hub_core::home names a row's kind; the page only labels it.
        for k in hub_core::home::NeedKind::ALL {
            let line = format!("  {}: \"{}\",", k.slug(), k.label());
            assert!(WAITING_JS.contains(&line), "{line} is not in waiting.js");
        }
    }

    #[test]
    fn the_nav_is_the_layout() {
        // docs/dashboards.md rule 8: every tab, in the layout's order, under its own heading.
        let page = index();
        assert!(!page.contains(NAV_MARK), "the nav mark was not filled");
        let mut at = 0;
        let mut group = "";
        for t in &hub_core::layout::TABS {
            if t.group != group {
                group = t.group;
                let head = format!(">{group}</div>");
                at += page[at..]
                    .find(&head)
                    .unwrap_or_else(|| panic!("{head} missing or out of order"));
            }
            let id = format!("id=\"tab-{}\"", t.id);
            at += page[at..]
                .find(&id)
                .unwrap_or_else(|| panic!("{id} missing or out of order"));
        }
    }

    #[test]
    fn tab_names_are_the_layout() {
        // docs/dashboards.md rule 8: both surfaces list hub_core::layout's tabs, in its order.
        let names = js_list(APP_JS, "TAB_NAMES");
        let layout: Vec<&str> = hub_core::layout::TABS.iter().map(|t| t.id).collect();
        assert_eq!(names, layout);
        // A retired name the TUI also knows is never a live web tab, and lands where hub-core says.
        let retired = js_list(APP_JS, "RETIRED_TABS");
        for pair in retired.chunks(2) {
            let (old, new) = (&pair[0], &pair[1]);
            assert!(!names.contains(old), "{old} is retired and live");
            assert_eq!(
                hub_core::layout::resolve(old).map(|t| t.id),
                Some(new.as_str()),
                "{old}"
            );
        }
        let ui = include_str!("../static/ui.js");
        let rows = format!("const LOG_ROWS = {};", hub_core::layout::FOLD_ROWS);
        assert!(ui.contains(&rows), "ui.js lacks {rows}");
        for (old, new) in hub_core::layout::RETIRED {
            // overview and forecast were only ever TUI tabs; the web never had them.
            if !["overview", "forecast"].contains(old) {
                assert!(
                    retired.chunks(2).any(|p| p[0] == *old && p[1] == *new),
                    "{old} missing"
                );
            }
        }
    }

    #[test]
    fn entity_pages_are_the_links() {
        // Rule 8 for record pages: app.js's ENTITY_PAGES is hub_core::links::PAGES (and the old
        // words it still reads), so the router keeps the id of every page Link::href draws inside
        // an inner tab, and of a saved link to one.
        let mut want = serde_json::Map::new();
        for p in hub_core::links::PAGES
            .iter()
            .chain(hub_core::links::RETIRED_PAGES)
        {
            let tab = want.entry(p.tab).or_insert_with(|| serde_json::json!({}));
            tab[p.word] = p.inner.into();
        }
        let line = APP_JS
            .lines()
            .find_map(|l| l.strip_prefix("const ENTITY_PAGES = "))
            .expect("app.js has ENTITY_PAGES");
        let got: serde_json::Value =
            serde_json::from_str(line.trim_end_matches(';')).expect("ENTITY_PAGES is JSON");
        assert_eq!(got, serde_json::Value::Object(want));
    }

    #[test]
    fn moved_chips_are_the_layout() {
        // app.js's MOVED carries each layout::MOVED_CHIPS entry as the view it opens with, under
        // the table's prefix (infra::TABLES), so a renamed chip or prefix fails here.
        for (tab, old, table, chip) in hub_core::layout::MOVED_CHIPS {
            let to = hub_core::layout::MOVED
                .iter()
                .find(|m| m.0 == *tab && m.1 == *old)
                .expect("a moved chip is a moved section");
            let pre = crate::infra::TABLES
                .iter()
                .find(|t| t.0 == *table)
                .expect("the chip's table is on the page")
                .1;
            let want = format!(
                r#""{tab}/{old}": ["{}", "{}", "{pre}s={chip}"]"#,
                to.2, to.3
            );
            assert!(APP_JS.contains(&want), "app.js MOVED lacks {want}");
        }
    }

    #[test]
    fn project_page_is_the_layout() {
        // Rule 8 for an opened project: app.js's PROJECT_PAGE is hub_core::layout::PROJECT_PAGE.
        let want: Vec<serde_json::Value> = hub_core::layout::PROJECT_PAGE
            .iter()
            .map(|i| serde_json::json!([i.id, i.title, i.sections]))
            .collect();
        let line = APP_JS
            .lines()
            .find_map(|l| l.strip_prefix("const PROJECT_PAGE = "))
            .expect("app.js has PROJECT_PAGE");
        let got: serde_json::Value =
            serde_json::from_str(line.trim_end_matches(';')).expect("PROJECT_PAGE is JSON");
        assert_eq!(got, serde_json::Value::Array(want));
        // Every section a group names is an anchor projects.js draws.
        let js = include_str!("../static/projects.js");
        for i in hub_core::layout::PROJECT_PAGE {
            for s in i.sections {
                assert!(
                    js.contains(&format!("\"{s}\"")),
                    "projects.js never names {s}"
                );
            }
        }
    }

    #[test]
    fn inner_tabs_are_the_layout() {
        // Rule 8 for inner tabs: app.js's INNER_TABS is hub_core::layout's groups, as JSON.
        let mut want = serde_json::Map::new();
        for t in hub_core::layout::TABS
            .iter()
            .filter(|t| !t.inner.is_empty())
        {
            let tabs: Vec<serde_json::Value> = t
                .inner
                .iter()
                .map(|i| serde_json::json!([i.id, i.title, i.sections]))
                .collect();
            want.insert(t.id.to_string(), serde_json::json!({ "tabs": tabs }));
        }
        let line = APP_JS
            .lines()
            .find_map(|l| l.strip_prefix("const INNER_TABS = "))
            .expect("app.js has INNER_TABS");
        let got: serde_json::Value =
            serde_json::from_str(line.trim_end_matches(';')).expect("INNER_TABS is JSON");
        assert_eq!(got, serde_json::Value::Object(want));
        // Every section a group names is one the page wraps in its inner tab's group, so a
        // section never shows under every inner tab or under none. Releases is checked per
        // inner tab below: its table and detail share one group.
        let pages = [
            ("alerts", include_str!("../static/alerts.js").to_string()),
            ("costs", include_str!("../static/costs.js").to_string()),
            ("infra", include_str!("../static/infra.js").to_string()),
            (
                "projects",
                include_str!("../static/projects.js").to_string(),
            ),
        ];
        for t in hub_core::layout::TABS
            .iter()
            .filter(|t| !t.inner.is_empty() && !["releases", "log"].contains(&t.id))
        {
            let (_, js) = pages
                .iter()
                .find(|p| p.0 == t.id)
                .unwrap_or_else(|| panic!("{} has inner tabs but no page here", t.id));
            for s in t.inner.iter().flat_map(|i| i.sections) {
                let at = format!("(\"{}\", \"{s}\"", t.id);
                assert!(
                    js.contains(&format!("innerWrap{at}"))
                        || js.contains(&format!("innerHide{at}")),
                    "{}'s page never puts {s} in its inner tab",
                    t.id
                );
            }
        }
        // Log's sections are index.html's `sec-` anchors, which log.js puts in their inner tab's
        // group by id; one log.js draws (the day's history) it wraps where it draws it. The
        // forecast is the TUI's alone, as `log_folds_are_the_layout` says.
        let log_js = include_str!("../static/log.js");
        assert!(
            log_js.contains(r#"innerHide("log", el.id.slice(4), el)"#),
            "log.js never puts Log's sections in their inner tabs"
        );
        let index = include_str!("index.html");
        for s in hub_core::layout::resolve("log").expect("log").sections {
            let id = format!("id=\"sec-{s}\"");
            let drawn = log_js.contains(&format!("innerWrap(\"log\", \"{s}\", `<div {id}"));
            assert!(
                *s == "forecast" || index.contains(&id) || drawn,
                "Log's {s} has no {id} in its inner tab's group"
            );
        }
        // Every Releases inner tab has a group on the page: releases.js wraps one of its sections.
        let releases = include_str!("../static/releases.js");
        for i in hub_core::layout::resolve("releases")
            .expect("releases")
            .inner
        {
            assert!(
                i.sections
                    .iter()
                    .any(|s| releases.contains(&format!("innerWrap(\"releases\", \"{s}\""))),
                "releases.js never draws the {} inner tab",
                i.id
            );
        }
    }

    #[test]
    fn log_folds_are_the_layout() {
        // Rule 8 for sections: each folded Log section in hub_core::layout is a `sec-<name>`
        // fold in index.html, in its order. The day and its history are the day view
        // (log.js); the forecast's burn-up and baseline are the TUI's alone so far.
        let html = include_str!("index.html");
        let log = hub_core::layout::resolve("log").expect("log is a tab");
        let mut at = 0;
        for s in log.sections {
            if ["day", "history", "forecast"].contains(s) {
                continue;
            }
            let id = format!("id=\"sec-{s}\"");
            let i = html
                .find(&id)
                .unwrap_or_else(|| panic!("index.html lacks {id}"));
            assert!(i > at, "{id} is out of layout order");
            at = i;
        }
    }

    fn header_of(res: &Response, name: header::HeaderName) -> String {
        res.headers()
            .get(name)
            .map(|v| v.to_str().unwrap().to_string())
            .unwrap_or_default()
    }

    #[test]
    fn every_page_link_is_served_at_the_current_version() {
        let b = built();
        assert!(!b.index.contains(VERSION_MARK));
        for part in b.index.split("/static/").skip(1) {
            let (name, rest) = part.split_once('?').expect("a versioned link");
            assert!(
                rest.starts_with(&format!("v={}\"", b.version)),
                "{name} is not linked at the current version"
            );
            assert!(
                b.files.iter().any(|(n, _, _)| *n == name),
                "{name} is linked but not served"
            );
        }
        // Every script and the stylesheet; a file nothing links is dead weight.
        for (name, ctype, _) in &b.files {
            if *ctype != WOFF2 {
                assert!(
                    b.index.contains(&format!("/static/{name}?")),
                    "{name} is served but the page never loads it"
                );
            }
        }
    }

    #[test]
    fn css_names_the_fonts_at_the_current_version() {
        // web-kit's tokens.css names the fonts relative to itself, so they resolve under /static/.
        let b = built();
        let css = b.files.iter().find(|(n, _, _)| *n == "tokens.css").unwrap();
        let css = std::str::from_utf8(&css.2).unwrap();
        assert!(!css.contains(VERSION_MARK));
        assert!(css.contains(&format!("url(inter.woff2?v={})", b.version)));
        assert!(css.contains(&format!("url(jetbrains-mono.woff2?v={})", b.version)));
    }

    #[test]
    fn only_the_current_version_is_cached_for_good() {
        let v = built().version.clone();
        assert_eq!(
            header_of(&file("app.js", Some(&v)), header::CACHE_CONTROL),
            IMMUTABLE
        );
        assert_eq!(
            header_of(&file("app.js", Some("0")), header::CACHE_CONTROL),
            REVALIDATE
        );
        assert_eq!(
            header_of(&file("app.js", None), header::CACHE_CONTROL),
            REVALIDATE
        );
        assert_eq!(
            header_of(&file("inter.woff2", None), header::CONTENT_TYPE),
            WOFF2
        );
        assert_eq!(file("../main.rs", None).status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn pages_get_the_csp_and_everything_gets_nosniff() {
        let page = headers(axum::response::Html("x").into_response()).await;
        assert_eq!(header_of(&page, header::CONTENT_SECURITY_POLICY), CSP);
        assert_eq!(header_of(&page, header::CACHE_CONTROL), REVALIDATE);
        assert_eq!(header_of(&page, header::X_CONTENT_TYPE_OPTIONS), "nosniff");

        let js = headers(file("ui.js", Some(&built().version))).await;
        assert_eq!(header_of(&js, header::CONTENT_SECURITY_POLICY), "");
        assert_eq!(header_of(&js, header::CACHE_CONTROL), IMMUTABLE);
        assert_eq!(header_of(&js, header::REFERRER_POLICY), "same-origin");
    }

    /// The page's scripts share one global scope, so a top-level name declared in two of them
    /// is a SyntaxError that drops the later script whole (2026-11-04: `sumOf` in infra.js and
    /// actions.js left Log's Actions section blank). `node --check` sees one file and cannot catch it.
    #[test]
    fn no_top_level_name_is_declared_by_two_scripts() {
        let mut seen: std::collections::HashMap<String, &str> = Default::default();
        for (file, ctype, body) in FILES {
            if *ctype != JS {
                continue;
            }
            for line in std::str::from_utf8(body).unwrap().lines() {
                let rest = [
                    "const ",
                    "let ",
                    "var ",
                    "function ",
                    "async function ",
                    "class ",
                ]
                .iter()
                .find_map(|k| line.strip_prefix(k));
                let Some(rest) = rest else { continue };
                let name: String = rest
                    .chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '$')
                    .collect();
                if name.is_empty() {
                    continue;
                }
                if let Some(first) = seen.insert(name.clone(), file) {
                    assert_eq!(
                        first, *file,
                        "{name} is declared in both {first} and {file}"
                    );
                }
            }
        }
    }
}
