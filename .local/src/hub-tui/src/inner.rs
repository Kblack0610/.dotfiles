//! A tab's inner tabs (`hub_core::layout::Inner`): the strip drawn under its pinned sections,
//! and the Left/Right step between them. Costs and Infra both draw theirs from here.

use hub_core::layout::{self, Tab};
use ratatui::text::{Line, Span};

use crate::fit::clip_line;
use crate::fmt::Palette;

/// The strip: the open inner tab in brackets, a count beside one whose sections are in `flagged`
/// (the ones needing a look, only above zero), and the keys that switch.
pub fn strip(tab: &Tab, on: &str, flagged: &[&str], p: Palette, w: usize) -> Line<'static> {
    let mut s = vec![];
    for i in tab.inner {
        let n = layout::inner_count(i, flagged);
        let label = if n > 0 {
            format!("{} {n}", i.title)
        } else {
            i.title.to_string()
        };
        let style = if n > 0 { p.warn() } else { p.head() };
        s.push(if i.id == on {
            Span::styled(format!("[{label}]"), style)
        } else if n > 0 {
            Span::styled(format!(" {label} "), p.warn())
        } else {
            Span::raw(format!(" {label} "))
        });
    }
    s.push(Span::styled("  <- -> switch", p.dim()));
    clip_line(Line::from(s), w)
}

/// The inner tab after `on` (before it when `back`), wrapping at the ends.
pub fn step(tab: &Tab, on: &'static str, back: bool) -> &'static str {
    let ids: Vec<&'static str> = tab.inner.iter().map(|i| i.id).collect();
    if ids.is_empty() {
        return on;
    }
    cycle(&ids, on, back)
}

/// The entry after `at` in `list` (before it when `back`), wrapping at the ends.
pub fn cycle<T: Copy + PartialEq>(list: &[T], at: T, back: bool) -> T {
    let i = list.iter().position(|x| *x == at).unwrap_or(0);
    let n = list.len();
    list[if back { (i + n - 1) % n } else { (i + 1) % n }]
}
