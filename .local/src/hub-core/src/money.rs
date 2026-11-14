//! Money made: one `Source` per store or broker, each read by its collector and said as one
//! line in the briefing's Money section. The app stores and Steam come from `store-sales <day>`;
//! the trader's paper accounts from Prometheus (`trader`). Both: docs/operations/store-sales.md.
//! A source that could not be read carries its reason and no amount, so it is said as not read,
//! never as $0.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::queue::money;
use crate::session_actions::Runner;

/// Titles one line names before "and N more".
pub const TITLES_SHOWN: usize = 3;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Amount {
    pub currency: String,
    pub amount: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Source {
    pub name: String,
    /// What the amount is: `proceeds` (after the store's cut), `charged` (what buyers paid),
    /// `net` (Steam: after refunds and tax, before Valve's cut) or `P&L` (`PNL`: a trader
    /// account's change in equity over the day).
    #[serde(default)]
    pub basis: String,
    /// None when the source could not be read; empty when it was and nothing sold.
    #[serde(default)]
    pub made: Option<Vec<Amount>>,
    #[serde(default)]
    pub sales: u64,
    /// Titles sold, most units first.
    #[serde(default)]
    pub titles: Vec<String>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Deserialize)]
struct Report {
    sources: Vec<Source>,
}

/// The stores' sales on `day` (`YYYY-MM-DD`), or why `store-sales` could not run.
pub fn apps(runner: &dyn Runner, day: &str) -> Result<Vec<Source>, String> {
    let raw = runner
        .run(&["store-sales".to_string(), day.to_string()])
        .map_err(|e| format!("store-sales: {e}"))?;
    serde_json::from_str::<Report>(&raw)
        .map(|r| r.sources)
        .map_err(|e| format!("store-sales: {e}"))
}

/// The basis of a trader source: its change in equity from one local midnight to the next.
pub const PNL: &str = "P&L";

/// An equity reading older than this at either midnight leaves the day not read. The broker
/// read runs hourly and the paper league marks every few minutes, so this is two missed reads.
pub const TRADER_STALE_SECS: f64 = 3.0 * 3600.0;

/// The trader's sources: name, equity query, read-age query. The trader exports only paper
/// accounts to Prometheus (its web/exporter.py keeps real ones out), so each name says paper.
/// A live account needs its own reader once the trader's live guard lifts (its docs/live.md).
/// The paper league trades Kalshi's books; its equity less capital is its profit, so an account
/// joining the league adds nothing on its first day.
const TRADER: [(&str, &str, &str); 2] = [
    (
        "Alpaca (paper)",
        r#"max(trader_broker_equity{broker="alpaca_paper"})"#,
        r#"max(trader_broker_read_age_seconds{broker="alpaca_paper"})"#,
    ),
    (
        "Kalshi paper league",
        "sum(max by (account) (trader_paper_equity) - max by (account) (trader_paper_capital))",
        "max(trader_paper_marked_age_seconds)",
    ),
];

/// `day`'s local midnight and the next one, in unix seconds; None for a date that does not parse.
pub fn day_bounds(day: &str) -> Option<(i64, i64)> {
    let next = NaiveDate::parse_from_str(day, "%Y-%m-%d")
        .ok()?
        .succ_opt()?;
    Some((
        crate::home::day_start(day)?,
        crate::home::day_start(&next.format("%Y-%m-%d").to_string())?,
    ))
}

/// One instant query at a unix time: its value, None when it has no series then.
pub type At<'a> = dyn Fn(&str, i64) -> Result<Option<f64>, String> + 'a;

/// What each trader account made over `day`, read through `at`.
pub fn trader(at: &At, day: &str) -> Vec<Source> {
    let bounds = day_bounds(day).ok_or_else(|| format!("{day} has no local midnight"));
    // The source's value at `t`, unless Prometheus has none then or it was read too long before.
    let value_at = |value: &str, age: &str, t: i64| -> Result<f64, String> {
        let when = crate::fleet::local_minute(t);
        let v = at(value, t)?.ok_or_else(|| format!("no reading at {when}"))?;
        let old = at(age, t)?.ok_or_else(|| format!("no read age at {when}"))?;
        if old > TRADER_STALE_SECS {
            return Err(format!(
                "the reading at {when} was {:.0}h old",
                old / 3600.0
            ));
        }
        Ok(v)
    };
    let read = |value: &str, age: &str| -> Result<f64, String> {
        let (start, end) = bounds.clone()?;
        Ok(value_at(value, age, end)? - value_at(value, age, start)?)
    };
    TRADER
        .iter()
        .map(|(name, value, age)| {
            let (made, error) = match read(value, age) {
                Ok(d) => (
                    Some(vec![Amount {
                        currency: "USD".into(),
                        amount: d,
                    }]),
                    None,
                ),
                Err(e) => (None, Some(e)),
            };
            Source {
                name: name.to_string(),
                basis: PNL.into(),
                made,
                error,
                ..Default::default()
            }
        })
        .collect()
}

/// The trader's sources for `day`, read from Prometheus (`CC_PROM_URL`).
pub fn trader_from_prom(day: &str) -> Vec<Source> {
    let base = crate::prom::base();
    let at = |q: &str, t: i64| -> Result<Option<f64>, String> {
        let b = base.as_ref().map_err(String::clone)?;
        crate::prom::query(b, "query", &[("query", q.into()), ("time", t.to_string())])
            .map(|s| s.first().and_then(|x| x.value))
    };
    trader(&at, day)
}

/// "$12.34", or "$12.34 + EUR 3.10" when a store pays out in more than one currency.
fn amounts(made: &[Amount]) -> String {
    let mut v: Vec<&Amount> = made.iter().collect();
    v.sort_by_key(|a| a.currency != "USD");
    v.iter()
        .map(|a| match a.currency.as_str() {
            "USD" => money(a.amount),
            c => format!("{c} {:.2}", a.amount),
        })
        .collect::<Vec<_>>()
        .join(" + ")
}

/// One Money line: what the source made yesterday, that nothing sold, or why it was not read.
pub fn line(s: &Source) -> String {
    let made = match (&s.made, &s.error) {
        (Some(m), None) => m,
        (_, e) => {
            return format!(
                "{}: not read, {}.",
                s.name,
                e.as_deref().unwrap_or("no amount").trim_end_matches('.')
            )
        }
    };
    if s.basis == PNL {
        let d: f64 = made.iter().map(|a| a.amount).sum();
        return match d {
            d if d.abs() < 0.005 => format!("{}: flat yesterday.", s.name),
            d if d > 0.0 => format!("{}: made {} yesterday.", s.name, money(d)),
            d => format!("{}: lost {} yesterday.", s.name, money(-d)),
        };
    }
    if made.is_empty() {
        return format!("{}: no sales yesterday.", s.name);
    }
    if s.sales == 0 {
        return format!(
            "{}: {} {} from refunds, no sales.",
            s.name,
            amounts(made),
            s.basis
        );
    }
    let sales = if s.sales == 1 {
        "1 sale".to_string()
    } else {
        format!("{} sales", s.sales)
    };
    let mut titles = s
        .titles
        .iter()
        .take(TITLES_SHOWN)
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    if s.titles.len() > TITLES_SHOWN {
        titles += &format!(" and {} more", s.titles.len() - TITLES_SHOWN);
    }
    format!(
        "{}: {} {} from {sales} ({titles}).",
        s.name,
        amounts(made),
        s.basis
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(
        made: Option<Vec<(&str, f64)>>,
        sales: u64,
        titles: &[&str],
        error: Option<&str>,
    ) -> Source {
        Source {
            name: "App Store".into(),
            basis: "proceeds".into(),
            made: made.map(|m| {
                m.into_iter()
                    .map(|(c, a)| Amount {
                        currency: c.into(),
                        amount: a,
                    })
                    .collect()
            }),
            sales,
            titles: titles.iter().map(|t| t.to_string()).collect(),
            error: error.map(String::from),
        }
    }

    #[test]
    fn a_read_source_says_amount_basis_sales_and_titles() {
        let s = src(
            Some(vec![("EUR", 1.5), ("USD", 12.345)]),
            5,
            &["Shape City", "Place My Parent"],
            None,
        );
        assert_eq!(
            line(&s),
            "App Store: $12.35 + EUR 1.50 proceeds from 5 sales (Shape City, Place My Parent)."
        );
    }

    #[test]
    fn titles_past_the_cap_fold_to_a_count() {
        let s = src(
            Some(vec![("USD", 4.0)]),
            4,
            &["a", "b", "c", "d", "e"],
            None,
        );
        assert!(line(&s).ends_with("(a, b, c and 2 more)."), "{}", line(&s));
    }

    #[test]
    fn an_unread_source_is_never_zero() {
        // negative control: no credential reads as not read, not as "$0" or "no sales"
        let s = src(None, 0, &[], Some("no rbw entry store_sales_asc"));
        assert_eq!(
            line(&s),
            "App Store: not read, no rbw entry store_sales_asc."
        );
        assert!(!line(&s).contains('$'));
    }

    #[test]
    fn a_day_of_refunds_only_shows_the_amount() {
        let s = src(Some(vec![("USD", -0.7)]), 0, &[], None);
        assert_eq!(
            line(&s),
            "App Store: $-0.70 proceeds from refunds, no sales."
        );
    }

    #[test]
    fn a_read_day_with_nothing_sold_says_so() {
        assert_eq!(
            line(&src(Some(vec![]), 0, &[], None)),
            "App Store: no sales yesterday."
        );
    }

    #[test]
    fn the_report_parses_every_shape() {
        struct Fake;
        impl Runner for Fake {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                assert_eq!(argv, ["store-sales", "2026-11-09"]);
                Ok(r#"{"date":"2026-11-09","sources":[
                    {"name":"App Store","basis":"proceeds","made":[{"currency":"USD","amount":2.1}],"sales":3,"titles":["Shape City"]},
                    {"name":"Google Play","basis":"charged","error":"no rbw entry store_sales_play"},
                    {"name":"Steam","basis":"net","made":[{"currency":"USD","amount":17.98}],"sales":2,"titles":["Apociseum"]}]}"#
                    .into())
            }
        }
        let v = apps(&Fake, "2026-11-09").unwrap();
        assert_eq!(
            line(&v[0]),
            "App Store: $2.10 proceeds from 3 sales (Shape City)."
        );
        assert_eq!(
            line(&v[1]),
            "Google Play: not read, no rbw entry store_sales_play."
        );
        assert_eq!(line(&v[2]), "Steam: $17.98 net from 2 sales (Apociseum).");
    }

    /// A fake Prometheus: `(query fragment, at start?) -> value`; absent means no series.
    fn prom(
        day: &str,
        rows: Vec<(&'static str, bool, f64)>,
    ) -> impl Fn(&str, i64) -> Result<Option<f64>, String> {
        let (start, _) = day_bounds(day).unwrap();
        move |q: &str, t: i64| {
            Ok(rows
                .iter()
                .find(|(frag, at_start, _)| q.contains(frag) && *at_start == (t == start))
                .map(|r| r.2))
        }
    }

    const ALPACA: &str = "trader_broker_equity";
    const ALPACA_AGE: &str = "trader_broker_read_age";
    const LEAGUE: &str = "trader_paper_equity";
    const LEAGUE_AGE: &str = "trader_paper_marked_age";

    #[test]
    fn a_trader_day_is_the_equity_change_between_midnights() {
        let at = prom(
            "2026-11-13",
            vec![
                (ALPACA, true, 100_000.0),
                (ALPACA, false, 100_012.5),
                (ALPACA_AGE, true, 600.0),
                (ALPACA_AGE, false, 2540.0),
                (LEAGUE, true, -400.0),
                (LEAGUE, false, -473.28),
                (LEAGUE_AGE, true, 60.0),
                (LEAGUE_AGE, false, 556.0),
            ],
        );
        let v = trader(&at, "2026-11-13");
        let lines: Vec<String> = v.iter().map(line).collect();
        assert_eq!(
            lines,
            [
                "Alpaca (paper): made $12.50 yesterday.",
                "Kalshi paper league: lost $73.28 yesterday."
            ]
        );
    }

    #[test]
    fn a_trader_day_without_a_reading_at_either_end_is_not_read() {
        // negative control: the series began after the day's start, so the day is not read,
        // never "flat" or $0
        let at = prom(
            "2026-11-13",
            vec![
                (ALPACA, false, 100_000.0),
                (ALPACA_AGE, false, 2540.0),
                (LEAGUE, true, 0.0),
                (LEAGUE, false, 0.0),
                (LEAGUE_AGE, true, 60.0),
                (LEAGUE_AGE, false, 60.0),
            ],
        );
        let v = trader(&at, "2026-11-13");
        assert_eq!(
            line(&v[0]),
            "Alpaca (paper): not read, no reading at 2026-11-13 00:00."
        );
        assert!(!line(&v[0]).contains('$'));
        assert_eq!(line(&v[1]), "Kalshi paper league: flat yesterday.");
    }

    #[test]
    fn a_stale_equity_reading_leaves_the_day_not_read() {
        let at = prom(
            "2026-11-13",
            vec![
                (ALPACA, true, 100_000.0),
                (ALPACA, false, 100_000.0),
                (ALPACA_AGE, true, 600.0),
                (ALPACA_AGE, false, 5.0 * 3600.0),
            ],
        );
        assert_eq!(
            line(&trader(&at, "2026-11-13")[0]),
            "Alpaca (paper): not read, the reading at 2026-11-14 00:00 was 5h old."
        );
    }

    #[test]
    fn an_unreachable_prometheus_reads_every_trader_source_as_not_read() {
        let at = |_: &str, _: i64| -> Result<Option<f64>, String> {
            Err("cannot read http://prom".into())
        };
        let v = trader(&at, "2026-11-13");
        assert_eq!(v.len(), TRADER.len());
        assert!(v.iter().all(|s| s.made.is_none()
            && s.error.as_deref() == Some("cannot read http://prom")
            && s.basis == PNL));
    }

    #[test]
    fn day_bounds_span_one_local_day() {
        let (a, b) = day_bounds("2026-11-13").unwrap();
        assert!((23 * 3600..=25 * 3600).contains(&(b - a)), "{a} {b}");
        assert_eq!(crate::fleet::local_minute(a), "2026-11-13 00:00");
        assert!(day_bounds("yesterday").is_none());
    }
}
