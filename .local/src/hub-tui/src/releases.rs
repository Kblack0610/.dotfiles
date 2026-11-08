//! The Releases page: every channel from `hub_core::releases::read` on the shared data table
//! (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear), green rows folded to one line,
//! the selected row's versions, watches and dependencies in a pane under the list.

use hub_core::releases::{fold, Deploy, Level, Release, Releases, STALE_SECS};
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

/// `Release::COLUMNS` in capitals, in its order, the sort mark placed by that index. `id` and
/// `where` filter without a column: the channel says the one, the pane the other.
const HEADER: [&str; 9] = [
    "PROJECT",
    "CHANNEL",
    "PINNED",
    "LIVE",
    "STATUS",
    "PREV",
    "LAST DEPLOY",
    "TELEMETRY",
    "DEPS",
];
/// The width of the pane's labels, as the longest one.
const LABEL: usize = 8;
/// PROJECT and CHANNEL at 80 columns and at their widest: each takes half of whatever a wider
/// terminal adds. A version is short enough for one cap, and DEPS only gets what is left.
const PROJECT_FIT: (usize, usize) = (13, 26);
const CHANNEL_FIT: (usize, usize) = (15, 36);
const VERSION_CAP: usize = 11;
const STATUS_CAP: usize = 10;
/// `10-26 15:02 fail`.
const LAST_DEPLOY_CAP: usize = 16;

#[derive(Default)]
pub struct ReleasesView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    /// Whether the pane is open, and how far it is scrolled.
    pub open: bool,
    pub down: usize,
    /// The Builds section under the channels, which `b` hands the keys to.
    pub builds: crate::builds::BuildsView,
}

/// The row a selection stands for, so a new snapshot keeps the same channel selected.
pub type RowId = (String, String);

pub fn row_id(r: &Release) -> RowId {
    (r.project.clone(), r.id.clone())
}

pub(crate) fn level(l: Level, p: Palette) -> Style {
    match l {
        Level::Bad => p.bad(),
        Level::Warn => p.warn(),
        Level::Ok => p.good(),
    }
}

impl ReleasesView {
    fn folded<'a>(&self, s: &'a Releases) -> (Vec<&'a Release>, Option<String>) {
        fold(&self.table.view, self.table.view.apply(&s.rows))
    }

    /// The rows drawn, in the view's sort or the reader's exceptions-first order.
    pub fn open_view(&mut self, q: String) {
        self.table.view = hub_core::table::View {
            q,
            ..Default::default()
        };
        self.table.sel = 0;
        self.open = false;
        self.down = 0;
    }

    pub fn shown<'a>(&self, s: &'a Releases) -> Vec<&'a Release> {
        self.folded(s).0
    }

    /// Move the selection to the row with this id after a read, or keep the index in range.
    pub fn reselect(&mut self, s: &Releases, id: Option<RowId>) {
        let rows = self.shown(s);
        let at = id.and_then(|id| rows.iter().position(|r| row_id(r) == id));
        self.table.keep(at, rows.len());
    }

    /// The tab's question, the summary with the snapshot's age, the view, and what stopped a read.
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
        let mut spans = self.table.status(&s.rows, p);
        spans.push(Span::styled(
            format!("    {} of {}", self.shown(s).len(), s.rows.len()),
            p.dim(),
        ));
        let mut out = vec![
            Line::styled(s.question.clone(), p.head()),
            Line::from(head),
            Line::from(spans),
        ];
        if !s.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", s.errors.join("; ")),
                p.warn(),
            ));
        }
        out
    }

    /// The table: a header line, then one line per shown row. `sel` marks the selected row.
    pub fn table(&self, s: &Releases, p: Palette, w: usize, sel: bool) -> Vec<Line<'static>> {
        let (rows, folded) = self.folded(s);
        if rows.is_empty() {
            let says = match (&folded, s.rows.is_empty()) {
                (Some(_), _) => "nothing needs attention",
                (_, true) => "no channels",
                _ => "no channel matches (/ query, f state, x clears)",
            };
            return vec![Line::styled(says, p.dim())];
        }
        let spare = w.saturating_sub(80) / 2;
        let fit = |(least, most): (usize, usize)| (least + spare).min(most);
        // The mark of a column with no header (`id`, `where`) has nothing to sit on.
        let mark = self
            .table
            .mark::<Release>()
            .filter(|(i, _)| *i < HEADER.len());
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: rows.iter().map(|r| row(r, p)).collect(),
            // PREV and LAST DEPLOY go first when it is narrow: a wide terminal has the room.
            keep: vec![0, 1, 3, 4, 2, 7, 6, 5],
            flex: Some(8),
            flexmin: 12,
            flexkeep: false,
            right: vec![],
            cap: vec![
                (0, fit(PROJECT_FIT)),
                (1, fit(CHANNEL_FIT)),
                (2, VERSION_CAP),
                (3, VERSION_CAP),
                (4, STATUS_CAP),
                (5, VERSION_CAP),
                (6, LAST_DEPLOY_CAP),
            ],
            mark,
        }
        .fit(w, p.head());
        if sel {
            self.table.style(&mut out, p);
        }
        out
    }

    /// Under the table: the fold line, which says how to list what it folded.
    pub fn foot(&self, s: &Releases, p: Palette, w: usize) -> Vec<Line<'static>> {
        let mut out = vec![];
        if let Some(f) = self.folded(s).1 {
            let text = format!("> {f}, f twice lists them");
            let words: Vec<&str> = text.split_whitespace().collect();
            out.extend(
                wrap(&words, " ", w.max(20))
                    .into_iter()
                    .map(|l| clip_line(Line::styled(l, p.dim()), w)),
            );
        }
        out
    }
}

fn row(r: &Release, p: Palette) -> Vec<Cell> {
    let live = if r.status == "drift" {
        cell(r.live_text.clone(), p.bad())
    } else {
        r.live_text.clone().into()
    };
    let tinted = |text: &str, l: Level| match l {
        Level::Ok => text.to_string().into(),
        l => cell(text.to_string(), level(l, p)),
    };
    vec![
        r.project.clone().into(),
        r.label.clone().into(),
        r.pinned_text.clone().into(),
        live,
        cell(r.status.clone(), level(r.status_level, p)),
        r.prev_text.clone().into(),
        tinted(&r.last_deploy_text, r.deploy_level),
        tinted(&r.telemetry_text, r.watch_level),
        r.deps_text.clone().into(),
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

/// The pane: the row's status, then each part that has anything to say, wrapped to `w`.
pub fn detail(r: &Release, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut status = r.status.clone();
    if let Some(t) = r.drift_since {
        status += &format!(" since {}", clock(t, now));
    }
    if let Some(t) = r.probed_at {
        status += &format!(", probed {}", clock(t, now));
    }
    let mut out = vec![
        Line::styled(format!("> {} {}", r.project, r.label), p.head()),
        Line::styled(format!("  {status}"), level(r.level, p)),
    ];
    let mut part = |label: &str, text: &str, style: Style| {
        out.extend(wrapped(&format!("  {label:<LABEL$} "), text, style, p, w));
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
        let raw = serde_json::json!({
            "generated_epoch": AT,
            "rows": [green, row("kenneth-black-portfolio", "portfolio-preview-eu-west", "drift")],
        });
        read(&Fake(raw.to_string()))
    }

    fn text(l: &Line) -> String {
        l.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn the_header_is_hub_cores_columns() {
        use hub_core::table::Row;
        let lower: Vec<String> = HEADER
            .iter()
            .map(|h| h.to_lowercase().replace(' ', "_"))
            .collect();
        let all = Release::COLUMNS;
        assert_eq!(lower, all[..HEADER.len()]);
        assert_eq!(all[HEADER.len()..], ["id", "where"]);
    }

    #[test]
    fn the_status_asks_the_tabs_question_and_says_the_snapshots_age() {
        let s = sample();
        let st = ReleasesView::default().status(&s, Palette::default(), AT + 120);
        assert_eq!(text(&st[0]), "What is building, and what is live where?");
        assert!(text(&st[1]).starts_with("2 channels: 1 drift, 1 ok"));
        assert!(text(&st[1]).contains("(2m ago)"), "{}", text(&st[1]));
        assert!(!text(&st[1]).contains("older than"));
        assert!(text(&st[2]).ends_with("1 of 2"), "{}", text(&st[2]));
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
            "no channels"
        );
    }

    #[test]
    fn the_table_fits_eighty_columns_and_keeps_what_the_row_is_about() {
        let s = sample();
        let mut v = ReleasesView::default();
        v.table.view.state = "all".into();
        v.table.view.sort = "project".into();
        let t = v.table(&s, Palette::default(), 80, false);
        let head = text(&t[0]);
        for col in [
            "PROJECT",
            "CHANNEL",
            "PINNED",
            "LIVE",
            "STATUS",
            "TELEMETRY",
        ] {
            assert!(head.contains(col), "{head}");
        }
        assert!(t.iter().all(|l| text(l).chars().count() <= 80));
        let drift = t.iter().map(text).find(|l| l.contains("drift")).unwrap();
        assert!(drift.contains("v1.2.2") && drift.contains("0/1"), "{drift}");
    }

    #[test]
    fn green_rows_fold_to_one_line_until_a_chip_asks_for_them() {
        let s = sample();
        let mut v = ReleasesView::default();
        assert_eq!(v.shown(&s).len(), 1);
        let foot: Vec<String> = v
            .foot(&s, Palette::default(), 80)
            .iter()
            .map(text)
            .collect();
        assert_eq!(
            foot,
            ["> 1 channel green: 1 ok (binks-prod), f twice lists them"]
        );
        v.table.view.state = "green".into();
        assert_eq!(v.shown(&s)[0].id, "binks-prod");
        assert!(v.foot(&s, Palette::default(), 80).is_empty());
    }

    #[test]
    fn when_everything_is_green_the_table_says_so() {
        let mut s = sample();
        s.rows.retain(|r| r.green());
        let t = ReleasesView::default().table(&s, Palette::default(), 80, false);
        assert_eq!(text(&t[0]), "nothing needs attention");
    }

    #[test]
    fn a_new_snapshot_keeps_the_selected_channel() {
        let s = sample();
        let mut v = ReleasesView::default();
        v.table.view.sort = "project".into();
        v.table.view.dir = hub_core::table::Dir::Asc;
        v.reselect(
            &s,
            Some((
                "kenneth-black-portfolio".into(),
                "portfolio-preview-eu-west".into(),
            )),
        );
        assert_eq!(v.table.sel, 1);
        v.table.sel = 9;
        v.reselect(&s, Some(("gone".into(), "gone".into())));
        assert_eq!(v.table.sel, 1);
    }

    #[test]
    fn a_tripped_watch_is_red_and_a_clean_one_is_not_coloured() {
        let s = sample();
        let p = Palette::default();
        let cells = row(&s.rows[0], p);
        assert_eq!(cells[7].style, p.bad());
        assert_eq!(cells[3].style, p.bad());
        assert_eq!(row(&s.rows[1], p)[7].style, Style::default());
    }

    #[test]
    fn the_pane_says_both_sides_every_watch_and_the_deps() {
        let s = sample();
        let lines: Vec<String> = detail(&s.rows[0], Palette::default(), AT, 60)
            .iter()
            .map(text)
            .collect();
        assert!(lines[1].starts_with("  drift since"), "{lines:?}");
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
        assert!(lines.iter().all(|l| l.chars().count() <= 60), "{lines:?}");
    }

    #[test]
    fn a_wide_table_shows_prev_and_last_deploy_and_the_narrow_one_drops_them_first() {
        let mut s = sample();
        s.rows[0].prev_text = "v1.2.1".into();
        s.rows[0].last_deploy_text = "11-06 15:00 ok".into();
        let mut v = ReleasesView::default();
        v.table.view.state = "all".into();
        let wide = v.table(&s, Palette::default(), 160, false);
        assert!(text(&wide[0]).contains("LAST DEPLOY"), "{}", text(&wide[0]));
        assert!(
            text(&wide[1]).contains("11-06 15:00 ok"),
            "{}",
            text(&wide[1])
        );
        let narrow = text(&v.table(&s, Palette::default(), 80, false)[0]);
        assert!(
            !narrow.contains("PREV") && narrow.contains("LIVE"),
            "{narrow}"
        );
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
        s.rows[0].deploys = Deploys {
            source: "o/r".into(),
            prev: Some("v1".into()),
            history: vec![d("v3", "fail"), d("v2", "ok")],
            ..Default::default()
        };
        let p = Palette::default();
        let pane = detail(&s.rows[0], p, AT, 200);
        let lines: Vec<String> = pane.iter().map(text).collect();
        assert!(
            lines.iter().any(|l| l.contains("Prev") && l.contains("v1")),
            "{lines:?}"
        );
        assert!(lines.iter().any(|l| l.contains("v2 ok")), "{lines:?}");
        let failed = pane.iter().find(|l| text(l).contains("v3 fail")).unwrap();
        assert!(
            text(failed).contains("https://github.test/run/7"),
            "{}",
            text(failed)
        );
        s.rows[0].deploys = Deploys {
            source: "o/r".into(),
            error: Some("gh api failed".into()),
            ..Default::default()
        };
        let lines: Vec<String> = detail(&s.rows[0], p, AT, 200).iter().map(text).collect();
        assert!(
            lines.iter().any(|l| l.contains("gh api failed (o/r)")),
            "{lines:?}"
        );
    }
}
