//! The one order open rows are worked in: what the sheet's sections are cut from, and what
//! every reader of `notes board --json` sorts by instead of deriving its own.
//!
//! Smaller is sooner: a row due soon, then the priority tag, then a row the human asked for
//! (`#requested`), then the oldest `#cMMDD`. Ties keep file order (callers sort stably).
//! Counted from the row's own tags, so the order explains itself and no model scores it.
//! One input is not the row's own: a row aimed at the project's targeted version ([`Aim`])
//! takes the target day as its due date when that is sooner. It ranks; it never pins.

use std::collections::HashSet;
use std::path::Path;

use chrono::NaiveDate;

use crate::sheet::V;
use crate::{epics, md, project_tasks, projects, sheet};

/// The project's targeted version (`Target: vX.Y.Z YYYY-MM-DD` in the human sheet's head) and
/// the rows aimed at it: a row tagged with that version, or an untagged row under one (`#of/`,
/// at any depth). Such a row ranks as if due on the target day, through the same due bucket a
/// `#due` tag uses, so it only moves once the day is within [`DUE_SOON_DAYS`]. A row's own tag
/// wins over its parent's: a row aimed at another release does not inherit. Parents are read
/// from the project's own two sheets only, so a child whose `#of/` names another project's
/// row does not inherit. A target day already past ranks the aimed rows overdue, as a past
/// `#due` would: the release is late, and P3's `release-late` watch pages for a new date.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Aim {
    pub version: V,
    pub on: NaiveDate,
    /// Ids of the rows aimed at `version`: the parents an untagged child inherits from.
    ids: HashSet<String>,
}

/// The task sheet text under `dir`, empty when it has none.
fn sheet_text(dir: &Path) -> String {
    project_tasks::task_sheet(dir)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default()
}

impl Aim {
    /// The aim of the project whose human sheet sits in `dir`, from both sheets on disk; `None`
    /// when the head carries no target.
    pub(crate) fn of(dir: &Path) -> Option<Aim> {
        Aim::of_sheets(&sheet_text(dir), &sheet_text(&projects::agent_dir(dir)))
    }

    /// [`Aim::of`] with one lane's text in hand (an editor buffer being swept, `agent` true for
    /// the agent board) and the other lane's read from disk.
    pub(crate) fn of_swept(dir: &Path, agent: bool, content: &str) -> Option<Aim> {
        if agent {
            Aim::of_sheets(&sheet_text(dir), content)
        } else {
            Aim::of_sheets(content, &sheet_text(&projects::agent_dir(dir)))
        }
    }

    /// The aim the human sheet's head sets over both sheets' rows; `None` with no target.
    fn of_sheets(human: &str, agent: &str) -> Option<Aim> {
        let target = projects::target_of(human)?;
        Some(Aim::from_sheets(target, &[human, agent]))
    }

    /// The aim at `target` over the rows of `sheets`: the ids grow from the rows tagged with
    /// the version through each untagged child, until a pass adds none.
    pub(crate) fn from_sheets(target: projects::Target, sheets: &[&str]) -> Aim {
        let rows: Vec<(Option<V>, Option<String>, String)> = sheets
            .iter()
            .flat_map(|s| s.lines())
            .filter(|l| l.trim_start().starts_with("- ["))
            .filter_map(|l| Some((sheet::target(l), epics::parent_of(l), md::row_id(l)?)))
            .collect();
        let mut aim = Aim {
            version: target.0,
            on: target.1,
            ids: HashSet::new(),
        };
        loop {
            let before = aim.ids.len();
            for (tag, parent, id) in &rows {
                if aim.aims(*tag, parent.as_deref()) {
                    aim.ids.insert(id.clone());
                }
            }
            if aim.ids.len() == before {
                return aim;
            }
        }
    }

    fn aims(&self, tag: Option<V>, parent: Option<&str>) -> bool {
        match tag {
            Some(v) => v == self.version,
            None => parent.is_some_and(|p| self.ids.contains(p)),
        }
    }

    /// The target day when `line` is aimed at the targeted version, else `None`.
    pub(crate) fn due_of(&self, line: &str) -> Option<NaiveDate> {
        self.aims(sheet::target(line), epics::parent_of(line).as_deref())
            .then_some(self.on)
    }
}

/// The tag the human's own asks carry (`ptask add --want`).
const REQUESTED: &str = "#requested";

/// Days ahead a due date pulls a row up: the same window `fleet-dispatch` RANK_JQ uses.
pub(crate) const DUE_SOON_DAYS: i64 = 3;

/// [`Rank::due`] of a row due later than [`DUE_SOON_DAYS`] or not at all: below it, the row is
/// due soon.
pub(crate) const DUE_LATER: u8 = 3;

/// One row's place in the rank. Field order is the sort order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Rank {
    /// 0 overdue, 1 due today, 2 due within [`DUE_SOON_DAYS`], [`DUE_LATER`] later or no due date.
    pub due: u8,
    /// Index into [`md::PRIORITIES`]: 0 `#urgent`, 1 `#high`, 2 `#normal`, 3 `#low`; untagged is
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
        let day = (self.created - NaiveDate::default())
            .num_days()
            .clamp(0, 999_999) as u64;
        let head = (u64::from(self.due) * md::PRIORITIES.len() as u64 + u64::from(self.prio)) * 2
            + u64::from(self.req);
        head * 1_000_000 + day
    }
}

/// The rank of `line` on `today` from its own tags alone: what pinning reads, since only a
/// row's own `#due` pins it.
pub(crate) fn of(line: &str, today: NaiveDate) -> Rank {
    aimed(line, today, None)
}

/// The rank of `line` on `today`, its due date the sooner of its own `#due` and, when `aim`
/// covers it, the target day: the order the sweep lays rows out in and the feed prints.
pub(crate) fn aimed(line: &str, today: NaiveDate, aim: Option<&Aim>) -> Rank {
    let due = match md::find_due(line, today)
        .into_iter()
        .chain(aim.and_then(|a| a.due_of(line)))
        .min()
        .map(|d| (d - today).num_days())
    {
        Some(n) if n < 0 => 0,
        Some(0) => 1,
        Some(n) if n <= DUE_SOON_DAYS => 2,
        _ => DUE_LATER,
    };
    let prio = md::priority_index(line).unwrap_or(md::DEFAULT_PRIORITY) as u8;
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

    use crate::md::date as d;

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
            of("- [ ] tagged #normal", d(TODAY)).prio
        );
    }

    #[test]
    fn an_untagged_row_ranks_after_high_and_before_low() {
        // Negative control: on the three-level table (bare row ranked as #high) the first
        // assertion fails.
        let out = sorted(&[
            "- [ ] low #low #c1001",
            "- [ ] bare #c1001",
            "- [ ] high #high #c1001",
            "- [ ] normal #normal #c1002",
            "- [ ] fire #urgent #c1001",
        ]);
        assert_eq!(out, ["fire", "high", "bare", "normal", "low"]);
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
    fn a_row_aimed_at_the_target_takes_its_day_and_others_do_not() {
        let human = "# d\nVersion: v1.0.0\nTarget: v1.1.0 2026-11-10\n\n## Tasks\n\
- [ ] epic(app): ship it #v1.1.0 <!-- id:dm-1 -->\n\
- [ ] feature(app): part #of/dm-1 <!-- id:dm-2 -->\n";
        let agent = "## Tasks\n- [ ] story #of/dm-2\n- [ ] later story #of/dm-1 #v1.2.0\n";
        let aim = Aim::from_sheets(((1, 1, 0), d("2026-11-10")), &[human, agent]);
        let today = d(TODAY);
        let due = |l: &str| aimed(l, today, Some(&aim)).due;
        // Tagged, under the epic at depth two: due tomorrow, bucket 2.
        assert_eq!(due("- [ ] tagged #v1.1.0"), 2);
        assert_eq!(due("- [ ] story #of/dm-2"), 2);
        // Its own tag names another release, or it is not under the aim at all: no inherit.
        assert_eq!(due("- [ ] later story #of/dm-1 #v1.2.0"), DUE_LATER);
        assert_eq!(due("- [ ] plain"), DUE_LATER);
        // Its own sooner #due wins; the aim never pushes a row later.
        assert_eq!(due("- [ ] story #of/dm-2 #due1108"), 0);
        // Pinning reads the own rank, which the aim does not touch.
        assert_eq!(of("- [ ] story #of/dm-2", today).due, DUE_LATER);
    }

    #[test]
    fn a_far_target_moves_nothing() {
        let aim = Aim::from_sheets(((1, 1, 0), d("2026-12-15")), &[]);
        let l = "- [ ] tagged #v1.1.0";
        assert_eq!(aim.due_of(l), Some(d("2026-12-15")));
        assert_eq!(aimed(l, d(TODAY), Some(&aim)), of(l, d(TODAY)));
    }

    #[test]
    fn requested_inside_the_marker_does_not_count() {
        assert_eq!(of("- [ ] x #high <!-- #requested -->", d(TODAY)).req, 1);
    }
}
