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

/// A labelled count under the bar (`Offline 43`), coloured by its own level, and the rows it
/// counts when they have a view of their own (else a tap opens the card's tab).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Part {
    pub label: String,
    pub value: String,
    pub level: Level,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<Link>,
}

/// A "where to look first" row: what it is, a line under it, and the record it opens.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct First {
    pub text: String,
    pub sub: String,
    pub level: Level,
    pub link: Option<Link>,
}

/// One headed list of rows on a card.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Rows {
    pub head: String,
    pub rows: Vec<First>,
}

/// The heading over a card's one list when it has nothing more particular to say.
pub const FIRST_HEAD: &str = "Where to look first";

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Card {
    /// The card's id: the `hub_core::layout` tab it opens, or for a card with no tab of its own
    /// what it counts (`opens` says where each leads). A widget's `?cards=` names cards by it.
    pub tab: &'static str,
    pub title: &'static str,
    /// The one big number or word, and what it counts: a fixed word of 16 characters or fewer,
    /// the widget's cap (`widget_doc` tests every card's), so a count beside it is a part.
    pub big: String,
    pub unit: String,
    /// The card's worst level: the big number wears it.
    pub level: Level,
    pub bar: Vec<Seg>,
    pub parts: Vec<Part>,
    /// The row lists under the parts, each under its own heading, in order ("Where to look
    /// first", "Flow"). A list with no rows draws nothing.
    pub lists: Vec<Rows>,
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
            lists: vec![],
            counted: counted.into(),
            error: None,
            link: Link::tab(opens(tab)),
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

    fn part(self, label: &str, value: impl ToString, level: Level) -> Card {
        self.part_to(label, value, level, None)
    }

    /// A part that opens the rows it counts.
    fn part_to(
        mut self,
        label: &str,
        value: impl ToString,
        level: Level,
        link: Option<Link>,
    ) -> Card {
        self.parts.push(Part {
            label: label.into(),
            value: value.to_string(),
            level,
            link,
        });
        self
    }

    /// The card's list of the first `SHOWN_FIRST` of `rows` under `head`.
    fn list(self, head: impl Into<String>, rows: impl IntoIterator<Item = First>) -> Card {
        self.rows(head, rows.into_iter().take(SHOWN_FIRST).collect())
    }

    /// A list of exactly `rows`, for one that must not be cut.
    fn rows(mut self, head: impl Into<String>, rows: Vec<First>) -> Card {
        self.lists.push(Rows {
            head: head.into(),
            rows,
        });
        self
    }

    fn first(self, rows: impl IntoIterator<Item = First>) -> Card {
        self.list(FIRST_HEAD, rows)
    }
}

/// The tab a card id opens: Needs you and Main red are Home's own lists, Done today is the
/// queue's done items and Health the Infra tab; CI is `ci`, the retired tab name that lands on
/// Infra's Runners tab (`layout::RETIRED`, `layout::section`); every other card is its tab's.
fn opens(id: &str) -> &str {
    match id {
        "needs" | "red" => "home",
        "done" => "queue",
        "health" => "infra",
        tab => tab,
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
    // The fleet's own sessions (the shepherd) are no one's task: fleet-sessions' `.counts`, which
    // Home's "need you" header reads, leave them out, so this card does too (one number per fact).
    let live: Vec<_> = rows
        .iter()
        .filter(|r| r.source == Source::Live && !r.machine)
        .collect();
    let n = |b: &str| live.iter().filter(|r| r.bucket == b).count();
    let (needs, stalled) = (n("NEEDS"), n("STALLED"));
    // the ok segment: live rows neither finished nor waiting, counted directly so a finished bucket
    // that is also NEEDS or STALLED cannot be taken off twice
    let ok = live
        .iter()
        .filter(|r| !r.done && r.bucket != "NEEDS" && r.bucket != "STALLED")
        .count();
    // What got done today is the Done today card's, so this card counts no ended sessions.
    let mut c = Card::new(
        "sessions",
        "Sessions",
        "live tmux sessions by fleet-sessions bucket",
    )
    .bar(ok, stalled, needs)
    .part("Working", n("WORKING"), Level::Ok)
    .part("Need you", needs, lvl(needs, Level::Red))
    .part("Stalled", stalled, lvl(stalled, Level::Warn))
    // Ready to close: live rows in a finished bucket (DONE, LANDED), the chip's check count. The
    // chip reads it as `sessions_ready_to_close`, so no surface counts the vocabulary itself.
    .part(
        "Ready to close",
        live.iter().filter(|r| r.done).count(),
        Level::Ok,
    );
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

/// Queue: the work, then whether it flows. The big number is what runs now; the lists name the
/// running items, the ones parked on a PR and the next to start (`bar::ready`, in start order), each
/// `SHOWN_FIRST` rows, then Flow (`queue_verdict`): the head verdict, then the item a hold keeps
/// waiting and each other exception, each with its Do, worst first, uncapped; the card wears the
/// worst. The waybar queue chip lays this card out from summary/cards, and the Queue tabs draw the
/// same lines, so the three agree.
pub fn queue(
    q: &crate::queue::Queue,
    pipeline: Option<&Result<Option<crate::pipeline::Pipeline>, String>>,
    now: i64,
) -> Card {
    use crate::queue::State;
    let (running, review, queued) = (
        q.count(State::Running),
        q.count(State::Review),
        q.count(State::Queued),
    );
    // On deck is the queued items nothing holds, as waybar's Q: counts them; the rest are held.
    // With no stats read the card says "queued" and counts them all, never a runnable number.
    let (on_deck, held) = (q.on_deck(), q.held());
    let mut c = Card::new(
        "queue",
        "Queue",
        "agent-queue items by state (agent-queue list)",
    )
    .bar(
        running + review + on_deck.map_or(queued, |n| n as usize),
        0,
        0,
    )
    .part("Running", running, Level::Ok)
    .part("On a PR", review, Level::Ok);
    // The On deck part is the figure waybar's Q: reads, so with no stats it is absent and Q: says -,
    // never the queued count the headline falls back to.
    if let (Some(d), Some(h)) = (on_deck, held) {
        c = c
            .part("On deck", d as usize, Level::Ok)
            .part("Held", h as usize, Level::Ok);
    }
    c.big = running.to_string();
    c.unit = "running".into();
    // Items that only wait on someone are Needs you's to say: the card is read and fine, not empty.
    if c.level == Level::Nodata && !q.items.is_empty() {
        c.level = Level::Ok;
    }
    let at = chrono::DateTime::from_timestamp(now, 0).unwrap_or_default();
    let ready = crate::bar::ready(q, now);
    c = c
        .part("Urgent", ready.urgent, Level::Ok)
        .part("High", ready.high, Level::Ok);
    if let Some(r) = q.stats.as_ref().and_then(|s| s.recent.as_ref()) {
        let n = r.failed_24h as usize;
        c = c.part("Failed 24h", n, lvl(n, Level::Warn));
    }
    let item_link =
        |i: &crate::queue::Item| Some(Link::to(crate::links::Kind::Queue, i.slug.clone()));
    let said = |rows: Vec<First>, empty: &str| {
        if rows.is_empty() {
            vec![row(empty, String::new(), Level::Ok, None)]
        } else {
            rows
        }
    };
    let working = q.in_state(State::Running).map(|i| {
        let sub = format!(
            "{} - {}",
            i.project.trim(),
            crate::display::fmt::dur_min(i.timing(at).in_state)
        );
        row(i.title(), sub, Level::Ok, item_link(i))
    });
    let parked = q.in_state(State::Review).map(|i| {
        let pr = i.pr_refs().next().and_then(crate::queue::pr_link_of);
        let (sub, link) = match pr {
            Some((label, Some(url))) => (label, Some(Link::Url(url))),
            Some((label, None)) => (label, item_link(i)),
            None => (i.project.trim().to_string(), item_link(i)),
        };
        row(i.title(), sub, Level::Ok, link)
    });
    let next = ready.items.iter().map(|i| {
        let sub = format!(
            "{} - {} - {}",
            i.priority,
            i.project.trim(),
            crate::display::fmt::dur_min(i.ready_min)
        );
        let link = Link::to(crate::links::Kind::Queue, i.slug.clone());
        let what = match (i.kind.as_str(), i.area.as_str()) {
            ("", _) => i.title.clone(),
            (k, "") => format!("{k}: {}", i.title),
            (k, a) => format!("{k}({a}): {}", i.title),
        };
        row(what, sub, Level::Ok, Some(link))
    });
    c = c
        .list(
            "Running",
            said(working.take(SHOWN_FIRST).collect(), "Nothing running"),
        )
        .list(
            "On a PR",
            said(parked.take(SHOWN_FIRST).collect(), "Nothing on a PR"),
        )
        .rows(
            format!(
                "Up next: {} ready, {} urgent, {} high",
                ready.total, ready.urgent, ready.high
            ),
            said(next.take(SHOWN_FIRST).collect(), "Nothing ready"),
        );
    let mut flow = vec![];
    if let Some(v) = &q.verdict {
        c = room(c, v);
        // Every line, uncapped: a hidden exception is one the human cannot act on.
        flow = v
            .lines(|| &ready)
            .into_iter()
            .map(|l| row(l.text, l.act, l.level, None))
            .collect();
        let verdict = v.level();
        let rank = crate::queue_verdict::rank;
        if c.level == Level::Nodata || rank(verdict) > rank(c.level) {
            c.level = verdict;
        }
    }
    let read = pipeline.map(Result::as_ref);
    let bottleneck = match read {
        Some(Ok(Some(p))) => p.bottleneck.as_ref().map(|b| (b, p.bottleneck_age())),
        _ => None,
    };
    if let Some((b, age)) = bottleneck {
        let step = crate::flow::step_label(&b.step);
        // Its age is in the text, so every Flow row's sub is a Do, as the chip lays it out.
        let text = match age {
            Some(a) => format!("Bottleneck: {step}, {a}"),
            None => format!("Bottleneck: {step}"),
        };
        flow.push(row(text, String::new(), Level::Warn, None));
    }
    c = c.rows("Flow", flow);
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

/// The room the last dispatch pass had, as parts: sessions against the target (amber once the run
/// units fill it, the gates and not the count decide when the machine is full) and load against its
/// cap (amber from 80%, red past it; none when the pass sent no load; held on load, the load the gate
/// judged), and the focus projects that go
/// first. None without a pass.
fn room(mut c: Card, v: &crate::queue_verdict::Verdict) -> Card {
    let d = |k: &str| v.get(&format!("dispatch.{k}"));
    if let Some(cap) = d("room_max_live") {
        let units = d("room_live_runs").unwrap_or(0);
        let total = d("room_total_live").map_or("-".into(), |n| n.to_string());
        let ul = if units >= cap { Level::Warn } else { Level::Ok };
        c = c.part("Sessions", format!("{total} of {cap}"), ul);
        let f = |k: &str| v.fact(&format!("dispatch.{k}"));
        // Held on load, the load is the one the gate judged, as the pause line says it.
        let load = if d("room_held_load") == Some(1) {
            f("room_load_at_hold")
        } else {
            f("room_load")
        };
        if let (Some(load), Some(lcap)) = (load, f("room_load_cap")) {
            let ll = if load > lcap {
                Level::Red
            } else if load >= lcap * 0.8 {
                Level::Warn
            } else {
                Level::Ok
            };
            c = c.part("Load", format!("{} of {}", load.floor(), lcap.floor()), ll);
        }
    }
    match d("focus_projects") {
        Some(n) if n > 0 => c.part("Focus first", n, Level::Warn),
        _ => c,
    }
}

/// Alerts: what fires now that needs the human (no owner, a fix that did not hold, a fix that
/// waits or is past its due), by the hue the Alerts tab gives each row; a red with its fix in
/// hand on time counts as being fixed, in the bar's green and as its own part, never as red.
/// A count, or `reading::NOT_READ` when the join's errors say its source (by the error's prefix)
/// was not read.
fn read_or(a: &crate::alerts::Alerts, source: &str, n: usize) -> String {
    if a.errors.iter().any(|e| e.starts_with(source)) {
        crate::reading::NOT_READ.to_string()
    } else {
        n.to_string()
    }
}

pub fn alerts(a: &crate::alerts::Alerts) -> Card {
    let by = |l: Level| {
        a.firing
            .iter()
            .filter(|x| x.unfixed() && x.hue() == l)
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
    .part("Unfixed", k.unfixed, need)
    .part("Being fixed", k.being_fixed, Level::Ok)
    .part("No owner", k.no_owner, lvl(k.no_owner, Level::Warn))
    .part("Fixes open", k.fixes_open, Level::Ok)
    .part("Firing", k.firing, Level::Nodata)
    // Uncoloured like Firing: Unfixed and Being fixed say whether a red waits on the human. A
    // source that did not answer reads not read, never 0 (rule 6).
    .part("Red now", read_or(a, "prometheus:", k.red_now), Level::Nodata)
    .part(
        "Watches tripped",
        read_or(a, "watches:", k.watches_tripped),
        Level::Nodata,
    );
    // Nothing needing the human is green when every source answered; the tab's own level says
    // which, and a tab that is red only for rows being fixed is green here.
    c.level = if need == Level::Ok && a.level == Level::Nodata {
        Level::Nodata
    } else {
        need
    };
    c.big = k.unfixed.to_string();
    c.unit = "unfixed".into();
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
            // An unowned row's state already says so; "-" is the tab's blank owner, not a name.
            "" => match x.owner.as_str() {
                "" | "-" => (x.state.clone(), x.hue()),
                owner => (format!("{owner} - {}", x.state), x.hue()),
            },
            by => (format!("being fixed by {by}"), Level::Ok),
        };
        row(x.what.clone(), sub, hue, None)
    }))
}

/// Done today: the PRs merged and the queue items closed since local midnight, by project,
/// from the one count the phone's Done section shows (`phone::Done`). A source that could not be
/// read is a dash and its reason, never a zero.
pub fn done(d: Option<&crate::phone::Done>) -> Card {
    const COUNTED: &str = "PRs merged today (the day-log record) and agent-queue items closed \
         since local midnight: shipped is closed ok with a merge, checks closed with none, one \
         per slug";
    let Some(d) = d else {
        return Card::failed(
            "done",
            "Done today",
            COUNTED,
            "neither agent-queue list nor today's day-log record could be read",
        );
    };
    let mut c = Card::new("done", "Done today", COUNTED);
    c.big = d.prs.map_or("-".into(), |n| n.to_string());
    c.unit = "PRs merged".into();
    c.level = Level::Ok;
    let mut unread = vec![];
    match d.items {
        Some(t) => {
            c = c
                .part("Shipped", t.shipped, Level::Ok)
                .part("Checks", t.checks, Level::Ok);
        }
        None => {
            c = c
                .part("Shipped", crate::reading::NOT_READ, Level::Nodata)
                .part("Checks", crate::reading::NOT_READ, Level::Nodata);
            unread.push("agent-queue list could not be read");
            c.level = Level::Warn;
        }
    }
    if d.prs.is_none() {
        unread.push("no day-log record for today yet");
        c.level = Level::Nodata;
    }
    if !unread.is_empty() {
        c.error = Some(unread.join("; "));
    }
    c.list(
        "By project",
        d.by.iter()
            .map(|(name, t, prs)| {
                row(
                    name.clone(),
                    crate::phone::Done::said(t, *prs),
                    Level::Ok,
                    None,
                )
            })
            .collect::<Vec<_>>(),
    )
}

/// Health: the machines Prometheus reads, the System domains (`cc:domain_status`,
/// `Infra::domains`) the waybar health chip and the phone's System line show, and fleet-bench's
/// vitals. CI is its own card (`ci`). It opens the Infra tab.
pub fn health(i: &crate::infra::Infra) -> Card {
    const COUNTED: &str = "machines with a reading and the cc:domain_status domains from \
         Prometheus, a domain down turning the card red; vitals are fleet-bench's KPIs against their targets";
    if !i.ok {
        return Card::failed(
            "health",
            "Health",
            COUNTED,
            i.error
                .clone()
                .unwrap_or("Prometheus did not answer".into()),
        );
    }
    let up = i.machines.iter().filter(|m| m.state == "up").count();
    let unread = i.machines.iter().filter(|m| m.state == NO_DATA).count();
    let (d_down, d_warn, d_up) = i.domains();
    let mut c = Card::new("health", "Health", COUNTED)
        .bar(up, i.machines.len() - up - unread, unread)
        .part("Domains down", d_down, lvl(d_down, Level::Red))
        .part("Domains warn", d_warn, lvl(d_warn, Level::Warn))
        .part("Domains up", d_up, Level::Ok);
    if let Some(v) = crate::vitals::read(i) {
        let level = if v.rows.is_empty() {
            Level::Nodata
        } else if v.all_ok {
            Level::Ok
        } else {
            Level::Warn
        };
        c = c.part("Vitals", v.tally(), level);
        if level == Level::Warn && c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    if d_down > 0 {
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
    let domains = i
        .health()
        .into_iter()
        .filter(|d| d.level == Level::Red)
        .map(|d| row(d.name, "domain down", Level::Red, None));
    c.first(machines.chain(domains).collect::<Vec<_>>())
}

/// CI: the jobs running now and the ones waiting, from the CI glance the bar's `CI r:N q:N`
/// and the phone's CI row read, the runners up of the roster, the queued jobs no runner takes
/// and what is stuck. Red only on a runner down, a job no runner takes or a stuck run
/// (`Glance::alert`'s rule plus Alerts' stuck runs), never queue depth. It opens Infra's Runners tab.
pub fn ci(i: &crate::infra::Infra) -> Card {
    const COUNTED: &str = "CI running is the jobs on a runner now, Queued the jobs waiting and \
         Runners up the runners up of the roster, all from the CI glance; No runner is the \
         queued jobs no online runner can take and Stuck the runs Alerts lists; only a runner \
         down, a job with no runner or a stuck run turns the card red";
    if !i.ok {
        return Card::failed(
            "ci",
            "CI",
            COUNTED,
            i.error
                .clone()
                .unwrap_or("Prometheus did not answer".into()),
        );
    }
    let down = i.runners_down();
    // Alerts' stuck runs, the one list its rows read: one number for one fact.
    let runs = crate::alerts::stuck_runs(i);
    let g = &i.ci.glance;
    let mut c = Card::new("ci", "CI", COUNTED)
        .bar(g.up as usize, 0, down.len())
        .part("Queued", g.queued, Level::Ok)
        .part(
            "Runners up",
            g.up_line(),
            match g.expected {
                0 => Level::Nodata,
                _ => lvl(down.len(), Level::Red),
            },
        )
        .part("No runner", i.ci.red.len(), lvl(i.ci.red.len(), Level::Red))
        .part("Stuck", runs.len(), lvl(runs.len(), Level::Red));
    if down.len() + runs.len() + i.ci.red.len() > 0 {
        c.level = Level::Red;
    }
    c.big = g.busy.to_string();
    c.unit = "CI running".into();
    let red =
        i.ci.red
            .iter()
            .map(|r| row(r.clone(), "no runner takes it", Level::Red, None));
    let runners = down.iter().map(|s| {
        row(
            format!("{} down", s.label("runner")),
            "CI runner",
            Level::Red,
            None,
        )
    });
    let stuck = runs.iter().map(|s| {
        row(
            s.name(),
            format!("stuck run, {}", s.age_text()),
            Level::Red,
            None,
        )
    });
    let oldest = g.next.first().map(|q| {
        row(
            format!("{} {}", q.repo, q.job).trim().to_string(),
            format!(
                "oldest queued, {} x{}",
                crate::display::fmt::age(q.wait),
                q.n
            ),
            Level::Ok,
            None,
        )
    });
    c.first(
        red.chain(runners)
            .chain(stuck)
            .chain(oldest)
            .collect::<Vec<_>>(),
    )
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
    c.unit = "in 24h".into();
    c = c
        .part("Month", &k.budget.spent, Level::Ok)
        .part(
            "Projected",
            &k.budget.projected,
            lvl(k.budget.needs.len(), Level::Warn),
        )
        .part("API cash", &fc.cash, Level::Ok)
        .part("Sub burn", &fc.burn, Level::Ok);
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
    c.list(
        "Burn",
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

/// What an app's row says: its status word and, for a channel the collector could not read, which
/// one and why, so "ok" never sits under an amber hue unexplained.
fn app_says(a: &crate::releases::App) -> String {
    let unread: Vec<String> = a
        .channels
        .iter()
        .filter(|c| c.unread())
        .map(|c| format!("{} not read: {}", c.label, c.why_unread()))
        .collect();
    if unread.is_empty() {
        a.status_text.clone()
    } else {
        format!("{}; {}", a.status_text, unread.join("; "))
    }
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
    // A legacy app (no release through the flow yet) is a grey segment, never a look.
    let legacy = n(R::Neutral);
    if legacy > 0 {
        c.bar.push(Seg {
            level: Level::Nodata,
            n: legacy,
        });
        c = c.part("Legacy", legacy, Level::Nodata);
    }
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
        R::Neutral => Level::Nodata,
    };
    c.first(r.apps.iter().filter(|a| !a.level.calm()).map(|a| {
        row(
            a.project.clone(),
            app_says(a),
            hue(a.level),
            Some(Link::to(crate::links::Kind::App, a.project.clone())),
        )
    }))
}

/// Schedules: everything that runs on its own, by its job state.
pub fn schedules(s: &crate::schedules::Schedules) -> Card {
    use crate::reading::JobState;
    let n = |st: JobState| s.rows.iter().filter(|r| r.state == st).count();
    let (failing, stale, never) = (n(JobState::Failing), n(JobState::Stale), n(JobState::Never));
    // A row with no purpose is the tab's lint, not a fault: it joins no level here (its count is in
    // the summary `counted` says).
    let look = stale + never;
    let mut c = Card::new("schedules", "Schedules", "")
        .bar(s.rows.len() - failing - look, look, failing)
        .part("Failing", failing, lvl(failing, Level::Red))
        .part("Stale", stale, lvl(stale, Level::Warn))
        .part("Never ran", never, lvl(never, Level::Warn));
    c.big = s.rows.len().to_string();
    c.unit = "scheduled things".into();
    c.counted = s.summary.clone();
    if !s.errors.is_empty() {
        c.error = Some(s.errors.join("; "));
    }
    // The rows come ranked failing, stale, never, then no purpose (schedules::rank); the last are
    // not listed.
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
            _ => return None,
        };
        Some(row(r.name.clone(), sub, level, None))
    }))
}

/// Projects: the lab projects and which have work in flight. Who waits on the human is Needs
/// you's fact, never counted here (one reader per fact), and the per-project hot count is the
/// Projects tab's.
pub fn projects(p: &crate::projects::Projects) -> Card {
    let cards = &p.cards;
    let mut c = Card::new(
        "projects",
        "Projects",
        "lab projects with their board slice and queue (notes projects --stats)",
    )
    .part(
        "In flight",
        cards.iter().filter(|c| c.in_flight()).count(),
        Level::Ok,
    )
    .part(
        "Sprints",
        cards
            .iter()
            .filter(|c| crate::projects::sprint_says(c).is_some())
            .count(),
        Level::Ok,
    );
    // Every project counted is one green: a bar of one segment would repeat the big number.
    c.level = worst(0, 0, cards.len());
    c.big = cards.len().to_string();
    c.unit = "lab projects".into();
    if !p.errors.is_empty() {
        c.error = Some(p.errors.join("; "));
        if c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    let mut look: Vec<_> = cards.iter().filter(|c| c.in_flight()).collect();
    look.sort_by_key(|a| std::cmp::Reverse(a.running.len()));
    c.list(
        "In flight",
        look.into_iter().map(|p| {
            let sub = match p.running.len() {
                0 => "none running".to_string(),
                n => format!("{n} running"),
            };
            row(
                p.name.clone(),
                sub,
                Level::Ok,
                Some(Link::to(crate::links::Kind::Project, p.name.clone())),
            )
        }),
    )
}

/// Board: every open row on the boards (an agent row with the retired `tier:backlog` token is
/// Backlog's part, never listed), the feed's `totals` (`tasks::Totals`, the waybar hover's `all lanes`
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
    let mut c = Card::new(
        "board",
        "Board",
        "open rows on every sheet, human, agent and playtest (notes board); requested is asked \
         for and not started, late is past its due day; backlog is the agent rows still \
         carrying the retired tier:backlog token, counted in none of the others; sprint is the \
         release windows' rows still open of the rows they hold, left out when none is recorded",
    )
    .bar(n_open.saturating_sub(n_late + n_asked), n_asked, n_late)
    .part("Doing", n_doing, Level::Ok)
    .part("Requested", n_asked, lvl(n_asked, Level::Warn))
    .part("Late", n_late, lvl(n_late, Level::Red))
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
    c.unit = "open".into();
    // No `f.errors` here: they are the stats and queue joins `sheet_view` adds, which the hub's
    // feed carries and the web's does not, and no count on this card uses them.
    // Up next fills the list only when nothing is late or asked for, under its own head.
    let urgent = n_late + n_asked > 0;
    let head = if urgent { FIRST_HEAD } else { "Up next" };
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
    c.list(
        head,
        look.into_iter().map(|(r, level)| {
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
        }),
    )
}

/// One tab's read as the grid gets it: None while it has not answered, else its answer.
pub type Got<'a, T> = Option<Result<&'a T, &'a str>>;

/// Every read the grid maps, as each surface holds it.
#[derive(Default)]
pub struct Reads<'a> {
    pub sessions: Got<'a, [crate::session_table::SessionRow]>,
    pub board: Got<'a, crate::tasks::Feed>,
    pub queue: Got<'a, crate::queue::Queue>,
    /// The project of each PR merged today (`phone::merged_today`); None with no day-log record.
    pub merged: Option<&'a [String]>,
    /// When the grid is read, for the Done card's local midnight.
    pub now: i64,
    pub pipeline: Option<&'a Result<Option<crate::pipeline::Pipeline>, String>>,
    pub alerts: Got<'a, crate::alerts::Alerts>,
    pub infra: Got<'a, crate::infra::Infra>,
    pub costs: Got<'a, crate::costs::Costs>,
    pub releases: Got<'a, crate::releases::Releases>,
    pub schedules: Got<'a, crate::schedules::Schedules>,
    pub projects: Got<'a, crate::projects::Projects>,
}

/// Needs you: Home's list, oldest first. The count and the kind split are Home's own
/// (`Home::waiting`, `Home::split`), the same numbers the phone, the badge and the briefing show.
pub fn needs(home: &crate::home::Home, now: i64) -> Card {
    let count = home.waiting().count;
    let mut c = Card::new(
        "needs",
        "Needs you",
        "Home's Needs you: what only the human can do; agent work is routed, not listed",
    );
    c.big = count.to_string();
    c.unit = "waiting on you".into();
    for (label, n) in home.parts() {
        c = if label == crate::home::ONLY_YOU {
            // Not a kind, so no list to filter to: a count of the rows already listed.
            c.part(label, n, Level::Nodata)
        } else {
            let to = Link::to(crate::links::Kind::Needs, label);
            c.part_to(label, n, lvl(n, Level::Warn), Some(to))
        };
    }
    // Nothing waiting is a green zero, never no data: Home answered.
    c.level = lvl(count, Level::Warn);
    if !home.errors.is_empty() {
        c.error = Some(home.errors.join("; "));
        if c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    let mut old: Vec<&crate::home::Need> = home.needs.iter().collect();
    old.sort_by_key(|n| n.since.unwrap_or(i64::MAX));
    c.list(
        "Oldest",
        old.into_iter().map(|n| {
            let waited = n
                .since
                .map(|t| crate::display::fmt::age(now - t))
                .unwrap_or_default();
            let sub = [waited.as_str(), n.project.trim_start_matches('.')]
                .iter()
                .filter(|s| !s.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join(" ");
            row(
                crate::text::cap(&n.text, 60),
                sub,
                Level::Warn,
                Some(n.link()),
            )
        }),
    )
}

/// Main red: the repos whose nightly on main is red.
pub fn main_red(home: &crate::home::Home) -> Card {
    let red = crate::phone::red_repos(home);
    let mut c = Card::new(
        "red",
        "Main red",
        "Home's routed agent work: repos whose nightly on main is red",
    );
    c.big = red.len().to_string();
    c.unit = "red on main".into();
    c.level = lvl(red.len(), Level::Red);
    // Home's nightly reds come from reads that can fail: a zero then is unknown, never green.
    if !home.errors.is_empty() {
        c.error = Some(home.errors.join("; "));
        if c.level == Level::Ok {
            c.level = Level::Warn;
        }
    }
    c.list(
        "Red",
        red.iter().map(|r| row(*r, "nightly", Level::Red, None)),
    )
}

/// Home's card order on every surface. Needs you and Main red lead the widgets; on the web and the TUI
/// Home they are the Needs you list under the grid, so those draw `grid`, the rest of this list.
pub const ORDER: &[&str] = &[
    "needs",
    "red",
    "done",
    "health",
    "ci",
    "sessions",
    "queue",
    "board",
    "alerts",
    "costs",
    "releases",
    "schedules",
    "projects",
];

/// Old card ids and the card each now names, so a saved `?cards=` list keeps its card
/// (`layout.rs` holds the retired tab names beside this).
pub const ALIASES: &[(&str, &str)] = &[("infra", "health")];

/// The card id `name` stands for: itself, or the card an old id was renamed to.
pub fn id(name: &str) -> &str {
    ALIASES
        .iter()
        .find(|(old, _)| *old == name)
        .map_or(name, |(_, new)| new)
}

/// The cards `names` lists, in its order, an old id (`ALIASES`) naming its new card; a name no
/// card has is skipped.
pub fn pick(cards: Vec<Card>, names: &[&str]) -> Vec<Card> {
    let mut cards: Vec<Option<Card>> = cards.into_iter().map(Some).collect();
    names
        .iter()
        .filter_map(|n| {
            cards
                .iter_mut()
                .find(|c| c.as_ref().is_some_and(|c| c.tab == id(n)))
                .and_then(Option::take)
        })
        .collect()
}

/// The grid, `ORDER` after Needs you and Main red, on both surfaces: a card per tab, `reading` until its read
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
    // Done counts the queue and the day-log record: reading until the queue answers, and a
    // queue that failed leaves the PRs.
    let done_today = match r.queue {
        None => Card::reading("done", "Done today"),
        Some(q) => done(crate::phone::Done::read(q.ok(), r.merged, r.now).as_ref()),
    };
    vec![
        done_today,
        one(r.infra, "health", "Health", health),
        one(r.infra, "ci", "CI", ci),
        one(r.sessions, "sessions", "Sessions", sessions),
        one(r.queue, "queue", "Queue", |q| queue(q, r.pipeline, r.now)),
        one(r.board, "board", "Board", board),
        one(r.alerts, "alerts", "Alerts", alerts),
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

    /// The Queue card's Flow rows: its last list.
    fn flow(c: &Card) -> &[First] {
        let l = c.lists.last().expect("the Queue card's lists");
        assert_eq!(l.head, "Flow");
        &l.rows
    }

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
            c.lists[0]
                .rows
                .iter()
                .map(|f| f.text.as_str())
                .collect::<Vec<_>>(),
            ["c", "b"]
        );
        assert_eq!(
            c.lists[0].rows[0].link.as_ref().unwrap().href(),
            "#sessions/sessions/hub%2Fc%3A1"
        );
        assert!(c.parts.iter().all(|p| p.label != "Ended today"));
        assert_eq!(c.link.href(), "#sessions");
    }

    #[test]
    fn ready_to_close_counts_live_finished_rows_and_the_fleets_own_sit_outside() {
        let done = SessionRow {
            done: true,
            ..live("LANDED", "d")
        };
        let rows = vec![
            live("WORKING", "a"),
            done.clone(),
            SessionRow {
                machine: true,
                ..done
            },
            // an ended row is the Done today card's, not a session to close
            SessionRow {
                source: Source::Queue,
                done: true,
                ..live("DONE", "q")
            },
        ];
        let c = sessions(&rows);
        let part = |l: &str| {
            c.parts
                .iter()
                .find(|p| p.label == l)
                .map(|p| p.value.clone())
        };
        assert_eq!(part("Ready to close").as_deref(), Some("1"));
        assert_eq!(c.big, "2");
        assert_eq!(
            crate::widget_doc::figures(&[c]).get("sessions_ready_to_close"),
            Some(&1)
        );
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
        // What ended today is the Done today card's, so the card has no such part.
        assert_eq!(c.big, "2");
        assert!(c.parts.iter().all(|p| p.label != "Ended today"));
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
        assert_eq!(g.iter().map(|c| c.tab).collect::<Vec<_>>(), ORDER[2..]);
        // Done answers once the queue is read; with no day-log record its PRs are a dash, never 0.
        assert_eq!((g[0].tab, g[0].big.as_str()), ("done", "-"));
        assert_eq!(g[0].level, Level::Nodata);
        assert_eq!((g[1].big.as_str(), g[1].unit.as_str()), ("-", "reading"));
        assert_eq!(g[1].level, Level::Nodata);
        assert_eq!(
            (g[7].tab, g[7].big.as_str(), g[7].error.as_deref()),
            ("costs", "NO DATA", Some("prometheus: timeout"))
        );
        // Every card opens its tab: Done the Queue, Health the Infra tab.
        assert!(g
            .iter()
            .all(|c| c.link.href() == format!("#{}", opens(c.tab))));
        assert_eq!(
            (g[0].link.href(), g[1].link.href()),
            ("#queue".to_string(), "#infra".to_string())
        );
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
        assert_eq!((c.big.as_str(), c.unit.as_str()), ("5", "open"));
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
        let first: Vec<_> = c.lists[0]
            .rows
            .iter()
            .map(|f| (f.text.as_str(), f.level))
            .collect();
        assert_eq!(first, [("row db-4", Level::Red), ("row db-3", Level::Warn)]);
        assert_eq!(c.lists[0].head, "Where to look first");
        // A late row already started is still late.
        f.rows[3].state = "doing".into();
        assert_eq!(board(&f).lists[0].rows[0].text, "row db-4");
        f.rows[3].state = "open".into();
        assert_eq!(c.lists[0].rows[0].sub, "db - backlog, due 11-17");
        assert_eq!(
            c.lists[0].rows[0].link.as_ref().unwrap().href(),
            "#projects/all?q=id:=db-4"
        );
        // Nothing late or asked for: the card says what is up next.
        f.rows[2].requested = false;
        f.rows[3].due = None;
        let c = board(&f);
        assert_eq!((c.lists[0].head.as_str(), c.level), ("Up next", Level::Ok));
        assert_eq!(c.lists[0].rows[0].text, "row db-2");
        // A row on the backlog tier is not a place to look: Up next is the next board row.
        f.rows[1].backlog = true;
        assert_eq!(board(&f).lists[0].rows[0].text, "row db-5");
    }

    #[test]
    fn queue_names_the_bottleneck_step_and_never_counts_who_waits_on_you() {
        use crate::flow::tests::{pipe, queue as q};
        // No stats read: the big number is the running count, with no Held or On deck part.
        let c = queue(&q(), Some(&Ok(Some(pipe(2.25)))), 0);
        assert_eq!((c.big.as_str(), c.unit.as_str()), ("1", "running"));
        assert!(c
            .parts
            .iter()
            .all(|p| p.label != "Held" && p.label != "On deck"));
        // The stats say how many of the two queued items nothing holds: that is on deck, the
        // rest is Held, and a held item is no segment of the bar.
        let mut held = q();
        held.stats.as_mut().unwrap().sitting = Some(crate::queue::Sitting {
            queued: 2,
            runnable: 1,
            ..Default::default()
        });
        let c = queue(&held, Some(&Ok(Some(pipe(2.25)))), 0);
        assert_eq!((c.big.as_str(), c.unit.as_str()), ("1", "running"));
        let parts: Vec<_> = c
            .parts
            .iter()
            .map(|p| (p.label.as_str(), p.value.as_str()))
            .take(4)
            .collect();
        assert_eq!(
            parts,
            [
                ("Running", "1"),
                ("On a PR", "1"),
                ("On deck", "1"),
                ("Held", "1")
            ]
        );
        let bar: Vec<_> = c.bar.iter().map(|s| (s.level, s.n)).collect();
        // A waiting item is Needs you's fact (Blocked), so it is no red segment here: one reader.
        assert_eq!(bar, [(Level::Ok, 3)]);
        // With no verdict read the bottleneck is the only row, after where the flow lines go.
        assert_eq!(c.lists.last().unwrap().head, "Flow");
        assert_eq!(
            (flow(&c)[0].text.as_str(), flow(&c)[0].sub.as_str()),
            ("Bottleneck: needs you, age p90 9h00m (bound 4h00m)", "")
        );
        // A snapshot that could not be read is said on the card, never as no bottleneck.
        let c = queue(&held, Some(&Err("state.json: bad json".into())), 0);
        assert!(flow(&c).is_empty());
        assert_eq!(c.error.as_deref(), Some("pipeline: state.json: bad json"));
        // No snapshot read: no rows, and the item that waits on the human (q() has one) is no
        // segment or row of this card, since Needs you counts it as Blocked.
        let c = queue(&q(), None, 0);
        assert_eq!(c.error, None);
        assert!(flow(&c).is_empty());
        assert_eq!(c.level, Level::Ok);
        assert!(c.bar.iter().all(|s| s.level != Level::Red));
        // Only an item that waits on the human: the card is read, never no data.
        let mut only = q();
        only.items
            .retain(|i| i.state == crate::queue::State::Waiting);
        assert!(!only.items.is_empty());
        assert_eq!(queue(&only, None, 0).level, Level::Ok);
    }

    #[test]
    fn queue_lists_the_running_the_parked_and_the_next_with_an_empty_state_for_each() {
        use crate::flow::tests::queue as q;
        use crate::queue::State;
        let mut full = q();
        for i in &mut full.items {
            i.project = "dotfiles".into();
            i.title = format!("work {}", i.slug);
            i.priority = "high".into();
        }
        full.items[0].started = Some("1970-01-01T00:00:00Z".into());
        full.items[4].pr = Some("owner/repo#7".into());
        let c = queue(&full, None, 3600);
        let heads: Vec<_> = c.lists.iter().map(|l| l.head.as_str()).collect();
        assert_eq!(
            heads,
            [
                "Running",
                "On a PR",
                "Up next: 2 ready, 0 urgent, 2 high",
                "Flow"
            ]
        );
        let list = |n: usize| -> Vec<(&str, &str)> {
            c.lists[n]
                .rows
                .iter()
                .map(|r| (r.text.as_str(), r.sub.as_str()))
                .collect()
        };
        assert_eq!((c.big.as_str(), c.unit.as_str()), ("1", "running"));
        assert_eq!(list(0), [("work a", "dotfiles - 1h00m")]);
        assert_eq!(list(1), [("work e", "repo#7")]);
        assert_eq!(
            list(2).iter().map(|r| r.0).collect::<Vec<_>>(),
            ["work b", "work c"]
        );
        assert!(list(2)[0].1.starts_with("high - dotfiles - "));
        // Nothing running or parked: Running reads 0 and each list says so, never goes missing.
        full.items
            .retain(|i| i.state != State::Running && i.state != State::Review);
        let c = queue(&full, None, 3600);
        assert_eq!(c.big, "0");
        assert_eq!(c.lists[0].rows[0].text, "Nothing running");
        assert_eq!(c.lists[1].rows[0].text, "Nothing on a PR");
        // Long lists show SHOWN_FIRST rows each.
        let mut many = q();
        for n in 0..6 {
            let mut i = many.items[0].clone();
            i.slug = format!("r{n}");
            many.items.push(i);
        }
        assert_eq!(queue(&many, None, 0).lists[0].rows.len(), SHOWN_FIRST);
    }

    #[test]
    fn queue_rows_are_the_flow_verdict_with_its_do_and_the_card_wears_the_worst() {
        use crate::flow::tests::{pipe, queue as q};
        use crate::prom::Series;
        let s = |topic: &str, name: &str, v: f64| Series {
            labels: [
                ("__name__".to_string(), format!("mqtt_{name}")),
                ("topic".to_string(), format!("agents_h1_main_{topic}")),
            ]
            .into(),
            value: Some(v),
            points: vec![],
        };
        let mut held = q();
        held.verdict = Some(crate::queue_verdict::Verdict::from_series(
            &[
                s("summary_dispatch", "runnable", 2.0),
                s("summary_dispatch", "last_pass_epoch", 990.0),
                s("summary_dispatch", "held_s", 600.0),
                s("summary_dispatch", "room_held_load", 1.0),
                s("summary_dispatch", "room_load", 11.0),
                s("summary_dispatch", "room_load_at_hold", 30.0),
                s("summary_dispatch", "room_load_cap", 25.0),
                s("summary_dispatch", "room_max_live", 40.0),
                s("summary_dispatch", "room_total_live", 20.0),
                s("summary_shepherd", "unhandled", 1.0),
                s("watch_queue_starved", "tripped", 1.0),
            ],
            1000,
        ));
        let c = queue(&held, Some(&Ok(Some(pipe(2.25)))), 1000);
        assert_eq!(c.level, Level::Red, "a hold that starved the queue is red");
        let rows: Vec<_> = flow(&c)
            .iter()
            .map(|r| (r.level, r.text.as_str(), r.sub.as_str()))
            .collect();
        assert_eq!(
            rows[0],
            (
                Level::Red,
                "Dispatch paused 10m: load 30 is over its cap of 25",
                "See the fleet-pace skill"
            )
        );
        assert_eq!(
            rows[rows.len() - 2],
            (
                Level::Warn,
                "1 shepherd due line(s) unhandled",
                "Use the shepherd skill, triage"
            )
        );
        assert!(rows
            .last()
            .unwrap()
            .1
            .starts_with("Bottleneck: needs you, "));
        let part = |l: &str| {
            c.parts
                .iter()
                .find(|p| p.label == l)
                .map(|p| (p.value.as_str(), p.level))
        };
        assert_eq!(part("Sessions"), Some(("20 of 40", Level::Ok)));
        assert_eq!(part("Load"), Some(("30 of 25", Level::Red)));
        // Negative control: the same queue flowing is one green "Flowing" row and an ok card.
        held.verdict = Some(crate::queue_verdict::Verdict::from_series(
            &[
                s("summary_dispatch", "runnable", 2.0),
                s("summary_dispatch", "last_pass_epoch", 990.0),
            ],
            1000,
        ));
        let c = queue(&held, None, 1000);
        assert_eq!(c.level, Level::Ok);
        assert_eq!(
            flow(&c).iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            ["Flowing"]
        );
        assert!(c.parts.iter().all(|p| p.label != "Sessions"));
        // The load is judged on its fractions (24.6 is over a cap of 24.5), and a pass that sent no
        // load has a Sessions part and no Load part, never a load of 0.
        let mut room = |load: &[(&str, f64)]| {
            let mut series = vec![
                s("summary_dispatch", "last_pass_epoch", 990.0),
                s("summary_dispatch", "room_max_live", 40.0),
                s("summary_dispatch", "room_total_live", 20.0),
            ];
            series.extend(load.iter().map(|(k, v)| s("summary_dispatch", k, *v)));
            held.verdict = Some(crate::queue_verdict::Verdict::from_series(&series, 1000));
            let c = queue(&held, None, 1000);
            let load = c.parts.iter().find(|p| p.label == "Load");
            (
                c.parts.iter().any(|p| p.label == "Sessions"),
                load.map(|p| (p.value.clone(), p.level)),
            )
        };
        assert_eq!(
            room(&[("room_load", 24.6), ("room_load_cap", 24.5)]),
            (true, Some(("24 of 24".to_string(), Level::Red)))
        );
        assert_eq!(room(&[("room_load", 24.6)]), (true, None));
    }

    #[test]
    fn a_card_with_nothing_counted_is_no_data_never_green() {
        // Negative control: an empty read must not paint a green card.
        assert_eq!(sessions(&[]).level, Level::Nodata);
        assert_eq!(releases(&Default::default()).level, Level::Nodata);
        assert_eq!(schedules(&Default::default()).level, Level::Nodata);
    }

    #[test]
    fn the_old_infra_id_still_names_its_card_now_health() {
        let picked = pick(grid(&Default::default()), &["infra", "nope", "queue"]);
        assert_eq!(
            picked.iter().map(|c| c.tab).collect::<Vec<_>>(),
            ["health", "queue"]
        );
        assert_eq!((id("infra"), id("queue")), ("health", "queue"));
        // Negative control: an alias may not shadow a live card id.
        assert!(ALIASES.iter().all(|(old, _)| !ORDER.contains(old)));
    }

    #[test]
    fn health_that_did_not_answer_is_no_data_with_why() {
        let i = crate::infra::Infra {
            ok: false,
            error: Some("timeout".into()),
            ..Default::default()
        };
        let c = health(&i);
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
        // Prometheus or the watches unread: their counts read not read, never 0 (rule 6).
        let says = |a: &crate::alerts::Alerts, label: &str| {
            let c = alerts(a);
            c.parts
                .iter()
                .find(|p| p.label == label)
                .unwrap()
                .value
                .clone()
        };
        assert_eq!(
            says(&a, "Red now"),
            "0",
            "a reds read failure is not Prometheus's"
        );
        a.errors = vec!["prometheus: timeout".into(), "watches: gone".into()];
        assert_eq!(says(&a, "Red now"), crate::reading::NOT_READ);
        assert_eq!(says(&a, "Watches tripped"), crate::reading::NOT_READ);
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
        a.counts.unfixed = 1;
        a.counts.being_fixed = 1;
        let c = alerts(&a);
        assert_eq!((c.level, c.big.as_str()), (Level::Red, "1"));
        assert_eq!(c.unit, "unfixed");
        let part = |l: &str| c.parts.iter().find(|p| p.label == l).unwrap().value.clone();
        assert_eq!(
            (part("Being fixed"), part("Firing")),
            ("1".into(), "2".into())
        );
        let first: Vec<(&str, &str, Level)> = c.lists[0]
            .rows
            .iter()
            .map(|f| (f.text.as_str(), f.sub.as_str(), f.level))
            .collect();
        assert_eq!(
            first,
            [
                ("pr-blocked", "no owner", Level::Red),
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
        a.counts.unfixed = 0;
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
    fn schedules_rank_failing_and_cap_the_list_and_a_missing_purpose_is_no_level() {
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
        assert_eq!(c.lists[0].rows.len(), SHOWN_FIRST);
        assert_eq!(c.lists[0].rows[0].sub, "timer - failed 2 in a row");
        // Negative control: the row with no purpose (b) is on no row, part or level here.
        assert!(c.lists[0].rows.iter().all(|f| f.text != "b"));
        assert!(c.parts.iter().all(|p| p.label != "No purpose"));
        assert_eq!(
            c.bar,
            vec![
                Seg {
                    level: Level::Ok,
                    n: 2
                },
                Seg {
                    level: Level::Red,
                    n: 3
                }
            ]
        );
    }

    #[test]
    fn projects_list_who_has_work_in_flight_and_count_nobody_waiting_or_hot() {
        let p = |name: &str, waiting: usize, hot: usize, running: usize| crate::projects::Card {
            name: name.into(),
            waiting,
            hot,
            running: vec![Default::default(); running],
            ..Default::default()
        };
        let ps = crate::projects::Projects {
            cards: vec![
                p("quiet", 0, 0, 0),
                p("hot", 0, 4, 0),
                p("binks", 2, 1, 0),
                p("busy", 0, 0, 3),
            ],
            ..Default::default()
        };
        let c = projects(&ps);
        // Waiting is Needs you's and Hot is the tab's: no pill, level or bar here says either.
        assert!(c
            .parts
            .iter()
            .all(|p| p.label != "Waiting" && p.label != "Hot"));
        assert_eq!((c.level, c.bar.is_empty()), (Level::Ok, true));
        let rows: Vec<_> = c.lists[0]
            .rows
            .iter()
            .map(|f| (f.text.as_str(), f.sub.as_str()))
            .collect();
        // In flight is the one definition the phone and the Projects tab share; the sub says what
        // ran, so a project that only waits reads "none running", never a blank.
        assert_eq!(rows, [("busy", "3 running"), ("binks", "none running")]);
        assert_eq!(
            c.lists[0].rows[0].link.as_ref().unwrap().href(),
            "#projects/busy"
        );
        assert_eq!(projects(&Default::default()).level, Level::Nodata);
        // A read that failed is said, and a green card never hides it.
        let c = projects(&crate::projects::Projects {
            errors: vec!["notes projects: exit 1".into()],
            ..ps
        });
        assert_eq!(
            (c.level, c.error.as_deref()),
            (Level::Warn, Some("notes projects: exit 1"))
        );
    }

    #[test]
    fn sessions_need_you_is_the_count_home_says_not_the_fleets_own_sessions() {
        use serde_json::json;
        let s = |target: &str, bucket: &str, labels: &[&str]| json!({"target": target, "bucket": bucket, "labels": labels});
        let doc = vec![
            s("hub/a:1", "NEEDS", &[]),
            s("hub/b:1", "NEEDS", &[]),
            // The shepherd waits on a dialog too, and fleet-sessions' `.counts` leave it out.
            s("hub/shepherd:1", "NEEDS", &["shepherd"]),
            s("hub/c:1", "WORKING", &[]),
        ];
        let counts = json!({"WORKING": 1, "NEEDS": 2, "STALLED": 0});
        let state = json!({"sessions": doc, "counts": counts, "generated_epoch": 1000});
        let rows = crate::session_table::rows(&doc, &Default::default(), &Default::default(), &[]);
        let c = sessions(&rows);
        let pill = c.parts.iter().find(|p| p.label == "Need you").unwrap();
        let home = crate::home::build(Some(&state), None, None, None, 1000);
        assert_eq!(home.sessions, "1 working, 2 need you, 0 stalled");
        assert_eq!(pill.value, "2", "the card reads Home's count");
        assert_eq!(c.big, "3", "the shepherd is no live session of the card");
    }

    #[test]
    fn ci_stuck_is_alerts_stuck_runs_one_per_branch() {
        use crate::prom::Series;
        let run = |branch: &str, wf: &str| Series {
            labels: [
                ("repo", "app"),
                ("branch", branch),
                ("workflow", wf),
                ("stuck", "true"),
            ]
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
            value: Some(600.0),
            points: vec![],
        };
        let mut i = crate::infra::Infra {
            ok: true,
            ..Default::default()
        };
        // Three runs on two branches: Alerts has two rows, so CI says two, never three or 0.
        i.instant.insert(
            "waiting",
            vec![run("main", "CI"), run("main", "Checks"), run("feat", "CI")],
        );
        let c = ci(&i);
        let pill = c.parts.iter().find(|p| p.label == "Stuck").unwrap();
        let rows = crate::alerts::machinery(&i)
            .iter()
            .filter(|l| l.starts_with("stuck run"))
            .count();
        assert_eq!((pill.value.as_str(), rows), ("2", 2));
        assert_eq!(c.level, Level::Red);
        // The stuck runs are CI's, not Health's: Health stays machines, domains and vitals.
        let h = health(&i);
        assert!(h.parts.iter().all(|p| p.label != "Stuck"));
        assert_ne!(h.level, Level::Red);
        // A job no runner takes is a pill and the first row, so the red level is never unexplained.
        i.ci.red = vec!["Checks main".into()];
        let c = ci(&i);
        let red = c.parts.iter().find(|p| p.label == "No runner").unwrap();
        assert_eq!(red.value, "1");
        assert_eq!(c.lists[0].rows[0].text, "Checks main");
    }

    #[test]
    fn the_ci_card_reads_the_glance_and_is_red_only_for_a_fault_never_queue_depth() {
        let mut i = crate::infra::Infra {
            ok: true,
            ..Default::default()
        };
        i.ci.glance.busy = 4;
        i.ci.glance.queued = 23;
        i.ci.glance.up = 5;
        i.ci.glance.expected = 5;
        i.ci.glance.next = vec![crate::ci::Queued {
            job: "build".into(),
            repo: "app".into(),
            n: 2,
            wait: 600,
            ..Default::default()
        }];
        let c = ci(&i);
        assert_eq!(
            (c.tab, c.big.as_str(), c.unit.as_str(), c.link.href()),
            ("ci", "4", "CI running", "#ci".into())
        );
        let part = |l: &str| c.parts.iter().find(|p| p.label == l).unwrap().value.clone();
        assert_eq!(
            (part("Queued"), part("Runners up")),
            ("23".into(), "5/5".into())
        );
        // A deep queue is information: green, with the oldest queued job as the one row.
        assert_eq!(c.level, Level::Ok);
        assert_eq!(c.lists[0].rows[0].text, "app build");
        // A job no runner takes turns CI red and leaves Health green.
        i.ci.red = vec!["Checks main".into()];
        assert_eq!(ci(&i).level, Level::Red);
        assert_ne!(health(&i).level, Level::Red);
        // A reader that did not answer is no data with why, never a green zero.
        i.ok = false;
        i.error = Some("timeout".into());
        let c = ci(&i);
        assert_eq!(
            (c.big.as_str(), c.level, c.error.as_deref()),
            ("NO DATA", Level::Nodata, Some("timeout"))
        );
    }

    #[test]
    fn a_release_row_names_the_channel_that_was_not_read() {
        let mut a = crate::releases::App {
            project: "game".into(),
            status_text: "ok".into(),
            level: crate::releases::Level::Warn,
            ..Default::default()
        };
        assert_eq!(app_says(&a), "ok");
        let mut ch = crate::releases::Release {
            status: "unknown".into(),
            label: "beta game-beta".into(),
            ..Default::default()
        };
        ch.live.error = Some("no store key".into());
        a.channels = vec![ch];
        assert_eq!(app_says(&a), "ok; beta game-beta not read: no store key");
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
        // One segment would only repeat the level, so the card has no bar.
        assert!(c.bar.is_empty());
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
    fn needs_counts_home_and_looks_first_at_the_oldest() {
        use crate::home::{Home, Kind};
        let home = Home {
            needs: vec![
                need(Kind::Ask, "new ask", Some(9_000)),
                need(Kind::Session, "old session", Some(1_000)),
                need(Kind::Queue, "held item", None),
                need(Kind::Budget, "budget", Some(5_000)),
            ],
            // Agent work Home routed off the list stays off this card.
            routed: vec![need(Kind::Nightly, "nightly", Some(0))],
            ..Home::default()
        };
        let c = needs(&home, 10_000);
        assert_eq!((c.big.as_str(), c.level), ("4", Level::Warn));
        assert_eq!(c.big, home.waiting().count.to_string());
        // A bar of one segment would only repeat the big number.
        assert!(c.bar.is_empty());
        let parts: Vec<_> = c
            .parts
            .iter()
            .map(|p| (p.label.as_str(), p.value.as_str()))
            .collect();
        assert_eq!(parts, [("Your turn", "4"), ("Only you", "4")]);
        let first: Vec<_> = c.lists[0].rows.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(first, ["old session", "budget", "new ask"]);
        assert_eq!(c.lists[0].rows[0].sub, "2h dotfiles");
        // Each count opens Home's list filtered to its kind, as its tile does; a session and a
        // queue item open their own record, anything else its kind's filtered list.
        let to = |l: &Option<Link>| l.as_ref().map(Link::href);
        assert_eq!(
            to(&c.parts[0].link).as_deref(),
            Some("#home?ns=Your%20turn")
        );
        let opens: Vec<_> = c.lists[0]
            .rows
            .iter()
            .map(|f| to(&f.link).unwrap())
            .collect();
        assert_eq!(
            opens,
            [
                "#sessions/sessions/old%20session",
                "#home?ns=Your%20turn",
                "#home/ask/new%20ask"
            ]
        );
        assert_eq!(
            to(&Some(need(Kind::Queue, "q1", None).link())).as_deref(),
            Some("#queue/q1")
        );
        // Negative control: a card with no view of its own keeps the plain part, which opens its tab.
        assert_eq!(
            Card::new("x", "X", "").part("a", 1, Level::Ok).parts[0].link,
            None
        );
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
            needs: vec![need(Kind::Ask, "ask", None)],
            routed: vec![need(Kind::Nightly, "red", None)],
            ..Home::default()
        };
        let c = main_red(&home);
        assert_eq!((c.big.as_str(), c.level), ("1", Level::Red));
        assert!(c.bar.is_empty());
        assert_eq!(c.lists[0].rows[0].text, "dotfiles");
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
            c.lists[0].rows.iter().any(|f| f.text == "$12.50 top"),
            "{:?}",
            c.lists
        );
        // A budget need outranks it: with three rows to show, the need stays and the session goes.
        k.burn.head = "burning 2x".into();
        k.budget.needs = vec!["over cap".into(), "projected over".into()];
        let rows: Vec<_> = costs(&k)
            .lists
            .remove(0)
            .rows
            .into_iter()
            .map(|f| f.text)
            .collect();
        assert_eq!(rows, ["burning 2x", "over cap", "projected over"]);
        k.budget.needs.clear();
        // Negative control: no live file is no line, never an old one.
        k.live = None;
        assert!(costs(&k).lists[0]
            .rows
            .iter()
            .all(|f| !f.text.starts_with('$')));
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
