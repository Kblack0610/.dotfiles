//! The Prometheus pages of `hub` (Home's infra body, CI, Machines), laid out from one
//! `hub_core::infra::Infra` answer. It judges nothing: statuses are `cc:*` rules and rows are
//! runner-exporter series, so it cannot disagree with Grafana or agent-web's Infra tab.

use std::collections::{BTreeMap, HashMap};

use hub_core::infra::Infra;
use hub_core::prom::Series;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::{clock, dur, pct, Palette};

/// A job running longer than this shows its time amber: playground ci.md calls a gate that
/// runs past about an hour a bug to fix, not a wait.
pub const LONG_RUN_SECS: f64 = 3600.0;
/// Queue groups the Home lists before it counts the rest.
pub const QUEUE_ROWS: usize = 8;
/// Recent runs the CI page lists before it counts the rest (Grafana keeps them all).
pub const RECENT_ROWS: usize = 60;

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

/// One machine's CI slots (Board::machine_slots).
#[derive(Default)]
struct MachineSlots {
    host: String,
    cloud: bool,
    busy: u32,
    slots: u32,
    /// `unity 2/2`, `unity withheld 0/1`, `unity-local 2/4+6` or `2 gates`.
    pools: Vec<String>,
}

impl MachineSlots {
    fn where_(&self) -> &'static str {
        if self.cloud {
            "cloud"
        } else {
            "local"
        }
    }
    /// busy/slots, or - when nothing is up.
    fn busy_cell(&self) -> String {
        if self.busy == 0 && self.slots == 0 {
            "-".into()
        } else {
            format!("{}/{}", self.busy, self.slots)
        }
    }
    fn pools_cell(&self) -> String {
        if self.pools.is_empty() {
            "-".into()
        } else {
            self.pools.join("  ")
        }
    }
}

pub struct Board<'a> {
    infra: &'a Infra,
    p: Palette,
    now: i64,
    /// `cc:<name>` or `cc:<name>/<domain|host|pool|site>` -> value.
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

    /// Each machine's CI slots, counted as cc:pool_slots counts them: a slot is a running
    /// runner, or an idle one the governor does not withhold. A withheld runner shows as
    /// `<pool> withheld` and is no slot. Local gate slots fold into the machine that runs them,
    /// as cc:site_slots folds them into local. Machines in CC_HOSTS first, then by name.
    fn machine_slots(&self) -> Vec<MachineSlots> {
        let withheld: Vec<&str> = self
            .infra
            .get("withheld")
            .iter()
            .map(|s| s.label("name"))
            .collect();
        let mut hosts: Vec<MachineSlots> = vec![];
        fn at<'m>(hosts: &'m mut Vec<MachineSlots>, h: &str) -> &'m mut MachineSlots {
            match hosts.iter().position(|m| m.host == h) {
                Some(i) => &mut hosts[i],
                None => {
                    hosts.push(MachineSlots {
                        host: h.to_string(),
                        ..Default::default()
                    });
                    hosts.last_mut().unwrap()
                }
            }
        }
        for h in &self.extra_hosts {
            at(&mut hosts, h);
        }
        // (host, pool) -> (busy, registered), in the pools' order (longest queue first).
        let mut per: BTreeMap<(String, usize, String), (u32, u32)> = BTreeMap::new();
        let known = self.pools_list();
        for s in &self.runners {
            let m = at(&mut hosts, lab(s, "host"));
            m.cloud |= s.label("site") == "cloud";
            let state = s.label("state");
            if !matches!(state, "running" | "idle") {
                continue;
            }
            let held = withheld.contains(&s.label("name"));
            let busy = state == "running";
            if busy || !held {
                m.slots += 1;
            }
            if busy {
                m.busy += 1;
            }
            let mut pool = lab(s, "pool").to_string();
            let rank = known.iter().position(|p| *p == pool).unwrap_or(known.len());
            if held {
                pool += " withheld";
            }
            let e = per.entry((lab(s, "host").into(), rank, pool)).or_default();
            e.1 += 1;
            if busy {
                e.0 += 1;
            }
        }
        for ((h, _, pool), (b, n)) in per {
            at(&mut hosts, &h).pools.push(format!("{pool} {b}/{n}"));
        }
        let mut gates: BTreeMap<String, u32> = BTreeMap::new();
        for g in self.infra.get("gates") {
            *gates.entry(lab(g, "host").into()).or_default() += 1;
        }
        for (h, n) in &gates {
            at(&mut hosts, h);
            if self.get(&format!("cc:host_local_slots/{h}")).is_none() {
                at(&mut hosts, h).pools.push(format!("{n} gates"));
            }
        }
        for h in self.local_hosts() {
            let busy = self.get(&format!("cc:host_local_busy/{h}")).unwrap_or(0.0) as u32;
            let open = self
                .get(&format!("cc:host_local_open_slots/{h}"))
                .unwrap_or(0.0) as u32;
            let cell = format!("unity-local {}", self.local_cell(&h));
            let m = at(&mut hosts, &h);
            m.busy += busy;
            m.slots += open.max(busy);
            m.pools.push(cell);
        }
        hosts
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
            format!(
                "lazer {}/{}",
                self.usd("cc:lazer_spend_usd"),
                self.usd("cc:lazer_budget_usd")
            ),
            format!("claude 24h {}", self.usd("cc:claude_code_cost_24h_usd")),
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

    /// The machine view. Full (the Machines tab): one row per machine with where it is, busy
    /// of its slots, its load and busy/slots per pool; narrowing drops TEMP, MEM, 6H, WHERE, then
    /// LOAD, and BUSY, CPU and POOLS stay. Compact (Home): only machines with
    /// a slot or a gate up, busiest first, and only MACHINE, WHERE, BUSY and POOLS.
    pub fn machines(&self, w: usize, compact: bool) -> Vec<Line<'static>> {
        let mut ms = self.machine_slots();
        if compact {
            ms.retain(|m| m.slots > 0 || m.busy > 0 || !m.pools.is_empty());
            ms.sort_by(|a, b| b.busy.cmp(&a.busy).then_with(|| a.host.cmp(&b.host)));
            if ms.is_empty() {
                return vec![self.heading("MACHINES", "  no CI slot up".into())];
            }
            let rows = ms
                .iter()
                .map(|m| {
                    vec![
                        m.host.clone().into(),
                        m.where_().into(),
                        m.busy_cell().into(),
                        m.pools_cell().into(),
                    ]
                })
                .collect();
            return Table {
                header: vec!["MACHINE", "WHERE", "BUSY", "POOLS"],
                rows,
                keep: vec![0, 2, 1],
                flex: Some(3),
                flexmin: 12,
                flexkeep: true,
                right: vec![2],
                ..Default::default()
            }
            .fit(w, self.p.head());
        }
        let rows: Vec<Vec<Cell>> = ms
            .iter()
            .map(|m| {
                let k = |r: &str| format!("{r}/{}", m.host);
                vec![
                    m.host.clone().into(),
                    m.where_().into(),
                    m.busy_cell().into(),
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
                    m.pools_cell().into(),
                ]
            })
            .collect();
        // POOLS asks for its widest row, but no more than room for two pools' counts, so the
        // narrowing drops the other columns to keep it whole and never reaches BUSY or CPU.
        let widest = rows
            .iter()
            .map(|r| r[8].text.chars().count())
            .max()
            .unwrap_or(0)
            .max(5);
        Table {
            header: vec![
                "MACHINE", "WHERE", "BUSY", "CPU", "6H", "LOAD", "MEM", "TEMP", "POOLS",
            ],
            rows,
            keep: vec![0, 2, 3, 5, 1, 4, 6, 7],
            flex: Some(8),
            flexmin: widest.min(24),
            flexkeep: true,
            right: vec![2, 3, 4, 5, 6, 7],
            ..Default::default()
        }
        .fit(w, self.p.head())
    }

    /// Every busy runner and local gate, grouped by machine (busiest machine first, its
    /// busy/slots on the group's first row), each job longest first: repo#PR, job, how long,
    /// and the PR title or branch. Pool and host need no column: the machine row names both.
    pub fn running(&self, w: usize) -> Vec<Line<'static>> {
        // host -> (seconds, repo#PR, job, branch - title)
        let mut by: BTreeMap<String, Vec<(f64, [String; 3])>> = BTreeMap::new();
        let pr_cell = |repo: &str, pr: &str| match pr {
            "" | "-" => repo.to_string(),
            p => format!("{repo}{p}"),
        };
        for s in &self.runners {
            if s.label("state") != "running" {
                continue;
            }
            let title = s.label("title");
            let detail = if !title.is_empty() && title != s.label("workflow") {
                title.to_string()
            } else {
                lab(s, "branch").to_string()
            };
            by.entry(lab(s, "host").into()).or_default().push((
                s.value.unwrap_or(0.0),
                [
                    pr_cell(lab(s, "repo"), &pr_of(s)),
                    lab(s, "job_name").into(),
                    detail,
                ],
            ));
        }
        // A machine that is not a runner runs its gates locally: the PR from a runner or queue
        // row on the same branch, and the worktree only when the repo is unknown.
        for g in self.infra.get("gates") {
            let repo = match g.label("repo") {
                "" => lab(g, "worktree"),
                r => r,
            };
            let branch = lab(g, "branch");
            let pr = self
                .pr_by_branch
                .get(&format!("{repo}/{branch}"))
                .cloned()
                .unwrap_or_default();
            by.entry(lab(g, "host").into()).or_default().push((
                g.value.unwrap_or(0.0),
                [
                    pr_cell(repo, &pr),
                    format!("{} (local)", lab(g, "platform")),
                    branch.into(),
                ],
            ));
        }
        if by.is_empty() {
            return vec![self.heading("RUNNING", "  nothing".into())];
        }
        let busy: HashMap<String, String> = self
            .machine_slots()
            .into_iter()
            .map(|m| (m.host.clone(), m.busy_cell()))
            .collect();
        let jobs: usize = by.values().map(Vec::len).sum();
        let mut groups: Vec<_> = by.into_iter().collect();
        groups.sort_by(|a: &(String, Vec<_>), b| {
            b.1.len().cmp(&a.1.len()).then_with(|| a.0.cmp(&b.0))
        });
        let mut rows = vec![];
        for (host, mut js) in groups {
            js.sort_by(|a, b| b.0.total_cmp(&a.0));
            for (n, (secs, [pr, job, detail])) in js.into_iter().enumerate() {
                let (t, style) = if secs.trunc() > 0.0 {
                    if secs > LONG_RUN_SECS {
                        (format!("{}!", dur(secs)), self.p.warn())
                    } else {
                        (dur(secs), Default::default())
                    }
                } else {
                    ("-".into(), Default::default())
                };
                let (h, b) = if n == 0 {
                    (host.clone(), busy.get(&host).cloned().unwrap_or("-".into()))
                } else {
                    (String::new(), String::new())
                };
                rows.push(vec![
                    h.into(),
                    b.into(),
                    pr.into(),
                    job.into(),
                    cell(t, style),
                    detail.into(),
                ]);
            }
        }
        let mut out = vec![self.heading("RUNNING", format!("  {jobs} jobs"))];
        out.extend(
            Table {
                header: vec!["MACHINE", "BUSY", "PR", "JOB", "FOR", "PR TITLE OR BRANCH"],
                rows,
                // Narrowing drops BUSY, then JOB, then the title, so machine, repo#PR and FOR stay.
                keep: vec![0, 2, 4, 3, 1],
                flex: Some(5),
                flexmin: 12,
                right: vec![1, 4],
                cap: vec![(2, 27), (3, 18)],
                ..Default::default()
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
        // A missed scrape (every exporter series stale) is told apart from a spent rate limit
        // and from GitHub not answering the exporter's runner reads, the only API failure that
        // can cost runner rows.
        let is = |q: &str, v: f64| self.infra.get(q).first().and_then(|s| s.value) == Some(v);
        if !is("exporter_up", 1.0) {
            items.insert(
                0,
                "runner exporter missed its last scrape: runner rows may be missing".into(),
            );
        } else if is("rate_left", 0.0) {
            items.insert(
                0,
                "GitHub rate limit spent: runner jobs and history unread until it resets".into(),
            );
        } else if !is("api", 1.0) {
            items.insert(
                0,
                "GitHub not answering the exporter: runner rows may be missing".into(),
            );
        } else if self.runners.is_empty() {
            items.push("no runner series from the exporter".into());
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
        Tab::Home => {
            out.extend(b.numbers(w));
            out.push(blank());
            out.extend(b.pools(w));
            out.push(blank());
            out.extend(b.machines(w, true));
            out.push(blank());
            out.extend(b.queued(w, Some(QUEUE_ROWS)));
            out.extend(b.down(w));
            out.push(blank());
            out.extend(b.finished(w, Some(0)).into_iter().take(1));
        }
        Tab::Machines => out.extend(b.machines(w, false)),
        Tab::Ci => {
            out.extend(b.running(w));
            out.push(blank());
            out.extend(b.finished(w, None));
            out.push(blank());
            out.extend(b.recent(w));
        }
        Tab::Jobs
        | Tab::Sessions
        | Tab::Today
        | Tab::History
        | Tab::Fleet
        | Tab::Queue
        | Tab::Projects => {}
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

    fn text(i: &Infra, w: usize) -> String {
        [Tab::Home, Tab::Machines, Tab::Ci]
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

    fn tab(i: &Infra, t: Tab, w: usize) -> String {
        page(t, i, Palette { no_color: true }, 0, w, &hosts())
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
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
    fn the_ci_tab_lists_each_job_under_its_machine_with_repo_pr_job_time_and_title() {
        let i = fixture();
        let ci = tab(&i, Tab::Ci, 160);
        assert!(ci.starts_with("RUNNING  3 jobs"), "{ci}");
        // The machine and its busy/slots head the group; the title stands in for the branch.
        assert_line(
            &ci,
            "razer-laptop 3/4 unity-core-playground#1110 PlayMode 4 1h33m! feat/automatch-phase",
        );
        assert_line(
            &ci,
            "unity-core-playground#412 PlayMode 2 36m Apociseum third arena",
        );
        // No PR shows the repo alone, and a title that only repeats the workflow is not shown.
        assert_line(&ci, "platform E2E 5m develop");
        // Home has the per-machine rollup instead of the job list.
        assert!(!tab(&i, Tab::Home, 160).contains("RUNNING"));
    }

    #[test]
    fn home_has_one_row_per_machine_with_a_slot_up_busiest_first() {
        let mut i = fixture();
        with_cloud(&mut i, "0");
        let out = tab(&i, Tab::Home, 160);
        assert_line(&out, "MACHINE WHERE BUSY POOLS");
        assert_line(&out, "razer-laptop local 3/4 unity 3/4");
        assert_line(&out, "aws-burst-1 cloud 1/2 unity 1/2");
        let sq = squash(&out);
        assert!(sq.find("razer-laptop local").unwrap() < sq.find("aws-burst-1 cloud").unwrap());
        // Nothing up: the offline mac-mini is DOWN's, and the workstation has no slot.
        assert!(
            !out.lines()
                .any(|l| l.starts_with("mac-mini ") || l.starts_with("workstation ")),
            "{out}"
        );
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
        let out = text(&i, 160);
        assert_line(&out, "razer-laptop local 3/3 unity 3/3 unity withheld 0/1");
    }

    #[test]
    fn a_machines_row_carries_where_busy_load_6h_cpu_and_busy_of_its_slots_per_pool() {
        let mut i = fixture();
        with_cloud(&mut i, "0");
        let out = tab(&i, Tab::Machines, 160);
        assert_line(&out, "MACHINE WHERE BUSY CPU 6H LOAD MEM TEMP POOLS");
        assert_line(
            &out,
            "razer-laptop local 3/4 91% 31% 9.8/16 60% 84C unity 3/4",
        );
        assert_line(&out, "aws-burst-1 cloud 1/2 - - - - - unity 1/2");
        // No exporter series reads - in every column, never 0.
        assert_line(&out, "workstation local - - - - - - -");
        assert_line(&out, "mac-mini local - 3% - - - - -");
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
            "razer-laptop 3/4 unity-core-playground#1110 PlayMode 4 1h33m! feat/automatch-phase",
        );
        assert!(!out.contains("36m!"));
        let p = Palette::default();
        let lines = page(Tab::Ci, &i, p, 0, 160, &hosts());
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
    fn the_home_queue_counts_the_groups_it_does_not_list() {
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
        let lines = page(Tab::Home, &fixture(), p, 0, 160, &hosts());
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
        let b = Board::new(&i, Palette { no_color: true }, 0, hosts());
        let wide: Vec<String> = b.numbers(200).iter().map(plain).collect();
        let narrow: Vec<String> = b.numbers(40).iter().map(plain).collect();
        assert!(narrow.len() > wide.len(), "{narrow:?}");
        let joined = narrow.join("\n");
        for item in [
            "nodes ",
            "heartbeats ",
            "ci local 3/7 cloud 0/0, waiting 4",
            "claude 24h ",
        ] {
            assert!(joined.contains(item), "{item} lost: {narrow:?}");
        }
        assert!(narrow.iter().all(|l| !l.ends_with('~')), "{narrow:?}");
    }

    #[test]
    fn narrowing_the_machines_drops_temp_mem_6h_where_then_load() {
        let i = fixture();
        let row = |w| tab(&i, Tab::Machines, w);
        assert_line(
            &row(60),
            "razer-laptop local 3/4 91% 31% 9.8/16 60% unity 3/4",
        );
        assert_line(&row(54), "razer-laptop local 3/4 91% 31% 9.8/16 unity 3/4");
        assert_line(&row(50), "razer-laptop local 3/4 91% 9.8/16 unity 3/4");
        assert_line(&row(44), "razer-laptop 3/4 91% 9.8/16 unity 3/4");
        // At its narrowest the machine keeps its busy/slots, CPU and pools.
        assert_line(&row(40), "razer-laptop 3/4 91% unity 3/4");
    }

    #[test]
    fn a_narrow_terminal_keeps_each_runs_machine_repo_and_pr_and_nothing_wraps() {
        let out = text(&fixture(), 60);
        assert!(
            out.lines()
                .any(|l| squash(l) == "razer-laptop unity-core-playground#1110 PlayMode 4 1h33m!"),
            "{out}"
        );
        let long: Vec<&str> = out.lines().filter(|l| l.chars().count() > 60).collect();
        assert!(long.is_empty(), "{long:#?}");
    }

    #[test]
    fn github_not_answering_and_a_missed_scrape_read_differently_in_down() {
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
        let out = text(&i, 160);
        assert_line(
            &out,
            "workstation - unity-core-playground#412 PlayMode (local) 36m feat/apociseum-third",
        );
        // No repo label (an older fleet-assess): the worktree stands in, and no PR is guessed.
        assert_line(
            &out,
            "unity-core-playground-agen~ EditMode (local) 45s fix/x",
        );
        // Without published local slots the machine counts its gates and invents no capacity.
        assert_line(&out, "workstation local - - - - - - 2 gates");
        assert_line(&tab(&i, Tab::Home, 160), "workstation local - 2 gates");
        assert!(!out.lines().any(|l| l.starts_with("unity-local ")));
    }

    #[test]
    fn published_local_slots_read_like_a_pool() {
        let mut i = fixture();
        with_gates(&mut i);
        with_local_slots(&mut i);
        let out = text(&i, 160);
        assert_line(&out, "workstation local 2/4 - - - - - unity-local 2/4+6");
        assert_line(&out, "unity-local 2/4+6 1 - 14 50% workstation");
        // The gates' busy/open fold into the machine, as cc:site_slots folds them into local.
        assert_line(
            &tab(&i, Tab::Home, 160),
            "workstation local 2/4 unity-local 2/4+6",
        );
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
