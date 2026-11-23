//! One machine's page in place of Infra's Machines tab, drawn from the page `hub_core` reads for
//! both surfaces (`hub_core::machine_page`): its parts, every temperature sensor and fan, the
//! runner slots there with what each takes of it, the CI jobs running there, its pods, containers, busiest processes
//! and services, its last days of CPU, temperature and downtime, the CI jobs that ran there and
//! the alerts that name it. agent-web draws the same page at `#infra/machines/<host>`.

use hub_core::host_history::{HostHistory, Hour, PowerHistory, DAYS};
use hub_core::host_now::{bytes, tests_text, HostNow, Proc, Session, HOT_C};
use hub_core::machine_page::{MachinePage, RecentJob};
use hub_core::table::Row as _;
use ratatui::text::{Line, Span};

use crate::controls::{dash, page_field};
use crate::fit::{self, cell, clip_line, Table};
use crate::fmt::{clock, Palette};
use hub_core::display::fmt::dur_secs;

/// The page's own keys, as its heading says them.
pub const PAGE_KEYS: &str = "[Esc all machines  o Grafana]";

/// Recent CI jobs drawn before `+N more`.
const RECENT_ROWS: usize = 15;
/// Power changes shown before "+N older".
const POWER_ROWS: usize = 10;
/// The temperature chart's empty block, degrees C: an idle CPU sits above it, so the chart
/// spends its eight blocks on the range a machine works in.
const TEMP_FLOOR: f64 = 30.0;
/// Pods, containers or processes drawn before `+N more`.
const LIVE_ROWS: usize = 20;

/// The CPU chart's rows, one character a bucket of hours; a pool's page draws with them too.
pub(crate) const BLOCKS: [char; 9] = [
    ' ', '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}', '\u{2587}',
    '\u{2588}',
];

/// The block for a 0 to 1 share: the lowest one at least, so a reading never looks like none.
pub(crate) fn block(v: f64) -> char {
    BLOCKS[((v.clamp(0.0, 1.0) * 8.0).round() as usize).max(1)]
}

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
    match &page.live {
        Some(live) => out.extend(sensors(live, p, w)),
        None => out.push(heading("SENSORS", hub_core::reading::NOT_READ, p)),
    }
    out.push(blank());
    out.extend(slots(page, p, w));
    out.push(blank());
    out.extend(running(page, p, w));
    out.push(blank());
    if let Some(live) = &page.live {
        out.extend(pods(live, p, w));
        out.push(blank());
        out.extend(inventory(live, p, w));
        out.push(blank());
    }
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

/// Each runner with what it takes, what it does and what it uses, then the rest of the machine by class;
/// TAKES is the first column to go when the width runs short.
fn slots(page: &MachinePage, p: Palette, w: usize) -> Vec<Line<'static>> {
    if page.slots.is_empty() {
        return vec![heading("SLOTS", "no runner and no core reading", p)];
    }
    let runners: Vec<_> = page.slots.iter().filter(|s| s.runner).collect();
    let busy = runners.iter().filter(|s| s.now == "busy").count();
    let mut head = format!("{busy} of {} busy", runners.len());
    if let Some(age) = runners.iter().filter_map(|s| s.disk_age).reduce(f64::max) {
        head += &format!(", disk read {} ago", dur_secs(age));
    }
    let no = hub_core::reading::NO_DATA;
    let read = |t: String| {
        if t == no {
            cell(t, p.dim())
        } else {
            t.into()
        }
    };
    let mut out = vec![heading("SLOTS", head, p)];
    out.extend(
        Table {
            header: vec!["SLOT", "TAKES", "NOW", "JOB", "CORES", "MEM", "DISK"],
            rows: page
                .slots
                .iter()
                .map(|s| {
                    let name = if s.runner {
                        s.slot.clone().into()
                    } else {
                        cell(s.slot.clone(), p.dim())
                    };
                    vec![
                        name,
                        s.takes.join(" ").into(),
                        if s.now == "off" {
                            cell(s.now.clone(), p.warn())
                        } else {
                            s.now.clone().into()
                        },
                        if s.runner { dash(&s.job) } else { "".into() },
                        read(s.cores_text()),
                        read(s.mem_text()),
                        read(s.disk_text()),
                    ]
                })
                .collect(),
            keep: vec![0, 2, 4, 5, 6, 3, 1],
            right: vec![4, 5, 6],
            flex: Some(3),
            flexmin: 10,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
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
                    let ran = s.ran.map_or("-".into(), |r| dur_secs(r as f64));
                    vec![
                        dash(&s.job),
                        dash(&s.pool),
                        dash(&s.slot),
                        if s.late {
                            cell(ran, p.warn())
                        } else {
                            ran.into()
                        },
                        s.usual.map_or("-".into(), |u| dur_secs(u as f64).into()),
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
        out.push(Line::styled(
            format!("  {} in the window", hub_core::reading::NO_DATA),
            p.dim(),
        ));
        return out;
    }
    // One column per bucket of hours, so the whole window fits the width.
    let room = w.saturating_sub(9).max(1);
    let per = h.hours.len().div_ceil(room).max(1);
    out.push(Line::raw(format!(
        "  cpu  {}",
        chart(&h.hours, per, |c| {
            let read: Vec<f64> = c.iter().filter_map(|x| x.cpu).collect();
            (!read.is_empty()).then(|| read.iter().sum::<f64>() / read.len() as f64)
        })
    )));
    let hottest = h
        .hours
        .iter()
        .filter_map(|x| x.temp.map(|t| (t, x.at)))
        .max_by(|a, b| a.0.total_cmp(&b.0));
    if let Some((peak, at)) = hottest {
        // A column's hottest hour, from `TEMP_FLOOR` (an empty block) to 100C (a full one).
        out.push(Line::raw(format!(
            "  temp {}",
            chart(&h.hours, per, |c| {
                c.iter()
                    .filter_map(|x| x.temp)
                    .reduce(f64::max)
                    .map(|t| (t - TEMP_FLOOR) / (100.0 - TEMP_FLOOR))
            })
        )));
        let style = if peak >= HOT_C { p.warn() } else { p.dim() };
        out.push(Line::styled(
            format!(
                "  temp {TEMP_FLOOR:.0} to 100C; hottest {peak:.0}C, the hour from {}",
                clock(at as i64, now)
            ),
            style,
        ));
    }
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

/// One block per `per` hours, each `f` of those hours (a 0 to 1 share), an hour with none a `.`.
fn chart(hours: &[Hour], per: usize, f: impl Fn(&[Hour]) -> Option<f64>) -> String {
    hours
        .chunks(per)
        .map(|c| match f(c) {
            None => '.',
            Some(v) => block(v),
        })
        .collect()
}

/// `not read: <why>` when the part's query failed: its section is unknown, not empty.
fn unread(live: &HostNow, part: &str) -> Option<String> {
    let why = live.unread.get(part)?;
    Some(format!("{}: {why}", hub_core::reading::NOT_READ))
}

/// `0.70` cores, or `-`.
fn cores(c: Option<f64>) -> String {
    c.map_or("-".into(), |c| format!("{c:.2}"))
}

/// `+N more on the web page` when `n` rows were cut to `LIVE_ROWS`.
fn more(n: usize, p: Palette) -> Option<Line<'static>> {
    (n > LIVE_ROWS).then(|| {
        Line::styled(
            format!("  +{} more on the web page", n - LIVE_ROWS),
            p.dim(),
        )
    })
}

/// Every device's temperatures and fans, a hot one in amber.
fn sensors(live: &HostNow, p: Palette, w: usize) -> Vec<Line<'static>> {
    if let Some(why) = unread(live, "sensors") {
        return vec![heading("SENSORS", why, p)];
    }
    if live.devices.is_empty() {
        return vec![heading(
            "SENSORS",
            "none: its node exporter publishes no hwmon reading",
            p,
        )];
    }
    let mut out = vec![heading(
        "SENSORS",
        format!(
            "{}, amber at {HOT_C:.0}C",
            hub_core::display::fmt::counted(live.devices.len(), "device")
        ),
        p,
    )];
    out.extend(
        Table {
            header: vec!["DEVICE", "HOTTEST", "READINGS", "CHIP"],
            rows: live
                .devices
                .iter()
                .map(|d| {
                    let hot = d.hottest.map_or("-".into(), |c| format!("{c:.0}C"));
                    vec![
                        dash(&d.device),
                        if d.in_state("hot") {
                            cell(hot, p.warn())
                        } else {
                            hot.into()
                        },
                        dash(&d.readings()),
                        dash(&d.chip),
                    ]
                })
                .collect(),
            keep: vec![0, 1, 2, 3],
            right: vec![1],
            flex: Some(2),
            flexmin: 16,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out
}

/// Its Kubernetes pods, busiest first.
fn pods(live: &HostNow, p: Palette, w: usize) -> Vec<Line<'static>> {
    if let Some(why) = unread(live, "pods") {
        return vec![heading("PODS", why, p)];
    }
    if live.pods.is_empty() {
        return vec![heading("PODS", "none: no Kubernetes pod runs here", p)];
    }
    let cpu: f64 = live.pods.iter().filter_map(|x| x.cpu).sum();
    let mem: f64 = live.pods.iter().filter_map(|x| x.mem).sum();
    let mut out = vec![heading(
        "PODS",
        format!(
            "{} running, {} cores, {} together",
            live.pods.len(),
            cores(Some(cpu)),
            bytes(mem)
        ),
        p,
    )];
    out.extend(
        Table {
            header: vec!["POD", "NAMESPACE", "CPU", "MEM"],
            rows: live
                .pods
                .iter()
                .take(LIVE_ROWS)
                .map(|x| {
                    vec![
                        dash(&x.pod),
                        dash(&x.namespace),
                        cores(x.cpu).into(),
                        x.mem.map_or("-".into(), |m| bytes(m).into()),
                    ]
                })
                .collect(),
            keep: vec![0, 2, 3, 1],
            right: vec![2, 3],
            flex: Some(0),
            flexmin: 16,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(more(live.pods.len(), p));
    out
}

/// A table of processes or containers: name, then image or count, then CPU and memory.
fn procs(rows: &[Proc], image: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = Table {
        header: vec!["NAME", if image { "IMAGE" } else { "COUNT" }, "CPU", "MEM"],
        rows: rows
            .iter()
            .take(LIVE_ROWS)
            .map(|x| {
                vec![
                    dash(&x.name),
                    if image {
                        dash(&x.image)
                    } else {
                        x.count.map_or("-".into(), |n| format!("{n:.0}").into())
                    },
                    cores(x.cpu).into(),
                    x.mem.map_or("-".into(), |m| bytes(m).into()),
                ]
            })
            .collect(),
        keep: vec![0, 2, 3, 1],
        right: if image { vec![2, 3] } else { vec![1, 2, 3] },
        flex: Some(if image { 1 } else { 0 }),
        flexmin: 16,
        ..Default::default()
    }
    .fit(w, p.head());
    out.extend(more(rows.len(), p));
    out
}

/// Each agent session in its own scope: project, item, CPU, memory, then its test runs' cores.
fn sessions(rows: &[Session], p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = Table {
        header: vec!["PROJECT", "ITEM", "CPU", "MEM", "TESTS"],
        rows: rows
            .iter()
            .take(LIVE_ROWS)
            .map(|x| {
                vec![
                    dash(&x.project),
                    dash(&x.item),
                    cores(x.cpu).into(),
                    x.mem.map_or("-".into(), |m| bytes(m).into()),
                    dash(&tests_text(&x.tests)),
                ]
            })
            .collect(),
        keep: vec![0, 1, 2, 3, 4],
        right: vec![2, 3],
        flex: Some(4),
        flexmin: 12,
        ..Default::default()
    }
    .fit(w, p.head());
    out.extend(more(rows.len(), p));
    out
}

/// What runs outside Kubernetes: Docker containers, the busiest processes, agent sessions,
/// running services.
fn inventory(live: &HostNow, p: Palette, w: usize) -> Vec<Line<'static>> {
    if let Some(why) = unread(live, "inventory") {
        return vec![heading("CONTAINERS, PROCESSES, SERVICES", why, p)];
    }
    if !live.inventory {
        return vec![heading(
            "CONTAINERS, PROCESSES, SERVICES",
            "not collected: no node_inventory.prom (home-config role node-inventory-metrics)",
            p,
        )];
    }
    let mut out = vec![];
    if live.containers.is_empty() {
        out.push(heading("CONTAINERS", "no Docker container runs here", p));
    } else {
        out.push(heading(
            "CONTAINERS",
            format!("{} running in Docker", live.containers.len()),
            p,
        ));
        out.extend(procs(&live.containers, true, p, w));
    }
    out.push(Line::raw(""));
    let of = live
        .processes_total
        .map_or(String::new(), |t| format!(" of {t:.0} processes"));
    out.push(heading(
        "PROCESSES",
        format!(
            "the busiest {} names{of}, by cpu and memory",
            live.processes.len()
        ),
        p,
    ));
    out.extend(procs(&live.processes, false, p, w));
    out.push(Line::raw(""));
    if live.sessions.is_empty() {
        out.push(heading(
            "AGENT SESSIONS",
            "none runs in its own scope here",
            p,
        ));
    } else {
        out.push(heading(
            "AGENT SESSIONS",
            format!(
                "{} in their own scopes, the busiest first",
                live.sessions.len()
            ),
            p,
        ));
        out.extend(sessions(&live.sessions, p, w));
    }
    out.push(Line::raw(""));
    out.push(heading(
        "SERVICES",
        format!("{} systemd services running", live.services.len()),
        p,
    ));
    let lines = fit::wrap(&live.services, " ", w.saturating_sub(2));
    out.extend(lines.into_iter().map(|l| Line::raw(format!("  {l}"))));
    out
}

/// Its downtime records, newest first; an unexplained one in the warning colour.
fn downtime(h: &HostHistory, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if let Some(why) = &h.down_unread {
        let text = format!("{}: {why}", hub_core::reading::NOT_READ);
        return vec![heading("DOWNTIME", text, p)];
    }
    if h.down.is_empty() {
        let text = "no record in the window (one is written once a downtime ends)";
        return vec![heading("DOWNTIME", text, p)];
    }
    let mut out = vec![heading("DOWNTIME", format!("{} records", h.down.len()), p)];
    out.extend(
        Table {
            header: vec!["FROM", "TO", "TOOK", "CAUSE", "WHY"],
            rows: h
                .down
                .iter()
                .map(|d| {
                    vec![
                        clock(d.from as i64, now).into(),
                        clock(d.to as i64, now).into(),
                        dur_secs(d.to.saturating_sub(d.from) as f64).into(),
                        if d.in_state("unexplained") {
                            cell(&d.cause, p.warn())
                        } else {
                            d.cause.clone().into()
                        },
                        d.why.clone().into(),
                    ]
                })
                .collect(),
            keep: vec![0, 3, 2, 1, 4],
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
                        j.took.map_or("-".into(), |t| dur_secs(t as f64).into()),
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
    use hub_core::host_now::{Device, Pod};
    use hub_core::links::Link;
    use hub_core::machine_page::SlotUse;

    const GIB: f64 = 1024.0 * 1024.0 * 1024.0;
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
            slots: vec![
                SlotUse {
                    slot: "ms-a2-unity-1".into(),
                    takes: vec!["unity".into(), "light".into(), "heavy".into()],
                    now: "busy".into(),
                    job: "playground / test PlayMode".into(),
                    cores: Some(2.8),
                    cores_max: Some(3.0),
                    mem: Some(11.2 * GIB),
                    mem_max: Some(14.0 * GIB),
                    disk: Some(58.0 * GIB),
                    disk_age: Some(600.0),
                    runner: true,
                },
                SlotUse {
                    slot: "ms-a2-unity-2".into(),
                    now: "idle".into(),
                    runner: true,
                    ..SlotUse::default()
                },
                SlotUse {
                    slot: "free".into(),
                    cores: Some(9.0),
                    ..SlotUse::default()
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
                        temp: (i % 10 != 0).then_some(if i == 101 { 97.0 } else { 60.0 }),
                        ..Hour::default()
                    })
                    .collect(),
                down: vec![Down {
                    from: 3600,
                    to: 7200,
                    id: "workstation@1970-01-01T01:00:00Z".into(),
                    cause: "power".into(),
                    why: "13 hosts rebooted".into(),
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
            live: Some(HostNow {
                devices: vec![Device {
                    device: "cpu".into(),
                    chip: "k10temp".into(),
                    hottest: Some(96.0),
                    temps: vec![("Tctl".into(), 96.0), ("Tccd1".into(), 91.0)],
                    fans: vec![],
                }],
                pods: vec![Pod {
                    namespace: "frigate".into(),
                    pod: "frigate-0".into(),
                    cpu: Some(0.7),
                    mem: Some(2.5 * 1024.0 * 1024.0 * 1024.0),
                }],
                services: vec!["nfs-server".into(), "tailscaled".into()],
                containers: vec![Proc {
                    name: "mailpit".into(),
                    image: "axllent/mailpit".into(),
                    cpu: Some(0.01),
                    mem: Some(30e6),
                    count: None,
                }],
                processes: vec![Proc {
                    name: "Unity".into(),
                    cpu: Some(3.5),
                    mem: Some(8e9),
                    count: Some(2.0),
                    ..Proc::default()
                }],
                processes_total: Some(612.0),
                sessions: vec![Session {
                    scope: "agent-dotfiles-ar\\x2d4859-10.scope".into(),
                    project: "dotfiles".into(),
                    item: "ar-4859".into(),
                    cpu: Some(1.5),
                    mem: Some(2e9),
                    tests: vec![("bats".into(), 1.2)],
                }],
                inventory: true,
                unread: Default::default(),
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
            "SLOTS",
            "1 of 2 busy, disk read 10m ago",
            "unity light",
            "2.8/3",
            "11.2/14G",
            "58G",
            "TAKES",
            "RUNNING",
            "EditMode",
            "7 DAYS",
            "DOWNTIME",
            "13 hosts rebooted",
            "POWER",
            "11-10 3.5h",
            "queue",
            "SENSORS",
            "Tctl 96C  Tccd1 91C",
            "PODS",
            "frigate-0",
            "2.5G",
            "CONTAINERS",
            "axllent/mailpit",
            "PROCESSES",
            "of 612 processes",
            "Unity",
            "AGENT SESSIONS",
            "ar-4859",
            "bats 1.20",
            "SERVICES",
            "nfs-server tailscaled",
            "temp ",
            "hottest 97C",
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
    fn downtime_records_not_read_say_why_and_never_the_empty_text() {
        let mut page = fixture();
        let h = page.history.as_mut().unwrap();
        h.down.clear();
        let empty = text(&page_lines(&page));
        assert!(
            empty.contains("no record in the window (one is written once a downtime ends)"),
            "{empty}"
        );
        page.history.as_mut().unwrap().down_unread = Some("Loki answer 503".into());
        let unread = text(&page_lines(&page));
        assert!(
            unread.contains("DOWNTIME  not read: Loki answer 503"),
            "{unread}"
        );
        assert!(!unread.contains("no record in the window"), "{unread}");
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
    fn a_machine_with_no_reading_shows_why_and_no_slots() {
        let page = MachinePage {
            host: "mac-mini".into(),
            parts: vec![Part::new(
                "Now",
                "no data: Prometheus has no node exporter series for it",
            )
            .warn(true)],
            ..MachinePage::default()
        };
        let t = text(&page_lines(&page));
        assert!(
            t.contains("no data: Prometheus has no node exporter series"),
            "{t}"
        );
        assert!(t.contains("SLOTS  no runner and no core reading"), "{t}");
        assert!(t.contains("not read"), "no history read: {t}");
        assert!(t.contains("SENSORS  not read"), "{t}");
    }

    /// At 80 columns TAKES goes first; a slot with no reading says no data, never 0.
    #[test]
    fn slots_drop_takes_at_80_columns_and_say_no_data_for_a_slot_unread() {
        let page = fixture();
        let lines = super::page(
            &page.host,
            Some(&Ok(page.clone())),
            Palette::from_env(),
            7 * 86_400,
            80,
        );
        let t = text(&lines);
        assert!(!t.contains("TAKES"), "{t}");
        let row = t
            .lines()
            .find(|l| l.contains("ms-a2-unity-2"))
            .expect("its row");
        assert!(row.contains("no data"), "{row}");
        assert!(!row.contains(" 0"), "{row}");
        assert!(t.lines().all(|l| fit::len(l) <= 80), "{t}");
        let head = t.lines().find(|l| l.contains("SLOT ")).expect("its header");
        for col in ["NOW", "CORES", "MEM", "DISK"] {
            assert!(head.contains(col), "{col}: {head}");
        }
    }

    #[test]
    fn a_machine_without_the_inventory_collector_says_not_collected_not_none() {
        let page = MachinePage {
            host: "mac-mini".into(),
            live: Some(HostNow::default()),
            ..MachinePage::default()
        };
        let t = text(&page_lines(&page));
        assert!(t.contains("SENSORS  none: its node exporter"), "{t}");
        assert!(t.contains("PODS  none"), "{t}");
        assert!(t.contains("not collected: no node_inventory.prom"), "{t}");
        assert!(!t.contains("SERVICES  0"), "{t}");
    }

    #[test]
    fn a_part_prometheus_failed_says_not_read_not_none() {
        let why = |p: &str| (p.to_string(), "prometheus down".to_string());
        let page = MachinePage {
            host: "workstation".into(),
            live: Some(HostNow {
                unread: [why("sensors"), why("pods"), why("inventory")].into(),
                ..HostNow::default()
            }),
            ..MachinePage::default()
        };
        let t = text(&page_lines(&page));
        for h in ["SENSORS", "PODS", "CONTAINERS, PROCESSES, SERVICES"] {
            assert!(
                t.contains(&format!("{h}  not read: prometheus down")),
                "{h}: {t}"
            );
        }
        assert!(!t.contains("not collected"), "{t}");
        assert!(!t.contains("none:"), "{t}");
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
