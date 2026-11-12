//! The hub's tabs, in order, for both surfaces: the `hub` TUI's tab bar and agent-web's. Each
//! surface lists its tabs from here and a test on each side fails when they drift, so the two
//! cannot name or order a tab differently. The layout and its rules: `docs/dashboards.md`.

/// One inner tab: a strip entry inside one tab that shows a named group of that tab's sections.
/// Its id is the `#tab/id` URL word; a section id names it too, for the inner tab holding it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Inner {
    pub id: &'static str,
    pub title: &'static str,
    pub sections: &'static [&'static str],
}

/// One tab: its id (the `#name` URL and `hub --tab name`), title, the question it answers, and
/// its section ids in order. A tab with inner tabs lists its `pinned` sections (always shown,
/// above the strip) and then each inner tab's sections, so `sections` is those, concatenated:
/// the section ids never change when a tab gains a strip, and every old link still lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tab {
    pub id: &'static str,
    /// The sidebar heading agent-web files it under. Each group is one run of `TABS`, so a heading
    /// never splits the order or moves a digit.
    pub group: &'static str,
    pub title: &'static str,
    pub question: &'static str,
    pub sections: &'static [&'static str],
    pub pinned: &'static [&'static str],
    pub inner: &'static [Inner],
}

pub const TABS: [Tab; 13] = [
    // The landing page: every action that waits on the human, then the summary lines.
    Tab {
        id: "home",
        group: "Today",
        title: "Home",
        question: "What needs me, and is everything OK?",
        sections: &["needs", "proposals", "running", "spend", "vitals", "health"],
        pinned: &[],
        inner: &[],
    },
    // The daily note behind its nav (the places, Daily first, then the note's parts); the outbox
    // (the doc and Handled today) opens from that nav, so it is a section here, not a tab of its own.
    // The day's briefing is drawn as one of the note's sections.
    Tab {
        id: "daily",
        group: "Today",
        title: "Daily",
        question: "What is my day?",
        sections: &["nav", "lanes", "briefing", "rollup", "sections", "outbox"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "log",
        group: "Today",
        title: "Log",
        question: "What happened?",
        sections: &[
            "work", "day", "history", "actions", "changes", "rundowns", "verdicts", "forecast",
            "ranked",
        ],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "queue",
        group: "Agents",
        title: "Queue",
        question: "What will agents do next?",
        sections: &["flow", "table", "candidates"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "sessions",
        group: "Agents",
        title: "Sessions",
        question: "What is each agent doing?",
        sections: &["shepherd", "sessions", "detail"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "fleet",
        group: "Agents",
        title: "Fleet",
        question: "Who is working, and on what?",
        sections: &["workers"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "projects",
        group: "Projects",
        title: "Projects",
        question: "Where is each project, and its tasks?",
        sections: &["cards", "rows"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "board",
        group: "Projects",
        title: "Board",
        question: "What is on every project's board?",
        sections: &["rows"],
        pinned: &[],
        inner: &[],
    },
    // The channels (`hub_core::releases`) and each opened row, then Release runs: the CI runs the
    // graph tied to a release (`builds::Builds::releases`). Every other CI run is Infra's.
    Tab {
        id: "releases",
        group: "Projects",
        title: "Releases",
        question: "What is live where, and which builds made it?",
        sections: &["table", "detail", "runs"],
        // Two questions: what is live where (the apps and an opened one), and the runs that
        // built and shipped a release.
        pinned: &[],
        inner: &[
            Inner {
                id: "apps",
                title: "Apps",
                sections: &["table", "detail"],
            },
            Inner {
                id: "runs",
                title: "Release runs",
                sections: &["runs"],
            },
        ],
    },
    Tab {
        id: "alerts",
        group: "System",
        title: "Alerts",
        question: "What is firing, who owns it, and what fired lately?",
        // hub_core::alerts: the health chips, what fires with its fix's owner, the fixes, the
        // alert pages of the week, then every watch (folded while none is red).
        sections: &["health", "firing", "fixes", "history", "watches"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "infra",
        group: "System",
        title: "Infra",
        question: "Is the machinery healthy?",
        sections: &["machines", "pools", "ci", "runs", "tests", "jobs"],
        // What is red and its fixes moved to Alerts (MOVED); the governor's verdict and the
        // cloud power are columns of the machine they act on. CI is the runners, their queue and
        // finished runs, every run of 30 days with its run times and the quarantine
        // (`hub_core::builds`), and the declared test workflows' suites (`hub_core::junit`).
        pinned: &[],
        inner: &[
            Inner {
                id: "machines",
                title: "Machines",
                sections: &["machines", "pools"],
            },
            Inner {
                id: "ci",
                title: "CI",
                sections: &["ci", "runs", "tests"],
            },
            Inner {
                id: "jobs",
                title: "Jobs",
                sections: &["jobs"],
            },
        ],
    },
    Tab {
        id: "schedules",
        group: "System",
        title: "Schedules",
        question: "What runs on its own, and why?",
        sections: &["table", "detail"],
        pinned: &[],
        inner: &[],
    },
    // Every dollar figure the other tabs showed is here, cut eight ways; they keep a one-line
    // badge that links in.
    Tab {
        id: "costs",
        group: "System",
        title: "Costs",
        question:
            "How fast are the limits burning, what does the fleet cost, and is each model worth it?",
        sections: &[
            "fleet",
            "burn",
            "consumers",
            "sessions",
            "spend",
            "totals",
            "table",
            "tokens",
            "langfuse",
            "sections",
            "budget",
        ],
        // The 24h fleet figure stays above the strip; the strip splits the four questions. Budget
        // is cash (the bills we pay); the 24h figure and the rest of the tab are list price.
        pinned: &["fleet"],
        inner: &[
            Inner {
                id: "limits",
                title: "Limits",
                sections: &["burn", "consumers"],
            },
            Inner {
                id: "spend",
                title: "Spend",
                sections: &["sessions", "spend", "totals", "table"],
            },
            Inner {
                id: "models",
                title: "Models",
                sections: &["tokens", "langfuse", "sections"],
            },
            Inner {
                id: "budget",
                title: "Budget",
                sections: &["budget"],
            },
        ],
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
    // Home's Numbers heading: the session counts head Running and the spend is its own SPEND line.
    ("numbers", "home"),
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
    // nav; Focus is Daily, the daily note's own name.
    ("outbox", "daily"),
    ("focus", "daily"),
];

/// Sections that moved to another tab: (old tab, old section, new tab, new section), so
/// `hub tab fleet tokens`, `hub --tab 'fleet tokens'` and agent-web's `#fleet/tokens` still land
/// where the content went. Keep a row here for good once it has shipped.
pub const MOVED: &[(&str, &str, &str, &str)] = &[
    // Fleet's Claude accounts table, Where the tokens go and What Langfuse sees: what the fleet
    // costs, not who is working (2026-11-07). The accounts' columns joined Costs' Burn table.
    ("fleet", "accounts", "costs", "burn"),
    ("fleet", "tokens", "costs", "tokens"),
    ("fleet", "langfuse", "costs", "langfuse"),
    // Infra's health chips, Red now and Red fixes (with its Reds inner tab): what is firing and
    // who owns it is Alerts' question, not the machinery's (2026-11-11).
    ("infra", "health", "alerts", "health"),
    ("infra", "red", "alerts", "firing"),
    ("infra", "fixes", "alerts", "fixes"),
    ("infra", "reds", "alerts", "fixes"),
    // Infra's Governor panel and Cloud tab: the governor's verdict and each cloud host's power
    // are columns of the machine they act on (2026-11-11). agent-web opens them filtered.
    ("infra", "governor", "infra", "machines"),
    ("infra", "cloud", "infra", "machines"),
    // Releases' Builds and Tests inner tabs: CI that ships no release is the machinery's
    // question; Releases keeps the runs tied to a release (2026-11-12, P5 of
    // better-release-data-need-polished-dragonfly.md).
    ("releases", "builds", "infra", "runs"),
    ("releases", "tests", "infra", "tests"),
];

/// A moved name that opens its new table under a state chip, on both surfaces: (tab, old
/// section, table, chip). agent-web's app.js MOVED carries the same chips as a query.
pub const MOVED_CHIPS: &[(&str, &str, &str, &str)] = &[
    ("infra", "governor", "machines", "governed"),
    ("infra", "cloud", "machines", "cloud"),
];

/// The table and chip a moved name opens under (`MOVED_CHIPS`), any case.
pub fn moved_chip(tab: &str, sec: &str) -> Option<(&'static str, &'static str)> {
    let id = resolve(&tab.trim().to_ascii_lowercase())?.id;
    let sec = sec.trim().to_ascii_lowercase();
    MOVED_CHIPS
        .iter()
        .find(|m| m.0 == id && m.1 == sec)
        .map(|m| (m.2, m.3))
}

/// The layout's tabs the TUI's number row leaves off: Daily, which only agent-web lists, and
/// Board, which is `a` on Projects there.
pub const OFF_BAR: [&str; 2] = ["daily", "board"];

/// A tab's key on the TUI's number row: 1 for the first, 0 for the tenth; a tab past the tenth
/// has none (Tab and Shift-Tab still reach it).
pub fn bar_digit(id: &str) -> Option<usize> {
    TABS.iter()
        .filter(|t| !OFF_BAR.contains(&t.id))
        .position(|t| t.id == id)
        .filter(|i| *i < 10)
        .map(|i| (i + 1) % 10)
}

/// A tab as the TUI's text names it: its bar digit and title (`8 Alerts`), or the title alone for
/// a tab with no digit, so a badge or hint never names a stale key after a reorder.
pub fn bar_label(id: &str) -> String {
    let title = resolve(id).map_or(id, |t| t.title);
    bar_digit(id).map_or(title.to_string(), |d| format!("{d} {title}"))
}

/// Where a section that moved off `tab` lives now: its new tab and section.
pub fn moved(tab: &str, sec: &str) -> Option<(&'static Tab, &'static str)> {
    let (t, s) = (
        tab.trim().to_ascii_lowercase(),
        sec.trim().to_ascii_lowercase(),
    );
    let id = resolve(&t)?.id;
    MOVED
        .iter()
        .find(|m| m.0 == id && m.1 == s)
        .and_then(|m| Some((resolve(m.2)?, m.3)))
}

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

/// The inner tab a request word opens on `tab`: a section id (an old link) opens the inner tab
/// holding it, an inner tab's id opens it, and a missing, unknown or pinned word opens the
/// first. None when the tab has no inner tabs.
pub fn inner_tab(tab: &Tab, name: Option<&str>) -> Option<&'static Inner> {
    let n = name.unwrap_or_default().trim().to_ascii_lowercase();
    tab.inner
        .iter()
        .find(|i| i.sections.contains(&n.as_str()))
        .or_else(|| tab.inner.iter().find(|i| i.id == n))
        .or_else(|| tab.inner.first())
}

/// How many of an inner tab's sections are in `flagged` (the ones needing a look), the count its
/// label carries when above zero, so a red behind an unselected inner tab still shows.
pub fn inner_count(inner: &Inner, flagged: &[&str]) -> usize {
    inner
        .sections
        .iter()
        .filter(|s| flagged.contains(s))
        .count()
}

/// Why a tab's groups are not sound: `sections` must be its pinned sections then each inner
/// tab's, in that order, which puts every section in exactly one place.
pub fn groups_check(tab: &Tab) -> Result<(), String> {
    if tab.inner.is_empty() {
        return if tab.pinned.is_empty() {
            Ok(())
        } else {
            Err(format!("{} pins sections but has no inner tabs", tab.id))
        };
    }
    let grouped: Vec<&str> = tab
        .pinned
        .iter()
        .copied()
        .chain(tab.inner.iter().flat_map(|i| i.sections.iter().copied()))
        .collect();
    if grouped != tab.sections {
        return Err(format!(
            "{}: pinned and inner sections {grouped:?} are not its sections {:?}",
            tab.id, tab.sections
        ));
    }
    for i in tab.inner {
        if i.sections.is_empty() {
            return Err(format!("{}: inner tab {} is empty", tab.id, i.id));
        }
        // An id that is also a section must name the inner tab holding that section.
        if tab.sections.contains(&i.id) && !i.sections.contains(&i.id) {
            return Err(format!(
                "{}: {} names a section of another inner tab",
                tab.id, i.id
            ));
        }
    }
    let mut ids: Vec<&str> = tab.inner.iter().map(|i| i.id).collect();
    ids.sort();
    ids.dedup();
    if ids.len() != tab.inner.len() {
        return Err(format!("{}: inner tab ids repeat", tab.id));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_group_is_one_run_of_the_tabs() {
        let mut seen: Vec<&str> = Vec::new();
        for t in &TABS {
            if seen.last() != Some(&t.group) {
                assert!(!seen.contains(&t.group), "{} splits {}", t.id, t.group);
                seen.push(t.group);
            }
        }
    }

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
        assert_eq!(resolve("numbers").map(|t| t.id), Some("home"));
        assert_eq!(resolve("QUEUE").map(|t| t.id), Some("queue"));
        assert_eq!(resolve("focus").map(|t| t.id), Some("daily"));
        assert_eq!(resolve("Outbox").map(|t| t.id), Some("daily"));
        assert_eq!(resolve("Daily").map(|t| t.id), Some("daily"));
        assert_eq!(TABS[0].id, "home", "the landing page leads");
        assert_eq!(resolve("board").map(|t| t.id), Some("board"));
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
        assert_eq!(resolve("Costs").map(|t| t.id), Some("costs"));
        assert_eq!(resolve("nope"), None);
    }

    #[test]
    fn a_moved_section_lands_on_its_new_tab_and_is_gone_from_the_old() {
        for (old_tab, old, new_tab, new) in MOVED {
            let from = resolve(old_tab).unwrap();
            assert!(!from.sections.contains(old), "{old} is still on {old_tab}");
            let to = resolve(new_tab).unwrap();
            assert!(
                to.sections.contains(new),
                "{new} is not a section of {new_tab}"
            );
        }
        assert_eq!(
            moved("Fleet", " Tokens ").map(|(t, s)| (t.id, s)),
            Some(("costs", "tokens"))
        );
        assert_eq!(
            moved("fleet", "accounts").map(|(t, s)| (t.id, s)),
            Some(("costs", "burn"))
        );
        assert_eq!(
            moved("fleet", "langfuse").map(|(t, s)| (t.id, s)),
            Some(("costs", "langfuse"))
        );
        assert_eq!(moved("fleet", "workers"), None, "workers stayed");
        assert_eq!(
            moved("fleet", "inbox-triage"),
            None,
            "a runner is no section"
        );
        assert_eq!(moved("costs", "tokens"), None);
        // Infra's old links (`#infra/red`, `hub tab infra fixes`) land on Alerts.
        for (old, new) in [
            ("red", "firing"),
            ("reds", "fixes"),
            ("fixes", "fixes"),
            ("health", "health"),
        ] {
            assert_eq!(
                moved("infra", old).map(|(t, s)| (t.id, s)),
                Some(("alerts", new)),
                "{old}"
            );
        }
        assert_eq!(moved("infra", "machines"), None, "machines stayed");
        for old in ["governor", "cloud"] {
            assert_eq!(
                moved("infra", old).map(|(t, s)| (t.id, s)),
                Some(("infra", "machines")),
                "{old}"
            );
        }
        // Each opens Machines under its chip, a chip the table has.
        assert_eq!(
            moved_chip("Infra", " Governor "),
            Some(("machines", "governed"))
        );
        assert_eq!(moved_chip("infra", "cloud"), Some(("machines", "cloud")));
        assert_eq!(moved_chip("infra", "machines"), None);
        for (_, old, table, chip) in MOVED_CHIPS {
            assert!(MOVED.iter().any(|m| m.1 == *old && m.3 == *table), "{old}");
            assert!(<crate::machines::Machine as crate::table::Row>::STATES.contains(chip));
        }
        assert_eq!(resolve("fleet").unwrap().sections, ["workers"]);
        // Releases' Builds and Tests links land on Infra's CI inner tab, at the runs or suites.
        let infra = resolve("infra").unwrap();
        for (old, new) in [("builds", "runs"), ("Tests", "tests")] {
            let (t, s) = moved("releases", old).unwrap();
            assert_eq!((t.id, s), ("infra", new), "{old}");
            assert_eq!(inner_tab(infra, Some(s)).map(|i| i.id), Some("ci"));
        }
        assert_eq!(
            moved("releases", "runs"),
            None,
            "Release runs is Releases' own"
        );
    }

    #[test]
    fn alerts_sits_just_before_infra_and_leads_with_what_is_firing() {
        let at = |id: &str| TABS.iter().position(|t| t.id == id).unwrap();
        assert_eq!(at("alerts") + 1, at("infra"));
        let alerts = resolve("alerts").unwrap();
        assert_eq!(
            alerts.sections,
            ["health", "firing", "fixes", "history", "watches"]
        );
        assert_eq!(section("fixes"), None, "a new section is no retired name");
        // The eleventh tab on the number row has no digit; the tenth is 0.
        assert_eq!(bar_digit("schedules"), Some(0));
        assert_eq!(bar_digit("costs"), None);
        assert_eq!(bar_digit("alerts"), Some(8));
    }

    #[test]
    fn the_groups_are_today_agents_projects_system_one_subject_each() {
        // One subject per group (P3 of can-we-fix-trader-logical-goblet.md): the day's tabs, the
        // agent tabs, the project tabs, and the system's, Alerts leading it.
        let groups: Vec<(&str, Vec<&str>)> = TABS.iter().fold(vec![], |mut g, t| {
            match g.last_mut() {
                Some((name, ids)) if *name == t.group => ids.push(t.id),
                _ => g.push((t.group, vec![t.id])),
            }
            g
        });
        assert_eq!(
            groups,
            [
                ("Today", vec!["home", "daily", "log"]),
                ("Agents", vec!["queue", "sessions", "fleet"]),
                ("Projects", vec!["projects", "board", "releases"]),
                ("System", vec!["alerts", "infra", "schedules", "costs"]),
            ]
        );
        // The number row: Home 1, Log 2, Queue 3, Sessions 4, Fleet 5, Projects 6, Releases 7,
        // Alerts 8, Infra 9, Schedules 0; Costs, the eleventh, has none.
        let ids = [
            "home",
            "log",
            "queue",
            "sessions",
            "fleet",
            "projects",
            "releases",
            "alerts",
            "infra",
            "schedules",
            "costs",
        ];
        let digits: Vec<Option<usize>> = ids.iter().map(|id| bar_digit(id)).collect();
        assert_eq!(
            digits,
            [
                Some(1),
                Some(2),
                Some(3),
                Some(4),
                Some(5),
                Some(6),
                Some(7),
                Some(8),
                Some(9),
                Some(0),
                None
            ]
        );
    }

    #[test]
    fn a_bar_label_is_the_digit_and_title_or_the_title_alone() {
        assert_eq!(bar_label("sessions"), "4 Sessions");
        assert_eq!(bar_label("alerts"), "8 Alerts");
        assert_eq!(bar_label("costs"), "Costs", "the eleventh has no digit");
        assert_eq!(bar_label("daily"), "Daily", "off the bar");
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

    #[test]
    fn every_section_is_pinned_or_in_exactly_one_inner_tab() {
        for t in &TABS {
            assert_eq!(groups_check(t), Ok(()), "{}", t.id);
        }
        assert_eq!(resolve("costs").unwrap().inner.len(), 4);
        assert_eq!(resolve("infra").unwrap().inner.len(), 3);
    }

    #[test]
    fn infra_pins_nothing_and_old_links_open_their_inner_tab() {
        let infra = resolve("infra").unwrap();
        assert!(infra.pinned.is_empty());
        let at = |w: Option<&str>| inner_tab(infra, w).map(|i| i.id);
        assert_eq!(at(None), Some("machines"));
        assert_eq!(at(Some("pools")), Some("machines"));
        assert_eq!(at(Some("ci")), Some("ci"));
        assert_eq!(at(Some("runs")), Some("ci"));
        assert_eq!(at(Some("tests")), Some("ci"));
        assert_eq!(at(Some("jobs")), Some("jobs"));
        let titles: Vec<&str> = infra.inner.iter().map(|i| i.title).collect();
        assert_eq!(titles, ["Machines", "CI", "Jobs"]);
        // a retired tab name that became a section lands on the inner tab holding it
        assert_eq!(at(section("ci")), Some("ci"));
        assert_eq!(at(section("machines")), Some("machines"));
    }

    #[test]
    fn an_unknown_section_in_a_group_fails_the_check() {
        // The negative control: the check is not vacuous.
        let costs = *resolve("costs").unwrap();
        const BAD: &[Inner] = &[Inner {
            id: "limits",
            title: "Limits",
            sections: &["burn", "nope"],
        }];
        assert!(groups_check(&Tab {
            inner: BAD,
            ..costs
        })
        .is_err());
        const DUP: &[Inner] = &[
            Inner {
                id: "a",
                title: "A",
                sections: &["fleet", "burn", "spend", "totals"],
            },
            Inner {
                id: "a",
                title: "A",
                sections: &["table", "tokens", "langfuse", "sections"],
            },
        ];
        assert!(groups_check(&Tab {
            pinned: &[],
            inner: DUP,
            ..costs
        })
        .is_err());
        assert!(groups_check(&Tab {
            pinned: &["fleet"],
            inner: &[],
            ..costs
        })
        .is_err());
    }

    #[test]
    fn the_inner_tab_a_word_opens() {
        let costs = resolve("costs").unwrap();
        let at = |w: Option<&str>| inner_tab(costs, w).map(|i| i.id);
        // the URL's inner tab opens
        assert_eq!(at(Some("models")), Some("models"));
        assert_eq!(at(Some(" Spend ")), Some("spend"));
        // a missing, unknown or pinned word falls to the first
        assert_eq!(at(None), Some("limits"));
        assert_eq!(at(Some("nope")), Some("limits"));
        assert_eq!(at(Some("fleet")), Some("limits"));
        // an old section link opens the inner tab now holding it
        assert_eq!(at(Some("burn")), Some("limits"));
        assert_eq!(at(Some("langfuse")), Some("models"));
        assert_eq!(at(Some("table")), Some("spend"));
        // a moved section still lands: fleet/tokens is costs/tokens, which Models holds
        let (tab, sec) = moved("fleet", "tokens").unwrap();
        assert_eq!(inner_tab(tab, Some(sec)).map(|i| i.id), Some("models"));
        // a tab with no inner tabs has none
        assert_eq!(inner_tab(resolve("queue").unwrap(), Some("table")), None);
        // Releases: the apps and an opened one, then Release runs.
        let rel = resolve("releases").unwrap();
        let at = |w: Option<&str>| inner_tab(rel, w).map(|i| i.id);
        assert_eq!(at(None), Some("apps"));
        assert_eq!(at(Some("detail")), Some("apps"));
        assert_eq!(at(Some("runs")), Some("runs"));
        assert_eq!(at(Some("project:binks")), Some("apps"));
        let titles: Vec<&str> = rel.inner.iter().map(|i| i.title).collect();
        assert_eq!(titles, ["Apps", "Release runs"]);
    }

    #[test]
    fn a_count_shows_only_for_flagged_sections_of_that_inner_tab() {
        let costs = resolve("costs").unwrap();
        let n =
            |id: &str, f: &[&str]| inner_count(costs.inner.iter().find(|i| i.id == id).unwrap(), f);
        assert_eq!(n("limits", &[]), 0);
        assert_eq!(n("limits", &["burn"]), 1);
        assert_eq!(n("limits", &["burn", "consumers"]), 2);
        assert_eq!(n("models", &["tokens", "langfuse", "burn"]), 2);
        assert_eq!(n("spend", &["burn"]), 0);
    }
}
