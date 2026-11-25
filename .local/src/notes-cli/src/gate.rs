//! The intake gate (QUEUE.md "Admission"): on a gated project (`intake_gated` in the notes
//! config, agent-runtime by default) a session's row enters the board only as an evidenced fault,
//! a plan phase or the person's ask. The write carries the person's want (`--want`), or the row a `#why/<slug>` whose reason
//! is urgent or high in `priority-reasons.tsv` (a red, an outage, a runtime fault that happens now
//! or recurs). Anything else is an improvement, kept by `notes improve`, never a row dispatch can
//! pick. A plan's phases come through `agent-queue add --plan`, a direct filer, and a person's
//! own words are never gated, so neither reaches this check.

use crate::reasons::{self, Reason};
use anyhow::Result;

/// What `ptask add` and `ptask file` exit with when the gate refuses a row: nothing was written,
/// and the reason is on stderr. `agentctl-inbox-triage` keeps such a line as an improvement.
pub const EXIT_GATED: i32 = 6;

/// The reason levels that admit a row: the evidenced ones.
const ADMITS: [&str; 2] = ["urgent", "high"];

/// The reason a wanted row carries, which a session may not give itself.
const ASKED: &str = "requested";

/// Why `row` may not enter `project`'s board, or None when it may. `project` is the canonical
/// name (the project's directory); `wanted` is a `--want` on this write, the only form the
/// person's ask takes, since a `#requested` a session typed into its own row is no ask.
pub(crate) fn refusal(project: &str, row: &str, wanted: bool) -> Result<Option<String>> {
    let gated = crate::config::intake_gated();
    if !gated.iter().any(|g| g == project) {
        return Ok(None);
    }
    Ok(refusal_in(&reasons::load()?, project, row, wanted))
}

fn refusal_in(all: &[Reason], project: &str, row: &str, wanted: bool) -> Option<String> {
    if wanted || crate::epics::is_epic(row) {
        return None;
    }
    let evidence = |r: &&Reason| ADMITS.contains(&r.priority.as_str()) && r.slug != ASKED;
    let admitting: Vec<&str> = all
        .iter()
        .filter(evidence)
        .map(|r| r.slug.as_str())
        .collect();
    let why = match reasons::slug_of(row) {
        Some(s) if admitting.contains(&s.as_str()) => return None,
        Some(s) => format!("its reason #why/{s} is no evidenced fault"),
        None => "it names no reason".into(),
    };
    Some(format!(
        "{project} takes a session's row only as an evidenced fault, a plan phase or the person's ask (QUEUE.md \"Admission\"), and {why}: give the reason that names its evidence (--why {}), file a phase with `agent-queue add --plan`, pass the person's ask with --want, or keep it with `notes improve {project} -- \"<text>\"`, so nothing was added",
        admitting.join("|")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> Vec<Reason> {
        reasons::parse(include_str!(
            "../../../../.config/inbox-triage/rules/priority-reasons.tsv"
        ))
        .unwrap()
    }

    #[test]
    fn an_evidenced_fault_a_requested_row_and_an_epic_pass_and_polish_is_refused() {
        let r = |row: &str| refusal_in(&list(), "agent-runtime", row, false);
        for pass in [
            "- [ ] fix(dispatch): a reaped item restarts #high #why/runtime-fault",
            "- [ ] fix(ci): main is red #high #why/red-main",
            "- [ ] fix(views): the board is down #urgent #why/outage",
            "- [ ] epic(views): every tab reads hub-core",
        ] {
            assert_eq!(r(pass), None, "{pass}");
        }
        assert_eq!(
            refusal_in(
                &list(),
                "agent-runtime",
                "- [ ] feat(views): a chip #high",
                true
            ),
            None,
            "the person's want"
        );
        // NEGATIVE CONTROLS: a fault nobody is blocked by, polish, a feature, no reason at all, and
        // the person's ask claimed by a session's own tag or reason.
        for refused in [
            "- [ ] fix(dispatch): a log line says start twice #normal #why/fault",
            "- [ ] chore(views): tidy the chip colours #low #why/upkeep",
            "- [ ] feat(views): a sparkline on the KPI tab #normal #why/feature",
            "- [ ] feat(sessions): a new watch on idle panes #high",
            "- [ ] feat(views): a chip it tagged itself #high #requested",
            "- [ ] feat(views): a chip nobody asked for #high #why/requested",
        ] {
            let e = r(refused).unwrap_or_else(|| panic!("admitted: {refused}"));
            assert!(
                e.contains("evidenced fault")
                    && e.contains("runtime-fault")
                    && e.contains("notes improve agent-runtime"),
                "{e}"
            );
            assert!(
                !e.contains("|requested|") && !e.ends_with("|requested)"),
                "--want, not --why requested: {e}"
            );
        }
    }

    #[test]
    fn a_project_off_the_list_is_never_gated() {
        let row = "- [ ] chore(ui): tidy #low #why/upkeep";
        assert!(refusal_in(&list(), "agent-runtime", row, false).is_some());
        // refusal reads the configured list; with no config it is the default, agent-runtime only.
        assert_eq!(refusal("unity-core-playground", row, false).unwrap(), None);
    }
}
