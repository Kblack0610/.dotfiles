//! The append-only event: one JSON object per line in `events.jsonl`.
//!
//! The log is the durable source of truth — every state transition and every lap
//! boundary is recorded, so any future stat is a fold over this log with no schema
//! migration. Forward-compat is deliberate: a `v` field, `#[serde(default)]` on the
//! optional fields, and a catch-all `Unknown` event kind so a newer writer's events
//! never crash an older reader.

use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// What happened. Serialized lowercase (`"start"`, `"lap"`, ...).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventKind {
    Start,
    Stop,
    Pause,
    Resume,
    Lap,
    Switch,
    Reset,
    /// Any kind a future version writes that this build doesn't know — kept so old
    /// binaries can still read (and fold over) a newer log.
    #[serde(other)]
    Unknown,
}

/// One logged event. `sw` is the stopwatch id (== `op` in Phase 1). `lap_index` /
/// `lap_len_s` are set on lap-ish events; `meta` is an open forward-compat blob.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    #[serde(default = "one")]
    pub v: u32,
    pub ts: DateTime<Local>,
    #[serde(rename = "type")]
    pub kind: EventKind,
    pub op: String,
    pub sw: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lap_index: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lap_len_s: Option<u64>,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub meta: Value,
}

fn one() -> u32 {
    1
}

impl Event {
    /// Construct an event for stopwatch `op` at `ts`.
    pub fn new(ts: DateTime<Local>, kind: EventKind, op: &str) -> Self {
        Event {
            v: 1,
            ts,
            kind,
            op: op.to_string(),
            sw: op.to_string(),
            lap_index: None,
            lap_len_s: None,
            meta: Value::Null,
        }
    }

    pub fn with_lap(mut self, lap_index: u32, lap_len_s: Option<u64>) -> Self {
        self.lap_index = Some(lap_index);
        self.lap_len_s = lap_len_s;
        self
    }

    pub fn with_lap_len(mut self, lap_len_s: Option<u64>) -> Self {
        self.lap_len_s = lap_len_s;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_through_json() {
        let ts = DateTime::parse_from_rfc3339("2026-07-10T09:15:30-07:00")
            .unwrap()
            .with_timezone(&Local);
        let e = Event::new(ts, EventKind::Lap, "deep-work").with_lap(3, Some(1500));
        let line = serde_json::to_string(&e).unwrap();
        let back: Event = serde_json::from_str(&line).unwrap();
        assert_eq!(back.kind, EventKind::Lap);
        assert_eq!(back.op, "deep-work");
        assert_eq!(back.lap_index, Some(3));
        assert_eq!(back.lap_len_s, Some(1500));
    }

    #[test]
    fn unknown_kind_survives() {
        let line = r#"{"v":1,"ts":"2026-07-10T09:15:30-07:00","type":"teleport","op":"x","sw":"x"}"#;
        let e: Event = serde_json::from_str(line).unwrap();
        assert_eq!(e.kind, EventKind::Unknown);
    }
}
