//! The file-backed sources: the Unity gate ledger, and the local test runs `tests/run-bats.sh`
//! records (its ledger, and one live file per run waiting for or holding the machine's slot).

use super::{Got, Job, Paths, Source, State};

/// A slots ledger: `end start result kind worktree branch repo`, tab-separated, the Unity gates'
/// and the local tests' alike. The tests ledger adds `waited what`: seconds spent waiting for the
/// slot, and the test files.
pub(super) fn parse_runs(text: &str, since: i64, source: Source) -> (Vec<Job>, usize) {
    let mut bad = 0;
    let mut jobs = vec![];
    for l in text.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = l.split('\t').collect();
        let (Some(end), Some(start)) = (
            f.first().and_then(|v| v.parse::<i64>().ok()),
            f.get(1).and_then(|v| v.parse::<i64>().ok()),
        ) else {
            bad += 1;
            continue;
        };
        if end < since {
            continue;
        }
        let g = |i: usize| f.get(i).copied().unwrap_or("");
        let mut j = Job::new(
            source,
            format!("{} {}", g(6), g(3)).trim().to_string(),
            State::Done,
        );
        j.result = g(2).to_string();
        // killed and flood are the slots refusing or stopping a run, not the tests' verdict.
        j.ok = match g(2) {
            "pass" => Some(true),
            "fail" | "timeout" | "error" => Some(false),
            _ => None,
        };
        j.started = Some(start);
        j.finished = Some(end);
        j.secs = Some(end - start);
        j.detail = detail(g(5), g(4), g(7), g(8));
        jobs.push(j);
    }
    (jobs, bad)
}

/// `branch worktree`, then for a local test run what it ran and how long it waited for the slot.
fn detail(branch: &str, worktree: &str, waited: &str, what: &str) -> String {
    let mut parts = vec![branch, worktree, what];
    let w = waited.parse::<i64>().unwrap_or(0);
    let waited = format!("waited {w}s");
    if w > 0 {
        parts.push(&waited);
    }
    parts
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// One live run, `<live>/<pid>`: `since state kind worktree branch repo what`, where since is when
/// it entered its state (waiting for the slot, or running). A file whose pid is gone is a run
/// killed past its traps, and is not listed.
pub(super) fn parse_live(text: &str, at: i64) -> Option<Job> {
    let f: Vec<&str> = text.trim_end_matches('\n').split('\t').collect();
    let since = f.first()?.parse::<i64>().ok()?;
    let state = match *f.get(1)? {
        "waiting" => State::Queued,
        "running" => State::Running,
        _ => return None,
    };
    let g = |i: usize| f.get(i).copied().unwrap_or("");
    let mut j = Job::new(
        Source::Tests,
        format!("{} {}", g(5), g(2)).trim().to_string(),
        state,
    );
    j.started = Some(since);
    j.secs = Some(at - since);
    j.detail = detail(g(4), g(3), "", g(6));
    Some(j)
}

fn ledger(path: &std::path::Path, since: i64, source: Source) -> Got {
    match std::fs::read_to_string(path) {
        Ok(t) => {
            let (jobs, bad) = parse_runs(&t, since, source);
            let errs = if bad > 0 {
                vec![format!(
                    "{bad} unreadable line(s) in {} skipped",
                    path.display()
                )]
            } else {
                vec![]
            };
            (jobs, errs)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (vec![], vec![]),
        Err(e) => (vec![], vec![format!("{}: {e}", path.display())]),
    }
}

pub(super) fn unity(paths: &Paths, since: i64) -> Got {
    ledger(&paths.unity_runs, since, Source::Unity)
}

/// The local test runs: those that finished in the window, then those waiting or running now.
pub(super) fn tests(paths: &Paths, since: i64, at: i64) -> Got {
    let (mut jobs, mut errs) = ledger(&paths.test_runs, since, Source::Tests);
    match std::fs::read_dir(&paths.test_live) {
        Ok(dir) => {
            for e in dir.flatten() {
                let pid = e.file_name().to_string_lossy().into_owned();
                if !std::path::Path::new("/proc").join(&pid).exists() {
                    continue;
                }
                match std::fs::read_to_string(e.path()) {
                    Ok(t) => match parse_live(&t, at) {
                        Some(j) => jobs.push(j),
                        None => errs.push(format!("{}: unreadable", e.path().display())),
                    },
                    // The run ended between the listing and the read.
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                    Err(err) => errs.push(format!("{}: {err}", e.path().display())),
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => errs.push(format!("{}: {e}", paths.test_live.display())),
    }
    (jobs, errs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unity_rows_and_a_bad_row() {
        let text = "200\t100\tpass\tPlayMode\twt-1\tfeat/x\tplayground\ngarbage\n50\t10\tfail\tEditMode\twt\tb\tr\n300\t250\tkilled\tEditMode\twt\tb\tr\n";
        let (jobs, bad) = parse_runs(text, 60, Source::Unity);
        assert_eq!(bad, 1);
        assert_eq!(jobs.len(), 2);
        assert_eq!(
            (jobs[0].name.as_str(), jobs[0].secs, jobs[0].ok),
            ("playground PlayMode", Some(100), Some(true))
        );
        assert_eq!(jobs[0].detail, "feat/x wt-1");
        assert_eq!(jobs[1].ok, None);
    }

    #[test]
    fn a_test_run_row_names_its_files_and_its_wait() {
        let text =
            "200\t150\tfail\tbats\tdotfiles-agent-7\tfix/x\tdotfiles\t42\tclaude_acct.bats\n\
                    300\t290\tpass\tbats\tdotfiles\tmain\tdotfiles\t0\tpick.bats\n";
        let (jobs, bad) = parse_runs(text, 0, Source::Tests);
        assert_eq!(bad, 0);
        assert_eq!(
            (jobs[0].source, jobs[0].name.as_str(), jobs[0].ok),
            (Source::Tests, "dotfiles bats", Some(false))
        );
        assert_eq!(
            jobs[0].detail,
            "fix/x dotfiles-agent-7 claude_acct.bats waited 42s"
        );
        assert_eq!(
            jobs[1].detail, "main dotfiles pick.bats",
            "no wait, none shown"
        );
    }

    #[test]
    fn a_live_run_is_waiting_or_running_since_its_state_began() {
        let w = parse_live(
            "100\twaiting\tbats\twt-3\tfeat/y\tdotfiles\ta.bats b.bats\n",
            130,
        )
        .unwrap();
        assert_eq!(
            (w.state, w.secs, w.started),
            (State::Queued, Some(30), Some(100))
        );
        assert_eq!(w.name, "dotfiles bats");
        assert_eq!(w.detail, "feat/y wt-3 a.bats b.bats");
        let r = parse_live("120\trunning\tbats\twt-3\tfeat/y\tdotfiles\t\n", 130).unwrap();
        assert_eq!(r.state, State::Running);
        assert!(parse_live("garbage", 130).is_none());
        assert!(parse_live("100\tdone\tbats\n", 130).is_none());
    }

    #[test]
    fn live_files_of_dead_pids_are_not_listed() {
        let d = std::env::temp_dir().join(format!("hub-tests-live-{}", std::process::id()));
        let live = d.join("live");
        std::fs::create_dir_all(&live).unwrap();
        let me = std::process::id().to_string();
        std::fs::write(
            live.join(&me),
            "100\trunning\tbats\twt\tb\tdotfiles\tx.bats\n",
        )
        .unwrap();
        // pid_max is at most 2^22, so this pid never exists.
        std::fs::write(
            live.join("99999999"),
            "100\twaiting\tbats\twt\tb\tdotfiles\t\n",
        )
        .unwrap();
        let paths = Paths {
            agentctl: d.clone(),
            unity_runs: d.join("unity.tsv"),
            test_runs: d.join("runs.tsv"),
            test_live: live,
            cache: d.join("cache"),
            builds: crate::builds::Paths::from_env(),
        };
        let (jobs, errs) = tests(&paths, 0, 160);
        std::fs::remove_dir_all(&d).ok();
        assert!(errs.is_empty(), "{errs:?}");
        assert_eq!(jobs.len(), 1);
        assert_eq!((jobs[0].state, jobs[0].secs), (State::Running, Some(60)));
    }
}
