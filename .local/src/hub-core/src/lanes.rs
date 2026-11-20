//! Releases > Flow: one project's CI and release runs as swimlanes over a window (24h or 7d),
//! built once here so the hub TUI's text bars and agent-web's chart draw the same rows.
//!
//! The CI lanes are the project's runs the release graph tied to no release, one lane per
//! workflow (`builds::timed_as`, so `Tests (delta of N)` pools), each run a segment keyed by its
//! state. The Release lanes are, per app of the project (an app whose tag line lives in the
//! project's repo, so a game of the playground is the playground's): its tags, its build runs
//! (the runs `release_graph` joined to it) and one lane per channel a tag reached in the window,
//! each reach a mark at its time (`release_graph::reached`, read off the app's history). Nothing
//! here is stored: every join is the read's (`builds::read`, `releases::read`).
//!
//! A run opens its record (`links::Kind::CiRun`), a tag or a reach the app's page
//! (`links::Kind::App`).

use std::collections::BTreeMap;

use serde::Serialize;

use crate::builds::{timed_as, Builds, Run};
use crate::links::{Kind, Link};
use crate::pipeline::dated;
use crate::releases::{App, Releases};

/// The windows a Flow can be drawn over, as the picker names them, and their length in seconds.
pub const WINDOWS: [(&str, i64); 2] = [("24h", 86_400), ("7d", 7 * 86_400)];
/// The `WINDOWS` entry an unknown name gets, 7d: a week shows a release's path from tag to
/// store; a day is mostly CI.
const DEFAULT_WINDOW: usize = 1;
/// Past this many workflows the quietest fold into one `other workflows` lane, so a project
/// with a long tail of one-off workflows still reads on one screen.
pub const MAX_CI_LANES: usize = 10;
/// Runs of one state closer than a window / MERGE_PARTS apart are one segment: below that the
/// chart cannot draw them apart, and a week of a busy repo (6000 runs) stays a small answer.
const MERGE_PARTS: i64 = 600;

/// Each key a segment can carry and what it means, in the order a cell picks the one it shows
/// (`cells`): what both surfaces' legends list.
pub const KEYS: [(&str, &str); 7] = [
    ("red", "failed"),
    ("running", "running"),
    ("queued", "queued"),
    ("reached", "reached the channel"),
    ("tag", "tagged"),
    ("green", "passed"),
    ("other", "cancelled or skipped"),
];

/// One run, or several merged runs of one state, or one tag or reach (`a == b`), unix seconds.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Seg {
    pub a: i64,
    pub b: i64,
    /// One of `KEYS`.
    pub key: &'static str,
    pub title: String,
    /// The web address it opens (`Link::href`): the run's record, or the app's page.
    pub link: String,
    /// How many runs it stands for: 1 unless runs merged into it.
    pub n: usize,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Lane {
    pub label: String,
    /// `12 runs, 2 red`, or the channel a reach lane is for (`beta`).
    pub sub: String,
    pub segs: Vec<Seg>,
}

/// The tab's one read: the lanes of `project` over `[t0, t1]`, and the pickers' choices.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Flow {
    pub project: String,
    pub window: &'static str,
    pub t0: i64,
    pub t1: i64,
    /// Every project with a run in the window or an app: the picker, sorted.
    pub projects: Vec<String>,
    pub windows: Vec<&'static str>,
    pub keys: Vec<(&'static str, &'static str)>,
    pub ci: Vec<Lane>,
    pub release: Vec<Lane>,
    /// Why the CI lanes are empty (`no CI runs in 7d`); empty when there are lanes.
    pub ci_empty: String,
    /// Why the Release lanes are empty: `no release joins` for a project no app and no run's
    /// release names (a Forgejo-only repo), else nothing in the window.
    pub release_empty: String,
    /// What the runs ledger and the releases snapshot could not read.
    pub errors: Vec<String>,
}

/// The window `name` names, else the default: (its name, its length).
pub fn window(name: &str) -> (&'static str, i64) {
    let name = name.trim();
    WINDOWS
        .iter()
        .find(|w| w.0 == name)
        .copied()
        .unwrap_or(WINDOWS[DEFAULT_WINDOW])
}

/// The project whose repo holds the app's tags, else the app's own name.
fn owner(a: &App) -> String {
    if a.repo.is_empty() {
        a.project.clone()
    } else {
        project_map::canonical(&a.repo)
    }
}

/// When a run ran, clipped to nothing: its start, and its start plus what it took (a running or
/// queued run's time so far).
fn span(r: &Run) -> (i64, i64) {
    (r.started, r.started + r.took.unwrap_or(0))
}

fn state_key(state: &str) -> &'static str {
    KEYS.iter()
        .map(|k| k.0)
        .find(|k| *k == state && !matches!(*k, "tag" | "reached"))
        .unwrap_or("other")
}

/// One run as a segment; `project` is `r.project()`, which the caller already worked out.
fn run_seg(r: &Run, project: &str, what: &str) -> Seg {
    let (a, b) = span(r);
    let took = r.took.map_or_else(String::new, |t| {
        format!(" {}", crate::run_detail::took_text(Some(t)))
    });
    Seg {
        a,
        b,
        key: state_key(&r.state),
        title: format!("{what} {} {}{took}", r.state, dated(a)),
        link: Link::to(Kind::CiRun, format!("{project}/{}", r.id)).href(),
        n: 1,
    }
}

/// Runs of one state that touch within `tol` seconds become one segment, which opens the newest
/// of them. A tag or reach mark never merges: each names a different tag.
fn merge(mut segs: Vec<Seg>, tol: i64) -> Vec<Seg> {
    segs.sort_by_key(|s| (s.a, s.b));
    let mut out: Vec<Seg> = vec![];
    let mut last: Vec<(&'static str, usize)> = vec![];
    for s in segs {
        let runs = !matches!(s.key, "tag" | "reached");
        let at = last.iter().find(|(k, _)| *k == s.key).map(|x| x.1);
        match at.filter(|&i| runs && s.a <= out[i].b + tol) {
            Some(i) => {
                let m = &mut out[i];
                m.b = m.b.max(s.b);
                m.n += s.n;
                m.link = s.link;
                m.title = format!("{} {} runs {} to {}", m.n, m.key, dated(m.a), dated(m.b));
            }
            None => {
                last.retain(|(k, _)| *k != s.key);
                last.push((s.key, out.len()));
                out.push(s);
            }
        }
    }
    out
}

/// `12 runs, 2 red`: what a run lane's segments stand for.
fn says(segs: &[Seg]) -> String {
    let n: usize = segs.iter().map(|s| s.n).sum();
    let red: usize = segs.iter().filter(|s| s.key == "red").map(|s| s.n).sum();
    let runs = if n == 1 { "run" } else { "runs" };
    if red > 0 {
        format!("{n} {runs}, {red} red")
    } else {
        format!("{n} {runs}")
    }
}

fn run_lane(label: String, segs: Vec<Seg>, tol: i64) -> Lane {
    Lane {
        sub: says(&segs),
        segs: merge(segs, tol),
        label,
    }
}

/// One lane a workflow, the busiest first; past the cap the rest are one lane.
fn ci_lanes(ci: BTreeMap<String, Vec<Seg>>, tol: i64) -> Vec<Lane> {
    let mut by: Vec<(String, Vec<Seg>)> = ci.into_iter().collect();
    by.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then_with(|| a.0.cmp(&b.0)));
    let rest: Vec<(String, Vec<Seg>)> = if by.len() > MAX_CI_LANES {
        by.split_off(MAX_CI_LANES - 1)
    } else {
        vec![]
    };
    let mut ci: Vec<Lane> = by
        .into_iter()
        .map(|(wf, segs)| run_lane(wf, segs, tol))
        .collect();
    if !rest.is_empty() {
        let n = rest.len();
        let segs: Vec<Seg> = rest.into_iter().flat_map(|x| x.1).collect();
        let mut lane = run_lane("other workflows".into(), segs, tol);
        lane.sub = format!("{n} workflows, {}", lane.sub);
        ci.push(lane);
    }
    ci
}

/// One app's release lanes in `[t0, t1]`: its tags, its build runs (`built`), and one lane per
/// channel a tag reached; a lane with nothing in the window is left out.
fn app_lanes(
    name: &str,
    app: Option<&App>,
    built: Option<Vec<Seg>>,
    (t0, t1): (i64, i64),
    tol: i64,
) -> Vec<Lane> {
    let mut out = vec![];
    let page = Link::to(Kind::App, name.to_string()).href();
    let hist = app.map_or(&[][..], |a| &a.history[..]);
    let mark = |at: i64, key: &'static str, title: String| Seg {
        a: at,
        b: at,
        key,
        title,
        link: page.clone(),
        n: 1,
    };
    let tags: Vec<Seg> = hist
        .iter()
        .filter_map(|s| Some((s, s.at.filter(|&at| at >= t0 && at <= t1)?)))
        .map(|(s, at)| mark(at, "tag", format!("{} tagged {}", s.tag, dated(at))))
        .collect();
    if !tags.is_empty() {
        let n = tags.len();
        out.push(Lane {
            label: format!("{name} tags"),
            sub: format!("{n} {}", if n == 1 { "tag" } else { "tags" }),
            segs: merge(tags, tol),
        });
    }
    if let Some(segs) = built {
        out.push(run_lane(format!("{name} builds"), segs, tol));
    }
    for ch in app.map_or(&[][..], |a| &a.channels[..]) {
        let reached: Vec<Seg> = hist
            .iter()
            .flat_map(|s| s.reached.iter().map(move |x| (s, x)))
            .filter(|(_, x)| x.id == ch.id)
            .filter_map(|(s, x)| Some((s, x, x.at.filter(|&at| at >= t0 && at <= t1)?)))
            .map(|(s, x, at)| {
                let how = if x.how == "pin" { " (pin)" } else { "" };
                mark(
                    at,
                    "reached",
                    format!("{} reached {} {}{how}", s.tag, ch.id, dated(at)),
                )
            })
            .collect();
        if !reached.is_empty() {
            out.push(Lane {
                label: ch.id.clone(),
                sub: ch.channel.clone(),
                segs: merge(reached, tol),
            });
        }
    }
    out
}

/// The lanes of `project` over the `window` (a `WINDOWS` name; an unknown one is the default)
/// ending `now`, from one builds read (its rows joined to releases: `builds::read` with a join)
/// and one releases read. An empty `project` is the one with the most runs in the window, else
/// the first in the picker.
pub fn build(b: &Builds, rel: &Releases, project: &str, window_name: &str, now: i64) -> Flow {
    let (window, secs) = window(window_name);
    let (t0, t1) = (now - secs, now);
    let tol = secs / MERGE_PARTS;
    // Each run with its project, worked out once: `canonical` takes the registry's lock.
    let runs: Vec<(&Run, String)> = b
        .rows
        .iter()
        .filter(|r| span(r).1 >= t0 && r.started <= t1)
        .map(|r| (r, r.project()))
        .collect();
    let mut busy: BTreeMap<&str, usize> = BTreeMap::new();
    for (_, p) in &runs {
        *busy.entry(p).or_default() += 1;
    }
    let mut projects: Vec<String> = busy
        .keys()
        .map(|p| p.to_string())
        .chain(rel.apps.iter().map(owner))
        .collect();
    projects.sort();
    projects.dedup();
    // Asked for none, the busiest in the window, else the first.
    let project = match project.trim() {
        "" => busy
            .iter()
            .max_by_key(|(p, n)| (**n, std::cmp::Reverse(**p)))
            .map(|(p, _)| p.to_string())
            .or_else(|| projects.first().cloned())
            .unwrap_or_default(),
        p => p.to_string(),
    };
    let apps: Vec<&App> = rel.apps.iter().filter(|a| owner(a) == project).collect();
    let is_app = |name: &str| apps.iter().any(|a| a.project == name);
    let mut ci: BTreeMap<String, Vec<Seg>> = BTreeMap::new();
    let mut built: BTreeMap<String, Vec<Seg>> = BTreeMap::new();
    for (r, rp) in &runs {
        match &r.release {
            Some(x) if *rp == project || is_app(&x.project) => {
                let what = format!("{} {}", x.tag, r.workflow);
                built
                    .entry(x.project.clone())
                    .or_default()
                    .push(run_seg(r, rp, &what));
            }
            None if *rp == project => {
                let wf = timed_as(&r.workflow, &r.path);
                let seg = run_seg(r, rp, &wf);
                ci.entry(wf).or_default().push(seg);
            }
            _ => {}
        }
    }
    let ci = ci_lanes(ci, tol);
    // Per app, the project's own first.
    let mut names: Vec<String> = apps.iter().map(|a| a.project.clone()).collect();
    names.extend(built.keys().cloned());
    names.sort_by(|a, b| (a != &project, a).cmp(&(b != &project, b)));
    names.dedup();
    let release: Vec<Lane> = names
        .iter()
        .flat_map(|name| {
            let app = apps.iter().copied().find(|a| &a.project == name);
            app_lanes(name, app, built.remove(name), (t0, t1), tol)
        })
        .collect();
    let ci_empty = if ci.is_empty() {
        format!("no CI runs in {window}")
    } else {
        String::new()
    };
    let release_empty = if !release.is_empty() {
        String::new()
    } else if names.is_empty() {
        "no release joins".into()
    } else {
        format!("nothing tagged, built or deployed in {window}")
    };
    // Both reads carry the queue's error when the queue would not read: say it once.
    let mut errors = b.errors.clone();
    for e in &rel.errors {
        if !errors.contains(e) {
            errors.push(e.clone());
        }
    }
    Flow {
        project,
        window,
        t0,
        t1,
        projects,
        windows: WINDOWS.iter().map(|w| w.0).collect(),
        keys: KEYS.to_vec(),
        ci,
        release,
        ci_empty,
        release_empty,
        errors,
    }
}

/// A lane as `width` cells over `[t0, t1]`: each cell the first `KEYS` key among the segments
/// that touch it, None where nothing ran. A mark or a short run still takes the cell it falls in.
pub fn cells(lane: &Lane, t0: i64, t1: i64, width: usize) -> Vec<Option<&'static str>> {
    let mut out: Vec<Option<&'static str>> = vec![None; width];
    if width == 0 || t1 <= t0 {
        return out;
    }
    let span = (t1 - t0) as f64;
    let cell = |t: i64| ((((t - t0) as f64) / span * width as f64) as usize).min(width - 1);
    let rank = |k: &str| KEYS.iter().position(|x| x.0 == k).unwrap_or(KEYS.len());
    for s in &lane.segs {
        if s.b < t0 || s.a > t1 {
            continue;
        }
        for c in &mut out[cell(s.a.max(t0))..=cell(s.b.min(t1))] {
            if c.is_none_or(|k| rank(s.key) < rank(k)) {
                *c = Some(s.key);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::release_graph::{Reached, RunRelease, Shipment};
    use crate::releases::Release;

    const NOW: i64 = 1_800_000_000;

    fn run(id: u64, repo: &str, workflow: &str, state: &str, ago: i64) -> Run {
        Run {
            forge: "github".into(),
            repo: repo.into(),
            id,
            workflow: workflow.into(),
            state: state.into(),
            started: NOW - ago,
            took: Some(120),
            ..Default::default()
        }
    }

    fn tagged(mut r: Run, app: &str, tag: &str) -> Run {
        r.release = Some(RunRelease {
            project: app.into(),
            tag: tag.into(),
        });
        r
    }

    fn game() -> App {
        App {
            project: "dodginballs".into(),
            repo: "Org/unity-core-playground".into(),
            channels: vec![
                Release {
                    id: "dodginballs-steam-development".into(),
                    channel: "alpha".into(),
                    ..Default::default()
                },
                Release {
                    id: "dodginballs-steam-default".into(),
                    channel: "prod".into(),
                    ..Default::default()
                },
            ],
            history: vec![Shipment {
                tag: "v0.5.0-dodginballs7".into(),
                at: Some(NOW - 7200),
                reached: vec![Reached {
                    id: "dodginballs-steam-development".into(),
                    channel: "alpha".into(),
                    at: Some(NOW - 3600),
                    how: "deploy".into(),
                    run: None,
                }],
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn reads(rows: Vec<Run>, apps: Vec<App>) -> (Builds, Releases) {
        (
            Builds {
                rows,
                ..Default::default()
            },
            Releases {
                apps,
                ..Default::default()
            },
        )
    }

    fn labels(l: &[Lane]) -> Vec<&str> {
        l.iter().map(|x| x.label.as_str()).collect()
    }

    #[test]
    fn a_run_with_no_tag_lands_in_ci_only_and_a_tagged_one_in_release_only() {
        let repo = "Org/unity-core-playground";
        let (b, r) = reads(
            vec![
                run(1, repo, "Checks", "green", 600),
                run(3, repo, "Started after now", "green", -600),
                tagged(
                    run(
                        2,
                        repo,
                        "Release builds of v0.5.0-dodginballs7",
                        "green",
                        5000,
                    ),
                    "dodginballs",
                    "v0.5.0-dodginballs7",
                ),
            ],
            vec![game()],
        );
        let f = build(&b, &r, "unity-core-playground", "7d", NOW);
        assert_eq!(labels(&f.ci), ["Checks"], "a run started after now is out");
        assert_eq!(
            f.ci[0].segs[0].link,
            "#infra/runs/unity-core-playground%2F1"
        );
        assert_eq!(
            labels(&f.release),
            [
                "dodginballs tags",
                "dodginballs builds",
                "dodginballs-steam-development"
            ],
            "the game is the repo's; a channel nothing reached has no lane"
        );
        assert!(f
            .release
            .iter()
            .all(|l| l.segs.iter().all(|s| !s.link.ends_with("%2F1"))));
        let dev = &f.release[2];
        assert_eq!((dev.sub.as_str(), dev.segs[0].key), ("alpha", "reached"));
        assert_eq!(dev.segs[0].link, "#releases/apps/dodginballs");
        assert!(f.ci_empty.is_empty() && f.release_empty.is_empty());
    }

    #[test]
    fn a_project_with_nothing_in_the_window_says_so_and_one_with_no_app_says_no_release_joins() {
        let (b, r) = reads(
            vec![run(1, "Org/home-config", "deploy", "red", 3 * 86_400)],
            vec![game()],
        );
        // Three days back is outside 24h and inside 7d.
        let day = build(&b, &r, "home-config", "24h", NOW);
        assert_eq!(day.ci_empty, "no CI runs in 24h");
        assert_eq!(day.release_empty, "no release joins");
        let week = build(&b, &r, "home-config", "7d", NOW);
        assert_eq!(labels(&week.ci), ["deploy"]);
        assert_eq!(week.ci[0].sub, "1 run, 1 red");
        // The game's tag is two hours old: a day shows it, an unknown window is the week.
        let none = build(&b, &r, "trader", "bogus", NOW);
        assert_eq!(none.window, "7d");
        assert_eq!(none.ci_empty, "no CI runs in 7d");
        assert_eq!(none.release_empty, "no release joins");
        assert!(none.ci.is_empty() && none.release.is_empty());
        let mut old = game();
        old.history[0].at = Some(NOW - 9 * 86_400);
        old.history[0].reached[0].at = Some(NOW - 8 * 86_400);
        let (b, r) = reads(vec![], vec![old]);
        let f = build(&b, &r, "unity-core-playground", "7d", NOW);
        assert_eq!(f.release_empty, "nothing tagged, built or deployed in 7d");
    }

    #[test]
    fn the_picker_holds_every_project_and_opens_on_the_busiest() {
        let ucp = "Org/unity-core-playground";
        let (b, r) = reads(
            vec![
                run(1, "Org/home-config", "deploy", "green", 60),
                run(2, "Org/old", "x", "green", 30 * 86_400),
                run(3, ucp, "Checks", "green", 60),
                run(4, ucp, "Checks", "green", 600),
            ],
            vec![game()],
        );
        let f = build(&b, &r, "", "", NOW);
        assert_eq!(
            (f.project.as_str(), f.window),
            ("unity-core-playground", "7d")
        );
        assert_eq!(f.projects, ["home-config", "unity-core-playground"]);
        assert_eq!(f.windows, ["24h", "7d"]);
        let (b, r) = reads(vec![], vec![game()]);
        assert_eq!(
            build(&b, &r, " ", "24h", NOW).project,
            "unity-core-playground",
            "no runs: the first app's project"
        );
    }

    #[test]
    fn runs_of_one_state_that_touch_merge_and_open_the_newest() {
        let repo = "Org/app";
        let mut rows: Vec<Run> = (0..5)
            .map(|i| run(i, repo, "Checks", "green", 10_000 - i as i64 * 100))
            .collect();
        rows.push(run(9, repo, "Checks", "red", 9_800));
        rows.push(run(10, repo, "Checks", "green", 2_000));
        let (b, r) = reads(rows, vec![]);
        let f = build(&b, &r, "app", "24h", NOW);
        let segs = &f.ci[0].segs;
        let keys: Vec<(&str, usize)> = segs.iter().map(|s| (s.key, s.n)).collect();
        assert_eq!(keys, [("green", 5), ("red", 1), ("green", 1)]);
        assert_eq!(segs[0].link, "#infra/runs/app%2F4");
        assert!(segs[0].title.starts_with("5 green runs"));
        assert_eq!(f.ci[0].sub, "7 runs, 1 red");
    }

    #[test]
    fn past_the_cap_the_quietest_workflows_are_one_lane() {
        let rows: Vec<Run> = (0..MAX_CI_LANES as u64 + 3)
            .flat_map(|w| {
                (0..=w).map(move |i| run(w * 100 + i, "Org/app", &format!("wf{w:02}"), "green", 60))
            })
            .collect();
        let (b, r) = reads(rows, vec![]);
        let f = build(&b, &r, "app", "24h", NOW);
        assert_eq!(f.ci.len(), MAX_CI_LANES);
        assert_eq!(f.ci[0].label, "wf12", "the busiest first");
        let other = f.ci.last().unwrap();
        assert_eq!(other.label, "other workflows");
        assert!(
            other.sub.starts_with("4 workflows, 10 runs"),
            "{}",
            other.sub
        );
        // Workflow names pool as Run times does: one run id or tag per name is one lane.
        let (b, r) = reads(
            vec![
                run(1, "Org/app", "Tests (delta of 42)", "green", 60),
                run(2, "Org/app", "Tests (delta of 43)", "red", 60),
            ],
            vec![],
        );
        assert_eq!(
            labels(&build(&b, &r, "app", "24h", NOW).ci),
            ["Tests (delta)"]
        );
    }

    #[test]
    fn a_cell_shows_the_worst_key_that_touches_it() {
        let seg = |a: i64, b: i64, key| Seg {
            a,
            b,
            key,
            n: 1,
            ..Default::default()
        };
        let lane = Lane {
            segs: vec![
                seg(0, 40, "green"),
                seg(20, 24, "red"),
                seg(99, 99, "tag"),
                seg(-50, -10, "red"),
            ],
            ..Default::default()
        };
        assert_eq!(
            cells(&lane, 0, 100, 4),
            [Some("red"), Some("green"), None, Some("tag")]
        );
        assert_eq!(cells(&lane, 0, 100, 0), Vec::<Option<&str>>::new());
    }
}
