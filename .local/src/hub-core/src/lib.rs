//! What the hub boards read, shared by agent-web and the hub TUI so the two surfaces cannot
//! disagree. Everything here is synchronous and shells out to the tools that own the data
//! (curl for Prometheus, systemctl and journalctl, gh); an async caller wraps it in
//! `spawn_blocking`.

pub mod infra;
pub mod jobs;
pub mod prom;
