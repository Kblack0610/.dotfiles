//! The card for a dialog open in a session (`agent_core::dialog`): one format for the questions
//! panel and the agent panel's preview, and the `dialog` and `answer` verbs that act on it.

use anyhow::{Context, Result};

use agent_core::agent::{collect, Agent};
use agent_core::dialog::{answer_in, parse, Answered, Dialog, Kind};
use agent_core::{tmux, transcript};

/// The live Claude at a `<server>/<session>:<window>` target: a row on another harness has no Claude dialog.
fn agent(target: &str) -> Result<Agent> {
    collect()
        .into_iter()
        .find(|a| a.target == target && a.harness.is_empty())
        .with_context(|| format!("no live agent at {target}"))
}

/// `agent-panel dialog <target>`: the card for the dialog open in that session, or with
/// `options` its options as `<key>\t<free 0|1>\t<text>` lines. Exits 1 when it shows none.
pub fn run_card(target: &str, options: bool) -> Result<()> {
    let a = agent(target)?;
    let Some(d) = parse(&tmux::capture_pane(&a.pane, false, 0)) else {
        std::process::exit(1)
    };
    if options {
        for o in &d.options {
            println!("{}\t{}\t{}", o.key, u8::from(o.free), o.text);
        }
        return Ok(());
    }
    let color = std::env::var("AGENT_ASK_COLOR").is_ok_and(|v| v == "1");
    let plan = Plan::of(&d, a.jsonl.as_deref().and_then(transcript::open_plan_at));
    print!(
        "{}",
        card(
            &d,
            &format!("{}  {}", a.target, a.project),
            plan,
            color,
            crate::md::width()
        )
    );
    Ok(())
}

/// What a dialog card shows under its options.
pub enum Plan {
    /// A question dialog: it has no plan.
    None,
    /// A plan dialog whose plan the transcript does not hold.
    Unread,
    /// A plan dialog's plan, from the session's transcript.
    Text(String),
}

impl Plan {
    /// The plan for `d`, given the open plan its transcript holds (`transcript::open_plan_at`).
    pub fn of(d: &Dialog, text: Option<String>) -> Plan {
        match (d.kind, text) {
            (Kind::Question, _) => Plan::None,
            (Kind::Plan, None) => Plan::Unread,
            (Kind::Plan, Some(t)) => Plan::Text(t),
        }
    }
}

/// The dialog's card, one format for the questions panel and the agent panel's preview: what it
/// waits for and `who`, the question and the options as the pane numbers them, then the plan
/// (`Plan`) as plain text folded at `width`. What to answer comes first; a plan can run to
/// pages, so it follows the options.
pub fn card(d: &Dialog, who: &str, plan: Plan, color: bool, width: usize) -> String {
    use std::fmt::Write;
    // The panels' palette (panel-palette.sh): ANSI indices, so a theme swap recolours the card.
    // The heading is the needs-you yellow, as the same ask's card in agent-ask.
    let (bold, head, dim, off) = if color {
        ("\x1b[1m", "\x1b[1;33m", "\x1b[90m", "\x1b[0m")
    } else {
        ("", "", "", "")
    };
    let mut s = String::new();
    let _ = match d.kind {
        Kind::Plan => writeln!(s, "{head}plan waiting for your approval{off}"),
        Kind::Question => writeln!(s, "{head}question waiting for your answer{off}"),
    };
    let _ = writeln!(s, "{dim}{who}{off}");
    if !d.tabs.is_empty() {
        let _ = writeln!(s, "{dim}{}{off}", d.tabs);
    }
    if !d.title.is_empty() {
        let _ = writeln!(s, "\n{}", d.title.join("\n"));
    }
    s.push('\n');
    for o in &d.options {
        let typed = if o.free {
            format!("  {dim}(t types it){off}")
        } else {
            String::new()
        };
        let _ = writeln!(s, " {bold}{}{off}  {}{typed}", o.key, o.text);
        for l in &o.detail {
            let _ = writeln!(s, "    {dim}{l}{off}");
        }
    }
    let _ = match plan {
        Plan::Text(text) => writeln!(
            s,
            "\n{bold}the plan{off}\n\n{}",
            crate::md::plain(&text, width)
        ),
        Plan::Unread => writeln!(
            s,
            "\n{dim}(the plan text is in its session; g goes there){off}"
        ),
        Plan::None => Ok(()),
    };
    s
}

/// `agent-panel answer <target> <key> --expect <text> [typed]`: exit 0 sent, 3 not taken,
/// 4 the dialog is gone or changed (the reason on stderr), 75 another send held the pane.
pub fn run_answer(target: &str, key: char, expect: &str, text: &str) -> Result<()> {
    let a = agent(target)?;
    match crate::or_busy_exit(answer_in(&a.pane, key, expect, text))? {
        Answered::Sent => Ok(()),
        Answered::NotTaken => {
            eprintln!("{target} did not take option {key}");
            std::process::exit(3)
        }
        Answered::Gone(why) => {
            eprintln!("{why}");
            std::process::exit(4)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_core::dialog::fixtures::{PLAN_PANE, QUESTION_PANE};

    #[test]
    fn the_card_puts_the_options_before_the_plan_and_reads_the_plan_as_plain_text() {
        let d = parse(PLAN_PANE).unwrap();
        let c = card(
            &d,
            "hub/s:1  dotfiles",
            Plan::Text("## Context\n\n**Bold** `code`".into()),
            false,
            40,
        );
        assert!(
            c.starts_with("plan waiting for your approval\nhub/s:1  dotfiles\n"),
            "{c}"
        );
        let (opts, plan) = (
            c.find(" 3  Tell Claude what to change  (t types it)")
                .unwrap(),
            c.find("the plan").unwrap(),
        );
        assert!(opts < plan, "{c}");
        assert!(c.ends_with("the plan\n\nContext\n\nBold code\n"), "{c}");
        // Negative control: no plan in the transcript says where it is; a question has no plan line.
        assert!(card(&d, "x", Plan::Unread, false, 40)
            .contains("(the plan text is in its session; g goes there)"));
        assert!(
            !card(&parse(QUESTION_PANE).unwrap(), "x", Plan::None, false, 40).contains("the plan")
        );
    }
}
