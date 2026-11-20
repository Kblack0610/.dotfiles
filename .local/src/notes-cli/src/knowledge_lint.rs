//! `notes knowledge lint`: how far the knowledge base has drifted from its schema and registry.
//!
//! Read-only and deterministic. It counts the same rules `apply` enforces on a write, run over
//! every page already there, plus what only shows across pages (near-duplicate titles, broken
//! links). Given the retired list (`--retired`, see `knowledge_retired.rs`), it also counts the
//! lines that still name a retired host or command as live. A cleanup pass reads the `--json`
//! counts; zero in every class is the goal.

use crate::config::{self, Profile};
use crate::index;
use crate::knowledge::{
    articles, core_topics, dated, frontmatter, kind_violation, list_tags, normalize, tag_vocab,
    title_of, REQUIRED,
};
use crate::knowledge_registry::{self as registry, Registry};
use crate::knowledge_retired::{self as retired, List};
use anyhow::Result;
use std::collections::BTreeSet;
use std::fs;

/// Two titles whose words overlap by at least this share are near-duplicates.
const NEAR_DUP_PCT: usize = 75;

/// The classes in the order they print, so the output and the JSON keys never reorder.
const CLASSES: [&str; 10] = [
    "unregistered",
    "dated_slug",
    "no_frontmatter",
    "unknown_tag",
    "near_duplicate_title",
    "broken_link",
    "core_no_canonical",
    "project_restates_core",
    "retired_host",
    "retired_command",
];

pub struct Report {
    pub articles: usize,
    /// one entry per class in `CLASSES` order: (class, one line per finding)
    pub classes: Vec<(&'static str, Vec<String>)>,
}

impl Report {
    pub fn total(&self) -> usize {
        self.classes.iter().map(|(_, v)| v.len()).sum()
    }

    fn class(&mut self, name: &str) -> &mut Vec<String> {
        &mut self
            .classes
            .iter_mut()
            .find(|(c, _)| *c == name)
            .expect("a class in CLASSES")
            .1
    }
}

/// The title's words that say what it is about: lowercase, 3 letters or more, no bare numbers
/// (a date in a title splits into numbers, so dated diaries of one topic compare equal).
fn title_words(title: &str) -> BTreeSet<String> {
    normalize(title)
        .split(' ')
        .filter(|w| w.len() >= 3 && !w.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_string)
        .collect()
}

pub fn lint(p: &Profile, gone: &List) -> Result<Report> {
    let reg: Option<Registry> = registry::load(p)?;
    let vocab = tag_vocab(reg.as_ref());
    let core = reg.as_ref().map(|r| core_topics(p, r)).unwrap_or_default();
    let mut report = Report {
        articles: 0,
        classes: CLASSES.iter().map(|c| (*c, Vec::new())).collect(),
    };
    let mut titles: Vec<(String, BTreeSet<String>)> = Vec::new();

    for f in articles(p) {
        report.articles += 1;
        let rel = format!("{}.md", config::wikilink(&p.root, &f));
        let content = fs::read_to_string(&f).unwrap_or_default();
        let fm = frontmatter(&content);
        let domain = reg.as_ref().and_then(|r| r.find(&p.knowledge, &f));
        // No registry means nothing is registered yet: every page counts.
        if domain.is_none() {
            report.class("unregistered").push(rel.clone());
        }
        if dated(&f.file_stem().unwrap_or_default().to_string_lossy()) {
            report.class("dated_slug").push(rel.clone());
        }
        let missing: Vec<&str> = match &fm {
            None => vec!["frontmatter"],
            Some(fm) => REQUIRED
                .iter()
                .copied()
                .filter(|k| fm.get(*k).is_none_or(|v| v.is_empty() || v == "[]"))
                .collect(),
        };
        if !missing.is_empty() {
            report
                .class("no_frontmatter")
                .push(format!("{rel}: missing {}", missing.join(", ")));
        }
        if let Some(tags) = fm.as_ref().and_then(|fm| fm.get("tags")) {
            for t in list_tags(tags).into_iter().filter(|t| !vocab.contains(t)) {
                report.class("unknown_tag").push(format!("{rel}: `{t}`"));
            }
        }
        let title = title_of(&f, &content);
        if let Some(d) = domain {
            if let Some(why) = kind_violation(d, &title, &content, &core) {
                let class = if d.kind() == registry::Kind::Core {
                    "core_no_canonical"
                } else {
                    "project_restates_core"
                };
                report.class(class).push(format!("{rel}: {why}"));
            }
        }
        for h in gone.stale(&content) {
            let class = match h.retired.kind {
                retired::Kind::Host => "retired_host",
                retired::Kind::Command => "retired_command",
            };
            report.class(class).push(format!(
                "{rel}:{}: `{}` {}",
                h.line, h.retired.name, h.retired.why
            ));
        }
        titles.push((rel, title_words(&title)));
    }

    for (i, (a, wa)) in titles.iter().enumerate() {
        for (b, wb) in &titles[i + 1..] {
            if wa.len() < 2 || wb.len() < 2 {
                continue;
            }
            let shared = wa.intersection(wb).count();
            let union = wa.union(wb).count();
            if shared * 100 >= union * NEAR_DUP_PCT {
                report
                    .class("near_duplicate_title")
                    .push(format!("{a} ~ {b}"));
            }
        }
    }

    // The index scan resolves links between scanned notes; a target it cannot place may still be
    // a real file (a journal note, a `_log`), which is not broken.
    // SCHEMA.md is the contract, not an article: its example links name pages no vault must have.
    let schema = p.knowledge.join(crate::knowledge::SCHEMA_FILE);
    let scan = index::scan(p)?;
    let knowledge_links: BTreeSet<&str> = scan
        .notes
        .iter()
        .filter(|n| n.kind == index::Kind::Knowledge)
        .map(|n| n.link.as_str())
        .collect();
    for (src, target) in &scan.dead {
        if !knowledge_links.contains(src.as_str()) || p.root.join(format!("{src}.md")) == schema {
            continue;
        }
        let on_disk = [p.root.join(format!("{target}.md")), p.root.join(target)]
            .iter()
            .any(|f| f.is_file());
        if !on_disk {
            report
                .class("broken_link")
                .push(format!("{src}.md -> [[{target}]]"));
        }
    }
    Ok(report)
}

pub fn run(p: &Profile, json: bool, gone: &List) -> Result<()> {
    let r = lint(p, gone)?;
    if json {
        let classes: serde_json::Map<String, serde_json::Value> = r
            .classes
            .iter()
            .map(|(c, items)| {
                (
                    c.to_string(),
                    serde_json::json!({ "count": items.len(), "items": items }),
                )
            })
            .collect();
        let out = serde_json::json!({
            "articles": r.articles,
            "total": r.total(),
            "classes": classes,
        });
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(());
    }
    println!(
        "knowledge lint: {} finding(s) across {} article(s)",
        r.total(),
        r.articles
    );
    for (c, items) in &r.classes {
        println!("  {c:<22} {}", items.len());
    }
    for (c, items) in r.classes.iter().filter(|(_, v)| !v.is_empty()) {
        println!("\n{c}:");
        for i in items {
            println!("  {i}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-klint-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("knowledge")).unwrap();
        dir
    }

    fn write(root: &Path, rel: &str, body: &str) {
        let f = root.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(f, body).unwrap();
    }

    fn page(title: &str, tags: &str, body: &str) -> String {
        format!("---\ntitle: {title}\nsummary: s\ntags: [{tags}]\nupdated: 2026-11-19\n---\n\n# {title}\n\n{body}\n")
    }

    fn count(r: &Report, class: &str) -> usize {
        r.classes.iter().find(|(c, _)| *c == class).unwrap().1.len()
    }

    #[test]
    fn a_clean_vault_reads_zero_and_each_drift_counts_in_its_class() {
        let root = vault("drift");
        write(
            &root,
            "knowledge/domains.toml",
            "[[domain]]\nid = \"core/ops\"\nis = \"how we ship\"\ncanonical = [\"LSD/ci.md\"]\n\n[[domain]]\nid = \"projects/trader\"\nis = \"the bot\"\n",
        );
        write(
            &root,
            "knowledge/core/ops/ci.md",
            &page("CI", "ops, reference", "see LSD/ci.md"),
        );
        write(
            &root,
            "knowledge/projects/trader/risk.md",
            &page("Risk rules", "project", "x"),
        );
        let p = config::test_profile(root.to_str().unwrap());
        crate::knowledge::write_schema(&p).unwrap();
        let clean = lint(&p, &List::default()).unwrap();
        assert_eq!(clean.total(), 0, "{:?}", clean.classes);

        write(
            &root,
            "knowledge/software/a.md",
            &page("Fleet gotchas", "software", "x"),
        );
        write(
            &root,
            "knowledge/software/fleet-gotchas-2026-11-09.md",
            &page(
                "Fleet gotchas 2026-11-09",
                "madeup",
                "[[knowledge/nowhere]]",
            ),
        );
        write(&root, "knowledge/software/hand.md", "# hand written\n");
        write(
            &root,
            "knowledge/core/ops/deploy.md",
            &page("Deploy", "ops", "no link"),
        );
        write(
            &root,
            "knowledge/projects/trader/ci.md",
            &page("CI", "project", "see LSD/ci.md"),
        );
        let r = lint(&p, &List::default()).unwrap();
        assert_eq!(count(&r, "unregistered"), 3);
        assert_eq!(count(&r, "dated_slug"), 1);
        assert_eq!(count(&r, "no_frontmatter"), 1);
        assert_eq!(count(&r, "unknown_tag"), 1);
        assert_eq!(count(&r, "near_duplicate_title"), 1);
        assert_eq!(count(&r, "broken_link"), 1);
        assert_eq!(count(&r, "core_no_canonical"), 1);
        assert_eq!(count(&r, "project_restates_core"), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_schema_example_and_code_snippets_are_not_broken_links() {
        let root = vault("nolink");
        write(
            &root,
            "knowledge/SCHEMA.md",
            "# Schema\n\n[[knowledge/subjects/software/example]]\n",
        );
        write(
            &root,
            "knowledge/a.md",
            &page(
                "A",
                "software, reference",
                "```bash\nif [[ -n \"$a\" ]]; then\n```\nand `[[target]]`\n\n[[knowledge/gone]]",
            ),
        );
        let r = lint(
            &config::test_profile(root.to_str().unwrap()),
            &List::default(),
        )
        .unwrap();
        // negative control: the real dead link in the same page still counts
        assert_eq!(
            r.classes
                .iter()
                .find(|(c, _)| *c == "broken_link")
                .unwrap()
                .1,
            vec!["knowledge/a.md -> [[knowledge/gone]]".to_string()]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn with_no_registry_every_page_is_unregistered() {
        let root = vault("noreg");
        write(
            &root,
            "knowledge/software/a.md",
            &page("A thing", "software", "x"),
        );
        let r = lint(
            &config::test_profile(root.to_str().unwrap()),
            &List::default(),
        )
        .unwrap();
        assert_eq!(count(&r, "unregistered"), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_retired_host_or_command_counts_only_with_the_list_and_only_where_it_reads_live() {
        let root = vault("retired");
        write(
            &root,
            "knowledge/domains.toml",
            "[[domain]]\nid = \"subjects/infra\"\nis = \"the home lab\"\n",
        );
        write(
            &root,
            "knowledge/subjects/infra/llm.md",
            &page(
                "Local models",
                "reference",
                "MLX runs on the Mac Studio.\nThe Mac Studio was sold 2026-11-10.\nStart it with `wave-start`.",
            ),
        );
        let p = config::test_profile(root.to_str().unwrap());
        let none = lint(&p, &List::default()).unwrap();
        assert_eq!(none.total(), 0, "{:?}", none.classes);
        let gone = retired::parse(
            "host\tmac-studio\tleft the home-config inventory\ncommand\twave-start\twas deleted\n",
        )
        .unwrap();
        let r = lint(&p, &gone).unwrap();
        assert_eq!(count(&r, "retired_host"), 1);
        assert_eq!(count(&r, "retired_command"), 1);
        assert_eq!(r.total(), 2);
        let _ = fs::remove_dir_all(&root);
    }
}
