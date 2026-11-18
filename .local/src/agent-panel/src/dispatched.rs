//! A-d in the chooser: show every session, hide the ones fleet-dispatch started, or show only
//! those. A dispatched session is a window fleet-dispatch tagged `@dispatch`, which the row reads
//! as its `dispatch` tag (`tmux::pane_format`). The view is saved beside the sort
//! (`panels/agent-panel.dispatch`) so the panel reopens in it, and the border label names it.
//! Its one writer is `agent-panel dispatched --step`.

use std::fs;
use std::path::{Path, PathBuf};

use crate::chooser::Agent;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum View {
    #[default]
    All,
    Hide,
    Only,
}

/// Every view in A-d order: the view, its word in the state file, and the border label.
const VIEWS: [(View, &str, &str); 3] = [
    (View::All, "all", ""),
    (View::Hide, "hide", " dispatched hidden "),
    (View::Only, "only", " dispatched only "),
];

impl View {
    fn entry(self) -> (View, &'static str, &'static str) {
        *VIEWS.iter().find(|v| v.0 == self).unwrap_or(&VIEWS[0])
    }

    pub fn next(self) -> View {
        let i = VIEWS.iter().position(|v| v.0 == self).unwrap_or(0);
        VIEWS[(i + 1) % VIEWS.len()].0
    }

    /// The border label: empty when every session shows.
    pub fn label(self) -> &'static str {
        self.entry().2
    }

    pub fn filter(self, agents: Vec<Agent>) -> Vec<Agent> {
        agents
            .into_iter()
            .filter(|a| match self {
                View::All => true,
                View::Hide => !is_dispatched(a),
                View::Only => is_dispatched(a),
            })
            .collect()
    }
}

/// fleet-dispatch started it: its window carries `@dispatch`, the row's `dispatch` tag.
pub fn is_dispatched(agent: &Agent) -> bool {
    agent.tags.split_whitespace().any(|t| t == "dispatch")
}

pub fn state_file() -> Option<PathBuf> {
    crate::sort::panels_file("agent-panel.dispatch")
}

/// The saved view, every session when there is none or it does not parse.
pub fn load(file: &Path) -> View {
    let text = fs::read_to_string(file).unwrap_or_default();
    VIEWS
        .iter()
        .find(|v| v.1 == text.trim())
        .map_or(View::All, |v| v.0)
}

pub fn save(file: &Path, view: View) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(file, format!("{}\n", view.entry().1))
}

/// The view the panel was last left in.
pub fn saved() -> View {
    state_file().map(|f| load(&f)).unwrap_or_default()
}

/// A-d: step the saved view and print its border label for fzf's `transform-border-label`.
pub fn run_step() -> anyhow::Result<()> {
    let view = saved().next();
    if let Some(file) = state_file() {
        save(&file, view)?;
    }
    println!("{}", view.label());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(target: &str, tags: &str) -> Agent {
        Agent {
            target: target.into(),
            tags: tags.into(),
            ..Agent::default()
        }
    }

    #[test]
    fn a_d_steps_all_hide_only_and_each_view_keeps_its_rows() {
        assert_eq!(View::All.next(), View::Hide);
        assert_eq!(View::Hide.next(), View::Only);
        assert_eq!(View::Only.next(), View::All);
        let agents = vec![
            agent("hub/a:1", "fav dispatch"),
            agent("hub/b:1", "fav"),
            agent("hub/c:1", "dispatch"),
        ];
        let targets = |v: View| -> Vec<String> {
            v.filter(agents.clone())
                .into_iter()
                .map(|a| a.target)
                .collect()
        };
        assert_eq!(targets(View::All).len(), 3);
        assert_eq!(targets(View::Hide), ["hub/b:1"]);
        assert_eq!(targets(View::Only), ["hub/a:1", "hub/c:1"]);
        // Negative control: a tag that only contains the word is not the dispatch tag.
        assert!(!is_dispatched(&agent("hub/d:1", "dispatcher")));
    }

    #[test]
    fn the_view_saves_and_loads_and_junk_reads_as_all() {
        let dir = std::env::temp_dir().join(format!("ap-dispatched-{}", std::process::id()));
        let file = dir.join("agent-panel.dispatch");
        assert_eq!(load(&file), View::All);
        for v in [View::Hide, View::Only, View::All] {
            save(&file, v).unwrap();
            assert_eq!(load(&file), v);
        }
        fs::write(&file, "bogus\n").unwrap();
        assert_eq!(load(&file), View::All);
        assert_eq!(View::All.label(), "");
        assert!(View::Only.label().contains("only"));
        let _ = fs::remove_dir_all(dir);
    }
}
