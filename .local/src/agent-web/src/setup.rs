//! `/widget/setup`: hands a phone the widget key with no adb and no typing. Behind the session
//! sign-in, never the widget key: an "Add to Tilecast" link (`tilecast://add?url=<base>/widget.json
//! &auth=bearer&key=<key>`), the same link as a QR for setting up from a computer, and a New key
//! button that rewrites `widget.token` (creating it when missing), which stops every phone set up
//! with the old key until it is added again. The key is only ever in this page's body.

use std::fmt::Write;
use std::path::Path;

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use qrcodegen::{QrCode, QrCodeEcc};

use crate::{auth, Shared};

const PAGE: &str = include_str!("setup.html");
const PATH: &str = "/widget/setup";

pub async fn page(State(s): State<Shared>, headers: HeaderMap) -> Response {
    let signed_in = crate::signed_in(&s, &headers).is_some();
    show(signed_in, s.oauth.base(), &auth::widget_token_path())
}

pub async fn new_key(State(s): State<Shared>, headers: HeaderMap) -> Response {
    let signed_in = crate::signed_in(&s, &headers).is_some();
    rotate(
        signed_in,
        &headers,
        s.oauth.base(),
        &auth::widget_token_path(),
    )
}

/// A signed-out visit goes to `/`, the sign-in page with the Forgejo button and the key form.
fn to_sign_in() -> Response {
    (StatusCode::SEE_OTHER, [(header::LOCATION, "/")]).into_response()
}

fn show(signed_in: bool, base: &str, key_file: &Path) -> Response {
    if !signed_in {
        return to_sign_in();
    }
    let body = match auth::read_token(key_file) {
        Some(key) => {
            let link = add_link(base, &key);
            format!(
                r#"<a class="btn" href="{}">Add to Tilecast</a>{}<p class="cap">Setting up from a computer? Scan this with the phone.</p>"#,
                escape(&link),
                qr_svg(&link)
            )
        }
        None => r#"<p class="err">There is no widget key yet: New key makes one.</p>"#.into(),
    };
    let page = PAGE
        .replacen("{{card_css}}", crate::assets::CARD_CSS, 1)
        .replacen("{{body}}", &body, 1);
    ([crate::widget::NO_STORE], Html(page)).into_response()
}

fn rotate(signed_in: bool, headers: &HeaderMap, base: &str, key_file: &Path) -> Response {
    if !signed_in {
        return to_sign_in();
    }
    // SameSite=Lax already keeps the cookie off another site's POST; this holds even without it.
    if !same_origin(headers, base) {
        eprintln!(
            "agent-web: new widget key refused: origin {:?}",
            headers.get(header::ORIGIN)
        );
        return (StatusCode::FORBIDDEN, "cross-origin request refused").into_response();
    }
    if let Err(e) = auth::rotate_token(key_file) {
        eprintln!("agent-web: could not write a new widget key: {e:#}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "could not write a new widget key",
        )
            .into_response();
    }
    (StatusCode::SEE_OTHER, [(header::LOCATION, PATH)]).into_response()
}

/// The link the Tilecast app's `tilecast://add` handler reads.
fn add_link(base: &str, key: &str) -> String {
    format!(
        "tilecast://add?url={}&auth=bearer&key={}",
        auth::pct_encode(&format!("{base}/widget.json")),
        auth::pct_encode(key)
    )
}

/// The request's `Origin` is this server's: a browser sends it on every form POST, and
/// `AGENT_WEB_BASE_URL` is an origin (the routes and the OAuth callback sit at its root).
fn same_origin(headers: &HeaderMap, base: &str) -> bool {
    headers
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|o| o == base)
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// `text` as an inline SVG QR code, with the standard 4-module quiet zone.
fn qr_svg(text: &str) -> String {
    let Ok(qr) = QrCode::encode_text(text, QrCodeEcc::Medium) else {
        return String::new();
    };
    const QUIET: i32 = 4;
    let side = qr.size() + 2 * QUIET;
    let mut d = String::new();
    for y in 0..qr.size() {
        for x in 0..qr.size() {
            if qr.get_module(x, y) {
                let _ = write!(d, "M{},{}h1v1h-1z", x + QUIET, y + QUIET);
            }
        }
    }
    format!(
        r##"<svg class="qr" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {side} {side}" shape-rendering="crispEdges" role="img" aria-label="QR code of the Add to Tilecast link"><rect width="{side}" height="{side}" fill="#fff"/><path d="{d}" fill="#000"/></svg>"##
    )
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    use super::*;

    const BASE: &str = "https://agents.example";

    fn temp_dir() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("agent-web-setup-{}", auth::random_hex(6).unwrap()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn location(r: &Response) -> Option<&str> {
        r.headers().get(header::LOCATION)?.to_str().ok()
    }

    async fn body(r: Response) -> String {
        let b = axum::body::to_bytes(r.into_body(), usize::MAX)
            .await
            .unwrap();
        String::from_utf8(b.to_vec()).unwrap()
    }

    fn origin(o: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(header::ORIGIN, o.parse().unwrap());
        h
    }

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[tokio::test]
    async fn a_signed_out_visit_or_post_goes_to_sign_in_and_writes_nothing() {
        let dir = temp_dir();
        let file = dir.join("widget.token");
        let r = show(false, BASE, &file);
        assert_eq!(r.status(), StatusCode::SEE_OTHER);
        assert_eq!(location(&r), Some("/"));
        let r = rotate(false, &origin(BASE), BASE, &file);
        assert_eq!(r.status(), StatusCode::SEE_OTHER);
        assert_eq!(location(&r), Some("/"));
        assert!(!file.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_signed_in_page_carries_the_add_link_with_the_key_and_its_qr() {
        let dir = temp_dir();
        let file = dir.join("widget.token");
        std::fs::write(&file, "k3y+/\n").unwrap();
        let r = show(true, BASE, &file);
        assert_eq!(r.status(), StatusCode::OK);
        let html = body(r).await;
        assert!(html.contains(
            r#"href="tilecast://add?url=https%3A%2F%2Fagents.example%2Fwidget.json&amp;auth=bearer&amp;key=k3y%2B%2F""#
        ));
        assert!(html.contains(r#"<svg class="qr""#));
        assert!(html.contains(r#"action="/widget/setup/new-key""#));
        assert!(!html.contains("{{"));
        // Negative control: with no key file the page has no link, only New key.
        std::fs::remove_file(&file).unwrap();
        let html = body(show(true, BASE, &file)).await;
        assert!(!html.contains("tilecast://") && !html.contains("<svg"));
        assert!(html.contains("New key"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn new_key_rotates_the_file_and_keeps_it_0600_and_creates_it_when_missing() {
        let dir = temp_dir().join("agent-web");
        let file = dir.join("widget.token");
        let r = rotate(true, &origin(BASE), BASE, &file);
        assert_eq!(r.status(), StatusCode::SEE_OTHER);
        assert_eq!(location(&r), Some(PATH));
        let first = auth::read_token(&file).unwrap();
        assert_eq!(first.len(), 48);
        assert!(first.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(&dir), 0o700);

        // An old file with looser bits is replaced, not kept.
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        rotate(true, &origin(BASE), BASE, &file);
        let second = auth::read_token(&file).unwrap();
        assert_ne!(first, second);
        assert_eq!(mode(&file), 0o600);
        assert!(!file.with_extension("new").exists());
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    #[test]
    fn a_cross_origin_or_originless_post_is_refused_and_keeps_the_key() {
        let dir = temp_dir();
        let file = dir.join("widget.token");
        std::fs::write(&file, "old").unwrap();
        for h in [
            origin("https://evil.example"),
            origin("https://agents.example.evil"),
            origin("null"),
            HeaderMap::new(),
        ] {
            let r = rotate(true, &h, BASE, &file);
            assert_eq!(r.status(), StatusCode::FORBIDDEN);
            assert_eq!(auth::read_token(&file).as_deref(), Some("old"));
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
