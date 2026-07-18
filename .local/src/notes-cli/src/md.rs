//! Shared markdown + task-line helpers. These are the historically fragile bits
//! (section extraction, day-count stamping) so they carry unit tests.

use chrono::{Datelike, Duration, NaiveDate, Weekday};

/// Marks the start of a generated rollup block inside a section (today: only `## Focus`).
/// Everything from this line to the end of the section is MIRRORED FROM ANOTHER PROFILE,
/// not authored here, and `capture` ends the section at it.
///
/// That boundary is what keeps generated content from being mistaken for the user's own:
/// carry-forward (`daily::create_note`) would otherwise promote another profile's tasks
/// into this note's Focus overnight, and `summarize` would fold them into the append-only
/// continuous log permanently. Both read through `capture`, so both are fixed here rather
/// than at each call site.
pub const ROLLUP_START: &str = "<!-- rollup:start -->";

/// Capture the raw lines under a `## heading` up to the next `## `, a [`ROLLUP_START`]
/// sentinel, or EOF. Returns `None` if the heading is absent, `Some(vec)` (possibly
/// empty) otherwise. Heading match is case-insensitive and tolerant of trailing
/// whitespace. `### ` subsections do NOT end a section (see tests).
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
            if line.trim() == ROLLUP_START {
                break; // generated rollup block ends the authored part of the section
            }
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

/// Parse a bracket's inner text as a due date. Accepts a few human-friendly forms
/// (separator `-` or `/`), all requiring an explicit year so bare `[3-4]` prose
/// never false-matches:
///   - ISO   `YYYY-MM-DD`      (e.g. `2026-07-02`)
///   - US     `M-D-YY`         (e.g. `7-02-26` → 2026-07-02)
///   - US     `M-D-YYYY`       (e.g. `7/2/2026`)
/// Two-part first group of length 4 ⇒ ISO (year-first); otherwise month-first with
/// the year last (US ordering — the author's convention). Returns None on anything
/// that isn't three all-numeric groups with a 2- or 4-digit year.
fn parse_due_token(inner: &str) -> Option<NaiveDate> {
    let sep = if inner.contains('/') { '/' } else { '-' };
    let parts: Vec<&str> = inner.split(sep).collect();
    if parts.len() != 3 || parts.iter().any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit())) {
        return None;
    }
    let (ys, ms, ds) = if parts[0].len() == 4 {
        (parts[0], parts[1], parts[2]) // ISO YYYY-MM-DD
    } else if parts[2].len() == 2 || parts[2].len() == 4 {
        (parts[2], parts[0], parts[1]) // US M-D-Y → (year, month, day)
    } else {
        return None;
    };
    let mut year: i32 = ys.parse().ok()?;
    if ys.len() == 2 {
        year += 2000;
    }
    NaiveDate::from_ymd_opt(year, ms.parse().ok()?, ds.parse().ok()?)
}

/// Locate the first inline due-date token: returns `(open, close, date)` as byte
/// indices of the `[` and `]`. Skips the `- [ ]`/`- [x]` checkbox and `[[wikilinks]]`
/// (a `[` adjacent to another `[`). Accepts the formats `parse_due_token` handles.
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
                if !after_is_bracket {
                    if let Some(d) = parse_due_token(inner) {
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

/// Extract inline `#hashtag` tokens from a line. A tag is `#` followed by a letter,
/// then `[A-Za-z0-9_/-]*`, so `#wedding` and nested `#wedding/venue` both parse.
/// Deliberately skips (mirroring the care `find_due_span` takes with brackets):
///   - the leading `##`-style markdown **heading marker** (its text is still scanned);
///   - a `#` glued to the end of a word/number, `_`, `/`, `.`, `[`, or another `#`
///     — covers `foo#bar`, URL fragments `site.com/#top`, and the `[[note#anchor]]`
///     wikilink form;
///   - anything inside a `` `backtick` `` inline-code span.
/// Tags are lower-cased for case-insensitive grouping (like `extract_links`/`extract_tags`).
pub fn find_hashtags(line: &str) -> Vec<String> {
    let bytes = line.as_bytes();

    // Skip a leading heading marker: optional indent, a run of '#', then a space.
    let indent_end = line.len() - line.trim_start().len();
    let mut j = indent_end;
    while j < bytes.len() && bytes[j] == b'#' {
        j += 1;
    }
    let start = if j > indent_end && bytes.get(j) == Some(&b' ') {
        j + 1
    } else {
        0
    };

    let mut out = Vec::new();
    let mut in_code = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'`' {
            in_code = !in_code;
            i += 1;
            continue;
        }
        if b == b'#' && !in_code {
            let prev = if i > 0 { Some(bytes[i - 1]) } else { None };
            let glued = matches!(prev, Some(p)
                if p.is_ascii_alphanumeric() || matches!(p, b'_' | b'/' | b'.' | b'[' | b'#'));
            let tag_start = i + 1;
            if !glued
                && bytes
                    .get(tag_start)
                    .is_some_and(|c| c.is_ascii_alphabetic())
            {
                let mut k = tag_start;
                while k < bytes.len()
                    && (bytes[k].is_ascii_alphanumeric() || matches!(bytes[k], b'_' | b'-' | b'/'))
                {
                    k += 1;
                }
                // Trim a trailing separator so `#wedding/` / `#wedding-` → the bare stem.
                let mut end = k;
                while end > tag_start && matches!(bytes[end - 1], b'/' | b'-') {
                    end -= 1;
                }
                out.push(line[tag_start..end].to_lowercase());
                i = k;
                continue;
            }
        }
        i += 1;
    }
    out
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

/// Locate an inline `(every:…)` recurrence token: returns `(open, close, inner)` as
/// byte indices of the `(` and `)` plus the cadence text between `every:` and `)`.
/// Chosen deliberately in parens (not `[...]`) so it never collides with the `[date]`
/// due-token grammar. Only the first occurrence is returned.
fn find_every_span(line: &str) -> Option<(usize, usize, &str)> {
    let marker = "(every:";
    let open = line.find(marker)?;
    let inner_start = open + marker.len();
    let rel = line[inner_start..].find(')')?;
    let close = inner_start + rel;
    Some((open, close, &line[inner_start..close]))
}

/// Remove the first inline `(every:…)` token, collapsing surrounding whitespace so no
/// double space is left behind. No-op when the line has no token. Mirrors `strip_due`.
pub fn strip_every(line: &str) -> String {
    match find_every_span(line) {
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

/// Map a weekday term (`mon`…`sun`, or a longer form like `monday`) to a `Weekday`.
/// Matches on the first three letters so both `fri` and `friday` resolve. Terms are
/// assumed ASCII (cadence tokens always are), so the byte slice is safe.
fn weekday_from(term: &str) -> Option<Weekday> {
    let key = if term.len() >= 3 { &term[..3] } else { term };
    Some(match key {
        "mon" => Weekday::Mon,
        "tue" => Weekday::Tue,
        "wed" => Weekday::Wed,
        "thu" => Weekday::Thu,
        "fri" => Weekday::Fri,
        "sat" => Weekday::Sat,
        "sun" => Weekday::Sun,
        _ => return None,
    })
}

/// Does a single cadence term fire on `date`? Understands: `day` (always), `weekday`
/// (Mon–Fri), `weekend` (Sat/Sun), weekday names (`fri`, `friday`), `last` (last day
/// of the month), and day-of-month (`1st`, `15th`, or a bare `15`). Unknown → false.
fn term_matches(term: &str, date: NaiveDate) -> bool {
    let t = term.trim().to_lowercase();
    match t.as_str() {
        "" => false,
        "day" | "daily" => true,
        "weekday" => !matches!(date.weekday(), Weekday::Sat | Weekday::Sun),
        "weekend" => matches!(date.weekday(), Weekday::Sat | Weekday::Sun),
        // last day of the month: tomorrow rolls into a new month.
        "last" => (date + Duration::days(1)).month() != date.month(),
        _ => {
            if let Some(wd) = weekday_from(&t) {
                return date.weekday() == wd;
            }
            // Day-of-month: leading digits of `1st` / `15th` / bare `15`.
            let digits: String = t.chars().take_while(|c| c.is_ascii_digit()).collect();
            match digits.parse::<u32>() {
                Ok(n) => date.day() == n,
                Err(_) => false,
            }
        }
    }
}

/// True when the line carries an `(every:…)` token whose cadence fires on `date`.
/// Comma-separated terms are OR'd (`every:mon,thu`). No token → false.
pub fn recurs_on(line: &str, date: NaiveDate) -> bool {
    match find_every_span(line) {
        Some((_, _, inner)) => inner.split(',').any(|term| term_matches(term, date)),
        None => false,
    }
}

/// Pull a top-level scalar `key: value` out of flat YAML text (e.g. a Sentinel watch
/// manifest) without pulling in a YAML crate. Returns the value with surrounding single
/// or double quotes stripped and whitespace trimmed. First match wins; comment lines
/// (`# …`) and non-matching keys are skipped. `None` if the key is absent or empty.
pub fn parse_yaml_scalar(text: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}:");
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with('#') {
            continue;
        }
        if let Some(rest) = t.strip_prefix(&prefix) {
            let v = rest.trim();
            let v = v
                .strip_prefix('"')
                .and_then(|s| s.strip_suffix('"'))
                .or_else(|| v.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
                .unwrap_or(v)
                .trim();
            if v.is_empty() {
                return None;
            }
            return Some(v.to_string());
        }
    }
    None
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

/// Priority hashtags, most-urgent first. A task carries at most one; it always rides
/// at the very end of the line, after the `(Nd) <!-- since -->` stamp, so it stays
/// visible and never gets a stale duplicate appended in front of the stamp.
const PRIORITY_TAGS: [&str; 4] = ["urgent", "high", "medium", "low"];
const PRIORITY_HASH: [&str; 4] = ["#urgent", "#high", "#medium", "#low"];

/// Strip every priority hashtag (`#urgent`/`#high`/`#medium`/`#low`, case-insensitive)
/// from `line`, collapsing the space each one leaves behind, and return the cleaned line
/// plus the single most-urgent tag found (as `#low` etc.), or `None` if the line has none.
/// Tag detection mirrors [`find_hashtags`] (heading marker, glued `#`, and code spans skipped).
fn split_priority(line: &str) -> (String, Option<&'static str>) {
    let bytes = line.as_bytes();

    // Skip a leading heading marker: optional indent, a run of '#', then a space.
    let indent_end = line.len() - line.trim_start().len();
    let mut j = indent_end;
    while j < bytes.len() && bytes[j] == b'#' {
        j += 1;
    }
    let start = if j > indent_end && bytes.get(j) == Some(&b' ') {
        j + 1
    } else {
        0
    };

    // Byte ranges to cut, each already extended to swallow one adjacent space.
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut best: Option<usize> = None; // index into PRIORITY_TAGS (lower = more urgent)
    let mut in_code = false;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'`' {
            in_code = !in_code;
            i += 1;
            continue;
        }
        if b == b'#' && !in_code {
            let prev = if i > 0 { Some(bytes[i - 1]) } else { None };
            let glued = matches!(prev, Some(p)
                if p.is_ascii_alphanumeric() || matches!(p, b'_' | b'/' | b'.' | b'[' | b'#'));
            let tag_start = i + 1;
            if !glued
                && bytes
                    .get(tag_start)
                    .is_some_and(|c| c.is_ascii_alphabetic())
            {
                let mut k = tag_start;
                while k < bytes.len()
                    && (bytes[k].is_ascii_alphanumeric() || matches!(bytes[k], b'_' | b'-' | b'/'))
                {
                    k += 1;
                }
                let mut end = k;
                while end > tag_start && matches!(bytes[end - 1], b'/' | b'-') {
                    end -= 1;
                }
                if let Some(rank) = PRIORITY_TAGS.iter().position(|t| *t == line[tag_start..end].to_lowercase()) {
                    // Cut `#tag` plus one neighbouring space so no double space is left.
                    let (mut cut_s, mut cut_e) = (i, k);
                    if cut_s > start && bytes[cut_s - 1] == b' ' {
                        cut_s -= 1;
                    } else if bytes.get(cut_e) == Some(&b' ') {
                        cut_e += 1;
                    }
                    spans.push((cut_s, cut_e));
                    best = Some(best.map_or(rank, |b| b.min(rank)));
                    i = k;
                    continue;
                }
            }
        }
        i += 1;
    }

    if spans.is_empty() {
        return (line.to_string(), None);
    }
    let mut cleaned = String::with_capacity(line.len());
    let mut cursor = 0;
    for (s, e) in &spans {
        cleaned.push_str(&line[cursor..*s]);
        cursor = *e;
    }
    cleaned.push_str(&line[cursor..]);
    (
        cleaned.trim_end().to_string(),
        best.map(|r| PRIORITY_HASH[r]),
    )
}

/// Reset a carried task's in-progress checkbox `[/]` back to an open `[ ]`, preserving
/// indentation. Status (`[/]`) is a same-day signal set in the editor (see markdown.lua's
/// `<leader>t` cycle); it does not survive the daily carry — only the open todo + its
/// priority tag do. `[x]`/`[X]` never reach here (checked tasks are dropped before carry).
fn reset_status(line: &str) -> String {
    let indent_end = line.len() - line.trim_start().len();
    let (indent, rest) = line.split_at(indent_end);
    match rest.strip_prefix("- [/]") {
        Some(tail) => format!("{indent}- [ ]{tail}"),
        None => line.to_string(),
    }
}

/// Stamp a task line with an up-to-date `(Nd) <!-- since:DATE -->`.
/// - If the line already has a `since:` origin, recompute the day count from it.
/// - Otherwise treat it as a new carry item originating on `origin_if_new`.
/// A priority tag (`#low` etc.) is normalised to sit last, after the stamp, deduped;
/// an in-progress `[/]` checkbox is reset to `[ ]` (status is a same-day signal).
/// Non-task lines pass through unchanged.
pub fn stamp_line(line: &str, today: NaiveDate, origin_if_new: NaiveDate) -> String {
    if !is_task(line) {
        return line.to_string();
    }
    // Lift any priority tag(s) off the whole line first so the stamp lands in front of
    // the single canonical tag rather than behind a buried one; drop the in-progress mark.
    let line = reset_status(line);
    let (core, prio) = split_priority(&line);
    let stamped = match find_since(&core) {
        Some(date) => {
            let comment_start = core.find("<!--").unwrap_or(core.len());
            let before = strip_trailing_day(core[..comment_start].trim_end());
            let days = (today - date).num_days().max(0);
            format!("{} ({}d) <!-- since:{} -->", before, days, date.format("%Y-%m-%d"))
        }
        None => {
            let days = (today - origin_if_new).num_days().max(0);
            format!(
                "{} ({}d) <!-- since:{} -->",
                core.trim_end(),
                days,
                origin_if_new.format("%Y-%m-%d")
            )
        }
    };
    match prio {
        Some(tag) => format!("{stamped} {tag}"),
        None => stamped,
    }
}

/// Normalised core text of a task line, for de-duplication.
pub fn task_key(line: &str) -> String {
    let mut t = line.trim();
    if let Some(i) = t.find("<!--") {
        t = t[..i].trim_end();
    }
    let stripped = strip_trailing_day(t);
    // A task's identity is independent of its priority tag (and where it sits), so
    // carried/promoted copies dedupe even if the tag was added or moved.
    let (stripped, _) = split_priority(&stripped);
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

    /// `### ` must NOT end a section: `strip_prefix("## ")` fails on `"### x"` only
    /// because the third byte is `#` rather than a space. The whole job-rollup layout
    /// (H3 subsections living inside `## Focus`) rests on that, so pin it down here
    /// rather than leave it as an accident one refactor away from silently breaking.
    #[test]
    fn capture_keeps_h3_subsections() {
        let note = "\
## Focus
- [ ] mine

### acmecorp
- [ ] theirs

## Notes
after
";
        let lines = section_lines(note, "Focus").unwrap();
        assert_eq!(
            lines,
            vec!["- [ ] mine", "### acmecorp", "- [ ] theirs"]
        );
    }

    /// The rollup sentinel ends the AUTHORED part of a section. This single boundary is
    /// what stops `daily::create_note` carry-forward from promoting mirrored job tasks
    /// into personal Focus, and what stops `summarize` from baking them into the
    /// append-only continuous log. Assert both readers, since both go through `capture`.
    #[test]
    fn capture_stops_at_rollup_sentinel() {
        let note = format!(
            "\
## Focus
- [ ] mine
- [x] my done thing

{}

### acmecorp (2026-07-13)
- [ ] theirs
    - [ ] their child

## Notes
after
",
            ROLLUP_START
        );

        // section_lines: carry-forward's reader
        let lines = section_lines(&note, "Focus").unwrap();
        assert_eq!(lines, vec!["- [ ] mine", "- [x] my done thing"]);
        assert!(!lines.iter().any(|l| l.contains("theirs")));
        assert!(!lines.iter().any(|l| l.contains("acmecorp")));

        // section_text: summarize's reader
        let text = section_text(&note, "Focus").unwrap();
        assert!(text.contains("- [ ] mine"));
        assert!(!text.contains("theirs"));
        assert!(!text.contains("acmecorp"));

        // A section with no sentinel is unaffected.
        assert_eq!(
            section_lines(NOTE, "Focus").unwrap(),
            vec!["- [ ] write the plan", "- [x] done thing"]
        );
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
    fn task_key_ignores_priority_tag() {
        // Same task, tag before the stamp vs. no tag -> same identity.
        let a = task_key("- [ ] ship it #low (3d) <!-- since:2026-05-31 -->");
        let b = task_key("- [ ] ship it");
        assert_eq!(a, b);
        assert_eq!(a, "ship it");
    }

    #[test]
    fn split_priority_extracts_and_dedupes() {
        // The reported bug shape: tag buried before the stamp AND a stale dup after it.
        let (core, prio) =
            split_priority("- [ ] add priority tags #low (1d) <!-- since:2026-07-13 --> #low");
        assert_eq!(core, "- [ ] add priority tags (1d) <!-- since:2026-07-13 -->");
        assert_eq!(prio, Some("#low"));
    }

    #[test]
    fn split_priority_keeps_most_urgent() {
        let (core, prio) = split_priority("- [ ] triage #low the thing #urgent");
        assert_eq!(core, "- [ ] triage the thing");
        assert_eq!(prio, Some("#urgent"));
    }

    #[test]
    fn split_priority_leaves_content_tags_and_indent() {
        // Non-priority hashtags and nested indentation are untouched.
        let (core, prio) = split_priority("  - [ ] book #wedding venue");
        assert_eq!(core, "  - [ ] book #wedding venue");
        assert_eq!(prio, None);
    }

    #[test]
    fn stamp_moves_priority_tag_last() {
        // New item: tag ends up after the stamp, not before it.
        let out = stamp_line("- [ ] get androids onto fleet #low", d("2026-07-14"), d("2026-07-13"));
        assert_eq!(
            out,
            "- [ ] get androids onto fleet (1d) <!-- since:2026-07-13 --> #low"
        );
    }

    #[test]
    fn stamp_resets_in_progress_checkbox() {
        // An in-progress task carried to the next day reverts to an open todo, but
        // keeps its priority tag (which does carry).
        let out = stamp_line("- [/] wire it up #high", d("2026-07-15"), d("2026-07-14"));
        assert_eq!(
            out,
            "- [ ] wire it up (1d) <!-- since:2026-07-14 --> #high"
        );
        // Indentation on a nested task is preserved.
        let nested = stamp_line("  - [/] sub-step", d("2026-07-15"), d("2026-07-14"));
        assert_eq!(nested, "  - [ ] sub-step (1d) <!-- since:2026-07-14 -->");
    }

    #[test]
    fn stamp_heals_before_and_after_dup() {
        // Re-stamping the buggy line collapses the two tags into one trailing tag.
        let line = "- [ ] add priority tags #low (1d) <!-- since:2026-07-13 --> #low";
        let out = stamp_line(line, d("2026-07-15"), d("2026-07-14"));
        assert_eq!(
            out,
            "- [ ] add priority tags (2d) <!-- since:2026-07-13 --> #low"
        );
        // Idempotent: stamping the healed line again is stable (bar the day count).
        let out2 = stamp_line(&out, d("2026-07-15"), d("2026-07-14"));
        assert_eq!(out2, out);
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
    fn find_due_accepts_us_and_nonpadded_forms() {
        // US M-D-YY (the author's natural form), M-D-YYYY, slash separator
        assert_eq!(find_due("- [ ] take exam [7-02-26]"), Some(d("2026-07-02")));
        assert_eq!(find_due("- [ ] x [7/2/2026]"), Some(d("2026-07-02")));
        // non-padded ISO is unambiguous → accepted
        assert_eq!(find_due("- [ ] x [2026-6-3]"), Some(d("2026-06-03")));
    }

    #[test]
    fn find_due_rejects_invalid() {
        assert_eq!(find_due("- [ ] x [2026-13-40]"), None);
        assert_eq!(find_due("- [ ] x [not-a-date!]"), None);
        // two-part prose like a section ref must NOT match (year required)
        assert_eq!(find_due("- [ ] see section [3-4]"), None);
        // single-digit year rejected (avoids [1-1-1]-style false matches)
        assert_eq!(find_due("- [ ] x [1-1-1]"), None);
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

    #[test]
    fn hashtags_basic_and_multiple() {
        assert_eq!(find_hashtags("book #wedding venue"), vec!["wedding"]);
        assert_eq!(
            find_hashtags("- [ ] #wedding cake and #house paint"),
            vec!["wedding", "house"]
        );
        assert!(find_hashtags("no tags here").is_empty());
    }

    #[test]
    fn hashtags_case_insensitive_and_nested() {
        assert_eq!(find_hashtags("#Wedding"), vec!["wedding"]);
        assert_eq!(find_hashtags("plan #wedding/venue now"), vec!["wedding/venue"]);
    }

    #[test]
    fn hashtags_skip_heading_marker_but_scan_text() {
        assert!(find_hashtags("## Focus").is_empty());
        assert!(find_hashtags("# Title").is_empty());
        assert_eq!(find_hashtags("## Focus #wedding"), vec!["wedding"]);
        // a bare `#wedding` with no space after the '#' run is a tag, not a heading
        assert_eq!(find_hashtags("#wedding"), vec!["wedding"]);
    }

    #[test]
    fn hashtags_skip_glued_and_wikilink_and_url() {
        assert!(find_hashtags("see [[note#anchor]] here").is_empty());
        assert!(find_hashtags("id foo#bar baz").is_empty());
        assert!(find_hashtags("visit https://site.com/#top now").is_empty());
        assert!(find_hashtags("value is 3#4").is_empty());
    }

    #[test]
    fn hashtags_skip_code_span_and_trim_punctuation() {
        assert!(find_hashtags("run `git commit #123` now").is_empty());
        assert_eq!(find_hashtags("done #wedding."), vec!["wedding"]);
        assert_eq!(find_hashtags("(#wedding, #house)"), vec!["wedding", "house"]);
    }

    #[test]
    fn recurs_on_weekday() {
        // 2026-07-10 is a Friday, 2026-07-11 a Saturday.
        let fri = d("2026-07-10");
        let sat = d("2026-07-11");
        assert!(recurs_on("- [ ] timesheets (every:fri)", fri));
        assert!(!recurs_on("- [ ] timesheets (every:fri)", sat));
        assert!(recurs_on("- [ ] x (every:friday)", fri));
    }

    #[test]
    fn recurs_on_comma_list_is_or() {
        let mon = d("2026-07-06"); // Monday
        let thu = d("2026-07-09"); // Thursday
        let tue = d("2026-07-07"); // Tuesday
        assert!(recurs_on("- [ ] backup (every:mon,thu)", mon));
        assert!(recurs_on("- [ ] backup (every:mon,thu)", thu));
        assert!(!recurs_on("- [ ] backup (every:mon,thu)", tue));
    }

    #[test]
    fn recurs_on_weekday_keyword_and_day() {
        let fri = d("2026-07-10");
        let sat = d("2026-07-11");
        assert!(recurs_on("- [ ] standup (every:weekday)", fri));
        assert!(!recurs_on("- [ ] standup (every:weekday)", sat));
        assert!(recurs_on("- [ ] chores (every:weekend)", sat));
        assert!(recurs_on("- [ ] vitamins (every:day)", sat));
    }

    #[test]
    fn recurs_on_day_of_month_and_last() {
        assert!(recurs_on("- [ ] rent (every:1st)", d("2026-07-01")));
        assert!(!recurs_on("- [ ] rent (every:1st)", d("2026-07-02")));
        assert!(recurs_on("- [ ] mid (every:15th)", d("2026-07-15")));
        assert!(recurs_on("- [ ] plain (every:15)", d("2026-07-15")));
        // July has 31 days; the 31st is the last.
        assert!(recurs_on("- [ ] month-end (every:last)", d("2026-07-31")));
        assert!(!recurs_on("- [ ] month-end (every:last)", d("2026-07-30")));
        // February in a non-leap year: the 28th is the last.
        assert!(recurs_on("- [ ] feb (every:last)", d("2026-02-28")));
    }

    #[test]
    fn recurs_on_no_token_or_garbage_is_false() {
        let any = d("2026-07-10");
        assert!(!recurs_on("- [ ] plain task", any));
        assert!(!recurs_on("- [ ] x (every:blorp)", any));
        assert!(!recurs_on("- [ ] x (2d)", any));
    }

    #[test]
    fn strip_every_removes_token_and_collapses_space() {
        assert_eq!(strip_every("- [ ] timesheets (every:fri)"), "- [ ] timesheets");
        assert_eq!(strip_every("- [ ] x (every:mon,thu) more"), "- [ ] x more");
        assert_eq!(strip_every("- [ ] plain task"), "- [ ] plain task");
    }

    #[test]
    fn parse_yaml_scalar_handles_quotes_and_absent() {
        let y = "name: pmp-api-health\ndescription: \"PMP prod API liveness\"\nprobe: http\n# comment: ignore\ninterval: 5m\nempty:\n";
        assert_eq!(parse_yaml_scalar(y, "name").as_deref(), Some("pmp-api-health"));
        assert_eq!(parse_yaml_scalar(y, "description").as_deref(), Some("PMP prod API liveness"));
        assert_eq!(parse_yaml_scalar(y, "probe").as_deref(), Some("http"));
        assert_eq!(parse_yaml_scalar(y, "interval").as_deref(), Some("5m"));
        assert_eq!(parse_yaml_scalar(y, "comment"), None); // comment line skipped
        assert_eq!(parse_yaml_scalar(y, "empty"), None); // empty value → None
        assert_eq!(parse_yaml_scalar(y, "missing"), None);
        assert_eq!(parse_yaml_scalar("k: 'single quoted'", "k").as_deref(), Some("single quoted"));
    }
}
