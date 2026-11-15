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

/// Is `l` a whole-line comment, which the inbox grammar reads past?
fn is_comment(l: &str) -> bool {
    let t = l.trim();
    t.starts_with("<!--") && t.ends_with("-->")
}

/// A `---` or `***` line, a separator and never an item.
fn is_rule(t: &str) -> bool {
    t.len() >= 3 && (t.chars().all(|c| c == '-') || t.chars().all(|c| c == '*'))
}

/// An unticked checkbox with words: what makes a line a list.
fn is_open_box(t: &str) -> bool {
    (t.starts_with("- [ ]") || t.starts_with("- [/]")) && !inbox_text(t).is_empty()
}

/// Leading spaces and tabs, the only indent the inbox grammar writes, so a cut there is a char boundary.
fn indent_of(l: &str) -> usize {
    l.len() - l.trim_start_matches([' ', '\t']).len()
}

/// `body` with each run of indented lines no top-level line owns, and that opens with an open
/// checkbox, moved left as a run, its own nesting kept. `lines_in` reads past such a run, so a
/// pasted block indented as a whole would wait for ever unseen. Any other run (a detail after a
/// blank line) is not an ask and stays where it is.
fn dedent_orphans(body: &[&str]) -> Vec<String> {
    let indented = |l: &str| l.starts_with([' ', '\t']) && !l.trim().is_empty();
    let mut out = Vec::new();
    let mut i = 0;
    while i < body.len() {
        if !indented(body[i]) {
            let end = if body[i].trim().is_empty() {
                i + 1
            } else {
                md::row_block_end(body, i)
            };
            out.extend(body[i..end].iter().map(|l| l.to_string()));
            i = end;
            continue;
        }
        let end = (i..body.len())
            .find(|&e| !indented(body[e]))
            .unwrap_or(body.len());
        if !is_open_box(body[i].trim()) {
            out.extend(body[i..end].iter().map(|l| l.to_string()));
            i = end;
            continue;
        }
        let cut = body[i..end].iter().map(|l| indent_of(l)).min().unwrap_or(0);
        out.extend(
            body[i..end]
                .iter()
                .filter(|l| !is_rule(l.trim()))
                .map(|l| l[cut..].to_string()),
        );
        i = end;
    }
    out
}

/// A heading word every item of its list takes: where it goes, its lane, plan-first, priority.
fn is_inherited(w: &str) -> bool {
    md::project_tag_word(w).is_some()
        || md::agent_tag(w)
        || w.eq_ignore_ascii_case("#plan")
        || w.eq_ignore_ascii_case("#go")
        || (w.starts_with('#') && md::is_priority(w))
}

/// `words` with each `heading` tag it does not already set, before any marker comment. A `#p:`
/// or a priority it carries replaces the heading's: the item's own word is the later one.
fn with_inherited(words: &str, heading: &[&str]) -> String {
    let (body, mark) = words.split_at(words.find("<!--").unwrap_or(words.len()));
    let own: Vec<&str> = body.split_whitespace().collect();
    let sets = |tag: &str| {
        own.iter().any(|o| {
            o.eq_ignore_ascii_case(tag)
                || (md::project_tag_word(o).is_some() && md::project_tag_word(tag).is_some())
                || (o.starts_with('#') && md::is_priority(o) && md::is_priority(tag))
        })
    };
    let mut out = own.join(" ");
    for tag in heading.iter().filter(|t| !sets(t)) {
        out = format!("{out} {tag}");
    }
    if !mark.is_empty() {
        out = format!("{out} {mark}");
    }
    out
}

/// The lines a list block becomes, or None when it stays one line: a block is a list when it has
/// two or more open checkboxes directly under its top line (`words - [ ] first` counts its inline
/// box), unless the top line is a typed row or a `#ask`, which say what they are. Each direct
/// bullet is an item; a line of words joins the item before it; anything deeper stays that item's
/// detail, its checkbox off so the item is whole on the next pass. A ticked item is finished.
fn list_items(block: &[&str]) -> Option<Vec<String>> {
    let text = inbox_text(block[0]);
    let text = text[..text.find("<!--").unwrap_or(text.len())].trim();
    if block[0].trim_start().starts_with("<!--")
        || md::ask_tag(block[0])
        || projects::is_typed(text)
    {
        return None;
    }
    const INLINE: &str = " - [ ] ";
    let (head, first) = match text.find(INLINE) {
        Some(at) => (&text[..at], Some(text[at + INLINE.len()..].trim())),
        None => (text, None),
    };
    let direct = block[1..].iter().map(|l| indent_of(l)).min().unwrap_or(0);
    let boxes = block[1..]
        .iter()
        .filter(|l| indent_of(l) == direct && is_open_box(l.trim()))
        .count();
    if boxes + usize::from(first.is_some()) < 2 {
        return None;
    }
    let mut items: Vec<(String, Vec<String>)> = first
        .map(|f| (f.to_string(), Vec::new()))
        .into_iter()
        .collect();
    let mut lead: Vec<String> = Vec::new();
    let mut finished = false;
    for l in &block[1..] {
        let t = l.trim();
        if indent_of(l) == direct {
            finished = false;
            if is_rule(t) {
                continue;
            }
            if t.starts_with("- [x]") || t.starts_with("- [X]") || inbox_text(t).is_empty() {
                finished = true;
                continue;
            }
            if t.starts_with("- ") || t.starts_with("* ") {
                items.push((inbox_text(t), Vec::new()));
                continue;
            }
        }
        if !finished {
            let words = inbox_text(t);
            if words.is_empty() {
                continue;
            }
            match items.last_mut() {
                Some((_, details)) => details.push(words),
                None => lead.push(words),
            }
        }
    }
    let tags: Vec<&str> = head
        .split_whitespace()
        .filter(|w| is_inherited(w))
        .collect();
    let words: Vec<&str> = head
        .split_whitespace()
        .filter(|w| !is_inherited(w))
        .collect();
    let words = words.join(" ");
    let under = (!words.is_empty()).then_some(words).into_iter().chain(lead);
    let under: Vec<String> = under.map(|u| format!("under: {u}")).collect();
    let mut out = Vec::new();
    for (item, details) in items {
        out.push(format!("- [ ] {}", with_inherited(&item, &tags)));
        out.extend(under.iter().chain(&details).map(|d| format!("  {d}")));
    }
    Some(out)
}

/// `content` with each list under `## <heading>` turned into one top-level line per item, and the
/// list's words and item count for each one split. Everything downstream reads one line as one
/// item, so a line is what each ask becomes. Run again it changes nothing.
pub(crate) fn split_lists(content: &str, heading: &str) -> (String, Vec<(String, usize)>) {
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, heading) else {
        return (content.to_string(), Vec::new());
    };
    let seen = dedent_orphans(&lines[span.clone()]);
    let seen: Vec<&str> = seen.iter().map(String::as_str).collect();
    let (mut body, mut lists) = (Vec::new(), Vec::new());
    let mut i = 0;
    while i < seen.len() {
        let l = seen[i];
        if l.trim().is_empty() || l.starts_with([' ', '\t']) || is_comment(l) {
            body.push(l.to_string());
            i += 1;
            continue;
        }
        let end = md::row_block_end(&seen, i);
        match list_items(&seen[i..end]) {
            Some(items) => {
                let n = items.iter().filter(|x| !x.starts_with(' ')).count();
                lists.push((inbox_text(l), n));
                body.extend(items);
            }
            None => body.extend(seen[i..end].iter().map(|s| s.to_string())),
        }
        i = end;
    }
    if body
        .iter()
        .map(String::as_str)
        .eq(lines[span.clone()].iter().copied())
    {
        return (content.to_string(), Vec::new());
    }
    let mut out: Vec<&str> = lines[..span.start].to_vec();
    out.extend(body.iter().map(String::as_str));
    out.extend_from_slice(&lines[span.end..]);
    let mut joined = out.join("\n");
    if content.ends_with('\n') {
        joined.push('\n');
    }
    (joined, lists)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(body: &str) -> (Vec<String>, Vec<(String, usize)>) {
        let (out, lists) = split_lists(&format!("## Inbox\n{body}"), INBOX);
        let again = split_lists(&out, INBOX);
        assert_eq!(
            again,
            (out.clone(), Vec::new()),
            "a second run changes nothing"
        );
        (out.lines().skip(1).map(str::to_string).collect(), lists)
    }

    #[test]
    fn a_list_under_a_heading_becomes_one_line_per_ask_with_the_heading_on_each() {
        let (got, lists) = split(
            "- [ ] look first, dodgeball fixes #urgent #p:dodginballs\n    - [ ] no bench #c1109\n    - when i die i wake in bed\n    - [ ] bigger text #low\n- [ ] other\n",
        );
        assert_eq!(
            got,
            vec![
                "- [ ] no bench #c1109 #urgent #p:dodginballs",
                "  under: look first, dodgeball fixes",
                "- [ ] when i die i wake in bed #urgent #p:dodginballs",
                "  under: look first, dodgeball fixes",
                "- [ ] bigger text #low #p:dodginballs",
                "  under: look first, dodgeball fixes",
                "- [ ] other",
            ]
        );
        assert_eq!(
            lists,
            vec![(
                "look first, dodgeball fixes #urgent #p:dodginballs".to_string(),
                3
            )]
        );
    }

    #[test]
    fn an_items_own_project_wins_and_agent_plan_and_go_are_inherited() {
        let (got, _) = split("- [ ] #agent #plan #go\n  - [ ] a #p:one\n  - [ ] b #go\n");
        assert_eq!(
            got,
            vec![
                "- [ ] a #p:one #agent #plan #go",
                "- [ ] b #go #agent #plan"
            ]
        );
    }

    #[test]
    fn a_block_indented_as_a_whole_is_moved_left_and_then_read() {
        let (got, lists) = split("    - [ ] one\n    - [ ] two\n      detail\n");
        assert_eq!(got, vec!["- [ ] one", "- [ ] two", "  detail"]);
        assert!(
            lists.is_empty(),
            "nothing was split, it was only moved left"
        );
    }

    #[test]
    fn a_detail_after_a_blank_line_and_a_comment_block_stay_put() {
        for body in [
            "- [ ] fix login\n\n  more detail about login\n",
            "<!-- notes\n  - [ ] example one\n  - [ ] example two\n-->\n",
        ] {
            let (got, lists) = split(body);
            assert_eq!(got.join("\n") + "\n", body);
            assert!(lists.is_empty());
        }
    }

    #[test]
    fn an_empty_deeper_bullet_leaves_no_blank_line_to_end_its_item() {
        let (got, _) = split("- [ ] h\n  - [ ] a\n    -\n    - [ ] x\n  - [ ] b\n");
        assert_eq!(
            got,
            vec!["- [ ] a", "  under: h", "  x", "- [ ] b", "  under: h"]
        );
    }

    #[test]
    fn an_inline_first_box_counts_and_the_words_before_it_are_the_heading() {
        let (got, _) = split("once this - [ ] first\n  - [ ] second\n");
        assert_eq!(
            got,
            vec![
                "- [ ] first",
                "  under: once this",
                "- [ ] second",
                "  under: once this"
            ]
        );
    }

    #[test]
    fn rules_and_ticked_items_go_and_deeper_lines_stay_details_without_their_box() {
        let (got, _) = split(
            "- [ ] h\n  - [ ] a\n    - [ ] sub one\n    - [ ] sub two\n  ---\n  - [x] done\n    gone too\n  - [ ] b\n  words on b\n",
        );
        assert_eq!(
            got,
            vec![
                "- [ ] a",
                "  under: h",
                "  sub one",
                "  sub two",
                "- [ ] b",
                "  under: h",
                "  words on b"
            ]
        );
    }

    #[test]
    fn a_typed_row_a_question_one_box_and_bare_bullets_stay_whole() {
        for body in [
            "- [ ] fix(audio): the gun\n  - [ ] step one\n  - [ ] step two\n",
            "- [ ] #ask why this\n  - [ ] one\n  - [ ] two\n",
            "- [ ] one job\n  - [ ] one step\n  notes\n",
            "- [ ] one job\n  - note\n  - note two\n",
            "- [ ] blank boxes\n  - [ ]\n  - [ ]\n",
        ] {
            let (got, lists) = split(body);
            assert_eq!(got.join("\n") + "\n", body);
            assert!(lists.is_empty());
        }
    }

    #[test]
    fn a_section_with_nothing_to_split_is_returned_byte_for_byte() {
        let s = "# a\n\n## Inbox\n<!-- note -->\n\n- [ ] x\n  d\n\n## Tasks\n- [ ] t";
        assert_eq!(split_lists(s, INBOX), (s.to_string(), Vec::new()));
        assert_eq!(
            split_lists("# none\n", INBOX),
            ("# none\n".to_string(), Vec::new())
        );
    }

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
