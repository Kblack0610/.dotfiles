//! The Projects tab for both surfaces: one card per lab project with its release window's score
//! (delivered of committed rows, and the due day), its pace, and what is in flight on it. Every
//! number is counted, never judged: `notes projects --stats --json` counts the rows and the
//! window, this module does the arithmetic. A project with no window snapshot says `no window`,
//! never a percent of its whole backlog.
//!
//! Queue items name a REPO-side project (`dotfiles`) while cards are LAB projects
//! (`agent-runtime`, `notes-cockpit`). An item joins a card by its ledger `row:`
//! (`<lab>:<id>`), else by a project name both share. Anything else is listed as unlinked, not
//! guessed at.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::display::{Fact, Shown};
use crate::home::{self, Running};
use crate::links::{Kind, Link};
use crate::queue::{Item, Queue, State};
use crate::session_actions::Runner;
use crate::table::Val;
use crate::tasks::Feed;
use crate::vocab::Level;

/// The open version's rows and closes, as notes-cli counts them (`Progress` there).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Progress {
    pub open: u32,
    pub done: u32,
    pub open_weight: u32,
    pub done_weight: u32,
    pub closed_7d: u32,
    pub closed_28d: u32,
    pub closed_weight_7d: u32,
    pub closed_weight_28d: u32,
    /// The day of the newest close, `YYYY-MM-DD`; None with none. [`state`] reads it against
    /// `Stats::idle_days`.
    pub last_closed: Option<String>,
    /// The weight of this version's rows filed in the last 28 days: the scope growth the
    /// version ETA nets out of the close rate.
    pub filed_weight_28d: u32,
}

/// The work standing before a targeted version ships, as notes-cli sums it (`TargetWork`
/// there): the open version and every later one up to the target.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct TargetWork {
    pub open_weight: u32,
    pub closed_weight_28d: u32,
    pub filed_weight_28d: u32,
}

/// The open version's release window as notes-cli counts it against its `## Committed` snapshot
/// (`window::OpenWindow` there): the sprint the card scores. `open` is the committed rows still
/// open, which carry at the cut.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Window {
    pub version: String,
    /// The day the snapshot was taken, `YYYY-MM-DD`.
    pub opened: String,
    /// The day the window is due, `YYYY-MM-DD`; None when the snapshot names none.
    pub due: Option<String>,
    pub committed: u32,
    pub delivered: u32,
    pub open: u32,
    /// The `open` rows' `#size/` weight, 1 unsized: what [`state`] holds against the net rate.
    /// Never below `open`, since a row weighs at least 1; [`Window::open_weight()`] floors it there
    /// for a notes that sends none.
    pub open_weight: u32,
    /// Committed rows closed as dropped or duplicate, or gone from both lanes.
    pub dropped: u32,
    /// Rows tagged `#interrupt` that entered after the snapshot.
    pub interrupted: u32,
    /// When the sprint lock was taken, `YYYY-MM-DDTHH:MM`: set while a sprint runs, None for a
    /// window recorded at a cut.
    pub locked: Option<String>,
    /// Days from today to `due`, negative once past; set by [`Card::from_stats`], never read
    /// from notes.
    #[serde(skip_deserializing)]
    pub days_left: Option<i64>,
}

impl Window {
    /// The open rows' weight, at least one per open row: a notes older than `open_weight` sends
    /// none, and the row count is the weight's true floor, never a guess above it.
    pub fn open_weight(&self) -> u32 {
        self.open_weight.max(self.open)
    }
}

/// The last cut's window score, the `## Score` line of its `sprints/` file (`window::LastWindow`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LastWindow {
    pub version: String,
    pub line: String,
}

/// One row of `notes projects --stats --json`: the fields a card shows.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Stats {
    pub profile: String,
    pub name: String,
    pub stage: String,
    /// `focus` while the sheet's `#prio/focus` is live, else empty: the sprint switch, the one
    /// project tag left (a row's own priority orders work, `priority.md`).
    pub prio: String,
    /// When the focus ends (`YYYY-MM-DD HH:MM`), while `prio` is focus; past it notes reads empty.
    pub focus_until: Option<String>,
    pub version: Option<String>,
    pub goal: String,
    pub progress: Progress,
    pub status: String,
    pub status_date: String,
    pub status_parts: StatusParts,
    /// The human sheet's epics with their leaf rollup (notes-cli `epics.rs`).
    pub epics: Vec<EpicRollup>,
    /// The version the human promised (`Target:` head line) and its day, `YYYY-MM-DD`.
    pub target_version: Option<String>,
    pub target_on: Option<String>,
    /// The work standing before that version ships; `None` with no target.
    pub target_work: Option<TargetWork>,
    /// The open version's window; `None` when it has no `## Committed` snapshot.
    pub window: Option<Window>,
    /// The last cut's score; `None` when that cut had no snapshot or nothing was cut.
    pub last_window: Option<LastWindow>,
    /// notes' `[projects] idle_days`: days with no close before a project with nothing in
    /// flight and no window reads idle. 0 (a notes that sends none) reads every such project
    /// idle, never active.
    pub idle_days: i64,
}

/// One epic as `--stats --json` rolls it up: leaves only, by size weight.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct EpicRollup {
    pub id: String,
    pub title: String,
    /// The system it builds, the area in `epic(<system>):`.
    pub system: String,
    /// The release it is aimed at; empty when it spans releases.
    pub version: String,
    pub open: u32,
    pub done: u32,
    pub open_weight: u32,
    pub done_weight: u32,
}

/// The value a key writes for a project at `cur`: focus toggles, on and off (`normal`).
pub fn next_prio(cur: &str) -> &'static str {
    if cur == "focus" {
        "normal"
    } else {
        "focus"
    }
}

/// A project or profile name safe to pass as one argument: not empty, not flag-like, and only
/// letters, digits, `-`, `_` and `.`.
pub fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// The STATUS block's labelled lines as `notes projects --stats --json` sends them
/// (`status_parts`). The fields are private: they are read once, by [`Status::of`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct StatusParts {
    done: String,
    doing: String,
    next: String,
    needs: String,
}

/// A project's agent note: the headline, then a key table of what was done, is being done, comes
/// next and needs the human. Both surfaces draw it as sent; the numbers (state, waves, window,
/// gate) are the page's own and are never in it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Status {
    pub headline: Option<Shown>,
    /// One fact per labelled line the note carries, in the order they are written.
    pub rows: Vec<Fact>,
}

impl Status {
    pub fn of(headline: &str, parts: &StatusParts) -> Status {
        let rows = [
            ("Done", &parts.done),
            ("Doing", &parts.doing),
            ("Next", &parts.next),
            ("Needs you", &parts.needs),
        ]
        .into_iter()
        .filter(|(_, v)| !v.trim().is_empty())
        .map(|(l, v)| Fact {
            label: Shown::chip(l),
            value: Shown::note(v),
        })
        .collect();
        Status {
            headline: (!headline.trim().is_empty()).then(|| Shown::note(headline)),
            rows,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.headline.is_none() && self.rows.is_empty()
    }

    /// Every word of the note, for a search.
    fn search_text(&self) -> String {
        self.headline
            .iter()
            .chain(self.rows.iter().map(|f| &f.value))
            .map(|s| s.full())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// The opened card's Agent note head: `model-written, <date>`, or `none`.
pub fn note_says(c: &Card) -> String {
    if c.status.is_empty() {
        "none".into()
    } else {
        format!("model-written, {}", c.status_date)
            .trim_end_matches([',', ' '])
            .to_string()
    }
}

/// `notes projects --prio <name> --profile <profile> --set <value> [--hours H]`: the one
/// writer. `hours` is how long a focus lasts; `None` takes notes' default.
pub fn set_prio(
    runner: &dyn Runner,
    profile: &str,
    name: &str,
    value: &str,
    hours: Option<u32>,
) -> Result<String, String> {
    if !safe_name(profile)
        || !safe_name(name)
        || !["focus", "normal"].contains(&value)
        || (hours.is_some() && value != "focus")
    {
        return Err(format!("refusing prio {value} for {profile}/{name}"));
    }
    let mut argv: Vec<String> = [
        "notes",
        "projects",
        "--prio",
        name,
        "--profile",
        profile,
        "--set",
        value,
    ]
    .map(String::from)
    .to_vec();
    if let Some(h) = hours {
        argv.extend(["--hours".into(), h.to_string()]);
    }
    runner.run(&argv)
}

pub fn stats(runner: &dyn Runner) -> Result<Vec<Stats>, String> {
    let out = runner.run(&[
        "notes".into(),
        "projects".into(),
        "--stats".into(),
        "--json".into(),
    ])?;
    serde_json::from_str(&out).map_err(|e| format!("notes projects --stats --json: {e}"))
}

/// This machine's own notes profile (`notes config --machine-profile`), which decides whether a
/// work project is listed here; `personal` when notes cannot say, so a box without notes hides
/// work rather than listing it, and says so on stderr (the same fallback as
/// `project_machine_profile` in project-name.sh).
pub fn machine_profile(runner: &dyn Runner) -> String {
    let out = runner.run(&["notes".into(), "config".into(), "--machine-profile".into()]);
    out.ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            eprintln!(
                "hub-core: `notes config --machine-profile` failed, so work projects are hidden here; rebuild notes"
            );
            "personal".into()
        })
}

/// project-map.json: `$AGENT_QUEUE_PROJECT_MAP`, else the shared-hooks copy. agent-queue checks
/// `--project` against the same file.
pub fn map_path() -> PathBuf {
    std::env::var("AGENT_QUEUE_PROJECT_MAP").map_or_else(
        |_| agent_core::session::home().join(".config/shared-hooks/project-map.json"),
        PathBuf::from,
    )
}

/// One project's card.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Card {
    pub profile: String,
    pub name: String,
    pub stage: String,
    pub prio: String,
    pub focus_until: Option<String>,
    pub version: Option<String>,
    pub goal: String,
    pub progress: Progress,
    /// Where the current release is, one of [`STATES`] ([`state`]); set by [`build`] once the
    /// queue joins in, empty on a card [`Card::from_stats`] made alone.
    pub state: &'static str,
    pub idle_days: i64,
    /// The open version's release window, its `days_left` dated from the card's day; None when
    /// it has no snapshot, which every surface says as `no window`.
    pub window: Option<Window>,
    pub last_window: Option<LastWindow>,
    /// Open rows tagged `#requested` (the human's asks of the agents), both lanes.
    pub requested: usize,
    pub inbox: usize,
    /// Started rows (`[/]`) among the ones `progress.open` counts.
    pub doing: usize,
    /// Rows tagged `#urgent` or `#high` among the ones `progress.open` counts.
    pub hot: usize,
    pub running: Vec<Running>,
    pub waiting: usize,
    /// Every queued item; each can start, since work with a gate is a board row.
    pub queued: usize,
    /// Queue items closed since local midnight, shipped and checks (`queue::done_today`).
    pub today: crate::queue::DoneToday,
    /// Minutes the longest-waiting queued item has sat; None when none is queued.
    pub oldest_ready_min: Option<i64>,
    pub status: Status,
    pub status_date: String,
    /// The department inner tabs its page has (`layout::dept_tabs` over its project-map type): all
    /// nine for a game or app, engineering and ops for infra, none for an untyped project.
    pub dept_tabs: Vec<&'static str>,
    /// The agent sheet's open rows on its board and on the backlog tier and the human sheet's
    /// feature epics (`tasks::Project::tiers`); None until the feed joins in.
    pub agent_tiers: Option<crate::tasks::Tiers>,
    /// The targeted version against its net-rate ETA; None when no target is set.
    pub on_time: Option<OnTime>,
    /// One entry per version the open feature epics are aimed at, earliest first.
    pub versions: Vec<VersionEpics>,
}

/// A targeted version against the day the work up to it closes at the net rate: what the card,
/// `hub projects --status` and the Sentinel `release-late` watch read (`hub projects --json`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct OnTime {
    pub version: String,
    /// The promised day, `YYYY-MM-DD`.
    pub target_on: String,
    /// The day the work through the target closes at the net rate; None when it never does.
    pub eta_on: Option<String>,
    /// `on track`, `late`, [`NEVER`] (the net rate is at or below zero) or `unread` (notes sent
    /// a target but no `target_work`: an older notes, rebuilt with the hub).
    pub state: &'static str,
    /// Days `eta_on` falls after `target_on`; 0 unless late.
    pub late_days: i64,
    /// Weight that still fits before `target_on` at the net rate, after the work already aimed
    /// through the target: negative when that work alone overruns it (a target already past
    /// reads minus the open work), None when the net rate is at or below zero or unread. None
    /// means nothing more fits even when `state` reads on track with nothing open: no scope
    /// added can close at that rate. What release-coordinator `plan` fills with notes'
    /// `target_backlog`.
    pub room_weight: Option<i64>,
}

/// A version's open feature epics by size points (standing epics are upkeep, left out): the
/// Projects tab's line per version.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct VersionEpics {
    pub version: String,
    pub epics: u32,
    pub done_weight: u32,
    pub total_weight: u32,
}

impl Card {
    /// The card's own numbers, before the feed and the queue join in: the one Stats -> Card
    /// mapping, which `build` and `page::status` share. `today` dates the on-time check.
    pub fn from_stats(s: &Stats, today: chrono::NaiveDate) -> Card {
        Card {
            profile: s.profile.clone(),
            name: s.name.clone(),
            stage: s.stage.clone(),
            prio: s.prio.clone(),
            focus_until: s.focus_until.clone(),
            version: s.version.clone(),
            goal: s.goal.clone(),
            progress: s.progress.clone(),
            idle_days: s.idle_days,
            window: s.window.clone().map(|mut w| {
                w.days_left = w
                    .due
                    .as_deref()
                    .and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
                    .map(|d| (d - today).num_days());
                w
            }),
            last_window: s.last_window.clone(),
            on_time: on_time(s, today),
            versions: version_epics(&s.epics),
            status: Status::of(&s.status, &s.status_parts),
            status_date: s.status_date.clone(),
            dept_tabs: crate::layout::dept_tabs(
                project_map::cached()
                    .and_then(|r| r.kind(r.lookup(&s.name).unwrap_or(&s.name)))
                    .as_deref(),
            ),
            ..Card::default()
        }
    }

    pub fn in_flight(&self) -> bool {
        !self.running.is_empty() || self.waiting > 0
    }

    /// Rows closed per week: the open version's rows closed in the last 28 days, over 4. Rounded
    /// here to the one decimal a surface prints: quarters are ties, and Rust and JS break them
    /// apart, so a surface formatting the raw value would read differently from the next.
    pub fn pace(&self) -> f64 {
        (f64::from(self.progress.closed_28d) * 2.5).round() / 10.0
    }
}

/// The list of projects, one row a card. Its own order is in flight first, so no column is
/// sorted until asked. Empty words read as no value, the `-` a surface draws.
impl crate::table::Row for Card {
    const COLUMNS: &'static [&'static str] = &[
        "project", "state", "profile", "stage", "version", "prio", "open", "doing", "hot", "done",
        "7d", "pts", "pts7d", "window", "due", "pace", "run", "wait", "queued", "shipped",
        "oldest",
    ];
    const STATES: &'static [&'static str] = &["all", "in flight", "waiting"];
    const FACETS: &'static [&'static str] = &["profile", "stage", "state"];
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["state", "stage", "open"];
    const TONES: &'static [(&'static str, Level)] = STATE_TONES;

    fn val(&self, col: &str) -> Val {
        let word = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        let num = |n: Option<u32>| n.map_or(Val::None, |n| Val::Num(f64::from(n)));
        match col {
            "project" => word(&self.name),
            "state" => word(self.state),
            "profile" => word(&self.profile),
            "stage" => word(&self.stage),
            "version" => self.version.as_deref().map_or(Val::None, word),
            "prio" => word(&self.prio),
            "open" => num(Some(self.progress.open)),
            "doing" => Val::Num(self.doing as f64),
            "hot" => Val::Num(self.hot as f64),
            "done" => num(Some(self.progress.done)),
            "7d" => num(Some(self.progress.closed_7d)),
            "pts" => num(Some(self.progress.done_weight)),
            "pts7d" => num(Some(self.progress.closed_weight_7d)),
            "window" => window_share(self).map_or(Val::None, |n| Val::Num(f64::from(n))),
            "due" => self
                .window
                .as_ref()
                .and_then(|w| w.days_left)
                .map_or(Val::None, |d| Val::Num(d as f64)),
            "pace" => Val::Num(self.pace()),
            "run" => Val::Num(self.running.len() as f64),
            "wait" => Val::Num(self.waiting as f64),
            "queued" => Val::Num(self.queued as f64),
            "shipped" => Val::Num(self.today.shipped as f64),
            "oldest" => self
                .oldest_ready_min
                .map_or(Val::None, |m| Val::Num(m as f64)),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "in flight" => self.in_flight(),
            "waiting" => self.waiting > 0,
            _ => false,
        }
    }

    /// A bare word searches what a project is called, what it is for and its note.
    fn text(&self) -> String {
        format!(
            "{}\n{}\n{}",
            self.name,
            self.goal,
            self.status.search_text()
        )
        .to_lowercase()
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            // `next_prio`'s words, normal being blank, lowest first.
            "prio" => ["", "focus"]
                .iter()
                .position(|p| *p == self.prio)
                .map_or(Val::None, |i| Val::Num(i as f64)),
            // Worst first ascending: the rule table's order, `late` at 0.
            "state" => STATES
                .iter()
                .position(|s| *s == self.state)
                .map_or(Val::None, |i| Val::Num(i as f64)),
            "version" => self
                .version
                .as_deref()
                .map_or(Val::None, |v| Val::Text(crate::tasks::release_order(v))),
            _ => self.val(col),
        }
    }

    /// The name opens the project's page.
    fn link(&self, col: &str) -> Option<Link> {
        (col == "project")
            .then(|| Link::to(Kind::Project, format!("{}/{}", self.profile, self.name)))
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Projects {
    pub cards: Vec<Card>,
    /// Active queue items no card could claim, as `project: title`.
    pub unlinked: Vec<String>,
    pub errors: Vec<String>,
    /// The agent board's rows, `notes board --json` `totals.agent`, so the Projects strip shows
    /// the Board its tiers line names without reading the rows. `None` when the feed failed.
    pub board_open: Option<usize>,
    /// `totals.backlog`, the agent rows still carrying the retired backlog token, shown beside it.
    pub board_backlog: Option<usize>,
}

/// What an ETA reads when the net rate is at or below zero: rows are filed as fast as they close.
pub const NEVER: &str = "never at this rate";

/// What a card with no window snapshot says in its window cell, in place of any number.
pub const NO_WINDOW: &str = "no window";

pub const LATE: &str = "late";
pub const AT_RISK: &str = "at risk";
pub const ON_TRACK: &str = "on track";
pub const IDLE: &str = "idle";
pub const PARKED: &str = "parked";
/// An active project with no window: its rows flow as they close. Not a warning, so no hue.
pub const FLOW: &str = "flow";

/// The project states in the order [`state`] tries them, first match wins. The rule table's one
/// home is `docs/stages.md`, "Project state"; `state_words_are_the_stages_md_table` holds the two
/// to the same words in the same order.
pub const STATES: [&str; 6] = [LATE, AT_RISK, ON_TRACK, FLOW, IDLE, PARKED];

/// Each state's hue (dashboards.md rule 5); `flow` and `parked` are in none, so they draw plain.
pub const STATE_TONES: &[(&str, Level)] = &[
    (LATE, Level::Bad),
    (AT_RISK, Level::Warn),
    (ON_TRACK, Level::Ok),
    (IDLE, Level::Warn),
];

/// A state's hue, `None` for grey: what `state_level` in `--json` carries.
pub fn state_level(state: &str) -> Option<Level> {
    crate::vocab::tone(STATE_TONES, state)
}

/// The state, then the window: what the phone row and the anchor's Lab line say, `state_says` in
/// `--json`. A quiet or flowing state with no window is said alone (`flow`, `idle`, `parked`);
/// `late` and `at risk` keep `no window`, the cause to close. A card [`build`] has not stated is
/// its window.
pub fn state_says(c: &Card) -> String {
    let window = window_short(c);
    if c.state.is_empty() {
        window
    } else if c.window.is_none() && ![LATE, AT_RISK].contains(&c.state) {
        c.state.to_string()
    } else {
        format!("{}, {window}", c.state)
    }
}

/// Where `c`'s current release is on `today`, by the rule table in `docs/stages.md`, "Project
/// state": the first of [`STATES`] whose rule matches. Every input is counted: the window and
/// its due day, the net weight rate ([`net_rate`]), the target's on-time check, the newest close,
/// and the queue's running and waiting items.
pub fn state(c: &Card, today: chrono::NaiveDate) -> &'static str {
    let day = |d: &str| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok();
    let target_past = c
        .on_time
        .as_ref()
        .and_then(|o| day(&o.target_on))
        .is_some_and(|on| on < today);
    let w = c.window.as_ref();
    // A window with every committed row delivered waits only on its cut: not late.
    let delivered = w.is_some_and(|w| w.open == 0);
    if !delivered && (target_past || w.and_then(|w| w.days_left).is_some_and(|d| d < 0)) {
        return LATE;
    }
    // The weight the net rate closes in the days left, against the committed rows' open weight.
    let net = net_rate(c.progress.closed_weight_28d, c.progress.filed_weight_28d).unwrap_or(0);
    let short = w.is_some_and(|w| {
        w.days_left
            .is_some_and(|d| i64::from(net) * d.max(0) / 28 < i64::from(w.open_weight()))
    });
    let miss = c
        .on_time
        .as_ref()
        .is_some_and(|o| o.state == "late" || o.state == NEVER);
    if short || miss {
        return AT_RISK;
    }
    if w.is_some() {
        return ON_TRACK;
    }
    let closed_lately = c
        .progress
        .last_closed
        .as_deref()
        .and_then(day)
        .is_some_and(|d| (today - d).num_days() < c.idle_days);
    if closed_lately || c.in_flight() {
        FLOW
    } else if c.stage == "draft" {
        PARKED
    } else {
        IDLE
    }
}

/// `part` of `whole` as a whole percent, rounded down so 100 means nothing is left; None when
/// `whole` is 0.
pub fn share(part: u32, whole: u32) -> Option<u32> {
    (whole > 0).then(|| part * 100 / whole)
}

/// Delivered of committed rows as a whole percent, for a bar's fill only (the words are always
/// the counts); None with no window or nothing committed.
pub fn window_share(c: &Card) -> Option<u32> {
    c.window
        .as_ref()
        .and_then(|w| share(w.delivered, w.committed))
}

/// The window's score: `1/84`, delivered of committed rows.
fn score(w: &Window) -> String {
    format!("{}/{}", w.delivered, w.committed)
}

/// A running sprint in words, `v0.5.4 6/15 due 11-19, locked 18:05`; None when no sprint lock
/// holds the open window. The projects chip counts and lists these. A lock past its cut still
/// runs until the cut rolls the version, which opens the next window unlocked: that sprint is
/// late, and its card's state says so.
pub fn sprint_says(c: &Card) -> Option<String> {
    let w = c.window.as_ref()?;
    let at = w.locked.as_deref()?;
    let hm = at.split_once('T').map_or(at, |(_, t)| t);
    Some(format!("{} {}, locked {hm}", w.version, window_short(c)))
}

/// The window in one short cell: `1/84 due 11-22`, `1/84` with no due day, or `no window`.
pub fn window_short(c: &Card) -> String {
    let mut s = window_cell(c);
    if let Some(d) = c.window.as_ref().and_then(|w| w.due.as_ref()) {
        s += &format!(" due {}", crate::text::short_day(d));
    }
    s
}

/// The window's score as a table cell: `1/84`, or `no window`.
pub fn window_cell(c: &Card) -> String {
    c.window
        .as_ref()
        .map_or_else(|| NO_WINDOW.to_string(), score)
}

/// The days to the window's due day as a table cell: `4d`, `today`, `3d over`, or `-` with no
/// window or no due day.
pub fn due_cell(c: &Card) -> String {
    match c.window.as_ref().and_then(|w| w.days_left) {
        None => "-".to_string(),
        Some(0) => "today".to_string(),
        Some(n) if n > 0 => format!("{n}d"),
        Some(n) => format!("{}d over", -n),
    }
}

/// The window in words: `1/84 rows, due 11-22 (4 days left), 2 interrupts`, `(due today)`,
/// `(3 days over)`, or `no window`.
pub fn window_words(c: &Card) -> String {
    let Some(w) = &c.window else {
        return NO_WINDOW.to_string();
    };
    let days = |n: i64| crate::display::fmt::counted(n as usize, "day");
    let mut s = format!("{} rows", score(w));
    match (&w.due, w.days_left) {
        (Some(d), Some(n)) => {
            s += &format!(", due {}", crate::text::short_day(d));
            s += &match n {
                0 => " (due today)".to_string(),
                n if n > 0 => format!(" ({} left)", days(n)),
                n => format!(" ({} over)", days(-n)),
            };
        }
        _ => s += ", no due day",
    }
    if w.interrupted > 0 {
        let n = i64::from(w.interrupted);
        s += &format!(
            ", {}",
            crate::display::fmt::counted(n as usize, "interrupt")
        );
    }
    s
}

/// The card's target against its ETA: `target v0.3.0 by 12-15: on track (ETA ~12-01)`,
/// `... late 9 days (ETA ~12-24)`, `... never at this rate`, or `no target`.
pub fn on_time_words(c: &Card) -> String {
    let Some(o) = &c.on_time else {
        return "no target".to_string();
    };
    let eta = o.eta_on.as_deref().map_or_else(String::new, |e| {
        format!(" (ETA ~{})", crate::text::short_day(e))
    });
    let verdict = match o.state {
        "late" => format!(
            "late {}{eta}",
            crate::display::fmt::counted(o.late_days as usize, "day")
        ),
        "on track" => format!("on track{eta}"),
        NEVER => NEVER.to_string(),
        _ => "ETA unread (notes sent no target_work; rebuild notes)".to_string(),
    };
    format!(
        "target {} by {}: {verdict}",
        o.version,
        crate::text::short_day(&o.target_on)
    )
}

/// `s`'s target against the day the work through it closes at the net rate, from `today`; None
/// when no target is set.
pub fn on_time(s: &Stats, today: chrono::NaiveDate) -> Option<OnTime> {
    let version = s.target_version.clone()?;
    let on = chrono::NaiveDate::parse_from_str(s.target_on.as_deref()?, "%Y-%m-%d").ok()?;
    let mut o = OnTime {
        version,
        target_on: on.to_string(),
        state: "unread",
        ..OnTime::default()
    };
    let Some(w) = s.target_work else {
        return Some(o);
    };
    let eta = net_eta(w.open_weight, w.closed_weight_28d, w.filed_weight_28d)
        .map(|d| today + chrono::Days::new(u64::from(d)));
    o.late_days = eta.map_or(0, |e| (e - on).num_days().max(0));
    o.eta_on = eta.map(|e| e.to_string());
    o.room_weight = net_room(&w, (on - today).num_days());
    o.state = match eta {
        None => NEVER,
        Some(_) if o.late_days > 0 => "late",
        Some(_) => "on track",
    };
    Some(o)
}

/// The open feature epics grouped by the version they are aimed at, earliest first. An epic
/// that spans releases (no version) or is standing upkeep is in none.
pub fn version_epics(epics: &[EpicRollup]) -> Vec<VersionEpics> {
    let mut out: Vec<VersionEpics> = Vec::new();
    for e in epics
        .iter()
        .filter(|e| !e.version.is_empty() && !crate::page::standing(&e.title, &e.system))
    {
        let i = match out.iter().position(|v| v.version == e.version) {
            Some(i) => i,
            None => {
                out.push(VersionEpics {
                    version: e.version.clone(),
                    ..VersionEpics::default()
                });
                out.len() - 1
            }
        };
        let v = &mut out[i];
        v.epics += 1;
        v.done_weight += e.done_weight;
        v.total_weight += e.done_weight + e.open_weight;
    }
    out.sort_by_key(|v| crate::tasks::release_order(&v.version));
    out
}

/// One version's epic line: `v0.3.0: 2 open epics, 5 of 20 points done`.
pub fn version_words(v: &VersionEpics) -> String {
    format!(
        "{}: {} open {}, {} of {} points done",
        v.version,
        v.epics,
        crate::display::fmt::noun(v.epics as usize, "epic", "epics"),
        v.done_weight,
        v.total_weight
    )
}

/// Days to close `open` weight at the net rate, weight closed minus weight filed per 28 days,
/// rounded up: 0 when nothing is open, None when the net rate is at or below zero ([`NEVER`]),
/// so a version filled as fast as it empties never reads as closing.
fn net_eta(open: u32, closed_28d: u32, filed_28d: u32) -> Option<u32> {
    if open == 0 {
        return Some(0);
    }
    Some(days_at(open, net_rate(closed_28d, filed_28d)?))
}

/// The net weight rate, weight closed minus weight filed per 28 days; None at or below zero. The
/// one arithmetic the version ETA ([`net_eta`]) and its room ([`net_room`]) apply to the target's
/// work, and the row forecast ([`forecast`]) and the project state ([`state`]) to the project's
/// [`Progress`], so a project filing as fast as it closes reads never on each of them.
fn net_rate(closed_28d: u32, filed_28d: u32) -> Option<u32> {
    closed_28d.checked_sub(filed_28d).filter(|n| *n > 0)
}

/// The weight the net rate closes in `days_left` days (none when past), less what `w` already
/// has open, rounded down; None when the net rate is at or below zero, as [`net_eta`] reads it.
fn net_room(w: &TargetWork, days_left: i64) -> Option<i64> {
    let net = net_rate(w.closed_weight_28d, w.filed_weight_28d)?;
    Some(i64::from(net) * days_left.max(0) / 28 - i64::from(w.open_weight))
}

/// Days to close `weight` at `rate` weight per 28 days, rounded up. `rate` is above 0.
fn days_at(weight: u32, rate: u32) -> u32 {
    (weight * 28).div_ceil(rate)
}

/// Put a forecast day on each open leaf row of the projects `stats` covers: the day it should
/// close at the project's net weight rate ([`net_rate`] over its [`Progress`]), after every row
/// ranked ahead of it, in the sheet's order (section, then rank): the weight ahead and its own,
/// times 28, over the net rate, rounded up, in days from `today`. An epic or a row another row
/// names in `#of/` weighs what its children weigh, so it adds nothing and gets no day; a playtest
/// check is no work item. A project whose net rate is at or below zero gets no day, never a
/// guess.
pub fn forecast(feed: &mut Feed, stats: &[Stats], today: chrono::NaiveDate) {
    let parents: std::collections::HashSet<String> =
        feed.rows.iter().filter_map(|r| r.parent.clone()).collect();
    let mut order: Vec<usize> = (0..feed.rows.len()).collect();
    order.sort_by_key(|&i| {
        let r = &feed.rows[i];
        (crate::tasks::section_order(r.section.as_deref()), r.rank)
    });
    let mut ahead: HashMap<(String, String), u32> = HashMap::new();
    for i in order {
        let r = &mut feed.rows[i];
        r.forecast = None;
        let leaf = matches!(
            r.section.as_deref(),
            Some("now" | "next" | "board" | "backlog")
        ) && r.id.as_ref().is_none_or(|id| !parents.contains(id));
        let Some(project) = r.project.clone().filter(|_| leaf) else {
            continue;
        };
        let Some(rate) = stats
            .iter()
            .find(|s| s.name == project && s.profile == r.profile)
            .and_then(|s| net_rate(s.progress.closed_weight_28d, s.progress.filed_weight_28d))
        else {
            continue;
        };
        let sum = ahead.entry((r.profile.clone(), project)).or_default();
        *sum += r.weight.max(1);
        let days = days_at(*sum, rate);
        r.forecast = Some((today + chrono::Days::new(u64::from(days))).to_string());
    }
}

/// The lab project an item belongs to, by the rules in the module doc.
fn owner(i: &Item, labs: &[&str]) -> Option<String> {
    let row = i.row.as_deref().and_then(|r| r.split(':').next());
    [row, Some(i.project.as_str())]
        .into_iter()
        .flatten()
        .find(|p| labs.contains(p))
        .map(String::from)
}

/// A minute count at a glance, `display::fmt::age`'s words: what the `oldest` column prints.
pub fn wait_word(min: Option<i64>) -> String {
    min.map_or_else(|| "-".to_string(), |m| crate::display::fmt::age(m * 60))
}

/// The cards, in flight first (running, then waiting), then by closes in 7 days, then name.
/// `now` dates the queue's waits and its done-today count.
pub fn build(
    stats: &[Stats],
    feed: Option<&Feed>,
    state: &Value,
    queue: Option<&Queue>,
    now: chrono::DateTime<chrono::Utc>,
) -> Projects {
    let mut out = Projects::default();
    let labs: Vec<&str> = stats.iter().map(|s| s.name.as_str()).collect();
    let today = now.with_timezone(&chrono::Local).date_naive();
    let mut cards: Vec<Card> = stats.iter().map(|s| Card::from_stats(s, today)).collect();
    let at = |cards: &mut Vec<Card>, name: &str| cards.iter().position(|c| c.name == name);
    if let Some(f) = feed {
        for p in &f.projects {
            if let Some(c) = cards
                .iter_mut()
                .find(|c| c.name == p.project && c.profile == p.profile)
            {
                c.inbox = p.inbox;
                c.agent_tiers = Some(p.tiers());
            }
        }
        for r in &f.rows {
            let Some(p) = r.project.as_deref() else {
                continue;
            };
            let Some(c) = cards
                .iter_mut()
                .find(|c| c.name == p && c.profile == r.profile)
            else {
                continue;
            };
            c.requested += usize::from(r.requested);
            // DOING and HOT count the rows OPEN counts: the open version's, in the human and
            // agent lanes (no playtest list, nothing aimed at a later release), not yet done.
            let counted = r.state != "done"
                && r.lane != "playtest"
                && (r.version.is_none() || r.version == c.version);
            if counted {
                c.doing += usize::from(r.doing());
                c.hot += usize::from(r.hot());
            }
        }
    }
    if let Some(q) = queue {
        out.errors.extend(q.errors.iter().cloned());
        let by_slug: HashMap<&str, &Item> = q.items.iter().map(|i| (i.slug.as_str(), i)).collect();
        for r in home::running(state, q, feed) {
            let item = by_slug[r.slug.as_str()];
            match owner(item, &labs).and_then(|o| at(&mut cards, &o)) {
                Some(k) => cards[k].running.push(r),
                None => out.unlinked.push(format!("{}: {}", r.project, r.title)),
            }
        }
        let midnight = crate::text::local_day_start(now.timestamp());
        let mut closed: HashMap<usize, Vec<&Item>> = HashMap::new();
        for i in q.items.iter().filter(|i| i.state == State::Done) {
            if let Some(k) = owner(i, &labs).and_then(|o| at(&mut cards, &o)) {
                closed.entry(k).or_default().push(i);
            }
        }
        for (k, items) in closed {
            cards[k].today = crate::queue::done_today(items, midnight);
        }
        for i in q
            .items
            .iter()
            .filter(|i| matches!(i.state, State::Waiting | State::Queued))
        {
            match owner(i, &labs).and_then(|o| at(&mut cards, &o)) {
                Some(k) if i.state == State::Waiting => cards[k].waiting += 1,
                Some(k) => {
                    let c = &mut cards[k];
                    c.queued += 1;
                    if let Some(m) = i.ready_min(now) {
                        c.oldest_ready_min = Some(c.oldest_ready_min.map_or(m, |o| o.max(m)));
                    }
                }
                None => out.unlinked.push(format!("{}: {}", i.project, i.title())),
            }
        }
    }
    // The rule counts what is in flight, so an unread queue states no card (each surface draws
    // `-`) rather than calling an active project idle.
    let queue_read = queue.is_some_and(|q| q.errors.is_empty());
    for c in &mut cards {
        c.state = if queue_read {
            self::state(c, today)
        } else {
            ""
        };
    }
    cards.sort_by(|a, b| {
        (b.running.len(), b.waiting, b.progress.closed_7d)
            .cmp(&(a.running.len(), a.waiting, a.progress.closed_7d))
            .then_with(|| a.name.cmp(&b.name))
    });
    out.cards = cards;
    out.board_open = feed.and_then(|f| f.totals).map(|t| t.agent);
    out.board_backlog = feed.and_then(|f| f.totals).map(|t| t.backlog);
    out
}

/// A card's one-line progress, the same words on both surfaces, every number named:
/// `v0.0.1 window 1/84 rows, due 11-22 (4 days left), closed 103 in 7d, 239 in 28d; no target`.
/// With no window it says `no window`, and the last cut's score when there was one.
pub fn summary(c: &Card) -> String {
    let p = &c.progress;
    let mut s = c.version.clone().unwrap_or_else(|| "no version".into());
    if c.window.is_some() {
        s += &format!(" window {}", window_words(c));
    } else {
        s += &format!(" {NO_WINDOW}");
        if let Some(l) = &c.last_window {
            s += &format!(" (last {}: {})", l.version, l.line);
        }
    }
    s += &format!(", closed {} in 7d, {} in 28d", p.closed_7d, p.closed_28d);
    s + "; " + &on_time_words(c)
}

/// The card's queue in one line, at the head of `counts`: `1 running, 0 waiting, 2 queued`.
fn queue(c: &Card) -> String {
    format!(
        "{} running, {} waiting, {} queued",
        c.running.len(),
        c.waiting,
        c.queued
    )
}

/// What a running item under no epic counts as in [`running_areas`].
pub const NO_EPIC: &str = "no epic";

/// The card's running items counted by their epic's system (`Running::area`), most first, ties
/// by name, and the items under no epic last as [`NO_EPIC`]: `running_areas` in `--json`, the
/// categories the projects chip lists under each project.
pub fn running_areas(c: &Card) -> Vec<(String, usize)> {
    let mut by: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
    let mut none = 0;
    for r in &c.running {
        match r.area.as_deref() {
            Some(a) => *by.entry(a).or_default() += 1,
            None => none += 1,
        }
    }
    let mut v: Vec<(String, usize)> = by.into_iter().map(|(a, n)| (a.to_string(), n)).collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    if none > 0 {
        v.push((NO_EPIC.to_string(), none));
    }
    v
}

/// The card's In flight as the Running table draws it, scoped to the project: the same
/// [`Running`] row type, so the same columns and each cell's links. It is a fixed list on the
/// project page (no query, sort or filter to give), so it sends no facets or state chips.
pub fn running_table(c: &Card) -> crate::table::Summary {
    let (_, mut t) = crate::table::View::default().summary(&c.running);
    t.facets.clear();
    t.states.clear();
    t
}

/// The opened card's In flight counts: the queue, then rows #requested and the inbox, then its
/// agent board, backlog and feature epic counts once the feed joined in.
pub fn counts(c: &Card) -> String {
    let mut s = format!(
        "{}; {} rows #requested, {} in the inbox",
        queue(c),
        c.requested,
        c.inbox
    );
    if let Some(t) = c.agent_tiers {
        s += &format!("; {}", t.words());
    }
    s
}

/// The fleet state file as JSON, `Null` when unreadable: what `build` reads beside the stats.
pub fn fleet_state() -> Value {
    std::fs::read_to_string(crate::boards::fleet_state())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// The whole join every surface reads: `notes projects --stats --json`, the inbox feed, fleet
/// state and the queue, built into cards. agent-web's `/api/projects` and `hub projects --json`
/// both call this, so the chip, the phone, the web tab and the TUI agree.
pub fn gather() -> Projects {
    let runner = crate::session_actions::System;
    let state = fleet_state();
    // The cards join only the queue's items, so its stats (about 0.9 s) are not read, and the
    // three reads run at once: the anchor's Stop hook waits on this (regen-anchor.sh).
    let (items, feed, stats) = std::thread::scope(|s| {
        let items = s.spawn(|| crate::queue::list(&runner, "all"));
        let feed = s.spawn(|| crate::tasks::feed(&runner).ok());
        let stats = stats(&runner);
        (
            items
                .join()
                .unwrap_or_else(|p| std::panic::resume_unwind(p)),
            feed.join().unwrap_or_else(|p| std::panic::resume_unwind(p)),
            stats,
        )
    });
    let queue = Queue::from_reads(items, Ok(Default::default()));
    match stats {
        Ok(stats) => build(
            &stats,
            feed.as_ref(),
            &state,
            Some(&queue),
            chrono::Utc::now(),
        ),
        Err(e) => Projects {
            errors: vec![e],
            ..Default::default()
        },
    }
}

/// The cards as JSON, each with its `summary` line, `in_flight` and `pace`, so a reader prints
/// the same words the TUI does and computes nothing, and `figures`, the Projects card's whole
/// numbers by name (`widget_doc::figures`, absent with any read error), the counts the waybar
/// projects chip shows.
/// The lengths a surface offers a focus besides notes' own default (no `--hours`), which is
/// notes' alone, as its cap is: notes refuses what it does not take.
pub const FOCUS_HOURS: [u32; 3] = [2, 8, 24];

/// The Focus strip over every card, never a view's: the projects on focus now with when each
/// ends, the line that names them, and every project a focus may be set on (one on focus again
/// re-sets its end, which is how a focus is extended).
pub fn focus_json(cards: &[Card]) -> Value {
    let on: Vec<&Card> = cards.iter().filter(|c| c.prio == "focus").collect();
    // `YYYY-MM-DD HH:MM +ZZZZ` as `MM-DD HH:MM`: a focus lasts at most a day, and the stamp
    // is in the zone of the host that served it.
    let ends = |c: &Card| {
        c.focus_until
            .as_deref()
            .map(|u| u.get(5..16).unwrap_or(u).to_string())
            .unwrap_or_default()
    };
    let says = if on.is_empty() {
        "No project is on focus, so none runs sprints.".to_string()
    } else {
        let named: Vec<String> = on
            .iter()
            .map(|c| {
                format!("{} until {}", c.name, ends(c))
                    .trim_end_matches(" until ")
                    .to_string()
            })
            .collect();
        format!(
            "On focus: {}. Its release windows run as sprints until its end.",
            named.join(", ")
        )
    };
    let who =
        |c: &Card| serde_json::json!({"profile": c.profile, "name": c.name, "until": ends(c)});
    serde_json::json!({
        "says": says,
        "on": on.iter().map(|c| who(c)).collect::<Vec<_>>(),
        "all": cards.iter().map(who).collect::<Vec<_>>(),
        "hours": FOCUS_HOURS,
    })
}

pub fn to_json(p: &Projects) -> Value {
    let mut v = serde_json::to_value(p).unwrap_or_default();
    v["figures"] = serde_json::json!(crate::widget_doc::figures(&[crate::cards::projects(p)]));
    if let Some(cards) = v["cards"].as_array_mut() {
        for (j, c) in cards.iter_mut().zip(&p.cards) {
            j["state_level"] = serde_json::to_value(state_level(c.state)).unwrap_or_default();
            j["state_says"] = state_says(c).into();
            j["summary"] = summary(c).into();
            j["window_says"] = window_short(c).into();
            j["sprint_says"] = sprint_says(c).into();
            j["window_cell"] = window_cell(c).into();
            j["window_share"] = window_share(c).into();
            j["due_cell"] = due_cell(c).into();
            j["counts"] = counts(c).into();
            j["version_lines"] = c.versions.iter().map(version_words).collect();
            j["in_flight"] = c.in_flight().into();
            j["pace"] = c.pace().into();
            j["oldest"] = wait_word(c.oldest_ready_min).into();
            if !c.running.is_empty() {
                j["running_table"] = serde_json::to_value(running_table(c)).unwrap_or_default();
            }
            j["running_areas"] = running_areas(c)
                .into_iter()
                .map(|(area, n)| serde_json::json!({"area": area, "n": n}))
                .collect();
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tasks::{Project, Row};
    use serde_json::json;

    #[test]
    fn a_status_note_is_a_headline_over_its_labelled_lines_in_the_written_order() {
        let stats: Stats = serde_json::from_value(json!({
            "name": "demo",
            "status": "Waves are landing.",
            "status_parts": {"done": "AI skins (#412).", "doing": "", "next": "morality meter.", "needs": "nothing."},
        }))
        .unwrap();
        let s = Status::of(&stats.status, &stats.status_parts);
        assert_eq!(s.headline.as_ref().unwrap().text(), "Waves are landing.");
        let rows: Vec<(&str, &str)> = s
            .rows
            .iter()
            .map(|f| (f.label.text(), f.value.text()))
            .collect();
        // A label with no words is no row.
        assert_eq!(
            rows,
            [
                ("Done", "AI skins (#412)."),
                ("Next", "morality meter."),
                ("Needs you", "nothing.")
            ]
        );
        // No headline and no lines is no note: a project the writer never reached.
        let none = Status::of("", &StatusParts::default());
        assert!(none.is_empty());
        let mut card = Card::default();
        assert_eq!(note_says(&card), "none");
        // A note of labelled lines alone still is one, and a search finds the words in it.
        card.status = Status::of("", &stats.status_parts);
        assert!(!card.status.is_empty());
        assert!(crate::table::Row::text(&card).contains("morality meter"));
        // The roles ride in the JSON both surfaces draw: a chip for each label, a note for the headline.
        let walk = serde_json::to_value(&s).unwrap();
        assert_eq!(walk["rows"][0]["label"]["role"], "chip");
        assert_eq!(walk["headline"]["role"], "note");
    }

    #[test]
    fn the_list_sorts_filters_and_searches_on_the_one_view() {
        use crate::table::View;
        let card = |name: &str, stage: &str, prio: &str, version: &str, closed: u32| Card {
            profile: "personal".into(),
            name: name.into(),
            stage: stage.into(),
            prio: prio.into(),
            version: Some(version.into()),
            goal: format!("{name} goal"),
            progress: Progress {
                closed_28d: closed,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut cards = vec![
            card("low", "alpha", "low", "v0.10.0", 10),
            card("normal", "beta", "", "v0.9.0", 2),
            card("focus", "alpha", "focus", "v0.2.0", 0),
            Card {
                name: "bare".into(),
                ..Default::default()
            },
        ];
        cards[1].waiting = 1;
        cards[2].running = vec![Running {
            slug: "s1".into(),
            title: "wire it".into(),
            project: "focus".into(),
            started: None,
            target: None,
            phases: None,
            ..Default::default()
        }];
        let names = |q: &str, s: &str, sort: &str, dir: &str| -> Vec<String> {
            View::new::<Card>(q, s, sort, dir)
                .apply(&cards)
                .iter()
                .map(|c| c.name.clone())
                .collect()
        };
        assert_eq!(cards[0].pace(), 2.5, "28-day closes over 4 weeks");
        assert_eq!(card("", "", "", "", 1).pace(), 0.3, "a tie rounds up, once");
        assert_eq!(
            names("pace:0.5", "", "", ""),
            ["normal"],
            "the figure shown"
        );
        assert_eq!(names("", "", "", ""), ["low", "normal", "focus", "bare"]);
        assert_eq!(names("", "in flight", "", ""), ["normal", "focus"]);
        assert_eq!(names("", "waiting", "", ""), ["normal"]);
        assert_eq!(names("stage:alpha", "", "", ""), ["low", "focus"]);
        assert_eq!(names("-stage:alpha normal", "", "", ""), ["normal"]);
        assert_eq!(
            names("", "", "prio", ""),
            ["focus", "normal", "bare", "low"],
            "focus outranks no focus; a retired ladder word (low) has no rank and sorts last"
        );
        assert_eq!(
            names("stage:alpha", "", "version", ""),
            ["low", "focus"],
            "v0.10.0 is newer than v0.2.0"
        );
        assert_eq!(names("", "", "pace", "")[0], "low");
    }

    #[test]
    fn running_areas_count_by_epic_system_most_first_and_no_epic_last() {
        let run = |area: Option<&str>| Running {
            area: area.map(Into::into),
            ..Default::default()
        };
        let c = Card {
            running: vec![
                run(None),
                run(Some("views")),
                run(Some("dispatch")),
                run(None),
                run(Some("dispatch")),
                run(Some("ci")),
                run(None),
            ],
            ..Default::default()
        };
        // NEGATIVE CONTROL: 3 items under no epic outnumber every system, and still go last.
        let wire = to_json(&Projects {
            cards: vec![c],
            ..Default::default()
        });
        assert_eq!(
            wire["cards"][0]["running_areas"],
            json!([{"area": "dispatch", "n": 2}, {"area": "ci", "n": 1},
                   {"area": "views", "n": 1}, {"area": "no epic", "n": 3}])
        );
        let idle = to_json(&Projects {
            cards: vec![Card::default()],
            ..Default::default()
        });
        assert_eq!(idle["cards"][0]["running_areas"], json!([]));
    }

    #[test]
    fn a_card_sends_its_in_flight_as_homes_running_table_in_the_rows_order() {
        let run = |slug: &str| Running {
            slug: slug.into(),
            title: format!("work {slug}"),
            project: "focus".into(),
            row: Some("ar-1".into()),
            ..Default::default()
        };
        let mut c = Card {
            name: "focus".into(),
            running: vec![run("b"), run("a")],
            ..Default::default()
        };
        let t = running_table(&c);
        assert_eq!((t.total, t.shown), (2, 2));
        assert!(
            t.facets.is_empty() && t.states.is_empty(),
            "a fixed list has no controls"
        );
        assert_eq!(
            t.links.len(),
            2,
            "one links map per row, in the rows' order"
        );
        assert_eq!(t.links[0]["item"], "#queue/b");
        let wire = to_json(&Projects {
            cards: vec![c.clone()],
            ..Default::default()
        });
        assert_eq!(wire["cards"][0]["running_table"]["shown"], 2);
        assert_eq!(wire["cards"][0]["running"][0]["slug"], "b");
        c.running.clear();
        let none = to_json(&Projects {
            cards: vec![c],
            ..Default::default()
        });
        assert!(none["cards"][0].get("running_table").is_none());
    }

    #[test]
    fn each_card_carries_the_summary_the_tui_prints() {
        let c = Card {
            name: "demo".into(),
            version: Some("v0.1.0".into()),
            progress: Progress {
                open: 1,
                done: 1,
                open_weight: 3,
                done_weight: 1,
                ..Default::default()
            },
            window: Some(Window {
                due: Some("2026-11-22".into()),
                committed: 4,
                delivered: 1,
                open: 3,
                days_left: Some(4),
                ..Default::default()
            }),
            ..Default::default()
        };
        let v = to_json(&Projects {
            cards: vec![c.clone()],
            ..Default::default()
        });
        assert_eq!(v["cards"][0]["summary"], summary(&c));
        assert!(v["cards"][0]["summary"]
            .as_str()
            .unwrap()
            .starts_with("v0.1.0 window 1/4 rows, due 11-22 (4 days left)"));
        assert_eq!(v["cards"][0]["window_says"], "1/4 due 11-22");
        assert_eq!(
            v["cards"][0]["window_share"], 25,
            "the bar fill surfaces draw, counted once here"
        );
        assert_eq!(v["cards"][0]["window"]["committed"], 4);
        // NEGATIVE CONTROL: a window recorded at a cut runs no sprint.
        assert_eq!(v["cards"][0]["sprint_says"], Value::Null);
        let mut locked = c.clone();
        if let Some(w) = locked.window.as_mut() {
            w.version = "v0.1.0".into();
            w.locked = Some("2026-11-19T18:05".into());
        }
        assert_eq!(
            sprint_says(&locked).as_deref(),
            Some("v0.1.0 1/4 due 11-22, locked 18:05"),
            "a sprint lock reads as a running sprint"
        );
        assert_eq!(v["cards"][0]["in_flight"], false);
        assert_eq!(
            v["cards"][0]["counts"],
            "0 running, 0 waiting, 0 queued; 0 rows #requested, 0 in the inbox"
        );
    }

    struct Argv(std::cell::RefCell<Vec<String>>);
    impl Runner for Argv {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            *self.0.borrow_mut() = argv.to_vec();
            Ok(String::new())
        }
    }

    #[test]
    fn the_prio_key_cycles_and_writes_through_the_cli_only() {
        assert_eq!(next_prio(""), "focus");
        assert_eq!(next_prio("focus"), "normal");
        let r = Argv(Default::default());
        set_prio(&r, "bnb", "shape-city", "focus", None).unwrap();
        assert_eq!(
            *r.0.borrow(),
            [
                "notes",
                "projects",
                "--prio",
                "shape-city",
                "--profile",
                "bnb",
                "--set",
                "focus"
            ]
        );
        // nothing that could read as a flag, and no value outside the vocabulary, reaches argv
        r.0.borrow_mut().clear();
        assert!(set_prio(&r, "bnb", "--all", "focus", None).is_err());
        assert!(set_prio(&r, "bnb", "demo", "urgent", None).is_err());
        // the retired ladder's words are refused: focus is the one project tag left
        assert!(set_prio(&r, "bnb", "demo", "high", None).is_err());
        assert!(set_prio(&r, "bnb", "demo", "low", None).is_err());
        // hours go with a focus only; their range is notes' to refuse
        assert!(set_prio(&r, "bnb", "demo", "normal", Some(2)).is_err());
        assert!(r.0.borrow().is_empty(), "a refused write runs nothing");
        set_prio(&r, "bnb", "demo", "focus", Some(2)).unwrap();
        assert_eq!(r.0.borrow()[8..], ["--hours", "2"]);
    }

    #[test]
    fn the_focus_strip_names_each_focus_and_its_end_and_offers_every_project() {
        let card = |name: &str, prio: &str, until: Option<&str>| Card {
            profile: "bnb".into(),
            name: name.into(),
            prio: prio.into(),
            focus_until: until.map(str::to_string),
            ..Default::default()
        };
        let f = focus_json(&[
            card("a", "focus", Some("2026-11-23 18:00 -0800")),
            card("b", "high", None),
        ]);
        assert_eq!(f["on"][0]["until"], "11-23 18:00");
        assert!(
            f["says"]
                .as_str()
                .unwrap()
                .starts_with("On focus: a until 11-23 18:00."),
            "{f}"
        );
        // A project on focus stays in the picker, so its end can be set again.
        assert_eq!(f["all"].as_array().unwrap().len(), 2);
        // NEGATIVE CONTROL: no focus says so, and offers every project.
        let f = focus_json(&[card("b", "high", None)]);
        assert!(f["on"].as_array().unwrap().is_empty());
        assert!(
            f["says"]
                .as_str()
                .unwrap()
                .starts_with("No project is on focus"),
            "{f}"
        );
    }

    #[test]
    fn a_card_carries_the_sheet_prio() {
        let s: Vec<Stats> =
            serde_json::from_value(json!([{"profile": "bnb", "name": "a", "prio": "focus"}, {"profile": "bnb", "name": "b"}]))
                .unwrap();
        let p = build(&s, None, &json!({}), None, chrono::Utc::now());
        let prio = |n: &str| p.cards.iter().find(|c| c.name == n).unwrap().prio.clone();
        assert_eq!(prio("a"), "focus");
        assert_eq!(prio("b"), "");
    }

    fn prog(open_w: u32, done_w: u32, closed_28: u32) -> Progress {
        Progress {
            open: open_w,
            done: done_w,
            open_weight: open_w,
            done_weight: done_w,
            closed_28d: closed_28,
            closed_weight_28d: closed_28,
            ..Progress::default()
        }
    }

    #[test]
    fn the_card_scores_its_window_and_never_the_backlog() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        let window = |due: Option<&str>, delivered, interrupted| Window {
            version: "v0.5.3".into(),
            opened: "2026-11-18".into(),
            due: due.map(String::from),
            committed: 84,
            delivered,
            open: 84 - delivered,
            interrupted,
            ..Window::default()
        };
        let stats = |w: Option<Window>| Stats {
            name: "ucp".into(),
            version: Some("v0.5.3".into()),
            progress: prog(990, 30, 12),
            window: w,
            ..Stats::default()
        };
        // NEGATIVE CONTROL: 990 open and 30 done read 2% as a backlog percent; with no snapshot
        // the card says `no window`, and no percent is anywhere in its JSON.
        let c = Card::from_stats(&stats(None), today);
        assert_eq!(
            (window_short(&c), window_words(&c)),
            ("no window".into(), "no window".into())
        );
        assert_eq!(window_share(&c), None);
        assert_eq!(
            (window_cell(&c), due_cell(&c)),
            ("no window".into(), "-".into())
        );
        let j = to_json(&Projects {
            cards: vec![c],
            ..Projects::default()
        });
        let text = j.to_string();
        assert!(
            !text.contains("percent") && !text.contains("eta_days") && !text.contains("2%"),
            "{text}"
        );
        assert_eq!(j["cards"][0]["window"], Value::Null);

        let c = Card::from_stats(&stats(Some(window(Some("2026-11-22"), 21, 0))), today);
        assert_eq!(c.window.as_ref().unwrap().days_left, Some(3));
        assert_eq!(window_short(&c), "21/84 due 11-22");
        assert_eq!(window_words(&c), "21/84 rows, due 11-22 (3 days left)");
        assert_eq!(window_share(&c), Some(25));
        assert_eq!(
            (window_cell(&c), due_cell(&c)),
            ("21/84".into(), "3d".into())
        );
        let c = Card::from_stats(&stats(Some(window(Some("2026-11-19"), 84, 1))), today);
        assert_eq!(
            window_words(&c),
            "84/84 rows, due 11-19 (due today), 1 interrupt"
        );
        let c = Card::from_stats(&stats(Some(window(Some("2026-11-16"), 0, 2))), today);
        assert_eq!(
            window_words(&c),
            "0/84 rows, due 11-16 (3 days over), 2 interrupts"
        );
        assert_eq!(due_cell(&c), "3d over");
        let c = Card::from_stats(&stats(Some(window(None, 0, 0))), today);
        assert_eq!(
            (window_short(&c), window_words(&c)),
            ("0/84".into(), "0/84 rows, no due day".into())
        );
        assert_eq!(c.window.as_ref().unwrap().days_left, None);
    }

    const STATE_DAY: (i32, u32, u32) = (2026, 11, 19);

    fn state_today() -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(STATE_DAY.0, STATE_DAY.1, STATE_DAY.2).unwrap()
    }

    /// A v0.2.0 window of 20 rows opened 11-10, due `due`, with `open` still open.
    fn state_window(due: &str, open: u32) -> Window {
        Window {
            version: "v0.2.0".into(),
            opened: "2026-11-10".into(),
            due: Some(due.into()),
            committed: 20,
            delivered: 20 - open,
            open,
            open_weight: open,
            ..Window::default()
        }
    }

    /// A card on `state_today()` with 990 open and 30 done, `closed_28` closes in the last 28
    /// days and its newest close on `last`.
    fn state_card(stage: &str, w: Option<Window>, closed_28: u32, last: Option<&str>) -> Card {
        let mut progress = prog(990, 30, closed_28);
        progress.last_closed = last.map(String::from);
        Card::from_stats(
            &Stats {
                name: "game".into(),
                stage: stage.into(),
                version: Some("v0.2.0".into()),
                progress,
                window: w,
                idle_days: 28,
                ..Stats::default()
            },
            state_today(),
        )
    }

    const TEN_DAYS_AGO: Option<&str> = Some("2026-11-09");

    fn with_target(c: &Card, target_on: &str, on_time: &'static str) -> Card {
        let mut c = c.clone();
        c.on_time = Some(OnTime {
            target_on: target_on.into(),
            state: on_time,
            ..OnTime::default()
        });
        c
    }

    #[test]
    fn each_state_row_matches_first_and_the_backlog_never_sets_one() {
        let today = state_today();
        let late = state_card(
            "alpha",
            Some(state_window("2026-11-18", 4)),
            280,
            TEN_DAYS_AGO,
        );
        // 28 weight closed in 28 days closes 3 in the 3 days left: 4 open is at risk, 3 is not.
        let short = state_card(
            "alpha",
            Some(state_window("2026-11-22", 4)),
            28,
            TEN_DAYS_AGO,
        );
        let on_track = state_card(
            "alpha",
            Some(state_window("2026-11-22", 3)),
            28,
            TEN_DAYS_AGO,
        );
        let target_past = with_target(&on_track, "2026-11-18", "on track");
        let never = with_target(&on_track, "2026-12-01", NEVER);
        let no_window = state_card("alpha", None, 0, TEN_DAYS_AGO);
        let mut waiting = state_card("draft", None, 0, None);
        waiting.waiting = 1;
        let idle = state_card("alpha", None, 0, Some("2026-10-22"));
        let parked = state_card("draft", None, 0, None);
        let got: Vec<&str> = [
            &late,
            &target_past,
            &short,
            &never,
            &on_track,
            &no_window,
            &waiting,
            &idle,
            &parked,
        ]
        .iter()
        .map(|c| state(c, today))
        .collect();
        assert_eq!(
            got,
            [LATE, LATE, AT_RISK, AT_RISK, ON_TRACK, FLOW, FLOW, IDLE, PARKED],
            "the last close 28 days back is idle; a waiting item is in flight"
        );
        let mut zero = idle.clone();
        zero.idle_days = 0;
        assert_eq!(
            state(&zero, today),
            IDLE,
            "idle_days 0 reads every quiet project idle"
        );
        // The rate is net of filings: 14 of the 28 refilled closes 1 in 3 days, short of 3.
        let mut filing = on_track.clone();
        filing.progress.filed_weight_28d = 14;
        assert_eq!(state(&filing, today), AT_RISK, "filings slow the rate");
        filing.progress.filed_weight_28d = 28;
        assert_eq!(
            state(&filing, today),
            AT_RISK,
            "filing as fast as closing closes none"
        );
        // It is weight against weight: one open row of 8 points outweighs the 3 that 3 days close.
        let mut heavy = state_card(
            "alpha",
            Some(state_window("2026-11-22", 1)),
            28,
            TEN_DAYS_AGO,
        );
        assert_eq!(
            state(&heavy, today),
            ON_TRACK,
            "NEGATIVE CONTROL: one unsized row fits"
        );
        heavy.window.as_mut().unwrap().open_weight = 8;
        assert_eq!(state(&heavy, today), AT_RISK, "an 8-point row does not");
        // A notes that sends no open_weight still reads at risk: each open row weighs at least 1.
        let mut unweighed = short.clone();
        unweighed.window.as_mut().unwrap().open_weight = 0;
        assert_eq!(
            state(&unweighed, today),
            AT_RISK,
            "the row count floors the weight"
        );
        assert_eq!(state_level(PARKED), None, "parked draws grey");
        assert_eq!(state_level(FLOW), None, "flow is no warning");
        let short = Card {
            state: AT_RISK,
            ..short
        };
        assert_eq!(state_says(&short), "at risk, 16/20 due 11-22");
        // A target past with no window keeps the cause; a flowing card says its state alone.
        let late = Card {
            state: LATE,
            window: None,
            ..short
        };
        assert_eq!(state_says(&late), "late, no window");
    }

    #[test]
    fn a_delivered_window_is_not_late() {
        let today = state_today();
        let delivered = state_card(
            "alpha",
            Some(state_window("2026-11-18", 0)),
            0,
            TEN_DAYS_AGO,
        );
        assert_eq!(
            state(&delivered, today),
            ON_TRACK,
            "every row delivered past the due day waits on the cut"
        );
        let delivered = with_target(&delivered, "2026-11-18", "on track");
        assert_eq!(
            state(&delivered, today),
            ON_TRACK,
            "and past the target day"
        );
    }

    #[test]
    fn an_unread_queue_states_no_card() {
        // An active project is never called idle on a guess.
        let s = Stats {
            name: "game".into(),
            stage: "alpha".into(),
            idle_days: 28,
            ..Stats::default()
        };
        let at = chrono::Utc::now();
        let state_with = |q: Option<&Queue>| {
            build(std::slice::from_ref(&s), None, &Value::Null, q, at).cards[0].state
        };
        assert_eq!(state_with(None), "");
        let broken = Queue {
            errors: vec!["agent-queue: not found".into()],
            ..Queue::default()
        };
        assert_eq!(state_with(Some(&broken)), "");
        assert_eq!(
            state_with(Some(&Queue::default())),
            IDLE,
            "NEGATIVE CONTROL: a read empty queue states the card"
        );
    }

    #[test]
    fn the_backlog_sets_no_state_and_a_flowing_card_says_flow_alone() {
        // NEGATIVE CONTROL: 990 open and 30 done set no state of their own; the card with no
        // window that closed lately is `flow`, uncoloured, its JSON carries no percent, and its
        // window cell still says `no window`.
        let no_window = state_card("alpha", None, 0, TEN_DAYS_AGO);
        let j = to_json(&Projects {
            cards: vec![Card {
                state: state(&no_window, state_today()),
                ..no_window
            }],
            ..Projects::default()
        });
        assert_eq!(
            (
                &j["cards"][0]["state"],
                &j["cards"][0]["state_level"],
                &j["cards"][0]["state_says"]
            ),
            (&json!("flow"), &Value::Null, &json!("flow")),
            "`flow` is said alone, in no hue"
        );
        assert_eq!(j["cards"][0]["window_cell"], "no window");
        assert!(!j.to_string().contains("percent"), "{j}");
    }

    #[test]
    fn state_words_are_the_stages_md_table() {
        let doc = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/stages.md"));
        let section = doc
            .split("\n## ")
            .find(|s| s.starts_with("Project state"))
            .expect("stages.md has a Project state section");
        let words: Vec<&str> = section
            .lines()
            .filter_map(|l| l.strip_prefix("| `")?.split('`').next())
            .collect();
        assert_eq!(
            words, STATES,
            "the table's states, in the order state() tries them"
        );
    }

    #[test]
    fn stats_parse_the_window_notes_emits() {
        let s: Vec<Stats> = serde_json::from_value(json!([{
            "name": "trader",
            "window": {"version": "v0.1.3", "opened": "2026-11-18", "due": "2026-11-22",
                       "committed": 105, "delivered": 2, "open": 103, "open_weight": 160,
                       "dropped": 0, "interrupted": 1},
            "last_window": {"version": "v0.1.2", "line": "delivered 3 of 4"}
        }, {"name": "bare", "window": null, "last_window": null}]))
        .unwrap();
        let w = s[0].window.as_ref().unwrap();
        assert_eq!(
            (
                w.committed,
                w.delivered,
                w.open,
                w.open_weight,
                w.interrupted
            ),
            (105, 2, 103, 160, 1)
        );
        assert_eq!(w.days_left, None, "the card dates it, notes does not");
        assert_eq!(s[0].last_window.as_ref().unwrap().line, "delivered 3 of 4");
        assert_eq!(
            (s[1].window.clone(), s[1].last_window.clone()),
            (None, None)
        );
    }

    fn st(name: &str, closed_7d: u32) -> Stats {
        Stats {
            profile: "personal".into(),
            name: name.into(),
            version: Some("v0.0.1".into()),
            progress: Progress {
                closed_7d,
                ..prog(4, 4, 4)
            },
            ..Stats::default()
        }
    }

    fn item(slug: &str, state: State, project: &str, row: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            state,
            project: project.into(),
            task: format!("Do {slug}."),
            row: row.map(String::from),
            ..Default::default()
        }
    }

    #[test]
    fn queue_items_join_by_ledger_row_or_shared_name_and_the_rest_are_unlinked() {
        let stats = [
            st("agent-runtime", 1),
            st("notes-cockpit", 9),
            st("trader", 0),
        ];
        let q = Queue {
            items: vec![
                item("a", State::Running, "dotfiles", Some("agent-runtime:ar-1")),
                item("b", State::Running, "trader", None),
                item("c", State::Waiting, "freqtrade", Some("trader:tr-2")),
                item("d", State::Queued, "dotfiles", None),
                item("f", State::Queued, "freqtrade", None),
                item("e", State::Done, "trader", None),
            ],
            ..Queue::default()
        };
        let feed = Feed {
            projects: vec![Project {
                profile: "personal".into(),
                project: "trader".into(),
                inbox: 2,
                agent_open: 75,
                agent_backlog: 210,
                epic_open: 3,
                epic_backlog: 9,
                ..Project::default()
            }],
            rows: vec![Row {
                profile: "personal".into(),
                project: Some("trader".into()),
                requested: true,
                ..Row::default()
            }],
            totals: Some(crate::tasks::Totals {
                open: 80,
                agent: 75,
                backlog: 210,
                ..Default::default()
            }),
            ..Feed::default()
        };
        let p = build(
            &stats,
            Some(&feed),
            &json!({}),
            Some(&q),
            chrono::Utc::now(),
        );
        let names: Vec<&str> = p.cards.iter().map(|c| c.name.as_str()).collect();
        // trader runs one and waits one; agent-runtime runs one; notes-cockpit closed most.
        assert_eq!(names, ["trader", "agent-runtime", "notes-cockpit"]);
        let trader = &p.cards[0];
        assert_eq!(
            (trader.running.len(), trader.waiting, trader.queued),
            (1, 1, 0)
        );
        assert_eq!((trader.inbox, trader.requested), (2, 1));
        // The agent board, backlog and feature epic counts in the words every surface uses; the
        // strip's Board is the agent board (totals.agent, the Today count), never every lane's open.
        assert!(counts(trader).ends_with("; Today 75 | Backlog 210 | Epics 3 | Epic backlog 9"));
        assert_eq!((p.board_open, p.board_backlog), (Some(75), Some(210)));
        assert!(
            !counts(&p.cards[2]).contains("Today"),
            "no feed project, no tiers"
        );
        assert_eq!(p.cards[1].running[0].slug, "a");
        assert_eq!(
            p.unlinked,
            ["dotfiles: Do d", "freqtrade: Do f"],
            "no row and no lab of that name: unlinked, never guessed from the repo"
        );
        assert!(p.cards[0].in_flight() && !p.cards[2].in_flight());
    }

    #[test]
    fn a_card_counts_its_board_slice_and_its_queue_slice() {
        use chrono::TimeZone;
        let now = chrono::Utc.with_ymd_and_hms(2026, 11, 7, 20, 0, 0).unwrap();
        let ago = |h: i64| (now - chrono::Duration::hours(h)).to_rfc3339();
        // Queued 50h ago, released from its hold 30h ago: it has been ready 30h.
        let mut ready_old = item("r1", State::Queued, "trader", None);
        ready_old.queued = Some(ago(50));
        ready_old.ready = Some(ago(30));
        let mut ready_new = item("r2", State::Queued, "trader", None);
        ready_new.queued = Some(ago(2));
        let mut today = item("t", State::Done, "trader", None);
        // An older minute stamp, no seconds and no zone, still reads as UTC.
        today.finished = Some(
            (now - chrono::Duration::minutes(30))
                .format("%Y-%m-%dT%H:%M")
                .to_string(),
        );
        today.status = Some("ok".into());
        today.merged = Some("abc123".into());
        // Closed today too: a check (ok, no merge) and a failed run with a merge, which counts
        // in neither.
        let mut check = item("k", State::Done, "trader", None);
        (check.finished, check.status) = (Some(ago(0)), Some("ok".into()));
        let mut failed = item("f", State::Done, "trader", None);
        (failed.finished, failed.status) = (Some(ago(0)), Some("failed".into()));
        failed.merged = Some("def456".into());
        let mut before = item("y", State::Done, "trader", None);
        before.finished = Some(ago(48));
        let q = Queue {
            items: vec![ready_old, ready_new, today, check, failed, before],
            ..Queue::default()
        };
        let row = |state: &str, priority: &str| Row {
            profile: "personal".into(),
            project: Some("trader".into()),
            state: state.into(),
            priority: priority.into(),
            ..Row::default()
        };
        let feed = Feed {
            rows: vec![
                row("open", "high"),
                row("doing", "urgent"),
                row("doing", "low"),
                row("open", ""),
                row("done", "high"),
                Row {
                    lane: "playtest".into(),
                    ..row("open", "high")
                },
                Row {
                    version: Some("v0.1.0".into()),
                    ..row("doing", "high")
                },
            ],
            ..Feed::default()
        };
        let p = build(&[st("trader", 3)], Some(&feed), &json!({}), Some(&q), now);
        let c = &p.cards[0];
        assert_eq!(
            (c.doing, c.hot),
            (2, 2),
            "a done, playtest or later-release row counts neither"
        );
        assert_eq!(
            (c.queued, c.today),
            (
                2,
                crate::queue::DoneToday {
                    shipped: 1,
                    checks: 1
                }
            )
        );
        assert_eq!(
            c.oldest_ready_min,
            Some(30 * 60),
            "ready since its release, not since it was queued"
        );
        assert_eq!(wait_word(c.oldest_ready_min), "30h");
        assert_eq!(wait_word(None), "-");
        let j = to_json(&p);
        assert_eq!(j["cards"][0]["oldest"], "30h");
        assert!(j["cards"][0].get("held").is_none(), "no held count");
    }

    #[test]
    fn the_summary_line_says_the_window_or_that_there_is_none() {
        let mut c = Card {
            version: Some("v0.0.1".into()),
            progress: prog(276, 314, 239),
            ..Card::default()
        };
        c.progress.closed_7d = 103;
        assert_eq!(
            summary(&c),
            "v0.0.1 no window, closed 103 in 7d, 239 in 28d; no target"
        );
        c.last_window = Some(LastWindow {
            version: "v0.0.0".into(),
            line: "delivered 3 of 4".into(),
        });
        assert_eq!(
            summary(&c),
            "v0.0.1 no window (last v0.0.0: delivered 3 of 4), closed 103 in 7d, 239 in 28d; \
             no target"
        );
        c.window = Some(Window {
            due: Some("2026-11-22".into()),
            committed: 84,
            delivered: 1,
            days_left: Some(1),
            ..Window::default()
        });
        assert_eq!(
            summary(&c),
            "v0.0.1 window 1/84 rows, due 11-22 (1 day left), closed 103 in 7d, 239 in 28d; \
             no target"
        );
    }

    #[test]
    fn the_version_eta_nets_out_scope_growth() {
        // 276 open, 239 closed and 99 filed in 28 days: 140 net, so 55.2 days, rounded up.
        assert_eq!(net_eta(276, 239, 99), Some(56));
        // NEGATIVE CONTROL: the close rate alone says 33 days.
        assert_eq!(net_eta(276, 239, 0), Some(33));
        // Filing as fast as it closes, or faster (dodginballs files 2x), never closes.
        for filed in [239, 478] {
            assert_eq!(net_eta(276, 239, filed), None, "filed {filed}");
        }
        assert_eq!(
            net_eta(0, 239, 478),
            Some(0),
            "nothing open is done, whatever is filed"
        );
    }

    fn targeted(on: &str, open: u32, closed: u32, filed: u32) -> Stats {
        Stats {
            target_version: Some("v0.3.0".into()),
            target_on: Some(on.into()),
            target_work: Some(TargetWork {
                open_weight: open,
                closed_weight_28d: closed,
                filed_weight_28d: filed,
            }),
            ..Stats::default()
        }
    }

    #[test]
    fn a_target_reads_on_track_late_never_or_no_target() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 18).unwrap();
        let card = |s: &Stats| Card::from_stats(s, today);
        // 28 open at 28 net per 28 days: 28 days, so 12-16.
        let on = card(&targeted("2026-12-16", 28, 40, 12));
        assert_eq!(on.on_time.as_ref().unwrap().state, "on track");
        assert_eq!(
            on_time_words(&on),
            "target v0.3.0 by 12-16: on track (ETA ~12-16)"
        );
        let late = card(&targeted("2026-12-07", 28, 40, 12));
        assert_eq!(
            (
                late.on_time.as_ref().unwrap().state,
                late.on_time.as_ref().unwrap().late_days
            ),
            ("late", 9)
        );
        assert_eq!(
            on_time_words(&late),
            "target v0.3.0 by 12-07: late 9 days (ETA ~12-16)"
        );
        let never = card(&targeted("2026-12-16", 28, 20, 40));
        assert_eq!(never.on_time.as_ref().unwrap().state, NEVER);
        assert_eq!(
            on_time_words(&never),
            "target v0.3.0 by 12-16: never at this rate"
        );
        // A promise already past with nothing open is late by the days since: it was not cut.
        let past = card(&targeted("2026-11-15", 0, 0, 0));
        assert_eq!(
            on_time_words(&past),
            "target v0.3.0 by 11-15: late 3 days (ETA ~11-18)"
        );
        // NEGATIVE CONTROL: no target, no verdict; an older notes with no target_work is
        // unread, never a guessed on track.
        assert_eq!(card(&Stats::default()).on_time, None);
        assert_eq!(on_time_words(&card(&Stats::default())), "no target");
        let old = Stats {
            target_work: None,
            ..targeted("2026-12-16", 0, 0, 0)
        };
        assert_eq!(card(&old).on_time.unwrap().state, "unread");
        let j = to_json(&Projects {
            cards: vec![late],
            ..Projects::default()
        });
        assert_eq!(j["cards"][0]["on_time"]["state"], "late");
        assert_eq!(j["cards"][0]["on_time"]["late_days"], 9);
    }

    #[test]
    fn room_is_what_the_net_rate_closes_by_the_target_less_the_work_aimed_at_it() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 18).unwrap();
        let room = |s: &Stats| Card::from_stats(s, today).on_time.unwrap().room_weight;
        // 28 net per 28 days for 28 days closes 28; 10 is aimed already, so 18 fits.
        assert_eq!(room(&targeted("2026-12-16", 10, 40, 12)), Some(18));
        // Rounded down: 27 days at 30 net per 28 close 28 (28.9).
        assert_eq!(room(&targeted("2026-12-15", 0, 42, 12)), Some(28));
        // The aimed work alone overruns the target: negative, so nothing more fits.
        assert_eq!(room(&targeted("2026-12-07", 28, 40, 12)), Some(-9));
        // A target already past closes nothing more.
        assert_eq!(room(&targeted("2026-11-15", 3, 40, 12)), Some(-3));
        // NEGATIVE CONTROL: filing as fast as closing leaves no room to plan into, even with
        // nothing open, and an unread target has none either.
        assert_eq!(room(&targeted("2026-12-16", 0, 20, 20)), None);
        assert_eq!(room(&targeted("2026-12-16", 28, 20, 40)), None);
        let old = Stats {
            target_work: None,
            ..targeted("2026-12-16", 0, 0, 0)
        };
        assert_eq!(room(&old), None);
        let j = to_json(&Projects {
            cards: vec![Card::from_stats(&targeted("2026-12-16", 10, 40, 12), today)],
            ..Projects::default()
        });
        assert_eq!(j["cards"][0]["on_time"]["room_weight"], 18);
    }

    #[test]
    fn a_version_line_sums_its_feature_epics_and_leaves_standing_ones_out() {
        let e =
            |id: &str, title: &str, system: &str, version: &str, open: u32, done: u32| EpicRollup {
                id: id.into(),
                title: title.into(),
                system: system.into(),
                version: version.into(),
                open_weight: open,
                done_weight: done,
                ..EpicRollup::default()
            };
        let epics = [
            e("g-1", "pause menu", "ui", "v0.10.0", 8, 2),
            e("g-2", "net code", "net", "v0.3.0", 5, 5),
            e("g-3", "save slots", "save", "v0.3.0", 10, 0),
            // NEGATIVE CONTROL: standing upkeep and an epic spanning releases are in no line.
            e("g-4", "ui to standard", "ui", "v0.3.0", 50, 50),
            e("g-5", "big idea", "core", "", 9, 9),
        ];
        let v = version_epics(&epics);
        let words: Vec<String> = v.iter().map(version_words).collect();
        assert_eq!(
            words,
            [
                "v0.3.0: 2 open epics, 5 of 20 points done",
                "v0.10.0: 1 open epic, 2 of 10 points done"
            ],
            "earliest release first, by number, not by text"
        );
        let j = to_json(&Projects {
            cards: vec![Card {
                versions: v,
                ..Card::default()
            }],
            ..Projects::default()
        });
        assert_eq!(j["cards"][0]["version_lines"][1], words[1]);
    }
}
