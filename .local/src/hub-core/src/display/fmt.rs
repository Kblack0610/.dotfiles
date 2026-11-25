//! The one home of how a number reads: money, tokens, durations, ages and counts. Every surface
//! (agent-web through hub-core, the TUI, the panel's cards) calls these, so `$214` and `2h28m`
//! read the same everywhere; a copy elsewhere fails the `number-formatters` Owners row (`fact-owners check`).

/// Dollars as the views show them: cents under $100, whole dollars above. [`usd_est`] is the
/// second form, for an estimate, not a measured price.
pub fn usd(c: f64) -> String {
    if c >= 100.0 {
        format!("${c:.0}")
    } else {
        format!("${c:.2}")
    }
}

/// [`usd`], or `-` for a price nobody has: unknown, never $0.
pub fn usd_opt(c: Option<f64>) -> String {
    c.map_or("-".into(), usd)
}

/// Dollars at a size that does not claim more than an estimate knows: cents only under $10,
/// thousands separated.
pub fn usd_est(v: f64) -> String {
    if v < 10.0 {
        return format!("${v:.2}");
    }
    let digits = format!("{v:.0}");
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    format!("${out}")
}

/// A token count: 1.9B, 2.3M, 61M, 12k, 512; `-` for none.
pub fn tokens(n: Option<f64>) -> String {
    match n {
        None => "-".into(),
        Some(n) if n >= 1e9 => format!("{:.1}B", n / 1e9),
        Some(n) if n >= 1e7 => format!("{:.0}M", n / 1e6),
        Some(n) if n >= 1e6 => format!("{:.1}M", n / 1e6),
        Some(n) if n >= 1e3 => format!("{:.0}k", n / 1e3),
        Some(n) => format!("{n:.0}"),
    }
}

/// 45s, 36m, 2h28m, 3d4h, as `prom_dur` in `.local/lib/prom.sh`; `-` for no number.
pub fn dur_secs(secs: f64) -> String {
    if !secs.is_finite() || secs < 0.0 {
        return "-".into();
    }
    let s = secs as i64;
    match s {
        0..=59 => format!("{s}s"),
        60..=3599 => format!("{}m", s / 60),
        3600..=86399 => format!("{}h{:02}m", s / 3600, s % 3600 / 60),
        _ => format!("{}d{}h", s / 86400, s % 86400 / 3600),
    }
}

/// [`dur_secs`] of minutes; `-` for none.
pub fn dur_min(m: Option<i64>) -> String {
    match m {
        None => "-".into(),
        Some(m) if m < 60 => format!("{}m", m.max(0)),
        Some(m) => dur_secs(m as f64 * 60.0),
    }
}

/// Minutes as an age: [`dur_min`], and past two days `2.8d`, which says more than `67h`.
pub fn age_min(m: f64) -> String {
    if m >= 48.0 * 60.0 {
        format!("{:.1}d", m / (24.0 * 60.0))
    } else {
        dur_min(Some(m.round() as i64))
    }
}

/// How long since `since`, as [`dur_secs`]; `-` for none.
pub fn dur_since(since: Option<i64>, now: i64) -> String {
    since.map_or("-".into(), |t| dur_secs((now - t).max(0) as f64))
}

/// Minutes rounded to 45m or 3h, a share of an age, not a clock; `-` for none.
pub fn hours_min(m: i64) -> String {
    match m {
        ..=0 => "-".into(),
        1..=59 => format!("{m}m"),
        _ => format!("{}h", (m as f64 / 60.0).round() as i64),
    }
}

/// An age at a glance: minutes, then hours, then days.
pub fn age(secs: i64) -> String {
    match secs.max(0) {
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

/// The noun for `n`: `fix` for one, else its own plural (`fixes`), for text that puts words
/// between the number and the noun (`3 beta checks`).
pub fn noun<'a>(n: usize, one: &'a str, many: &'a str) -> &'a str {
    if n == 1 {
        one
    } else {
        many
    }
}

/// `1 fix`, `2 fixes`.
pub fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", noun(n, one, many))
}

/// `1 phase`, `3 phases`: a noun that takes an `s`.
pub fn counted(n: usize, unit: &str) -> String {
    plural(n, unit, &format!("{unit}s"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn money_reads_cents_then_whole_dollars() {
        assert_eq!(usd(6.1), "$6.10");
        assert_eq!(usd(214.4), "$214");
        assert_eq!(usd_opt(None), "-");
        assert_eq!(usd_est(9.5), "$9.50");
        assert_eq!(usd_est(12_345.0), "$12,345");
    }

    #[test]
    fn tokens_and_durations_read_short() {
        assert_eq!(tokens(Some(1.9e9)), "1.9B");
        assert_eq!(tokens(Some(61e6)), "61M");
        assert_eq!(tokens(Some(2.3e6)), "2.3M");
        assert_eq!(tokens(Some(12_000.0)), "12k");
        assert_eq!(tokens(Some(512.0)), "512");
        assert_eq!(tokens(None), "-");
        assert_eq!(dur_secs(45.9), "45s");
        assert_eq!(dur_secs(2160.0), "36m");
        assert_eq!(dur_secs(8880.0), "2h28m");
        assert_eq!(dur_secs(3949200.0), "45d17h");
        assert_eq!(dur_secs(f64::NAN), "-");
        assert_eq!(dur_secs(-1.0), "-");
        assert_eq!(dur_min(Some(150)), "2h30m");
        assert_eq!(dur_min(None), "-");
        assert_eq!(dur_min(Some(0)), "0m");
        assert_eq!(dur_min(Some(14)), "14m");
        assert_eq!(age(300), "5m");
        assert_eq!(age(7200), "2h");
        assert_eq!(age(3 * 86400), "3d");
    }

    #[test]
    fn a_count_takes_its_own_plural() {
        assert_eq!(plural(1, "fix", "fixes"), "1 fix");
        assert_eq!(plural(2, "fix", "fixes"), "2 fixes");
        assert_eq!(plural(0, "PR", "PRs"), "0 PRs");
    }
}
