//! `notes projects --backfill <name> --weekly [--repo <path>]... [--dry-run]`: split the closed
//! record of a project's open version (its agent note's board rows, sheet rows and proof table)
//! into one version per ISO week, numbered by the release rule (`stages.md`, "Versions").
//!
//! A row is dated by its `done:` stamp, else by the first notes commit showing it checked. The
//! current week stays open, and the sheet ends one patch past the last backfilled version. A
//! project with no frozen version starts at a baseline, v0.1.0: the rows nothing dates plus the
//! commits each `--repo` made before the first week, by system. Live sheet and board rows are
//! left alone: they belong to the open version and freeze with its next cut.

use crate::config::Profile;
use crate::epics;
use crate::logging::Logger;
use crate::md;
use crate::project_tasks;
use crate::projects::{self, Bump};
use crate::sheet::V;
use crate::standing;
use anyhow::{bail, Result};
use chrono::{Datelike, NaiveDate};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

/// The agent note sections a backfill splits. Any other section stays with the open version.
const BOARD_ROWS: &str = "Done rows";
const PROOF: &str = "Proof";
const PROOF_HEAD: [&str; 2] = ["| task | proof | when |", "|---|---|---|"];

/// One closed row with the lines indented under it, and the day it closed when known.
#[derive(Clone, Debug)]
struct Block {
    lines: Vec<String>,
    day: Option<NaiveDate>,
}

impl Block {
    fn row(&self) -> &str {
        &self.lines[0]
    }
}

/// An agent note cut into what a backfill moves and what it leaves.
#[derive(Debug, Default)]
struct Note {
    /// Everything above the first `##`.
    head: Vec<String>,
    /// Sections the backfill does not split, in order, heading included.
    kept: Vec<Vec<String>>,
    board: Vec<Block>,
    sheet: Vec<Block>,
    proof: Vec<Block>,
    /// Lines inside a split section that are not rows (prose, a stray table line).
    stray: Vec<(String, Vec<String>)>,
}

impl Note {
    fn rows(&self) -> usize {
        self.board.len() + self.sheet.len() + self.proof.len()
    }
}

/// The day a proof table line names in its last cell (`| task | proof | 2026-08-12 |`).
fn proof_day(line: &str) -> Option<NaiveDate> {
    let cell = line.trim().trim_end_matches('|').rsplit('|').next()?.trim();
    NaiveDate::parse_from_str(cell.get(..10)?, "%Y-%m-%d").ok()
}

/// Group a section's lines into row blocks (a `- [` line and the indented lines under it); the
/// rest is returned as stray lines.
fn blocks(lines: &[String]) -> (Vec<Block>, Vec<String>) {
    let mut out: Vec<Block> = Vec::new();
    let mut stray = Vec::new();
    for l in lines {
        if l.starts_with("- [") {
            out.push(Block {
                lines: vec![l.clone()],
                day: project_tasks::done_on(l),
            });
        } else if !l.trim().is_empty() && l.starts_with([' ', '\t']) && !out.is_empty() {
            out.last_mut().expect("checked").lines.push(l.clone());
        } else if !l.trim().is_empty() {
            stray.push(l.clone());
        }
    }
    (out, stray)
}

fn parse_note(content: &str) -> Note {
    let mut note = Note::default();
    let mut sections: Vec<Vec<String>> = Vec::new();
    for l in content.lines() {
        if l.starts_with("## ") {
            sections.push(vec![l.to_string()]);
        } else if let Some(s) = sections.last_mut() {
            s.push(l.to_string());
        } else {
            note.head.push(l.to_string());
        }
    }
    for s in sections {
        let heading = s[0].trim_start_matches("## ").trim().to_string();
        let body = &s[1..];
        if heading.eq_ignore_ascii_case(PROOF) {
            let mut stray = Vec::new();
            for l in body.iter().filter(|l| !l.trim().is_empty()) {
                let header = PROOF_HEAD
                    .iter()
                    .any(|h| l.replace(' ', "") == h.replace(' ', ""));
                if l.trim_start().starts_with('|') && !header {
                    note.proof.push(Block {
                        lines: vec![l.clone()],
                        day: proof_day(l),
                    });
                } else if !header {
                    stray.push(l.clone());
                }
            }
            if !stray.is_empty() {
                note.stray.push((heading, stray));
            }
        } else if heading.eq_ignore_ascii_case(BOARD_ROWS)
            || heading.eq_ignore_ascii_case(project_tasks::SHEET_DONE_ROWS)
        {
            let (b, stray) = blocks(body);
            if heading.eq_ignore_ascii_case(BOARD_ROWS) {
                note.board.extend(b);
            } else {
                note.sheet.extend(b);
            }
            if !stray.is_empty() {
                note.stray.push((heading, stray));
            }
        } else {
            note.kept.push(s);
        }
    }
    note
}

/// The key a row is known by across edits: its id, else its normalised text.
fn row_key(line: &str) -> String {
    md::row_id(line).unwrap_or_else(|| md::task_key(line))
}

/// Row key -> the first day a notes commit shows it checked on the project's sheet or board.
/// Empty when the project is not in git.
fn checked_days(dir: &Path) -> HashMap<String, NaiveDate> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["log", "-p", "--reverse", "--format=@@T%at", "--"])
        .args(["agent/README.md", "README.md", "tasks.md"])
        .output();
    let Ok(out) = out else {
        return HashMap::new();
    };
    if !out.status.success() {
        return HashMap::new();
    }
    parse_checked_days(&String::from_utf8_lossy(&out.stdout))
}

fn parse_checked_days(log: &str) -> HashMap<String, NaiveDate> {
    let mut first: HashMap<String, NaiveDate> = HashMap::new();
    let mut day = None;
    for l in log.lines() {
        if let Some(t) = l.strip_prefix("@@T") {
            day = t
                .trim()
                .parse::<i64>()
                .ok()
                .and_then(|s| chrono::DateTime::from_timestamp(s, 0))
                .map(|d| d.with_timezone(&chrono::Local).date_naive());
        } else if let (Some(row), Some(d)) = (l.strip_prefix('+'), day) {
            if row.starts_with("- [") && md::is_checked(row) {
                first
                    .entry(row_key(row))
                    .and_modify(|e| *e = (*e).min(d))
                    .or_insert(d);
            }
        }
    }
    first
}

fn monday(d: NaiveDate) -> NaiveDate {
    d - chrono::Duration::days(i64::from(d.weekday().num_days_from_monday()))
}

fn week_label(m: NaiveDate) -> String {
    let w = m.iso_week();
    format!("{}-W{:02}", w.year(), w.week())
}

/// The closed rows of one backfilled version.
#[derive(Debug, Default)]
struct Bucket {
    board: Vec<Block>,
    sheet: Vec<Block>,
    proof: Vec<Block>,
}

impl Bucket {
    fn rows(&self) -> usize {
        self.board.len() + self.sheet.len() + self.proof.len()
    }

    /// The closed task rows, both lanes: what makes a week a version. A proof line only
    /// evidences one.
    fn tasks(&self) -> usize {
        self.board.len() + self.sheet.len()
    }

    fn task_rows(&self) -> impl Iterator<Item = &str> {
        self.board.iter().chain(&self.sheet).map(Block::row)
    }

    /// The feature epic closed on proof in this bucket, which makes it a minor.
    fn feature(&self) -> Option<String> {
        self.task_rows()
            .filter(|l| epics::is_epic(l) && !md::is_dropped(l))
            .filter(|l| epics::proves_outcome(&epics::proof_of(l)))
            .find_map(|l| {
                let system = projects::row_type_area(l)
                    .map(|(_, a)| a)
                    .unwrap_or_default();
                let title = projects::row_title(l);
                (!standing::is_standing(&system, &title)).then_some(title)
            })
    }
}

/// One version the backfill writes.
#[derive(Debug)]
struct Cut {
    version: V,
    /// The week it covers, by its Monday; `None` for the baseline.
    week: Option<NaiveDate>,
    rows: Bucket,
    /// For the baseline: commits before the first week, per repo, as `(repo, system counts)`.
    commits: Vec<(String, BTreeMap<String, usize>)>,
    feature: Option<String>,
}

impl Cut {
    /// The epoch that bounds this version's work, the `rolled:` stamp `last_cut` reads: the
    /// last second of its week, or of the day before `first` for the baseline.
    fn rolled(&self, first: NaiveDate) -> i64 {
        let end =
            self.week.unwrap_or(first - chrono::Duration::days(7)) + chrono::Duration::days(7);
        end.and_hms_opt(0, 0, 0)
            .and_then(|t| t.and_local_timezone(chrono::Local).earliest())
            .map_or(0, |t| t.timestamp() - 1)
    }

    fn label(&self, first: NaiveDate) -> String {
        match self.week {
            Some(m) => format!(
                "{} ({} to {})",
                week_label(m),
                m,
                m + chrono::Duration::days(6)
            ),
            None => format!("baseline (before {first})"),
        }
    }
}

/// What a backfill would write, computed without touching the disk.
#[derive(Debug)]
struct Plan {
    cuts: Vec<Cut>,
    /// The open version after the backfill.
    open: V,
    /// The rows that stay with the open version (this week's).
    left: Bucket,
    total: usize,
}

/// Split `note`'s rows by week into versions. `cur` is the open version, `frozen` whether the
/// project already has a frozen version (no baseline then), `today` decides the current week.
fn plan(
    mut note_rows: Bucket,
    cur: V,
    frozen: bool,
    commits: &dyn Fn(NaiveDate) -> Vec<(String, BTreeMap<String, usize>)>,
    today: NaiveDate,
) -> Plan {
    let total = note_rows.rows();
    let this_week = monday(today);
    let mut weeks: BTreeMap<NaiveDate, Bucket> = BTreeMap::new();
    let mut undated = Bucket::default();
    let mut left = Bucket::default();
    let mut sort = |blocks: Vec<Block>, pick: fn(&mut Bucket) -> &mut Vec<Block>| {
        for b in blocks {
            match b.day.map(monday) {
                Some(m) if m >= this_week => pick(&mut left).push(b),
                Some(m) => pick(weeks.entry(m).or_default()).push(b),
                None => pick(&mut undated).push(b),
            }
        }
    };
    sort(std::mem::take(&mut note_rows.board), |b| &mut b.board);
    sort(std::mem::take(&mut note_rows.sheet), |b| &mut b.sheet);
    sort(std::mem::take(&mut note_rows.proof), |b| &mut b.proof);

    let mut weeks = fold_proof_only(weeks.into_iter().collect(), &mut undated);
    let first = weeks.first().map_or(this_week, |(m, _)| *m);
    let mut cuts: Vec<Cut> = Vec::new();
    if frozen {
        // The undated rows are the oldest, so they ride with the first week cut.
        if let Some((_, b)) = weeks.first_mut() {
            b.board.append(&mut undated.board);
            b.sheet.append(&mut undated.sheet);
            b.proof.append(&mut undated.proof);
        } else if undated.rows() > 0 {
            weeks.push((
                monday(first - chrono::Duration::days(7)),
                std::mem::take(&mut undated),
            ));
        }
    } else {
        let before = commits(first);
        if undated.rows() > 0 || before.iter().any(|(_, c)| !c.is_empty()) {
            cuts.push(Cut {
                version: (0, 1, 0),
                week: None,
                feature: undated.feature(),
                rows: std::mem::take(&mut undated),
                commits: before,
            });
        }
    }
    for (m, rows) in weeks {
        let feature = rows.feature();
        let version = match cuts.last() {
            None if frozen => cur,
            None => (0, 1, 0),
            Some(prev) => projects::next_version(
                Some(prev.version),
                if feature.is_some() {
                    Bump::Minor
                } else {
                    Bump::Patch
                },
            ),
        };
        cuts.push(Cut {
            version,
            week: Some(m),
            rows,
            commits: Vec::new(),
            feature,
        });
    }
    let open = cuts.last().map_or(cur, |c| {
        projects::next_version(Some(c.version), Bump::Patch)
    });
    Plan {
        cuts,
        open,
        left,
        total,
    }
}

/// A week with proof lines but no closed row cuts nothing: its lines join the next week that
/// has rows, else the last one, else the undated rows.
fn fold_proof_only(weeks: Vec<(NaiveDate, Bucket)>, undated: &mut Bucket) -> Vec<(NaiveDate, Bucket)> {
    let mut out: Vec<(NaiveDate, Bucket)> = Vec::new();
    let mut waiting: Vec<Block> = Vec::new();
    for (m, mut b) in weeks {
        if b.tasks() == 0 {
            waiting.append(&mut b.proof);
            continue;
        }
        b.proof.splice(0..0, waiting.drain(..));
        out.push((m, b));
    }
    match out.last_mut() {
        Some((_, b)) => b.proof.append(&mut waiting),
        None => undated.proof.append(&mut waiting),
    }
    out
}

/// The system an area names: its system id when the project lists one, else `other`, so a
/// summary reads in the project's own systems rather than every word a row or commit used.
fn system_for(systems: &[standing::System], area: &str) -> String {
    standing::system_of(systems, area).map_or_else(|| "other".to_string(), str::to_string)
}

/// Commits before `first` in `repo`, counted by the system their conventional-commit scope
/// names (`feat(notes): x` -> notes); a subject with no scope, or one naming no system of the
/// project, counts under `other`.
fn commits_before(
    repo: &Path,
    first: NaiveDate,
    systems: &[standing::System],
) -> Result<BTreeMap<String, usize>> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["log", "--no-merges", "--format=%s"])
        .arg(format!("--before={first}T00:00:00"))
        .output()?;
    if !out.status.success() {
        bail!(
            "git log in {}: {}",
            repo.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(count_scopes(&String::from_utf8_lossy(&out.stdout), systems))
}

fn count_scopes(subjects: &str, systems: &[standing::System]) -> BTreeMap<String, usize> {
    let mut by: BTreeMap<String, usize> = BTreeMap::new();
    for s in subjects.lines().filter(|s| !s.trim().is_empty()) {
        let area = s
            .split_once('(')
            .filter(|(ty, _)| ty.bytes().all(|b| b.is_ascii_lowercase()))
            .and_then(|(_, rest)| rest.split_once(')'))
            .map(|(a, _)| {
                a.split([',', '/'])
                    .next()
                    .unwrap_or(a)
                    .trim()
                    .to_lowercase()
            })
            .filter(|a| projects::is_area(a));
        let key = area.map_or_else(|| "other".to_string(), |a| system_for(systems, &a));
        *by.entry(key).or_default() += 1;
    }
    by
}

/// `## Shipped`: the version's rows counted by system, then by epic under it, then the commits
/// a baseline summarises.
fn shipped(
    cut: &Cut,
    first: NaiveDate,
    systems: &[standing::System],
    epics_by_id: &HashMap<String, String>,
) -> String {
    let mut s = format!(
        "## Shipped\n\nBackfilled for {}: {} closed rows, {} proof lines.\n",
        cut.label(first),
        cut.rows.tasks(),
        cut.rows.proof.len()
    );
    if let Some(f) = &cut.feature {
        s.push_str(&format!("Minor: a feature closed on proof: {f}.\n"));
    }
    let mut by: BTreeMap<String, BTreeMap<String, usize>> = BTreeMap::new();
    for l in cut.rows.task_rows().filter(|l| !md::is_dropped(l)) {
        let system = projects::row_type_area(l)
            .map_or_else(|| "untyped".to_string(), |(_, a)| system_for(systems, &a));
        let epic = epics::parent_of(l)
            .map(|id| epics_by_id.get(&id).cloned().unwrap_or(id))
            .unwrap_or_else(|| "no epic".to_string());
        *by.entry(system).or_default().entry(epic).or_default() += 1;
    }
    for (system, epics) in &by {
        let n: usize = epics.values().sum();
        s.push_str(&format!("\n### {system} ({n})\n"));
        for (epic, k) in epics {
            s.push_str(&format!("- {epic}: {k}\n"));
        }
    }
    for (repo, counts) in &cut.commits {
        let n: usize = counts.values().sum();
        s.push_str(&format!("\n### Commits before {first} in {repo} ({n})\n"));
        let mut rows: Vec<(&String, &usize)> = counts.iter().collect();
        rows.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        for (system, k) in rows {
            s.push_str(&format!("- {system}: {k}\n"));
        }
    }
    s
}

fn lines_of(blocks: &[Block]) -> String {
    blocks
        .iter()
        .flat_map(|b| b.lines.iter())
        .map(|l| format!("{}\n", l.trim_end()))
        .collect()
}

/// The frozen human note for one cut: the sheet rows under `## Tasks`, `## Shipped`, the PRs and
/// the `rolled:` stamp, the same shape `projects --release` freezes.
fn human_note(title: &str, cut: &Cut, shipped: &str, rolled: i64) -> String {
    let prs = projects::prs_section(cut.rows.task_rows());
    format!(
        "{title}\nVersion: {}\n\n## {}\n{}\n{shipped}{prs}\n<!-- rolled: {rolled} -->\n",
        projects::fmt_version(cut.version),
        crate::sheet::TASKS,
        lines_of(&cut.rows.sheet),
    )
}

/// The agent note for one cut: its proof rows and its board rows.
fn agent_note(name: &str, cut: &Cut) -> String {
    let mut s = format!(
        "# {name} {} - agent notes\n\nWhat the agents did for this version, split by week from the open version's note by `notes projects --backfill`.\n",
        projects::fmt_version(cut.version)
    );
    if !cut.rows.proof.is_empty() {
        s.push_str(&format!(
            "\n## {PROOF}\n{}\n{}\n",
            PROOF_HEAD[0], PROOF_HEAD[1]
        ));
        s.push_str(&lines_of(&cut.rows.proof));
    }
    s.push_str("\n## Notes\n");
    if !cut.rows.board.is_empty() {
        s.push_str(&format!("\n## {BOARD_ROWS}\n{}", lines_of(&cut.rows.board)));
    }
    s
}

/// The open version's note after the backfill: its head (retitled), the sections it keeps, and
/// this week's rows.
fn open_note(note: &Note, cur: V, open: V, left: &Bucket) -> String {
    let mut s: String = note
        .head
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let l = if i == 0 {
                l.replacen(&projects::fmt_version(cur), &projects::fmt_version(open), 1)
            } else {
                l.clone()
            };
            format!("{l}\n")
        })
        .collect();
    let stray = |h: &str| -> String {
        note.stray
            .iter()
            .filter(|(s, _)| s.eq_ignore_ascii_case(h))
            .flat_map(|(_, l)| l.iter())
            .map(|l| format!("{l}\n"))
            .collect()
    };
    if !left.proof.is_empty() || !stray(PROOF).is_empty() {
        s.push_str(&format!(
            "## {PROOF}\n{}\n{}\n",
            PROOF_HEAD[0], PROOF_HEAD[1]
        ));
        s.push_str(&lines_of(&left.proof));
        s.push_str(&stray(PROOF));
        s.push('\n');
    }
    for sec in &note.kept {
        for l in sec {
            s.push_str(l);
            s.push('\n');
        }
    }
    for (h, rows) in [
        (BOARD_ROWS, &left.board),
        (project_tasks::SHEET_DONE_ROWS, &left.sheet),
    ] {
        let st = stray(h);
        if !rows.is_empty() || !st.is_empty() {
            if !s.ends_with("\n\n") {
                s.push('\n');
            }
            s.push_str(&format!("## {h}\n{}{st}", lines_of(rows)));
        }
    }
    format!("{}\n", s.trim_end())
}

/// Epic id -> its title, over the project's sheet, board and notes, so `## Shipped` names an
/// epic rather than its id.
fn epic_titles(dir: &Path) -> HashMap<String, String> {
    let mut texts: Vec<String> = Vec::new();
    for lane in [dir.to_path_buf(), projects::agent_dir(dir)] {
        for f in ["README.md", "tasks.md"] {
            texts.extend(fs::read_to_string(lane.join(f)));
        }
        for (_, p) in projects::version_notes(&lane.join("versions")) {
            texts.extend(fs::read_to_string(p));
        }
    }
    texts
        .iter()
        .flat_map(|t| t.lines())
        .filter(|l| l.starts_with("- [") && epics::is_epic(l))
        .filter_map(|l| Some((md::row_id(l)?, projects::row_title(l))))
        .collect()
}

/// `content` with the head `Version:` line naming `open`, its tags kept.
fn set_version(content: &str, open: V) -> String {
    let mut in_head = true;
    let mut done = false;
    let lines: Vec<String> = content
        .lines()
        .map(|l| {
            in_head &= !l.trim_start().starts_with("## ");
            match l.trim_start().strip_prefix("Version:") {
                Some(rest) if in_head && !done => {
                    done = true;
                    let tags = rest
                        .trim()
                        .split_once(char::is_whitespace)
                        .map_or("", |(_, t)| t.trim());
                    let v = projects::fmt_version(open);
                    if tags.is_empty() {
                        format!("Version: {v}")
                    } else {
                        format!("Version: {v} {tags}")
                    }
                }
                _ => l.to_string(),
            }
        })
        .collect();
    format!("{}\n", lines.join("\n"))
}

/// `notes projects --backfill <name> --weekly`. Exits 0 when there is nothing to split, and
/// refuses before writing anything when a target note exists or the rows do not add up.
pub fn backfill(
    p: &Profile,
    log: &Logger,
    name: &str,
    repos: &[PathBuf],
    dry_run: bool,
) -> Result<()> {
    let dir = projects::project_dir(p, name)?;
    let Some(sheet_path) = projects::sheet_path(&dir) else {
        bail!("{name} has no working sheet (no README.md with a `Version: vX.Y.Z` line)");
    };
    let sheet = fs::read_to_string(&sheet_path)?;
    let Some(cur) = projects::sheet_version(&sheet) else {
        bail!("no `Version: vX.Y.Z` line on {}", sheet_path.display());
    };
    let cur_s = projects::fmt_version(cur);
    let note_path = projects::agent_note_path(&dir, &cur_s);
    let Ok(note_text) = fs::read_to_string(&note_path) else {
        println!(
            "{name}: no agent note for {cur_s} ({}), nothing to backfill",
            note_path.display()
        );
        return Ok(());
    };
    let note = parse_note(&note_text);
    let history = checked_days(&dir);
    let date = |mut b: Block| {
        b.day = b.day.or_else(|| history.get(&row_key(b.row())).copied());
        b
    };
    let rows = Bucket {
        board: note.board.iter().cloned().map(date).collect(),
        sheet: note.sheet.iter().cloned().map(date).collect(),
        proof: note.proof.clone(),
    };
    let frozen = !projects::version_notes(&dir.join("versions")).is_empty();
    let systems = standing::list(standing::SYSTEMS_BIN, name).unwrap_or_default();
    if frozen && !repos.is_empty() {
        println!("{name} already has a frozen version, so there is no baseline: --repo ignored");
    }
    let failed: std::cell::RefCell<Option<anyhow::Error>> = std::cell::RefCell::default();
    let commits = |first: NaiveDate| {
        repos
            .iter()
            .filter_map(|r| match commits_before(r, first, &systems) {
                Ok(c) => Some((r.display().to_string(), c)),
                Err(e) => {
                    failed.borrow_mut().get_or_insert(e);
                    None
                }
            })
            .collect::<Vec<_>>()
    };
    let today = chrono::Local::now().date_naive();
    let plan = plan(rows, cur, frozen, &commits, today);
    if let Some(e) = failed.into_inner() {
        return Err(e);
    }
    let first = plan
        .cuts
        .iter()
        .find_map(|c| c.week)
        .unwrap_or_else(|| monday(today));

    let written: usize = plan.cuts.iter().map(|c| c.rows.rows()).sum::<usize>() + plan.left.rows();
    if written != plan.total || plan.total != note.rows() {
        bail!(
            "rows do not add up: {written} placed of {} in {}; nothing written",
            note.rows(),
            note_path.display()
        );
    }
    println!(
        "{name}: {} rows in {} -> {} versions, {} rows stay open at {}",
        plan.total,
        note_path.display(),
        plan.cuts.len(),
        plan.left.rows(),
        projects::fmt_version(plan.open)
    );
    for c in &plan.cuts {
        let why = c
            .feature
            .as_deref()
            .map_or(String::new(), |f| format!("  minor: {f}"));
        let commits: usize = c.commits.iter().flat_map(|(_, m)| m.values()).sum();
        let commits = if commits > 0 {
            format!(", {commits} commits")
        } else {
            String::new()
        };
        println!(
            "  {}  {}  {} rows (board {}, sheet {}, proof {}){commits}{why}",
            projects::fmt_version(c.version),
            c.label(first),
            c.rows.rows(),
            c.rows.board.len(),
            c.rows.sheet.len(),
            c.rows.proof.len()
        );
    }
    let tasks: usize = plan.cuts.iter().map(|c| c.rows.tasks()).sum();
    println!(
        "  closed rows: {tasks} backfilled + {} open = {} in {} (and {} proof lines)",
        plan.left.tasks(),
        note.board.len() + note.sheet.len(),
        note_path.display(),
        note.proof.len()
    );
    if plan.cuts.is_empty() {
        println!("{name}: nothing before this week to backfill");
        return Ok(());
    }

    // Refuse before writing anything: a frozen note is never overwritten. The open note is the
    // one file rewritten, so its path may be a target.
    let human = dir.join("versions");
    let targets: Vec<(PathBuf, PathBuf)> = plan
        .cuts
        .iter()
        .map(|c| {
            let v = projects::fmt_version(c.version);
            (
                human.join(format!("{v}.md")),
                projects::agent_note_path(&dir, &v),
            )
        })
        .collect();
    let open_s = projects::fmt_version(plan.open);
    let open_path = projects::agent_note_path(&dir, &open_s);
    for path in targets
        .iter()
        .flat_map(|(h, a)| [h, a])
        .chain([&open_path])
        .filter(|p| **p != note_path)
    {
        if path.exists() {
            bail!(
                "{} already exists - refusing to overwrite a frozen version",
                path.display()
            );
        }
    }
    if dry_run {
        println!("--dry-run: nothing written");
        return Ok(());
    }

    let title = sheet.lines().next().unwrap_or("# project").to_string();
    let titles = epic_titles(&dir);
    fs::create_dir_all(&human)?;
    // The frozen notes first, then the open note, then the sheet: a failure in between leaves
    // rows in two notes, never in none.
    for (c, (h, a)) in plan.cuts.iter().zip(&targets) {
        let shipped = shipped(c, first, &systems, &titles);
        md::write_atomic(h, &human_note(&title, c, &shipped, c.rolled(first)))?;
        md::write_atomic(a, &agent_note(name, c))?;
    }
    md::write_atomic(&open_path, &open_note(&note, cur, plan.open, &plan.left))?;
    if open_path != note_path && !targets.iter().any(|(_, a)| *a == note_path) {
        fs::remove_file(&note_path)?;
    }
    md::write_atomic(&sheet_path, &set_version(&sheet, plan.open))?;
    let msg = format!(
        "{name} backfilled {} versions, {cur_s} -> {open_s} ({} rows)",
        plan.cuts.len(),
        plan.total - plan.left.rows()
    );
    log.info("projects", &msg);
    println!("{msg}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn row(text: &str, day: Option<&str>) -> Block {
        Block {
            lines: vec![format!("- [x] {text}")],
            day: day.map(d),
        }
    }

    fn none(_: NaiveDate) -> Vec<(String, BTreeMap<String, usize>)> {
        Vec::new()
    }

    const NOTE: &str = "# p v0.0.1 - AI notes\n\nintro\n\n## Proof\n| task | proof | when |\n|---|---|---|\n| a | pr:1 | 2026-08-04 |\n| b | pr:2 | 2026-11-10 |\n\n## Notes\nlog line\n\n## Done rows\n- [x] feat(notes): one <!-- id:ar-1 done:2026-08-05 -->\n  detail\n- [x] fix(views): two <!-- id:ar-2 -->\n\n## Sheet done rows\n- [x] feat(notes): three <!-- done:2026-08-20 -->\n";

    #[test]
    fn a_note_splits_into_rows_and_kept_sections() {
        let n = parse_note(NOTE);
        assert_eq!(n.board.len(), 2);
        assert_eq!(
            n.board[0].lines.len(),
            2,
            "the indented detail rides with its row"
        );
        assert_eq!(n.sheet.len(), 1);
        assert_eq!(n.proof.len(), 2);
        assert_eq!(n.proof[0].day, Some(d("2026-08-04")));
        assert_eq!(n.kept.len(), 1, "Notes is kept whole");
        assert_eq!(n.rows(), 5);
    }

    #[test]
    fn history_dates_a_row_by_the_first_commit_that_shows_it_checked() {
        let log = "@@T1754300000\n+- [ ] fix(views): two <!-- id:ar-2 -->\n@@T1754900000\n+- [x] fix(views): two <!-- id:ar-2 -->\n@@T1755900000\n+- [x] fix(views): two #high <!-- id:ar-2 -->\n";
        let days = parse_checked_days(log);
        let want = chrono::DateTime::from_timestamp(1_754_900_000, 0)
            .unwrap()
            .with_timezone(&chrono::Local)
            .date_naive();
        assert_eq!(days.get("ar-2"), Some(&want));
    }

    #[test]
    fn weeks_become_versions_and_this_week_stays_open() {
        let rows = Bucket {
            board: vec![
                row("feat(notes): a <!-- id:ar-1 -->", Some("2026-08-04")),
                row("feat(notes): b <!-- id:ar-2 -->", Some("2026-08-06")),
                row("fix(views): c <!-- id:ar-3 -->", Some("2026-08-20")),
                row("fix(views): d <!-- id:ar-4 -->", Some("2026-11-10")),
            ],
            sheet: vec![row("feat(notes): e", None)],
            proof: vec![],
        };
        let p = plan(rows, (0, 0, 1), false, &none, d("2026-11-11"));
        let got: Vec<_> = p
            .cuts
            .iter()
            .map(|c| (c.version, c.week, c.rows.rows()))
            .collect();
        assert_eq!(
            got,
            vec![
                ((0, 1, 0), None, 1),
                ((0, 1, 1), Some(d("2026-08-03")), 2),
                ((0, 1, 2), Some(d("2026-08-17")), 1),
            ],
            "a week with no rows cuts nothing; the undated row is the baseline"
        );
        assert_eq!(p.left.rows(), 1);
        assert_eq!(p.open, (0, 1, 3));
        assert_eq!(p.total, 5);
    }

    #[test]
    fn a_week_that_closes_a_feature_on_proof_is_a_minor() {
        let rows = Bucket {
            board: vec![
                row("feat(notes): a", Some("2026-08-04")),
                row("epic(notes): search that works <!-- id:ar-9 done:2026-08-12 used it, finds rows -->", Some("2026-08-12")),
                row("epic(notes): notes to standard <!-- id:ar-8 done:2026-08-19 checked -->", Some("2026-08-19")),
                row("epic(views): a board <!-- id:ar-7 done:2026-08-26 pr:5 -->", Some("2026-08-26")),
            ],
            ..Bucket::default()
        };
        let p = plan(rows, (0, 0, 1), false, &none, d("2026-11-11"));
        let got: Vec<_> = p.cuts.iter().map(|c| c.version).collect();
        assert_eq!(
            got,
            vec![(0, 1, 0), (0, 2, 0), (0, 2, 1), (0, 2, 2)],
            "a standing epic and an epic closed on a PR alone are patches"
        );
        assert_eq!(p.cuts[1].feature.as_deref(), Some("search that works"));
    }

    #[test]
    fn a_project_with_frozen_versions_starts_at_its_open_version_with_no_baseline() {
        let rows = Bucket {
            board: vec![
                row("feat(notes): a", Some("2026-08-04")),
                row("feat(notes): b", None),
                row("feat(notes): c", Some("2026-08-11")),
            ],
            ..Bucket::default()
        };
        let called = std::cell::Cell::new(false);
        let commits = |_: NaiveDate| {
            called.set(true);
            Vec::new()
        };
        let p = plan(rows, (0, 0, 2), true, &commits, d("2026-11-11"));
        let got: Vec<_> = p.cuts.iter().map(|c| (c.version, c.rows.rows())).collect();
        assert_eq!(got, vec![((0, 0, 2), 2), ((0, 0, 3), 1)]);
        assert_eq!(p.open, (0, 0, 4));
        assert!(!called.get(), "no baseline, so no git log");
    }

    #[test]
    fn a_week_of_proof_lines_alone_cuts_nothing() {
        let proof = |day: &str| Block {
            lines: vec![format!("| t | pr:1 | {day} |")],
            day: Some(d(day)),
        };
        let rows = Bucket {
            board: vec![
                row("feat(notes): a", Some("2026-08-04")),
                row("feat(notes): b", Some("2026-08-25")),
            ],
            proof: vec![proof("2026-08-12"), proof("2026-09-01")],
            ..Bucket::default()
        };
        let p = plan(rows, (0, 0, 1), false, &none, d("2026-11-11"));
        let got: Vec<_> = p.cuts.iter().map(|c| (c.week, c.rows.tasks(), c.rows.proof.len())).collect();
        assert_eq!(
            got,
            vec![(Some(d("2026-08-03")), 1, 0), (Some(d("2026-08-24")), 1, 2)],
            "the lines of a week with no row join the next week with one, else the last"
        );
    }

    #[test]
    fn nothing_before_this_week_cuts_nothing() {
        let rows = Bucket {
            board: vec![row("feat(notes): a", Some("2026-11-10"))],
            ..Bucket::default()
        };
        let p = plan(rows, (0, 0, 1), false, &none, d("2026-11-11"));
        assert!(p.cuts.is_empty());
        assert_eq!(p.open, (0, 0, 1), "the open version is unchanged");
    }

    #[test]
    fn the_baseline_counts_commits_by_system() {
        let systems = vec![standing::System {
            id: "notes".into(),
            aliases: vec!["notes-cli".into()],
        }];
        let c = count_scopes(
            "feat(notes-cli): a\nfix(notes): b (#3)\nfeat(nvim,tmux): c\nUpdate readme\nWIP(x): y\n",
            &systems,
        );
        let want: BTreeMap<String, usize> = [
            ("notes".to_string(), 2),
            ("other".to_string(), 3),
        ]
        .into_iter()
        .collect();
        assert_eq!(c, want);
    }

    #[test]
    fn the_open_note_keeps_its_sections_and_this_weeks_rows_under_the_new_number() {
        let n = parse_note(NOTE);
        let left = Bucket {
            proof: vec![n.proof[1].clone()],
            board: vec![],
            sheet: vec![],
        };
        let out = open_note(&n, (0, 0, 1), (0, 1, 4), &left);
        assert!(out.starts_with("# p v0.1.4 - AI notes\n"), "{out}");
        assert!(out.contains("| b | pr:2 | 2026-11-10 |"), "{out}");
        assert!(!out.contains("| a |"), "{out}");
        assert!(out.contains("## Notes\nlog line"), "{out}");
        assert!(
            !out.contains("## Done rows"),
            "an emptied section goes: {out}"
        );
    }

    #[test]
    fn the_version_line_moves_and_keeps_its_tags() {
        let s = "# p\nVersion: v0.0.1 #alpha #tooling\n\n## Tasks\nVersion: v9.9.9\n";
        assert_eq!(
            set_version(s, (0, 1, 4)),
            "# p\nVersion: v0.1.4 #alpha #tooling\n\n## Tasks\nVersion: v9.9.9\n"
        );
    }

    #[test]
    fn a_frozen_human_note_has_the_release_shape() {
        let cut = Cut {
            version: (0, 1, 1),
            week: Some(d("2026-08-03")),
            rows: Bucket {
                board: vec![row(
                    "feat(notes): a <!-- id:ar-1 pr:12 -->",
                    Some("2026-08-04"),
                )],
                sheet: vec![row("feat(notes): s <!-- pr:13 -->", Some("2026-08-05"))],
                proof: vec![],
            },
            commits: Vec::new(),
            feature: None,
        };
        let shipped = shipped(&cut, d("2026-08-03"), &[], &HashMap::new());
        let out = human_note("# p", &cut, &shipped, cut.rolled(d("2026-08-03")));
        assert!(
            out.starts_with("# p\nVersion: v0.1.1\n\n## Tasks\n- [x] feat(notes): s"),
            "{out}"
        );
        assert!(out.contains("### other (2)\n- no epic: 2\n"), "an area the project does not list is other: {out}");
        assert!(out.contains("- pr:12\n- pr:13\n"), "{out}");
        let end = d("2026-08-10")
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_local_timezone(chrono::Local)
            .earliest()
            .unwrap()
            .timestamp()
            - 1;
        assert!(out.ends_with(&format!("<!-- rolled: {end} -->\n")), "{out}");
    }
}
