//! The Costs tab's Consumers section, both surfaces: every LLM consumer with its priority, what it
//! runs on, the budget it spends from, what it has spent, its fallback and its status, one row each.
//! A `must` consumer on a low-priority team or source, or on a team at its cap, is a MISMATCH.
//!
//! | figure | store | read through |
//! |---|---|---|
//! | teams, keys, their spend, budget and metadata priority; the sources; aliases and fallbacks | `claude-acct gateway`'s snapshot (`boards::gateway_snapshot`) | the file |
//! | each runner's priority, harness, model, route, key and source | the agentctl confs | `agentctl list --json` |
//! | a Codex source's week used and room, a key source's room | claude-acct's textfile | the Burn read (`burn::Burn`) |
//!
//! A row is a runner whose conf has a PRIORITY, or a gateway key no such runner's route names.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::burn::{Account, Burn};
use crate::session_actions::Runner;
use crate::table::{Row, Summary, Val, View};

/// A snapshot older than this is amber: the timer writes it every 15 minutes.
pub const STALE_SECS: i64 = 2 * 3600;

/// What each column says, defined once for both surfaces.
pub const LEGEND: &[(&str, &str)] = &[
    (
        "PRI",
        "the priority its conf or key declares: must, low, off",
    ),
    (
        "RUNS ON",
        "harness, model and route, or the key's models on the gateway",
    ),
    ("BUDGET", "the team, key or plan it spends from"),
    (
        "SPENT",
        "the key's spend in its budget period (all = no reset), or the plan's week used",
    ),
    (
        "FALLBACK",
        "where the gateway sends it when its model fails (none on a native route)",
    ),
];

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Team {
    pub alias: Option<String>,
    pub spend: Option<f64>,
    pub max_budget: Option<f64>,
    pub blocked: bool,
    pub budget_duration: Option<String>,
    pub budget_reset_at: Option<String>,
    pub priority: Option<String>,
    pub note: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Key {
    pub alias: Option<String>,
    pub team: Option<String>,
    pub spend: Option<f64>,
    pub max_budget: Option<f64>,
    pub blocked: bool,
    pub budget_duration: Option<String>,
    pub models: Vec<String>,
    pub consumer: Option<String>,
    pub priority: Option<String>,
}

/// A row of claude-acct's sources file, with the key alias of a `litellm-key` one.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Source {
    pub name: String,
    pub kind: String,
    pub reserve: Option<f64>,
    pub parent: Option<String>,
    pub priority: Option<String>,
    pub key: Option<String>,
}

/// `claude-acct gateway`'s file.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    pub at: i64,
    pub teams: Vec<Team>,
    pub keys: Vec<Key>,
    pub sources: Vec<Source>,
    /// None when the gateway config could not be read: the fallback column is then unknown.
    pub aliases: Option<BTreeMap<String, String>>,
    pub fallbacks: Option<BTreeMap<String, Vec<String>>>,
}

/// One runner as `agentctl list --json` prints it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Conf {
    pub name: String,
    pub invalid: bool,
    pub enabled: bool,
    pub priority: Option<String>,
    pub harness: String,
    pub model: Option<String>,
    pub route: Option<String>,
    pub source: Option<String>,
    pub route_transport: Option<String>,
    pub route_model: Option<String>,
    pub route_key: Option<String>,
}

/// The inputs, read once with the rest of the tab.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Read {
    pub snapshot: Option<Snapshot>,
    pub confs: Vec<Conf>,
    /// `<part>: <why>` for an input that could not be read.
    pub errors: Vec<String>,
}

/// Read the snapshot and the confs. A part that fails is named in `errors`; the other still shows.
pub fn read(runner: &dyn Runner, path: &Path) -> Read {
    let mut r = Read::default();
    match std::fs::read_to_string(path) {
        Ok(t) => match serde_json::from_str(&t) {
            Ok(s) => r.snapshot = Some(s),
            Err(e) => r.errors.push(format!("{}: {e}", path.display())),
        },
        Err(e) => r.errors.push(format!(
            "no gateway snapshot at {} ({e}): claude-acct gateway writes it",
            path.display()
        )),
    }
    let argv = ["agentctl", "list", "--json"].map(String::from);
    match runner
        .run(&argv)
        .and_then(|o| serde_json::from_str::<Vec<Conf>>(o.trim()).map_err(|e| e.to_string()))
    {
        Ok(c) => r.confs = c,
        Err(e) => r.errors.push(format!("agentctl list --json: {e}")),
    }
    r
}

/// One row, every cell worded here so both surfaces print the same.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Consumer {
    pub consumer: String,
    /// `runner` or `key`.
    pub kind: &'static str,
    pub priority: String,
    pub runs_on: String,
    pub budget: String,
    pub spent: String,
    pub fallback: String,
    pub status: String,
    /// Who the key says uses it (its metadata.consumer), for a key row.
    pub who: Option<String>,
    pub mismatch: bool,
    /// `bad` on a MISMATCH or a must consumer stopped by its cap, `ok` otherwise.
    pub level: &'static str,
}

impl Row for Consumer {
    const COLUMNS: &'static [&'static str] = &[
        "consumer", "priority", "runs_on", "budget", "spent", "fallback", "status",
    ];
    const STATES: &'static [&'static str] = &["all", "mismatch"];
    const FACETS: &'static [&'static str] = &["priority"];
    const LEAD: &'static str = "consumer";
    const GLANCE: &'static [&'static str] = &["priority", "status"];

    fn val(&self, col: &str) -> Val {
        Val::Text(self.show(col).to_string())
    }
    fn in_state(&self, state: &str) -> bool {
        state != "mismatch" || self.mismatch
    }
    /// Must above low above off, so the sort on PRI reads as the priorities do.
    fn rank(&self, col: &str) -> Val {
        match col {
            "priority" => Val::Num(prio_rank(&self.priority) as f64),
            _ => self.val(col),
        }
    }
}

impl Consumer {
    pub fn show(&self, col: &str) -> &str {
        match col {
            "consumer" => &self.consumer,
            "priority" => &self.priority,
            "runs_on" => &self.runs_on,
            "budget" => &self.budget,
            "spent" => &self.spent,
            "fallback" => &self.fallback,
            "status" => &self.status,
            _ => "",
        }
    }
}

fn prio_rank(p: &str) -> u8 {
    match p {
        "must" => 3,
        "low" => 2,
        "off" => 1,
        _ => 0,
    }
}

/// What a surface draws.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Consumers {
    /// The folded line: counts, each team's spend, the Codex lines and any MISMATCH.
    pub head: String,
    /// `bad` with a MISMATCH or a must consumer at its cap, `warn` with a stale, missing or
    /// unreadable input or a key Burn calls unreadable, `ok` otherwise.
    pub level: &'static str,
    /// Set when the snapshot is older than `STALE_SECS`.
    pub stale: Option<String>,
    pub errors: Vec<String>,
    pub columns: &'static [&'static str],
    pub headers: Vec<&'static str>,
    pub rows: Vec<Consumer>,
    /// One line per team and per unlabelled-by-the-gateway source (Codex): its priority and budget.
    pub pools: Vec<String>,
    /// The gateway's aliases and fallback edges, one line, or why they are unknown.
    pub routes: String,
    pub legend: &'static [(&'static str, &'static str)],
    pub table: Option<Summary>,
}

pub fn header(col: &str) -> &'static str {
    match col {
        "consumer" => "CONSUMER",
        "priority" => "PRI",
        "runs_on" => "RUNS ON",
        "budget" => "BUDGET",
        "spent" => "SPENT",
        "fallback" => "FALLBACK",
        "status" => "STATUS",
        _ => "",
    }
}

fn money(v: f64) -> String {
    crate::queue::money(v)
}

/// The text inside a gateway model name's parens (`fast (gpt-oss-120b)` is `gpt-oss-120b`), a
/// Claude id without `claude-`, else itself.
fn short(model: &str) -> String {
    match model.split_once('(') {
        Some((_, r)) => r.trim_end_matches(')').trim().to_string(),
        None => crate::costs::short(model),
    }
}

fn at_cap(spend: Option<f64>, max: Option<f64>) -> bool {
    matches!((spend, max), (Some(s), Some(m)) if s >= m)
}

/// `$28.27/$150 all`, `$0.02/$25 30d`, `$0.74 all` with no cap.
fn spent(k: &Key) -> String {
    let period = k.budget_duration.as_deref().unwrap_or("all");
    let s = money(k.spend.unwrap_or(0.0));
    match k.max_budget {
        Some(m) => format!("{s}/{} {period}", money(m)),
        None => format!("{s} {period}"),
    }
}

struct Ctx<'a> {
    snap: Option<&'a Snapshot>,
    burn: &'a Burn,
}

impl<'a> Ctx<'a> {
    fn team(&self, alias: Option<&str>) -> Option<&'a Team> {
        let a = alias?;
        self.snap?
            .teams
            .iter()
            .find(|t| t.alias.as_deref() == Some(a))
    }
    fn key(&self, alias: &str) -> Option<&'a Key> {
        self.snap?
            .keys
            .iter()
            .find(|k| k.alias.as_deref() == Some(alias))
    }
    fn source(&self, name: &str) -> Option<&'a Source> {
        self.snap?.sources.iter().find(|s| s.name == name)
    }
    fn account(&self, name: &str) -> Option<&'a Account> {
        self.burn.accounts.iter().find(|a| a.name == name)
    }
    /// The gateway's edges out of `model`, through its alias: `none` with no edge, `?` when the
    /// config was not read.
    fn fallback(&self, models: &[String]) -> String {
        let Some(s) = self.snap else {
            return "?".into();
        };
        let (Some(al), Some(fb)) = (&s.aliases, &s.fallbacks) else {
            return "?".into();
        };
        let mut out = BTreeSet::new();
        for m in models {
            let target = al.get(m).unwrap_or(m);
            for t in fb.get(target).into_iter().flatten() {
                out.insert(short(t));
            }
        }
        if out.is_empty() {
            "none".into()
        } else {
            out.into_iter().collect::<Vec<_>>().join(", ")
        }
    }
    /// The key a route's ROUTE_KEY_SOURCE names, when the gateway has a key by that alias:
    /// `rbw:litellm_comms_triage_key` is comms-triage, `file:.../knowledge-engine/key` is
    /// knowledge-engine and `file:.../lazer-eval.key` is lazer-eval. A file named plainly `key` names
    /// no key, so only its directory is a candidate.
    fn route_key(&self, src: &str) -> Option<&'a Key> {
        let mut cands = vec![];
        if let Some(r) = src.strip_prefix("rbw:") {
            let r = r.strip_prefix("litellm_").unwrap_or(r);
            cands.push(r.strip_suffix("_key").unwrap_or(r).replace('_', "-"));
        }
        if let Some(f) = src.strip_prefix("file:") {
            let p = Path::new(f);
            if let Some(stem) = p
                .file_stem()
                .and_then(|s| s.to_str())
                .filter(|s| *s != "key")
            {
                cands.push(stem.to_string());
            }
            if let Some(dir) = p
                .parent()
                .and_then(|d| d.file_name())
                .and_then(|d| d.to_str())
            {
                cands.push(dir.to_string());
            }
        }
        cands.iter().find_map(|c| self.key(c))
    }
    /// Why a must consumer on this key, team or source is in the wrong place, if it is.
    fn mismatch(
        &self,
        prio: &str,
        key: Option<&Key>,
        team: Option<&Team>,
        src: Option<&Source>,
    ) -> Option<String> {
        if prio != "must" {
            return None;
        }
        if let Some(t) = team {
            let name = t.alias.as_deref().unwrap_or("its team");
            if t.priority.as_deref() == Some("low") {
                return Some(format!("{name} is low priority"));
            }
            if at_cap(t.spend, t.max_budget) {
                return Some(format!("{name} is at its cap"));
            }
        }
        if let Some(k) = key {
            let name = k.alias.as_deref().unwrap_or("its key");
            if let Some(p @ ("low" | "off")) = k.priority.as_deref() {
                return Some(format!("key {name} is {p} priority"));
            }
            if k.blocked {
                return Some(format!("key {name} is blocked"));
            }
        }
        if let Some(s) = src.filter(|s| s.priority.as_deref() == Some("low")) {
            return Some(format!("source {} is low priority", s.name));
        }
        None
    }
}

/// Where a Codex source stops: its own reserve, or claude-acct's RESERVE_PCT (scaled by the pace
/// level, so not a fixed number here) when the sources file gives it none.
fn stops(x: &Source) -> String {
    x.reserve
        .map_or("stops at the default reserve".into(), |r| {
            format!("stops at {:.0}%", 100.0 - r)
        })
}

/// A key's own state: blocked, at its cap, its team at cap, or no room in claude-acct.
fn key_status(c: &Ctx, k: &Key, team: Option<&Team>) -> Option<String> {
    if k.blocked {
        return Some("blocked".into());
    }
    if at_cap(k.spend, k.max_budget) {
        return Some("at cap".into());
    }
    if team.is_some_and(|t| at_cap(t.spend, t.max_budget)) {
        return Some("team at cap".into());
    }
    let alias = k.alias.as_deref()?;
    let src = c
        .snap?
        .sources
        .iter()
        .find(|s| s.key.as_deref() == Some(alias))?;
    room_status(c.account(&src.name)?)
}

fn room_status(a: &Account) -> Option<String> {
    if a.state == "unreadable" {
        return Some("unread".into());
    }
    let r = a.room.as_ref().filter(|r| !r.ok)?;
    Some(format!("no room: {}", r.reasons.join(", ")))
}

fn finish(mut row: Consumer, why: Option<String>, stopped: bool) -> Consumer {
    if let Some(w) = why {
        row.mismatch = true;
        row.status = format!("MISMATCH: {w}");
        row.level = "bad";
    } else {
        row.level = if stopped && row.priority == "must" {
            "bad"
        } else {
            "ok"
        };
    }
    row
}

fn runner_row(c: &Ctx, f: &Conf, key: Option<&Key>) -> Consumer {
    let prio = f.priority.clone().unwrap_or_default();
    let model = f
        .model
        .as_deref()
        .or(f.route_model.as_deref())
        .map_or("default".into(), short);
    let route = f.route.clone().unwrap_or_default();
    let native = matches!(
        f.route_transport.as_deref(),
        Some("anthropic-native" | "openai-native")
    );
    let mut row = Consumer {
        consumer: f.name.clone(),
        kind: "runner",
        priority: prio.clone(),
        runs_on: format!("{} {model} via {route}", f.harness),
        ..Consumer::default()
    };
    let mut status = None;
    let (mut team, mut src) = (None, None);
    if let Some(k) = key {
        team = c.team(k.team.as_deref());
        row.budget = format!(
            "{} (key {})",
            k.team.as_deref().unwrap_or("no team"),
            k.alias.as_deref().unwrap_or("-")
        );
        row.spent = spent(k);
        row.fallback = c.fallback(&f.route_model.iter().cloned().collect::<Vec<_>>());
        status = key_status(c, k, team);
    } else if let Some(s) = f.source.as_deref() {
        src = c.source(s);
        let acct = c.account(s);
        row.budget = match src {
            Some(x) if x.kind == "codex" => format!("{s} plan, {}", stops(x)),
            Some(x) => format!("{s} ({})", x.kind),
            None => format!("{s} (not a source)"),
        };
        row.spent = acct.map_or("-".into(), |a| format!("{} week", a.used_text));
        status = acct.and_then(room_status);
    } else if f.harness == "claude" && native {
        row.budget = "Claude accounts".into();
        row.spent = "in Burn".into();
    } else {
        row.budget = "-".into();
        row.spent = "-".into();
    }
    if native {
        row.fallback = "none (native)".into();
    } else if row.fallback.is_empty() {
        row.fallback = c.fallback(&f.route_model.iter().cloned().collect::<Vec<_>>());
    }
    if !f.enabled {
        status = Some("disabled".into());
    }
    let stopped = f.enabled && status.is_some();
    row.status = status.unwrap_or_else(|| "ok".into());
    finish(row, c.mismatch(&prio, key, team, src), stopped)
}

fn key_row(c: &Ctx, k: &Key, taken: &BTreeSet<&str>) -> Consumer {
    let alias = k.alias.clone().unwrap_or_else(|| "(no alias)".into());
    let team = c.team(k.team.as_deref());
    let prio = k.priority.clone().unwrap_or_else(|| "-".into());
    let models: Vec<String> = k.models.iter().map(|m| short(m)).collect();
    let runs_on = match models.len() {
        0 => "gateway, every model".into(),
        n if n > 3 => format!("gateway {} +{}", models[..3].join(", "), n - 3),
        _ => format!("gateway {}", models.join(", ")),
    };
    let status = key_status(c, k, team);
    let stopped = status.is_some();
    let row = Consumer {
        consumer: if taken.contains(alias.as_str()) {
            format!("{alias} key")
        } else {
            alias
        },
        kind: "key",
        priority: prio.clone(),
        runs_on,
        budget: k.team.clone().unwrap_or_else(|| "own budget".into()),
        spent: spent(k),
        fallback: c.fallback(&k.models),
        status: status.unwrap_or_else(|| "ok".into()),
        who: k.consumer.clone(),
        ..Consumer::default()
    };
    finish(row, c.mismatch(&prio, Some(k), team, None), stopped)
}

/// The section under one sort (`sort`/`dir` over `Consumer::COLUMNS`; blank is the section's own
/// order: MISMATCH first, then must, low, off, runners before keys).
pub fn build(r: &Read, burn: &Burn, now: i64, sort: &str, dir: &str) -> Consumers {
    let c = Ctx {
        snap: r.snapshot.as_ref(),
        burn,
    };
    let confs: Vec<&Conf> = r
        .confs
        .iter()
        .filter(|f| !f.invalid && f.priority.is_some())
        .collect();
    let mut linked = BTreeSet::new();
    let mut rows: Vec<Consumer> = confs
        .iter()
        .map(|f| {
            let key = f.route_key.as_deref().and_then(|s| c.route_key(s));
            if let Some(a) = key.and_then(|k| k.alias.as_deref()) {
                linked.insert(a);
            }
            runner_row(&c, f, key)
        })
        .collect();
    let taken: BTreeSet<&str> = confs.iter().map(|f| f.name.as_str()).collect();
    if let Some(s) = c.snap {
        rows.extend(
            s.keys
                .iter()
                .filter(|k| !k.alias.as_deref().is_some_and(|a| linked.contains(a)))
                .map(|k| key_row(&c, k, &taken)),
        );
    }
    rows.sort_by_key(|x| {
        (
            !x.mismatch,
            x.level != "bad",
            std::cmp::Reverse(prio_rank(&x.priority)),
            x.kind != "runner",
            x.consumer.clone(),
        )
    });
    let mut errors = r.errors.clone();
    let stale = c.snap.filter(|s| now - s.at > STALE_SECS).map(|s| {
        format!(
            "stale: the gateway snapshot is {}h old (claude-acct gateway, timer claude-acct-usage)",
            (now - s.at) / 3600
        )
    });
    if c.snap.is_some_and(|s| s.aliases.is_none()) {
        errors.push(
            "the gateway config was not read: fallbacks unknown (gateway.config in harnesses.json)"
                .into(),
        );
    }
    let mismatches = rows.iter().filter(|x| x.mismatch).count();
    let level = if rows.iter().any(|x| x.level == "bad") {
        "bad"
    } else if stale.is_some()
        || !errors.is_empty()
        || burn.keys.as_ref().is_some_and(|k| k.level == "warn")
    {
        "warn"
    } else {
        "ok"
    };
    let (view_rows, table) = View::new::<Consumer>("", "", sort, dir).summary(&rows);
    let view_rows: Vec<Consumer> = view_rows.into_iter().cloned().collect();
    let pools = pools(&c);
    Consumers {
        head: head(&rows, mismatches, &c),
        level,
        stale,
        errors,
        columns: Consumer::COLUMNS,
        headers: Consumer::COLUMNS.iter().map(|k| header(k)).collect(),
        rows: view_rows,
        pools,
        routes: routes(c.snap),
        legend: LEGEND,
        table: Some(table),
    }
}

fn team_text(t: &Team) -> String {
    let cap = if at_cap(t.spend, t.max_budget) {
        " AT CAP"
    } else {
        ""
    };
    format!(
        "{} {}/{}{cap}",
        t.alias.as_deref().unwrap_or("-"),
        money(t.spend.unwrap_or(0.0)),
        t.max_budget.map_or("-".into(), money)
    )
}

/// `2 MISMATCH | 33 consumers: must 15, low 14, off 4 | lazer-core $0.00/$200 | ...`
fn head(rows: &[Consumer], mismatches: usize, c: &Ctx) -> String {
    if rows.is_empty() && c.snap.is_none() {
        return "no consumers read".into();
    }
    let mut by: BTreeMap<u8, (String, usize)> = BTreeMap::new();
    for r in rows {
        let e = by
            .entry(prio_rank(&r.priority))
            .or_insert((r.priority.clone(), 0));
        e.1 += 1;
    }
    let counts: Vec<String> = by
        .values()
        .rev()
        .map(|(p, n)| format!("{} {n}", if p.is_empty() { "-" } else { p }))
        .collect();
    let mut parts = vec![];
    if mismatches > 0 {
        parts.push(format!("{mismatches} MISMATCH"));
    }
    parts.push(format!("{} consumers: {}", rows.len(), counts.join(", ")));
    if let Some(s) = c.snap {
        parts.extend(s.teams.iter().map(team_text));
    }
    parts.join(" | ")
}

fn pools(c: &Ctx) -> Vec<String> {
    let Some(s) = c.snap else {
        return vec![];
    };
    let mut out: Vec<String> = s
        .teams
        .iter()
        .map(|t| {
            let reset = t
                .budget_reset_at
                .as_deref()
                .map(|r| format!(", resets {}", r.get(..10).unwrap_or(r)))
                .unwrap_or_default();
            format!(
                "team {} {} per {}{reset}",
                t.priority.as_deref().unwrap_or("-"),
                team_text(t),
                t.budget_duration.as_deref().unwrap_or("-")
            )
        })
        .collect();
    out.extend(s.sources.iter().filter(|x| x.kind == "codex").map(|x| {
        let used = c
            .account(&x.name)
            .map_or("-".into(), |a| a.used_text.clone());
        format!(
            "source {} {} Codex plan, {}, week used {used}",
            x.priority.as_deref().unwrap_or("-"),
            x.name,
            stops(x)
        )
    }));
    out
}

fn routes(s: Option<&Snapshot>) -> String {
    let Some(s) = s else {
        return "aliases and fallbacks: no snapshot".into();
    };
    let (Some(al), Some(fb)) = (&s.aliases, &s.fallbacks) else {
        return "aliases and fallbacks: the gateway config was not read".into();
    };
    let a: Vec<String> = al
        .iter()
        .map(|(k, v)| format!("{k} -> {}", short(v)))
        .collect();
    let f: Vec<String> = fb
        .iter()
        .flat_map(|(k, vs)| {
            vs.iter()
                .map(move |v| format!("{} -> {}", short(k), short(v)))
        })
        .collect();
    format!(
        "aliases: {}; fallbacks: {}",
        a.join(", "),
        if f.is_empty() {
            "none".into()
        } else {
            f.join(", ")
        }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn snap() -> Snapshot {
        serde_json::from_value(serde_json::json!({
            "at": NOW - 600,
            "teams": [
                {"alias": "lazer-core", "spend": 0.5, "max_budget": 200.0, "priority": "must", "budget_duration": "1mo"},
                {"alias": "lazer-pool", "spend": 228.0, "max_budget": 50.0, "priority": "low", "budget_duration": "1mo"}
            ],
            "keys": [
                {"alias": "comms-triage", "team": "lazer-core", "spend": 0.02, "max_budget": 25.0, "budget_duration": "30d", "models": ["fast"], "priority": "must"},
                {"alias": "claude-reserve", "team": "lazer-pool", "spend": 92.0, "max_budget": 100.0, "budget_duration": "30d", "models": ["claude-sonnet-5"], "priority": "low", "consumer": "cl --lazer"},
                {"alias": "glm-pilot", "team": "lazer-pool", "spend": 48.0, "max_budget": 50.0, "blocked": true, "models": ["reasoning (glm-5.3)"], "priority": "off"}
            ],
            "sources": [
                {"name": "codex", "kind": "codex", "reserve": 30, "priority": "low"},
                {"name": "codex-core", "kind": "codex", "reserve": 5, "priority": "must"}
            ],
            "aliases": {"fast": "fast (gpt-oss-120b)"},
            "fallbacks": {"fast (gpt-oss-120b)": ["assist (gemini-flash)"]}
        }))
        .unwrap()
    }

    fn conf(name: &str, prio: &str, harness: &str, route: &str, transport: &str) -> Conf {
        Conf {
            name: name.into(),
            enabled: true,
            priority: Some(prio.into()),
            harness: harness.into(),
            route: Some(route.into()),
            route_transport: Some(transport.into()),
            ..Conf::default()
        }
    }

    fn gateway_conf(name: &str, key: &str) -> Conf {
        Conf {
            route_model: Some("fast".into()),
            route_key: Some(key.into()),
            model: Some("fast".into()),
            ..conf(name, "must", "raw", "gateway-fast", "openai-compatible")
        }
    }

    fn row<'a>(c: &'a Consumers, name: &str) -> &'a Consumer {
        c.rows
            .iter()
            .find(|r| r.consumer == name)
            .unwrap_or_else(|| panic!("no row {name}: {:?}", c.rows))
    }

    fn built(confs: Vec<Conf>) -> Consumers {
        let r = Read {
            snapshot: Some(snap()),
            confs,
            errors: vec![],
        };
        build(&r, &Burn::default(), NOW, "", "")
    }

    #[test]
    fn a_gateway_runner_spends_from_its_routes_key_and_shows_the_fallback_edge() {
        let c = built(vec![gateway_conf(
            "version-summary",
            "rbw:litellm_comms_triage_key",
        )]);
        let r = row(&c, "version-summary");
        assert_eq!(r.budget, "lazer-core (key comms-triage)");
        assert_eq!(r.spent, "$0.02/$25.00 30d");
        assert_eq!(r.fallback, "gemini-flash");
        assert_eq!((r.status.as_str(), r.level), ("ok", "ok"));
        assert!(
            !c.rows.iter().any(|x| x.consumer == "comms-triage"),
            "a key a runner names is that runner's row, not a second one"
        );
        assert_eq!(c.level, "ok");
    }

    #[test]
    fn a_must_consumer_on_lazer_pool_is_a_mismatch_and_the_section_is_red() {
        let c = built(vec![gateway_conf(
            "nightly-thing",
            "file:/home/x/.local/state/claude-reserve/key",
        )]);
        let r = row(&c, "nightly-thing");
        assert!(r.mismatch, "{r:?}");
        assert_eq!(r.status, "MISMATCH: lazer-pool is low priority");
        assert_eq!(r.level, "bad");
        assert_eq!(c.level, "bad");
        assert!(c.head.starts_with("1 MISMATCH | "), "{}", c.head);
        assert_eq!(c.rows[0].consumer, "nightly-thing", "a MISMATCH leads");
    }

    fn built_with(s: Snapshot, confs: Vec<Conf>) -> Consumers {
        let r = Read {
            snapshot: Some(s),
            confs,
            errors: vec![],
        };
        build(&r, &Burn::default(), NOW, "", "")
    }

    #[test]
    fn a_must_runner_on_a_must_team_still_mismatches_on_a_low_off_or_blocked_key() {
        let mut s = snap();
        let base = s.keys[0].clone();
        for (alias, prio, blocked) in [
            ("low-pin", "low", false),
            ("off-pin", "off", false),
            ("shut-pin", "must", true),
        ] {
            s.keys.push(Key {
                alias: Some(alias.into()),
                priority: Some(prio.into()),
                blocked,
                ..base.clone()
            });
        }
        let c = built_with(
            s,
            vec![
                gateway_conf("a", "rbw:litellm_low_pin_key"),
                gateway_conf("b", "rbw:litellm_off_pin_key"),
                gateway_conf("d", "rbw:litellm_shut_pin_key"),
                gateway_conf("e", "rbw:litellm_comms_triage_key"),
            ],
        );
        assert_eq!(row(&c, "a").status, "MISMATCH: key low-pin is low priority");
        assert_eq!(row(&c, "b").status, "MISMATCH: key off-pin is off priority");
        assert_eq!(row(&c, "d").status, "MISMATCH: key shut-pin is blocked");
        assert!(
            !row(&c, "e").mismatch,
            "a must key on a must team is the control"
        );
    }

    #[test]
    fn a_codex_source_with_no_reserve_stops_at_the_default_reserve_not_100() {
        let mut s = snap();
        s.sources[0].reserve = None;
        let mut ke = conf("ke", "low", "codex", "codex-personal", "openai-native");
        ke.source = Some("codex".into());
        let c = built_with(s, vec![ke]);
        assert_eq!(
            row(&c, "ke").budget,
            "codex plan, stops at the default reserve"
        );
        assert!(c
            .pools
            .iter()
            .any(|p| p.contains("codex Codex plan, stops at the default reserve")));
        assert!(!c.pools.iter().any(|p| p.contains("100%")), "{:?}", c.pools);
    }

    #[test]
    fn a_key_file_named_key_matches_by_its_directory_never_a_key_aliased_key() {
        let mut s = snap();
        let mut generic = s.keys[0].clone();
        generic.alias = Some("key".into());
        s.keys.push(generic);
        let c = built_with(
            s,
            vec![
                gateway_conf("stray", "file:/home/x/.local/state/no-such-dir/key"),
                gateway_conf("named", "file:/home/x/.local/state/comms-triage/key"),
            ],
        );
        assert_eq!(row(&c, "stray").budget, "-", "{:?}", row(&c, "stray"));
        assert_eq!(row(&c, "named").budget, "lazer-core (key comms-triage)");
    }

    #[test]
    fn the_same_low_consumer_on_lazer_pool_is_no_mismatch() {
        let mut f = gateway_conf("dream-ish", "rbw:litellm_claude_reserve_key");
        f.priority = Some("low".into());
        let c = built(vec![f]);
        let r = row(&c, "dream-ish");
        assert!(!r.mismatch);
        assert_eq!((r.status.as_str(), r.level), ("team at cap", "ok"));
    }

    #[test]
    fn a_must_key_on_a_capped_team_and_a_must_runner_on_the_low_codex_source_mismatch() {
        let mut s = snap();
        s.teams[0].spend = Some(200.0);
        let mut ke = conf(
            "knowledge-engine",
            "must",
            "codex",
            "codex-personal",
            "openai-native",
        );
        ke.source = Some("codex".into());
        let r = Read {
            snapshot: Some(s),
            confs: vec![ke],
            errors: vec![],
        };
        let c = build(&r, &Burn::default(), NOW, "", "");
        assert_eq!(
            row(&c, "comms-triage").status,
            "MISMATCH: lazer-core is at its cap"
        );
        let k = row(&c, "knowledge-engine");
        assert_eq!(k.status, "MISMATCH: source codex is low priority");
        assert_eq!(k.budget, "codex plan, stops at 70%");
        assert_eq!(k.fallback, "none (native)");
    }

    #[test]
    fn codex_core_is_a_must_source_so_a_must_runner_there_is_fine() {
        let mut ke = conf(
            "knowledge-engine",
            "must",
            "codex",
            "codex-personal",
            "openai-native",
        );
        ke.source = Some("codex-core".into());
        let c = built(vec![ke]);
        let k = row(&c, "knowledge-engine");
        assert!(!k.mismatch && k.status == "ok", "{k:?}");
        assert_eq!(k.budget, "codex-core plan, stops at 95%");
    }

    #[test]
    fn unlinked_keys_are_rows_with_their_models_and_a_blocked_off_key_is_not_red() {
        let c = built(vec![conf(
            "claude-acct",
            "must",
            "claude",
            "subscription",
            "anthropic-native",
        )]);
        let g = row(&c, "glm-pilot");
        assert_eq!((g.status.as_str(), g.level), ("blocked", "ok"));
        assert_eq!(g.runs_on, "gateway glm-5.3");
        assert_eq!(g.fallback, "none");
        assert_eq!(row(&c, "claude-reserve").who.as_deref(), Some("cl --lazer"));
        let s = row(&c, "claude-acct");
        assert_eq!(
            (s.budget.as_str(), s.spent.as_str()),
            ("Claude accounts", "in Burn")
        );
        assert!(c
            .pools
            .iter()
            .any(|p| p.contains("lazer-pool $228/$50.00 AT CAP")));
        assert!(c
            .pools
            .iter()
            .any(|p| p.contains("codex-core Codex plan, stops at 95%")));
        assert_eq!(
            c.routes,
            "aliases: fast -> gpt-oss-120b; fallbacks: gpt-oss-120b -> gemini-flash"
        );
    }

    #[test]
    fn a_stale_or_missing_snapshot_is_amber_and_the_runners_still_show() {
        let mut s = snap();
        s.at = NOW - STALE_SECS - 60;
        let r = Read {
            snapshot: Some(s),
            confs: vec![],
            errors: vec![],
        };
        let c = build(&r, &Burn::default(), NOW, "", "");
        assert_eq!(c.level, "warn");
        assert!(c
            .stale
            .as_deref()
            .unwrap()
            .starts_with("stale: the gateway snapshot is 2h old"));
        let r = Read {
            snapshot: None,
            confs: vec![gateway_conf("v", "rbw:litellm_comms_triage_key")],
            errors: vec!["no gateway snapshot".into()],
        };
        let c = build(&r, &Burn::default(), NOW, "", "");
        assert_eq!(c.level, "warn");
        assert_eq!(row(&c, "v").fallback, "?");
    }

    #[test]
    fn a_conf_with_no_priority_or_an_invalid_one_is_no_row_and_priority_sorts_must_first() {
        let mut none = conf("x", "low", "claude", "subscription", "anthropic-native");
        none.priority = None;
        let bad = Conf {
            name: "y".into(),
            invalid: true,
            priority: Some("must".into()),
            ..Conf::default()
        };
        let c = built(vec![none, bad]);
        assert!(!c
            .rows
            .iter()
            .any(|r| r.consumer == "x" || r.consumer == "y"));
        let r = Read {
            snapshot: Some(snap()),
            ..Read::default()
        };
        let asc = build(&r, &Burn::default(), NOW, "priority", "asc");
        assert_eq!(asc.rows[0].priority, "off");
        let desc = build(&r, &Burn::default(), NOW, "priority", "desc");
        assert_eq!(desc.rows[0].priority, "must");
    }
}
