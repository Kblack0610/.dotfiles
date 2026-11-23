//! A product's department tabs and Projects > Coverage, both surfaces, from one read
//! (dashboards rule 8). Stores: pipelines from `~/.config/agentctl/departments.tsv` checked
//! against this machine, numbers from VictoriaMetrics `kb_project_number`, Marketing's outbound
//! ledger (`outbound`), Legal from `game.json` or `metadata.yaml` with each URL probed, and the
//! stage that makes a department due from stages.md. A cell is `ok` (fed, no gap), `amber` (a gap not due yet), `red` (a gap
//! its stage requires) or `off` (nothing feeds it, nothing due). Only the product's own
//! sources count: a `*` catalog row serves every product, so it is listed, never counted.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use project_map::Registry;
use serde::Serialize;
use serde_json::Value;

use crate::links::{Kind, Link};
use crate::outbound::{self, Item};
use crate::prom::Series;
use crate::reading::{self, State};
use crate::schedules::CiState;
use crate::session_actions::Runner;
use crate::stages::{Reqs, Requirement};
use crate::table::{Row, Val};
use crate::vocab::Level;

pub use crate::stages::Department;

/// The stage ladder, lowest first, as stages.md orders it.
const LADDER: [&str; 5] = ["draft", "dev", "alpha", "beta", "prod"];

/// The project-map types that are products: all of stages.md's departments apply to them. Any
/// other typed project (infra) has only [`INFRA_DEPARTMENTS`], the ones its base rows fill.
const PRODUCT_TYPES: [&str; 2] = ["game", "app"];

/// The departments an infra project has: its Requirements rows are the `base` ones.
const INFRA_DEPARTMENTS: [&str; 2] = ["engineering", "ops"];

/// Whether a project of project-map type `kind` has department `id`: a product has every one, any
/// other typed project engineering and ops.
pub fn applies(kind: &str, id: &str) -> bool {
    PRODUCT_TYPES.contains(&kind) || INFRA_DEPARTMENTS.contains(&id)
}

/// The trend dashboard every tab links (home-config `apps/monitoring/dashboards/kb-project.json`).
const DASHBOARD: &str = "kb-project";

/// How long one URL probe may take.
const PROBE_SECS: &str = "5";

/// A cell of the grid, worst first.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Cell {
    Red,
    Amber,
    #[default]
    Off,
    Ok,
}

impl Cell {
    pub const fn word(self) -> &'static str {
        match self {
            Cell::Red => "red",
            Cell::Amber => "amber",
            Cell::Off => "off",
            Cell::Ok => "ok",
        }
    }

    pub const fn level(self) -> Level {
        match self {
            Cell::Red => Level::Bad,
            Cell::Amber => Level::Warn,
            Cell::Off | Cell::Ok => Level::Ok,
        }
    }
}

/// A source's words on this machine.
const FOUND: &str = "ok";
const MISSING: &str = "missing";
const NOT_CLONED: &str = "not cloned";

/// A Legal check's words: met, a gap, or no check exists yet (never a failure, rule 6).
pub const MET: &str = "ok";
pub const GAP: &str = "gap";
pub const NOT_YET: &str = "not yet";

#[derive(Clone, Debug)]
pub struct Paths {
    pub catalog: PathBuf,
    /// The agentctl conf dir a runner source names a conf in.
    pub agents: PathBuf,
    /// agentctl's state dir: `<runner>/last-outcome`.
    pub state: PathBuf,
    /// Where a skill source is deployed: `<skill>/SKILL.md`, flat or one group deep.
    pub skills: PathBuf,
    /// Where an exporter source is deployed.
    pub bin: PathBuf,
    pub home: PathBuf,
    /// `schedules-sync`'s state.json, the last runs of scheduled workflows.
    pub ci: PathBuf,
    /// The outbound ledger `mkt` writes, which Marketing lists.
    pub outbound: PathBuf,
}

impl Paths {
    /// The deployed homes; `DEPARTMENTS_CATALOG` moves the catalog and `AGENTCTL_STATE_DIR`
    /// the runner state, as their writers read them.
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let var = |k: &str| {
            std::env::var(k)
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        Paths {
            catalog: var("DEPARTMENTS_CATALOG")
                .unwrap_or_else(|| home.join(".config/agentctl/departments.tsv")),
            agents: home.join(".config/agentctl/agents"),
            state: var("AGENTCTL_STATE_DIR").unwrap_or_else(|| home.join(".local/state/agentctl")),
            skills: home.join(".claude/skills"),
            bin: home.join(".local/bin"),
            ci: crate::schedules::state_path(&home.to_string_lossy()),
            outbound: crate::boards::outbound_dir(),
            home,
        }
    }
}

/// One catalog row: `department source kind project record`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Source {
    pub dept: String,
    pub source: String,
    pub kind: String,
    pub project: String,
    pub record: String,
}

/// The catalog's rows; a comment, a blank line or a row short of five fields is skipped.
pub fn catalog(text: &str) -> Vec<Source> {
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() >= 5).then(|| Source {
                dept: f[0].trim().into(),
                source: f[1].trim().into(),
                kind: f[2].trim().into(),
                project: f[3].trim().into(),
                record: f[4].trim().into(),
            })
        })
        .collect()
}

/// One pipeline feeding a department, as its tab lists it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Pipe {
    pub source: String,
    pub kind: String,
    pub record: String,
    /// A `*` row: it serves every product, so it is listed but counts as no product's feed.
    pub shared: bool,
    /// `ok`, `missing` or `not cloned` on this machine.
    pub found: &'static str,
    /// When it last ran (a runner or a scheduled workflow) or last changed (a file).
    pub last: Option<i64>,
    pub last_says: String,
    /// Its last verdict in its own word (WORKED, success), empty when it has none.
    pub verdict: String,
    pub level: Level,
}

/// One item of a product's Legal checklist, with its evidence: a file or a probed URL.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Check {
    pub item: &'static str,
    /// `ok`, `gap` or `not yet`.
    pub state: &'static str,
    pub says: String,
    pub evidence: String,
    /// A gap's tone: bad once the stage requires Legal, warn before; ok otherwise.
    pub level: Level,
}

/// One number from `kb_project_number`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Number {
    pub metric: String,
    pub value: f64,
    pub says: String,
}

/// One line of what needs the human, worst first.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Need {
    pub level: Level,
    pub says: String,
}

/// One department of one product.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Dept {
    pub id: String,
    pub title: String,
    pub question: String,
    pub cell: Cell,
    /// The stage that makes it due for this product's type (`beta`), when any does.
    pub due_at: Option<String>,
    /// Whether the product's stage has reached `due_at`.
    pub required: bool,
    pub needs: Vec<Need>,
    pub numbers: Vec<Number>,
    /// Why there are no numbers (`no data`, `not read: ...`); empty when there are.
    pub numbers_says: String,
    pub pipes: Vec<Pipe>,
    /// Legal only: the checklist for the product's type.
    pub checks: Vec<Check>,
    /// The `kb-project` dashboard on this product; None when no Grafana is configured.
    pub grafana: Option<String>,
    /// Marketing only: the ledger's open items and what went out in 30 days, newest first.
    pub outbound: Vec<Item>,
    /// Why the ledger was not read; empty when it was.
    pub outbound_says: String,
}

/// One project with department tabs (a product, or infra with engineering and ops): a Coverage
/// row and its tabs.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Product {
    pub profile: String,
    pub name: String,
    pub stage: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub stage_rank: Option<usize>,
    pub depts: Vec<Dept>,
}

impl Dept {
    /// The needs that are not ok: the number on the department's inner tab.
    pub fn open_needs(&self) -> usize {
        self.needs.iter().filter(|n| n.level != Level::Ok).count()
    }
}

impl Product {
    /// Each department's `open_needs`, by id.
    pub fn open_needs(&self) -> BTreeMap<String, usize> {
        self.depts
            .iter()
            .map(|d| (d.id.clone(), d.open_needs()))
            .collect()
    }

    pub fn key(&self) -> String {
        format!("{}/{}", self.profile, self.name)
    }

    pub fn dept(&self, id: &str) -> Option<&Dept> {
        self.depts.iter().find(|d| d.id == id)
    }

    fn worst(&self) -> Cell {
        self.depts.iter().map(|d| d.cell).min().unwrap_or_default()
    }

    /// Overview's Needs you groups for the departments: one per department with a need that is
    /// not ok (kind `dept:<id>`, its items those needs, worst first), red departments before
    /// amber ones, page order within a level. Both surfaces append them after the work's groups.
    pub fn need_groups(&self) -> Vec<crate::page::NeedGroup> {
        let mut out: Vec<(Level, crate::page::NeedGroup)> = self
            .depts
            .iter()
            .filter_map(|d| {
                let mut needs: Vec<&Need> =
                    d.needs.iter().filter(|n| n.level != Level::Ok).collect();
                needs.sort_by_key(|n| n.level);
                let worst = needs.first()?.level;
                Some((
                    worst,
                    crate::page::NeedGroup {
                        kind: format!("dept:{}", d.id),
                        says: format!("{}: {}", d.title, needs.len()),
                        items: needs.iter().map(|n| n.says.clone()).collect(),
                    },
                ))
            })
            .collect();
        out.sort_by_key(|(l, _)| *l);
        out.into_iter().map(|(_, g)| g).collect()
    }
}

impl Row for Product {
    const COLUMNS: &'static [&'static str] = &[
        "project",
        "type",
        "stage",
        "product",
        "engineering",
        "ops",
        "design",
        "analytics",
        "marketing",
        "legal",
        "support",
        "money",
    ];
    const STATES: &'static [&'static str] = &["all", "red", "amber", "off"];
    const FACETS: &'static [&'static str] = &["type", "stage"];
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["stage", "legal", "money"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            "ok",
            "the product's own sources feed it and none is missing",
        ),
        ("amber", "a gap its stage does not require yet"),
        (
            "red",
            "a gap, and its stage requires the department (stages.md)",
        ),
        (
            "off",
            "nothing of the product's own feeds it, and nothing is due",
        ),
    ];
    const TONES: &'static [(&'static str, Level)] = &[
        ("red", Level::Bad),
        ("amber", Level::Warn),
        ("ok", Level::Ok),
    ];

    fn val(&self, col: &str) -> Val {
        let word = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "project" => word(&self.name),
            "type" => word(&self.kind),
            "stage" => word(&self.stage),
            d => self
                .dept(d)
                .map_or(Val::None, |d| Val::Text(d.cell.word().into())),
        }
    }

    /// Under a chip when any of its cells is in that state.
    fn in_state(&self, s: &str) -> bool {
        self.depts.iter().any(|d| d.cell.word() == s)
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            "stage" => self.stage_rank.map_or(Val::None, |r| Val::Num(r as f64)),
            "project" | "type" => self.val(col),
            d => self
                .dept(d)
                .map_or(Val::None, |d| Val::Num(d.cell as u8 as f64)),
        }
    }

    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "project" => Some(Link::to(Kind::Project, self.key())),
            d if self.dept(d).is_some() => Some(Link::to(
                Kind::Project,
                format!("{}/{}/{d}", self.key(), crate::layout::DEPT_TAB),
            )),
            _ => None,
        }
    }
}

/// The grid and every product's tabs.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Coverage {
    pub products: Vec<Product>,
    /// stages.md's Departments table, in its order: the grid's cell columns and each tab's words.
    pub departments: Vec<Department>,
    /// Cells in each state over the whole grid: the head's `2 red | 14 off`.
    pub red: usize,
    pub amber: usize,
    pub off: usize,
    /// Why the grid is partial or empty (a store not read), one sentence per store.
    pub says: Vec<String>,
}

impl Coverage {
    /// The product a page key names: `<profile>/<name>`, or a bare name.
    pub fn product(&self, key: &str) -> Option<&Product> {
        self.products
            .iter()
            .find(|p| p.key() == key)
            .or_else(|| self.products.iter().find(|p| p.name == key))
    }

    /// The head line both surfaces print: `2 red | 14 off`, or what could not be read.
    pub fn head(&self) -> String {
        let mut parts = vec![];
        if self.red > 0 {
            parts.push(format!("{} red", self.red));
        }
        if self.amber > 0 {
            parts.push(format!("{} amber", self.amber));
        }
        parts.push(format!("{} off", self.off));
        parts.join("  |  ")
    }

    /// Products with a red cell: the Coverage strip's count on both surfaces.
    pub fn failing(&self) -> usize {
        self.products
            .iter()
            .filter(|p| p.depts.iter().any(|d| d.cell == Cell::Red))
            .count()
    }
}

/// What one read gathered, handed to [`build`] so a test can feed each store.
pub struct Inputs<'a> {
    pub registry: Option<&'a Registry>,
    /// The lab cards: profile, name and stage.
    pub cards: Result<Vec<(String, String, String)>, String>,
    pub catalog: Result<String, String>,
    /// stages.md: its Requirements rows and its Departments table.
    pub requirements: Result<Reqs, String>,
    pub numbers: Result<Vec<Series>, String>,
    pub ci: Option<CiState>,
    pub grafana: Option<String>,
    /// The clock a review's wait and the 30-day window are measured at.
    pub now: i64,
}

/// Reads every store and builds the grid. URL probes run in parallel through `runner`'s curl.
pub fn read(runner: &(dyn Runner + Sync), paths: &Paths) -> Coverage {
    let registry = project_map::cached();
    let (cards, requirements, numbers) = std::thread::scope(|s| {
        let cards = s.spawn(|| {
            crate::projects::stats(runner).map(|st| {
                st.into_iter()
                    .map(|c| (c.profile, c.name, c.stage))
                    .collect()
            })
        });
        let reqs = s.spawn(|| crate::stages::standard(runner));
        let nums = s.spawn(|| crate::prom::vm(runner, "kb_project_number", None));
        fn join<T>(r: std::thread::Result<Result<T, String>>, what: &str) -> Result<T, String> {
            r.unwrap_or_else(|_| Err(format!("{what} panicked")))
        }
        (
            join(cards.join(), "notes projects"),
            join(reqs.join(), "project-stage-check"),
            join(nums.join(), "kb_project_number"),
        )
    });
    let ci = std::fs::read_to_string(&paths.ci)
        .ok()
        .and_then(|t| crate::schedules::ci_state(&t).ok());
    let inputs = Inputs {
        registry: registry.as_deref(),
        cards,
        catalog: std::fs::read_to_string(&paths.catalog)
            .map_err(|e| format!("{}: {e}", paths.catalog.display())),
        requirements,
        numbers,
        ci,
        grafana: crate::infra::grafana(),
        now: chrono::Utc::now().timestamp(),
    };
    build(&inputs, paths, &|url: &str| probe(runner, url))
}

/// The HTTP status `url` answers with, redirects followed.
fn probe(runner: &dyn Runner, url: &str) -> Result<u16, String> {
    let out = runner.run(&crate::session_actions::argv(&[
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "-m",
        PROBE_SECS,
        "-L",
        url,
    ]))?;
    out.trim()
        .parse::<u16>()
        .ok()
        .filter(|c| *c > 0)
        .ok_or_else(|| format!("no answer from {url}"))
}

/// A probe's words: met on 2xx or 3xx.
fn probed(code: &Result<u16, String>) -> (bool, String) {
    match code {
        Ok(c) if (200..400).contains(c) => (true, format!("answers {c}")),
        Ok(c) => (false, format!("answers {c}")),
        Err(e) => (false, e.clone()),
    }
}

/// The grid from what each store answered.
pub fn build(
    inputs: &Inputs,
    paths: &Paths,
    probe: &(dyn Fn(&str) -> Result<u16, String> + Sync),
) -> Coverage {
    let mut out = Coverage::default();
    let Some(reg) = inputs.registry else {
        out.says
            .push(State::NotRead("project-map.json".into()).sentence("project map"));
        return out;
    };
    let cards = match &inputs.cards {
        Ok(c) => c,
        Err(e) => {
            out.says
                .push(State::NotRead(e.clone()).sentence("projects"));
            return out;
        }
    };
    let rows = match &inputs.catalog {
        Ok(t) => catalog(t),
        Err(e) => {
            out.says.push(State::NotRead(e.clone()).sentence("catalog"));
            vec![]
        }
    };
    match &inputs.requirements {
        Err(e) => out
            .says
            .push(State::NotRead(e.clone()).sentence("requirements")),
        // An older project-stage-check sends no Departments table: say so, never a blank grid.
        Ok(r) if r.departments.is_empty() => out.says.push(
            State::NotRead("project-stage-check sent no Departments table".into())
                .sentence("departments"),
        ),
        Ok(_) => {}
    }
    if let Err(e) = &inputs.numbers {
        out.says.push(State::NotRead(e.clone()).sentence("numbers"));
    }

    // The projects with department tabs, in the lab's own order: every typed one.
    let products: Vec<(&str, &str, &str, String, String)> = cards
        .iter()
        .filter_map(|(profile, name, stage)| {
            let key = reg.lookup(name).unwrap_or(name).to_string();
            let kind = reg.kind(&key)?;
            Some((profile.as_str(), name.as_str(), stage.as_str(), key, kind))
        })
        .collect();

    // Each source is looked up once, however many products list it.
    let mut found: BTreeMap<(String, String), Found> = BTreeMap::new();
    for r in &rows {
        found
            .entry((r.kind.clone(), r.source.clone()))
            .or_insert_with(|| look(paths, reg, inputs.ci.as_ref(), &r.kind, &r.source));
    }

    // The Legal evidence, then every URL it names probed once, in parallel.
    let legal: Vec<Vec<Pending>> = products
        .iter()
        .map(|(_, _, _, key, kind)| legal_checks(reg, key, kind))
        .collect();
    let urls: BTreeSet<String> = legal
        .iter()
        .flatten()
        .filter_map(|p| match p {
            Pending::Probe { url, .. } => Some(url.clone()),
            Pending::Done(_) => None,
        })
        .collect();
    let codes: BTreeMap<String, Result<u16, String>> = std::thread::scope(|s| {
        let handles: Vec<_> = urls
            .iter()
            .map(|u| (u.clone(), s.spawn(move || probe(u))))
            .collect();
        handles
            .into_iter()
            .map(|(u, h)| {
                (
                    u,
                    h.join()
                        .unwrap_or_else(|_| Err("the probe panicked".to_string())),
                )
            })
            .collect()
    });

    let numbers = inputs.numbers.as_ref().ok();
    let (departments, reqs) = inputs
        .requirements
        .as_ref()
        .map_or((&[][..], &[][..]), |r| {
            (&r.departments[..], &r.requirements[..])
        });
    out.departments = departments.to_vec();
    for ((profile, name, stage, key, kind), pending) in products.iter().zip(legal) {
        let rank = LADDER.iter().position(|s| s == stage);
        let repo = tracker_field(reg, key, "repo");
        let mut checks: Vec<Check> = pending.into_iter().map(|p| p.finish(&codes)).collect();
        let grafana = inputs.grafana.as_deref().map(|g| {
            format!(
                "{g}/d/{DASHBOARD}?var-project={}",
                crate::kube_proxy::encode(key)
            )
        });
        let depts = departments
            .iter()
            .filter(|d| applies(kind, &d.id))
            .map(|d| {
                let pipes = rows
                    .iter()
                    .filter(|r| r.dept == d.id)
                    .filter(|r| {
                        r.project == "*"
                            || r.project == *key
                            || (!repo.is_empty() && r.project == repo)
                    })
                    .map(|r| pipe(r, &found[&(r.kind.clone(), r.source.clone())]))
                    .collect();
                let nums = numbers.map(|n| numbers_of(n, key, &d.id));
                let legal = if d.id == "legal" {
                    std::mem::take(&mut checks)
                } else {
                    vec![]
                };
                let due = due_at(d, kind, reqs);
                let ledger = if d.id == "marketing" {
                    outbound::read(&paths.outbound, key)
                } else {
                    Ok(vec![])
                };
                let own = Own {
                    pipes,
                    checks: legal,
                    numbers: nums,
                    ledger,
                };
                dept(d, due, rank, own, grafana.clone(), inputs.now)
            })
            .collect();
        out.products.push(Product {
            profile: profile.to_string(),
            name: name.to_string(),
            stage: stage.to_string(),
            kind: kind.clone(),
            stage_rank: rank,
            depts,
        });
    }
    for p in &out.products {
        for d in &p.depts {
            match d.cell {
                Cell::Red => out.red += 1,
                Cell::Amber => out.amber += 1,
                Cell::Off => out.off += 1,
                Cell::Ok => {}
            }
        }
    }
    // Worst first; the lab's order within a state.
    out.products.sort_by_key(Product::worst);
    out
}

/// A string field of the product's project-map tracker, empty when unset.
fn tracker_field(reg: &Registry, key: &str, k: &str) -> String {
    reg.tracker(key)
        .and_then(|t| t.get(k))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// The earliest stage a requirement of `d` names for `kind`, by the ladder: a row of its `Dept`
/// that applies to every project (`base`) or to the type.
fn due_at(d: &Department, kind: &str, reqs: &[Requirement]) -> Option<usize> {
    reqs.iter()
        .filter(|r| r.dept == d.id)
        .filter(|r| r.applies.iter().any(|a| a == "base" || a == kind))
        .filter_map(|r| LADDER.iter().position(|s| *s == r.stage))
        .min()
}

/// What feeds one department of one product.
struct Own {
    pipes: Vec<Pipe>,
    checks: Vec<Check>,
    numbers: Option<Vec<Number>>,
    /// The product's outbound items, read for Marketing only.
    ledger: Result<Vec<Item>, String>,
}

fn dept(
    d: &Department,
    due: Option<usize>,
    rank: Option<usize>,
    own: Own,
    grafana: Option<String>,
    now: i64,
) -> Dept {
    let Own {
        pipes,
        mut checks,
        numbers,
        ledger,
    } = own;
    let required = matches!((due, rank), (Some(due), Some(r)) if r >= due);
    let level = if required { Level::Bad } else { Level::Warn };
    let mut needs = vec![];
    for p in pipes.iter().filter(|p| !p.shared && p.found == MISSING) {
        needs.push(Need {
            level,
            says: format!("{} {} is missing", p.kind, p.source),
        });
    }
    for c in checks.iter_mut().filter(|c| c.state == GAP) {
        c.level = level;
        needs.push(Need {
            level,
            says: format!("{}: {}", c.item, c.says),
        });
    }
    let (items, outbound_says) = match ledger {
        Ok(i) => (i, String::new()),
        Err(e) => (vec![], State::NotRead(e).sentence("outbound ledger")),
    };
    needs.extend(ledger_needs(&items, now));
    let fed = pipes.iter().any(|p| !p.shared && p.found == FOUND)
        || checks.iter().any(|c| c.state == MET)
        || numbers.as_ref().is_some_and(|n| !n.is_empty())
        || !items.is_empty();
    if required && !fed && needs.is_empty() {
        needs.push(Need {
            level,
            says: format!(
                "nothing of its own feeds {}, and {} requires it",
                d.title,
                LADDER[due.unwrap_or_default()]
            ),
        });
    }
    // The worst need colors the cell: a Bad need is red, a Warn one (a stale review) amber.
    needs.sort_by_key(|n| n.level);
    let cell = match (needs.first().map(|n| n.level), fed) {
        (Some(Level::Bad), _) => Cell::Red,
        (Some(_), _) => Cell::Amber,
        (None, true) => Cell::Ok,
        (None, false) => Cell::Off,
    };
    let numbers_says = match &numbers {
        None => reading::NOT_READ.to_string(),
        Some(n) if n.is_empty() => reading::NO_DATA.to_string(),
        Some(_) => String::new(),
    };
    Dept {
        id: d.id.clone(),
        title: d.title.clone(),
        question: d.question.clone(),
        cell,
        due_at: due.map(|i| LADDER[i].to_string()),
        required,
        needs,
        numbers: numbers.unwrap_or_default(),
        numbers_says,
        pipes,
        checks,
        grafana,
        outbound: outbound::shown(&items, now),
        outbound_says,
    }
}

/// What the ledger asks of the human: each draft that has waited `STALE_DAYS` on review (a
/// fresh one is on Waiting and in Outbound), and each one approved for a hand post.
fn ledger_needs(items: &[Item], now: i64) -> Vec<Need> {
    let mut out = vec![];
    for i in items {
        let what = format!("{} \"{}\" on {}", i.kind, i.title, i.channel);
        match (i.state, i.waited_days(now)) {
            ("review", Some(w)) if w >= outbound::STALE_DAYS => out.push(Need {
                level: Level::Warn,
                says: format!("{what} has waited {w} days on your review (ask {})", i.ask),
            }),
            ("approved", _) if i.verdict == "hand" => out.push(Need {
                level: Level::Warn,
                says: format!(
                    "{what} is approved: post it by hand, then: mkt log {} <url>",
                    i.id
                ),
            }),
            _ => {}
        }
    }
    out
}

fn numbers_of(series: &[Series], project: &str, dept: &str) -> Vec<Number> {
    let mut out: Vec<Number> = series
        .iter()
        .filter(|s| s.label("project") == project && s.label("dept") == dept)
        .filter_map(|s| {
            let metric = s.label("metric").to_string();
            let value = s.value?;
            Some(Number {
                says: number_says(value),
                metric,
                value,
            })
        })
        .collect();
    out.sort_by(|a, b| a.metric.cmp(&b.metric));
    out
}

fn number_says(v: f64) -> String {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        format!("{v:.2}")
    }
}

/// A source as this machine finds it, and its last run.
#[derive(Clone, Debug, Default)]
struct Found {
    found: &'static str,
    last: Option<i64>,
    verdict: String,
}

fn pipe(r: &Source, f: &Found) -> Pipe {
    let level = match (f.found, f.verdict.to_ascii_lowercase().as_str()) {
        (MISSING, _) => Level::Bad,
        (_, "failed" | "failure" | "stalled") => Level::Bad,
        (_, "blocked" | "cancelled" | "timed_out") => Level::Warn,
        _ => Level::Ok,
    };
    Pipe {
        source: r.source.clone(),
        kind: r.kind.clone(),
        record: r.record.clone(),
        shared: r.project == "*",
        found: f.found,
        last: f.last,
        last_says: match (f.found, f.last) {
            (FOUND, Some(t)) if r.kind == "file" => format!("changed {}", reading::hm(t)),
            (FOUND, Some(t)) => format!("ran {}", reading::hm(t)),
            (FOUND, None) if matches!(r.kind.as_str(), "runner" | "workflow") => {
                "no run yet".into()
            }
            (FOUND, None) => String::new(),
            (w, _) => w.to_string(),
        },
        verdict: f.verdict.clone(),
        level,
    }
}

fn mtime(p: &Path) -> Option<i64> {
    let t = std::fs::metadata(p).ok()?.modified().ok()?;
    t.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_secs()).ok())
}

/// A source's state, the rules `tests/unit/departments_catalog.bats` checks the catalog by,
/// over the deployed paths.
fn look(paths: &Paths, reg: &Registry, ci: Option<&CiState>, kind: &str, src: &str) -> Found {
    let word = |found: &'static str| Found {
        found,
        ..Default::default()
    };
    let have = |ok: bool| word(if ok { FOUND } else { MISSING });
    match kind {
        "runner" => {
            if !paths.agents.join(format!("{src}.conf")).is_file() {
                return have(false);
            }
            let out = paths.state.join(src).join("last-outcome");
            Found {
                found: FOUND,
                last: mtime(&out),
                verdict: std::fs::read_to_string(&out)
                    .map(|t| t.trim().to_string())
                    .unwrap_or_default(),
            }
        }
        "skill" => {
            let flat = paths.skills.join(src).join("SKILL.md").is_file();
            have(flat || !glob(&paths.skills.join("*").join(src).join("SKILL.md")).is_empty())
        }
        "exporter" => have(is_executable(&paths.bin.join(src))),
        "workflow" => {
            let Some((repo, file)) = src.split_once(':') else {
                return have(false);
            };
            let Some(dir) = reg.checkout(repo) else {
                return word(NOT_CLONED);
            };
            let here = [".github/workflows", ".forgejo/workflows"]
                .iter()
                .any(|w| dir.join(w).join(file).is_file());
            if !here {
                return have(false);
            }
            let (last, verdict) = last_workflow_run(reg, ci, repo, file);
            Found {
                found: FOUND,
                last,
                verdict,
            }
        }
        "file" => {
            let (path, tag) = match src.split_once('#') {
                Some((p, t)) => (p, Some(t)),
                None => (src, None),
            };
            let full = if let Some(rest) = path.strip_prefix("~/") {
                if rest.starts_with(".notes/") && !paths.home.join(".notes").is_dir() {
                    return word(NOT_CLONED);
                }
                paths.home.join(rest)
            } else if let Some((repo, rel)) = path.split_once(':') {
                match reg.checkout(repo) {
                    Some(d) => d.join(rel),
                    None => return word(NOT_CLONED),
                }
            } else {
                return have(false);
            };
            let hits = glob(&full);
            let tagged = |p: &PathBuf| {
                tag.is_none_or(|t| {
                    std::fs::read_to_string(p).is_ok_and(|s| s.contains(&format!("`{t}`")))
                })
            };
            if hits.is_empty() || !hits.iter().all(tagged) {
                return have(false);
            }
            Found {
                found: FOUND,
                last: hits.iter().filter_map(|p| mtime(p)).max(),
                verdict: String::new(),
            }
        }
        _ => have(false),
    }
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The newest run of scheduled workflow `file` in repo key `repo`, from schedules-sync's state.
fn last_workflow_run(
    reg: &Registry,
    ci: Option<&CiState>,
    repo: &str,
    file: &str,
) -> (Option<i64>, String) {
    let slugs = reg.repos(repo);
    let Some(ci) = ci else {
        return (None, String::new());
    };
    let run = ci
        .repos
        .iter()
        .filter(|r| slugs.iter().any(|s| s.eq_ignore_ascii_case(&r.repo)))
        .flat_map(|r| &r.workflows)
        .filter(|w| Path::new(&w.path).file_name().and_then(|f| f.to_str()) == Some(file))
        .flat_map(|w| &w.runs)
        .filter_map(|r| {
            let at = crate::fleet::ts(r.created_at.as_deref()?)?;
            Some((at, r.conclusion.clone().unwrap_or_default()))
        })
        .max_by_key(|(t, _)| *t);
    run.map_or((None, String::new()), |(t, c)| (Some(t), c))
}

/// The paths a pattern names, `*` and `?` matched within one segment.
fn glob(pattern: &Path) -> Vec<PathBuf> {
    let mut have = vec![PathBuf::new()];
    for part in pattern.components() {
        let seg = part.as_os_str().to_string_lossy();
        if !seg.contains(['*', '?']) {
            have = have.into_iter().map(|p| p.join(part)).collect();
            continue;
        }
        let mut next = vec![];
        for dir in have {
            let Ok(rd) = std::fs::read_dir(&dir) else {
                continue;
            };
            let mut names: Vec<String> = rd
                .filter_map(|e| e.ok()?.file_name().into_string().ok())
                .filter(|n| wild(&seg, n))
                .collect();
            names.sort();
            next.extend(names.into_iter().map(|n| dir.join(n)));
        }
        have = next;
    }
    have.into_iter().filter(|p| p.exists()).collect()
}

/// Whether `name` matches `pat`, `*` any run and `?` any one character.
fn wild(pat: &str, name: &str) -> bool {
    let (p, n): (Vec<char>, Vec<char>) = (pat.chars().collect(), name.chars().collect());
    let (mut i, mut j, mut star, mut mark) = (0, 0, None, 0);
    while j < n.len() {
        if i < p.len() && (p[i] == '?' || p[i] == n[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == '*' {
            star = Some(i);
            mark = j;
            i += 1;
        } else if let Some(s) = star {
            i = s + 1;
            mark += 1;
            j = mark;
        } else {
            return false;
        }
    }
    p[i..].iter().all(|c| *c == '*')
}

/// A Legal item: settled from its file, or a URL still to probe.
enum Pending {
    Done(Check),
    Probe { item: &'static str, url: String },
}

impl Pending {
    fn finish(self, codes: &BTreeMap<String, Result<u16, String>>) -> Check {
        match self {
            Pending::Done(c) => c,
            Pending::Probe { item, url } => {
                let (ok, says) = codes
                    .get(&url)
                    .map_or((false, reading::NOT_READ.to_string()), probed);
                Check {
                    item,
                    state: if ok { MET } else { GAP },
                    says,
                    evidence: url,
                    ..Default::default()
                }
            }
        }
    }
}

fn settled(item: &'static str, state: &'static str, says: &str, evidence: &str) -> Pending {
    Pending::Done(Check {
        item,
        state,
        says: says.to_string(),
        evidence: evidence.to_string(),
        ..Default::default()
    })
}

/// A URL item: probed when the key is set, a gap naming the key when it is not.
fn url_item(item: &'static str, key: &str, url: Option<String>, file: &str) -> Pending {
    match url.filter(|u| u.starts_with("https://") || u.starts_with("http://")) {
        Some(url) => Pending::Probe { item, url },
        None => settled(item, GAP, &format!("no {key} in {file}"), file),
    }
}

/// The Legal checklist for one product, from the files that hold its facts today: none when
/// the product has no store file yet (its tab then says what is due, not what fails).
fn legal_checks(reg: &Registry, key: &str, kind: &str) -> Vec<Pending> {
    let (repo, path) = (
        tracker_field(reg, key, "repo"),
        tracker_field(reg, key, "path"),
    );
    let licences = settled("licences", NOT_YET, "no licence check exists yet", "");
    match kind {
        "game" => {
            let Some(dir) = reg.checkout(if repo.is_empty() { key } else { &repo }) else {
                return vec![];
            };
            // The store id is the game folder's name, lowercased (stages.md, Content rating).
            let id = Path::new(&path)
                .file_name()
                .and_then(|f| f.to_str())
                .map_or_else(|| key.to_string(), str::to_ascii_lowercase);
            let game = dir.join("store").join(&id).join("game.json");
            let Ok(text) = std::fs::read_to_string(&game) else {
                return vec![];
            };
            let rel = format!("store/{id}/game.json");
            let v: Value = serde_json::from_str(&text).unwrap_or_default();
            let studio: Value = std::fs::read_to_string(dir.join("store/studio.json"))
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or_default();
            let url = |k: &str| studio.get(k).and_then(Value::as_str).map(str::to_string);
            let count = |p: &str| v.pointer(p).and_then(Value::as_array).map(Vec::len);
            vec![
                match count("/rating/answers") {
                    Some(n) if n > 0 => settled("rating", MET, &format!("{n} answers"), &rel),
                    _ => settled("rating", GAP, "rating.answers is empty", &rel),
                },
                match count("/data/collected") {
                    Some(n) => settled("data collected", MET, &format!("{n} kinds"), &rel),
                    None => settled("data collected", GAP, "data.collected is absent", &rel),
                },
                url_item(
                    "privacy",
                    "privacyUrl",
                    url("privacyUrl"),
                    "store/studio.json",
                ),
                url_item("terms", "termsUrl", url("termsUrl"), "store/studio.json"),
                licences,
            ]
        }
        "app" => {
            let Some(dir) = (!repo.is_empty()).then(|| reg.checkout(&repo)).flatten() else {
                return vec![];
            };
            // An empty path is the repo root, where a format! would make the path absolute.
            let rel = Path::new(&path).join("mobile/metadata.yaml");
            let Ok(text) = std::fs::read_to_string(dir.join(&rel)) else {
                return vec![];
            };
            let rel = rel.to_string_lossy();
            let url = |k: &str| yaml_scalar(&text, k);
            vec![
                url_item("privacy", "privacyUrl", url("privacyUrl"), &rel),
                url_item("support", "supportUrl", url("supportUrl"), &rel),
                url_item("terms", "termsUrl", url("termsUrl"), &rel),
                licences,
            ]
        }
        _ => vec![],
    }
}

/// A top-level `key: value` of a YAML file, a ` #` comment and quotes dropped; enough for
/// metadata.yaml's URLs.
fn yaml_scalar(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let v = l.strip_prefix(key)?.strip_prefix(':')?;
        let v = v.split(" #").next().unwrap_or(v).trim();
        let v = v.trim_matches(|c| c == '\'' || c == '"');
        (!v.is_empty()).then(|| v.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn need_groups_put_each_departments_needs_on_overview_red_first() {
        let need = |level, says: &str| Need {
            level,
            says: says.into(),
        };
        let dept = |id: &str, title: &str, needs| Dept {
            id: id.into(),
            title: title.into(),
            needs,
            ..Default::default()
        };
        let p = Product {
            depts: vec![
                dept("product", "Product", vec![]),
                dept(
                    "marketing",
                    "Marketing",
                    vec![need(Level::Warn, "post waited 9 days")],
                ),
                dept(
                    "legal",
                    "Legal",
                    vec![
                        need(Level::Warn, "no terms"),
                        need(Level::Bad, "no privacyUrl"),
                    ],
                ),
                dept(
                    "support",
                    "Support",
                    vec![need(Level::Ok, "intake is set up")],
                ),
            ],
            ..Default::default()
        };
        let got: Vec<_> = p
            .need_groups()
            .into_iter()
            .map(|g| (g.kind, g.says, g.items))
            .collect();
        assert_eq!(
            got,
            [
                (
                    "dept:legal".into(),
                    "Legal: 2".into(),
                    vec!["no privacyUrl".to_string(), "no terms".into()]
                ),
                (
                    "dept:marketing".into(),
                    "Marketing: 1".into(),
                    vec!["post waited 9 days".to_string()]
                ),
            ],
            "red before amber, worst need first; an ok need and an empty department add no group"
        );
        assert!(Product::default().need_groups().is_empty());
    }

    #[test]
    fn a_departments_tab_count_is_its_needs_that_are_not_ok_and_overview_adds_them_to_the_works() {
        let need = |level| Need {
            level,
            says: "x".into(),
        };
        let p = Product {
            depts: vec![
                Dept {
                    id: "legal".into(),
                    needs: vec![need(Level::Warn), need(Level::Bad), need(Level::Ok)],
                    ..Default::default()
                },
                Dept {
                    id: "product".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(p.open_needs()["legal"], 2);
        assert_eq!(p.open_needs()["product"], 0);
        let mut page = crate::page::Page {
            need_groups: vec![crate::page::NeedGroup {
                kind: "verify".into(),
                says: String::new(),
                items: vec!["a".into(), "b".into(), "c".into()],
            }],
            ..Default::default()
        };
        assert_eq!(page.overview_needs(None), 3);
        page.with_department_needs(Some(&p));
        assert_eq!(page.need_count, 5, "three of the work, two of Legal");
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hub-departments-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn paths(root: &Path) -> Paths {
        Paths {
            catalog: root.join("departments.tsv"),
            agents: root.join("agents"),
            state: root.join("state"),
            skills: root.join("skills"),
            bin: root.join("bin"),
            home: root.join("home"),
            ci: root.join("ci.json"),
            outbound: root.join("outbound"),
        }
    }

    fn req(dept: &str, stage: &str, applies: &[&str], text: &str) -> Requirement {
        Requirement {
            dept: dept.into(),
            stage: stage.into(),
            applies: applies.iter().map(|a| a.to_string()).collect(),
            requirement: text.into(),
            ..Default::default()
        }
    }

    /// The Departments table of the shipped stages.md, with these Requirements rows.
    fn reqs() -> Reqs {
        Reqs {
            departments: crate::stages::stages_md_departments(),
            requirements: vec![
                req(
                    "analytics",
                    "alpha",
                    &["game", "app"],
                    "An event catalogue: each event",
                ),
                req("legal", "beta", &["game"], "Content rating done: answers"),
                req(
                    "legal",
                    "beta",
                    &["app"],
                    "A privacy and compliance check when",
                ),
                req(
                    "money",
                    "beta",
                    &["game", "app"],
                    "Costs recorded per product: hosting",
                ),
                req(
                    "engineering",
                    "dev",
                    &["base"],
                    "CI green on the default branch",
                ),
                req("ops", "alpha", &["base"], "A deploy workflow green"),
            ],
            ..Default::default()
        }
    }

    fn registry(mono: &Path) -> Registry {
        Registry::parse(&format!(
            r#"{{"paths": {{"{}": "mono"}},
                 "trackers": {{
                   "quiet": {{"type": "app"}},
                   "listed": {{"type": "app", "repo": "mono", "path": "apps/listed"}},
                   "plumbing": {{"type": "infra"}},
                   "untyped": {{}}
                 }}}}"#,
            mono.display()
        ))
        .unwrap()
    }

    fn inputs<'a>(reg: &'a Registry, cards: &[(&str, &str)], catalog: &str) -> Inputs<'a> {
        Inputs {
            registry: Some(reg),
            cards: Ok(cards
                .iter()
                .map(|(n, s)| ("bnb".to_string(), n.to_string(), s.to_string()))
                .collect()),
            catalog: Ok(catalog.into()),
            requirements: Ok(reqs()),
            numbers: Ok(vec![]),
            ci: None,
            grafana: Some("https://grafana.test".into()),
            now: 1_794_787_200,
        }
    }

    const SHARED: &str = "marketing\tstore-console\tskill\t*\tthe listing\n";

    #[test]
    fn a_product_with_no_sources_is_off_in_every_cell_and_infra_has_only_engineering_and_ops() {
        let root = tmp("quiet");
        let reg = registry(&root.join("mono"));
        let cov = build(
            &inputs(
                &reg,
                &[("quiet", "draft"), ("plumbing", "dev"), ("untyped", "dev")],
                SHARED,
            ),
            &paths(&root),
            &|_| panic!("nothing to probe"),
        );
        assert_eq!(cov.products.len(), 2, "a project with no type has no row");
        assert_eq!(cov.departments.len(), 9);
        let p = cov.product("quiet").unwrap();
        assert_eq!(p.depts.len(), 9, "a product has every department");
        for d in &p.depts {
            assert_eq!(d.cell, Cell::Off, "{}", d.id);
            assert!(d.needs.is_empty(), "{}", d.id);
            assert_eq!(d.numbers_says, reading::NO_DATA);
        }
        // A `*` row is listed, missing or not, and never counts as the product's feed.
        let m = p.dept("marketing").unwrap();
        assert_eq!(m.pipes.len(), 1);
        assert!(m.pipes[0].shared);
        assert_eq!(
            m.grafana.as_deref(),
            Some("https://grafana.test/d/kb-project?var-project=quiet")
        );
        // Infra has engineering and ops only; its base `dev` row makes Engineering due and red.
        let i = cov.product("plumbing").unwrap();
        let ids: Vec<&str> = i.depts.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids, ["engineering", "ops"]);
        assert_eq!(i.dept("engineering").unwrap().cell, Cell::Red);
        assert_eq!(i.dept("ops").unwrap().cell, Cell::Off);
        assert!(i.dept("legal").is_none());
        assert_eq!((cov.red, cov.amber, cov.off), (1, 0, 10));
        assert_eq!(cov.head(), "1 red  |  10 off");
        let _ = std::fs::remove_dir_all(&root);
    }
    #[test]
    fn requirements_with_no_departments_table_say_so_and_never_draw_a_blank_grid() {
        let root = tmp("nodepts");
        let reg = registry(&root.join("mono"));
        let mut i = inputs(&reg, &[("quiet", "beta")], "");
        i.requirements = Ok(Reqs {
            requirements: reqs().requirements,
            ..Default::default()
        });
        let cov = build(&i, &paths(&root), &|_| Ok(200));
        assert!(
            cov.says.iter().any(|s| s.contains("no Departments table")),
            "{:?}",
            cov.says
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_reworded_requirement_keeps_its_department_and_a_wrong_dept_does_not_count() {
        let root = tmp("reworded");
        let reg = registry(&root.join("mono"));
        let build_with = |reqs: Reqs| {
            let mut i = inputs(&reg, &[("quiet", "beta")], "");
            i.requirements = Ok(reqs);
            build(&i, &paths(&root), &|_| panic!("nothing to probe"))
        };
        let due = |cov: &Coverage, id: &str| cov.products[0].dept(id).unwrap().due_at.clone();
        // The Legal row's words start with nothing the old prefix list knew: its Dept cell is all.
        let mut r = reqs();
        r.requirements
            .iter_mut()
            .find(|r| r.requirement.starts_with("A privacy and compliance"))
            .unwrap()
            .requirement = "Rewritten from scratch".into();
        assert_eq!(due(&build_with(r), "legal").as_deref(), Some("beta"));
        // NEGATIVE CONTROL: the same row under another Dept makes that one due, not Legal.
        let mut r = reqs();
        r.requirements
            .iter_mut()
            .find(|r| r.requirement.starts_with("A privacy and compliance"))
            .unwrap()
            .dept = "support".into();
        let cov = build_with(r);
        assert_eq!(due(&cov, "legal"), None);
        assert_eq!(due(&cov, "support").as_deref(), Some("beta"));
        // A base row reaches an app (engineering, `dev`), and a row of another type does not.
        assert_eq!(due(&cov, "engineering").as_deref(), Some("dev"));
        assert_eq!(due(&cov, "product"), None, "no product row in the fixture");
        let _ = std::fs::remove_dir_all(&root);
    }
    #[test]
    fn the_ledger_feeds_marketing_and_a_review_waiting_a_week_turns_it_amber() {
        let root = tmp("ledger");
        let reg = registry(&root.join("mono"));
        let book = root.join("outbound/quiet");
        std::fs::create_dir_all(&book).unwrap();
        let ev = |ts: &str, id: &str, ev: &str, rest: &str| {
            format!("{{\"ts\":\"{ts}\",\"id\":\"{id}\",\"event\":\"{ev}\"{rest}}}\n")
        };
        let draft = |ts: &str, id: &str, title: &str| {
            ev(ts, id, "draft", &format!(",\"project\":\"quiet\",\"channel\":\"reddit\",\"kind\":\"post\",\"title\":\"{title}\""))
        };
        let write = |text: &str| std::fs::write(book.join("2026-11.jsonl"), text).unwrap();
        let marketing = || {
            let cov = build(
                &inputs(&reg, &[("quiet", "draft")], ""),
                &paths(&root),
                &|_| panic!("nothing to probe"),
            );
            let p = &cov.products[0];
            assert_eq!(
                p.dept("analytics").unwrap().cell,
                Cell::Off,
                "only Marketing reads it"
            );
            p.dept("marketing").unwrap().clone()
        };
        let fresh = draft("2026-11-15T10:00:00Z", "261115-aaaaaa", "devlog")
            + &ev(
                "2026-11-15T10:00:01Z",
                "261115-aaaaaa",
                "review",
                ",\"ask\":\"Ab12Cd\"",
            );
        write(&fresh);
        let m = marketing();
        assert_eq!(
            m.cell,
            Cell::Ok,
            "a fresh review feeds Marketing and is not a gap"
        );
        assert!(m.needs.is_empty());
        assert_eq!(m.outbound.len(), 1);

        let stale = draft("2026-11-05T10:00:00Z", "261105-bbbbbb", "clip")
            + &ev(
                "2026-11-05T10:00:01Z",
                "261105-bbbbbb",
                "review",
                ",\"ask\":\"Ef34Gh\"",
            )
            + &draft("2026-11-14T10:00:00Z", "261114-cccccc", "page")
            + &ev(
                "2026-11-14T10:00:01Z",
                "261114-cccccc",
                "verdict",
                ",\"verdict\":\"hand\"",
            );
        write(&(fresh + &stale));
        let m = marketing();
        assert_eq!(m.cell, Cell::Amber);
        let says: Vec<&str> = m.needs.iter().map(|n| n.says.as_str()).collect();
        assert!(
            says.contains(
                &"post \"clip\" on reddit has waited 10 days on your review (ask Ef34Gh)"
            ),
            "{says:?}"
        );
        assert!(
            says.contains(
                &"post \"page\" on reddit is approved: post it by hand, then: mkt log 261114-cccccc <url>"
            ),
            "{says:?}"
        );

        // negative control: an unreadable ledger is said, never a silent empty list
        std::fs::remove_dir_all(&book).unwrap();
        std::fs::write(&book, "not a dir").unwrap();
        let m = marketing();
        assert!(
            m.outbound_says.contains("outbound/quiet"),
            "{}",
            m.outbound_says
        );
        assert_eq!(m.cell, Cell::Off);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_missing_privacy_url_turns_legal_red_once_its_stage_requires_it() {
        let root = tmp("privacy");
        let mono = root.join("mono");
        let meta = mono.join("apps/listed/mobile");
        std::fs::create_dir_all(&meta).unwrap();
        std::fs::write(
            meta.join("metadata.yaml"),
            "name: 'Listed'\nsupportUrl: 'https://listed.test/support'\n",
        )
        .unwrap();
        let reg = registry(&mono);
        let probe = |u: &str| {
            assert_eq!(u, "https://listed.test/support", "only a set URL is probed");
            Ok(200)
        };
        let at = |stage: &str| {
            let cov = build(
                &inputs(&reg, &[("listed", stage)], ""),
                &paths(&root),
                &probe,
            );
            cov.products[0].dept("legal").unwrap().clone()
        };
        let beta = at("beta");
        assert_eq!(beta.cell, Cell::Red);
        assert!(beta.required);
        assert_eq!(beta.due_at.as_deref(), Some("beta"));
        let items: Vec<(&str, &str)> = beta.checks.iter().map(|c| (c.item, c.state)).collect();
        assert_eq!(
            items,
            [
                ("privacy", GAP),
                ("support", MET),
                ("terms", GAP),
                ("licences", NOT_YET)
            ]
        );
        assert_eq!(beta.needs[0].level, Level::Bad);
        assert!(
            beta.needs[0].says.contains("no privacyUrl"),
            "{:?}",
            beta.needs
        );
        // The same gap before beta is amber: nothing is due yet.
        assert_eq!(at("alpha").cell, Cell::Amber);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_due_department_with_nothing_of_its_own_is_red_and_numbers_feed_it() {
        let root = tmp("due");
        let reg = registry(&root.join("mono"));
        let mut i = inputs(&reg, &[("quiet", "beta")], "");
        let cov = build(&i, &paths(&root), &|_| Ok(200));
        let p = &cov.products[0];
        assert_eq!(p.dept("analytics").unwrap().cell, Cell::Red, "due at alpha");
        assert_eq!(
            p.dept("money").unwrap().cell,
            Cell::Red,
            "costs due at beta"
        );
        assert_eq!(
            p.dept("support").unwrap().cell,
            Cell::Off,
            "no row requires it here"
        );
        assert_eq!(
            cov.head(),
            "5 red  |  4 off",
            "analytics, money, legal, engineering and ops are due; the other four have no row"
        );
        let series = |dept: &str, metric: &str, v: f64| Series {
            labels: [("project", "quiet"), ("dept", dept), ("metric", metric)]
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            value: Some(v),
            points: vec![],
        };
        i.numbers = Ok(vec![series("analytics", "players_now", 3.0)]);
        let cov = build(&i, &paths(&root), &|_| Ok(200));
        let a = cov.products[0].dept("analytics").unwrap();
        assert_eq!(a.cell, Cell::Ok);
        assert_eq!(a.numbers[0].says, "3");
        i.numbers = Err("VictoriaMetrics down".into());
        let cov = build(&i, &paths(&root), &|_| Ok(200));
        assert_eq!(
            cov.products[0].dept("analytics").unwrap().numbers_says,
            reading::NOT_READ
        );
        assert!(cov.says.iter().any(|s| s.contains("VictoriaMetrics down")));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_own_source_feeds_its_department_and_a_missing_one_is_a_gap() {
        let root = tmp("own");
        let mono = root.join("mono");
        std::fs::create_dir_all(mono.join("docs")).unwrap();
        std::fs::write(mono.join("docs/events.ts"), "export const E = 1;\n").unwrap();
        std::fs::create_dir_all(root.join("agents")).unwrap();
        std::fs::write(root.join("agents/perf.conf"), "").unwrap();
        std::fs::create_dir_all(root.join("state/perf")).unwrap();
        std::fs::write(root.join("state/perf/last-outcome"), "WORKED\n").unwrap();
        let reg = registry(&mono);
        let cat = "analytics\tmono:docs/events.ts\tfile\tlisted\tevents\n\
                   analytics\tperf\trunner\tmono\tperf numbers\n\
                   support\tmono:docs/none-*.md\tfile\tlisted\tfeedback\n";
        let cov = build(
            &inputs(&reg, &[("listed", "draft")], cat),
            &paths(&root),
            &|_| Ok(200),
        );
        let p = &cov.products[0];
        let a = p.dept("analytics").unwrap();
        assert_eq!(a.cell, Cell::Ok);
        assert_eq!(a.pipes.len(), 2, "its own row and its repo's row");
        let runner = a.pipes.iter().find(|x| x.kind == "runner").unwrap();
        assert_eq!(runner.verdict, "WORKED");
        assert!(runner.last_says.starts_with("ran "), "{}", runner.last_says);
        let s = p.dept("support").unwrap();
        assert_eq!(s.cell, Cell::Amber, "a missing own source, nothing due");
        assert_eq!(s.pipes[0].found, MISSING);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_coverage_table_sorts_worst_first_and_links_each_cell_to_its_tab() {
        use crate::table::View;
        let root = tmp("table");
        let reg = registry(&root.join("mono"));
        let cov = build(
            &inputs(&reg, &[("quiet", "draft"), ("listed", "beta")], ""),
            &paths(&root),
            &|_| Ok(200),
        );
        assert_eq!(cov.products[0].name, "listed", "red rows lead");
        let (rows, _) = View::new::<Product>("", "red", "", "").summary(&cov.products);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            cov.products[0].link("legal").unwrap().href(),
            "#projects/bnb%2Flisted%2Fdepartments%2Flegal"
        );
        assert_eq!(
            cov.product("listed").map(|p| p.key()),
            Some("bnb/listed".into())
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_coverage_columns_are_the_departments_of_stages_md() {
        let ids: Vec<String> = crate::stages::stages_md_departments()
            .into_iter()
            .map(|d| d.id)
            .collect();
        let cols: Vec<&str> = Product::COLUMNS[3..].to_vec();
        assert_eq!(cols, ids, "a Departments row needs a Coverage column");
        // Every department an infra project has is one of them.
        for id in INFRA_DEPARTMENTS {
            assert!(
                ids.iter().any(|i| i == id),
                "{id} is no stages.md department"
            );
        }
    }

    #[test]
    fn a_yaml_url_drops_its_comment_and_only_a_web_url_is_probed() {
        let text =
            "privacyUrl: 'https://x.test/p'  # moved in May\ntermsUrl: https://x.test/t#top\n";
        assert_eq!(
            yaml_scalar(text, "privacyUrl").as_deref(),
            Some("https://x.test/p")
        );
        assert_eq!(
            yaml_scalar(text, "termsUrl").as_deref(),
            Some("https://x.test/t#top")
        );
        let probed = |u: &str| {
            matches!(
                url_item("privacy", "privacyUrl", Some(u.into()), "f"),
                Pending::Probe { .. }
            )
        };
        assert!(probed("https://x.test/p"));
        assert!(!probed("httpx://x.test/p"));
    }

    #[test]
    fn a_glob_matches_within_a_segment() {
        assert!(wild("*.json", "game.json"));
        assert!(wild("a?c*", "abcdef"));
        assert!(!wild("*.json", "game.yaml"));
        let root = tmp("glob");
        for g in ["one", "two"] {
            std::fs::create_dir_all(root.join(g)).unwrap();
            std::fs::write(root.join(g).join("game.json"), "{}").unwrap();
        }
        assert_eq!(glob(&root.join("*").join("game.json")).len(), 2);
        assert!(glob(&root.join("*").join("nope.json")).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_metadata_scalar_drops_its_quotes() {
        let t = "name: 'X'\nprivacyUrl: 'https://x.test/privacy'\nsupportUrl: \"https://x\"\n";
        assert_eq!(
            yaml_scalar(t, "privacyUrl").as_deref(),
            Some("https://x.test/privacy")
        );
        assert_eq!(yaml_scalar(t, "supportUrl").as_deref(), Some("https://x"));
        assert_eq!(yaml_scalar(t, "termsUrl"), None);
    }
}
