//! The keys and status line every data table tab shares, over `hub_core::table::View`, which
//! alone decides what a query keeps and how a sort orders (docs/dashboards.md rule 7). agent-web
//! draws the same view from the same summary.
//!
//! `/` types the query (Enter applies, Esc drops the draft), `f` steps the state chip, `s` sorts by
//! the next column, `S` flips the direction, `x` clears the whole view. The selection is the
//! table's too: one cursor that moves, stays in range and goes to the top when the view changes.

use hub_core::links::Link;
use hub_core::table::{Dir, Row, View};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::fit::wrap;
use crate::fmt::Palette;

/// The page section that marks a selected row's line (Home, Alerts, Infra), only so the app can
/// keep it in view: the app takes it out of the sections `n`/`N` step through.
pub const ROW: &str = "row";

/// What a key did to the table.
#[derive(Debug, PartialEq, Eq)]
pub enum Took {
    /// Not a table key.
    No,
    /// Typed into the query; the view is unchanged until Enter.
    Typing,
    /// The view changed.
    View,
}

#[derive(Debug, Default)]
pub struct DataTable {
    pub view: View,
    /// The query being typed after `/`, applied on Enter, dropped on Esc.
    pub typing: Option<String>,
    /// The selected row, an index into the rows the view keeps.
    pub sel: usize,
    /// The first row drawn, so the selection stays in view.
    pub top: usize,
}

impl DataTable {
    /// Nothing typed and the view is the table's own: Esc at this point leaves the table.
    pub fn is_default(&self) -> bool {
        self.typing.is_none() && self.view.is_default()
    }

    /// Whether `code` is one of the shared keys, so a tab can route it here before the table
    /// has focus.
    pub fn owns(code: KeyCode) -> bool {
        matches!(code, KeyCode::Char('/' | 'f' | 's' | 'S' | 'x'))
    }

    /// The query, chip and sort back to the table's own, nothing typed, the selection at the top.
    pub fn clear(&mut self) {
        *self = DataTable::default();
    }

    /// One key, for an `R` table: what it did. A changed view puts the selection at the top.
    pub fn key<R: Row>(&mut self, code: KeyCode) -> Took {
        let took = self.take::<R>(code);
        if took == Took::View {
            self.sel = 0;
        }
        took
    }

    fn take<R: Row>(&mut self, code: KeyCode) -> Took {
        if let Some(t) = self.typing.as_mut() {
            match code {
                KeyCode::Enter => self.view.q = self.typing.take().unwrap_or_default(),
                // The draft goes and the query in force stays; Esc again clears the view.
                KeyCode::Esc => {
                    self.typing = None;
                    return Took::Typing;
                }
                KeyCode::Backspace => {
                    t.pop();
                    return Took::Typing;
                }
                KeyCode::Char(c) => {
                    t.push(c);
                    return Took::Typing;
                }
                _ => return Took::Typing,
            }
            return Took::View;
        }
        match code {
            KeyCode::Char('/') => {
                self.typing = Some(self.view.q.clone());
                return Took::Typing;
            }
            KeyCode::Char('f') => self.view.cycle_state::<R>(),
            KeyCode::Char('s') => self.view.cycle_sort::<R>(),
            KeyCode::Char('S') => self.view.flip(),
            KeyCode::Char('x') => self.clear(),
            _ => return Took::No,
        }
        Took::View
    }

    /// A key that moves the selection over `n` rows, `page` of them to a screen: j/k or Down/Up
    /// a row, PageDown or space and PageUp a page, Ctrl-d/Ctrl-u half of one, g/G or Home/End to
    /// the ends. False for any other key, any other Ctrl chord too. The selection is first put
    /// back in range, as a re-read may have left fewer rows.
    pub fn moves(&mut self, k: KeyEvent, n: usize, page: usize) -> bool {
        self.clamp(n);
        let last = n.saturating_sub(1);
        let page = page.max(1);
        let half = (page / 2).max(1);
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        self.sel = match k.code {
            KeyCode::Char('d') if ctrl => self.sel + half,
            KeyCode::Char('u') if ctrl => self.sel.saturating_sub(half),
            _ if ctrl => return false,
            KeyCode::Char('j') | KeyCode::Down => self.sel + 1,
            KeyCode::Char('k') | KeyCode::Up => self.sel.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => self.sel + page,
            KeyCode::PageUp => self.sel.saturating_sub(page),
            KeyCode::Char('g') | KeyCode::Home => 0,
            KeyCode::Char('G') | KeyCode::End => last,
            _ => return false,
        }
        .min(last);
        true
    }

    /// What Enter on a row opens: its lead column's record, else the first column that names
    /// one (`Row::link`, the resolver agent-web draws its anchors from).
    pub fn opens<R: Row>(row: &R) -> Option<Link> {
        std::iter::once(R::LEAD)
            .chain(R::COLUMNS.iter().copied())
            .filter(|c| !c.is_empty())
            .find_map(|c| row.link(c))
    }

    /// The selection within `n` rows.
    pub fn clamp(&mut self, n: usize) {
        self.sel = self.sel.min(n.saturating_sub(1));
    }

    /// After a re-read: the selection on row `at`, where the row it was on now is, then within
    /// `n` rows.
    pub fn keep(&mut self, at: Option<usize>, n: usize) {
        if let Some(i) = at {
            self.sel = i;
        }
        self.clamp(n);
    }

    /// The header and the `h` rows of a drawn table that keep the selection in view: the header
    /// stays, rows scroll under it.
    pub fn window(&mut self, table: Vec<Line<'static>>, h: usize) -> Vec<Line<'static>> {
        if self.sel < self.top {
            self.top = self.sel;
        } else if self.sel >= self.top + h {
            self.top = self.sel + 1 - h;
        }
        let mut rows = table.into_iter();
        rows.next()
            .into_iter()
            .chain(rows.skip(self.top).take(h))
            .collect()
    }

    /// Mark the selected row of a drawn table, a header line then one line per row, and say
    /// which line that is.
    pub fn style(&self, lines: &mut [Line<'static>], p: Palette) -> Option<usize> {
        let l = lines.get_mut(self.sel + 1)?;
        l.style = p.sel();
        Some(self.sel + 1)
    }

    /// The sort column's index in `R::COLUMNS` and its mark, for `fit::Table::mark`.
    pub fn mark<R: Row>(&self) -> Option<(usize, &'static str)> {
        let i = R::COLUMNS.iter().position(|c| *c == self.view.sort)?;
        Some((
            i,
            if self.view.dir == Dir::Asc {
                " ^"
            } else {
                " v"
            },
        ))
    }

    /// The state chips with their counts (the one in force in the head style), the query and
    /// the sort.
    pub fn status<R: Row>(&self, rows: &[R], p: Palette) -> Vec<Span<'static>> {
        let mut out = self.chips(rows, p);
        out.extend(self.asked::<R>(p));
        out
    }

    /// What the table's state words mean (`Row::LEGEND`, `hub_core::table::legend`), dim lines
    /// for under its chips, wrapped between words to `w` (0: one line); none for a table without.
    pub fn legend<R: Row>(p: Palette, w: usize) -> Vec<Line<'static>> {
        let Some(text) = hub_core::table::legend::<R>() else {
            return vec![];
        };
        let words: Vec<&str> = text.split(' ').collect();
        wrap(&words, " ", w)
            .into_iter()
            .map(|l| Line::styled(l, p.dim()))
            .collect()
    }

    /// The state chips with their counts in their hue (`Chip::tone`), the one in force in the
    /// head style.
    pub fn chips<R: Row>(&self, rows: &[R], p: Palette) -> Vec<Span<'static>> {
        let mut out = vec![];
        for (i, c) in self.view.states(rows).iter().enumerate() {
            let on = if i == 0 {
                self.view.state.is_empty()
            } else {
                self.view.state == c.name
            };
            let text = format!("{}{} {}", if i == 0 { "" } else { "  " }, c.name, c.n);
            let hue = c.tone.map_or_else(Style::new, |l| crate::releases::level(l, p));
            out.push(Span::styled(
                text,
                if on { hue.patch(p.head()) } else { hue },
            ));
        }
        out
    }

    /// The query, or the draft being typed, and the sort: a table whose chips can fill the line
    /// draws these on their own, so what is typed is never clipped.
    pub fn asked<R: Row>(&self, p: Palette) -> Vec<Span<'static>> {
        let mut out = vec![];
        if let Some(t) = &self.typing {
            out.push(Span::styled(format!(" | /{t}_"), p.head()));
        } else if !self.view.q.is_empty() {
            out.push(Span::raw(format!(" | /{}", self.view.q)));
        }
        if let Some((_, m)) = self.mark::<R>() {
            out.push(Span::raw(format!(" | sort {}{m}", self.view.sort)));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::jobs::{Job, Source, State};

    fn jobs() -> Vec<Job> {
        let mut a = Job::new(Source::Unity, "gate", State::Done);
        a.ok = Some(false);
        vec![a, Job::new(Source::Agentctl, "dream", State::Running)]
    }

    fn status(t: &DataTable) -> String {
        plain(&Line::from(t.status(&jobs(), Palette { no_color: true })))
    }

    #[test]
    fn a_chip_wears_its_states_hue_only_while_it_holds_a_row() {
        let p = Palette { no_color: false };
        let chips = DataTable::default().chips(&jobs(), p);
        let fg = |w: &str| {
            chips
                .iter()
                .find(|s| s.content.trim_start().starts_with(w))
                .and_then(|s| s.style.fg)
        };
        assert_eq!(fg("failed"), p.bad().fg);
        assert_eq!(fg("done"), p.good().fg);
        assert_eq!(
            (fg("running"), fg("waiting")),
            (None, None),
            "no hue for a neutral word or a zero count"
        );
        assert!(
            chips[0]
                .style
                .add_modifier
                .contains(ratatui::style::Modifier::BOLD),
            "the chip in force is the head"
        );
    }

    #[test]
    fn the_keys_drive_the_one_view() {
        let mut t = DataTable::default();
        for c in "/source:unity".chars() {
            assert_eq!(t.key::<Job>(KeyCode::Char(c)), Took::Typing);
        }
        assert!(t.view.q.is_empty(), "typing applies on Enter");
        assert_eq!(
            status(&t),
            "all 2  running 1  waiting 0  done 1  failed 1 | /source:unity_"
        );
        assert_eq!(t.key::<Job>(KeyCode::Enter), Took::View);
        assert_eq!(t.view.q, "source:unity");
        assert_eq!(t.view.apply(&jobs()).len(), 1);
        t.key::<Job>(KeyCode::Char('f'));
        assert_eq!(t.view.state, "running");
        t.key::<Job>(KeyCode::Char('s'));
        t.key::<Job>(KeyCode::Char('S'));
        assert_eq!((t.view.sort.as_str(), t.view.dir), ("state", Dir::Asc));
        assert_eq!(t.mark::<Job>(), Some((0, " ^")));
        assert!(status(&t).ends_with("| /source:unity | sort state ^"));
        assert_eq!(t.key::<Job>(KeyCode::Char('j')), Took::No);
        assert!(DataTable::owns(KeyCode::Char('S')) && !DataTable::owns(KeyCode::Char('j')));
        t.key::<Job>(KeyCode::Char('x'));
        assert!(t.is_default());
    }

    #[test]
    fn enter_opens_the_lead_record_else_the_first_linked_column() {
        use hub_core::links::{Kind, Link};
        use hub_core::table::{Row, Val};
        struct R(&'static str, bool);
        impl Row for R {
            const COLUMNS: &'static [&'static str] = &["state", "project", "pr"];
            const STATES: &'static [&'static str] = &[];
            const FACETS: &'static [&'static str] = &[];
            const LEAD: &'static str = "item";
            fn val(&self, _: &str) -> Val {
                Val::Text(String::new())
            }
            fn in_state(&self, _: &str) -> bool {
                true
            }
            fn link(&self, col: &str) -> Option<Link> {
                match col {
                    "item" if self.1 => Some(Link::to(Kind::Queue, self.0)),
                    "project" => Some(Link::to(Kind::Project, "p")),
                    "pr" => Some(Link::Url("https://x/pull/1".into())),
                    _ => None,
                }
            }
        }
        assert_eq!(
            DataTable::opens(&R("slug", true)),
            Some(Link::to(Kind::Queue, "slug"))
        );
        assert_eq!(
            DataTable::opens(&R("slug", false)),
            Some(Link::to(Kind::Project, "p"))
        );
    }

    #[test]
    fn esc_while_typing_keeps_the_query_in_force() {
        let mut t = DataTable::default();
        t.view.q = "dream".into();
        t.key::<Job>(KeyCode::Char('/'));
        t.key::<Job>(KeyCode::Char('x'));
        assert_eq!(t.key::<Job>(KeyCode::Esc), Took::Typing);
        assert_eq!((t.view.q.as_str(), t.typing.is_none()), ("dream", true));
    }

    #[test]
    fn one_cursor_moves_clamps_and_starts_over_on_a_new_view() {
        let key = |c: KeyCode| -> KeyEvent { c.into() };
        let ctrl = |c| KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL);
        let mut t = DataTable::default();
        let at = |t: &mut DataTable, k| {
            assert!(t.moves(k, 10, 4));
            t.sel
        };
        assert_eq!(at(&mut t, key(KeyCode::Char('j'))), 1);
        assert_eq!(at(&mut t, key(KeyCode::Down)), 2);
        assert_eq!(at(&mut t, key(KeyCode::Char('k'))), 1);
        assert_eq!(at(&mut t, key(KeyCode::PageDown)), 5);
        assert_eq!(
            at(&mut t, key(KeyCode::Char(' '))),
            9,
            "a page stops at the last row"
        );
        assert_eq!(at(&mut t, key(KeyCode::Char('j'))), 9);
        assert_eq!(at(&mut t, key(KeyCode::PageUp)), 5);
        assert_eq!(at(&mut t, ctrl('u')), 3);
        assert_eq!(at(&mut t, ctrl('d')), 5);
        assert_eq!(at(&mut t, key(KeyCode::Char('g'))), 0);
        assert_eq!(at(&mut t, key(KeyCode::Up)), 0);
        assert_eq!(at(&mut t, key(KeyCode::End)), 9);
        assert!(!t.moves(key(KeyCode::Enter), 10, 4));
        assert!(!t.moves(ctrl('j'), 10, 4), "a Ctrl chord is not a move");

        // Fewer rows after a re-read: a move starts from the last one.
        assert!(t.moves(key(KeyCode::Char('k')), 3, 4));
        assert_eq!(t.sel, 1);
        t.clamp(0);
        assert_eq!(t.sel, 0);
        t.sel = 7;
        t.keep(None, 5);
        assert_eq!(t.sel, 4);
        t.keep(Some(2), 5);
        assert_eq!(t.sel, 2);

        let p = Palette { no_color: true };
        let mut lines: Vec<Line<'static>> = (0..4).map(|i| Line::raw(i.to_string())).collect();
        assert_eq!(t.style(&mut lines, p), Some(3));
        assert_eq!(
            (lines[3].style, lines[2].style),
            (p.sel(), Default::default())
        );
        t.sel = 3;
        assert_eq!(
            t.style(&mut lines, p),
            None,
            "no line for a row past the table"
        );

        t.sel = 2;
        t.key::<Job>(KeyCode::Char('/'));
        t.key::<Job>(KeyCode::Char('d'));
        assert_eq!(t.sel, 2, "typing leaves the selection");
        assert_eq!(t.key::<Job>(KeyCode::Enter), Took::View);
        assert_eq!(t.sel, 0, "a changed view starts at the top");
        t.sel = 2;
        t.clear();
        assert_eq!(t.sel, 0);
    }

    #[test]
    fn the_window_keeps_the_header_and_scrolls_rows_to_the_selection() {
        let lines = |n: usize| -> Vec<Line<'static>> {
            (0..=n).map(|i| Line::from(i.to_string())).collect()
        };
        let shown = |v: Vec<Line<'static>>| v.iter().map(plain).collect::<Vec<_>>();
        let mut t = DataTable::default();
        assert_eq!(shown(t.window(lines(5), 2)), ["0", "1", "2"]);
        t.sel = 4;
        assert_eq!(
            shown(t.window(lines(5), 2)),
            ["0", "4", "5"],
            "down past the end scrolls"
        );
        t.sel = 2;
        assert_eq!(
            shown(t.window(lines(5), 2)),
            ["0", "3", "4"],
            "inside the window stays put"
        );
        t.sel = 1;
        assert_eq!(
            shown(t.window(lines(5), 2)),
            ["0", "2", "3"],
            "up past the top scrolls"
        );
    }
}
