//! The infra board's questions to Prometheus, asked once for both surfaces: the `hub infra`
//! TUI (Prefix i) and agent-web's Infra tab. Both read the `cc:*` recording rules (home-config
//! `apps/monitoring/prometheus-rules-command-center.yaml`) and the runner-exporter series, as
//! Grafana's kb-command-center does, so none of them judges anything itself.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::prom::{self, Series, W};

/// Keeps a machine's run ledger series only while its textfile is fresh, as `cc:host_local_done_24h`.
const LOCAL_FRESH: &str =
    r#"and on (instance) (time() - node_textfile_mtime_seconds{file=~".*fleet_local.prom"} < 180)"#;

/// The board's queries, by name. All but `OPTIONAL` must answer or the tab shows the
/// error instead of numbers: a board blanks rather than leave stale values up.
pub fn instant_queries() -> Vec<(&'static str, String)> {
    vec![
        ("cc", r#"{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate|cc:host_core_busy_ratio|cc:runner_cores_.+"}"#.into()),
        ("runners", format!("{W} (github_runner_state)")),
        ("waiting", format!("{W} (github_actions_job_waiting)")),
        ("finished", format!("sum by (repo, workflow, conclusion, scope) ({W} (github_runs_finished))")),
        ("api", "min(github_runner_exporter_api_ok)".into()),
        ("gates", "cc:host_local_gate".into()),
        // Each core's busy share, keyed by host and cpu, so it stays out of `cc` (keyed by host).
        ("cores", "cc:host_core_busy_ratio".into()),
        // Cores each CI runner's job uses, and a pinned slot's CPUs, keyed by host and runner.
        ("runner_cores", r#"{__name__=~"cc:runner_cores_.+"}"#.into()),
        // Runners the governor holds back: idle but not taking jobs, so not online capacity.
        ("withheld", format!("{W} (github_runner_withheld) == 1")),
        // Done today: when runs finished, and which failed. An absent metric is an empty answer,
        // so the tab says "no data" rather than an error until the exporters publish them.
        ("hourly", format!("sum by (hour, conclusion, scope) ({W} (github_runs_by_hour))")),
        ("failed", format!("{W} (github_run_failed)")),
        ("local_hourly", format!("sum by (hour, result) (fleet_local_gate_by_hour {LOCAL_FRESH})")),
        ("local_failed", format!("sum by (hour, repo, branch, platform, result) (fleet_local_gate_failed {LOCAL_FRESH})")),
        // Recent runs, one series per run: the value is when it finished, or how long it took.
        ("recent", format!("{W} (github_actions_run_recent)")),
        ("recent_dur", format!("{W} (github_actions_run_recent_duration_seconds)")),
        // claude-acct's textfile, only while it is fresh; no `max without` here, which would drop
        // the metric names the card reads. An empty answer makes the card say no data.
        ("accounts", r#"{__name__=~"claude_account_.+"} and on (instance) (time() - node_textfile_mtime_seconds{file=~".*claude_acct.prom"} < 3600)"#.into()),
        // The same three sources as the dashboard's "What is red" table.
        ("red", r#"label_replace(mqtt_tripped{topic=~"agents_.+_watch_.+"} == 1, "item", "watch $1", "topic", "agents_.+_watch_(.+)")
            or label_replace(mqtt_failed{topic=~"agents_.+_runner_.+"} == 1, "item", "runner $1", "topic", "agents_.+_runner_(.+)")
            or label_replace(kube_node_status_condition{condition="Ready",status="true"} == 0, "item", "node $1 NotReady", "node", "(.+)")"#.into()),
    ]
}
pub const OPTIONAL: &[&str] = &[
    "red",
    "accounts",
    "cores",
    "runner_cores",
    "withheld",
    "recent",
    "recent_dur",
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
        grafana: prom::config("CC_GRAFANA_URL").map(|g| grafana_base(&g)),
        ..Default::default()
    };
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => {
            out.error = Some(e);
            return out;
        }
    };
    let answers: Vec<_> = std::thread::scope(|s| {
        let handles: Vec<_> = instant_queries()
            .into_iter()
            .map(|(name, q)| {
                let base = &base;
                (name, s.spawn(move || prom::instant(base, &q)))
            })
            .collect();
        handles
            .into_iter()
            .map(|(name, h)| (name, h.join().unwrap_or_else(|_| Err("panicked".into()))))
            .collect()
    });
    let mut errors = vec![];
    for (name, res) in answers {
        match res {
            Ok(s) => _ = out.instant.insert(name, s),
            Err(e) if !OPTIONAL.contains(&name) => errors.push(e),
            Err(_) => {}
        }
    }
    judge(&mut out, errors);
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
    /// One query's series, or none.
    pub fn get(&self, name: &str) -> &[Series] {
        self.instant.get(name).map(Vec::as_slice).unwrap_or(&[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_grafana_link_is_cut_to_its_base() {
        assert_eq!(
            grafana_base("https://g.lan/d/kb-ci-runners"),
            "https://g.lan"
        );
        assert_eq!(grafana_base("https://g.lan/"), "https://g.lan");
    }

    #[test]
    fn only_the_extras_are_optional() {
        let names: Vec<_> = instant_queries().into_iter().map(|(n, _)| n).collect();
        assert!(OPTIONAL.iter().all(|o| names.contains(o)));
        assert_eq!(
            OPTIONAL,
            [
                "red",
                "accounts",
                "cores",
                "runner_cores",
                "withheld",
                "recent",
                "recent_dur"
            ]
        );
    }
}
