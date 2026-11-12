//! One runner pool's page in place of Infra's Machines tab, drawn from the page `hub_core` reads
//! for both surfaces (`hub_core::pool_page`): its parts and the governor's bounds, the machines
//! with a slot in it, the CI jobs waiting for it, and its busy and waiting over the last days.
//! agent-web draws the same page at `#infra/pools/<pool>`.

use hub_core::host_history::DAYS;
use hub_core::pool_page::{PoolHistory, PoolPage};
use ratatui::text::{Line, Span};

use crate::controls::page_field;
use crate::fit::clip_line;
use crate::fmt::{clock, Palette};
use crate::machinetab::{heading, BLOCKS};

/// The page's own keys, as its heading says them.
pub const PAGE_KEYS: &str = "[Esc all pools  o Grafana]";

/// The page for `pool`: reading, why it could not be read, or each of its parts.
pub fn page(
    pool: &str,
    r: Option<&Result<PoolPage, String>>,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let page = match r {
        None => return vec![Line::styled(format!("Reading {pool}..."), p.dim())],
        Some(Err(e)) => {
            return vec![
                clip_line(Line::styled(e.clone(), p.warn()), w),
                Line::styled(format!("  {PAGE_KEYS}"), p.dim()),
            ]
        }
        Some(Ok(x)) => x,
    };
    let mut out = vec![Line::from(vec![
        Span::styled(page.pool.to_uppercase(), p.head()),
        Span::styled(
            format!(
                "  {}  read {}  {PAGE_KEYS}",
                page.head,
                clock(page.at as i64, now)
            ),
            p.dim(),
        ),
    ])];
    for e in &page.errors {
        out.push(Line::styled(format!("  {e}"), p.warn()));
    }
    for part in &page.parts {
        out.push(page_field(part, p, w));
    }
    out.push(Line::raw(""));
    out.extend(crate::infratables::page_tables(
        &page.machines,
        &page.waiting,
        p,
        now,
        w,
    ));
    out.push(Line::raw(""));
    match &page.history {
        Some(h) => out.extend(history(h, p, now, w)),
        None => out.push(heading(&format!("{DAYS} DAYS"), "not read", p)),
    }
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

/// Its busy share of its slots and the most jobs waiting, one block per bucket of hours, an
/// hour with no reading a `.`.
fn history(h: &PoolHistory, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let days = (h.to.saturating_sub(h.from) / 86_400).max(1);
    let mut out = vec![heading(
        &format!("{days} DAYS"),
        format!(
            "by hour from {}, {} readings",
            clock(h.from as i64, now),
            h.readings
        ),
        p,
    )];
    if h.hours.is_empty() {
        out.push(Line::styled("  no reading in the window", p.dim()));
        return out;
    }
    let room = w.saturating_sub(12).max(1);
    let per = h.hours.len().div_ceil(room).max(1);
    let block = |v: f64| match v {
        v if v <= 0.0 => BLOCKS[0],
        v => BLOCKS[((v.clamp(0.0, 1.0) * 8.0).round() as usize).max(1)],
    };
    let busy: String = h
        .hours
        .chunks(per)
        .map(|c| {
            let (b, s): (f64, f64) = c
                .iter()
                .filter_map(|x| Some((x.busy?, x.slots?)))
                .fold((0.0, 0.0), |a, x| (a.0 + x.0, a.1 + x.1));
            if s > 0.0 {
                block(b / s)
            } else if c.iter().any(|x| x.slots.is_some()) {
                BLOCKS[0]
            } else {
                '.'
            }
        })
        .collect();
    let most = h.hours.iter().filter_map(|x| x.waiting).fold(0.0, f64::max);
    let waiting: String = h
        .hours
        .chunks(per)
        .map(
            |c| match c.iter().filter_map(|x| x.waiting).reduce(f64::max) {
                None => '.',
                Some(v) => block(v / most.max(1.0)),
            },
        )
        .collect();
    out.push(Line::from(vec![
        Span::styled("  busy    ", p.dim()),
        Span::raw(busy),
    ]));
    out.push(Line::from(vec![
        Span::styled("  waiting ", p.dim()),
        Span::styled(waiting, p.warn()),
    ]));
    out.push(Line::styled(
        format!(
            "  {per} hours a column; busy is its share of the slots, waiting up to {most:.0} jobs"
        ),
        p.dim(),
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrapage::InfraPage;
    use hub_core::ci::Queued;
    use hub_core::links::Link;
    use hub_core::machines::Machine;
    use hub_core::pool_page::PoolHour;
    use hub_core::session_page::Part;

    fn text(lines: &[Line]) -> String {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn fixture() -> PoolPage {
        PoolPage {
            pool: "unity".into(),
            head: "unity, 1/3 busy, 2 waiting".into(),
            parts: vec![
                Part::new("Waiting", "2 jobs, the oldest 15m").warn(true),
                Part::new("Grafana", "the CI runners board")
                    .link(Link::Url("https://g/d/kb-ci-runners".into())),
            ],
            machines: vec![Machine {
                host: "workstation".into(),
                place: "local".into(),
                state: "up".into(),
                ..Default::default()
            }],
            waiting: vec![Queued {
                job: "Tests".into(),
                pool: "unity".into(),
                needs: vec!["unity".into()],
                stuck: true,
                ..Default::default()
            }],
            history: Some(PoolHistory {
                from: 0,
                to: 3 * 3600,
                step: 120,
                bucket: 3600,
                readings: 30,
                hours: vec![
                    PoolHour {
                        at: 0,
                        busy: Some(3.0),
                        slots: Some(3.0),
                        waiting: Some(4.0),
                    },
                    PoolHour {
                        at: 3600,
                        busy: Some(0.0),
                        slots: Some(3.0),
                        waiting: Some(0.0),
                    },
                    PoolHour {
                        at: 7200,
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn the_page_draws_its_parts_machines_waiting_jobs_and_days() {
        let f = fixture();
        let t = text(&page(
            "unity",
            Some(&Ok(f.clone())),
            Palette::default(),
            7200,
            120,
        ));
        assert!(t.starts_with("UNITY  unity, 1/3 busy, 2 waiting"), "{t}");
        assert!(t.contains("2 jobs, the oldest 15m"), "{t}");
        assert!(t.contains("MACHINES") && t.contains("workstation"), "{t}");
        assert!(
            t.contains("WAITING") && t.contains("Tests") && t.contains("nobody"),
            "{t}"
        );
        assert!(
            t.contains("  busy    \u{2588} ."),
            "a full hour, an idle one, then one with no reading: {t}"
        );
        assert!(t.contains("  waiting \u{2588} ."), "{t}");
        assert_eq!(
            InfraPage::Pool(String::new(), Some(Ok(f)))
                .grafana()
                .as_deref(),
            Some("https://g/d/kb-ci-runners")
        );
    }

    #[test]
    fn a_name_no_pool_has_says_so_and_how_back() {
        let t = text(&page(
            "nope",
            Some(&Err("no pool named nope".into())),
            Palette::default(),
            0,
            80,
        ));
        assert!(
            t.contains("no pool named nope") && t.contains("Esc all pools"),
            "{t}"
        );
        assert!(text(&page("unity", None, Palette::default(), 0, 80)).contains("Reading unity"));
    }
}
