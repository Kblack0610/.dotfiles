//! The infra board's questions to Prometheus, asked once for both surfaces: the `hub`
//! TUI's Infra tab (and Home's health line) and agent-web's Infra tab. Both read the `cc:*` recording rules (home-config
//! `apps/monitoring/prometheus-rules-command-center.yaml`) and the runner-exporter series, as
//! Grafana's kb-command-center does, so none of them judges anything itself. Alertmanager is
//! asked in the same gather (`alertmanager::read`), so the Alerts tab's rules ride this cadence.

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;

use crate::alertmanager::{self, Firing};
use crate::ci::{self, Ci};
use crate::home::{Chip, Level, ALWAYS, DOMAINS};

use crate::prom::{self, Series, W};
use crate::run_detail::Rates;

/// Keeps a machine's run ledger series only while its textfile is fresh, as `cc:host_local_done_24h`.
const LOCAL_FRESH: &str =
    r#"and on (instance) (time() - node_textfile_mtime_seconds{file=~".*fleet_local.prom"} < 180)"#;

/// The board's queries, by name. All but `OPTIONAL` must answer or the tab shows the
/// error instead of numbers: a board blanks rather than leave stale values up.
/// fleet-bench's gauges, in one query so `vitals::fetch` can ask for them alone.
pub const BENCH_QUERY: &str =
    r#"{__name__=~"agent_bench_(waiting_hours|kpi|kpi_limit|kpi_past|vital)"}"#;

/// What CI time costs: each host's rate and basis, its registered slots, its powered hours today
/// and the AWS budget's month, which `run_detail::Rates` prices jobs from (`Infra::rates`).
pub const RATES_QUERY: &str =
    r#"{__name__=~"ci_governor_(rate_usd_per_hour|registered|power_hours_today|budget_usd)"}"#;

pub fn instant_queries() -> Vec<(&'static str, String)> {
    vec![
        ("cc", r#"{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate|cc:host_core_busy_ratio|cc:runner_cores_.+"}"#.into()),
        ("runners", format!("{W} (github_runner_state)")),
        ("waiting", format!("{W} (github_actions_job_waiting)")),
        ("finished", format!("sum by (repo, workflow, conclusion, scope) ({W} (github_runs_finished))")),
        // GitHub answering the exporter's runner reads. The per-repo run-list sources are left
        // out: one failed call there leaves every runner row intact, so it is no reason to say
        // runner rows may be missing.
        ("api", r#"min(github_runner_exporter_api_ok{kind="runners"})"#.into()),
        // The exporter's last scrape. 0 or absent means every exporter series went stale, which
        // is a missed scrape, not GitHub down.
        ("exporter_up", r#"max(up{job="github-runner-exporter"})"#.into()),
        // Calls GitHub says the exporter's token has left this hour, its emptiest bucket. The
        // budget is per user, shared with every gh session, so 0 is the usual reason GitHub
        // stops answering (2026-11-03: repos at 0 from 21:25Z, every job unattributed).
        ("rate_left", "min(github_runner_exporter_rate_remaining)".into()),
        ("gates", "cc:host_local_gate".into()),
        // Each core's busy share, keyed by host and cpu, so it stays out of `cc` (keyed by host).
        ("cores", "cc:host_core_busy_ratio".into()),
        // Cores each CI runner's job uses, and a pinned slot's CPUs, keyed by host and runner.
        ("runner_cores", r#"{__name__=~"cc:runner_cores_.+"}"#.into()),
        // Runners the governor holds back: idle but not taking jobs, so not online capacity.
        ("withheld", format!("{W} (github_runner_withheld) == 1")),
        // The governor's powered standby hosts (aws-burst-1): state and why, run hours today
        // against the day cap, and the override in force. The Cloud runners card.
        ("power", r#"{__name__=~"ci_governor_power_.+"}"#.into()),
        // What a workflow's job usually takes: the exporter's median and p90 over a day of finished
        // jobs, for the CI runners table's USUAL column.
        ("job_usual", r#"github_job_duration_seconds{forge!="forgejo"}"#.into()),
        // The governor itself: per host its verdict and action, admitted slots and whether it
        // acts for real; its queue and health; and the AWS budget's month it reads hourly.
        ("governor", r#"{__name__=~"ci_governor_(up|ok|dry_run|queue|live|admitted|decision|budget_.+)"}"#.into()),
        // Done today: when runs finished, and which failed. An absent metric is an empty answer,
        // so the tab says "no data" rather than an error until the exporters publish them.
        ("hourly", format!("sum by (hour, conclusion, scope) ({W} (github_runs_by_hour))")),
        ("failed", format!("{W} (github_run_failed)")),
        ("local_hourly", format!("sum by (hour, result) (fleet_local_gate_by_hour {LOCAL_FRESH})")),
        ("local_failed", format!("sum by (hour, repo, branch, platform, result) (fleet_local_gate_failed {LOCAL_FRESH})")),
        // What is red right now, one row per item: the home-config `cc:red_now` recording rule,
        // which the dashboard's "What is red" table and the waybar day chip also read.
        ("red", "cc:red_now".into()),
        // fleet-bench's window and KPIs, as it judged them, and which of them are the vitals: the
        // phone's agent lines and Home's Vitals.
        ("bench", BENCH_QUERY.into()),
        ("rates", RATES_QUERY.into()),
    ]
}
pub const OPTIONAL: &[&str] = &[
    "red",
    "bench",
    "exporter_up",
    "rate_left",
    "cores",
    "runner_cores",
    "withheld",
    "power",
    "governor",
    "job_usual",
    "rates",
];

#[derive(Serialize, Default, Clone, Debug)]
pub struct Infra {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// When Prometheus was asked, unix seconds.
    pub at: u64,
    /// Grafana's base URL, for the boards' links: `CC_GRAFANA_URL` is a dashboard link (the
    /// waybar chip opens it as is), so everything from `/d/` on is dropped here, once.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grafana: Option<String>,
    pub instant: BTreeMap<&'static str, Vec<Series>>,
    /// `runners_down()` as `gather` found it, for the browser, which only draws it.
    pub down: Vec<Series>,
    /// The CI runners board, built once here for both surfaces (`ci::build`).
    pub ci: Ci,
    /// What Alertmanager says is firing, asked beside the queries so it is cached with them;
    /// none when it was not asked. Only the Alerts join reads it, so the Infra tab's JSON
    /// leaves it out.
    #[serde(skip)]
    pub alertmanager: Option<Result<Vec<Firing>, String>>,
}

/// Grafana's base URL from `CC_GRAFANA_URL`, for any board's dashboard link.
pub fn grafana() -> Option<String> {
    prom::config("CC_GRAFANA_URL").map(|g| grafana_base(&g))
}

fn grafana_base(url: &str) -> String {
    url.split("/d/")
        .next()
        .unwrap_or(url)
        .trim_end_matches('/')
        .to_string()
}

/// Ask every query at once (each is a curl with its own timeout) and keep what answered.
/// Any required query failing, or no `cc:overall_status`, makes the whole answer an error.
pub fn gather() -> Infra {
    let mut out = Infra {
        at: crate::jobs::now().max(0) as u64,
        grafana: grafana(),
        ..Default::default()
    };
    // Alertmanager is asked beside Prometheus, and even when Prometheus cannot be, since the
    // Alerts tab shows each source's answer on its own.
    let base = prom::base();
    let (am, answers) = std::thread::scope(|s| {
        let am = s.spawn(alertmanager::read);
        let answers: Vec<_> = match &base {
            Ok(base) => {
                let handles: Vec<_> = instant_queries()
                    .into_iter()
                    .map(|(name, q)| (name, s.spawn(move || prom::instant(base, &q))))
                    .collect();
                handles
                    .into_iter()
                    .map(|(name, h)| (name, h.join().unwrap_or_else(|_| Err("panicked".into()))))
                    .collect()
            }
            Err(_) => vec![],
        };
        (
            am.join().unwrap_or_else(|_| Err("panicked".into())),
            answers,
        )
    });
    out.alertmanager = Some(am);
    if let Err(e) = base {
        out.error = Some(e);
        return out;
    }
    let mut errors = vec![];
    for (name, res) in answers {
        match res {
            Ok(s) => _ = out.instant.insert(name, s),
            Err(e) if !OPTIONAL.contains(&name) => errors.push(e),
            Err(_) => {}
        }
    }
    judge(&mut out, errors);
    out.down = out.runners_down().into_iter().cloned().collect();
    out.ci = ci::build(&out);
    out
}

/// Set `ok` and `error` from the failed required queries, and fail an answer with no
/// `cc:overall_status`: rules not loaded is not an empty green board.
pub fn judge(out: &mut Infra, mut errors: Vec<String>) {
    errors.sort();
    errors.dedup();
    if errors.is_empty()
        && !out
            .instant
            .get("cc")
            .is_some_and(|s| s.iter().any(|x| x.label("__name__") == "cc:overall_status"))
    {
        errors.push("no cc:* series (recording rules not loaded?)".into());
    }
    out.ok = errors.is_empty();
    out.error = (!errors.is_empty()).then(|| errors.join("; "));
}

impl Infra {
    /// The rates the board read, or why there are none.
    pub fn rates(&self) -> Rates {
        match self.instant.get("rates") {
            Some(s) => Rates::from_series(s),
            None => Rates {
                error: Some(
                    self.error
                        .clone()
                        .unwrap_or_else(|| "no rate series".into()),
                ),
                ..Default::default()
            },
        }
    }

    /// One query's series, or none.
    pub fn get(&self, name: &str) -> &[Series] {
        self.instant.get(name).map(Vec::as_slice).unwrap_or(&[])
    }

    /// The hosts the governor has powered off, or is starting or stopping (`ci_governor_power_state`
    /// at 1 in a state other than `running`), with that state: offline is what their runners
    /// should be. A host the governor does not manage has no such series.
    pub fn powered_off(&self) -> HashMap<&str, &str> {
        self.get("power")
            .iter()
            .filter(|s| {
                s.label("__name__") == "ci_governor_power_state"
                    && s.value == Some(1.0)
                    && s.label("state") != "running"
            })
            .map(|s| (s.label("host"), s.label("state")))
            .collect()
    }

    /// The runners that are down: offline or missing, unless the governor has powered their host
    /// off (`powered_off`). RED NOW on both surfaces and the phone's CI line read this, so none
    /// of them judges a runner itself. By host, then name.
    pub fn runners_down(&self) -> Vec<&Series> {
        let off = self.powered_off();
        let mut down: Vec<&Series> = self
            .get("runners")
            .iter()
            .filter(|s| matches!(s.label("state"), "offline" | "missing"))
            .filter(|s| !off.contains_key(s.label("host")))
            .collect();
        down.sort_by_key(|s| (s.label("host"), s.label("name")));
        down
    }

    /// The `cc` series keyed as the boards key them: `name` or `name/<domain|host|pool|site>`.
    pub fn cc_values(&self) -> HashMap<String, f64> {
        let mut v = HashMap::new();
        for s in self.get("cc") {
            let name = s.label("__name__");
            let sub = if name == "cc:domain_status" {
                s.label("domain")
            } else {
                ["host", "pool", "site"]
                    .into_iter()
                    .map(|k| s.label(k))
                    .find(|x| !x.is_empty())
                    .unwrap_or("")
            };
            let key = if sub.is_empty() {
                name.to_string()
            } else {
                format!("{name}/{sub}")
            };
            if let Some(x) = s.value {
                v.insert(key, x);
            }
        }
        v
    }

    /// The health chips (`cc:domain_status`) in strip order, for Home's HEALTH line and
    /// Infra's health section; k3s and ci show even with no status, as no data.
    pub fn health(&self) -> Vec<Chip> {
        let v = self.cc_values();
        DOMAINS
            .iter()
            .filter_map(|d| {
                let s = v.get(&format!("cc:domain_status/{d}")).copied();
                (s.is_some() || ALWAYS.contains(d)).then(|| Chip {
                    name: (*d).into(),
                    level: Level::of(s),
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cc(name: &str, label: (&str, &str), v: f64) -> Series {
        let mut labels = std::collections::BTreeMap::new();
        labels.insert("__name__".to_string(), name.to_string());
        labels.insert(label.0.to_string(), label.1.to_string());
        Series {
            labels,
            value: Some(v),
            points: vec![],
        }
    }

    #[test]
    fn health_keeps_strip_order_and_always_shows_k3s_and_ci() {
        let mut i = Infra::default();
        i.instant.insert(
            "cc",
            vec![
                cc("cc:domain_status", ("domain", "ci"), 2.0),
                cc("cc:pool_status", ("pool", "unity"), 1.0),
            ],
        );
        let h = i.health();
        let names: Vec<_> = h.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["k3s", "ci"]);
        assert_eq!(h[0].level, Level::Nodata);
        assert_eq!(h[1].level, Level::Red);
        assert_eq!(i.cc_values().get("cc:pool_status/unity"), Some(&1.0));
    }

    fn runner(name: &str, host: &str, state: &str) -> Series {
        let mut s = cc("github_runner_state", ("name", name), 0.0);
        s.labels.insert("host".into(), host.into());
        s.labels.insert("state".into(), state.into());
        s
    }

    fn power(host: &str, state: &str, v: f64) -> Series {
        let mut s = cc("ci_governor_power_state", ("host", host), v);
        s.labels.insert("state".into(), state.into());
        s
    }

    #[test]
    fn a_runner_on_a_host_the_governor_powered_off_is_not_down() {
        let mut i = Infra::default();
        i.instant.insert(
            "runners",
            vec![
                runner("aws-burst-1-unity-pool-1", "aws-burst-1", "offline"),
                runner("aws-burst-2-unity-pool-1", "aws-burst-2", "missing"),
                runner("mini-1", "mac-mini", "offline"),
                runner("razer-1", "razer-laptop", "idle"),
            ],
        );
        i.instant.insert(
            "power",
            vec![
                power("aws-burst-1", "stopped", 1.0),
                // A state at 0 is not the host's state: aws-burst-2 is running.
                power("aws-burst-2", "stopped", 0.0),
                power("aws-burst-2", "running", 1.0),
            ],
        );
        let names = |i: &Infra| -> Vec<String> {
            i.runners_down()
                .iter()
                .map(|s| s.label("name").to_string())
                .collect()
        };
        // Down while the governor says its host runs, and on mac-mini, which it does not manage.
        assert_eq!(names(&i), ["aws-burst-2-unity-pool-1", "mini-1"]);
        // Starting is not running either: its runners are not up yet, by design.
        i.instant
            .insert("power", vec![power("aws-burst-1", "starting", 1.0)]);
        assert_eq!(names(&i), ["aws-burst-2-unity-pool-1", "mini-1"]);
        // With no governor answer every offline runner is down.
        i.instant.remove("power");
        assert_eq!(
            names(&i),
            [
                "aws-burst-1-unity-pool-1",
                "aws-burst-2-unity-pool-1",
                "mini-1"
            ]
        );
    }

    #[test]
    fn the_grafana_link_is_cut_to_its_base() {
        assert_eq!(
            grafana_base("https://g.lan/d/kb-ci-runners"),
            "https://g.lan"
        );
        assert_eq!(grafana_base("https://g.lan/"), "https://g.lan");
    }

    #[test]
    fn the_rates_come_from_the_boards_answer_or_say_why_not() {
        let mut i = Infra::default();
        i.instant.insert(
            "rates",
            vec![
                cc("ci_governor_registered", ("host", "aws-burst-1"), 5.0),
                cc("ci_governor_budget_usd", ("kind", "actual"), 10.0),
            ],
        );
        let r = i.rates();
        assert_eq!(r.hosts["aws-burst-1"].slots, Some(5.0));
        assert_eq!((r.budget_actual, r.error), (Some(10.0), None));
        let none = Infra {
            error: Some("cannot read prom".into()),
            ..Default::default()
        };
        assert_eq!(none.rates().error.as_deref(), Some("cannot read prom"));
    }

    #[test]
    fn only_the_extras_are_optional() {
        let names: Vec<_> = instant_queries().into_iter().map(|(n, _)| n).collect();
        assert!(OPTIONAL.iter().all(|o| names.contains(o)));
        assert_eq!(
            OPTIONAL,
            [
                "red",
                "bench",
                "exporter_up",
                "rate_left",
                "cores",
                "runner_cores",
                "withheld",
                "power",
                "governor",
                "job_usual",
                "rates"
            ]
        );
    }
}
