//! UI text as typed fields: what a section says is built from a role (title, sub, chip, next,
//! note), a count or a time, never a free sentence, so every surface draws it as sent and a cap
//! is one number. A [`Shown`] has private fields and no `Deserialize`, so the only way to a
//! `Shown` is a role constructor, which cleans the words ([`text::clean`]) and fits them to the
//! role's caps. The caps and the forbidden patterns live in `[channel.ui]` of
//! `.config/comms-lint/channels.toml`, the file comms-lint grades `hub ui-text --json` by; no cap
//! is restated here. When a text is cut, `full` keeps the uncut words for the opened row
//! (ui.md rule 9). A [`Block`] is a section: its head, and a [`Body`] of facts, steps or rows,
//! with no variant that holds a sentence list. The guard is the tests below and the ratchet
//! (`prose_fields_never_grow`), `tests/agent-web/text.test.mjs` for the web side.

use crate::{plans, text};

pub mod fmt;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::OnceLock;

/// The channel file the roles' caps are read from, the one comms-lint grades by.
const CHANNELS: &str = include_str!("../../../../.config/comms-lint/channels.toml");

/// What a [`Shown`] is for. The caps of each are `roles` in `[channel.ui]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// The few words that name a record: a link over its muted second line.
    Title,
    /// The muted second line: where, which, whose.
    Sub,
    /// A state in one or two words.
    Chip,
    /// What happens or is needed next.
    Next,
    /// One short remark the opened row adds.
    Note,
}

impl Role {
    pub const ALL: [Role; 5] = [Role::Title, Role::Sub, Role::Chip, Role::Next, Role::Note];

    /// The role's key in `roles`, and its name in the JSON.
    pub fn key(self) -> &'static str {
        match self {
            Role::Title => "title",
            Role::Sub => "sub",
            Role::Chip => "chip",
            Role::Next => "next",
            Role::Note => "note",
        }
    }

    pub fn of_key(key: &str) -> Option<Role> {
        Role::ALL.into_iter().find(|r| r.key() == key)
    }

    /// The role's caps from `[channel.ui]`.
    pub fn caps(self) -> Caps {
        static CAPS: OnceLock<HashMap<Role, Caps>> = OnceLock::new();
        CAPS.get_or_init(read_caps)[&self]
    }
}

/// The longest text a role holds, 0 for no limit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Caps {
    pub chars: usize,
    pub words: usize,
}

fn read_caps() -> HashMap<Role, Caps> {
    let doc: toml::Value = CHANNELS.parse().expect("channels.toml is TOML");
    let roles = &doc["channel"]["ui"]["roles"];
    Role::ALL
        .into_iter()
        .map(|r| {
            let n = |i: usize| {
                roles[r.key()][i]
                    .as_integer()
                    .and_then(|n| usize::try_from(n).ok())
                    .unwrap_or_else(|| {
                        panic!("[channel.ui] roles.{} needs [chars, words]", r.key())
                    })
            };
            (
                r,
                Caps {
                    chars: n(0),
                    words: n(1),
                },
            )
        })
        .collect()
}

/// Text as one role holds it. Built only by [`Shown::title`] and its siblings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Shown {
    role: Role,
    text: String,
    /// The uncut words, when `text` is a cut of them.
    #[serde(skip_serializing_if = "Option::is_none")]
    full: Option<String>,
}

impl Shown {
    /// A record's name. A board row in the `<plan> P4: <words>` shape is its words; the
    /// slash command, `type(area):` and ids a title does not need go ([`text::title`]).
    pub fn title(raw: &str) -> Shown {
        let raw = plans::legacy(raw).map_or(raw, |(.., words)| words);
        let t = text::title(raw);
        let whole = text::clean(raw).shown();
        Shown::fit(Role::Title, &t.title, &one_line(&whole))
    }

    /// A name its author wrote to be read whole (a report's title): cleaned as any text is (ids,
    /// tags and a `type(area):` head go), cut only at the role's caps. A board row's
    /// [`Shown::title`] also cuts at the first clause break and reads the legacy `<plan> P4:`
    /// shape; neither applies to free text an author titled.
    pub fn name(raw: &str) -> Shown {
        Shown::plain(Role::Title, raw)
    }

    pub fn sub(raw: &str) -> Shown {
        Shown::plain(Role::Sub, raw)
    }

    pub fn chip(raw: &str) -> Shown {
        Shown::plain(Role::Chip, raw)
    }

    pub fn next(raw: &str) -> Shown {
        Shown::plain(Role::Next, raw)
    }

    pub fn note(raw: &str) -> Shown {
        Shown::plain(Role::Note, raw)
    }

    fn plain(role: Role, raw: &str) -> Shown {
        let whole = one_line(&text::clean(raw).shown());
        Shown::fit(role, &whole, &whole)
    }

    /// `text` cut to the role's caps; `whole` is what it was cut from.
    fn fit(role: Role, text: &str, whole: &str) -> Shown {
        let caps = role.caps();
        let mut out = text.to_string();
        let words: Vec<&str> = out.split_whitespace().collect();
        let too_many = caps.words > 0 && words.len() > caps.words;
        if too_many {
            out = words[..caps.words].join(" ");
        }
        // A chip is a state, so it is cut with no "..." after it.
        if too_many && role != Role::Chip {
            out = format!("{}...", out.trim_end_matches([',', ';', ':', '.']));
        }
        if caps.chars > 0 && out.chars().count() > caps.chars {
            out = if role == Role::Chip {
                out.chars().take(caps.chars).collect()
            } else {
                text::cap(&out, caps.chars)
            };
        }
        let full = (out != whole).then(|| whole.to_string());
        Shown {
            role,
            text: out,
            full,
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn role(&self) -> Role {
        self.role
    }

    /// The uncut words: `text` when nothing was cut.
    pub fn full(&self) -> &str {
        self.full.as_deref().unwrap_or(&self.text)
    }
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A number with its unit: `3 phases`, `1 phase`, `0/1 phases`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Count {
    n: u64,
    of: Option<u64>,
    unit: &'static str,
}

impl Count {
    pub fn of(n: u64, unit: &'static str) -> Count {
        Count { n, of: None, unit }
    }

    pub fn out_of(n: u64, of: u64, unit: &'static str) -> Count {
        Count {
            n,
            of: Some(of),
            unit,
        }
    }

    /// The count as a cell says it. A unit takes an `s` unless it is one (`1 phase`), or is
    /// out of something (`0/1 phases`).
    pub fn shown(&self) -> String {
        match self.of {
            Some(of) => format!("{}/{of} {}s", self.n, self.unit),
            None => fmt::counted(self.n as usize, self.unit),
        }
    }
}

/// A time, exact: a clock time beside a row (`14:05`), or how long ago (`5m ago`), with the
/// epoch for the ISO time a hover shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct When {
    epoch: i64,
    text: String,
}

impl When {
    /// The local clock time of `epoch`.
    pub fn clock(epoch: i64) -> When {
        use chrono::{Local, TimeZone};
        let text = Local
            .timestamp_opt(epoch, 0)
            .single()
            .map_or_else(String::new, |t| t.format("%H:%M").to_string());
        When { epoch, text }
    }

    /// How long before `now` it was.
    pub fn ago(epoch: i64, now: i64) -> When {
        When {
            epoch,
            text: format!("{} ago", fmt::age(now - epoch)),
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }
}

/// A fact: a short label and its value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Fact {
    pub label: Shown,
    pub value: Shown,
}

/// What a section holds. There is no variant for a list of sentences: a record is a row of
/// cells, a status is facts, a plan is steps.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "items", rename_all = "lowercase")]
pub enum Body {
    Facts(Vec<Fact>),
    Steps(Vec<Shown>),
    Rows(Vec<Vec<Shown>>),
}

impl Body {
    /// `(label, value)` pairs, the label a chip and the value a note.
    pub fn facts(pairs: &[(&str, &str)]) -> Body {
        Body::Facts(
            pairs
                .iter()
                .map(|(l, v)| Fact {
                    label: Shown::chip(l),
                    value: Shown::note(v),
                })
                .collect(),
        )
    }

    pub fn steps(steps: &[&str]) -> Body {
        Body::Steps(steps.iter().map(|s| Shown::next(s)).collect())
    }
}

/// A section: its head and its body.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Block {
    head: Shown,
    body: Body,
}

impl Block {
    pub fn new(head: &str, body: Body) -> Block {
        Block {
            head: Shown::title(head),
            body,
        }
    }
}

/// The page fields that carry words a person reads, and the role each fills: the guard walks
/// a page's JSON by these names. A struct field of one of these names that is a `String` is
/// what `prose_fields_never_grow` counts, until it is a [`Shown`].
pub const FIELD_ROLES: &[(&str, Role)] = &[
    ("title", Role::Title),
    ("summary", Role::Sub),
    ("says", Role::Note),
    ("note", Role::Note),
    ("headline", Role::Note),
    ("holds_line", Role::Note),
    ("what", Role::Note),
    ("next", Role::Next),
    ("needs", Role::Next),
    ("landed", Role::Note),
    ("builds", Role::Note),
    ("overnight", Role::Note),
    ("money", Role::Note),
    ("details", Role::Note),
    ("errors", Role::Note),
];

/// One text a page sends: where it is, the role it fills and its words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Text {
    pub path: String,
    pub role: Role,
    pub text: String,
}

/// Every text in `page`: a [`Shown`] by its own role, else a string in a [`FIELD_ROLES`] field
/// (or an array of strings in one) by that field's role. `path` is the page's name.
pub fn walk(path: &str, page: &Value) -> Vec<Text> {
    let mut out = Vec::new();
    visit(path, page, None, &mut out);
    out
}

fn visit(path: &str, v: &Value, role: Option<Role>, out: &mut Vec<Text>) {
    match v {
        Value::Object(m) => {
            let shown = m
                .get("role")
                .and_then(Value::as_str)
                .and_then(Role::of_key)
                .zip(m.get("text").and_then(Value::as_str));
            if let Some((role, text)) = shown {
                out.push(Text {
                    path: path.to_string(),
                    role,
                    text: text.to_string(),
                });
                return;
            }
            for (k, v) in m {
                let role = FIELD_ROLES.iter().find(|(f, _)| f == k).map(|(_, r)| *r);
                visit(&format!("{path}.{k}"), v, role, out);
            }
        }
        Value::Array(a) => {
            for (i, v) in a.iter().enumerate() {
                visit(&format!("{path}[{i}]"), v, role, out);
            }
        }
        Value::String(s) => {
            if let Some(role) = role.filter(|_| !s.trim().is_empty()) {
                out.push(Text {
                    path: path.to_string(),
                    role,
                    text: s.clone(),
                });
            }
        }
        _ => {}
    }
}

/// The records `hub ui-text --json` prints, one JSON object per text, stamped `ts` for
/// comms-lint's command source.
pub fn records(pages: &[(&str, Value)], ts: &str) -> Vec<Value> {
    pages
        .iter()
        .flat_map(|(name, page)| walk(name, page))
        .map(
            |t| serde_json::json!({"ts": ts, "path": t.path, "role": t.role.key(), "text": t.text}),
        )
        .collect()
}

/// comms-lint as the tests run it: the one grader of `[channel.ui]` and the briefing channels.
#[cfg(test)]
pub(crate) mod grader {
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};

    fn repo() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    /// comms-lint's finding codes for `text` under `args` (`--channel ui --role next`). It panics
    /// when python3 or comms-lint cannot run, so a missing grader fails the test, never passes it.
    pub(crate) fn grade(args: &[&str], text: &str) -> Vec<String> {
        let mut p = Command::new("python3")
            .arg(repo().join(".local/bin/comms-lint"))
            .args(args)
            .arg("-")
            .env(
                "COMMS_CHANNELS",
                repo().join(".config/comms-lint/channels.toml"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("python3 must run comms-lint");
        p.stdin
            .take()
            .expect("piped stdin")
            .write_all(text.as_bytes())
            .expect("write to comms-lint");
        let out = p.wait_with_output().expect("comms-lint exits");
        assert!(
            matches!(out.status.code(), Some(0 | 1)),
            "comms-lint failed on {text:?}"
        );
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().split(':').next().map(String::from))
            .filter(|c| !c.is_empty() && !c.contains(' '))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::{Path, PathBuf};

    /// The findings for `text` in `role` of the `ui` channel.
    fn lint(role: Role, text: &str) -> Vec<String> {
        grader::grade(&["--channel", "ui", "--role", role.key()], text)
    }

    /// The pre-fix strings the human's screenshots showed.
    const SESSION_PROMPT: &str = "/one-shot ucp-2697: PerfRun.SwapTo waits for launcher.Current.id == 'apociseum' while the run is still starting up and the scene is not yet loaded";
    const PHASE_ROW: &str =
        "pasted-content-id-6b1b-l-wondrous-moon P4: Lab status writer for the private repo";
    const RUN_ON: &str = "Done: P1 and P2 merged. Doing: P3 type and guard in review. Next: P4 briefing. Needs you: the role caps";

    #[test]
    fn the_roles_read_their_caps_from_channels_toml() {
        assert_eq!(
            Role::Title.caps(),
            Caps {
                chars: 80,
                words: 10
            }
        );
        assert_eq!(Role::Chip.caps().words, 2);
        for r in Role::ALL {
            assert!(r.caps().chars > 0, "{} has no char cap", r.key());
        }
    }

    #[test]
    fn a_title_cut_by_the_word_cap_still_fits_the_char_cap_with_its_dots() {
        // Ten words of 7 or 8 chars come to about 79 chars, and the cut adds "...".
        let raw = "alphabe bravois charlie deltaon echofox foxtrot golfbal hotelie india99 julie9 extraword";
        let t = Shown::title(raw);
        assert!(t.text().chars().count() <= 80, "{}", t.text());
        assert!(t.text().split_whitespace().count() <= 10, "{}", t.text());
        assert!(t.text().ends_with("..."), "{}", t.text());
        assert_eq!(t.full(), raw);
    }

    #[test]
    fn a_session_prompt_is_cut_to_a_title_and_keeps_its_words_in_full() {
        let t = Shown::title(SESSION_PROMPT);
        assert!(!t.text().starts_with('/'), "{}", t.text());
        assert!(t.text().chars().count() <= 80 && t.text().split_whitespace().count() <= 10);
        assert!(t.text().ends_with("..."), "{}", t.text());
        assert!(t.full().starts_with("PerfRun.SwapTo waits"));
        assert!(t.full().contains("scene is not yet loaded"));
    }

    #[test]
    fn a_phase_row_is_its_words_not_its_plan_slug() {
        let t = Shown::title(PHASE_ROW);
        assert_eq!(t.text(), "Lab status writer for the private repo");
        assert_eq!(t.full(), t.text());
    }

    #[test]
    fn a_chip_is_two_words_and_is_never_cut_with_dots() {
        let c = Shown::chip("waiting on the human to answer");
        assert_eq!(c.text(), "waiting on");
        assert_eq!(c.full(), "waiting on the human to answer");
        assert_eq!(Shown::chip("running").full(), "running");
    }

    #[test]
    fn nothing_cut_leaves_no_full() {
        let v = serde_json::to_value(Shown::sub("Lab status")).unwrap();
        assert_eq!(v, json!({"role": "sub", "text": "Lab status"}));
    }

    #[test]
    fn a_count_carries_its_unit_and_a_time_is_exact() {
        assert_eq!(Count::of(1, "phase").shown(), "1 phase");
        assert_eq!(Count::of(3, "phase").shown(), "3 phases");
        assert_eq!(Count::out_of(0, 1, "phase").shown(), "0/1 phases");
        assert_eq!(When::ago(1000, 1300).text(), "5m ago");
        assert_eq!(When::clock(0).text().len(), 5);
    }

    #[test]
    fn a_body_has_no_sentence_list() {
        let b = Block::new(
            "fix(x): Lab status",
            Body::facts(&[("Done", "P1 and P2 merged"), ("Next", "P4 briefing")]),
        );
        let v = serde_json::to_value(&b).unwrap();
        assert_eq!(v["head"]["text"], "Lab status");
        assert_eq!(v["body"]["kind"], "facts");
        assert_eq!(v["body"]["items"][0]["label"]["role"], "chip");
        assert_eq!(v["body"]["items"][1]["value"]["text"], "P4 briefing");
    }

    #[test]
    fn walk_reads_shown_objects_and_the_prose_fields_of_a_page() {
        let page = json!({
            "needs": [{"title": "Answer the ask", "id": "ar-1", "text": "ignored"}],
            "running": [{"title": Shown::title("Fix it"), "slug": "x"}],
            "headline": "Two things need you.",
            "money": ["Spent $3"],
            "count": 4,
        });
        let got: Vec<(String, Role, String)> = walk("home", &page)
            .into_iter()
            .map(|t| (t.path, t.role, t.text))
            .collect();
        assert!(got.contains(&(
            "home.needs[0].title".into(),
            Role::Title,
            "Answer the ask".into()
        )));
        assert!(got.contains(&("home.running[0].title".into(), Role::Title, "Fix it".into())));
        assert!(got.contains(&(
            "home.headline".into(),
            Role::Note,
            "Two things need you.".into()
        )));
        assert!(got.contains(&("home.money[0]".into(), Role::Note, "Spent $3".into())));
        assert_eq!(got.len(), 4, "{got:?}");
    }

    /// Fakes of the pages agent-web and the TUI draw, built the way the builders build them.
    fn fake_pages() -> Vec<(&'static str, Value)> {
        let briefing = crate::briefing::Briefing {
            headline: "Two things need you.".into(),
            needs: vec!["Answer the ask in the dotfiles session".into()],
            landed: vec!["Merged 4 changes".into()],
            ..Default::default()
        };
        let row = crate::tasks::Row {
            title: Shown::title(SESSION_PROMPT).text().into(),
            summary: Shown::sub("Plan P3").text().into(),
            ..Default::default()
        };
        let home = crate::home::Home {
            proposals: vec![crate::proposals::Proposal {
                title: Shown::title(PHASE_ROW).text().into(),
                ..Default::default()
            }],
            errors: vec!["Could not read the queue. Reload, or check agent-web's log.".into()],
            ..Default::default()
        };
        vec![
            ("home", serde_json::to_value(home).unwrap()),
            (
                "board",
                json!({"rows": [serde_json::to_value(row).unwrap()]}),
            ),
            ("briefing", serde_json::to_value(briefing).unwrap()),
        ]
    }

    #[test]
    fn every_text_the_fake_pages_send_passes_its_roles_lint() {
        let texts: Vec<Text> = fake_pages().iter().flat_map(|(n, p)| walk(n, p)).collect();
        assert!(texts.len() >= 7, "{texts:?}");
        for t in &texts {
            let f = lint(t.role, &t.text);
            assert!(f.is_empty(), "{}: {:?} -> {f:?}", t.path, t.text);
        }
    }

    #[test]
    fn negative_control_the_pre_fix_strings_fail_the_lint() {
        let fails = |role, text: &str, code: &str| {
            let f = lint(role, text);
            assert!(f.iter().any(|c| c == code), "{text:?}: {f:?}");
        };
        fails(Role::Title, SESSION_PROMPT, "forbid");
        fails(Role::Title, SESSION_PROMPT, "too-long");
        fails(Role::Title, PHASE_ROW, "forbid");
        fails(Role::Note, RUN_ON, "run-on");
        // What the constructors make of the same strings is clean.
        for (role, raw) in [(Role::Title, SESSION_PROMPT), (Role::Title, PHASE_ROW)] {
            let s = Shown::title(raw);
            assert_eq!(s.role(), role);
            let f = lint(role, s.text());
            assert!(f.is_empty(), "{:?}: {f:?}", s.text());
        }
    }

    /// The `pub <name>: String` fields of hub-core a person reads, per source file: a string
    /// sent as a sentence. A field that becomes a [`Shown`] leaves the count, and the baseline
    /// next to this crate is lowered with it; it never rises.
    fn prose_fields() -> std::collections::BTreeMap<String, usize> {
        let names: Vec<&str> = FIELD_ROLES.iter().map(|(n, _)| *n).collect();
        let mut out = std::collections::BTreeMap::new();
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files: Vec<PathBuf> = Vec::new();
        let mut todo = vec![dir.clone()];
        while let Some(d) = todo.pop() {
            for e in std::fs::read_dir(&d).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    todo.push(p);
                } else if p.extension().is_some_and(|x| x == "rs") {
                    files.push(p);
                }
            }
        }
        for p in files {
            let src = std::fs::read_to_string(&p).unwrap();
            // Only the code above the module's tests.
            let code = src.split("#[cfg(test)]").next().unwrap_or(&src);
            let n = code
                .lines()
                .filter_map(|l| l.trim().strip_prefix("pub "))
                .filter_map(|l| l.split_once(": "))
                .filter(|(name, ty)| names.contains(name) && ty.trim_end_matches(',') == "String")
                .count();
            if n > 0 {
                let rel = p.strip_prefix(&dir).unwrap().to_string_lossy().into_owned();
                out.insert(rel, n);
            }
        }
        out
    }

    #[test]
    fn prose_fields_never_grow() {
        let base: std::collections::BTreeMap<String, usize> = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("prose-fields.baseline"),
        )
        .unwrap()
        .lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .filter_map(|l| l.split_once('\t'))
        .map(|(f, n)| (f.to_string(), n.parse().unwrap()))
        .collect();
        let now = prose_fields();
        let total: usize = now.values().sum();
        println!(
            "prose String fields in hub-core: {total} (baseline {})",
            base.values().sum::<usize>()
        );
        let mut bad = Vec::new();
        for (f, n) in &now {
            let was = base.get(f).copied().unwrap_or(0);
            if *n > was {
                bad.push(format!(
                    "{f}: {n} prose String fields, baseline {was}: send a display::Shown, or a Count, When or Block"
                ));
            } else if *n < was {
                bad.push(format!(
                    "{f}: {n} now, baseline {was}: lower the baseline to {n}"
                ));
            }
        }
        for (f, was) in &base {
            if !now.contains_key(f) {
                bad.push(format!(
                    "{f}: none now, baseline {was}: drop it from the baseline"
                ));
            }
        }
        assert!(bad.is_empty(), "{}", bad.join("\n"));
    }
}
