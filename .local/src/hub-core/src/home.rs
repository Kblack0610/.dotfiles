//! The Home tab for both surfaces: what needs the human, what is running
//! (with the session counts), the spend
//! line and the health chips. It joins what the other readers already read (fleet-sessions'
//! `state.json`, `queue::Queue`, `infra::Infra`, read by `gather`), and `build` reads nothing
//! itself, so it is pure and both surfaces get the same rows in the same order.
//!
//! One row per thing that waits: a session with a pending ask shows the ask, not the session as
//! well, and a queue item waiting on a session already shown adds nothing. Sessions are matched
//! by their tmux session name, the one name an ask, a queue item and a state row all carry.
//!
//! `needs` is the one ranking of that list: every surface, `hub needs --json`, the briefing's
//! Needs you, fleet-bench's asks digest and the needs pager read its order, and none re-sorts it. A row's `Score` is counted
//! from facts (who can act, what it holds, how long it waited, the row's own priority), never a
//! model's number.

use std::collections::HashSet;

use serde::Serialize;
use serde_json::Value;

use crate::boards;
use crate::fleet::ts;
use crate::infra::Infra;
use crate::proposals::Proposal;
use crate::queue::{Item, Queue, State};
use crate::tasks::{Feed, Row};

/// The health chips, in the order the strip shows them (the `cc:domain_status` domains).
pub const DOMAINS: [&str; 11] = [
    "k3s", "machines", "ci", "prod", "llm", "agents", "spend", "platform", "queue", "home", "other",
];
/// The row types only the human can do (notes-cli README, "The task row": `run decide check`).
/// A human-sheet row of another type is work an agent can take, so it never needs the human.
pub const HUMAN_TYPES: [&str; 3] = ["run", "decide", "check"];
/// The priorities a human-sheet row needs before it joins NEEDS YOU; a `#low` row waits on the sheet.
pub const SHEET_PRIORITIES: [&str; 2] = ["urgent", "high"];
/// The domains shown even when Prometheus has no status for them, so a missing one reads as no data.
pub(crate) const ALWAYS: [&str; 2] = ["k3s", "ci"];
/// How much of a question or reason a row keeps.
pub const TEXT_MAX: usize = 160;
/// How many rows of a list Home shows before the rest fold under "+N more" (dashboards rule: a
/// long list is capped, never unbounded at top level).
pub const SHOWN: usize = 8;

/// What a row is. A Stopped row leads the list; conditions (Budget to Red) list after every
/// scored row, in this order. A condition has no score, so the needs pager never pages it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A hold that has stopped every dispatch pass (`fleet-dispatch stopped`): how long, why and
    /// what clears it, in one line. A condition with no score, so the needs pager leaves it to
    /// the queue-starved watch.
    Stopped,
    /// A pending `agent-ask`, answered by its id.
    Ask,
    /// A session fleet-sessions buckets NEEDS with no ask: a dialog, a permission or a stop.
    Session,
    /// A queue item waiting with no session or ask shown for it.
    Queue,
    /// An open `#urgent` or `#high` row of a project's human sheet that only the human can do
    /// (`HUMAN_TYPES`), with no ask, session or queue item shown for it.
    Sheet,
    /// A runner stopped at its budget today (`signals::budget_stop`): it waits for a raise.
    Budget,
    /// A `night` queue item that finished failed.
    Night,
    /// A NEEDS YOU line of the home-k3s janitor (`signals::janitor`).
    Janitor,
    /// Critical mail, one row per sender and subject (`signals::mail`).
    Mail,
    /// A repo whose nightly on main is red.
    Nightly,
    /// An item of `cc:red_now`.
    Red,
}

/// What a row asks of the human, the one naming both surfaces filter and draw it by: the
/// serialized slug is what `kind:` matches and the label is its chip and KIND cell. A session
/// takes its open dialog's, read by `boards::state`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum NeedKind {
    Plan,
    Ask,
    Perm,
    Turn,
    Blocked,
    Todo,
    Red,
    Stopped,
}

impl NeedKind {
    /// In chip order.
    pub const ALL: [NeedKind; 8] = [
        NeedKind::Plan,
        NeedKind::Ask,
        NeedKind::Perm,
        NeedKind::Turn,
        NeedKind::Blocked,
        NeedKind::Todo,
        NeedKind::Red,
        NeedKind::Stopped,
    ];

    pub fn slug(self) -> &'static str {
        match self {
            NeedKind::Plan => "plan",
            NeedKind::Ask => "ask",
            NeedKind::Perm => "perm",
            NeedKind::Turn => "turn",
            NeedKind::Blocked => "blocked",
            NeedKind::Todo => "todo",
            NeedKind::Red => "red",
            NeedKind::Stopped => "stopped",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            NeedKind::Plan => "Plan to approve",
            NeedKind::Ask => "Question",
            NeedKind::Perm => "Permission",
            NeedKind::Turn => "Your turn",
            NeedKind::Blocked => "Blocked",
            NeedKind::Todo => "To do",
            NeedKind::Red => "Failing",
            NeedKind::Stopped => "Stopped",
        }
    }

    /// A condition row's: a budget stop waits on a raise, as a blocked item does; every other
    /// condition is a failure.
    fn of_condition(kind: Kind) -> NeedKind {
        match kind {
            Kind::Budget => NeedKind::Blocked,
            _ => NeedKind::Red,
        }
    }

    /// A session row's, from its open dialog (`transcript::Question::kind`); a session with
    /// no dialog, or only its last message, waits for its turn.
    fn of_dialog(dialog: &str) -> NeedKind {
        match dialog {
            "choice" => NeedKind::Ask,
            "tool" => NeedKind::Perm,
            "plan" => NeedKind::Plan,
            _ => NeedKind::Turn,
        }
    }
}

/// One row of NEEDS YOU.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Need {
    pub kind: Kind,
    /// What it asks of the human.
    pub need: NeedKind,
    /// Its place in `needs`' order, from 1, whatever a view does to the rows.
    pub rank: usize,
    pub project: String,
    pub text: String,
    /// What the row acts on: the ask id, the session's tmux target, the queue slug, the sheet
    /// row's id (its text when it has none), the repo or the red item.
    pub id: String,
    /// The tmux target (`server/session:window`) of the session behind the row, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// When it started waiting, unix seconds, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub since: Option<i64>,
    /// An ask's recommended option, when it has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recommend: Option<String>,
    /// What the row counted, for an ask, a session, a queue item or a sheet row; a condition
    /// (Stopped, Budget to Red) is not a wait, and has none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score: Option<Score>,
}

impl Need {
    /// Why it sits where it does: what it holds, or a sheet row's `#priority`.
    pub fn holds(&self) -> String {
        match &self.score {
            Some(s) if !s.holds.is_empty() => s.holds.clone(),
            Some(Score {
                priority: Some(p), ..
            }) => format!("#{p}"),
            _ => String::new(),
        }
    }
}

impl crate::table::Row for Need {
    const COLUMNS: &'static [&'static str] =
        &["rank", "kind", "project", "waited", "holds", "what"];
    const STATES: &'static [&'static str] = &[
        "all",
        "Plan to approve",
        "Question",
        "Permission",
        "Your turn",
        "Blocked",
        "To do",
        "Failing",
        "Stopped",
    ];
    const FACETS: &'static [&'static str] = &["project"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "what";
    const GLANCE: &'static [&'static str] = &["kind", "project", "waited"];

    fn val(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        let text = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "rank" => Val::Num(self.rank as f64),
            "kind" => text(self.need.slug()),
            "project" => text(&self.project),
            // Earlier is bigger, so a header's first click puts the longest wait on top.
            "waited" => self.since.map_or(Val::None, |s| Val::Num(-(s as f64))),
            "holds" => text(&self.holds()),
            "what" => text(&self.text),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.need.label() == s
    }

    /// A bare word searches what the row says, its kind as drawn and the id it acts on.
    fn text(&self) -> String {
        [
            self.need.label(),
            &self.project,
            &self.holds(),
            &self.text,
            &self.id,
        ]
        .join("\n")
        .to_lowercase()
    }
}

/// What a row of NEEDS YOU counted, so it says why it sits where it does (dashboards rule 6).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Score {
    /// Only the human can act. False only for an ask the judge said a machine could answer.
    pub human: bool,
    /// It holds a live session.
    pub session: bool,
    /// Plan phases left in that session.
    pub phases: u64,
    /// Queued items that start only after this one (their `after:`).
    pub dependents: u64,
    /// Minutes it has waited, by the state document's clock.
    pub age_min: i64,
    /// `(1 + session + phases + dependents) x age_min`: what a wait costs, the rank among rows
    /// with the same `human`.
    pub value: i64,
    /// What it holds, in words: "session, 3 phases, 2 queued", empty when nothing.
    pub holds: String,
    /// A sheet row's priority (`urgent` or `high`). A `high` row ranks after every live wait
    /// and `urgent` row with the same `human`; a live wait has none and ranks as `urgent`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
}

impl Score {
    pub fn new(human: bool, session: bool, phases: u64, dependents: u64, age_min: i64) -> Score {
        let mut words = Vec::new();
        if session {
            words.push("session".to_string());
        }
        if phases > 0 {
            words.push(format!(
                "{phases} phase{}",
                if phases == 1 { "" } else { "s" }
            ));
        }
        if dependents > 0 {
            words.push(format!("{dependents} queued"));
        }
        let holds = 1 + u64::from(session) + phases + dependents;
        Score {
            human,
            session,
            phases,
            dependents,
            age_min,
            value: i64::try_from(holds)
                .unwrap_or(i64::MAX)
                .saturating_mul(age_min),
            holds: words.join(", "),
            priority: None,
        }
    }

    /// A `high` sheet row, which ranks after the rows that block running work or are urgent.
    fn later(&self) -> bool {
        self.priority.as_deref() == Some("high")
    }
}

/// An ask the judge said a machine could answer (`take-recommend`, `answer:<text>`). A gate or
/// an approval is the human's whatever the verdict says; an error or no verdict is the human's.
fn machine_can_answer(kind: &str, judge: &str) -> bool {
    !matches!(kind, "gate" | "approval")
        && (judge == "take-recommend" || judge.starts_with("answer:"))
}

/// One running queue item, with its plan's progress when its session has a checklist.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Running {
    pub slug: String,
    pub title: String,
    pub project: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phases: Option<boards::Phases>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Warn,
    Red,
    Nodata,
}

impl Level {
    /// A `cc:*_status` value: 0 ok, 1 warn, 2 red, anything else or none is no data.
    pub fn of(v: Option<f64>) -> Level {
        match v.map(|v| v as i64) {
            Some(0) => Level::Ok,
            Some(1) => Level::Warn,
            Some(2) => Level::Red,
            _ => Level::Nodata,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Chip {
    pub name: String,
    pub level: Level,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Home {
    pub needs: Vec<Need>,
    /// What analysis streams propose, newest first, and their count worded once.
    pub proposals: Vec<Proposal>,
    pub proposals_head: String,
    pub proposals_failed: bool,
    /// No read has answered yet, so nothing can be said about what is open.
    pub proposals_unread: bool,
    pub running: Vec<Running>,
    /// Where work sits from inbox to done; `set_pipeline` adds the snapshot's half.
    pub flow: crate::flow::Strip,
    /// The session counts that head Running (`12 working, 2 need you, 2 stalled`); empty when
    /// fleet-sessions' state has no counts.
    pub sessions: String,
    /// What the fleet spent on Claude in 24h (`claude $573 in 24h`), the line that links to
    /// Costs; None when Prometheus did not answer (its error is in `errors`).
    pub spend: Option<String>,
    /// The fleet's front page, one row per question; None when Prometheus did not answer.
    pub vitals: Option<crate::vitals::Vitals>,
    pub health: Vec<Chip>,
    /// What could not be read, so a short list never reads as an all-clear.
    pub errors: Vec<String>,
    /// How many rows of each list show before the rest fold (`SHOWN`), sent so the web reads it.
    pub shown: usize,
}

impl Home {
    /// The chips that are not green: the strip shows only these, and one "all green" line when
    /// there are none (dashboards.md rule 4).
    pub fn exceptions(&self) -> impl Iterator<Item = &Chip> {
        self.health.iter().filter(|c| c.level != Level::Ok)
    }
}

/// The tmux session name in a target (`server/session:window`), a queue item's session
/// (`server:session` or bare) or an ask's (bare).
pub(crate) fn tmux_name(s: &str) -> &str {
    if let Some((_, rest)) = s.split_once('/') {
        return rest.rsplit_once(':').map_or(rest, |(n, _)| n);
    }
    s.split_once(':').map_or(s, |(_, n)| n)
}

/// The board row a queue item works, `<project>:<id>`: its ledger `row`, else its `from:
/// board:<project>:<id>`.
fn item_row(i: &Item) -> Option<&str> {
    i.row
        .as_deref()
        .or_else(|| i.from.as_deref().and_then(|f| f.strip_prefix("board:")))
}

/// Unix seconds at the local start of a `YYYY-MM-DD` day, a sheet row's `since`.
fn day_start(day: &str) -> Option<i64> {
    use chrono::TimeZone;
    let d = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()?;
    chrono::Local
        .from_local_datetime(&d.and_hms_opt(0, 0, 0)?)
        .earliest()
        .map(|t| t.timestamp())
}

/// A `night` queue item that finished failed: it ran unwatched, so its failure is the human's.
/// A failed night task needs the human for a day after it ends; after that the queue holds it.
pub const NIGHT_WINDOW_SECS: i64 = 86_400;

fn night_failed(i: &Item) -> bool {
    i.state == State::Done
        && i.status.as_deref() == Some("failed")
        && i.tag_list().any(|t| t == "night")
}

/// A human-sheet row that needs the human: open, `#urgent` or `#high`, of a `HUMAN_TYPES` type.
fn needs_the_human(r: &Row) -> bool {
    r.lane == "human"
        && r.state == "open"
        && SHEET_PRIORITIES.contains(&r.priority.as_str())
        && r.r#type
            .as_deref()
            .is_some_and(|t| HUMAN_TYPES.contains(&t))
}

pub(crate) fn str_of<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

/// The first line, whitespace squeezed, capped at `TEXT_MAX` chars.
fn short(s: &str) -> String {
    let line = s.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    let t = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.chars().count() <= TEXT_MAX {
        return t;
    }
    let cut: String = t.chars().take(TEXT_MAX - 3).collect();
    format!("{}...", cut.trim_end())
}

/// The tmux target of session `name` in `sessions`, when exactly one window carries it.
fn target_in(sessions: &[&Value], name: &str) -> Option<String> {
    let mut m = sessions
        .iter()
        .map(|s| str_of(s, "target"))
        .filter(|t| !t.is_empty() && tmux_name(t) == name);
    let first = m.next()?;
    // Two windows of one tmux session: the name alone cannot say which.
    m.next().is_none().then(|| first.to_string())
}

/// The running queue items, each with its session's plan progress when it has a checklist:
/// Home's running section and each Projects card's in-flight list.
pub fn running(state: &Value, q: &Queue) -> Vec<Running> {
    let sessions: Vec<&Value> = state["sessions"]
        .as_array()
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let phases = boards::phases(state);
    q.in_state(State::Running)
        .map(|i| {
            let target = i
                .session
                .as_deref()
                .and_then(|s| target_in(&sessions, tmux_name(s)));
            Running {
                slug: i.slug.clone(),
                title: i.title(),
                project: i.project.clone(),
                started: i.started.clone(),
                phases: target.as_ref().and_then(|t| phases.get(t).cloned()),
                target,
            }
        })
        .collect()
}

/// NEEDS YOU from fleet-sessions' `state.json` (null when missing), the queue, the board feed and
/// infra (None until read), ranked: the asks, sessions, queue items and `#urgent` sheet rows only
/// the human can act on by what their wait costs (`Score::value`), then the `#high` sheet rows
/// by the same value, then those the judge said a machine could answer, then the conditions:
/// budget stops, failed night items, janitor lines, critical mail, nightly reds and red-now items. A Stopped row, when dispatch is stopped, comes before all of them: while it
/// stands nothing else starts. Ages are by the state's own clock, so the order is pure.
pub fn needs(
    state: &Value,
    queue: Option<&Queue>,
    board: Option<&Feed>,
    infra: Option<&Infra>,
) -> Vec<Need> {
    let now = state["generated_epoch"].as_i64();
    let age_min = |since: Option<i64>| now.zip(since).map_or(0, |(n, s)| (n - s).max(0) / 60);
    let sessions: Vec<&Value> = state["sessions"]
        .as_array()
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let phases = boards::phases(state);
    let left = |target: Option<&String>| {
        target
            .and_then(|t| phases.get(t))
            .map_or(0, |p| p.total.saturating_sub(p.done))
    };
    let target_of = |name: &str| target_in(&sessions, name);
    let items: Vec<&Item> = queue.map(|q| q.items.iter().collect()).unwrap_or_default();
    let item_of = |name: &str| {
        items.iter().copied().find(|i| {
            matches!(i.state, State::Waiting | State::Running | State::Review)
                && i.session.as_deref().is_some_and(|s| tmux_name(s) == name)
        })
    };
    // Queued items whose `after:` names this one, whether or not another slug there holds them too:
    // what this item holds up (`agent-queue dependents` lists only the ones its close releases).
    let dependents = |slug: Option<&str>| {
        slug.map_or(0, |slug| {
            items
                .iter()
                .filter(|i| {
                    i.state == State::Queued
                        && i.after.as_deref().is_some_and(|a| a.split_whitespace().any(|s| s == slug))
                })
                .count() as u64
        })
    };
    let mut out = Vec::new();
    let mut shown: HashSet<String> = HashSet::new();
    // The board rows (`<project>:<id>`) an ask, session or queue row above already stands for.
    let mut worked: HashSet<String> = HashSet::new();
    fn work(worked: &mut HashSet<String>, i: Option<&Item>) {
        worked.extend(i.and_then(item_row).map(String::from));
    }

    for st in state["stopped"].as_array().into_iter().flatten() {
        out.push(Need {
            kind: Kind::Stopped,
            need: NeedKind::Stopped,
            rank: 0,
            project: String::new(),
            text: short(str_of(st, "line")),
            id: format!("stopped:{}", str_of(st, "runner")),
            target: None,
            since: st["since"].as_i64(),
            recommend: None,
            score: None,
        });
    }

    for a in state["asks"].as_array().into_iter().flatten() {
        let session = str_of(a, "session");
        if !session.is_empty() {
            shown.insert(session.to_string());
        }
        let target = (!session.is_empty()).then(|| target_of(session)).flatten();
        let since = ts(str_of(a, "created"));
        let recommend = str_of(a, "recommend");
        // An ask's `task` is its queue item's slug, which for an item promoted from the board
        // is the row's id.
        let task = str_of(a, "task");
        if !task.is_empty() {
            worked.insert(format!("{}:{task}", str_of(a, "project")));
        }
        work(
            &mut worked,
            items
                .iter()
                .copied()
                .find(|i| !task.is_empty() && i.slug == task),
        );
        work(&mut worked, item_of(session));
        out.push(Need {
            kind: Kind::Ask,
            need: NeedKind::Ask,
            rank: 0,
            project: str_of(a, "project").into(),
            text: short(str_of(a, "question")),
            id: str_of(a, "id").into(),
            score: Some(Score::new(
                !machine_can_answer(str_of(a, "kind"), str_of(a, "judge")),
                target.is_some(),
                left(target.as_ref()),
                dependents(item_of(session).map(|i| i.slug.as_str())),
                age_min(since),
            )),
            recommend: (!recommend.is_empty()).then(|| recommend.into()),
            target,
            since,
        });
    }
    for s in &sessions {
        let target = str_of(s, "target");
        let name = tmux_name(target);
        if str_of(s, "bucket") != "NEEDS" || shown.contains(name) {
            continue;
        }
        shown.insert(name.to_string());
        let item = item_of(name);
        work(&mut worked, item);
        let since = now.zip(s["idle_min"].as_i64()).map(|(g, m)| g - m * 60);
        out.push(Need {
            kind: Kind::Session,
            need: NeedKind::of_dialog(str_of(s, "dialog")),
            rank: 0,
            project: item.map_or_else(|| str_of(s, "project").to_string(), |i| i.project.clone()),
            text: short(&item.map_or_else(|| str_of(s, "reason").to_string(), |i| i.title())),
            id: target.into(),
            target: Some(target.into()),
            since,
            recommend: None,
            score: Some(Score::new(
                true,
                true,
                left(Some(&target.to_string())),
                dependents(item.map(|i| i.slug.as_str())),
                age_min(since),
            )),
        });
    }
    for i in items.iter().filter(|i| i.state == State::Waiting) {
        if i.session
            .as_deref()
            .is_some_and(|s| shown.contains(tmux_name(s)))
        {
            continue;
        }
        work(&mut worked, Some(i));
        let waited = i.waiting.as_deref();
        let target = i.session.as_deref().and_then(|s| target_of(tmux_name(s)));
        let since = waited.or(i.started.as_deref()).and_then(ts);
        out.push(Need {
            kind: Kind::Queue,
            need: NeedKind::Blocked,
            rank: 0,
            project: i.project.clone(),
            text: short(&i.title()),
            id: i.slug.clone(),
            score: Some(Score::new(
                true,
                target.is_some(),
                left(target.as_ref()),
                dependents(Some(&i.slug)),
                age_min(since),
            )),
            target,
            since,
            recommend: None,
        });
    }
    let rows = board.map_or(&[][..], |f| f.rows.as_slice());
    for r in rows.iter().filter(|r| needs_the_human(r)) {
        let project = r.project.clone().unwrap_or_default();
        if r.id
            .as_ref()
            .is_some_and(|id| worked.contains(&format!("{project}:{id}")))
        {
            continue;
        }
        let since = r.since.as_deref().and_then(day_start);
        let mut score = Score::new(true, false, 0, 0, age_min(since));
        score.priority = Some(r.priority.clone());
        out.push(Need {
            kind: Kind::Sheet,
            need: NeedKind::Todo,
            rank: 0,
            project,
            text: short(&r.text),
            id: r.id.clone().unwrap_or_else(|| short(&r.text)),
            target: None,
            since,
            recommend: None,
            score: Some(score),
        });
    }
    let condition = |kind, id: String, text: String, since| Need {
        kind,
        need: NeedKind::of_condition(kind),
        rank: 0,
        project: String::new(),
        text: short(&text),
        id,
        target: None,
        since,
        recommend: None,
        score: None,
    };
    for b in state["budget"].as_array().into_iter().flatten() {
        let runner = str_of(b, "runner");
        out.push(condition(
            Kind::Budget,
            format!("budget:{runner}"),
            format!(
                "{runner} stopped at its daily budget: {}. To go on today: agentctl budget {runner} raise <usd>.",
                str_of(b, "detail").trim_end_matches('.')
            ),
            b["at"].as_i64(),
        ));
    }
    let recent = |i: &Item| {
        let done = i.finished.as_deref().and_then(ts);
        now.zip(done)
            .is_none_or(|(n, d)| n - d <= NIGHT_WINDOW_SECS)
    };
    for i in items.iter().filter(|i| night_failed(i) && recent(i)) {
        out.push(Need {
            project: i.project.clone(),
            ..condition(
                Kind::Night,
                i.slug.clone(),
                format!(
                    "Night task {} failed: {}. Run agent-queue show {}.",
                    i.slug,
                    i.title(),
                    i.slug
                ),
                i.finished.as_deref().and_then(ts),
            )
        });
    }
    for j in state["janitor"].as_array().into_iter().flatten() {
        let what = str_of(j, "what");
        out.push(condition(
            Kind::Janitor,
            format!("janitor:{what}"),
            format!(
                "Home cluster needs you: {} ({}, {}).",
                what.trim_end_matches('.'),
                str_of(j, "who"),
                str_of(j, "when")
            ),
            None,
        ));
    }
    for m in state["mail"].as_array().into_iter().flatten() {
        let (from, subject) = (str_of(m, "from"), str_of(m, "subject"));
        let copies = m["copies"].as_u64().unwrap_or(1);
        let more = if copies > 1 {
            format!(", {copies} copies")
        } else {
            String::new()
        };
        out.push(condition(
            Kind::Mail,
            format!("mail:{from}:{subject}"),
            format!(
                "Critical mail from {from}: {subject} ({}){more}.",
                str_of(m, "acct")
            ),
            None,
        ));
    }
    for m in state["main"].as_array().into_iter().flatten() {
        out.push(Need {
            kind: Kind::Nightly,
            need: NeedKind::Red,
            rank: 0,
            project: str_of(m, "repo").into(),
            text: short(str_of(m, "reason")),
            id: str_of(m, "repo").into(),
            target: None,
            since: None,
            recommend: None,
            score: None,
        });
    }
    if let Some(inf) = infra.filter(|i| i.ok) {
        let mut red: Vec<&str> = inf
            .get("red")
            .iter()
            .map(|s| s.label("item"))
            .filter(|i| !i.is_empty())
            .collect();
        red.sort();
        red.dedup();
        for r in red {
            out.push(Need {
                kind: Kind::Red,
                need: NeedKind::Red,
                rank: 0,
                project: String::new(),
                text: r.into(),
                id: r.into(),
                target: None,
                since: None,
                recommend: None,
                score: None,
            });
        }
    }
    // Stable: equal waits keep their read order (asks, sessions, queue items, sheet rows);
    // conditions last, but a Stopped row first.
    out.sort_by_key(|n| {
        (
            n.kind != Kind::Stopped,
            n.score.is_none(),
            n.score
                .as_ref()
                .map(|s| (!s.human, s.later(), std::cmp::Reverse(s.value))),
        )
    });
    for (i, n) in out.iter_mut().enumerate() {
        n.rank = i + 1;
    }
    out
}

impl Home {
    /// The snapshot's half of the flow strip (inbox, board, the amber step).
    pub fn set_pipeline(&mut self, read: &Result<Option<crate::pipeline::Pipeline>, String>) {
        self.flow.set_pipeline(read);
    }

    /// The proposals agent-propose holds open; a failed read says so among the errors.
    pub fn set_proposals(&mut self, open: &Result<Vec<Proposal>, String>) {
        match open {
            Ok(p) => {
                self.proposals_head = crate::proposals::heading(p);
                self.proposals = p.clone();
            }
            Err(e) => {
                self.proposals_failed = true;
                self.errors.push(format!("{e}, so no proposals are shown"));
            }
        }
    }
}

/// What Home is built from: fleet-sessions' state with its joins (`boards::state`), the queue,
/// the board feed and, when asked, infra, the slow one, read beside the others.
pub fn gather(with_infra: bool) -> (Value, Queue, Result<Feed, String>, Option<Infra>) {
    use crate::session_actions::System;
    let state = boards::state(&boards::fleet_state(), &System);
    std::thread::scope(|s| {
        let infra = with_infra.then(|| s.spawn(crate::infra::gather));
        let queue = Queue::read(&System);
        let board = crate::tasks::feed(&System);
        (
            state,
            queue,
            board,
            infra.map(|i| i.join().unwrap_or_default()),
        )
    })
}

/// Home from fleet-sessions' `state.json` (null when missing), the queue, the board feed,
/// and infra: NEEDS YOU in `needs` order, the running items, the session counts, the spend line and the chips.
pub fn build(
    state: &Value,
    queue: Option<&Queue>,
    board: Option<&Result<Feed, String>>,
    infra: Option<&Infra>,
) -> Home {
    let mut h = Home {
        shown: SHOWN,
        flow: crate::flow::Strip::build(queue),
        ..Home::default()
    };
    if state.is_null() {
        h.errors
            .push("no fleet state yet (fleet-state.timer writes it every minute)".into());
    }
    for u in state["unreadable"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        let what = match u {
            "agent-ask" => "no asks are shown",
            "comms" => "no critical mail is shown",
            "notes" => "no janitor lines are shown",
            "agentctl" => "no budget stops are shown",
            _ => continue,
        };
        h.errors.push(format!("{u} could not be read, so {what}"));
    }
    if let Some(Err(e)) = board {
        h.errors
            .push(format!("{e}, so no human-sheet rows are shown"));
    }
    h.needs = needs(state, queue, board.and_then(|b| b.as_ref().ok()), infra);
    if let Some(q) = queue {
        h.errors.extend(q.errors.iter().cloned());
        h.running = running(state, q);
    }
    if let Some(c) = state["counts"].as_object() {
        let n = |k: &str| c.get(k).and_then(Value::as_u64).unwrap_or(0);
        h.sessions = format!(
            "{} working, {} need you, {} stalled",
            n("WORKING"),
            n("NEEDS"),
            n("STALLED")
        );
    }

    match infra {
        None => h.errors.push("Prometheus: reading".into()),
        Some(i) if !i.ok => h.errors.push(format!(
            "Prometheus: {}",
            i.error.as_deref().unwrap_or("did not answer")
        )),
        Some(i) => {
            let v = i.cc_values();
            if let Some(x) = v.get("cc:claude_code_cost_24h_usd") {
                h.spend = Some(format!("claude ${x:.0} in 24h"));
            }
            h.health = i.health();
            h.vitals = crate::vitals::read(i);
        }
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn infra(cc: Vec<Value>, red: &[&str]) -> Infra {
        let res = |rows: Vec<Value>| {
            crate::prom::flatten(&json!({"status": "success", "data": {"result": rows}})).unwrap()
        };
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert("cc", res(cc));
        i.instant.insert(
            "red",
            res(red
                .iter()
                .map(|r| json!({"metric": {"item": r}, "value": [0, "1"]}))
                .collect()),
        );
        i
    }

    fn domain(d: &str, v: &str) -> Value {
        json!({"metric": {"__name__": "cc:domain_status", "domain": d}, "value": [0, v]})
    }

    fn item(slug: &str, state: State, session: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            state,
            project: "p".into(),
            task: format!("Do {slug}."),
            session: session.map(String::from),
            ..Default::default()
        }
    }

    /// 2026-11-05T09:00:00-0800, an hour after the fixture's ask.
    const NOW: i64 = 1_793_898_000;

    fn state() -> Value {
        json!({
            "generated_epoch": NOW,
            "counts": {"WORKING": 2, "NEEDS": 2, "STALLED": 0},
            "sessions": [
                {"target": "lab/repo-agent-1:1", "bucket": "NEEDS", "asks": 1, "idle_min": 5, "cwd": "/w/repo", "project": "repo"},
                {"target": "hub/dotfiles:2", "bucket": "NEEDS", "asks": 0, "idle_min": 3,
                 "cwd": "/home/k/.dotfiles", "project": "dotfiles", "reason": "waiting on a prompt or permission"},
                {"target": "lab/repo-agent-2:1", "bucket": "WORKING", "phases_done": 2,
                 "phases_total": 4, "next_phase": "three"},
            ],
            "asks": [
                {"id": "a1", "project": "repo", "question": "Which one?\nmore", "session": "repo-agent-1",
                 "created": "2026-11-05T08:00:00-0800"},
            ],
            "main": [{"repo": "repo", "reason": "repo red: Tests"}],
        })
    }

    #[test]
    fn the_briefing_only_inputs_are_conditions_after_every_wait() {
        let mut st = state();
        st["budget"] =
            json!([{"runner": "dream", "detail": "day $10.20 of $10.", "at": NOW - 600}]);
        st["janitor"] = json!([{"when": "Fri 06:30", "who": "janitor", "what": "pvc stuck"}]);
        st["mail"] = json!([{"from": "alarm@aws", "subject": "ALARM: 5xx", "acct": "gigantic", "copies": 5}]);
        let mut failed = item("night-1", State::Done, None);
        failed.tags = "night tier3".into();
        failed.status = Some("failed".into());
        failed.finished = Some("2026-11-05T03:00:00-0800".into());
        // Negative controls: a night item that ended ok, and a failed item that was no night task.
        let mut ok = failed.clone();
        ok.slug = "night-ok".into();
        ok.status = Some("ok".into());
        let mut day = failed.clone();
        day.slug = "day-failed".into();
        day.tags = String::new();
        // And one that failed more than a day before the state was written.
        let mut old = failed.clone();
        old.slug = "night-old".into();
        old.finished = Some("2026-11-03T03:00:00-0800".into());
        let q = Queue {
            items: vec![failed, ok, day, old],
            ..Default::default()
        };
        let h = build(&st, Some(&q), None, None);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        assert_eq!(
            rows,
            [
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Budget, "budget:dream"),
                (Kind::Night, "night-1"),
                (Kind::Janitor, "janitor:pvc stuck"),
                (Kind::Mail, "mail:alarm@aws:ALARM: 5xx"),
                (Kind::Nightly, "repo"),
            ]
        );
        let text = |k: Kind| h.needs.iter().find(|n| n.kind == k).unwrap().text.clone();
        assert_eq!(
            text(Kind::Budget),
            "dream stopped at its daily budget: day $10.20 of $10. To go on today: agentctl budget dream raise <usd>."
        );
        assert_eq!(
            text(Kind::Night),
            "Night task night-1 failed: Do night-1. Run agent-queue show night-1."
        );
        assert_eq!(
            text(Kind::Janitor),
            "Home cluster needs you: pvc stuck (janitor, Fri 06:30)."
        );
        assert_eq!(
            text(Kind::Mail),
            "Critical mail from alarm@aws: ALARM: 5xx (gigantic), 5 copies."
        );
        assert!(h
            .needs
            .iter()
            .filter(|n| n.kind >= Kind::Budget)
            .all(|n| n.score.is_none()));
        // A budget stop waits on a raise, so it filters as Blocked; the rest as Failing.
        let need = |k: Kind| h.needs.iter().find(|n| n.kind == k).unwrap().need;
        assert_eq!(need(Kind::Budget), NeedKind::Blocked);
        for k in [Kind::Night, Kind::Janitor, Kind::Mail] {
            assert_eq!(need(k), NeedKind::Red, "{k:?}");
        }
    }

    #[test]
    fn an_unreadable_signal_source_is_said_not_shown_as_nothing() {
        let mut st = state();
        st["unreadable"] = json!(["comms", "notes", "agentctl", "something-else"]);
        let h = build(&st, None, None, None);
        assert_eq!(
            h.errors[..3],
            [
                "comms could not be read, so no critical mail is shown",
                "notes could not be read, so no janitor lines are shown",
                "agentctl could not be read, so no budget stops are shown",
            ]
        );
        assert!(!h.errors.iter().any(|e| e.contains("something-else")));
    }

    #[test]
    fn an_ask_stands_for_its_session_and_its_queue_item_once() {
        let q = Queue {
            items: vec![
                item("asked", State::Waiting, Some("lab:repo-agent-1")),
                item("lone", State::Waiting, None),
                item("dialog", State::Waiting, Some("hub:dotfiles")),
                item("busy", State::Running, Some("lab:repo-agent-2")),
            ],
            ..Default::default()
        };
        let h = build(&state(), Some(&q), None, None);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        assert_eq!(
            rows,
            [
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Queue, "lone"),
                (Kind::Nightly, "repo"),
            ]
        );
        let ask = &h.needs[0];
        assert_eq!(ask.text, "Which one?");
        assert_eq!(ask.target.as_deref(), Some("lab/repo-agent-1:1"));
        // The session row takes its queue item's words, and its age from the idle minutes.
        assert_eq!(h.needs[1].text, "Do dialog");
        assert_eq!(h.needs[1].since, Some(NOW - 180));
        assert_eq!(h.running.len(), 1);
        let p = h.running[0].phases.as_ref().unwrap();
        assert_eq!((p.done, p.total), (2, 4));
        // The queue's counts are the flow strip's; the session counts head Running.
        assert_eq!(h.sessions, "2 working, 2 need you, 0 stalled");
        assert_eq!(h.spend, None, "no Prometheus read, no spend");
        assert_eq!(h.flow.chips[3].text(), "running 1");
        assert_eq!(h.flow.chips[2].text(), "queued 0");
        assert_eq!(h.errors, ["Prometheus: reading"]);
    }

    #[test]
    fn an_unreadable_agent_ask_is_said_not_shown_as_no_asks() {
        let mut st = state();
        st["asks"] = json!([]);
        st["unreadable"] = json!(["agent-ask"]);
        let h = build(&st, None, None, None);
        assert!(h.errors.iter().any(|e| e.contains("agent-ask")));
        let ok = build(&state(), None, None, None);
        assert!(!ok.errors.iter().any(|e| e.contains("agent-ask")));
    }

    fn score(n: &Need) -> (bool, bool, u64, u64, i64, i64) {
        let s = n.score.as_ref().unwrap();
        (
            s.human,
            s.session,
            s.phases,
            s.dependents,
            s.age_min,
            s.value,
        )
    }

    #[test]
    fn needs_rank_by_what_they_hold_times_how_long_they_waited() {
        let mut st = state();
        st["sessions"] = json!([
            {"target": "lab/big-agent-1:1", "bucket": "NEEDS", "idle_min": 30,
             "phases_done": 1, "phases_total": 4, "cwd": "/w/freqtrade_trading_attempt-agent-1",
             "project": "trader"},
        ]);
        st["asks"] = json!([
            // Ten days old, but the judge said a machine can answer it: below every human row.
            {"id": "auto", "question": "q", "kind": "question", "judge": "take-recommend",
             "recommend": "yes", "created": "2026-10-26T09:00:00-0800"},
            // A gate is the human's whatever the judge said.
            {"id": "gate", "question": "q", "kind": "gate", "judge": "take-recommend",
             "created": "2026-11-05T08:50:00-0800"},
            {"id": "old", "question": "q", "created": "2026-11-05T08:00:00-0800"},
            {"id": "undated", "question": "q"},
        ]);
        st["main"] = json!([]);
        let mut parent = item("parent", State::Waiting, None);
        parent.started = Some("2026-11-05T08:40:00-0800".into());
        let kid = |slug: &str, after: &str| {
            let mut i = item(slug, State::Queued, None);
            i.after = Some(after.into());
            i
        };
        // `after:` is a list: k2 waits on parent among others; k3 names only a look-alike slug.
        let q = Queue {
            items: vec![
                parent,
                kid("k1", "parent"),
                kid("k2", "other parent"),
                kid("k3", "parent-old"),
            ],
            ..Default::default()
        };
        let h = build(&st, Some(&q), None, None);
        let ids: Vec<&str> = h.needs.iter().map(|n| n.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "lab/big-agent-1:1",
                "old",
                "parent",
                "gate",
                "undated",
                "auto"
            ]
        );
        // The project is the one the row carries: a freqtrade_trading_attempt worktree is trader.
        assert_eq!(h.needs[0].project, "trader");
        // (1 + session + 3 phases left) * 30 min.
        assert_eq!(score(&h.needs[0]), (true, true, 3, 0, 30, 150));
        assert_eq!(
            h.needs[0].score.as_ref().unwrap().holds,
            "session, 3 phases"
        );
        assert_eq!(score(&h.needs[1]), (true, false, 0, 0, 60, 60));
        // (1 + 2 queued after it) * 20 min.
        assert_eq!(score(&h.needs[2]), (true, false, 0, 2, 20, 60));
        assert_eq!(h.needs[2].score.as_ref().unwrap().holds, "2 queued");
        assert_eq!(score(&h.needs[3]), (true, false, 0, 0, 10, 10));
        assert_eq!(score(&h.needs[4]).5, 0);
        let auto = &h.needs[5];
        assert_eq!(score(auto), (false, false, 0, 0, 14_400, 14_400));
        assert_eq!(auto.recommend.as_deref(), Some("yes"));
        assert_eq!(h.shown, SHOWN);
    }

    #[test]
    fn conditions_follow_every_scored_row_and_carry_no_score() {
        let i = infra(vec![], &["watch:a"]);
        let h = build(&state(), None, None, Some(&i));
        let kinds: Vec<Kind> = h.needs.iter().map(|n| n.kind).collect();
        assert_eq!(kinds, [Kind::Ask, Kind::Session, Kind::Nightly, Kind::Red]);
        assert!(h.needs[2..].iter().all(|n| n.score.is_none()));
        // An ask from the future (a skewed clock) waits zero minutes, never negative.
        let mut st = state();
        st["asks"][0]["created"] = json!("2026-11-06T09:00:00-0800");
        assert_eq!(score(&build(&st, None, None, None).needs[1]).4, 0);
    }

    #[test]
    fn a_stopped_dispatch_leads_needs_you_as_one_unscored_line() {
        let mut st = state();
        st["stopped"] = json!([{"runner": "fleet-dispatch", "since": NOW - 13 * 3600,
            "why": "no account has room",
            "line": "Dispatch stopped 13h: no account has room. Clears when an account is back under its pace."}]);
        let h = build(&st, None, None, None);
        let top = &h.needs[0];
        assert_eq!(top.kind, Kind::Stopped);
        assert_eq!(top.id, "stopped:fleet-dispatch");
        assert!(top.text.starts_with("Dispatch stopped 13h: "));
        assert_eq!(top.since, Some(NOW - 13 * 3600));
        assert!(top.score.is_none());
        assert_eq!(serde_json::to_value(top).unwrap()["kind"], "stopped");
        // The rest keep their order; with no hold there is no Stopped row.
        assert_eq!(h.needs[1].kind, Kind::Ask);
        assert!(build(&state(), None, None, None)
            .needs
            .iter()
            .all(|n| n.kind != Kind::Stopped));
    }

    fn sheet(id: &str, lane: &str, ty: &str, priority: &str, since: &str) -> Row {
        Row {
            project: Some("trader".into()),
            lane: lane.into(),
            r#type: Some(ty.into()),
            state: "open".into(),
            priority: priority.into(),
            id: Some(id.into()),
            text: format!("{ty}(markets): do {id} #{priority}"),
            since: Some(since.into()),
            ..Row::default()
        }
    }

    fn board() -> Result<Feed, String> {
        let mut doing = sheet("tr-9", "human", "run", "urgent", "2026-11-01");
        doing.state = "doing".into();
        Ok(Feed {
            rows: vec![
                sheet("tr-117", "human", "run", "high", "2026-11-01"),
                sheet("tr-50", "human", "run", "urgent", "2026-11-04"),
                // Worked by the queue item behind ask a1, so the ask stands for it.
                sheet("tr-51", "human", "decide", "urgent", "2026-11-04"),
                // None of these needs the human: a #low row, work an agent can take, a row on
                // the agent board and a row the human already started.
                sheet("tr-119", "human", "decide", "low", "2026-11-01"),
                sheet("tr-38", "human", "feat", "high", "2026-11-01"),
                sheet("ar-1", "agent", "run", "urgent", "2026-11-01"),
                doing,
            ],
            ..Feed::default()
        })
    }

    #[test]
    fn human_sheet_rows_that_need_the_human_rank_by_priority_then_their_wait() {
        let mut asked = item("asked", State::Waiting, Some("lab:repo-agent-1"));
        asked.row = Some("trader:tr-51".into());
        let q = Queue {
            items: vec![asked],
            ..Default::default()
        };
        let h = build(&state(), Some(&q), Some(&board()), None);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        // The #urgent row has waited longer than the ask, so it leads; the #high row, older
        // still, follows every live wait; conditions stay last.
        assert_eq!(
            rows,
            [
                (Kind::Sheet, "tr-50"),
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Sheet, "tr-117"),
                (Kind::Nightly, "repo"),
            ]
        );
        let top = &h.needs[0];
        let age = (NOW - day_start("2026-11-04").unwrap()) / 60;
        assert!(age > 60 * 24, "a day-old row waits more than a day: {age}");
        assert_eq!(score(top), (true, false, 0, 0, age, age));
        assert_eq!(top.project, "trader");
        assert_eq!(top.text, "run(markets): do tr-50 #urgent");
        let json = serde_json::to_value(top).unwrap();
        assert_eq!(json["kind"], "sheet");
        assert_eq!(json["score"]["priority"], "urgent");
        assert!(serde_json::to_value(&h.needs[1]).unwrap()["score"]
            .get("priority")
            .is_none());
        // With no board read there are no sheet rows, and nothing else moves.
        let without: Vec<Kind> = build(&state(), Some(&q), None, None)
            .needs
            .iter()
            .map(|n| n.kind)
            .collect();
        assert_eq!(without, [Kind::Ask, Kind::Session, Kind::Nightly]);
    }

    #[test]
    fn an_ask_whose_task_is_the_row_stands_for_it_and_a_failed_board_read_is_said() {
        let mut st = state();
        st["asks"][0]["project"] = json!("trader");
        st["asks"][0]["task"] = json!("tr-50");
        let ids: Vec<String> = build(&st, None, Some(&board()), None)
            .needs
            .into_iter()
            .filter(|n| n.kind == Kind::Sheet)
            .map(|n| n.id)
            .collect();
        assert_eq!(ids, ["tr-51", "tr-117"]);
        let h = build(
            &state(),
            None,
            Some(&Err("notes board --json: boom".into())),
            None,
        );
        assert!(h
            .errors
            .iter()
            .any(|e| e.starts_with("notes board --json: boom")));
        assert!(h.needs.iter().all(|n| n.kind != Kind::Sheet));
    }

    #[test]
    fn spend_is_one_worded_line_and_a_missing_series_or_counts_read_as_nothing() {
        let cost =
            json!({"metric": {"__name__": "cc:claude_code_cost_24h_usd"}, "value": [0, "573.4"]});
        let h = build(&state(), None, None, Some(&infra(vec![cost], &[])));
        assert_eq!(h.spend.as_deref(), Some("claude $573 in 24h"));
        let none = build(&Value::Null, None, None, Some(&infra(vec![], &[])));
        assert_eq!(none.spend, None, "a series Prometheus lacks is not $0");
        assert_eq!(none.sessions, "", "no state, no counts");
    }

    #[test]
    fn health_keeps_the_known_domains_and_red_now_items_are_needs() {
        let i = infra(
            vec![domain("ci", "1"), domain("prod", "0")],
            &["watch:b", "watch:a"],
        );
        let h = build(&Value::Null, None, None, Some(&i));
        let chips: Vec<(&str, Level)> = h
            .health
            .iter()
            .map(|c| (c.name.as_str(), c.level))
            .collect();
        assert_eq!(
            chips,
            [
                ("k3s", Level::Nodata),
                ("ci", Level::Warn),
                ("prod", Level::Ok)
            ]
        );
        assert_eq!(h.exceptions().count(), 2);
        let red: Vec<&str> = h.needs.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(red, ["watch:a", "watch:b"]);
        assert!(h.errors[0].starts_with("no fleet state"));
    }

    #[test]
    fn a_failed_prometheus_read_is_an_error_not_a_green_strip() {
        let i = Infra {
            ok: false,
            error: Some("timeout".into()),
            ..Default::default()
        };
        let h = build(&state(), None, None, Some(&i));
        assert!(h.health.is_empty());
        assert_eq!(h.errors, ["Prometheus: timeout"]);
    }

    #[test]
    fn a_rows_rank_and_kind_are_counted_here_and_the_chips_are_the_kinds() {
        use crate::table::Row;
        let labels = NeedKind::ALL.map(NeedKind::label);
        assert_eq!(Need::STATES[1..], labels);
        let q = Queue {
            items: vec![item("lone", State::Waiting, None)],
            ..Default::default()
        };
        let mut s = state();
        s["sessions"][1]["dialog"] = "tool".into();
        s["stopped"] = json!([{"runner": "d", "line": "held", "since": NOW - 60}]);
        let rows = needs(&s, Some(&q), None, None);
        let got: Vec<(usize, NeedKind)> = rows.iter().map(|n| (n.rank, n.need)).collect();
        assert_eq!(
            got,
            [
                (1, NeedKind::Stopped),
                (2, NeedKind::Ask),
                (3, NeedKind::Perm),
                (4, NeedKind::Blocked),
                (5, NeedKind::Red),
            ]
        );
        for (dialog, need) in [
            ("choice", NeedKind::Ask),
            ("plan", NeedKind::Plan),
            ("text", NeedKind::Turn),
            ("", NeedKind::Turn),
        ] {
            assert_eq!(NeedKind::of_dialog(dialog), need);
        }
    }

    #[test]
    fn a_view_of_needs_filters_by_kind_and_project_and_sorts_by_the_wait() {
        use crate::table::View;
        let rows = needs(&state(), None, None, None);
        let ids =
            |v: View| -> Vec<String> { v.apply(&rows).iter().map(|n| n.id.clone()).collect() };
        let q = |q: &str| View::new::<Need>(q, "", "", "");
        assert_eq!(ids(q("kind:ask")), ["a1"]);
        assert_eq!(ids(q("kind:turn project:dotfiles")), ["hub/dotfiles:2"]);
        assert_eq!(ids(q("-kind:red -kind:turn")), ["a1"]);
        assert_eq!(ids(q("failing")), ["repo"], "a bare word reads the label");
        assert_eq!(ids(q("a1")), ["a1"], "and the id the row acts on");
        let chip = View::new::<Need>("", "your turn", "", "");
        assert_eq!(ids(chip), ["hub/dotfiles:2"]);
        // The first click: longest wait on top, a condition with no start time last.
        let longest = View::new::<Need>("", "", "waited", "");
        assert_eq!(ids(longest), ["a1", "hub/dotfiles:2", "repo"]);
    }

    #[test]
    fn only_the_chips_with_rows_or_in_force_are_offered() {
        use crate::table::View;
        let rows = needs(&state(), None, None, None);
        let names = |v: &View| -> Vec<&str> { v.states(&rows).iter().map(|c| c.name).collect() };
        let v = View::default();
        assert_eq!(names(&v), ["all", "Question", "Your turn", "Failing"]);
        let v = View::new::<Need>("kind:ask", "Blocked", "", "");
        assert_eq!(names(&v), ["all", "Question", "Blocked"]);
        // The TUI's `f` steps over the same chips, never onto a hidden one.
        let mut v = View::default();
        let mut seen = vec![];
        for _ in 0..4 {
            v.cycle_shown(&rows);
            seen.push(v.state.clone());
        }
        assert_eq!(seen, ["Question", "Your turn", "Failing", ""]);
    }

    #[test]
    fn holds_is_what_the_row_holds_or_a_sheet_rows_priority() {
        let mut n = needs(&state(), None, None, None).remove(0);
        n.score = Some(Score::new(true, true, 2, 0, 5));
        assert_eq!(n.holds(), "session, 2 phases");
        let mut s = Score::new(true, false, 0, 0, 5);
        s.priority = Some("high".into());
        n.score = Some(s);
        assert_eq!(n.holds(), "#high");
        n.score = None;
        assert_eq!(n.holds(), "");
    }

    #[test]
    fn a_session_name_is_read_from_every_shape() {
        assert_eq!(tmux_name("lab/repo-agent-1:1"), "repo-agent-1");
        assert_eq!(tmux_name("lab:repo-agent-1"), "repo-agent-1");
        assert_eq!(tmux_name("repo-agent-1"), "repo-agent-1");
    }

    #[test]
    fn proposals_join_home_and_a_failed_read_says_so() {
        let p = Proposal {
            stream: "dream".into(),
            ..Proposal::default()
        };
        let mut h = build(&state(), None, None, None);
        h.set_proposals(&Ok(vec![p.clone()]));
        assert_eq!(h.proposals, [p]);
        assert_eq!(h.proposals_head, "1 from 1 stream");
        let mut h = build(&state(), None, None, None);
        h.set_proposals(&Err("no jq".into()));
        assert!(h.proposals_failed);
        assert!(h
            .errors
            .iter()
            .any(|e| e == "no jq, so no proposals are shown"));
    }
}
