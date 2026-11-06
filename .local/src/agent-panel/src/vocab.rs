//! The bucket vocabulary state.json carries (`vocab`), written once by `fleet-sessions --write`:
//! the order the buckets list in, and which of them are in progress. Nothing here names a
//! bucket, so a surface that needs the order or a set reads it from the document it already has.
//! A document with no `vocab` (one written before it existed) gives an empty one: no order and
//! no bucket in progress, until the next pass writes it. It lives in agent-panel, which hub-core
//! depends on, so the chooser's Stage sort and every hub surface read it through one type.

use std::fs;
use std::path::PathBuf;

use serde_json::Value;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Vocab {
    buckets: Vec<String>,
    in_progress: Vec<String>,
}

fn names(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// fleet-sessions' state document: `$FLEET_STATE_FILE`, else `fleet/state.json` under the state home.
pub fn fleet_state_file() -> PathBuf {
    let set = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    set("FLEET_STATE_FILE").unwrap_or_else(|| {
        set("XDG_STATE_HOME")
            .or_else(|| set("HOME").map(|h| h.join(".local/state")))
            .unwrap_or_default()
            .join("fleet/state.json")
    })
}

impl Vocab {
    /// The vocabulary of the state document on disk; empty when it is missing or unreadable.
    pub fn read() -> Vocab {
        let doc: Value = fs::read_to_string(fleet_state_file())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Vocab::from_state(&doc)
    }

    /// The vocabulary of the whole state document.
    pub fn from_state(state: &Value) -> Vocab {
        Vocab {
            buckets: names(&state["vocab"]["buckets"]),
            in_progress: names(&state["vocab"]["in_progress"]),
        }
    }

    /// The buckets, in order.
    pub fn buckets(&self) -> &[String] {
        &self.buckets
    }

    /// A bucket's place in the order; one the order does not name sorts last.
    pub fn rank(&self, bucket: &str) -> usize {
        self.buckets
            .iter()
            .position(|b| b == bucket)
            .unwrap_or(self.buckets.len())
    }

    /// Whether a session in `bucket` is at work, so an ETA means something.
    pub fn in_progress(&self, bucket: &str) -> bool {
        self.in_progress.iter().any(|b| b == bucket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_order_and_the_set_come_from_the_document() {
        let v = Vocab::from_state(&json!({"vocab": {
            "buckets": ["NEEDS", "WORKING"], "in_progress": ["WORKING"]}}));
        assert_eq!((v.rank("NEEDS"), v.rank("WORKING"), v.rank("X")), (0, 1, 2));
        assert!(v.in_progress("WORKING") && !v.in_progress("NEEDS"));
    }

    #[test]
    fn a_document_without_one_has_no_order_and_nothing_in_progress() {
        let v = Vocab::from_state(&json!({"sessions": []}));
        assert_eq!((v.rank("NEEDS"), v.in_progress("WORKING")), (0, false));
    }
}
