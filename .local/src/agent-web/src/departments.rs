//! Projects > Coverage an        failing: c.failing(), a product's department tabs, from `hub_core::departments` (the grid
//! and words the hub TUI draws). `/api/coverage` is the grid (`cq`, `cs`, `csort`, `cdir`);
//! `/api/projects/{name}/departments` is one product's five tabs. Both narrow one kept read.

use std::collections::BTreeMap;
use std::sync::Arc;

use axum::extract::{Path, Query};
use axum::Json;
use hub_core::departments::{self, Coverage, Paths, Product};
use hub_core::table::{links, Summary, View};
use serde::{Deserialize, Serialize};

use crate::cache::{off, ReadCache};

/// One read probes every product's privacy, support and terms URLs; five minutes keeps a page
/// of clicks from re-probing them, and the TUI reads on its own.
const CACHE_SECS: u64 = 300;
static READ: ReadCache<Coverage, CACHE_SECS> = ReadCache::new();

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CoverageQuery {
    cq: String,
    cs: String,
    csort: String,
    cdir: String,
}

/// A grid row: the product and its five cells, not the tabs behind them.
#[derive(Serialize)]
struct GridRow<'a> {
    key: String,
    profile: &'a str,
    name: &'a str,
    #[serde(rename = "type")]
    kind: &'a str,
    stage: &'a str,
    cells: BTreeMap<&'static str, &'static str>,
}

#[derive(Serialize)]
struct Grid<'a> {
    rows: Vec<GridRow<'a>>,
    head: String,
    says: &'a [String],
    red: usize,
    amber: usize,
    off: usize,
    /// Products with a red cell: the strip's count.
    failing: usize,
    departments: Vec<[&'static str; 2]>,
    table: Summary,
}

fn grid(c: &Coverage, q: &CoverageQuery) -> serde_json::Value {
    let view = View::new::<Product>(&q.cq, &q.cs, &q.csort, &q.cdir);
    let (rows, mut table) = view.summary(&c.products);
    table.links = links(&rows);
    serde_json::to_value(Grid {
        rows: rows
            .iter()
            .map(|p| GridRow {
                key: p.key(),
                profile: &p.profile,
                name: &p.name,
                kind: &p.kind,
                stage: &p.stage,
                cells: p.depts.iter().map(|d| (d.id, d.cell.word())).collect(),
            })
            .collect(),
        head: c.head(),
        says: &c.says,
        red: c.red,
        amber: c.amber,
        off: c.off,
        failing: c
            .products
            .iter()
            .filter(|p| p.depts.iter().any(|d| d.cell == departments::Cell::Red))
            .count(),
        departments: departments::DEPARTMENTS.map(|d| [d.id, d.title]).to_vec(),
        table,
    })
    .unwrap_or_default()
}

#[derive(Serialize)]
struct Tabs<'a> {
    product: Option<&'a Product>,
    says: String,
}

/// One product's tabs; `says` tells why there are none (not a product, or a store not read).
fn tabs<'a>(c: &'a Coverage, key: &str) -> Tabs<'a> {
    let product = c.product(key);
    let says = match (product, c.says.is_empty()) {
        (Some(_), _) => String::new(),
        (None, false) => c.says.join(" "),
        (None, true) => format!("{key} is not a product: no game or app type in project-map.json"),
    };
    Tabs { product, says }
}

async fn current() -> Arc<Coverage> {
    let read = READ
        .get((), async {
            off(|| departments::read(&hub_core::session_actions::System, &Paths::from_env())).await
        })
        .await;
    // `off` fails only when the blocking task panicked; each store's own failure is in `says`.
    read.unwrap_or_else(|e| {
        Arc::new(Coverage {
            says: vec![format!("{}: {e}", hub_core::reading::NOT_READ)],
            ..Default::default()
        })
    })
}

pub async fn get(Query(q): Query<CoverageQuery>) -> Json<serde_json::Value> {
    Json(grid(&*current().await, &q))
}

pub async fn get_project(Path(name): Path<String>) -> Json<serde_json::Value> {
    let c = current().await;
    Json(serde_json::to_value(tabs(&c, &name)).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::departments::{Cell, Dept, DEPARTMENTS};

    fn coverage() -> Coverage {
        let p = |name: &str, legal: Cell| Product {
            profile: "bnb".into(),
            name: name.into(),
            stage: "beta".into(),
            kind: "app".into(),
            stage_rank: Some(3),
            depts: DEPARTMENTS
                .iter()
                .map(|d| Dept {
                    id: d.id,
                    title: d.title,
                    cell: if d.id == "legal" { legal } else { Cell::Off },
                    ..Default::default()
                })
                .collect(),
        };
        Coverage {
            products: vec![p("listed", Cell::Red), p("quiet", Cell::Off)],
            red: 1,
            off: 9,
            ..Default::default()
        }
    }

    #[test]
    fn the_grid_narrows_by_state_and_links_each_cell_to_its_tab() {
        let c = coverage();
        let all = grid(&c, &CoverageQuery::default());
        assert_eq!(all["rows"].as_array().unwrap().len(), 2);
        assert_eq!(all["head"], "1 red  |  9 off");
        assert_eq!(all["failing"], 1);
        assert_eq!(all["rows"][0]["cells"]["legal"], "red");
        assert_eq!(all["departments"][2], serde_json::json!(["legal", "Legal"]));
        let red = grid(
            &c,
            &CoverageQuery {
                cs: "red".into(),
                ..Default::default()
            },
        );
        assert_eq!(red["rows"].as_array().unwrap().len(), 1);
        let links = red["table"]["links"].to_string();
        assert!(links.contains("#projects/bnb%2Flisted%2Flegal"), "{links}");
    }

    #[test]
    fn a_tab_read_names_its_product_or_says_why_it_has_none() {
        let c = coverage();
        assert_eq!(
            tabs(&c, "bnb/listed").product.map(|p| p.name.as_str()),
            Some("listed")
        );
        assert_eq!(
            tabs(&c, "listed").product.map(|p| p.name.as_str()),
            Some("listed")
        );
        let none = tabs(&c, "agent-runtime");
        assert!(none.product.is_none());
        assert!(none.says.contains("not a product"), "{}", none.says);
    }
}
