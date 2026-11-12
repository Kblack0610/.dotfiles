//! The Fleet tab: hub-core's `fleet`, shared with the TUI. It is all files, read on every
//! request, so a file event shows at once. A runner's page (`/api/fleet/runner?name=`) is read
//! only when it is opened. The accounts, tokens and Langfuse are the Costs tab's (costs.rs).
//! The answer judge's verdicts are a table of their own under the `v` key prefix (`vq`, `vs`,
//! `vsort`, `vdir`), on Log's Judges section and on the ask-judge runner page alike.

use std::collections::HashSet;

use hub_core::fleet::{self, who, who::Who, AskVerdict, Fleet, Paths};
use hub_core::layout::FOLD_ROWS;
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
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
}

/// The answer judge's verdicts' view, under the `v` prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct VerdictQuery {
    pub vq: String,
    pub vs: String,
    pub vsort: String,
    pub vdir: String,
}

impl VerdictQuery {
    fn view(&self) -> View {
        View::new::<AskVerdict>(&self.vq, &self.vs, &self.vsort, &self.vdir)
    }
}

/// A runner's page: its name, required (a request without one is a 400), and the verdicts' view
/// when it is the answer judge's.
#[derive(Deserialize)]
pub struct RunnerQuery {
    pub name: String,
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
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
/// (`table`; `hidden` is how many rows the folds hold back), and the verdicts Log lists.
fn render(mut f: Fleet, q: &FleetQuery) -> String {
    f.judge.view(&q.verdicts.view(), FOLD_ROWS);
    let view = View::new::<Who>(&q.q, &q.s, &q.sort, &q.dir);
    let all = std::mem::take(&mut f.who);
    let (rows, mut table) = view.summary(&all);
    let folded: HashSet<String> = q
        .fold
        .split(',')
        .filter(|n| !n.is_empty())
        .map(String::from)
        .collect();
    let shown = who::unfolded(rows.clone(), &folded, &view);
    let hidden = rows.len() - shown.len();
    // The links run beside the rows the page gets, and the folds dropped some.
    table.links = hub_core::table::links(&shown);
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
pub async fn runner(q: RunnerQuery) -> Result<String, String> {
    let name = q.name.clone();
    let mut r = off(move || fleet::runner::read(&Paths::from_env(), &name)).await??;
    if let fleet::runner::Extras::AskJudge { judge } = &mut r.extras {
        judge.view(&q.verdicts.view(), fleet::runner::PAGE_ROWS);
    }
    serde_json::to_string(&r).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::fleet::who::Opens;

    fn row(tier: u8, key: &str, parent: Option<&str>, kids: usize) -> Who {
        Who {
            tier,
            kind: if tier == 3 { "session" } else { "lead" }.into(),
            who: key.into(),
            opens: if tier == 3 {
                Opens::Session
            } else {
                Opens::Runner
            },
            key: key.into(),
            state: "working".into(),
            since: None,
            cost_24h: None,
            cost_estimated: false,
            activity: String::new(),
            purpose: String::new(),
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
        assert_eq!(
            v["table"]["links"],
            serde_json::json!([{"who": "#fleet/shepherd", "project": "#projects/dotfiles"}]),
            "the links match the rows the folds left"
        );
        let v = who_of(&render(fleet(), &q("", "")));
        assert_eq!(v["table"]["links"][1]["who"], "#sessions/lab%2Fa%3A1");
    }

    #[test]
    fn the_verdicts_view_rides_the_fleet_read_and_counts_every_verdict() {
        let uri = "/api/fleet?q=lab&vs=wrong&vq=ship".parse().unwrap();
        let axum::extract::Query(q) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        assert_eq!((q.q.as_str(), q.verdicts.vs.as_str()), ("lab", "wrong"));
        let wrong = |question: &str| AskVerdict {
            question: question.into(),
            score: "wrong".into(),
            ..Default::default()
        };
        let mut f = fleet();
        f.judge.verdicts = (0..FOLD_ROWS + 5).map(|_| wrong("ship it?")).collect();
        f.judge.verdicts.push(wrong("which login?"));
        let v = who_of(&render(f, &q));
        assert_eq!(v["judge"]["verdicts"].as_array().unwrap().len(), FOLD_ROWS);
        assert_eq!(v["judge"]["table"]["shown"], FOLD_ROWS + 5);
        assert_eq!(v["judge"]["table"]["total"], FOLD_ROWS + 6);
        let uri = "/api/fleet/runner?name=ask-judge&vs=passed"
            .parse()
            .unwrap();
        let axum::extract::Query(r) =
            axum::extract::Query::<RunnerQuery>::try_from_uri(&uri).unwrap();
        assert_eq!(
            (r.name.as_str(), r.verdicts.vs.as_str()),
            ("ask-judge", "passed")
        );
        let bare = "/api/fleet/runner?vs=passed"
            .parse::<axum::http::Uri>()
            .unwrap();
        assert!(
            axum::extract::Query::<RunnerQuery>::try_from_uri(&bare).is_err(),
            "no name is a bad request, not a lookup of the empty name"
        );
    }

    #[test]
    fn a_search_shows_a_hit_even_under_a_folded_row() {
        let v = who_of(&render(fleet(), &q("shepherd", "lab")));
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["who"][0]["key"], "lab/a:1");
        assert_eq!(v["hidden"], 0);
    }
}
