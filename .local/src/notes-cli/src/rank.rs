//! The one order open rows are worked in: what the sheet's sections are cut from, and what
//! every reader of `notes board --json` sorts by instead of deriving its own.
//!
//! Smaller is sooner: a row due soon, then the priority tag, then a row the human asked for
//! (`#requested`), then the oldest `#cMMDD`. Ties keep file order (callers sort stably).
//! Counted from the row's own tags, so the order explains itself and no model scores it.

use chrono::NaiveDate;

use crate::md;

/// The tag the human's own asks carry (`ptask add --want`).
const REQUESTED: &str = "#requested";

/// Days ahead a due date pulls a row up: the same window `fleet-dispatch` RANK_JQ uses.
const DUE_SOON_DAYS: i64 = 3;

/// One row's place in the rank. Field order is the sort order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Rank {
    /// 0 overdue, 1 due today, 2 due within [`DUE_SOON_DAYS`], 3 later or no due date.
    pub due: u8,
    /// Index into [`md::PRIORITIES`]: 0 `#urgent`, 1 `#high`, 2 `#low`; untagged is
    /// [`md::DEFAULT_PRIORITY`].
    pub prio: u8,
    /// 0 when the human asked for it.
    pub req: u8,
    /// The created day; an undated row sorts as made today, after every dated one.
    pub created: NaiveDate,
}

impl Rank {
    /// The rank as one number, smaller sooner, in the same order as the struct: what
    /// `notes board --json` prints in `rank`, so a reader sorts rows from different sheets
    /// (one project's two lanes, the queue's candidates) by one integer and derives nothing.
    pub(crate) fn key(&self) -> u64 {
        // Days since 1970 fit in six digits until the year 4707.
        let day = (self.created - NaiveDate::default()).num_days().clamp(0, 999_999) as u64;
        let head = (u64::from(self.due) * md::PRIORITIES.len() as u64 + u64::from(self.prio))
            * 2
            + u64::from(self.req);
        head * 1_000_000 + day
    }
}

/// The rank of `line` on `today`.
pub(crate) fn of(line: &str, today: NaiveDate) -> Rank {
    let due = match md::find_due(line, today).map(|d| (d - today).num_days()) {
        Some(n) if n < 0 => 0,
        Some(0) => 1,
        Some(n) if n <= DUE_SOON_DAYS => 2,
        _ => 3,
    };
    let prio = md::task_priority(line)
        .and_then(|t| md::PRIORITIES.iter().position(|(_, hash, _)| *hash == t))
        .unwrap_or(md::DEFAULT_PRIORITY) as u8;
    let head = line.split("<!--").next().unwrap_or(line);
    let req = u8::from(!head.split_whitespace().any(|t| t == REQUESTED));
    let created = md::find_created(line, today).unwrap_or(today);
    Rank {
        due,
        prio,
        req,
        created,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    const TODAY: &str = "2026-11-09";

    fn sorted(rows: &[&str]) -> Vec<String> {
        let mut v: Vec<&str> = rows.to_vec();
        v.sort_by_key(|l| of(l, d(TODAY)));
        v.iter()
            .map(|l| md::task_text(l).replace(" #requested", ""))
            .collect()
    }

    #[test]
    fn due_beats_priority_and_priority_beats_requested_and_age() {
        let out = sorted(&[
            "- [ ] old low #low #c0901",
            "- [ ] asked high #high #requested #c1105",
            "- [ ] plain high #high #c1001",
            "- [ ] fire #urgent #c1108",
            "- [ ] overdue low #low #due1101",
            "- [ ] due today #low #due1109",
            "- [ ] due far #low #due1230",
        ]);
        assert_eq!(
            out,
            [
                "overdue low",
                "due today",
                "fire",
                "asked high",
                "plain high",
                "old low",
                "due far"
            ]
        );
    }

    #[test]
    fn an_untagged_row_ranks_as_the_default_priority() {
        assert_eq!(
            of("- [ ] bare", d(TODAY)).prio,
            of("- [ ] tagged #high", d(TODAY)).prio
        );
    }

    #[test]
    fn the_key_sorts_exactly_as_the_rank_does() {
        let rows = [
            "- [ ] old low #low #c0901",
            "- [ ] asked high #high #requested #c1105",
            "- [ ] plain high #high #c1001",
            "- [ ] fire #urgent #c1108",
            "- [ ] overdue low #low #due1101",
            "- [ ] due today #low #due1109",
            "- [ ] due far #low #due1230",
            "- [ ] bare",
        ];
        let mut by_rank: Vec<&str> = rows.to_vec();
        by_rank.sort_by_key(|l| of(l, d(TODAY)));
        let mut by_key: Vec<&str> = rows.to_vec();
        by_key.sort_by_key(|l| of(l, d(TODAY)).key());
        assert_eq!(by_rank, by_key);
        assert!(of(rows[4], d(TODAY)).key() < of(rows[3], d(TODAY)).key());
    }

    #[test]
    fn requested_inside_the_marker_does_not_count() {
        assert_eq!(of("- [ ] x #high <!-- #requested -->", d(TODAY)).req, 1);
    }
}
