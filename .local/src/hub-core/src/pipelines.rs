//! Infra's Pipelines view: one row per workflow of each repo, on or off, when it is scheduled,
//! when it next runs, how its last run went and how it usually goes. A repo `schedules-sync`
//! reads lists every workflow file on its base, run or not; a repo it does not read (Forgejo)
//! lists the workflows the builds ledger has runs of.
//!
//! | fact                       | home                                                              |
//! |----------------------------|-------------------------------------------------------------------|
//! | which pipelines            | state.json (`schedules-sync`): the base's files, scheduled (`workflows`) and not (`unscheduled`); else the ledger's `(repo, path)` |
//! | its crons, purpose, jobs   | state.json `workflows[]`                                          |
//! | on or held from the night  | state.json `night`: the repo's `scripts/night.json`, by file name |
//! | what starts the night      | the registry: `trackers.<repo>.nightRunner`; its schedule, next and last start from its conf and timer (`schedules::runner_starts`) |
//! | its runs                   | the builds ledger by the workflow's file; a night member's by its nightly title (`builds::timed_as`), so a PR's affected run of the same file is not the nightly |
//! | pass, runs, usual, p90     | `builds::time_of` over those runs, the ledger's window (`builds::KEEP_DAYS`) |
//!
//! How a row's state is decided is on [`one`].

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;

use crate::builds::{self, Run};
use crate::links::{Kind, Link};
use crate::schedules::{self, CiRepo, CiState, CiWorkflow, Starts};
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// How long past a due start a pipeline may go without a run before it reads late: a GitHub
/// cron slot can start hours behind, and the night set runs for over an hour.
pub const LATE_SECS: i64 = 3 * 3600;
/// The runs an opened pipeline lists, newest first.
pub const DETAIL_RUNS: usize = 10;

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Pipeline {
    /// `red`, `amber`, `ok` or `off`.
    pub state: String,
    /// Why it is in that state: `last run on main failed 11-11 22:04`.
    pub why: String,
    pub forge: String,
    /// The repo's slug; `project` is what the column draws.
    pub repo: String,
    pub project: String,
    pub pipeline: String,
    /// The workflow's file in the repo (`.github/workflows/test.yml`); the column draws its name.
    pub file: String,
    /// What started its runs, most first (`dispatch, pr`), and `cron` when it has one.
    pub trigger: String,
    /// `on` in the night set, `held` out of it, empty when not a member.
    pub nightly: String,
    /// Its crons in words, or the night runner's schedule.
    pub schedule: String,
    pub next: Option<i64>,
    /// The runner that starts the night set, for a member.
    pub runner: Option<String>,
    /// When its last finished run started.
    pub last: Option<i64>,
    pub last_id: Option<u64>,
    /// The last finished run's conclusion.
    pub last_result: String,
    /// The pass rate (`builds::verdict`) of its finished runs; none when none counted.
    pub pass: Option<u32>,
    pub runs: usize,
    pub usual: Option<i64>,
    pub p90: Option<i64>,
    pub running: usize,
    /// The Schedules row its next start is on: the runner, else `<repo> / <name>` for a cron.
    #[serde(skip)]
    next_row: String,
}

impl Pipeline {
    fn rank(&self) -> u8 {
        match self.state.as_str() {
            "red" => 0,
            "amber" => 1,
            _ => 2,
        }
    }

    fn file_name(&self) -> &str {
        self.file.rsplit('/').next().unwrap_or(&self.file)
    }
}

impl Row for Pipeline {
    const COLUMNS: &'static [&'static str] = &[
        "state", "repo", "pipeline", "file", "trigger", "nightly", "schedule", "next", "last",
        "pass", "runs", "usual", "p90", "running",
    ];
    const STATES: &'static [&'static str] = &["all", "red", "amber", "ok", "off"];
    const FACETS: &'static [&'static str] = &["repo", "trigger", "nightly"];
    const LEAD: &'static str = "pipeline";
    const GLANCE: &'static [&'static str] = &["state", "next", "pass"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        ("red", "its last run on the base failed"),
        (
            "amber",
            "late for a start, or its last base run stopped before a verdict",
        ),
        (
            "ok",
            "its last run on the base passed, or it runs only on branches",
        ),
        (
            "off",
            "held from the night, or nothing ran it in the window",
        ),
    ];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" | "-" => Val::None,
            s => Val::Text(s.to_string()),
        };
        let num = |v: Option<i64>| v.map_or(Val::None, |v| Val::Num(v as f64));
        match col {
            "state" => text(&self.state),
            "repo" => text(&self.project),
            "pipeline" => text(&self.pipeline),
            "file" => text(self.file_name()),
            "trigger" => text(&self.trigger),
            "nightly" => text(&self.nightly),
            "schedule" => text(&self.schedule),
            "next" => num(self.next),
            "last" => num(self.last),
            "pass" => self.pass.map_or(Val::None, |p| Val::Num(f64::from(p))),
            "runs" => Val::Num(self.runs as f64),
            "usual" => num(self.usual),
            "p90" => num(self.p90),
            "running" if self.running > 0 => Val::Num(self.running as f64),
            _ => Val::None,
        }
    }

    /// `trigger:cron` finds `dispatch, cron`.
    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "trigger" => self
                .trigger
                .split(", ")
                .filter(|t| !t.is_empty())
                .map(|t| Val::Text(t.to_string()))
                .collect(),
            _ => vec![self.val(col)],
        }
    }

    fn in_state(&self, state: &str) -> bool {
        state == "all" || self.state == state
    }

    /// The last run opens its record, the next start its Schedules row, the repo its project.
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "last" => self
                .last_id
                .map(|id| Link::to(Kind::CiRun, format!("{}/{id}", self.project))),
            "next" if !self.next_row.is_empty() => {
                Some(Link::to(Kind::Schedule, self.next_row.clone()))
            }
            "repo" => Some(Link::to(Kind::Project, self.project.clone())),
            _ => None,
        }
    }

    fn text(&self) -> String {
        [
            &self.state,
            &self.repo,
            &self.project,
            &self.pipeline,
            &self.file,
            &self.trigger,
            &self.nightly,
            &self.schedule,
            &self.why,
        ]
        .map(String::as_str)
        .join("\n")
        .to_lowercase()
    }
}

/// Every pipeline, red first, then amber, then by repo and name.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Pipelines {
    pub at: i64,
    /// `52 pipelines in 9 repos, 2 red, 4 held from the night`.
    pub summary: String,
    pub red: usize,
    pub rows: Vec<Pipeline>,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// An opened pipeline: what it is for, what it is made of, and its last runs.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Detail {
    pub row: Pipeline,
    pub purpose: Option<String>,
    /// Each cron and its words: `0 9 * * 1 (09:00 Mon)`.
    pub crons: Vec<String>,
    /// Its jobs by layer (`schedules::layers`).
    pub jobs: String,
    /// The run title the night set starts it as, for a member.
    pub night_title: Option<String>,
    pub runs: Vec<DetailRun>,
}

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct DetailRun {
    pub id: u64,
    pub attempt: u32,
    pub started: i64,
    pub branch: String,
    pub event: String,
    pub title: String,
    pub state: String,
    pub conclusion: Option<String>,
    pub took: Option<i64>,
    /// Its record (`links::Kind::CiRun`).
    pub link: Link,
}

/// What the view is built from: state.json, the night runners and their starts.
#[derive(Debug, Default, Clone)]
pub struct Sources {
    pub ci: CiState,
    /// A repo's slug to the runner that starts its night set (`Registry::night_runner`).
    pub runners: BTreeMap<String, String>,
    pub starts: Vec<Starts>,
    pub errors: Vec<String>,
    pub at: i64,
    /// The local zone, seconds east of UTC.
    pub off: i32,
}

/// Read state.json, the registry's night runners and their starts. The ledger's runs are the
/// caller's, as each surface already holds them (agent-web's `builds::current`).
pub fn sources(runner: &dyn Runner) -> Sources {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut s = Sources {
        at: crate::jobs::now(),
        off: chrono::Local::now().offset().local_minus_utc(),
        ..Default::default()
    };
    let state = schedules::state_path(&home);
    match std::fs::read_to_string(&state)
        .map_err(|e| format!("{}: {e}", state.display()))
        .and_then(|t| schedules::ci_state(&t))
    {
        Ok(ci) => s.ci = ci,
        Err(e) => s.errors.push(format!("schedules-sync: {e}")),
    }
    let night: Vec<&CiRepo> = s.ci.repos.iter().filter(|r| r.night.is_some()).collect();
    if night.is_empty() {
        return s;
    }
    let reg = project_map::Registry::load();
    for r in night {
        match reg.as_ref().and_then(|g| g.night_runner(&r.repo)) {
            Some(n) => {
                s.runners.insert(r.repo.clone(), n);
            }
            None => s.errors.push(format!(
                "registry: {} has a night set but no nightRunner",
                r.repo
            )),
        }
    }
    let names: Vec<&str> = s.runners.values().map(String::as_str).collect();
    let (starts, e) = schedules::runner_starts(&crate::fleet::Paths::from_env(), runner, &names);
    s.starts = starts;
    s.errors.extend(e);
    s
}

/// One pipeline with what its detail needs.
struct Built<'a> {
    row: Pipeline,
    wf: Option<&'a CiWorkflow>,
    title: Option<String>,
    runs: Vec<&'a Run>,
}

/// One workflow file of a repo, before it is read against its runs.
struct File<'a> {
    path: &'a str,
    wf: Option<&'a CiWorkflow>,
    /// `on` or `held`, and the title the night set runs it as.
    night: Option<(&'static str, &'a str)>,
}

fn base_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn trigger_word(event: &str) -> &str {
    match event {
        "schedule" => "cron",
        "workflow_dispatch" => "dispatch",
        "pull_request" | "pull_request_target" => "pr",
        "workflow_run" => "after",
        e => e,
    }
}

/// Each file a repo state.json reads has on its base, with its night membership.
fn files_of<'a>(repo: &'a CiRepo, errors: &mut Vec<String>) -> Vec<File<'a>> {
    let mut out: Vec<File> = repo
        .workflows
        .iter()
        .map(|w| File {
            path: &w.path,
            wf: Some(w),
            night: None,
        })
        .chain(repo.unscheduled.keys().map(|p| File {
            path: p,
            wf: None,
            night: None,
        }))
        .collect();
    let Some(n) = &repo.night else {
        return out;
    };
    if let Some(e) = &n.error {
        errors.push(format!("{}: {e}", repo.repo));
    }
    let sets = [("on", &n.night), ("held", &n.held)];
    for (word, set) in sets {
        for (name, title) in set {
            match out.iter_mut().find(|f| base_name(f.path) == name) {
                Some(f) => f.night = Some((word, title.as_str())),
                None => errors.push(format!(
                    "{}: scripts/night.json names {name}, which is not a workflow on {}",
                    repo.repo,
                    base_of(repo)
                )),
            }
        }
    }
    out
}

fn base_of(repo: &CiRepo) -> &str {
    if repo.base.is_empty() {
        "main"
    } else {
        &repo.base
    }
}

/// Build every pipeline from `s` and the ledger's `runs` (settled, as `builds::read` gives them).
fn built<'a>(s: &'a Sources, runs: &'a [Run], errors: &mut Vec<String>) -> Vec<Built<'a>> {
    let mut out = vec![];
    for repo in &s.ci.repos {
        if let Some(e) = repo.error.as_deref().filter(|e| !e.is_empty()) {
            errors.push(format!("{}: {e}", repo.repo));
        }
        let mine: Vec<&Run> = runs
            .iter()
            .filter(|r| r.repo.eq_ignore_ascii_case(&repo.repo))
            .collect();
        for f in files_of(repo, errors) {
            let of: Vec<&Run> = mine
                .iter()
                .copied()
                .filter(|r| r.path == f.path)
                .filter(|r| {
                    f.night
                        .is_none_or(|(_, t)| builds::timed_as(&r.workflow, &r.path) == t)
                })
                .collect();
            out.push(one(s, &repo.repo, base_of(repo), f, of));
        }
    }
    // A repo state.json does not read (a Forgejo one) is what the ledger ran: its base is the
    // branch its pushes and crons ran on.
    let mut rest: BTreeMap<(&str, &str, &str), Vec<&Run>> = BTreeMap::new();
    for r in runs.iter().filter(|r| {
        !r.path.starts_with("dynamic/")
            && !s
                .ci
                .repos
                .iter()
                .any(|c| c.repo.eq_ignore_ascii_case(&r.repo))
    }) {
        let path = if r.path.is_empty() {
            &r.workflow
        } else {
            &r.path
        };
        rest.entry((&r.forge, &r.repo, path)).or_default().push(r);
    }
    let mut bases: HashMap<&str, HashMap<&str, usize>> = HashMap::new();
    for r in rest.values().flatten() {
        if matches!(r.event.as_str(), "push" | "schedule") {
            *bases
                .entry(&r.repo)
                .or_default()
                .entry(&r.branch)
                .or_default() += 1;
        }
    }
    for ((forge, repo, path), of) in rest {
        let base = bases
            .get(repo)
            .and_then(|b| {
                b.iter()
                    .max_by_key(|(name, n)| (**n, std::cmp::Reverse(**name)))
            })
            .map_or("main", |(b, _)| b);
        let f = File {
            path,
            wf: None,
            night: None,
        };
        let mut b = one(s, repo, base, f, of);
        b.row.forge = forge.to_string();
        out.push(b);
    }
    out
}

/// One file's row from its runs. Its state, first that holds: `off` held from the night (and no
/// cron of its own); `red` its newest finished run on the base failed; `amber` a start it was
/// due (a cron slot, the night runner's last start) is `LATE_SECS` past with no run since, or
/// its newest base run stopped before a verdict (cancelled), or it is scheduled and nothing
/// finished on the base in the window; `ok` its newest base run passed, or it runs only on
/// branches; `off` nothing ran it.
fn one<'a>(s: &Sources, slug: &str, base: &str, f: File<'a>, mut runs: Vec<&'a Run>) -> Built<'a> {
    runs.sort_by(|a, b| b.started.cmp(&a.started).then(b.attempt.cmp(&a.attempt)));
    let crons: &[String] = f.wf.map_or(&[], |w| &w.crons);
    let short = slug.rsplit('/').next().unwrap_or(slug);
    let mut row = Pipeline {
        forge: "github".into(),
        repo: slug.to_string(),
        project: project_map::canonical(slug),
        file: f.path.to_string(),
        nightly: f.night.map(|(w, _)| w.to_string()).unwrap_or_default(),
        ..Default::default()
    };
    row.pipeline = match (f.night, f.wf) {
        (Some((_, t)), _) => t.to_string(),
        (None, Some(w)) if !w.name.is_empty() => w.name.clone(),
        _ => one_title(&runs).unwrap_or_else(|| {
            base_name(f.path)
                .trim_end_matches(".yml")
                .trim_end_matches(".yaml")
                .to_string()
        }),
    };

    // The trigger: what started its runs, most first, and `cron` for a schedule not yet run.
    let mut events: BTreeMap<&str, usize> = BTreeMap::new();
    for r in &runs {
        *events.entry(trigger_word(&r.event)).or_default() += 1;
    }
    let mut words: Vec<(&str, usize)> = events.into_iter().collect();
    words.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    let mut trigger: Vec<&str> = words.into_iter().map(|(w, _)| w).collect();
    if !crons.is_empty() && !trigger.contains(&"cron") {
        trigger.push("cron");
    }
    row.trigger = trigger.join(", ");

    // When it is due: a night member by its runner, anything else by its crons.
    let on = f.night.is_some_and(|(w, _)| w == "on");
    let start = on
        .then(|| s.runners.get(slug))
        .flatten()
        .and_then(|n| s.starts.iter().find(|st| &st.name == n));
    if on {
        row.runner = s.runners.get(slug).cloned();
    }
    // The start that meets a due one: the night runner dispatches, a cron slot is a `schedule`
    // run, each on the base. A push, a PR or a branch's gate run says nothing about the miss.
    let mut due = None;
    let mut meets = "schedule";
    if let Some(st) = start {
        meets = "workflow_dispatch";
        row.schedule = st.schedule.clone();
        row.next = st.next;
        row.next_row = st.name.clone();
        due = st.fired.filter(|t| *t <= s.at - LATE_SECS);
    } else if !crons.is_empty() {
        row.schedule = crons
            .iter()
            .map(|c| schedules::cron_words(c, s.off))
            .collect::<Vec<_>>()
            .join("; ");
        row.next = crons
            .iter()
            .filter_map(|c| schedules::cron_next(c, s.at))
            .min();
        row.next_row = format!("{short} / {}", f.wf.map_or("", |w| w.name.as_str()));
        due = crons
            .iter()
            .filter_map(|c| schedules::cron_prev(c, s.at - LATE_SECS))
            .max();
    }

    let t = builds::time_of(runs.iter().copied());
    let finished: Vec<&Run> = runs
        .iter()
        .copied()
        .filter(|r| r.done() && r.conclusion.as_deref() != Some("skipped"))
        .collect();
    row.runs = t.runs;
    row.usual = t.usual.map(|u| u.median);
    row.p90 = t.usual.map(|u| u.p90);
    row.running = t.running;
    row.pass = finished
        .iter()
        .any(|r| builds::verdict(r.conclusion.as_deref()).is_some())
        .then_some(t.pass);
    let on_base = finished.iter().find(|r| r.branch == base);
    if let Some(r) = on_base.or(finished.first()) {
        row.last = Some(r.started);
        row.last_id = Some(r.id);
        row.last_result = r.conclusion.clone().unwrap_or_default();
    }

    let when = |t: i64| schedules::local(t, s.off, "%m-%d %H:%M");
    let late = due.filter(|d| {
        !runs
            .iter()
            .any(|r| r.started >= *d && r.event == meets && r.branch == base)
    });
    let scheduled = start.is_some() || !crons.is_empty();
    let held = f.night.is_some_and(|(w, _)| w == "held");
    let verdict = on_base.map(|r| builds::verdict(r.conclusion.as_deref()));
    let (state, why) = match (verdict, late) {
        _ if held && crons.is_empty() => ("off", "held from the night".to_string()),
        (Some(Some(false)), _) => {
            let r = on_base.expect("a verdict is a run's");
            (
                "red",
                format!("last run on {base} failed {}", when(r.started)),
            )
        }
        (_, Some(d)) => ("amber", format!("no run since the start due {}", when(d))),
        (Some(None), _) => {
            let r = on_base.expect("a verdict is a run's");
            let c = r.conclusion.as_deref().unwrap_or("stopped");
            (
                "amber",
                format!("last run on {base} {c} {}", when(r.started)),
            )
        }
        (Some(Some(true)), _) => ("ok", format!("last run on {base} passed")),
        (None, _) if scheduled => ("amber", format!("no finished run on {base} in the window")),
        (None, _) if !runs.is_empty() => ("ok", format!("runs only on branches, none on {base}")),
        (None, _) => ("off", "no run in the window".to_string()),
    };
    row.state = state.into();
    row.why = why;
    if on && start.is_none() {
        row.why.push_str(", no night runner read");
    }
    Built {
        row,
        wf: f.wf,
        title: f.night.map(|(_, t)| t.to_string()),
        runs,
    }
}

/// The title every run carries, when they share one: a workflow whose runs carry its
/// name. A title that varies (`Tests (affected, <branch>)`) names a run, not the workflow, so
/// the file names it instead.
fn one_title(runs: &[&Run]) -> Option<String> {
    let mut titles = runs.iter().map(|r| &r.workflow);
    let first = titles.next()?;
    titles.all(|t| t == first).then(|| first.clone())
}

/// Every pipeline in `s` against the ledger's `runs`, red first.
pub fn pipelines(s: &Sources, runs: &[Run]) -> Pipelines {
    let mut errors = s.errors.clone();
    let mut rows: Vec<Pipeline> = built(s, runs, &mut errors)
        .into_iter()
        .map(|b| b.row)
        .collect();
    rows.sort_by_cached_key(|r| {
        let lower = |s: &str| s.to_lowercase();
        (
            r.rank(),
            lower(&r.project),
            lower(&r.pipeline),
            r.file.clone(),
        )
    });
    let red = rows.iter().filter(|r| r.state == "red").count();
    let held = rows.iter().filter(|r| r.nightly == "held").count();
    let repos = {
        let mut r: Vec<&str> = rows.iter().map(|r| r.repo.as_str()).collect();
        r.sort_unstable();
        r.dedup();
        r.len()
    };
    Pipelines {
        at: s.at,
        summary: format!(
            "{} pipelines in {repos} repos, {red} red, {held} held from the night",
            rows.len()
        ),
        red,
        rows,
        errors,
    }
}

/// The pipeline `repo` (a slug or project name) and `file` (its path or file name) name.
pub fn detail(s: &Sources, runs: &[Run], repo: &str, file: &str) -> Option<Detail> {
    let b = built(s, runs, &mut vec![]).into_iter().find(|b| {
        (b.row.repo.eq_ignore_ascii_case(repo) || b.row.project == project_map::canonical(repo))
            && (b.row.file == file || b.row.file_name() == file)
    })?;
    let wf = b.wf;
    Some(Detail {
        purpose: wf.and_then(|w| w.purpose.clone()),
        crons: wf.map_or(vec![], |w| {
            w.crons
                .iter()
                .map(|c| format!("{c} ({})", schedules::cron_words(c, s.off)))
                .collect()
        }),
        jobs: wf.map_or(String::new(), |w| schedules::layers(&w.jobs)),
        night_title: b.title,
        runs: b
            .runs
            .iter()
            .take(DETAIL_RUNS)
            .map(|r| DetailRun {
                id: r.id,
                attempt: r.attempt,
                started: r.started,
                branch: r.branch.clone(),
                event: r.event.clone(),
                title: r.title.clone(),
                state: r.state.clone(),
                conclusion: r.conclusion.clone(),
                took: r.took,
                link: Link::to(Kind::CiRun, format!("{}/{}", b.row.project, r.id)),
            })
            .collect(),
        row: b.row,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 2026-11-12 12:00 UTC, a Thursday.
    const NOW: i64 = 1_794_484_800;
    const H: i64 = 3600;

    fn iso(t: i64) -> String {
        chrono::DateTime::from_timestamp(t, 0)
            .unwrap()
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string()
    }

    /// A finished run `age` seconds ago that took 10 minutes: its path, title, event, branch and
    /// conclusion.
    fn run(repo: &str, id: u64, [path, title, event, branch, c]: [&str; 5], age: i64) -> String {
        json!({
            "forge": if repo.starts_with("me/") { "forgejo" } else { "github" },
            "repo": repo, "id": id, "attempt": 1, "workflow": title, "path": path,
            "title": title, "branch": branch, "event": event, "status": "completed",
            "conclusion": c, "created_at": iso(NOW - age), "started_at": iso(NOW - age),
            "ended_at": iso(NOW - age + 600), "url": "u",
        })
        .to_string()
    }

    fn state() -> CiState {
        schedules::ci_state(
            &json!({"repos": [{
                "repo": "Org/game", "base": "main",
                "workflows": [
                    {"path": ".github/workflows/vuln-scan.yml", "name": "Vuln scan",
                     "crons": ["0 9 * * 1"], "purpose": "Scan the lockfiles",
                     "jobs": [{"id": "scan"}, {"id": "file", "needs": ["scan"]}]},
                    {"path": ".github/workflows/gates.yml", "name": "Drop gates",
                     "crons": ["0 6 * * *"]}
                ],
                "unscheduled": {
                    ".github/workflows/test.yml": "s1", ".github/workflows/multi.yml": "s2",
                    ".github/workflows/checks.yml": "s3", ".github/workflows/ios.yml": "s4", ".github/workflows/hd.yml": "s5"
                },
                "night": {"night": {"test.yml": "Tests (all)"},
                          "held": {"multi.yml": "Multi (all)", "gone.yml": "Gone (all)"},
                          "sha": "n1"}
            }]})
            .to_string(),
        )
        .unwrap()
    }

    fn sources(fired: i64) -> Sources {
        Sources {
            ci: state(),
            runners: BTreeMap::from([("Org/game".into(), "game-night".into())]),
            starts: vec![Starts {
                name: "game-night".into(),
                schedule: "22:00 daily".into(),
                next: Some(NOW + 10 * H),
                fired: Some(fired),
            }],
            at: NOW,
            ..Default::default()
        }
    }

    fn runs(night_age: i64) -> Vec<Run> {
        let (t, hd) = (".github/workflows/test.yml", ".github/workflows/hd.yml");
        let text = [
            run(
                "Org/game",
                1,
                [t, "Tests (all)", "workflow_dispatch", "main", "failure"],
                night_age,
            ),
            run(
                "Org/game",
                2,
                [
                    t,
                    "Tests (affected)",
                    "workflow_dispatch",
                    "feat/a",
                    "success",
                ],
                H,
            ),
            run(
                "Org/game",
                3,
                [
                    ".github/workflows/multi.yml",
                    "Multi (all)",
                    "workflow_dispatch",
                    "main",
                    "failure",
                ],
                20 * H,
            ),
            run(
                "Org/game",
                4,
                [
                    ".github/workflows/checks.yml",
                    "Checks",
                    "pull_request",
                    "feat/a",
                    "failure",
                ],
                2 * H,
            ),
            run(
                "Org/game",
                5,
                [
                    ".github/workflows/checks.yml",
                    "Checks",
                    "pull_request",
                    "feat/b",
                    "success",
                ],
                3 * H,
            ),
            run(
                "Org/game",
                6,
                [
                    ".github/workflows/checks.yml",
                    "Checks",
                    "push",
                    "main",
                    "success",
                ],
                4 * H,
            ),
            run(
                "Org/game",
                7,
                [
                    ".github/workflows/vuln-scan.yml",
                    "Vuln scan",
                    "schedule",
                    "main",
                    "success",
                ],
                3 * 24 * H,
            ),
            run(
                "Org/game",
                8,
                [
                    ".github/workflows/gates.yml",
                    "Drop gates",
                    "schedule",
                    "main",
                    "success",
                ],
                2 * 24 * H,
            ),
            run(
                "Org/game",
                11,
                [hd, "HD tests (a)", "workflow_dispatch", "main", "success"],
                H,
            ),
            run(
                "Org/game",
                12,
                [hd, "HD tests (b)", "workflow_dispatch", "feat/b", "success"],
                2 * H,
            ),
            run(
                "me/home",
                9,
                ["checks.yaml", "checks.yaml", "push", "master", "cancelled"],
                H,
            ),
            run(
                "me/home",
                10,
                [
                    "checks.yaml",
                    "checks.yaml",
                    "pull_request",
                    "fix/x",
                    "success",
                ],
                2 * H,
            ),
        ]
        .join("\n");
        builds::parse(&text, NOW).0
    }

    fn row<'a>(p: &'a Pipelines, name: &str) -> &'a Pipeline {
        p.rows
            .iter()
            .find(|r| r.pipeline == name)
            .unwrap_or_else(|| panic!("{name}"))
    }

    #[test]
    fn each_workflow_is_a_row_red_first_and_the_night_set_runs_on_its_runner() {
        let p = pipelines(&sources(NOW - 14 * H), &runs(14 * H - 60));
        let order: Vec<(&str, &str)> = p
            .rows
            .iter()
            .map(|r| (r.state.as_str(), r.pipeline.as_str()))
            .collect();
        assert_eq!(
            order,
            [
                ("red", "Tests (all)"),
                ("amber", "Drop gates"),
                ("amber", "checks.yaml"),
                ("ok", "Checks"),
                ("ok", "hd"),
                ("off", "ios"),
                ("off", "Multi (all)"),
                ("ok", "Vuln scan"),
            ]
        );
        assert_eq!(
            p.summary,
            "8 pipelines in 2 repos, 1 red, 1 held from the night"
        );
        assert_eq!(p.red, 1);

        let t = row(&p, "Tests (all)");
        assert_eq!((t.nightly.as_str(), t.trigger.as_str()), ("on", "dispatch"));
        assert_eq!(
            (t.schedule.as_str(), t.next),
            ("22:00 daily", Some(NOW + 10 * H))
        );
        assert_eq!(t.runner.as_deref(), Some("game-night"));
        assert_eq!((t.last_id, t.last_result.as_str()), (Some(1), "failure"));
        assert_eq!(
            (t.runs, t.pass),
            (1, Some(0)),
            "the PR's affected run is not the nightly"
        );
        assert!(t.why.starts_with("last run on main failed"), "{}", t.why);
        assert_eq!(
            t.link("next").unwrap().href(),
            "#schedules?q=name:=game-night"
        );
        let last = t.link("last").unwrap().href();
        assert!(
            last.starts_with("#infra/runs/") && last.ends_with("%2F1"),
            "{last}"
        );

        let m = row(&p, "Multi (all)");
        assert_eq!(
            (m.nightly.as_str(), m.why.as_str()),
            ("held", "held from the night")
        );
        assert_eq!(
            (m.next, m.last_id),
            (None, Some(3)),
            "held: no next, its last run kept"
        );

        let g = row(&p, "Drop gates");
        assert!(
            g.why.starts_with("no run since the start due 11-12 06:00"),
            "{}",
            g.why
        );
        assert_eq!(g.trigger, "cron");
        // A push on main since the missed slot is no scheduled start: still late. Only a
        // `schedule` run on the base clears it (negative control).
        let mut pushed = runs(28 * H);
        let mut late_push = builds::parse(
            &run(
                "Org/game",
                20,
                [
                    ".github/workflows/gates.yml",
                    "Drop gates",
                    "push",
                    "main",
                    "success",
                ],
                H,
            ),
            NOW,
        )
        .0;
        pushed.append(&mut late_push.clone());
        assert_eq!(
            row(&pipelines(&sources(NOW - 29 * H), &pushed), "Drop gates").state,
            "amber"
        );
        late_push[0].event = "schedule".into();
        let mut cleared = runs(28 * H);
        cleared.append(&mut late_push);
        assert_eq!(
            row(&pipelines(&sources(NOW - 29 * H), &cleared), "Drop gates").state,
            "ok"
        );
        let v = row(&p, "Vuln scan");
        assert_eq!(
            (v.schedule.as_str(), v.next),
            ("09:00 Mon", Some(NOW + 4 * 24 * H - 3 * H))
        );
        assert_eq!(
            v.link("next").unwrap().href(),
            "#schedules?q=name:=%22game%20%2F%20Vuln%20scan%22"
        );

        let c = row(&p, "Checks");
        assert_eq!(
            (c.trigger.as_str(), c.last_id, c.pass),
            ("pr, push", Some(6), Some(66))
        );
        assert_eq!(
            c.vals("trigger"),
            [Val::Text("pr".into()), Val::Text("push".into())]
        );

        let f = row(&p, "checks.yaml");
        assert_eq!(
            (f.forge.as_str(), f.why.as_str()),
            ("forgejo", "last run on master cancelled 11-12 11:00")
        );
        assert_eq!(row(&p, "ios").why, "no run in the window");
        assert_eq!(
            row(&p, "Checks").file,
            ".github/workflows/checks.yml",
            "one title names it"
        );
        assert_eq!(
            row(&p, "hd").last_id,
            Some(11),
            "titles that vary: the file names it"
        );
        assert_eq!(
            p.errors,
            ["Org/game: scripts/night.json names gone.yml, which is not a workflow on main"]
        );
    }

    #[test]
    fn a_night_member_is_late_when_its_runner_started_hours_ago_and_no_run_followed() {
        let late = pipelines(&sources(NOW - 4 * H), &runs(28 * H));
        let t = row(&late, "Tests (all)");
        assert_eq!(t.state, "red", "a red last run outranks late");
        let mut green = runs(28 * H);
        let one = green.iter_mut().find(|r| r.id == 1).unwrap();
        one.conclusion = Some("success".into());
        let late = pipelines(&sources(NOW - 4 * H), &green);
        let t = row(&late, "Tests (all)");
        assert_eq!(t.state, "amber");
        assert!(
            t.why.starts_with("no run since the start due 11-12 08:00"),
            "{}",
            t.why
        );
        // Negative control: the run that followed the start clears it.
        let on_time = pipelines(&sources(NOW - 29 * H), &green);
        assert_eq!(row(&on_time, "Tests (all)").state, "ok");
        // A runner the registry does not name leaves the row unscheduled, and says so.
        let mut s = sources(NOW - 4 * H);
        s.runners.clear();
        let t = pipelines(&s, &green)
            .rows
            .into_iter()
            .find(|r| r.pipeline == "Tests (all)")
            .unwrap();
        assert_eq!(
            (t.schedule.as_str(), t.next, t.state.as_str()),
            ("", None, "ok")
        );
        assert!(t.why.ends_with(", no night runner read"), "{}", t.why);
    }

    /// This account's pipelines as JSON: `cargo test real_pipelines -- --ignored --nocapture`;
    /// `SCHEDULES_STATE` and `PROJECT_MAP_FILE` point it at another state.json and registry.
    #[test]
    #[ignore = "reads this account's state and timers; a proof run by hand"]
    fn real_pipelines() {
        let b = builds::read(&builds::Paths::from_env(), None, crate::jobs::now());
        let s = super::sources(&crate::session_actions::System);
        let p = pipelines(&s, &b.rows);
        println!("{}", serde_json::to_string(&p).unwrap());
    }

    #[test]
    fn an_opened_pipeline_has_its_purpose_crons_jobs_and_its_own_runs() {
        let (s, r) = (sources(NOW - 14 * H), runs(14 * H - 60));
        let d = detail(&s, &r, "org/GAME", "vuln-scan.yml").unwrap();
        assert_eq!(d.purpose.as_deref(), Some("Scan the lockfiles"));
        assert_eq!(d.crons, ["0 9 * * 1 (09:00 Mon)"]);
        assert_eq!(d.jobs, schedules::layers(&s.ci.repos[0].workflows[0].jobs));
        let t = detail(&s, &r, "Org/game", ".github/workflows/test.yml").unwrap();
        assert_eq!(t.night_title.as_deref(), Some("Tests (all)"));
        let ids: Vec<u64> = t.runs.iter().map(|r| r.id).collect();
        assert_eq!(ids, [1]);
        assert!(t.runs[0].link.href().starts_with("#infra/runs/"));
        assert!(detail(&s, &r, "Org/game", "nope.yml").is_none());
    }
}
