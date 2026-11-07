//! What NEEDS YOU reads beyond fleet-sessions' state: critical mail (comms' surfaced mail), the
//! janitor's NEEDS YOU lines (today's `infra-cleanup.md`) and the runners stopped at their budget
//! today (each runner's activity.log). `join` adds them to the state document beside the live
//! asks (`boards::state`), so Home, `hub needs`, the pager and the briefing read one list. A
//! source that cannot be read is named in the document's `unreadable`, never an empty list.

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
        }
    }
}

/// The CRITICAL rows of comms' surfaced mail (`class acct date from subject summary`), one per
/// sender and subject with its count, so an alarm that fires every few minutes is one row.
/// First seen first.
pub fn mail(tsv: &str) -> Vec<Value> {
    let mut order: Vec<(String, String, String)> = vec![];
    let mut copies: HashMap<(String, String, String), u64> = HashMap::new();
    for l in tsv.lines() {
        let f: Vec<&str> = l.split('\t').collect();
        if f.first() != Some(&"CRITICAL") {
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
/// One item per what, the newest pass's: the janitor repeats a line on each pass it persists.
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
            seen.insert(what.to_string())
                .then(|| json!({"when": when.trim(), "who": who, "what": what}))
        })
        .collect();
    out.reverse();
    out
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

/// Adds `mail`, `janitor` and `budget` to the state document; a source that cannot be read is
/// named in `unreadable` (`comms`, `notes`, `agentctl`).
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
            state["mail"] = Value::Array(mail(&tsv));
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
        let m = mail(tsv);
        assert_eq!(m.len(), 2);
        assert_eq!(
            m[0],
            json!({"from": "alarm@aws", "subject": "ALARM: 5xx", "acct": "gigantic", "copies": 2})
        );
        assert_eq!(m[1]["from"], "google");
        assert_eq!(m[1]["copies"], 1);
        // Negative control: no CRITICAL row is no mail.
        assert!(mail("ACTION\ta\tb\tc\td\te\n").is_empty());
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
            json!({"when": "Thu 06:30", "who": "janitor", "what": "pvc stuck"})
        );
        assert_eq!(j[1]["what"], "node disk 91%");
        // A line the janitor repeats on a later pass is one item, at its newest time.
        let again = format!("{md}- Fri 02:00 [janitor] NEEDS YOU: pvc stuck\n");
        let j = janitor(&again);
        assert_eq!(j.len(), 2);
        assert_eq!(
            j[1],
            json!({"when": "Fri 02:00", "who": "janitor", "what": "pvc stuck"})
        );
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
        let p = Paths {
            comms: comms.clone(),
            confs,
            agentctl,
        };
        let mut s = json!({"unreadable": []});
        join(&mut s, &p, &Notes(Ok(format!("{}\n", refs.display()))), now);
        assert_eq!(s["mail"].as_array().unwrap().len(), 1);
        assert_eq!(s["janitor"][0]["what"], "pvc stuck");
        assert_eq!(s["budget"].as_array().unwrap().len(), 1);
        assert_eq!(s["budget"][0]["runner"], "dream");
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
