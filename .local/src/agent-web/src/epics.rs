//! The one `fleet-bench epics --json` read over every project, kept for `EPICS_SECS`. Its
//! forecast places every queue item on the dispatcher's slots, so it takes about 9s whatever
//! project is asked for, and an epic moves in hours: the Deliverables section and every project
//! page take their chains from this one read instead of each running it.

use std::sync::Arc;

use hub_core::epics::{self, Chain};
use hub_core::session_actions::System;

use crate::cache::{off, ReadCache};

const EPICS_SECS: u64 = 120;

static LAST: ReadCache<Vec<Chain>, EPICS_SECS> = ReadCache::new();

/// Every project's chain. A failed read is handed back and not kept, so the next one tries again.
pub async fn chains() -> Result<Arc<Vec<Chain>>, String> {
    LAST.get((), async { off(|| epics::all(&System)).await? })
        .await
}

/// Drop the kept read after a board or queue write from this server, so the page that wrote
/// shows its own change instead of a chain up to `EPICS_SECS` old.
pub async fn clear() {
    LAST.clear().await;
}
