//! `notes zettel new "<title>"` — create an atomic permanent note with a
//! timestamp id and link-ready frontmatter.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::{bail, Result};
use chrono::{DateTime, Local};
use std::fs;
use std::io::Write;
use std::path::Path;

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    create(&p.zettel, log, "zettel", "note", title, note_text)
}

fn note_text(id: &str, title: &str, now: DateTime<Local>) -> String {
    format!(
        "---\nid: {id}\ntitle: {q}\ncreated: {date}\ntags: []\nlinks: []\n---\n\n# {title}\n\n",
        q = crate::md::yaml_quote(title),
        date = now.format("%Y-%m-%d")
    )
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
    let title = one_line(title);
    let title = title.as_str();
    if title.is_empty() {
        bail!("{kind} title must not be empty");
    }
    let now = Local::now();
    let id = now.format("%Y%m%dT%H%M").to_string();
    let slug = slugify(title, fallback);
    fs::create_dir_all(dir)?;
    let file = dir.join(format!("{id}-{slug}.md"));
    // create_new, so a second note of the same title in the same minute is refused, never
    // written over the first.
    let mut f = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            bail!("note already exists: {}", file.display())
        }
        Err(e) => return Err(e.into()),
    };
    f.write_all(body(&id, title, now).as_bytes())?;
    log.info(kind, &format!("created {}", file.display()));
    println!("{}", file.display());
    Ok(())
}

/// The title on one line: a newline in it would split the `# {title}` heading as well.
/// Control characters become a space; the ends are trimmed.
fn one_line(title: &str) -> String {
    title
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .trim()
        .to_string()
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
    fn one_line_replaces_control_characters_and_keeps_spacing() {
        assert_eq!(one_line("  a\nb\tc  "), "a b c");
        assert_eq!(one_line("Sync  A  vs  B"), "Sync  A  vs  B");
        assert_eq!(one_line(" \n "), "");
    }

    #[test]
    fn note_title_survives_the_front_matter() {
        let t = "He said \"x\" in C:\\temp";
        let text = note_text("id", t, Local::now());
        assert_eq!(
            crate::md::parse_yaml_scalar(&text, "title").as_deref(),
            Some(t)
        );
        assert!(text.contains("\n# He said \"x\" in C:\\temp\n"), "{text}");
    }

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
