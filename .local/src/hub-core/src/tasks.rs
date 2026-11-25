//! The task board: every project's rows, open and closed, as `notes board --json` prints them,
//! for agent-web's Board tab and the hub TUI's. `notes` is the sheets' only writer, so this
//! module never opens a sheet: it reads the feed through a `Runner` and writes with
//! `notes ptask ... --exact`, which matches the row's raw line byte for byte and writes nothing
//! when the row changed since the read (design: notes-cli README, "The task feed").

use serde::{Deserialize, Serialize};

use crate::session_actions::Runner;
use crate::table::Val;

/// A board row's priorities, most urgent first: notes-cli `md::PRIORITIES`, whose default is
/// `normal`, so an untagged row reads normal in the feed. A queue item's are `queue::PRIORITIES`.
pub const PRIORITIES: [&str; 4] = ["urgent", "high", "normal", "low"];

/// The priority an untagged row reads as (notes-cli `md::DEFAULT_PRIORITY`).
pub const DEFAULT_PRIORITY: &str = "normal";

/// The lanes a board can write. The feed's `focus` rows are counted into `Feed::focus` and
/// left out of `rows`: a profile's Focus is the Daily tab's (`crate::focus`), and a board shows
/// only how many are open, linking there.
pub const LANES: [&str; 3] = ["human", "agent", "playtest"];

/// One project, listed even with no open rows so a board can offer `add` on it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Project {
    pub profile: String,
    pub project: String,
    pub dir: String,
    pub version: Option<String>,
    pub open: usize,
    /// The agent sheet's open rows on its board: the backlog tier (`agent_backlog`) left out.
    pub agent_open: usize,
    /// The agent sheet's open rows still carrying the retired `tier:backlog` token, which the sweep
    /// strips.
    pub agent_backlog: usize,
    /// The human sheet's open feature epics aimed at a release (`#vX.Y.Z`), and the untagged
    /// ones aimed at none; standing `<system> to standard` epics are in neither.
    pub epic_open: usize,
    pub epic_backlog: usize,
    pub playtest_open: usize,
    /// Lines waiting in the sheet's `## Inbox` for the triager.
    pub inbox: usize,
    /// The open version's release window (notes-cli `window::Sprint`), `None` with no window
    /// recorded: then its agent board is the rolling Today tier alone.
    pub sprint: Option<Sprint>,
}

/// A release window's rows still open of the rows it holds (its snapshot plus the interrupts
/// that entered it): the tiers line's `Sprint O/C` and waybar's `S`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Sprint {
    pub open: usize,
    pub committed: usize,
}

impl Project {
    /// Its window, agent board, Backlog tier and feature epics, as the tiers line shows them.
    pub fn tiers(&self) -> Tiers {
        Tiers {
            sprint: self.sprint.unwrap_or_default(),
            board: self.agent_open,
            backlog: self.agent_backlog,
            epics: self.epic_open,
            epic_backlog: self.epic_backlog,
        }
    }
}

/// The rows under an epic: open ones and closed ones, counted over the whole feed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Children {
    pub open: usize,
    pub done: usize,
}

impl Children {
    /// The ROWS cell: `12 open / 4 done`.
    pub fn words(&self) -> String {
        format!("{} open / {} done", self.open, self.done)
    }
}

/// One open row. `raw` is the line as it stands, what a write passes back.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Row {
    pub profile: String,
    /// None on a focus row.
    pub project: Option<String>,
    pub lane: String,
    pub version: Option<String>,
    pub game: Option<String>,
    /// The row's `type(area):` type (`feat`, `run`, ...), when its title has a well-formed one.
    pub r#type: Option<String>,
    /// That prefix's area (`ci`, `gameplay`, ...).
    pub area: Option<String>,
    pub state: String,
    pub priority: String,
    pub tier: Option<u8>,
    pub worker: Option<String>,
    /// The row's `#size/<s|m|l>`, without the prefix.
    pub size: Option<String>,
    /// The row's `#pts/<n>` estimate, None when unscored.
    pub points: Option<u32>,
    pub requested: bool,
    /// The row's `<code>-<n>` id, when its project has a code.
    pub id: Option<String>,
    pub text: String,
    pub tags: Vec<String>,
    pub marker: Option<String>,
    pub since: Option<String>,
    /// `YYYY-MM-DD` the triager filed it from an inbox (its `filed:` marker token).
    pub filed: Option<String>,
    /// `filed` is the feed's `today`, which `feed` works out: a row alone cannot know the day.
    pub filed_today: bool,
    pub sheet: String,
    pub line: usize,
    pub raw: String,
    /// The sheet section the sweep lays it out in (`epics`, `now`, `next`, `backlog`, `done`);
    /// None on a playtest row. With `rank` it is the one order a view draws (notes-cli rank.rs).
    pub section: Option<String>,
    /// Smaller is sooner; comparable across sheets.
    pub rank: u64,
    /// `#dueMMDD` as `YYYY-MM-DD`.
    pub due: Option<String>,
    /// The id its `#of/<id>` names.
    pub parent: Option<String>,
    /// What a board leads the row with, a few words (`row_title`); set by [`feed`].
    pub title: String,
    /// What the title leaves out of the text (`row_title`); set by [`feed`].
    pub summary: String,
    /// The title of the epic `parent` names, when that row is on the board; set by [`feed`].
    pub epic: Option<String>,
    /// The epic `parent` names is an open epic row, so it lists on the `epics` chip; a closed one
    /// is on Done. Set by [`Feed::titles`].
    pub epic_open: bool,
    /// What hangs under an epic row, from the rows' `parent` links; set by [`Feed::titles`].
    /// None on a row that is not an epic.
    pub children: Option<Children>,
    /// The `#size/` weight, 1 unsized.
    pub weight: u32,
    /// The day a closed row closed.
    pub closed: Option<String>,
    /// The PRs its marker names.
    pub prs: Vec<String>,
    /// `YYYY-MM-DD` the row should close at the project's net weight rate, after every row
    /// ranked ahead of it (`projects::forecast`). Never in the sheet.
    pub forecast: Option<String>,
    /// The state of the queue item whose `row:` names it (`queued`, `running`, `waiting`,
    /// `review`), set by `queue_states`.
    pub queue: Option<String>,
    /// The agent row carries the retired `tier:backlog` token, which the sweep strips, so
    /// no Board count holds it, and its `section` is `backlog`, after the board's `board` rows.
    pub backlog: bool,
}

/// The sections in sheet order, then a row in none (a playtest check). `board` is the agent
/// board's rows inside its budget; the human sheet has none.
pub const SECTIONS: [&str; 6] = ["epics", "now", "next", "board", "backlog", "done"];

/// A section's place in [`SECTIONS`]; past the end for a row in none.
pub fn section_order(section: Option<&str>) -> usize {
    section
        .and_then(|s| SECTIONS.iter().position(|x| *x == s))
        .unwrap_or(SECTIONS.len())
}

/// The heading a surface draws over a section, the sheet's own words.
pub fn section_title(section: Option<&str>) -> &'static str {
    match section {
        Some("epics") => "EPICS",
        Some("now") => "NOW",
        Some("next") => "NEXT UP",
        Some("board") => "BOARD",
        Some("backlog") => "BACKLOG",
        Some("done") => "DONE",
        _ => "PLAYTEST",
    }
}

/// Each row's section cell on a board: `NEXT UP (10)` over the first row of a section and blank
/// under it, the way the sheet reads, while the rows are in the sheet's order; under any other
/// sort each row names its own. Closed rows run by the day they closed (`DONE 11-07 (12)`, or
/// `DONE no day` for a row ticked with no `done:` marker), so the Done chip reads as a day log;
/// under another sort a closed row still names its day. The hub and agent-web both draw these.
pub fn section_labels(rows: &[&Row], sorted: bool) -> Vec<String> {
    /// A row's run: its section and, on a closed row, the day it closed (None: no marker).
    fn of(r: &Row) -> (Option<&str>, Option<Option<&str>>) {
        let day = (r.state == "done").then_some(r.closed.as_deref());
        (r.section.as_deref(), day)
    }
    rows.iter()
        .enumerate()
        .map(|(i, r)| {
            let title = match of(r).1 {
                Some(Some(d)) => format!(
                    "{} {}",
                    section_title(r.section.as_deref()),
                    crate::text::short_day(d)
                ),
                Some(None) => format!("{} no day", section_title(r.section.as_deref())),
                None => section_title(r.section.as_deref()).to_string(),
            };
            if sorted {
                return title;
            }
            if i > 0 && of(rows[i - 1]) == of(r) {
                return String::new();
            }
            let n = rows[i..].iter().take_while(|x| of(x) == of(r)).count();
            format!("{title} ({n})")
        })
        .collect()
}

impl Row {
    /// What a board draws beside the row, the same words on every surface: a closed row's day
    /// and PRs (`11-07 pr 63`), else its queue item's state and its forecast day (`queued
    /// ~11-12`).
    pub fn when(&self) -> String {
        self.when_with(self.forecast.as_deref())
    }

    /// [`Row::when`] with `forecast` in place of the row's own, for a view that draws the day
    /// on fewer rows than the board does.
    pub fn when_with(&self, forecast: Option<&str>) -> String {
        use crate::text::short_day;
        let words: Vec<String> = if self.state == "done" {
            let prs = (!self.prs.is_empty()).then(|| format!("pr {}", self.prs.join(" ")));
            self.closed
                .as_deref()
                .map(|d| short_day(d).to_string())
                .into_iter()
                .chain(prs)
                .collect()
        } else {
            let at = forecast.map(|f| format!("~{}", short_day(f)));
            self.queue.clone().into_iter().chain(at).collect()
        };
        words.join("  ")
    }

    /// An epic: a row the sweep lays out in the `epics` section. It lists on its own chip, never
    /// among the tasks.
    pub fn is_epic(&self) -> bool {
        self.section.as_deref() == Some("epics")
    }

    /// Started (`[/]`).
    pub fn doing(&self) -> bool {
        self.state == "doing"
    }

    /// Tagged `#urgent` or `#high`.
    pub fn hot(&self) -> bool {
        matches!(self.priority.as_str(), "urgent" | "high")
    }

    /// What it ships in: a playtest check's game, any other row's version.
    pub fn release(&self) -> Option<&str> {
        if self.lane == "playtest" {
            self.game.as_deref()
        } else {
            self.version.as_deref()
        }
    }
}

/// The rows table on both surfaces: agent-web's Projects rows and the hub's. `profile` and `tag`
/// are query keys, not drawn; `tag:` takes any of a row's tags.
impl crate::table::Row for Row {
    const COLUMNS: &'static [&'static str] = &[
        "section", "type", "area", "title", "epic", "priority", "state", "when", "project", "lane",
        "id", "version", "size", "pts", "tier", "since", "text", "profile", "tag", "rows",
    ];
    const STATES: &'static [&'static str] = &[
        "all",
        "in progress",
        "epics",
        "filed today",
        "urgent",
        "requested",
        "done",
    ];
    const FACETS: &'static [&'static str] = &[
        "section", "type", "area", "epic", "project", "lane", "priority", "state",
    ];
    const LEAD: &'static str = "title";
    const GLANCE: &'static [&'static str] = &["epic", "rows", "priority", "state"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| Val::Text(s.to_string());
        let some = |s: Option<&str>| s.map_or(Val::None, text);
        match col {
            "section" => text(self.section.as_deref().unwrap_or("playtest")),
            "priority" => text(&self.priority),
            "project" => some(self.project.as_deref()),
            "lane" => text(&self.lane),
            "state" => text(&self.state),
            "id" => some(self.id.as_deref()),
            "version" => some(self.release()),
            "size" => some(self.size.as_deref()),
            "pts" => self.points.map_or(Val::None, |n| Val::Num(f64::from(n))),
            "tier" => self.tier.map_or(Val::None, |t| Val::Num(f64::from(t))),
            "since" => some(self.since.as_deref()),
            "when" => match self.when() {
                w if w.is_empty() => Val::None,
                w => Val::Text(w),
            },
            "text" => text(&self.text),
            "title" => text(&self.title),
            "type" => some(self.r#type.as_deref()),
            "area" => some(self.area.as_deref()),
            "epic" => some(self.epic.as_deref()),
            "profile" => text(&self.profile),
            "tag" if self.tags.is_empty() => Val::None,
            "tag" => Val::Text(self.tags.join(" ")),
            "rows" => self.children.map_or(Val::None, |c| Val::Text(c.words())),
            _ => Val::None,
        }
    }

    /// Every chip but `epics` lists tasks: an epic is a deliverable, listed on its own chip with
    /// what hangs under it.
    fn in_default(&self) -> bool {
        !self.is_epic()
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "epics" => self.is_epic(),
            "in progress" => self.doing() && !self.is_epic(),
            "filed today" => self.filed_today && !self.is_epic(),
            // Asks of work still open: a closed row is Done's, not the chip's.
            "urgent" => self.state != "done" && self.priority == "urgent" && !self.is_epic(),
            "requested" => self.state != "done" && self.requested && !self.is_epic(),
            // Every closed row, by day then project (`Feed::board_rows`), with its PR in WHEN.
            "done" => self.state == "done",
            _ => false,
        }
    }

    /// A bare word searches where the row lives and its whole line, so `#tag` still finds it.
    fn text(&self) -> String {
        let project = self.project.as_deref().unwrap_or_default();
        format!("{}/{project}\n{}", self.profile, self.raw).to_lowercase()
    }

    /// The epic cell opens the epic's row, on the epics chip while it is open and on the default
    /// chip once it is closed; an epic's rows cell opens the rows under it.
    fn link(&self, col: &str) -> Option<crate::links::Link> {
        use crate::links::{Kind, Link};
        match col {
            "epic" => self.parent.as_deref().map(|e| {
                let kind = if self.epic_open {
                    Kind::Epic
                } else {
                    Kind::Row
                };
                Link::to(kind, e)
            }),
            "rows" => self
                .children
                .and(self.id.as_deref())
                .map(|id| Link::to(Kind::Children, id)),
            _ => None,
        }
    }

    fn vals(&self, col: &str) -> Vec<Val> {
        if col == "tag" {
            return self.tags.iter().cloned().map(Val::Text).collect();
        }
        vec![self.val(col)]
    }

    fn rank(&self, col: &str) -> Val {
        let at = |list: &[&str], v: &str| {
            list.iter()
                .position(|x| *x == v)
                .map_or(Val::None, |i| Val::Num(i as f64))
        };
        match col {
            // The sheet's order: the section, then the feed's rank within it.
            "section" => {
                Val::Num(section_order(self.section.as_deref()) as f64 * 1e15 + self.rank as f64)
            }
            "when" => self
                .forecast
                .as_deref()
                .or(self.closed.as_deref())
                .map_or(Val::None, |d| Val::Text(d.to_string())),
            // Ascending sorts low first: the reverse of `PRIORITIES`, most urgent first.
            "priority" => PRIORITIES
                .iter()
                .position(|p| *p == self.priority)
                .map_or(Val::None, |i| Val::Num((PRIORITIES.len() - 1 - i) as f64)),
            "size" => self
                .size
                .as_deref()
                .map_or(Val::None, |s| at(&["xs", "s", "m", "l", "xl"], s)),
            "version" => self
                .release()
                .map_or(Val::None, |v| Val::Text(release_order(v))),
            // Most open rows first under a descending sort, not the words' alphabet.
            "rows" => self.children.map_or(Val::None, |c| Val::Num(c.open as f64)),
            _ => self.val(col),
        }
    }
}

/// `v0.10.0` as text that sorts after `v0.9.0`; a playtest game's name stays itself. All text, so
/// the two kinds still compare in one total order.
pub(crate) fn release_order(v: &str) -> String {
    let parts = v.strip_prefix('v').map(|n| {
        n.split('.')
            .map(str::parse::<u32>)
            .collect::<Result<Vec<_>, _>>()
    });
    match parts {
        Some(Ok(n)) => n
            .iter()
            .map(|x| format!("{x:010}"))
            .collect::<Vec<_>>()
            .join("."),
        _ => v.to_string(),
    }
}

/// A profile's open Focus rows, counted.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct FocusOpen {
    pub profile: String,
    pub open: usize,
}

/// The board's one count, the feed's `totals` (notes-cli `board::Totals`): every open row, open
/// or doing, on the human, agent and playtest sheets, never a Focus or closed row. Home's Board
/// card and the waybar hover's `all lanes` line show `open`; the Projects strip and waybar's `T`
/// show `agent`, the Today of the tiers line. `sprint` is every release window summed, the
/// tiers line's Sprint and waybar's `S`. No reader counts for itself. An agent row on the backlog
/// tier is in `backlog` alone, never in the others. `epic_open` and `epic_backlog` are every project's.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Totals {
    pub open: usize,
    pub doing: usize,
    pub human: usize,
    pub agent: usize,
    pub playtest: usize,
    pub backlog: usize,
    pub epic_open: usize,
    pub epic_backlog: usize,
    pub sprint: Sprint,
}

/// The release windows, the agent board's rows and the human sheet's feature epics: the
/// windows' Sprint, the board (Today), its Backlog tier, epics aimed at a release, and epics
/// aimed at none (notes-cli `epics::strip_counts`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
pub struct Tiers {
    pub sprint: Sprint,
    pub board: usize,
    pub backlog: usize,
    pub epics: usize,
    pub epic_backlog: usize,
}

impl Tiers {
    /// The one form every surface shows, the words `notes board` and `notes doctor` print
    /// (notes-cli `board::tiers`): `Sprint 12/71 | Today 75 | Backlog 210 | Epics 4 | Epic
    /// backlog 12`, the Sprint left out when no window is recorded.
    pub fn words(&self) -> String {
        let head = if self.sprint.committed > 0 {
            format!("Sprint {}/{} | ", self.sprint.open, self.sprint.committed)
        } else {
            String::new()
        };
        format!(
            "{head}Today {} | Backlog {} | Epics {} | Epic backlog {}",
            self.board, self.backlog, self.epics, self.epic_backlog
        )
    }
}

/// One focus window as the feed carries it: its counts and cut for a reader that sorts or
/// colours, and `line`, the words notes-cli's one formatter wrote and every surface shows.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SprintLine {
    pub profile: String,
    pub project: String,
    pub version: String,
    pub done: usize,
    pub committed: usize,
    /// The window's due day, `YYYY-MM-DD`.
    pub due: Option<String>,
    /// The cut moment, `YYYY-MM-DDTHH:MM`: the cut row naming the project, else the sprint lock's cut.
    pub cut: Option<String>,
    /// `none`, `held`, `queued`, `building` or `built`.
    pub build: String,
    /// What the last cut carried into the window.
    pub carried: Option<usize>,
    pub line: String,
    /// The day the window opened, `YYYY-MM-DD`.
    pub opened: String,
    /// When a sprint lock was taken, `YYYY-MM-DDTHH:MM`; absent for a window recorded at a cut.
    pub locked: Option<String>,
    /// The next version's sprint, locked while the open one runs: it has not started.
    pub queued: bool,
    /// When a queued sprint starts, `YYYY-MM-DDTHH:MM`: the cut of the window before it.
    pub start: Option<String>,
    /// The weight of the tasks still open or in progress.
    pub remaining_weight: u32,
    /// The project's shipped weight per hour over the last 7 days; 0.0 with no history.
    pub rate_per_hour: f64,
}

/// A sprint row's times, in the words every surface shows ([`SprintLine::times`]).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SprintTimes {
    /// A queued sprint's start `MM-DD HH:MM`, else the lock moment, else the day it opened `MM-DD`.
    pub started: String,
    /// The cut `MM-DD HH:MM`, else the due day `MM-DD`, else `-`.
    pub cut: String,
    /// Until the cut: `49m`, `3h 20m`, `2d`, `over` once it passed, `-` with no cut; `queued`
    /// for a sprint that has not started.
    pub left: String,
    /// When the open weight lands at the 7-day rate, from now or a queued sprint's start when
    /// later: `~15:40` today, `~11-20 09:00` later, `done` with nothing open,
    /// [`crate::reading::NO_DATA`] with no rate.
    pub finish: String,
    /// The projected finish falls after the cut.
    pub late: bool,
}

/// One row of the Sprints table: a release window with its times worked out at one moment, its
/// version linking to the window's page. Built by [`Feed::sprint_rows`]; both surfaces draw it as it is.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SprintRow {
    pub profile: String,
    pub project: String,
    pub version: String,
    #[serde(flatten)]
    pub times: SprintTimes,
    /// `<done>/<committed>`.
    pub done: String,
    /// `none`, `held`, `queued`, `building` or `built`.
    pub build: String,
    /// The next version's sprint, locked while the open one runs: it has not started.
    pub queued: bool,
}

impl crate::table::Row for SprintRow {
    const COLUMNS: &'static [&'static str] = &[
        "project", "version", "started", "cut", "left", "done", "finish", "build",
    ];
    const STATES: &'static [&'static str] = &["all", "late"];
    const FACETS: &'static [&'static str] = &[];
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["left", "done", "finish"];

    fn val(&self, col: &str) -> crate::table::Val {
        use crate::table::Val;
        match col {
            "project" => Val::Text(self.project.clone()),
            "version" => Val::Text(self.version.clone()),
            "started" => Val::Text(self.times.started.clone()),
            "cut" => Val::Text(self.times.cut.clone()),
            "left" => Val::Text(self.times.left.clone()),
            "done" => Val::Text(self.done.clone()),
            "finish" => Val::Text(self.times.finish.clone()),
            "build" => Val::Text(self.build.clone()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        s == "late" && self.times.late
    }
    /// The window opens on its own page, from either surface.
    fn link(&self, col: &str) -> Option<crate::links::Link> {
        use crate::links::{Kind, Link};
        let key = format!("{}/{}", self.profile, self.project);
        match col {
            "version" => Some(Link::to(Kind::Sprint, format!("{key}/{}", self.version))),
            "project" => Some(Link::to(Kind::Project, key)),
            _ => None,
        }
    }
}

/// The Sprints table's column heads, the same words on both surfaces: FINISH names the rate it
/// projects from (dashboards.md: an ETA names its window). The window is notes-cli
/// `project_tasks::BUDGET_WINDOW_DAYS`; change this head with it.
pub const SPRINT_HEADS: [(&str, &str); 8] = [
    ("project", "PROJECT"),
    ("version", "VERSION"),
    ("started", "STARTED"),
    ("cut", "CUT"),
    ("left", "LEFT"),
    ("done", "DONE"),
    ("finish", "FINISH (7d rate)"),
    ("build", "BUILD"),
];

/// `MM-DD HH:MM` of a `YYYY-MM-DDTHH:MM`.
fn short_moment(m: &chrono::NaiveDateTime) -> String {
    m.format("%m-%d %H:%M").to_string()
}

fn parse_moment(s: Option<&str>) -> Option<chrono::NaiveDateTime> {
    chrono::NaiveDateTime::parse_from_str(s?, "%Y-%m-%dT%H:%M").ok()
}

impl SprintLine {
    /// The moment the sprint ends: its cut, else the end of its due day.
    fn end(&self) -> Option<chrono::NaiveDateTime> {
        parse_moment(self.cut.as_deref()).or_else(|| {
            let due = chrono::NaiveDate::parse_from_str(self.due.as_deref()?, "%Y-%m-%d").ok()?;
            (due + chrono::Duration::days(1)).and_hms_opt(0, 0, 0)
        })
    }

    /// Its start, cut, time left and projected finish at `now`: the one place either surface
    /// reads them. The finish is an estimate: the open weight over the project's 7-day shipped
    /// rate, and no estimate at all when that rate is 0.
    pub fn times(&self, now: chrono::NaiveDateTime) -> SprintTimes {
        let start = parse_moment(self.start.as_deref());
        let started = start
            .or_else(|| parse_moment(self.locked.as_deref()))
            .map(|m| short_moment(&m))
            .unwrap_or_else(|| match self.opened.as_str() {
                "" => "-".to_string(),
                d => crate::text::short_day(d).to_string(),
            });
        let end = self.end();
        let cut = match (parse_moment(self.cut.as_deref()), self.due.as_deref()) {
            (Some(c), _) => short_moment(&c),
            (None, Some(d)) => crate::text::short_day(d).to_string(),
            (None, None) => "-".to_string(),
        };
        let left = end.map_or_else(
            || "-".to_string(),
            |e| match (e - now).num_minutes() {
                _ if self.queued => "queued".to_string(),
                _ if e <= now => "over".to_string(),
                0 => "<1m".to_string(),
                m if m < 60 => format!("{m}m"),
                m if m < 48 * 60 => format!("{}h {}m", m / 60, m % 60),
                m => format!("{}d", m / (24 * 60)),
            },
        );
        let finish_at = (self.remaining_weight > 0 && self.rate_per_hour > 0.0).then(|| {
            let mins = (f64::from(self.remaining_weight) / self.rate_per_hour * 60.0).ceil();
            let from = start.filter(|s| self.queued && *s > now).unwrap_or(now);
            from + chrono::Duration::minutes(mins.min(1e7) as i64)
        });
        let finish = match finish_at {
            // A feed from a notes that predates the weights reads 0 weight with rows still open:
            // no data, never done.
            _ if self.done >= self.committed => "done".to_string(),
            None => crate::reading::NO_DATA.to_string(),
            Some(f) if f.date() == now.date() => format!("~{}", f.format("%H:%M")),
            Some(f) => format!("~{}", short_moment(&f)),
        };
        SprintTimes {
            started,
            cut,
            left,
            finish,
            late: matches!((finish_at, end), (Some(f), Some(e)) if f > e),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Feed {
    /// The day the feed was read (`YYYY-MM-DD`, the CLI's clock), what `filed` compares to.
    pub today: String,
    /// `None` from a notes that predates `totals`: every Board number then reads `-`, never 0.
    pub totals: Option<Totals>,
    pub projects: Vec<Project>,
    /// Every project's open rows; never a `focus` row.
    pub rows: Vec<Row>,
    /// Closed rows, newest first (the feed's `done`).
    pub done: Vec<Row>,
    /// Each profile with open Focus rows, in feed order.
    pub focus: Vec<FocusOpen>,
    /// What a board read could not join on (`sheet_view::feed`: the stats, the queue), so a
    /// row with no forecast or queue state says why.
    pub errors: Vec<String>,
    /// One line per open release window and per sprint queued behind one (notes-cli
    /// `board::FeedSprint`), in the CLI's words:
    /// `<project> <version> <done>/<committed> cut <day time> build <state>`, so no surface
    /// formats one itself. Empty from a notes that predates it.
    pub sprints: Vec<SprintLine>,
}

/// Is `r` in `scope`, a (profile, project), or is there no scope?
fn in_scope(r: &Row, scope: Option<(&str, &str)>) -> bool {
    scope.is_none_or(|(profile, project)| {
        r.profile == profile && r.project.as_deref() == Some(project)
    })
}

impl Feed {
    /// The open rows of one project as (profile, project), or of every project: the rows table
    /// before any view, in the sheet's order: by section, then the feed's rank. Neither is
    /// derived here; notes-cli's sweep and rank own both.
    /// The row `project`'s `id` names, open or closed; the project matches without case.
    pub fn row(&self, project: &str, id: &str) -> Option<&Row> {
        self.rows.iter().chain(&self.done).find(|r| {
            r.id.as_deref() == Some(id)
                && r.project
                    .as_deref()
                    .is_some_and(|p| p.eq_ignore_ascii_case(project))
        })
    }

    pub fn open_rows(&self, scope: Option<(&str, &str)>) -> Vec<&Row> {
        let mut rows: Vec<&Row> = self
            .rows
            .iter()
            .filter(|r| r.state != "done" && in_scope(r, scope))
            .collect();
        rows.sort_by_key(|r| (section_order(r.section.as_deref()), r.rank));
        rows
    }

    /// The release windows, agent board and backlog counts and the feature epics in
    /// [`Tiers::words`]: every project's from `totals`, one project's from its `projects` entry.
    /// None when the feed carries neither (an older notes, or a project it does not list), so a
    /// view shows nothing rather than a 0. The epic pair and the sprint default to 0 on a notes
    /// older than them: notes and the hub build from this one repo, so that skew lasts one rebuild.
    pub fn agent_tiers(&self, scope: Option<(&str, &str)>) -> Option<String> {
        let t = match scope {
            None => self.totals.map(|t| Tiers {
                sprint: t.sprint,
                board: t.agent,
                backlog: t.backlog,
                epics: t.epic_open,
                epic_backlog: t.epic_backlog,
            })?,
            Some((profile, project)) => self
                .projects
                .iter()
                .find(|p| p.profile == profile && p.project == project)
                .map(Project::tiers)?,
        };
        Some(t.words())
    }

    /// The release windows' lines ([`SprintLine`]): every project's, or one project's from its
    /// (profile, project). Empty when none is recorded, so a view shows no line, never a 0.
    pub fn sprint_lines(&self, scope: Option<(&str, &str)>) -> Vec<&str> {
        self.sprints_in(scope)
            .into_iter()
            .map(|s| s.line.as_str())
            .collect()
    }

    /// The board's rows: the open ones as `open_rows` orders them, then the closed ones newest
    /// first, each day's by project, so Done reads as the days' work.
    pub fn board_rows(&self, scope: Option<(&str, &str)>) -> Vec<&Row> {
        let mut done: Vec<&Row> = self.done.iter().filter(|r| in_scope(r, scope)).collect();
        done.sort_by(|a, b| {
            b.closed
                .cmp(&a.closed)
                .then_with(|| a.project.cmp(&b.project))
                .then_with(|| a.profile.cmp(&b.profile))
        });
        let mut rows = self.open_rows(scope);
        rows.extend(done);
        rows
    }

    /// Give every row its [`row_title`] (plan files under `home`), each row
    /// under an epic that epic's title, and each epic its [`Children`], counted over the open
    /// and the closed rows by (project, parent).
    pub fn titles(&mut self, home: &str) {
        for r in self.rows.iter_mut().chain(&mut self.done) {
            (r.title, r.summary) = row_title(home, &r.text);
        }
        let by: std::collections::HashMap<(String, String), String> = self
            .rows
            .iter()
            .chain(&self.done)
            .filter_map(|r| {
                Some((
                    (r.project.clone()?.to_lowercase(), r.id.clone()?),
                    r.title.clone(),
                ))
            })
            .collect();
        let mut kids: std::collections::HashMap<(String, String), Children> =
            std::collections::HashMap::new();
        let open_epics: std::collections::HashSet<(String, String)> = self
            .rows
            .iter()
            .filter(|r| r.is_epic())
            .filter_map(|r| Some((r.project.clone()?.to_lowercase(), r.id.clone()?)))
            .collect();
        // A sub-epic lists on the epics chip, not among the epic's rows, so it is not counted.
        for (r, closed) in self
            .rows
            .iter()
            .map(|r| (r, false))
            .chain(self.done.iter().map(|r| (r, true)))
            .filter(|(r, _)| !r.is_epic())
        {
            if let (Some(p), Some(e)) = (r.project.as_deref(), r.parent.as_deref()) {
                let c = kids.entry((p.to_lowercase(), e.to_string())).or_default();
                if closed {
                    c.done += 1;
                } else {
                    c.open += 1;
                }
            }
        }
        for r in self.rows.iter_mut().chain(&mut self.done) {
            r.epic = match (r.project.as_deref(), r.parent.as_deref()) {
                (Some(p), Some(e)) => by.get(&(p.to_lowercase(), e.to_string())).cloned(),
                _ => None,
            };
            r.epic_open = match (r.project.as_deref(), r.parent.as_deref()) {
                (Some(p), Some(e)) => open_epics.contains(&(p.to_lowercase(), e.to_string())),
                _ => false,
            };
            r.children = match (r.is_epic(), r.project.as_deref(), r.id.as_deref()) {
                (true, Some(p), Some(id)) => Some(
                    kids.get(&(p.to_lowercase(), id.to_string()))
                        .copied()
                        .unwrap_or_default(),
                ),
                _ => None,
            };
        }
    }

    /// Put each active queue item's state on the rows its `row:` (`<project>:<id>`) names.
    pub fn queue_states(&mut self, items: &[crate::queue::Item]) {
        let mut by: std::collections::HashMap<(&str, &str), &'static str> =
            std::collections::HashMap::new();
        for i in items {
            let word = match i.state {
                crate::queue::State::Queued => "queued",
                crate::queue::State::Running => "running",
                crate::queue::State::Waiting => "waiting",
                crate::queue::State::Review => "review",
                crate::queue::State::Done => continue,
            };
            if let Some((p, id)) = i.row.as_deref().and_then(|r| r.split_once(':')) {
                by.insert((p, id), word);
            }
        }
        for r in &mut self.rows {
            if let (Some(p), Some(id)) = (r.project.as_deref(), r.id.as_deref()) {
                r.queue = by.get(&(p, id)).map(|w| (*w).to_string());
            }
        }
    }

    /// The release windows: every project's, or one project's from its (profile, project).
    pub fn sprints_in(&self, scope: Option<(&str, &str)>) -> Vec<&SprintLine> {
        self.sprints
            .iter()
            .filter(|s| scope.is_none_or(|(p, n)| s.profile == p && s.project == n))
            .collect()
    }

    /// The Sprints table at `now`: one [`SprintRow`] per window in scope, soonest cut first, a
    /// window with no cut or due day last.
    pub fn sprint_rows(
        &self,
        scope: Option<(&str, &str)>,
        now: chrono::NaiveDateTime,
    ) -> Vec<SprintRow> {
        let mut ws = self.sprints_in(scope);
        ws.sort_by_key(|s| (s.end().is_none(), s.end()));
        ws.into_iter()
            .map(|s| SprintRow {
                profile: s.profile.clone(),
                project: s.project.clone(),
                version: s.version.clone(),
                times: s.times(now),
                done: format!("{}/{}", s.done, s.committed),
                build: s.build.clone(),
                queued: s.queued,
            })
            .collect()
    }
}

/// A board line's (title, summary). A plan phase (`<plan-file> P2: <words>`, its plan file under
/// `home`) is titled by its words over its plan and phase ([`crate::plans::split_title`]), so a
/// row reads as the Queue tab's item does; any other line by [`crate::text::title`], the whole
/// line when that is empty, as is a phase whose words are all tags. The ids either one takes out
/// stay readable in the summary. The phase shape is read before [`crate::text::clean`], which
/// would take a plan named like an id (`ucp-145 P2: `) out as one.
fn row_title(home: &str, text: &str) -> (String, String) {
    let line = crate::text::unlabelled(text);
    let phase = crate::plans::split_title(home, line, None).filter(|(_, w)| !w.is_empty());
    if let Some((label, words)) = phase {
        let ids =
            crate::plans::legacy(line).map_or_else(Vec::new, |(.., w)| crate::text::clean(w).ids);
        let summary = match ids.is_empty() {
            true => label,
            false => format!("{label} ({})", ids.join(", ")),
        };
        return (words, summary);
    }
    let t = crate::text::title(text);
    let title = match t.title.is_empty() {
        true => text.trim().to_string(),
        false => t.title,
    };
    (title, t.summary)
}

pub fn feed(runner: &dyn Runner) -> Result<Feed, String> {
    let out = runner.run(&["notes".into(), "board".into(), "--json".into()])?;
    let mut f: Feed = serde_json::from_str(&out).map_err(|e| format!("notes board --json: {e}"))?;
    let (focus, rows): (Vec<Row>, Vec<Row>) = f.rows.drain(..).partition(|r| r.lane == "focus");
    f.rows = rows;
    for r in &mut f.rows {
        r.filed_today = r.filed.as_deref() == Some(f.today.as_str());
    }
    f.titles(&crate::plans::home());
    for r in focus {
        match f.focus.iter_mut().find(|c| c.profile == r.profile) {
            Some(c) => c.open += 1,
            None => f.focus.push(FocusOpen {
                profile: r.profile,
                open: 1,
            }),
        }
    }
    Ok(f)
}

/// What a write does to one row, or the row it adds.
#[derive(Clone, Debug, PartialEq)]
pub enum Verb {
    /// `to` aims it at a later release (`vX.Y.Z`); `game` is the playtest heading.
    Add {
        text: String,
        priority: String,
        to: Option<String>,
        game: Option<String>,
    },
    /// Exactly one of `proof` and `unverified`; `notes` refuses a bare done.
    Done {
        raw: String,
        proof: Option<String>,
        unverified: Option<String>,
    },
    /// Queues the row: `fleet-dispatch promote` starts it and adds its queue item, the same
    /// path a fill takes. An open row only, and not on the playtest lane.
    Start { raw: String },
    /// Closes the row undelivered and keeps it: exactly one of `why` and `dup` (the id of the
    /// row it duplicates); `notes` refuses a drop with no reason.
    Drop {
        raw: String,
        why: Option<String>,
        dup: Option<String>,
    },
    /// Onto another project's sheet (aimed at release `to` if given), or with no project aimed
    /// at release `to` on its own sheet. At least one of the two.
    Move {
        raw: String,
        project: Option<String>,
        to: Option<String>,
    },
    /// One release sooner (clamped at the open version).
    Promote { raw: String },
    /// One release later (the next patch past the last).
    Demote { raw: String },
    /// New text; the checkbox, place and tags stay.
    Edit { raw: String, text: String },
    /// Tags added and removed, at least one of either. A row has one size, so adding a
    /// `size/<s>` replaces its old one; a release tag is `Move`'s.
    Tag {
        raw: String,
        add: Vec<String>,
        remove: Vec<String>,
    },
}

/// A tag as a row carries it, without the `#`: one word that cannot read as a flag.
fn is_tag(t: &str) -> bool {
    let t = t.strip_prefix('#').unwrap_or(t);
    !t.is_empty()
        && !t.starts_with('-')
        && !is_version(t)
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '/' | ':' | '.'))
}

#[derive(Clone, Debug, PartialEq)]
pub struct Write {
    pub profile: String,
    pub project: String,
    pub lane: String,
    pub verb: Verb,
}

/// A profile or project name: what `notes` itself names them, so nothing else reaches argv.
fn is_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn one_line(s: &str) -> bool {
    !s.trim().is_empty() && !s.contains(['\n', '\r'])
}

pub(crate) fn is_version(s: &str) -> bool {
    let Some(v) = s.strip_prefix('v') else {
        return false;
    };
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// Something a row's own text would not say: a priority other than the default is the row's
/// `#urgent`, `#high` or `#low` tag, and normal is no tag at all, as `ptask add` reads it.
fn with_priority(text: &str, priority: &str) -> String {
    let text = text.trim();
    let tag = format!("#{priority}");
    if priority == DEFAULT_PRIORITY || text.split_whitespace().any(|w| w == tag) {
        text.to_string()
    } else {
        format!("{text} {tag}")
    }
}

fn is_row(s: &str) -> bool {
    one_line(s) && s.starts_with("- [")
}

/// The argv for one write, or why it is refused. Every free-text value goes after `--`, so a
/// row's `- [ ]` and a text starting with `-` stay values; Start's is the value of `--raw`.
pub fn argv(w: &Write) -> Result<Vec<String>, String> {
    if !is_name(&w.profile) || !is_name(&w.project) {
        return Err("pick a project".into());
    }
    if !LANES.contains(&w.lane.as_str()) {
        return Err("the lane is human, agent or playtest".into());
    }
    let playtest = w.lane == "playtest";
    let mut a: Vec<String> = ["notes", "ptask", &w.project, "--profile", &w.profile]
        .into_iter()
        .map(String::from)
        .collect();
    match w.lane.as_str() {
        "agent" => a.push("--agent".into()),
        "playtest" => a.push("--playtest".into()),
        _ => {}
    }
    let tail = match &w.verb {
        Verb::Add {
            text,
            priority,
            to,
            game,
        } => {
            if !one_line(text) {
                return Err("type the task, on one line".into());
            }
            if !PRIORITIES.contains(&priority.as_str()) {
                return Err("priority is urgent, high, normal or low".into());
            }
            a.push("add".into());
            if let Some(v) = to.as_deref().filter(|v| !v.is_empty()) {
                if playtest || !is_version(v) {
                    return Err("a version is vX.Y.Z, and a playtest check has none".into());
                }
                a.extend(["--to".into(), v.into()]);
            }
            if let Some(g) = game.as_deref().filter(|g| !g.is_empty()) {
                if !playtest || !one_line(g) {
                    return Err("a game heading is for a playtest check".into());
                }
                a.extend(["--game".into(), g.trim().into()]);
            }
            with_priority(text, priority)
        }
        Verb::Done {
            raw,
            proof,
            unverified,
        } => {
            let proof = proof.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let why = unverified
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            a.extend(["--exact".into(), "done".into()]);
            match (proof, why) {
                (Some(p), None) if one_line(p) => a.extend(["--proof".into(), p.into()]),
                (None, Some(u)) if one_line(u) => a.extend(["--unverified".into(), u.into()]),
                _ => return Err("done needs a proof (pr:N, a URL) or why it has none".into()),
            }
            raw.clone()
        }
        Verb::Start { raw } => {
            if playtest {
                return Err("a playtest check has no in-progress state".into());
            }
            if !is_row(raw) {
                return Err("that is not a row's line".into());
            }
            let mut a: Vec<String> = [
                "fleet-dispatch",
                "promote",
                "--project",
                &w.project,
                "--profile",
                &w.profile,
            ]
            .into_iter()
            .map(String::from)
            .collect();
            if w.lane == "agent" {
                a.push("--agent".into());
            }
            a.extend(["--raw".into(), raw.clone()]);
            return Ok(a);
        }
        Verb::Drop { raw, why, dup } => {
            let why = why.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let dup = dup.as_deref().map(str::trim).filter(|s| !s.is_empty());
            a.extend(["--exact".into(), "drop".into()]);
            match (why, dup) {
                (Some(y), None) if one_line(y) => a.extend(["--why".into(), y.into()]),
                (None, Some(d)) if one_line(d) => a.extend(["--dup".into(), d.into()]),
                _ => return Err("drop needs why, or the id of the row it duplicates".into()),
            }
            raw.clone()
        }
        Verb::Move { .. } | Verb::Promote { .. } | Verb::Demote { .. } | Verb::Edit { .. }
            if playtest =>
        {
            return Err(
                "a playtest check has no version and no edit: drop it and add it again".into(),
            );
        }
        Verb::Move { raw, project, to } => {
            let project = project.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let to = to.as_deref().map(str::trim).filter(|s| !s.is_empty());
            if project.is_none() && to.is_none() {
                return Err("move to a project, a version (vX.Y.Z), or both".into());
            }
            a.extend(["--exact".into(), "move".into()]);
            if let Some(p) = project {
                if !is_name(p) {
                    return Err("that is not a project name".into());
                }
                a.extend(["--project".into(), p.into()]);
            }
            if let Some(v) = to {
                if !is_version(v) {
                    return Err("a version is vX.Y.Z".into());
                }
                a.extend(["--to".into(), v.into()]);
            }
            raw.clone()
        }
        Verb::Tag { raw, add, remove } => {
            if add.is_empty() && remove.is_empty() {
                return Err("type a tag to add or remove".into());
            }
            if !add.iter().chain(remove).all(|t| is_tag(t)) {
                return Err("a tag is one word (size/s, requested); a release is move".into());
            }
            a.extend(["--exact".into(), "tag".into()]);
            let flag = |f: &str, t: &String| format!("--{f}={}", t.trim_start_matches('#'));
            a.extend(add.iter().map(|t| flag("add", t)));
            a.extend(remove.iter().map(|t| flag("remove", t)));
            raw.clone()
        }
        Verb::Promote { raw } => {
            a.extend(["--exact".into(), "promote".into()]);
            raw.clone()
        }
        Verb::Demote { raw } => {
            a.extend(["--exact".into(), "demote".into()]);
            raw.clone()
        }
        Verb::Edit { raw, text } => {
            if !one_line(text) {
                return Err("type the new text, on one line".into());
            }
            a.extend([
                "--exact".into(),
                "edit".into(),
                "--text".into(),
                text.trim().into(),
            ]);
            raw.clone()
        }
    };
    if !matches!(w.verb, Verb::Add { .. }) && !is_row(&tail) {
        return Err("that is not a row's line".into());
    }
    a.extend(["--".into(), tail]);
    Ok(a)
}

impl Write {
    /// The audit line this write records (`crate::audit`): `board.<verb in the past tense>`, the
    /// project and row as the target, and the verb's own fields as what was asked.
    pub fn audit_entry(&self, actor: &str, via: &str) -> crate::audit::Entry {
        use serde_json::{json, Value};
        let (verb, raw, to) = match &self.verb {
            Verb::Add {
                text,
                priority,
                to,
                game,
            } => (
                "add",
                "",
                json!({"text": text, "priority": priority, "to": to, "game": game}),
            ),
            Verb::Done {
                raw,
                proof,
                unverified,
            } => (
                "done",
                raw.as_str(),
                json!({"proof": proof, "unverified": unverified}),
            ),
            Verb::Start { raw } => ("start", raw.as_str(), Value::Null),
            Verb::Drop { raw, why, dup } => ("drop", raw.as_str(), json!({"why": why, "dup": dup})),
            Verb::Move { raw, project, to } => {
                ("move", raw.as_str(), json!({"project": project, "to": to}))
            }
            Verb::Promote { raw } => ("promote", raw.as_str(), Value::Null),
            Verb::Demote { raw } => ("demote", raw.as_str(), Value::Null),
            Verb::Edit { raw, text } => ("edit", raw.as_str(), json!({ "text": text })),
            Verb::Tag { raw, add, remove } => {
                ("tag", raw.as_str(), json!({"add": add, "remove": remove}))
            }
        };
        let target = format!("{} {raw}", self.project);
        crate::audit::Entry::new(
            actor,
            &format!("board.{}", crate::audit::past(verb)),
            target.trim(),
            via,
        )
        .to(to)
    }
}

/// Run one write: its output, or its stderr (a stale row says nothing matched).
pub fn apply(runner: &dyn Runner, w: &Write) -> Result<String, String> {
    runner.run(&argv(w)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn the_version_column_sorts_by_release_number_with_games_after() {
        assert!(release_order("v0.9.0") < release_order("v0.10.0"));
        assert!(release_order("v1.0.0") < release_order("demo"));
        assert_eq!(release_order("v1.x"), "v1.x");
    }

    struct Fake {
        out: Result<&'static str, &'static str>,
        calls: RefCell<Vec<Vec<String>>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.to_vec());
            self.out.map(String::from).map_err(String::from)
        }
    }

    fn w(lane: &str, verb: Verb) -> Write {
        Write {
            profile: "bnb".into(),
            project: "demo".into(),
            lane: lane.into(),
            verb,
        }
    }

    fn rows() -> Feed {
        let row = |project: &str, priority: &str, text: &str| Row {
            profile: "bnb".into(),
            project: Some(project.into()),
            lane: "agent".into(),
            state: "open".into(),
            priority: priority.into(),
            text: text.into(),
            raw: format!("- [ ] {text}"),
            ..Default::default()
        };
        let mut f = Feed {
            rows: vec![
                row("demo", "low", "tidy"),
                row("demo", "high", "wire the bar #size/m"),
                row("garden", "urgent", "water"),
                row("demo", "high", "ship"),
            ],
            ..Default::default()
        };
        f.rows[1].tags = vec!["ai".into(), "size/m".into()];
        f.rows[1].size = Some("m".into());
        f.rows[1].state = "doing".into();
        f.rows[2].size = Some("xl".into());
        f.rows[3].size = Some("s".into());
        f.rows[3].requested = true;
        f.rows[3].filed_today = true;
        for (r, (section, rank)) in
            f.rows
                .iter_mut()
                .zip([("backlog", 1), ("now", 9), ("next", 1), ("next", 5)])
        {
            r.section = Some(section.into());
            r.rank = rank;
        }
        f
    }

    fn texts<'a>(rows: &[&&'a Row]) -> Vec<&'a str> {
        rows.iter().map(|r| r.text.as_str()).collect()
    }

    #[test]
    fn a_row_shows_the_state_of_the_active_item_that_names_it() {
        let mut f = rows();
        f.rows[0].id = Some("de-1".into());
        f.rows[1].id = Some("de-2".into());
        f.rows[2].id = Some("de-1".into());
        let item = |row: &str, state| crate::queue::Item {
            row: Some(row.into()),
            state,
            ..Default::default()
        };
        f.queue_states(&[
            item("demo:de-1", crate::queue::State::Running),
            item("demo:de-2", crate::queue::State::Done),
        ]);
        let got: Vec<Option<&str>> = f.rows.iter().map(|r| r.queue.as_deref()).collect();
        // A done item says nothing, and the same id in another project is another row.
        assert_eq!(got, [Some("running"), None, None, None]);
    }

    fn sprint(cut: Option<&str>, remaining: u32, rate: f64) -> SprintLine {
        SprintLine {
            profile: "bnb".into(),
            project: "demo".into(),
            opened: "2026-11-19".into(),
            due: Some("2026-11-19".into()),
            cut: cut.map(str::to_string),
            committed: remaining as usize,
            remaining_weight: remaining,
            rate_per_hour: rate,
            ..Default::default()
        }
    }

    fn at(s: &str) -> chrono::NaiveDateTime {
        chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M").unwrap()
    }

    /// A queued sprint starts at the open one's cut, reads `queued` until a roll opens it, and
    /// projects its finish from its start.
    #[test]
    fn a_queued_sprint_reads_its_start_and_queued() {
        let now = at("2026-11-19T15:10");
        let mut s = sprint(Some("2026-11-20T21:59"), 2, 4.0);
        s.locked = Some("2026-11-19T15:00".into());
        s.start = Some("2026-11-19T21:59".into());
        s.queued = true;
        let t = s.times(now);
        assert_eq!(
            (t.started.as_str(), t.left.as_str(), t.finish.as_str()),
            ("11-19 21:59", "queued", "~22:29")
        );
        // NEGATIVE CONTROL: once it opens it counts down from now like any sprint.
        s.queued = false;
        let t = s.times(now);
        assert_eq!(
            (t.started.as_str(), t.left.as_str(), t.finish.as_str()),
            ("11-19 21:59", "30h 49m", "~15:40")
        );
    }

    #[test]
    fn a_sprint_reads_its_time_left_and_projected_finish() {
        let now = at("2026-11-19T15:10");
        // 2 weight at 4 per hour is 30 minutes: on time for a 15:59 cut.
        let mut s = sprint(Some("2026-11-19T15:59"), 2, 4.0);
        s.locked = Some("2026-11-19T14:25".into());
        let t = s.times(now);
        assert_eq!(
            (
                t.started.as_str(),
                t.cut.as_str(),
                t.left.as_str(),
                t.finish.as_str(),
                t.late
            ),
            ("11-19 14:25", "11-19 15:59", "49m", "~15:40", false)
        );
        // 20 weight at 1 per hour lands tomorrow, after a cut that has passed.
        let t = sprint(Some("2026-11-19T14:00"), 20, 1.0).times(now);
        assert_eq!(
            (
                t.started.as_str(),
                t.left.as_str(),
                t.finish.as_str(),
                t.late
            ),
            ("11-19", "over", "~11-20 11:10", true)
        );
        // With no cut the due day's end is the sprint's end.
        let t = sprint(None, 1, 1.0).times(now);
        assert_eq!((t.cut.as_str(), t.left.as_str()), ("11-19", "8h 50m"));
        // NEGATIVE CONTROL: no shipping history is no estimate, never a guess; nothing open is done.
        let t = sprint(Some("2026-11-19T15:59"), 3, 0.0).times(now);
        assert_eq!(
            (t.finish.as_str(), t.late),
            (crate::reading::NO_DATA, false)
        );
        assert_eq!(sprint(None, 0, 0.0).times(now).finish, "done");
        // A feed from a notes that predates the weights: rows open, no weight, no opened day.
        let old = SprintLine {
            done: 0,
            committed: 5,
            cut: Some("2026-11-19T17:00".into()),
            ..Default::default()
        };
        let t = old.times(now);
        assert_eq!(
            (t.started.as_str(), t.finish.as_str()),
            ("-", crate::reading::NO_DATA),
            "unknown, never done"
        );
        // The last seconds before the cut are under a minute, not over.
        let s = sprint(Some("2026-11-19T15:59"), 1, 1.0);
        let t = s.times(at("2026-11-19T15:58") + chrono::Duration::seconds(30));
        assert_eq!(t.left, "<1m");
        assert_eq!(s.times(at("2026-11-19T15:59")).left, "over");
    }

    #[test]
    fn open_rows_follow_the_sheet_sections_then_rank_and_leave_out_done() {
        let mut f = rows();
        let all: Vec<&str> = f.open_rows(None).iter().map(|r| r.text.as_str()).collect();
        // Now before Next up before Backlog, then the feed's rank; the old priority sort put the
        // urgent "water" first.
        assert_eq!(all, ["wire the bar #size/m", "water", "ship", "tidy"]);
        assert_eq!(f.open_rows(Some(("bnb", "garden"))).len(), 1);
        assert!(f.open_rows(Some(("personal", "garden"))).is_empty());
        // On the agent board a backlog-tier row is in Backlog, after Board, whatever its rank.
        for (text, section) in [("water", "backlog"), ("tidy", "board")] {
            let r = f.rows.iter_mut().find(|r| r.text == text).unwrap();
            r.section = Some(section.into());
            r.rank = 0;
        }
        let all: Vec<&str> = f.open_rows(None).iter().map(|r| r.text.as_str()).collect();
        assert_eq!(all, ["wire the bar #size/m", "ship", "tidy", "water"]);
        let labels = section_labels(&f.open_rows(None), false);
        assert_eq!(
            labels,
            ["NOW (1)", "NEXT UP (1)", "BOARD (1)", "BACKLOG (1)"]
        );
        // The tiers line: the whole feed's from totals, a project's from its entry, else none.
        assert_eq!(f.agent_tiers(None), None, "no totals, no line");
        f.totals = Some(Totals {
            agent: 3,
            epic_open: 4,
            epic_backlog: 6,
            backlog: 1,
            sprint: Sprint {
                open: 2,
                committed: 5,
            },
            ..Default::default()
        });
        f.projects = vec![Project {
            profile: "bnb".into(),
            project: "demo".into(),
            agent_open: 2,
            agent_backlog: 1,
            epic_open: 1,
            epic_backlog: 2,
            ..Default::default()
        }];
        assert_eq!(
            f.agent_tiers(None).as_deref(),
            Some("Sprint 2/5 | Today 3 | Backlog 1 | Epics 4 | Epic backlog 6")
        );
        assert_eq!(
            f.agent_tiers(Some(("bnb", "demo"))).as_deref(),
            Some("Today 2 | Backlog 1 | Epics 1 | Epic backlog 2"),
            "a project with no window has no Sprint"
        );
        assert_eq!(f.agent_tiers(Some(("bnb", "garden"))), None);
        f.rows[0].state = "done".into();
        assert_eq!(f.open_rows(None).len(), 3);
    }

    #[test]
    fn the_rows_table_filters_on_any_tag_and_each_chip() {
        use crate::table::View;
        let f = rows();
        let open = f.open_rows(None);
        let shown = |q: &str, s: &str| View::new::<Row>(q, s, "", "").apply(&open).len();
        assert_eq!(shown("tag:size/", ""), 1, "any tag, not only the first");
        assert_eq!(shown("-tag:ai", ""), 3);
        assert_eq!(shown("size:m project:demo", ""), 1);
        assert_eq!(shown("#size/m", ""), 1, "a bare word reads the raw line");
        assert_eq!(shown("bnb/garden", ""), 1, "and where the row lives");
        assert_eq!(shown("", "in progress"), 1);
        assert_eq!(shown("", "filed today"), 1);
        assert_eq!(shown("", "urgent"), 1);
        assert_eq!(shown("", "requested"), 1);
        // A closed row is Done's: the ask chips count open work only.
        let closed: Vec<Row> = open
            .iter()
            .map(|r| Row {
                state: "done".into(),
                ..(*r).clone()
            })
            .collect();
        let closed: Vec<&Row> = closed.iter().collect();
        let on = |s: &str| View::new::<Row>("", s, "", "").apply(&closed).len();
        assert_eq!((on("urgent"), on("requested")), (0, 0));
        // The Done chip is the reverse: closed rows only.
        assert_eq!((shown("", "done"), on("done")), (0, 4));
    }

    #[test]
    fn closed_rows_run_by_the_day_they_closed_then_by_project() {
        let done = |project: &str, closed: Option<&str>| Row {
            state: "done".into(),
            section: Some("done".into()),
            project: Some(project.into()),
            closed: closed.map(Into::into),
            text: project.into(),
            ..Default::default()
        };
        let f = Feed {
            rows: rows().rows,
            done: vec![
                done("old", None),
                done("garden", Some("2026-11-05")),
                done("demo", Some("2026-11-07")),
                done("arena", Some("2026-11-07")),
            ],
            ..Default::default()
        };
        let all = f.board_rows(None);
        let closed = &all[all.len() - 4..];
        let names: Vec<&str> = closed.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(names, ["arena", "demo", "garden", "old"]);
        assert_eq!(
            section_labels(closed, false),
            ["DONE 11-07 (2)", "", "DONE 11-05 (1)", "DONE no day (1)"]
        );
        // Under another sort each row names its own section and day, with no count.
        assert_eq!(
            section_labels(&[closed[0], closed[3]], true),
            ["DONE 11-07", "DONE no day"]
        );
    }

    #[test]
    fn priority_and_size_sort_by_rank_not_by_spelling() {
        use crate::table::View;
        let f = rows();
        let open = f.open_rows(None);
        let by = |col: &str, dir: &str| View::new::<Row>("", "", col, dir).apply(&open);
        assert_eq!(texts(&by("priority", "desc"))[0], "water");
        assert_eq!(texts(&by("priority", "asc"))[0], "tidy");
        assert_eq!(
            texts(&by("size", "desc")),
            ["water", "wire the bar #size/m", "ship", "tidy"],
            "xl over m over s, a row with no size last"
        );
    }

    #[test]
    fn a_playtest_rows_version_column_is_its_game() {
        use crate::table::{Row as _, Val};
        let r = Row {
            lane: "playtest".into(),
            game: Some("demo".into()),
            version: Some("v0.1.0".into()),
            ..Default::default()
        };
        assert_eq!(r.val("version"), Val::Text("demo".into()));
    }

    #[test]
    fn the_feed_marks_what_was_filed_today() {
        let fake = Fake {
            out: Ok(r#"{"today":"2026-11-06","rows":[
                {"lane":"agent","filed":"2026-11-06"},{"lane":"agent","filed":"2026-11-05"}]}"#),
            calls: RefCell::default(),
        };
        let f = feed(&fake).unwrap();
        assert!(f.rows[0].filed_today && !f.rows[1].filed_today);
    }

    #[test]
    fn a_title_is_the_few_words_before_the_first_clause() {
        // notes sets `type` on exactly these `type(area): ` rows.
        let title = |t: &str| {
            let t = crate::text::title(t);
            (t.title, t.summary)
        };
        // The board rows as they stand on unity-core-playground (2026-11-12).
        for (text, want) in [
            (
                "epic(gameplay): Apociseum coliseum mode: rounds with a red end #new",
                "Apociseum coliseum mode",
            ),
            (
                "epic(ci): Golden CI for tests: one owner, one checklist",
                "Golden CI for tests",
            ),
            ("epic(gameplay): Space Raiders (v0.3.2)", "Space Raiders"),
            (
                "epic(save): Home: the player room, plus saves for every game",
                "Home: the player room",
            ),
            (
                "BrainMush: press X: the squad holds, and X frees it",
                "BrainMush: press X",
            ),
            (
                "feat(net): bot mode for testing networking, bots plus a real client",
                "bot mode for testing networking",
            ),
            ("epic(ui): ui to standard", "ui to standard"),
            (
                "perf(perf): run scenes with 1000s of objects on pools and one tick for all",
                "run scenes with 1000s of objects on pools...",
            ),
            // No prefix: a sentence keeps its own head, a colon in prose is not a prefix.
            (
                "Ship the trailer for DodginBalls",
                "Ship the trailer for DodginBalls",
            ),
            ("the two sheets: merge them", "the two sheets"),
            (
                "bump the slot #urgent past #1980",
                "bump the slot past #1980",
            ),
            // A playtest check's head is its own word, not a type.
            (
                "headset: menu text readable at 1.5 m, quests list Active",
                "headset: menu text readable at 1.5 m",
            ),
            ("", ""),
        ] {
            assert_eq!(title(text).0, want, "{text}");
        }
        // The summary is what the title leaves out, never the title again.
        for (text, rest) in [
            (
                "epic(ci): Golden CI for tests: one owner, one checklist",
                "one owner, one checklist",
            ),
            ("epic(gameplay): Space Raiders (v0.3.2)", "v0.3.2"),
            (
                "feat(net): bot mode for testing networking, bots plus a client #low",
                "bots plus a client",
            ),
            ("epic(ui): ui to standard", ""),
            (
                "feat(ui): end-of-run victory/defeat panel (UITK) now that round text is debug-only",
                "(UITK) now that round text is debug-only",
            ),
            (
                "perf(perf): run scenes with 1000s of objects on pools and one tick for all",
                "...and one tick for all",
            ),
        ] {
            assert_eq!(title(text).1, rest, "{text}");
        }
    }

    #[test]
    fn a_plan_phase_row_is_titled_by_its_words_and_no_board_text_carries_its_brief() {
        let home = std::env::temp_dir().join(format!("tasks-plan-{}", std::process::id()));
        let plans = home.join(".claude/plans");
        std::fs::create_dir_all(&plans).unwrap();
        std::fs::write(
            plans.join("can-we-add-more-jaunty-moonbeam.md"),
            "# Structured UI text by default, on every surface\n",
        )
        .unwrap();
        std::fs::write(plans.join("ucp-145.md"), "# Look pass\n").unwrap();
        // The row `agent-queue add --plan` filed for ar-4379 and its brief, as notes sends them.
        let phase = "feat(agent-runtime): can-we-add-more-jaunty-moonbeam P2: Board titles vs agent briefs, and sprint #of/ar-4377";
        let brief = "Phase 2 of the plan /x/can-we-add-more-jaunty-moonbeam.md: Board titles vs agent briefs, and sprint rows. Read the plan whole, then do ONLY this phase, to merged. When it lands, tick its box in the plan's Phases checklist with the PR number and add a Results line.";
        let row = |id: &str, text: &str| serde_json::json!({"project": "agent-runtime", "lane": "agent", "id": id, "text": text, "details": [brief]});
        let mut f: Feed = serde_json::from_value(serde_json::json!({
            "today": "2026-11-21",
            "rows": [
                row("ar-4379", phase),
                row("ar-4380", "feat(hub): can-we-add-more-jaunty-moonbeam P4+5: Briefing, then STATUS (ar-3865)"),
                row("ar-4381", "feat(hub): no-such-plan-file P3: Words, then more"),
                row("ar-4382", "feat(look): ucp-145 P2: Menus, then maps"),
                row("ar-4383", "feat(hub): can-we-add-more-jaunty-moonbeam P3: #size/s"),
            ]
        }))
        .unwrap();
        f.titles(home.to_str().unwrap());
        fn got(r: &Row) -> (&str, &str) {
            (&r.title, &r.summary)
        }
        assert_eq!(
            got(&f.rows[0]),
            (
                "Board titles vs agent briefs, and sprint",
                "Structured UI text by default P2"
            ),
            "the phase's words are the title, its plan and phase the second line"
        );
        assert_eq!(
            got(&f.rows[1]),
            (
                "Briefing, then STATUS",
                "Structured UI text by default P4+5 (ar-3865)"
            ),
            "a joined phase keeps both numbers and the ids the words named"
        );
        // NEGATIVE CONTROL: a slug with no plan file is not read as a plan.
        assert_eq!(
            got(&f.rows[2]),
            ("no-such-plan-file P3", "Words, then more")
        );
        assert_eq!(
            got(&f.rows[3]),
            ("Menus, then maps", "Look pass P2"),
            "a plan named like an id is still a plan, not an id the cleaner drops"
        );
        assert_eq!(
            got(&f.rows[4]).0,
            "can-we-add-more-jaunty-moonbeam P3",
            "a phase with no words is never a blank title"
        );
        let sent = serde_json::to_string(&f).unwrap();
        for said in [
            "of the plan",
            "Read the plan",
            "do ONLY",
            "tick its box",
            "Results line",
        ] {
            assert!(
                !sent.contains(said),
                "the brief stays off the board: {said}"
            );
        }
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn a_row_under_an_epic_carries_its_title_and_links_it() {
        let fake = Fake {
            out: Ok(r#"{"today":"2026-11-12","rows":[
                {"project":"ucp","lane":"human","id":"ucp-1","type":"epic","section":"epics","text":"epic(net): netcode to standard"},
                {"project":"ucp","lane":"human","id":"ucp-2","type":"feat","text":"feat(net): bot mode, bots plus a client","parent":"ucp-1"},
                {"project":"other","lane":"human","id":"ucp-3","text":"x","parent":"ucp-1"},
                {"project":"ucp","lane":"human","id":"ucp-4","text":"y","parent":"ucp-99"},
                {"project":"ucp","lane":"human","id":"ucp-5","text":"z","parent":"ucp-7"}],
                "done":[
                {"project":"ucp","lane":"human","id":"ucp-7","type":"epic","section":"done","state":"done","text":"epic(old): shipped"}]}"#),
            calls: RefCell::default(),
        };
        let f = feed(&fake).unwrap();
        assert_eq!(f.rows[1].title, "bot mode");
        assert_eq!(f.rows[1].epic.as_deref(), Some("netcode to standard"));
        assert_eq!(f.rows[0].epic, None, "an epic is under nothing");
        assert_eq!(f.rows[2].epic, None, "an id is the project's own");
        assert_eq!(
            f.rows[3].epic, None,
            "a parent not on the board names nothing"
        );
        use crate::table::Row as _;
        assert_eq!(
            f.rows[1].val("epic"),
            Val::Text("netcode to standard".into())
        );
        assert_eq!(
            f.rows[1].link("epic").map(|l| l.href()),
            Some("#projects/all?q=id:=ucp-1&s=epics".to_string()),
            "an epic is listed on the epics chip only, so the link opens that chip"
        );
        assert!(f.rows[0].link("epic").is_none());
        assert_eq!(
            f.rows[4].link("epic").map(|l| l.href()),
            Some("#projects/all?q=id:=ucp-7".to_string()),
            "a closed epic lists on the default chip with the done rows, so its link opens that"
        );
    }

    #[test]
    fn an_epic_counts_its_open_and_closed_rows_and_lists_only_on_its_chip() {
        use crate::table::{Row as _, View};
        let fake = Fake {
            out: Ok(r#"{"today":"2026-11-12","rows":[
                {"project":"ucp","lane":"human","id":"ucp-1","type":"epic","section":"epics","text":"epic(net): netcode","priority":"high"},
                {"project":"ucp","lane":"human","id":"ucp-5","type":"epic","section":"epics","text":"epic(ui): empty one"},
                {"project":"ucp","lane":"agent","id":"ucp-2","section":"now","state":"doing","text":"feat(net): one","parent":"ucp-1"},
                {"project":"ucp","lane":"agent","id":"ucp-3","section":"next","text":"feat(net): two","parent":"ucp-1"},
                {"project":"other","lane":"agent","id":"ucp-1","section":"next","text":"x","parent":"ucp-1"},
                {"project":"ucp","lane":"agent","id":"ucp-4","section":"next","text":"fix(ui): loose"},
                {"project":"ucp","lane":"human","id":"ucp-7","type":"epic","section":"epics","text":"epic(net): sub","parent":"ucp-1"}],
                "done":[
                {"project":"ucp","lane":"agent","id":"ucp-6","section":"done","state":"done","text":"feat(net): shipped","parent":"ucp-1"}]}"#),
            calls: RefCell::default(),
        };
        let f = feed(&fake).unwrap();
        let kids = |i: usize| f.rows[i].children;
        assert_eq!(
            kids(0),
            Some(Children { open: 2, done: 1 }),
            "a sub-epic lists on the epics chip, so it is not one of the rows"
        );
        assert_eq!(f.rows[0].val("rows"), Val::Text("2 open / 1 done".into()));
        assert_eq!(
            kids(1),
            Some(Children { open: 0, done: 0 }),
            "an epic with no rows reads 0 / 0, not a blank"
        );
        assert_eq!(kids(2), None, "a task has no count");
        assert_eq!(
            f.rows[0].link("rows").map(|l| l.href()),
            Some("#projects/all?q=tag:=of/ucp-1".to_string())
        );
        assert!(f.rows[2].link("rows").is_none());
        let rows = f.board_rows(None);
        let on = |s: &str| -> Vec<String> {
            View::new::<Row>("", s, "", "")
                .apply(&rows)
                .iter()
                .filter_map(|r| r.id.clone())
                .collect()
        };
        // NEGATIVE CONTROL: the default chip held both epics before this chip.
        assert_eq!(on(""), ["ucp-2", "ucp-3", "ucp-1", "ucp-4", "ucp-6"]);
        assert_eq!(on("epics"), ["ucp-1", "ucp-5", "ucp-7"]);
        assert_eq!(on("in progress"), ["ucp-2"]);
    }

    fn add(text: &str, priority: &str, to: Option<&str>, game: Option<&str>) -> Verb {
        Verb::Add {
            text: text.into(),
            priority: priority.into(),
            to: to.map(String::from),
            game: game.map(String::from),
        }
    }

    const RAW: &str = "- [ ] ship it #urgent <!-- pr:3 -->";

    fn drop(why: Option<&str>, dup: Option<&str>) -> Verb {
        Verb::Drop {
            raw: RAW.into(),
            why: why.map(Into::into),
            dup: dup.map(Into::into),
        }
    }

    #[test]
    fn the_feed_parses_and_focus_rows_become_a_count() {
        let f = Fake {
            out: Ok(
                r#"{"today":"2026-11-04","projects":[{"profile":"bnb","project":"demo","dir":"/d","version":"v1.0.0","open":1,"agent_open":0,"playtest_open":0,"inbox":2}],
                "rows":[{"profile":"personal","project":null,"lane":"focus","state":"open","priority":"high","text":"x","tags":[],"sheet":"/n","line":4,"raw":"- [ ] x","later":"kept out"},
                {"profile":"personal","project":null,"lane":"focus","state":"doing","priority":"low","text":"z","sheet":"/n","line":5,"raw":"- [/] z"},
                {"profile":"bnb","project":"demo","lane":"human","state":"open","priority":"low","id":"de-3","text":"y","filed":"2026-11-04","sheet":"/s","line":9,"raw":"- [ ] y"}]}"#,
            ),
            calls: RefCell::default(),
        };
        let feed = feed(&f).unwrap();
        assert_eq!(feed.projects[0].version.as_deref(), Some("v1.0.0"));
        assert_eq!(
            feed.focus,
            [FocusOpen {
                profile: "personal".into(),
                open: 2
            }]
        );
        assert_eq!(feed.rows.len(), 1, "no focus row is left among the rows");
        // what the Filed today card reads
        assert_eq!(feed.today, "2026-11-04");
        assert_eq!(feed.projects[0].inbox, 2);
        assert_eq!(feed.rows[0].id.as_deref(), Some("de-3"));
        assert_eq!(feed.rows[0].filed.as_deref(), Some("2026-11-04"));
        assert_eq!(f.calls.borrow()[0], ["notes", "board", "--json"]);
        let bad = Fake {
            out: Ok("not json"),
            calls: RefCell::default(),
        };
        assert!(feed_err(&bad).contains("notes board --json"));
    }

    fn feed_err(f: &Fake) -> String {
        feed(f).unwrap_err()
    }

    #[test]
    fn writes_name_the_lane_and_pass_the_row_after_the_separator() {
        assert_eq!(
            argv(&w(
                "human",
                add("fix the menu", "urgent", Some("v1.2.0"), None)
            ))
            .unwrap(),
            [
                "notes",
                "ptask",
                "demo",
                "--profile",
                "bnb",
                "add",
                "--to",
                "v1.2.0",
                "--",
                "fix the menu #urgent"
            ]
        );
        assert_eq!(
            argv(&w("agent", add("-lead dash", "normal", None, None))).unwrap()[5..],
            ["--agent", "add", "--", "-lead dash"],
            "normal is no tag"
        );
        assert_eq!(
            argv(&w("agent", add("ship it", "high", None, None))).unwrap()[5..],
            ["--agent", "add", "--", "ship it #high"],
            "high is a tag now that an untagged row is normal"
        );
        assert_eq!(
            argv(&w(
                "playtest",
                add("ball clips", "low", None, Some("Arena"))
            ))
            .unwrap()[5..],
            [
                "--playtest",
                "add",
                "--game",
                "Arena",
                "--",
                "ball clips #low"
            ]
        );
        let done = Verb::Done {
            raw: RAW.into(),
            proof: Some("pr:12".into()),
            unverified: None,
        };
        assert_eq!(
            argv(&w("agent", done)).unwrap()[5..],
            ["--agent", "--exact", "done", "--proof", "pr:12", "--", RAW]
        );
        let done = Verb::Done {
            raw: RAW.into(),
            proof: Some(" ".into()),
            unverified: Some("played it".into()),
        };
        assert_eq!(
            argv(&w("human", done)).unwrap()[5..],
            ["--exact", "done", "--unverified", "played it", "--", RAW]
        );
        assert_eq!(
            argv(&w("human", drop(Some("stale"), None))).unwrap()[5..],
            ["--exact", "drop", "--why", "stale", "--", RAW]
        );
        assert_eq!(
            argv(&w("human", drop(Some(" "), Some("ar-142")))).unwrap()[5..],
            ["--exact", "drop", "--dup", "ar-142", "--", RAW]
        );
    }

    // Start is the queue's door, not a checkbox: a row started here gets an item, as a fill's does.
    #[test]
    fn start_goes_through_fleet_dispatch_promote() {
        assert_eq!(
            argv(&w("agent", Verb::Start { raw: RAW.into() })).unwrap(),
            [
                "fleet-dispatch",
                "promote",
                "--project",
                "demo",
                "--profile",
                "bnb",
                "--agent",
                "--raw",
                RAW
            ]
        );
        assert!(!argv(&w("human", Verb::Start { raw: RAW.into() }))
            .unwrap()
            .contains(&"--agent".to_string()));
    }

    #[test]
    fn move_version_and_edit_pass_the_row_after_the_separator() {
        let mv = |project: Option<&str>, to: Option<&str>| Verb::Move {
            raw: RAW.into(),
            project: project.map(String::from),
            to: to.map(String::from),
        };
        assert_eq!(
            argv(&w("human", mv(Some("other"), None))).unwrap()[5..],
            ["--exact", "move", "--project", "other", "--", RAW]
        );
        assert_eq!(
            argv(&w("agent", mv(Some("other"), Some("v2.0.0")))).unwrap()[5..],
            [
                "--agent",
                "--exact",
                "move",
                "--project",
                "other",
                "--to",
                "v2.0.0",
                "--",
                RAW
            ]
        );
        assert_eq!(
            argv(&w("human", mv(Some(" "), Some("v1.3.0")))).unwrap()[5..],
            ["--exact", "move", "--to", "v1.3.0", "--", RAW],
            "a blank project is no project"
        );
        assert_eq!(
            argv(&w("human", Verb::Promote { raw: RAW.into() })).unwrap()[5..],
            ["--exact", "promote", "--", RAW]
        );
        assert_eq!(
            argv(&w("agent", Verb::Demote { raw: RAW.into() })).unwrap()[5..],
            ["--agent", "--exact", "demote", "--", RAW]
        );
        let edit = Verb::Edit {
            raw: RAW.into(),
            text: " -ship it today ".into(),
        };
        assert_eq!(
            argv(&w("human", edit)).unwrap()[5..],
            ["--exact", "edit", "--text", "-ship it today", "--", RAW]
        );
    }

    #[test]
    fn tag_passes_each_tag_as_a_glued_flag_and_refuses_what_is_not_one() {
        let tag = |add: &[&str], remove: &[&str]| Verb::Tag {
            raw: RAW.into(),
            add: add.iter().map(|t| t.to_string()).collect(),
            remove: remove.iter().map(|t| t.to_string()).collect(),
        };
        assert_eq!(
            argv(&w("agent", tag(&["#size/m", "requested"], &["ai"]))).unwrap()[5..],
            [
                "--agent",
                "--exact",
                "tag",
                "--add=size/m",
                "--add=requested",
                "--remove=ai",
                "--",
                RAW
            ]
        );
        for bad in [
            tag(&[], &[]),
            tag(&["two words"], &[]),
            tag(&["-x"], &[]),
            tag(&["v1.2.0"], &[]),
            tag(&[""], &[]),
        ] {
            assert!(argv(&w("human", bad)).is_err());
        }
    }

    #[test]
    fn writes_refuse_what_notes_would_misread() {
        let gone = |raw: &str| Verb::Drop {
            raw: raw.into(),
            why: Some("stale".into()),
            dup: None,
        };
        let bad = [
            w("human", drop(None, None)),
            w("human", drop(Some("x"), Some("ar-1"))),
            w("human", drop(Some("two\nlines"), None)),
            w("focus", gone(RAW)),
            w("human", gone("not a row")),
            w("human", gone("- [ ] two\n- [ ] lines")),
            w("playtest", Verb::Start { raw: RAW.into() }),
            w(
                "human",
                Verb::Start {
                    raw: "not a row".into(),
                },
            ),
            w("human", add("x", "medium", None, None)),
            w("human", add("  ", "high", None, None)),
            w("human", add("x", "high", Some("next"), None)),
            w("playtest", add("x", "high", Some("v1.0.0"), None)),
            w("human", add("x", "high", None, Some("Arena"))),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: None,
                    to: Some(" ".into()),
                },
            ),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: Some("a b".into()),
                    to: None,
                },
            ),
            w(
                "human",
                Verb::Move {
                    raw: RAW.into(),
                    project: None,
                    to: Some("next".into()),
                },
            ),
            w(
                "playtest",
                Verb::Move {
                    raw: RAW.into(),
                    project: Some("other".into()),
                    to: None,
                },
            ),
            w("playtest", Verb::Promote { raw: RAW.into() }),
            w(
                "human",
                Verb::Edit {
                    raw: RAW.into(),
                    text: "two\nlines".into(),
                },
            ),
            w(
                "human",
                Verb::Edit {
                    raw: "not a row".into(),
                    text: "x".into(),
                },
            ),
            w(
                "human",
                Verb::Done {
                    raw: RAW.into(),
                    proof: None,
                    unverified: None,
                },
            ),
            w(
                "human",
                Verb::Done {
                    raw: RAW.into(),
                    proof: Some("pr:1".into()),
                    unverified: Some("both".into()),
                },
            ),
            Write {
                project: "--all".into(),
                ..w("human", gone(RAW))
            },
            Write {
                profile: "a b".into(),
                ..w("human", gone(RAW))
            },
        ];
        for b in bad {
            assert!(argv(&b).is_err(), "{b:?}");
        }
    }

    #[test]
    fn a_stale_row_comes_back_as_the_error_and_nothing_else_runs() {
        let f = Fake {
            out: Err("no open task matches"),
            calls: RefCell::default(),
        };
        let e = apply(&f, &w("human", drop(Some("stale"), None))).unwrap_err();
        assert_eq!(e, "no open task matches");
        assert_eq!(f.calls.borrow().len(), 1);
        let none = Fake {
            out: Ok(""),
            calls: RefCell::default(),
        };
        assert!(apply(&none, &w("focus", drop(Some("stale"), None))).is_err());
        assert!(
            none.calls.borrow().is_empty(),
            "a refused write runs nothing"
        );
    }
}
