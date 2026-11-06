//! The Daily tab's reader: one note from `notes show --json` (the CLI resolves the target and
//! keeps it inside the notes), split so both hub surfaces draw the same thing. The daily note's
//! `## Focus` comes apart into its lanes (`### Urgent`, `### High`, `### Low`, `### Done`, and
//! the unheaded lines above them), the rollup block another profile's Focus is mirrored into
//! comes out on its own, and every other `##` section, plus the link footer, is a section to
//! fold. A note that is not a daily note has no Focus and is all sections.

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
}

/// One task line: `state` is `' '` open, `'/'` doing, `'x'` done; `depth` its indent level.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Item {
    pub state: char,
    pub text: String,
    pub depth: usize,
}

/// A lane of Focus: its heading (`""` for the lines above the first one) and its lines, both
/// as markdown for the web and as items for the terminal.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Lane {
    pub name: String,
    pub markdown: String,
    pub items: Vec<Item>,
    pub open: usize,
    pub done: usize,
}

/// A `##` section of the note other than Focus (`""` for what comes before the first one,
/// `"Links"` for the footer).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Section {
    pub title: String,
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
}

/// Read the note `target` names (`daily`, `daily:YYYY-MM-DD`, or a wikilink target).
pub fn read(runner: &dyn Runner, target: &str) -> Result<View, String> {
    let argv = ["notes", "show", "--json", "--", target].map(String::from);
    parse(&runner.run(&argv)?)
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

fn lane(name: &str, lines: &[&str]) -> Lane {
    let placeholder = |l: &&&str| l.trim() == "- [ ]";
    let lines: Vec<&str> = lines.iter().filter(|l| !placeholder(l)).copied().collect();
    let items: Vec<Item> = lines.iter().filter_map(|l| item(l)).collect();
    let tops = items.iter().filter(|i| i.depth == 0);
    let done = tops.clone().filter(|i| i.state == 'x').count();
    Lane {
        name: name.to_string(),
        markdown: lines.join("\n").trim().to_string(),
        open: tops.count() - done,
        done,
        items,
    }
}

fn focus(lines: &[&str]) -> Focus {
    let (authored, rollup) = match lines.iter().position(|l| l.trim() == ROLLUP_START) {
        Some(i) => (&lines[..i], lines[i + 1..].join("\n").trim().to_string()),
        None => (lines, String::new()),
    };
    let mut lanes = Vec::new();
    let mut name = "";
    let mut start = 0;
    for (i, l) in authored.iter().enumerate() {
        if let Some(h) = l.strip_prefix("### ") {
            lanes.push(lane(name, &authored[start..i]));
            name = h.trim();
            start = i + 1;
        }
    }
    lanes.push(lane(name, &authored[start..]));
    // The `---` that sets Done apart is layout, not a line of any lane.
    for l in &mut lanes {
        l.markdown = l.markdown.trim_end_matches("---").trim().to_string();
    }
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
    let mut lines: Vec<&str> = md.lines().collect();
    // Front matter is for tools, not for reading.
    if lines.first().map(|l| l.trim()) == Some("---") {
        if let Some(end) = lines.iter().skip(1).position(|l| l.trim() == "---") {
            lines.drain(..end + 2);
        }
    }
    let mut focus_view = None;
    let mut sections = Vec::new();
    let mut title = String::new();
    let mut start = 0;
    let flush =
        |title: &str, body: &[&str], sections: &mut Vec<Section>, fv: &mut Option<Focus>| {
            if title.eq_ignore_ascii_case("focus") {
                *fv = Some(focus(body));
                return;
            }
            let markdown = body.join("\n").trim().to_string();
            let markdown = if title.is_empty() {
                // The note's `# title` is the page heading already.
                markdown
                    .lines()
                    .filter(|l| !l.starts_with("# "))
                    .collect::<Vec<_>>()
                    .join("\n")
                    .trim()
                    .to_string()
            } else {
                markdown
            };
            if !markdown.is_empty() {
                sections.push(Section {
                    title: title.to_string(),
                    markdown,
                });
            }
        };
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i];
        let footer = l.trim() == "---" && lines.get(i + 1).is_some_and(|n| n.contains("[["));
        if let Some(h) = l.strip_prefix("## ") {
            flush(&title, &lines[start..i], &mut sections, &mut focus_view);
            title = h.trim().to_string();
            start = i + 1;
        } else if footer {
            flush(&title, &lines[start..i], &mut sections, &mut focus_view);
            title = "Links".to_string();
            start = i + 1;
        }
        i += 1;
    }
    flush(&title, &lines[start..], &mut sections, &mut focus_view);
    View {
        note,
        focus: focus_view,
        sections,
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

    struct Fake(Result<String, String>);
    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv, ["notes", "show", "--json", "--", "status/inbox"]);
            self.0.clone()
        }
    }

    #[test]
    fn read_passes_the_target_as_one_argument_and_carries_the_cli_error() {
        let ok = Fake(Ok(
            r##"{"rel":"status/inbox","exists":true,"markdown":"# Inbox\n"}"##.into(),
        ));
        assert_eq!(read(&ok, "status/inbox").unwrap().note.rel, "status/inbox");
        let bad = Fake(Err("'status/inbox' is outside the notes".into()));
        assert!(read(&bad, "status/inbox").unwrap_err().contains("outside"));
    }
}
