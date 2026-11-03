//! Reads one run's log from a `LogRef`. A reference can come back from a browser, so every
//! field is checked against its own narrow shape before it becomes a path or an argument.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::process::Command;

use super::{LogRef, Paths};

/// The most of a log returned at once: its tail, which is where a failure is.
pub const LOG_TAIL_BYTES: u64 = 256 * 1024;

fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('.')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@._-".contains(&b))
}

/// Bytes `from..to` of a file (to the end when `to` is None), at most the last
/// `LOG_TAIL_BYTES` of that range.
fn slice(path: &Path, from: u64, to: Option<u64>) -> Result<String, String> {
    let mut f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let len = f.metadata().map_err(|e| e.to_string())?.len();
    let end = to.unwrap_or(len).min(len);
    if from > len {
        return Ok(format!(
            "(rotated away: this run's output was at bytes {from}.. of a file now {len} long)\n"
        ));
    }
    let start = from.max(end.saturating_sub(LOG_TAIL_BYTES));
    let mut buf = vec![0; (end.saturating_sub(start)) as usize];
    f.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
    f.read_exact(&mut buf).map_err(|e| e.to_string())?;
    let mut s = String::from_utf8_lossy(&buf).into_owned();
    if start > from {
        s.insert_str(0, &format!("(first {} bytes not shown)\n", start - from));
    }
    Ok(s)
}

fn tail_file(path: &Path) -> Result<String, String> {
    slice(path, 0, None)
}

pub(super) fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd)
        .args(args)
        .output()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{cmd}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// A GitHub Actions URL as (owner/repo, run id, job id).
pub(super) fn parse_gh(url: &str) -> Option<(String, u64, Option<u64>)> {
    let rest = url.strip_prefix("https://github.com/")?;
    let p: Vec<&str> = rest.split('/').collect();
    if p.len() < 5 || p[2] != "actions" || p[3] != "runs" || !safe_name(p[0]) || !safe_name(p[1]) {
        return None;
    }
    let run = p[4].parse().ok()?;
    let job = match (p.get(5), p.get(6)) {
        (Some(&"job"), Some(j)) => Some(j.parse().ok()?),
        (None, _) => None,
        _ => return None,
    };
    Some((format!("{}/{}", p[0], p[1]), run, job))
}

fn gh_log(paths: &Paths, url: &str, done: bool) -> Result<String, String> {
    let (repo, id, job) = parse_gh(url).ok_or("not a GitHub Actions run URL")?;
    if !done {
        return Ok(format!(
            "GitHub serves a log once the job ends. Live: {url}\n"
        ));
    }
    // A finished run's log never changes, so it is fetched once: the API budget is shared.
    let dir = paths.cache.join("gh");
    let file = dir.join(format!(
        "{}-{id}{}.log",
        repo.replace('/', "_"),
        job.map(|j| format!("-{j}")).unwrap_or_default()
    ));
    if file.exists() {
        return tail_file(&file);
    }
    let id_s = id.to_string();
    let job_s = job.map(|j| j.to_string());
    let mut args = vec!["run", "view", &id_s, "-R", &repo];
    if let Some(j) = &job_s {
        args.extend(["--job", j]);
    }
    // The failed steps when there are any, else the whole log: one call either way when it failed.
    let mut text = run("gh", &[&args[..], &["--log-failed"]].concat())?;
    if text.trim().is_empty() {
        text = run("gh", &[&args[..], &["--log"]].concat())?;
    }
    let keep = text.len().saturating_sub(LOG_TAIL_BYTES as usize);
    let keep = (keep..text.len())
        .find(|&i| text.is_char_boundary(i))
        .unwrap_or(text.len());
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(&file, &text[keep..]).map_err(|e| e.to_string())?;
    Ok(text[keep..].to_string())
}

/// The log behind a job row, as text.
pub fn read_log(paths: &Paths, r: &LogRef) -> Result<String, String> {
    match r {
        LogRef::Runner { name, out, err } => {
            if !safe_name(name) {
                return Err("bad runner name".into());
            }
            let o = slice(
                &paths.agentctl.join(format!("{name}.stdout.log")),
                out.0,
                out.1,
            )?;
            let e = slice(
                &paths.agentctl.join(format!("{name}.stderr.log")),
                err.0,
                err.1,
            )?;
            Ok(match (o.is_empty(), e.is_empty()) {
                (true, true) => "(this run wrote nothing)\n".into(),
                (false, true) => o,
                _ => format!("{o}\n--- stderr ---\n{e}"),
            })
        }
        LogRef::Journal { invocation } => {
            if invocation.len() != 32 || !invocation.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err("bad invocation id".into());
            }
            let text = run(
                "journalctl",
                &[
                    "--user",
                    "-q",
                    "--no-pager",
                    "-o",
                    "short-iso",
                    "-n",
                    "2000",
                    &format!("_SYSTEMD_INVOCATION_ID={invocation}"),
                ],
            )?;
            Ok(if text.is_empty() {
                "(this run wrote nothing to the journal, or it has rotated away)\n".into()
            } else {
                text
            })
        }
        LogRef::Night { slug } => {
            if !safe_name(slug) {
                return Err("bad slug".into());
            }
            tail_file(&paths.night_logs.join(format!("{slug}.log")))
        }
        LogRef::Gh { url, done } => gh_log(paths, url, *done),
        LogRef::K8s { ns, job, from, to } => super::loki::job_log(ns, job, *from, *to),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(dir: &Path) -> Paths {
        Paths {
            agentctl: dir.to_path_buf(),
            night: dir.to_path_buf(),
            night_logs: dir.to_path_buf(),
            unity_runs: dir.join("runs.tsv"),
            cache: dir.join("cache"),
        }
    }

    #[test]
    fn a_runner_log_is_its_own_byte_range() {
        let d = std::env::temp_dir().join(format!("hub-log-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("r.stdout.log"), "old run\nthis run\n").unwrap();
        let p = paths(&d);
        let got = read_log(
            &p,
            &LogRef::Runner {
                name: "r".into(),
                out: (8, Some(17)),
                err: (0, Some(0)),
            },
        );
        let live = read_log(
            &p,
            &LogRef::Runner {
                name: "r".into(),
                out: (8, None),
                err: (0, None),
            },
        );
        let rotated = read_log(
            &p,
            &LogRef::Runner {
                name: "r".into(),
                out: (900, Some(950)),
                err: (0, Some(0)),
            },
        );
        std::fs::remove_dir_all(&d).unwrap();
        assert_eq!(got.unwrap(), "this run\n");
        assert_eq!(live.unwrap(), "this run\n");
        assert!(rotated.unwrap().starts_with("(rotated away"));
    }

    #[test]
    fn a_reference_from_outside_cannot_name_another_file() {
        let p = paths(Path::new("/nonexistent"));
        for name in ["../../etc/passwd", "a/b", ".hidden", ""] {
            let r = LogRef::Runner {
                name: name.into(),
                out: (0, None),
                err: (0, None),
            };
            assert!(read_log(&p, &r).is_err(), "{name}");
            assert!(
                read_log(&p, &LogRef::Night { slug: name.into() }).is_err(),
                "{name}"
            );
        }
        assert!(read_log(
            &p,
            &LogRef::Journal {
                invocation: "x; rm -rf ~".into()
            }
        )
        .is_err());
        assert!(read_log(
            &p,
            &LogRef::Gh {
                url: "https://evil.example/actions/runs/1".into(),
                done: true
            }
        )
        .is_err());
    }

    #[test]
    fn gh_urls_parse_to_repo_run_and_job() {
        assert_eq!(
            parse_gh("https://github.com/O/r/actions/runs/12"),
            Some(("O/r".into(), 12, None))
        );
        assert_eq!(
            parse_gh("https://github.com/O/r/actions/runs/12/job/34"),
            Some(("O/r".into(), 12, Some(34)))
        );
        assert_eq!(
            parse_gh("https://github.com/O/r/actions/runs/12/attempts/2"),
            None
        );
        assert_eq!(parse_gh("https://github.com/O/r/pull/12"), None);
    }
}
