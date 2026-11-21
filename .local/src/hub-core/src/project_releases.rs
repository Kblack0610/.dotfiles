//! An opened project's Releases inner tab (docs/dashboards.md row 6), both surfaces: the project's
//! versions newest first, each with its status (the version page's rule, `version_page::status`),
//! its place on the release line, its rows done and its newest cut, linked to its version page;
//! then the apps whose cuts are the project's (`version_page::owned`) with the words Releases >
//! Apps gives them; then one shut Legacy fold holding every version from before the line starts
//! and every app with no line (the registry's `releaseFrom`). Nothing legacy is dropped.
//!
//! The marks are release-state's (docs/operations/release-state.md, Provenance): a lab version's
//! own mark, else its cuts'. The open version has no lab note yet, so with no cut of it it is
//! legacy only when no app of the project has a line. Rows done are `notes projects --roadmap`'s
//! count of the project's own rows aimed at the version. Built by [`build`] from the project
//! page's reads (`page::read`), so both surfaces draw the same words.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::links::{Kind, Link};
use crate::release_graph::{legacy, Shipment};
use crate::release_page::{core, cut_of};
use crate::releases::{App, Level, Releases};
use crate::version_page;

/// One version of the project.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Version {
    /// `v0.5.3`.
    pub version: String,
    /// `released`, `cut`, `unreleased` or `legacy` (`version_page::status`).
    pub status: String,
    pub level: Level,
    /// `flow`, `outside` (cut outside the release flow: amber) or `legacy`.
    pub provenance: String,
    pub done: u64,
    pub total: u64,
    /// `26 of 26 rows done`, or `no rows` when none is aimed at it.
    pub progress_text: String,
    /// The newest cut and its day, `v0.5.3-dodginballs5 11-19 14:02`, or `no cut`.
    pub cut_text: String,
    /// Its version page.
    pub href: String,
}

/// One app whose cuts are the project's.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct AppLine {
    pub app: String,
    /// Its word on Releases > Apps; `legacy` for an app with no line.
    pub status_text: String,
    pub level: Level,
    pub live_text: String,
    pub released_text: String,
    /// `line from v0.5.3`, or `no line (no releaseFrom)`.
    pub line_text: String,
    /// Its app page.
    pub href: String,
}

/// An app named like the project whose cuts are another project's (`dodginballs` under
/// `unity-core-playground`): its versions are listed on that project's tab.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Elsewhere {
    pub app: String,
    pub owner: String,
    /// The owner's Releases tab.
    pub href: String,
}

#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Tab {
    /// The versions on the line, newest first.
    pub versions: Vec<Version>,
    /// The apps with a line.
    pub apps: Vec<AppLine>,
    /// The Legacy fold: versions from before the line, newest first, and apps with no line.
    pub legacy_versions: Vec<Version>,
    pub legacy_apps: Vec<AppLine>,
    /// `line from v0.5.3`, or why every version is legacy.
    pub line_text: String,
    /// The Legacy fold's head: `8 versions, 2 apps`.
    pub legacy_says: String,
    pub elsewhere: Vec<Elsewhere>,
    pub errors: Vec<String>,
}

/// Everything known of one version before it is said.
#[derive(Default)]
struct Facts<'a> {
    /// The lab version note's mark.
    mark: Option<String>,
    progress: Option<(u64, u64)>,
    cuts: Vec<&'a Shipment>,
}

/// A version's numbers for the newest-first order; a version that is not `x.y.z` sorts last.
fn key(v: &str) -> (bool, Vec<u64>, String) {
    let nums: Option<Vec<u64>> = v.split('.').map(|p| p.parse().ok()).collect();
    (nums.is_some(), nums.unwrap_or_default(), v.to_string())
}

fn plural(n: usize, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

fn app_line(a: &App) -> AppLine {
    let lined = !a.release_from.is_empty();
    AppLine {
        app: a.project.clone(),
        status_text: if lined {
            a.status_text.clone()
        } else {
            "legacy".into()
        },
        level: if lined { a.level } else { Level::Neutral },
        live_text: a.live_text.clone(),
        released_text: a.released_text.clone(),
        line_text: if lined {
            format!("line from {}", a.release_from)
        } else {
            "no line (no releaseFrom)".into()
        },
        href: Link::to(Kind::App, a.project.clone()).href(),
    }
}

/// The tab for `project` from the Releases read, the project's own lab names (`version_page::labs`
/// with no apps) and its `notes projects --roadmap --json`, None when that did not read.
pub fn build(project: &str, rel: &Releases, labs: &[String], roadmap: Option<&Value>) -> Tab {
    let apps = version_page::owned(rel, project);
    let from = apps
        .iter()
        .map(|a| a.release_from.as_str())
        .find(|f| !f.is_empty());
    let mut facts: BTreeMap<String, Facts> = BTreeMap::new();
    for l in labs {
        for v in rel.versions.get(l).map_or(&[][..], |v| &v.list[..]) {
            facts.entry(core(&v.version).to_string()).or_default().mark =
                Some(v.provenance.clone()).filter(|m| !m.is_empty());
        }
    }
    for r in roadmap.and_then(Value::as_array).into_iter().flatten() {
        let Some(v) = r.get("version").and_then(Value::as_str) else {
            continue;
        };
        let n = |k: &str| r["progress"][k].as_u64().unwrap_or(0);
        facts.entry(core(v).to_string()).or_default().progress = Some((n("done"), n("open")));
    }
    for a in &apps {
        for s in &a.history {
            facts.entry(cut_of(s).to_string()).or_default().cuts.push(s);
        }
    }
    let mut versions = vec![];
    let mut legacy_versions = vec![];
    for (v, f) in facts {
        let is_legacy = match (&f.mark, f.cuts.is_empty()) {
            (Some(m), _) => legacy(m),
            (None, false) => f.cuts.iter().all(|s| legacy(&s.provenance)),
            (None, true) => from.is_none(),
        };
        let outside = !is_legacy
            && (f.mark.as_deref() == Some("outside")
                || f.cuts.iter().any(|s| s.provenance == "outside"));
        let released = f.cuts.iter().any(|s| !s.reached.is_empty());
        let (status, mut level) =
            version_page::status(is_legacy, released, !f.cuts.is_empty(), false);
        if outside {
            level = level.min(Level::Warn);
        }
        let (done, open) = f.progress.unwrap_or((0, 0));
        let newest = f.cuts.iter().max_by_key(|s| s.at);
        let row = Version {
            version: if key(&v).0 {
                format!("v{v}")
            } else {
                v.clone()
            },
            status: status.into(),
            level,
            provenance: if is_legacy {
                "legacy"
            } else if outside {
                "outside"
            } else {
                "flow"
            }
            .into(),
            done,
            total: done + open,
            progress_text: if done + open == 0 {
                "no rows".into()
            } else {
                format!("{done} of {} rows done", done + open)
            },
            cut_text: newest.map_or_else(
                || "no cut".into(),
                |s| format!("{} {}", s.tag, s.at_text).trim().to_string(),
            ),
            href: version_page::link(project, &v).href(),
        };
        if is_legacy {
            legacy_versions.push(row);
        } else {
            versions.push(row);
        }
    }
    let newest_first = |a: &Version, b: &Version| key(core(&b.version)).cmp(&key(core(&a.version)));
    versions.sort_by(newest_first);
    legacy_versions.sort_by(newest_first);
    let (lined, unlined): (Vec<&App>, Vec<&App>) =
        apps.iter().partition(|a| !a.release_from.is_empty());
    let elsewhere = rel
        .apps
        .iter()
        .filter(|a| a.project == project && a.owner() != project)
        .map(|a| Elsewhere {
            app: a.project.clone(),
            owner: a.owner(),
            href: format!("{}/releases", Link::to(Kind::Project, a.owner()).href()),
        })
        .collect();
    let legacy_apps: Vec<AppLine> = unlined.into_iter().map(app_line).collect();
    Tab {
        line_text: match from {
            Some(f) => format!("line from {f}"),
            None if apps.is_empty() => "no app releases under this project, so no line".into(),
            None => "no app declares releaseFrom, so every version is legacy".into(),
        },
        legacy_says: format!(
            "{}, {}",
            plural(legacy_versions.len(), "version"),
            plural(legacy_apps.len(), "app")
        ),
        versions,
        apps: lined.into_iter().map(app_line).collect(),
        legacy_versions,
        legacy_apps,
        elsewhere,
        errors: rel.errors.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::release_graph::{LabVersion, Reached, Versions};
    use std::collections::HashMap;

    fn ship(tag: &str, prov: &str, at: i64, reached: bool) -> Shipment {
        Shipment {
            tag: tag.into(),
            at: Some(at),
            at_text: format!("11-{at:02}"),
            provenance: prov.into(),
            reached: if reached {
                vec![Reached {
                    channel: "steam-beta".into(),
                    ..Default::default()
                }]
            } else {
                vec![]
            },
            ..Default::default()
        }
    }

    fn app(name: &str, from: &str, history: Vec<Shipment>) -> App {
        App {
            project: name.into(),
            repo: "Org/game".into(),
            release_from: from.into(),
            status_text: "ok".into(),
            live_text: "v0.5.0-x3 prod".into(),
            history,
            ..Default::default()
        }
    }

    fn lab(list: &[(&str, &str)]) -> HashMap<String, Versions> {
        let list = list
            .iter()
            .map(|(v, p)| LabVersion {
                version: v.to_string(),
                provenance: p.to_string(),
                ..Default::default()
            })
            .collect();
        HashMap::from([("game".to_string(), Versions { list, error: None })])
    }

    fn rel(apps: Vec<App>, versions: HashMap<String, Versions>) -> Releases {
        Releases {
            apps,
            versions,
            ..Default::default()
        }
    }

    fn roadmap() -> Value {
        serde_json::json!([
            {"version": "v0.5.5", "state": "current", "progress": {"done": 2, "open": 8}},
            {"version": "v0.5.4", "state": "shipped", "progress": {"done": 39, "open": 0}},
            {"version": "v0.5.3", "state": "shipped", "progress": {"done": 26, "open": 0}},
            {"version": "v0.0.1", "state": "shipped", "progress": {"done": 9, "open": 0}},
        ])
    }

    // project_map::canonical keys a repo it does not know by its name: the owner of Org/game.
    fn owner() -> String {
        app("x", "", vec![]).owner()
    }

    #[test]
    fn versions_on_the_line_lead_newest_first_and_legacy_folds_with_apps_lacking_a_line() {
        let p = owner();
        let game = app(
            &p,
            "v0.5.3",
            vec![
                ship("v0.5.4", "outside", 20, false),
                ship("v0.5.3", "flow", 18, false),
                ship("v0.5.0", "legacy", 1, true),
            ],
        );
        let build_app = app(
            "game-dodge",
            "v0.5.3",
            vec![ship("v0.5.3-dodge5", "flow", 19, true)],
        );
        let other = app(
            "game-city",
            "",
            vec![ship("v0.5.3-city1", "legacy", 18, false)],
        );
        let r = rel(
            vec![game, build_app, other],
            lab(&[
                ("v0.5.4", "outside"),
                ("v0.5.3", "flow"),
                ("v0.0.1", "legacy"),
            ]),
        );
        let t = build(&p, &r, &["game".into()], Some(&roadmap()));
        let vs: Vec<(&str, &str, &str)> = t
            .versions
            .iter()
            .map(|v| (v.version.as_str(), v.status.as_str(), v.provenance.as_str()))
            .collect();
        assert_eq!(
            vs,
            [
                ("v0.5.5", "unreleased", "flow"),
                ("v0.5.4", "cut", "outside"),
                ("v0.5.3", "released", "flow"),
            ]
        );
        // A cut outside the flow is amber, never green.
        assert_eq!(t.versions[1].level, Level::Warn);
        assert_eq!(t.versions[0].progress_text, "2 of 10 rows done");
        assert_eq!(t.versions[2].cut_text, "v0.5.3-dodge5 11-19");
        assert_eq!(
            t.versions[2].href,
            format!("#releases/versions/{p}%2F0.5.3")
        );
        let legacy: Vec<&str> = t
            .legacy_versions
            .iter()
            .map(|v| v.version.as_str())
            .collect();
        assert_eq!(legacy, ["v0.5.0", "v0.0.1"]);
        assert!(t.legacy_versions.iter().all(|v| v.level == Level::Neutral));
        // A legacy release that reached a channel is still legacy, not released.
        assert_eq!(t.legacy_versions[0].status, "legacy");
        let apps: Vec<&str> = t.apps.iter().map(|a| a.app.as_str()).collect();
        assert_eq!(apps, [p.as_str(), "game-dodge"]);
        assert_eq!(t.legacy_apps.len(), 1);
        assert_eq!(t.legacy_apps[0].status_text, "legacy");
        assert_eq!(t.legacy_apps[0].line_text, "no line (no releaseFrom)");
        assert_eq!(t.legacy_says, "2 versions, 1 app");
        assert_eq!(t.line_text, "line from v0.5.3");
    }

    #[test]
    fn with_no_line_every_version_is_legacy_and_none_is_lost() {
        let p = owner();
        let r = rel(
            vec![app(&p, "", vec![ship("v1.2.0", "legacy", 5, true)])],
            lab(&[("v1.1.0", "legacy")]),
        );
        let t = build(&p, &r, &["game".into()], Some(&roadmap()));
        // NEGATIVE CONTROL: the open version, with no lab mark and no cut, is legacy too.
        assert!(t.versions.is_empty());
        // Every version any source names lands in the fold: 4 roadmap, 1 lab, 1 cut, 0 shared.
        assert_eq!(t.legacy_versions.len(), 6);
        assert_eq!(
            t.line_text,
            "no app declares releaseFrom, so every version is legacy"
        );
    }

    #[test]
    fn an_app_named_like_the_project_but_owned_elsewhere_points_there() {
        let dodge = app("game-dodge", "v0.5.3", vec![]);
        let t = build("game-dodge", &rel(vec![dodge], HashMap::new()), &[], None);
        assert!(t.apps.is_empty() && t.versions.is_empty());
        assert_eq!(t.elsewhere.len(), 1);
        assert_eq!(t.elsewhere[0].owner, owner());
        assert_eq!(
            t.elsewhere[0].href,
            format!("#projects/{}/releases", owner())
        );
        assert_eq!(
            t.line_text,
            "no app releases under this project, so no line"
        );
    }
}
