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

    /// True when `name` is a value of `paths`: a repo with a registered checkout.
    fn in_paths(&self, name: &str) -> bool {
        self.raw
            .get("paths")
            .and_then(Value::as_object)
            .is_some_and(|m| m.values().any(|v| v.as_str() == Some(name)))
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

    /// The workflow files whose `junit-*` artifacts are a repo's test results:
    /// `testWorkflows` on the tracker whose `github` slug is `slug`, compared without case as
    /// GitHub does. Empty for a repo that declares none, so its runs list no Tests.
    pub fn test_workflows(&self, slug: &str) -> Vec<String> {
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
            .filter_map(|t| t.get("testWorkflows")?.as_array())
            .flatten()
            .filter_map(Value::as_str)
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
}
