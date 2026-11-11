//! One project's dev timeline, the Timeline fold of its opened record on the Projects tab (both
//! surfaces): its commits, PRs, CI runs, release tags and deploys of the last `DAYS` days, newest
//! first. Read when the record opens (docs/dashboards.md rule 10), never for every card.
//! `project-timeline` resolves the project and fetches the facts (`Facts`); the deploys are the
//! channels `releases::channels` read for the page's badge. This module only joins them and says
//! the words.
//!
//! A run belongs to a path- or filter-scoped project when it ran on one of its commits, for one of
//! its PRs, or on one of their branches; an unscoped project (the whole repo) owns every run. A
//! run on a listed commit is said on that commit's line (`CI red`), the worst of them. Any other
//! run is a line only when it is red, running or queued; a green or cancelled one is counted in
//! the head, not listed (rule 4).

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::builds::Run;
use crate::releases::{Level, Release};
use crate::session_actions::Runner;

/// How many days back the timeline reaches.
pub const DAYS: u32 = 7;

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Commit {
    pub sha: String,
    pub at: i64,
    pub subject: String,
    /// The PRs its subject names as its merge, `(#12)`.
    pub prs: Vec<u64>,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Pr {
    pub number: u64,
    pub title: String,
    /// `open`, `merged` or `closed`, as it stands now.
    pub state: String,
    pub created: Option<i64>,
    pub merged: Option<i64>,
    pub closed: Option<i64>,
    pub branch: String,
    pub url: String,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Tag {
    pub tag: String,
    pub at: i64,
}

/// What `project-timeline` printed: the commits under the project's path or prFilter (`scoped`
/// when it has either), its PRs (the newest 100 updated in the window, from `gh pr list`), the
/// origin repo's runs from `schedules-sync runs` (unscoped) and its release tags, all in the
/// window; `notes` names a source the project does not have, `errors` one that failed.
/// `channels` is set by [`read`].
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Facts {
    pub since: i64,
    /// The integration branch: its runs are not a PR's.
    pub branch: String,
    pub scoped: bool,
    pub commits: Vec<Commit>,
    pub prs: Vec<Pr>,
    pub runs: Vec<Run>,
    pub tags: Vec<Tag>,
    pub notes: Vec<String>,
    pub errors: Vec<String>,
    #[serde(skip)]
    pub channels: Vec<Release>,
}

/// One drawn line: `11-07 14:02  commit  fix(x): y (#12)  CI red`, its colour and where it links.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Line {
    pub line: String,
    pub level: Level,
    /// The PR, run or deploy page; empty for a commit or tag.
    pub url: String,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Timeline {
    /// The fold's head: `7d: 12 commits (1 red on CI), 4 PRs, 30 runs, 2 red, 1 tag`.
    pub says: String,
    /// The newest `layout::FOLD_ROWS`, newest first.
    pub lines: Vec<Line>,
    /// How many older lines the cap left out: the `+N older` line.
    pub older: usize,
    pub notes: Vec<String>,
}

/// Red outranks live, live outranks green; `other` (cancelled, skipped) says nothing.
fn rank(state: &str) -> u8 {
    match state {
        "red" => 4,
        "running" => 3,
        "queued" => 2,
        "green" => 1,
        _ => 0,
    }
}

/// The lines, newest first, and the head's counts, from the facts as fetched. `now` is epoch
/// seconds, for the stamps.
pub fn build(f: &Facts, now: i64) -> Timeline {
    let shas: HashMap<&str, usize> = f
        .commits
        .iter()
        .enumerate()
        .map(|(i, c)| (c.sha.as_str(), i))
        .collect();
    let merged_here: HashSet<u64> = f.commits.iter().flat_map(|c| c.prs.clone()).collect();
    let mut prs = merged_here.clone();
    prs.extend(f.prs.iter().map(|p| p.number));
    let heads: HashSet<&str> = f
        .prs
        .iter()
        .map(|p| p.branch.as_str())
        .filter(|b| !b.is_empty() && *b != f.branch)
        .collect();
    // The worst run on each commit; one that says nothing (`other`) is never kept.
    let mut ci: Vec<Option<Run>> = vec![None; f.commits.len()];
    let mut events: Vec<(i64, Line)> = vec![];
    let (mut runs, mut red) = (0, 0);
    for r in &f.runs {
        // A row with no creation time is skipped, as `builds::parse` skips it.
        let Some(created) = crate::fleet::ts(&r.created_at) else {
            continue;
        };
        let on_commit = shas.get(r.sha.as_str()).copied();
        let mine = !f.scoped
            || on_commit.is_some()
            || r.prs.iter().any(|n| prs.contains(n))
            || heads.contains(r.branch.as_str());
        if !mine {
            continue;
        }
        runs += 1;
        let mut r = r.clone();
        r.settle(created, now);
        red += usize::from(r.state == "red");
        if let Some(i) = on_commit {
            if rank(&r.state) > ci[i].as_ref().map_or(0, |w| rank(&w.state)) {
                ci[i] = Some(r);
            }
        } else if matches!(r.state.as_str(), "red" | "running" | "queued") {
            events.push((
                r.started,
                Line {
                    line: format!("CI      {} {} on {}", r.workflow, r.state, r.branch),
                    level: r.level,
                    url: r.url,
                },
            ));
        }
    }
    let mut ci_red = 0;
    for (c, worst) in f.commits.iter().zip(ci) {
        ci_red += usize::from(worst.as_ref().is_some_and(|w| w.state == "red"));
        let (tail, level) = worst.map_or((String::new(), Level::Ok), |w| {
            (format!("  CI {}", w.state), w.level)
        });
        events.push((
            c.at,
            Line {
                line: format!("commit  {}{tail}", c.subject),
                level,
                url: String::new(),
            },
        ));
    }
    let mut pr_event = |at: Option<i64>, what: &str, p: &Pr| {
        if let Some(at) = at.filter(|a| *a >= f.since) {
            events.push((
                at,
                Line {
                    line: format!("PR      #{} {what}: {}", p.number, p.title),
                    level: Level::Ok,
                    url: p.url.clone(),
                },
            ));
        }
    };
    for p in &f.prs {
        pr_event(p.created, "opened", p);
        match p.state.as_str() {
            // A merge on the branch is its commit's line; one elsewhere is said here.
            "merged" if !merged_here.contains(&p.number) => pr_event(p.merged, "merged", p),
            "closed" => pr_event(p.closed, "closed unmerged", p),
            _ => {}
        }
    }
    for t in &f.tags {
        events.push((
            t.at,
            Line {
                line: format!("tag     {}", t.tag),
                ..Default::default()
            },
        ));
    }
    let mut deploys = 0;
    for ch in &f.channels {
        for d in ch.deploys.history.iter().filter(|d| d.at >= f.since) {
            deploys += 1;
            events.push((
                d.at,
                Line {
                    line: format!("deploy  {} {} {}", ch.id, d.version, d.state),
                    // Amber, as the Releases tab says a failed deploy.
                    level: if d.failed() { Level::Warn } else { Level::Ok },
                    url: d.url.clone().unwrap_or_default(),
                },
            ));
        }
    }
    // Newest first; the stable sort keeps a run's commit above the PR opened in the same second.
    events.sort_by_key(|(at, _)| std::cmp::Reverse(*at));
    let older = events.len().saturating_sub(crate::layout::FOLD_ROWS);
    let lines = events
        .into_iter()
        .take(crate::layout::FOLD_ROWS)
        .map(|(at, mut l)| {
            l.line = format!("{}  {}", crate::pipeline::stamp(at, now), l.line);
            l
        })
        .collect();
    Timeline {
        says: says(f, ci_red, runs, red, deploys),
        lines,
        older,
        notes: f.notes.clone(),
    }
}

/// The head: what the window holds, each kind with a count, none that is zero.
fn says(f: &Facts, ci_red: usize, runs: usize, red: usize, deploys: usize) -> String {
    let n = |k: usize, one: &str, many: &str| match k {
        0 => None,
        1 => Some(format!("1 {one}")),
        k => Some(format!("{k} {many}")),
    };
    let mut parts: Vec<String> = vec![];
    if let Some(mut c) = n(f.commits.len(), "commit", "commits") {
        if ci_red > 0 {
            c += &format!(" ({ci_red} red on CI)");
        }
        parts.push(c);
    }
    parts.extend(n(f.prs.len(), "PR", "PRs"));
    parts.extend(n(runs, "run", "runs"));
    if red > 0 {
        parts.push(format!("{red} red"));
    }
    parts.extend(n(f.tags.len(), "tag", "tags"));
    parts.extend(n(deploys, "deploy", "deploys"));
    if parts.is_empty() {
        format!("nothing in {DAYS}d")
    } else {
        format!("{DAYS}d: {}", parts.join(", "))
    }
}

/// The timeline for `name` (already a safe name) and its `channels`, and an error line per source
/// that failed: the rest still shows. None only when `project-timeline` gave nothing to read.
pub fn read(
    runner: &dyn Runner,
    name: &str,
    channels: Vec<Release>,
    now: i64,
) -> (Option<Timeline>, Vec<String>) {
    let argv: Vec<String> = ["project-timeline", "--days", &DAYS.to_string(), name]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let facts = runner.run(&argv).and_then(|o| {
        serde_json::from_str::<Facts>(&o).map_err(|e| format!("project-timeline: {e}"))
    });
    match facts {
        Ok(mut f) => {
            f.channels = channels;
            let errors = f.errors.iter().map(|e| format!("timeline: {e}")).collect();
            (Some(build(&f, now)), errors)
        }
        Err(e) => (None, vec![format!("project-timeline: {e}")]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(h: u32, m: u32) -> i64 {
        chrono::Local
            .with_ymd_and_hms(2026, 11, 8, h, m, 0)
            .unwrap()
            .timestamp()
    }

    fn iso(t: i64) -> String {
        chrono::DateTime::from_timestamp(t, 0).unwrap().to_rfc3339()
    }

    fn run(sha: &str, branch: &str, conclusion: Option<&str>, t: i64, prs: &[u64]) -> Run {
        Run {
            workflow: "Tests".into(),
            branch: branch.into(),
            sha: sha.into(),
            status: if conclusion.is_some() {
                "completed"
            } else {
                "in_progress"
            }
            .into(),
            conclusion: conclusion.map(String::from),
            created_at: iso(t),
            started_at: Some(iso(t)),
            prs: prs.to_vec(),
            url: format!("https://x/runs/{sha}"),
            ..Default::default()
        }
    }

    /// A scoped project: one merged PR on main with a red run on its commit, an open PR with a
    /// red run on its branch, a green run on the PR branch, a run of some other app, a tag and
    /// a failed deploy.
    fn facts() -> Facts {
        Facts {
            since: at(0, 0),
            branch: "main".into(),
            scoped: true,
            commits: vec![
                Commit {
                    sha: "c2".into(),
                    at: at(14, 2),
                    subject: "fix(web): keep the cart (#12)".into(),
                    prs: vec![12],
                },
                Commit {
                    sha: "c1".into(),
                    at: at(9, 0),
                    subject: "chore(web): bump".into(),
                    ..Default::default()
                },
            ],
            prs: vec![
                Pr {
                    number: 12,
                    title: "fix(web): keep the cart".into(),
                    state: "merged".into(),
                    created: Some(at(10, 0)),
                    merged: Some(at(14, 2)),
                    branch: "agent-3/cart".into(),
                    url: "https://x/pull/12".into(),
                    ..Default::default()
                },
                Pr {
                    number: 13,
                    title: "feat(web): menu".into(),
                    state: "open".into(),
                    created: Some(at(15, 0)),
                    branch: "agent-4/menu".into(),
                    url: "https://x/pull/13".into(),
                    ..Default::default()
                },
            ],
            runs: vec![
                run("c2", "main", Some("success"), at(14, 3), &[]),
                run("c2", "main", Some("failure"), at(14, 4), &[]),
                run("c1", "main", Some("cancelled"), at(9, 1), &[]),
                run("h13", "agent-4/menu", Some("failure"), at(15, 5), &[13]),
                run("h13b", "agent-4/menu", None, at(15, 30), &[]),
                run("h12", "agent-3/cart", Some("success"), at(10, 5), &[12]),
                run("other", "agent-9/api", Some("failure"), at(11, 0), &[99]),
                Run {
                    created_at: "not a time".into(),
                    ..run("c1", "main", Some("failure"), at(9, 2), &[])
                },
            ],
            tags: vec![Tag {
                tag: "web-v1.2.0".into(),
                at: at(14, 30),
            }],
            channels: vec![Release {
                id: "web-prod".into(),
                deploys: crate::releases::Deploys {
                    history: vec![
                        crate::releases::Deploy {
                            version: "v1.2.0".into(),
                            state: "fail".into(),
                            at: at(14, 45),
                            url: Some("https://x/runs/d".into()),
                            ..Default::default()
                        },
                        crate::releases::Deploy {
                            version: "v1.1.0".into(),
                            state: "ok".into(),
                            at: at(0, 0) - 1,
                            url: None,
                            ..Default::default()
                        },
                    ],
                    ..Default::default()
                },
                ..Default::default()
            }],
            notes: vec!["PRs: the newest 100 of those updated in the window only".into()],
            errors: vec![],
        }
    }

    #[test]
    fn the_timeline_joins_runs_to_their_commits_and_lists_only_what_is_not_green() {
        let t = build(&facts(), at(16, 0));
        let lines: Vec<&str> = t.lines.iter().map(|l| l.line.as_str()).collect();
        assert_eq!(
            lines,
            [
                "15:30  CI      Tests running on agent-4/menu",
                "15:05  CI      Tests red on agent-4/menu",
                "15:00  PR      #13 opened: feat(web): menu",
                "14:45  deploy  web-prod v1.2.0 fail",
                "14:30  tag     web-v1.2.0",
                "14:02  commit  fix(web): keep the cart (#12)  CI red",
                "10:00  PR      #12 opened: fix(web): keep the cart",
                "09:00  commit  chore(web): bump",
            ],
            "a merged PR is its commit's line; green, cancelled and other apps' runs are not listed"
        );
        let level = |s: &str| t.lines.iter().find(|l| l.line.contains(s)).unwrap().level;
        assert_eq!(level("CI red"), Level::Bad);
        assert_eq!(
            level("fail"),
            Level::Warn,
            "a failed deploy is amber, as on Releases"
        );
        assert_eq!(level("running"), Level::Ok);
        assert_eq!(level("bump"), Level::Ok);
        assert_eq!(
            t.says, "7d: 2 commits (1 red on CI), 2 PRs, 6 runs, 2 red, 1 tag, 1 deploy",
            "the other app's run is not counted"
        );
        assert_eq!(t.older, 0);
        assert_eq!(t.notes.len(), 1);
        assert_eq!(t.lines[0].url, "https://x/runs/h13b");
    }

    #[test]
    fn an_unscoped_project_owns_every_run_and_a_merge_off_the_branch_is_said_on_the_pr() {
        let mut f = facts();
        f.scoped = false;
        f.commits.remove(0);
        let t = build(&f, at(16, 0));
        let all = t
            .lines
            .iter()
            .map(|l| l.line.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all.contains("Tests red on agent-9/api"), "{all}");
        assert!(all.contains("#12 merged: fix(web)"), "{all}");
        assert!(t.says.contains("7 runs, 3 red"), "{}", t.says);
    }

    #[test]
    fn the_lines_stop_at_the_fold_cap_and_say_how_many_are_older() {
        let f = Facts {
            commits: (0..60)
                .map(|i| Commit {
                    sha: format!("s{i}"),
                    at: at(12, 0) - i,
                    subject: format!("c{i}"),
                    ..Default::default()
                })
                .collect(),
            ..Facts::default()
        };
        let t = build(&f, at(16, 0));
        assert_eq!(t.lines.len(), crate::layout::FOLD_ROWS);
        assert_eq!(t.older, 10);
        assert!(t.lines[0].line.ends_with("c0"));
        assert_eq!(t.says, "7d: 60 commits");
        assert_eq!(build(&Facts::default(), 0).says, "nothing in 7d");
    }

    struct Fake(Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv, ["project-timeline", "--days", "7", "web"]);
            self.0.clone()
        }
    }

    #[test]
    fn a_failed_source_is_named_and_a_failed_read_leaves_no_timeline() {
        let ok = r#"{"commits":[{"sha":"a","at":1,"subject":"x"}],"errors":["gh pr list: 403"]}"#;
        let (t, e) = read(&Fake(Ok(ok.into())), "web", vec![], 2);
        assert_eq!(t.unwrap().says, "7d: 1 commit");
        assert_eq!(e, ["timeline: gh pr list: 403"]);
        let (t, e) = read(&Fake(Err("exit 2".into())), "web", vec![], 2);
        assert!(t.is_none());
        assert_eq!(e, ["project-timeline: exit 2"]);
    }
}
