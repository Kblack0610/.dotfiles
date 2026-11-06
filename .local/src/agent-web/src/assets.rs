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
/// Where the page and app.css name the asset version.
const VERSION_MARK: &str = "{{v}}";

const JS: &str = "text/javascript; charset=utf-8";
const CSS: &str = "text/css; charset=utf-8";
const WOFF2: &str = "font/woff2";

/// `(name, content type, body)`. ui.js is the shared helpers, md.js the markdown renderer,
/// app.js the Sessions tab and the event stream, waiting.js the answer cards, home.js the Home tab;
/// each other script is one board tab.
const FILES: &[(&str, &str, &[u8])] = &[
    ("app.css", CSS, include_bytes!("../static/app.css")),
    ("ui.js", JS, include_bytes!("../static/ui.js")),
    ("md.js", JS, include_bytes!("../static/md.js")),
    ("charts.js", JS, include_bytes!("../static/charts.js")),
    ("app.js", JS, include_bytes!("../static/app.js")),
    ("waiting.js", JS, include_bytes!("../static/waiting.js")),
    ("home.js", JS, include_bytes!("../static/home.js")),
    ("outbox.js", JS, include_bytes!("../static/outbox.js")),
    ("watch.js", JS, include_bytes!("../static/watch.js")),
    ("log.js", JS, include_bytes!("../static/log.js")),
    ("infra.js", JS, include_bytes!("../static/infra.js")),
    ("table.js", JS, include_bytes!("../static/table.js")),
    ("jobs.js", JS, include_bytes!("../static/jobs.js")),
    ("queue.js", JS, include_bytes!("../static/queue.js")),
    ("board.js", JS, include_bytes!("../static/board.js")),
    ("projects.js", JS, include_bytes!("../static/projects.js")),
    ("shepherd.js", JS, include_bytes!("../static/shepherd.js")),
    ("actions.js", JS, include_bytes!("../static/actions.js")),
    ("fleet.js", JS, include_bytes!("../static/fleet.js")),
    ("focus.js", JS, include_bytes!("../static/focus.js")),
    (
        "inter.woff2",
        WOFF2,
        include_bytes!("../static/fonts/inter.woff2"),
    ),
    (
        "jetbrains-mono.woff2",
        WOFF2,
        include_bytes!("../static/fonts/jetbrains-mono.woff2"),
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
        let mut h = fnv(FNV_OFFSET, INDEX.as_bytes());
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
            index: INDEX.replace(VERSION_MARK, &version),
            version,
            files,
        }
    })
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

    const APP_JS: &str = include_str!("../static/app.js");
    const FLEET_JS: &str = include_str!("../static/fleet.js");

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

    #[test]
    fn the_workers_filters_are_hub_cores() {
        // docs/dashboards.md rule 8: the chips and sorts are the TUI's, in its order.
        assert_eq!(
            js_list(FLEET_JS, "W_FILTERS"),
            hub_core::fleet::WORKER_FILTERS
        );
        assert_eq!(js_list(FLEET_JS, "W_SORTS"), hub_core::fleet::WORKER_SORTS);
    }

    #[test]
    fn the_jobs_headers_are_hub_cores_columns() {
        // Rule 8: the web draws the columns hub_core::table sorts and filters, every one of them.
        use hub_core::table::Row;
        let js = include_str!("../static/jobs.js");
        let at = js.find("const JOB_COLS = {").expect("no JOB_COLS");
        let body = &js[at..at + js[at..].find('}').unwrap()];
        let keys: Vec<&str> = body
            .split(['{', ','])
            .filter_map(|p| p.split_once(':').map(|(k, _)| k.trim()))
            .filter(|k| !k.contains('"') && !k.is_empty())
            .collect();
        assert_eq!(keys, hub_core::jobs::Job::COLUMNS);
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
        let b = built();
        let css = b.files.iter().find(|(n, _, _)| *n == "app.css").unwrap();
        let css = std::str::from_utf8(&css.2).unwrap();
        assert!(!css.contains(VERSION_MARK));
        assert!(css.contains(&format!("/static/inter.woff2?v={}", b.version)));
        assert!(css.contains(&format!("/static/jetbrains-mono.woff2?v={}", b.version)));
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
