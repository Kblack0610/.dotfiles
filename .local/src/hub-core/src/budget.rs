//! What the fleet pays this month, in cash, from `agent-usage budget`'s file (fleet-bench's
//! sampler writes it, at most every 30 minutes). Costs' Budget inner tab is the one place in the
//! hub that shows a cash dollar; every other figure on Costs is list price. The rows and their words
//! are built here once, so the hub TUI and agent-web only draw them (dashboards rule 8).
//!
//! What needs a look is the file's own `needs` (the reasons `agent-usage budget check`, the
//! `fleet-budget-pace` watch, trips on), then any line not `ok` that those do not name (a bill
//! someone else pays, past its cap; a reader that failed less than a day ago), then the file's age.

use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::fleet_cost::dollars;

/// Older than this the tab says it is stale and `budget check` trips: four missed tries of the
/// sampler's 30 minutes (`FILE_STALE_SECS` in agent-usage-budget.py, `fleet_cost::STALE_SECS`).
pub const STALE_SECS: i64 = 2 * 3600;
/// The schema `agent-usage budget --json` writes; another one is read as nothing.
const SCHEMA: u32 = 2;

pub const FOOT: &str = "Cash: what we pay, not list price. A subscription is its flat fee, paid whole; a metered bill is read from the system that bills it. The split shares each fee by its account's list-price work this month; what no project or lane carries is unattributed.";

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Total {
    spent: f64,
    projected: f64,
    caps: f64,
    list_usd: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Line {
    name: String,
    kind: String,
    paid_by: Option<String>,
    cap: Option<f64>,
    spent: Option<f64>,
    projected: Option<f64>,
    list_usd: Option<f64>,
    status: String,
    note: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
struct Cut {
    name: String,
    usd: f64,
}

/// `budget.json`, as far as the tab reads it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct File {
    schema: u32,
    month: String,
    pub as_of_epoch: i64,
    day: u32,
    days: u32,
    total: Total,
    partial: Vec<String>,
    needs: Vec<String>,
    by_project: Vec<Cut>,
    by_lane: Vec<Cut>,
    lines: Vec<Line>,
}

/// The file, or why there is none to show.
pub fn load(path: &Path) -> Result<File, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let f: File =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    if f.schema != SCHEMA {
        return Err(format!(
            "{} is schema {}, not {SCHEMA}: an older agent-usage budget wrote it",
            path.display(),
            f.schema
        ));
    }
    Ok(f)
}

/// One bill. Money columns are "-" when the bill has no such figure (no cap, or unread).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Bill {
    pub name: String,
    pub kind: String,
    pub cap: String,
    pub spent: String,
    /// The month's estimate: the fee, the bill's pace, or AWS's own forecast.
    pub month: String,
    pub note: String,
    /// `ok`, `over`, `unread` or `unpriced`; a surface draws anything but `ok` amber.
    pub status: String,
}

/// One project or lane of the split.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Share {
    pub name: String,
    pub usd: String,
    pub share: String,
}

/// The block both surfaces draw. `why` is set when there is nothing to show.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Budget {
    pub why: Option<String>,
    /// "Nov, day 11 of 30".
    pub month: String,
    pub spent: String,
    pub projected: String,
    pub caps: String,
    /// Bills of ours not in the totals (unread, unpriced): the totals are partial.
    pub partial: Vec<String>,
    pub as_of: Option<i64>,
    pub stale: bool,
    /// What needs a look, one line each, worst first. Empty when all is well.
    pub needs: Vec<String>,
    pub bills: Vec<Bill>,
    pub by_project: Vec<Share>,
    pub by_lane: Vec<Share>,
    pub foot: &'static str,
}

impl Budget {
    /// Whether the Budget inner tab carries a count: something needs a look, or nothing was read.
    pub fn flagged(&self) -> bool {
        self.why.is_some() || !self.needs.is_empty()
    }
}

fn money(v: Option<f64>) -> String {
    v.map_or("-".into(), dollars)
}

fn month_name(month: &str) -> String {
    const NAMES: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    month
        .split_once('-')
        .and_then(|(_, m)| m.parse::<usize>().ok())
        .and_then(|m| NAMES.get(m.wrapping_sub(1)))
        .map_or_else(|| month.to_string(), |n| n.to_string())
}

fn note(l: &Line) -> String {
    let mut parts: Vec<String> = vec![];
    if l.status != "ok" {
        parts.push(l.status.clone());
    }
    if let Some(p) = &l.paid_by {
        parts.push(format!("paid by {p}, not in our total"));
    }
    match (l.list_usd, l.cap) {
        (Some(list), Some(fee)) if fee > 0.0 => {
            parts.push(format!("{} list work ({:.0}x)", dollars(list), list / fee))
        }
        (Some(list), _) => parts.push(format!("{} list work", dollars(list))),
        _ => {}
    }
    if !l.note.is_empty() {
        parts.push(l.note.clone());
    }
    parts.join(", ")
}

fn shares(cuts: &[Cut], total: f64) -> Vec<Share> {
    cuts.iter()
        .map(|c| Share {
            name: c.name.clone(),
            usd: dollars(c.usd),
            share: if total > 0.0 {
                format!("{:.0}%", c.usd / total * 100.0)
            } else {
                "-".into()
            },
        })
        .collect()
}

/// The block from the file.
pub fn build(f: &File, now: i64) -> Budget {
    let stale = now - f.as_of_epoch > STALE_SECS;
    let mut needs = f.needs.clone();
    // A line off `ok` that the file's reasons do not name: someone else's bill past its cap, or a
    // reader that failed under a day ago (the watch waits a day; the tab says it now).
    for l in f.lines.iter().filter(|l| l.status != "ok") {
        let named = needs
            .iter()
            .any(|n| n.split_whitespace().next() == Some(l.name.as_str()));
        if named {
            continue;
        }
        let mut s = format!("{} {}", l.name, l.status);
        if l.status == "over" {
            if let (Some(cap), Some(spent)) = (l.cap, l.spent) {
                s = format!("{} over its {} cap ({})", l.name, dollars(cap), dollars(spent));
            }
        } else if !l.note.is_empty() {
            s = format!("{s}: {}", l.note);
        }
        if let Some(p) = &l.paid_by {
            s = format!("{s}, paid by {p}, not in our total");
        }
        needs.push(s);
    }
    if stale {
        needs.insert(
            0,
            format!(
                "stale: the fleet-bench budget step last wrote it {}h ago",
                (now - f.as_of_epoch) / 3600
            ),
        );
    }
    // What needs a look first, then the metered bills by their month, then the fees.
    let rank = |l: &Line| (l.status == "ok", l.kind == "subscription");
    let mut lines: Vec<&Line> = f.lines.iter().collect();
    lines.sort_by(|a, b| {
        rank(a).cmp(&rank(b)).then_with(|| {
            b.projected
                .unwrap_or(-1.0)
                .total_cmp(&a.projected.unwrap_or(-1.0))
        })
    });
    let t = &f.total;
    Budget {
        why: None,
        month: format!("{}, day {} of {}", month_name(&f.month), f.day, f.days),
        spent: dollars(t.spent),
        projected: format!("~{}", dollars(t.projected)),
        caps: dollars(t.caps),
        partial: f.partial.clone(),
        as_of: Some(f.as_of_epoch),
        stale,
        needs,
        bills: lines
            .into_iter()
            .map(|l| Bill {
                name: l.name.clone(),
                kind: l.kind.clone(),
                cap: money(l.cap),
                spent: money(l.spent),
                month: money(l.projected),
                note: note(l),
                status: l.status.clone(),
            })
            .collect(),
        by_project: shares(&f.by_project, t.spent),
        by_lane: shares(&f.by_lane, t.spent),
        foot: FOOT,
    }
}

/// The block when there is no file to read.
pub fn missing(why: String) -> Budget {
    Budget {
        why: Some(format!("nothing read: {why}")),
        ..Budget::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000_000;

    fn file(needs: &[&str]) -> File {
        serde_json::from_value(serde_json::json!({
            "schema": 2, "month": "2026-11", "as_of_epoch": NOW - 600, "day": 11, "days": 30,
            "total": {"spent": 838.3, "projected": 1303.52, "caps": 1445.0, "list_usd": 13923.6},
            "partial": [], "needs": needs,
            "by_project": [{"name": "unity-core-playground", "usd": 334.31}, {"name": "unattributed", "usd": 91.18}],
            "by_lane": [{"name": "queue", "usd": 175.02}],
            "lines": [
                {"name": "alt", "kind": "subscription", "cap": 200.0, "spent": 200.0, "projected": 200.0,
                 "list_usd": 4663.51, "status": "ok", "note": ""},
                {"name": "lazer", "kind": "litellm", "paid_by": "lazer", "cap": 50.0, "spent": 228.12,
                 "projected": 228.12, "status": "over", "note": "past its $50 cap"},
                {"name": "do", "kind": "digitalocean", "spent": 77.71, "projected": 224.0, "status": "ok", "note": ""},
                {"name": "aws", "kind": "aws", "cap": 600.0, "spent": 112.95, "projected": 379.86,
                 "status": "ok", "note": "AWS's own forecast"},
                {"name": "github", "kind": "github", "status": "unread", "note": "gh: no answer"}
            ]
        }))
        .unwrap()
    }

    #[test]
    fn the_head_is_the_month_and_its_cash_and_the_bills_lead_with_what_needs_a_look() {
        let b = build(&file(&[]), NOW);
        assert_eq!(b.month, "Nov, day 11 of 30");
        assert_eq!((b.spent.as_str(), b.projected.as_str(), b.caps.as_str()), ("$838", "~$1,304", "$1,445"));
        assert!(!b.stale);
        let names: Vec<&str> = b.bills.iter().map(|x| x.name.as_str()).collect();
        // off ok first (by month), then metered by month, then the fees
        assert_eq!(names, ["lazer", "github", "aws", "do", "alt"]);
        assert_eq!(b.bills[1].spent, "-", "an unread bill is unknown, never $0");
        assert_eq!(b.bills[4].note, "$4,664 list work (23x)");
        assert_eq!(b.bills[0].note, "over, paid by lazer, not in our total, past its $50 cap");
        assert_eq!(b.by_project[0].share, "40%");
        assert_eq!(b.by_project[1].name, "unattributed");
    }

    #[test]
    fn needs_are_the_watchs_reasons_then_each_line_off_ok_they_do_not_name_then_the_age() {
        let b = build(&file(&["github unread since 2026-11-10T09:00: gh: no answer"]), NOW);
        assert_eq!(
            b.needs,
            [
                "github unread since 2026-11-10T09:00: gh: no answer",
                "lazer over its $50 cap ($228), paid by lazer, not in our total",
            ]
        );
        assert!(b.flagged());
        // under a day unread: the watch is quiet, the tab says it now
        let b = build(&file(&[]), NOW);
        assert_eq!(b.needs[0], "lazer over its $50 cap ($228), paid by lazer, not in our total");
        assert_eq!(b.needs[1], "github unread: gh: no answer");
        // negative control: three hours old is stale, first
        let b = build(&file(&[]), NOW + 3 * 3600);
        assert!(b.stale);
        assert_eq!(b.needs[0], "stale: the fleet-bench budget step last wrote it 3h ago");
    }

    #[test]
    fn all_well_flags_nothing_and_no_file_says_why() {
        let mut f = file(&[]);
        f.lines.retain(|l| l.status == "ok");
        assert!(!build(&f, NOW).flagged());
        let m = missing("no such file".into());
        assert!(m.flagged() && m.bills.is_empty());
    }

    #[test]
    fn another_schema_is_refused_not_misread() {
        let dir = std::env::temp_dir().join(format!("budget-schema-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("budget.json");
        std::fs::write(&p, r#"{"schema":1,"total":{"spent":1}}"#).unwrap();
        assert!(load(&p).unwrap_err().contains("schema 1"));
        std::fs::write(&p, r#"{"schema":2,"total":{"spent":1}}"#).unwrap();
        assert!(load(&p).is_ok());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
