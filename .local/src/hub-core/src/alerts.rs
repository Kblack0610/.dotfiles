//! The Alerts tab, both surfaces: what is firing, who owns its fix, what fired lately and every
//! watch. It joins readers that already exist and keeps no store of its own:
//!
//! - `infra::gather` (the caller's, already cached): the health chips, `cc:red_now` and the
//!   machinery's own reds (down runners, stuck runs, the exporter and GitHub);
//! - `fleet::runner::watches`: every Sentinel watch and its state files;
//! - `reds::read` (`fleet-bench reds --json`, the caller's, cached): the fix item queued for
//!   each red;
//! - the agent-notify ledger (`actions::parse_notify`): the pages the alert senders wrote;
//! - `alertmanager::read` (asked inside `infra::gather`, so cached with it): what the cluster's
//!   rules have firing, one row per alert.
//!
//! A source that cannot be read is an error line on the tab, never an empty (green) section.

use serde::Serialize;

use crate::actions::{self, Action};
use crate::alertmanager::Firing;
use crate::fleet::runner::{self, Watch};
use crate::home::{Chip, Level};
use crate::infra::Infra;
use crate::layout::FOLD_ROWS;
use crate::reds::{self, Red, Reds};
use crate::table::{Row, Val};

/// History's window, the same as the fixes' (`reds::DAYS`).
pub const DAYS: i64 = reds::DAYS as i64;

/// The ledger actors whose pages are alerts. Sentinel's trips, recoveries and pages are; other
/// senders (the nightly report, Needs you) page about work, which Log's Actions keeps.
pub const ALERT_SENDERS: [&str; 1] = ["sentinel"];

/// The source name of a row from Alertmanager.
pub const ALERTMANAGER: &str = "alertmanager";

/// One thing firing now.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Alert {
    /// The watch's `severity:`; `high` for a `cc:red_now` or machinery row, which the red
    /// table holds only because it is red.
    pub sev: String,
    /// The watch's name, or the red item as Prometheus words it.
    pub what: String,
    /// The watch's `project:`, else the project of its fix item's queue item; empty for a
    /// fleet-wide watch or a red nothing files a fix for.
    pub project: String,
    /// `sentinel` (a watch's own state files), `red_now` (`cc:red_now`), `infra` (the
    /// machinery: down runners, stuck runs, the exporter or GitHub not answering) or
    /// `alertmanager` (a cluster rule firing).
    pub source: String,
    /// When it went red, epoch seconds; none for a Prometheus row, which has no start.
    pub since: Option<i64>,
    /// The fix item and its outcome (`ar-1601 fixing`), or `-`.
    pub owner: String,
    /// `fixing`, `queued`, `no owner`, `error` (the watch cannot check), `unknown` (the
    /// fixes could not be read) or `firing` (an Alertmanager rule, which no fix item is filed
    /// under).
    pub state: String,
    /// The fix item's slug, for a link to its queue record.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub slug: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    /// What a row opens to: the watch's `what:`, `where:`, `action:` and last probe output.
    pub about: String,
    pub place: String,
    pub action: String,
    pub evidence: String,
}

impl Alert {
    fn error(&self) -> bool {
        self.state == "error"
    }

    /// The hue this row gives the tab (rule 5). A watch that cannot check is amber and any other
    /// red row is red, but an Alertmanager rule says its own: critical is broken, a warning
    /// needs a look and info is neither.
    fn hue(&self) -> Level {
        if self.error() {
            return Level::Warn;
        }
        if self.source != ALERTMANAGER {
            return Level::Red;
        }
        match self.sev.as_str() {
            "urgent" | "high" => Level::Red,
            "normal" => Level::Warn,
            _ => Level::Ok,
        }
    }
}

impl Row for Alert {
    const COLUMNS: &'static [&'static str] = &[
        "sev", "what", "project", "source", "since", "owner", "state",
    ];
    const STATES: &'static [&'static str] = &["all", "trip", "error", "no owner", ALERTMANAGER];
    const FACETS: &'static [&'static str] = &["sev", "project", "source", "state"];
    const LEAD: &'static str = "what";
    const GLANCE: &'static [&'static str] = &["sev", "since", "state"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" | "-" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "sev" => text(&self.sev),
            "what" => text(&self.what),
            "project" => text(&self.project),
            "source" => text(&self.source),
            "since" => self.since.map_or(Val::None, |t| Val::Num(t as f64)),
            "owner" => text(&self.owner),
            "state" => text(&self.state),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        match state {
            "trip" => !self.error() && self.source != ALERTMANAGER,
            "error" => self.error(),
            "no owner" => self.state == "no owner",
            ALERTMANAGER => self.source == ALERTMANAGER,
            _ => true,
        }
    }

    /// The sort a severity header gives: high above normal above low.
    fn rank(&self, col: &str) -> Val {
        match col {
            "sev" => Val::Num(sev_rank(&self.sev) as f64),
            _ => self.val(col),
        }
    }

    fn text(&self) -> String {
        [
            &self.sev,
            &self.what,
            &self.project,
            &self.source,
            &self.owner,
            &self.state,
            &self.about,
            &self.place,
        ]
        .map(String::as_str)
        .join("\n")
        .to_lowercase()
    }
}

fn sev_rank(sev: &str) -> usize {
    match sev {
        "urgent" => 0,
        "high" => 1,
        "normal" => 2,
        "low" => 3,
        _ => 4,
    }
}

/// One `cc:component_status` series that is not green.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Component {
    pub domain: String,
    pub name: String,
    pub level: Level,
}

/// The components that are not green, in domain then name order.
pub fn components(infra: &Infra) -> Vec<Component> {
    let mut out: Vec<Component> = infra
        .get("cc")
        .iter()
        .filter(|s| s.label("__name__") == "cc:component_status")
        .filter(|s| s.value.is_some_and(|v| v > 0.0))
        .map(|s| Component {
            domain: s.label("domain").to_string(),
            name: s.label("component").to_string(),
            level: Level::of(s.value),
        })
        .collect();
    out.sort_by(|a, b| (&a.domain, &a.name).cmp(&(&b.domain, &b.name)));
    out
}

/// Every number the tab shows, each counted from the rows it heads.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Counts {
    pub firing: usize,
    pub tripped: usize,
    pub errors: usize,
    pub no_owner: usize,
    pub fixes_open: usize,
    pub fixes_settled: usize,
    pub history: usize,
    pub history_older: usize,
    pub watches: usize,
    pub watches_tripped: usize,
    pub watches_error: usize,
    pub watches_ok: usize,
    pub watches_new: usize,
    pub alertmanager: usize,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Alerts {
    /// When it was read, epoch seconds.
    pub at: i64,
    /// The tab's hue: red while anything trips (an Alertmanager row only at critical), amber
    /// when only errors or Alertmanager warnings fire, no data when nothing does but a firing
    /// source could not be read, else ok.
    pub level: Level,
    /// `cc:domain_status`, in Home's strip order.
    pub health: Vec<Chip>,
    /// The components (`cc:component_status`) that are not green: why a domain chip is.
    pub components: Vec<Component>,
    /// Tripped and error watches first, then `cc:red_now`, the machinery and Alertmanager;
    /// see `order`.
    pub firing: Vec<Alert>,
    /// The fix items of the last `DAYS`, open worst first and settled newest first.
    pub fixes: Reds,
    /// The alert senders' pages of the last `DAYS`, newest first, the first `FOLD_ROWS`.
    pub history: Vec<Action>,
    /// Every watch, tripped and errors first.
    pub watches: Vec<Watch>,
    /// No watch is tripped or failing: the section folds to its count line.
    pub watches_folded: bool,
    pub counts: Counts,
    /// One line per source that could not be read, `<source>: <why>`.
    pub errors: Vec<String>,
}

/// The machinery's reds, as Infra's RED NOW line had them: GitHub or the exporter not answering
/// first (the likeliest cause of the rest), then down CI runners and stuck runs.
pub fn machinery(infra: &Infra) -> Vec<String> {
    let mut items = vec![];
    for s in infra.runners_down() {
        items.push(format!(
            "ci runner {} {}",
            label(s.label("name")),
            s.label("state")
        ));
    }
    for s in infra.get("waiting") {
        if s.label("stuck") == "true" {
            items.push(format!(
                "stuck run: {} {}, {}, no jobs",
                label(s.label("repo")),
                label(s.label("branch")),
                s.value
                    .filter(|v| v.is_finite())
                    .map_or("-".into(), |v| crate::text::age(v as i64))
            ));
        }
    }
    // A missed scrape (every exporter series stale) is told apart from a spent rate limit and
    // from GitHub not answering the exporter's runner reads, the only API failure that can
    // cost runner rows.
    let is = |q: &str, v: f64| infra.get(q).first().and_then(|s| s.value) == Some(v);
    if !is("exporter_up", 1.0) {
        items.insert(
            0,
            "runner exporter missed its last scrape: runner rows may be missing".into(),
        );
    } else if is("rate_left", 0.0) {
        items.insert(
            0,
            "GitHub rate limit spent: runner jobs and history unread until it resets".into(),
        );
    } else if !is("api", 1.0) {
        items.insert(
            0,
            "GitHub not answering the exporter: runner rows may be missing".into(),
        );
    } else if infra.get("runners").is_empty() {
        items.push("no runner series from the exporter".into());
    }
    items
}

fn label(v: &str) -> &str {
    if v.is_empty() {
        "-"
    } else {
        v
    }
}

/// The `cc:red_now` items, sorted.
pub fn red_now(infra: &Infra) -> Vec<String> {
    let mut items: Vec<String> = infra
        .get("red")
        .iter()
        .map(|s| s.label("item").to_string())
        .filter(|i| !i.is_empty())
        .collect();
    items.sort();
    items
}

/// The `fleet-bench reds` key a red item's fix is filed under (its `red`, `<area> <name>`).
///
/// `cc:red_now` words a watch `watch <name>` and an agent runner `runner <name>` with `_` for
/// `-` (Prometheus labels); fleet-bench files them as `watch <name>` and `runner <name>`. Any
/// other item (`node n1 NotReady`, `agent feed frozen`) is triaged as `check(red): <item> is
/// red`, which fleet-bench parses to `red <first word>`: that names the item only while no
/// other red item shares the first word, so a shared one has no key and shows no owner rather
/// than another item's fix.
fn red_key(item: &str, items: &[String]) -> Option<String> {
    let (area, rest) = item.split_once(' ').unwrap_or((item, ""));
    match area {
        "watch" | "runner" if !rest.is_empty() => {
            Some(format!("{area} {}", rest.replace('_', "-")))
        }
        _ => {
            let shared = items
                .iter()
                .filter(|i| i.split(' ').next() == Some(area))
                .count();
            (shared == 1).then(|| format!("red {area}"))
        }
    }
}

/// The owner and state of a red from its fix: the first open row filed under `key` (open rows
/// are worst first), or none.
fn owner(a: &mut Alert, key: Option<&str>, fixes: Option<&[Red]>) {
    let Some(fixes) = fixes else {
        a.owner = "-".into();
        if !a.error() {
            a.state = "unknown".into();
        }
        return;
    };
    let fix = key.and_then(|k| fixes.iter().find(|r| r.red == k));
    a.owner = fix.map_or("-".into(), |r| format!("{} {}", r.slug, r.outcome));
    if let Some(r) = fix {
        if a.project.is_empty() {
            a.project = r.project.clone();
        }
        a.slug = r.slug.clone();
        a.pr_url = r.pr_url.clone();
    }
    if a.error() {
        return;
    }
    // A fix row whose fix did not hold (came back, still red, no fix) has an owner to ask, so
    // it is "unfixed"; "no owner" is only a red with no fix row at all.
    a.state = match fix.map(|r| r.outcome.as_str()) {
        Some("fixing" | "needs merge") => "fixing",
        Some("queued") => "queued",
        Some(_) => "unfixed",
        None => "no owner",
    }
    .into();
}

/// Firing's order: tripped watches, error watches, `cc:red_now`, the machinery, Alertmanager
/// (the cluster's own rules, which page through ntfy without the fleet); within each the worst
/// severity, then the longest red, then by name.
fn order(a: &Alert) -> (usize, usize, i64, String) {
    let kind = match (a.source.as_str(), a.error()) {
        ("sentinel", false) => 0,
        ("sentinel", true) => 1,
        ("red_now", _) => 2,
        (ALERTMANAGER, _) => 4,
        _ => 3,
    };
    (
        kind,
        sev_rank(&a.sev),
        a.since.unwrap_or(i64::MAX),
        a.what.clone(),
    )
}

/// An Alertmanager rule's `severity` in the watches' words: `critical` pages (ntfy-critical)
/// as a high watch does. Any other or no severity is a warning, so a rule nobody labelled still
/// raises the tab.
fn am_sev(sev: &str) -> &'static str {
    match sev {
        "critical" => "high",
        "info" => "low",
        _ => "normal",
    }
}

/// One Alertmanager alert as a firing row. Nothing files a fix for one by its name, so it is
/// `firing` and not `no owner`; what it checks, where and what to do come from its rule.
fn am_row(f: &Firing) -> Alert {
    let about = [f.name.as_str(), f.description.as_str()]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(": ");
    let place = f
        .labels
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut action: Vec<String> = Vec::new();
    if !f.runbook.is_empty() {
        action.push(format!("runbook {}", f.runbook));
    }
    if !f.receivers.is_empty() {
        action.push(format!("routed to {}", f.receivers.join(", ")));
    }
    action.push("silence it in Alertmanager once someone owns it".into());
    Alert {
        sev: am_sev(&f.severity).into(),
        what: if f.summary.is_empty() {
            f.name.clone()
        } else {
            f.summary.clone()
        },
        source: ALERTMANAGER.into(),
        since: f.since,
        about,
        place,
        action: action.join("; "),
        owner: "-".into(),
        state: "firing".into(),
        ..Default::default()
    }
}

/// The tab from what each source returned; `read` gathers them.
pub fn join(
    infra: &Infra,
    watches: Result<Vec<Watch>, String>,
    fixes: Result<Reds, String>,
    notify: Result<String, String>,
    now: i64,
) -> Alerts {
    let mut errors = vec![];
    let infra_ok = infra.ok;
    if !infra_ok {
        errors.push(format!(
            "prometheus: {}",
            infra.error.as_deref().unwrap_or("no answer")
        ));
    }
    let watches = watches
        .map_err(|e| errors.push(format!("watches: {e}")))
        .ok();
    let fixes = fixes
        .map_err(|e| errors.push(format!("fleet-bench reds: {e}")))
        .ok();
    let open = fixes.as_ref().map(|r| r.open.as_slice());

    let mut firing: Vec<Alert> = vec![];
    for w in watches.iter().flatten() {
        let error = match w.state.as_str() {
            "TRIP" => false,
            "ERROR" => true,
            _ => continue,
        };
        let mut a = Alert {
            sev: label(&w.severity).to_string(),
            what: w.name.clone(),
            project: w.project.clone(),
            source: "sentinel".into(),
            since: w.since,
            state: if error { "error".into() } else { String::new() },
            about: w.what.clone(),
            place: w.place.clone(),
            action: w.action.clone(),
            evidence: w.evidence.clone(),
            ..Default::default()
        };
        owner(
            &mut a,
            Some(&format!("watch {}", w.name.replace('_', "-"))),
            open,
        );
        firing.push(a);
    }
    if infra_ok {
        let items = red_now(infra);
        for item in &items {
            // A watch red in Prometheus is the same red as its own state file's row above.
            let watch = item
                .strip_prefix("watch ")
                .map(|n| n.replace('_', "-"))
                .filter(|n| {
                    firing
                        .iter()
                        .any(|a| a.source == "sentinel" && a.what.replace('_', "-") == *n)
                });
            if watch.is_some() {
                continue;
            }
            let mut a = Alert {
                sev: "high".into(),
                what: item.clone(),
                source: "red_now".into(),
                ..Default::default()
            };
            owner(&mut a, red_key(item, &items).as_deref(), open);
            firing.push(a);
        }
        for item in machinery(infra) {
            let mut a = Alert {
                sev: "high".into(),
                what: item,
                source: "infra".into(),
                ..Default::default()
            };
            // Nothing files a fix for the machinery's own reds.
            owner(&mut a, None, open);
            firing.push(a);
        }
    }
    match &infra.alertmanager {
        Some(Ok(list)) => firing.extend(list.iter().map(am_row)),
        Some(Err(e)) => errors.push(format!("alertmanager: {e}")),
        None => {}
    }
    firing.sort_by_cached_key(order);

    let mut history: Vec<Action> = match notify {
        Ok(text) => actions::parse_notify(&text)
            .0
            .into_iter()
            .filter(|a| ALERT_SENDERS.contains(&a.actor.as_str()) && a.at >= now - DAYS * 86400)
            .collect(),
        Err(e) => {
            errors.push(format!("agent-notify ledger: {e}"));
            vec![]
        }
    };
    history.sort_by_key(|a| std::cmp::Reverse(a.at));
    let history_older = history.len().saturating_sub(FOLD_ROWS);
    history.truncate(FOLD_ROWS);

    let watches = watches.unwrap_or_default();
    let n = |s: &str| watches.iter().filter(|w| w.state == s).count();
    let counts = Counts {
        firing: firing.len(),
        tripped: firing.iter().filter(|a| a.in_state("trip")).count(),
        errors: firing.iter().filter(|a| a.error()).count(),
        no_owner: firing.iter().filter(|a| a.in_state("no owner")).count(),
        fixes_open: fixes.as_ref().map_or(0, |r| r.open.len()),
        fixes_settled: fixes.as_ref().map_or(0, |r| r.settled.len()),
        history: history.len(),
        history_older,
        watches: watches.len(),
        watches_tripped: n("TRIP"),
        watches_error: n("ERROR"),
        watches_ok: n("OK"),
        watches_new: n("new"),
        alertmanager: firing.iter().filter(|a| a.in_state(ALERTMANAGER)).count(),
    };
    let hue = |l: Level| firing.iter().any(|a| a.hue() == l);
    let level = if hue(Level::Red) {
        Level::Red
    } else if hue(Level::Warn) {
        Level::Warn
    } else if !infra_ok
        || errors
            .iter()
            .any(|e| e.starts_with("watches:") || e.starts_with("alertmanager:"))
    {
        Level::Nodata
    } else {
        Level::Ok
    };
    Alerts {
        at: now,
        level,
        health: if infra_ok { infra.health() } else { vec![] },
        components: if infra_ok { components(infra) } else { vec![] },
        firing,
        fixes: fixes.unwrap_or_default(),
        history,
        watches_folded: counts.watches_tripped + counts.watches_error == 0,
        watches,
        counts,
        errors,
    }
}

/// The tab over the caller's `infra` and `fixes` (`reds::read`, about 2s: each surface keeps
/// both cached), with the watches and the agent-notify ledger read now, since a file read is
/// cheap and a trip must show on the push that announced it.
pub fn read(infra: &Infra, fixes: Result<Reds, String>, now: i64) -> Alerts {
    let (dir, state) = watch_dirs();
    let watches = runner::watches(&dir, &state);
    let notify = crate::jobs::read_or_empty(&actions::Paths::from_env().notify_log);
    join(infra, watches, fixes, notify, now)
}

/// A project card's count line over `watches`: how many carry `project:` and how many of them
/// are tripped or failing. None when no watch names the project, so a project nothing watches
/// shows no line rather than "0 watches".
pub fn project_badge(watches: &[Watch], project: &str) -> Option<crate::releases::Badge> {
    let mine: Vec<&Watch> = watches.iter().filter(|w| w.project == project).collect();
    let n = |s: &str| mine.iter().filter(|w| w.state == s).count();
    let (trip, error) = (n("TRIP"), n("ERROR"));
    (!mine.is_empty()).then(|| crate::releases::Badge {
        says: format!(
            "{} watch{}, {} firing",
            mine.len(),
            if mine.len() == 1 { "" } else { "es" },
            trip + error
        ),
        level: if trip > 0 {
            crate::releases::Level::Bad
        } else if error > 0 {
            crate::releases::Level::Warn
        } else {
            crate::releases::Level::Ok
        },
    })
}

/// `project_badge` over the watches this process's environment names; an unreadable watch
/// directory shows no line (the Alerts tab is the one that says why).
pub fn project_badge_here(project: &str) -> Option<crate::releases::Badge> {
    let (dir, state) = watch_dirs();
    project_badge(&runner::watches(&dir, &state).ok()?, project)
}

/// Sentinel's watch and state directories as this process's environment says.
pub fn watch_dirs() -> (std::path::PathBuf, std::path::PathBuf) {
    let home = std::env::var("HOME").unwrap_or_default();
    runner::watch_dirs(&home, |k| std::env::var(k).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prom::Series;

    const NOW: i64 = 1_762_200_000;

    fn series(labels: &[(&str, &str)], v: f64) -> Series {
        Series {
            labels: labels
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            value: Some(v),
            points: vec![],
        }
    }

    /// Prometheus answering, the exporter and GitHub fine, one runner up, `red` items red.
    fn infra(red: &[&str]) -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert("exporter_up", vec![series(&[], 1.0)]);
        i.instant.insert("api", vec![series(&[], 1.0)]);
        i.instant.insert("rate_left", vec![series(&[], 4000.0)]);
        i.instant.insert(
            "runners",
            vec![series(&[("name", "mini-1"), ("state", "online")], 1.0)],
        );
        i.instant.insert(
            "red",
            red.iter().map(|r| series(&[("item", r)], 1.0)).collect(),
        );
        i.instant.insert(
            "cc",
            vec![
                series(&[("__name__", "cc:domain_status"), ("domain", "ci")], 0.0),
                series(
                    &[
                        ("__name__", "cc:component_status"),
                        ("domain", "ci"),
                        ("component", "pool"),
                    ],
                    0.0,
                ),
            ],
        );
        i
    }

    fn watch(name: &str, state: &str, sev: &str, since: Option<i64>) -> Watch {
        Watch {
            name: name.into(),
            state: state.into(),
            severity: sev.into(),
            since,
            ..Default::default()
        }
    }

    fn red(slug: &str, key: &str, outcome: &str) -> Red {
        Red {
            slug: slug.into(),
            red: key.into(),
            outcome: outcome.into(),
            ..Default::default()
        }
    }

    fn ok_watches() -> Vec<Watch> {
        vec![
            watch("alpha", "OK", "normal", None),
            watch("bravo", "OK", "high", None),
            watch("charlie", "new", "low", None),
        ]
    }

    #[test]
    fn nothing_tripped_and_nothing_red_is_zero_firing_ok_and_the_watches_fold() {
        // The negative control: with every watch ok and cc:red_now empty, nothing fires and the
        // tab is ok, so a red one below is the join's doing and not the fixture's.
        let a = join(
            &infra(&[]),
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(a.counts.firing, 0, "{:?}", a.firing);
        assert!(a.firing.is_empty());
        assert_eq!(a.level, Level::Ok);
        assert!(a.watches_folded);
        assert_eq!(
            (a.counts.watches, a.counts.watches_ok, a.counts.watches_new),
            (3, 2, 1)
        );
        assert!(a.errors.is_empty(), "{:?}", a.errors);
        assert_eq!(a.health.len(), infra(&[]).health().len());
        assert!(a.components.is_empty(), "{:?}", a.components);
    }

    #[test]
    fn a_component_that_is_not_green_says_why_its_domain_chip_is() {
        let mut i = infra(&[]);
        i.instant.get_mut("cc").unwrap().push(series(
            &[
                ("__name__", "cc:component_status"),
                ("domain", "k3s"),
                ("component", "nodes"),
            ],
            2.0,
        ));
        let a = join(
            &i,
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(
            a.components,
            [Component {
                domain: "k3s".into(),
                name: "nodes".into(),
                level: Level::Red,
            }]
        );
    }

    #[test]
    fn one_trip_sorts_first_and_turns_the_tab_red() {
        let mut ws = ok_watches();
        ws.push(watch("delta", "TRIP", "low", Some(NOW - 600)));
        ws.push(watch("echo", "ERROR", "high", Some(NOW - 60)));
        let a = join(
            &infra(&["node n1 NotReady"]),
            Ok(ws),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        let got: Vec<(&str, &str, &str)> = a
            .firing
            .iter()
            .map(|r| (r.what.as_str(), r.source.as_str(), r.state.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("delta", "sentinel", "no owner"),
                ("echo", "sentinel", "error"),
                ("node n1 NotReady", "red_now", "no owner"),
            ]
        );
        assert_eq!(a.level, Level::Red);
        assert!(!a.watches_folded);
        assert_eq!(
            (a.counts.firing, a.counts.tripped, a.counts.errors),
            (3, 2, 1)
        );
    }

    #[test]
    fn an_error_alone_is_amber() {
        let mut ws = ok_watches();
        ws.push(watch("echo", "ERROR", "high", None));
        let a = join(
            &infra(&[]),
            Ok(ws),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!((a.counts.firing, a.level), (1, Level::Warn));
    }

    #[test]
    fn a_fix_that_did_not_hold_is_unfixed_and_an_underscore_watch_is_one_row() {
        let ws = vec![watch("dot_drift", "TRIP", "normal", Some(NOW - 60))];
        let fixes = reds::split(vec![red("ar-5", "watch dot-drift", "came back")]);
        let a = join(
            &infra(&["watch dot_drift"]),
            Ok(ws),
            Ok(fixes),
            Ok(String::new()),
            NOW,
        );
        let got: Vec<(&str, &str, &str)> = a
            .firing
            .iter()
            .map(|r| (r.what.as_str(), r.owner.as_str(), r.state.as_str()))
            .collect();
        assert_eq!(got, [("dot_drift", "ar-5 came back", "unfixed")]);
        assert_eq!(a.counts.no_owner, 0);
    }

    #[test]
    fn the_owner_is_the_open_fix_filed_under_the_red() {
        let ws = vec![
            watch("playground-nightly", "TRIP", "high", Some(NOW - 3600)),
            watch("queue-starved", "TRIP", "normal", Some(NOW - 60)),
        ];
        let fixes = reds::split(vec![
            red("ar-1", "watch playground-nightly", "fixing"),
            red("ar-2", "runner fleet-dispatch", "queued"),
            red("ar-3", "red agent", "needs merge"),
            red("ar-4", "watch queue-starved", "fixed"),
        ]);
        let a = join(
            // The tripped watch is in cc:red_now too: one row, the watch's.
            &infra(&[
                "watch playground_nightly",
                "runner fleet_dispatch",
                "agent feed frozen",
                "node n1 NotReady",
                "node n2 NotReady",
            ]),
            Ok(ws),
            Ok(fixes),
            Ok(String::new()),
            NOW,
        );
        let got: Vec<(&str, &str, &str)> = a
            .firing
            .iter()
            .map(|r| (r.what.as_str(), r.owner.as_str(), r.state.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("playground-nightly", "ar-1 fixing", "fixing"),
                // Its only fix settled: nobody holds it now.
                ("queue-starved", "-", "no owner"),
                ("agent feed frozen", "ar-3 needs merge", "fixing"),
                // Two items share `node`: `red node` names neither, so no owner is claimed.
                ("node n1 NotReady", "-", "no owner"),
                ("node n2 NotReady", "-", "no owner"),
                ("runner fleet_dispatch", "ar-2 queued", "queued"),
            ]
        );
        assert_eq!(a.firing[0].slug, "ar-1");
        assert_eq!((a.counts.fixes_open, a.counts.fixes_settled), (3, 1));
        assert_eq!(a.counts.no_owner, 3);
    }

    #[test]
    fn the_machinery_reds_fire_last_with_the_likeliest_cause_first() {
        let mut i = infra(&[]);
        i.instant.insert("api", vec![series(&[], 0.0)]);
        i.instant.insert(
            "waiting",
            vec![series(
                &[("repo", "app"), ("branch", "main"), ("stuck", "true")],
                7200.0,
            )],
        );
        let a = join(
            &i,
            Ok(vec![watch("delta", "TRIP", "low", None)]),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        let got: Vec<(&str, &str)> = a
            .firing
            .iter()
            .map(|r| (r.what.as_str(), r.source.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("delta", "sentinel"),
                (
                    "GitHub not answering the exporter: runner rows may be missing",
                    "infra"
                ),
                ("stuck run: app main, 2h, no jobs", "infra"),
            ]
        );
    }

    #[test]
    fn a_source_that_fails_is_an_error_line_never_an_empty_green() {
        let down = Infra {
            ok: false,
            error: Some("connection refused".into()),
            ..Default::default()
        };
        let a = join(
            &down,
            Err("no such dir".into()),
            Err("exit 1".into()),
            Err("permission denied".into()),
            NOW,
        );
        assert_eq!(
            a.errors,
            [
                "prometheus: connection refused",
                "watches: no such dir",
                "fleet-bench reds: exit 1",
                "agent-notify ledger: permission denied",
            ]
        );
        assert_eq!(
            a.level,
            Level::Nodata,
            "nothing firing that was read is not ok"
        );
        assert!(a.health.is_empty());
        // Unread fixes: a trip's owner is unknown, not "no owner".
        let a = join(
            &infra(&[]),
            Ok(vec![watch("delta", "TRIP", "low", None)]),
            Err("exit 1".into()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(a.firing[0].state, "unknown");
    }

    #[test]
    fn history_is_the_alert_senders_pages_of_the_window_newest_first_capped() {
        let stamp = |ago: i64| {
            chrono::DateTime::from_timestamp(NOW - ago, 0)
                .unwrap()
                .to_rfc3339()
        };
        let mut log = String::new();
        for i in 0..(FOLD_ROWS as i64 + 3) {
            log += &format!(
                "{}\tlow\tSentinel: w{i}\tw{i} back to normal after 4m.\n",
                stamp(60 + i)
            );
        }
        log += &format!("{}\thigh\tNeeds you\t1 new needs you\n", stamp(10));
        log += &format!(
            "{}\thigh\tSentinel: old\told TRIPPED\n",
            stamp(DAYS * 86400 + 60)
        );
        let a = join(
            &infra(&[]),
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(log),
            NOW,
        );
        assert_eq!(
            (a.history.len(), a.counts.history, a.counts.history_older),
            (FOLD_ROWS, FOLD_ROWS, 3)
        );
        assert!(a.history.iter().all(|h| h.actor == "sentinel"));
        assert_eq!(a.history[0].text, "w0 back to normal after 4m.");
        assert!(a.history.windows(2).all(|p| p[0].at >= p[1].at));
    }

    fn am(name: &str, sev: &str, summary: &str) -> Firing {
        Firing {
            name: name.into(),
            severity: sev.into(),
            since: Some(NOW - 120),
            summary: summary.into(),
            labels: [("namespace".to_string(), "freqtrade".to_string())].into(),
            receivers: vec!["ntfy".into()],
            ..Default::default()
        }
    }

    #[test]
    fn alertmanager_rows_fire_last_and_take_their_rules_hue() {
        // Info alone gives the tab no hue: the negative control for the two below.
        let mut i = infra(&[]);
        i.alertmanager = Some(Ok(vec![am("CPUThrottlingHigh", "info", "")]));
        let a = join(
            &i,
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(
            (a.counts.firing, a.counts.alertmanager, a.level),
            (1, 1, Level::Ok)
        );
        assert_eq!(
            (
                a.firing[0].what.as_str(),
                a.firing[0].sev.as_str(),
                a.firing[0].state.as_str()
            ),
            ("CPUThrottlingHigh", "low", "firing"),
            "no summary: the rule's name"
        );

        i.alertmanager = Some(Ok(vec![
            am("CPUThrottlingHigh", "info", ""),
            am("NodeOomKill", "warning", "n1 killed 2 processes"),
        ]));
        let a = join(
            &i,
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(a.level, Level::Warn, "a warning needs a look");

        i.alertmanager = Some(Ok(vec![
            am("NodeOomKill", "warning", "n1 killed 2 processes"),
            am(
                "HomelabBackupStale",
                "critical",
                "Backup stale: freqtrade/lab",
            ),
        ]));
        let mut ws = ok_watches();
        ws.push(watch("delta", "TRIP", "low", Some(NOW - 60)));
        let a = join(&i, Ok(ws), Ok(Reds::default()), Ok(String::new()), NOW);
        assert_eq!(a.level, Level::Red);
        let got: Vec<(&str, &str, &str)> = a
            .firing
            .iter()
            .map(|r| (r.what.as_str(), r.source.as_str(), r.sev.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("delta", "sentinel", "low"),
                ("Backup stale: freqtrade/lab", "alertmanager", "high"),
                ("n1 killed 2 processes", "alertmanager", "normal"),
            ]
        );
        let r = &a.firing[1];
        assert_eq!(r.about, "HomelabBackupStale");
        assert_eq!(r.place, "namespace=freqtrade");
        assert!(r.action.contains("routed to ntfy"), "{}", r.action);
        assert_eq!(
            (a.counts.tripped, a.counts.no_owner),
            (1, 1),
            "a rule is neither a tripped watch nor a red with no owner"
        );
    }

    #[test]
    fn alertmanager_unread_is_an_error_line_and_not_all_clear() {
        let mut i = infra(&[]);
        i.alertmanager = Some(Err("cannot read https://am".into()));
        let a = join(
            &i,
            Ok(ok_watches()),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        assert_eq!(a.errors, ["alertmanager: cannot read https://am"]);
        assert_eq!(a.level, Level::Nodata);
    }

    #[test]
    fn the_chips_filter_the_firing_rows() {
        let mut ws = ok_watches();
        ws.push(watch("delta", "TRIP", "low", None));
        ws.push(watch("echo", "ERROR", "high", None));
        let a = join(
            &infra(&[]),
            Ok(ws),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        let v = crate::table::View::new::<Alert>("", "error", "", "");
        let (rows, s) = v.summary(&a.firing);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].what, "echo");
        assert!(
            s.states.iter().any(|c| c.name == "trip" && c.n == 1),
            "{:?}",
            s.states
        );
    }

    #[test]
    fn a_firing_row_takes_its_watchs_project_else_its_fix_items_and_the_facet_filters_on_it() {
        let mut ws = ok_watches();
        let mut tagged = watch("ucp-nightly", "TRIP", "high", None);
        tagged.project = "unity-core-playground".into();
        ws.push(tagged);
        ws.push(watch("fleet-drain", "TRIP", "normal", None));
        ws.push(watch("untracked", "TRIP", "normal", None));
        let mut fix = red("ar-5", "watch fleet-drain", "fixing");
        fix.project = "agent-runtime".into();
        let mut other = red("ar-6", "watch ucp-nightly", "queued");
        other.project = "dotfiles".into();
        let fixes = Reds {
            open: vec![fix, other],
            ..Default::default()
        };
        let a = join(&infra(&[]), Ok(ws), Ok(fixes), Ok(String::new()), NOW);
        let project = |what: &str| {
            a.firing
                .iter()
                .find(|r| r.what == what)
                .map(|r| r.project.clone())
        };
        assert_eq!(
            project("ucp-nightly").as_deref(),
            Some("unity-core-playground")
        );
        assert_eq!(project("fleet-drain").as_deref(), Some("agent-runtime"));
        assert_eq!(project("untracked").as_deref(), Some(""));
        let v = crate::table::View::new::<Alert>("project:unity-core-playground", "", "", "");
        let (rows, s) = v.summary(&a.firing);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].what, "ucp-nightly");
        let facet = s
            .facets
            .iter()
            .find(|f| f.key == "project")
            .expect("a project facet");
        assert!(
            facet.values.iter().any(|x| x.value == "agent-runtime"),
            "{:?}",
            facet.values
        );
    }

    #[test]
    fn a_project_card_counts_its_watches_and_the_ones_firing_and_a_fleet_wide_watch_is_nobodys() {
        let mut ws = vec![
            watch("a", "OK", "high", None),
            watch("b", "TRIP", "high", None),
            watch("c", "ERROR", "high", None),
            watch("d", "OK", "high", None),
            watch("fleet", "TRIP", "high", None),
        ];
        for w in &mut ws[..3] {
            w.project = "dotfiles".into();
        }
        ws[3].project = "home-config".into();
        let b = project_badge(&ws, "dotfiles").expect("three watches name it");
        assert_eq!(b.says, "3 watches, 2 firing");
        assert_eq!(b.level, crate::releases::Level::Bad);
        let one = project_badge(&ws, "home-config").unwrap();
        assert_eq!(
            (one.says.as_str(), one.level),
            ("1 watch, 0 firing", crate::releases::Level::Ok)
        );
        assert!(project_badge(&ws, "trader").is_none(), "no watch, no line");
        ws[1].state = "OK".into();
        assert_eq!(
            project_badge(&ws, "dotfiles").unwrap().level,
            crate::releases::Level::Warn,
            "an error alone is amber"
        );
    }
}
