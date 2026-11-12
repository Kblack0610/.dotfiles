//! Fit a table to a width: columns take their content's width and drop from the least
//! important end until the rest fit, the flex column takes what is left, and every line is
//! clipped with `~` (or, with `fit_wrapped`, the flex column wraps under itself).

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
    /// A suffix on one header, the sort's direction mark (`datatable::DataTable::mark`).
    pub mark: Option<(usize, &'static str)>,
}

/// Terminal columns, not chars: an emoji job name (CI's "🔨 Build") takes two.
pub fn len(s: &str) -> usize {
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
    /// Each header's text, the marked one with its suffix.
    fn heads(&self) -> Vec<String> {
        self.header
            .iter()
            .enumerate()
            .map(|(i, h)| match self.mark {
                Some((c, m)) if c == i => format!("{h}{m}"),
                _ => h.to_string(),
            })
            .collect()
    }

    fn head(&self, style: Style) -> Vec<Cell> {
        self.heads().into_iter().map(|h| cell(h, style)).collect()
    }

    /// The header line (in `head` style) and one line per row, fitted to `w` (0: no limit).
    pub fn fit(&self, w: usize, head: Style) -> Vec<Line<'static>> {
        let (on, wid) = self.layout(w, false);
        let header = self.head(head);
        // A flex column with columns after it takes the room they leave, clipped and padded
        // to it, so they line up; a last one just runs to the edge.
        let ncol = self.header.len();
        let room = self
            .flex
            .filter(|&f| on[f] && (f + 1..ncol).any(|j| on[j]))
            .map(|f| {
                let others: usize = (0..ncol)
                    .filter(|&j| on[j] && j != f)
                    .map(|j| wid[j] + GAP)
                    .sum();
                let n = match w {
                    0 => wid[f],
                    _ => wid[f].min(w.saturating_sub(others)).max(1),
                };
                (f, n)
            });
        std::iter::once(&header)
            .chain(&self.rows)
            .map(|r| {
                let flex = room.map(|(f, n)| {
                    let t = clip(r.get(f).map_or("", |c| c.text.as_str()), n);
                    let pad = n.saturating_sub(len(&t));
                    t + &" ".repeat(pad)
                });
                clip_line(self.line(r, &on, &wid, flex), w)
            })
            .collect()
    }

    /// As [`Table::fit`], but the flex column wraps at word breaks onto lines of its own
    /// instead of being clipped, so a row's whole text shows. Also returns the line each row
    /// starts on (the header is line 0).
    pub fn fit_wrapped(&self, w: usize, head: Style) -> (Vec<Line<'static>>, Vec<usize>) {
        let (on, wid) = self.layout(w, true);
        let header = self.head(head);
        let Some(f) = self.flex.filter(|f| on[*f] && w > 0) else {
            let mut out = vec![clip_line(self.line(&header, &on, &wid, None), w)];
            let mut starts = vec![];
            for r in &self.rows {
                starts.push(out.len());
                out.push(clip_line(self.line(r, &on, &wid, None), w));
            }
            return (out, starts);
        };
        // The flex column need not be the last: the columns before it set where its wrapped
        // lines start, and with columns after it, it pads to its room so they line up.
        let span = |cols: std::ops::Range<usize>| -> usize {
            cols.filter(|&j| on[j]).map(|j| wid[j] + GAP).sum()
        };
        let indent = span(0..f);
        let after = span(f + 1..self.header.len());
        let room = w.saturating_sub(indent + after).max(1);
        let pad = |t: String| {
            if after > 0 {
                let n = room.saturating_sub(len(&t));
                t + &" ".repeat(n)
            } else {
                t
            }
        };
        let head_text = header.get(f).map(|c| c.text.clone()).unwrap_or_default();
        let mut out = vec![clip_line(
            self.line(&header, &on, &wid, Some(pad(head_text))),
            w,
        )];
        let mut starts = vec![];
        for r in &self.rows {
            starts.push(out.len());
            let c = r.get(f).cloned().unwrap_or_default();
            // A word wider than the room (a path, a URL) breaks inside itself, so it never
            // pushes the columns after it out of line.
            let words: Vec<String> = c
                .text
                .split_whitespace()
                .flat_map(|word| chunks(word, room))
                .collect();
            let mut parts = wrap(&words, " ", room).into_iter();
            let first = parts.next().unwrap_or_default();
            out.push(clip_line(self.line(r, &on, &wid, Some(pad(first))), w));
            for more in parts {
                let l = Line::from(vec![
                    Span::raw(" ".repeat(indent)),
                    Span::styled(more, c.style),
                ]);
                out.push(clip_line(l, w));
            }
        }
        (out, starts)
    }

    /// Which columns show, and each one's width. A clipped flex column asks for its whole
    /// text, so keep columns after it drop to show more of it; a `wrapped` one shows its whole
    /// text anyway, so it asks only `flexmin` and a long cell cannot push the others off.
    fn layout(&self, w: usize, wrapped: bool) -> (Vec<bool>, Vec<usize>) {
        let ncol = self.header.len();
        let mut wid: Vec<usize> = self.heads().iter().map(|h| len(h)).collect();
        for r in &self.rows {
            for (j, c) in r.iter().enumerate().take(ncol) {
                wid[j] = wid[j].max(len(&c.text));
            }
        }
        for &(j, m) in &self.cap {
            wid[j] = wid[j].min(m);
        }
        let ask = |j: usize| {
            if wrapped && Some(j) == self.flex {
                self.flexmin
            } else {
                wid[j]
            }
        };
        let mut on = vec![false; ncol];
        let mut total: isize = -(GAP as isize);
        for &j in &self.keep {
            on[j] = true;
            total += (ask(j) + GAP) as isize;
        }
        let need = match self.flex {
            Some(f) if self.flexkeep && !(wrapped && self.keep.contains(&f)) => {
                (self.flexmin + GAP) as isize
            }
            _ => 0,
        };
        for &j in self.keep.iter().skip(1).rev() {
            if w == 0 || total + need <= w as isize {
                break;
            }
            on[j] = false;
            total -= (ask(j) + GAP) as isize;
        }
        if let Some(f) = self.flex {
            // The room the flex column gets is what the others leave, so its own width is not
            // counted against it.
            let rest = if on[f] {
                total - (ask(f) + GAP) as isize
            } else {
                total
            };
            on[f] = w == 0
                || self.flexkeep
                || w as isize - rest - GAP as isize >= self.flexmin as isize;
        }
        (on, wid)
    }

    /// One row's line, unclipped; `flex` replaces the flex column's text.
    fn line(&self, r: &[Cell], on: &[bool], wid: &[usize], flex: Option<String>) -> Line<'static> {
        let mut spans: Vec<Span<'static>> = vec![];
        let mut flex = flex;
        for j in (0..self.header.len()).filter(|&j| on[j]) {
            let empty = Cell::default();
            let c = r.get(j).unwrap_or(&empty);
            if !spans.is_empty() {
                spans.push(Span::raw(" ".repeat(GAP)));
            }
            if Some(j) == self.flex {
                let text = flex.take().unwrap_or_else(|| c.text.clone());
                spans.push(Span::styled(text, c.style));
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
        trim_end(spans)
    }
}

/// `s` cut into pieces of at most `n` columns.
fn chunks(s: &str, n: usize) -> Vec<String> {
    let mut out = vec![];
    let mut rest = s;
    while len(rest) > n {
        let mut head = take_cols(rest, n);
        if head.is_empty() {
            // A wide character in a one-column room: it goes alone, so the loop always moves.
            head = rest.chars().next().map(String::from).unwrap_or_default();
        }
        rest = &rest[head.len()..];
        out.push(head);
    }
    out.push(rest.to_string());
    out
}

/// Drop trailing blanks.
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

/// Items joined by `sep` into as few lines as fit in `w` (0: one line). An item wider than `w`
/// gets a line of its own and is clipped where it is drawn.
pub fn wrap<S: AsRef<str>>(items: &[S], sep: &str, w: usize) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for it in items.iter().map(AsRef::as_ref) {
        match out.last_mut() {
            Some(l) if w == 0 || len(l) + len(sep) + len(it) <= w => {
                l.push_str(sep);
                l.push_str(it);
            }
            _ => out.push(it.to_string()),
        }
    }
    out
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
        assert_eq!(chunks("🔨🔨a", 1), ["🔨", "🔨", "a"]);
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
    fn a_flex_column_in_keep_that_fits_is_not_hidden_by_its_own_width() {
        let mut tb = t(&[&["alpha", "7", "short note"]]);
        tb.keep = vec![0, 1, 2];
        assert_eq!(texts(&tb, 24), ["NAME   N  NOTE", "alpha  7  short note"]);
        assert_eq!(
            texts(&tb, 12),
            ["NAME   N", "alpha  7"],
            "still hides under flexmin"
        );
    }

    #[test]
    fn flexkeep_drops_keep_columns_to_keep_the_flex_column() {
        let mut tb = t(&[&["alpha", "7", "a long note"]]);
        tb.flexkeep = true;
        assert_eq!(texts(&tb, 13), ["NAME   NOTE", "alpha  a lon~"]);
    }

    #[test]
    fn a_flex_column_before_others_clips_and_pads_so_they_line_up() {
        let mut tb = t(&[&["alpha", "7", "a long note here"], &["b", "12", "short"]]);
        tb.header = vec!["NOTE", "NAME", "N"];
        tb.rows = tb
            .rows
            .into_iter()
            .map(|r| vec![r[2].clone(), r[0].clone(), r[1].clone()])
            .collect();
        (tb.keep, tb.flex, tb.flexkeep, tb.right) = (vec![1, 2], Some(0), true, vec![2]);
        assert_eq!(
            texts(&tb, 22),
            [
                "NOTE         NAME    N",
                "a long not~  alpha   7",
                "short        b      12"
            ]
        );
        // With room to spare, the note keeps its own width rather than the line's.
        assert_eq!(
            texts(&tb, 0),
            [
                "NOTE              NAME    N",
                "a long note here  alpha   7",
                "short             b      12"
            ]
        );
    }

    #[test]
    fn a_long_wrapped_flex_cell_does_not_push_the_other_columns_off() {
        let mut tb = t(&[&["alpha", "7", &"word ".repeat(40)]]);
        tb.keep = vec![0, 2, 1];
        tb.flexkeep = true;
        let (lines, _) = tb.fit_wrapped(30, Style::new());
        let out: Vec<String> = lines.iter().map(plain).collect();
        assert_eq!(out[0], "NAME   N  NOTE", "{out:?}");
        assert!(out.len() > 2 && out.iter().all(|l| len(l) <= 30 && !l.contains('~')));
        // Clipped, the same table still drops N to show more of the note.
        assert_eq!(texts(&tb, 30)[0], "NAME   NOTE");
    }

    #[test]
    fn wrap_breaks_between_items_never_inside_one() {
        let items: Vec<String> = ["nodes 3/3", "heartbeats 7/8", "lazer $1/$5"]
            .map(String::from)
            .to_vec();
        assert_eq!(
            wrap(&items, "  ", 0),
            ["nodes 3/3  heartbeats 7/8  lazer $1/$5"]
        );
        assert_eq!(
            wrap(&items, "  ", 26),
            ["nodes 3/3  heartbeats 7/8", "lazer $1/$5"]
        );
        assert_eq!(
            wrap(&items, "  ", 5),
            ["nodes 3/3", "heartbeats 7/8", "lazer $1/$5"]
        );
    }

    #[test]
    fn a_wrapped_flex_column_shows_its_whole_text_under_itself() {
        let mut tb = t(&[&["a", "1", "one two three four"], &["b", "2", "five"]]);
        tb.flexkeep = true;
        let (lines, starts) = tb.fit_wrapped(18, Style::new());
        let got: Vec<String> = lines.iter().map(plain).collect();
        assert_eq!(
            got,
            [
                "NAME  N  NOTE",
                "a     1  one two",
                "         three",
                "         four",
                "b     2  five"
            ]
        );
        assert_eq!(starts, [1, 4]);
        assert!(got.iter().all(|l| len(l) <= 18 && !l.contains('~')));
    }

    #[test]
    fn a_wrapped_flex_column_before_others_keeps_them_aligned() {
        let tb = Table {
            header: vec!["N", "NOTE", "ID"],
            rows: vec![vec!["1".into(), "one two three four".into(), "x-1".into()]],
            keep: vec![0, 1, 2],
            flex: Some(1),
            flexmin: 9,
            flexkeep: true,
            ..Default::default()
        };
        let (lines, _) = tb.fit_wrapped(17, Style::new());
        let got: Vec<String> = lines.iter().map(plain).collect();
        assert_eq!(
            got,
            [
                "N  NOTE       ID",
                "1  one two    x-1",
                "   three",
                "   four"
            ]
        );
        let mut long = tb;
        long.rows[0][1] = "see /a/very/long/path".into();
        let (lines, _) = long.fit_wrapped(17, Style::new());
        let got: Vec<String> = lines.iter().map(plain).collect();
        assert_eq!(
            got,
            [
                "N  NOTE       ID",
                "1  see        x-1",
                "   /a/very/l",
                "   ong/path"
            ]
        );
    }

    #[test]
    fn caps_clip_with_a_tilde() {
        let mut tb = t(&[&["unity-core-playground", "1", ""]]);
        tb.cap = vec![(0, 8)];
        assert_eq!(texts(&tb, 0)[1], "unity-c~  1");
    }
}
