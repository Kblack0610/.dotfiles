//! Acting on a Claude session from agent-web or the hub TUI. Each action is the argv of the
//! command that already owns it, so this module writes nothing itself:
//!
//! | action    | owner                                                              |
//! |-----------|--------------------------------------------------------------------|
//! | interrupt | tmux: leave any pane mode, then send Escape to the agent's pane    |
//! | park      | `claude-acct park <tmux-session> --server S`                       |
//! | unpark    | `claude-acct unpark <tmux-session>`                                |
//! | move      | `claude-acct move <tmux-session> --server S --to <account>`        |
//! | stop      | tmux: type `/exit` as claude-acct park does, then `kill-window` as wind-down does |
//! | cancel    | `agent-queue cancel <slug>`, only for a session a queue item started |
//! | approve-plan | tmux: leave any pane mode, then press the plan dialog's "Yes, auto-accept edits" digit |
//!
//! `plan` refuses a target that is not a live or parked session right now and an account the
//! accounts file does not name, so neither surface can be pointed at an arbitrary pane or
//! account. Every step is an argv run without a shell; a `Runner` runs it, which tests fake.

use std::process::{Command, Stdio};

/// The agent row a `Snapshot` carries, so a caller needs no agent-panel dependency of its own.
pub use agent_panel::chooser::Agent;
use agent_panel::{account, chooser, tmux};
use serde::Serialize;

/// What a session can be asked to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Interrupt,
    Park,
    Unpark,
    Move,
    Stop,
    Cancel,
    ApprovePlan,
}

impl Action {
    pub const ALL: [Action; 7] = [
        Action::Interrupt,
        Action::Park,
        Action::Unpark,
        Action::Move,
        Action::Stop,
        Action::Cancel,
        Action::ApprovePlan,
    ];

    pub fn parse(s: &str) -> Option<Action> {
        Action::ALL.into_iter().find(|a| a.name() == s)
    }

    pub fn name(self) -> &'static str {
        match self {
            Action::Interrupt => "interrupt",
            Action::Park => "park",
            Action::Unpark => "unpark",
            Action::Move => "move",
            Action::Stop => "stop",
            Action::Cancel => "cancel",
            Action::ApprovePlan => "approve-plan",
        }
    }

    /// What the action does, for a confirm prompt.
    pub fn describe(self) -> &'static str {
        match self {
            Action::Interrupt => "press Escape in its pane (stops the current turn)",
            Action::Park => "exit its claude and keep the pane; unpark resumes it",
            Action::Unpark => "resume it in its pane on the account with room",
            Action::Move => "exit its claude and resume it on the chosen account",
            Action::Stop => "type /exit and close its tmux window",
            Action::Cancel => "cancel its queue item, which kills its tmux session",
            Action::ApprovePlan => {
                "accept its plan: press \"Yes, auto-accept edits\" in its plan dialog"
            }
        }
    }
}

/// One session as the actions see it: a row of `agent_panel::chooser::collect_all`, plus the
/// queue item that started it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Session {
    /// `<server>/<session>:<window>`: what a caller names the session by.
    pub target: String,
    pub server: String,
    pub tmux_session: String,
    /// The agent's pane, `%N` on `server`.
    pub pane: String,
    /// The agent's window, `@N` on `server`; empty for a parked row.
    pub window_id: String,
    /// The claude process; 0 when parked or unknown.
    pub pid: u32,
    pub parked: bool,
    pub attached: bool,
    pub account: String,
    /// The agent-queue slug whose item runs in this tmux session.
    pub item: Option<String>,
    /// The digit that accepts the plan, while its pane shows the plan dialog.
    pub approve_key: Option<char>,
}

impl From<&chooser::Agent> for Session {
    fn from(a: &chooser::Agent) -> Self {
        Session {
            target: a.target.clone(),
            server: a.server.clone(),
            tmux_session: a.tmux_session.clone(),
            pane: tmux::split(&a.pane).1.to_string(),
            window_id: a.window_id.clone(),
            pid: a.pid,
            parked: a.parked,
            attached: a.attached,
            account: a.account.clone(),
            item: None,
            approve_key: None,
        }
    }
}

/// The line that heads Claude Code's plan dialog; a permission prompt also offers "1. Yes", so
/// the digit is only read below this line.
const PLAN_PROMPT: &str = "Would you like to proceed?";
/// The dialog sits at the pane's foot: its header is within this many lines of the last one.
const PLAN_PROMPT_FOOT: usize = 12;

/// The digit of "Yes, auto-accept edits" (else the first "Yes" option) in the plan dialog at the
/// foot of a `capture-pane -p` capture, or None when the pane shows no plan dialog.
pub fn plan_approve_key(pane: &str) -> Option<char> {
    let lines: Vec<&str> = pane.lines().filter(|l| !l.trim().is_empty()).collect();
    let head = lines
        .iter()
        .rposition(|l| l.contains("plan") && l.contains(PLAN_PROMPT))?;
    if lines.len() - head > PLAN_PROMPT_FOOT {
        return None;
    }
    let options: Vec<(char, &str)> = lines[head + 1..]
        .iter()
        .filter_map(|l| {
            let l = l.trim_start().trim_start_matches('\u{276f}').trim_start();
            let (n, rest) = l.split_once(". ")?;
            let mut d = n.chars();
            match (d.next(), d.next()) {
                (Some(c), None) if c.is_ascii_digit() => Some((c, rest.trim())),
                _ => None,
            }
        })
        .collect();
    options
        .iter()
        .find(|(_, t)| t.starts_with("Yes, auto-accept edits"))
        .or_else(|| options.iter().find(|(_, t)| t.starts_with("Yes")))
        .map(|(c, _)| *c)
}

/// The actions a row offers: a parked one can only be unparked, cancel needs a queue item.
pub fn available(s: &Session) -> Vec<Action> {
    if s.parked {
        return vec![Action::Unpark];
    }
    let mut v = vec![Action::Interrupt, Action::Park, Action::Move, Action::Stop];
    if s.approve_key.is_some() {
        v.insert(0, Action::ApprovePlan);
    }
    if s.item.is_some() {
        v.push(Action::Cancel);
    }
    v
}

/// One command. A step with `check` stops the action when it fails; one without is allowed to
/// fail (a wait that timed out, a window that already closed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub argv: Vec<String>,
    pub check: bool,
}

fn step(argv: &[&str]) -> Step {
    Step {
        argv: argv.iter().map(|s| s.to_string()).collect(),
        check: true,
    }
}

/// How long stop waits for claude to exit after `/exit` before it closes the window anyway.
pub const STOP_WAIT_SECS: u32 = 10;

/// A name that can sit in an argv without being read as an option or a path.
fn is_word(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// `%N` or `@N`.
fn is_id(s: &str, sigil: char) -> bool {
    s.strip_prefix(sigil)
        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// The steps for `action` on the session at `target`, or why it is refused. `account` is the
/// destination of a move; `accounts` the names in the accounts file.
pub fn plan(
    action: Action,
    target: &str,
    account: Option<&str>,
    sessions: &[Session],
    accounts: &[String],
) -> Result<Vec<Step>, String> {
    let s = sessions
        .iter()
        .find(|s| s.target == target)
        .ok_or_else(|| format!("no live or parked session at {target}"))?;
    if !available(s).contains(&action) {
        return Err(match action {
            Action::Cancel => format!("{target} was not started by a queue item"),
            Action::ApprovePlan if !s.parked => format!("{target} shows no plan dialog"),
            _ if s.parked => format!("{target} is parked; it can only be unparked"),
            _ => format!("{target} is not parked"),
        });
    }
    if !is_word(&s.tmux_session) || !is_word(&s.server) {
        return Err(format!(
            "{target} has a session or server name this will not pass on"
        ));
    }
    let (srv, sess) = (s.server.as_str(), s.tmux_session.as_str());
    let pane_ok = is_id(&s.pane, '%');
    let tmux_keys = |keys: &[&str]| {
        let mut argv = vec!["tmux", "-L", srv, "send-keys", "-t", &s.pane];
        argv.extend_from_slice(keys);
        step(&argv)
    };
    // Copy mode swallows typed keys; `copy-mode -q` leaves every mode (claude-acct leave_mode).
    let leave_mode = step(&["tmux", "-L", srv, "copy-mode", "-q", "-t", &s.pane]);
    Ok(match action {
        Action::Interrupt => {
            if !pane_ok {
                return Err(format!("{target} has no pane id"));
            }
            vec![leave_mode, tmux_keys(&["Escape"])]
        }
        Action::ApprovePlan => {
            let key = s.approve_key.filter(char::is_ascii_digit).map(String::from);
            match (pane_ok, key) {
                (true, Some(k)) => vec![leave_mode, tmux_keys(&[&k])],
                _ => return Err(format!("{target} has no pane id or plan key")),
            }
        }
        Action::Park => vec![step(&["claude-acct", "park", sess, "--server", srv])],
        Action::Unpark => vec![step(&["claude-acct", "unpark", sess])],
        Action::Move => {
            let to = account
                .filter(|a| !a.is_empty())
                .ok_or("move needs an account")?;
            if !accounts.iter().any(|a| a == to) {
                return Err(format!("no account '{to}' (have: {})", accounts.join(" ")));
            }
            vec![step(&[
                "claude-acct",
                "move",
                sess,
                "--server",
                srv,
                "--to",
                to,
            ])]
        }
        Action::Stop => {
            if !pane_ok || !is_id(&s.window_id, '@') {
                return Err(format!("{target} has no pane or window id"));
            }
            let mut v = vec![
                leave_mode,
                tmux_keys(&["Escape"]),
                tmux_keys(&["-l", "/exit"]),
                tmux_keys(&["Enter"]),
            ];
            if s.pid > 0 {
                // No event exists for a non-child's exit; `tail --pid` is the wait, `timeout`
                // its guard. Allowed to fail: the window is closed either way.
                let (secs, pid) = (STOP_WAIT_SECS.to_string(), s.pid.to_string());
                let mut w = step(&["timeout", &secs, "tail", "--pid", &pid, "-f", "/dev/null"]);
                w.check = false;
                v.push(w);
            }
            // The window may already be gone when claude was the pane's own process.
            let mut k = step(&["tmux", "-L", srv, "kill-window", "-t", &s.window_id]);
            k.check = false;
            v.push(k);
            v
        }
        Action::Cancel => {
            let slug = s.item.as_deref().unwrap_or_default();
            if !is_word(slug) {
                return Err(format!("{target} has a queue slug this will not pass on"));
            }
            vec![step(&["agent-queue", "cancel", slug])]
        }
    })
}

/// Runs one argv: its stdout, or its stderr (else its exit status) when it fails.
pub trait Runner {
    fn run(&self, argv: &[String]) -> Result<String, String>;
}

/// The real runner: the command with no shell and no stdin.
pub struct System;

impl Runner for System {
    fn run(&self, argv: &[String]) -> Result<String, String> {
        let (cmd, args) = argv.split_first().ok_or("empty command")?;
        let out = Command::new(cmd)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("{cmd}: {e}"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            Err(if err.is_empty() {
                format!("{cmd}: {}", out.status)
            } else {
                err
            })
        }
    }
}

/// Run the steps in order; the output of the ones that printed, or the first checked failure.
pub fn execute(steps: &[Step], runner: &dyn Runner) -> Result<String, String> {
    let mut said = Vec::new();
    for s in steps {
        match runner.run(&s.argv) {
            Ok(out) if !out.trim().is_empty() => said.push(out.trim().to_string()),
            Ok(_) => {}
            Err(e) if s.check => return Err(e),
            Err(_) => {}
        }
    }
    Ok(said.join("\n"))
}

/// The tmux server agent-queue starts its sessions on, as agent-queue resolves it.
fn queue_server() -> String {
    std::env::var("AGENT_QUEUE_TMUX_SERVER").unwrap_or_else(|_| "lab".into())
}

/// Name each session's queue item from `agent-queue list --json` (one object per line): the
/// item whose `session` names that tmux session, once it has started. `session` is
/// `<server>:<tmux-session>`, or a bare tmux session on agent-queue's `server`.
pub fn with_items(sessions: &mut [Session], items_jsonl: &str, server: &str) {
    for line in items_jsonl.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let field = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("");
        let (slug, sess) = (field("slug"), field("session"));
        if slug.is_empty() || sess.is_empty() || field("state") == "queued" {
            continue;
        }
        let (srv, sess) = sess.split_once(':').unwrap_or((server, sess));
        for s in sessions.iter_mut() {
            if s.server == srv && s.tmux_session == sess && !s.parked {
                s.item = Some(slug.to_string());
            }
        }
    }
}

/// Every session and account as they are now.
pub struct Snapshot {
    /// The agents in `collect_all` order (attached first), each with its `Session`.
    pub agents: Vec<(chooser::Agent, Session)>,
    pub accounts: Vec<String>,
}

/// Read the sessions (live and parked), their queue items and the account names. A queue
/// that cannot be listed leaves every `item` empty, so cancel is simply not offered.
pub fn gather(runner: &dyn Runner) -> Snapshot {
    let agents = chooser::collect_all();
    let mut sessions: Vec<Session> = agents.iter().map(Session::from).collect();
    let items = runner
        .run(&["agent-queue".into(), "list".into(), "--json".into()])
        .unwrap_or_default();
    with_items(&mut sessions, &items, &queue_server());
    for (a, s) in agents.iter().zip(sessions.iter_mut()) {
        // Only a session in plan mode can show the dialog, so only those panes are captured.
        if a.plan && !s.parked && is_word(&s.server) && is_id(&s.pane, '%') {
            let argv = ["tmux", "-L", &s.server, "capture-pane", "-p", "-t", &s.pane];
            let argv: Vec<String> = argv.iter().map(|x| x.to_string()).collect();
            s.approve_key = runner.run(&argv).ok().as_deref().and_then(plan_approve_key);
        }
    }
    Snapshot {
        agents: agents.into_iter().zip(sessions).collect(),
        accounts: account::load().into_iter().map(|a| a.name).collect(),
    }
}

impl Snapshot {
    pub fn sessions(&self) -> Vec<Session> {
        self.agents.iter().map(|(_, s)| s.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Records every argv; fails the ones whose first word is in `fail`.
    #[derive(Default)]
    struct Fake {
        calls: RefCell<Vec<String>>,
        fail: Vec<&'static str>,
    }

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(argv.join(" "));
            if self.fail.iter().any(|f| argv.join(" ").contains(f)) {
                Err(format!("{} failed", argv[0]))
            } else {
                Ok(String::new())
            }
        }
    }

    fn live() -> Session {
        Session {
            target: "lab/dotfiles-agent-3:2".into(),
            server: "lab".into(),
            tmux_session: "dotfiles-agent-3".into(),
            pane: "%14".into(),
            window_id: "@7".into(),
            pid: 4242,
            account: "main".into(),
            ..Session::default()
        }
    }

    fn parked() -> Session {
        Session {
            target: "lab/dotfiles-agent-9:1".into(),
            server: "lab".into(),
            tmux_session: "dotfiles-agent-9".into(),
            pane: "%30".into(),
            parked: true,
            ..Session::default()
        }
    }

    fn accounts() -> Vec<String> {
        vec!["main".into(), "alt".into(), "bnb".into()]
    }

    fn run(action: Action, s: &Session, account: Option<&str>) -> Vec<String> {
        let steps = plan(
            action,
            &s.target,
            account,
            &[s.clone(), live(), parked()],
            &accounts(),
        )
        .unwrap();
        let fake = Fake::default();
        execute(&steps, &fake).unwrap();
        fake.calls.into_inner()
    }

    #[test]
    fn every_action_runs_the_command_that_owns_it() {
        let mut queued = live();
        queued.item = Some("fix-the-thing".into());
        assert_eq!(
            run(Action::Interrupt, &live(), None),
            [
                "tmux -L lab copy-mode -q -t %14",
                "tmux -L lab send-keys -t %14 Escape"
            ]
        );
        assert_eq!(
            run(Action::Park, &live(), None),
            ["claude-acct park dotfiles-agent-3 --server lab"]
        );
        assert_eq!(
            run(Action::Unpark, &parked(), None),
            ["claude-acct unpark dotfiles-agent-9"]
        );
        assert_eq!(
            run(Action::Move, &live(), Some("bnb")),
            ["claude-acct move dotfiles-agent-3 --server lab --to bnb"]
        );
        assert_eq!(
            run(Action::Stop, &live(), None),
            [
                "tmux -L lab copy-mode -q -t %14",
                "tmux -L lab send-keys -t %14 Escape",
                "tmux -L lab send-keys -t %14 -l /exit",
                "tmux -L lab send-keys -t %14 Enter",
                "timeout 10 tail --pid 4242 -f /dev/null",
                "tmux -L lab kill-window -t @7",
            ]
        );
        assert_eq!(
            run(Action::Cancel, &queued, None),
            ["agent-queue cancel fix-the-thing"]
        );
    }

    #[test]
    fn stop_closes_the_window_even_when_the_wait_times_out() {
        let steps = plan(Action::Stop, &live().target, None, &[live()], &accounts()).unwrap();
        let fake = Fake {
            fail: vec!["timeout", "kill-window"],
            ..Fake::default()
        };
        assert!(execute(&steps, &fake).is_ok());
        assert_eq!(fake.calls.borrow().len(), 6);
        // A checked step that fails stops the rest.
        let fake = Fake {
            fail: vec!["copy-mode"],
            ..Fake::default()
        };
        assert_eq!(execute(&steps, &fake), Err("tmux failed".into()));
        assert_eq!(fake.calls.borrow().len(), 1);
    }

    #[test]
    fn refuses_an_unknown_session_and_an_unknown_account() {
        let all = [live(), parked()];
        let err = plan(Action::Park, "lab/someone-else:1", None, &all, &accounts()).unwrap_err();
        assert!(err.contains("no live or parked session"), "{err}");
        let err = plan(
            Action::Move,
            &live().target,
            Some("evil"),
            &all,
            &accounts(),
        )
        .unwrap_err();
        assert!(err.contains("no account 'evil'"), "{err}");
        assert!(plan(Action::Move, &live().target, None, &all, &accounts()).is_err());
        assert!(plan(
            Action::Move,
            &live().target,
            Some("--to"),
            &all,
            &accounts()
        )
        .is_err());
        let mut odd = live();
        odd.tmux_session = "-t".into();
        assert!(plan(Action::Park, &odd.target, None, &[odd.clone()], &accounts()).is_err());
    }

    #[test]
    fn cancel_is_unavailable_without_a_queue_slug() {
        assert!(!available(&live()).contains(&Action::Cancel));
        let err = plan(Action::Cancel, &live().target, None, &[live()], &accounts()).unwrap_err();
        assert!(err.contains("not started by a queue item"), "{err}");
        let mut bad = live();
        bad.item = Some("--all".into());
        assert!(plan(
            Action::Cancel,
            &bad.target,
            None,
            &[bad.clone()],
            &accounts()
        )
        .is_err());
    }

    #[test]
    fn a_parked_row_offers_only_unpark_and_a_live_one_never_unpark() {
        assert_eq!(available(&parked()), [Action::Unpark]);
        let all = [live(), parked()];
        assert!(plan(Action::Stop, &parked().target, None, &all, &accounts()).is_err());
        assert!(plan(Action::Unpark, &live().target, None, &all, &accounts()).is_err());
    }

    #[test]
    fn a_queue_item_names_its_running_session_on_the_queue_server() {
        let mut s = vec![live(), parked()];
        let mut other = live();
        other.server = "hub".into();
        s.push(other);
        with_items(
            &mut s,
            "{\"slug\":\"a\",\"session\":\"dotfiles-agent-3\",\"state\":\"running\"}\n\
             not json\n\
             {\"slug\":\"b\",\"session\":\"dotfiles-agent-9\",\"state\":\"running\"}\n\
             {\"slug\":\"c\",\"session\":\"dotfiles-agent-3\",\"state\":\"queued\"}\n",
            "lab",
        );
        assert_eq!(s[0].item.as_deref(), Some("a"));
        assert_eq!(s[1].item, None, "a parked row is unparked, not cancelled");
        assert_eq!(s[2].item, None, "same name on another server");

        with_items(
            &mut s,
            "{\"slug\":\"d\",\"session\":\"hub:dotfiles-agent-3\",\"state\":\"running\"}\n",
            "lab",
        );
        assert_eq!(
            s[2].item.as_deref(),
            Some("d"),
            "<server>:<session> names its server"
        );
        assert_eq!(s[0].item.as_deref(), Some("a"));
    }

    #[test]
    fn actions_round_trip_by_name() {
        for a in Action::ALL {
            assert_eq!(Action::parse(a.name()), Some(a));
        }
        assert_eq!(Action::parse("rm"), None);
    }
    /// A pane captured from Claude Code v2.1.318 with its plan dialog open.
    const PLAN_PANE: &str = "\
\u{25cf} I wrote a 2-line plan: create hello.txt, then cat it.
\u{2500}\u{2500}\u{2500}
 Ready to code?
 Here is Claude's plan:
 1. Create hello.txt in the repo root containing the single line \"hi\".
 2. Verify: run cat hello.txt and confirm it prints \"hi\".
\u{2500}\u{2500}\u{2500}
 Claude has written up a plan and is ready to execute. Would you like to proceed?
 \u{276f} 1. Yes, auto-accept edits
   2. Yes, manually approve edits
   3. Tell Claude what to change
      shift+tab to approve with this feedback
 ctrl+g to edit in Nvim \u{b7} ~/.claude/plans/plan.md

";

    /// The same session one step earlier: a permission prompt, which also offers "1. Yes".
    const PERMISSION_PANE: &str = "\
 Create file
 Do you want to create plan-creating-hello-txt.md?
 \u{276f} 1. Yes
   2. Yes, and always allow access to ~/.claude/plans for this session (shift+tab)
   3. No
 Esc to cancel \u{b7} Tab to amend
";

    #[test]
    fn the_plan_key_is_read_only_under_the_plan_dialog() {
        assert_eq!(plan_approve_key(PLAN_PANE), Some('1'));
        assert_eq!(plan_approve_key(PERMISSION_PANE), None);
        assert_eq!(plan_approve_key(""), None);
        // Options ordered differently: the auto-accept one still wins over a plain "Yes".
        let reordered = PLAN_PANE
            .replace(
                "1. Yes, auto-accept edits",
                "1. Yes, manually approve edits",
            )
            .replace(
                "2. Yes, manually approve edits",
                "2. Yes, auto-accept edits",
            );
        assert_eq!(plan_approve_key(&reordered), Some('2'));
        // A dialog scrolled far above the foot is an old one the pane no longer shows open.
        let scrolled = format!("{PLAN_PANE}{}", "output\n".repeat(PLAN_PROMPT_FOOT));
        assert_eq!(plan_approve_key(&scrolled), None);
    }

    #[test]
    fn approve_plan_presses_the_dialog_digit_and_only_when_one_is_shown() {
        let mut planning = live();
        planning.approve_key = Some('1');
        assert_eq!(available(&planning)[0], Action::ApprovePlan);
        assert_eq!(
            run(Action::ApprovePlan, &planning, None),
            [
                "tmux -L lab copy-mode -q -t %14",
                "tmux -L lab send-keys -t %14 1"
            ]
        );
        assert!(!available(&live()).contains(&Action::ApprovePlan));
        let err = plan(
            Action::ApprovePlan,
            &live().target,
            None,
            &[live()],
            &accounts(),
        )
        .unwrap_err();
        assert!(err.contains("no plan dialog"), "{err}");
        let mut parked_plan = parked();
        parked_plan.approve_key = Some('1');
        assert_eq!(available(&parked_plan), [Action::Unpark]);
    }
}
