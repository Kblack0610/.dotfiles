//! `notes meeting new "<title>"` — create a structured meeting log with a
//! timestamp id and agenda/notes/decisions/action-item scaffolding.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Result};
use chrono::Local;
use std::fs;

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    let title = title.trim();
    if title.is_empty() {
        bail!("meeting title must not be empty");
    }
    let now = Local::now();
    let id = now.format("%Y%m%dT%H%M").to_string();
    let slug = slugify(title);
    fs::create_dir_all(&p.meetings)?;
    let file = p.meetings.join(format!("{id}-{slug}.md"));
    if file.exists() {
        bail!("note already exists: {}", file.display());
    }

    let body = format!(
        "---\nid: {id}\ntitle: \"{title}\"\ndate: {date}\ntype: meeting\ntags: [meeting]\nattendees: []\nlinks: []\n---\n\n# {title}\n\n- **When:** {when}\n- **Attendees:**\n\n## Agenda\n\n## Notes\n\n## Decisions\n\n## Action Items\n- [ ]\n",
        date = now.format("%Y-%m-%d"),
        when = now.format("%Y-%m-%d %H:%M"),
    );
    fs::write(&file, body)?;
    log.info("meeting", &format!("created {}", file.display()));
    println!("{}", file.display());
    Ok(())
}

fn slugify(s: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in s.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "meeting".to_string()
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_basic() {
        assert_eq!(slugify("Q2 Planning: kickoff!"), "q2-planning-kickoff");
        assert_eq!(slugify("   "), "meeting");
        assert_eq!(slugify("a---b"), "a-b");
    }
}
