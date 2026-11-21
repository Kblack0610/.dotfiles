//! The home artifact store, reached through the lister a repo declares as `artifactStore` on its
//! tracker (`project_map::Registry::artifact_store`): a script path inside the repo's clone, run
//! from that clone so the script is the one at hand and never one this tree guesses. The run page's
//! Artifacts section lists a build run's artifacts with `ls`; the Tests tab (`junit`) fetches a test
//! run's results with `get`. Both go through a `Runner`, so a test hands it canned answers.

use std::path::{Path, PathBuf};

use project_map::Registry;

use crate::session_actions::Runner;

/// The clone of `repo` (a forge slug, `owner/repo`) on this machine.
pub fn clone_of(reg: &Registry, repo: &str) -> Result<PathBuf, String> {
    // `paths` maps a checkout to a project key, while a run names its forge slug (`owner/repo`).
    // Only a key whose own slugs name the run's repo counts, so another owner's repo of the same
    // name never reads this machine's clone.
    reg.lookup(repo)
        .filter(|k| reg.repos(k).iter().any(|s| s.eq_ignore_ascii_case(repo)))
        .and_then(|k| reg.checkout(k))
        .ok_or_else(|| format!("no clone of {repo} on this machine"))
}

/// The lister `repo` declares, as a path in its clone: None when it declares none, an error when
/// the declared path leaves the clone or there is no clone to run it from.
pub fn lister(reg: &Registry, repo: &str) -> Option<Result<PathBuf, String>> {
    let script = reg.artifact_store(repo)?;
    let rel = Path::new(&script);
    if rel.is_absolute() || rel.components().any(|c| c.as_os_str() == "..") {
        return Some(Err(format!(
            "artifactStore {script}: a path inside the clone"
        )));
    }
    Some(clone_of(reg, repo).map(|c| c.join(rel)))
}

/// One live artifact of a run, as `ls` prints it.
#[derive(Debug, Clone, PartialEq)]
pub struct Listed {
    pub name: String,
    pub expires: String,
    pub size: u64,
}

fn call(repo: &str, script: &Path, args: &[&str]) -> Vec<String> {
    let mut a = vec![
        "env".to_string(),
        format!("GITHUB_REPOSITORY={repo}"),
        "python3".to_string(),
        script.to_string_lossy().into_owned(),
    ];
    a.extend(args.iter().map(|s| s.to_string()));
    a
}

/// Every live artifact of run `id` of `repo`, from `<lister> ls "" --run <id>` (lines
/// `<name> <run> <expires> <bytes>`). An answer with lines but none in that shape is an error, so a
/// lister in a new format is named rather than read as a run with nothing.
pub fn ls(
    runner: &dyn Runner,
    repo: &str,
    script: &Path,
    prefix: &str,
    id: u64,
) -> Result<Vec<Listed>, String> {
    let out = runner.run(&call(
        repo,
        script,
        &["ls", prefix, "--run", &id.to_string()],
    ))?;
    let mut items = vec![];
    let mut unread = 0;
    for l in out.lines().filter(|l| !l.trim().is_empty()) {
        let f: Vec<&str> = l.split_whitespace().collect();
        match f[..] {
            [name, _run, expires, size] if size.parse::<u64>().is_ok() => items.push(Listed {
                name: name.into(),
                size: size.parse().unwrap_or_default(),
                expires: expires.into(),
            }),
            _ => unread += 1,
        }
    }
    if unread > 0 && items.is_empty() {
        return Err(format!(
            "{unread} lines of the lister's answer are not `<name> <run> <expires> <bytes>`"
        ));
    }
    Ok(items)
}

/// Extracts artifact `name` of run `id` into `dir` (`<lister> get <name> --run <id> --dir <dir>`):
/// the artifact's files land at the top of `dir`, the way `gh run download` lays out one artifact.
pub fn get(
    runner: &dyn Runner,
    repo: &str,
    script: &Path,
    name: &str,
    id: u64,
    dir: &Path,
) -> Result<(), String> {
    runner
        .run(&call(
            repo,
            script,
            &[
                "get",
                name,
                "--run",
                &id.to_string(),
                "--dir",
                &dir.to_string_lossy(),
            ],
        ))
        .map(|_| ())
}
