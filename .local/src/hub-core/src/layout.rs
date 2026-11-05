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
    /// False until the phase that builds the tab lands; until then each surface keeps its own
    /// older tabs for that question after the landed ones.
    pub landed: bool,
}

pub const TABS: [Tab; 7] = [
    Tab {
        id: "home",
        title: "Home",
        question: "What needs me, and is everything OK?",
        sections: &["needs", "running", "numbers", "health"],
        landed: true,
    },
    Tab {
        id: "queue",
        title: "Queue",
        question: "What will agents do next?",
        sections: &["waiting", "running", "queued", "done"],
        landed: true,
    },
    Tab {
        id: "projects",
        title: "Projects",
        question: "Where is each project, and its tasks?",
        sections: &["cards", "rows"],
        landed: true,
    },
    Tab {
        id: "sessions",
        title: "Sessions",
        question: "What is each agent doing?",
        sections: &[],
        landed: false,
    },
    Tab {
        id: "infra",
        title: "Infra",
        question: "Is the machinery healthy?",
        sections: &[],
        landed: false,
    },
    Tab {
        id: "log",
        title: "Log",
        question: "What happened?",
        sections: &[],
        landed: false,
    },
    Tab {
        id: "fleet",
        title: "Fleet",
        question: "Can I afford more agents, and are the judges right?",
        sections: &[],
        landed: false,
    },
];

/// Retired tab names and the tab that took their place, so a bookmark, a waybar `on-click` or
/// `hub --tab <old>` still lands somewhere. Keep a name here for good once it has shipped.
pub const RETIRED: &[(&str, &str)] = &[
    // agent-web's Waiting tab (its section id was `asks`) and the TUI's Overview: both became Home.
    ("waiting", "home"),
    ("asks", "home"),
    ("overview", "home"),
    // Both surfaces' Board tab: its rows are the Projects tab's, one project at a time or All.
    ("board", "projects"),
];

/// The landed tabs, in order.
pub fn landed() -> impl Iterator<Item = &'static Tab> {
    TABS.iter().filter(|t| t.landed)
}

/// A tab id, a title, or a retired name (any case) as the landed tab it means.
pub fn resolve(name: &str) -> Option<&'static Tab> {
    let n = name.trim().to_ascii_lowercase();
    let id = RETIRED
        .iter()
        .find(|(old, _)| *old == n)
        .map_or(n.as_str(), |(_, new)| new);
    landed().find(|t| t.id == id || t.title.eq_ignore_ascii_case(id))
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
            assert!(
                resolve(new).is_some(),
                "{old} points at {new}, not a landed tab"
            );
        }
    }

    #[test]
    fn a_retired_name_or_a_title_resolves_to_its_tab() {
        assert_eq!(resolve("waiting").map(|t| t.id), Some("home"));
        assert_eq!(resolve("Overview").map(|t| t.id), Some("home"));
        assert_eq!(resolve("QUEUE").map(|t| t.id), Some("queue"));
        assert_eq!(resolve("board").map(|t| t.id), Some("projects"));
        assert_eq!(resolve("sessions"), None, "not landed yet");
        assert_eq!(resolve("nope"), None);
    }
}
