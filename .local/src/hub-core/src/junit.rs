//! Infra's CI Tests section: what each finished run of a repo's declared test workflow said, suite
//! by suite and test by test, from the `junit-*` artifacts the workflow uploads (a tier's shards
//! each upload one). A repo declares its workflows in the registry (`testWorkflows` on its
//! tracker, `project_map::Registry::test_workflows`); a repo that declares none lists no runs.
//! The runs come from the builds ledger; an artifact is fetched with `gh run download` only when
//! its run is read (docs/dashboards.md rule 10) and kept under the hub cache, since a finished
//! run's artifacts never change and GitHub drops them after the workflow's retention.
//!
//! | fact                    | home                                                              |
//! |-------------------------|-------------------------------------------------------------------|
//! | which runs have results | the builds ledger: finished runs of a workflow the repo declares    |
//! | which workflows count   | the registry: `trackers.<repo>.testWorkflows`                      |
//! | a suite or a test       | `<cache>/junit/<repo>-<run>-<attempt>/junit-<tier>-*/**/report.xml` |
//! | the tier                | the artifact's name: `junit-unit-1` is `unit`, `junit-ui-tmux-3.8` is `ui` |
//!
//! The bats JUnit is read by a small scanner here rather than a new XML dependency: the report
//! has `testsuite`, `testcase` and a `failure`, `error` or `skipped` child, nothing else is used.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use project_map::Registry;
use serde::Serialize;

use crate::builds::{Builds, Run};
use crate::releases::Level;
use crate::table::{Row, Val, View};

/// How many runs the picker offers, newest first.
pub const PICK_RUNS: usize = 30;
/// The most of a failure's text kept per test.
pub const MESSAGE_BYTES: usize = 4000;
/// The cap on the suites a surface draws at once.
pub const LIST_ROWS: usize = 100;
/// The cap on the tests of one opened suite.
pub const CASE_ROWS: usize = 300;

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
        }
    }
}

/// The finished runs of each repo's declared test workflows, newest first, one per run id (its
/// latest attempt): a cancelled or skipped run uploaded nothing worth listing. With no registry
/// no repo declares any.
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
    best.into_iter().take(PICK_RUNS).map(PickRun::of).collect()
}

/// One test of a suite.
#[derive(Serialize, Debug, Clone, Default, PartialEq)]
pub struct Case {
    pub name: String,
    /// `passed`, `failed` or `skipped`.
    pub result: String,
    pub time: f64,
    /// The failure's text, or the reason it was skipped.
    pub message: String,
}

/// One bats file of one tier.
#[derive(Serialize, Debug, Clone, Default, PartialEq)]
pub struct Suite {
    pub tier: String,
    pub suite: String,
    pub tests: usize,
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
    pub time: f64,
    /// `failed` when any test failed, else `skipped` when any was, else `passed`.
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
        self.skipped = n("skipped");
        self.passed = n("passed");
        let (state, level) = match (self.failed, self.skipped) {
            (0, 0) => ("passed", Level::Ok),
            (0, _) => ("skipped", Level::Ok),
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
        match self.state.as_str() {
            "failed" => 0,
            "skipped" => 1,
            _ => 2,
        }
    }
}

impl Row for Suite {
    const COLUMNS: &'static [&'static str] = &[
        "state", "tier", "suite", "tests", "failed", "skipped", "time",
    ];
    const STATES: &'static [&'static str] = &["all", "failed", "skipped", "passed"];
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
    pub failed: usize,
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
        t.skipped += s.skipped;
        t.failed_suites += usize::from(s.failed > 0);
        t.time += s.time;
    }
    t
}

impl Totals {
    /// `2915 tests in 98 suites: 3 failed, 12 skipped, 2900 passed`.
    pub fn says(&self) -> String {
        format!(
            "{} test{} in {} suite{}: {} failed, {} skipped, {} passed",
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

/// The rows to draw and the one line a run with no failure folds to (docs/dashboards.md rule 4).
/// Only the plain view folds: any query, chip or sort is the human asking for those rows. The
/// way open is the `passed` chip.
pub fn fold<'a>(view: &View, rows: Vec<&'a Suite>, t: &Totals) -> (Vec<&'a Suite>, Option<String>) {
    if !view.is_default() || t.failed > 0 || rows.is_empty() {
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
    /// The tests of one suite, failed first and then in the report's order, capped at
    /// `CASE_ROWS`; the second value counts the ones the cap left out.
    pub fn cases(&self, tier: &str, suite: &str) -> Option<(Vec<&Case>, usize)> {
        let s = self
            .suites
            .iter()
            .find(|s| s.tier == tier && s.suite == suite)?;
        let rank = |c: &Case| match c.result.as_str() {
            "failed" => 0,
            "skipped" => 1,
            _ => 2,
        };
        let mut cases: Vec<&Case> = s.cases.iter().collect();
        cases.sort_by_key(|c| rank(c));
        let more = cases.len().saturating_sub(CASE_ROWS);
        cases.truncate(CASE_ROWS);
        Some((cases, more))
    }
}

/// Where a run's artifacts are kept.
fn run_dir(cache: &Path, repo: &str, id: u64, attempt: u32) -> PathBuf {
    cache
        .join("junit")
        .join(format!("{}-{id}-{attempt}", repo.replace('/', "_")))
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
const NONE_NOTE: &str = "this run uploaded no junit-* artifact (it ran before the workflow did, or GitHub's retention has dropped them)";

/// Downloads a run's `junit-*` artifacts into its directory, once. A run with none leaves a
/// marker so it is not asked again; any other failure leaves nothing, so the next read retries.
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
        .args(["-p", "junit-*", "-D"])
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

/// The tier an artifact's name says: `junit-unit-1` is `unit`.
pub fn tier_of(artifact: &str) -> String {
    artifact
        .strip_prefix("junit-")
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
        } else if p.file_name().is_some_and(|n| n == "report.xml") {
            out.push(p);
        }
    }
}

/// The results of `run`: downloaded on first read, then read from the kept files. Blocks on `gh`.
pub fn load(cache: &Path, run: &PickRun) -> Result<Loaded, String> {
    let dir = run_dir(cache, &run.repo, run.id, run.attempt);
    fetch(&dir, run)?;
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
        let tier = tier_of(name);
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
            NONE_NOTE.to_string()
        } else {
            "the artifacts hold no test report".to_string()
        });
    }
    out.suites = merged(out.suites);
    out.suites
        .sort_by(|a, b| (a.rank(), &a.tier, &a.suite).cmp(&(b.rank(), &b.tier, &b.suite)));
    Ok(out)
}

/// One suite per (tier, file): a tier uploaded by several artifacts (the tmux versions of the ui
/// tier) runs the same file in each, and the rows, the totals and an opened suite count them as one.
fn merged(suites: Vec<Suite>) -> Vec<Suite> {
    let mut out: Vec<Suite> = vec![];
    for s in suites {
        match out
            .iter_mut()
            .find(|o| o.tier == s.tier && o.suite == s.suite)
        {
            Some(o) => {
                o.time += s.time;
                o.cases.extend(s.cases);
                o.settle();
            }
            None => out.push(s),
        }
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

/// The suites of one bats JUnit report, each tagged with `tier`. An empty report has none; a tag
/// that never closes is an error, so a truncated download is not read as a short run.
pub fn parse(xml: &str, tier: &str) -> Result<Vec<Suite>, String> {
    let mut suites = vec![];
    let mut suite: Option<Suite> = None;
    let mut case: Option<Case> = None;
    let mut detail = false;
    let mut rest = xml;
    let push_text = |case: &mut Option<Case>, detail: bool, text: &str| {
        if let (Some(c), true) = (case.as_mut(), detail) {
            c.message.push_str(text);
        }
    };
    while let Some(lt) = rest.find('<') {
        push_text(&mut case, detail, &unescape(&rest[..lt]));
        rest = &rest[lt..];
        if let Some(body) = rest.strip_prefix("<!--") {
            let end = body.find("-->").ok_or("a comment never closes")?;
            rest = &body[end + 3..];
            continue;
        }
        if let Some(body) = rest.strip_prefix("<![CDATA[") {
            let end = body.find("]]>").ok_or("a CDATA section never closes")?;
            push_text(&mut case, detail, &body[..end]);
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
        if let Some(name) = inside.strip_prefix('/') {
            match name.trim() {
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
            }
            continue;
        }
        let empty = inside.ends_with('/');
        let inside = inside.trim_end_matches('/');
        let (name, attrs) = inside
            .split_once(char::is_whitespace)
            .map_or((inside, ""), |(n, a)| (n, a));
        let attrs = attrs_of(attrs);
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
                    message: String::new(),
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
    if suite.is_some() || case.is_some() {
        return Err("the report ends inside a testsuite".into());
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
    fn the_tier_is_the_artifacts_second_word() {
        assert_eq!(tier_of("junit-unit-1"), "unit");
        assert_eq!(tier_of("junit-integ-0"), "integ");
        assert_eq!(tier_of("junit-ui-tmux-3.8"), "ui");
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
            (n("all"), n("failed"), n("skipped"), n("passed")),
            (Some(1), Some(0), Some(0), Some(1))
        );
        let failed = View::new::<Suite>("", "failed", "", "").apply(&rows);
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].suite, "a.bats");
        // a bare word finds the suite holding that test
        assert_eq!(View::new::<Suite>("t1", "", "", "").apply(&rows).len(), 2);
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
        let dir = run_dir(&cache, "Org/app", 9, 1);
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
        let (cases, more) = got.cases("unit", "a.bats").unwrap();
        assert_eq!((cases.len(), more), (1, 0));
        assert!(got.cases("unit", "nope.bats").is_none());
        let _ = std::fs::remove_dir_all(&cache);
    }

    #[test]
    fn a_run_marked_as_having_no_artifacts_says_why_and_a_bad_report_is_named() {
        let cache = scratch("none");
        let dir = run_dir(&cache, "Org/app", 9, 1);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(NONE_MARK), "").unwrap();
        let got = load(&cache, &pick()).unwrap();
        assert!(got.suites.is_empty() && got.note.as_deref() == Some(NONE_NOTE));
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
        let a = part_dir(&run_dir(cache, "Kblack0610/.dotfiles", 1, 1));
        let b = part_dir(&run_dir(cache, "Kblack0610/.dotfiles", 2, 1));
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
