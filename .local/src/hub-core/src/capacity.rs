//! The header over Sessions on both surfaces: how many sessions are live and who started them,
//! the run units `fleet-dispatch` has used, and whether the two timers that move work are on.
//! The session counts come from the state document (`fleet-sessions`), the run units from
//! `fleet-dispatch headroom --json`, the timers from `jobs::timer_starts`, and the shepherd's
//! last pass from `fleet-shepherd stats`. Nothing here judges: a timer that is not on turns its
//! part amber and offers [`start`], which only ever starts one of the two named here.

use std::collections::HashMap;

use chrono::{Local, TimeZone};
use serde::Serialize;
use serde_json::Value;

use crate::session_actions::{argv, Runner};
use crate::session_table::{is_live, is_machine, is_unlinked, read_state};

/// The timers the header watches: its name in the header and on the Start button, the timer
/// unit, and the service that timer starts.
const TIMERS: [(&str, &str, &str); 2] = [
    (
        "dispatch",
        "agentctl-fleet-dispatch.timer",
        "agentctl@fleet-dispatch.service",
    ),
    (
        "shepherd",
        "agentctl-shepherd.timer",
        "agentctl@shepherd.service",
    ),
];

/// One piece of the header line. Both surfaces draw `text`; `warn` is amber, `start` names the
/// timer this part's Start button enables, and `confirm` is what its confirm says.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Part {
    pub text: String,
    pub warn: bool,
    pub start: Option<&'static str>,
    pub confirm: String,
}

/// What the header says, and how many live sessions have no queue item.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Capacity {
    pub parts: Vec<Part>,
    pub live: usize,
    pub unlinked: usize,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// The sources as they were read; a source that failed is `None`, and says so in `errors`.
#[derive(Debug, Default)]
pub struct Sources {
    pub headroom: Option<Value>,
    /// Next start by the unit a timer starts, as `jobs::timer_starts` gives it.
    pub timers: Option<HashMap<String, i64>>,
    pub shepherd: Option<Value>,
    pub errors: Vec<String>,
}

/// A clock time as the header prints it.
fn clock(epoch: i64) -> String {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map_or("?".into(), |t| t.format("%H:%M").to_string())
}

/// The live sessions by who started them. A dispatched session's item says `run`; the shepherd
/// and the NIGHTLY and SHARED rows are the fleet's own; every other one was started by hand,
/// which is also what a session with no queue item is.
fn live_part(sessions: &[Value], h: Option<&Value>) -> (Part, usize, usize) {
    let live: Vec<&Value> = sessions.iter().filter(|s| is_live(s)).collect();
    let other = live.iter().filter(|s| is_machine(s)).count();
    let run = live
        .iter()
        .filter(|s| !is_machine(s) && s["item"]["origin"].as_str() == Some("run"))
        .count();
    let hand = live.len() - other - run;
    let units = h.and_then(|h| Some((h["live_runs"].as_i64()?, h["max_live"].as_i64()?)));
    let units = units.map_or("run units unknown".to_string(), |(u, m)| {
        let per = h.and_then(|h| h["per_pass"].as_i64()).unwrap_or(0);
        format!("{u}/{m} run units, {per} per pass")
    });
    let unlinked = live.iter().filter(|s| is_unlinked(s)).count();
    let text = format!(
        "{} live: {hand} hand, {run} dispatched ({units}), {other} other",
        live.len()
    );
    (
        Part {
            text,
            ..Part::default()
        },
        live.len(),
        unlinked,
    )
}

/// `<name> on<last>, next HH:MM`, or amber with a Start when its timer has no next start.
fn timer_part(
    (name, _, service): (&'static str, &str, &str),
    timers: Option<&HashMap<String, i64>>,
    last: &str,
) -> Part {
    let Some(timers) = timers else {
        return Part {
            text: format!("{name} timer unknown{last}"),
            ..Part::default()
        };
    };
    match timers.get(service).filter(|n| **n > 0) {
        Some(next) => Part {
            text: format!("{name} on{last}, next {}", clock(*next)),
            ..Part::default()
        },
        None => Part {
            text: format!("{name} timer stopped{last}"),
            warn: true,
            start: Some(name),
            confirm: format!(
                "Start the {name} timer? It will enable it, so its passes run on schedule again."
            ),
        },
    }
}

/// `, last HH:MM VERDICT` from `fleet-shepherd stats`, or nothing before its first pass.
fn last_pass(stats: Option<&Value>) -> String {
    let Some(x) = stats else {
        return String::new();
    };
    let Some(last) = x["last_pass_epoch"].as_i64().filter(|e| *e > 0) else {
        return String::new();
    };
    match x["last_verdict"].as_str().filter(|v| !v.is_empty()) {
        Some(v) => format!(", last {} {v}", clock(last)),
        None => format!(", last {}", clock(last)),
    }
}

/// The header from what was read. A stuck shepherd is amber.
pub fn build(sessions: &[Value], src: Sources) -> Capacity {
    let (live_p, live, unlinked) = live_part(sessions, src.headroom.as_ref());
    let timers = src.timers.as_ref();
    let mut dispatch = timer_part(TIMERS[0], timers, "");
    if let Some(h) = src.headroom.as_ref().and_then(|h| h["held"].as_str()) {
        dispatch.text += &format!(", held: {h}");
    }
    let mut shepherd = timer_part(TIMERS[1], timers, &last_pass(src.shepherd.as_ref()));
    if src.shepherd.as_ref().is_some_and(|x| x["stuck"] == true) {
        shepherd.warn = true;
        shepherd.text += ", stuck";
    }
    Capacity {
        parts: vec![live_p, dispatch, shepherd],
        live,
        unlinked,
        errors: src.errors,
    }
}

/// Run one source's command and read its JSON; a failure goes in `errors` under its name.
fn json(runner: &dyn Runner, cmd: &[&str], errors: &mut Vec<String>) -> Option<Value> {
    let got = runner
        .run(&argv(cmd))
        .and_then(|o| serde_json::from_str(&o).map_err(|e| e.to_string()));
    match got {
        Ok(v) => Some(v),
        Err(e) => {
            errors.push(format!("{}: {e}", cmd[0]));
            None
        }
    }
}

/// Read every source. `fleet-dispatch headroom` walks the live units and takes seconds on a
/// loaded machine, so a caller reads this on its own, off the table's path, and keeps it a while.
pub fn read(runner: &dyn Runner, sessions: &[Value]) -> Capacity {
    let mut errors = vec![];
    let headroom = json(
        runner,
        &["fleet-dispatch", "headroom", "--json"],
        &mut errors,
    );
    let shepherd = json(runner, &["fleet-shepherd", "stats"], &mut errors);
    let timers = crate::jobs::timer_starts()
        .map_err(|e| errors.push(format!("systemctl: {e}")))
        .ok();
    build(
        sessions,
        Sources {
            headroom,
            timers,
            shepherd,
            errors,
        },
    )
}

/// [`read`] over the sessions in `fleet-sessions`' state document.
pub fn read_fleet(runner: &dyn Runner) -> Capacity {
    read(runner, &read_state(&crate::boards::fleet_state()))
}

/// Enable and start one of the two timers. Any other name is refused, and nothing here stops one.
pub fn start(runner: &dyn Runner, name: &str) -> Result<String, String> {
    let (_, unit, _) = TIMERS
        .iter()
        .find(|(n, _, _)| *n == name)
        .ok_or_else(|| format!("no timer {name}"))?;
    runner.run(&argv(&["systemctl", "--user", "enable", "--now", unit]))?;
    Ok(format!("{name} timer started"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Fake {
        calls: RefCell<Vec<Vec<String>>>,
        fail: bool,
    }
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.to_vec());
            match (self.fail, argv[0].as_str()) {
                (true, _) => Err("no such thing".into()),
                (_, "fleet-dispatch") => {
                    Ok(r#"{"live_runs":2,"max_live":40,"per_pass":3,"held":null}"#.into())
                }
                (_, "fleet-shepherd") => Ok(r#"{"last_pass_epoch":0,"stuck":false}"#.into()),
                _ => Ok(String::new()),
            }
        }
    }

    fn sessions() -> Vec<Value> {
        vec![
            json!({"bucket":"WORKING","item":{"slug":"a","origin":"run"}}),
            json!({"bucket":"WORKING","item":{"slug":"b","origin":"hand"}}),
            json!({"bucket":"NEEDS","item":null}),
            json!({"bucket":"WORKING","item":null,"labels":["shepherd"]}),
            json!({"bucket":"PARKED","item":null}),
        ]
    }

    fn on() -> HashMap<String, i64> {
        TIMERS
            .iter()
            .map(|(_, _, s)| (s.to_string(), 1_800_000_000))
            .collect()
    }

    #[test]
    fn counts_who_started_each_live_session() {
        let c = build(
            &sessions(),
            Sources {
                headroom: Some(json!({"live_runs":2,"max_live":40,"per_pass":3})),
                timers: Some(on()),
                ..Sources::default()
            },
        );
        assert_eq!(c.live, 4);
        assert_eq!(c.unlinked, 1);
        assert_eq!(
            c.parts[0].text,
            "4 live: 2 hand, 1 dispatched (2/40 run units, 3 per pass), 1 other"
        );
        assert!(c.parts.iter().all(|p| !p.warn && p.start.is_none()));
    }

    #[test]
    fn a_stopped_timer_is_amber_and_offers_start() {
        let mut timers = on();
        timers.insert("agentctl@shepherd.service".into(), 0);
        let c = build(
            &sessions(),
            Sources {
                timers: Some(timers),
                ..Sources::default()
            },
        );
        assert!(c.parts[1].text.starts_with("dispatch on, next "));
        assert_eq!(c.parts[1].start, None);
        assert_eq!(c.parts[2].text, "shepherd timer stopped");
        assert!(c.parts[2].warn);
        assert_eq!(c.parts[2].start, Some("shepherd"));
    }

    #[test]
    fn a_timer_systemd_does_not_list_is_stopped_too() {
        let c = build(
            &[],
            Sources {
                timers: Some(HashMap::new()),
                ..Sources::default()
            },
        );
        assert_eq!(c.parts[1].start, Some("dispatch"));
        assert_eq!(c.parts[2].start, Some("shepherd"));
    }

    #[test]
    fn timers_that_could_not_be_read_offer_nothing() {
        let c = build(&[], Sources::default());
        assert_eq!(c.parts[1].text, "dispatch timer unknown");
        assert!(c.parts.iter().all(|p| !p.warn && p.start.is_none()));
    }

    #[test]
    fn the_shepherd_part_carries_its_last_pass_and_verdict() {
        let at = Local
            .with_ymd_and_hms(2026, 11, 6, 12, 49, 0)
            .unwrap()
            .timestamp();
        let next = Local
            .with_ymd_and_hms(2026, 11, 6, 13, 4, 0)
            .unwrap()
            .timestamp();
        let mut timers = on();
        timers.insert("agentctl@shepherd.service".into(), next);
        let c = build(
            &[],
            Sources {
                timers: Some(timers),
                shepherd: Some(json!({"last_pass_epoch":at,"last_verdict":"WORKED","stuck":false})),
                ..Sources::default()
            },
        );
        assert_eq!(
            c.parts[2].text,
            "shepherd on, last 12:49 WORKED, next 13:04"
        );
        assert!(!c.parts[2].warn);
    }

    #[test]
    fn a_stuck_shepherd_is_amber_but_its_timer_needs_no_start() {
        let c = build(
            &[],
            Sources {
                timers: Some(on()),
                shepherd: Some(json!({"stuck":true})),
                ..Sources::default()
            },
        );
        assert!(c.parts[2].warn);
        assert!(c.parts[2].text.ends_with(", stuck"));
        assert_eq!(c.parts[2].start, None);
    }

    #[test]
    fn the_hold_is_named_on_the_dispatch_part() {
        let c = build(
            &[],
            Sources {
                headroom: Some(
                    json!({"live_runs":0,"max_live":40,"per_pass":3,"held":"fleet-assess says HOLD"}),
                ),
                timers: Some(on()),
                ..Sources::default()
            },
        );
        assert!(c.parts[1].text.ends_with(", held: fleet-assess says HOLD"));
    }

    #[test]
    fn read_parses_headroom_and_names_what_failed() {
        let c = read(&Fake::default(), &sessions());
        assert!(c.parts[0].text.contains("2/40 run units, 3 per pass"));
        let c = read(
            &Fake {
                fail: true,
                ..Fake::default()
            },
            &sessions(),
        );
        assert!(c.parts[0].text.contains("run units unknown"));
        assert!(c.errors.iter().any(|e| e.starts_with("fleet-dispatch: ")));
        assert!(c.errors.iter().any(|e| e.starts_with("fleet-shepherd: ")));
    }

    #[test]
    fn start_enables_only_the_named_timers() {
        let f = Fake::default();
        assert_eq!(start(&f, "shepherd").unwrap(), "shepherd timer started");
        assert_eq!(
            f.calls.borrow()[0],
            [
                "systemctl",
                "--user",
                "enable",
                "--now",
                "agentctl-shepherd.timer"
            ]
        );
        assert!(start(&f, "sshd").is_err());
        assert_eq!(f.calls.borrow().len(), 1);
    }
}
