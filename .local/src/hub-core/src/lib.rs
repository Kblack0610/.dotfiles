//! What the hub boards read and the session actions they offer, shared by agent-web and the
//! hub TUI so the two surfaces cannot disagree. Everything here is synchronous and shells out
//! to the tools that own the data (curl for Prometheus, systemctl and journalctl, gh,
//! claude-acct, agent-queue, tmux); an async caller wraps it in `spawn_blocking`.

pub mod actions;
pub mod boards;
pub mod capacity;
pub mod epics;
pub mod fleet;
pub mod focus;
pub mod home;
pub mod infra;
pub mod jobs;
pub mod layout;
pub mod outbox;
pub mod outcomes;
pub mod page;
pub mod pager;
pub mod phone;
pub mod pipeline;
pub mod projects;
pub mod prom;
pub mod proposals;
pub mod queue;
pub mod reds;
pub mod schedules;
pub mod session_actions;
pub mod session_page;
pub mod session_table;
pub mod table;
pub mod tasks;
pub mod text;
pub mod vocab;
