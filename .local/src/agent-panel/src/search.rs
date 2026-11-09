//! Typing in the chooser searches what each agent's session has been about, not only its row.
//!
//! A row shows the session's current title, and Claude retitles a session as its subject
//! drifts, so an agent that started on audio and moved on cannot be found by "audio" in the
//! row. The sessions index (`~/.agent/sessions/index.tsv`, written only by `sessions index`)
//! keeps every title a session had, its first and last prompt, branch and touched files. Each
//! row gets a note of that text, saved beside the map file, and every typed word must appear in
//! the note: the rule `sessions search` (Prefix+R) applies, `.local/bin/sessions` cmd_filter.
//! A typed word that names a topic in `topics.conf` also matches any of that topic's words, so
//! "audio" finds the session that only ever said "music" or "speaker".

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::chooser::Agent;
use crate::render::Row;

/// The sessions index, as `.local/bin/sessions` names it.
pub fn index_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".agent/sessions/index.tsv"))
}

/// The notes file beside a map file.
pub fn notes_path(map_file: &Path) -> PathBuf {
    let mut p = map_file.as_os_str().to_owned();
    p.push(".notes");
    PathBuf::from(p)
}

/// Session id -> its index text, lowercased. Index columns (sessions cmd_filter reads the same
/// ones): 1 id, 6 branch, 8 titles_all, 9 first_prompt, 10 last_prompt, 11 files. `-` is the
/// index's empty value.
pub fn index_notes(index: &str) -> HashMap<String, String> {
    index
        .lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\t').collect();
            let id = f.first().filter(|id| !id.is_empty())?;
            let text: Vec<&str> =
                [5, 7, 8, 9, 10].iter().filter_map(|&i| f.get(i)).copied().filter(|v| *v != "-" && !v.is_empty()).collect();
            Some((id.to_string(), text.join(" ").to_lowercase()))
        })
        .collect()
}

/// The topics file, beside `time-use.conf`. Read at each run; no rebuild needed.
const TOPICS_CONF: &str = ".config/agent-panel/topics.conf";

/// Topic -> its words, from `topics.conf` lines `<topic> <word> <word> ...`; `#` lines and blank
/// lines are skipped. A missing file gives no topics: each word then matches only itself.
pub fn topics(conf: &str) -> HashMap<String, Vec<String>> {
    conf.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let mut words = l.split_whitespace().map(str::to_lowercase);
            Some((words.next()?, words.collect()))
        })
        .collect()
}

/// The topics on disk (`TOPICS_CONF` under the home directory).
pub fn read_topics() -> HashMap<String, Vec<String>> {
    topics(&std::fs::read_to_string(crate::session::home().join(TOPICS_CONF)).unwrap_or_default())
}

/// Strip ANSI colour escapes, so a note holds the words a human reads on the row.
fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// One line per row, in row order: `<note>\t<row text>`. A row's note is its display text, its
/// agent's project and cwd, and its session's index text; a project header's note is its own
/// text. Neither carries a tab or newline, so the first tab ends the note.
pub fn notes(rows: &[Row], agents: &[Agent], index: &HashMap<String, String>) -> String {
    let by_target: HashMap<&str, &Agent> = agents.iter().map(|a| (a.target.as_str(), a)).collect();
    rows.iter()
        .map(|r| {
            let mut note = plain(r.text.split_once('\t').map_or(r.text.as_str(), |(_, d)| d));
            if let Some(a) = by_target.get(r.target.as_str()) {
                note.push(' ');
                note.push_str(&a.project);
                // The checkout's own name (a worktree's carries its slug), not the whole path,
                // whose /home/<user>/ is in every row and would make "home" match them all.
                note.push(' ');
                note.push_str(a.cwd.rsplit('/').find(|p| !p.is_empty()).unwrap_or(""));
                if let Some(text) = index.get(&a.session_id) {
                    note.push(' ');
                    note.push_str(text);
                }
            }
            let note = note.to_lowercase().replace(['\t', '\n', '\r'], " ");
            format!("{note}\t{}", r.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Every typed word, case-insensitive, is somewhere in the note. Each entry of `words` is one
/// typed word (matched anywhere, as Prefix+R does) and, for a topic, its words, which match only
/// at the start of a word: "helm" is not in "overwhelm", "pod" not in "tripod".
fn matches(note: &str, words: &[Vec<&str>]) -> bool {
    words.iter().all(|alts| {
        alts.first().is_some_and(|w| note.contains(w)) || alts.iter().skip(1).any(|w| starts_a_word(note, w))
    })
}

fn starts_a_word(note: &str, w: &str) -> bool {
    note.match_indices(w)
        .any(|(i, _)| note[..i].chars().next_back().is_none_or(|c| !c.is_alphanumeric()))
}

/// The rows of `notes` (see [`notes`]) that match `query`, as fzf input. A leading `'` on a word
/// (fzf's exact match, which `agent-panel "'dotfiles"` types up front) is dropped. A project
/// header is kept when any agent under it matches; an empty query keeps every row.
pub fn filter(notes: &str, query: &str, topics: &HashMap<String, Vec<String>>) -> String {
    let typed: Vec<String> = query
        .split_whitespace()
        .map(|w| w.trim_start_matches('\'').to_lowercase())
        .filter(|w| !w.is_empty())
        .collect();
    let words: Vec<Vec<&str>> = typed
        .iter()
        .map(|w| {
            let mut alts = vec![w.as_str()];
            alts.extend(topics.get(w).into_iter().flatten().map(String::as_str));
            alts
        })
        .collect();
    let mut out: Vec<&str> = Vec::new();
    let mut header: Option<&str> = None;
    for line in notes.lines() {
        let Some((note, row)) = line.split_once('\t') else { continue };
        if row.starts_with('\t') {
            // A header: its target field is empty. Held until one of its agents matches.
            header = Some(row);
            if words.is_empty() {
                out.push(row);
                header = None;
            }
            continue;
        }
        if matches(note, &words) {
            if let Some(h) = header.take() {
                out.push(h);
            }
            out.push(row);
        }
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(target: &str, session_id: &str, project: &str) -> Agent {
        Agent {
            target: target.into(),
            session_id: session_id.into(),
            project: project.into(),
            cwd: format!("/home/u/{project}"),
            ..Agent::default()
        }
    }

    fn row(target: &str, display: &str) -> Row {
        Row { target: target.into(), text: format!("{target}\t{display}") }
    }

    fn fixture() -> String {
        let index = "sid-1\tu\t-\t1\t/home/u/dotfiles\tfeat/x\tfix-nightly-test-red-loop\tTurntable speaker audio not working | fix-nightly-test-red-loop\tthe record player is silent\tnow fix the nightly\t.config/pipewire/x.conf\t-\thand\n\
                     sid-2\tu\t-\t1\t/home/u/dotfiles\tmain\tsnapcast\tWhole house snapcast\tset up snapcast\t-\t-\t-\thand\n";
        let agents = [agent("hub/dotfiles:1", "sid-1", "dotfiles"), agent("hub/dotfiles:2", "sid-2", "dotfiles"), agent("lab/game:1", "sid-3", "game")];
        let rows = [
            Row { target: String::new(), text: "\t\x1b[1m━━━ dotfiles\x1b[0m (2)".into() },
            row("hub/dotfiles:1", " \x1b[32m✓\x1b[0m 56m dotfiles:1 fix-nightly-test-red-loop"),
            row("hub/dotfiles:2", " ✓ 2m dotfiles:2 snapcast"),
            Row { target: String::new(), text: "\t━━━ game (1)".into() },
            row("lab/game:1", " ✓ 1h game:1 dodge balls"),
        ];
        notes(&rows, &agents, &index_notes(index))
    }

    fn no_topics() -> HashMap<String, Vec<String>> {
        HashMap::new()
    }

    #[test]
    fn a_topic_word_finds_a_session_that_never_said_it() {
        // Neither session ever says "sound": sid-1 says "record player", sid-2 "snapcast".
        let t = topics("# comment\n\nsound snapcast record\nnetwork wifi\n");
        let notes = fixture();
        assert_eq!(targets(&filter(&notes, "sound", &t)), ["", "hub/dotfiles:1", "hub/dotfiles:2"]);
        assert_eq!(targets(&filter(&notes, "SOUND house", &t)), ["", "hub/dotfiles:2"]);
        // Negative controls: without the topic, "sound" is in no session; a topic with no
        // matching word matches nothing; a topic word does not stand for its topic.
        assert_eq!(filter(&notes, "sound", &no_topics()), "");
        assert_eq!(filter(&notes, "network", &t), "");
        assert_eq!(filter(&notes, "snapcast", &t), filter(&notes, "snapcast", &no_topics()));
        // A topic word matches at the start of a word only: "player" holds "aye" mid-word.
        let t = topics("vote aye");
        assert_eq!(filter(&notes, "vote", &t), "");
        assert!(starts_a_word("set up snapcast", "snap") && !starts_a_word("whole housesnap", "snap"));
    }

    #[test]
    fn the_cwd_adds_its_checkout_name_not_the_home_path() {
        assert_eq!(targets(&filter(&fixture(), "game", &no_topics())), ["", "lab/game:1"]);
        assert_eq!(filter(&fixture(), "home", &no_topics()), "");
    }

    fn targets(out: &str) -> Vec<&str> {
        out.lines().map(|l| l.split('\t').next().unwrap()).collect()
    }

    #[test]
    fn a_past_title_finds_the_agent_and_keeps_its_project_header() {
        let out = filter(&fixture(), "audio", &no_topics());
        assert_eq!(targets(&out), ["", "hub/dotfiles:1"], "{out}");
        assert!(out.lines().next().unwrap().contains("dotfiles"));
    }

    #[test]
    fn every_word_must_match_and_case_does_not_matter() {
        assert_eq!(targets(&filter(&fixture(), "SNAPCAST house", &no_topics())), ["", "hub/dotfiles:2"]);
        // Negative control: audio is in sid-1, snapcast in sid-2, never both in one session.
        assert_eq!(filter(&fixture(), "audio snapcast", &no_topics()), "");
        assert_eq!(filter(&fixture(), "zzzz-nothing", &no_topics()), "");
    }

    #[test]
    fn row_text_project_and_prompts_match_too() {
        assert_eq!(targets(&filter(&fixture(), "dodge", &no_topics())), ["", "lab/game:1"]);
        assert_eq!(targets(&filter(&fixture(), "record player", &no_topics())), ["", "hub/dotfiles:1"]);
        // An agent with no index row still matches on its project.
        assert_eq!(targets(&filter(&fixture(), "game", &no_topics())), ["", "lab/game:1"]);
    }

    #[test]
    fn an_exact_match_quote_is_dropped_and_an_empty_query_keeps_every_row() {
        assert_eq!(filter(&fixture(), "'dotfiles", &no_topics()), filter(&fixture(), "dotfiles", &no_topics()));
        assert_eq!(targets(&filter(&fixture(), "'dotfiles", &no_topics())), ["", "hub/dotfiles:1", "hub/dotfiles:2"]);
        assert_eq!(filter(&fixture(), "  ", &no_topics()).lines().count(), 5);
    }

    #[test]
    fn colour_escapes_are_not_searchable_text() {
        // "32m" is inside an escape on the row, not a word on it.
        assert_eq!(filter(&fixture(), "32m", &no_topics()), "");
    }
}
