//! The Costs tab's Burn section: how fast the weekly limits are being spent, how many sessions
//! are going, whether that is over what the weeks can carry, the dispatch drip, and when each
//! account is back on pace. `claude-acct` computes every pace figure and publishes it in its
//! textfile (`claude_account_*`, `claude_fleet_session_rate_points_per_hour`); this only sums
//! the per-account series and words them, so the hub TUI and agent-web print the same section
//! and no second formula exists. The drip is the `started` lines of fleet-dispatch's `log.md`.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::prom::Series;

/// The fleet's measured points of weekly limit one live session burns an hour (a 6h average).
pub const RATE_Q: &str = "claude_fleet_session_rate_points_per_hour";

/// Where the dispatch hold is explained (the Sessions header), as `SPEND_BADGE` names Costs.
pub const HOLD_BADGE: &str = "5 Sessions";

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
}

impl Room {
    /// The verdict in words: `room, 4 points spare`, or `no room: pace 20 points past the line`.
    pub fn text(&self) -> String {
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
        format!("no room: {}", why.join(", "))
    }
}

/// The account series by account, keyed by metric name, and the age in seconds of the textfile
/// they came from (None when the age series is missing). The room reasons are labels of one
/// metric, so they are collected apart.
pub struct Accounts<'a> {
    pub by: BTreeMap<&'a str, BTreeMap<&'a str, f64>>,
    pub reasons: BTreeMap<&'a str, Vec<String>>,
    pub age: Option<f64>,
}

/// A textfile older than this is not read (claude-acct's timer runs every 15 minutes).
pub const STALE_AFTER_SECS: f64 = 3600.0;

impl<'a> Accounts<'a> {
    pub fn read(series: &'a [Series]) -> Self {
        let mut a = Accounts {
            by: BTreeMap::new(),
            reasons: BTreeMap::new(),
            age: None,
        };
        for s in series {
            let key = s.label("__name__").trim_start_matches("claude_account_");
            let Some(v) = s.value else { continue };
            match (key, s.label("account")) {
                (AGE_KEY, _) => a.age = Some(v),
                (_, "") => {}
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

    /// The textfile is older than an hour: what it says is not what is true now.
    pub fn stale(&self) -> bool {
        self.age.is_some_and(|age| age >= STALE_AFTER_SECS)
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
        Some(Room {
            ok: *ok == 1.0,
            reasons,
            headroom: self.by[account].get("room_headroom_points").copied(),
        })
    }
}

/// The metric name of the textfile's age, after the `claude_account_` prefix.
pub const AGE_KEY: &str = "textfile_age_seconds";

/// One Claude account's row.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Account {
    pub name: String,
    /// `ok`, `unreadable` (claude-acct could not read its usage), `idle` (no usage yet) or
    /// `stale` (its textfile is over an hour old).
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
}

impl Account {
    /// Burning faster than the rest of its week can carry.
    pub fn is_over(&self) -> bool {
        self.sustain.is_some_and(|s| self.burn > s)
    }

    /// Used is ahead of the week gone, so it has pace to win back.
    pub fn is_ahead(&self) -> bool {
        matches!((self.used, self.gone), (Some(u), Some(g)) if u > g)
    }

    /// A back-on-pace cell: `on pace` when it already is, the time, or `after reset` when the
    /// reset puts it on pace first. The surface words the time.
    pub fn on_pace(&self, at: Option<i64>, now: i64, time: &dyn Fn(i64) -> String) -> String {
        match at {
            _ if !self.is_ahead() => "on pace".into(),
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
    /// `bad` when the fleet is over, `warn` when one account is or none can be read, `ok`, or
    /// `none` with no data.
    pub level: &'static str,
    pub accounts: Vec<Account>,
    pub fleet: Fleet,
    pub drip: Drip,
    pub pace: Pace,
}

fn account(name: &str, a: &BTreeMap<&str, f64>, room: Option<Room>, stale: bool) -> Account {
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
    Account {
        name: name.into(),
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
    }
}

/// The section from claude-acct's series (fresh ones only; none is "no data") and the drip.
pub fn build(series: &[Series], rate: Option<f64>, drip: Drip, at: i64) -> Burn {
    let read = Accounts::read(series);
    let stale = read.stale();
    let accounts: Vec<Account> = read
        .by
        .iter()
        .map(|(n, a)| account(n, a, read.room(n), stale))
        .collect();
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
    } else if accounts.iter().any(Account::is_over) {
        "warn"
    } else {
        "ok"
    };
    let mut b = Burn {
        at,
        level,
        accounts,
        fleet,
        drip,
        ..Burn::default()
    };
    b.head = b.head_text();
    b.drip_line = format!("{} started in 1h, {} in 24h", b.drip.hour, b.drip.day);
    b.pace = b.pace_of();
    b
}

impl Burn {
    /// The headline: burn against what the weeks carry, and the sessions going.
    fn head_text(&self) -> String {
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
        format!(
            "{:.1} pts/h vs {:.1} sustainable{ratio}, {} live{carries}",
            f.burn, f.sustain, f.live
        )
    }

    fn pace_of(&self) -> Pace {
        let ahead: Vec<&Account> = self
            .accounts
            .iter()
            .filter(|a| a.state == "ok" && a.is_ahead())
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
        if p.on_pace {
            return "every account is on pace".into();
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
        out
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
    fn an_unreadable_account_is_listed_but_not_counted() {
        let mut s = fixture();
        s.push(series("old", "read_ok", 0.0));
        s.push(series("old", "live_sessions", 2.0));
        let b = build(&s, None, quiet(), NOW);
        let old = b.accounts.iter().find(|a| a.name == "old").unwrap();
        assert_eq!(old.state, "unreadable");
        assert!((b.fleet.burn - 4.52).abs() < 1e-9, "its burn is not summed");
        assert_eq!(b.fleet.live, 41, "its sessions are live all the same");
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
        }
        assert_eq!(
            build(&s, None, quiet(), NOW).pace_text(&|t| t.to_string()),
            "every account is on pace"
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
        let at = crate::layout::TABS.iter().position(|t| t.id == "sessions");
        assert_eq!(
            at.map(|i| format!("{} Sessions", (i + 1) % 10)).as_deref(),
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
        assert_eq!(room("a").text(), "no room: pace 1 point past the line");
        assert_eq!(room("b").text(), "room, 3 points spare");
        assert!(room("b").reasons.is_empty(), "ok is not a refusal");
        assert_eq!(room("c").text(), "no room: reserve, five hour");
    }

    #[test]
    fn an_account_with_no_published_verdict_has_none_rather_than_a_derived_one() {
        let b = build(&fixture(), None, Drip::default(), NOW);
        assert!(b.accounts.iter().all(|a| a.room.is_none()));
    }

    #[test]
    fn a_textfile_over_an_hour_old_is_stale_not_a_green_fleet() {
        let mut all = fixture();
        all.push(age(7300.0));
        let b = build(&all, None, Drip::default(), NOW);
        assert!(b.accounts.iter().all(|a| a.state == "stale"));
        assert_eq!(b.level, "warn");
        let mut fresh = fixture();
        fresh.push(age(120.0));
        assert!(build(&fresh, None, Drip::default(), NOW)
            .accounts
            .iter()
            .all(|a| a.state == "ok"));
    }
}
