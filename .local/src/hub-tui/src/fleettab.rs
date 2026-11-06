//! The Fleet tab's machinery, below the sessions: the Claude accounts, each agentctl runner, and
//! the dispatch and answer judges, from hub-core's `fleet` (the same reader as agent-web's Fleet
//! tab). Named apart from `fleet.rs`, which is the sessions' watch page.

use std::collections::BTreeMap;

use hub_core::fleet::{AskVerdict, Dispatch, Eval, Fleet, Judge, Registry, Worker, ASK_FILTERS};
use hub_core::prom::Series;
use ratatui::text::{Line, Span};

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

/// `details` puts each runner's registry lines under its row (the hub's `d`); `tonight` lists
/// the runners in hub-core's Tonight order in place of the default (the hub's `t`).
pub fn page(
    f: &Fleet,
    p: Palette,
    now: i64,
    w: usize,
    details: bool,
    tonight: bool,
) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &f.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    out.push(heading("CLAUDE ACCOUNTS", String::new(), p));
    out.extend(accounts(&f.accounts, p, now, w));
    out.push(Line::raw(""));
    let rest = if tonight {
        format!("  tonight, {} -> {}", hhmm(f.at), hhmm(f.tonight.until))
    } else {
        format!(
            "  {} runners, {} in 24h across every agentctl run",
            f.workers.len(),
            usd(f.cost_24h)
        )
    };
    out.push(clip_line(heading("WORKERS", rest, p), w));
    if tonight {
        let (ws, slots): (Vec<&Worker>, Vec<String>) = f
            .tonight
            .slots
            .iter()
            .filter_map(|s| {
                let r = f.workers.iter().find(|r| r.name == s.name)?;
                let slot = match (&s.under, s.at) {
                    (Some(_), _) => "  `-".to_string(),
                    (None, Some(t)) => hhmm(t),
                    (None, None) => "always".to_string(),
                };
                Some((r, slot))
            })
            .unzip();
        out.extend(workers(&ws, Some(&slots), p, now, w, details));
        if f.tonight.other_timers > 0 {
            out.push(clip_line(
                Line::styled(
                    format!(
                        "  + {} other timers before {}: 6 Infra, Enter for Jobs",
                        f.tonight.other_timers,
                        hhmm(f.tonight.until)
                    ),
                    p.dim(),
                ),
                w,
            ));
        }
    } else {
        let ws: Vec<&Worker> = f.workers.iter().collect();
        out.extend(workers(&ws, None, p, now, w, details));
    }
    out.push(Line::raw(""));
    out.push(dispatch_head(&f.dispatch, p, w));
    out.push(judge_head(&f.judge, p, w));
    out.push(Line::styled("  verdict lists: 7 Log, v", p.dim()));
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

/// A local time as HH:MM, for a slot inside the next day.
fn hhmm(t: i64) -> String {
    chrono::TimeZone::timestamp_opt(&chrono::Local, t, 0)
        .single()
        .map_or("-".into(), |d| d.format("%H:%M").to_string())
}

/// One row per runner; `slots`, when given, prefixes each name with its Tonight slot.
fn workers(
    ws: &[&Worker],
    slots: Option<&[String]>,
    p: Palette,
    now: i64,
    w: usize,
    details: bool,
) -> Vec<Line<'static>> {
    if ws.is_empty() {
        return vec![Line::styled(
            if slots.is_some() {
                "No runner runs before morning."
            } else {
                "No runners configured in ~/.config/agentctl/agents."
            },
            p.dim(),
        )];
    }
    let rows = ws
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let label = match slots.and_then(|s| s.get(i)) {
                Some(s) => format!("{s:<6} {}", r.name),
                None => r.name.clone(),
            };
            let name = if r.enabled {
                cell(label, p.head())
            } else {
                cell(format!("{label} (off)"), p.dim())
            };
            let (last, when) = match (&r.running_since, &r.last) {
                (Some(t), _) => (cell("running", p.warn()), clock(*t, now)),
                (None, Some(o)) => (
                    cell(
                        if o.word.is_empty() { "-" } else { &o.word },
                        match o.ok {
                            Some(false) => p.bad(),
                            None => p.warn(),
                            Some(true) => p.good(),
                        },
                    ),
                    o.at.map_or("-".into(), |t| clock(t, now)),
                ),
                (None, None) => (cell("none 7d", p.dim()), "-".into()),
            };
            let why = r
                .why
                .as_ref()
                .map_or(String::new(), |o| format!("{} {}", o.word, o.text));
            vec![
                name,
                cell(if r.lane.is_empty() { "-" } else { &r.lane }, p.dim()),
                last,
                when.into(),
                r.runs_24h.to_string().into(),
                cell(
                    r.failed_24h.to_string(),
                    if r.failed_24h > 0 {
                        p.bad()
                    } else {
                        Default::default()
                    },
                ),
                r.next.map_or("-".into(), |t| clock(t, now)).into(),
                usd(r.cost_24h).into(),
                r.score.as_ref().map_or("-", |s| &s.text).into(),
                cell(why, p.dim()),
            ]
        })
        .collect();
    let table = Table {
        header: vec![
            "RUNNER", "LANE", "LAST", "WHEN", "RUNS", "FAIL", "NEXT", "$24H", "SCORE", "WHY",
        ],
        rows,
        // WHY is the flex column and stays last: fit neither pads nor clips it, so a column
        // after it would be pushed off the line by a long WHY.
        keep: vec![0, 2, 8, 3, 5, 4, 6, 7, 1],
        flex: Some(9),
        flexmin: 20,
        right: vec![4, 5, 7],
        cap: vec![(0, if slots.is_some() { 35 } else { 28 })],
        ..Default::default()
    }
    .fit(w, p.head());
    if !details {
        return table;
    }
    // fit gives the header, then one line per runner.
    let mut out = vec![];
    for (i, l) in table.into_iter().enumerate() {
        out.push(l);
        if let Some(r) = i.checked_sub(1).and_then(|i| ws.get(i)) {
            out.extend(registry(&r.registry, p, now, w));
            if let Some(s) = &r.score {
                out.push(clip_line(
                    Line::styled(format!("{PAD}score {}: {}", s.text, s.title), p.dim()),
                    w,
                ));
            }
        }
    }
    out
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
        Bar, Call, Calls, JudgeWeek, Outcome, RunnerScore, Score, Slot, Tonight, Verdict,
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
                    cost_24h: Some(1.25),
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
                                    rule: "restates-rule".into(),
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
            cost_24h: Some(4.5),
            tonight: Tonight::default(),
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

    /// The Fleet page, then Log's verdicts section drawn from the same read.
    fn text(f: &Fleet, w: usize) -> String {
        let p = Palette { no_color: true };
        page(f, p, NOW, w, false, false)
            .iter()
            .chain(verdicts(f, "all", p, NOW, w).iter())
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn the_page_shows_each_part() {
        let s = text(&fixture(), 160);
        for want in [
            "prometheus: timed out",
            "CLAUDE ACCOUNTS",
            "usage unreadable",
            "42%",
            "$12.50",
            "WORKERS  2 runners, $4.50 in 24h",
            "FAILED claude exited 1",
            "idle-one (off)",
            "none 7d",
            "dispatch 2 (9+ in 7d)  skip 0 (4+ in 7d)  started 2  reaped 1",
            "fix the flaky bats test",
            "prompt 60c840b  agree 3 (75% precision)  disagree 1  deferred 2  false-defer 1  pending 1  unscored 5",
            "land the fleet tab now?",
            "verdict lists: 7 Log, v",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
    }

    #[test]
    fn the_score_column_sits_before_why_in_both_orders_and_a_lane_with_none_is_a_dash() {
        let p = Palette { no_color: true };
        // A WHY longer than the page: the score before it still shows.
        let mut f = tonight_fixture();
        for w in &mut f.workers {
            if let Some(o) = w.why.as_mut() {
                o.text = "moved 0 from the outbox, filed 0, left 0, refused 3 ".repeat(6);
            }
        }
        for tonight in [false, true] {
            let lines: Vec<String> = page(&f, p, NOW, 150, false, tonight)
                .iter()
                .map(plain)
                .collect();
            let row = |name: &str| {
                lines
                    .iter()
                    .find(|l| l.contains(name) && !l.contains("WORKERS"))
                    .unwrap_or_else(|| panic!("{name:?} missing from {lines:#?}"))
                    .trim_end()
                    .to_string()
            };
            assert!(
                lines
                    .iter()
                    .any(|l| l.trim_end().ends_with("WHY") && l.contains("$24H  SCORE ")),
                "{lines:#?}"
            );
            // dream is the row with its lane, memory.
            assert!(row("memory").contains("81% kept"), "{}", row("memory"));
            assert!(row("memory").ends_with('~'), "{}", row("memory"));
            assert!(row("idle-one").contains(" -  "), "{}", row("idle-one"));
        }
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

    #[test]
    fn a_narrow_page_fits() {
        for (details, tonight) in [(false, false), (true, false), (false, true), (true, true)] {
            for l in page(
                &tonight_fixture(),
                Palette { no_color: true },
                NOW,
                40,
                details,
                tonight,
            ) {
                assert!(plain(&l).chars().count() <= 40, "{:?}", plain(&l));
            }
        }
    }

    #[test]
    fn details_put_each_runners_registry_under_its_row() {
        let p = Palette { no_color: true };
        let lines: Vec<String> = page(&fixture(), p, NOW, 160, true, false)
            .iter()
            .map(plain)
            .collect();
        let row = lines.iter().position(|l| l.starts_with("dream")).unwrap();
        let want = [
            "    curate  write yes, task no, bash yes, mcp none",
            "    model claude-opus-5-5  prompt prompt.md 3fa1c2d  effect -",
            "    trigger *-*-* 03:00:00 | 24h: 14 calls, 1 errors, $0.12, 865k tokens, p95 7s",
        ];
        for (i, w) in want.iter().enumerate() {
            assert_eq!(lines[row + 1 + i].trim_end(), *w, "{lines:#?}");
        }
        assert!(
            lines[row + 4].contains("3s ok  https://lf/project/P/sessions/s1"),
            "{lines:#?}"
        );
        let s = lines.join("\n");
        assert!(s.contains("RULE"), "{s}");
        // The score's title, what it counted, closes dream's block; idle-one has no score line.
        assert!(
            lines.iter().any(|l| l.trim_end()
                == "    score 81% kept: 7d, 34 of 42 right, 0 pending, lessons-kept"),
            "{lines:#?}"
        );
        assert_eq!(lines.iter().filter(|l| l.contains("    score ")).count(), 1);
        let taste = lines.iter().find(|l| l.contains("taste")).unwrap();
        assert!(
            taste.contains("18%") && taste.contains("no (6/30 to bar)"),
            "{taste}"
        );
        let live = lines.iter().find(|l| l.contains("restates-rule")).unwrap();
        assert!(
            live.contains("100%") && live.trim_end().ends_with("yes"),
            "{live}"
        );
        // idle-one has an empty registry: its lines say so with dashes, and no call or table.
        let idle = lines
            .iter()
            .position(|l| l.starts_with("idle-one"))
            .unwrap();
        assert_eq!(lines[idle + 1].trim_end(), "    -", "{lines:#?}");
        assert!(!page(&fixture(), p, NOW, 160, false, false)
            .iter()
            .any(|l| plain(l).contains("trigger")));
    }

    /// The fixture with a call under dream, and its Tonight order: idle-one always on, then
    /// dream, then dream's call.
    pub fn tonight_fixture() -> Fleet {
        let mut f = fixture();
        f.workers.push(Worker {
            name: "ask-sweep".into(),
            enabled: true,
            called_by: Some("dream".into()),
            ..Default::default()
        });
        f.tonight = Tonight {
            until: NOW + 6 * 3600,
            other_timers: 3,
            slots: vec![
                Slot {
                    name: "idle-one".into(),
                    ..Default::default()
                },
                Slot {
                    name: "dream".into(),
                    at: Some(NOW + 3600),
                    under: None,
                },
                Slot {
                    name: "ask-sweep".into(),
                    at: None,
                    under: Some("dream".into()),
                },
            ],
        };
        f
    }

    #[test]
    fn tonight_lists_the_slots_in_order_with_a_call_under_its_caller() {
        let p = Palette { no_color: true };
        let f = tonight_fixture();
        let lines: Vec<String> = page(&f, p, NOW, 160, false, true)
            .iter()
            .map(plain)
            .collect();
        let at = |want: &str| {
            lines
                .iter()
                .position(|l| l.starts_with(want))
                .unwrap_or_else(|| panic!("{want:?} missing from {lines:#?}"))
        };
        let head = format!(
            "WORKERS  tonight, {} -> {}",
            hhmm(NOW),
            hhmm(NOW + 6 * 3600)
        );
        assert!(lines.iter().any(|l| l.starts_with(&head)), "{lines:#?}");
        let (always, dream, call) = (
            at("always idle-one (off)"),
            at(&format!("{}  dream", hhmm(NOW + 3600))),
            at("  `-   ask-sweep"),
        );
        assert!(always < dream && dream + 1 == call, "{lines:#?}");
        assert!(
            lines.iter().any(|l| l.trim()
                == format!(
                    "+ 3 other timers before {}: 6 Infra, Enter for Jobs",
                    hhmm(NOW + 6 * 3600)
                )),
            "{lines:#?}"
        );
        // The default order is untouched: no slot words, every runner by its own name.
        let default: Vec<String> = page(&f, p, NOW, 160, false, false)
            .iter()
            .map(plain)
            .collect();
        assert!(
            !default
                .iter()
                .any(|l| l.contains("always") || l.contains("other timers")),
            "{default:#?}"
        );
        assert!(
            default.iter().any(|l| l.starts_with("ask-sweep")),
            "{default:#?}"
        );
    }

    #[test]
    fn an_empty_night_says_so() {
        let p = Palette { no_color: true };
        let s: Vec<String> = page(&fixture(), p, NOW, 160, false, true)
            .iter()
            .map(plain)
            .collect();
        assert!(
            s.iter()
                .any(|l| l.contains("No runner runs before morning.")),
            "{s:#?}"
        );
        assert!(
            !s.iter().any(|l| l.contains("other timers")),
            "a zero count draws no line"
        );
    }
}
