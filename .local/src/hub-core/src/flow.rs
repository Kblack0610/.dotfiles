//! The flow strip: where work sits between a captured thought and a landed PR, as one row of
//! chips (`inbox | board | up next | running | on a PR | needs you | done 24h | drain`). Home leads
//! with it on both surfaces and the Queue tab shows the same one, from this one builder, so the
//! hub TUI and agent-web cannot word or count it differently.
//!
//! Where each number comes from: the queue's own chips (up next, running, on a PR, needs you) are the live
//! queue, the same count the table under a chip shows (done 24h is agent-queue's rolling count,
//! and its chip opens the Queue's done chip, which lists today's finished items); inbox and board are fleet-bench's
//! snapshot (`pipeline`), the only owner of those two; done 24h and the drain are
//! agent-queue's `stats.recent`. A number its source did not give reads `-`, never 0. A step
//! past its age bound is the one amber chip (`hot`).
//!
//! The Queue tab leads with the same chips as a `Rail`: one point per step with that step's age,
//! why it is stuck and what went wrong there, from this one builder for both surfaces.

use serde::Serialize;

use crate::pipeline::{Pipeline, Problem, Step};
use crate::queue::{Queue, Recent, State};

/// The tab a chip opens and, for the Queue, the state chip it filters to (`""` for none).
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Target {
    pub tab: &'static str,
    pub state: &'static str,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Chip {
    pub key: &'static str,
    pub label: &'static str,
    /// The number as worded (`27 ready, 56 held`, `6h +41/-52 shrinking`); None reads `-`.
    pub value: Option<String>,
    /// The step is past its age bound.
    pub hot: bool,
    /// Where a click goes; None for a count with no view of its own.
    pub to: Option<Target>,
}

impl Chip {
    pub fn text(&self) -> String {
        format!("{} {}", self.label, self.value.as_deref().unwrap_or("-"))
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Strip {
    pub chips: Vec<Chip>,
    /// `bottleneck: waiting, age p90 9h (bound 4h)`, when a step is past its bound.
    pub bottleneck: Option<String>,
    /// When fleet-bench last wrote the snapshot the inbox and board chips read.
    pub as_of: Option<String>,
    /// Why the snapshot could not be read, if it could not.
    pub error: Option<String>,
    /// The read answered but fleet-bench has written no snapshot, so inbox and board are `-`.
    pub absent: bool,
}

const QUEUE: &str = "queue";

fn chip(key: &'static str, label: &'static str, value: Option<String>, to: Option<Target>) -> Chip {
    Chip {
        key,
        label,
        value,
        hot: false,
        to,
    }
}

fn queue_to(state: &'static str) -> Option<Target> {
    Some(Target { tab: QUEUE, state })
}

/// Added against finished over the last 6 hours, and whether the queue shrinks or grows. This is
/// the waybar chip's drain rule (`.config/waybar/dispatch.sh`), which keeps its copy until that
/// chip moves here.
pub fn drain(r: &Recent) -> String {
    let verdict = match r.added_6h.cmp(&r.done_6h) {
        std::cmp::Ordering::Less => "shrinking",
        std::cmp::Ordering::Greater => "growing",
        std::cmp::Ordering::Equal => "steady",
    };
    format!("6h +{}/-{} {verdict}", r.added_6h, r.done_6h)
}

impl Strip {
    /// The strip from the queue; inbox and board wait for `set_pipeline`. With no queue read the
    /// queue chips read `-`.
    pub fn build(queue: Option<&Queue>) -> Strip {
        let n = |s: State| queue.filter(|q| q.list_read()).map(|q| q.count(s));
        let recent = queue
            .and_then(|q| q.stats.as_ref())
            .and_then(|s| s.recent.as_ref());
        // Not started is said as its two states (`vocab::QUEUE`), never as "queued".
        let up_next = queue
            .filter(|q| q.list_read())
            .map(Queue::up_next)
            .map(|(r, h)| format!("{r} ready, {h} held"));
        Strip {
            chips: vec![
                chip("inbox", "inbox", None, None),
                chip(
                    "board",
                    "board",
                    None,
                    Some(Target {
                        tab: "board",
                        state: "",
                    }),
                ),
                chip("queued", "up next", up_next, queue_to("ready")),
                chip(
                    "running",
                    "running",
                    n(State::Running).map(|c| c.to_string()),
                    queue_to("running"),
                ),
                chip(
                    "review",
                    "on a PR",
                    n(State::Review).map(|c| c.to_string()),
                    queue_to("on a PR"),
                ),
                chip(
                    "needs",
                    "needs you",
                    n(State::Waiting).map(|c| c.to_string()),
                    queue_to("needs you"),
                ),
                chip(
                    "done",
                    "done 24h",
                    recent.map(|r| r.done_24h.to_string()),
                    queue_to("done"),
                ),
                chip("drain", "drain", recent.map(drain), queue_to("")),
            ],
            ..Strip::default()
        }
    }

    /// The snapshot's read: the inbox and board counts, the one amber step, the bottleneck line
    /// and the stamp. No snapshot or a failed read leaves those chips `-`; the failure is kept.
    pub fn set_pipeline(&mut self, read: &Result<Option<Pipeline>, String>) {
        let p = match read {
            Ok(Some(p)) => p,
            Ok(None) => {
                self.absent = true;
                return;
            }
            Err(e) => {
                self.error = Some(e.clone());
                return;
            }
        };
        let wip = |step: &str| p.step(step).and_then(|s| s.wip).map(|n| n.to_string());
        for c in &mut self.chips {
            match c.key {
                "inbox" => c.value = wip("inbox"),
                "board" => c.value = wip("backlog"),
                _ => {}
            }
        }
        let hot = p.bottleneck.as_ref().map(|b| chip_key(&b.step));
        for c in &mut self.chips {
            c.hot = hot == Some(c.key);
        }
        // The step in the strip's own words: the record's `queued` is the up next chip.
        let chips = &self.chips;
        self.bottleneck = p.bottleneck_text(|step| {
            let key = chip_key(step);
            chips
                .iter()
                .find(|c| c.key == key)
                .map_or(step.to_string(), |c| c.label.to_string())
        });
        self.as_of = p.as_of_label();
    }

    /// `inbox 4 | board 312 | up next 27 ready, 56 held | ...`, the plain words of the chips.
    pub fn line(&self) -> String {
        self.chips
            .iter()
            .map(Chip::text)
            .collect::<Vec<_>>()
            .join(" | ")
    }
}

/// The record names the board `backlog`, the human's turn `waiting` and a parked PR `review`.
fn chip_key(step: &str) -> &str {
    match step {
        "backlog" => "board",
        "waiting" => "needs",
        s => s,
    }
}

fn step_of<'a>(p: Option<&'a Pipeline>, key: &str) -> Option<&'a Step> {
    p?.steps.iter().find(|s| chip_key(&s.step) == key)
}

/// How old the snapshot may be before the line says so: three missed 10-minute ticks.
const STALE_SECS: i64 = 30 * 60;

/// Past this an age reads in days: `2.8d` says more than `67h`.
const DAYS_FROM_MIN: f64 = 48.0 * 60.0;

fn age(m: f64) -> String {
    if m >= DAYS_FROM_MIN {
        format!("{:.1}d", m / (24.0 * 60.0))
    } else {
        crate::queue::dur(Some(m.round() as i64))
    }
}

/// One thing that went wrong at a step, worded once for both surfaces.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Trouble {
    /// `01:16  ucp-412  failed  session ended before it closed the item`.
    pub text: String,
    /// The Queue item it opens; None for an inbox line, which has no item.
    pub item: Option<String>,
}

impl From<&Problem> for Trouble {
    fn from(p: &Problem) -> Trouble {
        let time = p.ts.get(11..16).unwrap_or("-");
        let times = if p.n > 1 {
            format!(" {}x", p.n)
        } else {
            String::new()
        };
        let why = if p.why.is_empty() {
            "no cause recorded"
        } else {
            &p.why
        };
        Trouble {
            text: format!("{time}  {}  {}{times}  {why}", p.subject, p.kind),
            // A land failure before its item was known names the PR, which no Queue row can open.
            item: (matches!(p.kind.as_str(), "failed" | "reaped" | "land failed")
                && !p.subject.contains('#'))
            .then(|| p.subject.clone()),
        }
    }
}

/// One point on the line.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Node {
    pub key: &'static str,
    pub label: &'static str,
    /// The live count; None reads `-`.
    pub count: Option<String>,
    /// `p90 2.8d`, `ok` for an empty step, `24h` on done.
    pub sub: String,
    /// Past its age bound: amber.
    pub hot: bool,
    /// Nothing can leave it right now: red.
    pub stopped: bool,
    pub to: Option<Target>,
    /// Why nothing can leave it.
    pub stop: Option<String>,
    /// The detail lines: counts against the bound, then the drain on up next.
    pub facts: Vec<String>,
    pub problems_n: usize,
    /// The newest problems, newest first.
    pub problems: Vec<Trouble>,
    /// The step with the most problems, when it is another one.
    pub elsewhere: Option<String>,
}

/// The line: every step but the drain, which rides in up next's detail.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Rail {
    pub nodes: Vec<Node>,
    /// The node that starts open: one that is stopped, else the furthest past its bound, else
    /// the one with the most problems.
    pub worst: usize,
    pub as_of: Option<String>,
    /// The snapshot is past `STALE_SECS` old, or says nothing of its age.
    pub stale: bool,
    /// The snapshot has not been read yet.
    pub reading: bool,
    pub error: Option<String>,
    pub absent: bool,
}

/// `up` is the queue's `(ready, held)`: up next's node counts its items, and its chip's split is
/// the first fact.
fn node(c: &Chip, s: Option<&Step>, drain: Option<&str>, up: Option<(usize, usize)>) -> Node {
    let (count, split) = match (c.key, up) {
        ("queued", Some((r, h))) => (Some((r + h).to_string()), c.value.as_deref()),
        _ => (c.value.clone(), None),
    };
    let sub = match (c.key, s.and_then(|s| s.age_p90_min), s.and_then(|s| s.wip)) {
        ("done", ..) => "24h".to_string(),
        (_, Some(a), _) => format!("p90 {}", age(a)),
        (_, None, Some(0)) => "ok".to_string(),
        _ => "-".to_string(),
    };
    let ratio = s.and_then(|s| s.ratio);
    let mut line: Vec<String> = vec![];
    if c.key != "done" {
        line.extend(count.as_ref().map(|n| format!("{n} items")));
    }
    line.extend(split.map(str::to_string));
    if let Some(s) = s {
        line.extend(s.oldest_min.map(|m| format!("oldest {}", age(m))));
        if let (Some(b), Some(r)) = (s.bound, ratio) {
            line.push(format!("bound {} ({r:.1}x)", age(b)));
        }
        if let (Some(i), Some(o)) = (s.in_24h, s.out_24h) {
            line.push(format!("24h +{i}/-{o}"));
        }
    }
    let mut facts = vec![];
    if !line.is_empty() {
        facts.push(line.join(", "));
    }
    if c.key == "queued" {
        facts.extend(drain.map(|d| format!("drain {d}")));
    }
    let stop = s.and_then(|s| s.blocked.clone());
    Node {
        key: c.key,
        label: c.label,
        count,
        sub,
        hot: ratio.is_some_and(|r| r > 1.0),
        stopped: stop.is_some(),
        to: c.to,
        stop,
        facts,
        problems_n: s.and_then(|s| s.problems_n).unwrap_or(0),
        problems: s.map_or(vec![], |s| s.problems.iter().map(Trouble::from).collect()),
        elsewhere: None,
    }
}

/// Why the items in `state` sit there, most common first. None when none does.
fn why(queue: &Queue, state: State, head: &str) -> Option<String> {
    let mut by = std::collections::BTreeMap::new();
    for i in queue.in_state(state) {
        *by.entry(i.waits_on()).or_insert(0_usize) += 1;
    }
    let mut by: Vec<_> = by.into_iter().collect();
    by.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    let parts: Vec<String> = by.iter().map(|(why, n)| format!("{n} {why}")).collect();
    (!parts.is_empty()).then(|| format!("{head}: {}", parts.join(", ")))
}

fn worst_of(nodes: &[Node], p: Option<&Pipeline>) -> usize {
    let ratio = |n: &Node| step_of(p, n.key).and_then(|s| s.ratio).unwrap_or(0.0);
    let at = nodes.iter().position(|n| n.stopped).or_else(|| {
        let past = nodes.iter().enumerate().filter(|(_, n)| n.hot);
        past.max_by(|a, b| ratio(a.1).total_cmp(&ratio(b.1)))
            .map(|(i, _)| i)
    });
    at.or_else(|| {
        let some = nodes.iter().enumerate().filter(|(_, n)| n.problems_n > 0);
        some.max_by_key(|(_, n)| n.problems_n).map(|(i, _)| i)
    })
    .unwrap_or(0)
}

impl Rail {
    /// The line from the live queue and the snapshot's read; `read` is None until it answers.
    pub fn build(
        queue: Option<&Queue>,
        read: Option<&Result<Option<Pipeline>, String>>,
        now: i64,
    ) -> Rail {
        let mut strip = Strip::build(queue);
        if let Some(r) = read {
            strip.set_pipeline(r);
        }
        let p = read.and_then(|r| r.as_ref().ok()).and_then(|o| o.as_ref());
        let drain = strip.chips.iter().find(|c| c.key == "drain");
        let drain = drain.and_then(|c| c.value.as_deref());
        let up = queue.filter(|q| q.list_read()).map(Queue::up_next);
        let mut nodes: Vec<Node> = strip
            .chips
            .iter()
            .filter(|c| c.key != "drain")
            .map(|c| node(c, step_of(p, c.key), drain, up))
            .collect();
        if let Some(q) = queue.filter(|q| q.list_read()) {
            for n in nodes.iter_mut() {
                match n.key {
                    "needs" => n.facts.extend(why(q, State::Waiting, "Why waiting")),
                    "review" => n.facts.extend(why(q, State::Review, "Why on a PR")),
                    _ => {}
                }
            }
        }
        let most = nodes
            .iter()
            .filter(|n| n.problems_n > 0)
            .max_by_key(|n| n.problems_n)
            .map(|n| (n.key, n.label, n.problems_n));
        if let Some((key, label, n)) = most {
            for o in nodes.iter_mut().filter(|o| o.key != key) {
                o.elsewhere = Some(format!("Problems at {label}, 24h: {n}"));
            }
        }
        Rail {
            worst: worst_of(&nodes, p),
            nodes,
            as_of: strip.as_of,
            stale: p.is_some_and(|p| p.as_of.is_none_or(|t| now - t > STALE_SECS)),
            reading: read.is_none(),
            error: strip.error,
            absent: strip.absent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::tests::snapshot;
    use crate::queue::{Item, Stats, LIST_FAILED};

    fn pipe(ratio: f64) -> Pipeline {
        snapshot(&[
            ("inbox", 4, 1.0, 0.1),
            ("backlog", 312, 1.0, 0.1),
            ("queued", 3, 1.0, 0.1),
            ("waiting", 2, 540.0, ratio),
        ])
    }

    fn queue() -> Queue {
        let item = |slug: &str, state| Item {
            slug: slug.into(),
            state,
            ..Item::default()
        };
        let held = Item {
            hold: Some("after b".into()),
            ..item("c", State::Queued)
        };
        Queue {
            items: vec![
                item("a", State::Running),
                item("b", State::Queued),
                held,
                item("d", State::Waiting),
                item("e", State::Review),
            ],
            stats: Some(Stats {
                recent: Some(Recent {
                    added_6h: 41,
                    done_6h: 52,
                    done_24h: 280,
                    ..Recent::default()
                }),
                ..Stats::default()
            }),
            ..Queue::default()
        }
    }

    #[test]
    fn the_strip_is_the_mockup_and_each_chip_opens_its_view() {
        let mut st = Strip::build(Some(&queue()));
        st.set_pipeline(&Ok(Some(pipe(0.5))));
        assert_eq!(
            st.line(),
            "inbox 4 | board 312 | up next 1 ready, 1 held | running 1 | on a PR 1 | needs you 1 | done 24h 280 | drain 6h +41/-52 shrinking"
        );
        let to: Vec<_> = st
            .chips
            .iter()
            .map(|c| c.to.map(|t| (t.tab, t.state)))
            .collect();
        assert_eq!(
            to,
            vec![
                None,
                Some(("board", "")),
                Some(("queue", "ready")),
                Some(("queue", "running")),
                Some(("queue", "on a PR")),
                Some(("queue", "needs you")),
                Some(("queue", "done")),
                Some(("queue", "")),
            ]
        );
        assert!(st.chips.iter().all(|c| !c.hot) && st.bottleneck.is_none());
    }

    #[test]
    fn only_the_step_past_its_bound_is_hot_and_the_snapshot_names_it() {
        let mut st = Strip::build(Some(&queue()));
        st.set_pipeline(&Ok(Some(pipe(2.25))));
        let hot: Vec<_> = st.chips.iter().filter(|c| c.hot).map(|c| c.key).collect();
        assert_eq!(
            hot,
            ["needs"],
            "the record's `waiting` is the needs-you chip"
        );
        assert_eq!(
            st.bottleneck.as_deref(),
            Some("bottleneck: needs you, age p90 9h (bound 4h)"),
            "the record's step is named as its chip"
        );
    }

    #[test]
    fn negative_control_nothing_read_is_dash_never_zero() {
        let mut st = Strip::build(None);
        assert_eq!(
            st.line(),
            "inbox - | board - | up next - | running - | on a PR - | needs you - | done 24h - | drain -"
        );
        // No snapshot: the queue's chips stand and inbox and board stay `-`.
        let mut q = Strip::build(Some(&queue()));
        q.set_pipeline(&Ok(None));
        assert!(q.absent);
        assert!(q
            .line()
            .starts_with("inbox - | board - | up next 1 ready, 1 held"));
        // A failed read is kept for the surface to show, and is not a zero.
        st.set_pipeline(&Err("no prom".into()));
        assert_eq!(st.error.as_deref(), Some("no prom"));
        assert!(st.chips.iter().all(|c| c.value.is_none() && !c.hot));
        // An agent-queue with no `recent` says so with `-`; up next counts the list itself.
        let mut old = queue();
        old.stats = Some(Stats::default());
        let l = Strip::build(Some(&old)).line();
        assert!(
            l.contains("up next 1 ready, 1 held |") && l.ends_with("done 24h - | drain -"),
            "{l}"
        );
        assert!(!l.contains("queued"), "the strip never says queued: {l}");
    }

    fn stuck() -> Pipeline {
        let mut p = pipe(2.25);
        let q = p.steps.iter_mut().find(|s| s.step == "queued").unwrap();
        (q.blocked, q.oldest_min, q.in_24h, q.out_24h) = (
            Some("Dispatch stopped".into()),
            Some(5472.0),
            Some(110),
            Some(220),
        );
        (q.age_p90_min, q.bound, q.ratio) = (Some(4080.0), Some(720.0), Some(5.67));
        let i = p.steps.iter_mut().find(|s| s.step == "inbox").unwrap();
        i.problems_n = Some(3);
        for (n, why, kind) in [(1, "", "failed"), (4, "no project", "refused")] {
            i.problems.push(Problem {
                ts: "2026-11-09T01:16:00-08:00".into(),
                subject: "ucp-412".into(),
                kind: kind.into(),
                why: why.into(),
                n,
            });
        }
        p
    }

    fn node_at<'a>(r: &'a Rail, key: &str) -> &'a Node {
        r.nodes.iter().find(|n| n.key == key).unwrap()
    }

    #[test]
    fn the_rail_is_the_mockup_a_point_per_step_with_the_drain_folded_into_queued() {
        let now = 1_794_010_893;
        let mut p = stuck();
        p.as_of = Some(now - 60);
        let r = Rail::build(Some(&queue()), Some(&Ok(Some(p))), now);
        let keys: Vec<_> = r.nodes.iter().map(|n| n.key).collect();
        assert_eq!(
            keys,
            ["inbox", "board", "queued", "running", "review", "needs", "done"]
        );
        let q = node_at(&r, "queued");
        assert_eq!(
            (q.count.as_deref(), q.sub.as_str()),
            (Some("2"), "p90 2.8d")
        );
        assert_eq!(q.stop.as_deref(), Some("Dispatch stopped"));
        assert_eq!(
            q.facts,
            [
                "2 items, 1 ready, 1 held, oldest 3.8d, bound 12h (5.7x), 24h +110/-220",
                "drain 6h +41/-52 shrinking"
            ]
        );
        assert_eq!(keys[r.worst], "queued", "a stopped step starts open");
        assert_eq!(q.label, "up next");
        assert!(!r.stale);
        assert_eq!(node_at(&r, "done").sub, "24h");
        assert_eq!(node_at(&r, "done").count.as_deref(), Some("280"));
    }

    #[test]
    fn a_problem_says_when_what_and_why_and_only_an_item_opens() {
        let r = Rail::build(Some(&queue()), Some(&Ok(Some(stuck()))), 0);
        let i = node_at(&r, "inbox");
        assert_eq!(i.problems_n, 3);
        assert_eq!(
            i.problems[0].text,
            "01:16  ucp-412  failed  no cause recorded"
        );
        assert_eq!(i.problems[0].item.as_deref(), Some("ucp-412"));
        assert_eq!(i.problems[1].text, "01:16  ucp-412  refused 4x  no project");
        assert_eq!(i.problems[1].item, None);
        assert_eq!(i.elsewhere, None);
        assert_eq!(
            node_at(&r, "running").elsewhere.as_deref(),
            Some("Problems at inbox, 24h: 3")
        );
    }

    #[test]
    fn amber_is_past_the_bound_and_red_is_stopped_and_a_problem_alone_is_neither() {
        let r = Rail::build(Some(&queue()), Some(&Ok(Some(stuck()))), 0);
        let (q, n, i) = (
            node_at(&r, "queued"),
            node_at(&r, "needs"),
            node_at(&r, "inbox"),
        );
        assert!(q.stopped && q.hot && n.hot && !n.stopped);
        assert!(!i.hot && !i.stopped && i.problems_n > 0);
        let calm = Rail::build(Some(&queue()), Some(&Ok(Some(pipe(0.5)))), 0);
        assert_eq!(calm.worst, 0, "nothing wrong opens the first step");
    }

    #[test]
    fn negative_control_a_stale_absent_or_broken_snapshot_says_so_and_never_zero() {
        let now = 1_794_010_893;
        let mut p = pipe(0.5);
        p.as_of = Some(now - STALE_SECS - 1);
        assert!(Rail::build(None, Some(&Ok(Some(p.clone()))), now).stale);
        p.as_of = None;
        assert!(Rail::build(None, Some(&Ok(Some(p))), now).stale);
        let bad = Rail::build(Some(&queue()), Some(&Err("broken".into())), now);
        assert_eq!(bad.error.as_deref(), Some("broken"));
        assert_eq!(node_at(&bad, "inbox").count, None);
        assert_eq!(node_at(&bad, "queued").count.as_deref(), Some("2"));
        assert!(Rail::build(None, Some(&Ok(None)), now).absent);
        assert!(Rail::build(None, None, now).reading);
    }

    #[test]
    fn needs_you_counts_the_humans_turn_and_a_parked_pr_is_on_a_pr() {
        let item = |slug: &str, state, set: fn(&mut Item)| {
            let mut i = Item {
                slug: slug.into(),
                state,
                ..Item::default()
            };
            set(&mut i);
            i
        };
        let q = Queue {
            items: vec![
                item("a", State::Review, |i| i.pr = Some("o/r#1".into())),
                item("b", State::Review, |i| i.pr = Some("o/r#2".into())),
                item("c", State::Review, |i| {
                    i.pr = Some("o/r#3".into());
                    i.partial = Some("yes".into());
                }),
                item("d", State::Waiting, |_| {}),
                item("e", State::Waiting, |i| {
                    i.pr = Some("o/r#4".into());
                    i.extra.insert("ask".into(), "at-9".into());
                }),
            ],
            ..Queue::default()
        };
        let r = Rail::build(Some(&q), None, 0);
        let needs = node_at(&r, "needs");
        assert_eq!(needs.count.as_deref(), Some("2"), "only the human's turn");
        assert_eq!(
            needs.facts.last().map(String::as_str),
            Some("Why waiting: 1 on an ask or report, 1 on its session's question")
        );
        let review = node_at(&r, "review");
        assert_eq!(review.count.as_deref(), Some("3"));
        assert_eq!(
            review.facts.last().map(String::as_str),
            Some("Why on a PR: 2 on its merge, 1 on a final landing")
        );
    }

    #[test]
    fn a_queue_that_could_not_be_listed_reads_dash_never_zero() {
        let q = Queue {
            errors: vec![format!("{LIST_FAILED}: boom")],
            ..Queue::default()
        };
        let r = Rail::build(Some(&q), None, 0);
        for key in ["queued", "running", "review", "needs"] {
            assert_eq!(node_at(&r, key).count, None, "{key}");
        }
        assert!(!node_at(&r, "needs")
            .facts
            .iter()
            .any(|f| f.starts_with("Why waiting")));
        // The control: the same empty queue, read, is a real zero.
        let read = Rail::build(Some(&Queue::default()), None, 0);
        assert_eq!(node_at(&read, "needs").count.as_deref(), Some("0"));
    }

    #[test]
    fn a_land_failure_opens_its_item_unless_it_only_knows_the_pr() {
        let p = |subject: &str| Problem {
            ts: "2026-11-09T10:00:00Z".into(),
            subject: subject.into(),
            kind: "land failed".into(),
            why: "checks: Checks".into(),
            n: 1,
        };
        assert_eq!(Trouble::from(&p("ship")).item.as_deref(), Some("ship"));
        assert_eq!(Trouble::from(&p("o/r#42")).item, None);
    }

    #[test]
    fn drain_is_added_against_finished_over_six_hours() {
        let r = |a, d| Recent {
            added_6h: a,
            done_6h: d,
            ..Recent::default()
        };
        assert_eq!(drain(&r(41, 52)), "6h +41/-52 shrinking");
        assert_eq!(drain(&r(60, 10)), "6h +60/-10 growing");
        assert_eq!(drain(&r(5, 5)), "6h +5/-5 steady");
    }
}
