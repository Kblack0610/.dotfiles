//! The priority reasons: the one list of why a row sits at its priority, and the `#why/<slug>`
//! row tag checked against it. The list is data, `~/.config/inbox-triage/rules/priority-reasons.tsv`
//! (slug, priority, meaning; one tab-separated reason per line), read here to validate and, once
//! the priority pass is wired to it, by the rubric too, so the words a model may answer are the
//! words this CLI accepts. Each slug belongs to exactly one priority, so a
//! reason also checks the row's priority word.

use crate::md;
use anyhow::{bail, Context, Result};
use std::path::PathBuf;

/// The tag prefix a row carries its reason under.
pub(crate) const TAG: &str = "why/";

/// Overrides [`path`], for a test or a vault copy.
const PATH_ENV: &str = "NOTES_PRIORITY_REASONS";

pub(crate) struct Reason {
    pub slug: String,
    /// The bare priority word the reason belongs to (`high`).
    pub priority: String,
}

/// Where the list lives.
fn path() -> PathBuf {
    std::env::var_os(PATH_ENV).map_or_else(
        || crate::config::home().join(".config/inbox-triage/rules/priority-reasons.tsv"),
        PathBuf::from,
    )
}

/// The reasons in `text`, one per `slug<TAB>priority<TAB>meaning` line. Blank lines and `#`
/// lines are skipped. A slug that is not lower-case kebab, a priority that is not one of the
/// four, or a repeated slug is an error: the list is the contract, so a typo is caught here.
pub(crate) fn parse(text: &str) -> Result<Vec<Reason>> {
    let mut out: Vec<Reason> = Vec::new();
    for (i, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let mut cols = line.split('\t');
        let (Some(slug), Some(priority), Some(meaning)) = (cols.next(), cols.next(), cols.next())
        else {
            bail!("line {}: want slug<TAB>priority<TAB>meaning", i + 1);
        };
        let kebab = !slug.is_empty()
            && slug.starts_with(|c: char| c.is_ascii_lowercase())
            && slug
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
        if !kebab {
            bail!("line {}: '{slug}' is not a lower-case kebab slug", i + 1);
        }
        if !["urgent", "high", "normal", "low"].contains(&priority) {
            bail!(
                "line {}: '{priority}' is not urgent, high, normal or low",
                i + 1
            );
        }
        if meaning.trim().is_empty() {
            bail!("line {}: '{slug}' has no meaning", i + 1);
        }
        if out.iter().any(|r| r.slug == slug) {
            bail!("line {}: '{slug}' is listed twice", i + 1);
        }
        out.push(Reason {
            slug: slug.to_string(),
            priority: priority.to_string(),
        });
    }
    Ok(out)
}

pub(crate) fn load() -> Result<Vec<Reason>> {
    let p = path();
    let text = std::fs::read_to_string(&p)
        .with_context(|| format!("the reason list {} is unreadable", p.display()))?;
    parse(&text).with_context(|| format!("the reason list {}", p.display()))
}

/// The reason named `slug`, or the refusal listing the slugs there are.
pub(crate) fn lookup(slug: &str) -> Result<Reason> {
    lookup_in(load()?, slug)
}

fn lookup_in(all: Vec<Reason>, slug: &str) -> Result<Reason> {
    let slug = slug.trim().trim_start_matches('#').trim_start_matches(TAG);
    match all.iter().position(|r| r.slug == slug) {
        Some(i) => Ok(all.into_iter().nth(i).expect("position is in range")),
        None => bail!(
            "'{slug}' is not a priority reason ({}), so nothing was written",
            all.iter()
                .map(|r| r.slug.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// The `why/<slug>` tags a row's text carries before its marker, lower-cased, no `#`.
pub(crate) fn tags_of(line: &str) -> Vec<String> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    md::find_hashtags(head)
        .into_iter()
        .filter(|t| t.starts_with(TAG))
        .collect()
}

/// The slug a row's `#why/<slug>` names, if it has one.
pub(crate) fn slug_of(line: &str) -> Option<String> {
    tags_of(line)
        .into_iter()
        .next()
        .map(|t| t[TAG.len()..].to_string())
}

/// The row's bare priority word, from its tag.
fn priority_of(line: &str) -> Option<&'static str> {
    md::task_priority(line).map(|t| t.trim_start_matches('#'))
}

/// `text` with `#why/<slug>` added, and the reason's priority when it carries none of its own.
/// The first line takes the tags, so a pasted block keeps its detail lines. A priority the text
/// already has stays, and [`refuse_bad`] then says when it is the wrong level for the reason.
pub(crate) fn with_reason(text: &str, slug: &str) -> Result<String> {
    with_reason_in(lookup(slug)?, text)
}

fn with_reason_in(r: Reason, text: &str) -> Result<String> {
    let (first, rest) = text
        .split_once('\n')
        .map_or((text, None), |(a, b)| (a, Some(b)));
    let mut line = format!("{} #{TAG}{}", first.trim_end(), r.slug);
    if priority_of(first).is_none() {
        line = format!("{line} #{}", r.priority);
    }
    Ok(match rest {
        Some(rest) => format!("{line}\n{rest}"),
        None => line,
    })
}

/// The words of `ptask add`, joined, with `--why`'s reason and priority when one is given.
pub(crate) fn add_text(words: &[String], why: Option<&str>) -> Result<String> {
    let text = words.join(" ");
    match why {
        Some(slug) => with_reason(&text, slug),
        None => Ok(text),
    }
}

/// `ptask tag --add`'s tags plus `--why`'s `#why/<slug>`, and the reason's priority unless one
/// of the tags already is a priority ([`refuse_bad`] then says when it is the wrong level).
pub(crate) fn tag_adds(mut add: Vec<String>, why: Option<&str>) -> Result<Vec<String>> {
    if let Some(slug) = why {
        let r = lookup(slug)?;
        add.push(format!("#{TAG}{}", r.slug));
        if !add.iter().any(|t| md::is_priority(t)) {
            add.push(format!("#{}", r.priority));
        }
    }
    Ok(add)
}

/// Why an edit from `old` to `new` is refused: `new` names a reason the list does not have, two
/// reasons, or a reason of another priority than the row's. Nothing is checked when the edit
/// changes neither the row's reasons nor its priority, so a row that already breaks this can
/// still be edited, fixed or closed.
pub(crate) fn refuse_bad(old: &str, new: &str) -> Result<()> {
    if tags_of(new).is_empty() {
        return Ok(());
    }
    refuse_bad_in(load()?, old, new)
}

fn refuse_bad_in(all: Vec<Reason>, old: &str, new: &str) -> Result<()> {
    let mut tags = tags_of(new);
    tags.dedup();
    if tags.is_empty() || (tags == tags_of(old) && priority_of(new) == priority_of(old)) {
        return Ok(());
    }
    if tags.len() > 1 {
        bail!(
            "a row has one reason, and this one has {}: keep one, so nothing was written",
            tags.iter()
                .map(|t| format!("#{t}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    let slug = &tags[0][TAG.len()..];
    let r = lookup_in(all, slug)?;
    match priority_of(new) {
        Some(p) if p == r.priority => Ok(()),
        Some(p) => bail!(
            "#{TAG}{slug} is a #{} reason, but the row is #{p}: give a #{p} reason, or set the priority with --why {slug}, so nothing was written",
            r.priority
        ),
        None => bail!(
            "#{TAG}{slug} is a #{} reason and the row has no priority: pass --why {slug}, which writes both, so nothing was written",
            r.priority
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shipped list parses, has a reason at every level, and its slugs stay kebab-case.
    #[test]
    fn the_shipped_list_is_well_formed() {
        let all = parse(include_str!(
            "../../../../.config/inbox-triage/rules/priority-reasons.tsv"
        ))
        .unwrap();
        for level in ["urgent", "high", "normal", "low"] {
            assert!(all.iter().any(|r| r.priority == level), "no {level} reason");
        }
    }

    #[test]
    fn parse_refuses_a_typo_in_the_list() {
        assert!(parse("a\thigh\tm\n").is_ok());
        assert!(parse("# note\n\na\thigh\tm\n").is_ok());
        for bad in [
            "a\tmedium\tm\n",
            "A\thigh\tm\n",
            "a b\thigh\tm\n",
            "a\thigh\n",
            "a\thigh\t \n",
            "a\thigh\tm\na\tlow\tn\n",
        ] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
    }

    fn list() -> Vec<Reason> {
        parse("feature\tnormal\tm\nupkeep\tlow\tm\nred-main\thigh\tm\n").unwrap()
    }

    #[test]
    fn a_reason_is_checked_against_the_list_and_the_rows_priority() {
        let ok = "- [ ] fix(a): b #low #why/upkeep <!-- id:x-1 -->";
        assert!(refuse_bad_in(list(), "- [ ] fix(a): b #low", ok).is_ok());
        let e = |old: &str, new: &str| refuse_bad_in(list(), old, new).unwrap_err().to_string();
        // NEGATIVE CONTROL: a reason of another priority, an unknown one, two, and no priority.
        assert!(e("- [ ] a #high", "- [ ] a #high #why/upkeep").contains("is a #low reason"));
        assert!(e("- [ ] a #low", "- [ ] a #low #why/nope").contains("not a priority reason"));
        assert!(e("- [ ] a #low", "- [ ] a #low #why/upkeep #why/feature").contains("one reason"));
        assert!(e("- [ ] a", "- [ ] a #why/upkeep").contains("no priority"));
        // a row that already breaks it still takes an edit that touches neither
        let bad = "- [ ] a #high #why/upkeep";
        assert!(refuse_bad_in(list(), bad, "- [ ] a b #high #why/upkeep").is_ok());
        assert!(refuse_bad_in(list(), bad, "- [ ] a #low #why/upkeep").is_ok());
        assert!(refuse_bad_in(list(), bad, "- [ ] a #normal #why/upkeep").is_err());
        // a proof marker is not a tag
        assert!(refuse_bad_in(list(), "- [ ] a #low", "- [ ] a #low <!-- #why/nope -->").is_ok());
    }

    #[test]
    fn with_reason_adds_the_level_the_row_lacks() {
        assert_eq!(
            with_reason_in(lookup_in(list(), "upkeep").unwrap(), "fix(a): b\n  detail").unwrap(),
            "fix(a): b #why/upkeep #low\n  detail"
        );
        assert_eq!(
            with_reason_in(lookup_in(list(), "red-main").unwrap(), "fix(a): b #high").unwrap(),
            "fix(a): b #high #why/red-main"
        );
        assert!(lookup_in(list(), "nope").is_err());
        // the same slug twice is one reason, not two
        assert!(refuse_bad_in(
            list(),
            "- [ ] a #low",
            "- [ ] a #low #why/upkeep #why/upkeep"
        )
        .is_ok());
    }
}
