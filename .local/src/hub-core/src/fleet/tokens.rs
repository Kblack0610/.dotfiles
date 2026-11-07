//! Fleet's "Where the tokens go": tool output by tool and by Bash command, over the newest week
//! of snapshots and the newest day. It sums `~/.agent/token-usage/<day>.json`, the nightly record
//! `agent-usage tokens snapshot` writes from `claude-recall tool-output`; running that from a view
//! takes minutes. The dollars per tool are the Costs tab's tool cut, over the same files.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{Days, NaiveDate};
use serde::Serialize;

use crate::costs::{snapshots, Snapshot, ToolDay, STALE_SECS};

/// Calendar days the week view sums, the newest snapshot's day the last.
const WEEK_DAYS: usize = 7;
/// Rows named in each table before the rest fold into Other: agent-web's four chart `SLOTS`
/// (dashboards rule 5).
const NAMED: usize = 4;
/// The tool the `by_command` heads split.
const SHELL: &str = "Bash";

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Tokens {
    /// The newest snapshot's day, and when it was written.
    pub date: String,
    pub generated_at: Option<i64>,
    /// Older than `costs::STALE_SECS` or undated: both surfaces turn the head amber.
    pub stale: bool,
    pub week: Split,
    /// The newest snapshot alone: yesterday, unless the nightly run stopped.
    pub day: Split,
}

/// One window's totals and its two tables.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Split {
    /// Snapshots summed, and how many of them name an error or lack `by_tool`.
    pub days: usize,
    pub partial: usize,
    pub context: u64,
    pub per_response: u64,
    /// Share of the context that was carried tool output.
    pub carried_share: f64,
    pub tools: Vec<Share>,
    pub commands: Vec<Share>,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Share {
    pub name: String,
    pub calls: u64,
    pub chars: u64,
    /// Of all tool output in the window, so a Bash command's reads against the whole.
    pub share: f64,
    pub carried_tokens: u64,
    /// The rest of the table, not a tool or command of that name.
    pub other: bool,
}

/// The newest week of snapshots in `dir`. None with no snapshot at all, which is no error: the
/// head says so. A file that does not parse is named in `errors` and the others still count.
pub fn read(dir: &Path, now: i64, errors: &mut Vec<String>) -> Option<Tokens> {
    let mut found = snapshots(dir, WEEK_DAYS, errors);
    let newest = found.first()?;
    let (date, generated_at) = (newest.date.clone(), newest.generated_at);
    // A night the run missed leaves no file, and "7d" must not reach back past it.
    let first =
        NaiveDate::parse_from_str(&date, "%Y-%m-%d").ok()? - Days::new(WEEK_DAYS as u64 - 1);
    let first = first.format("%Y-%m-%d").to_string();
    found.retain(|d| d.date >= first);
    Some(Tokens {
        date,
        generated_at,
        stale: generated_at.is_none_or(|t| now - t > STALE_SECS),
        week: split(&found),
        day: split(&found[..1]),
    })
}

fn split(days: &[Snapshot]) -> Split {
    let tools = summed(days.iter().flat_map(|d| &d.tools));
    let commands = summed(days.iter().flat_map(|d| &d.commands));
    let all = total(&tools);
    let (context, responses, carried) = days
        .iter()
        .filter_map(|d| d.totals.as_ref())
        .fold((0, 0, 0), |a, t| {
            (a.0 + t.context, a.1 + t.responses, a.2 + t.carried_tokens)
        });
    // A snapshot keeps only each day's top commands, so the shell's own row is the whole they
    // split: the commands listed fall short of it.
    let shell = tools.iter().find(|t| t.tool == SHELL).cloned();
    let unnamed_tools = tools.len().saturating_sub(NAMED);
    Split {
        days: days.len(),
        partial: days
            .iter()
            .filter(|d| d.errors > 0 || d.tools.is_empty())
            .count(),
        context,
        per_response: context.checked_div(responses).unwrap_or(0),
        carried_share: ratio(carried, context),
        tools: shares(&tools, &all, all.chars, format!("Other ({unnamed_tools})")),
        commands: shares(
            &commands,
            &shell.unwrap_or_default(),
            all.chars,
            "Other".into(),
        ),
    }
}

/// Each name's days added up, the largest first.
fn summed<'a>(rows: impl Iterator<Item = &'a ToolDay>) -> Vec<ToolDay> {
    let mut by: BTreeMap<&str, ToolDay> = BTreeMap::new();
    for r in rows {
        let c = by.entry(&r.tool).or_insert_with(|| ToolDay {
            tool: r.tool.clone(),
            ..Default::default()
        });
        c.calls += r.calls;
        c.chars += r.chars;
        c.carried_tokens += r.carried_tokens;
    }
    let mut out: Vec<ToolDay> = by.into_values().collect();
    out.sort_by(|a, b| b.chars.cmp(&a.chars).then_with(|| a.tool.cmp(&b.tool)));
    out
}

fn total(rows: &[ToolDay]) -> ToolDay {
    rows.iter().fold(ToolDay::default(), |a, r| ToolDay {
        calls: a.calls + r.calls,
        chars: a.chars + r.chars,
        carried_tokens: a.carried_tokens + r.carried_tokens,
        ..a
    })
}

/// The first `NAMED` rows, then what `whole` holds beyond them as Other; nothing left, no row.
fn shares(rows: &[ToolDay], whole: &ToolDay, all_chars: u64, other: String) -> Vec<Share> {
    let named = &rows[..rows.len().min(NAMED)];
    let shown = total(named);
    let rest = ToolDay {
        tool: other,
        calls: whole.calls.saturating_sub(shown.calls),
        chars: whole.chars.saturating_sub(shown.chars),
        carried_tokens: whole.carried_tokens.saturating_sub(shown.carried_tokens),
        ..Default::default()
    };
    let row = |c: &ToolDay, other| Share {
        name: c.tool.clone(),
        calls: c.calls,
        chars: c.chars,
        share: ratio(c.chars, all_chars),
        carried_tokens: c.carried_tokens,
        other,
    };
    named
        .iter()
        .map(|c| row(c, false))
        .chain((rest.chars > 0).then(|| row(&rest, true)))
        .collect()
}

fn ratio(part: u64, whole: u64) -> f64 {
    if whole == 0 {
        0.0
    } else {
        part as f64 / whole as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    struct Dir(std::path::PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn dir(tag: &str) -> Dir {
        let d = std::env::temp_dir().join(format!("hub-tokens-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Dir(d)
    }

    fn stamp(age: i64) -> String {
        chrono::DateTime::from_timestamp(NOW - age, 0)
            .unwrap()
            .to_rfc3339()
    }

    fn day(d: &Dir, date: &str, age: i64, bash: u64, sed: u64) {
        let doc = serde_json::json!({
            "generated_at": stamp(age),
            "errors": [],
            "totals": {"responses": 10, "context": 1000, "carried_tokens": 150},
            "by_tool": [
                {"tool": "Bash", "calls": 4, "chars": bash, "carried_tokens": 100},
                {"tool": "Read", "calls": 1, "chars": 100, "carried_tokens": 50},
            ],
            "by_command": [{"head": "sed", "calls": 2, "chars": sed, "carried_tokens": 60}],
        });
        std::fs::write(d.0.join(format!("{date}.json")), doc.to_string()).unwrap();
    }

    #[test]
    fn an_empty_or_missing_dir_is_no_section_and_no_error() {
        let d = dir("empty");
        let mut errors = vec![];
        assert_eq!(read(&d.0, NOW, &mut errors), None);
        assert_eq!(read(&d.0.join("none"), NOW, &mut errors), None);
        assert!(errors.is_empty());
    }

    #[test]
    fn the_week_sums_the_days_and_the_day_is_the_newest_alone() {
        let d = dir("sum");
        day(&d, "2027-01-14", 90_000, 300, 100);
        day(&d, "2027-01-15", 3_600, 900, 200);
        let t = read(&d.0, NOW, &mut vec![]).unwrap();
        assert_eq!(t.date, "2027-01-15");
        assert!(!t.stale);
        assert_eq!((t.week.days, t.day.days), (2, 1));
        assert_eq!(t.week.context, 2000);
        assert_eq!(t.week.per_response, 100);
        assert_eq!(t.week.carried_share, 0.15);
        assert_eq!(t.week.tools[0].name, "Bash");
        assert_eq!(t.week.tools[0].chars, 1200);
        assert_eq!(t.day.tools[0].chars, 900);
    }

    #[test]
    fn only_the_newest_seven_snapshots_count() {
        let d = dir("seven");
        for n in 1..=9 {
            day(&d, &format!("2027-01-{n:02}"), 3_600, 100, 10);
        }
        let t = read(&d.0, NOW, &mut vec![]).unwrap();
        assert_eq!(t.week.days, 7);
        assert_eq!(t.week.context, 7000);
    }

    #[test]
    fn a_night_with_no_snapshot_does_not_stretch_the_week() {
        let d = dir("gap");
        for n in [1, 2, 10, 11, 12] {
            day(&d, &format!("2027-01-{n:02}"), 3_600, 100, 10);
        }
        let t = read(&d.0, NOW, &mut vec![]).unwrap();
        assert_eq!((t.date.as_str(), t.week.days), ("2027-01-12", 3));
    }

    #[test]
    fn a_snapshot_past_the_limit_or_undated_is_stale() {
        let d = dir("stale");
        day(&d, "2027-01-15", STALE_SECS + 1, 100, 10);
        assert!(read(&d.0, NOW, &mut vec![]).unwrap().stale);
        day(&d, "2027-01-15", STALE_SECS, 100, 10);
        assert!(!read(&d.0, NOW, &mut vec![]).unwrap().stale);
        std::fs::write(d.0.join("2027-01-15.json"), "{}").unwrap();
        assert!(read(&d.0, NOW, &mut vec![]).unwrap().stale);
    }

    #[test]
    fn a_broken_file_is_named_and_the_others_still_count() {
        let d = dir("broken");
        day(&d, "2027-01-14", 3_600, 100, 10);
        std::fs::write(d.0.join("2027-01-15.json"), "not json").unwrap();
        let mut errors = vec![];
        let t = read(&d.0, NOW, &mut errors).unwrap();
        assert_eq!(t.date, "2027-01-14");
        assert_eq!(errors, ["tokens: 2027-01-15.json does not parse"]);
    }

    #[test]
    fn a_snapshot_without_by_tool_or_with_errors_counts_as_partial() {
        let d = dir("partial");
        day(&d, "2027-01-13", 3_600, 100, 10);
        std::fs::write(d.0.join("2027-01-14.json"), r#"{"errors":["recall"]}"#).unwrap();
        std::fs::write(d.0.join("2027-01-15.json"), "{}").unwrap();
        let t = read(&d.0, NOW, &mut vec![]).unwrap();
        assert_eq!((t.week.days, t.week.partial), (3, 2));
    }

    #[test]
    fn past_the_slots_tools_fold_into_a_counted_other() {
        let c = |name: &str, chars| ToolDay {
            tool: name.into(),
            calls: 1,
            chars,
            carried_tokens: 2,
            ..Default::default()
        };
        let tools = vec![
            c("Bash", 60),
            c("Read", 20),
            c("Grep", 10),
            c("Glob", 5),
            c("Edit", 3),
            c("Write", 2),
        ];
        let s = split(&[Snapshot {
            tools,
            ..Default::default()
        }]);
        let names: Vec<&str> = s.tools.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["Bash", "Read", "Grep", "Glob", "Other (2)"]);
        let other = &s.tools[NAMED];
        assert_eq!((other.calls, other.chars, other.share), (2, 5, 0.05));
        assert_eq!(other.carried_tokens, 4);
    }

    #[test]
    fn commands_are_shares_of_all_output_and_their_other_is_the_rest_of_the_shell() {
        let d = dir("cmd");
        // 1000 chars in all, 900 of them the shell's, 200 of those the one listed head.
        day(&d, "2027-01-15", 3_600, 900, 200);
        let t = read(&d.0, NOW, &mut vec![]).unwrap();
        let c = &t.week.commands;
        assert_eq!(c[0].name, "sed");
        assert_eq!(c[0].share, 0.2);
        assert_eq!((c[1].name.as_str(), c[1].chars), ("Other", 700));
        assert_eq!((c[1].calls, c[1].carried_tokens), (2, 40));
    }

    #[test]
    fn the_costs_answer_does_not_carry_what_only_fleet_reads() {
        let text = r#"{"by_tool":[{"tool":"Bash","calls":1,"chars":9,"carried_tokens":2}],
            "by_command":[{"head":"sed","calls":1,"chars":9}],"totals":{"context":5},"errors":["x"]}"#;
        let s = crate::costs::snapshot("2027-01-15", text).unwrap();
        assert_eq!(s.tools[0].chars, 9);
        assert_eq!(s.commands[0].tool, "sed");
        assert_eq!(s.totals.as_ref().unwrap().context, 5);
        assert_eq!(s.errors, 1);
        let answer = serde_json::to_string(&s).unwrap();
        for field in ["chars", "commands", "totals", "errors"] {
            assert!(!answer.contains(field), "{answer}");
        }
    }

    #[test]
    fn no_tool_output_divides_by_nothing() {
        let s = split(&[Snapshot::default()]);
        assert_eq!((s.per_response, s.carried_share), (0, 0.0));
        assert!(s.tools.is_empty() && s.commands.is_empty());
    }
}
