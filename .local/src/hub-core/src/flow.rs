//! The flow strip: where work sits between a captured thought and a landed PR, as one row of
//! chips (`inbox | board | queued (ready) | running | needs you | done 24h | drain`). Home leads
//! with it on both surfaces and the Queue tab shows the same one, from this one builder, so the
//! hub TUI and agent-web cannot word or count it differently.
//!
//! Where each number comes from: the queue's own chips (queued, running, needs you) are the live
//! queue, the same count the table under a chip shows (done 24h is agent-queue's rolling count,
//! and its chip opens the Queue's done chip, which lists today's finished items); inbox and board are fleet-bench's
//! `agent_chain_*` gauges (`pipeline`), the only owner of those two; done 24h and the drain are
//! agent-queue's `stats.recent`. A number its source did not give reads `-`, never 0. A step
//! past its age bound is the one amber chip (`hot`).

use serde::Serialize;

use crate::pipeline::Pipeline;
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
    /// The number as worded (`83 (27 ready)`, `6h +41/-52 shrinking`); None reads `-`.
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
    /// When fleet-bench last wrote the gauges the inbox and board chips read.
    pub as_of: Option<String>,
    /// Why the gauges could not be read, if they could not.
    pub error: Option<String>,
    /// The read answered but fleet-bench has written no gauges, so inbox and board are `-`.
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
        let n = |s: State| queue.map(|q| q.count(s));
        let recent = queue
            .and_then(|q| q.stats.as_ref())
            .and_then(|s| s.recent.as_ref());
        let ready = queue
            .and_then(|q| q.stats.as_ref())
            .and_then(|s| s.sitting.as_ref())
            .map(|s| s.runnable);
        let queued = n(State::Queued).map(|c| match ready {
            Some(r) => format!("{c} ({r} ready)"),
            None => c.to_string(),
        });
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
                chip("queued", "queued", queued, queue_to("up next")),
                chip(
                    "running",
                    "running",
                    n(State::Running).map(|c| c.to_string()),
                    queue_to("running"),
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

    /// The gauges' read: the inbox and board counts, the one amber step, the bottleneck line and
    /// the stamp. Absent gauges or a failed read leave those chips `-`; the failure is kept.
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
        let wip = |step: &str| {
            p.wip
                .iter()
                .find(|(s, _)| s == step)
                .and_then(|(_, n)| *n)
                .map(|n| n.to_string())
        };
        for c in &mut self.chips {
            match c.key {
                "inbox" => c.value = wip("inbox"),
                "board" => c.value = wip("backlog"),
                _ => {}
            }
        }
        // The gauges name the board `backlog` and the human's turn `waiting`.
        let hot = p.bottleneck.as_ref().map(|b| match b.step.as_str() {
            "backlog" => "board",
            "waiting" => "needs",
            s => s,
        });
        for c in &mut self.chips {
            c.hot = hot == Some(c.key);
        }
        self.bottleneck = p.bottleneck_text();
        self.as_of = p.as_of_label();
    }

    /// `inbox 4 | board 312 | queued 83 (27 ready) | ...`, the plain words of the chips.
    pub fn line(&self) -> String {
        self.chips
            .iter()
            .map(Chip::text)
            .collect::<Vec<_>>()
            .join(" | ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::from_series;
    use crate::prom::Series;
    use crate::queue::{Item, Sitting, Stats};

    fn s(step: &str, v: f64) -> Series {
        Series {
            labels: [("step".to_string(), step.to_string())].into(),
            value: Some(v),
            points: vec![],
        }
    }

    fn pipe(ratio: f64) -> Pipeline {
        let wip = [("inbox", 4.0), ("backlog", 312.0), ("queued", 3.0)].map(|(k, v)| s(k, v));
        from_series(&wip, &[s("waiting", 540.0)], &[s("waiting", ratio)]).unwrap()
    }

    fn queue() -> Queue {
        let item = |slug: &str, state| Item {
            slug: slug.into(),
            state,
            ..Item::default()
        };
        Queue {
            items: vec![
                item("a", State::Running),
                item("b", State::Queued),
                item("c", State::Queued),
                item("d", State::Waiting),
            ],
            stats: Some(Stats {
                sitting: Some(Sitting {
                    runnable: 1,
                    ..Sitting::default()
                }),
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
            "inbox 4 | board 312 | queued 2 (1 ready) | running 1 | needs you 1 | done 24h 280 | drain 6h +41/-52 shrinking"
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
                Some(("queue", "up next")),
                Some(("queue", "running")),
                Some(("queue", "needs you")),
                Some(("queue", "done")),
                Some(("queue", "")),
            ]
        );
        assert!(st.chips.iter().all(|c| !c.hot) && st.bottleneck.is_none());
    }

    #[test]
    fn only_the_step_past_its_bound_is_hot_and_the_gauges_name_it() {
        let mut st = Strip::build(Some(&queue()));
        st.set_pipeline(&Ok(Some(pipe(2.25))));
        let hot: Vec<_> = st.chips.iter().filter(|c| c.hot).map(|c| c.key).collect();
        assert_eq!(
            hot,
            ["needs"],
            "the gauge's `waiting` is the needs-you chip"
        );
        assert_eq!(
            st.bottleneck.as_deref(),
            Some("bottleneck: waiting, age p90 9h (bound 4h)")
        );
    }

    #[test]
    fn negative_control_nothing_read_is_dash_never_zero() {
        let mut st = Strip::build(None);
        assert_eq!(
            st.line(),
            "inbox - | board - | queued - | running - | needs you - | done 24h - | drain -"
        );
        // Gauges absent: the queue's chips stand and inbox and board stay `-`.
        let mut q = Strip::build(Some(&queue()));
        q.set_pipeline(&Ok(None));
        assert!(q.absent);
        assert!(q
            .line()
            .starts_with("inbox - | board - | queued 2 (1 ready)"));
        // A failed read is kept for the surface to show, and is not a zero.
        st.set_pipeline(&Err("no prom".into()));
        assert_eq!(st.error.as_deref(), Some("no prom"));
        assert!(st.chips.iter().all(|c| c.value.is_none() && !c.hot));
        // An agent-queue with no `recent` or `sitting` says so with `-`, and a bare count.
        let mut old = queue();
        old.stats = Some(Stats::default());
        let l = Strip::build(Some(&old)).line();
        assert!(
            l.contains("queued 2 |") && l.ends_with("done 24h - | drain -"),
            "{l}"
        );
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
