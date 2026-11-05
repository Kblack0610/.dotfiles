//! The task section of a project sheet: one `## Tasks`, the one parser shared by `projects`
//! (release) and `project_tasks` (ptask). `## Inbox` sits above it.
//!
//! ```markdown
//! # myapp
//! Version: v1.13.0
//!
//! ## Inbox
//!
//! ## Tasks
//! - [ ] full flow e2e
//! - [ ] android: sweep remaining screens #v1.14.0
//! - [ ]
//!
//! ---
//! ### Done
//! ```
//!
//! A row's release is its `#vX.Y.Z` tag. An untagged row, or one tagged at or below the
//! sheet's `Version:`, belongs to the open version; a tag above it aims the row at a later
//! release, and the current-version views leave it out. A release is a filter, never a section.

use crate::md;
use crate::projects;

pub(crate) type V = (u32, u32, u32);

/// The heading TEXT of the one task section, what `md::section_span` matches.
pub(crate) const TASKS: &str = "Tasks";
/// The heading TEXT of the section above it.
pub(crate) const INBOX: &str = "Inbox";

/// The sections a sheet ends in: the ONE place their shape is written.
pub(crate) fn skeleton() -> String {
    format!("## {INBOX}\n\n## {TASKS}\n- [ ] \n")
}

/// Does this sheet carry the task section?
pub(crate) fn has_tasks(content: &str) -> bool {
    let lines: Vec<&str> = content.lines().collect();
    md::section_span(&lines, TASKS).is_some()
}

/// Every open row of the section with its 1-based line number, whatever release it is aimed at.
pub(crate) fn open_rows(content: &str) -> Vec<(usize, &str)> {
    md::section_numbered(content, TASKS)
        .into_iter()
        .filter(|(_, l)| md::is_open_task(l))
        .collect()
}

/// The release a row's tag names, if it has one.
pub(crate) fn target(line: &str) -> Option<V> {
    md::version_tag(line).and_then(|t| projects::parse_version(t.trim_start_matches('#')))
}

/// Is this row aimed past the open version `cur`?
pub(crate) fn is_later(line: &str, cur: Option<V>) -> bool {
    matches!((target(line), cur), (Some(t), Some(c)) if t > c)
}

/// The version a row belongs to: its tag when that is ahead of `cur`, else `cur`.
pub(crate) fn version_of(line: &str, cur: Option<V>) -> Option<V> {
    match target(line) {
        Some(t) if cur.is_none_or(|c| t > c) => Some(t),
        _ => cur,
    }
}

/// The open rows of the open version: what a board shows and what a release gates on.
pub(crate) fn current_rows(content: &str, cur: Option<V>) -> Vec<(usize, &str)> {
    open_rows(content)
        .into_iter()
        .filter(|(_, l)| !is_later(l, cur))
        .collect()
}

/// The releases open rows are aimed at past `cur`, ascending and without repeats.
pub(crate) fn later_versions(content: &str, cur: Option<V>) -> Vec<V> {
    let mut out: Vec<V> = open_rows(content)
        .into_iter()
        .filter(|(_, l)| is_later(l, cur))
        .filter_map(|(_, l)| target(l))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "# a\nVersion: v1.13.0\n\n## Inbox\n- [ ] raw thought\n\n## Tasks\n- [ ] now\n- [/] going\n- [ ] later #v1.14.0\n- [ ] further #v1.15.0\n- [ ] stale #v1.2.0\n- [ ] \n\n---\n### Done\n- [x] shipped #v1.14.0\n\n## Notes\n- [ ] not a row\n";
    const CUR: Option<V> = Some((1, 13, 0));

    #[test]
    fn the_section_holds_the_rows_and_nothing_around_it() {
        let rows: Vec<&str> = open_rows(SHEET).into_iter().map(|(_, l)| l).collect();
        assert_eq!(rows.len(), 5, "{rows:?}");
        assert!(!rows
            .iter()
            .any(|l| l.contains("raw thought") || l.contains("not a row")));
        assert_eq!(open_rows(SHEET)[0].0, 8, "line numbers are the file's");
    }

    #[test]
    fn a_tag_ahead_of_the_version_is_the_only_thing_that_makes_a_row_later() {
        assert!(is_later("- [ ] x #v1.14.0", CUR));
        assert!(
            !is_later("- [ ] x #v1.13.0", CUR),
            "the open version itself"
        );
        assert!(!is_later("- [ ] x #v1.2.0", CUR), "a stale tag");
        assert!(!is_later("- [ ] x", CUR));
        assert!(
            !is_later("- [ ] x #v1.14.0", None),
            "nothing to be later than"
        );
    }

    #[test]
    fn a_rows_version_is_its_tag_only_when_the_tag_is_ahead() {
        assert_eq!(version_of("- [ ] x #v1.14.0", CUR), Some((1, 14, 0)));
        assert_eq!(version_of("- [ ] x #v1.2.0", CUR), CUR);
        assert_eq!(version_of("- [ ] x", CUR), CUR);
        assert_eq!(version_of("- [ ] x #v1.14.0", None), Some((1, 14, 0)));
        assert_eq!(version_of("- [ ] x", None), None);
    }

    #[test]
    fn the_current_view_leaves_out_later_rows_and_keeps_stale_ones() {
        let rows: Vec<&str> = current_rows(SHEET, CUR)
            .into_iter()
            .map(|(_, l)| l)
            .collect();
        assert_eq!(rows, ["- [ ] now", "- [/] going", "- [ ] stale #v1.2.0"]);
    }

    #[test]
    fn later_versions_read_only_open_rows() {
        assert_eq!(later_versions(SHEET, CUR), [(1, 14, 0), (1, 15, 0)]);
    }

    #[test]
    fn a_sheet_with_no_section_has_no_rows() {
        assert!(!has_tasks("# a\n\n### Tasks\n- [ ] nested\n"));
        assert!(open_rows("# a\n\nprose\n").is_empty());
        assert!(has_tasks(&skeleton()));
    }
}
