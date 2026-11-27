//! Where the cluster's cores and memory go: the Space section of Infra > Machines and each
//! machine's split, read once for the hub TUI and agent-web (plan curried-squishing-mountain).
//! It reads the `cc:host_class_*` and `cc:host_ns_cores` rules (home-config
//! `apps/monitoring/prometheus-rules-command-center.yaml`), which already carry the split by
//! class, so nothing here measures a class or derives one from another: not named `capacity`,
//! which is the Sessions header (`capacity.rs`).
//!
//! Every class has a measured `used` and, where something reserves, a declared `reserved`; room
//! is reserved less used, and a class that reserves nothing has a dash, never a made-up cap. A
//! reading a host lacks is `reading::NO_DATA`, never 0: a host with no node inventory (Macs,
//! Windows, AWS) has no split and is named under the header instead.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::Serialize;

use crate::infra::{self, Infra};
use crate::links::Link;
use crate::machine_page::{short, whole};
use crate::machines::Machine;
use crate::reading::NO_DATA;

/// The classes, in the order both surfaces list them; `free` closes the list.
pub const CLASSES: [&str; 6] = ["ci", "apps", "agents", "docker", "other", "free"];
/// The columns of the class table, as `Class::cells` gives them.
pub const COLUMNS: [&str; 7] = [
    "class",
    "cores used",
    "reserved",
    "room",
    "mem used",
    "reserved",
    "machines",
];
const GIB: f64 = 1024.0 * 1024.0 * 1024.0;
/// The namespaces the apps row names, busiest first.
const NAMESPACES: usize = 3;

/// One class on one machine, or summed over the cluster.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Use {
    pub class: &'static str,
    /// Cores and memory (bytes) the class uses; for `free` what is left.
    pub cores: Option<f64>,
    pub mem: Option<f64>,
    /// What the class holds back, where something does.
    pub reserved_cores: Option<f64>,
    pub reserved_mem: Option<f64>,
}

impl Use {
    /// Reserved cores not yet used; none where nothing reserves.
    pub fn room(&self) -> Option<f64> {
        Some((self.reserved_cores? - self.cores.unwrap_or(0.0)).max(0.0))
    }

    /// `ci 3.1 of 8 cores, 12G of 16G`: what one machine's row hovers and its page says. The
    /// reserved half is left out where nothing reserves.
    pub fn line(&self) -> String {
        let cores = match (self.cores, self.reserved_cores) {
            (None, _) => format!("cores {NO_DATA}"),
            (Some(c), Some(r)) => format!("{} of {} cores", short(c), short(r)),
            (Some(c), None) => format!("{} cores", short(c)),
        };
        let mem = match (self.mem, self.reserved_mem) {
            (None, _) => format!("mem {NO_DATA}"),
            (Some(m), Some(r)) => format!("{} of {}", gib(m), gib(r)),
            (Some(m), None) => gib(m),
        };
        format!("{} {cores}, {mem}", self.class)
    }
}

/// Memory as the Space section says it: `118G`.
fn gib(bytes: f64) -> String {
    format!("{}G", whole(bytes / GIB))
}

/// One machine's classes, in `CLASSES` order, only the ones it has a series for.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct HostSplit {
    pub host: String,
    pub classes: Vec<Use>,
}

impl HostSplit {
    pub fn class(&self, class: &str) -> Option<&Use> {
        self.classes.iter().find(|u| u.class == class)
    }
}

/// One class summed over the machines that report it.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Class {
    #[serde(flatten)]
    pub total: Use,
    pub room: Option<f64>,
    /// How many machines report it.
    pub machines: u32,
    /// What the row adds: the agents' run units, the apps' busiest namespaces.
    pub note: String,
    /// The row as the table draws it (`COLUMNS`), so both surfaces say the same words.
    pub cells: Vec<String>,
}

/// The cluster's Space: its total, one row per class, each machine's split, and who has none.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Space {
    /// Cores busy, as `busy_cores` reads each machine, of the cores of the machines read.
    pub cores_busy: Option<f64>,
    pub cores: Option<f64>,
    pub mem_used: Option<f64>,
    pub mem_total: Option<f64>,
    /// Machines with a split, of machines that report their cores.
    pub read: u32,
    pub of: u32,
    /// The machines that report but have no split (no node inventory), sorted.
    pub no_split: Vec<String>,
    /// The class table's header (`COLUMNS`), so the web draws the words Rust chose.
    pub columns: Vec<&'static str>,
    pub classes: Vec<Class>,
    pub by_host: Vec<HostSplit>,
    /// The apps class by k3s namespace, busiest first.
    pub namespaces: Vec<(String, f64)>,
    /// Run units the agent sessions hold, and the units the machines take.
    pub units: Option<f64>,
    pub units_max: Option<f64>,
    /// Jobs finished in 24h, a badge: what got done lives on the Job kinds table it links to.
    pub done: u32,
    pub done_link: Option<Link>,
    /// The header and the no-split note as both surfaces say them (`Space::words`).
    pub head: String,
    pub no_split_note: String,
}

impl Space {
    /// The machine's split, when it has one.
    pub fn host(&self, host: &str) -> Option<&HostSplit> {
        self.by_host.iter().find(|h| h.host == host)
    }

    /// Fill `head` and `no_split_note`: `cores 54 of 236 busy, mem 310 of 640G, 17 of 19 machines
    /// read` (`no data` for each reading it lacks), and `no split: mac-mini, windows-media-ci (no
    /// node inventory there)` or empty.
    fn words(&mut self) {
        self.head = self.head_line();
        self.no_split_note = if self.no_split.is_empty() {
            String::new()
        } else {
            format!(
                "no split: {} (no node inventory there)",
                self.no_split.join(", ")
            )
        };
    }

    fn head_line(&self) -> String {
        let cores = match (self.cores_busy, self.cores) {
            (Some(b), Some(c)) => format!("cores {} of {} busy", short(b), whole(c)),
            _ => format!("cores {NO_DATA}"),
        };
        let mem = match (self.mem_used, self.mem_total) {
            (Some(u), Some(t)) => format!("mem {} of {}", whole(u / GIB), gib(t)),
            _ => format!("mem {NO_DATA}"),
        };
        format!("{cores}, {mem}, {} of {} machines read", self.read, self.of)
    }
}

/// `busy` cores of a machine: its cores times its busy share.
pub fn busy_cores(m: &Machine) -> Option<f64> {
    Some(m.cores? * m.cpu?)
}

/// The class rules' answers, by host and class.
fn read(
    infra: &Infra,
) -> (
    BTreeMap<String, BTreeMap<&'static str, Use>>,
    BTreeSet<String>,
) {
    let alias = infra.aliases();
    let mut by: BTreeMap<String, BTreeMap<&'static str, Use>> = BTreeMap::new();
    let mut inventory = BTreeSet::new();
    for s in infra.get("cc") {
        let name = s.label("__name__");
        let host = infra::host(&alias, s.label("host"));
        if host.is_empty() {
            continue;
        }
        let Some(v) = s.value else { continue };
        if name == "cc:host_inventory" {
            inventory.insert(host);
            continue;
        }
        let Some(class) = CLASSES.iter().find(|c| **c == s.label("class")) else {
            continue;
        };
        let u = by
            .entry(host)
            .or_default()
            .entry(class)
            .or_insert_with(|| Use {
                class,
                ..Use::default()
            });
        match name {
            "cc:host_class_cores" => u.cores = Some(v),
            "cc:host_class_mem_bytes" => u.mem = Some(v),
            "cc:host_class_reserved_cores" => u.reserved_cores = Some(v),
            "cc:host_class_reserved_mem_bytes" => u.reserved_mem = Some(v),
            _ => {}
        }
    }
    (by, inventory)
}

/// The Space of the cluster, over the machines `machines::build` made. A machine reads when it
/// has a node inventory, which is what publishes agents, docker, other and free; the CI and apps
/// rows a machine without one still has are kept on its split, so its page shows them.
pub fn build(infra: &Infra, machines: &[Machine]) -> Space {
    let (by, inventory) = read(infra);
    let mut sp = Space::default();
    let reporting: Vec<&Machine> = machines.iter().filter(|m| m.cores.is_some()).collect();
    sp.of = reporting.len() as u32;
    let sum = |f: &dyn Fn(&Machine) -> Option<f64>| -> Option<f64> {
        let v: Vec<f64> = reporting.iter().filter_map(|m| f(m)).collect();
        (!v.is_empty()).then(|| v.iter().sum())
    };
    // Each ratio's total is summed over the machines its used is, so a machine with no reading
    // never makes the cluster read emptier than it is.
    sp.cores = sum(&|m| busy_cores(m).and(m.cores));
    sp.cores_busy = sum(&busy_cores);
    sp.mem_used = sum(&|m| m.mem_used);
    sp.mem_total = sum(&|m| m.mem_used.and(m.mem_total));
    for m in &reporting {
        if inventory.contains(&m.host) {
            sp.read += 1;
        } else {
            sp.no_split.push(m.host.clone());
        }
    }
    sp.no_split.sort();
    for (host, classes) in by {
        sp.by_host.push(HostSplit {
            host,
            classes: CLASSES
                .iter()
                .filter_map(|c| classes.get(c).cloned())
                .collect(),
        });
    }
    let by_ns = namespaces(infra);
    let units = |name: &str| -> Option<f64> {
        let v: Vec<f64> = infra
            .get("cc")
            .iter()
            .filter(|s| s.label("__name__") == name)
            .filter_map(|s| s.value)
            .collect();
        (!v.is_empty()).then(|| v.iter().sum())
    };
    (sp.units, sp.units_max) = (units("cc:host_run_units"), units("cc:host_run_units_max"));
    sp.classes = CLASSES
        .iter()
        .filter_map(|c| class(&sp, c, &by_ns))
        .collect();
    sp.namespaces = by_ns;
    // The pools' done 24h, as `ci::glance` sums them: the glance itself is built after this.
    sp.done = infra
        .pools
        .iter()
        .map(|p| p.done.unwrap_or(0.0) as u32)
        .sum();
    sp.done_link = Some(Link::tab("infra"));
    sp.columns = COLUMNS.to_vec();
    sp.words();
    sp
}

/// The apps class by namespace, summed over machines, busiest first.
fn namespaces(infra: &Infra) -> Vec<(String, f64)> {
    let mut by: HashMap<&str, f64> = HashMap::new();
    for s in infra
        .get("cc")
        .iter()
        .filter(|s| s.label("__name__") == "cc:host_ns_cores")
    {
        if let Some(v) = s.value {
            *by.entry(s.label("namespace")).or_default() += v;
        }
    }
    let mut out: Vec<(String, f64)> = by.into_iter().map(|(n, v)| (n.to_string(), v)).collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out
}

/// One class's row: each reading summed over the machines that have it, `None` where none does.
fn class(sp: &Space, name: &'static str, by_ns: &[(String, f64)]) -> Option<Class> {
    let rows: Vec<&Use> = sp.by_host.iter().filter_map(|h| h.class(name)).collect();
    if rows.is_empty() {
        return None;
    }
    let add = |f: &dyn Fn(&Use) -> Option<f64>| -> Option<f64> {
        let v: Vec<f64> = rows.iter().filter_map(|u| f(u)).collect();
        (!v.is_empty()).then(|| v.iter().sum())
    };
    let total = Use {
        class: name,
        cores: add(&|u| u.cores),
        mem: add(&|u| u.mem),
        reserved_cores: add(&|u| u.reserved_cores),
        reserved_mem: add(&|u| u.reserved_mem),
    };
    // Room is each machine's own reserved less used, so a machine over its cpuset does not take
    // room from one under it.
    let room = add(&|u| u.room());
    let note = match name {
        "agents" => match (sp.units, sp.units_max) {
            (Some(u), Some(m)) => format!("run units {} of {}", whole(u), whole(m)),
            (Some(u), None) => format!("run units {}", whole(u)),
            _ => String::new(),
        },
        "apps" => by_ns
            .iter()
            .take(NAMESPACES)
            .map(|(n, v)| format!("{n} {}", short(*v)))
            .collect::<Vec<_>>()
            .join(", "),
        _ => String::new(),
    };
    let dash = |v: Option<f64>, f: &dyn Fn(f64) -> String| v.map_or("-".to_string(), f);
    let cells = vec![
        name.to_string(),
        dash(total.cores, &short),
        dash(total.reserved_cores, &short),
        dash(room, &short),
        dash(total.mem, &gib),
        dash(total.reserved_mem, &gib),
        rows.len().to_string(),
    ];
    Some(Class {
        total,
        room,
        machines: rows.len() as u32,
        note,
        cells,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machines::tests::series;
    use serde_json::json;

    fn cc(name: &str, host: &str, class: &str, v: f64) -> serde_json::Value {
        json!({"__name__": name, "host": host, "class": class, "v": v.to_string()})
    }

    fn host(name: &str, v: f64, host: &str) -> serde_json::Value {
        json!({"__name__": name, "host": host, "v": v.to_string()})
    }

    /// Two machines with a split and one without: the cc series as Prometheus answers them.
    fn infra() -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        let g = GIB;
        let mut rows = vec![
            host("cc:host_cores", 16.0, "razer"),
            host("cc:host_cpu_busy_ratio", 0.05, "razer"),
            host("cc:host_mem_used_bytes", 8.0 * g, "razer"),
            host("cc:host_mem_total_bytes", 32.0 * g, "razer"),
            host("cc:host_cores", 24.0, "victus"),
            host("cc:host_cpu_busy_ratio", 0.1, "victus"),
            host("cc:host_cores", 8.0, "mini"),
            host("cc:host_cpu_busy_ratio", 0.2, "mini"),
            host("cc:host_inventory", 1.0, "razer"),
            host("cc:host_inventory", 1.0, "victus"),
            host("cc:host_run_units", 3.0, "razer"),
            host("cc:host_run_units_max", 5.0, "razer"),
            json!({"__name__": "cc:host_ns_cores", "host": "victus", "namespace": "media", "v": "0.6"}),
            json!({"__name__": "cc:host_ns_cores", "host": "victus", "namespace": "monitoring", "v": "0.2"}),
        ];
        for (h, class, cores, mem) in [
            ("razer", "agents", 0.5, 2.0),
            ("razer", "other", 0.3, 1.0),
            ("razer", "free", 15.2, 24.0),
            ("victus", "apps", 0.8, 6.0),
            ("victus", "other", 0.2, 1.0),
            ("victus", "free", 22.0, 40.0),
            // the machine with no inventory still has a CI reading
            ("mini", "ci", 1.0, 3.0),
        ] {
            rows.push(cc("cc:host_class_cores", h, class, cores));
            rows.push(cc("cc:host_class_mem_bytes", h, class, mem * g));
        }
        rows.push(json!({"__name__": "cc:pool_done_24h", "pool": "unity", "v": "212"}));
        rows.push(cc("cc:host_class_reserved_cores", "razer", "agents", 6.0));
        rows.push(cc("cc:host_class_reserved_cores", "victus", "apps", 1.0));
        i.instant.insert("cc", series(rows));
        i
    }

    fn space() -> Space {
        let mut i = infra();
        i.derive();
        i.space
    }

    #[test]
    fn the_header_counts_the_machines_that_have_a_split() {
        let s = space();
        assert_eq!((s.read, s.of), (2, 3));
        assert_eq!(s.no_split, ["mini"]);
        assert_eq!(
            s.head,
            "cores 4.8 of 48 busy, mem 8 of 32G, 2 of 3 machines read"
        );
        assert_eq!(s.no_split_note, "no split: mini (no node inventory there)");
    }

    #[test]
    fn a_class_sums_its_machines_and_room_is_reserved_less_used() {
        let s = space();
        let agents = s
            .classes
            .iter()
            .find(|c| c.total.class == "agents")
            .unwrap();
        assert_eq!(
            agents.cells,
            ["agents", "0.5", "6.0", "5.5", "2G", "-", "1"]
        );
        assert_eq!(agents.note, "run units 3 of 5");
        let apps = s.classes.iter().find(|c| c.total.class == "apps").unwrap();
        assert_eq!(apps.note, "media 0.6, monitoring 0.2");
        assert!((apps.room.unwrap() - 0.2).abs() < 1e-9);
    }

    #[test]
    fn a_class_nobody_reports_is_absent_not_zero() {
        let s = space();
        assert!(s.classes.iter().all(|c| c.total.class != "docker"));
        let ci = s.classes.iter().find(|c| c.total.class == "ci").unwrap();
        assert_eq!(
            (ci.machines, ci.room),
            (1, None),
            "CI reads on the no-split mac"
        );
    }

    #[test]
    fn dropping_a_hosts_inventory_moves_it_under_no_split() {
        let mut i = infra();
        let cc = i.instant.get_mut("cc").unwrap();
        cc.retain(|s| !(s.label("__name__") == "cc:host_inventory" && s.label("host") == "victus"));
        let (machines, _) = crate::machines::build(&i);
        let s = build(&i, &machines);
        assert_eq!(s.head.rsplit(", ").next().unwrap(), "1 of 3 machines read");
        assert_eq!(s.no_split, ["mini", "victus"]);
    }

    #[test]
    fn no_class_series_at_all_reads_no_data() {
        let mut i = infra();
        i.instant.get_mut("cc").unwrap().retain(|s| {
            !s.label("__name__").starts_with("cc:host_class")
                && s.label("__name__") != "cc:host_inventory"
        });
        let (machines, _) = crate::machines::build(&i);
        let s = build(&i, &machines);
        assert!(s.classes.is_empty() && s.by_host.is_empty());
        assert_eq!((s.read, s.of), (0, 3));
        let empty = build(&Infra::default(), &[]);
        assert_eq!(
            empty.head,
            "cores no data, mem no data, 0 of 0 machines read"
        );
    }

    #[test]
    fn a_machines_split_lines_say_reserved_only_where_something_reserves() {
        let s = space();
        let razer = s.host("razer").unwrap();
        assert_eq!(
            razer.class("agents").unwrap().line(),
            "agents 0.5 of 6.0 cores, 2G"
        );
        assert_eq!(razer.class("other").unwrap().line(), "other 0.3 cores, 1G");
        assert!(s.host("nope").is_none());
    }

    #[test]
    fn the_done_badge_links_to_the_job_kinds() {
        let s = space();
        assert_eq!(s.done, 212);
        let link = s.done_link.expect("a link");
        assert_eq!(
            link.tab_args(),
            Some(("infra", String::new())),
            "Infra opens on Machines, where Job kinds sit under Space"
        );
    }

    #[test]
    fn a_machine_with_no_busy_reading_is_not_in_the_total_either() {
        let mut i = infra();
        i.derive();
        let mut ms = i.machines.clone();
        ms.push(Machine {
            host: "ghost".into(),
            cores: Some(100.0),
            ..Machine::default()
        });
        let with = build(&i, &ms);
        assert_eq!(
            with.cores, i.space.cores,
            "100 unread cores do not dilute the load"
        );
        assert_eq!(
            with.of,
            i.space.of + 1,
            "but the machine is counted as one that reports"
        );
    }

    #[test]
    fn the_badge_counts_what_the_glance_counts() {
        let mut i = infra();
        i.derive();
        assert_eq!(i.space.done, i.ci.glance.done);
        assert!(
            i.space.done > 0,
            "derive builds the space after the pools it counts"
        );
    }
}
