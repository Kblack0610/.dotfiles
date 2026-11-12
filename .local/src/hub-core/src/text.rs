//! Free text as a title: what a board row, a queue item or an ask is, in a few words, the same
//! on every surface that shows it. [`clean`] is the one place a title loses what is not its
//! words (a checkbox, a `type(area):`, a leading or bracketed id, a `#tag`, a marker comment);
//! every title on every table comes through it, by [`title`] or [`headline`]. An id it takes out
//! is a column of its own (the board's `id`, the queue's `row`), never part of a title.

/// The longest title a view shows, in chars.
pub const TITLE_MAX: usize = 100;

/// The most words a [`title`] keeps before it is cut.
const TITLE_WORDS: usize = 8;
/// Words past TITLE_WORDS a title may keep rather than cut: a summary of one word reads as noise.
const TITLE_SLACK: usize = 3;

/// The row types a bare `type: ` prefix names (notes' row types, as the boards use them); a
/// `word(area): ` prefix is a type whatever its word.
const KINDS: &[&str] = &[
    "feat", "fix", "chore", "check", "run", "decide", "epic", "refactor", "docs", "perf",
    "research", "test", "ci", "verify", "spike", "build", "style", "revert", "deps", "release",
    "hotfix", "wip",
];

/// A text with everything that is not its words taken out, and what came out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Clean {
    pub text: String,
    /// `fix` of `fix(hub): ...`.
    pub kind: Option<String>,
    /// `hub` of `fix(hub): ...`.
    pub area: Option<String>,
    /// The ids it led with or named in brackets, in order: `apo-104 P2`, `ar-1928`.
    pub ids: Vec<String>,
}

impl Clean {
    /// The words, or the ids when the text was nothing but ids (`fix(x): ar-186`), so a cell is
    /// never blank.
    pub fn shown(self) -> String {
        if self.text.is_empty() { self.ids.join(", ") } else { self.text }
    }
}

/// A `#` word that is a tag (`#size/s`, `#urgent`), not a PR (`#1980`) or a colour (`#fff`).
fn is_tag(w: &str) -> bool {
    w.strip_prefix('#').is_some_and(|t| {
        let t = t.trim_end_matches(|c: char| c.is_ascii_punctuation() && c != '/');
        let hex = matches!(t.len(), 3 | 4 | 6 | 8) && t.bytes().all(|b| b.is_ascii_hexdigit());
        t.starts_with(|c: char| c.is_alphabetic()) && !hex
    })
}

/// A board row or queue id: lowercase letters, a dash and digits, then any slug words
/// (`ar-1928`, `ucp-819-hurt-grunts`, `liveness-1794305214`).
pub fn is_id(w: &str) -> bool {
    let mut parts = w.split('-');
    let head = parts.next().unwrap_or("");
    let Some(num) = parts.next() else { return false };
    !head.is_empty()
        && head.len() <= 12
        && head.bytes().all(|b| b.is_ascii_lowercase())
        && !num.is_empty()
        && num.bytes().all(|b| b.is_ascii_digit())
        && parts.all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()))
}

/// A plan phase tag beside an id: `P2`, `P4+5`, `P2b`.
fn is_phase(w: &str) -> bool {
    w.strip_prefix('P').is_some_and(|n| {
        n.starts_with(|c: char| c.is_ascii_digit())
            && n.bytes().all(|b| b.is_ascii_digit() || b == b'+' || b.is_ascii_lowercase())
    })
}

/// The ids a head names when it is only ids (each maybe with its phase), else None.
fn ids_of(head: &str) -> Option<Vec<String>> {
    let mut ids: Vec<String> = Vec::new();
    for w in head.split([' ', ',']).filter(|w| !w.is_empty()) {
        if is_id(w) {
            ids.push(w.to_string());
        } else if is_phase(w) && !ids.is_empty() {
            let last = ids.last_mut()?;
            last.push(' ');
            last.push_str(w);
        } else {
            return None;
        }
    }
    (!ids.is_empty()).then_some(ids)
}

/// `type(area)` or a bare known type, as (type, area).
fn kind_of(head: &str) -> Option<(String, Option<String>)> {
    // `feat!:` and `feat(x)!:` mark a breaking change; the type is the same.
    let head = head.strip_suffix('!').unwrap_or(head);
    if let Some((k, rest)) = head.split_once('(') {
        let area = rest.strip_suffix(')')?;
        let ok = !k.is_empty() && k.bytes().all(|b| b.is_ascii_lowercase()) && !area.contains(['(', ')']);
        return ok.then(|| (k.to_string(), Some(area.to_string())));
    }
    KINDS.contains(&head).then(|| (head.to_string(), None))
}

/// `text` without its checkbox, marker comment, leading `type(area): ` labels and id prefixes
/// (`apo-104 P2: `, `ucp-486, ucp-526: `, in any order), bracketed id lists (`(ar-1928)`) and
/// `#tags` (a `#` and a letter; `#1980` is a PR and stays). Lines keep their breaks. Counted
/// from the text, never written by a model (dashboards rule 6).
pub fn clean(text: &str) -> Clean {
    let mut out = Clean::default();
    let mut t = text.trim();
    if let Some(r) = t.strip_prefix("- [") {
        if r.get(1..3) == Some("] ") {
            t = r[3..].trim_start();
        }
    }
    let mut t = t.split("<!--").next().unwrap_or(t).trim().to_string();
    loop {
        let Some((head, rest)) = t.split_once(": ") else { break };
        if let Some(ids) = ids_of(head) {
            out.ids.extend(ids);
        } else if let Some((k, a)) = kind_of(head) {
            // Stacked labels (`feat(deploy): cleanup(home-config): `): the first of each wins.
            out.kind = out.kind.or(Some(k));
            out.area = out.area.or(a);
        } else if out.area.as_deref() == Some(head) {
            // The area said again (`chore(docs): docs: `). Any other bare word stays: a playtest
            // check's `headset: ` is its own head.
        } else {
            break;
        }
        t = rest.trim_start().to_string();
    }
    // A bracket that holds only ids is a reference, not words: `... (ar-1928)`.
    let mut words = String::with_capacity(t.len());
    let mut rest = t.as_str();
    while let Some(open) = rest.find('(') {
        let Some(close) = rest[open..].find(')').map(|c| open + c) else { break };
        match ids_of(&rest[open + 1..close]) {
            Some(ids) => {
                out.ids.extend(ids);
                words.push_str(rest[..open].trim_end());
            }
            None => words.push_str(&rest[..=close]),
        }
        rest = &rest[close + 1..];
    }
    words.push_str(rest);
    out.text = words
        .lines()
        .map(|l| {
            l.split_whitespace()
                .filter(|w| !is_tag(w))
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    out
}

/// A row's title, what it leaves out, and what [`clean`] took out of it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Title {
    pub title: String,
    pub summary: String,
    pub kind: Option<String>,
    pub area: Option<String>,
    pub ids: Vec<String>,
}

/// A row's text as the few words a table leads with, and what the title leaves out: the summary
/// line a board draws under it, empty when the title is all of it. The title is the [`clean`]
/// text up to the first clause break (`: `, `, `, `; `, ` - `, ` (`) that leaves two words or
/// more, at most [`TITLE_WORDS`] words (plus [`TITLE_SLACK`]); a cut title leaves the rest from
/// the word it stopped at, so no word is lost. A text that is only ids is titled by them.
pub fn title(text: &str) -> Title {
    let c = clean(text);
    let line = c.text.split_whitespace().collect::<Vec<_>>().join(" ");
    let (title, mut summary) = clause(&line);
    if title.is_empty() {
        return Title { title: c.ids.join(", "), summary, kind: c.kind, area: c.area, ids: c.ids };
    }
    // The ids the title lost stay readable in the summary, never in the title.
    if !c.ids.is_empty() {
        let refs = c.ids.join(", ");
        summary = if summary.is_empty() { refs } else { format!("{summary} ({refs})") };
    }
    Title { title, summary, kind: c.kind, area: c.area, ids: c.ids }
}

/// `line` cut at its first clause break, as [`title`] describes.
fn clause(line: &str) -> (String, String) {
    let end = [": ", ", ", "; ", " - ", " ("]
        .iter()
        .filter_map(|p| {
            line.match_indices(p)
                .map(|(i, _)| i)
                .find(|&i| line[..i].split_whitespace().count() >= 2)
        })
        .min()
        .unwrap_or(line.len());
    let words: Vec<&str> = line[..end].split_whitespace().collect();
    // A tail of a few words reads better kept than moved alone to the summary.
    let cut = words.len() > TITLE_WORDS + TITLE_SLACK;
    let n = if cut { TITLE_WORDS } else { words.len() };
    let title = words[..n].join(" ");
    let title = title.trim_end_matches([',', ';', ':', '.']);
    if cut {
        let rest: Vec<&str> = line.split_whitespace().skip(TITLE_WORDS).collect();
        return (format!("{title}..."), format!("...{}", rest.join(" ")));
    }
    let rest = line[end..].trim_start_matches([':', ',', ';', '-', ' ']);
    // `Space Raiders (v0.3.2)`: a parenthesis that closes the line is the summary, unwrapped;
    // one that closes mid-line stays as written.
    let rest = match rest.strip_prefix('(').and_then(|r| r.strip_suffix(')')) {
        Some(inner) if !inner.contains([')', '(']) => inner,
        _ => rest,
    };
    (title.to_string(), rest.trim().to_string())
}

/// A text's title and the rest of it, for prose (an ask, a session's topic, a task): the
/// [`clean`] text's first line up to its first sentence end, each file path as its name
/// (`/a/b/plan.md` as `plan`), capped at `TITLE_MAX`. The rest is the text as written (its
/// tags, refs and indentation kept) after that sentence; when the title had to be cut it is the
/// whole text, so nothing is only in the cut-off part.
pub fn headline(text: &str) -> (String, String) {
    let cleaned = clean(text);
    let (line, _) = sentence(&cleaned.text);
    let words: Vec<String> = line.split_whitespace().map(short_path).collect();
    let full = words.join(" ");
    let full = full.trim_end_matches('.');
    let title = cap(full, TITLE_MAX);
    let raw = text.trim();
    let rest = if title != full { raw.to_string() } else { sentence(raw).1 };
    (title, rest)
}

/// `text`'s first line up to its first sentence end, and everything after it.
fn sentence(text: &str) -> (&str, String) {
    let (line, after) = text.split_once('\n').unwrap_or((text, ""));
    let line = line.trim();
    let end = [". ", "? ", "! "]
        .iter()
        .filter_map(|p| line.find(p))
        .map(|i| i + 1)
        .min()
        .unwrap_or(line.len());
    let rest = [line[end..].trim(), after.trim_end()]
        .iter()
        .filter(|s| !s.trim().is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join("\n");
    (&line[..end], rest)
}

/// A word that is a file path, as the file's name without its extension; the punctuation after
/// it is kept. Anything else as it is.
fn short_path(w: &str) -> String {
    let body = w.trim_end_matches([':', ',', ';', '.', ')']);
    if !(body.starts_with('/') || body.starts_with("~/")) || !body[1..].contains('/') {
        return w.to_string();
    }
    let name = body.rsplit('/').next().unwrap_or(body);
    let stem = name.rsplit_once('.').map_or(name, |(s, _)| s);
    format!("{stem}{}", &w[body.len()..])
}

/// `s` cut on a word boundary to fit `max` chars with the "..." it gains when cut, so a cap
/// a lint enforces holds.
pub fn cap(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let cut: String = s.chars().take(max.saturating_sub(3)).collect();
    let cut = cut.rsplit_once(' ').map_or(cut.as_str(), |(a, _)| a);
    format!("{}...", cut.trim_end_matches([',', ';', ':']))
}

/// `MM-DD` of a `YYYY-MM-DD`: a day beside a row, where the year is plain.
pub fn short_day(d: &str) -> &str {
    d.get(5..).unwrap_or(d)
}

/// An age at a glance: minutes, then hours, then days (the phone widget and the needs page).
pub fn age(secs: i64) -> String {
    match secs.max(0) {
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

/// Unix seconds at the local midnight that starts the day holding `now`.
pub fn local_day_start(now: i64) -> i64 {
    use chrono::{Local, TimeZone};
    Local
        .timestamp_opt(now, 0)
        .single()
        .and_then(|t| t.date_naive().and_hms_opt(0, 0, 0))
        // A DST change that skips midnight starts the day at the first time that exists.
        .and_then(|d| {
            (0..3).find_map(|h| {
                Local
                    .from_local_datetime(&(d + chrono::Duration::hours(h)))
                    .earliest()
            })
        })
        .map_or(now, |t| t.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_fits_its_max_with_the_ellipsis() {
        let word = "x".repeat(200);
        assert_eq!(cap(&word, 160).chars().count(), 160);
        let words = format!("{} tail", "a b".repeat(60));
        assert!(cap(&words, 160).chars().count() <= 160);
        assert!(cap(&words, 160).ends_with("..."));
        assert_eq!(cap("short", 160), "short");
    }

    #[test]
    fn the_title_is_the_first_sentence_and_the_rest_follows_it() {
        let (t, r) = headline("\nShip it? The build is green.\nOptions: yes, no");
        assert_eq!(t, "Ship it?");
        assert_eq!(r, "The build is green.\nOptions: yes, no");
        assert_eq!(
            headline("One line only."),
            ("One line only".into(), String::new())
        );
        assert_eq!(headline(""), (String::new(), String::new()));
    }

    #[test]
    fn a_path_in_the_title_reads_as_its_name_and_stays_whole_in_the_rest() {
        let (t, r) = headline("Read /a/b/plan.md: then go. See /a/b/plan.md too");
        assert_eq!(t, "Read plan: then go");
        assert_eq!(r, "See /a/b/plan.md too");
    }

    /// What no title on any table may hold: a leading id, a `type(area):`, a `#tag`.
    /// A title is dirty when it opens with ids or a type label and a colon (`apo-120: `,
    /// `ucp-486, ucp-526: `, `fix(hub): `) or holds a `#tag`.
    fn dirty(t: &str) -> bool {
        t.split_once(": ").is_some_and(|(h, _)| ids_of(h).is_some() || kind_of(h).is_some())
            || t.split_whitespace().any(|w| {
                w.strip_prefix('#').is_some_and(|r| r.starts_with(|c: char| c.is_alphabetic()))
            })
    }

    #[test]
    fn a_title_holds_no_id_type_tag_or_marker_and_the_ids_come_out_in_order() {
        // Real shapes from the queue and the boards (2026-11-12).
        for (text, want, ids, kind) in [
            ("apo-120: base UI screens lay lists out as rows", "base UI screens lay lists out as rows", vec!["apo-120"], None),
            ("apo-104 P2: town gate frames, corner watchtowers", "town gate frames, corner watchtowers", vec!["apo-104 P2"], None),
            ("ucp-819-hurt-grunts P4: Swap the grunt clip", "Swap the grunt clip", vec!["ucp-819-hurt-grunts P4"], None),
            ("ucp-486, ucp-526: land both", "land both", vec!["ucp-486", "ucp-526"], None),
            ("fix(agent-web): a Queue row opens under it (ar-1947)", "a Queue row opens under it", vec!["ar-1947"], Some("fix")),
            ("feat(board): titles on every row (ar-1928, ar-1930) #size/s", "titles on every row", vec!["ar-1928", "ar-1930"], Some("feat")),
            ("fix(x): ar-186: gate line", "gate line", vec!["ar-186"], Some("fix")),
            ("feat!: drop the old flag", "drop the old flag", vec![], Some("feat")),
            ("- [ ] fix(ci): runner OOM #tier/2 #low <!-- id:ucp-197 -->", "runner OOM", vec![], Some("fix")),
            ("- [x] chore: tidy past #1980", "tidy past #1980", vec![], Some("chore")),
            ("feat(deploy): cleanup(home-config): per the runbook", "per the runbook", vec![], Some("feat")),
            ("chore(docs): docs: docs/architecture.md #size/s", "docs/architecture.md", vec![], Some("chore")),
            ("chore(security): security: A secret scan gates commits", "A secret scan gates commits", vec![], Some("chore")),
            // An id inside the sentence is prose, not a prefix: `week-46` and `tier-2` are words.
            ("ucp-486 finish landing", "ucp-486 finish landing", vec![], None),
            ("week-46 claude canaries scored", "week-46 claude canaries scored", vec![], None),
            // Words stay words: a name before a colon, a bracket that is prose, a version.
            ("Home: the player room", "Home: the player room", vec![], None),
            ("DodginBalls epic, P4 (game: verified join)", "DodginBalls epic, P4 (game: verified join)", vec![], None),
            ("Space Raiders (v0.3.2)", "Space Raiders (v0.3.2)", vec![], None),
            ("Phase 4 of the plan rewards-admin: Game", "Phase 4 of the plan rewards-admin: Game", vec![], None),
        ] {
            let c = clean(text);
            assert_eq!(c.text, want, "{text}");
            assert_eq!(c.ids, ids, "{text}");
            assert_eq!(c.kind.as_deref(), kind, "{text}");
            assert!(!dirty(&c.text), "{text} -> {}", c.text);
            assert!(!dirty(&title(text).title), "{text}");
            assert!(!dirty(&headline(text).0), "{text}");
        }
        // The negative control: the check catches what the old cleaners let through.
        for old in ["apo-120: base UI", "apo-104 P2: town gate", "ucp-486, ucp-526: x", "fix(hub): x", "a row #size/s"] {
            assert!(dirty(old), "{old}");
        }
    }

    #[test]
    fn the_ids_a_title_loses_stay_in_its_summary_and_a_colour_is_not_a_tag() {
        let t = title("ucp-486, ucp-526: land both");
        assert_eq!((t.title.as_str(), t.summary.as_str()), ("land both", "ucp-486, ucp-526"));
        let t = title("fix(ui): set accent to #fff, then #a1b2c3 #size/s (ar-9)");
        assert_eq!((t.title.as_str(), t.summary.as_str()), ("set accent to #fff", "then #a1b2c3 (ar-9)"));
        assert!(is_tag("#size/s") && is_tag("#urgent") && !is_tag("#fff") && !is_tag("#1980"));
    }

    #[test]
    fn a_headlines_rest_is_the_text_as_written() {
        let ask = "Merge the #fff theme? (ar-1928)\n  - option a\n    code";
        let (t, rest) = headline(ask);
        assert_eq!(t, "Merge the #fff theme?");
        assert_eq!(rest, "(ar-1928)\n  - option a\n    code");
        // A one-sentence ask has no rest, so agent-web keeps it whole as the title.
        assert_eq!(headline("fix(x): one line #low").1, "");
    }

    #[test]
    fn a_text_that_is_only_ids_is_titled_by_them_and_lines_keep_their_breaks() {
        assert_eq!(title("ar-186").title, "ar-186");
        assert_eq!(title("(ar-1, ar-2)").title, "ar-1, ar-2");
        assert_eq!(clean("fix(x): one #a\ntwo (ar-9)\nthree").text, "one\ntwo\nthree");
    }

    #[test]
    fn a_cut_title_leaves_the_whole_text_as_the_rest() {
        let long = "word ".repeat(40);
        let (t, r) = headline(&long);
        assert!(
            t.ends_with("word...") && t.chars().count() <= TITLE_MAX + 3,
            "{t}"
        );
        assert_eq!(r, long.trim());
    }
}
