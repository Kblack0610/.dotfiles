//! Fit a table to a width, as `.local/lib/table-fit.sh` does for the bash boards: columns
//! take their content's width and drop from the least important end until the rest fit, the
//! flex column (always the last) takes what is left, and every line is clipped with `~`.

use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const GAP: usize = 2;

#[derive(Clone, Debug, Default)]
pub struct Cell {
    pub text: String,
    pub style: Style,
}

impl<T: Into<String>> From<T> for Cell {
    fn from(t: T) -> Cell {
        Cell {
            text: t.into(),
            style: Style::new(),
        }
    }
}

pub fn cell(text: impl Into<String>, style: Style) -> Cell {
    Cell {
        text: text.into(),
        style,
    }
}

/// A table and how it narrows. Columns are 0-based.
#[derive(Default)]
pub struct Table {
    pub header: Vec<&'static str>,
    pub rows: Vec<Vec<Cell>>,
    /// Most important first; the first never drops.
    pub keep: Vec<usize>,
    pub flex: Option<usize>,
    pub flexmin: usize,
    /// The flex column never hides; keep columns drop from the end until it has `flexmin`.
    pub flexkeep: bool,
    pub right: Vec<usize>,
    /// (column, max width)
    pub cap: Vec<(usize, usize)>,
}

/// Terminal columns, not chars: an emoji job name (CI's "🔨 Build") takes two.
fn len(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// The longest start of `s` that fits in `n` columns.
fn take_cols(s: &str, n: usize) -> String {
    let mut used = 0;
    s.chars()
        .take_while(|c| {
            used += UnicodeWidthChar::width(*c).unwrap_or(0);
            used <= n
        })
        .collect()
}

fn clip(s: &str, w: usize) -> String {
    if w > 0 && len(s) > w {
        take_cols(s, w - 1) + "~"
    } else {
        s.to_string()
    }
}

/// Clip a styled line to `w` visible columns, the last one a `~` when anything was cut.
pub fn clip_line(line: Line<'static>, w: usize) -> Line<'static> {
    let total: usize = line.spans.iter().map(|s| len(&s.content)).sum();
    if w == 0 || total <= w {
        return line;
    }
    let mut left = w - 1;
    let mut spans = vec![];
    for s in line.spans {
        if left == 0 {
            break;
        }
        let n = len(&s.content);
        if n <= left {
            left -= n;
            spans.push(s);
        } else {
            spans.push(Span::styled(take_cols(&s.content, left), s.style));
            left = 0;
        }
    }
    spans.push(Span::raw("~"));
    Line {
        spans,
        style: line.style,
        alignment: line.alignment,
    }
}

impl Table {
    /// The header line (in `head` style) and one line per row, fitted to `w` (0: no limit).
    pub fn fit(&self, w: usize, head: Style) -> Vec<Line<'static>> {
        let ncol = self.header.len();
        let mut wid: Vec<usize> = self.header.iter().map(|h| len(h)).collect();
        for r in &self.rows {
            for (j, c) in r.iter().enumerate().take(ncol) {
                wid[j] = wid[j].max(len(&c.text));
            }
        }
        for &(j, m) in &self.cap {
            wid[j] = wid[j].min(m);
        }
        let mut on = vec![false; ncol];
        let mut total: isize = -(GAP as isize);
        for &j in &self.keep {
            on[j] = true;
            total += (wid[j] + GAP) as isize;
        }
        let need = match (self.flex, self.flexkeep) {
            (Some(_), true) => (self.flexmin + GAP) as isize,
            _ => 0,
        };
        for &j in self.keep.iter().skip(1).rev() {
            if w == 0 || total + need <= w as isize {
                break;
            }
            on[j] = false;
            total -= (wid[j] + GAP) as isize;
        }
        if let Some(f) = self.flex {
            on[f] = w == 0
                || self.flexkeep
                || w as isize - total - GAP as isize >= self.flexmin as isize;
        }
        let header: Vec<Cell> = self.header.iter().map(|h| cell(*h, head)).collect();
        std::iter::once(&header)
            .chain(&self.rows)
            .map(|r| {
                let mut spans: Vec<Span<'static>> = vec![];
                for j in (0..ncol).filter(|&j| on[j]) {
                    let empty = Cell::default();
                    let c = r.get(j).unwrap_or(&empty);
                    if !spans.is_empty() {
                        spans.push(Span::raw(" ".repeat(GAP)));
                    }
                    if Some(j) == self.flex {
                        spans.push(Span::styled(c.text.clone(), c.style));
                        continue;
                    }
                    let v = clip(&c.text, wid[j]);
                    let pad = " ".repeat(wid[j] - len(&v));
                    if self.right.contains(&j) {
                        spans.push(Span::raw(pad));
                        spans.push(Span::styled(v, c.style));
                    } else {
                        spans.push(Span::styled(v, c.style));
                        spans.push(Span::raw(pad));
                    }
                }
                clip_line(trim_end(spans), w)
            })
            .collect()
    }
}

/// Drop trailing blanks, as the bash fitter's `sub(/ +$/, "")`.
fn trim_end(mut spans: Vec<Span<'static>>) -> Line<'static> {
    while let Some(last) = spans.last_mut() {
        let t = last.content.trim_end().to_string();
        if t.is_empty() {
            spans.pop();
        } else {
            last.content = t.into();
            break;
        }
    }
    Line::from(spans)
}

/// A line's text, styles dropped.
pub fn plain(l: &Line) -> String {
    l.spans.iter().map(|s| s.content.as_ref()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wide_character_takes_two_columns() {
        let t = Table {
            header: vec!["JOB", "FOR"],
            rows: vec![
                vec!["🔨 Build".into(), "6m".into()],
                vec!["Checks".into(), "9m".into()],
            ],
            keep: vec![0, 1],
            right: vec![1],
            ..Default::default()
        };
        let out: Vec<String> = t.fit(0, Style::new()).iter().map(plain).collect();
        assert_eq!(out, ["JOB       FOR", "🔨 Build   6m", "Checks     9m"]);
        assert_eq!(plain(&clip_line(Line::raw("🔨 Build xyz"), 6)), "🔨 Bu~");
    }

    fn t(rows: &[&[&str]]) -> Table {
        Table {
            header: vec!["NAME", "N", "NOTE"],
            rows: rows
                .iter()
                .map(|r| r.iter().map(|c| Cell::from(*c)).collect())
                .collect(),
            keep: vec![0, 1],
            flex: Some(2),
            flexmin: 6,
            right: vec![1],
            ..Default::default()
        }
    }

    fn texts(t: &Table, w: usize) -> Vec<String> {
        t.fit(w, Style::new()).iter().map(plain).collect()
    }

    #[test]
    fn pads_right_aligns_and_trims() {
        assert_eq!(
            texts(&t(&[&["alpha", "7", "x"], &["b", "12", ""]]), 0),
            ["NAME    N  NOTE", "alpha   7  x", "b      12"]
        );
    }

    #[test]
    fn the_flex_column_hides_before_it_gets_too_narrow_and_keep_columns_drop_from_the_end() {
        let tb = t(&[&["alpha", "7", "a long note"]]);
        assert_eq!(texts(&tb, 18), ["NAME   N  NOTE", "alpha  7  a long ~"]);
        assert_eq!(
            texts(&tb, 12),
            ["NAME   N", "alpha  7"],
            "flex hides under flexmin"
        );
        assert_eq!(texts(&tb, 6), ["NAME", "alpha"], "N drops, NAME never");
    }

    #[test]
    fn flexkeep_drops_keep_columns_to_keep_the_flex_column() {
        let mut tb = t(&[&["alpha", "7", "a long note"]]);
        tb.flexkeep = true;
        assert_eq!(texts(&tb, 13), ["NAME   NOTE", "alpha  a lon~"]);
    }

    #[test]
    fn caps_clip_with_a_tilde() {
        let mut tb = t(&[&["unity-core-playground", "1", ""]]);
        tb.cap = vec![(0, 8)];
        assert_eq!(texts(&tb, 0)[1], "unity-c~  1");
    }
}
