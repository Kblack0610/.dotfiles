//! agent-panel as a library: the chooser's own modules (fzf wiring, rows, sorts, the dialog
//! card). Every session fact it shows comes from `agent_core`, the layer hub-core and agent-web
//! read too, so the panel only renders.

pub mod callbacks;
pub mod card;
pub mod chooser;
pub mod dispatched;
pub mod fzf;
pub mod help;
pub mod md;
pub mod render;
pub mod search;
pub mod sort;

/// A send or answer whose pane another sender held past the wait (`send::Busy`) exits
/// `send::BUSY_EXIT` with the reason on stderr, so a caller can tell it from a failed send:
/// nothing was typed. Anything else passes through.
pub fn or_busy_exit<T>(r: anyhow::Result<T>) -> anyhow::Result<T> {
    let busy = r
        .as_ref()
        .err()
        .and_then(|e| e.downcast_ref::<agent_core::send::Busy>());
    if let Some(busy) = busy {
        eprintln!("agent-panel: {busy}");
        std::process::exit(agent_core::send::BUSY_EXIT);
    }
    r
}
