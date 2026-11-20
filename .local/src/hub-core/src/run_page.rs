//! The run page's five sections, in order (docs/dashboards.md, "Run page"): Summary, Changes,
//! Tests, Jobs and Chain. `builds::detail` fills `RunDetail::page` when a run is opened and both
//! surfaces draw that struct; a section that cannot be read says why in its `note`, never a blank
//! or a guess.
//!
//! | section | one source                                                                               |
//! |---------|------------------------------------------------------------------------------------------|
//! | Summary | the run's ledger row and its `RunDetail` header                                           |
//! | Changes | `git log <previous run's sha>..<sha>` in the repo's clone, PRs from the PR store (`release_graph::read_prs`) |
//! | Tests   | the run's junit (`junit::load`, kept on disk), a workflow the repo declares in `testWorkflows` |
//! | Jobs    | the job archive; a run it has not reached reads `gh api .../jobs` once per open (kept `LIVE_TTL_SECS`); the stages from the workflow file's `needs:` at the run's sha |
//! | Chain   | the upstream run (`workflow_run`), the release graph's tag and the channels it reached    |
//!
//! Everything outside the process (git, gh, release-state) goes through the `Runner`, so a test
//! hands it canned answers.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use project_map::Registry;
use serde::{Deserialize, Serialize};

use crate::builds::{timed_as, Builds, Paths, Run};
use crate::junit::{self, Loaded, PickRun};
use crate::links::{Kind, Link};
use crate::run_detail::{took_text, ts, Job, Record, RunDetail};
use crate::session_actions::Runner;

/// A live job read is reused this long, so a page that repaints on every ledger line asks GitHub
/// once. Once the run is done and every job has ended, the read is kept for good. There is no
/// event for "a job moved" on this side of the API, hence a cadence.
pub const LIVE_TTL_SECS: i64 = 30;
/// `Record::source` of jobs read live, which `run_detail::build` words as coverage `live`.
pub const LIVE_SOURCE: &str = "live";
/// The commits Changes lists; the rest are counted.
pub const COMMITS_MAX: usize = 30;
/// The failed tests Tests lists; the rest are counted.
pub const FAILED_MAX: usize = 25;
/// The most of a failure's text the page keeps per test.
const MESSAGE_CHARS: usize = 240;

/// What opening a run may read besides its own row.
pub struct Env<'a> {
    pub builds: &'a Builds,
    pub paths: &'a Paths,
    /// The hub cache: junit artifacts, live jobs and finished logs live under it.
    pub cache: &'a Path,
    pub runner: &'a dyn Runner,
    pub registry: Option<&'a Registry>,
    pub now: i64,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Commit {
    pub sha: String,
    pub subject: String,
    /// The PR the PR store says merged it.
    pub pr: Option<u64>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct ChangePr {
    pub number: u64,
    pub title: String,
    pub url: String,
}

/// What changed since the previous run of the same workflow on the same branch.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Changes {
    /// Why there is nothing to list (`no clone of ...`, `first run ...`); empty when there is.
    pub note: String,
    /// `#42871 (a1b2c3d, green)`: the run the range starts at.
    pub since: String,
    pub commits: Vec<Commit>,
    /// Commits past `COMMITS_MAX`.
    pub more: usize,
    pub prs: Vec<ChangePr>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct FailedTest {
    pub tier: String,
    pub suite: String,
    pub name: String,
    pub message: String,
    /// Failed here and not in the last green run on main.
    pub new: bool,
    pub quarantined: bool,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct TestsPart {
    /// Why there is no result (`no declared tests: ...`); empty when there is one.
    pub note: String,
    /// `2915 tests in 98 suites: 3 failed, ...`, or `All green: ...` when `folded`.
    pub says: String,
    /// Nothing failed: the section is this one line.
    pub folded: bool,
    pub totals: Option<junit::Totals>,
    pub failed: Vec<FailedTest>,
    /// Failures past `FAILED_MAX`.
    pub more: usize,
    /// What the comparison with main's last green run was: `new against #4412 (3 new)`, or why it was not made.
    pub compared: String,
    /// Reports that could not be read.
    pub errors: Vec<String>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct StageJob {
    pub id: u64,
    pub name: String,
    /// `green`, `red`, `running`, `queued`, `open` (not ended, status not given) or `other`.
    pub state: String,
    pub took_text: String,
    /// The first step that failed.
    pub failing: String,
    /// The job has ended, so its log opens (`/api/builds/joblog`).
    pub log: bool,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Stage {
    pub label: String,
    pub jobs: Vec<StageJob>,
}

/// The run's jobs as a staged graph: a column per depth of `needs:`, left to right.
#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Stages {
    /// `archive`, `live` or `none`.
    pub source: String,
    /// Why the graph is one column or empty; empty when the stages are the file's.
    pub note: String,
    pub columns: Vec<Stage>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Hop {
    pub text: String,
    pub href: String,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Chain {
    /// `pull_request`, `workflow_run`, `schedule`: what started it.
    pub trigger: String,
    pub upstream: Option<Hop>,
    pub release: Option<Hop>,
    /// The channels the release reached: `steam-beta 11-19 14:02`.
    pub reached: Vec<String>,
    /// Where a part could not be read.
    pub notes: Vec<String>,
    /// Its place on Releases > Flow.
    pub flow: Hop,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Page {
    pub changes: Changes,
    pub tests: TestsPart,
    pub stages: Stages,
    pub chain: Chain,
}

fn argv(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

fn short(s: &str) -> &str {
    s.get(..7).unwrap_or(s)
}

fn is_hex(s: &str) -> bool {
    s.len() >= 7 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn clone_of(o: &Env, run: &Run) -> Result<std::path::PathBuf, String> {
    let reg = o.registry.ok_or("no project map")?;
    reg.checkout(&run.repo)
        .ok_or_else(|| format!("no clone of {} on this machine", run.repo))
}

#[derive(Default, Debug, Clone, PartialEq)]
pub struct WfJob {
    pub id: String,
    pub name: Option<String>,
    pub needs: Vec<String>,
}

/// What the page reads of a workflow file: its jobs with their `needs:`, and the workflows
/// whose end starts it (`on.workflow_run.workflows`).
#[derive(Default, Debug, Clone, PartialEq)]
pub struct Workflow {
    pub jobs: Vec<WfJob>,
    pub upstream: Vec<String>,
}

fn strip_comment(l: &str) -> &str {
    let mut quote = None;
    let mut prev = ' ';
    for (i, c) in l.char_indices() {
        match (quote, c) {
            (None, '"' | '\'') => quote = Some(c),
            (Some(q), c) if c == q => quote = None,
            (None, '#') if prev.is_whitespace() => return &l[..i],
            _ => {}
        }
        prev = c;
    }
    l
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    for q in ['"', '\''] {
        if let Some(i) = s.strip_prefix(q).and_then(|r| r.strip_suffix(q)) {
            return i.to_string();
        }
    }
    s.to_string()
}

/// `a, "b, c", d` as three items; the commas inside a quote stay.
fn split_list(s: &str) -> Vec<String> {
    let mut out = vec![];
    let (mut cur, mut quote) = (String::new(), None);
    for c in s.chars() {
        match (quote, c) {
            (None, '"' | '\'') => {
                quote = Some(c);
                cur.push(c);
            }
            (Some(q), c) if c == q => {
                quote = None;
                cur.push(c);
            }
            (None, ',') => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out.iter()
        .map(|x| unquote(x))
        .filter(|x| !x.is_empty())
        .collect()
}

/// The items a key at `lines[i]` holds: an inline value (`k: a`, `k: [a, b]`) or the `- x` lines
/// under it, indented or level with the key (YAML allows both). Returns them and the index of the last line read.
fn items(lines: &[(usize, &str)], i: usize) -> (Vec<String>, usize) {
    let (n, l) = lines[i];
    let val = l.split_once(':').map_or("", |(_, v)| v.trim());
    if !val.is_empty() {
        let inner = val
            .strip_prefix('[')
            .and_then(|v| v.strip_suffix(']'))
            .unwrap_or(val);
        return (split_list(inner), i);
    }
    let mut out = vec![];
    let mut j = i;
    while j + 1 < lines.len() && lines[j + 1].0 >= n && lines[j + 1].1.starts_with('-') {
        j += 1;
        out.push(unquote(lines[j].1.trim_start_matches('-').trim()));
    }
    (out, j)
}

/// A workflow file's jobs, `needs:` and `workflow_run` triggers, by a line scanner: the files
/// are regular enough that a YAML parser would only add a dependency.
pub fn parse_workflow(text: &str) -> Workflow {
    let lines: Vec<(usize, &str)> = text
        .lines()
        .map(strip_comment)
        .filter(|l| !l.trim().is_empty())
        .map(|l| (l.len() - l.trim_start().len(), l.trim()))
        .collect();
    let mut w = Workflow::default();
    let jobs_at = lines.iter().position(|(n, l)| *n == 0 && *l == "jobs:");
    let head = &lines[..jobs_at.unwrap_or(lines.len())];
    if let Some(i) = head.iter().position(|(_, l)| *l == "workflow_run:") {
        let n = head[i].0;
        let mut j = i + 1;
        while j < head.len() && head[j].0 > n {
            if head[j].1.starts_with("workflows:") {
                w.upstream = items(head, j).0;
                break;
            }
            j += 1;
        }
    }
    let Some(ji) = jobs_at else { return w };
    let Some(&(job_indent, _)) = lines.get(ji + 1) else {
        return w;
    };
    let mut child: Option<usize> = None;
    let mut i = ji + 1;
    while i < lines.len() && lines[i].0 > 0 {
        let (n, l) = lines[i];
        if n == job_indent {
            if let Some(id) = l.strip_suffix(':') {
                w.jobs.push(WfJob {
                    id: unquote(id),
                    ..Default::default()
                });
                child = None;
            }
        } else if let Some(job) = w.jobs.last_mut() {
            let c = *child.get_or_insert(n);
            if n == c {
                if let Some(v) = l.strip_prefix("name:") {
                    job.name = Some(unquote(v));
                } else if l.starts_with("needs:") {
                    let (list, last) = items(&lines, i);
                    job.needs = list;
                    i = last;
                }
            }
        }
        i += 1;
    }
    w
}

/// How well a run's job name `actual` names workflow job `j`: the length of the template it
/// matches (a matrix adds ` (value)`, a reusable workflow ` / inner`), 0 for none.
fn match_len(actual: &str, j: &WfJob) -> usize {
    let t = j.name.as_deref().unwrap_or(&j.id);
    let t = t.split("${{").next().unwrap_or(t);
    let whole = !j.name.as_deref().unwrap_or(&j.id).contains("${{");
    let t = if whole { t } else { t.trim_end() };
    if t.is_empty() {
        return 0;
    }
    let hit = actual == t
        || actual.starts_with(&format!("{t} ("))
        || actual.starts_with(&format!("{t} / "))
        || (!whole && actual.starts_with(t));
    if hit {
        t.len()
    } else {
        0
    }
}

fn state_of(j: &Job) -> &'static str {
    match j.conclusion.as_deref() {
        Some("success") => "green",
        Some("failure" | "timed_out" | "startup_failure") => "red",
        Some(_) => "other",
        None => match j.status.as_deref() {
            Some("in_progress") => "running",
            Some("queued" | "waiting" | "pending") => "queued",
            _ => "open",
        },
    }
}

fn stage_job(j: &Job) -> StageJob {
    let took = crate::run_detail::span(ts(&j.started_at), ts(&j.completed_at));
    let failing = j
        .steps
        .iter()
        .find(|s| matches!(s.conclusion.as_deref(), Some("failure" | "timed_out")))
        .map(|s| s.name.clone())
        .unwrap_or_default();
    StageJob {
        id: j.id,
        name: j.name.clone(),
        state: state_of(j).into(),
        took_text: if j.started_at.is_some() {
            took_text(took)
        } else {
            "-".into()
        },
        failing,
        log: j.conclusion.is_some() && j.id != 0,
    }
}

/// The jobs drawn as columns by their depth in the file's `needs:` graph. With no file, or none of
/// its jobs matching, one column says why instead of inventing an order.
pub fn stages(jobs: &[Job], wf: Result<&Workflow, &str>, source: &str) -> Stages {
    let flat = |note: String| Stages {
        source: source.into(),
        note,
        columns: if jobs.is_empty() {
            vec![]
        } else {
            vec![Stage {
                label: "Jobs".into(),
                jobs: ordered(jobs.iter().collect()),
            }]
        },
    };
    if jobs.is_empty() {
        return Stages {
            source: source.into(),
            ..Default::default()
        };
    }
    let wf = match wf {
        Ok(w) if !w.jobs.is_empty() => w,
        Ok(_) => return flat("the workflow file lists no jobs: stages unknown".into()),
        Err(e) => return flat(format!("{e}: stages unknown")),
    };
    let mut depth: HashMap<&str, usize> = wf.jobs.iter().map(|j| (j.id.as_str(), 0)).collect();
    for _ in 0..wf.jobs.len() {
        for j in &wf.jobs {
            let d = j
                .needs
                .iter()
                .filter_map(|n| depth.get(n.as_str()))
                .max()
                .map_or(0, |m| m + 1);
            depth.insert(j.id.as_str(), d.min(wf.jobs.len()));
        }
    }
    let mut by: std::collections::BTreeMap<Option<usize>, Vec<&Job>> = Default::default();
    for j in jobs {
        let best = wf
            .jobs
            .iter()
            .map(|w| (match_len(&j.name, w), w))
            .filter(|(n, _)| *n > 0)
            .max_by_key(|(n, _)| *n);
        by.entry(best.map(|(_, w)| depth[w.id.as_str()]))
            .or_default()
            .push(j);
    }
    if by.keys().all(Option::is_none) {
        return flat("no job of this run matches the workflow file: stages unknown".into());
    }
    let mut columns = vec![];
    let mut n = 0;
    // `None` sorts first in a BTreeMap, so the unplaced come last by pulling them out.
    let other = by.remove(&None);
    for (_, js) in by {
        n += 1;
        columns.push(Stage {
            label: format!("Stage {n}"),
            jobs: ordered(js),
        });
    }
    if let Some(js) = other {
        columns.push(Stage {
            label: "Not in the file".into(),
            jobs: ordered(js),
        });
    }
    Stages {
        source: source.into(),
        note: String::new(),
        columns,
    }
}

fn ordered(mut js: Vec<&Job>) -> Vec<StageJob> {
    js.sort_by_key(|j| (ts(&j.started_at).unwrap_or(i64::MAX), j.name.clone()));
    js.into_iter().map(stage_job).collect()
}

#[derive(Deserialize)]
struct JobList {
    jobs: Vec<Job>,
}

fn iso(t: i64) -> String {
    chrono::DateTime::from_timestamp(t, 0)
        .map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_default()
}

/// The jobs of a GitHub run's attempt from `gh api`, kept under the cache `LIVE_TTL_SECS` (for
/// good once the run is done and every job ended): one call per open of a run the archive has not
/// reached, however often the page repaints.
pub fn live_record(o: &Env, run: &Run) -> Result<Record, String> {
    if run.forge != "github" {
        return Err("only GitHub runs read live".into());
    }
    if !junit::safe_repo(&run.repo) {
        return Err(format!("not a repository name: {}", run.repo));
    }
    let file = o.cache.join("live-jobs").join(format!(
        "{}-{}-{}.json",
        run.repo.replace('/', "_"),
        run.id,
        run.attempt
    ));
    let record = |at: i64, body: &str| -> Result<Record, String> {
        let mut jobs = vec![];
        for page in serde_json::Deserializer::from_str(body).into_iter::<JobList>() {
            jobs.extend(page.map_err(|e| format!("job list: {e}"))?.jobs);
        }
        Ok(Record {
            forge: run.forge.clone(),
            repo: run.repo.clone(),
            run_id: run.id,
            attempt: run.attempt,
            source: LIVE_SOURCE.into(),
            complete: false,
            fetched_at: iso(at),
            jobs,
        })
    };
    if let Ok(text) = std::fs::read_to_string(&file) {
        let mut it = text.splitn(2, '\n');
        let head: Vec<&str> = it.next().unwrap_or_default().split(' ').collect();
        if let (Some(at), Some(fin), Some(body)) = (
            head.first().and_then(|a| a.parse::<i64>().ok()),
            head.get(1),
            it.next(),
        ) {
            if *fin == "final" || o.now - at < LIVE_TTL_SECS {
                return record(at, body);
            }
        }
    }
    let url = format!(
        "repos/{}/actions/runs/{}/attempts/{}/jobs?per_page=100",
        run.repo, run.id, run.attempt
    );
    let body = o.runner.run(&argv(&["gh", "api", "--paginate", &url]))?;
    let rec = record(o.now, &body)?;
    let fin = run.done() && !rec.jobs.is_empty() && rec.jobs.iter().all(|j| j.conclusion.is_some());
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(
        &file,
        format!("{} {}\n{body}", o.now, if fin { "final" } else { "open" }),
    );
    Ok(rec)
}

/// The jobs the page names: the archive record when it has one, else the live read.
pub fn record_of(o: &Env, run: &Run, rec: Option<&Record>) -> Result<Record, String> {
    rec.cloned().map(Ok).unwrap_or_else(|| live_record(o, run))
}

/// A job of the run, so a log is only ever fetched for a job that belongs to it.
pub fn job_in(held: Record, run: &Run, id: u64) -> Result<Job, String> {
    held.jobs
        .into_iter()
        .find(|j| j.id == id)
        .ok_or_else(|| format!("job {id} is not a job of run {}", run.id))
}

pub fn job_of(o: &Env, run: &Run, rec: Option<&Record>, id: u64) -> Result<Job, String> {
    job_in(record_of(o, run, rec)?, run, id)
}

fn prev_run<'a>(b: &'a Builds, run: &Run) -> Option<&'a Run> {
    let me = timed_as(&run.workflow, &run.path);
    b.rows
        .iter()
        .filter(|r| {
            r.repo == run.repo
                && r.branch == run.branch
                && r.id != run.id
                && r.done()
                && r.started < run.started
                && timed_as(&r.workflow, &r.path) == me
        })
        .max_by_key(|r| (r.started, r.attempt))
}

fn changes(o: &Env, run: &Run) -> Changes {
    let none = |note: String| Changes {
        note,
        ..Default::default()
    };
    let Some(prev) = prev_run(o.builds, run) else {
        return none(format!(
            "no earlier run of {} on {} in the ledger's 30 days",
            timed_as(&run.workflow, &run.path),
            if run.branch.is_empty() {
                "this branch"
            } else {
                &run.branch
            }
        ));
    };
    let since = format!("#{} ({}, {})", prev.id, short(&prev.sha), prev.state);
    if prev.sha == run.sha {
        return none(format!(
            "same commit as #{}: a re-run, nothing changed",
            prev.id
        ));
    }
    if !is_hex(&prev.sha) || !is_hex(&run.sha) {
        return none("a run's sha is not a commit id".into());
    }
    let dir = match clone_of(o, run) {
        Ok(d) => d,
        Err(e) => return none(e),
    };
    let range = format!("{}..{}", prev.sha, run.sha);
    let out = o.runner.run(&argv(&[
        "git",
        "-C",
        &dir.to_string_lossy(),
        "log",
        "--format=%H%x09%s",
        &range,
    ]));
    let out = match out {
        Ok(t) => t,
        Err(e) => {
            return none(format!(
                "git log {range} failed in the clone ({e}); fetch {} there",
                run.repo
            ))
        }
    };
    let mut commits: Vec<(String, String)> = out
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(h, s)| (h.to_string(), s.to_string()))
        .collect();
    if commits.is_empty() {
        return none(format!(
            "no commits between {range}: the history was rewritten"
        ));
    }
    let more = commits.len().saturating_sub(COMMITS_MAX);
    commits.truncate(COMMITS_MAX);
    let (store, _) = crate::release_graph::read_prs(&o.paths.prs);
    let repo = crate::release_graph::repo_key(&run.repo);
    let mine = |p: &&crate::release_graph::Pr| crate::release_graph::repo_key(&p.repo) == repo;
    let merged_by = |sha: &str| {
        store
            .iter()
            .filter(mine)
            .find(|p| p.merge_sha.as_deref() == Some(sha))
            .map(|p| p.number)
    };
    let commits: Vec<Commit> = commits
        .into_iter()
        .map(|(h, subject)| Commit {
            pr: merged_by(&h),
            sha: short(&h).to_string(),
            subject,
        })
        .collect();
    let mut numbers: Vec<u64> = run.prs.clone();
    for c in &commits {
        if let Some(n) = c.pr.filter(|n| !numbers.contains(n)) {
            numbers.push(n);
        }
    }
    let prs = numbers
        .into_iter()
        .map(|n| {
            let p = store.iter().filter(mine).find(|p| p.number == n);
            ChangePr {
                number: n,
                title: p.map(|p| p.title.clone()).unwrap_or_default(),
                url: p.map(|p| p.url.clone()).unwrap_or_default(),
            }
        })
        .collect();
    Changes {
        note: String::new(),
        since,
        commits,
        more,
        prs,
    }
}

fn pick(reg: &Registry, r: &Run) -> PickRun {
    PickRun {
        repo: r.repo.clone(),
        id: r.id,
        attempt: r.attempt,
        branch: r.branch.clone(),
        sha: short(&r.sha).to_string(),
        title: r.title.clone(),
        state: r.state.clone(),
        level: r.level,
        started: r.started,
        prs: r.prs.clone(),
        url: r.url.clone(),
        artifacts: reg.test_artifacts(&r.repo),
    }
}

fn applied(b: &Builds, repo: &str, l: &Loaded) -> Loaded {
    let lane = b
        .quarantine
        .iter()
        .find(|l| l.repo.eq_ignore_ascii_case(repo));
    l.quarantined(&lane.map(crate::quarantine::Lane::held).unwrap_or_default())
}

fn identity(tier: &str, suite: &str, c: &junit::Case) -> String {
    let name = if c.fullname.is_empty() {
        &c.name
    } else {
        &c.fullname
    };
    format!("{tier}/{suite}/{name}")
}

fn first_line(s: &str) -> String {
    let l = s.lines().next().unwrap_or_default().trim();
    l.chars().take(MESSAGE_CHARS).collect()
}

fn tests(o: &Env, run: &Run) -> TestsPart {
    let note = |n: String| TestsPart {
        note: n,
        ..Default::default()
    };
    let Some(reg) = o.registry else {
        return note("no declared tests: there is no project map to say".into());
    };
    if run.forge != "github" || !reg.test_workflows(&run.repo).contains(&run.path) {
        return note(format!(
            "no declared tests: {} is not in testWorkflows for {}",
            timed_as(&run.workflow, &run.path),
            run.repo
        ));
    }
    if !run.done() {
        return note("the results arrive when the run ends".into());
    }
    if run.state == "other" {
        return note("cancelled or skipped: it uploaded no results".into());
    }
    let loaded = match junit::load(o.cache, &pick(reg, run)) {
        Ok(l) => l,
        Err(e) => return note(format!("results not read: {e}")),
    };
    if loaded.suites.is_empty() {
        return TestsPart {
            note: loaded
                .note
                .clone()
                .unwrap_or_else(|| "the run's reports hold no tests".into()),
            errors: loaded.errors.clone(),
            ..Default::default()
        };
    }
    let l = applied(o.builds, &run.repo, &loaded);
    let totals = junit::totals(&l.suites);
    if totals.failed == 0 && totals.quarantined == 0 {
        return TestsPart {
            says: format!("All green: {}", totals.says()),
            folded: true,
            totals: Some(totals),
            errors: l.errors.clone(),
            ..Default::default()
        };
    }
    let mut compared = String::new();
    let mut before: Option<HashSet<String>> = None;
    if totals.failed > 0 {
        let base = o
            .builds
            .rows
            .iter()
            .filter(|r| {
                r.repo == run.repo
                    && r.path == run.path
                    && r.id != run.id
                    && matches!(r.branch.as_str(), "main" | "master")
                    && r.state == "green"
                    && r.started < run.started
            })
            .max_by_key(|r| r.started);
        match base {
            None => {
                compared = "new failures not marked: no earlier green run on main to compare".into()
            }
            Some(b) => match junit::load(o.cache, &pick(reg, b)) {
                Err(e) => compared = format!("new failures not marked: #{} not read ({e})", b.id),
                Ok(bl) if bl.suites.is_empty() => {
                    compared = format!("new failures not marked: #{} has no results", b.id)
                }
                Ok(bl) => {
                    let bl = applied(o.builds, &b.repo, &bl);
                    before = Some(
                        bl.suites
                            .iter()
                            .flat_map(|s| {
                                s.cases
                                    .iter()
                                    .filter(|c| c.result == "failed")
                                    .map(|c| identity(&s.tier, &s.suite, c))
                            })
                            .collect(),
                    );
                    compared = format!("against #{} on {}", b.id, b.branch);
                }
            },
        }
    }
    let mut failed: Vec<FailedTest> = vec![];
    for s in &l.suites {
        for c in s
            .cases
            .iter()
            .filter(|c| matches!(c.result.as_str(), "failed" | "quarantined"))
        {
            failed.push(FailedTest {
                tier: s.tier.clone(),
                suite: s.suite.clone(),
                name: c.name.clone(),
                message: first_line(&c.message),
                new: c.result == "failed"
                    && before
                        .as_ref()
                        .is_some_and(|b| !b.contains(&identity(&s.tier, &s.suite, c))),
                quarantined: c.result == "quarantined",
            });
        }
    }
    // Failed first, the new ones before the old, the quarantined last.
    failed.sort_by_key(|f| (f.quarantined, !f.new));
    let new = failed.iter().filter(|f| f.new).count();
    if before.is_some() {
        compared = format!("{compared} ({new} new)");
    }
    let more = failed.len().saturating_sub(FAILED_MAX);
    failed.truncate(FAILED_MAX);
    TestsPart {
        says: totals.says(),
        totals: Some(totals),
        failed,
        more,
        compared,
        errors: l.errors.clone(),
        ..Default::default()
    }
}

fn run_hop(r: &Run) -> Hop {
    Hop {
        text: format!("#{} {} {}", r.id, r.workflow, r.state),
        href: Link::to(Kind::CiRun, format!("{}/{}", r.project(), r.id)).href(),
    }
}

fn chain(o: &Env, run: &Run, wf: Result<&Workflow, &str>) -> Chain {
    let mut c = Chain {
        trigger: run.event.clone(),
        flow: Hop {
            text: format!("Flow: {}", run.project()),
            href: Link::tab("releases/flow").href(),
        },
        ..Default::default()
    };
    if run.event == "workflow_run" {
        match wf {
            Ok(w) if !w.upstream.is_empty() => {
                let up = o
                    .builds
                    .rows
                    .iter()
                    .filter(|r| {
                        r.repo == run.repo
                            && r.sha == run.sha
                            && r.id != run.id
                            && r.started <= run.started
                            && w.upstream.contains(&r.workflow)
                    })
                    .max_by_key(|r| r.started);
                match up {
                    Some(r) => c.upstream = Some(run_hop(r)),
                    None => c.notes.push(format!(
                        "upstream: no run of {} on {} in the ledger",
                        w.upstream.join(" or "),
                        short(&run.sha)
                    )),
                }
            }
            Ok(_) => c
                .notes
                .push("upstream: the workflow file names no workflow_run trigger".into()),
            Err(e) => c.notes.push(format!("upstream not read: {e}")),
        }
    }
    let Some(rel) = &run.release else {
        return c;
    };
    c.release = Some(Hop {
        text: format!("{} {}", rel.project, rel.tag),
        href: Link::to(Kind::App, rel.project.clone()).href(),
    });
    match crate::releases::snapshot(o.runner) {
        Err(e) => c.notes.push(format!("channels not read: {e}")),
        Ok(s) => {
            let channels: Vec<_> = s
                .rows
                .iter()
                .filter(|r| r.project == rel.project)
                .cloned()
                .collect();
            let line = s.releases.get(&rel.project);
            match line.and_then(|l| l.tags.iter().find(|t| t.tag == rel.tag).map(|t| (l, t))) {
                None => c.notes.push(format!(
                    "channels: {} is not in {}'s tag history",
                    rel.tag, rel.project
                )),
                Some((l, t)) => {
                    c.reached = crate::release_graph::reached(t, &l.tags, &channels)
                        .into_iter()
                        .map(|x| {
                            let when =
                                x.at.map(|a| format!(" {}", crate::pipeline::dated(a)))
                                    .unwrap_or_default();
                            let how = match x.how.as_str() {
                                "pin" => " (pin)",
                                "live" => " (live)",
                                _ => "",
                            };
                            format!("{}{when}{how}", x.id)
                        })
                        .collect();
                    if c.reached.is_empty() {
                        c.notes.push("channels: none reached yet".into());
                    }
                }
            }
        }
    }
    c
}

/// The file of the workflow a run ran, at its sha, from the repo's clone.
fn workflow_text(o: &Env, run: &Run) -> Result<String, String> {
    if run.path.is_empty() || run.path.starts_with('-') || run.path.contains("..") {
        return Err("the run names no workflow file".into());
    }
    if !is_hex(&run.sha) {
        return Err("the run's sha is not a commit id".into());
    }
    let dir = clone_of(o, run)?;
    o.runner
        .run(&argv(&[
            "git",
            "-C",
            &dir.to_string_lossy(),
            "show",
            &format!("{}:{}", run.sha, run.path),
        ]))
        .map_err(|e| {
            format!(
                "{} at {} is not in the clone ({e})",
                run.path,
                short(&run.sha)
            )
        })
}

/// The five sections of `run`, opened. `rec` is the record its jobs came from (the archive's or a
/// live read); `live_error` says why a live read that was due failed.
pub fn page(
    o: &Env,
    run: &Run,
    rec: Option<&Record>,
    live_error: Option<&str>,
    d: &RunDetail,
) -> Page {
    let text = workflow_text(o, run);
    let wf = text.as_deref().map(parse_workflow);
    let wf_ref: Result<&Workflow, &str> = wf.as_ref().map_err(|e| e.as_str());
    let mut st = match rec {
        Some(r) => stages(
            &r.jobs,
            wf_ref,
            if r.source == LIVE_SOURCE {
                "live"
            } else {
                "archive"
            },
        ),
        None => Stages {
            source: "none".into(),
            ..Default::default()
        },
    };
    if rec.is_none() {
        st.note = match live_error {
            Some(e) => format!("jobs not read: {e}"),
            None => d.coverage_text.clone(),
        };
    }
    Page {
        changes: changes(o, run),
        tests: tests(o, run),
        stages: st,
        chain: chain(o, run, wf_ref),
    }
}

#[cfg(test)]
mod tests_mod {
    use super::*;

    const FILE: &str = r#"
name: Tests (affected)
on:
  workflow_run:
    workflows: ["Checks", 'Build, all']
    types: [completed]
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - run: echo
  shard:
    name: Shard
    needs: plan   # the picker
    strategy:
      matrix:
        n: [1, 2]
  unit:
    name: "Unit ${{ matrix.v }}"
    needs: [plan]
  report:
    needs:
      - shard
      - unit
    if: always()
"#;

    fn job(name: &str, conclusion: Option<&str>, start: i64) -> Job {
        Job {
            id: start as u64 + 1,
            name: name.into(),
            conclusion: conclusion.map(String::from),
            started_at: Some(iso(1_800_000_000 + start)),
            completed_at: conclusion.map(|_| iso(1_800_000_000 + start + 60)),
            ..Default::default()
        }
    }

    #[test]
    fn the_scanner_reads_needs_names_and_the_upstream_workflows() {
        let w = parse_workflow(FILE);
        assert_eq!(w.upstream, ["Checks", "Build, all"]);
        let got: Vec<(&str, Option<&str>, Vec<&str>)> = w
            .jobs
            .iter()
            .map(|j| {
                (
                    j.id.as_str(),
                    j.name.as_deref(),
                    j.needs.iter().map(String::as_str).collect(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                ("plan", None, vec![]),
                ("shard", Some("Shard"), vec!["plan"]),
                ("unit", Some("Unit ${{ matrix.v }}"), vec!["plan"]),
                ("report", None, vec!["shard", "unit"]),
            ]
        );
    }

    #[test]
    fn jobs_draw_as_columns_by_their_depth_and_a_matrix_job_finds_its_file_job() {
        let jobs = [
            job("report", Some("failure"), 300),
            job("Shard (2)", Some("success"), 100),
            job("Shard (1)", Some("success"), 90),
            job("plan", Some("success"), 0),
            job("Unit 3.12", Some("failure"), 95),
            job("stranger", None, 400),
        ];
        let s = stages(&jobs, Ok(&parse_workflow(FILE)), "archive");
        let cols: Vec<(String, Vec<&str>)> = s
            .columns
            .iter()
            .map(|c| {
                (
                    c.label.clone(),
                    c.jobs.iter().map(|j| j.name.as_str()).collect(),
                )
            })
            .collect();
        assert_eq!(
            cols,
            [
                ("Stage 1".to_string(), vec!["plan"]),
                (
                    "Stage 2".to_string(),
                    vec!["Shard (1)", "Unit 3.12", "Shard (2)"]
                ),
                ("Stage 3".to_string(), vec!["report"]),
                ("Not in the file".to_string(), vec!["stranger"]),
            ]
        );
        assert_eq!(s.columns[2].jobs[0].state, "red");
        assert!(s.columns[3].jobs[0].state == "open" && !s.columns[3].jobs[0].log);
    }

    #[test]
    fn a_failing_step_and_an_unfinished_job_read_as_they_are() {
        let mut j = job("plan", Some("failure"), 0);
        j.steps = vec![
            crate::run_detail::Step {
                name: "checkout".into(),
                conclusion: Some("success".into()),
                ..Default::default()
            },
            crate::run_detail::Step {
                name: "PlayMode".into(),
                conclusion: Some("failure".into()),
                ..Default::default()
            },
        ];
        let sj = stage_job(&j);
        assert_eq!((sj.failing.as_str(), sj.log), ("PlayMode", true));
        let live = Job {
            status: Some("in_progress".into()),
            started_at: Some(iso(1_800_000_000)),
            ..Default::default()
        };
        assert_eq!(state_of(&live), "running");
        assert!(!stage_job(&live).log, "a running job has no log yet");
    }

    #[test]
    fn with_no_file_the_jobs_are_one_column_that_says_why() {
        let jobs = [job("a", Some("success"), 0)];
        let s = stages(&jobs, Err("no clone of o/r on this machine"), "live");
        assert_eq!(s.columns.len(), 1);
        assert_eq!(s.columns[0].label, "Jobs");
        assert!(s.note.contains("no clone") && s.note.ends_with("stages unknown"));
        let none = stages(
            &[job("zzz", Some("success"), 0)],
            Ok(&parse_workflow(FILE)),
            "archive",
        );
        assert!(none.note.contains("no job of this run matches"));
    }

    #[test]
    fn a_cycle_in_needs_ends_instead_of_looping() {
        let w = parse_workflow("jobs:\n  a:\n    needs: b\n  b:\n    needs: a\n");
        let s = stages(
            &[job("a", Some("success"), 0), job("b", Some("success"), 1)],
            Ok(&w),
            "archive",
        );
        assert!(!s.columns.is_empty());
    }

    use std::cell::RefCell;
    use std::path::PathBuf;

    const NOW: i64 = 1_800_000_000;

    struct Fake {
        calls: RefCell<Vec<String>>,
        reply: Result<String, String>,
    }

    impl Fake {
        fn new(reply: Result<&str, &str>) -> Fake {
            Fake {
                calls: RefCell::new(vec![]),
                reply: reply.map(String::from).map_err(String::from),
            }
        }
        fn count(&self) -> usize {
            self.calls.borrow().len()
        }
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            self.reply.clone()
        }
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("run-page-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn paths(d: &Path) -> Paths {
        Paths {
            ledger: d.join("runs.jsonl"),
            sync: d.join("sync"),
            fleet: d.join("fleet"),
            prs: d.join("prs"),
            jobs: d.join("jobs"),
            quarantine: d.join("quarantine"),
            run_tags: d.join("tags"),
        }
    }

    fn run_of(id: u64, sha: &str, state: &str, started: i64) -> Run {
        Run {
            forge: "github".into(),
            repo: "o/r".into(),
            id,
            attempt: 1,
            workflow: "Tests".into(),
            branch: "main".into(),
            sha: sha.into(),
            state: state.into(),
            started,
            ..Default::default()
        }
    }

    fn env<'a>(
        b: &'a Builds,
        p: &'a Paths,
        cache: &'a Path,
        r: &'a dyn Runner,
        reg: Option<&'a Registry>,
    ) -> Env<'a> {
        Env {
            builds: b,
            paths: p,
            cache,
            runner: r,
            registry: reg,
            now: NOW,
        }
    }

    const JOBS: &str = r#"{"jobs":[{"id":5,"name":"a","status":"completed","conclusion":"success","html_url":"https://github.com/o/r/actions/runs/9/job/5"}]}"#;
    const OPEN_JOBS: &str = r#"{"jobs":[{"id":5,"name":"a","status":"in_progress"}]}"#;

    #[test]
    fn a_live_read_is_kept_for_the_ttl_while_open_and_for_good_once_final() {
        let d = scratch("live");
        let (p, b) = (paths(&d), Builds::default());
        let running = run_of(9, "abc1234", "running", NOW - 100);
        let gh = Fake::new(Ok(OPEN_JOBS));
        let at = |now: i64| Env {
            now,
            ..env(&b, &p, &d, &gh, None)
        };
        let first = live_record(&at(NOW), &running).unwrap();
        assert_eq!(
            (first.source.as_str(), first.complete, first.jobs.len()),
            (LIVE_SOURCE, false, 1)
        );
        assert!(gh.calls.borrow()[0].contains("repos/o/r/actions/runs/9/attempts/1/jobs"));
        live_record(&at(NOW + LIVE_TTL_SECS - 1), &running).unwrap();
        assert_eq!(gh.count(), 1, "inside the ttl the cache answers");
        live_record(&at(NOW + LIVE_TTL_SECS), &running).unwrap();
        assert_eq!(gh.count(), 2, "past the ttl a still-open run is read again");

        let done = run_of(10, "abc1234", "green", NOW - 100);
        let gh = Fake::new(Ok(JOBS));
        let at = |now: i64| Env {
            now,
            ..env(&b, &p, &d, &gh, None)
        };
        let rec = live_record(&at(NOW), &done).unwrap();
        assert_eq!(
            rec.jobs[0].url.as_deref(),
            Some("https://github.com/o/r/actions/runs/9/job/5")
        );
        live_record(&at(NOW + 86_400), &done).unwrap();
        assert_eq!(
            gh.count(),
            1,
            "a finished run with every job ended is final"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_live_read_refuses_what_it_cannot_ask_gh_about() {
        let d = scratch("refuse");
        let (p, b) = (paths(&d), Builds::default());
        let gh = Fake::new(Err("gh: not logged in"));
        let o = env(&b, &p, &d, &gh, None);
        let mut forgejo = run_of(1, "abc1234", "green", 0);
        forgejo.forge = "forgejo".into();
        assert!(live_record(&o, &forgejo)
            .unwrap_err()
            .contains("only GitHub"));
        let mut odd = run_of(1, "abc1234", "green", 0);
        odd.repo = "../x".into();
        assert!(live_record(&o, &odd)
            .unwrap_err()
            .contains("not a repository name"));
        assert_eq!(gh.count(), 0);
        assert_eq!(
            live_record(&o, &run_of(1, "abc1234", "green", 0)).unwrap_err(),
            "gh: not logged in"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_job_is_only_found_among_the_jobs_of_the_run() {
        let d = scratch("jobof");
        let (p, b) = (paths(&d), Builds::default());
        let gh = Fake::new(Ok(JOBS));
        let o = env(&b, &p, &d, &gh, None);
        let r = run_of(9, "abc1234", "green", 0);
        assert_eq!(job_of(&o, &r, None, 5).unwrap().name, "a");
        assert_eq!(
            job_of(&o, &r, None, 6).unwrap_err(),
            "job 6 is not a job of run 9"
        );
        let rec = Record {
            jobs: vec![job("z", Some("success"), 9)],
            ..Default::default()
        };
        let calls = gh.count();
        assert_eq!(job_of(&o, &r, Some(&rec), 10).unwrap().name, "z");
        assert_eq!(gh.count(), calls, "an archive record answers without gh");
        let _ = std::fs::remove_dir_all(&d);
    }

    const A: &str = "aaaaaaa1111111111111111111111111111111aa";
    const B: &str = "bbbbbbb2222222222222222222222222222222bb";

    #[test]
    fn changes_are_the_commits_since_the_last_run_of_the_workflow_on_the_branch_with_their_prs() {
        let d = scratch("changes");
        let p = paths(&d);
        std::fs::create_dir_all(&p.prs).unwrap();
        std::fs::write(
            p.prs.join("o_r.jsonl"),
            format!(
                "{}\n",
                serde_json::json!({"forge": "github", "repo": "o/r", "number": 12, "state": "MERGED",
                    "title": "fix the gate", "url": "https://github.com/o/r/pull/12", "merge_sha": B})
            ),
        )
        .unwrap();
        let prev = run_of(8, A, "green", NOW - 600);
        let mut me = run_of(9, B, "red", NOW - 100);
        me.prs = vec![12];
        let other_branch = Run {
            branch: "x".into(),
            ..run_of(7, "ccccccc", "green", NOW - 50)
        };
        let b = Builds {
            rows: vec![me.clone(), other_branch, prev],
            ..Default::default()
        };
        let reg =
            Registry::parse(&format!(r#"{{"paths": {{"{}": "o/r"}}}}"#, d.display())).unwrap();
        let git = Fake::new(Ok(&format!(
            "{B}\tfix(gate): stop the retry\n{A}\told thing"
        )));
        let c = changes(&env(&b, &p, &d, &git, Some(&reg)), &me);
        assert_eq!(c.since, "#8 (aaaaaaa, green)");
        assert_eq!(c.commits.len(), 2);
        assert_eq!(
            (c.commits[0].sha.as_str(), c.commits[0].pr),
            ("bbbbbbb", Some(12))
        );
        assert_eq!(c.commits[1].pr, None);
        assert_eq!(
            c.prs,
            vec![ChangePr {
                number: 12,
                title: "fix the gate".into(),
                url: "https://github.com/o/r/pull/12".into()
            }]
        );
        assert!(git.calls.borrow()[0].ends_with(&format!("{A}..{B}")));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn changes_say_why_they_are_empty() {
        let d = scratch("nochanges");
        let p = paths(&d);
        let git = Fake::new(Err("fatal: bad revision"));
        let me = run_of(9, B, "red", NOW - 100);
        let alone = Builds {
            rows: vec![me.clone()],
            ..Default::default()
        };
        assert!(changes(&env(&alone, &p, &d, &git, None), &me)
            .note
            .starts_with("no earlier run of Tests on main"));
        let rerun = Builds {
            rows: vec![me.clone(), run_of(8, B, "green", NOW - 600)],
            ..Default::default()
        };
        assert!(changes(&env(&rerun, &p, &d, &git, None), &me)
            .note
            .contains("same commit as #8"));
        let moved = Builds {
            rows: vec![me.clone(), run_of(8, A, "green", NOW - 600)],
            ..Default::default()
        };
        assert_eq!(
            changes(&env(&moved, &p, &d, &git, None), &me).note,
            "no project map"
        );
        let reg = Registry::parse(r#"{"paths": {}}"#).unwrap();
        assert!(changes(&env(&moved, &p, &d, &git, Some(&reg)), &me)
            .note
            .contains("no clone of o/r"));
        let reg =
            Registry::parse(&format!(r#"{{"paths": {{"{}": "o/r"}}}}"#, d.display())).unwrap();
        let note = changes(&env(&moved, &p, &d, &git, Some(&reg)), &me).note;
        assert!(
            note.contains("failed in the clone") && note.contains("fatal: bad revision"),
            "{note}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_needs_list_level_with_its_key_is_read() {
        let w = parse_workflow("jobs:\n  a:\n    runs-on: x\n  b:\n    needs:\n    - a\n    - c\n  c:\n    runs-on: x\n");
        let b = w.jobs.iter().find(|j| j.id == "b").unwrap();
        assert_eq!(b.needs, vec!["a".to_string(), "c".to_string()]);
        assert_eq!(w.jobs.len(), 3);
    }

    #[test]
    fn pages_of_a_live_read_are_joined_and_more_than_thirty_commits_are_counted() {
        let d = scratch("pages");
        let (p, b) = (paths(&d), Builds::default());
        let two = format!(
            "{}{}",
            r#"{"total_count":2,"jobs":[{"id":1,"name":"a","conclusion":"success"}]}"#,
            r#"{"total_count":2,"jobs":[{"id":2,"name":"b","conclusion":"success"}]}"#
        );
        let gh = Fake::new(Ok(&two));
        let rec = live_record(
            &env(&b, &p, &d, &gh, None),
            &run_of(9, "abc1234", "green", 0),
        )
        .unwrap();
        assert_eq!(
            rec.jobs.iter().map(|j| j.id).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert!(gh.calls.borrow()[0].contains("--paginate"));

        let log: String = (0..200)
            .map(|n| format!("{n:040x}\tcommit {n}\n"))
            .collect();
        let git = Fake::new(Ok(&log));
        let prev = run_of(8, A, "green", NOW - 600);
        let me = run_of(9, B, "red", NOW - 100);
        let bs = Builds {
            rows: vec![me.clone(), prev],
            ..Default::default()
        };
        let reg =
            Registry::parse(&format!(r#"{{"paths": {{"{}": "o/r"}}}}"#, d.display())).unwrap();
        let c = changes(&env(&bs, &p, &d, &git, Some(&reg)), &me);
        assert_eq!((c.commits.len(), c.more), (COMMITS_MAX, 200 - COMMITS_MAX));
        let _ = std::fs::remove_dir_all(&d);
    }
}
