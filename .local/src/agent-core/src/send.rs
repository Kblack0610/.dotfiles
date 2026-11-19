//! Typing a message into a Claude pane: the one implementation. agent-web (the page's send box),
//! `agent-panel send` and through it `agent-ask answer` and fleet-shepherd's close all come here.
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
//!
//! One sender types into a pane at a time: `message` (and `dialog::answer_in`) hold the pane's
//! lock (`lock_pane`) from the first look through the last Enter, so two senders never land in
//! one input box together. A sender that cannot get it within `LOCK_WAIT` types nothing and
//! fails with `Busy`, which `agent-panel` exits `BUSY_EXIT` on.

use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::tmux;
use crate::vocab::state_home;

/// How long a send waits for another sender to finish with the same pane. A send takes at most
/// about 6s (the settle and two Enter checks, `POLLS` each) and a dialog answer about 8s (its key,
/// the 2s move wait, then a send), so this covers one answer or two sends in front.
pub const LOCK_WAIT: Duration = Duration::from_secs(20);

/// `agent-panel`'s exit on `Busy`: 75, EX_TEMPFAIL, the code agent-queue's lock timeout uses.
pub const BUSY_EXIT: i32 = 75;

/// Another sender held the pane past the wait. Nothing was typed: the caller may try again.
#[derive(Debug)]
pub struct Busy {
    pub pane: String,
    pub waited: Duration,
}

impl std::fmt::Display for Busy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}: another send held it for {}s; nothing was typed",
            self.pane,
            self.waited.as_secs()
        )
    }
}

impl std::error::Error for Busy {}

/// A held pane lock; dropping it releases the pane.
pub struct PaneLock(#[allow(dead_code)] File);

/// The pane locks' directory: `agent-send` under the state home, the one every sender resolves the
/// same way (a timer's env has no `$XDG_RUNTIME_DIR`, and two homes would be two locks).
pub fn lock_dir() -> PathBuf {
    state_home().join("agent-send")
}

/// `<server>.<pane id number>`: one lock per pane whatever form its target takes, so a
/// `<server>/<session>:<window>` target is resolved to the pane id tmux would type into. A target
/// with no server is on the server tmux itself would pick: the one we are inside, else `default`.
fn pane_key(target: &str) -> Result<String> {
    let (server, local) = tmux::split(target);
    let name = server
        .map(str::to_string)
        .or_else(tmux::current_server)
        .unwrap_or_else(|| "default".to_string());
    let id = if local.starts_with('%') {
        local.to_string()
    } else {
        let out = tmux::tmux(server)
            .args(["display-message", "-p", "-t", local, "#{pane_id}"])
            .output()?;
        let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !out.status.success() || !id.starts_with('%') {
            bail!("{target}: no such pane");
        }
        id
    };
    Ok(format!("{name}.{}", id.trim_start_matches('%')))
}

/// Take the send lock of the pane at `target` (`<server>/<pane>`), waiting up to `wait`: the
/// flock (std's `File::lock`) on `<dir>/<pane_key>.lock`, `dir` being `lock_dir()` but in tests.
/// A blocking lock has no timeout, so it waits in a thread and the caller waits on that thread's
/// answer for `wait`, an event and not a poll. A thread left waiting past the bound drops the
/// lock the moment it gets it, since no one is left to hand it to.
pub fn lock_pane(dir: &Path, target: &str, wait: Duration) -> Result<PaneLock> {
    let key = pane_key(target)?;
    std::fs::create_dir_all(dir).with_context(|| format!("{}", dir.display()))?;
    let path = dir.join(format!("{key}.lock"));
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .with_context(|| format!("{}", path.display()))?;
    match file.try_lock() {
        Ok(()) => return Ok(PaneLock(file)),
        Err(TryLockError::WouldBlock) => {}
        Err(TryLockError::Error(e)) => return Err(e).context(path.display().to_string()),
    }
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(file.lock().map(|()| file));
    });
    match rx.recv_timeout(wait) {
        Ok(Ok(file)) => Ok(PaneLock(file)),
        Ok(Err(e)) => Err(e).context(path.display().to_string()),
        Err(_) => Err(Busy {
            pane: target.to_string(),
            waited: wait,
        }
        .into()),
    }
}

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

/// Type `text` into the pane at `target` (`<server>/<pane>`), submitting it unless `submit` is
/// false, holding the pane's lock throughout. `Busy` when another sender kept it past `wait`
/// (`LOCK_WAIT` unless the caller would rather retry later than wait).
pub fn message(target: &str, text: &str, submit: bool, wait: Duration) -> Result<Sent> {
    if text.is_empty() {
        bail!("nothing to send");
    }
    let _held = lock_pane(&lock_dir(), target, wait)?;
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

    /// A lock directory of the test's own, removed by the caller.
    fn lock_test_dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("agent-send-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn a_send_to_a_pane_another_send_holds_types_nothing_and_is_busy() {
        let dir = lock_test_dir("busy");
        let first = lock_pane(&dir, "lab/%1", Duration::ZERO).unwrap();
        // The second send, as `message` runs it: the lock, then the paste and Enter.
        let mut p = Script::new(&["empty", "> hi", "> hi", "sent"]);
        let second = lock_pane(&dir, "lab/%1", Duration::from_millis(50))
            .and_then(|_held| deliver(&mut p, "hi", true, 40));
        let busy = second.unwrap_err();
        let busy = busy.downcast_ref::<super::Busy>().expect("a Busy error");
        assert_eq!(busy.pane, "lab/%1");
        assert!(p.log.is_empty(), "typed while held: {:?}", p.log);
        // Another pane is not held.
        lock_pane(&dir, "lab/%2", Duration::ZERO).unwrap();
        // Released, the same send goes through.
        drop(first);
        let _held = lock_pane(&dir, "lab/%1", Duration::from_millis(50)).unwrap();
        assert_eq!(deliver(&mut p, "hi", true, 40).unwrap(), Sent::Submitted);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_second_send_waits_for_the_first_to_finish_then_goes() {
        let dir = lock_test_dir("wait");
        let first = lock_pane(&dir, "lab/%1", Duration::ZERO).unwrap();
        let (tx, rx) = mpsc::channel();
        let d = dir.clone();
        let second = std::thread::spawn(move || {
            let held = lock_pane(&d, "lab/%1", LOCK_WAIT);
            tx.send(()).unwrap();
            held.map(|_| ())
        });
        // While the first holds the pane the second cannot have its lock. A bound on a wait for
        // something that must not happen: it can only fail when the lock is broken.
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
        drop(first);
        rx.recv_timeout(LOCK_WAIT).unwrap();
        second.join().unwrap().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_pane_lock_is_keyed_by_server_and_pane_id() {
        assert_eq!(pane_key("lab/%12").unwrap(), "lab.12");
        // No server: the one tmux picks, `default` outside tmux.
        if std::env::var_os("TMUX").is_none() {
            assert_eq!(pane_key("%12").unwrap(), "default.12");
        }
    }

    #[test]
    fn no_submit_pastes_only() {
        let mut p = Script::new(&["empty"]);
        assert_eq!(deliver(&mut p, "hi", false, 40).unwrap(), Sent::Typed);
        assert_eq!(p.log, ["paste hi"]);
    }
}
