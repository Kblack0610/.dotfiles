//! The hub's tabs, in order, for both surfaces: the `hub` TUI's tab bar and agent-web's. Each
//! surface lists its tabs from here and a test on each side fails when they drift, so the two
//! cannot name or order a tab differently. The layout and its rules: `docs/dashboards.md`.

/// One tab: its id (the `#name` URL and `hub --tab name`), title, the question it answers, and
/// its section ids in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tab {
    pub id: &'static str,
    pub title: &'static str,
    pub question: &'static str,
    pub sections: &'static [&'static str],
}

pub const TABS: [Tab; 8] = [
    // The landing page: every action that waits on the human, then the summary lines.
    Tab {
        id: "home",
        title: "Home",
        question: "What needs me, and is everything OK?",
        sections: &["needs", "running", "numbers", "health"],
    },
    // The daily note, its links row first; the outbox (the doc and Handled today) opens from
    // that row, so it is a section here, not a tab of its own.
    Tab {
        id: "daily",
        title: "Daily",
        question: "What is my day?",
        sections: &["links", "lanes", "rollup", "sections", "outbox"],
    },
    Tab {
        id: "queue",
        title: "Queue",
        question: "What will agents do next?",
        sections: &["waiting", "running", "queued", "done"],
    },
    Tab {
        id: "projects",
        title: "Projects",
        question: "Where is each project, and its tasks?",
        sections: &["cards", "rows"],
    },
    Tab {
        id: "sessions",
        title: "Sessions",
        question: "What is each agent doing?",
        sections: &["shepherd", "sessions", "detail"],
    },
    Tab {
        id: "infra",
        title: "Infra",
        question: "Is the machinery healthy?",
        sections: &[
            "health", "red", "machines", "ci", "jobs", "cloud", "governor",
        ],
    },
    Tab {
        id: "log",
        title: "Log",
        question: "What happened?",
        sections: &[
            "day", "history", "actions", "changes", "rundowns", "verdicts", "forecast", "ranked",
        ],
    },
    Tab {
        id: "fleet",
        title: "Fleet",
        question: "Can I afford more agents, and are the judges right?",
        sections: &["accounts", "workers", "judges"],
    },
];

/// A folded Log section lists at most this many rows, then "+N older". agent-web's `LOG_ROWS`
/// (static/ui.js) is this number; its assets test checks.
pub const FOLD_ROWS: usize = 50;

/// Retired tab names and the tab that took their place, so a bookmark, a waybar `on-click` or
/// `hub --tab <old>` still lands somewhere. Keep a name here for good once it has shipped.
pub const RETIRED: &[(&str, &str)] = &[
    // agent-web's Waiting tab (its section id was `asks`) and the TUI's Overview: both became Home.
    ("waiting", "home"),
    ("asks", "home"),
    ("overview", "home"),
    // Both surfaces' Board tab: its rows are the Projects tab's, one project at a time or All.
    ("board", "projects"),
    // agent-web's Watch and Shepherd: one row per session on Sessions, the shepherd pinned first.
    ("watch", "sessions"),
    ("shepherd", "sessions"),
    // The TUI's Jobs, CI and Machines tabs and agent-web's Jobs tab: sections of Infra now,
    // one MACHINES table in place of POOLS, CI by machine and the Machines tab.
    ("jobs", "infra"),
    ("ci", "infra"),
    ("machines", "infra"),
    // The TUI's Today and History and agent-web's Actions: Log's day view, its day list and its
    // folded Actions section. The TUI's Forecast (its timeline is the Sessions ETA column and
    // detail pane) left its burn-up and baseline as Log's Forecast section.
    ("today", "log"),
    ("history", "log"),
    ("actions", "log"),
    ("forecast", "log"),
    // The Outbox tab (the landing page until 2026-11-05) is a section of Daily, opened from its
    // links row; Focus is Daily, the daily note's own name.
    ("outbox", "daily"),
    ("focus", "daily"),
];

/// A tab id, a title, or a retired name (any case) as the tab it means.
pub fn resolve(name: &str) -> Option<&'static Tab> {
    let n = name.trim().to_ascii_lowercase();
    let id = RETIRED
        .iter()
        .find(|(old, _)| *old == n)
        .map_or(n.as_str(), |(_, new)| new);
    TABS.iter()
        .find(|t| t.id == id || t.title.eq_ignore_ascii_case(id))
}

/// The section a retired name opens on its new tab, when that name is one of the tab's
/// sections (`ci` -> Infra's CI section), so an old link lands where its content went.
pub fn section(name: &str) -> Option<&'static str> {
    let n = name.trim().to_ascii_lowercase();
    let tab = resolve(&n)?;
    tab.sections
        .iter()
        .copied()
        .find(|s| *s == n && tab.id != n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_a_retired_name_is_never_a_live_id() {
        let mut ids: Vec<&str> = TABS.iter().map(|t| t.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), TABS.len());
        for (old, new) in RETIRED {
            assert!(!ids.contains(old), "{old} is retired and live");
            assert!(resolve(new).is_some(), "{old} points at {new}, not a tab");
        }
    }

    #[test]
    fn a_retired_name_or_a_title_resolves_to_its_tab() {
        assert_eq!(resolve("waiting").map(|t| t.id), Some("home"));
        assert_eq!(resolve("Overview").map(|t| t.id), Some("home"));
        assert_eq!(resolve("QUEUE").map(|t| t.id), Some("queue"));
        assert_eq!(resolve("focus").map(|t| t.id), Some("daily"));
        assert_eq!(resolve("Outbox").map(|t| t.id), Some("daily"));
        assert_eq!(resolve("Daily").map(|t| t.id), Some("daily"));
        assert_eq!(TABS[0].id, "home", "the landing page leads");
        assert_eq!(resolve("board").map(|t| t.id), Some("projects"));
        assert_eq!(resolve("forecast").map(|t| t.id), Some("log"));
        assert_eq!(resolve("Watch").map(|t| t.id), Some("sessions"));
        assert_eq!(resolve("shepherd").map(|t| t.id), Some("sessions"));
        assert_eq!(resolve("jobs").map(|t| t.id), Some("infra"));
        assert_eq!(resolve("CI").map(|t| t.id), Some("infra"));
        assert_eq!(resolve("machines").map(|t| t.id), Some("infra"));
        assert_eq!(resolve("Today").map(|t| t.id), Some("log"));
        assert_eq!(resolve("history").map(|t| t.id), Some("log"));
        assert_eq!(resolve("actions").map(|t| t.id), Some("log"));
        assert_eq!(resolve("fleet").map(|t| t.id), Some("fleet"));
        assert_eq!(resolve("nope"), None);
    }

    #[test]
    fn a_retired_name_that_became_a_section_opens_that_section() {
        assert_eq!(section("ci"), Some("ci"));
        assert_eq!(section("Machines"), Some("machines"));
        assert_eq!(section("jobs"), Some("jobs"));
        assert_eq!(section("shepherd"), Some("shepherd"));
        assert_eq!(section("history"), Some("history"));
        assert_eq!(section("actions"), Some("actions"));
        assert_eq!(section("forecast"), Some("forecast"));
        assert_eq!(section("today"), None, "the day view is Log's top");
        assert_eq!(section("outbox"), Some("outbox"));
        assert_eq!(section("focus"), None, "Daily has no focus section");
        assert_eq!(section("infra"), None, "a live tab is not a section");
        assert_eq!(section("waiting"), None, "Home has no waiting section");
        assert_eq!(section("nope"), None);
    }
}
