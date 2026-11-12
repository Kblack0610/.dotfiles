//! Sessions' Runners inner tab: hub-core's `fleet`, shared with the TUI. It is all files, read on
//! every request, so a file event shows at once. A runner's page (`/api/fleet/runner?name=`) is
//! read only when it is opened. The accounts, tokens and Langfuse are the Costs tab's (costs.rs).

use hub_core::fleet::{self, who::Who, Fleet, Paths};
use hub_core::table::View;
use serde::Deserialize;

use crate::cache::off;

/// The table view the page keeps in its URL. Runners shares `#sessions?...` with the Sessions
/// table, so its keys carry the `r` prefix (`rq`, `rs`, `rsort`, `rdir`; table.js `pre`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct FleetQuery {
    pub rq: String,
    pub rs: String,
    pub rsort: String,
    pub rdir: String,
}

/// A runners read. The files are read afresh each time, so there is nothing to keep.
pub async fn get(q: FleetQuery) -> String {
    let f = off(|| fleet::files(&Paths::from_env()))
        .await
        .unwrap_or_else(|e| Fleet {
            errors: vec![e],
            ..Default::default()
        });
    render(f, &q)
}

/// The Fleet with its `who` rows cut to the view, and the controls that drew them (`table`).
fn render(mut f: Fleet, q: &FleetQuery) -> String {
    let view = View::new::<Who>(&q.rq, &q.rs, &q.rsort, &q.rdir);
    let all = std::mem::take(&mut f.who);
    let (rows, table) = view.summary(&all);
    let out = serde_json::to_value(&f).map(|mut v| {
        v["who"] = serde_json::json!(rows);
        v["table"] = serde_json::json!(table);
        v
    });
    out.and_then(|v| serde_json::to_string(&v))
        .unwrap_or_else(|e| {
            serde_json::json!({"errors": [e.to_string()], "workers": [], "who": []}).to_string()
        })
}

/// One runner's page, read only when `#sessions/runners/<name>` opens. An unknown name is the
/// caller's 404.
pub async fn runner(name: String) -> Result<String, String> {
    let r = off(move || fleet::runner::read(&Paths::from_env(), &name)).await??;
    serde_json::to_string(&r).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(tier: u8, who: &str, state: &str) -> Who {
        Who {
            tier,
            kind: if tier == 1 { "lead" } else { "observe" }.into(),
            who: who.into(),
            state: state.into(),
            since: None,
            cost_24h: None,
            cost_estimated: false,
            purpose: String::new(),
            doing: String::new(),
            under: String::new(),
        }
    }

    fn fleet() -> Fleet {
        Fleet {
            who: vec![row(1, "shepherd", "working"), row(2, "briefing", "failed")],
            ..Fleet::default()
        }
    }

    fn read(q: &FleetQuery) -> serde_json::Value {
        serde_json::from_str(&render(fleet(), q)).unwrap()
    }

    #[test]
    fn each_row_links_its_runner_page_on_sessions_runners() {
        let v = read(&FleetQuery::default());
        assert_eq!(v["who"].as_array().unwrap().len(), 2);
        assert_eq!(v["table"]["shown"], 2);
        assert_eq!(
            v["table"]["links"],
            serde_json::json!([{"who": "#sessions/runners/shepherd"}, {"who": "#sessions/runners/briefing"}])
        );
    }

    #[test]
    fn the_view_is_read_from_the_r_prefixed_keys() {
        let v = read(&FleetQuery {
            rs: "failed".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["who"][0]["who"], "briefing");
        assert_eq!(v["table"]["links"][0]["who"], "#sessions/runners/briefing");
        let v = read(&FleetQuery {
            rq: "shep".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"][0]["who"], "shepherd");
    }
}
