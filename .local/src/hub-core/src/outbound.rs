//! The outbound ledger `mkt` writes: append-only events in
//! `~/.agent/outbound/<project>/<YYYY-MM>.jsonl`, folded by id into one item each, the same
//! fold as mkt's `FOLD` (docs/operations/mkt.md). The Marketing tab lists them, and agent-web
//! serves an ask's preview image only when it lies under this dir.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

/// An item in review longer than this turns Marketing amber (the plan's telemetry rule).
pub const STALE_DAYS: i64 = 7;
/// How far back the tab lists a sent item.
pub const SENT_DAYS: i64 = 30;

const DAY: i64 = 86_400;

/// The image types a preview may be, and the content type each is served as.
const IMAGES: [(&str, &str); 5] = [
    ("png", "image/png"),
    ("jpg", "image/jpeg"),
    ("jpeg", "image/jpeg"),
    ("gif", "image/gif"),
    ("webp", "image/webp"),
];

/// One item, its events folded in file order.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Item {
    pub id: String,
    pub project: String,
    pub channel: String,
    pub kind: String,
    pub title: String,
    pub draft: String,
    pub utm: String,
    /// The review ask's id, its verdict (post, hand, skip, revise) and who gave it.
    pub ask: String,
    pub verdict: String,
    pub reviewed_by: String,
    pub url: String,
    pub created: Option<i64>,
    pub asked: Option<i64>,
    pub sent: Option<i64>,
    /// draft, review, approved, revise, skipped or sent: the last step it reached.
    pub state: &'static str,
    /// What mkt-metrics last measured for a sent item (docs/operations/mkt.md "Metrics"), one line
    /// for the web and the TUI: "4 search clicks 7d, 9 wishlist adds 7d", "so far" until its week is read.
    pub results: String,
}

impl Item {
    fn apply(&mut self, e: &Value) {
        let s = |k: &str| e.get(k).and_then(Value::as_str);
        for (k, f) in [
            ("project", &mut self.project),
            ("channel", &mut self.channel),
            ("kind", &mut self.kind),
            ("title", &mut self.title),
            ("draft", &mut self.draft),
            ("utm", &mut self.utm),
            ("ask", &mut self.ask),
            ("verdict", &mut self.verdict),
            ("reviewed_by", &mut self.reviewed_by),
            ("url", &mut self.url),
        ] {
            if let Some(v) = s(k) {
                *f = v.to_string();
            }
        }
        let at = s("ts").and_then(crate::fleet::ts);
        match s("event") {
            Some("draft") => self.created = at,
            Some("review") => self.asked = at,
            Some("sent") => self.sent = at,
            Some("metrics") => {
                let w = |k: &str| e.get("window").and_then(|w| w.get(k));
                let mut r = e
                    .get("metrics")
                    .and_then(Value::as_object)
                    .into_iter()
                    .flatten()
                    .filter_map(|(k, v)| Some(format!("{} {}", v.as_f64()?, k.replace('_', " "))))
                    .collect::<Vec<_>>()
                    .join(", ");
                if !r.is_empty() && w("final").and_then(Value::as_bool) != Some(true) {
                    let to = w("to").and_then(Value::as_str).unwrap_or_default();
                    r.push_str(&format!(", so far to {to}"));
                }
                self.results = r;
            }
            _ => {}
        }
    }

    fn settle(&mut self) {
        self.state = if self.sent.is_some() {
            "sent"
        } else {
            match self.verdict.as_str() {
                "skip" => "skipped",
                "revise" => "revise",
                "" if !self.ask.is_empty() => "review",
                "" => "draft",
                _ => "approved",
            }
        };
    }

    /// Days it has waited on its review ask, at `now`.
    pub fn waited_days(&self, now: i64) -> Option<i64> {
        (self.state == "review").then_some((now - self.asked?) / DAY)
    }
}

/// The items in ledger text, oldest first by when each was drafted. A line that is not a JSON
/// object with an id is skipped.
pub fn fold(text: &str) -> Vec<Item> {
    let mut by: BTreeMap<String, Item> = BTreeMap::new();
    for e in text
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
    {
        let Some(id) = e.get("id").and_then(Value::as_str) else {
            continue;
        };
        let it = by.entry(id.to_string()).or_insert_with(|| Item {
            id: id.to_string(),
            ..Default::default()
        });
        it.apply(&e);
    }
    let mut out: Vec<Item> = by
        .into_values()
        .map(|mut i| {
            i.settle();
            i
        })
        .collect();
    out.sort_by_key(|i| i.created);
    out
}

/// One project's items, every month file in name order. No dir is no items, not an error.
pub fn read(dir: &Path, project: &str) -> Result<Vec<Item>, String> {
    let d = dir.join(project);
    let entries = match std::fs::read_dir(&d) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("{}: {e}", d.display())),
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    files.sort();
    let mut text = String::new();
    for f in files {
        text.push_str(&std::fs::read_to_string(&f).map_err(|e| format!("{}: {e}", f.display()))?);
        text.push('\n');
    }
    Ok(fold(&text))
}

/// What the Marketing tab lists: every open item (not sent, not skipped) and what went out in
/// the last `SENT_DAYS`, newest first.
pub fn shown(items: &[Item], now: i64) -> Vec<Item> {
    let mut out: Vec<Item> = items
        .iter()
        .filter(|i| match i.state {
            "sent" => i.sent.is_some_and(|t| now - t <= SENT_DAYS * DAY),
            "skipped" => false,
            _ => true,
        })
        .cloned()
        .collect();
    out.sort_by_key(|i| std::cmp::Reverse(i.sent.or(i.created)));
    out
}

/// The image the `n`th preview of ask `id` names, and its content type: only a file of an image
/// type that lies under `ledger`, so an ask file cannot make agent-web serve anything else.
pub fn preview(
    asks: &Path,
    ledger: &Path,
    id: &str,
    n: usize,
) -> Result<(PathBuf, &'static str), String> {
    let file = std::fs::read_dir(asks)
        .map_err(|e| format!("{}: {e}", asks.display()))?
        .filter_map(|e| e.ok())
        .map(|e| e.path().join(format!("{id}.md")))
        .find(|p| p.is_file())
        .ok_or_else(|| format!("no ask {id}"))?;
    let text = std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    let list = text
        .lines()
        .find_map(|l| l.strip_prefix("previews: "))
        .unwrap_or_default();
    let named = list
        .split('|')
        .filter(|p| !p.is_empty())
        .nth(n)
        .ok_or_else(|| format!("ask {id} has no preview {n}"))?;
    let real = std::fs::canonicalize(named).map_err(|e| format!("{named}: {e}"))?;
    let root = std::fs::canonicalize(ledger).map_err(|e| format!("{}: {e}", ledger.display()))?;
    if !real.starts_with(&root) {
        return Err(format!("{named} is not under the outbound ledger"));
    }
    let ext = real
        .extension()
        .and_then(|x| x.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mime = IMAGES
        .iter()
        .find(|(x, _)| *x == ext)
        .map(|(_, m)| *m)
        .ok_or_else(|| format!("{named} is not an image"))?;
    Ok((real, mime))
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_794_787_200; // 2026-11-16T00:00:00Z

    fn line(ts: &str, id: &str, ev: &str, rest: &str) -> String {
        format!(r#"{{"ts":"{ts}","id":"{id}","event":"{ev}"{rest}}}"#)
    }

    fn ledger() -> String {
        [
            line(
                "2026-11-01T10:00:00Z",
                "261101-aaaaaa",
                "draft",
                r#","project":"dodge","channel":"reddit","kind":"post","title":"build post""#,
            ),
            line(
                "2026-11-01T10:00:01Z",
                "261101-aaaaaa",
                "review",
                r#","ask":"Ab12Cd""#,
            ),
            line(
                "2026-11-14T10:00:00Z",
                "261114-bbbbbb",
                "draft",
                r#","project":"dodge","channel":"bluesky","kind":"mockup","title":"clip""#,
            ),
            "not json".into(),
            line(
                "2026-11-14T10:00:01Z",
                "261114-bbbbbb",
                "review",
                r#","ask":"Ef34Gh""#,
            ),
            line(
                "2026-11-15T09:00:00Z",
                "261114-bbbbbb",
                "verdict",
                r#","verdict":"hand","reviewed_by":"human""#,
            ),
            line(
                "2026-11-15T09:30:00Z",
                "261114-bbbbbb",
                "sent",
                r#","url":"https://bsky.app/x","by":"human""#,
            ),
            line(
                "2026-11-16T06:00:00Z",
                "261114-bbbbbb",
                "metrics",
                r#","metrics":{"search_clicks_7d":4},"window":{"from":"2026-11-15","to":"2026-11-15","final":false}"#,
            ),
            line(
                "2026-11-17T06:00:00Z",
                "261114-bbbbbb",
                "metrics",
                r#","metrics":{"wishlist_adds_7d":9},"window":{"from":"2026-11-15","to":"2026-11-16","final":false}"#,
            ),
            line(
                "2026-11-15T11:00:00Z",
                "261115-cccccc",
                "draft",
                r#","project":"dodge","channel":"steam","kind":"listing","title":"page""#,
            ),
            line(
                "2026-11-15T11:00:01Z",
                "261115-cccccc",
                "verdict",
                r#","verdict":"skip""#,
            ),
        ]
        .join("\n")
    }

    #[test]
    fn events_fold_by_id_into_the_last_state_each_reached() {
        let items = fold(&ledger());
        let st: Vec<(&str, &str)> = items.iter().map(|i| (i.id.as_str(), i.state)).collect();
        assert_eq!(
            st,
            [
                ("261101-aaaaaa", "review"),
                ("261114-bbbbbb", "sent"),
                ("261115-cccccc", "skipped")
            ]
        );
        let b = &items[1];
        assert_eq!(
            (b.ask.as_str(), b.verdict.as_str(), b.url.as_str()),
            ("Ef34Gh", "hand", "https://bsky.app/x")
        );
        assert_eq!(items[0].waited_days(T0), Some(14));
        assert_eq!(b.waited_days(T0), None, "only an item in review waits");
        // the last metrics event replaces the numbers, it does not merge into them
        assert_eq!(b.results, "9 wishlist adds 7d, so far to 2026-11-16");
        assert!(items[0].results.is_empty());
        let mut done = b.clone();
        done.apply(
            &serde_json::json!({"event": "metrics", "metrics": {"wishlist_adds_7d": 9},
            "window": {"from": "2026-11-15", "to": "2026-11-21", "final": true}}),
        );
        assert_eq!(done.results, "9 wishlist adds 7d");
    }

    #[test]
    fn the_tab_shows_open_items_and_the_last_thirty_days_sent_never_a_skip() {
        let items = fold(&ledger());
        let ids = |v: Vec<Item>| v.into_iter().map(|i| i.id).collect::<Vec<_>>();
        assert_eq!(ids(shown(&items, T0)), ["261114-bbbbbb", "261101-aaaaaa"]);
        assert_eq!(
            ids(shown(&items, T0 + 40 * DAY)),
            ["261101-aaaaaa"],
            "a send older than 30 days drops off"
        );
    }

    #[test]
    fn a_project_reads_every_month_file_and_no_dir_is_no_items() {
        let root = std::env::temp_dir().join(format!("hub-outbound-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("dodge")).unwrap();
        let text = ledger();
        let (a, b) = text.split_at(text.find("\n").unwrap());
        std::fs::write(root.join("dodge/2026-10.jsonl"), a).unwrap();
        std::fs::write(root.join("dodge/2026-11.jsonl"), b).unwrap();
        std::fs::write(root.join("dodge/notes.txt"), "ignored").unwrap();
        assert_eq!(read(&root, "dodge").unwrap(), fold(&text));
        assert_eq!(read(&root, "nothing").unwrap(), vec![]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_preview_is_served_only_as_an_image_under_the_ledger() {
        let root = std::env::temp_dir().join(format!("hub-preview-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (asks, ledger) = (root.join("asks"), root.join("outbound"));
        std::fs::create_dir_all(asks.join("dodge")).unwrap();
        std::fs::create_dir_all(ledger.join("dodge/files/x")).unwrap();
        let shot = ledger.join("dodge/files/x/shot.PNG");
        let notes = ledger.join("dodge/files/x/draft.md");
        let outside = root.join("secret.png");
        for f in [&shot, &notes, &outside] {
            std::fs::write(f, "x").unwrap();
        }
        std::fs::write(
            asks.join("dodge/Ab12Cd.md"),
            format!(
                "id: Ab12Cd\npreviews: {}|{}|{}\n",
                shot.display(),
                notes.display(),
                outside.display()
            ),
        )
        .unwrap();
        let got = |n| preview(&asks, &ledger, "Ab12Cd", n);
        assert_eq!(got(0).unwrap().1, "image/png");
        assert!(got(1).unwrap_err().contains("not an image"));
        // negative control: a real image outside the ledger is refused
        assert!(got(2)
            .unwrap_err()
            .contains("not under the outbound ledger"));
        assert!(got(3).unwrap_err().contains("no preview 3"));
        assert!(preview(&asks, &ledger, "Zz99Zz", 0).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }
}
