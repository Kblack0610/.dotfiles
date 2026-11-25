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

/// Each job pod starting, running or waiting for room, once per resource: its requests summed
/// over its containers, its node (none while unscheduled), its phase and its owner.
pub fn pods_query() -> String {
    format!(
        r#"sum by (pod, node, resource) (kube_pod_container_resource_requests{{namespace="{NAMESPACE}",resource=~"cpu|memory"}}) * on (pod) group_left (phase, created_by_kind, created_by_name) (max by (pod, phase) (kube_pod_status_phase{{namespace="{NAMESPACE}",phase=~"Pending|Running"}} == 1) * on (pod) group_left (created_by_kind, created_by_name) max by (pod, created_by_kind, created_by_name) (kube_pod_info{{namespace="{NAMESPACE}"}}))"#
    )
}

/// Each CI node's allocatable CPU and memory.
pub fn alloc_query() -> String {
    format!(
        r#"max by (node, resource) (kube_node_status_allocatable{{resource=~"cpu|memory"}}) and on (node) kube_node_spec_taint{{key=~"{CI_TAINT}"}}"#
    )
}

/// One CI job pod.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct JobPod {
    pub name: String,
    /// Its scale set or ScaledJob (`kind_of`): `arc-org-light`, `forgejo-runner`.
    pub kind: String,
    /// Its machine (`Infra::aliases`); empty while the scheduler has found it no room.
    pub node: String,
    /// Cores and bytes it requests.
    pub cpu: f64,
    pub mem: f64,
}

/// The CPU and memory job pods book on a CI node, against its allocatable.
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq)]
pub struct Booked {
    pub cpu: f64,
    pub cpu_alloc: f64,
    pub mem: f64,
    pub mem_alloc: f64,
}

impl Booked {
    /// `5.1/32 4.0G/92G`: cores booked of allocatable, then memory.
    pub fn cell(&self) -> String {
        let b = crate::host_now::bytes;
        format!(
            "{:.1}/{:.0} {}/{}",
            self.cpu,
            self.cpu_alloc,
            b(self.mem),
            b(self.mem_alloc)
        )
    }

    /// The fuller of its CPU and memory shares: the one that stops the next pod.
    pub fn share(&self) -> f64 {
        let s = |used: f64, of: f64| if of > 0.0 { used / of } else { 0.0 };
        s(self.cpu, self.cpu_alloc).max(s(self.mem, self.mem_alloc))
    }

    pub fn add(&mut self, o: &Booked) {
        self.cpu += o.cpu;
        self.cpu_alloc += o.cpu_alloc;
        self.mem += o.mem;
        self.mem_alloc += o.mem_alloc;
    }
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

/// Every job pod starting, running or waiting, by name.
pub fn read(infra: &Infra) -> Vec<JobPod> {
    let alias = infra.aliases();
    let mut by: BTreeMap<&str, JobPod> = BTreeMap::new();
    for s in infra.get("job_pods") {
        let name = s.label("pod");
        if name.is_empty() {
            continue;
        }
        let p = by.entry(name).or_insert_with(|| JobPod {
            name: name.into(),
            kind: kind_of(s.label("created_by_kind"), s.label("created_by_name"), name),
            ..Default::default()
        });
        if !s.label("node").is_empty() {
            p.node = crate::infra::host(&alias, s.label("node"));
        }
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
    }
    by
}

/// The pods no node has room for, grouped by kind and size, the most first.
pub fn pending(pods: &[JobPod]) -> Vec<Pending> {
    let mut by: BTreeMap<(String, u64, u64), u32> = BTreeMap::new();
    for p in pods.iter().filter(|p| p.node.is_empty()) {
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

/// The running pods on each node by kind, the most first: `[arc-org-light] x3`.
pub fn running_by_node(pods: &[JobPod]) -> BTreeMap<String, BTreeMap<String, u32>> {
    let mut by: BTreeMap<String, BTreeMap<String, u32>> = BTreeMap::new();
    for p in pods.iter().filter(|p| !p.node.is_empty()) {
        *by.entry(p.node.clone())
            .or_default()
            .entry(format!("[{}]", p.kind))
            .or_default() += 1;
    }
    by
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::prom::Series;
    use serde_json::{json, Value};

    pub fn pod(
        name: &str,
        owner_kind: &str,
        owner: &str,
        node: &str,
        cpu: &str,
        mem: &str,
    ) -> Vec<Series> {
        ["cpu", "memory"]
            .into_iter()
            .zip([cpu, mem])
            .map(|(r, v)| {
                let mut m = json!({
                    "pod": name, "resource": r, "phase": if node.is_empty() { "Pending" } else { "Running" },
                    "created_by_kind": owner_kind, "created_by_name": owner,
                });
                if !node.is_empty() {
                    m["node"] = Value::from(node);
                }
                one(m, v)
            })
            .collect()
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

    /// Two light pods and a forgejo job on ms-a2, one light pod with no room, tuf-b550 idle.
    pub fn cluster() -> Vec<(&'static str, Vec<Series>)> {
        let pods = [
            pod(
                "arc-org-light-runner-z5wfp",
                "EphemeralRunner",
                "arc-org-light-runner-z5wfp",
                "ms-a2",
                "1.69",
                "1300000000",
            ),
            pod(
                "arc-org-light-runner-q8zhv",
                "EphemeralRunner",
                "arc-org-light-runner-q8zhv",
                "ms-a2",
                "1.69",
                "1300000000",
            ),
            pod(
                "forgejo-runner-667ts-7zc96",
                "Job",
                "forgejo-runner-667ts",
                "ms-a2",
                "1",
                "100000000",
            ),
            pod(
                "arc-org-light-runner-kzhmj",
                "EphemeralRunner",
                "arc-org-light-runner-kzhmj",
                "",
                "1.69",
                "1300000000",
            ),
        ]
        .concat();
        let alloc = [
            alloc("ms-a2", "32", "98768805888"),
            alloc("tuf-b550", "32", "67290488832"),
        ]
        .concat();
        vec![("job_pods", pods), ("ci_alloc", alloc)]
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
        // An idle CI node is a row with nothing booked, never absent.
        assert_eq!((b["tuf-b550"].cpu, b["tuf-b550"].cpu_alloc), (0.0, 32.0));
        let w = pending(&pods);
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].line(), "arc-org-light (1.69 cpu 1.2G)");
        let r = running_by_node(&pods);
        assert_eq!(r["ms-a2"]["[arc-org-light]"], 2);
        assert_eq!(r["ms-a2"]["[forgejo-runner]"], 1);
    }
}
