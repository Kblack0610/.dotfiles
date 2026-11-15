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
    step_of(tab.inner, on, back)
}

/// `step` over any inner list, such as the project page's (`layout::PROJECT_PAGE`).
pub fn step_of(inner: &[Inner], on: &str, back: bool) -> &'static str {
    let n = inner.len();
    if n == 0 {
        return "";
    }
    let i = inner.iter().position(|x| x.id == on).unwrap_or(0);
    inner[if back { (i + n - 1) % n } else { (i + 1) % n }].id
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
    spans(inner, on, |i| Some(count(i)).filter(|n| *n > 0), true, p, w)
}

/// [`strip_of`] with each inner tab's total beside it, None until it is read: a count, not a
/// flag, so it is never amber (dashboards rule 5), as agent-web's Projects strip draws it.
pub fn strip_totals(
    inner: &[Inner],
    on: &str,
    total: impl Fn(&Inner) -> Option<usize>,
    p: Palette,
    w: usize,
) -> Line<'static> {
    spans(inner, on, total, false, p, w)
}

/// The strip, a number beside each inner tab `n` gives one; `hot`: that number needs a look.
fn spans(
    inner: &[Inner],
    on: &str,
    n: impl Fn(&Inner) -> Option<usize>,
    hot: bool,
    p: Palette,
    w: usize,
) -> Line<'static> {
    let mut s = vec![];
    for i in inner {
        let n = n(i);
        let label = match n {
            Some(n) => format!("{} {n}", i.title),
            None => i.title.to_string(),
        };
        let base = if hot && n.is_some() {
            p.warn()
        } else {
            Style::new()
        };
        s.push(if i.id == on {
            Span::styled(format!("[{label}]"), base.patch(p.sel()).patch(p.head()))
        } else {
            Span::styled(format!(" {label} "), base)
        });
    }
    s.push(Span::styled("  <- -> switch", p.dim()));
    clip_line(Line::from(s), w)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_is_strict_so_an_unknown_word_keeps_the_inner_tab_shown() {
        let infra = layout::resolve("infra").unwrap();
        // `ci` is the Runners head's section, so the old CI inner tab's word opens Runners.
        assert_eq!(named(infra, "ci"), Some("runners"));
        assert_eq!(named(infra, " Pools "), Some("machines"));
        assert_eq!(named(infra, "jobs"), Some("jobs"));
        assert_eq!(
            named(infra, "governor"),
            None,
            "a moved name is the tab's to open"
        );
        let projects = layout::resolve("projects").unwrap();
        assert_eq!(named(projects, "requirements"), Some("ladder"));
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
        let open = l.spans.iter().find(|s| s.content == "[Spend]").unwrap();
        assert!(open.style.add_modifier.contains(Modifier::REVERSED));
    }

    #[test]
    fn a_total_is_plain_and_waits_for_its_read() {
        let projects = layout::resolve("projects").unwrap();
        let total = |i: &Inner| (i.id == "all").then_some(12);
        let l = strip_totals(projects.inner, "list", total, Palette::default(), 80);
        let words: Vec<&str> = l.spans.iter().map(|s| s.content.trim()).collect();
        assert_eq!(
            words[..4],
            ["[Projects]", "All rows 12", "Deliverables", "Ladder"],
            "no number until read"
        );
        let amber = Palette::default().warn().fg;
        assert!(
            l.spans.iter().all(|s| s.style.fg != amber),
            "a total is not amber"
        );
        // negative control: the same number as a flag is amber
        let l = strip_of(
            projects.inner,
            "list",
            |i| usize::from(i.id == "all") * 12,
            Palette::default(),
            80,
        );
        let hot = l
            .spans
            .iter()
            .find(|s| s.content.trim() == "All rows 12")
            .unwrap();
        assert_eq!(hot.style.fg, Palette::default().warn().fg);
    }
}
