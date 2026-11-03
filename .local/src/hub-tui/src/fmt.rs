//! Numbers as the boards write them, and the palette.

use chrono::{Local, TimeZone};
use ratatui::style::{Color, Modifier, Style};

/// 45s, 36m, 2h28m, 3d4h, as `prom_dur` in `.local/lib/prom.sh`; - for no number.
pub fn dur(secs: f64) -> String {
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

/// A ratio as a whole percent, or - when the series is absent.
pub fn pct(v: Option<f64>) -> String {
    v.map_or("-".into(), |v| format!("{:.0}%", v * 100.0))
}

/// A unix time as the local clock: HH:MM today, else MM-DD HH:MM.
pub fn clock(ts: i64, now: i64) -> String {
    let (Some(t), Some(n)) = (
        Local.timestamp_opt(ts, 0).single(),
        Local.timestamp_opt(now, 0).single(),
    ) else {
        return "-".into();
    };
    if t.date_naive() == n.date_naive() {
        t.format("%H:%M").to_string()
    } else {
        t.format("%m-%d %H:%M").to_string()
    }
}

/// Styles from the 16-colour ANSI palette only, so the terminal's theme decides the shades.
/// `NO_COLOR` keeps bold and reverse, which are not colour.
#[derive(Clone, Copy, Debug, Default)]
pub struct Palette {
    pub no_color: bool,
}

impl Palette {
    pub fn from_env() -> Palette {
        Palette {
            no_color: std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()),
        }
    }
    fn c(&self, s: Style) -> Style {
        if self.no_color {
            Style::new().add_modifier(s.add_modifier)
        } else {
            s
        }
    }
    pub fn head(&self) -> Style {
        Style::new().add_modifier(Modifier::BOLD)
    }
    pub fn dim(&self) -> Style {
        self.c(Style::new().fg(Color::DarkGray))
    }
    pub fn warn(&self) -> Style {
        self.c(Style::new().fg(Color::Yellow))
    }
    pub fn bad(&self) -> Style {
        self.c(Style::new().fg(Color::Red).add_modifier(Modifier::BOLD))
    }
    pub fn good(&self) -> Style {
        self.c(Style::new().fg(Color::Green))
    }
    pub fn sel(&self) -> Style {
        Style::new().add_modifier(Modifier::REVERSED)
    }
    /// A `cc:*_status` value: 0 OK, 1 WARN, 2 RED, anything else NODATA (never OK). Black text
    /// on every chip: a theme may map red and green to light shades (batman maps both to
    /// yellows), so the word carries the state and the background only backs it up.
    pub fn status(&self, v: Option<f64>) -> (Style, &'static str) {
        let b = Style::new().add_modifier(Modifier::BOLD);
        match v.map(|v| v as i64) {
            Some(0) => (self.c(b.fg(Color::Black).bg(Color::Green)), "OK"),
            Some(1) => (self.c(b.fg(Color::Black).bg(Color::Yellow)), "WARN"),
            Some(2) => (self.c(b.fg(Color::Black).bg(Color::Red)), "RED"),
            _ => (self.c(b.fg(Color::Black).bg(Color::Magenta)), "NODATA"),
        }
    }
    /// A pass rate: red under 70%, amber under 90%.
    pub fn pass(&self, ratio: Option<f64>) -> Style {
        match ratio.map(|r| (r * 100.0).round()) {
            Some(p) if p < 70.0 => self.bad(),
            Some(p) if p < 90.0 => self.warn(),
            _ => Style::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_as_the_bash_boards_wrote_them() {
        assert_eq!(dur(45.9), "45s");
        assert_eq!(dur(2160.0), "36m");
        assert_eq!(dur(8880.0), "2h28m");
        assert_eq!(dur(3949200.0), "45d17h");
        assert_eq!(dur(f64::NAN), "-");
        assert_eq!(dur(-1.0), "-");
    }

    #[test]
    fn every_chip_is_black_text_on_its_colour() {
        // A theme may map red and green to light shades, so the text never takes the colour.
        let p = Palette::default();
        for v in [Some(0.0), Some(1.0), Some(2.0), None] {
            let (s, _) = p.status(v);
            assert_eq!(s.fg, Some(Color::Black), "{v:?}");
            assert!(s.bg.is_some_and(|b| b != Color::Black), "{v:?}");
        }
    }

    #[test]
    fn no_color_keeps_bold_and_drops_colour() {
        let p = Palette { no_color: true };
        let (s, w) = p.status(Some(2.0));
        assert_eq!(w, "RED");
        assert_eq!(s.bg, None);
        assert!(s.add_modifier.contains(Modifier::BOLD));
        assert_eq!(p.status(None).1, "NODATA");
    }
}
