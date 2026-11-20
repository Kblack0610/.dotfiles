//! Retired names: hosts that left the home inventory and commands that were deleted.
//!
//! The list is data, written by the `knowledge-retired` script as a TSV of `kind name why`
//! (kind is `host` or `command`, why says where it went, such as "left the home-config
//! inventory"). This module only matches it. A knowledge line that names a retired thing reads
//! as a live claim unless the same line says it is gone, so a page retires a fact by saying so
//! or by dropping it, never by leaving it as written. `lint` counts those lines on every page;
//! `apply` refuses an op that adds one.

use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// A line with any of these words tells the history of the thing, not its current state. Only
/// past or state forms: "replace" and "remove" are live instructions ("run x to replace y").
const GONE_WORDS: [&str; 20] = [
    "sold",
    "retire",
    "retired",
    "retiring",
    "removed",
    "replaced",
    "replacement",
    "decommissioned",
    "gone",
    "former",
    "formerly",
    "was",
    "were",
    "archived",
    "deprecated",
    "dropped",
    "deleted",
    "renamed",
    "superseded",
    "dead",
];
/// Two-word forms of the same.
const GONE_PHRASES: [&str; 2] = ["no longer", "used to"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Host,
    Command,
}

pub struct Retired {
    pub kind: Kind,
    pub name: String,
    pub why: String,
    /// a host's name as lowercase words, so `mac-studio` matches "Mac Studio"
    words: Vec<String>,
}

#[derive(Default)]
pub struct List(Vec<Retired>);

pub struct Hit<'a> {
    /// 1-based
    pub line: usize,
    pub text: String,
    pub retired: &'a Retired,
}

fn words(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// The list at `path`; no path is an empty list (nothing is checked). A path that cannot be read
/// or parsed is an error, never an empty list, so a lost list cannot read as "nothing retired".
pub fn load(path: Option<&Path>) -> Result<List> {
    let Some(path) = path else {
        return Ok(List::default());
    };
    let raw = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    parse(&raw).with_context(|| format!("parsing {}", path.display()))
}

pub fn parse(raw: &str) -> Result<List> {
    let mut out = Vec::new();
    for (i, line) in raw.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let mut f = line.splitn(3, '\t');
        let (Some(kind), Some(name), why) = (f.next(), f.next(), f.next()) else {
            bail!("line {}: want `kind<TAB>name<TAB>why`", i + 1);
        };
        let kind = match kind {
            "host" => Kind::Host,
            "command" => Kind::Command,
            k => bail!("line {}: kind `{k}` is not host or command", i + 1),
        };
        let name = name.trim().to_string();
        let w = words(&name);
        if w.is_empty() {
            bail!("line {}: an empty name", i + 1);
        }
        out.push(Retired {
            kind,
            name,
            why: why.unwrap_or("is retired").trim().to_string(),
            words: w,
        });
    }
    Ok(List(out))
}

impl List {
    /// Every line of `content` that names a retired thing as if it were live. A host counts
    /// anywhere on the line; a command only where it is run: the first word of an inline code
    /// span or of a line inside a fenced block. The frontmatter `sources:` line holds paths,
    /// not claims, so it never counts.
    pub fn stale<'a>(&'a self, content: &str) -> Vec<Hit<'a>> {
        let mut out = Vec::new();
        if self.0.is_empty() {
            return out;
        }
        let mut fenced = false;
        let mut in_fm = content.starts_with("---\n");
        for (i, line) in content.lines().enumerate() {
            let t = line.trim_start();
            if in_fm {
                if i > 0 && line == "---" {
                    in_fm = false;
                }
                if t.starts_with("sources:") {
                    continue;
                }
            }
            if t.starts_with("```") {
                fenced = !fenced;
                continue;
            }
            let lw = words(line);
            if gone(&lw) {
                continue;
            }
            let run: Vec<&str> = if fenced {
                first_word(t).into_iter().collect()
            } else {
                code_spans(line).filter_map(first_word).collect()
            };
            for r in &self.0 {
                let named = match r.kind {
                    Kind::Host => lw.windows(r.words.len()).any(|w| w == r.words.as_slice()),
                    Kind::Command => run.contains(&r.name.as_str()),
                };
                if named {
                    out.push(Hit {
                        line: i + 1,
                        text: line.trim().to_string(),
                        retired: r,
                    });
                }
            }
        }
        out
    }

    /// The hits in `new` beyond those already in `old`: what a write would add. Counted per (line,
    /// name), so a copy of a stale line the page had is added too; a reworded one is new.
    pub fn added<'a>(&'a self, old: &str, new: &str) -> Vec<Hit<'a>> {
        let mut before: HashMap<(String, &str), usize> = HashMap::new();
        for h in self.stale(old) {
            *before.entry((h.text, h.retired.name.as_str())).or_default() += 1;
        }
        self.stale(new)
            .into_iter()
            .filter(
                |h| match before.get_mut(&(h.text.clone(), h.retired.name.as_str())) {
                    Some(n) if *n > 0 => {
                        *n -= 1;
                        false
                    }
                    _ => true,
                },
            )
            .collect()
    }
}

fn gone(line_words: &[String]) -> bool {
    line_words.iter().any(|w| GONE_WORDS.contains(&w.as_str()))
        || GONE_PHRASES.iter().any(|p| {
            let pw: Vec<&str> = p.split(' ').collect();
            line_words
                .windows(pw.len())
                .any(|w| w.iter().map(String::as_str).eq(pw.iter().copied()))
        })
}

fn first_word(s: &str) -> Option<&str> {
    s.trim_start_matches("$ ").split_whitespace().next()
}

/// The text inside each pair of single backticks on a line. A double-backtick span and a
/// command behind a prefix (`sudo x`, `./x`) are not matched: a miss in the count, never a false
/// alarm.
fn code_spans(line: &str) -> impl Iterator<Item = &str> {
    line.split('`').skip(1).step_by(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> List {
        parse("# retired\nhost\tmac-studio\tleft the home-config inventory\ncommand\twave-start\twas deleted from .local/bin\n").unwrap()
    }

    fn names(l: &List, content: &str) -> Vec<(usize, String)> {
        l.stale(content)
            .into_iter()
            .map(|h| (h.line, h.retired.name.clone()))
            .collect()
    }

    #[test]
    fn a_host_counts_in_any_spelling_and_a_line_that_says_it_is_gone_does_not() {
        let l = list();
        let page = "MLX runs on the Mac Studio.\nmac-studio slots are withheld.\nThe Mac Studio was sold on 2026-11-10.\nIt is no longer a host: mac-studio.\nThe mac-mini is the agent machine.\n";
        assert_eq!(
            names(&l, page),
            vec![(1, "mac-studio".into()), (2, "mac-studio".into())]
        );
    }

    #[test]
    fn a_command_counts_only_where_it_is_run() {
        let l = list();
        let page = "Run `wave-start --all` each morning.\nThe wave-start idea came from waves.\n```bash\nwave-start x\necho wave-start\n```\n`wave-start` was deleted in #1200.\n";
        assert_eq!(
            names(&l, page),
            vec![(1, "wave-start".into()), (4, "wave-start".into())]
        );
    }

    #[test]
    fn frontmatter_sources_are_paths_not_claims() {
        let l = list();
        let page = "---\ntitle: Selling\nsources: [journal/refs/2026-11-09/mac-studio-listing.md]\nsummary: the Mac Studio listing\n---\n";
        assert_eq!(names(&l, page), vec![(4, "mac-studio".into())]);
    }

    #[test]
    fn added_ignores_a_stale_line_the_page_already_had() {
        let l = list();
        let old = "MLX runs on the Mac Studio.\n";
        assert!(l
            .added(old, "MLX runs on the Mac Studio.\nA new fact.\n")
            .is_empty());
        let new = l.added(
            old,
            "MLX runs on the Mac Studio.\nThe judge calls the Mac Studio.\n",
        );
        assert_eq!(new.len(), 1);
        assert_eq!(new[0].line, 2);
        let copied = l.added(
            old,
            "MLX runs on the Mac Studio.\nMLX runs on the Mac Studio.\n",
        );
        assert_eq!(
            copied.len(),
            1,
            "a second copy of a stale line is an addition"
        );
    }

    #[test]
    fn a_malformed_list_is_an_error_not_an_empty_one() {
        assert!(parse("host mac-studio\n").is_err());
        assert!(parse("vm\tx\twhy\n").is_err());
        assert!(parse("\n# only a comment\n").unwrap().0.is_empty());
    }
}
