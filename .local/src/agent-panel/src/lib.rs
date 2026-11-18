//! agent-panel as a library: the chooser's own modules (fzf wiring, rows, sorts, the dialog
//! card). Every session fact it shows comes from `agent_core`, the layer hub-core and agent-web
//! read too, so the panel only renders.

pub mod card;
pub mod chooser;
pub mod dispatched;
pub mod fzf;
pub mod help;
pub mod md;
pub mod render;
pub mod search;
pub mod sort;
