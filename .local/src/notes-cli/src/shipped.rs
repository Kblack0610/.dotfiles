//! Which release a closed row shipped in: the first tag of the project's release family that
//! contains the row's `commit:`. A tag closing a version (`notes projects --release --tag`, with
//! `--repo` and `--family`, which `notes-roll` passes) freezes each closed row under that tag,
//! never under whatever version was open when the row closed (`stages.md`, "Versions").

use crate::md;
use crate::sheet::V;
use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::ops::Range;
use std::path::{Path, PathBuf};

/// A project's checkout and its release tags, `(version, tag name)` lowest first.
pub(crate) struct Family {
    repo: PathBuf,
    tags: Vec<(V, String)>,
}

/// Where a commit shipped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Shipped {
    /// The lowest release tag of the family that contains it.
    In(V),
    /// In the repo, but no release tag contains it yet.
    Untagged,
    /// Not a commit of this repo: a row whose PR landed in another one.
    Elsewhere,
}

impl Family {
    /// Read `file`: one `vX.Y.Z<TAB><tag name>` line per release tag of the family.
    pub(crate) fn load(repo: &Path, file: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(file)
            .with_context(|| format!("--family {}", file.display()))?;
        let mut tags: Vec<(V, String)> = text
            .lines()
            .filter_map(|l| {
                let (v, name) = l.split_once('\t')?;
                Some((
                    crate::projects::parse_version(v.trim())?,
                    name.trim().to_string(),
                ))
            })
            .collect();
        tags.sort();
        Ok(Self {
            repo: repo.to_path_buf(),
            tags,
        })
    }

    pub(crate) fn has(&self, v: V) -> bool {
        self.tags.iter().any(|(t, _)| *t == v)
    }

    /// The first release tag containing `commit`. `git tag --contains` fails on a commit the
    /// repo does not have, which is what a row of another repo names.
    pub(crate) fn shipped(&self, commit: &str) -> Shipped {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args(["tag", "--contains", commit])
            .stderr(std::process::Stdio::null())
            .output();
        let Some(out) = out.ok().filter(|o| o.status.success()) else {
            return Shipped::Elsewhere;
        };
        let names = String::from_utf8_lossy(&out.stdout);
        let names: Vec<&str> = names.lines().map(str::trim).collect();
        self.tags
            .iter()
            .find(|(_, n)| names.contains(&n.as_str()))
            .map_or(Shipped::Untagged, |(v, _)| Shipped::In(*v))
    }
}

/// The closed rows of one lane after [`sort`]: `content` without the rows an earlier tag
/// shipped, those rows by the tag, and how many were aimed at the next version to wait for theirs.
#[derive(Debug, Default)]
pub(crate) struct Sorted {
    pub(crate) content: String,
    pub(crate) earlier: BTreeMap<V, Vec<Vec<String>>>,
    pub(crate) waiting: usize,
}

/// Sort the closed rows at `ranges` of `content` (each a row and the lines indented under it)
/// for the release `tag`, by where each row's `commit:` shipped:
/// - in `tag`, in another repo, or with no commit: it freezes with `tag`, as before;
/// - in an earlier tag that has a frozen note (`has_note`): it is cut out and returned, to go
///   to that tag's note. An earlier tag with no note is history nobody recorded, so it stays;
/// - in a later tag or in none yet: it is retagged `#<next>` and waits for its own tag.
pub(crate) fn sort(
    content: &str,
    ranges: &[Range<usize>],
    tag: V,
    next: V,
    shipped: impl Fn(&str) -> Shipped,
    has_note: impl Fn(V) -> bool,
) -> Sorted {
    let mut lines: Vec<String> = content.lines().map(str::to_string).collect();
    let mut out = Sorted::default();
    let mut cut: Vec<Range<usize>> = Vec::new();
    for r in ranges {
        let Some(commit) = commit_of(&lines[r.start]) else {
            continue;
        };
        match shipped(&commit) {
            Shipped::In(v) if v < tag && has_note(v) => {
                out.earlier
                    .entry(v)
                    .or_default()
                    .push(lines[r.clone()].to_vec());
                cut.push(r.clone());
            }
            Shipped::In(v) if v > tag => out.waiting += aim(&mut lines[r.start], next),
            Shipped::Untagged => out.waiting += aim(&mut lines[r.start], next),
            _ => {}
        }
    }
    let kept: Vec<&str> = lines
        .iter()
        .enumerate()
        .filter(|(i, _)| !cut.iter().any(|r| r.contains(i)))
        .map(|(_, l)| l.as_str())
        .collect();
    out.content = if kept.len() == lines.len() && out.waiting == 0 {
        content.to_string()
    } else {
        format!("{}\n", kept.join("\n"))
    };
    out
}

fn aim(line: &mut String, next: V) -> usize {
    *line = crate::project_sweep::retag(line.trim_end(), next, true).0;
    1
}

/// The `commit:<sha>` a closed row's marker carries (agent-land's proof stamp).
fn commit_of(line: &str) -> Option<String> {
    md::marker_of(line)?
        .split_whitespace()
        .find_map(|t| t.strip_prefix("commit:"))
        .map(|c| c.trim_end_matches([')', ',', ';', ':', '.']).to_string())
        .filter(|c| !c.is_empty())
}

/// A scratch repo at `root` with three commits: the first tagged `app-v1.0.0` (and `v9.0.0`,
/// another family's), the second `app-v1.1.0`, the third untagged; and `root/family.tsv`
/// naming the `app-v*` family. Returns the three SHAs.
#[cfg(test)]
pub(crate) fn test_repo(root: &Path) -> [String; 3] {
    let _ = std::fs::remove_dir_all(root);
    std::fs::create_dir_all(root).unwrap();
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"])
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {out:?}");
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    git(&["init", "-q"]);
    let commit = |m: &str| {
        git(&["commit", "-q", "--allow-empty", "-m", m]);
        git(&["rev-parse", "HEAD"])
    };
    let one = commit("one");
    git(&["tag", "app-v1.0.0"]);
    git(&["tag", "v9.0.0"]);
    let two = commit("two");
    git(&["tag", "app-v1.1.0"]);
    let three = commit("three");
    std::fs::write(
        root.join("family.tsv"),
        "v1.1.0\tapp-v1.1.0\nv1.0.0\tapp-v1.0.0\n",
    )
    .unwrap();
    [one, two, three]
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "# demo\nVersion: v1.2.0\n\n## Tasks\n\
        - [x] feat(a): in this tag <!-- id:a commit:aaa -->\n\
        - [x] feat(b): an earlier tag <!-- id:b commit:bbb -->\n  - [x] its child\n\
        - [x] feat(c): no tag yet <!-- id:c commit:ccc -->\n\
        - [x] feat(d): another repo <!-- id:d commit:ddd -->\n\
        - [x] feat(e): no commit <!-- id:e pr:5 -->\n\
        - [x] feat(f): a tag with no note <!-- id:f commit:fff -->\n";

    fn where_(c: &str) -> Shipped {
        match c {
            "aaa" => Shipped::In((1, 2, 0)),
            "bbb" => Shipped::In((1, 1, 0)),
            "fff" => Shipped::In((1, 0, 0)),
            "ccc" => Shipped::Untagged,
            _ => Shipped::Elsewhere,
        }
    }

    #[test]
    fn a_row_goes_to_the_first_tag_containing_its_commit() {
        let ranges = crate::project_tasks::done_rows(SHEET);
        let s = sort(SHEET, &ranges, (1, 2, 0), (1, 2, 1), where_, |v| {
            v == (1, 1, 0)
        });
        // The earlier tag takes the row with its child, and the sheet loses both.
        assert_eq!(
            s.earlier.get(&(1, 1, 0)).unwrap(),
            &vec![vec![
                "- [x] feat(b): an earlier tag <!-- id:b commit:bbb -->".to_string(),
                "  - [x] its child".to_string()
            ]]
        );
        assert!(!s.content.contains("feat(b)"), "{}", s.content);
        assert!(!s.content.contains("its child"), "{}", s.content);
        // A merge no tag holds yet waits for the next version's tag.
        assert_eq!(s.waiting, 1);
        assert!(
            s.content.contains("feat(c): no tag yet #v1.2.1 <!--"),
            "{}",
            s.content
        );
        // NEGATIVE CONTROL: the rows this tag shipped, another repo's, one with no commit and
        // one whose tag has no note are left exactly as they were.
        for row in ["feat(a)", "feat(d)", "feat(e)", "feat(f)"] {
            let l = s.content.lines().find(|l| l.contains(row)).unwrap();
            assert!(SHEET.contains(l), "{row} changed: {l}");
        }
    }

    #[test]
    fn nothing_to_sort_leaves_the_content_byte_for_byte() {
        let sheet = "# demo\n## Tasks\n- [x] a <!-- commit:aaa -->";
        let ranges = crate::project_tasks::done_rows(sheet);
        let s = sort(sheet, &ranges, (1, 2, 0), (1, 2, 1), where_, |_| true);
        assert_eq!(s.content, sheet);
        assert!(s.earlier.is_empty());
    }

    #[test]
    fn the_family_reads_git_containment() {
        let root = std::env::temp_dir().join(format!("shipped-{}", std::process::id()));
        let [one, two, three] = test_repo(&root);
        let f = Family::load(&root, &root.join("family.tsv")).unwrap();
        assert!(f.has((1, 1, 0)) && !f.has((9, 0, 0)));
        assert_eq!(f.shipped(&one), Shipped::In((1, 0, 0)));
        assert_eq!(f.shipped(&two[..12]), Shipped::In((1, 1, 0)));
        assert_eq!(f.shipped(&three), Shipped::Untagged);
        // NEGATIVE CONTROL: a commit this repo does not have is another repo's.
        assert_eq!(f.shipped("0123456789ab"), Shipped::Elsewhere);
        let _ = std::fs::remove_dir_all(&root);
    }
}
