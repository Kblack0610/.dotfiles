//! The CI job pods and what they take on each CI node, read from kube-state-metrics: the ARC
//! runner pods and the KEDA `forgejo-runner` jobs, all in `arc-runners` (home-config
//! `apps/actions-runner-controller`), plus the requests of every other pod placed on a CI node.
//! The CI board's machine rows, glance and units (`Units`: 1 unit = 1 CI core) read this (ar-5304).

use std::collections::BTreeMap;

use serde::Serialize;

use crate::infra::Infra;

/// The namespace every CI job pod runs in.
pub const NAMESPACE: &str = "arc-runners";

/// The node taint that makes a node a CI node (home-config `ci_hosts`), matched by its name:
/// its key's domain stays out of this public repo.
pub const CI_TAINT: &str = ".+/ci";

/// The taint home-config puts on a quarantined node, matched the same way.
pub const DEGRADED_TAINT: &str = ".+/degraded";

/// Each job pod starting, running or waiting for room: its phase, its node (none while
/// unscheduled) and its owner. Its requests are `requests_query`, apart, so a pod that requests
/// nothing still counts.
pub fn pods_query() -> String {
    format!(
        r#"max by (pod, phase) (kube_pod_status_phase{{namespace="{NAMESPACE}",phase=~"Pending|Running"}} == 1) * on (pod) group_left (node, created_by_kind, created_by_name) max by (pod, node, created_by_kind, created_by_name) (kube_pod_info{{namespace="{NAMESPACE}"}})"#
    )
}

/// Each job pod's CPU and memory requests, summed over its containers.
pub fn requests_query() -> String {
    format!(
        r#"sum by (pod, resource) (kube_pod_container_resource_requests{{namespace="{NAMESPACE}",resource=~"cpu|memory"}})"#
    )
}

/// What the pods of every other namespace (the registry, crowdsec, monitoring's DaemonSets)
/// request on each CI node while they start or run: the scheduler counts them against the same
/// allocatable, so a unit they hold is no free unit.
pub fn other_query() -> String {
    format!(
        r#"sum by (node, resource) ((kube_pod_container_resource_requests{{namespace!="{NAMESPACE}",resource=~"cpu|memory"}} and on (node) kube_node_spec_taint{{key=~"{CI_TAINT}"}}) * on (namespace, pod) group_left () max by (namespace, pod) (kube_pod_status_phase{{phase=~"Pending|Running"}} == 1))"#
    )
}

/// Each CI node's allocatable CPU and memory.
pub fn alloc_query() -> String {
    format!(
        r#"max by (node, resource) (kube_node_status_allocatable{{resource=~"cpu|memory"}}) and on (node) kube_node_spec_taint{{key=~"{CI_TAINT}"}}"#
    )
}

/// Each node's state, one series per state it is in: `NotReady` (its Ready condition is not
/// true), `quarantined` (the home-config degraded taint, matched by name) or `cordoned`
/// (unschedulable). A healthy node has none.
pub fn node_state_query() -> String {
    let degraded = format!(r#"max by (node) (kube_node_spec_taint{{key=~"{DEGRADED_TAINT}"}})"#);
    let tag =
        |q: &str, state: &str| format!(r#"label_replace({q}, "state", "{state}", "node", ".*")"#);
    [
        tag(
            r#"max by (node) (kube_node_status_condition{condition="Ready",status="true"} == 0)"#,
            "NotReady",
        ),
        tag(&degraded, "quarantined"),
        tag(
            "max by (node) (kube_node_spec_unschedulable == 1)",
            "cordoned",
        ),
    ]
    .join(" or ")
}

/// One CI job pod.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct JobPod {
    pub name: String,
    /// Its scale set or ScaledJob (`kind_of`): `arc-org-light`, `forgejo-runner`; a reservation
    /// pod's DaemonSet: `ci-build-slot`.
    pub kind: String,
    /// Its machine (`Infra::aliases`); empty while the scheduler has found it no room.
    pub node: String,
    /// Its containers run: a job. A placed pod still starting books its node but runs nothing.
    /// No scale set keeps warm runners (minRunners 0), so a running pod is a job, unless it is
    /// `reserved`.
    pub running: bool,
    /// A DaemonSet pod: it sits on every node it selects, so it is never a job. Today the one is
    /// `ci-build-slot` (home-config #1514), a pause container booking the CPU of the out-of-k8s
    /// Unity build slot; any other DaemonSet added to the namespace is a reservation too.
    pub reserved: bool,
    /// Cores and bytes it requests.
    pub cpu: f64,
    pub mem: f64,
}

/// The CPU and memory every pod placed on a CI node requests (its job pods, a reservation pod,
/// and `other`), against its allocatable: what the scheduler has left for the next job.
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq)]
pub struct Booked {
    pub cpu: f64,
    pub cpu_alloc: f64,
    pub mem: f64,
    pub mem_alloc: f64,
    /// The part of `cpu` the pods of other namespaces request (`other_query`).
    pub other: f64,
}

impl Booked {
    /// A CI node: one with an allocatable read. A node whose CI taint is gone while pods still
    /// run there has none, and is no unit of the pool.
    pub fn on_ci(&self) -> bool {
        self.cpu_alloc > 0.0
    }

    /// `5.1/32 4.0G/92G`: cores taken of allocatable, then memory. A node with no allocatable
    /// read (its CI taint gone while pods still run there) reads its requests bare: `1.7 1.2G`.
    /// Halves round up, as agent-web and the waybar chip round them.
    pub fn cell(&self) -> String {
        let b = crate::host_now::bytes;
        if self.cpu_alloc <= 0.0 {
            return format!("{} {}", cores(self.cpu), b(self.mem));
        }
        format!(
            "{}/{:.0} {}/{}",
            cores(self.cpu),
            self.cpu_alloc.round(),
            b(self.mem),
            b(self.mem_alloc)
        )
    }

    /// The fuller of its CPU and memory shares: the one that stops the next pod.
    pub fn share(&self) -> f64 {
        let (c, m) = self.shares();
        c.max(m)
    }

    fn shares(&self) -> (f64, f64) {
        let s = |used: f64, of: f64| if of > 0.0 { used / of } else { 0.0 };
        (s(self.cpu, self.cpu_alloc), s(self.mem, self.mem_alloc))
    }

    /// `17.2 61%`: units taken, and their share of the node's; bare with no allocatable read.
    pub fn taken_cell(&self) -> String {
        match self.cpu_alloc > 0.0 {
            true => format!("{} {}", cores(self.cpu), percent(self.cpu / self.cpu_alloc)),
            false => cores(self.cpu),
        }
    }

    /// What is left for the next pod, in the limit that binds: `10.8 cpu` while CPU is the
    /// fuller share, `3.1G mem` once memory is. `-` with no allocatable read.
    pub fn free_cell(&self) -> String {
        if self.cpu_alloc <= 0.0 {
            return "-".into();
        }
        let (c, m) = self.shares();
        match m > c {
            true => format!(
                "{} mem",
                crate::host_now::bytes((self.mem_alloc - self.mem).max(0.0))
            ),
            false => format!("{} cpu", cores((self.cpu_alloc - self.cpu).max(0.0))),
        }
    }

    /// `28G/70G`: memory taken of allocatable; bare with none read.
    pub fn mem_cell(&self) -> String {
        let b = crate::host_now::bytes;
        match self.mem_alloc > 0.0 {
            true => format!("{}/{}", b(self.mem), b(self.mem_alloc)),
            false => b(self.mem),
        }
    }
}

/// `67%`, whole percent.
pub fn percent(share: f64) -> String {
    format!("{:.0}%", share * 100.0)
}

/// The kind of the pods of other namespaces on a CI node, in `Units`.
pub const OTHER: &str = "other";

/// One TAKEN BY row: the placed pods of one kind on the CI nodes and the units they take.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Taken {
    pub kind: String,
    /// Its pods; None for `other`, which is counted per node, not per pod.
    pub pods: Option<u32>,
    /// What one of its pods requests, when every one requests the same.
    pub each: Option<f64>,
    pub units: f64,
}

/// The CI pool in units: 1 unit is 1 CI core, a CI node's allocatable CPU, so the total moves
/// with the nodes and no config holds a copy. Taken is every pod's CPU request on a CI node,
/// the build-slot hold and other namespaces included; free is the rest; real is the CPU the
/// nodes actually use, CI or not, beside it so an idle booking shows. The words and cells are filled here
/// (`Units::words`), so the hub, agent-web and the waybar hover print the same.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Units {
    pub total: f64,
    pub taken: f64,
    /// The total less taken as printed, so the two words add up to the total: 46.05 taken and
    /// 61.95 free would print 46.1 and 62.0.
    pub free: f64,
    /// Cores busy over every CI node (`Machine::cpu` times its cores); None unless each reads.
    pub real: Option<f64>,
    /// The most units first, `other` last.
    pub by: Vec<Taken>,
    /// `CI POOL  108 units (1 unit = 1 CI core)`.
    pub head: String,
    /// `taken 72.4/108 units (67%)`: the clause the CI head lines print.
    pub brief: String,
    /// `taken 72.4 of 108 (67%), free 35.6, real use 25.1 (23%)`.
    pub line: String,
    /// The TAKEN BY header (`TAKEN_BY`) and its rows as cells, a `free` row last.
    pub columns: Vec<&'static str>,
    pub rows: Vec<Vec<String>>,
}

/// The TAKEN BY table's header.
pub const TAKEN_BY: [&str; 5] = ["TAKEN BY", "PODS", "EACH", "UNITS", "SHARE"];

impl Units {
    /// The share of the pool taken, 0 with no total.
    pub fn share(&self) -> f64 {
        match self.total > 0.0 {
            true => self.taken / self.total,
            false => 0.0,
        }
    }

    fn words(&mut self) {
        let share = |u: f64| match self.total > 0.0 {
            true => percent(u / self.total),
            false => "-".into(),
        };
        self.head = format!("CI POOL  {:.0} units (1 unit = 1 CI core)", self.total);
        self.brief = format!(
            "taken {}/{:.0} units ({})",
            cores(self.taken),
            self.total,
            share(self.taken)
        );
        let real = self
            .real
            .map_or(format!("real use {}", crate::reading::NO_DATA), |r| {
                format!("real use {} ({})", cores(r), share(r))
            });
        self.line = format!(
            "taken {} of {:.0} ({}), free {}, {real}",
            cores(self.taken),
            self.total,
            share(self.taken),
            cores(self.free)
        );
        self.columns = TAKEN_BY.to_vec();
        self.rows = self
            .by
            .iter()
            .map(|t| {
                vec![
                    t.kind.clone(),
                    t.pods.map_or("-".into(), |n| n.to_string()),
                    t.each.map_or("-".into(), |e| format!("{e:.2}")),
                    cores(t.units),
                    share(t.units),
                ]
            })
            .chain([vec![
                "free".into(),
                String::new(),
                String::new(),
                cores(self.free),
                share(self.free),
            ]])
            .collect();
    }
}

/// The pool's units from the CI nodes' requests (`booked`, those `Booked::on_ci`) and the pods
/// placed there, by kind.
/// `real` is the busy cores over those nodes, passed in by the caller that holds the machines.
/// None with no CI node read.
pub fn units(
    booked: &BTreeMap<String, Booked>,
    pods: &[JobPod],
    real: Option<f64>,
) -> Option<Units> {
    let ci: BTreeMap<&String, &Booked> = booked.iter().filter(|(_, b)| b.on_ci()).collect();
    if ci.is_empty() {
        return None;
    }
    let mut u = Units {
        real,
        ..Default::default()
    };
    let mut by: BTreeMap<&str, (u32, Vec<f64>)> = BTreeMap::new();
    for p in pods.iter().filter(|p| ci.contains_key(&p.node)) {
        let e = by.entry(p.kind.as_str()).or_default();
        e.0 += 1;
        e.1.push(p.cpu);
    }
    for b in ci.values() {
        u.total += b.cpu_alloc;
        u.taken += b.cpu;
    }
    u.free = (u.total - (u.taken * 10.0).round() / 10.0).max(0.0);
    u.by = by
        .into_iter()
        .map(|(kind, (n, cpus))| Taken {
            kind: kind.into(),
            pods: Some(n),
            each: cpus
                .iter()
                .all(|c| (c - cpus[0]).abs() < 0.005)
                .then_some(cpus[0]),
            units: cpus.iter().sum(),
        })
        .collect();
    u.by.sort_by(|a, b| {
        b.units
            .total_cmp(&a.units)
            .then_with(|| a.kind.cmp(&b.kind))
    });
    let other: f64 = ci.values().map(|b| b.other).sum();
    if other > 0.0 {
        u.by.push(Taken {
            kind: OTHER.into(),
            units: other,
            ..Default::default()
        });
    }
    u.words();
    Some(u)
}

/// Cores to one place, halves up: `4.4`.
pub fn cores(c: f64) -> String {
    format!("{:.1}", (c * 10.0).round() / 10.0)
}

/// Pods waiting for room, one row per kind and size.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Pending {
    pub kind: String,
    pub n: u32,
    /// What each one requests.
    pub cpu: f64,
    pub mem: f64,
}

impl Pending {
    /// `arc-org-light x3 (1.69 cpu 1.2G each)`.
    pub fn line(&self) -> String {
        let n = if self.n > 1 {
            format!(" x{}", self.n)
        } else {
            String::new()
        };
        let each = if self.n > 1 { " each" } else { "" };
        format!(
            "{}{n} ({} cpu {}{each})",
            self.kind,
            request(self.cpu),
            crate::host_now::bytes(self.mem)
        )
    }
}

/// `1.69`, `2`: a CPU request in cores, trailing zeros dropped.
fn request(cpu: f64) -> String {
    let n = format!("{cpu:.2}");
    n.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// The suffix of the pod ARC's kubernetes container mode runs a job's steps in, beside its runner.
const WORKFLOW_POD: &str = "-workflow";

/// The scale set or job that owns a pod: an ARC pod's EphemeralRunner is `<set>-runner-<id>`, a
/// KEDA pod's Job is `<scaledjob>-<id>`, a reservation pod's DaemonSet is its own name. What
/// `actions.github.com/scale-set-name` says, from series kube-state-metrics exports without a
/// label allowlist.
pub fn kind_of(owner_kind: &str, owner: &str, pod: &str) -> String {
    match owner_kind {
        "EphemeralRunner" => owner.rsplit_once("-runner-").map_or(owner, |(s, _)| s),
        "Job" => owner.rsplit_once('-').map_or(owner, |(s, _)| s),
        "DaemonSet" => owner,
        _ => pod,
    }
    .to_string()
}

/// Every job pod starting, running or waiting, by name, with its requests.
pub fn read(infra: &Infra) -> Vec<JobPod> {
    let alias = infra.aliases();
    let mut by: BTreeMap<&str, JobPod> = BTreeMap::new();
    for s in infra.get("job_pods") {
        let name = s.label("pod");
        if name.is_empty() {
            continue;
        }
        let node = s.label("node");
        by.insert(
            name,
            JobPod {
                name: name.into(),
                kind: kind_of(s.label("created_by_kind"), s.label("created_by_name"), name),
                node: if node.is_empty() {
                    String::new()
                } else {
                    crate::infra::host(&alias, node)
                },
                running: s.label("phase") == "Running",
                reserved: s.label("created_by_kind") == "DaemonSet",
                ..Default::default()
            },
        );
    }
    // A finished pod keeps its request series; only the pods above take theirs.
    for s in infra.get("job_requests") {
        let Some(p) = by.get_mut(s.label("pod")) else {
            continue;
        };
        let v = s.value.unwrap_or(0.0);
        match s.label("resource") {
            "cpu" => p.cpu = v,
            "memory" => p.mem = v,
            _ => {}
        }
    }
    // ARC's kubernetes container mode runs each job's steps in a `<runner pod>-workflow` pod with
    // no owner, on its runner's node (they share the work volume): one job, booked as its runner.
    let workflow: Vec<&str> = by
        .keys()
        .copied()
        .filter(|n| n.ends_with(WORKFLOW_POD))
        .collect();
    for name in workflow {
        let runner = &name[..name.len() - WORKFLOW_POD.len()];
        if by.contains_key(runner) {
            let w = by.remove(name).unwrap_or_default();
            if let Some(r) = by.get_mut(runner) {
                (r.cpu, r.mem) = (r.cpu + w.cpu, r.mem + w.mem);
            }
        }
    }
    by.into_values().collect()
}

/// Every CI node's booking: its allocatable, the requests of the job pods placed on it, and
/// those of every other pod there (`other_query`). A job pod on a node that is no CI node (its
/// taint gone) still books there, so it is never lost.
pub fn booked(infra: &Infra, pods: &[JobPod]) -> BTreeMap<String, Booked> {
    let alias = infra.aliases();
    let mut by: BTreeMap<String, Booked> = BTreeMap::new();
    for s in infra.get("ci_alloc") {
        let e = by
            .entry(crate::infra::host(&alias, s.label("node")))
            .or_default();
        let v = s.value.unwrap_or(0.0);
        match s.label("resource") {
            "cpu" => e.cpu_alloc = v,
            "memory" => e.mem_alloc = v,
            _ => {}
        }
    }
    for s in infra.get("ci_other") {
        let e = by
            .entry(crate::infra::host(&alias, s.label("node")))
            .or_default();
        let v = s.value.unwrap_or(0.0);
        match s.label("resource") {
            "cpu" => (e.cpu, e.other) = (e.cpu + v, e.other + v),
            "memory" => e.mem += v,
            _ => {}
        }
    }
    for p in pods.iter().filter(|p| !p.node.is_empty()) {
        let e = by.entry(p.node.clone()).or_default();
        e.cpu += p.cpu;
        e.mem += p.mem;
    }
    by
}

/// Each node's states by machine, worst first: `NotReady`, `quarantined`, `cordoned` (dropped
/// beside `quarantined`, which cordons the node as part of it). A healthy node is absent.
pub fn node_states(infra: &Infra) -> BTreeMap<String, String> {
    let alias = infra.aliases();
    let mut by: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for s in infra.get("node_state") {
        by.entry(crate::infra::host(&alias, s.label("node")))
            .or_default()
            .push(s.label("state"));
    }
    by.into_iter()
        .filter_map(|(h, have)| {
            let quarantined = have.contains(&"quarantined");
            let order = ["NotReady", "quarantined", "cordoned"];
            let line: Vec<&str> = order
                .into_iter()
                .filter(|o| have.contains(o) && !(quarantined && *o == "cordoned"))
                .collect();
            (!line.is_empty()).then(|| (h, line.join(", ")))
        })
        .collect()
}

/// The job pods no node has room for, grouped by kind and size, the most first. A reservation
/// pod with no node (its node is down) waits on that node, not for room.
pub fn pending(pods: &[JobPod]) -> Vec<Pending> {
    let mut by: BTreeMap<(String, u64, u64), u32> = BTreeMap::new();
    for p in pods.iter().filter(|p| p.node.is_empty() && !p.reserved) {
        *by.entry((p.kind.clone(), (p.cpu * 1000.0) as u64, p.mem as u64))
            .or_default() += 1;
    }
    let mut out: Vec<Pending> = by
        .into_iter()
        .map(|((kind, cpu, mem), n)| Pending {
            kind,
            n,
            cpu: cpu as f64 / 1000.0,
            mem: mem as f64,
        })
        .collect();
    out.sort_by(|a, b| b.n.cmp(&a.n).then_with(|| a.kind.cmp(&b.kind)));
    out
}

/// The running job pods on each node by kind: `[light]` and its count. A pod's kind is the one
/// the exporter reads off its `ci-kind` label (`Infra::job_kinds`, by runner name). A running pod
/// whose runner reports no job yet is `[starting]`. A reservation pod is no job.
pub fn running_by_node(
    pods: &[JobPod],
    kinds: &std::collections::HashMap<&str, &str>,
) -> BTreeMap<String, BTreeMap<String, u32>> {
    let mut by: BTreeMap<String, BTreeMap<String, u32>> = BTreeMap::new();
    for p in pods
        .iter()
        .filter(|p| p.running && !p.reserved && !p.node.is_empty())
    {
        *by.entry(p.node.clone())
            .or_default()
            .entry(format!(
                "[{}]",
                kinds.get(p.name.as_str()).copied().unwrap_or("starting")
            ))
            .or_default() += 1;
    }
    by
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::prom::Series;
    use serde_json::{json, Value};

    /// One pod's `job_pods` series and its two `job_requests` series. No node is a pod waiting
    /// for room; `phase` says whether its containers run.
    pub fn pod(
        name: &str,
        owner_kind: &str,
        owner: &str,
        node: &str,
        phase: &str,
        cpu: &str,
        mem: &str,
    ) -> (Series, Vec<Series>) {
        let mut m = json!({
            "pod": name, "phase": phase,
            "created_by_kind": owner_kind, "created_by_name": owner,
        });
        if !node.is_empty() {
            m["node"] = Value::from(node);
        }
        let req = ["cpu", "memory"]
            .into_iter()
            .zip([cpu, mem])
            .map(|(r, v)| one(json!({"pod": name, "resource": r}), v))
            .collect();
        (one(m, "1"), req)
    }

    fn one(m: Value, v: &str) -> Series {
        let r = json!({"status": "success", "data": {"result": [{"metric": m, "value": [0, v]}]}});
        crate::prom::flatten(&r).unwrap().remove(0)
    }

    pub fn alloc(node: &str, cpu: &str, mem: &str) -> Vec<Series> {
        ["cpu", "memory"]
            .into_iter()
            .zip([cpu, mem])
            .map(|(r, v)| one(json!({"node": node, "resource": r}), v))
            .collect()
    }

    /// Two light pods running on ms-a2, a forgejo job placed there and starting, one light pod
    /// with no room, tuf-b550 idle.
    pub fn cluster() -> Vec<(&'static str, Vec<Series>)> {
        let (pods, req): (Vec<_>, Vec<_>) = [
            pod(
                "arc-org-light-runner-z5wfp",
                "EphemeralRunner",
                "arc-org-light-runner-z5wfp",
                "ms-a2",
                "Running",
                "1.69",
                "1300000000",
            ),
            pod(
                "arc-org-light-runner-q8zhv",
                "EphemeralRunner",
                "arc-org-light-runner-q8zhv",
                "ms-a2",
                "Running",
                "1.69",
                "1300000000",
            ),
            pod(
                "forgejo-runner-667ts-7zc96",
                "Job",
                "forgejo-runner-667ts",
                "ms-a2",
                "Pending",
                "1",
                "100000000",
            ),
            pod(
                "arc-org-light-runner-kzhmj",
                "EphemeralRunner",
                "arc-org-light-runner-kzhmj",
                "",
                "Pending",
                "1.69",
                "1300000000",
            ),
        ]
        .into_iter()
        .unzip();
        // A finished pod's requests linger after its phase series is gone.
        let mut req = req.concat();
        req.extend(pod("gone-1", "Job", "gone", "ms-a2", "Running", "8", "1").1);
        let alloc = [
            alloc("ms-a2", "32", "98768805888"),
            alloc("tuf-b550", "32", "67290488832"),
        ]
        .concat();
        vec![
            ("job_pods", pods),
            ("job_requests", req),
            ("ci_alloc", alloc),
        ]
    }

    fn infra() -> Infra {
        let mut i = Infra::default();
        for (k, s) in cluster() {
            i.instant.insert(k, s);
        }
        i
    }

    #[test]
    fn a_pods_kind_is_its_scale_set_or_scaledjob() {
        assert_eq!(
            kind_of(
                "EphemeralRunner",
                "arc-repo-dotfiles-private-runner-htsm9",
                "x"
            ),
            "arc-repo-dotfiles-private"
        );
        assert_eq!(
            kind_of("Job", "forgejo-runner-667ts", "forgejo-runner-667ts-7zc96"),
            "forgejo-runner"
        );
        assert_eq!(kind_of("", "", "lone-pod"), "lone-pod");
    }

    #[test]
    fn each_ci_node_books_its_placed_pods_against_allocatable_and_the_rest_wait() {
        let i = infra();
        let pods = read(&i);
        assert_eq!(pods.len(), 4);
        let b = booked(&i, &pods);
        let ms = b["ms-a2"];
        assert_eq!(
            (format!("{:.2}", ms.cpu), ms.cpu_alloc),
            ("4.38".to_string(), 32.0)
        );
        assert_eq!(ms.mem, 2_700_000_000.0);
        assert_eq!(ms.cell(), "4.4/32 2.5G/92G");
        // A node with pods but no allocatable read books bare.
        let bare = Booked {
            cpu: 1.69,
            mem: 1_300_000_000.0,
            ..Default::default()
        };
        assert_eq!(bare.cell(), "1.7 1.2G");
        // Halves round up, as agent-web and waybar do.
        assert_eq!(cores(0.25), "0.3");
        // An idle CI node is a row with nothing booked, never absent.
        assert_eq!((b["tuf-b550"].cpu, b["tuf-b550"].cpu_alloc), (0.0, 32.0));
        let w = pending(&pods);
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].line(), "arc-org-light (1.69 cpu 1.2G)");
        let r = running_by_node(&pods, &Default::default());
        assert_eq!(r["ms-a2"]["[starting]"], 2);
        // The kind the exporter reads off a pod's `ci-kind` label names it instead of its scale set.
        let name = pods
            .iter()
            .find(|p| p.running && p.kind == "arc-org-light")
            .map(|p| p.name.clone())
            .unwrap();
        let kinds = [(name.as_str(), "light")].into();
        let by_kind = running_by_node(&pods, &kinds);
        assert_eq!(by_kind["ms-a2"]["[light]"], 1);
        // The other pod's runner reports no job yet.
        assert_eq!(by_kind["ms-a2"]["[starting]"], 1);
        // The forgejo pod books ms-a2 but is still starting: no job runs yet.
        assert!(!r["ms-a2"].contains_key("[forgejo-runner]"));
    }

    /// A `ci-build-slot` pod (a DaemonSet, home-config #1514) on each of ms-a2 and tuf-b550, and
    /// one for a node that is down, which has no node yet.
    pub fn reservations() -> (Vec<Series>, Vec<Series>) {
        let (mut pods, mut req) = (vec![], vec![]);
        for (name, node) in [
            ("ci-build-slot-aaaaa", "ms-a2"),
            ("ci-build-slot-bbbbb", "tuf-b550"),
            ("ci-build-slot-ccccc", ""),
        ] {
            let (p, r) = pod(
                name,
                "DaemonSet",
                "ci-build-slot",
                node,
                "Running",
                "7.36",
                "22100000000",
            );
            pods.push(p);
            req.extend(r);
        }
        (pods, req)
    }

    pub fn node_state(node: &str, state: &str) -> Series {
        one(json!({"node": node, "state": state}), "1")
    }

    #[test]
    fn a_container_mode_workflow_pod_is_its_runners_job_and_books_with_it() {
        let mut i = infra();
        let runner = "arc-repo-dotfiles-pods-runner-xrvxx";
        let (p1, r1) = pod(
            runner,
            "EphemeralRunner",
            runner,
            "ms-a2",
            "Running",
            "0.5",
            "1000000000",
        );
        let (p2, r2) = pod(
            &format!("{runner}-workflow"),
            "",
            "",
            "ms-a2",
            "Running",
            "0.01",
            "64000000",
        );
        let (p3, r3) = pod(
            "lone-workflow",
            "",
            "",
            "ms-a2",
            "Running",
            "0.01",
            "64000000",
        );
        i.instant.get_mut("job_pods").unwrap().extend([p1, p2, p3]);
        i.instant
            .get_mut("job_requests")
            .unwrap()
            .extend([r1, r2, r3].concat());
        let pods = read(&i);
        let r = pods.iter().find(|p| p.name == runner).unwrap();
        assert_eq!(
            (r.kind.as_str(), r.cpu, r.mem),
            ("arc-repo-dotfiles-pods", 0.51, 1064000000.0)
        );
        assert!(
            !pods.iter().any(|p| p.name == format!("{runner}-workflow")),
            "folded into its runner"
        );
        assert!(
            pods.iter().any(|p| p.name == "lone-workflow"),
            "no runner pod to fold into: kept"
        );
    }

    #[test]
    fn a_reservation_pod_books_cpu_but_is_no_job_and_waits_for_no_room() {
        let mut i = infra();
        let (pods, req) = reservations();
        i.instant.get_mut("job_pods").unwrap().extend(pods);
        i.instant.get_mut("job_requests").unwrap().extend(req);
        let pods = read(&i);
        assert!(pods
            .iter()
            .filter(|p| p.kind.starts_with("ci-build-slot"))
            .all(|p| p.reserved));
        assert!(pods
            .iter()
            .filter(|p| !p.kind.starts_with("ci-build-slot"))
            .all(|p| !p.reserved));
        let b = booked(&i, &pods);
        // Booked against allocatable like any pod, and named apart.
        assert_eq!(b["ms-a2"].cell(), "11.7/32 23G/92G");
        assert_eq!(b["tuf-b550"].cell(), "7.4/32 21G/63G");
        // The hold is its DaemonSet, a kind of its own.
        assert!(pods
            .iter()
            .filter(|p| p.reserved)
            .all(|p| p.kind == "ci-build-slot"));
        let r = running_by_node(&pods, &Default::default());
        assert_eq!(r["ms-a2"].keys().collect::<Vec<_>>(), ["[starting]"]);
        assert!(
            !r.contains_key("tuf-b550"),
            "a reservation is no job: {r:?}"
        );
        let w = pending(&pods);
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].kind, "arc-org-light");
    }

    /// The requests of other namespaces' pods on a CI node, as `other_query` answers.
    pub fn other(node: &str, cpu: &str, mem: &str) -> Vec<Series> {
        alloc(node, cpu, mem)
    }

    /// ar-6359: one org set, one repo set, a hold pod and an other pod, counted in units of the
    /// CI nodes' allocatable, by kind, with free in the limit that binds.
    #[test]
    fn the_pool_counts_every_pod_on_a_ci_node_in_units_by_kind() {
        let mut i = infra();
        let (hold, hold_req) = reservations();
        let (repo, repo_req) = pod(
            "arc-repo-dotfiles-runner-abcde",
            "EphemeralRunner",
            "arc-repo-dotfiles-runner-abcde",
            "tuf-b550",
            "Running",
            "1",
            "1000000000",
        );
        i.instant.get_mut("job_pods").unwrap().extend(hold);
        i.instant.get_mut("job_pods").unwrap().push(repo);
        i.instant.get_mut("job_requests").unwrap().extend(hold_req);
        i.instant.get_mut("job_requests").unwrap().extend(repo_req);
        i.instant
            .insert("ci_other", other("ms-a2", "3", "4000000000"));
        let pods = read(&i);
        let b = booked(&i, &pods);
        // The other pods take ms-a2's room like any pod: 4.38 jobs + 7.36 hold + 3 other.
        assert_eq!(b["ms-a2"].cell(), "14.7/32 27G/92G");
        assert_eq!(b["ms-a2"].other, 3.0);
        assert_eq!(b["ms-a2"].taken_cell(), "14.7 46%");
        assert_eq!(b["ms-a2"].free_cell(), "17.3 cpu");
        assert_eq!(b["tuf-b550"].mem_cell(), "22G/63G");
        let u = units(&b, &pods, Some(16.0)).unwrap();
        assert_eq!((u.total, format!("{:.2}", u.taken)), (64.0, "23.10".into()));
        assert_eq!(u.head, "CI POOL  64 units (1 unit = 1 CI core)");
        assert_eq!(u.brief, "taken 23.1/64 units (36%)");
        assert_eq!(
            u.line,
            "taken 23.1 of 64 (36%), free 40.9, real use 16.0 (25%)"
        );
        assert_eq!(u.columns, TAKEN_BY);
        let rows: Vec<String> = u.rows.iter().map(|r| r.join("|")).collect();
        assert_eq!(
            rows,
            [
                // Two placed holds; the third has no node, so it takes no unit.
                "ci-build-slot|2|7.36|14.7|23%",
                // Three placed light pods (one still starting), the one waiting takes none.
                "arc-org-light|2|1.69|3.4|5%",
                "arc-repo-dotfiles|1|1.00|1.0|2%",
                "forgejo-runner|1|1.00|1.0|2%",
                // Other namespaces last, then what is left.
                "other|-|-|3.0|5%",
                "free|||40.9|64%",
            ]
        );
        // Every unit is a row: the rows and free add up to the total, to the tenth printed.
        let sum: f64 = u.by.iter().map(|t| t.units).sum::<f64>() + u.free;
        assert!((sum - u.total).abs() < 0.05, "{sum}");
        // No real reading on every node is no data, never 0.
        let blind = units(&b, &pods, None).unwrap();
        assert!(blind.line.ends_with("real use no data"), "{}", blind.line);
        // No CI node read is no pool.
        assert!(units(&BTreeMap::new(), &pods, None).is_none());
    }

    /// Live 2026-11-27: 46.05 of 108 taken printed `taken 46.1, free 62.0`, 0.1 over the pool.
    #[test]
    fn taken_and_free_add_up_to_the_pool_as_printed() {
        let b = BTreeMap::from([(
            "ms-a2".to_string(),
            Booked {
                cpu: 46.05,
                cpu_alloc: 108.0,
                ..Default::default()
            },
        )]);
        let u = units(&b, &[], None).unwrap();
        assert!(
            u.line.starts_with("taken 46.1 of 108 (43%), free 61.9,"),
            "{}",
            u.line
        );
        assert_eq!(u.rows.last().unwrap()[3], "61.9");
    }

    #[test]
    fn free_names_memory_once_memory_is_the_fuller_share() {
        let b = Booked {
            cpu: 4.0,
            cpu_alloc: 20.0,
            mem: 45e9,
            mem_alloc: 50e9,
            ..Default::default()
        };
        assert_eq!(b.free_cell(), "4.7G mem");
        assert_eq!(Booked::default().free_cell(), "-");
    }

    #[test]
    fn a_node_says_not_ready_quarantined_or_cordoned_worst_first() {
        let mut i = infra();
        i.instant.insert(
            "node_state",
            vec![
                node_state("tuf-b550", "cordoned"),
                node_state("tuf-b550", "NotReady"),
                node_state("msi-b550", "cordoned"),
                node_state("msi-b550", "quarantined"),
                node_state("ms-a2", "cordoned"),
            ],
        );
        let s = node_states(&i);
        assert_eq!(s["tuf-b550"], "NotReady, cordoned");
        assert_eq!(s["msi-b550"], "quarantined");
        assert_eq!(s["ms-a2"], "cordoned");
        assert_eq!(s.len(), 3);
    }
}
