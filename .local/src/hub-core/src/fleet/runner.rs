//! One runner's page: `#fleet/<name>` on the web, Enter on a Workers row in the TUI. Read only
//! when it is opened (dashboards.md rule 10), and by this one reader for both surfaces (rule 8).
//! Nothing is kept; each part reads the file its writer owns:
//!
//! | part     | source                                                                             |
//! |----------|------------------------------------------------------------------------------------|
//! | conf     | `<agents>/<name>.conf`, every `KEY=value` in file order, secrets masked             |
//! | registry | as the Workers row's: its role file, the 24h calls, judge-eval's rule table          |
//! | runs     | agentctl's `runs.jsonl` for `RUN_DAYS`, each with its log's byte ranges, and the `<name>/run` sidecar while one runs |
//! | status   | agentctl's `<name>/status` (with `next=`, the runner's own next try) and the tail of `<INBOX>/activity.log` |
//! | calls    | agentctl-run's `calls.jsonl`: totals for 24h and 7d, and the newest `PAGE_CALLS`     |
//! | extras   | one block the conf's `DETAIL=` key names (`DETAILS`): content is data              |
//!
//! A runner with no run in the window is an empty `runs`, not an error; an unknown name is.

use super::*;
use crate::outbox::Step;

/// How far back the runs go.
pub const RUN_DAYS: i64 = 14;
const PAGE_RUNS: usize = 20;
const PAGE_ACTIVITY: usize = 20;
const PAGE_CALLS: usize = 20;
/// The newest verdicts and steps an extras block lists; the Log tab keeps the whole lists.
const PAGE_ROWS: usize = 10;
/// Enough of calls.jsonl for a week at today's rate (about 70 KB a day); `partial` says when not.
const CALLS_WEEK_TAIL: u64 = 16 << 20;
const INGEST_TAIL: u64 = 2 << 20;

/// The extras blocks a conf's `DETAIL=` can name.
pub const DETAILS: [&str; 4] = [
    "dispatch-verdicts",
    "ask-judge",
    "ingest",
    "sentinel-watches",
];

/// The intake steps the ingest block counts: what inbox-triage does with a line.
const INTAKE: [&str; 6] = ["moved", "filed", "dup", "planned", "left", "refused"];

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Runner {
    pub at: i64,
    pub name: String,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
    pub lane: String,
    pub description: String,
    pub enabled: bool,
    /// running, idle or off, the Workers row's words.
    pub state: String,
    pub running_since: Option<i64>,
    /// Its timer's next start, else the `next=` it wrote in its status.
    pub next: Option<i64>,
    pub registry: Registry,
    pub conf: Vec<ConfLine>,
    /// agentctl's status contract as written: state, project, item, detail, next, updated.
    pub status: BTreeMap<String, String>,
    /// activity.log, newest first.
    pub activity: Vec<Outcome>,
    /// Newest first, a running one at the top; at most `PAGE_RUNS`, the counts cover them all.
    pub runs: Vec<Job>,
    pub runs_total: u32,
    /// Finished runs in the window past the `runs` shown.
    pub runs_older: u32,
    pub failed_total: u32,
    /// One bucket per local day, oldest first, ending today.
    pub days: Vec<Day>,
    pub calls: PageCalls,
    pub extras: Extras,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct ConfLine {
    pub key: String,
    pub value: String,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Day {
    /// `MM-DD`, local.
    pub day: String,
    pub runs: u32,
    pub failed: u32,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct PageCalls {
    pub day: Totals,
    pub week: Totals,
    /// The tail read starts inside the week, so `week` is a floor.
    pub partial: bool,
    /// Newest first.
    pub recent: Vec<Call>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Totals {
    pub calls: u32,
    pub errors: u32,
    pub tokens: u64,
    /// None with no call that reported one.
    pub cost: Option<f64>,
    pub p50_ms: Option<u64>,
}

/// One Sentinel watch as its state files say.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Watch {
    pub name: String,
    /// TRIP, OK, ERROR, or `new` before its first run.
    pub state: String,
    pub severity: String,
    pub since: Option<i64>,
    pub lastrun: Option<i64>,
    pub lasttrip: Option<i64>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Extras {
    #[default]
    None,
    /// the dispatch judge (dispatch-judge.conf): the verdict counts and the newest `PAGE_ROWS`.
    DispatchVerdicts { dispatch: Dispatch },
    /// The answer judge's tiles and its newest `PAGE_ROWS` verdicts.
    AskJudge { judge: Judge },
    /// The intake steps in the ingest record for the week: counts and the newest `PAGE_ROWS`.
    Ingest {
        counts_7d: BTreeMap<String, u32>,
        steps: Vec<Step>,
        partial: bool,
    },
    /// Every Sentinel watch, TRIP and ERROR first.
    SentinelWatches { watches: Vec<Watch> },
}

/// The page for `name`, timers read from systemd.
pub fn read(paths: &Paths, name: &str) -> Result<Runner, String> {
    let mut errors = vec![];
    let timers = jobs::timer_starts().unwrap_or_else(|e| {
        errors.push(format!("timers: {e}"));
        HashMap::new()
    });
    let mut r = runner(paths, name, jobs::now(), &timers)?;
    errors.append(&mut r.errors);
    r.errors = errors;
    Ok(r)
}

/// A runner's name as agentctl takes it; anything else never reaches a path.
fn valid(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The page for `name` at `at`, with the timer starts given. Err for a name with no conf.
pub fn runner(
    paths: &Paths,
    name: &str,
    at: i64,
    timers: &HashMap<String, i64>,
) -> Result<Runner, String> {
    if !valid(name) {
        return Err(format!("{name:?} is not a runner name"));
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let path = paths.agents.join(format!("{name}.conf"));
    let text = std::fs::read_to_string(&path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!("no runner named {name}"),
        _ => format!("{}: {e}", path.display()),
    })?;
    let state = &paths.jobs.agentctl;
    let c = parse_conf(name, &text, &home, state);
    let keys = kv(
        &text,
        &["SCORE", "SENTINEL_WATCHES", "SENTINEL_STATE"],
        &home,
    );
    let key = |k: &str| keys.get(k).cloned().unwrap_or_default();
    let detail = c.detail.clone();
    let mut errors = vec![];

    let (runs, runs_total, runs_older, failed_total, days, running_since) =
        runs(paths, name, at, &mut errors);

    let status = read_status(state, name);
    let activity = match tail(&c.inbox.join("activity.log"), ACTIVITY_TAIL) {
        Ok((t, _)) => t
            .lines()
            .rev()
            .filter_map(parse_activity)
            .take(PAGE_ACTIVITY)
            .collect(),
        Err(e) => {
            errors.push(format!("activity: {e}"));
            vec![]
        }
    };

    let lf = langfuse_sessions(&paths.agents.join("session-outcomes.conf"));
    let (calls_text, cut) = tail(&paths.calls, CALLS_WEEK_TAIL).unwrap_or_else(|e| {
        errors.push(format!("calls: {e}"));
        Default::default()
    });
    // The file is in write order, so its first line is the tail's oldest. Only this runner's
    // lines are parsed: a name is `valid`, so its line carries it unescaped.
    let oldest = calls_text
        .lines()
        .find_map(|l| parse_call(l, &lf))
        .map(|(_, c, _)| c.at);
    let mine: Vec<(String, Call, String)> = calls_text
        .lines()
        .filter(|l| l.contains(name))
        .filter_map(|l| parse_call(l, &lf))
        .filter(|(agent, _, _)| agent == name)
        .collect();
    let page_calls = page_calls(&mine, cut, oldest, at);

    // judge-eval is the slow part: only a judge's page asks it.
    let (judge, evals) = if !key("SCORE").is_empty() || detail == "ask-judge" {
        match run_judge_eval(&paths.judge_eval).and_then(|t| judges(&t)) {
            Ok((j, e, _)) => (j, e),
            Err(e) => {
                errors.push(format!("judges: {e}"));
                Default::default()
            }
        }
    } else {
        Default::default()
    };
    let roles = read_roles(&paths.roles, std::slice::from_ref(&c));
    let registry = registry(&c, &roles, &calls_of(mine, at), &evals);

    let extras = match detail.as_str() {
        "" => Extras::None,
        "dispatch-verdicts" => {
            let mut dispatch = read_dispatch(&paths.dispatch, at, &mut errors);
            dispatch.recent.truncate(PAGE_ROWS);
            Extras::DispatchVerdicts { dispatch }
        }
        "ask-judge" => {
            let mut judge = judge;
            judge.verdicts.truncate(PAGE_ROWS);
            Extras::AskJudge { judge }
        }
        "ingest" => match tail(&paths.notes_state.join("ingest.jsonl"), INGEST_TAIL) {
            Ok((t, cut)) => ingest(&t, cut, at),
            Err(e) => {
                errors.push(format!("ingest: {e}"));
                Extras::None
            }
        },
        "sentinel-watches" => {
            let dir = |k: &str, d: &str| {
                Some(key(k))
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| Path::new(&home).join(d))
            };
            match watches(
                &dir("SENTINEL_WATCHES", ".agent/watches"),
                &dir("SENTINEL_STATE", ".local/state/watch-companion"),
            ) {
                Ok(watches) => Extras::SentinelWatches { watches },
                Err(e) => {
                    errors.push(format!("sentinel: {e}"));
                    Extras::None
                }
            }
        }
        other => {
            errors.push(format!(
                "DETAIL={other}: not a known extras block ({})",
                DETAILS.join(", ")
            ));
            Extras::None
        }
    };

    let next = timers
        .get(&format!("{AGENTCTL_PREFIX}{name}.service"))
        .copied()
        .filter(|&n| n > 0)
        .or_else(|| own_next(&status));
    Ok(Runner {
        at,
        name: name.to_string(),
        errors,
        state: match (running_since, c.enabled) {
            (Some(_), _) => "running",
            (None, true) => "idle",
            (None, false) => "off",
        }
        .into(),
        lane: c.lane,
        description: c.description,
        enabled: c.enabled,
        running_since,
        next,
        registry,
        conf: assignments(&text, &home)
            .into_iter()
            .map(|(key, value)| ConfLine {
                value: if secret(&key) { "(set)".into() } else { value },
                key,
            })
            .collect(),
        status,
        activity,
        runs,
        runs_total,
        runs_older,
        failed_total,
        days,
        calls: page_calls,
        extras,
    })
}

/// A conf key whose value the page must not show.
fn secret(key: &str) -> bool {
    let k = key.to_ascii_uppercase();
    k.contains("SECRET")
        || k.contains("PASSWORD")
        || k == "TOKEN"
        || k.ends_with("_TOKEN")
        || k.ends_with("_KEY")
}

type Runs = (Vec<Job>, u32, u32, u32, Vec<Day>, Option<i64>);

/// The runner's ledger runs in the window, a running one from its sidecar first, newest first.
fn runs(paths: &Paths, name: &str, at: i64, errors: &mut Vec<String>) -> Runs {
    let ledger = paths.jobs.agentctl.join("runs.jsonl");
    let mut mine: Vec<Job> = match jobs::read_or_empty(&ledger) {
        Ok(t) => {
            let (all, bad) = jobs::parse_agentctl_ledger(&t, at - RUN_DAYS * DAY);
            if bad > 0 {
                errors.push(format!(
                    "runs: {bad} unreadable line(s) in {} skipped",
                    ledger.display()
                ));
            }
            all.into_iter().filter(|j| j.name == name).collect()
        }
        Err(e) => {
            errors.push(format!("runs: {e}"));
            vec![]
        }
    };
    mine.sort_by_key(|j| std::cmp::Reverse(j.finished));
    let today = local_day(at);
    let mut days: Vec<Day> = (0..RUN_DAYS)
        .rev()
        .filter_map(|i| today.map(|d| d - chrono::Days::new(i as u64)))
        .map(|d| Day {
            day: d.format("%m-%d").to_string(),
            ..Default::default()
        })
        .collect();
    let (mut total, mut failed) = (0, 0);
    for j in &mine {
        total += 1;
        failed += u32::from(j.ok == Some(false));
        let Some(d) = j.finished.and_then(local_day) else {
            continue;
        };
        let key = d.format("%m-%d").to_string();
        if let Some(b) = days.iter_mut().find(|b| b.day == key) {
            b.runs += 1;
            b.failed += u32::from(j.ok == Some(false));
        }
    }
    mine.truncate(PAGE_RUNS);
    let older = total - mine.len() as u32;
    let running = running(&paths.jobs.agentctl, name, at);
    let since = running.as_ref().and_then(|j| j.started);
    mine.splice(0..0, running);
    (mine, total, older, failed, days, since)
}

fn local_day(t: i64) -> Option<chrono::NaiveDate> {
    Local.timestamp_opt(t, 0).single().map(|d| d.date_naive())
}

/// The run in flight, from the `run` sidecar agentctl writes at a start and removes at the stop:
/// `<started> <invocation> <stdout offset> <stderr offset>`.
fn running(state: &Path, name: &str, at: i64) -> Option<Job> {
    let s = std::fs::read_to_string(state.join(name).join("run")).ok()?;
    let f: Vec<&str> = s.split_whitespace().collect();
    let n = |i: usize| f.get(i).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    let started = f.first().and_then(|v| v.parse::<i64>().ok())?;
    let mut j = Job::new(jobs::Source::Agentctl, name, State::Running);
    j.started = Some(started);
    j.secs = Some(at - started);
    j.result = "running".into();
    j.log = Some(jobs::LogRef::Runner {
        name: name.to_string(),
        out: (n(2), None),
        err: (n(3), None),
    });
    if let Some(inv) = f.get(1).filter(|v| **v != "-") {
        j.detail = format!("inv {}", &inv[..inv.len().min(8)]);
    }
    Some(j)
}

/// agentctl's status contract for a runner; a runner that never reported has none.
pub fn read_status(state: &Path, name: &str) -> BTreeMap<String, String> {
    std::fs::read_to_string(state.join(name).join("status"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// The `next=` a runner wrote in its status: its own next try, for one no timer starts.
pub fn status_next(state: &Path, name: &str) -> Option<i64> {
    own_next(&read_status(state, name))
}

fn own_next(status: &BTreeMap<String, String>) -> Option<i64> {
    status
        .get("next")
        .and_then(|v| v.parse().ok())
        .filter(|&n: &i64| n > 0)
}

/// The runner's calls (its parsed calls.jsonl lines, in file order): totals for the day and the
/// week before `at`, the newest `PAGE_CALLS`. `oldest` is the tail's first call; a `cut` tail
/// that starts inside the week makes the week a floor.
fn page_calls(
    mine: &[(String, Call, String)],
    cut: bool,
    oldest: Option<i64>,
    at: i64,
) -> PageCalls {
    let within = |since: i64| -> Totals {
        let cs: Vec<&Call> = mine
            .iter()
            .map(|(_, c, _)| c)
            .filter(|c| c.at >= since)
            .collect();
        let mut ms: Vec<u64> = cs.iter().map(|c| c.ms).collect();
        ms.sort_unstable();
        Totals {
            calls: cs.len() as u32,
            errors: cs.iter().filter(|c| !c.ok).count() as u32,
            tokens: cs.iter().map(|c| c.tokens).sum(),
            cost: cs
                .iter()
                .filter_map(|c| c.cost)
                .fold(None, |a, x| Some(a.unwrap_or(0.0) + x)),
            p50_ms: nearest_rank(&ms, 50),
        }
    };
    PageCalls {
        day: within(at - DAY),
        week: within(at - WEEK),
        partial: cut && oldest.is_some_and(|o| o >= at - WEEK),
        // The file is in write order, so the last lines are the newest.
        recent: mine
            .iter()
            .rev()
            .take(PAGE_CALLS)
            .map(|(_, c, _)| c.clone())
            .collect(),
    }
}

/// The intake steps of the week before `at` in the ingest record's tail.
pub fn ingest(text: &str, cut: bool, at: i64) -> Extras {
    let mut counts_7d = BTreeMap::new();
    let mut oldest = i64::MAX;
    let mut steps: Vec<Step> = vec![];
    for s in text
        .lines()
        .filter_map(|l| serde_json::from_str::<Step>(l).ok())
    {
        let Some(t) = ts(&s.ts) else {
            continue;
        };
        oldest = oldest.min(t);
        if t < at - WEEK || !INTAKE.contains(&s.action.as_str()) {
            continue;
        }
        *counts_7d.entry(s.action.clone()).or_default() += 1;
        steps.push(s);
    }
    steps.reverse();
    steps.truncate(PAGE_ROWS);
    Extras::Ingest {
        counts_7d,
        steps,
        partial: cut && oldest >= at - WEEK,
    }
}

/// Every `<watches>/*.yaml` with its `<state>/<name>.*` files, TRIP and ERROR first, then by name.
pub fn watches(dir: &Path, state: &Path) -> Result<Vec<Watch>, String> {
    let rd = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let read = |n: &str, ext: &str| {
        std::fs::read_to_string(state.join(format!("{n}.{ext}")))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let mut out: Vec<Watch> = rd
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            let name = p.file_name()?.to_str()?.strip_suffix(".yaml")?.to_string();
            let yaml = std::fs::read_to_string(&p).unwrap_or_default();
            let severity = yaml
                .lines()
                .find_map(|l| l.strip_prefix("severity:"))
                .map(|v| v.trim().to_string())
                .unwrap_or_default();
            let st = read(&name, "state");
            Some(Watch {
                state: if st.is_empty() { "new".into() } else { st },
                severity,
                since: read(&name, "since").parse().ok(),
                lastrun: read(&name, "lastrun").parse().ok(),
                lasttrip: read(&name, "lasttrip").parse().ok(),
                name,
            })
        })
        .collect();
    let rank = |w: &Watch| match w.state.as_str() {
        "TRIP" => 0,
        "ERROR" => 1,
        _ => 2,
    };
    out.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.name.cmp(&b.name)));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: i64 = 1_762_200_000; // 2025-11-03T12:00:00-08:00

    /// A throwaway state tree under the system temp dir, removed on drop.
    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fixture(tag: &str) -> (Fixture, Paths) {
        let root = std::env::temp_dir().join(format!(
            "hub-core-runner-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let state = root.join("state");
        for d in [
            "agents", "roles", "state", "dispatch", "notes", "watches", "wc",
        ] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        let paths = Paths {
            agents: root.join("agents"),
            roles: root.join("roles"),
            calls: state.join("calls.jsonl"),
            jobs: jobs::Paths {
                agentctl: state,
                unity_runs: root.join("unity-runs.tsv"),
                cache: root.join("cache"),
            },
            dispatch: root.join("dispatch"),
            // Never run: no fixture conf below is a judge.
            judge_eval: root.join("no-judge-eval").display().to_string(),
            notes_state: root.join("notes"),
        };
        (Fixture(root), paths)
    }

    fn write(p: &Path, text: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    fn iso(t: i64) -> String {
        DateTime::<chrono::Utc>::from_timestamp(t, 0)
            .unwrap()
            .to_rfc3339()
    }

    fn ledger(
        name: &str,
        started: i64,
        secs: i64,
        result: &str,
        outcome: &str,
        out: (u64, u64),
    ) -> String {
        format!(
            r#"{{"name":"{name}","invocation":"abcdef1234","started":{started},"finished":{},"result":"{result}","exit":"0","outcome":"{outcome}","out":[{},{}],"err":[0,0]}}"#,
            started + secs,
            out.0,
            out.1
        )
    }

    #[test]
    fn a_runner_page_reads_its_conf_runs_status_activity_calls_and_extras() {
        let (fx, paths) = fixture("full");
        let st = &paths.jobs.agentctl;
        write(
            &paths.agents.join("inbox-triage.conf"),
            "# a comment\nNAME=inbox-triage\nKIND=persistent\nLANE=maintain\nDESCRIPTION='Route the outbox'\nINBOX=\"$HOME/nowhere-used\"\nROLE=distill\nMODEL=claude-opus-5-5\nDETAIL=ingest\nLANGFUSE_SECRET_KEY=sk-123\nAPI_TOKEN=t\n",
        );
        // INBOX is overridden to the state dir so activity.log sits beside status.
        let text = std::fs::read_to_string(paths.agents.join("inbox-triage.conf")).unwrap();
        write(
            &paths.agents.join("inbox-triage.conf"),
            &text.replace(
                "$HOME/nowhere-used",
                &st.join("inbox-triage").display().to_string(),
            ),
        );
        write(
            &paths.roles.join("distill.role"),
            "ROLE_DESC='reads, answers'\nROLE_WRITE=no\n",
        );
        write(
            &st.join("runs.jsonl"),
            &[
                ledger(
                    "inbox-triage",
                    T - 20 * DAY,
                    60,
                    "success",
                    "WORKED",
                    (0, 10),
                ),
                ledger(
                    "inbox-triage",
                    T - 3 * DAY,
                    60,
                    "success",
                    "WORKED",
                    (10, 20),
                ),
                ledger("other", T - 2 * DAY, 60, "success", "WORKED", (0, 5)),
                ledger("inbox-triage", T - 3600, 30, "failed", "FAILED", (20, 40)),
                "not json".into(),
            ]
            .join("\n"),
        );
        write(
            &st.join("inbox-triage/run"),
            &format!("{} 5c0da7977c8d4b54 40 7\n", T - 120),
        );
        write(
            &st.join("inbox-triage/status"),
            &format!("state=working\nproject=\nitem=agent-runtime\ndetail=moved 0; retry 12:05\nnext={}\nupdated={}\n", T + 300, T - 10),
        );
        write(
            &st.join("inbox-triage/activity.log"),
            "[2025-11-03T10:00:00-08:00] outcome=NOOP moved 0\n[2025-11-03T11:00:00-08:00] outcome=FAILED model call failed\n",
        );
        let call = |at: i64, ms: u64, exit: u8, cost: f64| {
            format!(
                r#"{{"agent":"inbox-triage","at":"{}","id":"c{at}","duration_ms":{ms},"exit":{exit},"gen_ai.response.model":"opus","cost_usd":{cost},"gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":5}}"#,
                iso(at)
            )
        };
        write(
            &paths.calls,
            &[
                call(T - 3 * DAY, 4000, 0, 0.5),
                call(T - 2 * 3600, 1000, 0, 0.25),
                call(T - 3600, 3000, 1, 0.25),
                r#"{"agent":"other","at":"2025-11-03T11:30:00-08:00","duration_ms":1,"exit":0}"#
                    .into(),
            ]
            .join("\n"),
        );
        let step = |at: i64, action: &str, text: &str| {
            format!(
                r#"{{"ts":"{}","action":"{action}","from":"outbox","to":"demo","lane":"","text":"{text}"}}"#,
                iso(at)
            )
        };
        write(
            &paths.notes_state.join("ingest.jsonl"),
            &[
                step(T - 8 * DAY, "filed", "too old"),
                step(T - 2 * DAY, "moved", "one"),
                step(T - DAY, "filed", "one"),
                step(T - 60, "item-set", "not intake"),
                step(T - 30, "left", "two"),
            ]
            .join("\n"),
        );

        let r = runner(&paths, "inbox-triage", T, &HashMap::new()).unwrap();
        assert_eq!(
            r.errors,
            vec![format!(
                "runs: 1 unreadable line(s) in {} skipped",
                st.join("runs.jsonl").display()
            )]
        );
        assert_eq!((r.lane.as_str(), r.state.as_str()), ("maintain", "running"));
        assert_eq!(r.running_since, Some(T - 120));
        // No timer: the runner's own next try.
        assert_eq!(r.next, Some(T + 300));
        assert_eq!(r.status["detail"], "moved 0; retry 12:05");
        assert_eq!(r.registry.role_desc, "reads, answers");
        assert_eq!(r.registry.model, "claude-opus-5-5");
        // The conf in file order, secrets masked.
        let conf: Vec<(&str, &str)> = r
            .conf
            .iter()
            .map(|c| (c.key.as_str(), c.value.as_str()))
            .collect();
        assert_eq!(conf[0], ("NAME", "inbox-triage"));
        assert!(conf.contains(&("LANGFUSE_SECRET_KEY", "(set)")));
        assert!(conf.contains(&("API_TOKEN", "(set)")));
        assert!(conf.contains(&("DESCRIPTION", "Route the outbox")));
        // Runs: the one in flight first, then the window's newest first; the 20-day-old one
        // and another runner's are not here.
        let runs: Vec<(&str, Option<i64>)> = r
            .runs
            .iter()
            .map(|j| (j.result.as_str(), j.started))
            .collect();
        assert_eq!(
            runs,
            vec![
                ("running", Some(T - 120)),
                ("failed exit=0", Some(T - 3600)),
                ("WORKED", Some(T - 3 * DAY))
            ]
        );
        assert_eq!(
            r.runs[0].log,
            Some(jobs::LogRef::Runner {
                name: "inbox-triage".into(),
                out: (40, None),
                err: (7, None)
            })
        );
        assert_eq!(
            r.runs[1].log,
            Some(jobs::LogRef::Runner {
                name: "inbox-triage".into(),
                out: (20, Some(40)),
                err: (0, Some(0))
            })
        );
        assert_eq!((r.runs_total, r.failed_total), (2, 1));
        assert_eq!(r.days.len(), RUN_DAYS as usize);
        assert_eq!(r.days.iter().map(|d| d.runs).sum::<u32>(), 2);
        assert_eq!(r.days.last().map(|d| (d.runs, d.failed)), Some((1, 1)));
        // Activity newest first.
        assert_eq!(
            r.activity
                .iter()
                .map(|o| o.word.as_str())
                .collect::<Vec<_>>(),
            ["FAILED", "NOOP"]
        );
        // Calls: the day has two, one failed; the week has all three.
        let d = &r.calls.day;
        assert_eq!(
            (d.calls, d.errors, d.tokens, d.cost, d.p50_ms),
            (2, 1, 30, Some(0.5), Some(1000))
        );
        let w = &r.calls.week;
        assert_eq!(
            (w.calls, w.errors, w.cost, w.p50_ms),
            (3, 1, Some(1.0), Some(3000))
        );
        assert!(!r.calls.partial);
        assert_eq!(r.calls.recent.first().map(|c| c.at), Some(T - 3600));
        assert_eq!(r.registry.calls.n_24h, 2);
        // The ingest block: the week's intake steps, newest first.
        match &r.extras {
            Extras::Ingest {
                counts_7d,
                steps,
                partial,
            } => {
                assert_eq!(
                    counts_7d
                        .iter()
                        .map(|(k, v)| (k.as_str(), *v))
                        .collect::<Vec<_>>(),
                    [("filed", 1), ("left", 1), ("moved", 1)]
                );
                assert_eq!(
                    steps.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
                    ["two", "one", "one"]
                );
                assert!(!partial);
            }
            e => panic!("{e:?}"),
        }
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["extras"]["kind"], "ingest");
        drop(fx);
    }

    #[test]
    fn a_runner_with_no_runs_is_an_empty_page_not_an_error() {
        let (_fx, paths) = fixture("empty");
        write(
            &paths.agents.join("quiet.conf"),
            "NAME=quiet\nKIND=oneshot\nSCHEDULE=daily\n",
        );
        let r = runner(&paths, "quiet", T, &HashMap::new()).unwrap();
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert!(r.runs.is_empty());
        assert_eq!((r.runs_total, r.state.as_str()), (0, "idle"));
        assert_eq!(r.days.iter().map(|d| d.runs).sum::<u32>(), 0);
        assert_eq!(r.calls.week, Totals::default());
        assert!(r.activity.is_empty() && r.status.is_empty());
        assert_eq!(r.extras, Extras::None);
    }

    #[test]
    fn the_page_lists_the_newest_runs_and_counts_the_older_ones_without_the_running_one() {
        let (_fx, paths) = fixture("many");
        let st = &paths.jobs.agentctl;
        write(&paths.agents.join("busy.conf"), "NAME=busy\n");
        let lines: Vec<String> = (0..25)
            .map(|i| ledger("busy", T - 3600 - i * 60, 5, "success", "NOOP", (0, 0)))
            .collect();
        write(&st.join("runs.jsonl"), &lines.join("\n"));
        write(
            &st.join("busy").join("run"),
            &format!("{} abcdef12 0 0\n", T - 30),
        );
        let r = runner(&paths, "busy", T, &HashMap::new()).unwrap();
        assert_eq!(
            r.runs.len(),
            PAGE_RUNS + 1,
            "the running row is on top of the page"
        );
        assert_eq!(r.runs[0].state, State::Running);
        assert_eq!((r.runs_total, r.runs_older), (25, 25 - PAGE_RUNS as u32));
    }

    #[test]
    fn an_unknown_runner_or_a_name_that_is_a_path_is_an_error() {
        let (_fx, paths) = fixture("unknown");
        assert_eq!(
            runner(&paths, "nobody", T, &HashMap::new()).unwrap_err(),
            "no runner named nobody"
        );
        for bad in ["../etc/passwd", "a/b", "", ".hidden"] {
            assert!(
                runner(&paths, bad, T, &HashMap::new())
                    .unwrap_err()
                    .contains("not a runner name"),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_timer_wins_over_the_status_next_and_an_unknown_detail_is_named() {
        let (_fx, paths) = fixture("timer");
        write(&paths.agents.join("t.conf"), "NAME=t\nDETAIL=nonsense\n");
        write(
            &paths.jobs.agentctl.join("t/status"),
            &format!("next={}\n", T + 900),
        );
        let timers = HashMap::from([("agentctl@t.service".to_string(), T + 60)]);
        let r = runner(&paths, "t", T, &timers).unwrap();
        assert_eq!(r.next, Some(T + 60));
        assert_eq!(
            r.errors,
            ["DETAIL=nonsense: not a known extras block (dispatch-verdicts, ask-judge, ingest, sentinel-watches)"]
        );
    }

    #[test]
    fn the_dispatch_block_counts_and_lists_the_newest_ten() {
        let (_fx, paths) = fixture("dispatch");
        write(
            &paths.agents.join("dispatch-judge.conf"),
            "NAME=dispatch-judge\nDETAIL=dispatch-verdicts\n",
        );
        let lines: Vec<String> = (0..12)
            .map(|i| {
                format!(
                    r#"{{"project":"p","key":"k{i}","verdict":"{}","at":"{}"}}"#,
                    if i % 2 == 0 { "dispatch" } else { "skip" },
                    iso(T - 3600 + i * 60)
                )
            })
            .collect();
        write(&paths.dispatch.join("verdicts.jsonl"), &lines.join("\n"));
        let r = runner(&paths, "dispatch-judge", T, &HashMap::new()).unwrap();
        match &r.extras {
            Extras::DispatchVerdicts { dispatch } => {
                assert_eq!(dispatch.recent.len(), PAGE_ROWS);
                assert_eq!(dispatch.recent[0].key, "k11");
                assert_eq!(dispatch.counts_24h.get("skip"), Some(&6));
            }
            e => panic!("{e:?}"),
        }
    }

    #[test]
    fn the_sentinel_block_lists_trips_and_errors_first() {
        let (fx, paths) = fixture("sentinel");
        let (w, s) = (fx.0.join("watches"), fx.0.join("wc"));
        write(
            &paths.agents.join("sentinel.conf"),
            &format!(
                "NAME=sentinel\nDETAIL=sentinel-watches\nSENTINEL_WATCHES={}\nSENTINEL_STATE={}\n",
                w.display(),
                s.display()
            ),
        );
        for (n, sev) in [
            ("alpha", "normal"),
            ("bravo", "high"),
            ("charlie", "low"),
            ("delta", "normal"),
        ] {
            write(
                &w.join(format!("{n}.yaml")),
                &format!("name: {n}\nseverity: {sev}\n"),
            );
        }
        write(&w.join("README.md"), "not a watch");
        write(&s.join("alpha.state"), "OK\n");
        write(&s.join("bravo.state"), "TRIP\n");
        write(&s.join("bravo.since"), &format!("{}\n", T - 60));
        write(&s.join("charlie.state"), "ERROR\n");
        let r = runner(&paths, "sentinel", T, &HashMap::new()).unwrap();
        match &r.extras {
            Extras::SentinelWatches { watches } => {
                let got: Vec<(&str, &str)> = watches
                    .iter()
                    .map(|w| (w.name.as_str(), w.state.as_str()))
                    .collect();
                assert_eq!(
                    got,
                    [
                        ("bravo", "TRIP"),
                        ("charlie", "ERROR"),
                        ("alpha", "OK"),
                        ("delta", "new")
                    ]
                );
                assert_eq!(
                    (watches[0].severity.as_str(), watches[0].since),
                    ("high", Some(T - 60))
                );
            }
            e => panic!("{e:?}"),
        }
    }
}
