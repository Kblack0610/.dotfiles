//! One release of an app as a pipeline (docs/dashboards.md, "Release page"): every cut of one
//! version (`v0.5.3-dodginballs1` .. `5` are five cuts of 0.5.3), and the cut on show drawn as
//! stages left to right: the tag, the runs the tag started, the runs another run started, then
//! each declared channel with whether the cut reached it. Under it, every cut's result per
//! workflow, the way a pipeline's execution history lists its past runs.
//!
//! Nothing here is read: the app (`releases::App`, its history and channels), the joined runs
//! (`builds::read`, each run's `release`) and the job archive's records are the caller's. The page
//! is the app page's (`links::Kind::App`) with the version after a slash, so one link resolver
//! serves both: `#releases/apps/dodginballs/0.5.3`.

use std::collections::HashMap;

use serde::Serialize;

use crate::builds::{Run, RunKey};
use crate::links::{Kind, Link};
use crate::pipeline::dated;
use crate::release_graph::{Reached, Shipment};
use crate::releases::{App, Level};
use crate::run_detail::{took_text, Record};
use crate::run_page::{job_boxes, StageJob};

/// The version a tag or version string is a cut of: `v0.5.3-dodginballs5` and `0.5.3` are both
/// `0.5.3`. A suffix after the first `-` names the cut, never another release.
pub fn core(v: &str) -> &str {
    let v = v.trim().trim_start_matches('v');
    v.split_once('-').map_or(v, |(c, _)| c)
}

/// The version a history tag is a cut of, from the version the collector parsed off it with the
/// line's glob (`binks-v2` is `2`, `v0.5.3-dodginballs5` is `0.5.3`); the tag when none was parsed.
fn cut_of(s: &Shipment) -> &str {
    core(if s.version.is_empty() {
        &s.tag
    } else {
        &s.version
    })
}

/// The version asked (`0.5.3`, or one cut's tag, which stands for its own version) and the app's
/// cuts of it, newest first.
fn cuts_of<'a>(app: &'a App, asked: &str) -> (String, Vec<&'a Shipment>) {
    let asked = asked.trim();
    let named = app
        .history
        .iter()
        .find(|s| s.tag == asked || s.tag == format!("v{asked}"));
    let want = named.map_or_else(|| core(asked), cut_of).to_string();
    let cuts = app.history.iter().filter(|s| cut_of(s) == want).collect();
    (want, cuts)
}

/// An app page id that names a release (`dodginballs/0.5.3`, `dodginballs/v0.5.3-dodginballs4`):
/// the app and what follows the slash; None for a plain app id.
pub fn split(id: &str) -> Option<(&str, &str)> {
    id.split_once('/')
        .map(|(a, v)| (a.trim(), v.trim()))
        .filter(|(a, v)| !a.is_empty() && !v.is_empty())
}

/// The release page's link: the app page with the version after a slash.
pub fn link(app: &str, version: &str) -> Link {
    Link::to(Kind::App, format!("{app}/{version}"))
}

/// One run in a stage: its workflow, how it went and its jobs.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Action {
    pub workflow: String,
    /// `green`, `red`, `running`, `queued` or `other`: the runs table's state.
    pub state: String,
    pub level: Level,
    pub started_text: String,
    pub took_text: String,
    /// The run's page in the hub.
    pub href: String,
    /// The run on its forge.
    pub url: String,
    pub jobs: Vec<StageJob>,
    /// Why no job is listed: the archive has not reached it, or holds only some of them.
    pub jobs_note: String,
}

/// A channel the app declares, as the stage after the runs: reached by this cut or not.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Channel {
    pub id: String,
    pub channel: String,
    pub reached: bool,
    /// `deploy 11-19 14:02`, `pin`, `live`; else what the channel holds now (`live v0.5.0-x3`).
    pub text: String,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Stage {
    pub label: String,
    pub actions: Vec<Action>,
}

/// One cut of the version, a row of the history: its result per workflow.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Cut {
    pub tag: String,
    pub at_text: String,
    /// The worst of its runs: `red`, `running`, `green`, or `no runs` when the ledger holds none.
    pub state: String,
    pub level: Level,
    /// The state of its newest run of each of the page's `workflows`, `-` for one it did not run.
    pub results: Vec<String>,
    pub reached_text: String,
    pub prs_text: String,
    /// This cut drawn as the pipeline.
    pub href: String,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Page {
    pub project: String,
    pub version: String,
    /// The cut drawn as the pipeline.
    pub tag: String,
    pub sha: String,
    pub at_text: String,
    /// Tag, then the runs by what started them; empty stages are left out.
    pub stages: Vec<Stage>,
    pub channels: Vec<Channel>,
    /// Why there is no channel stage: the app declares none.
    pub channels_note: String,
    /// The history's columns, in stage order.
    pub workflows: Vec<String>,
    /// Every cut of the version, newest first.
    pub cuts: Vec<Cut>,
    pub prs_text: String,
    pub rows_text: String,
    pub app_href: String,
    /// The runs ledger keeps `builds::KEEP_DAYS`: a cut older than it has no runs to show.
    pub note: String,
}

/// What started a run: the tag (a push of it, a dispatch on it) is stage 1, another run (a
/// `workflow_run` trigger, or an upload titled `... of <run id>`) stage 2.
fn depth(r: &Run) -> usize {
    let of_run = r
        .title
        .rsplit_once(" of ")
        .and_then(|(_, w)| w.split_whitespace().next())
        .map(|w| w.trim_end_matches(')'))
        .is_some_and(|w| !w.is_empty() && w.bytes().all(|b| b.is_ascii_digit()));
    usize::from(r.event == "workflow_run" || of_run)
}

const STAGES: [&str; 2] = ["Started by the tag", "Started by a run"];

/// The newest attempt of each run joined to `tag` of `project`, oldest start first.
fn runs_of<'a>(runs: &'a [Run], project: &str, tag: &str) -> Vec<&'a Run> {
    let mut newest: HashMap<(&str, &str, u64), &Run> = HashMap::new();
    for r in runs.iter().filter(|r| {
        r.release
            .as_ref()
            .is_some_and(|x| x.project == project && x.tag == tag)
    }) {
        let e = newest.entry((&r.forge, &r.repo, r.id)).or_insert(r);
        if r.attempt > e.attempt {
            *e = r;
        }
    }
    let mut out: Vec<&Run> = newest.into_values().collect();
    out.sort_by_key(|r| (depth(r), r.started, r.id));
    out
}

/// The run ids a page of `version` can draw: what the caller reads from the job archive.
pub fn run_keys(app: &App, runs: &[Run], version: &str) -> Vec<RunKey> {
    cuts_of(app, version)
        .1
        .into_iter()
        .flat_map(|s| runs_of(runs, &app.project, &s.tag))
        .map(Run::key)
        .collect()
}

/// The job archive's records of `keys`, read from `path` (`builds::Paths::jobs`): only lines that
/// name one of the runs are parsed. A missing archive is no records, not an error. The test reads
/// each line's `"run_id":` once (it sits near the line's start), so the archive is one pass however
/// many runs a version has.
pub fn records(path: &std::path::Path, keys: &[RunKey]) -> HashMap<RunKey, Record> {
    if keys.is_empty() {
        return HashMap::new();
    }
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let ids: std::collections::HashSet<u64> = keys.iter().map(|k| k.id).collect();
    let run_id = |l: &str| {
        let at = l.find("\"run_id\":")? + "\"run_id\":".len();
        let rest = &l[at..];
        rest[..rest
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(rest.len())]
            .parse::<u64>()
            .ok()
    };
    let (mut got, _) =
        crate::run_detail::archive(&text, |l| run_id(l).is_some_and(|i| ids.contains(&i)));
    got.retain(|k, _| keys.contains(k));
    got
}

fn action(r: &Run, rec: Option<&Record>) -> Action {
    let (jobs, jobs_note) = match rec {
        Some(x) if !x.jobs.is_empty() => (
            job_boxes(&x.jobs),
            if x.complete {
                String::new()
            } else {
                "only some of its jobs were read".into()
            },
        ),
        _ if !r.done() => (vec![], "jobs show on its page while it runs".into()),
        _ => (vec![], "no jobs archived for it yet".into()),
    };
    Action {
        workflow: crate::builds::timed_as(&r.workflow, &r.path),
        state: r.state.clone(),
        level: r.level,
        started_text: dated(r.started),
        took_text: took_text(r.took),
        href: Link::to(Kind::CiRun, format!("{}/{}", r.project(), r.id)).href(),
        url: r.url.clone(),
        jobs,
        jobs_note,
    }
}

/// The worst of a cut's runs, as the history's STATE cell says it.
fn worst(rs: &[&Run]) -> (String, Level) {
    if rs.is_empty() {
        return ("no runs".into(), Level::default());
    }
    for s in ["red", "running", "queued"] {
        if let Some(r) = rs.iter().find(|r| r.state == s) {
            return (s.into(), r.level);
        }
    }
    if rs.iter().all(|r| r.state == "green") {
        return ("green".into(), Level::Ok);
    }
    ("other".into(), Level::default())
}

fn reached_word(x: &Reached) -> String {
    match x.at {
        Some(a) => format!("{} {}", x.how, dated(a)),
        None => x.how.clone(),
    }
}

/// `version` of `app` (`0.5.3`, or one cut's tag to draw that cut) as its page, or None when no
/// tag of the app's line is a cut of it. `records` are the job archive's, by run.
pub fn build(
    app: &App,
    runs: &[Run],
    records: &HashMap<RunKey, Record>,
    version: &str,
) -> Option<Page> {
    let (want, cuts) = cuts_of(app, version);
    let shown = cuts
        .iter()
        .find(|s| s.tag == version || s.tag == format!("v{version}"))
        .or(cuts.first())?;
    let by_cut: Vec<Vec<&Run>> = cuts
        .iter()
        .map(|s| runs_of(runs, &app.project, &s.tag))
        .collect();
    // The history's columns: every workflow any cut ran, in stage order, then first start.
    let mut workflows: Vec<(usize, i64, String)> = vec![];
    for r in by_cut.iter().flatten() {
        let w = crate::builds::timed_as(&r.workflow, &r.path);
        match workflows.iter_mut().find(|(_, _, x)| *x == w) {
            Some(e) => e.1 = e.1.min(r.started),
            None => workflows.push((depth(r), r.started, w)),
        }
    }
    workflows.sort();
    let workflows: Vec<String> = workflows.into_iter().map(|(_, _, w)| w).collect();
    let mine = &by_cut[cuts.iter().position(|s| s.tag == shown.tag)?];
    let mut stages: Vec<Stage> = STAGES
        .iter()
        .map(|l| Stage {
            label: (*l).into(),
            actions: vec![],
        })
        .collect();
    for r in mine {
        stages[depth(r)]
            .actions
            .push(action(r, records.get(&r.key())));
    }
    stages.retain(|s| !s.actions.is_empty());
    let declared: Vec<_> = app.channels.iter().filter(|c| !c.implicit).collect();
    let channels = declared
        .iter()
        .map(|c| {
            let hit = shown.reached.iter().find(|x| x.id == c.id);
            Channel {
                id: c.id.clone(),
                channel: c.channel.clone(),
                reached: hit.is_some(),
                text: hit.map_or_else(
                    || format!("not reached, live {}", c.live_text),
                    reached_word,
                ),
            }
        })
        .collect();
    let oldest = cuts.iter().filter_map(|s| s.at).min();
    let horizon = crate::jobs::now() - crate::builds::KEEP_DAYS * 86400;
    let note = if oldest.is_some_and(|a| a < horizon) {
        format!(
            "runs older than {} days are out of the ledger: those cuts say no runs",
            crate::builds::KEEP_DAYS
        )
    } else {
        String::new()
    };
    let cuts_rows = cuts
        .iter()
        .zip(&by_cut)
        .map(|(s, rs)| {
            let (state, level) = worst(rs);
            let results = workflows
                .iter()
                .map(|w| {
                    rs.iter()
                        .rev()
                        .find(|r| crate::builds::timed_as(&r.workflow, &r.path) == *w)
                        .map_or("-".into(), |r| r.state.clone())
                })
                .collect();
            Cut {
                tag: s.tag.clone(),
                at_text: s.at_text.clone(),
                state,
                level,
                results,
                reached_text: s.reached_text.clone(),
                prs_text: s.prs_text.clone(),
                href: link(&app.project, &s.tag).href(),
            }
        })
        .collect();
    Some(Page {
        project: app.project.clone(),
        version: want.to_string(),
        tag: shown.tag.clone(),
        sha: shown.sha.clone().unwrap_or_default(),
        at_text: shown.at_text.clone(),
        stages,
        channels_note: if declared.is_empty() {
            "the app declares no channel".into()
        } else {
            String::new()
        },
        channels,
        workflows,
        cuts: cuts_rows,
        prs_text: shown.prs_text.clone(),
        rows_text: shown.rows_text.clone(),
        app_href: Link::to(Kind::App, app.project.clone()).href(),
        note,
    })
}

/// The page as text, for the hub TUI: the pipeline of the cut on show, then the history.
pub fn lines(p: &Page) -> Vec<String> {
    let mut out = vec![format!(
        "Release {} {}: {} tagged {}",
        p.project, p.version, p.tag, p.at_text
    )];
    for s in &p.stages {
        out.push(format!("  {}", s.label));
        for a in &s.actions {
            out.push(format!(
                "    {}  {}  {}  {}",
                a.workflow, a.state, a.started_text, a.took_text
            ));
            for j in a.jobs.iter().filter(|j| j.state != "green") {
                let fail = if j.failing.is_empty() {
                    String::new()
                } else {
                    format!(" at {}", j.failing)
                };
                out.push(format!("      {} {}{fail}", j.name, j.state));
            }
            if !a.jobs_note.is_empty() {
                out.push(format!("      {}", a.jobs_note));
            }
        }
    }
    out.push("  Channels".into());
    if !p.channels_note.is_empty() {
        out.push(format!("    {}", p.channels_note));
    }
    for c in &p.channels {
        out.push(format!("    {} {}", c.id, c.text));
    }
    out.push(format!("  PRs {}  rows {}", p.prs_text, p.rows_text));
    out.push(format!("  Cuts: {}", p.workflows.join(", ")));
    for c in &p.cuts {
        out.push(format!(
            "    {}  {}  {}  {}",
            c.tag,
            c.at_text,
            c.state,
            c.results.join(" ")
        ));
    }
    if !p.note.is_empty() {
        out.push(format!("  {}", p.note));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::release_graph::RunRelease;
    use crate::releases::Release;
    use crate::run_detail::{Job, Step};

    fn run(id: u64, wf: &str, tag: &str, state: &str, event: &str, started: i64) -> Run {
        Run {
            forge: "github".into(),
            repo: "o/r".into(),
            id,
            attempt: 1,
            workflow: wf.into(),
            title: wf.into(),
            branch: tag.into(),
            event: event.into(),
            status: "completed".into(),
            state: state.into(),
            level: if state == "red" {
                Level::Bad
            } else {
                Level::Ok
            },
            started,
            took: Some(60),
            release: Some(RunRelease {
                project: "game".into(),
                tag: tag.into(),
            }),
            ..Default::default()
        }
    }

    fn cut(tag: &str, at: i64, reached: Vec<Reached>) -> Shipment {
        Shipment {
            tag: tag.into(),
            at: Some(at),
            at_text: format!("t{at}"),
            reached,
            prs_text: "#1".into(),
            ..Default::default()
        }
    }

    fn app() -> App {
        let now = crate::jobs::now();
        App {
            project: "game".into(),
            history: vec![
                cut("v0.5.3-game3", now - 10, vec![]),
                cut(
                    "v0.5.3-game2",
                    now - 20,
                    vec![Reached {
                        id: "steam-beta".into(),
                        channel: "beta".into(),
                        at: Some(now - 15),
                        how: "deploy".into(),
                        run: None,
                    }],
                ),
                cut("v0.5.2-game1", now - 30, vec![]),
            ],
            channels: vec![Release {
                id: "steam-beta".into(),
                channel: "beta".into(),
                live_text: "v0.5.0-game7".into(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn a_version_is_the_core_of_any_of_its_cuts() {
        assert_eq!(core("v0.5.3-dodginballs5"), "0.5.3");
        assert_eq!(core("0.5.3"), "0.5.3");
        assert_eq!(core("v1.19.0"), "1.19.0");
        assert_eq!(split("game/0.5.3"), Some(("game", "0.5.3")));
        assert_eq!(split("game"), None);
        assert_eq!(link("game", "0.5.3").href(), "#releases/apps/game%2F0.5.3");
    }

    #[test]
    fn the_newest_cut_is_drawn_as_stages_by_what_started_each_run_and_every_cut_is_a_row() {
        let mut steam = run(
            4,
            "Steam (game of 1)",
            "v0.5.3-game3",
            "red",
            "workflow_dispatch",
            50,
        );
        steam.title = "Steam (game of 1)".into();
        let runs = vec![
            run(
                1,
                "Release builds",
                "v0.5.3-game3",
                "green",
                "workflow_dispatch",
                10,
            ),
            run(2, "iOS release", "v0.5.3-game3", "red", "push", 11),
            steam,
            run(3, "Release builds", "v0.5.3-game2", "green", "push", 5),
            run(9, "Release builds", "v0.5.2-game1", "green", "push", 1),
        ];
        let mut records = HashMap::new();
        records.insert(
            runs[1].key(),
            Record {
                complete: true,
                jobs: vec![Job {
                    id: 7,
                    name: "Build".into(),
                    conclusion: Some("failure".into()),
                    steps: vec![Step {
                        name: "Export".into(),
                        conclusion: Some("failure".into()),
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            },
        );
        let p = build(&app(), &runs, &records, "0.5.3").unwrap();
        assert_eq!(
            (p.version.as_str(), p.tag.as_str()),
            ("0.5.3", "v0.5.3-game3")
        );
        let names: Vec<Vec<&str>> = p
            .stages
            .iter()
            .map(|s| s.actions.iter().map(|a| a.workflow.as_str()).collect())
            .collect();
        assert_eq!(
            names,
            vec![vec!["Release builds", "iOS release"], vec!["Steam (game)"]]
        );
        assert_eq!(p.stages[1].label, "Started by a run");
        let ios = &p.stages[0].actions[1];
        assert_eq!(
            (ios.jobs[0].state.as_str(), ios.jobs[0].failing.as_str()),
            ("red", "Export")
        );
        assert_eq!(
            p.stages[0].actions[0].jobs_note,
            "no jobs archived for it yet"
        );
        assert_eq!(
            p.workflows,
            vec!["Release builds", "iOS release", "Steam (game)"]
        );
        let rows: Vec<(&str, &str, Vec<String>)> = p
            .cuts
            .iter()
            .map(|c| (c.tag.as_str(), c.state.as_str(), c.results.clone()))
            .collect();
        assert_eq!(
            rows,
            vec![
                (
                    "v0.5.3-game3",
                    "red",
                    vec!["green".into(), "red".into(), "red".into()]
                ),
                (
                    "v0.5.3-game2",
                    "green",
                    vec!["green".into(), "-".into(), "-".into()]
                ),
            ],
            "0.5.2 is another release"
        );
        assert_eq!(p.channels.len(), 1);
        assert!(!p.channels[0].reached);
        assert_eq!(p.channels[0].text, "not reached, live v0.5.0-game7");
        assert_eq!(run_keys(&app(), &runs, "0.5.3").len(), 4);
    }

    #[test]
    fn a_cuts_tag_draws_that_cut_and_says_the_channel_it_reached() {
        let p = build(&app(), &[], &HashMap::new(), "v0.5.3-game2").unwrap();
        assert_eq!(p.tag, "v0.5.3-game2");
        assert!(p.stages.is_empty());
        assert!(p.channels[0].reached);
        assert!(p.channels[0].text.starts_with("deploy "));
        assert_eq!(p.cuts[0].state, "no runs");
        assert_eq!(p.cuts[1].href, "#releases/apps/game%2Fv0.5.3-game2");
        let text = lines(&p).join("\n");
        assert!(text.contains("steam-beta deploy"), "{text}");
    }

    #[test]
    fn a_version_with_no_cut_is_no_page_and_an_app_with_no_channel_says_so() {
        assert!(build(&app(), &[], &HashMap::new(), "9.9.9").is_none());
        let mut a = app();
        a.channels.clear();
        let p = build(&a, &[], &HashMap::new(), "0.5.3").unwrap();
        assert_eq!(p.channels_note, "the app declares no channel");
    }

    /// A line whose tags lead with the app (`binks-v2`) groups by the version the collector parsed
    /// off each tag, so each version is its own page, asked by version or by its tag.
    #[test]
    fn an_app_prefixed_tag_groups_by_its_parsed_version() {
        let tag = |t: &str, v: &str| Shipment {
            version: v.into(),
            ..cut(t, 1, vec![])
        };
        let a = App {
            project: "binks".into(),
            history: vec![tag("binks-v2", "2"), tag("binks-v1", "1")],
            ..Default::default()
        };
        for asked in ["binks-v2", "2", "v2"] {
            let p = build(&a, &[], &HashMap::new(), asked).unwrap();
            assert_eq!(
                (p.version.as_str(), p.tag.as_str()),
                ("2", "binks-v2"),
                "{asked}"
            );
            assert_eq!(
                p.cuts.len(),
                1,
                "{asked}: one cut, not every tag of the app"
            );
        }
        assert!(build(&a, &[], &HashMap::new(), "binks").is_none());
    }

    /// The archive read keeps the asked run by its `run_id`, never a run whose id contains it.
    #[test]
    fn records_reads_the_asked_runs_by_run_id() {
        let file =
            std::env::temp_dir().join(format!("hub-core-release-jobs-{}", std::process::id()));
        let line = |id: u64| {
            format!(
                r#"{{"forge":"github.com","repo":"o/app","run_id":{id},"attempt":1,"complete":true,"jobs":[]}}"#
            )
        };
        std::fs::write(&file, [line(55), line(5), line(9)].join("\n")).unwrap();
        let key = RunKey {
            forge: "github.com".into(),
            repo: "o/app".into(),
            id: 5,
            attempt: 1,
        };
        let got = records(&file, std::slice::from_ref(&key));
        std::fs::remove_file(&file).unwrap();
        assert_eq!(got.keys().collect::<Vec<_>>(), vec![&key]);
        assert!(
            records(&file, &[key]).is_empty(),
            "a missing archive is no records"
        );
    }
}
