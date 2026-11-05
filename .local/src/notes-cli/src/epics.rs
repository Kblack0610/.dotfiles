//! The epic -> story -> subtask tree of one project, read from its rows.
//!
//! A row names its parent with `#of/<id>` ([`md::split_parent`]); an epic is a row typed
//! `epic(area): <outcome>`. The tree spans both lanes and every frozen version note: ids are
//! unique per project across all of them (`project_tasks::next_id`), and a story whose
//! subtasks were archived or released must not turn back into a leaf.
//!
//! Version totals ([`crate::projects::Progress`]) weigh leaves only, so a parent never counts
//! twice; an epic's own percent is its leaves' rollup across every version.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

use crate::md;
use crate::project_tasks;
use crate::projects::{self, fmt_version, parse_version, size_weight};
use crate::sheet::{self, V};

/// The deepest a row may sit: epic, story, subtask.
pub(crate) const MAX_DEPTH: usize = 3;

/// What each `#size/` weighs: the one scale every rollup and legend reads. `xl` is an epic's
/// appetite and belongs on epic rows only (doctor flags it elsewhere).
pub(crate) const WEIGHTS: &[(&str, u32)] = &[("xs", 1), ("s", 1), ("m", 3), ("l", 8), ("xl", 21)];

/// One `WEIGHTS` entry as `--stats --json` prints it, so a legend never hard-codes the scale.
#[derive(Debug, PartialEq, serde::Serialize)]
pub(crate) struct Weight {
    pub size: &'static str,
    pub weight: u32,
}

pub(crate) fn weights() -> Vec<Weight> {
    WEIGHTS
        .iter()
        .map(|&(size, weight)| Weight { size, weight })
        .collect()
}

/// The id a row's `#of/<id>` tag names, read before its marker comment.
pub(crate) fn parent_of(line: &str) -> Option<String> {
    let head = line.find("<!--").map_or(line, |i| &line[..i]);
    md::split_parent(head).1
}

/// Is this row an epic: typed `epic(area): <outcome>`.
pub(crate) fn is_epic(line: &str) -> bool {
    line.contains("epic(") && projects::row_type_area(line).is_some_and(|(t, _)| t == "epic")
}

#[derive(Debug)]
struct Node {
    id: Option<String>,
    parent: Option<String>,
    open: bool,
    dropped: bool,
    epic: bool,
    weight: u32,
    sized: bool,
    /// The release the row's tag names, if it carries one.
    target: Option<V>,
    /// The release the row belongs to: its note's, or the sheet's reading of its tag.
    version: Option<V>,
    /// An epic's title; empty on other rows, which nothing here shows.
    title: String,
    /// Where the row is, for a doctor line: `sheet line 12`.
    at: String,
}

/// One open epic's rollup over its leaves, in every version.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub(crate) struct EpicProgress {
    pub id: String,
    pub title: String,
    /// The release the epic is aimed at; empty when it spans releases.
    pub version: String,
    pub open: usize,
    pub done: usize,
    pub open_weight: u32,
    pub done_weight: u32,
    /// Open leaves with no `#size/`, each weighed at 1: how far the percent can be trusted.
    pub unsized_open: usize,
    /// No story yet: the epic is its own one leaf, weighed at its own size.
    pub childless: bool,
}

/// The tree of one project: every row with an id or a parent, and each parent's children.
#[derive(Debug, Default)]
pub(crate) struct Index {
    nodes: Vec<Node>,
    by_id: HashMap<String, usize>,
    /// Parent id -> its children that are not dropped (a dropped child is out of scope).
    kids: HashMap<String, Vec<usize>>,
}

impl Index {
    /// Read the tree of the project at `dir`, whose open version is `cur`: the human sheet and
    /// the agent board first, then their `versions/` notes newest first, so the live copy of a
    /// row (one carried, or listed in a note) is the one kept.
    ///
    /// Only the rows the tree needs are parsed: a row naming a parent, an epic, and a row some
    /// `#of/` names. A project with neither costs one substring scan per note.
    pub(crate) fn of(dir: &Path, cur: Option<V>) -> Index {
        let agent = projects::agent_dir(dir);
        let lanes = [(dir, false), (agent.as_path(), true)];
        // (text, the note's version or None for a live sheet, label)
        let mut texts: Vec<(String, Option<V>, String)> = Vec::new();
        for (lane, is_agent) in lanes {
            if let Some(t) =
                project_tasks::task_sheet(lane).and_then(|p| fs::read_to_string(p).ok())
            {
                let label = if is_agent { "agent board" } else { "sheet" };
                texts.push((t, None, label.to_string()));
            }
        }
        for (lane, is_agent) in lanes {
            let mut notes: Vec<(String, Option<V>, String)> = fs::read_dir(lane.join("versions"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().into_owned();
                    let v = parse_version(name.strip_suffix(".md")?)?;
                    let prefix = if is_agent {
                        "agent/versions/"
                    } else {
                        "versions/"
                    };
                    let t = fs::read_to_string(e.path()).ok()?;
                    Some((t, Some(v), format!("{prefix}{name}")))
                })
                .collect();
            notes.sort_by(|a, b| b.1.cmp(&a.1));
            texts.extend(notes);
        }
        let mut ix = Index::default();
        let named: HashSet<&str> = texts
            .iter()
            .flat_map(|(t, ..)| t.match_indices("#of/").map(move |(i, _)| &t[i + 4..]))
            .map(|rest| {
                rest.split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
                    .next()
                    .unwrap_or("")
            })
            .filter(|id| md::is_row_id(id))
            .collect();
        if named.is_empty() && !texts.iter().any(|(t, ..)| t.contains("epic(")) {
            return ix;
        }
        let wanted = |l: &str| {
            l.contains("#of/")
                || l.contains("epic(")
                || md::row_id(l).is_some_and(|id| named.contains(id.as_str()))
        };
        for (t, note, label) in &texts {
            let rows: Vec<(usize, &str)> = match note {
                None => md::section_numbered(t, sheet::TASKS),
                Some(_) => t.lines().enumerate().map(|(i, l)| (i + 1, l)).collect(),
            };
            for (n, l) in rows {
                if l.starts_with("- [") && wanted(l) {
                    let v = note.or_else(|| sheet::version_of(l, cur));
                    ix.add(l, v, note.is_none(), format!("{label} line {n}"));
                }
            }
        }
        for (i, n) in ix.nodes.iter().enumerate() {
            if let (Some(p), false) = (&n.parent, n.dropped) {
                ix.kids.entry(p.clone()).or_default().push(i);
            }
        }
        ix
    }

    /// Record one row. A row with no id can be nobody's parent, so it is kept only when it
    /// names one, and only from a live sheet: a note copy of an id-less row cannot be told
    /// from the live one.
    fn add(&mut self, line: &str, version: Option<V>, live: bool, at: String) {
        let id = md::row_id(line);
        let parent = parent_of(line);
        match &id {
            Some(id) if self.by_id.contains_key(id) => return,
            None if parent.is_none() || !live => return,
            _ => {}
        }
        let epic = is_epic(line);
        if let Some(id) = &id {
            self.by_id.insert(id.clone(), self.nodes.len());
        }
        self.nodes.push(Node {
            id,
            parent,
            open: md::is_open_task(line),
            dropped: md::is_dropped(line),
            epic,
            weight: size_weight(line),
            sized: project_tasks::size_tag(line).is_some(),
            target: sheet::target(line),
            version,
            title: if epic {
                projects::row_title(line)
            } else {
                String::new()
            },
            at,
        });
    }

    fn node(&self, id: &str) -> Option<&Node> {
        self.by_id.get(id).map(|&i| &self.nodes[i])
    }

    fn children(&self, id: &str) -> &[usize] {
        self.kids.get(id).map_or(&[], Vec::as_slice)
    }

    /// Does `id` have a child that is not dropped: a row whose weight is its children's.
    pub(crate) fn is_parent(&self, id: &str) -> bool {
        self.kids.contains_key(id)
    }

    /// Whether a row counts toward its version's totals: only a leaf does. A parent weighs
    /// what its children weigh, and an untagged epic is scope not yet aimed at any release.
    pub(crate) fn counts(&self, line: &str) -> bool {
        if md::row_id(line).is_some_and(|id| self.is_parent(&id)) {
            return false;
        }
        !is_epic(line) || sheet::target(line).is_some()
    }

    /// Where each open child of `id` is, for a refusal to close it.
    pub(crate) fn open_children(&self, id: &str) -> Vec<String> {
        self.children(id)
            .iter()
            .map(|&i| &self.nodes[i])
            .filter(|n| n.open)
            .map(|n| match &n.id {
                Some(c) => format!("{c} ({})", n.at),
                None => n.at.clone(),
            })
            .collect()
    }

    /// The leaves under node `i`, walked at most [`MAX_DEPTH`] levels and never twice, so a
    /// cycle or an over-deep chain cannot hang a read (doctor names both).
    fn leaves(&self, i: usize) -> Vec<usize> {
        let mut out = Vec::new();
        let mut seen = HashSet::from([i]);
        let mut stack = vec![(i, 0)];
        while let Some((j, depth)) = stack.pop() {
            let kids = self.nodes[j]
                .id
                .as_deref()
                .map_or(&[][..], |id| self.children(id));
            if kids.is_empty() || depth > MAX_DEPTH {
                out.push(j);
                continue;
            }
            for &k in kids {
                if seen.insert(k) {
                    stack.push((k, depth + 1));
                }
            }
        }
        out
    }

    /// Does following `#of/` up from node `i` come back to a row already passed.
    fn loops(&self, i: usize) -> bool {
        let mut j = i;
        let mut seen = HashSet::from([i]);
        while let Some(&k) = self.nodes[j]
            .parent
            .as_deref()
            .and_then(|p| self.by_id.get(p))
        {
            if !seen.insert(k) {
                return true;
            }
            j = k;
        }
        false
    }

    fn rollup(&self, i: usize) -> EpicProgress {
        let e = &self.nodes[i];
        let mut p = EpicProgress {
            id: e.id.clone().unwrap_or_default(),
            title: e.title.clone(),
            version: e.target.map(fmt_version).unwrap_or_default(),
            childless: !e.id.as_deref().is_some_and(|id| self.is_parent(id)),
            ..EpicProgress::default()
        };
        for j in self.leaves(i) {
            let n = &self.nodes[j];
            if n.open {
                p.open += 1;
                p.open_weight += n.weight;
                if !n.sized {
                    p.unsized_open += 1;
                }
            } else {
                p.done += 1;
                p.done_weight += n.weight;
            }
        }
        p
    }

    fn open_epics(&self) -> impl Iterator<Item = usize> + '_ {
        (0..self.nodes.len()).filter(|&i| self.nodes[i].epic && self.nodes[i].open)
    }

    /// Every open epic with its rollup, in sheet order.
    pub(crate) fn epics(&self) -> Vec<EpicProgress> {
        self.open_epics().map(|i| self.rollup(i)).collect()
    }

    /// The open epics with work in version `v`: a leaf of theirs in it, or, for an epic with
    /// no story yet, its own tag naming it.
    pub(crate) fn epics_in(&self, v: Option<V>) -> Vec<EpicProgress> {
        self.open_epics()
            .filter(|&i| {
                self.leaves(i).into_iter().any(|j| {
                    let n = &self.nodes[j];
                    !n.dropped
                        && if j == i {
                            n.target == v
                        } else {
                            n.version == v
                        }
                })
            })
            .map(|i| self.rollup(i))
            .collect()
    }

    /// What is wrong with the tree, one line per open row: a parent that is not a row here,
    /// one closed under an open child, a loop, a chain past [`MAX_DEPTH`], and an epic with a
    /// parent. Where an epic or `#size/xl` may sit is row grammar (`projects::row_findings`).
    pub(crate) fn findings(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (i, n) in self.nodes.iter().enumerate() {
            if !n.open {
                continue;
            }
            let at = &n.at;
            let Some(p) = n.parent.as_deref() else {
                continue;
            };
            if n.epic {
                out.push(format!(
                    "{at}: an epic takes no #of/ (it is the top of its tree)"
                ));
            }
            match self.node(p) {
                None => out.push(format!("{at}: #of/{p} names no row in this project")),
                Some(parent) if !parent.open => out.push(format!(
                    "{at}: open under {p}, which is {}",
                    if parent.dropped { "dropped" } else { "done" }
                )),
                Some(_) => {}
            }
            if self.loops(i) {
                out.push(format!("{at}: #of/ loops back to this row"));
            } else if self.depth(i) > MAX_DEPTH {
                out.push(format!(
                    "{at}: {} levels deep (epic, story, subtask is the most)",
                    self.depth(i)
                ));
            }
        }
        out
    }

    /// How many levels node `i` sits at: 1 for a row with no parent here. Only called once
    /// [`Index::loops`] has ruled out a cycle.
    fn depth(&self, i: usize) -> usize {
        let mut d = 1;
        let mut j = i;
        while let Some(&k) = self.nodes[j]
            .parent
            .as_deref()
            .and_then(|p| self.by_id.get(p))
        {
            d += 1;
            j = k;
        }
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const V14: Option<V> = Some((1, 4, 0));
    const V15: Option<V> = Some((1, 5, 0));

    /// A project dir under the temp dir holding `files` (path relative to it, content).
    fn project(tag: &str, files: &[(&str, &str)]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("notes-epics-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        for (rel, body) in files {
            let path = dir.join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, body).unwrap();
        }
        dir
    }

    fn today() -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(2026, 11, 5).unwrap()
    }

    const HUMAN: &str = "\
# demo
Version: v1.4.0 #alpha

## Tasks
- [ ] epic(rollup): one estimate per release #size/xl <!-- id:dm-1 -->
- [ ] feat(rollup): the story #size/l #of/dm-1 <!-- id:dm-2 -->
";

    #[test]
    fn a_parent_weighs_its_children_and_adds_nothing_itself() {
        // NEGATIVE CONTROL for leaves-only: before epics, the story (l 8) and the untagged
        // epic (xl) were counted beside the subtasks, so the open weight read 3 + 8 + 21.
        let dir = project(
            "sum",
            &[
                ("README.md", HUMAN),
                (
                    "agent/README.md",
                    "# demo\n\n## Tasks\n\
                     - [ ] feat(rollup): first #size/m #of/dm-2 <!-- id:dm-3 -->\n\
                     - [x] feat(rollup): second #size/s #of/dm-2 <!-- id:dm-4 done:2026-11-05 pr:7 -->\n",
                ),
            ],
        );
        let ix = Index::of(&dir, V14);
        let p = projects::progress_of(&dir, V14, V14, &ix, today());
        assert_eq!((p.open, p.open_weight), (1, 3), "only the open subtask");
        assert_eq!((p.done, p.done_weight, p.closed_weight_28d), (1, 1, 1));
        assert_eq!(
            ix.epics(),
            vec![EpicProgress {
                id: "dm-1".into(),
                title: "one estimate per release".into(),
                open: 1,
                done: 1,
                open_weight: 3,
                done_weight: 1,
                ..EpicProgress::default()
            }]
        );
        assert_eq!(ix.open_children("dm-2"), vec!["dm-3 (agent board line 4)"]);
        assert!(ix.open_children("dm-3").is_empty(), "a leaf closes freely");
    }

    #[test]
    fn a_story_closing_after_its_subtasks_adds_nothing_to_the_closes() {
        // One subtask is already archived to the version note: the story must stay a parent
        // (the index reads every note), or it would turn back into an l-sized leaf.
        let dir = project(
            "close",
            &[
                (
                    "README.md",
                    "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                     - [x] feat(rollup): the story #size/l <!-- id:dm-2 done:2026-11-05 pr:9 -->\n",
                ),
                (
                    "agent/README.md",
                    "# demo\n\n## Tasks\n\
                     - [x] feat(rollup): first #size/m #of/dm-2 <!-- id:dm-3 done:2026-11-04 pr:7 -->\n",
                ),
                (
                    "agent/versions/v1.4.0.md",
                    "# demo v1.4.0\n\n## Done rows\n\
                     - [x] feat(rollup): second #size/s #of/dm-2 <!-- id:dm-4 done:2026-11-03 pr:6 -->\n",
                ),
            ],
        );
        let ix = Index::of(&dir, V14);
        let p = projects::progress_of(&dir, V14, V14, &ix, today());
        assert_eq!((p.done, p.done_weight), (2, 4));
        assert_eq!((p.closed_28d, p.closed_weight_28d), (2, 4), "the story's l is not a close");
    }

    #[test]
    fn a_child_aimed_at_a_later_release_counts_only_there() {
        let dir = project(
            "later",
            &[
                ("README.md", HUMAN),
                (
                    "agent/README.md",
                    "# demo\n\n## Tasks\n\
                     - [ ] feat(rollup): now #size/s #of/dm-2 <!-- id:dm-3 -->\n\
                     - [ ] feat(rollup): later #v1.5.0 #size/m #of/dm-2 <!-- id:dm-4 -->\n\
                     - [ ] feat(other): plain #size/s <!-- id:dm-5 -->\n",
                ),
            ],
        );
        let ix = Index::of(&dir, V14);
        let now = projects::progress_of(&dir, V14, V14, &ix, today());
        let later = projects::progress_of(&dir, V14, V15, &ix, today());
        assert_eq!((now.open, now.open_weight), (2, 2));
        assert_eq!((later.open, later.open_weight), (1, 3));
        let ids = |v| ix.epics_in(v).into_iter().map(|e| e.id).collect::<Vec<_>>();
        assert_eq!(ids(V14), vec!["dm-1"]);
        assert_eq!(ids(V15), vec!["dm-1"], "the epic is listed in every release it has work in");
        assert_eq!(ids(Some((1, 6, 0))), Vec::<String>::new());
    }

    #[test]
    fn a_childless_epic_counts_only_when_it_is_aimed_at_a_release() {
        let dir = project(
            "bare",
            &[(
                "README.md",
                "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                 - [ ] epic(spread): spans releases #size/xl <!-- id:dm-1 -->\n\
                 - [ ] epic(soon): due next #v1.5.0 #size/xl <!-- id:dm-2 -->\n",
            )],
        );
        let ix = Index::of(&dir, V14);
        let now = projects::progress_of(&dir, V14, V14, &ix, today());
        let next = projects::progress_of(&dir, V14, V15, &ix, today());
        assert_eq!((now.open, now.open_weight), (0, 0), "an untagged epic is in no version");
        assert_eq!((next.open, next.open_weight), (1, 21), "a tagged one is its own leaf");
        let e = ix.epics();
        assert!(e.iter().all(|e| e.childless && e.open_weight == 21));
        assert_eq!(e[1].version, "v1.5.0");
        let ids: Vec<String> = ix.epics_in(V15).into_iter().map(|e| e.id).collect();
        assert_eq!(ids, vec!["dm-2"]);
    }

    #[test]
    fn a_broken_tree_is_named_by_doctor() {
        let dir = project(
            "doctor",
            &[(
                "README.md",
                "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                 - [ ] feat(a): dangling #of/dm-99 <!-- id:dm-1 -->\n\
                 - [x] feat(b): closed story <!-- id:dm-2 done:2026-11-05 pr:1 -->\n\
                 - [ ] feat(b): open under it #of/dm-2 <!-- id:dm-3 -->\n\
                 - [ ] epic(c): an epic #of/dm-5 <!-- id:dm-4 -->\n\
                 - [ ] epic(c): top <!-- id:dm-5 -->\n\
                 - [ ] feat(d): loop one #of/dm-7 <!-- id:dm-6 -->\n\
                 - [ ] feat(d): loop two #of/dm-6 <!-- id:dm-7 -->\n\
                 - [ ] feat(e): story #of/dm-5 <!-- id:dm-8 -->\n\
                 - [ ] feat(e): subtask #of/dm-8 <!-- id:dm-9 -->\n\
                 - [ ] feat(e): too deep #of/dm-9 <!-- id:dm-10 -->\n\
                 - [ ] feat(f): fine #of/dm-8 <!-- id:dm-11 -->\n",
            )],
        );
        let f = Index::of(&dir, V14).findings();
        let want = [
            "sheet line 5: #of/dm-99 names no row in this project",
            "sheet line 7: open under dm-2, which is done",
            "sheet line 8: an epic takes no #of/ (it is the top of its tree)",
            "sheet line 10: #of/ loops back to this row",
            "sheet line 11: #of/ loops back to this row",
            "sheet line 14: 4 levels deep (epic, story, subtask is the most)",
        ];
        assert_eq!(f, want);
    }

    #[test]
    fn row_grammar_keeps_epics_on_the_sheet_and_xl_on_epics() {
        let board = "## Tasks\n\
                     - [ ] epic(a): on the board <!-- id:dm-1 -->\n\
                     - [ ] feat(a): huge #size/xl <!-- id:dm-2 -->\n\
                     - [ ] epic(a): sized right #size/xl <!-- id:dm-3 -->\n";
        let f = projects::row_findings(board, true);
        assert!(f.contains(&"line 2: an epic belongs on the human sheet, not the agent board".into()));
        assert!(f.contains(&"line 3: #size/xl is an epic's size; split the row or size it l".into()));
        assert!(!f.iter().any(|l| l.starts_with("line 4: #size/xl")));
        assert!(!projects::row_findings(board, false)
            .iter()
            .any(|l| l.contains("agent board")));
    }

    #[test]
    fn the_parent_tag_is_a_link_not_text() {
        let l = "- [ ] feat(a): do it #of/ar-12 #size/m <!-- id:ar-13 -->";
        assert_eq!(parent_of(l).as_deref(), Some("ar-12"));
        assert_eq!(md::task_text(l), md::task_text("- [ ] feat(a): do it #size/m"));
        assert_eq!(parent_of("- [ ] feat(a): #of/not-an-id"), None);
        assert_eq!(size_weight("- [ ] epic(a): big #size/xl"), 21);
        assert_eq!(size_weight("- [ ] feat(a): tiny #size/xs"), 1);
        assert_eq!(size_weight("- [ ] feat(a): odd #size/huge"), 1);
        assert!(is_epic("- [ ] epic(a): outcome #high"));
        assert!(!is_epic("- [ ] feat(epic): not one"));
    }
}
