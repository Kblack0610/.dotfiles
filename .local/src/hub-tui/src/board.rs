//! The Prometheus pages of `hub` (Home's infra body, CI, Machines), laid out from one
//! `hub_core::infra::Infra` answer. It judges nothing: statuses are `cc:*` rules and rows are the
//! machines, pools and CI rows `hub_core` builds once for both surfaces (`infratables` draws
//! them), so it cannot disagree with Grafana or agent-web's Infra tab.

use std::collections::HashMap;

use hub_core::infra::Infra;
use hub_core::workload;
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::Palette;
use crate::infratables::InfraTables;
use hub_core::display::fmt::dur_secs;

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
    fn dim(&self, s: String) -> Line<'static> {
        Line::styled(s, self.p.dim())
    }

    /// `ci 4 running +2 github-hosted, waiting 5, 12/12 up`: jobs on our runners (the figure the
    /// bar and the Runners head read), GitHub's own, the queue and the runners up of the roster.
    fn ci_line(&self) -> String {
        let g = &self.infra.ci.glance;
        let mut out = format!("ci {} running", g.busy);
        let hosted = self.get("cc:github_hosted_running").unwrap_or(0.0);
        if hosted > 0.0 {
            out += &format!(" +{hosted:.0} github-hosted");
        }
        out + &format!(", waiting {}, {} up", g.queued, g.up_line())
    }

    /// The Space section (`hub_core::workload`): the cluster's cores and memory by class, one row
    /// each with used, reserved and room, the machines with no split named under it. A cluster
    /// with no class reading says no data, never an empty table.
    pub fn space(&self, w: usize) -> Vec<Line<'static>> {
        let sp = &self.infra.space;
        let mut head = vec![
            Span::styled("SPACE", self.p.head()),
            Span::raw(format!("  {}", sp.head)),
        ];
        if sp.done > 0 {
            head.push(Span::styled(
                format!("  done 24h {}", sp.done),
                self.p.dim(),
            ));
        }
        let mut out = vec![clip_line(Line::from(head), w)];
        let no = sp.no_split_note.clone();
        if sp.classes.is_empty() {
            out.push(self.dim(format!("  {}", hub_core::reading::NO_DATA)));
            if !no.is_empty() {
                out.push(self.dim(format!("  {no}")));
            }
            return out;
        }
        let cols: Vec<usize> = (0..workload::COLUMNS.len())
            .map(|i| {
                sp.classes
                    .iter()
                    .map(|c| c.cells[i].len())
                    .chain([workload::COLUMNS[i].len()])
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let row = |cells: Vec<&str>| {
            let mut s = String::new();
            for (i, c) in cells.iter().enumerate() {
                if i == 0 {
                    s += &format!("  {c:<w$}", w = cols[i]);
                } else {
                    s += &format!("  {c:>w$}", w = cols[i]);
                }
            }
            s
        };
        out.push(Line::styled(
            row(workload::COLUMNS.to_vec()).to_uppercase(),
            self.p.dim(),
        ));
        for c in &sp.classes {
            let mut line = row(c.cells.iter().map(String::as_str).collect());
            if !c.note.is_empty() {
                line += &format!("  {}", c.note);
            }
            out.push(Line::raw(line));
        }
        if !no.is_empty() {
            out.push(self.dim(format!("  {no}")));
        }
        out
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
            self.ci_line(),
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

    /// The Runners head: slots, busy and the queue (`hub_core::ci`), the CI runs that went red
    /// in the last day (`failed`, the runs read's `Counts::recent_red`, none before it lands; the
    /// red runs are Runs' red chip), and a red line per kind of job no online runner can take,
    /// naming the missing label.
    pub fn ci_head(&self, failed: Option<usize>, w: usize) -> Vec<Line<'static>> {
        let ci = &self.infra.ci;
        let secs = |v: i64| dur_secs(v as f64);
        let mut head = vec![
            Span::styled("CI RUNNERS", self.p.head()),
            Span::raw(format!("  {}", ci.glance.head(secs))),
        ];
        if let Some(n) = failed.filter(|n| *n > 0) {
            head.push(Span::styled(
                format!("  failed 24h {n} (Runs, red)"),
                self.p.bad(),
            ));
        } else if failed.is_some() && ci.glance.busy + ci.glance.queued == 0 && ci.local.is_empty()
        {
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

/// The Infra page as named sections in `hub_core::layout` order, less runs, pipelines, tests
/// and jobs, which the app draws from its own reads; the app shows them by inner tab, and
/// `inner` is the one shown, whose table has the keys (`infratables`). What is red is the
/// Alerts tab's (`hub_core::alerts`); here the headline numbers lead the machines, then what
/// runs, waits and failed locally. `failed` is the Runners head's (`Board::ci_head`). A failed
/// read is one section with the error and nothing else: a board never leaves the last (maybe
/// green) numbers up.
pub fn infra(
    infra: &Infra,
    p: Palette,
    now: i64,
    w: usize,
    tables: &InfraTables,
    inner: &str,
    failed: Option<usize>,
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
    machines.extend(b.space(w));
    machines.push(blank());
    machines.extend(table("machines"));
    let mut ci = b.ci_head(failed, w);
    ci.push(blank());
    ci.extend(table("runners"));
    let sections = vec![
        ("machines", machines),
        ("pools", table("pools")),
        ("ci", ci),
        ("waiting", table("queued")),
        ("local", table("local")),
    ];
    sections
        .into_iter()
        .map(|(n, ls)| (n, ls.into_iter().map(|l| clip_line(l, w)).collect()))
        .collect()
}

/// The CI head and the runners and queued tables, plain: what `hub ci` prints.
pub fn ci_runners(infra: &Infra, p: Palette, w: usize) -> Vec<Line<'static>> {
    let t = InfraTables::default();
    let mut out = Board::new(infra, p).ci_head(None, w);
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
        let mut m = json!({"host": host, "name": name, "state": state});
        for (k, x) in kw.as_object().unwrap() {
            m[k] = x.clone();
        }
        (m, v)
    }

    /// Every runner takes one cap: one `github_runner_pool_slot` row each, pool unity unless
    /// the fixture names another, and each busy one runs a job of that kind (`ci_runner_job`).
    fn one_cap_each(i: &mut Infra) {
        let mut caps = i.get("runners").to_vec();
        for s in &mut caps {
            s.labels
                .entry("pool".into())
                .or_insert_with(|| "unity".into());
        }
        let kinds = caps
            .iter()
            .filter(|s| s.label("state") == "running")
            .map(|s| Series {
                labels: [("runner", s.label("name")), ("kind", s.label("pool"))]
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
                value: Some(1.0),
                points: vec![],
            })
            .collect();
        i.instant.insert("runner_caps", caps);
        i.instant.insert("job_kind", kinds);
    }

    /// The bats fixture: razer-laptop with four unity runners (three busy), an offline
    /// mac-mini, a queue for #412, a stuck run, and a day of failed local gates.
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
        // Two hours of one branch's failed Android gates fold into one row; main's is older.
        let local = |branch: &str, platform: &str, hour: &str, n: &'static str| {
            let l = json!({"repo": "unity-core-playground", "branch": branch, "platform": platform, "result": "failure", "hour": hour});
            (l, n)
        };
        let local_failed = vec![
            local("feat/yard", "android", "1762900000", "2"),
            local("feat/yard", "android", "1762903600", "1"),
            local("main", "windows", "1762896400", "1"),
        ];
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert("cc", series(cc));
        i.instant.insert("runners", series(runners));
        one_cap_each(&mut i);
        i.instant.insert("waiting", series(waiting));
        i.instant.insert("local_failed", series(local_failed));
        i.instant.insert("api", series(vec![(json!({}), "1")]));
        i.instant
            .insert("exporter_up", series(vec![(json!({}), "1")]));
        i.instant.insert("gates", vec![]);
        i.instant.insert(
            "red",
            series(vec![(json!({"item": "watch gateway-errors"}), "1")]),
        );
        i
    }

    /// The cluster: razer-laptop a CI node of 4 cores and 16G with two light job pods on it,
    /// booking 2.5 cores and 1.0G.
    fn with_pods(i: &mut Infra) {
        let pod = |name: &str, r: &str, v: &'static str| {
            (
                json!({"pod": name, "node": "razer-laptop", "resource": r, "phase": "Running",
                "created_by_kind": "EphemeralRunner", "created_by_name": name}),
                v,
            )
        };
        let mut pods = vec![];
        for name in ["arc-org-light-runner-a1", "arc-org-light-runner-b2"] {
            pods.push(pod(name, "cpu", "1.25"));
            pods.push(pod(name, "memory", "536870912"));
        }
        i.instant.insert("job_pods", series(pods));
        let a = |r: &str, v: &'static str| (json!({"node": "razer-laptop", "resource": r}), v);
        i.instant.insert(
            "ci_alloc",
            series(vec![a("cpu", "4"), a("memory", "17179869184")]),
        );
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

    /// The workstation's ledger says 14 local runs done at 50%; the governor grants it 4 local
    /// seats and holds 1 run waiting for one.
    fn with_local_slots(i: &mut Infra) {
        i.instant.insert(
            "governor",
            series(vec![
                (
                    json!({"__name__": "ci_governor_capacity_units", "host": "workstation"}),
                    "4",
                ),
                (
                    json!({"__name__": "ci_governor_backlog_units", "kind": "local"}),
                    "1",
                ),
            ]),
        );
        let cc = i.instant.get_mut("cc").unwrap();
        for (n, v) in [
            ("cc:host_local_done_24h", "14"),
            ("cc:host_local_pass_ratio_24h", "0.5"),
        ] {
            cc.extend(series(vec![(
                json!({"__name__": n, "host": "workstation"}),
                v,
            )]));
        }
    }

    /// The runs read's red runs of the last day, for the Runners head (`Board::ci_head`).
    const FAILED: Option<usize> = Some(2);

    /// The fixture with its CI join built, as `gather` leaves it.
    pub(crate) fn built(i: &Infra) -> Infra {
        let mut j = i.clone();
        j.derive();
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
            FAILED,
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
        infra(&built(i), p, 0, 160, &InfraTables::default(), "", FAILED)
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
            FAILED,
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
        one_cap_each(i);
        i.instant.get_mut("cc").unwrap().extend(series(vec![(
            json!({"__name__": "cc:github_hosted_running"}),
            hosted,
        )]));
    }

    #[test]
    fn the_ci_runners_section_lists_each_slot_with_its_job_time_and_the_queue_beside_it() {
        let i = fixture();
        let ci = tab(&i, "ci", 160);
        assert!(
            ci.starts_with("CI RUNNERS  3 running, 4 queued (oldest 2h28m), - queued -, 4/5 runners up, 112 done 24h, 44% passed  failed 24h 2 (Runs, red)\n\nRUNNERS  all 5  busy 3  idle 1  off 1  late 1\nHOST"),
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
        // The queue, its own section, names each job's wait, what it needs and who can take it.
        assert_line(
            &tab(&i, "waiting", 160),
            "JOB POOL REF N WAIT NEEDS CAN RUN ON STARTS",
        );
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
            FAILED,
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
            .filter(|s| !["jobs", "runs", "pipelines", "tests", "quarantine"].contains(s))
            .collect();
        assert_eq!(names, want);
        let ci = tab(&i, "ci", 160);
        assert!(ci.starts_with("CI RUNNERS  3 running, 4 queued"), "{ci}");
        assert!(has(&ci, "failed 24h 2"), "{ci}");
        // The queue and the local failures are their own sections, after the slots.
        assert!(tab(&i, "waiting", 160).starts_with("WAITING  all "));
        assert!(tab(&i, "local", 160).starts_with("LOCAL UNITY  all "));
    }

    #[test]
    fn a_quiet_ci_is_one_green_line_and_no_empty_tables() {
        let mut i = fixture();
        for q in ["runners", "runner_caps", "gates", "waiting", "local_failed"] {
            i.instant.insert(q, vec![]);
        }
        i.instant
            .get_mut("cc")
            .unwrap()
            .retain(|s| s.label("__name__") != "cc:pool_waiting");
        let section = |failed, name| {
            infra(
                &built(&i),
                Palette { no_color: true },
                0,
                160,
                &InfraTables::default(),
                "",
                failed,
            )
            .into_iter()
            .find(|s| s.0 == name)
            .map(|(_, ls)| ls.iter().map(plain).collect::<Vec<_>>().join("\n"))
            .unwrap_or_default()
        };
        let ci = section(Some(0), "ci");
        assert_line(
            &ci,
            "CI RUNNERS 0 running, 0 queued, -/- runners up, 112 done 24h, 44% passed green: nothing waiting or failed in 24h",
        );
        // Before the runs read lands, nothing says green: their failures are not known yet.
        assert_line(
            &section(None, "ci"),
            "CI RUNNERS 0 running, 0 queued, -/- runners up, 112 done 24h, 44% passed",
        );
        // An empty table is its title and why, on one line, with no header or chips.
        assert_line(&ci, "RUNNERS no runner reports");
        assert_line(&section(Some(0), "waiting"), "WAITING nothing waiting");
        assert_line(
            &section(Some(0), "local"),
            "LOCAL UNITY no local Unity gate failed in 24h",
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
                (json!({"__name__": "ci_governor_decision", "host": "razer-laptop", "verdict": "busy", "action": "admit"}), "1"),
                (json!({"__name__": "ci_governor_admitted", "host": "razer-laptop"}), "4"),
            ]),
        );
        // Governor and power are machine columns now; the cloud host is a machine row.
        let m = tab(&i, "machines", 200);
        assert!(
            has(&m, "MACHINES all 3 busy 2 no data 1 cloud 1 governed 2"),
            "{m}"
        );
        assert!(
            has(
                &m,
                "aws-burst-1 no data - - - - - - - [unity] unity-core-playground - -"
            ),
            "{m}"
        );
        assert!(
            has(&m, "[unity] unity-core-playground - - running 1.5/6h -"),
            "{m}"
        );
        assert!(has(&m, "admit - -"), "{m}");
        // No series: the columns read -, and no Cloud or Governor section is drawn.
        let none = tab(&fixture(), "machines", 200);
        assert!(
            !none.contains("admit") && !none.contains("running 1"),
            "{none}"
        );
        assert_eq!(tab(&i, "cloud", 160), "");
        assert_eq!(tab(&i, "governor", 160), "");
    }

    #[test]
    fn the_header_counts_every_slot_once_and_github_hosted_jobs() {
        let mut i = fixture();
        with_cloud(&mut i, "3");
        let out = text(&i, 160);
        assert!(
            has(&out, "ci 4 running +3 github-hosted, waiting 4, 6/7 up"),
            "{out}"
        );
        // No GitHub-hosted job running says nothing about them.
        let mut i = fixture();
        with_cloud(&mut i, "0");
        let out = text(&i, 160);
        assert!(has(&out, "ci 4 running, waiting 4, 6/7 up"), "{out}");
        assert!(!out.contains("github-hosted"));
    }

    #[test]
    fn no_slot_read_at_all_reads_unknown() {
        let mut i = fixture();
        i.instant.remove("runners");
        let out = text(&i, 160);
        assert!(has(&out, "ci 0 running, waiting 4, -/- up"), "{out}");
    }

    #[test]
    fn a_withheld_runner_is_no_slot_and_says_nothing_on_its_row() {
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
                "razer-laptop up - 91% 31% 9.8/16 60% 84C - [unity] unity-core-playground x2, [unity] platform"
            ),
            "a held slot is no job on its row: {out}"
        );
        assert_line(
            &out,
            "razer-laptop 3 withheld unity - - the governor holds it back -",
        );
    }

    #[test]
    fn a_machines_row_carries_booked_load_6h_cpu_what_runs_and_what_is_next() {
        let mut i = fixture();
        with_pods(&mut i);
        with_cloud(&mut i, "0");
        let out = tab(&i, "machines", 200);
        assert_line(
            &out,
            "MACHINE STATE BOOKED CPU 6H LOAD MEM TEMP DISK RUNNING NEXT GOVERNOR POWER UP",
        );
        assert!(
            has(
                &out,
                "razer-laptop up [###.] 2.5/4 1.0G/16G 91% 31% 9.8/16 60% 84C - [arc-org-light] x2, [unity] unity-core-playground x2, [unity] platform - - - -"
            ),
            "{out}"
        );
        assert!(
            has(
                &out,
                "aws-burst-1 no data - - - - - - - [unity] unity-core-playground - - - -"
            ),
            "a machine on no CI node reads - for BOOKED, never a runner count: {out}"
        );
        // A host with one reading is up; its other columns read -, never 0.
        assert_line(&out, "mac-mini up - +1 off 3% - - - - - - - - - -");
    }

    #[test]
    fn queues_show_waiting_oldest_done_pass_longest_queue_first() {
        let mut i = fixture();
        i.instant.insert(
            "kind_weight",
            series(vec![
                (json!({"kind": "light", "measured": "true"}), "0.658"),
                (json!({"kind": "unity", "measured": "false"}), "1"),
            ]),
        );
        let out = tab(&i, "pools", 160);
        assert!(out.starts_with("JOB KINDS  all 3  waiting 2\n"), "{out}");
        // Each kind's weight (1* for one the governor has not measured, a dash with no series),
        // jobs running, waiting and the machines that take it; no runner for it reads as a dash.
        assert_line(&out, "unity 1* 3 3 2h28m 72 24% razer-laptop 4");
        assert_line(&out, "light 0.66 0 1 1m 40 80% -");
        assert_line(&out, "windows - 0 0 - - - -");
        assert!(
            has(
                &out,
                "weight: the share of a slot one job of the kind takes"
            ),
            "{out}"
        );
        let order: Vec<&str> = out
            .lines()
            .skip(3)
            .map(|l| l.split_whitespace().next().unwrap())
            .collect();
        assert_eq!(order, ["unity", "light", "windows"]);
    }

    #[test]
    fn a_narrow_kinds_table_drops_weight_before_any_other_column() {
        let mut i = fixture();
        i.instant.insert(
            "kind_weight",
            series(vec![(
                json!({"kind": "light", "measured": "true"}),
                "0.658",
            )]),
        );
        let out = tab(&i, "pools", 60);
        assert!(has(&out, "KIND"), "{out}");
        assert!(!has(&out, "WEIGHT"), "{out}");
        assert!(has(&out, "WAITING") && has(&out, "RUNNING"), "{out}");
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
        assert!(has(&out, "4 queued (oldest 2h28m)"), "{out}");
        assert!(!out.contains("RED NOW"), "{out}");
    }

    #[test]
    fn the_queue_groups_by_pool_repo_pr_and_branch_with_count_and_oldest_wait() {
        let out = text(&fixture(), 160);
        // The queue rows carry the PR or branch, the count of identical jobs and the oldest wait.
        assert_line(&out, "- unity unity-core-playground#412 3 2h28m - - -");
        assert_line(&out, "- light develop 1 1m - - -");
    }

    #[test]
    fn local_unity_folds_a_branchs_failed_hours_newest_first() {
        let out = tab(&fixture(), "local", 160);
        assert!(out.starts_with("LOCAL UNITY  all 2"), "{out}");
        let rows: Vec<&str> = out
            .lines()
            .skip_while(|l| !l.starts_with("LAST "))
            .skip(1)
            .collect();
        assert_eq!(rows.len(), 2, "{out}");
        assert!(
            has(rows[0], "unity-core-playground feat/yard android failure 3"),
            "the newest first, its two hours one row: {out}"
        );
        assert!(
            has(rows[1], "unity-core-playground main windows failure 1"),
            "{out}"
        );
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
        assert!(has(&out, "ci 3 running, waiting 4, 4/5 up"), "{out}");
        assert!(!has(&out, "OVERALL"));
    }

    fn with_split(i: &mut Infra) {
        let class = |rule: &'static str, class: &'static str, v| {
            (
                json!({"__name__": rule, "host": "razer-laptop", "class": class}),
                v,
            )
        };
        let host = |rule: &'static str, v| (json!({"__name__": rule, "host": "razer-laptop"}), v);
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            host("cc:host_inventory", "1"),
            class("cc:host_class_cores", "agents", "0.5"),
            class("cc:host_class_reserved_cores", "agents", "4"),
            class("cc:host_class_cores", "free", "1.4"),
            host("cc:host_run_units", "2"),
            host("cc:host_run_units_max", "5"),
        ]));
    }

    #[test]
    fn the_space_section_leads_machines_with_the_split_by_class() {
        let mut i = fixture();
        with_split(&mut i);
        let out = text(&i, 160);
        assert!(
            has(
                &out,
                "SPACE  cores 14.6 of 16 busy, mem no data, 1 of 1 machines read"
            ),
            "{out}"
        );
        assert!(has(&out, "agents 0.5 4.0 3.5 -"), "{out}");
        assert!(has(&out, "run units 2 of 5"), "{out}");
        assert!(
            out.find("SPACE").unwrap() < out.find("MACHINE").unwrap(),
            "Space is above the machines table: {out}"
        );
    }

    /// The negative control: no class series reads no data, never a table of zeros.
    #[test]
    fn a_cluster_with_no_split_says_no_data_and_names_each_machine_without_one() {
        let out = text(&fixture(), 160);
        assert!(has(&out, "SPACE"), "{out}");
        assert!(has(&out, "0 of 1 machines read"), "{out}");
        assert!(
            has(&out, "no split: razer-laptop (no node inventory there)"),
            "{out}"
        );
        assert!(!has(&out, "CORES USED"), "{out}");
    }

    #[test]
    fn narrow_numbers_wrap_instead_of_cutting() {
        let i = fixture();
        let j = built(&i);
        let b = Board::new(&j, Palette { no_color: true });
        let wide: Vec<String> = b.numbers(200).iter().map(plain).collect();
        let narrow: Vec<String> = b.numbers(40).iter().map(plain).collect();
        assert!(narrow.len() > wide.len(), "{narrow:?}");
        let joined = narrow.join("\n");
        for item in [
            "nodes ",
            "heartbeats ",
            "ci 3 running, waiting 4",
            "spend: Costs",
        ] {
            assert!(joined.contains(item), "{item} lost: {narrow:?}");
        }
        assert!(narrow.iter().all(|l| !l.ends_with('~')), "{narrow:?}");
    }

    #[test]
    fn a_machine_names_the_oldest_waiting_job_its_runners_can_take_as_next() {
        let mut i = fixture();
        for s in i.instant.get_mut("runners").unwrap() {
            s.labels
                .insert("labels".into(), "self-hosted,linux,unity".into());
        }
        i.instant.get_mut("waiting").unwrap().extend(series(vec![(
            json!({"pool": "unity", "repo": "web", "branch": "x", "stuck": "false",
                "labels": "self-hosted,linux,unity", "job_name": "Checks"}),
            "300",
        )]));
        let out = tab(&i, "machines", 220);
        assert!(has(&out, "Checks (web) 5m"), "{out}");
    }

    #[test]
    fn narrowing_the_machines_keeps_booked_cpu_running_and_state_longest() {
        let mut i = fixture();
        with_pods(&mut i);
        let row = |w| tab(&i, "machines", w);
        assert!(has(
            &row(200),
            "razer-laptop up [###.] 2.5/4 1.0G/16G 91% 31% 9.8/16 60% 84C - [arc-org-light] x2, [unity] unity-core-playground x2, [unity] platform"
        ));
        // Narrower, what it runs takes the room left; below that it drops the booking for it.
        assert_line(
            &row(60),
            "razer-laptop [###.] 2.5/4 1.0G/16G [arc-org-light] x2, [u~",
        );
        assert_line(
            &row(50),
            "razer-laptop [arc-org-light] x2, [unity] unity-c~",
        );
        assert_line(&row(40), "razer-laptop [arc-org-light] x2, [unit~");
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
            "workstation - busy gates 36m - PlayMode (local) unity-core-playground#412",
        );
        // No repo label (an older fleet-assess): the branch stands in, and no PR is guessed.
        assert_line(
            &out,
            "workstation - busy gates 45s - EditMode (local) fix/x",
        );
        // Each running gate is one job on the machine, each by its repo, and no unit is
        // invented for it.
        assert!(
            has(
                &out,
                "workstation no data - - - - - - - [gates] unity-core-playground, [gates] unity-core-playg~"
            ),
            "{out}"
        );
        // The gates running are a pool of their own.
        assert!(tab(&built(&i), "pools", 160).contains("gates"));
    }

    #[test]
    fn the_ledger_and_the_governor_read_the_local_gates_like_a_pool() {
        let mut i = fixture();
        with_gates(&mut i);
        with_local_slots(&mut i);
        let out = text(&i, 200);
        assert!(
            has(
                &out,
                "workstation no data [....] 0.0/4 - - - - - - [gates] unity-core-playground, [gates] unity-core-playg~"
            ),
            "{out}"
        );
        assert_line(&out, "gates - 2 1 - 14 50% workstation 4");
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
