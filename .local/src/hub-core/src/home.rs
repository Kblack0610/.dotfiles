//! The Home tab for both surfaces: what needs the human, the vitals and the health chips the
//! briefing reads; the running items are `running`, the Queue's and a project's In flight; the status
//! grid over it is `cards`, one card per tab. It joins what the other readers already read (fleet-sessions'
//! `state.json`, `queue::Queue`, `infra::Infra`, read by `gather`), and `build` reads nothing
//! itself, so it is pure and both surfaces get the same rows in the same order.
//!
//! One row per thing that waits: a session with a pending ask shows the ask, not the session as
//! well, and a queue item waiting on a session already shown adds nothing. A waiting item an ask
//! holds (its `ask:<id>` tag, or the ask's Claude session last in its `sessions`) shows on the ask's row
//! after that session ends, and one whose last session's ask was answered leaves the list. Sessions are matched
//! to a queue item by their tmux session name, the one name an item and a state row carry; an ask
//! finds its session by `claude_session` alone (the state row's `session_id`), never by name.
//!
//! `needs` is the one ranking of that list: every surface, `hub needs --json`, the briefing's
//! Needs you, fleet-bench's asks digest and the needs pager read its order, and none re-sorts it. A row's `Score` is counted
//! from facts (who can act, whether it stops running work, what it holds, how long it waited, a
//! sheet row's own priority), never a model's number.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::boards;
use crate::fleet::ts;
use crate::infra::Infra;
use crate::proposals::Proposal;
use crate::queue::{Item, Queue, State};
use crate::reading::State as Reading;
use crate::tasks::{self, Feed, Row};

/// The health chips, in the order the strip shows them (the `cc:domain_status` domains).
pub const DOMAINS: [&str; 12] = [
    "k3s", "machines", "ci", "projects", "prod", "llm", "agents", "spend", "platform", "queue",
    "home", "other",
];
/// The row types only the human can do (notes-cli README, "The task row": `run decide check`).
/// A human-sheet row of another type is work an agent can take, so it never needs the human.
pub const HUMAN_TYPES: [&str; 3] = ["run", "decide", "check"];
/// The priorities a human-sheet row needs before it joins NEEDS YOU; a `#normal`, untagged
/// (notes-cli `md::DEFAULT_PRIORITY`) or `#low` row waits on the sheet. A row that truly blocks
/// the human is triaged to `#high`. Why: `#normal` is the default for new work, so counting it
/// floods NEEDS YOU with to-dos that block nothing.
pub const SHEET_PRIORITIES: [&str; 2] = ["urgent", "high"];
/// The domains shown even when Prometheus has no status for them, so a missing one reads as no data:
/// k3s and ci are the platform, and projects holds the playground and dotfiles CI watches that left ci.
pub(crate) const ALWAYS: [&str; 3] = ["k3s", "ci", "projects"];
/// How much of a question or reason a row keeps.
pub const TEXT_MAX: usize = 160;
/// How many rows of a list Home shows: a glance, not the list. The TUI folds the rest under "+N
/// more"; agent-web sends this many rows a Needs you or Proposals page, and ends Running in a link
/// to all of it on Queue.
pub const SHOWN: usize = 6;
/// fleet-state.timer rewrites `state.json` every minute; past this many seconds without a
/// rewrite Home says the state stopped, instead of showing an old list as if it were now. The
/// number is `FLEET_STATE_STALE_SECS` in `.config/fleet-sessions/state.conf`, which fleet-sessions
/// reads too; a conf that does not carry it as a plain number fails the build.
pub const FLEET_STATE_STALE_SECS: i64 = conf_number(
    include_str!("../../../../.config/fleet-sessions/state.conf"),
    "FLEET_STATE_STALE_SECS",
);

/// The whole number after `key=` on the line that starts with it. A const fn, so a missing or
/// non-numeric value stops the build.
const fn conf_number(conf: &str, key: &str) -> i64 {
    let (c, k) = (conf.as_bytes(), key.as_bytes());
    let mut i = 0;
    while i + k.len() < c.len() {
        let mut m = i == 0 || c[i - 1] == b'\n';
        let mut j = 0;
        while m && j < k.len() {
            m = c[i + j] == k[j];
            j += 1;
        }
        if m && c[i + k.len()] == b'=' {
            let (mut n, mut at, mut digits) = (0i64, i + k.len() + 1, 0);
            while at < c.len() && c[at].is_ascii_digit() {
                n = n * 10 + (c[at] - b'0') as i64;
                at += 1;
                digits += 1;
            }
            assert!(
                digits > 0 && (at == c.len() || c[at] == b'\n' || c[at] == b'\r'),
                "the conf key is not a number alone on its line"
            );
            return n;
        }
        i += 1;
    }
    panic!("the conf key is missing")
}

/// What a row is, and who owns it (`Kind::owner`): `build` keeps the human's kinds in `Home.needs`
/// and moves the agent's to `Home.routed`. Conditions (Hold to Red) list after every scored row,
/// in this order. A condition has no score, so the needs pager never pages it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A hold that has stopped every dispatch pass (`fleet-dispatch stopped`): how long, why and
    /// what clears it, in one line. A condition with no score, so the needs pager leaves it to
    /// the queue-starved watch. Agent work: `build` routes it.
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
    /// A hold the human set that has stood a day (`holds::Hold::standing`): it waits on their
    /// release. Alerts shows it red too, beside the holds an agent set.
    Hold,
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

    /// A condition row's: a budget stop waits on a raise and a hold on its release, as a blocked
    /// item does; every other condition is a failure.
    fn of_condition(kind: Kind) -> NeedKind {
        match kind {
            Kind::Budget | Kind::Hold => NeedKind::Blocked,
            _ => NeedKind::Red,
        }
    }

    /// A session row's, from its open question (`agent_core::transcript::Question::kind`); a
    /// session with none, or a closing message that asks, waits for its turn.
    pub fn of_dialog(dialog: &str) -> NeedKind {
        match dialog {
            "choice" => NeedKind::Ask,
            "tool" => NeedKind::Perm,
            "plan" => NeedKind::Plan,
            _ => NeedKind::Turn,
        }
    }

    /// This kind with its label, as a dialog outside Home carries it.
    pub fn tag(self) -> NeedTag {
        NeedTag {
            kind: self,
            label: self.label(),
        }
    }
}

/// Who a row's work belongs to: Needs you lists only what the human alone can do (ar-4018); the
/// rest is routed through the agent system and shows on the tab that owns it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    Human,
    Agent,
}

impl Kind {
    /// The one place that says whether a kind of row is the human's or agent work. A match with no
    /// wildcard, so a new kind cannot compile without a verdict. An agent kind's rows land in
    /// `Home::routed`, not `Home::needs`; the tab that shows each is named here.
    pub fn owner(self) -> Owner {
        match self {
            // The human's alone: a wait on them, or a call only they make.
            Kind::Ask | Kind::Session | Kind::Queue | Kind::Sheet => Owner::Human,
            // A raise is their call; the janitor and critical mail are addressed to them (mail
            // expires by `signals::MAIL_TTL_DAYS`).
            Kind::Budget | Kind::Janitor | Kind::Mail => Owner::Human,
            // A hold the human set: only their word releases it.
            Kind::Hold => Owner::Human,
            // A failed tier-3 task: the Queue tab, its board row open for dispatch.
            Kind::Night => Owner::Agent,
            // A `cc:red_now` item: Alerts, with its owner and fix.
            Kind::Red => Owner::Agent,
            // A red nightly on main: the Main red card and Alerts.
            Kind::Nightly => Owner::Agent,
            // A dispatch hold: the Queue flow strip and the queue-starved watch.
            Kind::Stopped => Owner::Agent,
        }
    }

    /// What a row of this kind is, for a card with no answer form of its own: an ask and a
    /// session have a card, so they say nothing here.
    pub fn what(self) -> &'static str {
        match self {
            Kind::Stopped => "dispatch",
            Kind::Ask | Kind::Session => "",
            Kind::Queue => "queue item",
            Kind::Sheet => "your sheet",
            Kind::Budget => "budget stop",
            Kind::Hold => "hold",
            Kind::Night => "night task",
            Kind::Janitor => "home cluster",
            Kind::Mail => "critical mail",
            Kind::Nightly => "nightly failed",
            Kind::Red => "red now",
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
    /// (Stopped, Hold to Red) is not a wait, and has none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score: Option<Score>,
    /// An ask row's whole record, joined here so a surface draws its answer card from the row
    /// and never finds it again in a second list.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ask: Option<boards::Ask>,
}

/// A row as the pages receive it: the row, and the words every surface draws it with, so no page
/// keeps its own table of kind labels or of what a kind of row is.
#[derive(Serialize)]
struct NeedRow<'a> {
    #[serde(flatten)]
    need: &'a Need,
    /// The kind as drawn: the chip, the KIND cell and the card's band lead with it.
    label: &'static str,
    /// Why it sits where it does (`Need::holds`).
    holds: String,
    /// `holds` as a card's band says it, with no column header to name it ("holds session").
    holds_line: String,
    /// What kind of row it is, for a card with no answer form (`Kind::what`).
    what: &'static str,
}

fn need_rows<S: serde::Serializer>(needs: &[Need], s: S) -> Result<S::Ok, S::Error> {
    s.collect_seq(needs.iter().map(|need| NeedRow {
        need,
        label: need.need.label(),
        holds: need.holds(),
        holds_line: need.holds_line(),
        what: need.kind.what(),
    }))
}

/// A session's open dialog as a Needs you kind, for the pane that shows it outside Home.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct NeedTag {
    pub kind: NeedKind,
    pub label: &'static str,
}

impl Need {
    /// Where a tap on the row leads off Home: its session or queue item, else Needs you filtered
    /// to its kind, where its answer card or close button is.
    pub fn link(&self) -> crate::links::Link {
        use crate::links::{Kind as L, Link};
        match self.kind {
            Kind::Session => Link::to(L::Session, self.target.as_deref().unwrap_or(&self.id)),
            Kind::Queue => Link::to(L::Queue, &self.id),
            Kind::Ask => Link::to(L::Ask, &self.id),
            _ => Link::to(L::Needs, self.need.label()),
        }
    }

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

    /// `holds` as a card's band says it, with no column header to name it: "holds session, 2 phases"
    /// for what a row holds, a sheet row's `#priority` as it is.
    pub fn holds_line(&self) -> String {
        match &self.score {
            Some(s) if !s.holds.is_empty() => format!("holds {}", s.holds),
            _ => self.holds(),
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
        match col {
            "rank" => Val::Num(self.rank as f64),
            "kind" => Val::word(self.need.slug()),
            "project" => Val::word(&self.project),
            // Earlier is bigger, so a header's first click puts the longest wait on top.
            "waited" => self.since.map_or(Val::None, |s| Val::Num(-(s as f64))),
            "holds" => Val::word(&self.holds()),
            "what" => Val::word(&self.text),
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
    /// A sheet row's priority (`urgent` or `high`, `SHEET_PRIORITIES`). Every sheet row ranks
    /// after every live wait with the same `human`, since a live wait stops work already running
    /// and a to-do does not; among sheet rows, `high` follows `urgent`. A live
    /// wait has none.
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
            words.push(crate::display::fmt::counted(phases as usize, "phase"));
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

    /// Name the waiting queue item an ask holds first in `holds`, so the item shows once, on its ask's row.
    pub fn holding(&mut self, slug: &str) {
        self.holds = if self.holds.is_empty() {
            slug.to_string()
        } else {
            format!("{slug}, {}", self.holds)
        };
    }

    /// Where the row ranks among the human's: 0 a live wait (an ask, a session, a queue item),
    /// which stops running work; then a sheet to-do by its priority, `urgent` 1, `high` 2
    /// (`tasks::PRIORITIES` order).
    fn tier(&self) -> u8 {
        self.priority.as_deref().map_or(0, |p| {
            let i = tasks::PRIORITIES.iter().position(|w| *w == p);
            1 + i.unwrap_or(tasks::PRIORITIES.len()) as u8
        })
    }
}

/// An ask the judge said a machine could answer (`take-recommend`, `answer:<text>`). An approval
/// is the human's whatever the verdict says, and a gate is judged like a question; an error or no
/// verdict is the human's.
fn machine_can_answer(kind: &str, judge: &str) -> bool {
    kind != "approval" && (judge == "take-recommend" || judge.starts_with("answer:"))
}

/// One running queue item, with its plan's progress when its session has a checklist, and each
/// thing it links to, joined at read time from the store that owns it (lifecycle.md: nothing
/// stores a link): its board row and that row's epic (`#of/`), its session's PR and CI.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
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
    /// The board row's id (`ar-1494`): the item's `row:`, else its `from: board:`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
    /// The epic the row's `#of/` names, when the board feed was read and has the row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub epic: Option<String>,
    /// That epic's system, the area of its `epic(<system>):` row (`dispatch`, `views`): the
    /// category the Projects chip groups running work by.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area: Option<String>,
    /// The PR as a row prints it (`#1871`) and its page: the session's, else the item's own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    /// The session's PR state (`open`, `merged`), lower case.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr_state: Option<String>,
    /// The session's CI on that PR as fleet-sessions read it, lower case, and where its checks are.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ci: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ci_url: Option<String>,
    /// fleet-sessions' overdue verdict is set on its session row (`overdue`, the shepherd's rule). Read from
    /// the row, not `phases`: the verdict can sit on the session running a phase, which may have no
    /// checklist of its own.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub overdue: bool,
}

impl Running {
    /// `2/4`, or empty with no checklist.
    pub fn phase(&self) -> String {
        self.phases.as_ref().map_or(String::new(), |p| p.shown())
    }

    /// fleet-sessions writes the PR's CI as `PASS`, `FAIL`, `PENDING` or `NONE` (fleet-states.md).
    pub fn ci_failing(&self) -> bool {
        self.ci.as_deref() == Some("fail")
    }
}

impl crate::table::Row for Running {
    const COLUMNS: &'static [&'static str] = &[
        "item", "project", "row", "epic", "phase", "eta", "pr", "ci", "since",
    ];
    const STATES: &'static [&'static str] = &["all", "Overdue", "CI failing", "No session"];
    const FACETS: &'static [&'static str] = &["project", "epic", "ci"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "item";
    const GLANCE: &'static [&'static str] = &["project", "eta", "since"];

    fn val(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        let text = |s: Option<&str>| s.map_or(Val::None, Val::word);
        match col {
            "item" => text(Some(&self.title)),
            "project" => text(Some(&self.project)),
            "row" => text(self.row.as_deref()),
            "epic" => text(self.epic.as_deref()),
            "phase" => text(Some(&self.phase())),
            "eta" => self
                .phases
                .as_ref()
                .and_then(|p| p.eta_epoch)
                .map_or(Val::None, |e| Val::Num(e as f64)),
            "pr" => text(self.pr.as_deref()),
            "ci" => text(self.ci.as_deref()),
            "since" => text(self.started.as_deref()),
            _ => Val::None,
        }
    }

    /// The phase sorts by how far through it is, not by its text (`10/12` after `2/4`).
    fn rank(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        match (col, &self.phases) {
            ("phase", Some(p)) if p.total > 0 => Val::Num(p.done as f64 / p.total as f64),
            _ => self.val(col),
        }
    }

    /// The item opens its session, else its queue item; project, row and epic their own homes; PR
    /// and CI their forge pages.
    fn link(&self, col: &str) -> Option<crate::links::Link> {
        use crate::links::{Kind, Link};
        let some = |s: Option<&str>| s.filter(|s| !s.is_empty()).map(String::from);
        match col {
            "item" => Some(match some(self.target.as_deref()) {
                Some(t) => Link::To(Kind::Session, t),
                None => Link::to(Kind::Queue, &self.slug),
            }),
            "project" => some(Some(&self.project)).map(|p| Link::To(Kind::Project, p)),
            "row" => some(self.row.as_deref()).map(|r| Link::To(Kind::Row, r)),
            "epic" => some(self.epic.as_deref()).map(|e| Link::To(Kind::Row, e)),
            "pr" => some(self.pr_url.as_deref()).map(Link::Url),
            "ci" => some(self.ci_url.as_deref()).map(Link::Url),
            _ => None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "Overdue" => self.overdue,
            "CI failing" => self.ci_failing(),
            "No session" => self.target.is_none(),
            _ => false,
        }
    }

    /// A bare word searches the title, the slug, the project, the row, the epic and the next phase.
    fn text(&self) -> String {
        let next = self.phases.as_ref().and_then(|p| p.next.as_deref());
        [
            Some(self.title.as_str()),
            Some(self.slug.as_str()),
            Some(self.project.as_str()),
            self.row.as_deref(),
            self.epic.as_deref(),
            next,
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Warn,
    Red,
    #[default]
    Nodata,
}

/// A chip or tile hue on a home row: red, amber, green.
impl From<crate::vocab::Level> for Level {
    fn from(l: crate::vocab::Level) -> Self {
        match l {
            crate::vocab::Level::Bad => Level::Red,
            crate::vocab::Level::Warn => Level::Warn,
            crate::vocab::Level::Ok => Level::Ok,
            crate::vocab::Level::Neutral => Level::Nodata,
        }
    }
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
    /// What only the human can do: the one list and the one count every surface shows.
    #[serde(serialize_with = "need_rows")]
    pub needs: Vec<Need>,
    /// Agent work that Needs you used to list (`Kind::owner`): never counted as a need, kept so the
    /// Main red card and the Queue and Alerts tabs can name what they own.
    #[serde(skip)]
    pub routed: Vec<Need>,
    /// What analysis streams propose, newest first, and their count worded once.
    pub proposals: Vec<Proposal>,
    pub proposals_head: String,
    pub proposals_failed: bool,
    /// No read has answered yet, so nothing can be said about what is open.
    pub proposals_unread: bool,
    /// The fleet's front page, one row per question; None when Prometheus did not answer.
    pub vitals: Option<crate::vitals::Vitals>,
    /// The `cc:domain_status` chips: the briefing's overnight line reads them; the pages show
    /// them on Alerts.
    pub health: Vec<Chip>,
    /// What could not be read, so a short list never reads as an all-clear.
    pub errors: Vec<String>,
}

impl Home {
    /// The chips that are not green: the strip shows only these, and one "all green" line when
    /// there are none (dashboards.md rule 4).
    pub fn exceptions(&self) -> impl Iterator<Item = &Chip> {
        self.health.iter().filter(|c| c.level != Level::Ok)
    }

    /// How many rows Needs you lists, and where they are answered: the one count every badge
    /// and line that says "waiting on you" shows, so none can disagree with the list.
    pub fn waiting(&self) -> Waiting {
        Waiting {
            count: self.needs.len(),
            human: self
                .needs
                .iter()
                .filter(|n| n.score.as_ref().is_none_or(|s| s.human))
                .count(),
            sessions: self
                .needs
                .iter()
                .filter(|n| n.kind == Kind::Session)
                .count(),
            href: crate::links::Link::tab("home").href(),
        }
    }

    /// The kind split of that count, one `(label, rows)` per kind that has rows, in chip order:
    /// the one split every surface words ("33 Question, 6 Blocked").
    pub fn split(&self) -> Vec<(&'static str, usize)> {
        NeedKind::ALL
            .iter()
            .map(|k| {
                (
                    k.label(),
                    self.needs.iter().filter(|n| n.need == *k).count(),
                )
            })
            .filter(|(_, n)| *n > 0)
            .collect()
    }

    /// The Needs you card's parts, one per figure: the kind split, then `ONLY_YOU`, the rows only
    /// the human can answer, counted here once so no reader filters the rows itself (the
    /// shepherd's "N need you", ar-4395). `ONLY_YOU` is always there, 0 included, because a
    /// reader must tell "none" from "not read".
    pub fn parts(&self) -> Vec<(&'static str, usize)> {
        let mut parts = self.split();
        parts.push((ONLY_YOU, self.waiting().human));
        parts
    }
}

/// The Needs you part that counts the rows only the human can answer (`Score::human`): the
/// rows the judge left to a machine are in the headline but not here. A row with no score (a
/// condition: a red, a stopped dispatch hold) is counted, since only a judged ask is ever a
/// machine's; the shepherd's old jq filter dropped them (`null` is not true).
pub const ONLY_YOU: &str = "Only you";

/// The count of Needs you rows and the link that opens them.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Waiting {
    pub count: usize,
    /// How many of those rows only the human can answer (`Score::human`).
    pub human: usize,
    /// How many of those rows are sessions waiting on a dialog: the number on Sessions' tab.
    pub sessions: usize,
    pub href: String,
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
pub(crate) fn day_start(day: &str) -> Option<i64> {
    use chrono::TimeZone;
    let d = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()?;
    chrono::Local
        .from_local_datetime(&d.and_hms_opt(0, 0, 0)?)
        .earliest()
        .map(|t| t.timestamp())
}

/// A tier-3 queue item (tag `tier3`, merging behind the red-fix gate) that finished failed: it ran unattended, so its failure is the human's.
/// A failed one needs the human for a day after it ends; after that the queue holds it.
pub const NIGHT_WINDOW_SECS: i64 = 86_400;

fn pr_item_failed(i: &Item) -> bool {
    i.state == State::Done
        && i.status.as_deref() == Some("failed")
        && i.tag_list().any(|t| t == "tier3")
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

/// The session's PR as (label, page): fleet-sessions writes a bare number for the branch's own PR
/// and `owner/repo#N` for one in another repo. With no session PR, the item's own (`agent-land`'s).
fn pr_of(live: Option<&Value>, item: &Item) -> Option<(String, Option<String>)> {
    let said = live.and_then(|s| match &s["pr"] {
        Value::String(p) if !p.is_empty() && p != "-" => Some(p.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    });
    match said.as_deref().map(|p| p.trim_start_matches('#')) {
        Some(p) if p.contains('#') => crate::queue::pr_link_of(p),
        Some(n) => Some((
            format!("#{n}"),
            crate::session_page::pr_url(n, live, Some(item)),
        )),
        None => item.pr_link(),
    }
}

/// A lower-case session field, None when fleet-sessions could not say (`null`, `-`, `NONE`).
fn said_lower(live: Option<&Value>, k: &str) -> Option<String> {
    let v = live?[k].as_str()?.to_lowercase();
    (!v.is_empty() && v != "-" && v != "none").then_some(v)
}

/// The running queue items, each with its session's plan progress when it has a checklist and
/// the links a row opens: the Queue's running state and each Projects card's in-flight list. `board`
/// gives each row's epic; without it the epic is left blank, never guessed.
pub fn running(state: &Value, q: &Queue, board: Option<&Feed>) -> Vec<Running> {
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
            let live = target
                .as_deref()
                .and_then(|t| sessions.iter().copied().find(|s| str_of(s, "target") == t));
            let phases = target.as_ref().and_then(|t| phases.get(t).cloned());
            let board_row = i.board_row();
            let epic = board_row
                .zip(board)
                .and_then(|((p, id), f)| f.row(p, id)?.parent.clone());
            let area = board_row
                .zip(board)
                .zip(epic.as_deref())
                .and_then(|(((p, _), f), e)| f.row(p, e)?.area.clone());
            let (pr, pr_url) = pr_of(live, i).map_or((None, None), |(l, u)| (Some(l), u));
            let ci = said_lower(live, "ci").filter(|_| pr.is_some());
            Running {
                slug: i.slug.clone(),
                title: i.title(),
                project: i.project.clone(),
                started: i.started.clone(),
                overdue: live.is_some_and(|s| s["overdue"].is_object()),
                phases,
                target,
                row: board_row.map(|(_, id)| id.to_string()),
                epic,
                area,
                ci_url: ci
                    .as_ref()
                    .and(pr_url.as_deref())
                    .and_then(crate::reds::checks_url),
                ci,
                pr_state: said_lower(live, "pr_state").filter(|_| pr.is_some()),
                pr,
                pr_url,
            }
        })
        .collect()
}

/// One pending ask's row: its record rides along as `ask`, the card's source. The waiting queue
/// item it holds (`item`) shows here, first in `holds`, and nowhere else.
fn ask_need(
    a: &Value,
    item: Option<&Item>,
    target: Option<String>,
    since: Option<i64>,
    mut score: Score,
) -> Need {
    if let Some(i) = item.filter(|i| i.state == State::Waiting) {
        score.holding(&i.slug);
    }
    let recommend = str_of(a, "recommend");
    Need {
        kind: Kind::Ask,
        need: NeedKind::Ask,
        rank: 0,
        ask: boards::Ask::deserialize(a).ok(),
        project: str_of(a, "project").into(),
        text: short(str_of(a, "question")),
        id: str_of(a, "id").into(),
        score: Some(score),
        recommend: (!recommend.is_empty()).then(|| recommend.into()),
        target,
        since,
    }
}

/// The waiting item ask `a` holds once its session is gone: the one tagged `ask:<id>`, or the one
/// whose last session is the ask's `claude_session`, unless an ask before it took that item (`asked`).
fn held_item<'a>(items: &[&'a Item], a: &Value, asked: &HashSet<String>) -> Option<&'a Item> {
    let (id, owner) = (str_of(a, "id"), str_of(a, "claude_session"));
    items.iter().copied().find(|i| {
        i.state == State::Waiting
            && !asked.contains(&i.slug)
            && (i.held_on(id) || (!owner.is_empty() && i.last_session() == Some(owner)))
    })
}

/// Each Claude session's latest answer time, from the state's `answered_asks`. An answer whose
/// delivery failed decides nothing yet: a board shows the failed delivery.
fn answered_by_session(state: &Value) -> HashMap<&str, i64> {
    let mut by: HashMap<&str, i64> = HashMap::new();
    for a in state["answered_asks"].as_array().into_iter().flatten() {
        let sid = str_of(a, "claude_session");
        let failed = str_of(a, "delivery") == "failed";
        if let Some(at) = a["answered_at"]
            .as_i64()
            .filter(|_| !sid.is_empty() && !failed)
        {
            by.entry(sid)
                .and_modify(|e| *e = (*e).max(at))
                .or_insert(at);
        }
    }
    by
}

/// The waiting items that have had their decision: each one's last session's ask was answered
/// after its wait began (its `waiting:` stamp, else `started:`), so the resume moves it, not the
/// human. One with no wait start at all is not taken as decided.
fn decided(state: &Value, items: &[&Item]) -> HashSet<String> {
    let answered = answered_by_session(state);
    items
        .iter()
        .filter(|i| i.state == State::Waiting)
        .filter(|i| {
            i.last_session()
                .and_then(|sid| answered.get(sid))
                .is_some_and(|&at| {
                    i.waiting
                        .as_deref()
                        .or(i.started.as_deref())
                        .and_then(ts)
                        .is_some_and(|w| w <= at)
                })
        })
        .map(|i| i.slug.clone())
        .collect()
}

/// NEEDS YOU from fleet-sessions' `state.json` (null when missing), the queue, the board feed and
/// infra (None until read), ranked: the asks, sessions and queue items only the human can act on
/// by what their wait costs (`Score::value`), then the `#urgent` sheet to-dos, then the `#high`
/// ones, each by the same value, then those the judge said a machine could answer, then the conditions:
/// budget stops, failed night items, janitor lines, critical mail, nightly reds and red-now items. A Stopped row, when dispatch is stopped, comes before all of them.
/// This is every kind, unsplit; `build` partitions it by `Kind::owner`. Ages are by the state's own clock, so the order is pure.
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
                        && i.after
                            .as_deref()
                            .is_some_and(|a| a.split_whitespace().any(|s| s == slug))
                })
                .count() as u64
        })
    };
    let mut out = hold_needs(state); // the first conditions: the sort keeps their push order
    let mut shown: HashSet<String> = HashSet::new();
    // The slugs of the queue items an ask already stands for: an answered one (`decided`), or a
    // pending one by its live owner, its `task` or its hold (`held_item`).
    let mut asked: HashSet<String> = decided(state, &items);
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
            ask: None,
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
        // Only the asking session owns an ask: its row is the one whose session_id is the ask's
        // claude_session. The tmux name is no fallback, since a name outlives its session (a
        // reboot) and a later session reuses it; an ask with no live owner blocks no session.
        let owner = str_of(a, "claude_session");
        let row = sessions
            .iter()
            .find(|s| !owner.is_empty() && str_of(s, "session_id") == owner);
        let target = row.map(|s| str_of(s, "target").to_string());
        let session = row.map_or("", |s| tmux_name(str_of(s, "target")));
        if !session.is_empty() {
            shown.insert(session.to_string());
        }
        let since = a["created"].as_i64();
        // An ask's `task` is its queue item's slug, which for an item promoted from the board
        // is the row's id.
        let task = str_of(a, "task");
        if !task.is_empty() {
            worked.insert(format!("{}:{task}", str_of(a, "project")));
        }
        // Its queue item: the live owner's, else the one its `task` names, else the waiting one it
        // holds (`held_item`), so an ask whose owner died still stands for it: one decision, one row.
        let by_task = items.iter().copied().find(|i| i.slug == task);
        work(&mut worked, by_task);
        let item = item_of(session)
            .or(by_task)
            .or_else(|| held_item(&items, a, &asked));
        work(&mut worked, item);
        asked.extend(item.map(|i| i.slug.clone()));
        let score = Score::new(
            !machine_can_answer(str_of(a, "kind"), str_of(a, "judge")),
            target.is_some(),
            left(target.as_ref()),
            dependents(item.map(|i| i.slug.as_str())),
            age_min(since),
        );
        out.push(ask_need(a, item, target, since, score));
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
            ask: None,
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
        if asked.contains(&i.slug)
            || i.session
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
            ask: None,
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
            ask: None,
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
        ask: None,
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
    for i in items.iter().filter(|i| pr_item_failed(i) && recent(i)) {
        out.push(Need {
            project: i.project.clone(),
            ..condition(
                Kind::Night,
                i.slug.clone(),
                format!(
                    "Tier-3 task {} failed: {}. Run agent-queue show {}.",
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
            ask: None,
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
                ask: None,
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
                .map(|s| (!s.human, s.tier(), std::cmp::Reverse(s.value))),
        )
    });
    for (i, n) in out.iter_mut().enumerate() {
        n.rank = i + 1;
    }
    out
}

/// `needs`' rows split by `Kind::owner`: the human's, then the agent work, each ranked from 1 in
/// the order it came, so a view's rank column never shows a gap.
fn by_owner(all: Vec<Need>) -> (Vec<Need>, Vec<Need>) {
    let (mut human, mut agent): (Vec<Need>, Vec<Need>) = all
        .into_iter()
        .partition(|n| n.kind.owner() == Owner::Human);
    for list in [&mut human, &mut agent] {
        for (i, n) in list.iter_mut().enumerate() {
            n.rank = i + 1;
        }
    }
    (human, agent)
}

impl Home {
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

/// The Hold rows of `state["holds"]` (`signals::join`: the standing holds the human set), one a
/// hold, as conditions with no score.
fn hold_needs(state: &Value) -> Vec<Need> {
    let rows = state["holds"].as_array().into_iter().flatten();
    rows.map(|h| {
        let resource = str_of(h, "resource");
        Need {
            kind: Kind::Hold,
            need: NeedKind::of_condition(Kind::Hold),
            rank: 0,
            ask: None,
            project: String::new(),
            text: short(&format!(
                "Hold {resource}, {}: {}. Release it once its work is done: agent-hold release {resource} (agent-hold show {resource}).",
                str_of(h, "held"),
                str_of(h, "reason").trim_end_matches('.')
            )),
            id: format!("hold:{resource}"),
            target: None,
            since: h["since"].as_i64(),
            recommend: None,
            score: None,
        }
    })
    .collect()
}

/// Home from fleet-sessions' `state.json` (null when missing), the queue, the board feed,
/// and infra: NEEDS YOU in `needs` order, the vitals and the chips.
pub fn build(
    state: Option<&Value>,
    queue: Option<&Queue>,
    board: Option<&Result<Feed, String>>,
    infra: Option<&Infra>,
    now: i64,
) -> Home {
    let mut h = Home::default();
    // None is a read still on its way: that is reading, not "no fleet state yet" (ar-919).
    match state.map(|s| match s {
        Value::Null => Reading::Never,
        _ => Reading::of_age(s["generated_epoch"].as_i64(), now, FLEET_STATE_STALE_SECS),
    }) {
        None => h.errors.push("fleet state: reading".into()),
        Some(Reading::Live) => {}
        Some(r) => h.errors.push(format!(
            "{} (fleet-state.timer writes it every minute)",
            r.words("fleet state")
        )),
    }
    let state = state.unwrap_or(&Value::Null);
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
            "holds" => "no standing holds are shown",
            _ => continue,
        };
        h.errors.push(format!("{u} could not be read, so {what}"));
    }
    if let Some(Err(e)) = board {
        h.errors
            .push(format!("{e}, so no human-sheet rows are shown"));
    }
    (h.needs, h.routed) = by_owner(needs(
        state,
        queue,
        board.and_then(|b| b.as_ref().ok()),
        infra,
    ));
    if let Some(q) = queue {
        h.errors.extend(q.errors.iter().cloned());
    }

    match infra {
        None => h.errors.push("Prometheus: reading".into()),
        Some(i) if !i.ok => h.errors.push(format!(
            "Prometheus: {}",
            i.error.as_deref().unwrap_or("did not answer")
        )),
        Some(i) => {
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

    #[test]
    fn an_ask_row_keeps_the_state_documents_audit_of_for_the_pager() {
        let row = |a: Value| ask_need(&a, None, None, None, Score::new(true, true, 0, 0, 120));
        let audit = row(json!({"id": "au", "project": "p", "question": "q?", "audit_of": "q1"}));
        assert_eq!(audit.ask.unwrap().audit_of, "q1");
        let plain = row(json!({"id": "a1", "project": "p", "question": "q?"}));
        assert_eq!(plain.ask.unwrap().audit_of, "");
    }

    /// `build` with every kind in `needs`, for the tests of the ranking and the rows themselves;
    /// `build` alone moves the agent kinds to `routed` (`Kind::owner`).
    fn build_all(
        state: Option<&Value>,
        queue: Option<&Queue>,
        board: Option<&Result<Feed, String>>,
        infra: Option<&Infra>,
        now: i64,
    ) -> Home {
        let mut h = build(state, queue, board, infra, now);
        h.needs = needs(
            state.unwrap_or(&Value::Null),
            queue,
            board.and_then(|b| b.as_ref().ok()),
            infra,
        );
        h
    }

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
                {"target": "lab/repo-agent-1:1", "session_id": "sid-1", "bucket": "NEEDS", "asks": 1, "idle_min": 5, "cwd": "/w/repo", "project": "repo"},
                {"target": "hub/dotfiles:2", "bucket": "NEEDS", "asks": 0, "idle_min": 3,
                 "cwd": "/home/k/.dotfiles", "project": "dotfiles", "reason": "waiting on a prompt or permission"},
                {"target": "lab/repo-agent-2:1", "bucket": "WORKING", "phases_done": 2,
                 "phases_total": 4, "next_phase": "three"},
            ],
            "asks": [
                {"id": "a1", "project": "repo", "question": "Which one?\nmore", "session": "repo-agent-1",
                 "claude_session": "sid-1", "created": 1793894400},
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
        st["holds"] = json!([{"resource": "critical", "since": NOW - 2 * 86400,
            "held": "held 2d by human", "reason": "lockdown."}]);
        st["mail"] = json!([{"from": "alarm@aws", "subject": "ALARM: 5xx", "acct": "gigantic", "copies": 5}]);
        let mut failed = item("night-1", State::Done, None);
        failed.tags = "tier3".into();
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
        let h = build_all(Some(&st), Some(&q), None, None, NOW);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        assert_eq!(
            rows,
            [
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Hold, "hold:critical"),
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
            text(Kind::Hold),
            "Hold critical, held 2d by human: lockdown. Release it once its work is done: agent-hold release critical (agent-hold show critical)."
        );
        assert_eq!(
            text(Kind::Night),
            "Tier-3 task night-1 failed: Do night-1. Run agent-queue show night-1."
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
            .filter(|n| n.kind >= Kind::Hold)
            .all(|n| n.score.is_none()));
        // A budget stop waits on a raise and a hold on its release, so both filter as Blocked; the
        // rest as Failing.
        let need = |k: Kind| h.needs.iter().find(|n| n.kind == k).unwrap().need;
        assert_eq!(need(Kind::Budget), NeedKind::Blocked);
        assert_eq!(need(Kind::Hold), NeedKind::Blocked);
        // The human's hold stays in Needs you, not routed (`build` alone).
        assert!(build(Some(&st), Some(&q), None, None, NOW)
            .needs
            .iter()
            .any(|n| n.kind == Kind::Hold));
        for k in [Kind::Night, Kind::Janitor, Kind::Mail] {
            assert_eq!(need(k), NeedKind::Red, "{k:?}");
        }
    }

    #[test]
    fn an_unreadable_signal_source_is_said_not_shown_as_nothing() {
        let mut st = state();
        st["unreadable"] = json!(["comms", "notes", "agentctl", "something-else"]);
        let h = build(Some(&st), None, None, None, NOW);
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
    fn a_waiting_item_an_ask_holds_shows_once_under_the_ask() {
        // The asker ended: no live owner and no `task`, as an ask filed from a dispatched session.
        let mut st = state();
        st["asks"][0]["claude_session"] = json!("sid-gone");
        let mut by_session = item("held", State::Waiting, Some("lab:repo-agent-9"));
        by_session
            .extra
            .insert("sessions".into(), json!("sid-old sid-gone"));
        let q = Queue {
            items: vec![by_session.clone()],
            ..Default::default()
        };
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(!h.needs.iter().any(|n| n.kind == Kind::Queue));
        let ask = h.needs.iter().find(|n| n.id == "a1").unwrap();
        assert_eq!(ask.holds_line(), "holds held");
        // Its `ask:<id>=<options>` tag holds it the same way, whatever sessions it ran in.
        let mut by_tag = item("held", State::Waiting, None);
        by_tag.tags = "tier2 ask:a1=retry".into();
        let q = Queue {
            items: vec![by_tag],
            ..Default::default()
        };
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(!h.needs.iter().any(|n| n.kind == Kind::Queue));
        // Negative controls: an item resumed in a later session waits on that one, not the ask,
        let mut resumed = by_session.clone();
        resumed
            .extra
            .insert("sessions".into(), json!("sid-gone sid-later"));
        let q = Queue {
            items: vec![resumed],
            ..Default::default()
        };
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(h
            .needs
            .iter()
            .any(|n| n.kind == Kind::Queue && n.id == "held"));
        // and an item another session ran in is its own row.
        by_session
            .extra
            .insert("sessions".into(), json!("sid-other"));
        let q = Queue {
            items: vec![by_session],
            ..Default::default()
        };
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(h
            .needs
            .iter()
            .any(|n| n.kind == Kind::Queue && n.id == "held"));
        assert_eq!(
            h.needs.iter().find(|n| n.id == "a1").unwrap().holds_line(),
            ""
        );
    }

    #[test]
    fn an_answered_asks_waiting_item_leaves_needs_you() {
        let mut st = state();
        st["asks"] = json!([]);
        st["answered_asks"] =
            json!([{"id": "x", "claude_session": "sid-x", "answered_at": NOW - 600}]);
        let mut done = item("decided", State::Waiting, Some("lab:repo-agent-9"));
        done.extra.insert("sessions".into(), json!("sid-x"));
        // No `waiting:` stamp: it waits since it started, before the answer.
        done.started = Some("2026-11-05T16:00:00Z".into()); // NOW - 3600
        let shown = |q: Item, st: &Value| {
            let q = Queue {
                items: vec![q],
                ..Default::default()
            };
            build(Some(st), Some(&q), None, None, NOW)
                .needs
                .iter()
                .any(|n| n.id == "decided")
        };
        assert!(!shown(done.clone(), &st));
        // Negative controls: an answer whose delivery failed decides nothing yet,
        let mut failed = st.clone();
        failed["answered_asks"][0]["delivery"] = json!("failed");
        assert!(shown(done.clone(), &failed));
        // and an item with no wait start at all is not taken as decided.
        let mut unknown = done.clone();
        unknown.started = None;
        assert!(shown(unknown, &st));
        // Negative control: it began waiting again after the answer, so it waits on something new.
        let mut again = done.clone();
        again.waiting = Some("2026-11-05T16:55:00Z".into()); // NOW - 300
        assert!(shown(again, &st));
        // And an answer to an earlier session of it decides nothing for the last one.
        done.extra.insert("sessions".into(), json!("sid-x sid-y"));
        assert!(shown(done, &st));
    }

    #[test]
    fn an_ask_finds_its_session_by_claude_session_never_by_name() {
        // Negative control: the same fixture with the ask's owner dead. The name still matches a
        // live row (a later session reused it), and the ask holds nothing.
        let mut st = state();
        st["asks"][0]["claude_session"] = json!("sid-dead");
        let h = build(Some(&st), None, None, None, NOW);
        let ask = h.needs.iter().find(|n| n.kind == Kind::Ask).unwrap();
        assert_eq!(ask.target, None);
        assert!(!ask.score.as_ref().unwrap().session);
        // The reused name's own session still needs the human, as its own row.
        assert!(h
            .needs
            .iter()
            .any(|n| n.kind == Kind::Session && n.id == "lab/repo-agent-1:1"));
        // The queue item waiting on the dead asker is still the ask's own, so it is no second row.
        st["asks"][0]["task"] = json!("asked");
        let q = Queue {
            items: vec![item("asked", State::Waiting, Some("lab:repo-agent-1"))],
            ..Default::default()
        };
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(!h
            .needs
            .iter()
            .any(|n| n.kind == Kind::Queue && n.id == "asked"));
        // An ask with no owner (headless) blocks no session either.
        st["asks"][0]["claude_session"] = Value::Null;
        let h = build(Some(&st), None, None, None, NOW);
        assert_eq!(
            h.needs.iter().find(|n| n.kind == Kind::Ask).unwrap().target,
            None
        );
        // And the live owner's id finds it whatever name the ask recorded.
        st["asks"][0]["claude_session"] = json!("sid-1");
        st["asks"][0]["session"] = json!("alGRvp");
        let h = build(Some(&st), None, None, None, NOW);
        let ask = h.needs.iter().find(|n| n.kind == Kind::Ask).unwrap();
        assert_eq!(ask.target.as_deref(), Some("lab/repo-agent-1:1"));
        assert!(!h
            .needs
            .iter()
            .any(|n| n.kind == Kind::Session && n.id == "lab/repo-agent-1:1"));
    }

    #[test]
    fn a_row_carries_its_label_holds_and_kind_words_and_an_ask_row_its_whole_record() {
        let h = build_all(Some(&state()), None, None, None, NOW);
        let rows = serde_json::to_value(&h).unwrap()["needs"].clone();
        let by = |id: &str| {
            rows.as_array()
                .unwrap()
                .iter()
                .find(|n| n["id"] == id)
                .unwrap()
                .clone()
        };
        let ask = by("a1");
        assert_eq!(
            (ask["label"].as_str(), ask["what"].as_str()),
            (Some("Question"), Some(""))
        );
        assert_eq!(
            ask["ask"]["id"], "a1",
            "the row holds the record its card draws"
        );
        assert_eq!(ask["ask"]["claude_session"], "sid-1");
        let nightly = by("repo");
        assert_eq!(
            (nightly["label"].as_str(), nightly["what"].as_str()),
            (Some("Failing"), Some("nightly failed"))
        );
        assert!(nightly.get("ask").is_none());
        assert_eq!(by("hub/dotfiles:2")["label"], "Your turn");
    }

    #[test]
    fn the_waiting_count_is_what_needs_you_lists_and_links_home() {
        let h = build(Some(&state()), None, None, None, NOW);
        let w = h.waiting();
        assert_eq!(w.count, h.needs.len());
        assert_eq!(
            w.sessions,
            h.needs.iter().filter(|n| n.kind == Kind::Session).count()
        );
        assert!(
            w.sessions > 0 && w.sessions < w.count,
            "the split is a part of the count"
        );
        assert_eq!(w.href, crate::links::Link::tab("home").href());
        assert_eq!(build(None, None, None, None, NOW).waiting().count, 0);
    }

    #[test]
    fn a_rows_holds_line_says_what_it_holds_and_a_priority_alone_is_just_the_tag() {
        let mut h = build_all(Some(&state()), None, None, None, NOW);
        h.needs[0].score = Some(Score {
            holds: "session, 2 queued".into(),
            ..Default::default()
        });
        h.needs[1].score = Some(Score {
            priority: Some("high".into()),
            ..Default::default()
        });
        h.needs[2].score = None;
        let v = serde_json::to_value(&h).unwrap();
        let row = |i: usize| {
            (
                v["needs"][i]["holds"].as_str(),
                v["needs"][i]["holds_line"].as_str(),
            )
        };
        assert_eq!(
            row(0),
            (Some("session, 2 queued"), Some("holds session, 2 queued"))
        );
        assert_eq!(row(1), (Some("#high"), Some("#high")));
        assert_eq!(row(2), (Some(""), Some("")));
    }
    #[test]
    fn a_dialog_is_tagged_with_the_kind_and_label_a_row_of_it_has() {
        assert_eq!(NeedKind::of_dialog("choice").tag().label, "Question");
        assert_eq!(NeedKind::of_dialog("tool").tag().label, "Permission");
        assert_eq!(NeedKind::of_dialog("plan").tag().label, "Plan to approve");
        assert_eq!(NeedKind::of_dialog("text").tag().kind, NeedKind::Turn);
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
        let h = build_all(Some(&state()), Some(&q), None, None, NOW);
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
        let run = running(&state(), &q, None);
        assert_eq!(run.len(), 1);
        let p = run[0].phases.as_ref().unwrap();
        assert_eq!((p.done, p.total), (2, 4));
        assert_eq!(h.errors, ["Prometheus: reading"]);
    }

    #[test]
    fn a_running_row_carries_its_board_row_epic_pr_and_ci_and_sorts_and_filters() {
        let mut st = state();
        let s = &mut st["sessions"][2];
        s["eta_epoch"] = json!(NOW - 60);
        s["overdue"] = json!({"phase": "phase 3/4", "age_min": 90, "expected_min": 40});
        s["pr"] = json!("12");
        s["pr_state"] = json!("OPEN");
        s["ci"] = json!("FAIL");
        s["prs"] = json!([{"repo": "o/r", "number": 12, "state": "OPEN"}]);
        // Promoted from a row (`from: board:`), with the row's epic on the board.
        let mut busy = item("busy", State::Running, Some("lab:repo-agent-2"));
        busy.from = Some("board:Trader:tr-9".into());
        // No session: its PR is its own, a Forgejo one with no checks page, and no CI is said.
        let mut lone = item("lone", State::Running, None);
        lone.row = Some("trader:tr-50".into());
        lone.pr = Some("https://forge.example.internal/k/r/pulls/3".into());
        let q = Queue {
            items: vec![busy, lone],
            ..Default::default()
        };
        let mut feed = board().unwrap();
        feed.rows
            .iter_mut()
            .find(|r| r.id.as_deref() == Some("tr-9"))
            .unwrap()
            .parent = Some("tr-1".into());
        // The epic's own row names its system, the area the chip groups running work by.
        let mut epic = sheet("tr-1", "agent", "epic", "high", "2026-11-01");
        epic.area = Some("data".into());
        feed.rows.push(epic);
        let run = running(&st, &q, Some(&feed));
        let r = &run[0];
        assert_eq!(r.area.as_deref(), Some("data"));
        assert_eq!(
            (
                r.row.as_deref(),
                r.epic.as_deref(),
                r.pr.as_deref(),
                r.pr_url.as_deref()
            ),
            (
                Some("tr-9"),
                Some("tr-1"),
                Some("#12"),
                Some("https://github.com/o/r/pull/12")
            )
        );
        assert_eq!(
            (
                r.pr_state.as_deref(),
                r.ci.as_deref(),
                r.ci_url.as_deref(),
                r.overdue
            ),
            (
                Some("open"),
                Some("fail"),
                Some("https://github.com/o/r/pull/12/checks"),
                true
            )
        );
        let l = &run[1];
        assert_eq!(
            (l.row.as_deref(), l.epic.as_deref(), l.area.as_deref()),
            (Some("tr-50"), None, None),
            "a row under no epic has no area, never its own scope"
        );
        assert_eq!(
            (l.pr.as_deref(), l.ci.as_deref(), l.ci_url.as_deref()),
            (Some("#3"), None, None)
        );
        assert!(!l.overdue && l.target.is_none());
        // Without the board the epic is blank, never guessed; the rest still joins.
        let bare = running(&st, &q, None);
        assert_eq!(
            (
                bare[0].epic.as_deref(),
                bare[0].area.as_deref(),
                bare[0].row.as_deref()
            ),
            (None, None, Some("tr-9"))
        );
        // Overdue is fleet-sessions' verdict, never a past ETA against a clock of Home's own.
        let mut calm = st.clone();
        calm["sessions"][2]["overdue"] = Value::Null;
        assert!(
            !running(&calm, &q, None)[0].overdue,
            "a past ETA with no verdict is on time"
        );
        // A verdict on a session with no checklist (the one running another plan's phase) still counts.
        let mut runner = calm.clone();
        for k in ["phases_total", "phases_done", "eta_epoch"] {
            runner["sessions"][2][k] = Value::Null;
        }
        runner["sessions"][2]["overdue"] = json!({"phase": "phase 2/3", "age_min": 70});
        let r = &running(&runner, &q, None)[0];
        assert!(
            r.overdue && r.phases.is_none(),
            "the verdict is read from the row"
        );
        let shown = |q: &str, s: &str| -> Vec<String> {
            crate::table::View::new::<Running>(q, s, "", "")
                .apply(&run)
                .iter()
                .map(|r| r.slug.clone())
                .collect()
        };
        assert_eq!(shown("", "CI failing"), ["busy"]);
        assert_eq!(shown("", "No session"), ["lone"]);
        assert_eq!(shown("", "Overdue"), ["busy"]);
        assert_eq!(shown("epic:tr-1", ""), ["busy"]);
        assert_eq!(shown("tr-50", ""), ["lone"]);
        // Each cell that names a record links its one page (hub_core::links), sent beside the rows.
        let (_, t) = crate::table::View::default().summary(&run);
        let at = |i: usize, c: &str| t.links[i].get(c).map(String::as_str);
        assert_eq!(
            (at(0, "item"), at(0, "project"), at(0, "row"), at(0, "epic")),
            (
                Some("#sessions/sessions/lab%2Frepo-agent-2%3A1"),
                Some("#projects/p"),
                Some("#projects/all?q=id:=tr-9"),
                Some("#projects/all?q=id:=tr-1")
            )
        );
        assert_eq!(
            (at(0, "pr"), at(0, "ci"), at(0, "phase")),
            (
                Some("https://github.com/o/r/pull/12"),
                Some("https://github.com/o/r/pull/12/checks"),
                None
            )
        );
        // No session: the item opens its queue record, and a CI never read links nothing.
        assert_eq!(
            (at(1, "item"), at(1, "epic"), at(1, "ci")),
            (Some("#queue/lone"), None, None)
        );
    }

    #[test]
    fn an_unreadable_agent_ask_is_said_not_shown_as_no_asks() {
        let mut st = state();
        st["asks"] = json!([]);
        st["unreadable"] = json!(["agent-ask"]);
        let h = build(Some(&st), None, None, None, NOW);
        assert!(h.errors.iter().any(|e| e.contains("agent-ask")));
        let ok = build(Some(&state()), None, None, None, NOW);
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
             "recommend": "yes", "created": 1793034000},
            // An approval is the human's whatever the judge said.
            {"id": "appr", "question": "q", "kind": "approval", "judge": "take-recommend",
             "created": 1793897400},
            // A gate is judged like a question: below every human row too.
            {"id": "gate", "question": "q", "kind": "gate", "judge": "take-recommend",
             "recommend": "approve", "created": 1793120400},
            {"id": "old", "question": "q", "created": 1793894400},
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
        let h = build(Some(&st), Some(&q), None, None, NOW);
        let ids: Vec<&str> = h.needs.iter().map(|n| n.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "lab/big-agent-1:1",
                "old",
                "parent",
                "appr",
                "undated",
                "auto",
                "gate"
            ]
        );
        // Only you is the part the shepherd's settle page reads: the 7 rows less the 2 the judge
        // left to a machine, so no reader filters the rows itself.
        assert_eq!((h.waiting().count, h.waiting().human), (7, 5));
        assert_eq!(h.parts().last(), Some(&(ONLY_YOU, 5)));
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
    }

    #[test]
    fn conditions_follow_every_scored_row_and_carry_no_score() {
        let i = infra(vec![], &["watch:a"]);
        let h = build_all(Some(&state()), None, None, Some(&i), NOW);
        let kinds: Vec<Kind> = h.needs.iter().map(|n| n.kind).collect();
        assert_eq!(kinds, [Kind::Ask, Kind::Session, Kind::Nightly, Kind::Red]);
        assert!(h.needs[2..].iter().all(|n| n.score.is_none()));
        // An ask from the future (a skewed clock) waits zero minutes, never negative.
        let mut st = state();
        st["asks"][0]["created"] = json!(1793984400);
        assert_eq!(
            score(&build_all(Some(&st), None, None, None, NOW).needs[1]).4,
            0
        );
    }

    #[test]
    fn a_stopped_dispatch_leads_needs_you_as_one_unscored_line() {
        let mut st = state();
        st["stopped"] = json!([{"runner": "fleet-dispatch", "since": NOW - 13 * 3600,
            "why": "no account has room",
            "line": "Dispatch stopped 13h: no account has room. Clears when an account is back under its pace."}]);
        let h = build_all(Some(&st), None, None, None, NOW);
        let top = &h.needs[0];
        assert_eq!(top.kind, Kind::Stopped);
        assert_eq!(top.id, "stopped:fleet-dispatch");
        assert!(top.text.starts_with("Dispatch stopped 13h: "));
        assert_eq!(top.since, Some(NOW - 13 * 3600));
        assert!(top.score.is_none());
        assert_eq!(serde_json::to_value(top).unwrap()["kind"], "stopped");
        // The rest keep their order; with no hold there is no Stopped row.
        assert_eq!(h.needs[1].kind, Kind::Ask);
        assert!(build_all(Some(&state()), None, None, None, NOW)
            .needs
            .iter()
            .all(|n| n.kind != Kind::Stopped));
    }

    /// A state with a stopped dispatch, a failed Tier-3 task, a red-now watch and the red nightly
    /// `state()` carries: one row of every kind that is agent work.
    fn agent_work() -> (Value, Queue, Infra) {
        let mut st = state();
        st["stopped"] = json!([{"runner": "fleet-dispatch", "since": NOW - 3600,
            "why": "no account has room", "line": "Dispatch stopped 1h: no account has room."}]);
        let mut failed = item("night-1", State::Done, None);
        failed.tags = "tier3".into();
        failed.status = Some("failed".into());
        failed.finished = Some("2026-11-05T03:00:00-0800".into());
        let q = Queue {
            items: vec![failed],
            ..Default::default()
        };
        (st, q, infra(vec![], &["watch:a"]))
    }

    #[test]
    fn every_kind_has_one_owner_and_the_agent_kinds_are_exactly_these() {
        let agent = [Kind::Night, Kind::Red, Kind::Nightly, Kind::Stopped];
        let human = [
            Kind::Ask,
            Kind::Session,
            Kind::Queue,
            Kind::Sheet,
            Kind::Budget,
            Kind::Janitor,
            Kind::Mail,
        ];
        assert!(agent.iter().all(|k| k.owner() == Owner::Agent));
        assert!(human.iter().all(|k| k.owner() == Owner::Human));
    }

    #[test]
    fn a_failed_tier3_task_is_routed_not_needed() {
        let (st, q, _) = agent_work();
        let h = build(Some(&st), Some(&q), None, None, NOW);
        assert!(h.needs.iter().all(|n| n.kind != Kind::Night));
        assert!(h
            .routed
            .iter()
            .any(|n| n.kind == Kind::Night && n.id == "night-1"));
    }

    #[test]
    fn a_red_now_item_is_routed_not_needed() {
        let (st, _, i) = agent_work();
        let h = build(Some(&st), None, None, Some(&i), NOW);
        assert!(h.needs.iter().all(|n| n.kind != Kind::Red));
        let red: Vec<&str> = h
            .routed
            .iter()
            .filter(|n| n.kind == Kind::Red)
            .map(|n| n.text.as_str())
            .collect();
        assert_eq!(red, ["watch:a"]);
    }

    #[test]
    fn a_red_nightly_is_routed_and_still_names_main_red() {
        let h = build(Some(&state()), None, None, None, NOW);
        assert!(h.needs.iter().all(|n| n.kind != Kind::Nightly));
        assert_eq!(crate::phone::red_repos(&h).len(), 1);
    }

    #[test]
    fn a_stopped_dispatch_is_routed_not_needed() {
        let (st, _, _) = agent_work();
        let h = build(Some(&st), None, None, None, NOW);
        assert!(h.needs.iter().all(|n| n.kind != Kind::Stopped));
        assert_eq!(h.routed[0].kind, Kind::Stopped);
    }

    #[test]
    fn needs_you_lists_only_what_the_human_owns_and_ranks_from_one() {
        let (st, q, i) = agent_work();
        let h = build(Some(&st), Some(&q), None, Some(&i), NOW);
        assert!(h.needs.iter().all(|n| n.kind.owner() == Owner::Human));
        assert!(h.routed.iter().all(|n| n.kind.owner() == Owner::Agent));
        let ranks: Vec<usize> = h.needs.iter().map(|n| n.rank).collect();
        assert_eq!(ranks, (1..=h.needs.len()).collect::<Vec<_>>());
        // The count is the list, and the split sums to it.
        assert_eq!(h.waiting().count, h.needs.len());
        assert_eq!(
            h.split().iter().map(|(_, n)| n).sum::<usize>(),
            h.needs.len()
        );
        // Negative control: the unfiltered list is longer, so a surface counting it would differ.
        assert!(
            build_all(Some(&st), Some(&q), None, Some(&i), NOW)
                .needs
                .len()
                > h.needs.len()
        );
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
                // A #normal row and an untagged one wait on the sheet, like a #low one.
                sheet("tr-120", "human", "run", "normal", "2026-10-20"),
                sheet("tr-121", "human", "run", "", "2026-10-20"),
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
    fn live_waits_lead_then_sheet_to_dos_by_priority_then_their_wait() {
        let mut asked = item("asked", State::Waiting, Some("lab:repo-agent-1"));
        asked.row = Some("trader:tr-51".into());
        let q = Queue {
            items: vec![asked],
            ..Default::default()
        };
        let h = build_all(Some(&state()), Some(&q), Some(&board()), None, NOW);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        // The #urgent row has waited longer than the ask, but every live wait leads: it stops
        // running work and a to-do does not. The #high row follows the #urgent one; the older
        // normal one waits on the sheet; conditions stay last.
        assert_eq!(
            rows,
            [
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Sheet, "tr-50"),
                (Kind::Sheet, "tr-117"),
                (Kind::Nightly, "repo"),
            ]
        );
        let top = &h.needs[2];
        let age = (NOW - day_start("2026-11-04").unwrap()) / 60;
        assert!(age > 60 * 24, "a day-old row waits more than a day: {age}");
        assert_eq!(score(top), (true, false, 0, 0, age, age));
        assert_eq!(top.project, "trader");
        assert_eq!(top.text, "run(markets): do tr-50 #urgent");
        let json = serde_json::to_value(top).unwrap();
        assert_eq!(json["kind"], "sheet");
        assert_eq!(json["score"]["priority"], "urgent");
        assert!(serde_json::to_value(&h.needs[0]).unwrap()["score"]
            .get("priority")
            .is_none());
        // With no board read there are no sheet rows, and nothing else moves.
        let without: Vec<Kind> = build_all(Some(&state()), Some(&q), None, None, NOW)
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
        let ids: Vec<String> = build(Some(&st), None, Some(&board()), None, NOW)
            .needs
            .into_iter()
            .filter(|n| n.kind == Kind::Sheet)
            .map(|n| n.id)
            .collect();
        assert_eq!(ids, ["tr-51", "tr-117"]);
        let h = build(
            Some(&state()),
            None,
            Some(&Err("notes board --json: boom".into())),
            None,
            NOW,
        );
        assert!(h
            .errors
            .iter()
            .any(|e| e.starts_with("notes board --json: boom")));
        assert!(h.needs.iter().all(|n| n.kind != Kind::Sheet));
    }

    #[test]
    fn health_keeps_the_known_domains_and_red_now_items_are_needs() {
        let i = infra(
            vec![domain("ci", "1"), domain("prod", "0")],
            &["watch:b", "watch:a"],
        );
        let h = build_all(Some(&Value::Null), None, None, Some(&i), NOW);
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
                ("projects", Level::Nodata),
                ("prod", Level::Ok)
            ]
        );
        assert_eq!(h.exceptions().count(), 3);
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
        let h = build(Some(&state()), None, None, Some(&i), NOW);
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
        let mut h = build(Some(&state()), None, None, None, NOW);
        h.set_proposals(&Ok(vec![p.clone()]));
        assert_eq!(h.proposals, [p]);
        assert_eq!(h.proposals_head, "1 from 1 stream");
        let mut h = build(Some(&state()), None, None, None, NOW);
        h.set_proposals(&Err("no jq".into()));
        assert!(h.proposals_failed);
        assert!(h
            .errors
            .iter()
            .any(|e| e == "no jq, so no proposals are shown"));
    }

    #[test]
    fn the_stale_age_is_the_confs_number() {
        let conf = "# FLEET_STATE_STALE_SECS=1\nOTHER_FLEET_STATE_STALE_SECS=2\nFLEET_STATE_STALE_SECS=42\n";
        assert_eq!(conf_number(conf, "FLEET_STATE_STALE_SECS"), 42);
        let shipped = include_str!("../../../../.config/fleet-sessions/state.conf");
        let line = shipped
            .lines()
            .find_map(|l| l.strip_prefix("FLEET_STATE_STALE_SECS="))
            .unwrap();
        assert_eq!(FLEET_STATE_STALE_SECS, line.parse::<i64>().unwrap());
    }

    #[test]
    #[should_panic(expected = "alone on its line")]
    fn a_conf_number_with_text_after_it_stops_the_build() {
        conf_number(
            "FLEET_STATE_STALE_SECS=300 # note\n",
            "FLEET_STATE_STALE_SECS",
        );
    }

    #[test]
    fn an_old_or_missing_fleet_state_says_so_and_a_fresh_one_says_nothing() {
        let said = |st: &Value| {
            build(Some(st), None, None, None, NOW)
                .errors
                .into_iter()
                .filter(|e| e.contains("fleet state"))
                .collect::<Vec<_>>()
        };
        assert!(said(&state()).is_empty());
        assert_eq!(
            said(&Value::Null),
            ["no fleet state yet (fleet-state.timer writes it every minute)"]
        );
        let mut old = state();
        old["generated_epoch"] = json!(NOW - FLEET_STATE_STALE_SECS - 1);
        let e = said(&old);
        assert!(
            e.len() == 1 && e[0].starts_with("fleet state stopped reporting at "),
            "{e:?}"
        );
        // a read still on its way is reading, never "no fleet state yet" (ar-919)
        let errs = build(None, None, None, None, NOW).errors;
        assert!(
            errs.contains(&"fleet state: reading".to_string()),
            "{errs:?}"
        );
        assert!(
            !errs.iter().any(|e| e.contains("no fleet state")),
            "{errs:?}"
        );
        // a state with no time at all cannot be judged fresh
        let mut undated = state();
        undated.as_object_mut().unwrap().remove("generated_epoch");
        assert_eq!(said(&undated).len(), 1);
    }
}
