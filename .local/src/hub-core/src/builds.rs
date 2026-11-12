//! Infra's CI runs, both surfaces: every CI run of the last 30 days on GitHub and Forgejo, from
//! `schedules-sync`'s run ledger (`~/.local/state/ci/runs.jsonl`), each with the session that owns
//! its branch. The ledger is append-only (a run is written again each time it changes), so a run is
//! its last line. A failed run's log is fetched only when the row is opened (docs/dashboards.md
//! rule 10), through the fetch and cache `jobs::read_log` already has. The opened run's jobs, steps
//! and cost are `detail` (`run_detail`), read from local files only. Releases' Release runs are the
//! same read cut to the runs the graph tied to a release (`Builds::scoped`). Money is a cloud
//! machine's POWER cell on Infra Machines and Costs', so the Run times fold has none.
//!
//! | fact                | home                                                           |
//! |---------------------|----------------------------------------------------------------|
//! | the runs            | `$SCHEDULES_RUNS_LEDGER`, else `<state>/ci/runs.jsonl`          |
//! | when it last synced | `sync.json` beside it: its `generated_at` and a `error` per repo |
//! | the owner session   | fleet-sessions' `state.json`: the live session on the branch, else its PR's item's |
//! | a run's PRs and release | joined on read by `release_graph`, from the PR store, the queue and `release-state` |
//! | the usual run time  | computed on read from the same runs (`time`), nothing stored     |
//! | the pass rate       | computed on read (`verdict`, `pass_by_repo`): the one CI pass rate |
//! | a run's jobs        | `$SCHEDULES_JOBS_LEDGER`, else `<state>/ci/jobs.jsonl` (`run_detail`) |
//! | the test quarantine | `$SCHEDULES_QUARANTINE`, else `quarantine.json` beside the ledger (`quarantine`) |

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::jobs::{self, LogRef};
use crate::quarantine;
use crate::releases::Level;
use crate::run_detail::{self, Rates, RunDetail};
use crate::table::{Row, Val};

/// How long the ledger keeps a run, and so how far back this section reaches.
pub const KEEP_DAYS: i64 = 30;

/// How far back a red run still colours the count line.
pub const RECENT_SECS: i64 = 86400;

/// Where the files live. Each honours the variable its writer reads.
#[derive(Clone, Debug)]
pub struct Paths {
    pub ledger: PathBuf,
    pub sync: PathBuf,
    pub fleet: PathBuf,
    /// The PR store (`release_graph::prs_dir`): what a run's PRs are joined from.
    pub prs: PathBuf,
    /// The job archive: every job of each run, keyed as the ledger is.
    pub jobs: PathBuf,
    /// Each repo's test quarantine and its last nightly's counts.
    pub quarantine: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let env = |k: &str| {
            std::env::var_os(k)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let state = env("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local/state"));
        let ledger = env("SCHEDULES_RUNS_LEDGER").unwrap_or_else(|| state.join("ci/runs.jsonl"));
        Paths {
            sync: ledger.with_file_name("sync.json"),
            quarantine: env("SCHEDULES_QUARANTINE")
                .unwrap_or_else(|| ledger.with_file_name("quarantine.json")),
            ledger,
            fleet: crate::boards::fleet_state(),
            prs: crate::release_graph::prs_dir(),
            jobs: env("SCHEDULES_JOBS_LEDGER").unwrap_or_else(|| state.join("ci/jobs.jsonl")),
        }
    }

    /// Whether a changed file is the ledger, its sync record, the job archive or the quarantine:
    /// what wakes the section.
    pub fn is_ledger_file(&self, p: &Path) -> bool {
        p == self.ledger || p == self.sync || p == self.jobs || p == self.quarantine
    }
}

/// One CI run as the ledger last wrote it, with the words a row draws.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Run {
    pub forge: String,
    pub repo: String,
    pub id: u64,
    pub attempt: u32,
    pub workflow: String,
    /// The workflow's file in the repo (`.github/workflows/tests.yml`), when the forge gives one.
    pub path: String,
    pub title: String,
    pub branch: String,
    pub event: String,
    pub sha: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub created_at: String,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub url: String,
    /// The PRs it ran for (`release_graph::Graph::run_prs`): joined on read, never stored.
    #[serde(skip_deserializing)]
    pub prs: Vec<u64>,
    /// The session working on the branch, else the one whose item landed its PR (several are
    /// joined with a comma); empty for a run no session owns, which is drawn `-`.
    #[serde(skip_deserializing)]
    pub owner: String,
    /// The release it deployed or ran on its tag for (`release_graph::Graph::release`).
    #[serde(skip_deserializing)]
    pub release: Option<crate::release_graph::RunRelease>,
    /// `running`, `queued`, `green`, `red` or `other` (cancelled, skipped).
    #[serde(skip_deserializing)]
    pub state: String,
    #[serde(skip_deserializing)]
    pub level: Level,
    /// When it started (queued: when it was created), unix seconds.
    #[serde(skip_deserializing)]
    pub started: i64,
    /// How long it ran; a queued run's wait; a running one's time so far.
    #[serde(skip_deserializing)]
    pub took: Option<i64>,
    /// What its workflow usually takes (`time`); none below `USUAL_MIN` finished runs.
    #[serde(skip_deserializing)]
    pub usual: Option<Usual>,
    /// A running run's expected end: its start plus the usual median, unix seconds.
    #[serde(skip_deserializing)]
    pub eta: Option<i64>,
}

/// A workflow's median and 90th-percentile run time in seconds, over its finished runs.
#[derive(Serialize, Debug, Default, Clone, Copy, PartialEq)]
pub struct Usual {
    pub median: i64,
    pub p90: i64,
}

/// Below this many finished runs a workflow has no usual time and its runs no ETA: a guess
/// drawn as a number reads as a fact.
pub const USUAL_MIN: usize = 3;

/// One workflow's run times over the window: the Builds section's Run times fold.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct RunTime {
    pub forge: String,
    pub repo: String,
    /// The name its runs are timed under (`timed_as`).
    pub workflow: String,
    /// Finished runs counted: success, failure and timeout. 0 for a workflow only running.
    pub runs: usize,
    pub usual: Option<Usual>,
    pub longest: i64,
    /// The pass rate (`verdict`) of its finished runs, a whole percent.
    pub pass: u32,
    pub running: usize,
}

impl RunTime {
    /// The project the repo is, through the name index (`project_map::canonical`).
    pub fn project(&self) -> String {
        project_map::canonical(&self.repo)
    }
}

impl Run {
    pub fn key(&self) -> RunKey {
        RunKey {
            forge: self.forge.clone(),
            repo: self.repo.clone(),
            id: self.id,
            attempt: self.attempt,
        }
    }

    /// Finished, so its log no longer changes.
    pub fn done(&self) -> bool {
        matches!(self.state.as_str(), "green" | "red" | "other")
    }

    /// The project the repo is, through the name index (`project_map::canonical`).
    pub fn project(&self) -> String {
        project_map::canonical(&self.repo)
    }
}

/// What names one run in a request: the ledger is looked up by it, so a caller never supplies a
/// URL or a path.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq, Eq, Hash)]
pub struct RunKey {
    pub forge: String,
    pub repo: String,
    /// `run_id` in the job archive and on `/api/builds/detail`.
    #[serde(alias = "run_id")]
    pub id: u64,
    pub attempt: u32,
}

impl Row for Run {
    // `forge`, `event`, `title`, `sha` and `url` filter without a column on the page: the first two
    // are dropdowns, the third is the open row's heading. `release` is the tag the run deployed or
    // ran on (`release_graph`), `-` for the rest.
    const COLUMNS: &'static [&'static str] = &[
        "started", "state", "repo", "workflow", "branch", "took", "usual", "eta", "owner",
        "release", "forge", "event", "title",
    ];
    const STATES: &'static [&'static str] = &["all", "running", "queued", "red", "green"];
    const FACETS: &'static [&'static str] = &["repo", "forge", "event", "state"];
    const LEAD: &'static str = "workflow";
    const GLANCE: &'static [&'static str] = &["state", "repo", "took"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" | "-" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "started" => Val::Num(self.started as f64),
            "repo" => text(&self.project()),
            "forge" => text(&self.forge),
            "workflow" => text(&self.workflow),
            "branch" => text(&self.branch),
            "event" => text(&self.event),
            "state" => text(&self.state),
            "took" => self.took.map_or(Val::None, |n| Val::Num(n as f64)),
            "usual" => self.usual.map_or(Val::None, |u| Val::Num(u.median as f64)),
            "eta" => self.eta.map_or(Val::None, |n| Val::Num(n as f64)),
            "owner" => text(&self.owner),
            "title" => text(&self.title),
            "release" => self.release.as_ref().map_or(Val::None, |r| text(&r.tag)),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        self.state == state || state == "all"
    }

    /// A bare word searches what the row says: the owner, the sha, the PR numbers and the
    /// release tag too.
    fn text(&self) -> String {
        let prs: Vec<String> = self.prs.iter().map(|n| format!("#{n}")).collect();
        let tag = self.release.as_ref().map_or("", |r| r.tag.as_str());
        [
            self.repo.as_str(),
            &self.workflow,
            &self.branch,
            &self.event,
            &self.owner,
            &self.title,
            &self.sha,
            &prs.join(" "),
            tag,
        ]
        .join("\n")
        .to_lowercase()
    }
}

/// How the runs divide: what the section's summary and Infra's line count.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Counts {
    pub total: usize,
    pub running: usize,
    pub queued: usize,
    pub red: usize,
    /// Red runs begun within `RECENT_SECS`: what colours a line quoting the counts.
    pub recent_red: usize,
}

impl Counts {
    fn of<'a>(rows: impl IntoIterator<Item = &'a Run>, now: i64) -> Counts {
        let mut c = Counts::default();
        for r in rows {
            c.total += 1;
            match r.state.as_str() {
                "running" => c.running += 1,
                "queued" => c.queued += 1,
                "red" => {
                    c.red += 1;
                    c.recent_red += usize::from(now - r.started < RECENT_SECS);
                }
                _ => {}
            }
        }
        c
    }

    /// `212 runs in 30 days: 3 running, 2 queued, 14 red`.
    pub fn says(&self) -> String {
        format!(
            "{} run{} in {KEEP_DAYS} days: {} running, {} queued, {} red",
            self.total,
            if self.total == 1 { "" } else { "s" },
            self.running,
            self.queued,
            self.red
        )
    }

    /// The worst thing the counts say, for the colour of a line that quotes them. A red run
    /// older than `RECENT_SECS` is history: 30 days of runs always hold one.
    pub fn level(&self) -> Level {
        if self.recent_red > 0 {
            Level::Bad
        } else if self.queued > 0 {
            Level::Warn
        } else {
            Level::Ok
        }
    }
}

/// The section's one read. `at` is when the collector last finished a pass (0 when it never has).
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Builds {
    pub at: i64,
    pub counts: Counts,
    /// The counts of the runs tied to a release (`Scope::Release`), taken with `counts`.
    pub released: Counts,
    pub rows: Vec<Run>,
    /// Each workflow's run times, by repo, the most-run first.
    pub times: Vec<RunTime>,
    /// Why the ledger or a repo could not be read: a red line, never a silent blank.
    pub errors: Vec<String>,
    /// Each repo's test quarantine: the Quarantine fold, none when no repo has one.
    pub quarantine: Vec<quarantine::Lane>,
}

/// Which runs a runs table lists: every CI run (Infra's) or the runs the graph tied to a release
/// (it deployed one, or ran on its tag: Releases' Release runs).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Scope {
    #[default]
    All,
    Release,
}

impl Scope {
    /// agent-web's `scope=`: `release`, else every run.
    pub fn named(s: &str) -> Scope {
        if s == "release" {
            Scope::Release
        } else {
            Scope::All
        }
    }

    pub fn keeps(self, r: &Run) -> bool {
        self == Scope::All || r.release.is_some()
    }
}

/// One scope's runs, borrowed from the read: what a runs table and its heading draw. Run times
/// and the quarantine are Infra's, so the `Release` scope carries none.
pub struct Scoped<'a> {
    pub rows: Vec<&'a Run>,
    pub counts: Counts,
    pub times: &'a [RunTime],
    pub quarantine: &'a [quarantine::Lane],
    pub errors: &'a [String],
}

impl Scoped<'_> {
    /// `looks` over this scope's runs: the count on the inner tab they are on.
    pub fn needs_look(&self) -> bool {
        looks(&self.counts, self.errors)
    }

    pub fn summary(&self) -> String {
        self.counts.says()
    }
}

/// A run went red in the last `RECENT_SECS`, or the ledger did not read. Older reds are history,
/// as `Counts::level` says.
fn looks(counts: &Counts, errors: &[String]) -> bool {
    !errors.is_empty() || counts.level() == Level::Bad
}

impl Builds {
    /// The runs `scope` lists, in the ledger's order.
    pub fn rows_in(&self, scope: Scope) -> Vec<&Run> {
        self.rows.iter().filter(|r| scope.keeps(r)).collect()
    }

    /// The read cut to `scope`, with that scope's counts; `All` is the read as it is.
    pub fn scoped(&self, scope: Scope) -> Scoped<'_> {
        let all = scope == Scope::All;
        Scoped {
            rows: self.rows_in(scope),
            counts: if all {
                self.counts.clone()
            } else {
                self.released.clone()
            },
            times: if all { &self.times } else { &[] },
            quarantine: if all { &self.quarantine } else { &[] },
            errors: &self.errors,
        }
    }

    /// `looks` over every run: the count on Infra's CI inner tab.
    pub fn needs_look(&self) -> bool {
        looks(&self.counts, &self.errors)
    }

    /// The collector has not finished a pass in longer than its cadence explains.
    pub fn stale(&self, now: i64) -> bool {
        self.at > 0 && now - self.at > STALE_SECS
    }
}

/// `schedules-sync.timer` runs every 10 minutes; a pass older than three of them is late.
pub const STALE_SECS: i64 = 1800;

fn state_of(status: &str, conclusion: Option<&str>) -> &'static str {
    match (status, conclusion.unwrap_or_default()) {
        ("in_progress" | "running", _) => "running",
        ("completed", "success") => "green",
        ("completed", "failure" | "timed_out" | "startup_failure" | "action_required") => "red",
        ("completed", _) => "other",
        _ => "queued",
    }
}

impl Run {
    /// Sets the words a row draws from the ledger's fields: its state and level, when it started
    /// (`created`, epoch seconds, when the ledger has no start) and how long it has taken.
    pub(crate) fn settle(&mut self, created: i64, now: i64) {
        self.state = state_of(&self.status, self.conclusion.as_deref()).to_string();
        self.level = match self.state.as_str() {
            "red" => Level::Bad,
            "queued" => Level::Warn,
            _ => Level::Ok,
        };
        let began = self.started_at.as_deref().and_then(crate::fleet::ts);
        self.started = began.unwrap_or(created);
        self.took = match self.state.as_str() {
            "queued" => Some((now - created).max(0)),
            "running" => Some((now - self.started).max(0)),
            _ => self
                .ended_at
                .as_deref()
                .and_then(crate::fleet::ts)
                .map(|e| (e - self.started).max(0)),
        };
    }
}

/// The ledger's runs: each run once, as its last line wrote it, none older than `KEEP_DAYS`,
/// with the words a row draws. The second value counts lines that did not parse.
pub fn parse(text: &str, now: i64) -> (Vec<Run>, usize) {
    let mut by_key: HashMap<RunKey, Run> = HashMap::new();
    let mut bad = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        match serde_json::from_str::<Run>(line) {
            Ok(r) => {
                by_key.insert(r.key(), r);
            }
            Err(_) => bad += 1,
        }
    }
    let floor = now - KEEP_DAYS * 86400;
    let mut rows: Vec<Run> = by_key
        .into_values()
        .filter_map(|mut r| {
            let created = crate::fleet::ts(&r.created_at)?;
            (created >= floor).then(|| {
                r.settle(created, now);
                r
            })
        })
        .collect();
    // Live runs first, then the newest: a view the human has not sorted.
    let live = |r: &Run| usize::from(!matches!(r.state.as_str(), "running" | "queued"));
    rows.sort_by(|a, b| {
        (live(a), std::cmp::Reverse(a.started), a.id).cmp(&(
            live(b),
            std::cmp::Reverse(b.started),
            b.id,
        ))
    });
    (rows, bad)
}

/// `generated_at` of `sync.json` as unix seconds, and one line per distinct error the last pass
/// hit: `<repo>: <error>` for one repo, `<error> (<n> repos: <names>)` when several share it, so
/// a rate limit that stops every repo reads once rather than once per repo.
fn synced(text: &str) -> Result<(i64, Vec<String>), String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("sync.json: {e}"))?;
    let at = v["generated_at"]
        .as_str()
        .and_then(crate::fleet::ts)
        .unwrap_or(0);
    let mut by_error: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (k, r) in v["repos"].as_object().into_iter().flatten() {
        if let Some(e) = r["error"].as_str() {
            by_error.entry(e).or_default().push(k);
        }
    }
    let mut errors: Vec<String> = by_error
        .into_iter()
        .map(|(e, repos)| match repos[..] {
            [one] => format!("{one}: {e}"),
            _ => {
                let names: Vec<&str> = repos
                    .iter()
                    .map(|k| k.split_once(':').map_or(*k, |(_, r)| r))
                    .collect();
                format!("{e} ({} repos: {})", repos.len(), names.join(", "))
            }
        })
        .collect();
    errors.sort();
    Ok((at, errors))
}

fn read_text(p: &Path) -> Result<String, String> {
    std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))
}

/// What a read joins its runs to beyond its own files: the queue's items (a run's PR -> item ->
/// session) and the runner `release-state show` is asked through (run -> release).
pub struct Join<'a> {
    pub runner: &'a dyn crate::session_actions::Runner,
    pub items: &'a [crate::queue::Item],
}

/// The section: every run in the window, or what stopped the read. The rows that did read are
/// kept beside the errors, and nothing is carried over from an earlier read. With no `join` a
/// run's owner is the live session on its branch only, and it has no release.
pub fn read(paths: &Paths, join: Option<Join>, now: i64) -> Builds {
    let mut out = Builds::default();
    match read_text(&paths.ledger) {
        Ok(text) => {
            let (rows, bad) = parse(&text, now);
            if bad > 0 {
                out.errors
                    .push(format!("runs.jsonl: {bad} unreadable line(s) skipped"));
            }
            out.rows = rows;
        }
        Err(e) => out.errors.push(format!("{e} (schedules-sync writes it)")),
    }
    match read_text(&paths.sync).and_then(|t| synced(&t)) {
        Ok((at, errors)) => {
            out.at = at;
            out.errors.extend(errors);
        }
        Err(e) => out.errors.push(e),
    }
    // The fleet's state is the owner column's first source; without it the section says so
    // rather than claiming no run has an owner.
    let live = match read_text(&paths.fleet).and_then(|t| {
        serde_json::from_str::<Value>(&t).map_err(|e| format!("{}: {e}", paths.fleet.display()))
    }) {
        Ok(state) => crate::release_graph::live(&state),
        Err(e) => {
            out.errors.push(format!("owner session: {e}"));
            HashMap::new()
        }
    };
    let (prs, errors) = crate::release_graph::read_prs(&paths.prs);
    out.errors.extend(errors);
    let (channels, lines) = match &join {
        Some(j) => match crate::releases::snapshot(j.runner) {
            Ok(s) => (s.rows, s.releases),
            // No snapshot yet is a host release-state never refreshed on: no run has a release.
            Err(e) if e.contains("no snapshot yet") => (vec![], HashMap::new()),
            Err(e) => {
                out.errors.push(format!("run release: {e}"));
                (vec![], HashMap::new())
            }
        },
        None => (vec![], HashMap::new()),
    };
    let registry = project_map::cached();
    crate::release_graph::Graph::new(crate::release_graph::Inputs {
        lines: &lines,
        channels: &channels,
        items: join.as_ref().map_or(&[], |j| j.items),
        prs: &prs,
        live: &live,
        registry: registry.as_deref(),
    })
    .join(&mut out.rows);
    // The quarantine is absent until a repo has one: no file is no fold, not an error.
    if let Ok(text) = read_text(&paths.quarantine) {
        match quarantine::parse(&text) {
            Ok(lanes) => out.quarantine = lanes,
            Err(e) => out.errors.push(e),
        }
    }
    out.times = time(&mut out.rows);
    out.counts = Counts::of(&out.rows, now);
    out.released = Counts::of(out.rows_in(Scope::Release), now);
    out
}

/// The name a run is timed under: Dependabot's per-update names fold to one per ecosystem, and a
/// run id or sha in a name drops with the `of` before it (`Tests (delta of 42614501160)` is
/// `Tests (delta)`), so one workflow's runs pool.
pub fn timed_as(workflow: &str, path: &str) -> String {
    if path.starts_with("dynamic/dependabot/") {
        let eco = workflow.split_whitespace().next().unwrap_or_default();
        return format!("Dependabot ({eco})");
    }
    let mut out: Vec<String> = Vec::new();
    for word in workflow.split_whitespace() {
        let core = word.trim_matches(|c: char| !c.is_ascii_alphanumeric());
        let id = core.len() >= 7
            && core.chars().all(|c| c.is_ascii_hexdigit())
            && core.chars().any(|c| c.is_ascii_digit());
        if !id {
            out.push(word.to_string());
            continue;
        }
        if out.last().is_some_and(|w| w == "of") {
            out.pop();
        }
        let tail = &word[word
            .trim_end_matches(|c: char| !c.is_ascii_alphanumeric())
            .len()..];
        match out.last_mut() {
            Some(w) => w.push_str(tail),
            None if !tail.is_empty() => out.push(tail.to_string()),
            None => {}
        }
    }
    out.join(" ")
}

/// The one CI pass rate's verdict on a run: `Some(true)` it succeeded, `Some(false)` it failed
/// (failure, timeout, startup failure), `None` it is left out: still running, or cancelled,
/// skipped, neutral, stale or waiting on approval, which stopped before saying pass or fail.
/// Each attempt is a run, so a red re-run to green is one red and one green. Builds' Run times
/// and `hub ci pass` (day-log's CI numbers) count with this and nothing else.
pub fn verdict(conclusion: Option<&str>) -> Option<bool> {
    match conclusion? {
        "success" => Some(true),
        "failure" | "timed_out" | "startup_failure" => Some(false),
        _ => None,
    }
}

/// Runs counted by `verdict` and how many of them succeeded; `pass` is their share, 0..1 to four
/// places, none when no run counted.
#[derive(Serialize, Default, Debug, Clone, PartialEq)]
pub struct Pass {
    pub runs: usize,
    pub green: usize,
    pub pass: Option<f64>,
}

impl Pass {
    fn add(&mut self, conclusion: Option<&str>) {
        if let Some(green) = verdict(conclusion) {
            self.runs += 1;
            self.green += usize::from(green);
            self.pass = Some((self.green as f64 / self.runs as f64 * 1e4).round() / 1e4);
        }
    }

    /// The share as a whole percent, 0 when no run counted.
    pub fn percent(&self) -> u32 {
        (self.green * 100).checked_div(self.runs).unwrap_or_default() as u32
    }
}

/// One repo's pass rate over a window, whole and per workflow (`timed_as`).
#[derive(Serialize, Default, Debug, Clone, PartialEq)]
pub struct RepoPass {
    #[serde(flatten)]
    pub all: Pass,
    pub workflows: BTreeMap<String, Pass>,
}

/// The pass rate of every repo's runs created in `[since, until)`, keyed `<forge>:<repo>`, on
/// `branch` alone when one is given: what `hub ci pass` prints.
pub fn pass_by_repo(
    rows: &[Run],
    since: i64,
    until: i64,
    branch: Option<&str>,
) -> BTreeMap<String, RepoPass> {
    let mut out: BTreeMap<String, RepoPass> = BTreeMap::new();
    for r in rows {
        let created = crate::fleet::ts(&r.created_at).unwrap_or(i64::MIN);
        if created < since || created >= until || branch.is_some_and(|b| r.branch != b) {
            continue;
        }
        let repo = out.entry(format!("{}:{}", r.forge, r.repo)).or_default();
        repo.all.add(r.conclusion.as_deref());
        repo.workflows
            .entry(timed_as(&r.workflow, &r.path))
            .or_default()
            .add(r.conclusion.as_deref());
    }
    out
}

/// The value at quantile `q` of sorted `v`, nearest rank.
fn rank(v: &[i64], q: f64) -> i64 {
    v[((q * v.len() as f64).ceil() as usize).clamp(1, v.len()) - 1]
}

/// Each workflow's run times and pass rate (`verdict`) from `rows`, and each row's usual time
/// and, running, its ETA. Only a run `verdict` counts is timed: a cancelled or skipped run
/// stopped early and would pull the median down. A running run past its workflow's p90 turns amber.
pub fn time(rows: &mut [Run]) -> Vec<RunTime> {
    type Key = (String, String, String);
    let key = |r: &Run| {
        (
            r.forge.clone(),
            r.repo.clone(),
            timed_as(&r.workflow, &r.path),
        )
    };
    let mut by: HashMap<Key, (Vec<i64>, Pass, usize)> = HashMap::new();
    for r in rows.iter() {
        let (took, pass, running) = by.entry(key(r)).or_default();
        *running += usize::from(r.state == "running");
        if !r.done() {
            continue;
        }
        pass.add(r.conclusion.as_deref());
        // A startup failure never ran its jobs, so its seconds would drag the usual time down.
        let ran = matches!(r.conclusion.as_deref(), Some("success" | "failure" | "timed_out"));
        let timed = ran && r.started_at.is_some();
        if let (true, Some(t)) = (timed, r.took) {
            took.push(t);
        }
    }
    let mut out: Vec<RunTime> = by
        .into_iter()
        .filter(|(_, (took, _, running))| !took.is_empty() || *running > 0)
        .map(|((forge, repo, workflow), (mut took, pass, running))| {
            took.sort_unstable();
            let usual = (took.len() >= USUAL_MIN).then(|| Usual {
                median: rank(&took, 0.5),
                p90: rank(&took, 0.9),
            });
            RunTime {
                forge,
                repo,
                workflow,
                runs: took.len(),
                usual,
                longest: took.last().copied().unwrap_or_default(),
                pass: pass.percent(),
                running,
            }
        })
        .collect();
    // Total, so the table never reshuffles between reads: the full repo and forge break a tie.
    out.sort_by_cached_key(|t| {
        (
            t.project(),
            std::cmp::Reverse(t.runs),
            t.workflow.clone(),
            t.repo.clone(),
            t.forge.clone(),
        )
    });
    let usual: HashMap<Key, Usual> = out
        .iter()
        .filter_map(|t| {
            Some((
                (t.forge.clone(), t.repo.clone(), t.workflow.clone()),
                t.usual?,
            ))
        })
        .collect();
    for r in rows.iter_mut() {
        r.usual = usual.get(&key(r)).copied();
        if r.state != "running" {
            continue;
        }
        if let Some(u) = r.usual {
            r.eta = Some(r.started + u.median);
            if r.took.is_some_and(|t| t > u.p90) {
                r.level = Level::Warn;
            }
        }
    }
    out
}

/// The cap on the rows a surface draws at once; the rest are one search or chip away.
pub const LIST_ROWS: usize = 100;

/// The first `LIST_ROWS` of `rows`, and how many were left out.
pub fn cap(rows: Vec<&Run>) -> (Vec<&Run>, usize) {
    let more = rows.len().saturating_sub(LIST_ROWS);
    (rows.into_iter().take(LIST_ROWS).collect(), more)
}

/// The run `key` names, from the ledger, and whether a later attempt of the same run exists.
pub fn find(paths: &Paths, key: &RunKey, now: i64) -> Result<(Run, bool), String> {
    let (rows, _) = parse(&read_text(&paths.ledger)?, now);
    let run = rows
        .iter()
        .find(|r| r.key() == *key)
        .ok_or("that run is not in the ledger (older than 30 days, or never synced)")?;
    let later = rows.iter().any(|r| {
        (r.forge.as_str(), r.repo.as_str(), r.id) == (run.forge.as_str(), run.repo.as_str(), run.id)
            && r.attempt > run.attempt
    });
    Ok((run.clone(), later))
}

/// The tail of a run's log, fetched on open. A finished GitHub run goes through `jobs::read_log`
/// (the failed steps, else the whole log, cached once because the API budget is shared); a live
/// one says so; Forgejo serves no log to a caller without a session, so its row points at the run.
pub fn log(
    paths: &Paths,
    jobs_paths: &jobs::Paths,
    key: &RunKey,
    now: i64,
) -> Result<String, String> {
    let (run, superseded) = find(paths, key, now)?;
    // `gh run view` and the log cache know the run, not its attempt: they would serve the latest
    // attempt's log under this one's row.
    if superseded {
        return Ok(format!(
            "Attempt {} was re-run; the hub reads only the latest attempt's log. Open {}/attempts/{}\n",
            run.attempt, run.url, run.attempt
        ));
    }
    match run.forge.as_str() {
        "github" => jobs::read_log(
            jobs_paths,
            &LogRef::Gh {
                url: run.url.clone(),
                done: run.done(),
            },
        ),
        _ => Ok(format!(
            "Forgejo does not serve this run's log to the hub. Open {}\n",
            run.url
        )),
    }
}

/// The run `key` names, opened: its jobs, steps and cost from the job archive, priced with
/// `rates`. Only the ledger and the archive are read, so an open never asks a provider.
pub fn detail(paths: &Paths, rates: &Rates, key: &RunKey, now: i64) -> Result<RunDetail, String> {
    let (rows, _) = parse(&read_text(&paths.ledger)?, now);
    let run = rows
        .iter()
        .find(|r| r.key() == *key)
        .ok_or("that run is not in the ledger (older than 30 days, or never synced)")?;
    let mut attempts: Vec<u32> = rows
        .iter()
        .filter(|r| (&r.forge, &r.repo, r.id) == (&run.forge, &run.repo, run.id))
        .map(|r| r.attempt)
        .collect();
    attempts.sort_unstable();
    // A missing archive is no record: the run reads pending or unavailable.
    let text = std::fs::read_to_string(&paths.jobs).unwrap_or_default();
    let id = key.id.to_string();
    let (records, _) = run_detail::archive(&text, |l| l.contains(&id));
    Ok(run_detail::build(
        run,
        records.get(key),
        attempts,
        rates,
        now,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_794_000_000;

    fn iso(t: i64) -> String {
        chrono::DateTime::from_timestamp(t, 0)
            .unwrap()
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string()
    }

    fn line(id: u64, status: &str, conclusion: Option<&str>, age: i64, branch: &str) -> String {
        let created = iso(NOW - age);
        let ended = conclusion.map(|_| iso(NOW - age + 90));
        serde_json::json!({
            "forge": "github", "repo": "Org/app", "id": id, "attempt": 1,
            "workflow": "Tests", "title": "t", "branch": branch, "event": "pull_request",
            "sha": "abc", "status": status, "conclusion": conclusion,
            "created_at": created, "started_at": created, "ended_at": ended,
            "prs": [7], "url": format!("https://github.com/Org/app/actions/runs/{id}"),
        })
        .to_string()
    }

    #[test]
    fn a_run_is_its_last_line_and_a_run_past_the_window_is_dropped() {
        let text = [
            line(1, "in_progress", None, 600, "feat/a"),
            line(1, "completed", Some("failure"), 600, "feat/a"),
            line(2, "completed", Some("success"), 300, "feat/b"),
            line(3, "completed", Some("success"), 31 * 86400, "feat/old"),
            "not json".to_string(),
        ]
        .join("\n");
        let (rows, bad) = parse(&text, NOW);
        assert_eq!(bad, 1);
        assert_eq!(rows.len(), 2);
        let one = rows.iter().find(|r| r.id == 1).unwrap();
        assert_eq!((one.state.as_str(), one.took), ("red", Some(90)));
        assert_eq!(one.level, Level::Bad);
    }

    #[test]
    fn live_runs_come_first_then_the_newest() {
        let text = [
            line(1, "completed", Some("success"), 100, "a"),
            line(2, "completed", Some("failure"), 50, "b"),
            line(3, "queued", None, 900, "c"),
            line(4, "in_progress", None, 800, "d"),
        ]
        .join("\n");
        let (rows, _) = parse(&text, NOW);
        let ids: Vec<u64> = rows.iter().map(|r| r.id).collect();
        assert_eq!(ids, [4, 3, 2, 1]);
        assert_eq!(rows[0].took, Some(800), "a running run's time so far");
        assert_eq!(rows[1].took, Some(900), "a queued run's wait");
    }

    #[test]
    fn counts_say_what_they_counted() {
        let text = [
            line(1, "in_progress", None, 10, "a"),
            line(2, "completed", Some("failure"), 20, "b"),
            line(3, "completed", Some("cancelled"), 30, "c"),
        ]
        .join("\n");
        let (rows, _) = parse(&text, NOW);
        let c = Counts::of(&rows, NOW);
        assert_eq!(c.says(), "3 runs in 30 days: 1 running, 0 queued, 1 red");
        let red = rows.iter().find(|r| r.id == 2).unwrap().started;
        assert_eq!(c.level(), Level::Bad, "a red run begun within the day");
        let later = Counts::of(&rows, red + RECENT_SECS + 1);
        assert_eq!(
            (later.red, later.level()),
            (1, Level::Ok),
            "an old red is history"
        );
        // A recent red or an unread ledger puts a count on Infra's CI inner tab; an old red does
        // not.
        let builds = |counts| Builds {
            counts,
            ..Default::default()
        };
        assert!(builds(c).needs_look() && !builds(later).needs_look());
        let unread = Builds {
            errors: vec!["runs.jsonl: unreadable".into()],
            ..Default::default()
        };
        assert!(unread.needs_look());
        assert_eq!(rows.iter().find(|r| r.id == 3).unwrap().state, "other");
    }

    #[test]
    fn a_branch_with_a_session_has_an_owner_and_a_hand_pushed_one_shows_nothing() {
        let state = serde_json::json!({"sessions": [
            {"target": "lab/dotfiles-agent-32:1", "branch": "feat/a"},
            {"target": "lab/dotfiles-agent-33:1", "branch": "feat/a"},
            {"target": "hub/dotfiles:2", "branch": "main"},
            {"target": "lab/x:1", "branch": ""},
        ]});
        let o = crate::release_graph::live(&state);
        assert_eq!(o["feat/a"], "dotfiles-agent-32, dotfiles-agent-33");
        assert_eq!(o.len(), 1, "main and an empty branch are nobody's");
        let (rows, _) = parse(&line(1, "queued", None, 5, "by-hand"), NOW);
        assert_eq!(rows[0].val("owner"), Val::None);
    }

    #[test]
    fn the_sync_record_names_each_repo_it_could_not_read() {
        let (at, errors) = synced(
            r#"{"generated_at":"2026-11-08T14:16:22Z","repos":{
                "github:a/b":{"error":null},"github:c/d":{"error":"403 rate limited"}}}"#,
        )
        .unwrap();
        assert!(at > 0);
        assert_eq!(errors, ["github:c/d: 403 rate limited"]);
        assert!(synced("nope").is_err());
    }

    #[test]
    fn repos_that_share_an_error_read_as_one_line() {
        let (_, errors) = synced(
            r#"{"generated_at":"2026-11-08T14:16:22Z","repos":{
                "github:o/a":{"error":"GitHub API rate limit hit"},
                "github:p/b":{"error":"GitHub API rate limit hit"},
                "github:o/c":{"error":"HTTP 502"}}}"#,
        )
        .unwrap();
        assert_eq!(
            errors,
            [
                "GitHub API rate limit hit (2 repos: o/a, p/b)",
                "github:o/c: HTTP 502"
            ]
        );
    }

    /// An empty PR store beside the ledger.
    fn store(d: &Path) -> PathBuf {
        let p = d.join("prs");
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn a_missing_ledger_is_an_error_and_the_rest_still_reads() {
        let d = std::env::temp_dir().join(format!("hub-builds-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("sync.json"),
            r#"{"generated_at":"2026-11-08T14:16:22Z","repos":{}}"#,
        )
        .unwrap();
        let p = Paths {
            ledger: d.join("runs.jsonl"),
            sync: d.join("sync.json"),
            fleet: d.join("state.json"),
            prs: store(&d),
            jobs: d.join("jobs.jsonl"),
            quarantine: d.join("quarantine.json"),
        };
        let b = read(&p, None, NOW);
        std::fs::remove_dir_all(&d).unwrap();
        assert!(b.rows.is_empty());
        assert!(b.errors[0].contains("runs.jsonl"), "{:?}", b.errors);
        assert!(b.errors.iter().any(|e| e.starts_with("owner session")));
        assert!(b.at > 0);
    }

    #[test]
    fn a_log_is_looked_up_by_key_and_a_forgejo_run_points_at_itself() {
        let d = std::env::temp_dir().join(format!("hub-builds-log-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let fj = line(5, "completed", Some("failure"), 60, "x")
            .replace("\"github\"", "\"forgejo\"")
            .replace("https://github.com", "https://git.example");
        std::fs::write(d.join("runs.jsonl"), fj).unwrap();
        let p = Paths {
            ledger: d.join("runs.jsonl"),
            sync: d.join("sync.json"),
            fleet: d.join("state.json"),
            prs: store(&d),
            jobs: d.join("jobs.jsonl"),
            quarantine: d.join("quarantine.json"),
        };
        let key = |id| RunKey {
            forge: "forgejo".into(),
            repo: "Org/app".into(),
            id,
            attempt: 1,
        };
        let got = log(&p, &jobs::Paths::from_env(), &key(5), NOW);
        let missing = log(&p, &jobs::Paths::from_env(), &key(6), NOW);
        std::fs::remove_dir_all(&d).unwrap();
        assert!(got
            .unwrap()
            .contains("https://git.example/Org/app/actions/runs/5"));
        assert!(missing.unwrap_err().contains("not in the ledger"));
    }

    #[test]
    fn a_re_run_attempt_does_not_show_the_latest_attempts_log() {
        let d = std::env::temp_dir().join(format!("hub-builds-attempt-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let first = line(7, "completed", Some("failure"), 600, "x");
        let second = first.replace("\"attempt\":1", "\"attempt\":2");
        std::fs::write(d.join("runs.jsonl"), format!("{first}\n{second}\n")).unwrap();
        let p = Paths {
            ledger: d.join("runs.jsonl"),
            sync: d.join("sync.json"),
            fleet: d.join("state.json"),
            prs: store(&d),
            jobs: d.join("jobs.jsonl"),
            quarantine: d.join("quarantine.json"),
        };
        let key = RunKey {
            forge: "github".into(),
            repo: "Org/app".into(),
            id: 7,
            attempt: 1,
        };
        let got = log(&p, &jobs::Paths::from_env(), &key, NOW);
        std::fs::remove_dir_all(&d).unwrap();
        let got = got.unwrap();
        assert!(
            got.contains("Attempt 1 was re-run") && got.contains("/attempts/1"),
            "{got}"
        );
    }

    #[test]
    fn the_quarantine_rides_the_read_silent_when_absent_and_red_when_unreadable() {
        let (d, p) = opened("quar", &[], "");
        assert!(
            p.is_ledger_file(&p.quarantine),
            "a new quarantine wakes the section"
        );
        let none = read(&p, None, NOW);
        assert!(none.quarantine.is_empty());
        assert!(
            !none.errors.iter().any(|e| e.contains("quarantine")),
            "{:?}",
            none.errors
        );
        std::fs::write(
            &p.quarantine,
            r#"{"repos":[{"repo":"Org/app","base":"main","report":{"entries":3,"rows":[]}}]}"#,
        )
        .unwrap();
        let some = read(&p, None, NOW);
        std::fs::write(&p.quarantine, "{").unwrap();
        let bad = read(&p, None, NOW);
        std::fs::remove_dir_all(&d).unwrap();
        assert_eq!(some.quarantine[0].repo, "Org/app");
        assert_eq!(some.quarantine[0].report.as_ref().unwrap().entries, 3);
        assert!(bad.quarantine.is_empty());
        assert!(
            bad.errors.iter().any(|e| e.starts_with("quarantine.json:")),
            "{:?}",
            bad.errors
        );
    }

    /// A run ledger and job archive in a fresh directory, and the paths that read them.
    fn opened(name: &str, runs: &[String], jobs: &str) -> (PathBuf, Paths) {
        let d = std::env::temp_dir().join(format!("hub-builds-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("runs.jsonl"), runs.join("\n")).unwrap();
        std::fs::write(d.join("jobs.jsonl"), jobs).unwrap();
        let p = Paths {
            ledger: d.join("runs.jsonl"),
            sync: d.join("sync.json"),
            fleet: d.join("state.json"),
            prs: store(&d),
            jobs: d.join("jobs.jsonl"),
            quarantine: d.join("quarantine.json"),
        };
        (d, p)
    }

    fn job(name: &str, runner: &str, start: i64, secs: i64) -> serde_json::Value {
        serde_json::json!({
            "id": start, "name": name, "conclusion": "success", "runner_name": runner,
            "labels": ["self-hosted", "unity"], "created_at": iso(start - 60),
            "started_at": iso(start), "completed_at": iso(start + secs), "url": "https://x/job",
            "steps": [{"number": 1, "name": "checkout", "conclusion": "success",
                       "started_at": iso(start), "completed_at": iso(start + 2)}],
        })
    }

    fn record(id: u64, complete: bool, jobs: Vec<serde_json::Value>) -> String {
        serde_json::json!({
            "forge": "github", "repo": "Org/app", "run_id": id, "attempt": 1,
            "source": "exporter", "complete": complete, "fetched_at": iso(NOW - 60), "jobs": jobs,
        })
        .to_string()
    }

    fn key(id: u64) -> RunKey {
        RunKey {
            forge: "github".into(),
            repo: "Org/app".into(),
            id,
            attempt: 1,
        }
    }

    #[test]
    fn an_opened_run_reads_its_jobs_and_prices_them_from_local_files_only() {
        let start = NOW - 3000;
        let jobs = vec![
            job("shard 2", "aws-burst-1-unity-pool-3", start, 32 * 60 + 45),
            job("report", "hp-victus-light-1", start + 10, 12),
            job("plan", "razer-laptop-light-2", start, 84),
        ];
        let (d, p) = opened(
            "detail",
            &[line(9, "completed", Some("failure"), 3060, "b")],
            &record(9, true, jobs),
        );
        // Only the paths and the rates go in: no Prometheus base, no GitHub token, no fetch.
        let got = detail(&p, &run_detail::tests::rates(), &key(9), NOW);
        let missing = detail(&p, &run_detail::tests::rates(), &key(10), NOW);
        std::fs::remove_dir_all(&d).unwrap();
        let got = got.unwrap();
        assert!(missing.unwrap_err().contains("not in the ledger"));
        assert_eq!(got.coverage, "complete");
        assert_eq!(got.jobs.len(), 3);
        let shard = &got.jobs[0];
        assert_eq!(
            (shard.class.as_str(), shard.took_text.as_str()),
            ("aws/on-demand", "32m45")
        );
        assert_eq!(shard.price.text, "0.20 (1/5 of $1.855/h)");
        assert_eq!(
            got.jobs[1].price.text, "no rate",
            "hp-victus has slots and no rate"
        );
        assert_eq!(got.jobs[2].class, "light/owned");
        assert_eq!(got.jobs[2].price.text, "0.00 owned");
        assert_eq!(got.cost.text, "$0.20 + no rate");
        assert_eq!(shard.steps_text, "checkout 2s");
        assert!(
            got.header
                .starts_with("end to end 33m45 | before first job 1m |"),
            "{}",
            got.header
        );
        assert!(
            got.header.ends_with("| tested abc | complete"),
            "{}",
            got.header
        );
        assert!(got.title.contains("$0.20 + no rate"), "{}", got.title);
        assert_eq!(got.attempts, [1]);
    }

    #[test]
    fn an_interrupted_fetch_reads_partial_and_a_run_without_a_record_pending_then_unavailable() {
        let runs = [
            line(1, "completed", Some("success"), 600, "b"),
            line(2, "completed", Some("success"), 600, "b"),
            line(3, "completed", Some("success"), 7200, "b"),
        ];
        let (d, p) = opened(
            "cover",
            &runs,
            &record(1, false, vec![job("a", "x-1", NOW - 600, 60)]),
        );
        let r = run_detail::tests::rates();
        let got: Vec<String> = [1, 2, 3]
            .map(|id| detail(&p, &r, &key(id), NOW).unwrap().coverage)
            .into();
        std::fs::remove_dir_all(&d).unwrap();
        // Run 2 ended 90s after it began 600s ago: the next import can still bring it.
        assert_eq!(got, ["partial", "pending", "unavailable"]);
    }

    #[test]
    fn a_run_of_130_jobs_reads_every_one() {
        let jobs: Vec<serde_json::Value> = (0..130)
            .map(|i| {
                job(
                    &format!("shard {i}"),
                    "razer-laptop-unity-pool-1",
                    NOW - 3000 + i,
                    60,
                )
            })
            .collect();
        let (d, p) = opened(
            "many",
            &[line(4, "completed", Some("success"), 3060, "b")],
            &record(4, true, jobs),
        );
        let got = detail(&p, &run_detail::tests::rates(), &key(4), NOW);
        std::fs::remove_dir_all(&d).unwrap();
        let got = got.unwrap();
        assert_eq!(got.jobs.len(), 130);
        assert_eq!(got.jobs[129].name, "shard 129");
        assert_eq!(got.cost.text, "$0.00 owned");
    }

    #[test]
    fn release_runs_are_the_runs_the_graph_tied_to_a_release() {
        let runs: Vec<String> = (1..=3).map(|i| timed(i, "Tests", "success", 60)).collect();
        let (d, p) = opened("rel", &runs, "");
        let mut b = read(&p, None, NOW);
        std::fs::remove_dir_all(&d).unwrap();
        b.rows[1].release = Some(crate::release_graph::RunRelease {
            project: "app".into(),
            tag: "v1.2.0".into(),
        });
        b.quarantine = vec![Default::default()];
        b.released = Counts::of(b.rows_in(Scope::Release), NOW);
        let r = b.scoped(Scope::Release);
        assert_eq!(r.rows.len(), 1);
        assert_eq!(r.counts.total, 1);
        assert!(r.times.is_empty() && r.quarantine.is_empty());
        let all = b.scoped(Scope::All);
        assert_eq!((all.rows.len(), all.counts.total), (3, 3));
        assert!(!all.times.is_empty() && all.quarantine.len() == 1);
        assert_eq!(r.rows[0].val("release"), Val::Text("v1.2.0".into()));
        assert!(r.rows[0].text().contains("v1.2.0"));
        assert_eq!(b.rows[0].val("release"), Val::None);
    }

    /// A finished run of `workflow` that took `secs`, begun an hour before `NOW`.
    fn timed(id: u64, workflow: &str, conclusion: &str, secs: i64) -> String {
        let start = NOW - 3600 - id as i64;
        serde_json::json!({
            "forge": "github", "repo": "Org/app", "id": id, "attempt": 1,
            "workflow": workflow, "path": ".github/workflows/test.yml", "branch": "b",
            "status": "completed", "conclusion": conclusion, "created_at": iso(start),
            "started_at": iso(start), "ended_at": iso(start + secs),
        })
        .to_string()
    }

    fn running(id: u64, workflow: &str, age: i64) -> String {
        serde_json::json!({
            "forge": "github", "repo": "Org/app", "id": id, "attempt": 1,
            "workflow": workflow, "path": ".github/workflows/test.yml", "branch": "b",
            "status": "in_progress", "created_at": iso(NOW - age), "started_at": iso(NOW - age),
        })
        .to_string()
    }

    fn timed_rows(lines: &[String]) -> (Vec<Run>, Vec<RunTime>) {
        let (mut rows, bad) = parse(&lines.join("\n"), NOW);
        assert_eq!(bad, 0);
        let times = time(&mut rows);
        (rows, times)
    }

    #[test]
    fn a_workflow_is_timed_by_median_and_p90_of_its_finished_runs_only() {
        let mut lines: Vec<String> = (1..=10)
            .map(|i| {
                timed(
                    i,
                    "Tests (affected)",
                    if i <= 7 { "success" } else { "failure" },
                    i as i64 * 60,
                )
            })
            .collect();
        // Cancelled and skipped runs stop early: counted, they would pull the median to a minute.
        for i in 11..=20 {
            lines.push(timed(i, "Tests (affected)", "cancelled", 5));
        }
        lines.push(timed(21, "Tests (affected)", "skipped", 1));
        let (_, times) = timed_rows(&lines);
        assert_eq!(times.len(), 1);
        let t = &times[0];
        assert_eq!(t.runs, 10, "cancelled and skipped are left out");
        assert_eq!(
            t.usual,
            Some(Usual {
                median: 300,
                p90: 540
            })
        );
        assert_eq!((t.longest, t.pass), (600, 70));
    }

    #[test]
    fn the_pass_rate_counts_each_finished_attempt_and_leaves_out_runs_that_said_neither() {
        let mut lines: Vec<String> = [
            (1, "success"),
            (2, "failure"),
            (3, "timed_out"),
            (4, "startup_failure"),
            (5, "cancelled"),
            (6, "skipped"),
            (7, "neutral"),
            (8, "action_required"),
        ]
        .iter()
        .map(|(i, c)| timed(*i, "Tests", c, 60))
        .collect();
        lines.push(running(9, "Tests", 60));
        // A red re-run to green: two runs, one of each.
        let rerun = |attempt: u32, c: &str| {
            let mut v: Value = serde_json::from_str(&timed(10, "Tests", c, 60)).unwrap();
            v["attempt"] = attempt.into();
            v.to_string()
        };
        lines.push(rerun(1, "failure"));
        lines.push(rerun(2, "success"));
        // Another branch, and a run before the window.
        let mut other: Value = serde_json::from_str(&timed(11, "Lint", "success", 60)).unwrap();
        other["branch"] = "main".into();
        lines.push(other.to_string());
        let mut old: Value = serde_json::from_str(&timed(12, "Tests", "failure", 60)).unwrap();
        old["created_at"] = iso(NOW - 3 * 86400).into();
        lines.push(old.to_string());
        let (rows, times) = timed_rows(&lines);
        let all = pass_by_repo(&rows, NOW - 86400, NOW, None);
        let app = &all["github:Org/app"];
        assert_eq!(
            (app.all.runs, app.all.green, app.all.pass),
            (7, 3, Some(0.4286))
        );
        assert_eq!(
            (app.workflows["Tests"].runs, app.workflows["Tests"].green),
            (6, 2)
        );
        let main = pass_by_repo(&rows, NOW - 86400, NOW, Some("main"));
        assert_eq!(
            main["github:Org/app"].all,
            Pass {
                runs: 1,
                green: 1,
                pass: Some(1.0)
            }
        );
        // Run times read the same verdict: 2 of 7 finished Tests runs in the 30 days, 28%.
        let tests = times.iter().find(|t| t.workflow == "Tests").unwrap();
        assert_eq!(tests.pass, 28);
        // The startup failure counts as red but is not timed: 6 of the 7 have a time.
        assert_eq!(tests.runs, 6);
        assert_eq!(verdict(None), None);
    }

    #[test]
    fn a_run_id_in_the_name_and_dependabots_updates_pool_under_one_name() {
        assert_eq!(
            timed_as("Tests (delta of 42614501160)", "x"),
            "Tests (delta)"
        );
        assert_eq!(timed_as("Tests (delta of 3f2a9c1d)", "x"), "Tests (delta)");
        assert_eq!(timed_as("Multi (named)", "x"), "Multi (named)");
        assert_eq!(timed_as("Release builds", "x"), "Release builds");
        assert_eq!(
            timed_as(
                "github_actions in / for actions/checkout - Update #1687367140",
                "dynamic/dependabot/dependabot-updates"
            ),
            "Dependabot (github_actions)"
        );
        let lines = [
            timed(1, "Tests (delta of 42614501160)", "success", 60),
            timed(2, "Tests (delta of 42718497697)", "success", 120),
            timed(3, "Tests (delta of 42862038016)", "failure", 180),
        ];
        let (_, times) = timed_rows(&lines);
        assert_eq!(times.len(), 1);
        assert_eq!(
            (times[0].workflow.as_str(), times[0].runs),
            ("Tests (delta)", 3)
        );
    }

    #[test]
    fn a_running_run_gets_an_eta_and_turns_amber_past_its_p90() {
        let mut lines: Vec<String> = (1..=10)
            .map(|i| timed(i, "Tests", "success", i as i64 * 60))
            .collect();
        lines.push(running(30, "Tests", 120));
        lines.push(running(31, "Tests", 900));
        let (rows, _) = timed_rows(&lines);
        let on_time = rows.iter().find(|r| r.id == 30).unwrap();
        assert_eq!(on_time.eta, Some(NOW - 120 + 300));
        assert_eq!(on_time.level, Level::Ok);
        let late = rows.iter().find(|r| r.id == 31).unwrap();
        assert_eq!(late.level, Level::Warn, "900s is past the 540s p90");
        let done = rows.iter().find(|r| r.id == 1).unwrap();
        assert_eq!((done.usual.map(|u| u.median), done.eta), (Some(300), None));
    }

    #[test]
    fn below_three_finished_runs_there_is_no_usual_and_no_eta() {
        let lines = [
            timed(1, "Soak", "success", 600),
            timed(2, "Soak", "success", 700),
            running(3, "Soak", 60),
        ];
        let (rows, times) = timed_rows(&lines);
        assert_eq!(
            (times[0].runs, times[0].usual, times[0].running),
            (2, None, 1)
        );
        assert!(rows.iter().all(|r| r.usual.is_none() && r.eta.is_none()));
        let (_, only) = timed_rows(&[running(4, "Brand new", 60)]);
        assert_eq!(
            (only[0].runs, only[0].running, only[0].pass),
            (0, 1, 0),
            "a workflow only running is still listed"
        );
    }

    #[test]
    fn the_cap_says_how_many_it_left_out() {
        let rows: Vec<Run> = (0..LIST_ROWS as u64 + 3)
            .map(|id| Run {
                id,
                ..Default::default()
            })
            .collect();
        let (shown, more) = cap(rows.iter().collect());
        assert_eq!((shown.len(), more), (LIST_ROWS, 3));
    }
}
