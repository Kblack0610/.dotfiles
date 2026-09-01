//! Status pages: one generated page per machine-rendered feed, beside the daily note.
//!
//! The note is the human's FOCUS surface, so anything regenerated belongs next to it rather
//! than in it - the argument `board.rs` already makes for the project board. Measured over one
//! week, 83 of 166 commits touching the daily note changed only its comms section.
//!
//! One renderer keyed by [`Feed`], so the pages cannot drift apart: a caller cannot build a
//! [`Page`] without naming a feed, and the feed fixes the frontmatter, title, both headings,
//! the cap and the sibling links.
//!
//! Two traps. `daily::remove_section` and `daily::insert_before_footer` are `pub(crate)` and
//! look applicable; both are wrong, because a page has a bare `---` as frontmatter AND above
//! its footer, so [`render`] rebuilds the whole file. And the bytes must be a function of the
//! SOURCE, never `Local::now()`: the page is compared before writing, so a wall-clock stamp
//! would defeat that. Today's date is the one exception, costing one write per page per day.

use crate::config;
use crate::logging::Logger;
use crate::md;
use anyhow::{Context, Result};
use chrono::Local;
use std::fs;
use std::path::{Path, PathBuf};

/// The generated feeds. A new variant gets a page path, a title, and a place in every other
/// page's footer for free.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Feed {
    Watches,
    Comms,
    Inbox,
}

impl Feed {
    pub const ALL: [Feed; 3] = [Feed::Watches, Feed::Comms, Feed::Inbox];

    pub fn title(&self) -> &'static str {
        match self {
            Feed::Watches => "Watches",
            Feed::Comms => "Comms",
            Feed::Inbox => "Inbox",
        }
    }

    pub fn slug(&self) -> &'static str {
        match self {
            Feed::Watches => "watches",
            Feed::Comms => "comms",
            Feed::Inbox => "inbox",
        }
    }

    /// Rows allowed under `## Needs attention` before the rest are counted off. A glance
    /// surface listing sixty things is a list, not a glance.
    pub fn attention_cap(&self) -> usize {
        match self {
            Feed::Watches => 20,
            Feed::Comms => 10,
            Feed::Inbox => 20,
        }
    }
}

/// One item on a page.
///
/// Structured on the axes the renderer decides - bucket, order, indents - and not beyond them.
/// Forcing a watch and an email into one struct would be a shape each feed works around; what
/// matters is that bucketing, ordering and capping happen exactly once, here.
pub struct Row {
    /// True files the row under `## Needs attention`, false under `## Quiet`.
    pub attention: bool,
    /// Rank then name, sorted before rendering so page order is stable across runs.
    pub sort: (u8, String),
    /// Bullet text, without its leading `- `.
    pub head: String,
    /// Sub-bullets rendered `- {label}: {value}`; empty values are dropped.
    pub detail: Vec<(String, String)>,
}

/// A page's content before rendering.
pub struct Page {
    pub feed: Feed,
    /// Italic lead line, already carrying its own freshness stamp when the source has one.
    pub stat: Option<String>,
    pub rows: Vec<Row>,
}

/// Where a feed's page lives: `<root>/status/<slug>.md`.
///
/// ORG-LOCAL, the opposite of `board::board_path` and for the opposite reason. All three feeds
/// are already per-profile, so one shared address would let `notes --profile bnb today`
/// overwrite personal's comms page with bnb's mail.
///
/// Derived, not configured: a second config key is a second thing to get wrong, and
/// `board::agent_board_path` sets the precedent.
pub fn page_path(root: &Path, feed: Feed) -> PathBuf {
    root.join("status").join(format!("{}.md", feed.slug()))
}

/// A `[[wikilink]]`, or empty when the target cannot be linked.
///
/// `config::wikilink` returns the path UNCHANGED when it is not under `root`, so an absolute
/// or `..`-escaping result means "outside the vault". Same guard as `board::link_for`.
fn link(root: &Path, target: &Path, label: &str) -> String {
    let t = config::wikilink(root, target);
    if t.is_empty() || t.starts_with("..") || t.starts_with('/') {
        return String::new();
    }
    format!("[[{t}|{label}]]")
}

/// Render a page. Pure, and takes paths rather than a `Profile` so the link rule is testable
/// without a configured vault - the split `board::link_for` already uses.
pub fn render(root: &Path, daily_dir: &Path, page: &Page) -> String {
    let feed = page.feed;
    let mut s = format!(
        "---\nid: status-{}\ntags: [status]\n---\n\n# {}\n\n",
        feed.slug(),
        feed.title()
    );

    if let Some(stat) = &page.stat {
        s.push_str(&format!("_{stat}_\n\n"));
    }

    let mut rows: Vec<&Row> = page.rows.iter().collect();
    rows.sort_by(|a, b| a.sort.cmp(&b.sort));
    let (attention, quiet): (Vec<&Row>, Vec<&Row>) = rows.into_iter().partition(|r| r.attention);

    let cap = feed.attention_cap();
    s.push_str("## Needs attention\n");
    if attention.is_empty() {
        s.push_str("_Nothing needs you._\n");
    } else {
        for r in attention.iter().take(cap) {
            s.push_str(&format!("- {}\n", r.head));
            for (label, value) in &r.detail {
                if !value.is_empty() {
                    s.push_str(&format!("  - {label}: {value}\n"));
                }
            }
        }
        if attention.len() > cap {
            s.push_str(&format!("- ... and {} more\n", attention.len() - cap));
        }
    }

    s.push_str("\n## Quiet\n");
    if quiet.is_empty() {
        s.push_str("_Nothing._\n");
    } else {
        for r in &quiet {
            s.push_str(&format!("- {}\n", r.head));
        }
    }

    let today = Local::now().date_naive().format("%Y-%m-%d").to_string();
    let daily = daily_dir.join(format!("{today}.md"));
    let mut links: Vec<String> = Vec::new();
    let back = link(root, &daily, "today");
    if !back.is_empty() {
        links.push(back);
    }
    for f in Feed::ALL.iter().filter(|f| **f != feed) {
        let l = link(root, &page_path(root, *f), f.title());
        if !l.is_empty() {
            links.push(l);
        }
    }
    s.push_str(&format!("\n---\n{}\n", links.join(" - ")));
    s
}

/// What [`publish`] did, so a caller can tell whether it is safe to strip the old section.
#[derive(PartialEq, Eq, Debug)]
pub enum Outcome {
    Written,
    Unchanged,
    Skipped(&'static str),
}

/// Render and write a page, only when the bytes change.
///
/// `source_present` is the cross-machine guard. The vault git-syncs between machines on a 30s
/// timer and `git-sync-notes.sh` aborts the rebase and exits on conflict with no retry and no
/// notification, so two machines disagreeing about one page silently wedges the sync rather
/// than merely churning. A machine not hosting a feed's source leaves that page alone.
///
/// Two invariants hold structurally, surviving a caller that forgets the guard: nothing here
/// deletes a page, and an empty render never truncates a page that already has content.
pub fn publish(
    root: &Path,
    daily_dir: &Path,
    log: &Logger,
    page: &Page,
    source_present: bool,
) -> Result<Outcome> {
    if !source_present {
        return Ok(Outcome::Skipped("source not on this machine"));
    }
    let path = page_path(root, page.feed);
    let existing = fs::read_to_string(&path).ok();

    if page.rows.is_empty()
        && page.stat.is_none()
        && existing.as_deref().is_some_and(|c| !c.trim().is_empty())
    {
        return Ok(Outcome::Skipped("empty render, page has content"));
    }

    let rendered = render(root, daily_dir, page);
    if existing.as_deref() == Some(rendered.as_str()) {
        return Ok(Outcome::Unchanged);
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating status dir {}", parent.display()))?;
    }
    md::write_atomic(&path, &rendered).with_context(|| format!("writing {}", path.display()))?;
    log.info(
        "status",
        &format!("wrote {} row(s) to {}", page.rows.len(), path.display()),
    );
    Ok(Outcome::Written)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: &str = "/tmp/notes-status-root";

    fn root() -> PathBuf {
        PathBuf::from(ROOT)
    }

    fn daily() -> PathBuf {
        PathBuf::from(ROOT).join("journal/daily")
    }

    fn row(attention: bool, rank: u8, name: &str, head: &str) -> Row {
        Row {
            attention,
            sort: (rank, name.to_string()),
            head: head.to_string(),
            detail: Vec::new(),
        }
    }

    /// The property the whole change rests on: identical source renders identical bytes, so
    /// compare-then-write can decline to write. A wall-clock stamp breaks this silently.
    #[test]
    fn render_is_byte_stable_across_runs() {
        let page = Page {
            feed: Feed::Watches,
            stat: Some("10 watches - 8 OK, 2 tripped".into()),
            rows: vec![
                row(true, 0, "deploy-drift", "TRIP deploy-drift"),
                row(false, 1, "pmp-api-health", "OK pmp-api-health (http, 5m)"),
            ],
        };
        let once = render(&root(), &daily(), &page);
        let twice = render(&root(), &daily(), &page);
        assert_eq!(once, twice, "identical input must render byte-stable");
    }

    #[test]
    fn tripped_rows_sort_above_quiet_ones() {
        let page = Page {
            feed: Feed::Watches,
            stat: None,
            rows: vec![
                row(false, 1, "pmp-api-health", "OK pmp-api-health"),
                row(true, 0, "deploy-drift", "TRIP deploy-drift"),
            ],
        };
        let out = render(&root(), &daily(), &page);
        let quiet = out.find("## Quiet").unwrap();
        assert!(
            out.find("## Needs attention").unwrap() < quiet,
            "Needs attention must lead:\n{out}"
        );
        assert!(
            out.find("TRIP deploy-drift").unwrap() < quiet,
            "a tripped watch belongs under Needs attention:\n{out}"
        );
        assert!(
            out.find("OK pmp-api-health").unwrap() > quiet,
            "a healthy watch belongs under Quiet:\n{out}"
        );
    }

    /// Pins the two-`---` shape, so a later refactor cannot start section-surgering a page
    /// with `daily::remove_section`, which stops at the first bare `---`.
    #[test]
    fn page_has_frontmatter_and_a_footer_rule() {
        let page = Page {
            feed: Feed::Comms,
            stat: Some("57 unread".into()),
            rows: vec![],
        };
        let out = render(&root(), &daily(), &page);
        assert!(
            out.starts_with("---\nid: status-comms\ntags: [status]\n---\n"),
            "{out}"
        );
        assert_eq!(
            out.matches("\n---\n").count(),
            2,
            "frontmatter plus footer:\n{out}"
        );
        assert!(
            out.contains("[[status/watches|Watches]]"),
            "siblings linked:\n{out}"
        );
        assert!(!out.contains("[[status/comms"), "no self-link:\n{out}");
    }

    #[test]
    fn attention_rows_are_capped_and_the_remainder_counted() {
        let rows: Vec<Row> = (0..15)
            .map(|i| row(true, 0, &format!("m{i:02}"), &format!("ACTION mail {i}")))
            .collect();
        let page = Page {
            feed: Feed::Comms,
            stat: None,
            rows,
        };
        let out = render(&root(), &daily(), &page);
        assert!(
            out.contains("- ... and 5 more"),
            "cap of 10 applies:\n{out}"
        );
    }

    /// A link out of the vault must not become a dangling wikilink.
    #[test]
    fn an_unlinkable_target_is_dropped_not_dangled() {
        assert_eq!(
            link(Path::new("/a"), Path::new("/b/c.md"), "c"),
            "",
            "a target outside root must not be linked"
        );
    }

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("notes-status-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn logger(d: &Path) -> Logger {
        Logger::new(d.join("log"), false)
    }

    fn watches(stat: Option<&str>, rows: Vec<Row>) -> Page {
        Page {
            feed: Feed::Watches,
            stat: stat.map(str::to_string),
            rows,
        }
    }

    /// Compare-then-write, which is the entire reason these pages exist. `board::write_one`
    /// writes unconditionally; copying that here would move the churn instead of ending it.
    #[test]
    fn publish_writes_once_then_declines() {
        let d = scratch("once");
        let log = logger(&d);
        let page = watches(Some("1 watch - 1 OK"), vec![row(false, 1, "a", "OK a")]);

        assert_eq!(
            publish(&d, &d.join("journal/daily"), &log, &page, true).unwrap(),
            Outcome::Written
        );
        assert_eq!(
            publish(&d, &d.join("journal/daily"), &log, &page, true).unwrap(),
            Outcome::Unchanged,
            "unchanged source must not rewrite the page"
        );
        let _ = fs::remove_dir_all(&d);
    }

    /// The cross-machine guard. The vault git-syncs on a 30s timer and the sync script aborts
    /// its rebase and exits on conflict, so a machine that does not host the source must not
    /// touch the page at all - not write it, and above all not blank it.
    #[test]
    fn publish_leaves_the_page_alone_when_the_source_is_absent() {
        let d = scratch("guard");
        let log = logger(&d);
        let path = page_path(&d, Feed::Watches);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "written by another machine\n").unwrap();

        let out = publish(
            &d,
            &d.join("journal/daily"),
            &log,
            &watches(None, vec![]),
            false,
        )
        .unwrap();
        assert!(matches!(out, Outcome::Skipped(_)), "got {out:?}");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "written by another machine\n",
            "a machine without the source must not touch the page"
        );
        let _ = fs::remove_dir_all(&d);
    }

    /// Belt to the guard's braces: even WITH the source present, an empty render must not
    /// truncate a page that already says something. This holds structurally, so it survives a
    /// caller that forgets the guard entirely.
    #[test]
    fn publish_never_blanks_a_page_that_has_content() {
        let d = scratch("blank");
        let log = logger(&d);
        let path = page_path(&d, Feed::Watches);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "real content\n").unwrap();

        let out = publish(
            &d,
            &d.join("journal/daily"),
            &log,
            &watches(None, vec![]),
            true,
        )
        .unwrap();
        assert!(matches!(out, Outcome::Skipped(_)), "got {out:?}");
        assert_eq!(fs::read_to_string(&path).unwrap(), "real content\n");
        let _ = fs::remove_dir_all(&d);
    }
}
