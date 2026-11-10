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

pub const TABS: [Tab; 12] = [
    // The landing page: every action that waits on the human, then the summary lines.
    Tab {
        id: "home",
        group: "Now",
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
        group: "Now",
        title: "Daily",
        question: "What is my day?",
        sections: &["nav", "lanes", "briefing", "rollup", "sections", "outbox"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "queue",
        group: "Work",
        title: "Queue",
        question: "What will agents do next?",
        sections: &["flow", "table", "candidates"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "projects",
        group: "Work",
        title: "Projects",
        question: "Where is each project, and its tasks?",
        sections: &["cards", "rows"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "board",
        group: "Work",
        title: "Board",
        question: "What is on every project's board?",
        sections: &["rows"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "sessions",
        group: "Work",
        title: "Sessions",
        question: "What is each agent doing?",
        sections: &["shepherd", "sessions", "detail"],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "infra",
        group: "Ops",
        title: "Infra",
        question: "Is the machinery healthy?",
        sections: &[
            "health", "red", "fixes", "machines", "ci", "jobs", "cloud", "governor",
        ],
        pinned: &[],
        inner: &[],
    },
    Tab {
        id: "log",
        group: "Ops",
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
        id: "fleet",
        group: "Ops",
        title: "Fleet",
        question: "Who is working, and on what?",
        sections: &["workers"],
        pinned: &[],
        inner: &[],
    },
    // After the older tabs, so they keep their digits.
    Tab {
        id: "schedules",
        group: "Ops",
        title: "Schedules",
        question: "What runs on its own, and why?",
        sections: &["table", "detail"],
        pinned: &[],
        inner: &[],
    },
    // After Schedules, so no digit shifts. Every dollar figure the other tabs showed is
    // here, cut seven ways; they keep a one-line badge that links in.
    Tab {
        id: "costs",
        group: "Spend, ship",
        title: "Costs",
        question:
            "How fast are the limits burning, what does the fleet cost, and is each model worth it?",
        sections: &[
            "fleet", "burn", "spend", "totals", "table", "tokens", "langfuse", "sections",
        ],
        // The 24h fleet figure stays above the strip; the strip splits the three questions.
        pinned: &["fleet"],
        inner: &[
            Inner {
                id: "limits",
                title: "Limits",
                sections: &["burn"],
            },
            Inner {
                id: "spend",
                title: "Spend",
                sections: &["spend", "totals", "table"],
            },
            Inner {
                id: "models",
                title: "Models",
                sections: &["tokens", "langfuse", "sections"],
            },
        ],
    },
    // Last, so no digit shifts: the channels (`hub_core::releases`) and each opened row, then the
    // Builds section (CI runs, its own reader; release-state has no CI collector), then the Tests
    // section (per-suite results of one tests.yml run, web first; the TUI follows).
    Tab {
        id: "releases",
        group: "Spend, ship",
        title: "Releases",
        question: "What is building, and what is live where?",
        sections: &["table", "detail", "builds", "tests"],
        pinned: &[],
        inner: &[],
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
];

/// The layout's tabs the TUI's number row leaves off: Daily, which only agent-web lists, and
/// Board, which is `a` on Projects there.
pub const OFF_BAR: [&str; 2] = ["daily", "board"];

/// A tab's key on the TUI's number row: 1 for the first, 0 for the tenth.
pub fn bar_digit(id: &str) -> Option<usize> {
    TABS.iter()
        .filter(|t| !OFF_BAR.contains(&t.id))
        .position(|t| t.id == id)
        .map(|i| (i + 1) % 10)
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
        assert_eq!(resolve("fleet").unwrap().sections, ["workers"]);
    }

    #[test]
    fn infra_shows_red_fixes_right_under_red_now() {
        let infra = resolve("infra").unwrap().sections;
        let at = |s: &str| infra.iter().position(|x| *x == s).unwrap();
        assert_eq!(at("fixes"), at("red") + 1);
        assert_eq!(section("fixes"), None, "a new section is no retired name");
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
        assert_eq!(resolve("costs").unwrap().inner.len(), 3);
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
    }

    #[test]
    fn a_count_shows_only_for_flagged_sections_of_that_inner_tab() {
        let costs = resolve("costs").unwrap();
        let n =
            |id: &str, f: &[&str]| inner_count(costs.inner.iter().find(|i| i.id == id).unwrap(), f);
        assert_eq!(n("limits", &[]), 0);
        assert_eq!(n("limits", &["burn"]), 1);
        assert_eq!(n("models", &["tokens", "langfuse", "burn"]), 2);
        assert_eq!(n("spend", &["burn"]), 0);
    }
}
