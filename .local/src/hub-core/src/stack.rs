//! The Stack tab, both surfaces: what the agent system is made of and whether it is wired. One
//! inner tab per part, each read from the store that owns it (dashboards rule 8), never a copy:
//!
//! | part     | store |
//! |----------|-------|
//! | skills   | `~/.claude/skills/*/SKILL.md` frontmatter; uses from the token-usage day snapshots (`costs::snapshots`); drift from the nightly docs-cleanup `skills.json` (`skill-drift --json`); runners from each agentctl conf's `SKILL=` |
//! | agents   | `~/.claude/agents/*.md` frontmatter; the runner count from the agentctl confs, whose home is Sessions' Runners |
//! | hooks    | `~/.claude/settings.json` `hooks`, the codex source `~/.config/codex/hooks.json`, and the Stop hook's `stop-checks.d` and `stop-post.d` |
//! | rules    | `fleet-bench rules --json`, the one reader of `rules.jsonl`; and `.claude/rules/*.md` with its `paths:` |
//!
//! `skill-drift` takes minutes, so the tab reads the snapshot the nightly runner already writes
//! and names its day. A part that could not be read says so in `hub_core::reading`'s words,
//! never as an empty table (rule 6).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::links::{Kind, Link};
use crate::outcomes;
use crate::reading::NOT_READ;
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// The window a skill's uses are counted over: a month of day snapshots.
pub const USE_DAYS: usize = 30;

/// Where each part is read from. `from_env` is the deployed tree; tests point it at fixtures.
#[derive(Clone, Debug)]
pub struct Paths {
    pub skills: PathBuf,
    pub agents: PathBuf,
    /// The private overlay's checkout: a skill or agent whose file resolves under it is private.
    pub private: PathBuf,
    pub settings: PathBuf,
    pub codex_hooks: PathBuf,
    /// `~/.claude/hooks`, holding `stop-checks.d` and `stop-post.d`.
    pub hooks: PathBuf,
    /// docs-cleanup's inbox: one `<YYYYMMDD>/skills.json` a night.
    pub drift: PathBuf,
    pub tokens: PathBuf,
    /// agentctl's runner confs, `<name>.conf` each.
    pub runners: PathBuf,
    /// The public repo's `.claude/rules`, the path-scoped rules.
    pub rule_files: PathBuf,
    /// The fleet map, whose `## Flows` table names each flow's one definition.
    pub architecture: PathBuf,
    /// What `~/` means in that table.
    pub home: PathBuf,
    /// The checkouts a `Checked by` test path is read under, the first that has it.
    pub repos: Vec<PathBuf>,
}

impl Paths {
    pub fn from_env() -> Paths {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Paths {
            skills: home.join(".claude/skills"),
            agents: home.join(".claude/agents"),
            private: home.join(".dotfiles-private"),
            settings: home.join(".claude/settings.json"),
            codex_hooks: home.join(".config/codex/hooks.json"),
            hooks: home.join(".claude/hooks"),
            drift: home.join(".local/state/agentctl/docs-cleanup"),
            tokens: crate::boards::token_usage_dir(),
            runners: home.join(".config/agentctl/agents"),
            rule_files: home.join(".dotfiles/.claude/rules"),
            architecture: home.join(".config/agentctl/ARCHITECTURE.md"),
            repos: vec![home.join(".dotfiles"), home.join(".dotfiles-private")],
            home,
        }
    }
}

/// The tab, as both surfaces draw it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Stack {
    pub at: i64,
    pub skills: Vec<Skill>,
    /// The day of the drift snapshot the skills' drift column is, `YYYY-MM-DD`; empty when none.
    pub drift_day: String,
    /// How many day snapshots the uses column sums (at most `USE_DAYS`).
    pub use_days: usize,
    pub agents: Vec<Agent>,
    /// agentctl runners: a count here, the list on Sessions' Runners (rule 2).
    pub runners: usize,
    pub hooks: Vec<Hook>,
    pub rules: Vec<Rule>,
    pub rule_files: Vec<RuleFile>,
    pub flows: Vec<Flow>,
    /// Each inner tab's count of rows that need a look, by inner id: the strip's pills.
    pub strip: BTreeMap<String, usize>,
    pub errors: Vec<String>,
}

/// One skill.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Skill {
    pub name: String,
    pub category: String,
    pub description: String,
    /// `public` or `private`: the repo its SKILL.md lives in.
    pub repo: String,
    /// The `paths:` globs: a skill with any is listed only once a session touches a match.
    pub paths: Vec<String>,
    /// Skill calls over the window (the snapshots' spans); None when no snapshot was read.
    pub calls: Option<u64>,
    /// The runners whose conf names this skill (`SKILL=`).
    pub runners: Vec<String>,
    /// The drift snapshot's findings for it, lower-case type and its item.
    pub drift: Vec<Finding>,
    /// The newest sessions that ran it (`RAN_PER_SKILL`, over `USE_DAYS`), each linked to its page.
    pub ran: Vec<SkillRun>,
}

/// One session that ran a skill, as its outcome row says.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SkillRun {
    pub session_id: String,
    pub project: String,
    pub title: String,
    pub updated: String,
    pub calls: u64,
    pub link: Link,
}

/// How many sessions a skill's backlinks list.
pub const RAN_PER_SKILL: usize = 10;

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Finding {
    pub kind: String,
    pub item: String,
    pub detail: String,
}

pub const ALL: &str = "all";
pub const DRIFT: &str = "drift";
pub const SCOPED: &str = "scoped";
pub const RUN: &str = "runner";

impl Row for Skill {
    const COLUMNS: &'static [&'static str] =
        &["skill", "category", "repo", "calls", "runners", "drift"];
    const STATES: &'static [&'static str] = &[ALL, DRIFT, SCOPED, RUN];
    const FACETS: &'static [&'static str] = &["category", "repo", "drift"];
    const LEAD: &'static str = "skill";
    const GLANCE: &'static [&'static str] = &["category", "calls", "drift"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            DRIFT,
            "the nightly skill-drift snapshot names a broken part; unused is shown, not counted",
        ),
        (
            SCOPED,
            "has paths: so it is listed only once a session touches a match",
        ),
        (RUN, "an agentctl runner's conf names it as its SKILL"),
    ];

    fn val(&self, col: &str) -> Val {
        match col {
            "skill" => Val::Text(self.name.clone()),
            "category" => text(&self.category),
            "repo" => text(&self.repo),
            "calls" => self.calls.map(|n| n as f64).into(),
            "runners" => text(&self.runners.join(", ")),
            "drift" => text(&self.drift_words().join(", ")),
            _ => Val::None,
        }
    }

    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "runners" => self.runners.iter().map(|r| text(r)).collect(),
            "drift" => self.drift_words().iter().map(|w| text(w)).collect(),
            _ => vec![self.val(col)],
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            DRIFT => self.drifts(),
            SCOPED => !self.paths.is_empty(),
            RUN => !self.runners.is_empty(),
            _ => true,
        }
    }

    fn text(&self) -> String {
        format!("{}\n{}\n{}", self.name, self.category, self.description).to_lowercase()
    }

    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "runners" => self.runners.first().map(|r| Link::to(Kind::Runner, r)),
            _ => None,
        }
    }
}

impl Skill {
    /// Whether a finding names a broken part: an unused skill is a fact, not a fault.
    pub fn drifts(&self) -> bool {
        self.drift.iter().any(|f| f.kind != "unused")
    }

    /// Its finding kinds, each once, in the snapshot's order.
    pub fn drift_words(&self) -> Vec<String> {
        let mut w: Vec<String> = vec![];
        for f in &self.drift {
            if !w.contains(&f.kind) {
                w.push(f.kind.clone());
            }
        }
        w
    }
}

/// One subagent definition.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Agent {
    pub name: String,
    /// The `model:` it pins; empty inherits the caller's.
    pub model: String,
    pub tools: String,
    pub repo: String,
    pub description: String,
}

impl Row for Agent {
    const COLUMNS: &'static [&'static str] = &["agent", "model", "tools", "repo"];
    const STATES: &'static [&'static str] = &[ALL];
    const FACETS: &'static [&'static str] = &["model", "repo"];
    const LEAD: &'static str = "agent";
    const GLANCE: &'static [&'static str] = &["model", "repo"];

    fn val(&self, col: &str) -> Val {
        match col {
            "agent" => Val::Text(self.name.clone()),
            "model" => text(if self.model.is_empty() {
                "inherit"
            } else {
                &self.model
            }),
            "tools" => text(&self.tools),
            "repo" => text(&self.repo),
            _ => Val::None,
        }
    }

    fn in_state(&self, _s: &str) -> bool {
        true
    }

    fn text(&self) -> String {
        format!("{}\n{}\n{}", self.name, self.tools, self.description).to_lowercase()
    }
}

/// One hook: an entry of a harness's hooks config, or a file the Stop hook runs from its dirs.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Hook {
    /// `claude` or `codex`.
    pub harness: String,
    pub event: String,
    /// The tool matcher; empty matches every call.
    pub matcher: String,
    /// The script it runs, by file name, or the command as written when it names none.
    pub script: String,
    pub command: String,
    /// Where the entry is written: `settings.json`, `hooks.json`, `stop-checks.d`, `stop-post.d`.
    pub from: String,
    /// The script resolves to a file on disk; false is a hook that cannot run.
    pub found: bool,
}

pub const MISSING: &str = "missing";

impl Row for Hook {
    const COLUMNS: &'static [&'static str] = &["harness", "event", "matcher", "script", "from"];
    const STATES: &'static [&'static str] = &[ALL, MISSING];
    const FACETS: &'static [&'static str] = &["harness", "event", "from"];
    const LEAD: &'static str = "script";
    const GLANCE: &'static [&'static str] = &["event", "matcher"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[(
        MISSING,
        "the script it names is not on disk, so the hook cannot run",
    )];

    fn val(&self, col: &str) -> Val {
        match col {
            "harness" => text(&self.harness),
            "event" => text(&self.event),
            "matcher" => text(if self.matcher.is_empty() {
                "*"
            } else {
                &self.matcher
            }),
            "script" => Val::Text(self.script.clone()),
            "from" => text(&self.from),
            _ => Val::None,
        }
    }

    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "matcher" if self.matcher.is_empty() => vec![text("*")],
            "matcher" => self.matcher.split('|').map(text).collect(),
            _ => vec![self.val(col)],
        }
    }

    fn in_state(&self, s: &str) -> bool {
        s != MISSING || !self.found
    }

    fn text(&self) -> String {
        format!("{}\n{}\n{}", self.event, self.matcher, self.command).to_lowercase()
    }
}

/// One rule of `rules.jsonl`, as `fleet-bench rules --json` states it today.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Rule {
    pub rule: String,
    /// `invariant` or `provisional`.
    pub kind: String,
    pub source: String,
    pub number: String,
    pub confidence: String,
    /// `ok`, `stale` (its anchor is gone from its source, or the source is not here), `moved`
    /// (its measured number disagrees with its recorded confidence), `restates` (its bound is a
    /// copy of the number its measure reads) or `dead` (its measure printed no number).
    pub state: String,
    pub today: String,
    pub revisit: String,
    pub why: String,
}

pub const OK: &str = "ok";
pub const STALE: &str = "stale";
pub const MOVED: &str = "moved";
pub const RESTATES: &str = "restates";
pub const ABSENT: &str = "absent";
pub const DEAD: &str = "dead";

impl Row for Rule {
    const COLUMNS: &'static [&'static str] =
        &["rule", "kind", "number", "confidence", "state", "source"];
    const STATES: &'static [&'static str] = &[ALL, STALE, MOVED, RESTATES, DEAD, ABSENT];
    const FACETS: &'static [&'static str] = &["kind", "confidence", "state"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "rule";
    const GLANCE: &'static [&'static str] = &["kind", "state"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            STALE,
            "its anchor text is gone from its source file, or that file is not on this machine",
        ),
        (
            MOVED,
            "its measured number disagrees with its recorded confidence: a confident row past its bound, or a low one back inside it",
        ),
        (
            RESTATES,
            "its bound is a copy of the number its measure reads from its own source; the reading is the number",
        ),
        (DEAD, "its measure printed no number"),
        (
            ABSENT,
            "its source file is not on this machine, so nothing here checked it",
        ),
    ];

    fn val(&self, col: &str) -> Val {
        match col {
            "rule" => Val::Text(self.rule.clone()),
            "kind" => text(&self.kind),
            "number" => text(&self.number),
            "confidence" => text(&self.confidence),
            "state" => text(&self.state),
            "source" => text(&self.source),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.state == s
    }

    fn text(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}",
            self.rule, self.source, self.today, self.why
        )
        .to_lowercase()
    }
}

/// One path-scoped rule file: its name and the globs that load it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct RuleFile {
    pub name: String,
    pub paths: Vec<String>,
}

/// One flow of the fleet, a row of the `## Flows` table in ARCHITECTURE.md: the one doc section
/// that defines it, its picture, and the test that fails when the code leaves that section.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Flow {
    pub flow: String,
    pub question: String,
    /// As the table writes it, `~/<path>#<anchor>`.
    pub source: String,
    /// `~/<path>.svg`, or empty.
    pub picture: String,
    /// Test paths under one of the repos, or empty when nothing checks it.
    pub checked: Vec<String>,
    /// `ok`, `unchecked` (no test holds the doc to the code) or `broken` (a path, heading or
    /// test it names is gone).
    pub state: String,
    /// What is broken, one line each.
    pub why: Vec<String>,
    #[serde(skip)]
    pub doc: PathBuf,
    #[serde(skip)]
    pub anchor: String,
    #[serde(skip)]
    pub svg: Option<PathBuf>,
}

pub const UNCHECKED: &str = "unchecked";
pub const BROKEN: &str = "broken";

impl Row for Flow {
    const COLUMNS: &'static [&'static str] =
        &["flow", "question", "source", "picture", "checked", "state"];
    const STATES: &'static [&'static str] = &[ALL, UNCHECKED, BROKEN];
    const FACETS: &'static [&'static str] = &["state"];
    const LEAD: &'static str = "flow";
    const GLANCE: &'static [&'static str] = &["checked", "state"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[
        (
            UNCHECKED,
            "no test fails when the code leaves the doc, so the doc may drift",
        ),
        (BROKEN, "a doc, heading, picture or test it names is gone"),
    ];

    fn val(&self, col: &str) -> Val {
        match col {
            "flow" => Val::Text(self.flow.clone()),
            "question" => text(&self.question),
            "source" => text(self.source.strip_prefix("~/").unwrap_or(&self.source)),
            "picture" => text(self.picture.rsplit('/').next().unwrap_or_default()),
            "checked" => text(
                &self
                    .checked
                    .iter()
                    .map(|t| t.rsplit('/').next().unwrap_or(t))
                    .collect::<Vec<_>>()
                    .join(", "),
            ),
            "state" => text(&self.state),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.state == s
    }

    fn text(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}",
            self.flow,
            self.question,
            self.source,
            self.checked.join(" ")
        )
        .to_lowercase()
    }
}

/// A heading's GitHub anchor: lowercase, keep letters, digits, `-` and `_`, spaces to `-`.
pub fn slug(heading: &str) -> String {
    heading
        .to_lowercase()
        .chars()
        .filter_map(|c| match c {
            ' ' => Some('-'),
            c if c.is_alphanumeric() || c == '-' || c == '_' => Some(c),
            _ => None,
        })
        .collect()
}

/// The markdown under the heading whose anchor is `anchor`, up to the next heading of the same
/// or a higher level, `#` lines inside a fence not counted. Image lines are dropped: the picture
/// is served on its own.
pub fn section(md: &str, anchor: &str) -> Option<String> {
    let mut fence = false;
    let mut level = None;
    let mut out = Vec::new();
    for line in md.lines() {
        let t = line.trim_start();
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence;
        }
        let depth = t.chars().take_while(|c| *c == '#').count();
        let heading = !fence && (1..=6).contains(&depth) && t[depth..].starts_with(' ');
        match level {
            None if heading && slug(t[depth..].trim()) == anchor => level = Some(depth),
            None => continue,
            Some(l) if heading && depth <= l => break,
            Some(_) => {}
        }
        let image = !fence && t.starts_with("![") && t.trim_end().ends_with(')');
        // An image line goes with the blank line after it, so no gap is left.
        if image || (t.is_empty() && out.last().is_some_and(|l: &&str| l.trim().is_empty())) {
            continue;
        }
        out.push(line);
    }
    level.map(|_| out.join("\n").trim().to_string())
}

/// The cells of one markdown table row, backticks dropped.
fn cells(line: &str) -> Vec<String> {
    let t = line.trim();
    t.strip_prefix('|')
        .and_then(|t| t.strip_suffix('|'))
        .unwrap_or(t)
        .split('|')
        .map(|c| c.trim().replace('`', ""))
        .collect()
}

fn read_flows(paths: &Paths, errors: &mut Vec<String>) -> Vec<Flow> {
    let Ok(md) = std::fs::read_to_string(&paths.architecture) else {
        errors.push(format!("{} not read", paths.architecture.display()));
        return Vec::new();
    };
    let Some(table) = section(&md, "flows") else {
        errors.push(format!("{}: no ## Flows", paths.architecture.display()));
        return Vec::new();
    };
    // The first table under the heading, and only it: a later table or subsection is prose.
    let is_row = |l: &&str| l.trim_start().starts_with('|');
    let mut rows = table.lines().skip_while(|l| !is_row(l)).take_while(is_row);
    let head: Vec<String> = rows
        .next()
        .map(cells)
        .unwrap_or_default()
        .iter()
        .map(|c| c.to_lowercase())
        .collect();
    let col = |name: &str| head.iter().position(|h| h == name);
    let (Some(fi), Some(qi), Some(di), Some(pi), Some(ci)) = (
        col("flow"),
        col("question"),
        col("defined in"),
        col("picture"),
        col("checked by"),
    ) else {
        errors.push(format!(
            "{}: the Flows table needs Flow, Question, Defined in, Picture and Checked by",
            paths.architecture.display()
        ));
        return Vec::new();
    };
    let home = |p: &str| match p.strip_prefix("~/") {
        Some(rest) => paths.home.join(rest),
        None => PathBuf::from(p),
    };
    let blank = |c: &str| c.is_empty() || c == "-" || c.eq_ignore_ascii_case("none");
    // Several flows share one doc, so each is read once per pass.
    let mut docs: std::collections::HashMap<PathBuf, Option<String>> = Default::default();
    rows.skip(1)
        .map(cells)
        .map(|mut c| {
            let mut why = Vec::new();
            // A short row is shown broken, never dropped: losing a flow silently is the drift this
            // table exists to catch.
            if c.len() < head.len() {
                why.push(format!(
                    "the row has {} cells, the header {}",
                    c.len(),
                    head.len()
                ));
                c.resize(head.len(), String::new());
            }
            let (file, anchor) = c[di].split_once('#').unwrap_or((&c[di], ""));
            let doc = home(file);
            let text = docs
                .entry(doc.clone())
                .or_insert_with(|| std::fs::read_to_string(&doc).ok());
            match text {
                None => why.push(format!("{file} is gone")),
                Some(_) if anchor.is_empty() => why.push(format!("{file}: no #anchor")),
                Some(text) if section(text, anchor).is_none() => {
                    why.push(format!("{file}: no heading #{anchor}"))
                }
                Some(_) => {}
            }
            let picture = if blank(&c[pi]) {
                String::new()
            } else {
                c[pi].clone()
            };
            let svg = (!picture.is_empty()).then(|| home(&picture));
            if svg.as_ref().is_some_and(|p| !p.is_file()) {
                why.push(format!("{picture} is gone"));
            }
            let checked: Vec<String> = if blank(&c[ci]) {
                Vec::new()
            } else {
                c[ci].split(',').map(|t| t.trim().to_string()).collect()
            };
            for t in &checked {
                if !paths.repos.iter().any(|r| r.join(t).is_file()) {
                    why.push(format!("{t} is gone"));
                }
            }
            let state = if !why.is_empty() {
                BROKEN
            } else if checked.is_empty() {
                UNCHECKED
            } else {
                OK
            };
            Flow {
                flow: c[fi].clone(),
                question: c[qi].clone(),
                source: c[di].clone(),
                picture,
                checked,
                state: state.to_string(),
                why,
                doc,
                anchor: anchor.to_string(),
                svg,
            }
        })
        .collect()
}

/// A flow's doc section, read now, for the page a row opens.
pub fn flow_section(flow: &Flow) -> Option<String> {
    section(&std::fs::read_to_string(&flow.doc).ok()?, &flow.anchor)
}

fn text(s: &str) -> Val {
    if s.is_empty() {
        Val::None
    } else {
        Val::Text(s.to_string())
    }
}

/// The whole tab: each part read from its store, the slow `fleet-bench rules` through `runner`.
pub fn read(paths: &Paths, runner: &dyn Runner, now: i64) -> Stack {
    let mut errors = vec![];
    let (drift_day, drift) = read_drift(&paths.drift, &mut errors);
    let (use_days, calls) = read_calls(&paths.tokens, &mut errors);
    let by_skill = runner_skills(&paths.runners);
    let mut ran = read_ran(runner, &mut errors);
    let mut skills = read_skills(paths, &mut errors);
    for s in &mut skills {
        s.calls = (use_days > 0).then(|| calls.get(&s.name).copied().unwrap_or(0));
        s.runners = by_skill.get(&s.name).cloned().unwrap_or_default();
        s.drift = drift.get(&s.name).cloned().unwrap_or_default();
        s.ran = ran.remove(&s.name).unwrap_or_default();
    }
    let agents = read_agents(paths, &mut errors);
    let runners = conf_names(&paths.runners).len();
    let hooks = read_hooks(paths, &mut errors);
    let rules = read_rules(runner, &mut errors);
    let rule_files = read_rule_files(&paths.rule_files);
    let flows = read_flows(paths, &mut errors);
    let strip = BTreeMap::from([
        (
            "flows".to_string(),
            flows.iter().filter(|f| f.state != OK).count(),
        ),
        (
            "skills".to_string(),
            skills.iter().filter(|s| s.drifts()).count(),
        ),
        (
            "hooks".to_string(),
            hooks.iter().filter(|h| !h.found).count(),
        ),
        (
            "rules".to_string(),
            rules
                .iter()
                .filter(|r| r.state != OK && r.state != ABSENT)
                .count(),
        ),
    ]);
    Stack {
        at: now,
        skills,
        drift_day,
        use_days,
        agents,
        runners,
        hooks,
        rules,
        rule_files,
        flows,
        strip,
        errors,
    }
}

/// A markdown file's frontmatter as flat keys: `key: value`, a `>-` or `|` block folded to one
/// line, a `- item` list joined by newlines, and one level of nesting as `parent.key`.
pub fn frontmatter(md: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut lines = md.lines();
    if lines.next().map(str::trim) != Some("---") {
        return out;
    }
    let body: Vec<&str> = lines.take_while(|l| l.trim() != "---").collect();
    let mut parent: Option<String> = None;
    let mut i = 0;
    while i < body.len() {
        let line = body[i];
        i += 1;
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let indented = line.starts_with(' ') || line.starts_with('\t');
        let Some((k, v)) = line.trim().split_once(':') else {
            continue;
        };
        if k.starts_with("- ") || line.trim_start().starts_with("- ") {
            continue;
        }
        let key = match (&parent, indented) {
            (Some(p), true) => format!("{p}.{}", k.trim()),
            _ => k.trim().to_string(),
        };
        if !indented {
            parent = None;
        }
        let v = v.trim();
        // The lines below this key that belong to it: deeper indented than the key itself.
        let depth = line.len() - line.trim_start().len();
        let mut more = vec![];
        while i < body.len() {
            let n = body[i];
            let nd = n.len() - n.trim_start().len();
            // A list may sit at its key's own indent (`paths:` then `- "a/**"`).
            let item = nd == depth && n.trim_start().starts_with("- ");
            if !n.trim().is_empty() && nd <= depth && !item {
                break;
            }
            more.push(n.trim());
            i += 1;
        }
        let value = if matches!(v, ">" | ">-" | "|" | "|-") {
            let sep = if v.starts_with('|') { "\n" } else { " " };
            more.iter()
                .filter(|l| !l.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join(sep)
        } else if v.is_empty() && more.iter().any(|l| l.starts_with("- ")) {
            more.iter()
                .filter_map(|l| l.strip_prefix("- "))
                .map(unquote)
                .collect::<Vec<_>>()
                .join("\n")
        } else if v.is_empty() && !more.is_empty() {
            // A map: its keys are read on their own as `key.child`.
            parent = Some(key.clone());
            i -= more.len();
            continue;
        } else {
            unquote(v).to_string()
        };
        out.insert(key, value);
    }
    out
}

fn unquote(s: &str) -> &str {
    let s = s.trim();
    s.strip_prefix('"')
        .and_then(|x| x.strip_suffix('"'))
        .or_else(|| s.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
        .unwrap_or(s)
}

/// A frontmatter list value: a `- item` block (one per line) or a `[a, b]` flow list.
fn list(v: &str) -> Vec<String> {
    let v = v.trim();
    let inner = v.strip_prefix('[').and_then(|x| x.strip_suffix(']'));
    let items: Vec<&str> = match inner {
        Some(i) => i.split(','),
        None if v.is_empty() => return vec![],
        None => v.split('\n'),
    }
    .collect();
    items
        .into_iter()
        .map(|x| unquote(x).to_string())
        .filter(|x| !x.is_empty())
        .collect()
}

fn repo_of(path: &Path, private: &Path) -> String {
    let real = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let private = std::fs::canonicalize(private).unwrap_or_else(|_| private.to_path_buf());
    if real.starts_with(&private) {
        "private".into()
    } else {
        "public".into()
    }
}

fn read_skills(paths: &Paths, errors: &mut Vec<String>) -> Vec<Skill> {
    let Ok(dir) = std::fs::read_dir(&paths.skills) else {
        errors.push(format!("skills: {NOT_READ}: {}", paths.skills.display()));
        return vec![];
    };
    let mut out: Vec<Skill> = dir
        .filter_map(Result::ok)
        .filter_map(|e| {
            let file = e.path().join("SKILL.md");
            let md = std::fs::read_to_string(&file).ok()?;
            let fm = frontmatter(&md);
            let dir_name = e.file_name().to_string_lossy().to_string();
            Some(Skill {
                name: fm.get("name").cloned().unwrap_or(dir_name),
                category: fm.get("metadata.category").cloned().unwrap_or_default(),
                description: fm.get("description").cloned().unwrap_or_default(),
                repo: repo_of(&file, &paths.private),
                paths: fm.get("paths").map(|p| list(p)).unwrap_or_default(),
                ..Default::default()
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

impl From<outcomes::Ran> for SkillRun {
    fn from(r: outcomes::Ran) -> SkillRun {
        SkillRun {
            link: Link::to(Kind::Session, &r.session_id),
            title: crate::text::headline(r.title.as_deref().unwrap_or("")).0,
            updated: r.updated.unwrap_or_default(),
            session_id: r.session_id,
            project: r.project,
            calls: r.calls,
        }
    }
}

/// Each skill's newest sessions from the outcome rows (`agentctl-session-outcomes ran`), which
/// the nightly run writes: a session still live has no row yet, so it is not listed.
fn read_ran(runner: &dyn Runner, errors: &mut Vec<String>) -> BTreeMap<String, Vec<SkillRun>> {
    let by = outcomes::ran(runner, USE_DAYS, RAN_PER_SKILL).unwrap_or_else(|e| {
        errors.push(format!(
            "skill sessions: {NOT_READ}: agentctl-session-outcomes ran: {e}"
        ));
        BTreeMap::new()
    });
    by.into_iter()
        .map(|(skill, rows)| (skill, rows.into_iter().map(SkillRun::from).collect()))
        .collect()
}

fn read_agents(paths: &Paths, errors: &mut Vec<String>) -> Vec<Agent> {
    let Ok(dir) = std::fs::read_dir(&paths.agents) else {
        errors.push(format!("agents: {NOT_READ}: {}", paths.agents.display()));
        return vec![];
    };
    let mut out: Vec<Agent> = dir
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .filter_map(|p| {
            let fm = frontmatter(&std::fs::read_to_string(&p).ok()?);
            let stem = p.file_stem()?.to_string_lossy().to_string();
            Some(Agent {
                name: fm.get("name").cloned().unwrap_or(stem),
                model: fm.get("model").cloned().unwrap_or_default(),
                tools: fm
                    .get("tools")
                    .map(|t| list(t).join(", "))
                    .unwrap_or_default(),
                repo: repo_of(&p, &paths.private),
                description: fm.get("description").cloned().unwrap_or_default(),
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// The newest drift snapshot's findings by skill, and its day. `skill-drift --json` exits 1 when
/// it finds anything, so the runner keeps the file either way.
fn read_drift(dir: &Path, errors: &mut Vec<String>) -> (String, BTreeMap<String, Vec<Finding>>) {
    let mut days: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| n.len() == 8 && n.bytes().all(|b| b.is_ascii_digit()))
                .collect()
        })
        .unwrap_or_default();
    days.sort();
    let Some((day, v)) = days.iter().rev().find_map(|d| {
        let t = std::fs::read_to_string(dir.join(d).join("skills.json")).ok()?;
        Some((
            d.clone(),
            serde_json::from_str::<serde_json::Value>(&t).ok()?,
        ))
    }) else {
        errors.push(format!(
            "skill drift: {NOT_READ}: no skills.json under {}",
            dir.display()
        ));
        return (String::new(), BTreeMap::new());
    };
    let mut by: BTreeMap<String, Vec<Finding>> = BTreeMap::new();
    for f in v["findings"].as_array().into_iter().flatten() {
        let Some(skill) = f["skill"].as_str() else {
            continue;
        };
        by.entry(skill.to_string()).or_default().push(Finding {
            kind: f["type"].as_str().unwrap_or_default().to_lowercase(),
            item: f["item"].as_str().unwrap_or_default().to_string(),
            detail: f["detail"].as_str().unwrap_or_default().to_string(),
        });
    }
    let day = format!("{}-{}-{}", &day[..4], &day[4..6], &day[6..]);
    (day, by)
}

/// Skill calls by skill over the newest `USE_DAYS` snapshots, and how many were read.
fn read_calls(dir: &Path, errors: &mut Vec<String>) -> (usize, BTreeMap<String, u64>) {
    let snaps = crate::costs::snapshots(dir, USE_DAYS, errors);
    let mut by: BTreeMap<String, u64> = BTreeMap::new();
    for s in &snaps {
        for d in &s.skills {
            *by.entry(d.skill.clone()).or_default() += d.spans;
        }
    }
    (snaps.len(), by)
}

fn conf_names(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "conf"))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// Each skill the runner confs name (`SKILL=`), with the runners naming it.
fn runner_skills(dir: &Path) -> BTreeMap<String, Vec<String>> {
    let mut by: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for p in conf_names(dir) {
        let Ok(t) = std::fs::read_to_string(&p) else {
            continue;
        };
        let name = p
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        for l in t.lines() {
            if let Some(v) = l.trim().strip_prefix("SKILL=") {
                let v = unquote(v);
                if !v.is_empty() {
                    by.entry(v.to_string()).or_default().push(name.clone());
                }
            }
        }
    }
    by
}

/// The script a hook command runs: the first word naming a `.sh` or `.py` file, quotes dropped and
/// `~`, `$HOME` and `${HOME}` filled in, and whether it is on disk. A command naming no script, or
/// one under another variable or a relative path the harness resolves, counts as found.
fn script_of(command: &str, home: &Path) -> (String, bool) {
    let word = command
        .split_whitespace()
        .map(|w| w.trim_matches(|c| c == '"' || c == '\''))
        .find(|w| w.ends_with(".sh") || w.ends_with(".py"));
    let Some(w) = word else {
        return (command.to_string(), true);
    };
    let home_rel = ["~/", "$HOME/", "${HOME}/"]
        .iter()
        .find_map(|p| w.strip_prefix(p));
    let path = home_rel.map_or_else(|| PathBuf::from(w), |r| home.join(r));
    let name = path
        .file_name()
        .map_or(w.to_string(), |n| n.to_string_lossy().to_string());
    // Only a path that names its own place can be checked from here.
    let checkable = home_rel.is_some() || path.is_absolute();
    (name, !checkable || path.is_file())
}

/// A harness's `hooks` object: event -> [{matcher, hooks: [{command}]}].
fn config_hooks(v: &serde_json::Value, harness: &str, from: &str, home: &Path) -> Vec<Hook> {
    let mut out = vec![];
    let Some(events) = v["hooks"].as_object() else {
        return out;
    };
    for (event, groups) in events {
        for g in groups.as_array().into_iter().flatten() {
            let matcher = g["matcher"].as_str().unwrap_or_default().to_string();
            for h in g["hooks"].as_array().into_iter().flatten() {
                let command = h["command"].as_str().unwrap_or_default().to_string();
                let (script, found) = script_of(&command, home);
                out.push(Hook {
                    harness: harness.into(),
                    event: event.clone(),
                    matcher: matcher.clone(),
                    script,
                    command,
                    from: from.into(),
                    found,
                });
            }
        }
    }
    out
}

fn read_hooks(paths: &Paths, errors: &mut Vec<String>) -> Vec<Hook> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let mut out = vec![];
    for (file, harness, from) in [
        (&paths.settings, "claude", "settings.json"),
        (&paths.codex_hooks, "codex", "hooks.json"),
    ] {
        match std::fs::read_to_string(file)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        {
            Some(v) => out.extend(config_hooks(&v, harness, from, &home)),
            None => errors.push(format!("{harness} hooks: {NOT_READ}: {}", file.display())),
        }
    }
    for d in ["stop-checks.d", "stop-post.d"] {
        let dir = paths.hooks.join(d);
        let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map(|rd| rd.filter_map(Result::ok).map(|e| e.path()).collect())
            .unwrap_or_default();
        files.sort();
        for f in files.into_iter().filter(|f| f.is_file()) {
            let name = f
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            out.push(Hook {
                harness: "claude".into(),
                event: "Stop".into(),
                matcher: String::new(),
                script: name,
                command: f.display().to_string(),
                from: d.into(),
                found: true,
            });
        }
    }
    out
}

fn read_rules(runner: &dyn Runner, errors: &mut Vec<String>) -> Vec<Rule> {
    let argv = ["fleet-bench", "rules", "--json"].map(String::from);
    let parsed = runner.run(&argv).and_then(|o| {
        serde_json::from_str::<Vec<serde_json::Value>>(&o).map_err(|e| e.to_string())
    });
    let rows = match parsed {
        Ok(r) => r,
        Err(e) => {
            errors.push(format!("rules: {NOT_READ}: fleet-bench rules --json: {e}"));
            return vec![];
        }
    };
    let s = |v: &serde_json::Value| match v {
        serde_json::Value::String(t) => t.clone(),
        serde_json::Value::Null => String::new(),
        o => o.to_string(),
    };
    rows.iter()
        .map(|r| Rule {
            rule: s(&r["rule"]),
            kind: s(&r["kind"]),
            source: s(&r["source"]),
            // A measured rule shows what its measure read today beside its recorded number.
            number: match (s(&r["number"]), r["value"].is_number()) {
                (n, false) => n,
                (n, true) if n.is_empty() => s(&r["value"]),
                (n, true) => format!("{n} (now {})", s(&r["value"])),
            },
            confidence: s(&r["confidence"]),
            // fleet-bench decides the state, the one verdict `rules --check` fails on too.
            state: s(&r["state"]),
            today: s(&r["today"]),
            revisit: s(&r["revisit"]),
            why: s(&r["why"]),
        })
        .collect()
}

fn read_rule_files(dir: &Path) -> Vec<RuleFile> {
    let mut out: Vec<RuleFile> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "md"))
                .filter_map(|p| {
                    let fm = frontmatter(&std::fs::read_to_string(&p).ok()?);
                    Some(RuleFile {
                        name: p.file_name()?.to_string_lossy().to_string(),
                        paths: fm.get("paths").map(|v| list(v)).unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(Result<String, String>);
    impl Runner for Fixed {
        fn run(&self, _argv: &[String]) -> Result<String, String> {
            self.0.clone()
        }
    }

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hub-stack-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn put(p: &Path, text: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    fn fixture(tag: &str) -> Paths {
        let d = tmp(tag);
        let p = Paths {
            skills: d.join("skills"),
            agents: d.join("agents"),
            private: d.join("private"),
            settings: d.join("settings.json"),
            codex_hooks: d.join("hooks.json"),
            hooks: d.join("hooks"),
            drift: d.join("drift"),
            tokens: d.join("tokens"),
            runners: d.join("runners"),
            rule_files: d.join("rules"),
            architecture: d.join("ARCHITECTURE.md"),
            home: d.clone(),
            repos: vec![d.join("pub"), d.join("priv")],
        };
        put(
            &p.skills.join("shepherd/SKILL.md"),
            "---\nname: shepherd\ndescription: >-\n  Move every session\n  through its plan.\nmetadata:\n  category: monitoring\n  tags: [a, b]\n---\n# shepherd\n",
        );
        put(
            &p.skills.join("hz-build/SKILL.md"),
            "---\nname: hz-build\ndescription: \"Build a Quest app\"\npaths:\n  - \"**/*.unity\"\n  - Packages/**\nmetadata:\n  category: ops\n---\n",
        );
        put(&p.skills.join("bare/SKILL.md"), "no frontmatter\n");
        put(
            &p.agents.join("root-cause-analyst.md"),
            "---\nname: root-cause-analyst\ndescription: >-\n  Read-only investigator.\ntools: Read, Grep, Bash\n---\n",
        );
        put(
            &p.settings,
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash|Read","hooks":[{"type":"command","command":"python3 /nope/block-poll.py"}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo hi"}]}]}}"#,
        );
        put(&p.codex_hooks, r#"{"hooks":{}}"#);
        put(&p.hooks.join("stop-post.d/88-ask-filed.sh"), "#!/bin/sh\n");
        put(
            &p.drift.join("20261117/skills.json"),
            r#"{"findings":[{"type":"UNUSED","skill":"hz-build","item":"30d","detail":"x"}]}"#,
        );
        put(
            &p.drift.join("20261118/skills.json"),
            r#"{"findings":[{"type":"DEADPATH","skill":"shepherd","item":"~/gone","detail":"path does not exist"},{"type":"DEADPATH","skill":"shepherd","item":"~/gone2","detail":"y"}]}"#,
        );
        put(
            &p.tokens.join("2026-11-17.json"),
            r#"{"by_skill":[{"skill":"shepherd","spans":3,"sessions":2}]}"#,
        );
        put(
            &p.tokens.join("2026-11-18.json"),
            r#"{"by_skill":[{"skill":"shepherd","spans":2,"sessions":2}]}"#,
        );
        put(
            &p.runners.join("fleet-shepherd.conf"),
            "NAME=x\nSKILL='shepherd'\n",
        );
        put(&p.runners.join("dream.conf"), "NAME=dream\n");
        put(
            &p.rule_files.join("agent-runtime.md"),
            "---\npaths:\n  - \".local/bin/agentctl*\"\n---\n# rules\n",
        );
        put(&p.architecture, ARCH);
        put(&d.join("docs/states.md"), STATES_MD);
        put(&d.join("docs/close.svg"), "<svg/>");
        put(&d.join("priv/tests/states.bats"), "");
        p
    }

    const ARCH: &str = "# map\n\n## Flows\n\n| Flow | Question | Defined in | Picture | Checked by |\n| --- | --- | --- | --- | --- |\n| Close verdict | may it close? | `~/docs/states.md#close-verdict` | `~/docs/close.svg` | `tests/states.bats` |\n| Chain | what runs after what? | `~/docs/states.md#the-chain-a---b` | - | None |\n| Gone | ? | `~/docs/states.md#nope` | `~/docs/gone.svg` | `tests/gone.bats` |\n| Short | ? |\n\n### Notes\n\n| Flow | Question | Defined in | Picture | Checked by |\n| --- | --- | --- | --- | --- |\n| Bogus | ? | - | - | - |\n\n## Instruments\n\n| a | b |\n";

    const STATES_MD: &str = "# states\n\n## Close verdict\n\n![close](close.svg)\n\nOne chain.\n\n```sh\n# not a heading\n```\n\n### Changing it\n\nRun the diff.\n\n## The chain: `a` -> b\n\nA then B.\n";

    const RULES: &str = r#"[{"rule":"cap at 50","kind":"provisional","number":"50","confidence":"high","state":"moved"},{"rule":"never force push","kind":"invariant","state":"ok"},{"rule":"old","kind":"provisional","state":"stale"},{"rule":"cap read from config","kind":"provisional","number":"max_live in sources","confidence":"low","value":2,"state":"ok"},{"rule":"copied cap","kind":"provisional","number":"3","confidence":"low","value":3,"state":"restates"},{"rule":"elsewhere","kind":"invariant","state":"absent"}]"#;

    #[test]
    fn each_part_is_read_from_its_own_store() {
        let p = fixture("parts");
        let s = read(&p, &Fixed(Ok(RULES.into())), 100);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        let names: Vec<&str> = s.skills.iter().map(|k| k.name.as_str()).collect();
        assert_eq!(
            names,
            ["bare", "hz-build", "shepherd"],
            "a dir with no frontmatter keeps its name"
        );
        let sh = s.skills.iter().find(|k| k.name == "shepherd").unwrap();
        assert_eq!(sh.description, "Move every session through its plan.");
        assert_eq!(sh.category, "monitoring");
        assert_eq!(sh.calls, Some(5), "spans summed across the day snapshots");
        assert_eq!(sh.runners, ["fleet-shepherd"]);
        assert_eq!(
            sh.drift_words(),
            ["deadpath"],
            "the newest snapshot only, each kind once"
        );
        assert_eq!(sh.drift.len(), 2);
        let hz = s.skills.iter().find(|k| k.name == "hz-build").unwrap();
        assert_eq!(hz.paths, ["**/*.unity", "Packages/**"]);
        assert_eq!(hz.description, "Build a Quest app");
        assert!(
            hz.drift.is_empty(),
            "an older snapshot's findings are not today's"
        );
        assert_eq!(hz.calls, Some(0));
        assert_eq!(s.drift_day, "2026-11-18");
        assert_eq!(s.use_days, 2);
        assert_eq!(s.runners, 2);
        assert_eq!(s.agents[0].name, "root-cause-analyst");
        assert_eq!(s.agents[0].tools, "Read, Grep, Bash");
        assert_eq!(s.rule_files[0].paths, [".local/bin/agentctl*"]);
    }

    #[test]
    fn flows_are_the_architecture_table_each_checked_against_its_paths() {
        let p = fixture("flows");
        let s = read(&p, &Fixed(Ok(RULES.into())), 100);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        let states: Vec<(&str, &str)> = s
            .flows
            .iter()
            .map(|f| (f.flow.as_str(), f.state.as_str()))
            .collect();
        assert_eq!(
            states,
            [
                ("Close verdict", OK),
                ("Chain", UNCHECKED),
                ("Gone", BROKEN),
                ("Short", BROKEN)
            ],
            "only the first table counts, a short row is broken not dropped"
        );
        assert_eq!(s.flows[3].why[0], "the row has 2 cells, the header 5");
        assert_eq!(s.strip["flows"], 3, "unchecked and broken both count");
        assert_eq!(
            s.flows[2].why,
            [
                "~/docs/states.md: no heading #nope",
                "~/docs/gone.svg is gone",
                "tests/gone.bats is gone"
            ]
        );
        let close = &s.flows[0];
        assert_eq!(
            close.checked,
            ["tests/states.bats"],
            "found under the second repo"
        );
        assert_eq!(
            close.svg.as_deref(),
            Some(p.home.join("docs/close.svg").as_path())
        );
        assert_eq!(
            flow_section(close).unwrap(),
            "## Close verdict\n\nOne chain.\n\n```sh\n# not a heading\n```\n\n### Changing it\n\nRun the diff.",
            "a fenced # and a deeper heading stay in, the image line goes, the next ## ends it"
        );
        assert_eq!(
            flow_section(&s.flows[1]).unwrap(),
            "## The chain: `a` -> b\n\nA then B."
        );
        assert_eq!(
            close.val("source"),
            Val::Text("docs/states.md#close-verdict".into())
        );
        assert_eq!(close.val("picture"), Val::Text("close.svg".into()));
        assert_eq!(s.flows[1].val("picture"), Val::None);
    }

    #[test]
    fn no_flows_table_is_an_error_not_an_empty_list_that_reads_as_fine() {
        let p = fixture("noflows");
        put(&p.architecture, "# map\n\n## Instruments\n");
        let s = read(&p, &Fixed(Ok(RULES.into())), 100);
        assert!(s.flows.is_empty());
        assert!(
            s.errors.iter().any(|e| e.contains("no ## Flows")),
            "{:?}",
            s.errors
        );
    }

    #[test]
    fn slug_is_the_github_anchor() {
        assert_eq!(
            slug("The dispatcher: `fleet-dispatch`"),
            "the-dispatcher-fleet-dispatch"
        );
        assert_eq!(
            slug("The flow: inbox to ledger"),
            "the-flow-inbox-to-ledger"
        );
        assert_eq!(slug("The chain: `a` -> b"), "the-chain-a---b");
    }

    #[test]
    fn a_hook_whose_script_is_gone_is_missing() {
        let p = fixture("hooks");
        let s = read(&p, &Fixed(Ok("[]".into())), 0);
        let poll = s
            .hooks
            .iter()
            .find(|h| h.script == "block-poll.py")
            .unwrap();
        assert!(!poll.found);
        assert!(poll.in_state(MISSING));
        let echo = s.hooks.iter().find(|h| h.command == "echo hi").unwrap();
        assert!(echo.found, "a command naming no script is not missing");
        let post = s.hooks.iter().find(|h| h.from == "stop-post.d").unwrap();
        assert_eq!(
            (post.event.as_str(), post.script.as_str()),
            ("Stop", "88-ask-filed.sh")
        );
        assert_eq!(s.strip["hooks"], 1);
        assert_eq!(
            poll.vals("matcher").len(),
            2,
            "each matcher alternative is a filter value"
        );
    }

    #[test]
    fn a_rule_says_stale_moved_restates_or_ok() {
        let p = fixture("rules");
        let s = read(&p, &Fixed(Ok(RULES.into())), 0);
        let states: Vec<&str> = s.rules.iter().map(|r| r.state.as_str()).collect();
        assert_eq!(states, [MOVED, OK, STALE, OK, RESTATES, ABSENT]);
        assert_eq!(
            s.rules[3].number, "max_live in sources (now 2)",
            "a reading shows what it read"
        );
        assert_eq!(
            s.rules[0].number, "50",
            "an unmeasured rule shows its number as recorded"
        );
        assert_eq!(
            s.strip["rules"], 3,
            "every row not ok, past one whose source is elsewhere"
        );
    }

    /// Answers `ran` with outcome lines and everything else (rules) with the rules array.
    struct ByArgv(Result<String, String>);
    impl Runner for ByArgv {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            if argv.iter().any(|a| a == "ran") {
                self.0.clone()
            } else {
                Ok(RULES.into())
            }
        }
    }

    #[test]
    fn a_skill_carries_the_sessions_that_ran_it_and_a_failed_read_says_so() {
        let p = fixture("ran");
        let ran = concat!(
            r#"{"skill":"shepherd","calls":3,"session_id":"6f296b73-b7a5-4f30-8046-5d583d1f7c61","project":"dotfiles","title":"fix the gate","updated":"2026-11-18"}"#,
            "\n",
            r#"{"skill":"hz-build","calls":1,"session_id":"aaaaaaaa-1","project":"q"}"#,
            "\n",
        );
        let s = read(&p, &ByArgv(Ok(ran.into())), 100);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        let sh = s.skills.iter().find(|k| k.name == "shepherd").unwrap();
        assert_eq!(sh.ran.len(), 1);
        assert_eq!(sh.ran[0].calls, 3);
        assert_eq!(sh.ran[0].project, "dotfiles");
        assert_eq!(
            sh.ran[0].link,
            Link::to(Kind::Session, "6f296b73-b7a5-4f30-8046-5d583d1f7c61")
        );
        let bare = s.skills.iter().find(|k| k.name == "bare").unwrap();
        assert!(bare.ran.is_empty(), "a skill nobody ran has no backlinks");

        let s = read(&p, &ByArgv(Err("boom".into())), 100);
        assert!(s
            .errors
            .iter()
            .any(|e| e.starts_with("skill sessions: not read")));
        assert!(s.skills.iter().all(|k| k.ran.is_empty()));
    }

    #[test]
    fn the_skill_query_matches_one_skill_exactly() {
        let p = fixture("ranview");
        let s = read(&p, &Fixed(Ok(RULES.into())), 100);
        let rows = crate::table::View::new::<Skill>("skill:=shepherd", "", "", "").apply(&s.skills);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "shepherd");
    }

    #[test]
    fn a_store_that_cannot_be_read_says_so() {
        let p = fixture("gone");
        std::fs::remove_dir_all(&p.drift).unwrap();
        std::fs::remove_dir_all(&p.tokens).unwrap();
        let s = read(&p, &Fixed(Err("not found".into())), 0);
        assert!(s
            .errors
            .iter()
            .any(|e| e.starts_with("skill drift: not read")));
        assert!(s.errors.iter().any(|e| e.starts_with("rules: not read")));
        assert!(
            s.skills.iter().all(|k| k.calls.is_none()),
            "no snapshot is no data, not zero"
        );
        // Negative control: the same tree with the skill gone counts one fewer.
        std::fs::remove_dir_all(p.skills.join("shepherd")).unwrap();
        assert_eq!(read(&p, &Fixed(Ok("[]".into())), 0).skills.len(), 2);
    }

    #[test]
    fn frontmatter_reads_blocks_lists_and_one_level_of_nesting() {
        let fm = frontmatter("---\na: 1\nb: |\n  x\n  y\nm:\n  k: v\n  t: [p, q]\nl:\n  - one\n  - 'two'\nz: \"q\"\n---\nbody: no\n");
        assert_eq!(fm["a"], "1");
        assert_eq!(fm["b"], "x\ny");
        assert_eq!(fm["m.k"], "v");
        assert_eq!(list(&fm["m.t"]), ["p", "q"]);
        assert_eq!(list(&fm["l"]), ["one", "two"]);
        assert_eq!(fm["z"], "q");
        assert!(!fm.contains_key("body"));
        assert!(frontmatter("no fm\n").is_empty());
        let flush = frontmatter("---\npaths:\n- \"Assets/**\"\n- b\nname: x\n---\n");
        assert_eq!(
            list(&flush["paths"]),
            ["Assets/**", "b"],
            "a list at its key's own indent"
        );
        assert_eq!(flush["name"], "x");
    }

    #[test]
    fn a_hook_script_is_judged_only_where_its_path_names_its_place() {
        let home = tmp("script");
        std::fs::write(home.join("here.sh"), "").unwrap();
        assert_eq!(
            script_of("bash \"$HOME/here.sh\" x", &home),
            ("here.sh".into(), true)
        );
        assert_eq!(
            script_of("${HOME}/gone.sh", &home),
            ("gone.sh".into(), false)
        );
        assert_eq!(script_of("'~/gone.py'", &home), ("gone.py".into(), false));
        assert!(
            script_of("$CLAUDE_PROJECT_DIR/x.sh", &home).1,
            "another variable is not judged"
        );
        assert!(
            script_of("hooks/x.sh", &home).1,
            "a relative path is not judged"
        );
    }

    #[test]
    fn an_empty_matcher_filters_as_the_star_it_shows() {
        let h = Hook::default();
        assert_eq!(h.vals("matcher"), [h.val("matcher")]);
        assert_eq!(h.val("matcher"), text("*"));
    }

    #[test]
    fn an_unused_skill_is_shown_but_not_counted_as_drift() {
        let f = |kind: &str| Finding {
            kind: kind.into(),
            ..Default::default()
        };
        let mut s = Skill {
            drift: vec![f("unused")],
            ..Default::default()
        };
        assert!(!s.drifts());
        assert_eq!(s.drift_words(), ["unused"]);
        s.drift.push(f("deadpath"));
        assert!(s.drifts());
    }
}
