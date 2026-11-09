//! k8s Jobs (kube-state-metrics) and the Unity gates running now, from Prometheus.

use std::collections::HashMap;

use super::{Got, Job, LogRef, Source, State};
use crate::prom::{self, Series};

fn join(parts: &[&str]) -> String {
    parts
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn conclusion_ok(c: &str) -> Option<bool> {
    match c {
        "success" => Some(true),
        "failure" | "timed_out" | "startup_failure" => Some(false),
        _ => None,
    }
}

/// Local Unity gates running now. `runs.tsv` gets a gate only once it ends, so the running ones
/// come from `cc:host_local_gate` (value: seconds running), as on the infra board.
pub(super) fn gates(at: i64) -> Got {
    match prom::base().and_then(|b| prom::instant(&b, "cc:host_local_gate")) {
        Ok(s) => (gate_rows(&s, at), vec![]),
        Err(e) => (vec![], vec![e]),
    }
}

pub(super) fn gate_rows(gates: &[Series], at: i64) -> Vec<Job> {
    gates
        .iter()
        .map(|g| {
            let repo = match g.label("repo") {
                "" => g.label("worktree"),
                r => r,
            };
            let mut j = Job::new(
                Source::Unity,
                join(&[repo, g.label("platform")]),
                State::Running,
            );
            j.secs = g.value.map(|v| v as i64);
            j.started = j.secs.map(|v| at - v);
            j.detail = join(&[g.label("branch"), g.label("worktree"), g.label("host")]);
            j
        })
        .collect()
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
            j.log = k.started.map(|from| LogRef::K8s {
                ns: ns.clone(),
                job: job.clone(),
                from,
                to: k.finished,
            });
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
    fn a_running_local_gate_is_a_unity_row_started_its_seconds_ago() {
        let g = [s(
            &[
                ("host", "workstation"),
                ("worktree", "pg-agent-9"),
                ("branch", "fix/x"),
                ("platform", "EditMode"),
                ("repo", ""),
            ],
            45.0,
        )];
        let j = gate_rows(&g, 1000);
        assert_eq!((j[0].source, j[0].state), (Source::Unity, State::Running));
        assert_eq!(
            (j[0].name.as_str(), j[0].started),
            ("pg-agent-9 EditMode", Some(955))
        );
        assert_eq!(j[0].detail, "fix/x pg-agent-9 workstation");
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
        assert_eq!(
            j[1].log,
            Some(LogRef::K8s {
                ns: "nas".into(),
                job: "backup-1".into(),
                from: 100,
                to: Some(160)
            }),
            "a row opens its own Job's pods, not the CronJob's"
        );
    }
}
