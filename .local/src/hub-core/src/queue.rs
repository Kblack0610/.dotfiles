//! The agent queue as `agent-queue` lists it, for agent-web's Queue tab, the hub TUI's and the
//! session actions. agent-queue is the store's only reader and writer (design:
//! `~/.config/agentctl/QUEUE.md`), so this module never opens `~/.agent/queue`: it runs
//! `agent-queue list --json` and `agent-queue stats --json` through a `Runner` and types what
//! they print. Cancel and bump are argv for agent-queue too.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::session_actions::Runner;

pub const PRIORITIES: [&str; 4] = ["urgent", "high", "normal", "low"];

/// The store's states, in the order every surface shows them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Waiting,
    Running,
    #[default]
    Queued,
    Done,
}

/// The sections a Queue view shows, with their headings, as agent-web's page names them.
pub const SECTIONS: [(State, &str); 4] = [
    (State::Waiting, "Waiting for you"),
    (State::Running, "Running"),
    (State::Queued, "Up next"),
    (State::Done, "Done today"),
];

/// One item: its header keys as agent-queue prints them, plus `state`, `task` and, for a
/// queued item that cannot start yet, `hold`. A key this does not name is kept in `extra`, so
/// a caller that hands the item on as JSON loses nothing agent-queue said.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub slug: String,
    pub state: State,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub mode: String,
    /// Space-separated, as the store writes them; `tag_list` splits them.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tags: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    /// `human`, `shepherd` or `board:<project>:<key>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// `<server>:<tmux session>`, or a bare tmux session on agent-queue's server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr: Option<String>,
    /// `ok`, `failed` or `cancelled`, once done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Why a queued item cannot start yet: `after <slug>`, `night (...)`, `at:HH:MM`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished: Option<String>,
    #[serde(default)]
    pub task: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Item {
    pub fn tag_list(&self) -> impl Iterator<Item = &str> {
        self.tags.split_whitespace()
    }

    /// The first line of the task, for a one-line row.
    pub fn title(&self) -> &str {
        self.task
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim()
    }

    /// The priority one step up (`up`) or down, or None at the end of the scale or for a
    /// priority agent-queue does not know.
    pub fn bumped(&self, up: bool) -> Option<&'static str> {
        let i = PRIORITIES.iter().position(|p| *p == self.priority)?;
        let j = if up { i.checked_sub(1)? } else { i + 1 };
        PRIORITIES.get(j).copied()
    }
}

/// One group of `stats.by_project` or `stats.by_source`: the done items in it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Outcomes {
    pub done: u64,
    pub ok: u64,
    pub failed: u64,
    pub cancelled: u64,
    pub prs: u64,
    pub wait_minutes_median: Option<i64>,
    pub to_pr_minutes_median: Option<i64>,
}

/// `agent-queue stats --json`: active counts now, and the items finished since `since`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Stats {
    pub since: String,
    pub active: BTreeMap<String, u64>,
    /// Done items by status.
    pub done: BTreeMap<String, u64>,
    pub wait_minutes_median: Option<i64>,
    pub run_minutes_median: Option<i64>,
    pub to_pr_minutes_median: Option<i64>,
    pub per_day: BTreeMap<String, u64>,
    pub by_project: BTreeMap<String, Outcomes>,
    pub by_source: BTreeMap<String, Outcomes>,
    pub done_by_tag: BTreeMap<String, u64>,
}

fn argv(args: &[&str]) -> Vec<String> {
    std::iter::once("agent-queue")
        .chain(args.iter().copied())
        .map(String::from)
        .collect()
}

/// `agent-queue list --json` prints one object per line; a line that does not parse is skipped.
pub fn parse(jsonl: &str) -> Vec<Item> {
    jsonl
        .lines()
        .filter_map(|l| serde_json::from_str::<Item>(l).ok())
        .collect()
}

/// The items in `state` (`active`, `all`, or one state), in agent-queue's order: priority, then
/// queued time. `all` is every active item plus today's finished ones.
pub fn list(runner: &dyn Runner, state: &str) -> Result<Vec<Item>, String> {
    runner
        .run(&argv(&["list", "--json", "--state", state]))
        .map(|out| parse(&out))
}

pub fn stats(runner: &dyn Runner) -> Result<Stats, String> {
    let out = runner.run(&argv(&["stats", "--json"]))?;
    serde_json::from_str(&out).map_err(|e| format!("agent-queue stats: {e}"))
}

/// What a Queue view shows: the items (`all`), the week's stats, and what could not be read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Queue {
    pub items: Vec<Item>,
    pub stats: Option<Stats>,
    pub errors: Vec<String>,
}

impl Queue {
    pub fn read(runner: &dyn Runner) -> Queue {
        let mut q = Queue::default();
        match list(runner, "all") {
            Ok(items) => q.items = items,
            Err(e) => q.errors.push(format!("agent-queue list: {e}")),
        }
        match stats(runner) {
            Ok(s) => q.stats = Some(s),
            Err(e) => q.errors.push(e),
        }
        q
    }

    pub fn in_state(&self, s: State) -> impl Iterator<Item = &Item> {
        self.items.iter().filter(move |i| i.state == s)
    }

    pub fn count(&self, s: State) -> usize {
        self.in_state(s).count()
    }
}

/// A slug as agent-queue writes it, so nothing else reaches its argv.
fn is_slug(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// `agent-queue cancel <slug>`: a running item's session is killed with it. Its output, or why
/// it was refused.
pub fn cancel(runner: &dyn Runner, slug: &str) -> Result<String, String> {
    if !is_slug(slug) {
        return Err("bad slug".into());
    }
    runner.run(&argv(&["cancel", slug]))
}

/// `agent-queue bump <slug> <priority>`.
pub fn bump(runner: &dyn Runner, slug: &str, priority: &str) -> Result<String, String> {
    if !is_slug(slug) {
        return Err("bad slug".into());
    }
    if !PRIORITIES.contains(&priority) {
        return Err("priority is urgent, high, normal or low".into());
    }
    runner.run(&argv(&["bump", slug, priority]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Serves canned output per verb and records every argv.
    #[derive(Default)]
    struct Fake {
        list: Option<&'static str>,
        stats: Option<&'static str>,
        calls: RefCell<Vec<String>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            let out = match argv.get(1).map(String::as_str) {
                Some("list") => self.list,
                Some("stats") => self.stats,
                _ => Some(""),
            };
            out.map(String::from)
                .ok_or_else(|| "agent-queue: no".into())
        }
    }

    const LIST: &str = concat!(
        r#"{"slug":"w","project":"game","mode":"plan","priority":"high","from":"human","agent":"claude","queued":"2026-11-03T10:00:00Z","session":"lab:game-agent-2","state":"waiting","file":"/q/waiting/w.md","task":"Pick a side\nthen more"}"#,
        "\n",
        "not json\n",
        r#"{"slug":"q","project":"dotfiles","mode":"oneshot","priority":"normal","tags":"night at:02:30","after":"w","queued":"2026-11-03T11:00:00Z","state":"queued","task":"later","hold":"after w"}"#,
        "\n",
        r#"{"slug":"nostate","task":"x"}"#,
        "\n",
        r#"{"slug":"d","project":"game","priority":"low","state":"done","status":"cancelled","finished":"2026-11-03T12:00:00Z","pr":"812","task":"t"}"#,
        "\n",
    );

    #[test]
    fn list_types_each_item_and_skips_a_line_that_is_not_one() {
        let fake = Fake {
            list: Some(LIST),
            ..Fake::default()
        };
        let items = list(&fake, "all").unwrap();
        assert_eq!(
            fake.calls.borrow()[0],
            "agent-queue list --json --state all"
        );
        let slugs: Vec<&str> = items.iter().map(|i| i.slug.as_str()).collect();
        assert_eq!(slugs, ["w", "q", "d"], "no state is not an item");
        let (w, q, d) = (&items[0], &items[1], &items[2]);
        assert_eq!(w.state, State::Waiting);
        assert_eq!(w.session.as_deref(), Some("lab:game-agent-2"));
        assert_eq!(w.title(), "Pick a side");
        assert_eq!(q.tag_list().collect::<Vec<_>>(), ["night", "at:02:30"]);
        assert_eq!(q.hold.as_deref(), Some("after w"));
        assert_eq!(d.status.as_deref(), Some("cancelled"));
        assert_eq!(d.pr.as_deref(), Some("812"));
    }

    #[test]
    fn an_item_hands_on_every_key_agent_queue_printed() {
        let items = parse(LIST);
        let back = serde_json::to_value(&items[0]).unwrap();
        let orig: Value = serde_json::from_str(LIST.lines().next().unwrap()).unwrap();
        assert_eq!(back, orig, "agent and file ride in extra");
        let q = serde_json::to_value(&items[1]).unwrap();
        assert_eq!(
            q["tags"], "night at:02:30",
            "tags stay one string for the page"
        );
        assert!(
            q.get("session").is_none(),
            "an absent key is not written as null"
        );
    }

    #[test]
    fn read_keeps_what_it_could_and_says_what_it_could_not() {
        let fake = Fake {
            list: Some(LIST),
            stats: Some(
                r#"{"since":"2026-10-27","active":{"queued":1},"done":{"ok":3},"wait_minutes_median":12,"run_minutes_median":null,"to_pr_minutes_median":95,"per_day":{"2026-11-03":3},"by_project":{"game":{"done":3,"ok":3,"failed":0,"cancelled":0,"prs":2,"wait_minutes_median":12,"to_pr_minutes_median":95}},"by_source":{},"done_by_tag":{}}"#,
            ),
            ..Fake::default()
        };
        let q = Queue::read(&fake);
        assert!(q.errors.is_empty(), "{:?}", q.errors);
        assert_eq!(q.count(State::Queued), 1);
        let s = q.stats.unwrap();
        assert_eq!(s.to_pr_minutes_median, Some(95));
        assert_eq!(s.run_minutes_median, None);
        assert_eq!(s.by_project["game"].prs, 2);

        let q = Queue::read(&Fake::default());
        assert!(q.items.is_empty() && q.stats.is_none());
        assert_eq!(q.errors.len(), 2, "{:?}", q.errors);
    }

    #[test]
    fn cancel_and_bump_are_agent_queue_argv_and_refuse_an_option() {
        let fake = Fake::default();
        cancel(&fake, "w").unwrap();
        bump(&fake, "q", "urgent").unwrap();
        assert!(cancel(&fake, "--all").is_err());
        assert!(cancel(&fake, "a b").is_err());
        assert!(bump(&fake, "q", "now").is_err());
        assert_eq!(
            *fake.calls.borrow(),
            ["agent-queue cancel w", "agent-queue bump q urgent"]
        );
    }

    #[test]
    fn bump_steps_along_the_scale_and_stops_at_its_ends() {
        let mut i = Item {
            priority: "normal".into(),
            ..Item::default()
        };
        assert_eq!(i.bumped(true), Some("high"));
        assert_eq!(i.bumped(false), Some("low"));
        i.priority = "urgent".into();
        assert_eq!(i.bumped(true), None);
        i.priority = "low".into();
        assert_eq!(i.bumped(false), None);
        i.priority = "asap".into();
        assert_eq!(i.bumped(true), None);
    }
}
