//! agentctl runners (their run ledger) and the other timer-started user units (journald).

use std::collections::HashMap;
use std::process::Command;

use serde::Deserialize;
use serde_json::Value;

use super::{read_or_empty, Got, Job, LogRef, Paths, Source, State};

/// Journald message ids for a unit's job starting, its job finishing, and the unit failing.
const MSG_STARTING: &str = "7d4958e842da4a758f6c1cdc7b36dcc5";
const MSG_FINISHED: &str = "39f53479d3a045ac8e11786248231fbf";
const MSG_FAILED: &str = "d9b373ed55a64feb8242e02dbe79a49c";

pub(crate) const AGENTCTL_PREFIX: &str = "agentctl@";

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd)
        .args(args)
        .output()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{cmd} {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[derive(Deserialize)]
struct Timer {
    activates: String,
    #[serde(default)]
    next: Option<u64>,
}

/// Each timer-activated service and its next start, unix seconds.
pub(super) fn timers_next() -> Result<HashMap<String, i64>, String> {
    let out = run(
        "systemctl",
        &["--user", "list-timers", "--all", "-o", "json"],
    )?;
    parse_timers(&out)
}

fn parse_timers(json: &str) -> Result<HashMap<String, i64>, String> {
    let ts: Vec<Timer> = serde_json::from_str(json).map_err(|e| format!("list-timers: {e}"))?;
    Ok(ts
        .into_iter()
        .map(|t| {
            let next = t
                .next
                .filter(|&n| n > 0)
                .map(|n| (n / 1_000_000) as i64)
                .unwrap_or(0);
            (t.activates, next)
        })
        .collect())
}

/// A unit that is running now: its start and its invocation.
struct Live {
    unit: String,
    started: Option<i64>,
    invocation: String,
}

/// `systemctl show` for the active units among `pattern`, in one call.
fn live(pattern: &[&str]) -> Result<Vec<Live>, String> {
    let mut args = vec![
        "--user",
        "list-units",
        "--state=active,activating,deactivating",
        "--no-legend",
        "--plain",
        "-o",
        "json",
    ];
    args.extend_from_slice(pattern);
    let units: Vec<Value> =
        serde_json::from_str(&run("systemctl", &args)?).map_err(|e| format!("list-units: {e}"))?;
    let names: Vec<String> = units
        .iter()
        .filter_map(|u| u["unit"].as_str())
        .filter(|u| u.ends_with(".service"))
        .map(String::from)
        .collect();
    if names.is_empty() {
        return Ok(vec![]);
    }
    let mut show = vec![
        "--user",
        "show",
        "-p",
        "Id,ExecMainStartTimestamp,InvocationID",
        "--timestamp=unix",
    ];
    show.extend(names.iter().map(String::as_str));
    Ok(parse_show(&run("systemctl", &show)?))
}

/// `systemctl show` prints one `Key=value` block per unit, blank-line separated.
fn parse_show(text: &str) -> Vec<Live> {
    text.split("\n\n")
        .filter_map(|block| {
            let kv: HashMap<&str, &str> = block.lines().filter_map(|l| l.split_once('=')).collect();
            Some(Live {
                unit: kv.get("Id")?.to_string(),
                started: kv
                    .get("ExecMainStartTimestamp")
                    .and_then(|v| v.trim_start_matches('@').parse().ok()),
                invocation: kv.get("InvocationID").unwrap_or(&"").to_string(),
            })
        })
        .collect()
}

fn agentctl_name(unit: &str) -> Option<&str> {
    unit.strip_prefix(AGENTCTL_PREFIX)?.strip_suffix(".service")
}

/// One line of agentctl's `runs.jsonl`, also read by `crate::actions` for its failed runs.
#[derive(Deserialize)]
pub(crate) struct LedgerLine {
    pub(crate) name: String,
    #[serde(default)]
    invocation: String,
    pub(crate) started: Option<i64>,
    pub(crate) finished: i64,
    #[serde(default)]
    pub(crate) result: String,
    #[serde(default)]
    pub(crate) exit: String,
    #[serde(default)]
    pub(crate) outcome: String,
    out: (u64, u64),
    err: (u64, u64),
}

/// Every run in the ledger text, and how many lines could not be read.
pub(crate) fn ledger_lines(text: &str) -> (Vec<LedgerLine>, usize) {
    let mut bad = 0;
    let runs = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| {
            let r = serde_json::from_str::<LedgerLine>(l).ok();
            bad += usize::from(r.is_none());
            r
        })
        .collect();
    (runs, bad)
}

/// Passed when systemd says success and the runner did not say FAILED or go silent. BLOCKED is
/// neither: the run waits on a gate or a budget, as `word_ok` in fleet.rs reads it.
fn ledger_ok(result: &str, outcome: &str) -> Option<bool> {
    match (result, outcome) {
        (_, "FAILED" | "STALLED") => Some(false),
        ("success" | "", "BLOCKED") => None,
        ("success" | "", _) => Some(true),
        _ => Some(false),
    }
}

/// The ledger's runs that finished since `since`, and how many lines could not be read.
pub(super) fn parse_ledger(text: &str, since: i64) -> (Vec<Job>, usize) {
    let (runs, bad) = ledger_lines(text);
    let mut jobs = vec![];
    for r in runs {
        if r.finished < since {
            continue;
        }
        let mut j = Job::new(Source::Agentctl, &r.name, State::Done);
        j.ok = ledger_ok(&r.result, &r.outcome);
        j.result = match (r.outcome.as_str(), r.result.as_str()) {
            (o, "success" | "") if !o.is_empty() => o.to_string(),
            (_, res) if !res.is_empty() && res != "success" => {
                format!("{res} exit={}", r.exit)
            }
            _ => r.result.clone(),
        };
        j.started = r.started;
        j.finished = Some(r.finished);
        j.secs = r.started.map(|s| r.finished - s);
        j.log = Some(LogRef::Runner {
            name: r.name.clone(),
            out: (r.out.0, Some(r.out.1)),
            err: (r.err.0, Some(r.err.1)),
        });
        if !r.invocation.is_empty() {
            j.detail = format!("inv {}", &r.invocation[..r.invocation.len().min(8)]);
        }
        jobs.push(j);
    }
    (jobs, bad)
}

/// Where a running runner's output starts: the `run` sidecar agentctl wrote at its start.
fn run_offsets(paths: &Paths, name: &str) -> (u64, u64) {
    let s = std::fs::read_to_string(paths.agentctl.join(name).join("run")).unwrap_or_default();
    let f: Vec<&str> = s.split_whitespace().collect();
    let n = |i: usize| f.get(i).and_then(|v| v.parse().ok()).unwrap_or(0);
    (n(2), n(3))
}

pub(super) fn agentctl(paths: &Paths, since: i64, at: i64) -> Got {
    let mut errors = vec![];
    let ledger = paths.agentctl.join("runs.jsonl");
    let (mut jobs, bad) = match read_or_empty(&ledger) {
        Ok(t) => parse_ledger(&t, since),
        Err(e) => {
            errors.push(e);
            (vec![], 0)
        }
    };
    if bad > 0 {
        errors.push(format!(
            "{bad} unreadable line(s) in {} skipped",
            ledger.display()
        ));
    }
    match live(&["agentctl@*.service"]) {
        Ok(ls) => {
            for l in ls {
                let Some(name) = agentctl_name(&l.unit) else {
                    continue;
                };
                let mut j = Job::new(Source::Agentctl, name, State::Running);
                j.started = l.started;
                j.secs = l.started.map(|s| at - s);
                let (o, e) = run_offsets(paths, name);
                j.log = Some(LogRef::Runner {
                    name: name.to_string(),
                    out: (o, None),
                    err: (e, None),
                });
                if !l.invocation.is_empty() {
                    j.detail = format!("inv {}", &l.invocation[..l.invocation.len().min(8)]);
                }
                jobs.push(j);
            }
        }
        Err(e) => errors.push(e),
    }
    if let Ok(next) = timers_next() {
        for j in &mut jobs {
            j.next = next
                .get(&format!("{AGENTCTL_PREFIX}{}.service", j.name))
                .copied()
                .filter(|&n| n > 0);
        }
    }
    (jobs, errors)
}

/// One invocation's journald records, folded.
#[derive(Default)]
struct Inv {
    unit: String,
    started: Option<i64>,
    finished: Option<i64>,
    job_result: Option<String>,
    unit_result: Option<String>,
}

/// Runs of the timer-started `units` from journald's JSON records, keyed by invocation.
pub(super) fn parse_journal(text: &str, units: &HashMap<String, i64>) -> Vec<Job> {
    let mut invs: HashMap<String, Inv> = HashMap::new();
    for l in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(l) else {
            continue;
        };
        let s = |k: &str| v[k].as_str().unwrap_or("").to_string();
        let (unit, id) = (s("USER_UNIT"), s("USER_INVOCATION_ID"));
        if id.is_empty() || !units.contains_key(&unit) {
            continue;
        }
        let ts = v["__REALTIME_TIMESTAMP"]
            .as_str()
            .and_then(|t| t.parse::<i64>().ok())
            .map(|us| us / 1_000_000);
        let e = invs.entry(id).or_default();
        e.unit = unit;
        match v["MESSAGE_ID"].as_str().unwrap_or("") {
            MSG_STARTING => e.started = ts,
            MSG_FINISHED => {
                e.finished = ts;
                e.job_result = Some(s("JOB_RESULT"));
            }
            MSG_FAILED => {
                e.finished = e.finished.or(ts);
                e.unit_result = Some(s("UNIT_RESULT"));
            }
            _ => {}
        }
    }
    invs.into_iter()
        .filter_map(|(id, i)| {
            // A start with no end is either running (listed from systemd) or cut off by the
            // journal's own retention; neither is a finished run.
            let fin = i.finished?;
            let name = i
                .unit
                .strip_suffix(".service")
                .unwrap_or(&i.unit)
                .to_string();
            let mut j = Job::new(Source::Timer, name, State::Done);
            let failed =
                i.unit_result.is_some() || i.job_result.as_deref().is_some_and(|r| r != "done");
            j.ok = Some(!failed);
            j.result = match (&i.unit_result, &i.job_result) {
                (Some(u), _) => u.clone(),
                (None, Some(r)) if r == "done" => "ok".into(),
                (None, Some(r)) => r.clone(),
                (None, None) => "failed".into(),
            };
            j.started = i.started;
            j.finished = Some(fin);
            j.secs = i.started.map(|s| fin - s);
            j.next = units.get(&i.unit).copied().filter(|&n| n > 0);
            j.log = Some(LogRef::Journal { invocation: id });
            Some(j)
        })
        .collect()
}

pub(super) fn timers(since: i64, at: i64) -> Got {
    let next = match timers_next() {
        Ok(n) => n,
        Err(e) => return (vec![], vec![e]),
    };
    // agentctl@ runs come from their own ledger, which outlives the journal.
    let units: HashMap<String, i64> = next
        .into_iter()
        .filter(|(u, _)| !u.starts_with(AGENTCTL_PREFIX))
        .collect();
    let mut errors = vec![];
    let since_arg = format!("@{since}");
    let fields = "--output-fields=MESSAGE_ID,USER_UNIT,USER_INVOCATION_ID,JOB_RESULT,UNIT_RESULT";
    let mut jobs = match run(
        "journalctl",
        &[
            "--user",
            "-q",
            "-o",
            "json",
            "--since",
            &since_arg,
            fields,
            &format!("MESSAGE_ID={MSG_STARTING}"),
            &format!("MESSAGE_ID={MSG_FINISHED}"),
            &format!("MESSAGE_ID={MSG_FAILED}"),
        ],
    ) {
        Ok(t) => parse_journal(&t, &units),
        Err(e) => {
            errors.push(e);
            vec![]
        }
    };
    let patterns: Vec<&str> = units.keys().map(String::as_str).collect();
    if !patterns.is_empty() {
        match live(&patterns) {
            Ok(ls) => jobs.extend(ls.into_iter().map(|l| {
                let name = l.unit.strip_suffix(".service").unwrap_or(&l.unit);
                let mut j = Job::new(Source::Timer, name, State::Running);
                j.started = l.started;
                j.secs = l.started.map(|s| at - s);
                if !l.invocation.is_empty() {
                    j.log = Some(LogRef::Journal {
                        invocation: l.invocation,
                    });
                }
                j
            })),
            Err(e) => errors.push(e),
        }
    }
    (jobs, errors)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ledger_lines_become_runs_and_a_corrupt_line_is_counted_not_fatal() {
        let text = r#"{"name":"dream","invocation":"abcdef0123456789","started":100,"finished":940,"result":"success","exit":"0","outcome":"WORKED","out":[0,50],"err":[0,0]}
{"name":"dream","invocation":"x","started":1000,"finished":1060,"result":"exit-code","exit":"1","outcome":"STALLED","out":[50,80],"err":[0,9]}
{"name":"broken","started":
not json at all
{"name":"old","invocation":"","started":1,"finished":2,"result":"success","exit":"0","outcome":"NOOP","out":[0,0],"err":[0,0]}
"#;
        let (jobs, bad) = parse_ledger(text, 50);
        assert_eq!(bad, 2);
        assert_eq!(jobs.len(), 2, "the run before the window is dropped");
        assert_eq!(jobs[0].result, "WORKED");
        assert_eq!(jobs[0].ok, Some(true));
        assert_eq!(jobs[0].secs, Some(840));
        assert_eq!(jobs[1].result, "exit-code exit=1");
        assert_eq!(jobs[1].ok, Some(false));
        assert_eq!(
            jobs[1].log,
            Some(LogRef::Runner {
                name: "dream".into(),
                out: (50, Some(80)),
                err: (0, Some(9))
            })
        );
    }

    #[test]
    fn a_success_the_runner_called_stalled_is_a_failure() {
        assert_eq!(ledger_ok("success", "STALLED"), Some(false));
        assert_eq!(ledger_ok("success", "NOOP"), Some(true));
        assert_eq!(ledger_ok("timeout", "WORKED"), Some(false));
    }

    #[test]
    fn a_blocked_run_is_neither_passed_nor_failed_unless_systemd_failed_it() {
        assert_eq!(ledger_ok("success", "BLOCKED"), None);
        assert_eq!(ledger_ok("", "BLOCKED"), None);
        assert_eq!(ledger_ok("timeout", "BLOCKED"), Some(false));
    }

    #[test]
    fn journal_records_fold_by_invocation() {
        let units: HashMap<String, i64> = [("git-sync-notes.service".to_string(), 2_000)]
            .into_iter()
            .collect();
        let rec = |mid: &str, inv: &str, t: i64, extra: &str| {
            format!(
                r#"{{"MESSAGE_ID":"{mid}","USER_UNIT":"git-sync-notes.service","USER_INVOCATION_ID":"{inv}","__REALTIME_TIMESTAMP":"{}"{extra}}}"#,
                t * 1_000_000
            )
        };
        let text = [
            rec(MSG_STARTING, "a", 100, ""),
            rec(MSG_FINISHED, "a", 103, r#","JOB_RESULT":"done""#),
            rec(MSG_STARTING, "b", 200, ""),
            rec(MSG_FAILED, "b", 290, r#","UNIT_RESULT":"timeout""#),
            rec(MSG_FINISHED, "b", 291, r#","JOB_RESULT":"failed""#),
            rec(MSG_STARTING, "c", 300, ""),
            r#"{"MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","USER_UNIT":"other.service","USER_INVOCATION_ID":"d"}"#.into(),
        ]
        .join("\n");
        let mut jobs = parse_journal(&text, &units);
        jobs.sort_by_key(|j| j.started);
        assert_eq!(jobs.len(), 2, "c has not finished, d is not a timer's unit");
        assert_eq!(
            (jobs[0].ok, jobs[0].result.as_str(), jobs[0].secs),
            (Some(true), "ok", Some(3))
        );
        assert_eq!(
            (jobs[1].ok, jobs[1].result.as_str()),
            (Some(false), "timeout")
        );
        assert_eq!(jobs[1].name, "git-sync-notes");
        assert_eq!(jobs[1].next, Some(2_000));
    }

    #[test]
    fn show_blocks_parse() {
        let l = parse_show("Id=a.service\nInvocationID=ff\nExecMainStartTimestamp=@17\n\nId=b.service\nExecMainStartTimestamp=\n");
        assert_eq!(l.len(), 2);
        assert_eq!(
            (l[0].unit.as_str(), l[0].started, l[0].invocation.as_str()),
            ("a.service", Some(17), "ff")
        );
        assert_eq!(l[1].started, None);
    }

    #[test]
    fn timers_parse_microseconds() {
        let t = parse_timers(r#"[{"next":1793726160000000,"unit":"x.timer","activates":"x.service"},{"next":null,"unit":"y.timer","activates":"y.service"}]"#).unwrap();
        assert_eq!(t["x.service"], 1_793_726_160);
        assert_eq!(t["y.service"], 0);
    }
}
