//! One project's chain from idea to verified, read when its card is opened (dashboards rule 10):
//! per epic its brief, plans and phases, leaf rows, queue items, PRs and derived step, and per
//! project the flow counts and the rows and plans linked to no epic. `fleet-bench epics --json`
//! owns the join and derives every step; this module only types it and says the flow line, so
//! agent-web and the hub TUI print the same words and compute nothing.

use serde::Deserialize;

use crate::session_actions::Runner;

/// How many of each artifact the project has, in chain order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Flow {
    pub ideas: u32,
    pub briefs: u32,
    pub plans: u32,
    pub epics: u32,
    pub rows: u32,
    pub landed: u32,
    pub verified: u32,
}

/// Open rows with no epic above them, and active queue items whose plan names no epic.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Unlinked {
    pub rows: Vec<String>,
    pub plans: Vec<String>,
}

/// A plan whose `epic:` line names the epic: its phases ticked of total, the open ones by name,
/// and how many of those an active queue item carries.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Plan {
    pub file: String,
    pub done: u32,
    pub total: u32,
    pub open: Vec<String>,
    pub queued: u32,
}

/// A leaf row under the epic (through `#of/`, up to three levels).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Row {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub size: String,
    pub state: String,
    pub prs: Vec<String>,
}

/// A queue item made from one of the epic's rows.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Item {
    pub slug: String,
    pub state: String,
    pub pr: Option<String>,
    pub row: String,
}

/// The epic's finish estimate, epoch seconds; `cal_p50` once its basis has scored epics.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Eta {
    pub p50: i64,
    pub slow: i64,
    pub basis: String,
    pub cal_p50: Option<i64>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Epic {
    pub id: String,
    pub title: String,
    /// The system it builds, the area in its `epic(<system>):` row; empty from an older reader.
    pub system: String,
    pub version: String,
    /// `open` or `closed`.
    pub state: String,
    pub verified: bool,
    pub proof: String,
    pub open: u32,
    pub done: u32,
    pub open_weight: u32,
    pub done_weight: u32,
    /// `epic`, `brief`, `plan`, `rows`, `landed` or `verified`: derived, never stored.
    pub step: String,
    pub brief: Option<String>,
    pub plans: Vec<Plan>,
    pub rows: Vec<Row>,
    pub items: Vec<Item>,
    pub prs: Vec<String>,
    pub eta: Option<Eta>,
    /// Why an open epic has no ETA.
    pub no_eta: Option<String>,
    /// `on track` or `behind` its frozen baseline, once it has one.
    pub track: Option<String>,
}

/// One project's chain.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Chain {
    pub project: String,
    pub profile: String,
    pub repo: String,
    pub flow: Flow,
    pub unlinked: Unlinked,
    pub epics: Vec<Epic>,
}

#[derive(Deserialize)]
struct Out {
    #[serde(default)]
    projects: Vec<Chain>,
}

/// `fleet-bench epics --json --project <name>`. A project the reader does not list (no roadmap,
/// or no such name) is an error that says so, never an empty chain.
pub fn chain(runner: &dyn Runner, name: &str) -> Result<Chain, String> {
    if !crate::projects::safe_name(name) {
        return Err(format!("refusing project name {name:?}"));
    }
    let out = runner.run(&[
        "fleet-bench".into(),
        "epics".into(),
        "--json".into(),
        "--project".into(),
        name.into(),
    ])?;
    let o: Out =
        serde_json::from_str(&out).map_err(|e| format!("fleet-bench epics --json: {e}"))?;
    o.projects
        .into_iter()
        .find(|c| c.project == name)
        .ok_or_else(|| format!("fleet-bench epics lists no project {name}"))
}

/// The mockup's Flow line: `ideas 4 | briefs 2 | plans 3 | epics 5 | rows 38 | landed 2 | verified 1`.
pub fn flow_line(f: &Flow) -> String {
    format!(
        "ideas {} | briefs {} | plans {} | epics {} | rows {} | landed {} | verified {}",
        f.ideas, f.briefs, f.plans, f.epics, f.rows, f.landed, f.verified
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(&'static str, std::cell::RefCell<Vec<String>>);
    impl Runner for Fixed {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            *self.1.borrow_mut() = argv.to_vec();
            Ok(self.0.into())
        }
    }

    // trimmed from a live `fleet-bench epics --json --project agent-runtime`, with the fields
    // this module does not type (pace, accuracy, baseline, score) left in to prove they are skipped
    const OUT: &str = r#"{"made_epoch":1793984926,"projects":[{"project":"agent-runtime","profile":"personal","repo":"dotfiles",
      "pace":{"P":1344,"S":900,"basis":"project-median(232) x1.12"},
      "flow":{"ideas":19,"briefs":2,"plans":1,"epics":1,"rows":13,"landed":0,"verified":0},
      "unlinked":{"rows":["ar-10","ar-100"],"plans":["/p/i-think-it-s-snug-cupcake.md"]},
      "accuracy":{"scored":0,"median_ratio":null},
      "epics":[{"id":"ar-374","title":"one project page","version":"","state":"open","verified":false,"proof":"",
        "open":9,"done":4,"open_weight":16,"done_weight":4,"progress":0.2,"step":"rows","brief":"/b/brief.md",
        "plans":[{"file":"/p/humble-flurry.md","done":4,"total":8,"open":["P3 join"],"queued":4}],
        "rows":[{"id":"ar-405","kind":"untyped","title":"P2","size":"s","state":"done","prs":["1093"]}],
        "items":[{"slug":"x-p4","state":"running","pr":null,"row":"ar-439"},{"slug":"x-p3","state":"done","pr":"o/r#1149","row":"ar-438"}],
        "prs":["1093","o/r#1149"],
        "eta":{"p50":1794003682,"slow":1794003682,"basis":"queue","scheduled":4,"unscheduled":5,"factor":null,"cal_p50":null},
        "no_eta":null,"baseline":null,"track":null,"score":null}]}]}"#;

    #[test]
    fn the_chain_reads_one_project_from_fleet_bench_and_types_its_join() {
        let r = Fixed(OUT, Default::default());
        let c = chain(&r, "agent-runtime").unwrap();
        assert_eq!(
            *r.1.borrow(),
            [
                "fleet-bench",
                "epics",
                "--json",
                "--project",
                "agent-runtime"
            ]
        );
        assert_eq!(c.flow.rows, 13);
        assert_eq!(c.unlinked.rows, ["ar-10", "ar-100"]);
        assert_eq!(c.unlinked.plans.len(), 1);
        let e = &c.epics[0];
        assert_eq!((e.id.as_str(), e.step.as_str()), ("ar-374", "rows"));
        assert_eq!(e.brief.as_deref(), Some("/b/brief.md"));
        assert_eq!((e.plans[0].done, e.plans[0].total), (4, 8));
        assert_eq!(e.rows[0].prs, ["1093"]);
        assert_eq!(e.items[0].pr, None);
        assert_eq!(e.items[1].pr.as_deref(), Some("o/r#1149"));
        assert_eq!(e.eta.as_ref().unwrap().p50, 1794003682);
        assert_eq!(e.track, None);
    }

    #[test]
    fn a_project_fleet_bench_does_not_list_is_an_error_not_an_empty_chain() {
        let r = Fixed(r#"{"made_epoch":1,"projects":[]}"#, Default::default());
        let e = chain(&r, "nosuch").unwrap_err();
        assert!(e.contains("no project nosuch"), "{e}");
        let r = Fixed("not json", Default::default());
        assert!(chain(&r, "agent-runtime")
            .unwrap_err()
            .contains("fleet-bench epics"));
    }

    #[test]
    fn a_name_that_could_be_a_flag_never_reaches_the_command() {
        let r = Fixed(OUT, Default::default());
        for bad in ["", "--all", "a b", "../x"] {
            assert!(chain(&r, bad).is_err(), "{bad}");
        }
        assert!(r.1.borrow().is_empty());
    }
}
