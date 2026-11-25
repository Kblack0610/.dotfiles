//! The standing holds: the `agent-hold` holds only the human ends, read from their files
//! (`~/.agent/holds`, `AGENT_HOLD_DIR`), for Alerts (one red row each) and Home's Needs you (the
//! ones the human set). A standing hold is a resource hold, or any hold `by: human`, set
//! `STANDING_SECS` ago or longer; a load hold (the shepherd lifts it) and a claim (it ends with its
//! skill) never stand. A keep (`agent-hold keep`, the human's `keep` answer on an ask about it)
//! restarts that clock: a hold the human just re-confirmed waits a day past the keep (ar-5307). The
//! rule is `agent-hold aged`'s, whose `hold-age` watch pages the same holds
//! (ar-4645). A hold forgotten for days kept its resource from every session and nobody saw it.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

/// How long a hold stands before it is red: `agent-hold aged`'s default, one day.
pub const STANDING_SECS: i64 = 86400;

/// The `by:` a hold the human set carries.
pub const HUMAN: &str = "human";

/// One hold file, the fields a reader shows.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Hold {
    pub resource: String,
    /// `load`, `resource` or `claim`; a file with no `kind:` line reads as `agent-hold set` gives
    /// it: resource for `dispatch`, else load.
    pub kind: String,
    pub by: String,
    /// When it was set, epoch seconds; none when its `since:` does not read.
    pub since: Option<i64>,
    /// When the human last re-confirmed it (`kept:`, written by `agent-hold keep`), epoch seconds;
    /// none when it was never kept or the value does not read.
    pub kept: Option<i64>,
    pub reason: String,
}

impl Hold {
    /// Parse one hold file, flat `key: value`, the first value of each key.
    pub fn parse(resource: &str, text: &str) -> Hold {
        let field = |k: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(k)?.strip_prefix(": "))
                .unwrap_or("")
                .trim()
                .to_string()
        };
        let kind = match field("kind") {
            k if !k.is_empty() => k,
            _ if resource == "dispatch" => "resource".into(),
            _ => "load".into(),
        };
        Hold {
            resource: resource.to_string(),
            kind,
            by: field("by"),
            since: crate::fleet::ts(&field("since")),
            kept: crate::fleet::ts(&field("kept")),
            reason: field("reason"),
        }
    }

    /// Set by the human, so only the human's word ends it.
    pub fn human(&self) -> bool {
        self.by == HUMAN
    }

    /// True when only the human ends it and it has stood `STANDING_SECS` since it was set, or
    /// since the human last kept it when that is later. A since that does not read stands: it is
    /// as old as anything, as `agent-hold aged` reads it.
    pub fn standing(&self, now: i64) -> bool {
        let theirs = self.kind == "resource" || (self.kind != "claim" && self.human());
        let from = match (self.since, self.kept) {
            (Some(s), Some(k)) => Some(s.max(k)),
            (None, Some(k)) => Some(k),
            (s, None) => s,
        };
        theirs && from.is_none_or(|t| now - t >= STANDING_SECS)
    }

    /// Whole days since it was set, none when its since does not read.
    pub fn days(&self, now: i64) -> Option<i64> {
        self.since.map(|s| (now - s).max(0) / 86400)
    }

    /// The command that prints its file, which every row of it opens to.
    pub fn show(&self) -> String {
        format!("agent-hold show {}", self.resource)
    }

    /// "held 3d by <who>", or "held since an unreadable time by <who>", plus ", kept 1d ago" when
    /// the human re-confirmed it since it was set, so a reader sees the keep took.
    pub fn held(&self, now: i64) -> String {
        let held = match self.days(now) {
            Some(d) => format!("held {d}d by {}", self.by),
            None => format!("held since an unreadable time by {}", self.by),
        };
        match self.kept {
            Some(k) if self.since.is_none_or(|s| k > s) => {
                format!("{held}, kept {}d ago", (now - k).max(0) / 86400)
            }
            _ => held,
        }
    }

    /// Home's state document row for it (`signals::join` writes, `home::needs` reads).
    pub fn json(&self, now: i64) -> Value {
        json!({
            "resource": self.resource,
            "since": self.since,
            "kept": self.kept,
            "held": self.held(now),
            "reason": self.reason,
        })
    }
}

/// The hold directory this process's environment names.
pub fn dir() -> PathBuf {
    match std::env::var_os("AGENT_HOLD_DIR").filter(|v| !v.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".agent/holds"),
    }
}

/// Every hold in `dir`, by resource. No directory is no hold (`agent-hold` makes it on the first
/// set); a directory or a hold file that cannot be read is an error, never a shorter list, since a
/// hold left out is a standing hold shown green. Dot files are `agent-hold`'s temp files mid-rename.
pub fn read(dir: &Path) -> Result<Vec<Hold>, String> {
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    let mut out = vec![];
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        // Anything but a directory is a hold file, so a broken link is a hold that cannot be read.
        if name.starts_with('.') || e.path().is_dir() {
            continue;
        }
        let text = std::fs::read_to_string(e.path())
            .map_err(|err| format!("{}: {err}", e.path().display()))?;
        out.push(Hold::parse(&name, &text));
    }
    out.sort_by(|a, b| a.resource.cmp(&b.resource));
    Ok(out)
}

/// The standing holds of `read`, oldest first.
pub fn standing(holds: Vec<Hold>, now: i64) -> Vec<Hold> {
    let mut out: Vec<Hold> = holds.into_iter().filter(|h| h.standing(now)).collect();
    out.sort_by_key(|h| h.since.unwrap_or(i64::MIN));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn hold(kind: &str, by: &str, age: i64) -> Hold {
        Hold {
            resource: "r".into(),
            kind: kind.into(),
            by: by.into(),
            since: Some(NOW - age),
            kept: None,
            reason: "why".into(),
        }
    }

    #[test]
    fn a_kept_hold_stands_again_only_a_day_past_the_keep() {
        // The human's 4-day-old lockdown, kept an hour ago: not a need until a day past the keep.
        let kept = Hold {
            kept: Some(NOW - 3600),
            ..hold("resource", HUMAN, 4 * 86400)
        };
        assert!(!kept.standing(NOW));
        assert!(kept.standing(NOW - 3600 + STANDING_SECS));
        // Negative control: the same hold never kept stands.
        assert!(hold("resource", HUMAN, 4 * 86400).standing(NOW));
        // A keep older than since (a file written by hand) changes nothing.
        let stale = Hold {
            kept: Some(NOW - 9 * 86400),
            ..hold("resource", HUMAN, 4 * 86400)
        };
        assert!(stale.standing(NOW));
        // A keep with no readable since still counts from the keep.
        let unread = Hold {
            since: None,
            ..kept.clone()
        };
        assert!(!unread.standing(NOW));
        assert_eq!(kept.held(NOW), "held 4d by human, kept 0d ago");
        assert_eq!(stale.held(NOW), "held 4d by human");
        assert_eq!(
            Hold::parse("critical", "kind: resource\nby: human\nsince: 2026-11-20T16:10:54-0800\nkept: 2026-11-24T17:30:08-0800\nkept_ask: M0yWLL\n").kept,
            crate::fleet::ts("2026-11-24T17:30:08-0800")
        );
    }

    #[test]
    fn a_resource_or_human_hold_stands_after_a_day_and_a_load_hold_or_claim_never_does() {
        assert!(hold("resource", "fleet-dispatch", 2 * 86400).standing(NOW));
        assert!(hold("load", HUMAN, 86400).standing(NOW));
        assert!(!hold("resource", HUMAN, 86399).standing(NOW));
        // Negative controls: the shepherd lifts a load hold, and a claim ends with its skill.
        assert!(!hold("load", "fleet-pace", 9 * 86400).standing(NOW));
        assert!(!hold("claim", HUMAN, 9 * 86400).standing(NOW));
        // A since that does not read stands, as agent-hold aged reads it.
        let unread = Hold {
            since: None,
            ..hold("resource", "x", 0)
        };
        assert!(unread.standing(NOW));
        assert_eq!(unread.held(NOW), "held since an unreadable time by x");
    }

    #[test]
    fn a_hold_file_parses_and_a_missing_kind_reads_as_agent_hold_set_gives_it() {
        let h = Hold::parse(
            "critical",
            "resource: critical\nkind: resource\nsince: 2026-11-20T21:55:45-0800\nby: human\nroster: \nreason: lockdown\n",
        );
        assert_eq!(h.kind, "resource");
        assert!(h.human());
        assert_eq!(h.since, crate::fleet::ts("2026-11-20T21:55:45-0800"));
        assert_eq!(h.reason, "lockdown");
        assert_eq!(Hold::parse("dispatch", "by: x\n").kind, "resource");
        assert_eq!(Hold::parse("unity", "by: x\n").kind, "load");
    }

    #[test]
    fn read_skips_temp_files_and_no_directory_is_no_hold() {
        let d = std::env::temp_dir().join(format!("hub-holds-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        assert_eq!(read(&d), Ok(vec![]));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("b"), "kind: resource\nby: human\n").unwrap();
        std::fs::write(d.join(".b.XXXX"), "kind: resource\n").unwrap();
        let got = read(&d).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].resource, "b");
        // A hold file that cannot be read is an error, not a hold left out: a broken link fails
        // the read for any user, root included.
        std::os::unix::fs::symlink(d.join("missing"), d.join("c")).unwrap();
        let err = read(&d);
        std::fs::remove_dir_all(&d).unwrap();
        assert!(err.is_err_and(|e| e.contains("/c: ")));
    }
}
