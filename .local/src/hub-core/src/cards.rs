//! Home's status grid: one card per tab, each the tab's own reader worded as a tile (docs/
//! dashboards.md, Tile pattern). A card counts nothing itself: each `fn` here maps what its tab's
//! reader already counted, so the card and the tab cannot disagree (rule 8), and every number
//! links to the tab that owns it (rule 2). Both surfaces draw `Card` as it is sent.

use serde::Serialize;

use crate::home::Level;
use crate::links::Link;
use crate::reading::NO_DATA;

/// How many "where to look first" rows a card shows; the rest are on its tab.
pub const SHOWN_FIRST: usize = 3;

/// One run of the card's bar: how many of the counted things sit at `level`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Seg {
    pub level: Level,
    pub n: usize,
}

/// A labelled count under the bar (`Offline 43`), coloured by its own level.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Part {
    pub label: String,
    pub value: String,
    pub level: Level,
}

/// A "where to look first" row: what it is, a line under it, and the record it opens.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct First {
    pub text: String,
    pub sub: String,
    pub level: Level,
    pub link: Option<Link>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Card {
    /// The card's id: the `hub_core::layout` tab it opens, or for a Home card (`needs`, `red`)
    /// the Home list it counts. A widget's `?cards=` names cards by it.
    pub tab: &'static str,
    pub title: &'static str,
    /// The one big number or word, and what it counts.
    pub big: String,
    pub unit: String,
    /// The card's worst level: the big number wears it.
    pub level: Level,
    pub bar: Vec<Seg>,
    pub parts: Vec<Part>,
    /// The heading over `first` ("Where to look first", "Bottleneck").
    pub first_head: &'static str,
    pub first: Vec<First>,
    /// What was counted, the card's (i) (rule 6).
    pub counted: String,
    /// Why the reader could not answer; the card then says NO DATA, never green.
    pub error: Option<String>,
    pub link: Link,
}

impl Card {
    fn new(tab: &'static str, title: &'static str, counted: impl Into<String>) -> Card {
        Card {
            tab,
            title,
            big: String::new(),
            unit: String::new(),
            level: Level::Nodata,
            bar: vec![],
            parts: vec![],
            first_head: "Where to look first",
            first: vec![],
            counted: counted.into(),
            error: None,
            link: Link::tab(tab),
        }
    }

    /// The card of a reader that did not answer.
    pub fn failed(
        tab: &'static str,
        title: &'static str,
        counted: &str,
        why: impl Into<String>,
    ) -> Card {
        Card {
            big: NO_DATA.to_uppercase(),
            error: Some(why.into()),
            ..Card::new(tab, title, counted)
        }
    }

    /// The card of a reader that has not answered yet: a dash, never a number or a green bar.
    pub fn reading(tab: &'static str, title: &'static str) -> Card {
        Card {
            big: "-".into(),
            unit: "reading".into(),
            ..Card::new(tab, title, "")
        }
    }

    fn bar(mut self, ok: usize, warn: usize, red: usize) -> Card {
        self.bar = [(Level::Ok, ok), (Level::Warn, warn), (Level::Red, red)]
            .into_iter()
            .filter(|(_, n)| *n > 0)
            .map(|(level, n)| Seg { level, n })
            .collect();
        self.level = worst(red, warn, ok + warn + red);
        self
    }

    fn part(mut self, label: &str, value: impl ToString, level: Level) -> Card {
        self.parts.push(Part {
            label: label.into(),
            value: value.to_string(),
            level,
        });
        self
    }

    fn first(mut self, rows: impl IntoIterator<Item = First>) -> Card {
        self.first = rows.into_iter().take(SHOWN_FIRST).collect();
        self
    }
}

/// Red if any is red, amber if any is amber, green when something was counted, else no data.
fn worst(red: usize, warn: usize, total: usize) -> Level {
    if red > 0 {
        Level::Red
    } else if warn > 0 {
        Level::Warn
    } else if total > 0 {
        Level::Ok
    } else {
        Level::Nodata
    }
}

/// A count's own level: `bad` when above zero, else ok.
fn lvl(n: usize, bad: Level) -> Level {
    if n > 0 {
        bad
    } else {
        Level::Ok
    }
}

fn row(text: impl Into<String>, sub: impl Into<String>, level: Level, link: Option<Link>) -> First {
    First {
        text: text.into(),
        sub: sub.into(),
        level,
        link,
    }
}

/// Sessions: the live sessions by fleet-sessions bucket, need-you first.
pub fn sessions(rows: &[crate::session_table::SessionRow]) -> Card {
    use crate::session_table::Source;
    let live: Vec<_> = rows.iter().filter(|r| r.source == Source::Live).collect();
    let n = |b: &str| live.iter().filter(|r| r.bucket == b).count();
    let (needs, stalled) = (n("NEEDS"), n("STALLED"));
    let done = rows.iter().filter(|r| r.done).count();
    // the ok segment: live rows neither finished nor waiting, counted directly so a finished bucket
    // that is also NEEDS or STALLED cannot be taken off twice
    let ok = live
        .iter()
        .filter(|r| !r.done && r.bucket != "NEEDS" && r.bucket != "STALLED")
        .count();
    let mut c = Card::new(
        "sessions",
        "Sessions",
        "live tmux sessions by fleet-sessions bucket; done counts finished and ended rows today",
    )
    .bar(ok, stalled, needs)
    .part("Working", n("WORKING"), Level::Ok)
    .part("Need you", needs, lvl(needs, Level::Red))
    .part("Stalled", stalled, lvl(stalled, Level::Warn))
    .part("Done today", done, Level::Ok);
    c.big = live.len().to_string();
    c.unit = "live sessions".into();
    let look = ["NEEDS", "STALLED"]
        .into_iter()
        .flat_map(|b| live.iter().filter(move |r| r.bucket == b));
    c.first(look.map(|r| {
        let level = if r.bucket == "NEEDS" {
            Level::Red
        } else {
            Level::Warn
        };
        let idle = r
            .idle_min
            .map(|m| format!(", idle {m}m"))
            .unwrap_or_default();
        let id = if r.target.is_empty() {
            &r.session_id
        } else {
            &r.target
        };
        row(
            if r.task.is_empty() {
                r.key.clone()
            } else {
                r.task.clone()
            },
            format!("{} - {}{idle}", r.project, r.bucket.to_lowercase()),
            level,
            Some(Link::to(crate::links::Kind::Session, id.clone())),
        )
    }))
}

/// Queue: agent-queue's items by state, and the flow strip's bottleneck from fleet-bench's
/// pipeline snapshot when it has been read.
pub fn queue(
    q: &crate::queue::Queue,
    pipeline: Option<&Result<Option<crate::pipeline::Pipeline>, String>>,
) -> Card {
    use crate::queue::State;
    let (waiting, running, review, queued) = (
        q.count(State::Waiting),
        q.count(State::Running),
        q.count(State::Review),
        q.count(State::Queued),
    );
    let mut c = Card::new(
        "queue",
        "Queue",
        "agent-queue items by state (agent-queue list)",
    )
    .bar(running + review + queued, 0, waiting)
    .part("Running", running, Level::Ok)
    .part("On a PR", review, Level::Ok);
    // The queue is the waiting: every queued item can start, and gated work is a board row.
    c.big = queued.to_string();
    c.unit = format!("on deck, {running} running");
    c.first_head = "Bottleneck";
    let read = pipeline.map(Result::as_ref);
    let bottleneck = match read {
        Some(Ok(Some(p))) => p.bottleneck.as_ref().map(|b| (b, p.bottleneck_age())),
        _ => None,
    };
    if let Some((b, age)) = bottleneck {
        let step = crate::flow::step_label(&b.step);
        c = c.first([row(step, age.unwrap_or_default(), Level::Warn, None)]);
    } else {
        c.first_head = "Waiting on you";
        c = c.first(q.in_state(State::Waiting).map(|i| {
            row(
                i.title(),
                i.project.clone(),
                Level::Red,
                Some(Link::to(crate::links::Kind::Queue, i.slug.clone())),
            )
        }));
    }
    // A pipeline that could not be read is said, so it never reads as no bottleneck.
    let pipe_err = match read {
        Some(Err(e)) => Some(format!("pipeline: {e}")),
        _ => None,
    };
    let errors: Vec<_> = q.errors.iter().cloned().chain(pipe_err).collect();
    if !errors.is_empty() {
        c.error = Some(errors.join("; "));
    }
    c
}

/// Alerts: what fires now that needs the human (no owner, a fix that did not hold, a fix that
/// waits or is past its due), by the hue the Alerts tab gives each row; a red with its fix in
/// hand on time counts as being fixed, in the bar's green and as its own part, never as red.
pub fn alerts(a: &crate::alerts::Alerts) -> Card {
    let by = |l: Level| {
        a.firing
            .iter()
            .filter(|x| x.needs_you() && x.hue() == l)
            .count()
    };
    let k = &a.counts;
    let (red, warn) = (by(Level::Red), by(Level::Warn));
    let need = if red > 0 {
        Level::Red
    } else {
        lvl(warn, Level::Warn)
    };
    let mut c = Card::new(
        "alerts",
        "Alerts",
        "tripped watches, cc:red_now, the machinery and Alertmanager; a red whose fix item is in hand and not past its due is being fixed",
    )
    .bar(k.being_fixed, warn, red)
    .part("Need you", k.need_you, need)
    .part("Being fixed", k.being_fixed, Level::Ok)
    .part("No owner", k.no_owner, lvl(k.no_owner, Level::Warn))
    .part("Fixes open", k.fixes_open, Level::Ok);
    // Nothing needing the human is green when every source answered; the tab's own level says
    // which, and a tab that is red only for rows being fixed is green here.
    c.level = if need == Level::Ok && a.level == Level::Nodata {
        Level::Nodata
    } else {
        need
    };
    c.big = k.need_you.to_string();
    c.unit = format!(
        "need you, {} being fixed, {} firing",
        k.being_fixed, k.firing
    );
    if a.firing.is_empty() && a.level == Level::Ok {
        c.bar = vec![Seg {
            level: Level::Ok,
            n: k.watches.max(1),
        }];
    }
    if !a.errors.is_empty() {
        c.error = Some(a.errors.join("; "));
    }
    // The rows that need the human lead, in the tab's order; a row being fixed says by whom.
    let mut rows: Vec<_> = a.firing.iter().collect();
    rows.sort_by_key(|x| !x.fixing_by.is_empty());
    c.first(rows.into_iter().map(|x| {
        let (sub, hue) = match x.fixing_by.as_str() {
            "" => (format!("{} - {}", x.owner, x.state), x.hue()),
            by => (format!("being fixed by {by}"), Level::Ok),
        };
        row(x.what.clone(), sub, hue, None)
    }))
}

/// Infra: the machines Prometheus reads, the CI pool and what is stuck.
pub fn infra(i: &crate::infra::Infra) -> Card {
    const COUNTED: &str = "machines with a reading, CI runners and slots from Prometheus";
    if !i.ok {
        return Card::failed(
            "infra",
            "Infra",
            COUNTED,
            i.error
                .clone()
                .unwrap_or("Prometheus did not answer".into()),
        );
    }
    let up = i.machines.iter().filter(|m| m.state == "up").count();
    let unread = i.machines.iter().filter(|m| m.state == NO_DATA).count();
    let down = i.runners_down().len();
    let stuck = i.ci.red.len();
    let mut c = Card::new("infra", "Infra", COUNTED)
        .bar(up, i.machines.len() - up - unread, unread)
        .part("Runners down", down, lvl(down, Level::Red))
        .part(
            "CI busy",
            format!("{}/{}", i.ci.busy, i.ci.slots),
            Level::Ok,
        )
        .part("CI queued", i.ci.queued, Level::Ok)
        .part("Stuck", stuck, lvl(stuck, Level::Red));
    if down + stuck > 0 {
        c.level = Level::Red;
    }
    c.big = format!("{up} of {}", i.machines.len());
    c.unit = "machines up".into();
    let machines = i.machines.iter().filter(|m| m.state != "up").map(|m| {
        let level = if m.state == NO_DATA {
            Level::Red
        } else {
            Level::Warn
        };
        row(
            m.host.clone(),
            m.state.clone(),
            level,
            Some(Link::to(crate::links::Kind::Machine, m.host.clone())),
        )
    });
    let runners = i.runners_down().into_iter().map(|s| {
        row(
            format!("{} down", s.label("runner")),
            "CI runner",
            Level::Red,
            None,
        )
    });
    let red =
        i.ci.red
            .iter()
            .map(|r| row(r.clone(), "CI", Level::Red, None));
    c.first(red.chain(runners).chain(machines).collect::<Vec<_>>())
}

/// Costs: the fleet's 24h figure, this month's bill and the burn pace.
pub fn costs(k: &crate::costs::Costs) -> Card {
    let burn = match k.burn.level {
        "bad" => Level::Red,
        "warn" => Level::Warn,
        "ok" => Level::Ok,
        _ => Level::Nodata,
    };
    let fc = &k.fleet_cost;
    let mut c = Card::new(
        "costs",
        "Costs",
        "agent-usage fleet-cost (24h), this month's bills, claude-acct burn pace",
    );
    c.level = match burn {
        Level::Ok | Level::Nodata if !k.budget.needs.is_empty() => Level::Warn,
        l => l,
    };
    c.big = if fc.why.is_some() {
        "-".into()
    } else {
        fc.usd.clone()
    };
    c.unit = "fleet cost in 24h".into();
    c.bar = vec![Seg {
        level: c.level,
        n: 1,
    }];
    c = c
        .part("Month", &k.budget.spent, Level::Ok)
        .part(
            "Projected",
            &k.budget.projected,
            lvl(k.budget.needs.len(), Level::Warn),
        )
        .part("Measured", &fc.measured, Level::Ok);
    c.first_head = "Burn";
    let needs = k
        .budget
        .needs
        .iter()
        .map(|n| row(n.clone(), "budget", Level::Warn, None));
    let head = (!k.burn.head.is_empty())
        .then(|| row(k.burn.head.clone(), k.burn.stale.unwrap_or(""), burn, None));
    let errors: Vec<_> = k.errors.iter().cloned().chain(fc.why.clone()).collect();
    if !errors.is_empty() {
        c.error = Some(errors.join("; "));
    }
    // A cost that could not be read is no data, and a partial read is never green.
    if fc.why.is_some() {
        c.level = Level::Nodata;
    } else if !k.errors.is_empty() && c.level == Level::Ok {
        c.level = Level::Warn;
    }
    c.bar = vec![Seg {
        level: c.level,
        n: 1,
    }];
    c.first(
        // The top session comes last, so it never pushes a budget need off the card.
        head.into_iter()
            .chain(needs)
            .chain(top_session(k))
            .collect::<Vec<_>>(),
    )
}

/// The session that spent the most in the last 24h, from the live fleet-cost session rows: burn
/// per session, on a card with room for one line.
fn top_session(k: &crate::costs::Costs) -> Option<First> {
    let s = k
        .live
        .as_ref()?
        .sessions
        .iter()
        .filter(|s| s.usd > 0.0)
        .max_by(|a, b| a.usd.total_cmp(&b.usd))?;
    let name = [&s.title, &s.item, &s.project]
        .into_iter()
        .flatten()
        .find(|t| !t.is_empty())
        .map_or(s.sid.as_str(), |t| t.as_str());
    Some(row(
        format!("${:.2} {}", s.usd, crate::text::cap(name, 40)),
        "top session of the last 24h",
        Level::Ok,
        Some(Link::to(crate::links::Kind::Session, s.sid.clone())),
    ))
}

/// Releases: each app's worst channel, as release-state judged it.
pub fn releases(r: &crate::releases::Releases) -> Card {
    use crate::releases::Level as R;
    let n = |l: R| r.apps.iter().filter(|a| a.level == l).count();
    let unread: usize = r.apps.iter().map(|a| a.unread).sum();
    let mut c = Card::new(
        "releases",
        "Releases",
        "release-state show: each app's channels",
    )
    .bar(n(R::Ok), n(R::Warn), n(R::Bad))
    .part("Drift", n(R::Bad), lvl(n(R::Bad), Level::Red))
    .part("To check", n(R::Warn), lvl(n(R::Warn), Level::Warn))
    .part("Unread", unread, lvl(unread, Level::Warn));
    c.big = r.apps.len().to_string();
    c.unit = "apps tracked".into();
    c.counted = format!("release-state show: {}", r.summary);
    if !r.errors.is_empty() {
        c.error = Some(r.errors.join("; "));
    }
    let hue = |l: R| match l {
        R::Bad => Level::Red,
        R::Warn => Level::Warn,
        R::Ok => Level::Ok,
    };
    c.first(r.apps.iter().filter(|a| a.level != R::Ok).map(|a| {
        row(
            a.project.clone(),
            a.status_text.clone(),
            hue(a.level),
            Some(Link::to(crate::links::Kind::App, a.project.clone())),
        )
    }))
}

/// Schedules: everything that runs on its own, by its job state, amber with no purpose.
pub fn schedules(s: &crate::schedules::Schedules) -> Card {
    use crate::reading::JobState;
    let n = |st: JobState| s.rows.iter().filter(|r| r.state == st).count();
    let (failing, stale, never) = (n(JobState::Failing), n(JobState::Stale), n(JobState::Never));
    // One "no purpose" count everywhere (the chip, the summary): every row with none. The bar
    // splits the rows once, so there only an ok row with none adds to the amber part.
    let why = s.rows.iter().filter(|r| r.purpose.is_empty()).count();
    let quiet_gaps = s
        .rows
        .iter()
        .filter(|r| r.state == JobState::Ok && r.purpose.is_empty())
        .count();
    let look = stale + never + quiet_gaps;
    let mut c = Card::new("schedules", "Schedules", "")
        .bar(s.rows.len() - failing - look, look, failing)
        .part("Failing", failing, lvl(failing, Level::Red))
        .part("Stale", stale, lvl(stale, Level::Warn))
        .part("Never ran", never, lvl(never, Level::Warn))
        .part("No purpose", why, lvl(why, Level::Warn));
    c.big = s.rows.len().to_string();
    c.unit = "scheduled things".into();
    c.counted = s.summary.clone();
    if !s.errors.is_empty() {
        c.error = Some(s.errors.join("; "));
    }
    // The rows come ranked failing, stale, never, then no purpose (schedules::rank).
    c.first(s.rows.iter().filter_map(|r| {
        let (sub, level) = match r.state {
            JobState::Failing if r.streak < 0 => (
                format!("{} - failed {} in a row", r.kind, -r.streak),
                Level::Red,
            ),
            JobState::Failing => (format!("{} - {}", r.kind, r.status), Level::Red),
            JobState::Stale | JobState::Never => {
                (format!("{} - {}", r.kind, r.status), Level::Warn)
            }
            JobState::Ok if r.purpose.is_empty() => {
                (format!("{} - no purpose", r.kind), Level::Warn)
            }
            _ => return None,
        };
        Some(row(r.name.clone(), sub, level, None))
    }))
}

/// Projects: the lab projects, amber where one waits on the human.
pub fn projects(p: &crate::projects::Projects) -> Card {
    let cards = &p.cards;
    let waiting = cards.iter().filter(|c| c.waiting > 0).count();
    let sum = |f: fn(&crate::projects::Card) -> usize| cards.iter().map(f).sum::<usize>();
    let mut c = Card::new(
        "projects",
        "Projects",
        "lab projects with their board slice and queue (notes projects --stats)",
    )
    .bar(cards.len() - waiting, waiting, 0)
    .part(
        "In flight",
        cards.iter().filter(|c| c.in_flight()).count(),
        Level::Ok,
    )
    .part("Waiting", sum(|c| c.waiting), lvl(waiting, Level::Warn))
    .part("Hot", sum(|c| c.hot), Level::Ok)
    .part("Done today", sum(|c| c.done_today), Level::Ok);
    c.big = cards.len().to_string();
    c.unit = "lab projects".into();
    if !p.errors.is_empty() {
        c.error = Some(p.errors.join("; "));
    }
    let mut look: Vec<_> = cards
        .iter()
        .filter(|c| c.waiting > 0 || c.hot > 0)
        .collect();
    look.sort_by_key(|a| std::cmp::Reverse((a.waiting, a.hot)));
    c.first(look.into_iter().map(|p| {
        let level = if p.waiting > 0 {
            Level::Warn
        } else {
            Level::Ok
        };
        row(
            p.name.clone(),
            format!("{} waiting on you, {} hot", p.waiting, p.hot),
            level,
            Some(Link::to(crate::links::Kind::Project, p.name.clone())),
        )
    }))
}

/// Board: every open row on the boards (an agent row past its project's budget is Backlog's
/// part, never listed), the feed's `totals` (`tasks::Totals`, the waybar hover's `all lanes`
/// count too), the rows Projects' Board lists. Late rows (past their `#due`) and rows the human
/// asked for that nothing has started come first.
pub fn board(f: &crate::tasks::Feed) -> Card {
    use crate::tasks::Row;
    let today = f.today.as_str();
    let open = f.open_rows(None);
    let doing = |r: &Row| r.state == "doing";
    // Where a row ranks among the places to look: late (started or not, it is still late), then
    // asked for and not started, then Now and Next not started; None is not a place to look.
    let look_at = |r: &Row| {
        if r.due.as_deref().is_some_and(|d| d < today) {
            Some(Level::Red)
        } else if doing(r) || r.backlog {
            None
        } else if r.requested {
            Some(Level::Warn)
        } else if matches!(r.section.as_deref(), Some("now" | "next")) {
            Some(Level::Ok)
        } else {
            None
        }
    };
    let looked: Vec<_> = open.iter().map(|r| (*r, look_at(r))).collect();
    let at = |l: Level| looked.iter().filter(|(_, x)| *x == Some(l)).count();
    let Some(t) = f.totals else {
        return Card::failed(
            "board",
            "Board",
            "",
            "notes board --json has no totals: rebuild notes",
        );
    };
    let (n_open, n_doing, n_backlog) = (t.open, t.doing, t.backlog);
    let (n_late, n_asked) = (at(Level::Red), at(Level::Warn));
    let done = f
        .done
        .iter()
        .filter(|r| r.closed.as_deref() == Some(today))
        .count();
    let mut c = Card::new(
        "board",
        "Board",
        "open rows on every sheet, human, agent and playtest (notes board); requested is asked \
         for and not started, late is past its due day; backlog is the agent rows past their \
         project's board budget (tier:backlog), counted in none of the others; sprint is the \
         release windows' rows still open of the rows they hold, left out when none is recorded",
    )
    .bar(n_open.saturating_sub(n_late + n_asked), n_asked, n_late)
    .part("Doing", n_doing, Level::Ok)
    .part("Requested", n_asked, lvl(n_asked, Level::Warn))
    .part("Late", n_late, lvl(n_late, Level::Red))
    .part("Done today", done, Level::Ok)
    .part("Backlog", n_backlog, Level::Ok);
    // The tiers line's Sprint (tasks::Tiers::words), on the same rule; last, so a narrow TUI
    // card clips it before the counts it always had.
    if t.sprint.committed > 0 {
        let s = format!("{}/{}", t.sprint.open, t.sprint.committed);
        c = c.part("Sprint", s, Level::Ok);
    }
    // The windows by project, one line each in the CLI's words, in the card's (i): the Sprint
    // part above is their sum.
    let windows = f.sprint_lines(None);
    if !windows.is_empty() {
        c.counted += &format!("\nSprint by project:\n{}", windows.join("\n"));
    }
    c.big = n_open.to_string();
    c.unit = format!("open rows, {n_doing} doing, {n_backlog} on the backlog");
    // No `f.errors` here: they are the stats and queue joins `sheet_view` adds, which the hub's
    // feed carries and the web's does not, and no count on this card uses them.
    // Up next fills the list only when nothing is late or asked for, under its own head.
    let urgent = n_late + n_asked > 0;
    if !urgent {
        c.first_head = "Up next";
    }
    let mut look: Vec<_> = looked
        .into_iter()
        .filter_map(|(r, l)| l.map(|l| (r, l)))
        .filter(|(_, l)| !urgent || *l != Level::Ok)
        .collect();
    // Stable, so each level keeps the sheet's order.
    look.sort_by_key(|(_, l)| match l {
        Level::Red => 0,
        Level::Warn => 1,
        _ => 2,
    });
    c.first(look.into_iter().map(|(r, level)| {
        let place = r.project.as_deref().unwrap_or(&r.profile);
        let section = crate::tasks::section_title(r.section.as_deref()).to_lowercase();
        let due = r
            .due
            .as_deref()
            .map(|d| format!(", due {}", crate::text::short_day(d)))
            .unwrap_or_default();
        let link = match (&r.id, &r.project) {
            (Some(id), _) => Some(Link::to(crate::links::Kind::Row, id.clone())),
            (None, Some(p)) => Some(Link::to(crate::links::Kind::Project, p.clone())),
            _ => None,
        };
        row(
            r.title.clone(),
            format!("{place} - {section}{due}"),
            level,
            link,
        )
    }))
}

/// One tab's read as the grid gets it: None while it has not answered, else its answer.
pub type Got<'a, T> = Option<Result<&'a T, &'a str>>;

/// Every read the grid maps, as each surface holds it.
#[derive(Default)]
pub struct Reads<'a> {
    pub sessions: Got<'a, [crate::session_table::SessionRow]>,
    pub board: Got<'a, crate::tasks::Feed>,
    pub queue: Got<'a, crate::queue::Queue>,
    pub pipeline: Option<&'a Result<Option<crate::pipeline::Pipeline>, String>>,
    pub alerts: Got<'a, crate::alerts::Alerts>,
    pub infra: Got<'a, crate::infra::Infra>,
    pub costs: Got<'a, crate::costs::Costs>,
    pub releases: Got<'a, crate::releases::Releases>,
    pub schedules: Got<'a, crate::schedules::Schedules>,
    pub projects: Got<'a, crate::projects::Projects>,
}

/// Needs you: what waits on the human (asks, sessions, queue items), oldest first.
pub fn needs(home: &crate::home::Home, now: i64) -> Card {
    use crate::home::Kind;
    let waiting = crate::phone::waiting(home);
    let of = |k: Kind| waiting.iter().filter(|n| n.kind == k).count();
    let mut c = Card::new(
        "needs",
        "Needs you",
        "Home's Needs you: open asks, sessions waiting on you, queue items held for you",
    );
    c.link = Link::tab("home");
    c.big = waiting.len().to_string();
    c.unit = "waiting on you".into();
    c = c
        .bar(0, waiting.len(), 0)
        .part("Asks", of(Kind::Ask), lvl(of(Kind::Ask), Level::Warn))
        .part(
            "Sessions",
            of(Kind::Session),
            lvl(of(Kind::Session), Level::Warn),
        )
        .part("Queue", of(Kind::Queue), lvl(of(Kind::Queue), Level::Warn));
    // Nothing waiting is a green zero, never no data: Home answered.
    c.level = lvl(waiting.len(), Level::Warn);
    if !home.errors.is_empty() {
        c.error = Some(home.errors.join("; "));
        if c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    c.first_head = "Oldest";
    let mut old = waiting.clone();
    old.sort_by_key(|n| n.since.unwrap_or(i64::MAX));
    c.first(old.into_iter().map(|n| {
        let waited = n
            .since
            .map(|t| crate::text::age(now - t))
            .unwrap_or_default();
        let sub = [waited.as_str(), n.project.trim_start_matches('.')]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" ");
        row(crate::text::cap(&n.text, 60), sub, Level::Warn, None)
    }))
}

/// Main red: the repos whose nightly on main is red.
pub fn main_red(home: &crate::home::Home) -> Card {
    let red = crate::phone::red_repos(home);
    let mut c = Card::new(
        "red",
        "Main red",
        "Home's needs: repos whose nightly on main is red",
    );
    c.link = Link::tab("home");
    c.big = red.len().to_string();
    c.unit = if red.len() == 1 {
        "repo red on main"
    } else {
        "repos red on main"
    }
    .into();
    c = c.bar(0, 0, red.len());
    c.level = lvl(red.len(), Level::Red);
    // Home's nightly reds come from reads that can fail: a zero then is unknown, never green.
    if !home.errors.is_empty() {
        c.error = Some(home.errors.join("; "));
        if c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    c.first_head = "Red";
    c.first(red.iter().map(|r| row(*r, "nightly", Level::Red, None)))
}

/// The widget's cards when its URL names none: what needs the human, then fleet health.
pub const WIDGET: &[&str] = &["needs", "red", "alerts", "sessions", "costs", "infra"];

/// The cards `names` lists, in its order; a name no card has is skipped.
pub fn pick(cards: Vec<Card>, names: &[&str]) -> Vec<Card> {
    let mut cards: Vec<Option<Card>> = cards.into_iter().map(Some).collect();
    names
        .iter()
        .filter_map(|n| {
            cards
                .iter_mut()
                .find(|c| c.as_ref().is_some_and(|c| c.tab == *n))
                .and_then(Option::take)
        })
        .collect()
}

/// The grid, in the order both surfaces draw it: a card per tab, `reading` until its read
/// answers and `failed` when it could not.
pub fn grid(r: &Reads) -> Vec<Card> {
    fn one<T: ?Sized>(
        g: Got<'_, T>,
        tab: &'static str,
        title: &'static str,
        f: impl FnOnce(&T) -> Card,
    ) -> Card {
        match g {
            None => Card::reading(tab, title),
            Some(Err(e)) => Card::failed(tab, title, "", e),
            Some(Ok(v)) => f(v),
        }
    }
    vec![
        one(r.sessions, "sessions", "Sessions", sessions),
        one(r.queue, "queue", "Queue", |q| queue(q, r.pipeline)),
        one(r.board, "board", "Board", board),
        one(r.alerts, "alerts", "Alerts", alerts),
        one(r.infra, "infra", "Infra", infra),
        one(r.costs, "costs", "Costs", costs),
        one(r.releases, "releases", "Releases", releases),
        one(r.schedules, "schedules", "Schedules", schedules),
        one(r.projects, "projects", "Projects", projects),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_table::{SessionRow, Source};

    fn live(bucket: &str, task: &str) -> SessionRow {
        SessionRow {
            bucket: bucket.into(),
            task: task.into(),
            project: "p".into(),
            target: format!("hub/{task}:1"),
            source: Source::Live,
            ..Default::default()
        }
    }

    #[test]
    fn sessions_count_live_buckets_and_look_first_at_need_you_then_stalled() {
        let rows = vec![
            live("WORKING", "a"),
            live("STALLED", "b"),
            live("NEEDS", "c"),
            // An ended row is not live, so it counts only as done.
            SessionRow {
                bucket: "DONE".into(),
                source: Source::Outcome,
                done: true,
                ..Default::default()
            },
        ];
        let c = sessions(&rows);
        assert_eq!(c.big, "3");
        assert_eq!(c.level, Level::Red);
        assert_eq!(
            c.bar,
            vec![
                Seg {
                    level: Level::Ok,
                    n: 1
                },
                Seg {
                    level: Level::Warn,
                    n: 1
                },
                Seg {
                    level: Level::Red,
                    n: 1
                }
            ]
        );
        assert_eq!(
            c.first.iter().map(|f| f.text.as_str()).collect::<Vec<_>>(),
            ["c", "b"]
        );
        assert_eq!(
            c.first[0].link.as_ref().unwrap().href(),
            "#sessions/sessions/hub%2Fc%3A1"
        );
        assert_eq!(
            c.parts
                .iter()
                .find(|p| p.label == "Done today")
                .unwrap()
                .value,
            "1"
        );
        assert_eq!(c.link.href(), "#sessions");
    }

    #[test]
    fn a_live_landed_session_counts_as_done_not_working() {
        let vocab = crate::vocab::Vocab::from_state(&serde_json::json!({"vocab": {
            "buckets": ["NEEDS", "LANDED", "WORKING"], "finished": ["DONE", "LANDED"]}}));
        let state = [
            serde_json::json!({"target": "hub/a:1", "bucket": "WORKING", "session_id": "a"}),
            serde_json::json!({"target": "hub/b:1", "bucket": "LANDED", "session_id": "b"}),
        ];
        let rows = crate::session_table::rows(&state, &vocab, &Default::default(), &[]);
        let c = sessions(&rows);
        let part = |l| c.parts.iter().find(|p| p.label == l).unwrap().value.clone();
        assert_eq!((c.big.as_str(), part("Done today")), ("2", "1".to_string()));
        assert_eq!(
            c.bar[0],
            Seg {
                level: Level::Ok,
                n: 1
            }
        );
    }

    #[test]
    fn the_grid_is_a_card_per_tab_reading_until_answered_and_no_data_on_error() {
        let q = crate::queue::Queue::default();
        let g = grid(&Reads {
            queue: Some(Ok(&q)),
            costs: Some(Err("prometheus: timeout")),
            ..Default::default()
        });
        assert_eq!(
            g.iter().map(|c| c.tab).collect::<Vec<_>>(),
            [
                "sessions",
                "queue",
                "board",
                "alerts",
                "infra",
                "costs",
                "releases",
                "schedules",
                "projects"
            ]
        );
        assert_eq!((g[0].big.as_str(), g[0].unit.as_str()), ("-", "reading"));
        assert_eq!(g[0].level, Level::Nodata);
        assert_eq!(
            (g[5].big.as_str(), g[5].error.as_deref()),
            ("NO DATA", Some("prometheus: timeout"))
        );
        assert!(g.iter().all(|c| c.link.href() == format!("#{}", c.tab)));
    }

    #[test]
    fn board_counts_open_rows_and_puts_late_then_requested_then_up_next_first() {
        use crate::tasks::{Feed, Row};
        let r = |id: &str, section: &str, rank: u64| Row {
            profile: "personal".into(),
            project: Some("db".into()),
            lane: "agent".into(),
            state: "open".into(),
            id: Some(id.into()),
            title: format!("row {id}"),
            section: Some(section.into()),
            rank,
            ..Default::default()
        };
        // The big number and doing are the feed's `totals` (notes' one count), never a recount
        // of the rows the card ranks.
        let mut f = Feed {
            today: "2026-11-18".into(),
            totals: Some(crate::tasks::Totals {
                open: 5,
                doing: 1,
                agent: 5,
                backlog: 2,
                ..Default::default()
            }),
            rows: vec![
                r("db-1", "now", 1),
                r("db-2", "next", 2),
                r("db-3", "backlog", 3),
                r("db-4", "backlog", 4),
                r("db-5", "next", 5),
            ],
            done: vec![Row {
                state: "done".into(),
                closed: Some("2026-11-18".into()),
                ..r("db-9", "done", 9)
            }],
            ..Default::default()
        };
        f.rows[0].state = "doing".into();
        f.rows[2].requested = true;
        f.rows[3].due = Some("2026-11-17".into());
        let c = board(&f);
        assert_eq!(
            (c.big.as_str(), c.unit.as_str()),
            ("5", "open rows, 1 doing, 2 on the backlog")
        );
        // Negative control: a feed with no totals (an older notes) is a failed card, never a 0.
        let none = board(&Feed {
            totals: None,
            ..f.clone()
        });
        assert_eq!(none.big, NO_DATA.to_uppercase());
        assert!(none
            .error
            .as_deref()
            .is_some_and(|e| e.contains("no totals")));
        assert_eq!(c.level, Level::Red);
        let parts: Vec<_> = c
            .parts
            .iter()
            .map(|p| (p.label.as_str(), p.value.as_str()))
            .collect();
        assert_eq!(
            parts,
            [
                ("Doing", "1"),
                ("Requested", "1"),
                ("Late", "1"),
                ("Done today", "1"),
                ("Backlog", "2")
            ]
        );
        // A recorded release window adds the tiers line's Sprint after the other parts, 0 open
        // included; none recorded (above, and committed 0 with rows open) adds no part.
        let with_sprint = |open, committed| {
            let mut w = f.clone();
            w.totals.as_mut().unwrap().sprint = crate::tasks::Sprint { open, committed };
            board(&w)
                .parts
                .into_iter()
                .map(|p| (p.label, p.value))
                .collect::<Vec<_>>()
        };
        let counts = parts.iter().map(|(l, v)| (l.to_string(), v.to_string()));
        let and = |s: &str| {
            let mut v: Vec<_> = counts.clone().collect();
            v.push(("Sprint".into(), s.into()));
            v
        };
        assert_eq!(with_sprint(3, 4), and("3/4"));
        assert_eq!(with_sprint(0, 4), and("0/4"));
        assert_eq!(with_sprint(2, 0), counts.clone().collect::<Vec<_>>());
        // The windows by project ride in the card's (i), one line each, none with none recorded.
        assert!(!c.counted.contains("Sprint by project"), "{}", c.counted);
        let mut w = f.clone();
        w.sprints = vec![crate::tasks::SprintLine {
            line: "db v0.3.0 1/2 cut Thu 14:00 build held".into(),
            ..Default::default()
        }];
        assert!(
            board(&w)
                .counted
                .ends_with("Sprint by project:\ndb v0.3.0 1/2 cut Thu 14:00 build held"),
            "{}",
            board(&w).counted
        );
        // Late, then requested; Up next rows wait until neither is left, and doing is never listed.
        let first: Vec<_> = c.first.iter().map(|f| (f.text.as_str(), f.level)).collect();
        assert_eq!(first, [("row db-4", Level::Red), ("row db-3", Level::Warn)]);
        assert_eq!(c.first_head, "Where to look first");
        // A late row already started is still late.
        f.rows[3].state = "doing".into();
        assert_eq!(board(&f).first[0].text, "row db-4");
        f.rows[3].state = "open".into();
        assert_eq!(c.first[0].sub, "db - backlog, due 11-17");
        assert_eq!(
            c.first[0].link.as_ref().unwrap().href(),
            "#projects/all?q=id:=db-4"
        );
        // Nothing late or asked for: the card says what is up next.
        f.rows[2].requested = false;
        f.rows[3].due = None;
        let c = board(&f);
        assert_eq!((c.first_head, c.level), ("Up next", Level::Ok));
        assert_eq!(c.first[0].text, "row db-2");
        // A row on the backlog tier is not a place to look: Up next is the next board row.
        f.rows[1].backlog = true;
        assert_eq!(board(&f).first[0].text, "row db-5");
    }

    #[test]
    fn queue_names_the_bottleneck_step_and_else_what_waits_on_you() {
        use crate::flow::tests::{pipe, queue as q};
        let c = queue(&q(), Some(&Ok(Some(pipe(2.25)))));
        // The big number is the queue itself: both queued items, the one with an old hold line too.
        assert_eq!(
            (c.big.as_str(), c.unit.as_str()),
            ("2", "on deck, 1 running")
        );
        let parts: Vec<_> = c
            .parts
            .iter()
            .map(|p| (p.label.as_str(), p.value.as_str()))
            .collect();
        assert_eq!(
            parts,
            [("Running", "1"), ("On a PR", "1")],
            "no Ready or Held: the queue is what waits"
        );
        let bar: Vec<_> = c.bar.iter().map(|s| (s.level, s.n)).collect();
        assert_eq!(
            bar,
            [(Level::Ok, 4), (Level::Red, 1)],
            "no amber held segment"
        );
        assert_eq!(c.first_head, "Bottleneck");
        assert_eq!(
            (c.first[0].text.as_str(), c.first[0].sub.as_str()),
            ("needs you", "age p90 9h (bound 4h)")
        );
        // A snapshot that could not be read is said on the card, beside what waits on you.
        let c = queue(&q(), Some(&Err("state.json: bad json".into())));
        assert_eq!(c.first_head, "Waiting on you");
        assert_eq!(c.error.as_deref(), Some("pipeline: state.json: bad json"));
        // No snapshot read: the item that waits on the human is where to look.
        let c = queue(&q(), None);
        assert_eq!(c.error, None);
        assert_eq!(c.first_head, "Waiting on you");
        assert_eq!(c.first[0].link.as_ref().unwrap().href(), "#queue/d");
        assert_eq!(
            c.level,
            Level::Red,
            "an item waiting on you is red on the bar"
        );
    }

    #[test]
    fn a_card_with_nothing_counted_is_no_data_never_green() {
        // Negative control: an empty read must not paint a green card.
        assert_eq!(sessions(&[]).level, Level::Nodata);
        assert_eq!(releases(&Default::default()).level, Level::Nodata);
        assert_eq!(schedules(&Default::default()).level, Level::Nodata);
    }

    #[test]
    fn infra_that_did_not_answer_is_no_data_with_why() {
        let i = crate::infra::Infra {
            ok: false,
            error: Some("timeout".into()),
            ..Default::default()
        };
        let c = infra(&i);
        assert_eq!(
            (c.big.as_str(), c.level, c.error.as_deref()),
            ("NO DATA", Level::Nodata, Some("timeout"))
        );
    }

    #[test]
    fn alerts_wear_the_tab_level_and_a_read_error_shows() {
        let mut a = crate::alerts::Alerts {
            level: Level::Nodata,
            errors: vec!["reds: no answer".into()],
            ..Default::default()
        };
        let c = alerts(&a);
        assert_eq!(c.level, Level::Nodata);
        assert!(
            c.bar.is_empty(),
            "nothing firing but a source unread is no green bar"
        );
        assert_eq!(c.error.as_deref(), Some("reds: no answer"));
        a.level = Level::Ok;
        a.errors.clear();
        a.counts.watches = 9;
        assert_eq!(
            alerts(&a).bar,
            vec![Seg {
                level: Level::Ok,
                n: 9
            }]
        );
    }

    #[test]
    fn an_owned_red_on_time_is_being_fixed_and_only_the_rest_turn_the_card_red() {
        let trip = |what: &str, by: &str| crate::alerts::Alert {
            what: what.into(),
            source: "sentinel".into(),
            owner: if by.is_empty() {
                "-".into()
            } else {
                "ar-1 fixing".into()
            },
            state: if by.is_empty() {
                "no owner".into()
            } else {
                "fixing".into()
            },
            fixing_by: by.into(),
            ..Default::default()
        };
        let mut a = crate::alerts::Alerts {
            level: Level::Red,
            firing: vec![
                trip("release-links", "dotfiles-agent-7"),
                trip("pr-blocked", ""),
            ],
            ..Default::default()
        };
        a.counts.firing = 2;
        a.counts.need_you = 1;
        a.counts.being_fixed = 1;
        let c = alerts(&a);
        assert_eq!((c.level, c.big.as_str()), (Level::Red, "1"));
        assert_eq!(c.unit, "need you, 1 being fixed, 2 firing");
        let first: Vec<(&str, &str, Level)> = c
            .first
            .iter()
            .map(|f| (f.text.as_str(), f.sub.as_str(), f.level))
            .collect();
        assert_eq!(
            first,
            [
                ("pr-blocked", "- - no owner", Level::Red),
                (
                    "release-links",
                    "being fixed by dotfiles-agent-7",
                    Level::Ok
                ),
            ]
        );
        // Every red being fixed: nothing needs the human, so the card is green though the tab is red.
        a.firing.pop();
        a.counts.firing = 1;
        a.counts.need_you = 0;
        let c = alerts(&a);
        assert_eq!((c.level, c.big.as_str()), (Level::Ok, "0"));
        assert_eq!(
            c.bar,
            vec![Seg {
                level: Level::Ok,
                n: 1
            }]
        );
    }

    #[test]
    fn schedules_rank_failing_then_no_purpose_and_cap_the_list() {
        let s = |name: &str, streak: i32, purpose: &str| {
            let mut r = crate::schedules::Schedule::default();
            r.name = name.into();
            r.kind = "timer".into();
            r.streak = streak;
            r.state = if streak < 0 {
                crate::reading::JobState::Failing
            } else {
                crate::reading::JobState::Ok
            };
            r.purpose = purpose.into();
            r
        };
        let sch = crate::schedules::Schedules {
            rows: vec![
                s("dream", -2, "x"),
                s("a", -1, "x"),
                s("b", 3, ""),
                s("c", -1, "x"),
                s("ok", 4, "x"),
            ],
            ..Default::default()
        };
        let c = schedules(&sch);
        assert_eq!(c.level, Level::Red);
        assert_eq!(c.first.len(), SHOWN_FIRST);
        assert_eq!(c.first[0].sub, "timer - failed 2 in a row");
        assert_eq!(
            c.bar,
            vec![
                Seg {
                    level: Level::Ok,
                    n: 1
                },
                Seg {
                    level: Level::Warn,
                    n: 1
                },
                Seg {
                    level: Level::Red,
                    n: 3
                }
            ]
        );
    }

    #[test]
    fn projects_look_first_where_the_human_is_waited_on() {
        let p = |name: &str, waiting: usize, hot: usize| crate::projects::Card {
            name: name.into(),
            waiting,
            hot,
            ..Default::default()
        };
        let ps = crate::projects::Projects {
            cards: vec![p("quiet", 0, 0), p("hot", 0, 4), p("binks", 2, 1)],
            ..Default::default()
        };
        let c = projects(&ps);
        assert_eq!(c.level, Level::Warn);
        assert_eq!(
            c.first.iter().map(|f| f.text.as_str()).collect::<Vec<_>>(),
            ["binks", "hot"]
        );
        assert_eq!(c.first[0].link.as_ref().unwrap().href(), "#projects/binks");
    }

    #[test]
    fn costs_amber_when_the_budget_needs_a_look_even_with_burn_ok() {
        let mut k = crate::costs::Costs::default();
        k.burn.level = "ok";
        k.fleet_cost.usd = "$573".into();
        k.budget.needs = vec!["projected over cap".into()];
        let c = costs(&k);
        assert_eq!((c.big.as_str(), c.level), ("$573", Level::Warn));
        // Negative control: a cost that could not be read must not paint green, and a partial
        // read never reads as all clear.
        k.fleet_cost.why = Some("file missing".into());
        let c = costs(&k);
        assert_eq!((c.big.as_str(), c.level), ("-", Level::Nodata));
        assert_eq!(c.bar[0].level, Level::Nodata);
        k.fleet_cost.why = None;
        k.budget.needs.clear();
        k.errors = vec!["ccusage: timed out".into()];
        assert_eq!(costs(&k).level, Level::Warn);
    }

    fn need(kind: crate::home::Kind, text: &str, since: Option<i64>) -> crate::home::Need {
        crate::home::Need {
            kind,
            need: crate::home::NeedKind::Turn,
            rank: 0,
            ask: None,
            project: ".dotfiles".into(),
            text: text.into(),
            id: text.into(),
            target: None,
            since,
            recommend: None,
            score: None,
        }
    }

    #[test]
    fn needs_counts_what_waits_on_you_and_looks_first_at_the_oldest() {
        use crate::home::{Home, Kind};
        let home = Home {
            needs: vec![
                need(Kind::Ask, "new ask", Some(9_000)),
                need(Kind::Session, "old session", Some(1_000)),
                need(Kind::Queue, "held item", None),
                // A condition and a red are not waits: they stay off this card.
                need(Kind::Stopped, "stopped", Some(0)),
                need(Kind::Nightly, "nightly", Some(0)),
            ],
            ..Home::default()
        };
        let c = needs(&home, 10_000);
        assert_eq!((c.big.as_str(), c.level), ("3", Level::Warn));
        let first: Vec<_> = c.first.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(first, ["old session", "new ask", "held item"]);
        assert_eq!(c.first[0].sub, "2h dotfiles");
        // Negative control: nothing waiting is a green zero, and an unread Home is never green.
        let mut empty = Home::default();
        assert_eq!(needs(&empty, 0).level, Level::Ok);
        empty.errors = vec!["asks: timed out".into()];
        assert_eq!(needs(&empty, 0).level, Level::Warn);
    }

    #[test]
    fn main_red_names_the_red_repos() {
        use crate::home::{Home, Kind};
        let home = Home {
            needs: vec![
                need(Kind::Nightly, "red", None),
                need(Kind::Ask, "ask", None),
            ],
            ..Home::default()
        };
        let c = main_red(&home);
        assert_eq!((c.big.as_str(), c.level), ("1", Level::Red));
        assert_eq!(c.first[0].text, "dotfiles");
        assert_eq!(main_red(&Home::default()).level, Level::Ok);
        // Negative control: a Home whose reads failed is no all-clear on main.
        let unread = Home {
            errors: vec!["Prometheus: timed out".into()],
            ..Home::default()
        };
        assert_eq!(main_red(&unread).level, Level::Warn);
    }

    #[test]
    fn costs_names_the_top_session_of_the_live_24h() {
        use crate::spend_history::{Day, Sess};
        let sess = |id: &str, usd: f64| Sess {
            sid: id.into(),
            usd,
            project: Some("p".into()),
            title: Some(id.into()),
            ..Default::default()
        };
        let mut k = crate::costs::Costs::default();
        k.burn.level = "ok";
        // A nightly day is not the last 24h: its dearer session is no line.
        k.spend_days = vec![Day {
            sessions: std::sync::Arc::new(vec![sess("big-but-old", 90.0)]),
            ..Default::default()
        }];
        k.live = Some(Day {
            sessions: std::sync::Arc::new(vec![sess("small", 3.0), sess("top", 12.5)]),
            ..Default::default()
        });
        let c = costs(&k);
        assert!(
            c.first.iter().any(|f| f.text == "$12.50 top"),
            "{:?}",
            c.first
        );
        // A budget need outranks it: with three rows to show, the need stays and the session goes.
        k.burn.head = "burning 2x".into();
        k.budget.needs = vec!["over cap".into(), "projected over".into()];
        let rows: Vec<_> = costs(&k).first.into_iter().map(|f| f.text).collect();
        assert_eq!(rows, ["burning 2x", "over cap", "projected over"]);
        k.budget.needs.clear();
        // Negative control: no live file is no line, never an old one.
        k.live = None;
        assert!(costs(&k).first.iter().all(|f| !f.text.starts_with('$')));
    }

    #[test]
    fn pick_keeps_the_named_cards_in_the_named_order() {
        let cards = vec![
            Card::reading("sessions", "Sessions"),
            Card::reading("alerts", "Alerts"),
        ];
        let got: Vec<_> = pick(cards, &["alerts", "nope", "sessions", "alerts"])
            .iter()
            .map(|c| c.tab)
            .collect();
        assert_eq!(got, ["alerts", "sessions"]);
    }
}
