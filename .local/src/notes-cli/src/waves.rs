//! `## Wave` sections on a project sheet — the ONE parser and the ONE minter of the
//! heading format, shared by `projects` (roll) and `project_tasks` (ptask).
//!
//! A sheet carries a ROADMAP. The FIRST `## Wave …` section is the CURRENT wave — the one
//! `/wave` runs, the one `notes board` shows, the one `roll` freezes. Every `## Wave …`
//! after it is PLANNED: the road forward, held in ascending version order.
//!
//! ```markdown
//! # myapp
//! Version: v1.13.0
//!
//! ## Wave: v1.13.0 (current)
//! - [ ] full flow e2e
//!
//! ## Wave: v1.14.0 (planned)
//! - [ ] android: sweep remaining screens
//! ```
//!
//! Planned waves are structurally invisible to every reader that predates them.
//! `md::section_span` ends at the next `## `, and CURRENT is defined by POSITION (first),
//! not by the `(current)` suffix — which is how `notes ptask list`, `notes board`, `/wave`
//! and the cockpit keep seeing exactly the current wave and nothing else, unchanged.
//! Anything that writes a planned section must therefore keep it BELOW the current one;
//! `insert_planned` is the only sanctioned way to do that.

use crate::md;

/// The `## Wave` heading TEXT for the CURRENT version — the ONE place that format is
/// written.
///
/// There used to be two minters. `projects::sheet_body` seeded a fresh sheet with the
/// version; `project_tasks::ensure_task_sheet` hardcoded the literal string `new` when
/// appending a wave to a sheet that had none. So which id a wave got depended on which
/// code path created it, and notes-cockpit sat on `## Wave: new (current)` under
/// `Version: v0.0.2` until 2026-08-04 — the half of "the version is the wave's ONLY id"
/// (2026-07-28) that never landed. Every caller now routes through here.
pub(crate) fn heading_current(ver: &str) -> String {
    format!("Wave: {ver} (current)")
}

/// The `## Wave` heading TEXT for a PLANNED version — the roadmap forward.
pub(crate) fn heading_planned(ver: &str) -> String {
    format!("Wave: {ver} (planned)")
}

/// One `## Wave …` section, located by line index.
#[derive(Debug, Clone)]
pub(crate) struct Section {
    /// The heading TEXT (`Wave: v1.13.0 (current)`) — what `md::section_span` matches.
    pub heading: String,
    /// The version the heading names, when it names one parseably.
    pub version: Option<(u32, u32, u32)>,
    /// Index of the `## …` heading line itself.
    pub start: usize,
    /// Exclusive end: the first line NOT in this section.
    pub end: usize,
}

impl Section {
    /// The version as it is written (`v1.13.0`), else the raw heading — for messages.
    pub fn label(&self) -> String {
        self.version.map_or_else(|| self.heading.clone(), fmt)
    }
}

/// A `## Wave …` heading line -> its heading TEXT. `None` for any other line.
fn heading_text(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("## ")?;
    rest.trim_start().starts_with("Wave").then(|| rest.trim())
}

/// The first `vX.Y.Z` token in a heading (`Wave: v1.13.0 (current)` -> `(1,13,0)`).
fn version_in(heading: &str) -> Option<(u32, u32, u32)> {
    heading
        .split(|c: char| c.is_whitespace() || c == ':')
        .find_map(|t| parse(t.trim_matches(|c| c == '(' || c == ')')))
}

/// Parse `vX.Y.Z`. Kept here rather than borrowed from `projects` so the two modules that
/// need it do not have to depend on each other.
pub(crate) fn parse(s: &str) -> Option<(u32, u32, u32)> {
    let rest = s.strip_prefix('v')?;
    let mut it = rest.split('.');
    let v = (
        it.next()?.parse().ok()?,
        it.next()?.parse().ok()?,
        it.next()?.parse().ok()?,
    );
    it.next().is_none().then_some(v)
}

pub(crate) fn fmt(v: (u32, u32, u32)) -> String {
    format!("v{}.{}.{}", v.0, v.1, v.2)
}

/// Every `## Wave …` section on a sheet, in file order — `[0]` is the current wave.
///
/// The scan STOPS at the first `## ` heading that is not a Wave (and at a
/// [`md::ROLLUP_START`] sentinel, matching `md::section_span`'s boundary rule). So a
/// `## Backlog` written below the waves — and everything under it — is left alone, and
/// a wave heading that somehow appears after it is not mistaken for part of the roadmap.
pub(crate) fn sections(content: &str) -> Vec<Section> {
    let lines: Vec<&str> = content.lines().collect();
    let Some(first) = lines.iter().position(|l| heading_text(l).is_some()) else {
        return Vec::new();
    };
    let mut out: Vec<Section> = Vec::new();
    for (i, l) in lines.iter().enumerate().skip(first) {
        if l.trim() == md::ROLLUP_START {
            break;
        }
        if !l.starts_with("## ") {
            continue;
        }
        let Some(h) = heading_text(l) else { break }; // a non-Wave H2 ends the roadmap
        if let Some(prev) = out.last_mut() {
            prev.end = i;
        }
        out.push(Section {
            heading: h.to_string(),
            version: version_in(h),
            start: i,
            end: lines.len(),
        });
    }
    // The last section runs to the roadmap's end: the sentinel / the first non-Wave H2 /
    // EOF, whichever the loop stopped on.
    if let Some(last) = out.last_mut() {
        let stop = lines
            .iter()
            .enumerate()
            .skip(last.start + 1)
            .find(|(_, l)| l.starts_with("## ") || l.trim() == md::ROLLUP_START)
            .map_or(lines.len(), |(i, _)| i);
        last.end = stop;
    }
    out
}

/// The section naming `ver`, current or planned.
pub(crate) fn find(content: &str, ver: (u32, u32, u32)) -> Option<Section> {
    sections(content).into_iter().find(|s| s.version == Some(ver))
}

/// The CURRENT wave: the section naming the sheet's declared `Version:`, falling back to the
/// first section when the sheet declares none (a `tasks.md` sheet).
///
/// A sweep that reorders sections cannot use position to decide which section goes first
/// without arguing in a circle, so it sorts by `Version:` instead - the sheet's own
/// declaration of the open version, and already what `roll` reads.
///
/// Invariant the two definitions share, restored by the sweep and checked by `doctor`:
/// `sections(content)[0].version == sheet_version(content)`. Readers keep using position.
pub(crate) fn current_of(content: &str, declared: Option<(u32, u32, u32)>) -> Option<Section> {
    match declared {
        Some(v) => find(content, v).or_else(|| sections(content).into_iter().next()),
        None => sections(content).into_iter().next(),
    }
}

/// Insert an empty PLANNED wave for `ver`, in ascending version order among the planned
/// sections and always BELOW the current wave. Returns the new content.
///
/// Position is the invariant the whole design rests on: every pre-existing reader takes
/// the first `## Wave` as the current one, so a planned section that lands above it would
/// silently redirect `ptask`, `board` and `/wave` onto work that has not started. Hence
/// one function that can only ever append downward.
pub(crate) fn insert_planned(content: &str, ver: (u32, u32, u32)) -> String {
    let secs = sections(content);
    let block = format!("## {}\n- [ ] \n", heading_planned(&fmt(ver)));
    let mut lines: Vec<String> = content.lines().map(str::to_string).collect();

    // Where it goes: before the first planned wave with a HIGHER version; else after the
    // last wave section. Index 0 (the current wave) is never a candidate.
    let at = secs
        .iter()
        .skip(1)
        .find(|s| s.version.is_some_and(|v| v > ver))
        .map_or_else(|| secs.last().map_or(lines.len(), |s| s.end), |s| s.start);

    // Keep one blank line between sections, without accumulating them.
    let mut insert: Vec<String> = Vec::new();
    if at > 0 && !lines[at - 1].trim().is_empty() {
        insert.push(String::new());
    }
    insert.extend(block.lines().map(str::to_string));
    if at < lines.len() && !lines[at].trim().is_empty() {
        insert.push(String::new());
    }
    for (k, l) in insert.into_iter().enumerate() {
        lines.insert(at + k, l);
    }
    format!("{}\n", lines.join("\n"))
}

/// Cut a section's lines out of a sheet, returning `(remaining_content, cut_lines)`.
/// The heading line is included in the cut. Used by `roll` (freeze the current wave) and
/// by `ptask move` is NOT — that one moves a single task, not a section.
pub(crate) fn cut(content: &str, s: &Section) -> (String, Vec<String>) {
    let lines: Vec<&str> = content.lines().collect();
    let cut: Vec<String> = lines[s.start..s.end].iter().map(|l| (*l).to_string()).collect();
    let mut kept: Vec<String> = Vec::new();
    kept.extend(lines[..s.start].iter().map(|l| (*l).to_string()));
    kept.extend(lines[s.end..].iter().map(|l| (*l).to_string()));
    (format!("{}\n", kept.join("\n")), cut)
}

/// The open (`- [ ]` / `- [/]`, non-empty) task lines in a section.
pub(crate) fn open_tasks(content: &str, s: &Section) -> Vec<String> {
    content
        .lines()
        .skip(s.start + 1)
        .take(s.end.saturating_sub(s.start + 1))
        .filter(|l| md::is_open_task(l))
        .map(|l| l.trim_end().to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROADMAP: &str = "\
# demo
Version: v1.13.0

## Wave: v1.13.0 (current)
- [ ] live one
- [x] done one

## Wave: v1.14.0 (planned)
- [ ] next one

## Wave: v1.16.0 (planned)
- [ ] later one

## Backlog
- [ ] not a wave
";

    #[test]
    fn the_first_wave_is_current_and_the_rest_are_the_roadmap() {
        let s = sections(ROADMAP);
        assert_eq!(s.len(), 3, "three wave sections, not the Backlog");
        assert_eq!(s[0].version, Some((1, 13, 0)));
        assert_eq!(s[1].version, Some((1, 14, 0)));
        assert_eq!(s[2].version, Some((1, 16, 0)));
    }

    // The boundary that keeps a `## Backlog` (and anything under it) out of the roadmap.
    #[test]
    fn a_non_wave_heading_ends_the_roadmap() {
        let s = sections(ROADMAP);
        let last = s.last().unwrap();
        let lines: Vec<&str> = ROADMAP.lines().collect();
        assert_eq!(lines[last.end], "## Backlog");
        assert!(!open_tasks(ROADMAP, last).iter().any(|t| t.contains("not a wave")));
    }

    #[test]
    fn open_tasks_skips_the_checked_and_the_empty() {
        let s = sections(ROADMAP);
        assert_eq!(open_tasks(ROADMAP, &s[0]), vec!["- [ ] live one"]);
    }

    // A planned wave must land in version order and NEVER above the current one — if it
    // did, every existing reader (ptask/board/wave, all of which take the first `## Wave`)
    // would silently switch to work that has not started.
    #[test]
    fn a_planned_wave_lands_in_order_and_never_first() {
        let out = insert_planned(ROADMAP, (1, 15, 0));
        let s = sections(&out);
        let got: Vec<_> = s.iter().map(|x| x.version.unwrap()).collect();
        assert_eq!(
            got,
            vec![(1, 13, 0), (1, 14, 0), (1, 15, 0), (1, 16, 0)],
            "v1.15.0 belongs between v1.14.0 and v1.16.0:\n{out}"
        );
        assert!(s[0].heading.contains("(current)"), "the current wave stays first");
    }

    // Negative control for the same invariant from the other end: a planned version LOWER
    // than the current one still cannot displace it.
    #[test]
    fn a_lower_planned_version_still_lands_below_the_current_wave() {
        let out = insert_planned(ROADMAP, (1, 0, 0));
        let s = sections(&out);
        assert_eq!(s[0].version, Some((1, 13, 0)), "current wave first:\n{out}");
        assert_eq!(s[1].version, Some((1, 0, 0)));
    }

    #[test]
    fn insert_into_a_sheet_with_only_a_current_wave() {
        let sheet = "# d\nVersion: v0.1.0\n\n## Wave: v0.1.0 (current)\n- [ ] a\n";
        let out = insert_planned(sheet, (0, 2, 0));
        assert!(out.contains("## Wave: v0.2.0 (planned)"), "{out}");
        let s = sections(&out);
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].version, Some((0, 1, 0)));
    }

    #[test]
    fn cut_removes_exactly_the_section() {
        let s = sections(ROADMAP);
        let (kept, taken) = cut(ROADMAP, &s[1]);
        assert!(taken.iter().any(|l| l.contains("next one")));
        assert!(!kept.contains("v1.14.0"), "{kept}");
        assert!(kept.contains("v1.13.0") && kept.contains("v1.16.0"));
        assert!(kept.contains("## Backlog"));
    }

    #[test]
    fn version_parsing_round_trips_and_rejects_junk() {
        assert_eq!(parse("v1.13.0"), Some((1, 13, 0)));
        assert_eq!(parse("1.13.0"), None);
        assert_eq!(parse("v1.13"), None);
        assert_eq!(parse("v1.13.0.1"), None);
        assert_eq!(version_in("Wave: v1.13.0 (current)"), Some((1, 13, 0)));
        assert_eq!(version_in("Wave: new (current)"), None);
    }

    #[test]
    fn a_sheet_with_no_waves_has_no_sections() {
        assert!(sections("# x\n\n## Notes\n- [ ] a\n").is_empty());
    }
}
