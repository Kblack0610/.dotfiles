//! Sweep a project sheet's `## Wave` roadmap: group tasks into waves by their `#vX.Y.Z` tag,
//! current wave first and the rest ascending, then apply the priority lanes inside each.
//!
//! The wave tag is the source of truth and the heading is swept output, exactly as the
//! priority tag relates to `### Urgent`. An untagged task inherits the wave it sits under.
//!
//! Two rules the lane sweep has no equivalent for. A task can never sit in a wave EARLIER
//! than the current one, so a tag naming a rolled version is pulled forward rather than
//! opening a section above the current wave that every reader would mistake for it. And
//! `#urgent` is legal only in the current wave, so a task moved out is rewritten to `#high`.

use crate::md;
use crate::projects;
use crate::sweep;
use crate::waves;

type V = (u32, u32, u32);

/// The lanes a wave offers. The current wave offers all three; a planned wave offers
/// everything below Urgent, because an Urgent lane there would be a drop target it is
/// illegal to drop into.
fn lanes_for(is_current: bool) -> &'static [sweep::Lane] {
    if is_current {
        &md::PRIORITIES
    } else {
        &md::PRIORITIES[1..]
    }
}

/// One rung of the wave ladder from `at`, in `dir` (`-1` sooner, `+1` later).
///
/// A ladder, not a ring. `PRIORITY_RING` wraps through the no-tag slot because every priority
/// is legal; wave steps are bounded on one side and open on the other. Going sooner CLAMPS at
/// `cur`, because a wave before the current one is the thing every reader would mistake for
/// the current one. Going later MINTS the next patch past the end, because the roadmap is
/// supposed to grow: that is how a pile becomes small waves.
pub(crate) fn step_wave(cur: V, ladder: &[V], at: V, dir: i32) -> Result<V, StepEnd> {
    if dir < 0 {
        if at <= cur {
            return Err(StepEnd::AtCurrent);
        }
        Ok(ladder
            .iter()
            .copied()
            .filter(|v| *v < at && *v >= cur)
            .max()
            .unwrap_or(cur))
    } else {
        match ladder.iter().copied().filter(|v| *v > at).min() {
            Some(v) => Ok(v),
            // Past the last planned wave: open the next patch above the highest wave on the
            // sheet, so `demote` on the last one still has somewhere to put the task.
            None => {
                let top = ladder.iter().copied().max().unwrap_or(cur).max(at);
                Ok((top.0, top.1, top.2 + 1))
            }
        }
    }
}

/// Why a wave step could not happen. Only one direction can fail.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StepEnd {
    /// Already in the current wave; there is nothing sooner.
    AtCurrent,
}

/// Retag `line` for wave `to`, returning the new line and a report when something was
/// rewritten beyond the tag itself.
pub(crate) fn retag_wave(line: &str, to: V, to_is_current: bool) -> (String, Option<String>) {
    let (stripped, _) = md::split_wave(line);
    let mut note = None;
    let stripped = if !to_is_current && md::task_priority(&stripped) == Some("#urgent") {
        note = Some(format!(
            "{}: #urgent -> #high (urgent is only legal in the current wave)",
            md::task_text(line)
        ));
        // Strip the priority by re-adding the one we want: `add_tag` no-ops on a duplicate,
        // so drop `#urgent` first and let the lane tag land in the same place.
        let cleared = md::strip_priority_tag(&stripped);
        md::add_tag(&cleared, "#high")
    } else {
        stripped
    };
    (
        md::add_tag(&stripped, &format!("#{}", waves::fmt(to))),
        note,
    )
}

/// Pure core: reorganize a project sheet's wave roadmap. Returns the new content and a
/// report of everything it moved, or `None` when the sheet is already in this shape.
///
/// Refuses (returns `None`) rather than guessing when the sheet declares no `Version:`, or
/// when any wave heading names no parseable version - a legacy `## Wave 1 - verify` must not
/// be renumbered into the roadmap.
pub(crate) fn sweep_sheet(content: &str) -> Option<(String, Vec<String>)> {
    let declared = projects::sheet_version(content)?;
    let secs = waves::sections(content);
    if secs.is_empty() || secs.iter().any(|s| s.version.is_none()) {
        return None;
    }
    let cur = waves::current_of(content, Some(declared))?.version?;

    let lines: Vec<&str> = content.lines().collect();
    let start = secs[0].start;
    let end = secs.last().map(|s| s.end).unwrap_or(lines.len());

    // Bucket every task by the wave it belongs to: its tag, else the section it sits in.
    let mut waves_seen: Vec<V> = secs.iter().filter_map(|s| s.version).collect();
    let mut buckets: Vec<(V, Vec<String>)> = Vec::new();
    let mut report: Vec<String> = Vec::new();

    let mut push = |buckets: &mut Vec<(V, Vec<String>)>, v: V, line: String| match buckets
        .iter_mut()
        .find(|(bv, _)| *bv == v)
    {
        Some((_, b)) => b.push(line),
        None => buckets.push((v, vec![line])),
    };

    for s in &secs {
        let sec_v = s.version.expect("checked above");
        for l in lines.iter().take(s.end).skip(s.start + 1) {
            // Blank lines and the generated `- [ ] ` placeholder are scaffold, not content:
            // the lane rebuild re-emits the placeholder itself, and tagging the one it
            // emitted last time would make every sweep differ from the one before it.
            if l.trim().is_empty() || md::is_empty_unchecked(l) {
                continue;
            }
            // Scaffold and prose inside a section stay with that section; the lane sweep
            // below decides what to do with them.
            let tagged = md::wave_tag(l).and_then(|t| waves::parse(t.trim_start_matches('#')));
            let mut want = tagged.unwrap_or(sec_v);
            if want < cur {
                report.push(format!(
                    "{}: pulled forward to {} (was {})",
                    md::task_text(l),
                    waves::fmt(cur),
                    waves::fmt(want)
                ));
                want = cur;
            }
            if !waves_seen.contains(&want) {
                waves_seen.push(want);
            }
            let (line, note) = if md::is_task(l) {
                retag_wave(l, want, want == cur)
            } else {
                ((*l).to_string(), None)
            };
            if let Some(n) = note {
                report.push(n);
            }
            push(&mut buckets, want, line);
        }
    }

    // Current wave first, then the roadmap ascending. Sorting plainly by version would put a
    // wave numbered BELOW the current one above it, and every reader takes the first section
    // as the current wave.
    waves_seen.sort_unstable();
    waves_seen.dedup();
    let ordered: Vec<V> = std::iter::once(cur)
        .chain(waves_seen.into_iter().filter(|v| *v != cur))
        .collect();

    let mut out: Vec<String> = lines[..start].iter().map(|l| (*l).to_string()).collect();
    for (i, v) in ordered.iter().enumerate() {
        if i > 0 {
            out.push(String::new());
        }
        let is_current = *v == cur;
        let heading = if is_current {
            waves::heading_current(&waves::fmt(*v))
        } else {
            waves::heading_planned(&waves::fmt(*v))
        };
        out.push(format!("## {heading}"));
        let body: Vec<String> = buckets
            .iter()
            .find(|(bv, _)| bv == v)
            .map(|(_, b)| b.clone())
            .unwrap_or_default();
        let refs: Vec<&str> = body.iter().map(String::as_str).collect();
        // Canonical tag order, applied once at the end: the wave retag above and the lane
        // inherit inside `rebuild` add tags at different points, so this is what stops the
        // same task being spelled two ways depending on how it got here.
        out.extend(
            sweep::rebuild_scaffolded(&refs, lanes_for(is_current))
                .iter()
                .map(|l| md::normalize_tags(l)),
        );
    }
    out.push(String::new());
    out.extend(lines[end..].iter().map(|l| (*l).to_string()));

    let mut joined = out.join("\n");
    if content.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    // Trailing blank lines accumulate otherwise: the roadmap's own blank separator plus
    // whatever followed the last section.
    while joined.contains("\n\n\n") {
        joined = joined.replace("\n\n\n", "\n\n");
    }
    (joined != content).then_some((joined, report))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHEET: &str = "\
# demo
Version: v0.12.1

## Wave: v0.12.1 (current)
- [ ] live one #high
- [x] done one <!-- pr:307 -->

## Wave: v0.12.2 (planned)
- [ ] next one
";

    fn sweep(c: &str) -> String {
        sweep_sheet(c).expect("sheet reorganizes").0
    }

    const CUR: V = (0, 12, 1);
    const LADDER: [V; 3] = [(0, 12, 1), (0, 12, 2), (0, 12, 4)];

    #[test]
    fn stepping_later_walks_the_ladder_it_finds_not_the_next_number() {
        // v0.12.3 does not exist on the sheet, so v0.12.2 steps to v0.12.4.
        assert_eq!(step_wave(CUR, &LADDER, (0, 12, 2), 1), Ok((0, 12, 4)));
        assert_eq!(step_wave(CUR, &LADDER, CUR, 1), Ok((0, 12, 2)));
    }

    #[test]
    fn stepping_later_past_the_last_wave_opens_the_next_patch() {
        assert_eq!(step_wave(CUR, &LADDER, (0, 12, 4), 1), Ok((0, 12, 5)));
        // and from a lone current wave, so a sheet with no roadmap can still grow one
        assert_eq!(step_wave(CUR, &[CUR], CUR, 1), Ok((0, 12, 2)));
    }

    #[test]
    fn stepping_sooner_walks_back_down_the_ladder() {
        assert_eq!(step_wave(CUR, &LADDER, (0, 12, 4), -1), Ok((0, 12, 2)));
        assert_eq!(step_wave(CUR, &LADDER, (0, 12, 2), -1), Ok(CUR));
    }

    // The clamp. A wave before the current one is exactly what every reader would mistake
    // for the current one, so the ladder is bounded on this side and says so.
    #[test]
    fn stepping_sooner_clamps_at_the_current_wave() {
        assert_eq!(step_wave(CUR, &LADDER, CUR, -1), Err(StepEnd::AtCurrent));
        // and a task somehow BELOW current cannot be walked further down either
        assert_eq!(
            step_wave(CUR, &LADDER, (0, 11, 0), -1),
            Err(StepEnd::AtCurrent)
        );
    }

    // A step never lands on a rolled version even if one is somehow still on the ladder.
    #[test]
    fn a_step_never_lands_before_the_current_wave() {
        let stale = [(0, 11, 0), (0, 12, 1), (0, 12, 2)];
        assert_eq!(step_wave(CUR, &stale, (0, 12, 2), -1), Ok(CUR));
    }

    #[test]
    fn tasks_get_their_section_version_as_a_tag() {
        let out = sweep(SHEET);
        assert!(out.contains("- [ ] live one #high #v0.12.1"), "{out}");
        // and an untagged one picks up the default on its way into a wave
        assert!(out.contains("- [ ] next one #high #v0.12.2"), "{out}");
    }

    // The tag must land before the marker or it leaks onto every board row.
    #[test]
    fn the_wave_tag_lands_before_a_trailing_marker() {
        let out = sweep(SHEET);
        assert!(
            out.contains("- [x] done one #v0.12.1 <!-- pr:307 -->"),
            "{out}"
        );
    }

    #[test]
    fn each_wave_gets_its_own_lanes_and_done_list() {
        let out = sweep(SHEET);
        let cur = out.split("## Wave: v0.12.2").next().unwrap();
        assert!(cur.contains("### Urgent") && cur.contains("### High"));
        assert!(cur.contains("### Done"), "done collects per wave:\n{out}");
        assert!(
            cur.find("done one").unwrap() > cur.find("### Done").unwrap(),
            "{out}"
        );
    }

    // A planned wave has no legal Urgent lane, so it must not render one.
    #[test]
    fn a_planned_wave_renders_no_urgent_lane() {
        let out = sweep(SHEET);
        let planned = out.split("## Wave: v0.12.2").nth(1).unwrap();
        assert!(!planned.contains("### Urgent"), "{out}");
        assert!(
            planned.contains("### High") && planned.contains("### Low"),
            "{out}"
        );
    }

    // THE catastrophic one: if the sweep leaves a section above the current wave, every
    // reader (board, ptask list, /wave) silently switches to work that has not started.
    #[test]
    fn the_declared_version_heads_the_roadmap_from_a_shuffled_sheet() {
        let shuffled = "\
# demo
Version: v0.12.1

## Wave: v0.12.2 (planned)
- [ ] later

## Wave: v0.12.1 (current)
- [ ] now
";
        let out = sweep(shuffled);
        let secs = waves::sections(&out);
        assert_eq!(
            secs[0].version,
            Some((0, 12, 1)),
            "current heads it:\n{out}"
        );
        assert_eq!(secs[1].version, Some((0, 12, 2)));
        assert!(secs[0].heading.contains("(current)"), "{out}");
    }

    #[test]
    fn a_tag_naming_a_rolled_version_is_pulled_forward_not_opened_above() {
        let stale = "# d\nVersion: v0.12.1\n\n## Wave: v0.12.1 (current)\n- [ ] stale #v0.11.0\n";
        let (out, report) = sweep_sheet(stale).unwrap();
        assert!(out.contains("- [ ] stale #high #v0.12.1"), "{out}");
        assert_eq!(
            waves::sections(&out).len(),
            1,
            "no section above current:\n{out}"
        );
        assert!(
            report.iter().any(|r| r.contains("pulled forward")),
            "{report:?}"
        );
    }

    #[test]
    fn urgent_is_demoted_when_a_task_sits_in_a_planned_wave() {
        let s =
            "# d\nVersion: v0.12.1\n\n## Wave: v0.12.1 (current)\n- [ ] fire #urgent #v0.12.2\n";
        let (out, report) = sweep_sheet(s).unwrap();
        assert!(out.contains("#high"), "demoted:\n{out}");
        assert!(!out.contains("#urgent"), "and not left urgent:\n{out}");
        assert!(
            report.iter().any(|r| r.contains("#urgent -> #high")),
            "{report:?}"
        );
    }

    #[test]
    fn urgent_survives_in_the_current_wave() {
        let s = "# d\nVersion: v0.12.1\n\n## Wave: v0.12.1 (current)\n- [ ] fire #urgent\n";
        let out = sweep(s);
        assert!(out.contains("- [ ] fire #urgent #v0.12.1"), "{out}");
    }

    // A sheet whose wave heading names no version cannot be renumbered safely.
    #[test]
    fn a_legacy_unversioned_wave_heading_is_refused() {
        let legacy = "# d\nVersion: v0.0.1\n\n## Wave 1 - verify\n- [ ] check it\n";
        assert!(sweep_sheet(legacy).is_none());
    }

    #[test]
    fn a_sheet_with_no_version_line_is_refused() {
        let no_ver = "# d\n\n## Wave: v0.1.0 (current)\n- [ ] a\n";
        assert!(sweep_sheet(no_ver).is_none());
    }

    // Byte-for-byte the output the nvim BufWritePre sweep produces for the same input
    // (markdown.lua sweep_waves), captured from a real headless run. The wave sweep exists
    // twice - once here, once in the editor - and this is the only thing that can catch them
    // drifting apart. Its sibling in `sweep` pins the `## Focus` half.
    #[test]
    fn golden_matches_the_nvim_wave_sweep() {
        let note = "# demo\nVersion: v0.12.1\n\n## Wave: v0.12.1 (current)\n\
- [ ] live one #high\n- [x] done one <!-- pr:307 -->\n- [ ] fire #urgent\n\
- [ ] wrapped task here\n      a continuation line\n- [ ] pushed out #v0.12.2\n\n\
## Wave: v0.12.2 (planned)\n- [ ] next one\n";
        let expected = "# demo\nVersion: v0.12.1\n\n## Wave: v0.12.1 (current)\n- [ ] \n\n\
### Urgent\n- [ ] fire #urgent #v0.12.1\n\n\
### High\n- [ ] live one #high #v0.12.1\n- [ ] wrapped task here #high #v0.12.1\n      a continuation line\n\n\
### Low\n\n---\n### Done\n- [x] done one #v0.12.1 <!-- pr:307 -->\n\n\
## Wave: v0.12.2 (planned)\n- [ ] \n\n\
### High\n- [ ] pushed out #high #v0.12.2\n- [ ] next one #high #v0.12.2\n\n\
### Low\n\n---\n### Done\n";
        assert_eq!(sweep(note), expected);
    }

    #[test]
    fn sweeping_a_swept_sheet_is_a_no_op() {
        let once = sweep(SHEET);
        assert!(sweep_sheet(&once).is_none(), "settles:\n{once}");
    }

    // Everything outside the roadmap is passed through untouched.
    #[test]
    fn content_around_the_roadmap_survives() {
        let s = format!("{SHEET}\n## Backlog\n- [ ] not a wave\n");
        let out = sweep(&s);
        assert!(out.contains("## Backlog\n- [ ] not a wave"), "{out}");
        assert!(out.starts_with("# demo\nVersion: v0.12.1\n"), "{out}");
    }

    // A proof marker is the evidence a task shipped; losing one loses the audit trail.
    #[test]
    fn every_proof_marker_survives_the_sweep() {
        let s = "# d\nVersion: v0.0.2\n\n## Wave: v0.0.2 (current)\n\
- [x] a <!-- pr:307 -->\n- [x] b <!-- pr:274,pr:156 -->\n- [ ] c <!-- ask:0ACTm8 -->\n";
        let out = sweep(s);
        for m in [
            "<!-- pr:307 -->",
            "<!-- pr:274,pr:156 -->",
            "<!-- ask:0ACTm8 -->",
        ] {
            assert!(out.contains(m), "lost {m}:\n{out}");
        }
    }
}
