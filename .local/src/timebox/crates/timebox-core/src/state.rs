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

/// One queued task: run `op` with a recurring lap of `len_s` seconds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Task {
    pub op: String,
    pub len_s: u64,
}

/// The task queue. The head (`tasks[0]`) is the task being worked on; while the queue is
/// `active` its op is the active stopwatch with lap = the task's length, so a timeout is a
/// plain lap boundary: it flashes and the same task's window starts again. Only `done`
/// moves to the next task.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Queue {
    #[serde(default)]
    pub tasks: Vec<Task>,
    /// Running the head right now (cleared by stopping it or starting another op by hand).
    #[serde(default)]
    pub active: bool,
    /// The head stopwatch's `lap_index` when the head started: laps past it are misses.
    #[serde(default)]
    pub lap_base: u32,
    /// The preset last loaded, for display.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<String>,
}

impl Queue {
    pub fn head(&self) -> Option<&Task> {
        self.tasks.first()
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
    #[serde(default)]
    pub queue: Queue,
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
            queue: Queue::default(),
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

    /// Start (create-or-resume) a stopwatch and make it active. Starting any op but the
    /// queue head, or the head with another lap, takes the queue off (its tasks stay).
    pub fn start(
        &mut self,
        now: DateTime<Local>,
        op: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        self.leave_queue_unless(op, lap_len_s);
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

    /// Stop a stopwatch, banking its elapsed time. Stopping the queue head takes the
    /// queue off (its tasks stay; `queue go` picks it up again).
    pub fn stop(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.queue.head().map(|t| t.op.as_str()) == Some(op) {
            self.queue.active = false;
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
            self.leave_queue_unless(op, None);
            return vec![Event::new(now, EventKind::Resume, op)];
        }
        vec![]
    }

    /// Manually close the current lap window now and restart the cadence from here. On
    /// the queue head it restarts the task's window without counting a miss.
    pub fn lap(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        let Some(sw) = self.stopwatches.get_mut(op) else {
            return vec![];
        };
        let e = sw.elapsed_s(now);
        sw.lap_base_s = e;
        sw.lap_index += 1;
        let idx = sw.lap_index;
        let len = sw.lap_len_s;
        if self.on_queue_head(op) {
            self.queue.lap_base += 1;
        }
        vec![Event::new(now, EventKind::Lap, op).with_lap(idx, len)]
    }

    /// Stop/leave the active stopwatch and start `to` in one atomic step. Switching to
    /// any op but the queue head, or the head with another lap, takes the queue off.
    pub fn switch(
        &mut self,
        now: DateTime<Local>,
        to: &str,
        lap_len_s: Option<u64>,
        sound: Option<bool>,
    ) -> Vec<Event> {
        self.leave_queue_unless(to, lap_len_s);
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

    /// Anything but the head task at its own length takes the queue off.
    fn leave_queue_unless(&mut self, op: &str, lap_len_s: Option<u64>) {
        let keeps = self
            .queue
            .head()
            .is_some_and(|t| t.op == op && lap_len_s.is_none_or(|l| l == t.len_s));
        if !keeps {
            self.queue.active = false;
        }
    }

    fn on_queue_head(&self, op: &str) -> bool {
        self.queue.active && self.queue.head().is_some_and(|t| t.op == op)
    }

    /// The head task is about to change: stop the old one so the new head starts a fresh
    /// window and miss count, even when it is the same op at the same length.
    fn retire_head(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.queue.active {
            self.stop_inner(now, op)
        } else {
            vec![]
        }
    }

    /// Misses on the head task: lap boundaries it crossed since it started.
    pub fn queue_misses(&self) -> u32 {
        let Some(h) = self.queue.head() else { return 0 };
        if !self.queue.active {
            return 0;
        }
        self.stopwatches
            .get(&h.op)
            .map(|sw| sw.lap_index.saturating_sub(self.queue.lap_base))
            .unwrap_or(0)
    }

    fn qev(now: DateTime<Local>, kind: EventKind, op: &str, meta: serde_json::Value) -> Event {
        let mut e = Event::new(now, kind, op);
        e.meta = meta;
        e
    }

    /// After the queue changed: while active, make sure the head is the running op with
    /// its own lap; with no tasks left, stop and go idle.
    fn sync_head(&mut self, now: DateTime<Local>, sound: bool) -> Vec<Event> {
        if !self.queue.active {
            return vec![];
        }
        let Some(h) = self.queue.head().cloned() else {
            self.queue.active = false;
            return match self.active_sw.clone() {
                Some(cur) => self.stop_inner(now, &cur),
                None => vec![],
            };
        };
        // Already the head (running, or paused by hand: an edit behind it must not unpause).
        let on_head = self.active_sw.as_deref() == Some(h.op.as_str())
            && self
                .stopwatches
                .get(&h.op)
                .is_some_and(|s| s.state != RunState::Stopped && s.lap_len_s == Some(h.len_s));
        if on_head {
            return vec![];
        }
        let evs = self.switch_inner(now, &h.op, Some(h.len_s), Some(sound));
        self.queue.lap_base = self.stopwatches[&h.op].lap_index;
        evs
    }

    /// Append a task to the queue.
    pub fn queue_add(&mut self, now: DateTime<Local>, task: Task) -> Vec<Event> {
        let ev = Self::qev(
            now,
            EventKind::QueueAdd,
            &task.op,
            serde_json::json!({ "len_s": task.len_s, "pos": self.queue.tasks.len() }),
        );
        self.queue.tasks.push(task);
        vec![ev]
    }

    /// Remove the task at `i` (0 = head). Removing the running head starts the next.
    pub fn queue_rm(&mut self, now: DateTime<Local>, i: usize, sound: bool) -> Vec<Event> {
        if i >= self.queue.tasks.len() {
            return vec![];
        }
        let t = self.queue.tasks.remove(i);
        let mut evs = vec![Self::qev(
            now,
            EventKind::QueueRm,
            &t.op,
            serde_json::json!({ "pos": i }),
        )];
        if i == 0 {
            evs.extend(self.retire_head(now, &t.op));
        }
        evs.extend(self.sync_head(now, sound));
        evs
    }

    /// Move the task at `from` to position `to` (clamped). A new head starts if active.
    pub fn queue_mv(
        &mut self,
        now: DateTime<Local>,
        from: usize,
        to: usize,
        sound: bool,
    ) -> Vec<Event> {
        let n = self.queue.tasks.len();
        if from >= n {
            return vec![];
        }
        let to = to.min(n - 1);
        if from == to {
            return vec![];
        }
        let old_head = self.queue.tasks[0].op.clone();
        let t = self.queue.tasks.remove(from);
        let op = t.op.clone();
        self.queue.tasks.insert(to, t);
        let mut evs = vec![Self::qev(
            now,
            EventKind::QueueMv,
            &op,
            serde_json::json!({ "from": from, "to": to }),
        )];
        if from == 0 || to == 0 {
            evs.extend(self.retire_head(now, &old_head));
        }
        evs.extend(self.sync_head(now, sound));
        evs
    }

    /// Start working the queue: the head runs with its own lap, and misses count from now.
    pub fn queue_go(&mut self, now: DateTime<Local>, sound: bool) -> Vec<Event> {
        let Some(h) = self.queue.head().cloned() else {
            return vec![];
        };
        let mut evs = vec![];
        if !self.queue.active {
            self.queue.active = true;
            self.queue.lap_base = self.stopwatches.get(&h.op).map_or(0, |s| s.lap_index);
            evs.push(Self::qev(
                now,
                EventKind::QueueGo,
                &h.op,
                serde_json::Value::Null,
            ));
        }
        evs.extend(self.sync_head(now, sound));
        evs
    }

    /// Finish the head task: it leaves the queue and, if the queue is on, the next starts.
    pub fn done(&mut self, now: DateTime<Local>, sound: bool) -> Vec<Event> {
        if self.queue.tasks.is_empty() {
            return vec![];
        }
        let misses = self.queue_misses();
        let t = self.queue.tasks.remove(0);
        let mut evs = vec![Self::qev(
            now,
            EventKind::QueueDone,
            &t.op,
            serde_json::json!({ "misses": misses }),
        )];
        evs.extend(self.retire_head(now, &t.op));
        evs.extend(self.sync_head(now, sound));
        evs
    }

    /// Empty the queue, stopping the head if it is running.
    pub fn queue_clear(&mut self, now: DateTime<Local>) -> Vec<Event> {
        if self.queue.tasks.is_empty() {
            return vec![];
        }
        let mut evs = vec![Self::qev(
            now,
            EventKind::QueueClear,
            "",
            serde_json::Value::Null,
        )];
        if self.queue.active {
            if let Some(h) = self.queue.head().map(|t| t.op.clone()) {
                evs.extend(self.stop_inner(now, &h));
            }
        }
        self.queue = Queue::default();
        evs
    }

    /// Replace the queue with a preset's tasks (stopping a running head). `queue_go`
    /// starts it.
    pub fn queue_load(&mut self, now: DateTime<Local>, name: &str, tasks: Vec<Task>) -> Vec<Event> {
        let mut evs = self.queue_clear(now);
        evs.push(Self::qev(
            now,
            EventKind::QueueLoad,
            "",
            serde_json::json!({ "preset": name, "tasks": tasks.len() }),
        ));
        self.queue.tasks = tasks;
        self.queue.preset = Some(name.to_string());
        evs
    }

    /// Remove a stopwatch from the live snapshot (its events stay in the log).
    pub fn reset(&mut self, now: DateTime<Local>, op: &str) -> Vec<Event> {
        if self.queue.head().map(|t| t.op.as_str()) == Some(op) {
            self.queue.active = false;
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

    fn task(op: &str, len_s: u64) -> Task {
        Task {
            op: op.into(),
            len_s,
        }
    }

    fn queued() -> Snapshot {
        let mut s = Snapshot::default();
        let t = t0();
        s.queue_add(t, task("guitar", 300));
        s.queue_add(t, task("email", 600));
        s.queue_add(t, task("reading", 1500));
        s
    }

    fn head(s: &Snapshot) -> &str {
        s.queue.head().map(|t| t.op.as_str()).unwrap_or("")
    }

    #[test]
    fn go_runs_the_head_with_its_own_lap() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        assert_eq!(s.stopwatches["guitar"].next_lap_countdown_s(t), Some(300));
    }

    #[test]
    fn timeout_repeats_the_same_task_and_counts_a_miss() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        let laps = s.catch_up(at(t, 301));
        assert_eq!(laps.len(), 1);
        assert_eq!(laps[0].op, "guitar");
        // the negative control: a timeout never moves the queue on
        assert_eq!(head(&s), "guitar");
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        assert_eq!(s.queue_misses(), 1);
        assert_eq!(
            s.stopwatches["guitar"].next_lap_countdown_s(at(t, 301)),
            Some(299)
        );
    }

    #[test]
    fn late_poll_counts_every_missed_window_on_the_same_task() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        assert_eq!(s.catch_up(at(t, 950)).len(), 3);
        assert_eq!(head(&s), "guitar");
        assert_eq!(s.queue_misses(), 3);
    }

    #[test]
    fn done_pops_the_head_and_starts_the_next() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.catch_up(at(t, 301));
        let evs = s.done(at(t, 400), false);
        assert!(evs
            .iter()
            .any(|e| e.kind == EventKind::QueueDone && e.op == "guitar"));
        assert_eq!(head(&s), "email");
        assert_eq!(s.active_sw.as_deref(), Some("email"));
        assert_eq!(s.stopwatches["guitar"].state, RunState::Stopped);
        assert_eq!(s.queue_misses(), 0);
        assert_eq!(
            s.stopwatches["email"].next_lap_countdown_s(at(t, 400)),
            Some(600)
        );
    }

    #[test]
    fn done_on_the_last_task_goes_idle() {
        let mut s = Snapshot::default();
        let t = t0();
        s.queue_add(t, task("guitar", 60));
        s.queue_go(t, false);
        s.done(at(t, 10), false);
        assert!(s.queue.tasks.is_empty());
        assert!(!s.queue.active);
        assert_eq!(s.active_sw, None);
        assert_eq!(s.display_op(), None);
    }

    #[test]
    fn a_task_done_twice_starts_fresh_misses() {
        let mut s = Snapshot::default();
        let t = t0();
        s.queue_add(t, task("guitar", 60));
        s.queue_add(t, task("guitar", 60));
        s.queue_go(t, false);
        s.catch_up(at(t, 130));
        assert_eq!(s.queue_misses(), 2);
        s.done(at(t, 130), false);
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        assert_eq!(s.queue_misses(), 0);
    }

    #[test]
    fn rm_and_mv_of_the_head_switch_while_active() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.queue_mv(at(t, 5), 2, 0, false);
        assert_eq!(s.active_sw.as_deref(), Some("reading"));
        s.queue_rm(at(t, 6), 0, false);
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        // a move behind the head changes nothing that runs
        s.queue_mv(at(t, 7), 1, 0, false);
        assert_eq!(s.active_sw.as_deref(), Some("email"));
        s.queue_mv(at(t, 8), 0, 9, false);
        assert_eq!(
            s.queue
                .tasks
                .iter()
                .map(|t| t.op.as_str())
                .collect::<Vec<_>>(),
            ["guitar", "email"]
        );
    }

    #[test]
    fn edits_while_off_never_start_anything() {
        let mut s = queued();
        let t = t0();
        s.queue_rm(t, 0, false);
        s.done(t, false);
        assert_eq!(head(&s), "reading");
        assert!(s.stopwatches.is_empty());
    }

    #[test]
    fn switching_away_takes_the_queue_off_and_go_resumes_it() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.switch(at(t, 30), "phone", None, None);
        assert!(!s.queue.active);
        assert_eq!(head(&s), "guitar");
        assert!(s.catch_up(at(t, 9999)).is_empty());
        s.queue_go(at(t, 9999), false);
        assert_eq!(s.active_sw.as_deref(), Some("guitar"));
        assert_eq!(
            s.stopwatches["guitar"].next_lap_countdown_s(at(t, 9999)),
            Some(300)
        );
    }

    #[test]
    fn an_edit_behind_a_paused_head_keeps_it_paused() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.pause(at(t, 10), "guitar");
        s.queue_rm(at(t, 20), 2, false);
        s.queue_add(at(t, 20), task("walk", 60));
        assert_eq!(s.stopwatches["guitar"].state, RunState::Paused);
    }

    #[test]
    fn clear_stops_the_head_and_empties_the_queue() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.queue_clear(at(t, 10));
        assert!(s.queue.tasks.is_empty());
        assert_eq!(s.stopwatches["guitar"].state, RunState::Stopped);
    }

    #[test]
    fn load_replaces_the_queue_and_keeps_the_preset_name() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.queue_load(
            at(t, 10),
            "practice",
            vec![task("work", 300), task("guitar", 180)],
        );
        assert_eq!(head(&s), "work");
        assert!(!s.queue.active);
        assert_eq!(s.queue.preset.as_deref(), Some("practice"));
        s.queue_go(at(t, 10), false);
        assert_eq!(s.active_sw.as_deref(), Some("work"));
    }

    #[test]
    fn an_old_snapshot_with_a_cycle_still_loads() {
        let old = r#"{"v":1,"active_sw":"work","stopwatches":{},"cycle":{"name":"practice","steps":[{"op":"work","len_s":300}],"idx":0}}"#;
        let s: Snapshot = serde_json::from_str(old).unwrap();
        assert!(s.queue.tasks.is_empty());
    }

    #[test]
    fn resuming_another_op_takes_the_queue_off() {
        let mut s = Snapshot::default();
        let t = t0();
        s.start(t, "email", Some(60), None);
        s.stop(at(t, 10), "email");
        s.queue_add(at(t, 10), task("work", 300));
        s.queue_go(at(t, 10), false);
        s.resume(at(t, 20), "email");
        assert!(!s.queue.active);
        assert_eq!(s.queue.tasks.len(), 1); // the task stays queued
                                            // email's own lap fires as a plain lap; nothing switches back to the head
        s.catch_up(at(t, 80));
        assert_eq!(s.active_sw.as_deref(), Some("email"));
    }

    #[test]
    fn go_on_a_head_started_by_hand_turns_the_queue_on_and_counts_misses_from_there() {
        let mut s = queued();
        let t = t0();
        s.start(t, "guitar", Some(300), None);
        s.catch_up(at(t, 601)); // two laps before the queue was on
        let evs = s.queue_go(at(t, 601), false);
        assert!(evs.iter().any(|e| e.kind == EventKind::QueueGo));
        assert!(s.queue.active);
        assert_eq!(s.queue_misses(), 0);
    }

    #[test]
    fn a_manual_lap_on_the_head_is_not_a_miss() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.lap(at(t, 100), "guitar");
        assert_eq!(s.queue_misses(), 0);
        s.catch_up(at(t, 401)); // its own timeout still counts
        assert_eq!(s.queue_misses(), 1);
    }

    #[test]
    fn removing_the_head_onto_an_identical_task_starts_it_fresh() {
        let mut s = Snapshot::default();
        let t = t0();
        s.queue_add(t, task("guitar", 300));
        s.queue_add(t, task("guitar", 300));
        s.queue_go(t, false);
        s.catch_up(at(t, 301));
        assert_eq!(s.queue_misses(), 1);
        s.queue_rm(at(t, 350), 0, false);
        assert_eq!(s.queue_misses(), 0);
        assert_eq!(
            s.stopwatches["guitar"].next_lap_countdown_s(at(t, 350)),
            Some(300)
        );
    }

    #[test]
    fn moving_a_task_onto_the_head_starts_it_fresh() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.queue_mv(at(t, 50), 2, 0, false);
        assert_eq!(s.active_sw.as_deref(), Some("reading"));
        assert_eq!(s.stopwatches["guitar"].state, RunState::Stopped);
    }

    #[test]
    fn switching_to_the_head_with_another_lap_takes_the_queue_off() {
        let mut s = queued();
        let t = t0();
        s.queue_go(t, false);
        s.switch(at(t, 10), "guitar", Some(1500), None);
        assert!(!s.queue.active);
        s.queue_go(at(t, 20), false); // go puts it back on its own 5m
        assert_eq!(s.stopwatches["guitar"].lap_len_s, Some(300));
    }
}
