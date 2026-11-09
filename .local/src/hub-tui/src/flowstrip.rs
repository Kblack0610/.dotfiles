//! The flow strip as the hub draws it on Home, over `hub_core::flow::Strip` (the same builder
//! agent-web draws from); the Queue tab leads with the line (`flowline`). The step past its age bound
//! is the one amber chip; the line under the chips says what the inbox and board counts were
//! read from and when, so a count from a stopped writer cannot pass for a fresh one.

use hub_core::flow::Strip;
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;

use crate::fit::clip_line;
use crate::fmt::Palette;

const HEAD: &str = "FLOW  ";
const SEP: &str = " | ";

/// The lines: the chips wrapped under `FLOW`, a bottleneck line when a step is past its bound,
/// and a dim line for the snapshot's stamp or failure and the `o graph` hint. `reading` is true
/// while it has not been read, when inbox and board read `-`.
pub fn lines(
    strip: &Strip,
    reading: bool,
    graph: bool,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let indent = " ".repeat(HEAD.len());
    let mut out: Vec<Line<'static>> = vec![];
    let mut cur: Vec<Span<'static>> = vec![Span::styled(HEAD, p.head())];
    let mut used = HEAD.len();
    let mut first = true;
    for c in &strip.chips {
        let text = c.text();
        let width = UnicodeWidthStr::width(text.as_str());
        if !first && w > 0 && used + SEP.len() + width > w {
            out.push(Line::from(std::mem::take(&mut cur)));
            cur.push(Span::raw(indent.clone()));
            used = indent.len();
            first = true;
        }
        if !first {
            cur.push(Span::styled(SEP, p.dim()));
            used += SEP.len();
        }
        cur.push(if c.hot {
            Span::styled(text, p.warn())
        } else {
            Span::raw(text)
        });
        used += width;
        first = false;
    }
    out.push(Line::from(cur));
    if let Some(b) = &strip.bottleneck {
        out.push(Line::styled(format!("{indent}! {b}"), p.warn()));
    }
    let mut notes: Vec<String> = vec![];
    if reading {
        notes.push("inbox, board: reading".into());
    }
    if strip.absent {
        notes.push("inbox, board: no snapshot".into());
    }
    if let Some(t) = &strip.as_of {
        notes.push(format!("inbox, board as of {t}"));
    }
    if graph {
        notes.push("o graph".into());
    }
    if let Some(e) = &strip.error {
        out.push(Line::styled(format!("{indent}inbox, board: {e}"), p.warn()));
    }
    if !notes.is_empty() {
        out.push(Line::styled(
            format!("{indent}{}", notes.join("   ")),
            p.dim(),
        ));
    }
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::flow::Strip;

    const P: Palette = Palette { no_color: true };

    fn text(strip: &Strip, reading: bool, graph: bool, w: usize) -> Vec<String> {
        lines(strip, reading, graph, P, w)
            .iter()
            .map(|l| plain(l).trim_end().to_string())
            .collect()
    }

    #[test]
    fn the_chips_wrap_under_flow_at_a_narrow_width() {
        let st = Strip::build(None);
        let wide = text(&st, false, false, 140);
        assert_eq!(
            wide,
            ["FLOW  inbox - | board - | queued - | running - | needs you - | done 24h - | drain -"]
        );
        let narrow = text(&st, false, false, 40);
        assert!(
            narrow.len() > 1 && narrow.iter().all(|l| l.chars().count() <= 40),
            "{narrow:?}"
        );
        assert!(narrow[1].starts_with("      "), "{narrow:?}");
    }

    #[test]
    fn reading_the_snapshot_and_a_failed_read_say_so_and_the_graph_hint_rides_below() {
        let st = Strip::build(None);
        assert_eq!(
            text(&st, true, true, 140)[1],
            "      inbox, board: reading   o graph"
        );
        let mut bad = Strip::build(None);
        bad.set_pipeline(&Err("CC_PROM_URL is not set".into()));
        let l = text(&bad, false, false, 140);
        assert_eq!(l[1], "      inbox, board: CC_PROM_URL is not set");
        let mut none = Strip::build(None);
        none.set_pipeline(&Ok(None));
        assert_eq!(
            text(&none, false, false, 140)[1],
            "      inbox, board: no snapshot"
        );
    }
}
