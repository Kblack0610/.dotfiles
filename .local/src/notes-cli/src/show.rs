//! `notes show [<target>] [--json]`: one note, resolved the way the editor's `gf` resolves a
//! `[[wikilink]]`, for a viewer that is not the editor (agent-web's Focus tab, through
//! `hub_core::focus`).
//!
//! A target is `daily` (today's note, the default), `daily:YYYY-MM-DD`, or a wikilink target
//! (`outbox`, `status/inbox`, `journal/refs/2026-11-05/briefing`). Like notes.nvim's
//! `wikilink.lua`, the text before `|` or `#` is the target and `<target>.md` is looked up under
//! the profile root first, then the vault. The resolved file must sit inside one of those two
//! roots once symlinks and `..` are taken out, so a caller that passes a target it got from a
//! browser never reads past the notes.

use crate::config::Profile;
use anyhow::{bail, Result};
use chrono::NaiveDate;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// The text of a wikilink that names its target: before any `|label` or `#heading`, trimmed.
fn link_target(inner: &str) -> &str {
    inner.split(['|', '#']).next().unwrap_or("").trim()
}

/// Every `[[wikilink]]` in `md`, in order of first appearance, as `(target, label)`.
fn links(md: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut rest = md;
    while let Some(s) = rest.find("[[") {
        let after = &rest[s + 2..];
        let Some(e) = after.find("]]") else { break };
        let inner = &after[..e];
        rest = &after[e + 2..];
        if inner.contains('\n') {
            continue;
        }
        let target = link_target(inner);
        if target.is_empty() || out.iter().any(|(t, _)| t == target) {
            continue;
        }
        let label = inner.split_once('|').map_or(target, |(_, l)| l.trim());
        out.push((target.to_string(), label.to_string()));
    }
    out
}

/// The roots a note may live under: the profile root, then the vault, each canonical.
fn roots(p: &Profile) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for r in [&p.root, &p.vault] {
        if let Ok(c) = fs::canonicalize(r) {
            if !out.contains(&c) {
                out.push(c);
            }
        }
    }
    out
}

/// `path` canonical, and inside one of `roots`; None when it does not exist or escapes.
fn confined(path: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    let c = fs::canonicalize(path).ok()?;
    (c.is_file() && roots.iter().any(|r| c.starts_with(r))).then_some(c)
}

/// The file a wikilink target names, or None. A target that climbs (`..`) or is absolute is
/// refused before any lookup, so the containment check is a second guard, not the only one.
fn resolve_link(p: &Profile, roots: &[PathBuf], target: &str) -> Option<PathBuf> {
    let t = Path::new(target);
    if t.is_absolute()
        || t.components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return None;
    }
    for base in [&p.root, &p.vault] {
        for cand in [base.join(format!("{target}.md")), base.join(target)] {
            if let Some(c) = confined(&cand, roots) {
                return Some(c);
            }
        }
    }
    None
}

/// The days that have a daily note, sorted.
fn days(p: &Profile) -> Vec<NaiveDate> {
    let mut out: Vec<NaiveDate> = fs::read_dir(&p.daily)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            NaiveDate::parse_from_str(name.strip_suffix(".md")?, "%Y-%m-%d").ok()
        })
        .collect();
    out.sort();
    out
}

/// The note `target` names: `(file, date)`, where `file` may not exist (a day with no note yet)
/// and `date` is set for a daily note. Errors only for a target that escapes the notes.
fn locate(p: &Profile, roots: &[PathBuf], target: &str) -> Result<(PathBuf, Option<NaiveDate>)> {
    let target = link_target(target);
    let date = if target.is_empty() || target == "daily" {
        Some(chrono::Local::now().date_naive())
    } else if let Some(d) = target.strip_prefix("daily:") {
        match NaiveDate::parse_from_str(d, "%Y-%m-%d") {
            Ok(d) => Some(d),
            Err(_) => bail!("'{d}' is not a date (want daily:YYYY-MM-DD)"),
        }
    } else {
        None
    };
    if let Some(d) = date {
        let file = p.daily.join(format!("{}.md", d.format("%Y-%m-%d")));
        if file.exists() && confined(&file, roots).is_none() {
            bail!("{} is outside the notes", file.display());
        }
        return Ok((file, Some(d)));
    }
    let t = Path::new(target);
    if t.is_absolute()
        || t.components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        bail!("'{target}' is outside the notes");
    }
    match resolve_link(p, roots, target) {
        Some(file) => {
            // A wikilink to a daily note is that day, so it gets day navigation too.
            let day = (file.parent() == fs::canonicalize(&p.daily).ok().as_deref())
                .then(|| file.file_stem()?.to_str()?.parse::<NaiveDate>().ok())
                .flatten();
            Ok((file, day))
        }
        None => Ok((p.root.join(format!("{target}.md")), None)),
    }
}

/// The JSON a viewer renders: the note's markdown, where it is, its day neighbours when it is a
/// daily note, and each link it holds with whether that link resolves.
pub fn note(p: &Profile, target: &str) -> Result<Value> {
    let roots = roots(p);
    let (file, date) = locate(p, &roots, target)?;
    // Read only what the containment check passes, so an unresolved path is never opened.
    let readable = confined(&file, &roots);
    let exists = readable.is_some();
    let file = readable.unwrap_or(file);
    let markdown = if exists {
        fs::read_to_string(&file)?
    } else {
        String::new()
    };
    let vault = fs::canonicalize(&p.vault).unwrap_or_else(|_| p.vault.clone());
    // Vault-relative when the note is in the vault, else relative to the profile root (a job
    // profile's root sits outside the vault).
    let rel = crate::config::wikilink(
        if file.starts_with(&vault) {
            &vault
        } else {
            &p.root
        },
        &file,
    );
    let title = markdown
        .lines()
        .find_map(|l| l.strip_prefix("# "))
        .map(|t| t.trim().to_string())
        .unwrap_or_else(|| rel.clone());
    let (prev, next) = match date {
        Some(d) => {
            let all = days(p);
            (
                all.iter().rev().find(|x| **x < d).map(|x| x.to_string()),
                all.iter().find(|x| **x > d).map(|x| x.to_string()),
            )
        }
        None => (None, None),
    };
    let links: Vec<Value> = links(&markdown)
        .into_iter()
        .map(|(t, label)| json!({"target": t, "label": label, "exists": resolve_link(p, &roots, &t).is_some()}))
        .collect();
    Ok(json!({
        "target": link_target(target),
        "profile": p.name,
        "path": file.to_string_lossy(),
        "rel": rel,
        "title": title,
        "exists": exists,
        "date": date.map(|d| d.to_string()),
        "prev": prev,
        "next": next,
        "markdown": markdown,
        "links": links,
    }))
}

/// `notes show [<target>] [--json]`: the note's markdown, or with `--json` the object `note`
/// builds. A note that does not exist is not an error (`exists: false`); a target outside the
/// notes is.
pub fn run(p: &Profile, target: &str, as_json: bool) -> Result<i32> {
    let v = note(p, target)?;
    if as_json {
        println!("{v}");
    } else if v["exists"].as_bool() == Some(true) {
        print!("{}", v["markdown"].as_str().unwrap_or(""));
    } else {
        eprintln!(
            "no note for '{}' ({})",
            target,
            v["path"].as_str().unwrap_or("")
        );
        return Ok(1);
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault(tag: &str) -> (PathBuf, Profile) {
        let root = std::env::temp_dir().join(format!("show-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let p = crate::config::test_profile(&root.to_string_lossy());
        fs::create_dir_all(&p.daily).unwrap();
        fs::create_dir_all(root.join("status")).unwrap();
        fs::write(
            p.daily.join("2026-11-04.md"),
            "# Wed\n\n## Focus\n- [ ] a\n\n[[outbox]] [[status/inbox|Inbox]] [[gone]] [[outbox]]\n",
        )
        .unwrap();
        fs::write(p.daily.join("2026-11-02.md"), "# Mon\n").unwrap();
        fs::write(p.daily.join("2026-11-05.md"), "# Thu\n").unwrap();
        fs::write(root.join("outbox.md"), "# Outbox\n").unwrap();
        fs::write(root.join("status/inbox.md"), "# Inbox status\n").unwrap();
        (root, p)
    }

    #[test]
    fn a_day_has_its_neighbours_and_its_links_with_whether_each_resolves() {
        let (root, p) = vault("day");
        let v = note(&p, "daily:2026-11-04").unwrap();
        assert_eq!(v["exists"], true);
        assert_eq!(v["title"], "Wed");
        assert_eq!(v["rel"], "journal/daily/2026-11-04");
        assert_eq!(v["prev"], "2026-11-02");
        assert_eq!(v["next"], "2026-11-05");
        let links: Vec<(String, String, bool)> = v["links"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| {
                (
                    l["target"].as_str().unwrap().into(),
                    l["label"].as_str().unwrap().into(),
                    l["exists"].as_bool().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            links,
            vec![
                ("outbox".into(), "outbox".into(), true),
                ("status/inbox".into(), "Inbox".into(), true),
                ("gone".into(), "gone".into(), false),
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_wikilink_target_opens_with_its_label_and_heading_cut_off() {
        let (root, p) = vault("link");
        let v = note(&p, "status/inbox|Inbox").unwrap();
        assert_eq!(v["exists"], true);
        assert_eq!(v["title"], "Inbox status");
        assert_eq!(note(&p, "outbox#Outbox").unwrap()["rel"], "outbox");
        // A link to a daily note is that day, with its neighbours.
        assert_eq!(
            note(&p, "journal/daily/2026-11-04").unwrap()["prev"],
            "2026-11-02"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_missing_note_is_not_an_error_but_says_it_does_not_exist() {
        let (root, mut p) = vault("missing");
        let gone = note(&p, "gone").unwrap();
        assert_eq!(
            (&gone["exists"], &gone["rel"]),
            (&Value::Bool(false), &Value::from("gone"))
        );
        // A profile whose root is not the vault names a missing note from its root, not as a path.
        p.vault = root.join("elsewhere");
        assert_eq!(note(&p, "gone").unwrap()["rel"], "gone");
        let day = note(&p, "daily:2026-11-03").unwrap();
        assert_eq!(day["exists"], false);
        assert_eq!(day["prev"], "2026-11-02");
        assert_eq!(day["next"], "2026-11-04");
        assert!(note(&p, "daily:nope").is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_target_outside_the_notes_is_refused() {
        let (root, p) = vault("escape");
        let outside = root.with_extension("outside.md");
        fs::write(&outside, "secret").unwrap();
        let name = outside.file_stem().unwrap().to_string_lossy().into_owned();
        assert!(note(&p, &format!("../{name}")).is_err());
        assert!(note(&p, &outside.to_string_lossy()).is_err());
        // A symlink inside the notes that points out is no way around it.
        std::os::unix::fs::symlink(&outside, root.join("sneaky.md")).unwrap();
        assert_eq!(note(&p, "sneaky").unwrap()["exists"], false);
        assert_eq!(note(&p, "sneaky").unwrap()["markdown"], "");
        fs::remove_file(outside).unwrap();
        fs::remove_dir_all(root).unwrap();
    }
}
