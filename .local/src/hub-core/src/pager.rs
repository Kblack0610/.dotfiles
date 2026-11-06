//! The needs pager: one grouped page for the rows of `home::needs` that crossed the bar since
//! the last one, at most `max_buzz_day` buzzes a day. `hub needs --page` runs it after every
//! fleet-state pass (`fleet-state.service` ExecStartPost), so an ask pages on the event that
//! filed it. The bar, the cap and the top count are `[pager.needs]` in comms-lint's
//! `channels.toml`, beside the buzz priorities (`[report] buzz`) the cap counts against.
//! `decide` is pure; `run` reads and writes the files around it.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::home::{Kind, Need};
use crate::session_actions::Runner;
use crate::text::{age, cap};

/// The page's fixed title, so the ledger counts this sender (comms-standard: a countable title).
pub const TITLE: &str = "Needs you";
/// The sender `actions::parse_notify` reads from `TITLE`.
const SENDER: &str = "needs";
/// What a phone page may hold (`[channel.page] max_chars`).
const PAGE_MAX: usize = 300;
const FIRST_MAX: usize = 110;
const THEN_MAX: usize = 60;

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Config {
    /// The `Score::value` a row the human must act on reaches before it pages.
    pub min_score: i64,
    /// High pages a day from this sender; past it the page goes out silent, never dropped.
    pub max_buzz_day: usize,
    /// How many rows one page names.
    pub top: usize,
    /// The priorities that buzz (`[report] buzz`).
    #[serde(skip)]
    pub buzz: Vec<String>,
}

/// `[pager.needs]` and `[report] buzz` from `channels.toml`. Every key is required: the file is
/// the one home of these numbers.
pub fn config(text: &str) -> Result<Config, String> {
    #[derive(Deserialize)]
    struct File {
        pager: Option<Pager>,
        report: Option<Report>,
    }
    #[derive(Deserialize)]
    struct Pager {
        needs: Option<Config>,
    }
    #[derive(Deserialize)]
    struct Report {
        buzz: Option<Vec<String>>,
    }
    let f: File = toml::from_str(text).map_err(|e| e.to_string())?;
    let mut c = f
        .pager
        .and_then(|p| p.needs)
        .ok_or("no [pager.needs] table")?;
    c.buzz = f
        .report
        .and_then(|r| r.buzz)
        .ok_or("no [report] buzz list")?;
    Ok(c)
}

/// One page to send.
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub priority: &'static str,
    pub text: String,
    /// `ask:<id>` or `tmux:<target>` for the top row, what `agent-notify open` resolves.
    pub reference: Option<String>,
}

/// What to send, and the ids the paged file keeps after it.
#[derive(Debug, PartialEq)]
pub struct Decision {
    pub page: Option<Page>,
    pub paged: Vec<String>,
}

/// The page for `needs` (in their rank order) given the ids already paged and how many of
/// this sender's pages buzzed in the last day. The paged ids keep only rows still listed, so
/// an answered ask leaves the file and a new ask with its id would page again.
pub fn decide(needs: &[Need], paged: &HashSet<String>, buzzed: usize, cfg: &Config) -> Decision {
    let human: Vec<&Need> = needs
        .iter()
        .filter(|n| n.score.as_ref().is_some_and(|s| s.human))
        .collect();
    let fresh: Vec<&Need> = human
        .iter()
        .copied()
        .filter(|n| n.score.as_ref().is_some_and(|s| s.value >= cfg.min_score))
        .filter(|n| !paged.contains(&n.id))
        .collect();
    let listed: HashSet<&str> = needs.iter().map(|n| n.id.as_str()).collect();
    let mut keep: Vec<String> = paged
        .iter()
        .filter(|id| listed.contains(id.as_str()))
        .cloned()
        .chain(fresh.iter().map(|n| n.id.clone()))
        .collect();
    keep.sort();
    keep.dedup();
    let page = fresh.first().map(|top| Page {
        priority: if buzzed < cfg.max_buzz_day {
            "high"
        } else {
            "normal"
        },
        text: text(&fresh, human.len(), cfg.top.max(1)),
        reference: match top.kind {
            Kind::Ask => Some(format!("ask:{}", top.id)),
            _ => top.target.as_ref().map(|t| format!("tmux:{t}")),
        },
    });
    Decision { page, paged: keep }
}

/// "2 new need you, 5 waiting. First: <ask> (dotfiles, 2h, holds session). Then: <ask>. List:
/// hub Home." The lead says the count; rows past `top`, or past the page's length, fold into
/// "+N more" (comms-standard: group, then point at the list).
fn text(fresh: &[&Need], waiting: usize, top: usize) -> String {
    let n = fresh.len();
    let lead = format!(
        "{n} new need{} you, {waiting} waiting.",
        if n == 1 { "s" } else { "" }
    );
    let first = fresh[0];
    let s = first.score.clone().unwrap_or_default();
    let mut about: Vec<String> = Vec::new();
    if !first.project.is_empty() {
        about.push(first.project.clone());
    }
    about.push(age(s.age_min * 60));
    if !s.holds.is_empty() {
        about.push(format!("holds {}", s.holds));
    }
    let head = format!(
        "{lead} First: {} ({}).",
        cap(&first.text, FIRST_MAX),
        about.join(", ")
    );
    let mut then: Vec<String> = fresh[1..top.min(n)]
        .iter()
        .map(|r| cap(&r.text, THEN_MAX))
        .collect();
    loop {
        let more = n - 1 - then.len();
        let mut t = head.clone();
        if !then.is_empty() {
            t += &format!(" Then: {}", stop(&then.join("; ")));
        }
        if more > 0 {
            t += &format!(" +{more} more.");
        }
        t += " List: hub Home.";
        if t.chars().count() <= PAGE_MAX || then.is_empty() {
            return t;
        }
        then.pop();
    }
}

/// `s` ending as a sentence: a question keeps its own mark.
fn stop(s: &str) -> String {
    if s.ends_with(['.', '?', '!']) {
        s.to_string()
    } else {
        format!("{s}.")
    }
}

/// This sender's buzzing pages in the agent-notify ledger since `now - 1 day`.
pub fn buzzed(ledger: &str, now: i64, cfg: &Config) -> usize {
    let (pages, _) = crate::actions::parse_notify(ledger);
    pages
        .iter()
        .filter(|a| a.actor == SENDER && a.at > now - 86_400)
        .filter(|a| {
            a.priority
                .as_ref()
                .is_some_and(|p| cfg.buzz.iter().any(|b| b == p))
        })
        .count()
}

/// The pager's files, by the variables their owners resolve.
pub struct Paths {
    /// comms-lint's `channels.toml` (`COMMS_CHANNELS`).
    pub config: PathBuf,
    /// agent-notify's ledger (`AGENT_NOTIFY_LOG`).
    pub ledger: PathBuf,
    /// The ids already paged, one a line; the pager is its only writer.
    pub paged: PathBuf,
}

impl Paths {
    pub fn from_env() -> Paths {
        let var = |k: &str| {
            std::env::var_os(k)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Paths {
            config: var("COMMS_CHANNELS")
                .unwrap_or_else(|| home.join(".config/comms-lint/channels.toml")),
            ledger: crate::actions::Paths::from_env().notify_log,
            paged: var("XDG_STATE_HOME")
                .unwrap_or_else(|| home.join(".local/state"))
                .join("hub/needs-paged"),
        }
    }
}

/// Decide and send. A missing paged file or ledger is empty; one that cannot be read is an
/// error and sends nothing, so a fault never pages every row. The paged file is written after
/// the page goes out, so a failed send is tried again on the next pass.
pub fn run(needs: &[Need], now: i64, p: &Paths, r: &dyn Runner) -> Result<Option<Page>, String> {
    let read = |f: &Path| match std::fs::read_to_string(f) {
        Ok(s) => Ok(s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("{}: {e}", f.display())),
    };
    let cfg = config(&read(&p.config)?).map_err(|e| format!("{}: {e}", p.config.display()))?;
    let paged: HashSet<String> = read(&p.paged)?
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();
    let d = decide(needs, &paged, buzzed(&read(&p.ledger)?, now, &cfg), &cfg);
    if let Some(page) = &d.page {
        let mut argv = vec!["agent-notify", "-p", page.priority, "-t", TITLE];
        if let Some(r) = &page.reference {
            argv.extend(["-r", r]);
        }
        argv.push(&page.text);
        r.run(&argv.iter().map(|a| a.to_string()).collect::<Vec<_>>())?;
    }
    let mut now_paged: Vec<&String> = paged.iter().collect();
    now_paged.sort();
    if d.paged.iter().collect::<Vec<_>>() != now_paged {
        write(&p.paged, &d.paged).map_err(|e| format!("{}: {e}", p.paged.display()))?;
    }
    Ok(d.page)
}

fn write(f: &Path, ids: &[String]) -> std::io::Result<()> {
    if let Some(dir) = f.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = f.with_extension("tmp");
    let body: String = ids.iter().map(|i| format!("{i}\n")).collect();
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, f)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::home::Score;

    fn cfg() -> Config {
        config(
            "[report]\nbuzz = [\"high\", \"urgent\"]\n\
             [pager.needs]\nmin_score = 60\nmax_buzz_day = 6\ntop = 3\n",
        )
        .unwrap()
    }

    fn row(kind: Kind, id: &str, human: bool, value: i64) -> Need {
        Need {
            kind,
            need: crate::home::NeedKind::Ask,
            rank: 0,
            project: "dotfiles".into(),
            text: format!("Question {id}?"),
            id: id.into(),
            target: Some(format!("hub/{id}:1")),
            since: None,
            recommend: None,
            score: Some(Score {
                value,
                ..Score::new(human, true, 0, 0, 120)
            }),
        }
    }

    fn set(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_shipped_channels_file_carries_the_pager_numbers() {
        let f = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../.config/comms-lint/channels.toml"
        );
        let c = config(&std::fs::read_to_string(f).unwrap()).unwrap();
        assert!(c.min_score > 0 && c.top > 0);
        assert_eq!(c.buzz, ["high", "urgent"]);
        assert!(config("[report]\nbuzz = []\n").is_err());
    }

    #[test]
    fn new_rows_above_the_bar_page_once_as_one_grouped_page() {
        let needs = [
            row(Kind::Ask, "a1", true, 600),
            row(Kind::Session, "s1", true, 90),
            row(Kind::Queue, "low", true, 59),
        ];
        let d = decide(&needs, &set(&[]), 0, &cfg());
        let p = d.page.unwrap();
        assert_eq!(p.priority, "high");
        assert_eq!(p.reference.as_deref(), Some("ask:a1"));
        assert_eq!(
            p.text,
            "2 new need you, 3 waiting. First: Question a1? (dotfiles, 2h, holds session). \
             Then: Question s1? List: hub Home."
        );
        assert_eq!(d.paged, ["a1", "s1"]);
        // The next pass has told the human already.
        let again = decide(&needs, &set(&["a1", "s1"]), 1, &cfg());
        assert_eq!(again.page, None);
        assert_eq!(again.paged, ["a1", "s1"]);
    }

    #[test]
    fn past_the_cap_the_page_goes_silent_and_is_never_dropped() {
        let needs = [row(Kind::Session, "s1", true, 90)];
        let p = decide(&needs, &set(&[]), 6, &cfg()).page.unwrap();
        assert_eq!(p.priority, "normal");
        assert_eq!(p.reference.as_deref(), Some("tmux:hub/s1:1"));
        assert!(p.text.starts_with("1 new needs you, 1 waiting."));
    }

    #[test]
    fn an_answered_ask_leaves_the_paged_file() {
        let needs = [row(Kind::Ask, "a2", true, 10)];
        let d = decide(&needs, &set(&["gone", "a2"]), 0, &cfg());
        assert_eq!(d.page, None);
        assert_eq!(d.paged, ["a2"]);
    }

    #[test]
    fn a_row_a_machine_can_answer_never_pages_however_old() {
        // Negative control: ten days old, far over the bar, and the judge said take-recommend.
        let needs = [row(Kind::Ask, "auto", false, 14_400 * 2)];
        let d = decide(&needs, &set(&[]), 0, &cfg());
        assert_eq!(d.page, None);
        assert!(d.paged.is_empty());
    }

    #[test]
    fn a_long_page_folds_its_tail_into_more() {
        let mut needs: Vec<Need> = (0..6)
            .map(|i| row(Kind::Ask, &format!("a{i}"), true, 100))
            .collect();
        for n in &mut needs {
            n.text = "word ".repeat(40);
        }
        let p = decide(&needs, &set(&[]), 0, &cfg()).page.unwrap();
        assert!(p.text.chars().count() <= PAGE_MAX, "{}", p.text);
        assert!(p.text.ends_with("more. List: hub Home."), "{}", p.text);
    }

    #[test]
    fn the_cap_counts_this_senders_buzzes_in_the_last_day() {
        let now = 1_793_898_000;
        let line = |at: i64, prio: &str, title: &str| {
            let t = chrono::DateTime::from_timestamp(at, 0)
                .unwrap()
                .to_rfc3339();
            format!("{t}\t{prio}\t{title}\tmsg\task:x\n")
        };
        let ledger = [
            line(now - 60, "high", TITLE),
            line(now - 3600, "urgent", TITLE),
            line(now - 60, "normal", TITLE),
            line(now - 60, "high", "Sentinel: watch:x"),
            line(now - 90_000, "high", TITLE),
        ]
        .concat();
        assert_eq!(buzzed(&ledger, now, &cfg()), 2);
    }

    /// A Runner that records each argv and answers with `fail` when set.
    struct Record(std::cell::RefCell<Vec<Vec<String>>>, Option<&'static str>);
    impl Runner for Record {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.0.borrow_mut().push(argv.to_vec());
            self.1.map_or(Ok(String::new()), |e| Err(e.into()))
        }
    }

    fn paths(name: &str) -> Paths {
        let dir =
            std::env::temp_dir().join(format!("hub-core-pager-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("channels.toml");
        std::fs::write(
            &config,
            "[report]\nbuzz = [\"high\", \"urgent\"]\n[pager.needs]\nmin_score = 60\nmax_buzz_day = 6\ntop = 3\n",
        )
        .unwrap();
        Paths {
            config,
            ledger: dir.join("log"),
            paged: dir.join("state/needs-paged"),
        }
    }

    #[test]
    fn run_pages_once_then_stays_quiet_and_its_page_passes_comms_lint() {
        let p = paths("once");
        let needs = [
            row(Kind::Ask, "a1", true, 600),
            row(Kind::Session, "s1", true, 90),
        ];
        let r = Record(Default::default(), None);
        let page = run(&needs, 0, &p, &r).unwrap().unwrap();
        assert_eq!(std::fs::read_to_string(&p.paged).unwrap(), "a1\ns1\n");
        assert_eq!(
            run(&needs, 60, &p, &r).unwrap(),
            None,
            "the second pass has told the human"
        );
        let sent = r.0.into_inner();
        assert_eq!(sent.len(), 1);
        assert_eq!(
            sent[0][..7],
            ["agent-notify", "-p", "high", "-t", TITLE, "-r", "ask:a1"]
        );
        assert_eq!(sent[0][7], page.text);
        // comms-standard rule 12: the page as sent passes the page channel's lint.
        // The repo's channels file, not the stowed one: CI has no ~/.config.
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let mut c = std::process::Command::new(repo.join(".local/bin/comms-lint"))
            .env(
                "COMMS_CHANNELS",
                repo.join(".config/comms-lint/channels.toml"),
            )
            .args([
                "--channel",
                "page",
                "--priority",
                "high",
                "--title",
                TITLE,
                "-",
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        c.stdin
            .take()
            .unwrap()
            .write_all(page.text.as_bytes())
            .unwrap();
        let out = c.wait_with_output().unwrap();
        let said = [out.stdout, out.stderr].concat();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&said));
    }

    #[test]
    fn a_failed_send_is_tried_again_and_an_unreadable_file_sends_nothing() {
        let p = paths("fail");
        let needs = [row(Kind::Ask, "a1", true, 600)];
        assert!(run(&needs, 0, &p, &Record(Default::default(), Some("down"))).is_err());
        assert!(
            !p.paged.exists(),
            "nothing is marked told when the page did not go out"
        );
        // Negative control: a paged file that cannot be read pages nothing, never every row.
        std::fs::create_dir_all(&p.paged).unwrap();
        let r = Record(Default::default(), None);
        assert!(run(&needs, 0, &p, &r).is_err());
        assert!(r.0.into_inner().is_empty());
    }
}
