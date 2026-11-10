//! The Releases tab's Builds section, both surfaces: every CI run of the last 30 days on GitHub
//! and Forgejo, from `schedules-sync`'s run ledger (`~/.local/state/ci/runs.jsonl`), each with
//! the session that owns its branch. The ledger is append-only (a run is written again each time
//! it changes), so a run is its last line. A failed run's log is fetched only when the row is
//! opened (docs/dashboards.md rule 10), through the fetch and cache `jobs::read_log` already has.
//!
//! | fact                | home                                                           |
//! |---------------------|----------------------------------------------------------------|
//! | the runs            | `$SCHEDULES_RUNS_LEDGER`, else `<state>/ci/runs.jsonl`          |
//! | when it last synced | `sync.json` beside it: its `generated_at` and a `error` per repo |
//! | the owner session   | fleet-sessions' `state.json`: the live session on the branch    |
//! | the usual run time  | computed on read from the same runs (`time`), nothing stored     |

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::jobs::{self, LogRef};
use crate::releases::Level;
use crate::table::{Row, Val};

/// How long the ledger keeps a run, and so how far back this section reaches.
pub const KEEP_DAYS: i64 = 30;

/// How far back a red run still colours the count line.
pub const RECENT_SECS: i64 = 86400;
/// Branches that belong to no session: a session sitting on one is not what ran it.
const SHARED_BRANCHES: [&str; 4] = ["main", "master", "develop", "HEAD"];

/// Where the files live. Each honours the variable its writer reads.
#[derive(Clone, Debug)]
pub struct Paths {
    pub ledger: PathBuf,
    pub sync: PathBuf,
    pub fleet: PathBuf,
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
            ledger,
            fleet: crate::boards::fleet_state(),
        }
    }

    /// Whether a changed file is the ledger or its sync record: what wakes the section.
    pub fn is_ledger_file(&self, p: &Path) -> bool {
        p == self.ledger || p == self.sync
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
    pub prs: Vec<u64>,
    pub url: String,
    /// The session working on the branch (several are joined with a comma); empty for a branch
    /// no session owns, which is drawn `-`.
    #[serde(skip_deserializing)]
    pub owner: String,
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
    /// Successes among the runs counted, a whole percent.
    pub pass: u32,
    pub running: usize,
}

impl RunTime {
    pub fn short_repo(&self) -> &str {
        short_repo(&self.repo)
    }
}

/// The repo as a person names it: the part after the owner.
pub fn short_repo(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
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

    pub fn short_repo(&self) -> &str {
        short_repo(&self.repo)
    }
}

/// What names one run in a request: the ledger is looked up by it, so a caller never supplies a
/// URL or a path.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq, Eq, Hash)]
pub struct RunKey {
    pub forge: String,
    pub repo: String,
    pub id: u64,
    pub attempt: u32,
}

impl Row for Run {
    // `forge`, `event`, `title`, `sha` and `url` filter without a column on the page: the first two
    // are dropdowns, the third is the open row's heading.
    const COLUMNS: &'static [&'static str] = &[
        "started", "state", "repo", "workflow", "branch", "took", "usual", "eta", "owner", "forge",
        "event", "title",
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
            "repo" => text(self.short_repo()),
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
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        self.state == state || state == "all"
    }

    /// A bare word searches what the row says: the owner, the sha and the PR numbers too.
    fn text(&self) -> String {
        let prs: Vec<String> = self.prs.iter().map(|n| format!("#{n}")).collect();
        [
            self.repo.as_str(),
            &self.workflow,
            &self.branch,
            &self.event,
            &self.owner,
            &self.title,
            &self.sha,
            &prs.join(" "),
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
    fn of(rows: &[Run], now: i64) -> Counts {
        let n = |s: &str| rows.iter().filter(|r| r.state == s).count();
        Counts {
            total: rows.len(),
            running: n("running"),
            queued: n("queued"),
            red: n("red"),
            recent_red: rows
                .iter()
                .filter(|r| r.state == "red" && now - r.started < RECENT_SECS)
                .count(),
        }
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
    pub rows: Vec<Run>,
    /// Each workflow's run times, by repo, the most-run first.
    pub times: Vec<RunTime>,
    /// Why the ledger or a repo could not be read: a red line, never a silent blank.
    pub errors: Vec<String>,
}

impl Builds {
    /// A run went red in the last `RECENT_SECS`: the Builds inner tab's count on Releases. Older
    /// reds are history, as `Counts::level` says.
    pub fn needs_look(&self) -> bool {
        self.counts.level() == Level::Bad
    }

    pub fn summary(&self) -> String {
        self.counts.says()
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

/// The sessions on each branch, from `state.json`'s live sessions. A branch every session shares
/// (`main`) is no one's, and a branch no session sits on is absent, so a hand-pushed one shows `-`.
pub fn owners(state: &Value) -> HashMap<String, String> {
    let mut by_branch: HashMap<String, Vec<String>> = HashMap::new();
    for s in state["sessions"].as_array().into_iter().flatten() {
        let (branch, target) = (
            s["branch"].as_str().unwrap_or_default(),
            s["target"].as_str().unwrap_or_default(),
        );
        if branch.is_empty() || SHARED_BRANCHES.contains(&branch) || target.is_empty() {
            continue;
        }
        let name = crate::fleet::who::name_of(target);
        let names = by_branch.entry(branch.to_string()).or_default();
        if !names.contains(&name) {
            names.push(name);
        }
    }
    by_branch
        .into_iter()
        .map(|(b, n)| (b, n.join(", ")))
        .collect()
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

/// The section: every run in the window, or what stopped the read. The rows that did read are
/// kept beside the errors, and nothing is carried over from an earlier read.
pub fn read(paths: &Paths, now: i64) -> Builds {
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
    // The fleet's state is the owner column's only source; without it the column is `-`, and
    // the section says so rather than claiming no run has an owner.
    match read_text(&paths.fleet).and_then(|t| {
        serde_json::from_str::<Value>(&t).map_err(|e| format!("{}: {e}", paths.fleet.display()))
    }) {
        Ok(state) => {
            let owner = owners(&state);
            for r in &mut out.rows {
                r.owner = owner.get(&r.branch).cloned().unwrap_or_default();
            }
        }
        Err(e) => out.errors.push(format!("owner session: {e}")),
    }
    out.times = time(&mut out.rows);
    out.counts = Counts::of(&out.rows, now);
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

/// The value at quantile `q` of sorted `v`, nearest rank.
fn rank(v: &[i64], q: f64) -> i64 {
    v[((q * v.len() as f64).ceil() as usize).clamp(1, v.len()) - 1]
}

/// Each workflow's run times from `rows`, and each row's usual time and, running, its ETA. Only
/// a finished success, failure or timeout counts: a cancelled or skipped run stopped early and
/// would pull the median down. A running run past its workflow's p90 turns amber.
pub fn time(rows: &mut [Run]) -> Vec<RunTime> {
    type Key = (String, String, String);
    let key = |r: &Run| {
        (
            r.forge.clone(),
            r.repo.clone(),
            timed_as(&r.workflow, &r.path),
        )
    };
    let mut by: HashMap<Key, (Vec<i64>, usize, usize)> = HashMap::new();
    for r in rows.iter() {
        let (took, green, running) = by.entry(key(r)).or_default();
        *running += usize::from(r.state == "running");
        let counted = matches!(
            r.conclusion.as_deref(),
            Some("success" | "failure" | "timed_out")
        ) && r.done()
            && r.started_at.is_some();
        if let (true, Some(t)) = (counted, r.took) {
            took.push(t);
            *green += usize::from(r.state == "green");
        }
    }
    let mut out: Vec<RunTime> = by
        .into_iter()
        .filter(|(_, (took, _, running))| !took.is_empty() || *running > 0)
        .map(|((forge, repo, workflow), (mut took, green, running))| {
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
                pass: (green * 100).checked_div(took.len()).unwrap_or_default() as u32,
                running,
            }
        })
        .collect();
    // Total, so the table never reshuffles between reads: the full repo and forge break a tie.
    out.sort_by(|a, b| {
        let k = |t: &RunTime| {
            (
                short_repo(&t.repo).to_string(),
                std::cmp::Reverse(t.runs),
                t.workflow.clone(),
                t.repo.clone(),
                t.forge.clone(),
            )
        };
        k(a).cmp(&k(b))
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
        // A recent red is what puts a count on Releases' Builds inner tab; an old one does not.
        let builds = |counts| Builds {
            counts,
            ..Default::default()
        };
        assert!(builds(c).needs_look() && !builds(later).needs_look());
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
        let o = owners(&state);
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
        };
        let b = read(&p, NOW);
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
