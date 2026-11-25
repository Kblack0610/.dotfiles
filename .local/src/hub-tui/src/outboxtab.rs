//! The Daily tab's outbox view (`o`): the outbox's waiting lines and what intake did today,
//! from `hub_core::outbox`, the reader agent-web's Daily outbox uses. The terminal does not edit in
//! place: Enter opens the file in `$EDITOR` in a new tmux window, and the sweep files what is
//! saved there 30s after the last save.

use hub_core::outbox::{clock, say, View};
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::Palette;

/// `text` word-wrapped to `w`, its first line led by `lead` and the rest hung under it.
fn hung(lead: &str, text: &str, w: usize) -> Vec<(String, String)> {
    let words: Vec<&str> = text.split_whitespace().collect();
    wrap(&words, " ", w.saturating_sub(lead.len()).max(10))
        .into_iter()
        .enumerate()
        .map(|(n, t)| {
            let head = if n == 0 {
                lead.to_string()
            } else {
                " ".repeat(lead.len())
            };
            (head, t)
        })
        .collect()
}

/// The tab's lines: the outbox (or why it did not read), with what the last action said above it.
pub fn lines(
    outbox: Option<&Result<View, String>>,
    said: Option<&Result<String, String>>,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    match outbox {
        None => vec![Line::styled("Reading the outbox...", p.dim())],
        Some(Err(e)) => vec![Line::styled(e.clone(), p.warn())],
        Some(Ok(v)) => {
            let mut l = match said {
                Some(Ok(m)) => vec![Line::styled(m.clone(), p.dim())],
                Some(Err(e)) => vec![Line::styled(e.clone(), p.warn())],
                None => vec![],
            };
            l.extend(page(v, p, w));
            l
        }
    }
}

pub fn page(v: &View, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("OUTBOX", p.head()),
            Span::styled(format!("  {} waiting", v.doc.waiting), p.dim()),
        ]),
        w,
    )];
    if v.doc.text.trim().is_empty() {
        out.push(Line::styled("Empty. Enter opens it to write in.", p.dim()));
    }
    for l in v.doc.text.lines() {
        out.push(clip_line(Line::raw(format!("  {l}")), w));
    }
    out.push(Line::raw(""));
    out.push(clip_line(
        Line::from(vec![
            Span::styled("HANDLED TODAY", p.head()),
            Span::styled(format!("  {}", v.counts), p.dim()),
        ]),
        w,
    ));
    if v.handled.is_empty() {
        out.push(Line::styled("Nothing yet today.", p.dim()));
    }
    for s in &v.handled {
        let style = if matches!(s.action.as_str(), "left" | "asked" | "refused") {
            p.warn()
        } else {
            ratatui::style::Style::default()
        };
        for (head, t) in hung(&format!("  {} ", clock(&s.ts)), &say(s), w) {
            out.push(clip_line(
                Line::from(vec![Span::styled(head, p.dim()), Span::styled(t, style)]),
                w,
            ));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::outbox::{build, Doc};

    use crate::fit::plain_text as text;

    #[test]
    fn the_waiting_lines_then_todays_steps() {
        let doc = Doc {
            text: "- [ ] the gun shot is late".into(),
            waiting: 1,
            ..Doc::default()
        };
        let log = r#"{"ts":"2026-11-05T14:01:00-08:00","action":"filed","from":"db","to":"dodginballs","lane":"human","text":"fix(audio): gun shot late","id":"db-51"}"#;
        let got = text(&page(&build(doc, log), Palette::default(), 80));
        assert!(
            got.starts_with("OUTBOX  1 waiting\n  - [ ] the gun shot is late"),
            "{got}"
        );
        assert!(got.contains("HANDLED TODAY  1 filed"), "{got}");
        assert!(
            got.contains("14:01 filed db-51 in dodginballs: fix(audio): gun shot late"),
            "{got}"
        );
    }

    #[test]
    fn an_empty_outbox_says_how_to_write_in_it() {
        let got = text(&page(&build(Doc::default(), ""), Palette::default(), 80));
        assert!(got.contains("Empty. Enter opens it"), "{got}");
        assert!(got.contains("Nothing yet today."), "{got}");
    }
}
