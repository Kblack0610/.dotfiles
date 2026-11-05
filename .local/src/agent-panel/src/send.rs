//! Typing a message into a Claude pane: the one implementation. agent-web (the page's send box),
//! `agent-panel send` and through it `agent-ask answer` all come here.
//!
//! Claude Code drops an Enter that arrives on the heels of a paste, which leaves the message
//! sitting unsent in its input box until the human next types there. So the text goes in as a
//! bracketed paste, the pane is sampled until it has drawn the paste and held still, and only
//! then is Enter pressed. After the Enter the pane must change again: a screen that still shows
//! the settled paste means the Enter was dropped, so it is pressed once more, and a second drop
//! is reported to the caller instead of passing as sent.

use std::process::Command;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::tmux;

/// Sampling a pane while it draws. tmux has no event for "the program in this pane has read its
/// input", so this is the one bounded loop on one cadence. 40 samples is 2s.
pub const POLL: Duration = Duration::from_millis(50);
pub const POLLS: u32 = 40;

/// Scrollback the samples compare: enough that a message moving up the screen shows as a change.
const SCREEN_LINES: i32 = -200;

/// What a send did.
#[derive(Debug, PartialEq, Eq)]
pub enum Sent {
    /// Pasted and submitted: the pane changed after the Enter.
    Submitted,
    /// Pasted with no Enter, as asked.
    Typed,
    /// The pane never moved after the Enter, twice: the text is probably still in the input box.
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
    let before = pane.capture();
    pane.paste(text)?;
    if !submit {
        return Ok(Sent::Typed);
    }
    // The pane that never settles (a spinner) gets its Enter regardless, once, and the result
    // cannot be judged from the screen, so it counts as submitted.
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
/// settled screen, or None when it never settled within `polls` (a running spinner, say).
fn settle_on(pane: &mut impl Pane, before: &str, polls: u32) -> Option<String> {
    let mut last: Option<String> = None;
    for _ in 0..polls {
        let now = pane.capture();
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
        if pane.capture() != screen {
            return true;
        }
        pane.pause();
    }
    false
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

    #[test]
    fn no_submit_pastes_only() {
        let mut p = Script::new(&["empty"]);
        assert_eq!(deliver(&mut p, "hi", false, 40).unwrap(), Sent::Typed);
        assert_eq!(p.log, ["paste hi"]);
    }
}
