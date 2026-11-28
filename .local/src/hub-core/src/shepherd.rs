//! The shepherd's numbers: `fleet-shepherd stats`, the object the MQTT feed publishes, read once
//! here. The capacity header's shepherd part ([`crate::capacity`]) and the Shepherd tab on both
//! surfaces (agent-web, the hub TUI) take it from [`read`], and the tab's pass card is worded once
//! by [`Card::of`], so neither surface parses the object or words the pass itself.

use serde::Serialize;
use serde_json::Value;

use crate::display::fmt::dur_secs;
use crate::session_actions::{argv, Runner};

/// `fleet-shepherd stats`, or why there is none: it did not run, or printed no object. Only an
/// object counts: an error line or empty output is no stats, not a page of nulls.
pub fn read(runner: &dyn Runner) -> Result<Value, String> {
    runner
        .run(&argv(&["fleet-shepherd", "stats"]))
        .and_then(|out| parse(&out))
}

/// The object in `out`.
fn parse(out: &str) -> Result<Value, String> {
    match serde_json::from_str::<Value>(out) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err("not an object".into()),
        Err(e) => Err(e.to_string()),
    }
}

/// The Shepherd tab's pass card, in the words both surfaces draw.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Card {
    /// The flags that need a look, amber: `stuck`, `2 unhandled, 3 checks in a row`.
    pub flags: Vec<String>,
    /// Why it is stuck, when it is.
    pub why: String,
    /// The pass running now, or the last one, and what attaches to it.
    pub now: String,
    pub attach: String,
    /// The last verdict.
    pub last: String,
    /// The last day's counts and the ledger's.
    pub totals: String,
}

fn short(id: Option<&str>) -> String {
    id.unwrap_or_default().chars().take(8).collect()
}

fn n(v: &Value, key: &str) -> i64 {
    v[key].as_i64().unwrap_or(0)
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or_default()
}

impl Card {
    pub fn of(x: &Value) -> Card {
        let mut flags = vec![];
        if x["stuck"] == true {
            flags.push("stuck".to_string());
        }
        if n(x, "unhandled") > 0 {
            flags.push(format!(
                "{} unhandled, {} checks in a row",
                n(x, "unhandled"),
                n(x, "unhandled_checks")
            ));
        }
        let id = short(x["pass_id"].as_str());
        let status = s(x, "pass_status");
        let has_pass = x["pass_running"] == true || !id.is_empty();
        let now = if x["pass_running"] == true {
            format!(
                "pass {id} {status}, {}:",
                dur_secs(n(x, "pass_age_s") as f64)
            )
        } else if !id.is_empty() {
            format!("no pass running; the last was {id} ({status}):")
        } else {
            "no pass on record".to_string()
        };
        let last = if x["last_pass_id"].as_str().is_some_and(|i| !i.is_empty()) {
            let verdict = Some(s(x, "last_verdict")).filter(|v| !v.is_empty());
            format!(
                "last verdict {} for pass {}, {} ago",
                verdict.unwrap_or("?"),
                short(x["last_pass_id"].as_str()),
                dur_secs(n(x, "last_pass_age_s") as f64)
            )
        } else {
            "no verdict on record".to_string()
        };
        Card {
            flags,
            why: s(x, "stuck_why").to_string(),
            attach: if has_pass {
                s(x, "attach").to_string()
            } else {
                String::new()
            },
            now,
            last,
            totals: format!(
                "last 24h: {} passes, {} nudges, {} escalations, {} skips; {} due, {} skipped, {} paged",
                n(x, "passes_24h"),
                n(x, "nudges_24h"),
                n(x, "escalations_24h"),
                n(x, "skips_24h"),
                n(x, "due"),
                n(x, "skipped"),
                n(x, "paged")
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct Said(Result<&'static str, &'static str>);

    impl Runner for Said {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv, ["fleet-shepherd", "stats"]);
            self.0.map(String::from).map_err(String::from)
        }
    }

    #[test]
    fn stats_are_the_object_fleet_shepherd_prints_and_nothing_else() {
        let got = read(&Said(Ok(
            r#"{"due":2,"pass_id":"sid","last_verdict":"WORKED"}"#,
        )))
        .unwrap();
        assert_eq!(got["due"], 2);
        assert_eq!(got["last_verdict"], "WORKED");
        assert!(read(&Said(Ok(""))).is_err());
        assert!(read(&Said(Ok("fleet-shepherd: no ledger"))).is_err());
        assert!(read(&Said(Ok("[1,2]"))).is_err());
        assert_eq!(read(&Said(Err("exit 1"))), Err("exit 1".into()));
    }

    #[test]
    fn a_running_pass_says_its_age_and_how_to_attach() {
        let c = Card::of(
            &json!({"pass_running":true,"pass_id":"0123456789","pass_status":"working",
            "pass_age_s":300,"attach":"tmux attach -t sh","last_pass_id":"abcdefghij",
            "last_verdict":"WORKED","last_pass_age_s":7200,"passes_24h":4,"nudges_24h":3,
            "escalations_24h":1,"skips_24h":2,"due":2,"skipped":1,"paged":0}),
        );
        assert_eq!(c.now, "pass 01234567 working, 5m:");
        assert_eq!(c.attach, "tmux attach -t sh");
        assert_eq!(c.last, "last verdict WORKED for pass abcdefgh, 2h00m ago");
        assert_eq!(
            c.totals,
            "last 24h: 4 passes, 3 nudges, 1 escalations, 2 skips; 2 due, 1 skipped, 0 paged"
        );
        assert!(c.flags.is_empty());
    }

    #[test]
    fn a_stuck_or_unhandled_pass_is_flagged_and_an_idle_one_has_nothing_to_attach() {
        let c = Card::of(
            &json!({"stuck":true,"stuck_why":"no pass for 3h","unhandled":2,
            "unhandled_checks":3,"pass_id":"sid","pass_status":"done","attach":"x"}),
        );
        assert_eq!(c.flags, ["stuck", "2 unhandled, 3 checks in a row"]);
        assert_eq!(c.why, "no pass for 3h");
        assert_eq!(c.now, "no pass running; the last was sid (done):");
        assert_eq!(c.attach, "x");
        let none = Card::of(&json!({}));
        assert_eq!(none.now, "no pass on record");
        assert_eq!(none.attach, "");
        assert_eq!(none.last, "no verdict on record");
    }
}
