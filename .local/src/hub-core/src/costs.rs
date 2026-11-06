//! The Costs tab, both surfaces: what the fleet spent over 24h, 7d or 30d, cut seven ways
//! (session, model, harness, tool, project, runner, kind), with fleet-bench's model evaluation on
//! the model and harness cuts. One reader over the stores that already hold every figure, so
//! nothing is written twice and the terminal and the browser cannot disagree (dashboards rule 8):
//!
//! | figure | store | read through |
//! |---|---|---|
//! | per session: cost, models, harness, project, runner, kind | outcomes rows | `agentctl-session-outcomes costs` |
//! | per runner call | `calls.jsonl` | `fleet::parse_call`, the Fleet tab's parser |
//! | per tool, allocated | `~/.agent/token-usage/<day>.json` (`TOKENS_DIR`) | the snapshot files |
//! | landed rate, redo, reverts, $ per PR | `fleet-bench models --json` | a shell-out, so the scoring stays there |
//! | live 24h and the Lazer pool | Prometheus `cc:` rules | `prom::instant` |
//!
//! The query filters slices (a session's cost on one model) before grouping, so `-model:opus`
//! narrows every outcomes cut; runner and tool cuts filter their own rows; the sort is over groups.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::session_actions::Runner;
use crate::table::{Row, Summary, Val, View};

const DAY: i64 = 24 * 3600;

/// The `by:` switch, in the bar's order.
pub const CUTS: [&str; 7] = [
    "session", "model", "harness", "tool", "project", "runner", "kind",
];
/// The window switch and its length. The read takes the longest, so a switch needs no re-read.
pub const WINDOWS: [(&str, i64); 3] = [("24h", DAY), ("7d", 7 * DAY), ("30d", 30 * DAY)];
/// What the tab opens on: the model cut over a week, the view of the mockup in the plan.
pub const DEFAULT_CUT: &str = "model";
pub const DEFAULT_WINDOW: &str = "7d";
/// A source older than this turns amber: outcomes and the token snapshot are written nightly.
pub const STALE_SECS: i64 = 36 * 3600;
/// The Grafana board with the spend trends; the tab draws no chart (dashboards rule 3).
pub const DASHBOARD: &str = "kb-agents-overview";

/// What the tool cut says when its snapshots predate the allocation, on both surfaces.
pub const UNPRICED: &str =
    "no snapshot in this window allocates dollars to tools yet: calls and tokens only";

/// The gauges the live tiles read: Claude Code's 24h cost and the Lazer pool's spend and cap.
const LIVE_Q: &str =
    r#"{__name__=~"cc:claude_code_cost_24h_usd|cc:lazer_spend_usd|cc:lazer_budget_usd"}"#;

/// One session's newest outcomes row, as `agentctl-session-outcomes costs` prints it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Spent {
    pub session_id: String,
    pub project: String,
    pub title: Option<String>,
    pub harness: Option<String>,
    /// The runner that made the call, for a headless run; none for a session.
    pub runner: Option<String>,
    /// `automated` (a runner call or a queue item's session) or `human`, as the outcomes CLI says.
    pub kind: Option<String>,
    pub account: Option<String>,
    pub models: Vec<String>,
    pub cost_usd: Option<f64>,
    pub cost_by_model: Option<BTreeMap<String, f64>>,
    pub tokens_total: Option<f64>,
    pub updated_epoch: Option<i64>,
    /// When the nightly writer last looked at the session, RFC 3339.
    pub observed: Option<String>,
    /// Its first merged PR as `owner/repo#N`.
    pub pr: Option<String>,
}

/// One `fleet-bench models --json` row: a model on a harness, and how its queue items went.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Eval {
    /// The alias an item names (`opus`), or the whole id.
    pub model: String,
    pub harness: String,
    pub done: u64,
    pub landed: u64,
    pub redo: u64,
    pub reverts: u64,
    pub cost_usd: f64,
    /// The landed items with a known cost, what cost per PR divides by.
    pub priced: u64,
    /// `list`, `gateway`, `mixed` or `-`.
    pub source: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Evals {
    days: Option<u32>,
    models: Vec<Eval>,
}

/// One runner call from `calls.jsonl`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Call {
    pub runner: String,
    pub model: String,
    pub at: i64,
    pub cost: Option<f64>,
    pub tokens: u64,
}

/// One tool's day in a token-usage snapshot. Its dollars are an allocation: each session's
/// cost split over its tools by their share of its carried tokens, never a metered figure.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ToolDay {
    pub tool: String,
    pub calls: u64,
    pub carried_tokens: u64,
    pub allocated_cost_usd: Option<f64>,
}

/// One day's snapshot: its tools and the cost no tool carried.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Snapshot {
    pub date: String,
    pub generated_at: Option<i64>,
    pub tools: Vec<ToolDay>,
    pub unallocated_usd: Option<f64>,
}

/// The live gauges; any can be missing.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Live {
    pub claude_24h: Option<f64>,
    pub lazer_spend: Option<f64>,
    pub lazer_budget: Option<f64>,
}

/// Everything one read gathered, over the longest window. `board` cuts it for a view.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Costs {
    pub at: i64,
    /// `<part>: <why>` for each source that could not be read; the rest still show.
    pub errors: Vec<String>,
    pub sessions: Vec<Spent>,
    pub evals: Vec<Eval>,
    /// fleet-bench's own window for the evaluation columns.
    pub eval_days: Option<u32>,
    pub calls: Vec<Call>,
    /// Newest first.
    pub snapshots: Vec<Snapshot>,
    pub live: Live,
    pub grafana: Option<String>,
}

/// Where the reader looks; tests and a checkout point these elsewhere.
#[derive(Clone, Debug)]
pub struct Paths {
    pub calls: PathBuf,
    pub tokens: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Paths {
            calls: crate::fleet::Paths::from_env().calls,
            tokens: std::env::var_os("TOKENS_DIR")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".agent/token-usage")),
        }
    }
}

fn longest() -> i64 {
    WINDOWS.iter().map(|w| w.1).max().unwrap_or(DAY)
}

/// Read every source once. A source that fails is named in `errors` and the others still show.
pub fn read(runner: &dyn Runner, paths: &Paths, now: i64) -> Costs {
    let mut c = Costs {
        at: now,
        grafana: crate::infra::grafana(),
        ..Costs::default()
    };
    let days = (longest() / DAY).to_string();
    let argv = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    match runner.run(&argv(&[
        "agentctl-session-outcomes",
        "costs",
        "--days",
        &days,
    ])) {
        Ok(out) => c.sessions = sessions(&out),
        Err(e) => c.errors.push(format!("outcomes: {e}")),
    }
    match runner.run(&argv(&["fleet-bench", "models", "--json"])) {
        Ok(out) => match serde_json::from_str::<Evals>(out.trim()) {
            Ok(e) => {
                c.evals = e.models;
                c.eval_days = e.days;
            }
            Err(e) => c.errors.push(format!("fleet-bench models: {e}")),
        },
        Err(e) => c.errors.push(format!("fleet-bench models: {e}")),
    }
    match std::fs::read_to_string(&paths.calls) {
        Ok(text) => c.calls = calls(&text, now - longest()),
        Err(e) => c.errors.push(format!("{}: {e}", paths.calls.display())),
    }
    c.snapshots = snapshots(&paths.tokens, (longest() / DAY) as usize);
    match crate::prom::base().and_then(|b| crate::prom::instant(&b, LIVE_Q)) {
        Ok(series) => {
            for s in series {
                let v = s.value;
                match s.label("__name__") {
                    "cc:claude_code_cost_24h_usd" => c.live.claude_24h = v,
                    "cc:lazer_spend_usd" => c.live.lazer_spend = v,
                    "cc:lazer_budget_usd" => c.live.lazer_budget = v,
                    _ => {}
                }
            }
        }
        Err(e) => c.errors.push(format!("Prometheus: {e}")),
    }
    c
}

/// The outcomes CLI's lines; one that does not parse is skipped, as every hub reader does.
pub fn sessions(out: &str) -> Vec<Spent> {
    out.lines()
        .filter_map(|l| serde_json::from_str::<Spent>(l).ok())
        .filter(|s| !s.session_id.is_empty())
        .collect()
}

/// calls.jsonl's lines since `since`, through the Fleet tab's parser.
pub fn calls(text: &str, since: i64) -> Vec<Call> {
    text.lines()
        .filter_map(|l| crate::fleet::parse_call(l, ""))
        .filter(|(_, c, _)| c.at >= since)
        .map(|(runner, c, _)| Call {
            runner,
            model: c.model,
            at: c.at,
            cost: c.cost,
            tokens: c.tokens,
        })
        .collect()
}

/// The newest `n` day snapshots in `dir`, newest first.
pub fn snapshots(dir: &Path, n: usize) -> Vec<Snapshot> {
    let mut days: Vec<(String, PathBuf)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let date = name.strip_suffix(".json")?;
            let ok =
                date.len() == 10 && chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_ok();
            ok.then(|| (date.to_string(), e.path()))
        })
        .collect();
    days.sort_by(|a, b| b.0.cmp(&a.0));
    days.into_iter()
        .take(n)
        .filter_map(|(date, p)| snapshot(&date, &std::fs::read_to_string(p).ok()?))
        .collect()
}

pub fn snapshot(date: &str, text: &str) -> Option<Snapshot> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    Some(Snapshot {
        date: date.to_string(),
        generated_at: v["generated_at"].as_str().and_then(epoch),
        tools: serde_json::from_value(v["by_tool"].clone()).unwrap_or_default(),
        unallocated_usd: v["by_tool_unallocated_usd"].as_f64(),
    })
}

fn epoch(t: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(t)
        .ok()
        .map(|t| t.timestamp())
}

/// A model id as the table shows it: Claude's without its `claude-` prefix.
pub fn short(model: &str) -> String {
    model.strip_prefix("claude-").unwrap_or(model).to_string()
}

/// The alias fleet-bench keys a model by: `claude-opus-5-5` is `opus`, anything else is itself
/// (fleet-bench's `alias`).
pub fn alias(model: &str) -> String {
    model
        .strip_prefix("claude-")
        .and_then(|r| r.split_once('-'))
        .map(|(f, _)| f)
        .filter(|f| !f.is_empty() && f.chars().all(|c| c.is_ascii_lowercase()))
        .map_or_else(|| model.to_string(), String::from)
}

/// Whether a fleet-bench row is this model's: its alias (`opus`), or the name an item gave a
/// model of another harness (`sol` for `gpt-5.6-sol`). Its `unrecorded` means an item with no
/// outcomes row, not a session with no model, so it joins nothing.
fn names_eval(e: &Eval, alias: &str, model: &str) -> bool {
    !alias.is_empty()
        && e.model != "unrecorded"
        && (e.model == alias || model.ends_with(&format!("-{}", e.model)))
}

/// A session's cost on one model: what every outcomes cut groups, and what the query filters.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Slice {
    pub session: String,
    pub title: String,
    pub project: String,
    pub harness: String,
    /// As shown (`opus-5-5`); `alias` is fleet-bench's key for it.
    pub model: String,
    pub alias: String,
    pub runner: String,
    pub kind: String,
    pub account: String,
    pub cost: f64,
    pub tokens: f64,
    pub at: i64,
    pub pr: Option<String>,
}

impl Row for Slice {
    const COLUMNS: &'static [&'static str] = &[
        "session", "title", "project", "harness", "model", "runner", "kind", "account", "cost",
        "tokens",
    ];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &["harness", "model", "project", "kind"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "session" => text(&self.session),
            "title" => text(&self.title),
            "project" => text(&self.project),
            "harness" => text(&self.harness),
            "model" => text(&self.model),
            "runner" => text(&self.runner),
            "kind" => text(&self.kind),
            "account" => text(&self.account),
            "cost" => Val::Num(self.cost),
            "tokens" => Val::Num(self.tokens),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        true
    }
}

/// Each model a session spent on and its share of the cost. The writer's `cost_by_model` split
/// wins; a session with no split books its whole cost on its one model, or on all of them joined
/// (`opus-5-5+haiku-4-5`) when it names several, since there is nothing to split them by.
fn shares(s: &Spent) -> Vec<(String, f64)> {
    let real = |m: &&String| !m.is_empty() && !m.starts_with('<');
    if let Some(by) = &s.cost_by_model {
        let pos: Vec<(&String, f64)> = by
            .iter()
            .filter(|(m, v)| real(m) && **v > 0.0)
            .map(|(m, v)| (m, *v))
            .collect();
        let sum: f64 = pos.iter().map(|x| x.1).sum();
        if sum > 0.0 {
            return pos.into_iter().map(|(m, v)| (m.clone(), v / sum)).collect();
        }
    }
    let mut names: Vec<&String> = s.models.iter().filter(real).collect();
    names.dedup();
    match names.as_slice() {
        [] => vec![("unrecorded".into(), 1.0)],
        [one] => vec![((*one).clone(), 1.0)],
        many => {
            let joined = many.iter().map(|m| short(m)).collect::<Vec<_>>().join("+");
            vec![(format!("claude-{joined}"), 1.0)]
        }
    }
}

/// The window's sessions as slices.
pub fn slices(sessions: &[Spent], since: i64) -> Vec<Slice> {
    let mut out = Vec::new();
    for s in sessions {
        let at = s.updated_epoch.unwrap_or(0);
        if at < since {
            continue;
        }
        // A row with no cost but a split books the split, which is what it measured.
        let whole = s.cost_usd.unwrap_or_else(|| {
            s.cost_by_model
                .as_ref()
                .map_or(0.0, |m| m.values().filter(|v| **v > 0.0).sum())
        });
        for (model, frac) in shares(s) {
            let alias = if model.contains('+') {
                String::new()
            } else {
                alias(&model)
            };
            out.push(Slice {
                session: s.session_id.clone(),
                title: s.title.clone().unwrap_or_default(),
                project: s.project.clone(),
                harness: s.harness.clone().unwrap_or_default(),
                model: short(&model),
                alias,
                runner: s.runner.clone().unwrap_or_default(),
                kind: s.kind.clone().unwrap_or_default(),
                account: s.account.clone().unwrap_or_default(),
                cost: whole * frac,
                tokens: s.tokens_total.unwrap_or(0.0) * frac,
                at,
                pr: s.pr.clone(),
            });
        }
    }
    out
}

/// One row of the table, whichever cut. Each cut fills its own columns (`columns`) and leaves
/// the rest empty, so one row type serves all seven and the sort means the same on each.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Line {
    pub session: Option<String>,
    pub title: Option<String>,
    pub tool: Option<String>,
    pub kind: Option<String>,
    pub project: Option<String>,
    pub harness: Option<String>,
    pub model: Option<String>,
    pub runner: Option<String>,
    pub sessions: Option<u64>,
    pub calls: Option<u64>,
    pub tokens: Option<f64>,
    pub cost: f64,
    /// Of what the filtered table sums to, 0..1.
    pub share: f64,
    /// fleet-bench's landed over done, 0..1.
    pub landed: Option<f64>,
    pub redo: Option<u64>,
    pub reverts: Option<u64>,
    pub per_pr: Option<f64>,
    /// What priced the evaluation's cost: `list`, `gateway` or `mixed`.
    pub src: Option<String>,
    pub pr: Option<String>,
    pub at: Option<i64>,
}

impl Row for Line {
    const COLUMNS: &'static [&'static str] = &[
        "session", "tool", "kind", "project", "harness", "model", "runner", "title", "sessions",
        "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src", "pr",
        "at",
    ];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &["model", "runner"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &Option<String>| s.as_ref().map_or(Val::None, |s| Val::Text(s.clone()));
        let num = |n: Option<f64>| n.map_or(Val::None, Val::Num);
        let int = |n: Option<u64>| n.map_or(Val::None, |n| Val::Num(n as f64));
        match col {
            "session" => text(&self.session),
            "title" => text(&self.title),
            "tool" => text(&self.tool),
            "kind" => text(&self.kind),
            "project" => text(&self.project),
            "harness" => text(&self.harness),
            "model" => text(&self.model),
            "runner" => text(&self.runner),
            "src" => text(&self.src),
            "pr" => text(&self.pr),
            "sessions" => int(self.sessions),
            "calls" => int(self.calls),
            "tokens" => num(self.tokens),
            "cost" => Val::Num(self.cost),
            "share" => Val::Num(self.share),
            "landed" => num(self.landed),
            "redo" => int(self.redo),
            "reverts" => int(self.reverts),
            "per_pr" => num(self.per_pr),
            "at" => num(self.at.map(|a| a as f64)),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        true
    }
}

/// The columns a cut shows, in order; both surfaces draw these and no others.
pub fn columns(cut: &str) -> &'static [&'static str] {
    match cut {
        "session" => &[
            "session", "project", "harness", "model", "runner", "tokens", "cost", "share", "pr",
            "at",
        ],
        "harness" => &[
            "harness", "sessions", "tokens", "cost", "share", "landed", "redo", "reverts",
            "per_pr", "src",
        ],
        "tool" => &["tool", "calls", "tokens", "cost", "share"],
        "project" => &["project", "sessions", "tokens", "cost", "share"],
        "runner" => &["runner", "model", "calls", "tokens", "cost", "share"],
        "kind" => &["kind", "sessions", "tokens", "cost", "share"],
        _ => &[
            "model", "harness", "sessions", "tokens", "cost", "share", "landed", "redo", "reverts",
            "per_pr", "src",
        ],
    }
}

/// What each cut's rows are read from, as the table's head says it.
pub fn source(cut: &str) -> &'static str {
    match cut {
        "tool" => {
            "token-usage snapshots; dollars allocated by each session's carried tokens, not metered"
        }
        "runner" => "agentctl-run calls.jsonl",
        _ => "outcomes rows",
    }
}

/// Sum a group's slices into one line; `key` fills the cut's own columns.
fn group(
    slices: &[&Slice],
    key: impl Fn(&Slice) -> (Line, String),
) -> Vec<(Line, BTreeSet<String>)> {
    let mut by: BTreeMap<String, (Line, BTreeSet<String>, f64)> = BTreeMap::new();
    for s in slices {
        let (line, k) = key(s);
        let e = by.entry(k).or_insert_with(|| (line, BTreeSet::new(), 0.0));
        e.0.cost += s.cost;
        e.2 += s.tokens;
        e.1.insert(s.session.clone());
    }
    by.into_values()
        .map(|(mut l, ids, tok)| {
            l.tokens = Some(tok.round());
            l.sessions = Some(ids.len() as u64);
            (l, ids)
        })
        .collect()
}

/// fleet-bench's figures summed over `evals`: counts add, and the rates are the ratio of the sums.
fn evaluate(l: &mut Line, evals: &[&Eval]) {
    if evals.is_empty() {
        return;
    }
    let sum = |f: fn(&Eval) -> u64| evals.iter().map(|e| f(e)).sum::<u64>();
    let (done, landed, priced) = (sum(|e| e.done), sum(|e| e.landed), sum(|e| e.priced));
    let cost: f64 = evals.iter().map(|e| e.cost_usd).sum();
    l.landed = (done > 0).then(|| landed as f64 / done as f64);
    l.redo = Some(sum(|e| e.redo));
    l.reverts = Some(sum(|e| e.reverts));
    l.per_pr = (priced > 0).then(|| cost / priced as f64);
    let srcs: BTreeSet<&str> = evals
        .iter()
        .map(|e| e.source.as_str())
        .filter(|s| !s.is_empty() && *s != "-")
        .collect();
    l.src = match srcs.len() {
        0 => None,
        1 => srcs.into_iter().next().map(String::from),
        _ => Some("mixed".into()),
    };
}

/// The outcomes cuts' lines from the kept slices.
fn outcome_lines(cut: &str, kept: &[&Slice], evals: &[Eval]) -> Vec<Line> {
    let of = |s: &str| Some(s.to_string()).filter(|s| !s.is_empty());
    match cut {
        "session" => {
            let mut lines: Vec<Line> = group(kept, |s| {
                let l = Line {
                    session: of(&s.session),
                    title: of(&s.title),
                    project: of(&s.project),
                    harness: of(&s.harness),
                    runner: of(&s.runner),
                    kind: of(&s.kind),
                    pr: s.pr.clone(),
                    at: Some(s.at),
                    ..Line::default()
                };
                (l, s.session.clone())
            })
            .into_iter()
            .map(|(l, _)| l)
            .collect();
            // A session's models, the costliest first, as one cell.
            for l in &mut lines {
                let mut ms: Vec<&&Slice> = kept
                    .iter()
                    .filter(|s| Some(&s.session) == l.session.as_ref())
                    .collect();
                ms.sort_by(|a, b| b.cost.total_cmp(&a.cost));
                l.model = Some(
                    ms.iter()
                        .map(|s| s.model.as_str())
                        .collect::<Vec<_>>()
                        .join(", "),
                )
                .filter(|m| !m.is_empty());
                l.sessions = None;
            }
            lines
        }
        "harness" => group(kept, |s| {
            let l = Line {
                harness: of(&s.harness),
                ..Line::default()
            };
            (l, s.harness.clone())
        })
        .into_iter()
        .map(|(mut l, _)| {
            let h = l.harness.clone().unwrap_or_default();
            evaluate(
                &mut l,
                &evals.iter().filter(|e| e.harness == h).collect::<Vec<_>>(),
            );
            l
        })
        .collect(),
        "project" => group(kept, |s| {
            let l = Line {
                project: of(&s.project),
                ..Line::default()
            };
            (l, s.project.clone())
        })
        .into_iter()
        .map(|(l, _)| l)
        .collect(),
        "kind" => group(kept, |s| {
            let l = Line {
                kind: of(&s.kind),
                ..Line::default()
            };
            (l, s.kind.clone())
        })
        .into_iter()
        .map(|(l, _)| l)
        .collect(),
        _ => group(kept, |s| {
            let l = Line {
                model: of(&s.model),
                harness: of(&s.harness),
                // The alias rides in `src` until the join below replaces it.
                src: of(&s.alias),
                ..Line::default()
            };
            (l, format!("{}\u{0}{}", s.model, s.harness))
        })
        .into_iter()
        .map(|(mut l, _)| {
            let (a, h) = (
                l.src.take().unwrap_or_default(),
                l.harness.clone().unwrap_or_default(),
            );
            let m = l.model.clone().unwrap_or_default();
            let mine: Vec<&Eval> = evals
                .iter()
                .filter(|e| e.harness == h && names_eval(e, &a, &m))
                .collect();
            evaluate(&mut l, &mine);
            l
        })
        .collect(),
    }
}

fn runner_lines(calls: &[Call], since: i64) -> Vec<Line> {
    let mut by: BTreeMap<&str, (Line, BTreeMap<&str, u64>, f64)> = BTreeMap::new();
    for c in calls.iter().filter(|c| c.at >= since) {
        let e = by.entry(c.runner.as_str()).or_insert_with(|| {
            let l = Line {
                runner: Some(c.runner.clone()),
                calls: Some(0),
                ..Line::default()
            };
            (l, BTreeMap::new(), 0.0)
        });
        e.0.calls = e.0.calls.map(|n| n + 1);
        e.0.cost += c.cost.unwrap_or(0.0);
        e.2 += c.tokens as f64;
        if !c.model.is_empty() {
            *e.1.entry(c.model.as_str()).or_default() += 1;
        }
    }
    by.into_values()
        .map(|(mut l, models, tok)| {
            l.tokens = Some(tok);
            // The model it called most, the one a runner's conf names.
            l.model = models
                .into_iter()
                .max_by_key(|(_, n)| *n)
                .map(|(m, _)| short(m));
            l
        })
        .collect()
}

/// The token snapshots inside the window: a day's file covers that day, so 24h is the newest.
fn tool_lines(snaps: &[Snapshot], days: usize) -> Vec<Line> {
    let mut by: BTreeMap<String, Line> = BTreeMap::new();
    let mut unallocated: Option<f64> = None;
    for s in snaps.iter().take(days) {
        for t in &s.tools {
            let l = by.entry(t.tool.clone()).or_insert_with(|| Line {
                tool: Some(t.tool.clone()),
                calls: Some(0),
                tokens: Some(0.0),
                ..Line::default()
            });
            l.calls = l.calls.map(|n| n + t.calls);
            l.tokens = l.tokens.map(|n| n + t.carried_tokens as f64);
            l.cost += t.allocated_cost_usd.unwrap_or(0.0);
        }
        if let Some(u) = s.unallocated_usd {
            *unallocated.get_or_insert(0.0) += u;
        }
    }
    let mut lines: Vec<Line> = by.into_values().collect();
    // The cost no tool carried, so the allocations sum to the snapshots' whole cost.
    if let Some(u) = unallocated.filter(|u| *u > 0.0) {
        lines.push(Line {
            tool: Some("(no tool)".into()),
            cost: u,
            ..Line::default()
        });
    }
    lines
}

/// One window's total from the outcomes rows: what the tile prints and the 7d check sums.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Total {
    pub window: &'static str,
    pub usd: f64,
    pub sessions: usize,
    /// Sessions with no cost recorded, which count as $0.
    pub unpriced: usize,
}

pub fn totals(sessions: &[Spent], now: i64) -> Vec<Total> {
    WINDOWS
        .iter()
        .map(|(w, secs)| {
            let inw: Vec<&Spent> = sessions
                .iter()
                .filter(|s| s.updated_epoch.unwrap_or(0) >= now - secs)
                .collect();
            Total {
                window: w,
                usd: inw.iter().map(|s| s.cost_usd.unwrap_or(0.0)).sum(),
                sessions: inw.len(),
                unpriced: inw.iter().filter(|s| s.cost_usd.is_none()).count(),
            }
        })
        .collect()
}

/// One source's freshness, as the tab's head lists them.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Source {
    pub name: &'static str,
    /// The newest record it holds, unix seconds.
    pub as_of: Option<i64>,
    /// Older than `STALE_SECS`: the tab shows it amber.
    pub stale: bool,
}

fn sources(c: &Costs) -> Vec<Source> {
    let fresh = |name, as_of: Option<i64>| Source {
        name,
        as_of,
        stale: as_of.is_none_or(|t| c.at - t > STALE_SECS),
    };
    let outcomes = c
        .sessions
        .iter()
        .filter_map(|s| s.observed.as_deref().and_then(epoch))
        .max();
    let snap = c.snapshots.first().and_then(|s| s.generated_at);
    vec![
        fresh("outcomes", outcomes),
        fresh("token snapshot", snap),
        Source {
            name: "calls",
            as_of: c.calls.iter().map(|x| x.at).max(),
            stale: false,
        },
    ]
}

/// What a surface draws for one view: the tiles, the sources and the table.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Board {
    pub at: i64,
    pub by: String,
    pub window: String,
    pub cuts: &'static [&'static str],
    pub windows: Vec<&'static str>,
    pub totals: Vec<Total>,
    pub live: Live,
    pub sources: Vec<Source>,
    pub errors: Vec<String>,
    /// This cut's columns, the only ones drawn.
    pub columns: &'static [&'static str],
    /// What this cut's rows are read from.
    pub source: &'static str,
    pub eval_days: Option<u32>,
    /// `UNPRICED` on the tool cut with no allocated dollars in its window: cost and share are
    /// unknown. Both surfaces print this text.
    pub unpriced: Option<&'static str>,
    pub rows: Vec<Line>,
    /// What the shown rows add up to, under the query.
    pub shown_usd: f64,
    pub table: Summary,
    pub grafana: Option<String>,
}

/// A cut or window the tab knows, else its default, so a stale link still opens.
pub fn cut(by: &str) -> &'static str {
    CUTS.iter()
        .find(|c| c.eq_ignore_ascii_case(by.trim()))
        .copied()
        .unwrap_or(DEFAULT_CUT)
}

pub fn window(w: &str) -> (&'static str, i64) {
    WINDOWS
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(w.trim()))
        .or_else(|| WINDOWS.iter().find(|(n, _)| *n == DEFAULT_WINDOW))
        .copied()
        .unwrap_or(WINDOWS[0])
}

/// The view `by`/`w`/`q`/`sort`/`dir` over one read.
pub fn board(c: &Costs, by: &str, w: &str, q: &str, sort: &str, dir: &str) -> Board {
    let by = cut(by);
    let (w, secs) = window(w);
    let since = c.at - secs;
    let cols = columns(by);
    // A sort on a column this cut does not show is no sort.
    let sort = if cols.iter().any(|x| x.eq_ignore_ascii_case(sort)) {
        sort
    } else {
        ""
    };
    // `total` is the cut's rows under no query, so "3 of 12" counts rows, not slices.
    let (mut lines, filter, total) = match by {
        "runner" | "tool" => {
            let all = if by == "runner" {
                runner_lines(&c.calls, since)
            } else {
                tool_lines(&c.snapshots, (secs / DAY) as usize)
            };
            let v = View::new::<Line>(q, "", "", "");
            let (kept, s) = v.summary(&all);
            let n = all.len();
            (kept.into_iter().cloned().collect::<Vec<_>>(), s, n)
        }
        _ => {
            let all = slices(&c.sessions, since);
            let v = View::new::<Slice>(q, "", "", "");
            let (kept, s) = v.summary(&all);
            let lines = outcome_lines(by, &kept, &c.evals);
            let n = if v.q.is_empty() {
                lines.len()
            } else {
                outcome_lines(by, &all.iter().collect::<Vec<_>>(), &[]).len()
            };
            (lines, s, n)
        }
    };
    // No snapshot in the window carries the allocation yet, so the tool cut has calls and
    // tokens but no dollars: the surfaces print "-" and say why, never $0.
    let unpriced = by == "tool"
        && !c.snapshots.iter().take((secs / DAY) as usize).any(|s| {
            s.unallocated_usd.is_some() || s.tools.iter().any(|t| t.allocated_cost_usd.is_some())
        });
    let shown_usd: f64 = lines.iter().map(|l| l.cost).sum();
    for l in &mut lines {
        l.share = if shown_usd > 0.0 {
            l.cost / shown_usd
        } else {
            0.0
        };
    }
    // The table's own order is the costliest first.
    lines.sort_by(|a, b| b.cost.total_cmp(&a.cost));
    let order = View::new::<Line>("", "", sort, dir);
    let (rows, ord) = order.summary(&lines);
    let rows: Vec<Line> = rows.into_iter().cloned().collect();
    let table = Summary {
        q: filter.q,
        state: String::new(),
        sort: ord.sort,
        dir: ord.dir,
        total,
        shown: rows.len(),
        states: Vec::new(),
        columns: ord
            .columns
            .into_iter()
            .filter(|col| cols.contains(&col.key))
            .collect(),
        facets: filter
            .facets
            .into_iter()
            .filter(|f| !f.values.is_empty())
            .collect(),
    };
    Board {
        at: c.at,
        by: by.into(),
        window: w.into(),
        cuts: &CUTS,
        windows: WINDOWS.iter().map(|w| w.0).collect(),
        totals: totals(&c.sessions, c.at),
        live: c.live.clone(),
        sources: sources(c),
        errors: c.errors.clone(),
        columns: cols,
        source: source(by),
        eval_days: c.eval_days,
        unpriced: unpriced.then_some(UNPRICED),
        rows,
        shown_usd,
        table,
        grafana: c.grafana.clone(),
    }
}

/// `$1,288.40` style money for the tiles and cells; `-` for none.
pub fn usd(v: Option<f64>) -> String {
    match v {
        None => "-".into(),
        Some(x) if x.abs() >= 100.0 => format!("${x:.0}"),
        Some(x) => format!("${x:.2}"),
    }
}

/// A token count as the table prints it: 1.9B, 61M, 12k.
pub fn tokens(n: Option<f64>) -> String {
    match n {
        None => "-".into(),
        Some(n) if n >= 1e9 => format!("{:.1}B", n / 1e9),
        Some(n) if n >= 1e6 => format!("{:.0}M", n / 1e6),
        Some(n) if n >= 1e3 => format!("{:.0}k", n / 1e3),
        Some(n) => format!("{n:.0}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn spent(
        id: &str,
        project: &str,
        harness: &str,
        cost: f64,
        by: &[(&str, f64)],
        ago: i64,
    ) -> Spent {
        Spent {
            session_id: id.into(),
            project: project.into(),
            harness: Some(harness.into()),
            kind: Some(
                if project == "_runner" {
                    "automated"
                } else {
                    "human"
                }
                .into(),
            ),
            models: by.iter().map(|(m, _)| m.to_string()).collect(),
            cost_usd: Some(cost),
            cost_by_model: (by.len() > 1)
                .then(|| by.iter().map(|(m, v)| (m.to_string(), *v)).collect()),
            tokens_total: Some(1000.0),
            updated_epoch: Some(NOW - ago),
            ..Spent::default()
        }
    }

    fn costs() -> Costs {
        Costs {
            at: NOW,
            sessions: vec![
                spent(
                    "s1",
                    "dotfiles",
                    "claude",
                    10.0,
                    &[("claude-opus-5-5", 8.0), ("claude-haiku-4-5", 2.0)],
                    3600,
                ),
                spent(
                    "s2",
                    "playground",
                    "claude",
                    4.0,
                    &[("claude-opus-5-5", 0.0)],
                    2 * DAY,
                ),
                spent("s3", "dotfiles", "codex", 1.5, &[("gpt-5.4", 0.0)], 3 * DAY),
                spent(
                    "s4",
                    "_runner",
                    "claude-lazer",
                    0.5,
                    &[("claude-sonnet-5-5", 0.0)],
                    20 * DAY,
                ),
            ],
            evals: vec![Eval {
                model: "opus".into(),
                harness: "claude".into(),
                done: 10,
                landed: 9,
                redo: 1,
                reverts: 0,
                cost_usd: 45.0,
                priced: 9,
                source: "list".into(),
            }],
            calls: vec![
                Call {
                    runner: "dream".into(),
                    model: "claude-opus-5-5".into(),
                    at: NOW - 60,
                    cost: Some(0.8),
                    tokens: 100,
                },
                Call {
                    runner: "dream".into(),
                    model: "claude-opus-5-5".into(),
                    at: NOW - 2 * DAY,
                    cost: Some(0.2),
                    tokens: 50,
                },
                Call {
                    runner: "ask-judge".into(),
                    model: "claude-sonnet-5-5".into(),
                    at: NOW - 120,
                    cost: Some(0.1),
                    tokens: 10,
                },
            ],
            snapshots: vec![Snapshot {
                date: "2027-01-14".into(),
                generated_at: Some(NOW - 3600),
                tools: vec![
                    ToolDay {
                        tool: "Bash".into(),
                        calls: 30,
                        carried_tokens: 900,
                        allocated_cost_usd: Some(7.0),
                    },
                    ToolDay {
                        tool: "Read".into(),
                        calls: 5,
                        carried_tokens: 100,
                        allocated_cost_usd: Some(2.0),
                    },
                ],
                unallocated_usd: Some(1.0),
            }],
            ..Costs::default()
        }
    }

    fn names(b: &Board, col: &str) -> Vec<String> {
        b.rows
            .iter()
            .map(|r| match r.val(col) {
                Val::Text(t) => t,
                Val::Num(n) => n.to_string(),
                Val::None => "-".into(),
            })
            .collect()
    }

    #[test]
    fn the_totals_are_the_outcomes_cost_per_window() {
        let t = totals(&costs().sessions, NOW);
        let usd: Vec<f64> = t.iter().map(|t| t.usd).collect();
        assert_eq!(usd, [10.0, 15.5, 16.0]);
        assert_eq!(t[1].sessions, 3);
    }

    #[test]
    fn the_model_cut_splits_a_session_by_its_cost_by_model_and_joins_the_evaluation() {
        let b = board(&costs(), "model", "7d", "", "", "");
        assert_eq!(names(&b, "model"), ["opus-5-5", "haiku-4-5", "gpt-5.4"]);
        let opus = &b.rows[0];
        assert!((opus.cost - 12.0).abs() < 1e-9, "8 of s1 and all of s2");
        assert_eq!(opus.sessions, Some(2));
        assert_eq!(opus.landed, Some(0.9));
        assert_eq!(opus.per_pr, Some(5.0));
        assert_eq!(opus.src.as_deref(), Some("list"));
        assert_eq!(b.rows[2].landed, None, "codex has no fleet-bench row");
        // Every cut of the outcomes sums to the window's total.
        assert!((b.shown_usd - 15.5).abs() < 1e-9);
        let share: f64 = b.rows.iter().map(|r| r.share).sum();
        assert!((share - 1.0).abs() < 1e-9);
    }

    #[test]
    fn each_cut_groups_by_its_own_key() {
        let c = costs();
        let b = board(&c, "session", "30d", "", "", "");
        assert_eq!(names(&b, "session"), ["s1", "s2", "s3", "s4"]);
        assert_eq!(b.rows[0].model.as_deref(), Some("opus-5-5, haiku-4-5"));
        let b = board(&c, "harness", "30d", "", "", "");
        assert_eq!(names(&b, "harness"), ["claude", "codex", "claude-lazer"]);
        assert_eq!(b.rows[0].landed, Some(0.9));
        let b = board(&c, "project", "30d", "", "", "");
        assert_eq!(names(&b, "project"), ["dotfiles", "playground", "_runner"]);
        let b = board(&c, "kind", "30d", "", "", "");
        assert_eq!(names(&b, "kind"), ["human", "automated"]);
        let b = board(&c, "runner", "24h", "", "", "");
        assert_eq!(names(&b, "runner"), ["dream", "ask-judge"]);
        assert_eq!(
            b.rows[0].calls,
            Some(1),
            "the 2-day-old call is outside 24h"
        );
        assert_eq!(b.rows[0].model.as_deref(), Some("opus-5-5"));
        let b = board(&c, "tool", "7d", "", "", "");
        assert_eq!(names(&b, "tool"), ["Bash", "Read", "(no tool)"]);
        assert!(
            (b.shown_usd - 10.0).abs() < 1e-9,
            "allocations and the rest sum to the cost"
        );
        assert!(b.unpriced.is_none());
        let mut old = c.clone();
        for t in &mut old.snapshots[0].tools {
            t.allocated_cost_usd = None;
        }
        old.snapshots[0].unallocated_usd = None;
        assert!(
            board(&old, "tool", "7d", "", "", "").unpriced.is_some(),
            "a snapshot from before the allocation"
        );
    }

    #[test]
    fn a_sort_goes_both_ways_and_the_default_is_the_costliest_first() {
        let c = costs();
        let up = board(&c, "project", "30d", "", "cost", "asc");
        assert_eq!(names(&up, "project"), ["_runner", "playground", "dotfiles"]);
        let down = board(&c, "project", "30d", "", "cost", "");
        assert_eq!(
            names(&down, "project"),
            ["dotfiles", "playground", "_runner"]
        );
        let by_name = board(&c, "project", "30d", "", "project", "asc");
        assert_eq!(
            names(&by_name, "project"),
            ["_runner", "dotfiles", "playground"]
        );
        // A column the cut does not show sorts nothing.
        let off = board(&c, "project", "30d", "", "landed", "asc");
        assert_eq!(off.table.sort, "");
        assert!(off
            .table
            .columns
            .iter()
            .all(|c| columns("project").contains(&c.key)));
    }

    #[test]
    fn the_query_filters_the_slices_before_they_are_grouped() {
        let c = costs();
        let b = board(&c, "project", "7d", "harness:codex", "", "");
        assert_eq!(names(&b, "project"), ["dotfiles"]);
        assert!((b.shown_usd - 1.5).abs() < 1e-9, "only s3's cost");
        assert_eq!(
            (b.table.shown, b.table.total),
            (1, 2),
            "rows of the cut, not slices"
        );
        let b = board(&c, "model", "7d", "-model:opus", "", "");
        assert_eq!(names(&b, "model"), ["haiku-4-5", "gpt-5.4"]);
        let b = board(&c, "session", "7d", "-model:opus", "", "");
        assert!(
            (b.rows[0].cost - 2.0).abs() < 1e-9,
            "s1 without its opus share"
        );
        assert!(b.table.facets.iter().any(|f| f.key == "harness"));
    }

    #[test]
    fn a_query_with_no_match_is_an_empty_table_that_says_so() {
        let b = board(&costs(), "model", "7d", "harness:nope", "", "");
        assert!(b.rows.is_empty());
        assert_eq!(b.table.shown, 0);
        assert!(b.table.total > 0, "the surfaces say no match, not no data");
        assert_eq!(b.shown_usd, 0.0);
    }

    #[test]
    fn a_stale_link_opens_the_default_view() {
        let b = board(&costs(), "nope", "1y", "", "", "");
        assert_eq!(
            (b.by.as_str(), b.window.as_str()),
            (DEFAULT_CUT, DEFAULT_WINDOW)
        );
    }

    #[test]
    fn a_session_with_no_split_books_its_models_whole() {
        let mut s = spent("x", "p", "claude", 3.0, &[], 0);
        s.models = vec![
            "claude-opus-5-5".into(),
            "claude-haiku-4-5".into(),
            "<synthetic>".into(),
        ];
        let v = slices(&[s.clone()], 0);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].model, "opus-5-5+haiku-4-5");
        assert_eq!(v[0].alias, "", "a joined model has no evaluation");
        s.models.clear();
        assert_eq!(slices(&[s], 0)[0].model, "unrecorded");
        assert_eq!(alias("claude-opus-5-5"), "opus");
        assert_eq!(alias("gpt-5.4"), "gpt-5.4");
        let sol = Eval {
            model: "sol".into(),
            ..Eval::default()
        };
        assert!(names_eval(&sol, "gpt-5.6-sol", "gpt-5.6-sol"));
        let none = Eval {
            model: "unrecorded".into(),
            ..Eval::default()
        };
        assert!(!names_eval(&none, "unrecorded", "unrecorded"));
    }

    #[test]
    fn the_sources_say_how_old_they_are() {
        let mut c = costs();
        c.sessions[0].observed = Some("2020-01-01T00:00:00Z".into());
        let s = sources(&c);
        assert!(s[0].stale, "outcomes from 2020");
        assert!(!s[1].stale, "a snapshot an hour old");
        c.snapshots.clear();
        assert!(sources(&c)[1].stale, "no snapshot at all is stale");
    }

    #[test]
    fn the_readers_take_the_lines_they_understand() {
        let out = r#"{"session_id":"a","project":"p","cost_usd":1.5,"updated_epoch":5}
not json
{"project":"no id"}"#;
        assert_eq!(sessions(out).len(), 1);
        let snap = snapshot(
            "2027-01-14",
            r#"{"generated_at":"2027-01-15T03:40:00-08:00","by_tool":[{"tool":"Bash","calls":3,"chars":9,"carried_tokens":40,"allocated_cost_usd":1.25}],"by_tool_unallocated_usd":0.5}"#,
        )
        .unwrap();
        assert_eq!(snap.tools[0].allocated_cost_usd, Some(1.25));
        assert_eq!(snap.unallocated_usd, Some(0.5));
        let line = r#"{"id":"c","agent":"dream","at":"2027-01-15T03:40:00-08:00","duration_ms":5,"exit":0,"gen_ai.request.model":"claude-opus-5-5","cost_usd":0.4,"gen_ai.usage.input_tokens":2}"#;
        let c = calls(line, 0);
        assert_eq!((c[0].runner.as_str(), c[0].cost), ("dream", Some(0.4)));
        assert!(calls(line, i64::MAX).is_empty());
    }

    #[test]
    fn money_and_tokens_read_short() {
        assert_eq!(usd(Some(1288.4)), "$1288");
        assert_eq!(usd(Some(8.734)), "$8.73");
        assert_eq!(usd(None), "-");
        assert_eq!(tokens(Some(1.9e9)), "1.9B");
        assert_eq!(tokens(Some(61e6)), "61M");
    }
}
