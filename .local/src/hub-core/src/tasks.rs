//! The task board: every project's rows, open and closed, as `notes board --json` prints them,
//! for agent-web's Board tab and the hub TUI's. `notes` is the sheets' only writer, so this
//! module never opens a sheet: it reads the feed through a `Runner` and writes with
//! `notes ptask ... --exact`, which matches the row's raw line byte for byte and writes nothing
//! when the row changed since the read (design: notes-cli README, "The task feed").

use serde::{Deserialize, Serialize};

use crate::queue::PRIORITIES;
use crate::session_actions::Runner;
use crate::table::Val;

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
    pub agent_open: usize,
    pub playtest_open: usize,
    /// Lines waiting in the sheet's `## Inbox` for the triager.
    pub inbox: usize,
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
    pub state: String,
    pub priority: String,
    pub tier: Option<u8>,
    pub worker: Option<String>,
    /// The row's `#size/<s|m|l>`, without the prefix.
    pub size: Option<String>,
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
    /// The `#size/` weight, 1 unsized.
    pub weight: u32,
    /// The day a closed row closed.
    pub closed: Option<String>,
    /// The PRs its marker names.
    pub prs: Vec<String>,
    /// `YYYY-MM-DD` the row should close at the project's 28-day close rate, after every row
    /// ranked ahead of it (`projects::forecast`). Never in the sheet.
    pub forecast: Option<String>,
    /// The state of the queue item whose `row:` names it (`queued`, `running`, `waiting`,
    /// `review`), set by `queue_states`.
    pub queue: Option<String>,
}

/// The sections in sheet order, then a row in none (a playtest check).
pub const SECTIONS: [&str; 5] = ["epics", "now", "next", "backlog", "done"];

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
        Some("backlog") => "BACKLOG",
        Some("done") => "DONE",
        _ => "PLAYTEST",
    }
}

/// Each row's section cell on a board: `NEXT UP (10)` over the first row of a section and blank
/// under it, the way the sheet reads, while the rows are in the sheet's order; under any other
/// sort each row names its own. The hub and agent-web both draw these.
pub fn section_labels(rows: &[&Row], sorted: bool) -> Vec<String> {
    fn of(r: &Row) -> Option<&str> {
        r.section.as_deref()
    }
    rows.iter()
        .enumerate()
        .map(|(i, r)| {
            let title = section_title(r.section.as_deref());
            if sorted {
                return title.to_string();
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
        "section", "priority", "project", "lane", "state", "id", "version", "size", "tier",
        "since", "when", "text", "profile", "tag",
    ];
    const STATES: &'static [&'static str] =
        &["all", "in progress", "filed today", "urgent", "requested"];
    const FACETS: &'static [&'static str] = &["section", "project", "lane", "priority", "state"];
    const LEAD: &'static str = "text";
    const GLANCE: &'static [&'static str] = &["priority", "project", "state"];

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
            "tier" => self.tier.map_or(Val::None, |t| Val::Num(f64::from(t))),
            "since" => some(self.since.as_deref()),
            "when" => match self.when() {
                w if w.is_empty() => Val::None,
                w => Val::Text(w),
            },
            "text" => text(&self.text),
            "profile" => text(&self.profile),
            "tag" if self.tags.is_empty() => Val::None,
            "tag" => Val::Text(self.tags.join(" ")),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "in progress" => self.doing(),
            "filed today" => self.filed_today,
            // Asks of work still open: a closed row is Done's, not the chip's.
            "urgent" => self.state != "done" && self.priority == "urgent",
            "requested" => self.state != "done" && self.requested,
            _ => false,
        }
    }

    /// A bare word searches where the row lives and its whole line, so `#tag` still finds it.
    fn text(&self) -> String {
        let project = self.project.as_deref().unwrap_or_default();
        format!("{}/{project}\n{}", self.profile, self.raw).to_lowercase()
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
            "priority" => at(&["low", "high", "urgent"], &self.priority),
            "size" => self
                .size
                .as_deref()
                .map_or(Val::None, |s| at(&["xs", "s", "m", "l", "xl"], s)),
            "version" => self
                .release()
                .map_or(Val::None, |v| Val::Text(release_order(v))),
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

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Feed {
    /// The day the feed was read (`YYYY-MM-DD`, the CLI's clock), what `filed` compares to.
    pub today: String,
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

    /// The board's rows: the open ones as `open_rows` orders them, then the closed ones newest
    /// first, each day's by project, so Done reads as the days' work.
    pub fn board_rows(&self, scope: Option<(&str, &str)>) -> Vec<&Row> {
        let mut done: Vec<&Row> = self.done.iter().filter(|r| in_scope(r, scope)).collect();
        done.sort_by(|a, b| {
            b.closed
                .cmp(&a.closed)
                .then_with(|| a.project.cmp(&b.project))
        });
        let mut rows = self.open_rows(scope);
        rows.extend(done);
        rows
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
}

pub fn feed(runner: &dyn Runner) -> Result<Feed, String> {
    let out = runner.run(&["notes".into(), "board".into(), "--json".into()])?;
    let mut f: Feed = serde_json::from_str(&out).map_err(|e| format!("notes board --json: {e}"))?;
    let (focus, rows): (Vec<Row>, Vec<Row>) = f.rows.drain(..).partition(|r| r.lane == "focus");
    f.rows = rows;
    for r in &mut f.rows {
        r.filed_today = r.filed.as_deref() == Some(f.today.as_str());
    }
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

fn is_version(s: &str) -> bool {
    let Some(v) = s.strip_prefix('v') else {
        return false;
    };
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// Something a row's own text would not say: a non-high priority is the row's `#urgent` or
/// `#low` tag, and high is no tag at all, as `ptask add` reads it.
fn with_priority(text: &str, priority: &str) -> String {
    let text = text.trim();
    let tag = format!("#{priority}");
    if priority == "high" || text.split_whitespace().any(|w| w == tag) {
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
                return Err("priority is urgent, high or low".into());
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

    #[test]
    fn open_rows_follow_the_sheet_sections_then_rank_and_leave_out_done() {
        let mut f = rows();
        let all: Vec<&str> = f.open_rows(None).iter().map(|r| r.text.as_str()).collect();
        // Now before Next up before Backlog, then the feed's rank; the old priority sort put the
        // urgent "water" first.
        assert_eq!(all, ["wire the bar #size/m", "water", "ship", "tidy"]);
        assert_eq!(f.open_rows(Some(("bnb", "garden"))).len(), 1);
        assert!(f.open_rows(Some(("personal", "garden"))).is_empty());
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
            argv(&w("agent", add("-lead dash", "high", None, None))).unwrap()[5..],
            ["--agent", "add", "--", "-lead dash"],
            "high is no tag"
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
            w("human", add("x", "normal", None, None)),
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
