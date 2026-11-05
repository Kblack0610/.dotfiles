//! `fleet-bench forecast`, `vs` and `flow` on the Sessions tab (the retired Forecast tab's
//! content). The all-done-by band and the drain, the burn-up of scope against done and the frozen
//! baseline against what happened since sit at the bottom, folded; a session's phase timeline is
//! its detail pane. Every number comes from fleet-bench; this page
//! only lays them out, with the words its text output uses.

use std::process::{Command, Stdio};

use ratatui::style::Style;
use ratatui::text::{Line, Span};
use serde_json::Value;

use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fleet::short;
use crate::fmt::{clock, dur, Palette};

pub const BIN: &str = "fleet-bench";

/// fleet-bench's exit for a verb or flag it does not know: it prints its usage.
const USAGE_EXIT: i32 = 2;

/// Rows of the burn-up chart.
const CHART_H: usize = 8;

/// Why a verb gave no JSON. `usage`: this fleet-bench does not have the verb.
#[derive(Debug)]
pub struct Fail {
    pub usage: bool,
    pub why: String,
}

pub type Got = Result<Value, Fail>;

/// One read of the three verbs.
pub struct Forecast {
    pub at: i64,
    pub forecast: Got,
    pub vs: Got,
    pub flow: Got,
}

impl Forecast {
    pub fn read() -> Forecast {
        Forecast::read_with(BIN)
    }

    /// The three verbs at once; each is a separate jq pass over the same history.
    pub fn read_with(bin: &str) -> Forecast {
        std::thread::scope(|s| {
            let fc = s.spawn(|| run(bin, &["forecast", "--json"]));
            let vs = s.spawn(|| run(bin, &["vs", "--json"]));
            let flow = run(bin, &["flow", "--json", "--hourly"]);
            let join = |h: std::thread::ScopedJoinHandle<Got>| {
                h.join().unwrap_or_else(|_| {
                    Err(Fail {
                        usage: false,
                        why: "the reader panicked".into(),
                    })
                })
            };
            Forecast {
                at: hub_core::jobs::now(),
                forecast: join(fc),
                vs: join(vs),
                flow,
            }
        })
    }
}

fn run(bin: &str, args: &[&str]) -> Got {
    let what = format!("{bin} {}", args.join(" "));
    let fail = |usage, why| Err(Fail { usage, why });
    let out = match Command::new(bin).args(args).stdin(Stdio::null()).output() {
        Ok(o) => o,
        Err(e) => return fail(false, format!("{what}: {e}")),
    };
    if !out.status.success() {
        let code = out.status.code();
        if code == Some(USAGE_EXIT) {
            return fail(true, format!("{what}: exit {USAGE_EXIT}, usage"));
        }
        let err = String::from_utf8_lossy(&out.stderr);
        let first = err.lines().map(str::trim).find(|l| !l.is_empty());
        let code = code.map_or("killed".into(), |c| format!("exit {c}"));
        return fail(
            false,
            match first {
                Some(l) => format!("{what}: {code}: {l}"),
                None => format!("{what}: {code}"),
            },
        );
    }
    serde_json::from_slice(&out.stdout).or_else(|e| fail(false, format!("{what}: not JSON ({e})")))
}

fn i(v: &Value, k: &str) -> Option<i64> {
    v[k].as_i64()
}
fn n(v: &Value, k: &str) -> String {
    match &v[k] {
        Value::Number(x) => x.to_string(),
        _ => "-".into(),
    }
}
fn at(v: &Value, k: &str, now: i64) -> String {
    i(v, k).map_or("-".into(), |t| clock(t, now))
}

/// The schedule rows: each session's phases, finish p50 and lateness.
pub fn schedule(f: &Forecast) -> Vec<Value> {
    match &f.forecast {
        Ok(fc) => fc["schedule"].as_array().cloned().unwrap_or_default(),
        Err(_) => vec![],
    }
}

/// The band, the drain, the burn-up and the baseline, top to bottom.
pub fn page(f: &Forecast, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    match &f.forecast {
        Ok(fc) if fc.is_object() => {
            out.extend(header(fc, p, now, f.at, w));
        }
        Ok(_) => out.push(Line::styled(
            "No forecast: fleet-bench forecast --json gave no object",
            p.warn(),
        )),
        Err(e) => {
            out.push(clip_line(
                Line::styled(format!("No forecast: {}", e.why), p.warn()),
                w,
            ));
            if e.usage {
                out.push(Line::styled(
                    "This fleet-bench has no forecast verb: update the checkout ~/.local/bin/fleet-bench links to.",
                    p.dim(),
                ));
            }
        }
    }
    out.push(Line::raw(""));
    out.extend(burnup(&f.flow, p, now, w));
    out.push(Line::raw(""));
    out.extend(versus(&f.vs, p, now, w));
    out
}

fn header(fc: &Value, p: Palette, now: i64, read: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(
                format!(
                    "FORECAST  {} sessions with a plan, {} phases open",
                    n(fc, "sessions"),
                    n(fc, "open")
                ),
                p.head(),
            ),
            Span::styled(
                format!(
                    "   made {}, read {}",
                    at(fc, "made_epoch", now),
                    clock(read, now)
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    let band = |k: &str| {
        format!(
            "median {:<11}  p90 {:<11}  last {}",
            at(fc, &format!("median_{k}"), now),
            at(fc, &format!("p90_{k}"), now),
            at(fc, &format!("last_{k}"), now)
        )
    };
    out.push(Line::raw(format!("  all done by  p50   {}", band("p50"))));
    let ratio = match &fc["slow_ratio"] {
        Value::Number(x) => format!("{x}x"),
        _ => "none, so 1x".into(),
    };
    out.push(Line::raw(format!(
        "               slow  {}   (at the last 24h scored ratio, {ratio})",
        band("slow")
    )));
    let d = &fc["drain"];
    let rates = format!("in {}/h, out {}/h", n(d, "in_per_h"), n(d, "out_per_h"));
    out.push(match i(d, "epoch") {
        Some(t) => Line::raw(format!("  drain        {} ({rates})", clock(t, now))),
        None => Line::from(vec![
            Span::raw("  drain        "),
            Span::styled(format!(" not draining ({rates}) "), p.status(Some(2.0)).0),
        ]),
    });
    let q = &fc["queue"];
    if q.is_object() {
        out.push(Line::raw(format!(
            "  queue        {} board rows ({} ready), about {} phases at {} per plan",
            n(q, "rows"),
            n(q, "ready"),
            n(q, "phases"),
            n(q, "phases_per_plan")
        )));
    }
    out.push(Line::raw(format!(
        "  unscheduled  {} (no plan or no estimate)",
        n(fc, "unscheduled")
    )));
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mark {
    Empty,
    Solid(char),
    Slow,
    DueNow,
}

/// A session's phases on `cols` columns from `t0` to `t1`: each phase a run of `=` or `#`
/// (alternating, so neighbours show) ending at its p50, then `-` out to the slow finish.
fn bar(s: &Value, t0: i64, t1: i64, cols: usize) -> Vec<Mark> {
    let span = (t1 - t0).max(1) as f64;
    let col = |t: i64| (((t - t0).max(0) as f64 / span * cols as f64).round() as usize).min(cols);
    let mut m = vec![Mark::Empty; cols];
    let mut start = 0;
    let phases = s["phases"].as_array().map_or(&[][..], |a| a.as_slice());
    for (k, ph) in phases.iter().enumerate() {
        let end = col(i(ph, "p50").unwrap_or(t0));
        let ch = if k % 2 == 0 { '=' } else { '#' };
        for c in m.iter_mut().take(end).skip(start) {
            *c = Mark::Solid(ch);
        }
        start = start.max(end);
    }
    let slow = col(i(s, "finish_slow").unwrap_or(t0));
    for c in m.iter_mut().take(slow).skip(start) {
        *c = Mark::Slow;
    }
    // Everything due by now draws nothing: mark the left edge so the row is not blank.
    if cols > 0 && i(s, "finish_p50").is_some_and(|t| t <= t0) && m[0] == Mark::Empty {
        m[0] = Mark::DueNow;
    }
    m
}

fn bar_spans(m: &[Mark], p: Palette) -> Vec<Span<'static>> {
    let mut out: Vec<Span> = vec![];
    let mut run = String::new();
    let mut style = Style::new();
    for &k in m {
        let (ch, st) = match k {
            Mark::Empty => (' ', Style::new()),
            Mark::Solid(c) => (c, Style::new()),
            Mark::Slow => ('-', p.dim()),
            Mark::DueNow => ('!', p.bad()),
        };
        if st != style && !run.is_empty() {
            out.push(Span::styled(std::mem::take(&mut run), style));
        }
        style = st;
        run.push(ch);
    }
    if !run.is_empty() {
        out.push(Span::styled(run, style));
    }
    out
}

/// The time axis: the clock at the far end, then a `|` and the clock at each quarter that fits
/// before it.
fn axis(t0: i64, t1: i64, cols: usize, now: i64) -> String {
    let mut a = vec![' '; cols];
    let end: Vec<char> = format!("{}|", clock(t1, now)).chars().collect();
    let mut stop = cols;
    if cols >= end.len() {
        stop = cols - end.len();
        a[stop..].copy_from_slice(&end);
    }
    let mut free = 0;
    for q in 0..4 {
        let c = cols * q / 4;
        let t = t0 + (t1 - t0) * q as i64 / 4;
        let label: Vec<char> = format!("|{}", clock(t, now)).chars().collect();
        if c >= free && c + label.len() < stop {
            a[c..c + label.len()].copy_from_slice(&label);
            free = c + label.len() + 1;
        }
    }
    a.into_iter().collect()
}

/// One session's schedule row as a timeline from now to its slow finish: the axis, its bar
/// (= and # one phase each, to its p50; - out to slow; ! due now), then each phase's times.
pub fn timeline(s: &Value, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let t0 = now;
    let t1 = i(s, "finish_slow").filter(|t| *t > t0).unwrap_or(t0 + 3600);
    // After the bar: "  12/12  11-04 06:03  late 22h45m  " then the next phase's name.
    let fixed = 2 + 5 + 2 + 11 + 2;
    let cols = (w.saturating_sub(4 + fixed) * 2 / 3).max(10);
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::raw("  "),
            Span::styled(axis(t0, t1, cols, now), p.dim()),
            Span::styled("  DONE   FINISH P50   NEXT", p.head()),
        ]),
        w,
    )];
    let mut spans = vec![Span::raw("  ")];
    spans.extend(bar_spans(&bar(s, t0, t1, cols), p));
    spans.push(Span::raw(format!(
        "  {:>5}  {:<11}  ",
        format!("{}/{}", n(s, "phases_done"), n(s, "phases_total")),
        at(s, "finish_p50", now)
    )));
    if let Some(m) = i(s, "late_min") {
        spans.push(Span::styled(
            format!("late {}  ", dur(m as f64 * 60.0)),
            p.bad(),
        ));
    }
    let next = s["phases"][0]["name"].as_str().unwrap_or("-").to_string();
    spans.push(Span::styled(next, p.dim()));
    out.push(clip_line(Line::from(spans), w));
    for ph in s["phases"].as_array().into_iter().flatten() {
        out.push(clip_line(
            Line::styled(
                format!(
                    "    {}  p50 {}  slow {}",
                    ph["name"].as_str().unwrap_or("-"),
                    at(ph, "p50", now),
                    at(ph, "slow", now)
                ),
                p.dim(),
            ),
            w,
        ));
    }
    out
}

fn burnup(flow: &Got, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let fl = match flow {
        Ok(v) if v.is_object() => v,
        Ok(_) => {
            return vec![
                Line::styled("BURN-UP", p.head()),
                Line::styled("  no samples yet: fleet-bench sample writes them", p.dim()),
            ]
        }
        Err(e) => {
            return vec![
                Line::styled("BURN-UP", p.head()),
                clip_line(Line::styled(format!("  no flow: {}", e.why), p.warn()), w),
            ]
        }
    };
    let mut out = vec![];
    out.push(clip_line(
        Line::from(vec![
            Span::styled(format!("BURN-UP {}h", n(fl, "hours")), p.head()),
            Span::raw(format!(
                "  in {} ({}/h)  done {} ({}/h)  removed {}  net in {}/h  open {} -> {}, {} dropped",
                n(fl, "in"),
                n(fl, "in_per_h"),
                n(fl, "ticked"),
                n(fl, "out_per_h"),
                n(fl, "removed"),
                n(fl, "net_in_per_h"),
                n(fl, "open_start"),
                n(fl, "open_end"),
                n(fl, "dropped"),
            )),
        ]),
        w,
    ));
    let hourly = fl["hourly"].as_array().map_or(&[][..], |a| a.as_slice());
    let pts: Vec<(i64, i64, i64)> = hourly
        .iter()
        .map(|h| {
            (
                i(h, "hour").unwrap_or(0),
                i(h, "scope").unwrap_or(0),
                i(h, "done").unwrap_or(0),
            )
        })
        .collect();
    let top = pts.iter().map(|x| x.1.max(x.2)).max().unwrap_or(0);
    if pts.is_empty() || top <= 0 {
        out.push(Line::styled("  nothing came in or went out", p.dim()));
        return out;
    }
    let gut = top.to_string().len() + 1;
    let room = w.saturating_sub(gut + 4).max(1);
    // The newest hours when the pane is too narrow for all of them.
    let pts = &pts[pts.len().saturating_sub(room)..];
    let cw = (room / pts.len()).clamp(1, 3);
    let level = |v: i64| ((v.max(0) as f64 / top as f64) * CHART_H as f64).round() as usize;
    for r in (1..=CHART_H).rev() {
        let label = if r == CHART_H {
            top.to_string()
        } else {
            String::new()
        };
        let mut spans = vec![Span::styled(format!("  {label:>gut$}|"), p.dim())];
        for &(_, scope, done) in pts {
            let (ch, st) = if level(done) >= r {
                ('#', p.good())
            } else if level(scope) >= r {
                ('.', p.warn())
            } else {
                (' ', Style::new())
            };
            spans.push(Span::styled(ch.to_string().repeat(cw), st));
        }
        out.push(Line::from(spans));
    }
    let width = pts.len() * cw;
    out.push(Line::styled(
        format!("  {:>gut$}+{}", 0, "-".repeat(width)),
        p.dim(),
    ));
    let first = clock(pts[0].0, now);
    let last = clock(pts[pts.len() - 1].0, now);
    let pad = width.saturating_sub(first.len() + last.len());
    out.push(Line::styled(
        format!("  {:gut$} {first}{}{last}", "", " ".repeat(pad)),
        p.dim(),
    ));
    out.push(Line::styled(
        format!("  {:gut$} . scope (open plus done)   # done", ""),
        p.dim(),
    ));
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

const STATES: [&str; 5] = ["finished", "ahead", "on track", "behind", "gone"];

fn state_style(p: Palette, s: &str) -> Style {
    match s {
        "behind" => p.bad(),
        "ahead" | "finished" => p.good(),
        "gone" => p.dim(),
        _ => Style::new(),
    }
}

fn versus(vs: &Got, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let v = match vs {
        Ok(v) if v.is_object() => v,
        other => {
            let mut out = vec![
                Line::styled("VS BASELINE", p.head()),
                Line::styled(
                    "  no baseline yet: fleet-bench forecast --baseline <label>",
                    p.warn(),
                ),
            ];
            if let Err(e) = other {
                out.push(clip_line(
                    Line::styled(format!("  ({})", e.why), p.dim()),
                    w,
                ));
            }
            return out;
        }
    };
    let mut out = vec![clip_line(
        Line::styled(
            format!(
                "VS BASELINE {} (frozen {}, {}h ago)",
                v["label"].as_str().unwrap_or("-"),
                at(v, "made_epoch", now),
                n(v, "hours")
            ),
            p.head(),
        ),
        w,
    )];
    let states: Vec<String> = STATES
        .iter()
        .filter_map(|k| v["states"][*k].as_i64().map(|c| format!("{c} {k}")))
        .collect();
    let summary = [
        format!(
            "ticked {} of {} expected ({} slow), {} fleet-wide",
            n(v, "ticked"),
            n(v, "expected"),
            n(v, "expected_slow"),
            n(v, "ticked_all")
        ),
        if states.is_empty() {
            "no sessions".into()
        } else {
            states.join(", ")
        },
        format!(
            "scope +{} -{}, {} new plans",
            n(v, "added"),
            n(v, "removed"),
            n(v, "new_plans")
        ),
        format!("{} sessions started since", n(v, "started_since")),
        format!(
            "inflow {}/h now against {}/h frozen, out {}/h",
            n(v, "in_per_h"),
            n(v, "in_per_h_frozen"),
            n(v, "out_per_h")
        ),
    ];
    out.extend(
        wrap(&summary, "   ", w.saturating_sub(2))
            .into_iter()
            .map(|l| clip_line(Line::raw(format!("  {l}")), w)),
    );
    let rows: Vec<Vec<Cell>> = v["sessions"]
        .as_array()
        .map_or(&[][..], |a| a.as_slice())
        .iter()
        .map(|s| {
            let st = s["state"].as_str().unwrap_or("-");
            let min = match (st, i(s, "min")) {
                ("behind", Some(m)) => format!("{} past due", dur(m as f64 * 60.0)),
                ("ahead", Some(m)) => format!("{} early", dur(m as f64 * 60.0)),
                _ => "-".into(),
            };
            vec![
                short(s["target"].as_str().unwrap_or("-")).into(),
                cell(st, state_style(p, st)),
                format!("{} of {}", n(s, "ticked"), n(s, "expected")).into(),
                n(s, "left").into(),
                min.into(),
                s["next"].as_str().unwrap_or("-").into(),
            ]
        })
        .collect();
    if rows.is_empty() {
        out.push(Line::styled("  the baseline scheduled no session", p.dim()));
        return out;
    }
    out.push(Line::raw(""));
    out.extend(
        Table {
            header: vec!["SESSION", "STATE", "TICKED", "LEFT", "MIN", "NEXT"],
            rows,
            keep: vec![0, 1, 2, 4, 3],
            flex: Some(5),
            flexmin: 12,
            right: vec![3],
            cap: vec![(0, 30)],
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

    fn load(name: &str) -> Value {
        let path = format!("{}/tests/fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
    }

    /// The three fixtures, read as the hub would the moment the forecast was made.
    pub fn fixture() -> Forecast {
        let forecast = load("forecast");
        Forecast {
            at: forecast["made_epoch"].as_i64().unwrap(),
            forecast: Ok(forecast),
            vs: Ok(load("vs")),
            flow: Ok(load("flow")),
        }
    }

    fn text(lines: &[Line]) -> String {
        lines.iter().map(plain).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn the_three_fixtures_parse_with_the_fields_the_page_reads() {
        let f = fixture();
        let fc = f.forecast.as_ref().unwrap();
        assert_eq!(i(fc, "sessions"), Some(29));
        assert!(fc["drain"]["epoch"].is_null() && fc["queue"].is_null());
        let s = &fc["schedule"][0];
        assert_eq!(s["target"], "hub/dotfiles:4");
        assert_eq!(s["phases"].as_array().unwrap().len(), 12);
        assert!(i(&s["phases"][0], "p50").is_some() && i(&s["phases"][0], "slow").is_some());
        let vs = f.vs.as_ref().unwrap();
        assert_eq!(vs["label"], "backtest");
        assert_eq!(vs["states"]["behind"], 3);
        assert!(vs["states"]["ahead"].is_null(), "a zero count is left out");
        let fl = f.flow.as_ref().unwrap();
        let h = fl["hourly"].as_array().unwrap();
        assert!(h
            .iter()
            .all(|x| i(x, "scope").is_some() && i(x, "done").is_some()));
    }

    #[test]
    fn the_page_shows_the_band_the_burnup_and_the_baseline() {
        let f = fixture();
        let now = f.at;
        let out = text(&page(&f, Palette { no_color: true }, now, 180));
        let fc = f.forecast.as_ref().unwrap();
        assert!(
            out.contains(&format!("median {}", at(fc, "median_p50", now))),
            "{out}"
        );
        assert!(
            out.contains("not draining (in 10.63/h, out 6.88/h)"),
            "{out}"
        );
        assert!(
            !out.contains("queue "),
            "no queue line when the queue is null"
        );
        assert!(out.contains("unscheduled  3"), "{out}");
        assert!(
            !out.contains("late 5h35m"),
            "a session's lateness is its own row's"
        );
        assert!(out.contains("BURN-UP 24h") && out.contains("open 86 -> 97"));
        assert!(out.contains("ticked 5 of 14 expected"), "{out}");
        assert!(out.contains("1 finished, 3 behind, 1 gone"), "{out}");
        assert!(out.contains("22h25m past due"), "{out}");
    }

    #[test]
    fn a_queue_and_a_drain_time_get_their_lines() {
        let mut f = fixture();
        let fc = f.forecast.as_mut().unwrap();
        fc["drain"]["epoch"] = (f.at + 7200).into();
        fc["queue"] =
            serde_json::json!({"rows": 12, "ready": 5, "phases_per_plan": 4, "phases": 48});
        let out = text(&page(&f, Palette { no_color: true }, f.at, 180));
        assert!(!out.contains("not draining"), "{out}");
        assert!(out.contains(&format!("drain        {}", clock(f.at + 7200, f.at))));
        assert!(out.contains("12 board rows (5 ready), about 48 phases at 4 per plan"));
    }

    #[test]
    fn not_draining_is_a_red_chip() {
        let f = fixture();
        let p = Palette::default();
        let out = page(&f, p, f.at, 180);
        let s = out
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content.contains("not draining"))
            .unwrap();
        assert_eq!(s.style, p.status(Some(2.0)).0);
    }

    #[test]
    fn a_bar_runs_its_phases_to_p50_then_slow_to_the_finish() {
        let s = serde_json::json!({
            "phases": [{"p50": 100, "slow": 200}, {"p50": 200, "slow": 400}],
            "finish_p50": 200, "finish_slow": 400
        });
        let m = bar(&s, 0, 400, 8);
        let t: String = bar_spans(&m, Palette { no_color: true })
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert_eq!(t, "==##----");
        let due = serde_json::json!({"phases": [{"p50": 0, "slow": 0}], "finish_p50": 0, "finish_slow": 0});
        assert_eq!(bar(&due, 0, 400, 4)[0], Mark::DueNow);
    }

    #[test]
    fn a_missing_or_failed_fleet_bench_says_so() {
        for bin in ["hub-test-no-such-fleet-bench", "false"] {
            let f = Forecast::read_with(bin);
            assert!(
                f.forecast.is_err() && f.vs.is_err() && f.flow.is_err(),
                "{bin}"
            );
            let out = text(&page(&f, Palette { no_color: true }, f.at, 160));
            assert!(
                out.contains(&format!("No forecast: {bin} forecast --json")),
                "{out}"
            );
            assert!(out.contains("no flow: "), "{out}");
            assert!(
                out.contains("no baseline yet: fleet-bench forecast --baseline <label>"),
                "{out}"
            );
        }
    }

    #[test]
    fn a_fleet_bench_without_the_verbs_is_named_as_such() {
        let f = Forecast {
            at: 0,
            forecast: Err(Fail {
                usage: true,
                why: "fleet-bench forecast --json: exit 2, usage".into(),
            }),
            vs: Ok(Value::Null),
            flow: Ok(Value::Null),
        };
        let out = text(&page(&f, Palette { no_color: true }, 0, 160));
        assert!(
            out.contains("This fleet-bench has no forecast verb"),
            "{out}"
        );
        assert!(out.contains("no samples yet"), "{out}");
    }

    #[test]
    fn a_sessions_timeline_has_its_bar_lateness_and_each_phase() {
        let f = fixture();
        let row = schedule(&f)
            .into_iter()
            .find(|s| s["late_min"].is_i64())
            .unwrap();
        let out = text(&timeline(&row, Palette { no_color: true }, f.at, 160));
        assert!(out.contains("DONE   FINISH P50   NEXT"), "{out}");
        assert!(out.contains("late "), "{out}");
        let first = row["phases"][0]["name"].as_str().unwrap();
        assert!(out.contains(&format!("    {first}  p50 ")), "{out}");
        for w in [40, 80] {
            for l in timeline(&row, Palette { no_color: true }, f.at, w) {
                assert!(unicode_width::UnicodeWidthStr::width(plain(&l).as_str()) <= w);
            }
        }
    }

    #[test]
    fn a_narrow_pane_fits_every_line() {
        let f = fixture();
        for w in [40, 80] {
            for l in page(&f, Palette { no_color: true }, f.at, w) {
                let s = plain(&l);
                assert!(
                    unicode_width::UnicodeWidthStr::width(s.as_str()) <= w,
                    "{w}: {s}"
                );
            }
        }
    }
}
