//! The intake gate (QUEUE.md "Admission"): on a gated project (`intake_gated` in the notes
//! config, agent-runtime by default) a session's row enters the board only as an evidenced fault,
//! source-of-truth work, a plan phase or the person's ask. The write carries the person's want
//! (`--want`), or the row a `#why/<slug>` whose reason is urgent or high in `priority-reasons.tsv`
//! (a red, an outage, a runtime fault that happens now or recurs) or is `sot` (it removes a second
//! copy, a second reader or a gate with no number), or the row is health work as `notes improve --check` judges it (`improve::health_of`,
//! the one list, which `notes improve` itself refuses). Anything else is an improvement, kept by
//! `notes improve`, never a row dispatch can pick. A plan's phases come through `agent-queue add --plan`, a direct filer, and a person's
//! own words are never gated, so neither reaches this check. A phase's session that splits its
//! phase into rows files them as follow-ups, which do: one whose `#from/<id>` names a row a plan
//! filed and whose reason is a fault or epic work is that phase's pass and is admitted
//! ([`split_admits`]; ar-5824, where the rest pass of a split phase went to improvements as no
//! evidenced fault). Polish from the same session is still refused.
//!
//! The daily cap (`intake_daily_cap`, [`cap_refusal`]) is a separate test, on every row the gate
//! admits and every writer the gate never asks, and on every project's agent board, gated or not
//! (the human, 2026-11-25: "lets make sure rows dont come in aggressively"): a board takes at most
//! that many new agent rows a local day, whoever filed them. The person's `--want` and an urgent
//! `#why` pass it, except `quick-fault`, which ranks a row already on the board.

use crate::config::Profile;
use crate::ingest::{self, Event};
use crate::reasons::{self, Reason};
use anyhow::Result;

/// What `ptask add` and `ptask file` exit with when the gate refuses a row: nothing was written,
/// and the reason is on stderr. `agentctl-inbox-triage` keeps such a line as an improvement.
pub const EXIT_GATED: i32 = 6;

/// The reason levels that admit a row: the evidenced ones.
const ADMITS: [&str; 2] = ["urgent", "high"];

/// The reason a wanted row carries, which a session may not give itself.
const ASKED: &str = "requested";

/// The urgent reason a verify pass gives a row already on the board with `ptask tag --why` (a fault
/// pulled forward because it blocks landing or dispatch, answers a live red, or is a small fix;
/// ar-6307). It is no red or outage: a new row carrying it is refused, and it passes no cap.
const RANKED: &str = "quick-fault";

/// The reasons that admit a row at any level: the human's scope for the runtime board, source-of-truth
/// and efficiency work (delightful-leaf P4, ar-5605).
const SCOPE: [&str; 1] = ["sot"];

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
    // Health work is refused by `notes improve` (exit 3), so the board is its only home.
    if wanted || crate::epics::is_epic(row) || crate::improve::health_of(row).is_some() {
        return None;
    }
    let evidence = |r: &&Reason| {
        (ADMITS.contains(&r.priority.as_str()) && r.slug != ASKED && r.slug != RANKED)
            || SCOPE.contains(&r.slug.as_str())
    };
    let admitting: Vec<&str> = all
        .iter()
        .filter(evidence)
        .map(|r| r.slug.as_str())
        .collect();
    let why = match reasons::slug_of(row) {
        Some(s) if admitting.contains(&s.as_str()) => return None,
        Some(s) => format!("its reason #why/{s} is no evidenced fault or source-of-truth work"),
        None => "it names no reason".into(),
    };
    Some(format!(
        "{project} takes a session's row only as an evidenced fault, source-of-truth work, a plan phase or the person's ask (QUEUE.md \"Admission\"), and {why}: give the reason that names its evidence (--why {}), file a phase with `agent-queue add --plan`, pass the person's ask with --want, or keep it with `notes improve {project} -- \"<text>\"`, so nothing was added",
        admitting.join("|")
    ))
}

/// The reasons a plan phase's split is admitted at below high: its passes are the phase's own fault
/// or epic work, never a feature or polish the session thought of on the way (ar-5824 review).
const SPLIT: [&str; 2] = ["fault", "epic-turn"];

/// Whether `row`, filed for a session's follow-up `line`, is a pass of a plan phase the gate admits:
/// its reason is one of [`SPLIT`] and `line` is part of a plan phase ([`plan_phase`]).
pub(crate) fn split_admits(p: &Profile, line: &str, row: &str) -> bool {
    split_reason(row) && plan_phase(p, line)
}

/// Whether `row`'s `#why/` is one of [`SPLIT`].
fn split_reason(row: &str) -> bool {
    reasons::slug_of(row).is_some_and(|s| SPLIT.contains(&s.as_str()))
}

/// Whether a session's follow-up `line` is part of a plan phase: its `#from/<id>` names a row a
/// plan filed (`agent-queue add --plan`, recorded `added` with origin `plan`). A follow-up from any
/// other item, or with no `#from/`, is not. The tie is the record's, not the phase row's state: the
/// phase's session often lands before the sweep files its split.
fn plan_phase(p: &Profile, line: &str) -> bool {
    let Some(from) = crate::project_tasks::origin_item(line) else {
        return false;
    };
    let mark = format!("\"origin\":\"{}\"", crate::project_tasks::ORIGIN_PLAN);
    phase_of(&ingest::matching(p, |l| l.contains(&mark)), &from)
}

/// Whether `events` hold the `added` event of row `id` with origin `plan`.
fn phase_of(events: &[Event], id: &str) -> bool {
    events.iter().any(|e| {
        e.action == "added"
            && e.origin.as_deref() == Some(crate::project_tasks::ORIGIN_PLAN)
            && e.id.as_deref().is_some_and(|i| i.eq_ignore_ascii_case(id))
    })
}

/// The record's action for a row the cap turned away, which `notes ingest cap` and fleet-bench's
/// churn KPIs count. Not `refused`: the inbox page lists those for the person, and a row held by the
/// cap is no ask of theirs.
pub const CAPPED: &str = "capped";

/// The board an agent-lane intake event is about: where a row was added or capped, or where triage
/// filed it. Empty for any other event.
fn board_of(e: &Event) -> &str {
    match e.action.as_str() {
        "added" | CAPPED => &e.from,
        "filed" => &e.to,
        _ => "",
    }
}

/// Whether `e` is a new agent row the cap counts against `project`: a row a session, a plan or a
/// machine filer put on the board (`added`) or inbox-triage filed from the outbox (`filed`). Left
/// out: a story row (the board's copy of an item already started, `ingest::ORIGIN_STORY`), the
/// person's own add (no origin, writer `human`) and any `--want`, an epic, and a `dup`, which joins
/// an open row and so is no new one.
pub(crate) fn counts_toward_cap(e: &Event, project: &str) -> bool {
    let on_board = match e.action.as_str() {
        "added" => e.from == project,
        "filed" => e.to == project,
        _ => false,
    };
    on_board
        && e.lane == "agent"
        && e.want.is_none()
        && e.origin.as_deref() != Some(ingest::ORIGIN_STORY)
        && !(e.origin.is_none() && e.by == "human")
        && !crate::epics::is_epic(&e.text)
}

/// New agent rows `events` count against `project`.
fn admitted(events: &[Event], project: &str) -> usize {
    events
        .iter()
        .filter(|e| counts_toward_cap(e, project))
        .count()
}

/// Whether the cap lets `row` through whatever the day's count: the person's want, or a row whose
/// `#why` is an urgent reason (a red, an outage). `requested` is no reason a session may give itself,
/// and [`RANKED`] ranks a row already on the board, so neither lets a new one past the cap.
fn cap_exempt(all: &[Reason], row: &str, wanted: bool) -> bool {
    wanted
        || reasons::slug_of(row).is_some_and(|s| {
            all.iter().any(|r| {
                r.slug == s && r.slug != ASKED && r.slug != RANKED && r.priority == "urgent"
            })
        })
}

/// Why `project`'s board takes no more new rows today, or None when `taken` is under `cap`.
fn cap_why(project: &str, taken: usize, cap: usize) -> Option<String> {
    (taken >= cap).then(|| {
        format!(
            "{project} has taken its {cap} new agent rows for today ({taken} so far, intake_daily_cap in the notes config, QUEUE.md \"Admission\"): the person's words (--want) and an urgent red (--why with an urgent reason other than quick-fault) are never held, so keep this one with `notes improve {project} -- \"<text>\"` or file it again tomorrow, and nothing was added"
        )
    })
}

/// Why `row` may not be the next new agent row of `project`'s board today, or None when it may.
/// `pending` is the rows of the same write already counted, so a multi-row filing stops at the cap
/// too. A refusal is recorded as a [`CAPPED`] event, once a day for the same row. Never an error for a list of reasons that
/// cannot be read: the row is then not urgent, and the cap holds it.
pub(crate) fn cap_refusal(
    p: &Profile,
    project: &str,
    row: &str,
    wanted: bool,
    pending: usize,
) -> Result<Option<String>> {
    let cap = crate::config::intake_daily_cap() as usize;
    if cap == 0 || cap_exempt(&reasons::load().unwrap_or_default(), row, wanted) {
        return Ok(None);
    }
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let events = ingest::on_day(p, &today);
    let taken = admitted(&events, project) + pending;
    let why = cap_why(project, taken, cap);
    if let Some(w) = &why {
        // One event a row a day: fleet-bench tries its red again every pass, and each try is no new refusal.
        let text = crate::md::task_text(row);
        let held = |e: &Event| e.action == CAPPED && e.from == project && e.text == text;
        if !events.iter().any(held) {
            let mut ev = Event::new(CAPPED, project, "", &text);
            ev.lane = "agent".into();
            ev.why = Some(w.split(" (").next().unwrap_or_default().to_string());
            ingest::record(p, &ev);
        }
    }
    Ok(why)
}

/// One local day of a board's intake: what the cap admitted, what it turned away, and the cap.
#[derive(serde::Serialize, Debug, PartialEq)]
pub struct DayCap {
    pub date: String,
    pub project: String,
    pub cap: u32,
    pub admitted: usize,
    pub refused: usize,
}

/// The projects `notes ingest cap` lists: every gated one (agent-runtime always shows, even on a
/// quiet day), and any other whose board took or was refused a row in `events`.
fn capped_projects(events: &[Event]) -> Vec<String> {
    let mut out = crate::config::intake_gated();
    for e in events {
        let board = board_of(e);
        let capped = e.action == CAPPED && e.lane == "agent";
        if !board.is_empty() && (capped || counts_toward_cap(e, board)) {
            out.push(board.to_string());
        }
    }
    out.sort();
    out.dedup();
    out
}

/// `notes ingest cap`: the last `days` local days, oldest first and today last, of every project
/// with a board the cap touched: new agent rows admitted ([`counts_toward_cap`]) and rows the cap
/// refused ([`CAPPED`]). A day an ungated board did neither has no line.
pub fn cap_days(p: &Profile, days: i64) -> Vec<DayCap> {
    let events = ingest::recent(p, days.max(1));
    let projects = capped_projects(&events);
    let gated = crate::config::intake_gated();
    let today = chrono::Local::now().date_naive();
    let cap = crate::config::intake_daily_cap();
    let mut out = Vec::new();
    for back in (0..days.max(1)).rev() {
        let date = (today - chrono::Duration::days(back))
            .format("%Y-%m-%d")
            .to_string();
        let day: Vec<Event> = events
            .iter()
            .filter(|e| e.ts.starts_with(&date))
            .cloned()
            .collect();
        for project in projects.iter().cloned() {
            let refused = day
                .iter()
                .filter(|e| e.action == CAPPED && e.from == project)
                .count();
            let admitted = admitted(&day, &project);
            // A quiet day of an ungated board is no line; a gated one always is (agent-runtime's KPIs).
            if refused + admitted == 0 && !gated.contains(&project) {
                continue;
            }
            out.push(DayCap {
                refused,
                admitted,
                date: date.clone(),
                project,
                cap,
            });
        }
    }
    out
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
            // the human's scope: source-of-truth work at its own level (ar-5605)
            "- [ ] refactor(views): one reader for the budget, delete the copy #normal #why/sot",
            "- [ ] epic(views): every tab reads hub-core",
            // health work by `notes improve --check`, whatever its reason
            "- [ ] test(probe): add a regression test for the probe #normal #why/upkeep",
            "- [ ] fix(ci): the shard takes 40s over budget on a flaky ci run #normal",
        ] {
            assert_eq!(r(pass), None, "{pass}");
        }
        // the sot row passes on its reason, not as health work
        let sot = "- [ ] refactor(views): one reader for the budget, delete the copy #normal";
        assert!(crate::improve::health_of(sot).is_none() && r(sot).is_some());
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
            // a verify pass's rank for a row already on the board, never a new row's evidence
            "- [ ] fix(dispatch): a reaped item restarts #urgent #why/quick-fault",
        ] {
            let e = r(refused).unwrap_or_else(|| panic!("admitted: {refused}"));
            assert!(
                e.contains("evidenced fault")
                    && e.contains("runtime-fault")
                    && e.contains("|sot")
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

    #[test]
    fn a_follow_up_from_a_plan_filed_row_is_a_plan_phase_and_one_from_any_other_is_not() {
        let added = |id: &str, origin: Option<&str>| {
            let mut e = Event::new("added", "agent-runtime", "", "feat(x): P3 focus passes");
            e.id = Some(id.into());
            e.origin = origin.map(str::to_string);
            e
        };
        let events = [
            added("ar-5604", Some("plan")),
            added("ar-5773", Some("agent-queue")),
            added("ar-9", None),
        ];
        assert!(
            phase_of(&events, "ar-5604"),
            "the row a plan filed (ar-5824)"
        );
        assert!(phase_of(&events, "AR-5604"));
        // NEGATIVE CONTROLS: a row another writer filed, one with no origin, one not in the record.
        for id in ["ar-5773", "ar-9", "ar-1"] {
            assert!(!phase_of(&events, id), "{id}");
        }
        // The line's tie is its `#from/`; a line with none ties to no row.
        assert_eq!(
            crate::project_tasks::origin_item(
                "#agent #from/ar-5604 fix(rest): focus pass, views, skills and the rest #normal"
            )
            .as_deref(),
            Some("ar-5604")
        );
        assert_eq!(
            crate::project_tasks::origin_item("fix(rest): focus pass #normal"),
            None
        );
        // A pass of the phase is its fault or epic work; polish or a feature from it is not.
        assert!(split_reason(
            "fix(views): focus pass over the 43 views rows #normal #why/fault"
        ));
        assert!(split_reason(
            "feat(x): the next step #normal #why/epic-turn"
        ));
        for row in [
            "chore(ui): a nicer empty state #low #why/upkeep",
            "feat(ui): a new view #normal #why/feature",
            "fix(ui): no reason #normal",
        ] {
            assert!(!split_reason(row), "{row}");
        }
    }

    fn ev(action: &str, from: &str, to: &str, text: &str) -> Event {
        let mut e = Event::new(action, from, to, text);
        e.lane = "agent".into();
        e.by = "fleet-bench".into();
        e
    }

    #[test]
    fn the_cap_counts_a_new_agent_row_and_leaves_out_what_is_no_new_row() {
        let c = |e: &Event| counts_toward_cap(e, "agent-runtime");
        let row = "- [ ] fix(views): a chip is wrong #size/s";
        assert!(c(&ev("added", "agent-runtime", "", row)));
        assert!(c(&ev("filed", "", "agent-runtime", row)), "triage's filing");
        // NEGATIVE CONTROLS: another board, a join (dup), a refusal, the person's want and own add,
        // a story row, an epic and a human-lane row are no new agent row of this board.
        assert!(!c(&ev("added", "other", "", row)));
        assert!(!c(&ev("filed", "", "other", row)));
        assert!(!c(&ev("dup", "agent-runtime", "", row)));
        assert!(!c(&ev(CAPPED, "agent-runtime", "", row)));
        let mut want = ev("added", "agent-runtime", "", row);
        want.want = Some("human".into());
        assert!(!c(&want));
        let mut own = ev("added", "agent-runtime", "", row);
        own.by = "human".into();
        assert!(!c(&own));
        let mut story = ev("added", "agent-runtime", "", row);
        story.origin = Some(ingest::ORIGIN_STORY.into());
        assert!(!c(&story));
        assert!(!c(&ev(
            "added",
            "agent-runtime",
            "",
            "- [ ] epic(views): every tab reads hub-core"
        )));
        let mut human_lane = ev("added", "agent-runtime", "", row);
        human_lane.lane = "human".into();
        assert!(!c(&human_lane));
        assert_eq!(
            admitted(
                &[ev("added", "agent-runtime", "", row), story],
                "agent-runtime"
            ),
            1
        );
    }

    #[test]
    fn the_cap_lists_every_board_that_took_or_was_refused_a_row_and_agent_runtime_always() {
        let row = "- [ ] fix(views): a chip is wrong #size/s";
        let mut story = ev("added", "story-only", "", row);
        story.origin = Some(ingest::ORIGIN_STORY.into());
        let events = [
            ev("added", "unity-core-playground", "", row),
            ev("filed", "", "demo", row),
            ev(CAPPED, "held-board", "", row),
            ev("dup", "dup-only", "", row),
            story,
        ];
        // with no config the gated list is agent-runtime alone
        assert_eq!(
            capped_projects(&events),
            [
                "agent-runtime",
                "demo",
                "held-board",
                "unity-core-playground"
            ]
        );
        assert_eq!(capped_projects(&[]), ["agent-runtime"]);
    }

    #[test]
    fn the_person_and_an_urgent_red_pass_the_cap_and_a_high_reason_or_requested_does_not() {
        let r = list();
        assert!(cap_exempt(&r, "- [ ] fix(a): b #why/outage", false));
        assert!(
            cap_exempt(&r, "- [ ] fix(a): b #normal", true),
            "the person's want"
        );
        // NEGATIVE CONTROLS
        for row in [
            "- [ ] fix(a): b #why/red-main",
            "- [ ] fix(a): b #why/runtime-fault",
            "- [ ] fix(a): b #why/requested",
            "- [ ] fix(a): b #urgent #why/quick-fault",
            "- [ ] fix(a): b #urgent",
            "- [ ] fix(a): b",
        ] {
            assert!(!cap_exempt(&r, row, false), "{row}");
        }
    }

    #[test]
    fn the_cap_holds_the_row_at_the_cap_and_not_before_and_names_it() {
        assert_eq!(cap_why("agent-runtime", 9, 10), None);
        let w = cap_why("agent-runtime", 10, 10).expect("row 11 is held");
        assert!(
            w.contains("10 new agent rows") && w.contains("intake_daily_cap"),
            "{w}"
        );
        assert!(w.contains("notes improve agent-runtime"), "{w}");
    }
}
