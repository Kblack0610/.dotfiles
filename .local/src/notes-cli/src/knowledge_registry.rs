//! `knowledge/domains.toml`, the domain registry: every place the knowledge base may grow.
//!
//! Content is data: the entries live in the vault and `notes knowledge domain add` writes them;
//! the binary holds only the rules. A domain's id is its path under `knowledge/`, and the first
//! segment is its kind, so the two can never disagree:
//!
//!   - `core/<x>`: how we work across every project, a hub over its canonical doc;
//!   - `subjects/<x>`: anything researched, in any field;
//!   - `projects/<lab project>`: only what is true of that one project;
//!   - `references`: one digest page per external source.
//!
//! A vault with no `domains.toml` has no registry, and the registry rules are off for it.

use crate::config::Profile;
use crate::knowledge_retired::List;
use crate::logging::Logger;
use crate::md;
use anyhow::{bail, Context, Result};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

pub const FILE: &str = "domains.toml";
/// The hub page every domain gets, under its folder.
pub const INDEX: &str = "index.md";

const HEADER: &str = "# The knowledge domain registry: every path a knowledge page may live under.\n\
# Written by `notes knowledge domain add`; the rules are in notes-cli `knowledge_registry.rs`.\n\
# An id is its path under knowledge/: core/<x>, subjects/<x>, projects/<lab project>, references.\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Core,
    Subject,
    Project,
    Reference,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Domain {
    pub id: String,
    /// One line: what belongs here.
    pub is: String,
    /// Other names for it; with the id's last segment, they must be unique across the registry.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub aliases: Vec<String>,
    /// The docs this domain is a hub over. A core page must link one of them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub canonical: Vec<String>,
    /// Exported repo docs this domain routes, each `<checkout>/<glob>` (`home-config/docs/finance/**`);
    /// the most specific match wins. Routing and hub links: `knowledge_hubs.rs`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repo_docs: Vec<String>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct Registry {
    #[serde(default)]
    pub domain: Vec<Domain>,
}

fn is_slug(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The kind an id names, or None when it is not a valid id.
pub fn kind(id: &str) -> Option<Kind> {
    let parts: Vec<&str> = id.split('/').collect();
    if !parts.iter().all(|s| is_slug(s)) {
        return None;
    }
    match parts.as_slice() {
        ["references"] => Some(Kind::Reference),
        ["core", _] => Some(Kind::Core),
        ["subjects", _] => Some(Kind::Subject),
        ["projects", _] => Some(Kind::Project),
        _ => None,
    }
}

impl Domain {
    pub fn kind(&self) -> Kind {
        kind(&self.id).expect("ids are checked when the registry is read")
    }

    /// The id's last segment: `ops` for `core/ops`.
    pub fn leaf(&self) -> &str {
        self.id.rsplit('/').next().unwrap_or(&self.id)
    }

    fn names(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.leaf()).chain(self.aliases.iter().map(String::as_str))
    }
}

impl Registry {
    /// Every rule an entry must meet, so a hand edit that breaks one fails loudly at read time.
    fn validate(&self) -> Result<()> {
        let mut ids = HashSet::new();
        let mut names = HashSet::new();
        let mut globs = HashSet::new();
        for d in &self.domain {
            if kind(&d.id).is_none() {
                bail!(
                    "domain `{}`: an id is core/<x>, subjects/<x>, projects/<x> or references, in lowercase slugs",
                    d.id
                );
            }
            if d.is.trim().is_empty() {
                bail!("domain `{}` has no `is` line", d.id);
            }
            if d.canonical.iter().any(|c| c.trim().is_empty()) {
                bail!("domain `{}` has an empty canonical doc", d.id);
            }
            if !ids.insert(d.id.as_str()) {
                bail!("domain `{}` is listed twice", d.id);
            }
            for g in &d.repo_docs {
                crate::knowledge_hubs::check_pattern(d, g).map_err(|e| anyhow::anyhow!(e))?;
                if !globs.insert(g.as_str()) {
                    bail!(
                        "domain `{}`: repo_docs `{g}` is already listed by this or another domain",
                        d.id
                    );
                }
            }
            for n in d.names() {
                if !is_slug(n) {
                    bail!("domain `{}`: alias `{n}` is not a lowercase slug", d.id);
                }
                if !names.insert(n) {
                    bail!(
                        "domain `{}`: the name `{n}` is already another domain's",
                        d.id
                    );
                }
            }
        }
        Ok(())
    }

    /// Why `d` may not join the registry (a bad id, no `is` line, a name another domain has).
    pub fn check_new(&self, d: &Domain) -> Result<()> {
        let mut with = Registry {
            domain: self.domain.clone(),
        };
        with.domain.push(d.clone());
        with.validate()
    }

    /// The domain a file under `knowledge` sits in: the one whose id is a prefix of the file's
    /// folder. A file directly in `knowledge/core/` sits in no domain.
    pub fn find(&self, knowledge: &Path, file: &Path) -> Option<&Domain> {
        let dir: Vec<String> = file
            .strip_prefix(knowledge)
            .ok()?
            .parent()?
            .components()
            .filter_map(|c| match c {
                Component::Normal(s) => Some(s.to_string_lossy().into_owned()),
                _ => None,
            })
            .collect();
        self.domain.iter().find(|d| {
            let id: Vec<&str> = d.id.split('/').collect();
            id.len() <= dir.len() && id.iter().zip(&dir).all(|(a, b)| a == b)
        })
    }

    /// The names a tag may use for a domain: each id's last segment.
    pub fn leaves(&self) -> impl Iterator<Item = &str> {
        self.domain.iter().map(Domain::leaf)
    }
}

pub fn path(p: &Profile) -> PathBuf {
    p.knowledge.join(FILE)
}

/// The vault's registry, or None when it has none. A registry that does not parse or breaks a
/// rule is an error: guessing past it would let pages land where nothing was registered.
pub fn load(p: &Profile) -> Result<Option<Registry>> {
    let file = path(p);
    let raw = match fs::read_to_string(&file) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("reading {}", file.display())),
    };
    let reg: Registry =
        toml::from_str(&raw).with_context(|| format!("parsing {}", file.display()))?;
    reg.validate()
        .with_context(|| format!("checking {}", file.display()))?;
    Ok(Some(reg))
}

/// The domain list the schema shows, one bullet per domain.
pub fn render(reg: Option<&Registry>) -> String {
    let Some(reg) = reg.filter(|r| !r.domain.is_empty()) else {
        return "_No registry yet: `notes knowledge domain add` writes `knowledge/domains.toml`._\n"
            .to_string();
    };
    let tick = |v: &[String]| {
        v.iter()
            .map(|s| format!("`{s}`"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut out = String::new();
    for d in &reg.domain {
        out.push_str(&format!("- `{}`: {}", d.id, d.is.trim()));
        if !d.aliases.is_empty() {
            out.push_str(&format!(" Aliases: {}.", tick(&d.aliases)));
        }
        if !d.canonical.is_empty() {
            out.push_str(&format!(" Canonical: {}.", tick(&d.canonical)));
        }
        out.push('\n');
    }
    out
}

/// The README's domain index: one `###` per kind (core, subjects, projects, references), each
/// domain a bullet that links its hub and says what belongs there, in registry order.
pub fn index(reg: Option<&Registry>) -> String {
    let Some(reg) = reg.filter(|r| !r.domain.is_empty()) else {
        return "_No registry yet: `notes knowledge domain add` writes `knowledge/domains.toml`._\n"
            .to_string();
    };
    let kinds = [
        (Kind::Core, "Core: how we work"),
        (Kind::Subject, "Subjects: what we research"),
        (Kind::Project, "Projects: true of one project"),
        (Kind::Reference, "References: one page per external source"),
    ];
    let hub = INDEX.trim_end_matches(".md");
    let mut groups = Vec::new();
    for (kind, heading) in kinds {
        let rows: String = reg
            .domain
            .iter()
            .filter(|d| d.kind() == kind)
            .map(|d| format!("- [[knowledge/{}/{hub}]]: {}\n", d.id, d.is.trim()))
            .collect();
        if !rows.is_empty() {
            groups.push(format!("### {heading}\n\n{rows}"));
        }
    }
    groups.join("\n")
}

/// The hub page a new domain starts with: what belongs there and the docs it links.
fn index_page(d: &Domain, today: NaiveDate) -> String {
    let title = d.leaf().replace('-', " ");
    let kind_tag = if d.kind() == Kind::Project {
        "project"
    } else {
        "reference"
    };
    let mut s = format!(
        "---\ntitle: {title}\nsummary: {is}\ntags: [{leaf}, {kind_tag}]\ncreated: {today}\nupdated: {today}\n---\n\n# {title}\n\n{is}\n",
        is = d.is.trim(),
        leaf = d.leaf(),
    );
    if !d.canonical.is_empty() {
        s.push_str("\n## Canonical docs\n\n");
        for c in &d.canonical {
            s.push_str(&format!("- `{c}`\n"));
        }
    }
    s
}

/// Register a domain: append its entry to `domains.toml` (made on the first add), write its hub
/// page unless one is there, and regenerate the schema. Refuses an id that is not valid, one
/// already registered, and a name (the id's last segment or an alias) another domain has.
/// Returns the files written.
pub fn add(p: &Profile, log: &Logger, d: Domain, today: NaiveDate) -> Result<Vec<PathBuf>> {
    let mut reg = load(p)?.unwrap_or_default();
    reg.domain.push(d.clone());
    reg.validate()?;

    // The hub goes first: a failed write then leaves nothing registered, so a retry works.
    let mut wrote = Vec::new();
    let index = p.knowledge.join(&d.id).join(INDEX);
    if !index.exists() {
        fs::create_dir_all(index.parent().unwrap())?;
        md::write_atomic(&index, &index_page(&d, today))?;
        wrote.push(index);
    }

    let file = path(p);
    let mut text = fs::read_to_string(&file).unwrap_or_else(|_| HEADER.to_string());
    if !text.ends_with('\n') {
        text.push('\n');
    }
    let entry = toml::to_string(&Registry {
        domain: vec![d.clone()],
    })?;
    text.push('\n');
    text.push_str(&entry);
    md::write_atomic(&file, &text)?;
    wrote.push(file);
    wrote.push(crate::knowledge::write_schema(p)?);
    wrote.push(crate::knowledge::write_readme(p, &List::default(), today)?);
    log.info("knowledge", &format!("registered domain {}", d.id));
    Ok(wrote)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(id: &str, aliases: &[&str]) -> Domain {
        Domain {
            id: id.into(),
            is: "what goes here".into(),
            aliases: aliases.iter().map(|s| s.to_string()).collect(),
            canonical: Vec::new(),
            repo_docs: Vec::new(),
        }
    }

    #[test]
    fn the_id_names_the_kind() {
        assert_eq!(kind("core/ops"), Some(Kind::Core));
        assert_eq!(kind("subjects/3d-printing"), Some(Kind::Subject));
        assert_eq!(kind("projects/trader"), Some(Kind::Project));
        assert_eq!(kind("references"), Some(Kind::Reference));
        for bad in [
            "software",
            "core",
            "core/a/b",
            "subjects/Biology",
            "projects/-x",
            "references/x",
        ] {
            assert_eq!(kind(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_name_belongs_to_one_domain() {
        let ok = Registry {
            domain: vec![d("core/ops", &["release"]), d("subjects/linux", &["os"])],
        };
        assert!(ok.validate().is_ok());
        for clash in [
            vec![d("core/ops", &[]), d("core/ops", &[])],
            vec![d("core/ops", &["release"]), d("subjects/release", &[])],
            vec![d("core/ops", &[]), d("subjects/ops", &[])],
            vec![d("core/ops", &["Release"])],
            vec![Domain {
                canonical: vec![" ".into()],
                ..d("core/ops", &[])
            }],
        ] {
            assert!(Registry { domain: clash }.validate().is_err());
        }
    }

    #[test]
    fn a_repo_docs_glob_is_checked_and_belongs_to_one_domain() {
        let with = |id: &str, globs: &[&str]| Domain {
            repo_docs: globs.iter().map(|s| s.to_string()).collect(),
            ..d(id, &[])
        };
        let ok = Registry {
            domain: vec![
                with("core/ops", &["home/docs/a.md"]),
                with("subjects/x", &["home/docs/**"]),
            ],
        };
        assert!(ok.validate().is_ok());
        for bad in [
            vec![with("core/ops", &["no-slash"])],
            vec![with("core/ops", &["*/docs/a.md"])],
            vec![with("core/ops", &["home/../a.md"])],
            vec![
                with("core/ops", &["home/docs/a.md"]),
                with("subjects/x", &["home/docs/a.md"]),
            ],
        ] {
            assert!(Registry { domain: bad }.validate().is_err());
        }
    }

    #[test]
    fn a_file_sits_in_the_domain_its_folder_names() {
        let k = Path::new("/v/knowledge");
        let reg = Registry {
            domain: vec![d("core/ops", &[]), d("references", &[])],
        };
        let at = |rel: &str| reg.find(k, &k.join(rel)).map(|d| d.id.as_str());
        assert_eq!(at("core/ops/release.md"), Some("core/ops"));
        assert_eq!(at("core/ops/deep/x.md"), Some("core/ops"));
        assert_eq!(at("references/brightsign.md"), Some("references"));
        assert_eq!(at("core/ops.md"), None);
        assert_eq!(at("core/opsx/a.md"), None);
        assert_eq!(at("software/a.md"), None);
    }
}
