//! The per-case test ledger: one row per execution of a test case, from every finished run of a
//! repo's declared test workflow, read once from the results artifacts the workflow uploads. The
//! flake score (`hub-cases score`) counts these rows; nothing else reads the artifacts for it.
//! `hub-cases ingest` writes the ledger, from the timer `schedules-sync` runs on.
//!
//! | fact                    | home                                                                  |
//! |-------------------------|-----------------------------------------------------------------------|
//! | which runs              | `junit::all_finished`: the builds ledger's finished runs of a declared workflow |
//! | where a run's results are | the registry's `testArtifacts`; a Unity shard's `test-results-<tier>-<n>` holds `meta.json` and one `results.xml` per run folder |
//! | a case's rows           | `<ledger>/<repo>/<run>-<attempt>.tsv.gz`, `COLUMNS` in order, a `#` header first |
//! | a run that left no rows | beside it: `.infra` (a mass-red run), `.refused` (an artifact the ledger cannot trust), `.none` (no results) |
//! | the ledger's place      | `$HUB_CASES_DIR`, else `<state>/ci/cases`                               |
//!
//! A row is one execution, so a case that ran in a batch and again alone is two rows (`role`), and a
//! `-repeat` run is one row per `repeatIteration`. What is left out is infra, not the test's:
//! - a case that did not pass or fail (skipped, inconclusive, `NOT RUN`, `UNCONFIRMED`: a class
//!   `suite.sh` never ran or never confirmed has no outcome in any `results.xml`);
//! - a case NUnit labels `Cancelled`, and a results file cut short mid-case (read as an error);
//! - a whole run in which more than `MASS_RED_SHARE` of at least `MIN_CLASSES_FOR_SHARE` classes
//!   failed: it is one infra event, the same rule as the playground's `quarantine.py`
//!   (`MAX_FAILED_SHARE`), so one bad night adds no failure to any case.
//!
//! An artifact with no `meta.json` is refused loudly, and never read as a partial answer: its tested
//! SHA is unknown, and a case keyed on the dispatch head would pair the wrong runs. The one
//! exception is a back-fill of runs from before the artifact existed, read from the big
//! `test-runs-*` bundles (`Opts::bundle`): they carry no tested SHA, so their rows say `bundle` in
//! `source` and carry the run's own head.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::Value;

use crate::junit::{self, PickRun};

/// The ledger's columns, in order. A reader skips lines that start with `#`.
pub const COLUMNS: &[&str] = &[
    "run", "attempt", "started", "event", "branch", "sha", "lane", "tier", "shard", "frame_ms",
    "host", "dir", "role", "seed", "source", "class", "fullname", "result", "repeat", "time",
    "message",
];

/// Over this share of a run's classes failed, the run is infra and adds no failure to any case.
/// Read 2026-11-14 with the playground's `quarantine.py` `MAX_FAILED_SHARE`, which this repeats:
/// nightlies fail under 2% of classes, the 11-08 infra night failed 39%. Revisit when a run that
/// is not infra fails over 5%; the cause table's policy block takes both numbers over.
pub const MASS_RED_SHARE: f64 = 0.10;
/// A run of fewer classes is too small for a share to mean anything.
pub const MIN_CLASSES_FOR_SHARE: usize = 20;
/// How long a run's rows are kept after they are written.
pub const KEEP_DAYS: i64 = 90;
/// How far back a timer pass looks for runs not yet read: a pass that missed a day still catches up.
pub const LIVE_DAYS: i64 = 3;
/// How far back `--backfill` reaches by default, the span of the runs ledger.
pub const BACKFILL_DAYS: i64 = 30;
/// A run with no results is marked `.none` only once it started this long ago: its last upload
/// may still be coming.
pub const NONE_SETTLE_SECS: i64 = 4 * 3600;
/// The most runs one pass fetches, newest first, so a backlog drains over passes and one pass
/// never spends the provider's budget or the store's time at a gulp.
pub const PASS_FETCHES: usize = 40;
/// A back-fill reads main's nightly `Tests (all)` runs and the same-SHA proof runs (a title with
/// one of these): the runs that hold the flake evidence, and the only ones whose bundles are worth
/// their size.
pub const PROOF_MARKS: &[&str] = &["all red", "readmit", "flake-hunt", "proof"];
/// The most of a failure's first line kept.
pub const MESSAGE_CHARS: usize = 400;
/// What the gh wrapper prints when a read waits for the reset (`~/.local/bin/gh`): the pass stops.
const DEFERRED: &str = "REST calls left";

/// One execution of one case.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Row {
    pub run: u64,
    pub attempt: u32,
    /// When the run started, unix seconds.
    pub started: i64,
    pub event: String,
    pub branch: String,
    /// The tested commit (`meta.json`); a bundle's rows have the run's 7-character head.
    pub sha: String,
    pub lane: String,
    pub tier: String,
    pub shard: String,
    pub frame_ms: String,
    pub host: String,
    /// The run folder the case ran in (`Logs/test-runs` name).
    pub dir: String,
    /// `batch`, `solo`, `repeat`; empty for a report that has none (bats).
    pub role: String,
    /// The `-randomOrderSeed`, empty when the run set none.
    pub seed: String,
    /// `results` (a `test-results-*` artifact with `meta.json`), `report` (a bats report) or `bundle`.
    pub source: String,
    pub class: String,
    pub fullname: String,
    /// `passed` or `failed`.
    pub result: String,
    pub repeat: Option<u32>,
    pub time: f64,
    /// The failure's first line.
    pub message: String,
}

fn cell(s: &str) -> String {
    s.chars()
        .map(|c| {
            if matches!(c, '\t' | '\n' | '\r') {
                ' '
            } else {
                c
            }
        })
        .collect()
}

impl Row {
    pub fn to_line(&self) -> String {
        let repeat = self.repeat.map(|n| n.to_string()).unwrap_or_default();
        let cells = [
            self.run.to_string(),
            self.attempt.to_string(),
            self.started.to_string(),
            cell(&self.event),
            cell(&self.branch),
            cell(&self.sha),
            cell(&self.lane),
            cell(&self.tier),
            cell(&self.shard),
            cell(&self.frame_ms),
            cell(&self.host),
            cell(&self.dir),
            cell(&self.role),
            cell(&self.seed),
            cell(&self.source),
            cell(&self.class),
            cell(&self.fullname),
            cell(&self.result),
            repeat,
            format!("{:.3}", self.time),
            cell(&self.message),
        ];
        cells.join("\t")
    }

    /// A row from one ledger line; None for a header, a blank or a short line.
    pub fn from_line(line: &str) -> Option<Row> {
        if line.starts_with('#') {
            return None;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != COLUMNS.len() {
            return None;
        }
        let own = |i: usize| c[i].to_string();
        Some(Row {
            run: c[0].parse().ok()?,
            attempt: c[1].parse().ok()?,
            started: c[2].parse().ok()?,
            event: own(3),
            branch: own(4),
            sha: own(5),
            lane: own(6),
            tier: own(7),
            shard: own(8),
            frame_ms: own(9),
            host: own(10),
            dir: own(11),
            role: own(12),
            seed: own(13),
            source: own(14),
            class: own(15),
            fullname: own(16),
            result: own(17),
            repeat: c[18].parse().ok(),
            time: c[19].parse().unwrap_or(0.0),
            message: own(20),
        })
    }
}

/// What reading one run's artifacts came to.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// The run's rows, with what was left out of them.
    Rows(Vec<Row>, Left),
    /// More than `MASS_RED_SHARE` of its classes failed: one infra event, no rows.
    Infra(String),
    /// An artifact the ledger will not read, and why.
    Refused(String),
    /// No results artifact at all.
    None,
}

/// Executions and files read out of a run.
#[derive(Debug, Default, PartialEq, Clone, Copy)]
pub struct Left {
    /// Cases that neither passed nor failed (skipped, inconclusive) or were cancelled.
    pub cases: usize,
    /// Results files cut short or missing, read as nothing.
    pub files: usize,
}

/// The facts of a run every row of it carries.
fn base(run: &PickRun) -> Row {
    Row {
        run: run.id,
        attempt: run.attempt,
        started: run.started,
        event: run.event.clone(),
        branch: run.branch.clone(),
        sha: run.sha.clone(),
        ..Default::default()
    }
}

/// `meta.json`'s value as the text a column holds: a number or a string, empty for null.
fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

/// The rows of one results file, with how many cases it left out; Err when it is cut short.
fn rows_of(xml: &str, tier: &str, at: &Row) -> Result<(Vec<Row>, usize), String> {
    let suites = junit::parse(xml, tier)?;
    let mut left = 0;
    let mut rows = vec![];
    for s in suites {
        for c in s.cases {
            if !matches!(c.result.as_str(), "passed" | "failed") || c.label == "Cancelled" {
                left += 1;
                continue;
            }
            rows.push(Row {
                class: s.suite.clone(),
                fullname: if c.fullname.is_empty() {
                    format!("{}.{}", s.suite, c.name)
                } else {
                    c.fullname.clone()
                },
                result: c.result.clone(),
                repeat: c.repeat,
                time: c.time,
                message: c
                    .message
                    .lines()
                    .next()
                    .unwrap_or("")
                    .chars()
                    .take(MESSAGE_CHARS)
                    .collect(),
                ..at.clone()
            });
        }
    }
    Ok((rows, left))
}

/// A bundle run folder's role: several classes ran in one Unity (a batch), or one (solo), the way
/// `suite.sh` names them.
fn bundle_role(rows: &[Row]) -> &'static str {
    let classes: HashSet<&str> = rows.iter().map(|r| r.class.as_str()).collect();
    if classes.len() > 1 {
        "batch"
    } else {
        "solo"
    }
}

/// A run's classes that failed and its classes: a class failed when its solo run failed, else, with
/// no solo run, when its batch did (`suite.sh`'s summary calls a batch red a solo run cleared a pass).
fn class_share(rows: &[Row]) -> (usize, usize) {
    // class -> (a solo run failed it, a solo run exists, a batch failed it)
    let mut by: HashMap<&str, (bool, bool, bool)> = HashMap::new();
    for r in rows {
        let e = by.entry(r.class.as_str()).or_default();
        let failed = r.result == "failed";
        if r.role == "batch" {
            e.2 |= failed;
        } else {
            e.0 |= failed;
            e.1 = true;
        }
    }
    let failed = by
        .values()
        .filter(
            |(solo_failed, solo, batch_failed)| if *solo { *solo_failed } else { *batch_failed },
        )
        .count();
    (failed, by.len())
}

/// Reads the artifacts in `dir` (one folder per artifact, as `junit::fetched` leaves them) into
/// `run`'s rows. `bundle` allows an artifact with no `meta.json` that holds `results.xml` files
/// (the back-fill of runs from before `meta.json`); otherwise such an artifact is refused.
pub fn load_run(dir: &Path, run: &PickRun, bundle: bool) -> Outcome {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Outcome::Refused(format!("{}: unreadable", dir.display()));
    };
    let mut arts: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    arts.sort();
    if arts.is_empty() {
        return Outcome::None;
    }
    let globs: Vec<&str> = run.artifacts.iter().map(String::as_str).collect();
    let globs = if globs.is_empty() {
        vec![project_map::DEFAULT_TEST_ARTIFACTS]
    } else {
        globs
    };
    let mut rows = vec![];
    let mut left = Left::default();
    for art in arts {
        let name = art
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        let tier = junit::tier_of(&name, &globs);
        let meta_path = art.join("meta.json");
        let at = Row {
            tier: tier.clone(),
            ..base(run)
        };
        if meta_path.is_file() {
            match from_meta(&art, &meta_path, &at, &mut left) {
                Ok(r) => rows.extend(r),
                Err(e) => return Outcome::Refused(format!("{name}: {e}")),
            }
            continue;
        }
        let mut files = vec![];
        junit::reports(&art, 3, &mut files);
        if files.is_empty() {
            continue;
        }
        let nunit = files
            .iter()
            .any(|f| f.file_name().is_some_and(|n| n == "results.xml"));
        if nunit && !bundle {
            return Outcome::Refused(format!(
                "{name}: Unity results with no meta.json, so no tested commit to key them on"
            ));
        }
        for f in files {
            let dirname = f
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .unwrap_or_default()
                .to_string();
            let tier = match dirname.rsplit('-').next() {
                Some("PlayMode") if nunit => "playmode".to_string(),
                Some("EditMode") if nunit => "editmode".to_string(),
                _ => tier.clone(),
            };
            let at = Row {
                tier,
                dir: dirname,
                source: if nunit { "bundle" } else { "report" }.into(),
                ..at.clone()
            };
            match std::fs::read_to_string(&f)
                .map_err(|e| e.to_string())
                .and_then(|x| rows_of(&x, &at.tier, &at))
            {
                Ok((mut r, l)) => {
                    left.cases += l;
                    if nunit {
                        let role = bundle_role(&r);
                        r.iter_mut().for_each(|x| x.role = role.into());
                    }
                    rows.extend(r);
                }
                Err(_) => left.files += 1,
            }
        }
    }
    if rows.is_empty() && left == Left::default() {
        return Outcome::None;
    }
    let (failed, classes) = class_share(&rows);
    if classes >= MIN_CLASSES_FOR_SHARE && failed as f64 / classes as f64 > MASS_RED_SHARE {
        return Outcome::Infra(format!(
            "{failed} of {classes} classes failed ({:.0}%, over {:.0}%)",
            100.0 * failed as f64 / classes as f64,
            100.0 * MASS_RED_SHARE
        ));
    }
    Outcome::Rows(rows, left)
}

/// The rows of a `test-results-*` artifact: each run in its `meta.json`, in the order it ran.
fn from_meta(art: &Path, meta_path: &Path, at: &Row, left: &mut Left) -> Result<Vec<Row>, String> {
    let meta: Value = std::fs::read_to_string(meta_path)
        .map_err(|e| e.to_string())
        .and_then(|t| serde_json::from_str(&t).map_err(|e| format!("meta.json: {e}")))?;
    let sha = text(meta.get("sha"));
    if sha.is_empty() {
        return Err("meta.json names no tested commit".into());
    }
    let mut out = vec![];
    for r in meta
        .get("runs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let dir = text(r.get("dir"));
        if dir.is_empty() || dir.contains(['/', '\\']) || dir == ".." {
            return Err(format!("meta.json run folder {dir:?} is not a folder name"));
        }
        let tier = match text(meta.get("tier")) {
            t if t.is_empty() => at.tier.clone(),
            t => t,
        };
        let row = Row {
            sha: sha.clone(),
            lane: text(meta.get("lane")),
            tier: tier.clone(),
            shard: text(meta.get("shard")),
            frame_ms: text(meta.get("frame_ms")),
            host: text(meta.get("host")),
            dir: dir.clone(),
            role: text(r.get("role")),
            seed: text(r.get("seed")),
            source: "results".into(),
            ..at.clone()
        };
        match std::fs::read_to_string(art.join(&dir).join("results.xml"))
            .map_err(|e| e.to_string())
            .and_then(|x| rows_of(&x, &tier, &row))
        {
            Ok((rows, l)) => {
                left.cases += l;
                out.extend(rows);
            }
            Err(_) => left.files += 1,
        }
    }
    Ok(out)
}

/// Where a repo's rows are kept under the ledger `root`.
pub fn repo_dir(root: &Path, repo: &str) -> PathBuf {
    root.join(repo.replace('/', "_"))
}

fn stem(run: &PickRun) -> String {
    format!("{}-{}", run.id, run.attempt)
}

const MARKS: [&str; 4] = ["tsv.gz", "infra", "refused", "none"];

/// Whether `run` has been read: it has rows or one of the three marks.
pub fn done(root: &Path, run: &PickRun) -> bool {
    let d = repo_dir(root, &run.repo);
    MARKS
        .iter()
        .any(|m| d.join(format!("{}.{m}", stem(run))).exists())
}

/// The ledger's row files of a repo, oldest name first.
pub fn files(root: &Path, repo: &str) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(repo_dir(root, repo))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "gz"))
        .collect();
    v.sort();
    v
}

/// The rows of one ledger file.
pub fn read_file(path: &Path) -> Result<Vec<Row>, String> {
    let out = Command::new("gzip")
        .arg("-dc")
        .arg(path)
        .output()
        .map_err(|e| format!("gzip: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{}: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(Row::from_line)
        .collect())
}

/// Writes `text` gzipped to `path` whole or not at all.
fn gzip_to(path: &Path, text: &str) -> Result<(), String> {
    let mut part = path.file_name().unwrap_or_default().to_os_string();
    part.push(".part");
    let part = path.with_file_name(part);
    let file = std::fs::File::create(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    let mut child = Command::new("gzip")
        .arg("-c")
        .stdin(Stdio::piped())
        .stdout(file)
        .spawn()
        .map_err(|e| format!("gzip: {e}"))?;
    let wrote = child.stdin.take().map(|mut i| i.write_all(text.as_bytes()));
    let status = child.wait().map_err(|e| format!("gzip: {e}"))?;
    if !status.success() || !matches!(wrote, Some(Ok(()))) {
        let _ = std::fs::remove_file(&part);
        return Err(format!("gzip of {} failed", path.display()));
    }
    std::fs::rename(&part, path).map_err(|e| format!("{}: {e}", path.display()))
}

fn write_rows(root: &Path, run: &PickRun, rows: &[Row]) -> Result<(), String> {
    let d = repo_dir(root, &run.repo);
    std::fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    let mut text = format!("#{}\n", COLUMNS.join("\t"));
    for r in rows {
        text.push_str(&r.to_line());
        text.push('\n');
    }
    gzip_to(&d.join(format!("{}.tsv.gz", stem(run))), &text)
}

fn write_mark(root: &Path, run: &PickRun, mark: &str, why: &str) -> Result<(), String> {
    let d = repo_dir(root, &run.repo);
    std::fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    let p = d.join(format!("{}.{mark}", stem(run)));
    std::fs::write(&p, format!("{}\n", cell(why))).map_err(|e| format!("{}: {e}", p.display()))
}

/// What one ingest pass reads.
#[derive(Debug, Clone)]
pub struct Opts {
    /// Only this repo's runs.
    pub repo: Option<String>,
    /// How far back runs are read, days.
    pub days: i64,
    /// Read only the back-fill's runs (`in_backfill`), and fall back to `bundle` for those with no
    /// `testArtifacts` match.
    pub backfill: bool,
    /// The artifact globs of the bundles a back-fill falls back to (`test-runs-*`).
    pub bundle: Vec<String>,
    /// The most runs fetched in the pass.
    pub cap: usize,
    /// When the pass stops starting a run, so a timer's unit never runs past its timeout.
    pub until: Option<std::time::Instant>,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            repo: None,
            days: LIVE_DAYS,
            backfill: false,
            bundle: vec![],
            cap: PASS_FETCHES,
            until: None,
        }
    }
}

/// Whether a back-fill reads `run`: main's nightly or `Tests (all)`, or a same-SHA proof run.
pub fn in_backfill(run: &PickRun) -> bool {
    let title = run.title.to_lowercase();
    let nightly =
        run.branch == "main" && (run.event == "schedule" || title.starts_with("tests (all)"));
    nightly || PROOF_MARKS.iter().any(|m| title.contains(m))
}

/// What a pass did.
#[derive(Debug, Default, PartialEq)]
pub struct Report {
    pub ingested: usize,
    pub rows: usize,
    pub infra: Vec<String>,
    pub refused: Vec<String>,
    pub none: usize,
    pub left: usize,
    pub errors: Vec<String>,
    /// Runs still to read when the cap or the budget stopped the pass.
    pub pending: usize,
    /// The gh wrapper held a read for the budget's reset.
    pub deferred: bool,
    /// The pass ran into `Opts::until`.
    pub timed_out: bool,
    /// Row files dropped past `KEEP_DAYS`.
    pub pruned: usize,
}

impl Report {
    pub fn says(&self) -> String {
        let mut s = format!(
            "hub-cases: {} run(s) ingested ({} rows), {} infra, {} refused, {} with no results, {} case(s) and file(s) left out",
            self.ingested, self.rows, self.infra.len(), self.refused.len(), self.none, self.left
        );
        if self.pending > 0 {
            s.push_str(&format!(", {} run(s) still to read", self.pending));
        }
        if self.deferred {
            s.push_str(" (GitHub budget reserve: stopped until its reset)");
        }
        if self.timed_out {
            s.push_str(" (out of time: the rest next pass)");
        }
        if self.pruned > 0 {
            s.push_str(&format!(", {} old file(s) dropped", self.pruned));
        }
        s
    }
}

/// Reads each of `runs` not yet in the ledger under `root`, newest first, at most `opts.cap` of them.
/// `fetch` gives a run's artifacts on disk, None when it has none. A fetch that fails leaves the
/// run unmarked, so the next pass asks again.
pub fn ingest(
    root: &Path,
    mut runs: Vec<PickRun>,
    opts: &Opts,
    now: i64,
    fetch: &mut dyn FnMut(&PickRun) -> Result<Option<PathBuf>, String>,
) -> Report {
    let mut rep = Report::default();
    let from = now - opts.days * 86400;
    runs.retain(|r| {
        opts.repo.as_ref().is_none_or(|n| *n == r.repo)
            && r.started >= from
            && (!opts.backfill || in_backfill(r))
            && !done(root, r)
    });
    runs.sort_by(|a, b| b.started.cmp(&a.started).then(b.id.cmp(&a.id)));
    rep.pending = runs.len().saturating_sub(opts.cap);
    runs.truncate(opts.cap);
    for (n, run) in runs.iter().enumerate() {
        if opts.until.is_some_and(|t| std::time::Instant::now() >= t) {
            rep.timed_out = true;
            rep.pending += runs.len() - n;
            break;
        }
        let run = run.clone();
        let tag = format!("{} run {}", run.repo, run.id);
        let mut bundle = false;
        let mut got = fetch(&run);
        if matches!(got, Ok(None)) && opts.backfill && !opts.bundle.is_empty() {
            let alt = PickRun {
                artifacts: opts.bundle.clone(),
                ..run.clone()
            };
            bundle = true;
            got = fetch(&alt);
        }
        let dir = match got {
            Ok(d) => d,
            Err(e) if e.contains(DEFERRED) => {
                rep.deferred = true;
                rep.pending += runs.len() - n;
                break;
            }
            Err(e) => {
                rep.errors.push(format!("{tag}: {e}"));
                continue;
            }
        };
        let outcome = dir
            .as_deref()
            .map_or(Outcome::None, |d| load_run(d, &run, bundle));
        let wrote = match outcome {
            Outcome::Rows(rows, left) => {
                rep.ingested += 1;
                rep.rows += rows.len();
                rep.left += left.cases + left.files;
                write_rows(root, &run, &rows)
            }
            Outcome::Infra(why) => {
                rep.infra.push(format!("{tag}: {why}"));
                write_mark(root, &run, "infra", &why)
            }
            Outcome::Refused(why) => {
                rep.refused.push(format!("{tag}: {why}"));
                write_mark(root, &run, "refused", &why)
            }
            Outcome::None if now - run.started >= NONE_SETTLE_SECS => {
                rep.none += 1;
                write_mark(root, &run, "none", "no results artifact")
            }
            Outcome::None => Ok(()),
        };
        if let Err(e) = wrote {
            rep.errors.push(format!("{tag}: {e}"));
        }
    }
    rep.pruned = prune(root, now);
    rep
}

/// Drops the ledger's files (rows and marks) written more than `KEEP_DAYS` ago.
pub fn prune(root: &Path, now: i64) -> usize {
    let cutoff = std::time::UNIX_EPOCH
        + std::time::Duration::from_secs((now - KEEP_DAYS * 86400).max(0) as u64);
    let mut n = 0;
    for repo in std::fs::read_dir(root).into_iter().flatten().flatten() {
        for f in std::fs::read_dir(repo.path())
            .into_iter()
            .flatten()
            .flatten()
        {
            let old = f
                .metadata()
                .and_then(|m| m.modified())
                .is_ok_and(|t| t < cutoff);
            if old && std::fs::remove_file(f.path()).is_ok() {
                n += 1;
            }
        }
    }
    n
}

/// The ledger's place: `$HUB_CASES_DIR`, else `<state>/ci/cases`.
pub fn root() -> PathBuf {
    agent_core::vocab::env_path("HUB_CASES_DIR")
        .unwrap_or_else(|| agent_core::vocab::state_home().join("ci/cases"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hub-cases-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn pick(id: u64) -> PickRun {
        PickRun {
            repo: "o/r".into(),
            id,
            attempt: 1,
            branch: "main".into(),
            sha: "abcdef0".into(),
            title: "Tests (all)".into(),
            state: "green".into(),
            level: crate::releases::Level::Ok,
            started: 1_000_000,
            prs: vec![],
            url: String::new(),
            path: "t.yml".into(),
            event: "schedule".into(),
            rank: 0,
            artifacts: vec!["test-results-*".into()],
            store: None,
        }
    }

    /// An NUnit file of `(class, name, result)` tests; a `Failed` one carries a message.
    fn nunit(cases: &[(&str, &str, &str)]) -> String {
        let mut x = String::from("<test-run start-time=\"2026-11-28 01:00:00Z\">\n");
        for (c, n, r) in cases {
            let body = if *r == "Failed" {
                "<failure><message><![CDATA[Timed out at Host()\nsecond line]]></message></failure>"
            } else {
                ""
            };
            x.push_str(&format!(
                "<test-case name=\"{n}\" fullname=\"{c}.{n}\" classname=\"{c}\" result=\"{r}\" duration=\"0.5\">{body}</test-case>\n"
            ));
        }
        x.push_str("</test-run>\n");
        x
    }

    fn put(art: &Path, dir: &str, xml: &str) {
        std::fs::create_dir_all(art.join(dir)).unwrap();
        std::fs::write(art.join(dir).join("results.xml"), xml).unwrap();
    }

    fn meta(art: &Path, runs: &[(&str, &str)]) {
        let runs: Vec<String> = runs
            .iter()
            .map(|(d, r)| format!("{{\"dir\":\"{d}\",\"role\":\"{r}\",\"platform\":\"PlayMode\",\"seed\":null,\"repeat_iterations\":0}}"))
            .collect();
        let m = format!(
            "{{\"sha\":\"1234567890abcdef\",\"tier\":\"playmode\",\"shard\":\"3\",\"lane\":\"full\",\"frame_ms\":250,\"host\":\"h1\",\"runs\":[{}]}}",
            runs.join(",")
        );
        std::fs::write(art.join("meta.json"), m).unwrap();
    }

    fn rows_of_run(dir: &Path) -> Vec<Row> {
        match load_run(dir, &pick(7), false) {
            Outcome::Rows(r, _) => r,
            o => panic!("not rows: {o:?}"),
        }
    }

    #[test]
    fn a_batch_fail_and_its_solo_pass_are_two_rows_keeping_role_and_run_facts() {
        let d = scratch("roles");
        let art = d.join("test-results-playmode-3");
        put(
            &art,
            "01-PlayMode",
            &nunit(&[("A", "t1", "Failed"), ("B", "t2", "Passed")]),
        );
        put(&art, "02-PlayMode", &nunit(&[("A", "t1", "Passed")]));
        meta(&art, &[("01-PlayMode", "batch"), ("02-PlayMode", "solo")]);
        let rows = rows_of_run(&d);
        let a: Vec<_> = rows.iter().filter(|r| r.fullname == "A.t1").collect();
        assert_eq!(a.len(), 2);
        assert_eq!(
            (a[0].role.as_str(), a[0].result.as_str()),
            ("batch", "failed")
        );
        assert_eq!(
            (a[1].role.as_str(), a[1].result.as_str()),
            ("solo", "passed")
        );
        assert_eq!(
            a[0].sha, "1234567890abcdef",
            "the tested commit, not the run's head"
        );
        assert_eq!(
            (
                a[0].lane.as_str(),
                a[0].frame_ms.as_str(),
                a[0].host.as_str()
            ),
            ("full", "250", "h1")
        );
        assert_eq!(
            a[0].message, "Timed out at Host()",
            "the failure's first line only"
        );
        assert_eq!(a[0].source, "results");
        assert_eq!(a[0].tier, "playmode");
    }

    #[test]
    fn a_skipped_case_a_cancelled_one_and_a_file_cut_short_leave_no_row() {
        let d = scratch("left");
        let art = d.join("test-results-playmode-3");
        let cancelled = "<test-run><test-case name=\"c\" fullname=\"C.c\" classname=\"C\" result=\"Failed\" label=\"Cancelled\" duration=\"1\"/></test-run>";
        put(
            &art,
            "01-PlayMode",
            &nunit(&[("A", "ok", "Passed"), ("A", "skip", "Skipped")]),
        );
        put(&art, "02-PlayMode", cancelled);
        put(
            &art,
            "03-PlayMode",
            "<test-run><test-case name=\"x\" fullname=\"X.x\" classname=\"X\" result=\"Passed\"",
        );
        meta(
            &art,
            &[
                ("01-PlayMode", "solo"),
                ("02-PlayMode", "solo"),
                ("03-PlayMode", "solo"),
            ],
        );
        let Outcome::Rows(rows, left) = load_run(&d, &pick(7), false) else {
            panic!("rows")
        };
        assert_eq!(
            rows.iter().map(|r| r.fullname.as_str()).collect::<Vec<_>>(),
            ["A.ok"]
        );
        assert_eq!(left, Left { cases: 2, files: 1 });
    }

    #[test]
    fn repeat_iterations_are_one_row_each() {
        let d = scratch("repeat");
        let art = d.join("test-results-playmode-3");
        let xml = "<test-run><test-case name=\"t\" fullname=\"A.t\" classname=\"A\" result=\"Passed\" duration=\"1\"><properties><property name=\"repeatIteration\" value=\"0\" /></properties></test-case><test-case name=\"t\" fullname=\"A.t\" classname=\"A\" result=\"Failed\" duration=\"1\"><properties><property name=\"repeatIteration\" value=\"1\" /></properties><failure><message>boom</message></failure></test-case></test-run>";
        put(&art, "01-PlayMode", xml);
        meta(&art, &[("01-PlayMode", "repeat")]);
        let rows = rows_of_run(&d);
        assert_eq!(
            rows.iter()
                .map(|r| (r.repeat, r.result.as_str()))
                .collect::<Vec<_>>(),
            [(Some(0), "passed"), (Some(1), "failed")]
        );
    }

    /// `n` classes, the first `failed` of them failing, as one batch run.
    fn many(n: usize, failed: usize) -> String {
        let cases: Vec<(String, String, &str)> = (0..n)
            .map(|i| {
                (
                    format!("C{i}"),
                    "t".to_string(),
                    if i < failed { "Failed" } else { "Passed" },
                )
            })
            .collect();
        nunit(
            &cases
                .iter()
                .map(|(c, n, r)| (c.as_str(), n.as_str(), *r))
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn a_run_failing_over_the_share_of_its_classes_is_infra_and_adds_no_row() {
        let d = scratch("mass");
        let art = d.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &many(30, 5));
        meta(&art, &[("01-PlayMode", "batch")]);
        assert!(
            matches!(load_run(&d, &pick(7), false), Outcome::Infra(w) if w.contains("5 of 30"))
        );
        // the negative control: the same shape under the share is read
        let ok = scratch("mass-ok");
        let art = ok.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &many(30, 3));
        meta(&art, &[("01-PlayMode", "batch")]);
        assert_eq!(
            rows_of_run(&ok)
                .iter()
                .filter(|r| r.result == "failed")
                .count(),
            3
        );
        // and a run of too few classes has no share
        let small = scratch("mass-small");
        let art = small.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &many(10, 10));
        meta(&art, &[("01-PlayMode", "batch")]);
        assert_eq!(rows_of_run(&small).len(), 10);
    }

    #[test]
    fn a_batch_red_that_its_solo_run_cleared_is_not_a_failed_class() {
        let d = scratch("solo-clears");
        let art = d.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &many(30, 6));
        let solos: Vec<(String, String, &str)> = (0..6)
            .map(|i| (format!("C{i}"), "t".into(), "Passed"))
            .collect();
        put(
            &art,
            "02-PlayMode",
            &nunit(
                &solos
                    .iter()
                    .map(|(c, n, r)| (c.as_str(), n.as_str(), *r))
                    .collect::<Vec<_>>(),
            ),
        );
        meta(&art, &[("01-PlayMode", "batch"), ("02-PlayMode", "solo")]);
        let rows = rows_of_run(&d);
        assert_eq!(
            rows.iter().filter(|r| r.result == "failed").count(),
            6,
            "the batch reds stay rows"
        );
    }

    #[test]
    fn unity_results_with_no_meta_json_are_refused_loudly() {
        let d = scratch("nometa");
        put(
            &d.join("test-results-playmode-3"),
            "01-PlayMode",
            &nunit(&[("A", "t", "Passed")]),
        );
        assert!(
            matches!(load_run(&d, &pick(7), false), Outcome::Refused(w) if w.contains("no meta.json"))
        );
    }

    #[test]
    fn a_meta_json_with_no_sha_or_an_escaping_folder_is_refused() {
        let d = scratch("badmeta");
        let art = d.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &nunit(&[("A", "t", "Passed")]));
        std::fs::write(art.join("meta.json"), "{\"sha\":\"\",\"runs\":[]}").unwrap();
        assert!(
            matches!(load_run(&d, &pick(7), false), Outcome::Refused(w) if w.contains("tested commit"))
        );
        std::fs::write(
            art.join("meta.json"),
            "{\"sha\":\"ab\",\"runs\":[{\"dir\":\"../x\",\"role\":\"solo\"}]}",
        )
        .unwrap();
        assert!(
            matches!(load_run(&d, &pick(7), false), Outcome::Refused(w) if w.contains("not a folder name"))
        );
    }

    #[test]
    fn a_bundle_with_no_meta_json_reads_when_a_back_fill_allows_it_with_roles_from_its_classes() {
        let d = scratch("bundle");
        let art = d.join("test-runs-playmode-3");
        put(
            &art,
            "01-PlayMode",
            &nunit(&[("A", "t", "Passed"), ("B", "t", "Failed")]),
        );
        put(&art, "02-PlayMode", &nunit(&[("B", "t", "Passed")]));
        put(&art, "03-EditMode", &nunit(&[("E", "t", "Passed")]));
        let mut run = pick(7);
        run.artifacts = vec!["test-runs-*".into()];
        let Outcome::Rows(rows, _) = load_run(&d, &run, true) else {
            panic!("rows")
        };
        let by = |f: &str| rows.iter().find(|r| r.fullname == f).unwrap();
        assert_eq!(
            (by("A.t").role.as_str(), by("A.t").source.as_str()),
            ("batch", "bundle")
        );
        assert_eq!(
            rows.iter()
                .filter(|r| r.fullname == "B.t")
                .map(|r| r.role.as_str())
                .collect::<Vec<_>>(),
            ["batch", "solo"]
        );
        assert_eq!(by("E.t").tier, "editmode");
        assert_eq!(
            by("A.t").sha,
            "abcdef0",
            "the run's head: a bundle has no tested commit"
        );
    }

    #[test]
    fn a_bats_report_reads_with_no_meta_json() {
        let d = scratch("bats");
        let art = d.join("junit-unit-1");
        std::fs::create_dir_all(&art).unwrap();
        std::fs::write(art.join("report.xml"), "<testsuites><testsuite name=\"a.bats\" time=\"1\"><testcase classname=\"a.bats\" name=\"ok\" time=\"0.1\"/><testcase classname=\"a.bats\" name=\"bad\" time=\"0.1\"><failure message=\"nope\"/></testcase></testsuite></testsuites>").unwrap();
        let mut run = pick(7);
        run.artifacts = vec![];
        let Outcome::Rows(rows, _) = load_run(&d, &run, false) else {
            panic!("rows")
        };
        assert_eq!(rows.len(), 2);
        assert_eq!(
            (
                rows[1].result.as_str(),
                rows[1].source.as_str(),
                rows[1].tier.as_str()
            ),
            ("failed", "report", "unit")
        );
        assert_eq!(rows[1].fullname, "a.bats.bad");
    }

    #[test]
    fn a_row_survives_a_round_trip_through_the_gzipped_file() {
        let root = scratch("roundtrip");
        let run = pick(9);
        let r = Row {
            run: 9,
            attempt: 1,
            started: 5,
            sha: "s".into(),
            fullname: "A.t".into(),
            class: "A".into(),
            result: "failed".into(),
            repeat: Some(2),
            time: 1.5,
            message: "a\tb\nc".into(),
            ..Default::default()
        };
        write_rows(&root, &run, std::slice::from_ref(&r)).unwrap();
        let back = read_file(&repo_dir(&root, "o/r").join("9-1.tsv.gz")).unwrap();
        assert_eq!(
            back,
            [Row {
                message: "a b c".into(),
                ..r
            }]
        );
        assert!(done(&root, &run));
        assert_eq!(files(&root, "o/r").len(), 1);
    }

    #[test]
    fn a_pass_reads_each_run_once_and_marks_what_leaves_no_rows() {
        let root = scratch("pass-root");
        let src = scratch("pass-src");
        let ok = src.join("1");
        let art = ok.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &nunit(&[("A", "t", "Passed")]));
        meta(&art, &[("01-PlayMode", "solo")]);
        let mass = src.join("2");
        let art = mass.join("test-results-playmode-3");
        put(&art, "01-PlayMode", &many(30, 9));
        meta(&art, &[("01-PlayMode", "batch")]);
        let bad = src.join("3");
        put(
            &bad.join("test-results-playmode-3"),
            "01-PlayMode",
            &nunit(&[("A", "t", "Passed")]),
        );
        let mut runs: Vec<PickRun> = (1..=4).map(pick).collect();
        for (i, r) in runs.iter_mut().enumerate() {
            r.started = 1_000_000 - i as i64; // 1 newest
        }
        let now = 1_000_000 + 10 * 3600;
        let opts = Opts {
            days: 30,
            ..Default::default()
        };
        let mut asked = vec![];
        let mut fetch = |r: &PickRun| -> Result<Option<PathBuf>, String> {
            asked.push(r.id);
            match r.id {
                1..=3 => Ok(Some(src.join(r.id.to_string()))),
                _ => Ok(None),
            }
        };
        let rep = ingest(&root, runs.clone(), &opts, now, &mut fetch);
        assert_eq!((rep.ingested, rep.rows, rep.none), (1, 1, 1));
        assert_eq!((rep.infra.len(), rep.refused.len()), (1, 1));
        assert!(rep.infra[0].contains("9 of 30") && rep.refused[0].contains("no meta.json"));
        // the second pass asks about none of them
        let mut again = vec![];
        let rep2 = ingest(&root, runs, &opts, now, &mut |r| {
            again.push(r.id);
            Ok(None)
        });
        assert!(again.is_empty(), "{again:?}");
        assert_eq!(rep2.ingested, 0);
        assert_eq!(asked, [1, 2, 3, 4]);
    }

    #[test]
    fn a_run_with_no_results_yet_is_asked_again_and_a_fetch_error_is_not_a_mark() {
        let root = scratch("fresh-root");
        let mut run = pick(1);
        run.started = 1_000_000;
        let opts = Opts {
            days: 30,
            ..Default::default()
        };
        let fresh = ingest(
            &root,
            vec![run.clone()],
            &opts,
            1_000_000 + 600,
            &mut |_| Ok(None),
        );
        assert_eq!(fresh.none, 0);
        assert!(!done(&root, &run), "its last upload may still be coming");
        let err = ingest(
            &root,
            vec![run.clone()],
            &opts,
            1_000_000 + 600,
            &mut |_| Err("store down".into()),
        );
        assert_eq!(err.errors.len(), 1);
        assert!(!done(&root, &run));
    }

    #[test]
    fn the_cap_stops_a_pass_and_the_budget_wait_ends_it() {
        let root = scratch("cap-root");
        let mut runs: Vec<PickRun> = (1..=5).map(pick).collect();
        for (i, r) in runs.iter_mut().enumerate() {
            r.started = 1_000_000 - i as i64;
        }
        let now = 1_000_000 + 10 * 3600;
        let opts = Opts {
            days: 30,
            cap: 2,
            ..Default::default()
        };
        let mut asked = vec![];
        let rep = ingest(&root, runs.clone(), &opts, now, &mut |r| {
            asked.push(r.id);
            Ok(None)
        });
        assert_eq!(asked, [1, 2], "newest first");
        assert_eq!(rep.pending, 3);
        let mut n = 0;
        let rep = ingest(
            &scratch("cap-root2"),
            runs,
            &Opts { cap: 5, ..opts },
            now,
            &mut |_| {
                n += 1;
                Err("gh: 400 REST calls left, under the 1000 kept".into())
            },
        );
        assert!(rep.deferred);
        assert_eq!(n, 1, "one deferred read ends the pass");
        assert!(rep.errors.is_empty());
    }

    #[test]
    fn a_back_fill_reads_main_nightlies_and_proof_runs_and_falls_back_to_the_bundle() {
        let mut night = pick(1);
        night.event = "schedule".into();
        let mut proof = pick(2);
        proof.event = "workflow_dispatch".into();
        proof.branch = "fix/x".into();
        proof.title = "Tests (affected, all red, frame 250 ms)".into();
        let mut gate = pick(3);
        gate.event = "workflow_dispatch".into();
        gate.branch = "fix/x".into();
        gate.title = "Tests (affected)".into();
        assert!(in_backfill(&night) && in_backfill(&proof) && !in_backfill(&gate));
        let root = scratch("bf-root");
        let src = scratch("bf-src");
        let art = src.join("test-runs-playmode-3");
        put(&art, "01-PlayMode", &nunit(&[("A", "t", "Passed")]));
        let opts = Opts {
            days: 30,
            backfill: true,
            bundle: vec!["test-runs-*".into()],
            ..Default::default()
        };
        let mut globs = vec![];
        let rep = ingest(
            &root,
            vec![night, proof, gate],
            &opts,
            1_000_000 + 3600,
            &mut |r| {
                globs.push((r.id, r.artifacts.clone()));
                Ok(if r.artifacts == ["test-runs-*"] {
                    Some(src.clone())
                } else {
                    None
                })
            },
        );
        assert_eq!(rep.ingested, 2);
        assert_eq!(
            globs.iter().filter(|(id, _)| *id == 3).count(),
            0,
            "a plain gate run is not back-filled"
        );
        assert_eq!(
            read_file(&repo_dir(&root, "o/r").join("1-1.tsv.gz")).unwrap()[0].source,
            "bundle"
        );
    }
}
