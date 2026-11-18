//! The agent session layer: every fact about a live agent session, read once and defined once,
//! with no UI. The agent panel (the Prefix+g chooser), hub-core (and through it the hub TUI) and
//! agent-web all read sessions through this crate, so no view re-implements session discovery,
//! transcript rules or the `list --json` contract and drifts.

pub mod account;
pub mod agent;
pub mod asks;
pub mod dialog;
pub mod jsonl;
pub mod names;
pub mod parked;
pub mod procmap;
pub mod send;
pub mod session;
pub mod tmux;
pub mod vocab;
