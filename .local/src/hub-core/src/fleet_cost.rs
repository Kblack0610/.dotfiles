//! The whole fleet's estimated cost over the last 24 hours, from `agent-usage fleet-cost`'s file
//! (fleet-bench's sampler writes it, at most every 30 minutes). The rows and their words are built
//! here once, so the hub TUI and agent-web only draw them (dashboards rule 8). Every percentage is
//! of the whole-fleet total, and every row says how much of it is measured or estimated.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// Older than this the block says it is stale: four missed tries of the sampler's 30 minutes, the
/// limit `fleet-bench kpi` uses for the same file. `budget.json` shares it, from the same step
/// (`FILE_STALE_SECS` in agent-usage-budget.py).
pub(crate) const STALE_SECS: i64 = 2 * 3600;
/// Below this a dollar figure is rounding, not money.
const CENT: f64 = 0.005;

pub const FOOT: &str = "% is of the whole fleet's 24h cost. \"estimated\" is priced from tokens at rates fitted to measured sessions.";
/// The Runners table's line for its COST 24H column.
pub const FLEET_LEGEND: &str = "cost 24h from Costs' fleet figure, ~ when part is estimated";

/// One cut of the file: an origin, a runner.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Cut {
    pub usd: f64,
    pub measured: f64,
    pub estimated: f64,
    pub sessions: u64,
}

impl Cut {
    /// Its dollars, or None when none of its sessions has a price: unknown, never $0.
    pub fn priced(&self) -> Option<f64> {
        (self.usd >= CENT).then_some(self.usd)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Coverage {
    /// Null when the window has no tokens at all.
    estimated_token_share: Option<f64>,
    sessions: u64,
    sessions_estimated: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Whole {
    usd: f64,
    measured: f64,
    estimated: f64,
    helper_usd: f64,
    helper_range: [f64; 2],
}

/// Another harness; `source` is None when none of its sessions has a price.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Harness {
    usd: f64,
    sessions: u64,
    priced: u64,
    source: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Unpriced {
    tokens: f64,
    sessions: u64,
    why: String,
}

/// `fleet-cost.json`, as far as the two tabs read it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct File {
    pub as_of_epoch: i64,
    coverage: Coverage,
    total: Whole,
    by_origin: BTreeMap<String, Cut>,
    pub by_runner: BTreeMap<String, Cut>,
    other_harness: BTreeMap<String, Harness>,
    unpriced: BTreeMap<String, Unpriced>,
}

impl File {
    pub fn stale(&self, now: i64) -> bool {
        now - self.as_of_epoch > STALE_SECS
    }
}

/// The file, or why there is none to show.
pub fn load(path: &Path) -> Result<File, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// One row of the block. `cost` and `share` are "-" when nothing in the row has a price.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Row {
    pub name: String,
    pub usd: Option<f64>,
    pub cost: String,
    pub share: String,
    /// How the row's figure was reached: measured, estimated, or how much of each.
    pub basis: String,
    /// A second line under the row.
    pub detail: Option<String>,
}

/// The block both surfaces draw. `why` is set when there is nothing to show.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct FleetCost {
    pub why: Option<String>,
    pub usd: String,
    pub measured: String,
    pub estimated: String,
    pub as_of: Option<i64>,
    pub stale: bool,
    pub coverage: String,
    pub rows: Vec<Row>,
    /// Models with no fitted rate, whose tokens are not in the total.
    pub unpriced: Vec<String>,
    pub foot: &'static str,
}

/// Dollars at a size that does not claim more than an estimate knows: cents only under $10.
pub fn dollars(v: f64) -> String {
    if v < 10.0 {
        return format!("${v:.2}");
    }
    let digits = format!("{v:.0}");
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    format!("${out}")
}

fn count(n: u64, noun: &str) -> String {
    format!("{n} {noun}{}", if n == 1 { "" } else { "s" })
}

fn basis(c: &Cut, noun: &str) -> String {
    let n = count(c.sessions, noun);
    match (c.measured >= CENT, c.estimated >= CENT) {
        (true, false) => format!("{n}, measured"),
        (false, true) => format!("{n}, estimated"),
        (true, true) => format!(
            "{n}, {} measured, {} estimated",
            dollars(c.measured),
            dollars(c.estimated)
        ),
        (false, false) => format!("{n}, no price known"),
    }
}

fn harness_basis(h: &Harness) -> String {
    let n = count(h.sessions, "session");
    let priced = if h.priced < h.sessions {
        format!("{} of {n}", h.priced)
    } else {
        n
    };
    match h.source.as_deref() {
        None => format!("{priced}, no price known"),
        Some("metered") => format!("{priced}, measured by the gateway"),
        Some("price") => format!("{priced}, estimated from prices"),
        Some(_) => format!("{priced}, estimated by the harness"),
    }
}

/// A `by_origin` key as a row name. A queue item's origin is free-form (`fleet-dispatch` also writes
/// `resume`), so a key not listed is one more way a queue item started.
fn origin_name(key: &str) -> String {
    match key {
        "run" => "queue, dispatch run".into(),
        "hand" => "queue, hand-started".into(),
        "plan" => "queue, plan".into(),
        "queue" => "queue items".into(),
        "shepherd" => "shepherd".into(),
        "interactive" => "you, interactive".into(),
        other => format!("queue, {other}"),
    }
}

/// Every runner by name, costliest first; shepherd and dream have their own rows, and a headless
/// session no runner claimed is the remainder.
fn runners_line(f: &File, others: f64) -> Option<String> {
    let mut named: Vec<(&String, &Cut)> = f
        .by_runner
        .iter()
        .filter(|(k, c)| {
            !matches!(k.as_str(), "shepherd" | "dream" | "unattributed") && c.usd >= CENT
        })
        .collect();
    named.sort_by(|a, b| b.1.usd.total_cmp(&a.1.usd).then_with(|| a.0.cmp(b.0)));
    let rest = others - named.iter().map(|r| r.1.usd).sum::<f64>();
    let mut parts: Vec<String> = named
        .iter()
        .map(|(k, c)| format!("{k} {}", dollars(c.usd)))
        .collect();
    if rest >= 0.5 {
        parts.push(format!("{} with no runner name", dollars(rest)));
    }
    (!parts.is_empty()).then(|| parts.join(", "))
}

fn share_text(usd: Option<f64>, total: f64) -> String {
    match usd {
        Some(u) if total > 0.0 && u / total < 0.005 => "<1%".into(),
        Some(u) if total > 0.0 => format!("{:.0}%", u / total * 100.0),
        _ => "-".into(),
    }
}

/// The block from the file.
pub fn build(f: &File, now: i64) -> FleetCost {
    let dream = f.by_runner.get("dream").cloned().unwrap_or_default();
    let runner = f.by_origin.get("runner").cloned().unwrap_or_default();
    let others = Cut {
        usd: (runner.usd - dream.usd).max(0.0),
        measured: (runner.measured - dream.measured).max(0.0),
        estimated: (runner.estimated - dream.estimated).max(0.0),
        sessions: runner.sessions.saturating_sub(dream.sessions),
    };
    let t = &f.total;
    let row = |name: &str, usd: Option<f64>, basis: String, detail: Option<String>| Row {
        name: name.into(),
        usd,
        cost: usd.map_or("-".into(), dollars),
        share: share_text(usd, t.usd),
        basis,
        detail,
    };
    // Every origin gets a row, so the rows add up to the total every share is taken of.
    let mut rows: Vec<Row> = f
        .by_origin
        .iter()
        .filter(|(k, _)| *k != "runner")
        .map(|(k, c)| (origin_name(k), c, "session"))
        .chain([("dream".to_string(), &dream, "sweep")])
        .filter(|(_, c, _)| c.sessions > 0 || c.usd >= CENT)
        .map(|(n, c, noun)| row(&n, c.priced(), basis(c, noun), None))
        .collect();
    if others.sessions > 0 || others.usd >= CENT {
        rows.push(row(
            "other runners",
            others.priced(),
            basis(&others, "session"),
            runners_line(f, others.usd),
        ));
    }
    if t.helper_usd >= CENT {
        let [low, high] = t.helper_range;
        rows.push(row(
            "helper calls",
            Some(t.helper_usd),
            format!("estimated, {} to {} range", dollars(low), dollars(high)),
            None,
        ));
    }
    for (name, h) in &f.other_harness {
        rows.push(row(
            name,
            h.source.is_some().then_some(h.usd),
            harness_basis(h),
            None,
        ));
    }
    let key = |r: &Row| r.usd.unwrap_or(-1.0);
    rows.sort_by(|a, b| key(b).total_cmp(&key(a)).then_with(|| a.name.cmp(&b.name)));
    let c = &f.coverage;
    FleetCost {
        why: None,
        usd: format!("about {}", dollars(t.usd)),
        measured: dollars(t.measured),
        estimated: dollars(t.estimated),
        as_of: Some(f.as_of_epoch),
        stale: f.stale(now),
        coverage: c.estimated_token_share.map_or_else(
            || "no tokens in the window".to_string(),
            |share| {
                format!(
                    "{:.0}% of tokens estimated: {} of {} have no cost telemetry",
                    share * 100.0,
                    c.sessions_estimated,
                    count(c.sessions, "session"),
                )
            },
        ),
        rows,
        unpriced: f
            .unpriced
            .iter()
            .map(|(m, u)| {
                format!(
                    "{m}: {} tokens in {} not in the total, {}",
                    crate::costs::tokens(Some(u.tokens)),
                    count(u.sessions, "session"),
                    u.why
                )
            })
            .collect(),
        foot: FOOT,
    }
}

/// The block when there is no file to read.
pub fn missing(why: String) -> FleetCost {
    FleetCost {
        why: Some(format!("nothing read: {why}")),
        ..FleetCost::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000_000;

    fn file() -> File {
        serde_json::from_value(serde_json::json!({
            "as_of_epoch": NOW - 600,
            "coverage": {"estimated_token_share": 0.7, "sessions": 300, "sessions_estimated": 200},
            "total": {"usd": 200.0, "measured": 90.0, "estimated": 110.0, "helper_usd": 10.0, "helper_range": [0.0, 14.0]},
            "by_origin": {
                "run": {"usd": 60.0, "measured": 0.0, "estimated": 60.0, "sessions": 40},
                "hand": {"usd": 40.0, "measured": 10.0, "estimated": 30.0, "sessions": 20},
                "shepherd": {"usd": 30.0, "measured": 30.0, "estimated": 0.0, "sessions": 50},
                "runner": {"usd": 35.0, "measured": 30.0, "estimated": 5.0, "sessions": 100},
                "interactive": {"usd": 5.0, "measured": 5.0, "estimated": 0.0, "sessions": 1}
            },
            "by_runner": {
                "dream": {"usd": 15.0, "measured": 15.0, "estimated": 0.0, "sessions": 20},
                "shepherd": {"usd": 30.0, "measured": 30.0, "estimated": 0.0, "sessions": 50},
                "ask-judge": {"usd": 12.0, "measured": 12.0, "estimated": 0.0, "sessions": 30},
                "unattributed": {"usd": 105.0, "measured": 15.0, "estimated": 90.0, "sessions": 61}
            },
            "other_harness": {
                "codex": {"usd": 15.0, "sessions": 10, "priced": 6, "source": "price"},
                "gateway": {"usd": 5.0, "sessions": 2, "priced": 2, "source": "metered"},
                "lazer-reserve": {"usd": 0.0, "sessions": 1, "priced": 0, "source": null}
            },
            "unpriced": {"claude-sonnet-4-6": {"tokens": 31500000.0, "sessions": 3, "why": "no billed sessions"}}
        }))
        .unwrap()
    }

    fn row<'a>(b: &'a FleetCost, name: &str) -> &'a Row {
        b.rows.iter().find(|r| r.name == name).unwrap()
    }

    #[test]
    fn the_rows_add_up_to_the_whole_and_every_share_is_of_it() {
        let b = build(&file(), NOW);
        let sum: f64 = b.rows.iter().filter_map(|r| r.usd).sum();
        assert!((sum - 200.0).abs() < 1e-9, "{sum}");
        assert_eq!(row(&b, "shepherd").share, "15%");
        assert_eq!(row(&b, "dream").share, "8%", "15 of 200, not of measured");
        assert_eq!(b.rows[0].name, "queue, dispatch run", "costliest first");
        assert_eq!(
            (b.usd.as_str(), b.measured.as_str(), b.estimated.as_str()),
            ("about $200", "$90", "$110")
        );
    }

    #[test]
    fn each_row_says_what_is_measured_and_what_is_estimated() {
        let b = build(&file(), NOW);
        assert_eq!(
            row(&b, "queue, dispatch run").basis,
            "40 sessions, estimated"
        );
        assert_eq!(row(&b, "shepherd").basis, "50 sessions, measured");
        assert_eq!(row(&b, "dream").basis, "20 sweeps, measured");
        assert_eq!(
            row(&b, "queue, hand-started").basis,
            "20 sessions, $10 measured, $30 estimated"
        );
        assert_eq!(
            row(&b, "helper calls").basis,
            "estimated, $0.00 to $14 range"
        );
        assert_eq!(
            row(&b, "gateway").basis,
            "2 sessions, measured by the gateway"
        );
        assert_eq!(
            row(&b, "codex").basis,
            "6 of 10 sessions, estimated from prices"
        );
    }

    #[test]
    fn a_harness_with_no_price_is_unknown_never_zero() {
        let b = build(&file(), NOW);
        let r = row(&b, "lazer-reserve");
        assert_eq!((r.usd, r.cost.as_str(), r.share.as_str()), (None, "-", "-"));
        assert_eq!(r.basis, "0 of 1 session, no price known");
        assert_eq!(b.rows.last().unwrap().name, "lazer-reserve");
    }

    #[test]
    fn every_runner_is_named_under_other_runners_and_the_remainder_says_what_it_is() {
        let b = build(&file(), NOW);
        let r = row(&b, "other runners");
        assert_eq!(r.usd, Some(20.0), "the runner origin less dream");
        assert_eq!(
            r.detail.as_deref(),
            Some("ask-judge $12, $8.00 with no runner name")
        );
    }

    #[test]
    fn an_origin_the_block_has_no_name_for_still_gets_a_row_so_the_rows_add_up() {
        let mut f = file();
        f.by_origin.insert(
            "resume".into(),
            Cut {
                usd: 25.0,
                measured: 0.0,
                estimated: 25.0,
                sessions: 4,
            },
        );
        f.total.usd = 225.0;
        let b = build(&f, NOW);
        let sum: f64 = b.rows.iter().filter_map(|r| r.usd).sum();
        assert!((sum - 225.0).abs() < 1e-9, "{sum}");
        assert_eq!(row(&b, "queue, resume").basis, "4 sessions, estimated");
    }

    #[test]
    fn sessions_with_no_price_are_unknown_never_zero_dollars() {
        let c = Cut {
            sessions: 3,
            ..Cut::default()
        };
        assert_eq!(c.priced(), None);
        let mut f = file();
        f.by_origin.insert("plan".into(), c);
        let b = build(&f, NOW);
        let r = row(&b, "queue, plan");
        assert_eq!((r.usd, r.cost.as_str(), r.share.as_str()), (None, "-", "-"));
        assert_eq!(r.basis, "3 sessions, no price known");
        assert_eq!(b.rows.last().unwrap().usd, None, "unknown sorts last");
    }

    #[test]
    fn a_window_with_no_tokens_writes_null_and_still_reads() {
        let f: File = serde_json::from_value(serde_json::json!({
            "as_of_epoch": NOW,
            "coverage": {"estimated_token_share": null, "sessions": 0, "sessions_estimated": 0},
        }))
        .unwrap();
        assert_eq!(build(&f, NOW).coverage, "no tokens in the window");
    }

    #[test]
    fn staleness_coverage_and_unpriced_read_as_they_say() {
        let b = build(&file(), NOW);
        assert!(!b.stale);
        assert!(build(&file(), NOW + 2 * 3600).stale);
        assert_eq!(
            b.coverage,
            "70% of tokens estimated: 200 of 300 sessions have no cost telemetry"
        );
        assert_eq!(
            b.unpriced,
            ["claude-sonnet-4-6: 32M tokens in 3 sessions not in the total, no billed sessions"]
        );
    }

    #[test]
    fn a_missing_or_broken_file_says_why() {
        let dir = std::env::temp_dir().join(format!("fleet-cost-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("fleet-cost.json");
        assert!(load(&p).unwrap_err().contains("fleet-cost.json"));
        std::fs::write(&p, "{").unwrap();
        assert!(load(&p).is_err());
        std::fs::write(&p, r#"{"as_of_epoch": 5}"#).unwrap();
        assert_eq!(load(&p).unwrap().as_of_epoch, 5);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(missing("x".into()).why.as_deref(), Some("nothing read: x"));
    }
}
