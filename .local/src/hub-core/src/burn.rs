//! The Costs tab's Burn section: how fast every model source is being spent (each Claude
//! account, the Codex plan, the gateway keys and the Lazer pool), how many sessions are going,
//! whether that is over what the windows can carry, the dispatch drip, and when each source is
//! back on pace. `claude-acct` computes every figure for every source and publishes it in its
//! textfile (`claude_account_*{kind}`, `claude_fleet_session_rate_points_per_hour`); this only
//! sums the per-source series and words them, so the hub TUI and agent-web print the same section
//! and no second formula exists. The drip is the `started` lines of fleet-dispatch's `log.md`.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::prom::Series;

/// The fleet's measured points of weekly limit one live session burns an hour (a 6h average).
pub const RATE_Q: &str = "claude_fleet_session_rate_points_per_hour";

/// Where the dispatch hold is explained (the Sessions header), as `SPEND_BADGE` names Costs.
pub const HOLD_BADGE: &str = "4 Sessions";

/// claude-acct's published answer on an automatic start for one account (its `room` object in
/// the textfile: `claude_account_room`, `_room_headroom_points`, `_room_reason`). The hub prints
/// it and never re-derives it from used and gone.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Room {
    pub ok: bool,
    /// Every refusal that holds the account now (`unread`, `capped`, `reserve`, `pace`,
    /// `five_hour`, `committed`); empty when it has room.
    pub reasons: Vec<String>,
    /// Points under the line after slack, negative past it; None without a week.
    pub headroom: Option<f64>,
    /// `words` of it, so a surface that cannot call Rust prints the same sentence.
    pub text: String,
}

impl Room {
    pub fn new(ok: bool, reasons: Vec<String>, headroom: Option<f64>) -> Self {
        let mut r = Room {
            ok,
            reasons,
            headroom,
            text: String::new(),
        };
        r.text = r.words();
        r
    }

    /// The verdict in words: `room, 4 points spare`, or `no room: pace 20 points past the line`.
    fn words(&self) -> String {
        let pts = |n: f64| format!("{n} point{}", if n == 1.0 { "" } else { "s" });
        if self.ok {
            return match self.headroom {
                Some(h) if h >= 0.0 => format!("room, {} spare", pts(h.floor())),
                _ => "room".into(),
            };
        }
        let why: Vec<String> = self
            .reasons
            .iter()
            .map(|r| match (r.as_str(), self.headroom) {
                ("pace", Some(h)) => format!("pace {} past the line", pts((-h).ceil())),
                (r, _) => r.replace('_', " "),
            })
            .collect();
        if why.is_empty() {
            return "no room".into();
        }
        format!("no room: {}", why.join(", "))
    }
}

/// The source series by source, keyed by metric name, and the age in seconds of the textfile
/// they came from (None when the age series is missing). The room reasons, the kind and the parent
/// pool are labels, so they are collected apart.
pub struct Accounts<'a> {
    pub by: BTreeMap<&'a str, BTreeMap<&'a str, f64>>,
    pub reasons: BTreeMap<&'a str, Vec<String>>,
    pub kinds: BTreeMap<&'a str, &'a str>,
    pub parents: BTreeMap<&'a str, &'a str>,
    pub age: Option<f64>,
}

/// claude-acct's textfile, however old, plus one series for its age (`claude_account_textfile_age_seconds`,
/// no account label, the oldest file when a second host exposes one) so a surface says "stale" past `burn::STALE_AFTER_SECS` instead of showing
/// nothing; no `max without`, which would drop the metric names the table reads. An empty
/// answer makes the table say no data.
pub(crate) const ACCOUNTS: &str = r#"{__name__=~"claude_account_.+"} or label_replace(max(time() - node_textfile_mtime_seconds{file=~".*claude_acct.prom"}), "__name__", "claude_account_textfile_age_seconds", "", "")"#;

/// What a surface says in place of an account's figures when the textfile is not fresh.
pub const STALE_NOTE: &str = "stale, claude-acct's textfile is not fresh (timer claude-acct-usage)";

/// A textfile older than this is not read (claude-acct's timer runs every 15 minutes).
pub const STALE_AFTER_SECS: f64 = 3600.0;

impl<'a> Accounts<'a> {
    pub fn read(series: &'a [Series]) -> Self {
        let mut a = Accounts {
            by: BTreeMap::new(),
            reasons: BTreeMap::new(),
            kinds: BTreeMap::new(),
            parents: BTreeMap::new(),
            age: None,
        };
        for s in series {
            let key = s.label("__name__").trim_start_matches("claude_account_");
            let Some(v) = s.value else { continue };
            let acc = s.label("account");
            if !acc.is_empty() && !s.label("kind").is_empty() {
                a.kinds.insert(acc, s.label("kind"));
            }
            match (key, acc) {
                (AGE_KEY, _) => a.age = Some(v),
                (_, "") => {}
                ("parent", acc) => {
                    a.parents.insert(acc, s.label("parent"));
                }
                ("room_reason", acc) => a
                    .reasons
                    .entry(acc)
                    .or_default()
                    .push(s.label("reason").to_string()),
                (_, acc) => {
                    a.by.entry(acc).or_default().insert(key, v);
                }
            }
        }
        a
    }

    /// The textfile is older than an hour, or Prometheus has no age for it: what it says cannot
    /// be shown as what is true now.
    pub fn stale(&self) -> bool {
        self.age.is_none_or(|age| age >= STALE_AFTER_SECS)
    }

    /// The account's published verdict; None when it has not published one (unreadable, or an
    /// older textfile).
    pub fn room(&self, account: &str) -> Option<Room> {
        let ok = self.by.get(account)?.get("room")?;
        let reasons = self
            .reasons
            .get(account)
            .into_iter()
            .flatten()
            .filter(|r| *r != "ok")
            .cloned()
            .collect();
        let headroom = self.by[account].get("room_headroom_points").copied();
        Some(Room::new(*ok == 1.0, reasons, headroom))
    }
}

/// The metric name of the textfile's age, after the `claude_account_` prefix.
pub const AGE_KEY: &str = "textfile_age_seconds";

/// What an idle row says: a Claude account's token refreshes on launch; any other source has had
/// no usage read yet.
pub fn idle_note(kind: &str) -> &'static str {
    if kind == DEFAULT_KIND {
        "idle, token refreshes on launch"
    } else {
        "no usage read yet"
    }
}

/// What a source's kind is when its textfile carries no `kind` label (one written before sources).
pub const DEFAULT_KIND: &str = "claude";

/// One source's row: a Claude account, the Codex plan, a gateway key or the Lazer pool.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Account {
    pub name: String,
    /// claude-acct's kind: `claude`, `codex`, `litellm-key` or `litellm-team`.
    pub kind: String,
    /// A dollar budget, which has no pace line, so its burn, keeps and back-on-pace cells say
    /// nothing. False by default, like a textfile written before sources: a Claude account.
    pub unpaced: bool,
    /// The last percent of the window kept for the human.
    pub reserve: Option<f64>,
    /// A dollar budget: spent this period and its cap.
    pub usd_used: Option<f64>,
    pub usd_budget: Option<f64>,
    /// The pool this key spends inside; it has room only when the pool does.
    pub parent: Option<String>,
    /// `parent` is itself a row, so this one is listed in the fold under it. Set by `ordered`.
    pub nested: bool,
    /// The USED cell both surfaces print: `53%`, or `81% $81/$100` for a dollar budget.
    pub used_text: String,
    /// `ok`, `unreadable` (claude-acct could not read its usage), `idle` (no usage yet) or
    /// `stale` (its textfile is not fresh).
    pub state: &'static str,
    /// claude-acct's verdict on an automatic start.
    pub room: Option<Room>,
    pub live: u32,
    pub used: Option<f64>,
    pub gone: Option<f64>,
    /// Points of the weekly limit an hour its live sessions burn.
    pub burn: f64,
    /// Points an hour the rest of the week can carry, landing at 100% on the reset.
    pub sustain: Option<f64>,
    /// `burn / sustain`, when there is something left to carry it.
    pub over: Option<f64>,
    /// Epoch seconds the account is back on pace if it spends nothing; None is after the reset.
    pub idle_at: Option<i64>,
    /// The same at this burn; None is after the reset.
    pub burn_at: Option<i64>,
    pub run_out: Option<i64>,
    pub resets: Option<i64>,
    /// The 5-hour window: percent used and when it resets.
    pub five_hour: Option<f64>,
    pub five_hour_resets: Option<i64>,
    /// What the account's sessions cost at list price over the last 24 hours.
    pub cost_24h: Option<f64>,
}

impl Account {
    /// Burning faster than the rest of its week can carry.
    pub fn is_over(&self) -> bool {
        self.sustain.is_some_and(|s| self.burn > s)
    }

    /// claude-acct publishes the time it is back on pace as now when it already is, so the
    /// verdict is read off the series and not derived again from used and gone.
    pub fn is_ahead(&self, now: i64) -> bool {
        !self.idle_at.is_some_and(|t| t <= now)
    }

    /// A back-on-pace cell: `on pace` when it already is, the time, or `after reset` when the
    /// reset puts it on pace first. The surface words the time.
    pub fn on_pace(&self, at: Option<i64>, now: i64, time: &dyn Fn(i64) -> String) -> String {
        match at {
            Some(t) if t <= now => "on pace".into(),
            Some(t) => time(t),
            None => "after reset".into(),
        }
    }
}

/// The accounts added up.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Fleet {
    pub live: u32,
    pub burn: f64,
    pub sustain: f64,
    pub over: Option<f64>,
    /// Points an hour one session burns.
    pub rate: Option<f64>,
    /// Sessions the weeks can carry at that rate.
    pub carries: Option<u32>,
}

/// Dispatch starts, counted from log.md.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Drip {
    pub hour: u32,
    pub day: u32,
    /// Why dispatch is held (headroom's `held`, only when it names a `held_kind`), shown as a badge to Sessions.
    pub held: Option<String>,
}

/// When the accounts ahead of their week are back on pace.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Pace {
    /// No account is ahead of its week.
    pub on_pace: bool,
    /// At this burn: each account that gets there before the reset, earliest first.
    pub at_burn: Vec<(String, i64)>,
    /// If idle: when the last account that gets there before the reset does.
    pub idle_all_by: Option<i64>,
    /// If idle, some accounts are not on pace until after the reset.
    pub idle_rest_after_reset: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Burn {
    pub at: i64,
    /// The headline and the drip, worded here so both surfaces print the same.
    pub head: String,
    pub drip_line: String,
    /// `bad` when the fleet is over, `warn` when one account is, no row has room or none can
    /// be read, `ok`, or `none` with no data.
    pub level: &'static str,
    /// Set when the textfile is not fresh: every figure below is then old, and the surfaces say so.
    pub stale: Option<&'static str>,
    /// Every source, in reading order (`ordered`); the surfaces list the `nested` ones in the fold.
    pub accounts: Vec<Account>,
    /// The fold under the pool row; None when no source is nested.
    pub keys: Option<Keys>,
    pub fleet: Fleet,
    pub drip: Drip,
    pub pace: Pace,
    /// What each term on the section means, in the order the surfaces print it.
    pub legend: &'static [(&'static str, &'static str)],
}

/// The Burn section's terms, defined once for both surfaces.
pub const LEGEND: &[(&str, &str)] = &[
    ("pts/h", "points of a weekly limit an hour"),
    (
        "BAR",
        "the fill is the share used, the tick the share of the week gone",
    ),
    ("GONE", "the share of the week gone"),
    ("BURN/H", "the last 6h rate of its live sessions"),
    (
        "KEEPS/H",
        "what the rest of the week can carry to the reset",
    ),
    (
        "ROOM",
        "claude-acct's answer on an automatic start, and why not",
    ),
    ("AT BURN", "when it is back on pace at this burn"),
    ("IF IDLE", "when it is back on pace with nothing live"),
    ("$24H", "the list-price estimate, for scale"),
];

/// The keys inside a pool, which draw on its money and so are not sources beside it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Keys {
    /// `3 in lazer, 0 live, tightest glm 96%`, worded here so both surfaces print the same.
    pub head: String,
    /// `warn` when a key's usage is unreadable or it refuses while its pool has room, which only
    /// the fold can show, so it starts open; `ok` otherwise.
    pub level: &'static str,
}

/// The sources in reading order: Claude accounts, the Codex plan, the pools, by name inside each,
/// each key right after its pool. A key whose pool is not a row stays at the top level.
fn ordered(mut accounts: Vec<Account>) -> Vec<Account> {
    let kinds: BTreeMap<String, String> = accounts
        .iter()
        .map(|a| (a.name.clone(), a.kind.clone()))
        .collect();
    // Only a row with no pool above it can hold keys, so a chain or a cycle keeps its rows visible.
    let roots: BTreeSet<String> = accounts
        .iter()
        .filter(|a| a.parent.as_ref().is_none_or(|p| *p == a.name))
        .map(|a| a.name.clone())
        .collect();
    for a in &mut accounts {
        a.nested = a
            .parent
            .as_ref()
            .is_some_and(|p| *p != a.name && roots.contains(p));
    }
    accounts.sort_by_cached_key(|a| {
        let top = match &a.parent {
            Some(p) if a.nested => p.clone(),
            _ => a.name.clone(),
        };
        let rank = match kinds[&top].as_str() {
            DEFAULT_KIND => 0,
            "codex" => 1,
            "litellm-team" => 2,
            _ => 3,
        };
        (rank, top, a.nested, a.name.clone())
    });
    accounts
}

fn keys_fold(accounts: &[Account]) -> Option<Keys> {
    let keys: Vec<&Account> = accounts.iter().filter(|a| a.nested).collect();
    if keys.is_empty() {
        return None;
    }
    let pool_has_room = |a: &Account| {
        accounts
            .iter()
            .find(|p| Some(&p.name) == a.parent.as_ref())
            .and_then(|p| p.room.as_ref())
            .is_some_and(|r| r.ok)
    };
    let alone = keys.iter().any(|a| {
        a.state == "unreadable" || (a.room.as_ref().is_some_and(|r| !r.ok) && pool_has_room(a))
    });
    let pools: BTreeSet<&str> = keys.iter().filter_map(|a| a.parent.as_deref()).collect();
    let tightest = keys
        .iter()
        .filter_map(|a| a.used.map(|u| (u, a)))
        .max_by(|x, y| x.0.total_cmp(&y.0))
        .map_or(String::new(), |(u, a)| {
            format!(", tightest {} {}%", a.name, u.floor())
        });
    Some(Keys {
        head: format!(
            "{} in {}, {} live{tightest}",
            keys.len(),
            pools.into_iter().collect::<Vec<_>>().join(", "),
            keys.iter().map(|a| a.live).sum::<u32>()
        ),
        level: if alone { "warn" } else { "ok" },
    })
}

/// `53%`, `81% $81/$100` with a dollar budget, `-` with no figure.
fn used_text(used: Option<f64>, usd: Option<f64>, budget: Option<f64>) -> String {
    let pct = used.map_or("-".to_string(), |u| format!("{}%", u.floor()));
    match (usd, budget) {
        (Some(u), Some(b)) => format!("{pct} ${u:.0}/${b:.0}"),
        _ => pct,
    }
}

fn account(name: &str, read: &Accounts, stale: bool) -> Account {
    let a = &read.by[name];
    let room = read.room(name);
    let get = |k: &str| a.get(k).copied();
    let epoch = |k: &str| get(k).map(|v| v as i64);
    let used = get("week_used_percent");
    let state = if stale {
        "stale"
    } else if get("read_ok") == Some(0.0) {
        "unreadable"
    } else if used.is_none() {
        "idle"
    } else {
        "ok"
    };
    let burn = get("burn_points_per_hour").unwrap_or(0.0);
    let sustain = get("sustain_points_per_hour");
    let (usd_used, usd_budget) = (get("usd_used"), get("usd_budget"));
    Account {
        name: name.into(),
        kind: read.kinds.get(name).unwrap_or(&DEFAULT_KIND).to_string(),
        // absent on a textfile written before sources, which held Claude accounts only
        unpaced: get("paced") == Some(0.0),
        reserve: get("reserve_percent"),
        usd_used,
        usd_budget,
        parent: read.parents.get(name).map(|p| p.to_string()),
        nested: false,
        used_text: used_text(used, usd_used, usd_budget),
        state,
        room,
        live: get("live_sessions").unwrap_or(0.0) as u32,
        used,
        gone: get("week_gone_percent"),
        burn,
        sustain,
        over: sustain.filter(|s| *s > 0.0).map(|s| burn / s),
        idle_at: epoch("on_pace_idle_timestamp_seconds"),
        burn_at: epoch("on_pace_burn_timestamp_seconds"),
        run_out: epoch("run_out_timestamp_seconds"),
        resets: epoch("resets_timestamp_seconds"),
        five_hour: get("five_hour_percent"),
        five_hour_resets: epoch("five_hour_resets_timestamp_seconds"),
        cost_24h: get("cost_24h_usd"),
    }
}

/// The section from claude-acct's series (fresh ones only; none is "no data") and the drip.
pub fn build(series: &[Series], rate: Option<f64>, drip: Drip, at: i64) -> Burn {
    let read = Accounts::read(series);
    let stale = read.stale();
    let accounts = ordered(read.by.keys().map(|n| account(n, &read, stale)).collect());
    let keys = keys_fold(&accounts);
    // Burn and sustain sum over the same accounts: an unreadable or idle one has neither, and
    // one with no sustain (its week is spent or past its reset) would otherwise add burn to
    // the OVER ratio with nothing on the other side.
    let counted: Vec<&Account> = accounts
        .iter()
        .filter(|a| a.state == "ok" && a.sustain.is_some())
        .collect();
    let burn: f64 = counted.iter().map(|a| a.burn).sum();
    let sustain: f64 = counted.iter().filter_map(|a| a.sustain).sum();
    let rate = rate.filter(|r| *r > 0.0);
    let fleet = Fleet {
        live: accounts.iter().map(|a| a.live).sum(),
        burn,
        sustain,
        over: (sustain > 0.0).then(|| burn / sustain),
        rate,
        carries: rate.map(|r| (sustain / r).floor() as u32),
    };
    let level = if accounts.is_empty() {
        "none"
    } else if counted.is_empty() {
        // Accounts exist but none can be read (or the textfile is stale): a quiet fleet is not what this means.
        "warn"
    } else if burn > sustain {
        "bad"
    } else if accounts.iter().any(Account::is_over)
        || matches!(no_room(&accounts), (n, of) if of > 0 && n == of)
    {
        "warn"
    } else {
        "ok"
    };
    let mut b = Burn {
        at,
        stale: stale.then_some(STALE_NOTE),
        level,
        accounts,
        keys,
        fleet,
        drip,
        legend: LEGEND,
        ..Burn::default()
    };
    b.head = b.head_text();
    b.drip_line = format!("{} started in 1h, {} in 24h", b.drip.hour, b.drip.day);
    b.pace = b.pace_of();
    b
}

/// The rows' own verdict, so the headline cannot read green while every row refuses: the
/// readable sources (not the keys in a pool) that say no room, and how many have a verdict.
/// An unreadable row says so in its own state, so it is not counted as a refusal here.
fn no_room(accounts: &[Account]) -> (usize, usize) {
    let judged: Vec<&Room> = accounts
        .iter()
        .filter(|a| !a.nested && a.state == "ok")
        .filter_map(|a| a.room.as_ref())
        .collect();
    (judged.iter().filter(|r| !r.ok).count(), judged.len())
}

impl Burn {
    /// The headline: burn against what the weeks carry, and the sessions going.
    fn head_text(&self) -> String {
        if let Some(note) = self.stale {
            return note.into();
        }
        let f = &self.fleet;
        let ratio = f.over.map_or(String::new(), |o| {
            format!(
                ", {o:.1}x{}",
                if self.level == "bad" { " OVER" } else { "" }
            )
        });
        let carries = f
            .carries
            .map_or(String::new(), |n| format!(", carries ~{n}"));
        let room = match no_room(&self.accounts) {
            (0, _) => String::new(),
            (n, of) if n == of => ", no room on any".into(),
            (n, of) => format!(", no room on {n} of {of}"),
        };
        format!(
            "{:.1} pts/h vs {:.1} sustainable{ratio}{room}, {} live{carries}",
            f.burn, f.sustain, f.live
        )
    }

    fn pace_of(&self) -> Pace {
        let ahead: Vec<&Account> = self
            .accounts
            .iter()
            .filter(|a| a.state == "ok" && !a.unpaced && a.is_ahead(self.at))
            .collect();
        let mut at_burn: Vec<(String, i64)> = ahead
            .iter()
            .filter_map(|a| a.burn_at.map(|t| (a.name.clone(), t)))
            .collect();
        at_burn.sort_by_key(|(_, t)| *t);
        let idle: Vec<i64> = ahead.iter().filter_map(|a| a.idle_at).collect();
        Pace {
            on_pace: ahead.is_empty(),
            at_burn,
            idle_all_by: idle.iter().max().copied(),
            idle_rest_after_reset: idle.len() < ahead.len(),
        }
    }

    /// The pace as a sentence; the table has each account's own times. `time` words an epoch
    /// the way the surface does.
    pub fn pace_text(&self, time: &dyn Fn(i64) -> String) -> String {
        let p = &self.pace;
        if self.stale.is_some() {
            return "unknown, the figures are stale".into();
        }
        if p.on_pace {
            return "every source is on pace".into();
        }
        let burn = if p.at_burn.is_empty() {
            "not before the reset".to_string()
        } else {
            p.at_burn
                .iter()
                .map(|(n, t)| format!("{n} {}", time(*t)))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let rest = if p.idle_rest_after_reset {
            ", the rest after the reset"
        } else {
            ""
        };
        let idle = p.idle_all_by.map_or(String::new(), |t| {
            format!("; if idle: all by {}{rest}", time(t))
        });
        format!("at this burn: {burn}{idle}")
    }
}

/// Dispatch starts in the last hour and day from log.md's text (`- YYYY-MM-DD HH:MM started ...`).
pub fn drip(log: &str, at: i64, held: Option<String>) -> Drip {
    let started = |since: i64| {
        crate::fleet::log_counts(log, &crate::fleet::local_minute(since))
            .get("started")
            .copied()
            .unwrap_or(0)
    };
    Drip {
        hour: started(at - 3600),
        day: started(at - 24 * 3600),
        held,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn series(account: &str, name: &str, v: f64) -> Series {
        Series {
            labels: [
                ("__name__".to_string(), format!("claude_account_{name}")),
                ("account".to_string(), account.to_string()),
            ]
            .into(),
            value: Some(v),
            points: vec![],
        }
    }

    /// The numbers of 2026-11-06 ~15:00 (plan fuzzy-scribbling-sky.md): three accounts, 39 live.
    fn fixture() -> Vec<Series> {
        let mut out = vec![];
        for (n, live, used, gone, burn, sustain) in [
            ("main", 13.0, 33.0, 12.0, 1.51, 0.45),
            ("alt", 9.0, 55.0, 25.0, 1.04, 0.36),
            ("bnb", 17.0, 7.0, 1.0, 1.97, 0.56),
        ] {
            for (k, v) in [
                ("live_sessions", live),
                ("week_used_percent", used),
                ("week_gone_percent", gone),
                ("burn_points_per_hour", burn),
                ("sustain_points_per_hour", sustain),
                ("on_pace_idle_timestamp_seconds", (NOW + 3600) as f64),
            ] {
                out.push(series(n, k, v));
            }
        }
        out.push(age(120.0));
        out
    }

    /// The fixture with its textfile age replaced.
    fn aged(secs: f64) -> Vec<Series> {
        let mut s = fixture();
        s.retain(|x| !x.label("__name__").ends_with(AGE_KEY));
        s.push(age(secs));
        s
    }

    fn quiet() -> Drip {
        Drip {
            hour: 15,
            day: 349,
            held: Some("fleet-assess says HOLD".into()),
        }
    }

    #[test]
    fn the_fixture_sums_to_the_fleet_line_and_is_over() {
        let b = build(&fixture(), Some(4.52 / 39.0), quiet(), NOW);
        assert_eq!(b.fleet.live, 39);
        assert!((b.fleet.burn - 4.52).abs() < 1e-9);
        assert!((b.fleet.sustain - 1.37).abs() < 1e-9);
        assert!((b.fleet.over.unwrap() - 3.3).abs() < 0.01);
        assert_eq!(
            b.fleet.carries,
            Some(11),
            "floor, as claude-acct's fleet line"
        );
        assert_eq!(b.level, "bad");
        assert_eq!(
            b.head,
            "4.5 pts/h vs 1.4 sustainable, 3.3x OVER, 39 live, carries ~11"
        );
        assert_eq!(b.drip_line, "15 started in 1h, 349 in 24h");
    }

    #[test]
    fn back_on_pace_says_when_idle_gets_there_and_when_burn_never_does() {
        let b = build(&fixture(), Some(0.1), quiet(), NOW);
        let t = |t: i64| format!("t{}", t - NOW);
        assert_eq!(
            b.pace_text(&t),
            "at this burn: not before the reset; if idle: all by t3600"
        );
        let mut s = fixture();
        s.push(series(
            "alt",
            "on_pace_burn_timestamp_seconds",
            (NOW + 60) as f64,
        ));
        assert!(build(&s, None, quiet(), NOW)
            .pace_text(&t)
            .starts_with("at this burn: alt t60;"));
    }

    #[test]
    fn one_account_over_is_amber_and_a_fleet_within_its_weeks_is_green() {
        let mut s = fixture();
        for x in &mut s {
            if x.label("__name__").ends_with("burn_points_per_hour") {
                x.value = Some(x.value.unwrap() / 10.0);
            }
        }
        assert_eq!(build(&s, None, quiet(), NOW).level, "ok");
        // alt alone burns above what its week carries; the fleet still fits.
        s.push(series("alt", "burn_points_per_hour", 0.5));
        let b = build(&s, None, quiet(), NOW);
        assert_eq!(b.level, "warn", "{b:?}");
    }

    #[test]
    fn the_headline_says_the_rows_no_room_so_a_fleet_under_its_weeks_is_not_green() {
        let mut s = fixture();
        for x in &mut s {
            if x.label("__name__").ends_with("burn_points_per_hour") {
                x.value = Some(x.value.unwrap() / 10.0);
            }
        }
        let with = |rooms: [f64; 3]| {
            let mut s = s.clone();
            for (n, ok) in ["main", "alt", "bnb"].into_iter().zip(rooms) {
                s.push(series(n, "room", ok));
            }
            build(&s, None, quiet(), NOW)
        };
        let all = with([0.0, 0.0, 0.0]);
        assert_eq!(
            all.head,
            "0.5 pts/h vs 1.4 sustainable, 0.3x, no room on any, 39 live"
        );
        assert_eq!(all.level, "warn");
        // a row refusing for its own reason is the row's news: the head says it, the section stays folded
        let some = with([0.0, 1.0, 0.0]);
        assert!(some.head.contains(", no room on 2 of 3,"), "{}", some.head);
        assert_eq!(some.level, "ok");
        // negative control: every row has room, so the headline adds nothing and stays green
        let roomy = with([1.0, 1.0, 1.0]);
        assert!(!roomy.head.contains("no room"), "{}", roomy.head);
        assert_eq!(roomy.level, "ok");
        assert_eq!(roomy.legend, LEGEND);
    }

    #[test]
    fn an_unreadable_account_is_listed_but_not_counted() {
        let mut s = fixture();
        s.push(series("old", "read_ok", 0.0));
        s.push(series("old", "live_sessions", 2.0));
        let b = build(&s, None, quiet(), NOW);
        let old = b.accounts.iter().find(|a| a.name == "old").unwrap();
        assert_eq!(old.state, "unreadable");
        assert!((b.fleet.burn - 4.52).abs() < 1e-9, "its burn is not summed");
        assert_eq!(b.fleet.live, 41, "its sessions are live all the same");
        // its own state says unreadable, so it is not one more "no room" in the head
        let mut s2 = s.clone();
        s2.push(series("old", "room", 0.0));
        assert!(!build(&s2, None, quiet(), NOW).head.contains("no room"));
    }

    #[test]
    fn an_account_with_no_sustain_adds_no_burn_to_the_ratio() {
        let mut s = fixture();
        s.push(series("spent", "week_used_percent", 100.0));
        s.push(series("spent", "burn_points_per_hour", 3.0));
        let b = build(&s, None, quiet(), NOW);
        assert!((b.fleet.burn - 4.52).abs() < 1e-9, "{:?}", b.fleet);
        assert!((b.fleet.sustain - 1.37).abs() < 1e-9);
    }

    #[test]
    fn accounts_that_cannot_be_read_are_not_a_green_fleet() {
        let b = build(&[series("old", "read_ok", 0.0)], None, Drip::default(), NOW);
        assert_eq!(b.level, "warn", "{b:?}");
    }

    #[test]
    fn no_series_is_no_data() {
        let b = build(&[], None, Drip::default(), NOW);
        assert_eq!(b.level, "none");
        assert!(b.accounts.is_empty());
    }

    #[test]
    fn every_account_on_pace_says_so() {
        let mut s = fixture();
        for x in &mut s {
            if x.label("__name__").ends_with("week_gone_percent") {
                x.value = Some(90.0);
            }
            if x.label("__name__")
                .ends_with("on_pace_idle_timestamp_seconds")
            {
                x.value = Some(NOW as f64);
            }
        }
        assert_eq!(
            build(&s, None, quiet(), NOW).pace_text(&|t| t.to_string()),
            "every source is on pace"
        );
    }

    #[test]
    fn the_drip_counts_started_lines_in_the_last_hour_and_day() {
        let at = 1_800_000_000;
        let stamp = |ago: i64| crate::fleet::local_minute(at - ago);
        let log = format!(
            "- {} started a for x\n- {} reaped b\n- {} started c for y\n- {} started d for z\n",
            stamp(600),
            stamp(900),
            stamp(7200),
            stamp(3 * 86400)
        );
        let d = drip(&log, at, None);
        assert_eq!((d.hour, d.day), (1, 2));
    }

    #[test]
    fn the_hold_badge_names_the_sessions_key() {
        assert_eq!(
            crate::layout::bar_digit("sessions")
                .map(|d| format!("{d} Sessions"))
                .as_deref(),
            Some(HOLD_BADGE)
        );
    }
    fn reason(account: &str, why: &str) -> Series {
        let mut s = series(account, "room_reason", 1.0);
        s.labels.insert("reason".into(), why.into());
        s
    }

    fn age(secs: f64) -> Series {
        let mut s = series("", "textfile_age_seconds", secs);
        s.labels.remove("account");
        s
    }

    /// Used 22 against gone 16 and slack 5 is 1 point past the line; 18 is inside it.
    #[test]
    fn the_published_verdict_is_printed_as_given_with_its_points() {
        let mut all = vec![];
        for (n, ok, headroom, why) in [
            ("a", 0.0, -1.0, "pace"),
            ("b", 1.0, 3.0, "ok"),
            ("c", 0.0, 12.0, "reserve"),
        ] {
            all.push(series(n, "week_used_percent", 20.0));
            all.push(series(n, "room", ok));
            all.push(series(n, "room_headroom_points", headroom));
            all.push(reason(n, why));
        }
        all.push(reason("c", "five_hour"));
        let b = build(&all, None, Drip::default(), NOW);
        let room = |n: &str| {
            b.accounts
                .iter()
                .find(|a| a.name == n)
                .unwrap()
                .room
                .clone()
                .unwrap()
        };
        assert_eq!(room("a").text, "no room: pace 1 point past the line");
        assert_eq!(room("b").text, "room, 3 points spare");
        assert!(room("b").reasons.is_empty(), "ok is not a refusal");
        assert_eq!(room("c").text, "no room: reserve, five hour");
    }

    #[test]
    fn an_account_with_no_published_verdict_has_none_rather_than_a_derived_one() {
        let b = build(&fixture(), None, Drip::default(), NOW);
        assert!(b.accounts.iter().all(|a| a.room.is_none()));
    }

    #[test]
    fn a_textfile_over_an_hour_old_is_stale_not_a_green_fleet() {
        let b = build(&aged(7300.0), None, Drip::default(), NOW);
        assert!(b.accounts.iter().all(|a| a.state == "stale"));
        assert_eq!(b.level, "warn");
        assert!(build(&fixture(), None, Drip::default(), NOW)
            .accounts
            .iter()
            .all(|a| a.state == "ok"));
    }

    /// A series as claude-acct writes it since sources: every one carries the source's kind.
    fn kinded(account: &str, kind: &str, name: &str, v: f64) -> Series {
        let mut s = series(account, name, v);
        s.labels.insert("kind".into(), kind.into());
        s
    }

    /// The 2026-11-07 sources beside the fixture's Claude accounts: Codex on its week, the pool
    /// and a key inside it on dollars.
    fn sources() -> Vec<Series> {
        let mut all = fixture();
        for (k, v) in [
            ("week_used_percent", 1.0),
            ("week_gone_percent", 16.0),
            ("sustain_points_per_hour", 0.71),
            ("burn_points_per_hour", 0.0),
            ("reserve_percent", 5.0),
            ("paced", 1.0),
            ("on_pace_idle_timestamp_seconds", (NOW - 60) as f64),
        ] {
            all.push(kinded("codex", "codex", k, v));
        }
        for (n, kind, used, usd, cap) in [
            ("lazer", "litellm-team", 62.9, 157.19, 250.0),
            ("reserve", "litellm-key", 81.4, 81.41, 100.0),
        ] {
            for (k, v) in [
                ("week_used_percent", used),
                ("usd_used", usd),
                ("usd_budget", cap),
                ("reserve_percent", 15.0),
                ("paced", 0.0),
            ] {
                all.push(kinded(n, kind, k, v));
            }
        }
        let mut parent = kinded("reserve", "litellm-key", "parent", 1.0);
        parent.labels.insert("parent".into(), "lazer".into());
        all.push(parent);
        all
    }

    #[test]
    fn an_idle_key_has_no_token_to_refresh() {
        assert_eq!(idle_note("claude"), "idle, token refreshes on launch");
        assert_eq!(idle_note("litellm-key"), "no usage read yet");
    }

    #[test]
    fn every_source_is_a_row_with_its_kind_dollars_reserve_and_pool() {
        let b = build(&sources(), None, Drip::default(), NOW);
        let row = |n: &str| b.accounts.iter().find(|a| a.name == n).unwrap().clone();
        assert_eq!(b.accounts.len(), 6);
        assert_eq!(
            row("main").kind,
            "claude",
            "no kind label is a Claude account"
        );
        assert!(!row("main").unpaced);
        assert_eq!(row("main").used_text, "33%");
        assert_eq!(row("codex").kind, "codex");
        assert_eq!(row("codex").reserve, Some(5.0));
        let r = row("reserve");
        assert_eq!((r.kind.as_str(), r.unpaced), ("litellm-key", true));
        assert_eq!(r.used_text, "81% $81/$100");
        assert_eq!(r.parent.as_deref(), Some("lazer"));
        assert_eq!(row("lazer").parent, None);
        assert_eq!(row("lazer").used_text, "62% $157/$250");
    }

    /// A key of `lazer`, or of a pool that is no row, with its own room verdict.
    fn key(name: &str, parent: &str, used: f64, ok: bool) -> Account {
        Account {
            name: name.into(),
            kind: "litellm-key".into(),
            parent: Some(parent.into()),
            used: Some(used),
            room: Some(Room {
                ok,
                ..Room::default()
            }),
            ..Account::default()
        }
    }

    fn pool(ok: bool) -> Account {
        Account {
            name: "lazer".into(),
            kind: "litellm-team".into(),
            room: Some(Room {
                ok,
                ..Room::default()
            }),
            ..Account::default()
        }
    }

    #[test]
    fn the_sources_read_claude_codex_then_the_pool_with_its_keys_after_it() {
        let b = build(&sources(), None, Drip::default(), NOW);
        let names: Vec<&str> = b.accounts.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(
            names,
            ["alt", "bnb", "main", "codex", "lazer", "reserve"],
            "alphabetical would put codex and lazer among the accounts"
        );
        let nested: Vec<&str> = b
            .accounts
            .iter()
            .filter(|a| a.nested)
            .map(|a| a.name.as_str())
            .collect();
        assert_eq!(nested, ["reserve"]);
        assert_eq!(
            b.keys.unwrap().head,
            "1 in lazer, 0 live, tightest reserve 81%"
        );
    }

    #[test]
    fn a_key_whose_pool_is_not_a_row_stays_at_the_top_level() {
        let rows = ordered(vec![pool(true), key("orphan", "gone", 10.0, true)]);
        assert!(rows.iter().all(|a| !a.nested), "{rows:?}");
        assert_eq!(keys_fold(&rows), None);
    }

    #[test]
    fn keys_that_name_each_other_stay_at_the_top_level() {
        let rows = ordered(vec![key("a", "b", 10.0, true), key("b", "a", 10.0, true)]);
        assert!(rows.iter().all(|a| !a.nested), "{rows:?}");
    }

    #[test]
    fn an_unreadable_key_opens_the_fold_even_with_its_pool_spent() {
        let unreadable = Account {
            state: "unreadable",
            room: None,
            ..key("glm", "lazer", 96.0, true)
        };
        let fold = keys_fold(&ordered(vec![pool(false), unreadable.clone()]));
        assert_eq!(fold.unwrap().level, "warn");
        // negative control: the same key, read, with nothing wrong
        let read = Account {
            state: "ok",
            ..unreadable
        };
        let fold = keys_fold(&ordered(vec![pool(false), read]));
        assert_eq!(fold.unwrap().level, "ok");
    }

    #[test]
    fn the_fold_is_warn_only_when_a_key_refuses_and_its_pool_has_room() {
        let level = |pool_ok, key_ok| {
            keys_fold(&ordered(vec![
                pool(pool_ok),
                key("glm", "lazer", 96.0, key_ok),
                key("eval", "lazer", 18.0, true),
            ]))
            .unwrap()
            .level
        };
        assert_eq!(level(true, false), "warn");
        // negative control: the pool row already says it is spent, so nothing is hidden
        assert_eq!(level(false, false), "ok");
        assert_eq!(level(true, true), "ok");
    }

    #[test]
    fn a_dollar_budget_adds_nothing_to_the_fleet_line_or_the_pace() {
        let b = build(&sources(), Some(0.116), Drip::default(), NOW);
        // the fixture's 4.52 against 1.37, plus Codex's 0 against 0.71; the keys carry no pace
        assert!((b.fleet.burn - 4.52).abs() < 1e-9);
        assert!((b.fleet.sustain - 2.08).abs() < 1e-9);
        // A dollar budget has no back-on-pace time; counted as ahead, it would be "on pace only
        // after the reset" and set this.
        assert!(!b.pace.idle_rest_after_reset);
        let only_keys: Vec<Series> = sources()
            .into_iter()
            .filter(|s| s.label("kind").starts_with("litellm") || s.label("account").is_empty())
            .collect();
        let k = build(&only_keys, None, Drip::default(), NOW);
        assert!(
            k.pace.on_pace,
            "dollar budgets alone are never behind a pace line"
        );
        assert_eq!(k.pace_text(&|t| t.to_string()), "every source is on pace");
    }
}
