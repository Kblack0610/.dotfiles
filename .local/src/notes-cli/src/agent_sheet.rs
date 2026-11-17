//! `<project>/agent/README.md` - the agents' own task sheet, and the link that reaches it.
//!
//! A WORKING BOARD, NOT A SECOND QUEUE. The project's own `README.md` is the queue - every
//! open item, whoever does it, and where done-ness is recorded. This is what the agents
//! write underneath it: the subtasks and in-flight state below a queue row, so work
//! interrupted halfway can be picked up by a session that was not there for the first half.
//!
//! Nothing is handed over and nothing is filtered. A row is not routed here; it is either
//! work the human wants (the queue) or an agent's own breakdown of it (this). That is why
//! there is no tag: the file a row lives in IS what it is, so there is nothing to classify
//! and nothing that can disagree.
//!
//! It also settles WRITES, which a marker on one sheet could not: every agent `ptask` used
//! to rewrite the human's `README.md`, so the file the human keeps open was the file the
//! agents edited all day.
//!
//! STATIC, for every project, agent-touched or not. Created lazily, the cost was lost
//! evidence: work finished with no note to record the proof in, so the proof is gone.

use crate::logging::Logger;
use crate::md;
use crate::projects;
use anyhow::Result;
use std::fs;
use std::path::{Path, PathBuf};

/// The agents' sheet for a project: `<project>/agent/README.md`.
///
/// `README.md` and not `board.md` so the agents' half is the same shape as the human's half
/// one level down - a sheet beside its `versions/`. One pattern, learned once.
pub fn sheet_path(dir: &Path) -> PathBuf {
    projects::agent_dir(dir).join("README.md")
}

/// Which sheet a reader or writer is acting on: a directory, never a predicate. A row
/// belongs to whichever file it is written in, so there is nothing to classify.
///
/// The two are not symmetric. `Human` is the QUEUE - every open item, whoever does it, and
/// where done-ness is recorded. `Agent` is the WORKING board - subtasks and state under a
/// queue row, so interrupted work can be resumed. Neither is a filtered view of the other.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Lane {
    Human,
    Agent,
}

impl Lane {
    /// The directory whose task sheet this lane reads and writes.
    ///
    /// One parser, two paths: `project_tasks::task_sheet` resolves any dir carrying a
    /// `## Tasks`, and the agent scaffold carries one deliberately for this reason.
    pub(crate) fn dir(self, project: &Path) -> PathBuf {
        match self {
            Lane::Human => project.to_path_buf(),
            Lane::Agent => projects::agent_dir(project),
        }
    }

    /// `human` or `agent`, the word `--lane` takes and the ingest record writes.
    pub(crate) fn name(self) -> &'static str {
        match self {
            Lane::Human => "human",
            Lane::Agent => "agent",
        }
    }
}

/// The body a fresh agent sheet starts with: title, a link home, and the empty sections. No
/// `Version:` line: the board follows its sheet, whose `Version:` an untagged row belongs to.
///
/// Deliberately the same skeleton `projects::sheet_body` writes for the human, because every
/// reader downstream (`sheet::open_rows`, `current_rows_for_dir`, the board, `ptask`) is the
/// human sheet's reader. A different skeleton here would mean a second parser, and a second
/// parser is a second set of bugs.
fn body(project: &str, home: &str) -> String {
    let link = if home.is_empty() {
        String::new()
    } else {
        format!("Human sheet: [[{home}|{project}]]\n")
    };
    format!(
        "# {project} - agent board\n{link}\n{}",
        crate::sheet::skeleton()
    )
}

/// Create `<project>/agent/README.md` if it is absent. Returns true when one was written.
///
/// Never touches an existing sheet: this runs from `notes board` and `notes today`, so it
/// fires several times a day against every project. Anything it rewrote, it would rewrite
/// under the agents mid-task.
pub fn ensure(dir: &Path, project: &str, home: &str) -> Result<bool> {
    let path = sheet_path(dir);
    if path.exists() {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    md::write_atomic(&path, &body(project, home))?;
    Ok(true)
}

/// The `Agents:` line a human sheet carries, pointing at that project's agent board and at
/// the cross-project one.
///
/// Emitted by code and not hand-added: `notes board` writes it where it is missing.
pub fn link_line(agent_home: &str) -> String {
    if agent_home.is_empty() {
        return String::new();
    }
    format!("Agents: [[{agent_home}|agent board]] - [[lab/projects/agent-board|all projects]]")
}

/// The head lines code owns on a human sheet, in the order they sit under `Version:`.
const HEAD_KEYS: [&str; 2] = ["Agents: ", "Docs:"];

/// A head line [`with_head`] owns: `Agents: ...` anywhere, and in the head `Docs:` alone or
/// `Docs: ...` (the one-line form it replaced).
fn owned_key(t: &str, in_head: bool) -> (bool, bool) {
    let docs = in_head && (t == HEAD_KEYS[1] || t.starts_with("Docs: "));
    (t.starts_with(HEAD_KEYS[0]) || docs, docs)
}

/// An item [`docs_list`] writes: one link and nothing else, so a bullet the human adds under
/// the list is theirs and stays.
fn is_doc_item(t: &str) -> bool {
    let Some(link) = t.strip_prefix("- ") else {
        return false;
    };
    let wiki = link.starts_with("[[") && link.ends_with("]]") && link.matches("]]").count() == 1;
    let md = link.starts_with('[')
        && link.ends_with(')')
        && link.matches("](").count() == 1
        && !link.contains(' ');
    wiki || md
}

/// Put `lines` directly under the sheet's `Version:` line, replacing any [`HEAD_KEYS`] line
/// already in the head (above the first `## `), and the link items right under `Docs:`.
/// Empty lines are skipped.
///
/// Idempotent by construction: it removes the old lines before inserting, so running it on
/// every board write cannot stack duplicates the way an append would. Returns the new
/// content, or `None` when nothing changed (the overwhelmingly common case, and the one that
/// must not cause a write).
pub fn with_head(content: &str, lines: &[String]) -> Option<String> {
    let mut in_head = true;
    let mut in_docs = false;
    let mut out: Vec<String> = Vec::new();
    for l in content.lines() {
        if l.starts_with("## ") {
            in_head = false;
        }
        // An `Agents:` line anywhere is a stray from before the head was code-owned; a
        // `Docs:` word below the head is the human's.
        let t = l.trim_start();
        in_docs = in_docs && is_doc_item(t);
        let (owned, docs) = owned_key(t, in_head);
        if owned || in_docs {
            in_docs |= docs;
            continue;
        }
        out.push(l.to_string());
    }
    let at = out
        .iter()
        .position(|l| l.trim_start().starts_with("Version:"))?;
    let add = lines.iter().filter(|l| !l.is_empty()).cloned();
    out.splice(at + 1..at + 1, add);
    let out = format!("{}\n", out.join("\n"));
    (out != content).then_some(out)
}

/// A game's docs in its repo, by the playground convention `docs/games/<id>.md` plus the
/// optional `<id>-story.md` and `<id>-look.md`, as `(label, url)` for those on `origin/main`.
///
/// `<id>` is the lowercased basename of the tracker's `path`, the rule `stages.md` checks
/// use. Empty for a project that is not a game or has no checkout or forge slug here.
/// The files are read from the checkout's `origin/main` tree, not its working tree: the
/// links point at `blob/main`, and the human's clone can sit hundreds of commits behind.
pub fn repo_docs(reg: &project_map::Registry, project: &str) -> Vec<(String, String)> {
    let Some(project) = reg.lookup(project) else {
        return Vec::new();
    };
    if reg.kind(project).as_deref() != Some("game") {
        return Vec::new();
    }
    let Some(t) = reg.tracker(project) else {
        return Vec::new();
    };
    let field = |k: &str| t.get(k).and_then(|v| v.as_str()).unwrap_or("");
    let id = Path::new(field("path"))
        .file_name()
        .map(|f| f.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let repo = field("repo");
    let checkout = reg.checkout(repo);
    // The GitHub slug of the same repo the checkout is: a Forgejo-only repo gets no links
    // rather than a github.com URL that does not exist.
    let slug = reg
        .tracker(repo)
        .and_then(|r| r.get("github")?.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let (Some(checkout), Some(slug), false) = (checkout, slug, id.is_empty()) else {
        return Vec::new();
    };
    let on_main = main_files(&checkout, "docs/games/");
    [
        ("design", format!("{id}.md")),
        ("story", format!("{id}-story.md")),
        ("look", format!("{id}-look.md")),
    ]
    .into_iter()
    .filter(|(_, f)| on_main.contains(&format!("docs/games/{f}")))
    .map(|(label, f)| {
        let url = format!("https://github.com/{slug}/blob/main/docs/games/{f}");
        (label.to_string(), url)
    })
    .collect()
}

/// The repo-root paths under `dir` (with its trailing slash) in the checkout's `origin/main`
/// tree, as fresh as its last fetch (a sheet render never touches the network); empty when
/// git fails or the ref is missing, so no link is written for a file not seen.
fn main_files(checkout: &Path, dir: &str) -> Vec<String> {
    std::process::Command::new("git")
        .arg("-C")
        .arg(checkout)
        .args([
            "ls-tree",
            "-z",
            "--full-tree",
            "--name-only",
            "origin/main",
            dir,
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split('\0')
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// The `Docs:` list a human sheet carries: every doc of the project that exists, in a fixed
/// order. The pitch (`docs/idea.md`), the `repo` docs ([`repo_docs`]), `playtest.md`,
/// `ideas.md`, `summary.md` as status, then every other `docs/*.md` and `docs/*/README.md`
/// by name, less [`is_report`] ones. A file that does not exist is not linked.
///
/// One link per `- ` item: an editor wraps on the raw text, so a single line of full-path
/// links wraps into a ragged block even when the link targets are concealed.
pub fn docs_list(vault: &Path, dir: &Path, repo: &[(String, String)]) -> String {
    let wiki = |f: &Path, label: &str| {
        let t = vault_rel(vault, f);
        (!t.is_empty() && f.is_file()).then(|| format!("[[{t}|{label}]]"))
    };
    let mut parts: Vec<String> = Vec::new();
    parts.extend(wiki(&dir.join("docs/idea.md"), "idea"));
    parts.extend(repo.iter().map(|(label, url)| format!("[{label}]({url})")));
    parts.extend(wiki(&dir.join("playtest.md"), "playtest"));
    parts.extend(wiki(&dir.join("ideas.md"), "ideas"));
    parts.extend(wiki(&dir.join("summary.md"), "status"));
    let mut extra: Vec<(String, PathBuf)> = fs::read_dir(dir.join("docs"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                let readme = path.join("README.md");
                return readme.is_file().then_some((name, readme));
            }
            let stem = name.strip_suffix(".md")?;
            let stem = if stem == "README" { "docs" } else { stem };
            (stem != "idea" && !is_report(stem)).then(|| (stem.to_string(), path.clone()))
        })
        .collect();
    extra.sort();
    parts.extend(extra.iter().filter_map(|(label, f)| wiki(f, label)));
    if parts.is_empty() {
        return String::new();
    }
    format!("Docs:\n- {}", parts.join("\n- "))
}

/// A doc named for one moment, not the project: its stem ends in a date (`-2026-11`,
/// `-2026-11-05`) or a pass number (`-p3`). The Docs list keeps to the standing docs, so a
/// project with a run of pass reports still has a short list.
fn is_report(stem: &str) -> bool {
    let parts: Vec<&str> = stem.split('-').collect();
    let num = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_digit());
    let pass = parts.last().is_some_and(|l| {
        l.len() > 1 && l.starts_with('p') && l[1..].bytes().all(|b| b.is_ascii_digit())
    });
    let dated = |k: usize| {
        parts.len() > k
            && num(parts[parts.len() - k], 4)
            && parts[parts.len() - k + 1..].iter().all(|s| num(s, 2))
    };
    pass || dated(2) || dated(3)
}

/// Ensure both halves of the link for one project: the agent sheet exists, and the human's
/// sheet points at it and at its docs (`docs`, from [`docs_list`]).
///
/// Best-effort per project. A project whose sheet cannot be read is skipped rather than
/// fatal - this runs from `notes today`, and one unreadable sheet must not stop the note.
pub fn ensure_pair(
    log: &Logger,
    dir: &Path,
    project: &str,
    human_home: &str,
    agent_home: &str,
    docs: &str,
) -> Result<()> {
    if ensure(dir, project, human_home)? {
        log.info("agent", &format!("created {}", sheet_path(dir).display()));
    }
    let Some(sheet) = crate::project_tasks::task_sheet(dir) else {
        return Ok(());
    };
    let Ok(content) = fs::read_to_string(&sheet) else {
        return Ok(());
    };
    let mut head = vec![link_line(agent_home)];
    head.extend(docs.lines().map(str::to_string));
    if let Some(out) = with_head(&content, &head) {
        md::write_atomic(&sheet, &out)?;
        log.info("agent", &format!("linked {}", sheet.display()));
    }
    Ok(())
}

/// A vault-relative wikilink target for `file`, or `""` when it is not under the vault.
///
/// The same fail-closed rule `board::link_for` follows, for the same reason: an unlinked
/// heading is a cosmetic loss, a dangling wikilink is a broken promise.
fn vault_rel(vault: &Path, file: &Path) -> String {
    let t = crate::config::wikilink(vault, file);
    if t.is_empty() || t.starts_with("..") || t.starts_with('/') {
        return String::new();
    }
    t
}

/// One project's agent sheet, created if absent, with the home link `ensure_all` would give
/// it.
///
/// The on-demand path for `ptask --agent`, and it goes through `ensure` rather than
/// `project_tasks::ensure_task_sheet`: that one scaffolds a bare sheet with no link home.
pub fn ensure_for(p: &crate::config::Profile, dir: &Path, project: &str) -> Result<PathBuf> {
    let home = crate::project_tasks::task_sheet(dir)
        .map(|s| vault_rel(&p.vault, &s))
        .unwrap_or_default();
    ensure(dir, project, &home)?;
    Ok(sheet_path(dir))
}

/// Give every project in every profile its agent sheet, and its human sheet the link.
///
/// Runs from `notes board` (so also from every `notes today`) rather than a one-off
/// migration, because "static" has to mean a project created tomorrow has one too. Both
/// halves are no-ops once satisfied, so the steady-state cost per project is a read of its
/// sheet and `docs/`, and a few stats.
///
/// A profile that fails to resolve is skipped rather than fatal - the rule `write` already
/// follows, because one broken org must not stop the daily note being written.
pub fn ensure_all(log: &Logger) -> Result<usize> {
    let mut n = 0usize;
    let reg = project_map::cached();
    for name in crate::config::all_profile_names()? {
        let Ok(p) = crate::config::resolve(Some(&name)) else {
            continue;
        };
        for (proj, summary) in crate::daily::discover_project_dirs(&p) {
            let Some(dir) = summary.parent() else {
                continue;
            };
            // No task sheet means nothing to link from. A prose
            // brief is not a project that has started; scaffolding into it would put an
            // agent board on something with no task section to put work in.
            let Some(human) = crate::project_tasks::task_sheet(dir) else {
                continue;
            };
            let human_home = vault_rel(&p.vault, &human);
            let agent_home = vault_rel(&p.vault, &sheet_path(dir));
            let repo = reg
                .as_deref()
                .map(|r| repo_docs(r, &proj))
                .unwrap_or_default();
            let docs = docs_list(&p.vault, dir, &repo);
            if ensure_pair(log, dir, &proj, &human_home, &agent_home, &docs).is_ok() {
                n += 1;
            }
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lane_resolves_to_a_directory_one_level_apart() {
        let p = Path::new("/v/projects/current/demo");
        assert_eq!(Lane::Human.dir(p), p);
        assert_eq!(Lane::Agent.dir(p), p.join("agent"));
        // The agent sheet sits where `sheet_path` puts it, so the board and `ptask --agent`
        // cannot disagree about which file the lane is.
        assert_eq!(Lane::Agent.dir(p).join("README.md"), sheet_path(p));
    }

    #[test]
    fn a_fresh_sheet_is_the_same_skeleton_the_human_gets() {
        let b = body("notes-cockpit", "lab/projects/current/notes-cockpit/README");
        assert!(
            b.starts_with("# notes-cockpit - agent board\nHuman sheet: "),
            "{b}"
        );
        assert!(
            !b.contains("Version:"),
            "the board follows its sheet's version:\n{b}"
        );
        assert!(b.ends_with(&crate::sheet::skeleton()), "{b}");
        // The human's reader must find the section, or nothing downstream sees this file.
        assert!(crate::sheet::has_tasks(&b), "{b}");
    }

    #[test]
    fn a_sheet_outside_the_vault_gets_no_dangling_link() {
        // Same rule `board::link_for` follows: an unlinked heading is a cosmetic loss, a
        // dangling wikilink is a broken promise.
        let b = body("stray", "");
        assert!(!b.contains("Human sheet:"), "{b}");
        assert!(crate::sheet::has_tasks(&b), "{b}");
    }

    #[test]
    fn the_link_lands_directly_under_the_version_line() {
        let sheet = "# demo\nVersion: v0.0.2\n\n## Tasks\n- [ ] a\n";
        let out = with_head(sheet, &[link_line("lab/p/demo/agent/README")]).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "# demo");
        assert_eq!(lines[1], "Version: v0.0.2");
        assert!(
            lines[2].starts_with("Agents: [[lab/p/demo/agent/README|agent board]]"),
            "{out}"
        );
        assert!(
            lines[2].contains("[[lab/projects/agent-board|all projects]]"),
            "{out}"
        );
        // and the section is untouched below it
        assert!(out.contains("## Tasks\n- [ ] a\n"), "{out}");
    }

    #[test]
    fn re_linking_replaces_rather_than_stacks() {
        // This runs on every `notes today`. An append would grow the head without bound.
        let sheet = "# demo\nVersion: v0.0.2\n\n## Tasks\n";
        let once = with_head(sheet, &[link_line("lab/p/demo/agent/README")]).unwrap();
        assert!(
            with_head(&once, &[link_line("lab/p/demo/agent/README")]).is_none(),
            "no rewrite"
        );
        assert_eq!(once.matches("Agents: ").count(), 1, "{once}");
    }

    #[test]
    fn a_moved_board_moves_the_link_with_it() {
        // The old line is replaced, never left pointing at a board that is gone.
        let rolled = "# demo\nVersion: v0.0.3\nAgents: [[lab/p/demo/agent/README|agent board]] - [[lab/projects/agent-board|all projects]]\n\n## Tasks\n";
        let out = with_head(rolled, &[link_line("lab/p/demo/agent/README")]);
        assert!(out.is_none(), "same target, so no write: {out:?}");

        let moved = with_head(rolled, &[link_line("lab/other/demo/agent/README")]).unwrap();
        assert_eq!(moved.matches("Agents: ").count(), 1, "{moved}");
        assert!(moved.contains("lab/other/demo/agent/README"), "{moved}");
        assert!(!moved.contains("lab/p/demo/agent/README"), "{moved}");
    }

    // THE NEGATIVE CONTROL. A prose brief with no `Version:` line is NOT a task sheet
    // (`sheet_path` accepts a README only when it declares one), and stamping a link onto
    // one would write into a file this feature has no business touching.
    #[test]
    fn a_sheet_with_no_version_line_is_never_stamped() {
        let prose = "# gsuite-comms\n\nMake GSuite manageable across 6+ accounts.\n";
        assert!(with_head(prose, &[link_line("lab/p/x/agent/README")]).is_none());
    }

    /// A fresh dir under the temp dir, unique per test thread, with `files` written empty.
    fn tree(tag: &str, files: &[&str]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "agent-sheet-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        for f in files {
            let path = dir.join(f);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "").unwrap();
        }
        dir
    }

    #[test]
    fn docs_list_links_only_what_exists_in_a_fixed_order() {
        let vault = tree(
            "docs",
            &[
                "lab/p/demo/README.md",
                "lab/p/demo/ideas.md",
                "lab/p/demo/summary.md",
                "lab/p/demo/playtest.md",
                "lab/p/demo/docs/idea.md",
                "lab/p/demo/docs/zeta.md",
                "lab/p/demo/docs/marketing/README.md",
                "lab/p/demo/docs/briefs/a-brief.md",
            ],
        );
        let dir = vault.join("lab/p/demo");
        let repo = vec![("design".to_string(), "https://x/demo.md".to_string())];
        let line = docs_list(&vault, &dir, &repo);
        assert_eq!(
            line,
            "Docs:\n\
             - [[lab/p/demo/docs/idea|idea]]\n\
             - [design](https://x/demo.md)\n\
             - [[lab/p/demo/playtest|playtest]]\n\
             - [[lab/p/demo/ideas|ideas]]\n\
             - [[lab/p/demo/summary|status]]\n\
             - [[lab/p/demo/docs/marketing/README|marketing]]\n\
             - [[lab/p/demo/docs/zeta|zeta]]"
        );
        let _ = fs::remove_dir_all(&vault);
    }

    #[test]
    fn dated_and_pass_reports_stay_off_the_docs_list() {
        for stem in [
            "capacity-budget-2026-11-05",
            "landscape-review-2026-11",
            "usage-cleanup-p6",
        ] {
            assert!(is_report(stem), "{stem}");
        }
        // a standing doc, a word that starts with p, and a bare year are not reports
        for stem in [
            "release-recommendations",
            "tool-call-usage",
            "pipeline",
            "plan-2026",
            "p",
        ] {
            assert!(!is_report(stem), "{stem}");
        }
    }

    // THE NEGATIVE CONTROL for the docs list: nothing on disk, nothing linked, no list.
    #[test]
    fn docs_list_is_empty_for_a_project_with_no_docs() {
        let vault = tree("nodocs", &["lab/p/bare/README.md"]);
        assert_eq!(docs_list(&vault, &vault.join("lab/p/bare"), &[]), "");
        let _ = fs::remove_dir_all(&vault);
    }

    #[test]
    fn the_docs_list_sits_under_agents_and_rewrites_in_place() {
        let head: Vec<String> = [
            link_line("lab/p/demo/agent/README").as_str(),
            "Docs:",
            "- [[x|new]]",
            "- [two](https://x/two.md)",
        ]
        .map(str::to_string)
        .into();
        // From the old one-line form, and from a longer list: the old items all go, and the
        // body below (its blank line, its task rows) stays.
        for sheet in [
            "# demo\nVersion: v0.0.2\nDocs: [[a|old]] - [[b|old2]]\n\n## Tasks\n- [ ] a\n",
            "# demo\nVersion: v0.0.2\nDocs:\n- [[a|old]]\n- [b](https://x/b.md)\n- [[c|old3]]\n\n## Tasks\n- [ ] a\n",
        ] {
            let out = with_head(sheet, &head).unwrap();
            assert_eq!(
                out,
                "# demo\nVersion: v0.0.2\nAgents: [[lab/p/demo/agent/README|agent board]] - \
                 [[lab/projects/agent-board|all projects]]\nDocs:\n- [[x|new]]\n\
                 - [two](https://x/two.md)\n\n## Tasks\n- [ ] a\n"
            );
            assert!(with_head(&out, &head).is_none(), "idempotent");
        }
    }

    #[test]
    fn a_bullet_the_human_wrote_under_the_docs_list_stays() {
        // Only a lone link is a generated item; a note, or a link with words, is the human's.
        // A head line that merely starts with `Docs:` is not the key either.
        let sheet = "# demo\nVersion: v0.0.2\nDocs:\n- [[a|old]]\n- ping X\n- see [[b|b]] first\n\
                     Docs:see README\n\n## Tasks\n";
        let head = ["Docs:".to_string(), "- [[x|new]]".to_string()];
        let out = with_head(sheet, &head).unwrap();
        assert_eq!(
            out,
            "# demo\nVersion: v0.0.2\nDocs:\n- [[x|new]]\n- ping X\n- see [[b|b]] first\n\
             Docs:see README\n\n## Tasks\n"
        );
        assert!(with_head(&out, &head).is_none(), "idempotent");
    }

    #[test]
    fn a_docs_word_below_the_head_is_not_the_head_line() {
        // Only the head is code-owned; a row or note further down is the human's.
        // A stray `Agents:` line below it is still cleaned, as with_link did.
        let sheet =
            "# demo\nVersion: v0.0.2\n\n## Notes\nDocs: keep me\n- mine too\nAgents: stray\n";
        let out = with_head(sheet, &["Docs:\n- [[x|new]]".to_string()]).unwrap();
        assert!(
            out.contains("## Notes\nDocs: keep me\n- mine too\n"),
            "{out}"
        );
        assert!(!out.contains("Agents: stray"), "{out}");
    }

    #[test]
    fn repo_docs_follow_the_game_convention_and_skip_what_is_missing() {
        let checkout = tree(
            "repo",
            &["docs/games/shapecity.md", "docs/games/shapecity-look.md"],
        );
        // Those two files are on origin/main. The working tree then disagrees both ways, as
        // a clone behind main does: look is gone locally, and a story exists only locally.
        let git = |args: &[&str]| {
            // A pre-commit hook exports these; left set, they aim git at the real repo.
            let ok = std::process::Command::new("git")
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .env_remove("GIT_INDEX_FILE")
                .arg("-C")
                .arg(&checkout)
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .output()
                .unwrap()
                .status
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&["init", "-q"]);
        git(&["add", "."]);
        git(&["commit", "-qm", "docs"]);
        git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        fs::remove_file(checkout.join("docs/games/shapecity-look.md")).unwrap();
        fs::write(checkout.join("docs/games/shapecity-story.md"), "").unwrap();
        let map = format!(
            r#"{{"paths": {{"{0}": "ucp", "{0}/": "fj"}},
                "trackers": {{
                  "ucp": {{"github": "Org/ucp"}},
                  "fj": {{"forgejo": "me/fj"}},
                  "shape-city": {{"type": "game", "repo": "ucp", "path": "Assets/Games/ShapeCity"}},
                  "fj-game": {{"type": "game", "repo": "fj", "path": "Assets/Games/ShapeCity"}},
                  "an-app": {{"type": "app", "repo": "ucp", "path": "Assets/Games/ShapeCity"}}
                }}}}"#,
            checkout.display()
        );
        let reg = project_map::Registry::parse(&map).unwrap();
        let docs = repo_docs(&reg, "shape-city");
        let labels: Vec<&str> = docs.iter().map(|(l, _)| l.as_str()).collect();
        assert_eq!(
            labels,
            ["design", "look"],
            "origin/main decides: a local-only story is not linked, a look missing locally is"
        );
        assert_eq!(
            docs[0].1,
            "https://github.com/Org/ucp/blob/main/docs/games/shapecity.md"
        );
        assert!(
            repo_docs(&reg, "an-app").is_empty(),
            "only a game has repo docs"
        );
        assert!(
            repo_docs(&reg, "fj-game").is_empty(),
            "a repo with no GitHub slug gets no github.com links"
        );
        assert_eq!(
            repo_docs(&reg, "Shape-City"),
            docs,
            "any spelling of the name"
        );
        let _ = fs::remove_dir_all(&checkout);
    }

    #[test]
    fn ensure_creates_once_and_then_leaves_it_alone() {
        let dir = std::env::temp_dir().join(format!(
            "agent-sheet-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        assert!(ensure(&dir, "demo", "lab/p/demo/README").unwrap());
        let path = sheet_path(&dir);
        // Whatever the agents put here must survive every later `notes board`.
        fs::write(
            &path,
            "# demo - agent board\n\n## Tasks\n- [ ] work in flight\n",
        )
        .unwrap();
        assert!(!ensure(&dir, "demo", "lab/p/demo/README").unwrap());
        assert!(
            fs::read_to_string(&path)
                .unwrap()
                .contains("work in flight"),
            "an existing sheet is never rewritten"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
