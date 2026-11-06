//! Everything the fleet's machinery did, as one newest-first list, for Log's Actions section on both hub surfaces
//! and `hub actions` (the briefing's digest). It only reads the ledgers their own tools write,
//! and keeps no copy of any:
//!
//! | source         | written by                         | read for                                  |
//! |----------------|------------------------------------|-------------------------------------------|
//! | `shepherd-log` | `fleet-shepherd log` and `skip`    | nudges, escalations, skips, overdue, ...  |
//! | `dispatch-log` | `fleet-dispatch`                   | sessions started and items reaped         |
//! | `notify`       | `agent-notify`                     | every page, with its priority             |
//! | `runs`         | agentctl (`runs.jsonl`)            | runner runs that FAILED or STALLED        |
//! | `queue`        | `agent-queue` (through `queue::list`) | items queued and finished              |
//!
//! Queue starts are not read from the queue: the dispatch log already records them.

use std::collections::BTreeMap;
use std::path::PathBuf;

use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, TimeZone};
use serde::Serialize;

use crate::jobs::read_or_empty;
use crate::queue::Item;

/// Actions sent to a caller, newest first. `Gathered::counts` still counts the whole window.
pub const MAX_ACTIONS: usize = 1000;

/// One thing an actor did.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Action {
    /// Epoch seconds.
    pub at: i64,
    /// `shepherd`, `dispatch`, `sentinel`, `hold`, `park`, `agentctl`, `human`, `board`, ...
    pub actor: String,
    /// `nudge`, `escalate`, `skip`, `start`, `reap`, `tripped`, `page`, `failed`, `queue`, ...
    pub verb: String,
    pub text: String,
    /// The page's priority, for an agent-notify action.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    /// Where an agent-notify page points (`tmux:`, `ask:`, `pr:`, `file:`, `url:`), as its
    /// sender wrote it; `agent-notify open` is what resolves it.
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
    /// Which ledger said so (the module table).
    pub source: String,
}

impl Action {
    fn new(at: i64, actor: &str, verb: &str, text: &str, source: &str) -> Action {
        Action {
            at,
            actor: actor.into(),
            verb: verb.into(),
            text: text.into(),
            priority: None,
            reference: None,
            source: source.into(),
        }
    }
}

/// A ledger line its parser could not read. It is kept so a lint can count it
/// (comms-lint's `fleet-log` channel) instead of the line vanishing.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Reject {
    /// Epoch seconds of the last line read before it: the line has no readable time of its own.
    pub at: i64,
    /// Which ledger it is in (the module table).
    pub source: String,
    /// The line as written.
    pub text: String,
    /// Why it was not read.
    pub reject: String,
}

impl Reject {
    fn new(at: i64, source: &str, line: &str, why: &str) -> Reject {
        Reject {
            at,
            source: source.into(),
            text: line.into(),
            reject: why.into(),
        }
    }
}

/// actor -> verb -> how many.
pub type Counts = BTreeMap<String, BTreeMap<String, u64>>;

/// The ledger files, by the same variables their writers resolve.
#[derive(Clone, Debug)]
pub struct Paths {
    pub shepherd_log: PathBuf,
    pub dispatch_log: PathBuf,
    pub notify_log: PathBuf,
    pub runs: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let notify_log = std::env::var_os("AGENT_NOTIFY_LOG")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/state/agent-notify/log"));
        Paths {
            shepherd_log: crate::boards::shepherd_dir().join("log.md"),
            dispatch_log: crate::boards::dispatch_dir().join("log.md"),
            notify_log,
            runs: crate::jobs::Paths::from_env().agentctl.join("runs.jsonl"),
        }
    }
}

#[derive(Serialize, Debug, Default, PartialEq)]
pub struct Gathered {
    /// Newest first, at most `MAX_ACTIONS`.
    pub actions: Vec<Action>,
    /// Every action in the window, not only the ones sent.
    pub counts: Counts,
    /// A ledger that could not be read. A missing one is just empty.
    pub errors: Vec<String>,
    /// Lines in a readable ledger that its parser could not read, newest first.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub rejects: Vec<Reject>,
}

/// Every queue item, live from `agent-queue`, for joining the ledgers to; an unread queue is an
/// error line beside an empty list, so the ledgers still show.
pub fn queue_items() -> (Vec<Item>, Option<String>) {
    match crate::queue::list(&crate::session_actions::System, "all") {
        Ok(items) => (items, None),
        Err(e) => (vec![], Some(format!("agent-queue list: {e}"))),
    }
}

/// `gather` over this host's ledgers and live queue: what Log's Actions section shows on both
/// surfaces.
pub fn read(since: i64) -> Gathered {
    let (items, err) = queue_items();
    let mut g = gather(&Paths::from_env(), since, &items);
    g.errors.extend(err);
    g
}

/// Every action at or after `since` (epoch seconds), with the dispatch log's times read as this
/// host's local time.
pub fn gather(paths: &Paths, since: i64, items: &[Item]) -> Gathered {
    gather_in(paths, since, items, &chrono::Local)
}

/// `gather`, with the dispatch log's local times read in `tz`.
pub fn gather_in<Tz: TimeZone>(paths: &Paths, since: i64, items: &[Item], tz: &Tz) -> Gathered {
    let mut g = window_in(paths, since, items, tz);
    g.actions.truncate(MAX_ACTIONS);
    g.rejects.truncate(MAX_ACTIONS);
    g
}

/// Every action and reject at or after `since`, none dropped: what `hub actions --records` streams.
pub fn window(paths: &Paths, since: i64, items: &[Item]) -> Gathered {
    window_in(paths, since, items, &chrono::Local)
}

/// `window`, with the dispatch log's local times read in `tz`.
pub fn window_in<Tz: TimeZone>(paths: &Paths, since: i64, items: &[Item], tz: &Tz) -> Gathered {
    let mut errors = vec![];
    let mut read = |p: &PathBuf| {
        read_or_empty(p).unwrap_or_else(|e| {
            errors.push(e);
            String::new()
        })
    };
    let (shepherd, dispatch, notify, runs) = (
        read(&paths.shepherd_log),
        read(&paths.dispatch_log),
        read(&paths.notify_log),
        read(&paths.runs),
    );
    let (failed, bad) = failed_runs(&runs);
    if bad > 0 {
        errors.push(format!(
            "{bad} unreadable line(s) in {} skipped",
            paths.runs.display()
        ));
    }
    let ((sa, sr), (da, dr), (na, nr)) = (
        parse_shepherd(&shepherd),
        parse_dispatch(&dispatch, tz),
        parse_notify(&notify),
    );
    let mut all: Vec<Action> = [sa, da, na, failed, from_queue(items)]
        .into_iter()
        .flatten()
        .filter(|a| a.at >= since)
        .collect();
    let mut rejects: Vec<Reject> = [sr, dr, nr]
        .into_iter()
        .flatten()
        .filter(|r| r.at >= since)
        .collect();
    // Within a ledger a later line is the newer one, so reverse first and sort stably.
    all.reverse();
    all.sort_by_key(|a| std::cmp::Reverse(a.at));
    rejects.reverse();
    rejects.sort_by_key(|r| std::cmp::Reverse(r.at));
    let counts = counts(&all);
    Gathered {
        actions: all,
        counts,
        errors,
        rejects,
    }
}

pub fn counts(actions: &[Action]) -> Counts {
    let mut c = Counts::new();
    for a in actions {
        *c.entry(a.actor.clone())
            .or_default()
            .entry(a.verb.clone())
            .or_default() += 1;
    }
    c
}

/// The per-pass tally: a `counts:` or `buckets:` line (the pass writes it by hand, so its shape
/// varies), or a bare `DONE 1, LANDED 2, WORKING 25` row. A tally, not an action.
fn is_counts(s: &str) -> bool {
    if s.starts_with("counts:") || s.starts_with("buckets:") {
        return true;
    }
    s.split(", ").all(|cell| {
        cell.split_once(' ').is_some_and(|(w, n)| {
            !w.is_empty()
                && w.chars().all(|c| c.is_ascii_uppercase())
                && !n.is_empty()
                && n.chars().all(|c| c.is_ascii_digit())
        })
    })
}

fn shepherd_verb(s: &str) -> &'static str {
    let mut words = s.split_whitespace();
    let (first, rest) = (words.next().unwrap_or(""), words.collect::<Vec<_>>());
    if first.starts_with("nudge") {
        "nudge"
    } else if first.starts_with("escalat") {
        "escalate"
    } else if first.starts_with("skip") {
        "skip"
    } else if s.starts_with("marked overdue") {
        "overdue"
    } else if s.starts_with("rundown:") {
        "rundown"
    } else if first.starts_with("watch") {
        "watch"
    } else if s.starts_with("wound down") || rest.starts_with(&["wound", "down"]) {
        // `wound down ...` or `<session> wound down ...`
        "wind-down"
    } else {
        "note"
    }
}

/// `fleet-shepherd`'s `log.md`: `## YYYY-MM-DD HH:MM UTC <what>` headings give the year, and each
/// entry is `- HH:MM UTC MM-DD: <text>`. An entry in another shape under a dated heading is a
/// reject; prose and indented lines between entries belong to the entry above.
pub fn parse_shepherd(text: &str) -> (Vec<Action>, Vec<Reject>) {
    const SHAPE: &str = "a log entry not in the shape - HH:MM UTC MM-DD: <text>";
    let mut head: Option<NaiveDate> = None;
    let (mut out, mut rejects, mut last) = (vec![], vec![], 0);
    for line in text.lines() {
        if let Some(h) = line.strip_prefix("## ") {
            if let Some(d) = h.get(..10).and_then(|d| d.parse::<NaiveDate>().ok()) {
                head = Some(d);
                last = d
                    .and_hms_opt(0, 0, 0)
                    .map_or(last, |t| t.and_utc().timestamp());
            }
            continue;
        }
        let Some(e) = line.strip_prefix("- ") else {
            continue;
        };
        let reject = |rejects: &mut Vec<Reject>| {
            if head.is_some() {
                rejects.push(Reject::new(last, "shepherd-log", line, SHAPE));
            }
        };
        let (Some(hm), Some(" UTC "), Some(md), Some(": "), Some(body), Some(head)) = (
            e.get(..5),
            e.get(5..10),
            e.get(10..15),
            e.get(15..17),
            e.get(17..),
            head,
        ) else {
            reject(&mut rejects);
            continue;
        };
        // An entry after New Year under a heading from December.
        let month: u32 = md.get(..2).and_then(|m| m.parse().ok()).unwrap_or(0);
        let year = head.year() + i32::from(month < head.month());
        let Ok(t) = NaiveDateTime::parse_from_str(&format!("{year}-{md} {hm}"), "%Y-%m-%d %H:%M")
        else {
            reject(&mut rejects);
            continue;
        };
        last = t.and_utc().timestamp();
        if is_counts(body) {
            continue;
        }
        // `fleet-shepherd skip` once logged its raw ledger row: key, role, epoch, `key: why`.
        let (lead, body) = match body.rsplit_once('\t') {
            Some((lead, last)) => (lead, last),
            None => (body, body),
        };
        out.push(Action::new(
            last,
            "shepherd",
            shepherd_verb(lead),
            body,
            "shepherd-log",
        ));
    }
    (out, rejects)
}

/// `fleet-dispatch`'s `log.md`: `- YYYY-MM-DD HH:MM <verb> <rest>`, in the host's local time.
/// Any other non-blank line is a reject.
pub fn parse_dispatch<Tz: TimeZone>(text: &str, tz: &Tz) -> (Vec<Action>, Vec<Reject>) {
    let entry = |l: &str| {
        let e = l.strip_prefix("- ")?;
        let t = NaiveDateTime::parse_from_str(e.get(..16)?, "%Y-%m-%d %H:%M").ok()?;
        let body = e.get(16..)?.trim();
        let verb = match body.split_whitespace().next()? {
            "started" => "start",
            "reaped" => "reap",
            w => w,
        };
        let at = tz.from_local_datetime(&t).earliest()?.timestamp();
        Some(Action::new(at, "dispatch", verb, body, "dispatch-log"))
    };
    read_lines(
        text,
        "dispatch-log",
        "a line not in the shape - YYYY-MM-DD HH:MM <verb> <rest>",
        entry,
    )
}

/// Each non-blank line through `entry`; a line it cannot read is a reject, dated by the line
/// read before it.
fn read_lines(
    text: &str,
    source: &str,
    why: &str,
    entry: impl Fn(&str) -> Option<Action>,
) -> (Vec<Action>, Vec<Reject>) {
    let (mut out, mut rejects, mut last) = (vec![], vec![], 0);
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        match entry(l) {
            Some(a) => {
                last = a.at;
                out.push(a);
            }
            None => rejects.push(Reject::new(last, source, l, why)),
        }
    }
    (out, rejects)
}

/// What a Sentinel page reports, from the shapes watch-companion-loop writes: "<subject> back
/// to normal", a reminder ending "for 5d now.", "<subject> watch cannot check (probe error ...)",
/// and anything else is a trip, whose sentence comes from the manifest. Pages from before the
/// plain wording lead with "[name]" and say TRIPPED or RECOVERED.
fn sentinel_verb(msg: &str) -> &'static str {
    if msg.contains("RECOVERED") || msg.contains(" back to normal") {
        "recovered"
    } else if msg.contains("TRIPPED") {
        "tripped"
    } else if msg.starts_with('[')
        || msg.contains("cannot check (probe error")
        || msg.ends_with(" now.")
        || msg.contains(" now. ")
    {
        "page"
    } else {
        "tripped"
    }
}

/// agent-notify's ledger: `<rfc3339>\t<priority>\t<title>\t<message>[\t<ref>]`. The title says
/// who paged; the ref, when there is one, says where the page points.
/// Any other non-blank line (a message written with a raw newline) is a reject.
pub fn parse_notify(text: &str) -> (Vec<Action>, Vec<Reject>) {
    read_lines(
        text,
        "notify",
        "a line with no ledger fields (a message written with a raw newline)",
        |l| {
            let mut f = l.splitn(5, '\t');
            let (ts, prio, title, msg) = (f.next()?, f.next()?, f.next()?, f.next()?);
            let reference = f.next().filter(|r| !r.is_empty()).map(str::to_string);
            let at = DateTime::parse_from_rfc3339(ts).ok()?.timestamp();
            let (head, target) = match title.split_once(": ") {
                Some((h, t)) => (h, Some(t)),
                None => (title, None),
            };
            let (actor, verb) = match head {
                "Sentinel" => ("sentinel".to_string(), sentinel_verb(msg)),
                "hold" => ("hold".to_string(), "hold"),
                "go" => ("hold".to_string(), "go"),
                "park" => ("park".to_string(), "park"),
                _ => {
                    let w = title.split_whitespace().next().unwrap_or("notify");
                    (w.trim_end_matches(':').to_lowercase(), "page")
                }
            };
            // Sentinel's message names its subject already; anyone else's target leads the text.
            let text = match target {
                Some(t) if head != "Sentinel" => format!("{t}: {msg}"),
                _ => msg.to_string(),
            };
            let mut a = Action::new(at, &actor, verb, &text, "notify");
            a.priority = Some(prio.to_string()).filter(|p| !p.is_empty());
            a.reference = reference;
            Some(a)
        },
    )
}

/// agentctl's runs that FAILED or STALLED, and how many ledger lines could not be read.
pub fn failed_runs(text: &str) -> (Vec<Action>, usize) {
    let (runs, bad) = crate::jobs::systemd::ledger_lines(text);
    let failed = runs
        .into_iter()
        .filter_map(|r| {
            let verb = match r.outcome.as_str() {
                "FAILED" => "failed",
                "STALLED" => "stalled",
                _ => return None,
            };
            let at = if r.finished > 0 {
                r.finished
            } else {
                r.started?
            };
            let text = format!(
                "{} {}: result {}, exit {}",
                r.name, r.outcome, r.result, r.exit
            );
            Some(Action::new(at, "agentctl", verb, &text, "runs"))
        })
        .collect();
    (failed, bad)
}

/// Who queued an item: `human`, `shepherd`, or `board` for any `board:<project>:<key>`.
fn source_of(i: &Item) -> String {
    match i.from.as_deref() {
        None | Some("") => "human".into(),
        Some(f) if f.starts_with("board:") => "board".into(),
        Some(f) => f.into(),
    }
}

/// Queue items queued and finished, from agent-queue's own item headers.
pub fn from_queue(items: &[Item]) -> Vec<Action> {
    let at = |t: &Option<String>| {
        t.as_deref()
            .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
            .map(|t| t.timestamp())
    };
    let mut out = vec![];
    for i in items {
        if let Some(t) = at(&i.queued) {
            let text = format!("{} ({}): {}", i.slug, i.project, i.title());
            out.push(Action::new(t, &source_of(i), "queue", &text, "queue"));
        }
        if let Some(t) = at(&i.finished) {
            let status = i.status.as_deref().unwrap_or("done");
            let text = format!("{} ({}) {status}: {}", i.slug, i.project, i.title());
            out.push(Action::new(t, "queue", "finish", &text, "queue"));
        }
    }
    out
}

/// Verbs a digest lists one by one, not only counts.
const HEADLINE: [&str; 4] = ["escalate", "tripped", "failed", "stalled"];
/// A listed action's text is cut to this many characters.
const DIGEST_TEXT: usize = 160;

/// The briefing's digest: one line per actor with its verb counts, most first, then each
/// escalation, tripped watch and failed run, oldest first, as `- HH:MM <actor> <verb>: <text>`.
pub fn digest(g: &Gathered) -> String {
    digest_in(g, &chrono::Local)
}

pub fn digest_in<Tz: TimeZone>(g: &Gathered, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let mut out = String::new();
    if g.counts.is_empty() {
        out.push_str("nothing recorded\n");
    }
    for (actor, verbs) in &g.counts {
        let mut v: Vec<(&String, &u64)> = verbs.iter().collect();
        v.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        let cells: Vec<String> = v.iter().map(|(verb, n)| format!("{n} {verb}")).collect();
        out.push_str(&format!("{actor}: {}\n", cells.join(", ")));
    }
    for a in g
        .actions
        .iter()
        .rev()
        .filter(|a| HEADLINE.contains(&a.verb.as_str()))
    {
        let hm = tz
            .timestamp_opt(a.at, 0)
            .single()
            .map(|t| t.format("%H:%M").to_string())
            .unwrap_or_default();
        let mut text: String = a.text.chars().take(DIGEST_TEXT).collect();
        if text.len() < a.text.len() {
            text.push_str("...");
        }
        out.push_str(&format!("- {hm} {} {}: {text}\n", a.actor, a.verb));
    }
    for e in &g.errors {
        out.push_str(&format!("unread: {e}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    const SHEPHERD: &str = "## 2026-10-24 (pass 4)
- buckets: STALLED 1, WORKING 11

## 2026-11-04 15:42 UTC pass
- 15:42 UTC 11-04: DONE 1, LANDED 2, NEEDS 10, STALLED 2, UNCLEAR 1, WORKING 15
- 15:42 UTC 11-04: counts: DONE 1, WORKING 3; load 8.6/24, 65% idle
- 15:42 UTC 11-04: counts: NIGHTLY 1 (unchanged), NEEDS 4, WORKING 28
- 15:42 UTC 11-04: buckets: MAIN 1, NEEDS 5, WORKING 26; load 12.8/24
- 15:42 UTC 11-04: nudged hub dotfiles:2 to wind down: all 5 phases done
- 15:43 UTC 11-04: escalated hub dotfiles:9 ask e7A1M1
- 15:44 UTC 11-04: skipped: hub dotfiles:10 (human on it)
- 15:45 UTC 11-04: marked overdue: agent-26 phase 5/6
- 15:46 UTC 11-04: rundown: what needs me? (rundowns/2026-11-04T1549Z.md)
- 15:47 UTC 11-04: watches tripped: playground-nightly (urgent)
- 15:48 UTC 11-04: agent-55 wound down after #1653 merged
- 15:49 UTC 11-04: agent-53 replied: #1623 red is a stale gate line
- 16:28 UTC 11-04: skipped: escalate NEEDS: hub/dotfiles:11 waiting\tshepherd\t1793809608\tescalate NEEDS: hub/dotfiles:11 waiting: no longer waiting
";

    const DISPATCH: &str =
        "- 2026-11-04 08:28 started bnb-agent-1 on lab (run) for bnb: queue item premium-8
- 2026-11-04 08:31 reaped dotfiles: queue item x running -> waiting
- 2026-11-04 08:32 refused dotfiles: no room
not a line
";

    const NOTIFY: &str = "2026-11-04T08:18:29-08:00\turgent\tSentinel: fleet-liveness\t[fleet-liveness] TRIPPED - exit 1
2026-11-04T08:31:58-08:00\thigh\tSentinel: systemd-user-failed\t[systemd-user-failed] RECOVERED - exit 0
2026-11-04T08:32:00-08:00\tnormal\tSentinel: odd\t[odd] something else
2026-11-04T08:33:00-08:00\thigh\tshepherd\tunhandled 40m: nudge STALLED: a:1
2026-11-04T08:34:00-08:00\tnormal\thold: unity\tHOLD set: gate running
2026-11-04T08:35:00-08:00\tnormal\tgo: unity\tGO batch 1
2026-11-04T08:36:00-08:00\tlow\tpark: agent-4\tparked for pace
2026-11-04T08:37:00-08:00\tnormal\task: dotfiles\tpick one
a continuation line of the message above
";

    const RUNS: &str = r#"{"name":"comms","started":1793810046,"finished":1793810123,"result":"success","exit":"0","outcome":"WORKED","out":[0,0],"err":[0,0]}
{"name":"fleet-dispatch","started":1793808989,"finished":1793809001,"result":"exit-code","exit":"1","outcome":"FAILED","out":[0,0],"err":[0,0]}
{"name":"lab-sync","started":1793809100,"finished":1793809200,"result":"success","exit":"0","outcome":"STALLED","out":[0,0],"err":[0,0]}
not json
"#;

    fn utc(s: &str) -> i64 {
        DateTime::parse_from_rfc3339(s).unwrap().timestamp()
    }

    fn pst() -> FixedOffset {
        FixedOffset::west_opt(8 * 3600).unwrap()
    }

    fn verbs(a: &[Action]) -> Vec<&str> {
        a.iter().map(|a| a.verb.as_str()).collect()
    }

    #[test]
    fn shepherd_lines_get_a_verb_each_and_the_counts_line_is_dropped() {
        let a = parse_shepherd(SHEPHERD).0;
        assert_eq!(
            verbs(&a),
            [
                "nudge",
                "escalate",
                "skip",
                "overdue",
                "rundown",
                "watch",
                "wind-down",
                "note",
                "skip"
            ]
        );
        assert!(a.iter().all(|a| a.actor == "shepherd"));
        assert_eq!(a[0].at, utc("2026-11-04T15:42:00Z"));
        assert_eq!(
            a[0].text,
            "nudged hub dotfiles:2 to wind down: all 5 phases done"
        );
    }

    #[test]
    fn a_skip_logged_as_a_raw_ledger_row_keeps_its_last_field() {
        let a = parse_shepherd(SHEPHERD).0;
        let last = a.last().unwrap();
        assert_eq!(last.verb, "skip");
        assert_eq!(
            last.text,
            "escalate NEEDS: hub/dotfiles:11 waiting: no longer waiting"
        );
    }

    #[test]
    fn a_shepherd_entry_after_new_year_takes_the_next_year() {
        let a = parse_shepherd("## 2026-12-31 23:58 UTC pass\n- 00:01 UTC 01-01: nudged a\n").0;
        assert_eq!(a[0].at, utc("2027-01-01T00:01:00Z"));
        assert!(
            parse_shepherd("- 00:01 UTC 01-01: nudged a\n").0.is_empty(),
            "no year yet"
        );
    }

    #[test]
    fn dispatch_times_are_local_and_the_verb_is_the_first_word() {
        let a = parse_dispatch(DISPATCH, &pst()).0;
        assert_eq!(verbs(&a), ["start", "reap", "refused"]);
        assert_eq!(a[0].at, utc("2026-11-04T16:28:00Z"), "08:28 at UTC-8");
        assert!(a[0].text.starts_with("started bnb-agent-1"));
        let east = parse_dispatch(DISPATCH, &FixedOffset::east_opt(3600).unwrap()).0;
        assert_eq!(east[0].at, utc("2026-11-04T07:28:00Z"));
    }

    #[test]
    fn a_notify_ref_is_the_fifth_field_and_a_four_field_row_has_none() {
        let a = parse_notify(
            "2026-11-05T10:00:00-08:00\tnormal\tgo: x\tSession is free.\ttmux:hub/x-agent-3:1
2026-11-05T10:01:00-08:00\tnormal\tgo: y\tNo ref here.
",
        )
        .0;
        assert_eq!(a[0].reference.as_deref(), Some("tmux:hub/x-agent-3:1"));
        assert_eq!(
            a[0].text, "x: Session is free.",
            "the ref stays out of the text"
        );
        assert_eq!(a[1].reference, None);
        let json = serde_json::to_string(&a).unwrap();
        assert!(json.contains(r#""ref":"tmux:hub/x-agent-3:1""#), "{json}");
        assert_eq!(
            json.matches(r#""ref""#).count(),
            1,
            "absent, not null: {json}"
        );
    }

    #[test]
    fn notify_titles_name_the_actor_and_keep_the_priority() {
        let a = parse_notify(NOTIFY).0;
        let got: Vec<(&str, &str, &str)> = a
            .iter()
            .map(|a| {
                (
                    a.actor.as_str(),
                    a.verb.as_str(),
                    a.priority.as_deref().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                ("sentinel", "tripped", "urgent"),
                ("sentinel", "recovered", "high"),
                ("sentinel", "page", "normal"),
                ("shepherd", "page", "high"),
                ("hold", "hold", "normal"),
                ("hold", "go", "normal"),
                ("park", "park", "low"),
                ("ask", "page", "normal"),
            ]
        );
        assert_eq!(a[0].at, utc("2026-11-04T16:18:29Z"));
        assert_eq!(a[0].text, "[fleet-liveness] TRIPPED - exit 1");
        assert_eq!(a[4].text, "unity: HOLD set: gate running");
    }

    #[test]
    fn plain_sentinel_pages_keep_their_verbs() {
        let page = |m: &str| format!("2026-11-05T09:00:00-08:00\thigh\tSentinel: w\t{m}\n");
        let text: String = [
            "A home cluster node is not Ready. Run kubectl --context home-k3s get nodes.",
            "AWS burst runner started.",
            "Home cluster nodes back to normal after 2h.",
            "Home cluster nodes back to normal.",
            "Playground nightly tests failing, for 5d now. Read the failed run.",
            "Agent runners watch cannot check (probe error: metrics fetch failed).",
            "[x] STILL TRIP after 5d - exit 1 (want 0)",
        ]
        .map(page)
        .concat();
        assert_eq!(
            verbs(&parse_notify(&text).0),
            [
                "tripped",
                "tripped",
                "recovered",
                "recovered",
                "page",
                "page",
                "page"
            ]
        );
    }

    #[test]
    fn only_failed_and_stalled_runs_are_actions() {
        let (a, bad) = failed_runs(RUNS);
        assert_eq!(verbs(&a), ["failed", "stalled"]);
        assert_eq!(bad, 1);
        assert_eq!(a[0].at, 1793809001);
        assert_eq!(a[0].text, "fleet-dispatch FAILED: result exit-code, exit 1");
    }

    fn item(slug: &str, from: Option<&str>, queued: &str, finished: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            project: "dotfiles".into(),
            from: from.map(String::from),
            queued: Some(queued.into()),
            started: Some(queued.into()),
            finished: finished.map(String::from),
            status: finished.map(|_| "ok".into()),
            task: "Do the thing\nmore".into(),
            ..Item::default()
        }
    }

    #[test]
    fn queue_items_give_queued_by_source_and_finished_but_not_started() {
        let items = [
            item("a", None, "2026-11-04T10:00:00Z", None),
            item("b", Some("board:dotfiles:x"), "2026-11-04T11:00:00Z", None),
            item(
                "c",
                Some("shepherd"),
                "2026-11-04T12:00:00Z",
                Some("2026-11-04T13:00:00Z"),
            ),
        ];
        let a = from_queue(&items);
        let got: Vec<(&str, &str)> = a
            .iter()
            .map(|a| (a.actor.as_str(), a.verb.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("human", "queue"),
                ("board", "queue"),
                ("shepherd", "queue"),
                ("queue", "finish")
            ]
        );
        assert_eq!(a[0].text, "a (dotfiles): Do the thing");
        assert_eq!(a[3].text, "c (dotfiles) ok: Do the thing");
    }

    fn dir(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("hub-core-actions-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn paths(d: &std::path::Path) -> Paths {
        Paths {
            shepherd_log: d.join("shepherd.md"),
            dispatch_log: d.join("dispatch.md"),
            notify_log: d.join("notify"),
            runs: d.join("runs.jsonl"),
        }
    }

    #[test]
    fn a_missing_ledger_is_empty_and_an_unreadable_one_is_an_error() {
        let d = dir("missing");
        let p = paths(&d);
        std::fs::write(&p.shepherd_log, "").unwrap();
        assert_eq!(gather_in(&p, 0, &[], &pst()), Gathered::default());
        std::fs::create_dir(&p.notify_log).unwrap(); // a dir cannot be read as a file
        let g = gather_in(&p, 0, &[], &pst());
        assert!(g.actions.is_empty());
        assert_eq!(g.errors.len(), 1, "{:?}", g.errors);
        assert!(g.errors[0].contains("notify"));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn the_digest_counts_per_actor_and_lists_the_headlines_oldest_first() {
        let actions = vec![
            Action::new(
                utc("2026-11-04T16:30:00Z"),
                "agentctl",
                "failed",
                "fleet-dispatch FAILED",
                "runs",
            ),
            Action::new(
                utc("2026-11-04T16:20:00Z"),
                "shepherd",
                "escalate",
                &"x".repeat(200),
                "shepherd-log",
            ),
            Action::new(
                utc("2026-11-04T16:10:00Z"),
                "shepherd",
                "nudge",
                "n",
                "shepherd-log",
            ),
            Action::new(
                utc("2026-11-04T16:05:00Z"),
                "shepherd",
                "nudge",
                "n",
                "shepherd-log",
            ),
        ];
        let g = Gathered {
            counts: counts(&actions),
            actions,
            errors: vec!["runs.jsonl: denied".into()],
            ..Gathered::default()
        };
        let text = digest_in(&g, &pst());
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "agentctl: 1 failed");
        assert_eq!(lines[1], "shepherd: 2 nudge, 1 escalate");
        assert_eq!(
            lines[2],
            format!("- 08:20 shepherd escalate: {}...", "x".repeat(160))
        );
        assert_eq!(lines[3], "- 08:30 agentctl failed: fleet-dispatch FAILED");
        assert_eq!(lines[4], "unread: runs.jsonl: denied");
        assert_eq!(
            digest_in(&Gathered::default(), &pst()),
            "nothing recorded\n"
        );
    }

    #[test]
    fn gather_merges_every_ledger_newest_first_from_the_cutoff() {
        let d = dir("all");
        let p = paths(&d);
        std::fs::write(&p.shepherd_log, SHEPHERD).unwrap();
        std::fs::write(&p.dispatch_log, DISPATCH).unwrap();
        std::fs::write(&p.notify_log, NOTIFY).unwrap();
        std::fs::write(&p.runs, RUNS).unwrap();
        let items = [item("a", None, "2026-11-04T16:30:00Z", None)];
        let g = gather_in(&p, 0, &items, &pst());
        assert!(
            g.actions.windows(2).all(|w| w[0].at >= w[1].at),
            "newest first"
        );
        assert_eq!(g.actions[0].actor, "ask", "08:37 local is the newest");
        assert_eq!(g.counts["shepherd"]["skip"], 2);
        assert_eq!(g.counts["dispatch"]["start"], 1);
        assert_eq!(g.counts["sentinel"]["tripped"], 1);
        assert_eq!(g.counts["agentctl"]["failed"], 1);
        assert_eq!(g.counts["human"]["queue"], 1);
        assert_eq!(g.errors.len(), 1, "the bad runs line: {:?}", g.errors);
        let n = g.actions.len();
        assert_eq!(
            n as u64,
            g.counts.values().flat_map(|v| v.values()).sum::<u64>()
        );

        // Same minute in one ledger: the later line is the newer.
        let same: Vec<&str> = g
            .actions
            .iter()
            .filter(|a| a.source == "dispatch-log" || a.source == "shepherd-log")
            .filter(|a| a.at == utc("2026-11-04T16:28:00Z"))
            .map(|a| a.verb.as_str())
            .collect();
        assert_eq!(same, ["start", "skip"], "ties keep the later ledger first");

        let since = utc("2026-11-04T16:28:00Z");
        let late = gather_in(&p, since, &items, &pst());
        assert!(late.actions.iter().all(|a| a.at >= since));
        assert_eq!(
            verbs(&late.actions),
            [
                "page",
                "park",
                "go",
                "hold",
                "page",
                "page",
                "refused",
                "recovered",
                "reap",
                "queue",
                "start",
                "skip"
            ],
            "the FAILED run at 16:16 and the trip at 16:18 are before the cutoff"
        );
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn each_parser_keeps_the_lines_it_cannot_read_as_rejects() {
        let (_, r) = parse_shepherd(SHEPHERD);
        let got: Vec<(&str, &str)> = r
            .iter()
            .map(|r| (r.source.as_str(), r.text.as_str()))
            .collect();
        assert_eq!(got, [("shepherd-log", "- buckets: STALLED 1, WORKING 11")]);
        assert_eq!(r[0].at, utc("2026-10-24T00:00:00Z"), "dated by its heading");
        assert!(
            parse_shepherd("- 00:01 UTC 01-01: nudged a\n").1.is_empty(),
            "no heading, no date"
        );

        let (_, r) = parse_dispatch(DISPATCH, &pst());
        assert_eq!(r.len(), 1);
        assert_eq!(
            (r[0].text.as_str(), r[0].at),
            ("not a line", utc("2026-11-04T16:32:00Z"))
        );

        let (_, r) = parse_notify(NOTIFY);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].text, "a continuation line of the message above");
        assert_eq!(
            r[0].at,
            utc("2026-11-04T08:37:00-08:00"),
            "dated by the page above it"
        );
        assert!(r[0].reject.contains("raw newline"));
    }

    #[test]
    fn clean_ledgers_give_no_rejects() {
        let clean = |t: &str| {
            t.lines()
                .filter(|l| {
                    !l.contains("buckets: STALLED 1")
                        && *l != "not a line"
                        && !l.starts_with("a continuation")
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        assert!(parse_shepherd(&clean(SHEPHERD)).1.is_empty());
        assert!(parse_dispatch(&clean(DISPATCH), &pst()).1.is_empty());
        assert!(parse_notify(&clean(NOTIFY)).1.is_empty());
    }

    #[test]
    fn the_window_keeps_every_action_and_gather_caps_them() {
        let d = dir("window");
        let p = paths(&d);
        let lines: String = (0..MAX_ACTIONS + 5)
            .map(|i| format!("- 2026-11-04 08:{:02} started s{i}\n", i % 60))
            .collect();
        std::fs::write(&p.dispatch_log, format!("{lines}junk\n")).unwrap();
        let w = window_in(&p, 0, &[], &pst());
        assert_eq!(w.actions.len(), MAX_ACTIONS + 5);
        assert_eq!(w.rejects.len(), 1);
        assert_eq!(gather_in(&p, 0, &[], &pst()).actions.len(), MAX_ACTIONS);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
