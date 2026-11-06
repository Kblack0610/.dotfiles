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
    /// Intake: `moved` (outbox or Focus -> an inbox), `filed`, `dup`, `planned`, `left` (waits
    /// for the human) or `refused` (a write the CLI turned down). A verb's write to a row:
    /// `added`, `edited`, `detailed`, `tagged`, `started`, `unstarted`, `toggled` (a Focus row), `done`, `dropped`, `placed` (another
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
    /// Why it stayed, for `left` and `refused`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// For `filed`: the first row's words as filed ([`row_words`]), which [`kept`] compares
    /// with the row's words now. For `edited`: the row's new words.
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
    /// The agent-queue item the write belongs to or names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    /// The tracker ticket the item or row carries.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
    /// The Claude session that wrote it, in full.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The pull request, `owner/repo#N` or a bare number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
    /// The merge commit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha: Option<String>,
}

/// `v` trimmed, or `None` when that leaves nothing.
pub fn set(v: Option<&str>) -> Option<String> {
    v.map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// The stages that are not intake: the inbox page and the board channel read only intake.
pub const CHAIN_STAGES: [&str; 3] = ["queue", "dispatch", "land"];

impl Event {
    pub fn new(action: &str, from: &str, to: &str, text: &str) -> Self {
        let env = |k: &str| std::env::var(k).ok();
        let (item, session) = (env("AGENT_QUEUE_ITEM"), env("CLAUDE_CODE_SESSION_ID"));
        Event {
            ts: chrono::Local::now().to_rfc3339(),
            action: action.into(),
            from: from.into(),
            to: to.into(),
            text: text.trim().into(),
            by: by(item.as_deref(), session.as_deref()),
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

/// Who a write belongs to: the queue item, else the session's first 8 characters, else `human`.
fn by(item: Option<&str>, session: Option<&str>) -> String {
    set(item)
        .or_else(|| set(session).map(|s| s.chars().take(8).collect()))
        .unwrap_or_else(|| "human".into())
}

pub fn path(p: &Profile) -> PathBuf {
    p.state_dir.join("ingest.jsonl")
}

/// Past this size the record is cut to its last [`KEEP_DAYS`], so the page's read stays cheap.
/// Well over those days' usual size (about 1400 writes a day, 11 MB), because a record that sits
/// at the cap is rewritten on every append.
const MAX_BYTES: u64 = 32 * 1024 * 1024;
const KEEP_DAYS: i64 = 30;

/// Append `ev`. Best effort, like the inbox flag: a record that cannot be written must not
/// fail the move it describes, so the error goes to stderr and the write stands.
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
            prune(&path)?;
        }
        Ok(())
    })();
    if let Err(e) = res {
        eprintln!("ingest record not written ({}): {e}", path.display());
    }
}

/// Keep the events of the last [`KEEP_DAYS`]. RFC 3339 stamps of one zone sort as text.
fn prune(path: &std::path::Path) -> std::io::Result<()> {
    let cut = (chrono::Local::now() - chrono::Duration::days(KEEP_DAYS)).to_rfc3339();
    let kept: String = fs::read_to_string(path)?
        .lines()
        .filter(|l| l.get(7..7 + cut.len()).is_some_and(|ts| ts >= &cut[..]))
        .map(|l| format!("{l}\n"))
        .collect();
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

/// Every event of the last `days` days, today included, oldest first.
pub fn since(p: &Profile, days: i64) -> Vec<Event> {
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
    for e in events.iter().filter(|e| filter.hits(e)) {
        if json {
            println!("{}", serde_json::to_string(e)?);
        } else {
            println!("{}", log_line(e));
        }
    }
    // A line that does not read has no fields to filter on, so only the unfiltered log has it.
    if json && filter.is_empty() {
        for r in &rejects {
            println!("{}", serde_json::to_string(r)?);
        }
    }
    Ok(0)
}

/// A row's words as [`kept`] compares them: its text without the hashtags, so the planner's
/// tag edits (`#plan` off, a size) leave a filing kept, and a new type, area or title does not.
pub fn row_words(line: &str) -> String {
    let text = crate::md::task_text(line);
    let words: Vec<&str> = text
        .split_whitespace()
        .filter(|w| !w.starts_with('#'))
        .collect();
    words.join(" ")
}

/// Where a row is now: its project, its lane, and its line.
pub struct Found {
    pub project: String,
    pub lane: &'static str,
    pub line: String,
}

/// How many of `events`' filings still stand as filed, of how many: a filing is kept when its
/// row is in the project and lane it was filed to, not dropped or closed as a dup, with its
/// words unchanged. Open, in progress and done all count. Counted, never judged by a model:
/// the human's edits are the label.
pub fn kept(events: &[Event], rows: &std::collections::HashMap<String, Found>) -> (usize, usize) {
    let filed: Vec<(&Event, &str)> = events
        .iter()
        .filter(|e| e.action == "filed")
        .filter_map(|e| Some((e, e.id.as_deref()?)))
        .collect();
    let kept = filed
        .iter()
        .filter(|(e, id)| {
            rows.get(*id).is_some_and(|f| {
                f.project == e.to
                    && f.lane == e.lane
                    && crate::md::marker_token(&f.line, "dropped:").is_none()
                    && crate::md::marker_token(&f.line, "dup:").is_none()
                    && e.row.as_deref().is_none_or(|w| row_words(&f.line) == w)
            })
        })
        .count();
    (kept, filed.len())
}

/// The rows with one of `ids`, from every `.md` under each project dir (both lanes and the
/// `versions/` archive, so a row closed and released still counts).
pub fn find_rows(
    dirs: &[(String, PathBuf)],
    ids: &std::collections::HashSet<&str>,
) -> std::collections::HashMap<String, Found> {
    let mut out = std::collections::HashMap::new();
    if ids.is_empty() {
        return out;
    }
    for (project, dir) in dirs {
        let agent = crate::agent_sheet::Lane::Agent.dir(dir);
        let mut stack = vec![dir.clone()];
        while let Some(d) = stack.pop() {
            let Ok(entries) = fs::read_dir(&d) else {
                continue;
            };
            for e in entries.flatten() {
                let path = e.path();
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    stack.push(path);
                    continue;
                }
                if path.extension().is_none_or(|x| x != "md") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                let lane = if path.starts_with(&agent) {
                    "agent"
                } else {
                    "human"
                };
                for line in text.lines().filter(|l| l.contains("id:")) {
                    let Some(id) = crate::md::row_id(line) else {
                        continue;
                    };
                    if ids.contains(id.as_str()) {
                        out.entry(id).or_insert_with(|| Found {
                            project: project.clone(),
                            lane,
                            line: line.to_string(),
                        });
                    }
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_belongs_to_the_queue_item_then_the_session_then_the_human() {
        assert_eq!(by(Some("fix-menu"), Some("6e736295-7629")), "fix-menu");
        assert_eq!(by(None, Some("6e736295-7629")), "6e736295");
        assert_eq!(by(Some(" "), None), "human");
        assert_eq!(by(None, None), "human");
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
    fn a_filing_is_kept_only_where_it_was_filed_with_its_words() {
        let dir = std::env::temp_dir().join(format!("ingest-kept-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let proj = dir.join("demo");
        fs::create_dir_all(proj.join("agent")).unwrap();
        fs::create_dir_all(proj.join("versions")).unwrap();
        fs::write(
            proj.join("README.md"),
            "## Tasks\n\
             - [ ] fix(ui): the menu flickers #low <!-- id:dm-1 filed:2026-11-05 -->\n\
             - [ ] feat(kit): a brand kit #size/l #high <!-- id:dm-2 filed:2026-11-05 -->\n\
             - [x] fix(ui): a stale thing <!-- id:dm-3 dropped: stale -->\n\
             - [x] fix(ui): the same thing <!-- id:dm-4 dup:dm-1 -->\n\
             - [ ] fix(ui): a new title <!-- id:dm-5 -->\n\
             - [ ] fix(ui): went human <!-- id:dm-6 -->\n",
        )
        .unwrap();
        fs::write(
            proj.join("versions").join("v0.1.0.md"),
            "- [x] fix(ui): shipped <!-- id:dm-7 pr:12 -->\n",
        )
        .unwrap();
        fs::write(
            proj.join("agent").join("README.md"),
            "## Tasks\n- [ ] ci(gate): a gate <!-- id:dm-8 -->\n",
        )
        .unwrap();
        let filing = |id: &str, lane: &str, row: Option<&str>| {
            let mut e = Event::new("filed", "demo", "demo", "words");
            e.lane = lane.into();
            e.id = Some(id.into());
            e.row = row.map(str::to_string);
            e
        };
        let mut moved = filing("dm-1", "human", None);
        moved.to = "other".into();
        let events = vec![
            filing("dm-1", "human", Some("fix(ui): the menu flickers")),
            // The planner's tag edits leave it kept.
            filing("dm-2", "human", Some("feat(kit): a brand kit")),
            filing("dm-3", "human", None),
            filing("dm-4", "human", None),
            filing("dm-5", "human", Some("fix(ui): the old title")),
            filing("dm-6", "agent", None),
            filing("dm-7", "human", Some("fix(ui): shipped")),
            filing("dm-8", "agent", Some("ci(gate): a gate")),
            filing("dm-9", "human", None),
            moved,
            Event::new("left", "demo", "", "a thought"),
        ];
        let ids: std::collections::HashSet<&str> =
            events.iter().filter_map(|e| e.id.as_deref()).collect();
        let rows = find_rows(&[("demo".into(), proj)], &ids);
        assert_eq!(rows["dm-8"].lane, "agent");
        assert_eq!(rows["dm-7"].lane, "human");
        // Kept: dm-1, dm-2, dm-7 (done and released), dm-8. Not: dropped dm-3, dup dm-4,
        // retitled dm-5, other lane dm-6, gone dm-9, other project.
        assert_eq!(kept(&events, &rows), (4, 10));
        let _ = fs::remove_dir_all(&dir);
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
        assert_eq!(
            since(&p, 1).len(),
            1,
            "callers that want events see only events"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
