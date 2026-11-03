//! GitHub Actions (runner-exporter) and k8s Jobs (kube-state-metrics), both from Prometheus.

use std::collections::HashMap;

use super::{Got, Job, LogRef, Source, State};
use crate::prom::{self, Series, W};

fn join(parts: &[&str]) -> String {
    parts
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ")
}

fn conclusion_ok(c: &str) -> Option<bool> {
    match c {
        "success" => Some(true),
        "failure" | "timed_out" | "startup_failure" => Some(false),
        _ => None,
    }
}

/// CI rows from the exporter's three series: busy runners, waiting jobs, recent runs.
pub(super) fn ci_rows(
    busy: &[Series],
    waiting: &[Series],
    recent: &[Series],
    durs: &[Series],
    at: i64,
) -> Vec<Job> {
    let mut jobs = vec![];
    for s in busy {
        let mut j = Job::new(
            Source::Ci,
            format!("{} / {}", s.label("repo"), s.label("workflow")),
            State::Running,
        );
        let secs = s.value.map(|v| v as i64);
        j.secs = secs;
        j.started = secs.map(|v| at - v);
        j.detail = join(&[s.label("job_name"), s.label("branch"), s.label("name")]);
        let url = s.label("url");
        if !url.is_empty() {
            j.url = Some(url.to_string());
            j.log = Some(LogRef::Gh {
                url: url.to_string(),
                done: false,
            });
        }
        jobs.push(j);
    }
    for s in waiting {
        let mut j = Job::new(
            Source::Ci,
            format!("{} / {}", s.label("repo"), s.label("workflow")),
            State::Queued,
        );
        j.secs = s.value.map(|v| v as i64);
        let stuck = if s.label("stuck") == "true" {
            "STUCK"
        } else {
            ""
        };
        j.detail = join(&[
            s.label("job_name"),
            s.label("branch"),
            s.label("pool"),
            stuck,
        ]);
        j.result = s.label("status").to_string();
        let url = s.label("url");
        if !url.is_empty() {
            j.url = Some(url.to_string());
        }
        jobs.push(j);
    }
    let dur: HashMap<&str, i64> = durs
        .iter()
        .filter_map(|s| Some((s.label("url"), s.value? as i64)))
        .collect();
    for s in recent {
        let Some(fin) = s.value.map(|v| v as i64) else {
            continue;
        };
        let mut j = Job::new(
            Source::Ci,
            format!("{} / {}", s.label("repo"), s.label("workflow")),
            State::Done,
        );
        let c = s.label("conclusion");
        j.ok = conclusion_ok(c);
        j.result = c.to_string();
        j.finished = Some(fin);
        let url = s.label("url");
        j.secs = dur.get(url).copied();
        j.started = j.secs.map(|d| fin - d);
        j.detail = join(&[s.label("branch"), s.label("event")]);
        if !url.is_empty() {
            j.url = Some(url.to_string());
            j.log = Some(LogRef::Gh {
                url: url.to_string(),
                done: true,
            });
        }
        jobs.push(j);
    }
    jobs
}

pub(super) fn ci(at: i64) -> Got {
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => return (vec![], vec![e]),
    };
    let q = |m: &str| prom::instant(&base, &format!("{W} ({m})"));
    let (busy, waiting, recent, durs) = (
        q("github_runner_state{state=\"busy\"}"),
        q("github_actions_job_waiting"),
        q("github_actions_run_recent"),
        q("github_actions_run_recent_duration_seconds"),
    );
    let mut errors = vec![];
    let mut ok = |r: Result<Vec<Series>, String>| {
        r.unwrap_or_else(|e| {
            errors.push(e);
            vec![]
        })
    };
    let (busy, waiting, recent, durs) = (ok(busy), ok(waiting), ok(recent), ok(durs));
    errors.dedup();
    (ci_rows(&busy, &waiting, &recent, &durs, at), errors)
}

#[derive(Default)]
struct KJob {
    owner: String,
    started: Option<i64>,
    finished: Option<i64>,
    active: bool,
    failed: bool,
}

/// k8s Jobs: every CronJob-owned Job, and any other Job still running.
pub(super) fn k8s_rows(
    owner: &[Series],
    start: &[Series],
    done: &[Series],
    active: &[Series],
    failed: &[Series],
    at: i64,
    since: i64,
) -> Vec<Job> {
    let mut by: HashMap<(String, String), KJob> = HashMap::new();
    let key = |s: &Series| {
        (
            s.label("namespace").to_string(),
            s.label("job_name").to_string(),
        )
    };
    for s in owner {
        by.entry(key(s)).or_default().owner = s.label("owner_name").to_string();
    }
    for s in start {
        by.entry(key(s)).or_default().started = s.value.map(|v| v as i64);
    }
    for s in done {
        by.entry(key(s)).or_default().finished = s.value.map(|v| v as i64);
    }
    for s in active {
        by.entry(key(s)).or_default().active = true;
    }
    for s in failed {
        by.entry(key(s)).or_default().failed = true;
    }
    by.into_iter()
        .filter(|(_, k)| k.active || !k.owner.is_empty())
        .filter_map(|((ns, job), k)| {
            let name = format!("{ns}/{}", if k.owner.is_empty() { &job } else { &k.owner });
            let state = if k.active {
                State::Running
            } else {
                State::Done
            };
            // A failed Job has no completion time; its start places it in the window.
            let when = k.finished.or(k.started)?;
            if state == State::Done && when < since {
                return None;
            }
            let mut j = Job::new(Source::K8s, name, state);
            j.started = k.started;
            j.detail = job;
            if k.active {
                j.secs = k.started.map(|s| at - s);
            } else {
                j.finished = k.finished;
                j.secs = k.started.zip(k.finished).map(|(s, e)| e - s);
                j.ok = Some(!k.failed && k.finished.is_some());
                j.result = if j.ok == Some(true) {
                    "complete"
                } else {
                    "failed"
                }
                .into();
            }
            Some(j)
        })
        .collect()
}

pub(super) fn k8s(at: i64, since: i64) -> Got {
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => return (vec![], vec![e]),
    };
    // kube-state-metrics' `namespace` is the Job's own, so it is kept: `W` drops it as a scrape label.
    let q = |m: &str| {
        prom::instant(
            &base,
            &format!("max by (namespace, job_name, owner_name) ({m})"),
        )
    };
    let mut errors = vec![];
    let mut ok = |r: Result<Vec<Series>, String>| {
        r.unwrap_or_else(|e| {
            errors.push(e);
            vec![]
        })
    };
    let owner = ok(q("kube_job_owner{owner_kind=\"CronJob\"}"));
    let start = ok(q("kube_job_status_start_time"));
    let done = ok(q("kube_job_status_completion_time"));
    let active = ok(q("kube_job_status_active > 0"));
    let failed = ok(q("kube_job_status_failed > 0"));
    errors.dedup();
    (
        k8s_rows(&owner, &start, &done, &active, &failed, at, since),
        errors,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(labels: &[(&str, &str)], v: f64) -> Series {
        Series {
            labels: labels
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            value: Some(v),
            points: vec![],
        }
    }

    #[test]
    fn ci_rows_from_the_three_series() {
        let url = "https://github.com/O/platform/actions/runs/1";
        let busy = [s(
            &[
                ("repo", "platform"),
                ("workflow", "CI"),
                ("job_name", "gate"),
                ("url", "https://github.com/O/platform/actions/runs/2/job/3"),
            ],
            60.0,
        )];
        let waiting = [s(
            &[
                ("repo", "playground"),
                ("workflow", "Checks"),
                ("pool", "light"),
                ("stuck", "true"),
            ],
            300.0,
        )];
        let recent = [
            s(
                &[
                    ("repo", "platform"),
                    ("workflow", "CI"),
                    ("conclusion", "failure"),
                    ("url", url),
                    ("branch", "develop"),
                ],
                1000.0,
            ),
            s(
                &[
                    ("repo", "platform"),
                    ("workflow", "Drift"),
                    ("conclusion", "cancelled"),
                    ("url", "u2"),
                ],
                900.0,
            ),
        ];
        let durs = [s(&[("url", url)], 120.0)];
        let j = ci_rows(&busy, &waiting, &recent, &durs, 5000);
        assert_eq!((j[0].state, j[0].started), (State::Running, Some(4940)));
        assert_eq!((j[1].state, j[1].secs), (State::Queued, Some(300)));
        assert!(j[1].detail.ends_with("STUCK"));
        assert_eq!(
            (j[2].ok, j[2].started, j[2].secs),
            (Some(false), Some(880), Some(120))
        );
        assert_eq!(
            j[2].log,
            Some(LogRef::Gh {
                url: url.into(),
                done: true
            })
        );
        assert_eq!(
            (j[3].ok, j[3].secs),
            (None, None),
            "cancelled is neither, and no duration is no guess"
        );
    }

    #[test]
    fn k8s_rows_cronjobs_only_unless_running() {
        fn l(job: &str) -> Vec<(&str, &str)> {
            vec![("namespace", "nas"), ("job_name", job)]
        }
        let mut owner_l = l("backup-1");
        owner_l.push(("owner_name", "backup"));
        let owner = [s(&owner_l, 1.0)];
        let start = [
            s(&l("backup-1"), 100.0),
            s(&l("helm-old"), 10.0),
            s(&l("adhoc"), 900.0),
        ];
        let done = [s(&l("backup-1"), 160.0), s(&l("helm-old"), 20.0)];
        let active = [s(&l("adhoc"), 1.0)];
        let mut j = k8s_rows(&owner, &start, &done, &active, &[], 1000, 50);
        j.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(j.len(), 2, "the old non-CronJob Job is not listed");
        assert_eq!(
            (j[0].name.as_str(), j[0].state),
            ("nas/adhoc", State::Running)
        );
        assert_eq!(
            (j[1].name.as_str(), j[1].secs, j[1].ok),
            ("nas/backup", Some(60), Some(true))
        );
    }
}
