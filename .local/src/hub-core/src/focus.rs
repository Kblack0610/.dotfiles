//! The Daily tab's reader: one note from `notes show --json` (the CLI resolves the target and
//! keeps it inside the notes), split so both hub surfaces draw the same thing. The daily note's
//! `## Focus` comes apart into its lanes (`### Urgent`, `### High`, `### Low`, `### Done`, and
//! the unheaded lines above them), the rollup block another profile's Focus is mirrored into
//! comes out on its own, and every other `##` section, plus the link footer, is a section to
//! fold. A note that is not a daily note has no Focus and is all sections.
//! Each lane and section carries the note line it starts on and the note line of every line of
//! its markdown, so a surface that edits one row changes that line of the note as read.
//! A day note's view also carries its briefing (`notes show --json` names it) and the links the
//! web nav lists as places.

use crate::session_actions::Runner;
use serde::{Deserialize, Serialize};

/// What `notes rollup` writes ahead of the mirrored block (`notes-cli` `md::ROLLUP_START`).
const ROLLUP_START: &str = "<!-- rollup:start -->";

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Link {
    pub target: String,
    pub label: String,
    pub exists: bool,
}

/// The note as `notes show --json` prints it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Note {
    pub target: String,
    pub profile: String,
    pub path: String,
    /// Vault-relative, no `.md`: the form a `[[wikilink]]` to it takes.
    pub rel: String,
    pub title: String,
    pub exists: bool,
    pub date: Option<String>,
    pub prev: Option<String>,
    pub next: Option<String>,
    /// The base `notes put --base` takes to save over this read.
    pub hash: String,
    pub markdown: String,
    pub links: Vec<Link>,
    /// The day's briefing as a link target, on a daily note whose day has one.
    pub brief: Option<String>,
}

/// One task line: `state` is `' '` open, `'/'` doing, `'x'` done; `depth` its indent level.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Item {
    pub state: char,
    pub text: String,
    pub depth: usize,
}

/// A lane of Focus: its heading (`""` for the lines above the first one) and its lines, both
/// as markdown for the web and as items for the terminal. `line` is the note line (from 0) of
/// its heading (the `## Focus` line for the unheaded lane), and `lines[i]` the note line of line
/// `i` of `markdown`, which skips the placeholder rows and the blank ends it leaves out.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Lane {
    pub name: String,
    pub line: usize,
    pub lines: Vec<usize>,
    pub markdown: String,
    pub items: Vec<Item>,
    pub open: usize,
    pub done: usize,
}

/// A `##` section of the note other than Focus (`""` for what comes before the first one,
/// `"Links"` for the footer). `line` is the note line of its heading (of the footer's `---`, of
/// the first line below any front matter for the untitled top), `lines` as a lane's.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Section {
    pub title: String,
    pub line: usize,
    pub lines: Vec<usize>,
    pub markdown: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Focus {
    pub lanes: Vec<Lane>,
    /// The mirrored block below the rollup sentinel, markdown; empty when there is none.
    pub rollup: String,
    pub open: usize,
    pub done: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct View {
    pub note: Note,
    /// None for a note with no `## Focus` section.
    pub focus: Option<Focus>,
    pub sections: Vec<Section>,
    /// The day's briefing, read whole, under a day note whose day has one.
    pub brief: Option<Box<View>>,
    /// The links the web nav lists as places: a day note's own, else today's note's; None when
    /// today's could not be read, so the nav keeps the ones it has.
    pub places: Option<Vec<Link>>,
}

fn show(runner: &dyn Runner, target: &str) -> Result<String, String> {
    runner.run(&["notes", "show", "--json", "--", target].map(String::from))
}

/// Read the note `target` names (`daily`, `daily:YYYY-MM-DD`, or a wikilink target), with what
/// `around` adds.
pub fn read(runner: &dyn Runner, target: &str) -> Result<View, String> {
    view_of(runner, &show(runner, target)?)
}

/// The view of one `notes show --json` object (the shape `notes put` prints too), with what
/// `around` adds, so a write answers like a read.
pub fn view_of(runner: &dyn Runner, json: &str) -> Result<View, String> {
    Ok(around(runner, parse(json)?))
}

/// A view with its briefing and places read: the day's briefing under a day note, and the nav's
/// places (a day note's own links, else today's). A briefing or a today that cannot be read is
/// left out (None), never an error: the note itself was read.
fn around(runner: &dyn Runner, mut v: View) -> View {
    let read_bare = |t: &str| show(runner, t).and_then(|j| parse(&j)).ok();
    if v.note.date.is_some() {
        v.places = Some(v.note.links.clone());
        v.brief = v.note.brief.as_deref().and_then(read_bare).map(Box::new);
    } else {
        v.places = read_bare("daily").map(|d| d.note.links);
    }
    v
}

/// The view of one `notes show --json` object, the shape `notes put` prints too.
pub fn parse(json: &str) -> Result<View, String> {
    let note: Note = serde_json::from_str(json).map_err(|e| format!("notes show --json: {e}"))?;
    Ok(build(note))
}

/// The task line `l` as an item, or None when it is not a checkbox line or is the empty
/// placeholder (`- [ ] `) the sweep keeps at the top for typing into.
fn item(l: &str) -> Option<Item> {
    let indent = l.len() - l.trim_start().len();
    let rest = l.trim_start().strip_prefix("- [")?;
    let mut ch = rest.chars();
    let state = ch.next()?.to_ascii_lowercase();
    let text = ch.as_str().strip_prefix(']')?.trim();
    if !matches!(state, ' ' | '/' | 'x') || text.is_empty() {
        return None;
    }
    Some(Item {
        state,
        text: text.to_string(),
        depth: indent / 2,
    })
}

/// A note line: its number in the note (from 0) and its text.
type Ln<'a> = (usize, &'a str);

/// A block's lines as markdown and the note line of each, the blank lines at either end left out.
fn block(lines: &[Ln]) -> (String, Vec<usize>) {
    let words = |l: &Ln| !l.1.trim().is_empty();
    let start = lines.iter().position(words).unwrap_or(lines.len());
    let end = lines.iter().rposition(words).map_or(start, |i| i + 1);
    let kept = &lines[start..end];
    let text: Vec<&str> = kept.iter().map(|l| l.1).collect();
    (
        text.join("\n").trim().to_string(),
        kept.iter().map(|l| l.0).collect(),
    )
}

fn lane(name: &str, line: usize, lines: &[Ln]) -> Lane {
    let mut lines: Vec<Ln> = lines
        .iter()
        .filter(|l| l.1.trim() != "- [ ]")
        .copied()
        .collect();
    // The `---` that sets Done apart is layout, not a line of any lane.
    while lines
        .last()
        .is_some_and(|l| matches!(l.1.trim(), "" | "---"))
    {
        lines.pop();
    }
    let items: Vec<Item> = lines.iter().filter_map(|l| item(l.1)).collect();
    let tops = items.iter().filter(|i| i.depth == 0);
    let done = tops.clone().filter(|i| i.state == 'x').count();
    let (markdown, lines) = block(&lines);
    Lane {
        name: name.to_string(),
        line,
        lines,
        markdown,
        open: tops.count() - done,
        done,
        items,
    }
}

/// `## Focus` from its heading's note line `head` and the lines below it.
fn focus(head: usize, lines: &[Ln]) -> Focus {
    let (authored, rollup) = match lines.iter().position(|l| l.1.trim() == ROLLUP_START) {
        Some(i) => (&lines[..i], block(&lines[i + 1..]).0),
        None => (lines, String::new()),
    };
    let mut lanes = Vec::new();
    let mut name = "";
    let mut line = head;
    let mut start = 0;
    for (i, l) in authored.iter().enumerate() {
        if let Some(h) = l.1.strip_prefix("### ") {
            lanes.push(lane(name, line, &authored[start..i]));
            name = h.trim();
            line = l.0;
            start = i + 1;
        }
    }
    lanes.push(lane(name, line, &authored[start..]));
    lanes.retain(|l| !l.name.is_empty() || !l.items.is_empty() || !l.markdown.is_empty());
    let open = lanes.iter().map(|l| l.open).sum();
    let done = lanes.iter().map(|l| l.done).sum();
    Focus {
        lanes,
        rollup,
        open,
        done,
    }
}

/// Split a note into its Focus and its other sections.
pub fn build(note: Note) -> View {
    let md = note.markdown.clone();
    let mut lines: Vec<Ln> = md.lines().enumerate().collect();
    // Front matter is for tools, not for reading.
    if lines.first().map(|l| l.1.trim()) == Some("---") {
        if let Some(end) = lines.iter().skip(1).position(|l| l.1.trim() == "---") {
            lines.drain(..end + 2);
        }
    }
    let mut focus_view = None;
    let mut sections = Vec::new();
    let mut title = String::new();
    let mut head = lines.first().map_or(0, |l| l.0);
    let mut start = 0;
    let flush = |title: &str,
                 head: usize,
                 body: &[Ln],
                 sections: &mut Vec<Section>,
                 fv: &mut Option<Focus>| {
        if title.eq_ignore_ascii_case("focus") {
            *fv = Some(focus(head, body));
            return;
        }
        // The note's `# title` is the page heading already.
        let body: Vec<Ln> = body
            .iter()
            .filter(|l| !(title.is_empty() && l.1.starts_with("# ")))
            .copied()
            .collect();
        let (markdown, lines) = block(&body);
        if !markdown.is_empty() {
            sections.push(Section {
                title: title.to_string(),
                line: head,
                lines,
                markdown,
            });
        }
    };
    for i in 0..lines.len() {
        let l = lines[i];
        let footer = l.1.trim() == "---" && lines.get(i + 1).is_some_and(|n| n.1.contains("[["));
        let next = if let Some(h) = l.1.strip_prefix("## ") {
            h.trim().to_string()
        } else if footer {
            "Links".to_string()
        } else {
            continue;
        };
        flush(
            &title,
            head,
            &lines[start..i],
            &mut sections,
            &mut focus_view,
        );
        title = next;
        head = l.0;
        start = i + 1;
    }
    flush(
        &title,
        head,
        &lines[start..],
        &mut sections,
        &mut focus_view,
    );
    View {
        note,
        focus: focus_view,
        sections,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "---\ndate: 2026-11-05\ntags: [daily]\n---\n\n# 2026-11-05\n\n## Notes\nINGEST PIPELINE\n\n## Focus\n- [ ] \n\n### Urgent\n- [ ] add deep research #c1105 #urgent\n  - [ ] a child #c1105\n- [/] doing one #p:notes-cockpit #c1105 #urgent\n\n### High\n\n### Low\n\n---\n### Done\n- [x] water plants #c1101 #urgent\n- [x] ingest all #c1104 #high\n<!-- rollup:start -->\n### bnb\n- [ ] a bnb row\n\n## Refs\n- [[journal/refs/2026-11-05/work-ledger]]\n\n---\n- Backlog: [[journal/backlogs/fun]]\n- Board: [[lab/projects/board]]\n";

    fn note(md: &str) -> Note {
        Note {
            markdown: md.into(),
            exists: true,
            ..Default::default()
        }
    }

    #[test]
    fn the_daily_focus_comes_apart_into_its_lanes_with_counts() {
        let v = build(note(NOTE));
        let f = v.focus.expect("a focus");
        let names: Vec<&str> = f.lanes.iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, ["Urgent", "High", "Low", "Done"]);
        assert_eq!((f.open, f.done), (2, 2));
        let urgent = &f.lanes[0];
        assert_eq!(urgent.items.len(), 3);
        assert_eq!(urgent.items[1].depth, 1);
        assert_eq!(urgent.items[2].state, '/');
        assert!(
            !f.lanes[2].markdown.contains("---"),
            "the Done rule is layout"
        );
        assert_eq!(f.rollup, "### bnb\n- [ ] a bnb row");
    }

    #[test]
    fn the_other_sections_and_the_footer_fold_on_their_own() {
        let v = build(note(NOTE));
        let titles: Vec<&str> = v.sections.iter().map(|s| s.title.as_str()).collect();
        assert_eq!(titles, ["Notes", "Refs", "Links"]);
        assert!(v.sections[2]
            .markdown
            .starts_with("- Backlog: [[journal/backlogs/fun]]"));
        assert!(
            !v.sections.iter().any(|s| s.markdown.contains("date: 2026")),
            "front matter is dropped"
        );
    }

    #[test]
    fn a_note_with_no_focus_is_all_sections() {
        let v = build(note(
            "# Outbox\n\nOne per line.\n\n## Outbox\n- [ ] a line\n",
        ));
        assert!(v.focus.is_none());
        assert_eq!(
            v.sections[0],
            Section {
                title: "".into(),
                line: 0,
                lines: vec![2],
                markdown: "One per line.".into()
            }
        );
        assert_eq!(v.sections[1].title, "Outbox");
    }

    #[test]
    fn a_focus_with_no_lanes_keeps_its_lines_in_one_unheaded_lane() {
        let v = build(note("## Focus\n- [ ] one\n- [x] two\npasted prose\n"));
        let f = v.focus.unwrap();
        assert_eq!(f.lanes.len(), 1);
        assert_eq!(f.lanes[0].name, "");
        assert_eq!((f.open, f.done), (1, 1));
        assert!(f.lanes[0].markdown.contains("pasted prose"));
    }

    /// Each line of every lane's and section's markdown is the note line its map names.
    fn lines_match(v: &View) {
        let note: Vec<&str> = v.note.markdown.lines().collect();
        let f = v.focus.as_ref().map_or(vec![], |f| f.lanes.clone());
        let blocks = f
            .iter()
            .map(|l| (&l.markdown, &l.lines))
            .chain(v.sections.iter().map(|s| (&s.markdown, &s.lines)));
        for (md, lines) in blocks {
            assert_eq!(md.lines().count(), lines.len(), "{md:?}");
            for (m, &n) in md.lines().zip(lines) {
                assert_eq!(note[n].trim(), m.trim(), "line {n}");
            }
        }
    }

    #[test]
    fn each_lane_and_section_knows_its_lines_in_the_note() {
        let v = build(note(NOTE));
        lines_match(&v);
        let f = v.focus.as_ref().unwrap();
        let at = |i: usize| (f.lanes[i].line, f.lanes[i].lines.clone());
        assert_eq!(at(0), (13, vec![14, 15, 16]), "Urgent");
        assert_eq!(at(1), (18, vec![]), "High is empty");
        assert_eq!(at(2), (20, vec![]), "Low ends at the Done rule");
        assert_eq!(at(3), (23, vec![24, 25]), "Done");
        let s: Vec<(usize, Vec<usize>)> = v
            .sections
            .iter()
            .map(|s| (s.line, s.lines.clone()))
            .collect();
        assert_eq!(s, [(7, vec![8]), (30, vec![31]), (33, vec![34, 35])]);
    }

    #[test]
    fn a_placeholder_row_inside_a_lane_is_skipped_by_the_line_map() {
        let v = build(note(
            "# Fri\n## Focus\n- [ ] loose\n### Urgent\n- [ ]\n- [ ] a\n- [ ]\n\n- [ ] b\n",
        ));
        lines_match(&v);
        let f = v.focus.unwrap();
        assert_eq!((f.lanes[0].name.as_str(), f.lanes[0].line), ("", 1));
        assert_eq!(f.lanes[0].lines, [2]);
        assert_eq!(f.lanes[1].markdown, "- [ ] a\n\n- [ ] b");
        assert_eq!(f.lanes[1].lines, [5, 7, 8]);
    }

    /// `notes show --json` for each target it knows; any other target is the CLI's error.
    struct Fake(Vec<(&'static str, &'static str)>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(&argv[..4], ["notes", "show", "--json", "--"]);
            let t = argv[4].as_str();
            let found = self.0.iter().find(|(k, _)| *k == t);
            found
                .map(|(_, j)| j.to_string())
                .ok_or(format!("'{t}' is outside the notes"))
        }
    }

    const DAY: &str = r##"{"rel":"journal/daily/2026-11-05","date":"2026-11-05","exists":true,"markdown":"# Thu\n","brief":"journal/refs/2026-11-05/briefing","links":[{"target":"outbox","exists":true}]}"##;
    const BRIEF: &str = r##"{"rel":"journal/refs/2026-11-05/briefing","exists":true,"markdown":"# Briefing\n## Needs you\n- one\n"}"##;

    #[test]
    fn read_passes_the_target_as_one_argument_and_carries_the_cli_error() {
        let ok = Fake(vec![(
            "status/inbox",
            r##"{"rel":"status/inbox","exists":true,"markdown":"# Inbox\n"}"##,
        )]);
        assert_eq!(read(&ok, "status/inbox").unwrap().note.rel, "status/inbox");
        assert!(read(&ok, "gone").unwrap_err().contains("outside"));
    }

    #[test]
    fn a_day_reads_its_briefing_and_lists_its_own_links_as_places() {
        let v = read(
            &Fake(vec![
                ("daily", DAY),
                ("journal/refs/2026-11-05/briefing", BRIEF),
            ]),
            "daily",
        )
        .unwrap();
        assert_eq!(v.places.as_ref().unwrap()[0].target, "outbox");
        let b = v.brief.expect("the briefing");
        assert_eq!(b.sections[0].title, "Needs you");
        assert!(b.brief.is_none() && b.places.is_none(), "read bare");
        // A briefing that cannot be read is left out; the day still reads.
        let v = read(&Fake(vec![("daily", DAY)]), "daily").unwrap();
        assert!(v.brief.is_none());
    }

    #[test]
    fn another_note_lists_todays_links_as_places_and_has_no_briefing() {
        let inbox = r##"{"rel":"status/inbox","exists":true,"markdown":"# Inbox\n"}"##;
        let v = read(
            &Fake(vec![("status/inbox", inbox), ("daily", DAY)]),
            "status/inbox",
        )
        .unwrap();
        assert_eq!(v.places.as_ref().unwrap()[0].target, "outbox");
        assert!(v.brief.is_none());
        let v = read(&Fake(vec![("status/inbox", inbox)]), "status/inbox").unwrap();
        assert!(v.places.is_none(), "no today: places unknown, no error");
    }
}
