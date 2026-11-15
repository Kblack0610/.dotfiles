//! A product's department tabs and Projects > Coverage, both surfaces, from one read
//! (dashboards rule 8). Stores: pipelines from `~/.config/agentctl/departments.tsv` checked
//! against this machine, numbers from VictoriaMetrics `kb_project_number`, Legal from
//! `game.json` or `metadata.yaml` with each URL probed, and the stage that makes a department
//! due from stages.md. A cell is `ok` (fed, no gap), `amber` (a gap not due yet), `red` (a gap
//! its stage requires) or `off` (nothing feeds it, nothing due). Only the product's own
//! sources count: a `*` catalog row serves every product, so it is listed, never counted.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use project_map::Registry;
use serde::Serialize;
use serde_json::Value;

use crate::links::{Kind, Link};
use crate::prom::Series;
use crate::reading::{self, State};
use crate::schedules::CiState;
use crate::session_actions::Runner;
use crate::stages::Requirement;
use crate::table::{Row, Val};
use crate::vocab::Level;

/// One department tab: its id (the inner tab id and the catalog's word), title, the question it
/// answers, and the stages.md requirements that make it due, by the start of their text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Department {
    pub id: &'static str,
    pub title: &'static str,
    pub question: &'static str,
    pub requires: &'static [&'static str],
}

pub const DEPARTMENTS: [Department; 5] = [
    Department {
        id: "analytics",
        title: "Analytics",
        question: "Who uses it, and which features?",
        requires: &["An event catalogue"],
    },
    Department {
        id: "marketing",
        title: "Marketing",
        question: "What did we plan and send, and how did it do?",
        requires: &["A go-to-market entry"],
    },
    Department {
        id: "legal",
        title: "Legal",
        question: "Can it ship at its stage?",
        requires: &["Content rating done", "A privacy and compliance check"],
    },
    Department {
        id: "support",
        title: "Support",
        question: "What are users telling us?",
        requires: &["A support intake"],
    },
    Department {
        id: "money",
        title: "Money",
        question: "What does it earn and cost?",
        requires: &["Costs recorded per product", "Revenue recorded per product"],
    },
];

/// The stage ladder, lowest first, as stages.md orders it.
pub const LADDER: [&str; 5] = ["draft", "dev", "alpha", "beta", "prod"];

/// The project-map types that are products, the ones with department tabs; the rest are infra.
pub const PRODUCT_TYPES: [&str; 2] = ["game", "app"];

/// The trend dashboard every tab links (home-config `apps/monitoring/dashboards/kb-project.json`).
pub const DASHBOARD: &str = "kb-project";

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
pub const FOUND: &str = "ok";
pub const MISSING: &str = "missing";
pub const NOT_CLONED: &str = "not cloned";

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
    pub id: &'static str,
    pub title: &'static str,
    pub question: &'static str,
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
}

/// One product: a Coverage row and its department tabs.
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

impl Product {
    pub fn key(&self) -> String {
        format!("{}/{}", self.profile, self.name)
    }

    pub fn dept(&self, id: &str) -> Option<&Dept> {
        self.depts.iter().find(|d| d.id == id)
    }

    fn worst(&self) -> Cell {
        self.depts.iter().map(|d| d.cell).min().unwrap_or_default()
    }
}

impl Row for Product {
    const COLUMNS: &'static [&'static str] = &[
        "product",
        "type",
        "stage",
        "analytics",
        "marketing",
        "legal",
        "support",
        "money",
    ];
    const STATES: &'static [&'static str] = &["all", "red", "amber", "off"];
    const FACETS: &'static [&'static str] = &["type", "stage"];
    const LEAD: &'static str = "product";
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
            "product" => word(&self.name),
            "type" => word(&self.kind),
            "stage" => word(&self.stage),
            d => self
                .dept(d)
                .map_or(Val::None, |d| Val::Text(d.cell.word().into())),
        }
    }

    /// Under a chip when any of its five cells is in that state.
    fn in_state(&self, s: &str) -> bool {
        self.depts.iter().any(|d| d.cell.word() == s)
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            "stage" => self.stage_rank.map_or(Val::None, |r| Val::Num(r as f64)),
            "product" | "type" => self.val(col),
            d => self
                .dept(d)
                .map_or(Val::None, |d| Val::Num(d.cell as u8 as f64)),
        }
    }

    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "product" => Some(Link::to(Kind::Project, self.key())),
            d if self.dept(d).is_some() => {
                Some(Link::to(Kind::Project, format!("{}/{d}", self.key())))
            }
            _ => None,
        }
    }
}

/// The grid and every product's tabs.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Coverage {
    pub products: Vec<Product>,
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
}

/// Whether `kind` (a project-map type) has department tabs.
pub fn is_product(kind: Option<&str>) -> bool {
    kind.is_some_and(|k| PRODUCT_TYPES.contains(&k))
}

/// What one read gathered, handed to [`build`] so a test can feed each store.
pub struct Inputs<'a> {
    pub registry: Option<&'a Registry>,
    /// The lab cards: profile, name and stage.
    pub cards: Result<Vec<(String, String, String)>, String>,
    pub catalog: Result<String, String>,
    pub requirements: Result<Vec<Requirement>, String>,
    pub numbers: Result<Vec<Series>, String>,
    pub ci: Option<CiState>,
    pub grafana: Option<String>,
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
        let reqs = s.spawn(|| crate::stages::requirements(runner));
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
    if let Err(e) = &inputs.requirements {
        out.says
            .push(State::NotRead(e.clone()).sentence("requirements"));
    }
    if let Err(e) = &inputs.numbers {
        out.says.push(State::NotRead(e.clone()).sentence("numbers"));
    }

    // The products, in the lab's own order.
    let products: Vec<(&str, &str, &str, String, String)> = cards
        .iter()
        .filter_map(|(profile, name, stage)| {
            let key = reg.lookup(name).unwrap_or(name).to_string();
            let kind = reg.kind(&key)?;
            is_product(Some(&kind)).then_some((
                profile.as_str(),
                name.as_str(),
                stage.as_str(),
                key,
                kind,
            ))
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
        .filter_map(|p| p.url.clone())
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
    for ((profile, name, stage, key, kind), pending) in products.iter().zip(legal) {
        let rank = LADDER.iter().position(|s| s == stage);
        let repo = reg
            .tracker(key)
            .and_then(|t| t.get("repo"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let checks: Vec<Check> = pending.into_iter().map(|p| p.finish(&codes)).collect();
        let depts = DEPARTMENTS
            .iter()
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
                let nums = numbers.map(|n| numbers_of(n, key, d.id));
                dept(
                    d,
                    kind,
                    rank,
                    inputs.requirements.as_deref().unwrap_or_default(),
                    pipes,
                    if d.id == "legal" {
                        checks.clone()
                    } else {
                        vec![]
                    },
                    nums,
                    inputs
                        .grafana
                        .as_deref()
                        .map(|g| format!("{g}/d/{DASHBOARD}?var-project={}", url_word(key))),
                )
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

/// A key as a URL query value: the project-map names are already plain words.
fn url_word(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        .collect()
}

/// The earliest stage a requirement of `d` names for `kind`, by the ladder.
fn due_at(d: &Department, kind: &str, reqs: &[Requirement]) -> Option<usize> {
    reqs.iter()
        .filter(|r| d.requires.iter().any(|p| r.requirement.starts_with(p)))
        .filter(|r| r.applies.iter().any(|a| a == kind))
        .filter_map(|r| LADDER.iter().position(|s| *s == r.stage))
        .min()
}

#[allow(clippy::too_many_arguments)]
fn dept(
    d: &Department,
    kind: &str,
    rank: Option<usize>,
    reqs: &[Requirement],
    pipes: Vec<Pipe>,
    checks: Vec<Check>,
    numbers: Option<Vec<Number>>,
    grafana: Option<String>,
) -> Dept {
    let due = due_at(d, kind, reqs);
    let required = matches!((due, rank), (Some(due), Some(r)) if r >= due);
    let level = if required { Level::Bad } else { Level::Warn };
    let mut needs = vec![];
    for p in pipes.iter().filter(|p| !p.shared && p.found == MISSING) {
        needs.push(Need {
            level,
            says: format!("{} {} is missing", p.kind, p.source),
        });
    }
    for c in checks.iter().filter(|c| c.state == GAP) {
        needs.push(Need {
            level,
            says: format!("{}: {}", c.item, c.says),
        });
    }
    let fed = pipes.iter().any(|p| !p.shared && p.found == FOUND)
        || checks.iter().any(|c| c.state == MET)
        || numbers.as_ref().is_some_and(|n| !n.is_empty());
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
    let cell = match (needs.is_empty(), required, fed) {
        (true, _, true) => Cell::Ok,
        (true, _, false) => Cell::Off,
        (false, true, _) => Cell::Red,
        (false, false, _) => Cell::Amber,
    };
    let numbers_says = match &numbers {
        None => reading::NOT_READ.to_string(),
        Some(n) if n.is_empty() => reading::NO_DATA.to_string(),
        Some(_) => String::new(),
    };
    Dept {
        id: d.id,
        title: d.title,
        question: d.question,
        cell,
        due_at: due.map(|i| LADDER[i].to_string()),
        required,
        needs,
        numbers: numbers.unwrap_or_default(),
        numbers_says,
        pipes,
        checks,
        grafana,
    }
}

fn numbers_of(series: &[Series], project: &str, dept: &str) -> Vec<Number> {
    let mut out: Vec<Number> = series
        .iter()
        .filter(|s| s.labels.get("project").map(String::as_str) == Some(project))
        .filter(|s| s.labels.get("dept").map(String::as_str) == Some(dept))
        .filter_map(|s| {
            let metric = s.labels.get("metric").cloned().unwrap_or_default();
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
    let have = |ok: bool| Found {
        found: if ok { FOUND } else { MISSING },
        ..Default::default()
    };
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
                return Found {
                    found: NOT_CLONED,
                    ..Default::default()
                };
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
                    return Found {
                        found: NOT_CLONED,
                        ..Default::default()
                    };
                }
                paths.home.join(rest)
            } else if let Some((repo, rel)) = path.split_once(':') {
                match reg.checkout(repo) {
                    Some(d) => d.join(rel),
                    None => {
                        return Found {
                            found: NOT_CLONED,
                            ..Default::default()
                        }
                    }
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
            let at = chrono::DateTime::parse_from_rfc3339(r.created_at.as_deref()?).ok()?;
            Some((at.timestamp(), r.conclusion.clone().unwrap_or_default()))
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

/// A Legal item before its URL is probed.
struct Pending {
    item: &'static str,
    /// Settled without a probe: the state and its words.
    settled: Option<(&'static str, String)>,
    url: Option<String>,
    evidence: String,
}

impl Pending {
    fn finish(self, codes: &BTreeMap<String, Result<u16, String>>) -> Check {
        let (state, says) = match (self.settled, &self.url) {
            (Some(s), _) => s,
            (None, Some(u)) => {
                let (ok, says) = codes
                    .get(u.as_str())
                    .map_or((false, reading::NOT_READ.to_string()), probed);
                (if ok { MET } else { GAP }, says)
            }
            (None, None) => (NOT_YET, String::new()),
        };
        Check {
            item: self.item,
            state,
            says,
            evidence: self.evidence,
        }
    }
}

fn settled(item: &'static str, state: &'static str, says: &str, evidence: &str) -> Pending {
    Pending {
        item,
        settled: Some((state, says.to_string())),
        url: None,
        evidence: evidence.to_string(),
    }
}

/// A URL item: probed when the key is set, a gap naming the key when it is not.
fn url_item(item: &'static str, key: &str, url: Option<String>, file: &str) -> Pending {
    match url.filter(|u| u.starts_with("http")) {
        Some(u) => Pending {
            item,
            settled: None,
            evidence: u.clone(),
            url: Some(u),
        },
        None => settled(item, GAP, &format!("no {key} in {file}"), file),
    }
}

/// The Legal checklist for one product, from the files that hold its facts today: none when
/// the product has no store file yet (its tab then says what is due, not what fails).
fn legal_checks(reg: &Registry, key: &str, kind: &str) -> Vec<Pending> {
    let tracker = reg.tracker(key);
    let field = |k: &str| {
        tracker
            .and_then(|t| t.get(k))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    let (repo, path) = (field("repo"), field("path"));
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
            let rel = format!("{path}/mobile/metadata.yaml");
            let Ok(text) = std::fs::read_to_string(dir.join(&rel)) else {
                return vec![];
            };
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

/// A top-level `key: value` of a YAML file, quotes dropped; enough for metadata.yaml's URLs.
fn yaml_scalar(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let v = l.strip_prefix(key)?.strip_prefix(':')?.trim();
        let v = v.trim_matches(|c| c == '\'' || c == '"');
        (!v.is_empty()).then(|| v.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
        }
    }

    fn req(stage: &str, applies: &[&str], text: &str) -> Requirement {
        Requirement {
            stage: stage.into(),
            applies: applies.iter().map(|a| a.to_string()).collect(),
            requirement: text.into(),
            ..Default::default()
        }
    }

    fn reqs() -> Vec<Requirement> {
        vec![
            req("alpha", &["game", "app"], "An event catalogue: each event"),
            req("beta", &["game"], "Content rating done: answers"),
            req("beta", &["app"], "A privacy and compliance check when"),
            req(
                "beta",
                &["game", "app"],
                "Costs recorded per product: hosting",
            ),
        ]
    }

    fn registry(mono: &Path) -> Registry {
        Registry::parse(&format!(
            r#"{{"paths": {{"{}": "mono"}},
                 "trackers": {{
                   "quiet": {{"type": "app"}},
                   "listed": {{"type": "app", "repo": "mono", "path": "apps/listed"}},
                   "infra-thing": {{}}
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
        }
    }

    const SHARED: &str = "marketing\tstore-console\tskill\t*\tthe listing\n";

    #[test]
    fn a_product_with_no_sources_is_off_in_every_cell_and_infra_has_no_row() {
        let root = tmp("quiet");
        let reg = registry(&root.join("mono"));
        let cov = build(
            &inputs(&reg, &[("quiet", "draft"), ("infra-thing", "dev")], SHARED),
            &paths(&root),
            &|_| panic!("nothing to probe"),
        );
        assert_eq!(cov.products.len(), 1, "infra is not a product");
        let p = &cov.products[0];
        for d in &p.depts {
            assert_eq!(d.cell, Cell::Off, "{}", d.id);
            assert!(d.needs.is_empty(), "{}", d.id);
            assert_eq!(d.numbers_says, reading::NO_DATA);
        }
        // A `*` row is listed, missing or not, and never counts as the product's feed.
        let m = p.dept("marketing").unwrap();
        assert_eq!(m.pipes.len(), 1);
        assert!(m.pipes[0].shared);
        assert_eq!((cov.red, cov.amber, cov.off), (0, 0, 5));
        assert_eq!(cov.head(), "5 off");
        assert_eq!(
            m.grafana.as_deref(),
            Some("https://grafana.test/d/kb-project?var-project=quiet")
        );
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
        assert_eq!(cov.head(), "3 red  |  2 off");
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
            "#projects/bnb%2Flisted%2Flegal"
        );
        assert_eq!(
            cov.product("listed").map(|p| p.key()),
            Some("bnb/listed".into())
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn each_department_requirement_names_one_stages_md_row() {
        let doc = include_str!("../../docs/stages.md");
        for d in &DEPARTMENTS {
            for p in d.requires {
                let n = doc
                    .lines()
                    .filter(|l| l.starts_with('|'))
                    .filter(|l| l.split('|').any(|c| c.trim().starts_with(p)))
                    .count();
                assert_eq!(n, 1, "{}: `{p}` names {n} stages.md rows", d.id);
            }
        }
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
