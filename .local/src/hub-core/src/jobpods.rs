//! The CI job pods and what they book on each CI node, read from kube-state-metrics: the ARC
//! runner pods and the KEDA `forgejo-runner` jobs, all in `arc-runners` (home-config
//! `apps/actions-runner-controller`). The CI board's machine rows and glance read this, not the
//! governor's slot units, which count only the topology's fixed slots (ar-5304).

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
    /// Its scale set or ScaledJob (`kind_of`): `arc-org-light`, `forgejo-runner`.
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

/// The CPU and memory job pods book on a CI node, against its allocatable.
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq)]
pub struct Booked {
    pub cpu: f64,
    /// The part of `cpu` that reservation pods hold (`JobPod::reserved`), not job pods.
    pub reserved: f64,
    pub cpu_alloc: f64,
    pub mem: f64,
    pub mem_alloc: f64,
}

impl Booked {
    /// `5.1/32 4.0G/92G`: cores booked of allocatable, then memory. A node with no allocatable
    /// read (its CI taint gone while pods still run there) reads its booking bare: `1.7 1.2G`.
    /// Halves round up, as agent-web and the waybar chip round them.
    /// A reservation adds `, 7.4 reserved`.
    pub fn cell(&self) -> String {
        let b = crate::host_now::bytes;
        let cell = if self.cpu_alloc <= 0.0 {
            format!("{} {}", cores(self.cpu), b(self.mem))
        } else {
            format!(
                "{}/{:.0} {}/{}",
                cores(self.cpu),
                self.cpu_alloc.round(),
                b(self.mem),
                b(self.mem_alloc)
            )
        };
        match self.reserved > 0.0 {
            true => format!("{cell}, {} reserved", cores(self.reserved)),
            false => cell,
        }
    }

    /// The fuller of its CPU and memory shares: the one that stops the next pod.
    pub fn share(&self) -> f64 {
        let s = |used: f64, of: f64| if of > 0.0 { used / of } else { 0.0 };
        s(self.cpu, self.cpu_alloc).max(s(self.mem, self.mem_alloc))
    }

    pub fn add(&mut self, o: &Booked) {
        self.cpu += o.cpu;
        self.reserved += o.reserved;
        self.cpu_alloc += o.cpu_alloc;
        self.mem += o.mem;
        self.mem_alloc += o.mem_alloc;
    }
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
            crate::machines::weight_text(self.cpu, true),
            crate::host_now::bytes(self.mem)
        )
    }
}

/// The scale set or job that owns a pod: an ARC pod's EphemeralRunner is `<set>-runner-<id>`, a
/// KEDA pod's Job is `<scaledjob>-<id>`. What `actions.github.com/scale-set-name` says, from
/// series kube-state-metrics exports without a label allowlist.
pub fn kind_of(owner_kind: &str, owner: &str, pod: &str) -> String {
    match owner_kind {
        "EphemeralRunner" => owner.rsplit_once("-runner-").map_or(owner, |(s, _)| s),
        "Job" => owner.rsplit_once('-').map_or(owner, |(s, _)| s),
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
    by.into_values().collect()
}

/// Every CI node's booking: its allocatable, and the requests of the job pods placed on it.
/// A pod on a node that is no CI node (its taint gone) still books there, so it is never lost.
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
    for p in pods.iter().filter(|p| !p.node.is_empty()) {
        let e = by.entry(p.node.clone()).or_default();
        e.cpu += p.cpu;
        e.mem += p.mem;
        if p.reserved {
            e.reserved += p.cpu;
        }
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
        assert_eq!(b["ms-a2"].cell(), "11.7/32 23G/92G, 7.4 reserved");
        assert_eq!(b["tuf-b550"].cell(), "7.4/32 21G/63G, 7.4 reserved");
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
