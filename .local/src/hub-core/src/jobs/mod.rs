//! Every job that runs on its own, in one list: queued, running, and what finished in the
//! window, each with its start, duration, result and a way to read its log.
//!
//! Sources, and where each one's truth lives (nothing here keeps a copy):
//!
//! | source   | running / queued                         | finished                                        |
//! |----------|------------------------------------------|-------------------------------------------------|
//! | agentctl | `systemctl --user list-units agentctl@*`  | the run ledger `<state>/runs.jsonl` (agentctl)  |
//! | timer    | the same, for other timer-started units  | journald unit records (user journal retention)  |
//! | unity    | -                                        | `unity-test-runs/runs.tsv` (the slots ledger)   |
//! | ci       | runner-exporter `github_runner_state`, `github_actions_job_waiting` | `github_actions_run_recent` |
//! | k8s      | `kube_job_status_active`                  | `kube_job_status_*` (kube-state-metrics)        |
//!
//! A k8s Job's log is its pods' lines in Loki (`loki.rs`), read only when a row is opened.
//!
//! An unreadable source is named in `errors` and the rest still list: a run list judges nothing.

mod local;
pub mod log;
mod loki;
mod remote;
pub(crate) mod systemd;

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub use log::read_log;

/// What one source collector returns: its jobs, and every problem it met. A source that
/// failed outright returns no jobs and one error; one that skipped a bad record keeps the
/// rest and says what it skipped.
type Got = (Vec<Job>, Vec<String>);

/// A ledger's text; a file that does not exist yet is empty, anything else unreadable is an error.
pub(crate) fn read_or_empty(p: &std::path::Path) -> Result<String, String> {
    match std::fs::read_to_string(p) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("{}: {e}", p.display())),
    }
}

/// How far back finished runs are listed by default. The exporter and journald both hold
/// about a day, so a longer window would only be longer for some sources.
pub const DEFAULT_WINDOW_SECS: i64 = 24 * 3600;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Agentctl,
    Timer,
    Unity,
    Ci,
    K8s,
}

impl Source {
    pub const ALL: [Source; 5] = [
        Source::Agentctl,
        Source::Timer,
        Source::Unity,
        Source::Ci,
        Source::K8s,
    ];
    pub fn name(self) -> &'static str {
        match self {
            Source::Agentctl => "agentctl",
            Source::Timer => "timer",
            Source::Unity => "unity",
            Source::Ci => "ci",
            Source::K8s => "k8s",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Running,
    Queued,
    Done,
}

/// Where a run's output is, resolved to a path or a command only by `read_log`, which checks
/// every field: a reference may come back from a browser.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum LogRef {
    /// An agentctl runner's `<name>.stdout.log` and `.stderr.log`, between byte offsets. `None`
    /// as the end means "to the end of the file": the run is still going.
    Runner {
        name: String,
        out: (u64, Option<u64>),
        err: (u64, Option<u64>),
    },
    /// One systemd invocation in the user journal.
    Journal { invocation: String },
    /// A GitHub Actions run or job, by its URL.
    Gh { url: String, done: bool },
    /// A k8s Job's pod logs in Loki, from its start to its end (None: to now).
    K8s {
        ns: String,
        job: String,
        from: i64,
        to: Option<i64>,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Job {
    pub source: Source,
    pub name: String,
    pub state: State,
    /// Done only: true passed, false failed, None neither (cancelled, blocked, skipped).
    pub ok: Option<bool>,
    /// The source's own word for how it ended: WORKED, success, timeout, pass, failure.
    pub result: String,
    pub started: Option<i64>,
    pub finished: Option<i64>,
    /// How long it ran, or for a queued job how long it has waited.
    pub secs: Option<i64>,
    /// One line of context: branch, host, project, worktree.
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log: Option<LogRef>,
    /// Runs of this job in the window that this row stands for (see `collapse`); 1 for a row
    /// that is one run.
    pub runs: u32,
    /// A scheduled job's next start, when systemd knows it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next: Option<i64>,
}

impl Job {
    pub fn new(source: Source, name: impl Into<String>, state: State) -> Job {
        Job {
            source,
            name: name.into(),
            state,
            ok: None,
            result: String::new(),
            started: None,
            finished: None,
            secs: None,
            detail: String::new(),
            url: None,
            log: None,
            runs: 1,
            next: None,
        }
    }
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Queued => "queued",
            State::Done => "done",
        }
    }
}

/// The Jobs table on both surfaces: Infra's Jobs section in the hub and on agent-web.
impl crate::table::Row for Job {
    const COLUMNS: &'static [&'static str] = &[
        "state", "source", "name", "started", "took", "result", "detail",
    ];
    const STATES: &'static [&'static str] = &["all", "running", "queued", "done", "failed"];
    const FACETS: &'static [&'static str] = &["source", "result"];

    fn val(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        let text = |s: &str| Val::Text(s.to_string());
        let num = |n: Option<i64>| n.map_or(Val::None, |n| Val::Num(n as f64));
        match col {
            "state" => text(self.state.name()),
            "source" => text(self.source.name()),
            "name" => text(&self.name),
            "started" => num(self.started),
            "took" => num(self.secs),
            "result" if self.result.is_empty() => Val::None,
            "result" => text(&self.result),
            "detail" => text(&self.detail),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "failed" => self.ok == Some(false),
            s => self.state.name() == s,
        }
    }
}

#[derive(Serialize, Debug, Default)]
pub struct Jobs {
    /// When this was collected, unix seconds.
    pub at: i64,
    pub window_secs: i64,
    pub jobs: Vec<Job>,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// Where the file-backed sources live. Each honours the variable its own writer reads, so a
/// relocated install moves the writer and this reader together.
#[derive(Clone, Debug)]
pub struct Paths {
    /// agentctl's state dir: `runs.jsonl`, `<name>.std{out,err}.log`, `<name>/log-mark`.
    pub agentctl: PathBuf,
    pub unity_runs: PathBuf,
    /// Where finished GitHub logs are kept once fetched.
    pub cache: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let env = |k: &str| {
            std::env::var(k)
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let state = env("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local/state"));
        let agentctl = env("AGENTCTL_STATE_DIR")
            .or_else(|| env("AGENTCTL_STATE"))
            .unwrap_or_else(|| state.join("agentctl"));
        Paths {
            unity_runs: env("UNITY_RUN_LEDGER")
                .unwrap_or_else(|| state.join("unity-test-runs/runs.tsv")),
            cache: env("XDG_CACHE_HOME")
                .unwrap_or_else(|| home.join(".cache"))
                .join("hub"),
            agentctl,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Opts {
    pub window_secs: i64,
    /// Every run of this one job, none folded: the history behind one row.
    pub name: Option<String>,
    pub sources: Vec<Source>,
}

impl Default for Opts {
    fn default() -> Opts {
        Opts {
            window_secs: DEFAULT_WINDOW_SECS,
            name: None,
            sources: Source::ALL.to_vec(),
        }
    }
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// agentctl's runs that finished since `since` plus its running units, each run with its
/// next timer start: the Jobs tab's agentctl source, unfolded.
pub fn agentctl_runs(paths: &Paths, since: i64) -> (Vec<Job>, Vec<String>) {
    systemd::agentctl(paths, since, now())
}

/// The run ledger's text as runs, and how many lines could not be read.
pub fn parse_agentctl_ledger(text: &str, since: i64) -> (Vec<Job>, usize) {
    systemd::parse_ledger(text, since)
}

/// Each user timer's next start, unix seconds, keyed by the unit it starts
/// (`agentctl@<name>.service`); 0 when systemd has none.
pub fn timer_starts() -> Result<std::collections::HashMap<String, i64>, String> {
    systemd::timers_next()
}

/// Collect every source in parallel: the slow ones are network (Prometheus) and journald.
pub fn collect(paths: &Paths, opts: &Opts) -> Jobs {
    let at = now();
    let since = at - opts.window_secs;
    let mut out = Jobs {
        at,
        window_secs: opts.window_secs,
        ..Default::default()
    };
    let results: Vec<(Source, Got)> = std::thread::scope(|s| {
        let handles: Vec<_> = opts
            .sources
            .iter()
            .map(|&src| {
                s.spawn(move || {
                    let got = match src {
                        Source::Agentctl => systemd::agentctl(paths, since, at),
                        Source::Timer => systemd::timers(since, at),
                        Source::Unity => {
                            let (mut j, mut e) = local::unity(paths, since);
                            let (g, ge) = remote::gates(at);
                            j.extend(g);
                            e.extend(ge);
                            (j, e)
                        }
                        Source::Ci => remote::ci(at),
                        Source::K8s => remote::k8s(at, since),
                    };
                    (src, got)
                })
            })
            .collect();
        handles
            .into_iter()
            .zip(&opts.sources)
            .map(|(h, &src)| h.join().unwrap_or((src, (vec![], vec!["panicked".into()]))))
            .collect()
    });
    for (src, (jobs, errs)) in results {
        out.jobs.extend(jobs);
        out.errors
            .extend(errs.into_iter().map(|e| format!("{}: {e}", src.name())));
    }
    if let Some(n) = &opts.name {
        out.jobs.retain(|j| &j.name == n);
    } else {
        out.jobs = collapse(std::mem::take(&mut out.jobs));
    }
    sort(&mut out.jobs);
    out
}

/// A heartbeat timer runs 1440 times a day and would bury everything else. For the
/// systemd-started sources, each job keeps one row for its latest run (counting the rest in
/// `runs`) plus a row for every run that did not pass, so a failure is never folded away.
/// CI, k8s and unity runs are each their own piece of work and stay one row per run.
pub fn collapse(jobs: Vec<Job>) -> Vec<Job> {
    use std::collections::HashMap;
    let foldable =
        |j: &Job| matches!(j.source, Source::Agentctl | Source::Timer) && j.state == State::Done;
    let mut latest: HashMap<(Source, String), usize> = HashMap::new();
    let mut counts: HashMap<(Source, String), u32> = HashMap::new();
    for (i, j) in jobs.iter().enumerate() {
        if !foldable(j) {
            continue;
        }
        let k = (j.source, j.name.clone());
        *counts.entry(k.clone()).or_default() += 1;
        let e = latest.entry(k).or_insert(i);
        if j.finished > jobs[*e].finished {
            *e = i;
        }
    }
    let keep: std::collections::HashSet<usize> = latest.values().copied().collect();
    jobs.into_iter()
        .enumerate()
        .filter(|(i, j)| !foldable(j) || keep.contains(i) || j.ok == Some(false))
        .map(|(i, mut j)| {
            if keep.contains(&i) {
                j.runs = counts[&(j.source, j.name.clone())];
            }
            j
        })
        .collect()
}

/// Running first (newest start first), then queued (longest wait first), then finished
/// (newest first).
pub fn sort(jobs: &mut [Job]) {
    jobs.sort_by(|a, b| {
        a.state.cmp(&b.state).then_with(|| match a.state {
            State::Running => b.started.cmp(&a.started),
            State::Queued => b.secs.cmp(&a.secs),
            State::Done => b.finished.cmp(&a.finished),
        })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn done(src: Source, name: &str, fin: i64, ok: bool) -> Job {
        let mut j = Job::new(src, name, State::Done);
        j.finished = Some(fin);
        j.ok = Some(ok);
        j
    }

    #[test]
    fn collapse_keeps_the_latest_and_every_failure() {
        let jobs = vec![
            done(Source::Timer, "pulse", 100, true),
            done(Source::Timer, "pulse", 300, true),
            done(Source::Timer, "pulse", 200, false),
            done(Source::Ci, "gate", 100, true),
            done(Source::Ci, "gate", 200, true),
        ];
        let out = collapse(jobs);
        let pulse: Vec<_> = out.iter().filter(|j| j.name == "pulse").collect();
        assert_eq!(pulse.len(), 2, "latest + the failure");
        let latest = pulse.iter().find(|j| j.finished == Some(300)).unwrap();
        assert_eq!(latest.runs, 3);
        assert!(pulse.iter().any(|j| j.ok == Some(false)));
        assert_eq!(
            out.iter().filter(|j| j.name == "gate").count(),
            2,
            "CI is never folded"
        );
    }

    #[test]
    fn collapse_leaves_running_rows_alone() {
        let mut r = Job::new(Source::Agentctl, "sentinel", State::Running);
        r.started = Some(5);
        let out = collapse(vec![r.clone(), done(Source::Agentctl, "sentinel", 4, true)]);
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn sort_is_running_queued_done() {
        let mut q = Job::new(Source::Ci, "q", State::Queued);
        q.secs = Some(10);
        let mut r = Job::new(Source::Ci, "r", State::Running);
        r.started = Some(1);
        let mut v = vec![
            done(Source::Ci, "old", 1, true),
            q,
            done(Source::Ci, "new", 9, true),
            r,
        ];
        sort(&mut v);
        let names: Vec<_> = v.iter().map(|j| j.name.as_str()).collect();
        assert_eq!(names, ["r", "q", "new", "old"]);
    }
}
