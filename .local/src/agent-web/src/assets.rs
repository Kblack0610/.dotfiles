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
/// app.js the Sessions/Waiting tabs and the event stream; each other script is one board tab.
const FILES: &[(&str, &str, &[u8])] = &[
    ("app.css", CSS, include_bytes!("../static/app.css")),
    ("ui.js", JS, include_bytes!("../static/ui.js")),
    ("md.js", JS, include_bytes!("../static/md.js")),
    ("charts.js", JS, include_bytes!("../static/charts.js")),
    ("app.js", JS, include_bytes!("../static/app.js")),
    ("watch.js", JS, include_bytes!("../static/watch.js")),
    ("log.js", JS, include_bytes!("../static/log.js")),
    ("infra.js", JS, include_bytes!("../static/infra.js")),
    ("jobs.js", JS, include_bytes!("../static/jobs.js")),
    ("queue.js", JS, include_bytes!("../static/queue.js")),
    ("shepherd.js", JS, include_bytes!("../static/shepherd.js")),
    ("actions.js", JS, include_bytes!("../static/actions.js")),
    ("fleet.js", JS, include_bytes!("../static/fleet.js")),
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
}
