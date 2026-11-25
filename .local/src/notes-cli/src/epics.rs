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
use crate::projects::{self, fmt_version};
use crate::sheet::{self, V};

/// The deepest a row may sit: epic, story, subtask.
pub(crate) const MAX_DEPTH: usize = 3;

/// What each `#size/` weighs: the one scale every rollup and legend reads. `xl` is an epic's
/// appetite and belongs on epic rows only (doctor flags it elsewhere).
pub(crate) const WEIGHTS: &[(&str, u32)] = &[("xs", 1), ("s", 1), ("m", 3), ("l", 8), ("xl", 21)];

/// The `#pts/<n>` scale: a row's effort estimate, and the `#size/` band each count falls in.
/// Points are the source; the size is derived from them (`ptask tag --add pts/<n>` rewrites
/// it), so a row's two never disagree. What each count means: `agentctl-inbox-triage`
/// the size rubric (`~/.config/inbox-size/prompt.md`), the one rubric the scoring pass and a filing session read. It stops at 13:
/// an epic's appetite is `#size/xl`, never points, so a leaf cannot reach xl.
pub(crate) const POINTS: &[(u32, &str)] =
    &[(1, "s"), (2, "s"), (3, "m"), (5, "m"), (8, "l"), (13, "l")];

/// The `#size/` band `pts` falls in, `None` for a count off the scale.
pub(crate) fn band(pts: u32) -> Option<&'static str> {
    POINTS.iter().find(|(n, _)| *n == pts).map(|&(_, b)| b)
}

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

/// What an open epic with no open child shows as in `notes board --json`'s `priority`
/// ([`Index::epic_priority`]); it ranks as `#low`, the last level.
pub(crate) const EMPTY: &str = "empty";

/// Is this row an epic: typed `epic(area): <outcome>`.
pub(crate) fn is_epic(line: &str) -> bool {
    line.contains("epic(") && projects::row_type_area(line).is_some_and(|(t, _)| t == "epic")
}

/// Is this row an epic's verify, `check(epics): verify <id> ...` (fleet-dispatch reconcile_epics).
/// Its `#of/` links the epic for readers, but the tree gives it no parent: it is the check that
/// the leaves landed, not one of them, so it neither holds the epic open nor raises its done
/// count (which would queue another verify), and the check can close the epic while its own row
/// is still open.
pub(crate) fn is_epic_check(line: &str) -> bool {
    line.contains("check(epics)")
        && projects::row_type_area(line).is_some_and(|(t, a)| t == "check" && a == "epics")
}

/// Does a close stamp prove an epic's outcome: something beyond the PRs that landed it, and
/// not `--unverified`. A merged PR says the work landed, never that the goal was reached.
pub(crate) fn proves_outcome(stamp: &str) -> bool {
    !stamp.starts_with("unverified:")
        && stamp
            .split_whitespace()
            .any(|t| !t.starts_with("pr:") && !t.contains("/pull/"))
}

/// What closed a row: its marker without the stamps every row carries.
pub(crate) fn proof_of(line: &str) -> String {
    let marker = md::marker_of(line).unwrap_or_default();
    let stamps = ["id:", "filed:", "done:", "carried", "ask:"];
    marker
        .split_whitespace()
        .filter(|t| !stamps.iter().any(|s| t.starts_with(s)))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Does a row belong to any release: every row does but an untagged epic, which is scope not
/// yet aimed at one. The one rule release gating and every version total read.
pub(crate) fn in_some_version(line: &str) -> bool {
    !is_epic(line) || sheet::target(line).is_some()
}

/// The open feature epics of the human sheet at `dir` as (aimed, backlog): aimed carries a
/// release tag, backlog does not ([`in_some_version`]). A standing epic (`<system> to standard`)
/// is upkeep, not a feature, so neither counts it, the rule Deliverables uses (hub-core
/// `page::is_standing`); an epic on the agent sheet is not read. What the board strip shows as
/// `Epics E | Epic backlog B`.
pub(crate) fn strip_counts(dir: &Path) -> (usize, usize) {
    let Some(content) = project_tasks::task_sheet(dir).and_then(|p| fs::read_to_string(p).ok())
    else {
        return (0, 0);
    };
    let mut n = (0, 0);
    for (_, l) in sheet::open_rows(&content)
        .into_iter()
        .filter(|(_, l)| is_epic(l))
    {
        let system = projects::row_type_area(l)
            .map(|(_, a)| a)
            .unwrap_or_default();
        if crate::standing::is_standing(&system, &projects::row_title(l)) {
            continue;
        }
        if in_some_version(l) {
            n.0 += 1;
        } else {
            n.1 += 1;
        }
    }
    n
}

#[derive(Debug)]
struct Node {
    id: Option<String>,
    parent: Option<String>,
    open: bool,
    dropped: bool,
    weight: u32,
    sized: bool,
    /// The release the row's tag names, if it carries one.
    target: Option<V>,
    /// The release the row belongs to: its note's, or the sheet's reading of its tag; none
    /// for an untagged epic ([`in_some_version`]).
    version: Option<V>,
    /// An epic's title; `None` marks a row that is not an epic.
    title: Option<String>,
    /// An epic's system, the area in `epic(<system>):`; empty on any other row.
    system: String,
    /// What closed the row, empty while open.
    proof: String,
    /// Where the row is, for a doctor line: `sheet line 12`.
    at: String,
    /// The row's priority as an index into [`md::PRIORITIES`], untagged as
    /// [`md::DEFAULT_PRIORITY`]: what an epic over it ranks as ([`Index::epic_priority`]).
    prio: usize,
}

/// One open epic's rollup over its leaves, in every version.
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub(crate) struct EpicProgress {
    pub id: String,
    pub title: String,
    /// The system it builds, the area in `epic(<system>):`, so a page can group epics by system.
    pub system: String,
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
    /// What closed it, empty on an open epic.
    pub proof: String,
    /// Closed on proof of the outcome ([`proves_outcome`]), not on landed work alone.
    pub verified: bool,
}

/// One untagged feature epic as release planning weighs it against a target ([`Index::backlog_for`]).
#[derive(Debug, Default, PartialEq, serde::Serialize)]
pub(crate) struct BacklogEpic {
    pub id: String,
    pub title: String,
    /// The open leaf weight counted past the target or in no release: what the work due by
    /// the target gains once the epic and these rows are aimed at it.
    pub add_weight: u32,
    /// Human-sheet ids to aim at the target, the epic first, then each leaf counted past it.
    pub moves: Vec<String>,
    /// Agent-board ids counted past the target, aimed with `ptask --agent move`.
    pub agent_moves: Vec<String>,
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
        let lanes = [
            (dir, "sheet", "versions"),
            (agent.as_path(), "agent board", "agent/versions"),
        ];
        // (text, the note's version or None for a live sheet, label)
        let mut texts: Vec<(String, Option<V>, String)> = Vec::new();
        for (lane, label, _) in lanes {
            if let Some(t) =
                project_tasks::task_sheet(lane).and_then(|p| fs::read_to_string(p).ok())
            {
                texts.push((t, None, label.to_string()));
            }
        }
        // The live sheets of the projects it versions (a game the playground numbers), whose
        // rows its window reads. Their `versions/` notes number the game's legacy line, not this
        // project's, so they stay out.
        for child in projects::version_child_dirs(dir) {
            let name = child
                .file_name()
                .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
            for (lane, label) in [
                (child.clone(), "sheet"),
                (projects::agent_dir(&child), "agent board"),
            ] {
                if let Some(t) =
                    project_tasks::task_sheet(&lane).and_then(|p| fs::read_to_string(p).ok())
                {
                    texts.push((t, None, format!("{name} {label}")));
                }
            }
        }
        for (lane, _, notes) in lanes {
            let mut found = projects::version_notes(&lane.join("versions"));
            found.sort_by_key(|a| std::cmp::Reverse(a.0));
            texts.extend(found.into_iter().filter_map(|(v, path)| {
                let t = fs::read_to_string(&path).ok()?;
                Some((t, Some(v), format!("{notes}/{}.md", fmt_version(v))))
            }));
        }
        let mut ix = Index::default();
        let named: HashSet<String> = texts
            .iter()
            .flat_map(|(t, ..)| t.lines().filter(|l| l.contains("#of/")))
            .filter_map(parent_of)
            .collect();
        if named.is_empty() && !texts.iter().any(|(t, ..)| t.contains("epic(")) {
            return ix;
        }
        let wanted = |l: &str| {
            l.contains("#of/")
                || l.contains("epic(")
                || md::row_id(l).is_some_and(|id| named.contains(&id))
        };
        for (t, note, label) in &texts {
            let rows: Vec<(usize, &str)> = match note {
                None => md::section_numbered(t, sheet::TASKS),
                Some(_) => t.lines().enumerate().map(|(i, l)| (i + 1, l)).collect(),
            };
            for (n, l) in rows {
                if l.starts_with("- [") && wanted(l) {
                    let v = note.or_else(|| {
                        in_some_version(l)
                            .then(|| sheet::version_of(l, cur))
                            .flatten()
                    });
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
        let parent = parent_of(line).filter(|_| !is_epic_check(line));
        match &id {
            Some(id) if self.by_id.contains_key(id) => return,
            None if parent.is_none() || !live => return,
            _ => {}
        }
        if let Some(id) = &id {
            self.by_id.insert(id.clone(), self.nodes.len());
        }
        let size = projects::size_of(line);
        self.nodes.push(Node {
            id,
            parent,
            open: md::is_open_task(line),
            dropped: md::is_dropped(line),
            weight: size.unwrap_or(1),
            sized: size.is_some(),
            target: sheet::target(line),
            version,
            title: is_epic(line).then(|| projects::row_title(line)),
            system: if is_epic(line) {
                projects::row_type_area(line).map_or_else(String::new, |(_, a)| a)
            } else {
                String::new()
            },
            proof: proof_of(line),
            at,
            prio: md::priority_index(line).unwrap_or(md::DEFAULT_PRIORITY),
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
        if !self.kids.is_empty() && md::row_id(line).is_some_and(|id| self.is_parent(&id)) {
            return false;
        }
        in_some_version(line)
    }

    /// What the open epic `id` ranks as: the most urgent of its open children that are not
    /// epics themselves, as an index into [`md::PRIORITIES`]; `None` when it has no open child
    /// ([`EMPTY`]). The one rule for an epic's priority: an epic row carries no tag of its own
    /// (`projects::row_findings` refuses one), so it is derived here, never stored.
    pub(crate) fn epic_priority(&self, id: &str) -> Option<usize> {
        self.children(id)
            .iter()
            .map(|&i| &self.nodes[i])
            .filter(|n| n.open && n.title.is_none())
            .map(|n| n.prio)
            .min()
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

    /// The ids under `id` at any depth, dropped rows left out, each walked once.
    pub(crate) fn descendants(&self, id: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut seen = HashSet::from([id.to_string()]);
        let mut stack = vec![id.to_string()];
        while let Some(j) = stack.pop() {
            for k in self.children(&j) {
                if let Some(c) = &self.nodes[*k].id {
                    if seen.insert(c.clone()) {
                        out.push(c.clone());
                        stack.push(c.clone());
                    }
                }
            }
        }
        out
    }

    /// The chain `[top, .., id]` when `id` sits under `top` at any depth, read up `id`'s
    /// parents; `None` when it does not. What a re-parent onto `id` would loop through.
    pub(crate) fn chain(&self, top: &str, id: &str) -> Option<Vec<String>> {
        let mut up = vec![id.to_string()];
        let mut cur = self.node(id)?;
        while let Some(p) = &cur.parent {
            if up.contains(p) {
                return None;
            }
            up.push(p.clone());
            if p == top {
                up.reverse();
                return Some(up);
            }
            cur = self.node(p)?;
        }
        None
    }

    /// How many children of the open row `id` closed done, and their ids, once none of its
    /// children is open: 0 when every one was dropped. `None` while one is open, when `id` is
    /// no open parent, and for an epic, which closes on proof of its outcome, never on its rows
    /// alone.
    pub(crate) fn spent(&self, id: &str) -> Option<(usize, Vec<String>)> {
        self.node(id).filter(|n| n.open && n.title.is_none())?;
        let kids: Vec<&Node> = self
            .nodes
            .iter()
            .filter(|n| n.parent.as_deref() == Some(id))
            .collect();
        if kids.is_empty() || kids.iter().any(|n| n.open) {
            return None;
        }
        let done: Vec<&&Node> = kids.iter().filter(|n| !n.dropped).collect();
        Some((
            done.len(),
            done.iter().filter_map(|n| n.id.clone()).collect(),
        ))
    }

    /// The leaves under node `i`, each node walked once, so a loop cannot hang a read. The
    /// same leaves [`Index::counts`] counts at any depth: an over-deep chain is a doctor
    /// finding, never a second answer to which rows are leaves.
    fn leaves(&self, i: usize) -> Vec<usize> {
        let mut out = Vec::new();
        let mut seen = HashSet::from([i]);
        let mut stack = vec![i];
        while let Some(j) = stack.pop() {
            let kids = self.nodes[j]
                .id
                .as_deref()
                .map_or(&[][..], |id| self.children(id));
            if kids.is_empty() {
                out.push(j);
            }
            stack.extend(kids.iter().copied().filter(|&k| seen.insert(k)));
        }
        out
    }

    fn rollup(&self, i: usize) -> EpicProgress {
        let e = &self.nodes[i];
        let mut p = EpicProgress {
            id: e.id.clone().unwrap_or_default(),
            title: e.title.clone().unwrap_or_default(),
            system: e.system.clone(),
            version: e.target.map(fmt_version).unwrap_or_default(),
            childless: !e.id.as_deref().is_some_and(|id| self.is_parent(id)),
            proof: if e.open {
                String::new()
            } else {
                e.proof.clone()
            },
            verified: !e.open && proves_outcome(&e.proof),
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
        (0..self.nodes.len()).filter(|&i| self.nodes[i].title.is_some() && self.nodes[i].open)
    }

    /// Every open epic with its rollup, in sheet order.
    pub(crate) fn epics(&self) -> Vec<EpicProgress> {
        self.open_epics().map(|i| self.rollup(i)).collect()
    }

    /// The open feature epics on the human sheet with no release tag, in sheet order, each with
    /// what aiming it at `to` adds to the work due by `to`. An untagged leaf already counts in
    /// the open version (`sheet::version_of`), so only the leaves counted past `to`, or in no
    /// release at all, add weight. Standing epics are upkeep, not scope to plan, the rule
    /// [`strip_counts`] uses. What release-coordinator `plan` fits against the hub card's
    /// `on_time.room_weight`.
    pub(crate) fn backlog_for(&self, to: V) -> Vec<BacklogEpic> {
        self.open_epics()
            .filter(|&i| {
                let e = &self.nodes[i];
                e.target.is_none()
                    && e.at.starts_with("sheet ")
                    && !crate::standing::is_standing(&e.system, e.title.as_deref().unwrap_or(""))
            })
            .map(|i| {
                let e = &self.nodes[i];
                let mut b = BacklogEpic {
                    id: e.id.clone().unwrap_or_default(),
                    title: e.title.clone().unwrap_or_default(),
                    moves: e.id.iter().cloned().collect(),
                    ..BacklogEpic::default()
                };
                for j in self.leaves(i) {
                    let n = &self.nodes[j];
                    if !n.open || n.version.is_some_and(|v| v <= to) {
                        continue;
                    }
                    // A leaf with no id cannot be moved by id, so it stays where it is and
                    // adds nothing: add_weight is exactly what the moves carry.
                    match (&n.id, j == i) {
                        (_, true) => {}
                        (Some(id), false) if n.at.starts_with("agent board") => {
                            b.agent_moves.push(id.clone());
                        }
                        (Some(id), false) => b.moves.push(id.clone()),
                        (None, false) => continue,
                    }
                    b.add_weight += n.weight;
                }
                b
            })
            .collect()
    }

    /// The epics closed in version `v`, whose open version is `cur`: a closed untagged epic
    /// belongs to no release, so it reads under the open one until the sheet freezes it into
    /// a note. A dropped epic was never delivered, so it is not listed.
    pub(crate) fn closed_epics_in(&self, v: V, cur: V) -> Vec<EpicProgress> {
        (0..self.nodes.len())
            .filter(|&i| {
                let n = &self.nodes[i];
                n.title.is_some() && !n.open && !n.dropped && n.version.unwrap_or(cur) == v
            })
            .map(|i| self.rollup(i))
            .collect()
    }

    /// The open epics with work in version `v`: a leaf of theirs in it, or, for an epic with
    /// no story yet, its own tag naming it.
    pub(crate) fn epics_in(&self, v: Option<V>) -> Vec<EpicProgress> {
        self.open_epics()
            .filter(|&i| {
                self.leaves(i)
                    .into_iter()
                    .any(|j| self.nodes[j].version.is_some() && self.nodes[j].version == v)
            })
            .map(|i| self.rollup(i))
            .collect()
    }

    /// The open rows of an agent board that sit under no feature: no epic, no `#of/`. Every
    /// agent row is a story (`agent-queue add` files one per work item), so once the project has
    /// an open epic, a row outside every epic is work no feature bar counts. Each row's id, else
    /// its line. None while the project has no open epic: there is no feature to file it under.
    pub(crate) fn stories_without_feature(&self, board: &str) -> Vec<String> {
        if self.open_epics().next().is_none() {
            return Vec::new();
        }
        md::section_numbered(board, sheet::TASKS)
            .into_iter()
            .filter(|(_, l)| md::is_open_task(l) && !is_epic(l) && parent_of(l).is_none())
            .map(|(n, l)| md::row_id(l).unwrap_or_else(|| format!("line {n}")))
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
            // A standing epic (`<system> to standard`) stays open with nothing under it.
            let feature = n
                .title
                .as_deref()
                .is_some_and(|t| !crate::standing::is_standing(&n.system, t));
            if let Some(id) = n.id.as_deref().filter(|_| feature) {
                if self.epic_priority(id).is_none() {
                    out.push(format!(
                        "{at}: epic {id} has no open row, so it ranks as {EMPTY}: close it or file its rows under it"
                    ));
                }
            }
            let Some(p) = n.parent.as_deref() else {
                continue;
            };
            if n.title.is_some() {
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
            // A row that only leads into a loop is not named: the loop's own rows are.
            match self.depth(i) {
                Err(k) if k == i => out.push(format!("{at}: #of/ loops back to this row")),
                Ok(d) if d > MAX_DEPTH => out.push(format!(
                    "{at}: {d} levels deep (epic, story, subtask is the most)"
                )),
                _ => {}
            }
        }
        out
    }

    /// How many levels node `i` sits at, 1 for a row with no parent here; `Err(k)` when
    /// following `#of/` up comes back to node `k`, which is `i` only for a row in the loop.
    fn depth(&self, i: usize) -> Result<usize, usize> {
        let mut seen = HashSet::from([i]);
        let mut j = i;
        while let Some(&k) = self.nodes[j]
            .parent
            .as_deref()
            .and_then(|p| self.by_id.get(p))
        {
            if !seen.insert(k) {
                return Err(k);
            }
            j = k;
        }
        Ok(seen.len())
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
                system: "rollup".into(),
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
    fn a_backlog_epic_adds_only_the_leaves_counted_past_the_target() {
        // NEGATIVE CONTROL: dm-3 has no tag, so it already counts in the open version (and in
        // target_work); weighing the whole epic (3 + 8 + 1) would count it twice.
        let dir = project(
            "backlog",
            &[
                (
                    "README.md",
                    "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                     - [ ] epic(feat): aimed already #v1.5.0 <!-- id:dm-1 -->\n\
                     - [ ] epic(feat): planned <!-- id:dm-2 -->\n\
                     - [ ] feat(feat): a #size/m #of/dm-2 <!-- id:dm-3 -->\n\
                     - [ ] feat(feat): b #size/l #v1.6.0 #of/dm-2 <!-- id:dm-4 -->\n\
                     - [ ] feat(feat): no id cannot move #size/m #v1.6.0 #of/dm-2\n\
                     - [x] feat(feat): d #size/l #v1.6.0 #of/dm-2 <!-- id:dm-6 pr:1 -->\n\
                     - [ ] epic(feat): no story yet #size/xl <!-- id:dm-7 -->\n\
                     - [ ] epic(notes): notes to standard <!-- id:dm-8 -->\n",
                ),
                (
                    "agent/README.md",
                    "# demo\n\n## Tasks\n\
                     - [ ] feat(feat): c #size/s #v1.6.0 #of/dm-2 <!-- id:dm-5 -->\n\
                     - [ ] epic(feat): agent lane epic <!-- id:dm-9 -->\n",
                ),
            ],
        );
        let ix = Index::of(&dir, V14);
        let planned = |add_weight, moves: &[&str], agent_moves: &[&str]| BacklogEpic {
            id: "dm-2".into(),
            title: "planned".into(),
            add_weight,
            moves: moves.iter().map(|s| s.to_string()).collect(),
            agent_moves: agent_moves.iter().map(|s| s.to_string()).collect(),
        };
        let childless = BacklogEpic {
            id: "dm-7".into(),
            title: "no story yet".into(),
            add_weight: 21,
            moves: vec!["dm-7".into()],
            agent_moves: vec![],
        };
        assert_eq!(
            ix.backlog_for(V15.unwrap()),
            vec![planned(9, &["dm-2", "dm-4"], &["dm-5"]), childless]
        );
        assert_eq!(
            ix.backlog_for((1, 6, 0))[0],
            planned(0, &["dm-2"], &[]),
            "rows already due by the target add nothing; only the epic needs aiming"
        );
        let _ = fs::remove_dir_all(&dir);
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
        assert_eq!(
            (p.closed_28d, p.closed_weight_28d),
            (2, 4),
            "the story's l is not a close"
        );
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
        assert_eq!(
            ids(V15),
            vec!["dm-1"],
            "the epic is listed in every release it has work in"
        );
        assert_eq!(ids(Some((1, 6, 0))), Vec::<String>::new());
    }

    #[test]
    fn an_epic_verify_row_links_its_epic_but_is_no_leaf_of_it() {
        let sheet = "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                     - [ ] epic(rollup): one estimate per release #size/xl <!-- id:dm-1 -->\n";
        let board = |row: &str| {
            format!(
                "# demo\n\n## Tasks\n\
                 - [x] feat(rollup): the story #size/s #of/dm-1 <!-- id:dm-2 done:2026-11-05 pr:7 -->\n\
                 {row}\n"
            )
        };
        let verify =
            "- [/] check(epics): verify dm-1 one estimate #size/s #high #of/dm-1 <!-- id:dm-3 -->";
        let dir = project(
            "verify",
            &[("README.md", sheet), ("agent/README.md", &board(verify))],
        );
        let ix = Index::of(&dir, V14);
        assert_eq!(
            parent_of(verify).as_deref(),
            Some("dm-1"),
            "the row keeps its link"
        );
        let e = &ix.epics()[0];
        assert_eq!(
            (e.open, e.done),
            (0, 1),
            "landed: its verify does not hold it open"
        );
        assert!(
            ix.open_children("dm-1").is_empty(),
            "the check closes the epic it verifies"
        );
        // NEGATIVE CONTROL: the same row typed as a gap under the epic is one of its open leaves.
        let gap =
            "- [ ] fix(epics): verify dm-1 one estimate #size/s #high #of/dm-1 <!-- id:dm-3 -->";
        let dir = project(
            "verify-gap",
            &[("README.md", sheet), ("agent/README.md", &board(gap))],
        );
        let ix = Index::of(&dir, V14);
        assert_eq!((ix.epics()[0].open, ix.epics()[0].done), (1, 1));
        assert_eq!(ix.open_children("dm-1"), vec!["dm-3 (agent board line 5)"]);
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
        assert_eq!(
            (now.open, now.open_weight),
            (0, 0),
            "an untagged epic is in no version"
        );
        assert_eq!(
            (next.open, next.open_weight),
            (1, 21),
            "a tagged one is its own leaf"
        );
        let e = ix.epics();
        assert!(e.iter().all(|e| e.childless && e.open_weight == 21));
        assert_eq!(e[1].version, "v1.5.0");
        let systems: Vec<&str> = e.iter().map(|e| e.system.as_str()).collect();
        assert_eq!(
            systems,
            vec!["spread", "soon"],
            "each epic carries the system its epic(<system>): prefix names"
        );
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
                 - [ ] feat(f): fine #of/dm-8 <!-- id:dm-11 -->\n\
                 - [ ] feat(d): leads into the loop #of/dm-6 <!-- id:dm-12 -->\n",
            )],
        );
        let f = Index::of(&dir, V14).findings();
        let want = [
            "sheet line 5: #of/dm-99 names no row in this project",
            "sheet line 7: open under dm-2, which is done",
            "sheet line 8: epic dm-4 has no open row, so it ranks as empty: close it or file its rows under it",
            "sheet line 8: an epic takes no #of/ (it is the top of its tree)",
            "sheet line 10: #of/ loops back to this row",
            "sheet line 11: #of/ loops back to this row",
            "sheet line 14: 4 levels deep (epic, story, subtask is the most)",
        ];
        assert_eq!(f, want);
    }

    // An epic's priority is its most urgent open child's, a child epic, a closed row and a
    // dropped one aside; with none open it has no priority and doctor names it.
    #[test]
    fn an_epic_takes_its_most_urgent_open_childs_priority() {
        let dir = project(
            "epicprio",
            &[(
                "README.md",
                "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                 - [ ] epic(a): busy #low <!-- id:dm-1 -->\n\
                 - [ ] feat(a): high one #high #of/dm-1 <!-- id:dm-2 -->\n\
                 - [ ] feat(a): untagged #of/dm-1 <!-- id:dm-3 -->\n\
                 - [x] feat(a): closed urgent #urgent #of/dm-1 <!-- id:dm-4 done:2026-11-05 pr:1 -->\n\
                 - [ ] epic(b): idle <!-- id:dm-5 -->\n\
                 - [ ] epic(b): a child epic #urgent #of/dm-5 <!-- id:dm-6 -->\n\
                 - [x] feat(b): dropped #urgent #of/dm-5 <!-- id:dm-7 dropped: stale -->\n\
                 - [ ] epic(c): c to standard <!-- id:dm-8 -->\n",
            )],
        );
        let ix = Index::of(&dir, V14);
        assert_eq!(
            ix.epic_priority("dm-1"),
            Some(1),
            "#high, not the epic's own #low"
        );
        assert_eq!(ix.epic_priority("dm-5"), None);
        let f = ix.findings();
        assert!(
            f.iter().any(|l| l.contains("epic dm-5 has no open row")),
            "{f:?}"
        );
        // NEGATIVE CONTROL: an epic with an open row is not named, nor a standing epic with none.
        assert!(!f.iter().any(|l| l.contains("epic dm-1 ")), "{f:?}");
        assert_eq!(ix.epic_priority("dm-8"), None);
        assert!(!f.iter().any(|l| l.contains("epic dm-8 ")), "{f:?}");
    }

    #[test]
    fn doctor_names_the_board_stories_under_no_feature() {
        let board = "## Tasks\n\
                     - [/] feat(a): filed by an item #of/dm-1 <!-- id:dm-2 -->\n\
                     - [/] feat(a): filed with no epic <!-- id:dm-3 -->\n\
                     - [ ] chore(b): no id either\n\
                     - [x] feat(a): done, never named <!-- id:dm-4 pr:7 -->\n\
                     - [ ] feat(c): a subtask #of/dm-3 <!-- id:dm-5 -->\n";
        let with_epic = project(
            "unlinked",
            &[
                (
                    "README.md",
                    "# demo\nVersion: v1.4.0\n\n## Tasks\n- [ ] epic(a): menus <!-- id:dm-1 -->\n",
                ),
                ("agent/README.md", board),
            ],
        );
        let ix = Index::of(&with_epic, V14);
        assert_eq!(ix.stories_without_feature(board), vec!["dm-3", "line 4"]);
        // NEGATIVE CONTROL: with no open epic there is no feature to name, so nothing is listed.
        let none = project("unlinked-none", &[("agent/README.md", board)]);
        assert!(Index::of(&none, V14)
            .stories_without_feature(board)
            .is_empty());
    }

    #[test]
    fn row_grammar_keeps_epics_on_the_sheet_and_xl_on_epics() {
        let board = "## Tasks\n\
                     - [ ] epic(a): on the board <!-- id:dm-1 -->\n\
                     - [ ] feat(a): huge #size/xl <!-- id:dm-2 -->\n\
                     - [ ] epic(a): sized right #size/xl <!-- id:dm-3 -->\n";
        let f = projects::row_findings(board, true);
        assert!(
            f.contains(&"line 2: an epic belongs on the human sheet, not the agent board".into())
        );
        assert!(
            f.contains(&"line 3: #size/xl is an epic's size; split the row or size it l".into())
        );
        assert!(!f.iter().any(|l| l.starts_with("line 4: #size/xl")));
        assert!(!projects::row_findings(board, false)
            .iter()
            .any(|l| l.contains("agent board")));
    }

    #[test]
    fn the_parent_tag_is_a_link_not_text() {
        let l = "- [ ] feat(a): do it #of/ar-12 #size/m <!-- id:ar-13 -->";
        assert_eq!(parent_of(l).as_deref(), Some("ar-12"));
        assert_eq!(
            md::task_text(l),
            md::task_text("- [ ] feat(a): do it #size/m")
        );
        assert_eq!(parent_of("- [ ] feat(a): #of/not-an-id"), None);
        assert_eq!(projects::size_weight("- [ ] epic(a): big #size/xl"), 21);
        assert_eq!(projects::size_weight("- [ ] feat(a): tiny #size/xs"), 1);
        assert_eq!(projects::size_weight("- [ ] feat(a): odd #size/huge"), 1);
        assert!(is_epic("- [ ] epic(a): outcome #high"));
        assert!(!is_epic("- [ ] feat(epic): not one"));
    }

    #[test]
    fn a_rewrite_keeps_the_parent_link() {
        // NEGATIVE CONTROL: task_text strips #of/, so a rewrite whose old text is not a
        // prefix of the row took the fallback path and dropped the link.
        let l = "- [ ] feat(a): do it #of/dm-1 #size/m <!-- id:dm-3 -->";
        let out = md::retext_task(l, "feat(a): do it better");
        assert_eq!(parent_of(&out).as_deref(), Some("dm-1"), "{out}");
        assert!(out.ends_with("<!-- id:dm-3 -->"), "{out}");
    }

    #[test]
    fn only_something_beyond_a_pr_proves_an_outcome() {
        assert!(!proves_outcome("pr:12"));
        assert!(!proves_outcome("https://github.com/a/b/pull/12"));
        assert!(!proves_outcome("unverified: no target yet"));
        assert!(proves_outcome("https://agents.example/p"));
        assert!(proves_outcome("pr:12 seen live"));
        let row = "- [x] epic(ui): a <!-- id:d-1 filed:2026-11-01 done:2026-11-04 pr:1 https://a.example -->";
        assert_eq!(proof_of(row), "pr:1 https://a.example");
    }

    #[test]
    fn a_parent_never_gates_a_release_its_leaves_do() {
        // NEGATIVE CONTROL: a tagged epic (or a story) with a child aimed later gated its
        // release, and `ptask done` refuses it while the child is open: a release it could
        // never pass but by --force.
        let dir = project(
            "gate",
            &[(
                "README.md",
                "# demo\nVersion: v1.4.0\n\n## Tasks\n\
                 - [ ] epic(a): outcome #v1.4.0 <!-- id:dm-1 -->\n\
                 - [ ] feat(a): story #of/dm-1 <!-- id:dm-2 -->\n\
                 - [ ] feat(a): later part #of/dm-2 #v1.5.0 <!-- id:dm-3 -->\n\
                 - [x] feat(a): done part #of/dm-2 <!-- id:dm-4 done:2026-11-05 pr:1 -->\n",
            )],
        );
        let ix = Index::of(&dir, V14);
        let sheet = fs::read_to_string(dir.join("README.md")).unwrap();
        assert!(projects::gated_rows(&sheet, (1, 4, 0), &ix).is_empty());
        let with_leaf = sheet.replace("#v1.5.0 ", "");
        let ix = Index::of(&dir, V14);
        assert_eq!(projects::gated_rows(&with_leaf, (1, 4, 0), &ix).len(), 1);
    }
}
