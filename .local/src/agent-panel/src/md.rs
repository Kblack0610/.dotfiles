//! The one markdown cleaner for what the panels show: an agent's message, a plan, an ask's story.
//! Markdown marks read as noise in a terminal preview, so `plain` drops them and folds the text to
//! the preview's width with a hanging indent under list items. `agent-panel plain` is the same
//! function for the shell (agent-ask's card).

/// The widest a preview folds to, however wide the window: past it a line is hard to read.
pub const MAX_WIDTH: usize = 110;
/// The narrowest it folds to, so a squeezed preview still keeps a few words a line.
const MIN_WIDTH: usize = 20;
/// The width when no fzf preview or terminal says one.
const DEFAULT_WIDTH: usize = 100;

/// The width to fold to: fzf's `$FZF_PREVIEW_COLUMNS`, else `$COLUMNS`, capped at `MAX_WIDTH`.
pub fn width() -> usize {
    ["FZF_PREVIEW_COLUMNS", "COLUMNS"]
        .iter()
        .find_map(|v| std::env::var(v).ok()?.trim().parse::<usize>().ok().filter(|&w| w > 0))
        .unwrap_or(DEFAULT_WIDTH)
        .clamp(MIN_WIDTH, MAX_WIDTH)
}

/// `text` as plain lines: headings, bold, code-span backticks and fences dropped (a fence's code kept,
/// indented two), a table as one `header: value; ...` line per row, a rule line dropped, runs of
/// blank lines made one. Folded at `width` (0 folds nothing), a list item's lines hung under its
/// text.
pub fn plain(text: &str, width: usize) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut fence = false;
    let mut table: Vec<Vec<String>> = Vec::new();
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence;
            continue;
        }
        if fence {
            // Code keeps its blank lines: only prose has its blank runs made one.
            let code = line.trim_end();
            out.push(if code.is_empty() { String::new() } else { format!("  {code}") });
            continue;
        }
        if t.starts_with('|') {
            table.push(cells(t));
            continue;
        }
        flush_table(&mut table, &mut out, width);
        if is_rule(t) {
            push(&mut out, String::new());
            continue;
        }
        let line = strip_heading(line);
        let indent = line.len() - line.trim_start().len();
        let rest = &line[indent..];
        let (marker, body) = list_marker(rest);
        let lead = format!("{}{marker}", &line[..indent]);
        fold(&mut out, &lead, &inline(body), width);
    }
    flush_table(&mut table, &mut out, width);
    while out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    while out.first().is_some_and(|l| l.is_empty()) {
        out.remove(0);
    }
    out.join("\n")
}

/// Add a line, keeping one blank between paragraphs at most.
fn push(out: &mut Vec<String>, line: String) {
    if line.trim().is_empty() {
        if out.last().is_some_and(|l| l.is_empty()) {
            return;
        }
        out.push(String::new());
    } else {
        out.push(line);
    }
}

/// A `---`, `***` or `___` line: three or more of one mark, spaces between them allowed.
fn is_rule(t: &str) -> bool {
    ['-', '*', '_'].iter().any(|&c| t.chars().all(|x| x == c || x == ' ') && t.chars().filter(|&x| x == c).count() >= 3)
}

/// A line with its `#` heading marks gone.
fn strip_heading(line: &str) -> &str {
    let t = line.trim_start();
    let hashes = t.chars().take_while(|&c| c == '#').count();
    if (1..=6).contains(&hashes) && t[hashes..].starts_with(' ') {
        t[hashes..].trim_start()
    } else {
        line
    }
}

/// A list item's marker (`- `, `* ` drawn as `- `, `1. `, `1) `) and the text after it.
fn list_marker(rest: &str) -> (String, &str) {
    for m in ["- ", "* ", "+ "] {
        if let Some(body) = rest.strip_prefix(m) {
            return ("- ".to_string(), body);
        }
    }
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    if digits > 0 && digits < 4 {
        let after = &rest[digits..];
        if after.starts_with(". ") || after.starts_with(") ") {
            return (rest[..digits + 2].to_string(), &rest[digits + 2..]);
        }
    }
    (String::new(), rest)
}

/// Inline marks gone: a code span's backticks (its text kept as written) and `**`/`__` bold
/// where they pair around words. A mark that does not pair (`a ** b`, `snake__case`, a lone
/// backtick) stays.
fn inline(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('`') {
        out.push_str(&bold(&rest[..i]));
        let after = &rest[i + 1..];
        match after.find('`') {
            Some(j) => {
                out.push_str(&after[..j]);
                rest = &after[j + 1..];
            }
            None => {
                out.push('`');
                rest = after;
            }
        }
    }
    out.push_str(&bold(rest));
    out
}

/// `**x**` and `__x__` unwrapped: a pair opens before a word, not after a letter, and closes
/// after a word, not before a letter (CommonMark's flanking rule, kept simple).
fn bold(s: &str) -> String {
    let mut s = s.to_string();
    for m in ["**", "__"] {
        let mut out = String::new();
        let mut rest = s.as_str();
        while let Some((open, close)) = pair(rest, m) {
            out.push_str(&rest[..open]);
            out.push_str(&rest[open + m.len()..close]);
            rest = &rest[close + m.len()..];
        }
        out.push_str(rest);
        s = out;
    }
    s
}

/// The byte offsets of the first `m` that opens and the `m` that closes it.
fn pair(s: &str, m: &str) -> Option<(usize, usize)> {
    let before = |i: usize| s[..i].chars().next_back();
    let after = |i: usize| s[i + m.len()..].chars().next();
    let starts: Vec<usize> = s.match_indices(m).map(|(i, _)| i).collect();
    let open = starts.iter().copied().find(|&i| {
        !before(i).is_some_and(char::is_alphanumeric) && after(i).is_some_and(|c| !c.is_whitespace() && c != m.as_bytes()[0] as char)
    })?;
    let close = starts.iter().copied().find(|&i| {
        i > open + m.len()
            && before(i).is_some_and(|c| !c.is_whitespace())
            && !after(i).is_some_and(char::is_alphanumeric)
    })?;
    Some((open, close))
}

/// A table row's cells, the outer pipes gone, each trimmed and cleaned. A `|` inside a code span
/// or written `\|` is part of its cell.
fn cells(row: &str) -> Vec<String> {
    let inner = row.trim().strip_prefix('|').unwrap_or(row.trim());
    let mut cells = vec![String::new()];
    let mut code = false;
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => cells.last_mut().unwrap().push(chars.next().unwrap()),
            '`' => {
                code = !code;
                cells.last_mut().unwrap().push(c);
            }
            '|' if !code => cells.push(String::new()),
            _ => cells.last_mut().unwrap().push(c),
        }
    }
    if cells.len() > 1 && cells.last().is_some_and(|c| c.trim().is_empty()) {
        cells.pop();
    }
    cells.iter().map(|c| inline(c.trim())).collect()
}

/// A `|---|:--:|` separator row.
fn is_separator(row: &[String]) -> bool {
    row.iter().all(|c| !c.is_empty() && c.chars().all(|x| matches!(x, '-' | ':' | ' ')))
}

/// A table as one line per body row, `header: value` pairs joined by `; ` (an empty cell left
/// out). A table with no separator row has no header: its rows print their values.
fn flush_table(table: &mut Vec<Vec<String>>, out: &mut Vec<String>, width: usize) {
    if table.is_empty() {
        return;
    }
    let rows = std::mem::take(table);
    let (header, body): (&[String], &[Vec<String>]) = if rows.len() > 1 && is_separator(&rows[1]) {
        (&rows[0], &rows[2..])
    } else {
        (&[], &rows[..])
    };
    for row in body {
        let pairs: Vec<String> = row
            .iter()
            .enumerate()
            .filter(|(_, v)| !v.is_empty())
            .map(|(i, v)| match header.get(i).filter(|h| !h.is_empty()) {
                Some(h) => format!("{h}: {v}"),
                None => v.clone(),
            })
            .collect();
        if !pairs.is_empty() {
            fold(out, "", &pairs.join("; "), width);
        }
    }
}

/// Word-fold `body` after `lead` at `width` chars, its later lines indented under the body.
fn fold(out: &mut Vec<String>, lead: &str, body: &str, width: usize) {
    let body = body.trim_end();
    if body.trim().is_empty() {
        push(out, lead.trim_end().to_string());
        return;
    }
    if width == 0 {
        push(out, format!("{lead}{body}"));
        return;
    }
    let hang = " ".repeat(lead.chars().count());
    let mut line = lead.to_string();
    let mut len = line.chars().count();
    let mut fresh = true;
    for word in body.split_whitespace() {
        let w = word.chars().count();
        if !fresh && len + 1 + w > width {
            push(out, std::mem::replace(&mut line, hang.clone()));
            len = hang.chars().count();
            fresh = true;
        }
        if !fresh {
            line.push(' ');
            len += 1;
        }
        line.push_str(word);
        len += w;
        fresh = false;
    }
    push(out, line);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_headings_bold_backticks_and_fences_keeping_the_code() {
        let md = "## Result\n\nMerged **#12** with `make test` green.\n\n```bash\nmake -C tests\n```\nDone.";
        assert_eq!(plain(md, 0), "Result\n\nMerged #12 with make test green.\n\n  make -C tests\nDone.");
    }

    #[test]
    fn renders_a_table_as_one_header_value_line_per_row() {
        let md = "Before\n| Check | Result |\n|---|:--:|\n| unit | **ok** |\n| ui |  |\nAfter";
        assert_eq!(plain(md, 0), "Before\nCheck: unit; Result: ok\nCheck: ui\nAfter");
        // Negative control: with no separator row there is no header to pair with.
        assert_eq!(plain("| a | b |\n| c | d |", 0), "a; b\nc; d");
    }

    #[test]
    fn folds_at_the_width_and_hangs_a_list_item_under_its_text() {
        let md = "* one two three four five six\n12. alpha beta gamma delta";
        assert_eq!(
            plain(md, 16),
            "- one two three\n  four five six\n12. alpha beta\n    gamma delta"
        );
        // Width 0 folds nothing.
        assert_eq!(plain(md, 0), "- one two three four five six\n12. alpha beta gamma delta");
    }

    #[test]
    fn keeps_marks_that_do_not_pair_and_code_as_written() {
        assert_eq!(plain("Edit `__init__.py` and `a**b`, then **ship**.", 0), "Edit __init__.py and a**b, then ship.");
        assert_eq!(plain("a ** b, snake__case, __bold__, a lone ` tick", 0), "a ** b, snake__case, bold, a lone ` tick");
        assert_eq!(plain("| cmd | why |\n|---|---|\n| `a | b` | x \\| y |", 0), "cmd: a | b; why: x | y");
        // A fence keeps its blank lines; prose around it still has one at most.
        assert_eq!(plain("```\na\n\n\nb\n```", 0), "  a\n\n\n  b");
    }

    #[test]
    fn rules_and_blank_runs_become_one_blank_line() {
        assert_eq!(plain("\n\na\n\n\n---\n\nb\n\n", 0), "a\n\nb");
        // Negative control: a list item is not a rule, a hash with no space is not a heading.
        assert_eq!(plain("- x\n#1 is next", 0), "- x\n#1 is next");
        assert_eq!(plain("* * *\n- -", 0), "- -");
    }

    #[test]
    fn width_reads_the_preview_then_the_terminal_and_caps_it() {
        // One test owns these variables, so no parallel test sees them half set.
        std::env::set_var("FZF_PREVIEW_COLUMNS", "300");
        std::env::set_var("COLUMNS", "50");
        assert_eq!(width(), MAX_WIDTH);
        std::env::remove_var("FZF_PREVIEW_COLUMNS");
        assert_eq!(width(), 50);
        std::env::set_var("COLUMNS", "5");
        assert_eq!(width(), MIN_WIDTH);
        std::env::remove_var("COLUMNS");
        assert_eq!(width(), DEFAULT_WIDTH);
    }
}
