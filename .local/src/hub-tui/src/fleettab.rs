//! Sessions' Runners inner tab: one table of the runners that work on their own (agentctl's
//! lanes), by tier, under the legend of what each kind means, from hub-core's `fleet` (the same
//! reader as agent-web's Runners). The sessions are the Sessions inner tab's (controls.rs); the
//! Claude accounts and the token folds are the Costs tab's (coststab.rs, tokens.rs). Named apart
//! from `fleet.rs`, which is the sessions' watch page. One runner's page (`runner_page`) is
//! hub-core's `fleet::runner`, as agent-web's `#sessions/runners/<runner>`.

use hub_core::boards::Due;
use hub_core::fleet::runner::{self, Extras, Runner, Totals};
use hub_core::fleet::who::Who;
use hub_core::fleet::{AskVerdict, Dispatch, Eval, Fleet, Judge, Registry, ASK_FILTERS};
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, len, wrap, Table};
use crate::fmt::{clock, dur, kilo, older, pct, Palette};
use hub_core::layout::FOLD_ROWS;

fn usd(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("${v:.2}"))
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

/// The rows as shown: the table's query, state and sort applied. j/k step through these and
/// Enter opens the one selected.
pub fn shown<'a>(f: &'a Fleet, t: &DataTable) -> Vec<&'a Who> {
    t.view.apply(&f.who)
}

/// The Runners inner tab: the table of runners, the row j/k picked (`t.sel`) drawn reversed:
/// Enter opens its page. Also the line that row is on, counted past every line above it (the
/// errors, the heading, the legend and the chips, each as wrapped), so the app keeps it in view.
pub fn page(
    f: &Fleet,
    t: &DataTable,
    p: Palette,
    now: i64,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = vec![];
    for e in &f.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let rows = shown(f, t);
    out.push(clip_line(
        heading(
            "RUNNERS",
            format!(
                "  {} of {} rows, {}",
                rows.len(),
                f.who.len(),
                hub_core::costs::spend_badge()
            ),
            p,
        ),
        w,
    ));
    for l in wrap(&f.legend, " | ", w) {
        out.push(clip_line(Line::styled(l, p.dim()), w));
    }
    out.extend(wrap_spans(t.status(&f.who, p), w));
    // The table's head is its first line; the selected row is under it.
    let sel = (!rows.is_empty()).then(|| out.len() + 1 + t.sel.min(rows.len() - 1));
    out.extend(who_table(&rows, t, p, now, w, f.who.is_empty()));
    (out, sel)
}

/// The chip line broken between chips so every chip shows in a narrow pane; a chip's own
/// leading gap is dropped where a line starts.
fn wrap_spans(spans: Vec<Span<'static>>, w: usize) -> Vec<Line<'static>> {
    let mut lines: Vec<Vec<Span<'static>>> = vec![vec![]];
    let mut used = 0;
    for sp in spans {
        let n = len(&sp.content);
        if used > 0 && used + n > w {
            lines.push(vec![]);
            used = 0;
        }
        let sp = if used == 0 {
            Span::styled(sp.content.trim_start().to_string(), sp.style)
        } else {
            sp
        };
        used += len(&sp.content);
        lines.last_mut().unwrap().push(sp);
    }
    lines
        .into_iter()
        .map(|l| clip_line(Line::from(l), w))
        .collect()
}

/// `Who::COLUMNS` in capitals, in its order: the sort mark is placed by that index.
const WHO_HEADER: [&str; 8] = [
    "KIND", "WHO", "STATE", "COST 24H", "SINCE", "FOR", "DOING", "UNDER",
];

fn who_table(
    rows: &[&Who],
    t: &DataTable,
    p: Palette,
    now: i64,
    w: usize,
    none_at_all: bool,
) -> Vec<Line<'static>> {
    if rows.is_empty() {
        return vec![Line::styled(
            if none_at_all {
                "No runners configured in ~/.config/agentctl/agents."
            } else {
                "No runner matches (/ query, f state, x clears)."
            },
            p.dim(),
        )];
    }
    let cells = rows
        .iter()
        .map(|r| {
            let state = match r.state.as_str() {
                "failed" | "held" => p.bad(),
                "needs you" | "stalled" => p.warn(),
                "working" => p.good(),
                _ => p.dim(),
            };
            vec![
                cell(r.kind.clone(), p.dim()),
                cell(r.who.clone(), p.head()),
                cell(r.state.clone(), state),
                format!(
                    "{}{}",
                    if r.cost_estimated { "~" } else { "" },
                    usd(r.cost_24h)
                )
                .into(),
                r.since.map_or("-".into(), |s| dur((now - s) as f64)).into(),
                r.purpose.clone().into(),
                r.doing.clone().into(),
                cell(r.under.clone(), p.dim()),
            ]
        })
        .collect();
    let mut out = Table {
        header: WHO_HEADER.to_vec(),
        rows: cells,
        // FOR, capped, keeps its place beside WHO; DOING is the flex column and takes the rest.
        keep: vec![1, 0, 2, 3, 5, 6, 4, 7],
        flex: Some(6),
        flexmin: 12,
        right: vec![3, 4],
        cap: vec![(1, 18), (5, 40), (7, 22)],
        mark: t.mark::<Who>(),
        ..Default::default()
    }
    .fit(w, p.head());
    // A re-read can leave fewer rows than the selection until the next key.
    if let Some(l) = out.get_mut(t.sel.min(rows.len() - 1) + 1) {
        l.style = p.sel();
    }
    out
}

/// Sessions' Shepherd inner tab: `fleet-shepherd`'s ledger, who holds the pass lease and when it
/// took it, then each line due with its role, how long it has waited, and whether the last pass
/// left it unhandled. The pass's rundowns are Log's Rundowns.
pub fn shepherd_page(d: &Due, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let lease = match (&d.lease_holder, d.lease_at) {
        (Some(h), Some(at)) => format!("lease {h}, taken {} ago", dur((now - at as i64) as f64)),
        (Some(h), None) => format!("lease {h}"),
        _ => "no pass holds the lease".into(),
    };
    let mut out = vec![clip_line(
        heading("SHEPHERD", format!("  {} due, {lease}", d.due.len()), p),
        w,
    )];
    if d.due.is_empty() {
        out.push(Line::styled("Nothing due.", p.dim()));
    } else {
        let rows = d
            .due
            .iter()
            .map(|l| {
                vec![
                    cell(
                        if l.role.is_empty() {
                            "-".into()
                        } else {
                            l.role.clone()
                        },
                        p.dim(),
                    ),
                    match l.first_seen {
                        0 => "-".into(),
                        t => dur((now - t as i64) as f64).into(),
                    },
                    if l.unhandled {
                        cell(format!("unhandled: {}", l.line), p.warn())
                    } else {
                        l.line.clone().into()
                    },
                ]
            })
            .collect();
        out.extend(
            Table {
                header: vec!["ROLE", "WAITING", "LINE"],
                rows,
                keep: vec![2, 0, 1],
                flex: Some(2),
                flexmin: 12,
                right: vec![1],
                cap: vec![(0, 18)],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }
    out.push(clip_line(
        Line::styled("The pass's rundowns: Log > Rundowns.", p.dim()),
        w,
    ));
    out
}

/// Log's Judges' verdicts section: both judges' counts and their lists, each at most `FOLD_ROWS`;
/// `filter` is one of `ASK_FILTERS`, for the answer judge's.
pub fn verdicts(f: &Fleet, filter: &str, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![dispatch_head(&f.dispatch, p, w)];
    out.extend(dispatch_list(&f.dispatch, p, now, w));
    out.push(Line::raw(""));
    out.push(judge_head(&f.judge, p, w));
    out.extend(judge_list(&f.judge, filter, FOLD_ROWS, p, now, w));
    out
}

fn secs(ms: Option<u64>) -> String {
    ms.map_or("-".into(), |ms| dur(ms as f64 / 1000.0))
}

const PAD: &str = "    ";

/// One runner's registry, as agent-web's expanded row: its role and what the role takes away,
/// model, prompt and its sha, trigger, 24h calls, the newest call's Langfuse trace, and a judge's
/// per-rule table.
fn registry(r: &Registry, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let c = &r.calls;
    let prompt = if r.prompt.is_empty() {
        "-".to_string()
    } else {
        let sha = if c.prompt_sha.is_empty() {
            r.eval.as_ref().map_or("", |e| e.prompt_sha.as_str())
        } else {
            &c.prompt_sha
        };
        format!("{} {sha}", r.prompt.rsplit('/').next().unwrap_or(&r.prompt))
    };
    let dash = |s: &str| {
        if s.is_empty() {
            "-".to_string()
        } else {
            s.to_string()
        }
    };
    let mut out = vec![
        Line::from(vec![
            Span::raw(PAD),
            Span::styled(dash(&r.role), p.head()),
            Span::styled(format!("  {}", r.caps), p.dim()),
        ]),
        Line::from(vec![
            Span::raw(PAD),
            Span::styled(
                format!(
                    "model {}  prompt {prompt}  effect {}",
                    dash(&r.model),
                    dash(&r.effect)
                ),
                p.dim(),
            ),
        ]),
        Line::from(vec![
            Span::raw(PAD),
            Span::raw(format!("trigger {} | 24h: {} calls, ", r.trigger, c.n_24h)),
            Span::styled(
                format!("{} errors", c.errors_24h),
                if c.errors_24h > 0 {
                    p.bad()
                } else {
                    Default::default()
                },
            ),
            Span::raw(format!(
                ", {}, {} tokens, p95 {}",
                usd(c.cost_24h),
                kilo(c.tokens_24h),
                secs(c.p95_ms)
            )),
        ]),
    ];
    if let Some(x) = c.recent.first() {
        out.push(Line::from(vec![
            Span::raw(PAD),
            Span::styled(
                format!(
                    "last call {} {} {}  {}",
                    clock(x.at, now),
                    secs(Some(x.ms)),
                    if x.ok { "ok" } else { "error" },
                    if x.link.is_empty() { &x.id } else { &x.link }
                ),
                if x.ok { p.dim() } else { p.bad() },
            ),
        ]));
    }
    let mut out: Vec<_> = out.into_iter().map(|l| clip_line(l, w)).collect();
    if let Some(e) = &r.eval {
        out.extend(eval(e, p, w));
    }
    out
}

/// A judge's per-rule table from judge-eval; a rule not yet live shows its labels against the bar.
fn eval(e: &Eval, p: Palette, w: usize) -> Vec<Line<'static>> {
    if e.rules.is_empty() {
        return vec![clip_line(
            Line::styled(
                format!("{PAD}no verdicts under prompt {}", e.prompt_sha),
                p.dim(),
            ),
            w,
        )];
    }
    // judge-eval gives percents, fmt::pct takes ratios.
    let pct = |x: Option<f64>| pct(x.map(|x| x / 100.0));
    let rows = e
        .rules
        .iter()
        .map(|r| {
            let live = match (&r.bar, r.live) {
                (_, true) => "yes".to_string(),
                (Some(b), false) => format!("no ({}/{} to bar)", b.labels, b.need),
                (None, false) => "no".into(),
            };
            vec![
                cell(r.rule.clone(), Default::default()),
                r.verdicts.to_string().into(),
                r.scored.to_string().into(),
                pct(r.precision).into(),
                pct(r.false_defer_pct).into(),
                cell(live, if r.live { p.good() } else { p.dim() }),
            ]
        })
        .collect();
    Table {
        header: vec!["RULE", "CALLS", "SCORED", "PREC", "FALSE-DEFER", "LIVE"],
        rows,
        keep: vec![0, 5, 3, 4, 1, 2],
        right: vec![1, 2, 3, 4],
        ..Default::default()
    }
    .fit(w.saturating_sub(PAD.len()), p.dim())
    .into_iter()
    .map(|l| {
        let mut spans = vec![Span::raw(PAD)];
        spans.extend(l.spans);
        Line::from(spans)
    })
    .collect()
}

fn dispatch_head(d: &Dispatch, p: Palette, w: usize) -> Line<'static> {
    let floor = if d.partial { "+" } else { "" };
    let mut kinds: Vec<&String> = d.counts_7d.keys().chain(d.counts_24h.keys()).collect();
    kinds.sort();
    kinds.dedup();
    let mut counts: Vec<String> = kinds
        .iter()
        .map(|k| {
            format!(
                "{k} {} ({}{floor} in 7d)",
                d.counts_24h.get(*k).unwrap_or(&0),
                d.counts_7d.get(*k).unwrap_or(&0)
            )
        })
        .collect();
    for verb in ["started", "reaped"] {
        counts.push(format!("{verb} {}", d.log_24h.get(verb).unwrap_or(&0)));
    }
    clip_line(
        heading("DISPATCH JUDGE", format!("  24h: {}", counts.join("  ")), p),
        w,
    )
}

fn dispatch_list(d: &Dispatch, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if d.recent.is_empty() {
        return vec![Line::styled("No verdicts yet.", p.dim())];
    }
    let mut out = vec![];
    let rows = d
        .recent
        .iter()
        .take(FOLD_ROWS)
        .map(|v| {
            let style = match v.verdict.as_str() {
                "dispatch" => p.good(),
                "failed" => p.bad(),
                _ => p.warn(),
            };
            vec![
                clock(v.ts, now).into(),
                v.project.clone().into(),
                cell(v.verdict.clone(), style),
                v.tier.map_or("-".into(), |t| format!("{t}")).into(),
                match v.clear {
                    None => "-",
                    Some(true) => "yes",
                    Some(false) => "no",
                }
                .into(),
                v.key.clone().into(),
                cell(v.reason.clone(), p.dim()),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec![
                "WHEN", "PROJECT", "VERDICT", "TIER", "CLEAR", "ROW", "REASON",
            ],
            rows,
            keep: vec![0, 2, 5, 1, 3, 4],
            flex: Some(6),
            flexmin: 20,
            right: vec![3],
            cap: vec![(1, 20), (5, 50)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(older(d.recent.len(), FOLD_ROWS, p));
    out
}

/// judge-eval's numbers as it gives them; nothing is recounted here.
fn judge_head(j: &Judge, p: Palette, w: usize) -> Line<'static> {
    let share = j
        .precision
        .map(|x| format!(" ({x}% precision)"))
        .unwrap_or_default();
    let prompt = if j.prompt.is_empty() {
        "none"
    } else {
        j.prompt.as_str()
    };
    clip_line(
        heading(
            "ANSWER JUDGE",
            format!(
                "  prompt {prompt}  agree {}{share}  disagree {}  deferred {}  pending {}  unscored {}",
                j.agree, j.disagree, j.deferred, j.pending, j.unscored
            ),
            p,
        ),
        w,
    )
}

/// judge-eval's percent as it gives it, or "-" with none.
fn share(x: Option<f64>) -> String {
    x.map_or("-".to_string(), |x| format!("{x}%"))
}

/// The answer judge per type and impact level, judge-eval's cells under its current prompt. A
/// live cell's scored count is the answers the human reviewed (AUDITED); silence scores nothing.
fn judge_cells(j: &Judge, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![clip_line(
        Line::styled(
            "  By type and level (self, repo, fleet, critical), under the current prompt:",
            p.dim(),
        ),
        w,
    )];
    if j.cells.is_empty() {
        out.push(clip_line(
            Line::styled(
                format!(
                    "{PAD}no verdicts under prompt {}",
                    if j.prompt.is_empty() {
                        "none"
                    } else {
                        &j.prompt
                    }
                ),
                p.dim(),
            ),
            w,
        ));
        return out;
    }
    let or_dash = |s: &str, none: &str| {
        if s.is_empty() {
            none.to_string()
        } else {
            s.to_string()
        }
    };
    let rows = j
        .cells
        .iter()
        .map(|c| {
            let prec = match (c.precision, c.precision_lo, c.precision_hi) {
                (Some(x), Some(lo), Some(hi)) => format!("{x}% [{lo}-{hi}]"),
                (x, _, _) => share(x),
            };
            vec![
                or_dash(&c.kind, "(no type)").into(),
                or_dash(&c.level, "-").into(),
                c.verdicts.to_string().into(),
                c.scored.to_string().into(),
                prec.into(),
                c.pending.to_string().into(),
                cell(
                    if c.live { "yes" } else { "no" }.to_string(),
                    if c.live { p.good() } else { p.dim() },
                ),
                c.audited.to_string().into(),
                share(c.level_raised_pct).into(),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec![
                "TYPE",
                "LEVEL",
                "VERD",
                "SCORED",
                "PREC [95%]",
                "PEND",
                "LIVE",
                "AUDITED",
                "RAISED",
            ],
            rows,
            keep: vec![0, 1, 4, 3, 6, 7, 2, 5, 8],
            right: vec![2, 3, 4, 5, 7, 8],
            ..Default::default()
        }
        .fit(w.saturating_sub(PAD.len()), p.dim())
        .into_iter()
        .map(|l| {
            let mut spans = vec![Span::raw(PAD)];
            spans.extend(l.spans);
            Line::from(spans)
        }),
    );
    out
}

/// The week's line, the filters, then what the judge said on each ask and why, at most `cap`.
fn judge_list(
    j: &Judge,
    filter: &str,
    cap: usize,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let filters = ASK_FILTERS
        .map(|f| {
            if f == filter {
                format!("[{f}]")
            } else {
                f.to_string()
            }
        })
        .join(" ");
    let mut out = vec![
        clip_line(
            Line::styled(
                format!(
                    "  7d: {} answered, {} would answer, {} right",
                    share(j.week.live_pct),
                    share(j.week.coverage),
                    share(j.week.precision)
                ),
                p.dim(),
            ),
            w,
        ),
        clip_line(Line::styled(format!("  V: {filters}"), p.dim()), w),
    ];
    let shown: Vec<&AskVerdict> = j.verdicts.iter().filter(|v| v.shown(filter)).collect();
    if shown.is_empty() {
        out.push(Line::styled("No verdicts here.", p.dim()));
        return out;
    }
    let rows = shown
        .iter()
        .take(cap)
        .map(|x| {
            let wrong = x.score == "wrong";
            vec![
                x.at.map_or("-".into(), |t| clock(t, now)).into(),
                x.project.clone().into(),
                if x.kind.is_empty() { &x.rule } else { &x.kind }
                    .clone()
                    .into(),
                x.said.clone().into(),
                x.question.clone().into(),
                why(x).into(),
                if wrong {
                    cell(x.you.clone(), p.warn())
                } else {
                    x.you.clone().into()
                },
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec!["WHEN", "PROJECT", "TYPE", "SAID", "QUESTION", "WHY", "YOU"],
            rows,
            keep: vec![0, 3, 6, 2, 1, 4],
            flex: Some(5),
            flexmin: 20,
            cap: vec![(1, 20), (2, 20), (4, 40), (6, 16)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(older(shown.len(), cap, p));
    out
}

/// `[ ]` and Esc on a runner's page, for its first line.
const PAGE_KEYS: &str = "[ ] runner  Esc all runners";

/// One runner's page (`hub tab 'sessions runners <runner>'`, Enter on a Runners row): summary first, then 14
/// days of runs, its status and activity, 24h and 7d calls, the registry, the lane's extras block
/// (`DETAIL=` in its conf) and the conf, as agent-web's `#sessions/runners/<runner>`.
pub fn runner_page(
    name: &str,
    r: Option<&Result<Runner, String>>,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let r = match r {
        None => return vec![Line::styled(format!("Reading {name}..."), p.dim())],
        Some(Err(e)) => {
            return vec![
                clip_line(Line::styled(e.clone(), p.warn()), w),
                Line::styled(format!("  {PAGE_KEYS}"), p.dim()),
            ]
        }
        Some(Ok(r)) => r,
    };
    let mut out = vec![];
    for e in &r.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let lane = if r.lane.is_empty() {
        "no lane"
    } else {
        &r.lane
    };
    out.push(clip_line(
        heading(&r.name.to_uppercase(), format!("  {lane}  {PAGE_KEYS}"), p),
        w,
    ));
    if !r.description.is_empty() {
        out.push(clip_line(
            Line::styled(format!("  {}", r.description), p.dim()),
            w,
        ));
    }
    let state = match r.running_since {
        Some(t) => format!("running since {}", clock(t, now)),
        None if !r.enabled => "off, disabled in its conf".into(),
        None => r.state.clone(),
    };
    let next = r.next.map_or("-".into(), |t| clock(t, now));
    let d = &r.calls.day;
    out.push(clip_line(
        Line::from(vec![
            Span::raw(format!(
                "  {state} | next {next} | 14d: {} runs, ",
                r.runs_total
            )),
            Span::styled(
                format!("{} failed", r.failed_total),
                if r.failed_total > 0 {
                    p.bad()
                } else {
                    Default::default()
                },
            ),
            Span::raw(format!(
                " | 24h: {} calls, {} errors, {}",
                d.calls,
                d.errors,
                usd(d.cost)
            )),
        ]),
        w,
    ));
    if let Some(x) = r.status.get("detail").filter(|x| !x.is_empty()) {
        out.push(clip_line(Line::raw(format!("  status: {x}")), w));
    }

    out.push(Line::raw(""));
    out.push(clip_line(
        heading(
            "RUNS",
            format!(
                "  14 days of runs.jsonl; a run's log: {}, h on {}",
                hub_core::layout::bar_label("infra"),
                r.name
            ),
            p,
        ),
        w,
    ));
    let days: Vec<String> = r
        .days
        .iter()
        .filter(|x| x.runs > 0)
        .map(|x| format!("{} {}/{}", x.day, x.runs, x.failed))
        .collect();
    if !days.is_empty() {
        out.push(clip_line(
            Line::styled(
                format!("  runs/failed by day: {}", days.join("  ")),
                p.dim(),
            ),
            w,
        ));
    }
    if r.runs.is_empty() {
        let call = if r.registry.kind == "call" {
            format!(" ({}; its calls are below)", r.registry.trigger)
        } else {
            String::new()
        };
        out.push(Line::styled(format!("  no run in 14 days{call}"), p.dim()));
    } else {
        let rows = r
            .runs
            .iter()
            .map(|j| {
                let style = match (j.ok, j.state) {
                    (_, hub_core::jobs::State::Running) => p.warn(),
                    (Some(false), _) => p.bad(),
                    (Some(true), _) => p.good(),
                    (None, _) => p.dim(),
                };
                let result = if j.result.is_empty() {
                    match j.state {
                        hub_core::jobs::State::Running => "running",
                        hub_core::jobs::State::Queued => "waiting",
                        hub_core::jobs::State::Done => "done",
                    }
                    .to_string()
                } else {
                    j.result.clone()
                };
                vec![
                    j.started.map_or("-".into(), |t| clock(t, now)).into(),
                    j.secs.map_or("-".into(), |x| dur(x as f64)).into(),
                    cell(result, style),
                    cell(j.detail.clone(), p.dim()),
                ]
            })
            .collect();
        out.extend(
            Table {
                header: vec!["STARTED", "TOOK", "RESULT", "DETAIL"],
                rows,
                keep: vec![0, 2, 1, 3],
                right: vec![1],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
        out.extend(older(r.runs_older as usize, 0, p));
    }

    out.push(Line::raw(""));
    out.push(clip_line(
        heading("STATUS", "  its status file, then activity.log".into(), p),
        w,
    ));
    if r.status.is_empty() {
        out.push(Line::styled("  No status file.", p.dim()));
    }
    for (k, v) in &r.status {
        let v = match (k.as_str(), v.parse::<i64>()) {
            ("updated" | "next", Ok(t)) => clock(t, now),
            _ => v.clone(),
        };
        out.push(clip_line(Line::raw(format!("  {k:<8} {v}")), w));
    }
    for a in &r.activity {
        let style = match a.ok {
            Some(false) => p.bad(),
            None => p.warn(),
            Some(true) => p.good(),
        };
        out.push(clip_line(
            Line::from(vec![
                Span::raw(format!("  {} ", a.at.map_or("-".into(), |t| clock(t, now)))),
                Span::styled(format!("{} ", a.word), style),
                Span::styled(a.text.clone(), p.dim()),
            ]),
            w,
        ));
    }

    out.push(Line::raw(""));
    let floor = if r.calls.partial { "+" } else { "" };
    out.push(clip_line(heading("CALLS", "  calls.jsonl".into(), p), w));
    let row = |l: &str, t: &Totals, f: &str| {
        vec![
            l.to_string().into(),
            format!("{}{f}", t.calls).into(),
            cell(
                format!("{}{f}", t.errors),
                if t.errors > 0 {
                    p.bad()
                } else {
                    Default::default()
                },
            ),
            format!("{}{f}", kilo(t.tokens)).into(),
            usd(t.cost).into(),
            secs(t.p50_ms).into(),
        ]
    };
    out.extend(
        Table {
            header: vec!["", "CALLS", "ERRORS", "TOKENS", "$", "P50"],
            rows: vec![row("24h", d, ""), row("7d", &r.calls.week, floor)],
            keep: vec![0, 1, 2, 4, 3, 5],
            right: vec![1, 2, 3, 4, 5],
            ..Default::default()
        }
        .fit(w, p.head()),
    );

    out.push(Line::raw(""));
    out.push(clip_line(heading("REGISTRY", String::new(), p), w));
    out.extend(registry(&r.registry, p, now, w));
    out.extend(extras(&r.extras, p, now, w));

    out.push(Line::raw(""));
    out.push(clip_line(
        heading(
            "CONF",
            format!("  ~/.config/agentctl/agents/{}.conf", r.name),
            p,
        ),
        w,
    ));
    for c in &r.conf {
        out.push(clip_line(
            Line::from(vec![
                Span::raw(format!("  {}=", c.key)),
                Span::styled(c.value.clone(), p.dim()),
            ]),
            w,
        ));
    }
    out
}

/// The lane's extras block, as `DETAIL=` in the runner's conf picks it.
fn extras(x: &Extras, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![Line::raw("")];
    match x {
        Extras::None => return vec![],
        Extras::DispatchVerdicts { dispatch } => {
            out.push(dispatch_head(dispatch, p, w));
            out.extend(dispatch_list(dispatch, p, now, w));
        }
        Extras::AskJudge { judge } => {
            out.push(judge_head(judge, p, w));
            out.extend(judge_cells(judge, p, w));
            out.extend(judge_list(
                judge,
                ASK_FILTERS[0],
                runner::PAGE_ROWS,
                p,
                now,
                w,
            ));
        }
        Extras::Ingest {
            counts_7d,
            steps,
            partial,
        } => {
            let floor = if *partial { "+" } else { "" };
            let counts: Vec<String> = counts_7d
                .iter()
                .map(|(k, n)| format!("{k} {n}{floor}"))
                .collect();
            out.push(clip_line(
                heading("INTAKE", format!("  7d: {}", counts.join("  ")), p),
                w,
            ));
            if steps.is_empty() {
                out.push(Line::styled("  No intake step in 7 days.", p.dim()));
            }
            for t in steps {
                let at = hub_core::fleet::ts(&t.ts).map_or("-".into(), |x| clock(x, now));
                let to = if t.to.is_empty() {
                    String::new()
                } else {
                    format!(" -> {}", t.to)
                };
                out.push(clip_line(
                    Line::from(vec![
                        Span::raw(format!("  {at} {} ", t.action)),
                        Span::styled(format!("{}{to} ", t.from), p.dim()),
                        Span::raw(t.text.clone()),
                    ]),
                    w,
                ));
            }
        }
        // Every watch with what it checks, where and what to do is Alerts' Watches; here only
        // the count and the way there.
        Extras::SentinelWatches { watches } => {
            let trip = watches.iter().filter(|x| x.state == "TRIP").count();
            let alerts = hub_core::layout::bar_label("alerts");
            out.push(clip_line(
                heading(
                    "WATCHES",
                    format!(
                        "  {} watches, {trip} tripped: {alerts}, Watches",
                        watches.len()
                    ),
                    p,
                ),
                w,
            ));
        }
    }
    out
}

/// The rule behind the call, the quote that decided it, then the judge's reason.
fn why(x: &AskVerdict) -> String {
    let rule = if x.rule.is_empty() || x.rule == x.kind {
        String::new()
    } else {
        format!("{}: ", x.rule)
    };
    if x.evidence.is_empty() {
        format!("{rule}{}", x.reason)
    } else {
        format!("{rule}\"{}\" {}", x.evidence, x.reason)
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::fleet::{
        Bar, Call, Calls, JudgeWeek, Outcome, RunnerScore, Score, Verdict, Worker,
    };

    pub const NOW: i64 = 1_793_661_428;

    fn who_row(tier: u8, name: &str, state: &str, under: &str) -> Who {
        Who {
            tier,
            kind: if tier == 1 { "lead" } else { "observe" }.into(),
            who: name.into(),
            state: state.into(),
            since: Some(NOW - 600),
            cost_24h: Some(4.5),
            cost_estimated: false,
            purpose: format!("{name} for"),
            doing: format!("{name} doing"),
            under: under.into(),
        }
    }

    pub fn fixture() -> Fleet {
        Fleet {
            at: NOW,
            errors: vec!["dispatch: unreadable".into()],
            legend: vec!["lead runs the sessions".into(), "observe reports".into()],
            workers: vec![
                Worker {
                    name: "dream".into(),
                    lane: "memory".into(),
                    enabled: true,
                    state: "idle".into(),
                    last: Some(Outcome {
                        word: "FAILED".into(),
                        ok: Some(false),
                        at: Some(NOW - 600),
                        text: String::new(),
                    }),
                    runs_24h: 3,
                    failed_24h: 1,
                    why: Some(Outcome {
                        word: "FAILED".into(),
                        ok: Some(false),
                        at: Some(NOW - 600),
                        text: "claude exited 1".into(),
                    }),
                    next: Some(NOW + 3600),
                    score: Some(RunnerScore {
                        text: "81% kept".into(),
                        title: "7d, 34 of 42 right, 0 pending, lessons-kept".into(),
                    }),
                    registry: Registry {
                        kind: "oneshot".into(),
                        trigger: "*-*-* 03:00:00".into(),
                        role: "curate".into(),
                        caps: "write yes, task no, bash yes, mcp none".into(),
                        model: "claude-opus-5-5".into(),
                        prompt: "/home/k/.config/dream/prompt.md".into(),
                        calls: Calls {
                            n_24h: 14,
                            errors_24h: 1,
                            cost_24h: Some(0.12),
                            tokens_24h: 864_905,
                            p95_ms: Some(7_100),
                            prompt_sha: "3fa1c2d".into(),
                            recent: vec![Call {
                                id: "c1".into(),
                                at: NOW - 60,
                                ms: 3_200,
                                ok: true,
                                link: "https://lf/project/P/sessions/s1".into(),
                                ..Default::default()
                            }],
                        },
                        eval: Some(Eval {
                            prompt_sha: "3fa1c2d".into(),
                            rules: vec![
                                Score {
                                    rule: "ship_deploy".into(),
                                    verdicts: 9,
                                    scored: 6,
                                    precision: Some(100.0),
                                    live: true,
                                    ..Default::default()
                                },
                                Score {
                                    rule: "taste".into(),
                                    verdicts: 31,
                                    scored: 28,
                                    false_defer_pct: Some(18.0),
                                    bar: Some(Bar {
                                        labels: 6,
                                        need: 30,
                                        met: false,
                                    }),
                                    ..Default::default()
                                },
                            ],
                            ..Default::default()
                        }),
                        ..Default::default()
                    },
                    ..Default::default()
                },
                Worker {
                    name: "idle-one".into(),
                    enabled: false,
                    ..Default::default()
                },
            ],
            who: vec![
                who_row(1, "dream", "failed", "1 sessions"),
                who_row(2, "idle-one", "off", ""),
                who_row(2, "inbox-triage", "working", ""),
            ],
            dispatch: Dispatch {
                recent: vec![Verdict {
                    project: "dotfiles".into(),
                    key: "fix the flaky bats test".into(),
                    verdict: "dispatch".into(),
                    reason: "clear and small".into(),
                    tier: Some(3.0),
                    clear: Some(true),
                    ts: NOW - 120,
                    ..Default::default()
                }],
                counts_24h: [("dispatch".to_string(), 2)].into(),
                counts_7d: [("dispatch".to_string(), 9), ("skip".to_string(), 4)].into(),
                partial: true,
                log_24h: [("started".to_string(), 2), ("reaped".to_string(), 1)].into(),
            },
            judge: Judge {
                agree: 3,
                disagree: 1,
                deferred: 2,
                pending: 1,
                unscored: 5,
                precision: Some(75.0),
                kappa: Some(0.2),
                prompt: "60c840b".into(),
                week: JudgeWeek {
                    live_pct: Some(25.0),
                    coverage: Some(40.0),
                    precision: Some(91.0),
                },
                verdicts: vec![
                    AskVerdict {
                        id: "abc".into(),
                        project: "dotfiles".into(),
                        question: "land the fleet tab now?".into(),
                        kind: "ship_deploy".into(),
                        rule: "ship_deploy".into(),
                        said: "would answer".into(),
                        judge: "yes".into(),
                        reason: "tests pass".into(),
                        evidence: "CI green".into(),
                        you: "wait".into(),
                        score: "wrong".into(),
                        at: Some(NOW - 60),
                    },
                    AskVerdict {
                        id: "def".into(),
                        project: "trader".into(),
                        question: "which login?".into(),
                        rule: "knowledge".into(),
                        said: "passed".into(),
                        reason: "only you know it".into(),
                        you: "pending".into(),
                        score: "pending".into(),
                        at: Some(NOW - 120),
                        ..Default::default()
                    },
                ],
                cells: vec![
                    hub_core::fleet::Cell {
                        kind: "ship_deploy".into(),
                        level: "repo".into(),
                        verdicts: 4,
                        scored: 3,
                        pending: 1,
                        precision: Some(66.7),
                        precision_lo: Some(20.8),
                        precision_hi: Some(93.9),
                        live: true,
                        audited: 3,
                        level_raised_pct: Some(25.0),
                    },
                    hub_core::fleet::Cell {
                        verdicts: 2,
                        pending: 2,
                        ..Default::default()
                    },
                ],
                ..Default::default()
            },
        }
    }

    fn lines(f: &Fleet, t: &DataTable, w: usize) -> Vec<String> {
        page(f, t, Palette { no_color: true }, NOW, w)
            .0
            .iter()
            .map(plain)
            .collect()
    }

    /// The Runners table, then Log's verdicts section drawn from the same read.
    fn text(f: &Fleet, w: usize) -> String {
        let p = Palette { no_color: true };
        lines(f, &DataTable::default(), w)
            .into_iter()
            .chain(verdicts(f, "all", p, NOW, w).iter().map(plain))
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn the_page_shows_the_one_table_and_no_accounts() {
        let s = text(&fixture(), 160);
        for want in [
            "dispatch: unreadable",
            "RUNNERS  3 of 3 rows, spend: 0 Costs",
            "all 3  lead 1  deliver 0  observe 2  learn 0  maintain 0",
            "KIND",
            "FOR",
            "COST 24H",
            "$4.50",
            "dream for",
            "lead runs the sessions | observe reports",
            "1 sessions",
            "inbox-triage",
            "dispatch 2 (9+ in 7d)  skip 0 (4+ in 7d)  started 2  reaped 1",
            "prompt 60c840b  agree 3 (75% precision)",
            "land the fleet tab now?",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
        // The accounts and the token folds are Costs' now (coststab.rs, tokens.rs).
        for gone in [
            "CLAUDE ACCOUNTS",
            "WHERE THE TOKENS GO",
            "WHAT LANGFUSE SEES",
        ] {
            assert!(!s.contains(gone), "{gone:?} is still on Runners\n{s}");
        }
        // The sessions are the Sessions inner tab's, so the runners table has no session columns.
        let head = s.lines().find(|l| l.starts_with("KIND")).unwrap();
        for gone in ["PROJECT", "ACTIVITY"] {
            assert!(
                !head.contains(gone),
                "{gone:?} is still a Runners column: {head}"
            );
        }
    }

    #[test]
    fn a_search_narrows_the_runners() {
        let f = fixture();
        let names =
            |t: &DataTable| -> Vec<String> { shown(&f, t).iter().map(|r| r.who.clone()).collect() };
        assert_eq!(
            names(&DataTable::default()),
            ["dream", "idle-one", "inbox-triage"]
        );
        let mut q = DataTable::default();
        q.view.q = "inbox".into();
        assert_eq!(names(&q), ["inbox-triage"]);
    }

    #[test]
    fn the_shepherd_page_shows_the_lease_and_each_line_due() {
        use hub_core::boards::DueLine;
        let d = Due {
            due: vec![
                DueLine {
                    key: "k1".into(),
                    role: "shepherd".into(),
                    first_seen: (NOW - 900) as u64,
                    line: "dotfiles-agent-3 stalled 40m".into(),
                    unhandled: true,
                },
                DueLine {
                    key: "k2".into(),
                    role: String::new(),
                    first_seen: 0,
                    line: "trader-agent-1 landed #12".into(),
                    unhandled: false,
                },
            ],
            lease_holder: Some("runner".into()),
            lease_at: Some((NOW - 120) as u64),
        };
        let p = Palette { no_color: true };
        let s = shepherd_page(&d, p, NOW, 120)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n");
        for want in [
            "SHEPHERD  2 due, lease runner, taken 2m ago",
            "ROLE",
            "unhandled: dotfiles-agent-3 stalled 40m",
            "15m",
            "trader-agent-1 landed #12",
            "Log > Rundowns",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
        let none = shepherd_page(&Due::default(), p, NOW, 120)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            none.contains("0 due, no pass holds the lease") && none.contains("Nothing due."),
            "{none}"
        );
    }

    #[test]
    fn a_held_runner_is_red_like_a_failed_one() {
        let p = Palette::default();
        let mut f = fixture();
        f.who[1] = who_row(2, "ask-judge", "held", "");
        let (out, _) = page(&f, &DataTable::default(), p, NOW, 160);
        let span = |word: &str| {
            out.iter()
                .flat_map(|l| l.spans.iter())
                .find(|s| s.content.trim() == word)
                .map(|s| s.style)
                .unwrap()
        };
        assert_eq!(span("held"), p.bad());
        assert_eq!(span("failed"), span("held"));
    }

    #[test]
    fn the_selected_row_is_the_reversed_one() {
        let p = Palette { no_color: true };
        let f = fixture();
        let t = DataTable {
            sel: 1,
            ..Default::default()
        };
        let (out, sel) = page(&f, &t, p, NOW, 160);
        let at = out
            .iter()
            .position(|l| plain(l).contains("idle-one"))
            .unwrap();
        assert_eq!(out[at].style, p.sel());
        assert_ne!(out[at - 1].style, p.sel());
        assert_eq!(sel, Some(at), "the line it names is the reversed one");
    }

    #[test]
    fn the_selected_line_counts_the_wrapped_legend_and_chips_above_the_rows() {
        // A narrow pane wraps the legend and the chip line onto several lines each: the line the
        // page names for the selection is still the reversed row's.
        let p = Palette { no_color: true };
        let mut f = fixture();
        f.legend = (0..6)
            .map(|i| format!("kind{i} means a long thing"))
            .collect();
        let t = DataTable {
            sel: 2,
            ..Default::default()
        };
        let (out, sel) = page(&f, &t, p, NOW, 40);
        let at = sel.expect("rows");
        assert_eq!(out[at].style, p.sel());
        assert!(at > 6, "the wrapped legend sits above: {at}");
        let mut none = DataTable::default();
        none.view.q = "nothing-matches".into();
        assert_eq!(page(&f, &none, p, NOW, 40).1, None, "no row, no line");
    }

    #[test]
    fn a_narrow_runners_page_fits() {
        for l in lines(&fixture(), &DataTable::default(), 40) {
            assert!(l.chars().count() <= 40, "{l:?}");
        }
    }

    #[test]
    fn a_search_that_keeps_nothing_says_so() {
        let mut t = DataTable::default();
        t.view.q = "nothing-matches".into();
        let l = lines(&fixture(), &t, 160);
        assert!(l.iter().any(|l| l.contains("No runner matches")), "{l:#?}");
    }

    #[test]
    fn an_empty_fleet_says_so() {
        let s = text(&Fleet::default(), 100);
        for want in [
            "No runners configured",
            "No verdicts yet.",
            "No verdicts here.",
            "agree 0  disagree 0",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
    }

    #[test]
    fn the_verdict_list_says_what_the_judge_said_and_why_under_each_filter() {
        let p = Palette { no_color: true };
        let list = |filter| {
            verdicts(&fixture(), filter, p, NOW, 200)
                .iter()
                .map(plain)
                .collect::<Vec<_>>()
                .join("\n")
        };
        let all = list("all");
        for want in [
            "7d: 25% answered, 40% would answer, 91% right",
            "[all] answered would answer passed wrong",
            "ship_deploy",
            "\"CI green\" tests pass",
            "knowledge: only you know it",
        ] {
            assert!(all.contains(want), "{want:?} missing from\n{all}");
        }
        let passed = list("passed");
        assert!(
            passed.contains("which login?") && !passed.contains("land the fleet tab"),
            "{passed}"
        );
        assert!(list("wrong").contains("land the fleet tab"));
        assert!(list("answered").contains("No verdicts here."));
    }

    /// dream's page: two runs (one failed), a status with a retry in its detail, an activity
    /// line, calls in both windows, and fleet-dispatch's verdicts as its extras block.
    pub fn runner_fixture() -> Runner {
        use hub_core::fleet::runner::{ConfLine, Day, PageCalls};
        use hub_core::jobs::{Job, Source, State};
        let f = fixture();
        let run = |at: i64, ok: bool, result: &str| Job {
            ok: Some(ok),
            result: result.into(),
            started: Some(at),
            secs: Some(95),
            ..Job::new(Source::Agentctl, "dream", State::Done)
        };
        Runner {
            at: NOW,
            name: "dream".into(),
            lane: "memory".into(),
            description: "nightly memory consolidation".into(),
            enabled: true,
            state: "idle".into(),
            next: Some(NOW + 3_600),
            registry: f.workers[0].registry.clone(),
            conf: vec![
                ConfLine {
                    key: "MODEL".into(),
                    value: "claude-opus-5-5".into(),
                },
                ConfLine {
                    key: "DETAIL".into(),
                    value: "dispatch-verdicts".into(),
                },
            ],
            status: [
                ("detail".to_string(), "retry 17:30".to_string()),
                ("next".to_string(), (NOW + 3_600).to_string()),
            ]
            .into(),
            activity: vec![Outcome {
                word: "WORKED".into(),
                ok: Some(true),
                at: Some(NOW - 7_200),
                text: "promoted 3 lessons".into(),
            }],
            runs: vec![
                run(NOW - 7_200, true, "WORKED"),
                run(NOW - 93_600, false, "FAILED"),
            ],
            runs_total: 2,
            runs_older: 0,
            failed_total: 1,
            days: vec![Day {
                day: "11-06".into(),
                runs: 2,
                failed: 1,
            }],
            calls: PageCalls {
                day: Totals {
                    calls: 14,
                    errors: 1,
                    tokens: 864_905,
                    cost: Some(0.12),
                    p50_ms: Some(3_200),
                },
                week: Totals {
                    calls: 90,
                    errors: 2,
                    tokens: 5_000_000,
                    cost: Some(0.8),
                    p50_ms: Some(3_000),
                },
                partial: true,
                recent: vec![],
            },
            extras: Extras::DispatchVerdicts {
                dispatch: f.dispatch.clone(),
            },
            ..Default::default()
        }
    }

    fn page_text(r: Option<&Result<Runner, String>>, w: usize) -> Vec<String> {
        runner_page("dream", r, Palette { no_color: true }, NOW, w)
            .iter()
            .map(plain)
            .collect()
    }

    #[test]
    fn a_runner_page_puts_its_summary_first_then_runs_status_calls_registry_extras_and_conf() {
        let lines = page_text(Some(&Ok(runner_fixture())), 160);
        let s = lines.join("\n");
        assert!(lines[0].starts_with("DREAM  memory  [ ] runner"), "{s}");
        assert!(
            lines[2].contains("idle | next ") && lines[2].contains("14d: 2 runs, 1 failed"),
            "{s}"
        );
        assert!(lines[2].contains("24h: 14 calls, 1 errors, $0.12"), "{s}");
        let at = |want: &str| {
            lines
                .iter()
                .position(|l| l.contains(want))
                .unwrap_or_else(|| panic!("{want:?} missing from\n{s}"))
        };
        let order = [
            "status: retry 17:30",
            "RUNS  14 days of runs.jsonl",
            "runs/failed by day: 11-06 2/1",
            "STATUS",
            "WORKED promoted 3 lessons",
            "CALLS",
            "REGISTRY",
            "trigger *-*-* 03:00:00",
            "DISPATCH JUDGE",
            "fix the flaky bats test",
            "CONF",
            "DETAIL=dispatch-verdicts",
        ];
        let seen: Vec<usize> = order.iter().map(|w| at(w)).collect();
        assert!(
            seen.windows(2).all(|x| x[0] < x[1]),
            "out of order {seen:?}\n{s}"
        );
        assert!(s.contains("FAILED"), "{s}");
        let calls = &lines[at("CALLS") + 1..at("CALLS") + 4].join("\n");
        assert!(
            calls.contains("865k") && calls.contains("90+"),
            "the 7d row is a floor\n{calls}"
        );
        assert!(!s.contains("no run in 14 days"), "{s}");
    }

    #[test]
    fn a_runner_with_no_runs_says_no_run_in_14_days_not_an_error() {
        let r = Runner {
            name: "dream".into(),
            enabled: true,
            state: "idle".into(),
            ..Default::default()
        };
        let lines = page_text(Some(&Ok(r)), 100);
        let s = lines.join("\n");
        assert!(s.contains("  no run in 14 days"), "{s}");
        assert!(s.contains("No status file."), "{s}");
        assert!(
            !s.contains("by day"),
            "a quiet fortnight draws no day line\n{s}"
        );
        let call = Runner {
            registry: Registry {
                kind: "call".into(),
                trigger: "called by fleet-dispatch".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        let s = page_text(Some(&Ok(call)), 100).join("\n");
        assert!(
            s.contains("no run in 14 days (called by fleet-dispatch; its calls are below)"),
            "{s}"
        );
    }

    #[test]
    fn a_running_row_is_not_counted_as_an_older_run() {
        use hub_core::jobs::{Job, Source, State};
        let mut r = runner_fixture();
        let running = Job {
            started: Some(NOW - 60),
            ..Job::new(Source::Agentctl, "dream", State::Running)
        };
        r.runs.insert(0, running);
        let s = page_text(Some(&Ok(r.clone())), 160).join("\n");
        assert!(s.contains("running") && !s.contains("older"), "{s}");
        r.runs_older = 3;
        let s = page_text(Some(&Ok(r)), 160).join("\n");
        assert!(s.contains("+3 older"), "{s}");
    }

    #[test]
    fn a_page_still_reading_or_unreadable_says_so() {
        assert_eq!(page_text(None, 80), ["Reading dream..."]);
        let lines = page_text(Some(&Err("no runner named dream".into())), 80);
        assert_eq!(lines[0], "no runner named dream");
        assert!(lines[1].contains("Esc all runners"));
    }

    #[test]
    fn sentinels_page_counts_its_watches_and_sends_them_to_alerts() {
        let mut r = runner_fixture();
        let watch = |state: &str| hub_core::fleet::runner::Watch {
            name: "dream".into(),
            state: state.into(),
            ..Default::default()
        };
        r.extras = Extras::SentinelWatches {
            watches: vec![watch("TRIP"), watch("OK")],
        };
        let lines = page_text(Some(&Ok(r)), 120);
        assert!(
            lines.contains(&"WATCHES  2 watches, 1 tripped: 7 Alerts, Watches".to_string()),
            "{lines:?}"
        );
        assert!(!lines.iter().any(|l| l.contains("LAST RUN")), "{lines:?}");
    }

    #[test]
    fn the_answer_judges_page_tables_each_type_at_each_level_as_judge_eval_scores_it() {
        let mut r = runner_fixture();
        r.extras = Extras::AskJudge {
            judge: Box::new(fixture().judge),
        };
        let lines = page_text(Some(&Ok(r.clone())), 160);
        let s = lines.join("\n");
        let head = lines
            .iter()
            .position(|l| l.contains("TYPE") && l.contains("AUDITED"));
        let head = head.unwrap_or_else(|| panic!("{s}"));
        assert!(lines[head].contains("PREC [95%]"), "{s}");
        let row = &lines[head + 1];
        for want in ["ship_deploy", "repo", "66.7% [20.8-93.9]", "yes", "25%"] {
            assert!(row.contains(want), "{want}: {row}");
        }
        // A verdict with no type or level is its own cell, never folded into another.
        assert!(lines[head + 2].contains("(no type)"), "{s}");
        // It sits between the judge's counts and its verdict list.
        let judge = lines
            .iter()
            .position(|l| l.starts_with("ANSWER JUDGE"))
            .unwrap();
        let list = lines.iter().position(|l| l.contains("7d:")).unwrap();
        assert!(judge < head && head < list, "{s}");

        if let Extras::AskJudge { judge } = &mut r.extras {
            judge.cells.clear();
        }
        let lines = page_text(Some(&Ok(r.clone())), 160);
        assert!(
            lines
                .iter()
                .any(|l| l.contains("no verdicts under prompt 60c840b")),
            "{lines:?}"
        );
        // No prompt reads "none", as the counts line above it does.
        if let Extras::AskJudge { judge } = &mut r.extras {
            judge.prompt.clear();
        }
        let lines = page_text(Some(&Ok(r.clone())), 160);
        assert!(
            lines
                .iter()
                .any(|l| l.trim_end().ends_with("no verdicts under prompt none")),
            "{lines:?}"
        );
        // The page lists the newest `PAGE_ROWS` of every verdict it is sent.
        if let Extras::AskJudge { judge } = &mut r.extras {
            let v = judge.verdicts[0].clone();
            judge.verdicts = vec![v; runner::PAGE_ROWS + 3];
        }
        let lines = page_text(Some(&Ok(r)), 160);
        let rows = lines
            .iter()
            .filter(|l| l.contains("land the fleet tab"))
            .count();
        assert_eq!(rows, runner::PAGE_ROWS, "{lines:?}");
        assert!(lines.iter().any(|l| l.trim() == "+3 older"), "{lines:?}");
    }

    #[test]
    fn a_narrow_runner_page_fits() {
        let mut r = runner_fixture();
        for x in [
            Extras::None,
            r.extras.clone(),
            Extras::AskJudge {
                judge: Box::new(fixture().judge),
            },
            Extras::SentinelWatches {
                watches: vec![hub_core::fleet::runner::Watch {
                    name: "claude-spend-hourly".into(),
                    state: "TRIP".into(),
                    severity: "high".into(),
                    since: Some(NOW - 600),
                    ..Default::default()
                }],
            },
            Extras::Ingest {
                counts_7d: [("filed".to_string(), 3)].into(),
                steps: vec![hub_core::outbox::Step {
                    ts: "2026-11-06T09:00:00Z".into(),
                    action: "filed".into(),
                    from: "inbox".into(),
                    to: "agent-runtime".into(),
                    text: "a scheduled docker prune".into(),
                    ..Default::default()
                }],
                partial: false,
            },
        ] {
            r.extras = x;
            for l in page_text(Some(&Ok(r.clone())), 40) {
                assert!(l.chars().count() <= 40, "{l:?}");
            }
        }
    }
}
