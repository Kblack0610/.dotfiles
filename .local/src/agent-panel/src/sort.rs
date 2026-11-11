//! How the chooser orders its rows: C-o steps the key, A-o flips the direction. The sort is
//! saved beside the panel's layout (`panels/agent-panel.sort`) so the panel reopens the way it
//! was left, as it does for ctrl-/. Its writers are `agent-panel rows --sort` and a S-Tab grab
//! (`agent-panel move grab`), which turns on the custom sort.
//!
//! The custom sort is the human's own order, moved by hand (S-Tab grabs a row, Up/Down carry it):
//! one target per line in `panels/agent-panel.order`, whose one writer is `agent-panel move`.

use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};

use crate::chooser::Agent;
use crate::vocab::Vocab;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Key {
    /// Grouped under project headers, the shepherd pinned on top.
    #[default]
    Project,
    /// The human's own order (`panels/agent-panel.order`), rows it does not name yet last.
    Custom,
    /// Newest activity first: the transcript's last write.
    Recent,
    /// Longest open first.
    Open,
    /// Waiting on the human first, then busy, then idle.
    Status,
    /// The fleet stage, in the order fleet-sessions publishes (state.json `vocab.buckets`).
    Stage,
    /// Grouped under a header per plan, the rows with no plan last.
    Plan,
}

/// Every key in C-o order: the key, its word in the state file, and how its header reads.
pub const KEYS: [(Key, &str, &str); 7] = [
    (Key::Project, "project", "by project"),
    (Key::Custom, "custom", "your order"),
    (Key::Recent, "recent", "most recent activity first"),
    (Key::Open, "open", "longest open first"),
    (Key::Status, "status", "needs you first"),
    (Key::Stage, "stage", "by fleet stage"),
    (Key::Plan, "plan", "by plan"),
];

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
        let word = KEYS
            .iter()
            .find(|(k, _, _)| *k == self.key)
            .map(|k| k.1)
            .unwrap_or("project");
        if self.reverse {
            format!("{word} reverse")
        } else {
            word.to_string()
        }
    }

    /// How the list header names the sort, e.g. `longest open first, reversed`.
    pub fn label(self) -> String {
        let label = KEYS
            .iter()
            .find(|(k, _, _)| *k == self.key)
            .map(|k| k.2)
            .unwrap_or("");
        if self.reverse {
            format!("{label}, reversed")
        } else {
            label.to_string()
        }
    }

    /// C-o moves to the next key in its natural direction; A-o flips the direction.
    pub fn step(self, step: Step) -> Sort {
        match step {
            Step::Reverse => Sort {
                reverse: !self.reverse,
                ..self
            },
            Step::Next => {
                let i = KEYS
                    .iter()
                    .position(|(k, _, _)| *k == self.key)
                    .unwrap_or(0);
                Sort {
                    key: KEYS[(i + 1) % KEYS.len()].0,
                    reverse: false,
                }
            }
        }
    }

    /// Order a flat list by this sort. Project is the grouped view, which `render::build`
    /// orders itself. A row with no open time (a parked one) goes last either way, and ties
    /// keep the longest open first, then the order the agents were found in (a stable sort).
    pub fn order(self, agents: &mut [&Agent]) {
        let vocab = if self.key == Key::Stage {
            Vocab::read()
        } else {
            Vocab::default()
        };
        let custom = match (self.key, order_file()) {
            (Key::Custom, Some(file)) => load_order(&file),
            _ => Vec::new(),
        };
        self.order_by(agents, &vocab, &custom);
    }

    /// `order`, with the stage order given by state.json's `vocab` and the custom order by
    /// `custom` (targets, first first).
    pub fn order_by(self, agents: &mut [&Agent], vocab: &Vocab, custom: &[String]) {
        let dir = |o: Ordering| if self.reverse { o.reverse() } else { o };
        let open = |a: &&Agent, b: &&Agent| {
            a.started_at
                .is_none()
                .cmp(&b.started_at.is_none())
                .then(a.started_at.cmp(&b.started_at))
        };
        match self.key {
            Key::Project => {}
            Key::Custom => {
                // Rows the order does not name yet go last, longest open first, either way.
                let rank = |a: &Agent| custom.iter().position(|t| *t == a.target);
                agents.sort_by(|a, b| match (rank(a), rank(b)) {
                    (Some(x), Some(y)) => dir(x.cmp(&y)),
                    (Some(_), None) => Ordering::Less,
                    (None, Some(_)) => Ordering::Greater,
                    (None, None) => open(a, b),
                })
            }
            Key::Recent => agents.sort_by(|a, b| {
                a.last_active
                    .is_none()
                    .cmp(&b.last_active.is_none())
                    .then_with(|| dir(b.last_active.cmp(&a.last_active)))
            }),
            Key::Open => agents.sort_by(|a, b| {
                a.started_at
                    .is_none()
                    .cmp(&b.started_at.is_none())
                    .then_with(|| dir(a.started_at.cmp(&b.started_at)))
            }),
            Key::Status => agents
                .sort_by(|a, b| dir(status_rank(a).cmp(&status_rank(b))).then_with(|| open(a, b))),
            Key::Stage => agents.sort_by(|a, b| {
                dir(vocab.rank(&a.stage).cmp(&vocab.rank(&b.stage))).then_with(|| open(a, b))
            }),
            Key::Plan => agents.sort_by(|a, b| {
                a.plan_slug
                    .is_empty()
                    .cmp(&b.plan_slug.is_empty())
                    .then_with(|| dir(a.plan_slug.cmp(&b.plan_slug)))
                    .then_with(|| open(a, b))
            }),
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

/// `${XDG_STATE_HOME:-$HOME/.local/state}/panels/<name>`, beside the layout file
/// `panel_layout_file` writes.
fn panels_file(name: &str) -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".local/state")))?;
    Some(state.join("panels").join(name))
}

/// The saved sort: `panels/agent-panel.sort`.
pub fn state_file() -> Option<PathBuf> {
    panels_file("agent-panel.sort")
}

/// The custom order: `panels/agent-panel.order`, one target per line.
pub fn order_file() -> Option<PathBuf> {
    panels_file("agent-panel.order")
}

/// The saved custom order, empty when there is none.
pub fn load_order(file: &Path) -> Vec<String> {
    fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

/// Save the order as given, by rename: a reload rendering the custom sort while a move writes
/// reads the old order or the new one, never a truncated one. A grab prunes gone sessions.
pub fn save_order(file: &Path, order: &[String]) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut text = order.join("\n");
    text.push('\n');
    let mut tmp = file.as_os_str().to_owned();
    tmp.push(".tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, file)
}

/// The saved sort, or project when there is none. A file that does not parse says so on
/// stderr and opens by project, so a typo never keeps the panel from opening.
pub fn load(file: &Path) -> Sort {
    match fs::read_to_string(file) {
        Err(_) => Sort::default(),
        Ok(text) => Sort::parse(text.trim()).unwrap_or_else(|| {
            eprintln!(
                "agent-panel: unknown sort in {}: {:?}, using project",
                file.display(),
                text.trim()
            );
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
        targets_in(sort, agents, &[])
    }

    fn targets_in(sort: Sort, agents: &[Agent], custom: &[&str]) -> Vec<String> {
        let mut refs: Vec<&Agent> = agents.iter().collect();
        let vocab = Vocab::from_state(&serde_json::json!({"vocab": {"buckets":
            ["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"]}}));
        let custom: Vec<String> = custom.iter().map(|t| t.to_string()).collect();
        sort.order_by(&mut refs, &vocab, &custom);
        refs.iter().map(|a| a.target.clone()).collect()
    }

    fn key(key: Key) -> Sort {
        Sort {
            key,
            reverse: false,
        }
    }

    #[test]
    fn custom_keeps_the_saved_order_and_puts_new_rows_last_longest_open_first() {
        let order = ["needs-mid", "gone", "idle-new"];
        assert_eq!(
            targets_in(key(Key::Custom), &fleet(), &order),
            ["needs-mid", "idle-new", "busy-old", "parked"]
        );
        assert_eq!(
            targets_in(key(Key::Custom).step(Step::Reverse), &fleet(), &order),
            ["idle-new", "needs-mid", "busy-old", "parked"],
            "reverse flips the saved rows, the new ones stay last"
        );
        // Negative control: no saved order is every row by longest open.
        assert_eq!(
            targets(key(Key::Custom), &fleet()),
            ["busy-old", "needs-mid", "idle-new", "parked"]
        );
    }

    #[test]
    fn recent_puts_the_newest_activity_first_and_plan_groups_by_plan() {
        let mut agents = fleet();
        agents[0].last_active = Some(50); // idle-new
        agents[2].last_active = Some(900); // busy-old
        agents[3].last_active = Some(400); // needs-mid
        assert_eq!(
            targets(key(Key::Recent), &agents),
            ["busy-old", "needs-mid", "idle-new", "parked"]
        );
        assert_eq!(
            targets(key(Key::Recent).step(Step::Reverse), &agents),
            ["idle-new", "needs-mid", "busy-old", "parked"]
        );
        agents[0].plan_slug = "zeta".into();
        agents[3].plan_slug = "alpha".into();
        agents[2].plan_slug = "zeta".into();
        assert_eq!(
            targets(key(Key::Plan), &agents),
            ["needs-mid", "busy-old", "idle-new", "parked"],
            "plans by name, longest open first inside one, no plan last"
        );
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
        let open = Sort {
            key: Key::Open,
            reverse: false,
        };
        assert_eq!(
            targets(open, &fleet()),
            ["busy-old", "needs-mid", "idle-new", "parked"]
        );
        let newest = open.step(Step::Reverse);
        assert_eq!(
            targets(newest, &fleet()),
            ["idle-new", "needs-mid", "busy-old", "parked"]
        );
    }

    #[test]
    fn status_and_stage_put_the_worst_first() {
        let status = Sort {
            key: Key::Status,
            reverse: false,
        };
        assert_eq!(
            targets(status, &fleet()),
            ["needs-mid", "busy-old", "idle-new", "parked"]
        );
        let stage = Sort {
            key: Key::Stage,
            reverse: false,
        };
        assert_eq!(
            targets(stage, &fleet()),
            ["needs-mid", "idle-new", "busy-old", "parked"]
        );
        let stage_rev = stage.step(Step::Reverse);
        assert_eq!(
            targets(stage_rev, &fleet()),
            ["parked", "busy-old", "idle-new", "needs-mid"]
        );
    }

    #[test]
    fn project_leaves_the_order_to_the_grouped_view() {
        let order: Vec<String> = fleet().iter().map(|a| a.target.clone()).collect();
        assert_eq!(targets(Sort::default(), &fleet()), order);
    }

    #[test]
    fn next_cycles_every_key_in_its_natural_direction() {
        let mut sort = Sort {
            key: Key::Project,
            reverse: true,
        };
        let mut seen = Vec::new();
        for _ in 0..KEYS.len() {
            sort = sort.step(Step::Next);
            assert!(!sort.reverse);
            seen.push(sort.line());
        }
        assert_eq!(
            seen,
            ["custom", "recent", "open", "status", "stage", "plan", "project"]
        );
    }

    #[test]
    fn the_state_file_round_trips_and_a_bad_one_opens_by_project() {
        let dir = std::env::temp_dir().join(format!("agent-panel-sort-{}", std::process::id()));
        let file = dir.join("panels/agent-panel.sort");
        assert_eq!(load(&file), Sort::default(), "no file is project");
        let sort = Sort {
            key: Key::Open,
            reverse: true,
        };
        save(&file, sort).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "open reverse\n");
        assert_eq!(load(&file), sort);
        for bad in ["diagonal", "open sideways", "open reverse again", ""] {
            fs::write(&file, bad).unwrap();
            assert_eq!(load(&file), Sort::default(), "{bad:?}");
        }
        let order_file = dir.join("panels/agent-panel.order");
        assert!(load_order(&order_file).is_empty(), "no file is no order");
        let order = vec!["hub/a:1".to_string(), "lab/b:2".to_string()];
        save_order(&order_file, &order).unwrap();
        assert_eq!(load_order(&order_file), order);
        let _ = fs::remove_dir_all(&dir);
    }
}
