//! Routed repo docs as engine sources: the content ledger and `notes knowledge repo-pending`.
//!
//! The engine's state is per day and an export stamp holds a repo object id with no date, so a
//! date cannot say which doc the engine has read. A content ledger can:
//! `knowledge/_log/repo-docs.tsv`, one `path<TAB>sha256<TAB>date` row per `.repos/` source the gate
//! listed, written by `knowledge apply --gate` (the one writer) after the batch applies. A doc
//! whose content hash is not in the ledger is pending, so a changed doc is read again, an
//! unchanged one never, and the first run needs no seeding: every routed doc starts unledgered.
//!
//! Only docs routed to a `core/*` or `subjects/*` domain are pending. A project-routed doc (a game
//! design doc, a platform app doc) is link-only: its project content is canonical in its repo.

use crate::agent_sheet::EXPORT_DIR;
use crate::config::Profile;
use crate::knowledge_gate::Item;
use crate::knowledge_hubs::{exported, route, Facts};
use crate::knowledge_registry::{self as registry, Kind};
use crate::md;
use anyhow::Result;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;

/// The ledger, under the engine's `_log/`.
const LEDGER: &str = "repo-docs.tsv";

/// The content hash the ledger holds: lowercase hex SHA-256.
pub fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A vault-relative source path (`.repos/<checkout>/<path>`) is an exported repo doc.
pub fn is_repo_source(path: &str) -> bool {
    path.strip_prefix(EXPORT_DIR)
        .is_some_and(|r| r.starts_with('/'))
}

/// The `(path, sha)` rows the gate's items earn: those that carry a hash (an exported repo doc)
/// and that `read` accepts, that is, not a doc whose every op was refused.
pub fn read_rows(items: &[Item], read: impl Fn(&str) -> bool) -> Vec<(String, String)> {
    items
        .iter()
        .filter(|i| !i.sha.is_empty() && read(&i.id))
        .map(|i| (i.path.clone(), i.sha.clone()))
        .collect()
}

/// Record the repo docs of a batch the engine has now read: each exported doc the gate listed,
/// except one whose only ops were refused (a guard, a model slip), which stays pending for another
/// night. A failed write only re-queues them, so it is a warning like the README.
pub fn ledger(
    p: &Profile,
    items: &[Item],
    read: impl Fn(&str) -> bool,
    date: &str,
    log: &crate::logging::Logger,
) {
    if let Err(e) = record(p, &read_rows(items, read), date) {
        log.warn("knowledge", &format!("repo-docs ledger not written: {e:#}"));
    }
}

fn ledger_file(p: &Profile) -> PathBuf {
    p.knowledge.join("_log").join(LEDGER)
}

/// path -> (sha, date). A missing ledger is an empty one.
fn read(p: &Profile) -> BTreeMap<String, (String, String)> {
    let raw = fs::read_to_string(ledger_file(p)).unwrap_or_default();
    raw.lines()
        .filter_map(|l| {
            let mut f = l.split('\t');
            Some((
                f.next()?.to_string(),
                (f.next()?.to_string(), f.next()?.to_string()),
            ))
        })
        .collect()
}

/// Record that `date`'s run read each `(path, sha)`; a path already there is replaced. Writes
/// only on change.
pub fn record(p: &Profile, rows: &[(String, String)], date: &str) -> Result<()> {
    let mut ledger = read(p);
    let before = ledger.clone();
    for (path, sha) in rows {
        let same = ledger.get(path).is_some_and(|(s, _)| s == sha);
        if !same {
            ledger.insert(path.clone(), (sha.clone(), date.to_string()));
        }
    }
    if ledger == before {
        return Ok(());
    }
    let mut out = String::new();
    for (path, (sha, d)) in &ledger {
        out.push_str(&format!("{path}\t{sha}\t{d}\n"));
    }
    let file = ledger_file(p);
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    md::write_atomic(&file, &out)
}

/// The exports the engine has not read at their current content, routed to a core or subject
/// domain, oldest export first (path breaks a tie), at most `limit`. Absolute paths: the gate's
/// source lines.
pub fn pending(p: &Profile, limit: usize) -> Result<Vec<PathBuf>> {
    let Some(reg) = registry::load(p)? else {
        return Ok(Vec::new());
    };
    let docs = exported(&p.vault);
    if docs.is_empty() {
        return Ok(Vec::new());
    }
    let facts = Facts::load(&reg, project_map::cached().as_deref());
    let ledger = read(p);
    let mut due: Vec<(SystemTime, String, PathBuf)> = Vec::new();
    for doc in docs {
        let routed = route(&reg, &facts, &doc).and_then(registry::kind);
        if !matches!(routed, Some(Kind::Core | Kind::Subject)) {
            continue;
        }
        let file = p.vault.join(EXPORT_DIR).join(&doc);
        // As the gate reads it: a file that is not UTF-8 text never gets a hash there, so it
        // would never be ledgered and would hold a slot every night.
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        let key = format!("{EXPORT_DIR}/{doc}");
        if ledger
            .get(&key)
            .is_some_and(|(s, _)| *s == sha(text.as_bytes()))
        {
            continue;
        }
        let at = fs::metadata(&file)
            .and_then(|m| m.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        due.push((at, doc, file));
    }
    due.sort();
    Ok(due.into_iter().take(limit).map(|(_, _, f)| f).collect())
}

/// `notes knowledge repo-pending [--limit N]`: one absolute path per line.
pub fn run(p: &Profile, limit: Option<usize>) -> Result<()> {
    for f in pending(p, limit.unwrap_or(usize::MAX))? {
        println!("{}", f.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn vault(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-repo-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("knowledge/_log")).unwrap();
        dir
    }

    fn write(root: &std::path::Path, rel: &str, body: &str) {
        let f = root.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(f, body).unwrap();
    }

    const REGISTRY: &str =
        "[[domain]]\nid = \"core/ops\"\nis = \"ops\"\nrepo_docs = [\"home/docs/**\"]\n\n\
        [[domain]]\nid = \"projects/game\"\nis = \"a game\"\nrepo_docs = [\"game/docs/**\"]\n";

    fn names(files: Vec<PathBuf>, root: &std::path::Path) -> Vec<String> {
        files
            .into_iter()
            .map(|f| f.strip_prefix(root).unwrap().to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn a_sha_is_the_hex_sha256_of_the_content() {
        assert_eq!(
            sha(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn only_unledgered_core_and_subject_docs_are_pending_oldest_first() {
        let root = vault("pending");
        write(&root, "knowledge/domains.toml", REGISTRY);
        write(&root, ".repos/home/docs/a.md", "# A\n");
        write(&root, ".repos/home/docs/b.md", "# B\n");
        write(&root, ".repos/game/docs/design.md", "# Design\n");
        let p = config::test_profile(root.to_str().unwrap());
        // Same mtime: the path breaks the tie. The game doc is project-routed: link-only.
        let all = names(pending(&p, 10).unwrap(), &root);
        assert_eq!(all, [".repos/home/docs/a.md", ".repos/home/docs/b.md"]);
        assert_eq!(pending(&p, 1).unwrap().len(), 1);
        // A ledgered doc at its current content is skipped, a changed one is pending again.
        record(
            &p,
            &[(".repos/home/docs/a.md".into(), sha(b"# A\n"))],
            "2026-11-21",
        )
        .unwrap();
        assert_eq!(
            names(pending(&p, 10).unwrap(), &root),
            [".repos/home/docs/b.md"]
        );
        write(&root, ".repos/home/docs/a.md", "# A, changed\n");
        assert_eq!(pending(&p, 10).unwrap().len(), 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_oldest_export_goes_first() {
        let root = vault("oldest");
        write(&root, "knowledge/domains.toml", REGISTRY);
        write(&root, ".repos/home/docs/a.md", "# A\n");
        write(&root, ".repos/home/docs/b.md", "# B\n");
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(86_400);
        fs::File::options()
            .write(true)
            .open(root.join(".repos/home/docs/b.md"))
            .unwrap()
            .set_modified(old)
            .unwrap();
        let p = config::test_profile(root.to_str().unwrap());
        assert_eq!(
            names(pending(&p, 10).unwrap(), &root),
            [".repos/home/docs/b.md", ".repos/home/docs/a.md"]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_ledger_replaces_a_row_and_writes_only_on_change() {
        let root = vault("ledger");
        let p = config::test_profile(root.to_str().unwrap());
        record(&p, &[(".repos/h/a.md".into(), "s1".into())], "2026-11-20").unwrap();
        let file = ledger_file(&p);
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            ".repos/h/a.md\ts1\t2026-11-20\n"
        );
        let stamp = fs::metadata(&file).unwrap().modified().unwrap();
        record(&p, &[(".repos/h/a.md".into(), "s1".into())], "2026-11-21").unwrap();
        assert_eq!(fs::metadata(&file).unwrap().modified().unwrap(), stamp);
        record(&p, &[(".repos/h/a.md".into(), "s2".into())], "2026-11-22").unwrap();
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            ".repos/h/a.md\ts2\t2026-11-22\n"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_file_the_gate_cannot_read_is_never_pending() {
        let root = vault("binary");
        write(&root, "knowledge/domains.toml", REGISTRY);
        write(&root, ".repos/home/docs/a.md", "# A\n");
        fs::write(root.join(".repos/home/docs/latin1.md"), [0xe9, 0xff, 0x00]).unwrap();
        let p = config::test_profile(root.to_str().unwrap());
        assert_eq!(
            names(pending(&p, 10).unwrap(), &root),
            [".repos/home/docs/a.md"]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn no_registry_or_no_export_has_nothing_pending() {
        let root = vault("none");
        let p = config::test_profile(root.to_str().unwrap());
        write(&root, ".repos/home/docs/a.md", "# A\n");
        assert!(pending(&p, 10).unwrap().is_empty());
        write(&root, "knowledge/domains.toml", REGISTRY);
        fs::remove_dir_all(root.join(".repos")).unwrap();
        assert!(pending(&p, 10).unwrap().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn only_hashed_items_the_caller_accepts_earn_a_row() {
        let item = |id: &str, sha: &str| Item {
            id: id.into(),
            path: format!(".repos/h/{id}.md"),
            sha: sha.into(),
            ..Item::default()
        };
        let items = [item("s1", "a"), item("s2", ""), item("s3", "c")];
        let rows = read_rows(&items, |id| id != "s3");
        assert_eq!(rows, [(".repos/h/s1.md".to_string(), "a".to_string())]);
    }

    #[test]
    fn a_source_path_is_a_repo_doc_only_under_the_export_dir() {
        assert!(is_repo_source(".repos/home/README.md"));
        assert!(!is_repo_source(".repos"));
        assert!(!is_repo_source("lab/x/.repos/a.md"));
        assert!(!is_repo_source(".reposx/a.md"));
    }
}
