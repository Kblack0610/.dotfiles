//! One sprint's page (`#projects/<profile>/<project>/sprint/<version>`): the window's header, a
//! By area rollup, and every row, committed and interrupt, with what became of it. The rows and
//! their outcomes are notes-cli's (`notes projects --sprints <p> --version <v> --json`, built on
//! the same code that scores the window, so the outcomes sum to its Score line); this adds each
//! row's group from `crate::areas` and the rollup, so agent-web and the hub TUI say the same
//! numbers and nothing is tallied a second time on a surface.

use serde::{Deserialize, Serialize};

use crate::areas::Areas;
use crate::links::{Kind, Link};
use crate::project_sprints::{self, Past};
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// One row of the window with its outcome, as notes-cli prints it, plus its group.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SprintRow {
    pub id: Option<String>,
    /// notes-cli's `type`.
    #[serde(alias = "type")]
    pub kind: Option<String>,
    /// The row's `type(scope):` scope, notes-cli's `area`.
    #[serde(alias = "area")]
    pub scope: Option<String>,
    /// The row's words after its prefix.
    #[serde(rename = "title")]
    pub name: String,
    pub pts: u32,
    /// The row as it stands now (`open`, `doing`, `done`, `dropped`, `deferred`, `gone`).
    pub state: String,
    /// `delivered`, `carried`, `open` (while the window runs) or `dropped`.
    pub outcome: String,
    /// Done in the window but not committed: it entered after the lock.
    pub interrupt: bool,
    /// The scope's group (`crate::areas`).
    #[serde(skip_deserializing)]
    pub group: String,
}

/// One group's line of the By area table.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct AreaLine {
    pub group: String,
    pub rows: usize,
    pub delivered: usize,
    /// Still open, or carried once the window is cut.
    pub pending: usize,
    pub dropped: usize,
    /// Points delivered and every row's, summed while the rollup is built.
    #[serde(skip)]
    pub pts_done: u32,
    #[serde(skip)]
    pub pts_total: u32,
    /// `48/80`, points delivered of the group's: the cell both surfaces draw.
    pub pts: String,
}

/// The By area table's columns, `(key, head)`; what is not yet delivered is `OPEN` while the
/// window runs and `CARRIED` once it is cut.
pub fn area_heads(state: &str) -> Vec<(&'static str, &'static str)> {
    vec![
        ("group", "AREA"),
        ("rows", "ROWS"),
        ("delivered", "DELIVERED"),
        (
            "pending",
            if state == "closed" { "CARRIED" } else { "OPEN" },
        ),
        ("dropped", "DROPPED"),
        ("pts", "PTS"),
    ]
}

/// The window as notes-cli prints it, with the groups and what the surfaces draw.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Page {
    pub version: String,
    /// `open`, `queued` or `closed`.
    pub state: String,
    pub opened: String,
    pub due: Option<String>,
    pub locked: Option<String>,
    pub cut: Option<String>,
    pub timing: Option<String>,
    pub committed: usize,
    pub delivered: usize,
    /// Committed rows still open (carried once the window is cut).
    pub open: usize,
    pub dropped: usize,
    pub interrupted: usize,
    /// The score the cut froze: a cut window's rows keep moving, so it can differ from the live counts.
    pub score: Option<Past>,
    pub rows: Vec<SprintRow>,
    /// The window's dates and its counts, one line each, as both surfaces print them.
    #[serde(skip_deserializing)]
    pub head: Vec<String>,
    #[serde(skip_deserializing)]
    pub by_area: Vec<AreaLine>,
    #[serde(skip_deserializing)]
    pub prev: Option<Link>,
    #[serde(skip_deserializing)]
    pub next: Option<Link>,
    /// What could not be read: the groups file, or the neighbouring versions.
    #[serde(skip_deserializing)]
    pub errors: Vec<String>,
}

/// A sprint's page: `<profile>/<project>/<version>`.
pub fn link(profile: &str, project: &str, version: &str) -> Link {
    Link::to(Kind::Sprint, format!("{profile}/{project}/{version}"))
}

/// Whether `v` is a version name a read may pass to notes.
pub fn safe_version(v: &str) -> bool {
    crate::tasks::is_version(v)
}

/// The By area table: one line per group over every row, the biggest by points first and
/// Unsorted last.
pub fn rollup(rows: &[SprintRow]) -> Vec<AreaLine> {
    let mut out: Vec<AreaLine> = Vec::new();
    for r in rows {
        let at = match out.iter().position(|a| a.group == r.group) {
            Some(i) => i,
            None => {
                out.push(AreaLine {
                    group: r.group.clone(),
                    ..Default::default()
                });
                out.len() - 1
            }
        };
        let a = &mut out[at];
        a.rows += 1;
        a.pts_total += r.pts;
        match r.outcome.as_str() {
            "delivered" => {
                a.delivered += 1;
                a.pts_done += r.pts;
            }
            "dropped" => a.dropped += 1,
            _ => a.pending += 1,
        }
    }
    for a in &mut out {
        a.pts = format!("{}/{}", a.pts_done, a.pts_total);
    }
    out.sort_by(|a, b| {
        (a.group == crate::areas::UNSORTED)
            .cmp(&(b.group == crate::areas::UNSORTED))
            .then(b.pts_total.cmp(&a.pts_total))
            .then(b.rows.cmp(&a.rows))
            .then(a.group.cmp(&b.group))
    });
    out
}

/// The dates line and the counts line, and the frozen score when the live counts moved off it.
fn head_lines(p: &Page) -> Vec<String> {
    let mut dates = vec![format!("opened {}", p.opened)];
    if let Some(l) = &p.locked {
        dates.push(format!("locked {l}"));
    }
    if let Some(d) = &p.due {
        dates.push(format!("due {d}"));
    }
    match (&p.cut, &p.timing) {
        (Some(c), Some(t)) => dates.push(format!("cut {c} ({t})")),
        (Some(c), None) => dates.push(format!("cut {c}")),
        _ => {}
    }
    let rest = if p.state == "closed" {
        "carried"
    } else {
        "open"
    };
    let mut out = vec![
        dates.join("  "),
        format!(
            "committed {}  delivered {}  {rest} {}  dropped {}  interrupts {}",
            p.committed, p.delivered, p.open, p.dropped, p.interrupted
        ),
    ];
    if let Some(s) = p
        .score
        .as_ref()
        .filter(|s| (s.delivered, s.dropped) != (p.delivered, p.dropped))
    {
        out.push(format!("score at the cut: {}", s.line));
    }
    out
}

/// The versions either side of `version` among `all`.
fn neighbours(all: &mut Vec<String>, version: &str) -> (Option<String>, Option<String>) {
    all.retain(|v| safe_version(v));
    all.sort_by_key(|v| crate::tasks::release_order(v));
    all.dedup();
    let Some(i) = all.iter().position(|v| v == version) else {
        return (None, None);
    };
    (
        i.checked_sub(1).map(|j| all[j].clone()),
        all.get(i + 1).cloned(),
    )
}

/// The page `json` (notes-cli's) holds, grouped by `areas`, with the neighbouring versions
/// among `windows`.
pub fn build(
    json: &str,
    areas: &Areas,
    profile: &str,
    project: &str,
    mut windows: Vec<String>,
) -> Result<Page, String> {
    let mut p: Page = serde_json::from_str(json)
        .map_err(|e| format!("notes projects --sprints --version --json: {e}"))?;
    for r in &mut p.rows {
        r.group = areas.group(r.scope.as_deref());
    }
    p.by_area = rollup(&p.rows);
    p.head = head_lines(&p);
    windows.push(p.version.clone());
    let (prev, next) = neighbours(&mut windows, &p.version);
    p.prev = prev.map(|v| link(profile, project, &v));
    p.next = next.map(|v| link(profile, project, &v));
    Ok(p)
}

/// Read one sprint's page. `windows` are the versions the caller knows of beside the scored
/// ones (the open and queued windows), for the links to the next and the previous.
pub fn read(
    runner: &dyn Runner,
    areas: Result<Areas, String>,
    profile: &str,
    project: &str,
    version: &str,
    windows: &[String],
) -> Result<Page, String> {
    if !crate::projects::safe_name(profile)
        || !crate::projects::safe_name(project)
        || !safe_version(version)
    {
        return Err(format!("refusing {profile}/{project}/{version}"));
    }
    let out = runner.run(&[
        "notes".into(),
        "projects".into(),
        "--sprints".into(),
        project.into(),
        "--version".into(),
        version.into(),
        "--json".into(),
    ])?;
    let mut errors = Vec::new();
    let mut known = windows.to_vec();
    match project_sprints::past(runner, project) {
        Ok(h) => known.extend(h.into_iter().map(|p| p.version)),
        Err(e) => errors.push(e),
    }
    let groups = areas.unwrap_or_else(|e| {
        errors.push(e);
        Areas::default()
    });
    let mut p = build(&out, &groups, profile, project, known)?;
    p.errors = errors;
    Ok(p)
}

/// The rows table on both surfaces: every row of the window, filtered by area group, scope,
/// outcome, type and interrupt.
impl Row for SprintRow {
    const COLUMNS: &'static [&'static str] = &[
        "id",
        "type",
        "scope",
        "group",
        "title",
        "pts",
        "outcome",
        "state",
        "interrupt",
    ];
    const STATES: &'static [&'static str] = &["all", "delivered", "carried", "open", "dropped"];
    const FACETS: &'static [&'static str] = &["group", "scope", "outcome", "type", "interrupt"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "title";
    const GLANCE: &'static [&'static str] = &["outcome", "pts"];

    fn val(&self, col: &str) -> Val {
        let text = Val::word;
        let opt = |s: &Option<String>| s.as_deref().map_or(Val::None, text);
        match col {
            "id" => opt(&self.id),
            "type" => opt(&self.kind),
            "scope" => opt(&self.scope),
            "group" => text(&self.group),
            "title" => text(&self.name),
            "pts" => Val::Num(f64::from(self.pts)),
            "outcome" => text(&self.outcome),
            "state" => text(&self.state),
            "interrupt" => Val::Text(if self.interrupt { "yes" } else { "no" }.into()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        self.outcome == s
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "id" => self.id.as_ref().map(|i| Link::to(Kind::Row, i.clone())),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;

    const PAGE: &str = r#"{"version":"v0.5.5","state":"closed","opened":"2026-11-19",
        "due":"2026-11-21","locked":"2026-11-19 09:00","cut":"2026-11-22","timing":"late by 1 day",
        "committed":4,"delivered":2,"open":1,"dropped":1,"interrupted":1,
        "score":{"version":"v0.5.5","committed":4,"delivered":2,"carried":1,"dropped":1,
                 "interrupted":1,"line":"2/4"},
        "rows":[
         {"id":"u-1","type":"fix","area":"ci","title":"ssh host key","pts":3,"state":"done","outcome":"delivered","interrupt":false},
         {"id":"u-2","type":"feat","area":"gameplay","title":"dash","pts":5,"state":"open","outcome":"carried","interrupt":false},
         {"id":"u-3","type":"chore","area":"tests","title":"flaky","pts":2,"state":"dropped","outcome":"dropped","interrupt":false},
         {"id":"u-4","type":"feat","area":"unity-core-playground","title":"misc","pts":1,"state":"done","outcome":"delivered","interrupt":false},
         {"id":"u-5","type":"fix","area":"ci","title":"red main","pts":0,"state":"done","outcome":"delivered","interrupt":true}]}"#;

    fn areas() -> Areas {
        Areas::parse(
            "@unity-core-playground  Games\ntest,tests,ci  Tests, CI and benches\ngameplay  Engine\n",
        )
    }

    fn built() -> Page {
        build(
            PAGE,
            &areas(),
            "bnb",
            "unity",
            vec!["v0.5.6".into(), "v0.5.4".into()],
        )
        .unwrap()
    }

    #[test]
    fn the_rollup_sums_to_the_rows_and_aliases_share_a_group() {
        let p = built();
        let by: Vec<(&str, usize, usize, usize, usize, String)> = p
            .by_area
            .iter()
            .map(|a| {
                (
                    a.group.as_str(),
                    a.rows,
                    a.delivered,
                    a.pending,
                    a.dropped,
                    a.pts.clone(),
                )
            })
            .collect();
        assert_eq!(
            by,
            [
                ("Tests, CI and benches", 3, 2, 0, 1, "3/5".to_string()),
                ("Engine", 1, 0, 1, 0, "0/5".to_string()),
                ("Unsorted", 1, 1, 0, 0, "1/1".to_string()),
            ],
            "ci and tests are one group, the tie on points goes to more rows, a repo-name scope is Unsorted, Unsorted is last"
        );
        assert_eq!(
            p.by_area.iter().map(|a| a.rows).sum::<usize>(),
            p.rows.len()
        );
        let delivered: usize = p.by_area.iter().map(|a| a.delivered).sum();
        assert_eq!(
            delivered,
            p.delivered + 1,
            "the committed rows plus the one interrupt"
        );
    }

    #[test]
    fn the_head_says_the_dates_the_counts_and_a_score_that_moved() {
        let p = built();
        assert_eq!(
            p.head[0],
            "opened 2026-11-19  locked 2026-11-19 09:00  due 2026-11-21  cut 2026-11-22 (late by 1 day)"
        );
        assert_eq!(
            p.head[1],
            "committed 4  delivered 2  carried 1  dropped 1  interrupts 1"
        );
        assert_eq!(p.head.len(), 2, "the live counts match the frozen score");
        let moved = PAGE.replace("\"delivered\":2,\"open\":1", "\"delivered\":3,\"open\":0");
        let p = build(&moved, &areas(), "bnb", "unity", vec![]).unwrap();
        assert_eq!(p.head[2], "score at the cut: 2/4");
    }

    #[test]
    fn the_neighbours_are_the_versions_either_side_in_version_order() {
        let p = built();
        assert_eq!(
            p.prev.unwrap().href(),
            "#projects/bnb%2Funity/sprint/v0.5.4"
        );
        assert_eq!(
            p.next.unwrap().href(),
            "#projects/bnb%2Funity/sprint/v0.5.6"
        );
        let ten = PAGE.replace("v0.5.5", "v0.5.10");
        let p = build(
            &ten,
            &areas(),
            "bnb",
            "unity",
            vec!["v0.5.9".into(), "v0.5.11".into(), "v0.5.2".into()],
        )
        .unwrap();
        assert_eq!(
            p.prev.unwrap().href(),
            "#projects/bnb%2Funity/sprint/v0.5.9",
            "numbers, not text"
        );
        assert_eq!(
            p.next.unwrap().href(),
            "#projects/bnb%2Funity/sprint/v0.5.11"
        );
        let alone = build(PAGE, &areas(), "bnb", "unity", vec![]).unwrap();
        assert!(alone.prev.is_none() && alone.next.is_none());
    }

    #[test]
    fn the_rows_table_filters_by_group_and_outcome_and_says_interrupts() {
        let p = built();
        let ci = View::new::<SprintRow>("group:Tests", "", "", "");
        let (kept, _) = ci.summary(&p.rows);
        let ids: Vec<_> = kept.iter().filter_map(|r| r.id.as_deref()).collect();
        assert_eq!(ids, ["u-1", "u-3", "u-5"], "one facet click is only CI");
        let (kept, table) = View::new::<SprintRow>("interrupt:yes", "", "", "").summary(&p.rows);
        assert_eq!(kept.len(), 1);
        assert_eq!(table.total, 5, "the count is the whole window's");
        let (kept, _) = View::new::<SprintRow>("", "dropped", "", "").summary(&p.rows);
        assert_eq!(kept.len(), 1);
    }

    #[test]
    fn a_garbled_read_and_an_unsafe_name_are_errors_never_an_empty_page() {
        assert!(build("nope", &areas(), "bnb", "unity", vec![]).is_err());
        struct Never;
        impl Runner for Never {
            fn run(&self, _: &[String]) -> Result<String, String> {
                panic!("an unsafe name never reaches notes");
            }
        }
        for (p, v) in [("../x", "v0.5.5"), ("unity", "v0.5"), ("unity", "latest")] {
            assert!(
                read(&Never, Ok(areas()), "bnb", p, v, &[]).is_err(),
                "{p} {v}"
            );
        }
    }

    #[test]
    fn a_read_asks_notes_for_the_page_and_the_history_and_keeps_what_failed() {
        struct Says;
        impl Runner for Says {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                match argv.join(" ").as_str() {
                    "notes projects --sprints unity --version v0.5.5 --json" => Ok(PAGE.into()),
                    "notes projects --sprints unity --json" => {
                        Ok(r#"[{"version":"v0.5.4"}]"#.into())
                    }
                    other => Err(format!("unexpected {other}")),
                }
            }
        }
        let p = read(
            &Says,
            Err("no groups file".into()),
            "bnb",
            "unity",
            "v0.5.5",
            &[],
        )
        .unwrap();
        assert_eq!(
            p.errors,
            ["no groups file"],
            "unread groups are said, not guessed"
        );
        assert_eq!(
            p.prev.unwrap().href(),
            "#projects/bnb%2Funity/sprint/v0.5.4"
        );
        assert_eq!(p.rows[0].group, "ci", "no map: the scope stands alone");
    }
}
