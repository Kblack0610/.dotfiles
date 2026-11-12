//! The CI runners board: every machine's slots, the job each is running and the jobs waiting,
//! each with the runners that can take it. Both surfaces draw this one answer (the TUI's Infra
//! `ci` section and agent-web's), and `fleet-bench` reads `pool_match` through `hub ci`, so
//! there is one copy of the label join. It judges from the runner-exporter series `infra`
//! already read and asks Prometheus for nothing.
//!
//! A job runs only on a runner holding all its labels, compared without case (GitHub does the
//! same). A queued job no online runner can take is `Queued::missing`, the labels none holds:
//! the board draws it red, so a label standing in for a place (2026-11-10: `lan`) shows at a
//! glance instead of as an hour of queue.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde::Serialize;

use crate::infra::Infra;
use crate::links::{Kind, Link};
use crate::prom::Series;
use crate::table::{Row, Val};

/// A running job past this is amber whatever its usual: playground `ci.md` calls a gate that
/// runs past about an hour a bug to fix, not a wait.
const LONG_RUN_SECS: i64 = 3600;

/// Labels every runner and job carries, left out of NEEDS: they say where, not what.
const COMMON: &[&str] = &["self-hosted", "linux"];

/// One row of the machines table: a job running in a slot, or a run of slots in one state.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Slot {
    pub host: String,
    /// `3`, or `2-5` for a run of slots in the same state.
    pub slot: String,
    /// The runner pool (`cc:pool_*`'s label), `unity-local` for a local gate.
    pub pool: String,
    /// `busy`, `idle`, `withheld` (the governor holds it back), `off` (offline or missing) or
    /// `standby` (its host is powered off by the governor).
    pub state: String,
    pub job: String,
    pub repo: String,
    pub pr: String,
    pub branch: String,
    /// Seconds the job has run.
    pub ran: Option<i64>,
    /// The workflow's usual job time over the last day (the exporter's median).
    pub usual: Option<i64>,
    /// Past its usual p90, or past `LONG_RUN_SECS`.
    pub late: bool,
    /// What the governor says of a standby host.
    pub note: String,
}

/// A host that can take a job, and whether a slot is free there now.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Fit {
    pub host: String,
    /// `idle`, `busy`, `withheld` or `standby`.
    pub state: String,
}

/// One group of waiting jobs: the same job of the same run.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Queued {
    pub job: String,
    /// The pool the exporter files it under.
    pub pool: String,
    pub repo: String,
    pub pr: String,
    pub branch: String,
    pub n: u32,
    /// Seconds the oldest has waited.
    pub wait: i64,
    /// The labels it needs, less `COMMON`.
    pub needs: Vec<String>,
    /// Hosts with an online runner holding every label, free ones first. Empty: nobody can.
    pub can: Vec<Fit>,
    /// The labels no online runner holds, when nobody can take it.
    pub missing: Vec<String>,
    /// No online runner can take it: a label none of them holds, or no one runner holding all.
    pub stuck: bool,
}

impl Queued {
    /// The red line for a job nobody can take.
    pub fn problem(&self) -> String {
        let what = if self.repo.is_empty() {
            self.job.clone()
        } else {
            format!("{} ({})", self.job, self.repo)
        };
        let has = if self.missing.is_empty() {
            "no one online runner holds all of them".to_string()
        } else {
            format!("no online runner holds {}", self.missing.join(", "))
        };
        format!("{what} needs [{}]: {has}", self.needs.join(", "))
    }
}

#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Ci {
    pub hosts: u32,
    /// Slots as `cc:pool_slots` counts them: a running runner, or an idle one not withheld; a
    /// local gate counts as a slot and as busy.
    pub slots: u32,
    pub busy: u32,
    pub queued: u32,
    pub oldest: i64,
    pub rows: Vec<Slot>,
    pub queue: Vec<Queued>,
    /// The last day's finished runs per workflow, worst main pass rate first.
    pub finished: Vec<Finished>,
    /// Those runs added up, for the section's head.
    pub done: Tally,
    /// One red line per kind of job no online runner can take (`Queued::problem`), oldest first,
    /// with the count of waiting jobs when more than one. Both surfaces draw these as they are.
    pub red: Vec<String>,
}

impl Ci {
    fn red_lines(&self) -> Vec<String> {
        let mut by: Vec<(String, u32)> = vec![];
        for q in self.problems() {
            let line = q.problem();
            match by.iter_mut().find(|(l, _)| *l == line) {
                Some(e) => e.1 += q.n,
                None => by.push((line, q.n)),
            }
        }
        by.into_iter()
            .map(|(l, n)| if n > 1 { format!("{l} ({n} jobs)") } else { l })
            .collect()
    }

    /// The jobs no online runner can take, oldest first.
    pub fn problems(&self) -> Vec<&Queued> {
        let mut p: Vec<&Queued> = self.queue.iter().filter(|q| q.stuck).collect();
        p.sort_by_key(|q| std::cmp::Reverse(q.wait));
        p
    }

    /// `4 hosts, 15 slots, 11 busy, 6 queued (oldest 1h12m)`, or the quiet one.
    pub fn head(&self, dur: impl Fn(i64) -> String) -> String {
        let mut s = format!(
            "{} hosts, {} slots, {} busy, {} queued",
            self.hosts, self.slots, self.busy, self.queued
        );
        if self.queued > 0 {
            s += &format!(" (oldest {})", dur(self.oldest));
        }
        s
    }
}

/// A runner as the exporter reports it, one per name.
struct Runner<'a> {
    s: &'a Series,
    /// Its machine's one name (`Infra::aliases`): the runner label can be the node's hostname.
    host: String,
    labels: Vec<String>,
    held: bool,
}

fn lower(csv: &str) -> Vec<String> {
    csv.split(',')
        .map(|l| l.trim().to_lowercase())
        .filter(|l| !l.is_empty())
        .collect()
}

fn holds(have: &[String], need: &[String]) -> bool {
    need.iter().all(|x| have.contains(x))
}

/// One row per runner name, a running one winning when two exporter pods disagree during a
/// rollout.
fn runners(infra: &Infra) -> Vec<Runner<'_>> {
    let alias = infra.aliases();
    let held: HashSet<&str> = infra
        .get("withheld")
        .iter()
        .map(|s| s.label("name"))
        .collect();
    let mut by: BTreeMap<&str, &Series> = BTreeMap::new();
    for s in infra.get("runners") {
        let e = by.entry(s.label("name")).or_insert(s);
        if s.label("state") == "running" && e.label("state") != "running" {
            *e = s;
        }
    }
    by.into_iter()
        .map(|(n, s)| Runner {
            s,
            host: crate::infra::host(&alias, s.label("host")),
            labels: lower(s.label("labels")),
            held: held.contains(n),
        })
        .collect()
}

/// A runner's slot number: the digits after its last `-` or `/`, else its name less the host.
fn slot_of(name: &str, host: &str) -> String {
    let tail = name.rsplit(['-', '/']).next().unwrap_or(name);
    if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
        tail.to_string()
    } else {
        name.strip_prefix(host)
            .map(|s| s.trim_start_matches('-'))
            .filter(|s| !s.is_empty())
            .unwrap_or(name)
            .to_string()
    }
}

/// Slot numbers as ranges: `1,3-5`. A name that is no number is listed as it is.
fn ranges(mut slots: Vec<String>) -> String {
    slots.sort_by_key(|s| (s.parse::<u32>().unwrap_or(u32::MAX), s.clone()));
    let mut out: Vec<String> = vec![];
    let mut run: Option<(u32, u32)> = None;
    let flush = |run: &mut Option<(u32, u32)>, out: &mut Vec<String>| {
        if let Some((a, b)) = run.take() {
            out.push(if a == b {
                a.to_string()
            } else {
                format!("{a}-{b}")
            });
        }
    };
    for s in slots {
        match (s.parse::<u32>(), run) {
            (Ok(n), Some((a, b))) if n == b + 1 => run = Some((a, n)),
            (Ok(n), _) => {
                flush(&mut run, &mut out);
                run = Some((n, n));
            }
            (Err(_), _) => {
                flush(&mut run, &mut out);
                out.push(s);
            }
        }
    }
    flush(&mut run, &mut out);
    out.join(",")
}

/// The usual job time per (pool, workflow) from the exporter's day of finished jobs, as
/// (median, p90).
fn usual(infra: &Infra) -> HashMap<(String, String), (i64, Option<i64>)> {
    let mut by: HashMap<(String, String), (Option<i64>, Option<i64>)> = HashMap::new();
    for s in infra.get("job_usual") {
        let Some(v) = s.value.map(|v| v as i64) else {
            continue;
        };
        let e = by
            .entry((s.label("pool").into(), s.label("workflow").into()))
            .or_default();
        match s.label("quantile") {
            "0.5" => e.0 = Some(v),
            "0.9" => e.1 = Some(v),
            _ => {}
        }
    }
    by.into_iter()
        .filter_map(|(k, (m, p))| Some((k, (m?, p))))
        .collect()
}

fn job_name(s: &Series) -> String {
    ["job_name", "workflow"]
        .into_iter()
        .map(|k| s.label(k))
        .find(|v| !v.is_empty())
        .unwrap_or("-")
        .to_string()
}

pub fn build(infra: &Infra) -> Ci {
    let all = runners(infra);
    let off = infra.powered_off();
    let usual = usual(infra);
    let mut ci = Ci::default();
    let mut hosts: BTreeSet<String> = BTreeSet::new();
    let mut rows: Vec<Slot> = vec![];
    // Slots with no job to say, by host and state: they fold into one row per state.
    let mut quiet: BTreeMap<(String, &str, &str), Vec<String>> = BTreeMap::new();
    for r in &all {
        let s = r.s;
        let host = r.host.clone();
        hosts.insert(host.clone());
        let slot = slot_of(s.label("name"), s.label("host"));
        let pool = s.label("pool");
        match s.label("state") {
            "running" => {
                ci.slots += 1;
                ci.busy += 1;
                let ran = s.value.map(|v| v as i64).filter(|v| *v > 0);
                let u = usual
                    .get(&(s.label("pool").into(), s.label("workflow").into()))
                    .copied();
                let title = s.label("title");
                rows.push(Slot {
                    host,
                    slot,
                    pool: pool.into(),
                    state: "busy".into(),
                    job: job_name(s),
                    repo: s.label("repo").into(),
                    pr: s.label("pr").into(),
                    branch: if !title.is_empty() && title != s.label("workflow") {
                        title.into()
                    } else {
                        s.label("branch").into()
                    },
                    ran,
                    usual: u.map(|u| u.0),
                    late: ran.is_some_and(|t| {
                        t > LONG_RUN_SECS || u.and_then(|u| u.1).is_some_and(|p| t > p)
                    }),
                    note: String::new(),
                });
            }
            "idle" if r.held => quiet
                .entry((host, pool, "withheld"))
                .or_default()
                .push(slot),
            "idle" => {
                ci.slots += 1;
                quiet.entry((host, pool, "idle")).or_default().push(slot);
            }
            _ if off.contains_key(s.label("host")) => {
                quiet.entry((host, pool, "standby")).or_default().push(slot)
            }
            _ => quiet.entry((host, pool, "off")).or_default().push(slot),
        }
    }
    // A machine that is not a runner runs its gates locally: one busy row each, no slot number.
    for g in infra.get("gates") {
        let host = g.label("host").to_string();
        hosts.insert(host.clone());
        ci.slots += 1;
        ci.busy += 1;
        let repo = match g.label("repo") {
            "" => g.label("worktree"),
            r => r,
        };
        let branch = g.label("branch");
        let pr = infra
            .get("runners")
            .iter()
            .chain(infra.get("waiting"))
            .find(|s| {
                s.label("repo") == repo && s.label("branch") == branch && !s.label("pr").is_empty()
            })
            .map_or("", |s| s.label("pr"));
        let ran = g.value.map(|v| v as i64).filter(|v| *v > 0);
        rows.push(Slot {
            host,
            slot: "-".into(),
            pool: crate::machines::LOCAL_POOL.into(),
            state: "busy".into(),
            job: format!("{} (local)", g.label("platform")),
            repo: repo.into(),
            pr: pr.into(),
            branch: branch.into(),
            ran,
            late: ran.is_some_and(|t| t > LONG_RUN_SECS),
            ..Default::default()
        });
    }
    for ((host, pool, state), slots) in quiet {
        let note = match state {
            "standby" => format!(
                "governor {}",
                off.get(host.as_str()).copied().unwrap_or("off")
            ),
            "withheld" => "the governor holds it back".into(),
            _ => String::new(),
        };
        rows.push(Slot {
            host,
            slot: ranges(slots),
            pool: pool.into(),
            state: state.into(),
            note,
            ..Default::default()
        });
    }
    // Busy hosts first, then by name; on a host the longest job first, then idle, held, off.
    let busy_on = |h: &str| {
        rows.iter()
            .filter(|r| r.host == h && r.state == "busy")
            .count()
    };
    let order = |s: &str| {
        ["busy", "idle", "withheld", "standby", "off"]
            .iter()
            .position(|x| *x == s)
    };
    let host_rank: HashMap<String, usize> = hosts.iter().map(|h| (h.clone(), busy_on(h))).collect();
    rows.sort_by(|a, b| {
        host_rank[&b.host]
            .cmp(&host_rank[&a.host])
            .then_with(|| a.host.cmp(&b.host))
            .then_with(|| order(&a.state).cmp(&order(&b.state)))
            .then_with(|| a.pool.cmp(&b.pool))
            .then_with(|| b.ran.cmp(&a.ran))
            .then_with(|| a.slot.cmp(&b.slot))
    });
    ci.hosts = hosts.len() as u32;
    ci.rows = rows;
    ci.queue = queue(infra, &all, &off);
    ci.queued = ci.queue.iter().map(|q| q.n).sum();
    ci.oldest = ci.queue.iter().map(|q| q.wait).max().unwrap_or(0);
    ci.red = ci.red_lines();
    ci.finished = finished(infra);
    ci.done = ci
        .finished
        .iter()
        .fold(Tally::default(), |t, f| t.add(&f.all));
    ci
}

/// Waiting jobs grouped by job and run, oldest first. A stuck run (queued with no jobs) is RED
/// NOW's, so it cannot pass for the queue's age.
fn queue(infra: &Infra, all: &[Runner], off: &HashMap<&str, &str>) -> Vec<Queued> {
    let mut by: BTreeMap<[String; 5], Queued> = BTreeMap::new();
    for s in infra.get("waiting") {
        if s.label("stuck") == "true" {
            continue;
        }
        let labels = lower(s.label("labels"));
        let wait = s.value.map_or(0, |v| v as i64);
        let q = by
            .entry([
                job_name(s),
                s.label("repo").into(),
                s.label("pr").into(),
                s.label("branch").into(),
                labels.join(","),
            ])
            .or_insert_with(|| Queued {
                job: job_name(s),
                pool: s.label("pool").into(),
                repo: s.label("repo").into(),
                pr: s.label("pr").into(),
                branch: s.label("branch").into(),
                needs: s
                    .label("labels")
                    .split(',')
                    .map(str::trim)
                    .filter(|l| !l.is_empty() && !COMMON.contains(&l.to_lowercase().as_str()))
                    .map(String::from)
                    .collect(),
                ..Default::default()
            });
        q.n += 1;
        q.wait = q.wait.max(wait);
    }
    let online: Vec<&Runner> = all
        .iter()
        .filter(|r| {
            matches!(r.s.label("state"), "running" | "idle") || off.contains_key(r.s.label("host"))
        })
        .collect();
    let mut out: Vec<Queued> = by
        .into_iter()
        .map(|([.., labels], mut q)| {
            let need = lower(&labels);
            if !need.is_empty() {
                q.can = fits(all, off, &need);
            }
            q
        })
        .collect();
    for q in &mut out {
        q.stuck = q.can.is_empty() && !q.needs.is_empty();
        if q.stuck {
            // The labels no online runner holds; empty when each is held but never together.
            q.missing = q
                .needs
                .iter()
                .filter(|n| !online.iter().any(|r| r.labels.contains(&n.to_lowercase())))
                .cloned()
                .collect();
        }
    }
    out.sort_by(|a, b| b.wait.cmp(&a.wait).then_with(|| a.job.cmp(&b.job)));
    out
}

/// The hosts with an online runner (or one waiting on a powered-off host) holding every label.
fn fits(all: &[Runner], off: &HashMap<&str, &str>, need: &[String]) -> Vec<Fit> {
    let mut by: BTreeMap<&str, &str> = BTreeMap::new();
    let rank = |s: &str| {
        ["idle", "busy", "withheld", "standby"]
            .iter()
            .position(|x| *x == s)
            .unwrap_or(9)
    };
    for r in all.iter().filter(|r| holds(&r.labels, need)) {
        let state = match r.s.label("state") {
            "running" => "busy",
            "idle" if r.held => "withheld",
            "idle" => "idle",
            _ if off.contains_key(r.s.label("host")) => "standby",
            _ => continue,
        };
        let e = by.entry(r.host.as_str()).or_insert(state);
        if rank(state) < rank(e) {
            *e = state;
        }
    }
    let mut out: Vec<Fit> = by
        .into_iter()
        .map(|(host, state)| Fit {
            host: host.into(),
            state: state.into(),
        })
        .collect();
    out.sort_by_key(|f| (rank(&f.state), f.host.clone()));
    out
}

/// The slots in one pool that can take the jobs it has long waited on.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct PoolMatch {
    pub pool: String,
    /// Runners running or idle and not withheld, as `cc:pool_slots` counts them.
    pub slots: u32,
    pub busy: u32,
    /// Runners in any state: no slot because they are down reads differently from no runner
    /// with the labels.
    pub runners: u32,
    /// `<pool>/<label set> | <label set>`, each set sorted, as fleet-bench's finding names it.
    pub labels: String,
}

/// Per pool, the runners that can take the jobs waiting `min_wait` seconds or longer: a pool's
/// total busy/slots says nothing about a job that fits two of its ten runners (2026-11-05:
/// razer-laptop-unity-pool-1/2 were the only ones that matched while mac-studio slots sat idle).
/// Nothing when no job waits that long, or no runner is read: the finding then falls back to the
/// pool's own totals.
pub fn pool_match(infra: &Infra, min_wait: i64) -> Vec<PoolMatch> {
    let all = runners(infra);
    if all.is_empty() {
        return vec![];
    }
    let mut sets: BTreeMap<String, BTreeSet<Vec<String>>> = BTreeMap::new();
    for s in infra.get("waiting") {
        let mut labels = lower(s.label("labels"));
        labels.sort();
        if s.label("stuck") != "true"
            && s.value.is_some_and(|v| v as i64 >= min_wait)
            && !s.label("pool").is_empty()
            && !labels.is_empty()
        {
            sets.entry(s.label("pool").into())
                .or_default()
                .insert(labels);
        }
    }
    sets.into_iter()
        .map(|(pool, sets)| {
            let fit: Vec<&Runner> = all
                .iter()
                .filter(|r| sets.iter().any(|set| holds(&r.labels, set)))
                .collect();
            let slot = |r: &&&Runner| {
                r.s.label("state") == "running" || (r.s.label("state") == "idle" && !r.held)
            };
            PoolMatch {
                slots: fit.iter().filter(slot).count() as u32,
                busy: fit
                    .iter()
                    .filter(|r| r.s.label("state") == "running")
                    .count() as u32,
                runners: fit.len() as u32,
                labels: format!(
                    "{pool}/{}",
                    sets.iter()
                        .map(|s| s.join(","))
                        .collect::<Vec<_>>()
                        .join(" | ")
                ),
                pool,
            }
        })
        .collect()
}

/// `pool_match` as the tab-separated rows fleet-bench reads: metric, label, value.
pub fn pool_match_rows(infra: &Infra, min_wait: i64) -> String {
    pool_match(infra, min_wait)
        .iter()
        .flat_map(|m| {
            [
                format!("cc:pool_match_slots\t{}\t{}", m.pool, m.slots),
                format!("cc:pool_match_busy\t{}\t{}", m.pool, m.busy),
                format!("cc:pool_match_runners\t{}\t{}", m.pool, m.runners),
                format!("cc:pool_match_labels\t{}\t1", m.labels),
            ]
        })
        .map(|l| l + "\n")
        .collect()
}

/// Runs that passed, failed (or timed out) and were cancelled; a skipped or neutral run counts
/// in none, so `runs` can be more than their sum.
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq)]
pub struct Tally {
    pub runs: u32,
    pub ok: u32,
    pub bad: u32,
    pub can: u32,
}

impl Tally {
    fn add(self, o: &Tally) -> Tally {
        Tally {
            runs: self.runs + o.runs,
            ok: self.ok + o.ok,
            bad: self.bad + o.bad,
            can: self.can + o.can,
        }
    }

    /// Passed of passed and failed; a cancel is neither.
    pub fn pass(&self) -> Option<f64> {
        (self.ok + self.bad > 0).then(|| self.ok as f64 / (self.ok + self.bad) as f64)
    }
}

/// One workflow's last day of finished runs (`github_runs_finished`), split by where they ran:
/// a red on main is everyone's problem, a red gate on a work branch is usually the gate working.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Finished {
    pub repo: String,
    pub workflow: String,
    pub all: Tally,
    pub main: Tally,
    pub branch: Tally,
}

/// Main's pass rate leads: worst first, then the overall rate, then the most failures; the
/// workflows with nothing failed or cancelled after them, the busiest first.
fn finished(infra: &Infra) -> Vec<Finished> {
    let mut by: BTreeMap<(String, String), Finished> = BTreeMap::new();
    for s in infra.get("finished") {
        let f = by
            .entry((s.label("repo").into(), s.label("workflow").into()))
            .or_insert_with(|| Finished {
                repo: s.label("repo").into(),
                workflow: s.label("workflow").into(),
                ..Default::default()
            });
        let n = s.value.unwrap_or(0.0) as u32;
        let scope = match s.label("scope") {
            "main" => Some(&mut f.main),
            "branch" => Some(&mut f.branch),
            _ => None,
        };
        let add = |t: &mut Tally| {
            t.runs += n;
            match s.label("conclusion") {
                "success" => t.ok += n,
                "failure" | "timed_out" => t.bad += n,
                "cancelled" => t.can += n,
                _ => {}
            }
        };
        if let Some(t) = scope {
            add(t);
        }
        add(&mut f.all);
    }
    let mut out: Vec<Finished> = by.into_values().collect();
    let worst = |p: Option<f64>| p.unwrap_or(2.0);
    out.sort_by(|a, b| {
        b.red()
            .cmp(&a.red())
            .then_with(|| {
                if a.red() {
                    worst(a.main.pass())
                        .total_cmp(&worst(b.main.pass()))
                        .then_with(|| worst(a.all.pass()).total_cmp(&worst(b.all.pass())))
                        .then_with(|| b.all.bad.cmp(&a.all.bad))
                } else {
                    b.all.runs.cmp(&a.all.runs)
                }
            })
            .then_with(|| (&a.repo, &a.workflow).cmp(&(&b.repo, &b.workflow)))
    });
    out
}

impl Finished {
    /// Something failed or was cancelled.
    pub fn red(&self) -> bool {
        self.all.bad + self.all.can > 0
    }
}

fn opt(v: Option<i64>) -> Val {
    v.map_or(Val::None, |n| Val::Num(n as f64))
}

/// What a job or slot runs for: `repo#pr`, else its branch, else its repo.
fn reference(repo: &str, pr: &str, branch: &str) -> String {
    if !pr.is_empty() {
        format!("{repo}#{pr}")
    } else if !branch.is_empty() {
        branch.to_string()
    } else {
        repo.to_string()
    }
}

impl Slot {
    pub fn reference(&self) -> String {
        reference(&self.repo, &self.pr, &self.branch)
    }
}

impl Queued {
    pub fn reference(&self) -> String {
        reference(&self.repo, &self.pr, &self.branch)
    }
}

/// The CI runners table on both surfaces: each slot with the job it runs, idle and held runs of
/// slots folded to one row each.
impl Row for Slot {
    const COLUMNS: &'static [&'static str] = &[
        "host", "slot", "state", "pool", "ran", "usual", "job", "ref",
    ];
    const STATES: &'static [&'static str] =
        &["all", "busy", "idle", "withheld", "standby", "off", "late"];
    const FACETS: &'static [&'static str] = &["host", "state", "pool"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "host";
    const GLANCE: &'static [&'static str] = &["state", "ran", "job"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "host" => text(&self.host),
            "slot" => text(&self.slot),
            "state" => text(&self.state),
            "pool" => text(&self.pool),
            "ran" => opt(self.ran),
            "usual" => opt(self.usual),
            "job" if self.state == "busy" => text(&self.job),
            "job" => text(&self.note),
            "ref" => text(&self.reference()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "late" => self.late,
            s => self.state == s,
        }
    }
    fn rank(&self, col: &str) -> Val {
        match col {
            // `2-5` sorts by its first slot.
            "slot" => self
                .slot
                .split(['-', ','])
                .next()
                .and_then(|n| n.parse::<f64>().ok())
                .map_or_else(|| self.val(col), Val::Num),
            c => self.val(c),
        }
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "host" => Some(Link::to(Kind::Machine, &self.host)),
            "pool" if !self.pool.is_empty() => Some(Link::to(Kind::Pool, &self.pool)),
            _ => None,
        }
    }
}

/// The queued jobs on both surfaces: what each needs and the hosts that can take it, the ones no
/// online runner can take under `stuck`.
impl Row for Queued {
    const COLUMNS: &'static [&'static str] = &["job", "pool", "ref", "n", "wait", "needs", "can"];
    const STATES: &'static [&'static str] = &["all", "stuck", "free"];
    const FACETS: &'static [&'static str] = &["pool", "needs", "can"];
    const LEAD: &'static str = "job";
    const GLANCE: &'static [&'static str] = &["wait", "can"];

    fn val(&self, col: &str) -> Val {
        match col {
            "job" => Val::Text(self.job.clone()),
            "pool" if self.pool.is_empty() => Val::None,
            "pool" => Val::Text(self.pool.clone()),
            "ref" => Val::Text(self.reference()),
            "n" => Val::Num(self.n as f64),
            "wait" => Val::Num(self.wait as f64),
            "needs" => Val::Text(self.needs.join(", ")),
            "can" if self.can.is_empty() => Val::None,
            "can" => Val::Text(
                self.can
                    .iter()
                    .map(|f| format!("{} {}", f.host, f.state))
                    .collect::<Vec<_>>()
                    .join(", "),
            ),
            _ => Val::None,
        }
    }
    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "needs" => self.needs.iter().map(|n| Val::Text(n.clone())).collect(),
            "can" => self.can.iter().map(|f| Val::Text(f.host.clone())).collect(),
            c => vec![self.val(c)],
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "stuck" => self.stuck,
            "free" => self.can.iter().any(|f| f.state == "idle"),
            _ => false,
        }
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "pool" if !self.pool.is_empty() => Some(Link::to(Kind::Pool, &self.pool)),
            _ => None,
        }
    }
}

/// The finished-runs table on both surfaces: one row per workflow over the last day.
impl Row for Finished {
    const COLUMNS: &'static [&'static str] = &[
        "repo",
        "workflow",
        "main",
        "branches",
        "runs",
        "failed",
        "cancelled",
    ];
    const STATES: &'static [&'static str] = &["all", "red", "green"];
    const FACETS: &'static [&'static str] = &["repo"];
    const LEAD: &'static str = "workflow";
    const GLANCE: &'static [&'static str] = &["repo", "main", "failed"];

    fn val(&self, col: &str) -> Val {
        match col {
            "repo" => Val::Text(self.repo.clone()),
            "workflow" => Val::Text(self.workflow.clone()),
            "main" => self.main.pass().into(),
            "branches" => self.branch.pass().into(),
            "runs" => Val::Num(self.all.runs as f64),
            "failed" => Val::Num(self.all.bad as f64),
            "cancelled" => Val::Num(self.all.can as f64),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "red" => self.red(),
            "green" => !self.red(),
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn series(rows: Vec<(Value, &str)>) -> Vec<Series> {
        let res: Vec<Value> = rows
            .into_iter()
            .map(|(m, v)| json!({"metric": m, "value": [0, v]}))
            .collect();
        crate::prom::flatten(&json!({"status": "success", "data": {"result": res}})).unwrap()
    }

    fn runner(
        host: &str,
        name: &str,
        state: &str,
        v: &'static str,
        labels: &str,
        kw: Value,
    ) -> (Value, &'static str) {
        let mut m =
            json!({"host": host, "name": name, "state": state, "pool": "unity", "labels": labels});
        for (k, x) in kw.as_object().unwrap() {
            m[k] = x.clone();
        }
        (m, v)
    }

    fn waiting(job: &str, labels: &str, v: &'static str) -> (Value, &'static str) {
        (
            json!({"pool": "unity", "repo": "game", "branch": "main", "stuck": "false", "job_name": job,
                "workflow": "Soak", "labels": labels}),
            v,
        )
    }

    const FULL: &str = "self-hosted,linux,unity-full,lan";
    const WIDE: &str = "self-hosted,Linux,unity-full";

    fn board() -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert(
            "runners",
            series(vec![
                runner("razer", "razer-unity-pool-1", "running", "6000", FULL,
                    json!({"repo": "game", "branch": "main", "job_name": "Multi", "workflow": "Multi"})),
                runner("razer", "razer-unity-pool-2", "running", "1320", FULL,
                    json!({"repo": "game", "pr": "2210", "job_name": "Tests shard 2/3", "workflow": "Tests"})),
                runner("aws", "aws-unity-pool-1", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-2", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-3", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-4", "idle", "0", WIDE, json!({})),
                runner("spot", "spot-unity-pool-1", "offline", "0", WIDE, json!({})),
                runner("spot", "spot-unity-pool-2", "offline", "0", WIDE, json!({})),
            ]),
        );
        i.instant.insert(
            "waiting",
            series(vec![
                waiting(
                    "HD tests",
                    "self-hosted,linux,unity-full,hd-library",
                    "4320",
                ),
                waiting("HD tests", "self-hosted,linux,unity-full,hd-library", "100"),
                waiting("Soak", FULL, "3480"),
                waiting("Wide", WIDE, "30"),
                (
                    json!({"pool": "other", "repo": "x", "stuck": "true"}),
                    "999999",
                ),
            ]),
        );
        i.instant.insert(
            "job_usual",
            series(vec![
                (
                    json!({"pool": "unity", "workflow": "Multi", "quantile": "0.5"}),
                    "9180",
                ),
                (
                    json!({"pool": "unity", "workflow": "Multi", "quantile": "0.9"}),
                    "10000",
                ),
                (
                    json!({"pool": "unity", "workflow": "Tests", "quantile": "0.5"}),
                    "2640",
                ),
                (
                    json!({"pool": "unity", "workflow": "Tests", "quantile": "0.9"}),
                    "3000",
                ),
            ]),
        );
        i.instant.insert(
            "power",
            series(vec![(
                json!({"__name__": "ci_governor_power_state", "host": "spot", "state": "stopped"}),
                "1",
            )]),
        );
        i
    }

    #[test]
    fn a_host_is_its_busy_slots_longest_first_then_its_idle_ones_folded_to_a_range() {
        let ci = build(&board());
        let at: Vec<_> = ci
            .rows
            .iter()
            .map(|r| (r.host.as_str(), r.slot.as_str(), r.state.as_str()))
            .collect();
        assert_eq!(
            at,
            [
                ("razer", "1", "busy"),
                ("razer", "2", "busy"),
                ("aws", "1-4", "idle"),
                ("spot", "1-2", "standby"),
            ]
        );
        let multi = &ci.rows[0];
        assert_eq!(
            (multi.job.as_str(), multi.ran, multi.usual),
            ("Multi", Some(6000), Some(9180))
        );
        assert!(multi.late, "past the hour is amber whatever its usual");
        assert!(!ci.rows[1].late, "22m is under its 3000s p90");
        assert_eq!(ci.rows[3].note, "governor stopped");
        assert_eq!((ci.hosts, ci.slots, ci.busy), (3, 6, 2));
    }

    #[test]
    fn a_queued_job_names_the_hosts_that_can_take_it_free_ones_first() {
        let ci = build(&board());
        let soak = ci.queue.iter().find(|q| q.job == "Soak").unwrap();
        assert_eq!(soak.needs, ["unity-full", "lan"]);
        assert_eq!(
            soak.can,
            [Fit {
                host: "razer".into(),
                state: "busy".into()
            }]
        );
        assert!(!soak.stuck);
        // Matched without regard to case: aws holds `Linux`, the job asks `linux`.
        let wide = ci.queue.iter().find(|q| q.job == "Wide").unwrap();
        assert_eq!(
            wide.can[0],
            Fit {
                host: "aws".into(),
                state: "idle".into()
            }
        );
        // A busy host after the free one, and a powered-off host last: the governor wakes it.
        assert_eq!(
            wide.can[1],
            Fit {
                host: "razer".into(),
                state: "busy".into()
            }
        );
        assert_eq!(
            wide.can[2],
            Fit {
                host: "spot".into(),
                state: "standby".into()
            }
        );
        assert_eq!(
            (ci.queued, ci.oldest),
            (4, 4320),
            "the stuck run is no queue"
        );
    }

    #[test]
    fn a_job_no_online_runner_can_take_is_a_problem_naming_the_missing_label() {
        let ci = build(&board());
        let hd = &ci.problems()[0];
        assert_eq!((hd.job.as_str(), hd.n, hd.wait), ("HD tests", 2, 4320));
        assert_eq!(hd.missing, ["hd-library"]);
        assert_eq!(
            hd.problem(),
            "HD tests (game) needs [unity-full, hd-library]: no online runner holds hd-library"
        );
        assert_eq!(ci.problems().len(), 1, "Soak fits razer");
        // The red line carries the count of waiting jobs of that kind.
        assert_eq!(
            ci.red,
            ["HD tests (game) needs [unity-full, hd-library]: no online runner holds hd-library (2 jobs)"]
        );
        // A label held by a runner that is offline is still missing: it cannot take the job.
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![runner(
                "razer",
                "razer-unity-pool-1",
                "offline",
                "0",
                FULL,
                json!({}),
            )]),
        );
        let ci = build(&i);
        let soak = ci.queue.iter().find(|q| q.job == "Soak").unwrap();
        assert_eq!(soak.missing, ["unity-full", "lan"]);
    }

    #[test]
    fn each_label_held_but_never_together_says_so() {
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![
                runner("a", "a-1", "idle", "0", "self-hosted,unity-full", json!({})),
                runner("b", "b-1", "idle", "0", "self-hosted,lan", json!({})),
            ]),
        );
        i.instant
            .insert("waiting", series(vec![waiting("Soak", FULL, "10")]));
        let q = &build(&i).queue[0];
        assert!(q.missing.is_empty() && q.stuck);
        assert!(q
            .problem()
            .contains("no one online runner holds all of them"));
    }

    #[test]
    fn a_withheld_idle_runner_is_no_slot_and_takes_no_job() {
        let mut i = board();
        i.instant.insert(
            "withheld",
            series(vec![(json!({"name": "aws-unity-pool-1"}), "1")]),
        );
        let ci = build(&i);
        let held: Vec<_> = ci.rows.iter().filter(|r| r.state == "withheld").collect();
        assert_eq!((held.len(), held[0].slot.as_str()), (1, "1"));
        assert_eq!(ci.slots, 5);
        let idle = ci.rows.iter().find(|r| r.state == "idle").unwrap();
        assert_eq!(idle.slot, "2-4");
    }

    #[test]
    fn a_local_gate_is_a_busy_row_with_the_pr_of_its_branch() {
        let mut i = board();
        i.instant.insert(
            "gates",
            series(vec![(
                json!({"host": "workstation", "repo": "game", "branch": "main", "platform": "unity"}),
                "300",
            )]),
        );
        let ci = build(&i);
        let g = ci.rows.iter().find(|r| r.host == "workstation").unwrap();
        assert_eq!(
            (g.job.as_str(), g.slot.as_str(), g.ran),
            ("unity (local)", "-", Some(300))
        );
        assert_eq!(ci.hosts, 4);
    }

    #[test]
    fn two_pods_reporting_one_runner_count_it_once_the_running_one_winning() {
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![
                runner("razer", "razer-unity-pool-1", "idle", "0", FULL, json!({})),
                runner(
                    "razer",
                    "razer-unity-pool-1",
                    "running",
                    "5",
                    FULL,
                    json!({"pod": "b"}),
                ),
            ]),
        );
        let ci = build(&i);
        assert_eq!((ci.slots, ci.busy), (1, 1));
    }

    #[test]
    fn slots_are_numbered_by_the_runners_trailing_digits() {
        assert_eq!(slot_of("razer-laptop-unity-pool-2", "razer-laptop"), "2");
        assert_eq!(slot_of("forgejo-runner/3", "forgejo"), "3");
        assert_eq!(slot_of("mac-mini-builder", "mac-mini"), "builder");
        assert_eq!(
            ranges(vec!["5".into(), "1".into(), "2".into(), "9".into()]),
            "1-2,5,9"
        );
        assert_eq!(ranges(vec!["b".into(), "1".into()]), "1,b");
    }

    /// fleet-bench's `prom_match_rows` bats case, moved here with the join.
    #[test]
    fn pool_match_counts_the_runners_that_fit_the_long_waiting_jobs_withheld_and_offline_out() {
        let l = "self-hosted,linux,unity-full";
        let mut i = Infra::default();
        i.instant.insert(
            "waiting",
            series(vec![
                (json!({"pool": "unity", "stuck": "false", "labels": "self-hosted,Linux,unity-full"}), "7200"),
                (json!({"pool": "unity", "stuck": "false", "labels": l}), "7000"),
                (json!({"pool": "unity", "stuck": "false", "labels": "self-hosted,macOS"}), "60"),
            ]),
        );
        let r = |name: &str, state: &str, labels: &str, kw: Value| {
            runner("h", name, state, "5", labels, kw)
        };
        i.instant.insert(
            "runners",
            series(vec![
                r("razer-1", "running", l, json!({})),
                r("razer-1", "running", l, json!({"pod": "b"})),
                r("razer-2", "idle", l, json!({})),
                r("razer-3", "idle", l, json!({})),
                r("razer-4", "offline", l, json!({})),
                r("mac-1", "idle", "macOS,unity-full", json!({})),
                r("cachy-1", "idle", "self-hosted,linux", json!({})),
            ]),
        );
        i.instant
            .insert("withheld", series(vec![(json!({"name": "razer-3"}), "1")]));
        let m = pool_match(&i, 3600);
        assert_eq!(
            m,
            [PoolMatch {
                pool: "unity".into(),
                slots: 2,
                busy: 1,
                runners: 4,
                labels: "unity/linux,self-hosted,unity-full".into()
            }]
        );
        assert!(pool_match_rows(&i, 3600)
            .contains("cc:pool_match_labels\tunity/linux,self-hosted,unity-full\t1\n"));
        assert!(pool_match(&i, 9000).is_empty(), "nothing waits that long");
        i.instant.remove("runners");
        assert!(
            pool_match(&i, 3600).is_empty(),
            "no runner read, so no match"
        );
    }

    #[test]
    fn finished_runs_fold_by_workflow_with_a_red_on_main_first() {
        let mut i = board();
        let run = |wf: &str, scope: &str, c: &str, v: &'static str| {
            (
                json!({"repo": "game", "workflow": wf, "scope": scope, "conclusion": c}),
                v,
            )
        };
        i.instant.insert(
            "finished",
            series(vec![
                run("Tests", "main", "success", "9"),
                run("Tests", "branch", "success", "30"),
                run("Multi", "main", "failure", "1"),
                run("Multi", "main", "success", "1"),
                run("Multi", "branch", "cancelled", "2"),
                run("Lint", "branch", "failure", "3"),
                run("Lint", "branch", "success", "1"),
            ]),
        );
        let ci = build(&i);
        let names: Vec<&str> = ci.finished.iter().map(|f| f.workflow.as_str()).collect();
        // Multi failed on main; Lint only on branches, so it follows; Tests is green.
        assert_eq!(names, ["Multi", "Lint", "Tests"]);
        let multi = &ci.finished[0];
        assert_eq!((multi.main.pass(), multi.all.can), (Some(0.5), 2));
        assert_eq!(multi.branch.pass(), None);
        assert_eq!((ci.done.runs, ci.done.ok, ci.done.bad), (47, 41, 4));
        let (red, _) = crate::table::View::new::<Finished>("", "red", "", "").summary(&ci.finished);
        assert_eq!(red.len(), 2);
    }

    #[test]
    fn slots_and_queued_jobs_link_their_machine_and_pool() {
        let ci = build(&board());
        let (rows, s) = crate::table::View::new::<Slot>("", "busy", "", "").summary(&ci.rows);
        assert_eq!(rows.len(), 2);
        assert_eq!(s.links[0]["host"], "#infra/machines/razer");
        assert_eq!(s.links[0]["pool"], "#infra/pools/unity");
        let (_, s) = crate::table::View::new::<Queued>("", "", "", "").summary(&ci.queue);
        assert!(s.links.iter().all(|l| l["pool"] == "#infra/pools/unity"));
        let can: Vec<String> = s
            .facets
            .iter()
            .find(|f| f.key == "can")
            .unwrap()
            .values
            .iter()
            .map(|v| v.value.clone())
            .collect();
        assert!(
            can.iter()
                .all(|h| ["razer", "aws", "spot"].contains(&h.as_str())),
            "{can:?}"
        );
    }
}
