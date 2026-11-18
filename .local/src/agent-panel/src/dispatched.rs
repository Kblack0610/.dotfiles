//! A-d in the chooser: show every session, hide the ones fleet-dispatch started, or show only
//! those. A dispatched session is one fleet-dispatch tagged `@dispatch` (`tmux::Pane::dispatched`).
//! The view is saved beside the sort (`panels/agent-panel.dispatch`) so the panel reopens in it,
//! and the border label names it. Its one writer is `agent-panel dispatched`, the A-d callback.

use std::fs;
use std::path::{Path, PathBuf};

use agent_core::agent::Agent;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum View {
    #[default]
    All,
    Hide,
    Only,
}

impl View {
    /// A-d order: every session, dispatched hidden, dispatched only.
    pub fn next(self) -> View {
        match self {
            View::All => View::Hide,
            View::Hide => View::Only,
            View::Only => View::All,
        }
    }

    /// The border label: empty when every session shows.
    pub fn label(self) -> &'static str {
        match self {
            View::All => "",
            View::Hide => " dispatched hidden ",
            View::Only => " dispatched only ",
        }
    }

    /// Its word in the state file.
    fn word(self) -> &'static str {
        match self {
            View::All => "all",
            View::Hide => "hide",
            View::Only => "only",
        }
    }

    pub fn filter(self, agents: Vec<Agent>) -> Vec<Agent> {
        agents
            .into_iter()
            .filter(|a| match self {
                View::All => true,
                View::Hide => !a.dispatched,
                View::Only => a.dispatched,
            })
            .collect()
    }
}

pub fn state_file() -> Option<PathBuf> {
    crate::sort::panels_file("agent-panel.dispatch")
}

/// The saved view, every session when there is none or it does not parse.
pub fn load(file: &Path) -> View {
    let text = fs::read_to_string(file).unwrap_or_default();
    [View::Hide, View::Only]
        .into_iter()
        .find(|v| v.word() == text.trim())
        .unwrap_or_default()
}

/// Write by rename: a reload reading the file mid-save sees the old view or the new one.
pub fn save(file: &Path, view: View) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut tmp = file.as_os_str().to_owned();
    tmp.push(".tmp");
    fs::write(&tmp, format!("{}\n", view.word()))?;
    fs::rename(&tmp, file)
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

    fn agent(target: &str, dispatched: bool) -> Agent {
        Agent {
            target: target.into(),
            dispatched,
            ..Agent::default()
        }
    }

    #[test]
    fn a_d_steps_all_hide_only_and_each_view_keeps_its_rows() {
        assert_eq!(View::All.next(), View::Hide);
        assert_eq!(View::Hide.next(), View::Only);
        assert_eq!(View::Only.next(), View::All);
        let agents = vec![
            agent("hub/a:1", true),
            agent("hub/b:1", false),
            agent("hub/c:1", true),
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
