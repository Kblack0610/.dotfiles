//! Whether agent work flows: the last dispatch pass's facts turned into exceptions, each with its
//! level and its Do (the command or skill that shows or fixes its cause). The one home for this
//! verdict: the Queue card carries it (`cards::queue`), the waybar queue chip lays that card out
//! from summary/cards, and the hub and web Queue tabs draw the same lines (dashboards.md rule 8).
//!
//! The facts are the live topics the fleet lease holder's agent-mqtt-publish sends, read back from
//! Prometheus in one instant query (`QUERY`): summary/dispatch (`fleet-dispatch stats`), the
//! fleet_dispatch runner, the queue-starved watch and summary/shepherd, plus the accounts' room
//! reasons from the claude-acct textfile. Prometheus is where every host sees the same numbers,
//! and the host whose pass ran last is the source: only the lease holder runs a pass, and a peer
//! with a frozen store clone once sent 622 queued (ar-4306), so its series are dropped.

use std::collections::{BTreeMap, BTreeSet};

use crate::display::fmt::{dur_min, dur_secs};
use crate::home::Level;
use crate::prom::Series;

/// fleet-dispatch runs every 15 minutes; three missed passes is a stopped timer, not a slow one.
const PASS_LATE_SECS: i64 = 2700;
/// claude-acct-usage.timer writes the accounts' textfile every 15 minutes; three missed is stale.
const ROOM_LATE_SECS: i64 = 2700;

/// The topics read, by the kind each fact is filed under (`dispatch.runnable`, `watch.tripped`).
const KINDS: &[(&str, &str)] = &[
    ("summary_dispatch", "dispatch"),
    ("runner_fleet_dispatch", "runner"),
    ("watch_queue_starved", "watch"),
    ("summary_shepherd", "shepherd"),
];

/// The gates a pass can be held by, in `fleet-dispatch stats`' `room_held_<kind>` names.
const GATES: &[&str] = &["slots", "load", "account", "assess", "other"];

/// A load or cap as published, to one decimal with a whole number bare: 25.2, 30. Floored, a
/// load just over its cap would read as equal to it.
fn one_dp(x: f64) -> String {
    let s = format!("{x:.1}");
    s.strip_suffix(".0").map_or(s.clone(), str::to_string)
}

/// The Do for each exception: what shows or fixes its cause, said after the point. Content, so
/// a renamed command is one edit here.
fn act(key: &str) -> &'static str {
    match key {
        "slots" | "other" | "could" => "Run fleet-dispatch headroom",
        "load" => "See the fleet-pace skill",
        "assess" => "Run fleet-assess",
        "account" => "Run claude-acct status",
        "blocked" | "starved" => "Run fleet-dispatch run --dry-run",
        "flapping" | "failed" => "Run agentctl logs fleet-dispatch",
        "late" => "Run systemctl --user status agentctl-fleet-dispatch.timer",
        "shepherd" => "Use the shepherd skill, triage",
        "nofeed" => "Run systemctl --user status agent-mqtt-publish.timer",
        _ => "",
    }
}

/// Where each exception's cause shows, for the Queue tab's banner link: the held work, the runner
/// that failed, the shepherd. Content, like `act`.
fn to(key: &str) -> &'static str {
    match key {
        "slots" | "other" | "could" | "load" | "assess" | "account" | "blocked" | "starved" => {
            "#queue/next"
        }
        "flapping" | "failed" | "late" | "nofeed" => "#sessions/runners",
        "shepherd" => "#sessions/shepherd",
        _ => "",
    }
}

/// The one instant query: the live topics' series, and the accounts' room reasons from a textfile
/// written in the last `ROOM_LATE_SECS`.
pub fn query() -> String {
    let topics = KINDS.iter().map(|(t, _)| *t).collect::<Vec<_>>().join("|");
    format!(
        "({{__name__=~\"mqtt_.+\", topic=~\"agents_.+_({topics})\"}} and on (topic) cc:agents_topic_live) \
         or (claude_account_room_reason and on (instance) \
         (time() - node_textfile_mtime_seconds{{file=~\".*/claude_acct.prom\"}} < {ROOM_LATE_SECS}))"
    )
}

/// The verdict of one read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Verdict {
    /// Every exception in the order raised; `head` is the worst of them.
    pub exceptions: Vec<Line>,
    /// The gate that held the last pass in words, when one did.
    pub paused: Option<String>,
    /// Each account with no room and why, when the account gate held the pass.
    pub accounts: Vec<(String, String)>,
    /// The source host's facts by `<kind>.<key>`: counts, 0/1s and epochs, and the load and its cap.
    pub facts: BTreeMap<String, f64>,
    /// Why Prometheus could not be read; the verdict is then that one line.
    pub error: Option<String>,
}

/// A line of the verdict as a surface draws it, an exception among them: the text, its Do (empty
/// for none), its level.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub level: Level,
    pub text: String,
    pub act: String,
    /// The page that shows the cause, a `#tab/section` link; empty for none.
    pub to: String,
}

/// Red over amber over the rest, for picking the worst of some levels.
pub(crate) fn rank(l: Level) -> u8 {
    match l {
        Level::Red => 2,
        Level::Warn => 1,
        _ => 0,
    }
}

impl Line {
    /// A line with no Do.
    fn plain(level: Level, text: String) -> Line {
        Line {
            level,
            text,
            act: String::new(),
            to: String::new(),
        }
    }

    /// The line as one sentence with its Do after it, as the Queue tabs draw it.
    pub fn said(&self) -> String {
        match self.act.as_str() {
            "" => format!("{}.", self.text),
            act => format!("{}. {act}.", self.text),
        }
    }
}

/// How many banners a tab with one line per banner draws (agent-web's Queue and the hub's).
pub const BANNER_LINES: usize = 3;

/// At most `n` of the verdict's lines, red over amber over the rest, each group in the order
/// raised: what a tab with one line per banner draws, so a long verdict does not push the rows
/// down.
pub fn worst_first(mut lines: Vec<Line>, n: usize) -> Vec<Line> {
    lines.sort_by_key(|l| std::cmp::Reverse(rank(l.level)));
    lines.truncate(n);
    lines
}

impl Verdict {
    /// Read the facts now and judge them at `now`.
    pub fn read(now: i64) -> Verdict {
        match crate::prom::base().and_then(|b| crate::prom::instant(&b, &query())) {
            Ok(s) => Verdict::from_series(&s, now),
            Err(e) => Verdict {
                error: Some(e),
                ..Verdict::default()
            },
        }
    }

    /// A fact of the source host floored, None when the feed lacks it.
    pub fn get(&self, key: &str) -> Option<i64> {
        self.fact(key).map(|v| v.floor() as i64)
    }

    /// A fact of the source host as published (the load and its cap carry fractions).
    pub fn fact(&self, key: &str) -> Option<f64> {
        self.facts.get(key).copied()
    }

    /// How long dispatch has been held, 0 when it is not.
    fn held(&self) -> i64 {
        self.get("dispatch.held_s").unwrap_or(0)
    }

    /// The queue-starved watch tripped: ready urgent or high work sat too long.
    fn starved(&self) -> bool {
        self.get("watch.tripped") == Some(1)
    }

    /// The last pass ended BLOCKED: it started nothing.
    fn blocked(&self) -> bool {
        self.get("runner.blocked") == Some(1)
    }

    /// The verdict over the query's answer, judged at `now`.
    pub fn from_series(series: &[Series], now: i64) -> Verdict {
        let v = Verdict {
            facts: source_facts(series),
            ..Verdict::default()
        };
        let get = |k: &str| v.get(k);
        let d = |k: &str| get(&format!("dispatch.{k}"));
        let (mut paused, mut accounts_of) = (None, vec![]);
        let dash = |x: Option<i64>| x.map_or("-".to_string(), |n| n.to_string());
        let mut ex: Vec<Line> = vec![];
        let mut flag = |level: Level, what: String, key: &str| {
            ex.push(Line {
                level,
                text: what,
                act: act(key).into(),
                to: to(key).into(),
            })
        };
        let (starved, blocked, held) = (v.starved(), v.blocked(), v.held());
        let mut gate = None;
        if d("runnable").is_none() {
            flag(
                Level::Warn,
                "No dispatch numbers on the feed".into(),
                "nofeed",
            );
        } else {
            // The gate that stopped the last pass, in words with its numbers.
            for k in GATES {
                if d(&format!("room_held_{k}")) != Some(1) {
                    continue;
                }
                gate = Some(*k);
                paused = Some(match *k {
                    "slots" => format!(
                        "the fleet is at its session target of {}",
                        dash(d("room_max_live"))
                    ),
                    // The load the gate judged on the pass it held (with its recent starts), never
                    // the live reading, which can sit under the cap beside the hold.
                    "load" => match (
                        v.fact("dispatch.room_load_at_hold"),
                        v.fact("dispatch.room_load_cap"),
                    ) {
                        (Some(l), Some(c)) => {
                            format!("load {} is over its cap of {}", one_dp(l), one_dp(c))
                        }
                        (_, c) => {
                            format!("load is over its cap of {}", c.map_or("-".into(), one_dp))
                        }
                    },
                    "assess" => "the fleet-assess check says the machine is too busy".into(),
                    "account" => "no account has room".into(),
                    _ => "a gate holds it".into(),
                });
            }
            if gate == Some("account") {
                accounts_of = accounts(series);
            }
            let held_key = gate.unwrap_or("blocked");
            // A hold is the head: how long and what it blocks. queue-starved trips on a hold (its
            // watch reads the runner's held_since), so while one stands the starve is the same
            // cause: one red sentence.
            if held > 0 {
                let p = paused
                    .clone()
                    .unwrap_or_else(|| "the last pass left ready work waiting".into());
                let level = if starved { Level::Red } else { Level::Warn };
                flag(
                    level,
                    format!("Dispatch paused {}: {p}", dur_secs(held as f64)),
                    held_key,
                );
            } else if starved {
                flag(
                    Level::Red,
                    "An urgent or high item sat ready too long, and nothing started it".into(),
                    "starved",
                );
            } else if blocked {
                let p = paused.as_ref().map_or(String::new(), |p| format!(": {p}"));
                flag(
                    Level::Warn,
                    format!("The last pass started nothing{p}"),
                    held_key,
                );
            }
            if get("runner.failed") == Some(1) {
                flag(
                    Level::Red,
                    "The fleet-dispatch runner failed".into(),
                    "failed",
                );
            }
            match d("last_pass_epoch") {
                None => flag(Level::Red, "No dispatch pass on record".into(), "late"),
                Some(p) if now - p > PASS_LATE_SECS => flag(
                    Level::Red,
                    format!("No dispatch pass in {}", dur_secs((now - p) as f64)),
                    "late",
                ),
                Some(_) => {}
            }
            let flapping = d("flapping_items").unwrap_or(0);
            if flapping > 0 {
                flag(
                    Level::Warn,
                    format!("{flapping} item(s) flapping: a writer undoes reap's moves"),
                    "flapping",
                );
            }
            let could = d("could_start").unwrap_or(0);
            if could > 0 {
                flag(
                    Level::Warn,
                    format!("{could} more could start: a limit holds them, not the machine"),
                    "could",
                );
            }
        }
        let unhandled = get("shepherd.unhandled").unwrap_or(0);
        if unhandled > 0 {
            flag(
                Level::Warn,
                format!("{unhandled} shepherd due line(s) unhandled"),
                "shepherd",
            );
        }
        Verdict {
            exceptions: ex,
            paused,
            accounts: accounts_of,
            ..v
        }
    }

    /// The worst exception's index, the first of the worst level.
    pub fn head(&self) -> Option<usize> {
        let top = self.exceptions.iter().map(|e| rank(e.level)).max()?;
        self.exceptions.iter().position(|e| rank(e.level) == top)
    }

    /// The level the queue wears: the worst exception's, ok with none, amber with no read.
    pub fn level(&self) -> Level {
        if self.error.is_some() {
            return Level::Warn;
        }
        self.head().map_or(Level::Ok, |i| self.exceptions[i].level)
    }

    /// The lines every surface draws, each a sentence, in order: the head (the worst exception, or
    /// "Flowing"), the item a hold or starve keeps waiting (from `ready`, the start order, built only
    /// when something waits), each other exception, the gate that paused a pass nothing else names,
    /// and each account with no room.
    pub fn lines<R: std::borrow::Borrow<crate::bar::Ready>>(
        &self,
        ready: impl FnOnce() -> R,
    ) -> Vec<Line> {
        if let Some(e) = &self.error {
            return vec![Line::plain(Level::Warn, format!("No flow verdict: {e}"))];
        }
        let head = self.head();
        let mut out = vec![head.map_or(Line::plain(Level::Ok, "Flowing".into()), |i| {
            self.exceptions[i].clone()
        })];
        // A hold, a starve or a BLOCKED pass: something keeps ready work from starting.
        let starved = self.starved();
        if self.get("dispatch.runnable").is_some() && (self.held() > 0 || starved || self.blocked())
        {
            let level = if starved { Level::Red } else { Level::Warn };
            out.extend(
                self.waiting(ready().borrow(), starved)
                    .map(|text| Line {
                        to: "#queue/next".into(),
                        ..Line::plain(level, text)
                    }),
            );
        }
        out.extend(
            self.exceptions
                .iter()
                .enumerate()
                .filter(|(i, _)| Some(*i) != head)
                .map(|(_, e)| e.clone()),
        );
        if let Some(p) = &self.paused {
            // A hold or a BLOCKED pass already said its gate.
            if self.held() == 0 && !self.blocked() {
                out.push(Line {
                    to: "#queue/next".into(),
                    ..Line::plain(Level::Warn, format!("Paused: {p}"))
                });
            }
        }
        // An account name stays as it is written.
        out.extend(
            self.accounts
                .iter()
                .map(|(a, why)| Line {
                    to: "#costs/limits".into(),
                    ..Line::plain(Level::Nodata, format!("{a}: no room, {why}"))
                }),
        );
        out
    }

    /// The urgent item kept waiting (or with a starve, the oldest high one when no urgent item
    /// is ready), by name from the start order, else by the feed's oldest urgent age.
    fn waiting(&self, ready: &crate::bar::Ready, starved: bool) -> Option<String> {
        let pick = ready
            .items
            .iter()
            .find(|i| i.priority == "urgent")
            .or_else(|| {
                starved
                    .then(|| ready.items.iter().find(|i| i.priority == "high"))
                    .flatten()
            });
        if let Some(i) = pick {
            let p = if i.priority == "urgent" {
                "Urgent"
            } else {
                "High"
            };
            let what = match (i.kind.as_str(), i.area.as_str()) {
                ("", _) => i.title.clone(),
                (k, "") => format!("{k}: {}", i.title),
                (k, a) => format!("{k}({a}): {}", i.title),
            };
            return Some(format!("{p} item waiting {}: {what}", dur_min(i.ready_min)));
        }
        self.get("dispatch.oldest_urgent_s")
            .map(|s| format!("Urgent item waiting {}", dur_secs(s as f64)))
    }
}

/// The facts by `<kind>.<key>` of the host whose pass ran last; with no pass on record anywhere,
/// every host's, by their max. A second scrape of one host counts once (the max).
fn source_facts(series: &[Series]) -> BTreeMap<String, f64> {
    let mut all: Vec<(String, String, f64)> = vec![];
    for s in series {
        let (Some(t), Some(name), Some(v)) = (
            s.labels.get("topic"),
            s.labels
                .get("__name__")
                .and_then(|n| n.strip_prefix("mqtt_")),
            s.value,
        ) else {
            continue;
        };
        let Some(rest) = t.strip_prefix("agents_") else {
            continue;
        };
        let Some((host, kind)) = KINDS.iter().find_map(|(topic, kind)| {
            rest.strip_suffix(topic)
                .and_then(|h| h.strip_suffix('_'))
                .filter(|h| !h.is_empty())
                .map(|h| (h, *kind))
        }) else {
            continue;
        };
        all.push((host.to_string(), format!("{kind}.{name}"), v));
    }
    let src = all
        .iter()
        .filter(|(_, k, _)| k == "dispatch.last_pass_epoch")
        .max_by(|a, b| a.2.total_cmp(&b.2))
        .map(|(h, _, _)| h.clone());
    let mut out = BTreeMap::new();
    for (h, k, v) in all {
        if src.as_ref().is_some_and(|s| *s != h) {
            continue;
        }
        let e = out.entry(k).or_insert(v);
        *e = (*e).max(v);
    }
    out
}

/// Each claude account with no room and its reasons (`a+b`), from the textfile's series.
fn accounts(series: &[Series]) -> Vec<(String, String)> {
    let mut by: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for s in series.iter().filter(|s| {
        s.label("__name__") == "claude_account_room_reason"
            && matches!(s.label("kind"), "" | "claude")
    }) {
        by.entry(s.label("account").to_string())
            .or_default()
            .insert(s.label("reason").to_string());
    }
    by.into_iter()
        .map(|(a, r)| (a, r.into_iter().collect::<Vec<_>>().join("+")))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bar::{BarItem, Ready};

    const NOW: i64 = 100_000;

    /// A healthy queue on h1 (39 ready, last pass 3m ago), with `kv` applied: `topic.key=value`,
    /// a `<host>:` prefix for another host, `dup:` for a second scrape of h1, `-` drops it, and
    /// `acct:<name>.<reason>` an account's room reason.
    fn feed(kv: &[&str]) -> Vec<Series> {
        let mut m: BTreeMap<String, f64> = [
            ("summary_dispatch.runnable", 39.0),
            ("summary_dispatch.runnable_urgent", 32.0),
            ("summary_dispatch.oldest_urgent_s", 46758.0),
            ("summary_dispatch.last_pass_epoch", (NOW - 180) as f64),
            ("summary_dispatch.room_max_live", 24.0),
            ("summary_dispatch.room_load", 27.4),
            ("summary_dispatch.room_load_cap", 36.0),
            ("runner_fleet_dispatch.failed", 0.0),
            ("runner_fleet_dispatch.blocked", 0.0),
            ("watch_queue_starved.tripped", 0.0),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        for a in kv {
            let (k, v) = a.split_once('=').unwrap();
            if v == "-" {
                m.remove(k);
            } else {
                m.insert(k.into(), v.parse().unwrap());
            }
        }
        m.into_iter()
            .map(|(k, v)| {
                let mut l = BTreeMap::new();
                if let Some(acct) = k.strip_prefix("acct:") {
                    let (name, reason) = acct.split_once('.').unwrap();
                    l.insert("__name__".into(), "claude_account_room_reason".into());
                    l.insert("account".into(), name.into());
                    l.insert("reason".into(), reason.into());
                    return Series {
                        labels: l,
                        value: Some(v),
                        points: vec![],
                    };
                }
                let (host, k) = match k.split_once(':') {
                    Some(("dup", k)) => ("h1", k),
                    Some((h, k)) => (h, k),
                    None => ("h1", k.as_str()),
                };
                let (topic, name) = k.split_once('.').unwrap();
                l.insert("__name__".into(), format!("mqtt_{name}"));
                l.insert("topic".into(), format!("agents_{host}_main_{topic}"));
                Series {
                    labels: l,
                    value: Some(v),
                    points: vec![],
                }
            })
            .collect()
    }

    fn judge(kv: &[&str]) -> Verdict {
        Verdict::from_series(&feed(kv), NOW)
    }

    fn texts(v: &Verdict, ready: &Ready) -> Vec<String> {
        v.lines(|| ready)
            .iter()
            .map(|l| {
                if l.act.is_empty() {
                    l.text.clone()
                } else {
                    format!("{} | {}", l.text, l.act)
                }
            })
            .collect()
    }

    fn ready(items: &[(&str, &str, i64)]) -> Ready {
        Ready {
            total: items.len(),
            urgent: 0,
            high: 0,
            items: items
                .iter()
                .map(|(p, t, m)| BarItem {
                    priority: p.to_string(),
                    kind: "fix".into(),
                    area: "waybar".into(),
                    title: t.to_string(),
                    ready_min: Some(*m),
                    ..BarItem::default()
                })
                .collect(),
        }
    }

    #[test]
    fn a_moving_queue_is_flowing_and_ok() {
        let v = judge(&[]);
        assert_eq!(v.level(), Level::Ok);
        assert_eq!(texts(&v, &Ready::default()), ["Flowing"]);
    }

    #[test]
    fn a_hold_heads_with_how_long_and_its_gate_said_once_with_the_urgent_item_waiting() {
        let v = judge(&[
            "summary_dispatch.held_s=7200",
            "summary_dispatch.room_held_load=1",
            "summary_dispatch.room_load_at_hold=37.6",
        ]);
        assert_eq!(v.level(), Level::Warn);
        assert_eq!(
            texts(&v, &ready(&[("high", "art", 5), ("urgent", "hovers", 20)])),
            [
                "Dispatch paused 2h00m: load 37.6 is over its cap of 36 | See the fleet-pace skill",
                "Urgent item waiting 20m: fix(waybar): hovers",
            ]
        );
    }

    #[test]
    fn a_load_hold_with_no_judged_load_on_the_feed_prints_no_live_reading_beside_it() {
        // 2026-11-23: "load 11 is over its cap of 25", the live reading beside a hold on 11 plus
        // the recent starts' load.
        let v = judge(&[
            "summary_dispatch.held_s=600",
            "summary_dispatch.room_held_load=1",
            "summary_dispatch.room_load_cap=25.2",
        ]);
        assert_eq!(
            texts(&v, &Ready::default())[0],
            "Dispatch paused 10m: load is over its cap of 25.2 | See the fleet-pace skill"
        );
    }

    #[test]
    fn a_hold_that_trips_queue_starved_is_one_red_line_and_names_a_high_item_with_no_urgent() {
        let v = judge(&[
            "summary_dispatch.held_s=600",
            "watch_queue_starved.tripped=1",
        ]);
        assert_eq!(v.level(), Level::Red);
        let l = v.lines(|| ready(&[("high", "art", 135)]));
        assert_eq!(l.len(), 2);
        assert_eq!(
            l[0].text,
            "Dispatch paused 10m: the last pass left ready work waiting"
        );
        assert_eq!(l[0].act, "Run fleet-dispatch run --dry-run");
        assert_eq!(
            (l[1].level, l[1].text.as_str()),
            (Level::Red, "High item waiting 2h15m: fix(waybar): art")
        );
    }

    #[test]
    fn with_no_ready_item_by_name_the_wait_is_the_feeds_oldest_urgent_age() {
        let v = judge(&["runner_fleet_dispatch.blocked=1"]);
        assert_eq!(
            texts(&v, &Ready::default()),
            [
                "The last pass started nothing | Run fleet-dispatch run --dry-run",
                "Urgent item waiting 12h59m",
            ]
        );
    }

    #[test]
    fn the_worst_exception_leads_and_the_rest_follow_in_raise_order() {
        let v = judge(&[
            "summary_dispatch.flapping_items=2",
            "summary_dispatch.could_start=3",
            "runner_fleet_dispatch.failed=1",
            "summary_shepherd.unhandled=1",
        ]);
        assert_eq!(
            texts(&v, &Ready::default()),
            [
                "The fleet-dispatch runner failed | Run agentctl logs fleet-dispatch",
                "2 item(s) flapping: a writer undoes reap's moves | Run agentctl logs fleet-dispatch",
                "3 more could start: a limit holds them, not the machine | Run fleet-dispatch headroom",
                "1 shepherd due line(s) unhandled | Use the shepherd skill, triage",
            ]
        );
    }

    #[test]
    fn a_late_or_missing_pass_is_red() {
        let late = judge(&[&format!(
            "summary_dispatch.last_pass_epoch={}",
            NOW - 3 * 3600
        )]);
        assert_eq!(late.exceptions[0].text, "No dispatch pass in 3h00m");
        assert_eq!(late.level(), Level::Red);
        let none = judge(&["summary_dispatch.last_pass_epoch=-"]);
        assert_eq!(none.exceptions[0].text, "No dispatch pass on record");
    }

    #[test]
    fn a_gate_with_work_still_flowing_is_an_amber_paused_line_and_names_each_account() {
        let v = judge(&[
            "summary_dispatch.room_held_account=1",
            "acct:work.weekly=1",
            "acct:work.five_hour=1",
            "acct:home.weekly=1",
        ]);
        assert_eq!(v.level(), Level::Ok);
        assert_eq!(
            texts(&v, &Ready::default()),
            [
                "Flowing",
                "Paused: no account has room",
                "home: no room, weekly",
                "work: no room, five_hour+weekly",
            ]
        );
    }

    #[test]
    fn no_dispatch_numbers_is_one_amber_line_with_the_publisher_to_check() {
        let v = judge(&["summary_dispatch.runnable=-"]);
        assert_eq!(
            texts(&v, &Ready::default()),
            ["No dispatch numbers on the feed | Run systemctl --user status agent-mqtt-publish.timer"]
        );
        assert_eq!(v.level(), Level::Warn);
    }

    #[test]
    fn prometheus_unread_is_one_amber_line_never_flowing() {
        let v = Verdict {
            error: Some("CC_PROM_URL is not set".into()),
            ..Verdict::default()
        };
        assert_eq!(v.level(), Level::Warn);
        assert_eq!(
            texts(&v, &Ready::default()),
            ["No flow verdict: CC_PROM_URL is not set"]
        );
    }

    #[test]
    fn the_host_whose_pass_ran_last_is_the_source_and_a_stale_hosts_series_are_dropped() {
        let v = judge(&[
            "h2:summary_dispatch.runnable=622",
            "h2:summary_dispatch.last_pass_epoch=1000",
            "h2:runner_fleet_dispatch.failed=1",
            "h2:summary_dispatch.flapping_items=4",
            "dup:summary_dispatch.runnable=39",
        ]);
        assert_eq!(v.get("dispatch.runnable"), Some(39));
        assert_eq!(v.level(), Level::Ok, "{:?}", v.exceptions);
        // Negative control: the newer pass wins even with the smaller queue.
        let w = judge(&[
            "h2:summary_dispatch.runnable=5",
            &format!("h2:summary_dispatch.last_pass_epoch={}", NOW - 10),
        ]);
        assert_eq!(w.get("dispatch.runnable"), Some(5));
        assert_eq!(w.get("dispatch.room_max_live"), None);
    }

    #[test]
    fn with_no_pass_on_record_anywhere_every_host_counts_by_the_max() {
        let v = judge(&[
            "summary_dispatch.last_pass_epoch=-",
            "h2:summary_dispatch.runnable=50",
        ]);
        assert_eq!(v.get("dispatch.runnable"), Some(50));
        assert_eq!(v.exceptions[0].text, "No dispatch pass on record");
    }

    #[test]
    fn the_query_reads_the_four_topics_and_fresh_account_reasons() {
        let q = query();
        for t in [
            "summary_dispatch",
            "runner_fleet_dispatch",
            "watch_queue_starved",
            "summary_shepherd",
            "cc:agents_topic_live",
            "claude_account_room_reason",
            "< 2700",
        ] {
            assert!(q.contains(t), "{t} not in {q}");
        }
    }

    #[test]
    fn worst_first_keeps_red_over_amber_over_the_rest_and_cuts_to_n() {
        let l = |level, t: &str| Line::plain(level, t.into());
        let got = worst_first(
            vec![
                l(Level::Nodata, "a: no room"),
                l(Level::Warn, "paused"),
                l(Level::Red, "failed"),
                l(Level::Warn, "held"),
            ],
            3,
        );
        let said: Vec<&str> = got.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(said, ["failed", "paused", "held"]);
        // NEGATIVE CONTROL: fewer lines than n are all kept, a lone line stays.
        assert_eq!(worst_first(vec![l(Level::Ok, "Flowing")], 3).len(), 1);
    }
}
