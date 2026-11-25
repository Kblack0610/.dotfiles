//! The Reports tab: every report an agent filed for the human, from `hub_core::reports`, the
//! reader agent-web's Reports tab uses. Today holds what needs the human, then the stream, then
//! the day's digests and the human's own captures, one line each; Archive is every other day.
//! Read-only: `notes report read` is agent-web's open, so the terminal never marks a report read.

use hub_core::layout::{self, Tab};
use hub_core::outbox::clock;
use hub_core::reports::{Row, Section, View};
use ratatui::text::{Line, Span};

use crate::fit::clip_line;
use crate::fmt::Palette;

/// Reports' layout entry: its sections and its Today and Archive inner tabs.
pub fn tab() -> &'static Tab {
    layout::resolve("reports").expect("reports is a layout tab")
}

/// The inner tab a request's word names: `archive`, or a date that is not today's (a day's
/// reports, which only Archive lists); else Today.
pub fn inner_of(word: &str, today: &str) -> &'static str {
    let w = word.trim();
    let is_date = w.len() == 10 && w.as_bytes()[4] == b'-' && w.as_bytes()[7] == b'-';
    match crate::innertabs::named(tab(), w) {
        Some(id) => id,
        None if is_date && w != today => "archive",
        None => "today",
    }
}

/// The page: the strip, the headline counts, then the inner tab's sections.
pub fn page(v: &View, inner: &str, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![crate::innertabs::strip(tab(), inner, &[], p, w)];
    out.push(clip_line(tiles(v, p), w));
    if inner == "archive" {
        out.extend(archive(v, p, w));
    } else {
        for s in &v.sections {
            out.extend(section(s, p, w));
        }
    }
    out
}

fn tiles(v: &View, p: Palette) -> Line<'static> {
    let mut s = vec![Span::styled("REPORTS", p.head())];
    for t in &v.tiles {
        let style = if t.level == "warn" { p.warn() } else { p.dim() };
        s.push(Span::styled(format!("  {} {}", t.n, t.label), style));
    }
    Line::from(s)
}

/// `HEAD  n`, a blank line before it.
fn head(title: &str, n: usize, p: Palette, w: usize) -> Vec<Line<'static>> {
    vec![
        Line::raw(""),
        clip_line(
            Line::from(vec![
                Span::styled(title.to_uppercase(), p.head()),
                Span::styled(format!("  {n}"), p.dim()),
            ]),
            w,
        ),
    ]
}

/// A row's first line: its title, the time it was filed and its state when it is not a plain
/// unread report.
fn first(r: &Row, indent: &str, p: Palette, w: usize) -> Line<'static> {
    let style = match (r.level, r.unread) {
        ("warn", _) => p.warn(),
        (_, true) => p.head(),
        _ => p.dim(),
    };
    let state = match r.state {
        "unread" => String::new(),
        s => format!("  {s}"),
    };
    clip_line(
        Line::from(vec![
            Span::styled(format!("{indent}{}", r.title.text()), style),
            Span::styled(format!("  {}{state}", clock(&r.at)), p.dim()),
        ]),
        w,
    )
}

fn section(s: &Section, p: Palette, w: usize) -> Vec<Line<'static>> {
    // A section with nothing is left out, not drawn empty.
    if s.rows.is_empty() {
        return vec![];
    }
    let mut out = head(s.title, s.rows.len(), p, w);
    if s.folded {
        // The reference reads fold to one line naming them.
        let names: Vec<&str> = s.rows.iter().map(|r| r.title.text()).collect();
        out.push(clip_line(
            Line::styled(format!("  {}", names.join(" . ")), p.dim()),
            w,
        ));
        return out;
    }
    for r in &s.rows {
        out.push(first(r, "  ", p, w));
        let sub = r.summary.text();
        if !sub.is_empty() {
            out.push(clip_line(Line::styled(format!("    {sub}"), p.dim()), w));
        }
    }
    out
}

fn archive(v: &View, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if !v.moved.is_empty() {
        out.push(Line::raw(""));
        out.push(clip_line(Line::styled(v.moved.clone(), p.warn()), w));
    }
    if v.archive.is_empty() {
        out.push(Line::raw(""));
        out.push(Line::styled("Nothing archived yet.", p.dim()));
    }
    for d in &v.archive {
        out.push(Line::raw(""));
        out.push(clip_line(
            Line::from(vec![
                Span::styled(d.date.clone(), p.head()),
                Span::styled(format!("  {}", d.count), p.dim()),
            ]),
            w,
        ));
        for r in &d.rows {
            out.push(first(r, "  ", p, w));
        }
    }
    if v.older_days > 0 {
        out.push(Line::raw(""));
        out.push(Line::styled(
            format!("+{} older days", v.older_days),
            p.dim(),
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::reports::{build, parse};

    // A needs-you report, a read one, an unread one a day old, a digest and a capture today,
    // and a read report from a past day.
    const LIST: &str = concat!(
        r#"{"id":"2026-11-24-ups","kind":"report","date":"2026-11-24","title":"UPS switch","summary":"Load fell 76% -> 41%\nUSB link down","needs_you":true,"created":"2026-11-24T15:40:00-08:00","read":null,"stream":true}"#,
        "\n",
        r#"{"id":"2026-11-24-board","kind":"report","date":"2026-11-24","title":"Board cleanup pass 3","summary":"212 -> 168 open rows","created":"2026-11-24T11:15:00-08:00","read":"2026-11-24T12:00:00-08:00","stream":true}"#,
        "\n",
        r#"{"id":"2026-11-23-flake","kind":"report","date":"2026-11-23","title":"Nightly flake readout","summary":"4 flaky specs","created":"2026-11-23T07:02:00-08:00","read":null,"stream":true}"#,
        "\n",
        r#"{"id":"2026-11-24-briefing","kind":"digest","date":"2026-11-24","title":"Briefing","created":"2026-11-24T06:00:00-08:00","stream":false}"#,
        "\n",
        r#"{"id":"2026-11-24-paste","kind":"capture","date":"2026-11-24","title":"Pasted transcript","created":"2026-11-24T09:00:00-08:00","stream":false}"#,
        "\n",
        r#"{"id":"2026-11-20-old","kind":"report","date":"2026-11-20","title":"Old report","summary":"x","created":"2026-11-20T09:00:00-08:00","read":"2026-11-20T10:00:00-08:00","stream":false}"#,
    );

    fn view() -> View {
        build(&parse(LIST).unwrap(), "2026-11-24")
    }

    fn text(lines: &[Line]) -> Vec<String> {
        lines.iter().map(crate::fit::plain).collect()
    }

    #[test]
    fn today_lists_needs_you_then_the_stream_then_one_line_for_the_folds() {
        let t = text(&page(&view(), "today", Palette { no_color: true }, 80));
        let at = |s: &str| t.iter().position(|l| l.contains(s)).unwrap_or(usize::MAX);
        assert!(t[0].contains("Today") && t[0].contains("Archive"), "{t:?}");
        assert!(t[1].starts_with("REPORTS  2 unread  1 needs you"), "{t:?}");
        assert!(
            at("NEEDS YOU") < at("UPS switch  15:40  needs you"),
            "{t:?}"
        );
        assert_eq!(t[at("UPS switch") + 1], "    Load fell 76% -> 41%", "{t:?}");
        assert!(at("UPS switch") < at("Board cleanup pass 3  11:15  read"));
        assert!(at("Board cleanup pass 3") < at("Nightly flake readout  07:02"));
        // The digest and the capture are one line each under their heads, not a row apiece.
        assert!(t.contains(&"  Briefing".to_string()), "{t:?}");
        assert!(t.contains(&"  Pasted transcript".to_string()), "{t:?}");
        assert!(!t.iter().any(|l| l.contains("Old report")), "archive only");
    }

    #[test]
    fn archive_lists_each_past_day_with_its_count() {
        let t = text(&page(&view(), "archive", Palette { no_color: true }, 80));
        assert!(
            t.contains(&"2026-11-20  1 report".to_string()),
            "the day and its count: {t:?}"
        );
        assert!(t.iter().any(|l| l.starts_with("  Old report")), "{t:?}");
        assert!(!t.iter().any(|l| l.contains("UPS switch")), "{t:?}");
    }

    #[test]
    fn a_section_with_no_rows_is_left_out_and_a_line_never_passes_the_width() {
        let t = text(&page(
            &build(&[], "2026-11-24"),
            "today",
            Palette::default(),
            40,
        ));
        assert!(!t.iter().any(|l| l.contains("NEEDS YOU")), "{t:?}");
        let t = text(&page(&view(), "today", Palette::default(), 30));
        assert!(t.iter().all(|l| l.chars().count() <= 30), "{t:?}");
    }

    #[test]
    fn a_request_word_picks_the_inner_tab() {
        assert_eq!(inner_of("archive", "2026-11-24"), "archive");
        assert_eq!(inner_of("2026-11-20", "2026-11-24"), "archive");
        assert_eq!(inner_of("2026-11-24", "2026-11-24"), "today");
        assert_eq!(inner_of("2026-11-24-ups", "2026-11-24"), "today");
        assert_eq!(inner_of("", "2026-11-24"), "today");
    }
}
