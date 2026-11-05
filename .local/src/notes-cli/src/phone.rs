//! `notes phone`: a plain checklist in today's daily note (`## Phone`) that the phone edits
//! through Home Assistant's To-do list (widget, dashboard card, notification reply, Assist).
//! It is not Focus: no day stamps, no priority lanes, no sweep. A line is `- [ ] text` or
//! `- [x] text` at the top level of the section.
//!
//! Every verb names an item by its exact text, so a line that changed on disk since the caller
//! read it is not found (exit 3) instead of the wrong line being changed. Each write holds one
//! lock (`<state>/phone.lock`, outside the synced vault) across its read and write.
//!
//! `notes today` carries open lines to the new day (`daily::create_note`).

use crate::config::Profile;
use crate::daily;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Result};
use std::fs;

pub(crate) const HEADING: &str = "Phone";

/// Exit code when the named item is not in the section (or the note is gone).
const NOT_FOUND: i32 = 3;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Item {
    pub uid: String,
    pub text: String,
    pub done: bool,
}

/// A top-level `- [?] text` line's state and text. The empty `- [ ]` placeholder and any
/// indented or non-task line are not items.
fn parse(line: &str) -> Option<(bool, String)> {
    if line.starts_with(char::is_whitespace) || !md::is_task(line) {
        return None;
    }
    let rest = line.strip_prefix("- [")?;
    let mut chars = rest.chars();
    let mark = chars.next()?;
    let tail = chars.as_str().strip_prefix(']')?;
    let text = tail.trim().to_string();
    if text.is_empty() {
        return None;
    }
    Some((matches!(mark, 'x' | 'X'), text))
}

/// FNV-1a over the text and how many earlier items share it, as 16 hex digits: stable across
/// builds and unique within the list, which is what Home Assistant's `uid` needs.
fn uid(text: &str, nth: usize) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in format!("{text}\n{nth}").bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

pub(crate) fn items(content: &str) -> Vec<Item> {
    let mut seen: std::collections::HashMap<String, usize> = Default::default();
    md::section_numbered(content, HEADING)
        .into_iter()
        .filter_map(|(_, l)| parse(l))
        .map(|(done, text)| {
            let n = seen.entry(text.clone()).or_default();
            let item = Item {
                uid: uid(&text, *n),
                text,
                done,
            };
            *n += 1;
            item
        })
        .collect()
}

/// The open lines, as written, for `notes today` to carry to the new day.
pub(crate) fn open_lines(content: &str) -> Vec<String> {
    items(content)
        .into_iter()
        .filter(|i| !i.done)
        .map(|i| format!("- [ ] {}", i.text))
        .collect()
}

/// What a verb does to the first item whose text is exactly `text`.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Op {
    Done,
    Undo,
    Remove,
    Rename(String),
}

/// Apply `op` to the first item whose text is `text`. None when there is no such item.
pub(crate) fn apply(content: &str, text: &str, op: &Op) -> Option<String> {
    let text = text.trim();
    md::edit_first_in_section(
        content,
        HEADING,
        |l| parse(l).is_some_and(|(_, t)| t == text),
        |l| match op {
            Op::Done => Some(md::set_checkbox(l, 'x')),
            Op::Undo => Some(md::set_checkbox(l, ' ')),
            Op::Remove => None,
            Op::Rename(new) => {
                let done = parse(l).is_some_and(|(d, _)| d);
                Some(format!("- [{}] {}", if done { 'x' } else { ' ' }, new.trim()))
            }
        },
    )
    .map(|(out, _)| out)
}

/// Append `- [ ] text` after the section's last item, creating `## Phone` above the link
/// footer when the note has none.
pub(crate) fn append(content: &str, text: &str) -> String {
    let line = format!("- [ ] {}", text.trim());
    let lines: Vec<&str> = content.lines().collect();
    let Some(span) = md::section_span(&lines, HEADING) else {
        return daily::insert_before_footer(content, &format!("## {HEADING}\n{line}\n"));
    };
    let at = span
        .clone()
        .rev()
        .find(|&i| !lines[i].trim().is_empty())
        .map_or(span.start, |i| i + 1);
    let mut out: Vec<String> = lines.iter().map(|l| (*l).to_string()).collect();
    out.insert(at, line);
    let mut s = out.join("\n");
    s.push('\n');
    s
}

struct Lock(#[allow(dead_code)] fs::File);

fn lock(p: &Profile) -> Result<Lock> {
    fs::create_dir_all(&p.state_dir)?;
    let f = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(p.state_dir.join("phone.lock"))?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: flock on a descriptor this function owns; the lock ends when `f` closes.
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
            bail!("locking the phone list: {}", std::io::Error::last_os_error());
        }
    }
    Ok(Lock(f))
}

fn list_json(p: &Profile, content: &str) -> serde_json::Value {
    let note = daily::today_path(p);
    let items: Vec<serde_json::Value> = items(content)
        .into_iter()
        .map(|i| serde_json::json!({"uid": i.uid, "text": i.text, "done": i.done}))
        .collect();
    serde_json::json!({
        "date": chrono::Local::now().date_naive().format("%Y-%m-%d").to_string(),
        "path": note,
        "heading": HEADING,
        "items": items,
    })
}

fn print(p: &Profile, content: &str, json: bool) {
    if json {
        println!("{}", list_json(p, content));
    } else {
        for i in items(content) {
            println!("- [{}] {}", if i.done { 'x' } else { ' ' }, i.text);
        }
    }
}

fn read_today(p: &Profile) -> Result<String> {
    match fs::read_to_string(daily::today_path(p)) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(e.into()),
    }
}

/// `notes phone [list] [--json]`: today's items; `--json` gives `{date, path, heading, items:
/// [{uid, text, done}]}`.
pub fn list(p: &Profile, json: bool) -> Result<i32> {
    print(p, &read_today(p)?, json);
    Ok(0)
}

/// `notes phone add <text>`: append an open item, creating today's note first when absent.
pub fn add(p: &Profile, log: &Logger, text: &str, json: bool) -> Result<i32> {
    let text = text.trim();
    if text.is_empty() {
        bail!("nothing to add (provide the item's text)");
    }
    let _lock = lock(p)?;
    let note = daily::today_path(p);
    if !note.exists() {
        daily::run(p, log)?;
    }
    let out = append(&fs::read_to_string(&note)?, text);
    md::write_atomic(&note, &out)?;
    log.info("phone", &format!("added to {}", note.display()));
    print(p, &out, json);
    Ok(0)
}

/// `notes phone done|undo|rm|edit <text>`: change the item whose text is exactly `text`.
/// Exit 3, nothing written, when there is none.
pub fn change(p: &Profile, log: &Logger, text: &str, op: Op, json: bool) -> Result<i32> {
    if text.trim().is_empty() {
        bail!("which item? (provide its exact text)");
    }
    if let Op::Rename(new) = &op {
        if new.trim().is_empty() {
            bail!("rename to what? (provide the new text)");
        }
    }
    let _lock = lock(p)?;
    let note = daily::today_path(p);
    let content = read_today(p)?;
    let Some(out) = apply(&content, text, &op) else {
        if json {
            println!("{}", list_json(p, &content));
        }
        eprintln!("no item '{}' in today's ## {HEADING}; nothing written", text.trim());
        return Ok(NOT_FOUND);
    };
    if out != content {
        md::write_atomic(&note, &out)?;
        log.info("phone", &format!("{op:?} in {}", note.display()));
    }
    print(p, &out, json);
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "# 2026-11-05\n\n## Focus\n- [ ] focus thing\n\n## Phone\n- [ ] call dentist\n- [x] water plants\n  - a detail\n- [ ] \n\n## Morning\nprose\n\n---\nBacklogs: [[x]]\n";

    #[test]
    fn items_are_top_level_tasks_with_text() {
        let got = items(NOTE);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].text, "call dentist");
        assert!(!got[0].done);
        assert_eq!(got[1].text, "water plants");
        assert!(got[1].done);
    }

    #[test]
    fn uids_are_unique_for_repeated_text() {
        let note = "## Phone\n- [ ] milk\n- [ ] milk\n";
        let got = items(note);
        assert_ne!(got[0].uid, got[1].uid);
        assert_eq!(got[0].uid, items(note)[0].uid);
    }

    #[test]
    fn done_undo_rename_remove() {
        let out = apply(NOTE, "call dentist", &Op::Done).unwrap();
        assert!(out.contains("- [x] call dentist"));
        let out = apply(&out, "call dentist", &Op::Undo).unwrap();
        assert!(out.contains("- [ ] call dentist"));
        let out = apply(NOTE, "water plants", &Op::Rename("water the ferns".into())).unwrap();
        assert!(out.contains("- [x] water the ferns"));
        assert!(out.contains("  - a detail"));
        let out = apply(NOTE, "call dentist", &Op::Remove).unwrap();
        assert!(!out.contains("call dentist"));
        assert!(out.contains("- [ ] focus thing"));
    }

    #[test]
    fn a_changed_line_is_not_found_and_focus_is_never_touched() {
        assert!(apply(NOTE, "call the dentist", &Op::Done).is_none());
        assert!(apply(NOTE, "focus thing", &Op::Done).is_none());
        assert!(apply(NOTE, "call", &Op::Remove).is_none());
    }

    #[test]
    fn append_goes_after_the_last_item_or_makes_the_section_above_the_footer() {
        let out = append(NOTE, "pick up filament");
        let lines: Vec<&str> = out.lines().collect();
        let i = lines.iter().position(|l| *l == "- [ ] pick up filament").unwrap();
        assert_eq!(lines[i - 1], "- [ ] ");
        assert!(out.find("pick up filament").unwrap() < out.find("## Morning").unwrap());

        let bare = "# d\n\n## Focus\n- [ ] a\n\n---\nBacklogs: [[x]]\n";
        let out = append(bare, "first");
        assert!(out.contains("## Phone\n- [ ] first\n"));
        assert!(out.find("## Phone").unwrap() < out.find("Backlogs").unwrap());
        assert_eq!(items(&out)[0].text, "first");
        // Focus still reads its own line only.
        assert_eq!(md::section_lines(&out, "Focus").unwrap(), vec!["- [ ] a"]);
    }

    #[test]
    fn open_lines_carry_only_open_items() {
        assert_eq!(open_lines(NOTE), vec!["- [ ] call dentist"]);
    }

    #[test]
    fn verbs_write_the_note_and_exit_3_on_a_missing_item() {
        let root = std::env::temp_dir().join(format!("notes-phone-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let p = crate::config::test_profile(&root.to_string_lossy());
        let log = Logger::new(root.join(".state/log"), false);
        let note = daily::today_path(&p);
        fs::create_dir_all(note.parent().unwrap()).unwrap();
        fs::write(&note, NOTE).unwrap();

        assert_eq!(add(&p, &log, "pick up filament", true).unwrap(), 0);
        assert_eq!(change(&p, &log, "pick up filament", Op::Done, true).unwrap(), 0);
        assert!(fs::read_to_string(&note).unwrap().contains("- [x] pick up filament"));

        let before = fs::read_to_string(&note).unwrap();
        assert_eq!(change(&p, &log, "pick up the filament", Op::Remove, true).unwrap(), 3);
        assert_eq!(fs::read_to_string(&note).unwrap(), before, "a miss writes nothing");
        let _ = fs::remove_dir_all(&root);
    }
}
