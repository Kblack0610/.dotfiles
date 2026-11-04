//! The project registry (`project-map.json`), read-only. It is the one place a project is
//! named and typed; the lab only reads it. `paths` maps a repo checkout to its key,
//! `aliases` maps another name to a key, and `trackers.<key>` holds the wiring, including
//! `type` (game, app or infra) and `repo`.

use serde_json::Value;
use std::path::{Path, PathBuf};

pub struct Registry(Value);

impl Registry {
    /// `$PROJECT_MAP_FILE`, else the stowed `~/.config/shared-hooks/project-map.json`, the
    /// same path `project_map_file` in `project-name.sh` resolves. None when it is absent.
    pub fn load() -> Option<Registry> {
        let path = match std::env::var("PROJECT_MAP_FILE") {
            Ok(p) if !p.is_empty() => PathBuf::from(p),
            _ => crate::config::home().join(".config/shared-hooks/project-map.json"),
        };
        Self::from_path(&path)
    }

    /// None when the file is absent. An unreadable or malformed file is also None, with a
    /// warning on stderr so it never reads as "no registry here".
    pub fn from_path(path: &Path) -> Option<Registry> {
        let text = std::fs::read_to_string(path).ok()?;
        match serde_json::from_str(&text) {
            Ok(v) => Some(Registry(v)),
            Err(e) => {
                eprintln!(
                    "warning: {} is not valid JSON ({e}); ignoring it",
                    path.display()
                );
                None
            }
        }
    }

    /// The tracker entry for `name`, when it is an object (`_comment*` keys are strings).
    fn tracker(&self, name: &str) -> Option<&serde_json::Map<String, Value>> {
        self.0.get("trackers")?.get(name)?.as_object()
    }

    /// True when `name` is a value of the top-level `key` map (`paths` or `aliases`).
    fn is_value_of(&self, key: &str, name: &str) -> bool {
        self.0
            .get(key)
            .and_then(Value::as_object)
            .is_some_and(|m| m.values().any(|v| v.as_str() == Some(name)))
    }

    /// A canonical project: a `paths` value, a tracker key, or an `aliases` value. The same
    /// test as `project_known` in `project-name.sh`.
    pub fn known(&self, name: &str) -> bool {
        self.is_value_of("paths", name)
            || self.tracker(name).is_some()
            || self.is_value_of("aliases", name)
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
        repo.is_some_and(|r| !r.is_empty()) || self.is_value_of("paths", name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(tag: &str) -> (PathBuf, Registry) {
        let path =
            std::env::temp_dir().join(format!("notes-registry-{tag}-{}.json", std::process::id()));
        std::fs::write(
            &path,
            r#"{
              "paths": {"/src/alpha": "alpha", "/src/mono": "mono"},
              "aliases": {"alpha-old": "alpha", "omega-old": "omega"},
              "trackers": {
                "_comment": "a string, not a tracker",
                "beta": {"type": "game", "repo": "mono"},
                "gamma": {"type": "app"},
                "delta": {"type": "game", "repo": ""}
              }
            }"#,
        )
        .unwrap();
        let r = Registry::from_path(&path).unwrap();
        (path, r)
    }

    #[test]
    fn known_matches_project_known() {
        let (path, r) = fixture("known");
        for n in ["alpha", "mono", "beta", "gamma", "omega"] {
            assert!(r.known(n), "{n}");
        }
        // an alias itself, a comment key and a stranger are not projects
        for n in ["alpha-old", "omega-old", "_comment", "zeta"] {
            assert!(!r.known(n), "{n}");
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn kind_and_repo_come_from_the_tracker_or_paths() {
        let (path, r) = fixture("kind");
        assert_eq!(r.kind("beta").as_deref(), Some("game"));
        assert_eq!(r.kind("alpha"), None);
        assert!(r.has_repo("beta"));
        assert!(r.has_repo("alpha"), "a paths key is its own repo");
        assert!(!r.has_repo("gamma"));
        assert!(!r.has_repo("delta"), "an empty repo is not a repo");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn an_absent_file_is_no_registry() {
        assert!(Registry::from_path(Path::new("/nonexistent/project-map.json")).is_none());
    }
}
