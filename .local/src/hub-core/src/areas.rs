//! The one scope -> group map (`.config/areas/groups`): the `type(scope):` prefix of a row or a PR
//! title says its scope, and this says which group of work that scope is, so a sprint page's By
//! area table and day-log's board group the same work the same way. day-log (jq) reads the file
//! too; the format is its header's.

use std::collections::HashMap;
use std::path::PathBuf;

/// The group of a row whose scope says nothing about the work: no scope at all, or the name of a
/// repo (`feat(unity-core-playground): ...`).
pub const UNSORTED: &str = "Unsorted";

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Areas {
    scopes: HashMap<String, String>,
    repos: Vec<String>,
}

impl Areas {
    /// The map in `text`: `<scope>[,<scope>...]  <group>` lines, `@<repo>  <area>` lines for the
    /// repos, `#` comments and blank lines skipped. The key is the line's first word, the group
    /// the rest of it.
    pub fn parse(text: &str) -> Areas {
        let mut out = Areas::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, group)) = line.split_once(char::is_whitespace) else {
                continue;
            };
            let group = group.trim();
            if group.is_empty() {
                continue;
            }
            if let Some(repo) = key.strip_prefix('@') {
                out.repos.push(repo.to_string());
            } else {
                for scope in key.split(',').filter(|s| !s.is_empty()) {
                    out.scopes.insert(scope.to_string(), group.to_string());
                }
            }
        }
        out
    }

    /// The file at `$HOME/.config/areas/groups`. An error names the path, so a sprint page says
    /// its groups are unread instead of filing every row under a made-up group.
    pub fn load() -> Result<Areas, String> {
        let path = PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
            .join(".config/areas/groups");
        std::fs::read_to_string(&path)
            .map(|t| Areas::parse(&t))
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The group of a row's scope: the file's for a scope it lists, `Unsorted` for no scope or
    /// a repo's name, else the scope itself, a group of its own as the file's header says.
    pub fn group(&self, scope: Option<&str>) -> String {
        match scope.filter(|s| !s.is_empty()) {
            None => UNSORTED.to_string(),
            Some(s) => match self.scopes.get(s) {
                Some(g) => g.clone(),
                None if self.repos.iter().any(|r| r == s) => UNSORTED.to_string(),
                None => s.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE: &str = "# comment\n\n@unity-core-playground  Games\n\
        test,tests,ci  Tests, CI and benches\nlook,ui   Look and UI\n";

    #[test]
    fn a_listed_scope_is_its_group_and_aliases_share_one() {
        let a = Areas::parse(FILE);
        assert_eq!(a.group(Some("ci")), "Tests, CI and benches");
        assert_eq!(a.group(Some("tests")), a.group(Some("test")));
        assert_eq!(a.group(Some("ui")), "Look and UI");
    }

    #[test]
    fn no_scope_or_a_repo_name_is_unsorted_and_an_unknown_scope_stands_alone() {
        let a = Areas::parse(FILE);
        assert_eq!(a.group(None), UNSORTED);
        assert_eq!(a.group(Some("")), UNSORTED);
        assert_eq!(a.group(Some("unity-core-playground")), UNSORTED);
        assert_eq!(a.group(Some("zany")), "zany");
    }

    /// The file the repo ships parses, and its unity scopes land where the plan put them.
    #[test]
    fn the_shipped_map_groups_the_unity_scopes() {
        let text = include_str!("../../../../.config/areas/groups");
        let a = Areas::parse(text);
        for (scope, group) in [
            ("tests", "Tests, CI and benches"),
            ("ci", "Tests, CI and benches"),
            ("gameplay", "Engine"),
            ("netcode", "Engine"),
            ("look", "Look and UI"),
            ("ui", "Look and UI"),
            ("deploy", "Ops"),
            ("perf", "Ops"),
            ("unity-core-playground", UNSORTED),
        ] {
            assert_eq!(a.group(Some(scope)), group, "{scope}");
        }
    }
}
