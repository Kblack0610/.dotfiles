//! The Costs tab's Sections block: what each section of a repo costs to build, from
//! `fleet-bench sections --json` (PRs, first-try share, gate reds and minutes, greens lost, and
//! the claiming session's cost, tokens and work minutes per PR). fleet-bench counts every figure;
//! this words them and sorts the table, so the hub TUI and agent-web print the same block.
//!
//! A PR counts in every section it touches, so the rows add up to more than All PRs, which is
//! the one row that does not double count and always sits on top. Cost, tokens and work minutes
//! cover only the PRs a session claims.

use serde::{Deserialize, Serialize};

use crate::table::{Row, Summary, Val, View};

/// The pinned first row's name.
pub const ALL: &str = "All PRs";

/// One section's row, or the whole window's (`fleet-bench sections --json` `all`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Section {
    pub section: String,
    pub prs: u64,
    /// The PRs with a gate run, what the gate figures divide by.
    pub gated: u64,
    /// The PRs a session claims, what cost, tokens and work minutes divide by.
    pub with_session: u64,
    pub first_try: Option<f64>,
    pub reds_per_pr: Option<f64>,
    pub gate_min_per_pr: Option<f64>,
    pub gate_h: Option<f64>,
    pub green_lost: u64,
    pub cost_per_pr: Option<f64>,
    pub tokens_per_pr: Option<f64>,
    pub work_min_per_pr: Option<f64>,
}

impl Row for Section {
    const COLUMNS: &'static [&'static str] = &[
        "section",
        "prs",
        "first_try",
        "reds_per_pr",
        "gate_min_per_pr",
        "gate_h",
        "green_lost",
        "cost_per_pr",
        "tokens_per_pr",
        "work_min_per_pr",
    ];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &[];

    fn val(&self, col: &str) -> Val {
        let num = |n: Option<f64>| n.map_or(Val::None, Val::Num);
        match col {
            "section" => Val::Text(self.section.clone()),
            "prs" => Val::Num(self.prs as f64),
            "first_try" => num(self.first_try),
            "reds_per_pr" => num(self.reds_per_pr),
            "gate_min_per_pr" => num(self.gate_min_per_pr),
            "gate_h" => num(self.gate_h),
            "green_lost" => Val::Num(self.green_lost as f64),
            "cost_per_pr" => num(self.cost_per_pr),
            "tokens_per_pr" => num(self.tokens_per_pr),
            "work_min_per_pr" => num(self.work_min_per_pr),
            _ => Val::None,
        }
    }

    fn in_state(&self, _: &str) -> bool {
        true
    }
}

impl Section {
    /// One cell as both surfaces print it; `-` is no figure (no gated PR, no claiming session).
    pub fn show(&self, col: &str) -> String {
        let f = |n: Option<f64>, p: usize| n.map_or("-".into(), |n| format!("{n:.p$}"));
        match col {
            "section" => self.section.clone(),
            "prs" => self.prs.to_string(),
            "first_try" => self
                .first_try
                .map_or("-".into(), |n| format!("{:.0}%", n * 100.0)),
            "reds_per_pr" => f(self.reds_per_pr, 2),
            "gate_min_per_pr" => f(self.gate_min_per_pr, 0),
            "gate_h" => f(self.gate_h, 0),
            "green_lost" => self.green_lost.to_string(),
            "cost_per_pr" => crate::costs::usd(self.cost_per_pr),
            "tokens_per_pr" => crate::costs::tokens(self.tokens_per_pr),
            "work_min_per_pr" => f(self.work_min_per_pr, 0),
            _ => "-".into(),
        }
    }

    fn cells(&self) -> Vec<String> {
        Self::COLUMNS.iter().map(|c| self.show(c)).collect()
    }
}

/// One read of `fleet-bench sections --json`, in fleet-bench's order (the most gate hours first).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Sections {
    pub days: u32,
    pub all: Section,
    pub rows: Vec<Section>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Wire {
    days: u32,
    all: Section,
    sections: Vec<Section>,
}

/// The CLI's JSON; the pinned row is named here, the one place that knows its name.
pub fn parse(out: &str) -> Result<Sections, String> {
    let w: Wire = serde_json::from_str(out.trim()).map_err(|e| e.to_string())?;
    let mut all = w.all;
    all.section = ALL.into();
    Ok(Sections {
        days: w.days,
        all,
        rows: w.sections,
    })
}

/// What a surface draws for the block: the headline, the pinned row, the sorted rows as printed
/// cells, and the two things the figures cannot say alone.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Block {
    pub days: u32,
    /// The always-visible line over the fold, from All PRs.
    pub head: String,
    /// The columns' keys in display order, the header's cells.
    pub columns: &'static [&'static str],
    /// Each column's header words, parallel to `columns`, so both surfaces print the same ones.
    pub headers: Vec<&'static str>,
    pub all: Vec<String>,
    pub rows: Vec<Vec<String>>,
    /// Both caveats, one line each, counted from the same read.
    pub notes: Vec<String>,
    /// The sort and the sort a click on each header gives (`table.columns`).
    pub table: Option<Summary>,
}

/// The block under one sort. An empty read (no section roots, or the CLI failed) has no `table`.
pub fn board(s: &Sections, sort: &str, dir: &str) -> Block {
    let mut b = Block {
        days: s.days,
        columns: Section::COLUMNS,
        headers: Section::COLUMNS.iter().map(|c| header(c)).collect(),
        ..Block::default()
    };
    if s.rows.is_empty() && s.all.prs == 0 {
        return b;
    }
    let (rows, table) = View::new::<Section>("", "", sort, dir).summary(&s.rows);
    b.head = format!(
        "{} PRs in {}d, {} first try, {} gate min per PR, {} greens lost",
        s.all.prs,
        s.days,
        s.all.show("first_try"),
        s.all.show("gate_min_per_pr"),
        s.all.green_lost,
    );
    b.all = s.all.cells();
    b.rows = rows.into_iter().map(Section::cells).collect();
    b.notes = vec![
        "A PR counts in every section it touches, so the rows add up to more than All PRs.".into(),
        format!(
            "Cost, tokens and work min cover only the PRs a session claims ({} of {} in All PRs).",
            s.all.with_session, s.all.prs
        ),
    ];
    b.table = Some(table);
    b
}

/// A column's header, the words both surfaces print.
fn header(col: &str) -> &'static str {
    match col {
        "section" => "section",
        "prs" => "PRs",
        "first_try" => "first try",
        "reds_per_pr" => "gate reds/PR",
        "gate_min_per_pr" => "gate min/PR",
        "gate_h" => "gate h",
        "green_lost" => "greens lost",
        "cost_per_pr" => "cost/PR",
        "tokens_per_pr" => "tokens/PR",
        "work_min_per_pr" => "work min/PR",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const JSON: &str = r#"{"days":7,
      "all":{"prs":10,"gated":8,"with_session":4,"first_try":0.5,"reds_per_pr":1.25,"gate_min_per_pr":144.7,"gate_h":19,"green_lost":3,"cost_per_pr":7.3,"tokens_per_pr":14030412,"work_min_per_pr":34.4},
      "sections":[
        {"section":"Assets/A","prs":6,"gated":6,"with_session":3,"first_try":0.4,"reds_per_pr":2,"gate_min_per_pr":200,"gate_h":20,"green_lost":2,"cost_per_pr":8,"tokens_per_pr":2000000,"work_min_per_pr":40},
        {"section":"docs","prs":9,"gated":1,"with_session":0,"first_try":1,"reds_per_pr":0,"gate_min_per_pr":30,"gate_h":1,"green_lost":0,"cost_per_pr":null,"tokens_per_pr":null,"work_min_per_pr":null},
        {"section":"other","prs":2,"gated":2,"with_session":2,"first_try":0,"reds_per_pr":3,"gate_min_per_pr":90,"gate_h":3,"green_lost":1,"cost_per_pr":2.5,"tokens_per_pr":500,"work_min_per_pr":10}]}"#;

    fn names(b: &Block) -> Vec<&str> {
        b.rows.iter().map(|r| r[0].as_str()).collect()
    }

    #[test]
    fn all_prs_is_named_and_the_rows_keep_fleet_benchs_order() {
        let s = parse(JSON).unwrap();
        assert_eq!(s.all.section, ALL);
        let b = board(&s, "", "");
        assert_eq!(names(&b), ["Assets/A", "docs", "other"]);
        assert_eq!(b.all[0], "All PRs");
        assert_eq!(
            b.all,
            ["All PRs", "10", "50%", "1.25", "145", "19", "3", "$7.30", "14M", "34"]
        );
    }

    #[test]
    fn every_column_sorts_both_ways_and_a_missing_figure_sorts_last_either_way() {
        let s = parse(JSON).unwrap();
        for col in Section::COLUMNS {
            let d = board(&s, col, "desc");
            let a = board(&s, col, "asc");
            let (d, a) = (names(&d), names(&a));
            assert_eq!(d.len(), 3, "{col}");
            if matches!(*col, "cost_per_pr" | "tokens_per_pr" | "work_min_per_pr") {
                assert_eq!(*d.last().unwrap(), "docs", "{col} desc: no figure last");
                assert_eq!(*a.last().unwrap(), "docs", "{col} asc: no figure last");
            } else {
                let mut r = a.clone();
                r.reverse();
                assert_eq!(d, r, "{col}: ascending is descending reversed");
            }
        }
        assert_eq!(
            names(&board(&s, "prs", "desc")),
            ["docs", "Assets/A", "other"]
        );
        assert_eq!(
            names(&board(&s, "prs", "asc")),
            ["other", "Assets/A", "docs"]
        );
        let t = board(&s, "prs", "desc").table.unwrap();
        let prs = t.columns.iter().find(|c| c.key == "prs").unwrap();
        assert_eq!(
            (prs.next_sort.as_str(), prs.next_dir),
            ("prs", crate::table::Dir::Asc)
        );
    }

    #[test]
    fn the_note_says_both_things_and_counts_the_claimed_prs() {
        let b = board(&parse(JSON).unwrap(), "", "");
        assert!(b.notes[0].contains("counts in every section it touches"));
        assert!(b.notes[1].contains("only the PRs a session claims (4 of 10"));
        assert_eq!(
            b.head,
            "10 PRs in 7d, 50% first try, 145 gate min per PR, 3 greens lost"
        );
    }

    #[test]
    fn a_repo_with_no_sections_has_no_block_and_bad_json_is_an_error() {
        let b = board(
            &parse(r#"{"days":7,"all":{"prs":0},"sections":[]}"#).unwrap(),
            "",
            "",
        );
        assert!(b.table.is_none() && b.rows.is_empty() && b.head.is_empty());
        assert!(parse("not json").is_err());
    }
}
