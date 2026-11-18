//! A live agent, on a pane here or on a fleet worker. A worker's target is
//! `<host>@<server>/<session>:<window>`, the form fleet-sessions and state.json carry for a worker's
//! rows (fleet-hosts.sh `fleet_host_panel`), so it names no tmux server here. One row, one
//! transport: the same argv runs here, or behind `fleet-host-run <host>`, the one ssh path, where
//! that worker's own agent-panel and tmux act on it. A read never goes over ssh: whether a worker's
//! pane is a live agent comes from the snapshot the minute record publishes (`worker_panel`); ssh is
//! only for acting on one.

use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use agent_core::tmux;

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

/// The worker and its own target, for a worker's target; None for a target on this machine.
pub fn split(target: &str) -> Option<(&str, &str)> {
    let (host, local) = target.split_once('@')?;
    let ok =
        !host.is_empty() && !host.starts_with('-') && !host.contains('/') && local.contains('/');
    ok.then_some((host, local))
}

/// The snapshot's document when it parses and is within the ttl it carries; Err (why) otherwise.
/// The one freshness rule for the session list (`rows_in`) and for screen and typing (`live_in`).
fn fresh(snapshot: &str, now: u64) -> Result<serde_json::Value, String> {
    let doc: serde_json::Value = serde_json::from_str(snapshot)
        .map_err(|e| format!("the worker snapshot is unreadable: {e}"))?;
    let age = now.saturating_sub(doc["at"].as_u64().unwrap_or(0));
    if age > doc["ttl"].as_u64().unwrap_or(0) {
        return Err(format!(
            "the worker snapshot is {age}s old; the minute record has not refreshed it"
        ));
    }
    Ok(doc)
}

/// The row of `target` in the worker-panel snapshot's text, as the live agent it names. Err (why)
/// when the snapshot is unreadable or older than the ttl it carries, when the target's worker is one
/// the minute record could not read (its sessions are unknown, not gone), or when the row has no pane.
pub fn live_in(snapshot: &str, target: &str, now: u64) -> Result<Option<Live>, String> {
    let doc = fresh(snapshot, now)?;
    let host = split(target).map_or("", |(h, _)| h);
    let row = doc["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["target"] == target);
    let Some(row) = row else {
        let silent = doc["silent"].as_array().into_iter().flatten();
        return if silent.into_iter().any(|h| h == host) {
            Err(format!(
                "{host} did not answer the last minute record, so its sessions are not known"
            ))
        } else {
            Ok(None)
        };
    };
    let pane = row["pane"]
        .as_str()
        .ok_or_else(|| format!("the snapshot's row for {target} has no pane"))?;
    Ok(Some(Live {
        host: Some(host.to_string()),
        pane: pane.to_string(),
    }))
}

/// Every worker row in the snapshot's text that names a live pane, for the session list. Empty when
/// the snapshot is unreadable or past its ttl: the sessions table already says which worker went
/// unread (hub-core `session_table`), so a stale row is never offered as live here.
pub fn rows_in(snapshot: &str, now: u64) -> Vec<serde_json::Value> {
    let Ok(doc) = fresh(snapshot, now) else {
        return Vec::new();
    };
    doc["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["pane"].is_string() && r["target"].as_str().and_then(split).is_some())
        .cloned()
        .collect()
}

/// The live agent at a worker's target, from the snapshot file: no ssh.
pub async fn find(snapshot: &Path, target: &str) -> Result<Option<Live>, Failed> {
    let path = snapshot.to_path_buf();
    let text =
        tokio::task::spawn_blocking(move || std::fs::read_to_string(&path).map_err(|e| (path, e)))
            .await
            .map_err(|e| Failed::Unreachable(e.to_string()))?
            .map_err(|(p, e)| {
                Failed::Unreachable(format!("no worker snapshot ({}): {e}", p.display()))
            })?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    live_in(&text, target, now).map_err(Failed::Unreachable)
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

    const SNAP: &str = r#"{"at":1000,"ttl":180,"rows":[
        {"target":"hp@lab/s1:1","pane":"lab/%3","host":"hp"},
        {"target":"hp@lab/s1:2","pane":"lab/%7","host":"hp"}]}"#;

    #[test]
    fn the_session_list_takes_every_fresh_worker_row_with_a_pane() {
        let rows = rows_in(SNAP, 1100);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1]["target"], "hp@lab/s1:2");
        let no_pane = r#"{"at":1000,"ttl":180,"rows":[{"target":"hp@lab/s1:1","host":"hp"},
            {"target":"lab/s1:1","pane":"lab/%3"}]}"#;
        assert!(
            rows_in(no_pane, 1100).is_empty(),
            "no pane, or not a worker's target"
        );
    }

    #[test]
    fn a_stale_or_unreadable_snapshot_lists_no_worker_session() {
        assert!(rows_in(SNAP, 1181).is_empty());
        assert!(rows_in("not json", 1000).is_empty());
    }

    #[test]
    fn only_a_listed_target_gives_a_live_agent_on_its_worker() {
        let l = live_in(SNAP, "hp@lab/s1:2", 1100).ok().flatten().unwrap();
        assert_eq!((l.host.as_deref(), l.pane.as_str()), (Some("hp"), "lab/%7"));
        assert!(live_in(SNAP, "hp@lab/s1:9", 1100).unwrap().is_none());
    }

    #[test]
    fn a_snapshot_past_its_own_ttl_or_unreadable_is_an_error_not_an_empty_answer() {
        assert!(live_in(SNAP, "hp@lab/s1:2", 1180).is_ok());
        assert!(live_in(SNAP, "hp@lab/s1:2", 1181).is_err());
        assert!(live_in("not json", "hp@lab/s1:2", 1000).is_err());
    }

    #[test]
    fn a_worker_the_record_could_not_read_is_unknown_not_empty() {
        let snap = r#"{"at":1000,"ttl":180,"rows":[
            {"target":"hp@lab/s1:1","pane":"lab/%3"}],"silent":["nuc"]}"#;
        assert!(live_in(snap, "nuc@lab/s1:1", 1100).is_err());
        assert!(live_in(snap, "hp@lab/s1:9", 1100).unwrap().is_none());
        assert!(live_in(snap, "hp@lab/s1:1", 1100).unwrap().is_some());
    }

    #[test]
    fn a_row_without_a_pane_is_an_error() {
        let snap = r#"{"at":1000,"ttl":180,"rows":[{"target":"hp@lab/s1:1"}]}"#;
        assert!(live_in(snap, "hp@lab/s1:1", 1100).is_err());
    }

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
