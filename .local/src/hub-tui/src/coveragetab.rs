//! Projects' Coverage inner tab and a project page's department tabs, both drawn from one
//! `hub_core::departments` read with the same rows and words as agent-web's. Coverage: the head
//! (`Coverage::head`), why a store was not read, then one row per typed project with each department's
//! cell toned by its level, and the legend; the shared table keys work, Enter opens the
//! product's page, Esc clears the view and then goes back to the list. A department tab: what
//! needs the human (worst first), Marketing's outbound items, Legal's checklist, the numbers and
//! the pipelines feeding it.
//! This file reads nothing.

use hub_core::departments::{Cell as DCell, Coverage, Dept, Product};
use hub_core::reading;
use hub_core::table::Row;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::Palette;
use crate::laddertab::{count, dash, head, section, tone};
use crate::projtab::{sec_head, wrapped, ProjView};
use crate::tasktab::TaskView;

/// `Product::COLUMNS`, upper-cased: the lead, type and stage, then one per stages.md department.
const HEADER: [&str; 12] = [
    "PROJECT",
    "TYPE",
    "STAGE",
    "PRODUCT",
    "ENGINEERING",
    "OPS",
    "DESIGN",
    "ANALYTICS",
    "MARKETING",
    "LEGAL",
    "SUPPORT",
    "MONEY",
];

impl ProjView {
    /// Coverage's keys: the shared table keys and moves, Enter opens the product's page, Esc
    /// clears the view and then goes back to the list. False for a key it does not take.
    pub fn ckey(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        cards: &[hub_core::projects::Card],
        c: &Coverage,
        page: usize,
    ) -> bool {
        let n = self.cv.view.apply(&c.products).len();
        if self.cv.key::<Product>(k.code) != Took::No || self.cv.moves(k, n, page) {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                let shown = self.cv.view.apply(&c.products);
                if let Some(r) = shown.get(self.cv.sel.min(shown.len().saturating_sub(1))) {
                    let key = r.key();
                    self.cfocus = false;
                    self.go(tv, cards, &key);
                }
            }
            KeyCode::Esc if !self.cv.is_default() => self.cv.clear(),
            KeyCode::Esc => self.cfocus = false,
            _ => return false,
        }
        true
    }
}

/// A grid cell's style: red and amber by their level, ok green, off dim (nothing is wrong).
fn cell_style(c: DCell, p: Palette) -> Style {
    match c {
        DCell::Off => p.dim(),
        c => crate::releases::level(c.level(), p),
    }
}

fn row(r: &Product, p: Palette) -> Vec<Cell> {
    let mut out: Vec<Cell> = vec![
        r.name.clone().into(),
        dash(&r.kind).into(),
        dash(&r.stage).into(),
    ];
    for id in &Product::COLUMNS[3..] {
        out.push(match r.dept(id) {
            Some(d) => cell(d.cell.word(), cell_style(d.cell, p)),
            None => cell("off", p.dim()),
        });
    }
    out
}

/// Coverage: its head, what could not be read, the grid, the legend; and the selected line.
pub fn page(
    c: Option<&Coverage>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let Some(c) = c else {
        return (
            vec![head("Coverage", "  reading the department stores", p, w)],
            None,
        );
    };
    let shown = pv.cv.view.apply(&c.products);
    let mut out = vec![head(
        "Coverage",
        &format!(
            "  {} products  {}  Enter opens its page",
            count(shown.len(), c.products.len()),
            c.head()
        ),
        p,
        w,
    )];
    if c.red > 0 {
        out[0].spans[0].style = p.bad();
    }
    for s in &c.says {
        out.extend(wrapped("", s, p.warn(), p, w));
    }
    let rows: Vec<Vec<Cell>> = shown.iter().map(|r| row(r, p)).collect();
    let none = if c.products.is_empty() {
        "No typed project (a game, app or infra in project-map) is on the lab."
    } else {
        "No project matches."
    };
    let t = Table {
        header: HEADER.to_vec(),
        keep: vec![0, 9, 11, 2, 4, 5, 7, 8, 10, 3, 6, 1],
        cap: vec![(0, 20)],
        mark: pv.cv.mark::<Product>(),
        ..Default::default()
    };
    let mut at = None;
    section(
        &mut out,
        &mut at,
        &pv.cv,
        pv.cv.status(&c.products, p),
        rows,
        t,
        none,
        true,
        p,
        w,
    );
    out.extend(DataTable::legend::<Product>(p, w));
    out.push(Line::raw(""));
    (out, at)
}

/// One department tab of the product `key`: its head and question, NEEDS YOU, Marketing's
/// OUTBOUND, Legal's CHECKLIST, NUMBERS and PIPELINES. Before the read it says it is reading.
pub fn dept(c: Option<&Coverage>, key: &str, id: &str, p: Palette, w: usize) -> Vec<Line<'static>> {
    let Some(c) = c else {
        return vec![Line::styled("  reading the departments...", p.dim())];
    };
    let Some(d) = c.product(key).and_then(|pr| pr.dept(id)) else {
        let mut out: Vec<Line<'static>> = c
            .says
            .iter()
            .flat_map(|s| wrapped("  ", s, p.warn(), p, w))
            .collect();
        out.push(Line::styled(
            format!("  {key} has no {id} row in Coverage."),
            p.dim(),
        ));
        return out;
    };
    let due = match (&d.due_at, d.required) {
        (Some(s), true) => format!("  required from {s}"),
        (Some(s), false) => format!("  due at {s}"),
        (None, _) => "  no stage requires it".into(),
    };
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(d.title.to_uppercase(), p.head()),
            Span::raw("  "),
            Span::styled(d.cell.word(), cell_style(d.cell, p)),
            Span::styled(due, p.dim()),
        ]),
        w,
    )];
    out.extend(wrapped("  ", &d.question, p.dim(), p, w));
    out.push(Line::raw(""));
    needs(&mut out, d, p, w);
    if d.id == "marketing" {
        outbound(&mut out, d, p, w);
    }
    if !d.checks.is_empty() {
        checklist(&mut out, d, p, w);
    }
    numbers(&mut out, d, p, w);
    pipes(&mut out, d, p, w);
    out
}

fn needs(out: &mut Vec<Line<'static>>, d: &Dept, p: Palette, w: usize) {
    let says = if d.needs.is_empty() {
        "nothing".to_string()
    } else {
        d.needs.len().to_string()
    };
    out.push(sec_head("NEEDS YOU", &says, "", p, w));
    let mut worst: Vec<_> = d.needs.iter().collect();
    worst.sort_by_key(|n| n.level);
    for n in worst {
        out.extend(wrapped("  ", &n.says, tone(n.level, p), p, w));
    }
    out.push(Line::raw(""));
}

/// Marketing's OUTBOUND: the ledger's open items and what went out in 30 days, newest first.
fn outbound(out: &mut Vec<Line<'static>>, d: &Dept, p: Palette, w: usize) {
    let sent = d.outbound.iter().filter(|i| i.state == "sent").count();
    let says = match (d.outbound.is_empty(), d.outbound_says.is_empty()) {
        (true, false) => d.outbound_says.clone(),
        (true, true) => "nothing in the ledger".into(),
        _ => format!("{sent} sent in 30d"),
    };
    out.push(sec_head("OUTBOUND", &says, "", p, w));
    if !d.outbound.is_empty() {
        let rows = d
            .outbound
            .iter()
            .map(|i| {
                let style = match i.state {
                    "sent" => Style::default(),
                    "review" => p.warn(),
                    _ => p.dim(),
                };
                let review = [i.verdict.as_str(), i.reviewed_by.as_str()]
                    .iter()
                    .filter(|s| !s.is_empty())
                    .copied()
                    .collect::<Vec<_>>()
                    .join(" by ");
                vec![
                    i.sent
                        .or(i.created)
                        .map(reading::hm)
                        .unwrap_or_default()
                        .into(),
                    i.channel.clone().into(),
                    i.title.clone().into(),
                    dash(&review).into(),
                    cell(i.state, style),
                    dash(&i.results).into(),
                    dash(&i.url).into(),
                ]
            })
            .collect();
        out.extend(
            Table {
                header: vec![
                    "WHEN", "CHANNEL", "ITEM", "REVIEW", "STATE", "RESULT", "URL",
                ],
                rows,
                keep: vec![2, 4, 5, 1, 0, 3, 6],
                flex: Some(2),
                cap: vec![(2, 32)],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }
    out.push(Line::raw(""));
}

fn checklist(out: &mut Vec<Line<'static>>, d: &Dept, p: Palette, w: usize) {
    use hub_core::departments::{GAP, MET, NOT_YET};
    let met = d.checks.iter().filter(|c| c.state == MET).count();
    out.push(sec_head(
        "CHECKLIST",
        &format!("{met} of {} met", d.checks.len()),
        "",
        p,
        w,
    ));
    let rows = d
        .checks
        .iter()
        .map(|c| {
            let style = match c.state {
                GAP => tone(c.level, p),
                NOT_YET => p.dim(),
                _ => Style::default(),
            };
            vec![
                c.item.into(),
                cell(c.state, style),
                dash(&c.says).into(),
                dash(&c.evidence).into(),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec!["ITEM", "STATE", "SAYS", "EVIDENCE"],
            rows,
            keep: vec![0, 1, 2, 3],
            flex: Some(3),
            cap: vec![(0, 28), (2, 24)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.push(Line::raw(""));
}

fn numbers(out: &mut Vec<Line<'static>>, d: &Dept, p: Palette, w: usize) {
    let says = if d.numbers.is_empty() {
        d.numbers_says.clone()
    } else {
        d.numbers.len().to_string()
    };
    out.push(sec_head("NUMBERS", &says, "", p, w));
    if !d.numbers.is_empty() {
        let rows = d
            .numbers
            .iter()
            .map(|n| vec![n.metric.clone().into(), n.says.clone().into()])
            .collect();
        out.extend(
            Table {
                header: vec!["METRIC", "VALUE"],
                rows,
                keep: vec![0, 1],
                right: vec![1],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }
    if let Some(g) = &d.grafana {
        out.extend(wrapped("  grafana  ", g, Style::default(), p, w));
    }
    out.push(Line::raw(""));
}

fn pipes(out: &mut Vec<Line<'static>>, d: &Dept, p: Palette, w: usize) {
    let says = if d.pipes.is_empty() {
        "none in departments.tsv".to_string()
    } else {
        d.pipes.len().to_string()
    };
    out.push(sec_head("PIPELINES", &says, "", p, w));
    if d.pipes.is_empty() {
        return;
    }
    let rows = d
        .pipes
        .iter()
        .map(|r| {
            let source = if r.shared {
                format!("* {}", r.source)
            } else {
                r.source.clone()
            };
            vec![
                source.into(),
                r.kind.clone().into(),
                cell(dash(&r.last_says), tone(r.level, p)),
                cell(dash(&r.verdict), tone(r.level, p)),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec!["SOURCE", "KIND", "LAST", "VERDICT"],
            rows,
            keep: vec![0, 2, 3, 1],
            cap: vec![(0, 32)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    if d.pipes.iter().any(|r| r.shared) {
        out.push(Line::styled(
            "  * shared: it serves every product, so it is listed, never counted",
            p.dim(),
        ));
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use hub_core::departments::{Check, Need, Number, Pipe, GAP, NOT_YET};
    use hub_core::outbound::Item;
    use hub_core::stages::Department;
    use hub_core::vocab::Level;

    /// The nine departments, as stages.md's Departments table gives them (titles and questions
    /// here are stand-ins; the TUI draws whatever the read carries).
    fn departments() -> Vec<Department> {
        Product::COLUMNS[3..]
            .iter()
            .map(|id| {
                let title = format!("{}{}", id[..1].to_uppercase(), &id[1..]);
                Department {
                    id: id.to_string(),
                    question: format!("Is {title} in hand?"),
                    title,
                    owns: String::new(),
                }
            })
            .collect()
    }

    fn row_of(id: &str, cell: DCell) -> Dept {
        let d = departments().into_iter().find(|d| d.id == id).unwrap();
        Dept {
            id: d.id,
            title: d.title,
            question: d.question,
            cell,
            ..Default::default()
        }
    }

    /// garden, a beta game whose Legal is red; demo, an app nothing feeds.
    pub fn coverage() -> Coverage {
        let mut legal = row_of("legal", DCell::Red);
        legal.due_at = Some("beta".into());
        legal.required = true;
        legal.needs = vec![
            Need {
                level: Level::Warn,
                says: "runner legal-scan last stalled".into(),
            },
            Need {
                level: Level::Bad,
                says: "Privacy policy: answers 404".into(),
            },
        ];
        legal.checks = vec![
            Check {
                item: "Privacy policy",
                state: GAP,
                says: "answers 404".into(),
                evidence: "https://example.com/privacy".into(),
                level: Level::Bad,
            },
            Check {
                item: "Content rating",
                state: NOT_YET,
                says: "no check yet".into(),
                evidence: String::new(),
                ..Default::default()
            },
        ];
        legal.numbers_says = hub_core::reading::NO_DATA.into();
        legal.pipes = vec![
            Pipe {
                source: "legal-scan".into(),
                kind: "runner".into(),
                last_says: "ran 04:30".into(),
                verdict: "WORKED".into(),
                ..Default::default()
            },
            Pipe {
                source: "compliance".into(),
                kind: "skill".into(),
                shared: true,
                ..Default::default()
            },
        ];
        legal.grafana = Some("https://grafana.example/d/kb-project?var-project=garden".into());
        let mut analytics = row_of("analytics", DCell::Ok);
        analytics.numbers = vec![Number {
            metric: "dau".into(),
            value: 12.0,
            says: "12".into(),
        }];
        let mut marketing = row_of("marketing", DCell::Amber);
        marketing.outbound = vec![
            Item {
                id: "261115-aaaaaa".into(),
                channel: "reddit".into(),
                title: "devlog".into(),
                state: "review",
                created: Some(1_794_700_000),
                ..Default::default()
            },
            Item {
                id: "261114-bbbbbb".into(),
                channel: "bluesky".into(),
                title: "clip".into(),
                verdict: "hand".into(),
                reviewed_by: "human".into(),
                url: "https://bsky.app/x".into(),
                results: "9 wishlist adds 7d".into(),
                state: "sent",
                sent: Some(1_794_650_000),
                ..Default::default()
            },
        ];
        let garden = Product {
            profile: "personal".into(),
            name: "garden".into(),
            stage: "beta".into(),
            kind: "game".into(),
            stage_rank: Some(3),
            depts: vec![
                analytics,
                marketing,
                legal,
                row_of("support", DCell::Off),
                row_of("money", DCell::Off),
            ],
        };
        let demo = Product {
            profile: "bnb".into(),
            name: "demo".into(),
            stage: "dev".into(),
            kind: "app".into(),
            stage_rank: Some(1),
            depts: departments()
                .iter()
                .map(|d| row_of(&d.id, DCell::Off))
                .collect(),
        };
        Coverage {
            products: vec![garden, demo],
            red: 1,
            amber: 1,
            off: 7,
            departments: departments(),
            says: vec!["Not read: kb_project_number: no VictoriaMetrics".into()],
        }
    }

    fn text(l: &[Line]) -> Vec<String> {
        l.iter().map(crate::fit::plain).collect()
    }

    #[test]
    fn coverage_says_its_head_then_one_row_a_product_and_the_legend_at_80_columns() {
        let p = Palette::default();
        let c = coverage();
        assert_eq!(c.failing(), 1, "the strip counts products with a red cell");
        let (l, at) = page(Some(&c), &ProjView::default(), p, 80);
        let t = text(&l);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        assert!(
            t[0].starts_with("Coverage  2 products  1 red  |  1 amber  |  7 off"),
            "{t:#?}"
        );
        assert_eq!(l[0].spans[0].style, p.bad(), "a red cell reddens the head");
        assert_eq!(t[1], "Not read: kb_project_number: no VictoriaMetrics");
        let header = t.iter().find(|s| s.starts_with("PROJECT")).expect("header");
        for h in [
            "STAGE",
            "ANALYTICS",
            "MARKETING",
            "LEGAL",
            "SUPPORT",
            "MONEY",
        ] {
            assert!(header.contains(h), "{h} fits at 80: {header}");
        }
        let at = at.expect("the table has the keys");
        assert!(t[at].starts_with("garden"), "{}", t[at]);
        assert!(
            t[at].contains("red") && t[at].contains("amber"),
            "{}",
            t[at]
        );
        let red = l
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content.trim() == "red")
            .expect("a red cell");
        assert_eq!(red.style, p.bad());
        assert!(t.iter().any(|s| s.starts_with("demo")));
        assert!(
            t.iter().any(|s| s.starts_with("ok: ")),
            "the legend: {t:#?}"
        );
        // Before its read it says so; NEGATIVE CONTROL: nothing red, a plain head.
        let (l, at) = page(None, &ProjView::default(), p, 80);
        assert_eq!(text(&l), ["Coverage  reading the department stores"]);
        assert_eq!(at, None);
        let calm = Coverage {
            red: 0,
            ..coverage()
        };
        let (l, _) = page(Some(&calm), &ProjView::default(), p, 80);
        assert_eq!(l[0].spans[0].style, p.head());
    }

    #[test]
    fn enter_opens_the_products_page_and_esc_goes_back() {
        let mut pv = ProjView {
            cfocus: true,
            ..Default::default()
        };
        let mut tv = TaskView::default();
        let c = coverage();
        let cards = [hub_core::projects::Card {
            profile: "bnb".into(),
            name: "demo".into(),
            dept_tabs: vec!["analytics", "legal"],
            ..Default::default()
        }];
        assert!(pv.ckey(&mut tv, KeyEvent::from(KeyCode::Char('j')), &cards, &c, 10));
        assert!(pv.ckey(&mut tv, KeyEvent::from(KeyCode::Enter), &cards, &c, 10));
        assert!(!pv.cfocus, "Enter leaves Coverage for the product");
        assert_eq!(tv.project, Some(("bnb".into(), "demo".into())));
        assert_eq!(
            (pv.inner, pv.tabs.clone()),
            ("overview", vec!["analytics", "legal"])
        );
        let mut pv = ProjView {
            cfocus: true,
            ..Default::default()
        };
        assert!(!pv.ckey(&mut tv, KeyEvent::from(KeyCode::Char('z')), &cards, &c, 10));
        assert!(pv.ckey(&mut tv, KeyEvent::from(KeyCode::Esc), &cards, &c, 10));
        assert!(!pv.cfocus);
    }

    #[test]
    fn a_department_tab_says_needs_then_its_numbers_and_pipelines_at_80_columns() {
        let p = Palette::default();
        let c = coverage();
        let l = dept(Some(&c), "personal/garden", "legal", p, 80);
        let t = text(&l);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        assert_eq!(t[0], "LEGAL  red  required from beta");
        assert_eq!(t[1], "  Is Legal in hand?");
        let at = |want: &str| {
            t.iter()
                .position(|s| s.starts_with(want))
                .unwrap_or_else(|| panic!("{want} in {t:#?}"))
        };
        assert_eq!(t[at("NEEDS YOU")], "NEEDS YOU  2");
        assert_eq!(
            t[at("NEEDS YOU") + 1],
            "  Privacy policy: answers 404",
            "worst first"
        );
        assert_eq!(l[at("NEEDS YOU") + 1].spans[1].style, p.bad());
        assert!(at("NEEDS YOU") < at("CHECKLIST  0 of 2 met"));
        assert!(at("CHECKLIST") < at("NUMBERS  no data"));
        assert!(t[at("Privacy policy")].contains("https://example.com/privacy"));
        assert!(t
            .iter()
            .any(|s| s == "  grafana  https://grafana.example/d/kb-project?var-project=garden"));
        assert!(at("NUMBERS") < at("PIPELINES  2"));
        assert!(
            t[at("legal-scan")].contains("ran 04:30") && t[at("legal-scan")].contains("WORKED")
        );
        assert!(t.iter().any(|s| s.starts_with("* compliance")), "{t:#?}");
        assert!(t.last().unwrap().starts_with("  * shared:"));

        // Analytics: nothing needs you, its numbers, no checklist, no pipeline.
        let t = text(&dept(Some(&c), "personal/garden", "analytics", p, 80));
        assert_eq!(t[at_of(&t, "NEEDS YOU")], "NEEDS YOU  nothing");
        assert!(!t.iter().any(|s| s.starts_with("CHECKLIST")), "{t:#?}");
        assert_eq!(t[at_of(&t, "NUMBERS")], "NUMBERS  1");
        assert!(
            t.iter().any(|s| s.starts_with("dau") && s.ends_with("12")),
            "{t:#?}"
        );
        assert_eq!(t.last().unwrap(), "PIPELINES  none in departments.tsv");

        // Before the read it says it is reading; a product the read lacks says why.
        assert_eq!(
            text(&dept(None, "personal/garden", "legal", p, 80)),
            ["  reading the departments..."]
        );
        let t = text(&dept(Some(&c), "personal/nope", "legal", p, 80));
        assert_eq!(
            t,
            [
                "  Not read: kb_project_number: no VictoriaMetrics",
                "  personal/nope has no legal row in Coverage."
            ]
        );
    }

    #[test]
    fn marketing_lists_its_outbound_items_under_needs_and_the_others_do_not() {
        let p = Palette::default();
        let c = coverage();
        let l = dept(Some(&c), "personal/garden", "marketing", p, 80);
        let t = text(&l);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        let at = at_of(&t, "OUTBOUND");
        assert_eq!(t[at], "OUTBOUND  1 sent in 30d");
        assert!(at_of(&t, "NEEDS YOU") < at && at < at_of(&t, "NUMBERS"));
        let row = |want: &str| t.iter().find(|s| s.contains(want)).cloned().unwrap();
        assert!(row("devlog").contains("review"), "{t:#?}");
        assert!(
            row("clip").contains("hand by human")
                && row("clip").contains("sent")
                && row("clip").contains("9 wishlist adds"),
            "{t:#?}"
        );
        let review = t.iter().position(|s| s.contains("devlog")).unwrap();
        assert!(
            l[review].spans.iter().any(|s| s.style == p.warn()),
            "a review waits: amber"
        );

        // An empty ledger says so, and only Marketing has the section.
        let t = text(&dept(Some(&c), "bnb/demo", "marketing", p, 80));
        assert_eq!(t[at_of(&t, "OUTBOUND")], "OUTBOUND  nothing in the ledger");
        let t = text(&dept(Some(&c), "personal/garden", "legal", p, 80));
        assert!(!t.iter().any(|s| s.starts_with("OUTBOUND")), "{t:#?}");
    }

    fn at_of(t: &[String], want: &str) -> usize {
        t.iter().position(|s| s.starts_with(want)).unwrap()
    }
}
