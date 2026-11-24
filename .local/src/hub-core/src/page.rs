//! One project's page, read when its card is opened (dashboards rule 10), never for every card:
//! its systems first (each with its progress, its features and their percents; the tasks are
//! the rows view's, never drawn here), the Flow line, what needs the human, the next stage's
//! gaps, the shipped versions and the dev timeline. Every number is counted by its
//! owner and this module only joins them and says the words, so agent-web and the hub TUI print
//! the same lines: `fleet-bench epics` (the chain, `epics.rs`), `project-stage-check` (next stage
//! and system criteria), `notes projects --roadmap --json` (shipped versions) and
//! `project-timeline` (`timeline.rs`). A source that fails is named in `errors` and the rest of
//! the page still shows.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::epics::{self, Chain, Epic};
use crate::projects::Card;
use crate::session_actions::Runner;

/// Next stage's head at the top of the ladder.
pub const NO_NEXT: &str = "no stage after this one";

/// One epic as its system's line: `one project page  20%  [rows]  brief yes  plan 2 of 7 ...`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct EpicLine {
    pub id: String,
    pub line: String,
    /// Behind its frozen baseline, which a surface marks.
    pub behind: bool,
}

/// A system's current wave (`lifecycle.md`, "What an epic is"): its first open feature epic in
/// sheet order, and how many more feature epics it has open.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Wave {
    pub id: String,
    pub title: String,
    /// The epic's own weighted done share; None when its leaves carry no weight.
    pub percent: Option<u32>,
    pub more: usize,
}

/// The next stage's gate as numbers: what `next_says` says, for a reader that composes its own.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Gate {
    pub stage: String,
    pub met: u32,
    pub total: u32,
    pub fail: u32,
    pub human: u32,
}

/// One kind of thing the chain asks of the human, as Needs you groups it: `verify` (epics whose
/// rows all landed with no live proof) or `plan` (plans that name no epic). `says` is the
/// group's line with its count; `items` are its lines, each kind's every one.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct NeedGroup {
    pub kind: String,
    pub says: String,
    pub items: Vec<String>,
}

/// A system: its progress and criteria, then its open epics; closed ones are a count.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct System {
    pub id: String,
    /// `gameplay  41%  4 features, 0 done, 1 standard epic  criteria 3 of 5`; a system with no
    /// epic has no percent (`ui  criteria 5 of 7`), and one the project type does not list says
    /// `no criteria`.
    pub head: String,
    /// The weighted done share of its leaves over its open epics and the epics closed in the
    /// open version; None with no epic to count.
    pub percent: Option<u32>,
    pub epics: Vec<EpicLine>,
    /// None when it has no open feature epic: no epic, or only its standing one.
    pub wave: Option<Wave>,
    /// `+3 closed, 2 verified`, empty when none closed.
    pub closed: String,
    /// The head's numbers, for a surface that draws them as columns: its criteria (None when the
    /// project type does not list the system), its feature epics counted and done, its open
    /// standard epics, the open rows under its open epics and how many of those epics run behind.
    pub criteria_met: Option<u32>,
    pub criteria_total: Option<u32>,
    pub features: usize,
    pub features_done: usize,
    pub standing: usize,
    pub open_rows: u32,
    pub behind: usize,
}

/// One requirement of the next stage that is not met: FAIL, HUMAN or TODO.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Requirement {
    pub stage: String,
    pub result: String,
    pub requirement: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Page {
    pub project: String,
    /// `ideas 19 | briefs 2 | ...`; None when the chain could not be read.
    pub flow_line: Option<String>,
    /// What needs the human, grouped by kind, each with its count and every item: the chain's
    /// (`need_groups`), then the next stage's failing and human checks (kind `stage`).
    pub need_groups: Vec<NeedGroup>,
    /// How many items Overview's Needs you lists: those groups, plus the departments' once
    /// `with_department_needs` has them. The number on Overview's inner tab, on both surfaces.
    pub need_count: usize,
    /// The project's open feature epics as the Deliverables table, the TUI's Build inner tab
    /// (agent-web reads `/api/deliverables?scope=` for its own, the same `deliverables::build`).
    #[serde(skip)]
    pub build: crate::deliverables::Deliverables,
    /// Build by system's head: `3 systems, 2 open epics (438 rows with no epic)`.
    pub systems_says: String,
    pub systems: Vec<System>,
    /// Next stage's head: `beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet`, or
    /// `no stage after this one` at the top.
    pub next_says: String,
    /// None at the top stage or when the check could not be read.
    pub gate: Option<Gate>,
    pub next_rows: Vec<Requirement>,
    /// Shipped's head: `2 versions`, `1 version` or `none yet`.
    pub shipped_says: String,
    /// `v0.0.0: 20 rows closed; feat 9, fix 7, docs 4`, newest first.
    pub shipped: Vec<String>,
    /// The channels' one-line badge, linking to the Releases tab; None with no channels.
    pub releases: Option<crate::releases::Badge>,
    /// The Releases inner tab: the project's versions, its apps and the Legacy fold.
    pub release_tab: crate::project_releases::Tab,
    /// The project's scored sprints, newest first (`project_sprints::past`), the Sprint inner tab's
    /// Past sprints. The open and queued windows are the feed's, which a page read does not hold.
    pub sprint_past: Vec<crate::project_sprints::Past>,
    /// `3 watches, 1 firing` over the watches that name this project, linking to the Alerts tab
    /// filtered to it; None when no watch does.
    pub alerts: Option<crate::releases::Badge>,
    /// The app's Gatus checks as its status page's banner, linking to that page, set by
    /// [`Page::read_checks`]; None for a project with no channels, `no check` for an app no
    /// check covers.
    pub checks: Option<crate::releases::Badge>,
    /// The app's Gatus groups (`app_status::groups`), empty for a project with no channels.
    #[serde(skip)]
    pub check_groups: Vec<String>,
    /// The Timeline fold; None when `project-timeline` could not be read (named in `errors`).
    pub timeline: Option<crate::timeline::Timeline>,
    pub errors: Vec<String>,
}

impl Page {
    /// The checks badge from the app's Gatus groups, a VictoriaMetrics read kept out of [`read`]
    /// as the Releases tab keeps it out of its own; a project with no channels costs no read.
    pub fn read_checks(&mut self, runner: &(dyn Runner + Sync), now: i64) {
        if let Some(groups) = self.check_read() {
            self.with_checks(&crate::app_status::badges(runner, &groups, now));
        }
    }

    /// What [`crate::app_status::badges`] is asked for this page: its app and groups, or None
    /// for a project with no channels. agent-web reads it through its own keep.
    pub fn check_read(&self) -> Option<Vec<(String, Vec<String>)>> {
        (!self.check_groups.is_empty())
            .then(|| vec![(self.project.clone(), self.check_groups.clone())])
    }

    /// Overview's Needs you count: every item of the work's groups, then the departments'
    /// (`Product::need_groups`) when the product is known.
    pub fn overview_needs(&self, prod: Option<&crate::departments::Product>) -> usize {
        let own = need_count(&self.need_groups);
        own + prod.map_or(0, |p| need_count(&p.need_groups()))
    }

    /// Sets `need_count` with the departments' needs in it; `None` leaves the work's alone.
    pub fn with_department_needs(&mut self, prod: Option<&crate::departments::Product>) {
        self.need_count = self.overview_needs(prod);
    }

    /// The checks badge from a [`crate::app_status::badges`] read; a failed one is named.
    pub fn with_checks(&mut self, read: &Result<HashMap<String, crate::releases::Badge>, String>) {
        if let Err(e) = read {
            self.errors.push(format!("app checks: {e}"));
        }
        self.checks = Some(crate::releases::check_badge(read, &self.project));
    }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct StageOut {
    stage: String,
    met: u32,
    total: u32,
    fail: u32,
    human: u32,
    todo: u32,
    requirements: Vec<Requirement>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SystemsOut {
    systems: Vec<Criteria>,
}

/// One system's criteria from `project-stage-check --systems`.
#[derive(Clone, Debug, Deserialize, Default)]
#[serde(default)]
pub struct Criteria {
    pub id: String,
    pub met: u32,
    pub total: u32,
}

/// The stage after `stage` on the ladder; None at the top or for a stage the ladder lacks.
pub fn next_on(ladder: &[String], stage: &str) -> Option<String> {
    let i = ladder.iter().position(|s| s == stage)?;
    ladder.get(i + 1).cloned()
}

/// The leaves-only weighted done share of `epics`, `done / (done + open)` by weight, rounded
/// down so 100 means nothing is left; None when none has a weight.
fn weighted<'a>(epics: impl IntoIterator<Item = &'a Epic>) -> Option<u32> {
    let (done, open) = epics
        .into_iter()
        .fold((0, 0), |(d, o), e| (d + e.done_weight, o + e.open_weight));
    crate::projects::share(done, done + open)
}

/// A system's standing epic, `epic(<system>): <system> to standard`, where upkeep that serves no
/// feature is linked (`lifecycle.md`, "What an epic is"); every other epic is a feature. Case
/// aside, as the writer (`notes-cli` `standing::find`) matches it.
pub fn is_standing(e: &Epic) -> bool {
    standing(&e.title, &e.system)
}

/// [`is_standing`] on an epic's title and system, for a reader holding no [`Epic`].
pub fn standing(title: &str, system: &str) -> bool {
    title
        .to_ascii_lowercase()
        .strip_suffix(" to standard")
        .is_some_and(|s| s.eq_ignore_ascii_case(system))
}

/// An epic's line on its system: title, percent, step, brief, plan phases, rows, PRs, ETA and track.
pub fn epic_line(e: &Epic, now: i64) -> String {
    let mut s = e.title.clone();
    if let Some(p) = weighted([e]) {
        s += &format!("  {p}%");
    }
    s += &format!("  [{}]", e.step);
    s += if e.brief.is_some() {
        "  brief yes"
    } else {
        "  brief no"
    };
    let (done, total) = e
        .plans
        .iter()
        .fold((0, 0), |(d, t), p| (d + p.done, t + p.total));
    if e.plans.is_empty() {
        s += "  plan no";
    } else {
        s += &format!("  plan {done} of {total}");
    }
    s += &format!("  rows {} of {}", e.done, e.done + e.open);
    if !e.prs.is_empty() {
        s += &format!("  PRs {}", e.prs.len());
    }
    if e.state == "open" {
        if let Some(eta) = &e.eta {
            if eta.p50 <= now {
                s += "  ETA overdue";
            } else {
                // Rounded up, so a finish later today is 1d, never 0d.
                let days = (eta.p50 - now + 86_399).div_euclid(86_400);
                s += &format!("  ETA {days}d");
            }
        }
    }
    if let Some(t) = &e.track {
        s += &format!("  {t}");
    }
    s
}

/// The stage group joins the work groups, then `need_count` is taken over all of them.
fn close_needs(p: &mut Page) {
    p.need_groups.extend(stage_group(p));
    p.need_count = need_count(&p.need_groups);
}

/// The items a set of Needs you groups lists.
pub fn need_count(groups: &[NeedGroup]) -> usize {
    groups.iter().map(|g| g.items.len()).sum()
}

/// What the chain asks of the human, by kind: the epics to verify once every row landed, then
/// the plans that name no epic. A kind with nothing is left out.
pub fn need_groups(c: &Chain) -> Vec<NeedGroup> {
    let verify: Vec<String> = c
        .epics
        .iter()
        .filter(|e| e.step == "landed")
        .map(|e| {
            format!(
                "verify: {} ({} of {} rows landed, no live proof)",
                e.title,
                e.done,
                e.done + e.open
            )
        })
        .collect();
    let plans: Vec<String> = c
        .unlinked
        .plans
        .iter()
        .map(|p| {
            format!(
                "plan with no epic: {}",
                crate::plans::named(&crate::plans::path(p))
            )
        })
        .collect();
    let mut out = vec![];
    if !verify.is_empty() {
        out.push(NeedGroup {
            kind: "verify".into(),
            says: format!(
                "{} landed with no live proof",
                crate::display::fmt::counted(verify.len(), "epic")
            ),
            items: verify,
        });
    }
    if !plans.is_empty() {
        out.push(NeedGroup {
            kind: "plan".into(),
            says: format!(
                "{} with no epic",
                crate::display::fmt::counted(plans.len(), "plan")
            ),
            items: plans,
        });
    }
    out
}

/// The next stage's checks that wait on a fix or the human, as one Needs you group; None when
/// none do or the stage was not read.
fn stage_group(p: &Page) -> Option<NeedGroup> {
    let g = p.gate.as_ref().filter(|g| g.fail + g.human > 0)?;
    Some(NeedGroup {
        kind: "stage".into(),
        says: format!(
            "{} {} {} failing, {} for a human",
            g.fail,
            g.stage,
            crate::display::fmt::noun(g.fail as usize, "check", "checks"),
            g.human
        ),
        items: p
            .next_rows
            .iter()
            .filter(|r| r.result == "FAIL" || r.result == "HUMAN")
            .map(|r| format!("{} {}", r.result, r.requirement))
            .collect(),
    })
}

/// The epics under their systems: every system the project's type has, in `systems.md` order,
/// then any system an epic names that the type lacks, then epics with none. `in_open` is the ids
/// of the epics closed in the open version, which count toward their system's percent.
pub fn systems(c: &Chain, criteria: &[Criteria], in_open: &[String], now: i64) -> Vec<System> {
    let mut by: BTreeMap<&str, Vec<&Epic>> = BTreeMap::new();
    for e in &c.epics {
        by.entry(e.system.as_str()).or_default().push(e);
    }
    let mut out: Vec<(System, String)> = criteria
        .iter()
        .map(|c| {
            let sys = System {
                id: c.id.clone(),
                criteria_met: Some(c.met),
                criteria_total: Some(c.total),
                ..Default::default()
            };
            (sys, format!("criteria {} of {}", c.met, c.total))
        })
        .collect();
    for sys in by.keys() {
        if !out.iter().any(|(s, _)| s.id == *sys) {
            let sys = System {
                id: sys.to_string(),
                ..Default::default()
            };
            out.push((sys, "no criteria".into()));
        }
    }
    out.into_iter()
        .map(|(mut s, criteria)| {
            let name = if s.id.is_empty() {
                "no system"
            } else {
                s.id.as_str()
            };
            let mut head = name.to_string();
            let es: &[&Epic] = by.get(s.id.as_str()).map_or(&[], |v| v.as_slice());
            // A system's progress counts its open epics and the ones closed in the open version,
            // never one number for the whole project.
            let counted: Vec<&Epic> = es
                .iter()
                .copied()
                .filter(|e| e.state == "open" || in_open.contains(&e.id))
                .collect();
            s.percent = weighted(counted.iter().copied());
            if let Some(p) = s.percent {
                head += &format!("  {p}%");
            }
            let features: Vec<&&Epic> = counted.iter().filter(|e| !is_standing(e)).collect();
            let standing = es
                .iter()
                .filter(|e| is_standing(e) && e.state == "open")
                .count();
            s.features = features.len();
            s.features_done = features.iter().filter(|e| e.state != "open").count();
            s.standing = standing;
            let mut parts = vec![];
            if !features.is_empty() {
                let done = s.features_done;
                let n = features.len();
                parts.push(format!(
                    "{}, {done} done",
                    crate::display::fmt::counted(n, "feature")
                ));
            }
            if standing > 0 {
                parts.push(format!(
                    "{standing} standard {}",
                    crate::display::fmt::noun(standing, "epic", "epics")
                ));
            }
            if !parts.is_empty() {
                head += &format!("  {}", parts.join(", "));
            }
            s.head = format!("{head}  {criteria}");
            s.epics = es
                .iter()
                .filter(|e| e.state == "open")
                .map(|e| EpicLine {
                    id: e.id.clone(),
                    line: epic_line(e, now),
                    behind: e.track.as_deref() == Some("behind"),
                })
                .collect();
            s.open_rows = es
                .iter()
                .filter(|e| e.state == "open")
                .map(|e| e.open)
                .sum();
            s.behind = s.epics.iter().filter(|e| e.behind).count();
            let mut open_features = es.iter().filter(|e| e.state == "open" && !is_standing(e));
            s.wave = open_features.next().map(|e| Wave {
                id: e.id.clone(),
                title: e.title.clone(),
                percent: weighted([*e]),
                more: open_features.count(),
            });
            let closed = es.iter().filter(|e| e.state != "open").count();
            if closed > 0 {
                let verified = es
                    .iter()
                    .filter(|e| e.state != "open" && e.verified)
                    .count();
                s.closed = format!("+{closed} closed, {verified} verified");
            }
            s
        })
        .collect()
}

/// The ids of the epics closed in the open version: the current entry of `--roadmap --json`.
pub fn closed_in_open(roadmap: &Value) -> Vec<String> {
    roadmap
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["state"] == "current")
        .flat_map(|r| r["closed_epics"].as_array().into_iter().flatten())
        .filter_map(|e| e["id"].as_str().map(String::from))
        .collect()
}

/// `--roadmap --json`'s shipped versions, newest first, each as its closes by kind.
pub fn shipped(roadmap: &Value) -> Vec<String> {
    let Some(rel) = roadmap.as_array() else {
        return vec![];
    };
    rel.iter()
        .filter(|r| r["state"] == "shipped")
        .map(|r| {
            let p = &r["progress"];
            let mut kinds: Vec<(String, u64)> = p["by_kind"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .map(|(k, v)| (k.clone(), v["done"].as_u64().unwrap_or(0)))
                        .filter(|(_, n)| *n > 0)
                        .collect()
                })
                .unwrap_or_default();
            kinds.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            let mut s = format!(
                "{}: {} rows closed",
                r["version"].as_str().unwrap_or("?"),
                p["done"].as_u64().unwrap_or(0)
            );
            if !kinds.is_empty() {
                let k: Vec<String> = kinds.iter().map(|(k, n)| format!("{k} {n}")).collect();
                s += &format!("; {}", k.join(", "));
            }
            s
        })
        .collect()
}

fn stage_line(o: &StageOut) -> String {
    format!(
        "{}  {} of {} met, {} failing, {} human, {} not checkable yet",
        o.stage, o.met, o.total, o.fail, o.human, o.todo
    )
}

/// Run `project-stage-check` and parse its JSON. Its exit is 1 when a row fails and the JSON is
/// still the answer; 2 is a usage error.
fn stage_json<T: serde::de::DeserializeOwned>(
    runner: &dyn Runner,
    argv: &[&str],
) -> Result<T, String> {
    let argv: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    match runner.output(&argv)? {
        (0 | 1, out) => serde_json::from_str(&out).map_err(|e| e.to_string()),
        (code, _) => Err(format!("{} exited {code}", argv.join(" "))),
    }
}

/// Read and join the page for one project at `stage`. `now` is epoch seconds, for ETAs. The
/// chain is a `fleet-bench epics` read over the whole fleet (its forecast places every queue
/// item), most of the page's time, so it runs beside the page's other reads.
pub fn read(runner: &(dyn Runner + Sync), name: &str, stage: &str, now: i64) -> Page {
    std::thread::scope(|s| {
        let chain = s.spawn(|| epics::chain(runner, name));
        read_with(runner, name, stage, now, move || {
            chain
                .join()
                .unwrap_or_else(|_| Err("fleet-bench epics: the read panicked".into()))
        })
    })
}

/// As `read`, with the chain from `chain`, called once the page's own reads are done: agent-web
/// hands it the project's chain from the one `fleet-bench epics` read the Deliverables share.
pub fn read_with(
    runner: &dyn Runner,
    name: &str,
    stage: &str,
    now: i64,
    chain: impl FnOnce() -> Result<Chain, String>,
) -> Page {
    let mut p = Page {
        project: name.to_string(),
        ..Default::default()
    };
    if !crate::projects::safe_name(name) {
        p.errors.push(format!("refusing project name {name:?}"));
        return p;
    }
    let criteria = match stage_json::<SystemsOut>(
        runner,
        &["project-stage-check", name, "--systems", "--json"],
    ) {
        Ok(o) => o.systems,
        Err(e) => {
            p.errors.push(format!("project-stage-check --systems: {e}"));
            vec![]
        }
    };
    let roadmap = match runner.run(&[
        "notes".into(),
        "projects".into(),
        "--roadmap".into(),
        name.into(),
        "--json".into(),
    ]) {
        Ok(o) => match serde_json::from_str::<Value>(&o) {
            Ok(v) => Some(v),
            Err(e) => {
                p.errors
                    .push(format!("notes projects --roadmap --json: {e}"));
                None
            }
        },
        Err(e) => {
            p.errors.push(format!("notes projects --roadmap: {e}"));
            None
        }
    };
    let ladder = match runner.run(&["notes".into(), "projects".into(), "--stages".into()]) {
        Ok(o) => o
            .lines()
            .next()
            .unwrap_or("")
            .split_whitespace()
            .map(String::from)
            .collect::<Vec<String>>(),
        Err(e) => {
            p.errors.push(format!("notes projects --stages: {e}"));
            vec![]
        }
    };
    // NO_NEXT only for the ladder's last stage: an unread ladder, or a stage it lacks, is unread.
    p.next_says = if ladder.iter().any(|s| s == stage) {
        NO_NEXT.into()
    } else {
        if !ladder.is_empty() {
            p.errors
                .push(format!("notes projects --stages: no stage {stage}"));
        }
        "next stage  not read".into()
    };
    if let Some(next) = next_on(&ladder, stage) {
        p.next_says = format!("{next}  not read");
        match stage_json::<StageOut>(
            runner,
            &["project-stage-check", name, "--stage", &next, "--json"],
        ) {
            Ok(o) => {
                p.next_says = stage_line(&o);
                p.gate = Some(Gate {
                    stage: o.stage.clone(),
                    met: o.met,
                    total: o.total,
                    fail: o.fail,
                    human: o.human,
                });
                p.next_rows = o
                    .requirements
                    .into_iter()
                    .filter(|r| r.result != "PASS")
                    .collect();
            }
            Err(e) => p
                .errors
                .push(format!("project-stage-check --stage {next}: {e}")),
        }
    }
    if let Some(v) = &roadmap {
        p.shipped = shipped(v);
    }
    // One release-state read serves the badge, the checks, the timeline and the Releases tab;
    // a failed read is said on the page and on the tab, a host with no snapshot on neither.
    let mut rel = crate::releases::read(runner, &[]);
    rel.errors.retain(|e| !crate::releases::unrefreshed(e));
    p.errors.extend(rel.errors.iter().cloned());
    let channels: Vec<_> = rel
        .rows
        .iter()
        .filter(|r| r.project == name)
        .cloned()
        .collect();
    p.releases = crate::releases::badge(&channels);
    p.release_tab = crate::project_releases::build(
        name,
        &rel,
        &crate::version_page::labs(project_map::cached().as_deref(), name, &[]),
        roadmap.as_ref(),
    );
    let sprints = crate::project_sprints::past(runner, name);
    p.sprint_past = sprints.map_err(|e| p.errors.push(e)).unwrap_or_default();
    p.alerts = crate::alerts::project_badge_here(name);
    if !channels.is_empty() {
        p.check_groups = crate::app_status::groups(name, &channels);
    }
    let (timeline, errors) = crate::timeline::read(runner, name, channels, now);
    p.timeline = timeline;
    p.errors.extend(errors);
    let chain = chain().map_err(|e| p.errors.push(e)).ok();
    if let Some(c) = &chain {
        p.flow_line = Some(epics::flow_line(&c.flow));
        p.need_groups = need_groups(c);
        p.build =
            crate::deliverables::build(std::slice::from_ref(c), *chrono::Local::now().offset());
        let in_open = roadmap.as_ref().map(closed_in_open).unwrap_or_default();
        p.systems = systems(c, &criteria, &in_open, now);
    }
    close_needs(&mut p);
    let open_epics: usize = p.systems.iter().map(|s| s.epics.len()).sum();
    p.systems_says = format!("{} systems, {open_epics} open epics", p.systems.len());
    if let Some(n) = chain
        .as_ref()
        .map(|c| c.unlinked.rows.len())
        .filter(|n| *n > 0)
    {
        p.systems_says += &format!(" ({n} rows with no epic)");
    }
    p.shipped_says = match p.shipped.len() {
        0 => "none yet".into(),
        1 => "1 version".into(),
        n => format!("{n} versions"),
    };
    p
}

/// The page for a name alone, as `hub projects --page` and agent-web read it: its stage from
/// `notes projects --stats --json`. A name no lab project has is an error, never an empty page.
pub fn named(runner: &(dyn Runner + Sync), name: &str, now: i64) -> Result<Page, String> {
    let s = stats_of(runner, name)?;
    Ok(read(runner, name, &s.stage, now))
}

/// As `named`, with the chain from `chain` (see `read_with`).
pub fn named_with(
    runner: &dyn Runner,
    name: &str,
    now: i64,
    chain: impl FnOnce() -> Result<Chain, String>,
) -> Result<Page, String> {
    let s = stats_of(runner, name)?;
    let mut p = read_with(runner, name, &s.stage, now, chain);
    for w in &mut p.sprint_past {
        w.link = Some(crate::sprint_page::link(&s.profile, name, &w.version));
    }
    Ok(p)
}

/// The `notes projects --stats --json` row of `name`; a name no lab project has is an error.
fn stats_of(runner: &dyn Runner, name: &str) -> Result<crate::projects::Stats, String> {
    crate::projects::stats(runner)?
        .into_iter()
        .find(|s| s.name == name)
        .ok_or_else(|| format!("notes projects lists no project {name}"))
}

/// A project's numbers as prose (`hub projects --status`), one sentence each: the project's
/// state ([`crate::projects::state`]), each system's
/// current wave and its percent, the systems with only upkeep open, the open version and its
/// release window, the next stage's gate and the playtests waiting. Every number is one this page or the
/// card already counts; only the words are here. The lab STATUS note carries none of them.
pub fn status_line(p: &Page, c: &Card, playtest_open: usize) -> String {
    let waves: Vec<String> = p
        .systems
        .iter()
        .filter_map(|s| {
            let w = s.wave.as_ref()?;
            let name = if s.id.is_empty() { "no system" } else { &s.id };
            let mut t = format!("{name} on \"{}\"", w.title);
            if let Some(pc) = w.percent {
                t += &format!(" {pc}%");
            }
            if w.more > 0 {
                t += &format!(" ({} more open)", w.more);
            }
            Some(t)
        })
        .collect();
    let mut out = vec![format!("State: {}.", c.state)];
    out.push(if waves.is_empty() {
        "Waves: none open.".to_string()
    } else {
        format!("Waves: {}.", waves.join("; "))
    });
    let upkeep = p
        .systems
        .iter()
        .filter(|s| s.wave.is_none() && !s.epics.is_empty())
        .count();
    if upkeep > 0 {
        out.push(format!(
            "Upkeep only: {}.",
            crate::display::fmt::counted(upkeep, "system")
        ));
    }
    out.push(match &c.version {
        None => "No open version.".to_string(),
        Some(v) if c.window.is_none() => format!("{v} has no window."),
        Some(v) => format!("{v} window: {}.", crate::projects::window_words(c)),
    });
    out.push(format!("On time: {}.", crate::projects::on_time_words(c)));
    if let Some(g) = &p.gate {
        out.push(format!(
            "Gate to {}: {} of {} met.",
            g.stage, g.met, g.total
        ));
    }
    out.push(format!("Playtests waiting: {playtest_open}."));
    out.join(" ")
}

/// `hub projects --status NAME`: one lab project's numbers as prose. A source the line
/// says (the chain, the next stage's check, the board feed) that could not be read is an error,
/// never a line that leaves it out.
pub fn status(runner: &(dyn Runner + Sync), name: &str, now: i64) -> Result<String, String> {
    status_in(runner, name, now, &crate::projects::fleet_state())
}

/// [`status`] over a given fleet state, which says which sessions are running.
fn status_in(
    runner: &(dyn Runner + Sync),
    name: &str,
    now: i64,
    fleet: &Value,
) -> Result<String, String> {
    let s = stats_of(runner, name)?;
    let p = read(runner, name, &s.stage, now);
    let next_unread = p.gate.is_none() && p.next_says != NO_NEXT;
    if p.flow_line.is_none() || next_unread {
        return Err(p.errors.join("; "));
    }
    let feed = crate::tasks::feed(runner)?;
    let playtest_open = feed
        .projects
        .iter()
        .find(|f| f.project == name && f.profile == s.profile)
        .map(|f| f.playtest_open)
        .ok_or_else(|| format!("notes board --json lists no project {name}"))?;
    // The state counts what is in flight, so the queue joins in the way the Projects tab joins
    // it (`projects::build`). The card is dated from the feed's day, as the rest of the line is,
    // not the clock `build` dates from, so only the in-flight counts are taken from the join.
    let queue =
        crate::queue::Queue::from_reads(crate::queue::list(runner, "all"), Ok(Default::default()));
    if !queue.errors.is_empty() {
        return Err(queue.errors.join("; "));
    }
    let at = chrono::DateTime::from_timestamp(now, 0).ok_or_else(|| format!("bad time {now}"))?;
    let today = crate::sheet_view::today_of(&feed);
    let mut card = Card::from_stats(&s, today);
    let joined = crate::projects::build(
        std::slice::from_ref(&s),
        Some(&feed),
        fleet,
        Some(&queue),
        at,
    );
    if let Some(j) = joined.cards.into_iter().next() {
        (card.running, card.waiting) = (j.running, j.waiting);
    }
    card.state = crate::projects::state(&card, today);
    Ok(status_line(&p, &card, playtest_open))
}

pub fn to_json(p: &Page) -> Value {
    serde_json::to_value(p).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Answers by the command's first two words; records every argv it was given.
    struct Fake {
        answers: Vec<(&'static str, i32, String)>,
        seen: Mutex<Vec<String>>,
    }
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            match self.output(argv)? {
                (0, o) => Ok(o),
                (c, _) => Err(format!("exit {c}")),
            }
        }
        fn output(&self, argv: &[String]) -> Result<(i32, String), String> {
            let line = argv.join(" ");
            self.seen.lock().unwrap().push(line.clone());
            self.answers
                .iter()
                .find(|(k, ..)| line.starts_with(k))
                .map(|(_, c, o)| (*c, o.clone()))
                .ok_or_else(|| format!("no answer for {line}"))
        }
    }

    const NOW: i64 = 1_794_000_000;

    fn chain_json() -> String {
        serde_json::json!({"projects": [{
            "project": "game", "profile": "lab", "repo": "game",
            "flow": {"ideas": 3, "briefs": 1, "plans": 1, "epics": 3, "rows": 5, "landed": 1, "verified": 1},
            "unlinked": {"rows": ["gm-7", "gm-15"], "plans": ["/p/a.md", "/p/b.md", "/p/c.md", "/p/d.md", "/p/e.md", "/p/f.md"]},
            "epics": [
                {"id": "gm-1", "title": "Menus", "system": "ui", "state": "open", "step": "rows", "open": 2, "done": 2,
                 "open_weight": 3, "done_weight": 1,
                 "brief": "/b.md", "plans": [{"file": "/p/m.md", "done": 1, "total": 3}], "prs": ["101"],
                 "rows": [{"id": "gm-3", "kind": "feat", "title": "Main menu", "size": "m", "state": "done", "prs": ["101"]},
                          {"id": "gm-4", "kind": "untyped", "title": "Pause menu", "size": "", "state": "open", "prs": []},
                          {"id": "gm-8", "kind": "fix", "title": "Back key", "size": "s", "state": "doing", "prs": []}],
                 "eta": {"p50": NOW + 3 * 86_400, "slow": NOW + 5 * 86_400, "basis": "queue"}, "track": "behind"},
                {"id": "gm-2", "title": "Saves", "system": "ui", "state": "open", "step": "landed", "open": 0, "done": 4,
                 "done_weight": 4, "prs": ["102", "103"]},
                {"id": "gm-6", "title": "ui to standard", "system": "ui", "state": "open", "step": "rows", "open": 1,
                 "open_weight": 2},
                {"id": "gm-5", "title": "Shipped", "system": "ui", "state": "closed", "step": "verified", "verified": true,
                 "done": 1, "done_weight": 2},
                {"id": "gm-10", "title": "Old", "system": "ui", "state": "closed", "step": "verified", "verified": true, "done": 9, "done_weight": 10},
                {"id": "gm-9", "title": "Odd", "system": "", "state": "open", "step": "epic",
                 "eta": {"p50": NOW - 60, "slow": NOW, "basis": "queue"}}
            ]}]})
        .to_string()
    }

    fn fake(stage_exit: i32) -> Fake {
        let systems =
            r#"{"systems":[{"id":"ui","met":5,"total":7},{"id":"ci","met":1,"total":2}]}"#;
        let stage = r#"{"stage":"beta","met":4,"total":12,"fail":1,"human":1,"todo":6,"requirements":[
            {"stage":"draft","result":"PASS","requirement":"a brief"},
            {"stage":"beta","result":"FAIL","requirement":"a soak test"}]}"#;
        let roadmap = r#"[{"version":"v0.2.0","state":"current","progress":{"done":3},"closed_epics":[{"id":"gm-5"}]},
            {"version":"v0.1.0","state":"shipped","progress":{"done":20,"by_kind":{"fix":{"done":7},"feat":{"done":9},"docs":{"done":4},"ci":{"done":0}}}}]"#;
        Fake {
            answers: vec![
                ("fleet-bench epics", 0, chain_json()),
                (
                    "project-stage-check game --systems",
                    stage_exit,
                    systems.into(),
                ),
                (
                    "notes projects --stages",
                    0,
                    "draft dev alpha beta prod\n".into(),
                ),
                (
                    "project-stage-check game --stage beta",
                    stage_exit,
                    stage.into(),
                ),
                ("notes projects --roadmap game", 0, roadmap.into()),
                (
                    "notes projects --sprints game",
                    0,
                    r#"[{"version":"v0.5.3","committed":5,"delivered":4,"line":"x"}]"#.into(),
                ),
                (
                    "release-state show --json",
                    0,
                    r#"{"rows":[{"project":"game","id":"game-prod","status":"drift"}]}"#.into(),
                ),
                (
                    "project-timeline --days 7 game",
                    0,
                    r#"{"tags":[{"tag":"v0.1.0","at":1794000000}]}"#.into(),
                ),
            ],
            seen: Mutex::new(vec![]),
        }
    }

    /// `fake(0)` whose release-state read dies with `error`.
    struct NoRelease(Fake, &'static str);
    impl Runner for NoRelease {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            if argv.join(" ").starts_with("release-state show") {
                return Err(self.1.into());
            }
            self.0.run(argv)
        }
        fn output(&self, argv: &[String]) -> Result<(i32, String), String> {
            self.0.output(argv)
        }
    }

    #[test]
    fn a_failed_release_read_is_said_on_the_page_and_the_tab_and_no_snapshot_on_neither() {
        let p = read(
            &NoRelease(fake(0), "exit 2: jq: error"),
            "game",
            "alpha",
            NOW,
        );
        let said = "release-state show: exit 2: jq: error";
        assert_eq!(p.errors, [said]);
        assert_eq!(p.release_tab.errors, [said]);
        // NEGATIVE CONTROL: a host where no refresh has run yet is not an error on either.
        let p = read(
            &NoRelease(fake(0), "no snapshot yet; run: release-state refresh"),
            "game",
            "alpha",
            NOW,
        );
        assert!(p.errors.is_empty(), "{:?}", p.errors);
        assert!(
            p.release_tab.errors.is_empty(),
            "{:?}",
            p.release_tab.errors
        );
        assert!(p.releases.is_none());
    }

    #[test]
    fn a_page_read_with_a_chain_in_hand_runs_no_fleet_bench_and_draws_the_same_page() {
        let f = fake(0);
        let whole = read(&f, "game", "alpha", NOW);
        let f = fake(0);
        let chains = epics::all(&f).unwrap();
        f.seen.lock().unwrap().clear();
        let given = read_with(&f, "game", "alpha", NOW, || epics::pick(&chains, "game"));
        assert!(!f
            .seen
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.starts_with("fleet-bench")));
        assert_eq!(given.flow_line, whole.flow_line);
        assert_eq!(given.systems_says, whole.systems_says);
        let none = read_with(&f, "game", "alpha", NOW, || epics::pick(&chains, "other"));
        assert!(none.flow_line.is_none());
        assert!(none
            .errors
            .iter()
            .any(|e| e == "fleet-bench epics lists no project other"));
        assert!(
            none.next_says != "next stage  not read",
            "the rest of the page still reads"
        );
    }

    #[test]
    fn the_page_joins_the_chain_the_stage_check_and_the_roadmap_into_the_mockup_lines() {
        let f = fake(0);
        let p = read(&f, "game", "alpha", NOW);
        assert!(p.errors.is_empty(), "{:?}", p.errors);
        assert_eq!(p.sprint_past.len(), 1, "the scored windows join the page");
        assert_eq!(
            p.flow_line.as_deref(),
            Some("ideas 3 | briefs 1 | plans 1 | epics 3 | rows 5 | landed 1 | verified 1")
        );
        // Grouped by kind with every item, the next stage's failing and human checks last.
        let groups: Vec<(&str, &str, usize)> = p
            .need_groups
            .iter()
            .map(|g| (g.kind.as_str(), g.says.as_str(), g.items.len()))
            .collect();
        assert_eq!(
            groups,
            vec![
                ("verify", "1 epic landed with no live proof", 1),
                ("plan", "6 plans with no epic", 6),
                ("stage", "1 beta check failing, 1 for a human", 1),
            ]
        );
        // The head's numbers as fields, so a table draws them without parsing the line.
        let ui = &p.systems[0];
        assert_eq!(
            (
                ui.criteria_met,
                ui.criteria_total,
                ui.features,
                ui.features_done,
                ui.standing
            ),
            (Some(5), Some(7), 3, 1, 1)
        );
        assert_eq!(
            (ui.open_rows, ui.behind),
            (3, 1),
            "Menus 2, Saves 0, standard 1; Menus behind"
        );
        let none = &p.systems[2];
        assert_eq!((none.criteria_met, none.criteria_total), (None, None));
        let heads: Vec<&str> = p.systems.iter().map(|s| s.head.as_str()).collect();
        assert_eq!(
            heads,
            vec![
                "ui  58%  3 features, 1 done, 1 standard epic  criteria 5 of 7",
                "ci  criteria 1 of 2",
                "no system  1 feature, 0 done  no criteria"
            ],
            "every system the type has, in its order, then epics with no system; a system with no \
             epic, or none with a weight, shows no percent, never 0%"
        );
        let ui = &p.systems[0];
        assert_eq!(
            ui.percent,
            Some(7 * 100 / 12),
            "open epics and the one closed in the open version, by weight; gm-10 closed earlier"
        );
        assert_eq!(p.systems[1].percent, None);
        assert_eq!(
            ui.epics.iter().map(|e| e.line.as_str()).collect::<Vec<_>>(),
            vec![
                "Menus  25%  [rows]  brief yes  plan 1 of 3  rows 2 of 4  PRs 1  ETA 3d  behind",
                "Saves  100%  [landed]  brief no  plan no  rows 4 of 4  PRs 2",
                "ui to standard  0%  [rows]  brief no  plan no  rows 0 of 1",
            ]
        );
        assert_eq!(
            ui.epics.iter().map(|e| e.behind).collect::<Vec<_>>(),
            vec![true, false, false]
        );
        assert_eq!(ui.closed, "+2 closed, 2 verified");
        assert_eq!(
            p.systems[2].epics[0].line, "Odd  [epic]  brief no  plan no  rows 0 of 0  ETA overdue",
            "an estimate already past says so, never 0d"
        );
        assert!(p.systems[1].epics.is_empty() && p.systems[1].closed.is_empty());
        assert_eq!(
            p.systems_says,
            "3 systems, 4 open epics (2 rows with no epic)"
        );
        assert_eq!(
            p.next_says,
            "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet"
        );
        assert_eq!(
            p.next_rows
                .iter()
                .map(|r| r.result.as_str())
                .collect::<Vec<_>>(),
            vec!["FAIL"],
            "a met requirement is not listed"
        );
        assert_eq!(
            p.shipped,
            vec!["v0.1.0: 20 rows closed; feat 9, fix 7, docs 4"]
        );
        assert_eq!(p.shipped_says, "1 version");
        assert_eq!(p.releases.unwrap().says, "drift; channels 1 drift");
        assert_eq!(p.timeline.unwrap().says, "7d: 1 tag");
    }

    #[test]
    fn a_standing_epic_is_its_system_to_standard_case_aside_as_the_writer_matches_it() {
        let e = |title: &str, system: &str| Epic {
            title: title.into(),
            system: system.into(),
            ..Default::default()
        };
        assert!(is_standing(&e("ui to standard", "ui")));
        assert!(is_standing(&e("UI to Standard", "ui")));
        // NEGATIVE CONTROL: another system's title, or a feature, is no standing epic.
        assert!(!is_standing(&e("look to standard", "ui")));
        assert!(!is_standing(&e("ui pause menu", "ui")));
    }

    #[test]
    fn a_failing_stage_check_still_gives_its_numbers_and_a_usage_error_is_named() {
        let p = read(&fake(1), "game", "alpha", NOW);
        assert!(
            p.errors.is_empty(),
            "exit 1 is a failing row, not a failed read"
        );
        assert!(p.next_says.starts_with("beta  4 of 12 met"));
        let p = read(&fake(2), "game", "alpha", NOW);
        assert_eq!(p.next_says, "beta  not read", "never the top stage's words");
        assert_eq!(p.systems.len(), 2);
        assert_eq!(p.errors.len(), 2, "{:?}", p.errors);
        assert!(p.errors.iter().all(|e| e.contains("exited 2")));
        assert!(
            p.flow_line.is_some(),
            "one failed source leaves the rest of the page"
        );
    }

    #[test]
    fn the_top_stage_has_no_next_and_an_unread_chain_is_an_error_not_an_empty_page() {
        let f = fake(0);
        let p = read(&f, "game", "prod", NOW);
        assert_eq!(p.next_says, "no stage after this one");
        assert!(!f
            .seen
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("--stage ")));
        let f = Fake {
            answers: vec![("notes projects --stages", 0, "draft dev\n".into())],
            seen: Mutex::new(vec![]),
        };
        let p = read(&f, "game", "draft", NOW);
        assert!(p.flow_line.is_none());
        assert!(
            p.errors.iter().any(|e| e.contains("fleet-bench")),
            "{:?}",
            p.errors
        );
    }

    #[test]
    fn a_name_alone_takes_its_stage_from_the_stats_and_an_unknown_one_is_an_error() {
        let mut f = fake(0);
        f.answers.insert(
            0,
            (
                "notes projects --stats",
                0,
                r#"[{"profile":"lab","name":"game","stage":"alpha"}]"#.into(),
            ),
        );
        let p = named(&f, "game", NOW).unwrap();
        assert!(p.next_says.starts_with("beta"), "{p:?}");
        let e = named(&f, "nosuch", NOW).unwrap_err();
        assert!(e.contains("no project nosuch"), "{e}");
    }

    #[test]
    fn each_system_s_wave_is_its_first_open_feature_epic_never_its_standing_one() {
        let p = read(&fake(0), "game", "alpha", NOW);
        let waves: Vec<Option<(&str, Option<u32>, usize)>> = p
            .systems
            .iter()
            .map(|s| s.wave.as_ref().map(|w| (w.id.as_str(), w.percent, w.more)))
            .collect();
        assert_eq!(
            waves,
            vec![Some(("gm-1", Some(25), 1)), None, Some(("gm-9", None, 0))],
            "ui's wave is Menus with Saves still open and its standing epic not counted; ci has \
             no epic; an epic with no weight has no percent, never 0%"
        );
        assert_eq!(
            p.gate,
            Some(Gate {
                stage: "beta".into(),
                met: 4,
                total: 12,
                fail: 1,
                human: 1
            })
        );
    }

    fn status_fake() -> Fake {
        let mut f = fake(0);
        f.answers.insert(
            0,
            (
                "notes projects --stats",
                0,
                r#"[{"profile":"lab","name":"game","stage":"alpha","version":"v0.2.0",
                    "progress":{"open":4,"done":6,"open_weight":4,"done_weight":6,"closed_weight_28d":28},
                    "target_version":"v0.2.0","target_on":"2026-11-12",
                    "target_work":{"open_weight":4,"closed_weight_28d":28,"filed_weight_28d":0},
                    "window":{"version":"v0.2.0","opened":"2026-11-05","due":"2026-11-12","committed":5,"delivered":2,"open":3,"dropped":0,"interrupted":0}}]"#
                    .into(),
            ),
        );
        f.answers.push((
            "notes board --json",
            0,
            r#"{"today":"2026-11-09","projects":[
                {"profile":"other","project":"game","playtest_open":9},
                {"profile":"lab","project":"game","playtest_open":3}]}"#
                .into(),
        ));
        f.answers.push(("agent-queue list", 0, "[]".into()));
        f
    }

    #[test]
    fn the_status_line_says_every_number_the_readers_counted_and_nothing_else() {
        let line = status_in(&status_fake(), "game", NOW, &Value::Null).unwrap();
        assert_eq!(
            line,
            "State: at risk. Waves: ui on \"Menus\" 25% (1 more open); no system on \"Odd\". v0.2.0 window: 2/5 \
             rows, due 11-12 (3 days left). On time: target v0.2.0 by 11-12: late 1 day (ETA \
             ~11-13). Gate to beta: 4 of 12 met. Playtests waiting: 3.",
            "the playtests are this profile's, the window's days are counted from the feed's day, \
             and no close in 28 days cannot close the 3 rows open in 3 days"
        );
        assert!(line.is_ascii() && !line.contains("  "), "{line}");
    }

    #[test]
    fn upkeep_only_systems_are_a_count_and_a_version_with_no_window_says_so() {
        let sys = |id: &str, wave: Option<Wave>, epics: usize| System {
            id: id.into(),
            wave,
            epics: vec![EpicLine::default(); epics],
            ..Default::default()
        };
        let p = Page {
            systems: vec![sys("ci", None, 1), sys("docs", None, 2), sys("ui", None, 0)],
            ..Default::default()
        };
        let mut c = Card {
            version: Some("v0.1.0".into()),
            state: crate::projects::IDLE,
            ..Default::default()
        };
        assert_eq!(
            status_line(&p, &c, 0),
            "State: idle. Waves: none open. Upkeep only: 2 systems. v0.1.0 has no window. On time: no \
             target. Playtests waiting: 0.",
            "a system with no open epic is neither a wave nor upkeep; the top stage has no gate"
        );
        c.window = Some(crate::projects::Window {
            due: Some("2026-11-09".into()),
            committed: 4,
            delivered: 4,
            days_left: Some(0),
            ..Default::default()
        });
        assert!(
            status_line(&p, &c, 0).contains(" v0.1.0 window: 4/4 rows, due 11-09 (due today). ")
        );
        c.version = None;
        assert!(status_line(&p, &c, 0).contains(" No open version. "));
    }

    #[test]
    fn a_status_whose_sources_failed_is_an_error_not_a_line_that_leaves_them_out() {
        let mut f = status_fake();
        f.answers.retain(|(k, ..)| !k.starts_with("fleet-bench"));
        let e = status_in(&f, "game", NOW, &Value::Null).unwrap_err();
        assert!(e.contains("fleet-bench"), "{e}");
        let mut f = status_fake();
        f.answers
            .retain(|(k, ..)| !k.starts_with("project-stage-check game --stage"));
        assert!(
            status_in(&f, "game", NOW, &Value::Null).is_err(),
            "an unread gate"
        );
        for ladder in [None, Some("draft dev\n")] {
            let mut f = status_fake();
            f.answers.retain(|(k, ..)| *k != "notes projects --stages");
            if let Some(l) = ladder {
                f.answers.push(("notes projects --stages", 0, l.into()));
            }
            let e = status_in(&f, "game", NOW, &Value::Null).unwrap_err();
            assert!(
                e.contains("--stages"),
                "an unread ladder is no top stage: {e}"
            );
        }
        let mut f = status_fake();
        f.answers.retain(|(k, ..)| !k.starts_with("notes board"));
        assert!(
            status_in(&f, "game", NOW, &Value::Null).is_err(),
            "an unread feed"
        );
        let mut f = status_fake();
        f.answers.retain(|(k, ..)| *k != "agent-queue list");
        let e = status_in(&f, "game", NOW, &Value::Null).unwrap_err();
        assert!(
            e.contains("agent-queue"),
            "an unread queue is no in-flight count: {e}"
        );
        // NEGATIVE CONTROL: a source the line does not say (the timeline) failing still gives it.
        let mut f = status_fake();
        f.answers
            .retain(|(k, ..)| !k.starts_with("project-timeline"));
        assert!(status_in(&f, "game", NOW, &Value::Null).is_ok());
        assert!(status(&status_fake(), "nosuch", NOW).is_err());
    }

    #[test]
    fn a_name_that_could_be_a_flag_runs_nothing() {
        let f = fake(0);
        let p = read(&f, "--all", "alpha", NOW);
        assert!(f.seen.lock().unwrap().is_empty());
        assert_eq!(p.errors.len(), 1);
    }

    #[test]
    fn an_app_page_carries_its_groups_and_its_checks_badge_names_a_failed_read() {
        let mut p = read(&fake(0), "game", "alpha", NOW);
        assert_eq!(p.check_groups, ["game"]);
        assert_eq!(
            p.checks, None,
            "the page read itself never reads VictoriaMetrics"
        );
        p.with_checks(&Ok(HashMap::new()));
        assert_eq!(p.checks.as_ref().unwrap().says, "no check");
        p.with_checks(&Err("vm: refused".into()));
        assert_eq!(p.checks.unwrap().says, "not read");
        assert_eq!(p.errors.last().unwrap(), "app checks: vm: refused");
    }
}
