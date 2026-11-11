//! Money made: one `Source` per store or broker, each read by its collector and said as one
//! line in the briefing's Money section. App stores come from `store-sales <day>`
//! (docs/operations/store-sales.md). A source that could not be read carries its reason and no
//! amount, so it is said as not read, never as $0.

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
    /// What the amount is: `proceeds` (after the store's cut) or `charged` (what buyers paid).
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

/// The app stores' sales on `day` (`YYYY-MM-DD`), or why `store-sales` could not run.
pub fn apps(runner: &dyn Runner, day: &str) -> Result<Vec<Source>, String> {
    let raw = runner
        .run(&["store-sales".to_string(), day.to_string()])
        .map_err(|e| format!("store-sales: {e}"))?;
    serde_json::from_str::<Report>(&raw)
        .map(|r| r.sources)
        .map_err(|e| format!("store-sales: {e}"))
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
    fn the_report_parses_both_shapes() {
        struct Fake;
        impl Runner for Fake {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                assert_eq!(argv, ["store-sales", "2026-11-09"]);
                Ok(r#"{"date":"2026-11-09","sources":[
                    {"name":"App Store","basis":"proceeds","made":[{"currency":"USD","amount":2.1}],"sales":3,"titles":["Shape City"]},
                    {"name":"Google Play","basis":"charged","error":"no rbw entry store_sales_play"}]}"#
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
    }
}
