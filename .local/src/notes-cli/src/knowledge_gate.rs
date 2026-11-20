//! `notes knowledge gate`: the deterministic step between a day's sources and the model.
//!
//! The runner lists every candidate file for a day; the gate gives each a kind and decides what
//! the model sees, so no source is dropped without a recorded outcome:
//!
//!   - `generated` (frontmatter `generated: true`), `index` (a refs `_index.md`) and `empty`
//!     files are skipped, with the reason;
//!   - `todo`, a list that is mostly open checkboxes, is routed to the outbox (by `apply`, once the
//!     day's log is written, so a failed night never routes twice) and never shown to the model;
//!   - `transcript`, a pasted TUI or chat session, has its chrome stripped (tool calls and their
//!     output, permission prompts, spinners, box rules and borders);
//!   - the daily note loses its `## Focus` (the task path: a Focus row is ingested only by
//!     `notes focus ingest`, so it stays there) and its generated `## Morning`;
//!   - what is left over `PART_BYTES` is split at headings into parts, each with its own id.
//!
//! The gate writes the copies the model reads under `--out` and prints one JSON object, which
//! the runner turns into the prompt's manifest and hands to `apply --gate`. `apply` writes each
//! item's outcome to the day's `_log` under `## Dispositions`, which `notes knowledge trace` reads.

use crate::config::Profile;
use crate::{knowledge, md};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// A source the model reads is split into parts no bigger than this. A model's file read
/// truncates long files, and the 11-17 pastes the engine skipped ran 40 to 85 KB.
pub const PART_BYTES: usize = 16_000;
/// A file with at least this many chrome lines is a pasted transcript.
const TRANSCRIPT_MIN: usize = 3;
/// A file whose content lines are at least this share open checkboxes is a todo list.
const TODO_PCT: usize = 60;

/// Daily-note sections the model never reads: Focus is the task path, Morning is generated.
const DAILY_SKIP: [&str; 2] = ["Focus", "Morning"];

/// Phrases that only appear in a TUI's chrome (prompts, hints, menus), never in prose.
const CHROME_PHRASES: [&str; 22] = [
    "Would you like to proceed?",
    "Do you want to proceed?",
    "Do you want to make this edit",
    "Do you want to create ",
    "Ready to code?",
    "Tell Claude what to change",
    "No, and tell Claude what to do differently",
    "Yes, and switch to BYPASS PERMISSIONS",
    "Yes, manually approve edits",
    "Yes, and don't ask again",
    "Yes, allow all edits",
    "Yes, auto-accept edits",
    "shift+tab to approve",
    "shift+tab to cycle",
    "ctrl+g to edit",
    "ctrl+o to expand",
    "ctrl+r to expand",
    "esc to interrupt",
    "/plan to preview",
    "? for shortcuts",
    "bypass permissions on",
    "accept edits on",
];

/// Spinner glyphs a TUI prints in front of its status lines ("Cogitated for 3m").
const SPINNERS: [char; 6] = ['✻', '✢', '✶', '✳', '✽', '✺'];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    #[default]
    Note,
    Transcript,
    Todo,
    Generated,
    Index,
    Empty,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    /// `s1`, or `s4.2` for the second part of source 4.
    pub id: String,
    /// What the model and the log call it: vault-relative, else absolute, else the runner's label.
    pub path: String,
    pub kind: Kind,
    /// The file the model reads; absent when the model never sees the item.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read: Option<String>,
    /// Bytes the model reads.
    #[serde(default)]
    pub bytes: usize,
    /// `part 2 of 3 (<first heading>)` for a split source.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub part: String,
    /// A todo list's open items, each a block (`- [ ] <text>` and its indented details), which
    /// `apply` adds to the outbox.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tasks: Vec<Vec<String>>,
    /// What the gate did beyond the kind: lines stripped, sections left out.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Gate {
    pub date: String,
    pub items: Vec<Item>,
}

/// A line of nothing but box-drawing characters: a TUI rule, never prose.
fn is_box_rule(t: &str) -> bool {
    t.chars().count() >= 3 && t.chars().all(|c| ('\u{2500}'..='\u{257F}').contains(&c))
}

/// A bullet glyph then `Bash(...)`, `Read(...)` and the like: a tool call the TUI echoed.
fn is_tool_call(t: &str) -> bool {
    let Some(rest) = t.strip_prefix("● ").or_else(|| t.strip_prefix("⏺ ")) else {
        return false;
    };
    let name: String = rest
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric())
        .collect();
    name.chars().next().is_some_and(|c| c.is_ascii_uppercase())
        && rest[name.len()..].starts_with('(')
}

/// A numbered menu choice of a permission prompt (`1. Yes, and ...`, maybe behind the cursor).
fn is_menu(t: &str) -> bool {
    let t = t.trim_start_matches('❯').trim_start();
    let digits = t.chars().take_while(char::is_ascii_digit).count();
    digits > 0 && t[digits..].starts_with(". ") && CHROME_PHRASES.iter().any(|p| t.contains(p))
}

/// An arrow or ellipsis then `79 more lines` or `+12 lines`: a TUI's fold marker.
fn is_fold(t: &str) -> bool {
    let rest = t
        .strip_prefix("↑ ")
        .or_else(|| t.strip_prefix("… +"))
        .or_else(|| t.strip_prefix("... +"));
    rest.is_some_and(|r| {
        let n = r.chars().take_while(char::is_ascii_digit).count();
        n > 0 && r[n..].trim_start().starts_with(['m', 'l'])
    })
}

/// A chrome line the strip drops whole.
fn is_chrome(t: &str) -> bool {
    is_box_rule(t)
        || is_tool_call(t)
        || is_menu(t)
        || is_fold(t)
        || t.starts_with('⎿')
        || t.starts_with(SPINNERS)
        || CHROME_PHRASES.iter().any(|p| t.contains(p))
}

fn indent(l: &str) -> usize {
    l.len() - l.trim_start().len()
}

/// Drop a transcript's chrome and keep its words: tool calls and their output blocks, prompts,
/// menus, spinners and rules go; the bullet and cursor markers and box borders come off the
/// lines they lead. Returns the text and how many lines were dropped.
pub fn strip_chrome(text: &str) -> (String, usize) {
    let mut out = Vec::new();
    let mut dropped = 0;
    // While Some(i), the lines indented deeper than i belong to a dropped tool call or output.
    let mut block: Option<usize> = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(i) = block {
            if !t.is_empty() && indent(line) > i && !t.starts_with('●') && !t.starts_with('⏺') {
                dropped += 1;
                continue;
            }
            block = None;
        }
        if is_chrome(t) {
            if is_tool_call(t) || t.starts_with('⎿') {
                block = Some(indent(line));
            }
            dropped += 1;
            continue;
        }
        let mut kept = line.trim_end();
        if let Some(inner) = kept.trim_start().strip_prefix('│') {
            kept = inner.trim_end().trim_end_matches('│').trim_end();
        }
        let lead = kept.trim_start();
        let kept = lead
            .strip_prefix("● ")
            .or_else(|| lead.strip_prefix("⏺ "))
            .or_else(|| lead.strip_prefix("❯ "))
            .map(str::to_string)
            .unwrap_or_else(|| kept.to_string());
        out.push(kept);
    }
    let mut s = out.join("\n");
    s.push('\n');
    (s, dropped)
}

/// How many lines of `text` are chrome; a transcript has `TRANSCRIPT_MIN` or more.
fn chrome_lines(text: &str) -> usize {
    text.lines()
        .map(str::trim)
        .filter(|t| {
            is_chrome(t) || t.starts_with("● ") || t.starts_with("⏺ ") || t.starts_with("❯ ")
        })
        .count()
}

/// The text after a `---` frontmatter block, if there is one.
fn body(text: &str) -> &str {
    let Some(rest) = text.strip_prefix("---\n") else {
        return text;
    };
    // The block ends at the first line that is exactly `---`, which may be the very next one.
    let mut at = 0;
    for line in rest.split_inclusive('\n') {
        at += line.len();
        if line.trim_end() == "---" {
            return &rest[at..];
        }
    }
    text
}

/// The open items of a todo list, or None when the text is not mostly open items. Each item is
/// its line as an outbox `- [ ]` line plus the lines indented under it.
fn todo_items(text: &str) -> Option<Vec<Vec<String>>> {
    let lines: Vec<&str> = body(text).lines().collect();
    let is_content = |l: &&&str| {
        let t = l.trim();
        !t.is_empty() && !t.starts_with('#') && !t.chars().all(|c| c == '-' || c == '*')
    };
    // Only open items count, each with the lines under it: a list that is mostly done, or mostly
    // prose, is a record, and the model reads it.
    let mut items: Vec<Vec<String>> = Vec::new();
    let mut open = 0;
    let mut i = 0;
    while i < lines.len() {
        if !md::is_open_task(lines[i]) {
            i += 1;
            continue;
        }
        let end = md::row_block_end(&lines, i);
        open += lines[i..end].iter().filter(is_content).count();
        let mut block = vec![md::set_checkbox(lines[i], ' ').trim().to_string()];
        block.extend(lines[i + 1..end].iter().map(|l| l.trim_end().to_string()));
        items.push(block);
        i = end;
    }
    let content = lines.iter().filter(is_content).count();
    (open > 0 && open * 100 >= content * TODO_PCT).then_some(items)
}

/// The daily note without its Focus and Morning sections, and how many Focus rows it held.
fn daily_body(text: &str) -> (String, usize) {
    let lines: Vec<&str> = text.lines().collect();
    let mut skip = vec![false; lines.len()];
    let mut focus = 0;
    for h in DAILY_SKIP {
        if let Some(span) = md::section_span(&lines, h) {
            if h == "Focus" {
                focus = lines[span.clone()]
                    .iter()
                    .filter(|l| md::is_task(l))
                    .count();
            }
            skip[span.start - 1] = true;
            for i in span {
                skip[i] = true;
            }
        }
    }
    let mut s: String = lines
        .iter()
        .zip(&skip)
        .filter(|(_, s)| !**s)
        .map(|(l, _)| *l)
        .collect::<Vec<_>>()
        .join("\n");
    s.push('\n');
    (s, focus)
}

/// Cut `text` into parts of at most `max` bytes: at headings first, then blank lines, then
/// line ends, so a part never starts mid-paragraph unless one paragraph is bigger than `max`.
pub fn split(text: &str, max: usize) -> Vec<String> {
    if text.len() <= max {
        return vec![text.to_string()];
    }
    // Cut at headings; a section still over the cap is cut after its blank lines, then at any
    // line end. Then pack the pieces back together greedily up to the cap.
    let mut pieces = Vec::new();
    for section in cut(text, |l| l.starts_with('#'), false) {
        if section.len() <= max {
            pieces.push(section);
            continue;
        }
        for para in cut(&section, |l| l.trim().is_empty(), true) {
            if para.len() <= max {
                pieces.push(para);
            } else {
                for line in cut(&para, |_| true, true) {
                    pieces.extend(hard_cut(&line, max));
                }
            }
        }
    }
    let mut parts: Vec<String> = Vec::new();
    for p in pieces {
        match parts.last_mut() {
            Some(last) if last.len() + p.len() <= max => last.push_str(&p),
            _ => parts.push(p),
        }
    }
    parts
}

/// A line longer than `max` (a minified paste) cut at char boundaries into pieces of at most `max`.
fn hard_cut(line: &str, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = line;
    while rest.len() > max {
        let mut at = max;
        while !rest.is_char_boundary(at) {
            at -= 1;
        }
        out.push(rest[..at].to_string());
        rest = &rest[at..];
    }
    out.push(rest.to_string());
    out
}

/// `text` cut into pieces at the lines `at` picks: before such a line, or after it with `after`.
fn cut(text: &str, at: impl Fn(&str) -> bool, after: bool) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for line in text.split_inclusive('\n') {
        if !after && at(line) && !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        cur.push_str(line);
        if after && at(line) {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// A part's first heading, cut to 60 characters: a label, not the text.
fn first_heading(text: &str) -> Option<String> {
    let h = text
        .lines()
        .find(|l| l.starts_with('#'))
        .map(|l| l.trim_start_matches('#').trim())
        .filter(|h| !h.is_empty())?;
    Some(match h.char_indices().nth(60) {
        Some((i, _)) => format!("{}...", h[..i].trim_end()),
        None => h.to_string(),
    })
}

/// The name a source goes by: vault-relative inside the vault, else its absolute path.
fn name_of(p: &Profile, file: &Path) -> String {
    file.strip_prefix(&p.root)
        .map(|r| r.to_string_lossy().into_owned())
        .unwrap_or_else(|_| file.to_string_lossy().into_owned())
}

fn is_daily(p: &Profile, file: &Path, date: &str) -> bool {
    file.parent() == Some(p.daily.as_path())
        && file
            .file_stem()
            .is_some_and(|s| s.to_string_lossy() == date)
}

/// Gate one day's sources (see the module doc). `sources` are `(file, label)` pairs; a label
/// names a file whose path means nothing to a reader (the runner's lessons extract). Copies the
/// model reads go under `out`.
pub fn gate(
    p: &Profile,
    date: &str,
    sources: &[(PathBuf, Option<String>)],
    out: &Path,
) -> Result<Gate> {
    fs::create_dir_all(out).with_context(|| format!("creating {}", out.display()))?;
    let mut items = Vec::new();
    for (n, (file, label)) in sources.iter().enumerate() {
        let id = format!("s{}", n + 1);
        let path = label.clone().unwrap_or_else(|| name_of(p, file));
        let skip = |kind: Kind, note: &str| Item {
            id: id.clone(),
            path: path.clone(),
            kind,
            note: note.into(),
            ..Default::default()
        };
        // One unreadable file (binary, gone since the listing) is its own outcome, not the day's.
        let raw = match fs::read_to_string(file) {
            Ok(r) => r,
            Err(e) => {
                items.push(skip(Kind::Empty, &format!("could not read it: {e}")));
                continue;
            }
        };
        if file.file_name().is_some_and(|f| f == "_index.md") {
            items.push(skip(Kind::Index, "the refs index, links only"));
            continue;
        }
        if knowledge::frontmatter(&raw)
            .is_some_and(|fm| fm.get("generated").is_some_and(|v| v == "true"))
        {
            items.push(skip(
                Kind::Generated,
                "a generated feed (frontmatter generated: true)",
            ));
            continue;
        }
        if body(&raw).trim().is_empty() {
            items.push(skip(Kind::Empty, "the file is empty"));
            continue;
        }
        // The daily note's tasks are Focus rows and the inbox has its own triage (`notes
        // inbox`), so only a ref is ever a todo list to route.
        let daily = is_daily(p, file, date);
        let routable = !daily && !file.starts_with(&p.inbox);
        if let Some(tasks) = todo_items(&raw).filter(|_| routable) {
            let n = tasks.len();
            items.push(Item {
                tasks,
                ..skip(
                    Kind::Todo,
                    &format!("a todo list: {n} open item(s) for the outbox"),
                )
            });
            continue;
        }
        let mut notes = Vec::new();
        let mut text = raw.clone();
        if daily {
            let (t, focus) = daily_body(&text);
            text = t;
            if focus > 0 {
                notes.push(format!(
                    "{focus} Focus row(s) left on Focus, the task path (`notes focus ingest` routes one)"
                ));
            }
        }
        let mut kind = Kind::Note;
        if chrome_lines(&text) >= TRANSCRIPT_MIN {
            let (t, dropped) = strip_chrome(&text);
            text = t;
            kind = Kind::Transcript;
            notes.push(format!("{dropped} chrome line(s) stripped"));
        }
        let parts = split(&text, PART_BYTES);
        let changed = text != raw;
        for (i, part) in parts.iter().enumerate() {
            let pid = if parts.len() == 1 {
                id.clone()
            } else {
                format!("{id}.{}", i + 1)
            };
            let read = if changed || parts.len() > 1 {
                let copy = out.join(format!("{pid}.md"));
                fs::write(&copy, part).with_context(|| format!("writing {}", copy.display()))?;
                copy
            } else {
                file.clone()
            };
            let label = if parts.len() == 1 {
                String::new()
            } else {
                match first_heading(part) {
                    Some(h) => format!("part {} of {} ({h})", i + 1, parts.len()),
                    None => format!("part {} of {}", i + 1, parts.len()),
                }
            };
            items.push(Item {
                id: pid,
                path: path.clone(),
                kind,
                read: Some(read.to_string_lossy().into_owned()),
                bytes: part.len(),
                part: label,
                note: notes.join("; "),
                ..Default::default()
            });
        }
    }
    Ok(Gate {
        date: date.to_string(),
        items,
    })
}

/// `notes knowledge gate <date> --out <dir>`: stdin is one source per line, `<file>` or
/// `<file><TAB><label>`; prints the gate JSON.
pub fn run(p: &Profile, date: &str, out: &Path, stdin: &str) -> Result<()> {
    let sources: Vec<(PathBuf, Option<String>)> = stdin
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| match l.split_once('\t') {
            Some((f, label)) => (PathBuf::from(f), Some(label.to_string())),
            None => (PathBuf::from(l), None),
        })
        .collect();
    let g = gate(p, date, &sources, out)?;
    println!("{}", serde_json::to_string_pretty(&g)?);
    Ok(())
}

pub fn load(file: &Path) -> Result<Gate> {
    let raw = fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?;
    serde_json::from_str(&raw).with_context(|| format!("parsing the gate {}", file.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-gate-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("journal/daily")).unwrap();
        fs::create_dir_all(dir.join("journal/refs/2026-11-18")).unwrap();
        dir
    }

    fn put(root: &Path, rel: &str, body: &str) -> PathBuf {
        let f = root.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(&f, body).unwrap();
        f
    }

    const TRANSCRIPT: &str = "❯ how should the release work?\n\n● The release goes through three gates.\n\n● Bash(git log --oneline -3)\n  ⎿  abc123 fix\n     def456 feat\n\n● Updated plan\n  ⎿  /plan to preview\n\n✻ Cogitated for 3m 2s\n\n────────────────────────────────────────\n Claude has written up a plan and is ready to execute. Would you like to proceed?\n\n ❯ 1. Yes, and switch to BYPASS PERMISSIONS (no further prompts) for this session\n   2. Yes, manually approve edits\n   3. Tell Claude what to change\n      shift+tab to approve with this feedback\n ↑ 79 more lines\n │ a boxed line │\n";

    #[test]
    fn chrome_is_stripped_and_the_words_stay() {
        let (s, dropped) = strip_chrome(TRANSCRIPT);
        assert!(s.contains("how should the release work?"), "{s}");
        assert!(s.contains("The release goes through three gates."), "{s}");
        assert!(s.contains("Updated plan"), "{s}");
        assert!(s.contains("a boxed line"), "{s}");
        for gone in [
            "Bash(",
            "abc123",
            "def456",
            "/plan to preview",
            "Cogitated",
            "───",
            "BYPASS",
            "manually approve",
            "Tell Claude",
            "shift+tab",
            "more lines",
            "●",
            "❯",
            "│",
        ] {
            assert!(!s.contains(gone), "`{gone}` survived:\n{s}");
        }
        assert!(dropped >= 12, "{dropped}");
    }

    #[test]
    fn prose_is_not_a_transcript() {
        let prose =
            "# Gateway\n\n- the gateway falls back to mlx\n- a table:\n\n| a | b |\n|---|---|\n";
        assert!(chrome_lines(prose) < TRANSCRIPT_MIN);
        assert!(chrome_lines(TRANSCRIPT) >= TRANSCRIPT_MIN);
    }

    #[test]
    fn a_big_paste_splits_at_headings_under_the_cap() {
        let section = format!("## Part\n\n{}\n\n", "word ".repeat(1000));
        let text = section.repeat(8);
        let parts = split(&text, PART_BYTES);
        assert!(parts.len() >= 3, "{}", parts.len());
        assert!(parts.iter().all(|p| p.len() <= PART_BYTES));
        assert!(parts.iter().all(|p| p.starts_with("## Part")));
        assert_eq!(parts.concat(), text, "nothing is lost in the split");
        assert_eq!(split("small", PART_BYTES), vec!["small".to_string()]);
    }

    #[test]
    fn only_a_list_of_mostly_open_items_is_a_todo_list() {
        let open = "- [ ] buy filament\n  - PETG\n- [ ] fix the gate\n- [x] done\n";
        assert_eq!(todo_items(open).map(|i| i.len()), Some(2));
        let done = "- [x] a\n- [x] b\n- [x] c\n- [ ] d\n";
        assert!(todo_items(done).is_none(), "a mostly done list is a record");
        let prose = "- [ ] one\n\nthe gateway falls back to mlx\nthe judge goes direct\n";
        assert!(todo_items(prose).is_none(), "mostly prose is a note");
    }

    #[test]
    fn the_body_starts_after_the_line_that_closes_the_frontmatter() {
        assert_eq!(body("---\n---\nkept\n\n---\nrule\n"), "kept\n\n---\nrule\n");
        assert_eq!(body("---\nid: x\n---\nkept\n"), "kept\n");
        assert_eq!(body("---\nno close\n"), "---\nno close\n");
        assert_eq!(body("plain\n"), "plain\n");
    }

    #[test]
    fn a_line_longer_than_a_part_is_cut_at_char_boundaries() {
        let text = format!("{}\n", "é".repeat(PART_BYTES));
        let parts = split(&text, PART_BYTES);
        assert!(parts.len() >= 2, "{}", parts.len());
        assert!(parts.iter().all(|p| p.len() <= PART_BYTES));
        assert_eq!(parts.concat(), text, "nothing is lost in the split");
    }

    #[test]
    fn an_unreadable_source_is_skipped_and_the_rest_are_gated() {
        let root = vault("unreadable");
        let p = config::test_profile(root.to_str().unwrap());
        let bin = root.join("journal/refs/2026-11-18/shot.md");
        fs::write(&bin, [0xff, 0xfe, 0x00]).unwrap();
        let note = put(
            &root,
            "journal/daily/2026-11-18.md",
            "the gateway falls back to mlx\n",
        );
        let srcs = vec![(bin, None), (note, None)];
        let g = gate(&p, "2026-11-18", &srcs, &root.join("gated")).unwrap();
        assert_eq!(g.items[0].kind, Kind::Empty);
        assert!(
            g.items[0].note.starts_with("could not read it"),
            "{}",
            g.items[0].note
        );
        assert!(g.items[1].read.is_some());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn each_source_gets_a_kind_and_only_what_the_model_should_read() {
        let root = vault("kinds");
        let p = config::test_profile(root.to_str().unwrap());
        let daily = put(
            &root,
            "journal/daily/2026-11-18.md",
            "# 2026-11-18\n\n## Notes\n\nthe gateway falls back to mlx\n\n## Focus\n\n- [ ] ship it #urgent\n- [x] done\n\n## Morning\n\n- Knowledge: nothing new\n\n## Refs\n\n- [[journal/refs/2026-11-18/x]]\n",
        );
        let todo = put(
            &root,
            "journal/refs/2026-11-18/ingest.md",
            "- [ ] confirm flow is clean #c1118\n  details under it\n- [/] seeded facility preview\n- [x] already done\n- [ ] \n",
        );
        let gen = put(
            &root,
            "journal/refs/2026-11-18/briefing.md",
            "---\ngenerated: true\n---\n# briefing\n",
        );
        let index = put(
            &root,
            "journal/refs/2026-11-18/_index.md",
            "---\nid: x\n---\n# Refs\n",
        );
        let empty = put(
            &root,
            "journal/refs/2026-11-18/final.md",
            "---\ntitle: x\n---\n\n",
        );
        let paste = put(&root, "journal/refs/2026-11-18/plan.md", TRANSCRIPT);
        let big = put(
            &root,
            "journal/refs/2026-11-18/big.md",
            &format!(
                "## A\n\n{}\n\n## B\n\n{}\n",
                "a ".repeat(6000),
                "b ".repeat(6000)
            ),
        );
        let lessons = put(&root, "lessons.md", "- a lesson\n");
        let out = root.join("gated");
        let srcs: Vec<(PathBuf, Option<String>)> = vec![
            (daily, None),
            (todo, None),
            (gen, None),
            (index, None),
            (empty, None),
            (paste, None),
            (big.clone(), None),
            (
                lessons.clone(),
                Some("~/.agent/lessons (bullets added 2026-11-18)".into()),
            ),
        ];
        let g = gate(&p, "2026-11-18", &srcs, &out).unwrap();
        let by = |id: &str| g.items.iter().find(|i| i.id == id).unwrap();

        let d = by("s1");
        assert_eq!(
            (d.kind, d.path.as_str()),
            (Kind::Note, "journal/daily/2026-11-18.md")
        );
        let seen = fs::read_to_string(d.read.as_ref().unwrap()).unwrap();
        assert!(
            seen.contains("falls back to mlx")
                && !seen.contains("ship it")
                && !seen.contains("nothing new"),
            "{seen}"
        );
        assert!(
            d.note.starts_with("2 Focus row(s) left on Focus"),
            "{}",
            d.note
        );

        let t = by("s2");
        assert_eq!(t.kind, Kind::Todo);
        assert!(t.read.is_none(), "a todo list is not shown to the model");
        assert_eq!(
            t.tasks,
            vec![
                vec![
                    "- [ ] confirm flow is clean #c1118".to_string(),
                    "  details under it".to_string()
                ],
                vec!["- [ ] seeded facility preview".to_string()],
            ]
        );
        assert_eq!(
            (by("s3").kind, by("s4").kind, by("s5").kind),
            (Kind::Generated, Kind::Index, Kind::Empty)
        );
        assert!(by("s3").read.is_none() && by("s4").read.is_none() && by("s5").read.is_none());

        let tr = by("s6");
        assert_eq!(tr.kind, Kind::Transcript);
        assert!(!fs::read_to_string(tr.read.as_ref().unwrap())
            .unwrap()
            .contains("Bash("));

        let parts: Vec<&Item> = g.items.iter().filter(|i| i.id.starts_with("s7.")).collect();
        assert_eq!(
            parts.len(),
            2,
            "{:?}",
            g.items.iter().map(|i| &i.id).collect::<Vec<_>>()
        );
        assert_eq!(parts[0].part, "part 1 of 2 (A)");
        assert!(parts
            .iter()
            .all(|i| i.path == "journal/refs/2026-11-18/big.md" && i.bytes <= PART_BYTES));

        let l = by("s8");
        assert_eq!(l.path, "~/.agent/lessons (bullets added 2026-11-18)");
        assert_eq!(
            l.read.as_deref(),
            Some(lessons.to_str().unwrap()),
            "an unchanged file is read in place"
        );

        // A daily note or an inbox capture that is all checkboxes is still read, never routed:
        // Focus rows and the inbox each have their own path.
        let tasks = "- [ ] a\n- [ ] b\n";
        let srcs = [
            (put(&root, "journal/daily/2026-11-19.md", tasks), None),
            (p.inbox.join("2026-11-19.md"), None),
        ];
        fs::create_dir_all(&p.inbox).unwrap();
        fs::write(&srcs[1].0, tasks).unwrap();
        let g = gate(&p, "2026-11-19", &srcs, &out).unwrap();
        assert!(g
            .items
            .iter()
            .all(|i| i.kind == Kind::Note && i.read.is_some()));
    }
}
