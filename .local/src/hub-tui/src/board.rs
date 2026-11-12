//! The Prometheus pages of `hub` (Home's infra body, CI, Machines), laid out from one
//! `hub_core::infra::Infra` answer. It judges nothing: statuses are `cc:*` rules and rows are the
//! machines, pools and CI rows `hub_core` builds once for both surfaces (`infratables` draws
//! them), so it cannot disagree with Grafana or agent-web's Infra tab.

use std::collections::HashMap;

use hub_core::infra::Infra;
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::{dur, Palette};
use crate::infratables::InfraTables;

pub struct Board<'a> {
    infra: &'a Infra,
    p: Palette,
    /// `cc:<name>` or `cc:<name>/<domain|host|pool|site>` -> value.
    v: HashMap<String, f64>,
}

impl<'a> Board<'a> {
    pub fn new(infra: &'a Infra, p: Palette) -> Board<'a> {
        let mut v = HashMap::new();
        for s in infra.get("cc") {
            let name = s.label("__name__");
            let sub = if name == "cc:domain_status" {
                s.label("domain")
            } else {
                ["host", "pool", "site"]
                    .into_iter()
                    .map(|k| s.label(k))
                    .find(|v| !v.is_empty())
                    .unwrap_or("")
            };
            let key = if sub.is_empty() {
                name.to_string()
            } else {
                format!("{name}/{sub}")
            };
            if let Some(x) = s.value {
                v.insert(key, x);
            }
        }
        Board { infra, p, v }
    }

    fn get(&self, k: &str) -> Option<f64> {
        self.v.get(k).copied()
    }
    /// A count, or ? when the rule is absent.
    fn num(&self, k: &str) -> String {
        self.get(k).map_or("?".into(), |x| format!("{x:.0}"))
    }
    /// The sum of the per-pool or per-host values of these rules, or ? when none has any.
    fn sum(&self, rules: &[&str]) -> String {
        let mut t = None;
        for r in rules {
            let pre = format!("{r}/");
            for (k, x) in &self.v {
                if k.starts_with(&pre) {
                    t = Some(t.unwrap_or(0.0) + x);
                }
            }
        }
        t.map_or("?".into(), |x: f64| format!("{x:.0}"))
    }
    fn dim(&self, s: String) -> Line<'static> {
        Line::styled(s, self.p.dim())
    }

    /// `ci local 13/22 cloud 4/4 +2 github-hosted, waiting 5`, from the cc:site_* rules (which
    /// fold the local gates into local) and GitHub's own runners. A site with no slots up has no
    /// series, so it reads 0/0 once any site has one; with none at all, ?.
    fn ci_sites(&self) -> String {
        let any = self.v.keys().any(|k| k.starts_with("cc:site_slots/"));
        let site = |r: &str, s: &str| match self.get(&format!("{r}/{s}")) {
            Some(x) => format!("{x:.0}"),
            None if any => "0".into(),
            None => "?".into(),
        };
        let mut out = format!(
            "ci local {}/{} cloud {}/{}",
            site("cc:site_busy", "local"),
            site("cc:site_slots", "local"),
            site("cc:site_busy", "cloud"),
            site("cc:site_slots", "cloud")
        );
        let hosted = self.get("cc:github_hosted_running").unwrap_or(0.0);
        if hosted > 0.0 {
            out += &format!(" +{hosted:.0} github-hosted");
        }
        out + &format!(
            ", waiting {}",
            self.sum(&["cc:pool_waiting", "cc:host_local_queued"])
        )
    }

    /// The machinery's headline numbers. The status tag, what needs you and the domain strip
    /// went to the Home sections above (`hub_core::home`).
    pub fn numbers(&self, w: usize) -> Vec<Line<'static>> {
        let mut items = vec![
            format!(
                "nodes {}/{}",
                self.num("cc:k3s_nodes_ready"),
                self.num("cc:k3s_nodes_total")
            ),
            format!(
                "heartbeats {}/{}",
                self.num("cc:machines_up"),
                self.num("cc:machines_total")
            ),
            self.ci_sites(),
            format!("agent runners {} failed", self.num("cc:runners_failed")),
            format!(
                "watches {}/{} tripped",
                self.num("cc:watches_tripped"),
                self.num("cc:watches_total")
            ),
            hub_core::costs::spend_badge(),
        ];
        if self.get("cc:agent_sessions_running").is_some() {
            items.push(format!(
                "agent sessions {}",
                self.num("cc:agent_sessions_running")
            ));
        }
        wrap(&items, "  ", w)
            .into_iter()
            .map(|l| clip_line(self.dim(l), w))
            .collect()
    }

    /// The CI head: slots, busy and the queue (`hub_core::ci`), the last day's failures, and a
    /// red line per kind of job no online runner can take, naming the missing label.
    pub fn ci_head(&self, w: usize) -> Vec<Line<'static>> {
        let ci = &self.infra.ci;
        let secs = |v: i64| dur(v as f64);
        let failed = ci.done.bad;
        let mut head = vec![
            Span::styled("CI RUNNERS", self.p.head()),
            Span::raw(format!("  {}", ci.head(secs))),
        ];
        if failed > 0 {
            head.push(Span::styled(format!("  failed 24h {failed}"), self.p.bad()));
        } else if ci.busy + ci.queued == 0 {
            head.push(Span::styled(
                "  green: nothing waiting or failed in 24h",
                self.p.good(),
            ));
        }
        let mut out = vec![clip_line(Line::from(head), w)];
        for line in &ci.red {
            out.push(clip_line(
                Line::styled(format!("! {line}"), self.p.bad()),
                w,
            ));
        }
        out
    }
}

/// A section of the Infra page: its `hub_core::layout` name and its lines.
pub type Section = (&'static str, Vec<Line<'static>>);

/// The Infra page as named sections in `hub_core::layout` order, less `jobs`, which the app
/// draws from its own read; the app shows them by inner tab, and `inner` is the one shown, whose
/// table has the keys (`infratables`). What is red is the Alerts tab's (`hub_core::alerts`);
/// here the headline numbers lead the machines, then what runs, waits and finished. A failed
/// read is one section with the error and nothing else: a board never leaves the last (maybe
/// green) numbers up.
pub fn infra(
    infra: &Infra,
    p: Palette,
    now: i64,
    w: usize,
    tables: &InfraTables,
    inner: &str,
) -> Vec<Section> {
    if !infra.ok {
        return vec![(
            "machines",
            vec![
                Line::from(vec![
                    Span::styled(" QUERY FAILED ", p.status(Some(2.0)).0),
                    Span::raw(format!(
                        " {}",
                        infra
                            .error
                            .as_deref()
                            .unwrap_or("Prometheus did not answer")
                    )),
                ]),
                Line::raw(""),
                Line::styled(
                    format!(
                        "Nothing is shown rather than old numbers. Retrying every {}s; r retries now.",
                        crate::app::PROM_REFRESH.as_secs()
                    ),
                    p.dim(),
                ),
            ],
        )];
    }
    let b = Board::new(infra, p);
    let blank = || Line::raw("");
    let table = |name| tables.draw(infra, name, inner, p, now, w);
    let mut machines = b.numbers(w);
    machines.push(blank());
    machines.extend(table("machines"));
    let mut ci = b.ci_head(w);
    for name in ["runners", "queued", "finished"] {
        ci.push(blank());
        ci.extend(table(name));
    }
    let sections = vec![
        ("machines", machines),
        ("pools", table("pools")),
        ("ci", ci),
    ];
    sections
        .into_iter()
        .map(|(n, ls)| (n, ls.into_iter().map(|l| clip_line(l, w)).collect()))
        .collect()
}

/// The CI head and the runners and queued tables, plain: what `hub ci` prints.
pub fn ci_runners(infra: &Infra, p: Palette, w: usize) -> Vec<Line<'static>> {
    let t = InfraTables::default();
    let mut out = Board::new(infra, p).ci_head(w);
    for name in ["runners", "queued"] {
        out.push(Line::raw(""));
        out.extend(t.draw(infra, name, "", p, 0, w));
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    //! The bash board's bats suite (command_center.bats), ported onto the same fixture data.
    use super::*;
    use crate::fit::plain;
    use hub_core::prom::Series;
    use serde_json::{json, Value};

    fn series(rows: Vec<(Value, &str)>) -> Vec<Series> {
        let res: Vec<Value> = rows
            .into_iter()
            .map(|(m, v)| json!({"metric": m, "value": [0, v]}))
            .collect();
        hub_core::prom::flatten(&json!({"status": "success", "data": {"result": res}})).unwrap()
    }

    fn runner(
        host: &str,
        name: &str,
        state: &str,
        v: &'static str,
        kw: Value,
    ) -> (Value, &'static str) {
        let mut m = json!({"host": host, "name": name, "state": state, "pool": "unity"});
        for (k, x) in kw.as_object().unwrap() {
            m[k] = x.clone();
        }
        (m, v)
    }

    fn fin(repo: &str, wf: &str, by: &[(&str, &'static str)]) -> Vec<(Value, &'static str)> {
        by.iter()
            .map(|(c, n)| (json!({"repo": repo, "workflow": wf, "conclusion": c}), *n))
            .collect()
    }

    /// The bats fixture: razer-laptop with four unity runners (three busy), an offline
    /// mac-mini, a queue for #412, a stuck run, and a day of finished runs.
    pub(crate) fn fixture() -> Infra {
        let mut cc = vec![
            (json!({"__name__": "cc:overall_status"}), "2"),
            (
                json!({"__name__": "cc:domain_status", "domain": "k3s"}),
                "0",
            ),
            (
                json!({"__name__": "cc:domain_status", "domain": "llm"}),
                "2",
            ),
            (json!({"__name__": "cc:k3s_nodes_ready"}), "8"),
            (json!({"__name__": "cc:k3s_nodes_total"}), "8"),
            (json!({"__name__": "cc:asks_open"}), "0"),
            (json!({"__name__": "cc:sessions_attention"}), "0"),
        ];
        for (n, v) in [
            ("cc:host_cpu_busy_ratio", "0.91"),
            ("cc:host_cpu_busy_ratio:avg6h", "0.31"),
            ("cc:host_load1", "9.84"),
            ("cc:host_cores", "16"),
            ("cc:host_mem_used_ratio", "0.6"),
            ("cc:host_temp_c", "84.2"),
        ] {
            cc.push((json!({"__name__": n, "host": "razer-laptop"}), v));
        }
        cc.push((
            json!({"__name__": "cc:host_cpu_busy_ratio", "host": "mac-mini"}),
            "0.03",
        ));
        // windows has slots and nothing waiting: it must read 0, never vanish; and no
        // finished series, so DONE and PASS read -, never 0.
        for (pool, slots, busy, waiting, oldest, done, ratio) in [
            ("unity", "4", "3", "3", Some("8880"), Some("72"), "0.24"),
            ("light", "2", "0", "1", Some("60"), Some("40"), "0.8"),
            ("windows", "1", "0", "0", None, None, ""),
        ] {
            cc.push((json!({"__name__": "cc:pool_slots", "pool": pool}), slots));
            cc.push((json!({"__name__": "cc:pool_busy", "pool": pool}), busy));
            cc.push((
                json!({"__name__": "cc:pool_waiting", "pool": pool}),
                waiting,
            ));
            if let Some(o) = oldest {
                cc.push((
                    json!({"__name__": "cc:pool_oldest_wait_seconds", "pool": pool}),
                    o,
                ));
            }
            if let Some(d) = done {
                cc.push((json!({"__name__": "cc:pool_done_24h", "pool": pool}), d));
                cc.push((
                    json!({"__name__": "cc:pool_pass_ratio_24h", "pool": pool}),
                    ratio,
                ));
            }
        }
        cc.push((json!({"__name__": "cc:site_slots", "site": "local"}), "7"));
        cc.push((json!({"__name__": "cc:site_busy", "site": "local"}), "3"));
        let runners = vec![
            runner(
                "razer-laptop",
                "razer-1",
                "running",
                "2160",
                json!({"repo": "unity-core-playground", "pr": "412",
                "branch": "feat/apociseum-third", "job_name": "PlayMode 2", "workflow": "Tests", "title": "Apociseum third arena"}),
            ),
            runner(
                "razer-laptop",
                "razer-2",
                "running",
                "300",
                json!({"repo": "platform", "branch": "develop",
                "job_name": "E2E", "workflow": "E2E", "title": "E2E"}),
            ),
            runner("razer-laptop", "razer-3", "idle", "0", json!({})),
            runner(
                "razer-laptop",
                "razer-4",
                "running",
                "5580",
                json!({"repo": "unity-core-playground", "pr": "1110",
                "branch": "feat/automatch-phase", "job_name": "PlayMode 4", "workflow": "Tests", "title": "Tests"}),
            ),
            runner(
                "mac-mini",
                "mini-1",
                "offline",
                "0",
                json!({"pool": "macos"}),
            ),
        ];
        let mut waiting: Vec<(Value, &str)> = ["600", "8880", "120"]
            .into_iter()
            .map(|v| (json!({"pool": "unity", "repo": "unity-core-playground", "pr": "412", "stuck": "false",
                "branch": "feat/apociseum-third"}), v))
            .collect();
        waiting.push((
            json!({"pool": "light", "repo": "platform", "branch": "develop", "stuck": "false"}),
            "60",
        ));
        // A run queued 45 days with no jobs: DOWN's, and never the queue's age.
        waiting.push((
            json!({"pool": "other", "repo": "platform", "branch": "develop", "stuck": "true"}),
            "3949200",
        ));
        let finished = [
            fin(
                "unity-core-playground",
                "Tests",
                &[("success", "12"), ("failure", "38"), ("cancelled", "22")],
            ),
            fin(
                "unity-core-playground",
                "Game catalog",
                &[("failure", "39")],
            ),
            fin("unity-core-playground", "Multi", &[("failure", "14")]),
            fin(
                "unity-core-playground",
                "Docs",
                &[("success", "5"), ("cancelled", "3")],
            ),
            fin("platform", "Checks", &[("success", "30")]),
            fin("platform", "E2E", &[("success", "8")]),
        ]
        .concat();
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert("cc", series(cc));
        i.instant.insert("runners", series(runners));
        i.instant.insert("waiting", series(waiting));
        i.instant.insert("finished", series(finished));
        i.instant.insert("api", series(vec![(json!({}), "1")]));
        i.instant
            .insert("exporter_up", series(vec![(json!({}), "1")]));
        i.instant.insert("gates", vec![]);
        i.instant.insert(
            "red",
            series(vec![(json!({"item": "watch mac_studio_mlx"}), "1")]),
        );
        i
    }

    /// Two gates on the workstation, one on a branch with a PR in the queue (#412).
    pub(crate) fn with_gates(i: &mut Infra) {
        let g = |wt: &str, br: &str, plat: &str, repo: &str, v: &'static str| {
            (
                json!({"__name__": "cc:host_local_gate", "host": "workstation", "worktree": wt,
                "branch": br, "platform": plat, "repo": repo}),
                v,
            )
        };
        i.instant.insert(
            "gates",
            series(vec![
                g(
                    "unity-core-playground-agent-7",
                    "feat/apociseum-third",
                    "PlayMode",
                    "unity-core-playground",
                    "2160",
                ),
                g(
                    "unity-core-playground-agent-9",
                    "fix/x",
                    "EditMode",
                    "",
                    "45",
                ),
            ]),
        );
    }

    /// The workstation publishes 10 local slots, 2 busy, 1 run queued for one.
    fn with_local_slots(i: &mut Infra) {
        let cc = i.instant.get_mut("cc").unwrap();
        for (n, v) in [
            ("cc:host_local_slots", "10"),
            ("cc:host_local_open_slots", "4"),
            ("cc:host_local_busy", "2"),
            ("cc:host_local_queued", "1"),
            ("cc:host_local_done_24h", "14"),
            ("cc:host_local_pass_ratio_24h", "0.5"),
        ] {
            cc.extend(series(vec![(
                json!({"__name__": n, "host": "workstation"}),
                v,
            )]));
        }
    }

    /// The fixture with its CI join built, as `gather` leaves it.
    pub(crate) fn built(i: &Infra) -> Infra {
        let mut j = i.clone();
        j.ci = hub_core::ci::build(&j);
        (j.machines, j.pools) = hub_core::machines::build(&j);
        j
    }

    /// The whole Infra page as plain text.
    fn text(i: &Infra, w: usize) -> String {
        infra(
            &built(i),
            Palette { no_color: true },
            0,
            w,
            &InfraTables::default(),
            "",
        )
        .into_iter()
        .flat_map(|(_, ls)| ls)
        .map(|l| plain(&l))
        .collect::<Vec<_>>()
        .join("\n")
    }
    fn squash(s: &str) -> String {
        s.split_whitespace().collect::<Vec<_>>().join(" ")
    }
    /// A line whose words, blanks squashed, are exactly these.
    fn has_line(out: &str, want: &str) -> bool {
        out.lines().any(|l| squash(l) == want)
    }
    fn has(out: &str, want: &str) -> bool {
        squash(out).contains(&squash(want))
    }
    fn assert_line(out: &str, want: &str) {
        assert!(has_line(out, want), "no line {want:?} in:\n{out}");
    }

    /// The whole Infra page's styled lines at 160 columns.
    fn all_lines(i: &Infra, p: Palette) -> Vec<Line<'static>> {
        infra(&built(i), p, 0, 160, &InfraTables::default(), "")
            .into_iter()
            .flat_map(|s| s.1)
            .collect()
    }
    /// One Infra section (`hub_core::layout` name) as plain text.
    fn tab(i: &Infra, name: &str, w: usize) -> String {
        infra(
            &built(i),
            Palette { no_color: true },
            0,
            w,
            &InfraTables::default(),
            "",
        )
        .into_iter()
        .find(|s| s.0 == name)
        .map(|(_, ls)| ls.iter().map(plain).collect::<Vec<_>>().join("\n"))
        .unwrap_or_default()
    }

    /// aws-burst-1 in the cloud with one of two unity runners busy, and 3 jobs on GitHub's own.
    fn with_cloud(i: &mut Infra, hosted: &'static str) {
        let r = i.instant.get_mut("runners").unwrap();
        r.extend(series(vec![
            runner(
                "aws-burst-1",
                "aws-1",
                "running",
                "120",
                json!({"site": "cloud", "repo": "unity-core-playground", "pr": "9", "job_name": "EditMode"}),
            ),
            runner("aws-burst-1", "aws-2", "idle", "0", json!({"site": "cloud"})),
        ]));
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            (json!({"__name__": "cc:site_slots", "site": "cloud"}), "2"),
            (json!({"__name__": "cc:site_busy", "site": "cloud"}), "1"),
            (json!({"__name__": "cc:github_hosted_running"}), hosted),
        ]));
    }

    #[test]
    fn the_ci_runners_section_lists_each_slot_with_its_job_time_and_the_queue_beside_it() {
        let i = fixture();
        let ci = tab(&i, "ci", 160);
        assert!(
            ci.starts_with("CI RUNNERS  2 hosts, 4 slots, 3 busy, 4 waiting (oldest 2h28m)  failed 24h 91\n\nRUNNERS  all 5  busy 3  idle 1  off 1  late 1\nHOST"),
            "{ci}"
        );
        // A late job carries the bang; each slot names its pool, job and ref.
        assert_line(
            &ci,
            "razer-laptop 4 busy unity 1h33m! - PlayMode 4 unity-core-playground#1110",
        );
        assert_line(
            &ci,
            "razer-laptop 1 busy unity 36m - PlayMode 2 unity-core-playground#412",
        );
        // No PR shows the branch; an idle slot and an offline host say so.
        assert_line(&ci, "razer-laptop 2 busy unity 5m - E2E develop");
        assert_line(&ci, "razer-laptop 3 idle unity - - - -");
        assert_line(&ci, "mac-mini 1 off macos - - - -");
        // The queue names each job's wait, what it needs and who can take it.
        assert_line(&ci, "JOB POOL REF N WAIT NEEDS CAN RUN ON");
    }

    #[test]
    fn infra_sections_come_in_layout_order_and_ci_runners_leads_with_its_counts() {
        let i = fixture();
        let names: Vec<_> = infra(
            &i,
            Palette { no_color: true },
            0,
            160,
            &InfraTables::default(),
            "",
        )
        .into_iter()
        .map(|s| s.0)
        .collect();
        // Jobs, Runs and Tests are the app's, drawn from their own reads.
        let want: Vec<_> = hub_core::layout::resolve("infra")
            .unwrap()
            .sections
            .iter()
            .copied()
            .filter(|s| !["jobs", "runs", "tests"].contains(s))
            .collect();
        assert_eq!(names, want);
        let ci = tab(&i, "ci", 160);
        assert!(
            ci.starts_with("CI RUNNERS  2 hosts, 4 slots, 3 busy, 4 waiting"),
            "{ci}"
        );
        assert!(has(&ci, "failed 24h"), "{ci}");
        // Exceptions lead: the slots and the queue before the day's results and the runs.
        let at = |w: &str| ci.find(w).unwrap_or_else(|| panic!("no {w} in {ci}"));
        assert!(at("HOST") < at("WAITING") && at("WAITING") < at("FINISHED 24H"));
    }

    #[test]
    fn a_quiet_ci_is_one_green_line_and_no_empty_tables() {
        let mut i = fixture();
        for q in ["runners", "gates", "waiting", "finished"] {
            i.instant.insert(q, vec![]);
        }
        let ci = tab(&i, "ci", 160);
        assert_line(
            &ci,
            "CI RUNNERS 0 hosts, 0 slots, 0 busy, 0 waiting green: nothing waiting or failed in 24h",
        );
        // An empty table is its title and why, on one line, with no header or chips.
        assert_line(&ci, "RUNNERS no runner reports");
        assert_line(&ci, "WAITING nothing waiting");
        assert_line(
            &ci,
            "FINISHED 24H no finished-run series yet (runner exporter)",
        );
        assert!(!ci.contains("HOST") && !ci.contains("all 0"), "{ci}");
    }

    #[test]
    fn cloud_runners_and_the_governor_read_from_their_series() {
        let mut i = fixture();
        with_cloud(&mut i, "0");
        i.instant.insert(
            "power",
            series(vec![
                (json!({"__name__": "ci_governor_power_state", "host": "aws-burst-1", "state": "running", "reason": "deep queue"}), "1"),
                (json!({"__name__": "ci_governor_power_hours_today", "host": "aws-burst-1"}), "1.5"),
                (json!({"__name__": "ci_governor_power_max_hours_day", "host": "aws-burst-1"}), "6"),
                (json!({"__name__": "ci_governor_power_override", "host": "aws-burst-1", "action": "none"}), "0"),
            ]),
        );
        i.instant.insert(
            "governor",
            series(vec![
                (json!({"__name__": "ci_governor_up"}), "1"),
                (json!({"__name__": "ci_governor_ok"}), "1"),
                (json!({"__name__": "ci_governor_queue"}), "7"),
                (json!({"__name__": "ci_governor_live", "host": "razer-laptop"}), "1"),
                (json!({"__name__": "ci_governor_decision", "host": "razer-laptop", "verdict": "busy", "action": "admit"}), "1"),
                (json!({"__name__": "ci_governor_admitted", "host": "razer-laptop"}), "4"),
                (json!({"__name__": "ci_governor_live", "host": "mac-mini"}), "0"),
            ]),
        );
        // Governor and power are machine columns now; the cloud host is a machine row.
        let m = tab(&i, "machines", 200);
        assert!(
            has(&m, "MACHINES all 3 busy 2 no reading 1 cloud 1 governed 3"),
            "{m}"
        );
        assert!(has(&m, "aws-burst-1 cloud no reading 1/2"), "{m}");
        assert!(
            has(&m, "EditMode unity-core-playground#9 - running 1.5/6h -"),
            "{m}"
        );
        assert!(has(&m, "live, admit - -"), "{m}");
        assert!(has(&m, "- dry run - -"), "{m}");
        // No series: the columns read -, and no Cloud or Governor section is drawn.
        let none = tab(&fixture(), "machines", 200);
        assert!(
            !none.contains("live") && !none.contains("running 1"),
            "{none}"
        );
        assert_eq!(tab(&i, "cloud", 160), "");
        assert_eq!(tab(&i, "governor", 160), "");
    }

    #[test]
    fn the_header_counts_local_and_cloud_and_github_hosted_jobs() {
        let mut i = fixture();
        with_cloud(&mut i, "3");
        assert!(has(
            &text(&i, 160),
            "ci local 3/7 cloud 1/2 +3 github-hosted, waiting 4"
        ));
        // No GitHub-hosted job running says nothing about them.
        let mut i = fixture();
        with_cloud(&mut i, "0");
        let out = text(&i, 160);
        assert!(has(&out, "ci local 3/7 cloud 1/2, waiting 4"), "{out}");
        assert!(!out.contains("github-hosted"));
    }

    #[test]
    fn a_site_with_no_slot_up_reads_zero_and_no_site_rule_at_all_reads_unknown() {
        assert!(has(
            &text(&fixture(), 160),
            "ci local 3/7 cloud 0/0, waiting 4"
        ));
        let mut i = fixture();
        i.instant
            .get_mut("cc")
            .unwrap()
            .retain(|s| !s.label("__name__").starts_with("cc:site_"));
        assert!(has(&text(&i, 160), "ci local ?/? cloud ?/?, waiting 4"));
    }

    #[test]
    fn a_withheld_runner_is_no_slot_and_shows_apart() {
        let mut i = fixture();
        i.instant.insert(
            "withheld",
            series(vec![(
                json!({"name": "razer-3", "host": "razer-laptop", "pool": "unity"}),
                "1",
            )]),
        );
        let out = text(&i, 200);
        assert!(
            has(
                &out,
                "razer-laptop local up 3/3 91% 31% 9.8/16 60% 84C - unity 3/3 unity withheld 0/1"
            ),
            "{out}"
        );
        assert_line(
            &out,
            "razer-laptop 3 withheld unity - - the governor holds it back -",
        );
    }

    #[test]
    fn a_machines_row_carries_where_busy_load_6h_cpu_and_busy_of_its_slots_per_pool() {
        let mut i = fixture();
        with_cloud(&mut i, "0");
        let out = tab(&i, "machines", 200);
        assert_line(
            &out,
            "MACHINE WHERE STATE BUSY CPU 6H LOAD MEM TEMP DISK POOLS RUNNING GOVERNOR POWER UP",
        );
        assert!(
            has(
                &out,
                "razer-laptop local up 3/4 91% 31% 9.8/16 60% 84C - unity 3/4 PlayMode 4"
            ),
            "{out}"
        );
        assert!(
            has(
                &out,
                "aws-burst-1 cloud no reading 1/2 - - - - - - unity 1/2"
            ),
            "{out}"
        );
        // A host with one reading is up; its other columns read -, never 0.
        assert_line(&out, "mac-mini local up - +1 off 3% - - - - - - - - - -");
    }

    #[test]
    fn queues_show_waiting_oldest_done_pass_longest_queue_first() {
        let out = tab(&fixture(), "pools", 160);
        assert!(
            out.starts_with("POOLS  all 3  waiting 2  busy 1  idle 2\n"),
            "{out}"
        );
        assert_line(&out, "unity 4 3 - 3 2h28m 72 24% razer-laptop");
        assert_line(&out, "light 2 0 - 1 1m 40 80% -");
        assert_line(&out, "windows 1 0 - 0 - - - -");
        let order: Vec<&str> = out
            .lines()
            .skip(2)
            .map(|l| l.split_whitespace().next().unwrap())
            .collect();
        assert_eq!(order, ["unity", "light", "windows"]);
    }

    #[test]
    fn a_job_past_an_hour_is_marked_and_amber() {
        let i = fixture();
        let out = text(&i, 160);
        assert_line(
            &out,
            "razer-laptop 4 busy unity 1h33m! - PlayMode 4 unity-core-playground#1110",
        );
        assert!(!out.contains("36m!"));
        let p = Palette::default();
        let lines = all_lines(&i, p);
        let span = lines
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content.trim() == "1h33m!")
            .unwrap();
        assert_eq!(span.style, p.warn());
    }

    #[test]
    fn a_stuck_run_is_out_of_the_queue_and_its_oldest_wait() {
        // Its red row is the Alerts tab's (`alertstab` tests).
        let out = text(&fixture(), 160);
        assert!(has(&out, "4 waiting (oldest 2h28m)"), "{out}");
        assert!(!out.contains("RED NOW"), "{out}");
    }

    #[test]
    fn the_queue_groups_by_pool_repo_pr_and_branch_with_count_and_oldest_wait() {
        let out = text(&fixture(), 160);
        // The queue rows carry the PR or branch, the count of identical jobs and the oldest wait.
        assert_line(&out, "- unity unity-core-playground#412 3 2h28m - -");
        assert_line(&out, "- light develop 1 1m - -");
    }

    #[test]
    fn finished_lists_the_red_first_with_cancels_apart_and_the_green_after() {
        let out = tab(&fixture(), "ci", 160);
        // Pass is success of success + failure, so Tests' 22 cancels are not failures.
        assert!(
            has(
                &out,
                "FINISHED 24H 171 runs, 38% pass, 91 failed, 25 cancelled all 6 red 4 green 2"
            ),
            "{out}"
        );
        let order: Vec<&str> = out
            .lines()
            .skip_while(|l| !l.starts_with("REPO "))
            .skip(1)
            .take_while(|l| !l.trim().is_empty())
            .map(|l| l.split_whitespace().nth(1).unwrap())
            .collect();
        assert_eq!(order, ["Game", "Multi", "Tests", "Docs", "Checks", "E2E"]);
        assert_line(&out, "unity-core-playground Game catalog - - 39 39 0");
        assert_line(&out, "unity-core-playground Tests - - 72 38 22");
        assert_line(&out, "unity-core-playground Docs - - 8 0 3");
        assert_line(&out, "platform Checks - - 30 0 0");
    }

    #[test]
    fn finished_with_no_series_says_so() {
        let mut i = fixture();
        i.instant.insert("finished", vec![]);
        assert!(has(
            &text(&i, 160),
            "FINISHED 24H no finished-run series yet (runner exporter)"
        ));
    }

    #[test]
    fn a_pass_rate_is_red_under_70_and_amber_under_90() {
        let p = Palette::default();
        let lines = all_lines(&fixture(), p);
        let style = |t: &str| {
            lines
                .iter()
                .flat_map(|l| &l.spans)
                .find(|s| s.content == t)
                .unwrap()
                .style
        };
        assert_eq!(style("24%"), p.bad());
        assert_eq!(style("80%"), p.warn());
    }

    #[test]
    fn the_numbers_come_from_the_cc_series() {
        // The domain strip and red now are Home's (hub_core::home, app.rs tests).
        let out = text(&fixture(), 160);
        assert!(has(&out, "ci local 3/7 cloud 0/0, waiting 4"));
        assert!(!has(&out, "OVERALL"));
    }

    #[test]
    fn narrow_numbers_wrap_instead_of_cutting() {
        let i = fixture();
        let b = Board::new(&i, Palette { no_color: true });
        let wide: Vec<String> = b.numbers(200).iter().map(plain).collect();
        let narrow: Vec<String> = b.numbers(40).iter().map(plain).collect();
        assert!(narrow.len() > wide.len(), "{narrow:?}");
        let joined = narrow.join("\n");
        for item in [
            "nodes ",
            "heartbeats ",
            "ci local 3/7 cloud 0/0, waiting 4",
            "spend: Costs",
        ] {
            assert!(joined.contains(item), "{item} lost: {narrow:?}");
        }
        assert!(narrow.iter().all(|l| !l.ends_with('~')), "{narrow:?}");
    }

    #[test]
    fn narrowing_the_machines_keeps_busy_cpu_pools_and_state_longest() {
        let i = fixture();
        let row = |w| tab(&i, "machines", w);
        assert!(has(
            &row(200),
            "razer-laptop local up 3/4 91% 31% 9.8/16 60% 84C - unity 3/4"
        ));
        assert_line(&row(60), "razer-laptop up 3/4 91% 9.8/16 unity 3/4");
        assert_line(&row(50), "razer-laptop up 3/4 91% unity 3/4");
        // At its narrowest the machine keeps its busy/slots, CPU and pools.
        assert_line(&row(44), "razer-laptop 3/4 91% unity 3/4");
        assert_line(&row(40), "razer-laptop 3/4 91% unity 3/4");
    }

    #[test]
    fn a_narrow_terminal_keeps_each_slots_host_state_and_job_and_nothing_wraps() {
        let out = text(&fixture(), 60);
        assert_line(&out, "razer-laptop busy 1h33m! PlayMode 4");
        let long: Vec<&str> = out.lines().filter(|l| l.chars().count() > 60).collect();
        assert!(long.is_empty(), "{long:#?}");
    }

    #[test]
    fn github_not_answering_and_a_missed_scrape_read_differently_in_alerts_machinery() {
        // The rows Alerts fires on (hub_core::alerts::machinery), on this board's fixture.
        let text = |i: &Infra, _w: usize| hub_core::alerts::machinery(i).join("\n");
        let mut i = fixture();
        i.instant.insert("api", series(vec![(json!({}), "0")]));
        let out = text(&i, 160);
        assert!(has(
            &out,
            "GitHub not answering the exporter: runner rows may be missing"
        ));
        assert!(!out.contains("missed its last scrape"));
        // A scrape that timed out (up 0) or a target gone (absent) is the exporter's, not GitHub's,
        // even when the stale api_ok series is gone too.
        for up in [Some("0"), None] {
            let mut i = fixture();
            match up {
                Some(v) => i
                    .instant
                    .insert("exporter_up", series(vec![(json!({}), v)])),
                None => i.instant.insert("exporter_up", vec![]),
            };
            i.instant.insert("api", vec![]);
            let out = text(&i, 160);
            assert!(
                has(
                    &out,
                    "runner exporter missed its last scrape: runner rows may be missing"
                ),
                "{out}"
            );
            assert!(!out.contains("GitHub not answering"));
        }
        // A spent rate limit says so, ahead of the vaguer GitHub line it causes.
        let mut i = fixture();
        i.instant.insert("api", series(vec![(json!({}), "0")]));
        i.instant
            .insert("rate_left", series(vec![(json!({}), "0")]));
        let out = text(&i, 160);
        assert!(
            has(
                &out,
                "GitHub rate limit spent: runner jobs and history unread until it resets"
            ),
            "{out}"
        );
        assert!(!out.contains("GitHub not answering"));
        // Both answering: neither line.
        let out = text(&fixture(), 160);
        assert!(!out.contains("missed its last scrape") && !out.contains("GitHub not answering"));
    }

    #[test]
    fn the_api_query_reads_only_the_runner_sources() {
        let q: HashMap<_, _> = hub_core::infra::instant_queries().into_iter().collect();
        assert_eq!(
            q["api"],
            r#"min(github_runner_exporter_api_ok{kind="runners"})"#
        );
        assert!(q["exporter_up"].contains(r#"up{job="github-runner-exporter"}"#));
        assert_eq!(q["rate_left"], "min(github_runner_exporter_rate_remaining)");
    }

    #[test]
    fn a_failed_read_shows_the_error_and_no_machine_at_all() {
        let mut i = fixture();
        i.ok = false;
        i.error = Some("cannot read http://prom.test".into());
        let out = text(&i, 160);
        assert!(has(&out, "QUERY FAILED cannot read http://prom.test"));
        assert!(!out.contains("razer-laptop"));
        assert!(!out.contains("OK"));
    }

    #[test]
    fn rules_not_loaded_is_a_failure_not_an_empty_green_board() {
        let mut i = fixture();
        i.instant.insert("cc", vec![]);
        hub_core::infra::judge(&mut i, vec![]);
        assert!(!i.ok);
        assert!(has(&text(&i, 160), "recording rules not loaded"));
    }

    #[test]
    fn a_non_runner_lists_its_local_gates_with_the_repo_and_the_pr_of_its_branch() {
        let mut i = fixture();
        with_gates(&mut i);
        let out = text(&i, 200);
        assert_line(
            &out,
            "workstation - busy unity-local 36m - PlayMode (local) unity-core-playground#412",
        );
        // No repo label (an older fleet-assess): the branch stands in, and no PR is guessed.
        assert_line(
            &out,
            "workstation - busy unity-local 45s - EditMode (local) fix/x",
        );
        // Without published local slots the machine counts its gates and invents no capacity.
        assert!(
            has(&out, "workstation local no reading - - - - - - - 2 gates"),
            "{out}"
        );
        assert!(!tab(&built(&i), "pools", 160).contains("unity-local"));
    }

    #[test]
    fn published_local_slots_read_like_a_pool() {
        let mut i = fixture();
        with_gates(&mut i);
        with_local_slots(&mut i);
        let out = text(&i, 200);
        assert!(
            has(
                &out,
                "workstation local no reading 2/4 - - - - - - unity-local 2/4+6"
            ),
            "{out}"
        );
        assert_line(&out, "unity-local 4 2 - 1 - 14 50% workstation");
        assert!(has(&out, "waiting 5"));
    }

    #[test]
    fn the_agent_session_count_shows_only_when_the_rule_has_a_value() {
        let mut i = fixture();
        assert!(!text(&i, 160).contains("agent sessions"));
        i.instant.get_mut("cc").unwrap().extend(series(vec![(
            json!({"__name__": "cc:agent_sessions_running"}),
            "26",
        )]));
        assert!(has(&text(&i, 160), "agent sessions 26"));
    }

    #[test]
    fn the_ci_section_lists_no_runs() {
        let ci = tab(&fixture(), "ci", 160);
        assert!(
            !ci.contains("RECENT RUNS") && !ci.contains("Releases"),
            "{ci}"
        );
    }
}
