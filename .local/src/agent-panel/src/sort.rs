//! How the chooser orders its rows: C-o steps the key, A-o flips the direction. The sort is
//! saved beside the panel's layout (`panels/agent-panel.sort`) so the panel reopens the way it
//! was left, as it does for ctrl-/. Its one writer is `agent-panel rows --sort`.

use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};

use crate::chooser::Agent;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Key {
    /// Grouped under project headers, the shepherd pinned on top.
    #[default]
    Project,
    /// Longest open first.
    Open,
    /// Waiting on the human first, then busy, then idle.
    Status,
    /// The fleet stage, worst first (`STAGES`).
    Stage,
}

/// Every key in C-o order: the key, its word in the state file, and how its header reads.
const KEYS: [(Key, &str, &str); 4] = [
    (Key::Project, "project", "by project"),
    (Key::Open, "open", "longest open first"),
    (Key::Status, "status", "needs you first"),
    (Key::Stage, "stage", "stalled first"),
];

/// Fleet stages (`~/.local/src/docs/fleet-states.md`) worst first; an unknown or empty stage
/// sorts beside WORKING.
const STAGES: [&str; 7] = ["STALLED", "NEEDS", "WORKING", "CHAT", "LANDED", "DONE", "PARKED"];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Sort {
    pub key: Key,
    pub reverse: bool,
}

/// A C-o or A-o press: what `rows --sort` was asked to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum Step {
    Next,
    Reverse,
}

impl Sort {
    /// The state file's one line: `<key>` or `<key> reverse`. None for anything else.
    pub fn parse(line: &str) -> Option<Sort> {
        let mut words = line.split_whitespace();
        let word = words.next()?;
        let key = KEYS.iter().find(|(_, w, _)| *w == word)?.0;
        let reverse = match words.next() {
            None => false,
            Some("reverse") => true,
            Some(_) => return None,
        };
        words.next().is_none().then_some(Sort { key, reverse })
    }

    pub fn line(self) -> String {
        let word = KEYS.iter().find(|(k, _, _)| *k == self.key).map(|k| k.1).unwrap_or("project");
        if self.reverse {
            format!("{word} reverse")
        } else {
            word.to_string()
        }
    }

    /// How the list header names the sort, e.g. `longest open first, reversed`.
    pub fn label(self) -> String {
        let label = KEYS.iter().find(|(k, _, _)| *k == self.key).map(|k| k.2).unwrap_or("");
        if self.reverse {
            format!("{label}, reversed")
        } else {
            label.to_string()
        }
    }

    /// C-o moves to the next key in its natural direction; A-o flips the direction.
    pub fn step(self, step: Step) -> Sort {
        match step {
            Step::Reverse => Sort { reverse: !self.reverse, ..self },
            Step::Next => {
                let i = KEYS.iter().position(|(k, _, _)| *k == self.key).unwrap_or(0);
                Sort { key: KEYS[(i + 1) % KEYS.len()].0, reverse: false }
            }
        }
    }

    /// Order a flat list by this sort. Project is the grouped view, which `render::build`
    /// orders itself. A row with no open time (a parked one) goes last either way, and ties
    /// keep the longest open first, then the order the agents were found in (a stable sort).
    pub fn order(self, agents: &mut [&Agent]) {
        let dir = |o: Ordering| if self.reverse { o.reverse() } else { o };
        let open = |a: &&Agent, b: &&Agent| a.started_at.is_none().cmp(&b.started_at.is_none()).then(a.started_at.cmp(&b.started_at));
        match self.key {
            Key::Project => {}
            Key::Open => agents.sort_by(|a, b| {
                a.started_at.is_none().cmp(&b.started_at.is_none()).then_with(|| dir(a.started_at.cmp(&b.started_at)))
            }),
            Key::Status => agents.sort_by(|a, b| dir(status_rank(a).cmp(&status_rank(b))).then_with(|| open(a, b))),
            Key::Stage => agents.sort_by(|a, b| dir(stage_rank(a).cmp(&stage_rank(b))).then_with(|| open(a, b))),
        }
    }
}

fn status_rank(a: &Agent) -> u8 {
    match a.glyph {
        _ if a.needs_attention() => 0,
        '~' => 1,
        '✓' => 2,
        _ => 3,
    }
}

fn stage_rank(a: &Agent) -> usize {
    STAGES.iter().position(|s| *s == a.stage).unwrap_or(2)
}

/// `${XDG_STATE_HOME:-$HOME/.local/state}/panels/agent-panel.sort`, beside the layout file
/// `panel_layout_file` writes.
pub fn state_file() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".local/state")))?;
    Some(state.join("panels/agent-panel.sort"))
}

/// The saved sort, or project when there is none. A file that does not parse says so on
/// stderr and opens by project, so a typo never keeps the panel from opening.
pub fn load(file: &Path) -> Sort {
    match fs::read_to_string(file) {
        Err(_) => Sort::default(),
        Ok(text) => Sort::parse(text.trim()).unwrap_or_else(|| {
            eprintln!("agent-panel: unknown sort in {}: {:?}, using project", file.display(), text.trim());
            Sort::default()
        }),
    }
}

pub fn save(file: &Path, sort: Sort) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(file, format!("{}\n", sort.line()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(target: &str, glyph: char, stage: &str, started_at: Option<u64>) -> Agent {
        Agent {
            glyph,
            target: target.to_string(),
            stage: stage.to_string(),
            started_at,
            ..Agent::default()
        }
    }

    fn targets(sort: Sort, agents: &[Agent]) -> Vec<String> {
        let mut refs: Vec<&Agent> = agents.iter().collect();
        sort.order(&mut refs);
        refs.iter().map(|a| a.target.clone()).collect()
    }

    fn fleet() -> Vec<Agent> {
        vec![
            agent("idle-new", '✓', "DONE", Some(300)),
            agent("parked", ' ', "PARKED", None),
            agent("busy-old", '~', "WORKING", Some(100)),
            agent("needs-mid", '!', "STALLED", Some(200)),
        ]
    }

    #[test]
    fn open_puts_the_longest_open_first_and_parked_last_both_ways() {
        let open = Sort { key: Key::Open, reverse: false };
        assert_eq!(targets(open, &fleet()), ["busy-old", "needs-mid", "idle-new", "parked"]);
        let newest = open.step(Step::Reverse);
        assert_eq!(targets(newest, &fleet()), ["idle-new", "needs-mid", "busy-old", "parked"]);
    }

    #[test]
    fn status_and_stage_put_the_worst_first() {
        let status = Sort { key: Key::Status, reverse: false };
        assert_eq!(targets(status, &fleet()), ["needs-mid", "busy-old", "idle-new", "parked"]);
        let stage = Sort { key: Key::Stage, reverse: false };
        assert_eq!(targets(stage, &fleet()), ["needs-mid", "busy-old", "idle-new", "parked"]);
        let stage_rev = stage.step(Step::Reverse);
        assert_eq!(targets(stage_rev, &fleet()), ["parked", "idle-new", "busy-old", "needs-mid"]);
    }

    #[test]
    fn project_leaves_the_order_to_the_grouped_view() {
        let order: Vec<String> = fleet().iter().map(|a| a.target.clone()).collect();
        assert_eq!(targets(Sort::default(), &fleet()), order);
    }

    #[test]
    fn next_cycles_every_key_in_its_natural_direction() {
        let mut sort = Sort { key: Key::Project, reverse: true };
        let mut seen = Vec::new();
        for _ in 0..KEYS.len() {
            sort = sort.step(Step::Next);
            assert!(!sort.reverse);
            seen.push(sort.line());
        }
        assert_eq!(seen, ["open", "status", "stage", "project"]);
    }

    #[test]
    fn the_state_file_round_trips_and_a_bad_one_opens_by_project() {
        let dir = std::env::temp_dir().join(format!("agent-panel-sort-{}", std::process::id()));
        let file = dir.join("panels/agent-panel.sort");
        assert_eq!(load(&file), Sort::default(), "no file is project");
        let sort = Sort { key: Key::Open, reverse: true };
        save(&file, sort).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "open reverse\n");
        assert_eq!(load(&file), sort);
        for bad in ["diagonal", "open sideways", "open reverse again", ""] {
            fs::write(&file, bad).unwrap();
            assert_eq!(load(&file), Sort::default(), "{bad:?}");
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
