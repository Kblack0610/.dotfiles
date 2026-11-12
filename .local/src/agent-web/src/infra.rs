//! The Infra tab: the hub board's infra pages (`hub`, Prefix i) for the browser. The questions
//! and the judging of the answer are hub-core's `infra::gather`, shared with the TUI, and so are
//! its tables (machines, pools, CI slots, queued jobs, finished runs); this module caches the
//! answer and applies each table's view from the page's URL.

use std::collections::HashMap;
use std::sync::Arc;

use hub_core::infra::Infra;
use hub_core::table::{Row, View};
use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::cache::{off, ReadCache};

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again. Alertmanager is asked in the same gather, so
/// this is its cadence too.
const CACHE_SECS: u64 = 30;

/// The tables on the tab and the prefix of each one's view keys in the URL (`mq`, `ms`, `msort`,
/// `mdir` for Machines); infra.js `INFRA_TABLES` names the same. Jobs keeps the plain keys.
pub const TABLES: [(&str, &str); 5] = [
    ("machines", "m"),
    ("pools", "p"),
    ("runners", "r"),
    ("queued", "w"),
    ("finished", "f"),
];

/// The page's URL query: every table's view keys, by their prefix.
pub type ViewQuery = HashMap<String, String>;

/// The last answer beside its JSON less the CI lists, made once per fill; kept as a failed
/// gather is, inside the answer. A panic in the gather is shown, not kept.
#[derive(Default)]
pub struct Cache(ReadCache<(Infra, Map<String, Value>), CACHE_SECS>);

/// One table's rows under its view, and the controls that drew them.
fn shown<R: Row + Serialize>(rows: &[R], q: &ViewQuery, pre: &str) -> Value {
    let k = |n: &str| q.get(&format!("{pre}{n}")).map_or("", String::as_str);
    let (rows, table) = View::new::<R>(k("q"), k("s"), k("sort"), k("dir")).summary(rows);
    json!({ "rows": rows, "table": table })
}

/// The answer as JSON less the CI lists, which ride only in `tables`: once per cache fill.
fn with_base(infra: Infra) -> (Infra, Map<String, Value>) {
    let mut base = match serde_json::to_value(&infra) {
        Ok(Value::Object(m)) => m,
        Ok(_) => Map::new(),
        Err(e) => json!({"ok": false, "error": e.to_string()})
            .as_object()
            .cloned()
            .unwrap_or_default(),
    };
    if let Some(ci) = base.get_mut("ci").and_then(Value::as_object_mut) {
        for k in ["rows", "queue", "finished"] {
            ci.remove(k);
        }
    }
    (infra, base)
}

/// The cached base with each table under the page's view: the base is written, not copied.
#[derive(Serialize)]
struct Body<'a> {
    #[serde(flatten)]
    base: &'a Map<String, Value>,
    tables: Map<String, Value>,
}

/// The answer as JSON with each table under its view (`tables`).
pub fn render(infra: &Infra, base: &Map<String, Value>, q: &ViewQuery) -> String {
    let mut tables = Map::new();
    for (name, pre) in TABLES {
        let t = match name {
            "machines" => shown(&infra.machines, q, pre),
            "pools" => shown(&infra.pools, q, pre),
            "runners" => shown(&infra.ci.rows, q, pre),
            "queued" => shown(&infra.ci.queue, q, pre),
            _ => shown(&infra.ci.finished, q, pre),
        };
        tables.insert(name.into(), t);
    }
    serde_json::to_string(&Body { base, tables })
        .unwrap_or_else(|e| json!({"ok": false, "error": e.to_string()}).to_string())
}

impl Cache {
    async fn answer(&self) -> Arc<(Infra, Map<String, Value>)> {
        let read = async { off(hub_core::infra::gather).await.map(with_base) };
        self.0.get((), read).await.unwrap_or_else(|e| {
            Arc::new(with_base(Infra {
                error: Some(e),
                ..Default::default()
            }))
        })
    }

    /// The Infra tab's answer with the page's views, as JSON.
    pub async fn get(&self, q: ViewQuery) -> String {
        let a = self.answer().await;
        off(move || render(&a.0, &a.1, &q))
            .await
            .unwrap_or_else(|e| json!({"ok": false, "error": e}).to_string())
    }

    /// The same answer for Home's health strip and red-now rows.
    pub async fn infra(&self) -> Infra {
        self.answer().await.0.clone()
    }

    /// The rates in the same answer, for the Builds section's prices.
    pub async fn rates(&self) -> hub_core::run_detail::Rates {
        self.answer().await.0.rates()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each table reads its own prefixed keys, and the CI lists are sent once, as tables.
    #[test]
    fn each_infra_table_takes_its_own_view() {
        let mut infra = Infra {
            ok: true,
            ..Default::default()
        };
        infra.machines = vec![
            hub_core::machines::Machine {
                host: "a".into(),
                place: "cloud".into(),
                ..Default::default()
            },
            hub_core::machines::Machine {
                host: "b".into(),
                place: "local".into(),
                ..Default::default()
            },
        ];
        let q: ViewQuery = [("ms", "cloud"), ("ps", "waiting")]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let (infra, base) = with_base(infra);
        let out: Value = serde_json::from_str(&render(&infra, &base, &q)).unwrap();
        let m = &out["tables"]["machines"];
        assert_eq!(m["table"]["state"], "cloud");
        assert_eq!(m["rows"].as_array().unwrap().len(), 1);
        assert_eq!(m["rows"][0]["where"], "cloud");
        assert_eq!(out["tables"]["pools"]["table"]["state"], "waiting");
        assert_eq!(out["tables"]["runners"]["table"]["state"], "");
        for (name, _) in TABLES {
            assert!(out["tables"][name]["table"].is_object(), "{name}");
        }
        assert!(out["ci"].get("rows").is_none());
        assert!(out["ci"]["done"].is_object());
    }
}
