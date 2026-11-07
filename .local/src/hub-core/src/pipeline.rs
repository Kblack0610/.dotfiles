//! The pipeline summary line: where items sit between a captured thought and a landed PR,
//! from fleet-bench's `agent_chain_*` gauges. The Queue tab of the hub TUI and of agent-web
//! word it from this one reader, so they cannot disagree. Counts are the gauges' own; when the
//! gauges are absent the line says so (`pipeline -`) and never shows a zero it did not read.

use serde::Serialize;

use chrono::{Local, TimeZone};

use crate::capacity::clock;
use crate::prom::{self, Series, W};

/// The steps the line shows, in pipeline order. `done` (finished in 24h) is left off by design.
pub const STEPS: [&str; 5] = ["inbox", "backlog", "queued", "running", "waiting"];

/// What the line says when nothing could be read.
pub const NONE: &str = "pipeline -";

/// The columns the second line is indented under (the width of `pipeline  `).
const INDENT: &str = "          ";

/// A step past its age bound.
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Bottleneck {
    pub step: String,
    /// The step's age p90 in minutes, when the gauge has it.
    pub age_p90_min: Option<f64>,
    /// age_p90 / ratio: the bound the ratio was taken against.
    pub bound_min: Option<f64>,
    pub ratio: f64,
}

#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Pipeline {
    /// WIP for each of `STEPS`, None for a step the gauge has no series for.
    pub wip: Vec<(String, Option<u64>)>,
    /// The step with the largest age ratio above 1, if any.
    pub bottleneck: Option<Bottleneck>,
    /// When fleet-bench last wrote the gauges (unix seconds). They lag the live queue by up to
    /// one sample, so the line says when they were read; None when the file's age is unknown.
    pub as_of: Option<i64>,
}

fn by_step<'a>(s: &'a [Series], step: &str) -> Option<&'a Series> {
    s.iter()
        .find(|x| x.label("step") == step && x.value.is_some())
}

/// The summary from the three instant answers (wip, age p90, age ratio). None when there is no
/// wip series at all: the gauges are not exported, which is not the same as an empty pipeline.
pub fn from_series(wip: &[Series], p90: &[Series], ratio: &[Series]) -> Option<Pipeline> {
    if !wip.iter().any(|s| s.value.is_some()) {
        return None;
    }
    let wip_by = STEPS
        .iter()
        .map(|st| {
            let n = by_step(wip, st)
                .and_then(|s| s.value)
                .map(|v| v.max(0.0).round() as u64);
            (st.to_string(), n)
        })
        .collect();
    let bottleneck = ratio
        .iter()
        .filter_map(|s| Some((s.label("step"), s.value.filter(|r| *r > 1.0)?)))
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(step, r)| {
            let age = by_step(p90, step).and_then(|s| s.value);
            Bottleneck {
                step: step.to_string(),
                age_p90_min: age,
                bound_min: age.map(|a| a / r),
                ratio: r,
            }
        });
    Some(Pipeline {
        wip: wip_by,
        bottleneck,
        as_of: None,
    })
}

/// Ask Prometheus: the gauges' wip, age p90 and age ratio. Ok(None) when the gauges are absent.
pub fn read() -> Result<Option<Pipeline>, String> {
    let base = prom::base()?;
    let qs = [
        format!("{W} (agent_chain_wip)"),
        format!("{W} (agent_chain_age_minutes{{quantile=\"p90\"}})"),
        format!("{W} (agent_chain_age_ratio)"),
        // node_exporter's mtime of the textfile fleet-bench writes the gauges to.
        "max (node_textfile_mtime_seconds{file=~\".*fleet_bench.prom\"})".to_string(),
    ];
    let mut a: Vec<_> = std::thread::scope(|s| {
        let hs: Vec<_> = qs
            .iter()
            .map(|q| {
                let base = &base;
                s.spawn(move || prom::instant(base, q))
            })
            .collect();
        hs.into_iter()
            .map(|h| h.join().unwrap_or_else(|_| Err("panicked".into())))
            .collect()
    });
    let wip = a.remove(0)?;
    // The age and ratio gauges only decide the second line, and the mtime only the as-of
    // stamp; their failure leaves each off.
    let mtime = a.pop().and_then(Result::ok).unwrap_or_default();
    let ratio = a.pop().and_then(Result::ok).unwrap_or_default();
    let p90 = a.pop().and_then(Result::ok).unwrap_or_default();
    Ok(from_series(&wip, &p90, &ratio).map(|mut p| {
        p.as_of = mtime.iter().find_map(|s| s.value).map(|v| v as i64);
        p
    }))
}

/// The stamp: a clock time for today, with the date when the gauges were last written on an
/// earlier day, so a collector that stopped writing cannot pass for a fresh reading.
fn stamp(epoch: i64, now: i64) -> String {
    let day = |e| Local.timestamp_opt(e, 0).single().map(|t| t.date_naive());
    match Local.timestamp_opt(epoch, 0).single() {
        Some(t) if day(epoch) != day(now) => t.format("%m-%d %H:%M").to_string(),
        _ => clock(epoch),
    }
}

fn mins(m: f64) -> String {
    crate::queue::dur(Some(m.round() as i64))
}

impl Pipeline {
    /// `pipeline  inbox 4  backlog 312 ...  as of 12:40`; a step the gauge lacks reads `-`.
    pub fn line(&self) -> String {
        let steps: Vec<String> = self
            .wip
            .iter()
            .map(|(s, n)| format!("{s} {}", n.map_or("-".into(), |n| n.to_string())))
            .collect();
        let as_of = self.as_of.map_or(String::new(), |t| {
            format!("  as of {}", stamp(t, Local::now().timestamp()))
        });
        format!("pipeline  {}{as_of}", steps.join("  "))
    }

    /// `! bottleneck: waiting, age p90 9h (bound 4h)`, only when a step is past its bound.
    pub fn bottleneck_line(&self) -> Option<String> {
        let b = self.bottleneck.as_ref()?;
        let detail = match (b.age_p90_min, b.bound_min) {
            (Some(a), Some(bd)) => format!(", age p90 {} (bound {})", mins(a), mins(bd)),
            _ => String::new(),
        };
        Some(format!("{INDENT}! bottleneck: {}{detail}", b.step))
    }
}

/// The lines for one read: the summary, or `pipeline -` when the gauges are absent or the read
/// failed (the failure is for the caller to show; it is not a zero).
pub fn lines(p: Option<&Pipeline>) -> Vec<String> {
    match p {
        Some(p) => std::iter::once(p.line())
            .chain(p.bottleneck_line())
            .collect(),
        None => vec![NONE.into()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(step: &str, v: f64) -> Series {
        Series {
            labels: [("step".to_string(), step.to_string())].into(),
            value: Some(v),
            points: vec![],
        }
    }

    fn wip() -> Vec<Series> {
        vec![
            s("inbox", 4.0),
            s("backlog", 312.0),
            s("queued", 3.0),
            s("running", 5.0),
            s("waiting", 2.0),
            s("done", 9.0),
        ]
    }

    #[test]
    fn a_bottleneck_adds_the_second_line() {
        let p = from_series(
            &wip(),
            &[s("waiting", 540.0)],
            &[s("waiting", 2.25), s("queued", 0.5)],
        )
        .unwrap();
        assert_eq!(
            lines(Some(&p)),
            vec![
                "pipeline  inbox 4  backlog 312  queued 3  running 5  waiting 2",
                "          ! bottleneck: waiting, age p90 9h (bound 4h)",
            ]
        );
    }

    #[test]
    fn the_largest_ratio_over_one_wins() {
        let r = [s("queued", 1.5), s("waiting", 3.0), s("running", 1.0)];
        let p = from_series(&wip(), &[s("queued", 90.0), s("waiting", 540.0)], &r).unwrap();
        assert_eq!(p.bottleneck.unwrap().step, "waiting");
    }

    #[test]
    fn no_ratio_over_one_is_one_line_and_done_is_left_off() {
        let p = from_series(&wip(), &[], &[s("waiting", 0.9), s("running", 1.0)]).unwrap();
        let l = lines(Some(&p));
        assert_eq!(l.len(), 1);
        assert!(!l[0].contains("done"));
    }

    #[test]
    fn a_bottleneck_without_an_age_names_only_the_step() {
        let p = from_series(&wip(), &[], &[s("waiting", 2.0)]).unwrap();
        assert_eq!(p.bottleneck_line().unwrap().trim(), "! bottleneck: waiting");
    }

    #[test]
    fn a_missing_step_reads_dash_not_zero() {
        let w = [s("inbox", 0.0), s("queued", 3.0)];
        let p = from_series(&w, &[], &[]).unwrap();
        assert_eq!(
            p.line(),
            "pipeline  inbox 0  backlog -  queued 3  running -  waiting -"
        );
    }

    #[test]
    fn the_line_says_when_the_gauges_were_written() {
        let mut p = from_series(&wip(), &[], &[]).unwrap();
        assert!(!p.line().contains("as of"), "unknown age adds nothing");
        p.as_of = Some(Local::now().timestamp() - 60);
        assert!(p
            .line()
            .ends_with(&format!("  as of {}", clock(p.as_of.unwrap()))));
        assert!(p.line().starts_with("pipeline  inbox 4  backlog 312"));
    }

    #[test]
    fn a_stamp_from_an_earlier_day_carries_its_date() {
        let now = 1_794_010_893;
        assert_eq!(stamp(now - 60, now), clock(now - 60));
        let old = stamp(now - 3 * 86_400, now);
        assert_eq!(old.len(), "11-04 12:40".len(), "{old}");
    }

    #[test]
    fn negative_control_no_series_is_the_degraded_form() {
        assert_eq!(
            from_series(&[], &[s("waiting", 540.0)], &[s("waiting", 2.0)]),
            None
        );
        assert_eq!(lines(None), vec!["pipeline -"]);
        // A series with no number (NaN) is no series.
        let nan = Series {
            value: None,
            ..s("inbox", 0.0)
        };
        assert_eq!(from_series(&[nan], &[], &[]), None);
    }
}
