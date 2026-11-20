//! The run page's six sections, in order (docs/dashboards.md, "Run page"): Summary, Changes,
//! Tests, Jobs, Artifacts and Chain. `builds::detail` fills `RunDetail::page` when a run is opened and both
//! surfaces draw that struct; a section that cannot be read says why in its `note`, never a blank
//! or a guess.
//!
//! | section | one source                                                                               |
//! |---------|------------------------------------------------------------------------------------------|
//! | Summary | the run's ledger row and its `RunDetail` header                                           |
//! | Changes | `git log <previous run's sha>..<sha>` in the repo's clone, PRs from the PR store (`release_graph::read_prs`) |
//! | Tests   | the run's junit (`junit::load`, kept on disk), a workflow the repo declares in `testWorkflows` |
//! | Jobs    | the job archive; a run it has not reached reads `gh api .../jobs` once per open (kept `LIVE_TTL_SECS`); the stages from the workflow file's `needs:` at the run's sha |
//! | Artifacts | a workflow the repo declares in `buildWorkflows`: `gh api .../artifacts` plus, with an `artifactStore`, the home store's lister; kept on disk (a running run's `LIVE_TTL_SECS`) |
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

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Artifact {
    pub name: String,
    pub size: u64,
    /// `12M`, from `size`.
    #[serde(default)]
    pub size_text: String,
    /// When it is dropped, RFC 3339; empty when the source did not say.
    pub expires: String,
    /// Past its retention: GitHub says so, or `expires` has gone by.
    pub expired: bool,
    /// `github` or `store` (the home artifact store).
    pub place: String,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Artifacts {
    /// Why there is nothing to list (`no declared builds: ...`); empty when there is a list.
    pub note: String,
    /// `6 artifacts, 640M live`; empty with no artifact.
    pub says: String,
    /// Live ones first, then expired, each by name.
    pub items: Vec<Artifact>,
    /// A source that could not be read (`GitHub: ...`, `store: ...`).
    pub errors: Vec<String>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Page {
    pub changes: Changes,
    pub tests: TestsPart,
    pub stages: Stages,
    pub artifacts: Artifacts,
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
    // `paths` maps a checkout to a project key, while a run names its forge slug (`owner/repo`).
    // Only a key whose own slugs name the run's repo counts, so another owner's repo of the same
    // name never reads this machine's clone.
    reg.lookup(&run.repo)
        .filter(|k| {
            reg.repos(k)
                .iter()
                .any(|s| s.eq_ignore_ascii_case(&run.repo))
        })
        .and_then(|k| reg.checkout(k))
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
        log: j.conclusion.is_some() && j.id != 0 && j.url.is_some(),
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

/// Where a run's artifact list is kept: `<epoch> final|open` on the first line, the JSON after it.
fn artifact_file(o: &Env, run: &Run) -> std::path::PathBuf {
    o.cache.join("artifacts").join(format!(
        "{}-{}-{}.json",
        run.repo.replace('/', "_"),
        run.id,
        run.attempt
    ))
}

#[derive(Deserialize)]
struct GhArtifact {
    name: String,
    #[serde(default)]
    size_in_bytes: u64,
    #[serde(default)]
    expired: bool,
    #[serde(default)]
    expires_at: Option<String>,
}

#[derive(Deserialize)]
struct GhArtifacts {
    #[serde(default)]
    artifacts: Vec<GhArtifact>,
}

fn github_artifacts(o: &Env, run: &Run) -> Result<Vec<Artifact>, String> {
    let url = format!(
        "repos/{}/actions/runs/{}/artifacts?per_page=100",
        run.repo, run.id
    );
    let body = o.runner.run(&argv(&["gh", "api", "--paginate", &url]))?;
    let mut out = vec![];
    for page in serde_json::Deserializer::from_str(&body).into_iter::<GhArtifacts>() {
        let page = page.map_err(|e| format!("artifact list: {e}"))?;
        out.extend(page.artifacts.into_iter().map(|a| Artifact {
            name: a.name,
            size: a.size_in_bytes,
            expires: a.expires_at.unwrap_or_default(),
            expired: a.expired,
            place: "github".into(),
            ..Default::default()
        }));
    }
    Ok(out)
}

/// The run's artifacts in the home store, from the repo's declared lister (`artifact_store`), run
/// from the clone's own path so the script is the one at hand and never one this tree guesses.
fn store_artifacts(o: &Env, run: &Run, script: &str) -> Result<Vec<Artifact>, String> {
    let rel = Path::new(script);
    if rel.is_absolute() || rel.components().any(|c| c.as_os_str() == "..") {
        return Err(format!("artifactStore {script}: a path inside the clone"));
    }
    let path = clone_of(o, run)?.join(rel);
    let out = o.runner.run(&argv(&[
        "env",
        &format!("GITHUB_REPOSITORY={}", run.repo),
        "python3",
        &path.to_string_lossy(),
        "ls",
        "",
        "--run",
        &run.id.to_string(),
    ]))?;
    let mut items = vec![];
    let mut unread = 0;
    for l in out.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = l.split_whitespace().collect();
        match f[..] {
            [name, _run, expires, size] if size.parse::<u64>().is_ok() => items.push(Artifact {
                name: name.into(),
                size: size.parse().unwrap_or_default(),
                expires: expires.into(),
                place: "store".into(),
                ..Default::default()
            }),
            _ => unread += 1,
        }
    }
    if unread > 0 && items.is_empty() {
        return Err(format!(
            "{unread} lines of the lister's answer are not `<name> <run> <expires> <bytes>`"
        ));
    }
    Ok(items)
}

/// What the run built: its artifacts on GitHub and, for a repo with an `artifactStore`, in the home
/// store. Read once on open and kept for good when the run is done (a finished run's artifacts do
/// not change; whether one has expired is judged against the clock at each read), a running run's
/// for `LIVE_TTL_SECS`. A source that fails is named and not kept, so the next open asks again.
fn artifacts(o: &Env, run: &Run) -> Artifacts {
    let note = |n: String| Artifacts {
        note: n,
        ..Default::default()
    };
    let Some(reg) = o.registry else {
        return note("no declared builds: there is no project map to say".into());
    };
    if run.forge != "github" || !reg.build_workflows(&run.repo).contains(&run.path) {
        return note(format!(
            "no declared builds: {} is not in buildWorkflows for {}",
            timed_as(&run.workflow, &run.path),
            run.repo
        ));
    }
    if !junit::safe_repo(&run.repo) {
        return note(format!("not a repository name: {}", run.repo));
    }
    let file = artifact_file(o, run);
    let mut items: Vec<Artifact> = vec![];
    let mut errors: Vec<String> = vec![];
    let kept = std::fs::read_to_string(&file).ok().and_then(|text| {
        let (head, body) = text.split_once('\n')?;
        let (at, fin) = head.split_once(' ')?;
        let fresh = fin == "final" || o.now - at.parse::<i64>().ok()? < LIVE_TTL_SECS;
        fresh
            .then(|| serde_json::from_str::<Vec<Artifact>>(body).ok())
            .flatten()
    });
    match kept {
        Some(k) => items = k,
        None => {
            match github_artifacts(o, run) {
                Ok(a) => items.extend(a),
                Err(e) => errors.push(format!("GitHub: {e}")),
            }
            if let Some(script) = reg.artifact_store(&run.repo) {
                match store_artifacts(o, run, &script) {
                    Ok(a) => items.extend(a),
                    Err(e) => errors.push(format!("store: {e}")),
                }
            }
            if errors.is_empty() {
                if let (Some(dir), Ok(body)) = (file.parent(), serde_json::to_string(&items)) {
                    let _ = std::fs::create_dir_all(dir);
                    let _ = std::fs::write(
                        &file,
                        format!(
                            "{} {}\n{body}",
                            o.now,
                            if run.done() && !items.is_empty() {
                                "final"
                            } else {
                                "open"
                            }
                        ),
                    );
                }
            }
        }
    }
    for a in &mut items {
        let past = chrono::DateTime::parse_from_rfc3339(&a.expires)
            .map(|t| t.timestamp() <= o.now)
            .unwrap_or(false);
        a.expired = a.expired || past;
        a.size_text = crate::host_now::bytes(a.size as f64);
    }
    items.sort_by(|a, b| (a.expired, &a.name).cmp(&(b.expired, &b.name)));
    let live: Vec<&Artifact> = items.iter().filter(|a| !a.expired).collect();
    let says = if items.is_empty() {
        String::new()
    } else if live.is_empty() {
        format!("{} artifacts, all expired", items.len())
    } else {
        format!(
            "{} artifacts, {} live",
            items.len(),
            crate::host_now::bytes(live.iter().map(|a| a.size).sum::<u64>() as f64)
        )
    };
    let note = if items.is_empty() && errors.is_empty() {
        if run.done() {
            "the run uploaded no artifact, or its retention has dropped them".to_string()
        } else {
            "no artifact yet: they arrive as the jobs end".to_string()
        }
    } else {
        String::new()
    };
    Artifacts {
        note,
        says,
        items,
        errors,
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
    // A Forgejo task names its workflow by file name alone; Forgejo reads `.forgejo/workflows`, else
    // `.github/workflows`, so those are where the file is looked for.
    let at = if run.forge == "forgejo" && !run.path.contains('/') {
        vec![
            format!(".forgejo/workflows/{}", run.path),
            format!(".github/workflows/{}", run.path),
        ]
    } else {
        vec![run.path.clone()]
    };
    let mut err = String::new();
    for p in &at {
        match o.runner.run(&argv(&[
            "git",
            "-C",
            &dir.to_string_lossy(),
            "show",
            &format!("{}:{p}", run.sha),
        ])) {
            Ok(text) => return Ok(text),
            Err(e) => err = e,
        }
    }
    Err(format!(
        "{} at {} is not in the clone ({err})",
        run.path,
        short(&run.sha)
    ))
}

/// The sections of `run`, opened. `rec` is the record its jobs came from (the archive's or a
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
        artifacts: artifacts(o, run),
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
            url: Some(format!("https://example.test/jobs/{start}")),
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
        let reg = Registry::parse(&format!(
            r#"{{"paths": {{"{}": "t"}}, "trackers": {{"t": {{"github": "o/r"}}}}}}"#,
            d.display()
        ))
        .unwrap();
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
        let reg = Registry::parse(&format!(
            r#"{{"paths": {{"{}": "t"}}, "trackers": {{"t": {{"github": "o/r"}}}}}}"#,
            d.display()
        ))
        .unwrap();
        let note = changes(&env(&moved, &p, &d, &git, Some(&reg)), &me).note;
        assert!(
            note.contains("failed in the clone") && note.contains("fatal: bad revision"),
            "{note}"
        );
        // Another owner's repo of the same name finds no clone, and the clone's git never runs.
        let foreign: Vec<Run> = moved
            .rows
            .iter()
            .cloned()
            .map(|mut r| {
                r.repo = "x/r".into();
                r
            })
            .collect();
        let elsewhere = Builds {
            rows: foreign.clone(),
            ..Default::default()
        };
        let calls = git.calls.borrow().len();
        let note = changes(&env(&elsewhere, &p, &d, &git, Some(&reg)), &foreign[0]).note;
        assert!(note.contains("no clone of x/r"), "{note}");
        assert_eq!(git.calls.borrow().len(), calls);
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
        let reg = Registry::parse(&format!(
            r#"{{"paths": {{"{}": "t"}}, "trackers": {{"t": {{"github": "o/r"}}}}}}"#,
            d.display()
        ))
        .unwrap();
        let c = changes(&env(&bs, &p, &d, &git, Some(&reg)), &me);
        assert_eq!((c.commits.len(), c.more), (COMMITS_MAX, 200 - COMMITS_MAX));
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Answers `gh api` and the store's lister apart, so a run reading both says which it asked.
    struct Both {
        gh: Result<String, String>,
        store: Result<String, String>,
        calls: RefCell<Vec<String>>,
    }

    impl Runner for Both {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            if argv[0] == "gh" {
                self.gh.clone()
            } else {
                self.store.clone()
            }
        }
    }

    const BUILD: &str = ".github/workflows/release.yml";
    const GH_ARTS: &str = r#"{"total_count":2,"artifacts":[
        {"name":"release-g-mac","size_in_bytes":5242880,"expired":false,"expires_at":"2027-02-01T00:00:00Z"},
        {"name":"old","size_in_bytes":10,"expired":true,"expires_at":"2020-01-01T00:00:00Z"}]}"#;

    fn build_run(id: u64, state: &str) -> Run {
        Run {
            workflow: "Release builds".into(),
            path: BUILD.into(),
            ..run_of(id, "abc1234", state, NOW - 100)
        }
    }

    fn build_reg(d: &Path, store: bool) -> Registry {
        Registry::parse(&format!(
            r#"{{"paths": {{"{}": "t"}}, "trackers": {{"t": {{"github": "o/r", "buildWorkflows": ["{BUILD}"]{} }}}}}}"#,
            d.display(),
            if store { r#", "artifactStore": "tools/art.py""# } else { "" }
        ))
        .unwrap()
    }

    #[test]
    fn a_build_runs_artifacts_come_from_github_and_the_store_expired_ones_last() {
        let d = scratch("arts");
        let (p, b) = (paths(&d), Builds::default());
        let reg = build_reg(&d, true);
        let both = Both {
            gh: Ok(GH_ARTS.into()),
            store: Ok("release-g-server 9 2027-03-01T19:15:04Z 81182720\nrelease-g-mac-logs 9 2027-01-16T00:00:00Z 1048576\nnoise\n".into()),
            calls: RefCell::new(vec![]),
        };
        let run = build_run(9, "green");
        let a = artifacts(&env(&b, &p, &d, &both, Some(&reg)), &run);
        let names: Vec<_> = a
            .items
            .iter()
            .map(|x| (x.name.as_str(), x.place.as_str(), x.expired))
            .collect();
        assert_eq!(
            names,
            [
                ("release-g-mac", "github", false),
                ("release-g-mac-logs", "store", false),
                ("release-g-server", "store", false),
                ("old", "github", true),
            ]
        );
        assert_eq!(a.items[0].size_text, "5.0M");
        assert_eq!(a.says, "4 artifacts, 83M live");
        assert!(a.errors.is_empty() && a.note.is_empty());
        let calls = both.calls.borrow();
        assert!(calls[0].contains("repos/o/r/actions/runs/9/artifacts"));
        assert!(
            calls[1].starts_with("env GITHUB_REPOSITORY=o/r python3 "),
            "{}",
            calls[1]
        );
        assert!(calls[1].ends_with("tools/art.py ls  --run 9"));
        drop(calls);
        // a finished run is kept for good: a day later neither source is asked again.
        let later = Env {
            now: NOW + 86_400,
            ..env(&b, &p, &d, &both, Some(&reg))
        };
        let again = artifacts(&later, &run);
        assert_eq!(both.calls.borrow().len(), 2);
        assert!(
            again.items.iter().filter(|x| x.expired).count() == 2,
            "the clock expires the one that was live"
        );
        assert_eq!(again.says, "4 artifacts, 82M live");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn artifacts_say_why_they_are_empty_and_a_failed_source_is_named_and_asked_again() {
        let d = scratch("arts-empty");
        let (p, b) = (paths(&d), Builds::default());
        let gh = Fake::new(Ok(r#"{"total_count":0,"artifacts":[]}"#));
        let reg = build_reg(&d, false);
        // negative control: a workflow no registry entry calls a build.
        let tests = run_of(1, "abc1234", "green", NOW);
        assert!(artifacts(&env(&b, &p, &d, &gh, Some(&reg)), &tests)
            .note
            .starts_with("no declared builds:"));
        assert!(artifacts(&env(&b, &p, &d, &gh, None), &tests)
            .note
            .contains("no project map"));
        assert_eq!(gh.count(), 0);
        let done = artifacts(&env(&b, &p, &d, &gh, Some(&reg)), &build_run(2, "green"));
        assert!(done.note.contains("retention"), "{}", done.note);
        let open = artifacts(&env(&b, &p, &d, &gh, Some(&reg)), &build_run(3, "running"));
        assert!(open.note.contains("as the jobs end"), "{}", open.note);
        // a failed read is not kept: the next open asks again, and the page names the source.
        let down = Fake::new(Err("gh: HTTP 502"));
        let run = build_run(4, "green");
        let a = artifacts(&env(&b, &p, &d, &down, Some(&reg)), &run);
        assert_eq!(a.errors, ["GitHub: gh: HTTP 502"]);
        assert!(a.note.is_empty() && a.items.is_empty());
        artifacts(&env(&b, &p, &d, &down, Some(&reg)), &run);
        assert_eq!(down.count(), 2);
        // a running run's list is read again past the ttl, not before.
        let at = |now: i64| Env {
            now,
            ..env(&b, &p, &d, &gh, Some(&reg))
        };
        let before = gh.count();
        artifacts(&at(NOW + LIVE_TTL_SECS - 1), &build_run(3, "running"));
        assert_eq!(gh.count(), before);
        artifacts(&at(NOW + LIVE_TTL_SECS), &build_run(3, "running"));
        assert_eq!(gh.count(), before + 1);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn the_store_lister_is_a_path_inside_the_clone() {
        let d = scratch("arts-path");
        let (p, b) = (paths(&d), Builds::default());
        let both = Both {
            gh: Ok("{}".into()),
            store: Ok(String::new()),
            calls: RefCell::new(vec![]),
        };
        let reg = Registry::parse(&format!(
            r#"{{"paths": {{"{}": "t"}}, "trackers": {{"t": {{"github": "o/r", "buildWorkflows": ["{BUILD}"], "artifactStore": "../x.py"}}}}}}"#,
            d.display()
        ))
        .unwrap();
        let a = artifacts(&env(&b, &p, &d, &both, Some(&reg)), &build_run(5, "green"));
        assert!(
            a.errors[0].starts_with("store: artifactStore ../x.py"),
            "{:?}",
            a.errors
        );
        assert_eq!(both.calls.borrow().len(), 1, "the lister never ran");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_rerun_reads_its_own_list_an_empty_finished_list_is_asked_again_and_a_lister_in_a_new_format_is_named(
    ) {
        let d = scratch("arts-keep");
        let (p, b) = (paths(&d), Builds::default());
        let reg = build_reg(&d, true);
        let both = Both {
            gh: Ok(GH_ARTS.into()),
            store: Ok("a 9 2027-03-01T00:00:00Z 1\n".into()),
            calls: RefCell::new(vec![]),
        };
        let first = build_run(9, "green");
        artifacts(&env(&b, &p, &d, &both, Some(&reg)), &first);
        let again = Run {
            attempt: 2,
            ..first.clone()
        };
        artifacts(&env(&b, &p, &d, &both, Some(&reg)), &again);
        assert_eq!(
            both.calls.borrow().len(),
            4,
            "attempt 2 is not served attempt 1's list"
        );

        // an upload the store had not indexed yet leaves an empty list, which is not kept for good.
        let empty = Both {
            gh: Ok("{}".into()),
            store: Ok(String::new()),
            calls: RefCell::new(vec![]),
        };
        let run = build_run(10, "green");
        artifacts(&env(&b, &p, &d, &empty, Some(&reg)), &run);
        let later = Env {
            now: NOW + LIVE_TTL_SECS,
            ..env(&b, &p, &d, &empty, Some(&reg))
        };
        artifacts(&later, &run);
        assert_eq!(empty.calls.borrow().len(), 4);

        let odd = Both {
            gh: Ok("{}".into()),
            store: Ok("a b c\nd e f g\n".into()),
            calls: RefCell::new(vec![]),
        };
        let a = artifacts(&env(&b, &p, &d, &odd, Some(&reg)), &build_run(11, "green"));
        assert!(
            a.errors[0].starts_with("store: 2 lines of the lister's answer"),
            "{:?}",
            a.errors
        );
        let _ = std::fs::remove_dir_all(&d);
    }
}
