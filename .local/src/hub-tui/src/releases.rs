//! The Releases page: every app from `hub_core::releases::read` on the shared data table
//! (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear), one row each with what is live
//! where it matters most. The opened app's pane lists its headline env's channels, its other envs
//! under a fold (`F`), then its changelog. The page is the layout's inner tabs (Apps, Builds,
//! Tests, `hub_core::layout`), switched with Left/Right.

use hub_core::builds::Builds;
use hub_core::layout;
use hub_core::releases::{App, Changelog, Deploy, Level, Release, Releases, STALE_SECS};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::{clock, Palette};
use crate::projtab::wrapped;

/// A line's colour where only trouble is coloured: a green line would shout.
pub(crate) fn alert(l: Level, p: Palette) -> Style {
    if l == Level::Ok {
        Style::default()
    } else {
        level(l, p)
    }
}

/// `App::COLUMNS` in capitals, in its order, the sort mark placed by that index; `project` is
/// drawn as APP. `channel` and `id` filter without a column: the pane says them.
const HEADER: [&str; 6] = [
    "APP",
    "LIVE",
    "STATUS",
    "CHANNELS",
    "RELEASED",
    "LAST DEPLOY",
];
/// The width of the pane's labels, as the longest one.
const LABEL: usize = 9;
/// APP and LIVE at 80 columns and at their widest: each takes half of whatever a wider terminal
/// adds. CHANNELS holds `7: 2 not read, 4 ok, 1 released`.
const APP_FIT: (usize, usize) = (16, 26);
const LIVE_FIT: (usize, usize) = (16, 28);
const STATUS_CAP: usize = 10;
const CHANNELS_CAP: usize = 31;
/// `v1.19.0 10-27 15:02`; a longer build tag clips.
const RELEASED_CAP: usize = 24;
/// `10-26 15:02 fail`.
const LAST_DEPLOY_CAP: usize = 16;
/// How many releases the pane lists before it says how many more there are.
const HISTORY_LINES: usize = 8;

/// The changelog read for the opened app: whose it is, whether a worker is still on it (one at a
/// time, so holding a key over many apps asks for the last one only), and what came back, None
/// while it is being read.
#[derive(Default)]
pub struct ChangelogRead {
    pub project: String,
    pub busy: bool,
    pub read: Option<Result<Changelog, String>>,
}

#[derive(Default)]
pub struct ReleasesView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    /// Whether the pane is open, and how far it is scrolled.
    pub open: bool,
    pub down: usize,
    /// The opened app's other envs are unfolded (`F`).
    pub others: bool,
    pub cl: ChangelogRead,
    /// The Builds inner tab's table and pane.
    pub builds: crate::builds::BuildsView,
    /// The inner tab picked (a `layout::Inner` id of Releases); empty until one is.
    pub inner: &'static str,
}

/// Releases' layout entry: its inner tabs.
pub fn tab() -> &'static layout::Tab {
    layout::resolve("releases").expect("releases is a tab")
}

/// The Releases sections that need a look, for the counts on their inner tabs: a bad app and a
/// red build of the last day. The TUI reads no tests run, so Tests carries no count here.
pub fn flagged(s: &Releases, b: Option<&Builds>) -> Vec<&'static str> {
    let mut out = vec![];
    if s.needs_look() {
        out.push("table");
    }
    if b.is_some_and(Builds::needs_look) {
        out.push("builds");
    }
    out
}

/// What the Tests inner tab says: the suites are read by agent-web alone.
pub fn tests_note(p: Palette, w: usize) -> Vec<Line<'static>> {
    let text = "The suites of the newest tests.yml run are on agent-web, Releases, Tests. The TUI does not read them.";
    let words: Vec<&str> = text.split_whitespace().collect();
    wrap(&words, " ", w.max(20))
        .into_iter()
        .map(|l| clip_line(Line::styled(l, p.dim()), w))
        .collect()
}

/// The row a selection stands for, so a new snapshot keeps the same app selected.
pub type RowId = String;

pub fn row_id(a: &App) -> RowId {
    a.project.clone()
}

pub(crate) fn level(l: Level, p: Palette) -> Style {
    match l {
        Level::Bad => p.bad(),
        Level::Warn => p.warn(),
        Level::Ok => p.good(),
    }
}

impl ReleasesView {
    /// The tab on a fresh view of `q`, nothing selected or open.
    pub fn open_view(&mut self, q: String) {
        self.table.view = hub_core::table::View {
            q,
            ..Default::default()
        };
        self.table.sel = 0;
        self.open = false;
        self.down = 0;
        self.inner = "";
    }

    /// The inner tab shown: the one picked, or the first.
    pub fn on(&self) -> &'static str {
        layout::inner_tab(tab(), Some(self.inner)).map_or("", |i| i.id)
    }

    /// Show inner tab `id`. The app pane is the Apps tab's: it closes when another is shown.
    pub fn show(&mut self, id: &'static str) {
        self.inner = id;
        if self.on() != "apps" {
            self.open = false;
        }
    }

    /// The tag `by` places along the picker from the one on show (positive is older), if any.
    pub fn pick(&self, by: isize) -> Option<String> {
        let Some(Ok(c)) = &self.cl.read else {
            return None;
        };
        c.neighbour(by).map(String::from)
    }

    /// The apps drawn, in the view's sort or the reader's exceptions-first order.
    pub fn shown<'a>(&self, s: &'a Releases) -> Vec<&'a App> {
        self.table.view.apply(&s.apps)
    }

    /// Move the selection to the row with this id after a read, or keep the index in range.
    pub fn reselect(&mut self, s: &Releases, id: Option<RowId>) {
        let rows = self.shown(s);
        let at = id.and_then(|id| rows.iter().position(|a| a.project == id));
        self.table.keep(at, rows.len());
    }

    /// The tab's question, the summary with the snapshot's age, the channels it could not read,
    /// the view, and what stopped a read.
    pub fn status(&self, s: &Releases, p: Palette, now: i64) -> Vec<Line<'static>> {
        let mut head = vec![Span::styled(s.summary.clone(), p.head())];
        if s.at > 0 {
            let age = hub_core::text::age(now - s.at);
            head.push(Span::styled(
                format!("  refreshed {} ({age} ago)", clock(s.at, now)),
                if s.stale(now) { p.warn() } else { p.dim() },
            ));
        }
        if s.stale(now) {
            head.push(Span::styled(
                format!("  older than {}", hub_core::text::age(STALE_SECS)),
                p.warn(),
            ));
        }
        let mut spans = self.table.status(&s.apps, p);
        spans.push(Span::styled(
            format!("    {} of {}", self.shown(s).len(), s.apps.len()),
            p.dim(),
        ));
        let mut out = vec![Line::styled(s.question.clone(), p.head()), Line::from(head)];
        if !s.gaps.is_empty() {
            out.push(Line::styled(s.gaps.clone(), p.warn()));
        }
        out.push(Line::from(spans));
        if !s.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", s.errors.join("; ")),
                p.warn(),
            ));
        }
        out
    }

    /// The table: a header line, then one line per shown app. `sel` marks the selected row.
    pub fn table(&self, s: &Releases, p: Palette, w: usize, sel: bool) -> Vec<Line<'static>> {
        let rows = self.shown(s);
        if rows.is_empty() {
            let says = if s.apps.is_empty() {
                "no apps"
            } else {
                "no app matches (/ query, f state, x clears)"
            };
            return vec![Line::styled(says, p.dim())];
        }
        let spare = w.saturating_sub(80) / 2;
        let fit = |(least, most): (usize, usize)| (least + spare).min(most);
        // The mark of a column with no header (`channel`, `id`) has nothing to sit on.
        let mark = self.table.mark::<App>().filter(|(i, _)| *i < HEADER.len());
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: rows.iter().map(|a| row(a, p)).collect(),
            // RELEASED, then LAST DEPLOY, go first when it is narrow: a wide terminal has the room.
            keep: vec![0, 2, 1, 3, 4, 5],
            right: vec![],
            cap: vec![
                (0, fit(APP_FIT)),
                (1, fit(LIVE_FIT)),
                (2, STATUS_CAP),
                (3, CHANNELS_CAP),
                (4, RELEASED_CAP),
                (5, LAST_DEPLOY_CAP),
            ],
            mark,
            ..Default::default()
        }
        .fit(w, p.head());
        if sel {
            self.table.style(&mut out, p);
        }
        out
    }
}

fn row(a: &App, p: Palette) -> Vec<Cell> {
    let tinted = |text: &str, l: Level| match l {
        Level::Ok => text.to_string().into(),
        l => cell(text.to_string(), level(l, p)),
    };
    let channels = if a.unread > 0 {
        cell(a.channels_text.clone(), p.warn())
    } else {
        a.channels_text.clone().into()
    };
    vec![
        a.project.clone().into(),
        a.live_text.clone().into(),
        cell(a.status_text.clone(), level(a.level, p)),
        channels,
        cell(a.released_text.clone(), p.dim()),
        tinted(&a.last_deploy_text, a.deploy_level),
    ]
}

/// One side's pane line: the value, where it was read from, then its image or what failed.
fn side(s: &hub_core::releases::Side, text: &str) -> String {
    let mut out = format!("{text} from {}", s.source);
    if let Some(i) = &s.image {
        out += &format!(", image {i}");
    }
    if let Some(e) = &s.error {
        out += &format!(": {e}");
    }
    out
}

/// One deployment on one pane line: when, what, how it ended, the run that proves it.
fn deploy_line(d: &Deploy, now: i64) -> String {
    let mut out = format!("{} {} {}", clock(d.at, now), d.version, d.state);
    if let Some(u) = &d.url {
        out += &format!(" {u}");
    }
    out
}

/// One channel in the pane: its label and status, then each part that has anything to say,
/// indented under it and wrapped to `w`.
fn channel(r: &Release, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut status = r.status_text.clone();
    if let Some(t) = r.drift_since {
        status += &format!(" since {}", clock(t, now));
    }
    if let Some(t) = r.probed_at {
        status += &format!(", probed {}", clock(t, now));
    }
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(format!("  {}  ", r.label), p.head()),
            Span::styled(status, level(r.level, p)),
        ]),
        w,
    )];
    let mut part = |label: &str, text: &str, style: Style| {
        out.extend(wrapped(&format!("    {label:<LABEL$} "), text, style, p, w));
    };
    let plain = Style::default();
    part("Pinned", &side(&r.pinned, &r.pinned_text), plain);
    part("Live", &side(&r.live, &r.live_text), plain);
    if let Some(t) = &r.tag {
        part("Tag", t, plain);
    }
    if let Some(e) = &r.deploys.error {
        part("Deploys", &format!("{e} ({})", r.deploys.source), p.warn());
    }
    if let Some(v) = &r.deploys.prev {
        part("Prev", v, plain);
    }
    for d in &r.deploys.history {
        let style = if d.failed() { p.warn() } else { plain };
        part("Deploy", &deploy_line(d, now), style);
    }
    if let Some(t) = &r.place {
        part("Where", t, plain);
    }
    for t in &r.telemetry {
        let since = t
            .since
            .map_or(String::new(), |at| format!(" since {}", clock(at, now)));
        part(
            "Watch",
            &format!("{} {}{since}", t.watch, t.state),
            alert(t.level, p),
        );
    }
    if !r.deps.is_empty() {
        part("Deps", &r.deps_text, plain);
    }
    out
}

/// The pane: the app's word and its channels, the headline env's channels, the other envs under
/// a fold (`others` unfolds them), then the app's changelog (`cl`, None while it is being read).
pub fn detail(
    a: &App,
    others: bool,
    p: Palette,
    now: i64,
    w: usize,
    cl: Option<&Result<Changelog, String>>,
) -> Vec<Line<'static>> {
    let says = match a.live_text.as_str() {
        "-" => a.status_text.clone(),
        live => format!("{live}, {}", a.status_text),
    };
    let mut out = vec![
        clip_line(
            Line::from(vec![
                Span::styled(format!("> {}  ", a.project), p.head()),
                Span::styled(says, level(a.level, p)),
            ]),
            w,
        ),
        clip_line(
            Line::styled(format!("  channels {}", a.channels_text), p.dim()),
            w,
        ),
    ];
    let (lead, rest) = a.channels.split_at(a.lead.min(a.channels.len()));
    for r in lead {
        out.extend(channel(r, p, now, w));
    }
    if !rest.is_empty() {
        let n = rest.len();
        // The key sits by the count, so a narrow pane clips the envs, not how to open them.
        let spans = vec![
            Span::styled(
                format!(
                    "{} {n} other channel{} (F)",
                    if others { "-" } else { "+" },
                    if n == 1 { "" } else { "s" }
                ),
                p.head(),
            ),
            Span::styled(format!("  {}", a.others_text), p.dim()),
        ];
        out.push(clip_line(Line::from(spans), w));
        if others {
            for r in rest {
                out.extend(channel(r, p, now, w));
            }
        }
    }
    let plain = Style::default();
    // The releases, newest first: when each was tagged, the one before it, where it reached
    // (hub_core::release_graph), as the web's history table says them.
    if a.history.is_empty() {
        out.extend(wrapped(
            &format!("  {:<LABEL$} ", "Releases"),
            "no tags read",
            p.dim(),
            p,
            w,
        ));
    } else {
        let kind = match a.line.as_str() {
            "build" => "build tags (no release tag yet)",
            _ => "release tags",
        };
        out.extend(wrapped(
            &format!("  {:<LABEL$} ", "Releases"),
            &format!("{} {kind}", a.history.len()),
            p.dim(),
            p,
            w,
        ));
        for h in a.history.iter().take(HISTORY_LINES) {
            let line = format!(
                "    {}  {}  prev {}  reached {}",
                h.tag,
                h.at_text,
                h.prev.as_deref().unwrap_or("-"),
                h.reached_text
            );
            let style = if h.reached.is_empty() { p.dim() } else { plain };
            out.push(clip_line(Line::styled(line, style), w));
        }
        if a.history.len() > HISTORY_LINES {
            let more = a.history.len() - HISTORY_LINES;
            out.push(Line::styled(
                format!("    and {more} older; [ ] walks them in the changelog"),
                p.dim(),
            ));
        }
    }
    let mut part = |label: &str, text: &str, style: Style| {
        out.extend(wrapped(&format!("  {label:<LABEL$} "), text, style, p, w));
    };
    match cl {
        None => part("Changelog", "reading...", p.dim()),
        Some(Err(e)) => part("Changelog", e, p.warn()),
        Some(Ok(c)) => {
            let place = c.position().map_or(String::new(), |i| {
                format!(", {} of {}", i + 1, c.tags.len())
            });
            part(
                "Changelog",
                &format!(
                    "{} ({}, from {}{place}); [ older, ] newer",
                    c.tag, c.range, c.source
                ),
                plain,
            );
            if c.text.is_empty() {
                out.extend(wrapped(
                    "    ",
                    &format!("no merged PRs in {}", c.range),
                    p.dim(),
                    p,
                    w,
                ));
            }
            for line in c.text.lines() {
                if line.trim().is_empty() {
                    out.push(Line::raw(""));
                } else {
                    out.extend(wrapped("    ", line.trim_end(), plain, p, w));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::releases::read;
    use hub_core::session_actions::Runner;

    struct Fake(String);
    impl Runner for Fake {
        fn run(&self, _: &[String]) -> Result<String, String> {
            Ok(self.0.clone())
        }
    }

    const AT: i64 = 1_794_002_400;

    /// binks: prod read and ok, its Steam beta not read. The portfolio: one prod channel in
    /// drift with a tripped watch.
    fn sample() -> Releases {
        let row = |project: &str, id: &str, status: &str| {
            serde_json::json!({
                "project": project, "id": id, "channel": "prod", "implicit": false,
                "pinned": {"value": "v1.2.3", "source": "manifest"},
                "live": {"value": "v1.2.2", "source": "k8s", "image": "reg/app:v1.2.2"},
                "status": status, "probed_at": AT,
                "telemetry": [{"watch": "pmp-probe", "state": "TRIP", "since": AT}],
                "deps": ["unity-core"], "drift_since": AT,
            })
        };
        let mut green = row("binks", "binks-prod", "ok");
        green["telemetry"] = serde_json::json!([]);
        green["drift_since"] = serde_json::Value::Null;
        green["live"]["value"] = "v1.2.3".into();
        let steam = serde_json::json!({
            "project": "binks", "id": "binks-steam-beta", "channel": "beta", "implicit": false,
            "pinned": {"value": null, "source": "tag"},
            "live": {"value": null, "source": "steam", "error": "steam GetAppBetas failed"},
            "status": "unknown",
        });
        let raw = serde_json::json!({
            "generated_epoch": AT,
            "rows": [green, steam, row("kenneth-black-portfolio", "portfolio-preview-eu-west", "drift")],
        });
        read(&Fake(raw.to_string()))
    }

    fn app<'a>(s: &'a Releases, project: &str) -> &'a App {
        s.apps.iter().find(|a| a.project == project).unwrap()
    }

    fn text(l: &Line) -> String {
        l.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn the_header_is_hub_cores_columns() {
        use hub_core::table::Row;
        let lower: Vec<String> = HEADER
            .iter()
            .map(|h| h.to_lowercase().replace(' ', "_").replace("app", "project"))
            .collect();
        let all = App::COLUMNS;
        assert_eq!(lower, all[..HEADER.len()]);
        assert_eq!(all[HEADER.len()..], ["channel", "id"]);
    }

    #[test]
    fn the_status_counts_apps_names_what_it_could_not_read_and_says_the_snapshots_age() {
        let (s, p) = (sample(), Palette::default());
        let st = ReleasesView::default().status(&s, p, AT + 120);
        assert_eq!(text(&st[0]), "What is building, and what is live where?");
        assert!(
            text(&st[1]).starts_with("2 apps: 1 drift, 1 ok"),
            "{}",
            text(&st[1])
        );
        assert!(text(&st[1]).contains("(2m ago)"), "{}", text(&st[1]));
        assert!(!text(&st[1]).contains("older than"));
        assert_eq!(
            text(&st[2]),
            "1 channel not read: steam GetAppBetas failed (1)"
        );
        assert_eq!(st[2].style, p.warn());
        assert!(text(&st[3]).ends_with("2 of 2"), "{}", text(&st[3]));
    }

    #[test]
    fn a_stale_snapshot_is_said_in_amber() {
        let (s, p) = (sample(), Palette::default());
        let st = ReleasesView::default().status(&s, p, AT + STALE_SECS + 1);
        assert!(text(&st[1]).contains("older than 1h"), "{}", text(&st[1]));
        assert_eq!(st[1].spans[2].style, p.warn());
    }

    #[test]
    fn a_failed_read_names_the_error_and_draws_no_rows() {
        let s = Releases {
            summary: "not read".into(),
            errors: vec!["release-state show: no snapshot yet".into()],
            ..Default::default()
        };
        let v = ReleasesView::default();
        let st = v.status(&s, Palette::default(), AT);
        assert_eq!(text(&st[3]), "unread: release-state show: no snapshot yet");
        assert_eq!(
            text(&v.table(&s, Palette::default(), 80, false)[0]),
            "no apps"
        );
    }

    #[test]
    fn each_app_is_one_row_that_fits_eighty_columns_with_what_is_live() {
        let s = sample();
        let t = ReleasesView::default().table(&s, Palette::default(), 80, false);
        let head = text(&t[0]);
        for col in ["APP", "LIVE", "STATUS", "CHANNELS"] {
            assert!(head.contains(col), "{head}");
        }
        assert_eq!(t.len(), 3, "a header and one row per app, not per channel");
        assert!(t.iter().all(|l| text(l).chars().count() <= 80));
        let binks = t.iter().map(text).find(|l| l.contains("binks ")).unwrap();
        assert!(
            binks.contains("v1.2.3 prod")
                && binks.contains("ok")
                && binks.contains("2: 1 not read, 1 ok"),
            "{binks}"
        );
        assert!(
            text(&t[1]).contains("drift"),
            "drift first: {}",
            text(&t[1])
        );
    }

    #[test]
    fn a_wide_table_shows_the_last_deploy() {
        let mut s = sample();
        s.apps[0].last_deploy_text = "11-06 15:00 ok".into();
        let wide = ReleasesView::default().table(&s, Palette::default(), 160, false);
        assert!(text(&wide[0]).contains("LAST DEPLOY"), "{}", text(&wide[0]));
        assert!(
            text(&wide[1]).contains("11-06 15:00 ok"),
            "{}",
            text(&wide[1])
        );
    }

    #[test]
    fn a_channel_not_read_tints_the_channels_cell_amber_and_drift_the_status_red() {
        let (s, p) = (sample(), Palette::default());
        let cells = row(app(&s, "binks"), p);
        assert_eq!(cells[3].style, p.warn());
        assert_eq!(cells[2].style, p.good());
        let drift = row(app(&s, "kenneth-black-portfolio"), p);
        assert_eq!(drift[2].style, p.bad());
        assert_eq!(drift[3].style, Style::default());
    }

    #[test]
    fn a_new_snapshot_keeps_the_selected_app() {
        let s = sample();
        let mut v = ReleasesView::default();
        v.table.view.sort = "project".into();
        v.table.view.dir = hub_core::table::Dir::Asc;
        v.reselect(&s, Some("kenneth-black-portfolio".into()));
        assert_eq!(v.table.sel, 1);
        v.table.sel = 9;
        v.reselect(&s, Some("gone".into()));
        assert_eq!(v.table.sel, 1);
    }

    #[test]
    fn a_query_finds_an_app_by_a_channel_it_folds() {
        let s = sample();
        let mut v = ReleasesView::default();
        v.table.view.q = "binks-steam-beta".into();
        let shown = v.shown(&s);
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].project, "binks");
    }

    fn pane(
        a: &App,
        others: bool,
        cl: Option<&Result<Changelog, String>>,
        w: usize,
    ) -> Vec<String> {
        detail(a, others, Palette::default(), AT, w, cl)
            .iter()
            .map(text)
            .collect()
    }

    #[test]
    fn the_pane_shows_the_headline_env_and_folds_the_others_until_f() {
        let s = sample();
        let binks = app(&s, "binks");
        let shut = pane(binks, false, None, 80);
        assert_eq!(shut[0], "> binks  v1.2.3 prod, ok");
        assert_eq!(shut[1], "  channels 2: 1 not read, 1 ok");
        assert!(
            shut.iter().any(|l| l.starts_with("  prod binks-prod")),
            "{shut:?}"
        );
        let fold = shut
            .iter()
            .find(|l| l.starts_with("+ 1 other channel"))
            .unwrap();
        assert_eq!(fold, "+ 1 other channel (F)  beta 1 not read");
        assert!(
            !shut.iter().any(|l| l.contains("binks-steam-beta")),
            "{shut:?}"
        );
        let open = pane(binks, true, None, 80);
        assert!(
            open.iter().any(|l| l.starts_with("- 1 other channel")),
            "{open:?}"
        );
        let beta = open
            .iter()
            .position(|l| l.contains("binks-steam-beta"))
            .unwrap();
        assert!(open[beta].contains("not read"), "{}", open[beta]);
        assert!(
            open[beta..]
                .iter()
                .any(|l| l.contains("steam GetAppBetas failed")),
            "{open:?}"
        );
    }

    #[test]
    fn the_pane_says_both_sides_every_watch_and_the_deps() {
        let s = sample();
        let lines = pane(app(&s, "kenneth-black-portfolio"), false, None, 60);
        assert!(lines.iter().any(|l| l.contains("drift since")), "{lines:?}");
        assert!(lines
            .iter()
            .any(|l| l.contains("Pinned") && l.contains("v1.2.3 from manifest")));
        assert!(lines
            .iter()
            .any(|l| l.contains("Live") && l.contains("image")));
        assert!(lines
            .iter()
            .any(|l| l.contains("Watch") && l.contains("pmp-probe TRIP")));
        assert!(lines
            .iter()
            .any(|l| l.contains("Deps") && l.contains("unity-core")));
        assert!(
            !lines.iter().any(|l| l.contains("other channel")),
            "one env, no fold"
        );
        assert!(lines.iter().all(|l| l.chars().count() <= 60), "{lines:?}");
    }

    fn changelog(tag: &str, text: &str) -> Changelog {
        Changelog {
            project: "binks".into(),
            tag: tag.into(),
            prev: Some("v1".into()),
            source: "merged PRs".into(),
            range: format!("v1..{tag}"),
            text: text.into(),
            tags: ["v3", "v2", "v1"].map(String::from).to_vec(),
        }
    }

    #[test]
    fn the_pane_ends_in_the_changelog_of_the_tag_on_show_and_where_it_sits_in_the_picker() {
        let s = sample();
        let ok = Ok(changelog(
            "v2",
            "- a fix (#1)\n\n### Added\n- a long line that has to wrap at the pane width (#2)",
        ));
        let lines = pane(app(&s, "binks"), false, Some(&ok), 40);
        let at = lines.iter().position(|l| l.contains("Changelog")).unwrap();
        let head = lines[at..at + 2].join(" ");
        assert!(head.contains("v2") && head.contains("2 of 3"), "{lines:?}");
        assert!(lines.iter().any(|l| l.trim() == "- a fix (#1)"));
        assert!(lines.iter().any(|l| l.trim() == "### Added"));
        assert!(lines.iter().any(|l| l.contains("(#2)")), "{lines:?}");
        assert!(lines.iter().all(|l| l.chars().count() <= 40), "{lines:?}");
    }

    #[test]
    fn the_pane_lists_the_releases_with_when_the_one_before_and_where_each_reached() {
        use hub_core::release_graph::Shipment;
        let s = sample();
        let mut a = app(&s, "binks").clone();
        assert!(pane(&a, false, None, 80)
            .iter()
            .any(|l| l.contains("Releases") && l.contains("no tags read")));
        a.line = "build".into();
        a.history = (0..10)
            .map(|i| Shipment {
                tag: format!("v0.5.0-binks{}", 10 - i),
                at_text: "11-10".into(),
                prev: (i < 9).then(|| format!("v0.5.0-binks{}", 9 - i)),
                reached_text: if i == 0 {
                    "binks-steam-beta 11-10".into()
                } else {
                    "not recorded".into()
                },
                ..Default::default()
            })
            .collect();
        let lines = pane(&a, false, None, 80);
        assert!(
            lines
                .iter()
                .any(|l| l.contains("10 build tags (no release tag yet)")),
            "{lines:?}"
        );
        assert!(
            lines.iter().any(|l| l.contains(
                "v0.5.0-binks10  11-10  prev v0.5.0-binks9  reached binks-steam-beta 11-10"
            )),
            "{lines:?}"
        );
        assert!(lines.iter().any(|l| l.contains("and 2 older")), "{lines:?}");
        let at = |k: &str| lines.iter().position(|l| l.contains(k)).unwrap();
        assert!(
            at("Releases") < at("Changelog"),
            "the history sits above the changelog"
        );
    }

    #[test]
    fn a_changelog_still_being_read_or_refused_or_empty_says_so() {
        let s = sample();
        let a = app(&s, "binks");
        assert!(pane(a, false, None, 80)
            .iter()
            .any(|l| l.contains("Changelog") && l.contains("reading...")));
        let err = Err("release-state: binks has no release tags".to_string());
        assert!(pane(a, false, Some(&err), 100)
            .iter()
            .any(|l| l.contains("binks has no release tags")));
        let none = Ok(changelog("v2", ""));
        assert!(pane(a, false, Some(&none), 80)
            .iter()
            .any(|l| l.trim() == "no merged PRs in v1..v2"));
    }

    #[test]
    fn the_picker_walks_older_and_newer_and_stops_at_the_ends() {
        let mut v = ReleasesView::default();
        assert_eq!(v.pick(1), None, "nothing read, nothing to pick");
        v.cl.read = Some(Ok(changelog("v2", "")));
        assert_eq!(v.pick(1).as_deref(), Some("v1"));
        assert_eq!(v.pick(-1).as_deref(), Some("v3"));
        v.cl.read = Some(Ok(changelog("v1", "")));
        assert_eq!(v.pick(1), None);
        v.cl.read = Some(Err("gone".into()));
        assert_eq!(v.pick(1), None);
    }

    #[test]
    fn the_pane_lists_the_history_and_its_runs_and_says_a_failed_read() {
        use hub_core::releases::{Deploy, Deploys};
        let mut s = sample();
        let d = |version: &str, state: &str| Deploy {
            version: version.into(),
            state: state.into(),
            at: AT,
            url: Some("https://github.test/run/7".into()),
        };
        let at = s.apps.iter().position(|a| a.project == "binks").unwrap();
        s.apps[at].channels[0].deploys = Deploys {
            source: "o/r".into(),
            prev: Some("v1".into()),
            history: vec![d("v3", "fail"), d("v2", "ok")],
            ..Default::default()
        };
        let p = Palette::default();
        let lines = pane(&s.apps[at], false, None, 200);
        assert!(
            lines.iter().any(|l| l.contains("Prev") && l.contains("v1")),
            "{lines:?}"
        );
        assert!(lines.iter().any(|l| l.contains("v2 ok")), "{lines:?}");
        let failed = detail(&s.apps[at], false, p, AT, 200, None)
            .into_iter()
            .find(|l| text(l).contains("v3 fail"))
            .unwrap();
        assert!(
            text(&failed).contains("https://github.test/run/7"),
            "{}",
            text(&failed)
        );
        s.apps[at].channels[0].deploys = Deploys {
            source: "o/r".into(),
            error: Some("gh api failed".into()),
            ..Default::default()
        };
        let lines = pane(&s.apps[at], false, None, 200);
        assert!(
            lines.iter().any(|l| l.contains("gh api failed (o/r)")),
            "{lines:?}"
        );
    }
}
