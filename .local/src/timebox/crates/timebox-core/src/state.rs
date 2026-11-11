//! The live snapshot (`state.json`) and the stopwatch state machine.
//!
//! Every transition method returns the `Event`s the caller should append to the log.
//! Elapsed time and lap boundaries are computed from `started_at` / `accumulated_s`
//! (see the module invariant in `lib.rs`), so the caller never has to keep a timer
//! running — it just calls `catch_up(now)` on read to flush any laps that have come due.

use crate::event::{Event, EventKind};
use chrono::{DateTime, Duration, Local};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunState {
    Running,
    Paused,
    Stopped,
}

/// A single count-up stopwatch, optionally with a recurring lap cadence.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stopwatch {
    pub op: String,
    pub state: RunState,
    /// Anchor for the current running segment. Only meaningful while `Running`.
    pub started_at: DateTime<Local>,
    /// Elapsed seconds banked before the current segment (grows on pause/stop).
    #[serde(default)]
    pub accumulated_s: i64,
    /// Recurring lap interval in seconds. `None` (or 0) = a plain stopwatch, no laps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lap_len_s: Option<u64>,
    /// Elapsed-seconds offset up to which laps have already been fired (the fire-once
    /// cursor, in *elapsed* space so it survives pause/resume). A manual `lap` sets this
    /// to the current elapsed so the cadence restarts from that point.
    #[serde(default)]
    pub lap_base_s: i64,
    /// Count of laps completed (auto + manual).
    #[serde(default)]
    pub lap_index: u32,
    /// Whether crossing a lap boundary should play a sound (opt-in per stopwatch).
    #[serde(default)]
    pub sound: bool,
}

impl Stopwatch {
    /// Elapsed seconds at `now`.
    pub fn elapsed_s(&self, now: DateTime<Local>) -> i64 {
        match self.state {
            RunState::Running => self.accumulated_s + (now - self.started_at).num_seconds(),
            _ => self.accumulated_s,
        }
    }

    fn lap_len(&self) -> Option<i64> {
        self.lap_len_s.filter(|l| *l > 0).map(|l| l as i64)
    }

    /// Seconds until the next lap boundary, or `None` for a plain / non-running stopwatch.
    pub fn next_lap_countdown_s(&self, now: DateTime<Local>) -> Option<i64> {
        if self.state != RunState::Running {
            return None;
        }
        let l = self.lap_len()?;
        let e = self.elapsed_s(now);
        let since = (e - self.lap_base_s).max(0);
        let next_boundary = self.lap_base_s + (since / l + 1) * l;
        Some(next_boundary - e)
    }

    /// Wall-clock time at which elapsed crossed `boundary_elapsed_s`, within the current
    /// running segment. `elapsed = accumulated + (t - started_at)`, so `t = started_at +
    /// (boundary_elapsed - accumulated)`.
    fn boundary_ts(&self, boundary_elapsed_s: i64) -> DateTime<Local> {
        self.started_at + Duration::seconds(boundary_elapsed_s - self.accumulated_s)
    }
}

/// One step of a named cycle: run `op` for `len_s` seconds, then move to the next step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CycleStep {
    pub op: String,
    pub len_s: u64,
}

/// A running named cycle (e.g. work 5m -> guitar 3m -> computer 10m, repeating). The
/// active stopwatch is always `steps[idx].op`; `catch_up` advances `idx` at each lap
/// boundary, so the cycle walks on its own with nothing running in the background.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cycle {
    pub name: String,
    pub steps: Vec<CycleStep>,
    #[serde(default)]
    pub idx: usize,
    #[serde(default)]
    pub sound: bool,
}

impl Cycle {
    pub fn current(&self) -> &CycleStep {
        &self.steps[self.idx % self.steps.len()]
    }
    pub fn next(&self) -> &CycleStep {
        &self.steps[(self.idx + 1) % self.steps.len()]
    }
}

/// Runtime alert toggles (`timebox toggle sound|flash`). `None` = follow config.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Alerts {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sound: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flash: Option<bool>,
}

/// The whole live state: which stopwatch is active, and every known stopwatch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(default = "one")]
    pub v: u32,
    #[serde(default)]
    pub active_sw: Option<String>,
    #[serde(default)]
    pub stopwatches: BTreeMap<String, Stopwatch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle: Option<Cycle>,
    #[serde(default)]
    pub alerts: Alerts,
}

fn one() -> u32 {
    1
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            v: 1,
            active_sw: None,
            stopwatches: BTreeMap::new(),
            cycle: None,
            alerts: Alerts::default(),
        }
    }
}

impl Snapshot {
    /// Resolve a target: an explicit op, else the active stopwatch. Returns the op name
    /// only if that stopwatch exists.
    pub fn resolve<'a>(&self, op: Option<&'a str>) -> Option<String> {
        match op {
            Some(o) => self.stopwatches.contains_key(o).then(|| o.to_string()),
            None => self
                .active_sw
                .clone()
                .filter(|a| self.stopwatches.contains_key(a)),
        }
    }

    /// The stopwatch to surface in a status line: the active one if running, else any
    /// running one, else the active one, else none.
    pub fn display_op(&self) -> Option<String> {
        if let Some(a) = &self.active_sw {
            if self.stopwatches.get(a).map(|s| s.state) == Some(RunState::Running) {
                return Some(a.clone());
            }
        }
        if let Some((op, _)) = self
            .stopwatches
            .iter()
            .find(|(_, s)| s.state == RunState::Running)
        {
            return Some(op.clone());
        }
        self.active_sw.clone()
    }

    /// Start (create-or-resume) a stopwatch and make it active. Ends any running cycle.
    pub fn start(
        &mut self,
        now: DateTime<Local>,
        op: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        self.cycle = None;
        self.start_inner(now, op, lap_len_s, sound)
    }

    fn start_inner(
        &mut self,
        now: DateTime<Local>,
        op: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        let kind;
        if let Some(sw) = self.stopwatches.get_mut(op) {
            match sw.state {
                RunState::Running => {
                    kind = EventKind::Start; // idempotent re-start
                }
                RunState::Paused | RunState::Stopped => {
                    sw.started_at = now;
                    sw.state = RunState::Running;
                    kind = EventKind::Resume;
                }
            }
            if lap_len_s.is_some() {
                sw.lap_len_s = lap_len_s;
            }
            if let Some(s) = sound {
                sw.sound = s;
            }
        } else {
            self.stopwatches.insert(
                op.to_string(),
                Stopwatch {
                    op: op.to_string(),
                    state: RunState::Running,
                    started_at: now,
                    accumulated_s: 0,
                    lap_len_s,
                    lap_base_s: 0,
                    lap_index: 0,
                    sound: sound.unwrap_or(false),
                },
            );
            kind = EventKind::Start;
        }
        // (Re)anchor the lap cadence to now whenever start carries a lap interval, so
        // `start --lap 3m` always means "first switch 3 minutes from now" — even when
        // resuming a stopwatch that already has banked elapsed time. (`resume` keeps the
        // partial window; `start` begins a fresh session.)
        if let Some(sw) = self.stopwatches.get_mut(op) {
            if sw.lap_len_s.filter(|l| *l > 0).is_some() {
                sw.lap_base_s = sw.elapsed_s(now);
            }
        }
        self.active_sw = Some(op.to_string());
        let len = self.stopwatches.get(op).and_then(|s| s.lap_len_s);
        vec![Event::new(now, kind, op).with_lap_len(len)]
    }

    /// Stop a stopwatch, banking its elapsed time. Stopping the active one ends a cycle.
    pub fn stop(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.active_sw.as_deref() == Some(op) {
            self.cycle = None;
        }
        self.stop_inner(now, op)
    }

    fn stop_inner(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        let Some(sw) = self.stopwatches.get_mut(op) else {
            return vec![];
        };
        if sw.state == RunState::Running {
            sw.accumulated_s = sw.accumulated_s + (now - sw.started_at).num_seconds();
        }
        sw.state = RunState::Stopped;
        if self.active_sw.as_deref() == Some(op) {
            self.active_sw = None;
        }
        vec![Event::new(now, EventKind::Stop, op)]
    }

    /// Pause a running stopwatch (bank elapsed, keep it as the active op).
    pub fn pause(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        let Some(sw) = self.stopwatches.get_mut(op) else {
            return vec![];
        };
        if sw.state == RunState::Running {
            sw.accumulated_s = sw.accumulated_s + (now - sw.started_at).num_seconds();
            sw.state = RunState::Paused;
            return vec![Event::new(now, EventKind::Pause, op)];
        }
        vec![]
    }

    /// Resume a paused/stopped stopwatch and make it active.
    pub fn resume(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        let Some(sw) = self.stopwatches.get_mut(op) else {
            return vec![];
        };
        if sw.state != RunState::Running {
            sw.started_at = now;
            sw.state = RunState::Running;
            self.active_sw = Some(op.to_string());
            return vec![Event::new(now, EventKind::Resume, op)];
        }
        vec![]
    }

    /// Manually close the current lap window now and restart the cadence from here.
    /// Inside a cycle, a lap on the active op skips to the next step.
    pub fn lap(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.cycle.is_some() && self.active_sw.as_deref() == Some(op) {
            return self.advance_cycle(now);
        }
        let Some(sw) = self.stopwatches.get_mut(op) else {
            return vec![];
        };
        let e = sw.elapsed_s(now);
        sw.lap_base_s = e;
        sw.lap_index += 1;
        let idx = sw.lap_index;
        let len = sw.lap_len_s;
        vec![Event::new(now, EventKind::Lap, op).with_lap(idx, len)]
    }

    /// Stop/leave the active stopwatch and start `to` in one atomic step. Ends any cycle.
    pub fn switch(
        &mut self,
        now: DateTime<Local>,
        to: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        self.cycle = None;
        self.switch_inner(now, to, lap_len_s, sound)
    }

    fn switch_inner(
        &mut self,
        now: DateTime<Local>,
        to: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        let mut evs = Vec::new();
        if let Some(cur) = self.active_sw.clone() {
            if cur != to {
                evs.extend(self.stop_inner(now, &cur));
            }
        }
        evs.extend(self.start_inner(now, to, lap_len_s, sound));
        evs.push(Event::new(now, EventKind::Switch, to).with_lap_len(lap_len_s));
        evs
    }

    /// Start a named cycle at its first step (switching away from the active op).
    pub fn start_cycle(
        &mut self,
        now: DateTime<Local>,
        name: &str,
        steps: Vec<CycleStep>,
        sound: bool,
    ) -> Vec<Event> {
        let Some(first) = steps.first().cloned() else {
            return vec![];
        };
        let mut evs = self.switch(now, &first.op, Some(first.len_s), Some(sound));
        for e in &mut evs {
            e.meta = serde_json::json!({ "cycle": name });
        }
        self.cycle = Some(Cycle {
            name: name.to_string(),
            steps,
            idx: 0,
            sound,
        });
        evs
    }

    /// Close the current cycle step at `at` (a lap on its op) and switch to the next.
    fn advance_cycle(&mut self, at: DateTime<Local>) -> Vec<Event> {
        let Some(c) = self.cycle.as_mut() else {
            return vec![];
        };
        let name = c.name.clone();
        let cur = c.current().op.clone();
        c.idx = (c.idx + 1) % c.steps.len();
        let next = c.current().clone();
        let sound = c.sound;
        let mut evs = Vec::new();
        if let Some(sw) = self.stopwatches.get_mut(&cur) {
            sw.lap_base_s = sw.elapsed_s(at);
            sw.lap_index += 1;
            evs.push(Event::new(at, EventKind::Lap, &cur).with_lap(sw.lap_index, sw.lap_len_s));
        }
        evs.extend(self.switch_inner(at, &next.op, Some(next.len_s), Some(sound)));
        for e in &mut evs {
            e.meta = serde_json::json!({ "cycle": name });
        }
        evs
    }

    /// Remove a stopwatch from the live snapshot (its events stay in the log).
    pub fn reset(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.active_sw.as_deref() == Some(op) {
            self.cycle = None;
        }
        if self.stopwatches.remove(op).is_none() {
            return vec![];
        }
        if self.active_sw.as_deref() == Some(op) {
            self.active_sw = None;
        }
        vec![Event::new(now, EventKind::Reset, op)]
    }

    /// Flush every lap boundary that has come due at or before `now`. Returns the lap
    /// events to append (in chronological order). Fire-once is guaranteed by advancing
    /// each stopwatch's `lap_base_s` past the boundaries it emits.
    pub fn catch_up(&mut self, now: DateTime<Local>) -> Vec<Event> {
        let mut out = Vec::new();
        // A cycle walks first: each due boundary of the active step switches to the next
        // step at the boundary's own timestamp, so a late poll replays the steps exactly.
        while self.cycle.is_some() {
            let Some(sw) = self
                .active_sw
                .as_ref()
                .and_then(|a| self.stopwatches.get(a))
            else {
                break;
            };
            if sw.state != RunState::Running {
                break;
            }
            let Some(l) = sw.lap_len() else { break };
            let boundary = sw.lap_base_s + l;
            if sw.elapsed_s(now) < boundary {
                break;
            }
            let ts = sw.boundary_ts(boundary);
            out.extend(self.advance_cycle(ts));
        }
        for sw in self.stopwatches.values_mut() {
            if sw.state != RunState::Running {
                continue;
            }
            let Some(l) = sw.lap_len_s.filter(|l| *l > 0).map(|l| l as i64) else {
                continue;
            };
            let e = sw.elapsed_s(now);
            let due = (e - sw.lap_base_s) / l; // whole windows since the cursor
            if due <= 0 {
                continue;
            }
            for k in 1..=due {
                let boundary_elapsed = sw.lap_base_s + k * l;
                let ts = sw.boundary_ts(boundary_elapsed);
                let idx = sw.lap_index + k as u32;
                out.push(Event::new(ts, EventKind::Lap, &sw.op).with_lap(idx, sw.lap_len_s));
            }
            sw.lap_base_s += due * l;
            sw.lap_index += due as u32;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> DateTime<Local> {
        DateTime::parse_from_rfc3339("2026-07-10T09:00:00-07:00")
            .unwrap()
            .with_timezone(&Local)
    }
    fn at(base: DateTime<Local>, secs: i64) -> DateTime<Local> {
        base + Duration::seconds(secs)
    }

    #[test]
    fn elapsed_counts_up_while_running() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "deep-work", None, None);
        let sw = &s.stopwatches["deep-work"];
        assert_eq!(sw.elapsed_s(at(t, 90)), 90);
    }

    #[test]
    fn pause_banks_and_freezes_elapsed() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "op", None, None);
        s.pause(at(t, 100), "op");
        let sw = &s.stopwatches["op"];
        assert_eq!(sw.state, RunState::Paused);
        assert_eq!(sw.elapsed_s(at(t, 999)), 100); // frozen at pause
                                                   // resume and run 50 more -> 150 total
        s.resume(at(t, 200), "op");
        let sw = &s.stopwatches["op"];
        assert_eq!(sw.elapsed_s(at(t, 250)), 150);
    }

    #[test]
    fn catch_up_fires_exactly_once_per_boundary() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "op", Some(5), None); // 5s laps
                                         // at 12s, two boundaries (5,10) are due
        let laps = s.catch_up(at(t, 12));
        assert_eq!(laps.len(), 2);
        assert_eq!(laps[0].lap_index, Some(1));
        assert_eq!(laps[1].lap_index, Some(2));
        // boundary timestamps are the computed crossing times, not `now`
        assert_eq!(laps[0].ts, at(t, 5));
        assert_eq!(laps[1].ts, at(t, 10));
        // calling again immediately fires nothing (fire-once)
        assert!(s.catch_up(at(t, 12)).is_empty());
        // a third boundary at 15s fires just once
        let more = s.catch_up(at(t, 16));
        assert_eq!(more.len(), 1);
        assert_eq!(more[0].lap_index, Some(3));
    }

    #[test]
    fn laps_pause_with_the_stopwatch() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "op", Some(10), None);
        // run 6s, pause 1000s, resume: only 6s of active time elapsed, no lap yet
        s.pause(at(t, 6), "op");
        assert!(s.catch_up(at(t, 1006)).is_empty());
        s.resume(at(t, 1006), "op");
        // 4 more active seconds -> elapsed 10 -> exactly one lap
        let laps = s.catch_up(at(t, 1010));
        assert_eq!(laps.len(), 1);
        assert_eq!(laps[0].lap_index, Some(1));
    }

    #[test]
    fn manual_lap_restarts_cadence() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "op", Some(100), None);
        s.lap(at(t, 30), "op"); // manual lap at 30s elapsed
        let sw = &s.stopwatches["op"];
        assert_eq!(sw.lap_index, 1);
        // next auto boundary is now 30 + 100 = 130s, so nothing at 120s...
        assert!(s.catch_up(at(t, 120)).is_empty());
        // ...and one at 130s
        let laps = s.catch_up(at(t, 131));
        assert_eq!(laps.len(), 1);
        assert_eq!(laps[0].lap_index, Some(2));
    }

    #[test]
    fn start_with_lap_anchors_cadence_to_now() {
        let mut s = Snapshot::default();
        let t = t0();
        // Prior session banked 320s, then stopped (as in: deep-work ran 5:20).
        s.start(t, "deep-work", Some(1500), None);
        s.stop(at(t, 320), "deep-work");
        // Restart with a 3m lap: the next switch must be a fresh 180s from now, not 40s
        // (the next 180s grid line off total elapsed).
        s.start(at(t, 320), "deep-work", Some(180), None);
        let sw = &s.stopwatches["deep-work"];
        assert_eq!(sw.next_lap_countdown_s(at(t, 320)), Some(180));
        // ...and the boundary actually fires ~180s later, exactly once.
        let laps = s.catch_up(at(t, 320 + 181));
        assert_eq!(laps.len(), 1);
    }

    #[test]
    fn restarting_a_running_stopwatch_rearms_the_window() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "op", Some(100), None); // boundary at 100
                                           // 40s in, re-arm with the same 100s lap -> fresh 100s from now (140 total)
        s.start(at(t, 40), "op", Some(100), None);
        let sw = &s.stopwatches["op"];
        assert_eq!(sw.next_lap_countdown_s(at(t, 40)), Some(100));
    }

    #[test]
    fn switch_stops_current_and_starts_next() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "a", None, None);
        let evs = s.switch(at(t, 60), "b", None, None);
        assert_eq!(s.active_sw.as_deref(), Some("b"));
        assert_eq!(s.stopwatches["a"].state, RunState::Stopped);
        assert_eq!(s.stopwatches["b"].state, RunState::Running);
        assert!(evs.iter().any(|e| e.kind == EventKind::Switch));
    }

    fn steps() -> Vec<CycleStep> {
        vec![
            CycleStep {
                op: "work".into(),
                len_s: 300,
            },
            CycleStep {
                op: "guitar".into(),
                len_s: 180,
            },
            CycleStep {
                op: "computer".into(),
                len_s: 600,
            },
        ]
    }

    #[test]
    fn cycle_walks_steps_at_their_boundaries() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start_cycle(t, "practice", steps(), false);
        assert_eq!(s.active_sw.as_deref(), Some("work"));
        assert!(s.catch_up(at(t, 299)).is_empty());
        let evs = s.catch_up(at(t, 300));
        assert!(evs
            .iter()
            .any(|e| e.kind == EventKind::Switch && e.op == "guitar"));
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        assert_eq!(s.stopwatches["work"].state, RunState::Stopped);
        assert_eq!(
            s.stopwatches["guitar"].next_lap_countdown_s(at(t, 300)),
            Some(180)
        );
    }

    #[test]
    fn late_poll_replays_every_missed_step_and_wraps() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start_cycle(t, "practice", steps(), false);
        // 300 + 180 + 600 = 1080 is one full loop; 1100 is 20s into work again.
        let evs = s.catch_up(at(t, 1100));
        let switches: Vec<_> = evs
            .iter()
            .filter(|e| e.kind == EventKind::Switch)
            .map(|e| e.op.as_str())
            .collect();
        assert_eq!(switches, ["guitar", "computer", "work"]);
        assert_eq!(s.active_sw.as_deref(), Some("work"));
        assert_eq!(s.cycle.as_ref().unwrap().idx, 0);
        assert_eq!(s.stopwatches["work"].elapsed_s(at(t, 1100)), 320);
        assert_eq!(s.stopwatches["guitar"].elapsed_s(at(t, 1100)), 180);
        assert_eq!(s.stopwatches["computer"].elapsed_s(at(t, 1100)), 600);
        assert_eq!(
            s.stopwatches["work"].next_lap_countdown_s(at(t, 1100)),
            Some(280)
        );
    }

    #[test]
    fn lap_skips_to_next_step_and_pause_holds_the_cycle() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start_cycle(t, "practice", steps(), false);
        s.lap(at(t, 10), "work");
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        s.pause(at(t, 20), "guitar");
        assert!(s.catch_up(at(t, 5000)).is_empty());
        s.resume(at(t, 5000), "guitar");
        assert_eq!(
            s.stopwatches["guitar"].next_lap_countdown_s(at(t, 5000)),
            Some(170)
        );
        assert!(s.cycle.is_some());
    }

    #[test]
    fn manual_switch_or_stop_ends_the_cycle() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start_cycle(t, "practice", steps(), false);
        s.switch(at(t, 10), "email", None, None);
        assert!(s.cycle.is_none());
        s.start_cycle(at(t, 20), "practice", steps(), false);
        s.stop(at(t, 30), "work");
        assert!(s.cycle.is_none());
        assert!(s.catch_up(at(t, 9999)).is_empty());
    }
}
