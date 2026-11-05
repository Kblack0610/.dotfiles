//! What the hub boards read and the session actions they offer, shared by agent-web and the
//! hub TUI so the two surfaces cannot disagree. Everything here is synchronous and shells out
//! to the tools that own the data (curl for Prometheus, systemctl and journalctl, gh,
//! claude-acct, agent-queue, tmux); an async caller wraps it in `spawn_blocking`.

pub mod actions;
pub mod boards;
pub mod fleet;
pub mod focus;
pub mod home;
pub mod infra;
pub mod jobs;
pub mod layout;
pub mod phone;
pub mod projects;
pub mod prom;
pub mod queue;
pub mod session_actions;
pub mod tasks;
pub mod text;
