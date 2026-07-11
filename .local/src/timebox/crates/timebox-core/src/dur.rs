//! Duration parsing + formatting. Hand-rolled to keep the dependency set minimal
//! (matching notes-cli's "few deps" ethos).

/// Parse a human duration into seconds. Accepts a single unit suffix `h`/`m`/`s`,
/// or a bare integer (interpreted as seconds): `"25m"`, `"1h"`, `"90s"`, `"1500"`.
pub fn parse_duration(s: &str) -> Result<u64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty duration".into());
    }
    let (num, mult): (&str, u64) = match s.chars().last().unwrap() {
        'h' | 'H' => (&s[..s.len() - 1], 3600),
        'm' | 'M' => (&s[..s.len() - 1], 60),
        's' | 'S' => (&s[..s.len() - 1], 1),
        c if c.is_ascii_digit() => (s, 1),
        other => return Err(format!("bad duration unit '{other}' (use h|m|s or a bare number)")),
    };
    let n: u64 = num
        .trim()
        .parse()
        .map_err(|_| format!("bad duration number '{num}'"))?;
    Ok(n * mult)
}

/// Format a non-negative second count as `M:SS` (under an hour) or `H:MM:SS`.
pub fn fmt_hms(secs: i64) -> String {
    let secs = secs.max(0);
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_units_and_bare() {
        assert_eq!(parse_duration("25m").unwrap(), 1500);
        assert_eq!(parse_duration("1h").unwrap(), 3600);
        assert_eq!(parse_duration("90s").unwrap(), 90);
        assert_eq!(parse_duration("1500").unwrap(), 1500);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_duration("").is_err());
        assert!(parse_duration("5x").is_err());
        assert!(parse_duration("mm").is_err());
    }

    #[test]
    fn formats_hms() {
        assert_eq!(fmt_hms(59), "0:59");
        assert_eq!(fmt_hms(90), "1:30");
        assert_eq!(fmt_hms(3661), "1:01:01");
        assert_eq!(fmt_hms(-5), "0:00");
    }
}
