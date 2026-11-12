//! One runner pool's page on both surfaces (`#infra/pools/<pool>`): its Pools row as labelled
//! parts, the governor's admitted bounds for it, the machines with a slot in it, the CI jobs
//! waiting for it, and its busy, slots and waiting over the last `DAYS` days. hub-core reads it;
//! agent-web and the TUI only draw it, as they draw a machine's page (`machine_page`).
//!
//! | part    | series                                                                          |
//! |---------|---------------------------------------------------------------------------------|
//! | history | `cc:pool_{busy,slots,waiting}{pool}`; the local gates (`unity-local`) sum `cc:host_local_{busy,open_slots,queued}` over the machines, a busy gate past the open slots still a slot, as `machines::pools` counts them |
//! | bounds  | the governor's `ci_governor_pool_admitted_{min,max}{pool}` (home-config apps/ci-runner-governor `pool_min_admitted`, `pool_max_admitted`) |

use serde::Serialize;

use crate::ci::Queued;
use crate::host_history::{self, BUCKET, DAYS, STEP};
use crate::infra::Infra;
use crate::links::Link;
use crate::machines::{Machine, Pool, LOCAL_POOL};
use crate::prom::{self, Series};
use crate::session_page::Part;
use crate::text::age;

/// What the page says for a name the Pools table does not have.
pub const NO_POOL: &str = "no pool named";
/// The Grafana board a pool's link opens, by its uid.
pub const BOARD: &str = "kb-ci-runners";

/// One hour of a pool's history: the means of its busy and slot samples, the most jobs waiting.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct PoolHour {
    /// Unix seconds the hour starts.
    pub at: u64,
    pub busy: Option<f64>,
    pub slots: Option<f64>,
    pub waiting: Option<f64>,
}

/// A pool's last `DAYS` days, one `PoolHour` per `BUCKET`.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct PoolHistory {
    pub pool: String,
    pub from: u64,
    pub to: u64,
    pub step: u64,
    pub bucket: u64,
    /// Oldest first.
    pub hours: Vec<PoolHour>,
    /// How many busy samples it gave: 0 is a pool with no reading in the window.
    pub readings: usize,
    /// `<part>: <why>` for each series that could not be read; the rest still show.
    pub errors: Vec<String>,
}

/// One pool's page.
#[derive(Serialize, Debug, Clone, Default)]
pub struct PoolPage {
    pub pool: String,
    /// When it was read, unix seconds.
    pub at: u64,
    /// The header line: `unity, 1/3 busy, 2 waiting`.
    pub head: String,
    pub row: Pool,
    pub parts: Vec<Part>,
    /// The machines with a slot in it, in the Machines table's order.
    pub machines: Vec<Machine>,
    /// The CI jobs waiting for it, as the queued table has them.
    pub waiting: Vec<Queued>,
    pub history: Option<PoolHistory>,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
}

/// The pool `name` names, as the Pools table has it.
pub fn find<'a>(infra: &'a Infra, name: &str) -> Result<&'a Pool, String> {
    infra
        .pools
        .iter()
        .find(|p| p.pool == name)
        .ok_or_else(|| format!("{NO_POOL} {name}"))
}

/// Read the page; the one error is a name no pool has. The pool comes from `infra`, its history
/// from Prometheus.
pub fn read(infra: &Infra, name: &str, now: u64) -> Result<PoolPage, String> {
    let p = find(infra, name)?;
    Ok(build(infra, p, history(&p.pool, now), now))
}

/// The page from what was read: pure, for the tests.
pub fn build(infra: &Infra, p: &Pool, history: Result<PoolHistory, String>, now: u64) -> PoolPage {
    let mut errors = vec![];
    let history = history
        .map(|mut h| {
            errors.append(&mut h.errors);
            h
        })
        .map_err(|e| errors.push(format!("history: {e}")))
        .ok();
    let machines: Vec<Machine> = infra
        .machines
        .iter()
        .filter(|m| p.machines.contains(&m.host))
        .cloned()
        .collect();
    let waiting: Vec<Queued> = infra
        .ci
        .queue
        .iter()
        .filter(|q| q.pool == p.pool)
        .cloned()
        .collect();
    let n = |v: Option<f64>| v.map_or("?".into(), |x| format!("{x:.0}"));
    PoolPage {
        pool: p.pool.clone(),
        at: now,
        head: format!(
            "{}, {}/{} busy, {} waiting",
            p.pool,
            n(p.busy),
            n(p.slots),
            n(p.waiting)
        ),
        row: p.clone(),
        parts: parts(infra, p, &machines, &waiting),
        machines,
        waiting,
        history,
        errors,
    }
}

/// The governor's bounds for `pool`, when it governs it: the fewest and most runners it keeps
/// admitted.
fn bounds(infra: &Infra, pool: &str) -> (Option<f64>, Option<f64>) {
    let get = |name: &str| {
        infra
            .get("governor")
            .iter()
            .find(|s| s.label("__name__") == name && s.label("pool") == pool)
            .and_then(|s| s.value)
    };
    (
        get("ci_governor_pool_admitted_min"),
        get("ci_governor_pool_admitted_max"),
    )
}

/// Its row as labelled parts: Slots, Waiting, Last 24h, Governor, Grafana.
fn parts(infra: &Infra, p: &Pool, machines: &[Machine], waiting: &[Queued]) -> Vec<Part> {
    let has = |v: Option<f64>| v.is_some_and(|x| x > 0.0);
    let n = |v: f64| format!("{v:.0}");
    let mut out = vec![];
    let mut slots = match (p.busy, p.slots) {
        (Some(b), Some(s)) => format!("{} busy of {}", n(b), n(s)),
        (None, Some(s)) => format!("{} slots", n(s)),
        _ => "no slot reading".into(),
    };
    if has(p.withheld) {
        slots = format!("{slots}; {} withheld", n(p.withheld.unwrap_or(0.0)));
    }
    let hosts = machines.len();
    slots = format!(
        "{slots}, on {hosts} machine{}",
        if hosts == 1 { "" } else { "s" }
    );
    out.push(Part::new("Slots", slots).warn(!has(p.slots)));
    let stuck = waiting.iter().filter(|q| q.stuck).count();
    let wait = match p.waiting {
        Some(w) if w > 0.0 => {
            let mut t = format!("{} job{}", n(w), if w == 1.0 { "" } else { "s" });
            if let Some(o) = p.oldest.filter(|o| *o > 0.0) {
                t = format!("{t}, the oldest {}", age(o as i64));
            }
            if stuck > 0 {
                t = format!("{t}; {stuck} no online runner can take");
            }
            t
        }
        Some(_) => "none".into(),
        None => "no reading".into(),
    };
    out.push(Part::new("Waiting", wait).warn(stuck > 0));
    if p.done.is_some() || p.pass.is_some() {
        let mut t = p.done.map_or("? done".into(), |d| format!("{} done", n(d)));
        if let Some(r) = p.pass {
            t = format!("{t}, {:.0}% passed", r * 100.0);
        }
        out.push(Part::new("Last 24h", t).warn(p.pass.is_some_and(|r| r < 0.8)));
    }
    let (lo, hi) = bounds(infra, &p.pool);
    if lo.is_some() || hi.is_some() {
        let admitted: Option<f64> = machines
            .iter()
            .filter_map(|m| m.governor.as_ref()?.admitted)
            .reduce(|a, b| a + b);
        let range = format!(
            "keeps {} to {} admitted",
            lo.map_or("?".into(), n),
            hi.map_or("?".into(), n)
        );
        let t = match admitted {
            Some(a) => format!("admits {} now, {range}", n(a)),
            None => range,
        };
        let low = matches!((admitted, lo), (Some(a), Some(l)) if a < l);
        out.push(Part::new("Governor", t).warn(low));
    }
    if let Some(g) = infra.grafana.as_deref() {
        out.push(
            Part::new("Grafana", "the CI runners board").link(Link::Url(format!("{g}/d/{BOARD}"))),
        );
    }
    out
}

/// The busy, slots and waiting queries for `pool`: its `cc:pool_*` series, or the local gates
/// summed over the machines that publish them.
fn queries(pool: &str) -> Result<[(&'static str, String); 3], String> {
    if pool == LOCAL_POOL {
        return Ok([
            ("busy", "sum(cc:host_local_busy)".into()),
            (
                "slots",
                "sum(cc:host_local_busy + clamp_min(cc:host_local_open_slots - cc:host_local_busy, 0))"
                    .into(),
            ),
            ("waiting", "sum(cc:host_local_queued)".into()),
        ]);
    }
    if !host_history::valid_host(pool) {
        return Err(format!("{pool:?} is not a pool name"));
    }
    let q = |rule: &str| format!(r#"max(cc:pool_{rule}{{pool="{pool}"}})"#);
    Ok([
        ("busy", q("busy")),
        ("slots", q("slots")),
        ("waiting", q("waiting")),
    ])
}

/// Ask Prometheus for a pool's last `DAYS` days. A series that fails is an error line; the rest
/// still read.
pub fn history(pool: &str, now: u64) -> Result<PoolHistory, String> {
    let qs = queries(pool)?;
    let base = prom::base()?;
    let from = now.saturating_sub(DAYS * 86_400);
    let mut errors = vec![];
    let mut got: [Vec<Series>; 3] = Default::default();
    for (i, (name, q)) in qs.into_iter().enumerate() {
        match host_history::range(&base, q, from, now) {
            Ok(s) => got[i] = s,
            Err(e) => errors.push(format!("{name}: {e}")),
        }
    }
    let [busy, slots, waiting] = got;
    let mut h = fold(pool, &busy, &slots, &waiting, from, now);
    h.errors = errors;
    Ok(h)
}

/// The hours from the three series: pure, for the tests.
pub fn fold(
    pool: &str,
    busy: &[Series],
    slots: &[Series],
    waiting: &[Series],
    from: u64,
    to: u64,
) -> PoolHistory {
    let n = to.saturating_sub(from).div_ceil(BUCKET).max(1);
    let slot = |t: f64| ((t as u64).saturating_sub(from) / BUCKET).min(n - 1) as usize;
    // Per hour: the sum and count of its samples, and the largest.
    let per = |series: &[Series]| {
        let mut by = vec![(0.0, 0u32, f64::MIN); n as usize];
        for s in series {
            for (t, v) in &s.points {
                let e = &mut by[slot(*t)];
                e.0 += v;
                e.1 += 1;
                e.2 = e.2.max(*v);
            }
        }
        by
    };
    let (b, s, w) = (per(busy), per(slots), per(waiting));
    let mean = |e: &(f64, u32, f64)| (e.1 > 0).then(|| e.0 / e.1 as f64);
    let hours = (0..n as usize)
        .map(|i| PoolHour {
            at: from + i as u64 * BUCKET,
            busy: mean(&b[i]),
            slots: mean(&s[i]),
            waiting: (w[i].1 > 0).then_some(w[i].2),
        })
        .collect();
    PoolHistory {
        pool: pool.to_string(),
        from,
        to,
        step: STEP,
        bucket: BUCKET,
        hours,
        readings: b.iter().map(|e| e.1 as usize).sum(),
        errors: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machines::build as machines;
    use crate::machines::tests::{fleet, series};
    use crate::table::{Row, View};
    use serde_json::json;
    use std::collections::BTreeMap;

    fn infra() -> Infra {
        let mut i = fleet();
        i.grafana = Some("https://grafana.example".into());
        i.instant.get_mut("governor").unwrap().extend(series(vec![
            json!({"__name__": "ci_governor_admitted", "host": "cachyos-x8664-main", "v": "1"}),
            json!({"__name__": "ci_governor_pool_admitted_min", "pool": "unity", "v": "2"}),
            json!({"__name__": "ci_governor_pool_admitted_max", "pool": "unity", "v": "24"}),
        ]));
        i.ci = crate::ci::build(&i);
        i.ci.queue = vec![
            Queued {
                job: "Tests".into(),
                pool: "unity".into(),
                stuck: true,
                ..Default::default()
            },
            Queued {
                job: "build".into(),
                pool: "macos".into(),
                ..Default::default()
            },
        ];
        (i.machines, i.pools) = machines(&i);
        i
    }

    fn page(i: &Infra, name: &str) -> PoolPage {
        build(
            i,
            find(i, name).unwrap(),
            Err("prometheus down".into()),
            1000,
        )
    }

    fn part<'a>(p: &'a PoolPage, label: &str) -> Option<&'a Part> {
        p.parts.iter().find(|x| x.label == label)
    }

    #[test]
    fn an_unknown_name_is_no_pool() {
        assert_eq!(find(&infra(), "nope").unwrap_err(), "no pool named nope");
    }

    #[test]
    fn the_page_reads_its_row_machines_and_waiting_jobs() {
        let p = page(&infra(), "unity");
        assert_eq!(p.head, "unity, 1/3 busy, 2 waiting");
        assert_eq!(
            part(&p, "Slots").unwrap().text,
            "1 busy of 3, on 2 machines"
        );
        let w = part(&p, "Waiting").unwrap();
        assert_eq!(
            w.text,
            "2 jobs, the oldest 15m; 1 no online runner can take"
        );
        assert!(w.warn);
        let hosts: Vec<&str> = p.machines.iter().map(|m| m.host.as_str()).collect();
        assert_eq!(hosts, ["workstation", "aws-burst-1"]);
        let jobs: Vec<&str> = p.waiting.iter().map(|q| q.job.as_str()).collect();
        assert_eq!(jobs, ["Tests"]);
        assert_eq!(
            p.machines[0].link("machine"),
            Some(Link::to(crate::links::Kind::Machine, "workstation"))
        );
        let g = part(&p, "Grafana").unwrap();
        assert_eq!(
            g.link,
            Some(Link::Url("https://grafana.example/d/kb-ci-runners".into()))
        );
        assert_eq!(p.errors, ["history: prometheus down"]);
    }

    #[test]
    fn the_governor_part_is_its_bounds_and_what_it_admits_and_only_where_it_governs() {
        let i = infra();
        let gov = page(&i, "unity");
        let g = part(&gov, "Governor").unwrap();
        // One admitted runner on the workstation, under the floor of two.
        assert_eq!(g.text, "admits 1 now, keeps 2 to 24 admitted");
        assert!(g.warn);
        assert!(part(&page(&i, "macos"), "Governor").is_none());
    }

    #[test]
    fn the_local_gates_page_has_its_machines_and_day() {
        let p = page(&infra(), LOCAL_POOL);
        let hosts: Vec<&str> = p.machines.iter().map(|m| m.host.as_str()).collect();
        assert_eq!(hosts, ["workstation"]);
        assert_eq!(part(&p, "Last 24h").unwrap().text, "4 done, 50% passed");
        assert!(p.waiting.is_empty());
    }

    #[test]
    fn a_bad_pool_name_is_never_queried() {
        assert!(queries("unity\"} or vector(1)").is_err());
        let [(_, busy), ..] = queries("unity").unwrap();
        assert_eq!(busy, r#"max(cc:pool_busy{pool="unity"})"#);
        let [(_, busy), ..] = queries(LOCAL_POOL).unwrap();
        assert_eq!(busy, "sum(cc:host_local_busy)");
    }

    fn range(points: &[(u64, f64)]) -> Series {
        Series {
            labels: BTreeMap::new(),
            value: None,
            points: points.iter().map(|(t, v)| (*t as f64, *v)).collect(),
        }
    }

    #[test]
    fn hours_are_the_means_of_busy_and_slots_and_the_most_waiting() {
        let from = 1_794_355_200;
        let h = fold(
            "unity",
            &[range(&[(from, 1.0), (from + STEP, 3.0)])],
            &[range(&[(from, 4.0), (from + STEP, 4.0)])],
            &[range(&[
                (from, 1.0),
                (from + STEP, 5.0),
                (from + BUCKET, 0.0),
            ])],
            from,
            from + 2 * BUCKET,
        );
        assert_eq!(h.hours.len(), 2);
        assert_eq!(
            h.hours[0],
            PoolHour {
                at: from,
                busy: Some(2.0),
                slots: Some(4.0),
                waiting: Some(5.0),
            }
        );
        // An hour with no busy or slot sample is no reading, not zero.
        assert_eq!((h.hours[1].busy, h.hours[1].waiting), (None, Some(0.0)));
        assert_eq!(h.readings, 2);
    }

    #[test]
    fn the_machines_table_on_the_page_keeps_its_links() {
        let p = page(&infra(), "unity");
        let (_, s) = View::new::<Machine>("", "", "", "").summary(&p.machines);
        assert_eq!(s.links[0]["machine"], "#infra/machines/workstation");
    }
}
