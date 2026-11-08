//! The Releases tab, both surfaces: one row per project channel, what is pinned there and what
//! is actually live, from `release-state show --json`. The collector owns the probes and the
//! status words; this reader adds only what a row needs to draw: its level, its column text and
//! the exceptions-first order. Previous version and last deploy arrive with the collector's
//! deployment history, and the Builds section under the channels is its own reader's.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::layout;
use crate::session_actions::Runner;
use crate::table::{Row, Val, View};

/// A snapshot older than this is drawn amber: the collector runs every 15 minutes, and this is
/// `release-state check`'s own `--max-age` default.
pub const STALE_SECS: i64 = 3600;
/// How many channels the fold line names before it says "...".
const FOLD_NAMES: usize = 3;
/// The collector's words, worst first (`RANK` in `release-state`). A word not listed here is
/// new, so it is drawn amber and sorts with the exceptions rather than folding as green.
const STATUSES: [&str; 6] = [
    "drift",
    "unknown",
    "floating",
    "ok",
    "released",
    "unreleased",
];

/// What one row's state means, for its colour (docs/dashboards.md rule 5).
#[derive(Serialize, Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Bad,
    Warn,
    #[default]
    Ok,
}

/// One side of a channel: the version pinned there or the version running there.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Side {
    pub value: Option<String>,
    /// Where the value was read from, as the probe names it; `none` when nothing is probed.
    pub source: String,
    pub error: Option<String>,
    pub image: Option<String>,
}

impl Side {
    /// The cell: the value, `-` when there is nothing to read, `?` when a read failed.
    fn text(&self) -> String {
        match &self.value {
            Some(v) => v.clone(),
            None if self.source == "none" || self.error.as_deref() == Some("no release tag") => {
                "-".into()
            }
            None => "?".into(),
        }
    }
}

/// One telemetry watch a channel declares.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Watch {
    pub watch: String,
    /// `OK`, `TRIP`, `pending` or `missing`.
    pub state: String,
    pub since: Option<i64>,
}

/// One project channel. The `Deserialize` fields are the collector's row as it wrote it; the
/// `skip_deserializing` ones are set by [`settle`], so a surface with only the JSON can draw it.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Release {
    pub project: String,
    pub id: String,
    pub channel: String,
    #[serde(rename = "where")]
    pub place: Option<String>,
    /// A row the collector made from a project's tags, with no declared target.
    pub implicit: bool,
    pub tag: Option<String>,
    pub pinned: Side,
    pub live: Side,
    pub status: String,
    pub drift_since: Option<i64>,
    pub telemetry: Vec<Watch>,
    pub deps: Vec<String>,
    pub probed_at: Option<i64>,
    /// The worse of the status word and the watches: what orders and folds the row.
    #[serde(skip_deserializing)]
    pub level: Level,
    /// The STATUS and TELEMETRY cells' own levels, for their colour.
    #[serde(skip_deserializing)]
    pub status_level: Level,
    #[serde(skip_deserializing)]
    pub watch_level: Level,
    /// The CHANNEL cell: `prod pmp-web-prod`, or `release` on an implicit row.
    #[serde(skip_deserializing)]
    pub label: String,
    #[serde(skip_deserializing)]
    pub pinned_text: String,
    #[serde(skip_deserializing)]
    pub live_text: String,
    /// `2/3` watches OK, `-` with none declared.
    #[serde(skip_deserializing)]
    pub telemetry_text: String,
    /// Each dependency with the version pinned on it: `unity-core v0.5.0, audio`.
    #[serde(skip_deserializing)]
    pub deps_text: String,
}

impl Release {
    /// Nothing about this channel asks for attention.
    pub fn green(&self) -> bool {
        self.level == Level::Ok
    }

    /// A watch tripped is broken and one that was never written is a gap; `pending` has simply
    /// not run yet, which `release-state check` does not count either.
    fn watches(&self) -> Level {
        let has = |s: &str| self.telemetry.iter().any(|w| w.state == s);
        if has("TRIP") {
            Level::Bad
        } else if has("missing") {
            Level::Warn
        } else {
            Level::Ok
        }
    }

    fn word(&self) -> Level {
        match self.status.as_str() {
            "drift" => Level::Bad,
            "ok" | "released" | "unreleased" => Level::Ok,
            _ => Level::Warn,
        }
    }

    fn order(&self) -> usize {
        STATUSES
            .iter()
            .position(|s| *s == self.status)
            .unwrap_or(STATUSES.len())
    }
}

impl Row for Release {
    // `id` and `where` are last and undrawn: the channel cell shows the one and the opened row the
    // other, and both still filter.
    const COLUMNS: &'static [&'static str] = &[
        "project",
        "channel",
        "pinned",
        "live",
        "status",
        "telemetry",
        "deps",
        "id",
        "where",
    ];
    const STATES: &'static [&'static str] = &["all", "attention", "green"];
    const FACETS: &'static [&'static str] = &["project", "status"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" | "-" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "project" => text(&self.project),
            "channel" => text(&self.label),
            "pinned" => text(&self.pinned_text),
            "live" => text(&self.live_text),
            "status" => text(&self.status),
            "telemetry" => text(&self.telemetry_text),
            "deps" => text(&self.deps_text),
            "id" => text(&self.id),
            "where" => text(self.place.as_deref().unwrap_or_default()),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        match state {
            "attention" => !self.green(),
            "green" => self.green(),
            _ => true,
        }
    }

    /// `status` sorts worst first on the first click, not by the word's spelling.
    fn rank(&self, col: &str) -> Val {
        match col {
            "status" => Val::Num(-(self.order() as f64)),
            _ => self.val(col),
        }
    }
}

/// The tab's one read. `at` is 0 when there is no snapshot, and `errors` says why.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Releases {
    pub at: i64,
    /// The tab's question, from `hub_core::layout`.
    pub question: String,
    /// `18 channels: 1 floating, 8 ok, 5 released, 4 unreleased`.
    pub summary: String,
    pub rows: Vec<Release>,
    pub errors: Vec<String>,
}

impl Releases {
    /// The snapshot is older than the collector's cadence can explain.
    pub fn stale(&self, now: i64) -> bool {
        self.at > 0 && now - self.at > STALE_SECS
    }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Snapshot {
    generated_epoch: i64,
    rows: Vec<Release>,
}

/// The rows this reader was handed, joined and ordered: exceptions first, the worst on top.
fn settle(mut rows: Vec<Release>) -> Vec<Release> {
    let mut pins: HashMap<String, (bool, String)> = HashMap::new();
    for r in &rows {
        let prod = r.channel == "prod";
        let pin = r.pinned.value.clone().unwrap_or_default();
        let e = pins.entry(r.project.clone()).or_insert((prod, pin.clone()));
        if prod && !e.0 {
            *e = (prod, pin);
        }
    }
    for r in &mut rows {
        r.status_level = r.word();
        r.watch_level = r.watches();
        r.level = r.status_level.min(r.watch_level);
        r.label = if r.implicit {
            r.channel.clone()
        } else {
            format!("{} {}", r.channel, r.id)
        };
        r.pinned_text = r.pinned.text();
        r.live_text = r.live.text();
        r.telemetry_text = if r.telemetry.is_empty() {
            "-".into()
        } else {
            let ok = r.telemetry.iter().filter(|w| w.state == "OK").count();
            format!("{ok}/{}", r.telemetry.len())
        };
        r.deps_text = if r.deps.is_empty() {
            "-".into()
        } else {
            r.deps
                .iter()
                .map(|d| match pins.get(d) {
                    Some((_, pin)) if !pin.is_empty() => format!("{d} {pin}"),
                    _ => d.clone(),
                })
                .collect::<Vec<_>>()
                .join(", ")
        };
    }
    rows.sort_by(|a, b| {
        (a.level, a.order(), &a.project, &a.id).cmp(&(b.level, b.order(), &b.project, &b.id))
    });
    rows
}

/// `8 ok, 5 released`, worst first, each status with its count and none with no rows.
fn counts<'a>(rows: impl IntoIterator<Item = &'a Release>) -> String {
    let mut n: Vec<(&str, usize)> = vec![];
    for r in rows {
        match n.iter_mut().find(|(s, _)| *s == r.status) {
            Some((_, c)) => *c += 1,
            None => n.push((&r.status, 1)),
        }
    }
    let at = |s: &str| {
        STATUSES
            .iter()
            .position(|x| *x == s)
            .unwrap_or(STATUSES.len())
    };
    n.sort_by_key(|(s, _)| at(s));
    n.iter()
        .map(|(s, c)| format!("{c} {s}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn says(rows: &[Release]) -> String {
    match rows.len() {
        0 => "no channels".into(),
        1 => format!("1 channel: {}", counts(rows)),
        n => format!("{n} channels: {}", counts(rows)),
    }
}

fn show(runner: &dyn Runner, project: Option<&str>) -> Result<Snapshot, String> {
    let mut argv: Vec<String> = ["release-state", "show", "--json"]
        .map(String::from)
        .to_vec();
    argv.extend(project.map(String::from));
    let raw = runner
        .run(&argv)
        .map_err(|e| format!("release-state show: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("release-state show: {e}"))
}

/// The tab: every channel, or what stopped the read. Nothing is carried over from an earlier
/// read, so a failed probe is never shown as the last good value.
pub fn read(runner: &dyn Runner) -> Releases {
    let question = layout::resolve("releases")
        .map(|t| t.question.to_string())
        .unwrap_or_default();
    match show(runner, None) {
        Ok(s) => {
            let rows = settle(s.rows);
            Releases {
                at: s.generated_epoch,
                question,
                summary: says(&rows),
                rows,
                errors: vec![],
            }
        }
        Err(e) => Releases {
            question,
            summary: "not read".into(),
            errors: vec![e],
            ..Default::default()
        },
    }
}

/// The green rows a view folds to one line (docs/dashboards.md rule 4).
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Fold {
    pub n: usize,
    /// `17 channels green: 8 ok, 5 released, 4 unreleased (binks-api-prod, ...)`.
    pub says: String,
}

/// The rows to draw and the green ones folded out of them. Only the plain view folds: any query,
/// chip or sort is the human asking for those rows, so they show. The fold's way open is the
/// `green` chip.
pub fn fold<'a>(view: &View, rows: Vec<&'a Release>) -> (Vec<&'a Release>, Option<Fold>) {
    if !view.is_default() {
        return (rows, None);
    }
    let (green, open): (Vec<&Release>, Vec<&Release>) = rows.into_iter().partition(|r| r.green());
    if green.is_empty() {
        return (open, None);
    }
    let mut names: Vec<&str> = green
        .iter()
        .take(FOLD_NAMES)
        .map(|r| r.id.as_str())
        .collect();
    if green.len() > FOLD_NAMES {
        names.push("...");
    }
    let says = format!(
        "{} channel{} green: {} ({})",
        green.len(),
        if green.len() == 1 { "" } else { "s" },
        counts(green.iter().copied()),
        names.join(", ")
    );
    let n = green.len();
    (open, Some(Fold { n, says }))
}

/// One project's channels as the Projects card's badge, linking to this tab (rule 2).
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Badge {
    /// `3 channels: 1 drift, 2 ok`.
    pub says: String,
    pub level: Level,
}

/// The badge for `project`; None when it has no channels. `project` is already a safe name.
pub fn badge(runner: &dyn Runner, project: &str) -> Result<Option<Badge>, String> {
    let rows = settle(show(runner, Some(project))?.rows);
    Ok(rows.first().map(|worst| Badge {
        says: says(&rows),
        level: worst.level,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv[..3], ["release-state", "show", "--json"]);
            self.0.clone()
        }
    }

    fn row(project: &str, id: &str, status: &str) -> serde_json::Value {
        serde_json::json!({
            "project": project, "id": id, "channel": "prod", "where": null, "implicit": false,
            "tag": null, "pinned": {"value": "v2", "source": "m"},
            "live": {"value": "v1", "source": "k8s"}, "status": status, "drift_since": null,
            "telemetry": [], "deps": [], "probed_at": 5,
        })
    }

    fn snapshot(rows: Vec<serde_json::Value>) -> Fake {
        Fake(Ok(
            serde_json::json!({ "generated_epoch": 100, "rows": rows }).to_string(),
        ))
    }

    #[test]
    fn exceptions_lead_worst_first_and_the_summary_counts_every_status() {
        let r = read(&snapshot(vec![
            row("a", "a-prod", "ok"),
            row("b", "b-prod", "unreleased"),
            row("c", "c-prod", "floating"),
            row("d", "d-prod", "drift"),
            row("e", "e-prod", "unknown"),
        ]));
        let ids: Vec<&str> = r.rows.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, ["d-prod", "e-prod", "c-prod", "a-prod", "b-prod"]);
        assert_eq!(
            r.summary,
            "5 channels: 1 drift, 1 unknown, 1 floating, 1 ok, 1 unreleased"
        );
        assert_eq!(r.at, 100);
        assert_eq!(r.question, "What is building, and what is live where?");
    }

    #[test]
    fn a_status_the_reader_does_not_know_is_amber_never_folded_as_green() {
        let r = read(&snapshot(vec![row("a", "a", "melting")]));
        assert_eq!(r.rows[0].level, Level::Warn);
        assert!(!r.rows[0].green());
    }

    #[test]
    fn a_watch_raises_a_green_channel_and_pending_does_not() {
        let tel = |state: &str| {
            let mut v = row("a", "a", "ok");
            v["telemetry"] = serde_json::json!([{"watch": "w", "state": state, "since": 3}]);
            v
        };
        let level = |state: &str| read(&snapshot(vec![tel(state)])).rows[0].level;
        assert_eq!(level("TRIP"), Level::Bad);
        assert_eq!(level("missing"), Level::Warn);
        assert_eq!(level("pending"), Level::Ok);
        let r = read(&snapshot(vec![tel("OK")]));
        assert_eq!(r.rows[0].telemetry_text, "1/1");
    }

    #[test]
    fn a_missing_value_is_a_dash_and_a_failed_read_a_question_mark() {
        let side = |v: serde_json::Value| serde_json::from_value::<Side>(v).unwrap().text();
        assert_eq!(
            side(serde_json::json!({"value": "v1", "source": "x"})),
            "v1"
        );
        assert_eq!(
            side(serde_json::json!({"value": null, "source": "none"})),
            "-"
        );
        assert_eq!(
            side(serde_json::json!({"source": "tag", "error": "no release tag"})),
            "-"
        );
        assert_eq!(
            side(serde_json::json!({"source": "k8s", "error": "timeout"})),
            "?"
        );
    }

    #[test]
    fn a_dependency_names_its_prod_pin_and_an_unlisted_one_stands_alone() {
        let mut app = row("app", "app-prod", "ok");
        app["deps"] = serde_json::json!(["lib", "other"]);
        let mut preview = row("lib", "lib-preview", "ok");
        preview["channel"] = "preview".into();
        preview["pinned"]["value"] = "p9".into();
        let r = read(&snapshot(vec![preview, app, row("lib", "lib-prod", "ok")]));
        let a = r.rows.iter().find(|x| x.project == "app").unwrap();
        assert_eq!(a.deps_text, "lib v2, other");
    }

    #[test]
    fn an_implicit_row_labels_only_its_channel() {
        let mut v = row("a", "a", "released");
        v["implicit"] = true.into();
        v["channel"] = "release".into();
        let r = read(&snapshot(vec![v, row("b", "b-prod", "ok")]));
        let labels: Vec<&str> = r.rows.iter().map(|x| x.label.as_str()).collect();
        assert_eq!(labels, ["prod b-prod", "release"]);
    }

    #[test]
    fn only_the_plain_view_folds_green_rows_to_one_line() {
        let r = read(&snapshot(vec![
            row("a", "a-prod", "ok"),
            row("b", "b-prod", "ok"),
            row("c", "c-prod", "released"),
            row("e", "e-prod", "ok"),
            row("d", "d-prod", "drift"),
        ]));
        let plain = View::default();
        let (shown, f) = fold(&plain, plain.apply(&r.rows));
        assert_eq!(shown.len(), 1);
        let f = f.unwrap();
        assert_eq!(f.n, 4);
        assert_eq!(
            f.says,
            "4 channels green: 3 ok, 1 released (a-prod, b-prod, e-prod, ...)"
        );
        // Negative controls: a chip, a query and a sort each show what they keep.
        let chip = View::new::<Release>("", "green", "", "");
        let (shown, f) = fold(&chip, chip.apply(&r.rows));
        assert_eq!((shown.len(), f), (4, None));
        let q = View::new::<Release>("project:a", "", "", "");
        let (shown, f) = fold(&q, q.apply(&r.rows));
        assert_eq!((shown.len(), f), (1, None));
        let sort = View::new::<Release>("", "", "project", "asc");
        assert!(fold(&sort, sort.apply(&r.rows)).1.is_none());
    }

    #[test]
    fn with_nothing_green_there_is_no_fold() {
        let r = read(&snapshot(vec![row("d", "d", "drift")]));
        let v = View::default();
        let (shown, f) = fold(&v, v.apply(&r.rows));
        assert_eq!((shown.len(), f), (1, None));
    }

    #[test]
    fn the_status_column_sorts_worst_first_on_the_first_click() {
        let r = read(&snapshot(vec![row("a", "a", "ok"), row("b", "b", "drift")]));
        let v = View::new::<Release>("", "", "status", "desc");
        assert_eq!(v.apply(&r.rows)[0].status, "drift");
    }

    #[test]
    fn a_failed_read_says_so_and_keeps_no_rows() {
        let r = read(&Fake(Err("no snapshot yet".into())));
        assert_eq!(r.errors, ["release-state show: no snapshot yet"]);
        assert!(r.rows.is_empty());
        assert_eq!(r.at, 0);
        assert!(!r.stale(1_000_000), "no snapshot is an error, not stale");
    }

    #[test]
    fn a_snapshot_past_the_collectors_cadence_is_stale() {
        let r = read(&snapshot(vec![]));
        assert!(!r.stale(100 + STALE_SECS));
        assert!(r.stale(100 + STALE_SECS + 1));
    }

    #[test]
    fn a_badge_counts_the_projects_channels_at_its_worst_level() {
        let b = badge(
            &snapshot(vec![row("a", "x", "ok"), row("a", "y", "drift")]),
            "a",
        )
        .unwrap()
        .unwrap();
        assert_eq!(b.says, "2 channels: 1 drift, 1 ok");
        assert_eq!(b.level, Level::Bad);
        assert_eq!(badge(&snapshot(vec![]), "a").unwrap(), None);
    }

    #[test]
    fn the_real_row_shape_reads() {
        let raw = r#"{"generated_epoch": 7, "rows": [{"project": "freelance", "id": "freelance",
          "channel": "release", "where": null, "implicit": true, "tag": null,
          "pinned": {"value": null, "source": "newest release tag", "error": "no release tag"},
          "live": {"value": null, "source": "none"}, "status": "unreleased", "drift_since": null,
          "telemetry": [], "deps": [], "probed_at": 9}]}"#;
        let r = read(&Fake(Ok(raw.into())));
        assert_eq!(r.errors, Vec::<String>::new());
        assert_eq!(r.rows[0].pinned_text, "-");
        assert_eq!(r.rows[0].live_text, "-");
    }
}
