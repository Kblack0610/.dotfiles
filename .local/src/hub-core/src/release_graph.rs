//! The joins between the release stores, computed in this one place for both surfaces (and,
//! later, the validator): the collector writes raw facts only (`release-state refresh`'s
//! `releases` tag history, each channel's Deployments and pin), and a link between two of them
//! is never stored, so it cannot drift from the facts it joins. Today: release -> the channels
//! it reached. The relationship model: docs/operations/release-state.md, "Relationships".

use serde::{Deserialize, Serialize};

use crate::pipeline::stamp;
use crate::releases::Release;

/// One tag of a project's line as the collector read it from git.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Tag {
    pub tag: String,
    /// The bare version (`1.19.0`, `0.5.0-shapecity3`): the key a lab version and a store's
    /// version string join on.
    pub version: String,
    pub sha: Option<String>,
    /// git's creatordate: the tagger date, or a lightweight tag's commit date (a lower bound).
    pub at: Option<i64>,
    /// The release before it on its own history, the changelog's range start.
    pub prev: Option<String>,
}

/// A project's tag history: `release` is its own release family, `build` its per-build tags
/// (the registry's `buildTags`) while it has none, `none` neither.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Line {
    pub line: String,
    pub glob: Option<String>,
    pub error: Option<String>,
    pub tags: Vec<Tag>,
}

/// One channel a release reached: a successful Deployment of it, or the gitops pin that names it.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Reached {
    pub id: String,
    pub channel: String,
    /// When: the Deployment's time, or when the pin took the value (the gitops PR's merge).
    pub at: Option<i64>,
    /// `deploy` (a GitHub Deployment) or `pin` (the file a gitops target reads).
    pub how: String,
}

/// One release of an app with what it is joined to, newest first: the opened app's history.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Shipment {
    pub tag: String,
    pub version: String,
    pub sha: Option<String>,
    pub at: Option<i64>,
    pub prev: Option<String>,
    pub reached: Vec<Reached>,
    /// The RELEASED cell: `11-10 22:07`, `-` when git gave no date.
    pub at_text: String,
    /// The REACHED cell: `beta 11-10, testflight (pin)`, `not recorded` when no channel says so.
    pub reached_text: String,
}

/// Whether a channel's version string names this tag: the tag itself, or its version with or
/// without the `v` (a pin or a store says `v1.2.0` for `app-v1.2.0`).
fn names(value: &str, t: &Tag) -> bool {
    value == t.tag || (!t.version.is_empty() && value.trim_start_matches('v') == t.version)
}

/// release -> channels: each channel whose successful Deployment or current pin names the tag.
/// A channel counts once per release, at its earliest successful deploy of it.
pub fn reached(t: &Tag, channels: &[Release]) -> Vec<Reached> {
    let mut out: Vec<Reached> = vec![];
    for r in channels {
        let deployed = r
            .deploys
            .history
            .iter()
            .filter(|d| d.state == "ok" && names(&d.version, t))
            .map(|d| d.at)
            .min();
        let hit = match deployed {
            Some(at) => Some((Some(at), "deploy")),
            None if r.pinned.value.as_deref().is_some_and(|v| names(v, t))
                && r.pinned.at.is_some() =>
            {
                Some((r.pinned.at, "pin"))
            }
            None => None,
        };
        if let Some((at, how)) = hit {
            out.push(Reached {
                id: r.id.clone(),
                channel: r.channel.clone(),
                at,
                how: how.into(),
            });
        }
    }
    out.sort_by_key(|x| x.at.unwrap_or(i64::MAX));
    out
}

/// An app's history: every tag the collector kept, each joined to the channels it reached.
pub fn history(line: &Line, channels: &[Release], now: i64) -> Vec<Shipment> {
    line.tags
        .iter()
        .map(|t| {
            let reached = reached(t, channels);
            let reached_text = if reached.is_empty() {
                "not recorded".into()
            } else {
                reached
                    .iter()
                    .map(|x| {
                        let when =
                            x.at.map(|a| format!(" {}", stamp(a, now)))
                                .unwrap_or_default();
                        let pin = if x.how == "pin" { " (pin)" } else { "" };
                        format!("{}{when}{pin}", x.id)
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            Shipment {
                tag: t.tag.clone(),
                version: t.version.clone(),
                sha: t.sha.clone(),
                at: t.at,
                prev: t.prev.clone(),
                at_text: t.at.map_or("-".into(), |a| stamp(a, now)),
                reached,
                reached_text,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::releases::{Deploy, Deploys, Side};

    fn tag(t: &str, v: &str, at: i64) -> Tag {
        Tag {
            tag: t.into(),
            version: v.into(),
            at: Some(at),
            ..Default::default()
        }
    }

    fn channel(id: &str, history: Vec<(&str, &str, i64)>, pin: Option<(&str, i64)>) -> Release {
        Release {
            project: "app".into(),
            id: id.into(),
            channel: "prod".into(),
            deploys: Deploys {
                history: history
                    .into_iter()
                    .map(|(v, s, at)| Deploy {
                        version: v.into(),
                        state: s.into(),
                        at,
                        url: None,
                    })
                    .collect(),
                ..Default::default()
            },
            pinned: Side {
                value: pin.map(|p| p.0.into()),
                at: pin.map(|p| p.1),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    #[test]
    fn a_tag_reaches_the_channels_that_deployed_or_pin_it() {
        let t = tag("app-v1.2.0", "1.2.0", 100);
        let chans = vec![
            channel(
                "web",
                vec![("v1.2.0", "ok", 300), ("v1.2.0", "ok", 200)],
                None,
            ),
            channel("api", vec![("v1.2.0", "fail", 150)], None),
            channel("flux", vec![], Some(("v1.2.0", 250))),
            channel("old", vec![("v1.1.0", "ok", 90)], Some(("v1.1.0", 80))),
        ];
        let got = reached(&t, &chans);
        let ids: Vec<(&str, Option<i64>, &str)> = got
            .iter()
            .map(|x| (x.id.as_str(), x.at, x.how.as_str()))
            .collect();
        // The earliest ok deploy, a pin with its date; a failed deploy and another version never.
        assert_eq!(
            ids,
            vec![("web", Some(200), "deploy"), ("flux", Some(250), "pin")]
        );
    }

    #[test]
    fn a_tag_nothing_recorded_says_so() {
        let line = Line {
            line: "build".into(),
            tags: vec![tag("v0.5.0-game3", "0.5.0-game3", 100)],
            ..Default::default()
        };
        let h = history(
            &line,
            &[channel("steam", vec![("v0.5.0-game2", "ok", 50)], None)],
            1000,
        );
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].reached_text, "not recorded");
        // A store that records the build tag itself joins on the tag.
        let h = history(
            &line,
            &[channel("steam", vec![("v0.5.0-game3", "ok", 150)], None)],
            1000,
        );
        assert_eq!(h[0].reached[0].id, "steam");
    }
}
