//! The pace config on Costs > Limits: every `pace.conf` key with its value and where it came from,
//! the burn allowance in force with the schedule of its windows, and the one way to set or end
//! one from the page. `pace-conf --json` is the reader (it is `pace_get`'s own answer, so the
//! value shown is the value claude-acct and dispatch use); `pace-conf set` and `pace-conf end`
//! are the only writers. This module checks what a request may carry before it reaches their
//! argv, and words the view once for the hub TUI and agent-web. Spare and allowed points come
//! from claude-acct's textfile through `burn::Fleet`, so no formula is repeated here.

use chrono::{Local, NaiveDateTime, TimeZone};
use serde::{Deserialize, Serialize};

use crate::burn::{Allowance as Named, Burn};
use crate::session_actions::{argv as argv_of, Runner};

/// The first editable key: how far over the sustainable rate the fleet may burn, in percent.
pub const ALLOWANCE_KEY: &str = "BURN_OVER_PCT";

/// What the allowance loosens, said once under the section.
pub const NOTE: &str =
    "Loosens only committed: pace, reserve, 5-hour and capped still refuse on their own.";

/// The CLI the page runs.
const CLI: &str = "pace-conf";

/// One key as `pace-conf --json` lists it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Key {
    pub key: String,
    pub value: Option<f64>,
    pub default: Option<f64>,
    /// `default`, `override` or `window`.
    pub source: String,
    pub until: Option<i64>,
    pub editable: bool,
    pub max: Option<f64>,
}

/// One override or window not yet ended.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Row {
    pub key: String,
    pub value: Option<f64>,
    pub from: Option<i64>,
    pub until: Option<i64>,
    pub by: String,
    /// `in_force`, `upcoming` or `shadowed` (a standing override under a window).
    pub state: String,
}

/// `pace-conf --json`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Conf {
    pub now: i64,
    pub window_max_days: Option<u32>,
    pub keys: Vec<Key>,
    pub schedule: Vec<Row>,
}

/// Read the config. `pace-conf` exits 1 when a value cannot be read yet still prints the list, so
/// that list is parsed; a start failure or any other exit is the error.
pub fn read(runner: &dyn Runner) -> Result<Conf, String> {
    let (code, out) = runner.output(&argv_of(&[CLI, "--json"]))?;
    if !matches!(code, 0 | 1) {
        return Err(format!("{CLI} exited {code}"));
    }
    serde_json::from_str(out.trim()).map_err(|e| format!("{CLI} --json: {e}"))
}

/// A number as the page words it: `400`, `0.07`.
fn num(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("{v}"))
}

/// An epoch as `Tue 22:00`, local.
pub fn at(epoch: i64) -> String {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map_or("?".into(), |t| t.format("%a %H:%M").to_string())
}

/// `window to Tue 22:00`, `override` or `default`: where a value came from.
fn source_text(k: &Key) -> String {
    match (k.source.as_str(), k.until) {
        ("window", Some(u)) => format!("window to {}", at(u)),
        ("", _) => "unreadable".into(),
        (s, _) => s.into(),
    }
}

/// A request to set a key: a standing override (no `until`) or a window.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub key: String,
    pub value: String,
    /// `YYYY-MM-DDTHH:MM` local, or empty for now.
    #[serde(default)]
    pub from: String,
    /// `YYYY-MM-DDTHH:MM` local, or empty for a standing override.
    #[serde(default)]
    pub until: String,
}

/// A request to end a window (`from` is its start, as the schedule lists it) or, with no `from`,
/// the key's standing override.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct End {
    pub key: String,
    #[serde(default)]
    pub from: Option<i64>,
}

/// A minute as a form sends it, `2026-11-24T22:00`; nothing else reaches `date -d`.
fn is_minute(s: &str) -> bool {
    s.len() == 16 && NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M").is_ok()
}

fn editable<'a>(conf: &'a Conf, key: &str) -> Result<&'a Key, String> {
    let k = conf
        .keys
        .iter()
        .find(|k| k.key == key)
        .ok_or_else(|| format!("{key} is not a pace.conf key"))?;
    if !k.editable {
        return Err(format!(
            "{key} is not editable: pace.conf has no {key}_MAX line"
        ));
    }
    Ok(k)
}

/// The argv of `pace-conf set`, after the key is one the list marks editable, the value a plain
/// number within its max and the times minutes. The CLI checks the rest (the end in the future,
/// the span, an overlap) and its words come back as the answer.
pub fn set_argv(conf: &Conf, s: &Set) -> Result<Vec<String>, String> {
    let k = editable(conf, &s.key)?;
    let plain = !s.value.is_empty()
        && s.value.matches('.').count() <= 1
        && !s.value.starts_with('.')
        && !s.value.ends_with('.')
        && s.value.chars().all(|c| c.is_ascii_digit() || c == '.');
    let v: f64 = s
        .value
        .parse()
        .ok()
        .filter(|_| plain)
        .ok_or("the value is not a plain number")?;
    if let Some(max) = k.max.filter(|m| v > *m) {
        return Err(format!("{v} is over {}'s max of {max}", s.key));
    }
    for (what, t) in [("from", &s.from), ("until", &s.until)] {
        if !t.is_empty() && !is_minute(t) {
            return Err(format!("{what} is not a time like 2026-11-24T22:00"));
        }
    }
    if s.until.is_empty() && !s.from.is_empty() {
        return Err("a start needs an end: a standing override starts now".into());
    }
    let mut a = argv_of(&[CLI, "set", &s.key, &s.value]);
    if !s.from.is_empty() {
        a.extend(["--from".into(), s.from.clone()]);
    }
    if !s.until.is_empty() {
        a.extend(["--until".into(), s.until.clone()]);
    }
    Ok(a)
}

/// The argv of `pace-conf end`: the key must be editable, and a window to end must be one the
/// schedule lists by that start.
pub fn end_argv(conf: &Conf, e: &End) -> Result<Vec<String>, String> {
    editable(conf, &e.key)?;
    let mut a = argv_of(&[CLI, "end", &e.key]);
    if let Some(from) = e.from {
        if !conf
            .schedule
            .iter()
            .any(|r| r.key == e.key && r.from == Some(from) && r.until.is_some())
        {
            return Err(format!(
                "{} has no window that starts at {}",
                e.key,
                at(from)
            ));
        }
        a.push(format!("@{from}"));
    }
    Ok(a)
}

/// `pace-conf set`: its line, or why it refused.
pub fn set(runner: &dyn Runner, s: &Set) -> Result<String, String> {
    let argv = set_argv(&read(runner)?, s)?;
    runner.run(&argv)
}

/// `pace-conf end`: its line, or why it refused.
pub fn end(runner: &dyn Runner, e: &End) -> Result<String, String> {
    let argv = end_argv(&read(runner)?, e)?;
    runner.run(&argv)
}

/// One row of the allowance's schedule, worded.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Schedule {
    pub value: String,
    /// `Mon 14:02`, or `-` for the default.
    pub from: String,
    /// `Tue 22:00`, or `-` for a standing value and the default.
    pub until: String,
    /// `agent-web`, `hand` or `pace.conf`.
    pub by: String,
    /// `In force`, `Upcoming`, `Shadowed` (a standing value under a window) or `Default`.
    pub state: &'static str,
    /// What `end` takes: the window's start. None for a standing value or the default.
    pub start: Option<i64>,
    /// The row can be ended: a window, or a standing override.
    pub can_end: bool,
}

/// The burn allowance in force, what it lets through and when it changes.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Allowance {
    pub key: &'static str,
    /// `300`, in percent.
    pub in_force: String,
    /// `default`, `override` or `window to Tue 22:00`.
    pub source: String,
    pub default: String,
    pub max: Option<f64>,
    pub allowed: Option<f64>,
    pub sustain: Option<f64>,
    pub burn: Option<f64>,
    pub spare: Option<u32>,
    /// When claude-acct wrote the spare and allowed figures: they lag a change by its timer.
    pub as_of: Option<i64>,
    pub window_max_days: Option<u32>,
    pub note: &'static str,
    pub rows: Vec<Schedule>,
}

/// One pace.conf key: its value, where it came from and its repo default.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct KeyRow {
    pub key: String,
    pub value: String,
    pub source: String,
    pub default: String,
    pub editable: bool,
}

/// What a surface draws; `error` says so when `pace-conf` could not be read.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct View {
    pub error: Option<String>,
    pub allowance: Option<Allowance>,
    pub keys: Vec<KeyRow>,
}

impl Conf {
    fn key(&self, k: &str) -> Option<&Key> {
        self.keys.iter().find(|x| x.key == k)
    }

    /// The headline's words for the allowance, None when the key is unreadable.
    pub fn named(&self) -> Option<Named> {
        let k = self.key(ALLOWANCE_KEY)?;
        let pct = k.value?;
        let source = match (k.source.as_str(), k.until) {
            ("window", Some(u)) => format!("to {}", at(u)),
            (s, _) => s.to_string(),
        };
        Some(Named { pct, source })
    }
}

fn schedule(conf: &Conf, k: &Key) -> Vec<Schedule> {
    let mut rows: Vec<Schedule> = conf
        .schedule
        .iter()
        .filter(|r| r.key == k.key)
        .map(|r| Schedule {
            value: num(r.value),
            from: r.from.map_or("-".into(), at),
            until: r.until.map_or("-".into(), at),
            by: r.by.clone(),
            state: match r.state.as_str() {
                "upcoming" => "Upcoming",
                "shadowed" => "Shadowed",
                _ => "In force",
            },
            start: r.until.and(r.from),
            can_end: true,
        })
        .collect();
    rows.push(Schedule {
        value: num(k.default),
        from: "-".into(),
        until: "-".into(),
        by: "pace.conf".into(),
        state: if k.source == "default" {
            "In force"
        } else {
            "Default"
        },
        start: None,
        can_end: false,
    });
    rows
}

/// The view from one read and the Burn section it sits beside.
pub fn view(conf: Result<Conf, String>, burn: &Burn) -> View {
    let conf = match conf {
        Ok(c) => c,
        Err(error) => {
            return View {
                error: Some(error),
                ..View::default()
            }
        }
    };
    let f = &burn.fleet;
    let allowance = conf.key(ALLOWANCE_KEY).map(|k| Allowance {
        key: ALLOWANCE_KEY,
        in_force: num(k.value),
        source: source_text(k),
        default: num(k.default),
        max: k.max,
        allowed: f.allowed,
        sustain: (f.sustain > 0.0).then_some(f.sustain),
        burn: burn.stale.is_none().then_some(f.burn),
        spare: f.spare,
        as_of: f.as_of,
        window_max_days: conf.window_max_days,
        note: NOTE,
        rows: schedule(&conf, k),
    });
    View {
        error: None,
        allowance,
        keys: conf
            .keys
            .iter()
            .map(|k| KeyRow {
                key: k.key.clone(),
                value: num(k.value),
                source: source_text(k),
                default: num(k.default),
                editable: k.editable,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// A runner that answers `pace-conf --json` with a fixed document and records the rest.
    struct Fake {
        json: String,
        ran: RefCell<Vec<String>>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.ran.borrow_mut().push(argv.join(" "));
            Ok(if argv.last().map(String::as_str) == Some("--json") {
                self.json.clone()
            } else {
                "ok".into()
            })
        }
    }

    const JSON: &str = r#"{"now":1795516600,"window_max_days":7,"overrides":"/x",
        "keys":[
          {"key":"PACE_SLACK_PCT","value":5,"default":5,"source":"default","until":null,"editable":false,"max":null},
          {"key":"BURN_OVER_PCT","value":300,"default":400,"source":"window","until":1795586400,"editable":true,"max":1000}],
        "schedule":[
          {"key":"BURN_OVER_PCT","value":300,"from":1795516000,"until":1795586400,"by":"agent-web","state":"in_force"},
          {"key":"BURN_OVER_PCT","value":200,"from":1795700000,"until":1795800000,"by":"hand","state":"upcoming"}]}"#;

    fn conf() -> Conf {
        serde_json::from_str(JSON).unwrap()
    }

    fn set_of(key: &str, value: &str, from: &str, until: &str) -> Set {
        Set {
            key: key.into(),
            value: value.into(),
            from: from.into(),
            until: until.into(),
        }
    }

    #[test]
    fn a_window_and_a_standing_override_become_the_cli_argv() {
        let c = conf();
        let w = set_argv(&c, &set_of("BURN_OVER_PCT", "300", "", "2026-11-24T22:00")).unwrap();
        assert_eq!(
            w,
            [
                "pace-conf",
                "set",
                "BURN_OVER_PCT",
                "300",
                "--until",
                "2026-11-24T22:00"
            ]
        );
        let w = set_argv(
            &c,
            &set_of(
                "BURN_OVER_PCT",
                "0.5",
                "2026-11-24T09:00",
                "2026-11-24T18:00",
            ),
        )
        .unwrap();
        assert_eq!(w.len(), 8);
        let s = set_argv(&c, &set_of("BURN_OVER_PCT", "200", "", "")).unwrap();
        assert_eq!(s, ["pace-conf", "set", "BURN_OVER_PCT", "200"]);
    }

    #[test]
    fn a_bad_key_value_or_time_never_reaches_argv() {
        let c = conf();
        for (s, why) in [
            (set_of("PACE_SLACK_PCT", "5", "", ""), "not editable"),
            (set_of("NOPE", "5", "", ""), "not a pace.conf key"),
            (set_of("--until", "5", "", ""), "not a pace.conf key"),
            (
                set_of("BURN_OVER_PCT", "1001", "", ""),
                "over BURN_OVER_PCT's max",
            ),
            (set_of("BURN_OVER_PCT", "-1", "", ""), "plain number"),
            (set_of("BURN_OVER_PCT", "1e3", "", ""), "plain number"),
            (set_of("BURN_OVER_PCT", "", "", ""), "plain number"),
            (set_of("BURN_OVER_PCT", "1.2.3", "", ""), "plain number"),
            (
                set_of("BURN_OVER_PCT", "300", "", "tomorrow 22:00"),
                "until is not a time",
            ),
            (
                set_of("BURN_OVER_PCT", "300", "-x", "2026-11-24T22:00"),
                "from is not a time",
            ),
            (
                set_of("BURN_OVER_PCT", "300", "2026-11-24T09:00", ""),
                "needs an end",
            ),
            (
                set_of("BURN_OVER_PCT", "300", "", "2026-13-24T22:00"),
                "until is not a time",
            ),
        ] {
            let e = set_argv(&c, &s).unwrap_err();
            assert!(e.contains(why), "{s:?}: {e}");
        }
    }

    #[test]
    fn an_end_names_a_window_the_schedule_lists_or_the_standing_override() {
        let c = conf();
        let e = |key: &str, from| End {
            key: key.into(),
            from,
        };
        assert_eq!(
            end_argv(&c, &e("BURN_OVER_PCT", Some(1795516000))).unwrap(),
            ["pace-conf", "end", "BURN_OVER_PCT", "@1795516000"]
        );
        assert_eq!(
            end_argv(&c, &e("BURN_OVER_PCT", None)).unwrap(),
            ["pace-conf", "end", "BURN_OVER_PCT"]
        );
        assert!(end_argv(&c, &e("BURN_OVER_PCT", Some(5)))
            .unwrap_err()
            .contains("no window that starts"));
        assert!(end_argv(&c, &e("PACE_SLACK_PCT", None))
            .unwrap_err()
            .contains("not editable"));
    }

    #[test]
    fn set_and_end_read_the_list_first_and_run_only_a_checked_argv() {
        let fake = Fake {
            json: JSON.into(),
            ran: RefCell::new(vec![]),
        };
        set(
            &fake,
            &set_of("BURN_OVER_PCT", "250", "", "2026-11-24T22:00"),
        )
        .unwrap();
        assert!(set(&fake, &set_of("RESERVE_PCT", "1", "", "")).is_err());
        end(
            &fake,
            &End {
                key: "BURN_OVER_PCT".into(),
                from: Some(1795516000),
            },
        )
        .unwrap();
        assert_eq!(
            fake.ran.borrow().as_slice(),
            [
                "pace-conf --json",
                "pace-conf set BURN_OVER_PCT 250 --until 2026-11-24T22:00",
                "pace-conf --json",
                "pace-conf --json",
                "pace-conf end BURN_OVER_PCT @1795516000",
            ]
        );
    }

    #[test]
    fn the_request_bodies_refuse_a_field_they_do_not_know() {
        assert!(serde_json::from_str::<Set>(r#"{"key":"A","value":"1","extra":1}"#).is_err());
        assert!(serde_json::from_str::<End>(r#"{"key":"A","from":1,"x":1}"#).is_err());
        assert!(serde_json::from_str::<End>(r#"{"key":"A"}"#).is_ok());
    }

    #[test]
    fn the_view_names_each_key_its_source_and_the_schedule_ends_on_the_default() {
        let mut burn = Burn::default();
        burn.fleet.burn = 5.1;
        burn.fleet.sustain = 2.1;
        burn.fleet.allowed = Some(6.3);
        burn.fleet.spare = Some(3);
        let v = view(Ok(conf()), &burn);
        assert_eq!(v.keys.len(), 2);
        assert_eq!(v.keys[1].source, format!("window to {}", at(1795586400)));
        assert!(v.keys[1].editable && !v.keys[0].editable);
        let a = v.allowance.unwrap();
        assert_eq!((a.in_force.as_str(), a.default.as_str()), ("300", "400"));
        assert_eq!((a.allowed, a.spare), (Some(6.3), Some(3)));
        let states: Vec<_> = a.rows.iter().map(|r| r.state).collect();
        assert_eq!(states, ["In force", "Upcoming", "Default"]);
        assert_eq!(a.rows[0].start, Some(1795516000));
        assert!(a.rows[0].can_end && !a.rows[2].can_end);
    }

    #[test]
    fn a_default_in_force_is_the_last_row_and_in_force() {
        let c: Conf = serde_json::from_str(
            r#"{"keys":[{"key":"BURN_OVER_PCT","value":400,"default":400,"source":"default","editable":true,"max":1000}]}"#,
        )
        .unwrap();
        let a = view(Ok(c.clone()), &Burn::default()).allowance.unwrap();
        assert_eq!(a.rows.len(), 1);
        assert_eq!(
            (a.rows[0].state, a.rows[0].by.as_str()),
            ("In force", "pace.conf")
        );
        let n = c.named().unwrap();
        assert_eq!((n.pct, n.source.as_str()), (400.0, "default"));
    }

    #[test]
    fn a_failed_read_is_the_views_error_and_never_an_empty_all_clear() {
        let v = view(Err("pace-conf: boom".into()), &Burn::default());
        assert_eq!(v.error.as_deref(), Some("pace-conf: boom"));
        assert!(v.allowance.is_none() && v.keys.is_empty());
    }

    #[test]
    fn the_window_to_a_time_is_in_the_headline_words() {
        let n = conf().named().unwrap();
        assert_eq!(n.pct, 300.0);
        assert_eq!(n.source, format!("to {}", at(1795586400)));
    }
}
