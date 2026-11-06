//! The Fleet tab, read once for both surfaces (agent-web's Fleet tab and the hub TUI's): who
//! pays, what each agentctl runner did, and how the two judges call it. Nothing here keeps a
//! copy; each part reads the file or series its writer owns:
//!
//! | part         | source                                                                   |
//! |--------------|--------------------------------------------------------------------------|
//! | accounts     | `claude_account_*`, claude-acct's textfile, in Prometheus                 |
//! | workers      | `~/.config/agentctl/agents/*.conf`, agentctl's `runs.jsonl`, each runner's `<INBOX>/activity.log` (agent-proof), the user timers, and `claude_code_cost_usage_USD_total` by `agentctl_runner` |
//! | tonight      | the workers and the user timers again, in the order they run until 07:00 (`tonight`) |
//! | registry     | each conf's KIND, ROLE, MODEL, PROMPT and EFFECT, its role's `roles/<role>.role`, the tail of agentctl-run's `calls.jsonl`, and session-outcomes.conf's Langfuse project for the call links |
//! | dispatch     | the tail of fleet-dispatch's `verdicts.jsonl` and `log.md`                |
//! | judges       | `judge-eval --all --json`, the one scorer (`~/.local/src/docs/judges.md`): the answer judge's tiles and each judge's per-rule table |
//!
//! The file parts are read fresh (judge-eval takes about a second); the Prometheus part (`prom`) is the slow one, so a
//! server can cache it apart and `apply` it to a fresh file read.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, NaiveTime, TimeZone};
use serde::{Deserialize, Serialize};

use crate::jobs::systemd::AGENTCTL_PREFIX;
use crate::jobs::{self, Job, State};
use crate::prom::{self, Series};

const DAY: i64 = 24 * 3600;
const WEEK: i64 = 7 * DAY;
/// Verdicts listed, newest first.
const RECENT_VERDICTS: usize = 30;
/// How much of the end of each append-only log is read. verdicts.jsonl grows about 400 bytes a
/// verdict, so 1 MiB is several weeks; a tail that still starts inside the week says so.
const VERDICT_TAIL: u64 = 1 << 20;
const LOG_TAIL: u64 = 256 << 10;
const ACTIVITY_TAIL: u64 = 16 << 10;
/// calls.jsonl holds up to 4 KB of raw reply a line; the busiest lane (dispatch-judge, about 100
/// calls a day) writes well under 1 MiB a day.
const CALLS_TAIL: u64 = 2 << 20;
/// Calls listed under a runner's row, newest first; the rest are `agentctl-run` lines on disk.
const RECENT_CALLS: usize = 5;
/// The Tonight order runs from now to the next of this local hour.
const MORNING_HOUR: u32 = 7;

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
    /// agentctl's role files, `<role>.role` each.
    pub roles: PathBuf,
    /// agentctl-run's one line per model call (`AGENTCTL_CALLS` overrides it, as agentctl-run's).
    pub calls: PathBuf,
    /// The judge scorer; `JUDGE_EVAL` overrides it (tests, a checkout).
    pub judge_eval: String,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let jobs = jobs::Paths::from_env();
        Paths {
            agents: home.join(".config/agentctl/agents"),
            roles: home.join(".config/agentctl/roles"),
            calls: std::env::var_os("AGENTCTL_CALLS")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| jobs.agentctl.join("calls.jsonl")),
            jobs,
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
    /// The workers in the order they run tonight, the order the human can pick over the default.
    pub tonight: Tonight,
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
    /// "running", "idle" or "off", one each; a failure in the last 24h is `failed_24h`, which
    /// can sit on any of them.
    pub state: String,
    /// How long a run usually takes: the 90th percentile of the week's finished runs, seconds.
    /// None under `USUAL_RUNS` of them.
    pub usual_s: Option<i64>,
    /// It is running, and has been for longer than `usual_s` and `OVERDUE_FLOOR_S`.
    pub overdue: bool,
    /// Its newest finished run in the week, else its newest activity line.
    pub last: Option<Outcome>,
    pub runs_24h: u32,
    pub failed_24h: u32,
    /// The newest activity.log line: the runner's own word on why.
    pub why: Option<Outcome>,
    pub next: Option<i64>,
    /// A call's CALLER: the runner (or program) that makes it.
    pub called_by: Option<String>,
    /// None until its cost series carries the runner label.
    pub cost_24h: Option<f64>,
    /// What the row opens to: how the runner is defined and what its calls did.
    pub registry: Registry,
    /// Its lane's counted score from judge-eval; None when judge-eval lists no such lane.
    pub score: Option<RunnerScore>,
}

/// The Workers state chips, in order; `Worker::shown` says what each keeps. agent-web's
/// `W_FILTERS` lists them too.
pub const WORKER_FILTERS: [&str; 5] = ["all", "failed", "running", "idle", "off"];
/// What the Workers table sorts by, biggest or newest first; a runner with no value sorts last.
pub const WORKER_SORTS: [&str; 4] = ["runs", "failed", "cost", "last"];
/// Fewer finished runs than this in the week say nothing about a usual length.
const USUAL_RUNS: usize = 3;
/// One run in ten passes `usual_s` by definition, so a run this short is never overdue: a
/// three-second runner would otherwise jump the table for a moment at every slow start.
const OVERDUE_FLOOR_S: i64 = 60;

impl Worker {
    /// Whether this runner is under one of `WORKER_FILTERS`.
    fn shown(&self, filter: &str) -> bool {
        match filter {
            "all" => true,
            "failed" => self.failed_24h > 0,
            state => self.state == state,
        }
    }

    /// Whether `q`, in lower case, is in its name, description or why.
    fn hits(&self, q: &str) -> bool {
        let why = self
            .why
            .as_ref()
            .map_or(String::new(), |o| format!("{} {}", o.word, o.text));
        [self.name.as_str(), &self.description, &why]
            .iter()
            .any(|t| t.to_lowercase().contains(q))
    }

    /// What `WORKER_SORTS`' key orders on; a time for "last", where a run in progress counts
    /// from its start.
    fn sort_value(&self, key: &str) -> Option<f64> {
        match key {
            "runs" => Some(f64::from(self.runs_24h)),
            "failed" => Some(f64::from(self.failed_24h)),
            "cost" => self.cost_24h,
            "last" => self
                .running_since
                .or(self.last.as_ref().and_then(|o| o.at))
                .map(|t| t as f64),
            _ => None,
        }
    }
}

/// Every lane in `ws`, sorted, for the lane filter.
pub fn lanes(ws: &[Worker]) -> Vec<String> {
    let set: std::collections::BTreeSet<&String> = ws
        .iter()
        .map(|w| &w.lane)
        .filter(|l| !l.is_empty())
        .collect();
    set.into_iter().cloned().collect()
}

/// A filtered and sorted view of the Workers table. The default keeps everything in hub-core's
/// exceptions-first order; `state` is one of `WORKER_FILTERS`, `sort` one of `WORKER_SORTS`.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkerView {
    pub q: String,
    pub lane: String,
    pub state: String,
    pub sort: String,
}

impl Default for WorkerView {
    fn default() -> Self {
        Self {
            q: String::new(),
            lane: String::new(),
            state: WORKER_FILTERS[0].to_string(),
            sort: String::new(),
        }
    }
}

impl WorkerView {
    fn matches(&self, w: &Worker) -> bool {
        let q = self.q.trim().to_lowercase();
        (self.lane.is_empty() || w.lane == self.lane) && (q.is_empty() || w.hits(&q))
    }

    /// Whether the search, lane and state all keep `w`.
    pub fn keeps(&self, w: &Worker) -> bool {
        self.matches(w) && w.shown(&self.state)
    }

    /// The rows it keeps, in its sort or else in `ws`'s own order.
    pub fn apply<'a>(&self, ws: &'a [Worker]) -> Vec<&'a Worker> {
        let mut out: Vec<&Worker> = ws.iter().filter(|w| self.keeps(w)).collect();
        out.sort_by(
            |a, b| match (a.sort_value(&self.sort), b.sort_value(&self.sort)) {
                (Some(x), Some(y)) => y.total_cmp(&x),
                (x, y) => y.is_some().cmp(&x.is_some()),
            },
        );
        out
    }

    /// How many runners each of `WORKER_FILTERS` would show under the search and lane.
    pub fn counts(&self, ws: &[Worker]) -> [(&'static str, usize); 5] {
        let kept: Vec<&Worker> = ws.iter().filter(|w| self.matches(w)).collect();
        WORKER_FILTERS.map(|f| (f, kept.iter().filter(|w| w.shown(f)).count()))
    }

    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    pub fn cycle_state(&mut self) {
        let at = WORKER_FILTERS.iter().position(|f| *f == self.state);
        let next = at.map_or(0, |i| (i + 1) % WORKER_FILTERS.len());
        self.state = WORKER_FILTERS[next].to_string();
    }

    pub fn cycle_sort(&mut self) {
        self.sort = next_of(&WORKER_SORTS, &self.sort);
    }

    pub fn cycle_lane(&mut self, lanes: &[String]) {
        let lanes: Vec<&str> = lanes.iter().map(String::as_str).collect();
        self.lane = next_of(&lanes, &self.lane);
    }
}

/// The value after `cur` in `list`, then back to blank, which keeps everything.
fn next_of(list: &[&str], cur: &str) -> String {
    let after = list.iter().position(|v| *v == cur).map_or(0, |i| i + 1);
    list.get(after).map_or(String::new(), |v| v.to_string())
}

/// A lane's score over a window as judge-eval counts and words it (its `score_7d`), never
/// model-written: the cell text and the title that says what it counted.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct RunnerScore {
    /// "93% untouched", "n<30" under the bar, "-" for a lane with no counted outcome.
    pub text: String,
    /// "7d, 41 of 44 right, 3 pending, triage-untouched".
    pub title: String,
}

/// The workers from now to the next 07:00 local: always-on runners first, then each timer in
/// time order, each call directly under the runner that makes it.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Tonight {
    /// The window's end, unix seconds; a start at or after it is the morning's, not tonight's.
    pub until: i64,
    pub slots: Vec<Slot>,
    /// User timers outside agentctl that fire in the window. Their rows are Infra's Jobs
    /// (dashboards.md rule 2), so here they are only this count.
    pub other_timers: u32,
}

/// One worker's place in the Tonight order. `at` and `under` both None is an always-on runner.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Slot {
    pub name: String,
    /// Its timer's next start.
    pub at: Option<i64>,
    /// The caller it is listed under, for a call.
    pub under: Option<String>,
}

/// One runner as its conf defines it (`~/.config/agentctl/README.md`, "What an agent is"), and
/// its model calls from agentctl-run's ledger.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Registry {
    /// call, oneshot or persistent.
    pub kind: String,
    /// The words `agentctl list --md` uses: its schedule, "called by its caller", ...
    pub trigger: String,
    pub role: String,
    /// The role's ROLE_DESC and its capabilities ("write no, task no, bash no, mcp none").
    pub role_desc: String,
    pub caps: String,
    /// MODEL as pinned; empty when the conf pins none.
    pub model: String,
    pub effect: String,
    /// PROMPT, the git-tracked prompt file; empty for a runner whose prompt is in its script.
    pub prompt: String,
    pub calls: Calls,
    /// judge-eval's block, for a judge lane.
    pub eval: Option<Eval>,
}

/// A runner's model calls in calls.jsonl: the last day's counts, and the newest few.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Calls {
    pub n_24h: u32,
    /// Exit not 0, or the json result said is_error.
    pub errors_24h: u32,
    /// Summed from each call's own json result, so it covers the short calls whose OTel export
    /// never lands (judges plan, phase 1). None with no call in the day.
    pub cost_24h: Option<f64>,
    /// Input, output and cache tokens together.
    pub tokens_24h: u64,
    pub p95_ms: Option<u64>,
    /// The prompt the newest call ran under (its git blob, short).
    pub prompt_sha: String,
    pub recent: Vec<Call>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Call {
    pub id: String,
    pub at: i64,
    pub ms: u64,
    pub ok: bool,
    pub model: String,
    pub cost: Option<f64>,
    pub tokens: u64,
    /// Its Langfuse session, when session-outcomes.conf names the project; else empty.
    pub link: String,
}

/// One judge lane from judge-eval, under its current prompt.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
pub struct Eval {
    pub prompt_sha: String,
    #[serde(default)]
    pub live: Vec<String>,
    pub total: Score,
    #[serde(default)]
    pub rules: Vec<Score>,
}

/// judge-eval's numbers for one rule (or the lane's total), as it gives them.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
pub struct Score {
    #[serde(default)]
    pub rule: String,
    #[serde(default)]
    pub verdicts: u32,
    #[serde(default)]
    pub errors: u32,
    #[serde(default)]
    pub scored: u32,
    pub precision: Option<f64>,
    pub false_defer_pct: Option<f64>,
    #[serde(default)]
    pub live: bool,
    pub bar: Option<Bar>,
}

/// How far a shadow rule is from going live: scored answers against the bar's count.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
pub struct Bar {
    pub labels: u32,
    pub need: u32,
    pub met: bool,
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
    /// The last 7 days under any prompt, what a reader asks first.
    pub week: JudgeWeek,
    /// Every verdict, newest first and under any prompt, as judge-eval lists them.
    pub verdicts: Vec<AskVerdict>,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct JudgeWeek {
    /// Asks the judge really answered, in percent of its verdicts.
    pub live_pct: Option<f64>,
    /// Asks it answered or would answer.
    pub coverage: Option<f64>,
    pub precision: Option<f64>,
}

/// The answer judge's filters on its verdict list, the first showing them all.
pub const ASK_FILTERS: [&str; 5] = ["all", "answered", "would answer", "passed", "wrong"];

#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct AskVerdict {
    pub id: String,
    pub project: String,
    pub question: String,
    /// The class of the question, on verdicts that record one.
    #[serde(rename = "type")]
    pub kind: String,
    pub rule: String,
    /// answered, would answer, passed or error.
    pub said: String,
    /// The option it answered or would answer.
    pub judge: String,
    pub reason: String,
    /// The quote from the ask behind the call.
    pub evidence: String,
    /// What the human did: their answer, kept, or pending.
    pub you: String,
    /// right, wrong, needless (a pass where the human took the recommendation), pending or -.
    pub score: String,
    pub at: Option<i64>,
}

impl AskVerdict {
    /// Whether this row is under one of `ASK_FILTERS`.
    pub fn shown(&self, filter: &str) -> bool {
        match filter {
            "all" => true,
            "wrong" => self.score == "wrong",
            said => self.said == said,
        }
    }
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
    let roles = read_roles(&paths.roles, &confs);
    let lf = langfuse_sessions(&paths.agents.join("session-outcomes.conf"));
    let calls = match tail(&paths.calls, CALLS_TAIL) {
        Ok((text, _)) => calls(&text, &lf, at),
        Err(e) => {
            errors.push(format!("calls: {e}"));
            HashMap::new()
        }
    };
    let (judge, evals, scores) = match run_judge_eval(&paths.judge_eval).and_then(|t| judges(&t)) {
        Ok(x) => x,
        Err(e) => {
            errors.push(format!("judges: {e}"));
            Default::default()
        }
    };
    let regs: HashMap<String, Registry> = confs
        .iter()
        .map(|c| (c.name.clone(), registry(c, &roles, &calls, &evals)))
        .collect();
    let mut workers = workers(confs, &runs, &activity, &timers, at);
    for w in &mut workers {
        w.registry = regs.get(&w.name).cloned().unwrap_or_default();
        w.score = scores.get(&w.name).cloned();
    }
    let tonight = tonight(&workers, &timers, at);

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
    Fleet {
        at,
        errors,
        workers,
        tonight,
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
    pub kind: String,
    pub role: String,
    pub model: String,
    pub prompt: String,
    pub effect: String,
    /// A call's CALLER; empty on a runner.
    pub caller: String,
}

/// A conf's (or a role's) `KEY=value` lines as agentctl sources them, for the keys asked for.
/// Quotes are stripped and `$HOME` expanded; nothing fancier is.
fn kv(text: &str, keys: &[&str], home: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for l in text.lines() {
        let l = l.trim();
        let l = l.strip_prefix("export ").unwrap_or(l);
        let Some((k, v)) = l.split_once('=') else {
            continue;
        };
        if !keys.contains(&k) {
            continue;
        }
        let v = v.trim();
        let v = v
            .strip_prefix('"')
            .and_then(|x| x.strip_suffix('"'))
            .or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
            .unwrap_or(v);
        out.insert(
            k.to_string(),
            v.replace("${HOME}", home).replace("$HOME", home),
        );
    }
    out
}

/// One runner's conf, for the keys the tab shows.
pub fn parse_conf(name: &str, text: &str, home: &str, state: &Path) -> Conf {
    let kv = kv(
        text,
        &[
            "LANE",
            "DESCRIPTION",
            "SCHEDULE",
            "ENABLED",
            "INBOX",
            "KIND",
            "ROLE",
            "MODEL",
            "PROMPT",
            "EFFECT",
            "CALLER",
        ],
        home,
    );
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
        kind: get("KIND"),
        role: get("ROLE"),
        model: get("MODEL"),
        prompt: get("PROMPT"),
        effect: get("EFFECT"),
        caller: get("CALLER"),
    }
}

/// Each role the confs name: (ROLE_DESC, its capabilities in a few words). A role with no file
/// says so in place of its capabilities.
fn read_roles(dir: &Path, confs: &[Conf]) -> HashMap<String, (String, String)> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut out = HashMap::new();
    for c in confs.iter().filter(|c| !c.role.is_empty()) {
        if out.contains_key(&c.role) {
            continue;
        }
        let r = match std::fs::read_to_string(dir.join(format!("{}.role", c.role))) {
            Ok(t) => parse_role(&t, &home),
            Err(_) => (String::new(), "no role file".into()),
        };
        out.insert(c.role.clone(), r);
    }
    out
}

/// A role file's ROLE_DESC and its ROLE_WRITE, ROLE_TASK, ROLE_BASH and ROLE_MCP, which are
/// what the role takes away (`--disallowedTools`).
pub fn parse_role(text: &str, home: &str) -> (String, String) {
    let kv = kv(
        text,
        &[
            "ROLE_DESC",
            "ROLE_WRITE",
            "ROLE_TASK",
            "ROLE_BASH",
            "ROLE_MCP",
        ],
        home,
    );
    let get = |k: &str| kv.get(k).map_or("-", |v| v.as_str());
    let caps = format!(
        "write {}, task {}, bash {}, mcp {}",
        get("ROLE_WRITE"),
        get("ROLE_TASK"),
        get("ROLE_BASH"),
        get("ROLE_MCP")
    );
    (kv.get("ROLE_DESC").cloned().unwrap_or_default(), caps)
}

/// `agentctl list --md`'s trigger words for a conf.
fn trigger(c: &Conf) -> String {
    let t = match c.kind.as_str() {
        "call" => "called by its caller".to_string(),
        "persistent" => "always on".to_string(),
        _ if !c.schedule.is_empty() => c.schedule.clone(),
        _ => "started by another runner".to_string(),
    };
    if c.enabled {
        t
    } else {
        format!("{t} (disabled)")
    }
}

fn registry(
    c: &Conf,
    roles: &HashMap<String, (String, String)>,
    calls: &HashMap<String, Calls>,
    evals: &HashMap<String, Eval>,
) -> Registry {
    let (role_desc, caps) = roles.get(&c.role).cloned().unwrap_or_default();
    Registry {
        kind: c.kind.clone(),
        trigger: trigger(c),
        role: c.role.clone(),
        role_desc,
        caps,
        model: c.model.clone(),
        effect: c.effect.clone(),
        prompt: c.prompt.clone(),
        calls: calls.get(&c.name).cloned().unwrap_or_default(),
        eval: evals.get(&c.name).cloned(),
    }
}

/// `<SO_LF_URL>/project/<SO_LF_PROJECT>/sessions/` from session-outcomes.conf, as agent-ask's
/// trace builds it; empty when either is unset.
fn langfuse_sessions(conf: &Path) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let text = std::fs::read_to_string(conf).unwrap_or_default();
    let kv = kv(&text, &["SO_LF_URL", "SO_LF_PROJECT"], &home);
    match (kv.get("SO_LF_URL"), kv.get("SO_LF_PROJECT")) {
        (Some(u), Some(p)) if !u.is_empty() && !p.is_empty() => {
            format!("{}/project/{p}/sessions/", u.trim_end_matches('/'))
        }
        _ => String::new(),
    }
}

/// Each runner's calls from calls.jsonl: the day before `at` counted, and the newest
/// `RECENT_CALLS` in the tail listed. `lf` is the Langfuse sessions URL a call's session_id
/// joins; empty leaves the links empty.
pub fn calls(text: &str, lf: &str, at: i64) -> HashMap<String, Calls> {
    let mut by: HashMap<String, (Calls, Vec<u64>)> = HashMap::new();
    let n = |v: &serde_json::Value, k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    for l in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(l) else {
            continue;
        };
        let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
        let agent = s("agent");
        let Some(t) = ts(&s("at")) else { continue };
        if agent.is_empty() {
            continue;
        }
        let ok = n(&v, "exit") == 0 && v.get("is_error").and_then(|x| x.as_bool()) != Some(true);
        let tokens = n(&v, "gen_ai.usage.input_tokens")
            + n(&v, "gen_ai.usage.output_tokens")
            + n(&v, "cache_read_tokens")
            + n(&v, "cache_write_tokens");
        let cost = v.get("cost_usd").and_then(|x| x.as_f64());
        let ms = n(&v, "duration_ms");
        let sid = s("session_id");
        let model = Some(s("gen_ai.response.model"))
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| s("gen_ai.request.model"));
        let (c, durs) = by.entry(agent).or_default();
        if t >= at - DAY {
            c.n_24h += 1;
            c.errors_24h += u32::from(!ok);
            if let Some(x) = cost {
                *c.cost_24h.get_or_insert(0.0) += x;
            }
            c.tokens_24h += tokens;
            durs.push(ms);
        }
        // The file is in write order, so the last line seen is the newest.
        c.prompt_sha = s("prompt_sha").chars().take(7).collect();
        c.recent.push(Call {
            id: s("id"),
            at: t,
            ms,
            ok,
            model,
            cost,
            tokens,
            link: if lf.is_empty() || sid.is_empty() {
                String::new()
            } else {
                format!("{lf}{sid}")
            },
        });
        if c.recent.len() > RECENT_CALLS {
            c.recent.remove(0);
        }
    }
    by.into_iter()
        .map(|(k, (mut c, mut durs))| {
            c.recent.reverse();
            durs.sort_unstable();
            // As judge-eval's p95.
            c.p95_ms = nearest_rank(&durs, 95);
            (k, c)
        })
        .collect()
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
/// gets no row. Exceptions first: a failure in 24h, then a run past its usual length; then
/// enabled runners, then by name.
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
                    .get(&format!("{AGENTCTL_PREFIX}{}.service", c.name))
                    .copied()
                    .filter(|&n| n > 0),
                why: activity.get(&c.name).cloned(),
                called_by: Some(c.caller).filter(|v| !v.is_empty()),
                name: c.name,
                lane: c.lane,
                description: c.description,
                schedule: c.schedule,
                enabled: c.enabled,
                ..Default::default()
            };
            let mut newest: Option<&Job> = None;
            let mut lengths: Vec<i64> = vec![];
            for j in mine {
                if j.state == State::Running {
                    w.running_since = j.started.or(Some(at));
                    continue;
                }
                if j.finished.is_some_and(|f| f >= at - DAY) {
                    w.runs_24h += 1;
                    w.failed_24h += u32::from(j.ok == Some(false));
                }
                lengths.extend(j.secs);
                if newest.is_none_or(|n| j.finished > n.finished) {
                    newest = Some(j);
                }
            }
            w.usual_s = usual(lengths);
            w.overdue = w
                .running_since
                .is_some_and(|t| w.usual_s.is_some_and(|u| at - t > u.max(OVERDUE_FLOOR_S)));
            w.state = match (w.running_since, w.enabled) {
                (Some(_), _) => "running",
                (None, true) => "idle",
                (None, false) => "off",
            }
            .into();
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
    let rank = |w: &Worker| match (w.failed_24h > 0, w.overdue) {
        (true, _) => 0,
        (false, true) => 1,
        (false, false) => 2,
    };
    out.sort_by(|a, b| {
        rank(a)
            .cmp(&rank(b))
            .then(b.enabled.cmp(&a.enabled))
            .then_with(|| a.name.cmp(&b.name))
    });
    out
}

/// The 90th percentile of `lengths`, nearest rank; None under `USUAL_RUNS` of them.
fn usual(mut lengths: Vec<i64>) -> Option<i64> {
    if lengths.len() < USUAL_RUNS {
        return None;
    }
    lengths.sort_unstable();
    nearest_rank(&lengths, 90)
}

/// The nearest-rank `pct`th percentile of `sorted`, None when it is empty.
fn nearest_rank<T: Copy>(sorted: &[T], pct: usize) -> Option<T> {
    let rank = (sorted.len() * pct).div_ceil(100);
    sorted.get(rank.saturating_sub(1)).copied()
}

/// The workers (their registry read) in the order they run from `at` to the next 07:00 local:
/// running always-on runners first, then every timer in the window by its next start, and each
/// call straight after the runner its CALLER names. A call whose caller is not a runner in the
/// window (agent-ask, a by-hand tool) has no slot. `timers` is the same `timer_starts` read the
/// workers took their `next` from; the ones outside agentctl are only counted.
pub fn tonight(ws: &[Worker], timers: &HashMap<String, i64>, at: i64) -> Tonight {
    let until = morning(at);
    let due = |n: i64| n > at && n < until;
    let always = ws.iter().filter(|w| {
        w.registry.kind == "persistent" && w.running_since.is_some() && w.next.is_none()
    });
    let mut timed: Vec<&Worker> = ws.iter().filter(|w| w.next.is_some_and(due)).collect();
    timed.sort_by(|a, b| a.next.cmp(&b.next).then_with(|| a.name.cmp(&b.name)));
    let mut calls: Vec<&Worker> = ws.iter().filter(|w| w.called_by.is_some()).collect();
    calls.sort_by(|a, b| a.name.cmp(&b.name));
    let mut slots = vec![];
    for w in always.chain(timed) {
        slots.push(Slot {
            name: w.name.clone(),
            at: w.next,
            under: None,
        });
        for c in calls
            .iter()
            .filter(|c| c.called_by.as_deref() == Some(&w.name))
        {
            slots.push(Slot {
                name: c.name.clone(),
                at: None,
                under: Some(w.name.clone()),
            });
        }
    }
    let other_timers = timers
        .iter()
        .filter(|(unit, &n)| !unit.starts_with(AGENTCTL_PREFIX) && due(n))
        .count() as u32;
    Tonight {
        until,
        slots,
        other_timers,
    }
}

/// The first `MORNING_HOUR`:00 local after `at`.
fn morning(at: i64) -> i64 {
    let (Some(now), Some(hour)) = (
        Local.timestamp_opt(at, 0).single(),
        NaiveTime::from_hms_opt(MORNING_HOUR, 0, 0),
    ) else {
        return at + DAY;
    };
    let day = now.date_naive();
    let day = if now.time() < hour {
        day
    } else {
        day.succ_opt().unwrap_or(day)
    };
    Local
        .from_local_datetime(&day.and_time(hour))
        .earliest()
        .map_or(at + DAY, |d| d.timestamp())
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
        .args(["--all", "--json"])
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{cmd} exited {}", out.status));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The answer judge's tiles, each lane's per-rule table and each lane's score, by agent name.
pub type Judges = (Judge, HashMap<String, Eval>, HashMap<String, RunnerScore>);

/// From one `judge-eval --all --json`, under each judge's current prompt: the answer judge's
/// tiles and each lane's per-rule table; under any prompt, each lane's 7d score. No count is made
/// here: judge-eval is the one scorer.
pub fn judges(json: &str) -> Result<Judges, String> {
    #[derive(Deserialize)]
    struct All {
        agents: Vec<Agent>,
    }
    #[derive(Deserialize)]
    struct Agent {
        agent: String,
        prompt_sha: String,
        total: Total,
        #[serde(default)]
        week: JudgeWeek,
        #[serde(default)]
        verdicts: Vec<AskVerdict>,
        #[serde(default)]
        live: Vec<String>,
        #[serde(default)]
        rules: Vec<Score>,
        #[serde(default)]
        score_7d: Option<RunnerScore>,
    }
    #[derive(Deserialize, Default)]
    #[serde(default)]
    struct Total {
        // precision is read through `score`: a field named here would hide it from the flatten.
        #[serde(flatten)]
        score: Score,
        tp: u32,
        fp: u32,
        #[serde(rename = "fn")]
        false_defer: u32,
        deferred: u32,
        pending: u32,
        unscorable: u32,
        kappa: Option<f64>,
    }
    let all: All = serde_json::from_str(json).map_err(|e| format!("judge-eval: {e}"))?;
    let mut evals = HashMap::new();
    let mut scores = HashMap::new();
    let mut ask = None;
    for mut a in all.agents {
        if let Some(sc) = a.score_7d.take() {
            scores.insert(a.agent.clone(), sc);
        }
        evals.insert(
            a.agent.clone(),
            Eval {
                prompt_sha: a.prompt_sha.chars().take(7).collect(),
                live: a.live.clone(),
                total: a.total.score.clone(),
                rules: a.rules.clone(),
            },
        );
        if a.agent == "ask-judge" {
            ask = Some(a);
        }
    }
    let a = ask.ok_or("judge-eval: no ask-judge block")?;
    let t = a.total;
    let judge = Judge {
        agree: t.tp,
        disagree: t.fp,
        deferred: t.deferred,
        false_defer: t.false_defer,
        pending: t.pending,
        unscored: t.unscorable,
        precision: t.score.precision,
        kappa: t.kappa,
        prompt: a.prompt_sha.chars().take(7).collect(),
        week: a.week,
        verdicts: a.verdicts,
    };
    Ok((judge, evals, scores))
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
    use crate::jobs::Source;

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
            ["dream", "sentinel", "idle", "off"],
            "no row for a retired runner; a failure in 24h comes first"
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

        let s = &w[1];
        assert_eq!((s.runs_24h, s.failed_24h), (1, 1), "STALLED is a failure");
        assert_eq!(s.running_since, Some(T - 5));
        assert_eq!(s.last.as_ref().unwrap().word, "STALLED");

        let idle = &w[2];
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
           "week":{"live_pct":25.0,"coverage":40.0,"precision":90.0},
           "verdicts":[{"id":"Ab1","project":"p","question":"q?","judge":"yes","reason":"because",
             "you":"no","rule":"r","type":"ship_deploy","said":"would answer","score":"wrong","at":1700000000},
             {"id":"Ab2","said":"passed","score":"needless","at":null}]}]}"#;
        let (j, evals, _) = judges(json).unwrap();
        assert_eq!(evals["ask-judge"].prompt_sha, "60c840b");
        assert_eq!(
            (
                j.agree,
                j.disagree,
                j.deferred,
                j.false_defer,
                j.pending,
                j.unscored
            ),
            (2, 1, 4, 3, 1, 2)
        );
        assert_eq!((j.precision, j.kappa), (Some(66.7), Some(0.12)));
        assert_eq!(j.prompt, "60c840b");
        assert_eq!(j.week.live_pct, Some(25.0));
        let v = &j.verdicts[0];
        assert_eq!(
            (v.kind.as_str(), v.you.as_str(), v.at),
            ("ship_deploy", "no", Some(1_700_000_000))
        );
        for (filter, want) in [
            ("all", 2),
            ("would answer", 1),
            ("passed", 1),
            ("answered", 0),
            ("wrong", 1),
        ] {
            assert_eq!(
                j.verdicts.iter().filter(|v| v.shown(filter)).count(),
                want,
                "{filter}"
            );
        }
    }

    #[test]
    fn each_lanes_score_cell_and_title_are_judge_evals_score_7d_as_written() {
        let json = r#"{"bar":{"labels":30,"precision":90},"agents":[
          {"agent":"ask-judge","prompt_sha":"a","score":"ask-answers",
           "total":{"verdicts":1,"tp":0,"fp":0,"fn":0,"tn":0},
           "score_7d":{"window":"7d","right":7,"n":9,"pending":4,"value":null,"text":"n<30",
             "title":"7d, 7 of 9 right, 4 pending, ask-answers; a percent at 30 rows"}},
          {"agent":"inbox-triage","prompt_sha":"b","score":"triage-untouched",
           "total":{"verdicts":44,"tp":41,"fp":3},
           "score_7d":{"window":"7d","right":41,"n":44,"pending":3,"value":93.2,"text":"93% untouched",
             "title":"7d, 41 of 44 right, 3 pending, triage-untouched"}},
          {"agent":"ask-sweep","prompt_sha":"","score":"unrecorded","total":{},
           "score_7d":{"window":"7d","right":0,"n":0,"pending":0,"value":null,"text":"-",
             "title":"unrecorded: no counted outcome"}},
          {"agent":"old-lane","prompt_sha":"c","total":{}}]}"#;
        let (_, _, scores) = judges(json).unwrap();
        let cell = |a: &str| {
            let s = &scores[a];
            (s.text.as_str(), s.title.as_str())
        };
        assert_eq!(
            cell("inbox-triage"),
            (
                "93% untouched",
                "7d, 41 of 44 right, 3 pending, triage-untouched"
            )
        );
        assert_eq!(
            cell("ask-judge"),
            (
                "n<30",
                "7d, 7 of 9 right, 4 pending, ask-answers; a percent at 30 rows"
            )
        );
        assert_eq!(cell("ask-sweep"), ("-", "unrecorded: no counted outcome"));
        // A judge-eval with no score_7d for a lane gives it no score: the surfaces draw "-".
        assert!(!scores.contains_key("old-lane"));
    }

    #[test]
    fn a_judge_eval_answer_with_no_ask_judge_block_is_an_error_not_zeros() {
        assert!(judges(r#"{"agents":[]}"#).is_err());
        assert!(judges("not json").is_err());
    }

    #[test]
    fn each_judge_gets_its_per_rule_table_from_the_one_judge_eval_read() {
        let json = r#"{"agents":[
          {"agent":"ask-judge","prompt_sha":"aaaaaaaaa","total":{"verdicts":40,"tp":6,"fp":0,"fn":0,"tn":0},
           "live":["ship_deploy"],
           "rules":[{"rule":"ship_deploy","verdicts":9,"errors":0,"scored":6,"precision":100.0,
                     "false_defer_pct":null,"live":true,"bar":{"labels":6,"need":30,"met":false}},
                    {"rule":"taste","verdicts":31,"scored":28,"precision":null,"false_defer_pct":18.0,
                     "live":false}],
           "misses":[]},
          {"agent":"dispatch-judge","prompt_sha":"bbbbbbbbb","total":{"verdicts":16,"errors":2,"tp":0,"fp":0,"fn":0,"tn":0}}]}"#;
        let (_, evals, _) = judges(json).unwrap();
        let a = &evals["ask-judge"];
        assert_eq!(a.live, vec!["ship_deploy".to_string()]);
        assert_eq!(a.total.verdicts, 40);
        assert_eq!(
            (
                a.rules[0].rule.as_str(),
                a.rules[0].scored,
                a.rules[0].precision,
                a.rules[0].live
            ),
            ("ship_deploy", 6, Some(100.0), true)
        );
        assert_eq!(
            a.rules[0].bar,
            Some(Bar {
                labels: 6,
                need: 30,
                met: false
            })
        );
        assert_eq!(
            (a.rules[1].false_defer_pct, a.rules[1].bar.is_none()),
            (Some(18.0), true)
        );
        let d = &evals["dispatch-judge"];
        assert_eq!(
            (d.prompt_sha.as_str(), d.total.errors, d.rules.len()),
            ("bbbbbbb", 2, 0)
        );
    }

    #[test]
    fn a_conf_names_its_registry_and_its_role_names_what_it_takes_away() {
        let c = parse_conf(
            "ask-judge",
            "KIND=call\nROLE=observe\nMODEL=sonnet-5-5\nPROMPT=\"$HOME/p/policy.md\"\nEFFECT='writes a verdict'\n",
            "/home/k",
            Path::new("/st"),
        );
        assert_eq!(
            (
                c.kind.as_str(),
                c.role.as_str(),
                c.model.as_str(),
                c.prompt.as_str(),
                c.effect.as_str()
            ),
            (
                "call",
                "observe",
                "sonnet-5-5",
                "/home/k/p/policy.md",
                "writes a verdict"
            )
        );
        assert_eq!(trigger(&c), "called by its caller");
        let sched = Conf {
            schedule: "daily".into(),
            enabled: false,
            ..c.clone()
        };
        assert_eq!(
            trigger(&Conf {
                kind: "oneshot".into(),
                ..sched.clone()
            }),
            "daily (disabled)"
        );
        assert_eq!(
            trigger(&Conf {
                kind: "oneshot".into(),
                schedule: String::new(),
                enabled: true,
                ..c
            }),
            "started by another runner"
        );
        let (desc, caps) = parse_role(
            "ROLE_DESC=\"read only\"\nROLE_WRITE=no\nROLE_TASK=no\nROLE_BASH=yes\nROLE_MCP=none\n",
            "/home/k",
        );
        assert_eq!(desc, "read only");
        assert_eq!(caps, "write no, task no, bash yes, mcp none");
    }

    #[test]
    fn calls_count_the_day_and_list_the_newest_with_a_langfuse_link() {
        let line = |at: &str, exit: u8, err: bool, ms: u64, sid: &str| {
            format!(
                r#"{{"id":"c{ms}","agent":"ask-judge","at":"{at}","duration_ms":{ms},"exit":{exit},"is_error":{err},"gen_ai.request.model":"sonnet","gen_ai.response.model":"claude-sonnet-5-5","prompt_sha":"3fa1c2deadbeef","session_id":"{sid}","gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":5,"cache_read_tokens":100,"cache_write_tokens":1,"cost_usd":0.01}}"#
            )
        };
        // T is 2025-11-03T20:00:00Z; the first call is two days old.
        let text = [
            line("2025-11-01T12:00:00Z", 0, false, 100, "s0"),
            line("2025-11-03T10:00:00Z", 0, false, 200, "s1"),
            line("2025-11-03T11:00:00Z", 1, false, 300, ""),
            line("2025-11-03T12:00:00Z", 0, true, 400, "s3"),
            "not json".into(),
            line("2025-11-03T13:00:00Z", 0, false, 500, "s4"),
        ]
        .join("\n");
        let c = &calls(&text, "https://lf/project/P/sessions/", T)["ask-judge"];
        assert_eq!((c.n_24h, c.errors_24h, c.tokens_24h), (4, 2, 4 * 116));
        assert!((c.cost_24h.unwrap() - 0.04).abs() < 1e-9);
        assert_eq!(c.p95_ms, Some(500));
        assert_eq!(c.prompt_sha, "3fa1c2d");
        assert_eq!(c.recent.len(), RECENT_CALLS);
        assert_eq!(c.recent[0].id, "c500", "newest first");
        assert_eq!(c.recent[0].link, "https://lf/project/P/sessions/s4");
        assert_eq!(c.recent[0].model, "claude-sonnet-5-5");
        assert_eq!(
            (c.recent[1].ok, c.recent[2].ok, c.recent[2].link.as_str()),
            (false, false, "")
        );
        assert!(calls(&text, "", T)["ask-judge"].recent[0].link.is_empty());
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

    /// 2026-11-05 at `h:m` local, unix seconds; `d` days on.
    fn local(d: u32, h: u32, m: u32) -> i64 {
        Local
            .with_ymd_and_hms(2026, 11, 5 + d, h, m, 0)
            .unwrap()
            .timestamp()
    }

    fn timed(name: &str, next: i64) -> Worker {
        Worker {
            name: name.into(),
            next: Some(next),
            ..Default::default()
        }
    }

    fn run(name: &str, start: i64, secs: i64, ok: bool) -> Job {
        let mut j = Job::new(Source::Agentctl, name, State::Done);
        j.ok = Some(ok);
        j.started = Some(start);
        j.finished = Some(start + secs);
        j.secs = Some(secs);
        j
    }

    fn running(name: &str, start: i64) -> Job {
        let mut j = Job::new(Source::Agentctl, name, State::Running);
        j.started = Some(start);
        j
    }

    fn read(confs: Vec<Conf>, runs: &[Job], at: i64) -> Vec<Worker> {
        workers(confs, runs, &HashMap::new(), &HashMap::new(), at)
    }

    #[test]
    fn exceptions_come_first_failed_then_past_their_usual_length() {
        let at = 1_000_000;
        let usual = |n: &'static str| (1..=4).map(move |i| run(n, at - i * 1000, 100, true));
        let mut runs: Vec<Job> = usual("late").chain(usual("on-time")).collect();
        runs.push(running("late", at - 500));
        runs.push(running("on-time", at - 90));
        runs.push(run("bad", at - 2000, 100, false));
        let ws = read(
            ["a-quiet", "bad", "late", "on-time", "z-quiet"]
                .map(|n| conf(n, n != "a-quiet"))
                .to_vec(),
            &runs,
            at,
        );
        let order: Vec<&str> = ws.iter().map(|w| w.name.as_str()).collect();
        assert_eq!(order, ["bad", "late", "on-time", "z-quiet", "a-quiet"]);
        assert!(ws[1].overdue, "500s against a usual 100s");
        assert!(!ws[2].overdue, "90s against a usual 100s is on time");
        assert_eq!(ws[1].usual_s, Some(100));
        assert_eq!(
            ws.iter().map(|w| w.state.as_str()).collect::<Vec<_>>(),
            ["idle", "running", "running", "idle", "off"]
        );
    }

    #[test]
    fn a_usual_length_needs_three_runs_and_short_ones_are_never_overdue() {
        let at = 1_000_000;
        // Two runs say nothing, however long this one has gone on.
        let mut runs = vec![
            run("few", at - 9000, 10, true),
            run("few", at - 8000, 10, true),
        ];
        runs.push(running("few", at - 5000));
        // Twice its usual 5s, and still under the floor.
        runs.extend((1..=4).map(|i| run("quick", at - i * 1000, 5, true)));
        runs.push(running("quick", at - 10));
        let ws = read(vec![conf("few", true), conf("quick", true)], &runs, at);
        assert_eq!(ws[0].usual_s, None);
        assert!(!ws[0].overdue);
        assert_eq!(ws[1].usual_s, Some(5));
        assert!(!ws[1].overdue);
    }

    #[test]
    fn the_usual_length_is_the_ninetieth_percentile() {
        assert_eq!(usual(vec![1, 2]), None);
        assert_eq!(usual(vec![3, 1, 2]), Some(3));
        assert_eq!(usual((1..=10).collect()), Some(9));
        assert_eq!(usual((1..=20).collect()), Some(18));
    }

    fn row(name: &str, lane: &str, state: &str) -> Worker {
        Worker {
            name: name.into(),
            lane: lane.into(),
            state: state.into(),
            enabled: state != "off",
            ..Default::default()
        }
    }

    fn table() -> Vec<Worker> {
        let at = |t| Outcome {
            at: Some(t),
            ..Default::default()
        };
        vec![
            Worker {
                failed_24h: 2,
                runs_24h: 3,
                cost_24h: Some(1.5),
                last: Some(at(100)),
                why: Some(Outcome {
                    word: "FAILED".into(),
                    text: "sweep hit a rate limit".into(),
                    ..Default::default()
                }),
                ..row("triage", "maintain", "idle")
            },
            Worker {
                failed_24h: 1,
                runs_24h: 9,
                running_since: Some(300),
                description: "Reads the Inbox".into(),
                ..row("dispatch", "deliver", "running")
            },
            Worker {
                runs_24h: 1,
                cost_24h: Some(4.0),
                last: Some(at(200)),
                ..row("dream", "deliver", "idle")
            },
            row("retired", "", "off"),
        ]
    }

    fn shown(v: &WorkerView, ws: &[Worker]) -> Vec<String> {
        v.apply(ws).iter().map(|w| w.name.clone()).collect()
    }

    #[test]
    fn the_filters_keep_by_state_lane_and_search() {
        let ws = table();
        let view = |q: &str, lane: &str, state: &str| WorkerView {
            q: q.into(),
            lane: lane.into(),
            state: state.into(),
            ..Default::default()
        };
        assert_eq!(
            shown(&view("", "", "all"), &ws).len(),
            4,
            "all keeps every runner"
        );
        assert_eq!(shown(&view("", "", "failed"), &ws), ["triage", "dispatch"]);
        assert_eq!(shown(&view("", "", "running"), &ws), ["dispatch"]);
        assert_eq!(shown(&view("", "", "idle"), &ws), ["triage", "dream"]);
        assert_eq!(shown(&view("", "", "off"), &ws), ["retired"]);
        assert_eq!(
            shown(&view("", "deliver", "all"), &ws),
            ["dispatch", "dream"]
        );
        assert_eq!(shown(&view("", "deliver", "failed"), &ws), ["dispatch"]);
        assert_eq!(shown(&view("DREAM", "", "all"), &ws), ["dream"], "the name");
        assert_eq!(
            shown(&view("inbox", "", "all"), &ws),
            ["dispatch"],
            "the description"
        );
        assert_eq!(
            shown(&view("rate limit", "", "all"), &ws),
            ["triage"],
            "the why"
        );
        assert!(shown(&view("nothing like it", "", "all"), &ws).is_empty());
    }

    #[test]
    fn each_chips_count_follows_the_search_and_lane_but_not_the_chip() {
        let ws = table();
        let mut v = WorkerView {
            state: "off".into(),
            ..Default::default()
        };
        assert_eq!(
            v.counts(&ws),
            [
                ("all", 4),
                ("failed", 2),
                ("running", 1),
                ("idle", 2),
                ("off", 1)
            ]
        );
        v.lane = "deliver".into();
        assert_eq!(
            v.counts(&ws),
            [
                ("all", 2),
                ("failed", 1),
                ("running", 1),
                ("idle", 1),
                ("off", 0)
            ]
        );
    }

    #[test]
    fn a_sort_puts_the_biggest_first_and_a_runner_with_no_value_last() {
        let ws = table();
        let by = |k: &str| {
            shown(
                &WorkerView {
                    sort: k.into(),
                    ..Default::default()
                },
                &ws,
            )
        };
        assert_eq!(by("runs"), ["dispatch", "triage", "dream", "retired"]);
        assert_eq!(by("failed"), ["triage", "dispatch", "dream", "retired"]);
        assert_eq!(by("cost"), ["dream", "triage", "dispatch", "retired"]);
        assert_eq!(
            by("last"),
            ["dispatch", "dream", "triage", "retired"],
            "a run in progress is newest"
        );
        assert_eq!(by("nonsense"), ["triage", "dispatch", "dream", "retired"]);
    }

    #[test]
    fn each_filter_cycles_through_its_list_and_back_to_the_start() {
        let mut v = WorkerView::default();
        for f in WORKER_FILTERS
            .iter()
            .cycle()
            .skip(1)
            .take(WORKER_FILTERS.len())
        {
            v.cycle_state();
            assert_eq!(v.state, *f);
        }
        assert!(v.is_empty());
        for k in WORKER_SORTS {
            v.cycle_sort();
            assert_eq!(v.sort, k);
        }
        v.cycle_sort();
        assert!(v.is_empty());
        let ls = lanes(&table());
        assert_eq!(ls, ["deliver", "maintain"]);
        v.cycle_lane(&ls);
        v.cycle_lane(&ls);
        assert_eq!(v.lane, "maintain");
        v.cycle_lane(&ls);
        assert_eq!(v.lane, "");
    }

    fn names(t: &Tonight) -> Vec<(&str, Option<&str>)> {
        t.slots
            .iter()
            .map(|s| (s.name.as_str(), s.under.as_deref()))
            .collect()
    }

    #[test]
    fn a_conf_reads_its_caller() {
        let c = parse_conf(
            "ask-sweep",
            "KIND=call\nCALLER=dream\n",
            "/h",
            Path::new("/st"),
        );
        assert_eq!(c.caller, "dream");
        let w = workers(
            vec![c, conf("dream", true)],
            &[],
            &HashMap::new(),
            &HashMap::new(),
            T,
        );
        let by = |n: &str| w.iter().find(|w| w.name == n).unwrap().called_by.clone();
        assert_eq!(by("ask-sweep").as_deref(), Some("dream"));
        assert_eq!(by("dream"), None, "a runner has no caller");
    }

    #[test]
    fn tonight_runs_from_now_to_the_next_seven_in_time_order() {
        let now = local(0, 20, 25);
        let ws = [
            timed("dream", local(1, 3, 4)),
            timed("nightly-sync", local(0, 23, 3)),
            timed("briefing", local(1, 6, 45)),
            timed("theme-day", local(1, 7, 0)),
        ];
        let t = tonight(&ws, &HashMap::new(), now);
        assert_eq!(t.until, local(1, 7, 0));
        assert_eq!(
            names(&t),
            [("nightly-sync", None), ("dream", None), ("briefing", None)]
        );
        assert_eq!(t.slots[0].at, Some(local(0, 23, 3)));
        // Before 07:00 the window ends the same morning.
        let early = tonight(&ws, &HashMap::new(), local(1, 4, 0));
        assert_eq!(early.until, local(1, 7, 0));
        assert_eq!(
            names(&early),
            [("briefing", None)],
            "a start already gone is not tonight's"
        );
    }

    #[test]
    fn a_timer_after_seven_is_not_tonight() {
        // The negative control: the same rows with only the times moved past 07:00.
        let now = local(0, 20, 25);
        let ws = [
            timed("perf-round", local(2, 8, 0)),
            timed("lab-sync", local(1, 7, 1)),
        ];
        let timers = HashMap::from([
            ("theme-day.service".to_string(), local(1, 7, 0)),
            ("storage-scan.service".to_string(), local(1, 15, 8)),
        ]);
        let t = tonight(&ws, &timers, now);
        assert!(t.slots.is_empty(), "{:?}", t.slots);
        assert_eq!(t.other_timers, 0);
    }

    #[test]
    fn a_call_sits_under_its_caller() {
        let now = local(0, 20, 25);
        let call = |name: &str, caller: &str| Worker {
            name: name.into(),
            called_by: Some(caller.into()),
            ..Default::default()
        };
        let ws = [
            call("ask-sweep", "dream"),
            call("ask-judge", "agent-ask"),
            timed("token-usage", local(1, 3, 42)),
            timed("dream", local(1, 3, 4)),
            timed("fleet-dispatch", local(0, 20, 27)),
            call("dispatch-judge", "fleet-dispatch"),
        ];
        let t = tonight(&ws, &HashMap::new(), now);
        assert_eq!(
            names(&t),
            [
                ("fleet-dispatch", None),
                ("dispatch-judge", Some("fleet-dispatch")),
                ("dream", None),
                ("ask-sweep", Some("dream")),
                ("token-usage", None),
            ],
            "a call whose caller is no runner tonight (agent-ask) has no slot"
        );
        assert_eq!(t.slots[1].at, None);
    }

    #[test]
    fn always_on_runners_come_first() {
        let now = local(0, 20, 25);
        let persistent = |name: &str, running: bool| Worker {
            name: name.into(),
            running_since: running.then_some(now - 3600),
            registry: Registry {
                kind: "persistent".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        let mut oneshot = persistent("inbox-plan", true);
        oneshot.registry.kind = "oneshot".into();
        let ws = [
            timed("nightly-sync", local(0, 23, 3)),
            persistent("sentinel", true),
            persistent("inbox-triage", true),
            persistent("down", false),
            oneshot,
        ];
        let t = tonight(&ws, &HashMap::new(), now);
        assert_eq!(
            names(&t),
            [
                ("sentinel", None),
                ("inbox-triage", None),
                ("nightly-sync", None)
            ],
            "a stopped persistent runner and a running oneshot with no timer are not always on"
        );
        assert_eq!(t.slots[0].at, None);
    }

    #[test]
    fn other_timers_in_the_window_are_only_counted() {
        let now = local(0, 20, 25);
        let timers = HashMap::from([
            (
                "journal-daily-summarize.service".to_string(),
                local(1, 1, 0),
            ),
            ("journal-index-rebuild.service".to_string(), local(1, 1, 15)),
            ("theme-day.service".to_string(), local(1, 7, 0)),
            ("agentctl@dream.service".to_string(), local(1, 3, 4)),
            ("never.service".to_string(), 0),
        ]);
        let t = tonight(&[], &timers, now);
        assert_eq!(t.other_timers, 2);
        assert!(
            t.slots.is_empty(),
            "a timer is a slot only through its worker"
        );
    }
}
