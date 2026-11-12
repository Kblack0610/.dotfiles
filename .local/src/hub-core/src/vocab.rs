//! The words the hub uses for state. The bucket vocabulary of state.json lives in agent-panel
//! (`agent_panel::vocab`); hub-core re-exports it. The waiting states are worded here, one line
//! per state, and each table under them carries its own as its legend (`Row::LEGEND`). Three
//! things wait to start, each under its own word: a queue item is `ready` or `held`, a job and a
//! CI job are `waiting`.

pub use agent_panel::vocab::Vocab;

/// An agent-queue item that has not started (`queue::State::Queued`), the Queue table's STATE.
pub const QUEUE: &[(&str, &str)] = &[
    ("ready", "starts when dispatch has a slot for it"),
    (
        "held",
        "waits on its hold: after another item, until a PR merges, until night or a set time; the opened row says which",
    ),
];

/// A job that has not started (`jobs::State::Queued`), the Jobs table's STATE.
pub const JOBS: &[(&str, &str)] = &[(
    "waiting",
    "the job has not started; TOOK says how long it has waited",
)];

/// A GitHub Actions job no runner has taken yet (`ci::Queued`), the CI Waiting table's rows.
pub const CI: &[(&str, &str)] = &[
    (
        "waiting",
        "a CI job waiting for a runner with every label in NEEDS; CAN RUN ON is who holds them",
    ),
    (
        "stuck",
        "the chip for a job no online runner holds those labels for",
    ),
];

#[cfg(test)]
mod tests {
    use crate::ci::{Queued, Slot};
    use crate::jobs::{Job, Source, State as JobState};
    use crate::queue::{Item, Queue, QueueRow, State};
    use crate::table::{Row, View};

    /// Each word a legend defines is one its table's rows show, so the legend cannot drift from
    /// the cells it explains.
    fn defines<R: Row>(rows: &[R], col: &str) {
        let (_, s) = View::new::<R>("", "", "", "").summary(rows);
        let legend = s.legend.expect("the table carries its legend");
        for (word, _) in R::LEGEND {
            assert!(legend.contains(&format!("{word}: ")), "{legend}");
            let n = View::new::<R>(&format!("{col}:{word}"), "", "", "")
                .apply(rows)
                .len();
            assert_eq!(n, 1, "`{col}:{word}` finds its one row");
        }
    }

    #[test]
    fn a_queue_item_not_started_is_ready_or_held_and_its_legend_says_which() {
        let item = |slug: &str, hold: Option<&str>| Item {
            slug: slug.into(),
            state: State::Queued,
            hold: hold.map(str::to_string),
            ..Item::default()
        };
        let q = Queue {
            items: vec![item("r", None), item("h", Some("after r"))],
            ..Queue::default()
        };
        let rows: Vec<QueueRow> = q.rows(chrono::Utc::now());
        defines(&rows, "state");
        assert!(View::new::<QueueRow>("state:queued", "", "", "")
            .apply(&rows)
            .is_empty());
    }

    #[test]
    fn a_job_not_started_is_waiting_under_its_own_chip() {
        let rows = vec![Job::new(Source::Unity, "gate", JobState::Queued)];
        defines(&rows, "state");
        assert!(rows[0].in_state("waiting"));
        let (_, s) = View::new::<Job>("", "", "", "").summary(&rows);
        assert!(s.states.iter().all(|c| c.name != "queued"));
    }

    #[test]
    fn a_ci_job_waits_for_a_runner_and_a_table_without_words_sends_no_legend() {
        let rows = vec![Queued::default()];
        let (_, s) = View::new::<Queued>("", "", "", "").summary(&rows);
        assert!(s
            .legend
            .unwrap()
            .starts_with("waiting: a CI job waiting for a runner"));
        // Negative control: the runners table defines no state word and sends no `legend` key.
        let (_, s) = View::new::<Slot>("", "", "", "").summary(&[Slot::default()]);
        assert_eq!(s.legend, None);
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("legend").is_none(), "{json}");
    }
}
