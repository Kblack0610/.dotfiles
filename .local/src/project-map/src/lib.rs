//! The project registry (`project-map.json`), read-only, and its one name index for Rust.
//!
//! Any spelling of a project (a checkout basename, a forge slug, a retired name in its
//! tracker's `names`) maps to its key. `project_canonical` in `project-name.sh` is the shell
//! lookup over the same index, and `tests/fixtures/project-names.tsv` is read by a test of each,
//! so the two cannot diverge. The index order and lookup rule: `docs/operations/release-state.md`,
//! "Project identity".

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

pub struct Registry {
    raw: Value,
    index: HashMap<String, String>,
}

/// `$PROJECT_MAP_FILE`, else the stowed `~/.config/shared-hooks/project-map.json`: the path
/// `project_map_file` in `project-name.sh` resolves.
pub fn map_path() -> PathBuf {
    match std::env::var("PROJECT_MAP_FILE") {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
            .join(".config/shared-hooks/project-map.json"),
    }
}

/// How long `cached()` trusts the registry it holds before it stats the file again. A table
/// sort resolves a name per comparison, and a stat per call made each lookup 1.5us (270ns with
/// this); a hand edit to the registry is seen within this long.
const RECHECK_EVERY: Duration = Duration::from_secs(1);

/// The artifacts a repo's test results are in when its tracker names no `testArtifacts`.
pub const DEFAULT_TEST_ARTIFACTS: &str = "junit-*";

/// The registry at `map_path()`, read again when the file's mtime changes (checked at most once
/// per `RECHECK_EVERY`), so a long-running server follows an edit without a restart. None when
/// there is no registry.
pub fn cached() -> Option<Arc<Registry>> {
    struct Slot {
        path: PathBuf,
        mtime: Option<SystemTime>,
        checked: Instant,
        reg: Option<Arc<Registry>>,
    }
    static CACHE: Mutex<Option<Slot>> = Mutex::new(None);
    let path = map_path();
    let mut slot = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(s) = slot.as_mut().filter(|s| s.path == path) {
        if s.checked.elapsed() < RECHECK_EVERY {
            return s.reg.clone();
        }
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if mtime == s.mtime {
            s.checked = Instant::now();
            return s.reg.clone();
        }
    }
    let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let reg = Registry::from_path(&path).map(Arc::new);
    *slot = Some(Slot {
        path,
        mtime,
        checked: Instant::now(),
        reg: reg.clone(),
    });
    reg
}

/// The project key `name` spells, through the cached registry; see `Registry::canonical`.
pub fn canonical(name: &str) -> String {
    cached().map_or_else(|| fallback(name), |r| r.canonical(name))
}

/// The project a directory belongs to, through the cached registry; see
/// `Registry::project_for_path`. With no registry it is the directory's basename, leading dot
/// stripped, as `resolve_project_name` answers then.
pub fn project_for_path(path: &str) -> String {
    cached().map_or_else(|| fallback(path), |r| r.project_for_path(path))
}

/// What git says about the checkout holding a directory, read off `.git` without running git:
/// the worktree's top, the repo it is a worktree of (the common dir's parent, so every worktree
/// collapses to one checkout), and the branch checked out there.
struct Checkout {
    top: PathBuf,
    repo: PathBuf,
    branch: Option<String>,
}

impl Checkout {
    /// The checkout `dir` is in: the nearest ancestor holding `.git`, a directory for the main
    /// checkout or a `gitdir:` file for a linked worktree. None outside any repo.
    fn find(dir: &Path) -> Option<Checkout> {
        if !dir.is_dir() {
            return None;
        }
        let top = dir
            .ancestors()
            .find(|d| d.join(".git").exists())?
            .to_path_buf();
        let dotgit = top.join(".git");
        let gitdir = if dotgit.is_dir() {
            dotgit
        } else {
            let text = std::fs::read_to_string(&dotgit).ok()?;
            top.join(text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim())
        };
        let common = match std::fs::read_to_string(gitdir.join("commondir")) {
            Ok(c) => gitdir.join(c.trim()),
            Err(_) => gitdir.clone(),
        };
        let common = common.canonicalize().unwrap_or(common);
        let repo = match common.file_name() {
            Some(n) if n == ".git" => common
                .parent()
                .map_or_else(|| top.clone(), Path::to_path_buf),
            _ => common.clone(),
        };
        let branch = std::fs::read_to_string(gitdir.join("HEAD"))
            .ok()
            .and_then(|h| {
                h.trim()
                    .strip_prefix("ref: refs/heads/")
                    .map(str::to_string)
            });
        Some(Checkout { top, repo, branch })
    }
}

/// What a name no registry entry knows reads as: its last path segment, one leading dot stripped,
/// case kept (`Kblack0610/.dotfiles` -> `dotfiles`).
fn fallback(name: &str) -> String {
    let last = name.rsplit('/').find(|s| !s.is_empty()).unwrap_or("");
    last.strip_prefix('.').unwrap_or(last).to_string()
}

/// Each `/`-suffix of `name`, longest first, each as written and without one leading dot,
/// lowercased: the forms the index stores and a lookup tries.
fn suffixes(name: &str) -> Vec<String> {
    let lower = name.to_lowercase();
    let segs: Vec<&str> = lower.split('/').filter(|s| !s.is_empty()).collect();
    let mut out = Vec::new();
    for i in 0..segs.len() {
        let s = segs[i..].join("/");
        let bare = s.strip_prefix('.').unwrap_or(&s).to_string();
        out.push(s);
        if bare != *out.last().unwrap() && !bare.is_empty() {
            out.push(bare);
        }
    }
    out
}

impl Registry {
    /// The registry at `map_path()`, read now. None when it is absent or malformed.
    pub fn load() -> Option<Registry> {
        Self::from_path(&map_path())
    }

    /// None when the file is absent. An unreadable or malformed file is also None, with a
    /// warning on stderr so it never reads as "no registry here".
    pub fn from_path(path: &Path) -> Option<Registry> {
        let text = std::fs::read_to_string(path).ok()?;
        let r = Self::parse(&text);
        if r.is_none() {
            eprintln!("warning: {} is not valid JSON; ignoring it", path.display());
        }
        r
    }

    /// The registry from its JSON text; None when it is not a JSON object.
    pub fn parse(text: &str) -> Option<Registry> {
        let raw: Value = serde_json::from_str(text).ok()?;
        raw.is_object().then(|| Registry::new(raw))
    }

    fn new(raw: Value) -> Registry {
        let mut index = HashMap::new();
        let mut add = |spelling: String, key: &str| {
            if !spelling.is_empty() {
                index.entry(spelling).or_insert_with(|| key.to_string());
            }
        };
        let empty = Map::new();
        let paths = raw
            .get("paths")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let trackers = raw
            .get("trackers")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let mut trackers: Vec<(&String, &Map<String, Value>)> = trackers
            .iter()
            .filter(|(k, _)| k.as_str() != "default")
            .filter_map(|(k, v)| v.as_object().map(|o| (k, o)))
            .collect();
        trackers.sort_by(|a, b| a.0.cmp(b.0));
        // Sorted by path here and in the jq index, never map order: serde_json's `preserve_order`
        // feature, which any crate in the build can switch on, would make it insertion order.
        let mut by_path: Vec<(&String, &str)> = paths
            .iter()
            .filter_map(|(p, v)| v.as_str().map(|v| (p, v)))
            .collect();
        by_path.sort();
        for key in by_path
            .iter()
            .map(|(_, k)| *k)
            .chain(trackers.iter().map(|(k, _)| k.as_str()))
        {
            add(key.to_lowercase(), key);
        }
        for (key, t) in &trackers {
            for n in t
                .get("names")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                add(n.to_lowercase(), key);
            }
            for slug in ["github", "forgejo"]
                .iter()
                .filter_map(|f| t.get(*f).and_then(Value::as_str))
            {
                for s in suffixes(slug) {
                    add(s, key);
                }
            }
        }
        for (path, key) in by_path {
            let base = path.rsplit('/').next().unwrap_or("").to_lowercase();
            let bare = base.strip_prefix('.').unwrap_or(&base).to_string();
            add(base, key);
            add(bare, key);
        }
        Registry { raw, index }
    }

    /// The key `name` spells, or None when no entry names it.
    pub fn lookup(&self, name: &str) -> Option<&str> {
        suffixes(name)
            .iter()
            .find_map(|s| self.index.get(s))
            .map(String::as_str)
    }

    /// The key `name` spells, so an old name keeps working after a rename; a name no entry
    /// knows keeps its last path segment, leading dot stripped (`fallback`).
    pub fn canonical(&self, name: &str) -> String {
        self.lookup(name)
            .map_or_else(|| fallback(name), str::to_string)
    }

    /// True when `name` is itself a project key (a `paths` value or an object tracker other
    /// than `default`), not another spelling of one. The same test as `project_known`.
    pub fn known(&self, name: &str) -> bool {
        self.index.get(&name.to_lowercase()).map(String::as_str) == Some(name)
    }

    /// The tracker entry for `name`, when it is an object (`_comment*` keys are strings).
    pub fn tracker(&self, name: &str) -> Option<&Map<String, Value>> {
        self.raw.get("trackers")?.get(name)?.as_object()
    }

    /// Every object tracker with its key, in the file's order.
    pub fn trackers(&self) -> impl Iterator<Item = (&str, &Map<String, Value>)> {
        self.raw
            .get("trackers")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((k.as_str(), v.as_object()?)))
    }

    /// True when `name` is a value of `paths`: a repo with a registered checkout.
    fn in_paths(&self, name: &str) -> bool {
        self.raw
            .get("paths")
            .and_then(Value::as_object)
            .is_some_and(|m| m.values().any(|v| v.as_str() == Some(name)))
    }

    /// The checkout of repo key `repo` here: the first `paths` key mapped to it that is a
    /// directory. None when no path names it or none is cloned on this machine.
    pub fn checkout(&self, repo: &str) -> Option<PathBuf> {
        self.raw
            .get("paths")?
            .as_object()?
            .iter()
            .filter(|(_, v)| v.as_str() == Some(repo))
            .map(|(k, _)| PathBuf::from(k))
            .find(|p| p.is_dir())
    }

    /// `trackers.<name>.type`: game, app or infra.
    pub fn kind(&self, name: &str) -> Option<String> {
        let t = self.tracker(name)?.get("type")?.as_str()?;
        Some(t.to_string())
    }

    /// `trackers.<name>.repo` is set, or `name` is itself a repo's key (a `paths` value, which
    /// carries no `repo` field).
    pub fn has_repo(&self, name: &str) -> bool {
        let repo = self
            .tracker(name)
            .and_then(|t| t.get("repo"))
            .and_then(Value::as_str);
        repo.is_some_and(|r| !r.is_empty()) || self.in_paths(name)
    }

    /// The forge slugs a project's PRs and runs live under (`github`, then `forgejo`, each
    /// `owner/repo`), following `repo` to the repo's own tracker when the project has none of its
    /// own (a monorepo app is its monorepo's). Empty for a name no tracker knows.
    pub fn repos(&self, name: &str) -> Vec<String> {
        let slugs = |t: &Map<String, Value>| -> Vec<String> {
            ["github", "forgejo"]
                .iter()
                .filter_map(|k| t.get(*k)?.as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        };
        let Some(key) = self.lookup(name) else {
            return vec![];
        };
        let Some(t) = self.tracker(key) else {
            return vec![];
        };
        let own = slugs(t);
        if !own.is_empty() {
            return own;
        }
        t.get("repo")
            .and_then(Value::as_str)
            .and_then(|r| self.lookup(r))
            .filter(|r| *r != key)
            .and_then(|r| self.tracker(r))
            .map(slugs)
            .unwrap_or_default()
    }

    /// The string list `key` on each tracker whose `github` slug is `slug`, compared without
    /// case as GitHub does.
    fn github_list(&self, slug: &str, key: &str) -> Vec<String> {
        let Some(trackers) = self.raw.get("trackers").and_then(Value::as_object) else {
            return vec![];
        };
        trackers
            .values()
            .filter_map(Value::as_object)
            .filter(|t| {
                t.get("github")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty() && s.eq_ignore_ascii_case(slug))
            })
            .filter_map(|t| t.get(key)?.as_array())
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect()
    }

    /// The workflow files whose artifacts (`test_artifacts`) are a repo's test results:
    /// `testWorkflows` on the tracker whose `github` slug is `slug`. Empty for a repo that
    /// declares none, so its runs list no Tests.
    pub fn test_workflows(&self, slug: &str) -> Vec<String> {
        self.github_list(slug, "testWorkflows")
    }

    /// The artifact name globs a repo's test workflows upload their results in: `testArtifacts`
    /// on its tracker, else `junit-*`, what the bats tiers upload.
    pub fn test_artifacts(&self, slug: &str) -> Vec<String> {
        let globs: Vec<String> = self
            .github_list(slug, "testArtifacts")
            .into_iter()
            .filter(|g| !g.is_empty())
            .collect();
        if globs.is_empty() {
            vec![DEFAULT_TEST_ARTIFACTS.to_string()]
        } else {
            globs
        }
    }

    /// The workflow files whose runs build something a person or a deploy then takes: `buildWorkflows`
    /// on the tracker whose `github` slug is `slug`. A run page of one lists the run's artifacts.
    pub fn build_workflows(&self, slug: &str) -> Vec<String> {
        self.github_list(slug, "buildWorkflows")
    }

    /// `artifactStore` on the tracker whose `github` slug is `slug`: the path, in the repo's clone,
    /// of the script that lists a run's artifacts in the home store (`<script> ls "" --run <id>`
    /// prints `<name> <run> <expires> <bytes>` per live one), for a repo whose workflows put there
    /// and not on GitHub. None when the repo's artifacts are GitHub's alone.
    pub fn artifact_store(&self, slug: &str) -> Option<String> {
        let trackers = self.raw.get("trackers")?.as_object()?;
        trackers
            .values()
            .filter_map(Value::as_object)
            .filter(|t| {
                t.get("github")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty() && s.eq_ignore_ascii_case(slug))
            })
            .find_map(|t| t.get("artifactStore")?.as_str().filter(|r| !r.is_empty()))
            .map(str::to_string)
    }

    /// `nightRunner` on the tracker whose `github` slug is `slug`: the agentctl runner that
    /// starts the repo's night set (`scripts/night.json`), so a night member's next start is
    /// that runner's. None when the tracker names none.
    pub fn night_runner(&self, slug: &str) -> Option<String> {
        let trackers = self.raw.get("trackers")?.as_object()?;
        trackers
            .values()
            .filter_map(Value::as_object)
            .filter(|t| {
                t.get("github")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty() && s.eq_ignore_ascii_case(slug))
            })
            .find_map(|t| t.get("nightRunner")?.as_str().filter(|r| !r.is_empty()))
            .map(str::to_string)
    }

    /// `ciStages` on the tracker `name`: the project's CI workflows by run name (`Checks`,
    /// `Tests (affected)`), in pipeline order, the order Releases > Flow draws its CI lanes in.
    /// Empty when the tracker declares none.
    pub fn ci_stages(&self, name: &str) -> Vec<String> {
        self.tracker(name)
            .and_then(|t| t.get("ciStages")?.as_array())
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// The project whose release tag numbers `name`'s versions (stages.md, "Versions"): a key
    /// with `buildTags` whose `repo` is another tracker declaring a `tagGlob`, a game built from
    /// the playground. The one definition: notes applies it (`projects::version_parent_dir`, only
    /// for a sheet with no `Version:` line) and reports it as `version_parent` in
    /// `projects --stats --json`, which the shell (`project_version_owner`) reads.
    pub fn version_parent(&self, name: &str) -> Option<String> {
        let t = self.tracker(name)?;
        t.get("buildTags")?.as_array().filter(|b| !b.is_empty())?;
        let repo = t.get("repo")?.as_str().filter(|r| *r != name)?;
        self.tracker(repo)?
            .get("tagGlob")?
            .as_str()
            .filter(|g| !g.is_empty())?;
        Some(repo.to_string())
    }

    /// Every project [`Registry::version_parent`] gives as `name`, in the file's order.
    pub fn version_children(&self, name: &str) -> Vec<String> {
        self.trackers()
            .map(|(k, _)| k)
            .filter(|k| self.version_parent(k).as_deref() == Some(name))
            .map(str::to_string)
            .collect()
    }

    /// `trackers.<name>.code`: the 2-4 lowercase letters that prefix the project's row ids
    /// (`ar` in `ar-142`), when it is set and well formed. `project-map-doctor` checks it is
    /// unique.
    pub fn code(&self, name: &str) -> Option<String> {
        let c = self.tracker(name)?.get("code")?.as_str()?;
        ((2..=4).contains(&c.len()) && c.bytes().all(|b| b.is_ascii_lowercase()))
            .then(|| c.to_string())
    }

    /// The profile of every `clients` entry: the work profiles.
    fn work_profiles(&self) -> impl Iterator<Item = &str> {
        self.raw
            .get("clients")
            .and_then(Value::as_object)
            .into_iter()
            .flat_map(|m| m.values())
            .filter_map(|c| c.get("profile")?.as_str())
    }

    /// Whether notes profile `profile` is listed on a machine whose own profile is `machine`:
    /// a work profile (one a `clients` entry names) only there, any other everywhere. The work
    /// Mac lists its job and the personal fleet does not; the rule is the `clients` comment in
    /// project-map.json, and `project_visible` in project-name.sh is its shell side.
    pub fn profile_visible(&self, profile: &str, machine: &str) -> bool {
        profile == machine || !self.work_profiles().any(|p| p == profile)
    }

    /// Whether project `name` is listed on a machine whose own profile is `machine`: one whose
    /// tracker has a `client` only where that client's profile is the machine's, and a client
    /// `clients` does not name nowhere, so a typo hides work instead of leaking it.
    pub fn project_visible(&self, name: &str, machine: &str) -> bool {
        // A client that is not a string, or names no profile, hides the project everywhere.
        match self.tracker(name).and_then(|t| t.get("client")) {
            None | Some(Value::Null) => true,
            Some(c) => {
                c.as_str()
                    .and_then(|c| self.raw.get("clients")?.get(c)?.get("profile")?.as_str())
                    == Some(machine)
            }
        }
    }

    /// `paths.<p>`: the key a checkout path is registered under.
    fn path_key(&self, p: &str) -> Option<&str> {
        self.raw.get("paths")?.get(p)?.as_str()
    }

    /// The object tracker whose `repo` is `repo` and whose `path` is `path`, in file order.
    fn app_at(&self, repo: &str, path: &str) -> Option<&str> {
        self.trackers()
            .find(|(_, t)| {
                t.get("repo").and_then(Value::as_str) == Some(repo)
                    && t.get("path").and_then(Value::as_str) == Some(path)
            })
            .map(|(k, _)| k)
    }

    /// True when tracker `name` is an app of repo key `repo` at a non-empty `path`.
    fn app_of(&self, name: &str, repo: &str) -> bool {
        self.tracker(name).is_some_and(|t| {
            t.get("repo").and_then(Value::as_str) == Some(repo)
                && t.get("path")
                    .and_then(Value::as_str)
                    .is_some_and(|p| !p.is_empty())
        })
    }

    /// The project a directory belongs to: the Rust form of `resolve_project_name` in
    /// `project-name.sh`, held to it case by case by `project_for_path_matches_the_shell`. A
    /// worktree is its repo; inside a registered repo the longest repo-relative app `path` wins,
    /// and at the worktree root a `<type>/<app>/<rest>` branch names the app; a reaped worktree
    /// under the worktree root is named by the `<repo>-<slug>` convention; a directory outside
    /// any repo, or in an unregistered repo under the temp dir, is `_unscoped` unless its
    /// basename is a key.
    pub fn project_for_path(&self, abs_path: &str) -> String {
        let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let wt_root = env("WT_ROOT")
            .unwrap_or_else(|| format!("{}/.worktrees", env("HOME").unwrap_or_default()));
        let tmp = env("TMPDIR").unwrap_or_else(|| "/tmp".into());
        self.project_under(abs_path, &wt_root, &tmp)
    }

    /// `project_for_path` with the worktree root and temp dir passed in, so a test gives its own.
    fn project_under(&self, abs_path: &str, wt_root: &str, tmp: &str) -> String {
        let co = Checkout::find(Path::new(abs_path));
        let mut base = fallback(abs_path);
        let mut repo_name: Option<String> = None;
        if let Some(co) = &co {
            let repo = co.repo.to_string_lossy();
            base = fallback(&repo);
            repo_name = self
                .path_key(&repo)
                .or_else(|| self.lookup(repo.rsplit('/').next().unwrap_or("")))
                .map(str::to_string);
            if let Some(rn) = &repo_name {
                let rel = abs_path
                    .strip_prefix(co.top.to_string_lossy().as_ref())
                    .unwrap_or("")
                    .trim_start_matches('/');
                let mut seg = rel;
                while !seg.is_empty() {
                    if let Some(app) = self.app_at(rn, seg) {
                        return app.to_string();
                    }
                    seg = seg.rsplit_once('/').map_or("", |(head, _)| head);
                }
                let branch = co
                    .branch
                    .as_deref()
                    .filter(|b| rel.is_empty() && b.matches('/').count() >= 2);
                if let Some(seg) = branch.and_then(|b| b.split('/').nth(1)) {
                    for suffix in ["", "-web", "-api", "-mobile"] {
                        let cand = seg.strip_suffix(suffix).unwrap_or(seg);
                        if self.app_of(cand, rn) {
                            return cand.to_string();
                        }
                    }
                }
            }
        }
        if let Some(hit) = self.path_key(abs_path) {
            return hit.to_string();
        }
        if let Some(rn) = repo_name {
            return rn;
        }
        if let Some(hit) = self.lookup(&base) {
            return hit.to_string();
        }
        if co.is_none() {
            if let Some(hit) = self.reaped_worktree(abs_path, wt_root) {
                return hit.to_string();
            }
        }
        let tmp = format!("{}/", tmp.trim_end_matches('/'));
        let place = co.as_ref().map_or_else(
            || abs_path.to_string(),
            |c| c.repo.to_string_lossy().into_owned(),
        );
        let in_tmp = place.len() > tmp.len() && place.starts_with(&tmp);
        if (co.is_none() || in_tmp) && !self.known(&base) {
            return "_unscoped".into();
        }
        base
    }

    /// A path under the worktree root (`$WT_ROOT`, else `~/.worktrees`) that is no checkout,
    /// named by the `<repo>-<slug>` convention `wt` keeps: the longest registered checkout
    /// basename that is its first segment or prefixes it with a dash.
    fn reaped_worktree(&self, abs_path: &str, root: &str) -> Option<&str> {
        let wt = abs_path
            .strip_prefix(&format!("{root}/"))?
            .split('/')
            .next()?;
        self.raw
            .get("paths")?
            .as_object()?
            .iter()
            .filter_map(|(p, v)| {
                let b = fallback(p);
                let claims = !b.is_empty() && (wt == b || wt.starts_with(&format!("{b}-")));
                let v = v.as_str()?;
                claims.then_some((b.len(), v))
            })
            .max_by_key(|(l, _)| *l)
            .map(|(_, v)| v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_JSON: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../tests/fixtures/project-names.json"
    );
    const FIXTURE_TSV: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../tests/fixtures/project-names.tsv"
    );

    fn fixture() -> Registry {
        Registry::from_path(Path::new(FIXTURE_JSON)).expect("fixture registry")
    }

    #[test]
    fn a_game_with_build_tags_in_a_tagged_repo_takes_its_version_from_the_repo() {
        let r = Registry::parse(
            r#"{"trackers": {"play": {"tagGlob": "v*"},
                "game": {"repo": "play", "buildTags": ["v*-game*"]},
                "app": {"repo": "mono"}, "mono": {"tagGlob": "v*"},
                "bare": {"repo": "untagged", "buildTags": ["v*-bare*"]}, "untagged": {}}}"#,
        )
        .unwrap();
        assert_eq!(r.version_parent("game").as_deref(), Some("play"));
        assert_eq!(r.version_children("play"), ["game"]);
        // NEGATIVE CONTROL: an app in a tagged monorepo with no buildTags keeps its own number,
        // and buildTags under a repo with no tagGlob name no parent.
        assert_eq!(r.version_parent("app"), None);
        assert_eq!(r.version_parent("bare"), None);
        assert_eq!(r.version_parent("play"), None);
        assert!(r.version_children("mono").is_empty());
    }

    #[test]
    fn a_repo_declares_the_workflows_its_test_results_come_from() {
        let r = fixture();
        assert_eq!(
            r.test_workflows("kblack0610/.dotfiles"),
            [".github/workflows/tests.yml"]
        );
        // negative control: a repo the registry knows that declares none, and one it does not know.
        assert!(r.test_workflows("Studio/platform").is_empty());
        assert!(r.test_workflows("Org/nobody").is_empty());
    }

    #[test]
    fn a_repo_declares_the_artifacts_its_results_are_in_else_junit() {
        let r = Registry::parse(
            r#"{"trackers": {"ucp": {"github": "Org/Unity", "testWorkflows": [".github/workflows/test.yml"],
                "testArtifacts": ["test-runs-*"]}, "bats": {"github": "Org/bats"}}}"#,
        )
        .unwrap();
        assert_eq!(r.test_artifacts("org/unity"), ["test-runs-*"]);
        // negative control: a repo that names none, and one the registry does not know.
        assert_eq!(r.test_artifacts("Org/bats"), [DEFAULT_TEST_ARTIFACTS]);
        assert_eq!(r.test_artifacts("Org/nobody"), ["junit-*"]);
    }

    #[test]
    fn a_repo_names_the_runner_that_starts_its_night_set() {
        let r = Registry::parse(
            r#"{"trackers": {"ucp": {"github": "Org/Unity", "nightRunner": "playground-night"},
                "bats": {"github": "Org/bats", "nightRunner": ""}}}"#,
        )
        .unwrap();
        assert_eq!(
            r.night_runner("org/unity").as_deref(),
            Some("playground-night")
        );
        // negative control: an empty name, and a repo the registry does not know.
        assert_eq!(r.night_runner("Org/bats"), None);
        assert_eq!(r.night_runner("Org/nobody"), None);
    }

    #[test]
    fn a_repo_declares_the_workflows_that_build_and_where_their_artifacts_are_kept() {
        let r = Registry::parse(
            r#"{"trackers": {"ucp": {"github": "Org/Unity", "buildWorkflows": [".github/workflows/release.yml"],
                "artifactStore": ".github/actions/artifact/artifact.py"}, "bats": {"github": "Org/bats"}}}"#,
        )
        .unwrap();
        assert_eq!(
            r.build_workflows("org/unity"),
            [".github/workflows/release.yml"]
        );
        assert_eq!(
            r.artifact_store("Org/Unity").as_deref(),
            Some(".github/actions/artifact/artifact.py")
        );
        // negative control: a repo that declares neither, and one the registry does not know.
        assert!(r.build_workflows("Org/bats").is_empty());
        assert_eq!(r.artifact_store("Org/bats"), None);
        assert_eq!(r.artifact_store("Org/nobody"), None);
    }

    #[test]
    fn a_project_names_its_ci_stages_in_order() {
        let r = Registry::parse(
            r#"{"trackers": {"ucp": {"ciStages": ["Checks", "Tests (affected)", "", "Tests (all)"]},
                "bats": {"github": "Org/bats"}}}"#,
        )
        .unwrap();
        assert_eq!(
            r.ci_stages("ucp"),
            ["Checks", "Tests (affected)", "Tests (all)"]
        );
        // negative control: a tracker that declares none, and a project the registry does not know.
        assert!(r.ci_stages("bats").is_empty());
        assert!(r.ci_stages("nobody").is_empty());
    }

    #[test]
    fn a_project_has_its_own_slugs_or_its_monorepos() {
        let r = fixture();
        assert_eq!(r.repos("dotfiles"), ["Kblack0610/.dotfiles"]);
        assert_eq!(
            r.repos("monorepo"),
            ["Studio/platform", "kblack0610/platform"]
        );
        // An app with no slug of its own is its monorepo's.
        assert_eq!(
            r.repos("shop-app"),
            ["Studio/platform", "kblack0610/platform"]
        );
        // negative control: a tracker with neither, and a name no tracker knows.
        assert!(r.repos("unity-core-playground").is_empty());
        assert!(r.repos("nothing-here").is_empty());
    }

    /// The shared conformance fixture: tests/unit/project_names.bats reads the same rows
    /// through project-name.sh.
    #[test]
    fn every_fixture_spelling_resolves_as_the_shell_lookup_does() {
        let r = fixture();
        let rows = std::fs::read_to_string(FIXTURE_TSV).unwrap();
        let mut n = 0;
        for line in rows
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            let (spelling, want) = line.split_once('\t').expect("spelling<TAB>key");
            assert_eq!(r.canonical(spelling), want, "{spelling}");
            n += 1;
        }
        assert!(n >= 20, "the fixture lost its rows: {n}");
    }

    /// The shared visibility fixture: tests/unit/project_visible.bats reads the same rows
    /// through project-name.sh.
    #[test]
    fn every_visibility_row_matches_the_shell_rule() {
        let r = Registry::from_path(Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../tests/fixtures/project-visibility.json"
        )))
        .unwrap();
        let rows = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../tests/fixtures/project-visibility.tsv"
        ))
        .unwrap();
        let mut n = 0;
        for line in rows
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            let f: Vec<&str> = line.split('\t').collect();
            let [machine, kind, name, want] = f[..] else {
                panic!("machine<TAB>kind<TAB>name<TAB>yes|no: {line}")
            };
            let got = match kind {
                "profile" => r.profile_visible(name, machine),
                "project" => r.project_visible(name, machine),
                _ => panic!("kind {kind}"),
            };
            assert_eq!(got, want == "yes", "{line}");
            n += 1;
        }
        assert!(n >= 20, "the fixture lost its rows: {n}");
    }

    #[test]
    fn known_is_a_key_and_never_another_spelling() {
        let r = fixture();
        for k in [
            "dotfiles",
            "bnb-platform",
            "shopapp",
            "brightsign-fleet-platform",
        ] {
            assert!(r.known(k), "{k}");
        }
        for n in [
            "waybar", "platform", "Dotfiles", "default", "_comment", "zeta",
        ] {
            assert!(!r.known(n), "{n}");
        }
    }

    #[test]
    fn tracker_fields_come_from_the_tracker_or_paths() {
        let r = Registry::parse(
            r#"{"paths": {"/src/alpha": "alpha"},
                "trackers": {"beta": {"type": "game", "repo": "mono", "code": "bt"},
                             "epsilon": {"code": "Not-A-Code"}, "gamma": {"type": "app"},
                             "delta": {"repo": ""}}}"#,
        )
        .unwrap();
        assert_eq!(r.kind("beta").as_deref(), Some("game"));
        assert_eq!(r.kind("alpha"), None);
        assert!(r.has_repo("beta"));
        assert!(r.has_repo("alpha"), "a paths key is its own repo");
        assert!(!r.has_repo("gamma"));
        assert!(!r.has_repo("delta"), "an empty repo is not a repo");
        assert_eq!(r.code("beta").as_deref(), Some("bt"));
        assert_eq!(r.code("gamma"), None, "no code set");
        assert_eq!(r.code("epsilon"), None, "a malformed code is no code");
    }

    #[test]
    fn a_checkout_is_the_first_mapped_path_that_is_cloned() {
        let here = std::env::temp_dir();
        let text = format!(
            r#"{{"paths": {{"/no/such/clone": "mono", "{}": "mono", "/elsewhere": "other"}}}}"#,
            here.display()
        );
        let r = Registry::parse(&text).unwrap();
        assert_eq!(r.checkout("mono"), Some(here));
        assert_eq!(r.checkout("other"), None, "mapped but not cloned");
        assert_eq!(r.checkout("nope"), None, "not mapped");
    }

    #[test]
    fn a_key_wins_over_another_projects_name_for_it() {
        let r =
            Registry::parse(r#"{"trackers": {"alpha": {"names": ["beta"]}, "beta": {}}}"#).unwrap();
        assert_eq!(r.canonical("beta"), "beta");
    }

    #[test]
    fn no_registry_is_no_registry() {
        assert!(Registry::from_path(Path::new("/nonexistent/project-map.json")).is_none());
        assert!(Registry::parse("[1]").is_none());
        assert!(Registry::parse("not json").is_none());
    }

    #[test]
    fn a_stranger_keeps_its_last_segment() {
        assert_eq!(fallback("Kblack0610/.dotfiles"), "dotfiles");
        assert_eq!(fallback("Other"), "Other");
        assert_eq!(fallback("owner/repo/"), "repo");
    }

    fn git(dir: &Path, args: &[&str]) {
        let ok = std::process::Command::new("git")
            .args(["-c", "user.email=t@t", "-c", "user.name=t", "-C"])
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .expect("git runs")
            .status
            .success();
        assert!(ok, "git {args:?} in {}", dir.display());
    }

    /// Every case `tests/unit/project_name.bats` pins for `resolve_project_name`, built as real
    /// git trees and answered by both the shell resolver and `project_for_path`; each must give
    /// the expected key, so the two cannot drift. The roots go to the shell as `WT_ROOT` and `TMPDIR` and to Rust as
    /// arguments, so no test mutates the process environment.
    #[test]
    fn project_for_path_matches_the_shell() {
        let root = std::env::temp_dir().join(format!("project-map-pfp-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let s = root.canonicalize().unwrap();
        let (repos, wt, tmp, home) = (s.join("repos"), s.join("wt"), s.join("tmp"), s.join("home"));
        let mono = repos.join("mono");
        for d in ["apps/alpha/api", "apps/beta", "packages/shared"] {
            std::fs::create_dir_all(mono.join(d)).unwrap();
        }
        std::fs::write(mono.join("README.md"), "").unwrap();
        git(&mono, &["init", "-q", "-b", "develop"]);
        git(&mono, &["add", "-A"]);
        git(&mono, &["commit", "-qm", "init"]);
        let add_wt = |path: &Path, branch: &str| {
            git(
                &mono,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    branch,
                    path.to_str().unwrap(),
                ],
            );
        };
        add_wt(&repos.join("mono-wt-junk"), "wt-branch");
        add_wt(&repos.join("mono-wt2"), "wt2");
        add_wt(&repos.join("mono-wt3"), "fix/alpha/some-bug");
        add_wt(&repos.join("mono-wt4"), "feat/beta-web/thing");
        add_wt(&wt.join("unrelated-name"), "side");
        // git keeps no empty directory, so a worktree's subdirectories are made by hand.
        for d in [
            repos.join("mono-wt2/apps/beta"),
            repos.join("mono-wt3/packages/shared"),
            home.join(".mono-canon"),
            home.join(".someproj"),
            home.join("aliased-dir"),
            wt.join("mono-fix-thing/Logs"),
            tmp.join("tmp.AbC123xyZ/sub"),
            repos.join("stranger/sub"),
        ] {
            std::fs::create_dir_all(d).unwrap();
        }
        git(&tmp.join("tmp.AbC123xyZ"), &["init", "-q", "-b", "main"]);
        let stranger = repos.join("stranger");
        std::fs::write(stranger.join("f"), "").unwrap();
        git(&stranger, &["init", "-q", "-b", "main"]);
        git(&stranger, &["add", "-A"]);
        git(&stranger, &["commit", "-qm", "init"]);
        git(
            &stranger,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "w",
                repos.join("stranger-wt").to_str().unwrap(),
            ],
        );

        let map = s.join("project-map.json");
        let json = serde_json::json!({
            "paths": { mono.to_str().unwrap(): "mono-canon" },
            "trackers": {
                "from-alias": { "names": ["aliased-dir"] },
                "alpha": { "repo": "mono-canon", "path": "apps/alpha" },
                "beta": { "repo": "mono-canon", "path": "apps/beta" },
                "_comment": "a string value"
            }
        });
        std::fs::write(&map, json.to_string()).unwrap();
        let reg = Registry::from_path(&map).unwrap();
        let lib = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../.config/shared-hooks/project-name.sh"
        );

        let cases: &[(PathBuf, &str)] = &[
            (mono.clone(), "mono-canon"),
            (home.join(".mono-canon"), "mono-canon"),
            (home.join(".someproj"), "_unscoped"),
            (home.clone(), "_unscoped"),
            (home.join("aliased-dir"), "from-alias"),
            (mono.join("apps/alpha"), "alpha"),
            (mono.join("apps/alpha/api"), "alpha"),
            (mono.join("packages/shared"), "mono-canon"),
            (repos.join("mono-wt-junk"), "mono-canon"),
            (repos.join("mono-wt2/apps/beta"), "beta"),
            (repos.join("mono-wt3"), "alpha"),
            (repos.join("mono-wt3/packages/shared"), "mono-canon"),
            (repos.join("mono-wt4"), "beta"),
            (wt.join("mono-agent-3"), "mono-canon"),
            (wt.join("mono-fix-thing/Logs"), "mono-canon"),
            (wt.join("monolith-agent-1"), "_unscoped"),
            (s.join("elsewhere/mono-agent-3"), "_unscoped"),
            (wt.join("unrelated-name"), "mono-canon"),
            (tmp.join("tmp.AbC123xyZ"), "_unscoped"),
            (tmp.join("tmp.AbC123xyZ/sub"), "_unscoped"),
            (repos.join("stranger/sub"), "stranger"),
            (repos.join("stranger-wt"), "stranger"),
        ];
        for (path, want) in cases {
            let p = path.to_str().unwrap();
            let out = std::process::Command::new("bash")
                .args([
                    "-c",
                    r#"source "$1" && resolve_project_name "$2""#,
                    "_",
                    lib,
                    p,
                ])
                .env("PROJECT_MAP_FILE", &map)
                .env("HOME", &home)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("WT_ROOT", &wt)
                .env("TMPDIR", &tmp)
                .output()
                .expect("bash runs");
            let shell = String::from_utf8_lossy(&out.stdout).trim().to_string();
            assert_eq!(shell, *want, "shell resolver on {p}");
            let got = reg.project_under(p, wt.to_str().unwrap(), tmp.to_str().unwrap());
            assert_eq!(got, *want, "project_for_path on {p}");
        }
        // negative control: the basename rule this replaces in agent-panel names a worktree by
        // its own directory, which is the drift (`platform-agent-9` read `platform`).
        assert_ne!(
            fallback(repos.join("mono-wt-junk").to_str().unwrap()),
            "mono-canon"
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
