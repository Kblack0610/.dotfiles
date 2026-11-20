//! Home's cards as a Tilecast widget document (the tilecast repo's `docs/format.md`, schema
//! `spec/widget-document.v0.schema.json`): what agent-web's `/widget.json` serves. A view of
//! `cards`, no reader of its own: each card is one section, in the order the widget asked for, so
//! the app drops the last ones first when it runs out of room.
//!
//! The mapping: `big` and `unit` are a `metric`, `bar` a `bar`, `parts` `pill`s, `first` `row`s
//! (a part or row with a link carries an `open` action to it), and a card whose reader failed a
//! `bad` section saying NO DATA with the reason, never green.
//! Every string is capped (`text::cap`) at the schema's limit, since a reader skips an item over it.

use chrono::{DateTime, SecondsFormat};
use serde::Serialize;

use crate::cards::Card;
use crate::home::Level as HubLevel;
use crate::links::Link;
use crate::reading::NO_DATA;
use crate::text::cap;

/// The format's major version this module writes.
pub const VERSION: u32 = 0;

/// How long a document counts as current: two of the app's 15 min backstop fetches, so one late
/// fetch does not grey a healthy widget, and a server that stopped answering shows stale within
/// the half hour.
pub const TTL_S: u32 = 1800;

/// The document's title, in the widget's header.
pub const TITLE: &str = "Fleet";

// The schema's caps (maxLength, in characters).
const TITLE_MAX: usize = 80;
const VALUE_MAX: usize = 16;
const UNIT_MAX: usize = 16;
const LABEL_MAX: usize = 40;
const ROW_MAX: usize = 200;
const TEXT_MAX: usize = 500;
const ID_MAX: usize = 64;
const URL_MAX: usize = 2048;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Neutral,
    Info,
    Ok,
    Warn,
    Bad,
}

impl From<HubLevel> for Level {
    fn from(l: HubLevel) -> Level {
        match l {
            HubLevel::Ok => Level::Ok,
            HubLevel::Warn => Level::Warn,
            HubLevel::Red => Level::Bad,
            HubLevel::Nodata => Level::Neutral,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Action {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub url: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Segment {
    pub level: Level,
    pub n: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Item {
    Metric {
        value: String,
        #[serde(skip_serializing_if = "String::is_empty")]
        unit: String,
        level: Level,
    },
    Bar {
        segments: Vec<Segment>,
    },
    Pill {
        label: String,
        value: String,
        level: Level,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        actions: Vec<Action>,
    },
    Row {
        text: String,
        #[serde(skip_serializing_if = "String::is_empty")]
        sub: String,
        level: Level,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        actions: Vec<Action>,
    },
    Text {
        text: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Section {
    pub id: String,
    pub title: String,
    pub level: Level,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Document {
    pub version: u32,
    pub title: &'static str,
    pub updated_at: String,
    pub state: Level,
    pub ttl_s: u32,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
    pub sections: Vec<Section>,
    /// Where the app registers for "fetch now" pushes. agent-web sets it, since the route is its own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub push: Option<Push>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Push {
    pub register: String,
}

impl Document {
    /// What the widget draws, without the read time: two reads that draw the same give the same
    /// key, so a push goes out only when it changes.
    pub fn content_key(&self) -> String {
        serde_json::to_string(&(&self.state, &self.sections)).unwrap_or_default()
    }
}

/// The document for `cards` (already picked and ordered), read at `now` (epoch seconds).
/// `missing` are the card ids asked for that no card has, said in a section of their own rather
/// than silently one fewer. `base` is the web's address (`AGENT_WEB_BASE_URL`): with it, a tap
/// opens the card's tab; without it the document has no actions.
pub fn document(cards: &[Card], missing: &[&str], now: i64, base: Option<&str>) -> Document {
    let mut sections: Vec<Section> = cards.iter().map(|c| section(c, base)).collect();
    if !missing.is_empty() {
        sections.push(Section {
            id: "missing".into(),
            title: "Unknown cards".into(),
            level: Level::Warn,
            actions: vec![],
            items: vec![Item::Text {
                text: cap(&format!("No card named {}", missing.join(", ")), TEXT_MAX),
            }],
        });
    }
    let state = sections
        .iter()
        .map(|s| s.level)
        .max()
        .unwrap_or(Level::Neutral);
    Document {
        version: VERSION,
        title: TITLE,
        updated_at: rfc3339(now),
        state,
        ttl_s: TTL_S,
        actions: open(&Link::tab("home"), base),
        sections,
        push: None,
    }
}

fn section(c: &Card, base: Option<&str>) -> Section {
    let actions = open(&c.link, base);
    let head = |level, items| Section {
        id: cap(c.tab, ID_MAX),
        title: cap(c.title, TITLE_MAX),
        level,
        actions: actions.clone(),
        items,
    };
    if let Some(why) = &c.error {
        let items = vec![
            Item::Metric {
                value: NO_DATA.to_uppercase(),
                unit: String::new(),
                level: Level::Bad,
            },
            Item::Text {
                text: cap(why, TEXT_MAX),
            },
        ];
        return head(Level::Bad, items);
    }
    let level = Level::from(c.level);
    let mut items = vec![];
    if !c.big.is_empty() {
        items.push(Item::Metric {
            value: cap(&c.big, VALUE_MAX),
            unit: cap(&c.unit, UNIT_MAX),
            level,
        });
    }
    if !c.bar.is_empty() {
        items.push(Item::Bar {
            segments: c
                .bar
                .iter()
                .map(|s| Segment {
                    level: s.level.into(),
                    n: s.n,
                })
                .collect(),
        });
    }
    items.extend(c.parts.iter().map(|p| Item::Pill {
        label: cap(&p.label, LABEL_MAX),
        value: cap(&p.value, VALUE_MAX),
        level: p.level.into(),
        actions: p.link.as_ref().map_or(vec![], |l| open(l, base)),
    }));
    items.extend(c.first.iter().map(|f| Item::Row {
        text: cap(&f.text, ROW_MAX),
        sub: cap(&f.sub, ROW_MAX),
        level: f.level.into(),
        actions: f.link.as_ref().map_or(vec![], |l| open(l, base)),
    }));
    head(level, items)
}

/// An `open` action for `link`, as an absolute URL: a hub hash under `base`, or a page outside
/// the hub as it is. None when there is no base for a hash, or the URL is not http(s), which the
/// format does not allow.
fn open(link: &Link, base: Option<&str>) -> Vec<Action> {
    let href = link.href();
    let url = match (href.strip_prefix('#'), base) {
        (Some(_), Some(b)) => format!("{}/{href}", b.trim_end_matches('/')),
        (Some(_), None) => return vec![],
        (None, _) => href,
    };
    let ok = (url.starts_with("https://") || url.starts_with("http://"))
        && url.chars().count() <= URL_MAX
        && !url.chars().any(char::is_whitespace);
    if !ok {
        return vec![];
    }
    vec![Action { kind: "open", url }]
}

fn rfc3339(t: i64) -> String {
    DateTime::from_timestamp(t, 0)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cards::{First, Part, Seg};
    use serde_json::json;

    fn card() -> Card {
        let mut c = Card::reading("alerts", "Alerts");
        c.big = "3".into();
        c.unit = "firing".into();
        c.level = HubLevel::Red;
        c.bar = vec![
            Seg {
                level: HubLevel::Ok,
                n: 41,
            },
            Seg {
                level: HubLevel::Red,
                n: 3,
            },
        ];
        c.parts = vec![
            Part {
                label: "Offline".into(),
                value: "2".into(),
                level: HubLevel::Warn,
                link: None,
            },
            Part {
                label: "Question".into(),
                value: "1".into(),
                level: HubLevel::Warn,
                link: Some(Link::to(crate::links::Kind::Needs, "Question")),
            },
        ];
        c.first = vec![First {
            text: "dotfiles: unit tests".into(),
            sub: String::new(),
            level: HubLevel::Red,
            link: Some(Link::to(crate::links::Kind::Alert, "ci-red")),
        }];
        c
    }

    #[test]
    fn a_card_is_a_section_of_metric_bar_pills_and_rows() {
        let d = document(&[card()], &[], 0, Some("https://agents.example.com/"));
        let v = serde_json::to_value(&d).unwrap();
        assert_eq!(v["version"], 0);
        assert_eq!(v["updated_at"], "1970-01-01T00:00:00Z");
        assert_eq!(v["state"], "bad");
        assert_eq!(v["actions"][0]["url"], "https://agents.example.com/#home");
        let s = &v["sections"][0];
        assert_eq!(s["id"], "alerts");
        assert_eq!(s["level"], "bad");
        assert_eq!(s["actions"][0]["url"], "https://agents.example.com/#alerts");
        assert_eq!(
            s["items"],
            json!([
                { "kind": "metric", "value": "3", "unit": "firing", "level": "bad" },
                { "kind": "bar", "segments": [{ "level": "ok", "n": 41 }, { "level": "bad", "n": 3 }] },
                // A part with no view of its own has no action; one that counts rows opens them.
                { "kind": "pill", "label": "Offline", "value": "2", "level": "warn" },
                { "kind": "pill", "label": "Question", "value": "1", "level": "warn",
                  "actions": [{ "type": "open", "url": "https://agents.example.com/#home?ns=Question" }] },
                { "kind": "row", "text": "dotfiles: unit tests", "level": "bad",
                  "actions": [{ "type": "open", "url": "https://agents.example.com/#alerts/ci-red" }] },
            ])
        );
    }

    #[test]
    fn a_failed_card_is_a_bad_section_saying_no_data_never_green() {
        let c = Card::failed("costs", "Costs", "", "ccusage: timed out");
        let d = document(&[c], &[], 0, None);
        let s = &d.sections[0];
        assert_eq!(s.level, Level::Bad);
        assert_eq!(d.state, Level::Bad);
        assert!(
            matches!(&s.items[0], Item::Metric { value, level: Level::Bad, .. } if value == "NO DATA")
        );
        assert!(matches!(&s.items[1], Item::Text { text } if text == "ccusage: timed out"));
    }

    #[test]
    fn a_card_still_reading_is_neutral_and_a_missing_name_is_said() {
        let d = document(&[Card::reading("infra", "Infra")], &["nope"], 0, None);
        assert_eq!(d.sections[0].level, Level::Neutral);
        assert_eq!(d.sections[1].id, "missing");
        assert!(matches!(&d.sections[1].items[0], Item::Text { text } if text.contains("nope")));
        // No base: no hash can be made absolute, so no actions at all.
        assert!(d.actions.is_empty() && d.sections[0].actions.is_empty());
    }

    #[test]
    fn strings_are_clipped_to_the_schema_caps() {
        let mut c = card();
        c.big = "1234567890123456789".into();
        c.first[0].text = "x".repeat(300);
        let d = document(&[c], &[], 0, None);
        let Item::Metric { value, .. } = &d.sections[0].items[0] else {
            panic!()
        };
        assert_eq!(value, "1234567890123...");
        let Some(Item::Row { text, .. }) = d.sections[0]
            .items
            .iter()
            .find(|i| matches!(i, Item::Row { .. }))
        else {
            panic!()
        };
        assert_eq!(text.chars().count(), ROW_MAX);
    }

    #[test]
    fn the_content_key_ignores_the_read_time_and_moves_with_what_is_drawn() {
        let a = document(&[card()], &[], 0, None);
        assert_eq!(
            a.content_key(),
            document(&[card()], &[], 99, None).content_key()
        );
        let mut c = card();
        c.big = "4".into();
        assert_ne!(a.content_key(), document(&[c], &[], 0, None).content_key());
    }

    #[test]
    fn only_http_urls_become_actions() {
        assert!(open(&Link::Url("javascript:alert(1)".into()), None).is_empty());
        assert!(open(&Link::Url("intent://x".into()), None).is_empty());
        assert_eq!(
            open(&Link::Url("https://github.com/x".into()), None)[0].url,
            "https://github.com/x"
        );
    }

    /// Writes a document of every item kind to `$TILECAST_DOC_OUT`, for `tests/tilecast-schema.sh`
    /// to check against the format's schema.
    #[test]
    #[ignore]
    fn dump_for_schema_check() {
        let out = std::env::var("TILECAST_DOC_OUT").expect("TILECAST_DOC_OUT");
        let mut long = card();
        long.big = "9".repeat(40);
        long.first[0].text = "y".repeat(400);
        let cards = [
            card(),
            long,
            Card::failed("costs", "Costs", "", "ccusage: timed out"),
            Card::reading("infra", "Infra"),
        ];
        let mut d = document(
            &cards,
            &["nope"],
            1_763_400_000,
            Some("https://agents.example.com"),
        );
        d.push = Some(Push {
            register: "https://agents.example.com/widget/push-register".into(),
        });
        std::fs::write(out, serde_json::to_string_pretty(&d).unwrap()).unwrap();
    }
}
