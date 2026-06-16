//! `notes zettel new "<title>"` — create an atomic permanent note with a
//! timestamp id and link-ready frontmatter.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Result};
use chrono::Local;
use std::fs;

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    let title = title.trim();
    if title.is_empty() {
        bail!("zettel title must not be empty");
    }
    let now = Local::now();
    let id = now.format("%Y%m%dT%H%M").to_string();
    let slug = slugify(title);
    fs::create_dir_all(&p.zettel)?;
    let file = p.zettel.join(format!("{id}-{slug}.md"));
    if file.exists() {
        bail!("note already exists: {}", file.display());
    }

    let body = format!(
        "---\nid: {id}\ntitle: \"{title}\"\ncreated: {date}\ntags: []\nlinks: []\n---\n\n# {title}\n\n",
        date = now.format("%Y-%m-%d")
    );
    fs::write(&file, body)?;
    log.info("zettel", &format!("created {}", file.display()));
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
        "note".to_string()
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_basic() {
        assert_eq!(slugify("Atomic Idea: part 1!"), "atomic-idea-part-1");
        assert_eq!(slugify("   "), "note");
        assert_eq!(slugify("a---b"), "a-b");
    }
}
