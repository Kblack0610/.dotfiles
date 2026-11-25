//! The ingest record: one JSONL event per line an intake step moved, filed or left, and per
//! row a CLI verb wrote, at `<state_dir>/ingest.jsonl`. It is the one source for "what happened
//! to this row": `notes log` and the inbox status page read it, and the triager's eval scores
//! against it. Hand edits never pass through here; vault git history holds those. Runtime
//! state, so it lives outside the vault, as the rule on telemetry in `notes-system` says.

use crate::config::Profile;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::PathBuf;

/// One intake step on one line.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Event {
    /// RFC 3339, local time.
    pub ts: String,
    /// Intake: `split` (a list became one line per ask, `why` its size), `moved` (outbox or Focus -> an inbox), `filed`, `dup`, `planned`, `left` (waits
    /// for the human) or `refused` (a write the CLI turned down). A verb's write to a row:
    /// `capped` (a new agent row the daily intake cap turned away, `gate.rs`), `added`, `edited`, `detailed`, `tagged`, `started`, `unstarted`, `toggled` (a Focus row), `done`, `dropped`, `placed` (another
    /// version on the same sheet), `rehomed` (another project), `removed` (left Focus undone),
    /// `swept` or `archived`.
    pub action: String,
    /// Where the line was: `outbox`, `focus`, or the project whose inbox held it.
    pub from: String,
    /// The project it went to; empty when it stayed.
    #[serde(default)]
    pub to: String,
    /// `human` or `agent` for a filing; empty otherwise.
    #[serde(default)]
    pub lane: String,
    /// The line's words.
    pub text: String,
    /// The row id it was filed as, or the open row it joined.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Why it stayed, for `left` and `refused`; how the sweep decided a `moved`, `filed` or
    /// `dup` (`#p: tag`, `id answer`, `typed`, or `model: <its why>`); a `split`'s line count; a
    /// `sweep`'s counts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// For `filed`: the first row's words as filed ([`row_words`]). For `edited`: the row's new
    /// words.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
    /// Who wrote it ([`by`]).
    #[serde(default)]
    pub by: String,
    /// Which step of the chain from intake to landed the write is about: `intake` (a line
    /// moved or filed), `backlog` (a verb's write to a row), `queue` (an agent-queue item),
    /// `dispatch` (fleet-dispatch starting, reaping or settling) or `land` (a merge).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
    /// The channel a human's want entered by (`--want`), on the write that stamped `#requested`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub want: Option<String>,
    /// For a row a hand session filed after its self-check (`why: self-check`): the shortlist ids it
    /// was shown and named in `--checked` as other work.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checked: Vec<String>,
    /// For an `added` agent row: its writer, `ptask add --origin`, else the agentctl runner.
    /// [`ORIGIN_STORY`] is a story row, the board's copy of a queue item added already started,
    /// which `notes log --steps` leaves out of the backlog.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// The agent-queue item the write belongs to or names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    /// The Claude session that wrote it, in full.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The pull request, `owner/repo#N` or a bare number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
    /// The merge commit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha: Option<String>,
    /// For a `left` line: the projects the lines written beside it were filed to, which a
    /// later sweep that asks it again shows the router, since those lines left with their rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub near: Option<String>,
}

/// `v` trimmed, or `None` when that leaves nothing.
pub fn set(v: Option<&str>) -> Option<String> {
    v.map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// The `--origin` agent-queue files a story row with (`file_story`): a mirror of work already
/// started, never a row that waited on the backlog.
pub const ORIGIN_STORY: &str = "agent-queue";

/// The stages that are not intake: the inbox page and the board channel read only intake.
pub const CHAIN_STAGES: [&str; 3] = ["queue", "dispatch", "land"];

impl Event {
    pub fn new(action: &str, from: &str, to: &str, text: &str) -> Self {
        let env = |k: &str| std::env::var(k).ok();
        let (item, session, runner) = (
            env("AGENT_QUEUE_ITEM"),
            env("CLAUDE_CODE_SESSION_ID"),
            env("AGENTCTL_NAME"),
        );
        Event {
            ts: chrono::Local::now().to_rfc3339(),
            action: action.into(),
            from: from.into(),
            to: to.into(),
            text: text.trim().into(),
            by: by(item.as_deref(), session.as_deref(), runner.as_deref()),
            stage: Some("intake".into()),
            item: set(item.as_deref()),
            session_id: set(session.as_deref()),
            ..Default::default()
        }
    }

    /// A verb's write to the row `line`, on `lane` when the write has one.
    pub fn row(action: &str, from: &str, to: &str, lane: &str, line: &str) -> Self {
        Event {
            lane: lane.into(),
            id: crate::md::row_id(line),
            // A line put on the outbox is a capture the sweep has yet to file, not a row.
            stage: Some(
                if from == "outbox" {
                    "intake"
                } else {
                    "backlog"
                }
                .into(),
            ),
            ..Event::new(action, from, to, &crate::md::task_text(line))
        }
    }

    /// `done`'s proof stamp (`pr:<N> commit:<sha>`) as the event's `pr` and `sha`.
    pub fn proof(mut self, stamp: &str) -> Self {
        let tok = |k: &str| {
            stamp
                .split_whitespace()
                .find_map(|w| w.strip_prefix(k))
                .and_then(|v| set(Some(v)))
        };
        self.pr = tok("pr:");
        self.sha = tok("commit:");
        self
    }

    /// Whether the inbox page and the board channel read it: intake and row writes, not the
    /// queue, dispatch and land steps that `notes ingest record --stage` writes.
    pub fn is_intake(&self) -> bool {
        self.stage
            .as_deref()
            .is_none_or(|s| !CHAIN_STAGES.contains(&s))
    }
}

/// Who a write belongs to: the queue item, else the session's first 8 characters, else the
/// agentctl runner it runs under (`AGENTCTL_NAME`, so a sweep's filing is `inbox-triage`), else
/// `human`.
fn by(item: Option<&str>, session: Option<&str>, runner: Option<&str>) -> String {
    set(item)
        .or_else(|| set(session).map(|s| s.chars().take(8).collect()))
        .or_else(|| set(runner))
        .unwrap_or_else(|| "human".into())
}

/// [`by`] for this process's environment: the name a `#from/` tag on a session's follow-up carries.
pub fn writer() -> String {
    let env = |k: &str| std::env::var(k).ok();
    by(
        env("AGENT_QUEUE_ITEM").as_deref(),
        env("CLAUDE_CODE_SESSION_ID").as_deref(),
        env("AGENTCTL_NAME").as_deref(),
    )
}

pub fn path(p: &Profile) -> PathBuf {
    p.state_dir.join("ingest.jsonl")
}

/// Past this size the record is cut to its last [`KEEP_DAYS`], and then to its newest
/// [`PRUNE_TO_BYTES`] when those days still run over, so the page's read stays cheap. The cut goes
/// well under the cap, so a prune runs once per that many bytes of appends, never on each: a
/// rewrite replaces the file, and a `tail -F` reader (coord-watch) re-reads it whole.
const MAX_BYTES: u64 = 32 * 1024 * 1024;
const PRUNE_TO_BYTES: usize = (MAX_BYTES / 2) as usize;
const KEEP_DAYS: i64 = 30;

/// Append `ev`. Best effort, like the inbox flag: a record that cannot be written must not
/// fail the move it describes, so the error goes to stderr and the write stands.
/// One `split` event for each list `from` had split, its size in `why`, and a line on stdout.
pub fn record_splits(p: &Profile, from: &str, lists: &[(String, usize)]) {
    for (text, n) in lists {
        let why = Some(format!("{n} lines"));
        record(
            p,
            &Event {
                why,
                ..Event::new("split", from, "", text)
            },
        );
        println!("{from}: split into {n} lines: {text}");
    }
}

pub fn record(p: &Profile, ev: &Event) {
    let path = path(p);
    let res = (|| -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        let line = serde_json::to_string(ev).map_err(std::io::Error::other)?;
        // One write, so two sessions appending at once cannot interleave within a line.
        f.write_all(format!("{line}\n").as_bytes())?;
        if f.metadata()?.len() > MAX_BYTES {
            prune(&path, PRUNE_TO_BYTES)?;
        }
        Ok(())
    })();
    if let Err(e) = res {
        eprintln!("ingest record not written ({}): {e}", path.display());
    }
}

/// The lines of a fleet worker's record (`input`) this record should take: those of a queue item
/// that `have` does not hold word for word, and the instant the next read starts from (two hours
/// before the newest any line of `input` carries).
/// A line that does not read as an event is skipped; one with no item is the worker's own
/// intake or board write, which its own notes sync carries.
fn lines_to_import<'a>(
    have: &std::collections::HashSet<&str>,
    input: &'a str,
) -> (Vec<&'a str>, Option<String>) {
    let mut newest: Option<(chrono::DateTime<chrono::FixedOffset>, String)> = None;
    let mut take: Vec<&str> = vec![];
    for l in input.lines() {
        let Ok(e) = serde_json::from_str::<Event>(l) else {
            continue;
        };
        if let Ok(at) = chrono::DateTime::parse_from_rfc3339(&e.ts) {
            if newest.as_ref().is_none_or(|(n, _)| at > *n) {
                newest = Some((at, e.ts.clone()));
            }
        }
        if e.item.as_deref().is_some_and(|i| !i.is_empty())
            && !have.contains(l)
            && !take.contains(&l)
        {
            take.push(l);
        }
    }
    // Two hours behind the newest line read: the reader compares instants as text, which misorders
    // lines across a DST change (one hour) and a line stamped just before the cursor but written
    // after it. The overlap is re-read and dropped as already held.
    let cursor = newest.map(|(at, _)| {
        (at - chrono::Duration::hours(2)).to_rfc3339_opts(chrono::SecondsFormat::Nanos, false)
    });
    (take, cursor)
}

/// Append the queue-item events of a fleet worker's record that this one lacks: a worker keeps
/// its own `ingest.jsonl`, so what its sessions did to an item (moved it to done, merged it)
/// never reached the record the pipeline reads. Returns how many lines it took and the instant the
/// next read starts from, which the caller hands back to the worker's reader.
pub fn import(p: &Profile, input: &str) -> std::io::Result<(usize, Option<String>)> {
    let path = path(p);
    let have_text = fs::read_to_string(&path).unwrap_or_default();
    let have: std::collections::HashSet<&str> = have_text.lines().collect();
    let (take, newest) = lines_to_import(&have, input);
    if take.is_empty() {
        return Ok((0, newest));
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let block: String = take.iter().map(|l| format!("{l}\n")).collect();
    // One write, as `record` does, so a session appending at once cannot interleave within a line.
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?
        .write_all(block.as_bytes())?;
    Ok((take.len(), newest))
}

/// Keep the events of the last [`KEEP_DAYS`], then only the newest lines that fit in `keep_bytes`.
/// RFC 3339 stamps of one zone sort as text.
fn prune(path: &std::path::Path, keep_bytes: usize) -> std::io::Result<()> {
    let cut = (chrono::Local::now() - chrono::Duration::days(KEEP_DAYS)).to_rfc3339();
    let text = fs::read_to_string(path)?;
    let recent: Vec<&str> = text
        .lines()
        .filter(|l| l.get(7..7 + cut.len()).is_some_and(|ts| ts >= &cut[..]))
        .collect();
    let mut size = 0;
    let from = recent
        .iter()
        .rposition(|l| {
            size += l.len() + 1;
            size > keep_bytes
        })
        .map_or(0, |i| i + 1);
    let kept: String = recent[from..].iter().map(|l| format!("{l}\n")).collect();
    crate::md::write_atomic(path, &kept).map_err(std::io::Error::other)
}

/// Every event on `day` (`YYYY-MM-DD`), oldest first. A line that does not parse is skipped.
/// `ts` is serialized first, so a line from another day is passed over without parsing it:
/// `notes today` reads this on every shell start.
pub fn on_day(p: &Profile, day: &str) -> Vec<Event> {
    read_day(p, day).0
}

fn read_day(p: &Profile, day: &str) -> (Vec<Event>, Vec<Reject>) {
    let head = format!("{{\"ts\":\"{day}");
    read(p, |l| l.starts_with(&head))
}

/// Every event the record holds, oldest first.
pub fn all(p: &Profile) -> Vec<Event> {
    read(p, |_| true).0
}

/// The events of the last `days` local days (today included), oldest first.
pub fn recent(p: &Profile, days: i64) -> Vec<Event> {
    read_since(p, days).0
}

fn read_since(p: &Profile, days: i64) -> (Vec<Event>, Vec<Reject>) {
    let cut = (chrono::Local::now() - chrono::Duration::days(days - 1))
        .format("%Y-%m-%d")
        .to_string();
    read(p, |l| l.get(7..17).is_some_and(|d| d >= &cut[..]))
}

/// A line of the record that does not read as an event (a torn write), as `notes log --json`
/// prints it so comms-lint counts it: dated by the event before it.
#[derive(Serialize, Debug, PartialEq)]
pub struct Reject {
    pub ts: String,
    pub text: String,
    pub reject: &'static str,
}

/// The record's lines that `keep` picks, as events, and the ones that do not read.
fn read(p: &Profile, keep: impl Fn(&str) -> bool) -> (Vec<Event>, Vec<Reject>) {
    let (mut events, mut rejects) = (vec![], vec![]);
    let text = fs::read_to_string(path(p)).unwrap_or_default();
    for l in text.lines().filter(|l| keep(l)) {
        match serde_json::from_str::<Event>(l) {
            Ok(e) => events.push(e),
            Err(_) => rejects.push(Reject {
                ts: events
                    .last()
                    .map(|e: &Event| e.ts.clone())
                    .unwrap_or_default(),
                text: l.to_string(),
                reject: "a record line that does not read as an event",
            }),
        }
    }
    // Oldest first by instant, whatever order the lines came in: an imported worker event is
    // appended after newer local ones.
    events.sort_by_key(|e| chrono::DateTime::parse_from_rfc3339(&e.ts).ok());
    (events, rejects)
}

/// What `notes log` shows: every set field narrows it.
#[derive(Default)]
pub struct Filter {
    pub project: Option<String>,
    pub id: Option<String>,
    pub action: Option<String>,
    pub by: Option<String>,
    pub item: Option<String>,
}

impl Filter {
    /// A filter on the flags of `notes log`; a project is read through its canonical name.
    pub fn new(
        project: Option<String>,
        id: Option<String>,
        action: Option<String>,
        by: Option<String>,
        item: Option<String>,
    ) -> Self {
        Filter {
            project: project.map(|n| project_map::canonical(&n)),
            id,
            action,
            by,
            item,
        }
    }

    fn is_empty(&self) -> bool {
        self.project.is_none()
            && self.id.is_none()
            && self.action.is_none()
            && self.by.is_none()
            && self.item.is_none()
    }

    fn hits(&self, e: &Event) -> bool {
        let is = |want: &Option<String>, got: &str| want.as_deref().is_none_or(|w| w == got);
        self.project
            .as_deref()
            .is_none_or(|w| e.from == w || e.to == w)
            && self
                .id
                .as_deref()
                .is_none_or(|w| e.id.as_deref() == Some(w))
            && is(&self.action, &e.action)
            && is(&self.by, &e.by)
            && self
                .item
                .as_deref()
                .is_none_or(|w| e.item.as_deref() == Some(w))
    }
}

/// One event as `notes log` prints it.
pub fn log_line(e: &Event) -> String {
    let at = e.ts.get(..16).unwrap_or(&e.ts).replace('T', " ");
    let id = e.id.as_deref().map(|i| format!(" {i}")).unwrap_or_default();
    let place = match (e.from.as_str(), e.to.as_str()) {
        (f, t) if t.is_empty() || t == f => f.to_string(),
        (f, t) => format!("{f} -> {t}"),
    };
    let lane = if e.lane.is_empty() {
        String::new()
    } else {
        format!(" ({})", e.lane)
    };
    let by = if e.by.is_empty() {
        String::new()
    } else {
        format!(" by {}", e.by)
    };
    let words = e.row.as_deref().unwrap_or(&e.text);
    let why = e
        .why
        .as_deref()
        .map(|w| format!(" [{w}]"))
        .unwrap_or_default();
    format!("{at} {}{id} {place}{lane}{by}: {words}{why}", e.action)
}

/// `notes log`: the events of `day`, or of the last `days`, today when neither is given.
pub fn log(
    p: &Profile,
    day: Option<&str>,
    days: Option<i64>,
    filter: &Filter,
    json: bool,
) -> anyhow::Result<i32> {
    let (events, rejects) = match (day, days) {
        (Some(d), _) => read_day(p, d),
        (None, Some(n)) => read_since(p, n),
        (None, None) => read_since(p, 1),
    };
    print(events.iter().filter(|e| filter.hits(e)), json)?;
    // A line that does not read has no fields to filter on, so only the unfiltered log has it.
    if json && filter.is_empty() {
        for r in &rejects {
            println!("{}", serde_json::to_string(r)?);
        }
    }
    Ok(0)
}

/// `notes log --trace`: one line's whole path, capture to merge. The seeds are the events whose
/// words hold `words` (any case) or whose row id is `words`; the trace is every event of the
/// rows they were filed as or joined, and of the queue items those rows became, oldest first.
pub fn trace(p: &Profile, words: &str, json: bool) -> anyhow::Result<i32> {
    let events = all(p);
    let hits = traced(&events, words);
    if hits.is_empty() {
        eprintln!("no event in the record matches '{words}' (it keeps {KEEP_DAYS} days)");
        return Ok(1);
    }
    print(hits, json)?;
    Ok(0)
}

/// The events as `notes log` prints them: a line each, or one JSON object each.
fn print<'a>(events: impl IntoIterator<Item = &'a Event>, json: bool) -> anyhow::Result<()> {
    for e in events {
        if json {
            println!("{}", serde_json::to_string(e)?);
        } else {
            println!("{}", log_line(e));
        }
    }
    Ok(())
}

fn traced<'a>(events: &'a [Event], words: &str) -> Vec<&'a Event> {
    use std::collections::HashSet;
    let want = words.trim().to_lowercase();
    if want.is_empty() {
        return vec![];
    }
    let says = |e: &Event| {
        e.text.to_lowercase().contains(&want)
            || e.row
                .as_deref()
                .is_some_and(|r| r.to_lowercase().contains(&want))
    };
    let ids: HashSet<&str> = events
        .iter()
        .filter(|e| says(e) || e.id.as_deref() == Some(want.as_str()))
        .filter_map(|e| e.id.as_deref())
        .collect();
    let of_ids = |e: &&Event| e.id.as_deref().is_some_and(|i| ids.contains(i));
    let items: HashSet<&str> = events
        .iter()
        .filter(of_ids)
        .filter_map(|e| e.item.as_deref())
        .collect();
    // The words the rows were filed from, so an id's trace starts at the capture (its `moved`).
    let lines: HashSet<&str> = events
        .iter()
        .filter(of_ids)
        .filter(|e| matches!(e.action.as_str(), "filed" | "dup"))
        .map(|e| e.text.as_str())
        .collect();
    events
        .iter()
        .filter(|e| {
            says(e)
                || of_ids(e)
                || (e.is_intake() && lines.contains(e.text.as_str()))
                || e.item.as_deref().is_some_and(|i| items.contains(i))
        })
        .collect()
}

/// A row's words as the record keeps them: its text without the hashtags, so a tag edit
/// (`#plan` off, a size) leaves them as filed, and a new type, area or title does not.
pub fn row_words(line: &str) -> String {
    let text = crate::md::task_text(line);
    let words: Vec<&str> = text
        .split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .collect();
    words.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_import_takes_only_the_item_lines_it_lacks_and_reports_the_newest_instant() {
        let line = |ts: &str, item: Option<&str>| {
            serde_json::to_string(&Event {
                ts: ts.to_string(),
                item: item.map(str::to_string),
                ..Event::new("item-moved", "ar", "done", "t")
            })
            .unwrap()
        };
        let held = line("2026-11-23T12:00:00-08:00", Some("a"));
        let new = line("2026-11-23T12:05:00-08:00", Some("a"));
        let itemless = line("2026-11-23T12:09:00-08:00", None);
        let input = format!("{held}\n{new}\n{itemless}\nnot json\n");
        let have = std::collections::HashSet::from([held.as_str()]);
        let (take, newest) = lines_to_import(&have, &input);
        assert_eq!(take, vec![new.as_str()]);
        assert_eq!(
            newest.as_deref(),
            Some("2026-11-23T10:09:00.000000000-08:00")
        );
        let (again, _) = lines_to_import(
            &std::collections::HashSet::from([held.as_str(), new.as_str()]),
            &input,
        );
        assert!(again.is_empty());
        // The same line twice in one input is taken once.
        let doubled = format!("{new}\n{new}\n");
        let (twice, _) = lines_to_import(&Default::default(), &doubled);
        assert_eq!(twice.len(), 1);
    }

    #[test]
    fn a_trace_follows_a_line_to_its_row_and_the_item_it_became() {
        let ev = |action: &str, text: &str, id: Option<&str>, item: Option<&str>| Event {
            id: id.map(str::to_string),
            item: item.map(str::to_string),
            ..Event::new(action, "outbox", "demo", text)
        };
        let record = vec![
            ev("moved", "The menu Flickers", None, None),
            ev("filed", "The menu Flickers", Some("de-4"), None),
            ev("filed", "an unrelated line", Some("de-5"), None),
            ev("started", "fix(ui): no flicker", Some("de-4"), None),
            ev("item-added", "no flicker", Some("de-4"), Some("fix-menu")),
            ev("merged", "PR 12", None, Some("fix-menu")),
            ev("merged", "PR 13", None, Some("other")),
        ];
        let actions = |words: &str| -> Vec<String> {
            traced(&record, words)
                .iter()
                .map(|e| format!("{} {}", e.action, e.text))
                .collect()
        };
        let path = [
            "moved The menu Flickers",
            "filed The menu Flickers",
            "started fix(ui): no flicker",
            "item-added no flicker",
            "merged PR 12",
        ];
        assert_eq!(actions("menu flickers"), path);
        assert_eq!(actions("de-4"), path);
        assert!(actions("  ").is_empty());
        assert!(actions("nothing like it").is_empty());
    }

    #[test]
    fn a_write_belongs_to_the_queue_item_then_the_session_then_the_runner_then_the_human() {
        let r = Some("inbox-triage");
        assert_eq!(by(Some("fix-menu"), Some("6e736295-7629"), r), "fix-menu");
        assert_eq!(by(None, Some("6e736295-7629"), r), "6e736295");
        assert_eq!(by(None, None, r), "inbox-triage");
        assert_eq!(by(Some(" "), None, Some("")), "human");
        assert_eq!(by(None, None, None), "human");
    }

    #[test]
    fn a_row_write_is_the_backlog_stage_and_done_carries_its_pr_and_sha() {
        let e = Event::row("done", "ar", "", "agent", "- [x] a <!-- id:ar-1 -->")
            .proof("pr:1080 commit:becad5bb1234");
        assert_eq!(e.stage.as_deref(), Some("backlog"));
        assert_eq!(e.id.as_deref(), Some("ar-1"));
        let capture = Event::row("added", "outbox", "", "", "- [ ] a capture");
        assert_eq!(capture.stage.as_deref(), Some("intake"));
        assert_eq!(
            (e.pr.as_deref(), e.sha.as_deref()),
            (Some("1080"), Some("becad5bb1234"))
        );
        let u = Event::row("done", "ar", "", "agent", "- [x] a").proof("unverified: no PR");
        assert_eq!((u.pr, u.sha), (None, None));
    }

    #[test]
    fn only_intake_and_row_writes_are_intake() {
        let mut e = Event::new("filed", "outbox", "ar", "t");
        assert!(e.is_intake());
        e.stage = None;
        assert!(e.is_intake(), "a line from before stage");
        for s in CHAIN_STAGES {
            e.stage = Some(s.into());
            assert!(!e.is_intake(), "{s}");
        }
        let json = serde_json::to_string(&Event::new("left", "a", "", "t")).unwrap();
        assert!(
            !json.contains("\"pr\""),
            "unset chain fields stay off the line: {json}"
        );
    }

    #[test]
    fn a_line_from_before_by_still_parses() {
        let old = r#"{"ts":"2026-11-05T10:53:09-08:00","action":"filed","from":"a","text":"t"}"#;
        assert_eq!(serde_json::from_str::<Event>(old).unwrap().by, "");
    }

    #[test]
    fn a_log_line_says_what_where_who_and_why() {
        let mut e = Event::row(
            "rehomed",
            "ucp",
            "home-config",
            "agent",
            "- [ ] fix(runners): a pool #low <!-- id:ar-302 -->",
        );
        e.ts = "2026-11-05T11:14:50-08:00".into();
        e.by = "6e736295".into();
        e.why = Some("hosts live there".into());
        assert_eq!(
            log_line(&e),
            "2026-11-05 11:14 rehomed ar-302 ucp -> home-config (agent) by 6e736295: \
             fix(runners): a pool [hosts live there]"
        );
    }

    #[test]
    fn a_filter_matches_either_end_of_a_move_and_narrows_on_each_field() {
        let e = Event::row("rehomed", "ucp", "hc", "agent", "- [ ] a <!-- id:ucp-1 -->");
        let f = |project: Option<&str>, id: Option<&str>| Filter {
            project: project.map(Into::into),
            id: id.map(Into::into),
            ..Default::default()
        };
        assert!(f(None, None).hits(&e));
        let mut q = e.clone();
        q.item = Some("p5".into());
        let it = |i: &str| Filter {
            item: Some(i.into()),
            ..Default::default()
        };
        assert!(it("p5").hits(&q) && !it("p6").hits(&q) && !it("p5").hits(&e));
        assert!(f(Some("ucp"), None).hits(&e));
        assert!(f(Some("hc"), Some("ucp-1")).hits(&e));
        assert!(!f(Some("other"), None).hits(&e));
        assert!(!f(None, Some("ucp-2")).hits(&e));
    }

    #[test]
    fn events_round_trip_and_read_back_by_day() {
        let dir = std::env::temp_dir().join(format!("ingest-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = crate::config::test_profile(dir.to_str().unwrap());
        let mut ev = Event::new("filed", "outbox", "dodginballs", " the gun sound is late ");
        ev.lane = "human".into();
        ev.id = Some("db-12".into());
        record(&p, &ev);
        let mut old = Event::new("left", "nc", "", "a thought");
        old.ts = "2026-01-01T09:00:00-08:00".into();
        record(&p, &old);
        let got = on_day(&p, &ev.ts[..10]);
        assert_eq!(
            got,
            vec![Event {
                text: "the gun sound is late".into(),
                ..ev
            }]
        );
        assert_eq!(on_day(&p, "2026-01-01").len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_prune_whose_kept_days_still_run_over_keeps_only_the_newest_bytes() {
        let dir = std::env::temp_dir().join(format!("ingest-prune-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = crate::config::test_profile(dir.to_str().unwrap());
        for n in 0..10 {
            record(
                &p,
                &Event::new("filed", "outbox", "nc", &format!("row {n}")),
            );
        }
        let before = fs::read_to_string(path(&p)).unwrap();
        // The newest three lines exactly: a stamp's fraction is trimmed, so lines differ in length.
        let target: usize = before.lines().rev().take(3).map(|l| l.len() + 1).sum();
        prune(&path(&p), target).unwrap();
        let after = fs::read_to_string(path(&p)).unwrap();
        assert!(after.len() <= target, "cut under the target");
        let texts: Vec<String> = after
            .lines()
            .map(|l| serde_json::from_str::<Event>(l).unwrap().text)
            .collect();
        assert_eq!(
            texts,
            ["row 7", "row 8", "row 9"],
            "the newest kept, in order"
        );
        prune(&path(&p), usize::MAX).unwrap();
        assert_eq!(
            fs::read_to_string(path(&p)).unwrap(),
            after,
            "under the target, nothing goes"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_torn_line_is_a_reject_dated_by_the_event_before_it() {
        let dir = std::env::temp_dir().join(format!("ingest-torn-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = crate::config::test_profile(dir.to_str().unwrap());
        let ev = Event::new("filed", "outbox", "nc", "a row");
        record(&p, &ev);
        let day = &ev.ts[..10];
        let torn = format!("{{\"ts\":\"{day}T23:59:00-08:00\",\"action\":\"fi");
        let mut f = fs::OpenOptions::new().append(true).open(path(&p)).unwrap();
        writeln!(f, "{torn}").unwrap();
        let (events, rejects) = read_since(&p, 1);
        assert_eq!(events.len(), 1);
        assert_eq!(rejects.len(), 1);
        assert_eq!(
            (rejects[0].ts.as_str(), rejects[0].text.as_str()),
            (ev.ts.as_str(), torn.as_str())
        );
        assert!(read_day(&p, day).1.len() == 1, "the day read keeps it too");
        assert_eq!(all(&p).len(), 1, "callers that want events see only events");
        let _ = fs::remove_dir_all(&dir);
    }
}
