//! The Fleet tab: hub-core's `fleet`, shared with the TUI. It is all files, read on every
//! request, so a file event shows at once. A runner's page (`/api/fleet/runner?name=`) is read
//! only when it is opened. The accounts, tokens and Langfuse are the Costs tab's (costs.rs).

use std::collections::HashSet;

use hub_core::fleet::{self, who, who::Who, Fleet, Paths};
use hub_core::table::View;
use serde::Deserialize;

use crate::cache::off;

/// The table view the page keeps in its URL (`q`, `s`, `sort`, `dir`, as every table's) and the
/// tier 1 rows it has folded (`fold`, comma-separated runner names).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct FleetQuery {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
    pub fold: String,
}

/// A Fleet read. The files are read afresh each time, so there is nothing to keep.
pub async fn get(q: FleetQuery) -> String {
    let f = off(|| fleet::files(&Paths::from_env()))
        .await
        .unwrap_or_else(|e| Fleet {
            errors: vec![e],
            ..Default::default()
        });
    render(f, &q)
}

/// The Fleet with its `who` rows cut to the view and folds, and the controls that drew them
/// (`table`; `hidden` is how many rows the folds hold back).
fn render(mut f: Fleet, q: &FleetQuery) -> String {
    let view = View::new::<Who>(&q.q, &q.s, &q.sort, &q.dir);
    let all = std::mem::take(&mut f.who);
    let (rows, table) = view.summary(&all);
    let folded: HashSet<String> = q
        .fold
        .split(',')
        .filter(|n| !n.is_empty())
        .map(String::from)
        .collect();
    let shown = who::unfolded(rows.clone(), &folded, &view);
    let hidden = rows.len() - shown.len();
    let out = serde_json::to_value(&f).map(|mut v| {
        v["who"] = serde_json::json!(shown);
        v["table"] = serde_json::json!(table);
        v["table"]["shown"] = shown.len().into();
        v["hidden"] = hidden.into();
        v
    });
    out.and_then(|v| serde_json::to_string(&v))
        .unwrap_or_else(|e| {
            serde_json::json!({"errors": [e.to_string()], "workers": [], "who": []}).to_string()
        })
}

/// One runner's page, read only when `#fleet/<name>` opens. An unknown name is the caller's 404.
pub async fn runner(name: String) -> Result<String, String> {
    let r = off(move || fleet::runner::read(&Paths::from_env(), &name)).await??;
    serde_json::to_string(&r).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::fleet::who::Opens;

    fn row(tier: u8, key: &str, parent: Option<&str>, kids: usize) -> Who {
        Who {
            tier,
            who: key.into(),
            opens: if tier == 3 {
                Opens::Session
            } else {
                Opens::Runner
            },
            key: key.into(),
            state: "working".into(),
            since: None,
            doing: String::new(),
            under: String::new(),
            project: "dotfiles".into(),
            parent: parent.map(String::from),
            kids,
        }
    }

    fn fleet() -> Fleet {
        Fleet {
            who: vec![
                row(1, "shepherd", None, 1),
                row(3, "lab/a:1", Some("shepherd"), 0),
            ],
            ..Fleet::default()
        }
    }

    fn q(fold: &str, text: &str) -> FleetQuery {
        FleetQuery {
            fold: fold.into(),
            q: text.into(),
            ..FleetQuery::default()
        }
    }

    fn who_of(out: &str) -> serde_json::Value {
        serde_json::from_str(out).unwrap()
    }

    #[test]
    fn a_folded_tier_one_row_hides_its_children_and_the_page_says_how_many() {
        let v = who_of(&render(fleet(), &q("shepherd", "")));
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["hidden"], 1);
        assert!(v["table"].is_object());
    }

    #[test]
    fn a_search_shows_a_hit_even_under_a_folded_row() {
        let v = who_of(&render(fleet(), &q("shepherd", "lab")));
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["who"][0]["key"], "lab/a:1");
        assert_eq!(v["hidden"], 0);
    }
}
