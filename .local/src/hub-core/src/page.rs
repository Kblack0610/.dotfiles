//! One project's page, read when its card is opened (dashboards rule 10), never for every card:
//! the Flow line, what needs the human, the epics by system with each system's criteria, the
//! next stage's gaps and the shipped versions. Every number is counted by its owner and this
//! module only joins them and says the words, so agent-web and the hub TUI print the same lines:
//! `fleet-bench epics` (the chain, `epics.rs`), `project-stage-check` (next stage and system
//! criteria) and `notes projects --roadmap --json` (shipped versions). A source that fails is
//! named in `errors` and the rest of the page still shows.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::epics::{self, Chain, Epic};
use crate::session_actions::Runner;

/// Plans with no epic the Needs you list names one by one; the rest are one "+N more" line.
pub const PLANS_SHOWN: usize = 5;

/// One epic as its system's line: `one project page  [rows]  brief yes  plan 2 of 7 ...`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct EpicLine {
    pub line: String,
    /// Behind its frozen baseline, which a surface marks.
    pub behind: bool,
}

/// A system: its criteria from `systems.md`, then its open epics; closed ones are a count.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct System {
    pub id: String,
    /// `ui  criteria 5 of 7`, or `ui  no criteria` for a system the project type does not list.
    pub head: String,
    pub epics: Vec<EpicLine>,
    /// `+3 closed, 2 verified`, empty when none closed.
    pub closed: String,
}

/// One requirement of the next stage that is not met: FAIL, HUMAN or TODO.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Requirement {
    pub stage: String,
    pub result: String,
    pub requirement: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Page {
    pub project: String,
    /// `ideas 19 | briefs 2 | ...`; None when the chain could not be read.
    pub flow_line: Option<String>,
    /// Verify an epic whose rows all landed, then plans that name no epic, in that order.
    pub needs: Vec<String>,
    /// Build by system's head: `3 systems, 2 open epics (438 rows with no epic)`.
    pub systems_says: String,
    pub systems: Vec<System>,
    /// Next stage's head: `beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet`, or
    /// `no stage after this one` at the top.
    pub next_says: String,
    pub next_rows: Vec<Requirement>,
    /// Shipped's head: `2 versions`, `1 version` or `none yet`.
    pub shipped_says: String,
    /// `v0.0.0: 20 rows closed; feat 9, fix 7, docs 4`, newest first.
    pub shipped: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct StageOut {
    stage: String,
    met: u32,
    total: u32,
    fail: u32,
    human: u32,
    todo: u32,
    requirements: Vec<Requirement>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SystemsOut {
    systems: Vec<Criteria>,
}

/// One system's criteria from `project-stage-check --systems`.
#[derive(Clone, Debug, Deserialize, Default)]
#[serde(default)]
pub struct Criteria {
    pub id: String,
    pub met: u32,
    pub total: u32,
}

/// The stage after `stage` on the ladder; None at the top or for a stage the ladder lacks.
pub fn next_on(ladder: &[String], stage: &str) -> Option<String> {
    let i = ladder.iter().position(|s| s == stage)?;
    ladder.get(i + 1).cloned()
}

fn plan_name(path: &str) -> &str {
    let base = path.rsplit('/').next().unwrap_or(path);
    base.strip_suffix(".md").unwrap_or(base)
}

/// An epic's line on its system: title, step, brief, plan phases, rows, PRs, ETA and track.
pub fn epic_line(e: &Epic, now: i64) -> String {
    let mut s = format!("{}  [{}]", e.title, e.step);
    s += if e.brief.is_some() {
        "  brief yes"
    } else {
        "  brief no"
    };
    let (done, total) = e
        .plans
        .iter()
        .fold((0, 0), |(d, t), p| (d + p.done, t + p.total));
    if e.plans.is_empty() {
        s += "  plan no";
    } else {
        s += &format!("  plan {done} of {total}");
    }
    s += &format!("  rows {} of {}", e.done, e.done + e.open);
    if !e.prs.is_empty() {
        s += &format!("  PRs {}", e.prs.len());
    }
    if e.state == "open" {
        if let Some(eta) = &e.eta {
            if eta.p50 <= now {
                s += "  ETA overdue";
            } else {
                // Rounded up, so a finish later today is 1d, never 0d.
                let days = (eta.p50 - now + 86_399).div_euclid(86_400);
                s += &format!("  ETA {days}d");
            }
        }
    }
    if let Some(t) = &e.track {
        s += &format!("  {t}");
    }
    s
}

/// What the chain asks of the human: an epic to verify once every row landed, then each plan
/// that names no epic (the first [`PLANS_SHOWN`], then a count).
pub fn needs(c: &Chain) -> Vec<String> {
    let mut out: Vec<String> = c
        .epics
        .iter()
        .filter(|e| e.step == "landed")
        .map(|e| {
            format!(
                "verify: {} ({} of {} rows landed, no live proof)",
                e.title,
                e.done,
                e.done + e.open
            )
        })
        .collect();
    let plans = &c.unlinked.plans;
    out.extend(
        plans
            .iter()
            .take(PLANS_SHOWN)
            .map(|p| format!("plan with no epic: {}", plan_name(p))),
    );
    if plans.len() > PLANS_SHOWN {
        out.push(format!(
            "+{} more plans with no epic",
            plans.len() - PLANS_SHOWN
        ));
    }
    out
}

/// The epics under their systems: every system the project's type has, in `systems.md` order,
/// then any system an epic names that the type lacks, then epics with none.
pub fn systems(c: &Chain, criteria: &[Criteria], now: i64) -> Vec<System> {
    let mut by: BTreeMap<&str, Vec<&Epic>> = BTreeMap::new();
    for e in &c.epics {
        by.entry(e.system.as_str()).or_default().push(e);
    }
    let mut out: Vec<System> = criteria
        .iter()
        .map(|c| System {
            id: c.id.clone(),
            head: format!("{}  criteria {} of {}", c.id, c.met, c.total),
            ..Default::default()
        })
        .collect();
    for sys in by.keys() {
        if !out.iter().any(|s| s.id == *sys) {
            let id = if sys.is_empty() { "no system" } else { sys };
            out.push(System {
                id: sys.to_string(),
                head: format!("{id}  no criteria"),
                ..Default::default()
            });
        }
    }
    for s in &mut out {
        let Some(es) = by.get(s.id.as_str()) else {
            continue;
        };
        s.epics = es
            .iter()
            .filter(|e| e.state == "open")
            .map(|e| EpicLine {
                line: epic_line(e, now),
                behind: e.track.as_deref() == Some("behind"),
            })
            .collect();
        let closed = es.iter().filter(|e| e.state != "open").count();
        if closed > 0 {
            let verified = es
                .iter()
                .filter(|e| e.state != "open" && e.verified)
                .count();
            s.closed = format!("+{closed} closed, {verified} verified");
        }
    }
    out
}

/// `--roadmap --json`'s shipped versions, newest first, each as its closes by kind.
pub fn shipped(roadmap: &Value) -> Vec<String> {
    let Some(rel) = roadmap.as_array() else {
        return vec![];
    };
    rel.iter()
        .filter(|r| r["state"] == "shipped")
        .map(|r| {
            let p = &r["progress"];
            let mut kinds: Vec<(String, u64)> = p["by_kind"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .map(|(k, v)| (k.clone(), v["done"].as_u64().unwrap_or(0)))
                        .filter(|(_, n)| *n > 0)
                        .collect()
                })
                .unwrap_or_default();
            kinds.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            let mut s = format!(
                "{}: {} rows closed",
                r["version"].as_str().unwrap_or("?"),
                p["done"].as_u64().unwrap_or(0)
            );
            if !kinds.is_empty() {
                let k: Vec<String> = kinds.iter().map(|(k, n)| format!("{k} {n}")).collect();
                s += &format!("; {}", k.join(", "));
            }
            s
        })
        .collect()
}

fn stage_line(o: &StageOut) -> String {
    format!(
        "{}  {} of {} met, {} failing, {} human, {} not checkable yet",
        o.stage, o.met, o.total, o.fail, o.human, o.todo
    )
}

/// Run `project-stage-check` and parse its JSON. Its exit is 1 when a row fails and the JSON is
/// still the answer; 2 is a usage error.
fn stage_json<T: serde::de::DeserializeOwned>(
    runner: &dyn Runner,
    argv: &[&str],
) -> Result<T, String> {
    let argv: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    match runner.output(&argv)? {
        (0 | 1, out) => serde_json::from_str(&out).map_err(|e| e.to_string()),
        (code, _) => Err(format!("{} exited {code}", argv.join(" "))),
    }
}

/// Read and join the page for one project at `stage`. `now` is epoch seconds, for ETAs.
pub fn read(runner: &dyn Runner, name: &str, stage: &str, now: i64) -> Page {
    let mut p = Page {
        project: name.to_string(),
        ..Default::default()
    };
    if !crate::projects::safe_name(name) {
        p.errors.push(format!("refusing project name {name:?}"));
        return p;
    }
    let chain = match epics::chain(runner, name) {
        Ok(c) => Some(c),
        Err(e) => {
            p.errors.push(e);
            None
        }
    };
    let criteria = match stage_json::<SystemsOut>(
        runner,
        &["project-stage-check", name, "--systems", "--json"],
    ) {
        Ok(o) => o.systems,
        Err(e) => {
            p.errors.push(format!("project-stage-check --systems: {e}"));
            vec![]
        }
    };
    if let Some(c) = &chain {
        p.flow_line = Some(epics::flow_line(&c.flow));
        p.needs = needs(c);
        p.systems = systems(c, &criteria, now);
    }
    let open_epics: usize = p.systems.iter().map(|s| s.epics.len()).sum();
    p.systems_says = format!("{} systems, {open_epics} open epics", p.systems.len());
    if let Some(n) = chain
        .as_ref()
        .map(|c| c.unlinked.rows.len())
        .filter(|n| *n > 0)
    {
        p.systems_says += &format!(" ({n} rows with no epic)");
    }
    let ladder: Vec<String> =
        match runner.run(&["notes".into(), "projects".into(), "--stages".into()]) {
            Ok(o) => o
                .lines()
                .next()
                .unwrap_or("")
                .split_whitespace()
                .map(String::from)
                .collect(),
            Err(e) => {
                p.errors.push(format!("notes projects --stages: {e}"));
                vec![]
            }
        };
    p.next_says = "no stage after this one".into();
    if let Some(next) = next_on(&ladder, stage) {
        p.next_says = format!("{next}  not read");
        match stage_json::<StageOut>(
            runner,
            &["project-stage-check", name, "--stage", &next, "--json"],
        ) {
            Ok(o) => {
                p.next_says = stage_line(&o);
                p.next_rows = o
                    .requirements
                    .into_iter()
                    .filter(|r| r.result != "PASS")
                    .collect();
            }
            Err(e) => p
                .errors
                .push(format!("project-stage-check --stage {next}: {e}")),
        }
    }
    match runner.run(&[
        "notes".into(),
        "projects".into(),
        "--roadmap".into(),
        name.into(),
        "--json".into(),
    ]) {
        Ok(o) => match serde_json::from_str::<Value>(&o) {
            Ok(v) => p.shipped = shipped(&v),
            Err(e) => p
                .errors
                .push(format!("notes projects --roadmap --json: {e}")),
        },
        Err(e) => p.errors.push(format!("notes projects --roadmap: {e}")),
    }
    p.shipped_says = match p.shipped.len() {
        0 => "none yet".into(),
        1 => "1 version".into(),
        n => format!("{n} versions"),
    };
    p
}

/// The page for a name alone, as `hub projects --page` and agent-web read it: its stage from
/// `notes projects --stats --json`. A name no lab project has is an error, never an empty page.
pub fn named(runner: &dyn Runner, name: &str, now: i64) -> Result<Page, String> {
    let stats = crate::projects::stats(runner)?;
    let s = stats
        .iter()
        .find(|s| s.name == name)
        .ok_or_else(|| format!("notes projects lists no project {name}"))?;
    Ok(read(runner, name, &s.stage, now))
}

pub fn to_json(p: &Page) -> Value {
    serde_json::to_value(p).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Answers by the command's first two words; records every argv it was given.
    struct Fake {
        answers: Vec<(&'static str, i32, String)>,
        seen: RefCell<Vec<String>>,
    }
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            match self.output(argv)? {
                (0, o) => Ok(o),
                (c, _) => Err(format!("exit {c}")),
            }
        }
        fn output(&self, argv: &[String]) -> Result<(i32, String), String> {
            let line = argv.join(" ");
            self.seen.borrow_mut().push(line.clone());
            self.answers
                .iter()
                .find(|(k, ..)| line.starts_with(k))
                .map(|(_, c, o)| (*c, o.clone()))
                .ok_or_else(|| format!("no answer for {line}"))
        }
    }

    const NOW: i64 = 1_794_000_000;

    fn chain_json() -> String {
        serde_json::json!({"projects": [{
            "project": "game", "profile": "lab", "repo": "game",
            "flow": {"ideas": 3, "briefs": 1, "plans": 1, "epics": 3, "rows": 5, "landed": 1, "verified": 1},
            "unlinked": {"rows": ["gm-7", "gm-15"], "plans": ["/p/a.md", "/p/b.md", "/p/c.md", "/p/d.md", "/p/e.md", "/p/f.md"]},
            "epics": [
                {"id": "gm-1", "title": "Menus", "system": "ui", "state": "open", "step": "rows", "open": 2, "done": 2,
                 "brief": "/b.md", "plans": [{"file": "/p/m.md", "done": 1, "total": 3}], "prs": ["101"],
                 "eta": {"p50": NOW + 3 * 86_400, "slow": NOW + 5 * 86_400, "basis": "queue"}, "track": "behind"},
                {"id": "gm-2", "title": "Saves", "system": "ui", "state": "open", "step": "landed", "open": 0, "done": 4,
                 "prs": ["102", "103"]},
                {"id": "gm-5", "title": "Shipped", "system": "ui", "state": "closed", "step": "verified", "verified": true, "done": 1},
                {"id": "gm-9", "title": "Odd", "system": "", "state": "open", "step": "epic",
                 "eta": {"p50": NOW - 60, "slow": NOW, "basis": "queue"}}
            ]}]})
        .to_string()
    }

    fn fake(stage_exit: i32) -> Fake {
        let systems =
            r#"{"systems":[{"id":"ui","met":5,"total":7},{"id":"ci","met":1,"total":2}]}"#;
        let stage = r#"{"stage":"beta","met":4,"total":12,"fail":1,"human":1,"todo":6,"requirements":[
            {"stage":"draft","result":"PASS","requirement":"a brief"},
            {"stage":"beta","result":"FAIL","requirement":"a soak test"}]}"#;
        let roadmap = r#"[{"version":"v0.2.0","state":"current","progress":{"done":3}},
            {"version":"v0.1.0","state":"shipped","progress":{"done":20,"by_kind":{"fix":{"done":7},"feat":{"done":9},"docs":{"done":4},"ci":{"done":0}}}}]"#;
        Fake {
            answers: vec![
                ("fleet-bench epics", 0, chain_json()),
                (
                    "project-stage-check game --systems",
                    stage_exit,
                    systems.into(),
                ),
                (
                    "notes projects --stages",
                    0,
                    "draft dev alpha beta prod\n".into(),
                ),
                (
                    "project-stage-check game --stage beta",
                    stage_exit,
                    stage.into(),
                ),
                ("notes projects --roadmap game", 0, roadmap.into()),
            ],
            seen: RefCell::new(vec![]),
        }
    }

    #[test]
    fn the_page_joins_the_chain_the_stage_check_and_the_roadmap_into_the_mockup_lines() {
        let f = fake(0);
        let p = read(&f, "game", "alpha", NOW);
        assert!(p.errors.is_empty(), "{:?}", p.errors);
        assert_eq!(
            p.flow_line.as_deref(),
            Some("ideas 3 | briefs 1 | plans 1 | epics 3 | rows 5 | landed 1 | verified 1")
        );
        assert_eq!(
            p.needs,
            vec![
                "verify: Saves (4 of 4 rows landed, no live proof)",
                "plan with no epic: a",
                "plan with no epic: b",
                "plan with no epic: c",
                "plan with no epic: d",
                "plan with no epic: e",
                "+1 more plans with no epic",
            ]
        );
        let heads: Vec<&str> = p.systems.iter().map(|s| s.head.as_str()).collect();
        assert_eq!(
            heads,
            vec![
                "ui  criteria 5 of 7",
                "ci  criteria 1 of 2",
                "no system  no criteria"
            ],
            "every system the type has, in its order, then epics with no system"
        );
        let ui = &p.systems[0];
        assert_eq!(
            ui.epics.iter().map(|e| e.line.as_str()).collect::<Vec<_>>(),
            vec![
                "Menus  [rows]  brief yes  plan 1 of 3  rows 2 of 4  PRs 1  ETA 3d  behind",
                "Saves  [landed]  brief no  plan no  rows 4 of 4  PRs 2",
            ]
        );
        assert_eq!(
            ui.epics.iter().map(|e| e.behind).collect::<Vec<_>>(),
            vec![true, false]
        );
        assert_eq!(ui.closed, "+1 closed, 1 verified");
        assert_eq!(
            p.systems[2].epics[0].line, "Odd  [epic]  brief no  plan no  rows 0 of 0  ETA overdue",
            "an estimate already past says so, never 0d"
        );
        assert!(p.systems[1].epics.is_empty() && p.systems[1].closed.is_empty());
        assert_eq!(
            p.systems_says,
            "3 systems, 3 open epics (2 rows with no epic)"
        );
        assert_eq!(
            p.next_says,
            "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet"
        );
        assert_eq!(
            p.next_rows
                .iter()
                .map(|r| r.result.as_str())
                .collect::<Vec<_>>(),
            vec!["FAIL"],
            "a met requirement is not listed"
        );
        assert_eq!(
            p.shipped,
            vec!["v0.1.0: 20 rows closed; feat 9, fix 7, docs 4"]
        );
        assert_eq!(p.shipped_says, "1 version");
    }

    #[test]
    fn a_failing_stage_check_still_gives_its_numbers_and_a_usage_error_is_named() {
        let p = read(&fake(1), "game", "alpha", NOW);
        assert!(
            p.errors.is_empty(),
            "exit 1 is a failing row, not a failed read"
        );
        assert!(p.next_says.starts_with("beta  4 of 12 met"));
        let p = read(&fake(2), "game", "alpha", NOW);
        assert_eq!(p.next_says, "beta  not read", "never the top stage's words");
        assert_eq!(p.systems.len(), 2);
        assert_eq!(p.errors.len(), 2, "{:?}", p.errors);
        assert!(p.errors.iter().all(|e| e.contains("exited 2")));
        assert!(
            p.flow_line.is_some(),
            "one failed source leaves the rest of the page"
        );
    }

    #[test]
    fn the_top_stage_has_no_next_and_an_unread_chain_is_an_error_not_an_empty_page() {
        let f = fake(0);
        let p = read(&f, "game", "prod", NOW);
        assert_eq!(p.next_says, "no stage after this one");
        assert!(!f.seen.borrow().iter().any(|l| l.contains("--stage ")));
        let f = Fake {
            answers: vec![("notes projects --stages", 0, "draft dev\n".into())],
            seen: RefCell::new(vec![]),
        };
        let p = read(&f, "game", "draft", NOW);
        assert!(p.flow_line.is_none());
        assert!(p.errors[0].contains("fleet-bench"), "{:?}", p.errors);
    }

    #[test]
    fn a_name_alone_takes_its_stage_from_the_stats_and_an_unknown_one_is_an_error() {
        let mut f = fake(0);
        f.answers.insert(
            0,
            (
                "notes projects --stats",
                0,
                r#"[{"profile":"lab","name":"game","stage":"alpha"}]"#.into(),
            ),
        );
        let p = named(&f, "game", NOW).unwrap();
        assert!(p.next_says.starts_with("beta"), "{p:?}");
        let e = named(&f, "nosuch", NOW).unwrap_err();
        assert!(e.contains("no project nosuch"), "{e}");
    }

    #[test]
    fn a_name_that_could_be_a_flag_runs_nothing() {
        let f = fake(0);
        let p = read(&f, "--all", "alpha", NOW);
        assert!(f.seen.borrow().is_empty());
        assert_eq!(p.errors.len(), 1);
    }
}
