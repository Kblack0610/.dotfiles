//! Shared markdown + task-line helpers. These are the historically fragile bits
//! (section extraction, day-count stamping) so they carry unit tests.

use chrono::NaiveDate;

/// Capture the raw lines under a `## heading` up to the next `## ` or EOF.
/// Returns `None` if the heading is absent, `Some(vec)` (possibly empty) otherwise.
/// Heading match is case-insensitive and tolerant of trailing whitespace.
fn capture<'a>(content: &'a str, heading: &str) -> Option<Vec<&'a str>> {
    let mut collecting = false;
    let mut out = Vec::new();
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            if collecting {
                break; // next H2 section ends the current one
            }
            if rest.trim().eq_ignore_ascii_case(heading) {
                collecting = true;
                continue;
            }
        }
        if collecting {
            out.push(line);
        }
    }
    if collecting {
        Some(out)
    } else {
        None
    }
}

fn is_comment_only(line: &str) -> bool {
    let t = line.trim();
    t.starts_with("<!--") && t.ends_with("-->")
}

/// Non-empty raw lines of a section (for carry-forward). Inline `<!-- since -->`
/// comments are preserved; only blank lines are dropped.
pub fn section_lines(content: &str, heading: &str) -> Option<Vec<String>> {
    capture(content, heading).map(|lines| {
        lines
            .into_iter()
            .filter(|l| !l.trim().is_empty())
            .map(|l| l.to_string())
            .collect()
    })
}

/// Cleaned section text for summaries: drops comment-only and placeholder lines.
/// Returns `None` if the result is empty or a bare `-`.
pub fn section_text(content: &str, heading: &str) -> Option<String> {
    let lines = capture(content, heading)?;
    let kept: Vec<&str> = lines
        .into_iter()
        .filter(|l| !is_comment_only(l) && !is_empty_unchecked(l))
        .collect();
    let text = kept.join("\n");
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed == "-" {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub fn is_task(line: &str) -> bool {
    line.trim_start().starts_with("- [")
}

pub fn is_checked(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("- [x]") || t.starts_with("- [X]")
}

/// `- [ ]` with no text after it.
pub fn is_empty_unchecked(line: &str) -> bool {
    match line.trim().strip_prefix("- [ ]") {
        Some(rest) => rest.trim().is_empty(),
        None => false,
    }
}

/// Parse the `<!-- since:YYYY-MM-DD -->` origin date from a line, if present.
pub fn find_since(line: &str) -> Option<NaiveDate> {
    let marker = "since:";
    let i = line.find(marker)?;
    let tail: String = line[i + marker.len()..].chars().take(10).collect();
    NaiveDate::parse_from_str(&tail, "%Y-%m-%d").ok()
}

/// Locate the first inline `[YYYY-MM-DD]` due-date token: returns `(open, close, date)`
/// as byte indices of the `[` and `]`. Skips the `- [ ]`/`- [x]` checkbox (its inner
/// span is 1 char, never 10) and `[[wikilinks]]` (a `[` adjacent to another `[`).
/// Strict canonical zero-padded form only — `[2026-6-3]` and `[2026-13-40]` are rejected.
fn find_due_span(line: &str) -> Option<(usize, usize, NaiveDate)> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while let Some(rel) = line[i..].find('[') {
        let open = i + rel;
        let prev_is_bracket = open > 0 && bytes[open - 1] == b'[';
        let next_is_bracket = bytes.get(open + 1) == Some(&b'[');
        if !prev_is_bracket && !next_is_bracket {
            if let Some(crel) = line[open + 1..].find(']') {
                let close = open + 1 + crel;
                let after_is_bracket = bytes.get(close + 1) == Some(&b']');
                let inner = &line[open + 1..close];
                if inner.len() == 10 && !after_is_bracket {
                    if let Ok(d) = NaiveDate::parse_from_str(inner, "%Y-%m-%d") {
                        return Some((open, close, d));
                    }
                }
            }
        }
        i = open + 1;
    }
    None
}

/// Parse the first inline `[YYYY-MM-DD]` due-date token on a line, if present.
pub fn find_due(line: &str) -> Option<NaiveDate> {
    find_due_span(line).map(|(_, _, d)| d)
}

/// Remove the first inline `[YYYY-MM-DD]` due token, collapsing the surrounding
/// whitespace so no double space is left behind. No-op when the line has no token.
pub fn strip_due(line: &str) -> String {
    match find_due_span(line) {
        Some((open, close, _)) => {
            let head = line[..open].trim_end();
            let tail = line[close + 1..].trim_start();
            if tail.is_empty() {
                head.to_string()
            } else {
                format!("{head} {tail}")
            }
        }
        None => line.to_string(),
    }
}

/// Strip a trailing ` (Nd)` day-count suffix, if any.
fn strip_trailing_day(s: &str) -> String {
    let t = s.trim_end();
    if let Some(p) = t.rfind(" (") {
        let inner = &t[p + 2..];
        if let Some(num) = inner.strip_suffix("d)") {
            if !num.is_empty() && num.chars().all(|c| c.is_ascii_digit()) {
                return t[..p].to_string();
            }
        }
    }
    t.to_string()
}

/// Stamp a task line with an up-to-date `(Nd) <!-- since:DATE -->`.
/// - If the line already has a `since:` origin, recompute the day count from it.
/// - Otherwise treat it as a new carry item originating on `origin_if_new`.
/// Non-task lines pass through unchanged.
pub fn stamp_line(line: &str, today: NaiveDate, origin_if_new: NaiveDate) -> String {
    if !is_task(line) {
        return line.to_string();
    }
    match find_since(line) {
        Some(date) => {
            let comment_start = line.find("<!--").unwrap_or(line.len());
            let before = strip_trailing_day(line[..comment_start].trim_end());
            let days = (today - date).num_days().max(0);
            format!("{} ({}d) <!-- since:{} -->", before, days, date.format("%Y-%m-%d"))
        }
        None => {
            let days = (today - origin_if_new).num_days().max(0);
            format!(
                "{} ({}d) <!-- since:{} -->",
                line.trim_end(),
                days,
                origin_if_new.format("%Y-%m-%d")
            )
        }
    }
}

/// Normalised core text of a task line, for de-duplication.
pub fn task_key(line: &str) -> String {
    let mut t = line.trim();
    if let Some(i) = t.find("<!--") {
        t = t[..i].trim_end();
    }
    let stripped = strip_trailing_day(t);
    let t = stripped.trim();
    let t = t
        .strip_prefix("- [ ]")
        .or_else(|| t.strip_prefix("- [x]"))
        .or_else(|| t.strip_prefix("- [X]"))
        .unwrap_or(t);
    t.trim().to_lowercase()
}

/// Insert `new_lines` directly under `## heading`. If the heading is absent,
/// append a new section at the end.
pub fn insert_under_heading(content: &str, heading: &str, new_lines: &[String]) -> String {
    let target = format!("## {heading}");
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    if let Some(pos) = lines.iter().position(|l| l.trim() == target) {
        for (k, nl) in new_lines.iter().enumerate() {
            lines.insert(pos + 1 + k, nl.clone());
        }
        let mut out = lines.join("\n");
        out.push('\n');
        out
    } else {
        let mut out = content.trim_end().to_string();
        out.push_str(&format!("\n\n## {heading}\n"));
        for nl in new_lines {
            out.push_str(nl);
            out.push('\n');
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    const NOTE: &str = "\
# 2026-06-03

## Focus
- [ ] write the plan
- [x] done thing

## Priority
- [ ] ship it (3d) <!-- since:2026-05-31 -->
<!-- a comment -->

## Notes
nothing here
";

    #[test]
    fn capture_and_section_lines() {
        let lines = section_lines(NOTE, "Focus").unwrap();
        assert_eq!(lines, vec!["- [ ] write the plan", "- [x] done thing"]);
        assert!(section_lines(NOTE, "Missing").is_none());
    }

    #[test]
    fn section_text_filters_comments() {
        let t = section_text(NOTE, "Priority").unwrap();
        assert_eq!(t, "- [ ] ship it (3d) <!-- since:2026-05-31 -->");
        assert_eq!(section_text(NOTE, "Notes").unwrap(), "nothing here");
    }

    #[test]
    fn task_classification() {
        assert!(is_task("- [ ] x"));
        assert!(is_checked("- [x] x"));
        assert!(is_checked("  - [X] x"));
        assert!(is_empty_unchecked("- [ ] "));
        assert!(is_empty_unchecked("- [ ]"));
        assert!(!is_empty_unchecked("- [ ] real"));
    }

    #[test]
    fn stamp_recomputes_existing_since() {
        let line = "- [ ] ship it (3d) <!-- since:2026-05-31 -->";
        let out = stamp_line(line, d("2026-06-03"), d("2026-06-02"));
        assert_eq!(out, "- [ ] ship it (3d) <!-- since:2026-05-31 -->");
        // advance today by 7 days -> 10d since 05-31
        let out2 = stamp_line(line, d("2026-06-10"), d("2026-06-09"));
        assert_eq!(out2, "- [ ] ship it (10d) <!-- since:2026-05-31 -->");
    }

    #[test]
    fn stamp_new_item_uses_origin() {
        let line = "- [ ] brand new";
        let out = stamp_line(line, d("2026-06-03"), d("2026-06-01"));
        assert_eq!(out, "- [ ] brand new (2d) <!-- since:2026-06-01 -->");
    }

    #[test]
    fn task_key_normalises() {
        let a = task_key("- [ ] Ship It (3d) <!-- since:2026-05-31 -->");
        let b = task_key("- [x] ship it");
        assert_eq!(a, b);
        assert_eq!(a, "ship it");
    }

    #[test]
    fn insert_under_existing_heading() {
        let c = "# t\n\n## Active\n- [ ] one\n\n## Done\n";
        let out = insert_under_heading(c, "Active", &["- [ ] two".to_string()]);
        assert!(out.contains("## Active\n- [ ] two\n- [ ] one"));
    }

    #[test]
    fn insert_missing_heading_appends() {
        let c = "# t\n";
        let out = insert_under_heading(c, "Active", &["- [ ] two".to_string()]);
        assert!(out.contains("## Active\n- [ ] two"));
    }

    #[test]
    fn find_due_parses_inline() {
        assert_eq!(find_due("- [ ] pay rent [2026-07-15]"), Some(d("2026-07-15")));
        assert_eq!(find_due("- [ ] renew [2026-08-01] (2d)"), Some(d("2026-08-01")));
    }

    #[test]
    fn find_due_ignores_checkbox() {
        assert_eq!(find_due("- [ ] todo"), None);
        assert_eq!(find_due("- [x] done"), None);
        assert_eq!(find_due("  - [ ] indented"), None);
    }

    #[test]
    fn find_due_ignores_wikilink() {
        assert_eq!(find_due("see [[2026-06-30]] note"), None);
        assert_eq!(find_due("- [ ] x [[journal/2026-06-30]]"), None);
    }

    #[test]
    fn find_due_checkbox_and_date_coexist() {
        assert_eq!(find_due("- [x] done early [2026-01-02]"), Some(d("2026-01-02")));
    }

    #[test]
    fn find_due_rejects_invalid_or_nonpadded() {
        assert_eq!(find_due("- [ ] x [2026-13-40]"), None);
        assert_eq!(find_due("- [ ] x [2026-6-3]"), None);
        assert_eq!(find_due("- [ ] x [not-a-date!]"), None);
    }

    #[test]
    fn find_due_picks_date_past_wikilink() {
        assert_eq!(find_due("[[note]] thing [2026-07-15]"), Some(d("2026-07-15")));
    }

    #[test]
    fn strip_due_removes_token_and_collapses_space() {
        assert_eq!(strip_due("- [ ] pay rent [2026-07-15]"), "- [ ] pay rent");
        assert_eq!(strip_due("- [ ] x [2026-07-15] more"), "- [ ] x more");
    }

    #[test]
    fn strip_due_noop_when_absent() {
        assert_eq!(strip_due("- [ ] plain task"), "- [ ] plain task");
    }
}
