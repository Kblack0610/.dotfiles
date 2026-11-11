//! Inner tabs (`hub_core::layout::Inner`): the strip of sub-views under a tab, drawn and named
//! the same way on every tab that has one (Costs, Releases, Infra), as agent-web's `innerStrip` draws it.

use hub_core::layout::{self, Tab};
use ratatui::text::{Line, Span};

use crate::fit::clip_line;
use crate::fmt::Palette;

/// The inner tab a word names strictly: an inner id, or a section id for the one holding it.
pub fn named(tab: &Tab, word: &str) -> Option<&'static str> {
    let w = word.trim().to_ascii_lowercase();
    tab.inner
        .iter()
        .find(|i| i.id == w || i.sections.contains(&w.as_str()))
        .map(|i| i.id)
}

/// The inner tab after (or with `back`, before) `on`, wrapping at the ends; "" on a tab with none.
pub fn step(tab: &Tab, on: &str, back: bool) -> &'static str {
    let ids: Vec<&'static str> = tab.inner.iter().map(|i| i.id).collect();
    let n = ids.len();
    if n == 0 {
        return "";
    }
    let i = ids.iter().position(|x| *x == on).unwrap_or(0);
    ids[if back { (i + n - 1) % n } else { (i + 1) % n }]
}

/// The strip: the open one in brackets, a count beside one with sections needing a look
/// (`flagged`, `layout::inner_count`), and the keys that switch.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_is_strict_so_a_pinned_or_unknown_word_keeps_the_inner_tab_shown() {
        let infra = layout::resolve("infra").unwrap();
        assert_eq!(named(infra, "ci"), Some("machines"));
        assert_eq!(named(infra, " Cloud "), Some("cloud"));
        assert_eq!(named(infra, "red"), None);
        assert_eq!(named(infra, "nope"), None);
        assert_eq!(step(infra, "reds", true), "cloud");
    }
}
