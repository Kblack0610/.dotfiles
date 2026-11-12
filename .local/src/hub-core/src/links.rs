//! The one link resolver (docs/dashboards.md rule 8): an entity is a kind plus an id, it has
//! exactly one page, and every place that names it links there through [`Link`]. agent-web draws
//! [`Link::href`] (a `#tab/...` hash, or a URL for a page outside the hub), the hub TUI opens
//! [`Link::tab_args`] (what `hub tab` takes). Nothing else builds a `#...` string for a record.
//!
//! A page that lives inside an inner tab (`#infra/machines/<host>`) is listed in [`PAGES`], which
//! app.js mirrors as `ENTITY_PAGES` (agent-web's `entity_pages_are_the_links` test), so its router
//! keeps the id after the inner tab instead of dropping it.

use serde::{Serialize, Serializer};

/// What a record is: each kind has one page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A tab's front (`#home`), for a fact whose home is a whole tab.
    Tab,
    Project,
    /// A session, by its tmux target or session id (`#sessions/<id>` takes either).
    Session,
    /// An agent-queue item, by its slug.
    Queue,
    /// A board row or an epic, by its id (`ar-1494`): the Board filtered to exactly that id.
    Row,
    /// An agentctl runner's page.
    Runner,
    /// A watch or a Prometheus red, by its alert id.
    Alert,
    Machine,
    Pool,
    /// A CI run's record.
    CiRun,
    /// A job that runs on its own, by its name.
    Job,
    /// A PR's CI runs, by `owner/repo#N`: Infra's runs table filtered to that PR.
    PrRuns,
    /// An app's status page (`hub_core::app_status`), by its project-map tracker key.
    App,
    /// An app's channels: the Releases table filtered to that project.
    AppChannels,
}

/// An entity page that sits inside a tab's inner tab: its kind, the tab, the `#tab/<word>/<id>`
/// word that names it, and the inner tab it opens on.
pub struct Page {
    pub kind: Kind,
    pub tab: &'static str,
    pub word: &'static str,
    pub inner: &'static str,
}

pub const PAGES: &[Page] = &[
    Page {
        kind: Kind::Machine,
        tab: "infra",
        word: "machines",
        inner: "machines",
    },
    Page {
        kind: Kind::Pool,
        tab: "infra",
        word: "pools",
        inner: "machines",
    },
    Page {
        kind: Kind::CiRun,
        tab: "infra",
        word: "ci",
        inner: "ci",
    },
    Page {
        kind: Kind::Job,
        tab: "infra",
        word: "jobs",
        inner: "jobs",
    },
    Page {
        kind: Kind::App,
        tab: "releases",
        word: "apps",
        inner: "apps",
    },
];

/// The page `hub tab '<tab> <word>/<id>'` names (`PAGES`), as `Link::tab_args` writes it.
pub fn page_of<'a>(tab: &str, arg: &'a str) -> Option<(Kind, &'a str)> {
    let (word, id) = arg.trim().split_once('/')?;
    let p = PAGES
        .iter()
        .find(|p| p.tab.eq_ignore_ascii_case(tab) && p.word.eq_ignore_ascii_case(word))?;
    Some((p.kind, id.trim())).filter(|(_, id)| !id.is_empty())
}

/// `kind`'s row, when its records have a page.
pub fn page(kind: Kind) -> Option<&'static Page> {
    PAGES.iter().find(|p| p.kind == kind)
}

/// Where a cell, a part or a row leads: a record's page in the hub, or a page outside it (a PR,
/// its checks), which is already a URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Link {
    To(Kind, String),
    Url(String),
}

impl Link {
    pub fn to(kind: Kind, id: impl Into<String>) -> Link {
        Link::To(kind, id.into())
    }

    /// A tab's front page.
    pub fn tab(id: &str) -> Link {
        Link::to(Kind::Tab, id)
    }

    /// The web's address for it: agent-web's hash for a record, the URL itself for the rest.
    pub fn href(&self) -> String {
        let (kind, id) = match self {
            Link::Url(u) => return u.clone(),
            Link::To(k, id) => (*k, id.as_str()),
        };
        let seg = component(id);
        if let Some(p) = page(kind) {
            return format!("#{}/{}/{seg}", p.tab, p.word);
        }
        match kind {
            Kind::Tab => format!("#{seg}"),
            Kind::Project => format!("#projects/{seg}"),
            Kind::Session => format!("#sessions/{seg}"),
            Kind::Queue => format!("#queue/{seg}"),
            // `id:ar-1` alone would match `ar-10`.
            Kind::Row => format!("#board?q=id:={seg}"),
            Kind::Runner => format!("#fleet/{seg}"),
            Kind::Alert => format!("#alerts/{seg}"),
            // ci.js's runs table keys its view with `b` (`bq`); `pr:=` is exact, so #1 is not #10.
            Kind::PrRuns => format!("#infra/runs?bq=pr:={seg}"),
            Kind::AppChannels => format!("#releases?q=project:={seg}"),
            Kind::Machine | Kind::Pool | Kind::CiRun | Kind::Job | Kind::App => {
                unreachable!("in PAGES")
            }
        }
    }

    /// What `hub tab` takes for it (the tab, then the word that tab opens), or None for a page
    /// outside the hub. A page inside an inner tab is its `word/id`, as on the web.
    pub fn tab_args(&self) -> Option<(&'static str, String)> {
        let Link::To(kind, id) = self else {
            return None;
        };
        if let Some(p) = page(*kind) {
            return Some((p.tab, format!("{}/{id}", p.word)));
        }
        Some(match kind {
            Kind::Tab => return crate::layout::resolve(id).map(|t| (t.id, String::new())),
            Kind::Project => ("projects", id.clone()),
            Kind::Session => ("sessions", id.clone()),
            Kind::Queue => ("queue", id.clone()),
            Kind::Row => ("board", format!("id:={id}")),
            Kind::Runner => ("fleet", id.clone()),
            Kind::Alert => ("alerts", String::new()),
            Kind::PrRuns => ("infra", format!("runs pr:={id}")),
            Kind::AppChannels => ("releases", format!("project:={id}")),
            Kind::Machine | Kind::Pool | Kind::CiRun | Kind::Job | Kind::App => {
                unreachable!("in PAGES")
            }
        })
    }
}

/// It goes to the page as the href it draws, so a field that held a `#...` string keeps its shape.
impl Serialize for Link {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.href())
    }
}

/// `id` as one URL component, what the page's `encodeURIComponent` gives: a slash or a colon in
/// a session id (`lab/x:1`) stays inside its segment, and route() decodes it back.
fn component(id: &str) -> String {
    let mut out = String::with_capacity(id.len());
    for b in id.bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'!'
            | b'~'
            | b'*'
            | b'\''
            | b'('
            | b')' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_page_tab_args_writes_is_the_page_page_of_reads() {
        for p in PAGES {
            let (tab, arg) = Link::to(p.kind, "x1").tab_args().unwrap();
            assert_eq!(page_of(tab, &arg), Some((p.kind, "x1")), "{}", p.word);
        }
        assert_eq!(page_of("Infra", " CI/4412 "), Some((Kind::CiRun, "4412")));
        assert_eq!(page_of("infra", "ci/"), None, "no id, no page");
        assert_eq!(page_of("infra", "runs pr:=o/r#7"), None);
        assert_eq!(
            page_of("costs", "machines/w"),
            None,
            "a page is on its own tab"
        );
    }

    #[test]
    fn each_kind_has_one_address_on_each_surface() {
        let both = |k, id: &str| {
            let l = Link::to(k, id);
            (l.href(), l.tab_args())
        };
        let a = |t: &'static str, w: &str| Some((t, w.to_string()));
        assert_eq!(
            both(Kind::Project, "agent-runtime"),
            (
                "#projects/agent-runtime".into(),
                a("projects", "agent-runtime")
            )
        );
        assert_eq!(
            both(Kind::Session, "lab/dotfiles-agent-11:1"),
            (
                "#sessions/lab%2Fdotfiles-agent-11%3A1".into(),
                a("sessions", "lab/dotfiles-agent-11:1")
            )
        );
        assert_eq!(
            both(Kind::Queue, "the-item"),
            ("#queue/the-item".into(), a("queue", "the-item"))
        );
        assert_eq!(
            both(Kind::Row, "ar-455"),
            ("#board?q=id:=ar-455".into(), a("board", "id:=ar-455"))
        );
        assert_eq!(
            both(Kind::Runner, "inbox-triage"),
            ("#fleet/inbox-triage".into(), a("fleet", "inbox-triage"))
        );
        assert_eq!(both(Kind::Tab, "home"), ("#home".into(), a("home", "")));
        assert_eq!(
            both(Kind::Alert, "w-1"),
            ("#alerts/w-1".into(), a("alerts", ""))
        );
        assert_eq!(
            both(Kind::Machine, "razer-laptop"),
            (
                "#infra/machines/razer-laptop".into(),
                a("infra", "machines/razer-laptop")
            )
        );
        assert_eq!(
            both(Kind::Pool, "unity"),
            ("#infra/pools/unity".into(), a("infra", "pools/unity"))
        );
        assert_eq!(
            both(Kind::App, "shop"),
            (
                "#releases/apps/shop".into(),
                a("releases", "apps/shop")
            )
        );
        assert_eq!(
            both(Kind::AppChannels, "binks"),
            ("#releases?q=project:=binks".into(), a("releases", "project:=binks"))
        );
        assert_eq!(
            both(Kind::CiRun, "4412"),
            ("#infra/ci/4412".into(), a("infra", "ci/4412"))
        );
        assert_eq!(
            both(Kind::Job, "agentctl-dream"),
            (
                "#infra/jobs/agentctl-dream".into(),
                a("infra", "jobs/agentctl-dream")
            )
        );
        assert_eq!(
            both(Kind::PrRuns, "Kblack0610/.dotfiles#1924"),
            (
                "#infra/runs?bq=pr:=Kblack0610%2F.dotfiles%231924".into(),
                a("infra", "runs pr:=Kblack0610/.dotfiles#1924")
            )
        );
    }

    #[test]
    fn a_url_is_drawn_as_it_is_and_the_tui_cannot_open_it_as_a_tab() {
        let u = Link::Url("https://github.com/o/r/pull/1".into());
        assert_eq!(u.href(), "https://github.com/o/r/pull/1");
        assert_eq!(u.tab_args(), None);
        assert_eq!(
            serde_json::to_value(&u).unwrap(),
            serde_json::json!("https://github.com/o/r/pull/1")
        );
    }

    #[test]
    fn an_id_cannot_leave_its_segment_or_start_a_new_query_key() {
        assert_eq!(
            Link::to(Kind::Project, "bnb/demo").href(),
            "#projects/bnb%2Fdemo"
        );
        assert_eq!(
            Link::to(Kind::Row, "a&q=x #y").href(),
            "#board?q=id:=a%26q%3Dx%20%23y"
        );
        assert_eq!(Link::tab("nope").tab_args(), None, "no such tab");
    }

    #[test]
    fn every_page_is_on_a_tab_and_inner_tab_of_the_layout() {
        for p in PAGES {
            let tab = crate::layout::resolve(p.tab).unwrap_or_else(|| panic!("{}", p.tab));
            assert_eq!(tab.id, p.tab, "{} is a tab id, not a retired name", p.tab);
            assert!(
                tab.inner.iter().any(|i| i.id == p.inner),
                "{}/{} names inner tab {} the layout lacks",
                p.tab,
                p.word,
                p.inner
            );
        }
        for k in [
            Kind::Project,
            Kind::Session,
            Kind::Queue,
            Kind::Row,
            Kind::Runner,
        ] {
            let (tab, _) = Link::to(k, "x").tab_args().unwrap();
            assert!(crate::layout::resolve(tab).is_some(), "{k:?}: {tab}");
        }
    }
}
