//! `timebox-core` — the pure logic of the timebox tool, shared by the CLI today
//! and the Phase-2 HTTP API / Phase-3 web backend tomorrow.
//!
//! Design invariant: **elapsed time is computed, never ticked**. A stopwatch stores
//! an anchor (`started_at`) plus banked seconds (`accumulated_s`); its elapsed time is
//! `accumulated_s + (now - started_at)` while running. Recurring laps are likewise a
//! pure function of elapsed time, so pausing a stopwatch pauses its lap cadence for
//! free and nothing needs to run in the background to keep time.

pub mod dur;
pub mod event;
pub mod state;
pub mod stats;
pub mod store;

pub use event::{Event, EventKind};
pub use state::{RunState, Snapshot, Stopwatch};
