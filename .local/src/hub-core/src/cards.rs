//! Home's status grid: one card per tab, each the tab's own reader worded as a tile (docs/
//! dashboards.md, Tile pattern). A card counts nothing itself: each `fn` here maps what its tab's
//! reader already counted, so the card and the tab cannot disagree (rule 8), and every number
//! links to the tab that owns it (rule 2). Both surfaces draw `Card` as it is sent.

use serde::Serialize;

use crate::home::Level;
use crate::links::Link;

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
    /// The `hub_core::layout` tab id the card opens.
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
            big: crate::reading::NO_DATA.to_uppercase(),
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
    let done = rows.iter().filter(|r| r.bucket == "DONE").count();
    let mut c = Card::new(
        "sessions",
        "Sessions",
        "live tmux sessions by fleet-sessions bucket; done counts ended rows today",
    )
    .bar(live.len() - needs - stalled, stalled, needs)
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
    let (ready, held) = q.up_next();
    let (waiting, running, review) = (
        q.count(State::Waiting),
        q.count(State::Running),
        q.count(State::Review),
    );
    let mut c = Card::new(
        "queue",
        "Queue",
        "agent-queue items by state (agent-queue list)",
    )
    .bar(running + review + ready, held, waiting)
    .part("Running", running, Level::Ok)
    .part("On a PR", review, Level::Ok)
    .part("Ready", ready, Level::Ok)
    .part("Held", held, lvl(held, Level::Warn));
    c.big = q.count(State::Queued).to_string();
    c.unit = format!("queued, {running} running");
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

/// Alerts: what fires now, by the hue the Alerts tab gives each row.
pub fn alerts(a: &crate::alerts::Alerts) -> Card {
    let by = |l: Level| a.firing.iter().filter(|x| x.hue() == l).count();
    let k = &a.counts;
    let mut c = Card::new(
        "alerts",
        "Alerts",
        "tripped watches, cc:red_now, the machinery and Alertmanager",
    )
    .bar(0, by(Level::Warn), by(Level::Red))
    .part("Tripped", k.tripped, lvl(k.tripped, Level::Red))
    .part("Errors", k.errors, lvl(k.errors, Level::Warn))
    .part("No owner", k.no_owner, lvl(k.no_owner, Level::Warn))
    .part("Fixes open", k.fixes_open, Level::Ok);
    // Nothing firing is green when every source answered; the tab's own level says which.
    c.level = a.level;
    c.big = k.firing.to_string();
    c.unit = format!("firing, {} with no owner", k.no_owner);
    if a.firing.is_empty() && a.level == Level::Ok {
        c.bar = vec![Seg {
            level: Level::Ok,
            n: k.watches.max(1),
        }];
    }
    if !a.errors.is_empty() {
        c.error = Some(a.errors.join("; "));
    }
    c.first(a.firing.iter().map(|x| {
        row(
            x.what.clone(),
            format!("{} - {}", x.owner, x.state),
            x.hue(),
            None,
        )
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
    let unread = i
        .machines
        .iter()
        .filter(|m| m.state == "no reading")
        .count();
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
        let level = if m.state == "no reading" {
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
    c.first(head.into_iter().chain(needs).collect::<Vec<_>>())
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
    look.sort_by(|a, b| (b.waiting, b.hot).cmp(&(a.waiting, a.hot)));
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

/// One tab's read as the grid gets it: None while it has not answered, else its answer.
pub type Got<'a, T> = Option<Result<&'a T, &'a str>>;

/// Every read the grid maps, as each surface holds it.
#[derive(Default)]
pub struct Reads<'a> {
    pub sessions: Got<'a, [crate::session_table::SessionRow]>,
    pub queue: Got<'a, crate::queue::Queue>,
    pub pipeline: Option<&'a Result<Option<crate::pipeline::Pipeline>, String>>,
    pub alerts: Got<'a, crate::alerts::Alerts>,
    pub infra: Got<'a, crate::infra::Infra>,
    pub costs: Got<'a, crate::costs::Costs>,
    pub releases: Got<'a, crate::releases::Releases>,
    pub schedules: Got<'a, crate::schedules::Schedules>,
    pub projects: Got<'a, crate::projects::Projects>,
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
            "#sessions/hub%2Fc%3A1"
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
            (g[4].big.as_str(), g[4].error.as_deref()),
            ("NO DATA", Some("prometheus: timeout"))
        );
        assert!(g.iter().all(|c| c.link.href() == format!("#{}", c.tab)));
    }

    #[test]
    fn queue_names_the_bottleneck_step_and_else_what_waits_on_you() {
        use crate::flow::tests::{pipe, queue as q};
        let c = queue(&q(), Some(&Ok(Some(pipe(2.25)))));
        assert_eq!(
            (c.big.as_str(), c.unit.as_str()),
            ("2", "queued, 1 running")
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
}
