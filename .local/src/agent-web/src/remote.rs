//! A live agent, on a pane here or on a fleet worker. A worker's target is
//! `<host>@<server>/<session>:<window>`, the form fleet-sessions and state.json carry for a worker's
//! rows (fleet-hosts.sh `fleet_host_panel`), so it names no tmux server here. One row, one
//! transport: the same argv runs here, or behind `fleet-host-run <host>`, the one ssh path, where
//! that worker's own agent-panel and tmux act on it. A read never goes over ssh: whether a worker's
//! pane is a live agent comes from the snapshot the minute record publishes, read by
//! `hub_core::session_table`; ssh is only for acting on one.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use agent_core::tmux;
use hub_core::session_table::worker_pane;

/// How long one call to a pane may take before it is given up on. ssh ends a dead link on its own
/// (fleet-hosts.sh `_fh_ssh`); this ends a worker that answers and then hangs, so a request never
/// waits forever on one.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// A live agent: its pane (`<server>/%<id>`), and the worker it runs on, None when it runs here.
pub struct Live {
    pub host: Option<String>,
    pub pane: String,
}

/// Why a call did not give its output.
pub enum Failed {
    /// ssh's 255, the worker not in the roster, or no answer in time.
    Unreachable(String),
    /// The command ran and exited with this code.
    Exit(i32, String),
}

/// The live agent at a worker's target, from the snapshot file: no ssh. The snapshot and its
/// freshness are `hub_core::session_table`'s ([`worker_pane`]).
pub async fn find(snapshot: &Path, target: &str) -> Result<Option<Live>, Failed> {
    let (path, target) = (snapshot.to_path_buf(), target.to_string());
    let pane = tokio::task::spawn_blocking(move || worker_pane(&path, &target))
        .await
        .map_err(|e| Failed::Unreachable(e.to_string()))?
        .map_err(Failed::Unreachable)?;
    Ok(pane.map(|w| Live {
        host: Some(w.host),
        pane: w.pane,
    }))
}

/// Run `argv` here (`host` None) or on `host` through `fleet-host-run`, with the call's timeout; its
/// stdout on exit 0, or on any exit code in `ok`.
pub async fn run(host: Option<&str>, argv: &[&str], ok: &[i32]) -> Result<String, Failed> {
    let (prog, args) = match host {
        Some(h) => ("fleet-host-run", [&[h], argv].concat()),
        None => (argv[0], argv[1..].to_vec()),
    };
    let child = tokio::process::Command::new(prog)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| Failed::Unreachable(format!("{prog}: {e}")))?;
    let who = host.unwrap_or("here");
    let out = tokio::time::timeout(CALL_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| {
            Failed::Unreachable(format!(
                "{who} did not answer within {}s",
                CALL_TIMEOUT.as_secs()
            ))
        })?
        .map_err(|e| Failed::Unreachable(format!("{prog}: {e}")))?;
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    match out.status.code().unwrap_or(-1) {
        c if c == 0 || ok.contains(&c) => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        255 if host.is_some() && err.is_empty() => {
            Err(Failed::Unreachable(format!("{who} did not answer")))
        }
        255 if host.is_some() => Err(Failed::Unreachable(err)),
        c => Err(Failed::Exit(c, err)),
    }
}

impl Live {
    /// `tmux -L <server> <args...>` aimed at its pane with `-t`.
    async fn tmux(&self, verb: &str, args: &[&str]) -> Result<String, Failed> {
        let (srv, pane) = tmux::split(&self.pane);
        let Some(srv) = srv else {
            return Err(Failed::Exit(
                1,
                format!("pane {} names no tmux server", self.pane),
            ));
        };
        let mut argv = vec!["tmux", "-L", srv, verb, "-t", pane];
        argv.extend_from_slice(args);
        run(self.host.as_deref(), &argv, &[]).await
    }

    /// Its screen, as `tmux capture-pane -p -J -S <start>` prints it.
    pub async fn capture(&self, start: i32) -> Result<String, Failed> {
        self.tmux("capture-pane", &["-p", "-J", "-S", &start.to_string()])
            .await
    }

    /// Type `text` (when there is any) through `agent-panel send`, then send `key` with tmux.
    /// Ok(false) when the pane did not take the Enter (its exit 3): the text sits in the input box
    /// and no key is sent.
    pub async fn send(&self, text: &str, submit: bool, key: Option<&str>) -> Result<bool, Failed> {
        if !text.is_empty() {
            let mut args = vec!["agent-panel", "send", "--pane", self.pane.as_str()];
            if !submit {
                args.push("--no-submit");
            }
            args.extend(["--", text]);
            match run(self.host.as_deref(), &args, &[]).await {
                Ok(_) => {}
                Err(Failed::Exit(3, _)) => return Ok(false),
                Err(e) => return Err(e),
            }
        }
        if let Some(k) = key {
            self.tmux("send-keys", &[k]).await?;
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_pane_with_no_server_is_refused_before_any_call() {
        let l = Live {
            host: None,
            pane: "%3".into(),
        };
        assert!(matches!(l.capture(0).await, Err(Failed::Exit(1, _))));
    }

    // Paused time: the runtime jumps to the timeout while the child still sleeps, so no wait.
    #[tokio::test(start_paused = true)]
    async fn a_call_that_hangs_is_given_up_on() {
        let slow = run(None, &["sleep", "600"], &[]).await;
        assert!(
            matches!(slow, Err(Failed::Unreachable(w)) if w.contains("did not answer within 30s"))
        );
    }

    #[tokio::test]
    async fn a_call_here_runs_its_argv_as_given() {
        assert_eq!(
            run(None, &["echo", "hi"], &[]).await.ok().as_deref(),
            Some("hi\n")
        );
        assert!(matches!(
            run(None, &["sh", "-c", "exit 3"], &[]).await,
            Err(Failed::Exit(3, _))
        ));
        assert!(run(None, &["sh", "-c", "exit 3"], &[3]).await.is_ok());
        // A local 255 is the command's own exit, not an unreachable worker.
        assert!(matches!(
            run(None, &["sh", "-c", "exit 255"], &[]).await,
            Err(Failed::Exit(255, _))
        ));
    }
}
