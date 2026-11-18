//! A session on a fleet worker. Its target is `<host>@<server>/<session>:<window>`, the form
//! fleet-sessions and state.json carry for a worker's rows (fleet-hosts.sh `fleet_host_panel`), so
//! it names no tmux server here. Everything done to one goes through `fleet-host-run <host>`, the
//! one ssh path: that worker's own agent-panel says it is a live agent, shows its screen and types
//! into it.

use std::process::Stdio;

use agent_panel::tmux;

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
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    match out.status.code().unwrap_or(-1) {
        c if c == 0 || ok.contains(&c) => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        255 if err.is_empty() => Err(Failed::Unreachable(format!("{host} did not answer"))),
        255 => Err(Failed::Unreachable(err)),
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
    /// `tmux -L <server> <args...>` on the worker, aimed at its pane with `-t`.
    async fn tmux(&self, verb: &str, args: &[&str]) -> Result<String, Failed> {
        let (srv, pane) = tmux::split(&self.pane);
        let mut argv = vec!["tmux", "-L", srv.unwrap_or("default"), verb, "-t", pane];
        argv.extend_from_slice(args);
        run(&self.host, &argv, &[]).await
    }

    /// Its screen, as `tmux capture-pane -p -J -S <start>` prints it there.
    pub async fn capture(&self, start: i32) -> Result<String, Failed> {
        self.tmux("capture-pane", &["-p", "-J", "-S", &start.to_string()])
            .await
    }

    /// Type `text` (when there is any) through that worker's `agent-panel send`, then send `key`
    /// with its tmux. Ok(false) when the pane did not take the Enter (its exit 3): the text sits in
    /// the input box and no key is sent.
    pub async fn send(&self, text: &str, submit: bool, key: Option<&str>) -> Result<bool, Failed> {
        if !text.is_empty() {
            let mut args = vec!["agent-panel", "send", "--pane", self.pane.as_str()];
            if !submit {
                args.push("--no-submit");
            }
            args.extend(["--", text]);
            match run(&self.host, &args, &[]).await {
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
