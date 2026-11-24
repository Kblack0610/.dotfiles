//! The sprint history both surfaces draw under a project's Sprint inner tab and Projects'
//! Sprints inner tab (docs/dashboards.md, "Hub layout"): the scored windows of one project and
//! each project's last score. The open and queued windows are `tasks::SprintRow`s
//! ([`crate::tasks::Feed::sprint_rows`]); this module is the part a feed does not hold, what
//! `notes projects --sprints <p> --json` lists (one `sprints/vX.Y.Z.md` per window).

use serde::{Deserialize, Serialize};

use crate::projects::Card;
use crate::session_actions::Runner;

/// One scored window, as notes-cli's `window::Past` lists it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Past {
    pub version: String,
    /// The day the window opened, `YYYY-MM-DD`.
    pub opened: Option<String>,
    /// The day the cut ran, `YYYY-MM-DD`.
    pub cut: Option<String>,
    pub committed: usize,
    pub delivered: usize,
    pub carried: usize,
    pub dropped: usize,
    pub interrupted: usize,
    /// `on time` or `late by N days`; None for a window with no due day.
    pub timing: Option<String>,
    /// The whole `## Score` line.
    pub line: String,
    /// The window's page (`crate::sprint_page::link`), set by the page read that knows the
    /// project's profile; a row of the table links to it.
    #[serde(skip_deserializing)]
    pub link: Option<crate::links::Link>,
}

impl Past {
    /// The sprint file this window's score is in, under the project's directory.
    pub fn file(&self) -> String {
        format!("sprints/{}.md", self.version)
    }

    /// `26/26`, delivered of committed.
    pub fn score(&self) -> String {
        format!("{}/{}", self.delivered, self.committed)
    }
}

/// A project's scored windows, newest first (notes lists them oldest first).
pub fn past(runner: &dyn Runner, project: &str) -> Result<Vec<Past>, String> {
    if !crate::projects::safe_name(project) {
        return Err(format!("refusing project name {project:?}"));
    }
    let out = runner.run(&[
        "notes".into(),
        "projects".into(),
        "--sprints".into(),
        project.into(),
        "--json".into(),
    ])?;
    let mut v: Vec<Past> =
        serde_json::from_str(&out).map_err(|e| format!("notes projects --sprints --json: {e}"))?;
    v.reverse();
    Ok(v)
}

/// One project's last cut score, a row of Projects' Sprints inner tab.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct LastScore {
    pub profile: String,
    pub project: String,
    pub version: String,
    /// The `## Score` line.
    pub line: String,
}

/// Every card's last score, in the cards' order; a card whose last cut had no snapshot has none.
pub fn last_scores(cards: &[Card]) -> Vec<LastScore> {
    cards
        .iter()
        .filter_map(|c| {
            let w = c.last_window.as_ref()?;
            Some(LastScore {
                profile: c.profile.clone(),
                project: c.name.clone(),
                version: w.version.clone(),
                line: w.line.clone(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::LastWindow;

    struct Says(&'static str);
    impl Runner for Says {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(
                argv.join(" "),
                "notes projects --sprints game --json",
                "the one CLI the history is read from"
            );
            Ok(self.0.to_string())
        }
    }

    #[test]
    fn the_history_reads_newest_first() {
        let json = r#"[
            {"version":"v0.5.3","opened":"2026-11-01","cut":"2026-11-08","committed":10,"delivered":8,
             "carried":2,"dropped":0,"interrupted":1,"timing":"on time","line":"a"},
            {"version":"v0.5.4","opened":null,"cut":null,"committed":4,"delivered":4,
             "carried":0,"dropped":0,"interrupted":0,"timing":null,"line":"b"}]"#;
        let got = past(&Says(json), "game").unwrap();
        let order: Vec<&str> = got.iter().map(|p| p.version.as_str()).collect();
        assert_eq!(order, ["v0.5.4", "v0.5.3"]);
        assert_eq!(got[1].score(), "8/10");
        assert_eq!(got[1].file(), "sprints/v0.5.3.md");
        assert_eq!(got[0].timing, None);
    }

    #[test]
    fn a_garbled_read_and_an_unsafe_name_are_errors_never_an_empty_history() {
        assert!(past(&Says("not json"), "game").is_err());
        assert!(past(&Says("[]"), "../x").is_err());
        assert_eq!(past(&Says("[]"), "game").unwrap(), vec![]);
    }

    #[test]
    fn only_a_card_with_a_score_has_one() {
        let scored = Card {
            profile: "bnb".into(),
            name: "game".into(),
            last_window: Some(LastWindow {
                version: "v0.5.6".into(),
                line: "score".into(),
            }),
            ..Default::default()
        };
        let bare = Card {
            name: "tool".into(),
            ..Default::default()
        };
        let got = last_scores(&[bare, scored]);
        assert_eq!(got.len(), 1);
        assert_eq!(
            (got[0].project.as_str(), got[0].version.as_str()),
            ("game", "v0.5.6")
        );
    }
}
