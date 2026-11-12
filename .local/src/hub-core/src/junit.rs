//! Infra's CI Tests section: what each finished run of a repo's declared test workflow said, suite
//! by suite and test by test, from the artifacts the workflow uploads its results in (a tier's
//! shards each upload one). A repo declares its workflows and the artifact names in the registry
//! (`testWorkflows` and `testArtifacts` on its tracker); a repo that declares no workflow lists no
//! runs. The runs come from the builds ledger; an artifact is fetched with `gh run download` only
//! when its run is read (docs/dashboards.md rule 10) and kept under the hub cache, since a finished
//! run's artifacts never change and GitHub drops them after the workflow's retention.
//!
//! | fact                    | home                                                              |
//! |-------------------------|-------------------------------------------------------------------|
//! | which runs have results | the builds ledger: finished runs of a workflow the repo declares    |
//! | which workflows count   | the registry: `trackers.<repo>.testWorkflows`                      |
//! | which artifacts         | the registry: `trackers.<repo>.testArtifacts`, else `junit-*`      |
//! | a suite or a test       | `<cache>/junit/<repo>-<run>-<attempt>/<artifact>/**/{report,results}.xml` |
//! | the tier                | the artifact's name after the glob's prefix: `junit-ui-tmux-3.8` is `ui`, `test-runs-playmode-3` is `playmode` |
//! | a quarantined test      | a failure whose full name the repo's quarantine holds (`quarantine::Lane::held`) |
//!
//! The results are read by a small scanner here rather than a new XML dependency. A bats JUnit
//! report (`report.xml`) has `testsuite`, `testcase` and a `failure`, `error` or `skipped` child.
//! An NUnit file (`results.xml`, Unity's) has `test-case` elements, read as one suite per class;
//! a test in several files of one tier (a shard rerun) is the newest file's.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use project_map::Registry;
use serde::Serialize;

use crate::builds::{Builds, Run};
use crate::releases::Level;
use crate::table::{Row, Summary, Val, View};

/// How many runs of each repo the picker offers, newest first.
pub const PICK_RUNS: usize = 30;
/// The most of a failure's text kept per test.
pub const MESSAGE_BYTES: usize = 4000;
/// The cap on the suites a surface draws at once.
pub const LIST_ROWS: usize = 100;
/// The cap on the tests of one opened suite.
pub const CASE_ROWS: usize = 300;
/// The lines of an NUnit stack trace kept under its failure's message.
pub const STACK_LINES: usize = 8;

/// A run the picker offers.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct PickRun {
    pub repo: String,
    pub id: u64,
    pub attempt: u32,
    pub branch: String,
    pub sha: String,
    pub title: String,
    pub state: String,
    pub level: Level,
    pub started: i64,
    pub prs: Vec<u64>,
    pub url: String,
    /// The artifact name globs its results are in (`project_map::Registry::test_artifacts`).
    #[serde(skip)]
    pub artifacts: Vec<String>,
}

impl PickRun {
    fn of(r: &Run) -> PickRun {
        PickRun {
            repo: r.repo.clone(),
            id: r.id,
            attempt: r.attempt,
            branch: r.branch.clone(),
            sha: r.sha.chars().take(7).collect(),
            title: r.title.clone(),
            state: r.state.clone(),
            level: r.level,
            started: r.started,
            prs: r.prs.clone(),
            url: r.url.clone(),
            artifacts: vec![],
        }
    }

    /// Its artifact globs, `junit-*` when none were given.
    fn globs(&self) -> Vec<&str> {
        match self.artifacts.as_slice() {
            [] => vec![project_map::DEFAULT_TEST_ARTIFACTS],
            a => a.iter().map(String::as_str).collect(),
        }
    }
}

/// The finished runs of each repo's declared test workflows, newest first, one per run id (its
/// latest attempt), at most `PICK_RUNS` per repo so a busy repo never pushes a quiet one out: a
/// cancelled or skipped run uploaded nothing worth listing. With no registry no repo declares any.
pub fn pickable(b: &Builds, registry: Option<&Registry>) -> Vec<PickRun> {
    let Some(reg) = registry else {
        return vec![];
    };
    let mut declared: HashMap<&str, Vec<String>> = HashMap::new();
    let mut best: Vec<&Run> = vec![];
    for r in b
        .rows
        .iter()
        .filter(|r| r.forge == "github" && matches!(r.state.as_str(), "green" | "red"))
    {
        let workflows = declared
            .entry(r.repo.as_str())
            .or_insert_with(|| reg.test_workflows(&r.repo));
        if !workflows.contains(&r.path) {
            continue;
        }
        match best.iter_mut().find(|o| (&o.repo, o.id) == (&r.repo, r.id)) {
            Some(o) if o.attempt < r.attempt => *o = r,
            Some(_) => {}
            None => best.push(r),
        }
    }
    let mut kept: HashMap<&str, usize> = HashMap::new();
    best.into_iter()
        .filter(|r| {
            let n = kept.entry(r.repo.as_str()).or_default();
            *n += 1;
            *n <= PICK_RUNS
        })
        .map(|r| PickRun {
            artifacts: reg.test_artifacts(&r.repo),
            ..PickRun::of(r)
        })
        .collect()
}

/// The repos `runs` (from `pickable`) offer, the one with the newest run first.
pub fn repos(runs: &[PickRun]) -> Vec<&str> {
    let mut out: Vec<&str> = vec![];
    for r in runs {
        if !out.contains(&r.repo.as_str()) {
            out.push(&r.repo);
        }
    }
    out
}

/// One test of a suite.
#[derive(Serialize, Debug, Clone, Default, PartialEq)]
pub struct Case {
    pub name: String,
    /// NUnit's full name, what a quarantine entry names; bats has none.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub fullname: String,
    /// `passed`, `failed`, `quarantined` or `skipped`.
    pub result: String,
    pub time: f64,
    /// The failure's text, or the reason it was skipped.
    pub message: String,
    /// When its results file's run started, so a rerun's result replaces the earlier one.
    #[serde(skip)]
    pub at: String,
}

/// One bats file, or one NUnit class, of one tier.
#[derive(Serialize, Debug, Clone, Default, PartialEq)]
pub struct Suite {
    pub tier: String,
    pub suite: String,
    pub tests: usize,
    pub passed: usize,
    pub failed: usize,
    /// Failures of tests the repo's quarantine holds: amber, not counted as failed.
    pub quarantined: usize,
    pub skipped: usize,
    pub time: f64,
    /// `failed` when any test failed, else `quarantined`, else `skipped` when any was, else
    /// `passed`.
    pub state: String,
    pub level: Level,
    #[serde(skip)]
    pub cases: Vec<Case>,
    /// What a bare search word is matched against: the suite, its tier and its test names, lowercased.
    #[serde(skip)]
    hay: String,
}

impl Suite {
    /// A suite of these tests, its counts and state worked out from them.
    pub fn new(tier: &str, suite: &str, cases: Vec<Case>) -> Self {
        let mut s = Suite {
            tier: tier.into(),
            suite: suite.into(),
            cases,
            ..Default::default()
        };
        s.settle();
        s
    }

    fn settle(&mut self) {
        let n = |r: &str| self.cases.iter().filter(|c| c.result == r).count();
        self.tests = self.cases.len();
        self.failed = n("failed");
        self.quarantined = n("quarantined");
        self.skipped = n("skipped");
        self.passed = n("passed");
        let (state, level) = match (self.failed, self.quarantined, self.skipped) {
            (0, 0, 0) => ("passed", Level::Ok),
            (0, 0, _) => ("skipped", Level::Ok),
            (0, _, _) => ("quarantined", Level::Warn),
            _ => ("failed", Level::Bad),
        };
        self.state = state.to_string();
        self.level = level;
        let mut hay = format!("{}\n{}", self.suite, self.tier);
        for c in &self.cases {
            hay.push('\n');
            hay.push_str(&c.name);
        }
        self.hay = hay.to_lowercase();
    }

    fn rank(&self) -> u8 {
        rank_of(&self.state)
    }
}

/// A suite's state or a test's result in the order they list: the worst first.
fn rank_of(result: &str) -> u8 {
    match result {
        "failed" => 0,
        "quarantined" => 1,
        "skipped" => 2,
        _ => 3,
    }
}

/// A suite's state chips and its tests' alike: a suite is in the state of its worst test.
const RESULTS: &[&str] = &["all", "failed", "quarantined", "skipped", "passed"];

impl Row for Case {
    const COLUMNS: &'static [&'static str] = &["result", "name", "time"];
    const STATES: &'static [&'static str] = RESULTS;
    const FACETS: &'static [&'static str] = &[];
    const LEAD: &'static str = "name";
    const GLANCE: &'static [&'static str] = &["result", "time"];

    fn val(&self, col: &str) -> Val {
        match col {
            "result" => Val::Text(self.result.clone()),
            "name" => Val::Text(self.name.clone()),
            "time" => Val::Num(self.time),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        state == "all" || self.result == state
    }

    /// A bare word finds a test by its name, its NUnit full name or its failure's text.
    fn text(&self) -> String {
        [&self.name, &self.fullname, &self.message]
            .map(|s| s.as_str())
            .join("\n")
            .to_lowercase()
    }
}

impl Row for Suite {
    const COLUMNS: &'static [&'static str] = &[
        "state",
        "tier",
        "suite",
        "tests",
        "failed",
        "quarantined",
        "skipped",
        "time",
    ];
    const STATES: &'static [&'static str] = RESULTS;
    const FACETS: &'static [&'static str] = &["tier"];
    const LEAD: &'static str = "suite";
    const GLANCE: &'static [&'static str] = &["state", "tier", "failed"];

    fn val(&self, col: &str) -> Val {
        let num = |n: usize| Val::Num(n as f64);
        match col {
            "state" => Val::Text(self.state.clone()),
            "tier" => Val::Text(self.tier.clone()),
            "suite" => Val::Text(self.suite.clone()),
            "tests" => num(self.tests),
            "failed" => num(self.failed),
            "quarantined" => num(self.quarantined),
            "skipped" => num(self.skipped),
            "time" => Val::Num(self.time),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        state == "all" || self.state == state
    }

    /// A bare word finds the suite holding a test of that name.
    fn text(&self) -> String {
        self.hay.clone()
    }
}

/// What a run's suites add up to.
#[derive(Serialize, Debug, Clone, Default, PartialEq)]
pub struct Totals {
    pub suites: usize,
    pub tests: usize,
    pub passed: usize,
    /// Real failures only: a quarantined one is `quarantined`.
    pub failed: usize,
    pub quarantined: usize,
    pub skipped: usize,
    pub failed_suites: usize,
    pub time: f64,
}

pub fn totals(suites: &[Suite]) -> Totals {
    let mut t = Totals {
        suites: suites.len(),
        ..Default::default()
    };
    for s in suites {
        t.tests += s.tests;
        t.passed += s.passed;
        t.failed += s.failed;
        t.quarantined += s.quarantined;
        t.skipped += s.skipped;
        t.failed_suites += usize::from(s.failed > 0);
        t.time += s.time;
    }
    t
}

impl Totals {
    /// `2915 tests in 98 suites: 3 failed, 12 skipped, 2900 passed`, with `, 2 quarantined`
    /// after the failed when any were.
    pub fn says(&self) -> String {
        let held = match self.quarantined {
            0 => String::new(),
            n => format!(", {n} quarantined"),
        };
        format!(
            "{} test{} in {} suite{}: {} failed{held}, {} skipped, {} passed",
            self.tests,
            if self.tests == 1 { "" } else { "s" },
            self.suites,
            if self.suites == 1 { "" } else { "s" },
            self.failed,
            self.skipped,
            self.passed
        )
    }
}

/// The rows to draw and the one line a run with no failure, quarantined ones included, folds to
/// (docs/dashboards.md rule 4).
/// Only the plain view folds: any query, chip or sort is the human asking for those rows. The
/// way open is the `passed` chip.
pub fn fold<'a>(view: &View, rows: Vec<&'a Suite>, t: &Totals) -> (Vec<&'a Suite>, Option<String>) {
    if !view.is_default() || t.failed > 0 || t.quarantined > 0 || rows.is_empty() {
        return (rows, None);
    }
    (vec![], Some(format!("All green: {}", t.says())))
}

/// The first `LIST_ROWS` of `rows`, and how many were left out.
pub fn cap(rows: Vec<&Suite>) -> (Vec<&Suite>, usize) {
    let more = rows.len().saturating_sub(LIST_ROWS);
    (rows.into_iter().take(LIST_ROWS).collect(), more)
}

/// A run's results as read.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Loaded {
    pub suites: Vec<Suite>,
    /// A report that could not be read; the rest still list.
    pub errors: Vec<String>,
    /// Why there is nothing to list when that is not a fault.
    pub note: Option<String>,
}

impl Loaded {
    /// These results with each failure of a test in `held` (a quarantine's names) marked
    /// `quarantined`. Applied per read, so the cached results never go stale on a quarantine change.
    pub fn quarantined(&self, held: &HashSet<&str>) -> Loaded {
        let mut out = self.clone();
        if held.is_empty() {
            return out;
        }
        for s in &mut out.suites {
            let mut hit = false;
            for c in &mut s.cases {
                if c.result == "failed" && held.contains(c.fullname.as_str()) {
                    c.result = "quarantined".into();
                    hit = true;
                }
            }
            if hit {
                s.settle();
            }
        }
        sort(&mut out.suites);
        out
    }

    /// The tests of one suite the view keeps, worst first and then in the report's order unless
    /// it sorts, capped at `CASE_ROWS`; the summary counts every test, and the last value the
    /// ones the cap left out.
    pub fn cases(
        &self,
        tier: &str,
        suite: &str,
        view: &View,
    ) -> Option<(Vec<&Case>, Summary, usize)> {
        let s = self
            .suites
            .iter()
            .find(|s| s.tier == tier && s.suite == suite)?;
        let (mut cases, mut table) = view.summary(&s.cases);
        if view.sort.is_empty() {
            cases.sort_by_key(|c| rank_of(&c.result));
        }
        let more = crate::table::cap(&mut cases, &mut table, CASE_ROWS);
        Some((cases, table, more))
    }
}

/// Where a run's artifacts are kept.
/// A run's download dir, keyed on its globs too: a repo whose `testArtifacts` change fetches its
/// runs again rather than reading what the old globs left. The default globs keep the bare name.
fn run_dir(cache: &Path, repo: &str, id: u64, attempt: u32, globs: &[&str]) -> PathBuf {
    let base = format!("{}-{id}-{attempt}", repo.replace('/', "_"));
    if globs == [project_map::DEFAULT_TEST_ARTIFACTS] {
        return cache.join("junit").join(base);
    }
    let key: String = globs
        .join("+")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '+' {
                c
            } else {
                '_'
            }
        })
        .collect();
    cache.join("junit").join(format!("{base}-{key}"))
}

/// Where a download lands before it is renamed into place, so a half-fetched run is never read.
/// A repo name may hold a dot (`.dotfiles`), so the suffix is appended, not swapped in.
fn part_dir(dir: &Path) -> PathBuf {
    let mut name = dir.file_name().unwrap_or_default().to_os_string();
    name.push(".part");
    dir.with_file_name(name)
}

fn safe_repo(repo: &str) -> bool {
    let mut parts = repo.split('/');
    let ok = |s: &str| {
        !s.is_empty()
            && !s.starts_with('-')
            && !s.chars().all(|c| c == '.')
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    };
    matches!((parts.next(), parts.next(), parts.next()), (Some(a), Some(b), None) if ok(a) && ok(b))
}

const NONE_MARK: &str = ".none";

fn none_note(globs: &[&str]) -> String {
    format!(
        "this run uploaded no {} artifact (it ran before the workflow did, or GitHub's retention has dropped them)",
        globs.join(" or ")
    )
}

/// Downloads a run's artifacts that match its globs into its directory, once. A run with none
/// leaves a marker so it is not asked again; any other failure leaves nothing, so the next read
/// retries. New globs are a new dir (`run_dir`), so they fetch again.
fn fetch(dir: &Path, run: &PickRun) -> Result<(), String> {
    if dir.is_dir() {
        return Ok(());
    }
    if !safe_repo(&run.repo) {
        return Err(format!("not a repository name: {}", run.repo));
    }
    let part = part_dir(dir);
    let _ = std::fs::remove_dir_all(&part);
    std::fs::create_dir_all(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    let out = Command::new("gh")
        .args(["run", "download", &run.id.to_string(), "-R", &run.repo])
        .args(run.globs().iter().flat_map(|g| ["-p", *g]))
        .arg("-D")
        .arg(&part)
        .output()
        .map_err(|e| format!("gh: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if !err.contains("no valid artifacts") {
            let _ = std::fs::remove_dir_all(&part);
            return Err(format!("gh run download: {err}"));
        }
        std::fs::write(part.join(NONE_MARK), "").map_err(|e| e.to_string())?;
    }
    std::fs::rename(&part, dir).map_err(|e| format!("{}: {e}", dir.display()))
}

/// The tier an artifact's name says: its first word after the literal prefix of the glob it
/// matched, so `junit-unit-1` is `unit` and `test-runs-playmode-3` is `playmode`.
pub fn tier_of(artifact: &str, globs: &[&str]) -> String {
    globs
        .iter()
        .map(|g| g.split(['*', '?', '[']).next().unwrap_or_default())
        .filter(|pre| !pre.is_empty())
        .find_map(|pre| artifact.strip_prefix(pre))
        .unwrap_or(artifact)
        .split('-')
        .next()
        .unwrap_or_default()
        .to_string()
}

fn reports(dir: &Path, depth: u8, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        if p.is_dir() && depth > 0 {
            reports(&p, depth - 1, out);
        } else if p
            .file_name()
            .is_some_and(|n| n == "report.xml" || n == "results.xml")
        {
            out.push(p);
        }
    }
}

/// The results of `run`: downloaded on first read, then read from the kept files. Blocks on `gh`.
pub fn load(cache: &Path, run: &PickRun) -> Result<Loaded, String> {
    let dir = run_dir(cache, &run.repo, run.id, run.attempt, &run.globs());
    fetch(&dir, run)?;
    let globs = run.globs();
    let mut out = Loaded::default();
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return Err(format!("{}: unreadable", dir.display()));
    };
    let mut artifacts: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    artifacts.sort();
    for art in artifacts {
        let name = art.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        let tier = tier_of(name, &globs);
        let mut files = vec![];
        reports(&art, 3, &mut files);
        for f in files {
            let parsed = std::fs::read_to_string(&f)
                .map_err(|e| e.to_string())
                .and_then(|x| parse(&x, &tier));
            match parsed {
                Ok(s) => out.suites.extend(s),
                Err(e) => out.errors.push(format!("{name}: {e}")),
            }
        }
    }
    if out.suites.is_empty() && out.errors.is_empty() {
        out.note = Some(if dir.join(NONE_MARK).exists() {
            none_note(&globs)
        } else {
            "the artifacts hold no test report".to_string()
        });
    }
    out.suites = merged(out.suites);
    sort(&mut out.suites);
    Ok(out)
}

fn sort(suites: &mut [Suite]) {
    suites.sort_by(|a, b| (a.rank(), &a.tier, &a.suite).cmp(&(b.rank(), &b.tier, &b.suite)));
}

/// One suite per (tier, file or class): a tier uploaded by several artifacts (the tmux versions
/// of the ui tier) runs the same file in each, and the rows, the totals and an opened suite count
/// them as one. A named NUnit test is kept once, from the newest file: a shard that reran it
/// reports it again, and only the last run says what it is now.
fn merged(suites: Vec<Suite>) -> Vec<Suite> {
    let mut out: Vec<Suite> = vec![];
    for s in suites {
        let Some(o) = out
            .iter_mut()
            .find(|o| o.tier == s.tier && o.suite == s.suite)
        else {
            out.push(s);
            continue;
        };
        if s.cases.iter().all(|c| c.fullname.is_empty()) {
            o.time += s.time;
            o.cases.extend(s.cases);
        } else {
            for c in s.cases {
                let same = o
                    .cases
                    .iter_mut()
                    .find(|k| !c.fullname.is_empty() && k.fullname == c.fullname);
                match same {
                    Some(k) if c.at >= k.at => *k = c,
                    Some(_) => {}
                    None => o.cases.push(c),
                }
            }
            o.time = o.cases.iter().map(|c| c.time).sum();
        }
        o.settle();
    }
    out
}

/// `name` of an attribute list, unescaped.
fn attr(attrs: &[(String, String)], name: &str) -> String {
    attrs
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

fn unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(semi) = rest.find(';').filter(|&j| j <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..semi];
        let ch = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => ent
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| ent.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match ch {
            Some(c) => {
                out.push(c);
                rest = &rest[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// The attributes of a tag's inside (`name a="1" b='2'`), after the name.
fn attrs_of(s: &str) -> Vec<(String, String)> {
    let mut out = vec![];
    let mut rest = s.trim_start();
    while let Some(eq) = rest.find('=') {
        let key = rest[..eq].trim().to_string();
        let after = rest[eq + 1..].trim_start();
        let Some(q) = after.chars().next().filter(|c| *c == '"' || *c == '\'') else {
            break;
        };
        let body = &after[1..];
        let Some(end) = body.find(q) else { break };
        out.push((key, unescape(&body[..end])));
        rest = body[end + 1..].trim_start();
    }
    out
}

/// The index of the `>` that closes the tag `s` opens, skipping any inside a quoted value.
fn tag_end(s: &str) -> Option<usize> {
    let mut quote = None;
    for (i, c) in s.char_indices() {
        match (quote, c) {
            (None, '"' | '\'') => quote = Some(c),
            (Some(q), c) if c == q => quote = None,
            (None, '>') => return Some(i),
            _ => {}
        }
    }
    None
}

fn clip(mut s: String) -> String {
    let s0 = s.trim().len();
    s.truncate(s0);
    if s.len() > MESSAGE_BYTES {
        let mut cut = MESSAGE_BYTES;
        while !s.is_char_boundary(cut) {
            cut -= 1;
        }
        s.truncate(cut);
        s.push_str("\n...");
    }
    s
}

/// One piece of a document as the scanner sees it.
enum Tok<'a> {
    /// Character data, unescaped; a CDATA section's comes as written.
    Text(String),
    Open {
        name: &'a str,
        attrs: Vec<(String, String)>,
        empty: bool,
    },
    Close(&'a str),
}

/// Walks `xml` piece by piece until `f` returns false. A comment, CDATA section, declaration or
/// tag that never closes is an error, so a truncated download is not read as a short run.
fn scan<'a>(xml: &'a str, mut f: impl FnMut(Tok<'a>) -> bool) -> Result<(), String> {
    let mut rest = xml;
    while let Some(lt) = rest.find('<') {
        if lt > 0 && !f(Tok::Text(unescape(&rest[..lt]))) {
            return Ok(());
        }
        rest = &rest[lt..];
        if let Some(body) = rest.strip_prefix("<!--") {
            let end = body.find("-->").ok_or("a comment never closes")?;
            rest = &body[end + 3..];
            continue;
        }
        if let Some(body) = rest.strip_prefix("<![CDATA[") {
            let end = body.find("]]>").ok_or("a CDATA section never closes")?;
            if !f(Tok::Text(body[..end].to_string())) {
                return Ok(());
            }
            rest = &body[end + 3..];
            continue;
        }
        if rest.starts_with("<?") || rest.starts_with("<!") {
            let end = rest.find('>').ok_or("a declaration never closes")?;
            rest = &rest[end + 1..];
            continue;
        }
        let end = tag_end(&rest[1..]).ok_or("a tag never closes")?;
        let inside = &rest[1..1 + end];
        rest = &rest[end + 2..];
        let tok = if let Some(name) = inside.strip_prefix('/') {
            Tok::Close(name.trim())
        } else {
            let empty = inside.ends_with('/');
            let inside = inside.trim_end_matches('/');
            let (name, attrs) = inside
                .split_once(char::is_whitespace)
                .map_or((inside, ""), |(n, a)| (n, a));
            Tok::Open {
                name,
                attrs: attrs_of(attrs),
                empty,
            }
        };
        if !f(tok) {
            return Ok(());
        }
    }
    Ok(())
}

/// The suites of one results file, each tagged with `tier`: an NUnit file when its root is
/// `test-run`, else a bats JUnit report. An empty report has none.
pub fn parse(xml: &str, tier: &str) -> Result<Vec<Suite>, String> {
    let mut root = "";
    scan(xml, |t| match t {
        Tok::Open { name, .. } => {
            root = name;
            false
        }
        _ => true,
    })?;
    if root == "test-run" {
        parse_nunit(xml, tier)
    } else {
        parse_junit(xml, tier)
    }
}

fn parse_junit(xml: &str, tier: &str) -> Result<Vec<Suite>, String> {
    let mut suites = vec![];
    let mut suite: Option<Suite> = None;
    let mut case: Option<Case> = None;
    let mut detail = false;
    scan(xml, |t| {
        match t {
            Tok::Text(text) => {
                if let (Some(c), true) = (case.as_mut(), detail) {
                    c.message.push_str(&text);
                }
            }
            Tok::Close(name) => match name {
                "testsuite" => {
                    if let Some(mut s) = suite.take() {
                        s.settle();
                        suites.push(s);
                    }
                }
                "testcase" => {
                    if let (Some(c), Some(s)) = (case.take(), suite.as_mut()) {
                        s.cases.push(Case {
                            message: clip(c.message),
                            ..c
                        });
                    }
                }
                "failure" | "error" | "skipped" => detail = false,
                _ => {}
            },
            Tok::Open { name, attrs, empty } => {
                let time = |a: &[(String, String)]| attr(a, "time").parse::<f64>().unwrap_or(0.0);
                match name {
                    "testsuite" => {
                        let mut s = Suite {
                            tier: tier.to_string(),
                            suite: attr(&attrs, "name"),
                            time: time(&attrs),
                            ..Default::default()
                        };
                        if empty {
                            s.settle();
                            suites.push(s);
                        } else {
                            suite = Some(s);
                        }
                    }
                    "testcase" => {
                        let c = Case {
                            name: attr(&attrs, "name"),
                            result: "passed".into(),
                            time: time(&attrs),
                            ..Default::default()
                        };
                        if empty {
                            if let Some(s) = suite.as_mut() {
                                s.cases.push(c);
                            }
                        } else {
                            case = Some(c);
                        }
                    }
                    "failure" | "error" | "skipped" => {
                        if let Some(c) = case.as_mut() {
                            // A skip never hides a failure the same test also reported.
                            if name != "skipped" || c.result != "failed" {
                                c.result = if name == "skipped" {
                                    "skipped"
                                } else {
                                    "failed"
                                }
                                .into();
                            }
                            c.message.push_str(&attr(&attrs, "message"));
                            detail = !empty;
                            if detail && !c.message.is_empty() {
                                c.message.push('\n');
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        true
    })?;
    if suite.is_some() || case.is_some() {
        return Err("the report ends inside a testsuite".into());
    }
    Ok(suites)
}

/// NUnit's result as a test's: Inconclusive is skipped, and Warning passed with a note.
fn nunit_result(r: &str) -> &'static str {
    match r {
        "Passed" | "Warning" => "passed",
        "Failed" => "failed",
        _ => "skipped",
    }
}

/// A test-case being read: the failure's or skip's message and stack trace come in as text
/// under it and are joined when it closes.
struct Open {
    class: String,
    case: Case,
    /// The elements open inside the test-case, to tell its failure's message from its output's.
    path: Vec<String>,
    message: String,
    stack: String,
}

/// The tests of one NUnit results file, one suite per class in the order they first appear. A
/// suite's time is its tests' summed: the file times the classes it ran, not the class.
fn parse_nunit(xml: &str, tier: &str) -> Result<Vec<Suite>, String> {
    let mut at = String::new();
    let mut suites: Vec<Suite> = vec![];
    let mut open: Option<Open> = None;
    let mut put = |class: String, c: Case| match suites.iter_mut().find(|s| s.suite == class) {
        Some(s) => s.cases.push(c),
        None => suites.push(Suite {
            tier: tier.to_string(),
            suite: class,
            cases: vec![c],
            ..Default::default()
        }),
    };
    scan(xml, |t| {
        match (t, open.as_mut()) {
            (
                Tok::Open {
                    name: "test-run",
                    attrs,
                    ..
                },
                _,
            ) => {
                at = attr(&attrs, "start-time");
            }
            (
                Tok::Open {
                    name: "test-case",
                    attrs,
                    empty,
                },
                None,
            ) => {
                let case = Case {
                    name: attr(&attrs, "name"),
                    fullname: attr(&attrs, "fullname"),
                    result: nunit_result(&attr(&attrs, "result")).into(),
                    time: attr(&attrs, "duration").parse().unwrap_or(0.0),
                    message: String::new(),
                    at: at.clone(),
                };
                let class = attr(&attrs, "classname");
                if empty {
                    put(class, case);
                } else {
                    open = Some(Open {
                        class,
                        case,
                        path: vec![],
                        message: String::new(),
                        stack: String::new(),
                    });
                }
            }
            (Tok::Open { name, empty, .. }, Some(o)) if !empty => o.path.push(name.to_string()),
            (Tok::Close("test-case"), Some(_)) => {
                let Open {
                    class,
                    mut case,
                    message,
                    stack,
                    ..
                } = open.take().expect("matched Some");
                let stack: Vec<&str> = stack.trim().lines().take(STACK_LINES).collect();
                let mut text = message.trim().to_string();
                if !stack.is_empty() {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(&stack.join("\n"));
                }
                case.message = clip(text);
                put(class, case);
            }
            (Tok::Close(_), Some(o)) => {
                o.path.pop();
            }
            (Tok::Text(text), Some(o)) => {
                let path: Vec<&str> = o.path.iter().map(String::as_str).collect();
                match path.as_slice() {
                    ["failure" | "reason", "message"] => o.message.push_str(&text),
                    ["failure", "stack-trace"] => o.stack.push_str(&text),
                    _ => {}
                }
            }
            _ => {}
        }
        true
    })?;
    if open.is_some() {
        return Err("the results end inside a test-case".into());
    }
    for s in &mut suites {
        s.time = s.cases.iter().map(|c| c.time).sum();
        s.settle();
    }
    Ok(suites)
}

#[cfg(test)]
mod tests {
    use super::*;

    const REPORT: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="1.5">
<testsuite name="a.bats" tests="4" failures="1" errors="0" skipped="1" time="1.25" timestamp="2026-11-10T00:00:00" hostname="h">
    <testcase classname="a.bats" name="passes &amp; more" time="0.10">
    </testcase>
    <testcase classname="a.bats" name="fails here" time="0.20">
        <failure type="failure">(in test file a.bats, line 2)
  `[ &quot;$x&quot; -gt 1 ]&apos; failed &lt;here&gt;
</failure>
    </testcase>
    <testcase classname="a.bats" name="skipped one" time="0.00">
        <skipped>not on CI</skipped>
    </testcase>
    <testcase classname="a.bats" name="bare" time="0.01"/>
</testsuite>
<testsuite name="b.bats" tests="1" failures="0" errors="0" skipped="0" time="0.5">
    <testcase classname="b.bats" name="ok" time="0.5"></testcase>
</testsuite>
</testsuites>
"#;

    #[test]
    fn a_report_reads_into_suites_with_each_tests_result() {
        let s = parse(REPORT, "unit").unwrap();
        assert_eq!(s.len(), 2);
        let a = &s[0];
        assert_eq!((a.suite.as_str(), a.tier.as_str()), ("a.bats", "unit"));
        assert_eq!((a.tests, a.passed, a.failed, a.skipped), (4, 2, 1, 1));
        assert_eq!((a.state.as_str(), a.level), ("failed", Level::Bad));
        assert_eq!(a.time, 1.25);
        assert_eq!(a.cases[0].name, "passes & more");
        let f = &a.cases[1];
        assert_eq!(f.result, "failed");
        assert!(
            f.message.contains("[ \"$x\" -gt 1 ]' failed <here>"),
            "{}",
            f.message
        );
        assert_eq!(a.cases[2].message, "not on CI");
        assert_eq!(a.cases[3].result, "passed");
        assert_eq!(s[1].state, "passed");
    }

    #[test]
    fn a_message_attribute_and_cdata_are_the_failure_text() {
        let x = r#"<testsuites><testsuite name="t"><testcase name="x"><failure message="a &gt; b"><![CDATA[ <raw> & text ]]></failure></testcase></testsuite></testsuites>"#;
        let s = parse(x, "ui").unwrap();
        assert_eq!(s[0].cases[0].message, "a > b\n <raw> & text".trim());
    }

    #[test]
    fn a_truncated_report_is_an_error_not_a_short_run() {
        let cut = &REPORT[..REPORT.find("fails here").unwrap()];
        assert!(parse(cut, "unit").is_err());
        assert!(parse("<testsuites><testsuite name=\"a\" ", "unit").is_err());
        assert_eq!(parse("<testsuites/>", "unit").unwrap(), vec![]);
    }

    #[test]
    fn a_long_failure_is_clipped() {
        let big = "x".repeat(MESSAGE_BYTES * 2);
        let x = format!(
            "<testsuite name=\"t\"><testcase name=\"x\"><failure>{big}</failure></testcase></testsuite>"
        );
        let m = &parse(&x, "unit").unwrap()[0].cases[0].message;
        assert!(m.len() < MESSAGE_BYTES + 8 && m.ends_with("..."));
    }

    #[test]
    fn the_tier_is_the_first_word_after_the_globs_prefix() {
        let junit = ["junit-*"];
        assert_eq!(tier_of("junit-unit-1", &junit), "unit");
        assert_eq!(tier_of("junit-integ-0", &junit), "integ");
        assert_eq!(tier_of("junit-ui-tmux-3.8", &junit), "ui");
        let unity = ["test-runs-*", "junit-*"];
        assert_eq!(tier_of("test-runs-playmode-3", &unity), "playmode");
        assert_eq!(tier_of("junit-unit-1", &unity), "unit");
        // a name no glob prefixes is its own first word
        assert_eq!(tier_of("editmode-2", &junit), "editmode");
    }

    /// A trimmed Unity results file: one passed, one failed with a message, stack trace and output,
    /// one skipped, one inconclusive, one parameterized.
    const NUNIT: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<test-run id="2" testcasecount="5" result="Failed" total="5" passed="2" failed="1" inconclusive="1" skipped="1" start-time="2026-11-12 12:17:48Z" end-time="2026-11-12 12:31:16Z" duration="20.5">
  <test-suite type="TestSuite" id="5210" name="unity-core-playground" fullname="unity-core-playground" result="Failed">
    <properties>
      <property name="platform" value="PlayMode" />
    </properties>
    <failure>
      <message><![CDATA[One or more child tests had errors]]></message>
    </failure>
    <test-suite type="TestFixture" id="1" name="AI3DPlayTests" fullname="Playground.PlayTests.AI3DPlayTests" classname="Playground.PlayTests.AI3DPlayTests" result="Failed">
      <test-case id="1030" name="ABeastGoesDown" fullname="Playground.PlayTests.AI3DPlayTests.ABeastGoesDown" methodname="ABeastGoesDown" classname="Playground.PlayTests.AI3DPlayTests" runstate="Runnable" seed="1" result="Passed" start-time="2026-11-12 12:17:50Z" end-time="2026-11-12 12:18:03Z" duration="13.25" asserts="0">
        <properties />
        <output><![CDATA[a log line that is not a failure]]></output>
      </test-case>
      <test-case id="1031" name="ABotAims" fullname="Playground.PlayTests.AI3DPlayTests.ABotAims" methodname="ABotAims" classname="Playground.PlayTests.AI3DPlayTests" result="Failed" label="Error" duration="2.5" asserts="0">
        <properties />
        <failure>
          <message><![CDATA[Expected: 3
  But was:  0
]]></message>
          <stack-trace><![CDATA[at Playground.PlayTests.AI3DPlayTests.ABotAims () [0x00000] in AI3DPlayTests.cs:42
at line two
at line three
at line four
at line five
at line six
at line seven
at line eight
at line nine
]]></stack-trace>
        </failure>
        <output><![CDATA[Unity log noise]]></output>
        <assertions>
          <assertion result="Failed"><message><![CDATA[a repeat of the message]]></message></assertion>
        </assertions>
      </test-case>
    </test-suite>
    <test-suite type="TestFixture" id="2" name="YardGamesPlayTests" fullname="Playground.PlayTests.YardGamesPlayTests" result="Passed">
      <test-case id="2001" name="EachGameStandsUpInItsYard(&quot;shapecity.hub&quot;)" fullname="Playground.PlayTests.YardGamesPlayTests.EachGameStandsUpInItsYard(&quot;shapecity.hub&quot;)" classname="Playground.PlayTests.YardGamesPlayTests" result="Passed" duration="4.75" />
      <test-case id="2002" name="SkippedOne" fullname="Playground.PlayTests.YardGamesPlayTests.SkippedOne" classname="Playground.PlayTests.YardGamesPlayTests" result="Skipped" label="Ignored" duration="0">
        <reason>
          <message><![CDATA[not on CI]]></message>
        </reason>
      </test-case>
      <test-case id="2003" name="NotSure" fullname="Playground.PlayTests.YardGamesPlayTests.NotSure" classname="Playground.PlayTests.YardGamesPlayTests" result="Inconclusive" duration="0" />
    </test-suite>
  </test-suite>
</test-run>
"#;

    #[test]
    fn an_nunit_file_reads_one_suite_per_class_with_each_tests_result() {
        let s = parse(NUNIT, "playmode").unwrap();
        let names: Vec<&str> = s.iter().map(|s| s.suite.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "Playground.PlayTests.AI3DPlayTests",
                "Playground.PlayTests.YardGamesPlayTests"
            ]
        );
        let ai = &s[0];
        assert_eq!(ai.tier, "playmode");
        assert_eq!((ai.tests, ai.passed, ai.failed, ai.skipped), (2, 1, 1, 0));
        assert_eq!((ai.state.as_str(), ai.level), ("failed", Level::Bad));
        assert_eq!(ai.time, 15.75);
        assert_eq!(ai.cases[0].message, "", "output is not a failure");
        let f = &ai.cases[1];
        assert_eq!(f.fullname, "Playground.PlayTests.AI3DPlayTests.ABotAims");
        assert!(
            f.message
                .starts_with("Expected: 3\n  But was:  0\nat Playground"),
            "{}",
            f.message
        );
        assert!(
            f.message.ends_with("at line eight"),
            "the trace is cut at STACK_LINES: {}",
            f.message
        );
        assert!(!f.message.contains("noise") && !f.message.contains("repeat"));
        let yard = &s[1];
        assert_eq!((yard.tests, yard.passed, yard.skipped), (3, 1, 2));
        assert_eq!(yard.state, "skipped");
        assert_eq!(
            yard.cases[0].name,
            "EachGameStandsUpInItsYard(\"shapecity.hub\")"
        );
        assert_eq!(yard.cases[1].message, "not on CI");
        assert_eq!(
            yard.cases[2].result, "skipped",
            "inconclusive counts as skipped"
        );
        // the JUnit path is untouched by the format check
        assert_eq!(parse(REPORT, "unit").unwrap().len(), 2);
    }

    #[test]
    fn a_truncated_nunit_file_is_an_error() {
        let cut = &NUNIT[..NUNIT.find("<stack-trace>").unwrap()];
        assert!(parse(cut, "playmode").is_err());
    }

    #[test]
    fn a_test_rerun_in_a_later_file_of_the_tier_is_the_later_result() {
        let run = |at: &str, result: &str| {
            format!(
                r#"<test-run start-time="{at}"><test-case name="t" fullname="C.t" classname="C" result="{result}" duration="2"/><test-case name="{at}" fullname="C.{at}" classname="C" result="Passed" duration="1"/></test-run>"#
            )
        };
        let mut all = parse(&run("2026-11-12 12:30:00Z", "Passed"), "playmode").unwrap();
        all.extend(parse(&run("2026-11-12 12:10:00Z", "Failed"), "playmode").unwrap());
        let m = merged(all);
        assert_eq!(m.len(), 1);
        assert_eq!(
            (m[0].tests, m[0].passed, m[0].failed),
            (3, 3, 0),
            "{:?}",
            m[0].cases
        );
        assert_eq!(m[0].time, 4.0, "the kept tests' time, not both files'");
        let mut all = parse(&run("2026-11-12 12:10:00Z", "Passed"), "playmode").unwrap();
        all.extend(parse(&run("2026-11-12 12:30:00Z", "Failed"), "playmode").unwrap());
        assert_eq!(merged(all)[0].failed, 1);
    }

    #[test]
    fn a_held_failure_is_quarantined_amber_and_not_counted_as_failed() {
        let mut held_suite = suite("playmode", "A", &["passed", "failed"]);
        held_suite.cases[1].fullname = "A.t1".into();
        held_suite.settle();
        let mut red = suite("playmode", "B", &["failed", "failed"]);
        red.cases[0].fullname = "B.t0".into();
        red.cases[1].fullname = "B.t1".into();
        red.settle();
        let loaded = Loaded {
            suites: vec![red, held_suite],
            ..Default::default()
        };
        let held: HashSet<&str> = ["A.t1", "B.t0"].into();
        let q = loaded.quarantined(&held);
        let a = q.suites.iter().find(|s| s.suite == "A").unwrap();
        assert_eq!((a.failed, a.quarantined), (0, 1));
        assert_eq!((a.state.as_str(), a.level), ("quarantined", Level::Warn));
        let b = q.suites.iter().find(|s| s.suite == "B").unwrap();
        assert_eq!(
            (b.failed, b.quarantined, b.state.as_str()),
            (1, 1, "failed")
        );
        assert_eq!(q.suites[0].suite, "B", "a real failure still lists first");
        let t = totals(&q.suites);
        assert_eq!((t.failed, t.quarantined, t.failed_suites), (1, 2, 1));
        assert_eq!(
            t.says(),
            "4 tests in 2 suites: 1 failed, 2 quarantined, 0 skipped, 1 passed"
        );
        let (cases, _, _) = q.cases("playmode", "B", &View::default()).unwrap();
        assert_eq!(cases[0].result, "failed");
        // a quarantined-only run does not fold to "All green"
        let only: Vec<Suite> = vec![a.clone()];
        let plain = View::new::<Suite>("", "", "", "");
        assert!(fold(&plain, only.iter().collect(), &totals(&only))
            .1
            .is_none());
        // negative control: no held names leaves every failure red
        assert_eq!(
            totals(&loaded.quarantined(&HashSet::new()).suites).failed,
            3
        );
    }

    fn suite(tier: &str, name: &str, results: &[&str]) -> Suite {
        let mut s = Suite {
            tier: tier.into(),
            suite: name.into(),
            ..Default::default()
        };
        s.cases = results
            .iter()
            .enumerate()
            .map(|(i, r)| Case {
                name: format!("t{i}"),
                result: r.to_string(),
                ..Default::default()
            })
            .collect();
        s.settle();
        s
    }

    #[test]
    fn the_chips_and_the_tier_dropdown_count_what_they_filter() {
        let rows = vec![
            suite("unit", "a.bats", &["passed", "failed"]),
            suite("unit", "b.bats", &["passed", "skipped"]),
            suite("ui", "c.bats", &["passed"]),
        ];
        let (shown, t) = View::new::<Suite>("tier:ui", "", "", "").summary(&rows);
        assert_eq!(shown.len(), 1);
        let n = |name: &str| t.states.iter().find(|c| c.name == name).map(|c| c.n);
        assert_eq!(
            (
                n("all"),
                n("failed"),
                n("quarantined"),
                n("skipped"),
                n("passed")
            ),
            (Some(1), Some(0), Some(0), Some(0), Some(1))
        );
        let failed = View::new::<Suite>("", "failed", "", "").apply(&rows);
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].suite, "a.bats");
        // a bare word finds the suite holding that test
        assert_eq!(View::new::<Suite>("t1", "", "", "").apply(&rows).len(), 2);
    }

    #[test]
    fn a_suites_result_tiles_count_every_test_past_the_cap() {
        let mut results = vec!["failed"; CASE_ROWS + 10];
        results.extend(["passed"; 5]);
        let mut s = suite("unit", "big.bats", &results);
        s.cases[3].message = "Timed out waiting".into();
        s.cases[CASE_ROWS + 12].fullname = "Ns.Big.Slow".into();
        let got = Loaded {
            suites: vec![s],
            ..Default::default()
        };
        let all = View::new::<Case>("", "", "", "");
        let (cases, t, more) = got.cases("unit", "big.bats", &all).unwrap();
        assert_eq!(
            (cases.len(), more, t.total, t.shown),
            (CASE_ROWS, 15, 315, 315)
        );
        let n = |name: &str| t.states.iter().find(|c| c.name == name).map(|c| c.n);
        assert_eq!((n("failed"), n("passed")), (Some(CASE_ROWS + 10), Some(5)));
        let passed = View::new::<Case>("", "passed", "", "");
        let (cases, _, more) = got.cases("unit", "big.bats", &passed).unwrap();
        assert_eq!((cases.len(), more), (5, 0));
        // a word finds a test by its failure's text or its full name
        let by = |q: &str| {
            got.cases("unit", "big.bats", &View::new::<Case>(q, "", "", ""))
                .unwrap()
                .0
        };
        assert_eq!(by("timed out")[0].name, "t3");
        assert_eq!(by("ns.big")[0].name, format!("t{}", CASE_ROWS + 12));
    }

    #[test]
    fn a_run_with_no_failure_folds_until_asked() {
        let rows = vec![suite("unit", "a.bats", &["passed", "skipped"])];
        let t = totals(&rows);
        let plain = View::new::<Suite>("", "", "", "");
        let (shown, line) = fold(&plain, rows.iter().collect(), &t);
        assert!(shown.is_empty());
        assert_eq!(
            line.as_deref(),
            Some("All green: 2 tests in 1 suite: 0 failed, 1 skipped, 1 passed")
        );
        let chip = View::new::<Suite>("", "passed", "", "");
        assert!(fold(&chip, rows.iter().collect(), &t).1.is_none());
        let red = vec![suite("unit", "a.bats", &["failed"])];
        assert!(fold(&plain, red.iter().collect(), &totals(&red))
            .1
            .is_none());
    }

    const TESTS: &str = ".github/workflows/tests.yml";

    fn registry() -> Registry {
        Registry::parse(
            r#"{"trackers": {"app": {"github": "Org/app", "testWorkflows": [".github/workflows/tests.yml"]},
                "other": {"github": "Org/other"}}}"#,
        )
        .unwrap()
    }

    fn ledger_run(id: u64, attempt: u32, path: &str, state: &str) -> Run {
        Run {
            forge: "github".into(),
            repo: "Org/app".into(),
            id,
            attempt,
            path: path.into(),
            state: state.into(),
            sha: "0123456789".into(),
            ..Default::default()
        }
    }

    #[test]
    fn the_picker_lists_finished_runs_of_the_declared_workflow_once_each() {
        let mut undeclared = ledger_run(6, 1, TESTS, "green");
        undeclared.repo = "Org/other".into();
        let b = Builds {
            rows: vec![
                undeclared,
                ledger_run(5, 1, TESTS, "running"),
                ledger_run(4, 1, TESTS, "red"),
                ledger_run(4, 2, TESTS, "green"),
                ledger_run(3, 1, ".github/workflows/other.yml", "green"),
                ledger_run(2, 1, TESTS, "other"),
                ledger_run(1, 1, TESTS, "green"),
            ],
            ..Default::default()
        };
        let reg = registry();
        let p = pickable(&b, Some(&reg));
        let ids: Vec<(u64, u32)> = p.iter().map(|r| (r.id, r.attempt)).collect();
        assert_eq!(ids, vec![(4, 2), (1, 1)]);
        assert_eq!(p[0].sha, "0123456");
        // negative control: with no registry no repo declares a workflow.
        assert!(pickable(&b, None).is_empty());
    }

    #[test]
    fn each_repo_keeps_its_own_pick_runs_so_a_busy_repo_never_hides_a_quiet_one() {
        let reg = Registry::parse(
            r#"{"trackers": {"app": {"github": "Org/app", "testWorkflows": [".github/workflows/tests.yml"]},
                "quiet": {"github": "Org/quiet", "testWorkflows": [".github/workflows/tests.yml"]}}}"#,
        )
        .unwrap();
        let mut rows: Vec<Run> = (0..PICK_RUNS as u64 + 5)
            .rev()
            .map(|i| ledger_run(100 + i, 1, TESTS, "green"))
            .collect();
        let mut quiet = ledger_run(1, 1, TESTS, "red");
        quiet.repo = "Org/quiet".into();
        rows.push(quiet);
        let p = pickable(
            &Builds {
                rows,
                ..Default::default()
            },
            Some(&reg),
        );
        assert_eq!(repos(&p), ["Org/app", "Org/quiet"]);
        let busy = p.iter().filter(|r| r.repo == "Org/app").count();
        assert_eq!(busy, PICK_RUNS, "the busy repo keeps its newest PICK_RUNS");
        assert_eq!(
            p.last().map(|r| r.id),
            Some(1),
            "the quiet repo's run is still offered"
        );
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("junit-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn pick() -> PickRun {
        PickRun::of(&ledger_run(9, 1, TESTS, "green"))
    }

    #[test]
    fn kept_artifacts_are_read_by_tier_without_asking_github() {
        let cache = scratch("kept");
        let dir = run_dir(&cache, "Org/app", 9, 1, &["junit-*"]);
        for (art, sub, name) in [
            ("junit-unit-0", "unit", "z.bats"),
            ("junit-unit-1", "unit", "a.bats"),
            ("junit-ui-tmux-3.8", "ui", "u.bats"),
        ] {
            std::fs::create_dir_all(dir.join(art).join(sub)).unwrap();
            let x = format!(
                "<testsuites><testsuite name=\"{name}\"><testcase name=\"t\"></testcase></testsuite></testsuites>"
            );
            std::fs::write(dir.join(art).join(sub).join("report.xml"), x).unwrap();
        }
        let got = load(&cache, &pick()).unwrap();
        let names: Vec<(&str, &str)> = got
            .suites
            .iter()
            .map(|s| (s.tier.as_str(), s.suite.as_str()))
            .collect();
        assert_eq!(
            names,
            vec![("ui", "u.bats"), ("unit", "a.bats"), ("unit", "z.bats")]
        );
        assert!(got.errors.is_empty() && got.note.is_none());
        let (cases, _, more) = got.cases("unit", "a.bats", &View::default()).unwrap();
        assert_eq!((cases.len(), more), (1, 0));
        assert!(got.cases("unit", "nope.bats", &View::default()).is_none());
        let _ = std::fs::remove_dir_all(&cache);
    }

    #[test]
    fn a_repos_own_artifacts_are_read_as_nunit_by_the_tier_after_its_glob() {
        let reg = Registry::parse(
            r#"{"trackers": {"ucp": {"github": "Org/app", "testWorkflows": [".github/workflows/tests.yml"],
                "testArtifacts": ["test-runs-*"]}}}"#,
        )
        .unwrap();
        let b = Builds {
            rows: vec![ledger_run(9, 1, TESTS, "red")],
            ..Default::default()
        };
        let run = pickable(&b, Some(&reg)).remove(0);
        assert_eq!(run.artifacts, ["test-runs-*"]);
        assert_eq!(
            pick().globs(),
            ["junit-*"],
            "no registry entry reads junit-*"
        );
        let cache = scratch("nunit");
        // new globs are a new dir: the junit-* download of the same run is never read for them
        assert_ne!(
            run_dir(&cache, "Org/app", 9, 1, &run.globs()),
            run_dir(&cache, "Org/app", 9, 1, &["junit-*"])
        );
        let dir = run_dir(&cache, "Org/app", 9, 1, &run.globs());
        let shard = dir.join("test-runs-playmode-3/20261112T121422Z-PlayMode");
        std::fs::create_dir_all(shard.join("xdg")).unwrap();
        std::fs::write(shard.join("results.xml"), NUNIT).unwrap();
        // Unity's own copy of the same file is not read twice
        std::fs::write(shard.join("xdg/TestResults.xml"), NUNIT).unwrap();
        let got = load(&cache, &run).unwrap();
        let _ = std::fs::remove_dir_all(&cache);
        assert!(got.errors.is_empty(), "{:?}", got.errors);
        let t = totals(&got.suites);
        assert_eq!((t.suites, t.tests, t.failed, t.skipped), (2, 5, 1, 2));
        assert!(got.suites.iter().all(|s| s.tier == "playmode"));
        let held: HashSet<&str> = ["Playground.PlayTests.AI3DPlayTests.ABotAims"].into();
        let t = totals(&got.quarantined(&held).suites);
        assert_eq!((t.failed, t.quarantined, t.failed_suites), (0, 1, 0));
    }

    #[test]
    fn a_run_marked_as_having_no_artifacts_says_why_and_a_bad_report_is_named() {
        let cache = scratch("none");
        let dir = run_dir(&cache, "Org/app", 9, 1, &["junit-*"]);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(NONE_MARK), "").unwrap();
        let got = load(&cache, &pick()).unwrap();
        assert_eq!(got.note, Some(none_note(&["junit-*"])));
        assert!(got.suites.is_empty());
        std::fs::create_dir_all(dir.join("junit-integ-0")).unwrap();
        std::fs::write(
            dir.join("junit-integ-0/report.xml"),
            "<testsuite name=\"x\"",
        )
        .unwrap();
        let got = load(&cache, &pick()).unwrap();
        assert_eq!(got.errors.len(), 1);
        assert!(got.errors[0].starts_with("junit-integ-0: "));
        let _ = std::fs::remove_dir_all(&cache);
    }

    #[test]
    fn two_runs_of_a_dotted_repo_never_share_a_download_dir() {
        let cache = Path::new("/c");
        let a = part_dir(&run_dir(cache, "Kblack0610/.dotfiles", 1, 1, &["junit-*"]));
        let b = part_dir(&run_dir(cache, "Kblack0610/.dotfiles", 2, 1, &["junit-*"]));
        assert_ne!(a, b);
        assert!(a.ends_with("Kblack0610_.dotfiles-1-1.part"));
    }

    #[test]
    fn a_repo_name_that_is_not_owner_slash_name_is_never_passed_to_gh() {
        assert!(safe_repo("Kblack0610/.dotfiles"));
        assert!(safe_repo("Kblack0610/dotfiles"));
        for bad in ["", "a", "a/b/c", "../x", "a/..", "a/ b", "a/b;c", "-r/x"] {
            assert!(!safe_repo(bad), "{bad}");
        }
    }

    #[test]
    fn a_tier_uploaded_twice_lists_each_file_once_with_both_runs_tests() {
        let case = |n: &str, r: &str| Case {
            name: n.into(),
            result: r.into(),
            ..Default::default()
        };
        let one = |r: &str| {
            let mut s = Suite {
                tier: "ui".into(),
                suite: "a.bats".into(),
                time: 1.0,
                cases: vec![case("t", r)],
                ..Default::default()
            };
            s.settle();
            s
        };
        let m = merged(vec![one("passed"), one("failed")]);
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].tests, m[0].failed, m[0].passed), (2, 1, 1));
        assert_eq!(m[0].state, "failed");
        assert_eq!(m[0].time, 2.0);
    }
}
