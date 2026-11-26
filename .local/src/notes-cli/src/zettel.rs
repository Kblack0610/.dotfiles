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
    create(&p.zettel, log, "zettel", "note", title, |id, title, now| {
        format!(
            "---\nid: {id}\ntitle: {q}\ncreated: {date}\ntags: []\nlinks: []\n---\n\n# {title}\n\n",
            q = yaml_quote(title),
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
    // One line: a newline in a title would split the `# {title}` heading as well.
    let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
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

/// `s` as a YAML double-quoted scalar, quotes included: `\\`, `"` and control characters are
/// escaped, so no title can end the value early or break the front matter.
pub(crate) fn yaml_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
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
    fn yaml_quote_escapes_what_ends_a_double_quoted_scalar() {
        assert_eq!(yaml_quote("plain"), "\"plain\"");
        assert_eq!(yaml_quote(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(yaml_quote(r"a\b"), r#""a\\b""#);
        assert_eq!(yaml_quote("a\nb\tc"), r#""a\nb\tc""#);
        assert_eq!(yaml_quote("a\u{7}b"), r#""a\u0007b""#);
    }

    #[test]
    fn create_writes_a_one_line_escaped_title() {
        let dir = std::env::temp_dir().join(format!("zettel-title-{}", std::process::id()));
        let log = Logger::new(dir.join("log"), false);
        create(
            &dir,
            &log,
            "zettel",
            "note",
            "He said \"x\"\\\nnext",
            |id, t, _| format!("id: {id}\ntitle: {}\n# {t}\n", yaml_quote(t)),
        )
        .unwrap();
        let f = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "md"))
            .unwrap();
        let text = fs::read_to_string(&f).unwrap();
        assert!(
            text.contains("title: \"He said \\\"x\\\"\\\\ next\"\n"),
            "{text}"
        );
        assert!(text.contains("# He said \"x\"\\ next\n"), "{text}");
        fs::remove_dir_all(&dir).ok();
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
