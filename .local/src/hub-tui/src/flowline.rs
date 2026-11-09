//! The pipeline line as the hub draws it, leading the Queue tab: one point per step over
//! `hub_core::flow::Rail` (the same builder agent-web draws from), the selected step's detail
//! under it. `[` and `]` move between steps and the worst one starts open; `{` and `}` walk the
//! open step's problems and Enter opens the Queue item the marked one names. Amber is a step
//! past its age bound and red one nothing can leave; a `!` says the same with no colour.

use hub_core::flow::{Node, Rail};
use ratatui::crossterm::event::KeyCode;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;

use crate::fit::clip_line;
use crate::fmt::Palette;

const ARROW: &str = " -> ";
const GAP: &str = "    ";
/// Problems listed under the open step. The header counts them all; more would push the table
/// off a laptop screen.
const SHOWN_PROBLEMS: usize = 4;
/// The narrow form's label column: `needs you`.
const LABEL_COLS: usize = 9;

/// What the human has picked on the line: a step by key, so a redraw keeps it, and the marked
/// problem of that step.
#[derive(Default)]
pub struct LineView {
    node: Option<String>,
    problem: Option<usize>,
}

#[derive(Debug, PartialEq)]
pub enum Took {
    No,
    Moved,
    /// Open the Queue item with this slug.
    Open(String),
}

impl LineView {
    fn at(&self, r: &Rail) -> usize {
        let picked = self.node.as_deref();
        picked
            .and_then(|k| r.nodes.iter().position(|n| n.key == k))
            .unwrap_or(r.worst)
    }

    pub fn key(&mut self, code: KeyCode, r: &Rail) -> Took {
        let at = self.at(r);
        let Some(node) = r.nodes.get(at) else {
            return Took::No;
        };
        let shown = node.problems.len().min(SHOWN_PROBLEMS);
        match code {
            KeyCode::Char(c @ ('[' | ']')) => {
                let to = if c == '[' {
                    at.saturating_sub(1)
                } else {
                    at + 1
                };
                if let Some(n) = r.nodes.get(to) {
                    self.node = Some(n.key.to_string());
                    self.problem = None;
                }
            }
            KeyCode::Char('}') if shown > 0 => {
                self.node = Some(node.key.to_string());
                self.problem = Some(self.problem.map_or(0, |p| (p + 1).min(shown - 1)));
            }
            KeyCode::Char('{') if shown > 0 => {
                self.node = Some(node.key.to_string());
                self.problem = Some(self.problem.map_or(0, |p| p.saturating_sub(1)));
            }
            KeyCode::Esc if self.problem.is_some() => self.problem = None,
            KeyCode::Enter if self.problem.is_some() => {
                let item = self
                    .problem
                    .and_then(|p| node.problems.get(p)?.item.clone());
                self.problem = None;
                return item.map_or(Took::Moved, Took::Open);
            }
            _ => return Took::No,
        }
        Took::Moved
    }
}

fn style(n: &Node, p: Palette) -> Style {
    if n.stopped {
        p.bad()
    } else if n.hot {
        p.warn()
    } else {
        Style::default()
    }
}

fn count(n: &Node) -> String {
    let mark = if n.stopped || n.hot { "!" } else { "" };
    format!("{mark}{}", n.count.as_deref().unwrap_or("-"))
}

fn label(n: &Node, selected: bool) -> String {
    if selected {
        n.label.to_uppercase()
    } else {
        n.label.to_string()
    }
}

/// `PIPELINE  as of 09:41  [ ] node  { } problem  o graph`, and a red line when the snapshot
/// cannot be trusted.
fn header(r: &Rail, graph: bool, p: Palette) -> Vec<Line<'static>> {
    let mut spans = vec![Span::styled("PIPELINE", p.head())];
    if let Some(t) = &r.as_of {
        let (text, st) = if r.stale {
            (format!("  as of {t} (stale)"), p.bad())
        } else {
            (format!("  as of {t}"), p.dim())
        };
        spans.push(Span::styled(text, st));
    }
    if r.stale && r.as_of.is_none() {
        spans.push(Span::styled("  age unknown", p.bad()));
    }
    if r.reading {
        spans.push(Span::styled("  reading", p.dim()));
    }
    let keys = format!(
        "  [ ] step  {{ }} problem{}",
        if graph { "  o graph" } else { "" }
    );
    spans.push(Span::styled(keys, p.dim()));
    let mut out = vec![Line::from(spans)];
    if let Some(e) = &r.error {
        out.push(Line::styled(format!("inbox, board: {e}"), p.bad()));
    }
    if r.absent {
        out.push(Line::styled("inbox, board: no snapshot", p.bad()));
    }
    out
}

/// The open step's lines: why it stopped, its counts, its problems, what it does not record.
fn detail(n: &Node, v: &LineView, p: Palette, out: &mut Vec<Line<'static>>) {
    if let Some(s) = &n.stop {
        out.push(Line::styled(format!("STOPPED {}: {s}", n.label), p.bad()));
    }
    for f in &n.facts {
        out.push(Line::raw(format!("  {f}")));
    }
    if n.problems_n > 0 {
        out.push(Line::styled(
            format!("  Problems, 24h: {}", n.problems_n),
            p.head(),
        ));
    }
    for (i, t) in n.problems.iter().take(SHOWN_PROBLEMS).enumerate() {
        out.push(if v.problem == Some(i) {
            Line::styled(format!("> {}", t.text), p.head())
        } else {
            Line::raw(format!("  {}", t.text))
        });
    }
    if let Some(g) = n.gap {
        out.push(Line::styled(format!("  {g}"), p.dim()));
    }
    if let Some(e) = &n.elsewhere {
        out.push(Line::styled(format!("  {e}"), p.dim()));
    }
}

fn width(n: &Node) -> usize {
    [UnicodeWidthStr::width(n.label), count(n).len(), n.sub.len()]
        .into_iter()
        .max()
        .unwrap_or(0)
}

fn pad(text: String, w: usize) -> String {
    format!("{text:<w$}")
}

/// The line across the page: labels joined by arrows, each step's count and age under its label.
fn wide(r: &Rail, at: usize, widths: &[usize], p: Palette, out: &mut Vec<Line<'static>>) {
    let mut labels = vec![];
    let mut counts = vec![];
    let mut subs = vec![];
    for (i, (n, w)) in r.nodes.iter().zip(widths).enumerate() {
        if i > 0 {
            labels.push(Span::styled(ARROW, p.dim()));
            counts.push(Span::raw(GAP));
            subs.push(Span::raw(GAP));
        }
        labels.push(Span::styled(pad(label(n, i == at), *w), style(n, p)));
        counts.push(Span::styled(pad(count(n), *w), style(n, p)));
        subs.push(Span::styled(pad(n.sub.clone(), *w), p.dim()));
    }
    let before: usize = widths[..at].iter().map(|w| w + ARROW.len()).sum();
    out.push(Line::from(labels));
    out.push(Line::from(counts));
    out.push(Line::from(subs));
    out.push(Line::styled(
        format!(
            "{}{}",
            " ".repeat(before),
            "^".repeat(r.nodes[at].label.len())
        ),
        p.dim(),
    ));
}

/// One step per line, for a page too narrow for the arrows; the open step's detail under it.
fn narrow(r: &Rail, at: usize, v: &LineView, p: Palette, out: &mut Vec<Line<'static>>) {
    for (i, n) in r.nodes.iter().enumerate() {
        let stopped = if n.stopped { "  STOPPED" } else { "" };
        out.push(Line::styled(
            format!(
                "{:<LABEL_COLS$} {:>5}  {}{stopped}",
                label(n, i == at),
                count(n),
                n.sub
            ),
            style(n, p),
        ));
        if i == at {
            detail(n, v, p, out);
        }
    }
}

pub fn lines(r: &Rail, v: &LineView, graph: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = header(r, graph, p);
    if !r.nodes.is_empty() {
        let at = v.at(r);
        let widths: Vec<usize> = r.nodes.iter().map(width).collect();
        let total = widths.iter().sum::<usize>() + ARROW.len() * (widths.len() - 1);
        if w == 0 || total <= w {
            wide(r, at, &widths, p, &mut out);
            detail(&r.nodes[at], v, p, &mut out);
        } else {
            narrow(r, at, v, p, &mut out);
        }
    }
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::flow::{Target, Trouble};

    const P: Palette = Palette { no_color: true };

    fn node(key: &'static str, label: &'static str, count: &str, sub: &str) -> Node {
        Node {
            key,
            label,
            count: Some(count.into()),
            sub: sub.into(),
            hot: false,
            stopped: false,
            to: Some(Target {
                tab: "queue",
                state: "",
            }),
            stop: None,
            facts: vec![],
            problems_n: 0,
            problems: vec![],
            gap: None,
            elsewhere: None,
        }
    }

    fn rail() -> Rail {
        let mut q = node("queued", "queued", "272", "p90 2.8d");
        (q.hot, q.stopped, q.stop) = (true, true, Some("Dispatch stopped 9h50m".into()));
        q.facts = vec!["272 items, bound 12h (5.7x)".into()];
        q.elsewhere = Some("Problems at running, 24h: 11".into());
        let mut run = node("running", "running", "9", "p90 20h");
        run.problems_n = 11;
        run.problems = vec![
            Trouble {
                text: "01:16  ucp-412  failed  died".into(),
                item: Some("ucp-412".into()),
            },
            Trouble {
                text: "00:01  a line  refused  no".into(),
                item: None,
            },
        ];
        Rail {
            nodes: vec![
                node("inbox", "inbox", "1", "ok"),
                node("board", "board", "1234", "p90 18.8d"),
                q,
                run,
                node("needs", "needs you", "7", "p90 1.2d"),
                node("done", "done 24h", "299", "24h"),
            ],
            worst: 2,
            as_of: Some("09:41".into()),
            ..Rail::default()
        }
    }

    fn text(r: &Rail, v: &LineView, w: usize) -> Vec<String> {
        lines(r, v, true, P, w)
            .iter()
            .map(|l| plain(l).trim_end().to_string())
            .collect()
    }

    #[test]
    fn at_80_columns_it_is_the_mockup_with_the_worst_step_open() {
        let t = text(&rail(), &LineView::default(), 80);
        assert_eq!(
            t[0],
            "PIPELINE  as of 09:41  [ ] step  { } problem  o graph"
        );
        assert_eq!(
            t[1],
            "inbox -> board     -> QUEUED   -> running -> needs you -> done 24h"
        );
        assert_eq!(
            t[2],
            "1        1234         !272        9          7            299"
        );
        assert_eq!(
            t[3],
            "ok       p90 18.8d    p90 2.8d    p90 20h    p90 1.2d     24h"
        );
        assert_eq!(t[4], "                      ^^^^^^");
        assert_eq!(t[5], "STOPPED queued: Dispatch stopped 9h50m");
        assert_eq!(t[6], "  272 items, bound 12h (5.7x)");
        assert_eq!(t[7], "  Problems at running, 24h: 11");
        assert!(t.iter().all(|l| l.chars().count() <= 80), "{t:?}");
    }

    #[test]
    fn at_phone_width_each_step_is_a_line_and_the_detail_sits_under_the_open_one() {
        let t = text(&rail(), &LineView::default(), 44);
        assert_eq!(t[1], "inbox         1  ok");
        assert_eq!(t[3], "QUEUED     !272  p90 2.8d  STOPPED");
        assert_eq!(t[4], "STOPPED queued: Dispatch stopped 9h50m");
        assert_eq!(t[7], "running       9  p90 20h");
        assert!(t.iter().all(|l| l.chars().count() <= 44), "{t:?}");
    }

    #[test]
    fn brackets_walk_the_steps_and_stop_at_the_ends_and_a_problem_opens_its_item() {
        let r = rail();
        let mut v = LineView::default();
        assert_eq!(v.key(KeyCode::Char('}'), &r), Took::No, "queued has none");
        assert_eq!(v.key(KeyCode::Char(']'), &r), Took::Moved);
        assert_eq!(r.nodes[v.at(&r)].key, "running");
        let mut moved = rail();
        let mut held = LineView {
            node: None,
            problem: None,
        };
        moved.worst = 3;
        held.key(KeyCode::Char('}'), &moved);
        moved.worst = 0;
        assert_eq!(
            moved.nodes[held.at(&moved)].key,
            "running",
            "a marked problem holds its step"
        );
        assert_eq!(v.key(KeyCode::Enter, &r), Took::No, "the table's Enter");
        v.key(KeyCode::Char('}'), &r);
        assert!(text(&r, &v, 80).iter().any(|l| l.starts_with("> 01:16")));
        assert_eq!(
            v.key(KeyCode::Enter, &r),
            Took::Open("ucp-412".into()),
            "the marked problem names its item"
        );
        v.key(KeyCode::Char('}'), &r);
        v.key(KeyCode::Char('}'), &r);
        assert_eq!(
            v.key(KeyCode::Enter, &r),
            Took::Moved,
            "an inbox line has no item"
        );
        v.key(KeyCode::Char('}'), &r);
        assert_eq!(v.key(KeyCode::Esc, &r), Took::Moved);
        assert_eq!(v.key(KeyCode::Esc, &r), Took::No, "then Esc is the table's");
        for _ in 0..9 {
            v.key(KeyCode::Char(']'), &r);
        }
        assert_eq!(r.nodes[v.at(&r)].key, "done");
        for _ in 0..9 {
            v.key(KeyCode::Char('['), &r);
        }
        assert_eq!(r.nodes[v.at(&r)].key, "inbox");
    }

    #[test]
    fn negative_control_a_bad_snapshot_says_so_in_the_line_and_never_a_zero() {
        let mut r = rail();
        (r.stale, r.as_of) = (true, Some("11-04 12:40".into()));
        assert!(text(&r, &LineView::default(), 80)[0].contains("as of 11-04 12:40 (stale)"));
        (r.stale, r.as_of) = (true, None);
        assert!(text(&r, &LineView::default(), 80)[0].contains("age unknown"));
        r.error = Some("snapshot cannot be read".into());
        r.absent = true;
        r.nodes[1].count = None;
        let t = text(&r, &LineView::default(), 80);
        assert_eq!(t[1], "inbox, board: snapshot cannot be read");
        assert_eq!(t[2], "inbox, board: no snapshot");
        assert!(t[4].contains('-') && !t[4].contains('0'), "{t:?}");
    }
}
