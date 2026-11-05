//! The Home tab: what needs you, what is running, the numbers and the health strip, from
//! `hub_core::home` (the reader agent-web's Home uses too), then the machines and pools that
//! were the Overview's body until the Infra tab takes them (docs/dashboards.md "Hub layout").

use hub_core::home::{Home, Kind, Level};
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, wrap, Table};
use crate::fmt::{clock, dur, Palette};

fn kind(k: Kind) -> &'static str {
    match k {
        Kind::Ask => "ask",
        Kind::Session => "session",
        Kind::Queue => "queue",
        Kind::Nightly => "nightly",
        Kind::Red => "red",
    }
}

fn age(since: Option<i64>, now: i64) -> String {
    since.map_or("-".into(), |t| dur((now - t).max(0) as f64))
}

/// The Home sections, top to bottom; the caller adds the infra body under them.
pub fn page(h: &Home, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &h.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }

    if h.needs.is_empty() {
        out.push(Line::from(vec![
            Span::styled("NEEDS YOU  ", p.head()),
            Span::styled("nothing waits on you", p.dim()),
        ]));
    } else {
        out.push(Line::styled(
            format!("NEEDS YOU ({})", h.needs.len()),
            p.head(),
        ));
        let t = Table {
            header: vec!["KIND", "PROJECT", "AGE", "WHAT", "ID"],
            rows: h
                .needs
                .iter()
                .map(|n| {
                    let style = match n.kind {
                        Kind::Nightly | Kind::Red => p.bad(),
                        _ => ratatui::style::Style::new(),
                    };
                    vec![
                        cell(kind(n.kind), style),
                        n.project.clone().into(),
                        age(n.since, now).into(),
                        n.text.clone().into(),
                        // A red or nightly row is its own id: say it once.
                        if n.id == n.text {
                            "".into()
                        } else {
                            n.id.clone().into()
                        },
                    ]
                })
                .collect(),
            keep: vec![0, 3, 1, 2, 4],
            flex: Some(3),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(1, 22), (4, 34)],
        };
        out.extend(t.fit(w, p.dim()));
    }

    out.push(Line::raw(""));
    if h.running.is_empty() {
        out.push(Line::from(vec![
            Span::styled("RUNNING  ", p.head()),
            Span::styled("nothing running from the queue", p.dim()),
        ]));
    } else {
        out.push(Line::styled(
            format!("RUNNING ({})", h.running.len()),
            p.head(),
        ));
        let t = Table {
            header: vec!["ITEM", "PROJECT", "PHASE", "NEXT", "ETA"],
            rows: h
                .running
                .iter()
                .map(|r| {
                    let ph = r.phases.as_ref();
                    let eta = ph.and_then(|x| x.eta_epoch).map_or("-".into(), |e| {
                        let s = clock(e, now);
                        if e < now {
                            cell(format!("{s} late"), p.warn())
                        } else {
                            s.into()
                        }
                    });
                    vec![
                        r.title.clone().into(),
                        r.project.clone().into(),
                        ph.map_or("-".into(), |x| format!("{}/{}", x.done, x.total))
                            .into(),
                        ph.and_then(|x| x.next.clone()).unwrap_or("-".into()).into(),
                        eta,
                    ]
                })
                .collect(),
            keep: vec![0, 2, 4, 1, 3],
            flex: Some(0),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(1, 22), (3, 40)],
        };
        out.extend(t.fit(w, p.dim()));
    }

    out.push(Line::raw(""));
    let nums: Vec<String> = h
        .numbers
        .iter()
        .map(|n| format!("{} {}", n.label, n.value))
        .collect();
    for (i, l) in wrap(&nums, " | ", w.saturating_sub(9))
        .into_iter()
        .enumerate()
    {
        let head = if i == 0 { "NUMBERS  " } else { "         " };
        out.push(Line::from(vec![Span::styled(head, p.head()), Span::raw(l)]));
    }

    // Green collapses to one line; only the chips that are not green are drawn.
    let mut strip = vec![Span::styled("HEALTH   ", p.head())];
    if h.health.is_empty() {
        strip.push(Span::styled("no data", p.dim()));
    } else if h.exceptions().next().is_none() {
        strip.push(Span::styled(
            format!("all green ({})", h.health.len()),
            p.good(),
        ));
    } else {
        for c in h.exceptions() {
            let v = match c.level {
                Level::Ok => Some(0.0),
                Level::Warn => Some(1.0),
                Level::Red => Some(2.0),
                Level::Nodata => None,
            };
            let (style, word) = p.status(v);
            strip.push(Span::styled(format!(" {} {word} ", c.name), style));
            strip.push(Span::raw(" "));
        }
        let ok = h.health.len() - h.exceptions().count();
        strip.push(Span::styled(format!("{ok} green"), p.dim()));
    }
    out.push(clip_line(Line::from(strip), w));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::home::{Chip, Need, Number};

    fn home() -> Home {
        Home {
            needs: vec![Need {
                kind: Kind::Ask,
                project: "dodginballs".into(),
                text: "Which lobby?".into(),
                id: "a1".into(),
                target: None,
                since: Some(1_000 - 120),
            }],
            numbers: vec![Number {
                label: "queue",
                value: "1 running, 2 up next".into(),
            }],
            health: vec![
                Chip {
                    name: "k3s".into(),
                    level: Level::Ok,
                },
                Chip {
                    name: "ci".into(),
                    level: Level::Warn,
                },
            ],
            ..Default::default()
        }
    }

    fn text(h: &Home) -> String {
        page(h, Palette { no_color: true }, 1_000, 120)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn needs_come_first_and_only_the_chips_that_are_not_green_are_drawn() {
        let out = text(&home());
        assert!(out.starts_with("NEEDS YOU (1)"), "{out}");
        assert!(out.contains("ask") && out.contains("dodginballs") && out.contains("2m"));
        assert!(out.contains("RUNNING  nothing running from the queue"));
        assert!(out.contains("NUMBERS  queue 1 running, 2 up next"));
        assert!(
            out.contains(" ci WARN ") && out.contains("1 green"),
            "{out}"
        );
        assert!(!out.contains("k3s"), "green chips collapse: {out}");
    }

    #[test]
    fn an_all_green_strip_is_one_line_and_nothing_waiting_says_so() {
        let mut h = home();
        h.needs.clear();
        h.health.retain(|c| c.level == Level::Ok);
        let out = text(&h);
        assert!(out.contains("NEEDS YOU  nothing waits on you"));
        assert!(out.contains("HEALTH   all green (1)"));
    }
}
