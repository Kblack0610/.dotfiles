//! One CI run opened on Infra's CI runs (or Releases' Release runs), both surfaces: its jobs, their
//! steps and what each cost, from `schedules-sync`'s job archive joined to the run ledger on
//! `RunKey`, priced with the governor's rates. `builds::detail` reads it only when a run is opened
//! (docs/dashboards.md rule 10), and only from local files and the rates its caller passes, so
//! neither a list render nor an open asks GitHub anything, and a complete record is never fetched
//! again.
//!
//! | fact                    | home                                                              |
//! |-------------------------|-------------------------------------------------------------------|
//! | the jobs and steps      | `$SCHEDULES_JOBS_LEDGER`, else `<state>/ci/jobs.jsonl`; last line per key |
//! | the run's own fields    | the run ledger (`builds`), joined on forge, repo, run id, attempt  |
//! | a host's $/h and basis  | `ci_governor_rate_usd_per_hour{host,basis}`                        |
//! | a host's slots          | `ci_governor_registered{host}`                                     |

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use crate::builds::{Run, RunKey};
use crate::prom::Series;

/// A run that finished this recently may still get its jobs from the next 10-minute import.
pub const PENDING_SECS: i64 = 1200;

/// One line of the job archive: every job of one attempt of one run.
#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Record {
    pub forge: String,
    pub repo: String,
    pub run_id: u64,
    pub attempt: u32,
    /// `exporter` or `github`: who collected it.
    pub source: String,
    /// False when the fetch was interrupted: the jobs are only some of the run's.
    pub complete: bool,
    pub fetched_at: String,
    pub jobs: Vec<Job>,
}

impl Record {
    pub fn key(&self) -> RunKey {
        RunKey {
            forge: self.forge.clone(),
            repo: self.repo.clone(),
            id: self.run_id,
            attempt: self.attempt,
        }
    }
}

#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Job {
    pub id: u64,
    pub name: String,
    pub conclusion: Option<String>,
    pub runner_name: Option<String>,
    pub labels: Vec<String>,
    pub created_at: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub url: Option<String>,
    pub steps: Vec<Step>,
}

#[derive(Deserialize, Default, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Step {
    pub number: u32,
    pub name: String,
    pub conclusion: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

fn ts(s: &Option<String>) -> Option<i64> {
    s.as_deref().and_then(crate::fleet::ts)
}

/// Seconds from `a` to `b`, when both are known.
fn span(a: Option<i64>, b: Option<i64>) -> Option<i64> {
    Some((b? - a?).max(0))
}

/// The archive's records, each key once as its last line wrote it. `want` is a cheap test on the
/// raw line, so an open parses only the lines that can be its run. A last line that does not
/// parse is a write still in progress and is skipped silently; any other is counted.
pub fn archive(text: &str, want: impl Fn(&str) -> bool) -> (HashMap<RunKey, Record>, usize) {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    let mut out = HashMap::new();
    let mut bad = 0;
    for (i, line) in lines.iter().enumerate() {
        if !want(line) {
            continue;
        }
        match serde_json::from_str::<Record>(line) {
            Ok(r) => {
                out.insert(r.key(), r);
            }
            Err(_) if i + 1 == lines.len() => {}
            Err(_) => bad += 1,
        }
    }
    (out, bad)
}

/// One host's rate as the governor exports it.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct HostRate {
    /// None when the host has registered slots but no rate series.
    pub usd_per_hour: Option<f64>,
    /// `owned`, `on-demand` or `spot-estimate`.
    pub basis: String,
    /// Runner slots registered on the host (`ci_governor_registered`).
    pub slots: Option<f64>,
}

/// Every host's rate from the governor's series.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Rates {
    pub hosts: BTreeMap<String, HostRate>,
    /// Why the rates could not be read: every job then reads "no rate".
    pub error: Option<String>,
}

impl Rates {
    pub fn from_series(series: &[Series]) -> Rates {
        let mut out = Rates::default();
        for s in series {
            let (Some(v), host) = (s.value, s.label("host")) else {
                continue;
            };
            match s.label("__name__") {
                "ci_governor_rate_usd_per_hour" if !host.is_empty() => {
                    let h = out.hosts.entry(host.to_string()).or_default();
                    h.usd_per_hour = Some(v);
                    h.basis = s.label("basis").to_string();
                }
                "ci_governor_registered" if !host.is_empty() => {
                    let h = out.hosts.entry(host.to_string()).or_default();
                    h.slots = Some(h.slots.unwrap_or_default() + v);
                }
                _ => {}
            }
        }
        out
    }

    /// The host a runner sits on: the longest known host its name starts with, at a dash.
    pub fn host_of(&self, runner: &str) -> Option<&str> {
        self.hosts
            .keys()
            .filter(|h| {
                runner == h.as_str()
                    || runner
                        .strip_prefix(h.as_str())
                        .is_some_and(|rest| rest.starts_with('-'))
            })
            .max_by_key(|h| h.len())
            .map(String::as_str)
    }

    /// What `secs` of a job on `runner` cost.
    pub fn price(&self, runner: &str, hosted: bool, secs: Option<i64>) -> Price {
        let no_rate = |basis: &str| Price {
            usd: None,
            basis: basis.into(),
            text: "no rate".into(),
        };
        if runner.is_empty() {
            return Price::unrun();
        }
        if hosted {
            return no_rate("github-hosted");
        }
        let Some(host) = self.host_of(runner) else {
            return no_rate("no rate");
        };
        let h = &self.hosts[host];
        let Some(rate) = h.usd_per_hour else {
            return no_rate("no rate");
        };
        let basis = if h.basis.is_empty() {
            "owned"
        } else {
            &h.basis
        };
        let Some(secs) = secs else {
            return Price {
                basis: basis.into(),
                ..Price::unrun()
            };
        };
        if rate == 0.0 {
            return Price {
                usd: Some(0.0),
                basis: basis.into(),
                text: format!("0.00 {basis}"),
            };
        }
        // A rate with no registered slots cannot be shared out: unknown, not the whole host.
        let Some(slots) = h.slots.filter(|n| *n >= 1.0) else {
            return no_rate("no rate");
        };
        let usd = rate * secs as f64 / 3600.0 / slots;
        let est = basis == "spot-estimate";
        Price {
            usd: Some(usd),
            basis: basis.into(),
            text: format!(
                "{}{usd:.2}{} (1/{} of ${}/h)",
                if est { "~" } else { "" },
                if est { " est" } else { "" },
                slots.round() as i64,
                rate_text(rate)
            ),
        }
    }
}

/// A rate with as many decimals as it carries, two at least: `1.855`, `0.60`.
fn rate_text(r: f64) -> String {
    let s = format!("{r:.3}");
    let s = s.trim_end_matches('0');
    match s.split_once('.') {
        Some((_, d)) if d.len() >= 2 => s.to_string(),
        _ => format!("{r:.2}"),
    }
}

/// What one job cost: $/h x hours / slots. `usd` None with basis `no rate` or `github-hosted` is unpriced; with any
/// other basis the job has not finished.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Price {
    pub usd: Option<f64>,
    pub basis: String,
    pub text: String,
}

impl Price {
    fn unrun() -> Price {
        Price {
            usd: None,
            basis: String::new(),
            text: "-".into(),
        }
    }

    pub fn unpriced(&self) -> bool {
        self.usd.is_none() && matches!(self.basis.as_str(), "no rate" | "github-hosted")
    }
}

/// A run's jobs added up.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct RunCost {
    pub usd: f64,
    pub priced: usize,
    pub unpriced: usize,
    pub estimate: bool,
    /// `$0.20`, `~$1.10`, `$0.00 owned`, `$0.20 + no rate`, `no rate`, or `-` with no finished job.
    pub text: String,
}

impl RunCost {
    pub fn of<'a>(prices: impl IntoIterator<Item = &'a Price>) -> RunCost {
        let mut c = RunCost::default();
        let mut owned = true;
        for p in prices {
            match p.usd {
                Some(u) => {
                    c.usd += u;
                    c.priced += 1;
                    c.estimate |= p.basis == "spot-estimate";
                    owned &= u == 0.0;
                }
                None if p.unpriced() => c.unpriced += 1,
                None => {}
            }
        }
        let sum = format!("{}${:.2}", if c.estimate { "~" } else { "" }, c.usd);
        c.text = match (c.priced, c.unpriced) {
            (0, 0) => "-".into(),
            (0, _) => "no rate".into(),
            (_, 0) if owned => "$0.00 owned".into(),
            (_, 0) => sum,
            _ => format!("{sum} + no rate"),
        };
        c
    }
}

/// A duration as the open run reads it: `12s`, `21m`, `1m24`, `1h42`.
pub fn took_text(secs: Option<i64>) -> String {
    match secs {
        None => "-".into(),
        Some(s) if s < 60 => format!("{}s", s.max(0)),
        Some(s) if s < 3600 && s % 60 == 0 => format!("{}m", s / 60),
        Some(s) if s < 3600 => format!("{}m{:02}", s / 60, s % 60),
        Some(s) => format!("{}h{:02}", s / 3600, s % 3600 / 60),
    }
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct StepRow {
    pub name: String,
    pub conclusion: String,
    pub took: Option<i64>,
}

/// One job of the opened run, with the words its row draws.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct JobRow {
    pub name: String,
    pub conclusion: String,
    /// `<kind>/<basis>`: `pool/owned`, `light/owned`, `aws/on-demand`, `hosted`.
    pub class: String,
    /// Created to started.
    pub wait: Option<i64>,
    /// Started to completed.
    pub took: Option<i64>,
    pub wait_text: String,
    pub took_text: String,
    /// The runner's name, or `github-hosted`.
    pub runner: String,
    pub host: String,
    pub price: Price,
    pub url: String,
    pub steps: Vec<StepRow>,
    /// `checkout 2s, submodules 11s, PlayMode 43m10`.
    pub steps_text: String,
}

/// The opened run: the header, the jobs table and its folds.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct RunDetail {
    pub key: RunKey,
    pub workflow: String,
    pub state: String,
    pub url: String,
    /// Submitted to the last job's end.
    pub end_to_end: Option<i64>,
    /// Submitted to the first job's start.
    pub before_first_job: Option<i64>,
    /// Every job's run time added up.
    pub runner_time: i64,
    /// `complete`, `partial`, `pending` or `unavailable`.
    pub coverage: String,
    pub coverage_text: String,
    pub cost: RunCost,
    pub jobs: Vec<JobRow>,
    /// Every attempt of this run in the ledger, this one included.
    pub attempts: Vec<u32>,
    /// `#42871773354 Tests (affected)  red  46m  $0.20`.
    pub title: String,
    /// `end to end 46m | before first job 2m | runner time 1h42 | tested a1b2c3 | complete`.
    pub header: String,
    /// Why the rates did not read, so "no rate" on every row has its reason beside it.
    pub rates_error: Option<String>,
}

fn short_sha(s: &str) -> &str {
    s.get(..7).unwrap_or(s)
}

fn hosted(j: &Job, runner: &str) -> bool {
    runner.starts_with("GitHub Actions")
        || (!j.labels.is_empty() && !j.labels.iter().any(|l| l == "self-hosted"))
}

/// What kind of slot a job ran on, from its labels and runner: the class half of `pool/owned`.
fn kind_of(j: &Job, runner: &str, host: &str, basis: &str) -> String {
    if basis != "owned" && !host.is_empty() {
        return host.split('-').next().unwrap_or(host).to_string();
    }
    let has = |w: &str| j.labels.iter().any(|l| l.eq_ignore_ascii_case(w));
    if has("light") || runner.contains("-light-") {
        "light".into()
    } else if j.labels.iter().any(|l| l.starts_with("unity")) || runner.contains("-pool-") {
        "pool".into()
    } else {
        j.labels
            .iter()
            .find(|l| {
                !matches!(
                    l.to_lowercase().as_str(),
                    "self-hosted" | "linux" | "x64" | "arm64"
                )
            })
            .cloned()
            .unwrap_or_else(|| "runner".into())
    }
}

fn job_row(j: &Job, rates: &Rates) -> JobRow {
    let runner = j.runner_name.clone().unwrap_or_default();
    let (created, started, completed) = (ts(&j.created_at), ts(&j.started_at), ts(&j.completed_at));
    let took = span(started, completed);
    let is_hosted = !runner.is_empty() && hosted(j, &runner);
    let price = rates.price(&runner, is_hosted, took);
    let host = if is_hosted {
        String::new()
    } else {
        rates.host_of(&runner).unwrap_or_default().to_string()
    };
    let class = match price.basis.as_str() {
        _ if runner.is_empty() => "-".to_string(),
        "github-hosted" => "hosted".into(),
        "no rate" | "" => kind_of(j, &runner, "", "owned"),
        b => format!("{}/{b}", kind_of(j, &runner, &host, b)),
    };
    let steps: Vec<StepRow> = j
        .steps
        .iter()
        .map(|s| StepRow {
            name: s.name.clone(),
            conclusion: s.conclusion.clone().unwrap_or_default(),
            took: span(ts(&s.started_at), ts(&s.completed_at)),
        })
        .collect();
    let steps_text = steps
        .iter()
        .map(|s| format!("{} {}", s.name, took_text(s.took)))
        .collect::<Vec<_>>()
        .join(", ");
    let wait = span(created, started);
    JobRow {
        name: j.name.clone(),
        conclusion: j.conclusion.clone().unwrap_or_default(),
        class,
        wait,
        took,
        wait_text: took_text(wait),
        took_text: took_text(took),
        runner: if is_hosted {
            "github-hosted".into()
        } else {
            runner
        },
        host,
        price,
        url: j.url.clone().unwrap_or_default(),
        steps,
        steps_text,
    }
}

/// The opened run from its ledger row, its archive record (if any) and the rates.
pub fn build(
    run: &Run,
    rec: Option<&Record>,
    attempts: Vec<u32>,
    rates: &Rates,
    now: i64,
) -> RunDetail {
    let jobs: Vec<&Job> = rec.map(|r| r.jobs.iter().collect()).unwrap_or_default();
    let rows: Vec<JobRow> = jobs.iter().map(|j| job_row(j, rates)).collect();
    let created = crate::fleet::ts(&run.created_at);
    let first = jobs.iter().filter_map(|j| ts(&j.started_at)).min();
    let last = jobs.iter().filter_map(|j| ts(&j.completed_at)).max();
    let runner_time = rows.iter().filter_map(|r| r.took).sum();
    let ended = run.ended_at.as_deref().and_then(crate::fleet::ts);
    let (coverage, coverage_text) = match rec {
        Some(r) if r.complete => (
            "complete",
            format!(
                "complete: {} jobs from {}, fetched {}",
                r.jobs.len(),
                r.source,
                r.fetched_at
            ),
        ),
        Some(r) => (
            "partial",
            format!(
                "partial: the fetch was interrupted, {} jobs read from {}, fetched {}",
                r.jobs.len(),
                r.source,
                r.fetched_at
            ),
        ),
        None if !run.done() || ended.is_some_and(|e| now - e < PENDING_SECS) => (
            "pending",
            "pending: the next 10-minute import can still bring this run's jobs".to_string(),
        ),
        None => (
            "unavailable",
            "unavailable: no job record (older than collection)".to_string(),
        ),
    };
    let cost = RunCost::of(rows.iter().map(|r| &r.price));
    let end_to_end = span(created, last);
    let before_first_job = span(created, first);
    let sha = format!("tested {}", short_sha(&run.sha));
    let header = [
        format!("end to end {}", took_text(end_to_end)),
        format!("before first job {}", took_text(before_first_job)),
        format!("runner time {}", took_text(Some(runner_time))),
        sha,
        coverage.to_string(),
    ]
    .join(" | ");
    let title = format!(
        "#{} {}  {}  {}  {}",
        run.id,
        run.workflow,
        run.state,
        took_text(end_to_end.or(run.took)),
        cost.text
    );
    RunDetail {
        key: run.key(),
        workflow: run.workflow.clone(),
        state: run.state.clone(),
        url: run.url.clone(),
        end_to_end,
        before_first_job,
        runner_time,
        coverage: coverage.into(),
        coverage_text,
        cost,
        jobs: rows,
        attempts,
        title,
        header,
        rates_error: rates.error.clone(),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn series(name: &str, labels: &[(&str, &str)], v: f64) -> Series {
        let mut l = BTreeMap::new();
        l.insert("__name__".to_string(), name.to_string());
        for (k, x) in labels {
            l.insert(k.to_string(), x.to_string());
        }
        Series {
            labels: l,
            value: Some(v),
            points: vec![],
        }
    }

    pub fn rates() -> Rates {
        Rates::from_series(&[
            series(
                "ci_governor_rate_usd_per_hour",
                &[("host", "aws-burst-1"), ("basis", "on-demand")],
                1.855,
            ),
            series("ci_governor_registered", &[("host", "aws-burst-1")], 5.0),
            series(
                "ci_governor_rate_usd_per_hour",
                &[("host", "razer-laptop"), ("basis", "owned")],
                0.0,
            ),
            series(
                "ci_governor_rate_usd_per_hour",
                &[("host", "aws-burst-2"), ("basis", "spot-estimate")],
                0.6,
            ),
            series("ci_governor_registered", &[("host", "aws-burst-2")], 2.0),
            // A host with slots and no rate.
            series("ci_governor_registered", &[("host", "hp-victus")], 1.0),
        ])
    }

    #[test]
    fn a_runner_belongs_to_the_longest_host_it_starts_with() {
        let mut r = rates();
        r.hosts.insert("aws-burst".into(), HostRate::default());
        assert_eq!(r.host_of("aws-burst-1-unity-pool-3"), Some("aws-burst-1"));
        assert_eq!(r.host_of("razer-laptop-unity-pool-1"), Some("razer-laptop"));
        assert_eq!(
            r.host_of("aws-burst-10-x"),
            Some("aws-burst"),
            "a dash ends the host"
        );
        assert_eq!(r.host_of("mac-mini-1"), None);
    }

    #[test]
    fn a_fifth_of_1855_an_hour_for_32m45_reads_020() {
        let p = rates().price("aws-burst-1-unity-pool-3", false, Some(32 * 60 + 45));
        assert_eq!(p.text, "0.20 (1/5 of $1.855/h)");
        assert_eq!(p.basis, "on-demand");
        assert!((p.usd.unwrap() - 0.2025).abs() < 1e-3);
    }

    #[test]
    fn owned_is_zero_owned_and_a_spot_estimate_says_so() {
        let r = rates();
        assert_eq!(
            r.price("razer-laptop-light-2", false, Some(84)).text,
            "0.00 owned"
        );
        let spot = r.price("aws-burst-2-unity-pool-1", false, Some(3600));
        assert_eq!(spot.text, "~0.30 est (1/2 of $0.60/h)");
    }

    #[test]
    fn an_unpriced_host_reads_no_rate_never_zero() {
        let r = rates();
        for runner in ["hp-victus-light-1", "mac-mini-1"] {
            let p = r.price(runner, false, Some(600));
            assert_eq!((p.text.as_str(), p.usd), ("no rate", None), "{runner}");
            assert!(p.unpriced());
        }
        let hosted = r.price("GitHub Actions 12", true, Some(600));
        assert_eq!(
            (hosted.text.as_str(), hosted.basis.as_str()),
            ("no rate", "github-hosted")
        );
        // A rate with no registered slots is no rate too, unless the rate is 0.
        let mut r = Rates::default();
        r.hosts.insert(
            "x".into(),
            HostRate {
                usd_per_hour: Some(2.0),
                basis: "on-demand".into(),
                ..Default::default()
            },
        );
        r.hosts.insert(
            "y".into(),
            HostRate {
                usd_per_hour: Some(0.0),
                basis: "owned".into(),
                ..Default::default()
            },
        );
        assert_eq!(r.price("x-1", false, Some(60)).text, "no rate");
        assert_eq!(r.price("y-1", false, Some(60)).text, "0.00 owned");
    }

    #[test]
    fn a_runs_total_says_when_a_job_has_no_rate() {
        let r = rates();
        let p = [
            r.price("aws-burst-1-unity-pool-3", false, Some(1965)),
            r.price("hp-victus-light-1", false, Some(12)),
            r.price("razer-laptop-light-2", false, Some(84)),
        ];
        assert_eq!(RunCost::of(&p).text, "$0.20 + no rate");
        assert_eq!(RunCost::of(&p[2..]).text, "$0.00 owned");
        assert_eq!(RunCost::of(&p[1..2]).text, "no rate");
        assert_eq!(RunCost::of(&p[..1]).text, "$0.20");
    }

    #[test]
    fn durations_read_as_the_mock_does() {
        let t = |s| took_text(Some(s));
        assert_eq!(
            [t(12), t(84), t(1260), t(2590), t(6120)],
            ["12s", "1m24", "21m", "43m10", "1h42"]
        );
        assert_eq!(took_text(None), "-");
    }

    #[test]
    fn the_last_line_for_a_key_wins_and_a_torn_last_line_is_skipped() {
        let one =
            r#"{"forge":"github","repo":"o/a","run_id":1,"attempt":1,"complete":false,"jobs":[]}"#;
        let again =
            r#"{"forge":"github","repo":"o/a","run_id":1,"attempt":1,"complete":true,"jobs":[]}"#;
        let text = format!("{one}\nnot json\n{again}\n{{\"forge\":\"gith");
        let (got, bad) = archive(&text, |_| true);
        assert_eq!(bad, 1, "only the line in the middle is counted");
        assert_eq!(got.len(), 1);
        assert!(got.values().next().unwrap().complete, "the last line wins");
    }
}
