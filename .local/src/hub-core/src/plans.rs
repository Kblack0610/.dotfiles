//! What a plan is called where a row names it: its `# ` heading's first clause, since a plan's
//! file name is the planner's random words (`can-we-backfill-entier-snuggly-bachman`). The
//! phases checklist itself is read by `.local/lib/plan-phases.sh` alone.

use std::collections::HashMap;
use std::path::Path;

use crate::text::cap;

/// The longest plan name a row shows.
pub const NAME_MAX: usize = 48;
/// A heading this far down the file is not the plan's title.
const HEAD_LINES: usize = 20;

/// The file name without its directory and `.md`.
pub fn base(path: &str) -> &str {
    let b = path.rsplit('/').next().unwrap_or(path);
    b.strip_suffix(".md").unwrap_or(b)
}

/// A subject before `: ` this long names the plan alone; a shorter one (`DodginBalls`) keeps
/// the words after it.
const SUBJECT_MIN: usize = 16;

/// The name from a plan's text: its first `# ` heading up to the first clause break (`, `,
/// `; `, ` (`, ` - `, or `: ` after a subject of `SUBJECT_MIN`), capped at `NAME_MAX`. None
/// when the top of the file has no heading.
pub fn name_of(text: &str) -> Option<String> {
    let mut fenced = false;
    let head = text
        .lines()
        .take(HEAD_LINES)
        .find_map(|l| {
            fenced ^= l.trim_start().starts_with("```");
            l.strip_prefix("# ").filter(|_| !fenced)
        })?
        .trim();
    let colon = head
        .find(": ")
        .filter(|i| head[..*i].chars().count() >= SUBJECT_MIN);
    let cut = [", ", "; ", " (", " - "]
        .iter()
        .filter_map(|b| head.find(b))
        .chain(colon)
        .min()
        .map_or(head, |i| &head[..i]);
    let cut = cut.trim();
    (!cut.is_empty()).then(|| cap(cut, NAME_MAX))
}

/// The label a phase's words lead with, as `P<n>`, and the words after it: `P9 live stage`,
/// `P2b. Split`, `Phase 5 Look: x`. None when they lead with none.
pub fn own_label(words: &str) -> Option<(String, &str)> {
    let rest = words
        .strip_prefix("Phase ")
        .or_else(|| words.strip_prefix('P'))?;
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 {
        return None;
    }
    let after = &rest[digits..];
    let letter = usize::from(after.starts_with(|c: char| c.is_ascii_lowercase()));
    let tail = after[letter..]
        .strip_prefix(['.', ':'])
        .unwrap_or(&after[letter..]);
    let tail = tail.strip_prefix(' ')?.trim_start();
    (!tail.is_empty()).then(|| (format!("P{}", &rest[..digits + letter]), tail))
}

/// A plan's file: `plan` itself when it is a path, else where the planner writes one by that
/// name (`ucp-145` in fleet-sessions' rows, `<plan file>` in an old title).
pub fn path(plan: &str) -> String {
    if plan.contains('/') {
        return plan.to_string();
    }
    format!(
        "{}/.claude/plans/{plan}.md",
        std::env::var("HOME").unwrap_or_default()
    )
}
/// The plan file, phase tag and words of a title `agent-queue add --plan` built before titles
/// were the phase's own words: `<plan-file> P4+5: <words>`. None for any other title.
pub fn legacy(title: &str) -> Option<(&str, &str, &str)> {
    let (base, rest) = title.split_once(' ')?;
    let (tag, words) = rest.split_once(": ")?;
    let nums = tag.strip_prefix('P')?;
    let numbered = !nums.is_empty()
        && nums
            .split('+')
            .all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
    let plain = base.contains('-') && !base.contains([':', '/']);
    (plain && numbered).then_some((base, tag, words.trim_start()))
}

/// The plan's name, else its file name when it cannot be read or has no heading.
pub fn name(path: &str) -> String {
    use std::io::BufRead;
    std::fs::File::open(Path::new(path))
        .ok()
        .map(|f| {
            let lines = std::io::BufReader::new(f).lines().take(HEAD_LINES);
            lines.map_while(Result::ok).collect::<Vec<_>>().join("\n")
        })
        .and_then(|t| name_of(&t))
        .unwrap_or_else(|| base(path).to_string())
}

/// `name`, each file read once however many rows name it.
#[derive(Default)]
pub struct Names(HashMap<String, String>);

impl Names {
    pub fn get(&mut self, path: &str) -> String {
        self.0
            .entry(path.to_string())
            .or_insert_with(|| name(path))
            .clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_name_is_the_headings_first_clause_and_a_file_without_one_keeps_its_file_name() {
        let n = |t: &str| name_of(t);
        assert_eq!(
            n("# Systems you can see, every task under a feature\n").as_deref(),
            Some("Systems you can see")
        );
        assert_eq!(
            n("# DodginBalls: school days, choices and the morality meter").as_deref(),
            Some("DodginBalls: school days")
        );
        assert_eq!(
            n("# DodginBalls champion barks, phase 1 (one-shot)").as_deref(),
            Some("DodginBalls champion barks")
        );
        assert_eq!(
            n("intro\n\n# ar-527: inbox-plan red a106c8bd").as_deref(),
            Some("ar-527: inbox-plan red a106c8bd")
        );
        assert_eq!(
            n("# Hub consolidation: one 7-tab layout for the hub TUI and agent-web").as_deref(),
            Some("Hub consolidation")
        );
        let long = n("# One layout for the hub TUI and agent-web and every phone that reads them")
            .unwrap();
        assert!(
            long.chars().count() <= NAME_MAX + 3 && long.ends_with("..."),
            "{long}"
        );
        assert_eq!(
            n("# Boards you can read: one source of truth").as_deref(),
            Some("Boards you can read")
        );
        assert_eq!(
            n("# Codex on par: full integration").as_deref(),
            Some("Codex on par: full integration")
        );
        assert_eq!(n("## Phases\n- [ ] one"), None);
        assert_eq!(
            n("```sh\n# run this first\n```\n# Real title, more").as_deref(),
            Some("Real title"),
            "a comment in a fence is not the heading"
        );
        assert_eq!(n("# , oops"), None);
        assert_eq!(name("/nonexistent/quiet-ocean.md"), "quiet-ocean");
    }

    #[test]
    fn a_legacy_title_splits_into_plan_file_tag_and_words() {
        assert_eq!(
            legacy("quiet-ocean P4+5: Fourth thing"),
            Some(("quiet-ocean", "P4+5", "Fourth thing"))
        );
        for other in [
            "DodginBalls: school days",
            "quiet-ocean P: x",
            "sc-bar-26: bots P2: x",
            "../x-y P2: z",
            "quiet-ocean P4 x",
            "solo P2: x",
        ] {
            assert_eq!(legacy(other), None, "{other}");
        }
    }

    #[test]
    fn a_phases_own_label_is_read_and_ordinary_words_are_not() {
        let l = |w: &str| own_label(w).map(|(a, b)| (a, b.to_string()));
        assert_eq!(l("P9 live stage"), Some(("P9".into(), "live stage".into())));
        assert_eq!(
            l("Phase 5 Look: halo"),
            Some(("P5".into(), "Look: halo".into()))
        );
        assert_eq!(
            l("P2b. Split the gate"),
            Some(("P2b".into(), "Split the gate".into()))
        );
        assert_eq!(l("P0: Close-out"), Some(("P0".into(), "Close-out".into())));
        for plain in [
            "Playtests the human can work",
            "PR body lines",
            "P5",
            "Phase one",
            "P12x3 grid",
        ] {
            assert_eq!(l(plain), None, "{plain}");
        }
    }
}
