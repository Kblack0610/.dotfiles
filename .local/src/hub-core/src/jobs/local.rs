//! The file-backed sources: night-shift's queue/running/done tree and the Unity gate ledger.

use std::os::unix::fs::MetadataExt;
use std::path::Path;

use chrono::DateTime;

use super::{Got, Job, LogRef, Paths, Source, State};

/// Night-shift's `key: value` lines up to the `---` line (night-shift's own `fm_get`).
fn front_matter(text: &str) -> Vec<(&str, &str)> {
    text.lines()
        .take_while(|l| *l != "---")
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim(), v.trim()))
        .collect()
}

fn fm<'a>(f: &[(&'a str, &'a str)], k: &str) -> &'a str {
    f.iter()
        .find(|(key, _)| *key == k)
        .map(|(_, v)| *v)
        .unwrap_or("")
}

fn iso(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp())
}

fn md_files(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    v.sort();
    v
}

fn repo_name(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
}

/// One finished night-shift task from its `<slug>.result.md`.
pub(super) fn parse_result(slug: &str, text: &str) -> Job {
    let f = front_matter(text);
    let mut j = Job::new(Source::Night, slug, State::Done);
    let status = fm(&f, "status");
    j.ok = match status {
        "ok" => Some(true),
        "failed" => Some(false),
        _ => None,
    };
    j.result = status.to_string();
    j.started = iso(fm(&f, "started"));
    j.finished = iso(fm(&f, "finished"));
    j.secs = j.started.zip(j.finished).map(|(s, e)| e - s);
    let pr = fm(&f, "pr");
    j.detail = [repo_name(fm(&f, "repo")), fm(&f, "summary")]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(": ");
    if pr.starts_with("http") {
        j.url = Some(pr.to_string());
    }
    // A skipped task never ran, so it has no log.
    if !fm(&f, "log").is_empty() {
        j.log = Some(LogRef::Night {
            slug: slug.to_string(),
        });
    }
    j
}

pub(super) fn night(paths: &Paths, since: i64, at: i64) -> Got {
    let mut jobs = vec![];
    for (sub, state) in [("queue", State::Queued), ("running", State::Running)] {
        for p in md_files(&paths.night.join(sub)) {
            let Ok(text) = std::fs::read_to_string(&p) else {
                continue;
            };
            let f = front_matter(&text);
            let slug = fm(&f, "slug");
            if slug.is_empty() {
                continue;
            }
            let mut j = Job::new(Source::Night, slug, state);
            j.detail = repo_name(fm(&f, "repo")).to_string();
            if state == State::Queued {
                j.secs = iso(fm(&f, "queued")).map(|q| at - q);
            } else {
                // The task file was renamed into running/ when it started, and a rename sets ctime.
                j.started = std::fs::metadata(&p).ok().map(|m| m.ctime());
                j.secs = j.started.map(|s| at - s);
                j.log = Some(LogRef::Night {
                    slug: slug.to_string(),
                });
            }
            jobs.push(j);
        }
    }
    // done/<YYYY-MM-DD>/: a night's dir is named for the morning it ran into, so read every
    // dir from the day before the window starts.
    let first = DateTime::from_timestamp(since - 86_400, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    let done = paths.night.join("done");
    let mut nights: Vec<_> = std::fs::read_dir(&done)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.len() == 10 && *n >= first)
        .collect();
    nights.sort();
    for n in nights {
        for p in md_files(&done.join(&n)) {
            let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
            let Some(slug) = name.strip_suffix(".result.md") else {
                continue;
            };
            let Ok(text) = std::fs::read_to_string(&p) else {
                continue;
            };
            let j = parse_result(slug, &text);
            if j.finished.unwrap_or(at) >= since {
                jobs.push(j);
            }
        }
    }
    (jobs, vec![])
}

/// The Unity slots ledger: `end start result platform worktree branch repo`, tab-separated.
pub(super) fn parse_unity(text: &str, since: i64) -> (Vec<Job>, usize) {
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
            Source::Unity,
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
        j.detail = format!("{} {}", g(5), g(4)).trim().to_string();
        jobs.push(j);
    }
    (jobs, bad)
}

pub(super) fn unity(paths: &Paths, since: i64) -> Got {
    match std::fs::read_to_string(&paths.unity_runs) {
        Ok(t) => {
            let (jobs, bad) = parse_unity(&t, since);
            let errs = if bad > 0 {
                vec![format!(
                    "{bad} unreadable line(s) in {} skipped",
                    paths.unity_runs.display()
                )]
            } else {
                vec![]
            };
            (jobs, errs)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (vec![], vec![]),
        Err(e) => (vec![], vec![format!("{}: {e}", paths.unity_runs.display())]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_result_file_reads_as_a_finished_run() {
        let j = parse_result(
            "fix-the-thing",
            "status: ok\nrepo: /home/u/repo/dotfiles\npr: https://github.com/o/r/pull/9\nasks: none\nsummary: did it\nexit: 0\nsession: s\nstarted: 2026-11-03T01:00:00-08:00\nfinished: 2026-11-03T01:30:05-08:00\nlog: /x/fix-the-thing.log\n---\nstatus: failed\n",
        );
        assert_eq!(j.ok, Some(true), "the body after --- is never front matter");
        assert_eq!(j.secs, Some(1805));
        assert_eq!(j.detail, "dotfiles: did it");
        assert_eq!(j.url.as_deref(), Some("https://github.com/o/r/pull/9"));
        assert!(j.log.is_some());
    }

    #[test]
    fn a_skipped_task_has_no_log_and_no_verdict() {
        let j = parse_result("b", "status: skipped\nrepo: r\npr: none\nsummary: after a\nfinished: 2026-11-03T01:00:00-08:00\n---\n");
        assert_eq!((j.ok, j.log.is_none(), j.started), (None, true, None));
    }

    #[test]
    fn unity_rows_and_a_bad_row() {
        let text = "200\t100\tpass\tPlayMode\twt-1\tfeat/x\tplayground\ngarbage\n50\t10\tfail\tEditMode\twt\tb\tr\n300\t250\tkilled\tEditMode\twt\tb\tr\n";
        let (jobs, bad) = parse_unity(text, 60);
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
    fn night_lists_queue_running_and_done() {
        let d = std::env::temp_dir().join(format!("hub-night-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        for sub in ["queue", "running", "done/2026-11-03"] {
            std::fs::create_dir_all(d.join(sub)).unwrap();
        }
        std::fs::write(
            d.join("queue/1-a.md"),
            "slug: a\nrepo: /r/one\nqueued: 2026-11-03T00:00:00Z\n---\ndo a\n",
        )
        .unwrap();
        std::fs::write(d.join("running/2-b.md"), "slug: b\nrepo: /r/two\n---\n").unwrap();
        std::fs::write(
            d.join("done/2026-11-03/c.result.md"),
            "status: failed\nrepo: r\nfinished: 2026-11-03T02:00:00Z\nlog: x\n---\n",
        )
        .unwrap();
        std::fs::write(d.join("done/2026-11-03/c.md"), "slug: c\n---\n").unwrap();
        let paths = Paths {
            night: d.clone(),
            ..Paths::from_env()
        };
        let at = iso("2026-11-03T03:00:00Z").unwrap();
        let (jobs, errs) = night(&paths, at - 86_400, at);
        std::fs::remove_dir_all(&d).unwrap();
        assert!(errs.is_empty());
        let states: Vec<_> = jobs.iter().map(|j| (j.name.as_str(), j.state)).collect();
        assert_eq!(
            states,
            [
                ("a", State::Queued),
                ("b", State::Running),
                ("c", State::Done)
            ]
        );
        assert_eq!(jobs[0].secs, Some(3 * 3600));
        assert_eq!(jobs[2].ok, Some(false));
    }
}
