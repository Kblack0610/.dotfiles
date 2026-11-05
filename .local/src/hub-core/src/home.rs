//! The Home tab for both surfaces: what needs the human, what is running, the headline numbers
//! and the health chips. It joins what the other readers already read (fleet-sessions'
//! `state.json`, `queue::Queue`, `infra::Infra`) and reads nothing itself, so it is pure and
//! both surfaces get the same rows in the same order.
//!
//! One row per thing that waits: a session with a pending ask shows the ask, not the session as
//! well, and a queue item waiting on a session already shown adds nothing. Sessions are matched
//! by their tmux session name, the one name an ask, a queue item and a state row all carry.

use std::collections::{HashMap, HashSet};

use serde::Serialize;
use serde_json::Value;

use crate::boards;
use crate::fleet::ts;
use crate::infra::Infra;
use crate::queue::{Item, Queue, State};

/// The health chips, in the order the strip shows them (the `cc:domain_status` domains).
pub const DOMAINS: [&str; 11] = [
    "k3s", "machines", "ci", "prod", "llm", "agents", "spend", "platform", "queue", "home", "other",
];
/// The domains shown even when Prometheus has no status for them, so a missing one reads as no data.
const ALWAYS: [&str; 2] = ["k3s", "ci"];
/// How much of a question or reason a row keeps.
pub const TEXT_MAX: usize = 160;
/// How many rows of a list Home shows before the rest fold under "+N older" (dashboards rule: a
/// long list is capped, never unbounded at top level).
pub const SHOWN: usize = 8;

/// What a row is. The order here is the order Home lists them in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A pending `agent-ask`, answered by its id.
    Ask,
    /// A session fleet-sessions buckets NEEDS with no ask: a dialog, a permission or a stop.
    Session,
    /// A queue item waiting with no session or ask shown for it.
    Queue,
    /// A repo whose nightly on main is red.
    Nightly,
    /// An item of `cc:red_now`.
    Red,
}

/// One row of NEEDS YOU.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Need {
    pub kind: Kind,
    pub project: String,
    pub text: String,
    /// What the row acts on: the ask id, the session's tmux target, the queue slug, the repo or
    /// the red item.
    pub id: String,
    /// The tmux target (`server/session:window`) of the session behind the row, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// When it started waiting, unix seconds, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub since: Option<i64>,
}

/// One running queue item, with its plan's progress when its session has a checklist.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Running {
    pub slug: String,
    pub title: String,
    pub project: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phases: Option<boards::Phases>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Warn,
    Red,
    Nodata,
}

impl Level {
    /// A `cc:*_status` value: 0 ok, 1 warn, 2 red, anything else or none is no data.
    pub fn of(v: Option<f64>) -> Level {
        match v.map(|v| v as i64) {
            Some(0) => Level::Ok,
            Some(1) => Level::Warn,
            Some(2) => Level::Red,
            _ => Level::Nodata,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Chip {
    pub name: String,
    pub level: Level,
}

/// One headline number, worded once for both surfaces.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Number {
    pub label: &'static str,
    pub value: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Home {
    pub needs: Vec<Need>,
    pub running: Vec<Running>,
    pub numbers: Vec<Number>,
    pub health: Vec<Chip>,
    /// What could not be read, so a short list never reads as an all-clear.
    pub errors: Vec<String>,
    /// How many rows of each list show before the rest fold (`SHOWN`), sent so the web reads it.
    pub shown: usize,
}

impl Home {
    /// The chips that are not green: the strip shows only these, and one "all green" line when
    /// there are none (dashboards.md rule 4).
    pub fn exceptions(&self) -> impl Iterator<Item = &Chip> {
        self.health.iter().filter(|c| c.level != Level::Ok)
    }
}

/// The tmux session name in a target (`server/session:window`), a queue item's session
/// (`server:session` or bare) or an ask's (bare).
fn tmux_name(s: &str) -> &str {
    if let Some((_, rest)) = s.split_once('/') {
        return rest.rsplit_once(':').map_or(rest, |(n, _)| n);
    }
    s.split_once(':').map_or(s, |(_, n)| n)
}

fn str_of<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

/// The first line, whitespace squeezed, capped at `TEXT_MAX` chars.
fn short(s: &str) -> String {
    let line = s.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    let t = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.chars().count() <= TEXT_MAX {
        return t;
    }
    let cut: String = t.chars().take(TEXT_MAX - 3).collect();
    format!("{}...", cut.trim_end())
}

/// The last path segment of a session's cwd, the project a session row shows without a queue item.
fn dir_name(cwd: &str) -> String {
    cwd.rsplit('/')
        .find(|s| !s.is_empty())
        .unwrap_or("")
        .trim_start_matches('.')
        .to_string()
}

/// Infra's `cc` series keyed as the boards key them: `name` or `name/<domain|host|pool|site>`.
fn cc_values(infra: &Infra) -> HashMap<String, f64> {
    let mut v = HashMap::new();
    for s in infra.get("cc") {
        let name = s.label("__name__");
        let sub = if name == "cc:domain_status" {
            s.label("domain")
        } else {
            ["host", "pool", "site"]
                .into_iter()
                .map(|k| s.label(k))
                .find(|x| !x.is_empty())
                .unwrap_or("")
        };
        let key = if sub.is_empty() {
            name.to_string()
        } else {
            format!("{name}/{sub}")
        };
        if let Some(x) = s.value {
            v.insert(key, x);
        }
    }
    v
}

/// Home from fleet-sessions' `state.json` (null when missing), the queue and infra (None until
/// read). Needs come asks first, then sessions, queue items, nightly reds and red-now items,
/// each newest first.
/// The tmux target of session `name` in `sessions`, when exactly one window carries it.
fn target_in(sessions: &[&Value], name: &str) -> Option<String> {
    let mut m = sessions
        .iter()
        .map(|s| str_of(s, "target"))
        .filter(|t| !t.is_empty() && tmux_name(t) == name);
    let first = m.next()?;
    // Two windows of one tmux session: the name alone cannot say which.
    m.next().is_none().then(|| first.to_string())
}

/// The running queue items, each with its session's plan progress when it has a checklist:
/// Home's running section and each Projects card's in-flight list.
pub fn running(state: &Value, q: &Queue) -> Vec<Running> {
    let sessions: Vec<&Value> = state["sessions"]
        .as_array()
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let phases = boards::phases(state);
    q.in_state(State::Running)
        .map(|i| {
            let target = i
                .session
                .as_deref()
                .and_then(|s| target_in(&sessions, tmux_name(s)));
            Running {
                slug: i.slug.clone(),
                title: i.title(),
                project: i.project.clone(),
                started: i.started.clone(),
                phases: target.as_ref().and_then(|t| phases.get(t).cloned()),
                target,
            }
        })
        .collect()
}

pub fn build(state: &Value, queue: Option<&Queue>, infra: Option<&Infra>) -> Home {
    let mut h = Home {
        shown: SHOWN,
        ..Home::default()
    };
    let generated = state["generated_epoch"].as_i64();
    let sessions: Vec<&Value> = state["sessions"]
        .as_array()
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let target_of = |name: &str| target_in(&sessions, name);
    let items: Vec<&Item> = queue.map(|q| q.items.iter().collect()).unwrap_or_default();
    let item_of = |name: &str| {
        items.iter().copied().find(|i| {
            matches!(i.state, State::Waiting | State::Running)
                && i.session.as_deref().is_some_and(|s| tmux_name(s) == name)
        })
    };
    let mut shown: HashSet<String> = HashSet::new();

    if state.is_null() {
        h.errors
            .push("no fleet state yet (fleet-state.timer writes it every minute)".into());
    }
    for a in state["asks"].as_array().into_iter().flatten() {
        let session = str_of(a, "session");
        if !session.is_empty() {
            shown.insert(session.to_string());
        }
        h.needs.push(Need {
            kind: Kind::Ask,
            project: str_of(a, "project").into(),
            text: short(str_of(a, "question")),
            id: str_of(a, "id").into(),
            target: (!session.is_empty()).then(|| target_of(session)).flatten(),
            since: ts(str_of(a, "created")),
        });
    }
    for s in &sessions {
        let target = str_of(s, "target");
        let name = tmux_name(target);
        if str_of(s, "bucket") != "NEEDS" || shown.contains(name) {
            continue;
        }
        shown.insert(name.to_string());
        let item = item_of(name);
        h.needs.push(Need {
            kind: Kind::Session,
            project: item.map_or_else(|| dir_name(str_of(s, "cwd")), |i| i.project.clone()),
            text: short(&item.map_or_else(|| str_of(s, "reason").to_string(), |i| i.title())),
            id: target.into(),
            target: Some(target.into()),
            since: generated
                .zip(s["idle_min"].as_i64())
                .map(|(g, m)| g - m * 60),
        });
    }
    for i in items.iter().filter(|i| i.state == State::Waiting) {
        if i.session
            .as_deref()
            .is_some_and(|s| shown.contains(tmux_name(s)))
        {
            continue;
        }
        let waited = i.extra.get("waiting").and_then(Value::as_str);
        h.needs.push(Need {
            kind: Kind::Queue,
            project: i.project.clone(),
            text: short(&i.title()),
            id: i.slug.clone(),
            target: i.session.as_deref().and_then(|s| target_of(tmux_name(s))),
            since: waited.or(i.started.as_deref()).and_then(ts),
        });
    }
    for m in state["main"].as_array().into_iter().flatten() {
        h.needs.push(Need {
            kind: Kind::Nightly,
            project: str_of(m, "repo").into(),
            text: short(str_of(m, "reason")),
            id: str_of(m, "repo").into(),
            target: None,
            since: None,
        });
    }
    if let Some(inf) = infra.filter(|i| i.ok) {
        let mut red: Vec<&str> = inf
            .get("red")
            .iter()
            .map(|s| s.label("item"))
            .filter(|i| !i.is_empty())
            .collect();
        red.sort();
        red.dedup();
        for r in red {
            h.needs.push(Need {
                kind: Kind::Red,
                project: String::new(),
                text: r.into(),
                id: r.into(),
                target: None,
                since: None,
            });
        }
    }
    // Stable: same kind keeps its newest first, unknown ages last, so the fold holds the oldest.
    h.needs.sort_by_key(|n| {
        (
            n.kind,
            n.since.is_none(),
            std::cmp::Reverse(n.since.unwrap_or(0)),
        )
    });

    if let Some(q) = queue {
        h.errors.extend(q.errors.iter().cloned());
        h.running = running(state, q);
        let held = q
            .in_state(State::Queued)
            .filter(|i| i.hold.is_some())
            .count();
        let mut next = format!("{} up next", q.count(State::Queued));
        if held > 0 {
            next += &format!(" ({held} held)");
        }
        h.numbers.push(Number {
            label: "queue",
            value: format!("{} running, {next}", q.count(State::Running)),
        });
        h.numbers.push(Number {
            label: "done today",
            value: q.count(State::Done).to_string(),
        });
    }
    if let Some(c) = state["counts"].as_object() {
        let n = |k: &str| c.get(k).and_then(Value::as_u64).unwrap_or(0);
        h.numbers.push(Number {
            label: "sessions",
            value: format!(
                "{} working, {} need you, {} stalled",
                n("WORKING"),
                n("NEEDS"),
                n("STALLED")
            ),
        });
    }

    match infra {
        None => h.errors.push("Prometheus: reading".into()),
        Some(i) if !i.ok => h.errors.push(format!(
            "Prometheus: {}",
            i.error.as_deref().unwrap_or("did not answer")
        )),
        Some(i) => {
            let v = cc_values(i);
            if let Some(x) = v.get("cc:claude_code_cost_24h_usd") {
                h.numbers.push(Number {
                    label: "claude 24h",
                    value: format!("${x:.0}"),
                });
            }
            for d in DOMAINS {
                let s = v.get(&format!("cc:domain_status/{d}")).copied();
                if s.is_some() || ALWAYS.contains(&d) {
                    h.health.push(Chip {
                        name: d.into(),
                        level: Level::of(s),
                    });
                }
            }
        }
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn infra(cc: Vec<Value>, red: &[&str]) -> Infra {
        let res = |rows: Vec<Value>| {
            crate::prom::flatten(&json!({"status": "success", "data": {"result": rows}})).unwrap()
        };
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert("cc", res(cc));
        i.instant.insert(
            "red",
            res(red
                .iter()
                .map(|r| json!({"metric": {"item": r}, "value": [0, "1"]}))
                .collect()),
        );
        i
    }

    fn domain(d: &str, v: &str) -> Value {
        json!({"metric": {"__name__": "cc:domain_status", "domain": d}, "value": [0, v]})
    }

    fn item(slug: &str, state: State, session: Option<&str>) -> Item {
        Item {
            slug: slug.into(),
            state,
            project: "p".into(),
            task: format!("Do {slug}."),
            session: session.map(String::from),
            ..Default::default()
        }
    }

    fn state() -> Value {
        json!({
            "generated_epoch": 10_000,
            "counts": {"WORKING": 2, "NEEDS": 2, "STALLED": 0},
            "sessions": [
                {"target": "lab/repo-agent-1:1", "bucket": "NEEDS", "asks": 1, "idle_min": 5, "cwd": "/w/repo"},
                {"target": "hub/dotfiles:2", "bucket": "NEEDS", "asks": 0, "idle_min": 3,
                 "cwd": "/home/k/.dotfiles", "reason": "waiting on a prompt or permission"},
                {"target": "lab/repo-agent-2:1", "bucket": "WORKING", "phases_done": 2,
                 "phases_total": 4, "next_phase": "three"},
            ],
            "asks": [
                {"id": "a1", "project": "repo", "question": "Which one?\nmore", "session": "repo-agent-1",
                 "created": "2026-11-05T08:00:00-0800"},
            ],
            "main": [{"repo": "repo", "reason": "repo red: Tests"}],
        })
    }

    #[test]
    fn an_ask_stands_for_its_session_and_its_queue_item_once() {
        let q = Queue {
            items: vec![
                item("asked", State::Waiting, Some("lab:repo-agent-1")),
                item("lone", State::Waiting, None),
                item("dialog", State::Waiting, Some("hub:dotfiles")),
                item("busy", State::Running, Some("lab:repo-agent-2")),
            ],
            ..Default::default()
        };
        let h = build(&state(), Some(&q), None);
        let rows: Vec<(Kind, &str)> = h.needs.iter().map(|n| (n.kind, n.id.as_str())).collect();
        assert_eq!(
            rows,
            [
                (Kind::Ask, "a1"),
                (Kind::Session, "hub/dotfiles:2"),
                (Kind::Queue, "lone"),
                (Kind::Nightly, "repo"),
            ]
        );
        let ask = &h.needs[0];
        assert_eq!(ask.text, "Which one?");
        assert_eq!(ask.target.as_deref(), Some("lab/repo-agent-1:1"));
        // The session row takes its queue item's words, and its age from the idle minutes.
        assert_eq!(h.needs[1].text, "Do dialog");
        assert_eq!(h.needs[1].since, Some(10_000 - 180));
        assert_eq!(h.running.len(), 1);
        let p = h.running[0].phases.as_ref().unwrap();
        assert_eq!((p.done, p.total), (2, 4));
        assert_eq!(h.numbers[0].value, "1 running, 0 up next");
        assert_eq!(h.errors, ["Prometheus: reading"]);
    }

    #[test]
    fn asks_list_newest_first_so_the_fold_holds_the_oldest() {
        let mut st = state();
        st["asks"] = json!([
            {"id": "old", "question": "q", "created": "2026-11-05T08:00:00-0800"},
            {"id": "new", "question": "q", "created": "2026-11-05T09:00:00-0800"},
            {"id": "undated", "question": "q"},
        ]);
        let h = build(&st, None, None);
        let ids: Vec<&str> = h
            .needs
            .iter()
            .filter(|n| n.kind == Kind::Ask)
            .map(|n| n.id.as_str())
            .collect();
        assert_eq!(ids, ["new", "old", "undated"]);
        assert_eq!(h.shown, SHOWN);
    }

    #[test]
    fn health_keeps_the_known_domains_and_red_now_items_are_needs() {
        let i = infra(
            vec![domain("ci", "1"), domain("prod", "0")],
            &["watch:b", "watch:a"],
        );
        let h = build(&Value::Null, None, Some(&i));
        let chips: Vec<(&str, Level)> = h
            .health
            .iter()
            .map(|c| (c.name.as_str(), c.level))
            .collect();
        assert_eq!(
            chips,
            [
                ("k3s", Level::Nodata),
                ("ci", Level::Warn),
                ("prod", Level::Ok)
            ]
        );
        assert_eq!(h.exceptions().count(), 2);
        let red: Vec<&str> = h.needs.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(red, ["watch:a", "watch:b"]);
        assert!(h.errors[0].starts_with("no fleet state"));
    }

    #[test]
    fn a_failed_prometheus_read_is_an_error_not_a_green_strip() {
        let i = Infra {
            ok: false,
            error: Some("timeout".into()),
            ..Default::default()
        };
        let h = build(&state(), None, Some(&i));
        assert!(h.health.is_empty());
        assert_eq!(h.errors, ["Prometheus: timeout"]);
    }

    #[test]
    fn a_session_name_is_read_from_every_shape() {
        assert_eq!(tmux_name("lab/repo-agent-1:1"), "repo-agent-1");
        assert_eq!(tmux_name("lab:repo-agent-1"), "repo-agent-1");
        assert_eq!(tmux_name("repo-agent-1"), "repo-agent-1");
        assert_eq!(dir_name("/home/k/.dotfiles"), "dotfiles");
    }
}
