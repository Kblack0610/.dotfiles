//! A session on a fleet worker. Its target is `<host>@<server>/<session>:<window>`, the form
//! fleet-sessions and state.json carry for a worker's rows (fleet-hosts.sh `fleet_host_panel`), so
//! it names no tmux server here. Everything done to one goes through `fleet-host-run <host>`, the
//! one ssh path: that worker's own agent-panel says it is a live agent, shows its screen and types
//! into it.

use std::process::Stdio;

/// The live agent at a worker's target: the worker, and its pane there (`<server>/%<id>`).
pub struct Remote {
    pub host: String,
    pub pane: String,
}

/// Why a call to a worker did not give its output.
pub enum Failed {
    /// ssh's 255: the worker did not answer, or is not in the roster.
    Unreachable(String),
    /// The command ran there and exited with this code.
    Exit(i32, String),
}

/// The worker and its own target, for a worker's target; None for a target on this machine.
pub fn split(target: &str) -> Option<(&str, &str)> {
    let (host, local) = target.split_once('@')?;
    let ok =
        !host.is_empty() && !host.starts_with('-') && !host.contains('/') && local.contains('/');
    ok.then_some((host, local))
}

/// The pane of the live agent at `local` in a worker's `agent-panel list --json` lines.
pub fn pane_in(rows: &str, local: &str) -> Option<String> {
    rows.lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|r| r["target"] == local)
        .and_then(|r| r["pane"].as_str().map(str::to_string))
}

/// Run one command on `host`; its stdout on exit 0, or on any exit code in `ok`.
pub async fn run(host: &str, args: &[&str], ok: &[i32]) -> Result<String, Failed> {
    let out = tokio::process::Command::new("fleet-host-run")
        .arg(host)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|e| Failed::Unreachable(format!("fleet-host-run: {e}")))?;
    let code = out.status.code().unwrap_or(-1);
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    match code {
        0 => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        c if ok.contains(&c) => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        255 => Err(Failed::Unreachable(if err.is_empty() {
            format!("{host} did not answer")
        } else {
            err
        })),
        c => Err(Failed::Exit(c, err)),
    }
}

/// The live agent at a worker's target, from that worker's agent-panel. A read with a gap (exit 3)
/// still lists the rows it read.
pub async fn find(host: &str, local: &str) -> Result<Option<Remote>, Failed> {
    let rows = run(host, &["agent-panel", "list", "--json"], &[3]).await?;
    Ok(pane_in(&rows, local).map(|pane| Remote {
        host: host.to_string(),
        pane,
    }))
}

impl Remote {
    fn server_pane(&self) -> (&str, &str) {
        match self.pane.split_once('/') {
            Some((srv, p)) => (srv, p),
            None => ("default", self.pane.as_str()),
        }
    }

    /// Its screen, as `tmux capture-pane -p -J -S <start>` prints it there.
    pub async fn capture(&self, start: i32) -> Result<String, Failed> {
        let (srv, pane) = self.server_pane();
        let start = start.to_string();
        run(
            &self.host,
            &[
                "tmux",
                "-L",
                srv,
                "capture-pane",
                "-p",
                "-J",
                "-t",
                pane,
                "-S",
                &start,
            ],
            &[],
        )
        .await
    }

    /// Type `text` into it through that worker's `agent-panel send`; Ok(false) when the pane did
    /// not take the Enter (its exit 3), so the text sits in the input box.
    pub async fn message(&self, text: &str, submit: bool) -> Result<bool, Failed> {
        let mut args = vec!["agent-panel", "send", "--pane", self.pane.as_str()];
        if !submit {
            args.push("--no-submit");
        }
        args.extend(["--", text]);
        match run(&self.host, &args, &[]).await {
            Ok(_) => Ok(true),
            Err(Failed::Exit(3, _)) => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Send one tmux key to its pane there.
    pub async fn key(&self, key: &str) -> Result<(), Failed> {
        let (srv, pane) = self.server_pane();
        run(
            &self.host,
            &["tmux", "-L", srv, "send-keys", "-t", pane, key],
            &[],
        )
        .await
        .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_worker_target_splits_and_a_local_one_does_not() {
        assert_eq!(split("razer@lab/s1:2"), Some(("razer", "lab/s1:2")));
        assert_eq!(split("lab/s1:2"), None);
        // An @ inside a local session or window name is not a worker.
        assert_eq!(split("lab/me@x:1"), None);
        assert_eq!(split("@lab/s1:2"), None);
        assert_eq!(split("-oProxyCommand=x@lab/s1:2"), None);
        assert_eq!(split("razer@nothing"), None);
    }

    #[test]
    fn only_a_listed_target_gives_a_pane() {
        let rows = "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%3\"}\nnot json\n{\"target\":\"lab/s1:2\",\"pane\":\"lab/%7\"}\n";
        assert_eq!(pane_in(rows, "lab/s1:2").as_deref(), Some("lab/%7"));
        assert_eq!(pane_in(rows, "lab/s1:9"), None);
        assert_eq!(pane_in("", "lab/s1:1"), None);
    }
}
