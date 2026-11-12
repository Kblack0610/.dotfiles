//! The fleet's front page: one row per question (you, outcome, quality, cost),
//! each counted by fleet-bench and read here from its gauges. fleet-bench judges and picks the
//! rows (`BENCH_VITALS`); this only words them, so Home, `hub vitals` and whatever reads that
//! say the same thing. No model and no composite score: a row names what is off.

use serde::Serialize;

use crate::home::Level;
use crate::infra::Infra;
use crate::phone::kpi;

const GAUGE: &str = "agent_bench_vital";
/// The window a row reads. A vital that is a level, not a rate, carries the same value in each.
const WINDOW: &str = "7d";

/// How a KPI's number reads: the gauge carries it bare, and its name says the unit.
#[derive(Clone, Copy)]
enum Unit {
    Plain,
    Usd,
    Share,
    Hours,
    Minutes,
}

/// Each KPI's words, `{}` standing for its number. A key with none reads as its own name.
const WORDS: [(&str, &str, Unit); 7] = [
    ("rework_candidate_7d", "Rework {}", Unit::Share),
    ("first_pass_share", "first pass {}", Unit::Share),
    ("human_answered_per_day", "{} answers a day", Unit::Plain),
    ("buzzes_per_day", "{} buzzes a day", Unit::Plain),
    ("cost_per_merged_item", "{} per merged item", Unit::Usd),
    ("requested_unstarted_h", "Oldest request {}", Unit::Hours),
    ("landed_unverified", "{} unverified", Unit::Plain),
];

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Row {
    pub question: String,
    /// Warn when a KPI is past its limit, Nodata when one has no reading, else Ok.
    pub level: Level,
    /// One clause per KPI; joined, they are the row's text, and a narrow screen stacks them.
    pub parts: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Vitals {
    /// "2 of 4 off target".
    pub head: String,
    /// The head and the questions it counts, for the surfaces that carry one line.
    pub line: String,
    /// Every row read and on target, so Home folds to the head (dashboards rule 4).
    pub all_ok: bool,
    pub rows: Vec<Row>,
}

impl Row {
    pub fn text(&self) -> String {
        self.parts.join("; ")
    }

    /// The row's mark: what the color says, for a surface or a reader without one.
    pub fn mark(&self) -> &'static str {
        match self.level {
            Level::Ok => " ",
            Level::Warn | Level::Red => "!",
            Level::Nodata => "?",
        }
    }
}

/// A number with no trailing zeros: 372, 0.5, 0.86.
fn plain(x: f64) -> String {
    let s = format!("{x:.2}");
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn number(x: f64, unit: Unit) -> String {
    match unit {
        Unit::Plain => plain(x),
        Unit::Usd => format!("${x:.2}"),
        Unit::Share => format!("{}%", plain((x * 1000.0).round() / 10.0)),
        Unit::Hours => number(x * 60.0, Unit::Minutes),
        Unit::Minutes if x < 60.0 => format!("{x:.0}m"),
        Unit::Minutes => format!("{:.0}h", x / 60.0),
    }
}

fn gauge(infra: &Infra, name: &str, key: &str) -> Option<f64> {
    kpi(infra, name, key, "")
}

/// "Oldest request 340h", then ", limit 72h" while it is past that limit; "?" for no reading.
fn clause(infra: &Infra, key: &str, past: bool) -> String {
    let (words, unit) = WORDS
        .iter()
        .find(|(k, _, _)| *k == key)
        .map_or((None, Unit::Plain), |(_, w, u)| (Some(*w), *u));
    let value = kpi(infra, "agent_bench_kpi", key, WINDOW).map_or("?".into(), |x| number(x, unit));
    let mut said = match words {
        Some(w) => w.replace("{}", &value),
        None => format!("{} {value}", key.replace('_', " ")),
    };
    if let Some(row) = subject(infra, key) {
        said = format!("{said} ({row})");
    }
    match gauge(infra, "agent_bench_kpi_limit", key).filter(|_| past) {
        Some(limit) => format!("{said}, limit {}", number(limit, unit)),
        None => said,
    }
}

/// The row behind a KPI that names one (`agent_bench_kpi_subject`), so the line says which.
fn subject<'a>(infra: &'a Infra, key: &str) -> Option<&'a str> {
    infra
        .get("bench")
        .iter()
        .find(|s| s.label("__name__") == "agent_bench_kpi_subject" && s.label("kpi") == key)
        .map(|s| s.label("subject"))
        .filter(|s| !s.is_empty())
}

fn title(question: &str) -> String {
    let mut c = question.chars();
    c.next()
        .map_or(String::new(), |f| f.to_uppercase().chain(c).collect())
}

/// The vitals alone, one query: for a surface that shows only their line (`hub vitals`), where a
/// full `gather` would ask everything and drop all but this.
pub fn fetch() -> Result<Vitals, String> {
    let base = crate::prom::base()?;
    let mut infra = Infra {
        ok: true,
        ..Default::default()
    };
    let bench = crate::prom::instant(&base, crate::infra::BENCH_QUERY)?;
    infra.instant.insert("bench", bench);
    read(&infra).ok_or_else(|| "did not answer".to_string())
}

/// The rows as fleet-bench last published them, in its order. None when Prometheus did not
/// answer, which Home already reports; an empty answer is a head saying so, never an all-clear.
pub fn read(infra: &Infra) -> Option<Vitals> {
    if !infra.ok {
        return None;
    }
    let mut keys: Vec<_> = infra
        .get("bench")
        .iter()
        .filter(|s| s.label("__name__") == GAUGE)
        .collect();
    keys.sort_by(|a, b| {
        a.value
            .partial_cmp(&b.value)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut rows: Vec<Row> = vec![];
    for s in keys {
        let key = s.label("kpi");
        let question = title(s.label("question"));
        let past = gauge(infra, "agent_bench_kpi_past", key) == Some(1.0);
        let read = kpi(infra, "agent_bench_kpi", key, WINDOW).is_some();
        let level = match (past, read) {
            (true, _) => Level::Warn,
            (false, false) => Level::Nodata,
            (false, true) => Level::Ok,
        };
        let part = clause(infra, key, past);
        match rows.iter_mut().find(|r| r.question == question) {
            Some(r) => {
                r.parts.push(part);
                r.level = worse(r.level, level);
            }
            None => rows.push(Row {
                question,
                level,
                parts: vec![part],
            }),
        }
    }
    Some(summed(rows))
}

/// Past a limit outranks no reading, and either outranks on target.
fn worse(a: Level, b: Level) -> Level {
    match (a, b) {
        (Level::Warn, _) | (_, Level::Warn) => Level::Warn,
        (Level::Nodata, _) | (_, Level::Nodata) => Level::Nodata,
        _ => Level::Ok,
    }
}

fn summed(rows: Vec<Row>) -> Vitals {
    let named = |l: Level| -> Vec<&str> {
        rows.iter()
            .filter(|r| r.level == l)
            .map(|r| r.question.as_str())
            .collect()
    };
    let (off, unread, total) = (named(Level::Warn), named(Level::Nodata), rows.len());
    let head = if total == 0 {
        "no reading from fleet-bench".to_string()
    } else if !off.is_empty() {
        format!("{} of {total} off target", off.len())
    } else if !unread.is_empty() {
        format!(
            "{} of {total} on target, {} unread",
            total - unread.len(),
            unread.len()
        )
    } else {
        format!("{total} of {total} on target")
    };
    let named: Vec<&str> = off.iter().chain(&unread).copied().collect();
    let line = if named.is_empty() {
        head.clone()
    } else {
        format!("{head}: {}", named.join(", "))
    };
    let all_ok = total > 0 && named.is_empty();
    Vitals {
        head,
        line,
        all_ok,
        rows,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn infra(rows: Vec<Value>) -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        let flat =
            crate::prom::flatten(&json!({"status": "success", "data": {"result": rows}})).unwrap();
        i.instant.insert("bench", flat);
        i
    }

    fn metric(name: &str, labels: Value, v: f64) -> Value {
        let mut m = labels;
        m["__name__"] = json!(name);
        json!({"metric": m, "value": [0, v.to_string()]})
    }

    /// One KPI's series: its row, its value and, when it has one, its limit and verdict.
    fn vital(row: f64, q: &str, k: &str, v: Option<f64>, limit: Option<(f64, f64)>) -> Vec<Value> {
        let mut out = vec![metric(GAUGE, json!({"question": q, "kpi": k}), row)];
        if let Some(v) = v {
            out.push(metric(
                "agent_bench_kpi",
                json!({"kpi": k, "window": "7d"}),
                v,
            ));
            out.push(metric(
                "agent_bench_kpi",
                json!({"kpi": k, "window": "28d"}),
                v + 999.0,
            ));
        }
        if let Some((l, past)) = limit {
            out.push(metric("agent_bench_kpi_limit", json!({"kpi": k}), l));
            out.push(metric("agent_bench_kpi_past", json!({"kpi": k}), past));
        }
        out
    }

    /// Today's fleet, as the plan's mockup draws it.
    fn fleet() -> Infra {
        let mut rows = vec![];
        for (i, (q, k, v, l)) in [
            (
                "you",
                "human_answered_per_day",
                Some(35.9),
                Some((5.0, 1.0)),
            ),
            ("you", "buzzes_per_day", Some(61.3), Some((15.0, 1.0))),
            (
                "outcome",
                "requested_unstarted_h",
                Some(340.0),
                Some((72.0, 1.0)),
            ),
            ("outcome", "landed_unverified", Some(12.0), Some((0.0, 1.0))),
            ("quality", "rework_candidate_7d", Some(0.254), None),
            ("quality", "first_pass_share", Some(0.438), Some((0.7, 1.0))),
            ("cost", "cost_per_merged_item", Some(12.537), None),
        ]
        .into_iter()
        .enumerate()
        .rev()
        {
            // Inserted last row first, so the order shown is the gauge's, not the read order.
            rows.extend(vital(i as f64, q, k, v, l));
        }
        infra(rows)
    }

    #[test]
    fn the_rows_read_as_the_mockup_does_in_fleet_benchs_order() {
        let v = read(&fleet()).unwrap();
        let said: Vec<String> = v
            .rows
            .iter()
            .map(|r| format!("{} {} {}", r.question, r.mark(), r.text()))
            .collect();
        assert_eq!(
            said,
            [
                "You ! 35.9 answers a day, limit 5; 61.3 buzzes a day, limit 15",
                "Outcome ! Oldest request 340h, limit 72h; 12 unverified, limit 0",
                "Quality ! Rework 25.4%; first pass 43.8%, limit 70%",
                "Cost   $12.54 per merged item",
            ]
        );
        assert_eq!(v.head, "3 of 4 off target");
        assert_eq!(v.line, "3 of 4 off target: You, Outcome, Quality");
        assert!(!v.all_ok);
    }

    #[test]
    fn a_limit_is_said_only_while_it_is_past() {
        let v = read(&infra(vital(
            0.0,
            "you",
            "buzzes_per_day",
            Some(4.0),
            Some((15.0, 0.0)),
        )));
        let v = v.unwrap();
        assert_eq!(v.rows[0].text(), "4 buzzes a day");
        assert_eq!(v.head, "1 of 1 on target");
        assert_eq!(v.line, "1 of 1 on target");
        assert!(v.all_ok, "green folds to the head");
    }

    #[test]
    fn a_missing_reading_is_a_question_mark_and_never_an_all_clear() {
        let v = read(&infra(vital(
            0.0,
            "cost",
            "cost_per_merged_item",
            None,
            None,
        )))
        .unwrap();
        assert_eq!(v.rows[0].text(), "? per merged item");
        assert_eq!(v.rows[0].level, Level::Nodata);
        assert_eq!(v.head, "0 of 1 on target, 1 unread");
        assert_eq!(v.line, "0 of 1 on target, 1 unread: Cost");
        assert!(!v.all_ok);
    }

    #[test]
    fn a_past_kpi_outranks_an_unread_one_in_the_same_row() {
        let mut rows = vital(0.0, "outcome", "landed_unverified", None, None);
        rows.extend(vital(
            1.0,
            "outcome",
            "requested_unstarted_h",
            Some(100.0),
            Some((72.0, 1.0)),
        ));
        assert_eq!(read(&infra(rows)).unwrap().rows[0].level, Level::Warn);
    }

    #[test]
    fn no_gauges_says_so_and_prometheus_down_is_homes_error_to_report() {
        let v = read(&infra(vec![])).unwrap();
        assert_eq!(v.head, "no reading from fleet-bench");
        assert!(
            !v.all_ok,
            "the control: nothing read is not 0 of 0 on target"
        );
        assert_eq!(read(&Infra::default()), None);
    }

    #[test]
    fn a_kpi_with_a_subject_names_its_row_and_one_without_does_not() {
        let mut rows = vital(
            0.0,
            "outcome",
            "requested_unstarted_h",
            Some(306.0),
            Some((72.0, 1.0)),
        );
        rows.push(metric(
            "agent_bench_kpi_subject",
            json!({"kpi": "requested_unstarted_h", "subject": "agent-runtime:ar-574"}),
            1.0,
        ));
        rows.extend(vital(1.0, "outcome", "landed_unverified", Some(1.0), None));
        let v = read(&infra(rows)).unwrap();
        assert_eq!(
            v.rows[0].text(),
            "Oldest request 306h (agent-runtime:ar-574), limit 72h; 1 unverified"
        );
    }

    #[test]
    fn a_key_with_no_words_reads_as_its_own_name() {
        let v = read(&infra(vital(0.0, "flow", "some_new_kpi", Some(3.0), None))).unwrap();
        assert_eq!(v.rows[0].text(), "some new kpi 3");
    }

    #[test]
    fn a_plain_number_has_no_trailing_zeros() {
        assert_eq!(plain(372.0), "372");
        assert_eq!(plain(0.5), "0.5");
        assert_eq!(plain(0.863), "0.86");
    }

    #[test]
    fn a_short_duration_reads_in_minutes_and_a_limit_never_reads_as_zero() {
        assert_eq!(number(3198.0, Unit::Minutes), "53h");
        assert_eq!(number(25.0, Unit::Minutes), "25m");
        assert_eq!(number(340.0, Unit::Hours), "340h");
        assert_eq!(number(0.5, Unit::Hours), "30m");
    }

    #[test]
    fn dollars_read_to_the_cent() {
        assert_eq!(number(12.537, Unit::Usd), "$12.54");
        assert_eq!(number(5.0, Unit::Usd), "$5.00");
    }
}
