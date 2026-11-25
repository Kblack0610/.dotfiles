//! What NEEDS YOU reads beyond fleet-sessions' state: critical mail (comms' surfaced mail), the
//! janitor's NEEDS YOU lines (today's `infra-cleanup.md`), the runners stopped at their budget
//! today (each runner's activity.log) and the standing holds the human set (`holds`). `join` adds
//! them to the state document beside the live asks (`boards::state`), so Home, `hub needs`, the
//! pager and the briefing read one list. A source that cannot be read is named in the document's
//! `unreadable`, never an empty list.

use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::{json, Value};

use crate::session_actions::Runner;

/// Where the sources live, by the variables `agentctl-briefing` resolves.
pub struct Paths {
    /// comms' state dir: `surface/*.tsv` and `stats-summary.txt` (`BRIEFING_COMMS_DIR`).
    pub comms: PathBuf,
    /// agentctl's runner confs (`AGENTCTL_CONF_DIR`).
    pub confs: PathBuf,
    /// agentctl's state dir, each runner's default inbox.
    pub agentctl: PathBuf,
    /// agent-hold's hold files (`AGENT_HOLD_DIR`).
    pub holds: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let env = |k: &str| {
            std::env::var_os(k)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        Paths {
            comms: env("BRIEFING_COMMS_DIR")
                .unwrap_or_else(|| home.join(".local/state/notes-comms")),
            confs: env("AGENTCTL_CONF_DIR").unwrap_or_else(|| home.join(".config/agentctl/agents")),
            agentctl: crate::jobs::Paths::from_env().agentctl,
            holds: crate::holds::dir(),
        }
    }
}

/// How many days back a CRITICAL mail still needs the human: today's and yesterday's. A one-time
/// code or login link is stale the day after, and comms never ages a CRITICAL row out itself
/// (it stays until opened), so a code sat on Needs you for days (ar-4018). Dates are whole days.
pub const MAIL_TTL_DAYS: i64 = 1;

/// The CRITICAL rows of comms' surfaced mail (`class acct date from subject summary`), one per
/// sender and subject with its count, so an alarm that fires every few minutes is one row.
/// First seen first. A row dated before `MAIL_TTL_DAYS` ago has expired; one whose date does not
/// parse stays, since a read fault is not a verdict.
pub fn mail(tsv: &str, now: i64) -> Vec<Value> {
    use chrono::{Local, TimeZone};
    let oldest = Local
        .timestamp_opt(now, 0)
        .single()
        .map(|t| t.date_naive() - chrono::Duration::days(MAIL_TTL_DAYS));
    let mut order: Vec<(String, String, String)> = vec![];
    let mut copies: HashMap<(String, String, String), u64> = HashMap::new();
    for l in tsv.lines() {
        let f: Vec<&str> = l.split('\t').collect();
        if f.first() != Some(&"CRITICAL") {
            continue;
        }
        let dated = f
            .get(2)
            .and_then(|d| chrono::NaiveDate::parse_from_str(d.trim(), "%Y-%m-%d").ok());
        if dated.zip(oldest).is_some_and(|(d, o)| d < o) {
            continue;
        }
        let col = |i: usize| f.get(i).map_or("", |s| s.trim()).to_string();
        let key = (col(3), col(4), col(1));
        let n = copies.entry(key.clone()).or_insert(0);
        if *n == 0 {
            order.push(key);
        }
        *n += 1;
    }
    order
        .into_iter()
        .map(|k| {
            let n = copies[&k];
            let (from, subject, acct) = k;
            json!({"from": from, "subject": subject, "acct": acct, "copies": n})
        })
        .collect()
}

/// The janitor's NEEDS YOU items in `infra-cleanup.md`: `- <when> [<who>] NEEDS YOU: <what>`.
/// The section header names NEEDS YOU too, but is no item.
/// One item per subject, the newest pass's: the janitor repeats a line on each pass it persists,
/// with its evidence in parentheses growing each time ("HostSoftLockup x1 (06:20Z)", then "x2 (06:20Z,
/// 06:50Z)"). `key` is the what without its parenthesized groups, whitespace folded; the Needs id is
/// built from it, so a kept item keeps its id across passes.
pub fn janitor(md: &str) -> Vec<Value> {
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<Value> = md
        .lines()
        .rev()
        .filter_map(|l| {
            let rest = l.strip_prefix("- ")?;
            let (when, rest) = rest.split_once(" [")?;
            let (who, rest) = rest.split_once("] NEEDS YOU")?;
            let what = rest.trim_start_matches(':').trim();
            let key = janitor_key(what);
            seen.insert(key.clone())
                .then(|| json!({"when": when.trim(), "who": who, "what": what, "key": key}))
        })
        .collect();
    out.reverse();
    out
}

/// A janitor line's subject: its text without the parenthesized groups that carry a clock time
/// (the evidence, "(HostSoftLockup x2 (06:20Z, 06:50Z), host-only)"), whitespace folded. A group
/// with no time ("(ns-a)") names the subject and stays, so two such lines stay two items. A "(" never
/// closed and an unbalanced ")" stay as text; a key left empty falls back to the folded text.
fn janitor_key(what: &str) -> String {
    let fold = |t: &str| t.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut kept = String::with_capacity(what.len());
    let mut group = String::new();
    let mut depth = 0usize;
    for c in what.chars() {
        match c {
            '(' => {
                depth += 1;
                group.push(c);
            }
            ')' if depth > 0 => {
                depth -= 1;
                group.push(c);
                if depth == 0 {
                    if !has_clock(&group) {
                        kept.push_str(&group);
                    }
                    group.clear();
                }
            }
            _ if depth > 0 => group.push(c),
            _ => kept.push(c),
        }
    }
    kept.push_str(&group);
    let key = fold(&kept);
    if key.is_empty() {
        fold(what)
    } else {
        key
    }
}

/// Whether the text holds a clock time: digits, ":", two digits ("06:20Z", "6:05").
fn has_clock(t: &str) -> bool {
    let b = t.as_bytes();
    (1..b.len().saturating_sub(2)).any(|i| {
        b[i] == b':'
            && b[i - 1].is_ascii_digit()
            && b[i + 1].is_ascii_digit()
            && b[i + 2].is_ascii_digit()
    })
}

/// A runner stopped at its day budget today: the newest outcome line of its activity.log is
/// `outcome=BLOCKED budget: over its daily budget: <detail>` (lib/budget.sh), at or after
/// `day_start`. It waits for a raise or for midnight, so it needs the human whatever its kind.
/// The hourly call cap (`budget: rate: ...`) clears itself within the hour, so it is no stop.
pub fn budget_stop(log: &str, day_start: i64) -> Option<(String, Option<i64>)> {
    let last = log
        .lines()
        .rev()
        .find_map(|l| crate::fleet::parse_activity(l.trim()))?;
    let detail = last
        .text
        .strip_prefix("budget:")?
        .trim()
        .strip_prefix("over its daily budget:")?
        .trim();
    (last.word == "BLOCKED" && last.at.is_some_and(|t| t >= day_start))
        .then(|| (detail.to_string(), last.at))
}

fn unreadable(state: &mut Value, what: &str) {
    match state["unreadable"].as_array_mut() {
        Some(u) => u.push(what.into()),
        None => state["unreadable"] = json!([what]),
    }
}

/// Adds `mail`, `janitor`, `budget` and `holds` to the state document; a source that cannot be
/// read is named in `unreadable` (`comms`, `notes`, `agentctl`, `holds`). `holds` is the standing
/// holds `by: human`, oldest first: only the human ends one, so it waits on them (ar-4645). A
/// standing hold an agent set is red on Alerts, where its fix is routed.
pub fn join(state: &mut Value, p: &Paths, r: &dyn Runner, now: i64) {
    let surface = p.comms.join("surface");
    match std::fs::read_dir(&surface) {
        Ok(rd) => {
            let mut files: Vec<PathBuf> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|f| f.extension().is_some_and(|e| e == "tsv"))
                .collect();
            files.sort();
            let tsv: String = files
                .iter()
                .filter_map(|f| std::fs::read_to_string(f).ok())
                .collect::<Vec<_>>()
                .join("\n");
            state["mail"] = Value::Array(mail(&tsv, now));
        }
        Err(_) => {
            state["mail"] = json!([]);
            unreadable(state, "comms");
        }
    }

    let refs = r.run(&["notes", "path", "refs-today"].map(String::from));
    match refs {
        Ok(dir) => {
            let f = PathBuf::from(dir.trim()).join("infra-cleanup.md");
            // No file is a morning the janitor found nothing to say.
            let md = std::fs::read_to_string(f).unwrap_or_default();
            state["janitor"] = Value::Array(janitor(&md));
        }
        Err(_) => {
            state["janitor"] = json!([]);
            unreadable(state, "notes");
        }
    }

    let day_start = crate::text::local_day_start(now);
    let (confs, errors) = crate::fleet::read_confs(&p.confs, &p.agentctl);
    let mut stops = vec![];
    for c in &confs {
        let Ok((log, _)) =
            crate::fleet::tail(&c.inbox.join("activity.log"), crate::fleet::ACTIVITY_TAIL)
        else {
            continue;
        };
        if let Some((detail, at)) = budget_stop(&log, day_start) {
            stops.push(json!({"runner": c.name, "detail": detail, "at": at}));
        }
    }
    stops.sort_by(|a, b| a["runner"].as_str().cmp(&b["runner"].as_str()));
    state["budget"] = Value::Array(stops);
    if !errors.is_empty() {
        unreadable(state, "agentctl");
    }

    match crate::holds::read(&p.holds) {
        Ok(list) => {
            state["holds"] = crate::holds::standing(list, now)
                .iter()
                .filter(|h| h.human())
                .map(|h| h.json(now))
                .collect();
        }
        Err(_) => {
            state["holds"] = json!([]);
            unreadable(state, "holds");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn critical_mail_is_one_row_per_sender_and_subject_with_its_copies() {
        let tsv = "CRITICAL\tgigantic\t2026-11-06\talarm@aws\tALARM: 5xx\tCheck it.\t\n\
                   ACTION\tlazer\t2026-11-04\tjan@lazer\tInvite\tJoin.\t\n\
                   CRITICAL\tgigantic\t2026-11-06\talarm@aws\tALARM: 5xx\tCheck it again.\t\n\
                   CRITICAL\tpersonal\t2026-11-06\tgoogle\tSecurity alert\tRemove it.\tdev\n";
        let now = crate::fleet::ts("2026-11-06T06:45:00-0800").unwrap();
        let m = mail(tsv, now);
        assert_eq!(m.len(), 2);
        assert_eq!(
            m[0],
            json!({"from": "alarm@aws", "subject": "ALARM: 5xx", "acct": "gigantic", "copies": 2})
        );
        assert_eq!(m[1]["from"], "google");
        assert_eq!(m[1]["copies"], 1);
        // Negative control: no CRITICAL row is no mail.
        assert!(mail("ACTION\ta\tb\tc\td\te\n", now).is_empty());
    }

    #[test]
    fn a_critical_mail_past_its_ttl_expires_and_an_undated_one_stays() {
        let now = crate::fleet::ts("2026-11-20T09:00:00-0800").unwrap();
        let tsv = "CRITICAL\tpersonal\t2026-11-16\tnotifications@openrouter.ai\t394472 is your verification code\tCode.\t\n\
                   CRITICAL\tpersonal\t2026-11-19\talarm@aws\tALARM yesterday\tCheck.\t\n\
                   CRITICAL\tpersonal\t2026-11-20\talarm@aws\tALARM today\tCheck.\t\n\
                   CRITICAL\tpersonal\tunknown\tgoogle\tSecurity alert\tRemove it.\t\n";
        let subjects: Vec<String> = mail(tsv, now)
            .iter()
            .map(|m| m["subject"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            subjects,
            ["ALARM yesterday", "ALARM today", "Security alert"]
        );
    }

    #[test]
    fn janitor_items_are_its_needs_you_lines_and_not_the_header() {
        let md = "# Infra cleanup\n\nNEEDS YOU items below.\n\
                  - Thu 06:30 [janitor] NEEDS YOU: pvc stuck\n\
                  - Thu 06:31 [janitor] cleaned 3 pods\n\
                  - Fri 01:00 [digest] NEEDS YOU node disk 91%\n";
        let j = janitor(md);
        assert_eq!(j.len(), 2);
        assert_eq!(
            j[0],
            json!({"when": "Thu 06:30", "who": "janitor", "what": "pvc stuck", "key": "pvc stuck"})
        );
        assert_eq!(j[1]["what"], "node disk 91%");
        // A line the janitor repeats on a later pass is one item, at its newest time.
        let again = format!("{md}- Fri 02:00 [janitor] NEEDS YOU: pvc stuck\n");
        let j = janitor(&again);
        assert_eq!(j.len(), 2);
        assert_eq!(
            j[1],
            json!({"when": "Fri 02:00", "who": "janitor", "what": "pvc stuck", "key": "pvc stuck"})
        );
    }

    #[test]
    fn a_janitor_line_whose_evidence_grows_is_one_item_per_node() {
        let line = |when: &str, node: &str, ev: &str| {
            format!("- {when} [janitor] NEEDS YOU: node {node} meets quarantine (HostSoftLockup {ev}, host-only) but 2 nodes are already or newly quarantined - not tainted; check the trigger queries\n")
        };
        let md = [
            line("06:20", "deskslim-1", "x1 (06:20Z)"),
            line("06:50", "deskslim-1", "x2 (06:20Z, 06:50Z)"),
            line("07:10", "msi-b550", "x3 (06:50Z, 07:00Z, 07:10Z)"),
            line("10:50", "deskslim-1", "x3 (06:20Z, 06:50Z, 10:50Z)"),
        ]
        .concat();
        let j = janitor(&md);
        // Negative control: two nodes stay two items.
        assert_eq!(j.len(), 2);
        assert_eq!(j[0]["when"], "07:10");
        assert_eq!(j[1]["when"], "10:50");
        // The newest pass's full text is shown; the key drops the evidence.
        assert!(j[1]["what"]
            .as_str()
            .unwrap()
            .contains("x3 (06:20Z, 06:50Z, 10:50Z)"));
        assert_eq!(
            j[1]["key"],
            "node deskslim-1 meets quarantine but 2 nodes are already or newly quarantined - not tainted; check the trigger queries"
        );
        // A group with no clock time names the subject: two namespaces stay two items.
        let ns = "- 06:00 [janitor] NEEDS YOU: pvc stuck (ns-a)\n- 06:10 [janitor] NEEDS YOU: pvc stuck (ns-b)\n";
        assert_eq!(janitor(ns).len(), 2);
        // A stray "(" stays as text and the evidence group is still dropped.
        assert_eq!(
            janitor_key("node x quarantine (HostSoftLockup x1 (06:20Z)) :("),
            "node x quarantine :("
        );
        // A line that is all evidence keeps its folded text, never an empty key.
        assert_eq!(janitor_key("(disk  91% at 06:20Z)"), "(disk 91% at 06:20Z)");
    }

    #[test]
    fn a_budget_stop_counts_only_when_it_is_the_newest_outcome_of_today() {
        let day = crate::fleet::ts("2026-11-06T00:00:00-0800").unwrap();
        let log = "[2026-11-06T03:12:00-0800] outcome=BLOCKED budget: over its daily budget: $10.20 of $10 (BUDGET_DAY_USD)\n";
        assert_eq!(
            budget_stop(log, day),
            Some((
                "$10.20 of $10 (BUDGET_DAY_USD)".into(),
                crate::fleet::ts("2026-11-06T03:12:00-0800")
            ))
        );
        // Raised and ran again: the newest outcome is no stop.
        let raised = format!("{log}[2026-11-06T04:00:00-0800] outcome=WORKED did it\n");
        assert_eq!(budget_stop(&raised, day), None);
        // Yesterday's stop ended at midnight.
        let old = "[2026-11-05T23:00:00-0800] outcome=BLOCKED budget: over its daily budget: $10.20 of $10 (BUDGET_DAY_USD)\n";
        assert_eq!(budget_stop(old, day), None);
        // The hourly cap clears itself: no stop.
        let rate = "[2026-11-06T03:12:00-0800] outcome=BLOCKED budget: rate: 20 calls in the last hour, cap 20 (MAX_CALLS_HOUR)\n";
        assert_eq!(budget_stop(rate, day), None);
        // A gate, not a budget.
        let gate = "[2026-11-06T03:12:00-0800] outcome=BLOCKED gate: held\n";
        assert_eq!(budget_stop(gate, day), None);
    }

    struct Notes(Result<String, String>);
    impl Runner for Notes {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv.join(" "), "notes path refs-today");
            self.0.clone()
        }
    }

    #[test]
    fn join_reads_each_source_and_names_the_ones_it_could_not() {
        let dir = std::env::temp_dir().join(format!("hub-core-signals-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (comms, confs, agentctl, refs) = (
            dir.join("comms"),
            dir.join("confs"),
            dir.join("agentctl"),
            dir.join("refs"),
        );
        for d in [
            comms.join("surface"),
            confs.clone(),
            agentctl.join("dream"),
            refs.clone(),
        ] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(
            comms.join("surface/personal.tsv"),
            "CRITICAL\tpersonal\t2026-11-06\tgoogle\tSecurity alert\tRemove it.\t\n",
        )
        .unwrap();
        std::fs::write(confs.join("dream.conf"), "NAME=dream\nSCHEDULE=03:00\n").unwrap();
        std::fs::write(confs.join("tmp-gc.conf"), "NAME=tmp-gc\n").unwrap();
        let now = crate::fleet::ts("2026-11-06T06:45:00-0800").unwrap();
        std::fs::write(
            agentctl.join("dream/activity.log"),
            "[2026-11-06T03:12:00-0800] outcome=BLOCKED budget: over its daily budget: $10.20 of $10 (BUDGET_DAY_USD)\n",
        )
        .unwrap();
        std::fs::write(
            refs.join("infra-cleanup.md"),
            "- Fri 06:30 [janitor] NEEDS YOU: pvc stuck\n",
        )
        .unwrap();
        let holds = dir.join("holds");
        std::fs::create_dir_all(&holds).unwrap();
        let since = |days: i64| {
            chrono::DateTime::from_timestamp(now - days * 86400, 0)
                .unwrap()
                .format("%Y-%m-%dT%H:%M:%S%z")
                .to_string()
        };
        let put = |name: &str, kind: &str, by: &str, days: i64| {
            let text = format!(
                "kind: {kind}\nsince: {}\nby: {by}\nreason: why {name}\n",
                since(days)
            );
            std::fs::write(holds.join(name), text).unwrap();
        };
        put("critical", "resource", "human", 2);
        // Negative controls: an agent's standing hold is Alerts' alone, and a fresh one stands not yet.
        put("row-x-1", "resource", "fleet-dispatch", 3);
        put("fresh", "resource", "human", 0);
        let p = Paths {
            comms: comms.clone(),
            confs,
            agentctl,
            holds,
        };
        let mut s = json!({"unreadable": []});
        join(&mut s, &p, &Notes(Ok(format!("{}\n", refs.display()))), now);
        assert_eq!(s["mail"].as_array().unwrap().len(), 1);
        assert_eq!(s["janitor"][0]["what"], "pvc stuck");
        assert_eq!(s["budget"].as_array().unwrap().len(), 1);
        assert_eq!(s["budget"][0]["runner"], "dream");
        assert_eq!(s["holds"].as_array().unwrap().len(), 1, "{}", s["holds"]);
        assert_eq!(s["holds"][0]["resource"], "critical");
        assert_eq!(s["holds"][0]["held"], "held 2d by human");
        assert_eq!(s["unreadable"], json!([]));

        std::fs::remove_dir_all(comms.join("surface")).unwrap();
        let mut s = json!({"unreadable": []});
        join(&mut s, &p, &Notes(Err("notes: not found".into())), now);
        assert_eq!(s["mail"], json!([]));
        assert_eq!(s["janitor"], json!([]));
        assert_eq!(s["unreadable"], json!(["comms", "notes"]));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
