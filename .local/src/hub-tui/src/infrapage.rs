//! The page open in place of Infra's tables: a machine's (`machinetab`) or a pool's (`pooltab`),
//! each read by hub_core for both surfaces. The app keeps one of these, reads it one way and
//! gives it one set of keys (Esc back, `o` its Grafana board, Left/Right another inner tab), so
//! a third page is a variant here and its draw module, not a copy of the app's fields.

use std::path::Path;

use hub_core::alerts::Alert;
use hub_core::infra::Infra;
use hub_core::links::{self, Kind, Link, PAGES};
use hub_core::machine_page::{self, MachinePage};
use hub_core::pool_page::{self, PoolPage};
use hub_core::session_page::Part;
use ratatui::text::Line;

use crate::fmt::Palette;

/// Each page by its name, with its read: None until it comes back. The app holds one at a time
/// and its message boxes it, so the machine variant's size costs nothing.
#[allow(clippy::large_enum_variant)]
pub enum InfraPage {
    Machine(String, Option<Result<MachinePage, String>>),
    Pool(String, Option<Result<PoolPage, String>>),
}

impl InfraPage {
    /// `name`'s page of `kind`, not read yet; None for a kind with no Infra page here.
    pub fn new(kind: Kind, name: &str) -> Option<Self> {
        let n = name.to_string();
        match kind {
            Kind::Machine => Some(Self::Machine(n, None)),
            Kind::Pool => Some(Self::Pool(n, None)),
            _ => None,
        }
    }

    /// The page a link leads to, when it leads to one of these.
    pub fn from_link(l: &Link) -> Option<Self> {
        match l {
            Link::To(k, id) => Self::new(*k, id),
            Link::Url(_) => None,
        }
    }

    /// `hub tab 'infra <word>/<name>'`: the page its word names (`links::PAGES`), as its link
    /// opens it.
    pub fn parse(q: &str) -> Option<Self> {
        let (word, name) = q.trim().split_once('/')?;
        let name = name.trim();
        let page = PAGES.iter().find(|p| p.tab == "infra" && p.word == word)?;
        (!name.is_empty())
            .then(|| Self::new(page.kind, name))
            .flatten()
    }

    pub fn kind(&self) -> Kind {
        match self {
            Self::Machine(..) => Kind::Machine,
            Self::Pool(..) => Kind::Pool,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Machine(n, _) | Self::Pool(n, _) => n,
        }
    }

    /// The same page with nothing read, for a read to fill.
    pub fn unread(&self) -> Self {
        match self {
            Self::Machine(n, _) => Self::Machine(n.clone(), None),
            Self::Pool(n, _) => Self::Pool(n.clone(), None),
        }
    }

    /// The same page: its kind and name, whatever either has read.
    pub fn is(&self, other: &Self) -> bool {
        self.kind() == other.kind() && self.name() == other.name()
    }

    /// The inner tab it opens on, as its link's (`links::PAGES`).
    pub fn inner(&self) -> &'static str {
        self.row().inner
    }

    /// What Esc goes back to, for the hint line: all of its word's records.
    pub fn back(&self) -> String {
        format!("all {}", self.row().word)
    }

    /// Its kind's `links::PAGES` row, which every kind `new` builds has (the parse test pins it).
    fn row(&self) -> &'static links::Page {
        links::page(self.kind()).expect("every InfraPage kind has a links::PAGES row")
    }

    /// Its read takes the firing alerts, so its first read waits for them.
    pub fn reads_alerts(&self) -> bool {
        matches!(self, Self::Machine(..))
    }

    /// The page read now: hub_core's reader for its kind, from the Infra rows last read.
    pub fn read(&self, infra: &Infra, firing: Option<&[Alert]>, jobs: &Path, now: u64) -> Self {
        match self {
            Self::Machine(h, _) => {
                let alerts = firing.ok_or_else(|| "not read yet".to_string());
                let r = machine_page::read(infra, h, alerts, jobs, now);
                Self::Machine(h.clone(), Some(r))
            }
            Self::Pool(n, _) => Self::Pool(n.clone(), Some(pool_page::read(infra, n, now))),
        }
    }

    /// The Grafana board it links, for `o`: the first part that leads outside the hub.
    pub fn grafana(&self) -> Option<String> {
        let parts: &[Part] = match self {
            Self::Machine(_, Some(Ok(m))) => &m.parts,
            Self::Pool(_, Some(Ok(p))) => &p.parts,
            _ => return None,
        };
        parts.iter().find_map(|p| match &p.link {
            Some(Link::Url(u)) => Some(u.clone()),
            _ => None,
        })
    }

    /// Its lines under Infra's strip.
    pub fn lines(&self, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        match self {
            Self::Machine(h, r) => crate::machinetab::page(h, r.as_ref(), p, now, w),
            Self::Pool(n, r) => crate::pooltab::page(n, r.as_ref(), p, now, w),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_page_word_parses_to_its_page_and_anything_else_does_not() {
        let m = InfraPage::parse(" machines/workstation ").unwrap();
        assert_eq!((m.kind(), m.name()), (Kind::Machine, "workstation"));
        let p = InfraPage::parse("pools/unity").unwrap();
        assert_eq!(
            (p.kind(), p.name(), p.inner()),
            (Kind::Pool, "unity", "machines")
        );
        assert!(!p.is(&m));
        assert!(InfraPage::parse("governor").is_none());
        assert!(
            InfraPage::parse("ci/7").is_none(),
            "a CI run is no page of these"
        );
        assert!(
            InfraPage::parse("machines/ ").is_none(),
            "a page needs a name"
        );
        assert_eq!((m.inner(), m.back().as_str()), ("machines", "all machines"));
        assert_eq!(p.back(), "all pools");
    }

    #[test]
    fn o_opens_the_first_part_that_leads_outside_the_hub() {
        let page = PoolPage {
            parts: vec![
                Part::new("Slots", "1 busy of 3").link(Link::to(Kind::Machine, "ws")),
                Part::new("Grafana", "board").link(Link::Url("https://g/d/kb-ci-runners".into())),
            ],
            ..Default::default()
        };
        let p = InfraPage::Pool("unity".into(), Some(Ok(page)));
        assert_eq!(p.grafana().as_deref(), Some("https://g/d/kb-ci-runners"));
        assert!(InfraPage::Pool("unity".into(), None).grafana().is_none());
    }
}
