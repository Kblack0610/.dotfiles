//! The Focus tab: a day's `## Focus` from `hub_core::focus`, the reader agent-web's Focus tab
//! uses, as lines. Read-only: Focus is written by `notes focus` and the editor. The open lanes
//! are drawn item by item, word-wrapped; Done, the rollup and the note's other sections are
//! counted and named, since a terminal has no fold to keep them in.

use hub_core::focus::{Item, View};
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::Palette;

fn mark(state: char) -> &'static str {
    match state {
        'x' => "[x]",
        '/' => "[/]",
        _ => "[ ]",
    }
}

/// One task, its mark hanging and its text wrapped under itself.
fn item(i: &Item, p: Palette, w: usize) -> Vec<Line<'static>> {
    let pad = "  ".repeat(i.depth + 1);
    let lead = format!("{pad}{} ", mark(i.state));
    let words: Vec<&str> = i.text.split_whitespace().collect();
    let body = wrap(&words, " ", w.saturating_sub(lead.len()).max(10));
    let style = if i.state == '/' {
        p.good()
    } else {
        ratatui::style::Style::default()
    };
    body.into_iter()
        .enumerate()
        .map(|(n, t)| {
            let head = if n == 0 {
                lead.clone()
            } else {
                " ".repeat(lead.len())
            };
            clip_line(
                Line::from(vec![Span::styled(head, p.dim()), Span::styled(t, style)]),
                w,
            )
        })
        .collect()
}

pub fn page(v: &View, p: Palette, w: usize) -> Vec<Line<'static>> {
    let n = &v.note;
    let mut out = vec![];
    let day = n.date.clone().unwrap_or_else(|| n.rel.clone());
    let counts = v.focus.as_ref().map_or(String::new(), |f| {
        format!("  {} open, {} done", f.open, f.done)
    });
    out.push(clip_line(
        Line::from(vec![
            Span::styled(format!("FOCUS {day}"), p.head()),
            Span::styled(counts, p.dim()),
        ]),
        w,
    ));
    if !n.exists {
        out.push(Line::styled(format!("No note for {day} yet."), p.dim()));
        return out;
    }
    let Some(f) = &v.focus else {
        out.push(Line::styled("This note has no ## Focus.", p.dim()));
        return out;
    };
    for l in &f.lanes {
        out.push(Line::raw(""));
        let name = if l.name.is_empty() {
            "Focus"
        } else {
            l.name.as_str()
        };
        if l.name.eq_ignore_ascii_case("done") {
            out.push(clip_line(
                Line::from(vec![
                    Span::styled(name.to_uppercase(), p.head()),
                    Span::styled(format!("  {} done today", l.done), p.dim()),
                ]),
                w,
            ));
            continue;
        }
        out.push(Line::from(vec![
            Span::styled(name.to_uppercase(), p.head()),
            Span::styled(format!("  {}", l.open), p.dim()),
        ]));
        if l.items.is_empty() {
            out.push(Line::styled("  nothing here", p.dim()));
        }
        for i in &l.items {
            out.extend(item(i, p, w));
        }
    }
    let mut rest: Vec<String> = vec![];
    if !f.rollup.is_empty() {
        rest.push("Rollup".into());
    }
    rest.extend(v.sections.iter().map(|s| {
        if s.title.is_empty() {
            "Top".into()
        } else {
            s.title.clone()
        }
    }));
    if !rest.is_empty() {
        out.push(Line::raw(""));
        out.push(clip_line(
            Line::styled(
                format!(
                    "Also in the note: {} (agent-web Focus, or `notes show`)",
                    rest.join(", ")
                ),
                p.dim(),
            ),
            w,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::focus::{build, Note};

    fn view(md: &str) -> View {
        build(Note {
            markdown: md.into(),
            exists: true,
            date: Some("2026-11-05".into()),
            ..Default::default()
        })
    }

    fn text(v: &View, w: usize) -> Vec<String> {
        page(v, Palette { no_color: true }, w)
            .iter()
            .map(plain)
            .collect()
    }

    #[test]
    fn the_open_lanes_list_their_items_and_done_is_a_count() {
        let v = view(
            "## Focus\n### Urgent\n- [ ] fix the menu #c1105\n  - [ ] a child\n- [/] wire the bar\n### High\n---\n### Done\n- [x] water plants\n## Notes\nhi\n",
        );
        let t = text(&v, 80);
        assert_eq!(t[0], "FOCUS 2026-11-05  2 open, 1 done");
        assert!(t.contains(&"URGENT  2".to_string()), "{t:?}");
        assert!(t.contains(&"  [ ] fix the menu #c1105".to_string()));
        assert!(
            t.contains(&"    [ ] a child".to_string()),
            "a child is indented under its parent"
        );
        assert!(t.contains(&"  [/] wire the bar".to_string()));
        assert!(t.contains(&"  nothing here".to_string()), "High is empty");
        assert!(t.contains(&"DONE  1 done today".to_string()));
        assert!(
            !t.iter().any(|l| l.contains("water plants")),
            "Done is not listed"
        );
        assert!(t.last().unwrap().starts_with("Also in the note: Notes"));
    }

    #[test]
    fn a_long_item_wraps_under_its_own_text() {
        let v = view("## Focus\n### Low\n- [ ] one two three four five six\n");
        let t = text(&v, 20);
        assert_eq!(&t[3..5], ["  [ ] one two three", "      four five six"]);
    }

    #[test]
    fn a_day_with_no_note_says_so() {
        let mut v = view("");
        v.note.exists = false;
        assert_eq!(text(&v, 80)[1], "No note for 2026-11-05 yet.");
    }
}
