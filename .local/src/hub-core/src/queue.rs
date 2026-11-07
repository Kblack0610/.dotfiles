//! The agent queue as `agent-queue` lists it, for agent-web's Queue tab, the hub TUI's and the
//! session actions. agent-queue is the store's only reader and writer (design:
//! `~/.config/agentctl/QUEUE.md`), so this module never opens `~/.agent/queue`: it runs
//! `agent-queue list --json` and `agent-queue stats --json` through a `Runner` and types what
//! they print. Cancel and bump are argv for agent-queue too. `candidates` types the ranked board
//! rows `fleet-dispatch suggest --json` prints, for the tabs' Candidates section.

use std::collections::BTreeMap;

use agent_panel::account::GATEWAY;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::session_actions::Runner;
use crate::text::{cap, headline, TITLE_MAX};

pub const PRIORITIES: [&str; 3] = ["urgent", "high", "low"];

/// The harness of an item, or a session, that names none.
pub const HARNESS_DEFAULT: &str = "claude";

/// The harness of a session on the Lazer gateway (`agent_panel::account::GATEWAY`) whose item
/// names no other: claude-lazer's launcher sets `ANTHROPIC_BASE_URL`.
pub const HARNESS_GATEWAY: &str = "claude-lazer";

/// The harness a session ran on, for every reader (Sessions rows, the Costs cuts): what its item
/// or outcomes row says, where empty or blank is claude (rows written before #1125 carry none),
/// except that a session on the gateway account that says claude, or nothing, ran claude-lazer.
pub fn harness_of(said: &str, account: &str) -> String {
    match said.trim() {
        "" | HARNESS_DEFAULT if account == GATEWAY => HARNESS_GATEWAY,
        "" => HARNESS_DEFAULT,
        h => h,
    }
    .to_string()
}

/// The store's states, in the order every surface shows them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Waiting,
    Running,
    #[default]
    Queued,
    Done,
}

/// The old section ids (`#queue/running`, `hub --tab "queue running"`) and the state chip each
/// one opens the table on, so a link made before the table still lands on that view.
pub const SECTION_ALIASES: [(&str, &str); 4] = [
    ("waiting", "needs you"),
    ("running", "running"),
    ("queued", "up next"),
    ("done", "done"),
];

/// The state chip an old section id opens, or None for any other word.
pub fn section_chip(section: &str) -> Option<&'static str> {
    let s = section.trim().to_ascii_lowercase();
    SECTION_ALIASES
        .iter()
        .find(|(old, _)| *old == s)
        .map(|(_, chip)| *chip)
}

/// How many table rows a view draws before "+N older"; the chips still count every row.
pub const TABLE_OPEN_ROWS: usize = 200;

/// One item: its header keys as agent-queue prints them, plus `state`, `task` and, for a
/// queued item that cannot start yet, `hold`. A key this does not name is kept in `extra`, so
/// a caller that hands the item on as JSON loses nothing agent-queue said.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub slug: String,
    pub state: State,
    /// What the item is, in a few words: the `title:` header when it has one, else `parse` fills
    /// it from the task (`title()`), so every view shows the same words.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub title: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub mode: String,
    /// Space-separated, as the store writes them; `tag_list` splits them.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tags: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    /// `human`, `shepherd` or `board:<project>:<key>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// `<project>:<id>`: the board row this item works, the ledger's one link to the backlog.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
    /// `<server>:<tmux session>`, or a bare tmux session on agent-queue's server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    /// The `@N` window a hand-started item runs in, on the session's server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
    /// `ok`, `failed` or `cancelled`, once done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Why a queued item cannot start yet: `after <slug>`, `night (...)`, `at:HH:MM`, `pr:<owner>/<repo>#<N> not merged`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished: Option<String>,
    #[serde(default)]
    pub task: String,
    /// The `type` of a `type(area): title` task (feat, fix, chore), the Queue table's KIND.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<String>,
    /// The Claude account (or a gateway harness's) it ran on, written at start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    /// The model alias it ran on, written at start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// `s`, `m` or `l`: the task's `#size/` tag, which `fleet-dispatch start` writes as `size:`.
    /// None for an item added by hand or started before it did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    /// `heavy` or `light`: the run units it holds; agent-queue derives one when the item has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weight: Option<String>,
    /// When it moved to `waiting/`, the human's turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting: Option<String>,
    /// The merge commit `agent-land` proved, beside `pr`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merged: Option<String>,
    /// When it could first start: queued, or its `after:` item's finish when later; None while
    /// that still holds it (agent-queue's one rule, the one `stats` medians its wait by).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<String>,
    /// Dollars the nightly outcomes pass summed over its sessions; a header is text, so this
    /// reads text or a number and drops junk rather than the item.
    #[serde(
        default,
        deserialize_with = "lenient_num",
        skip_serializing_if = "Option::is_none"
    )]
    pub cost_usd: Option<f64>,
    /// Dollars the gateway metered, for a gateway harness; wins over `cost_usd`.
    #[serde(
        default,
        deserialize_with = "lenient_num",
        skip_serializing_if = "Option::is_none"
    )]
    pub gateway_cost_usd: Option<f64>,
    /// Working minutes over its sessions, from the same pass.
    #[serde(
        default,
        deserialize_with = "lenient_num",
        skip_serializing_if = "Option::is_none"
    )]
    pub work_min: Option<f64>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// A number from a header: agent-queue prints every header as text, a test or an older reader a
/// number; anything that is neither is None, so one bad header never drops its item.
fn lenient_num<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Number(n) => n.as_f64(),
        Value::String(t) => t.trim().parse().ok(),
        _ => None,
    })
}

/// A header's text, trimmed, or None when it is blank.
fn said(v: &Option<String>) -> Option<&str> {
    v.as_deref().map(str::trim).filter(|v| !v.is_empty())
}

/// One of the ledger's UTC stamps (`2026-11-03T10:00:00Z`, or an older `2026-11-03T10:00`).
fn stamp(s: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(s.trim())
        .map(|t| t.with_timezone(&chrono::Utc))
        .or_else(|_| {
            chrono::NaiveDateTime::parse_from_str(s.trim(), "%Y-%m-%dT%H:%M").map(|t| t.and_utc())
        })
        .ok()
}

/// How long an item took at each stage, in whole minutes, from its stamps and an injected `now`
/// (the one place a view's durations come from). None where the item has not reached the stage.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Timing {
    /// In its current state: queued since `queued`, running since `started`, waiting since
    /// `waiting`; None once done.
    pub in_state: Option<i64>,
    /// From ready to started: the time it could have run and did not.
    pub wait: Option<i64>,
    /// From started to finished, or to now while it runs; a waiting item's run stops at `waiting`.
    pub run: Option<i64>,
    /// From queued to finished, or to now while it is active.
    pub lead: Option<i64>,
}

/// One stage of an item's life as the detail view lists it.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Step {
    /// queued, ready, started, waiting, finished or merged.
    pub step: &'static str,
    /// The stamp as the ledger wrote it; None for `merged`, which records a commit.
    pub at: Option<String>,
    /// Minutes since the step before that had a readable stamp.
    pub gap_min: Option<i64>,
    /// The merge commit, on `merged` only.
    pub sha: Option<String>,
}

impl Item {
    pub fn tag_list(&self) -> impl Iterator<Item = &str> {
        self.tags.split_whitespace()
    }

    /// The item's stages in order, each with the minutes since the one before it: queued, ready,
    /// started, waiting, finished, then `merged` (the ledger keeps a sha, so no time or gap).
    /// A stage the item has not reached is left out. The one reader of this for both surfaces.
    pub fn timeline(&self) -> Vec<Step> {
        let mut out = vec![];
        let mut prev: Option<chrono::DateTime<chrono::Utc>> = None;
        for (step, v) in [
            ("queued", &self.queued),
            ("ready", &self.ready),
            ("started", &self.started),
            ("waiting", &self.waiting),
            ("finished", &self.finished),
        ] {
            let Some(at) = said(v) else { continue };
            let when = stamp(at);
            let gap_min = prev.zip(when).map(|(p, w)| (w - p).num_minutes().max(0));
            out.push(Step {
                step,
                at: Some(at.to_string()),
                gap_min,
                sha: None,
            });
            prev = when.or(prev);
        }
        if let Some(sha) = said(&self.merged) {
            out.push(Step {
                step: "merged",
                at: None,
                gap_min: None,
                sha: Some(sha.to_string()),
            });
        }
        out
    }

    /// What the item is in a few words: the `title:` header, else the task's first sentence
    /// with each file path shortened to its name; either one capped at `TITLE_MAX` chars.
    pub fn title(&self) -> String {
        if self.title.trim().is_empty() {
            headline(&self.task).0
        } else {
            cap(self.title.trim(), TITLE_MAX)
        }
    }

    /// The stage times at `now` (see [`Timing`]). A stamp before the one it is measured from
    /// (a clock step, a re-run predecessor) counts 0, never a negative span.
    pub fn timing(&self, now: chrono::DateTime<chrono::Utc>) -> Timing {
        let at = |v: &Option<String>| said(v).and_then(stamp);
        type At = Option<chrono::DateTime<chrono::Utc>>;
        let mins = |a: At, b: At| Some((b? - a?).num_minutes().max(0));
        let (queued, started, finished) = (at(&self.queued), at(&self.started), at(&self.finished));
        let waiting = at(&self.waiting);
        let done = self.state == State::Done;
        let end = if done { finished } else { Some(now) };
        Timing {
            in_state: match self.state {
                State::Done => None,
                State::Queued => mins(queued, Some(now)),
                State::Running => mins(started, Some(now)),
                State::Waiting => mins(waiting.or(started), Some(now)),
            },
            wait: mins(at(&self.ready).or(queued), started),
            run: match self.state {
                State::Waiting => mins(started, waiting.filter(|w| Some(*w) >= started).or(end)),
                _ => mins(started, end),
            },
            lead: mins(queued, end),
        }
    }

    fn extra_str(&self, key: &str) -> Option<&str> {
        self.extra
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
    }

    /// The harness the item runs on: its `agent` (claude, claude-lazer, lazer-reserve, opencode,
    /// codex), else claude, the rule `agentctl-session-outcomes` stamps a session's harness by.
    pub fn harness(&self) -> &str {
        self.extra_str("agent").unwrap_or(HARNESS_DEFAULT)
    }

    /// The harness and, when the item names one, its model alias: `codex sol`, `opencode glm`.
    pub fn harness_label(&self) -> String {
        match said(&self.model) {
            Some(m) => format!("{} {m}", self.harness()),
            None => self.harness().to_string(),
        }
    }

    /// What the item cost, in dollars: the metered gateway cost when it has one, else the
    /// nightly outcomes pass's `cost_usd`. None for an item neither priced: a ledger `0` is
    /// "no session row had a cost" (the pass sums a missing cost as 0), never a claim of free.
    pub fn cost(&self) -> Option<f64> {
        [self.gateway_cost_usd, self.cost_usd]
            .into_iter()
            .flatten()
            .find(|c| *c > 0.0)
    }

    /// The PR as `agent-land` records it (`owner/repo#N`; older items carry a bare number or a
    /// URL): the label a row prints and the page it links to, when the ledger names the repo.
    pub fn pr_link(&self) -> Option<(String, Option<String>)> {
        let pr = self.pr.as_deref()?.trim();
        if pr.is_empty() {
            return None;
        }
        if pr.starts_with("https://") || pr.starts_with("http://") {
            let n = pr.trim_end_matches('/').rsplit('/').next().unwrap_or(pr);
            return Some((format!("#{n}"), Some(pr.into())));
        }
        match pr.split_once('#') {
            Some((repo, n))
                if !repo.is_empty() && !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) =>
            {
                let short = repo.rsplit('/').next().unwrap_or(repo);
                Some((
                    format!("{short}#{n}"),
                    Some(format!("https://github.com/{repo}/pull/{n}")),
                ))
            }
            _ => Some((format!("#{}", pr.trim_start_matches('#')), None)),
        }
    }

    /// A done row's PR in words, the same on both surfaces: `PR r#7 merged`, or `merge not
    /// recorded` when `agent-land` wrote no merge commit beside it.
    pub fn pr_words(&self) -> Option<String> {
        let (label, _) = self.pr_link()?;
        let merge = if self.merged() {
            "merged"
        } else {
            "merge not recorded"
        };
        Some(format!("PR {label} {merge}"))
    }

    /// Whether the ledger recorded the merge: `agent-land` writes `merged` (the merge commit)
    /// beside `pr`, so a PR without it is one nobody proved landed.
    pub fn merged(&self) -> bool {
        said(&self.merged).is_some()
    }

    /// A finished `ok` item that shows nothing for its work: no PR and no `report` (the url or
    /// path of what it made instead of one). A canary item opens no PR by design.
    pub fn unproven(&self) -> bool {
        self.state == State::Done
            && self.status.as_deref().unwrap_or("ok") == "ok"
            && self.pr_link().is_none()
            && self.extra_str("report").is_none()
            && self.from.as_deref() != Some("canary")
    }

    /// The priority one step up (`up`) or down, or None at the end of the scale or for a
    /// priority agent-queue does not know.
    pub fn bumped(&self, up: bool) -> Option<&'static str> {
        let i = PRIORITIES.iter().position(|p| *p == self.priority)?;
        let j = if up { i.checked_sub(1)? } else { i + 1 };
        PRIORITIES.get(j).copied()
    }
}

/// One group of `stats.by_project` or `stats.by_source`: the done items in it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Outcomes {
    pub done: u64,
    pub ok: u64,
    pub failed: u64,
    pub cancelled: u64,
    pub prs: u64,
    pub wait_minutes_median: Option<i64>,
    pub to_pr_minutes_median: Option<i64>,
}

/// A queued item that could start now, and how long it has sat.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Waiter {
    pub slug: String,
    pub project: String,
    pub minutes: i64,
}

/// `stats.sitting`: what is queued right now, runnable or held, and how long it has sat.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Sitting {
    pub queued: u64,
    pub runnable: u64,
    pub held: u64,
    /// Held items by the first word of their hold: after, pr, night, at.
    pub held_by: BTreeMap<String, u64>,
    pub runnable_age_minutes_median: Option<i64>,
    /// The three runnable items that have sat longest, oldest first.
    pub oldest_runnable: Vec<Waiter>,
}

/// `agent-queue stats --json`: active counts and what sits now, and the items finished since `since`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Stats {
    pub since: String,
    pub active: BTreeMap<String, u64>,
    /// Done items by status.
    pub done: BTreeMap<String, u64>,
    /// Queued to started, over the items that waited; `started_at_once` counts the rest.
    pub wait_minutes_median: Option<i64>,
    pub wait_minutes_p90: Option<i64>,
    pub started_at_once: u64,
    pub run_minutes_median: Option<i64>,
    pub to_pr_minutes_median: Option<i64>,
    /// None from an agent-queue older than the field, so a view says nothing rather than "empty".
    pub sitting: Option<Sitting>,
    /// Items added per day (inflow); `per_day` is items finished per day.
    pub added_per_day: BTreeMap<String, u64>,
    pub per_day: BTreeMap<String, u64>,
    pub by_project: BTreeMap<String, Outcomes>,
    pub by_source: BTreeMap<String, Outcomes>,
    pub done_by_tag: BTreeMap<String, u64>,
    /// What moved in the last 1, 6 and 24 hours; None from an agent-queue older than the field.
    pub recent: Option<Recent>,
}

/// `stats.recent`: items added (by `queued`), started, done and failed (by `finished`) in the
/// last 1, 6 and 24 hours, and the ok items done since local midnight. Added against done over a
/// window is the drain: whether the queue shrinks or grows.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Recent {
    pub added_1h: u64,
    pub started_1h: u64,
    pub done_1h: u64,
    pub failed_1h: u64,
    pub added_6h: u64,
    pub started_6h: u64,
    pub done_6h: u64,
    pub failed_6h: u64,
    pub added_24h: u64,
    pub started_24h: u64,
    pub done_24h: u64,
    pub failed_24h: u64,
    pub done_today: u64,
}

/// Minutes as the views print them: `-` for none, hours from two hours up.
pub(crate) fn dur(m: Option<i64>) -> String {
    match m {
        None => "-".into(),
        Some(m) if m >= 120 => format!("{}h", m / 60),
        Some(m) => format!("{m}m"),
    }
}

impl Stats {
    /// The window's line: what finished, with a PR, and how long items waited to start.
    pub fn week(&self) -> String {
        let n = |k: &str| self.done.get(k).copied().unwrap_or(0);
        let done: u64 = self.done.values().sum();
        let prs: u64 = self.by_project.values().map(|o| o.prs).sum();
        format!(
            "since {}: {done} done ({} ok, {} failed, {} cancelled), {prs} with a PR, wait median {} p90 {} ({} started at once), to PR median {}",
            self.since,
            n("ok"),
            n("failed"),
            n("cancelled"),
            dur(self.wait_minutes_median),
            dur(self.wait_minutes_p90),
            self.started_at_once,
            dur(self.to_pr_minutes_median)
        )
    }

    /// What sits in the queue now, in plain words: how many could start and the oldest of them,
    /// then what holds the rest. The item slug comes after the point.
    pub fn sitting_line(&self) -> Option<String> {
        let s = self.sitting.as_ref()?;
        if s.queued == 0 {
            return Some("Queue: nothing waiting.".into());
        }
        let mut out = match (s.runnable, s.oldest_runnable.first()) {
            (0, _) => "Queue: nothing can start now.".to_string(),
            (n, Some(o)) => format!(
                "Queue: {n} can start now, the oldest waiting {} ({}), median {}.",
                dur(Some(o.minutes)),
                o.slug,
                dur(s.runnable_age_minutes_median)
            ),
            (n, None) => format!("Queue: {n} can start now."),
        };
        if s.held > 0 {
            let by: Vec<String> = s
                .held_by
                .iter()
                .map(|(k, v)| format!("{v} {}", hold_reason(k)))
                .collect();
            out += &format!(" {} held", s.held);
            if !by.is_empty() {
                out += &format!(": {}", by.join(", "));
            }
            out += ".";
        }
        Some(out)
    }
}

/// Why a queued item is held, from the first word of its `hold` (agent-queue `hold_for`).
fn hold_reason(kind: &str) -> String {
    match kind {
        "after" => "after another item".into(),
        "night" => "until night".into(),
        "at" => "until a set time".into(),
        "pr" => "until a PR merges".into(),
        k => format!("held by {k}"),
    }
}

/// Dollars as the Queue shows them: cents under $100, whole dollars above.
pub fn money(c: f64) -> String {
    if c >= 100.0 {
        format!("${c:.0}")
    } else {
        format!("${c:.2}")
    }
}

/// One day's finished items: how many, how many failed, and the dollars of those priced.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DayTotal {
    pub done: usize,
    pub failed: usize,
    pub cost: f64,
    /// Items that ran but have no cost, left out of `cost`, so a total never reads as complete when it is not.
    pub unpriced: usize,
}

impl DayTotal {
    pub fn of<'a>(items: impl IntoIterator<Item = &'a Item>) -> DayTotal {
        let mut t = DayTotal::default();
        for i in items {
            t.done += 1;
            t.failed += usize::from(i.status.as_deref() == Some("failed"));
            match i.cost() {
                Some(c) => t.cost += c,
                // A cancelled item never ran, so it has no price to miss.
                None if i.status.as_deref() != Some("cancelled") => t.unpriced += 1,
                None => {}
            }
        }
        t
    }

    /// What follows the count: `2 failed, $214, 3 unpriced`, each only when it applies.
    pub fn detail(&self) -> String {
        let mut out = Vec::new();
        if self.failed > 0 {
            out.push(format!("{} failed", self.failed));
        }
        if self.cost > 0.0 {
            out.push(money(self.cost));
        }
        if self.unpriced > 0 {
            out.push(format!("{} unpriced", self.unpriced));
        }
        out.join(", ")
    }

    /// `31 done, 2 failed, $214, 3 unpriced`.
    pub fn line(&self) -> String {
        match self.detail() {
            d if d.is_empty() => format!("{} done", self.done),
            d => format!("{} done, {d}", self.done),
        }
    }
}

/// The local date (`YYYY-MM-DD`) of one of the ledger's UTC stamps, the day an item counts on.
pub fn day_of(at: &str) -> Option<String> {
    Some(
        stamp(at)?
            .with_timezone(&chrono::Local)
            .format("%Y-%m-%d")
            .to_string(),
    )
}

/// A day (`YYYY-MM-DD`) as the Queue headings word it, by the same clock `day_of` uses: Today,
/// Yesterday, else `Thu 6 Nov`.
pub fn day_label(day: &str) -> String {
    let today = chrono::Local::now().date_naive();
    let Ok(d) = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d") else {
        return day.into();
    };
    if d == today {
        "Today".into()
    } else if Some(d) == today.pred_opt() {
        "Yesterday".into()
    } else {
        d.format("%a %-d %b").to_string()
    }
}

/// Each day's finished items totalled, by the day they finished. An item with no readable
/// `finished` counts on no day.
pub fn done_days(items: &[Item]) -> BTreeMap<String, DayTotal> {
    let mut by: BTreeMap<String, Vec<&Item>> = BTreeMap::new();
    for i in items.iter().filter(|i| i.state == State::Done) {
        if let Some(d) = i.finished.as_deref().and_then(day_of) {
            by.entry(d).or_default().push(i);
        }
    }
    by.into_iter().map(|(d, v)| (d, DayTotal::of(v))).collect()
}

fn argv(args: &[&str]) -> Vec<String> {
    std::iter::once("agent-queue")
        .chain(args.iter().copied())
        .map(String::from)
        .collect()
}

/// `agent-queue list --json` prints one object per line; a line that does not parse is skipped.
pub fn parse(jsonl: &str) -> Vec<Item> {
    jsonl
        .lines()
        .filter_map(|l| serde_json::from_str::<Item>(l).ok())
        .map(|mut i| {
            i.title = i.title();
            i
        })
        .collect()
}

/// One item by its slug, whatever its state.
pub fn show(runner: &dyn Runner, slug: &str) -> Result<Item, String> {
    parse(&runner.run(&argv(&["show", slug, "--json"]))?)
        .pop()
        .ok_or_else(|| format!("{slug}: agent-queue show printed no item"))
}

/// The items in `state` (`active`, `all`, or one state), in agent-queue's order: priority, then
/// queued time. `all` is every active item plus today's finished ones.
pub fn list(runner: &dyn Runner, state: &str) -> Result<Vec<Item>, String> {
    runner
        .run(&argv(&["list", "--json", "--state", state]))
        .map(|out| parse(&out))
}

/// The items in `state` with the done ones finished on `since` (`YYYY-MM-DD`) or later.
pub fn list_since(runner: &dyn Runner, state: &str, since: &str) -> Result<Vec<Item>, String> {
    if since.len() != 10 || !since.chars().all(|c| c.is_ascii_digit() || c == '-') {
        return Err(format!("bad date: {since}"));
    }
    runner
        .run(&argv(&[
            "list", "--json", "--state", state, "--since", since,
        ]))
        .map(|out| parse(&out))
}

/// The local date `days` before today, as `list_since` takes it.
pub fn days_ago(days: i64) -> String {
    (chrono::Local::now().date_naive() - chrono::Days::new(days.max(0) as u64))
        .format("%Y-%m-%d")
        .to_string()
}

pub fn stats(runner: &dyn Runner) -> Result<Stats, String> {
    let out = runner.run(&argv(&["stats", "--json"]))?;
    serde_json::from_str(&out).map_err(|e| format!("agent-queue stats: {e}"))
}

/// What a Queue view shows: the items (`all`), the week's stats, and what could not be read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Queue {
    pub items: Vec<Item>,
    pub stats: Option<Stats>,
    pub errors: Vec<String>,
}

impl Queue {
    pub fn read(runner: &dyn Runner) -> Queue {
        let mut q = Queue::default();
        match list(runner, "all") {
            Ok(items) => q.items = items,
            Err(e) => q.errors.push(format!("agent-queue list: {e}")),
        }
        match stats(runner) {
            Ok(s) => q.stats = Some(s),
            Err(e) => q.errors.push(e),
        }
        q
    }

    pub fn in_state(&self, s: State) -> impl Iterator<Item = &Item> {
        self.items.iter().filter(move |i| i.state == s)
    }

    pub fn count(&self, s: State) -> usize {
        self.in_state(s).count()
    }

    /// `1 running, 1 ready, 1 held`: the phone widget's queue line. Ready is queued with no hold.
    pub fn counts_line(&self) -> String {
        let held = self
            .in_state(State::Queued)
            .filter(|i| i.hold.is_some())
            .count();
        let ready = self.count(State::Queued) - held;
        let mut s = format!("{} running, {ready} ready", self.count(State::Running));
        if held > 0 {
            s += &format!(", {held} held");
        }
        s
    }
}

/// One Queue table row: an item and its stage times at the `now` the view was read at, so the
/// table filters, sorts and draws one set of numbers (P1's `table::Row`; there is no
/// queue-only filter).
#[derive(Clone, Copy, Debug)]
pub struct QueueRow<'a> {
    pub item: &'a Item,
    pub timing: Timing,
}

impl Queue {
    /// Every item as a table row, timed at `now`, in the table's own order: what needs the human,
    /// then running by the longest run, then the queued that could start (agent-queue's order),
    /// then the held, then done, the newest finish first.
    pub fn rows(&self, now: chrono::DateTime<chrono::Utc>) -> Vec<QueueRow<'_>> {
        let mut rows: Vec<QueueRow<'_>> = self
            .items
            .iter()
            .map(|item| QueueRow {
                item,
                timing: item.timing(now),
            })
            .collect();
        rows.sort_by(|a, b| a.rank().cmp(&b.rank()).then_with(|| a.within(b)));
        rows
    }
}

impl QueueRow<'_> {
    /// Where the row sits in the table's own order.
    fn rank(&self) -> u8 {
        match (self.item.state, self.item.hold.is_some()) {
            (State::Waiting, _) => 0,
            (State::Running, _) => 1,
            (State::Queued, false) => 2,
            (State::Queued, true) => 3,
            (State::Done, _) => 4,
        }
    }

    /// The order inside one rank; equal rows keep agent-queue's order (the sort is stable).
    fn within(&self, o: &QueueRow<'_>) -> std::cmp::Ordering {
        use std::cmp::Ordering::Equal;
        match self.item.state {
            State::Waiting => o.timing.in_state.cmp(&self.timing.in_state),
            State::Running => o.timing.run.cmp(&self.timing.run),
            State::Done => {
                // Newest finish first; a stamp that does not parse sorts last.
                let at = |r: &QueueRow<'_>| r.item.finished.as_deref().and_then(stamp);
                match (at(o), at(self)) {
                    (Some(a), Some(b)) => a.cmp(&b),
                    (Some(_), None) => std::cmp::Ordering::Greater,
                    (None, Some(_)) => std::cmp::Ordering::Less,
                    (None, None) => Equal,
                }
            }
            State::Queued => Equal,
        }
    }
}

impl crate::table::Row for QueueRow<'_> {
    const COLUMNS: &'static [&'static str] = &[
        "state", "in", "wait", "run", "project", "kind", "size", "acct", "pr", "title",
    ];
    /// `all` first, because the first chip keeps every row; then the states in the order the
    /// Queue sections list them.
    const STATES: &'static [&'static str] = &["all", "needs you", "running", "up next", "done"];
    const FACETS: &'static [&'static str] = &["project", "kind", "size", "acct"];

    fn val(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        let text = |s: Option<&str>| s.map_or(Val::None, |s| Val::Text(s.to_string()));
        let num = |m: Option<i64>| m.map_or(Val::None, |m| Val::Num(m as f64));
        let i = self.item;
        match col {
            "state" => Val::Text(
                match i.state {
                    State::Waiting => "needs",
                    State::Running => "running",
                    State::Queued => "queued",
                    State::Done => "done",
                }
                .into(),
            ),
            "in" => num(self.timing.in_state),
            "wait" => num(self.timing.wait),
            "run" => num(self.timing.run),
            "project" => text(Some(i.project.trim()).filter(|p| !p.is_empty())),
            "kind" => text(said(&i.kind)),
            "size" => text(said(&i.size)),
            "acct" => text(said(&i.account)),
            "pr" => text(said(&i.pr)),
            "title" => Val::Text(i.title()),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        let want = match s {
            "needs you" => State::Waiting,
            "running" => State::Running,
            "up next" => State::Queued,
            "done" => State::Done,
            _ => return false,
        };
        self.item.state == want
    }

    /// A bare word also finds the slug, the tags and the task the title was cut from.
    fn text(&self) -> String {
        let i = self.item;
        [i.title.as_str(), &i.slug, &i.project, &i.tags, &i.task]
            .join("\n")
            .to_lowercase()
    }
}

/// How many candidates a view lists; its heading counts them all.
pub const CANDIDATES_SHOWN: usize = 30;

/// One open board row `fleet-dispatch suggest --json` ranks: what the Queue tab's Candidates
/// section shows. fleet-dispatch ranks it and nothing stores it; this only types it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    pub profile: String,
    pub project: String,
    /// `agent` or `human`.
    pub lane: String,
    /// The row's id (`ucp-408`), or its text when it has none.
    pub key: String,
    /// The board line as it stands, what a promote passes back.
    pub text: String,
    pub stage: String,
    pub priority: String,
    /// Why it ranks where it does, e.g. "focus project, due today, #high, beta".
    pub why: String,
    /// A dispatch worker takes it.
    pub auto: bool,
    /// The judge's cached verdict, or `unjudged`.
    pub verdict: String,
    /// An active queue item holds its area.
    pub held: bool,
    pub area: String,
    /// Row priority as fleet-dispatch ranks it: 0 is `#urgent`, 3 is `#low`.
    pub prio: Option<u8>,
    /// Each reason no worker would start it, as fleet-dispatch words it ("no worker covers
    /// trader", "judge: skip, <reason>"); empty when one would.
    pub blocked: Vec<String>,
    /// No worker covers it and its repo has a commit in the last day: a gap in cover.
    pub active: bool,
}

impl Candidate {
    /// The row's words: no checkbox, no `#tags`, no trailing `<!-- -->` comment, capped.
    pub fn title(&self) -> String {
        let t = self.text.trim_start();
        let t = t.strip_prefix("- [").and_then(|r| r.get(2..)).unwrap_or(t);
        let t = t.split("<!--").next().unwrap_or(t);
        let words: Vec<&str> = t
            .split_whitespace()
            .filter(|w| !w.starts_with('#'))
            .collect();
        cap(&words.join(" "), TITLE_MAX)
    }

    /// Each blocked reason as a chip names it: the judge's own reason cut off, so every skip
    /// is one chip.
    pub fn reasons(&self) -> Vec<String> {
        self.blocked
            .iter()
            .map(|b| b.split(", ").next().unwrap_or(b).to_string())
            .collect()
    }

    /// The why, then what blocks it: the WHY cell of both views.
    pub fn why_line(&self) -> String {
        if self.blocked.is_empty() {
            self.why.clone()
        } else {
            format!("{}; blocked: {}", self.why, self.blocked.join("; "))
        }
    }

    /// How it would start: auto or man, the judge's verdict once it has one, and held.
    pub fn start_label(&self) -> String {
        let mut l = vec![if self.auto { "auto" } else { "man" }];
        if !self.verdict.is_empty() && self.verdict != "unjudged" {
            l.push(&self.verdict);
        }
        if self.held {
            l.push("held");
        }
        l.join(" ")
    }

    /// The board write that starts it: `fleet-dispatch promote`, the Projects tab's Start.
    pub fn start(&self) -> crate::tasks::Write {
        crate::tasks::Write {
            profile: self.profile.clone(),
            project: self.project.clone(),
            lane: self.lane.clone(),
            verb: crate::tasks::Verb::Start {
                raw: self.text.clone(),
            },
        }
    }
}

/// What a view shows of the ranked list: every row counted, the first `CANDIDATES_SHOWN` kept,
/// and every blocked reason counted over all of them.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Candidates {
    pub total: usize,
    pub auto: usize,
    pub rows: Vec<Candidate>,
    /// Rows past the first `CANDIDATES_SHOWN`, in rank order, kept so each reason chip lists up
    /// to `CANDIDATES_SHOWN` of its own.
    pub blocked_rows: Vec<Candidate>,
    /// Rows nothing blocks: a worker takes each and no judge, size or held area stops it.
    pub clear: usize,
    /// Each chip reason (`Candidate::reasons`) and how many rows it blocks, most first.
    pub reasons: Vec<(String, usize)>,
    /// `#urgent` rows something blocks: a view opens its Candidates by itself while any are.
    pub urgent_blocked: usize,
    /// Projects worked on in the last day that have a row no worker covers, sorted.
    pub uncovered: Vec<String>,
}

impl Candidates {
    pub fn more(&self) -> usize {
        self.total - self.rows.len()
    }
}

/// A row no worker covers: what `uncovered` counts.
fn uncovered_reason(r: &str) -> bool {
    r.starts_with("no worker covers ") || r.starts_with("night only: ")
}

/// `fleet-dispatch suggest --json` prints one object per line, in rank order, and nothing when
/// there is no row; a line that does not parse is skipped.
pub fn parse_candidates(jsonl: &str) -> Candidates {
    let mut c = Candidates::default();
    let mut by: Vec<(String, usize)> = Vec::new();
    for row in jsonl
        .lines()
        .filter_map(|l| serde_json::from_str::<Candidate>(l).ok())
    {
        c.total += 1;
        c.auto += usize::from(row.auto);
        let reasons = row.reasons();
        c.clear += usize::from(reasons.is_empty());
        if !reasons.is_empty() && row.prio == Some(0) {
            c.urgent_blocked += 1;
        }
        if row.active
            && row.blocked.iter().any(|r| uncovered_reason(r))
            && !c.uncovered.contains(&row.project)
        {
            c.uncovered.push(row.project.clone());
        }
        let mut wanted = false;
        for r in &reasons {
            match by.iter_mut().find(|(k, _)| k == r) {
                Some((_, n)) => {
                    wanted |= *n < CANDIDATES_SHOWN;
                    *n += 1;
                }
                None => {
                    wanted = true;
                    by.push((r.clone(), 1));
                }
            }
        }
        if c.rows.len() < CANDIDATES_SHOWN {
            c.rows.push(row);
        } else if wanted {
            c.blocked_rows.push(row);
        }
    }
    by.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    c.reasons = by;
    c.uncovered.sort();
    c
}

/// The ranked candidates. Slow (it reads every board), so a view reads it off its draw loop.
pub fn candidates(runner: &dyn Runner) -> Result<Candidates, String> {
    let argv: Vec<String> = ["fleet-dispatch", "suggest", "--json"]
        .into_iter()
        .map(String::from)
        .collect();
    runner.run(&argv).map(|out| parse_candidates(&out))
}

/// A slug or a project name as agent-queue writes it, so nothing else reaches its argv.
pub fn is_slug(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// `agent-queue cancel <slug>`: a running item's session is killed with it. Its output, or why
/// it was refused.
pub fn cancel(runner: &dyn Runner, slug: &str) -> Result<String, String> {
    if !is_slug(slug) {
        return Err("bad slug".into());
    }
    runner.run(&argv(&["cancel", slug]))
}

/// `agent-queue bump <slug> <priority>`.
pub fn bump(runner: &dyn Runner, slug: &str, priority: &str) -> Result<String, String> {
    if !is_slug(slug) {
        return Err("bad slug".into());
    }
    if !PRIORITIES.contains(&priority) {
        return Err("priority is urgent, high or low".into());
    }
    runner.run(&argv(&["bump", slug, priority]))
}

/// The modes `agent-queue add` takes.
pub const MODES: [&str; 2] = ["oneshot", "plan"];

/// A task to queue from the human (agent-web's Add and both Homes' "Queue a fix"): an empty
/// mode or priority is a high oneshot.
#[derive(Clone, Debug, Default, serde::Deserialize)]
pub struct Add {
    pub project: String,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub tags: String,
    pub task: String,
}

/// Tags are free words plus `at:HH:MM`; agent-queue checks the time, this only keeps them words.
fn is_tags(s: &str) -> bool {
    s.split([' ', ',']).filter(|t| !t.is_empty()).all(|t| {
        !t.starts_with('-')
            && t.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
    })
}

/// The argv for `agent-queue add`, or why the task is refused. The task goes after `--`, so
/// nothing in it reaches agent-queue as an option.
pub fn add_argv(a: &Add) -> Result<Vec<String>, &'static str> {
    let mode = if a.mode.is_empty() {
        "oneshot"
    } else {
        &a.mode
    };
    let priority = if a.priority.is_empty() {
        "high"
    } else {
        &a.priority
    };
    if !is_slug(&a.project) {
        return Err("pick a project");
    }
    if !MODES.contains(&mode) {
        return Err("mode is oneshot or plan");
    }
    if !PRIORITIES.contains(&priority) {
        return Err("priority is urgent, high or low");
    }
    if !is_tags(&a.tags) {
        return Err("tags are words, or at:HH:MM");
    }
    let task = a.task.trim();
    if task.is_empty() {
        return Err("type the task");
    }
    let mut args = argv(&["add", "--from", "human", "--project", &a.project]);
    args.extend(["--mode", mode, "--priority", priority].map(String::from));
    if !a.tags.trim().is_empty() {
        args.extend(["--tags".into(), a.tags.trim().into()]);
    }
    args.extend(["--".into(), task.into()]);
    Ok(args)
}

/// `agent-queue add`: what it printed (the new slug), or why it was refused.
pub fn add(runner: &dyn Runner, a: &Add) -> Result<String, String> {
    runner.run(&add_argv(a)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Serves canned output per verb and records every argv.
    #[derive(Default)]
    struct Fake {
        list: Option<&'static str>,
        stats: Option<&'static str>,
        calls: RefCell<Vec<String>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            let out = match argv.get(1).map(String::as_str) {
                Some("list") => self.list,
                Some("stats") => self.stats,
                _ => Some(""),
            };
            out.map(String::from)
                .ok_or_else(|| "agent-queue: no".into())
        }
    }

    const LIST: &str = concat!(
        r#"{"slug":"w","project":"game","mode":"plan","priority":"high","from":"human","agent":"claude","queued":"2026-11-03T10:00:00Z","session":"lab:game-agent-2","state":"waiting","file":"/q/waiting/w.md","task":"Pick a side\nthen more"}"#,
        "\n",
        "not json\n",
        r#"{"slug":"q","project":"dotfiles","mode":"oneshot","priority":"high","tags":"night at:02:30","after":"w","queued":"2026-11-03T11:00:00Z","state":"queued","task":"later","hold":"after w"}"#,
        "\n",
        r#"{"slug":"nostate","task":"x"}"#,
        "\n",
        r#"{"slug":"d","project":"game","priority":"low","state":"done","status":"cancelled","finished":"2026-11-03T12:00:00Z","pr":"812","task":"t"}"#,
        "\n",
    );

    fn add_of(project: &str, mode: &str, priority: &str, tags: &str, task: &str) -> Add {
        Add {
            project: project.into(),
            mode: mode.into(),
            priority: priority.into(),
            tags: tags.into(),
            task: task.into(),
        }
    }

    #[test]
    fn add_defaults_to_a_high_oneshot_from_the_human_with_the_task_after_dashes() {
        let args = add_argv(&add_of("dotfiles", "", "", "", " --slug x\n")).unwrap();
        assert_eq!(
            args.join(" "),
            "agent-queue add --from human --project dotfiles --mode oneshot --priority high -- --slug x"
        );
        let args = add_argv(&add_of("dotfiles", "plan", "high", "night at:02:30", "x")).unwrap();
        assert_eq!(
            args[args.len() - 4..],
            ["--tags", "night at:02:30", "--", "x"]
        );
        let fake = Fake::default();
        add(&fake, &add_of("dotfiles", "", "", "", "do it")).unwrap();
        assert!(fake.calls.borrow()[0].ends_with("-- do it"));
    }

    #[test]
    fn a_slug_is_one_word() {
        assert!(is_slug("20261103-fix-the-menu"));
        assert!(!is_slug("-rf"));
        assert!(!is_slug("a b"));
        assert!(!is_slug("../x"));
        assert!(!is_slug(""));
    }

    #[test]
    fn add_refuses_what_would_reach_argv_as_an_option() {
        assert!(add_argv(&add_of("--slug", "", "", "", "x")).is_err());
        assert!(add_argv(&add_of("", "", "", "", "x")).is_err());
        assert!(add_argv(&add_of("dotfiles", "wave", "", "", "x")).is_err());
        assert!(add_argv(&add_of("dotfiles", "", "now", "", "x")).is_err());
        assert!(add_argv(&add_of("dotfiles", "", "", "--after x", "x")).is_err());
        assert!(add_argv(&add_of("dotfiles", "", "", "a;b", "x")).is_err());
        assert!(add_argv(&add_of("dotfiles", "", "", "", "  \n")).is_err());
        let fake = Fake::default();
        assert!(add(&fake, &add_of("", "", "", "", "x")).is_err());
        assert!(
            fake.calls.borrow().is_empty(),
            "a refused task runs nothing"
        );
    }

    #[test]
    fn list_types_each_item_and_skips_a_line_that_is_not_one() {
        let fake = Fake {
            list: Some(LIST),
            ..Fake::default()
        };
        let items = list(&fake, "all").unwrap();
        assert_eq!(
            fake.calls.borrow()[0],
            "agent-queue list --json --state all"
        );
        let slugs: Vec<&str> = items.iter().map(|i| i.slug.as_str()).collect();
        assert_eq!(slugs, ["w", "q", "d"], "no state is not an item");
        let (w, q, d) = (&items[0], &items[1], &items[2]);
        assert_eq!(w.state, State::Waiting);
        assert_eq!(w.session.as_deref(), Some("lab:game-agent-2"));
        assert_eq!(w.title(), "Pick a side");
        assert_eq!(q.tag_list().collect::<Vec<_>>(), ["night", "at:02:30"]);
        assert_eq!(q.hold.as_deref(), Some("after w"));
        assert_eq!(d.status.as_deref(), Some("cancelled"));
        assert_eq!(d.pr.as_deref(), Some("812"));
    }

    #[test]
    fn the_harness_is_the_items_agent_else_claude_with_its_model_alias() {
        let item = |kv: &[(&str, &str)]| Item {
            model: kv
                .iter()
                .find(|(k, _)| *k == "model")
                .map(|(_, v)| v.to_string()),
            extra: kv
                .iter()
                .filter(|(k, _)| *k != "model")
                .map(|(k, v)| (k.to_string(), Value::from(*v)))
                .collect(),
            ..Item::default()
        };
        assert_eq!(
            item(&[]).harness(),
            "claude",
            "an item naming no agent ran claude"
        );
        assert_eq!(item(&[("agent", " ")]).harness_label(), "claude");
        assert_eq!(
            item(&[("agent", "codex"), ("model", "sol")]).harness_label(),
            "codex sol"
        );
        let lazer = item(&[("agent", "claude-lazer"), ("model", "")]);
        assert_eq!(
            (lazer.harness(), lazer.harness_label().as_str()),
            ("claude-lazer", "claude-lazer"),
            "an empty model adds nothing"
        );
    }

    #[test]
    fn a_title_is_the_header_or_the_tasks_first_sentence_with_paths_as_names() {
        let item = |title: &str, task: &str| Item {
            title: title.into(),
            task: task.into(),
            ..Item::default()
        };
        assert_eq!(item("Fix the page", "long task").title(), "Fix the page");
        assert_eq!(
            item(
                "",
                "\nDodginBalls epic, P4 (game: verified join). The plan is /a/b.md: read it."
            )
            .title(),
            "DodginBalls epic, P4 (game: verified join)"
        );
        assert_eq!(
            item(
                "",
                "Phase 4 of the plan /home/k/.agent/plans/x/rewards-admin.md: Game. Read it"
            )
            .title(),
            "Phase 4 of the plan rewards-admin: Game"
        );
        assert_eq!(item("", "is ~/x/y.sh ok? yes").title(), "is y ok?");
        let long = item(&"word ".repeat(40), "").title();
        assert!(
            long.ends_with("word...") && long.chars().count() <= TITLE_MAX + 3,
            "{long}"
        );
        let parsed = parse(r#"{"slug":"s","state":"queued","title":"From the header","task":"x"}"#);
        assert_eq!(parsed[0].title, "From the header");
    }

    #[test]
    fn list_since_passes_a_date_and_refuses_anything_else() {
        let fake = Fake {
            list: Some(LIST),
            ..Fake::default()
        };
        assert_eq!(list_since(&fake, "all", "2026-10-30").unwrap().len(), 3);
        assert_eq!(
            fake.calls.borrow()[0],
            "agent-queue list --json --state all --since 2026-10-30"
        );
        assert!(list_since(&fake, "all", "--state").is_err());
        assert_eq!(days_ago(0).len(), 10);
    }

    #[test]
    fn an_item_hands_on_every_key_agent_queue_printed() {
        let items = parse(LIST);
        let back = serde_json::to_value(&items[0]).unwrap();
        let mut orig: Value = serde_json::from_str(LIST.lines().next().unwrap()).unwrap();
        orig["title"] = "Pick a side".into();
        assert_eq!(
            back, orig,
            "agent and file ride in extra; parse adds the title"
        );
        let q = serde_json::to_value(&items[1]).unwrap();
        assert_eq!(
            q["tags"], "night at:02:30",
            "tags stay one string for the page"
        );
        assert!(
            q.get("session").is_none(),
            "an absent key is not written as null"
        );
    }

    #[test]
    fn read_keeps_what_it_could_and_says_what_it_could_not() {
        let fake = Fake {
            list: Some(LIST),
            stats: Some(
                r#"{"since":"2026-10-27","active":{"queued":1},"done":{"ok":3},"wait_minutes_median":12,"wait_minutes_p90":130,"started_at_once":4,"run_minutes_median":null,"to_pr_minutes_median":95,"sitting":{"queued":3,"runnable":1,"held":2,"held_by":{"after":1,"pr":1},"runnable_age_minutes_median":200,"oldest_runnable":[{"slug":"q1","project":"game","minutes":200}]},"added_per_day":{"2026-11-03":4},"per_day":{"2026-11-03":3},"by_project":{"game":{"done":3,"ok":3,"failed":0,"cancelled":0,"prs":2,"wait_minutes_median":12,"to_pr_minutes_median":95}},"by_source":{},"done_by_tag":{}}"#,
            ),
            ..Fake::default()
        };
        let q = Queue::read(&fake);
        assert!(q.errors.is_empty(), "{:?}", q.errors);
        assert_eq!(q.count(State::Queued), 1);
        let s = q.stats.unwrap();
        assert_eq!(s.to_pr_minutes_median, Some(95));
        assert_eq!(s.run_minutes_median, None);
        assert_eq!(s.by_project["game"].prs, 2);
        assert_eq!(
            s.week(),
            "since 2026-10-27: 3 done (3 ok, 0 failed, 0 cancelled), 2 with a PR, wait median 12m p90 2h (4 started at once), to PR median 95m"
        );
        assert_eq!(
            s.sitting_line().as_deref(),
            Some("Queue: 1 can start now, the oldest waiting 3h (q1), median 3h. 2 held: 1 after another item, 1 until a PR merges.")
        );
        assert_eq!(
            Stats::default().sitting_line(),
            None,
            "an older agent-queue without `sitting` says nothing, never that the queue is empty"
        );
        let held: Stats = serde_json::from_str(
            r#"{"sitting":{"queued":13,"runnable":0,"held":13,"held_by":{"after":12,"vacation":1},"runnable_age_minutes_median":null,"oldest_runnable":[]}}"#,
        )
        .unwrap();
        assert_eq!(
            held.sitting_line().as_deref(),
            Some(
                "Queue: nothing can start now. 13 held: 12 after another item, 1 held by vacation."
            ),
            "nothing runnable says so plainly, and a hold kind it does not know still reads"
        );

        let q = Queue::read(&Fake::default());
        assert!(q.items.is_empty() && q.stats.is_none());
        assert_eq!(q.errors.len(), 2, "{:?}", q.errors);
    }

    #[test]
    fn cancel_and_bump_are_agent_queue_argv_and_refuse_an_option() {
        let fake = Fake::default();
        cancel(&fake, "w").unwrap();
        bump(&fake, "q", "urgent").unwrap();
        assert!(cancel(&fake, "--all").is_err());
        assert!(cancel(&fake, "a b").is_err());
        assert!(bump(&fake, "q", "now").is_err());
        assert_eq!(
            *fake.calls.borrow(),
            ["agent-queue cancel w", "agent-queue bump q urgent"]
        );
    }

    const SUGGEST: &str = concat!(
        r##"{"profile":"bnb","project":"shape-city","stage":"beta","lane":"agent","key":"bar-17","text":"- [ ] fix the jump arc #high #size/s <!-- id:bar-17 -->","repo":"/r","prio":1,"priority":"high","tier":2,"line":"f508","worker":"requested","wrank":0,"pprio":0,"due":0,"due_in":0,"age":5,"why":"focus project, due today, #high, beta","auto":true,"area":"","verdict":"dispatch","held":false}"##,
        "\n",
        "not json\n",
        r##"{"profile":"personal","project":"trader","stage":"alpha","lane":"human","key":"backtest report","text":"- [ ] backtest report","why":"#high, alpha, 9d old","auto":false,"verdict":"unjudged","held":true,"area":"unity"}"##,
        "\n",
    );

    #[test]
    fn candidates_type_suggest_lines_in_rank_order() {
        struct Out(&'static str, RefCell<Vec<String>>);
        impl Runner for Out {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                self.1.borrow_mut().push(argv.join(" "));
                Ok(self.0.into())
            }
        }
        let r = Out(SUGGEST, RefCell::default());
        let c = candidates(&r).unwrap();
        assert_eq!(r.1.borrow()[0], "fleet-dispatch suggest --json");
        assert_eq!((c.total, c.auto, c.more()), (2, 1, 0));
        let c = c.rows;
        let keys: Vec<&str> = c.iter().map(|c| c.key.as_str()).collect();
        assert_eq!(keys, ["bar-17", "backtest report"], "a bad line is skipped");
        assert!(c[1].lane == "human");
        assert_eq!(c[0].title(), "fix the jump arc");
        assert_eq!(c[1].title(), "backtest report");
        assert_eq!(c[0].start_label(), "auto dispatch");
        assert_eq!(c[1].start_label(), "man held", "unjudged is not shown");
        assert_eq!(
            candidates(&Out("", RefCell::default())).unwrap(),
            Candidates::default(),
            "no rows prints nothing"
        );
    }

    #[test]
    fn candidates_count_each_blocked_reason_over_every_row_and_keep_rows_for_each_chip() {
        let row = |key: &str, prio: u8, blocked: &str, active: bool, project: &str| {
            let b: Vec<&str> = blocked.split('|').filter(|s| !s.is_empty()).collect();
            serde_json::json!({"key": key, "project": project, "prio": prio, "blocked": b,
                "active": active, "why": "alpha"})
            .to_string()
        };
        let mut lines: Vec<String> = (0..CANDIDATES_SHOWN)
            .map(|i| row(&format!("top-{i}"), 2, "", false, "game"))
            .collect();
        lines.push(row("skip-a", 2, "judge: skip, too vague", false, "game"));
        lines.push(row(
            "skip-b",
            0,
            "judge: skip, a dupe|size/l: too big for a pick",
            false,
            "game",
        ));
        lines.push(row(
            "gap",
            2,
            "night only: no day worker covers ar",
            true,
            "ar",
        ));
        lines.push(row(
            "gap-old",
            2,
            "no worker covers trader",
            false,
            "trader",
        ));
        lines.push(row("taken", 0, "", false, "game"));
        let c = parse_candidates(&lines.join("\n"));
        assert_eq!(
            (c.total, c.rows.len()),
            (CANDIDATES_SHOWN + 5, CANDIDATES_SHOWN)
        );
        let kept: Vec<&str> = c.blocked_rows.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(
            kept,
            ["skip-a", "skip-b", "gap", "gap-old"],
            "an unblocked row past the cap is not kept"
        );
        assert_eq!(
            c.reasons[0],
            ("judge: skip".to_string(), 2),
            "a judge's reason is one chip"
        );
        assert_eq!(c.reasons.len(), 4);
        assert_eq!(
            c.urgent_blocked, 1,
            "an urgent row a worker takes is not counted"
        );
        assert_eq!(
            c.uncovered,
            ["ar"],
            "a gap with no commit in a day is not a gap in cover"
        );
        assert_eq!(
            c.blocked_rows[1].why_line(),
            "alpha; blocked: judge: skip, a dupe; size/l: too big for a pick"
        );
        assert_eq!(c.rows[0].why_line(), "alpha");
    }

    #[test]
    fn a_reason_chip_keeps_at_most_the_shown_count_past_the_top() {
        let line = r#"{"key":"k","blocked":["tier 3: past the unattended ceiling"]}"#;
        let c = parse_candidates(&vec![line; 3 * CANDIDATES_SHOWN].join("\n"));
        assert_eq!(c.rows.len() + c.blocked_rows.len(), CANDIDATES_SHOWN);
        assert_eq!(
            c.reasons,
            [(
                "tier 3: past the unattended ceiling".to_string(),
                3 * CANDIDATES_SHOWN
            )]
        );
        assert_eq!(c.urgent_blocked, 0, "a row with no prio is not urgent");
    }

    #[test]
    fn candidates_count_every_row_and_keep_the_first_shown() {
        let line = r#"{"key":"k","auto":true}"#;
        let c = parse_candidates(&vec![line; CANDIDATES_SHOWN + 8].join("\n"));
        assert_eq!((c.total, c.auto, c.rows.len()), (38, 38, CANDIDATES_SHOWN));
        assert_eq!(c.more(), 8);
    }

    #[test]
    fn a_candidate_starts_through_the_boards_start() {
        let c = parse_candidates(SUGGEST).rows;
        assert_eq!(
            crate::tasks::argv(&c[0].start()).unwrap(),
            [
                "fleet-dispatch",
                "promote",
                "--project",
                "shape-city",
                "--profile",
                "bnb",
                "--agent",
                "--raw",
                "- [ ] fix the jump arc #high #size/s <!-- id:bar-17 -->"
            ]
        );
        // NEGATIVE CONTROL: a human-lane row is promoted without --agent.
        let human = crate::tasks::argv(&c[1].start()).unwrap();
        assert!(!human.contains(&"--agent".to_string()), "{human:?}");
        assert_eq!(
            human.last().map(String::as_str),
            Some("- [ ] backtest report")
        );
    }

    #[test]
    fn a_done_item_shows_its_pr_its_cost_and_whether_anything_proves_it() {
        let item = |j: &str| parse(j).remove(0);
        let landed = item(
            r#"{"slug":"a","state":"done","status":"ok","pr":"Kblack0610/.dotfiles#1225","merged":"abc","cost_usd":"6.1","task":"t"}"#,
        );
        assert_eq!(
            landed.pr_link(),
            Some((
                ".dotfiles#1225".into(),
                Some("https://github.com/Kblack0610/.dotfiles/pull/1225".into())
            ))
        );
        assert!(landed.merged() && !landed.unproven());
        assert_eq!(landed.cost(), Some(6.1));
        // An older item carries a bare number: a label, no link, and no merge recorded.
        let bare = item(r#"{"slug":"b","state":"done","status":"ok","pr":"1796","task":"t"}"#);
        assert_eq!(bare.pr_link(), Some(("#1796".into(), None)));
        assert!(!bare.merged() && !bare.unproven());
        assert_eq!(bare.pr_words().unwrap(), "PR #1796 merge not recorded");
        assert_eq!(landed.pr_words().unwrap(), "PR .dotfiles#1225 merged");
        // Nothing odd reaches a link: no number is a bare label, a slash is trimmed.
        let odd = |pr: &str| {
            item(&format!(
                r#"{{"slug":"x","state":"done","pr":"{pr}","task":"t"}}"#
            ))
            .pr_link()
        };
        assert_eq!(odd("o/r#"), Some(("#o/r#".into(), None)));
        assert_eq!(
            odd("https://h/o/r/pull/7/"),
            Some(("#7".into(), Some("https://h/o/r/pull/7/".into())))
        );
        assert_eq!(
            odd("javascript:alert(1)"),
            Some(("#javascript:alert(1)".into(), None))
        );
        // No PR and no report is flagged; a report, a canary or a failure is not.
        let flagged = item(r#"{"slug":"c","state":"done","status":"ok","task":"t"}"#);
        assert!(flagged.unproven());
        let reported =
            item(r#"{"slug":"c","state":"done","status":"ok","report":"https://x/y","task":"t"}"#);
        assert!(!reported.unproven());
        let canary =
            item(r#"{"slug":"c","state":"done","status":"ok","from":"canary","task":"t"}"#);
        assert!(!canary.unproven());
        assert!(!item(r#"{"slug":"d","state":"done","status":"failed","task":"t"}"#).unproven());
        assert!(!item(r#"{"slug":"e","state":"running","task":"t"}"#).unproven());
    }

    #[test]
    fn a_cost_of_zero_or_none_is_unknown_and_a_gateway_cost_wins() {
        let item = |j: &str| parse(j).remove(0);
        assert_eq!(
            item(r#"{"slug":"a","state":"done","cost_usd":"0","task":"t"}"#).cost(),
            None
        );
        assert_eq!(
            item(r#"{"slug":"a","state":"done","task":"t"}"#).cost(),
            None
        );
        assert_eq!(
            item(r#"{"slug":"a","state":"done","cost_usd":"junk","task":"t"}"#).cost(),
            None
        );
        assert_eq!(
            item(r#"{"slug":"a","state":"done","cost_usd":2.5,"task":"t"}"#).cost(),
            Some(2.5)
        );
        assert_eq!(
            item(r#"{"slug":"a","state":"done","cost_usd":"2.5","gateway_cost_usd":"9.1","task":"t"}"#).cost(),
            Some(9.1)
        );
        assert_eq!(money(6.1), "$6.10");
        assert_eq!(money(214.4), "$214");
    }

    #[test]
    fn a_day_totals_what_finished_what_failed_and_what_is_priced() {
        let items = parse(concat!(
            r#"{"slug":"a","state":"done","status":"ok","cost_usd":"6.10","task":"t"}"#,
            "\n",
            r#"{"slug":"b","state":"done","status":"failed","cost_usd":"3.02","task":"t"}"#,
            "\n",
            r#"{"slug":"c","state":"done","status":"ok","cost_usd":"0","task":"t"}"#,
            "\n",
        ));
        let t = DayTotal::of(&items);
        assert_eq!((t.done, t.failed, t.unpriced), (3, 1, 1));
        assert!((t.cost - 9.12).abs() < 1e-9);
        assert_eq!(t.line(), "3 done, 1 failed, $9.12, 1 unpriced");
        assert_eq!(
            DayTotal::of(&items[..0]).line(),
            "0 done",
            "no cost is never $0"
        );
    }

    #[test]
    fn done_days_total_each_local_day_by_when_the_item_finished() {
        let items = parse(concat!(
            r#"{"slug":"a","state":"done","status":"ok","cost_usd":"1","finished":"2026-11-06T12:00:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"b","state":"done","status":"failed","cost_usd":"2","finished":"2026-11-06T12:30:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"c","state":"done","status":"ok","cost_usd":"4","finished":"2026-11-04T12:00:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"d","state":"done","status":"ok","cost_usd":"8","task":"t"}"#,
            "\n",
            r#"{"slug":"e","state":"running","cost_usd":"16","task":"t"}"#,
            "\n",
        ));
        let days = done_days(&items);
        assert_eq!(
            days.len(),
            2,
            "no finished stamp, no day; a running item is no day's"
        );
        let d = &days[&day_of("2026-11-06T12:00:00Z").unwrap()];
        assert_eq!((d.done, d.failed, d.cost), (2, 1, 3.0));
        assert_eq!(day_of("not a time"), None);
        assert_eq!(day_label(&days_ago(0)), "Today");
        assert_eq!(day_label(&days_ago(1)), "Yesterday");
        assert_eq!(day_label("2026-11-04"), "Wed 4 Nov");
    }

    #[test]
    fn bump_steps_along_the_scale_and_stops_at_its_ends() {
        let mut i = Item {
            priority: "high".into(),
            ..Item::default()
        };
        assert_eq!(i.bumped(true), Some("urgent"));
        assert_eq!(i.bumped(false), Some("low"));
        i.priority = "urgent".into();
        assert_eq!(i.bumped(true), None);
        i.priority = "low".into();
        assert_eq!(i.bumped(false), None);
        i.priority = "asap".into();
        assert_eq!(i.bumped(true), None);
        // NEGATIVE CONTROL: normal is retired, so an old item carrying it does not step.
        i.priority = "normal".into();
        assert_eq!(i.bumped(true), None);
    }
    fn at(s: &str) -> chrono::DateTime<chrono::Utc> {
        stamp(s).unwrap()
    }

    fn timed(json: &str) -> Timing {
        parse(json)[0].timing(at("2026-11-06T12:00:00Z"))
    }

    #[test]
    fn timing_reads_each_stage_from_the_stamps_at_an_injected_now() {
        let none = Timing::default();
        assert_eq!(
            timed(
                r#"{"slug":"r","state":"running","queued":"2026-11-06T09:00:00Z","ready":"2026-11-06T10:00:00Z","started":"2026-11-06T10:30:00Z","task":"t"}"#
            ),
            Timing {
                in_state: Some(90),
                wait: Some(30),
                run: Some(90),
                lead: Some(180)
            },
            "running: wait from ready, not queued; run and lead to now"
        );
        assert_eq!(
            timed(r#"{"slug":"q","state":"queued","queued":"2026-11-06T11:15:00Z","task":"t"}"#),
            Timing {
                in_state: Some(45),
                lead: Some(45),
                ..none
            },
            "queued: no wait or run until it starts"
        );
        assert_eq!(
            timed(
                r#"{"slug":"d","state":"done","queued":"2026-11-06T08:00","started":"2026-11-06T08:20","finished":"2026-11-06T09:00","task":"t"}"#
            ),
            Timing {
                in_state: None,
                wait: Some(20),
                run: Some(40),
                lead: Some(60)
            },
            "done: spans end at finished, the older minute stamps read too"
        );
        assert_eq!(
            timed(
                r#"{"slug":"w","state":"waiting","queued":"2026-11-06T09:00:00Z","started":"2026-11-06T09:10:00Z","waiting":"2026-11-06T11:00:00Z","task":"t"}"#
            ),
            Timing {
                in_state: Some(60),
                wait: Some(10),
                run: Some(110),
                lead: Some(180)
            },
            "waiting: its run stops when it went to the human"
        );
        assert_eq!(
            timed(
                r#"{"slug":"c","state":"done","status":"cancelled","queued":"2026-11-06T09:00:00Z","finished":"2026-11-06T09:05:00Z","task":"t"}"#
            ),
            Timing {
                lead: Some(5),
                ..none
            },
            "a requeued then cancelled item with no started has no wait or run"
        );
        assert_eq!(
            timed(
                r#"{"slug":"s","state":"running","queued":"2026-11-06T12:30:00Z","started":"junk","task":"t"}"#
            ),
            Timing {
                lead: Some(0),
                ..none
            },
            "a stamp after now counts 0, never negative, and a bad one counts nothing"
        );
    }

    #[test]
    fn typed_headers_parse_from_the_ledgers_keys() {
        let i = &parse(
            r#"{"slug":"a","state":"running","type":"feat","area":"hub","account":"k2","model":"sol","size":"m","weight":"heavy","merged":"abc","ready":"2026-11-06T10:00:00Z","work_min":"42","cost_usd":"junk","other":"kept","task":"t"}"#,
        )[0];
        assert_eq!(
            (
                i.kind.as_deref(),
                i.area.as_deref(),
                i.account.as_deref(),
                i.size.as_deref()
            ),
            (Some("feat"), Some("hub"), Some("k2"), Some("m"))
        );
        assert_eq!(
            (i.work_min, i.cost_usd),
            (Some(42.0), None),
            "junk drops the field, not the item"
        );
        assert!(i.merged() && !i.extra.contains_key("type"));
        assert_eq!(i.extra.get("other"), Some(&Value::from("kept")));
        let back = serde_json::to_value(i).unwrap();
        assert_eq!(
            back["type"], "feat",
            "it serializes under the ledger's own key"
        );
    }

    #[test]
    fn stats_reads_recent_and_an_older_agent_queue_without_it() {
        let s: Stats = serde_json::from_str(
            r#"{"since":"2026-10-30","recent":{"added_6h":80,"done_6h":84,"failed_24h":5,"done_today":280}}"#,
        )
        .unwrap();
        let r = s.recent.unwrap();
        assert_eq!(
            (r.added_6h, r.done_6h, r.failed_24h, r.done_today),
            (80, 84, 5, 280)
        );
        let old: Stats = serde_json::from_str(r#"{"since":"2026-10-30"}"#).unwrap();
        assert_eq!(old.recent, None);
    }

    fn table() -> Queue {
        Queue {
            items: parse(concat!(
                r#"{"slug":"a","state":"running","project":"dotfiles","type":"fix","size":"s","account":"k1","started":"2026-11-06T11:00:00Z","task":"fix(hub): sort the queue"}"#,
                "\n",
                r#"{"slug":"b","state":"queued","project":"playground","type":"feat","queued":"2026-11-06T09:00:00Z","task":"feat(ci): nightly table"}"#,
                "\n",
                r#"{"slug":"c","state":"done","project":"dotfiles","type":"feat","size":"m","account":"k2","started":"2026-11-06T08:00:00Z","finished":"2026-11-06T10:00:00Z","task":"feat(hub): timing"}"#,
                "\n",
                r#"{"slug":"d","state":"waiting","project":"dotfiles","type":"fix","started":"2026-11-06T10:00:00Z","task":"fix(ask): pick one"}"#,
            )),
            ..Queue::default()
        }
    }

    #[test]
    fn the_queue_filters_sorts_and_counts_on_the_shared_table() {
        use crate::table::View;
        let q = table();
        let rows = q.rows(at("2026-11-06T12:00:00Z"));
        let slugs = |v: View| {
            v.apply(&rows)
                .iter()
                .map(|r| r.item.slug.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            slugs(View::new::<QueueRow>(
                "project:dotfiles kind:fix",
                "",
                "",
                ""
            )),
            ["d", "a"],
            "what needs the human comes first"
        );
        assert_eq!(
            slugs(View::new::<QueueRow>("-acct:k1 hub", "", "", "")),
            ["c"],
            "a bare word finds the task"
        );
        assert_eq!(
            slugs(View::new::<QueueRow>("", "", "run", "")),
            ["d", "c", "a", "b"],
            "run sorts biggest first (a tie keeps the table order), none last"
        );
        assert_eq!(slugs(View::new::<QueueRow>("", "up next", "", "")), ["b"]);
        let chips: Vec<(&str, usize)> = View::new::<QueueRow>("project:dotfiles", "", "", "")
            .states(&rows)
            .iter()
            .map(|c| (c.name, c.n))
            .collect();
        assert_eq!(
            chips,
            [
                ("all", 3),
                ("needs you", 1),
                ("running", 1),
                ("up next", 0),
                ("done", 1)
            ]
        );
        let kinds = View::new::<QueueRow>("project:dotfiles", "", "", "").facets(&rows);
        let kind = kinds.iter().find(|f| f.key == "kind").unwrap();
        let counts: Vec<(&str, usize)> = kind
            .values
            .iter()
            .map(|v| (v.value.as_str(), v.n))
            .collect();
        assert_eq!(counts, [("feat", 1), ("fix", 2)]);
    }
    #[test]
    fn the_table_opens_in_exceptions_first_order() {
        use crate::table::View;
        let q = Queue {
            items: parse(concat!(
                r#"{"slug":"held","state":"queued","hold":"after x","queued":"2026-11-06T01:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"old","state":"done","finished":"2026-11-05T10:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"q1","state":"queued","queued":"2026-11-06T08:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"short","state":"running","started":"2026-11-06T11:30:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"q2","state":"queued","queued":"2026-11-06T09:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"long","state":"running","started":"2026-11-06T09:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"new","state":"done","finished":"2026-11-06T11:00:00Z","task":"t"}"#,
                "\n",
                r#"{"slug":"need","state":"waiting","waiting":"2026-11-06T10:00:00Z","started":"2026-11-06T09:30:00Z","task":"t"}"#,
            )),
            ..Queue::default()
        };
        let rows = q.rows(at("2026-11-06T12:00:00Z"));
        let order: Vec<&str> = View::default()
            .apply(&rows)
            .iter()
            .map(|r| r.item.slug.as_str())
            .collect();
        assert_eq!(
            order,
            ["need", "long", "short", "q1", "q2", "held", "new", "old"],
            "needs you, longest run, ready queued as agent-queue ordered them, held, newest done"
        );
    }

    #[test]
    fn an_old_section_id_opens_its_state_chip() {
        assert_eq!(section_chip("Waiting"), Some("needs you"));
        assert_eq!(section_chip("queued"), Some("up next"));
        assert_eq!(section_chip("table"), None, "a live section is no alias");
        for (_, chip) in SECTION_ALIASES {
            assert!(<QueueRow as crate::table::Row>::STATES.contains(&chip));
        }
    }
    #[test]
    fn the_timeline_lists_each_stamp_with_minutes_since_the_one_before() {
        let items = parse(concat!(
            r#"{"slug":"a","state":"done","queued":"2026-11-06T09:00:00Z","ready":"2026-11-06T09:00:00Z","started":"2026-11-06T09:14:00Z","finished":"2026-11-06T10:00:00Z","merged":"abc123","task":"t"}"#,
            "\n",
            r#"{"slug":"b","state":"queued","task":"t"}"#,
        ));
        let t = items[0].timeline();
        let got: Vec<(&str, Option<i64>)> = t.iter().map(|s| (s.step, s.gap_min)).collect();
        assert_eq!(
            got,
            [
                ("queued", None),
                ("ready", Some(0)),
                ("started", Some(14)),
                ("finished", Some(46)),
                ("merged", None)
            ]
        );
        assert_eq!(t[4].sha.as_deref(), Some("abc123"));
        assert!(items[1].timeline().is_empty(), "no stamp, no step");
    }
}
