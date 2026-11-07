//! Claude Code's two dialogs that wait on the human, read off the pane: the plan approval
//! (ExitPlanMode) and the question (AskUserQuestion). The one parser of their numbered options:
//! the questions panel answers through `answer`, and hub-core's approve-plan picks its digit here.
//!
//! The options come from the screen, never the transcript: their numbering and wording are the
//! dialog's own UI text (a "switch to BYPASS PERMISSIONS" choice shows only in some modes), and
//! the digit pressed must be the one on screen.

use std::process::Command;

use anyhow::{bail, Context, Result};

use crate::{send, tmux};

/// The line that heads the plan dialog; a permission prompt also offers "1. Yes", so options
/// are only read below this line.
pub const PLAN_PROMPT: &str = "Would you like to proceed?";
/// The plan dialog sits at the pane's foot: its header is within this many lines of the last.
pub const PLAN_PROMPT_FOOT: usize = 12;
/// The question dialog's footer, its last or nearly last line.
const QUESTION_FOOT: &str = "Enter to select";
/// How far above its footer a question dialog can reach: a question, up to 9 options with a
/// description line or two each, and the tab strip.
const QUESTION_REACH: usize = 40;
/// Options that open a text field instead of choosing.
const FREE_TEXT: [&str; 2] = ["Type something", "Tell Claude what to change"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Plan,
    Question,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opt {
    pub key: char,
    pub text: String,
    /// Picking it opens a text field to type the answer in.
    pub free: bool,
    /// The lines drawn under it (a question option's description).
    pub detail: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dialog {
    pub kind: Kind,
    /// The question's own lines (the bar-marked block); empty for a plan, whose text is the plan file.
    pub title: Vec<String>,
    /// A multi-question dialog's tab strip, as drawn.
    pub tabs: String,
    pub options: Vec<Opt>,
}

impl Dialog {
    pub fn option(&self, key: char) -> Option<&Opt> {
        self.options.iter().find(|o| o.key == key)
    }
}

/// The dialog open at the foot of a `capture-pane -p` capture, or None when it shows none.
pub fn parse(capture: &str) -> Option<Dialog> {
    let lines: Vec<&str> = capture.lines().map(str::trim_end).filter(|l| !l.trim().is_empty()).collect();
    plan(&lines).or_else(|| question(&lines))
}

fn plan(lines: &[&str]) -> Option<Dialog> {
    let head = lines.iter().rposition(|l| l.contains("plan") && l.contains(PLAN_PROMPT))?;
    if lines.len() - head > PLAN_PROMPT_FOOT {
        return None;
    }
    let options = options(&lines[head + 1..]);
    (!options.is_empty()).then(|| Dialog { kind: Kind::Plan, title: vec![], tabs: String::new(), options })
}

fn question(lines: &[&str]) -> Option<Dialog> {
    let foot = lines.iter().rposition(|l| l.contains(QUESTION_FOOT))?;
    if lines.len() - foot > 2 {
        return None;
    }
    let from = foot.saturating_sub(QUESTION_REACH);
    let body = &lines[from..foot];
    // The question is the last bar-marked block above the options; the tab strip, when there
    // is one, is the left-arrow line above it.
    let bar = |l: &str| l.trim_start().starts_with('│');
    let last_bar = body.iter().rposition(|l| bar(l))?;
    let first_bar = body[..=last_bar].iter().rposition(|l| !bar(l)).map_or(0, |i| i + 1);
    let title = body[first_bar..=last_bar]
        .iter()
        .map(|l| l.trim_start().trim_start_matches('│').trim().to_string())
        .collect();
    let tabs = body[..first_bar]
        .iter()
        .rev()
        .take(2)
        .find(|l| l.trim_start().starts_with('←'))
        .map(|l| l.trim().to_string())
        .unwrap_or_default();
    let options = options(&body[last_bar + 1..]);
    (!options.is_empty()).then_some(Dialog { kind: Kind::Question, title, tabs, options })
}

/// Width of a line's lead, the selection marker counted as blank.
fn indent(l: &str) -> usize {
    l.chars().take_while(|c| c.is_whitespace() || *c == '\u{276f}').count()
}

/// `N. text` lines at the dialog's option indent, each with the more indented lines under it.
/// Rules and footers between them are skipped.
fn options(lines: &[&str]) -> Vec<Opt> {
    let mut out: Vec<(usize, Opt)> = Vec::new();
    for l in lines {
        let lead = indent(l);
        let rest = l.trim_start().trim_start_matches('\u{276f}').trim_start();
        let numbered = rest.split_once(". ").and_then(|(n, text)| {
            let mut d = n.chars();
            match (d.next(), d.next()) {
                (Some(c), None) if c.is_ascii_digit() && c != '0' => Some((c, text.trim())),
                _ => None,
            }
        });
        match (numbered, out.last_mut()) {
            (Some((key, text)), _) if lead <= 4 => out.push((
                lead,
                Opt {
                    key,
                    text: text.to_string(),
                    free: FREE_TEXT.iter().any(|f| text.starts_with(f)),
                    detail: vec![],
                },
            )),
            (_, Some((at, last))) if lead > *at + 1 && !rest.starts_with("──") => last.detail.push(rest.to_string()),
            _ => {}
        }
    }
    out.into_iter().map(|(_, o)| o).collect()
}

/// What an answer did.
#[derive(Debug, PartialEq, Eq)]
pub enum Answered {
    Sent,
    /// The pane shows no dialog, or option `key` no longer reads as the human saw it.
    Gone(String),
    /// The keys went in but the dialog did not move on.
    NotTaken,
}

/// The side of an answer that touches the pane, so the order is tested without tmux.
pub trait Keys: send::Pane {
    fn key(&mut self, key: &str) -> Result<()>;
}

/// Press option `key` of the dialog open in `pane`, after checking it still reads `expect`; a
/// free-text option then gets `text` typed into the field it opens and Enter.
pub fn answer(pane: &mut impl Keys, key: char, expect: &str, text: &str, polls: u32) -> Result<Answered> {
    let before = pane.capture();
    let Some(d) = parse(&before) else { return Ok(Answered::Gone("no dialog is open there now".into())) };
    let Some(opt) = d.option(key) else { return Ok(Answered::Gone(format!("the dialog has no option {key} now"))) };
    if !expect.is_empty() && opt.text != expect {
        return Ok(Answered::Gone(format!("option {key} now reads \"{}\"", opt.text)));
    }
    if opt.free && text.is_empty() {
        bail!("option {key} takes a typed answer");
    }
    // A pane left in copy mode would take the digit as a copy-mode key.
    pane.key("copy-mode-exit")?;
    pane.key(&key.to_string())?;
    if !moved(pane, &before, polls) {
        return Ok(Answered::NotTaken);
    }
    if opt.free {
        return match send::deliver(pane, text, true, polls)? {
            send::Sent::NotSubmitted => Ok(Answered::NotTaken),
            _ => Ok(Answered::Sent),
        };
    }
    Ok(Answered::Sent)
}

/// The screen changed from `before` within the polls.
fn moved(pane: &mut impl Keys, before: &str, polls: u32) -> bool {
    for _ in 0..polls {
        if pane.capture() != before {
            return true;
        }
        pane.pause();
    }
    false
}

/// A real pane presses keys with `send-keys`, and `copy-mode -q` to leave copy mode.
impl Keys for send::TmuxPane<'_> {
    fn key(&mut self, key: &str) -> Result<()> {
        let (server, local) = tmux::split(self.target);
        let server = server.context("pane target has no server")?;
        let args: Vec<&str> = if key == "copy-mode-exit" {
            vec!["copy-mode", "-q", "-t", local]
        } else {
            vec!["send-keys", "-t", local, key]
        };
        if !Command::new("tmux").args(["-L", server]).args(&args).status()?.success() {
            bail!("tmux {} failed on {}", args[0], self.target);
        }
        Ok(())
    }
}

/// The live agent at a `<server>/<session>:<window>` target.
fn agent(target: &str) -> Result<crate::chooser::Agent> {
    crate::chooser::collect().into_iter().find(|a| a.target == target).with_context(|| format!("no live agent at {target}"))
}

/// `agent-panel dialog <target>`: the card for the dialog open in that session, or with
/// `options` its options as `<key>\t<free 0|1>\t<text>` lines. Exits 1 when it shows none.
pub fn run_card(target: &str, options: bool) -> Result<()> {
    let a = agent(target)?;
    let Some(d) = parse(&tmux::capture_pane(&a.pane, false, 0)) else { std::process::exit(1) };
    if options {
        for o in &d.options {
            println!("{}\t{}\t{}", o.key, u8::from(o.free), o.text);
        }
        return Ok(());
    }
    let color = std::env::var("AGENT_ASK_COLOR").is_ok_and(|v| v == "1");
    let plan = Plan::of(&d, a.jsonl.as_deref().and_then(crate::jsonl::open_plan_at));
    print!("{}", card(&d, &format!("{}  {}", a.target, a.project), plan, color, crate::md::width()));
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
    /// The plan for `d`, given the open plan its transcript holds (`jsonl::open_plan_at`).
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
    let (bold, dim, off) = if color { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    let mut s = String::new();
    let _ = match d.kind {
        Kind::Plan => writeln!(s, "{bold}plan waiting for your approval{off}"),
        Kind::Question => writeln!(s, "{bold}question waiting for your answer{off}"),
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
        let typed = if o.free { format!("  {dim}(t types it){off}") } else { String::new() };
        let _ = writeln!(s, " {bold}{}{off}  {}{typed}", o.key, o.text);
        for l in &o.detail {
            let _ = writeln!(s, "    {dim}{l}{off}");
        }
    }
    let _ = match plan {
        Plan::Text(text) => writeln!(s, "\n{bold}the plan{off}\n\n{}", crate::md::plain(&text, width)),
        Plan::Unread => writeln!(s, "\n{dim}(the plan text is in its session; g goes there){off}"),
        Plan::None => Ok(()),
    };
    s
}

/// `agent-panel answer <target> <key> --expect <text> [typed]`: exit 0 sent, 3 not taken,
/// 4 the dialog is gone or changed (the reason on stderr).
pub fn run_answer(target: &str, key: char, expect: &str, text: &str) -> Result<()> {
    let a = agent(target)?;
    match answer(&mut send::TmuxPane { target: &a.pane }, key, expect, text, send::POLLS)? {
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

    pub const PLAN_PANE: &str = "\
\u{25cf} I wrote a 2-line plan.
\u{2500}\u{2500}\u{2500}
 Claude has written up a plan and is ready to execute. Would you like to proceed?

 \u{276f} 1. Yes, and switch to BYPASS PERMISSIONS (no further prompts) for this session
   2. Yes, manually approve edits
   3. Tell Claude what to change
      shift+tab to approve with this feedback

 ctrl+g to edit in Nvim \u{b7} ~/.claude/plans/plan.md
";

    const QUESTION_PANE: &str = "\
\u{25cf} Fetch(https://example.org)
\u{2500}\u{2500}\u{2500}
Planning: /home/u/.claude/plans/p.md
\u{2500}\u{2500}\u{2500}
\u{2190}  \u{2610} Mission  \u{2610} Budget  \u{2714} Submit  \u{2192}

\u{2502} What should the drones do? This decides indoor vs outdoor
\u{2502} apply.

\u{276f} 1. Outdoor yard patrol
     Scheduled flights around the property.
  2. Indoor house patrol
     Small drone, room to room.
  3. Type something.
\u{2500}\u{2500}\u{2500}
  4. Chat about this

Enter to select \u{b7} Tab/Arrow keys to navigate \u{b7} Esc to cancel
";

    const PERMISSION_PANE: &str = "\
 Create file
 Do you want to create plan-creating-hello-txt.md?
 \u{276f} 1. Yes
   2. Yes, and always allow access to ~/.claude/plans for this session (shift+tab)
   3. No
 Esc to cancel \u{b7} Tab to amend
";

    #[test]
    fn the_card_puts_the_options_before_the_plan_and_reads_the_plan_as_plain_text() {
        let d = parse(PLAN_PANE).unwrap();
        let c = card(&d, "hub/s:1  dotfiles", Plan::Text("## Context\n\n**Bold** `code`".into()), false, 40);
        assert!(c.starts_with("plan waiting for your approval\nhub/s:1  dotfiles\n"), "{c}");
        let (opts, plan) = (c.find(" 3  Tell Claude what to change  (t types it)").unwrap(), c.find("the plan").unwrap());
        assert!(opts < plan, "{c}");
        assert!(c.ends_with("the plan\n\nContext\n\nBold code\n"), "{c}");
        // Negative control: no plan in the transcript says where it is; a question has no plan line.
        assert!(card(&d, "x", Plan::Unread, false, 40).contains("(the plan text is in its session; g goes there)"));
        assert!(!card(&parse(QUESTION_PANE).unwrap(), "x", Plan::None, false, 40).contains("the plan"));
    }

    #[test]
    fn reads_the_plan_dialog_options() {
        let d = parse(PLAN_PANE).unwrap();
        assert_eq!(d.kind, Kind::Plan);
        let keys: Vec<(char, bool)> = d.options.iter().map(|o| (o.key, o.free)).collect();
        assert_eq!(keys, [('1', false), ('2', false), ('3', true)]);
        assert_eq!(d.options[1].text, "Yes, manually approve edits");
        assert_eq!(d.options[2].detail, ["shift+tab to approve with this feedback"]);
        // An old dialog scrolled far above the foot is not open any more.
        assert_eq!(parse(&format!("{PLAN_PANE}{}", "output\n".repeat(PLAN_PROMPT_FOOT))), None);
    }

    #[test]
    fn reads_the_question_dialog() {
        let d = parse(QUESTION_PANE).unwrap();
        assert_eq!(d.kind, Kind::Question);
        assert_eq!(d.title, ["What should the drones do? This decides indoor vs outdoor", "apply."]);
        assert!(d.tabs.contains("Mission"));
        let texts: Vec<&str> = d.options.iter().map(|o| o.text.as_str()).collect();
        assert_eq!(texts, ["Outdoor yard patrol", "Indoor house patrol", "Type something.", "Chat about this"]);
        assert_eq!(d.options[0].detail, ["Scheduled flights around the property."]);
        assert!(d.options[2].free && !d.options[3].free);
    }

    #[test]
    fn a_permission_prompt_or_plain_output_is_no_dialog() {
        assert_eq!(parse(PERMISSION_PANE), None);
        assert_eq!(parse("1. a list item\n2. another\n"), None);
        assert_eq!(parse(""), None);
    }

    /// A scripted pane: each capture returns the next screen (the last repeats); keys are logged.
    struct Script {
        screens: Vec<String>,
        at: usize,
        log: Vec<String>,
    }
    impl send::Pane for Script {
        fn capture(&mut self) -> String {
            let s = self.screens[self.at.min(self.screens.len() - 1)].clone();
            self.at += 1;
            s
        }
        fn paste(&mut self, text: &str) -> Result<()> {
            self.log.push(format!("paste {text}"));
            Ok(())
        }
        fn enter(&mut self) -> Result<()> {
            self.log.push("Enter".into());
            Ok(())
        }
        fn pause(&mut self) {}
    }
    impl Keys for Script {
        fn key(&mut self, key: &str) -> Result<()> {
            self.log.push(key.into());
            Ok(())
        }
    }
    fn script(screens: &[&str]) -> Script {
        Script { screens: screens.iter().map(|s| s.to_string()).collect(), at: 0, log: vec![] }
    }

    #[test]
    fn presses_the_digit_when_the_option_still_reads_the_same() {
        let mut p = script(&[PLAN_PANE, "working..."]);
        assert_eq!(answer(&mut p, '2', "Yes, manually approve edits", "", 5).unwrap(), Answered::Sent);
        assert_eq!(p.log, ["copy-mode-exit", "2"]);
    }

    #[test]
    fn refuses_when_the_dialog_changed_or_closed() {
        let mut p = script(&[PLAN_PANE]);
        assert!(matches!(answer(&mut p, '2', "Yes, auto-accept edits", "", 5).unwrap(), Answered::Gone(_)));
        let mut p = script(&["just output"]);
        assert!(matches!(answer(&mut p, '1', "", "", 5).unwrap(), Answered::Gone(_)));
        let mut p = script(&[PLAN_PANE]);
        assert!(matches!(answer(&mut p, '7', "", "", 5).unwrap(), Answered::Gone(_)));
        // Nothing was pressed on any of them.
        assert!(p.log.is_empty());
    }

    #[test]
    fn a_free_text_option_types_the_answer_into_its_field() {
        let field = format!("{PLAN_PANE}\n\u{2500}\u{2500}\n> \n\u{2500}\u{2500}\n");
        let typed = format!("{PLAN_PANE}\n\u{2500}\u{2500}\n> split it in two\n\u{2500}\u{2500}\n");
        let mut p = script(&[PLAN_PANE, &field, &field, &typed, &typed, "working..."]);
        assert_eq!(answer(&mut p, '3', "Tell Claude what to change", "split it in two", 5).unwrap(), Answered::Sent);
        assert_eq!(p.log, ["copy-mode-exit", "3", "paste split it in two", "Enter"]);
        let mut p = script(&[PLAN_PANE]);
        assert!(answer(&mut p, '3', "", "", 5).is_err(), "a free-text option needs the text");
    }

    #[test]
    fn a_digit_the_pane_ignores_is_not_taken() {
        let mut p = script(&[PLAN_PANE]);
        assert_eq!(answer(&mut p, '1', "", "", 3).unwrap(), Answered::NotTaken);
    }
}
