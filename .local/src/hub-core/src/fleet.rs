//! The Fleet tab, read once for both surfaces (agent-web's Fleet tab and the hub TUI's): who
//! pays, what each agentctl runner did, and how the two judges call it. Nothing here keeps a
//! copy; each part reads the file or series its writer owns:
//!
//! | part         | source                                                                   |
//! |--------------|--------------------------------------------------------------------------|
//! | accounts     | `claude_account_*`, claude-acct's textfile, in Prometheus                 |
//! | workers      | `~/.config/agentctl/agents/*.conf`, agentctl's `runs.jsonl`, each runner's `<INBOX>/activity.log` (agent-proof), the user timers, and `claude_code_cost_usage_USD_total` by `agentctl_runner` |
//! | dispatch     | the tail of fleet-dispatch's `verdicts.jsonl` and `log.md`                |
//! | answer judge | `judge-eval ask-judge --json`, the one scorer (`~/.local/src/docs/judges.md`) |
//!
//! The file parts are read fresh (judge-eval takes about a second); the Prometheus part (`prom`) is the slow one, so a
//! server can cache it apart and `apply` it to a fresh file read.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, TimeZone};
use serde::{Deserialize, Serialize};

use crate::jobs::{self, Job, State};
use crate::prom::{self, Series};

const DAY: i64 = 24 * 3600;
const WEEK: i64 = 7 * DAY;
/// Verdicts listed, newest first.
const RECENT_VERDICTS: usize = 30;
/// Disagreements listed, newest first.
const RECENT_DISAGREE: usize = 10;
/// How much of the end of each append-only log is read. verdicts.jsonl grows about 400 bytes a
/// verdict, so 1 MiB is several weeks; a tail that still starts inside the week says so.
const VERDICT_TAIL: u64 = 1 << 20;
const LOG_TAIL: u64 = 256 << 10;
const ACTIVITY_TAIL: u64 = 16 << 10;

/// Each runner's dollars in the last day, by the OTel resource attribute agentctl sets.
const COST_BY_RUNNER: &str = r#"sum by (agentctl_runner) (increase(claude_code_cost_usage_USD_total{service_name="claude-agentctl"}[24h]))"#;
const COST_TOTAL: &str =
    r#"sum(increase(claude_code_cost_usage_USD_total{service_name="claude-agentctl"}[24h]))"#;
/// claude-acct's textfile, only while it is fresh; no `max without`, which would drop the
/// metric names the table reads. An empty answer makes the table say no data.
const ACCOUNTS: &str = r#"{__name__=~"claude_account_.+"} and on (instance) (time() - node_textfile_mtime_seconds{file=~".*claude_acct.prom"} < 3600)"#;

#[derive(Clone, Debug)]
pub struct Paths {
    /// agentctl's runner configs, one `<name>.conf` each (agentctl's `CONFIG_DIR`).
    pub agents: PathBuf,
    pub jobs: jobs::Paths,
    pub dispatch: PathBuf,
    /// The judge scorer; `JUDGE_EVAL` overrides it (tests, a checkout).
    pub judge_eval: String,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Paths {
            agents: home.join(".config/agentctl/agents"),
            jobs: jobs::Paths::from_env(),
            dispatch: crate::boards::dispatch_dir(),
            judge_eval: std::env::var("JUDGE_EVAL").unwrap_or_else(|_| "judge-eval".into()),
        }
    }
}

#[derive(Serialize, Debug, Default, Clone)]
pub struct Fleet {
    /// When the files were read, unix seconds.
    pub at: i64,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
    /// claude-acct's series as Prometheus gave them.
    pub accounts: Vec<Series>,
    pub workers: Vec<Worker>,
    /// Every agentctl run's dollars in the last day, labelled or not.
    pub cost_24h: Option<f64>,
    pub dispatch: Dispatch,
    pub judge: Judge,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Worker {
    pub name: String,
    pub lane: String,
    pub description: String,
    pub schedule: String,
    pub enabled: bool,
    /// Set while its unit runs.
    pub running_since: Option<i64>,
    /// Its newest finished run in the week, else its newest activity line.
    pub last: Option<Outcome>,
    pub runs_24h: u32,
    pub failed_24h: u32,
    /// The newest activity.log line: the runner's own word on why.
    pub why: Option<Outcome>,
    pub next: Option<i64>,
    /// None until its cost series carries the runner label.
    pub cost_24h: Option<f64>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Outcome {
    /// WORKED, NOOP, FAILED, or systemd's word when the unit itself failed.
    pub word: String,
    /// false failed, true passed, None neither (BLOCKED).
    pub ok: Option<bool>,
    pub at: Option<i64>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub text: String,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
pub struct Verdict {
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub verdict: String,
    #[serde(default)]
    pub reason: String,
    pub tier: Option<f64>,
    pub clear: Option<bool>,
    /// RFC 3339 as written; `ts` is it in unix seconds.
    #[serde(default)]
    pub at: String,
    #[serde(default)]
    pub ts: i64,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Dispatch {
    pub recent: Vec<Verdict>,
    pub counts_24h: BTreeMap<String, u32>,
    pub counts_7d: BTreeMap<String, u32>,
    /// The read tail starts inside the week, so `counts_7d` is a floor.
    pub partial: bool,
    /// log.md's lines in the last day, by verb: started, reaped, filled, settled.
    pub log_24h: BTreeMap<String, u32>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Judge {
    /// Answered, and the human's answer (or the review of a live answer) matched.
    pub agree: u32,
    pub disagree: u32,
    /// The judge said this one is the human's ("asks-you").
    pub deferred: u32,
    /// Deferred, and the human took the recommendation anyway.
    pub false_defer: u32,
    /// Judged, still waiting on the human.
    pub pending: u32,
    /// Answered in the session as free text naming no option, which no call can match.
    pub unscored: u32,
    /// agree / (agree + disagree) in percent, and Cohen's kappa; null with nothing scored.
    pub precision: Option<f64>,
    pub kappa: Option<f64>,
    /// The judge prompt the counts are under (its git blob, short).
    pub prompt: String,
    pub disagreements: Vec<Disagreement>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Disagreement {
    pub id: String,
    pub project: String,
    pub question: String,
    /// What the judge would have answered.
    pub judge: String,
    pub reason: String,
    pub answer: String,
    pub answered_at: Option<i64>,
}

/// The Prometheus part, cached apart by a server.
#[derive(Serialize, Debug, Default, Clone)]
pub struct Prom {
    pub accounts: Vec<Series>,
    pub cost_by_runner: BTreeMap<String, f64>,
    pub cost_total: Option<f64>,
    pub errors: Vec<String>,
}

/// Both parts, for a caller with no cache (the TUI).
pub fn collect() -> Fleet {
    let mut f = files(&Paths::from_env());
    f.apply(&prom());
    f
}

/// The file-backed parts.
pub fn files(paths: &Paths) -> Fleet {
    let at = jobs::now();
    let mut errors = vec![];
    let (confs, e) = read_confs(&paths.agents, &paths.jobs.agentctl);
    errors.extend(e.into_iter().map(|e| format!("workers: {e}")));
    let (runs, e) = jobs::agentctl_runs(&paths.jobs, at - WEEK);
    errors.extend(e.into_iter().map(|e| format!("workers: {e}")));
    let timers = jobs::timer_starts().unwrap_or_else(|e| {
        errors.push(format!("timers: {e}"));
        HashMap::new()
    });
    let activity: HashMap<String, Outcome> = confs
        .iter()
        .filter_map(|c| {
            let (text, _) = tail(&c.inbox.join("activity.log"), ACTIVITY_TAIL).ok()?;
            Some((c.name.clone(), text.lines().rev().find_map(parse_activity)?))
        })
        .collect();
    let workers = workers(confs, &runs, &activity, &timers, at);

    let mut dispatch = match tail(&paths.dispatch.join("verdicts.jsonl"), VERDICT_TAIL) {
        Ok((text, cut)) => verdicts(&text, cut, at),
        Err(e) => {
            errors.push(format!("dispatch: {e}"));
            Dispatch::default()
        }
    };
    match tail(&paths.dispatch.join("log.md"), LOG_TAIL) {
        Ok((text, _)) => dispatch.log_24h = log_counts(&text, &local_minute(at - DAY)),
        Err(e) => errors.push(format!("dispatch log: {e}")),
    }
    let judge = run_judge_eval(&paths.judge_eval)
        .and_then(|t| judge(&t))
        .unwrap_or_else(|e| {
            errors.push(format!("answer judge: {e}"));
            Judge::default()
        });
    Fleet {
        at,
        errors,
        workers,
        dispatch,
        judge,
        ..Default::default()
    }
}

/// The Prometheus part: accounts, cost per runner and the total, asked at once.
pub fn prom() -> Prom {
    let mut out = Prom::default();
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => {
            out.errors.push(format!("prometheus: {e}"));
            return out;
        }
    };
    let qs = [
        ("accounts", ACCOUNTS),
        ("cost", COST_BY_RUNNER),
        ("cost total", COST_TOTAL),
    ];
    let answers: Vec<_> = std::thread::scope(|s| {
        let hs: Vec<_> = qs
            .iter()
            .map(|&(n, q)| {
                let base = &base;
                (n, s.spawn(move || prom::instant(base, q)))
            })
            .collect();
        hs.into_iter()
            .map(|(n, h)| (n, h.join().unwrap_or_else(|_| Err("panicked".into()))))
            .collect()
    });
    for (name, res) in answers {
        match (name, res) {
            (_, Err(e)) => out.errors.push(format!("{name}: {e}")),
            ("accounts", Ok(s)) => out.accounts = s,
            ("cost", Ok(s)) => out.cost_by_runner = costs(&s),
            (_, Ok(s)) => out.cost_total = s.first().and_then(|x| x.value),
        }
    }
    out
}

impl Fleet {
    /// Lay a Prometheus read over the file read: accounts, the total, each runner's dollars.
    pub fn apply(&mut self, p: &Prom) {
        self.accounts = p.accounts.clone();
        self.cost_24h = p.cost_total;
        for w in &mut self.workers {
            w.cost_24h = p.cost_by_runner.get(&w.name).copied();
        }
        self.errors.extend(p.errors.iter().cloned());
    }
}

/// Dollars by runner. A series with no `agentctl_runner` (runs from before the label) is in
/// the total only.
pub fn costs(series: &[Series]) -> BTreeMap<String, f64> {
    series
        .iter()
        .filter(|s| !s.label("agentctl_runner").is_empty())
        .filter_map(|s| Some((s.label("agentctl_runner").to_string(), s.value?)))
        .collect()
}

/// One runner's config: only what the tab shows.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Conf {
    pub name: String,
    pub lane: String,
    pub description: String,
    pub schedule: String,
    pub enabled: bool,
    pub inbox: PathBuf,
}

/// A conf's `KEY=value` lines as agentctl sources them, for the keys read here. Quotes are
/// stripped and `$HOME` expanded; nothing fancier is.
pub fn parse_conf(name: &str, text: &str, home: &str, state: &Path) -> Conf {
    let mut kv: HashMap<&str, String> = HashMap::new();
    for l in text.lines() {
        let l = l.trim();
        let l = l.strip_prefix("export ").unwrap_or(l);
        let Some((k, v)) = l.split_once('=') else {
            continue;
        };
        if !matches!(k, "LANE" | "DESCRIPTION" | "SCHEDULE" | "ENABLED" | "INBOX") {
            continue;
        }
        let v = v.trim();
        let v = v
            .strip_prefix('"')
            .and_then(|x| x.strip_suffix('"'))
            .or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
            .unwrap_or(v);
        kv.insert(k, v.replace("${HOME}", home).replace("$HOME", home));
    }
    let get = |k: &str| kv.get(k).cloned().unwrap_or_default();
    Conf {
        name: name.to_string(),
        lane: get("LANE"),
        description: get("DESCRIPTION"),
        schedule: get("SCHEDULE"),
        enabled: get("ENABLED") != "no",
        inbox: kv
            .get("INBOX")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| state.join(name)),
    }
}

fn read_confs(dir: &Path, state: &Path) -> (Vec<Conf>, Vec<String>) {
    let home = std::env::var("HOME").unwrap_or_default();
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) => return (vec![], vec![format!("{}: {e}", dir.display())]),
    };
    let mut errors = vec![];
    let mut out = vec![];
    for p in rd.flatten().map(|e| e.path()) {
        let Some(name) = p
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_suffix(".conf"))
        else {
            continue;
        };
        match std::fs::read_to_string(&p) {
            Ok(t) => out.push(parse_conf(name, &t, &home, state)),
            Err(e) => errors.push(format!("{}: {e}", p.display())),
        }
    }
    (out, errors)
}

/// One activity.log line, `[<iso time>] outcome=<WORD> <detail>` (agent-proof.sh).
pub fn parse_activity(line: &str) -> Option<Outcome> {
    let rest = line.strip_prefix('[')?;
    let (when, rest) = rest.split_once("] ")?;
    let rest = rest.strip_prefix("outcome=")?;
    let (word, text) = rest.split_once(' ').unwrap_or((rest, ""));
    Some(Outcome {
        word: word.to_string(),
        ok: word_ok(word),
        at: ts(when),
        text: text.trim().to_string(),
    })
}

/// agent-proof's verdicts: FAILED and STALLED fail, BLOCKED waits, the rest pass.
fn word_ok(word: &str) -> Option<bool> {
    match word {
        "FAILED" | "STALLED" => Some(false),
        "BLOCKED" => None,
        _ => Some(true),
    }
}

/// One row per configured runner, from its runs in the ledger (the week before `at`), its
/// newest activity line, and its timer. A ledger name with no conf is a retired runner and
/// gets no row. Enabled runners first, then by name.
pub fn workers(
    confs: Vec<Conf>,
    runs: &[Job],
    activity: &HashMap<String, Outcome>,
    timers: &HashMap<String, i64>,
    at: i64,
) -> Vec<Worker> {
    let mut out: Vec<Worker> = confs
        .into_iter()
        .map(|c| {
            let mine: Vec<&Job> = runs.iter().filter(|j| j.name == c.name).collect();
            let mut w = Worker {
                next: timers
                    .get(&format!("agentctl@{}.service", c.name))
                    .copied()
                    .filter(|&n| n > 0),
                why: activity.get(&c.name).cloned(),
                name: c.name,
                lane: c.lane,
                description: c.description,
                schedule: c.schedule,
                enabled: c.enabled,
                ..Default::default()
            };
            let mut newest: Option<&Job> = None;
            for j in mine {
                if j.state == State::Running {
                    w.running_since = j.started.or(Some(at));
                    continue;
                }
                if j.finished.is_some_and(|f| f >= at - DAY) {
                    w.runs_24h += 1;
                    w.failed_24h += u32::from(j.ok == Some(false));
                }
                if newest.is_none_or(|n| j.finished > n.finished) {
                    newest = Some(j);
                }
            }
            w.last = newest
                .map(|j| Outcome {
                    word: j.result.clone(),
                    ok: j.ok,
                    at: j.finished,
                    text: String::new(),
                })
                .or_else(|| {
                    w.why.clone().map(|o| Outcome {
                        text: String::new(),
                        ..o
                    })
                });
            w
        })
        .collect();
    out.sort_by(|a, b| b.enabled.cmp(&a.enabled).then_with(|| a.name.cmp(&b.name)));
    out
}

/// The verdicts tail: the newest first, and counts by verdict for the day and the week before
/// `at`. `cut` says the tail is not the whole file.
pub fn verdicts(text: &str, cut: bool, at: i64) -> Dispatch {
    let mut d = Dispatch::default();
    let mut oldest = i64::MAX;
    let mut all: Vec<Verdict> = text
        .lines()
        .filter_map(|l| serde_json::from_str::<Verdict>(l).ok())
        .filter_map(|mut v| {
            v.ts = ts(&v.at)?;
            Some(v)
        })
        .collect();
    for v in &all {
        oldest = oldest.min(v.ts);
        if v.ts >= at - WEEK {
            *d.counts_7d.entry(v.verdict.clone()).or_default() += 1;
        }
        if v.ts >= at - DAY {
            *d.counts_24h.entry(v.verdict.clone()).or_default() += 1;
        }
    }
    d.partial = cut && oldest >= at - WEEK;
    // The file is in write order; a stable sort keeps one pass's verdicts in that order.
    all.sort_by_key(|v| std::cmp::Reverse(v.ts));
    all.truncate(RECENT_VERDICTS);
    d.recent = all;
    d
}

/// log.md lines (`- YYYY-MM-DD HH:MM <verb> ...`, local time) at or after `since`, by verb.
/// The fixed-width stamp compares as text.
pub fn log_counts(text: &str, since: &str) -> BTreeMap<String, u32> {
    let mut out = BTreeMap::new();
    for l in text.lines() {
        let Some(rest) = l.strip_prefix("- ") else {
            continue;
        };
        if rest.len() < 17 || !rest.is_char_boundary(16) || &rest[..16] < since {
            continue;
        }
        if let Some(verb) = rest[16..].split_whitespace().next() {
            *out.entry(verb.to_string()).or_default() += 1;
        }
    }
    out
}

fn local_minute(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map(|d| d.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_default()
}

fn run_judge_eval(cmd: &str) -> Result<String, String> {
    let out = std::process::Command::new(cmd)
        .args(["ask-judge", "--json"])
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{cmd} exited {}", out.status));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The answer judge's tiles from `judge-eval ask-judge --json`, under its current prompt. No
/// count is made here: judge-eval is the one scorer.
pub fn judge(json: &str) -> Result<Judge, String> {
    #[derive(Deserialize)]
    struct Eval {
        agents: Vec<Agent>,
    }
    #[derive(Deserialize)]
    struct Agent {
        agent: String,
        prompt_sha: String,
        total: Total,
        misses: Vec<Miss>,
    }
    #[derive(Deserialize)]
    struct Total {
        tp: u32,
        fp: u32,
        #[serde(rename = "fn")]
        false_defer: u32,
        deferred: u32,
        pending: u32,
        unscorable: u32,
        precision: Option<f64>,
        kappa: Option<f64>,
    }
    #[derive(Deserialize)]
    struct Miss {
        id: String,
        project: String,
        question: Option<String>,
        judge: Option<String>,
        reason: Option<String>,
        answer: Option<String>,
        answered_at: Option<i64>,
    }
    let e: Eval = serde_json::from_str(json).map_err(|e| format!("judge-eval: {e}"))?;
    let a = e
        .agents
        .into_iter()
        .find(|a| a.agent == "ask-judge")
        .ok_or("judge-eval: no ask-judge block")?;
    let t = a.total;
    Ok(Judge {
        agree: t.tp,
        disagree: t.fp,
        deferred: t.deferred,
        false_defer: t.false_defer,
        pending: t.pending,
        unscored: t.unscorable,
        precision: t.precision,
        kappa: t.kappa,
        prompt: a.prompt_sha.chars().take(7).collect(),
        disagreements: a
            .misses
            .into_iter()
            .take(RECENT_DISAGREE)
            .map(|m| Disagreement {
                id: m.id,
                project: m.project,
                question: m.question.unwrap_or_default(),
                judge: m.judge.unwrap_or_default(),
                reason: m.reason.unwrap_or_default(),
                answer: m.answer.unwrap_or_default(),
                answered_at: m.answered_at,
            })
            .collect(),
    })
}

/// Unix seconds from RFC 3339 (`date -Is`) or agent-ask's `%Y-%m-%dT%H:%M:%S%z` (no colon).
pub fn ts(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s)
        .or_else(|_| DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%z"))
        .ok()
        .map(|d| d.timestamp())
}

/// The last `max` bytes of a file, from the first whole line, and whether that cut anything.
/// A missing file is empty: a fresh install has no log yet.
fn tail(p: &Path, max: u64) -> Result<(String, bool), String> {
    let err = |e: std::io::Error| format!("{}: {e}", p.display());
    let mut f = match std::fs::File::open(p) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((String::new(), false)),
        Err(e) => return Err(err(e)),
    };
    let len = f.metadata().map_err(err)?.len();
    let from = len.saturating_sub(max);
    f.seek(SeekFrom::Start(from)).map_err(err)?;
    let mut buf = vec![];
    f.read_to_end(&mut buf).map_err(err)?;
    let text = String::from_utf8_lossy(&buf).into_owned();
    if from == 0 {
        return Ok((text, false));
    }
    Ok((
        text.split_once('\n')
            .map(|(_, r)| r.to_string())
            .unwrap_or_default(),
        true,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: i64 = 1_762_200_000; // 2025-11-03T12:00:00-08:00

    fn conf(name: &str, enabled: bool) -> Conf {
        Conf {
            name: name.into(),
            enabled,
            ..Default::default()
        }
    }

    #[test]
    fn timestamps_with_and_without_a_colon_in_the_offset() {
        assert_eq!(ts("2026-11-02T15:17:08-08:00"), Some(1_793_661_428));
        assert_eq!(ts("2026-11-02T15:17:08-0800"), Some(1_793_661_428));
        assert_eq!(ts("yesterday"), None);
    }

    #[test]
    fn a_conf_reads_its_keys_and_defaults_the_rest() {
        let c = parse_conf(
            "brief",
            "# a comment\nNAME=brief\nLANE=observe\nDESCRIPTION='Morning briefing'\nSCHEDULE='*-*-* 06:45:00'\nINBOX=\"$HOME/.local/state/agentctl/brief\"\n",
            "/home/k",
            Path::new("/st"),
        );
        assert_eq!(c.lane, "observe");
        assert_eq!(c.description, "Morning briefing");
        assert_eq!(c.schedule, "*-*-* 06:45:00");
        assert!(c.enabled, "ENABLED defaults to yes");
        assert_eq!(
            c.inbox,
            PathBuf::from("/home/k/.local/state/agentctl/brief")
        );
        let off = parse_conf("x", "ENABLED=no\n", "/home/k", Path::new("/st"));
        assert!(!off.enabled);
        assert_eq!(
            off.inbox,
            PathBuf::from("/st/x"),
            "INBOX defaults to <state>/<name>"
        );
    }

    #[test]
    fn an_activity_line_parses() {
        let o = parse_activity(
            "[2026-11-03T19:48:08-08:00] outcome=NOOP interactive shepherd live (3m)",
        )
        .unwrap();
        assert_eq!(o.word, "NOOP");
        assert_eq!(o.ok, Some(true));
        assert_eq!(o.text, "interactive shepherd live (3m)");
        assert_eq!(o.at, ts("2026-11-03T19:48:08-08:00"));
        assert_eq!(
            parse_activity("[2026-11-03T19:48:08-08:00] outcome=BLOCKED")
                .unwrap()
                .ok,
            None
        );
        assert!(parse_activity("free text").is_none());
    }

    #[test]
    fn the_ledger_aggregates_per_runner() {
        let line = |name: &str, fin: i64, result: &str, outcome: &str| {
            format!(
                r#"{{"name":"{name}","invocation":"abc","started":{},"finished":{fin},"result":"{result}","exit":"1","outcome":"{outcome}","out":[0,1],"err":[0,1]}}"#,
                fin - 30
            )
        };
        let ledger = [
            line("dream", T - 3 * DAY, "success", "WORKED"),
            line("dream", T - 3600, "success", "NOOP"),
            line("dream", T - 600, "exit-code", ""),
            line("sentinel", T - 2 * DAY, "success", "WORKED"),
            line("sentinel", T - 120, "success", "STALLED"),
            line("retired", T - 60, "success", "WORKED"),
        ]
        .join("\n");
        let (mut runs, bad) = jobs::parse_agentctl_ledger(&ledger, T - WEEK);
        assert_eq!(bad, 0);
        let mut live = Job::new(jobs::Source::Agentctl, "sentinel", State::Running);
        live.started = Some(T - 5);
        runs.push(live);
        let activity = HashMap::from([(
            "idle".to_string(),
            parse_activity("[2026-11-03T10:00:00-08:00] outcome=NOOP nothing to do").unwrap(),
        )]);
        let timers = HashMap::from([("agentctl@dream.service".to_string(), T + 900)]);
        let w = workers(
            vec![
                conf("sentinel", true),
                conf("off", false),
                conf("dream", true),
                conf("idle", true),
            ],
            &runs,
            &activity,
            &timers,
            T,
        );
        let names: Vec<_> = w.iter().map(|w| w.name.as_str()).collect();
        assert_eq!(
            names,
            ["dream", "idle", "sentinel", "off"],
            "no row for a retired runner"
        );

        let dream = &w[0];
        assert_eq!(
            (dream.runs_24h, dream.failed_24h),
            (2, 1),
            "the 3-day-old run is out of the day"
        );
        let last = dream.last.as_ref().unwrap();
        assert_eq!(
            (last.word.as_str(), last.ok, last.at),
            ("exit-code exit=1", Some(false), Some(T - 600))
        );
        assert_eq!(dream.next, Some(T + 900));
        assert_eq!(dream.running_since, None);

        let s = &w[2];
        assert_eq!((s.runs_24h, s.failed_24h), (1, 1), "STALLED is a failure");
        assert_eq!(s.running_since, Some(T - 5));
        assert_eq!(s.last.as_ref().unwrap().word, "STALLED");

        let idle = &w[1];
        assert_eq!(idle.runs_24h, 0);
        assert_eq!(
            idle.last.as_ref().unwrap().word,
            "NOOP",
            "no run in the week: its activity line"
        );
        assert_eq!(idle.why.as_ref().unwrap().text, "nothing to do");
        assert!(w[3].last.is_none() && w[3].next.is_none());
    }

    #[test]
    fn verdicts_count_by_window() {
        let v = |verdict: &str, at: &str| {
            format!(
                r#"{{"project":"p","key":"k {at}","tier":3,"clear":true,"verdict":"{verdict}","reason":"r","at":"{at}"}}"#
            )
        };
        let text = [
            v("skip", "2025-10-20T12:00:00-08:00"),
            v("dispatch", "2025-10-30T12:00:00-08:00"),
            v("skip", "2025-11-03T01:00:00-08:00"),
            v("failed", "2025-11-03T11:00:00-08:00"),
            "not json".to_string(),
            r#"{"project":"p","key":"k","verdict":"skip","tier":null,"clear":null,"at":"2025-11-03T11:30:00-08:00"}"#.to_string(),
        ]
        .join("\n");
        let d = verdicts(&text, false, T);
        assert_eq!(
            d.counts_24h,
            BTreeMap::from([("failed".into(), 1), ("skip".into(), 2)])
        );
        assert_eq!(
            d.counts_7d,
            BTreeMap::from([
                ("dispatch".into(), 1),
                ("failed".into(), 1),
                ("skip".into(), 2)
            ])
        );
        assert!(!d.partial);
        assert_eq!(d.recent.len(), 5);
        assert_eq!(
            d.recent[0].tier, None,
            "newest first; a null tier stays null"
        );
        assert_eq!(d.recent[1].verdict, "failed");
        assert!(
            !verdicts(&text, true, T).partial,
            "the cut tail still reaches past the week"
        );
        assert!(
            verdicts(
                &text.lines().skip(2).collect::<Vec<_>>().join("\n"),
                true,
                T
            )
            .partial
        );
    }

    #[test]
    fn log_lines_count_by_verb_since_a_minute() {
        let text = "# fleet-dispatch\n- 2026-11-02 10:39 started a\n- 2026-11-03 09:00 started b\n- 2026-11-03 09:00 reaped c: gone\n- 2026-11-03 16:09 filled 3 rows\nfree text\n";
        assert_eq!(
            log_counts(text, "2026-11-03 09:00"),
            BTreeMap::from([
                ("filled".into(), 1),
                ("reaped".into(), 1),
                ("started".into(), 1)
            ])
        );
    }

    #[test]
    fn the_answer_judge_tiles_are_judge_evals_numbers() {
        let json = r#"{"at":1,"agents":[
          {"agent":"ask-judge","prompt_sha":"60c840b1234","total":{"verdicts":9,"tp":2,"fp":1,"fn":3,"tn":1,
            "deferred":4,"pending":1,"unscorable":2,"precision":66.7,"kappa":0.12},
           "misses":[{"id":"Ab1","project":"p","question":"q?","judge":"yes","reason":"because",
             "answer":"no","rule":"r","answered_at":1700000000}]}]}"#;
        let j = judge(json).unwrap();
        assert_eq!(
            (j.agree, j.disagree, j.deferred, j.false_defer, j.pending, j.unscored),
            (2, 1, 4, 3, 1, 2)
        );
        assert_eq!((j.precision, j.kappa), (Some(66.7), Some(0.12)));
        assert_eq!(j.prompt, "60c840b");
        assert_eq!(j.disagreements[0].judge, "yes");
        assert_eq!(j.disagreements[0].answered_at, Some(1_700_000_000));
    }

    #[test]
    fn a_judge_eval_answer_with_no_ask_judge_block_is_an_error_not_zeros() {
        assert!(judge(r#"{"agents":[]}"#).is_err());
        assert!(judge("not json").is_err());
    }

    #[test]
    fn cost_needs_the_runner_label() {
        let s = |runner: Option<&str>, v: f64| Series {
            labels: runner
                .map(|r| BTreeMap::from([("agentctl_runner".to_string(), r.to_string())]))
                .unwrap_or_default(),
            value: Some(v),
            points: vec![],
        };
        let c = costs(&[s(None, 44.9), s(Some("dream"), 1.5)]);
        assert_eq!(c, BTreeMap::from([("dream".into(), 1.5)]));
        let mut f = Fleet {
            workers: vec![
                Worker {
                    name: "dream".into(),
                    ..Default::default()
                },
                Worker {
                    name: "sentinel".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        f.apply(&Prom {
            cost_by_runner: c,
            cost_total: Some(46.4),
            ..Default::default()
        });
        assert_eq!(f.workers[0].cost_24h, Some(1.5));
        assert_eq!(f.workers[1].cost_24h, None, "no labelled cost shows as -");
        assert_eq!(f.cost_24h, Some(46.4));
    }

    #[test]
    fn a_tail_starts_at_a_whole_line() {
        let dir = std::env::temp_dir().join(format!("hub-fleet-tail-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("log");
        std::fs::write(&p, "first line\nsecond\nthird\n").unwrap();
        assert_eq!(tail(&p, 10).unwrap(), ("third\n".to_string(), true));
        assert!(!tail(&p, 1000).unwrap().1);
        assert_eq!(tail(&dir.join("none"), 10).unwrap(), (String::new(), false));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
