//! One machine's page in place of Infra's Machines tab, drawn from the page `hub_core` reads for
//! both surfaces (`hub_core::machine_page`): its parts, the cores each pool uses there, the CI
//! jobs running there, its last days of CPU and downtime, the CI jobs that ran there and the
//! alerts that name it. agent-web draws the same page at `#infra/machines/<host>`.

use hub_core::host_history::{HostHistory, PowerHistory, DAYS};
use hub_core::machine_page::{MachinePage, RecentJob};
use ratatui::text::{Line, Span};

use crate::controls::{dash, page_field};
use crate::fit::{cell, clip_line, Table};
use crate::fmt::{bar, clock, dur, Palette};

/// The page's own keys, as its heading says them.
pub const PAGE_KEYS: &str = "[Esc all machines  o Grafana]";

/// Recent CI jobs drawn before `+N more`.
const RECENT_ROWS: usize = 15;
/// Power changes shown before "+N older".
const POWER_ROWS: usize = 10;

/// Width of a share bar.
const SHARE_BAR: usize = 30;

/// The CPU chart's rows, one character a bucket of hours; a pool's page draws with them too.
pub(crate) const BLOCKS: [char; 9] = [
    ' ', '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}', '\u{2587}',
    '\u{2588}',
];

/// The page for `host`: reading, why it could not be read, or each of its parts.
pub fn page(
    host: &str,
    r: Option<&Result<MachinePage, String>>,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let page = match r {
        None => return vec![Line::styled(format!("Reading {host}..."), p.dim())],
        Some(Err(e)) => {
            return vec![
                clip_line(Line::styled(e.clone(), p.warn()), w),
                Line::styled(format!("  {PAGE_KEYS}"), p.dim()),
            ]
        }
        Some(Ok(m)) => m,
    };
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(page.host.to_uppercase(), p.head()),
            Span::styled(
                format!(
                    "  {}  read {}  {PAGE_KEYS}",
                    page.head,
                    clock(page.at as i64, now)
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    for e in &page.errors {
        out.push(clip_line(Line::styled(format!("  {e}"), p.warn()), w));
    }
    for part in &page.parts {
        out.push(page_field(part, p, w));
    }
    let blank = || Line::raw("");
    out.push(blank());
    out.extend(share(page, p, w));
    out.push(blank());
    out.extend(running(page, p, w));
    out.push(blank());
    match &page.history {
        Some(h) => {
            out.extend(history(h, p, now, w));
            out.push(blank());
            out.extend(downtime(h, p, now, w));
            if let Some(pw) = &h.power {
                out.push(blank());
                out.extend(power(pw, p, now));
            }
        }
        None => out.push(heading(
            &format!("{DAYS} DAYS"),
            hub_core::reading::NOT_READ,
            p,
        )),
    }
    out.push(blank());
    out.extend(recent(&page.recent, p, now, w));
    out.push(blank());
    out.extend(alerts(page, p, now, w));
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

pub(crate) fn heading(title: &str, rest: impl Into<String>, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(format!("  {}", rest.into()), p.dim()),
    ])
}

/// Cores per pool, then other and idle, each a bar of its cores.
fn share(page: &MachinePage, p: Palette, w: usize) -> Vec<Line<'static>> {
    let Some(cores) = page.cores.filter(|c| *c > 0.0) else {
        return vec![heading("SHARE", "no reading of its cores", p)];
    };
    let mut out = vec![heading("SHARE", format!("of its {cores:.0} cores"), p)];
    let width = SHARE_BAR.min(w.saturating_sub(30)).max(5);
    for s in &page.share {
        let pc = (s.cores / cores * 100.0).round().clamp(0.0, 100.0) as u32;
        let (on, off) = bar(Some(pc), None, width);
        out.push(Line::from(vec![
            Span::raw(format!("  {:<14} {:>5.1} ", s.what, s.cores)),
            Span::styled(format!("[{on}"), p.good()),
            Span::styled(format!("{off}]"), p.dim()),
            Span::raw(format!(" {pc}%")),
        ]));
    }
    out
}

/// The governor's hours per UTC day and its newest changes of power state, as on the web.
fn power(pw: &PowerHistory, p: Palette, now: i64) -> Vec<Line<'static>> {
    let days: Vec<String> = pw
        .days
        .iter()
        .map(|d| format!("{} {:.1}h", d.day.get(5..).unwrap_or(&d.day), d.hours))
        .collect();
    let mut out = vec![
        heading("POWER", "hours run per UTC day, newest change first", p),
        Line::raw(format!(
            "  {}",
            if days.is_empty() {
                "no samples".to_string()
            } else {
                days.join("  ")
            }
        )),
    ];
    for c in pw.changes.iter().rev().take(POWER_ROWS) {
        let why = if c.reason == "none" { "" } else { &c.reason };
        out.push(Line::raw(format!(
            "  {:<12} {:<10} {why}",
            clock(c.at as i64, now),
            c.state
        )));
    }
    if pw.changes.len() > POWER_ROWS {
        out.push(Line::styled(
            format!("  +{} older on the web page", pw.changes.len() - POWER_ROWS),
            p.dim(),
        ));
    }
    out
}

/// Its busy CI slots and local gates.
fn running(page: &MachinePage, p: Palette, w: usize) -> Vec<Line<'static>> {
    if page.running.is_empty() {
        return vec![heading("RUNNING", "no CI job runs here", p)];
    }
    let mut out = vec![heading(
        "RUNNING",
        format!("{} jobs", page.running.len()),
        p,
    )];
    out.extend(
        Table {
            header: vec!["JOB", "POOL", "SLOT", "RAN", "USUAL", "REF"],
            rows: page
                .running
                .iter()
                .map(|s| {
                    let ran = s.ran.map_or("-".into(), |r| dur(r as f64));
                    vec![
                        dash(&s.job),
                        dash(&s.pool),
                        dash(&s.slot),
                        if s.late {
                            cell(ran, p.warn())
                        } else {
                            ran.into()
                        },
                        s.usual.map_or("-".into(), |u| dur(u as f64).into()),
                        dash(&s.reference()),
                    ]
                })
                .collect(),
            keep: vec![0, 1, 3, 2, 4, 5],
            right: vec![3, 4],
            flex: Some(0),
            flexmin: 12,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out
}

/// Its CPU over the window, one block per bucket of hours, an empty hour a `.`.
fn history(h: &HostHistory, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let days = (h.to.saturating_sub(h.from) / 86_400).max(1);
    let mut out = vec![heading(
        &format!("{days} DAYS"),
        format!(
            "cpu by hour from {}, {} readings",
            clock(h.from as i64, now),
            h.readings
        ),
        p,
    )];
    if h.hours.is_empty() {
        out.push(Line::styled("  no reading in the window", p.dim()));
        return out;
    }
    // One column per bucket of hours, so the whole window fits the width.
    let room = w.saturating_sub(4).max(1);
    let per = h.hours.len().div_ceil(room).max(1);
    let chart: String = h
        .hours
        .chunks(per)
        .map(|c| {
            let read: Vec<f64> = c.iter().filter_map(|x| x.cpu).collect();
            if read.is_empty() {
                return '.';
            }
            let cpu = read.iter().sum::<f64>() / read.len() as f64;
            BLOCKS[((cpu.clamp(0.0, 1.0) * 8.0).round() as usize).max(1)]
        })
        .collect();
    out.push(Line::raw(format!("  {chart}")));
    let gaps = h.hours.iter().filter(|x| x.seen < 1.0).count();
    out.push(Line::styled(
        format!(
            "  {} hours a column; {gaps} of {} hours had a gap",
            per,
            h.hours.len()
        ),
        p.dim(),
    ));
    out
}

/// The stretches with no reading, newest first.
fn downtime(h: &HostHistory, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if h.down.is_empty() {
        return vec![heading("DOWNTIME", "none in the window", p)];
    }
    let mut out = vec![heading(
        "DOWNTIME",
        format!("{} stretches", h.down.len()),
        p,
    )];
    out.extend(
        Table {
            header: vec!["FROM", "TO", "TOOK", "WHY"],
            rows: h
                .down
                .iter()
                .map(|d| {
                    vec![
                        clock(d.from as i64, now).into(),
                        if d.open {
                            cell("now", p.warn())
                        } else {
                            clock(d.to as i64, now).into()
                        },
                        dur(d.to.saturating_sub(d.from) as f64).into(),
                        d.why.clone().into(),
                    ]
                })
                .collect(),
            keep: vec![0, 2, 1, 3],
            right: vec![2],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out
}

/// The CI jobs that ran there, newest first, a failure in red.
fn recent(rows: &[RecentJob], p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if rows.is_empty() {
        return vec![heading("RECENT CI JOBS", "none in the jobs archive", p)];
    }
    let mut out = vec![heading("RECENT CI JOBS", format!("last {}", rows.len()), p)];
    out.extend(
        Table {
            header: vec!["STARTED", "REPO", "JOB", "RUNNER", "CONCLUSION", "TOOK"],
            rows: rows
                .iter()
                .take(RECENT_ROWS)
                .map(|j| {
                    let c = match j.conclusion.as_str() {
                        "" => cell("running", p.dim()),
                        "failure" => cell("failure", p.bad()),
                        "success" => cell("success", p.good()),
                        s => s.to_string().into(),
                    };
                    vec![
                        j.started.map_or("-".into(), |t| clock(t, now).into()),
                        dash(&j.repo),
                        dash(&j.job),
                        dash(&j.runner),
                        c,
                        j.took.map_or("-".into(), |t| dur(t as f64).into()),
                    ]
                })
                .collect(),
            keep: vec![2, 4, 0, 5, 1, 3],
            right: vec![5],
            flex: Some(2),
            flexmin: 12,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    if rows.len() > RECENT_ROWS {
        out.push(Line::styled(
            format!("  +{} more on the web page", rows.len() - RECENT_ROWS),
            p.dim(),
        ));
    }
    out
}

/// The firing alerts that name it.
fn alerts(page: &MachinePage, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if page.alerts.is_empty() {
        return vec![heading("ALERTS", "none names it", p)];
    }
    let mut out = vec![heading(
        "ALERTS",
        format!("{} firing", page.alerts.len()),
        p,
    )];
    out.extend(
        Table {
            header: vec!["WHAT", "SEV", "STATE", "SINCE", "OWNER"],
            rows: page
                .alerts
                .iter()
                .map(|a| {
                    vec![
                        a.what.clone().into(),
                        dash(&a.sev),
                        dash(&a.state),
                        a.since.map_or("-".into(), |t| clock(t, now).into()),
                        dash(&a.owner),
                    ]
                })
                .collect(),
            keep: vec![0, 2, 1, 3, 4],
            flex: Some(0),
            flexmin: 16,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrapage::InfraPage;
    use hub_core::ci::Slot;
    use hub_core::host_history::{Change, Day, Down, Hour};
    use hub_core::links::Link;
    use hub_core::machine_page::Share;
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

    fn fixture() -> MachinePage {
        MachinePage {
            host: "workstation".into(),
            head: "workstation, local, up".into(),
            parts: vec![
                Part::new("Now", "cpu 62%, load 12.0 of 24 cores"),
                Part::new("Grafana", "its fleet board").link(Link::Url(
                    "https://g/d/kb-fleet?var-host=workstation".into(),
                )),
            ],
            cores: Some(24.0),
            share: vec![
                Share {
                    what: "unity".into(),
                    cores: 6.0,
                    link: None,
                },
                Share {
                    what: "idle".into(),
                    cores: 9.0,
                    link: None,
                },
            ],
            running: vec![Slot {
                host: "workstation".into(),
                slot: "1".into(),
                pool: "unity".into(),
                state: "busy".into(),
                job: "EditMode".into(),
                ran: Some(300),
                ..Slot::default()
            }],
            history: Some(HostHistory {
                host: "workstation".into(),
                from: 0,
                to: 7 * 86_400,
                hours: (0..168)
                    .map(|i| Hour {
                        at: i * 3600,
                        cpu: (i % 10 != 0).then_some(0.5),
                        seen: if i % 10 == 0 { 0.0 } else { 1.0 },
                        ..Hour::default()
                    })
                    .collect(),
                down: vec![Down {
                    from: 3600,
                    to: 7200,
                    open: false,
                    why: "no reading".into(),
                }],
                power: Some(PowerHistory {
                    changes: vec![Change {
                        at: 7200,
                        state: "running".into(),
                        reason: "queue".into(),
                    }],
                    days: vec![Day {
                        day: "2026-11-10".into(),
                        hours: 3.5,
                    }],
                    host: "workstation".into(),
                    from: 0,
                    to: 7 * 86_400,
                    step: 120,
                }),
                ..HostHistory::default()
            }),
            recent: vec![RecentJob {
                run_id: 7,
                repo: "dotfiles".into(),
                job: "bats".into(),
                runner: "workstation-1".into(),
                conclusion: "failure".into(),
                ..RecentJob::default()
            }],
            ..MachinePage::default()
        }
    }

    #[test]
    fn the_page_draws_every_part_from_the_one_reader() {
        let page = fixture();
        let t = text(&page_lines(&page));
        for want in [
            "WORKSTATION",
            "workstation, local, up",
            "cpu 62%",
            "var-host=workstation",
            "SHARE",
            "of its 24 cores",
            "unity",
            "25%",
            "RUNNING",
            "EditMode",
            "7 DAYS",
            "DOWNTIME",
            "no reading",
            "POWER",
            "11-10 3.5h",
            "queue",
            "RECENT CI JOBS",
            "bats",
            "failure",
            "ALERTS",
            "none names it",
        ] {
            assert!(t.contains(want), "{want} in:\n{t}");
        }
        assert_eq!(
            InfraPage::Machine(String::new(), Some(Ok(page)))
                .grafana()
                .as_deref(),
            Some("https://g/d/kb-fleet?var-host=workstation")
        );
    }

    #[test]
    fn an_unknown_host_says_so_and_a_page_not_read_yet_says_reading() {
        let p = Palette::from_env();
        let err = Err("no machine named nope".to_string());
        let t = text(&page("nope", Some(&err), p, 0, 120));
        assert!(t.contains("no machine named nope"), "{t}");
        assert!(text(&page("nope", None, p, 0, 120)).contains("Reading nope..."));
    }

    #[test]
    fn a_machine_with_no_reading_shows_why_and_no_share() {
        let page = MachinePage {
            host: "mac-mini".into(),
            parts: vec![Part::new(
                "Now",
                "no reading: Prometheus has no node exporter series for it",
            )
            .warn(true)],
            ..MachinePage::default()
        };
        let t = text(&page_lines(&page));
        assert!(
            t.contains("no reading: Prometheus has no node exporter series"),
            "{t}"
        );
        assert!(t.contains("no reading of its cores"), "{t}");
        assert!(t.contains("not read"), "no history read: {t}");
    }

    fn page_lines(m: &MachinePage) -> Vec<Line<'static>> {
        page(
            &m.host,
            Some(&Ok(m.clone())),
            Palette::from_env(),
            7 * 86_400,
            200,
        )
    }
}
