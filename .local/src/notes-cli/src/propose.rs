//! The `type(area): title` an untyped row should carry. Deterministic, and it writes nothing:
//! `notes doctor --projects --untyped` lists these for review, and `agent-queue` types an item's
//! story row with them, because the agent board refuses untyped text (`ptask add`).

use anyhow::Result;

use crate::{config, md, projects};

/// A label that reads like a type and is not one.
const LABEL_TYPES: &[(&str, &str)] = &[
    ("art", "design"),
    ("bug", "fix"),
    ("deploy", "run"),
    ("investigate", "research"),
    ("verify", "check"),
];

/// A row's first word, when it says the kind of work.
const LEAD_TYPES: &[(&str, &str)] = &[
    ("add", "feat"),
    ("build", "feat"),
    ("create", "feat"),
    ("fix", "fix"),
    ("bump", "chore"),
    ("finish", "chore"),
    ("update", "chore"),
    ("move", "refactor"),
    ("rename", "refactor"),
    ("split", "refactor"),
    ("investigate", "research"),
    ("research", "research"),
    ("deploy", "run"),
    ("run", "run"),
    ("measure", "check"),
    ("re-measure", "check"),
    ("verify", "check"),
];

/// Words anywhere in a row that report a defect.
const DEFECT_WORDS: &[&str] = &[
    "broken", "crash", "crashes", "failing", "fails", "missing", "stuck",
];

/// The row a filer should write for `text` on `project`'s board, without tags: each filer sets
/// its own. Text already typed keeps its words, cut to the title limit like any other.
pub(crate) fn proposed_row(text: &str, project: &str) -> String {
    let words = bare_words(text);
    if let Some((ty, area, title)) = projects::row_prefix(&words) {
        return format!("{ty}({area}): {}", cut(title));
    }
    let (phase, rest) = plan_phase(&words);
    let rest = strip_bracket(rest);
    let (ty, area, title) = classify(rest, &default_area(project));
    let title = match phase {
        Some(phase) => format!("{phase}: {title}"),
        None => title.to_string(),
    };
    format!("{ty}({area}): {}", cut(&title))
}

/// `<profile>/<project> <TAB> <id, or line N> <TAB> <proposed row>` for each open agent-board
/// row with no type, in every profile. The human sheet takes free text, which triage rewrites.
pub fn untyped_report() -> Result<Vec<String>> {
    let mut out = Vec::new();
    for profile in config::all_profile_names()? {
        let Ok(p) = config::resolve(Some(&profile)) else {
            continue;
        };
        for (name, dir) in projects::indexed_dirs(&p) {
            let Ok(board) = std::fs::read_to_string(crate::agent_sheet::sheet_path(&dir)) else {
                continue;
            };
            for (row, proposal) in untyped_rows(&board, &name) {
                out.push(format!("{profile}/{name}\t{row}\t{proposal}"));
            }
        }
    }
    Ok(out)
}

/// Each open top-level row of `board` with no `type(area): ` prefix: its id (else its line), and
/// the row proposed for it.
fn untyped_rows(board: &str, project: &str) -> Vec<(String, String)> {
    board
        .lines()
        .enumerate()
        .filter(|(_, line)| {
            line.starts_with("- [")
                && md::is_open_task(line)
                && projects::row_type_area(line).is_none()
        })
        .map(|(i, line)| {
            let key =
                md::row_id(line).map_or_else(|| format!("line {}", i + 1), |id| id.to_string());
            (key, proposed_row(&md::task_text(line), project))
        })
        .collect()
}

/// `text` without stamps or tags. An issue ref (`#45`) is a word, not a tag, so it stays.
fn bare_words(text: &str) -> String {
    md::task_text(&format!("- [ ] {text}"))
        .split_whitespace()
        .filter(|w| md::find_hashtags(w).is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Split `<plan-slug> P8: P7 words` into the phase (`<plan-slug> P8`) and its words. The slug
/// stays on the row: `ask-sweep` greps the board for it to tell a tracked plan from a forgotten one.
fn plan_phase(text: &str) -> (Option<String>, &str) {
    let mut parts = text.splitn(3, ' ');
    let (Some(slug), Some(phase), Some(rest)) = (parts.next(), parts.next(), parts.next()) else {
        return (None, text);
    };
    let Some(phase) = phase.strip_suffix(':').filter(|p| is_phase(p)) else {
        return (None, text);
    };
    if !slug.contains('-') {
        return (None, text);
    }
    // Queue items repeat the phase name: `slug P8: P7 words`.
    let rest = match rest.split_once(' ') {
        Some((head, tail)) if is_phase(head.trim_end_matches(':')) => tail,
        _ => rest,
    };
    (Some(format!("{slug} {phase}")), rest)
}

/// `P3`, `P12`, `P5c`.
fn is_phase(word: &str) -> bool {
    let Some(tail) = word.strip_prefix('P') else {
        return false;
    };
    let digits = tail.trim_end_matches(|c: char| c.is_ascii_lowercase());
    !digits.is_empty()
        && digits.len() + 1 >= tail.len()
        && digits.bytes().all(|b| b.is_ascii_digit())
}

/// `[shape-city] art(store): words` -> `art(store): words`.
fn strip_bracket(text: &str) -> &str {
    text.strip_prefix('[')
        .and_then(|t| t.split_once("] "))
        .map_or(text, |(_, rest)| rest)
}

/// `(type, area, title)` for words with no well-formed prefix.
fn classify<'a>(text: &'a str, area: &str) -> (&'a str, String, &'a str) {
    if let Some((ty, a, title)) = projects::row_prefix(text) {
        return (ty, a.to_string(), title);
    }
    if let Some((label, title)) = text
        .split_once(": ")
        .filter(|(l, t)| !l.contains(' ') && !t.is_empty())
    {
        if let Some((word, a)) = label.strip_suffix(')').and_then(|l| l.split_once('(')) {
            if let Some(ty) = label_type(word) {
                return (ty, kebab(a).unwrap_or_else(|| area.to_string()), title);
            }
        } else if let Some(ty) = label_type(label) {
            return (ty, area.to_string(), title);
        } else if let Some(a) = kebab(label) {
            return (guess(title), a, title);
        }
    }
    (guess(text), area.to_string(), text)
}

/// The row type a label names: one of the types (an epic is the human's to file), or a near miss.
fn label_type(word: &str) -> Option<&'static str> {
    let word = word.to_lowercase();
    projects::ROW_TYPES
        .iter()
        .copied()
        .find(|t| *t == word && *t != "epic")
        .or_else(|| {
            LABEL_TYPES
                .iter()
                .find(|(w, _)| *w == word)
                .map(|(_, t)| *t)
        })
}

/// The type the words suggest; feature work when they suggest none.
fn guess(text: &str) -> &'static str {
    if text.ends_with('?') || text.contains("-> answered") {
        return "decide";
    }
    let lower = text.to_lowercase();
    let lead = lower.split_whitespace().next().unwrap_or("");
    if let Some((_, ty)) = LEAD_TYPES.iter().find(|(w, _)| *w == lead) {
        return ty;
    }
    let defect = lower
        .split(|c: char| !c.is_ascii_alphanumeric())
        .any(|w| DEFECT_WORDS.contains(&w));
    if defect {
        "fix"
    } else {
        "feat"
    }
}

/// A project's name as an area: `media_player_fleet` -> `media-player-fleet`.
fn default_area(project: &str) -> String {
    kebab(project).unwrap_or_else(|| "general".to_string())
}

/// `word` as the grammar's one lowercase kebab word, when it can be one.
fn kebab(word: &str) -> Option<String> {
    let w = word.to_lowercase().replace('_', "-");
    projects::is_area(&w).then_some(w)
}

/// `title` within the grammar's limit, cut at a word. The filer keeps the whole line: `edit --was`
/// as the row's `was:` detail, `agent-queue` as `--detail`.
fn cut(title: &str) -> String {
    if title.chars().count() <= projects::TITLE_MAX {
        return title.to_string();
    }
    let head: String = title.chars().take(projects::TITLE_MAX).collect();
    match head.rsplit_once(' ') {
        Some((h, _)) => h.to_string(),
        None => head,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_typed_row_comes_back_as_it_is() {
        assert_eq!(
            proposed_row("fix(audio): plays late #size/s #high", "game"),
            "fix(audio): plays late"
        );
    }

    #[test]
    fn every_proposal_passes_the_grammar_the_board_enforces() {
        for text in [
            "Hard hits ragdoll: phase of fists plan, a hard hit #size/m",
            "ci: bump webfactory/ssh-agent past v0.9.0",
            "[shape-city] art(store): a 1024x1024 source icon",
            "investigate(ci): aws-burst-1 unity slots fail mid-run",
            "Fleet:<runner> detail page for every runner",
            "provisionScript.brs: retry download with backoff",
            "Wall panels (panels.example.internal/wall,",
            "epic: not ours to file",
        ] {
            let row = proposed_row(text, "media_player_fleet");
            assert!(
                projects::row_type_area(&format!("- [ ] {row}")).is_some(),
                "{text} -> {row}"
            );
            assert!(!row.starts_with("epic("), "{row}");
        }
    }

    #[test]
    fn a_plan_phase_takes_its_type_and_keeps_its_slug() {
        assert_eq!(
            proposed_row(
                "plan-mode-moonbeam P2: P2 fix(fleet-sessions): a heavy child",
                "agent-runtime"
            ),
            "fix(fleet-sessions): plan-mode-moonbeam P2: a heavy child"
        );
        assert_eq!(
            proposed_row(
                "snug-cupcake P6: P5c Lesson delivery and budget",
                "agent-runtime"
            ),
            "feat(agent-runtime): snug-cupcake P6: Lesson delivery and budget"
        );
    }

    #[test]
    fn a_label_maps_to_a_type_or_an_area() {
        assert_eq!(
            proposed_row("verify(trader): the run", "t"),
            "check(trader): the run"
        );
        assert_eq!(
            proposed_row("deploy(trader): bump #45", "t"),
            "run(trader): bump #45"
        );
        assert_eq!(
            proposed_row("Research: Claude capacity", "ar"),
            "research(ar): Claude capacity"
        );
        assert_eq!(
            proposed_row("ui: focus rings missing on Chip", "pmp"),
            "fix(ui): focus rings missing on Chip"
        );
    }

    #[test]
    fn the_words_pick_the_type_and_a_row_with_no_signal_is_a_feature() {
        assert_eq!(
            proposed_row("Rename the chip?", "ar"),
            "decide(ar): Rename the chip?"
        );
        assert_eq!(
            proposed_row("Re-measure usage pass 3", "ar"),
            "check(ar): Re-measure usage pass 3"
        );
        assert_eq!(
            proposed_row("the sweep fails silently", "ar"),
            "fix(ar): the sweep fails silently"
        );
        assert_eq!(
            proposed_row("Score every runner", "ar"),
            "feat(ar): Score every runner"
        );
    }

    #[test]
    fn a_long_title_is_cut_at_a_word_within_the_limit_typed_or_not() {
        for text in [
            "word ".repeat(40),
            format!("fix(ui): {}", "word ".repeat(40)),
        ] {
            let row = proposed_row(&text, "ar");
            let title = projects::row_title(&format!("- [ ] {row}"));
            assert!(title.chars().count() <= projects::TITLE_MAX, "{row}");
            assert!(row.ends_with("word"), "{row}");
        }
    }

    #[test]
    fn only_open_untyped_rows_are_listed_with_their_id_or_line() {
        let board = "## Tasks\n\
            - [ ] fix(a): typed <!-- id:xy-1 -->\n\
            - [ ] bare words <!-- id:xy-2 -->\n\
            - [/] started words\n\
            - [x] done words <!-- pr:3 -->\n\
            \x20 - [ ] a child row\n";
        assert_eq!(
            untyped_rows(board, "ar"),
            vec![
                ("xy-2".to_string(), "feat(ar): bare words".to_string()),
                ("line 4".to_string(), "feat(ar): started words".to_string()),
            ]
        );
    }
}
