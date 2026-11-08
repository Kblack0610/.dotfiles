//! Typing a message into a Claude pane: the one implementation. agent-web (the page's send box),
//! `agent-panel send` and through it `agent-ask answer` all come here.
//!
//! Claude Code drops an Enter that arrives on the heels of a paste, which leaves the message
//! sitting unsent in its input box until the human next types there. So the text goes in as a
//! bracketed paste, the input box is sampled until it has drawn the paste and held still, and
//! only then is Enter pressed. After the Enter the box must change again: a box that still shows
//! the settled paste means the Enter was dropped, so it is pressed once more, and a second drop
//! is reported to the caller instead of passing as sent.
//!
//! Both checks read only the input box (`input_box`), never the whole screen: a busy pane redraws
//! its spinner and timer every frame, which would pass for the paste drawn and the Enter taken.

use std::process::Command;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::tmux;

/// Sampling a pane while it draws. tmux has no event for "the program in this pane has read its
/// input", so this is the one bounded loop on one cadence. 40 samples is 2s.
pub const POLL: Duration = Duration::from_millis(50);
pub const POLLS: u32 = 40;

/// The samples read the visible screen only (`-S 0`): the input box is at its bottom, and rules
/// in the scrollback must not be taken for the box's.
const SCREEN_LINES: i32 = 0;

/// What a send did.
#[derive(Debug, PartialEq, Eq)]
pub enum Sent {
    /// Pasted and submitted: the input box changed after the Enter.
    Submitted,
    /// Pasted with no Enter, as asked.
    Typed,
    /// The input box did not change after the Enter, twice: the text is probably still in it.
    NotSubmitted,
}

/// The pane side of a send, so the order of paste, settle and Enter is tested without tmux.
pub trait Pane {
    fn capture(&mut self) -> String;
    fn paste(&mut self, text: &str) -> Result<()>;
    fn enter(&mut self) -> Result<()>;
    fn pause(&mut self);
}

/// Paste `text`, and with `submit` press Enter once the paste is drawn, then confirm it was taken.
pub fn deliver(pane: &mut impl Pane, text: &str, submit: bool, polls: u32) -> Result<Sent> {
    let before = look(pane);
    pane.paste(text)?;
    if !submit {
        return Ok(Sent::Typed);
    }
    // A box that never settles (not a Claude pane, or text still arriving) gets its Enter
    // regardless, once, and the result cannot be judged from the screen, so it counts as submitted.
    let Some(shown) = settle_on(pane, &before, polls) else {
        pane.enter()?;
        return Ok(Sent::Submitted);
    };
    for _ in 0..2 {
        pane.enter()?;
        if moved_on(pane, &shown, polls) {
            return Ok(Sent::Submitted);
        }
    }
    Ok(Sent::NotSubmitted)
}

/// Wait until the pane has moved away from `before` and then held still for one sample: the
/// settled screen, or None when it never settled within `polls`.
fn settle_on(pane: &mut impl Pane, before: &str, polls: u32) -> Option<String> {
    let mut last: Option<String> = None;
    for _ in 0..polls {
        let now = look(pane);
        if now != before && last.as_deref() == Some(now.as_str()) {
            return Some(now);
        }
        last = Some(now);
        pane.pause();
    }
    None
}

/// Whether the pane moves away from `screen` within `polls` samples.
fn moved_on(pane: &mut impl Pane, screen: &str, polls: u32) -> bool {
    for _ in 0..polls {
        if look(pane) != screen {
            return true;
        }
        pane.pause();
    }
    false
}

/// What a send judges a pane by: its input box when it has one, else the whole capture.
fn look(pane: &mut impl Pane) -> String {
    input_box(&pane.capture()).to_string()
}

/// Claude Code's input box in a capture: the lines between the last two rules, the borders it
/// draws at column 0 (`────` lines, or the older `╭──╮` and `╰──╯`). The spinner, the transcript
/// and a queued message all sit above the top rule, the status line below the bottom one. A
/// capture without two rules is not a Claude pane and is returned whole.
fn input_box(screen: &str) -> &str {
    let is_rule = |l: &str| {
        l.starts_with("──") || ((l.starts_with('╭') || l.starts_with('╰')) && l.contains("──"))
    };
    let mut ends = vec![];
    let mut at = 0;
    for line in screen.split_inclusive('\n') {
        if is_rule(line) {
            ends.push((at, at + line.len()));
        }
        at += line.len();
    }
    match ends.as_slice() {
        [.., (_, top_end), (bottom, _)] => &screen[*top_end..*bottom],
        _ => screen,
    }
}

/// A real tmux pane, by `<server>/<pane>` target as `agent-panel list --json` prints `pane`.
pub struct TmuxPane<'a> {
    pub target: &'a str,
}

impl TmuxPane<'_> {
    fn tmux(&self, args: &[&str], stdin: Option<&str>) -> Result<()> {
        let (server, local) = tmux::split(self.target);
        let server = server.context("pane target has no server")?;
        let mut c = Command::new("tmux");
        c.args(["-L", server])
            .args(args.iter().map(|a| if *a == "{pane}" { local } else { a }));
        let ok = match stdin {
            Some(text) => {
                use std::io::Write;
                let mut child = c.stdin(std::process::Stdio::piped()).spawn()?;
                child
                    .stdin
                    .take()
                    .context("tmux stdin")?
                    .write_all(text.as_bytes())?;
                child.wait()?.success()
            }
            None => c.status()?.success(),
        };
        if !ok {
            bail!("tmux {} failed on {}", args[0], self.target);
        }
        Ok(())
    }
}

impl Pane for TmuxPane<'_> {
    fn capture(&mut self) -> String {
        tmux::capture_pane(self.target, false, SCREEN_LINES)
    }
    // A bracketed paste, not send-keys -l: a newline inside the text stays part of the message
    // instead of submitting it half-written. The buffer is per process, so two senders at once
    // never paste each other's text.
    fn paste(&mut self, text: &str) -> Result<()> {
        let buf = format!("agent-send-{}", std::process::id());
        self.tmux(&["load-buffer", "-b", &buf, "-"], Some(text))?;
        self.tmux(
            &["paste-buffer", "-p", "-d", "-b", &buf, "-t", "{pane}"],
            None,
        )
    }
    fn enter(&mut self) -> Result<()> {
        self.tmux(&["send-keys", "-t", "{pane}", "Enter"], None)
    }
    fn pause(&mut self) {
        std::thread::sleep(POLL);
    }
}

/// Type `text` into the pane at `target` (`<server>/<pane>`), submitting it unless `submit` is false.
pub fn message(target: &str, text: &str, submit: bool) -> Result<Sent> {
    if text.is_empty() {
        bail!("nothing to send");
    }
    deliver(&mut TmuxPane { target }, text, submit, POLLS)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scripted pane: `screens` is what each capture returns in turn (the last one repeats),
    /// and every paste, enter and pause is logged.
    struct Script {
        screens: Vec<&'static str>,
        at: usize,
        log: Vec<String>,
    }

    impl Script {
        fn new(screens: &[&'static str]) -> Self {
            Script {
                screens: screens.to_vec(),
                at: 0,
                log: vec![],
            }
        }
    }

    impl Pane for Script {
        fn capture(&mut self) -> String {
            let s = self.screens[self.at.min(self.screens.len() - 1)];
            self.at += 1;
            s.to_string()
        }
        fn paste(&mut self, text: &str) -> Result<()> {
            self.log.push(format!("paste {text}"));
            Ok(())
        }
        fn enter(&mut self) -> Result<()> {
            self.log.push(format!("enter@{}", self.at));
            Ok(())
        }
        fn pause(&mut self) {}
    }

    #[test]
    fn enter_waits_for_the_paste_to_be_drawn_and_still() {
        // before, the paste not drawn yet, drawn, drawn again (still) -> Enter, then the
        // message leaves the input box.
        let mut p = Script::new(&["empty", "empty", "> hi", "> hi", "sent: hi"]);
        assert_eq!(deliver(&mut p, "hi", true, 40).unwrap(), Sent::Submitted);
        assert_eq!(p.log, ["paste hi", "enter@4"]);
    }

    #[test]
    fn a_dropped_enter_is_pressed_once_more() {
        let mut p = Script::new(&["empty", "> hi", "> hi", "> hi", "> hi", "sent: hi"]);
        assert_eq!(deliver(&mut p, "hi", true, 2).unwrap(), Sent::Submitted);
        assert_eq!(p.log.iter().filter(|l| l.starts_with("enter")).count(), 2);
    }

    #[test]
    fn two_dropped_enters_are_reported_not_passed_as_sent() {
        let mut p = Script::new(&["empty", "> hi", "> hi"]);
        assert_eq!(deliver(&mut p, "hi", true, 3).unwrap(), Sent::NotSubmitted);
        assert_eq!(p.log.iter().filter(|l| l.starts_with("enter")).count(), 2);
    }

    #[test]
    fn a_pane_that_never_settles_gets_one_enter() {
        let mut p = Script::new(&["a", "b", "c", "d", "e"]);
        assert_eq!(deliver(&mut p, "hi", true, 4).unwrap(), Sent::Submitted);
        assert_eq!(p.log, ["paste hi", "enter@5"]);
    }

    // A busy Claude pane: a spinner whose timer changes on every capture above the ruled input
    // box, and a status line below it.
    fn busy(frame: usize, input: &str) -> String {
        format!("* Working... ({frame}s)\n\n────\n> {input}\n────\n  esc to interrupt\n")
    }

    /// A scripted busy pane: the box shows `boxes[i]` from capture i on (the last repeats), and
    /// the spinner moves on every capture, so the whole screen never holds still.
    struct Busy {
        boxes: Vec<&'static str>,
        at: usize,
        enters: Vec<usize>,
    }

    impl Pane for Busy {
        fn capture(&mut self) -> String {
            let s = busy(self.at, self.boxes[self.at.min(self.boxes.len() - 1)]);
            self.at += 1;
            s
        }
        fn paste(&mut self, _: &str) -> Result<()> {
            Ok(())
        }
        fn enter(&mut self) -> Result<()> {
            self.enters.push(self.at);
            Ok(())
        }
        fn pause(&mut self) {}
    }

    #[test]
    fn input_box_is_the_lines_between_the_last_two_rules() {
        assert_eq!(input_box(&busy(3, "hi")), "> hi\n");
        let old = "out\n╭────╮\n│ > hi │\n╰────╯\n  ? for shortcuts\n";
        assert_eq!(input_box(old), "│ > hi │\n");
        // Not a Claude pane: judged whole.
        assert_eq!(input_box("> hi"), "> hi");
    }

    #[test]
    fn a_busy_pane_gets_its_enter_once_the_box_shows_the_paste() {
        // The spinner differs on every capture; the box is empty for three, then holds the paste.
        let mut p = Busy {
            boxes: vec!["", "", "", "hi", "hi", "hi", ""],
            at: 0,
            enters: vec![],
        };
        assert_eq!(deliver(&mut p, "hi", true, 40).unwrap(), Sent::Submitted);
        assert_eq!(p.enters, [5]);
    }

    #[test]
    fn a_busy_pane_that_drops_the_enter_is_reported() {
        // Whole-screen comparison passed this as sent: the spinner moved after each Enter.
        let mut p = Busy {
            boxes: vec!["", "hi"],
            at: 0,
            enters: vec![],
        };
        assert_eq!(deliver(&mut p, "hi", true, 5).unwrap(), Sent::NotSubmitted);
        assert_eq!(p.enters.len(), 2);
    }

    #[test]
    fn no_submit_pastes_only() {
        let mut p = Script::new(&["empty"]);
        assert_eq!(deliver(&mut p, "hi", false, 40).unwrap(), Sent::Typed);
        assert_eq!(p.log, ["paste hi"]);
    }
}
