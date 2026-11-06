//! The keys and status line every data table tab shares, over `hub_core::table::View`, which
//! alone decides what a query keeps and how a sort orders (docs/dashboards.md rule 7). agent-web
//! draws the same view from the same summary.
//!
//! `/` types the query (Enter applies, Esc clears it), `f` steps the state chip, `s` sorts by
//! the next column, `S` flips the direction, `x` clears the whole view.

use hub_core::table::{Dir, Row, View};
use ratatui::crossterm::event::KeyCode;
use ratatui::text::Span;

use crate::fmt::Palette;

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
    /// The query being typed after `/`, applied on Enter.
    pub typing: Option<String>,
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

    /// The query, chip and sort back to the table's own, nothing typed.
    pub fn clear(&mut self) {
        *self = DataTable::default();
    }

    /// One key, for an `R` table: what it did, so the caller moves its selection to the top
    /// when the view changed.
    pub fn key<R: Row>(&mut self, code: KeyCode) -> Took {
        if let Some(t) = self.typing.as_mut() {
            match code {
                KeyCode::Enter => self.view.q = self.typing.take().unwrap_or_default(),
                KeyCode::Esc => {
                    self.typing = None;
                    self.view.q.clear();
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
        let mut out = vec![];
        for (i, c) in self.view.states(rows).iter().enumerate() {
            let on = if i == 0 {
                self.view.state.is_empty()
            } else {
                self.view.state == c.name
            };
            let text = format!("{}{} {}", if i == 0 { "" } else { "  " }, c.name, c.n);
            out.push(if on {
                Span::styled(text, p.head())
            } else {
                Span::raw(text)
            });
        }
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
    use ratatui::text::Line;

    fn jobs() -> Vec<Job> {
        let mut a = Job::new(Source::Ci, "gate", State::Done);
        a.ok = Some(false);
        vec![a, Job::new(Source::Agentctl, "dream", State::Running)]
    }

    fn status(t: &DataTable) -> String {
        plain(&Line::from(t.status(&jobs(), Palette { no_color: true })))
    }

    #[test]
    fn the_keys_drive_the_one_view() {
        let mut t = DataTable::default();
        for c in "/source:ci".chars() {
            assert_eq!(t.key::<Job>(KeyCode::Char(c)), Took::Typing);
        }
        assert!(t.view.q.is_empty(), "typing applies on Enter");
        assert_eq!(
            status(&t),
            "all 2  running 1  queued 0  done 1  failed 1 | /source:ci_"
        );
        assert_eq!(t.key::<Job>(KeyCode::Enter), Took::View);
        assert_eq!(t.view.q, "source:ci");
        assert_eq!(t.view.apply(&jobs()).len(), 1);
        t.key::<Job>(KeyCode::Char('f'));
        assert_eq!(t.view.state, "running");
        t.key::<Job>(KeyCode::Char('s'));
        t.key::<Job>(KeyCode::Char('S'));
        assert_eq!((t.view.sort.as_str(), t.view.dir), ("state", Dir::Asc));
        assert_eq!(t.mark::<Job>(), Some((0, " ^")));
        assert!(status(&t).ends_with("| /source:ci | sort state ^"));
        assert_eq!(t.key::<Job>(KeyCode::Char('j')), Took::No);
        assert!(DataTable::owns(KeyCode::Char('S')) && !DataTable::owns(KeyCode::Char('j')));
        t.key::<Job>(KeyCode::Char('x'));
        assert!(t.is_default());
    }

    #[test]
    fn esc_while_typing_clears_the_query() {
        let mut t = DataTable::default();
        t.view.q = "dream".into();
        t.key::<Job>(KeyCode::Char('/'));
        t.key::<Job>(KeyCode::Esc);
        assert!(t.is_default());
    }
}
