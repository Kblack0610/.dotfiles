//! One version of a project (docs/dashboards.md, "Version page"), the way a tracker's release
//! page reads: a header with its status, its cut and its window days, a bar of its rows by state,
//! every row aimed at it with its state, who works it and its PRs, then each app's cut of the
//! version drawn as that app's release page (`release_page`), every cut listed under it.
//!
//! The rows are the notes release view (`notes board --json --version`): every row whose
//! `#version/` names it, both lanes, open and closed. The cuts are the history of each app the
//! project owns (`releases::App::owner`), so `unity-core-playground` 0.5.3 holds its own `v0.5.3`
//! and `v0.5.3-dodginballs5`. Who works a row is the queue item whose `row` names it; who fixes a
//! red cut is the owner of its red runs (`builds::Run::owner`).
//!
//! Nothing here reads but [`read`], which both surfaces call: agent-web's
//! `/api/releases/version` and the hub TUI's Releases pane.

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::builds::{Run, RunKey};
use crate::links::{Kind, Link};
use crate::queue::{Item, State};
use crate::release_graph::{self, pr_ref, repo_key, Pr, Shipment};
use crate::release_page::{self, core, cuts_of, runs_of, worst};
use crate::releases::{App, Level, Releases};
use crate::run_detail::Record;
use crate::session_actions::Runner;

/// The version page's link: `#releases/versions/<project>/<version>`.
pub fn link(project: &str, version: &str) -> Link {
    Link::to(Kind::Version, format!("{project}/{}", core(version)))
}

/// The notes release view as `notes board --json --version` prints it.
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
pub struct Feed {
    #[serde(default)]
    pub projects: Vec<FeedProject>,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
pub struct FeedProject {
    pub project: String,
    pub opened: Option<String>,
    pub due: Option<String>,
    #[serde(default)]
    pub rows: Vec<FeedRow>,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
pub struct FeedRow {
    pub id: Option<String>,
    pub text: String,
    /// `open`, `doing`, `done` or `dropped`.
    pub state: String,
    pub priority: String,
    #[serde(default)]
    pub prs: Vec<String>,
}

/// The apps whose cuts are the project's: every app it owns, its own app first.
pub fn owned<'a>(rel: &'a Releases, project: &str) -> Vec<&'a App> {
    let mut apps: Vec<&App> = rel.apps.iter().filter(|a| a.owner() == project).collect();
    apps.sort_by_key(|a| (a.project != project, a.project.clone()));
    apps
}

/// The lab projects the rows are filed under (`project_map::Registry::lab_names`): the
/// project's own first, then each owned app's, once each. With no registry a name is itself.
pub fn labs(reg: Option<&project_map::Registry>, project: &str, apps: &[&App]) -> Vec<String> {
    let names = |n: &str| reg.map_or_else(|| vec![n.to_string()], |r| r.lab_names(n));
    let mut out: Vec<String> = vec![];
    for n in std::iter::once(project)
        .chain(apps.iter().map(|a| a.project.as_str()))
        .flat_map(names)
    {
        if !out.contains(&n) {
            out.push(n);
        }
    }
    out
}

/// What reads the rows: notes' release view of `version` over the lab projects `labs` (one with
/// no rows prints nothing). None for a version notes cannot tag (`#vX.Y.Z` only), which no row
/// can be aimed at.
pub fn feed_argv(labs: &[String], version: &str) -> Option<Vec<String>> {
    let v = core(version);
    let parts: Vec<&str> = v.split('.').collect();
    let numeric = |p: &&str| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
    if parts.len() != 3 || !parts.iter().all(numeric) {
        return None;
    }
    let mut argv: Vec<String> = ["notes", "board", "--json", "--version"]
        .map(String::from)
        .into();
    argv.push(format!("v{v}"));
    for l in labs {
        argv.extend(["--project".to_string(), l.clone()]);
    }
    Some(argv)
}

pub fn parse_feed(json: &str) -> Result<Feed, String> {
    serde_json::from_str(json).map_err(|e| format!("notes board --version: {e}"))
}

/// The run ids every app's cuts of `version` can draw: what the caller reads from the archive.
pub fn run_keys(apps: &[&App], runs: &[Run], version: &str) -> Vec<RunKey> {
    apps.iter()
        .flat_map(|a| release_page::run_keys(a, runs, version))
        .collect()
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct PrCell {
    /// `#12` for the project's repo, else `owner/repo#12`.
    pub text: String,
    /// `open`, `merged`, `closed`, or empty for a PR the store does not hold.
    pub state: String,
    pub url: String,
}

/// One row aimed at the version.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Row {
    pub id: String,
    pub title: String,
    pub priority: String,
    /// `doing`, `open`, `done` or `dropped`.
    pub state: String,
    pub level: Level,
    /// Who works it: the live item's tmux session, else its slug; empty when no item names it.
    pub assignee: String,
    /// That item's state word (`running`, `review`, `done`).
    pub assignee_state: String,
    pub assignee_href: String,
    pub prs: Vec<PrCell>,
    /// The row on the board.
    pub href: String,
}

/// The rows by state, as the bar draws them.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Bar {
    pub done: usize,
    pub doing: usize,
    pub open: usize,
    pub dropped: usize,
}

/// One app's cut of the version: how its shown cut went, who fixes it when red, and its
/// release page (None when the app has no cut of the version).
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct AppRelease {
    pub app: String,
    /// The worst of its shown cut's runs (`release_page::worst`), or `no cut`.
    pub state: String,
    pub level: Level,
    pub tag: String,
    pub reached_text: String,
    /// The owners of its red runs, joined; empty when none is red or none is owned.
    pub fixing: String,
    pub href: String,
    pub page: Option<release_page::Page>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Page {
    pub project: String,
    pub version: String,
    /// `released` (a cut reached a channel), `cut` (tagged, nowhere yet), `unreleased` (no tag)
    /// or `legacy` (every cut predates the project's line).
    pub status: String,
    pub level: Level,
    /// The newest cut: `v0.5.3-dodginballs5 11-19 14:02`, or `no cut`.
    pub cut_text: String,
    pub opened_text: String,
    pub due_text: String,
    pub bar: Bar,
    /// Rows by state: doing, open, done, dropped.
    pub rows: Vec<Row>,
    /// Why no row is listed: none is aimed at it, or the rows did not read.
    pub rows_note: String,
    pub apps: Vec<AppRelease>,
    pub errors: Vec<String>,
    pub project_href: String,
}

fn state_rank(s: &str) -> usize {
    ["doing", "open", "done", "dropped"]
        .iter()
        .position(|x| *x == s)
        .unwrap_or(4)
}

fn state_word(s: State) -> &'static str {
    match s {
        State::Waiting => "waiting",
        State::Running => "running",
        State::Review => "review",
        State::Queued => "queued",
        State::Done => "done",
    }
}

/// The item that works row `id` of lab project `project`: a live one before a queued one before
/// a done one.
fn worker<'a>(items: &'a [Item], project: &str, id: &str) -> Option<&'a Item> {
    let rank = |s: State| match s {
        State::Running | State::Waiting => 0,
        State::Review => 1,
        State::Queued => 2,
        State::Done => 3,
    };
    items
        .iter()
        .filter(|i| {
            i.board_row()
                .is_some_and(|(p, r)| r == id && p.eq_ignore_ascii_case(project))
        })
        .min_by_key(|i| rank(i.state))
}

/// One PR ref as a cell, joined to the store: a bare number is the project's repo's.
fn pr_cell(r: &str, home: &str, prs: &[Pr]) -> Option<PrCell> {
    let (repo, n) = pr_ref(r)?;
    let repo = repo.unwrap_or_else(|| home.to_string());
    let hit = prs
        .iter()
        .find(|p| p.number == n && repo_key(&p.repo) == repo);
    Some(PrCell {
        text: if repo == home || repo.is_empty() {
            format!("#{n}")
        } else {
            format!("{repo}#{n}")
        },
        state: hit.map(|p| p.state.to_lowercase()).unwrap_or_default(),
        url: hit.map(|p| p.url.clone()).unwrap_or_default(),
    })
}

fn row(r: &FeedRow, project: &str, items: &[Item], home: &str, prs: &[Pr]) -> Row {
    let id = r.id.clone().unwrap_or_default();
    let item = (!id.is_empty())
        .then(|| worker(items, project, &id))
        .flatten();
    let mut refs: Vec<&str> = r.prs.iter().map(String::as_str).collect();
    refs.extend(item.into_iter().flat_map(Item::pr_refs));
    let mut cells: Vec<PrCell> = vec![];
    for c in refs.into_iter().filter_map(|x| pr_cell(x, home, prs)) {
        if !cells.iter().any(|x| x.text == c.text) {
            cells.push(c);
        }
    }
    let live = item.is_some_and(|i| matches!(i.state, State::Running | State::Waiting));
    let assignee = item.map_or_else(String::new, |i| match (&i.session, live) {
        (Some(s), true) => crate::home::tmux_name(s).to_string(),
        _ => i.slug.clone(),
    });
    Row {
        href: if id.is_empty() {
            String::new()
        } else {
            Link::to(Kind::Row, id.clone()).href()
        },
        id,
        title: r.text.clone(),
        priority: r.priority.clone(),
        level: match r.state.as_str() {
            "done" | "doing" => Level::Ok,
            _ => Level::Neutral,
        },
        state: r.state.clone(),
        assignee,
        assignee_state: item.map_or("", |i| state_word(i.state)).to_string(),
        assignee_href: item.map_or_else(String::new, |i| Link::to(Kind::Queue, &i.slug).href()),
        prs: cells,
    }
}

fn app_release(
    a: &App,
    runs: &[Run],
    records: &HashMap<RunKey, Record>,
    version: &str,
) -> AppRelease {
    let page = release_page::build(a, runs, records, version);
    let Some(p) = page else {
        return AppRelease {
            app: a.project.clone(),
            state: "no cut".into(),
            level: Level::Neutral,
            ..Default::default()
        };
    };
    let rs = runs_of(runs, &a.project, &p.tag);
    let (state, level) = worst(&rs);
    let mut fixing: Vec<&str> = vec![];
    for r in rs
        .iter()
        .filter(|r| r.state == "red" && !r.owner.is_empty())
    {
        if !fixing.contains(&r.owner.as_str()) {
            fixing.push(&r.owner);
        }
    }
    let shown = a.history.iter().find(|s| s.tag == p.tag);
    AppRelease {
        app: a.project.clone(),
        state,
        level,
        tag: p.tag.clone(),
        reached_text: shown.map(|s| s.reached_text.clone()).unwrap_or_default(),
        fixing: fixing.join(", "),
        href: release_page::link(&a.project, &p.version).href(),
        page: Some(p),
    }
}

/// What a version is, the one rule the version page and a project's Releases tab
/// (`project_releases`) both say.
pub struct Verdict {
    /// `legacy`, `released` (a cut reached a channel), `cut` (tagged, nowhere yet) or
    /// `unreleased` (no tag).
    pub status: &'static str,
    /// Grey when legacy; amber once its due day passed with nothing released, or when a cut of
    /// it went outside the release flow.
    pub level: Level,
    pub legacy: bool,
    pub outside: bool,
}

/// The verdict on a version from its lab version's release-state mark (docs/operations/
/// release-state.md, Provenance) when there is one, else its cuts' marks. With neither (the open
/// version before its first cut) it is legacy only when no app of the project has a line.
pub fn verdict(mark: Option<&str>, cuts: &[&Shipment], lined: bool, overdue: bool) -> Verdict {
    let legacy = match (mark, cuts.is_empty()) {
        (Some(m), _) => release_graph::legacy(m),
        (None, false) => cuts.iter().all(|s| release_graph::legacy(&s.provenance)),
        (None, true) => !lined,
    };
    let outside =
        !legacy && (mark == Some("outside") || cuts.iter().any(|s| s.provenance == "outside"));
    let released = cuts.iter().any(|s| !s.reached.is_empty());
    let (status, level) = if legacy {
        ("legacy", Level::Neutral)
    } else if released {
        ("released", Level::Ok)
    } else if !cuts.is_empty() {
        ("cut", if overdue { Level::Warn } else { Level::Ok })
    } else if overdue {
        ("unreleased", Level::Warn)
    } else {
        ("unreleased", Level::Neutral)
    };
    Verdict {
        status,
        level: if outside {
            level.min(Level::Warn)
        } else {
            level
        },
        legacy,
        outside,
    }
}

/// The newest cut and its day, `v0.5.3-dodginballs5 11-19 14:02`, or `no cut`.
pub fn cut_text(cuts: &[&Shipment]) -> String {
    cuts.iter().max_by_key(|s| s.at).map_or_else(
        || "no cut".into(),
        |s| format!("{} {}", s.tag, s.at_text).trim().to_string(),
    )
}

/// The inputs [`build`] joins, each read by the caller.
pub struct Inputs<'a> {
    pub apps: &'a [&'a App],
    /// The project's own lab projects ([`labs`] with no apps): whose window the header shows.
    pub own: &'a [String],
    pub runs: &'a [Run],
    pub records: &'a HashMap<RunKey, Record>,
    pub feed: Result<Feed, String>,
    pub items: &'a [Item],
    pub prs: &'a [Pr],
}

/// `version` of `project` as its page, or None when nothing names it: no app of the project has
/// a cut of it and no row is aimed at it. `today` (`YYYY-MM-DD`) says whether its due day passed.
pub fn build(project: &str, version: &str, today: &str, i: Inputs) -> Option<Page> {
    let want = core(version).to_string();
    let mut errors = vec![];
    let feed = i.feed.unwrap_or_else(|e| {
        errors.push(e);
        Feed::default()
    });
    let home = i
        .apps
        .iter()
        .find(|a| !a.repo.is_empty())
        .map(|a| repo_key(&a.repo))
        .unwrap_or_default();
    let mut rows: Vec<Row> = feed
        .projects
        .iter()
        .flat_map(|p| p.rows.iter().map(move |r| (p.project.as_str(), r)))
        .map(|(p, r)| row(r, p, i.items, &home, i.prs))
        .collect();
    rows.sort_by_key(|r| state_rank(&r.state));
    let cuts: Vec<_> = i.apps.iter().flat_map(|a| cuts_of(a, &want).1).collect();
    if cuts.is_empty() && rows.is_empty() {
        return None;
    }
    let apps: Vec<AppRelease> = i
        .apps
        .iter()
        .map(|a| app_release(a, i.runs, i.records, &want))
        .collect();
    let mut bar = Bar::default();
    for r in &rows {
        match r.state.as_str() {
            "done" => bar.done += 1,
            "doing" => bar.doing += 1,
            "dropped" => bar.dropped += 1,
            _ => bar.open += 1,
        }
    }
    let window = i.own.iter().find_map(|l| {
        feed.projects
            .iter()
            .find(|p| p.project.eq_ignore_ascii_case(l))
    });
    let opened = window.and_then(|w| w.opened.clone()).unwrap_or_default();
    let due = window.and_then(|w| w.due.clone()).unwrap_or_default();
    let overdue = !due.is_empty() && due.as_str() < today;
    // A version with no cut is the project's open one, never legacy here: it has rows.
    let v = verdict(None, &cuts, true, overdue);
    let mut level = v.level;
    if !v.legacy && apps.iter().any(|a| a.level == Level::Bad) {
        level = Level::Bad;
    }
    Some(Page {
        project: project.to_string(),
        version: want,
        status: v.status.into(),
        level,
        cut_text: cut_text(&cuts),
        opened_text: if opened.is_empty() {
            "not opened".into()
        } else {
            opened
        },
        due_text: if due.is_empty() {
            "no due day".into()
        } else {
            due
        },
        bar,
        rows_note: if !rows.is_empty() {
            String::new()
        } else if errors.is_empty() {
            "no row names this version (#version/)".into()
        } else {
            "the rows did not read".into()
        },
        rows,
        apps,
        errors,
        project_href: Link::to(Kind::Project, project).href(),
    })
}

/// Read and build the page: the rows from notes, the PR store, and the job archive at `jobs`
/// for the runs every cut started. `rel` and `runs` are the caller's current reads.
pub fn read(
    runner: &dyn Runner,
    rel: &Releases,
    runs: &[Run],
    items: &[Item],
    jobs: &Path,
    project: &str,
    version: &str,
) -> Option<Page> {
    let apps = owned(rel, project);
    let reg = project_map::cached();
    let own = labs(reg.as_deref(), project, &[]);
    let feed = match feed_argv(&labs(reg.as_deref(), project, &apps), version) {
        Some(argv) => runner.run(&argv).and_then(|j| parse_feed(&j)),
        None => Ok(Feed::default()),
    };
    let records = release_page::records(jobs, &run_keys(&apps, runs, version));
    let (prs, pr_errors) = crate::release_graph::read_prs(&crate::release_graph::prs_dir());
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let mut page = build(
        project,
        version,
        &today,
        Inputs {
            apps: &apps,
            own: &own,
            runs,
            records: &records,
            feed,
            items,
            prs: &prs,
        },
    )?;
    page.errors.extend(pr_errors);
    Some(page)
}

/// The page as text, for the hub TUI: the header and bar, the rows, then each app's cut.
pub fn lines(p: &Page) -> Vec<String> {
    let mut out = vec![
        format!(
            "Version {} {}: {}, {}",
            p.project, p.version, p.status, p.cut_text
        ),
        format!(
            "  opened {}  due {}  rows: {} done, {} doing, {} open, {} dropped",
            p.opened_text, p.due_text, p.bar.done, p.bar.doing, p.bar.open, p.bar.dropped
        ),
    ];
    if !p.rows_note.is_empty() {
        out.push(format!("  {}", p.rows_note));
    }
    for r in &p.rows {
        let who = if r.assignee.is_empty() {
            "-".to_string()
        } else {
            format!("{} {}", r.assignee, r.assignee_state)
        };
        let prs: Vec<String> = r
            .prs
            .iter()
            .map(|c| format!("{} {}", c.text, c.state).trim().to_string())
            .collect();
        out.push(format!(
            "    {}  {}  {}  {}  {}",
            r.id,
            r.state,
            who,
            if prs.is_empty() {
                "-".into()
            } else {
                prs.join(", ")
            },
            r.title
        ));
    }
    for a in &p.apps {
        let fixing = if a.fixing.is_empty() {
            String::new()
        } else {
            format!(", fixing: {}", a.fixing)
        };
        out.push(format!("  {} {} {}{fixing}", a.app, a.tag, a.state));
        if !a.reached_text.is_empty() {
            out.push(format!("    reached {}", a.reached_text));
        }
    }
    for e in &p.errors {
        out.push(format!("  {e}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::release_graph::{Reached, RunRelease};

    fn ship(tag: &str, version: &str, at: i64, reached: bool) -> Shipment {
        Shipment {
            tag: tag.into(),
            version: version.into(),
            at: Some(at),
            at_text: format!("t{at}"),
            reached: if reached {
                vec![Reached {
                    id: "steam".into(),
                    how: "deploy".into(),
                    at: None,
                    ..Default::default()
                }]
            } else {
                vec![]
            },
            provenance: "flow".into(),
            ..Default::default()
        }
    }

    fn app(name: &str, repo: &str, history: Vec<Shipment>) -> App {
        App {
            project: name.into(),
            repo: repo.into(),
            history,
            ..Default::default()
        }
    }

    fn red_run(project: &str, tag: &str, owner: &str) -> Run {
        Run {
            forge: "github".into(),
            repo: "o/ucp".into(),
            id: 7,
            attempt: 1,
            workflow: "Build".into(),
            title: "Build".into(),
            event: "push".into(),
            state: "red".into(),
            level: Level::Bad,
            owner: owner.into(),
            release: Some(RunRelease {
                project: project.into(),
                tag: tag.into(),
            }),
            ..Default::default()
        }
    }

    fn feed() -> Feed {
        parse_feed(
            r##"{"version":"v0.5.3","projects":[{"project":"ucp","opened":"2026-11-18","due":"2026-11-19","rows":[
            {"id":"ucp-1","text":"ship menu","state":"done","priority":"high","prs":["#12"]},
            {"id":"ucp-2","text":"fix lag","state":"open","priority":"med","prs":[]},
            {"id":"ucp-3","text":"wip","state":"doing","priority":"low","prs":[]}]}]}"##,
        )
        .unwrap()
    }

    fn item(slug: &str, row: &str, state: State, session: Option<&str>, pr: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            row: Some(row.into()),
            state,
            session: session.map(String::from),
            pr: pr.map(String::from),
            ..Default::default()
        }
    }

    fn page(
        apps: &[&App],
        runs: &[Run],
        f: Result<Feed, String>,
        items: &[Item],
        prs: &[Pr],
    ) -> Option<Page> {
        build(
            "ucp",
            "0.5.3",
            "2026-11-20",
            Inputs {
                apps,
                runs,
                records: &HashMap::new(),
                feed: f,
                items,
                prs,
                own: &["ucp".to_string()],
            },
        )
    }

    #[test]
    fn the_verdict_greys_legacy_and_ambers_an_outside_cut_whatever_reached() {
        let flow = ship("v1.0.0-a1", "1.0.0", 5, true);
        let mut out = ship("v1.0.0-a2", "1.0.0", 6, true);
        out.provenance = "outside".into();
        let v = verdict(None, &[&flow], true, false);
        assert_eq!(
            (v.status, v.level, v.legacy, v.outside),
            ("released", Level::Ok, false, false)
        );
        let v = verdict(None, &[&flow, &out], true, false);
        assert_eq!(
            (v.status, v.level, v.outside),
            ("released", Level::Warn, true)
        );
        // A lab mark wins over the cuts', and legacy is never outside.
        let v = verdict(Some("legacy"), &[&out], true, false);
        assert_eq!(
            (v.status, v.level, v.outside),
            ("legacy", Level::Neutral, false)
        );
        // NEGATIVE CONTROL: with no mark and no cut, only a project with no line is legacy.
        assert!(!verdict(None, &[], true, true).legacy);
        assert!(verdict(None, &[], false, true).legacy);
        assert_eq!(cut_text(&[&flow, &out]), "v1.0.0-a2 t6");
        assert_eq!(cut_text(&[]), "no cut");
    }

    #[test]
    fn the_link_is_the_project_and_the_core_version_under_versions() {
        assert_eq!(
            link("ucp", "v0.5.3-dodginballs5").href(),
            "#releases/versions/ucp%2F0.5.3"
        );
        assert_eq!(
            link("ucp", "0.5.3").tab_args(),
            Some(("releases", "versions/ucp/0.5.3".into()))
        );
    }

    #[test]
    fn feed_argv_names_each_lab_once_and_skips_a_version_notes_cannot_tag() {
        let own = app("ucp", "o/ucp", vec![]);
        let dodge = app("dodginballs", "o/ucp", vec![]);
        let l = labs(None, "ucp", &[&own, &dodge]);
        assert_eq!(l, ["ucp", "dodginballs"]);
        assert_eq!(
            feed_argv(&l, "v0.5.3-dodginballs5").unwrap(),
            [
                "notes",
                "board",
                "--json",
                "--version",
                "v0.5.3",
                "--project",
                "ucp",
                "--project",
                "dodginballs"
            ]
        );
        assert_eq!(feed_argv(&l, "2"), None);
        assert_eq!(feed_argv(&l, "0.5"), None);
        assert_eq!(feed_argv(&l, "0.x.3"), None);
    }

    #[test]
    fn labs_are_the_lab_names_the_registry_files_under_each_repo() {
        let r = project_map::Registry::parse(
            r#"{"trackers":{"dot":{},"cockpit":{"repo":"dot"},"else":{"repo":"x"}}}"#,
        )
        .unwrap();
        assert_eq!(labs(Some(&r), "dot", &[]), ["dot", "cockpit"]);
    }

    #[test]
    fn rows_carry_state_assignee_and_prs_and_the_bar_counts_them() {
        let own = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let items = [
            item("ar-9", "ucp:ucp-2", State::Done, None, None),
            item(
                "ar-10",
                "ucp:ucp-2",
                State::Running,
                Some("agent:agent-28"),
                Some("o/ucp#14"),
            ),
            // A row id that only ends the same must not match.
            item(
                "ar-11",
                "ucp:xucp-3",
                State::Running,
                Some("agent-29"),
                None,
            ),
            // Nor the same id on another project's board.
            item(
                "ar-12",
                "other:ucp-3",
                State::Running,
                Some("agent-30"),
                None,
            ),
        ];
        let prs = [Pr {
            repo: "o/ucp".into(),
            number: 12,
            state: "MERGED".into(),
            url: "https://github.com/o/ucp/pull/12".into(),
            ..Default::default()
        }];
        let p = page(&[&own], &[], Ok(feed()), &items, &prs).unwrap();
        assert_eq!(
            p.bar,
            Bar {
                done: 1,
                doing: 1,
                open: 1,
                dropped: 0
            }
        );
        let ids: Vec<&str> = p.rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["ucp-3", "ucp-2", "ucp-1"]);
        let fix = &p.rows[1];
        assert_eq!(
            (fix.assignee.as_str(), fix.assignee_state.as_str()),
            ("agent-28", "running")
        );
        assert_eq!(fix.assignee_href, "#queue/ar-10");
        assert_eq!(fix.prs[0].text, "#14");
        assert_eq!(fix.prs[0].state, "", "a PR the store lacks has no state");
        let wip = &p.rows[0];
        assert_eq!(wip.assignee, "", "xucp-3 and other:ucp-3 are not ucp:ucp-3");
        let shipped = &p.rows[2];
        assert_eq!(shipped.prs[0].state, "merged");
        assert_eq!(shipped.prs[0].url, "https://github.com/o/ucp/pull/12");
        assert_eq!(shipped.href, "#projects/all?q=id:=ucp-1");
        assert_eq!(
            (p.opened_text.as_str(), p.due_text.as_str()),
            ("2026-11-18", "2026-11-19")
        );
    }

    #[test]
    fn status_reads_released_cut_unreleased_legacy_and_a_red_cut_turns_it_bad() {
        let released = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, true)]);
        let p = page(&[&released], &[], Ok(Feed::default()), &[], &[]).unwrap();
        assert_eq!((p.status.as_str(), p.level), ("released", Level::Ok));
        assert_eq!(p.rows_note, "no row names this version (#version/)");

        let cut = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let dodge = app(
            "dodginballs",
            "o/ucp",
            vec![ship("v0.5.3-dodginballs5", "0.5.3", 20, false)],
        );
        let runs = [red_run("dodginballs", "v0.5.3-dodginballs5", "agent-31")];
        let p = page(&[&cut, &dodge], &runs, Ok(Feed::default()), &[], &[]).unwrap();
        assert_eq!((p.status.as_str(), p.level), ("cut", Level::Bad));
        assert_eq!(p.cut_text, "v0.5.3-dodginballs5 t20");
        let d = &p.apps[1];
        assert_eq!((d.state.as_str(), d.fixing.as_str()), ("red", "agent-31"));
        assert_eq!(d.href, "#releases/apps/dodginballs%2F0.5.3");
        assert_eq!(p.apps[0].fixing, "", "a cut with no red run has no fixer");

        let none = app("ucp", "o/ucp", vec![ship("v0.5.2", "0.5.2", 5, true)]);
        let p = page(&[&none], &[], Ok(feed()), &[], &[]).unwrap();
        assert_eq!(
            (p.status.as_str(), p.level),
            ("unreleased", Level::Warn),
            "due 11-19 passed"
        );
        assert_eq!(p.apps[0].state, "no cut");

        let late = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let p = page(&[&late], &[], Ok(feed()), &[], &[]).unwrap();
        assert_eq!(
            (p.status.as_str(), p.level),
            ("cut", Level::Warn),
            "a cut not out by its due day"
        );

        let mut old = ship("v0.5.3", "0.5.3", 1, true);
        old.provenance = "legacy".into();
        let legacy = app("ucp", "o/ucp", vec![old]);
        let p = page(&[&legacy], &[], Ok(Feed::default()), &[], &[]).unwrap();
        assert_eq!((p.status.as_str(), p.level), ("legacy", Level::Neutral));
    }

    #[test]
    fn no_cut_and_no_row_is_no_page_and_a_feed_error_still_draws_the_cuts() {
        let other = app("ucp", "o/ucp", vec![ship("v0.5.2", "0.5.2", 5, true)]);
        assert!(page(&[&other], &[], Ok(Feed::default()), &[], &[]).is_none());
        assert!(page(&[], &[], Err("notes: not found".into()), &[], &[]).is_none());
        let cut = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let p = page(&[&cut], &[], Err("notes: not found".into()), &[], &[]).unwrap();
        assert_eq!(p.errors, ["notes: not found"]);
        assert_eq!(p.rows_note, "the rows did not read");
        assert_eq!(p.apps.len(), 1);
    }

    #[test]
    fn the_window_comes_only_from_the_projects_own_lab() {
        let cut = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let mut f = feed();
        f.projects[0].project = "dodginballs".into();
        let p = page(&[&cut], &[], Ok(f.clone()), &[], &[]).unwrap();
        assert_eq!(p.due_text, "no due day");
        assert_eq!(p.rows.len(), 3, "its rows still count");
        f.projects[0].project = "UCP".into();
        let p = page(&[&cut], &[], Ok(f), &[], &[]).unwrap();
        assert_eq!(p.due_text, "2026-11-19", "lab names match in any case");
    }

    #[test]
    fn owned_lists_the_project_app_first_and_leaves_other_repos_out() {
        let rel = Releases {
            apps: vec![
                app("shape-city", "", vec![]),
                app("dodginballs", "", vec![]),
                app("ucp", "", vec![]),
            ],
            ..Default::default()
        };
        let names: Vec<&str> = owned(&rel, "ucp")
            .iter()
            .map(|a| a.project.as_str())
            .collect();
        assert_eq!(names, ["ucp"]);
    }

    #[test]
    fn lines_say_the_header_rows_and_each_app() {
        let cut = app("ucp", "o/ucp", vec![ship("v0.5.3", "0.5.3", 10, false)]);
        let p = page(&[&cut], &[], Ok(feed()), &[], &[]).unwrap();
        let l = lines(&p);
        assert_eq!(l[0], "Version ucp 0.5.3: cut, v0.5.3 t10");
        assert!(
            l[1].contains("1 done, 1 doing, 1 open, 0 dropped"),
            "{}",
            l[1]
        );
        assert!(
            l.iter()
                .any(|x| x.contains("ucp-1  done  -  #12  ship menu")),
            "{l:?}"
        );
        assert!(l.iter().any(|x| x == "  ucp v0.5.3 no runs"), "{l:?}");
    }
}
