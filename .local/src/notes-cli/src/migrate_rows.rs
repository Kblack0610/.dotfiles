//! `notes projects --migrate-rows`: the one-off changeover of every sheet to the row grammar
//! and the single `## Tasks` section. The only reader of the old `## Wave` headings lives here.
//!
//! Row pass, on the top-level open rows: `since:` becomes `#c`, a missing `#c` comes from
//! `git blame`, dead tags go, `#ci` becomes a `ci(...)` type, `YOU:` becomes `run(...)`, and an
//! id is stamped. A done row only loses dead tags. Structure pass: every `## Wave` section folds into one `## Tasks` with
//! `## Inbox` above it, a planned wave's rows take its `#vX` tag, and done rows go under
//! `### Done`. Rows are never reordered, added or dropped, and a second run changes nothing.

use crate::agent_sheet;
use crate::config;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use crate::project_tasks;
use crate::projects;
use crate::registry::Registry;
use crate::sheet::{self, V};
use anyhow::Result;
use chrono::{Local, NaiveDate};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;
use std::process::Command;

/// Tags the grammar retired outright. `#ci` is not here: it turns into a type. `#p1` and
/// `#high-priority` are not either: the vault's only uses are rows talking about them.
const DEAD_TAGS: [&str; 2] = ["#oneshot", "#ai"];

/// What one sheet's migration did, for the report.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
struct Tally {
    ids: usize,
    created: usize,
    tags: usize,
    typed: usize,
    aimed: usize,
    done: usize,
}

impl Tally {
    fn add(&mut self, o: Tally) {
        self.ids += o.ids;
        self.created += o.created;
        self.tags += o.tags;
        self.typed += o.typed;
        self.aimed += o.aimed;
        self.done += o.done;
    }

    fn line(&self) -> String {
        format!(
            "{} ids, {} #c, {} dead tags, {} typed, {} aimed at a release, {} done rows moved",
            self.ids, self.created, self.tags, self.typed, self.aimed, self.done
        )
    }
}

/// Hands out a project's next row ids. `None` code: the project has no `code` in the registry
/// and its rows stay unaddressed, as `ptask add` leaves them.
struct Ids {
    code: Option<String>,
    next: u64,
}

impl Ids {
    fn mint(&mut self) -> Option<String> {
        let code = self.code.as_ref()?;
        let id = format!("{code}-{}", self.next);
        self.next += 1;
        Some(id)
    }
}

/// What the row pass needs from outside the sheet: passed in so the pass stays pure.
struct Rows<'a> {
    /// Lowercase kebab project name: the area of a row with none of its own.
    slug: String,
    today: NaiveDate,
    /// Row text -> the earliest day `git blame` dates that exact line.
    blame: &'a HashMap<String, NaiveDate>,
    ids: &'a mut Ids,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Kind {
    Tasks,
    Wave(Option<V>),
}

#[derive(Debug, Clone, Copy)]
struct Section {
    kind: Kind,
    start: usize,
    end: usize,
}

fn kind_of(line: &str) -> Option<Kind> {
    let h = line.strip_prefix("## ")?.trim();
    if h == sheet::TASKS {
        return Some(Kind::Tasks);
    }
    h.starts_with("Wave").then(|| Kind::Wave(version_in(h)))
}

/// The first `vX.Y.Z` token in a heading (`Wave: v1.13.0 (current)` -> `(1,13,0)`).
fn version_in(heading: &str) -> Option<V> {
    heading
        .split(|c: char| c.is_whitespace() || c == ':')
        .find_map(|t| projects::parse_version(t.trim_matches(['(', ')'])))
}

/// Every task section above the rollup, in file order.
fn scan(lines: &[&str]) -> Vec<Section> {
    let stop = lines
        .iter()
        .position(|l| l.trim() == md::ROLLUP_START)
        .unwrap_or(lines.len());
    (0..stop)
        .filter_map(|i| {
            kind_of(lines[i]).map(|kind| Section {
                kind,
                start: i,
                end: md::section_end(lines, i + 1),
            })
        })
        .collect()
}

/// Does this file carry a section the migration reads?
fn is_sheet(content: &str) -> bool {
    !scan(&content.lines().collect::<Vec<_>>()).is_empty()
}

fn is_row(line: &str) -> bool {
    line.starts_with("- [")
}

/// Cut a `since:YYYY-MM-DD` stamp out of a line, returning its date.
fn take_since(line: &str) -> (String, Option<NaiveDate>) {
    let date = line.find("since:").and_then(|i| {
        let tail = i + "since:".len();
        let d = line.get(tail..tail + 10)?;
        Some((i, tail + 10, NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()?))
    });
    match date {
        Some((i, end, d)) => {
            let rest = format!("{}{}", line[..i].trim_end(), &line[end..]);
            (rest.replace(" <!-- -->", ""), Some(d))
        }
        None => (line.to_string(), None),
    }
}

/// `area: title` when a row leads with one lowercase word and a colon. `ci:` names the type,
/// not an area, so it counts as no area.
fn split_area(text: &str) -> (Option<String>, &str) {
    let Some((head, title)) = text.split_once(": ") else {
        return (None, text);
    };
    let word = !head.is_empty()
        && head
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_');
    match (word, head) {
        (true, "ci") => (None, title.trim()),
        (true, _) => (Some(head.replace('_', "-")), title.trim()),
        (false, _) => (None, text),
    }
}

/// The `#ci` tag as a `ci(area): title` type. A row already typed only loses the tag.
fn type_ci(line: &str, slug: &str) -> String {
    let bare = md::drop_tag(line, "#ci");
    if projects::row_type_area(&bare).is_some() {
        return bare;
    }
    let text = md::task_text(&bare);
    let (area, title) = split_area(&text);
    let area = area.as_deref().unwrap_or(slug);
    md::retext_task(&bare, &format!("ci({area}): {title}"))
}

fn strip_dead_tags(line: &str, t: &mut Tally) -> String {
    let mut l = line.to_string();
    for tag in DEAD_TAGS {
        let kept = md::drop_tag(&l, tag);
        t.tags += usize::from(kept != l);
        l = kept;
    }
    l
}

/// One open row brought up to the grammar.
fn fix_row(line: &str, rows: &mut Rows, t: &mut Tally) -> String {
    let (mut l, since) = take_since(line);
    if md::split_created(&l).1.is_none() {
        if let Some(d) = since.or_else(|| rows.blame.get(line).copied()) {
            l = md::add_tag(&l, &md::created_tag(d, rows.today));
            t.created += 1;
        }
    }
    l = strip_dead_tags(&l, t);
    let text = md::task_text(&l);
    if let Some(rest) = text.strip_prefix("YOU:") {
        l = md::drop_tag(&l, "#ci");
        l = md::retext_task(&l, &format!("run({}): {}", rows.slug, rest.trim()));
        t.typed += 1;
    } else if md::drop_tag(&l, "#ci") != l {
        l = type_ci(&l, &rows.slug);
        t.typed += 1;
    }
    if md::row_id(&l).is_none() {
        if let Some(id) = rows.ids.mint() {
            l = md::add_marker(&l, &format!("id:{id}"));
            t.ids += 1;
        }
    }
    l
}

fn fix_rows(content: &str, rows: &mut Rows, t: &mut Tally) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let sections = scan(&lines);
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    for s in &sections {
        for i in s.start + 1..s.end {
            if !is_row(lines[i]) {
                continue;
            }
            out[i] = if md::is_open_task(lines[i]) {
                fix_row(lines[i], rows, t)
            } else {
                strip_dead_tags(lines[i], t)
            };
        }
    }
    let mut joined = out.join("\n");
    joined.push('\n');
    joined
}

/// A row aimed at `aim` carries its tag, unless it already names a release.
fn aimed(line: &str, aim: Option<V>, t: &mut Tally) -> String {
    match aim {
        Some(v)
            if is_row(line) && !md::is_empty_unchecked(line) && md::version_tag(line).is_none() =>
        {
            t.aimed += 1;
            md::add_tag(line, &format!("#{}", projects::fmt_version(v)))
        }
        _ => line.to_string(),
    }
}

fn trim_blanks(mut v: Vec<String>) -> Vec<String> {
    while v.last().is_some_and(|l| l.trim().is_empty()) {
        v.pop();
    }
    let lead = v.iter().take_while(|l| l.trim().is_empty()).count();
    v.drain(..lead);
    v.dedup_by(|a, b| a.trim().is_empty() && b.trim().is_empty());
    v
}

/// One section's lines, split into what stays in the body and the done blocks. The old
/// `---` / `### Done` scaffold and the blank placeholder are dropped: the fold writes its own.
fn split_section(
    lines: &[&str],
    s: Section,
    aim: Option<V>,
    t: &mut Tally,
) -> (Vec<String>, Vec<String>) {
    let (mut body, mut done) = (Vec::new(), Vec::new());
    let mut i = s.start + 1;
    while i < s.end {
        let l = lines[i];
        i += 1;
        if is_row(l) && md::is_checked(l) {
            done.push(aimed(l, aim, t));
            t.done += 1;
            while i < s.end && !lines[i].trim().is_empty() && lines[i].starts_with([' ', '\t']) {
                done.push(lines[i].to_string());
                i += 1;
            }
        } else if !(l.trim() == "---"
            || l.trim() == "### Done"
            || (is_row(l) && md::is_empty_unchecked(l)))
        {
            body.push(aimed(l, aim, t));
        }
    }
    (trim_blanks(body), done)
}

/// Fold the sections into one `## Tasks`, at the first of them, with `## Inbox` above it.
fn restructure(content: &str, cur: Option<V>, t: &mut Tally) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let sections = scan(&lines);
    let has_wave = sections.iter().any(|s| matches!(s.kind, Kind::Wave(_)));
    let inbox = format!("## {}", sheet::INBOX);
    let has_inbox = lines.iter().any(|l| l.trim() == inbox);
    if sections.is_empty() || (!has_wave && has_inbox) {
        return content.to_string();
    }
    let main = sections
        .iter()
        .position(|s| cur.is_some() && s.kind == Kind::Wave(cur))
        .or_else(|| sections.iter().position(|s| s.kind == Kind::Tasks))
        .unwrap_or(0);
    let (mut body, mut done) = split_section(&lines, sections[main], None, t);
    for (_, s) in sections.iter().enumerate().filter(|(k, _)| *k != main) {
        let aim = match s.kind {
            Kind::Wave(Some(v)) if cur.is_none_or(|c| v > c) => Some(v),
            _ => None,
        };
        let (b, d) = split_section(&lines, *s, aim, t);
        body.extend(b);
        done.extend(d);
    }

    let head = lines[..sections[0].start].iter().map(|l| (*l).to_string());
    let mut out = trim_blanks(head.collect());
    if !out.is_empty() {
        out.push(String::new());
    }
    if !has_inbox {
        out.extend([inbox, String::new()]);
    }
    out.push(format!("## {}", sheet::TASKS));
    out.extend(body);
    out.push("- [ ] ".to_string());
    if !done.is_empty() {
        out.extend([String::new(), "---".to_string(), "### Done".to_string()]);
        out.extend(done);
    }
    let mut from = sections[0].end;
    for s in sections[1..]
        .iter()
        .map(|s| (s.start, s.end))
        .chain([(lines.len(), lines.len())])
    {
        let gap = trim_blanks(lines[from..s.0].iter().map(|l| (*l).to_string()).collect());
        if !gap.is_empty() {
            out.push(String::new());
            out.extend(gap);
        }
        from = s.1;
    }
    let mut joined = out.join("\n");
    joined.push('\n');
    joined
}

fn migrate(content: &str, cur: Option<V>, rows: &mut Rows, t: &mut Tally) -> String {
    restructure(&fix_rows(content, rows, t), cur, t)
}

/// Row text -> the earliest day blame dates it. An uncommitted line dates to now, which is
/// right: it was written today. Empty when the file is not in git.
fn blame_dates(path: &Path) -> HashMap<String, NaiveDate> {
    let mut out: HashMap<String, NaiveDate> = HashMap::new();
    let (Some(dir), Some(file)) = (path.parent(), path.file_name()) else {
        return out;
    };
    let run = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["blame", "--line-porcelain", "--"])
        .arg(file)
        .output();
    let Ok(run) = run.map(|o| {
        if o.status.success() {
            o.stdout
        } else {
            Vec::new()
        }
    }) else {
        return out;
    };
    let mut date = None;
    for line in String::from_utf8_lossy(&run).lines() {
        if let Some(t) = line.strip_prefix("author-time ") {
            date = t
                .parse()
                .ok()
                .and_then(|s| chrono::DateTime::from_timestamp(s, 0))
                .map(|d| d.with_timezone(&Local).date_naive());
        } else if let (Some(text), Some(d)) = (line.strip_prefix('\t'), date) {
            out.entry(text.to_string())
                .and_modify(|e| *e = (*e).min(d))
                .or_insert(d);
        }
    }
    out
}

/// The human sheet of a project dir: `task_sheet`'s choice, read for either heading.
fn human_sheet(dir: &Path) -> Option<std::path::PathBuf> {
    ["README.md", "tasks.md"].iter().find_map(|n| {
        let p = dir.join(n);
        fs::read_to_string(&p)
            .ok()
            .filter(|c| is_sheet(c))
            .map(|_| p)
    })
}

/// Migrate one sheet file. Returns its open rows for the duplicate check.
fn migrate_file(
    log: &Logger,
    path: &Path,
    cur: Option<V>,
    board: bool,
    rows: &mut Rows,
    total: &mut Tally,
    dry_run: bool,
) -> Result<Vec<String>> {
    let content = fs::read_to_string(path)?;
    let mut t = Tally::default();
    let mut new = migrate(&content, cur, rows, &mut t);
    if board {
        new = projects::drop_head_version(&new);
    }
    if new != content {
        println!("{}: {}", path.display(), t.line());
        total.add(t);
        if !dry_run {
            md::write_atomic(path, &new)?;
            log.info("projects", &format!("migrated {}", path.display()));
        }
    }
    Ok(sheet::open_rows(&new)
        .into_iter()
        .map(|(_, l)| l.to_string())
        .collect())
}

/// Print exact duplicates among a project's open rows, both lanes together. Which copy goes is
/// a reading job, so nothing here removes one.
fn flag_duplicates(name: &str, open: &[String]) -> usize {
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    for l in open {
        *seen.entry(md::task_key(l)).or_default() += 1;
    }
    let dups: Vec<_> = seen.iter().filter(|(_, n)| **n > 1).collect();
    for (key, n) in &dups {
        println!("duplicate in {name} ({n}x): {key}");
    }
    dups.len()
}

pub fn run(log: &Logger, dry_run: bool) -> Result<()> {
    let today = Local::now().date_naive();
    let registry = Registry::load();
    let mut total = Tally::default();
    let (mut sheets, mut dups) = (0, 0);
    let mut uncoded = Vec::new();
    for profile in config::all_profile_names()? {
        let Ok(p) = config::resolve(Some(&profile)) else {
            continue;
        };
        for (name, summary) in daily::discover_project_dirs(&p) {
            let Some(dir) = summary.parent() else {
                continue;
            };
            let code = registry.as_ref().and_then(|r| r.code(&name));
            let next = code.as_ref().map_or(1, |c| {
                let id = project_tasks::next_id(dir, c);
                id.rsplit('-')
                    .next()
                    .and_then(|n| n.parse().ok())
                    .unwrap_or(1)
            });
            if code.is_none() {
                uncoded.push(name.clone());
            }
            let mut ids = Ids { code, next };
            let slug = name.to_lowercase().replace('_', "-");
            let human = human_sheet(dir);
            let cur = human
                .as_ref()
                .and_then(|h| fs::read_to_string(h).ok())
                .and_then(|c| projects::sheet_version(&c));
            let agent = Some(agent_sheet::sheet_path(dir))
                .filter(|a| fs::read_to_string(a).is_ok_and(|c| is_sheet(&c)));
            let mut open = Vec::new();
            for (path, board) in [(human, false), (agent, true)] {
                let Some(path) = path else { continue };
                let blame = blame_dates(&path);
                let mut rows = Rows {
                    slug: slug.clone(),
                    today,
                    blame: &blame,
                    ids: &mut ids,
                };
                sheets += 1;
                open.extend(migrate_file(
                    log, &path, cur, board, &mut rows, &mut total, dry_run,
                )?);
            }
            dups += flag_duplicates(&name, &open);
        }
    }
    if !uncoded.is_empty() {
        println!(
            "no `code` in project-map.json, rows left without ids: {}",
            uncoded.join(", ")
        );
    }
    let verb = if dry_run { "would change" } else { "changed" };
    println!(
        "{sheets} sheets read, {dups} duplicate rows flagged, {verb}: {}",
        total.line()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const CUR: Option<V> = Some((1, 13, 0));

    fn day(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn run_on(
        content: &str,
        cur: Option<V>,
        blame: &HashMap<String, NaiveDate>,
    ) -> (String, Tally) {
        let mut ids = Ids {
            code: Some("ar".to_string()),
            next: 7,
        };
        let mut rows = Rows {
            slug: "my-app".to_string(),
            today: day("2026-11-04"),
            blame,
            ids: &mut ids,
        };
        let mut t = Tally::default();
        (migrate(content, cur, &mut rows, &mut t), t)
    }

    fn one_row(line: &str) -> String {
        let sheet = format!("# a\n\n## Inbox\n\n## Tasks\n{line}\n");
        let (out, _) = run_on(&sheet, CUR, &HashMap::new());
        out.lines().nth(5).unwrap().to_string()
    }

    const OLD: &str = "# a\nVersion: v1.13.0\n\n## Wave: v1.13.0 (current)\n- [ ] now #high\n  - a note\n- [/] going\n- [x] shipped <!-- pr:4 -->\n  - why\n- [ ] \n\n---\n### Done\n- [x] older\n\n## Wave: v1.14.0 (planned)\n- [ ] later\n- [ ] pinned #v1.15.0\n- [x] early\n\n## Wave: 7\n- [ ] unnamed\n\n## Notes\nprose\n";

    #[test]
    fn the_waves_fold_into_one_section_with_the_inbox_above_it() {
        let (out, t) = run_on(OLD, CUR, &HashMap::new());
        assert_eq!(
            out,
            "# a\nVersion: v1.13.0\n\n## Inbox\n\n## Tasks\n- [ ] now #high <!-- id:ar-7 -->\n  - a note\n- [/] going <!-- id:ar-8 -->\n- [ ] later #v1.14.0 <!-- id:ar-9 -->\n- [ ] pinned #v1.15.0 <!-- id:ar-10 -->\n- [ ] unnamed <!-- id:ar-11 -->\n- [ ] \n\n---\n### Done\n- [x] shipped <!-- pr:4 -->\n  - why\n- [x] older\n- [x] early #v1.14.0\n\n## Notes\nprose\n"
        );
        assert_eq!((t.ids, t.aimed, t.done), (5, 2, 3), "{t:?}");
    }

    #[test]
    fn a_second_run_changes_nothing() {
        let (once, _) = run_on(OLD, CUR, &HashMap::new());
        let (twice, t) = run_on(&once, CUR, &HashMap::new());
        assert_eq!(once, twice);
        assert_eq!(t, Tally::default());
    }

    #[test]
    fn open_rows_survive_the_fold_one_for_one() {
        let before = OLD.lines().filter(|l| md::is_open_task(l)).count();
        let (out, _) = run_on(OLD, CUR, &HashMap::new());
        assert_eq!(sheet::open_rows(&out).len(), before);
    }

    #[test]
    fn a_wave_written_after_the_fold_rejoins_it() {
        // An old binary finds no `## Wave` and appends a stub; the rerun picks it up.
        let (once, _) = run_on(OLD, CUR, &HashMap::new());
        let late = format!("{once}\n## Wave: new (current)\n- [ ] stray\n");
        let (out, _) = run_on(&late, CUR, &HashMap::new());
        assert!(!out.contains("## Wave"), "{out}");
        assert!(
            out.contains("- [ ] stray <!-- id:ar-7 -->\n- [ ] \n"),
            "{out}"
        );
    }

    #[test]
    fn a_section_below_the_notes_is_found_and_the_rollup_is_not() {
        let sheet = format!(
            "# a\n\n## Wave: new (current)\n- [ ] one\n\n## Shipped (v0.0.1)\n- [x] old\n\n{}\n## Wave: v9.0.0 (planned)\n- [ ] rollup text\n",
            md::ROLLUP_START
        );
        let (out, _) = run_on(&sheet, None, &HashMap::new());
        assert!(
            out.contains(
                "## Tasks\n- [ ] one <!-- id:ar-7 -->\n- [ ] \n\n## Shipped (v0.0.1)\n- [x] old\n"
            ),
            "{out}"
        );
        assert!(
            out.contains("## Wave: v9.0.0 (planned)\n- [ ] rollup text\n"),
            "{out}"
        );
    }

    #[test]
    fn a_sheet_with_no_task_section_is_left_alone() {
        let prose = "# a\n\n## Notes\n- [ ] not a row\n";
        assert_eq!(run_on(prose, CUR, &HashMap::new()).0, prose);
    }

    #[test]
    fn a_board_takes_the_parents_version_and_keeps_a_tag_for_rows_ahead_of_it() {
        let board = "# a - agent board\n\n## Wave: v1.12.0 (current)\n- [ ] behind\n\n## Wave: v1.13.0 (planned)\n- [ ] open now\n\n## Wave: v1.14.0 (planned)\n- [ ] ahead\n";
        let (out, _) = run_on(board, CUR, &HashMap::new());
        assert!(
            out.contains("- [ ] open now <!-- id:ar-8 -->\n- [ ] behind <!-- id:ar-7 -->\n"),
            "{out}"
        );
        assert!(
            out.contains("- [ ] ahead #v1.14.0 <!-- id:ar-9 -->"),
            "{out}"
        );
    }

    #[test]
    fn since_becomes_a_created_tag() {
        let row = one_row("- [ ] old row since:2026-10-02 #high");
        assert!(row.contains("#c1002") && !row.contains("since:"), "{row}");
        let row = one_row("- [ ] old row <!-- since:2026-10-02 -->");
        assert!(row.contains("#c1002") && !row.contains("since:"), "{row}");
    }

    #[test]
    fn a_stamped_row_keeps_its_date_and_blame_fills_the_rest() {
        let blame = HashMap::from([
            ("- [ ] dated".to_string(), day("2026-02-01")),
            ("- [ ] stamped #c1003".to_string(), day("2026-02-01")),
        ]);
        let sheet =
            "# a\n\n## Inbox\n\n## Tasks\n- [ ] dated\n- [ ] stamped #c1003\n- [ ] unknown\n";
        let (out, t) = run_on(sheet, CUR, &blame);
        assert!(out.contains("- [ ] dated #c260201 <!--"), "{out}");
        assert!(out.contains("- [ ] stamped #c1003 <!--"), "{out}");
        assert!(out.contains("- [ ] unknown <!--"), "{out}");
        assert_eq!(t.created, 1);
    }

    #[test]
    fn a_done_row_loses_its_dead_tags_and_nothing_else() {
        let sheet =
            "# a\n\n## Inbox\n\n## Tasks\n- [ ] \n\n---\n### Done\n- [x] old #oneshot #low\n";
        let (out, t) = run_on(sheet, CUR, &HashMap::new());
        assert!(out.contains("- [x] old #low\n"), "{out}");
        assert_eq!((t.tags, t.ids), (1, 0));
    }

    // A row about a retired tag is not a row carrying it.
    #[test]
    fn a_row_quoting_a_retired_priority_keeps_its_words() {
        let row = one_row("- [ ] sweep parsed #high-priority as #high #low");
        assert!(row.contains("parsed #high-priority as"), "{row}");
    }

    #[test]
    fn dead_tags_go_and_prose_that_quotes_one_stays() {
        let row = one_row("- [ ] tidy #oneshot #ai #high");
        assert!(row.starts_with("- [ ] tidy #high"), "{row}");
        let row = one_row("- [ ] restock the first #aid kit");
        assert!(row.contains("#aid"), "{row}");
    }

    #[test]
    fn the_ci_tag_becomes_a_type() {
        assert!(one_row("- [ ] green the nightly #ci #low")
            .starts_with("- [ ] ci(my-app): green the nightly #low"));
        assert!(one_row("- [ ] asset-library: cache the pull #ci")
            .starts_with("- [ ] ci(asset-library): cache the pull"));
        assert!(
            one_row("- [ ] ci: split the job #ci").starts_with("- [ ] ci(my-app): split the job")
        );
        assert!(
            one_row("- [ ] fix(api): flaky retry #ci").starts_with("- [ ] fix(api): flaky retry")
        );
        // NEGATIVE CONTROL: a plain `ci:` prefix with no tag is the triager's call, not a rule here.
        assert!(one_row("- [ ] ci: split the job").starts_with("- [ ] ci: split the job"));
    }

    #[test]
    fn you_becomes_a_run_row() {
        let row = one_row("- [ ] YOU: cancel the plan #high #v1.19.1 <!-- carried:3 -->");
        assert!(
            row.starts_with(
                "- [ ] run(my-app): cancel the plan #high #v1.19.1 <!-- carried:3 id:ar-7 -->"
            ),
            "{row}"
        );
    }

    #[test]
    fn an_existing_id_stays_and_a_project_with_no_code_gets_none() {
        assert!(one_row("- [ ] kept <!-- id:ar-2 -->").ends_with("<!-- id:ar-2 -->"));
        let mut ids = Ids {
            code: None,
            next: 1,
        };
        let blame = HashMap::new();
        let mut rows = Rows {
            slug: "x".to_string(),
            today: day("2026-11-04"),
            blame: &blame,
            ids: &mut ids,
        };
        let mut t = Tally::default();
        assert_eq!(fix_row("- [ ] a", &mut rows, &mut t), "- [ ] a");
    }

    #[test]
    fn a_child_row_is_left_to_its_parent() {
        let sheet = "# a\n\n## Inbox\n\n## Tasks\n- [ ] parent\n  - [ ] child #ci\n";
        let (out, _) = run_on(sheet, CUR, &HashMap::new());
        assert!(out.contains("\n  - [ ] child #ci\n"), "{out}");
    }

    #[test]
    fn duplicates_are_counted_not_removed() {
        let open = [
            "- [ ] same #high".to_string(),
            "- [ ] same <!-- id:ar-1 -->".to_string(),
            "- [ ] other".to_string(),
        ];
        assert_eq!(flag_duplicates("demo", &open), 1);
    }
}
