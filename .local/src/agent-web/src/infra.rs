//! The Infra tab: the hub board's infra pages (`hub`, Prefix i) for the browser. The questions
//! and the judging of the answer are hub-core's `infra::gather`, shared with the TUI, and so are
//! its tables (machines, pools, CI slots, queued jobs, finished runs); this module caches the
//! answer and applies each table's view from the page's URL.

use std::collections::HashMap;
use std::sync::Arc;

use axum::http::StatusCode;
use hub_core::infra::Infra;
use hub_core::machine_page::{self, MachinePage};
use hub_core::pool_page::{self, PoolPage};
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

/// One machine's page (`hub_core::machine_page`), kept for the host last asked for: its history
/// is three week-long range queries and its recent jobs a pass over the jobs archive, so a reload
/// or the page's own refresh inside `CACHE_SECS` is served the last read.
#[derive(Default)]
pub struct Pages(ReadCache<String, CACHE_SECS, String>);

/// The page, its lists sent once: as tables with their rows and links (`shown`, in their own
/// order), not also as the page's own fields.
fn page_json(p: &MachinePage) -> String {
    let none = ViewQuery::new();
    let down = p.history.as_ref().map_or(&[][..], |h| h.down.as_slice());
    with_tables(
        p,
        [
            ("recent", shown(&p.recent, &none, "")),
            ("down", shown(down, &none, "")),
            ("alerts", shown(&p.alerts, &none, "")),
        ],
        |o| {
            if let Some(h) = o.get_mut("history").and_then(Value::as_object_mut) {
                h.remove("down");
            }
        },
    )
}

/// A page as JSON with each of `tables` in place of its own field of that name, and `also`
/// for any other field a table replaces.
fn with_tables<const N: usize>(
    p: &impl Serialize,
    tables: [(&str, Value); N],
    also: impl FnOnce(&mut Map<String, Value>),
) -> String {
    let mut v = match serde_json::to_value(p) {
        Ok(v) => v,
        Err(e) => return json!({"error": e.to_string()}).to_string(),
    };
    if let Some(o) = v.as_object_mut() {
        also(o);
        let mut t = Map::new();
        for (k, rows) in tables {
            o.remove(k);
            t.insert(k.into(), rows);
        }
        o.insert("tables".into(), Value::Object(t));
    }
    v.to_string()
}

impl Pages {
    /// `#infra/machines/<host>`'s read: a name no machine has is a 404, and is not kept.
    pub async fn get(
        &self,
        infra: &Cache,
        alerts: &crate::alerts::Cache,
        host: String,
    ) -> Result<String, (StatusCode, String)> {
        let read = async {
            let i = infra.infra().await;
            let firing = alerts.firing(infra).await;
            let h = host.clone();
            let now = hub_core::jobs::now().max(0) as u64;
            let jobs = hub_core::builds::Paths::from_env().jobs;
            off(move || {
                machine_page::read(&i, &h, firing.as_deref().map_err(Clone::clone), &jobs, now)
                    .map(|p| page_json(&p))
            })
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
            .map_err(|e| (StatusCode::NOT_FOUND, e))
        };
        self.0.get(host.clone(), read).await.map(|s| (*s).clone())
    }
}

/// One pool's page (`hub_core::pool_page`), kept for the pool last asked for: its history is
/// three week-long range queries, so a reload inside `CACHE_SECS` is served the last read.
#[derive(Default)]
pub struct PoolPages(ReadCache<String, CACHE_SECS, String>);

/// The page, its machines and waiting jobs sent once, as tables (`shown`, in their own order).
fn pool_json(p: &PoolPage) -> String {
    let none = ViewQuery::new();
    with_tables(
        p,
        [
            ("machines", shown(&p.machines, &none, "")),
            ("waiting", shown(&p.waiting, &none, "")),
        ],
        |_| {},
    )
}

impl PoolPages {
    /// `#infra/pools/<pool>`'s read: a name no pool has is a 404, and is not kept.
    pub async fn get(&self, infra: &Cache, name: String) -> Result<String, (StatusCode, String)> {
        let read = async {
            let i = infra.infra().await;
            let n = name.clone();
            let now = hub_core::jobs::now().max(0) as u64;
            off(move || pool_page::read(&i, &n, now).map(|p| pool_json(&p)))
                .await
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
                .map_err(|e| (StatusCode::NOT_FOUND, e))
        };
        self.0.get(name.clone(), read).await.map(|s| (*s).clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A machine page sends its lists once, as tables.
    #[test]
    fn a_machine_page_sends_its_lists_once_as_tables() {
        let p = MachinePage {
            host: "ws".into(),
            recent: vec![hub_core::machine_page::RecentJob {
                job: "bats".into(),
                ..Default::default()
            }],
            history: Some(hub_core::host_history::HostHistory::default()),
            ..Default::default()
        };
        let v: Value = serde_json::from_str(&page_json(&p)).unwrap();
        assert_eq!(v["host"], "ws");
        assert!(v.get("recent").is_none() && v.get("alerts").is_none());
        assert!(v["history"].get("down").is_none() && v["history"].get("hours").is_some());
        assert_eq!(v["tables"]["recent"]["rows"][0]["job"], "bats");
        assert!(v["tables"]["down"]["rows"].is_array() && v["tables"]["alerts"]["rows"].is_array());
    }

    /// A pool page sends its machines and waiting jobs once, as tables.
    #[test]
    fn a_pool_page_sends_its_lists_once_as_tables() {
        let p = PoolPage {
            pool: "unity".into(),
            machines: vec![hub_core::machines::Machine {
                host: "ws".into(),
                ..Default::default()
            }],
            waiting: vec![hub_core::ci::Queued {
                job: "Tests".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v: Value = serde_json::from_str(&pool_json(&p)).unwrap();
        assert_eq!(v["pool"], "unity");
        assert!(v.get("machines").is_none() && v.get("waiting").is_none());
        assert_eq!(v["tables"]["machines"]["rows"][0]["host"], "ws");
        assert_eq!(
            v["tables"]["machines"]["table"]["links"][0]["machine"],
            "#infra/machines/ws"
        );
        assert_eq!(v["tables"]["waiting"]["rows"][0]["job"], "Tests");
    }

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
