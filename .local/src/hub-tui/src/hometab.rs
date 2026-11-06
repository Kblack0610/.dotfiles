//! The Home tab: what needs you, what analysis proposes, what is running, the numbers and the health strip, from
//! `hub_core::home` (the reader agent-web's Home uses too). The machines, pools and CI that sat
//! under it until phase 4 are the Infra tab's (docs/dashboards.md "Hub layout").

use hub_core::home::{Chip, Home, Kind, Level};
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, wrap, Table};
use crate::fmt::{clock, dur, Palette};

fn kind(k: Kind) -> &'static str {
    match k {
        Kind::Stopped => "stopped",
        Kind::Ask => "ask",
        Kind::Session => "session",
        Kind::Queue => "queue",
        Kind::Sheet => "sheet",
        Kind::Nightly => "nightly",
        Kind::Red => "red",
    }
}

pub(crate) fn age(since: Option<i64>, now: i64) -> String {
    since.map_or("-".into(), |t| dur((now - t).max(0) as f64))
}

/// The Home sections, top to bottom; the caller adds the infra body under them.
/// The "+N ..." line under a capped list, when rows were left out.
fn more(out: &mut Vec<Line<'static>>, len: usize, shown: usize, what: &str, p: Palette) {
    if len > shown {
        out.push(Line::styled(format!("+{} {what}", len - shown), p.dim()));
    }
}

pub fn page(h: &Home, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &h.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }

    // The summary leads (dashboards rule 3): two lines, so a long list never buries them.
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

    out.push(health_line(&h.health, p, w));
    out.push(Line::raw(""));

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
            mark: None,
            header: vec!["KIND", "PROJECT", "AGE", "HOLDS", "WHAT", "ID"],
            rows: h
                .needs
                .iter()
                .take(h.shown)
                .map(|n| {
                    // A row the judge said a machine can answer is dim and marked `~` (it ranks
                    // below every row only the human can act on).
                    let machine = n.score.as_ref().is_some_and(|s| !s.human);
                    let (mark, style) = match n.kind {
                        Kind::Stopped | Kind::Nightly | Kind::Red => ("", p.bad()),
                        _ if machine => ("~", p.dim()),
                        _ => ("", ratatui::style::Style::new()),
                    };
                    let holds = match &n.score {
                        Some(s) if !s.holds.is_empty() => s.holds.clone(),
                        Some(_) => "-".into(),
                        None => "".into(),
                    };
                    vec![
                        cell(format!("{mark}{}", kind(n.kind)), style),
                        n.project.clone().into(),
                        age(n.since, now).into(),
                        holds.into(),
                        if machine {
                            cell(n.text.clone(), p.dim())
                        } else {
                            n.text.clone().into()
                        },
                        // A red or nightly row is its own id: say it once.
                        if n.id == n.text {
                            "".into()
                        } else {
                            n.id.clone().into()
                        },
                    ]
                })
                .collect(),
            // The rank's two factors (AGE, HOLDS) outlast PROJECT as the page narrows.
            keep: vec![0, 4, 2, 3, 1, 5],
            flex: Some(4),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(1, 22), (3, 20), (5, 34)],
        };
        out.extend(t.fit(w, p.dim()));
        more(&mut out, h.needs.len(), h.shown, "more", p);
    }

    out.push(Line::raw(""));
    if h.proposals.is_empty() {
        out.push(Line::from(vec![
            Span::styled("PROPOSALS  ", p.head()),
            Span::styled(
                if h.proposals_failed {
                    "could not read them, see above"
                } else {
                    "nothing proposed"
                },
                p.dim(),
            ),
        ]));
    } else {
        out.push(Line::styled(
            format!("PROPOSALS ({})", h.proposals_head),
            p.head(),
        ));
        let t = Table {
            mark: None,
            header: vec!["STREAM", "PROJECT", "AGE", "PROPOSAL"],
            rows: h
                .proposals
                .iter()
                .take(h.shown)
                .map(|r| {
                    vec![
                        r.stream.clone().into(),
                        r.project.clone().into(),
                        age(r.at(), now).into(),
                        r.title.clone().into(),
                    ]
                })
                .collect(),
            keep: vec![3, 2, 0, 1],
            flex: Some(3),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(0, 18), (1, 18)],
        };
        out.extend(t.fit(w, p.dim()));
        more(&mut out, h.proposals.len(), h.shown, "more", p);
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
            mark: None,
            header: vec!["ITEM", "PROJECT", "PHASE", "NEXT", "ETA"],
            rows: h
                .running
                .iter()
                .take(h.shown)
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
        more(
            &mut out,
            h.running.len(),
            h.shown,
            "more on the Queue tab",
            p,
        );
    }

    out
}

/// The HEALTH line, Home's and Infra's: green collapses to one line, and only the chips that
/// are not green are drawn, then how many are green.
pub fn health_line(chips: &[Chip], p: Palette, w: usize) -> Line<'static> {
    let mut strip = vec![Span::styled("HEALTH   ", p.head())];
    let bad: Vec<&Chip> = chips.iter().filter(|c| c.level != Level::Ok).collect();
    if chips.is_empty() {
        strip.push(Span::styled("no data", p.dim()));
    } else if bad.is_empty() {
        strip.push(Span::styled(
            format!("all green ({})", chips.len()),
            p.good(),
        ));
    } else {
        for c in &bad {
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
        strip.push(Span::styled(
            format!("{} green", chips.len() - bad.len()),
            p.dim(),
        ));
    }
    clip_line(Line::from(strip), w)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::home::{Chip, Need, Number, Score};

    fn home() -> Home {
        Home {
            needs: vec![Need {
                kind: Kind::Ask,
                project: "dodginballs".into(),
                text: "Which lobby?".into(),
                id: "a1".into(),
                target: None,
                since: Some(1_000 - 120),
                recommend: None,
                score: Some(Score::new(true, true, 3, 0, 2)),
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
            shown: hub_core::home::SHOWN,
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
    fn the_summary_leads_and_only_the_chips_that_are_not_green_are_drawn() {
        let out = text(&home());
        assert!(
            out.starts_with("NUMBERS  queue 1 running, 2 up next"),
            "{out}"
        );
        let (num, need) = (
            out.find("HEALTH").unwrap(),
            out.find("NEEDS YOU (1)").unwrap(),
        );
        assert!(num < need, "health sits above the lists: {out}");
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

    #[test]
    fn a_long_needs_list_shows_the_cap_and_counts_the_rest() {
        let mut h = home();
        let one = h.needs[0].clone();
        h.needs = (0..h.shown + 3).map(|_| one.clone()).collect();
        let out = text(&h);
        assert_eq!(out.matches("Which lobby?").count(), h.shown, "{out}");
        assert!(out.contains("+3 more"), "{out}");
    }

    #[test]
    fn a_row_says_what_it_holds_and_a_machine_answerable_one_is_marked() {
        let mut h = home();
        let mut auto = h.needs[0].clone();
        auto.id = "b2".into();
        auto.text = "Keep the alias?".into();
        auto.score = Some(Score::new(false, false, 0, 0, 2));
        h.needs.push(auto);
        let out = text(&h);
        assert!(out.contains("HOLDS"), "{out}");
        assert!(out.contains("session, 3 phases"), "{out}");
        let line = out.lines().find(|l| l.contains("Keep the alias?")).unwrap();
        assert!(
            line.trim_start().starts_with("~ask") && line.contains(" - "),
            "{out}"
        );
        // The server's order is kept: the human's row first.
        assert!(
            out.find("Which lobby?") < out.find("Keep the alias?"),
            "{out}"
        );
    }
}
