//! The Fleet tab's machinery, below the sessions: one table of who is working (runners by tier,
//! then the live sessions) and the Claude accounts, from hub-core's `fleet` (the same reader as agent-web's Fleet
//! tab). Named apart from `fleet.rs`, which is the sessions' watch page. One runner's page
//! (`runner_page`) is hub-core's `fleet::runner`, as agent-web's `#fleet/<runner>`.

use std::collections::{BTreeMap, HashSet};

use hub_core::fleet::runner::{Extras, Runner, Totals};
use hub_core::fleet::who::{self, Who};
use hub_core::fleet::{AskVerdict, Dispatch, Eval, Fleet, Judge, Registry, ASK_FILTERS};
use hub_core::prom::Series;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, Table};
use crate::fmt::{clock, dur, older, pct, Palette};
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

/// The rows as shown: the table's query, state and sort applied, then the rows a folded tier 1
/// row holds taken out (unless a search or chip is on). `[ ]`-free: j/k step through these and
/// Enter opens the one selected.
pub fn shown<'a>(f: &'a Fleet, t: &DataTable, folded: &HashSet<String>) -> Vec<&'a Who> {
    who::unfolded(t.view.apply(&f.who), folded, &t.view)
}

/// The Fleet page: the table of who is working, then the Claude accounts. `sel` is the row j/k
/// picked, drawn reversed: Enter opens it.
pub fn page(
    f: &Fleet,
    t: &DataTable,
    folded: &HashSet<String>,
    sel: usize,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &f.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let rows = shown(f, t, folded);
    out.push(clip_line(
        heading(
            "FLEET",
            format!("  {} of {} rows, spend: 9 Costs", rows.len(), f.who.len(),),
            p,
        ),
        w,
    ));
    out.push(clip_line(Line::from(t.status(&f.who, p)), w));
    out.extend(who_table(
        &rows,
        t,
        folded,
        sel,
        p,
        now,
        w,
        f.who.is_empty(),
    ));
    out.push(Line::raw(""));
    out.push(heading("CLAUDE ACCOUNTS", String::new(), p));
    out.extend(accounts(&f.accounts, p, now, w));
    out
}

/// `Who::COLUMNS` in capitals, in its order: the sort mark is placed by that index.
const WHO_HEADER: [&str; 7] = ["TIER", "WHO", "STATE", "SINCE", "DOING", "UNDER", "PROJECT"];

#[allow(clippy::too_many_arguments)]
fn who_table(
    rows: &[&Who],
    t: &DataTable,
    folded: &HashSet<String>,
    sel: usize,
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
                "No runner or session matches (/ query, f state, x clears)."
            },
            p.dim(),
        )];
    }
    let cells = rows
        .iter()
        .map(|r| {
            let state = match r.state.as_str() {
                "failed" => p.bad(),
                "needs you" | "stalled" => p.warn(),
                "working" => p.good(),
                _ => p.dim(),
            };
            let fold = match (r.kids, folded.contains(&r.key)) {
                (0, _) => "",
                (_, true) => "> ",
                (_, false) => "v ",
            };
            vec![
                format!("{fold}{}", r.tier).into(),
                cell(
                    r.who.clone(),
                    if r.tier == 3 {
                        Default::default()
                    } else {
                        p.head()
                    },
                ),
                cell(r.state.clone(), state),
                r.since.map_or("-".into(), |s| dur((now - s) as f64)).into(),
                r.doing.clone().into(),
                cell(r.under.clone(), p.dim()),
                cell(r.project.clone(), p.dim()),
            ]
        })
        .collect();
    let mut out = Table {
        header: WHO_HEADER.to_vec(),
        rows: cells,
        // DOING is the flex column and stays where the rest can drop around it.
        keep: vec![1, 2, 4, 3, 0, 6, 5],
        flex: Some(4),
        flexmin: 16,
        right: vec![3],
        cap: vec![(1, 28), (5, 22), (6, 16)],
        mark: t.mark::<Who>(),
        ..Default::default()
    }
    .fit(w, p.head());
    if let Some(l) = out.get_mut(sel.min(rows.len() - 1) + 1) {
        l.style = p.sel();
    }
    out
}

/// Log's Judges' verdicts section: both judges' counts and their lists, each at most `FOLD_ROWS`;
/// `filter` is one of `ASK_FILTERS`, for the answer judge's.
pub fn verdicts(f: &Fleet, filter: &str, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![dispatch_head(&f.dispatch, p, w)];
    out.extend(dispatch_list(&f.dispatch, p, now, w));
    out.push(Line::raw(""));
    out.push(judge_head(&f.judge, p, w));
    out.extend(judge_list(&f.judge, filter, p, now, w));
    out
}

/// One row per account from claude-acct's textfile, as agent-web's table.
fn accounts(series: &[Series], p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut by: BTreeMap<&str, BTreeMap<&str, f64>> = BTreeMap::new();
    for s in series {
        let key = s.label("__name__").trim_start_matches("claude_account_");
        if let Some(v) = s.value {
            by.entry(s.label("account")).or_default().insert(key, v);
        }
    }
    if by.is_empty() {
        return vec![Line::styled("no data", p.dim())];
    }
    let when = |v: Option<&f64>| v.map_or("-".into(), |t| clock(*t as i64, now));
    let pc = |v: Option<&f64>| v.map_or("-".into(), |v| format!("{}%", v.floor()));
    let rows = by
        .iter()
        .map(|(name, a)| {
            if a.get("read_ok") == Some(&0.0) {
                return vec![cell(*name, p.head()), cell("usage unreadable", p.bad())];
            }
            if !a.contains_key("week_used_percent") {
                return vec![
                    cell(*name, p.head()),
                    cell("idle, token refreshes on launch", p.dim()),
                ];
            }
            let over = a.get("over_pace") == Some(&1.0);
            vec![
                cell(*name, p.head()),
                pc(a.get("week_used_percent")).into(),
                pc(a.get("week_gone_percent")).into(),
                cell(
                    if over { "over" } else { "under" },
                    if over { p.bad() } else { p.good() },
                ),
                when(a.get("run_out_timestamp_seconds")).into(),
                when(a.get("resets_timestamp_seconds")).into(),
                pc(a.get("five_hour_percent")).into(),
                when(a.get("five_hour_resets_timestamp_seconds")).into(),
                a.get("live_sessions")
                    .map_or("-".into(), |v| format!("{v:.0}"))
                    .into(),
                usd(a.get("cost_24h_usd").copied()).into(),
            ]
        })
        .collect();
    Table {
        header: vec![
            "ACCOUNT",
            "WEEK",
            "GONE",
            "PACE",
            "RUNS OUT",
            "RESETS",
            "5H",
            "5H RESETS",
            "LIVE",
            "$24H",
        ],
        rows,
        keep: vec![0, 1, 3, 2, 6, 5, 4, 9, 8, 7],
        right: vec![1, 2, 6, 8, 9],
        ..Default::default()
    }
    .fit(w, p.head())
}

fn kilo(n: u64) -> String {
    match n {
        n if n >= 1_000_000 => format!("{:.1}M", n as f64 / 1e6),
        n if n >= 1_000 => format!("{}k", (n + 500) / 1_000),
        n => n.to_string(),
    }
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
                "  prompt {prompt}  agree {}{share}  disagree {}  deferred {}  false-defer {}  pending {}  unscored {}",
                j.agree, j.disagree, j.deferred, j.false_defer, j.pending, j.unscored
            ),
            p,
        ),
        w,
    )
}

/// The week's line, the filters, then what the judge said on each ask and why.
fn judge_list(j: &Judge, filter: &str, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let share = |x: Option<f64>| x.map_or("-".to_string(), |x| format!("{x}%"));
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
        .take(FOLD_ROWS)
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
    out.extend(older(shown.len(), FOLD_ROWS, p));
    out
}

/// The runner a `fleet <word>` query names: any word but one of Fleet's own section names
/// (`accounts`), which scroll there instead. One rule for `hub tab fleet` and `--once --tab`.
pub fn runner_arg(q: &str) -> Option<&str> {
    let q = q.trim();
    let secs =
        hub_core::layout::resolve(crate::app::Tab::Fleet.title()).map_or(&[][..], |t| t.sections);
    (!q.is_empty() && !secs.iter().any(|s| s.eq_ignore_ascii_case(q))).then_some(q)
}

/// `[ ]` and Esc on a runner's page, for its first line.
const PAGE_KEYS: &str = "[ ] runner  Esc all runners";

/// One runner's page (`hub tab fleet <runner>`, Enter on a Workers row): summary first, then 14
/// days of runs, its status and activity, 24h and 7d calls, the registry, the lane's extras block
/// (`DETAIL=` in its conf) and the conf, as agent-web's `#fleet/<runner>`.
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
                "  14 days of runs.jsonl; a run's log: 6 Infra, h on {}",
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
                        hub_core::jobs::State::Queued => "queued",
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
            out.extend(judge_list(judge, ASK_FILTERS[0], p, now, w));
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
        Extras::SentinelWatches { watches } => {
            let trip = watches.iter().filter(|x| x.state == "TRIP").count();
            out.push(clip_line(
                heading(
                    "WATCHES",
                    format!("  {} watches, {trip} tripped", watches.len()),
                    p,
                ),
                w,
            ));
            let at = |t: Option<i64>| t.map_or("-".into(), |t| clock(t, now));
            let rows = watches
                .iter()
                .map(|x| {
                    let style = match x.state.as_str() {
                        "TRIP" | "ERROR" => p.bad(),
                        "OK" => p.good(),
                        _ => p.dim(),
                    };
                    vec![
                        x.name.clone().into(),
                        cell(x.state.clone(), style),
                        cell(x.severity.clone(), p.dim()),
                        at(x.since).into(),
                        at(x.lastrun).into(),
                    ]
                })
                .collect();
            out.extend(
                Table {
                    header: vec!["WATCH", "STATE", "SEVERITY", "SINCE", "LAST RUN"],
                    rows,
                    keep: vec![0, 1, 3, 4, 2],
                    ..Default::default()
                }
                .fit(w, p.head()),
            );
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
    use hub_core::fleet::who::Opens;
    use hub_core::fleet::{
        Bar, Call, Calls, JudgeWeek, Outcome, RunnerScore, Score, Verdict, Worker,
    };

    pub const NOW: i64 = 1_793_661_428;

    fn series(name: &str, account: &str, v: f64) -> Series {
        Series {
            labels: [
                ("__name__".to_string(), format!("claude_account_{name}")),
                ("account".to_string(), account.to_string()),
            ]
            .into(),
            value: Some(v),
            points: vec![],
        }
    }

    fn who_row(
        tier: u8,
        name: &str,
        key: &str,
        opens: Opens,
        state: &str,
        kids: usize,
        parent: Option<&str>,
    ) -> Who {
        Who {
            tier,
            who: name.into(),
            opens,
            key: key.into(),
            state: state.into(),
            since: Some(NOW - 600),
            doing: format!("{name} doing"),
            under: if kids > 0 {
                format!("{kids} sessions")
            } else {
                String::new()
            },
            project: "dotfiles".into(),
            parent: parent.map(String::from),
            kids,
        }
    }

    pub fn fixture() -> Fleet {
        Fleet {
            at: NOW,
            errors: vec!["prometheus: timed out".into()],
            accounts: vec![
                series("week_used_percent", "main", 42.7),
                series("week_gone_percent", "main", 50.0),
                series("over_pace", "main", 0.0),
                series("cost_24h_usd", "main", 12.5),
                series("read_ok", "alt", 0.0),
            ],
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
                who_row(1, "dream", "dream", Opens::Runner, "failed", 1, None),
                who_row(2, "idle-one", "idle-one", Opens::Runner, "off", 0, None),
                who_row(
                    3,
                    "dotfiles-agent-11",
                    "lab/dotfiles-agent-11:1",
                    Opens::Session,
                    "working",
                    0,
                    Some("dream"),
                ),
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
                false_defer: 1,
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
            },
        }
    }

    fn lines(
        f: &Fleet,
        t: &DataTable,
        folded: &HashSet<String>,
        sel: usize,
        w: usize,
    ) -> Vec<String> {
        page(f, t, folded, sel, Palette { no_color: true }, NOW, w)
            .iter()
            .map(plain)
            .collect()
    }

    /// The Fleet page, then Log's verdicts section drawn from the same read.
    fn text(f: &Fleet, w: usize) -> String {
        let p = Palette { no_color: true };
        lines(f, &DataTable::default(), &HashSet::new(), usize::MAX, w)
            .into_iter()
            .chain(verdicts(f, "all", p, NOW, w).iter().map(plain))
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn the_page_shows_the_one_table_then_the_accounts() {
        let s = text(&fixture(), 160);
        for want in [
            "prometheus: timed out",
            "FLEET  3 of 3 rows, spend: 9 Costs",
            "all 3",
            "TIER  WHO",
            "1 sessions",
            "dotfiles-agent-11",
            "CLAUDE ACCOUNTS",
            "usage unreadable",
            "42%",
            "$12.50",
            "dispatch 2 (9+ in 7d)  skip 0 (4+ in 7d)  started 2  reaped 1",
            "prompt 60c840b  agree 3 (75% precision)",
            "land the fleet tab now?",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
    }

    #[test]
    fn a_folded_tier_one_row_leaves_its_children_out_until_a_search_asks() {
        let f = fixture();
        let t = DataTable::default();
        let folded: HashSet<String> = ["dream".to_string()].into();
        let names = |t: &DataTable| -> Vec<String> {
            shown(&f, t, &folded)
                .iter()
                .map(|r| r.who.clone())
                .collect()
        };
        assert_eq!(names(&t), ["dream", "idle-one"]);
        let mut q = DataTable::default();
        q.view.q = "agent".into();
        assert_eq!(names(&q), ["dotfiles-agent-11"], "a hit is never hidden");
        let rows = lines(&f, &t, &folded, 0, 160);
        assert!(
            rows.iter()
                .any(|l| l.contains("> 1") && l.contains("dream")),
            "{rows:#?}"
        );
        assert!(
            !rows.iter().any(|l| l.contains("dotfiles-agent-11")),
            "{rows:#?}"
        );
    }

    #[test]
    fn the_selected_row_is_the_reversed_one() {
        let p = Palette { no_color: true };
        let f = fixture();
        let out = page(&f, &DataTable::default(), &HashSet::new(), 1, p, NOW, 160);
        let at = out
            .iter()
            .position(|l| plain(l).contains("idle-one"))
            .unwrap();
        assert_eq!(out[at].style, p.sel());
        assert_ne!(out[at - 1].style, p.sel());
    }

    #[test]
    fn a_narrow_fleet_page_fits() {
        for l in lines(&fixture(), &DataTable::default(), &HashSet::new(), 0, 40) {
            assert!(l.chars().count() <= 40, "{l:?}");
        }
    }

    #[test]
    fn a_search_that_keeps_nothing_says_so() {
        let mut t = DataTable::default();
        t.view.q = "nothing-matches".into();
        let l = lines(&fixture(), &t, &HashSet::new(), 0, 160);
        assert!(
            l.iter().any(|l| l.contains("No runner or session matches")),
            "{l:#?}"
        );
    }

    #[test]
    fn an_empty_fleet_says_so() {
        let s = text(&Fleet::default(), 100);
        for want in [
            "no data",
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
    fn a_fleet_word_is_a_runner_unless_it_names_a_section() {
        assert_eq!(runner_arg(" inbox-triage "), Some("inbox-triage"));
        assert_eq!(runner_arg("Accounts"), None);
        assert_eq!(runner_arg("  "), None);
    }

    #[test]
    fn a_page_still_reading_or_unreadable_says_so() {
        assert_eq!(page_text(None, 80), ["Reading dream..."]);
        let lines = page_text(Some(&Err("no runner named dream".into())), 80);
        assert_eq!(lines[0], "no runner named dream");
        assert!(lines[1].contains("Esc all runners"));
    }

    #[test]
    fn a_narrow_runner_page_fits() {
        let mut r = runner_fixture();
        for x in [
            Extras::None,
            r.extras.clone(),
            Extras::AskJudge {
                judge: fixture().judge,
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
