//! The sessions ranked by friction and one session's card, for the "Ranked sessions" fold at the
//! bottom of Sessions on both surfaces. `agentctl-session-outcomes` owns the outcome rows, the
//! friction score and its words (`~/.config/agentctl/DREAMING.md`, "Session outcomes"), so this
//! module never opens `~/.agent/outcomes`: it runs `worst --json`, `card` and `ran` through a
//! `Runner`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::session_actions::Runner;
use crate::text::{cap, headline, TITLE_MAX};

/// The window and the list's length: a week, the twenty to look at first.
pub const DAYS: u32 = 7;
pub const TOP: u32 = 20;

/// One ranked session: the outcome row's fields the list shows. The card has the rest.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Ranked {
    pub session_id: String,
    pub project: String,
    pub title: String,
    pub updated: String,
    pub friction: i64,
    pub why: String,
    pub cost_usd: Option<f64>,
    pub duration_s: Option<f64>,
    /// None when the session's transcript was pruned and nothing else names its PRs: unknown, not 0.
    pub prs_merged: Option<i64>,
    pub prs_open: Option<i64>,
    pub prs_closed_unmerged: Option<i64>,
}

impl Ranked {
    /// The row as the TUI prints it: friction, id, project, wall time, cost, PRs, then why.
    pub fn line(&self) -> String {
        let wall = crate::display::fmt::dur_min(self.duration_s.map(|s| (s / 60.0) as i64));
        let cost = self.cost_usd.map_or("-".into(), |c| format!("${c:.2}"));
        let prs = match (self.prs_merged, self.prs_open, self.prs_closed_unmerged) {
            (Some(m), Some(o), Some(c)) => format!("{m}/{}", m + o + c),
            _ => "?".into(),
        };
        format!(
            "{:>3}  {}  {:<12} {:>6} {:>8}  {} PRs  {}  {}",
            self.friction,
            self.session_id.get(..8).unwrap_or(&self.session_id),
            cap(&self.project, 12),
            wall,
            cost,
            prs,
            cap(&headline(&self.title).0, TITLE_MAX),
            self.why,
        )
    }
}

fn argv(args: &[&str]) -> Vec<String> {
    std::iter::once("agentctl-session-outcomes")
        .chain(args.iter().copied())
        .map(String::from)
        .collect()
}

/// The sessions with friction in the last `DAYS`, worst first, at most `TOP`. A line that is not
/// a row is skipped.
pub fn ranked(runner: &dyn Runner) -> Result<Vec<Ranked>, String> {
    let (days, top) = (DAYS.to_string(), TOP.to_string());
    let out = runner.run(&argv(&["worst", "--json", "--days", &days, "-n", &top]))?;
    Ok(out
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect())
}

/// One session that ran a skill: its outcome row's identity and the skill's calls in it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Ran {
    pub skill: String,
    pub calls: u64,
    pub session_id: String,
    pub project: String,
    pub title: Option<String>,
    pub updated: Option<String>,
}

/// Each skill's newest `top` sessions over `days`, by skill, newest first
/// (`agentctl-session-outcomes ran`). A line that is not a row is skipped.
pub fn ran(
    runner: &dyn Runner,
    days: usize,
    top: usize,
) -> Result<BTreeMap<String, Vec<Ran>>, String> {
    let (days, top) = (days.to_string(), top.to_string());
    let out = runner.run(&argv(&["ran", "--days", &days, "-n", &top]))?;
    let mut by: BTreeMap<String, Vec<Ran>> = BTreeMap::new();
    for r in out
        .lines()
        .filter_map(|l| serde_json::from_str::<Ran>(l).ok())
        .filter(|r| !r.skill.is_empty() && !r.session_id.is_empty())
    {
        by.entry(r.skill.clone()).or_default().push(r);
    }
    Ok(by)
}

/// One session's card as `agentctl-session-outcomes card` words it. The id is checked first, so
/// nothing but a session id reaches the command line.
pub fn card(runner: &dyn Runner, session_id: &str) -> Result<String, String> {
    let ok = session_id.len() >= 8
        && session_id.len() <= 64
        && session_id
            .chars()
            .all(|c| c.is_ascii_hexdigit() || c == '-');
    if !ok {
        return Err(format!("not a session id: {}", cap(session_id, 40)));
    }
    runner.run(&argv(&["card", session_id]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Fake {
        out: &'static str,
        calls: RefCell<Vec<String>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            Ok(self.out.into())
        }
    }

    const WORST: &str = concat!(
        r#"{"session_id":"6f296b73-b7a5-4f30-8046-5d583d1f7c61","project":"dotfiles","title":"fix the gate","friction":11,"why":"2 x 1 closed unmerged + 9 nudges","cost_usd":41.2,"duration_s":22200,"prs_merged":24,"prs_open":0,"prs_closed_unmerged":1,"activity":{"tool_calls":3}}"#,
        "\n",
        "not json\n",
        r#"{"session_id":"aa","friction":1}"#,
        "\n",
    );

    #[test]
    fn ranked_runs_worst_and_types_each_row() {
        let fake = Fake {
            out: WORST,
            ..Fake::default()
        };
        let rows = ranked(&fake).unwrap();
        assert_eq!(
            fake.calls.borrow()[0],
            "agentctl-session-outcomes worst --json --days 7 -n 20"
        );
        assert_eq!(rows.len(), 2, "the line that is not JSON is skipped");
        assert_eq!(rows[1].cost_usd, None);
        assert!(rows[1].line().contains(" ? PRs "), "{}", rows[1].line());
        assert_eq!(
            rows[0].line(),
            " 11  6f296b73  dotfiles      6h10m   $41.20  24/25 PRs  fix the gate  2 x 1 closed unmerged + 9 nudges"
        );
    }

    #[test]
    fn ran_groups_each_skills_sessions_in_the_order_the_command_gave_them() {
        let fake = Fake {
            out: concat!(
                r#"{"skill":"a","calls":2,"session_id":"s2","project":"p","title":"t","updated":"u"}"#,
                "\n",
                r#"{"skill":"a","calls":1,"session_id":"s1","project":"p","title":null,"updated":null}"#,
                "\n",
                r#"{"skill":"b","calls":1,"session_id":"s3","project":"q"}"#,
                "\nnot json\n",
                r#"{"skill":"","session_id":"s4"}"#,
                "\n",
            ),
            ..Fake::default()
        };
        let by = ran(&fake, 30, 10).unwrap();
        assert_eq!(
            fake.calls.borrow()[0],
            "agentctl-session-outcomes ran --days 30 -n 10"
        );
        assert_eq!(by.keys().collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!(by["a"][0].session_id, "s2");
        assert_eq!(by["a"][1].session_id, "s1");
        assert_eq!(by["a"][1].title, None);
    }

    #[test]
    fn card_passes_only_a_session_id() {
        let fake = Fake {
            out: "card text",
            ..Fake::default()
        };
        assert_eq!(card(&fake, "6f296b73").unwrap(), "card text");
        assert_eq!(
            fake.calls.borrow()[0],
            "agentctl-session-outcomes card 6f296b73"
        );
        for bad in ["6f29", "--json", "6f296b73; rm -rf /", "../../etc/passwd"] {
            assert!(card(&fake, bad).is_err(), "{bad}");
        }
        assert_eq!(fake.calls.borrow().len(), 1, "a refused id runs nothing");
    }
}
