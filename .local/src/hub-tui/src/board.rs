//! The Prometheus pages of `hub infra` (Overview, CI, Machines), laid out from one
//! `hub_core::infra::Infra` answer. It judges nothing: statuses are `cc:*` rules and rows are
//! runner-exporter series, so it cannot disagree with Grafana or agent-web's Infra tab.

use std::collections::{BTreeMap, HashMap};

use hub_core::infra::Infra;
use hub_core::prom::Series;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{clock, dur, pct, Palette};

/// A job running longer than this shows its time amber: playground ci.md calls a gate that
/// runs past about an hour a bug to fix, not a wait.
pub const LONG_RUN_SECS: f64 = 3600.0;
/// Queue groups the Overview lists before it counts the rest.
pub const QUEUE_ROWS: usize = 8;
/// Recent runs the CI page lists before it counts the rest (Grafana keeps them all).
pub const RECENT_ROWS: usize = 60;
const DOMAINS: [&str; 9] = [
    "k3s", "machines", "ci", "prod", "llm", "agents", "spend", "platform", "other",
];

/// A label as a cell shows it: - when the series has none.
fn lab<'a>(s: &'a Series, k: &str) -> &'a str {
    match s.label(k) {
        "" => "-",
        v => v,
    }
}

fn pr_of(s: &Series) -> String {
    match s.label("pr") {
        "" => "-".into(),
        p => format!("#{p}"),
    }
}

pub struct Board<'a> {
    infra: &'a Infra,
    p: Palette,
    now: i64,
    /// `cc:<name>` or `cc:<name>/<domain|host|pool>` -> value.
    v: HashMap<String, f64>,
    runners: Vec<&'a Series>,
    /// Machines listed even with no runner, first (`CC_HOSTS`).
    extra_hosts: Vec<String>,
    /// `<repo>/<branch>` -> the PR a runner or queued job carries for it.
    pr_by_branch: HashMap<String, String>,
}

impl<'a> Board<'a> {
    pub fn new(infra: &'a Infra, p: Palette, now: i64, extra_hosts: Vec<String>) -> Board<'a> {
        let mut v = HashMap::new();
        for s in infra.get("cc") {
            let name = s.label("__name__");
            let sub = if name == "cc:domain_status" {
                s.label("domain")
            } else if !s.label("host").is_empty() {
                s.label("host")
            } else {
                s.label("pool")
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
        let mut runners: Vec<&Series> = infra.get("runners").iter().collect();
        let order = |s: &Series| {
            ["host", "state", "pool", "name", "repo", "pr", "branch"]
                .map(|k| s.label(k).to_string())
        };
        runners.sort_by_key(|s| order(s));
        let mut pr_by_branch = HashMap::new();
        for s in runners.iter().copied().chain(infra.get("waiting")) {
            if !s.label("pr").is_empty() {
                pr_by_branch.insert(
                    format!("{}/{}", lab(s, "repo"), lab(s, "branch")),
                    format!("#{}", s.label("pr")),
                );
            }
        }
        Board {
            infra,
            p,
            now,
            v,
            runners,
            extra_hosts,
            pr_by_branch,
        }
    }

    fn get(&self, k: &str) -> Option<f64> {
        self.v.get(k).copied()
    }
    /// A count, or ? when the rule is absent.
    fn num(&self, k: &str) -> String {
        self.get(k).map_or("?".into(), |x| format!("{x:.0}"))
    }
    /// A whole number, or - when the series is absent (never a 0 it did not say).
    fn int(&self, k: &str) -> String {
        self.get(k).map_or("-".into(), |x| format!("{x:.0}"))
    }
    fn usd(&self, k: &str) -> String {
        self.get(k).map_or("?".into(), |x| format!("${x:.0}"))
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
    fn heading(&self, title: &str, rest: String) -> Line<'static> {
        Line::from(vec![
            Span::styled(title.to_string(), self.p.head()),
            Span::raw(rest),
        ])
    }
    fn dim(&self, s: String) -> Line<'static> {
        Line::styled(s, self.p.dim())
    }
    fn tag(&self, v: Option<f64>, label: &str) -> Span<'static> {
        let (style, word) = self.p.status(v);
        Span::styled(format!(" {label} {word} "), style)
    }

    /// Every pool a `cc:pool_*` series names, the longest queue first.
    fn pools_list(&self) -> Vec<String> {
        let mut ps: Vec<String> = self
            .v
            .keys()
            .filter_map(|k| {
                k.strip_prefix("cc:pool_slots/")
                    .or_else(|| k.strip_prefix("cc:pool_waiting/"))
            })
            .map(String::from)
            .collect();
        ps.sort();
        ps.dedup();
        ps.sort_by(|a, b| {
            let w = |p: &str| self.get(&format!("cc:pool_waiting/{p}")).unwrap_or(0.0);
            w(b).total_cmp(&w(a)).then_with(|| a.cmp(b))
        });
        ps
    }
    /// Every host whose local Unity slots are published.
    fn local_hosts(&self) -> Vec<String> {
        let mut h: Vec<String> = self
            .v
            .keys()
            .filter_map(|k| k.strip_prefix("cc:host_local_slots/").map(String::from))
            .collect();
        h.sort();
        h
    }
    /// busy/open+room. Open slots always run; room slots only while the machine has room.
    fn local_cell(&self, h: &str) -> String {
        let total = self.get(&format!("cc:host_local_slots/{h}")).unwrap_or(0.0);
        let open = self
            .get(&format!("cc:host_local_open_slots/{h}"))
            .unwrap_or(0.0);
        let room = (total - open).round() as i64;
        let mut s = format!(
            "{}/{}",
            self.num(&format!("cc:host_local_busy/{h}")),
            self.num(&format!("cc:host_local_open_slots/{h}"))
        );
        if room > 0 {
            s += &format!("+{room}");
        }
        s
    }

    /// The status tag, what needs the human, the domain strip and the headline numbers.
    pub fn header(&self, w: usize) -> Vec<Line<'static>> {
        let mut out = vec![Line::from(vec![
            self.tag(self.get("cc:overall_status"), "OVERALL"),
            Span::raw(format!(
                "  needs you: {} asks, {} sessions waiting",
                self.num("cc:asks_open"),
                self.num("cc:sessions_attention")
            )),
        ])];
        let mut strip = vec![];
        for d in DOMAINS {
            let s = self.get(&format!("cc:domain_status/{d}"));
            if s.is_none() && d != "k3s" && d != "ci" {
                continue;
            }
            strip.push(self.tag(s, d));
            strip.push(Span::raw(" "));
        }
        out.push(Line::from(strip));
        let here = self
            .get("cc:agent_sessions_running")
            .map_or(String::new(), |_| {
                format!("  agent sessions {}", self.num("cc:agent_sessions_running"))
            });
        out.push(self.dim(format!(
            "nodes {}/{}  heartbeats {}/{}  ci busy {}/{} waiting {}  agent runners {} failed  watches {}/{} tripped  lazer {}/{}  claude 24h {}{here}",
            self.num("cc:k3s_nodes_ready"),
            self.num("cc:k3s_nodes_total"),
            self.num("cc:machines_up"),
            self.num("cc:machines_total"),
            self.sum(&["cc:pool_busy", "cc:host_local_busy"]),
            self.sum(&["cc:pool_slots", "cc:host_local_open_slots"]),
            self.sum(&["cc:pool_waiting", "cc:host_local_queued"]),
            self.num("cc:runners_failed"),
            self.num("cc:watches_tripped"),
            self.num("cc:watches_total"),
            self.usd("cc:lazer_spend_usd"),
            self.usd("cc:lazer_budget_usd"),
            self.usd("cc:claude_code_cost_24h_usd"),
        )));
        out.into_iter().map(|l| clip_line(l, w)).collect()
    }

    /// The balance view, one row per pool: busy of its slots, waiting, the oldest wait, the
    /// last day's done and pass rate, and the machines serving it (host:n past one slot).
    pub fn pools(&self, w: usize) -> Vec<Line<'static>> {
        let mut on: BTreeMap<(String, String), u32> = BTreeMap::new();
        for s in &self.runners {
            if matches!(s.label("state"), "running" | "idle") {
                *on.entry((lab(s, "pool").into(), lab(s, "host").into()))
                    .or_default() += 1;
            }
        }
        let mut rows = vec![];
        for p in self.pools_list() {
            let hosts: Vec<String> = on
                .iter()
                .filter(|((pool, _), _)| *pool == p)
                .map(|((_, h), n)| {
                    if *n > 1 {
                        format!("{h}:{n}")
                    } else {
                        h.clone()
                    }
                })
                .collect();
            let slots = match self.get(&format!("cc:pool_slots/{p}")) {
                Some(_) => format!(
                    "{}/{}",
                    self.num(&format!("cc:pool_busy/{p}")),
                    self.num(&format!("cc:pool_slots/{p}"))
                ),
                None => "-".into(),
            };
            let ratio = self.get(&format!("cc:pool_pass_ratio_24h/{p}"));
            rows.push(vec![
                Cell::from(p.clone()),
                slots.into(),
                self.num(&format!("cc:pool_waiting/{p}")).into(),
                self.get(&format!("cc:pool_oldest_wait_seconds/{p}"))
                    .map_or("-".into(), dur)
                    .into(),
                self.int(&format!("cc:pool_done_24h/{p}")).into(),
                cell(pct(ratio), self.p.pass(ratio)),
                if hosts.is_empty() {
                    "-".into()
                } else {
                    hosts.join(" ").into()
                },
            ]);
        }
        for h in self.local_hosts() {
            let ratio = self.get(&format!("cc:host_local_pass_ratio_24h/{h}"));
            rows.push(vec![
                "unity-local".into(),
                self.local_cell(&h).into(),
                self.num(&format!("cc:host_local_queued/{h}")).into(),
                "-".into(),
                self.int(&format!("cc:host_local_done_24h/{h}")).into(),
                cell(pct(ratio), self.p.pass(ratio)),
                h.into(),
            ]);
        }
        Table {
            header: vec!["POOL", "BUSY", "WAITING", "OLDEST", "DONE", "PASS", "ON"],
            rows,
            keep: vec![0, 1, 2, 5, 4, 3],
            flex: Some(6),
            flexmin: 8,
            right: vec![1, 2, 3, 4, 5],
            ..Default::default()
        }
        .fit(w, self.p.head())
    }

    /// One row per machine: its load and its slots per pool. Narrowing drops TEMP, then MEM,
    /// then 6H; CPU, LOAD and SLOTS stay, so the load view never goes.
    pub fn machines(&self, w: usize) -> Vec<Line<'static>> {
        let mut hosts: Vec<String> = vec![];
        let add = |hosts: &mut Vec<String>, h: &str| {
            if !hosts.iter().any(|x| x == h) {
                hosts.push(h.to_string());
            }
        };
        for h in &self.extra_hosts {
            add(&mut hosts, h);
        }
        let mut slots: HashMap<(String, String), (u32, u32)> = HashMap::new();
        let mut order: Vec<String> = vec![];
        for s in &self.runners {
            add(&mut hosts, lab(s, "host"));
            // A slot counts when it is registered, as in cc:pool_slots; a missing one is DOWN's.
            let state = s.label("state");
            if !matches!(state, "running" | "idle") {
                continue;
            }
            let pool = lab(s, "pool").to_string();
            let e = slots
                .entry((lab(s, "host").into(), pool.clone()))
                .or_default();
            e.1 += 1;
            if state == "running" {
                e.0 += 1;
            }
            if !order.contains(&pool) {
                order.push(pool);
            }
        }
        // Pools in the pools' order (longest queue first), then any the cc:pool_* rules miss.
        let mut known = self.pools_list();
        for p in order {
            if !known.contains(&p) {
                known.push(p);
            }
        }
        let mut gates: HashMap<String, u32> = HashMap::new();
        for g in self.infra.get("gates") {
            add(&mut hosts, lab(g, "host"));
            *gates.entry(lab(g, "host").into()).or_default() += 1;
        }
        let rows: Vec<Vec<Cell>> = hosts
            .iter()
            .map(|h| {
                let k = |r: &str| format!("{r}/{h}");
                let mut sl: Vec<String> = known
                    .iter()
                    .filter_map(|p| {
                        slots
                            .get(&(h.clone(), p.clone()))
                            .map(|(b, n)| format!("{p} {b}/{n}"))
                    })
                    .collect();
                // Local slots once slots.sh publishes them; until then only the gates' count.
                if self.get(&k("cc:host_local_slots")).is_some() {
                    sl.push(format!("unity-local {}", self.local_cell(h)));
                } else if let Some(n) = gates.get(h) {
                    sl.push(format!("{n} gates"));
                }
                vec![
                    h.clone().into(),
                    pct(self.get(&k("cc:host_cpu_busy_ratio"))).into(),
                    pct(self.get(&k("cc:host_cpu_busy_ratio:avg6h"))).into(),
                    self.get(&k("cc:host_load1"))
                        .map_or("-".into(), |l| {
                            format!("{l:.1}/{}", self.num(&k("cc:host_cores")))
                        })
                        .into(),
                    pct(self.get(&k("cc:host_mem_used_ratio"))).into(),
                    self.get(&k("cc:host_temp_c"))
                        .map_or("-".into(), |t| format!("{t:.0}C"))
                        .into(),
                    if sl.is_empty() {
                        "-".into()
                    } else {
                        sl.join("  ").into()
                    },
                ]
            })
            .collect();
        // SLOTS asks for its widest row, but no more than room for two pools' counts, so the
        // narrowing drops TEMP, MEM and 6H to keep it whole and never reaches CPU or LOAD.
        let widest = rows
            .iter()
            .map(|r| r[6].text.chars().count())
            .max()
            .unwrap_or(0)
            .max(5);
        Table {
            header: vec!["MACHINE", "CPU", "6H", "LOAD", "MEM", "TEMP", "SLOTS"],
            rows,
            keep: vec![0, 1, 3, 2, 4, 5],
            flex: Some(6),
            flexmin: widest.min(24),
            flexkeep: true,
            right: vec![1, 2, 3, 4, 5],
            ..Default::default()
        }
        .fit(w, self.p.head())
    }

    /// One row per busy runner and per local gate, longest first.
    pub fn running(&self, w: usize) -> Vec<Line<'static>> {
        // (seconds, host, pool, repo, pr, job, branch)
        let mut rows: Vec<(f64, [String; 6])> = vec![];
        for s in &self.runners {
            if s.label("state") != "running" {
                continue;
            }
            let mut branch = lab(s, "branch").to_string();
            let title = s.label("title");
            if !title.is_empty() && title != s.label("workflow") {
                branch = format!("{branch} - {title}");
            }
            rows.push((
                s.value.unwrap_or(0.0),
                [
                    lab(s, "host").into(),
                    lab(s, "pool").into(),
                    lab(s, "repo").into(),
                    pr_of(s),
                    lab(s, "job_name").into(),
                    branch,
                ],
            ));
        }
        // A machine that is not a runner runs its gates locally: pool unity-local, the PR from
        // a runner or queue row on the same branch, and the worktree only when the repo is unknown.
        for g in self.infra.get("gates") {
            let repo = match g.label("repo") {
                "" => lab(g, "worktree"),
                r => r,
            };
            let branch = lab(g, "branch");
            rows.push((
                g.value.unwrap_or(0.0),
                [
                    lab(g, "host").into(),
                    "unity-local".into(),
                    repo.into(),
                    self.pr_by_branch
                        .get(&format!("{repo}/{branch}"))
                        .cloned()
                        .unwrap_or("-".into()),
                    lab(g, "platform").into(),
                    branch.into(),
                ],
            ));
        }
        if rows.is_empty() {
            return vec![self.heading("RUNNING", "  nothing".into())];
        }
        rows.sort_by(|a, b| b.0.total_cmp(&a.0));
        let rows = rows
            .into_iter()
            .map(|(secs, [host, pool, repo, pr, job, branch])| {
                let (t, style) = if secs.trunc() > 0.0 {
                    if secs > LONG_RUN_SECS {
                        (format!("{}!", dur(secs)), self.p.warn())
                    } else {
                        (dur(secs), Default::default())
                    }
                } else {
                    ("-".into(), Default::default())
                };
                vec![
                    host.into(),
                    pool.into(),
                    repo.into(),
                    pr.into(),
                    job.into(),
                    cell(t, style),
                    branch.into(),
                ]
            })
            .collect();
        let mut out = vec![self.heading("RUNNING", String::new())];
        out.extend(
            Table {
                header: vec![
                    "HOST",
                    "POOL",
                    "REPO",
                    "PR",
                    "JOB",
                    "FOR",
                    "BRANCH - PR TITLE",
                ],
                rows,
                keep: vec![0, 2, 3, 5, 4, 1],
                flex: Some(6),
                flexmin: 16,
                flexkeep: true,
                right: vec![5],
                cap: vec![(2, 21), (4, 18)],
            }
            .fit(w, self.p.head()),
        );
        out
    }

    /// Waiting jobs grouped by pool, repo, PR and branch, oldest first, `max` groups at most.
    /// A stuck run (queued with no jobs) is DOWN's, so it cannot pass for the queue's age.
    pub fn queued(&self, w: usize, max: Option<usize>) -> Vec<Line<'static>> {
        let mut groups: BTreeMap<[String; 4], (u32, f64)> = BTreeMap::new();
        let (mut n, mut oldest) = (0, 0.0f64);
        for s in self.infra.get("waiting") {
            if s.label("stuck") == "true" {
                continue;
            }
            let val = s.value.unwrap_or(0.0).trunc();
            n += 1;
            oldest = oldest.max(val);
            let e = groups
                .entry([
                    lab(s, "pool").into(),
                    lab(s, "repo").into(),
                    pr_of(s),
                    lab(s, "branch").into(),
                ])
                .or_default();
            e.0 += 1;
            e.1 = e.1.max(val);
        }
        if n == 0 {
            return vec![self.heading("QUEUED", "  nothing waiting".into())];
        }
        let mut out = vec![clip_line(
            self.heading(
                "QUEUED",
                format!(
                    "  {n} jobs in {} groups, oldest waiting {}",
                    groups.len(),
                    dur(oldest)
                ),
            ),
            w,
        )];
        let mut g: Vec<_> = groups.into_iter().collect();
        g.sort_by(|a, b| b.1 .1.total_cmp(&a.1 .1));
        let total = g.len();
        let shown = max.unwrap_or(total).min(total);
        let rows = g
            .into_iter()
            .take(shown)
            .map(|([pool, repo, pr, branch], (c, old))| {
                vec![
                    pool.into(),
                    repo.into(),
                    pr.into(),
                    c.to_string().into(),
                    dur(old).into(),
                    branch.into(),
                ]
            })
            .collect();
        out.extend(
            Table {
                header: vec!["POOL", "REPO", "PR", "JOBS", "WAITING", "BRANCH"],
                rows,
                keep: vec![0, 1, 2, 3, 4],
                flex: Some(5),
                flexmin: 12,
                right: vec![3, 4],
                ..Default::default()
            }
            .fit(w, self.p.head()),
        );
        if total > shown {
            out.push(self.dim(format!("  +{} more groups (3 CI)", total - shown)));
        }
        out
    }

    /// Offline or missing runners, stuck runs, and GitHub or the exporter not answering.
    pub fn down(&self, w: usize) -> Vec<Line<'static>> {
        let mut items: Vec<String> = vec![];
        for s in &self.runners {
            if matches!(s.label("state"), "offline" | "missing") {
                items.push(format!("{} {}", lab(s, "name"), s.label("state")));
            }
        }
        for s in self.infra.get("waiting") {
            if s.label("stuck") == "true" {
                items.push(format!(
                    "stuck run: {} {}, {}, no jobs",
                    lab(s, "repo"),
                    lab(s, "branch"),
                    dur(s.value.unwrap_or(f64::NAN))
                ));
            }
        }
        let api_ok = self
            .infra
            .get("api")
            .first()
            .and_then(|s| s.value)
            .is_some_and(|v| v == 1.0);
        if !api_ok {
            items.insert(
                0,
                "GitHub API not answering: runner rows may be missing".into(),
            );
        }
        if self.runners.is_empty() {
            items.push("no runner series (exporter down?)".into());
        }
        let line = if items.is_empty() {
            self.heading(
                "DOWN",
                "    nothing: every rostered runner is registered and online".into(),
            )
        } else {
            Line::from(vec![
                Span::styled("DOWN", self.p.head()),
                Span::raw("    "),
                Span::styled(items.join(", "), self.p.bad()),
            ])
        };
        vec![clip_line(line, w)]
    }

    /// The last day of runs per repo and workflow, the worst pass rate first, `max` rows at
    /// most. Pass is success of success + failure + timed out; cancelled is its own column,
    /// since gates for closed PRs are cancelled on purpose. All-green workflows fold to a line.
    pub fn finished(&self, w: usize, max: Option<usize>) -> Vec<Line<'static>> {
        let fin = self.infra.get("finished");
        if fin.is_empty() {
            return vec![self.heading(
                "FINISHED 24H",
                "  no finished-run series yet (runner exporter)".into(),
            )];
        }
        // (repo, workflow) -> runs, ok, bad, cancelled
        let mut agg: BTreeMap<(String, String), [u64; 4]> = BTreeMap::new();
        for s in fin {
            let n = s.value.unwrap_or(0.0) as u64;
            let e = agg
                .entry((lab(s, "repo").into(), lab(s, "workflow").into()))
                .or_default();
            e[0] += n;
            match s.label("conclusion") {
                "success" => e[1] += n,
                "failure" | "timed_out" => e[2] += n,
                "cancelled" => e[3] += n,
                _ => {}
            }
        }
        let t = agg.values().fold([0u64; 4], |mut t, a| {
            (0..4).for_each(|i| t[i] += a[i]);
            t
        });
        let ratio = |ok: u64, bad: u64| (ok + bad > 0).then(|| ok as f64 / (ok + bad) as f64);
        let mut out = vec![self.heading(
            "FINISHED 24H",
            format!(
                "  {} runs, {} pass, {} failed, {} cancelled",
                t[0],
                pct(ratio(t[1], t[2])),
                t[2],
                t[3]
            ),
        )];
        let (mut bad, green): (Vec<_>, Vec<_>) =
            agg.into_iter().partition(|(_, a)| a[2] + a[3] > 0);
        let key = |a: &[u64; 4]| ratio(a[1], a[2]).map_or(-1, |r| (r * 100.0).round() as i64);
        bad.sort_by(|(_, a), (_, b)| {
            key(a)
                .cmp(&key(b))
                .then(b[2].cmp(&a[2]))
                .then(b[3].cmp(&a[3]))
        });
        let shown = max.unwrap_or(bad.len()).min(bad.len());
        if !bad.is_empty() {
            let rows = bad
                .iter()
                .take(shown)
                .map(|((repo, wf), a)| {
                    let r = ratio(a[1], a[2]);
                    vec![
                        cell(pct(r), self.p.pass(r)),
                        a[0].to_string().into(),
                        a[2].to_string().into(),
                        a[3].to_string().into(),
                        repo.clone().into(),
                        wf.clone().into(),
                    ]
                })
                .collect();
            out.extend(
                Table {
                    header: vec!["PASS", "RUNS", "FAIL", "CANCEL", "REPO", "WORKFLOW"],
                    rows,
                    keep: vec![0, 2, 5, 3, 1, 4],
                    flex: Some(5),
                    flexmin: 10,
                    flexkeep: true,
                    right: vec![0, 1, 2, 3],
                    cap: vec![(4, 21)],
                }
                .fit(w, self.p.head()),
            );
            if bad.len() > shown {
                out.push(self.dim(format!(
                    "  +{} more workflows with failures (3 CI)",
                    bad.len() - shown
                )));
            }
        }
        if !green.is_empty() {
            let runs: u64 = green.iter().map(|(_, a)| a[0]).sum();
            out.push(self.dim(format!("  +{} green workflows, {runs} runs", green.len())));
        }
        out
    }

    /// Runs as the exporter last listed them, newest first: when each ended, how long it took.
    pub fn recent(&self, w: usize) -> Vec<Line<'static>> {
        let took: HashMap<&str, f64> = self
            .infra
            .get("recent_dur")
            .iter()
            .filter_map(|s| Some((s.label("url"), s.value?)))
            .collect();
        let mut runs: Vec<&Series> = self
            .infra
            .get("recent")
            .iter()
            .filter(|s| s.value.is_some_and(|v| v > 0.0))
            .collect();
        if runs.is_empty() {
            return vec![self.heading(
                "RECENT RUNS",
                "  no recent-run series (exporter down, or RUN_REPOS empty)".into(),
            )];
        }
        runs.sort_by(|a, b| b.value.unwrap_or(0.0).total_cmp(&a.value.unwrap_or(0.0)));
        let total = runs.len();
        let rows = runs
            .iter()
            .take(RECENT_ROWS)
            .map(|s| {
                let style = match s.label("conclusion") {
                    "failure" | "timed_out" => self.p.bad(),
                    "cancelled" => self.p.warn(),
                    _ => Default::default(),
                };
                vec![
                    clock(s.value.unwrap_or(0.0) as i64, self.now).into(),
                    lab(s, "repo").into(),
                    lab(s, "workflow").into(),
                    took.get(s.label("url"))
                        .map_or("-".into(), |d| dur(*d))
                        .into(),
                    cell(lab(s, "conclusion"), style),
                    lab(s, "event").into(),
                    lab(s, "branch").into(),
                ]
            })
            .collect();
        let mut out =
            vec![self.heading("RECENT RUNS", format!("  {total} listed by the exporter"))];
        out.extend(
            Table {
                header: vec![
                    "ENDED", "REPO", "WORKFLOW", "TOOK", "RESULT", "EVENT", "BRANCH",
                ],
                rows,
                keep: vec![0, 1, 2, 4, 3, 5],
                flex: Some(6),
                flexmin: 12,
                right: vec![3],
                cap: vec![(1, 21), (2, 28)],
                ..Default::default()
            }
            .fit(w, self.p.head()),
        );
        if total > RECENT_ROWS {
            out.push(self.dim(format!(
                "  +{} older (Grafana kb-ci-runners: Recent runs)",
                total - RECENT_ROWS
            )));
        }
        out
    }

    /// What is red right now: tripped watches, failed runners, NotReady nodes.
    pub fn red_now(&self, w: usize) -> Line<'static> {
        let mut items: Vec<&str> = self
            .infra
            .get("red")
            .iter()
            .map(|s| s.label("item"))
            .collect();
        items.retain(|i| !i.is_empty());
        items.sort();
        let line = if items.is_empty() {
            Line::raw("red now: nothing")
        } else {
            Line::from(vec![
                Span::raw("red now: "),
                Span::styled(items.join(", "), self.p.bad()),
            ])
        };
        clip_line(line, w)
    }
}

/// Machines listed even with no runner (`CC_HOSTS`, default the workstation).
pub fn extra_hosts() -> Vec<String> {
    hub_core::prom::config("CC_HOSTS")
        .unwrap_or_else(|| "workstation".into())
        .split_whitespace()
        .map(String::from)
        .collect()
}

/// The three Prometheus pages. A failed read shows the error and nothing else: a board never
/// leaves the last (maybe green) numbers up.
pub fn page(
    tab: crate::app::Tab,
    infra: &Infra,
    p: Palette,
    now: i64,
    w: usize,
    hosts: &[String],
) -> Vec<Line<'static>> {
    use crate::app::Tab;
    if !infra.ok {
        return vec![
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
        ];
    }
    let b = Board::new(infra, p, now, hosts.to_vec());
    let blank = || Line::raw("");
    let mut out = vec![];
    match tab {
        Tab::Overview => {
            out.extend(b.header(w));
            out.push(blank());
            out.extend(b.pools(w));
            out.push(blank());
            out.extend(b.running(w));
            out.push(blank());
            out.extend(b.queued(w, Some(QUEUE_ROWS)));
            out.extend(b.down(w));
            out.push(blank());
            out.extend(b.finished(w, Some(0)).into_iter().take(1));
            out.push(b.red_now(w));
        }
        Tab::Machines => out.extend(b.machines(w)),
        Tab::Ci => {
            out.extend(b.finished(w, None));
            out.push(blank());
            out.extend(b.recent(w));
        }
        Tab::Jobs => {}
    }
    out.into_iter().map(|l| clip_line(l, w)).collect()
}

#[cfg(test)]
pub(crate) mod tests {
    //! The bash board's bats suite (command_center.bats), ported onto the same fixture data.
    use super::*;
    use crate::app::Tab;
    use crate::fit::plain;
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

    fn text(i: &Infra, w: usize) -> String {
        [Tab::Overview, Tab::Machines, Tab::Ci]
            .iter()
            .flat_map(|t| page(*t, i, Palette { no_color: true }, 0, w, &hosts()))
            .map(|l| plain(&l))
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn hosts() -> Vec<String> {
        vec!["workstation".into()]
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

    #[test]
    fn a_busy_runners_row_names_host_pool_repo_pr_job_time_branch_and_title() {
        let out = text(&fixture(), 160);
        assert_line(&out, "razer-laptop unity unity-core-playground #412 PlayMode 2 36m feat/apociseum-third - Apociseum third arena");
        // No PR shows -, and a title that only repeats the workflow is not shown.
        assert_line(&out, "razer-laptop unity platform - E2E 5m develop");
    }

    #[test]
    fn a_machines_row_carries_load_6h_cpu_and_busy_of_its_slots_per_pool() {
        let out = text(&fixture(), 160);
        assert_line(&out, "razer-laptop 91% 31% 9.8/16 60% 84C unity 3/4");
        // No exporter series reads - in every column, never 0.
        assert_line(&out, "workstation - - - - - -");
        assert_line(&out, "mac-mini 3% - - - - -");
    }

    #[test]
    fn pools_show_busy_waiting_oldest_done_pass_and_hosts_longest_queue_first() {
        let out = text(&fixture(), 160);
        assert_line(&out, "unity 3/4 3 2h28m 72 24% razer-laptop:4");
        assert_line(&out, "light 0/2 1 1m 40 80% -");
        assert_line(&out, "windows 0/1 0 - - - -");
        let order: Vec<&str> = out
            .lines()
            .skip_while(|l| !l.starts_with("POOL "))
            .skip(1)
            .take_while(|l| !l.trim().is_empty())
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
            "razer-laptop unity unity-core-playground #1110 PlayMode 4 1h33m! feat/automatch-phase",
        );
        assert!(!out.contains("36m!"));
        let p = Palette::default();
        let lines = page(Tab::Overview, &i, p, 0, 160, &hosts());
        let span = lines
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content == "1h33m!")
            .unwrap();
        assert_eq!(span.style, p.warn());
    }

    #[test]
    fn a_stuck_run_is_down_and_out_of_the_queue_and_its_oldest_wait() {
        let out = text(&fixture(), 160);
        assert!(has(&out, "stuck run: platform develop, 45d17h, no jobs"));
        assert!(has(&out, "QUEUED 4 jobs in 2 groups, oldest waiting 2h28m"));
        assert!(
            has(&out, "DOWN mini-1 offline"),
            "an offline runner is in DOWN by name"
        );
    }

    #[test]
    fn the_queue_groups_by_pool_repo_pr_and_branch_with_count_and_oldest_wait() {
        let out = text(&fixture(), 160);
        assert_line(
            &out,
            "unity unity-core-playground #412 3 2h28m feat/apociseum-third",
        );
        assert_line(&out, "light platform - 1 1m develop");
    }

    #[test]
    fn the_overview_queue_counts_the_groups_it_does_not_list() {
        let mut i = fixture();
        let rows = (0..QUEUE_ROWS + 3)
            .map(|n| (json!({"pool": "unity", "repo": "r", "branch": format!("b{n}"), "stuck": "false"}), "60"))
            .collect();
        i.instant.insert("waiting", series(rows));
        let out = text(&i, 160);
        assert!(has(&out, "+3 more groups"), "{out}");
    }

    #[test]
    fn finished_lists_the_worst_pass_rate_first_cancels_apart_and_folds_the_green() {
        let out = text(&fixture(), 160);
        // Pass is success of success + failure: Tests 12 of 50 is 24%, its 22 cancels are not
        // failures. Multi (0%, 14 failed) sorts above Tests (24%, 38 failed).
        assert!(has(
            &out,
            "FINISHED 24H 171 runs, 38% pass, 91 failed, 25 cancelled"
        ));
        let order: Vec<&str> = out
            .lines()
            .skip_while(|l| !l.trim_start().starts_with("PASS "))
            .skip(1)
            .take_while(|l| {
                l.trim_start()
                    .starts_with(|c: char| c.is_ascii_digit() || c == '-')
            })
            .map(|l| l.split_whitespace().last().unwrap())
            .collect();
        assert_eq!(order, ["catalog", "Multi", "Tests", "Docs"]);
        assert_line(&out, "0% 39 39 0 unity-core-playground Game catalog");
        assert_line(&out, "24% 72 38 22 unity-core-playground Tests");
        assert_line(&out, "100% 8 0 3 unity-core-playground Docs");
        assert!(has(&out, "+2 green workflows, 38 runs"));
        assert!(!out.contains("Checks"));
    }

    #[test]
    fn finished_with_no_series_says_so() {
        let mut i = fixture();
        i.instant.insert("finished", vec![]);
        assert!(has(
            &text(&i, 160),
            "FINISHED 24H no finished-run series yet"
        ));
    }

    #[test]
    fn a_pass_rate_is_red_under_70_and_amber_under_90() {
        let p = Palette::default();
        let lines = page(Tab::Overview, &fixture(), p, 0, 160, &hosts());
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
    fn the_domain_strip_and_numbers_come_from_the_cc_series_and_ci_with_no_status_is_nodata() {
        let out = text(&fixture(), 160);
        assert!(has(&out, "OVERALL RED"));
        assert!(has(&out, "k3s OK ci NODATA llm RED"));
        assert!(has(&out, "ci busy 3/7 waiting 4"));
        assert!(has(&out, "red now: watch mac_studio_mlx"));
    }

    #[test]
    fn narrowing_the_machines_drops_temp_then_mem_then_6h() {
        let i = fixture();
        assert_line(&text(&i, 46), "razer-laptop 91% 31% 9.8/16 60% unity 3/4");
        assert_line(&text(&i, 40), "razer-laptop 91% 9.8/16 unity 3/4");
    }

    #[test]
    fn a_narrow_terminal_keeps_each_runs_machine_repo_and_pr_and_nothing_wraps() {
        let out = text(&fixture(), 60);
        assert!(
            out.lines()
                .any(|l| squash(l).starts_with("razer-laptop unity-core-playground #412")),
            "{out}"
        );
        let long: Vec<&str> = out.lines().filter(|l| l.chars().count() > 60).collect();
        assert!(long.is_empty(), "{long:#?}");
    }

    #[test]
    fn github_api_failing_is_said_in_down() {
        let mut i = fixture();
        i.instant.insert("api", series(vec![(json!({}), "0")]));
        assert!(has(&text(&i, 160), "GitHub API not answering"));
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
        let out = text(&i, 160);
        assert_line(
            &out,
            "workstation unity-local unity-core-playground #412 PlayMode 36m feat/apociseum-third",
        );
        // No repo label (an older fleet-assess): the worktree stands in, and no PR is guessed.
        assert_line(
            &out,
            "workstation unity-local unity-core-playgroun~ - EditMode 45s fix/x",
        );
        // Without published local slots the machine counts its gates and invents no capacity.
        assert_line(&out, "workstation - - - - - 2 gates");
        assert!(!out.lines().any(|l| l.starts_with("unity-local ")));
    }

    #[test]
    fn published_local_slots_read_like_a_pool() {
        let mut i = fixture();
        with_gates(&mut i);
        with_local_slots(&mut i);
        let out = text(&i, 160);
        assert_line(&out, "workstation - - - - - unity-local 2/4+6");
        assert_line(&out, "unity-local 2/4+6 1 - 14 50% workstation");
        assert!(has(&out, "ci busy 5/11 waiting 5"));
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
    fn recent_runs_list_newest_first_with_how_long_each_took() {
        let mut i = fixture();
        let run = |url: &str, wf: &str, c: &str| {
            json!({"url": url, "repo": "platform", "workflow": wf,
            "branch": "develop", "event": "push", "conclusion": c})
        };
        i.instant.insert(
            "recent",
            series(vec![
                (run("u1", "Checks", "success"), "100"),
                (run("u2", "E2E", "failure"), "200"),
            ]),
        );
        i.instant
            .insert("recent_dur", series(vec![(json!({"url": "u2"}), "372")]));
        let out = text(&i, 160);
        let e2e = out.find("E2E  ").unwrap_or(usize::MAX);
        let checks = out.find("Checks").unwrap();
        assert!(e2e < checks, "newest first:\n{out}");
        assert!(
            out.lines()
                .any(|l| squash(l).ends_with("platform E2E 6m failure push develop")),
            "{out}"
        );
        assert!(
            out.lines()
                .any(|l| squash(l).ends_with("platform Checks - success push develop")),
            "{out}"
        );
    }
}
