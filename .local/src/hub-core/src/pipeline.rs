//! The pipeline snapshot: one row per step between a captured thought and a landed PR, the JSON
//! fleet-bench writes each tick (`pipeline_json`), the same one its `agent_chain_*` gauges come
//! from. `flow` words it as the strip on Home and the line on the Queue tab. A step or number
//! the snapshot lacks is None and never a zero.

use std::path::Path;

use serde::{Deserialize, Serialize};

use chrono::{Local, TimeZone};

use crate::capacity::clock;

/// A step past its age bound.
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Bottleneck {
    pub step: String,
    /// The step's age p90 in minutes, when the snapshot has it.
    pub age_p90_min: Option<f64>,
    /// The bound the ratio was taken against.
    pub bound_min: Option<f64>,
    pub ratio: f64,
}

/// One subject that went wrong at a step in the last 24 hours (`notes log --steps`).
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone, Default)]
pub struct Problem {
    pub ts: String,
    pub subject: String,
    pub kind: String,
    /// Empty when the record holds no cause.
    pub why: String,
    pub n: usize,
}

/// One step of the snapshot, as `pipeline_json` names its fields.
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone, Default)]
pub struct Step {
    pub step: String,
    pub wip: Option<u64>,
    pub age_p90_min: Option<f64>,
    pub oldest_min: Option<f64>,
    pub in_24h: Option<u64>,
    pub out_24h: Option<u64>,
    pub bound: Option<f64>,
    pub ratio: Option<f64>,
    pub problems_n: Option<usize>,
    #[serde(default)]
    pub problems: Vec<Problem>,
    /// Why nothing can leave this step right now.
    pub blocked: Option<String>,
}

#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Pipeline {
    pub steps: Vec<Step>,
    /// The step with the largest age ratio above 1, if any.
    pub bottleneck: Option<Bottleneck>,
    /// When fleet-bench wrote the snapshot (unix seconds). It lags the live queue by up to one
    /// tick, so the surfaces say when it was written.
    pub as_of: Option<i64>,
}

/// The summary from the snapshot's text. None when it has no steps: fleet-bench could not build
/// them, which is not the same as an empty pipeline.
pub fn parse(text: &str) -> Result<Option<Pipeline>, String> {
    #[derive(Deserialize)]
    struct Raw {
        as_of: Option<i64>,
        #[serde(default)]
        steps: Vec<Step>,
    }
    let raw: Raw =
        serde_json::from_str(text).map_err(|e| format!("snapshot cannot be read: {e}"))?;
    if raw.steps.is_empty() {
        return Ok(None);
    }
    let bottleneck = raw
        .steps
        .iter()
        .filter_map(|s| Some((s, s.ratio.filter(|r| *r > 1.0)?)))
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(s, r)| Bottleneck {
            step: s.step.clone(),
            age_p90_min: s.age_p90_min,
            bound_min: s.bound,
            ratio: r,
        });
    Ok(Some(Pipeline {
        steps: raw.steps,
        bottleneck,
        as_of: raw.as_of,
    }))
}

fn read_file(path: &Path) -> Result<Option<Pipeline>, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// The snapshot. Ok(None) when fleet-bench has written none.
pub fn read() -> Result<Option<Pipeline>, String> {
    read_file(&crate::boards::pipeline_snapshot())
}

/// The stamp: a clock time for today, with the date when the snapshot was last written on an
/// earlier day, so a writer that stopped cannot pass for a fresh reading.
pub(crate) fn stamp(epoch: i64, now: i64) -> String {
    let day = |e| Local.timestamp_opt(e, 0).single().map(|t| t.date_naive());
    match Local.timestamp_opt(epoch, 0).single() {
        Some(t) if day(epoch) != day(now) => t.format("%m-%d %H:%M").to_string(),
        _ => clock(epoch),
    }
}

/// A history cell's time, always with its date (`11-11 00:16`), so today's row reads like the
/// ones beside it from earlier days.
pub(crate) fn dated(epoch: i64) -> String {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map_or_else(|| "-".into(), |t| t.format("%m-%d %H:%M").to_string())
}

fn mins(m: f64) -> String {
    crate::queue::dur(Some(m.round() as i64))
}

impl Pipeline {
    pub fn step(&self, name: &str) -> Option<&Step> {
        self.steps.iter().find(|s| s.step == name)
    }

    /// `bottleneck: waiting, age p90 9h (bound 4h)`, only when a step is past its bound.
    pub fn bottleneck_text(&self) -> Option<String> {
        let b = self.bottleneck.as_ref()?;
        let detail = match (b.age_p90_min, b.bound_min) {
            (Some(a), Some(bd)) => format!(", age p90 {} (bound {})", mins(a), mins(bd)),
            _ => String::new(),
        };
        Some(format!("bottleneck: {}{detail}", b.step))
    }

    /// When the snapshot was written, if known; a date is added from an earlier day.
    pub fn as_of_label(&self) -> Option<String> {
        self.as_of.map(|t| stamp(t, Local::now().timestamp()))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A snapshot as `pipeline_json` writes it, one `(step, wip, age p90, ratio)` per row.
    pub(crate) fn snapshot(rows: &[(&str, u64, f64, f64)]) -> Pipeline {
        let steps: Vec<_> = rows
            .iter()
            .map(|(step, wip, p90, ratio)| {
                serde_json::json!({"step": step, "wip": wip, "age_p90_min": p90,
                    "bound": p90 / ratio, "ratio": ratio, "problems_n": null, "blocked": null})
            })
            .collect();
        let text = serde_json::json!({"as_of": null, "steps": steps}).to_string();
        parse(&text).unwrap().unwrap()
    }

    #[test]
    fn a_bottleneck_names_its_step_age_and_bound() {
        let p = snapshot(&[("waiting", 2, 540.0, 2.25), ("queued", 3, 60.0, 0.5)]);
        assert_eq!(
            p.bottleneck_text().unwrap(),
            "bottleneck: waiting, age p90 9h (bound 4h)"
        );
    }

    #[test]
    fn the_largest_ratio_over_one_wins_and_none_over_one_is_no_bottleneck() {
        let p = snapshot(&[("queued", 3, 90.0, 1.5), ("waiting", 2, 540.0, 3.0)]);
        assert_eq!(p.bottleneck.unwrap().step, "waiting");
        let p = snapshot(&[("waiting", 2, 90.0, 0.9), ("running", 1, 60.0, 1.0)]);
        assert_eq!(p.bottleneck_text(), None);
    }

    #[test]
    fn a_step_carries_its_problems_and_why_it_is_blocked() {
        let p = parse(
            r#"{"as_of": 7, "steps": [{"step": "queued", "wip": 2, "problems_n": 1, "blocked": "stopped",
                "problems": [{"ts": "t", "subject": "a", "kind": "failed", "why": "", "n": 2}]}]}"#,
        )
        .unwrap()
        .unwrap();
        let q = p.step("queued").unwrap();
        assert_eq!(
            (p.as_of, q.blocked.as_deref(), q.problems[0].n),
            (Some(7), Some("stopped"), 2)
        );
        assert_eq!(p.step("running"), None);
    }

    #[test]
    fn the_stamp_says_when_the_snapshot_was_written() {
        let mut p = snapshot(&[("queued", 3, 60.0, 0.5)]);
        assert_eq!(p.as_of_label(), None, "unknown age adds nothing");
        p.as_of = Some(Local::now().timestamp() - 60);
        assert_eq!(p.as_of_label(), Some(clock(p.as_of.unwrap())));
    }

    #[test]
    fn a_stamp_from_an_earlier_day_carries_its_date() {
        let now = 1_794_010_893;
        assert_eq!(stamp(now - 60, now), clock(now - 60));
        let old = stamp(now - 3 * 86_400, now);
        assert_eq!(old.len(), "11-04 12:40".len(), "{old}");
        // A history cell carries the date even for today.
        assert_eq!(dated(now - 60).len(), "11-04 12:40".len());
        assert!(dated(now - 60).ends_with(&clock(now - 60)));
    }

    #[test]
    fn negative_control_no_file_no_steps_and_a_bad_file_are_not_an_empty_pipeline() {
        let dir = std::env::temp_dir().join(format!("hub-pipeline-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("pipeline.json");
        assert_eq!(read_file(&f), Ok(None), "not written yet");
        assert_eq!(
            parse(r#"{"steps": []}"#),
            Ok(None),
            "fleet-bench could not build it"
        );
        std::fs::write(&f, "{half").unwrap();
        assert!(read_file(&f).unwrap_err().contains("cannot be read"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
