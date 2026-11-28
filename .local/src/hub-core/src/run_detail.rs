//! One CI run opened on Infra's CI runs (or Releases' Release runs), both surfaces: its jobs and
//! their steps, from `schedules-sync`'s job archive joined to the run ledger on `RunKey`.
//! `builds::detail` reads it only when a run is opened (docs/dashboards.md rule 10), and only from
//! local files, so neither a list render nor an open asks GitHub anything, and a complete record
//! is never fetched again. No job is priced: the per-host rates came from the retired
//! ci-runner-governor (hc-955), and an ARC or KEDA job pod has no host rate of its own.
//!
//! | fact                    | home                                                              |
//! |-------------------------|-------------------------------------------------------------------|
//! | the jobs and steps      | `$SCHEDULES_JOBS_LEDGER`, else `<state>/ci/jobs.jsonl`; last line per key |
//! | the run's own fields    | the run ledger (`builds`), joined on forge, repo, run id, attempt  |

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::builds::{Run, RunKey};

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
    /// `queued`, `in_progress` or `completed`: the job API's; the archive may not carry it.
    pub status: Option<String>,
    pub conclusion: Option<String>,
    pub runner_name: Option<String>,
    pub labels: Vec<String>,
    pub created_at: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    /// The job's page: `url` in the archive, `html_url` from the job API.
    #[serde(alias = "html_url")]
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

pub(crate) fn ts(s: &Option<String>) -> Option<i64> {
    s.as_deref().and_then(crate::fleet::ts)
}

/// Seconds from `a` to `b`, when both are known.
pub(crate) fn span(a: Option<i64>, b: Option<i64>) -> Option<i64> {
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
    /// The kind of slot it asked for (`pool`, `light`, `forgejo`), `hosted`, or `-` unrun.
    pub class: String,
    /// Created to started.
    pub wait: Option<i64>,
    /// Started to completed.
    pub took: Option<i64>,
    pub wait_text: String,
    pub took_text: String,
    /// The runner's name, or `github-hosted`.
    pub runner: String,
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
    pub jobs: Vec<JobRow>,
    /// Every attempt of this run in the ledger, this one included.
    pub attempts: Vec<u32>,
    /// `#42871773354 Tests (affected)  red  46m`.
    pub title: String,
    /// `end to end 46m | before first job 2m | runner time 1h42 | tested a1b2c3 | complete`.
    pub header: String,
    /// The run page's sections, filled when the run is opened (`builds::detail`).
    pub page: Option<crate::run_page::Page>,
}

fn short_sha(s: &str) -> &str {
    s.get(..7).unwrap_or(s)
}

/// A GitHub-hosted runner, told by the name GitHub gives every one, never by the labels: the
/// archive's self-hosted Unity jobs carry `unity` and `unity-gate` with no `self-hosted` (ar-3083).
pub(crate) fn hosted(runner: &str) -> bool {
    runner.starts_with("GitHub Actions")
}

/// What kind of slot a job ran on, from the cap labels the job asked for: the class half of `pool/owned`.
/// A runner or host name is not a cap, so neither is read here (hc-652).
fn kind_of(j: &Job) -> String {
    let has = |w: &str| j.labels.iter().any(|l| l.eq_ignore_ascii_case(w));
    if let Some(k) = ["light", "heavy", "forgejo"].into_iter().find(|k| has(k)) {
        k.into()
    } else if j
        .labels
        .iter()
        .any(|l| l.to_lowercase().starts_with("unity"))
    {
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

fn job_row(j: &Job) -> JobRow {
    let runner = j.runner_name.clone().unwrap_or_default();
    let (created, started, completed) = (ts(&j.created_at), ts(&j.started_at), ts(&j.completed_at));
    let took = span(started, completed);
    let is_hosted = hosted(&runner);
    let class = if runner.is_empty() {
        "-".to_string()
    } else if is_hosted {
        "hosted".into()
    } else {
        kind_of(j)
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
        url: j.url.clone().unwrap_or_default(),
        steps,
        steps_text,
    }
}

/// The opened run from its ledger row and its archive record (if any).
pub fn build(run: &Run, rec: Option<&Record>, attempts: Vec<u32>, now: i64) -> RunDetail {
    let jobs: Vec<&Job> = rec.map(|r| r.jobs.iter().collect()).unwrap_or_default();
    let rows: Vec<JobRow> = jobs.iter().map(|j| job_row(j)).collect();
    let created = crate::fleet::ts(&run.created_at);
    let first = jobs.iter().filter_map(|j| ts(&j.started_at)).min();
    let last = jobs.iter().filter_map(|j| ts(&j.completed_at)).max();
    let runner_time = rows.iter().filter_map(|r| r.took).sum();
    let ended = run.ended_at.as_deref().and_then(crate::fleet::ts);
    let (coverage, coverage_text) = match rec {
        Some(r) if r.source == crate::run_page::LIVE_SOURCE => (
            "live",
            format!(
                "live: {} jobs read from GitHub when opened, fetched {}; the next 10-minute import archives them",
                r.jobs.len(),
                r.fetched_at
            ),
        ),
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
        "#{} {}  {}  {}",
        run.id,
        run.workflow,
        run.state,
        took_text(end_to_end.or(run.took))
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
        jobs: rows,
        attempts,
        title,
        header,
        page: Default::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn hosted_is_told_by_the_runner_name_never_by_a_missing_self_hosted_label() {
        // A playground Unity gate job asks for unity and unity-gate with no self-hosted (ar-3083).
        let job = |runner: &str, labels: &[&str]| Job {
            runner_name: Some(runner.into()),
            labels: labels.iter().map(|l| l.to_string()).collect(),
            ..Default::default()
        };
        let unity = job_row(&job("razer-laptop-unity-pool-1", &["unity", "unity-gate"]));
        assert_eq!(
            (unity.class.as_str(), unity.runner.as_str()),
            ("pool", "razer-laptop-unity-pool-1")
        );
        let gh = job_row(&job("GitHub Actions 12", &["ubuntu-latest"]));
        assert_eq!(
            (gh.class.as_str(), gh.runner.as_str()),
            ("hosted", "github-hosted")
        );
        // A job no runner took yet is neither.
        let unrun = job_row(&job("", &["unity", "unity-gate"]));
        assert_eq!((unrun.class.as_str(), unrun.runner.as_str()), ("-", ""));
    }

    #[test]
    fn a_job_kind_comes_from_its_cap_labels_never_from_a_runner_or_host_name() {
        let job = |runner: &str, labels: &[&str]| Job {
            runner_name: Some(runner.into()),
            labels: labels.iter().map(|l| l.to_string()).collect(),
            ..Default::default()
        };
        let kinds: Vec<String> = [
            job("x-light-1", &["self-hosted", "unity"]),
            job("x-unity-pool-1", &["self-hosted", "light"]),
            job("x-unity-pool-1-forgejo", &["forgejo"]),
            job("aws-build-1-unity-pool-2", &["self-hosted", "unity-build"]),
            job("ms-a2-unity-pool-1", &["self-hosted", "heavy", "unity"]),
            job("mac-1", &["self-hosted", "macOS", "arm64"]),
            job("x-light-1", &["self-hosted", "linux"]),
        ]
        .iter()
        .map(kind_of)
        .collect();
        assert_eq!(
            kinds,
            ["pool", "light", "forgejo", "pool", "heavy", "macOS", "runner"]
        );
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
