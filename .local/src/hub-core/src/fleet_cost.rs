//! The whole fleet's estimated cost over the last 24 hours, from `agent-usage fleet-cost`'s file
//! (fleet-bench's sampler writes it, at most every 30 minutes). This is the tile's figure and its
//! coverage words; the file's session rows are the live day of `spend_history`, the one builder of
//! every per-session cut, so the hub TUI and agent-web only draw them (dashboards rule 8).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// Older than this the block says it is stale: four missed tries of the sampler's 30 minutes, the
/// limit `fleet-bench kpi` uses for the same file. `budget.json` shares it, from the same step
/// (`FILE_STALE_SECS` in agent-usage-budget.py).
pub(crate) const STALE_SECS: i64 = 2 * 3600;
/// Below this a dollar figure is rounding, not money.
const CENT: f64 = 0.005;

pub const FOOT: &str = "% is of the whole fleet's figure for the day. \"est.\" is priced from tokens at rates fitted to measured sessions.";
/// The Runners table's line for its COST 24H column.
pub const FLEET_LEGEND: &str = "cost 24h from Costs' fleet figure, ~ when part is estimated";

/// One runner's cut of the file.
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
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Unpriced {
    tokens: f64,
    sessions: u64,
    why: String,
}

/// `fleet-cost.json`, as far as the tabs read it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct File {
    pub as_of_epoch: i64,
    coverage: Coverage,
    total: Whole,
    pub by_runner: BTreeMap<String, Cut>,
    /// The session rows of the window: the live day of the spend table.
    pub by_session: Vec<crate::spend_history::Sess>,
    unpriced: BTreeMap<String, Unpriced>,
}

impl File {
    pub fn stale(&self, now: i64) -> bool {
        now - self.as_of_epoch > STALE_SECS
    }

    /// The whole fleet's dollars for the window and the part of them estimated from tokens.
    pub fn figure(&self) -> (f64, f64) {
        (self.total.usd, self.total.estimated)
    }
}

/// The file, or why there is none to show.
pub fn load(path: &Path) -> Result<File, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
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

/// The block from the file.
pub fn build(f: &File, now: i64) -> FleetCost {
    let t = &f.total;
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
            "total": {"usd": 200.0, "measured": 90.0, "estimated": 110.0},
            "by_runner": {"dream": {"usd": 15.0, "measured": 15.0, "estimated": 0.0, "sessions": 20}},
            "by_session": [{"sid": "s1", "usd": 150.0, "measured": 50.0, "origin": "queue"}],
            "unpriced": {"claude-sonnet-4-6": {"tokens": 31500000.0, "sessions": 3, "why": "no billed sessions"}}
        }))
        .unwrap()
    }

    #[test]
    fn the_tile_reads_the_figure_and_the_file_keeps_its_session_rows() {
        let f = file();
        let b = build(&f, NOW);
        assert_eq!(
            (b.usd.as_str(), b.measured.as_str(), b.estimated.as_str()),
            ("about $200", "$90", "$110")
        );
        assert_eq!(f.figure(), (200.0, 110.0));
        assert_eq!(f.by_session[0].sid, "s1");
        assert_eq!(f.by_runner["dream"].priced(), Some(15.0));
        assert_eq!(
            Cut::default().priced(),
            None,
            "no price is unknown, never $0"
        );
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
