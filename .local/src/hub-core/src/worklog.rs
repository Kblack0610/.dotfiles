//! Log's Work table: everything done and not done across every project, in one list. Each queue
//! item is a row, and a PR gets a row of its own only when no item claims it. Items come from
//! `agent-queue list`, PRs from day-log's records: `merged[]` of every day and `open[]` of the
//! newest only, an older record's open PR being stale. This module stores nothing.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, NaiveDate, TimeZone};
use serde::Serialize;
use serde_json::Value;

use crate::boards;
use crate::queue::{self, Item, State};
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// The rows a page is sent unless it asks for all of them.
pub const SHOWN: usize = 200;

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Work {
    /// `failed`, `waiting`, `active`, `open`, `done`, `cancelled` or `queued`.
    pub state: &'static str,
    /// Local `YYYY-MM-DDTHH:MM`: when it finished, or when it reached the state it is in.
    pub when: Option<String>,
    pub project: String,
    pub what: String,
    pub kind: Option<String>,
    /// `repo#N`, then `+N` when the item has more than one.
    pub pr: Option<String>,
    pub url: Option<String>,
    pub cost: Option<f64>,
    /// The queue item; None for a PR no item claims.
    pub slug: Option<String>,
    /// Finished ok with no PR and no report: it stays Done, flagged.
    pub unproven: bool,
}

impl Work {
    fn finished(&self) -> bool {
        matches!(self.state, "done" | "failed" | "cancelled")
    }

    /// The default order: what needs attention first, the queue's long tail last.
    fn attention(&self) -> u8 {
        match self.state {
            "failed" => 0,
            "waiting" => 1,
            "active" | "open" | "review" => 2,
            "done" => 3,
            "cancelled" => 4,
            _ => 5,
        }
    }
}

impl Row for Work {
    const COLUMNS: &'static [&'static str] =
        &["state", "when", "project", "what", "kind", "pr", "cost"];
    const STATES: &'static [&'static str] = &[
        "all",
        "done",
        "active",
        "waiting",
        "review",
        "queued",
        "failed",
        "cancelled",
    ];
    const FACETS: &'static [&'static str] = &["project", "kind"];
    const LEAD: &'static str = "what";
    const GLANCE: &'static [&'static str] = &["state", "project", "when"];

    fn val(&self, col: &str) -> Val {
        let text = |s: Option<&str>| s.map_or(Val::None, |s| Val::Text(s.to_string()));
        match col {
            "state" => Val::Text(self.state.to_string()),
            "when" => text(self.when.as_deref()),
            "project" => Val::Text(self.project.clone()),
            "what" => Val::Text(self.what.clone()),
            "kind" => text(self.kind.as_deref()),
            "pr" => text(self.pr.as_deref()),
            "cost" => self.cost.map_or(Val::None, Val::Num),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        match state {
            "active" => matches!(self.state, "active" | "open"),
            s => self.state == s,
        }
    }
}

/// What a read found, and how far back each source goes.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Gathered {
    pub rows: Vec<Work>,
    pub errors: Vec<String>,
    /// The oldest day a finished item is known from.
    pub items_from: Option<String>,
    /// The oldest day-log record.
    pub prs_from: Option<String>,
}

/// One PR from a day-log record.
struct Pr {
    key: String,
    repo: String,
    number: String,
    project: String,
    title: String,
    url: String,
    at: Option<String>,
    open: bool,
    check: Option<String>,
}

/// `owner/repo#N`, lowercased, from a PR's page.
fn url_key(url: &str) -> Option<String> {
    let parts: Vec<&str> = url.trim_end_matches('/').split('/').collect();
    let at = parts.iter().position(|p| *p == "pull" || *p == "pulls")?;
    let (owner, repo, n) = (
        parts.get(at.checked_sub(2)?)?,
        parts.get(at - 1)?,
        parts.get(at + 1)?,
    );
    Some(format!("{owner}/{repo}#{n}").to_lowercase())
}

/// A time as local `YYYY-MM-DDTHH:MM`.
fn local<Tz: TimeZone>(ts: &str, tz: &Tz) -> Option<String>
where
    Tz::Offset: std::fmt::Display,
{
    DateTime::parse_from_rfc3339(ts.trim())
        .ok()
        .map(|t| t.with_timezone(tz).format("%Y-%m-%dT%H:%M").to_string())
}

/// The conventional-commit type a PR's title starts with, so `kind:fix` finds items and PRs.
fn title_kind(title: &str) -> Option<String> {
    let head = title.split(':').next().filter(|h| h.len() < title.len())?;
    let kind = head.split('(').next()?.trim_end_matches('!');
    (!kind.is_empty() && kind.chars().all(|c| c.is_ascii_lowercase())).then(|| kind.to_string())
}

/// The canonical project a day-log row means, through project-map.json's basenames and aliases.
fn canonical(names: &HashMap<String, String>, project: String) -> String {
    names.get(&project).cloned().unwrap_or(project)
}

/// Basename and alias to project name, from project-map.json's text. Unreadable maps to nothing.
pub fn names_from(map: &str) -> HashMap<String, String> {
    let v: Value = serde_json::from_str(map).unwrap_or_default();
    let mut names = HashMap::new();
    for (path, name) in v["paths"].as_object().into_iter().flatten() {
        if let (Some(base), Some(name)) = (path.rsplit('/').next(), name.as_str()) {
            names.insert(base.trim_start_matches('.').to_string(), name.to_string());
        }
    }
    for (alias, name) in v["aliases"].as_object().into_iter().flatten() {
        if let Some(name) = name.as_str() {
            names.insert(alias.clone(), name.to_string());
        }
    }
    names
}

/// What an open PR's row says before its title: that it is a draft, else its CI state.
fn check_of(v: &Value) -> Option<String> {
    if v["draft"].as_bool() == Some(true) {
        return Some("draft".to_string());
    }
    v["ci"]
        .as_str()
        .map(|ci| format!("CI {}", ci.to_lowercase()))
}

/// A row's text, led by what its open PR needs someone to know.
fn tagged(what: String, pr: Option<&Pr>) -> String {
    match pr.and_then(|p| p.check.as_deref()) {
        Some(check) => format!("[{check}] {what}"),
        None => what,
    }
}

fn pr_of<Tz: TimeZone>(
    v: &Value,
    open: bool,
    names: &HashMap<String, String>,
    tz: &Tz,
) -> Option<Pr>
where
    Tz::Offset: std::fmt::Display,
{
    let url = v["url"].as_str()?;
    let key = url_key(url)?;
    let (_, number) = key.rsplit_once('#')?;
    let stamp = if open { "created_at" } else { "merged_at" };
    Some(Pr {
        repo: v["repo"].as_str().unwrap_or("").to_string(),
        number: number.to_string(),
        project: canonical(names, boards::pr_project(v)),
        title: v["title"].as_str().unwrap_or("").to_string(),
        url: url.to_string(),
        at: v[stamp].as_str().and_then(|t| local(t, tz)),
        open,
        check: if open { check_of(v) } else { None },
        key,
    })
}

/// The PR one word of an item's `pr` names. `owner/repo#N` and a URL say so outright. A legacy
/// `repo#N` looks the repo up among the PRs with that number. A bare number is the one PR with
/// that number in the item's project, or the only PR with that number anywhere.
fn claimed(word: &str, project: &str, by_number: &HashMap<&str, Vec<&Pr>>) -> Option<String> {
    let w = word.to_lowercase();
    if w.starts_with("http") {
        return url_key(&w);
    }
    let (repo, n) = w.split_once('#').unwrap_or(("", &w));
    if n.is_empty() || !n.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    if repo.contains('/') {
        return Some(w.clone());
    }
    let found = by_number.get(n)?;
    let only = |list: Vec<&&Pr>| match list.as_slice() {
        [one] => Some(one.key.clone()),
        _ => None,
    };
    if !repo.is_empty() {
        let short = repo.trim_start_matches('.');
        return only(
            found
                .iter()
                .filter(|p| p.repo.trim_start_matches('.').eq_ignore_ascii_case(short))
                .collect(),
        );
    }
    only(
        found
            .iter()
            .filter(|p| p.project.eq_ignore_ascii_case(project))
            .collect(),
    )
    .or_else(|| only(found.iter().collect()))
}

fn pr_words(item: &Item) -> Vec<&str> {
    item.pr
        .as_deref()
        .unwrap_or("")
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|w| !w.is_empty())
        .collect()
}

fn item_row<Tz: TimeZone>(i: &Item, keys: &[String], prs: &HashMap<&str, &Pr>, tz: &Tz) -> Work
where
    Tz::Offset: std::fmt::Display,
{
    let at = |ts: &Option<String>| ts.as_deref().and_then(|t| local(t, tz));
    let (state, when) = match i.state {
        State::Done => (
            match i.status.as_deref() {
                Some("failed") => "failed",
                Some("cancelled") => "cancelled",
                _ => "done",
            },
            at(&i.finished),
        ),
        State::Waiting => ("waiting", at(&i.waiting).or_else(|| at(&i.started))),
        State::Review => (
            "review",
            at(&i.review)
                .or_else(|| at(&i.waiting))
                .or_else(|| at(&i.started)),
        ),
        State::Running => ("active", at(&i.started)),
        State::Queued => ("queued", at(&i.queued)),
    };
    let words = pr_words(i);
    let first = keys.iter().find_map(|k| prs.get(k.as_str())).copied();
    let link = words.first().and_then(|w| queue::pr_link_of(w));
    let label = first
        .map(|p| format!("{}#{}", p.repo, p.number))
        .or_else(|| link.as_ref().map(|(label, _)| label.clone()));
    let more = words.iter().collect::<HashSet<_>>().len().saturating_sub(1);
    Work {
        state,
        when,
        project: i.project.trim().to_string(),
        what: tagged(i.title(), first),
        kind: i.kind.clone().filter(|k| !k.is_empty()),
        pr: label.map(|l| if more > 0 { format!("{l} +{more}") } else { l }),
        url: first
            .map(|p| p.url.clone())
            .or_else(|| link.and_then(|(_, url)| url)),
        cost: i.cost(),
        slug: Some(i.slug.clone()),
        unproven: i.unproven(),
    }
}

fn pr_row(p: &Pr) -> Work {
    Work {
        state: if p.open { "open" } else { "done" },
        when: p.at.clone(),
        project: p.project.clone(),
        what: tagged(p.title.clone(), Some(p)),
        kind: title_kind(&p.title),
        pr: Some(format!("{}#{}", p.repo, p.number)),
        url: Some(p.url.clone()),
        cost: None,
        slug: None,
        unproven: false,
    }
}

/// One row per item, one per unclaimed PR, attention first and newest first inside that. Queued
/// items keep agent-queue's order, which is the order they will start in.
pub fn gather<Tz: TimeZone>(
    items: &[Item],
    days: &[(String, Value)],
    names: &HashMap<String, String>,
    tz: &Tz,
) -> Gathered
where
    Tz::Offset: std::fmt::Display,
{
    let list = |v: &Value, key: &str, open: bool| -> Vec<Pr> {
        v[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| pr_of(p, open, names, tz))
            .collect()
    };
    let merged = days.iter().flat_map(|(_, r)| list(r, "merged", false));
    let open = days
        .last()
        .into_iter()
        .flat_map(|(_, r)| list(r, "open", true));
    // Merged first, so a PR also listed open reads as merged; the first record of a PR wins.
    let mut seen = HashSet::new();
    let prs: Vec<Pr> = merged
        .chain(open)
        .filter(|p| seen.insert(p.key.clone()))
        .collect();
    let by_key: HashMap<&str, &Pr> = prs.iter().map(|p| (p.key.as_str(), p)).collect();
    let mut by_number: HashMap<&str, Vec<&Pr>> = HashMap::new();
    for p in &prs {
        by_number.entry(p.number.as_str()).or_default().push(p);
    }

    let mut claims = HashSet::new();
    let mut rows: Vec<Work> = items
        .iter()
        .map(|i| {
            let keys: Vec<String> = pr_words(i)
                .into_iter()
                .filter_map(|w| claimed(w, i.project.trim(), &by_number))
                .collect();
            let row = item_row(i, &keys, &by_key, tz);
            claims.extend(keys);
            row
        })
        .collect();
    rows.extend(prs.iter().filter(|p| !claims.contains(&p.key)).map(pr_row));
    let key = |r: &Work| match r.state {
        "queued" => String::new(),
        _ => r.when.clone().unwrap_or_default(),
    };
    rows.sort_by(|a, b| {
        a.attention()
            .cmp(&b.attention())
            .then_with(|| key(b).cmp(&key(a)))
    });

    Gathered {
        items_from: items
            .iter()
            .filter(|i| i.state == State::Done)
            .filter_map(|i| i.finished.as_deref().and_then(|t| local(t, tz)))
            .min()
            .map(|t| t[..10].to_string()),
        prs_from: days.first().map(|(d, _)| d.clone()),
        rows,
        errors: vec![],
    }
}

/// The one superset read; a surface narrows it with a [`Window`] and a table view.
pub fn read(runner: &dyn Runner) -> Gathered {
    let mut errors = vec![];
    // With no items every PR would look unclaimed, so a failed read says that and shows no rows.
    let items = match queue::list_since(runner, "all", "2000-01-01") {
        Ok(items) => items,
        Err(e) => {
            return Gathered {
                errors: vec![e],
                ..Gathered::default()
            }
        }
    };
    let dir = boards::daylog_dir();
    let days: Vec<(String, Value)> = boards::days(&dir)
        .into_iter()
        .filter_map(|d| match boards::record(&dir, Some(&d)) {
            Some(r) => Some((d, r)),
            None => {
                errors.push(format!("day-log {d}: unreadable"));
                None
            }
        })
        .collect();
    let names = std::fs::read_to_string(crate::projects::map_path())
        .map(|m| names_from(&m))
        .unwrap_or_default();
    let mut g = gather(&items, &days, &names, &chrono::Local);
    g.errors = errors;
    g
}

/// How far back finished rows reach. Unfinished rows stay in every window but a past day:
/// something stuck for five days is still not done.
#[derive(Debug, Clone, PartialEq)]
pub enum Window {
    Since(String),
    Day(String),
    All,
}

impl Window {
    /// `today`, `7d`, `30d`, `all` or a `YYYY-MM-DD`; anything else is the default, 7d.
    pub fn parse(asked: &str, today: NaiveDate) -> Window {
        let since = |days: u64| {
            let d = today - chrono::Days::new(days - 1);
            Window::Since(d.format("%Y-%m-%d").to_string())
        };
        match asked {
            "today" => since(1),
            "30d" => since(30),
            "all" => Window::All,
            d => match NaiveDate::parse_from_str(d, "%Y-%m-%d") {
                Ok(day) if day == today => since(1),
                Ok(_) => Window::Day(d.to_string()),
                Err(_) => since(7),
            },
        }
    }

    pub fn keeps(&self, r: &Work) -> bool {
        let when = r.when.as_deref();
        match self {
            Window::All => true,
            Window::Day(d) => r.finished() && when.is_some_and(|w| w.starts_with(d.as_str())),
            // A row with no time cannot be placed outside a window, so it is not hidden by one.
            Window::Since(d) => !r.finished() || when.is_none_or(|w| w >= d.as_str()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use serde_json::json;

    /// An item as every view reads one: through `queue::parse`, which names a plan item.
    fn item(slug: &str, state: &str, extra: Value) -> Item {
        let mut v = json!({"slug": slug, "project": "dotfiles", "state": state, "task": slug,
            "queued": "2026-11-01T10:00:00Z"});
        v.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        queue::parse(&v.to_string()).remove(0)
    }

    fn pr(repo: &str, n: u32, at: &str) -> Value {
        json!({"repo": repo, "project": null, "number": n, "title": format!("fix(x): pr {n}"),
            "url": format!("https://github.com/Kb/{repo}/pull/{n}"), "merged_at": at,
            "created_at": at})
    }

    fn work(items: &[Item], days: Vec<(&str, Value)>) -> Vec<Work> {
        let days: Vec<(String, Value)> =
            days.into_iter().map(|(d, r)| (d.to_string(), r)).collect();
        gather(items, &days, &HashMap::new(), &Utc).rows
    }

    const AT: &str = "2026-11-08T09:30:00Z";

    #[test]
    fn an_item_claims_its_pr_and_a_pr_nobody_claims_gets_its_own_row() {
        let i = item(
            "a",
            "done",
            json!({"status": "ok", "finished": AT, "pr": "Kb/.dotfiles#7", "merged": "abc"}),
        );
        let rows = work(
            &[i],
            vec![(
                "2026-11-08",
                json!({"merged": [pr(".dotfiles", 7, AT), pr(".dotfiles", 8, AT)]}),
            )],
        );
        assert_eq!(rows.len(), 2);
        let mine = rows.iter().find(|r| r.slug.is_some()).unwrap();
        assert_eq!(mine.pr.as_deref(), Some(".dotfiles#7"));
        assert_eq!(
            mine.url.as_deref(),
            Some("https://github.com/Kb/.dotfiles/pull/7")
        );
        let lone = rows.iter().find(|r| r.slug.is_none()).unwrap();
        assert_eq!(lone.pr.as_deref(), Some(".dotfiles#8"));
        assert_eq!((lone.state, lone.kind.as_deref()), ("done", Some("fix")));
        assert_eq!(lone.when.as_deref(), Some("2026-11-08T09:30"));
    }

    #[test]
    fn several_items_on_one_pr_are_one_row_each_and_no_pr_row() {
        let on = |s: &str| {
            item(
                s,
                "done",
                json!({"status": "ok", "finished": AT, "pr": "kb/.DOTFILES#7"}),
            )
        };
        let rows = work(
            &[on("a"), on("b")],
            vec![("2026-11-08", json!({"merged": [pr(".dotfiles", 7, AT)]}))],
        );
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.slug.is_some()));
    }

    #[test]
    fn one_item_may_claim_several_prs() {
        let i = item(
            "a",
            "done",
            json!({"status": "ok", "finished": AT, "pr": "Kb/a#1 Kb/b#2"}),
        );
        let rows = work(
            &[i],
            vec![(
                "2026-11-08",
                json!({"merged": [pr("a", 1, AT), pr("b", 2, AT)]}),
            )],
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].pr.as_deref(), Some("a#1 +1"));
    }

    #[test]
    fn a_bare_number_is_read_inside_its_project_then_anywhere() {
        let bare = |project: &str| {
            item(
                "a",
                "done",
                json!({"status": "ok", "finished": AT, "pr": "7", "project": project}),
            )
        };
        let mut other = pr("other", 7, AT);
        other["project"] = json!("other");
        let mut mine = pr("mine", 7, AT);
        mine["project"] = json!("mine");
        let both = json!({"merged": [other, mine]});
        let rows = work(&[bare("mine")], vec![("2026-11-08", both.clone())]);
        assert_eq!(rows.len(), 2, "the other repo's #7 is still its own row");
        assert_eq!(
            rows.iter()
                .find(|r| r.slug.is_some())
                .unwrap()
                .pr
                .as_deref(),
            Some("mine#7")
        );
        assert_eq!(
            work(&[bare("nobody")], vec![("2026-11-08", both)]).len(),
            3,
            "two candidates and neither in its project claims nothing"
        );
        let one = json!({"merged": [pr("only", 7, AT)]});
        assert_eq!(work(&[bare("nobody")], vec![("2026-11-08", one)]).len(), 1);
    }

    #[test]
    fn a_legacy_repo_name_finds_its_pr() {
        let i = item(
            "a",
            "done",
            json!({"status": "ok", "finished": AT, "pr": "dotfiles#7"}),
        );
        let rows = work(
            &[i],
            vec![("2026-11-08", json!({"merged": [pr(".dotfiles", 7, AT)]}))],
        );
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn merged_wins_and_only_the_newest_record_says_what_is_open() {
        let rows = work(
            &[],
            vec![
                (
                    "2026-11-07",
                    json!({"open": [pr("r", 1, AT), pr("r", 2, AT)]}),
                ),
                (
                    "2026-11-08",
                    json!({"merged": [pr("r", 3, AT)], "open": [pr("r", 3, AT), pr("r", 4, AT)]}),
                ),
            ],
        );
        let states: Vec<(&str, &str)> = rows
            .iter()
            .map(|r| (r.pr.as_deref().unwrap(), r.state))
            .collect();
        assert_eq!(states, [("r#4", "open"), ("r#3", "done")]);
    }

    #[test]
    fn attention_comes_first_and_the_queue_keeps_its_own_order() {
        let items = [
            item("q1", "queued", json!({})),
            item("q2", "queued", json!({"queued": "2026-11-05T10:00:00Z"})),
            item(
                "ok",
                "done",
                json!({"status": "ok", "finished": AT, "report": "r"}),
            ),
            item(
                "bad",
                "done",
                json!({"status": "failed", "finished": "2026-11-02T01:00:00Z"}),
            ),
            item(
                "off",
                "done",
                json!({"status": "cancelled", "finished": AT}),
            ),
            item("run", "running", json!({"started": AT})),
            item("ask", "waiting", json!({"started": AT})),
        ];
        let order: Vec<String> = work(&items, vec![])
            .into_iter()
            .map(|r| r.slug.unwrap())
            .collect();
        assert_eq!(order, ["bad", "ask", "run", "ok", "off", "q1", "q2"]);
    }

    #[test]
    fn a_done_item_with_nothing_to_show_stays_done_and_is_flagged() {
        let i = item("a", "done", json!({"status": "ok", "finished": AT}));
        let rows = work(&[i], vec![]);
        assert_eq!((rows[0].state, rows[0].unproven), ("done", true));
    }

    #[test]
    fn a_day_log_project_goes_through_the_map() {
        let names = names_from(
            r#"{"paths": {"/x/.dotfiles": "dotfiles", "/x/platform": "bnb-platform"},
                "aliases": {"freqtrade_trading_attempt": "trader"}}"#,
        );
        assert_eq!(canonical(&names, "platform".into()), "bnb-platform");
        assert_eq!(
            canonical(&names, "freqtrade_trading_attempt".into()),
            "trader"
        );
        assert_eq!(canonical(&names, "else".into()), "else");
    }

    #[test]
    fn a_plan_item_reads_as_its_plans_name_its_phase_and_the_phases_words() {
        let dir = std::env::temp_dir().join(format!("worklog-plan-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let plan = dir.join("can-we-backfill-snuggly-bachman.md");
        std::fs::write(
            &plan,
            "# Systems you can see, every task under a feature\n\n## Phases\n",
        )
        .unwrap();
        let p = plan.to_str().unwrap();
        let items = [
            // Queued before the title was the phase's words: the file-name prefix goes.
            item(
                "old-p5",
                "done",
                json!({"plan": p, "phases": "5",
                "title": "can-we-backfill-snuggly-bachman P5: Versions going forward"}),
            ),
            item(
                "new-p4",
                "queued",
                json!({"plan": p, "phases": "4 5", "title": "Fourth thing"}),
            ),
            // The plan's own label wins over the item's place in the checklist.
            item(
                "own-p10",
                "queued",
                json!({"plan": p, "phases": "10", "title": "P9 live stage, gated"}),
            ),
            // An old-shape title with no plan field is renamed only when its plan file exists.
            item(
                "hand",
                "queued",
                json!({"title": "other-plan P2: kept as written"}),
            ),
            item(
                "multi",
                "queued",
                json!({"plan": p, "phases": "4 5", "title": "P4 Fourth; P5 Fifth"}),
            ),
            item(
                "legacy-row",
                "queued",
                json!({"title": "ghost-plan-file P10: P9 live stage"}),
            ),
        ];
        let g = gather(&items, &[], &HashMap::new(), &Utc);
        let row = |s: &str| {
            g.rows
                .iter()
                .find(|r| r.slug.as_deref() == Some(s))
                .unwrap()
        };
        assert_eq!(
            row("old-p5").what,
            "Systems you can see P5: Versions going forward"
        );
        assert_eq!(row("new-p4").what, "Systems you can see P4+5: Fourth thing");
        assert_eq!(
            row("own-p10").what,
            "Systems you can see P9: live stage, gated"
        );
        assert_eq!(
            row("multi").what,
            "Systems you can see P4+5: P4 Fourth; P5 Fifth",
            "a leading label names one of an item's two phases, so the place stands"
        );
        assert_eq!(row("hand").what, "other-plan P2: kept as written");
        assert_eq!(row("legacy-row").what, "ghost-plan-file P10: P9 live stage");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_window_narrows_finished_rows_and_a_past_day_is_only_that_day() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 9).unwrap();
        let row = |state, when: &str| Work {
            state,
            when: Some(when.into()),
            project: "p".into(),
            what: "w".into(),
            kind: None,
            pr: None,
            url: None,
            cost: None,
            slug: None,
            unproven: false,
        };
        let old = row("done", "2026-10-30T10:00");
        let week = row("failed", "2026-11-03T00:00");
        let stuck = row("active", "2026-10-01T10:00");
        let w = Window::parse("", today);
        assert!(w.keeps(&week) && w.keeps(&stuck) && !w.keeps(&old));
        assert_eq!(Window::parse("nonsense", today), w);
        let t = Window::parse("today", today);
        assert_eq!(
            Window::parse("2026-11-09", today),
            t,
            "today's date is today"
        );
        assert!(t.keeps(&stuck) && !t.keeps(&week));
        let day = Window::parse("2026-11-03", today);
        assert!(day.keeps(&week));
        assert!(
            !day.keeps(&stuck),
            "a past day shows only what finished then"
        );
        assert!(Window::parse("30d", today).keeps(&old));
        assert!(Window::parse("all", today).keeps(&old));
    }

    #[test]
    fn a_finished_row_with_no_time_stays_until_one_day_is_asked_for() {
        let rows = work(&[item("a", "done", json!({"status": "failed"}))], vec![]);
        assert_eq!(rows[0].when, None);
        assert!(Window::Since("2026-11-02".into()).keeps(&rows[0]));
        assert!(!Window::Day("2026-11-02".into()).keeps(&rows[0]));
    }

    #[test]
    fn a_failed_queue_read_says_so_and_shows_no_unclaimed_prs() {
        struct Down;
        impl Runner for Down {
            fn run(&self, _: &[String]) -> Result<String, String> {
                Err("queue down".into())
            }
        }
        let g = read(&Down);
        assert!(g.rows.is_empty());
        assert_eq!(g.errors.len(), 1);
        assert!(g.errors[0].contains("queue down"), "{:?}", g.errors);
    }

    #[test]
    fn an_open_prs_draft_or_ci_state_leads_its_row_claimed_or_not() {
        let mut red = pr(".dotfiles", 7, AT);
        red["ci"] = json!("FAILURE");
        let mut draft = pr(".dotfiles", 8, AT);
        draft["draft"] = json!(true);
        let i = item("a", "running", json!({"pr": "Kb/.dotfiles#7"}));
        let rows = work(&[i], vec![("2026-11-08", json!({"open": [red, draft]}))]);
        let what = |slugged: bool| {
            let r = rows.iter().find(|r| r.slug.is_some() == slugged).unwrap();
            r.what.clone()
        };
        assert_eq!(what(true), "[CI failure] a");
        assert_eq!(what(false), "[draft] fix(x): pr 8");
    }

    #[test]
    fn the_pr_cell_is_the_first_pr_it_can_resolve_and_counts_each_other_pr_once() {
        let i = item(
            "a",
            "done",
            json!({"status": "ok", "finished": AT, "pr": "Kb/gone#1 Kb/.dotfiles#7 Kb/.dotfiles#7"}),
        );
        let rows = work(
            &[i],
            vec![("2026-11-08", json!({"merged": [pr(".dotfiles", 7, AT)]}))],
        );
        assert_eq!(rows[0].pr.as_deref(), Some(".dotfiles#7 +1"));
        assert_eq!(
            rows[0].url.as_deref(),
            Some("https://github.com/Kb/.dotfiles/pull/7")
        );
    }

    #[test]
    fn a_chip_and_a_day_prefix_use_the_shared_table() {
        let i = item("a", "running", json!({"started": AT}));
        let rows = work(&[i], vec![]);
        let v = crate::table::View::new::<Work>("project:dot when:2026-11-08", "active", "", "");
        assert_eq!(v.apply(&rows).len(), 1);
        let v = crate::table::View::new::<Work>("when:2026-11-07", "", "", "");
        assert!(v.apply(&rows).is_empty());
    }

    #[test]
    fn the_phone_roles_name_real_columns() {
        assert!(Work::COLUMNS.contains(&Work::LEAD));
        assert!(Work::GLANCE.iter().all(|c| Work::COLUMNS.contains(c)));
    }
}
