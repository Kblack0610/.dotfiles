//! The file-backed source: the Unity gate ledger.

use super::{Got, Job, Paths, Source, State};

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
}
