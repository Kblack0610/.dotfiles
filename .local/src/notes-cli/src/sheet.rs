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

/// One line waiting in `## Inbox`: the human's words as typed and the indented lines under it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct InboxLine {
    /// 1-based file line of the inbox line itself.
    pub line: usize,
    /// The line as it is on the sheet, what `--exact` matches.
    pub raw: String,
    /// The words: the line with its bullet and checkbox taken off, nothing else touched.
    pub text: String,
    /// Its indented lines, trimmed.
    pub details: Vec<String>,
}

/// The words of an inbox line: `- [ ] x`, `- x` and `x` all read as `x`.
pub(crate) fn inbox_text(line: &str) -> String {
    let t = line.trim();
    let t = ["- [ ]", "- [/]", "- [x]", "- [X]", "-", "*"]
        .iter()
        .find_map(|p| t.strip_prefix(p))
        .unwrap_or(t);
    t.trim().to_string()
}

/// The lines waiting in `## Inbox`, in sheet order. Every top-level line counts, whatever the
/// human typed: a checkbox row, a bare bullet or a sentence. A line indented under one is its
/// detail; a comment line is neither.
pub(crate) fn inbox_lines(content: &str) -> Vec<InboxLine> {
    lines_in(content, INBOX)
}

/// The lines waiting under `## <heading>`, read the way [`inbox_lines`] reads `## Inbox`. The
/// outbox (`outbox.rs`) is the other section with this grammar.
pub(crate) fn lines_in(content: &str, heading: &str) -> Vec<InboxLine> {
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, heading) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut i = span.start;
    while i < span.end {
        let l = lines[i];
        let t = l.trim();
        if t.is_empty()
            || l.starts_with([' ', '\t'])
            || (t.starts_with("<!--") && t.ends_with("-->"))
        {
            i += 1;
            continue;
        }
        let end = md::row_block_end(&lines, i).min(span.end);
        let text = inbox_text(l);
        if text.is_empty() {
            i = end;
            continue;
        }
        out.push(InboxLine {
            line: i + 1,
            raw: l.trim_end().to_string(),
            text,
            details: md::row_details(&lines[..end], i),
        });
        i = end;
    }
    out
}

/// `content` with `block` at the end of `## Inbox`, the section added above `## Tasks` (or at
/// the foot of a sheet with neither) when the sheet has none. Oldest first, so the triager
/// files in the order the human wrote.
pub(crate) fn put_in_inbox(content: &str, block: &[String]) -> String {
    put_in(content, INBOX, block)
}

/// `content` with `block` at the end of `## <heading>`, placed as [`put_in_inbox`] places it.
pub(crate) fn put_in(content: &str, heading: &str, block: &[String]) -> String {
    let refs: Vec<&str> = content.lines().collect();
    let (inbox, tasks) = (
        md::section_span(&refs, heading),
        md::section_span(&refs, TASKS),
    );
    let mut lines: Vec<String> = refs.iter().map(|l| (*l).to_string()).collect();
    let at = match inbox {
        Some(span) => {
            let mut at = span.end;
            while at > span.start && lines[at - 1].trim().is_empty() {
                at -= 1;
            }
            at
        }
        None => {
            let heading = format!("## {heading}");
            match tasks {
                Some(span) => {
                    let at = span.start - 1;
                    lines.splice(at..at, [heading, String::new()]);
                    at + 1
                }
                None => {
                    while lines.last().is_some_and(|l| l.trim().is_empty()) {
                        lines.pop();
                    }
                    lines.extend([String::new(), heading]);
                    lines.len()
                }
            }
        }
    };
    lines.splice(at..at, block.iter().cloned());
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// `content` with the first inbox line `hits` accepts removed, its detail lines with it, and
/// that line. None when nothing in `## Inbox` matches.
pub(crate) fn take_inbox<P>(content: &str, hits: P) -> Option<(String, InboxLine)>
where
    P: Fn(&InboxLine) -> bool,
{
    take_in(content, INBOX, hits)
}

/// [`take_inbox`] for any section with the inbox grammar.
pub(crate) fn take_in<P>(content: &str, heading: &str, hits: P) -> Option<(String, InboxLine)>
where
    P: Fn(&InboxLine) -> bool,
{
    let found = lines_in(content, heading).into_iter().find(|l| hits(l))?;
    let lines: Vec<&str> = content.lines().collect();
    let start = found.line - 1;
    let end = start + 1 + found.details.len();
    let mut out: Vec<&str> = lines[..start].to_vec();
    out.extend_from_slice(&lines[end..]);
    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    Some((joined, found))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_top_level_inbox_line_is_waiting_and_indented_ones_are_its_details() {
        let s = "# a\n\n## Inbox\n- [ ] raw thought\n  more words\n- bare bullet\nplain sentence\n<!-- note -->\n\n## Tasks\n- [ ] row\n";
        let got = inbox_lines(s);
        let texts: Vec<&str> = got.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(texts, ["raw thought", "bare bullet", "plain sentence"]);
        assert_eq!(got[0].details, ["more words"]);
        assert_eq!(got[0].line, 4);
        assert_eq!(got[1].raw, "- bare bullet");
        assert!(inbox_lines("# a\n\n## Tasks\n- [ ] row\n").is_empty());
    }

    #[test]
    fn a_new_inbox_line_goes_last_and_the_section_is_made_above_tasks() {
        let s = "# a\n\n## Inbox\n- [ ] one\n\n## Tasks\n- [ ] row\n";
        let got = put_in_inbox(s, &["- [ ] two".into()]);
        assert_eq!(
            got,
            "# a\n\n## Inbox\n- [ ] one\n- [ ] two\n\n## Tasks\n- [ ] row\n"
        );
        let bare = put_in_inbox("# a\n\n## Tasks\n- [ ] row\n", &["- [ ] x".into()]);
        assert_eq!(bare, "# a\n\n## Inbox\n- [ ] x\n\n## Tasks\n- [ ] row\n");
        let none = put_in_inbox("# a\n\nprose\n\n", &["- [ ] x".into()]);
        assert_eq!(none, "# a\n\nprose\n\n## Inbox\n- [ ] x\n");
    }

    #[test]
    fn taking_an_inbox_line_takes_its_details_and_leaves_the_rest() {
        let s = "# a\n\n## Inbox\n- [ ] one\n  why\n- [ ] two\n\n## Tasks\n- [ ] one\n";
        let (rest, got) = take_inbox(s, |l| l.text == "one").unwrap();
        assert_eq!(got.details, ["why"]);
        assert_eq!(rest, "# a\n\n## Inbox\n- [ ] two\n\n## Tasks\n- [ ] one\n");
        assert!(
            take_inbox(s, |l| l.text == "row").is_none(),
            "Tasks is not the inbox"
        );
    }

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
