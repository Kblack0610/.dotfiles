//! `notes zettel new "<title>"` — create an atomic permanent note with a
//! timestamp id and link-ready frontmatter.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Result};
use chrono::{DateTime, Local};
use std::fs;
use std::path::Path;

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    create(&p.zettel, log, "zettel", "note", title, |id, title, now| {
        format!(
            "---\nid: {id}\ntitle: \"{title}\"\ncreated: {date}\ntags: []\nlinks: []\n---\n\n# {title}\n\n",
            date = now.format("%Y-%m-%d")
        )
    })
}

/// A note named `<timestamp id>-<slug>.md` in `dir`, its text from `body(id, title, now)`;
/// refused when the title is blank or the file exists. `kind` names it in the error and the
/// log, `fallback` is the slug of a title with no letter or digit. `notes meeting new` makes
/// its logs the same way.
pub(crate) fn create(
    dir: &Path,
    log: &Logger,
    kind: &str,
    fallback: &str,
    title: &str,
    body: impl FnOnce(&str, &str, DateTime<Local>) -> String,
) -> Result<()> {
    let title = title.trim();
    if title.is_empty() {
        bail!("{kind} title must not be empty");
    }
    let now = Local::now();
    let id = now.format("%Y%m%dT%H%M").to_string();
    let slug = slugify(title, fallback);
    fs::create_dir_all(dir)?;
    let file = dir.join(format!("{id}-{slug}.md"));
    if file.exists() {
        bail!("note already exists: {}", file.display());
    }
    fs::write(&file, body(&id, title, now))?;
    log.info(kind, &format!("created {}", file.display()));
    println!("{}", file.display());
    Ok(())
}

fn slugify(s: &str, fallback: &str) -> String {
    let slug = crate::md::kebab(s);
    if slug.is_empty() {
        fallback.to_string()
    } else {
        slug
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_basic() {
        assert_eq!(
            slugify("Atomic Idea: part 1!", "note"),
            "atomic-idea-part-1"
        );
        assert_eq!(
            slugify("Q2 Planning: kickoff!", "meeting"),
            "q2-planning-kickoff"
        );
        assert_eq!(slugify("   ", "note"), "note");
        assert_eq!(slugify("a---b", "note"), "a-b");
    }
}
