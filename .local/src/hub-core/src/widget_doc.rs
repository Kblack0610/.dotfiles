//! Home's cards as a Tilecast widget document (the tilecast repo's `docs/format.md`, schema
//! `spec/widget-document.v0.schema.json`): what agent-web's `/widget.json` serves. A view of
//! `cards`, no reader of its own: each card is one section, in the order the widget asked for, so
//! the app drops the last ones first when it runs out of room.
//!
//! The mapping: `big` and `unit` are a `metric`, `bar` a `bar`, `parts` `pill`s, each list's `row`s
//! (a part or row with a link carries an `open` action to it), the list's head a `text` over them
//! and `counted` a `text` last, the card's (i) (dashboards.md rule 6). A card whose reader answered
//! nothing is a `bad` section saying NO DATA with the reason, never green; one that answered in part
//! keeps what it read, at warn or worse, with the reason as a `warn` row (as the web's card does).
//! Every string is capped (`text::cap`) at the schema's limit, since a reader skips an item over it.

use std::collections::BTreeMap;

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
pub(crate) const UNIT_MAX: usize = 16;
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

/// The cards' whole numbers by name, for a reader that keeps numbers and drops text (mqtt2prom,
/// so Prometheus and the waybar chips): a card's `big` is `<tab>_headline` and each part is
/// `<tab>_<label>` (lowercase, other characters `_`). A figure that is not a number
/// (`figure_value`), or belongs to a card whose reader failed, is absent: no figure is better than
/// a made-up zero.
pub fn figures(cards: &[Card]) -> BTreeMap<String, i64> {
    let mut m = BTreeMap::new();
    for c in cards.iter().filter(|c| c.error.is_none()) {
        if let Some(n) = figure_value(&c.big) {
            m.insert(format!("{}_headline", c.tab), n);
        }
        for p in &c.parts {
            if let Some(n) = figure_value(&p.value) {
                m.insert(figure_name(c.tab, &p.label), n);
            }
        }
    }
    m
}

/// The whole number a card shows: a count (`12`), or dollars as the Costs card writes them
/// (`usd_est`: `$573`, `$1,303`, `$5.23`; `about $573` for an estimate, `~$1,303` for a
/// projection), rounded to whole dollars. Anything else (`3/5`, `-`, a word) is no figure.
pub fn figure_value(v: &str) -> Option<i64> {
    if let Ok(n) = v.parse::<i64>() {
        return Some(n);
    }
    let usd = v
        .strip_prefix("about ")
        .or_else(|| v.strip_prefix('~'))
        .unwrap_or(v)
        .strip_prefix('$')?
        .replace(',', "");
    if usd.is_empty() || !usd.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    usd.parse::<f64>().ok().map(|d| d.round() as i64)
}

/// A part's figure name: `<tab>_<label>`, the label lowercase with every other character `_`.
pub fn figure_name(tab: &str, label: &str) -> String {
    let slug: String = label
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    format!("{tab}_{slug}")
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
    let counted = (!c.counted.is_empty()).then(|| Item::Text {
        text: cap(&c.counted, TEXT_MAX),
    });
    // `Card::failed`'s big word: the reader answered nothing at all.
    let no_data = NO_DATA.to_uppercase();
    if let Some(why) = c.error.as_ref().filter(|_| c.big == no_data) {
        let mut items = vec![
            Item::Metric {
                value: no_data,
                unit: String::new(),
                level: Level::Bad,
            },
            Item::Text {
                text: cap(why, TEXT_MAX),
            },
        ];
        items.extend(counted);
        return head(Level::Bad, items);
    }
    // A partial read is never green, and one whose big number could not be read (Costs' "-") is
    // as bad as no read at all, though the parts it did read stay.
    let level = match (&c.error, c.level) {
        (Some(_), HubLevel::Nodata) => Level::Bad,
        (Some(_), l) => Level::from(l).max(Level::Warn),
        (None, l) => Level::from(l),
    };
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
    if let Some(why) = &c.error {
        items.push(Item::Row {
            text: cap(why, ROW_MAX),
            sub: String::new(),
            level: Level::Warn,
            actions: vec![],
        });
    }
    for list in c.lists.iter().filter(|l| !l.rows.is_empty()) {
        if !list.head.is_empty() {
            items.push(Item::Text {
                text: cap(&list.head, TEXT_MAX),
            });
        }
        items.extend(list.rows.iter().map(|f| Item::Row {
            text: cap(&f.text, ROW_MAX),
            sub: cap(&f.sub, ROW_MAX),
            level: f.level.into(),
            actions: f.link.as_ref().map_or(vec![], |l| open(l, base)),
        }));
    }
    items.extend(counted);
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
    use crate::cards::{First, Part, Rows, Seg};
    use serde_json::json;

    fn card() -> Card {
        let mut c = Card::reading("alerts", "Alerts");
        c.big = "3".into();
        c.unit = "firing".into();
        c.level = HubLevel::Red;
        c.counted = "tripped watches".into();
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
        c.lists = vec![Rows {
            head: "Where to look first".into(),
            rows: vec![First {
                text: "dotfiles: unit tests".into(),
                sub: String::new(),
                level: HubLevel::Red,
                link: Some(Link::to(crate::links::Kind::Alert, "ci-red")),
            }],
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
                // The rows go under the card's heading, and what it counted closes the section.
                { "kind": "text", "text": "Where to look first" },
                { "kind": "row", "text": "dotfiles: unit tests", "level": "bad",
                  "actions": [{ "type": "open", "url": "https://agents.example.com/#alerts/ci-red" }] },
                { "kind": "text", "text": "tripped watches" },
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
    fn figures_are_the_whole_numbers_by_card_and_label_and_never_a_failed_cards() {
        let mut c = card();
        c.big = "7".into();
        c.parts.truncate(1);
        c.parts[0].label = "Shipped today".into();
        c.parts[0].value = "12".into();
        c.parts.push(Part {
            label: "Pass".into(),
            value: "3/5".into(),
            level: HubLevel::Ok,
            link: None,
        });
        let f = figures(&[
            c,
            Card::failed("costs", "Costs", "", "timed out"),
            Card::reading("infra", "Infra"),
        ]);
        assert_eq!(
            f.into_iter().collect::<Vec<_>>(),
            vec![
                ("alerts_headline".to_string(), 7),
                ("alerts_shipped_today".to_string(), 12)
            ]
        );
    }

    #[test]
    fn a_dollar_figure_is_whole_dollars_and_anything_else_is_no_figure() {
        for (v, want) in [
            ("12", Some(12)),
            ("$573", Some(573)),
            ("about $1,303", Some(1303)),
            ("~$1,303", Some(1303)),
            ("$5.49", Some(5)),
            ("$0.50", Some(1)),
            // Negative controls: a ratio, an unread value, a word and a bare sign are not numbers.
            ("3/5", None),
            ("-", None),
            ("about", None),
            ("$", None),
            ("$1.2k", None),
            ("about 5", None),
        ] {
            assert_eq!(figure_value(v), want, "{v}");
        }
    }

    #[test]
    fn the_costs_card_publishes_the_fleet_cost_and_its_named_parts_in_whole_dollars() {
        let mut k = crate::costs::Costs::default();
        k.fleet_cost.usd = "$1,203".into();
        k.fleet_cost.cash = "$403".into();
        k.fleet_cost.burn = "$800".into();
        let figs = figures(&[crate::cards::costs(&k)]);
        let got =
            ["costs_headline", "costs_api_cash", "costs_sub_burn"].map(|n| figs.get(n).copied());
        assert_eq!(got, [Some(1203), Some(403), Some(800)]);
        // Negative control: an unread fleet cost publishes no dollars, never a $0.
        let figs = figures(&[crate::cards::costs(&crate::costs::Costs::default())]);
        assert_eq!(figs.get("costs_headline"), None);
    }

    #[test]
    fn a_partial_read_keeps_its_data_at_warn_with_the_reason() {
        let mut c = card();
        c.level = HubLevel::Ok;
        c.error = Some("pipeline: timed out".into());
        let d = document(&[c], &[], 0, None);
        let s = &d.sections[0];
        assert_eq!(s.level, Level::Warn);
        assert!(
            matches!(&s.items[0], Item::Metric { value, level: Level::Warn, .. } if value == "3")
        );
        assert!(s.items.iter().any(|i| matches!(i, Item::Bar { .. })));
        assert!(s.items.iter().any(|i| matches!(i, Item::Pill { .. })));
        assert!(s.items.iter().any(
            |i| matches!(i, Item::Row { text, level: Level::Warn, .. } if text == "pipeline: timed out")
        ));
        // A card with nothing to look at sends no heading, but still what it counted.
        let mut calm = card();
        calm.lists.clear();
        let items = &document(&[calm], &[], 0, None).sections[0].items;
        assert!(!items
            .iter()
            .any(|i| matches!(i, Item::Text { text } if text == "Where to look first")));
        assert!(matches!(items.last(), Some(Item::Text { text }) if text == "tripped watches"));
    }

    #[test]
    fn a_cost_that_could_not_be_read_is_bad_and_keeps_the_bills() {
        let mut k = crate::costs::Costs::default();
        k.budget.spent = "$1,013".into();
        k.fleet_cost.why = Some("fleet-cost: file missing".into());
        let s = &document(&[crate::cards::costs(&k)], &[], 0, None).sections[0];
        assert_eq!(s.level, Level::Bad);
        assert!(
            matches!(&s.items[0], Item::Metric { value, level: Level::Bad, .. } if value == "-")
        );
        assert!(s.items.iter().any(
            |i| matches!(i, Item::Pill { label, value, .. } if label == "Month" && value == "$1,013")
        ));
        assert!(s.items.iter().any(
            |i| matches!(i, Item::Row { text, level: Level::Warn, .. } if text.contains("file missing"))
        ));
    }

    /// Every real card's unit fits the schema whole: a cap that clips it ("on deck, 24...") loses
    /// what the number counts, so a count beside the word is a part instead.
    #[test]
    fn every_card_unit_fits_the_widget_whole() {
        use crate::cards::{self, Reads};
        let sessions: Vec<crate::session_table::SessionRow> = vec![];
        let board = crate::tasks::Feed {
            totals: Some(Default::default()),
            ..Default::default()
        };
        let infra = crate::infra::Infra {
            ok: true,
            ..Default::default()
        };
        let (queue, alerts, costs) = (Default::default(), Default::default(), Default::default());
        let (releases, schedules, projects) =
            (Default::default(), Default::default(), Default::default());
        let reads = Reads {
            sessions: Some(Ok(&sessions[..])),
            board: Some(Ok(&board)),
            queue: Some(Ok(&queue)),
            merged: Some(&[]),
            now: 0,
            pipeline: None,
            alerts: Some(Ok(&alerts)),
            infra: Some(Ok(&infra)),
            costs: Some(Ok(&costs)),
            releases: Some(Ok(&releases)),
            schedules: Some(Ok(&schedules)),
            projects: Some(Ok(&projects)),
        };
        let home = crate::home::Home::default();
        let mut all = vec![cards::needs(&home, 0), cards::main_red(&home)];
        all.extend(cards::grid(&reads));
        all.push(Card::reading("health", "Health"));
        assert_eq!(all.len(), cards::ORDER.len() + 1);
        let d = document(&all, &[], 0, None);
        for (c, s) in all.iter().zip(&d.sections) {
            assert!(
                c.unit.chars().count() <= UNIT_MAX,
                "{}: {:?} is over {UNIT_MAX}",
                c.tab,
                c.unit
            );
            if let Some(Item::Metric { unit, .. }) = s.items.first() {
                assert_eq!(unit, &c.unit, "{}", c.tab);
            }
        }
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
        c.lists[0].rows[0].text = "x".repeat(300);
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
        long.lists[0].rows[0].text = "y".repeat(400);
        let mut partial = card();
        partial.error = Some("pipeline: timed out".into());
        let cards = [
            card(),
            long,
            partial,
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
