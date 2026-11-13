//! The Costs tab's two folds from the nightly token snapshot (hub_core::tokens, the same read
//! agent-web's Costs tab draws): where the tokens go (`u`, `U` the window) and what Langfuse sees
//! (`l`): what the fleet costs, not who is working.

use hub_core::costs::tokens as count;
use hub_core::tokens::{Count, Langfuse, Share, Tokens};
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, Table};
use crate::fmt::{clock, dur, kilo, pct, Palette};

fn usd(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("${v:.2}"))
}

/// The tokens fold: `u` folds or opens it, `U` switches its window. None is the default, open
/// (dashboards rule 4).
#[derive(Clone, Copy, Debug, Default)]
pub struct TokensView {
    pub open: Option<bool>,
    pub day: bool,
}

impl TokensView {
    pub fn is_open(self, t: Option<&Tokens>) -> bool {
        t.is_some() && self.open.unwrap_or(true)
    }
}

/// Where the tokens go: a head line with the week's total, and open, one window's two tables.
pub fn tokens(
    t: Option<&Tokens>,
    v: TokensView,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    const TITLE: &str = "WHERE THE TOKENS GO";
    let Some(t) = t else {
        return vec![clip_line(
            Line::from(vec![
                Span::styled(format!("  {TITLE}"), p.head()),
                Span::styled("  no snapshot in ~/.agent/token-usage", p.warn()),
            ]),
            w,
        )];
    };
    let open = v.is_open(Some(t));
    let (mark, verb) = if open { ("-", "folds") } else { ("+", "opens") };
    let week = format!(
        "  7d {}, tool output {}",
        count(Some(t.week.context as f64)),
        pct(Some(t.week.carried_share))
    );
    let mut head = vec![
        Span::styled(format!("{mark} {TITLE}"), p.head()),
        Span::styled(week, if t.stale { p.warn() } else { p.dim() }),
    ];
    if t.stale {
        head.push(Span::styled(format!("  stale, {}", t.date), p.warn()));
    }
    head.push(Span::styled(format!("  u {verb} it"), p.dim()));
    let mut out = vec![clip_line(Line::from(head), w)];
    if !open {
        return out;
    }
    let (s, label) = match (v.day, t.stale) {
        (true, false) => (&t.day, "yesterday"),
        (true, true) => (&t.day, t.date.as_str()),
        (false, _) => (&t.week, "7d"),
    };
    let partial = match s.partial {
        0 => String::new(),
        n => format!(", {n} of {} partial", s.days),
    };
    let read = t.generated_at.map_or("-".into(), |g| clock(g, now));
    out.push(clip_line(
        Line::styled(
            format!(
                "  {label}: {} context, {}/response, tool output {}  ({}, {read}{partial})",
                count(Some(s.context as f64)),
                count(Some(s.per_response as f64)),
                pct(Some(s.carried_share)),
                t.date.get(5..).unwrap_or(&t.date),
            ),
            if s.partial > 0 { p.warn() } else { p.dim() },
        ),
        w,
    ));
    out.extend(token_table("BY TOOL", &s.tools, p, w));
    out.extend(token_table("BY BASH COMMAND", &s.commands, p, w));
    out.push(clip_line(
        Line::styled(
            "  nightly, claude-recall tool-output; U yesterday | 7d; dollars: the tool cut",
            p.dim(),
        ),
        w,
    ));
    out
}

/// Whether the Langfuse fold is open: the human's `l`, else open (dashboards rule 4).
pub fn langfuse_open(open: Option<bool>) -> bool {
    open.unwrap_or(true)
}

/// What Langfuse sees: the newest snapshot's tool latency, tool errors and gateway figures. `open`
/// is the human's fold (`l`); None is the default, open (dashboards rule 4). The gateway's
/// dollars are the gateway's alone, never summed with the Claude sessions' (the table).
pub fn langfuse(
    t: Option<&Tokens>,
    open: Option<bool>,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    const TITLE: &str = "WHAT LANGFUSE SEES";
    let Some(t) = t else { return vec![] };
    let f = t.langfuse.figures.as_ref();
    let open = langfuse_open(open);
    let (mark, verb) = if open { ("-", "folds") } else { ("+", "opens") };
    let mut head = vec![Span::styled(format!("{mark} {TITLE}"), p.head())];
    match f {
        None => head.push(Span::styled(
            format!("  no figures in snapshot {}", t.date),
            p.warn(),
        )),
        Some(f) => {
            let (lead, tool, gw, style) = if t.stale {
                (format!("  stale {}: ", t.date), "tool", "gateway", p.warn())
            } else {
                ("  ".to_string(), "tool errors", "gateway errors", p.dim())
            };
            head.push(Span::styled(
                format!(
                    "{lead}{tool} {}, {gw} {}, {}",
                    pct(f.tool_error_share),
                    pct(f.gateway_error_share),
                    usd(Some(f.gateway_cost_usd)),
                ),
                style,
            ));
        }
    }
    head.push(Span::styled(format!("  l {verb} it"), p.dim()));
    let mut out = vec![clip_line(Line::from(head), w)];
    if !open {
        return out;
    }
    let Some(f) = f else {
        let why = t.langfuse.why.as_deref().unwrap_or(
            "the snapshot has no langfuse section: written before the reader, or the run stopped",
        );
        out.push(clip_line(Line::styled(format!("  {why}"), p.warn()), w));
        return out;
    };
    out.extend(langfuse_tools(f, p, w));
    let classes = |cs: &[Count]| match cs {
        [] => "none".to_string(),
        cs => cs
            .iter()
            .map(|c| format!("{} {}", c.name, c.n))
            .collect::<Vec<_>>()
            .join(", "),
    };
    let partial = if f.truncated {
        " (classes partial)"
    } else {
        ""
    };
    out.push(clip_line(
        Line::styled(
            format!(
                "  tool errors: {} of {} executions ({}){partial}",
                f.tool_errors,
                f.tool_executions,
                classes(&f.tool_error_classes)
            ),
            p.dim(),
        ),
        w,
    ));
    let models = f
        .gateway_models
        .iter()
        .map(|m| format!("{} {}", m.model, usd(Some(m.cost_usd))))
        .chain((f.gateway_other_models > 0).then(|| format!("{} more", f.gateway_other_models)))
        .collect::<Vec<_>>()
        .join(", ");
    out.push(clip_line(
        Line::styled(
            format!(
                "  gateway: {} calls, {} errors ({}), {} tokens",
                f.gateway_calls,
                f.gateway_errors,
                classes(&f.gateway_error_classes),
                kilo(f.gateway_tokens),
            ),
            p.dim(),
        ),
        w,
    ));
    out.push(clip_line(
        Line::styled(
            format!(
                "  gateway dearest: {}",
                if models.is_empty() { "none" } else { &models }
            ),
            p.dim(),
        ),
        w,
    ));
    out.push(clip_line(
        Line::styled(
            "  agent-usage langfuse, nightly; gateway only, Claude sessions are the table",
            p.dim(),
        ),
        w,
    ));
    out
}

fn langfuse_tools(f: &Langfuse, p: Palette, w: usize) -> Vec<Line<'static>> {
    let ms = |ms: u64| {
        if ms >= 1000 {
            format!("{:.1}s", ms as f64 / 1000.0)
        } else {
            format!("{ms}ms")
        }
    };
    let rows = f
        .tools
        .iter()
        .map(|t| {
            vec![
                t.tool.clone().into(),
                t.calls.to_string().into(),
                ms(t.p50_ms).into(),
                ms(t.p95_ms).into(),
                dur(t.total_s as f64).into(),
            ]
        })
        .collect();
    Table {
        header: vec!["SLOWEST TOOLS", "CALLS", "P50", "P95", "TOTAL"],
        rows,
        keep: vec![0, 4, 3, 1, 2],
        right: vec![1, 2, 3, 4],
        ..Default::default()
    }
    .fit(w, p.head())
}

fn token_table(title: &'static str, rows: &[Share], p: Palette, w: usize) -> Vec<Line<'static>> {
    let rows = rows
        .iter()
        .map(|r| {
            vec![
                r.name.clone().into(),
                r.calls.to_string().into(),
                format!("{} ch", count(Some(r.chars as f64))).into(),
                format!("{:.1}%", r.share * 100.0).into(),
                count(Some(r.carried_tokens as f64)).into(),
            ]
        })
        .collect();
    Table {
        header: vec![title, "CALLS", "OUTPUT", "OF OUTPUT", "RE-READ"],
        rows,
        keep: vec![0, 3, 2, 4, 1],
        right: vec![1, 2, 3, 4],
        ..Default::default()
    }
    .fit(w, p.head())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::tokens::{LangfuseView, LfModel, LfTool, Split};

    const NOW: i64 = crate::fleettab::tests::NOW;

    fn token_fixture(stale: bool) -> Tokens {
        let row = |name: &str, chars: u64, share| Share {
            name: name.into(),
            calls: 141_812,
            chars,
            share,
            carried_tokens: 2_550_000_000,
            other: name.starts_with("Other"),
        };
        let split = |context| Split {
            days: 7,
            partial: 0,
            context,
            per_response: 120_000,
            carried_share: 0.15,
            tools: vec![
                row("Bash", 331_000_000, 0.823),
                row("Other (22)", 10_000_000, 0.026),
            ],
            commands: vec![row("sed", 89_000_000, 0.221), row("Other", 40_000_000, 0.1)],
        };
        Tokens {
            date: "2026-11-05".into(),
            generated_at: Some(NOW - 3600),
            stale,
            week: split(18_000_000_000),
            day: split(3_900_000_000),
            langfuse: LangfuseView {
                figures: Some(lf_fixture()),
                why: None,
            },
        }
    }

    fn lf_fixture() -> Langfuse {
        Langfuse {
            tools: vec![LfTool {
                tool: "Bash".into(),
                calls: 35_243,
                p50_ms: 99,
                p95_ms: 17_487,
                total_s: 224_341,
            }],
            tool_executions: 38_947,
            tool_errors: 854,
            tool_error_share: Some(0.0219),
            tool_error_classes: vec![Count {
                name: "ShellError".into(),
                n: 781,
            }],
            gateway_calls: 194,
            gateway_errors: 26,
            gateway_error_share: Some(0.134),
            gateway_error_classes: vec![Count {
                name: "invalid_key".into(),
                n: 16,
            }],
            gateway_cost_usd: 3.59,
            gateway_tokens: 2_271_863,
            gateway_models: vec![LfModel {
                model: "claude-sonnet-5.5".into(),
                calls: 33,
                errors: 0,
                cost_usd: 3.45,
            }],
            gateway_other_models: 14,
            truncated: false,
        }
    }

    fn lf_text(t: Option<&Tokens>, open: Option<bool>, w: usize) -> Vec<String> {
        langfuse(t, open, Palette::default(), w)
            .iter()
            .map(crate::fit::plain)
            .collect()
    }

    #[test]
    fn the_langfuse_fold_starts_open_and_folds_to_one_line() {
        let t = token_fixture(false);
        assert!(lf_text(Some(&t), None, 80)[0].starts_with("- WHAT LANGFUSE SEES"));
        assert_eq!(
            lf_text(Some(&t), Some(false), 80),
            ["+ WHAT LANGFUSE SEES  tool errors 2%, gateway errors 13%, $3.59  l opens it"]
        );
        assert!(lf_text(None, None, 80).is_empty());
    }

    #[test]
    fn open_it_draws_the_tools_the_error_classes_and_the_gateway_in_80_columns() {
        let t = token_fixture(false);
        let l = lf_text(Some(&t), Some(true), 80);
        let all = l.join("\n");
        assert!(
            l[0].starts_with("- WHAT LANGFUSE SEES") && l[0].contains("l folds it"),
            "{all}"
        );
        assert!(
            all.contains("SLOWEST TOOLS") && all.contains("Bash"),
            "{all}"
        );
        assert!(all.contains("17.5s") && all.contains("99ms"), "{all}");
        assert!(
            all.contains("854 of 38947 executions (ShellError 781)"),
            "{all}"
        );
        assert!(
            all.contains("194 calls, 26 errors (invalid_key 16)"),
            "{all}"
        );
        assert!(
            all.contains("dearest: claude-sonnet-5.5 $3.45, 14 more"),
            "{all}"
        );
        assert!(l.iter().all(|x| x.chars().count() <= 80), "{all}");
    }

    #[test]
    fn no_figures_or_a_stale_snapshot_opens_the_fold_and_says_why() {
        let mut t = token_fixture(false);
        t.langfuse = LangfuseView {
            figures: None,
            why: Some("no key (rbw langfuse-api)".into()),
        };
        let l = lf_text(Some(&t), None, 80);
        assert!(l[0].contains("no figures in snapshot 2026-11-05"), "{l:?}");
        assert_eq!(l[1].trim(), "no key (rbw langfuse-api)");
        assert_eq!(lf_text(Some(&t), Some(false), 80).len(), 1);
        let stale = token_fixture(true);
        let l = lf_text(Some(&stale), None, 80);
        assert!(
            l[0].starts_with("- WHAT") && l[0].contains("stale 2026-11-05: tool 2%, gateway 13%"),
            "{l:?}"
        );
    }

    fn token_text(t: Option<&Tokens>, v: TokensView, w: usize) -> Vec<String> {
        tokens(t, v, Palette::default(), NOW, w)
            .iter()
            .map(crate::fit::plain)
            .collect()
    }

    #[test]
    fn the_tokens_fold_starts_open_and_folds_to_one_line() {
        let t = token_fixture(false);
        let l = token_text(Some(&t), TokensView::default(), 80);
        assert!(
            l[0].starts_with("- WHERE THE TOKENS GO") && l.len() > 1,
            "{l:?}"
        );
        let shut = TokensView {
            open: Some(false),
            day: false,
        };
        let l = token_text(Some(&t), shut, 80);
        assert_eq!(
            l,
            ["+ WHERE THE TOKENS GO  7d 18.0B, tool output 15%  u opens it"]
        );
    }

    #[test]
    fn a_stale_snapshot_opens_the_fold_and_says_so_until_it_is_folded() {
        let t = token_fixture(true);
        let l = token_text(Some(&t), TokensView::default(), 80);
        assert!(l[0].starts_with("- WHERE THE TOKENS GO"), "{l:?}");
        assert!(l[0].contains("stale, 2026-11-05"), "{l:?}");
        assert!(l.len() > 1);
        let shut = TokensView {
            open: Some(false),
            day: false,
        };
        assert_eq!(token_text(Some(&t), shut, 80).len(), 1);
    }

    #[test]
    fn no_snapshot_is_a_head_with_nothing_to_open() {
        let l = token_text(None, TokensView::default(), 80);
        assert_eq!(l.len(), 1);
        assert!(l[0].contains("no snapshot"), "{l:?}");
        let open = TokensView {
            open: Some(true),
            day: false,
        };
        assert!(!open.is_open(None));
    }

    #[test]
    fn open_it_draws_the_window_and_both_tables_in_80_columns() {
        let t = token_fixture(false);
        let mut v = TokensView {
            open: Some(true),
            day: false,
        };
        let l = token_text(Some(&t), v, 80);
        let all = l.join("\n");
        assert!(all.contains("7d: 18.0B context, 120k/response"), "{all}");
        assert!(
            all.contains("BY TOOL") && all.contains("BY BASH COMMAND"),
            "{all}"
        );
        assert!(all.contains("Bash") && all.contains("82.3%"), "{all}");
        assert!(all.contains("Other (22)") && all.contains("sed"), "{all}");
        assert!(l.iter().all(|x| x.chars().count() <= 80), "{all}");
        v.day = true;
        let all = token_text(Some(&t), v, 80).join("\n");
        assert!(all.contains("yesterday: 3.9B context"), "{all}");
        let stale = Tokens {
            stale: true,
            date: "2026-11-02".into(),
            ..t.clone()
        };
        let all = token_text(Some(&stale), v, 80).join("\n");
        assert!(all.contains("2026-11-02: 3.9B context"), "{all}");
    }
}
