//! Where a session spent its time, and what it waits on at its last entry.

use std::fs;
use std::path::Path;

use serde_json::Value;

use super::ask::HUMAN_TOOLS;
use super::read::{content_blocks, iso_epoch, read};

/// A gap between entries shorter than this is the session working; a longer one was a wait,
/// and what was still running says for what.
const WORK_GAP_SECS: u64 = 300;

/// How far past a gap's end to look for the entry that says who ended it.
const WAKE_SECS: u64 = 60;

/// A job open longer than this is taken as gone: a session can die with no record of it. The
/// longest real ones run about 5 hours (p99, 1782 background commands, 2026-10-30).
const JOB_MAX_SECS: u64 = 12 * 3600;

/// In the notification a resumed session gets for each job that died with the old process.
const SESSION_ENDED: &str = "before the previous session ended";

/// `toolUseResult` fields that mean the call went on in the background under that id.
const BACKGROUND_IDS: [&str; 4] = [
    "backgroundTaskId",
    "taskId",
    "resumedAgentId",
    "revivedAgentId",
];

/// Which commands are a merge gate or a test run. Content, so it lives in dotfiles config.
const TIME_USE_CONF: &str = ".config/agent-panel/time-use.conf";

/// Minutes of a session's closed gaps, by what it was waiting on. The open gap since the last
/// entry is not here: IDLE already shows it, and what ends it is not known yet.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub struct TimeUse {
    pub work_min: u64,
    /// A job whose command `time-use.conf` calls a merge gate was running.
    pub gate_min: u64,
    /// A job whose command `time-use.conf` calls a test run was running.
    pub test_min: u64,
    /// Any other background job or foreground tool was running.
    pub jobs_min: u64,
    /// An AskUserQuestion or ExitPlanMode was open, or nothing was running and a prompt was typed.
    pub human_min: u64,
    /// Nothing was running: a peer's message or some other record woke it.
    pub parked_min: u64,
}

#[derive(Clone, Copy, PartialEq)]
enum Wait {
    Work,
    Gate,
    Test,
    Jobs,
    Human,
    Parked,
    /// Only a `build` line of the conf yields this, and `open_job` turns it into a `Jobs` job
    /// with `build` set: time_use counts a build as `jobs`, so this is never a `secs` index.
    Build,
}

/// A tool call still running. Holds what it counts as, never its command, which can hold a secret.
struct Job {
    tool_id: String,
    task_id: Option<String>,
    wait: Wait,
    /// A background subagent: its session is idle while the subagent works.
    agent: bool,
    /// A command a `build` line of `time-use.conf` names: counted as `jobs`, reported as `build`.
    build: bool,
    since: u64,
}

/// `<gate|test|build> <text in the command>` lines. The first line that matches wins.
fn job_patterns(conf: &str) -> Vec<(Wait, &str)> {
    conf.lines()
        .filter_map(|l| {
            let (kind, text) = l.trim().split_once(char::is_whitespace)?;
            match kind {
                "gate" => Some((Wait::Gate, text.trim())),
                "test" => Some((Wait::Test, text.trim())),
                "build" => Some((Wait::Build, text.trim())),
                _ => None,
            }
        })
        .collect()
}

/// With no config every job counts as `jobs`, which is still true.
fn time_use_conf() -> String {
    fs::read_to_string(crate::session::home().join(TIME_USE_CONF)).unwrap_or_default()
}

pub fn time_use_at(path: &Path) -> TimeUse {
    time_use(&read(path), &job_patterns(&time_use_conf()))
}

/// Split the transcript's elapsed time. Reads every line, so it stays on substring checks and
/// parses only lines that start or end a job, and around a long gap. The first `"timestamp":"`
/// on a line is the entry's own (escaped copies inside a string do not match); a
/// file-history-snapshot has only a nested one. The running max keeps a burst written out of
/// order from reading as a gap. A gap is counted before its last line can end a job.
fn time_use(text: &str, patterns: &[(Wait, &str)]) -> TimeUse {
    walk(text, patterns).0
}

/// `walk` under the shipped `time-use.conf`.
pub(super) fn time_use_and_open_job(text: &str) -> (TimeUse, &'static str) {
    walk(text, &job_patterns(&time_use_conf()))
}

/// time_use, plus the class of what is still open at the last entry (FleetInfo::open_job).
fn walk(text: &str, patterns: &[(Wait, &str)]) -> (TimeUse, &'static str) {
    let lines: Vec<&str> = text.lines().filter(|l| !skipped_entry(l)).collect();
    let mut secs = [0u64; 6];
    let mut last: Option<u64> = None;
    let mut jobs: Vec<Job> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let at = entry_epoch(line);
        if let (Some(at), Some(prev)) = (at, last) {
            if at > prev {
                let gap = at - prev;
                let wait = if gap < WORK_GAP_SECS {
                    Wait::Work
                } else {
                    gap_wait(&lines[i..], prev, at, &mut jobs)
                };
                secs[wait as usize] += gap;
            }
        }
        last = last.max(at);
        track_jobs(line, last.unwrap_or(0), patterns, &mut jobs);
    }
    let open = open_class(&jobs, last.unwrap_or(0));
    let [work, gate, test, jobs, human, parked] = secs.map(|s| s / 60);
    (
        TimeUse {
            work_min: work,
            gate_min: gate,
            test_min: test,
            jobs_min: jobs,
            human_min: human,
            parked_min: parked,
        },
        open,
    )
}

/// The strongest wait among the jobs open at `last`, skipping any older than JOB_MAX_SECS.
fn open_class(jobs: &[Job], last: u64) -> &'static str {
    let live: Vec<&Job> = jobs
        .iter()
        .filter(|j| last.saturating_sub(j.since) < JOB_MAX_SECS)
        .collect();
    let has = |w: Wait| live.iter().any(|j| j.wait == w);
    if has(Wait::Human) {
        "human"
    } else if has(Wait::Gate) {
        "gate"
    } else if has(Wait::Test) {
        "test"
    } else if live.iter().any(|j| j.build) {
        "build"
    } else if live.iter().any(|j| j.agent) {
        "agent"
    } else if live.is_empty() {
        "none"
    } else {
        "jobs"
    }
}

/// A subagent's entry, or a snapshot whose only timestamp is nested.
fn skipped_entry(line: &str) -> bool {
    line.contains("\"isSidechain\":true") || line.starts_with("{\"type\":\"file-history-snapshot\"")
}

fn entry_epoch(line: &str) -> Option<u64> {
    const KEY: &str = "\"timestamp\":\"";
    line.find(KEY)
        .and_then(|i| line.get(i + KEY.len()..))
        .and_then(|rest| rest.split('"').next())
        .and_then(iso_epoch)
}

/// Keep the open jobs current with one entry.
fn track_jobs(line: &str, at: u64, patterns: &[(Wait, &str)], jobs: &mut Vec<Job>) {
    if !["\"tool_use\"", "\"tool_result\"", "<task-notification>"]
        .iter()
        .any(|k| line.contains(k))
    {
        return;
    }
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    match v.get("type").and_then(Value::as_str) {
        Some("assistant") => {
            for c in content_blocks(&v) {
                if c.get("type").and_then(Value::as_str) == Some("tool_use") {
                    open_job(c, at, patterns, jobs);
                }
            }
        }
        Some("user") => {
            if let Some(s) = v.pointer("/message/content").and_then(Value::as_str) {
                close_notified(s, jobs);
            }
            for c in content_blocks(&v) {
                match c.get("type").and_then(Value::as_str) {
                    Some("tool_result") => tool_returned(&v, c, jobs),
                    Some("text") => {
                        close_notified(c.get("text").and_then(Value::as_str).unwrap_or(""), jobs)
                    }
                    _ => {}
                }
            }
        }
        Some("queue-operation") => {
            close_notified(v.get("content").and_then(Value::as_str).unwrap_or(""), jobs)
        }
        _ => {}
    }
}

fn open_job(call: &Value, at: u64, patterns: &[(Wait, &str)], jobs: &mut Vec<Job>) {
    let name = call.get("name").and_then(Value::as_str).unwrap_or("");
    let input = call.get("input");
    if name == "TaskStop" {
        let id = input.and_then(|i| i.get("task_id")).and_then(Value::as_str);
        jobs.retain(|j| j.task_id.is_none() || j.task_id.as_deref() != id);
    }
    let command = input
        .and_then(|i| i.get("command"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let wait = if HUMAN_TOOLS.contains(&name) {
        Wait::Human
    } else {
        patterns
            .iter()
            .find(|(_, text)| command.contains(text))
            .map_or(Wait::Jobs, |(wait, _)| *wait)
    };
    let build = wait == Wait::Build;
    let wait = if build { Wait::Jobs } else { wait };
    if let Some(id) = call.get("id").and_then(Value::as_str) {
        let agent = name == "Agent" || name == "Task";
        jobs.push(Job {
            tool_id: id.to_string(),
            task_id: None,
            wait,
            agent,
            build,
            since: at,
        });
    }
}

/// A call's result ends it, unless the result says it went on in the background.
fn tool_returned(entry: &Value, block: &Value, jobs: &mut Vec<Job>) {
    let id = block
        .get("tool_use_id")
        .and_then(Value::as_str)
        .unwrap_or("");
    match background_id(entry) {
        Some(task) => {
            if let Some(job) = jobs.iter_mut().find(|j| j.tool_id == id) {
                job.task_id = Some(task.to_string());
            }
        }
        None => jobs.retain(|j| j.tool_id != id),
    }
}

/// An Agent call reports its id whether or not it waits, so only `isAsync` counts there.
fn background_id(entry: &Value) -> Option<&str> {
    let result = entry.get("toolUseResult")?;
    let id = |key: &str| {
        result
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    };
    BACKGROUND_IDS.iter().find_map(|k| id(k)).or_else(|| {
        (result.get("isAsync").and_then(Value::as_bool) == Some(true))
            .then(|| id("agentId"))
            .flatten()
    })
}

/// A job's notification ends it. A Monitor's event only reports, and its watch stays open: a
/// status or the watch expiring is what ends one.
fn close_notified(s: &str, jobs: &mut Vec<Job>) {
    if !s.starts_with("<task-notification>")
        || !(s.contains("<status>") || s.contains("Monitor expired"))
    {
        return;
    }
    let (tool, task) = (tag_text(s, "tool-use-id"), tag_text(s, "task-id"));
    jobs.retain(|j| {
        Some(j.tool_id.as_str()) != tool && (task.is_none() || j.task_id.as_deref() != task)
    });
}

fn tag_text<'a>(s: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let rest = s.get(s.find(&open)? + open.len()..)?;
    rest.split('<').next()
}

/// What a long gap was waiting on. A slow model turn is the session working, and an open dialog
/// is you. Otherwise a running job counts, however the gap ended: a peer's message during a
/// gate is still a wait on the gate. With nothing running, what ended the gap says.
fn gap_wait(lines: &[&str], start: u64, end: u64, jobs: &mut Vec<Job>) -> Wait {
    let wake = gap_end(lines, end);
    if wake == Wait::Work {
        return wake;
    }
    // The process that ran them is gone, so nothing was running through this gap.
    if wake_window(lines, end).any(|l| l.contains(SESSION_ENDED)) {
        jobs.clear();
    }
    jobs.retain(|j| start.saturating_sub(j.since) < JOB_MAX_SECS);
    [Wait::Human, Wait::Gate, Wait::Test, Wait::Jobs]
        .into_iter()
        .find(|wait| jobs.iter().any(|j| j.wait == *wait))
        .unwrap_or(wake)
}

fn wake_window<'a>(lines: &'a [&'a str], end: u64) -> impl Iterator<Item = &'a &'a str> {
    lines
        .iter()
        .take_while(move |l| entry_epoch(l).is_none_or(|at| at <= end + WAKE_SECS))
}

/// Who ended a long gap: the first entry at the gap's end that says who woke the session.
/// Bookkeeping lands around it, sometimes first: an `api-request` written just before the prompt
/// it sends, a `system` line for a mistyped command. Past WAKE_SECS those are all there is, and
/// nothing the session was running ended the gap.
fn gap_end(lines: &[&str], end: u64) -> Wait {
    for line in wake_window(lines, end) {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let Some(wait) = entry_wait(&v) {
            return wait;
        }
    }
    Wait::Parked
}

/// Who an entry says woke the session, None for bookkeeping.
fn entry_wait(v: &Value) -> Option<Wait> {
    match v.get("type").and_then(Value::as_str)? {
        // A slow model turn is the session working: nothing arrived to end the gap.
        "assistant" => Some(Wait::Work),
        // An enqueue carries the prompt; its dequeue and remove carry nothing.
        "queue-operation" => v
            .get("content")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(prompt_wait),
        "user" if v.get("isMeta").and_then(Value::as_bool) == Some(true) => Some(Wait::Parked),
        "user" => match v.pointer("/message/content")? {
            Value::String(s) => Some(prompt_wait(s)),
            Value::Array(blocks) => {
                if blocks
                    .iter()
                    .any(|c| c.get("type").and_then(Value::as_str) == Some("tool_result"))
                {
                    return Some(Wait::Jobs);
                }
                blocks
                    .iter()
                    .find(|c| c.get("type").and_then(Value::as_str) == Some("text"))
                    .map(|c| prompt_wait(c.get("text").and_then(Value::as_str).unwrap_or("")))
            }
            _ => None,
        },
        _ => None,
    }
}

/// Who a prompt came from, by its opening tag: the harness tags everything it injects.
fn prompt_wait(s: &str) -> Wait {
    if s.starts_with("<task-notification>") && !s.contains(SESSION_ENDED) {
        Wait::Jobs
    } else if !s.starts_with('<') || s.starts_with("<command") || s.starts_with("<local-command") {
        Wait::Human
    } else {
        Wait::Parked
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_util::*;
    use std::fs;

    #[test]
    fn time_use_buckets_a_gap_by_what_ended_it() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            at(
                2,
                r#""type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{}}]}"#,
            ),
            // A foreground tool and a task notification: jobs, 10 + 20.
            at(
                12,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"ok"}]}"#,
            ),
            at(
                32,
                r#""type":"queue-operation","operation":"enqueue","content":"<task-notification> done""#,
            ),
            at(
                32,
                r#""type":"assistant","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}"#,
            ),
            // AskUserQuestion's answer and a typed prompt: human, 30 + 40.
            at(
                62,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"a"}]}"#,
            ),
            at(102, r#""type":"user","message":{"content":"next"}"#),
            // A peer's message and a system record: parked, 50 + 60.
            at(
                152,
                r#""type":"queue-operation","operation":"enqueue","content":"<cross-session-message from=\"x\"> Shepherd""#,
            ),
            at(212, r#""type":"system","subtype":"informational""#),
            // A long model turn is work, 7; a typed prompt queued while busy is human, 8.
            at(219, r#""type":"assistant","message":{"content":[]}"#),
            at(
                227,
                r#""type":"queue-operation","operation":"enqueue","content":"also this""#,
            ),
        ];
        let text = lines.join("\n");
        assert_eq!(
            time_use(&text, &[]),
            TimeUse {
                work_min: 2 + 7,
                jobs_min: 30,
                human_min: 78,
                parked_min: 110,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_ignores_sidechains_snapshots_and_out_of_order_lines() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            // A subagent's entry and a snapshot's nested timestamp must not split the gap.
            at(30, r#""type":"assistant","isSidechain":true,"message":{"content":[]}"#),
            r#"{"type":"file-history-snapshot","snapshot":{"timestamp":"2026-10-30T12:45:00.000Z"}}"#.to_string(),
            at(60, r#""type":"queue-operation","operation":"enqueue","content":"<task-notification>""#),
            // Written out of order: no negative gap, and the next gap runs from the max.
            at(59, r#""type":"assistant","message":{"content":[]}"#),
            at(61, r#""type":"assistant","message":{"content":[]}"#),
        ];
        assert_eq!(
            time_use(&lines.join("\n"), &[]),
            TimeUse {
                work_min: 1,
                jobs_min: 60,
                ..TimeUse::default()
            }
        );
        assert_eq!(time_use("", &[]), TimeUse::default());
    }

    #[test]
    fn time_use_reads_past_bookkeeping_at_a_gaps_end() {
        let lines = [
            at(0, r#""type":"user","message":{"content":"go"}"#),
            // An api-request written just ahead of the prompt it sends: human, 30.
            at(30, r#""type":"api-request""#),
            at(30, r#""type":"user","message":{"content":"back"}"#),
            // A mistyped command's system line, then the retry: human, 40.
            at(
                70,
                r#""type":"system","subtype":"informational","content":"Unknown command""#,
            ),
            at(70, r#""type":"user","message":{"content":"/compact"}"#),
            // A dequeue is bookkeeping too; the notification behind it is jobs, 50.
            at(120, r#""type":"queue-operation","operation":"dequeue""#),
            at(
                120,
                r#""type":"user","message":{"content":"<task-notification>x"}"#,
            ),
            // Bookkeeping with nothing real inside the window: parked, 60. The prompt 20
            // minutes later is its own gap: human, 20.
            at(180, r#""type":"pr-link""#),
            at(200, r#""type":"user","message":{"content":"late"}"#),
        ];
        assert_eq!(
            time_use(&lines.join("\n"), &[]),
            TimeUse {
                jobs_min: 50,
                human_min: 90,
                parked_min: 60,
                ..TimeUse::default()
            }
        );
    }

    /// An assistant entry calling one tool, with the command already quoted for JSON.
    fn call(min: u64, id: &str, name: &str, input: &str) -> String {
        at(
            min,
            &format!(
                r#""type":"assistant","message":{{"content":[{{"type":"tool_use","id":"{id}","name":"{name}","input":{input}}}]}}"#
            ),
        )
    }

    /// The result of a call that went on in the background under `field`.
    fn launched(min: u64, id: &str, field: &str, task: &str) -> String {
        at(
            min,
            &format!(
                r#""type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"{id}","content":"started"}}]}},"toolUseResult":{{"{field}":"{task}"}}"#
            ),
        )
    }

    fn notified(min: u64, inner: &str) -> String {
        at(
            min,
            &format!(
                r#""type":"queue-operation","operation":"enqueue","content":"<task-notification> {inner}""#
            ),
        )
    }

    fn peer(min: u64) -> String {
        at(
            min,
            r#""type":"queue-operation","operation":"enqueue","content":"<cross-session-message from=\"x\"> hi""#,
        )
    }

    const PATTERNS: [(Wait, &str); 2] = [(Wait::Gate, "ci-gate.sh"), (Wait::Test, "run.sh")];

    const GATE: &str =
        r#"{"command":"cd x && scripts/test/ci-gate.sh --pr 1","run_in_background":true}"#;

    const TEST: &str = r#"{"command":"scripts/test/run.sh Foo","run_in_background":true}"#;

    const OTHER: &str = r#"{"command":"sleep 1","run_in_background":true}"#;

    fn buckets(lines: &[String]) -> TimeUse {
        time_use(&lines.join("\n"), &PATTERNS)
    }

    #[test]
    fn time_use_counts_a_gap_by_the_job_still_running_whatever_ended_it() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            // A peer's message and a typed prompt during the gate: gate, 10 + 20.
            peer(10),
            at(30, r#""type":"user","message":{"content":"how is it"}"#),
            // Its own notification: gate, 30. Nothing is running after it.
            notified(60, "<tool-use-id>g</tool-use-id> <status>failed</status>"),
            // A peer's message with nothing running: parked, 40.
            peer(100),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 60,
                parked_min: 40,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn a_build_job_counts_as_jobs_in_time_use_and_reads_build_when_open() {
        let patterns = [(Wait::Test, "run.sh"), (Wait::Build, "unity-method.sh")];
        const BUILD: &str =
            r#"{"command":"scripts/authoring/unity-method.sh RenderCli","run_in_background":true}"#;
        let lines = [
            call(0, "b", "Bash", BUILD),
            launched(0, "b", "backgroundTaskId", "tb"),
            peer(30),
        ];
        let (used, open) = walk(&lines.join("\n"), &patterns);
        // The wait is `jobs`, never `test`: a build is not a test run, and no stat of its own.
        assert_eq!(
            used,
            TimeUse {
                jobs_min: 30,
                ..TimeUse::default()
            }
        );
        assert_eq!(open, "build");
        // A test beside it still wins the open class, as a gate does over a test.
        let both = [
            call(0, "b", "Bash", BUILD),
            launched(0, "b", "backgroundTaskId", "tb"),
            call(1, "t", "Bash", TEST),
            launched(1, "t", "backgroundTaskId", "tt"),
        ];
        assert_eq!(walk(&both.join("\n"), &patterns).1, "test");
    }

    #[test]
    fn time_use_splits_gate_test_and_other_jobs_and_ranks_them() {
        let got = buckets(&[
            call(0, "o", "Bash", OTHER),
            launched(0, "o", "backgroundTaskId", "to"),
            // Other job alone: jobs, 10.
            peer(10),
            call(10, "t", "Bash", TEST),
            launched(10, "t", "backgroundTaskId", "tt"),
            // Test beside it: test, 20.
            peer(30),
            call(30, "g", "Bash", GATE),
            launched(30, "g", "backgroundTaskId", "tg"),
            // Gate beside both: gate, 40.
            notified(
                70,
                "<tool-use-id>g</tool-use-id> <status>completed</status>",
            ),
            // Gate gone: test, 50.
            notified(
                120,
                "<tool-use-id>t</tool-use-id> <status>completed</status>",
            ),
            // Test gone: jobs, 60.
            notified(
                180,
                "<tool-use-id>o</tool-use-id> <status>completed</status>",
            ),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 40,
                test_min: 70,
                jobs_min: 70,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_an_open_dialog_is_you_even_with_a_gate_running() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            call(0, "q", "AskUserQuestion", "{}"),
            at(
                30,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q","content":"a"}]}"#,
            ),
            // The dialog is answered and the gate still runs: gate, 10.
            peer(40),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 10,
                human_min: 30,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_a_foreground_gate_counts_and_ends_with_its_result() {
        let got = buckets(&[
            call(0, "g", "Bash", r#"{"command":"scripts/test/ci-gate.sh"}"#),
            at(
                10,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g","content":"ok"}]}"#,
            ),
            peer(30),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 10,
                parked_min: 20,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_a_monitor_event_does_not_end_its_watch_but_an_expiry_does() {
        let got = buckets(&[
            call(
                0,
                "m",
                "Monitor",
                r#"{"command":"tail -f scripts/test/ci-gate.sh.log"}"#,
            ),
            launched(0, "m", "taskId", "tm"),
            // An event, by task id and with no status: the watch stays open, gate, 10 + 10.
            notified(
                10,
                r#"<task-id>tm</task-id> <summary>Monitor event: x</summary>"#,
            ),
            peer(20),
            // The expiry ends the gap as gate, 10, and ends the watch: parked, 10.
            notified(
                30,
                r#"<task-id>tm</task-id> <event>[Monitor expired after 30m]</event>"#,
            ),
            peer(40),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 30,
                parked_min: 10,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_a_task_stop_ends_the_job_it_names() {
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            peer(10),
            call(10, "t2", "Bash", TEST),
            launched(10, "t2", "backgroundTaskId", "tt"),
            call(10, "s", "TaskStop", r#"{"task_id":"tg"}"#),
            at(
                10,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s","content":"ok"}]},"toolUseResult":{"task_id":"tg"}"#,
            ),
            // The gate was stopped, the test still runs: test, 20.
            peer(30),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 10,
                test_min: 20,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn open_job_names_the_strongest_wait_still_running_at_the_last_entry() {
        let open = |lines: &[String]| walk(&lines.join("\n"), &PATTERNS).1;
        // A sleep loop alone is `jobs`: fleet-sessions stops trusting it after FLEET_IDLE_MIN.
        assert_eq!(
            open(&[
                call(0, "o", "Bash", OTHER),
                launched(0, "o", "backgroundTaskId", "to")
            ]),
            "jobs"
        );
        // A gate beside it wins, and so does a test.
        assert_eq!(
            open(&[
                call(0, "o", "Bash", OTHER),
                launched(0, "o", "backgroundTaskId", "to"),
                call(1, "g", "Bash", GATE),
                launched(1, "g", "backgroundTaskId", "tg"),
            ]),
            "gate"
        );
        assert_eq!(
            open(&[
                call(0, "t", "Bash", TEST),
                launched(0, "t", "backgroundTaskId", "tt")
            ]),
            "test"
        );
        // A background subagent is work done elsewhere, not a wait loop.
        assert_eq!(
            open(&[
                call(0, "a", "Agent", r#"{"prompt":"x"}"#),
                launched(0, "a", "resumedAgentId", "ta")
            ]),
            "agent"
        );
        // A job whose result came back, or a job older than JOB_MAX_SECS, is not open.
        let done = at(
            1,
            r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g","content":"ok"}]}"#,
        );
        assert_eq!(open(&[call(0, "g", "Bash", GATE), done]), "none");
        assert_eq!(
            open(&[
                call(0, "o", "Bash", OTHER),
                launched(0, "o", "backgroundTaskId", "to"),
                peer(13 * 60)
            ]),
            "none"
        );
        assert_eq!(open(&[]), "none");
    }

    #[test]
    fn open_job_counts_the_shared_ci_waiter_as_a_gate_under_the_shipped_conf() {
        let conf = include_str!("../../../../../.config/agent-panel/time-use.conf");
        let open = |cmd: &str| {
            let input = format!(r#"{{"command":"{cmd}","run_in_background":true}}"#);
            walk(
                &[
                    call(0, "w", "Bash", &input),
                    launched(0, "w", "backgroundTaskId", "tw"),
                ]
                .join("\n"),
                &job_patterns(conf),
            )
            .1
        };
        assert_eq!(open("gh-run-wait 42349132239 'Release builds'"), "gate");
        assert_eq!(open("scripts/authoring/unity-method.sh RenderCli"), "build");
        // A wrapper script of the session's own hides its gh run view: a plain job.
        assert_eq!(open("/tmp/run-wait-1106.sh 42349132239"), "jobs");
    }

    #[test]
    fn time_use_agents_run_in_the_background_only_when_the_result_says_so() {
        let got = buckets(&[
            call(0, "a", "Agent", r#"{"prompt":"look"}"#),
            at(
                0,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag"}"#,
            ),
            // By task id alone, the way a finished agent can report: jobs, 10, then parked, 10.
            notified(10, r#"<task-id>ag</task-id> <status>completed</status>"#),
            peer(20),
            call(20, "b", "Agent", r#"{"prompt":"look"}"#),
            // Waited for: the result ends it, jobs, 10, then parked, 10.
            at(
                30,
                r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"x"}]},"toolUseResult":{"status":"completed","agentId":"ag2"}"#,
            ),
            peer(40),
        ]);
        assert_eq!(
            got,
            TimeUse {
                jobs_min: 20,
                parked_min: 20,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_a_job_that_never_closes_stops_counting() {
        // Older than JOB_MAX_SECS when the last gap starts: parked, not gate.
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            peer(600),
            peer(730),
            peer(830),
        ]);
        assert_eq!(
            got,
            TimeUse {
                gate_min: 730,
                parked_min: 100,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn time_use_a_resume_means_the_jobs_died_with_the_old_process() {
        let ended = r#"<tool-use-id>g</tool-use-id> <status>stopped</status> <summary>Background shell command didn't finish before the previous session ended</summary>"#;
        let got = buckets(&[
            call(0, "g", "Bash", GATE),
            launched(0, "g", "backgroundTaskId", "tg"),
            // The gate "ran" to the resume, by this record, but the session was gone: parked, 300.
            notified(300, ended),
            peer(310),
        ]);
        assert_eq!(
            got,
            TimeUse {
                parked_min: 310,
                ..TimeUse::default()
            }
        );
    }

    #[test]
    fn the_shipped_time_use_conf_names_a_gate_and_a_test_and_reads_every_line() {
        let conf = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../.config/agent-panel/time-use.conf"
        );
        let conf = fs::read_to_string(conf).unwrap();
        let patterns = job_patterns(&conf);
        let rows = conf
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
            .count();
        assert_eq!(
            patterns.len(),
            rows,
            "a line in time-use.conf is not `gate <text>` or `test <text>`"
        );
        let kind = |command: &str| {
            patterns
                .iter()
                .find(|(_, t)| command.contains(t))
                .map(|(w, _)| *w)
        };
        assert!(kind("scripts/test/ci-gate.sh --pr 1") == Some(Wait::Gate));
        // The playground's whole-nightly runner, a phase's proof run (2026-11-12 agent-6 read STALLED on it).
        assert!(kind("agentctl-playground-night --only test > night.log 2>&1") == Some(Wait::Test));
        assert!(kind("gh pr checks 12 --watch") == Some(Wait::Gate));
        assert!(kind("timeout -k 60 10800 bash Logs/land3.sh 2>&1 | tail -25") == Some(Wait::Gate));
        assert!(kind("scripts/gate.sh && agent-land 12 --item x") == Some(Wait::Gate));
        assert!(kind("scripts/test/run.sh Foo") == Some(Wait::Test));
        assert!(kind("make -C tests test-fast") == Some(Wait::Test));
        assert!(kind("sleep 5").is_none());
    }
}
