//! Inner tabs (`hub_core::layout::Inner`): the strip of sub-views under a tab, drawn and named
//! the same way on every tab that has one (Costs, Releases, Infra), as agent-web's `innerStrip` draws it.

use hub_core::layout::{self, Inner, Tab};
use ratatui::style::Style;
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

/// The strip, its tab's first line: the open one in brackets, bold and reversed (amber when its
/// sections need a look) so it reads at a glance, the rest plain; a count beside one with sections
/// needing a look (`flagged`, `layout::inner_count`), and the keys that switch.
pub fn strip(tab: &Tab, on: &str, flagged: &[&str], p: Palette, w: usize) -> Line<'static> {
    strip_of(tab.inner, on, |i| layout::inner_count(i, flagged), p, w)
}

/// [`strip`] over any inner list (a record page's, `layout::PROJECT_PAGE`), `count` giving the
/// number beside each.
pub fn strip_of(
    inner: &[Inner],
    on: &str,
    count: impl Fn(&Inner) -> usize,
    p: Palette,
    w: usize,
) -> Line<'static> {
    let mut s = vec![];
    for i in inner {
        let n = count(i);
        let label = if n > 0 {
            format!("{} {n}", i.title)
        } else {
            i.title.to_string()
        };
        s.push(if i.id == on {
            let base = if n > 0 { p.warn() } else { Style::new() };
            Span::styled(format!("[{label}]"), base.patch(p.sel()).patch(p.head()))
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
        assert_eq!(named(infra, "ci"), Some("ci"));
        assert_eq!(named(infra, " Pools "), Some("machines"));
        assert_eq!(named(infra, "jobs"), Some("jobs"));
        assert_eq!(
            named(infra, "governor"),
            None,
            "a moved name is the tab's to open"
        );
        assert_eq!(named(infra, "red"), None);
        assert_eq!(named(infra, "nope"), None);
        assert_eq!(step(infra, "machines", true), "jobs");
    }

    #[test]
    fn the_open_inner_tab_is_bold_and_reversed_and_the_rest_plain() {
        use ratatui::style::Modifier;
        let costs = layout::resolve("costs").unwrap();
        let l = strip(costs, "spend", &[], Palette::default(), 80);
        let open = l.spans.iter().find(|s| s.content == "[Spend]").unwrap();
        assert!(open
            .style
            .add_modifier
            .contains(Modifier::REVERSED | Modifier::BOLD));
        let shut = l
            .spans
            .iter()
            .find(|s| s.content.trim() == "Limits")
            .unwrap();
        assert!(!shut.style.add_modifier.contains(Modifier::REVERSED));
        // negative control: NO_COLOR keeps the reverse, which is not colour
        let l = strip(costs, "spend", &[], Palette { no_color: true }, 80);
        assert!(l.spans[1].style.add_modifier.contains(Modifier::REVERSED));
    }
}
