//! A page's save through the notes CLI's compare-and-swap writers (`notes outbox put --base`,
//! `notes put --base`): the page's text goes in on stdin (an argument is capped at 128 KB), and
//! the exit says what happened. 0 is written, with the new state on stdout; 3 is a stale base,
//! nothing written, with the current state on stdout; anything else is the CLI's error.
//! `hub_core::session_actions::Runner` passes no stdin, so this is the one place that spawns a
//! write with input.

use std::io::Write;
use std::process::{Command, Stdio};

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

use crate::bad;

/// The CLI's exit when the file changed since the base the page read.
pub const STALE: i32 = 3;

/// What a finished put means for the page.
#[derive(Debug, PartialEq)]
pub enum Outcome<T> {
    Written(T),
    Stale(T),
    Failed(String),
}

/// Text a page may write: CRLF folded, at most `max` bytes, and no control character but
/// newline and tab, so the page cannot write anything a hand edit could not.
pub fn plain_text(t: &str, max: usize) -> Option<String> {
    let t = t.replace("\r\n", "\n");
    (t.len() <= max && !t.chars().any(|c| c.is_control() && c != '\n' && c != '\t')).then_some(t)
}

/// A base is the hex hash the page last read.
pub fn is_base(b: &str) -> bool {
    !b.is_empty() && b.len() <= 64 && b.chars().all(|c| c.is_ascii_hexdigit())
}

pub fn outcome<T>(
    what: &str,
    code: Option<i32>,
    stdout: &str,
    stderr: &str,
    parse: impl Fn(&str) -> Result<T, String>,
) -> Outcome<T> {
    match code {
        Some(0) => parse(stdout.trim()).map_or_else(Outcome::Failed, Outcome::Written),
        Some(STALE) => parse(stdout.trim()).map_or_else(Outcome::Failed, Outcome::Stale),
        _ if stderr.trim().is_empty() => Outcome::Failed(format!("{what}: exit {code:?}")),
        _ => Outcome::Failed(stderr.trim().to_string()),
    }
}

/// Run `notes <args>` with `input` on stdin; `what` names it in an error.
pub fn put<T>(
    what: &str,
    args: &[&str],
    input: &str,
    parse: impl Fn(&str) -> Result<T, String>,
) -> Outcome<T> {
    let child = Command::new("notes")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(format!("notes: {e}")),
    };
    // The CLI reads all of stdin before it writes anything, so this cannot block on its output.
    if let Some(mut stdin) = child.stdin.take() {
        if let Err(e) = stdin.write_all(input.as_bytes()) {
            return Outcome::Failed(format!("{what}: {e}"));
        }
    }
    match child.wait_with_output() {
        Ok(o) => outcome(
            what,
            o.status.code(),
            &String::from_utf8_lossy(&o.stdout),
            &String::from_utf8_lossy(&o.stderr),
            parse,
        ),
        Err(e) => Outcome::Failed(format!("{what}: {e}")),
    }
}

/// Written is 200 with the new state, Stale 409 with the current one, Failed 502.
pub fn respond<T: Serialize>(o: Outcome<T>) -> Response {
    match o {
        Outcome::Written(d) => Json(d).into_response(),
        Outcome::Stale(d) => (StatusCode::CONFLICT, Json(d)).into_response(),
        Outcome::Failed(e) => bad(StatusCode::BAD_GATEWAY, e).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn num(s: &str) -> Result<u32, String> {
        s.parse().map_err(|_| format!("not a number: {s}"))
    }

    #[test]
    fn the_text_is_plain_lines_under_the_cap() {
        assert_eq!(plain_text("a\r\nb\tc\n", 64).unwrap(), "a\nb\tc\n");
        assert!(
            plain_text("a\u{1b}[2J", 64).is_none(),
            "an escape is not a line"
        );
        assert!(plain_text(&"x".repeat(65), 64).is_none());
        assert!(is_base("00ff") && !is_base("") && !is_base("zz") && !is_base("a b"));
    }

    #[test]
    fn a_stale_base_is_the_current_state_and_a_failure_says_why() {
        assert_eq!(outcome("put", Some(0), "7\n", "", num), Outcome::Written(7));
        assert_eq!(
            outcome(
                "put",
                Some(STALE),
                "7",
                "changed since ab; nothing written",
                num
            ),
            Outcome::Stale(7)
        );
        assert_eq!(
            outcome("put", Some(1), "", "error: no profile\n", num),
            Outcome::Failed("error: no profile".into())
        );
        assert!(
            matches!(outcome("put", None, "", "", num), Outcome::Failed(e) if e == "put: exit None")
        );
        assert!(matches!(
            outcome("put", Some(0), "nope", "", num),
            Outcome::Failed(_)
        ));
    }

    #[test]
    fn a_stale_base_answers_409_and_a_cli_error_502() {
        assert_eq!(
            respond(outcome("p", Some(0), "1", "", num)).status(),
            StatusCode::OK
        );
        assert_eq!(
            respond(outcome("p", Some(STALE), "1", "", num)).status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            respond(outcome("p", Some(2), "", "boom", num)).status(),
            StatusCode::BAD_GATEWAY
        );
    }
}
