//! The Stack tab: what the agent system is made of (`hub_core::stack`), one shared data table
//! (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear) per inner tab, Left/Right
//! between them. Enter opens the selected row's pane under the list; agent-web draws the same
//! four tables from the same read.

use hub_core::layout::{self, Inner, Tab};
use hub_core::stack::{Agent, Hook, Rule, Skill, Stack};
use hub_core::table::Row;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, wrap, Cell, Table};
use crate::fmt::Palette;

/// How one table fits a width: its header (`COLUMNS` in capitals, in order, so the sort mark
/// lands by index), the columns kept first (the rest drop from the end as the width shrinks, so
/// at 80 the column that says what is wrong stays), the one that flexes, and the caps.
struct Fit {
    head: &'static [&'static str],
    keep: &'static [usize],
    flex: Option<usize>,
    cap: &'static [(usize, usize)],
    none: &'static str,
}
const SKILLS: Fit = Fit {
    head: &["SKILL", "CATEGORY", "REPO", "CALLS", "RUNNERS", "DRIFT"],
    keep: &[0, 5, 3, 1, 4, 2],
    flex: None,
    cap: &[(0, 28), (4, 24), (5, 24)],
    none: "no skills are installed",
};
const AGENTS: Fit = Fit {
    head: &["AGENT", "MODEL", "TOOLS", "REPO"],
    keep: &[0, 1, 3, 2],
    flex: None,
    cap: &[(0, 28), (2, 30)],
    none: "no subagents are defined",
};
const HOOKS: Fit = Fit {
    head: &["HARNESS", "EVENT", "MATCHER", "SCRIPT", "FROM"],
    keep: &[3, 1, 0, 2, 4],
    flex: None,
    cap: &[(2, 20), (3, 30), (4, 24)],
    none: "no hooks are configured",
};
const RULES: Fit = Fit {
    head: &["RULE", "KIND", "NUMBER", "CONFIDENCE", "STATE", "SOURCE"],
    keep: &[0, 4, 1, 2, 3, 5],
    flex: Some(0),
    cap: &[(0, 50), (2, 16), (5, 24)],
    none: "no rules are recorded",
};
/// The width of the pane's labels, as the longest one.
const LABEL: usize = 10;

pub fn tab() -> &'static Tab {
    layout::resolve("stack").expect("hub_core::layout has a stack tab")
}

#[derive(Default)]
pub struct StackView {
    /// The open inner tab's id; "" is the first.
    pub inner: &'static str,
    pub skills: DataTable,
    pub agents: DataTable,
    pub hooks: DataTable,
    pub rules: DataTable,
    /// Whether the selected row's pane is open, and how far it is scrolled.
    pub open: bool,
    pub down: usize,
}

impl StackView {
    pub fn on(&self) -> &'static str {
        if self.inner.is_empty() {
            tab().inner[0].id
        } else {
            self.inner
        }
    }

    /// The open inner tab's table.
    pub fn table(&mut self) -> &mut DataTable {
        match self.on() {
            "agents" => &mut self.agents,
            "hooks" => &mut self.hooks,
            "rules" => &mut self.rules,
            _ => &mut self.skills,
        }
    }

    pub fn typing(&self) -> bool {
        [&self.skills, &self.agents, &self.hooks, &self.rules]
            .iter()
            .any(|t| t.typing.is_some())
    }

    /// How many rows the open table's view keeps.
    fn rows(&self, s: &Stack) -> usize {
        match self.on() {
            "agents" => self.agents.view.apply(&s.agents).len(),
            "hooks" => self.hooks.view.apply(&s.hooks).len(),
            "rules" => self.rules.view.apply(&s.rules).len(),
            _ => self.skills.view.apply(&s.skills).len(),
        }
    }

    /// A new read keeps each table's selection inside the rows its view keeps.
    pub fn clamp(&mut self, s: &Stack) {
        self.skills.clamp(self.skills.view.apply(&s.skills).len());
        self.agents.clamp(self.agents.view.apply(&s.agents).len());
        self.hooks.clamp(self.hooks.view.apply(&s.hooks).len());
        self.rules.clamp(self.rules.view.apply(&s.rules).len());
    }

    /// One key: Left/Right switch the inner tab, the table's keys change its view, j/k and the
    /// page keys move its selection, Enter opens or shuts the pane (J/K scroll it), Esc shuts the
    /// pane and then clears the view. False for a key that is not the tab's.
    pub fn key(&mut self, k: KeyEvent, s: Option<&Stack>, page: usize) -> bool {
        if k.modifiers.intersects(KeyModifiers::ALT) {
            return false;
        }
        let typing = self.typing();
        if matches!(k.code, KeyCode::Left | KeyCode::Right) && !typing {
            self.inner = crate::innertabs::step(tab(), self.on(), k.code == KeyCode::Left);
            self.open = false;
            self.down = 0;
            return true;
        }
        let took = match self.on() {
            "agents" => self.agents.key::<Agent>(k.code),
            "hooks" => self.hooks.key::<Hook>(k.code),
            "rules" => self.rules.key::<Rule>(k.code),
            _ => self.skills.key::<Skill>(k.code),
        };
        if took != Took::No {
            return true;
        }
        let n = s.map_or(0, |s| self.rows(s));
        let before = self.table().sel;
        match k.code {
            KeyCode::Char('J') if self.open => self.down += 1,
            KeyCode::Char('K') if self.open => self.down = self.down.saturating_sub(1),
            KeyCode::Enter => self.open = !self.open,
            KeyCode::Esc if self.open => self.open = false,
            KeyCode::Esc if !self.table().is_default() => self.table().clear(),
            _ if self.table().moves(k, n, page) => {}
            _ => return false,
        }
        if self.table().sel != before {
            self.down = 0;
        }
        true
    }

    /// The strip, each inner tab with its count of rows needing a look (`Stack::strip`).
    pub fn strip(&self, s: Option<&Stack>, p: Palette, w: usize) -> Line<'static> {
        let count = |i: &Inner| s.and_then(|s| s.strip.get(i.id).copied()).unwrap_or(0);
        crate::innertabs::strip_of(tab().inner, self.on(), count, p, w)
    }

    /// The open table's status lines: what was read, the view's chips, and what could not be
    /// read; then its fitted table, the selection marked.
    pub fn page(&mut self, s: &Stack, p: Palette, w: usize) -> (Vec<Line<'static>>, Vec<Line<'static>>) {
        let mut status: Vec<Line<'static>> = head(s).into_iter().map(|l| Line::styled(l, p.dim())).collect();
        let (spans, table) = match self.on() {
            "agents" => (
                counted(&self.agents, &s.agents, p),
                fitted(&self.agents, &s.agents, &AGENTS, agent_row, p, w),
            ),
            "hooks" => (
                counted(&self.hooks, &s.hooks, p),
                fitted(&self.hooks, &s.hooks, &HOOKS, hook_row, p, w),
            ),
            "rules" => (
                counted(&self.rules, &s.rules, p),
                fitted(&self.rules, &s.rules, &RULES, rule_row, p, w),
            ),
            _ => (
                counted(&self.skills, &s.skills, p),
                fitted(&self.skills, &s.skills, &SKILLS, skill_row, p, w),
            ),
        };
        status.push(Line::from(spans));
        if !s.errors.is_empty() {
            status.push(Line::styled(format!("unread: {}", s.errors.join("; ")), p.warn()));
        }
        (status, table)
    }

    /// The selected row's pane, wrapped to `w`.
    pub fn detail(&self, s: &Stack, p: Palette, w: usize) -> Vec<Line<'static>> {
        let width = w.saturating_sub(LABEL + 3).max(20);
        let mut out: Vec<Line<'static>> = vec![];
        let mut part = |label: &str, text: &str| {
            let words: Vec<&str> = text.split_whitespace().collect();
            for (i, l) in wrap(&words, " ", width).into_iter().enumerate() {
                let name = if i == 0 { label } else { "" };
                out.push(Line::from(vec![
                    Span::styled(format!("  {name:<LABEL$} "), p.dim()),
                    Span::raw(l),
                ]));
            }
        };
        match self.on() {
            "agents" => {
                if let Some(a) = self.agents.view.apply(&s.agents).get(self.agents.sel) {
                    part("Agent", &a.name);
                    part("Does", &a.description);
                    part("Tools", &a.tools);
                }
            }
            "hooks" => {
                if let Some(h) = self.hooks.view.apply(&s.hooks).get(self.hooks.sel) {
                    part("Hook", &format!("{} {}", h.harness, h.event));
                    part("Runs", &h.command);
                    if !h.found {
                        part("Missing", "the script it names is not on disk");
                    }
                }
            }
            "rules" => {
                if let Some(r) = self.rules.view.apply(&s.rules).get(self.rules.sel) {
                    part("Rule", &r.rule);
                    part("Why", &r.why);
                    part("Today", &r.today);
                    part("Revisit", &r.revisit);
                    part("Source", &r.source);
                }
            }
            _ => {
                if let Some(k) = self.skills.view.apply(&s.skills).get(self.skills.sel) {
                    part("Skill", &k.name);
                    part("Does", &k.description);
                    part("Loads on", &k.paths.join(", "));
                    part("Runners", &k.runners.join(", "));
                    for f in &k.drift {
                        part("Drift", &format!("{} {} {}", f.kind, f.item, f.detail));
                    }
                }
            }
        }
        out
    }
}

/// What the tab read, in two short lines: the drift snapshot's day and the window the calls
/// count; then the runners, whose home is Sessions' Runners (rule 2), named by its bar label.
fn head(s: &Stack) -> [String; 2] {
    let drift = if s.drift_day.is_empty() {
        format!("drift {}", hub_core::reading::NOT_READ)
    } else {
        format!("drift as of {}", s.drift_day)
    };
    [
        format!("{drift}; calls over the last {} days", s.use_days),
        format!(
            "{} runners: {} > Runners",
            s.runners,
            layout::bar_label("sessions")
        ),
    ]
}

fn counted<R: Row>(t: &DataTable, rows: &[R], p: Palette) -> Vec<Span<'static>> {
    let mut spans = t.status(rows, p);
    spans.push(Span::styled(
        format!("    {} of {}", t.view.apply(rows).len(), rows.len()),
        p.dim(),
    ));
    spans
}

/// One table fitted to `w` by its `Fit`, the selection marked.
fn fitted<R: Row>(
    t: &DataTable,
    rows: &[R],
    fit: &Fit,
    row: fn(&R, Palette) -> Vec<Cell>,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let shown = t.view.apply(rows);
    if shown.is_empty() {
        let why = if rows.is_empty() {
            fit.none.to_string()
        } else {
            "nothing matches (/ query, f state, x clears)".to_string()
        };
        return vec![Line::styled(why, p.dim())];
    }
    let mut out = Table {
        header: fit.head.to_vec(),
        rows: shown.iter().map(|r| row(r, p)).collect(),
        keep: fit.keep.to_vec(),
        flex: fit.flex,
        flexmin: 24,
        flexkeep: false,
        right: vec![],
        cap: fit.cap.to_vec(),
        mark: t.mark::<R>(),
    }
    .fit(w, p.head());
    t.style(&mut out, p);
    out
}

fn text(s: &str) -> Cell {
    if s.is_empty() { "-".into() } else { s.to_string().into() }
}

fn skill_row(r: &Skill, p: Palette) -> Vec<Cell> {
    let drift = r.drift_words().join(", ");
    vec![
        r.name.clone().into(),
        cell(r.category.clone(), p.dim()),
        cell(r.repo.clone(), p.dim()),
        r.calls.map_or("-".into(), |n| n.to_string()).into(),
        text(&r.runners.join(", ")),
        if drift.is_empty() { "-".into() } else { cell(drift, p.warn()) },
    ]
}

fn agent_row(r: &Agent, p: Palette) -> Vec<Cell> {
    vec![
        r.name.clone().into(),
        if r.model.is_empty() { cell("inherit", p.dim()) } else { r.model.clone().into() },
        cell(r.tools.clone(), p.dim()),
        cell(r.repo.clone(), p.dim()),
    ]
}

fn hook_row(r: &Hook, p: Palette) -> Vec<Cell> {
    vec![
        cell(r.harness.clone(), p.dim()),
        r.event.clone().into(),
        cell(if r.matcher.is_empty() { "*".into() } else { r.matcher.clone() }, p.dim()),
        if r.found { r.script.clone().into() } else { cell(format!("{} (missing)", r.script), p.bad()) },
        cell(r.from.clone(), p.dim()),
    ]
}

fn rule_row(r: &Rule, p: Palette) -> Vec<Cell> {
    let state = match r.state.as_str() {
        hub_core::stack::OK => Style::default(),
        hub_core::stack::DEAD => p.bad(),
        _ => p.warn(),
    };
    vec![
        r.rule.clone().into(),
        cell(r.kind.clone(), p.dim()),
        text(&r.number),
        cell(r.confidence.clone(), p.dim()),
        cell(r.state.clone(), state),
        cell(r.source.clone(), p.dim()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_headers_are_hub_cores_columns() {
        let caps = |c: &[&str]| c.iter().map(|k| k.to_uppercase()).collect::<Vec<_>>();
        for (fit, cols) in [
            (&SKILLS, Skill::COLUMNS),
            (&AGENTS, Agent::COLUMNS),
            (&HOOKS, Hook::COLUMNS),
            (&RULES, Rule::COLUMNS),
        ] {
            assert_eq!(fit.head.to_vec(), caps(cols));
            let mut keep = fit.keep.to_vec();
            keep.sort_unstable();
            assert_eq!(keep, (0..cols.len()).collect::<Vec<_>>(), "keep names each column once");
        }
    }

    #[test]
    fn left_and_right_walk_the_inner_tabs_and_each_keeps_its_view() {
        let mut v = StackView::default();
        let key = |c| KeyEvent::new(c, KeyModifiers::NONE);
        assert_eq!(v.on(), "skills");
        assert!(v.key(key(KeyCode::Char('f')), None, 10));
        assert!(!v.skills.view.is_default(), "f stepped the skills chip");
        assert!(v.key(key(KeyCode::Right), None, 10));
        assert_eq!(v.on(), "agents");
        assert!(v.agents.view.is_default(), "another table's view is its own");
        assert!(v.key(key(KeyCode::Left), None, 10));
        assert!(v.key(key(KeyCode::Left), None, 10));
        assert_eq!(v.on(), "rules", "Left wraps");
    }

    #[test]
    fn a_missing_hook_draws_as_missing() {
        let s = Stack {
            hooks: vec![Hook {
                harness: "claude".into(),
                event: "Stop".into(),
                script: "gone.sh".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let mut v = StackView {
            inner: "hooks",
            ..Default::default()
        };
        let (_, table) = v.page(&s, Palette::default(), 80);
        let all: String = table.iter().flat_map(|l| l.spans.iter()).map(|s| s.content.to_string()).collect();
        assert!(all.contains("gone.sh (missing)"), "{all}");
    }
}
