//! What a session is called, from its pane and paths: the project, the worktree basename, the
//! row label under a project header, and the pane title without its glyph. Every view names a
//! session with these, so the chooser and the hub cannot disagree on a name.

/// Normalize a working-directory path to a project name: basename with any
/// `-agent`, `-agent2`, `-agent-2` worktree suffix stripped, and the dotfiles
/// dir folded to `dotfiles`.
pub fn project_from_path(path: &str) -> String {
    let base = basename(path);
    let stripped = strip_agent_suffix(base);
    match stripped {
        ".dotfiles" | "_dotfiles" => "dotfiles".to_string(),
        other => other.to_string(),
    }
}

pub fn basename(path: &str) -> &str {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(path)
}

/// Strip a trailing `-agent-?[0-9]*` worktree marker.
fn strip_agent_suffix(s: &str) -> &str {
    if let Some(idx) = s.rfind("-agent") {
        let rest = &s[idx + "-agent".len()..];
        let digits = rest.strip_prefix('-').unwrap_or(rest);
        if digits.chars().all(|c| c.is_ascii_digit()) {
            return &s[..idx];
        }
    }
    s
}

/// Row label under a project header: the worktree's agent number, then the tmux
/// window index, e.g. session "platform-agent-4" window "2" -> "4:2". These are
/// two distinct values -- the agent number identifies the worktree, the window
/// index distinguishes tasks within it. Falls back to the window index alone
/// when the session carries no "-agent-N" worktree suffix.
pub fn short_target(session: &str, window_index: &str) -> String {
    let s = session.trim_start_matches(['_', '.']);
    let agent = s
        .rsplit_once("-agent")
        .map(|(_, rest)| rest.trim_start_matches('-'));
    match agent {
        Some(n) if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) => {
            format!("{n}:{window_index}")
        }
        _ => window_index.to_string(),
    }
}

/// Strip a leading status glyph + space from a Claude pane title (the row's own
/// glyph already conveys state). e.g. "✳ Doing a thing" -> "Doing a thing".
pub fn strip_title_glyph(title: &str) -> String {
    let mut chars = title.chars();
    if let Some(first) = chars.next() {
        if !first.is_alphanumeric() && !first.is_whitespace() && chars.next() == Some(' ') {
            return chars.collect::<String>().trim().to_string();
        }
    }
    title.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_agent_suffixes() {
        assert_eq!(project_from_path("/a/b/platform-agent-2"), "platform");
        assert_eq!(project_from_path("/a/b/foo-agent"), "foo");
        assert_eq!(project_from_path("/a/b/bar-agent3"), "bar");
        assert_eq!(project_from_path("/a/b/.dotfiles"), "dotfiles");
        assert_eq!(project_from_path("/a/b/plain"), "plain");
        // "-agent" mid-name without a trailing suffix is not stripped.
        assert_eq!(project_from_path("/a/b/my-agentic-tool"), "my-agentic-tool");
    }

    #[test]
    fn labels_agent_and_window() {
        // agent number leads (the worktree identity), window index trails.
        assert_eq!(short_target("platform-agent-4", "2"), "4:2");
        assert_eq!(short_target("platform-agent-2", "1"), "2:1");
        assert_eq!(short_target("platform-agent-2", "4"), "2:4");
        // no "-agent-N" suffix -> window index only.
        assert_eq!(short_target("platform", "3"), "3");
        assert_eq!(short_target("_dotfiles", "0"), "0");
    }

    #[test]
    fn strips_title_glyph() {
        assert_eq!(strip_title_glyph("✳ Hello there"), "Hello there");
        assert_eq!(strip_title_glyph("Plain title"), "Plain title");
        assert_eq!(strip_title_glyph("✳nospaces"), "✳nospaces");
    }
}
