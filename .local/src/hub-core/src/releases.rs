//! The Releases tab, both surfaces: one row per app, what is live where it matters most and its
//! worst status, its channels (what is pinned and what is live on each) opened under it, from
//! `release-state show --json`. The collector owns the probes and the status words; this reader
//! adds only what a row needs to draw: the grouping, the levels, the column text and the
//! exceptions-first order. The Release runs inner tab beside the apps is `builds`' reader, cut by
//! `Builds::releases`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::builds::{self, Run};
use crate::pipeline::{dated, stamp};

use crate::layout;
use crate::queue::Item;
use crate::release_graph::{self, Graph, Inputs, Line, Shipment};
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// A snapshot older than this is drawn amber: the collector runs every 15 minutes, and this is
/// `release-state check`'s own `--max-age` default.
pub const STALE_SECS: i64 = 3600;
/// The collector's words, worst first (`RANK` in `release-state`). A word not listed here is
/// new, so it is drawn amber and sorts with the exceptions rather than folding as green.
const STATUSES: [(&str, Level); 6] = [
    ("drift", Level::Bad),
    ("unknown", Level::Warn),
    ("floating", Level::Warn),
    ("ok", Level::Ok),
    ("released", Level::Ok),
    ("unreleased", Level::Ok),
];

/// How the tab says a collector word: `unknown` is a channel the collector could not read, which
/// is what the human needs to hear. Every other word is said as it is written.
fn shown(status: &str) -> &str {
    match status {
        "unknown" => "not read",
        s => s,
    }
}

/// The order an app's envs are listed in, its headline first; an env not named here follows them
/// by name.
const ENVS: [&str; 6] = ["prod", "release", "beta", "alpha", "internal", "preview"];

/// What one row's state means, for its colour (docs/dashboards.md rule 5).
#[derive(Serialize, Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Bad,
    Warn,
    #[default]
    Ok,
}

/// One side of a channel: the version pinned there or the version running there.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Side {
    pub value: Option<String>,
    /// Where the value was read from, as the probe names it; `none` when nothing is probed.
    pub source: String,
    pub error: Option<String>,
    pub image: Option<String>,
    /// A gitops pin only: when the file took this value (the commit that set it) and the value
    /// it held before.
    pub at: Option<i64>,
    pub prev: Option<String>,
    /// The store's build number: what the store reports live, or what the upload recorded on
    /// its Deployment; when both sides have one it decides the status.
    pub build: Option<String>,
    /// Why a channel moved by hand (`source` `manual`) has no recorded deploy, from the registry.
    pub reason: Option<String>,
}

/// The words a blank cell says, one per cause: nothing declares the fact, nothing recorded it,
/// it moves by hand, its read failed, or the release merged nothing. A surface sorts and
/// filters them as no value. docs/operations/release-state.md, "Blank cells".
pub const BLANKS: [&str; 5] = [
    "none declared",
    "not recorded",
    "manual",
    "not read",
    "none merged",
];

/// A cell with no value: `-` or one of [`BLANKS`].
pub fn blank(cell: &str) -> bool {
    cell.is_empty() || cell == "-" || BLANKS.contains(&cell)
}

impl Side {
    /// The cell: the value, `manual` for a channel moved by hand, `not recorded` for a release
    /// tag or a recorded pin nothing has made yet, `none` when this side has no source, `not
    /// read` when a read failed.
    fn text(&self, none: &str) -> String {
        match &self.value {
            Some(v) => v.clone(),
            None if self.source == "manual" => "manual".into(),
            None if self.error.as_deref() == Some("no release tag") => "not recorded".into(),
            None if self.source == "none" => none.into(),
            None => "not read".into(),
        }
    }
}

/// One GitHub Deployment of a channel: a version, how it ended, and the run that proves it.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Deploy {
    pub version: String,
    /// `ok`, `fail`, or GitHub's word for one not finished.
    pub state: String,
    pub at: i64,
    pub url: Option<String>,
    /// The commit the Deployment was made for (its `commitOid`): the tag's commit when the
    /// recorder passes the tag as its ref, what the release graph joins on when the version
    /// names no tag.
    pub sha: Option<String>,
    /// The store's build number the upload recorded (TestFlight, Play), when it recorded one.
    pub build: Option<String>,
}

impl Deploy {
    pub fn failed(&self) -> bool {
        self.state == "fail"
    }
}

/// A channel's deployment history, from the collector.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Deploys {
    /// The GitHub repo read, `none` when the channel has none to read.
    pub source: String,
    pub error: Option<String>,
    pub history: Vec<Deploy>,
    /// The version that succeeded before the newest success.
    pub prev: Option<String>,
    /// The newest finished deployment, however it ended.
    pub last: Option<Deploy>,
}

impl Deploys {
    /// The PREV cell: `not read` when the read failed, else `none` when there is none.
    fn prev_text(&self, none: &str) -> String {
        match (&self.error, &self.prev) {
            (Some(_), _) => "not read".into(),
            (None, Some(v)) => v.clone(),
            (None, None) => none.into(),
        }
    }

    /// The LAST DEPLOY cell: `11-06 15:00 ok`, the date dropped for one today.
    fn last_text(&self, now: i64, none: &str) -> String {
        match (&self.error, &self.last) {
            (Some(_), _) => "not read".into(),
            (None, Some(d)) => format!("{} {}", stamp(d.at, now), d.state),
            (None, None) => none.into(),
        }
    }

    fn level(&self) -> Level {
        match &self.last {
            Some(d) if self.error.is_none() && d.failed() => Level::Warn,
            _ => Level::Ok,
        }
    }
}

/// One telemetry watch a channel declares.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Watch {
    pub watch: String,
    /// `OK`, `TRIP`, `pending` or `missing`.
    pub state: String,
    pub since: Option<i64>,
    #[serde(skip_deserializing)]
    pub level: Level,
}

impl Watch {
    /// A watch tripped is broken and one that was never written is a gap; `pending` has simply
    /// not run yet, which `release-state check` does not count either.
    fn judged(&self) -> Level {
        match self.state.as_str() {
            "TRIP" => Level::Bad,
            "missing" => Level::Warn,
            _ => Level::Ok,
        }
    }
}

/// Where a status word sorts: worst first, one the reader does not know last.
fn rank(status: &str) -> usize {
    STATUSES
        .iter()
        .position(|(s, _)| *s == status)
        .unwrap_or(STATUSES.len())
}

/// One project channel. The `Deserialize` fields are the collector's row as it wrote it; the
/// `skip_deserializing` ones are set by [`settle`], so a surface with only the JSON can draw it.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Release {
    pub project: String,
    pub id: String,
    pub channel: String,
    #[serde(rename = "where")]
    pub place: Option<String>,
    /// A row the collector made from a project's tags, with no declared target.
    pub implicit: bool,
    pub tag: Option<String>,
    pub pinned: Side,
    pub live: Side,
    pub deploys: Deploys,
    pub status: String,
    pub drift_since: Option<i64>,
    pub telemetry: Vec<Watch>,
    pub deps: Vec<String>,
    pub probed_at: Option<i64>,
    /// The worst of the status word, the watches and a failed last deploy: what orders the
    /// channel within its app.
    #[serde(skip_deserializing)]
    pub level: Level,
    /// The STATUS, TELEMETRY and LAST DEPLOY cells' own levels, for their colour.
    #[serde(skip_deserializing)]
    pub status_level: Level,
    #[serde(skip_deserializing)]
    pub watch_level: Level,
    #[serde(skip_deserializing)]
    pub deploy_level: Level,
    /// The STATUS cell: the collector's word as the tab says it (`not read` for `unknown`).
    #[serde(skip_deserializing)]
    pub status_text: String,
    /// The CHANNEL cell: `prod pmp-web-prod`, or `release` on an implicit row.
    #[serde(skip_deserializing)]
    pub label: String,
    #[serde(skip_deserializing)]
    pub pinned_text: String,
    #[serde(skip_deserializing)]
    pub live_text: String,
    #[serde(skip_deserializing)]
    pub prev_text: String,
    #[serde(skip_deserializing)]
    pub last_deploy_text: String,
    /// `2/3` watches OK, `-` with none declared.
    #[serde(skip_deserializing)]
    pub telemetry_text: String,
    /// Each dependency with the version pinned on it: `unity-core v0.5.0, audio`.
    #[serde(skip_deserializing)]
    pub deps_text: String,
}

impl Release {
    /// Why the channel has no deploy to show: moved by hand, no repo whose Deployments it
    /// reads, or nothing recorded there yet.
    fn no_deploy(&self) -> &'static str {
        if self.pinned.source == "manual" {
            "manual"
        } else if matches!(self.deploys.source.as_str(), "" | "none") {
            "none declared"
        } else {
            "not recorded"
        }
    }

    /// Nothing about this channel asks for attention.
    pub fn green(&self) -> bool {
        self.level == Level::Ok
    }

    /// The collector could not read this channel: a probe or a credential failed.
    pub fn unread(&self) -> bool {
        self.status == "unknown"
    }

    /// Why the channel could not be read, as the probe said it.
    pub fn why_unread(&self) -> String {
        self.live
            .error
            .clone()
            .or_else(|| self.pinned.error.clone())
            .unwrap_or_else(|| "no reason given".into())
    }

    fn word(&self) -> Level {
        STATUSES
            .iter()
            .find(|(s, _)| *s == self.status)
            .map_or(Level::Warn, |(_, l)| *l)
    }

    /// What the channel says about its app: an unread one's watches and deploys, never its word.
    fn says_for_app(&self) -> Level {
        if self.unread() {
            self.watch_level.min(self.deploy_level)
        } else {
            self.level
        }
    }
}

/// Where an env sorts among an app's: [`ENVS`] first, any other after them by name.
fn env_rank(env: &str) -> (usize, &str) {
    (
        ENVS.iter().position(|e| *e == env).unwrap_or(ENVS.len()),
        env,
    )
}

/// One app: every channel of one project, what is live where it matters most, and the worst of
/// what the channels it could read say. A channel the collector could not read is counted, but it
/// never sets the app's word: a missing store key must not hide a prod that reads fine.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct App {
    pub project: String,
    /// The worst collector word among the channels read, `unknown` when none was.
    pub status: String,
    /// The STATUS cell: [`App::status`] as the tab says it.
    pub status_text: String,
    pub level: Level,
    /// The LIVE cell: `v1.19.0 prod`, the first value in env order, live before pinned.
    pub live_text: String,
    /// The CHANNELS cell: `7: 4 ok, 1 released, 2 not read`.
    pub channels_text: String,
    /// The channels the collector could not read.
    pub unread: usize,
    /// The LAST DEPLOY cell: the newest finished deployment of any channel, and its level.
    pub last_deploy_text: String,
    pub deploy_level: Level,
    /// The channels in env order (the headline env first), read before unread and the worst
    /// first within an env.
    pub channels: Vec<Release>,
    /// How many of [`App::channels`] are the headline env's: shown when the app opens, the rest
    /// fold under [`App::others_text`].
    pub lead: usize,
    /// The folded envs in one line: `preview 2 ok; beta 1 released; internal 1 not read`.
    pub others_text: String,
    /// Which tags the history reads: `release` (its own family), `build` (per-build tags, the
    /// registry's `buildTags`) or `none`.
    pub line: String,
    /// Every tag the collector kept, newest first, each joined to the channels it reached
    /// (`hub_core::release_graph`).
    pub history: Vec<Shipment>,
    /// The RELEASED cell: the newest tag and when it was made, `v1.19.0 11-10 14:02`; with
    /// none, `none declared` with no tag glob, `not read` when git failed, `not recorded` when
    /// the glob matched none. While a build runs it adds `; building <tag> (<workflow> <elapsed>)`.
    pub released_text: String,
    /// The RELEASED cell's word with no tag, kept for [`Releases::with_builds`].
    #[serde(skip)]
    pub no_release: &'static str,
    /// The build runs the release graph joins to this app's tags, newest first.
    pub builds: Vec<AppBuild>,
    /// How full each history column is ([`Coverage`]).
    pub coverage: Coverage,
    /// `prev 6/6, deployed 4/6 (1 manual, 1 not recorded), reached 2/6, rows 2/6 (4 before
    /// 2026-11-11: not recorded)`.
    pub coverage_text: String,
    /// The lab stage (`draft` .. `prod`), empty when the snapshot names none.
    pub stage: String,
    /// What the stage asks of the deploys: `draft: CI only, no deploy expected`,
    /// `alpha: no alpha target live`, `draft: live above it: bnb-studios-prod`
    /// (`docs/stages.md`, The ladder; facts from `release-state`).
    pub stage_text: String,
    pub stage_level: Level,
}

/// One build run of an app: a CI run the release graph joins to one of its tags (its run name, its
/// log's `TAG:` line, its Deployment or its tag ref), so a queued, running, failed or cancelled
/// run lists as well as one that shipped.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct AppBuild {
    pub tag: String,
    /// The workflow with its tag or run id folded out (`Release builds`, `Steam (dodginballs)`).
    pub workflow: String,
    /// `queued 2m`, `in progress 14m`, `success`, `failed`, `cancelled`.
    pub state_text: String,
    pub level: Level,
    /// Queued or in progress.
    pub live: bool,
    /// When it started (queued: when it was created), with the date.
    pub started_text: String,
    /// When it finished, with the date; `-` while it runs.
    pub ended_text: String,
    pub url: String,
}

/// The RELEASED cell: the newest tag with when it was made, a release line's tag as its version
/// (`v1.19.0`), a build tag as its own name; and the build running now, if one is.
fn released_text(
    line: Option<&str>,
    history: &[Shipment],
    builds: &[AppBuild],
    none: &str,
) -> String {
    let made = history.first().map(|h| {
        let tag = if line == Some("release") && !h.version.is_empty() {
            format!("v{}", h.version)
        } else {
            h.tag.clone()
        };
        format!("{tag} {}", h.at_text)
    });
    let building = builds.iter().find(|b| b.live).map(|b| {
        let took = b
            .state_text
            .strip_prefix("in progress ")
            .unwrap_or(&b.state_text);
        format!("building {} ({} {took})", b.tag, b.workflow)
    });
    match (made, building) {
        (Some(m), Some(b)) => format!("{m}; {b}"),
        (m, b) => m.or(b).unwrap_or_else(|| none.into()),
    }
}

impl Releases {
    /// Each app's build runs: the builds read's `runs` the release graph tied to one of its tags
    /// (the rows Release runs lists), the newest attempt of each, newest first. The RELEASED cell
    /// then says when one is running. Safe to call again on a newer read.
    pub fn with_builds(&mut self, runs: &[Run]) {
        let mut newest: HashMap<(&str, &str, u64), (&Run, &release_graph::RunRelease)> =
            HashMap::new();
        for (r, rel) in runs.iter().filter_map(|r| Some((r, r.release.as_ref()?))) {
            let e = newest.entry((&r.forge, &r.repo, r.id)).or_insert((r, rel));
            if r.attempt > e.0.attempt {
                *e = (r, rel);
            }
        }
        let mut picked: Vec<_> = newest.into_values().collect();
        picked.sort_by_key(|(r, _)| (std::cmp::Reverse(r.started), std::cmp::Reverse(r.id)));
        for a in &mut self.apps {
            a.builds = picked
                .iter()
                .filter(|(_, rel)| rel.project == a.project)
                .map(|(r, rel)| app_build(r, &rel.tag))
                .collect();
            let line = Some(a.line.as_str());
            a.released_text = released_text(line, &a.history, &a.builds, a.no_release);
        }
    }
}

fn app_build(r: &Run, tag: &str) -> AppBuild {
    let took = crate::run_detail::took_text(r.took);
    let state_text = match (r.state.as_str(), r.conclusion.as_deref()) {
        ("queued", _) => format!("queued {took}"),
        ("running", _) => format!("in progress {took}"),
        (_, Some("failure" | "startup_failure")) => "failed".into(),
        (_, Some("timed_out")) => "timed out".into(),
        (_, Some(c)) if !c.is_empty() => c.replace('_', " "),
        (s, _) => s.to_string(),
    };
    let live = matches!(r.state.as_str(), "queued" | "running");
    let ended = (!live)
        .then(|| r.ended_at.as_deref().and_then(crate::fleet::ts))
        .flatten();
    AppBuild {
        tag: tag.to_string(),
        workflow: builds::timed_as(&r.workflow, &r.path),
        state_text,
        level: r.level,
        live,
        started_text: dated(r.started),
        ended_text: ended.map_or("-".into(), dated),
        url: r.url.clone(),
    }
}

impl App {
    /// Nothing about this app asks for attention.
    pub fn green(&self) -> bool {
        self.level == Level::Ok
    }
}

impl Row for App {
    // `channel` and `id` are last and undrawn: they hold every channel's env and id, so
    // `channel:prod` and an id still find the app.
    const COLUMNS: &'static [&'static str] = &[
        "project",
        "live",
        "status",
        "channels",
        "released",
        "last_deploy",
        "channel",
        "id",
    ];
    const STATES: &'static [&'static str] = &["all", "attention", "ok"];
    const FACETS: &'static [&'static str] = &["project", "status"];
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["live", "status"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| {
            if blank(s) {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        let every = |f: fn(&Release) -> &str| {
            let mut v: Vec<&str> = self.channels.iter().map(f).collect();
            v.dedup();
            text(&v.join(" "))
        };
        match col {
            "project" => text(&self.project),
            "live" => text(&self.live_text),
            // `not read` is a status word here, not a blank.
            "status" => Val::Text(self.status_text.clone()),
            "channels" => text(&self.channels_text),
            "released" => text(&self.released_text),
            "last_deploy" => text(&self.last_deploy_text),
            "channel" => every(|r| r.channel.as_str()),
            "id" => every(|r| r.id.as_str()),
            _ => Val::None,
        }
    }

    /// `channel:prod` matches an app with any prod channel, `status:` the app's word or the
    /// collector's (`status:unknown` as well as `status:"not read"`).
    fn vals(&self, col: &str) -> Vec<Val> {
        let text = |s: &str| Val::Text(s.to_string());
        match col {
            "channel" => self.channels.iter().map(|r| text(&r.channel)).collect(),
            "id" => self.channels.iter().map(|r| text(&r.id)).collect(),
            "status" => vec![text(&self.status_text), text(&self.status)],
            c => vec![self.val(c)],
        }
    }

    /// A bare word searches every channel too: its versions, word, deps, place and watches,
    /// so a dep or a version an opened app would show still finds it.
    fn text(&self) -> String {
        let mut parts = vec![
            self.project.clone(),
            self.live_text.clone(),
            self.status_text.clone(),
            self.channels_text.clone(),
            self.released_text.clone(),
            self.last_deploy_text.clone(),
        ];
        for r in &self.channels {
            parts.extend([
                r.channel.clone(),
                r.id.clone(),
                r.pinned_text.clone(),
                r.live_text.clone(),
                r.status.clone(),
                r.status_text.clone(),
                r.deps_text.clone(),
                r.place.clone().unwrap_or_default(),
            ]);
            parts.extend(r.telemetry.iter().map(|t| t.watch.clone()));
        }
        parts.join("\n").to_lowercase()
    }

    fn in_state(&self, state: &str) -> bool {
        match state {
            "attention" => !self.green(),
            "ok" => self.green(),
            _ => true,
        }
    }

    /// `status` sorts worst first on the first click, not by the word's spelling.
    fn rank(&self, col: &str) -> Val {
        match col {
            "status" => Val::Num(-(rank(&self.status) as f64)),
            // Newest release first on the first click, by when, not by the tag's spelling.
            "released" => self
                .history
                .first()
                .and_then(|h| h.at)
                .map_or(Val::None, |a| Val::Num(a as f64)),
            _ => self.val(col),
        }
    }
}

/// How many of an app's history cells hold a value, per column: what the Apps summary and an
/// opened app count so a blank is a number, not a guess.
#[derive(Serialize, Debug, Default, Clone, Copy, PartialEq)]
pub struct Coverage {
    pub tags: usize,
    /// Tags with the release before them (the line's first counts: it has none to name).
    pub prev: usize,
    /// Declared channels, and those with a recorded deploy.
    pub channels: usize,
    pub deployed: usize,
    /// Tags some channel says it reached.
    pub reached: usize,
    /// Tags that merged PRs, those whose PRs name a board row, and those with none from before
    /// the links were held (`Links::since`).
    pub merged: usize,
    pub rows: usize,
    pub before: usize,
}

impl Coverage {
    fn of(channels: &[Release], history: &[Shipment], since: i64) -> Coverage {
        let declared: Vec<&Release> = channels.iter().filter(|r| !r.implicit).collect();
        let merged: Vec<&Shipment> = history.iter().filter(|h| !h.prs.is_empty()).collect();
        Coverage {
            tags: history.len(),
            prev: history
                .iter()
                .enumerate()
                .filter(|(i, h)| h.prev.is_some() || *i + 1 == history.len())
                .count(),
            channels: declared.len(),
            deployed: declared.iter().filter(|r| r.deploys.last.is_some()).count(),
            reached: history.iter().filter(|h| !h.reached.is_empty()).count(),
            merged: merged.len(),
            rows: merged.iter().filter(|h| !h.rows.is_empty()).count(),
            before: merged
                .iter()
                .filter(|h| h.rows.is_empty() && h.at.is_some_and(|a| a < since))
                .count(),
        }
    }

    fn add(&mut self, o: &Coverage) {
        self.tags += o.tags;
        self.prev += o.prev;
        self.channels += o.channels;
        self.deployed += o.deployed;
        self.reached += o.reached;
        self.merged += o.merged;
        self.rows += o.rows;
        self.before += o.before;
    }

    /// `prev 6/6, deployed 4/6, reached 2/6, rows 2/6 (4 before 2026-11-11: not recorded)`;
    /// `undeployed` follows the deployed count. Empty when there is nothing to count.
    fn text(&self, since: i64, undeployed: &str) -> String {
        let mut parts = vec![];
        if self.tags > 0 {
            parts.push(format!("prev {}/{}", self.prev, self.tags));
        }
        if self.channels > 0 {
            parts.push(format!(
                "deployed {}/{}{undeployed}",
                self.deployed, self.channels
            ));
        }
        if self.tags > 0 {
            parts.push(format!("reached {}/{}", self.reached, self.tags));
        }
        if self.merged > 0 {
            let before = if self.before > 0 {
                format!(
                    " ({} before {}: not recorded)",
                    self.before,
                    release_graph::since_day(since)
                )
            } else {
                String::new()
            };
            parts.push(format!("rows {}/{}{before}", self.rows, self.merged));
        }
        parts.join(", ")
    }
}

/// The tab's one read. `at` is 0 when there is no snapshot, and `errors` says why.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Releases {
    pub at: i64,
    /// The tab's question, from `hub_core::layout`.
    pub question: String,
    /// `17 apps: 1 floating, 8 ok, 4 released, 4 unreleased`.
    pub summary: String,
    /// `9 channels not read: steam GetAppBetas failed (6), ...`; empty when every one was read.
    pub gaps: String,
    /// Every app's [`Coverage`] summed: `coverage: prev 40/40, deployed 20/30, ...`.
    pub coverage: String,
    /// Every app, exceptions first: the tab's rows.
    pub apps: Vec<App>,
    /// Every channel, flat, for the readers that join one (the briefing).
    pub rows: Vec<Release>,
    pub errors: Vec<String>,
}

impl Releases {
    /// An app's word is bad (a drift, a tripped watch) or the snapshot could not be read: the
    /// Apps inner tab's count (`layout::inner_count`), so it shows while another one is open.
    pub fn needs_look(&self) -> bool {
        !self.errors.is_empty() || self.apps.iter().any(|a| a.level == Level::Bad)
    }

    /// The snapshot is older than the collector's cadence can explain.
    pub fn stale(&self, now: i64) -> bool {
        self.at > 0 && now - self.at > STALE_SECS
    }
}

/// `release-state show --json`: the collector's raw facts, before any join.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Snapshot {
    pub generated_epoch: i64,
    pub rows: Vec<Release>,
    /// Each project's tag history, keyed by project (`release-state refresh`).
    pub releases: HashMap<String, Line>,
    /// What each lab project's stage asks of its deploys, keyed by project.
    stages: HashMap<String, StageFacts>,
    /// Why `stages` is empty: `notes` could not say.
    pub stages_error: Option<String>,
    /// The stage ladder, lowest first (`notes projects --stages`).
    pub ladder: Vec<String>,
    /// The raw facts `hub releases check` holds the links to.
    pub links: crate::release_graph::Links,
}

impl Snapshot {
    /// Project -> its lab stage, for the projects whose sheet names one on the ladder.
    pub fn stage_names(&self) -> HashMap<String, String> {
        self.stages
            .iter()
            .filter_map(|(p, f)| Some((p.clone(), f.stage.clone()?)))
            .collect()
    }
}

/// One project's stage against its deploys, as `release-state refresh` computed it: the rungs its
/// live targets serve, the rungs its stage needs and nothing serves, the targets above the stage.
#[derive(Deserialize, Default, Debug, Clone, PartialEq)]
#[serde(default)]
struct StageFacts {
    /// None when the lab sheet names no stage on the ladder.
    stage: Option<String>,
    needs: Vec<String>,
    ahead: Vec<String>,
}

/// The stage cell and its level. A project with no stage on its lab sheet says so; one the
/// snapshot has no facts for (the read failed, which `errors` names) says `not read`.
fn staged(f: Option<&StageFacts>) -> (String, String, Level) {
    let Some(f) = f else {
        return (String::new(), "not read".into(), Level::Warn);
    };
    let Some(stage) = f.stage.as_deref() else {
        return (String::new(), "none on the lab sheet".into(), Level::Ok);
    };
    let mut says: Vec<String> = vec![];
    if !f.ahead.is_empty() {
        says.push(format!("live above it: {}", f.ahead.join(", ")));
    }
    if !f.needs.is_empty() {
        says.push(format!("no {} target live", f.needs.join(" or ")));
    }
    let (text, level) = match (says.is_empty(), stage) {
        (true, "draft" | "dev") => ("CI only, no deploy expected".to_string(), Level::Ok),
        (true, _) => ("deploys match".to_string(), Level::Ok),
        (false, _) => (says.join("; "), Level::Warn),
    };
    (stage.to_string(), format!("{stage}: {text}"), level)
}

/// The rows this reader was handed, joined and ordered: exceptions first, the worst on top.
fn settle(mut rows: Vec<Release>) -> Vec<Release> {
    let now = chrono::Local::now().timestamp();
    let deps: Vec<String> = rows
        .iter()
        .map(|r| release_graph::deps_text(&r.deps, &rows))
        .collect();
    for (r, deps_text) in rows.iter_mut().zip(deps) {
        r.deps_text = deps_text;
        for w in &mut r.telemetry {
            w.level = w.judged();
        }
        r.status_level = r.word();
        r.status_text = shown(&r.status).to_string();
        r.watch_level = r
            .telemetry
            .iter()
            .map(|w| w.level)
            .min()
            .unwrap_or_default();
        r.deploy_level = r.deploys.level();
        r.level = r.status_level.min(r.watch_level).min(r.deploy_level);
        r.label = if r.implicit {
            r.channel.clone()
        } else {
            format!("{} {}", r.channel, r.id)
        };
        r.pinned_text = r.pinned.text("not recorded");
        r.live_text = r.live.text("none declared");
        let none = r.no_deploy();
        r.prev_text = r.deploys.prev_text(none);
        r.last_deploy_text = r.deploys.last_text(now, none);
        r.telemetry_text = if r.telemetry.is_empty() {
            "none declared".into()
        } else {
            let ok = r.telemetry.iter().filter(|w| w.state == "OK").count();
            format!("{ok}/{}", r.telemetry.len())
        };
    }
    rows.sort_by(|a, b| {
        let key = |r: &Release| (r.level, rank(&r.status));
        (key(a), &a.project, &a.id).cmp(&(key(b), &b.project, &b.id))
    });
    rows
}

/// One project's settled channels as its app, with its tag history joined to them.
fn app(
    project: &str,
    mut channels: Vec<Release>,
    line: Option<&Line>,
    graph: Option<&Graph>,
    stage: Option<&StageFacts>,
    since: i64,
) -> App {
    channels.sort_by(|a, b| {
        let key = |r: &Release| (r.unread(), r.level, rank(&r.status));
        (env_rank(&a.channel), key(a), &a.id).cmp(&(env_rank(&b.channel), key(b), &b.id))
    });
    // Only a channel that was read speaks for what is live: an unread one's pin is not.
    let value = |r: &Release| r.live.value.clone().or_else(|| r.pinned.value.clone());
    let head = channels.iter().find(|r| !r.unread() && value(r).is_some());
    let live_text = head.map_or_else(
        || {
            (if channels.iter().all(Release::unread) {
                "not read"
            } else {
                "not recorded"
            })
            .into()
        },
        |h| {
            // Every distinct version read in the headline env, so a web and an api that differ
            // both show.
            let mut vs: Vec<String> = vec![];
            for v in channels
                .iter()
                .filter(|r| r.channel == h.channel && !r.unread())
                .filter_map(value)
            {
                if !vs.contains(&v) {
                    vs.push(v);
                }
            }
            let vs = vs.join(", ");
            if h.implicit {
                vs
            } else {
                format!("{vs} {}", h.channel)
            }
        },
    );
    let lead_env = head
        .or(channels.first())
        .map(|r| r.channel.clone())
        .unwrap_or_default();
    // The headline env leads; the rest keep env order behind it.
    channels.sort_by_key(|r| r.channel != lead_env);
    let lead = channels.iter().filter(|r| r.channel == lead_env).count();
    let read: Vec<&Release> = channels.iter().filter(|r| !r.unread()).collect();
    let status = read
        .iter()
        .map(|r| r.status.as_str())
        .min_by_key(|s| rank(s))
        .unwrap_or("unknown")
        .to_string();
    // A tripped watch or failed deploy on an unread channel still says; nothing read is at
    // least amber.
    let says = channels
        .iter()
        .map(Release::says_for_app)
        .min()
        .unwrap_or_default();
    let level = if read.is_empty() {
        says.min(Level::Warn)
    } else {
        says
    };
    let unread = channels.len() - read.len();
    let last = channels
        .iter()
        .filter(|r| r.deploys.error.is_none())
        .filter_map(|r| r.deploys.last.as_ref().map(|d| (d.at, r)))
        .max_by_key(|(at, _)| *at)
        .map(|(_, r)| r);
    // The sort keeps an env's channels together, so each run of one env is one entry.
    let history = match (graph, line) {
        (Some(g), _) => g.history(project, &channels),
        (None, Some(l)) => release_graph::history(l, &channels),
        (None, None) => vec![],
    };
    let others: Vec<String> = channels[lead..]
        .chunk_by(|a, b| a.channel == b.channel)
        .map(|env| {
            let words = counts(env.iter().map(|x| x.status.as_str()));
            format!("{} {words}", env[0].channel)
        })
        .collect();
    let (stage, stage_text, stage_level) = staged(stage);
    let coverage = Coverage::of(&channels, &history, since);
    let undeployed = counts(
        channels
            .iter()
            .filter(|r| !r.implicit && r.deploys.last.is_none())
            .map(|r| {
                if r.deploys.error.is_some() {
                    "not read"
                } else {
                    r.no_deploy()
                }
            }),
    );
    let undeployed = if undeployed.is_empty() {
        String::new()
    } else {
        format!(" ({undeployed})")
    };
    let no_deploy = if channels.iter().all(|r| r.pinned.source == "manual") {
        "manual"
    } else if channels.iter().all(|r| r.no_deploy() == "none declared") {
        "none declared"
    } else if channels.iter().any(|r| r.deploys.error.is_some()) {
        "not read"
    } else {
        "not recorded"
    };
    let no_release = match line {
        Some(l) if l.error.is_some() => "not read",
        Some(l) if l.glob.is_some() || l.line != "none" => "not recorded",
        _ => "none declared",
    };
    App {
        project: project.to_string(),
        status_text: shown(&status).to_string(),
        status,
        level,
        live_text,
        channels_text: format!(
            "{}: {}",
            channels.len(),
            counts(channels.iter().map(|r| r.status.as_str()))
        ),
        unread,
        last_deploy_text: last.map_or(no_deploy.into(), |r| r.last_deploy_text.clone()),
        deploy_level: last.map_or(Level::Ok, |r| r.deploy_level),
        others_text: others.join("; "),
        lead,
        released_text: released_text(line.map(|l| l.line.as_str()), &history, &[], no_release),
        line: line.map_or("none".into(), |l| l.line.clone()),
        no_release,
        builds: vec![],
        coverage_text: coverage.text(since, &undeployed),
        coverage,
        history,
        channels,
        stage,
        stage_text,
        stage_level,
    }
}

/// The settled channels grouped into apps, exceptions first, then by name.
fn apps(
    rows: &[Release],
    lines: &HashMap<String, Line>,
    stages: &HashMap<String, StageFacts>,
    graph: Option<&Graph>,
    since: i64,
) -> Vec<App> {
    let mut names: Vec<&str> = rows.iter().map(|r| r.project.as_str()).collect();
    names.sort_unstable();
    names.dedup();
    let mut out: Vec<App> = names
        .into_iter()
        .map(|p| {
            let channels = rows.iter().filter(|r| r.project == p).cloned().collect();
            app(p, channels, lines.get(p), graph, stages.get(p), since)
        })
        .collect();
    out.sort_by(|a, b| {
        let key = |x: &App| (x.level, rank(&x.status));
        (key(a), &a.project).cmp(&(key(b), &b.project))
    });
    out
}

/// `9 channels not read: steam GetAppBetas failed (6), no rbw entry release_state_play (3)`, the
/// biggest cause first; empty when the collector read every channel.
fn gaps(rows: &[Release]) -> String {
    let mut n: Vec<(String, usize)> = vec![];
    for r in rows.iter().filter(|r| r.unread()) {
        let why = r.why_unread();
        match n.iter_mut().find(|(w, _)| *w == why) {
            Some((_, c)) => *c += 1,
            None => n.push((why, 1)),
        }
    }
    if n.is_empty() {
        return String::new();
    }
    let total: usize = n.iter().map(|(_, c)| c).sum();
    n.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let causes: Vec<String> = n.iter().map(|(w, c)| format!("{w} ({c})")).collect();
    format!(
        "{total} channel{} not read: {}",
        if total == 1 { "" } else { "s" },
        causes.join(", ")
    )
}

/// `4 ok, 1 released, 2 not read`, worst first, each word with its count and none with no rows.
fn counts<'a>(words: impl IntoIterator<Item = &'a str>) -> String {
    let mut n: Vec<(&str, usize)> = vec![];
    for w in words {
        match n.iter_mut().find(|(s, _)| *s == w) {
            Some((_, c)) => *c += 1,
            None => n.push((w, 1)),
        }
    }
    n.sort_by_key(|(s, _)| rank(s));
    n.iter()
        .map(|(s, c)| format!("{c} {}", shown(s)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn says(apps: &[App]) -> String {
    match apps.len() {
        0 => "no apps".into(),
        1 => format!("1 app: {}", counts(apps.iter().map(|a| a.status.as_str()))),
        n => format!(
            "{n} apps: {}",
            counts(apps.iter().map(|a| a.status.as_str()))
        ),
    }
}

/// Every channel's and every project's raw facts, unjoined: what the release graph reads.
pub fn snapshot(runner: &dyn Runner) -> Result<Snapshot, String> {
    show(runner, None)
}

fn show(runner: &dyn Runner, project: Option<&str>) -> Result<Snapshot, String> {
    let mut argv: Vec<String> = ["release-state", "show", "--json"]
        .map(String::from)
        .to_vec();
    argv.extend(project.map(String::from));
    let raw = runner
        .run(&argv)
        .map_err(|e| format!("release-state show: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("release-state show: {e}"))
}

/// The tab: every app, or what stopped the read. Nothing is carried over from an earlier read, so
/// a failed probe is never shown as the last good value. `items` are the queue's, which join a
/// release's PRs to their rows; none leaves the ROWS cell `-`. Each app's build runs are the
/// builds read's rows, put on with [`Releases::with_builds`].
pub fn read(runner: &dyn Runner, items: &[Item]) -> Releases {
    let question = layout::resolve("releases")
        .map(|t| t.question.to_string())
        .unwrap_or_default();
    match show(runner, None) {
        Ok(s) => {
            let rows = settle(s.rows);
            let registry = project_map::cached();
            let none = HashMap::new();
            let graph = Graph::new(Inputs {
                lines: &s.releases,
                channels: &rows,
                items,
                prs: &[],
                live: &none,
                registry: registry.as_deref(),
                since: s.links.since,
                run_tags: &[],
            });
            let apps = apps(&rows, &s.releases, &s.stages, Some(&graph), s.links.since);
            let mut total = Coverage::default();
            for a in &apps {
                total.add(&a.coverage);
            }
            let coverage = total.text(s.links.since, "");
            Releases {
                at: s.generated_epoch,
                question,
                summary: says(&apps),
                gaps: gaps(&rows),
                coverage: if coverage.is_empty() {
                    coverage
                } else {
                    format!("coverage: {coverage}")
                },
                apps,
                rows,
                errors: s
                    .stages_error
                    .map(|e| format!("release-state stages: {e}"))
                    .into_iter()
                    .collect(),
            }
        }
        Err(e) => Releases {
            question,
            summary: "not read".into(),
            errors: vec![e],
            ..Default::default()
        },
    }
}

/// One project's app as the Projects card's badge, linking to this tab (rule 2).
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Badge {
    /// `v1.19.0 prod, ok; channels 7: 4 ok, 1 released, 2 not read`.
    pub says: String,
    pub level: Level,
}

/// `project`'s channels, worst first; none when no refresh has run on this host yet, which the
/// tab says and a project's page has no reason to. `project` is already a safe name.
pub fn channels(runner: &dyn Runner, project: &str) -> Result<Vec<Release>, String> {
    match show(runner, Some(project)) {
        Ok(s) => Ok(settle(s.rows)),
        Err(e) if e.contains("no snapshot yet") => Ok(vec![]),
        Err(e) => Err(e),
    }
}

/// The badge for a project's [`channels`], the same words as its row on the tab; None when it
/// has none.
pub fn badge(rows: &[Release]) -> Option<Badge> {
    apps(rows, &HashMap::new(), &HashMap::new(), None, 0)
        .into_iter()
        .next()
        .map(|a| {
            let live = if blank(&a.live_text) {
                String::new()
            } else {
                format!("{}, ", a.live_text)
            };
            Badge {
                says: format!("{live}{}; channels {}", a.status_text, a.channels_text),
                level: a.level,
            }
        })
}

/// What one tag of a project shipped, from `release-state changelog --json`: the tag's
/// CHANGELOG.md section, else the merged PRs since the release before it.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Changelog {
    pub project: String,
    pub tag: String,
    /// The release this one is compared with; None for the first tag.
    pub prev: Option<String>,
    /// `CHANGELOG.md` or `merged PRs`.
    pub source: String,
    /// `v1.0.0..v1.1.0`, the tag alone when it is the first.
    pub range: String,
    /// Markdown; empty when the range holds no merged PR.
    pub text: String,
    /// Every tag of the project's line, newest first: what the picker offers.
    pub tags: Vec<String>,
}

impl Changelog {
    /// Where the tag on show sits in the picker, from the newest, 0-based.
    pub fn position(&self) -> Option<usize> {
        self.tags.iter().position(|t| *t == self.tag)
    }

    /// The tag `by` places away in the picker: positive is older. None past either end.
    pub fn neighbour(&self, by: isize) -> Option<&str> {
        let at = self.position()? as isize + by;
        usize::try_from(at)
            .ok()
            .and_then(|i| self.tags.get(i))
            .map(String::as_str)
    }
}

/// Whether a project and tag may be handed to the collector: a name that would read as an option
/// or holds odd characters never is.
pub fn askable(project: &str, tag: Option<&str>) -> bool {
    crate::projects::safe_name(project) && !tag.is_some_and(|t| t.starts_with('-'))
}

/// One tag's changelog, or the newest release's when `tag` is None. The collector checks `tag`
/// against the project's own tags; a name that would read as an option never reaches it.
pub fn changelog(
    runner: &dyn Runner,
    project: &str,
    tag: Option<&str>,
) -> Result<Changelog, String> {
    if !askable(project, tag) {
        return Err("release-state changelog: not a project or tag".into());
    }
    let mut argv: Vec<String> = ["release-state", "changelog", "--json", project]
        .map(String::from)
        .to_vec();
    argv.extend(tag.map(String::from));
    let raw = runner.run(&argv)?;
    serde_json::from_str(&raw).map_err(|e| format!("release-state changelog: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;

    /// The tab with no queue items: the joins these tests pin need none.
    fn read(runner: &dyn Runner) -> Releases {
        super::read(runner, &[])
    }

    struct Fake(Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv[..3], ["release-state", "show", "--json"]);
            self.0.clone()
        }
    }

    struct Asked(std::cell::RefCell<Vec<String>>);
    impl Runner for Asked {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            *self.0.borrow_mut() = argv.to_vec();
            Ok(
                r#"{"project":"p","tag":"p-v2","prev":"p-v1","source":"merged PRs",
                "range":"p-v1..p-v2","text":"- a (#1)","tags":["p-v3","p-v2","p-v1"]}"#
                    .into(),
            )
        }
    }

    #[test]
    fn a_changelog_asks_the_collector_for_the_tag_and_walks_the_picker() {
        let a = Asked(Default::default());
        let c = changelog(&a, "p", Some("p-v2")).unwrap();
        assert_eq!(
            *a.0.borrow(),
            ["release-state", "changelog", "--json", "p", "p-v2"]
        );
        assert_eq!(
            (c.source.as_str(), c.prev.as_deref()),
            ("merged PRs", Some("p-v1"))
        );
        assert_eq!(c.neighbour(-1), Some("p-v3"));
        assert_eq!(c.neighbour(1), Some("p-v1"));
        assert_eq!(c.neighbour(2), None);
        assert_eq!(c.neighbour(-2), None);
        changelog(&a, "p", None).unwrap();
        assert_eq!(a.0.borrow().len(), 4, "no tag asks for the newest release");
    }

    #[test]
    fn a_name_that_reads_as_an_option_never_reaches_the_collector() {
        let a = Asked(Default::default());
        assert!(changelog(&a, "-h", None).is_err());
        assert!(changelog(&a, "p", Some("--list")).is_err());
        assert!(a.0.borrow().is_empty());
        struct Down;
        impl Runner for Down {
            fn run(&self, _: &[String]) -> Result<String, String> {
                Err("release-state: p has no release tags".into())
            }
        }
        assert_eq!(
            changelog(&Down, "p", None).unwrap_err(),
            "release-state: p has no release tags"
        );
    }

    #[test]
    fn a_host_with_no_snapshot_has_no_badge_and_a_broken_read_still_says_so() {
        let none = Fake(Err(
            "release-state: no snapshot yet; run: release-state refresh".into(),
        ));
        assert_eq!(channels(&none, "game"), Ok(vec![]));
        let broken = Fake(Err("jq: not found".into()));
        assert!(channels(&broken, "game").unwrap_err().contains("jq"));
    }

    fn row(project: &str, id: &str, status: &str) -> serde_json::Value {
        serde_json::json!({
            "project": project, "id": id, "channel": "prod", "where": null, "implicit": false,
            "tag": null, "pinned": {"value": "v2", "source": "m"},
            "live": {"value": "v1", "source": "k8s"}, "status": status, "drift_since": null,
            "telemetry": [], "deps": [], "probed_at": 5,
        })
    }

    fn snapshot(rows: Vec<serde_json::Value>) -> Fake {
        Fake(Ok(
            serde_json::json!({ "generated_epoch": 100, "rows": rows }).to_string(),
        ))
    }

    #[test]
    fn exceptions_lead_worst_first_and_the_summary_counts_every_status() {
        let r = read(&snapshot(vec![
            row("a", "a-prod", "ok"),
            row("b", "b-prod", "unreleased"),
            row("c", "c-prod", "floating"),
            row("d", "d-prod", "drift"),
            row("e", "e-prod", "unknown"),
        ]));
        let ids: Vec<&str> = r.rows.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, ["d-prod", "e-prod", "c-prod", "a-prod", "b-prod"]);
        assert_eq!(
            r.summary,
            "5 apps: 1 drift, 1 not read, 1 floating, 1 ok, 1 unreleased"
        );
        let apps: Vec<&str> = r.apps.iter().map(|x| x.project.as_str()).collect();
        assert_eq!(apps, ["d", "e", "c", "a", "b"]);
        assert_eq!(r.at, 100);
        assert_eq!(r.question, "What is live where, and which builds made it?");
    }

    #[test]
    fn a_status_the_reader_does_not_know_is_amber_never_folded_as_green() {
        let r = read(&snapshot(vec![row("a", "a", "melting")]));
        assert_eq!(r.rows[0].level, Level::Warn);
        assert!(!r.rows[0].green());
    }

    #[test]
    fn a_watch_raises_a_green_channel_and_pending_does_not() {
        let tel = |state: &str| {
            let mut v = row("a", "a", "ok");
            v["telemetry"] = serde_json::json!([{"watch": "w", "state": state, "since": 3}]);
            v
        };
        let level = |state: &str| read(&snapshot(vec![tel(state)])).rows[0].level;
        assert_eq!(level("TRIP"), Level::Bad);
        assert_eq!(level("missing"), Level::Warn);
        assert_eq!(level("pending"), Level::Ok);
        let r = read(&snapshot(vec![tel("OK")]));
        assert_eq!(r.rows[0].telemetry_text, "1/1");
    }

    #[test]
    fn a_blank_says_its_cause() {
        let side = |v: serde_json::Value, none: &str| {
            serde_json::from_value::<Side>(v).unwrap().text(none)
        };
        assert_eq!(
            side(
                serde_json::json!({"value": "v1", "source": "x"}),
                "none declared"
            ),
            "v1"
        );
        // A pin nothing recorded yet, and a live side nothing probes.
        assert_eq!(
            side(
                serde_json::json!({"value": null, "source": "none"}),
                "not recorded"
            ),
            "not recorded"
        );
        assert_eq!(
            side(
                serde_json::json!({"value": null, "source": "none"}),
                "none declared"
            ),
            "none declared"
        );
        assert_eq!(
            side(
                serde_json::json!({"source": "tag", "error": "no release tag"}),
                "none declared"
            ),
            "not recorded"
        );
        assert_eq!(
            side(
                serde_json::json!({"source": "k8s", "error": "timeout"}),
                "none declared"
            ),
            "not read"
        );
        // A channel moved by hand says so instead of a blank.
        assert_eq!(
            side(
                serde_json::json!({"value": null, "source": "manual", "reason": "set in Steamworks"}),
                "not recorded"
            ),
            "manual"
        );
    }

    #[test]
    fn a_channel_with_no_history_says_why() {
        let with = |d: serde_json::Value| {
            let mut v = row("a", "a", "ok");
            v["deploys"] = d;
            read(&snapshot(vec![v])).rows.remove(0)
        };
        let none = with(serde_json::json!({"source": "none", "history": []}));
        assert_eq!(
            (none.prev_text.as_str(), none.last_deploy_text.as_str()),
            ("none declared", "none declared")
        );
        assert!(none.green());
        let empty = with(serde_json::json!({"source": "o/r", "history": []}));
        assert_eq!(
            (empty.prev_text.as_str(), empty.last_deploy_text.as_str()),
            ("not recorded", "not recorded")
        );
        let broken = with(serde_json::json!({"source": "o/r", "error": "gh api failed"}));
        assert_eq!(
            (broken.prev_text.as_str(), broken.last_deploy_text.as_str()),
            ("not read", "not read")
        );
        assert!(
            broken.green(),
            "an unread history says nothing about the channel"
        );
    }

    #[test]
    fn a_failed_last_deploy_is_amber_and_stops_the_row_folding() {
        let with = |state: &str| {
            let mut v = row("a", "a", "ok");
            v["deploys"] = serde_json::json!({
                "source": "o/r", "prev": "v1",
                "last": {"version": "v2", "state": state, "at": 1_794_002_400, "url": "https://x/1"},
            });
            read(&snapshot(vec![v])).rows.remove(0)
        };
        let at = 1_794_002_400;
        let now = chrono::Local::now().timestamp();
        let ok = with("ok");
        assert_eq!(ok.prev_text, "v1");
        assert_eq!(ok.last_deploy_text, format!("{} ok", stamp(at, now)));
        assert!(ok.green());
        let failed = with("fail");
        assert_eq!(failed.last_deploy_text, format!("{} fail", stamp(at, now)));
        assert_eq!(
            (failed.deploy_level, failed.level),
            (Level::Warn, Level::Warn)
        );
        assert!(!failed.green());
    }

    #[test]
    fn a_dependency_names_its_prod_pin_and_an_unlisted_one_stands_alone() {
        let mut app = row("app", "app-prod", "ok");
        app["deps"] = serde_json::json!(["lib", "other"]);
        let mut preview = row("lib", "lib-preview", "ok");
        preview["channel"] = "preview".into();
        preview["pinned"]["value"] = "p9".into();
        let r = read(&snapshot(vec![preview, app, row("lib", "lib-prod", "ok")]));
        let a = r.rows.iter().find(|x| x.project == "app").unwrap();
        assert_eq!(a.deps_text, "lib v2, other");
    }

    #[test]
    fn an_implicit_row_labels_only_its_channel() {
        let mut v = row("a", "a", "released");
        v["implicit"] = true.into();
        v["channel"] = "release".into();
        let r = read(&snapshot(vec![v, row("b", "b-prod", "ok")]));
        let labels: Vec<&str> = r.rows.iter().map(|x| x.label.as_str()).collect();
        assert_eq!(labels, ["prod b-prod", "release"]);
    }

    /// One channel as the collector writes it: `live` None is a store it could not read.
    fn chan(
        project: &str,
        id: &str,
        env: &str,
        live: Option<&str>,
        status: &str,
    ) -> serde_json::Value {
        let mut v = row(project, id, status);
        v["channel"] = env.into();
        v["pinned"] = serde_json::json!({"value": live, "source": "m"});
        v["live"] = match live {
            Some(l) => serde_json::json!({"value": l, "source": "k8s"}),
            None => {
                serde_json::json!({"value": null, "source": "store", "error": format!("{id} key missing")})
            }
        };
        v
    }

    /// The 2026-11-10 shape that hid prod: an app whose prod reads fine beside store channels the
    /// collector could not read, and an app with nothing read at all.
    fn shipped() -> Releases {
        let mut a = chan("app", "app-android-prod", "prod", None, "unknown");
        a["live"]["error"] = "no rbw entry".into();
        let mut b = chan("app", "app-android-internal", "internal", None, "unknown");
        b["live"]["error"] = "no rbw entry".into();
        let mut g1 = chan("game", "game-steam-beta", "beta", None, "unknown");
        g1["live"]["error"] = "steam 403".into();
        let mut g2 = chan("game", "game-steam-default", "prod", None, "unknown");
        g2["live"]["error"] = "steam 403".into();
        let mut ios = chan("app", "app-ios", "beta", Some("1.19.0 (7)"), "released");
        ios["pinned"] = serde_json::json!({"value": null, "source": "none"});
        read(&snapshot(vec![
            a,
            chan("app", "app-web-prod", "prod", Some("v1.19.0"), "ok"),
            chan("app", "app-api-prod", "prod", Some("v1.19.0"), "ok"),
            chan("app", "app-web-preview", "preview", Some("pre-1"), "ok"),
            b,
            ios,
            g1,
            g2,
        ]))
    }

    #[test]
    fn an_app_is_one_row_and_a_channel_it_could_not_read_does_not_hide_its_prod() {
        let r = shipped();
        let app = r.apps.iter().find(|a| a.project == "app").unwrap();
        assert_eq!(app.live_text, "v1.19.0 prod");
        assert_eq!((app.status_text.as_str(), app.level), ("ok", Level::Ok));
        assert_eq!(app.channels_text, "6: 2 not read, 3 ok, 1 released");
        assert_eq!(app.unread, 2);
        let ids: Vec<&str> = app.channels.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "app-api-prod",
                "app-web-prod",
                "app-android-prod",
                "app-ios",
                "app-android-internal",
                "app-web-preview"
            ],
            "the headline env first, read before unread, then the envs in order"
        );
        assert_eq!(app.lead, 3);
        assert_eq!(
            app.others_text,
            "beta 1 released; internal 1 not read; preview 1 ok"
        );
        // Negative control: before, the plain view folded every green channel, so the only rows
        // left were the four unread ones and no row said v1.19.0.
        let drawn: Vec<&Release> = r.rows.iter().filter(|c| !c.green()).collect();
        assert!(drawn.iter().all(|c| c.unread()) && drawn.len() == 4);
        assert!(drawn.iter().all(|c| c.live_text != "v1.19.0"));
    }

    #[test]
    fn an_app_with_nothing_read_is_amber_and_leads() {
        let r = shipped();
        let game = &r.apps[0];
        assert_eq!(game.project, "game");
        assert_eq!(
            (game.status_text.as_str(), game.level),
            ("not read", Level::Warn)
        );
        assert_eq!((game.live_text.as_str(), game.unread), ("not read", 2));
        assert_eq!(r.summary, "2 apps: 1 not read, 1 ok");
    }

    #[test]
    fn the_gap_line_names_each_cause_once_biggest_first() {
        let r = shipped();
        assert_eq!(
            r.gaps,
            "4 channels not read: no rbw entry (2), steam 403 (2)"
        );
        let none = read(&snapshot(vec![row("a", "a", "ok")]));
        assert_eq!(none.gaps, "");
    }

    #[test]
    fn a_read_drift_still_makes_its_app_red_and_first() {
        let mut v = shipped().apps;
        assert!(v.iter().all(|a| a.level != Level::Bad));
        let r = read(&snapshot(vec![
            chan("app", "app-web-prod", "prod", Some("v1"), "ok"),
            chan("app", "app-api-prod", "prod", Some("v2"), "drift"),
            chan("zed", "zed-prod", "prod", None, "unknown"),
        ]));
        // A bad app is what puts a count on the Apps inner tab; unread and floating ones do not.
        assert!(r.needs_look() && !shipped().needs_look());
        v = r.apps;
        assert_eq!((v[0].project.as_str(), v[0].level), ("app", Level::Bad));
        assert_eq!(v[0].status_text, "drift");
        assert_eq!(
            v[0].live_text, "v2, v1 prod",
            "every prod version read shows, the worst channel's first"
        );
    }

    #[test]
    fn an_unread_channels_pin_does_not_speak_for_what_is_live() {
        let mut pinned = chan("app", "app-web-prod", "prod", None, "unknown");
        pinned["pinned"] = serde_json::json!({"value": "v1.19.0", "source": "manifest"});
        let beta = chan("app", "app-ios", "beta", Some("1.19.0 (7)"), "released");
        let a = &read(&snapshot(vec![pinned.clone(), beta])).apps[0];
        assert_eq!(a.live_text, "1.19.0 (7) beta");
        let a = &read(&snapshot(vec![pinned])).apps[0];
        assert_eq!(
            (a.live_text.as_str(), a.status_text.as_str()),
            ("not read", "not read")
        );
    }

    #[test]
    fn a_tripped_watch_on_an_app_with_nothing_read_is_red_not_amber() {
        let mut c = chan("game", "game-steam-default", "prod", None, "unknown");
        c["telemetry"] = serde_json::json!([{"watch": "game-probe", "state": "TRIP", "since": 1}]);
        let a = &read(&snapshot(vec![c])).apps[0];
        assert_eq!((a.status_text.as_str(), a.level), ("not read", Level::Bad));
    }

    #[test]
    fn a_bare_word_finds_an_app_by_what_only_its_channels_say() {
        let mut c = chan("app", "app-web-prod", "prod", Some("v1.2.2"), "ok");
        c["deps"] = serde_json::json!(["unity-core"]);
        c["telemetry"] = serde_json::json!([{"watch": "app-probe", "state": "OK"}]);
        let beta = chan("app", "app-api-beta", "beta", Some("v9.9.9"), "ok");
        let r = read(&snapshot(vec![c, beta]));
        for word in ["unity-core", "app-probe", "v9.9.9", "unknown-word"] {
            let q = View {
                q: word.into(),
                state: "all".into(),
                ..Default::default()
            };
            let n = q.apply(&r.apps).len();
            assert_eq!(n, usize::from(word != "unknown-word"), "{word}");
        }
    }

    #[test]
    fn an_implicit_app_says_its_tag_with_no_env() {
        let mut v = row("t", "t", "released");
        v["implicit"] = true.into();
        v["channel"] = "release".into();
        v["pinned"] = serde_json::json!({"value": "t-v1.0.1", "source": "newest release tag"});
        v["live"] = serde_json::json!({"value": null, "source": "none"});
        let a = &read(&snapshot(vec![v])).apps[0];
        assert_eq!(
            (a.live_text.as_str(), a.status_text.as_str()),
            ("t-v1.0.1", "released")
        );
    }

    #[test]
    fn a_query_finds_apps_by_any_channel_and_status_by_either_word() {
        let r = shipped();
        let find = |q: &str| -> Vec<String> {
            View::new::<App>(q, "", "", "")
                .apply(&r.apps)
                .iter()
                .map(|a| a.project.clone())
                .collect()
        };
        assert_eq!(find("project:app"), ["app"]);
        assert_eq!(find("channel:preview"), ["app"]);
        assert_eq!(find("channel:prod"), ["game", "app"]);
        assert_eq!(find("status:unknown"), ["game"]);
        assert_eq!(find("status:\"not read\""), ["game"]);
        assert_eq!(find("game-steam-beta"), ["game"]);
        let ok = View::new::<App>("", "ok", "", "");
        assert_eq!(ok.apply(&r.apps).len(), 1);
        let attention = View::new::<App>("", "attention", "", "");
        assert_eq!(attention.apply(&r.apps)[0].project, "game");
    }

    #[test]
    fn the_status_column_sorts_worst_first_on_the_first_click() {
        let r = read(&snapshot(vec![row("a", "a", "ok"), row("b", "b", "drift")]));
        let v = View::new::<App>("", "", "status", "desc");
        assert_eq!(v.apply(&r.apps)[0].status, "drift");
    }

    #[test]
    fn a_failed_read_says_so_and_keeps_no_rows() {
        let r = read(&Fake(Err("no snapshot yet".into())));
        assert_eq!(r.errors, ["release-state show: no snapshot yet"]);
        assert!(r.rows.is_empty());
        assert_eq!(r.at, 0);
        assert!(!r.stale(1_000_000), "no snapshot is an error, not stale");
    }

    #[test]
    fn a_snapshot_past_the_collectors_cadence_is_stale() {
        let r = read(&snapshot(vec![]));
        assert!(!r.stale(100 + STALE_SECS));
        assert!(r.stale(100 + STALE_SECS + 1));
    }

    #[test]
    fn a_badge_counts_the_projects_channels_at_its_worst_level() {
        let rows = channels(
            &snapshot(vec![row("a", "x", "ok"), row("a", "y", "drift")]),
            "a",
        )
        .unwrap();
        let b = badge(&rows).unwrap();
        assert_eq!(b.says, "v1 prod, drift; channels 2: 1 drift, 1 ok");
        assert_eq!(b.level, Level::Bad);
        assert_eq!(badge(&channels(&snapshot(vec![]), "a").unwrap()), None);
    }

    #[test]
    fn the_real_row_shape_reads() {
        let raw = r#"{"generated_epoch": 7, "rows": [{"project": "freelance", "id": "freelance",
          "channel": "release", "where": null, "implicit": true, "tag": null,
          "pinned": {"value": null, "source": "newest release tag", "error": "no release tag"},
          "live": {"value": null, "source": "none"}, "status": "unreleased", "drift_since": null,
          "telemetry": [], "deps": [], "probed_at": 9}]}"#;
        let r = read(&Fake(Ok(raw.into())));
        assert_eq!(r.errors, Vec::<String>::new());
        assert_eq!(r.rows[0].pinned_text, "not recorded");
        assert_eq!(r.rows[0].live_text, "none declared");
        assert_eq!(
            (r.apps[0].line.as_str(), r.apps[0].released_text.as_str()),
            ("none", "none declared")
        );
    }

    #[test]
    fn an_app_reads_its_tag_history_joined_to_its_channels() {
        let raw = r#"{"generated_epoch": 7, "rows": [{"project": "pmp", "id": "pmp-web-prod",
          "channel": "prod", "pinned": {"value": "v1.19.0", "source": "repo:origin/main:f.yaml",
          "at": 1793111939, "prev": "v1.18.0"}, "live": {"value": "v1.19.0", "source": "k8s"},
          "status": "ok", "deploys": {"source": "none", "history": []}}],
          "releases": {"pmp": {"line": "release", "glob": "pmp-v*", "error": null, "tags": [
            {"tag": "pmp-v1.19.0", "version": "1.19.0", "sha": "fc99", "at": 1793081423, "prev": "pmp-v1.18.0"},
            {"tag": "pmp-v1.18.0", "version": "1.18.0", "sha": "ab12", "at": 1792000000, "prev": null}]}}}"#;
        let r = read(&Fake(Ok(raw.into())));
        let a = &r.apps[0];
        assert_eq!(a.line, "release");
        assert_eq!(a.history.len(), 2);
        assert!(
            a.released_text.starts_with("v1.19.0 "),
            "{}",
            a.released_text
        );
        assert_eq!(a.history[0].prev.as_deref(), Some("pmp-v1.18.0"));
        // The prod pin names v1.19.0, so the newest release reached it; the older one did not.
        assert_eq!(a.history[0].reached[0].how, "pin");
        assert_eq!(a.history[1].reached_text, "not recorded");
        assert_eq!(r.rows[0].pinned.prev.as_deref(), Some("v1.18.0"));
        // Each column counted, the undeployed channel with its cause; a tag that merged no PR
        // has no row to count.
        assert_eq!(
            a.coverage_text,
            "prev 2/2, deployed 0/1 (1 none declared), reached 1/2"
        );
        assert_eq!(r.coverage, "coverage: prev 2/2, deployed 0/1, reached 1/2");
        assert_eq!(a.history[1].prs_text, "none merged");
    }

    #[test]
    fn an_app_lists_its_build_runs_newest_first_and_its_row_says_one_is_running() {
        let dir = std::env::temp_dir().join(format!("hub-rel-builds-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let paths = builds::Paths {
            ledger: dir.join("runs.jsonl"),
            sync: dir.join("sync.json"),
            fleet: dir.join("state.json"),
            prs: dir.join("prs"),
            jobs: dir.join("jobs.jsonl"),
            quarantine: dir.join("quarantine.json"),
            run_tags: dir.join("run-tags.jsonl"),
        };
        let now = chrono::Utc::now();
        let iso = |ago: i64| (now - chrono::Duration::seconds(ago)).to_rfc3339();
        let run = |id: u64,
                   attempt: u32,
                   name: &str,
                   status: &str,
                   concl: Option<&str>,
                   ago: i64,
                   end: Option<i64>| {
            serde_json::json!({"forge": "github", "repo": "Acme/game", "id": id, "attempt": attempt,
                "workflow": name, "path": ".github/workflows/release.yml", "title": name,
                "branch": "main", "event": "workflow_dispatch", "status": status,
                "conclusion": concl, "created_at": iso(ago), "started_at": iso(ago),
                "ended_at": end.map(iso), "url": format!("https://github.com/Acme/game/actions/runs/{id}")})
            .to_string()
        };
        let ledger = [
            run(
                10,
                1,
                "Release builds",
                "completed",
                Some("success"),
                9000,
                Some(8000),
            ),
            run(
                11,
                1,
                "Steam",
                "completed",
                Some("cancelled"),
                7000,
                Some(6900),
            ),
            run(
                11,
                2,
                "Steam",
                "completed",
                Some("success"),
                6000,
                Some(5000),
            ),
            run(
                12,
                1,
                "Release builds of v0.5.0-game8",
                "in_progress",
                None,
                600,
                None,
            ),
            run(13, 1, "Tests", "completed", Some("failure"), 500, Some(400)),
        ];
        std::fs::write(&paths.ledger, ledger.join("\n")).unwrap();
        std::fs::write(
            &paths.run_tags,
            "{\"repo\":\"Acme/game\",\"id\":10,\"tag\":\"v0.5.0-game7\"}\n{\"repo\":\"Acme/game\",\"id\":11,\"of\":10}\n",
        )
        .unwrap();
        let raw = r#"{"generated_epoch": 7, "rows": [{"project": "game", "id": "game-steam",
          "channel": "prod", "status": "ok", "live": {"value": "v0.5.0-game7"}}],
          "releases": {"game": {"line": "build", "repo": "Acme/game", "tags": [
            {"tag": "v0.5.0-game8", "version": "0.5.0-game8", "at": 1794000000},
            {"tag": "v0.5.0-game7", "version": "0.5.0-game7", "at": 1793990000}]}}}"#;
        let fake = Fake(Ok(raw.into()));
        let join = || builds::Join {
            runner: &fake,
            items: &[],
        };
        let b = builds::read(&paths, Some(join()), now.timestamp());
        let mut r = read(&fake);
        r.with_builds(&b.rows);
        assert_eq!(r.errors, Vec::<String>::new());
        let a = &r.apps[0];
        let got: Vec<(&str, &str, &str)> = a
            .builds
            .iter()
            .map(|b| (b.tag.as_str(), b.workflow.as_str(), b.state_text.as_str()))
            .collect();
        // The running one's elapsed time is read against the clock: 10m, or 10m01 a second on.
        assert!(got[0].2.starts_with("in progress 10m"), "{}", got[0].2);
        let got: Vec<_> = got
            .into_iter()
            .map(|(t, w, s)| {
                (
                    t,
                    w,
                    if s.starts_with("in progress") {
                        "in progress"
                    } else {
                        s
                    },
                )
            })
            .collect();
        // The newest attempt of each run; the Tests run names no tag and lists nowhere.
        assert_eq!(
            got,
            vec![
                ("v0.5.0-game8", "Release builds", "in progress"),
                ("v0.5.0-game7", "Steam", "success"),
                ("v0.5.0-game7", "Release builds", "success"),
            ]
        );
        assert_eq!(a.builds[0].ended_text, "-");
        assert_eq!(a.builds[2].started_text.len(), "11-11 00:16".len());
        assert!(a.builds[2].url.ends_with("/runs/10"));
        assert!(
            a.released_text
                .contains("; building v0.5.0-game8 (Release builds 10m"),
            "{}",
            a.released_text
        );
        // A newer builds read replaces the runs rather than adding to them.
        r.with_builds(&b.rows);
        assert_eq!(r.apps[0].builds.len(), 3);
        assert_eq!(r.apps[0].released_text.matches("building").count(), 1);
        // negative control: no ledger is no builds, and the cell names no build.
        std::fs::remove_dir_all(&dir).unwrap();
        let b = builds::read(&paths, Some(join()), now.timestamp());
        r.with_builds(&b.rows);
        assert_eq!(r.apps[0].builds.len(), 0);
        assert!(!r.apps[0].released_text.contains("building"));
    }

    #[test]
    fn each_app_says_what_its_stage_asks_of_its_deploys() {
        let row = |p: &str| {
            format!(
                r#"{{"project": "{p}", "id": "{p}-prod", "channel": "prod", "status": "ok",
                  "pinned": {{"value": "v1"}}, "live": {{"value": "v1"}}}}"#
            )
        };
        let raw = format!(
            r#"{{"generated_epoch": 7, "rows": [{}, {}, {}, {}, {}],
              "stages": {{"site": {{"stage": "draft", "rungs": ["prod"],
                  "needs": [], "ahead": ["site-prod"]}},
                "tool": {{"stage": "draft", "rungs": [], "needs": [], "ahead": []}},
                "new": {{"stage": null, "rungs": ["prod"], "needs": [], "ahead": []}},
                "game": {{"stage": "prod", "rungs": ["prod"],
                  "needs": ["alpha", "beta"], "ahead": []}}}}}}"#,
            row("site"),
            row("tool"),
            row("game"),
            row("new"),
            row("lone")
        );
        let r = read(&Fake(Ok(raw)));
        let says = |p: &str| {
            let a = r.apps.iter().find(|a| a.project == p).unwrap();
            (a.stage.as_str(), a.stage_text.as_str(), a.stage_level)
        };
        assert_eq!(
            says("site"),
            ("draft", "draft: live above it: site-prod", Level::Warn)
        );
        assert_eq!(
            says("tool"),
            ("draft", "draft: CI only, no deploy expected", Level::Ok)
        );
        assert_eq!(
            says("game"),
            ("prod", "prod: no alpha or beta target live", Level::Warn)
        );
        assert_eq!(says("new"), ("", "none on the lab sheet", Level::Ok));
        // No facts at all is a read that failed, never a quiet blank.
        assert_eq!(says("lone"), ("", "not read", Level::Warn));
        assert!(r.errors.is_empty());
    }

    #[test]
    fn a_stage_the_collector_could_not_read_is_an_error_not_a_blank() {
        let raw = r#"{"generated_epoch": 7, "rows": [], "stages": {},
          "stages_error": "notes projects --stages printed nothing"}"#;
        let r = read(&Fake(Ok(raw.into())));
        assert_eq!(
            r.errors,
            ["release-state stages: notes projects --stages printed nothing"]
        );
    }
}
