//! agent-panel as a library: the pane x `~/.claude/sessions` join and the tmux
//! wrappers, shared by the `agent-panel` chooser and the `agent-web` server so
//! neither re-implements session discovery and drifts.

pub mod account;
pub mod asks;
pub mod chooser;
pub mod fzf;
pub mod jsonl;
pub mod parked;
pub mod procmap;
pub mod render;
pub mod send;
pub mod session;
pub mod sort;
pub mod tmux;
pub mod vocab;
