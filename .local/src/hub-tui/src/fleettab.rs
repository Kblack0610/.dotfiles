//! The Fleet tab's machinery, below the sessions: the Claude accounts, each agentctl runner, and
//! the dispatch and answer judges, from hub-core's `fleet` (the same reader as agent-web's Fleet
//! tab). Named apart from `fleet.rs`, which is the sessions' watch page.

use std::collections::BTreeMap;

use hub_core::fleet::{Dispatch, Fleet, Judge, Worker};
use hub_core::prom::Series;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, Table};
use crate::fmt::{clock, Palette};

fn usd(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("${v:.2}"))
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

pub fn page(f: &Fleet, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &f.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    out.push(heading("CLAUDE ACCOUNTS", String::new(), p));
    out.extend(accounts(&f.accounts, p, now, w));
    out.push(Line::raw(""));
    out.push(clip_line(
        heading(
            "WORKERS",
            format!(
                "  {} runners, {} in 24h across every agentctl run",
                f.workers.len(),
                usd(f.cost_24h)
            ),
            p,
        ),
        w,
    ));
    out.extend(workers(&f.workers, p, now, w));
    out.push(Line::raw(""));
    out.extend(dispatch(&f.dispatch, p, now, w));
    out.push(Line::raw(""));
    out.extend(judge(&f.judge, p, now, w));
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

fn workers(ws: &[Worker], p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if ws.is_empty() {
        return vec![Line::styled(
            "No runners configured in ~/.config/agentctl/agents.",
            p.dim(),
        )];
    }
    let rows = ws
        .iter()
        .map(|r| {
            let name = if r.enabled {
                cell(r.name.clone(), p.head())
            } else {
                cell(format!("{} (off)", r.name), p.dim())
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
                cell(why, p.dim()),
            ]
        })
        .collect();
    Table {
        header: vec![
            "RUNNER", "LANE", "LAST", "WHEN", "RUNS", "FAIL", "NEXT", "$24H", "WHY",
        ],
        rows,
        keep: vec![0, 2, 3, 5, 4, 6, 7, 1],
        flex: Some(8),
        flexmin: 20,
        right: vec![4, 5, 7],
        cap: vec![(0, 28)],
        ..Default::default()
    }
    .fit(w, p.head())
}

fn dispatch(d: &Dispatch, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
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
    let mut out = vec![clip_line(
        heading("DISPATCH JUDGE", format!("  24h: {}", counts.join("  ")), p),
        w,
    )];
    if d.recent.is_empty() {
        out.push(Line::styled("No verdicts yet.", p.dim()));
        return out;
    }
    let rows = d
        .recent
        .iter()
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
    out
}

fn judge(j: &Judge, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let scored = j.agree + j.disagree;
    let share = if scored > 0 {
        format!(" ({}% of scored)", (100 * j.agree + scored / 2) / scored)
    } else {
        String::new()
    };
    let mut out = vec![clip_line(
        heading(
            "ANSWER JUDGE",
            format!(
                "  agree {}{share}  disagree {}  deferred {}  pending {}  unscored {}",
                j.agree, j.disagree, j.deferred, j.pending, j.unscored
            ),
            p,
        ),
        w,
    )];
    if j.disagreements.is_empty() {
        out.push(Line::styled("No disagreements.", p.dim()));
        return out;
    }
    let rows = j
        .disagreements
        .iter()
        .map(|x| {
            vec![
                x.answered_at.map_or("-".into(), |t| clock(t, now)).into(),
                x.project.clone().into(),
                cell(x.judge.clone(), p.warn()),
                x.answer.clone().into(),
                x.question.clone().into(),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec!["ANSWERED", "PROJECT", "JUDGE", "YOU", "QUESTION"],
            rows,
            keep: vec![0, 2, 3, 1],
            flex: Some(4),
            flexmin: 20,
            cap: vec![(1, 20), (2, 24), (3, 24)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::fleet::{Disagreement, Outcome, Verdict};

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
                    ..Default::default()
                },
                Worker {
                    name: "idle-one".into(),
                    enabled: false,
                    ..Default::default()
                },
            ],
            cost_24h: Some(4.5),
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
                disagreements: vec![Disagreement {
                    id: "abc".into(),
                    project: "dotfiles".into(),
                    question: "land the fleet tab now?".into(),
                    judge: "yes".into(),
                    reason: "tests pass".into(),
                    answer: "wait".into(),
                    answered_at: Some(NOW - 60),
                }],
            },
        }
    }

    fn text(f: &Fleet, w: usize) -> String {
        page(f, Palette { no_color: true }, NOW, w)
            .iter()
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
            "agree 3 (75% of scored)  disagree 1  deferred 2  pending 1  unscored 5",
            "land the fleet tab now?",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
    }

    #[test]
    fn an_empty_fleet_says_so() {
        let s = text(&Fleet::default(), 100);
        for want in [
            "no data",
            "No runners configured",
            "No verdicts yet.",
            "No disagreements.",
            "agree 0  disagree 0",
        ] {
            assert!(s.contains(want), "{want:?} missing from\n{s}");
        }
    }

    #[test]
    fn a_narrow_page_fits() {
        for l in page(&fixture(), Palette { no_color: true }, NOW, 40) {
            assert!(plain(&l).chars().count() <= 40, "{:?}", plain(&l));
        }
    }
}
