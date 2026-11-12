//! The joins between the release stores, computed in this one place for both surfaces and for
//! `hub releases check`. The collectors write raw facts only: `release-state refresh` (each
//! project's tag history with the PRs each tag holds, each channel's Deployments and pin),
//! schedules-sync (the runs ledger and the PR store), agent-queue (each item's PRs, row and
//! session) and fleet-sessions (who sits on which branch). A link between two of them is never
//! stored, so it cannot drift from the facts it joins. The joins (the Links table of
//! docs/operations/release-state.md, "Relationships"):
//!
//! - release -> channels: a Deployment's version, else its commit; or the pin ([`reached`]).
//! - run -> release: the Deployment whose URL names the run, else a run on the tag itself.
//! - run -> PR: a run on a PR's merge commit, else on its branch while it was open.
//! - PR -> item -> row and session: the item whose `pr:` names it.
//! - run -> owner: the live session on its branch, else the session of its PR's item.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use project_map::Registry;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::builds::{self, Run};
use crate::pipeline::stamp;
use crate::queue::{self, Item};
use crate::releases::{self, Deploy, Release};
use crate::session_actions::Runner;

/// Branches that belong to no session or PR: a session sitting on one is not what ran it.
pub const SHARED_BRANCHES: [&str; 4] = ["main", "master", "develop", "HEAD"];

/// How far back `check` holds the stores to each other: the runs ledger's window.
const CHECK_SECS: i64 = crate::builds::KEEP_DAYS * 86400;

/// One tag of a project's line as the collector read it from git.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Tag {
    pub tag: String,
    /// The bare version (`1.19.0`, `0.5.0-shapecity3`): the key a lab version and a store's
    /// version string join on.
    pub version: String,
    pub sha: Option<String>,
    /// git's creatordate: the tagger date, or a lightweight tag's commit date (a lower bound).
    pub at: Option<i64>,
    /// The release before it on its own history, the changelog's range start.
    pub prev: Option<String>,
    /// The PRs merged in prev..tag, by number in the line's `repo`.
    pub prs: Vec<u64>,
}

/// A project's tag history: `release` is its own release family, `build` its per-build tags
/// (the registry's `buildTags`) while it has none, `none` neither.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Line {
    pub line: String,
    pub glob: Option<String>,
    /// The checkout's origin as the PR store keys it: `owner/repo`, `host/owner/repo` off GitHub.
    pub repo: Option<String>,
    pub error: Option<String>,
    pub tags: Vec<Tag>,
}

/// One channel a release reached: a successful Deployment of it, or the gitops pin that names it.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Reached {
    pub id: String,
    pub channel: String,
    /// When: the Deployment's time, or when the pin took the value (the gitops PR's merge).
    pub at: Option<i64>,
    /// `deploy` (a GitHub Deployment) or `pin` (the file a gitops target reads).
    pub how: String,
    /// The run that made the Deployment, its page; None for a pin or a Deployment with no URL.
    pub run: Option<String>,
}

/// One release of an app with what it is joined to, newest first: the opened app's history.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Shipment {
    pub tag: String,
    pub version: String,
    pub sha: Option<String>,
    pub at: Option<i64>,
    pub prev: Option<String>,
    pub reached: Vec<Reached>,
    pub prs: Vec<u64>,
    /// The board rows its PRs' items worked (`agent-runtime:ar-1655`).
    pub rows: Vec<String>,
    /// The RELEASED cell: `11-10 22:07`, `not read` when git gave no date.
    pub at_text: String,
    /// The PREV cell: the release before it, `first tag` for the line's first.
    pub prev_text: String,
    /// The REACHED cell: `beta 11-10, testflight (pin)`; `not recorded` when no channel says
    /// so, `none declared` when the app declares no channel.
    pub reached_text: String,
    /// The PRS cell: `#12, #13`, `none merged` with none.
    pub prs_text: String,
    /// The ROWS cell: `ar-1655, ar-1660`; `none merged` with no PRs, `before 2026-11-11` for a
    /// release before the links were held, `not recorded` after.
    pub rows_text: String,
}

/// The release a run made or ran for.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct RunRelease {
    pub project: String,
    pub tag: String,
}

/// One PR as the PR store (`schedules-sync prs`, ~/.agent/prs) keeps it.
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Pr {
    pub forge: String,
    /// `owner/repo`, `host/owner/repo` off GitHub.
    pub repo: String,
    pub number: u64,
    /// None for a PR the forge gave no head branch for.
    pub branch: Option<String>,
    /// `OPEN`, `MERGED` or `CLOSED`.
    pub state: String,
    pub title: String,
    pub created_at: Option<String>,
    pub closed_at: Option<String>,
    pub merged_at: Option<String>,
    pub merge_sha: Option<String>,
    pub url: String,
    /// The forge login that opened it; a bot's PR has no board row to name.
    pub author: Option<String>,
}

impl Pr {
    /// Opened by a bot (Dependabot, Renovate, a GitHub App), so no session or row asked for it.
    fn by_bot(&self) -> bool {
        self.author.as_deref().is_some_and(|a| {
            let a = a.to_ascii_lowercase();
            a.ends_with("[bot]") || a.starts_with("app/") || a == "dependabot" || a == "renovate"
        })
    }
}

/// One repo's line in the PR store's sync record (`schedules-sync prs`, sync.json).
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Synced {
    pub synced_at: Option<String>,
    pub error: Option<String>,
}

/// The PR store's sync record, by repo as the store keys it.
pub fn read_sync(dir: &Path) -> Result<HashMap<String, Synced>, String> {
    #[derive(Deserialize, Default)]
    #[serde(default)]
    struct File {
        repos: HashMap<String, Synced>,
    }
    let p = dir.join("sync.json");
    let raw = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    serde_json::from_str::<File>(&raw)
        .map(|f| f.repos)
        .map_err(|e| format!("{}: {e}", p.display()))
}

/// The facts `release-state refresh` reads for the link checks: the snapshot's `links`
/// (docs/operations/release-state.md, "Link facts").
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Links {
    /// `RELEASE_NOTES_SINCE` in unix seconds: the links are held from this day on, and a gap
    /// before it is history nothing recorded. 0 in a snapshot written before the facts were.
    pub since: i64,
    /// App repo (its registry key) -> the GitHub environments holding a recorded Deployment.
    pub environments: HashMap<String, Envs>,
    /// App repo -> its workflow files at origin's default branch, on both forges.
    pub workflows: HashMap<String, Workflows>,
    /// Lab project -> its versions but the open one.
    pub versions: HashMap<String, Versions>,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Envs {
    pub slug: String,
    pub names: Vec<String>,
    pub error: Option<String>,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Workflows {
    pub branch: String,
    pub files: Vec<Workflow>,
    pub error: Option<String>,
}

/// One workflow file, and whether its name or a step says it ships something (`DEPLOY_NAMES`,
/// `DEPLOY_MARKERS` in release-state).
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Workflow {
    pub path: String,
    pub deploy: bool,
}

#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Versions {
    pub list: Vec<LabVersion>,
    pub error: Option<String>,
}

/// One lab version note: `v1.18.1`, when the roll froze it, the PRs its frozen rows name.
#[derive(Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct LabVersion {
    pub version: String,
    pub state: String,
    pub rolled: Option<i64>,
    pub prs: Vec<u64>,
}

/// What [`Graph::check`] holds the graph to beyond the stores it joins. A field left empty
/// skips the checks that read it.
#[derive(Default)]
pub struct Facts<'a> {
    /// The runs ledger.
    pub runs: Option<&'a [Run]>,
    pub links: Option<&'a Links>,
    /// Project -> its lab stage, and the ladder the stages climb, lowest first.
    pub stages: HashMap<String, String>,
    pub ladder: &'a [String],
    /// The PR store's sync record.
    pub synced: Option<&'a HashMap<String, Synced>>,
}

/// Where the PR store lives: what schedules-sync writes, `SCHEDULES_PRS_DIR` or ~/.agent/prs.
pub fn prs_dir() -> PathBuf {
    std::env::var_os("SCHEDULES_PRS_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".agent/prs")
        })
}

/// Every PR in the store, one per repo and number (the later line wins), and a line per file
/// or row that did not read.
pub fn read_prs(dir: &Path) -> (Vec<Pr>, Vec<String>) {
    let mut errors = vec![];
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            return (
                vec![],
                vec![format!(
                    "PR store {}: {e} (schedules-sync prs writes it)",
                    dir.display()
                )],
            )
        }
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    files.sort();
    let mut by: HashMap<(String, u64), Pr> = HashMap::new();
    for f in files {
        let text = match std::fs::read_to_string(&f) {
            Ok(t) => t,
            Err(e) => {
                errors.push(format!("{}: {e}", f.display()));
                continue;
            }
        };
        let mut bad = 0;
        for l in text.lines().filter(|l| !l.trim().is_empty()) {
            match serde_json::from_str::<Pr>(l) {
                Ok(p) if p.number > 0 => {
                    by.insert((repo_key(&p.repo), p.number), p);
                }
                _ => bad += 1,
            }
        }
        if bad > 0 {
            errors.push(format!("{}: {bad} unreadable line(s) skipped", f.display()));
        }
    }
    let mut prs: Vec<Pr> = by.into_values().collect();
    prs.sort_by(|a, b| (&a.repo, a.number).cmp(&(&b.repo, b.number)));
    (prs, errors)
}

/// The key two stores agree on for one repo: its owner and name, lower-cased, whatever host or
/// URL form the store wrote (`git.example.com/acme/infra` is `acme/infra`).
pub fn repo_key(repo: &str) -> String {
    let r = repo.trim().trim_end_matches('/').trim_end_matches(".git");
    let mut segs = r.rsplit('/').filter(|s| !s.is_empty());
    match (segs.next(), segs.next()) {
        (Some(name), Some(owner)) => format!("{owner}/{name}").to_lowercase(),
        (Some(name), None) => name.to_lowercase(),
        _ => String::new(),
    }
}

/// One PR ref as an item or a marker writes it: `owner/repo#N`, a forge URL to the PR, or a bare
/// `N` / `#N`, which names no repo.
pub fn pr_ref(s: &str) -> Option<(Option<String>, u64)> {
    let s = s.trim().trim_start_matches("pr:");
    if s.starts_with("https://") || s.starts_with("http://") {
        let segs: Vec<&str> = s.trim_end_matches('/').split('/').collect();
        let at = segs.iter().rposition(|x| *x == "pull" || *x == "pulls")?;
        let n = segs.get(at + 1)?.parse().ok()?;
        let repo = segs.get(at.checked_sub(2)?..at)?.join("/");
        return Some((Some(repo_key(&repo)), n));
    }
    match s.rsplit_once('#') {
        Some((repo, n)) if !repo.is_empty() => Some((Some(repo_key(repo)), n.parse().ok()?)),
        _ => Some((None, s.trim_start_matches('#').parse().ok()?)),
    }
}

/// The repo and run id a run's page names: `.../<owner>/<repo>/actions/runs/<id>[/...]`.
fn run_of(url: &str) -> Option<(String, u64)> {
    let segs: Vec<&str> = url.split('/').collect();
    let at = segs.iter().position(|x| *x == "actions")?;
    if segs.get(at + 1) != Some(&"runs") {
        return None;
    }
    let id = segs.get(at + 2)?.parse().ok()?;
    let repo = segs.get(at.checked_sub(2)?..at)?.join("/");
    Some((repo_key(&repo), id))
}

/// The sessions on each branch, from `state.json`'s live sessions. A branch every session shares
/// (`main`) is no one's, and a branch no session sits on is absent, so a hand-pushed one shows `-`.
pub fn live(state: &Value) -> HashMap<String, String> {
    let mut by_branch: HashMap<String, Vec<String>> = HashMap::new();
    for s in state["sessions"].as_array().into_iter().flatten() {
        let (branch, target) = (
            s["branch"].as_str().unwrap_or_default(),
            s["target"].as_str().unwrap_or_default(),
        );
        if branch.is_empty() || SHARED_BRANCHES.contains(&branch) || target.is_empty() {
            continue;
        }
        let name = crate::fleet::who::name_of(target);
        let names = by_branch.entry(branch.to_string()).or_default();
        if !names.contains(&name) {
            names.push(name);
        }
    }
    by_branch
        .into_iter()
        .map(|(b, n)| (b, n.join(", ")))
        .collect()
}

/// The facts the joins read, borrowed from whoever read them. A surface that has no use for one
/// passes it empty: the joins over it then find nothing, never a wrong link.
pub struct Inputs<'a> {
    pub lines: &'a HashMap<String, Line>,
    pub channels: &'a [Release],
    pub items: &'a [Item],
    pub prs: &'a [Pr],
    /// Branch -> the live sessions on it ([`live`]).
    pub live: &'a HashMap<String, String>,
    /// Resolves a bare `pr:N` through its project's one repo, and declares the targets.
    pub registry: Option<&'a Registry>,
    /// `Links::since`: a release before it has no rows because nothing recorded them.
    pub since: i64,
}

/// An item `pr:` ref that names no repo, on a project with no one repo to read it through.
struct Bare {
    slug: String,
    project: String,
    repos: usize,
}

/// The joins over one read of the stores.
pub struct Graph<'a> {
    i: Inputs<'a>,
    pr_at: HashSet<(String, u64)>,
    on_branch: HashMap<(String, String), Vec<usize>>,
    merged_as: HashMap<(String, String), usize>,
    item_of: HashMap<(String, u64), usize>,
    item_refs: Vec<(usize, String, u64)>,
    bare: Vec<Bare>,
    deployed_by: HashMap<(String, u64), RunRelease>,
    tag_in: HashMap<(String, String), String>,
}

impl<'a> Graph<'a> {
    pub fn new(i: Inputs<'a>) -> Graph<'a> {
        let mut g = Graph {
            pr_at: HashSet::new(),
            on_branch: HashMap::new(),
            merged_as: HashMap::new(),
            item_of: HashMap::new(),
            item_refs: vec![],
            bare: vec![],
            deployed_by: HashMap::new(),
            tag_in: HashMap::new(),
            i,
        };
        for (n, p) in g.i.prs.iter().enumerate() {
            let repo = repo_key(&p.repo);
            g.pr_at.insert((repo.clone(), p.number));
            if let Some(b) = p.branch.as_deref().filter(|b| !b.is_empty()) {
                g.on_branch
                    .entry((repo.clone(), b.to_string()))
                    .or_default()
                    .push(n);
            }
            if let Some(sha) = p.merge_sha.as_deref().filter(|s| !s.is_empty()) {
                g.merged_as.insert((repo, sha.to_string()), n);
            }
        }
        for (n, it) in g.i.items.iter().enumerate() {
            for word in it.pr_refs() {
                let Some((repo, num)) = pr_ref(word) else {
                    continue;
                };
                let repo = match repo {
                    Some(r) => r,
                    None => {
                        // One repo mirrored on two forges is still one repo.
                        let mut repos: Vec<String> =
                            g.i.registry
                                .map_or(vec![], |r| r.repos(&it.project))
                                .iter()
                                .map(|r| repo_key(r))
                                .collect();
                        repos.dedup();
                        if let [one] = &repos[..] {
                            one.clone()
                        } else {
                            g.bare.push(Bare {
                                slug: it.slug.clone(),
                                project: it.project.clone(),
                                repos: repos.len(),
                            });
                            continue;
                        }
                    }
                };
                // A PR two items name is the one that landed it: the item that says merged.
                let key = (repo.clone(), num);
                let keep = g
                    .item_of
                    .get(&key)
                    .is_some_and(|&o| g.i.items[o].merged.is_some() && it.merged.is_none());
                if !keep {
                    g.item_of.insert(key, n);
                }
                g.item_refs.push((n, repo, num));
            }
        }
        for (project, line) in g.i.lines {
            let Some(repo) = line.repo.as_deref().map(repo_key) else {
                continue;
            };
            for t in &line.tags {
                g.tag_in
                    .insert((repo.clone(), t.tag.clone()), project.clone());
            }
        }
        for r in g.i.channels {
            let line = g.i.lines.get(&r.project);
            for d in &r.deploys.history {
                let Some(run) = d.url.as_deref().and_then(run_of) else {
                    continue;
                };
                let tag = line
                    .and_then(|l| l.tags.iter().find(|t| shipped(d, t, &l.tags)))
                    .map_or_else(|| d.version.clone(), |t| t.tag.clone());
                g.deployed_by.insert(
                    run,
                    RunRelease {
                        project: r.project.clone(),
                        tag,
                    },
                );
            }
        }
        g
    }

    /// run -> PR: the PR merged as the run's commit, else the one on its branch that had not
    /// closed when the run started (the oldest, when a branch was reused). A shared branch is
    /// no PR's.
    pub fn run_prs(&self, r: &Run) -> Vec<u64> {
        let repo = repo_key(&r.repo);
        if let Some(&n) = self.merged_as.get(&(repo.clone(), r.sha.clone())) {
            return vec![self.i.prs[n].number];
        }
        if r.branch.is_empty() || SHARED_BRANCHES.contains(&r.branch.as_str()) {
            return vec![];
        }
        let created = crate::fleet::ts(&r.created_at).unwrap_or(0);
        let ts = |s: &Option<String>| s.as_deref().and_then(crate::fleet::ts);
        self.on_branch
            .get(&(repo, r.branch.clone()))
            .into_iter()
            .flatten()
            .map(|&n| &self.i.prs[n])
            .filter(|p| ts(&p.closed_at).is_none_or(|c| c >= created))
            .min_by_key(|p| ts(&p.created_at).unwrap_or(i64::MAX))
            .map(|p| vec![p.number])
            .unwrap_or_default()
    }

    /// Target `id`'s `pinned.deployed` as the registry declares it: `true` for a channel whose
    /// deploys record a GitHub Deployment, `"manual"` for one moved by hand.
    fn deployed(&self, id: &str) -> Option<&Value> {
        self.i.registry?.trackers().find_map(|(_, t)| {
            t.get("targets")?
                .as_array()?
                .iter()
                .find(|x| x.get("id").and_then(Value::as_str) == Some(id))?
                .get("pinned")?
                .get("deployed")
        })
    }

    /// The item that names PR `n` of `repo`.
    fn item(&self, repo: &str, n: u64) -> Option<&Item> {
        self.item_of
            .get(&(repo_key(repo), n))
            .map(|&i| &self.i.items[i])
    }

    /// run -> owner: the live session on its branch, else the session of its PR's item.
    pub fn owner(&self, r: &Run, prs: &[u64]) -> String {
        if let Some(o) = self.i.live.get(&r.branch) {
            return o.clone();
        }
        let mut names: Vec<String> = vec![];
        for n in prs {
            let s = self.item(&r.repo, *n).and_then(|it| it.session.as_deref());
            let name = s.map(|s| crate::home::tmux_name(s).to_string());
            if let Some(name) = name.filter(|x| !x.is_empty() && !names.contains(x)) {
                names.push(name);
            }
        }
        names.join(", ")
    }

    /// run -> release: the Deployment whose URL names the run, else a run on one of the line's
    /// tags (a tag push).
    pub fn release(&self, r: &Run) -> Option<RunRelease> {
        let repo = repo_key(&r.repo);
        if let Some(x) = self.deployed_by.get(&(repo.clone(), r.id)) {
            return Some(x.clone());
        }
        self.tag_in
            .get(&(repo, r.branch.clone()))
            .map(|p| RunRelease {
                project: p.clone(),
                tag: r.branch.clone(),
            })
    }

    /// Each run's PRs, owner and release.
    pub fn join(&self, runs: &mut [Run]) {
        for r in runs {
            r.prs = self.run_prs(r);
            r.owner = self.owner(r, &r.prs);
            r.release = self.release(r);
        }
    }

    /// release -> rows: the board rows of the items that name the tag's PRs.
    fn rows(&self, repo: Option<&str>, prs: &[u64]) -> Vec<String> {
        let mut out: Vec<String> = vec![];
        for n in prs {
            let row = repo
                .and_then(|r| self.item(r, *n))
                .and_then(|it| it.board_row())
                .map(|(p, id)| format!("{p}:{id}"));
            if let Some(row) = row.filter(|r| !out.contains(r)) {
                out.push(row);
            }
        }
        out
    }

    /// `project`'s history (see [`history`]), each release joined to its PRs' rows.
    pub fn history(&self, project: &str, channels: &[Release], now: i64) -> Vec<Shipment> {
        let Some(line) = self.i.lines.get(project) else {
            return vec![];
        };
        let mut h = history(line, channels, now);
        for s in &mut h {
            s.rows = self.rows(line.repo.as_deref(), &s.prs);
            s.rows_text = if !s.rows.is_empty() {
                cell(s.rows.iter().map(|r| {
                    r.split_once(':')
                        .map_or(r.as_str(), |(_, id)| id)
                        .to_string()
                }))
            } else if s.prs.is_empty() {
                "none merged".into()
            } else if s.at.is_some_and(|a| a < self.i.since) {
                format!("before {}", since_day(self.i.since))
            } else {
                "not recorded".into()
            };
        }
        h
    }

    /// Where the stores disagree, one line each, sorted: what `hub releases check` prints.
    /// Inside the ledger's window: a PR an item or a tag names that the store lacks (in a repo
    /// the store holds), and a Deployment naming a run of a repo the ledger holds that the
    /// ledger lacks. Always: a bare `pr:N` on a project with no one repo, a channel that says it
    /// records deploys and has none, a manual one with no reason, a missing telemetry watch, a
    /// tag in two lines. With the link facts, [`Graph::check_links`]; with the sync record, a
    /// stale PR store. A fact `f` leaves empty skips the checks that read it.
    pub fn check(&self, f: &Facts, now: i64) -> Vec<String> {
        let since = now - CHECK_SECS;
        let held: HashSet<String> = self.i.prs.iter().map(|p| repo_key(&p.repo)).collect();
        let mut out: Vec<String> = vec![];
        for (n, repo, num) in &self.item_refs {
            let it = &self.i.items[*n];
            let recent = it
                .finished
                .as_deref()
                .and_then(crate::fleet::ts)
                .is_some_and(|f| f >= since);
            if recent && held.contains(repo) && !self.pr_at.contains(&(repo.clone(), *num)) {
                out.push(format!(
                    "item {}: {repo}#{num} is not in the PR store",
                    it.slug
                ));
            }
        }
        let mut bare: HashMap<(&str, usize), Vec<&str>> = HashMap::new();
        for b in &self.bare {
            let slugs = bare.entry((&b.project, b.repos)).or_default();
            if !slugs.contains(&b.slug.as_str()) {
                slugs.push(&b.slug);
            }
        }
        for ((project, repos), slugs) in bare {
            let what = if repos == 0 {
                "no repo"
            } else {
                "several repos"
            };
            out.push(format!(
                "{project}: {} item(s) name a bare pr:N and {project} has {what} to read it in ({}{})",
                slugs.len(),
                slugs.iter().take(3).copied().collect::<Vec<_>>().join(", "),
                if slugs.len() > 3 { ", ..." } else { "" }
            ));
        }
        let mut lines_of: HashMap<(String, &str), Vec<&str>> = HashMap::new();
        for (project, line) in self.i.lines {
            let Some(repo) = line.repo.as_deref().map(repo_key) else {
                continue;
            };
            for t in &line.tags {
                lines_of
                    .entry((repo.clone(), t.tag.as_str()))
                    .or_default()
                    .push(project);
            }
            if !held.contains(&repo) {
                continue;
            }
            for t in line
                .tags
                .iter()
                .filter(|t| t.at.is_some_and(|a| a >= since))
            {
                for n in t
                    .prs
                    .iter()
                    .filter(|n| !self.pr_at.contains(&(repo.clone(), **n)))
                {
                    out.push(format!(
                        "{project} {}: {repo}#{n} is not in the PR store",
                        t.tag
                    ));
                }
            }
        }
        for ((repo, tag), mut projects) in lines_of {
            if projects.len() > 1 {
                projects.sort();
                out.push(format!(
                    "{repo} tag {tag} is in the lines of {}",
                    projects.join(" and ")
                ));
            }
        }
        for r in self.i.channels.iter().filter(|r| !r.implicit) {
            let who = format!("{} {}", r.project, r.id);
            match self.deployed(&r.id) {
                Some(Value::Bool(true))
                    if r.deploys.error.is_none() && r.deploys.history.is_empty() =>
                {
                    out.push(format!(
                        "{who}: deployed: true and no Deployment recorded (record one, or declare it manual with a reason)"
                    ))
                }
                Some(Value::String(m))
                    if m == "manual" && r.pinned.reason.as_deref().unwrap_or("").is_empty() =>
                {
                    out.push(format!("{who}: deployed: manual with no reason"))
                }
                _ => {}
            }
            for w in r.telemetry.iter().filter(|w| w.state == "missing") {
                out.push(format!("{who}: telemetry watch {} does not exist", w.watch));
            }
        }
        if let Some(runs) = f.runs {
            let ran: HashSet<(String, u64)> =
                runs.iter().map(|r| (repo_key(&r.repo), r.id)).collect();
            let repos: HashSet<&str> = ran.iter().map(|(r, _)| r.as_str()).collect();
            for r in self.i.channels {
                for d in r.deploys.history.iter().filter(|d| d.at >= since) {
                    let Some(run) = d.url.as_deref().and_then(run_of) else {
                        continue;
                    };
                    if repos.contains(run.0.as_str()) && !ran.contains(&run) {
                        out.push(format!(
                            "{} {}: deploy {} names run {}#{} the runs ledger lacks",
                            r.project, r.id, d.version, run.0, run.1
                        ));
                    }
                }
            }
        }
        if let Some(links) = f.links {
            out.extend(self.check_links(links, f, now));
        }
        if let Some(synced) = f.synced {
            for (repo, s) in synced {
                let age = s
                    .synced_at
                    .as_deref()
                    .and_then(crate::fleet::ts)
                    .map(|t| now - t);
                match (&s.error, age) {
                    (Some(e), _) if !e.is_empty() => {
                        out.push(format!("PR store: {repo} did not sync: {e}"))
                    }
                    (_, None) => out.push(format!("PR store: {repo} has never synced")),
                    (_, Some(a)) if a > builds::STALE_SECS => out.push(format!(
                        "PR store: {repo} last synced {}m ago (over {}m)",
                        a / 60,
                        builds::STALE_SECS / 60
                    )),
                    _ => {}
                }
            }
        }
        out.sort();
        out.dedup();
        out
    }

    /// The checks over the link facts, each held from `links.since` on (the earlier gaps are
    /// history nothing recorded): a GitHub environment with recorded Deployments that names no
    /// target, a tag glob that matches nothing on a project the lab has shipped, a successful
    /// run of a recording deploy workflow that resolves to no release, a release tag with no lab
    /// version and a shipped lab version with no tag, a release PR with no board row and a row
    /// frozen into a version its PR did not ship in, and a deploy workflow the registry's
    /// `deployWorkflows` does not map (or that deploys a project below alpha).
    fn check_links(&self, links: &Links, f: &Facts, now: i64) -> Vec<String> {
        let mut out = vec![];
        let reg = self.i.registry;
        let trackers: Vec<(&str, &serde_json::Map<String, Value>)> =
            reg.map_or(vec![], |r| r.trackers().collect());
        let targets: HashMap<&str, &str> = trackers
            .iter()
            .flat_map(|(p, t)| {
                t.get("targets")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|x| x.get("id")?.as_str())
                    .map(move |id| (id, *p))
            })
            .collect();
        let mut keys: Vec<&String> = links.environments.keys().collect();
        keys.sort();
        for key in keys {
            let e = &links.environments[key];
            for name in e.names.iter().filter(|n| !targets.contains_key(n.as_str())) {
                out.push(format!(
                    "{}: environment {name} holds recorded Deployments and no registry target is named {name}",
                    e.slug
                ));
            }
        }
        let shipped_versions = |p: &str| -> Option<&Vec<LabVersion>> {
            links
                .versions
                .get(p)
                .filter(|v| v.error.is_none())
                .map(|v| &v.list)
        };
        let recording = |id: &str| self.deployed(id) == Some(&Value::Bool(true));
        // Workflow path -> the targets it deploys, per app repo (registry key).
        let mut deploys_to: HashMap<(String, &str), Vec<&str>> = HashMap::new();
        for (key, w) in &links.workflows {
            if w.error.is_some() {
                continue;
            }
            let declared = reg
                .and_then(|r| r.tracker(key))
                .and_then(|t| t.get("deployWorkflows"))
                .and_then(Value::as_object);
            let files: HashSet<&str> = w.files.iter().map(|f| f.path.as_str()).collect();
            for (path, v) in declared.into_iter().flatten() {
                if !files.contains(path.as_str()) {
                    out.push(format!(
                        "{key} deployWorkflows {path}: not a workflow on origin/{}",
                        w.branch
                    ));
                }
                match v {
                    Value::Array(ids) => {
                        for id in ids {
                            match id.as_str() {
                                Some(id) if targets.contains_key(id) => deploys_to
                                    .entry((key.clone(), path.as_str()))
                                    .or_default()
                                    .push(id),
                                _ => out.push(format!(
                                    "{key} deployWorkflows {path}: {id} is no registry target"
                                )),
                            }
                        }
                    }
                    Value::String(why) if !why.trim().is_empty() => {}
                    _ => out.push(format!(
                        "{key} deployWorkflows {path}: give the targets it deploys, or a reason it deploys none"
                    )),
                }
            }
            for wf in w.files.iter().filter(|f| f.deploy) {
                if declared.is_some_and(|d| d.contains_key(&wf.path)) {
                    continue;
                }
                let file = wf.path.rsplit('/').next().unwrap_or(&wf.path);
                let early = trackers
                    .iter()
                    .filter(|(p, t)| t.get("repo").and_then(Value::as_str).unwrap_or(p) == key)
                    .filter(|(p, _)| file.contains(p))
                    .find_map(|(p, _)| {
                        let s = f.stages.get(*p)?;
                        below_alpha(s, f.ladder).then_some((*p, s.as_str()))
                    });
                out.push(match early {
                    Some((p, s)) => format!(
                        "{key} {}: deploys {p}, which is {s}: ahead of its stage",
                        wf.path
                    ),
                    None => format!(
                        "{key} {}: a deploy workflow no registry target maps to (add it to deployWorkflows)",
                        wf.path
                    ),
                });
            }
        }
        if let Some(runs) = f.runs {
            let from = links.since.max(now - CHECK_SECS);
            let key_of: HashMap<String, &str> = trackers
                .iter()
                .filter_map(|(k, t)| Some((repo_key(t.get("github")?.as_str()?), *k)))
                .collect();
            for r in runs.iter().filter(|r| {
                r.conclusion.as_deref() == Some("success")
                    && crate::fleet::ts(&r.created_at).is_some_and(|c| c >= from)
            }) {
                let Some(key) = key_of.get(&repo_key(&r.repo)) else {
                    continue;
                };
                let records = deploys_to
                    .get(&(key.to_string(), r.path.as_str()))
                    .is_some_and(|ids| ids.iter().any(|id| recording(id)));
                if records && self.release(r).is_none() {
                    out.push(format!(
                        "{} run {} ({}) deployed and resolves to no release",
                        r.repo, r.id, r.path
                    ));
                }
            }
        }
        let mut projects: Vec<&String> = self.i.lines.keys().collect();
        projects.sort();
        for p in projects {
            let line = &self.i.lines[p];
            let Some(versions) = shipped_versions(p) else {
                continue;
            };
            if line.line == "none" && line.error.is_none() {
                if let Some(g) = &line.glob {
                    if !versions.is_empty() {
                        out.push(format!(
                            "{p}: tag glob {g} matches no tag, and the lab has {} shipped version(s)",
                            versions.len()
                        ));
                    }
                }
            }
            if line.line != "release" {
                continue;
            }
            let repo = line.repo.as_deref().map(repo_key);
            for t in line
                .tags
                .iter()
                .filter(|t| t.at.is_some_and(|a| a >= links.since))
            {
                if plain_version(&t.version)
                    && !versions
                        .iter()
                        .any(|v| v.version.trim_start_matches('v') == t.version)
                {
                    out.push(format!("{p} {}: no lab version v{}", t.tag, t.version));
                }
                let Some(repo) = &repo else { continue };
                for n in &t.prs {
                    let Some(pr) = self
                        .i
                        .prs
                        .iter()
                        .find(|x| x.number == *n && repo_key(&x.repo) == *repo)
                    else {
                        continue;
                    };
                    if !pr.by_bot() && self.item(repo, *n).and_then(Item::board_row).is_none() {
                        out.push(format!("{p} {}: {repo}#{n} has no board row", t.tag));
                    }
                }
            }
            for v in versions
                .iter()
                .filter(|v| v.rolled.is_some_and(|r| r >= links.since))
            {
                let bare = v.version.trim_start_matches('v');
                if !line.tags.iter().any(|t| t.version == bare) {
                    out.push(format!("{p} lab {}: no tag of the line", v.version));
                }
                for n in &v.prs {
                    match line.tags.iter().find(|t| t.prs.contains(n)) {
                        Some(t) if t.version != bare => out.push(format!(
                            "{p} lab {}: row PR #{n} shipped in {}",
                            v.version, t.tag
                        )),
                        Some(_) => {}
                        None => out.push(format!(
                            "{p} lab {}: row PR #{n} is in no tag of the line",
                            v.version
                        )),
                    }
                }
            }
        }
        out
    }
}

/// The link facts the collector could not read: each an error of `hub releases check`, never a
/// clean pass.
pub fn link_errors(links: &Links) -> Vec<String> {
    if links.since == 0 {
        return vec!["the snapshot has no link facts (run release-state refresh)".into()];
    }
    let mut out: Vec<String> = links
        .environments
        .iter()
        .filter_map(|(k, e)| Some(format!("{k} environments: {}", e.error.as_ref()?)))
        .chain(
            links
                .workflows
                .iter()
                .filter_map(|(k, w)| Some(format!("{k} workflows: {}", w.error.as_ref()?))),
        )
        .chain(
            links
                .versions
                .iter()
                .filter_map(|(k, v)| Some(format!("{k} lab versions: {}", v.error.as_ref()?))),
        )
        .collect();
    out.sort();
    out
}

/// `1.19.0`: the versions a lab version note is named for. A build or pre-release tag's version
/// (`0.5.0-shapecity3`) has none to match.
fn plain_version(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// A stage below `alpha` on the ladder (`draft`, `dev`): nothing of it should deploy yet.
fn below_alpha(stage: &str, ladder: &[String]) -> bool {
    let at = |s: &str| ladder.iter().position(|x| x == s);
    matches!((at(stage), at("alpha")), (Some(s), Some(a)) if s < a)
}

/// `2026-11-11`: the day the links are held from.
pub fn since_day(since: i64) -> String {
    chrono::DateTime::from_timestamp(since, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// The checks of `hub releases check`, as two lists: where the stores disagree (`Graph::check`)
/// and which store could not be read. A store not read is an error, never a clean check: its
/// facts would be missing from the comparison.
pub fn audit(runner: &dyn Runner, now: i64) -> (Vec<String>, Vec<String>) {
    let mut errors = vec![];
    let snap = releases::snapshot(runner).unwrap_or_else(|e| {
        errors.push(e);
        Default::default()
    });
    let items = queue::list(runner, "all").unwrap_or_else(|e| {
        errors.push(format!("agent-queue list: {e}"));
        vec![]
    });
    let dir = prs_dir();
    let (prs, e) = read_prs(&dir);
    errors.extend(e);
    let synced = read_sync(&dir).map_err(|e| errors.push(e)).ok();
    let ledger = builds::read(&builds::Paths::from_env(), None, now);
    // The ledger's read reads the PR store too: one line per fault.
    for e in ledger.errors {
        if !errors.contains(&e) {
            errors.push(e);
        }
    }
    errors.extend(link_errors(&snap.links));
    if let Some(e) = &snap.stages_error {
        errors.push(format!("lab stages: {e}"));
    }
    let registry = project_map::cached();
    if registry.is_none() {
        errors.push(format!("{}: not read", project_map::map_path().display()));
    }
    let none = HashMap::new();
    let graph = Graph::new(Inputs {
        lines: &snap.releases,
        channels: &snap.rows,
        items: &items,
        prs: &prs,
        live: &none,
        registry: registry.as_deref(),
        since: snap.links.since,
    });
    let facts = Facts {
        runs: Some(&ledger.rows),
        links: Some(&snap.links),
        stages: snap.stage_names(),
        ladder: &snap.ladder,
        synced: synced.as_ref(),
    };
    (graph.check(&facts, now), errors)
}

/// `#12, #13, #14 +2`: a cell that lists at most three, `-` with none.
fn cell(xs: impl Iterator<Item = String>) -> String {
    let xs: Vec<String> = xs.collect();
    match xs.len() {
        0 => "-".into(),
        n if n <= 3 => xs.join(", "),
        n => format!("{} +{}", xs[..3].join(", "), n - 3),
    }
}

/// Each dependency with the version its prod channel pins (a channel of another env when it has
/// no prod one): `unity-core v0.5.0, audio`.
pub fn deps_text(deps: &[String], channels: &[Release]) -> String {
    if deps.is_empty() {
        return "-".into();
    }
    let pin = |d: &str| {
        let of = |prod: bool| {
            channels
                .iter()
                .find(|r| r.project == d && (r.channel == "prod") == prod)
        };
        of(true)
            .or_else(|| of(false))
            .and_then(|r| r.pinned.value.clone())
            .filter(|v| !v.is_empty())
    };
    deps.iter()
        .map(|d| match pin(d) {
            Some(p) => format!("{d} {p}"),
            None => d.clone(),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Whether a channel's version string names this tag: the tag itself, or its version with or
/// without the `v` (a pin or a store says `v1.2.0` for `app-v1.2.0`).
fn names(value: &str, t: &Tag) -> bool {
    value == t.tag || (!t.version.is_empty() && value.trim_start_matches('v') == t.version)
}

/// Whether a Deployment's commit is the tag's: either may be abbreviated.
fn same_commit(d: Option<&str>, t: Option<&str>) -> bool {
    match (d, t) {
        (Some(d), Some(t)) if d.len() >= 7 && t.len() >= 7 => d.starts_with(t) || t.starts_with(d),
        _ => false,
    }
}

/// Whether a Deployment shipped this tag: its version names the tag, or it names no tag of the
/// line (a build id, a bare version two tags share) and its commit is the tag's. The version
/// wins, so two tags on one commit (an rc and its release) each keep their own deploys.
fn shipped(d: &Deploy, t: &Tag, line: &[Tag]) -> bool {
    names(&d.version, t)
        || (!line.iter().any(|o| names(&d.version, o))
            && same_commit(d.sha.as_deref(), t.sha.as_deref()))
}

/// release -> channels: each channel whose successful Deployment of it (see [`shipped`]) or
/// current pin names the tag. A channel counts once per release, at its earliest successful
/// deploy of it. `line` is every tag of the project's line, `t` among them.
pub fn reached(t: &Tag, line: &[Tag], channels: &[Release]) -> Vec<Reached> {
    let mut out: Vec<Reached> = vec![];
    for r in channels {
        let deployed = r
            .deploys
            .history
            .iter()
            .filter(|d| d.state == "ok" && shipped(d, t, line))
            .min_by_key(|d| d.at);
        let hit = match deployed {
            Some(d) => Some((Some(d.at), "deploy", d.url.clone())),
            None if r.pinned.value.as_deref().is_some_and(|v| names(v, t))
                && r.pinned.at.is_some() =>
            {
                Some((r.pinned.at, "pin", None))
            }
            None => None,
        };
        if let Some((at, how, run)) = hit {
            out.push(Reached {
                id: r.id.clone(),
                channel: r.channel.clone(),
                at,
                how: how.into(),
                run,
            });
        }
    }
    out.sort_by_key(|x| x.at.unwrap_or(i64::MAX));
    out
}

/// An app's history: every tag the collector kept, each joined to the channels it reached and
/// carrying the PRs it holds. Its rows are [`Graph::history`]'s join.
pub fn history(line: &Line, channels: &[Release], now: i64) -> Vec<Shipment> {
    line.tags
        .iter()
        .map(|t| {
            let reached = reached(t, &line.tags, channels);
            let reached_text = if channels.iter().all(|r| r.implicit) {
                "none declared".into()
            } else if reached.is_empty() {
                "not recorded".into()
            } else {
                reached
                    .iter()
                    .map(|x| {
                        let when =
                            x.at.map(|a| format!(" {}", stamp(a, now)))
                                .unwrap_or_default();
                        let pin = if x.how == "pin" { " (pin)" } else { "" };
                        format!("{}{when}{pin}", x.id)
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            Shipment {
                tag: t.tag.clone(),
                version: t.version.clone(),
                sha: t.sha.clone(),
                at: t.at,
                prev: t.prev.clone(),
                at_text: t.at.map_or("not read".into(), |a| stamp(a, now)),
                prev_text: t.prev.clone().unwrap_or_else(|| "first tag".into()),
                reached,
                reached_text,
                prs: t.prs.clone(),
                prs_text: if t.prs.is_empty() {
                    "none merged".into()
                } else {
                    cell(t.prs.iter().map(|n| format!("#{n}")))
                },
                rows: vec![],
                rows_text: "not recorded".into(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::releases::{Deploy, Deploys, Side};
    use std::collections::HashMap;

    fn tag(t: &str, v: &str, at: i64) -> Tag {
        Tag {
            tag: t.into(),
            version: v.into(),
            at: Some(at),
            ..Default::default()
        }
    }

    fn channel(id: &str, history: Vec<(&str, &str, i64)>, pin: Option<(&str, i64)>) -> Release {
        Release {
            project: "app".into(),
            id: id.into(),
            channel: "prod".into(),
            deploys: Deploys {
                history: history
                    .into_iter()
                    .map(|(v, s, at)| Deploy {
                        version: v.into(),
                        state: s.into(),
                        at,
                        ..Default::default()
                    })
                    .collect(),
                ..Default::default()
            },
            pinned: Side {
                value: pin.map(|p| p.0.into()),
                at: pin.map(|p| p.1),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    #[test]
    fn a_tag_reaches_the_channels_that_deployed_or_pin_it() {
        let t = tag("app-v1.2.0", "1.2.0", 100);
        let chans = vec![
            channel(
                "web",
                vec![("v1.2.0", "ok", 300), ("v1.2.0", "ok", 200)],
                None,
            ),
            channel("api", vec![("v1.2.0", "fail", 150)], None),
            channel("flux", vec![], Some(("v1.2.0", 250))),
            channel("old", vec![("v1.1.0", "ok", 90)], Some(("v1.1.0", 80))),
        ];
        let got = reached(&t, std::slice::from_ref(&t), &chans);
        let ids: Vec<(&str, Option<i64>, &str)> = got
            .iter()
            .map(|x| (x.id.as_str(), x.at, x.how.as_str()))
            .collect();
        // The earliest ok deploy, a pin with its date; a failed deploy and another version never.
        assert_eq!(
            ids,
            vec![("web", Some(200), "deploy"), ("flux", Some(250), "pin")]
        );
    }

    #[test]
    fn a_tag_nothing_recorded_says_so() {
        let line = Line {
            line: "build".into(),
            tags: vec![tag("v0.5.0-game3", "0.5.0-game3", 100)],
            ..Default::default()
        };
        let h = history(
            &line,
            &[channel("steam", vec![("v0.5.0-game2", "ok", 50)], None)],
            1000,
        );
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].reached_text, "not recorded");
        // A store that records the build tag itself joins on the tag.
        let h = history(
            &line,
            &[channel("steam", vec![("v0.5.0-game3", "ok", 150)], None)],
            1000,
        );
        assert_eq!(h[0].reached[0].id, "steam");
    }

    #[test]
    fn a_deploy_naming_no_tag_joins_by_its_commit_and_a_named_one_never_does() {
        let mut rc = tag("app-v1.2.0-rc1", "1.2.0-rc1", 100);
        let mut rel = tag("app-v1.2.0", "1.2.0", 110);
        rc.sha = Some("abcdef0123456789".into());
        rel.sha = Some("abcdef0123456789".into());
        let line = vec![rel.clone(), rc.clone()];
        let deploy = |v: &str, sha: &str, at| Deploy {
            version: v.into(),
            state: "ok".into(),
            at,
            sha: Some(sha.into()),
            ..Default::default()
        };
        let mut steam = channel("steam", vec![], None);
        // A build id the upload wrote, on the release's commit (abbreviated): joins both tags of
        // that commit, since nothing tells them apart.
        steam.deploys.history = vec![deploy("20834411", "abcdef0", 200)];
        assert_eq!(reached(&rel, &line, std::slice::from_ref(&steam)).len(), 1);
        // One that names the rc stays the rc's, though the release shares its commit.
        steam.deploys.history = vec![deploy("v1.2.0-rc1", "abcdef0123456789", 120)];
        assert!(reached(&rel, &line, std::slice::from_ref(&steam)).is_empty());
        assert_eq!(reached(&rc, &line, std::slice::from_ref(&steam)).len(), 1);
        // Another commit, or a sha too short to trust, never joins.
        steam.deploys.history = vec![deploy("20834411", "1234567", 200)];
        assert!(reached(&rel, &line, std::slice::from_ref(&steam)).is_empty());
        steam.deploys.history = vec![deploy("20834411", "abc", 200)];
        assert!(reached(&rel, &line, &[steam]).is_empty());
    }

    fn pr(
        repo: &str,
        n: u64,
        branch: &str,
        created: &str,
        closed: Option<&str>,
        merge: Option<&str>,
    ) -> Pr {
        Pr {
            repo: repo.into(),
            number: n,
            branch: Some(branch.into()),
            created_at: Some(created.into()),
            closed_at: closed.map(String::from),
            merge_sha: merge.map(String::from),
            ..Default::default()
        }
    }

    fn item(slug: &str, project: &str, pr: &str, session: &str, row: &str) -> Item {
        Item {
            slug: slug.into(),
            project: project.into(),
            pr: Some(pr.into()),
            session: Some(session.into()),
            row: Some(row.into()),
            merged: Some("abc".into()),
            finished: Some("2026-11-10T12:00:00Z".into()),
            ..Default::default()
        }
    }

    fn run(repo: &str, id: u64, branch: &str, sha: &str, created: &str) -> Run {
        Run {
            repo: repo.into(),
            id,
            branch: branch.into(),
            sha: sha.into(),
            created_at: created.into(),
            ..Default::default()
        }
    }

    fn registry() -> Registry {
        Registry::parse(
            r#"{"trackers": {"app": {"github": "Acme/app"},
                "infra": {"forgejo": "acme/infra"},
                "multi": {"github": "Acme/one", "forgejo": "acme/two"},
                "mirror": {"github": "Acme/mirror", "forgejo": "acme/mirror"}}}"#,
        )
        .unwrap()
    }

    #[test]
    fn refs_and_repos_read_one_key_whatever_the_form() {
        assert_eq!(repo_key("git.example.com/acme/infra"), "acme/infra");
        assert_eq!(repo_key("Kblack0610/.dotfiles"), "kblack0610/.dotfiles");
        assert_eq!(pr_ref("Acme/app#12"), Some((Some("acme/app".into()), 12)));
        assert_eq!(
            pr_ref("https://git.example.com/acme/infra/pulls/7"),
            Some((Some("acme/infra".into()), 7))
        );
        assert_eq!(pr_ref("pr:#9"), Some((None, 9)));
        // negative control: no number is no ref.
        assert_eq!(pr_ref("Acme/app#x"), None);
        assert_eq!(pr_ref("soon"), None);
        assert_eq!(
            run_of("https://github.com/Acme/app/actions/runs/42/job/1"),
            Some(("acme/app".into(), 42))
        );
        assert_eq!(run_of("https://github.com/Acme/app/pull/42"), None);
    }

    #[test]
    fn a_run_is_its_merge_commits_pr_else_the_open_one_on_its_branch() {
        let prs = vec![
            // The branch was used before: that PR closed before the run, so it is not this run's.
            pr(
                "Acme/app",
                1,
                "feat/a",
                "2026-11-01T00:00:00Z",
                Some("2026-11-02T00:00:00Z"),
                None,
            ),
            pr("Acme/app", 2, "feat/a", "2026-11-05T00:00:00Z", None, None),
            pr(
                "Acme/app",
                3,
                "feat/b",
                "2026-11-05T00:00:00Z",
                Some("2026-11-06T00:00:00Z"),
                Some("m3"),
            ),
            // Same branch name, another repo: never joins.
            pr(
                "Acme/other",
                4,
                "feat/a",
                "2026-11-04T00:00:00Z",
                None,
                None,
            ),
        ];
        let reg = registry();
        let (lines, live) = (HashMap::new(), HashMap::new());
        let g = Graph::new(Inputs {
            lines: &lines,
            channels: &[],
            items: &[],
            prs: &prs,
            live: &live,
            registry: Some(&reg),
            since: 0,
        });
        let t = "2026-11-05T01:00:00Z";
        assert_eq!(g.run_prs(&run("acme/app", 1, "feat/a", "s1", t)), [2]);
        // A push to main on PR 3's merge commit is PR 3's; any other main run is no PR's.
        assert_eq!(g.run_prs(&run("Acme/app", 2, "main", "m3", t)), [3]);
        assert!(g.run_prs(&run("Acme/app", 3, "main", "m9", t)).is_empty());
        assert!(g
            .run_prs(&run("Acme/app", 4, "feat/none", "s4", t))
            .is_empty());
    }

    #[test]
    fn an_owner_is_the_live_session_else_the_session_whose_item_landed_the_pr() {
        let prs = vec![
            pr(
                "Acme/app",
                7,
                "feat/a",
                "2026-11-05T00:00:00Z",
                None,
                Some("m7"),
            ),
            pr(
                "git.example.com/acme/infra",
                8,
                "fix/x",
                "2026-11-05T00:00:00Z",
                None,
                None,
            ),
        ];
        let items = vec![
            item(
                "a",
                "app",
                "Acme/app#7",
                "lab:app-agent-1",
                "agent-runtime:ar-1",
            ),
            // A bare ref reads through the project's one repo.
            item("b", "infra", "8", "lab:infra-agent-2", "home:h-2"),
        ];
        let reg = registry();
        let lines = HashMap::new();
        let mut live = HashMap::new();
        let g = |live: &HashMap<String, String>| {
            let mut runs = vec![
                run("Acme/app", 1, "main", "m7", "2026-11-06T00:00:00Z"),
                run("acme/infra", 2, "fix/x", "s", "2026-11-06T00:00:00Z"),
                run("Acme/app", 3, "feat/z", "s", "2026-11-06T00:00:00Z"),
            ];
            Graph::new(Inputs {
                lines: &lines,
                channels: &[],
                items: &items,
                prs: &prs,
                live,
                registry: Some(&reg),
                since: 0,
            })
            .join(&mut runs);
            runs.iter().map(|r| r.owner.clone()).collect::<Vec<_>>()
        };
        assert_eq!(g(&live), ["app-agent-1", "infra-agent-2", ""]);
        // A session sitting on the branch wins over the item.
        live.insert("fix/x".to_string(), "hand-1".to_string());
        assert_eq!(g(&live), ["app-agent-1", "hand-1", ""]);
    }

    #[test]
    fn a_run_is_the_release_its_deploy_names_else_the_tag_it_ran_on() {
        let mut t = tag("app-v1.2.0", "1.2.0", 100);
        t.prs = vec![7];
        let mut lines = HashMap::new();
        lines.insert(
            "app".to_string(),
            Line {
                line: "release".into(),
                repo: Some("Acme/app".into()),
                tags: vec![t],
                ..Default::default()
            },
        );
        let mut ch = channel("web", vec![("v1.2.0", "ok", 300)], None);
        ch.deploys.history[0].url = Some("https://github.com/Acme/app/actions/runs/55".into());
        let chans = vec![ch];
        let items = vec![item(
            "a",
            "app",
            "Acme/app#7",
            "lab:s",
            "agent-runtime:ar-1",
        )];
        let live = HashMap::new();
        let g = Graph::new(Inputs {
            lines: &lines,
            channels: &chans,
            items: &items,
            prs: &[],
            live: &live,
            registry: None,
            since: 0,
        });
        let rel = |r: &Run| g.release(r).map(|x| format!("{} {}", x.project, x.tag));
        assert_eq!(
            rel(&run("Acme/app", 55, "main", "x", "")).as_deref(),
            Some("app app-v1.2.0")
        );
        assert_eq!(
            rel(&run("Acme/app", 9, "app-v1.2.0", "x", "")).as_deref(),
            Some("app app-v1.2.0")
        );
        // negative control: the same run id in another repo, and a branch that is no tag.
        assert_eq!(rel(&run("Acme/other", 55, "main", "x", "")), None);
        assert_eq!(rel(&run("Acme/app", 9, "feat/a", "x", "")), None);
        // release -> deploy run, PRs and rows on the history.
        let h = g.history("app", &chans, 1000);
        assert_eq!(
            h[0].reached[0].run.as_deref(),
            Some("https://github.com/Acme/app/actions/runs/55")
        );
        assert_eq!(
            (h[0].prs_text.as_str(), h[0].rows_text.as_str()),
            ("#7", "ar-1")
        );
    }

    #[test]
    fn check_names_each_store_that_disagrees_and_nothing_it_cannot_judge() {
        let now = 2_000_000_000;
        let mut t = tag("app-v1.2.0", "1.2.0", now - 100);
        t.prs = vec![7, 9];
        let mut lines = HashMap::new();
        lines.insert(
            "app".to_string(),
            Line {
                repo: Some("Acme/app".into()),
                tags: vec![t],
                ..Default::default()
            },
        );
        let mut ch = channel(
            "web",
            vec![("v1.2.0", "ok", now - 50), ("v1.1.0", "ok", now - 60)],
            None,
        );
        ch.project = "app".into();
        ch.deploys.history[0].url = Some("https://github.com/Acme/app/actions/runs/55".into());
        ch.deploys.history[1].url = Some("https://github.com/Acme/app/actions/runs/56".into());
        let prs = vec![pr(
            "Acme/app",
            7,
            "feat/a",
            "2026-11-05T00:00:00Z",
            None,
            None,
        )];
        let mut items = vec![
            item("a", "app", "Acme/app#7 Acme/app#8", "lab:s", "r:1"),
            // Two bare refs on one item are one item.
            item("b", "multi", "#3 #4", "lab:s", "r:2"),
            // One repo on two forges reads a bare ref through it.
            item("d", "mirror", "#5", "lab:s", "r:4"),
            // A repo the store does not hold is not judged.
            item("c", "app", "Elsewhere/x#1", "lab:s", "r:3"),
        ];
        for it in &mut items {
            it.finished = Some(
                chrono::DateTime::from_timestamp(now - 10, 0)
                    .unwrap()
                    .to_rfc3339(),
            );
        }
        let reg = registry();
        let live = HashMap::new();
        let chans = vec![ch];
        let g = Graph::new(Inputs {
            lines: &lines,
            channels: &chans,
            items: &items,
            prs: &prs,
            live: &live,
            registry: Some(&reg),
            since: 0,
        });
        let runs = vec![run("Acme/app", 55, "main", "x", "")];
        assert_eq!(
            g.check(&Facts { runs: Some(&runs), ..Default::default() }, now),
            [
                "app app-v1.2.0: acme/app#9 is not in the PR store",
                "app web: deploy v1.1.0 names run acme/app#56 the runs ledger lacks",
                "item a: acme/app#8 is not in the PR store",
                "multi: 1 item(s) name a bare pr:N and multi has several repos to read it in (b)",
            ]
        );
        // With every fact in place, nothing.
        let mut whole = prs.clone();
        whole.push(pr("Acme/app", 8, "x", "2026-11-05T00:00:00Z", None, None));
        whole.push(pr("Acme/app", 9, "y", "2026-11-05T00:00:00Z", None, None));
        let items = &items[..1];
        let g = Graph::new(Inputs {
            lines: &lines,
            channels: &chans,
            items,
            prs: &whole,
            live: &live,
            registry: Some(&reg),
            since: 0,
        });
        let runs = vec![
            run("Acme/app", 55, "main", "x", ""),
            run("Acme/app", 56, "main", "x", ""),
        ];
        assert!(g.check(&Facts { runs: Some(&runs), ..Default::default() }, now).is_empty());
    }

    #[test]
    fn the_link_checks_name_each_gap_from_the_day_they_are_held() {
        let since = 1_794_384_000; // 2026-11-11
        let now = since + 1000;
        let ts = |t: i64| chrono::DateTime::from_timestamp(t, 0).unwrap().to_rfc3339();
        let reg = Registry::parse(
            r#"{"trackers": {
                "app": {"github": "Acme/app", "type": "app", "targets": [
                    {"id": "app-prod", "pinned": {"deployed": true}},
                    {"id": "app-steam", "pinned": {"deployed": "manual"}}],
                  "deployWorkflows": {
                    ".github/workflows/deploy.yml": ["app-prod"],
                    ".github/workflows/gone.yml": "retired",
                    ".github/workflows/bad.yml": ["nope"],
                    ".github/workflows/odd.yml": 3}},
                "early": {"repo": "app", "type": "app"},
                "lib": {"github": "Acme/lib", "type": "app"}}}"#,
        )
        .unwrap();
        let mut old = tag("app-v1.2.0", "1.2.0", since - 100);
        old.prs = vec![10];
        let mut new = tag("app-v1.3.0", "1.3.0", since + 10);
        new.prs = vec![11, 12, 14];
        let mut lines = HashMap::new();
        lines.insert(
            "app".to_string(),
            Line {
                line: "release".into(),
                repo: Some("Acme/app".into()),
                tags: vec![new.clone(), old],
                ..Default::default()
            },
        );
        lines.insert(
            "early".to_string(),
            Line {
                line: "build".into(),
                repo: Some("Acme/app".into()),
                tags: vec![new],
                ..Default::default()
            },
        );
        lines.insert(
            "lib".to_string(),
            Line {
                line: "none".into(),
                glob: Some("lib-v*".into()),
                repo: Some("Acme/lib".into()),
                ..Default::default()
            },
        );
        let mut prod = channel("app-prod", vec![], None);
        prod.pinned.source = "none".into();
        prod.telemetry = vec![crate::releases::Watch {
            watch: "app-errors".into(),
            state: "missing".into(),
            ..Default::default()
        }];
        let mut steam = channel("app-steam", vec![], None);
        steam.pinned.source = "manual".into();
        let chans = vec![prod, steam];
        let human = |n| Pr {
            author: Some("kb".into()),
            ..pr("Acme/app", n, "x", "2026-11-05T00:00:00Z", None, None)
        };
        let prs = vec![
            human(10),
            human(11),
            Pr {
                author: Some("dependabot[bot]".into()),
                ..human(12)
            },
            human(14),
        ];
        let mut items = vec![item("a", "app", "Acme/app#11", "lab:s", "agent-runtime:ar-1")];
        items[0].finished = Some(ts(now - 10));
        let v = |version: &str, rolled: i64, prs: Vec<u64>| LabVersion {
            version: version.into(),
            state: "shipped".into(),
            rolled: Some(rolled),
            prs,
        };
        let mut links = Links {
            since,
            ..Default::default()
        };
        links.environments.insert(
            "app".into(),
            Envs {
                slug: "Acme/app".into(),
                names: vec!["app-prod".into(), "production".into()],
                error: None,
            },
        );
        let wf = |p: &str, deploy| Workflow {
            path: format!(".github/workflows/{p}"),
            deploy,
        };
        links.workflows.insert(
            "app".into(),
            Workflows {
                branch: "main".into(),
                files: vec![
                    wf("deploy.yml", true),
                    wf("deploy-early.yml", true),
                    wf("image.yml", true),
                    wf("ci.yml", false),
                    wf("bad.yml", false),
                    wf("odd.yml", false),
                ],
                error: None,
            },
        );
        links.versions.insert(
            "app".into(),
            Versions {
                // v1.1.0 was rolled before the day and has no tag: history, not a red.
                list: vec![v("v1.1.0", since - 50, vec![]), v("v1.4.0", since + 5, vec![11, 13])],
                error: None,
            },
        );
        links.versions.insert(
            "lib".into(),
            Versions {
                list: vec![v("v0.1.0", since - 50, vec![])],
                error: None,
            },
        );
        let deploy_run = |id, conclusion: &str| Run {
            path: ".github/workflows/deploy.yml".into(),
            conclusion: Some(conclusion.into()),
            ..run("Acme/app", id, "main", "s", &ts(since + 20))
        };
        let runs = vec![deploy_run(70, "success"), deploy_run(71, "failure")];
        let mut synced = HashMap::new();
        let sync = |at: Option<i64>, error: Option<&str>| Synced {
            synced_at: at.map(ts),
            error: error.map(String::from),
        };
        synced.insert("Acme/app".to_string(), sync(Some(now - 60), None));
        synced.insert("Acme/lib".to_string(), sync(Some(now - 4000), None));
        synced.insert("Acme/x".to_string(), sync(None, Some("HTTP 403")));
        let live = HashMap::new();
        let g = Graph::new(Inputs {
            lines: &lines,
            channels: &chans,
            items: &items,
            prs: &prs,
            live: &live,
            registry: Some(&reg),
            since,
        });
        let ladder: Vec<String> = ["draft", "dev", "alpha", "beta", "prod"].map(String::from).into();
        let facts = Facts {
            runs: Some(&runs),
            links: Some(&links),
            stages: HashMap::from([("early".to_string(), "draft".to_string())]),
            ladder: &ladder,
            synced: Some(&synced),
        };
        assert_eq!(
            g.check(&facts, now),
            [
                "Acme/app run 70 (.github/workflows/deploy.yml) deployed and resolves to no release",
                "Acme/app: environment production holds recorded Deployments and no registry target is named production",
                "PR store: Acme/lib last synced 66m ago (over 30m)",
                "PR store: Acme/x did not sync: HTTP 403",
                "acme/app tag app-v1.3.0 is in the lines of app and early",
                "app .github/workflows/deploy-early.yml: deploys early, which is draft: ahead of its stage",
                "app .github/workflows/image.yml: a deploy workflow no registry target maps to (add it to deployWorkflows)",
                "app app-prod: deployed: true and no Deployment recorded (record one, or declare it manual with a reason)",
                "app app-prod: telemetry watch app-errors does not exist",
                "app app-steam: deployed: manual with no reason",
                "app app-v1.3.0: acme/app#14 has no board row",
                "app app-v1.3.0: no lab version v1.3.0",
                "app deployWorkflows .github/workflows/bad.yml: \"nope\" is no registry target",
                "app deployWorkflows .github/workflows/gone.yml: not a workflow on origin/main",
                "app deployWorkflows .github/workflows/odd.yml: give the targets it deploys, or a reason it deploys none",
                "app lab v1.4.0: no tag of the line",
                "app lab v1.4.0: row PR #11 shipped in app-v1.3.0",
                "app lab v1.4.0: row PR #13 is in no tag of the line",
                "lib: tag glob lib-v* matches no tag, and the lab has 1 shipped version(s)",
            ]
        );
        // Without the link facts or the sync record, only the checks over the stores remain.
        let bare = g.check(&Facts { runs: Some(&runs), ..Default::default() }, now);
        assert!(bare.iter().all(|l| !l.contains("lab") && !l.starts_with("PR store")));
        // A release before the day with no row is history nothing recorded, never a red.
        let h = g.history("app", &chans, now);
        assert_eq!(
            h.iter().map(|s| s.rows_text.as_str()).collect::<Vec<_>>(),
            ["ar-1", "before 2026-11-11"]
        );
        assert_eq!(h[1].prev_text, "first tag");
        assert_eq!(
            link_errors(&Links::default()),
            ["the snapshot has no link facts (run release-state refresh)"]
        );
    }

    #[test]
    fn the_store_keeps_one_row_per_pr_the_last_written() {
        let d = std::env::temp_dir().join(format!("hub-prs-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("Acme__app.jsonl"),
            "{\"repo\":\"Acme/app\",\"number\":1,\"state\":\"OPEN\"}\n{\"repo\":\"Acme/app\",\"number\":1,\"state\":\"MERGED\"}\nnot json\n",
        )
        .unwrap();
        std::fs::write(d.join("sync.json"), "{}").unwrap();
        let (prs, errors) = read_prs(&d);
        let (_, missing) = read_prs(&d.join("nope"));
        std::fs::remove_dir_all(&d).unwrap();
        assert_eq!(prs.len(), 1);
        assert_eq!(prs[0].state, "MERGED");
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(missing[0].contains("schedules-sync prs writes it"));
    }
}
