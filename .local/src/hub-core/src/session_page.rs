//! One session's page on both surfaces: everything joined to it, each part read from the store
//! that owns it, as label and text so a surface only draws. The session comes from a
//! `session_table` row; on top of that the queue item (`agent-queue show`), its board row (`notes
//! board`), its budget (`fleet-shepherd budget`), the asks its session filed (`agent-ask list`,
//! by `claude_session`), the shepherd's ledger file for it and, once it has ended, its outcome
//! card. The transcript is not part of the read: it loads when it is opened (dashboards rule 10).

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::boards;
use crate::home::str_of;
use crate::outcomes;
use crate::queue::{self, Item};
use crate::reds;
use crate::session_actions::Runner;
use crate::session_table::{SessionRow, Source};
use crate::tasks;
use crate::text::{cap, headline, TITLE_MAX};

/// What a page says when its outcome card has not been written, for a session that has ended.
pub const NO_CARD: &str = "No outcome card yet: the nightly run writes it.";

/// One labelled line of the page.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Part {
    pub label: &'static str,
    pub text: String,
    /// Where the fact has its home: a URL, or a `#tab` of agent-web.
    pub link: Option<String>,
    /// It needs attention, so it shows amber.
    pub warn: bool,
}

impl Part {
    fn new(label: &'static str, text: impl Into<String>) -> Part {
        Part {
            label,
            text: text.into(),
            ..Part::default()
        }
    }

    fn link(self, to: impl Into<String>) -> Part {
        Part {
            link: Some(to.into()),
            ..self
        }
    }

    fn warn(self, warn: bool) -> Part {
        Part { warn, ..self }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SessionPage {
    /// The session's name on its head: its target, else a short id or its item.
    pub name: String,
    pub session_id: String,
    pub target: String,
    pub bucket: String,
    pub task: String,
    /// `3m idle` while it lives, else how it ended.
    pub idle: String,
    pub parts: Vec<Part>,
    /// The outcome card or `NO_CARD`; empty while the session lives.
    pub outcome: String,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// The row a page id names: a session id, a live row's target or an ended row's item.
pub fn find<'a>(rows: &'a [SessionRow], id: &str) -> Option<&'a SessionRow> {
    if id.is_empty() {
        return None;
    }
    rows.iter()
        .find(|r| r.session_id == id || r.key == id || r.target == id || r.item == id)
}

/// A session past the table's window has no row, but its outcome card still names it.
fn old_row(id: &str, card: &str) -> SessionRow {
    SessionRow {
        key: id.to_string(),
        bucket: "DONE".into(),
        task: headline(card).0,
        session_id: id.to_string(),
        ended: "ended".into(),
        source: Source::Outcome,
        ..SessionRow::default()
    }
}

/// The page for `id`, or None when nothing names it. `ledger` is the shepherd's directory. A
/// source that fails leaves its part saying so and its reason in `errors`.
pub fn read(
    runner: &dyn Runner,
    ledger: &Path,
    id: &str,
    rows: &[SessionRow],
    state: &[Value],
) -> Option<SessionPage> {
    let row = find(rows, id);
    let sid = row.map_or(id, |r| r.session_id.as_str());
    let ended = row.is_none_or(|r| r.source != Source::Live);
    let card = (ended && !sid.is_empty())
        .then(|| outcomes::card(runner, sid).ok())
        .flatten();
    let row = match row {
        Some(r) => r.clone(),
        None => old_row(id, card.as_deref()?),
    };
    let live = state.iter().find(|s| {
        row.source == Source::Live
            && (s["target"] == row.target.as_str()
                || (!sid.is_empty() && s["session_id"] == row.session_id.as_str()))
    });
    let mut errors = vec![];
    let mut fail = |source: &str, why: String| errors.push(format!("{source}: {why}"));
    let item = (!row.item.is_empty())
        .then(|| {
            queue::show(runner, &row.item)
                .map_err(|e| fail("agent-queue", e))
                .ok()
        })
        .flatten();
    let budget = item
        .as_ref()
        .and_then(|i| budget(runner, &i.task).map_err(|e| fail("budget", e)).ok());
    let board = item
        .as_ref()
        .and_then(|i| i.row.as_deref())
        .map(|r| board_part(runner, r, &mut fail));
    let asks = if row.session_id.is_empty() {
        Some(vec![])
    } else {
        asks(runner, &row.session_id)
            .map_err(|e| fail("agent-ask", e))
            .ok()
    };
    let parts = vec![
        item_part(&row, item.as_ref(), live),
        board.unwrap_or_else(|| Part::new("Board row", "no board row")),
        plan_part(live, item.as_ref()),
        worktree_part(live, item.as_ref()),
        pr_part(&row, live, item.as_ref()),
        spend_part(&row, budget.as_ref()),
        asks_part(asks.as_deref()),
        shepherd_part(&Ledger::read(ledger, &row.session_id), live),
    ];
    let outcome = card
        .or_else(|| ended.then(|| NO_CARD.to_string()))
        .unwrap_or_default();
    Some(SessionPage {
        name: name(&row),
        session_id: row.session_id.clone(),
        target: row.target.clone(),
        bucket: row.bucket.clone(),
        task: row.task.clone(),
        idle: idle(&row),
        parts,
        outcome,
        errors,
    })
}

fn name(r: &SessionRow) -> String {
    if !r.target.is_empty() {
        r.target.clone()
    } else if !r.item.is_empty() {
        r.item.clone()
    } else {
        r.session_id.chars().take(8).collect()
    }
}

fn idle(r: &SessionRow) -> String {
    if r.ended.is_empty() {
        r.idle_min
            .map_or(String::new(), |m| format!("{} idle", queue::dur(Some(m))))
    } else {
        r.ended.clone()
    }
}

fn item_part(r: &SessionRow, item: Option<&Item>, live: Option<&Value>) -> Part {
    let label = "Queue item";
    let Some(i) = item else {
        return if r.item.is_empty() {
            Part::new(label, "no queue item")
        } else {
            Part::new(label, format!("{} (could not be read)", r.item)).warn(true)
        };
    };
    let state = serde_json::to_value(i.state).ok();
    let mut said = vec![state.as_ref().and_then(Value::as_str).unwrap_or("-")];
    said.extend(Some(i.priority.as_str()).filter(|p| !p.is_empty()));
    said.extend(i.status.as_deref().filter(|s| *s != "ok"));
    if live.is_some_and(|s| s["item"]["is"] == "moved") {
        said.push("moved on from this session");
    }
    Part::new(label, format!("{} ({})", i.slug, said.join(", "))).link("#queue")
}

/// `<project>:<id>`'s row off the open board. A row that is closed is not on it, which is no
/// failure: a done item closed its row.
fn board_part(runner: &dyn Runner, row: &str, fail: &mut dyn FnMut(&str, String)) -> Part {
    let label = "Board row";
    let (project, id) = row.split_once(':').unwrap_or(("", row));
    let named = format!("{project} {id}");
    let named = named.trim();
    let part = match tasks::feed(runner) {
        Ok(f) => {
            let open = f.rows.iter().find(|r| {
                r.id.as_deref() == Some(id)
                    && r.project
                        .as_deref()
                        .is_some_and(|p| p.eq_ignore_ascii_case(project))
            });
            match open {
                Some(r) => Part::new(
                    label,
                    format!("{named} \"{}\" ({})", cap(&r.text, TITLE_MAX), r.state),
                ),
                None => Part::new(label, format!("{named} (closed, or not on the open board)")),
            }
        }
        Err(e) => {
            fail("notes board", e);
            Part::new(label, format!("{named} (could not be read)")).warn(true)
        }
    };
    if project.is_empty() {
        part
    } else {
        part.link(format!("#projects/{project}"))
    }
}

/// A path with the home directory as `~`.
fn tilde(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && path.starts_with(&h) => format!("~{}", &path[h.len()..]),
        _ => path.to_string(),
    }
}

fn known(v: &Value) -> Option<&str> {
    v.as_str().filter(|s| !s.is_empty() && *s != "-")
}

fn plan_part(live: Option<&Value>, item: Option<&Item>) -> Part {
    let label = "Plan";
    let file = live
        .and_then(|s| known(&s["plan_file"]))
        .or_else(|| item.and_then(|i| i.extra.get("plan")).and_then(known));
    let Some(file) = file else {
        return Part::new(label, "no plan file");
    };
    let mut text = tilde(file);
    if let Some(s) = live {
        if let (Some(d), Some(t)) = (s["phases_done"].as_i64(), s["phases_total"].as_i64()) {
            text += &format!("  phases {d}/{t}");
        }
        if let Some(n) = known(&s["next_phase"]) {
            let name = n.split_once(": ").map_or(n, |(name, _)| name);
            text += &format!(", next: {name}");
        }
    }
    Part::new(label, text)
}

fn worktree_part(live: Option<&Value>, item: Option<&Item>) -> Part {
    let label = "Worktree";
    let Some(s) = live else {
        return match item.and_then(|i| i.session.as_deref()) {
            Some(t) => Part::new(label, format!("not recorded, it ran in tmux {t}")),
            None => Part::new(label, "not recorded"),
        };
    };
    let mut text = tilde(str_of(s, "cwd"));
    if let Some(b) = known(&s["branch"]) {
        text += &format!("  branch {b}");
    }
    let count = |k: &str| s[k].as_i64().filter(|n| *n > 0);
    let mut git = vec![];
    git.extend(count("ahead").map(|n| format!("{n} ahead")));
    git.extend(count("behind").map(|n| format!("{n} behind")));
    git.extend(count("dirty").map(|n| format!("{n} dirty")));
    let conflicts = s["conflicts"].as_bool().unwrap_or(false);
    if conflicts {
        git.push("conflicts".into());
    }
    if !git.is_empty() {
        text += &format!(", {}", git.join(", "));
    }
    Part::new(label, text).warn(conflicts)
}

/// The PR's URL: the repo fleet-sessions read it from, else the queue item's `<repo>#<n>`.
fn pr_url(number: &str, live: Option<&Value>, item: Option<&Item>) -> Option<String> {
    let listed = live
        .and_then(|s| s["prs"].as_array())
        .into_iter()
        .flatten()
        .find(|p| {
            p["number"]
                .as_i64()
                .is_some_and(|n| n.to_string() == number)
        })
        .map(|p| format!("{}#{number}", str_of(p, "repo")));
    let pr = listed.or_else(|| item?.pr.clone())?;
    reds::pr_url(&pr).filter(|u| u.ends_with(&format!("/pull/{number}")))
}

fn pr_part(r: &SessionRow, live: Option<&Value>, item: Option<&Item>) -> Part {
    let label = "PR";
    let Some(n) = &r.pr else {
        return Part::new(
            label,
            if r.pr_state.is_empty() {
                "-"
            } else {
                &r.pr_state
            },
        );
    };
    let mut text = format!("#{n} {}", r.pr_state).trim_end().to_string();
    if !r.ci.is_empty() {
        text += &format!(" (CI {})", r.ci.to_lowercase());
    }
    let prs = live.and_then(|s| s["prs"].as_array());
    if let Some(p) = prs.filter(|p| p.len() > 1) {
        let merged = p.iter().filter(|x| x["state"] == "MERGED").count();
        text += &format!(", {merged} of {} PRs merged", p.len());
    }
    let part = Part::new(label, text).warn(r.ci.eq_ignore_ascii_case("fail"));
    match pr_url(n, live, item) {
        Some(u) => part.link(u),
        None => part,
    }
}

/// `fleet-shepherd budget`'s `<size> <usd>`, which owns the sizes and their numbers.
fn budget(runner: &dyn Runner, task: &str) -> Result<(String, f64), String> {
    let argv = ["fleet-shepherd", "budget", task].map(String::from);
    let out = runner.run(&argv)?;
    let mut f = out.split_whitespace();
    match (f.next(), f.next().and_then(|n| n.parse().ok())) {
        (Some(size), Some(usd)) => Ok((size.to_string(), usd)),
        _ => Err(format!("not <size> <usd>: {}", cap(&out, 40))),
    }
}

fn spend_part(r: &SessionRow, budget: Option<&(String, f64)>) -> Part {
    let from = match r.source {
        Source::Live => "session registry",
        Source::Queue => "queue item",
        Source::Outcome => "outcome row",
    };
    let cap = budget.map(|(size, usd)| match size.as_str() {
        "unsized" => format!("${usd} budget, unsized"),
        size => format!("${usd} budget, size {size}"),
    });
    let text = match (r.cost_usd, cap) {
        (Some(c), Some(cap)) => format!("${c:.2} of the {cap}, from the {from}"),
        (Some(c), None) => format!("${c:.2}, from the {from}"),
        (None, Some(cap)) => format!("none recorded yet, {cap}"),
        (None, None) => "none recorded yet".to_string(),
    };
    let over = matches!((r.cost_usd, budget), (Some(c), Some((_, b))) if c > *b);
    Part::new("Spend", text).warn(over)
}

/// The asks `session` filed, as `boards::asks` reads them.
fn asks(runner: &dyn Runner, session: &str) -> Result<Vec<Value>, String> {
    let argv = ["agent-ask", "list", "--all"].map(String::from);
    let mut all = boards::asks(&runner.run(&argv)?);
    all.retain(|a| a["claude_session"] == session);
    Ok(all)
}

fn asks_part(asks: Option<&[Value]>) -> Part {
    let label = "Asks";
    let Some(all) = asks else {
        return Part::new(label, "could not be read").warn(true);
    };
    let open: Vec<&Value> = all.iter().filter(|a| a["status"] == "pending").collect();
    let closed = all.len() - open.len();
    let was = if closed > 0 {
        format!(", {closed} closed")
    } else {
        String::new()
    };
    match open.first() {
        Some(a) if open.len() == 1 => Part::new(
            label,
            format!(
                "1 open: {} ({}){was}",
                cap(str_of(a, "question"), TITLE_MAX),
                str_of(a, "id")
            ),
        )
        .link("#home")
        .warn(true),
        Some(_) => Part::new(label, format!("{} open{was}", open.len()))
            .link("#home")
            .warn(true),
        None => Part::new(label, format!("none open{was}")),
    }
}

/// The shepherd's file for one session: the fact it last nudged on, when, and what it escalated.
/// The file holds one fact, so a session's earlier nudges are in its outcome card.
#[derive(Clone, Debug, Default, PartialEq)]
struct Ledger {
    fact: String,
    at: String,
    escalated: String,
}

impl Ledger {
    fn read(dir: &Path, session: &str) -> Ledger {
        let mut l = Ledger::default();
        if session.is_empty() {
            return l;
        }
        let text = std::fs::read_to_string(dir.join(session)).unwrap_or_default();
        for line in text.lines() {
            match line.split_once(": ") {
                Some(("fact", v)) => l.fact = v.to_string(),
                Some(("at", v)) => l.at = v.chars().take(16).collect::<String>().replace('T', " "),
                Some(("escalated", v)) => l.escalated = v.to_string(),
                _ => {}
            }
        }
        l
    }
}

fn shepherd_part(l: &Ledger, live: Option<&Value>) -> Part {
    let mut said = vec![];
    said.extend(
        live.and_then(|s| known(&s["fact"]))
            .map(|f| format!("now \"{f}\"")),
    );
    said.push(if l.fact.is_empty() {
        "no nudge".to_string()
    } else {
        format!("last nudge {} on \"{}\"", l.at, l.fact)
    });
    if !l.escalated.is_empty() {
        said.push(format!("escalated \"{}\"", l.escalated));
    }
    Part::new("Shepherd", said.join(", ")).warn(!l.escalated.is_empty() && live.is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;

    /// Answers by the argv's first words; anything else fails, as a missing tool does.
    struct Fake(Vec<(&'static str, Result<String, String>)>);

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            let line = argv.join(" ");
            self.0
                .iter()
                .find(|(k, _)| line.starts_with(k))
                .map_or_else(|| Err(format!("{line}: not found")), |(_, r)| r.clone())
        }
    }

    const SID: &str = "6f296b73-b7a5-4f30-8046-5d583d1f7c61";

    fn tsv(id: &str, status: &str, question: &str, sid: &str) -> String {
        let mut f = vec![""; 20];
        (f[0], f[3], f[5], f[15]) = (id, status, question, sid);
        f.join("\t") + "\n"
    }

    fn tools() -> Fake {
        let board = json!({"rows": [{"profile": "p", "project": "agent-runtime", "lane": "agent",
            "state": "doing", "priority": "", "id": "ar-455", "text": "notice and close",
            "tags": [], "sheet": "s", "line": 1, "raw": "x", "requested": false}]});
        let asks = tsv("Aa", "pending", "ship it?", SID)
            + &tsv("Bb", "answered", "which?", SID)
            + &tsv("Cc", "pending", "someone else's", "other");
        let item = json!({"slug": "the-item", "state": "running", "priority": "high",
            "row": "agent-runtime:ar-455", "task": "do it", "plan": "/p/from-item.md"});
        Fake(vec![
            ("agent-queue show the-item --json", Ok(item.to_string())),
            ("fleet-shepherd budget do it", Ok("m 25\n".into())),
            ("notes board --json", Ok(board.to_string())),
            ("agent-ask list --all", Ok(asks)),
            (
                "agentctl-session-outcomes card",
                Ok("Its title (6f296b73)\n  Time  1h".into()),
            ),
        ])
    }

    fn live_row() -> SessionRow {
        SessionRow {
            key: "lab/dotfiles-agent-6:1".into(),
            bucket: "WORKING".into(),
            task: "the task".into(),
            item: "the-item".into(),
            target: "lab/dotfiles-agent-6:1".into(),
            session_id: SID.into(),
            pr: Some("12".into()),
            pr_state: "open".into(),
            ci: "PASS".into(),
            idle_min: Some(3),
            cost_usd: Some(1.2),
            ..SessionRow::default()
        }
    }

    fn state() -> Value {
        json!({"target": "lab/dotfiles-agent-6:1", "session_id": SID, "cwd": "/w/dotfiles-agent-6",
            "branch": "feat/x", "plan_file": "/p/plan.md", "phases_done": 2, "phases_total": 4,
            "next_phase": "P3 the page: the long text", "fact": "WORKING idle 3m", "ahead": 2, "dirty": 0, "conflicts": false,
            "item": {"slug": "the-item", "is": "own"},
            "prs": [{"repo": "o/r", "number": 12, "state": "OPEN"}, {"repo": "o/r", "number": 9, "state": "MERGED"}]})
    }

    fn text<'a>(p: &'a SessionPage, label: &str) -> &'a str {
        let found = p.parts.iter().find(|x| x.label == label);
        found.map_or("", |x| x.text.as_str())
    }

    /// A ledger directory of its own for each test, which run in parallel.
    fn ledger(test: &str, body: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hub-page-{test}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join(SID), body).unwrap();
        d
    }

    /// No shepherd file for any session.
    fn no_ledger() -> PathBuf {
        std::env::temp_dir().join(format!("hub-page-none-{}", std::process::id()))
    }

    #[test]
    fn a_session_joins_its_item_row_plan_worktree_pr_spend_asks_and_shepherd() {
        let d = ledger(
            "joins",
            "fact: STALLED idle 40m\nat: 2026-11-06T12:49:03-08:00\n",
        );
        let p = read(&tools(), &d, SID, &[live_row()], &[state()]).unwrap();
        let labels: Vec<&str> = p.parts.iter().map(|x| x.label).collect();
        assert_eq!(
            labels,
            [
                "Queue item",
                "Board row",
                "Plan",
                "Worktree",
                "PR",
                "Spend",
                "Asks",
                "Shepherd"
            ]
        );
        assert_eq!(
            (p.name.as_str(), p.idle.as_str()),
            ("lab/dotfiles-agent-6:1", "3m idle")
        );
        assert_eq!(text(&p, "Queue item"), "the-item (running, high)");
        assert_eq!(
            text(&p, "Board row"),
            "agent-runtime ar-455 \"notice and close\" (doing)"
        );
        assert_eq!(
            text(&p, "Plan"),
            "/p/plan.md  phases 2/4, next: P3 the page"
        );
        assert_eq!(
            text(&p, "Worktree"),
            "/w/dotfiles-agent-6  branch feat/x, 2 ahead"
        );
        assert_eq!(text(&p, "PR"), "#12 open (CI pass), 1 of 2 PRs merged");
        assert_eq!(
            text(&p, "Spend"),
            "$1.20 of the $25 budget, size m, from the session registry"
        );
        assert_eq!(text(&p, "Asks"), "1 open: ship it? (Aa), 1 closed");
        assert_eq!(
            text(&p, "Shepherd"),
            "now \"WORKING idle 3m\", last nudge 2026-11-06 12:49 on \"STALLED idle 40m\""
        );
        let pr = p.parts.iter().find(|x| x.label == "PR").unwrap();
        assert_eq!(pr.link.as_deref(), Some("https://github.com/o/r/pull/12"));
        assert_eq!(p.outcome, "", "a live session has no card to show");
        assert!(p.errors.is_empty(), "{:?}", p.errors);
    }

    #[test]
    fn a_session_with_no_item_says_so_and_reads_no_item_tools() {
        let row = SessionRow {
            item: String::new(),
            pr: None,
            pr_state: String::new(),
            ..live_row()
        };
        let s = json!({"target": row.target, "session_id": SID, "cwd": "/w/x"});
        let only_asks = Fake(vec![("agent-ask list --all", Ok(String::new()))]);
        let d = no_ledger();
        let p = read(&only_asks, &d, SID, &[row], &[s]).unwrap();
        assert_eq!(text(&p, "Queue item"), "no queue item");
        assert_eq!(text(&p, "Board row"), "no board row");
        assert_eq!(text(&p, "Plan"), "no plan file");
        assert_eq!(text(&p, "PR"), "-");
        assert_eq!(text(&p, "Spend"), "$1.20, from the session registry");
        assert_eq!(text(&p, "Asks"), "none open");
        assert_eq!(text(&p, "Shepherd"), "no nudge");
        assert!(p.errors.is_empty(), "{:?}", p.errors);
    }

    #[test]
    fn an_ended_session_shows_its_card_and_the_items_plan_and_pr() {
        let row = SessionRow {
            key: "the-item".into(),
            bucket: "DONE".into(),
            target: String::new(),
            pr: Some("12".into()),
            pr_state: "merged".into(),
            ci: String::new(),
            ended: "ended".into(),
            idle_min: None,
            source: Source::Queue,
            ..live_row()
        };
        let mut t = tools();
        let done = json!({"slug": "the-item", "state": "done", "priority": "high", "status": "ok",
            "row": "agent-runtime:ar-999", "plan": "/p/from-item.md", "pr": "o/r#12",
            "session": "lab:dotfiles-agent-6", "task": "do it"});
        t.0[0].1 = Ok(done.to_string());
        let d = no_ledger();
        let p = read(&t, &d, "the-item", &[row], &[]).unwrap();
        assert_eq!(p.name, "the-item");
        assert_eq!(p.idle, "ended");
        assert_eq!(p.outcome, "Its title (6f296b73)\n  Time  1h");
        assert_eq!(text(&p, "Queue item"), "the-item (done, high)");
        assert_eq!(
            text(&p, "Board row"),
            "agent-runtime ar-999 (closed, or not on the open board)"
        );
        assert_eq!(text(&p, "Plan"), "/p/from-item.md");
        assert_eq!(
            text(&p, "Worktree"),
            "not recorded, it ran in tmux lab:dotfiles-agent-6"
        );
        let pr = p.parts.iter().find(|x| x.label == "PR").unwrap();
        assert_eq!(pr.link.as_deref(), Some("https://github.com/o/r/pull/12"));
        assert_eq!(
            text(&p, "Spend"),
            "$1.20 of the $25 budget, size m, from the queue item"
        );
    }

    #[test]
    fn an_ended_session_with_no_card_yet_says_the_nightly_run_writes_it() {
        let row = SessionRow {
            source: Source::Outcome,
            item: String::new(),
            ..live_row()
        };
        let no_card = Fake(vec![("agent-ask list --all", Ok(String::new()))]);
        let d = no_ledger();
        let p = read(&no_card, &d, SID, &[row], &[]).unwrap();
        assert_eq!(p.outcome, NO_CARD);
    }

    #[test]
    fn spend_with_no_cost_yet_still_names_the_budget() {
        let row = SessionRow {
            cost_usd: None,
            ..live_row()
        };
        assert_eq!(
            spend_part(&row, Some(&("unsized".to_string(), 25.0))).text,
            "none recorded yet, $25 budget, unsized"
        );
        assert_eq!(spend_part(&row, None).text, "none recorded yet");
    }

    #[test]
    fn a_session_past_the_tables_window_opens_from_its_card_and_nothing_else_does() {
        let d = no_ledger();
        let p = read(&tools(), &d, SID, &[], &[]).unwrap();
        assert_eq!(p.task, "Its title (6f296b73)");
        assert_eq!(p.idle, "ended");
        assert_eq!(p.session_id, SID);
        for nobody in ["not-a-session", "../../etc/passwd"] {
            assert_eq!(read(&tools(), &d, nobody, &[], &[]), None, "{nobody}");
        }
        let no_card = Fake(vec![]);
        assert_eq!(read(&no_card, &d, SID, &[], &[]), None);
    }

    #[test]
    fn a_source_that_fails_says_so_and_the_rest_still_shows() {
        let t = Fake(vec![("agent-ask list --all", Err("exit 1".into()))]);
        let d = no_ledger();
        let p = read(&t, &d, SID, &[live_row()], &[state()]).unwrap();
        assert_eq!(text(&p, "Queue item"), "the-item (could not be read)");
        assert_eq!(text(&p, "Asks"), "could not be read");
        assert_eq!(
            text(&p, "Worktree"),
            "/w/dotfiles-agent-6  branch feat/x, 2 ahead"
        );
        assert_eq!(p.errors.len(), 2, "{:?}", p.errors);
        assert!(p.errors[0].starts_with("agent-queue: "), "{:?}", p.errors);
        assert!(p.errors[1].starts_with("agent-ask: "), "{:?}", p.errors);
    }

    #[test]
    fn a_row_is_found_by_session_target_or_item_and_only_a_full_match() {
        let rows = [live_row()];
        for id in [SID, "lab/dotfiles-agent-6:1", "the-item"] {
            assert!(find(&rows, id).is_some(), "{id}");
        }
        assert!(find(&rows, "6f296b73").is_none());
        assert!(find(&rows, "dotfiles").is_none());
        let bare = [SessionRow::default()];
        assert!(find(&bare, "").is_none(), "an empty id names nothing");
    }

    #[test]
    fn spend_over_budget_conflicts_and_an_open_ask_are_amber() {
        let d = no_ledger();
        let mut s = state();
        s["conflicts"] = json!(true);
        let row = SessionRow {
            cost_usd: Some(30.0),
            ..live_row()
        };
        let p = read(&tools(), &d, SID, &[row], &[s]).unwrap();
        let warned: Vec<&str> = p.parts.iter().filter(|x| x.warn).map(|x| x.label).collect();
        assert_eq!(warned, ["Worktree", "Spend", "Asks"]);
    }
}
