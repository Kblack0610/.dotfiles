//! What runs on and inside one machine now, for its page (`#infra/machines/<host>`,
//! `machine_page`): every temperature sensor and fan by device, the Kubernetes pods on it, and,
//! where its node exporter publishes `node_inventory.prom`, its running services, Docker
//! containers, busiest processes and agent sessions. Read with instant queries only when a page is opened, never
//! on the board's cadence.
//!
//! | part       | series                                                                          |
//! |------------|---------------------------------------------------------------------------------|
//! | devices    | node exporter's `node_hwmon_temp_celsius`, `node_hwmon_fan_rpm`, named by `node_hwmon_chip_names` and `node_hwmon_sensor_label` |
//! | pods       | kube-state-metrics' `kube_pod_info{node}` (running or pending), cadvisor's `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes` |
//! | inventory  | home-config `ansible/roles/node-inventory-metrics`: `node_process_*`, `node_processes_total`, `node_service_running`, `node_docker_container_*`, `node_agent_scope_*` |
//!
//! A machine is matched by its exporter's `instance` through `cc:host_instance{host}`, and its pods
//! by the k8s node name, which is its host name.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::host_history::alternation;
use crate::prom::{self, Series};
use crate::table::{Row, Val};

/// A sensor this hot or hotter shows amber, on the Machines table and a machine's page (agent-web
/// infra.js `HOT_C` mirrors it): past where a cooled CPU sits at load, short of the 95C to 105C
/// where CPUs and NVMe drives throttle.
pub const HOT_C: f64 = 85.0;

/// What kind of part a hwmon chip is, by the driver's name: the device column's word.
const KINDS: &[(&str, &[&str])] = &[
    ("cpu", &["k10temp", "coretemp", "cpu_thermal", "zenpower"]),
    ("ram", &["spd5118", "jc42"]),
    ("gpu", &["amdgpu", "nouveau", "radeon", "nvidia"]),
    ("nvme", &["nvme"]),
    (
        "board",
        &[
            "acpitz",
            "nct6775",
            "it87",
            "asus_wmi_sensors",
            "asus",
            "hp",
            "thinkpad",
        ],
    ),
    ("nic", &["r8169", "igc", "e1000e", "ixgbe", "mlx5"]),
    (
        "wifi",
        &["iwlwifi", "mt7921", "ath11k", "ath12k", "brcmfmac"],
    ),
    ("usb", &["prom21_xhci", "xhci"]),
];
/// Devices sort in this order, then any other kind by name.
const KIND_ORDER: &[&str] = &["cpu", "ram", "gpu", "nvme", "board", "nic", "wifi", "usb"];

/// One device's temperatures and fans: `cpu` with Tctl, Tccd1 and Tccd2, or `ram 2` with one.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Device {
    /// `cpu`, `ram 2`, `nvme0`: its kind, numbered when the machine has more than one.
    pub device: String,
    /// The driver's own name: `k10temp`, `spd5118`.
    pub chip: String,
    /// Its hottest sensor now, degrees C.
    pub hottest: Option<f64>,
    /// Each sensor's label (or hwmon name) and degrees C, in hwmon order.
    pub temps: Vec<(String, f64)>,
    /// Each fan's label (or hwmon name) and RPM.
    pub fans: Vec<(String, f64)>,
}

impl Device {
    /// `Tctl 96C  Tccd1 97C  fan1 616rpm`.
    pub fn readings(&self) -> String {
        let t = self.temps.iter().map(|(n, c)| format!("{n} {c:.0}C"));
        let f = self.fans.iter().map(|(n, r)| format!("{n} {r:.0}rpm"));
        t.chain(f).collect::<Vec<_>>().join("  ")
    }
}

impl Row for Device {
    const COLUMNS: &'static [&'static str] = &["device", "hottest", "readings", "chip"];
    const STATES: &'static [&'static str] = &["all", "hot"];
    const FACETS: &'static [&'static str] = &[];
    const LEAD: &'static str = "device";
    const GLANCE: &'static [&'static str] = &["hottest"];

    fn val(&self, col: &str) -> Val {
        match col {
            "device" => Val::Text(self.device.clone()),
            "hottest" => self.hottest.into(),
            "readings" => Val::Text(self.readings()),
            "chip" => Val::Text(self.chip.clone()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        s == "hot" && self.hottest.is_some_and(|c| c >= HOT_C)
    }
}

/// One Kubernetes pod on the machine.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Pod {
    pub namespace: String,
    pub pod: String,
    /// Cores its containers used over the last 5 minutes.
    pub cpu: Option<f64>,
    /// Its containers' working set, bytes.
    pub mem: Option<f64>,
}

impl Row for Pod {
    const COLUMNS: &'static [&'static str] = &["pod", "namespace", "cpu", "mem"];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &["namespace"];
    const LEAD: &'static str = "pod";
    const GLANCE: &'static [&'static str] = &["cpu", "mem"];

    fn val(&self, col: &str) -> Val {
        match col {
            "pod" => Val::Text(self.pod.clone()),
            "namespace" => Val::Text(self.namespace.clone()),
            "cpu" => self.cpu.into(),
            "mem" => self.mem.into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        false
    }
}

/// A process name's share, or a Docker container's: what runs outside Kubernetes.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Proc {
    /// The process name (`comm`), or the container's name.
    pub name: String,
    /// A container's image; empty for a process.
    pub image: String,
    /// Cores used over the collector's last minute.
    pub cpu: Option<f64>,
    /// Resident memory, bytes.
    pub mem: Option<f64>,
    /// Processes with that name; none for a container.
    pub count: Option<f64>,
}

impl Row for Proc {
    const COLUMNS: &'static [&'static str] = &["name", "image", "cpu", "mem", "count"];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &[];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "name";
    const GLANCE: &'static [&'static str] = &["cpu", "mem"];

    fn val(&self, col: &str) -> Val {
        let text = Val::word;
        match col {
            "name" => text(&self.name),
            "image" => text(&self.image),
            "cpu" => self.cpu.into(),
            "mem" => self.mem.into(),
            "count" => self.count.into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        false
    }
}

/// One agent session's share: the systemd scope `claude-acct scope` starts it in
/// (`agent-<project>-<item>-<pid>.scope`), with the test runs inside it.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Session {
    pub project: String,
    /// Its agent-queue item; empty for a hand start.
    pub item: String,
    /// Cores used over the collector's last minute; none on the first reading of a new scope.
    pub cpu: Option<f64>,
    /// Resident memory, bytes.
    pub mem: Option<f64>,
    /// Cores each test command in it (bats, Unity, cargo, a node test runner) used, the busiest
    /// first: `bats 1.20, Unity 0.40`.
    pub tests: String,
}

impl Row for Session {
    const COLUMNS: &'static [&'static str] = &["project", "item", "cpu", "mem", "tests"];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &[];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "project";
    const GLANCE: &'static [&'static str] = &["cpu", "mem"];

    fn val(&self, col: &str) -> Val {
        let text = Val::word;
        match col {
            "project" => text(&self.project),
            "item" => text(&self.item),
            "cpu" => self.cpu.into(),
            "mem" => self.mem.into(),
            "tests" => text(&self.tests),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        false
    }
}

/// One machine now.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct HostNow {
    /// cpu first, then ram, gpu, nvme, board, then the rest by name.
    pub devices: Vec<Device>,
    /// The busiest first.
    pub pods: Vec<Pod>,
    /// Running systemd services, by name; empty when it publishes no inventory.
    pub services: Vec<String>,
    /// The busiest first.
    pub containers: Vec<Proc>,
    /// The busiest first: the collector's top names by CPU and by memory.
    pub processes: Vec<Proc>,
    /// Every process on it, of which `processes` are the top names.
    pub processes_total: Option<f64>,
    /// The busiest first: each agent session in its own scope.
    pub sessions: Vec<Session>,
    /// It publishes `node_inventory.prom`: without it services, containers and processes are
    /// unknown, not none.
    pub inventory: bool,
    /// Why each part that could not be read was not (`sensors`, `inventory`, `pods`, `pod_cpu`,
    /// `pod_mem`): its section says not read, not none; the rest still show.
    pub unread: BTreeMap<String, String>,
}

/// The queries, by part, for a machine named any of `names`.
fn queries(names: &[String]) -> Result<Vec<(&'static str, String)>, String> {
    let alt = alternation(names)?;
    let inst = format!(r#"and on (instance) cc:host_instance{{host=~"{alt}"}}"#);
    let node = format!(r#"node=~"{alt}""#);
    Ok(vec![
        (
            "sensors",
            format!(
                r#"{{__name__=~"node_hwmon_(temp_celsius|fan_rpm|chip_names|sensor_label)"}} {inst}"#
            ),
        ),
        (
            "inventory",
            format!(
                r#"{{__name__=~"node_(process_cpu_cores|process_resident_bytes|process_count|processes_total|service_running|docker_container_cpu_cores|docker_container_memory_bytes|agent_scope_cpu_cores|agent_scope_resident_bytes|agent_scope_test_cpu_cores)"}} {inst}"#
            ),
        ),
        (
            "pods",
            format!(
                r#"group by (namespace, pod) (kube_pod_info{{{node}}}) and on (namespace, pod) (kube_pod_status_phase{{phase=~"Running|Pending"}} == 1)"#
            ),
        ),
        (
            "pod_cpu",
            format!(
                r#"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{node},container!=""}}[5m]))"#
            ),
        ),
        (
            "pod_mem",
            format!(
                r#"sum by (namespace, pod) (container_memory_working_set_bytes{{{node},container!=""}})"#
            ),
        ),
    ])
}

/// Ask Prometheus for a machine named any of `names` now; each part that fails is an error line.
pub fn read(names: &[String]) -> Result<HostNow, String> {
    let qs = queries(names)?;
    let base = prom::base()?;
    let mut answers: BTreeMap<&str, Result<Vec<Series>, String>> = std::thread::scope(|s| {
        let hs: Vec<_> = qs
            .iter()
            .map(|(n, q)| (*n, s.spawn(|| prom::instant(&base, q))))
            .collect();
        hs.into_iter()
            .map(|(n, h)| (n, h.join().unwrap_or_else(|_| Err("panicked".into()))))
            .collect()
    });
    let mut unread = BTreeMap::new();
    let mut part = |n: &str| match answers.remove(n) {
        Some(Ok(s)) => s,
        Some(Err(e)) => {
            unread.insert(n.to_string(), e);
            vec![]
        }
        None => vec![],
    };
    let (sensors, inventory) = (part("sensors"), part("inventory"));
    let (pods, cpu, mem) = (part("pods"), part("pod_cpu"), part("pod_mem"));
    let mut h = build(&sensors, &inventory, &pods, &cpu, &mem);
    h.unread = unread;
    Ok(h)
}

/// A pod's or name's key and value from a series of one metric.
fn by<'a>(
    series: impl IntoIterator<Item = &'a Series>,
    key: impl Fn(&'a Series) -> String,
) -> BTreeMap<String, f64> {
    let mut out = BTreeMap::new();
    for s in series {
        if let Some(v) = s.value.filter(|v| v.is_finite()) {
            *out.entry(key(s)).or_default() += v;
        }
    }
    out
}

/// The kind of a hwmon chip by its driver's name, or the name itself.
fn kind(chip_name: &str) -> String {
    let n = chip_name.to_lowercase();
    KINDS
        .iter()
        .find(|(_, drivers)| {
            drivers
                .iter()
                .any(|d| n == *d || n.starts_with(&format!("{d}_")))
        })
        .map_or(n.clone(), |(k, _)| k.to_string())
}

/// hwmon's `temp3` or `fan1` sort in their number's order, not as text (`temp10` after `temp9`).
fn sensor_key(s: &str) -> (String, u32) {
    let digits = s.trim_start_matches(|c: char| !c.is_ascii_digit());
    (
        s[..s.len() - digits.len()].to_string(),
        digits.parse().unwrap_or(0),
    )
}

/// Every device with a temperature or fan, from the hwmon series.
fn devices(series: &[Series]) -> Vec<Device> {
    let mut chip_name: BTreeMap<&str, &str> = BTreeMap::new();
    let mut label: BTreeMap<(&str, &str), &str> = BTreeMap::new();
    for s in series {
        match s.label("__name__") {
            "node_hwmon_chip_names" => _ = chip_name.insert(s.label("chip"), s.label("chip_name")),
            "node_hwmon_sensor_label" => {
                _ = label.insert((s.label("chip"), s.label("sensor")), s.label("label"))
            }
            _ => {}
        }
    }
    type Readings = (Vec<(String, f64)>, Vec<(String, f64)>);
    let mut chips: BTreeMap<&str, Readings> = BTreeMap::new();
    let mut sorted: Vec<&Series> = series.iter().collect();
    sorted.sort_by_cached_key(|s| sensor_key(s.label("sensor")));
    for s in sorted {
        let (chip, sensor) = (s.label("chip"), s.label("sensor"));
        // Prometheus sends a sensor that failed to read as `NaN`.
        let Some(v) = s.value.filter(|v| v.is_finite()) else {
            continue;
        };
        let name = label
            .get(&(chip, sensor))
            .filter(|l| !l.is_empty())
            .map_or(sensor.to_string(), |l| l.to_string());
        // A chip with only a name (a mouse's battery) has nothing to show.
        match s.label("__name__") {
            "node_hwmon_temp_celsius" => chips.entry(chip).or_default().0.push((name, v)),
            "node_hwmon_fan_rpm" => chips.entry(chip).or_default().1.push((name, v)),
            _ => {}
        }
    }
    let mut out: Vec<Device> = chips
        .into_iter()
        .map(|(chip, (temps, fans))| {
            let driver = chip_name.get(chip).copied().unwrap_or(chip);
            Device {
                device: kind(driver),
                chip: driver.to_string(),
                hottest: temps.iter().map(|t| t.1).reduce(f64::max),
                temps,
                fans,
            }
        })
        .collect();
    let rank = |k: &str| {
        KIND_ORDER
            .iter()
            .position(|x| *x == k)
            .unwrap_or(KIND_ORDER.len())
    };
    // Stable, so two of a kind keep their chip order: ram 1 to ram 4 by their bus address.
    out.sort_by(|a, b| {
        rank(&a.device)
            .cmp(&rank(&b.device))
            .then(a.device.cmp(&b.device))
    });
    let mut count: BTreeMap<String, usize> = BTreeMap::new();
    for d in &out {
        *count.entry(d.device.clone()).or_default() += 1;
    }
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    for d in &mut out {
        if count[&d.device] > 1 {
            let n = seen.entry(d.device.clone()).or_default();
            *n += 1;
            d.device = format!("{} {n}", d.device);
        }
    }
    out
}

/// The busiest first, then the largest, then by name.
fn busiest<T>(v: &mut [T], key: impl Fn(&T) -> (Option<f64>, Option<f64>, &str)) {
    v.sort_by(|a, b| {
        let (ca, ma, na) = key(a);
        let (cb, mb, nb) = key(b);
        cb.unwrap_or(-1.0)
            .total_cmp(&ca.unwrap_or(-1.0))
            .then(mb.unwrap_or(-1.0).total_cmp(&ma.unwrap_or(-1.0)))
            .then(na.cmp(nb))
    });
}

/// The page's part from what was read: pure, for the tests.
pub fn build(
    sensors: &[Series],
    inventory: &[Series],
    pods: &[Series],
    pod_cpu: &[Series],
    pod_mem: &[Series],
) -> HostNow {
    let pod_key = |s: &Series| format!("{}/{}", s.label("namespace"), s.label("pod"));
    let (cpu, mem) = (by(pod_cpu, pod_key), by(pod_mem, pod_key));
    let mut pod_rows: Vec<Pod> = pods
        .iter()
        .map(|s| {
            let k = pod_key(s);
            Pod {
                namespace: s.label("namespace").into(),
                pod: s.label("pod").into(),
                cpu: cpu.get(&k).copied(),
                mem: mem.get(&k).copied(),
            }
        })
        .collect();
    busiest(&mut pod_rows, |p| (p.cpu, p.mem, &p.pod));

    let of = |name: &str| -> Vec<&Series> {
        inventory
            .iter()
            .filter(|s| s.label("__name__") == name)
            .collect()
    };
    let one = |name: &str, key: &str| -> BTreeMap<String, f64> {
        by(of(name), |s| s.label(key).to_string())
    };
    let (pcpu, pmem, pn) = (
        one("node_process_cpu_cores", "comm"),
        one("node_process_resident_bytes", "comm"),
        one("node_process_count", "comm"),
    );
    let mut names: Vec<&String> = pcpu.keys().chain(pmem.keys()).chain(pn.keys()).collect();
    names.sort();
    names.dedup();
    let mut processes: Vec<Proc> = names
        .into_iter()
        .map(|n| Proc {
            name: n.clone(),
            cpu: pcpu.get(n).copied(),
            mem: pmem.get(n).copied(),
            count: pn.get(n).copied(),
            ..Default::default()
        })
        .collect();
    busiest(&mut processes, |p| (p.cpu, p.mem, &p.name));

    let mut images: BTreeMap<String, String> = BTreeMap::new();
    for s in of("node_docker_container_cpu_cores")
        .into_iter()
        .chain(of("node_docker_container_memory_bytes"))
    {
        images.insert(s.label("name").into(), s.label("image").into());
    }
    let (ccpu, cmem) = (
        one("node_docker_container_cpu_cores", "name"),
        one("node_docker_container_memory_bytes", "name"),
    );
    let mut containers: Vec<Proc> = images
        .into_iter()
        .map(|(name, image)| Proc {
            cpu: ccpu.get(&name).copied(),
            mem: cmem.get(&name).copied(),
            name,
            image,
            count: None,
        })
        .collect();
    busiest(&mut containers, |p| (p.cpu, p.mem, &p.name));

    let mut services: Vec<String> = of("node_service_running")
        .iter()
        .filter(|s| s.value == Some(1.0))
        .map(|s| s.label("unit").trim_end_matches(".service").to_string())
        .collect();
    services.sort();
    services.dedup();
    let mut who: BTreeMap<String, (String, String)> = BTreeMap::new();
    for s in of("node_agent_scope_cpu_cores")
        .into_iter()
        .chain(of("node_agent_scope_resident_bytes"))
    {
        who.insert(
            s.label("scope").into(),
            (s.label("project").into(), s.label("item").into()),
        );
    }
    let (scpu, smem) = (
        one("node_agent_scope_cpu_cores", "scope"),
        one("node_agent_scope_resident_bytes", "scope"),
    );
    let mut tests: BTreeMap<String, Vec<(String, f64)>> = BTreeMap::new();
    for s in of("node_agent_scope_test_cpu_cores") {
        if let Some(v) = s.value.filter(|v| v.is_finite()) {
            tests
                .entry(s.label("scope").into())
                .or_default()
                .push((s.label("comm").into(), v));
        }
    }
    let mut sessions: Vec<Session> = who
        .into_iter()
        .map(|(scope, (project, item))| {
            let mut t = tests.remove(&scope).unwrap_or_default();
            t.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
            Session {
                cpu: scpu.get(&scope).copied(),
                mem: smem.get(&scope).copied(),
                tests: t
                    .iter()
                    .map(|(c, v)| format!("{c} {v:.2}"))
                    .collect::<Vec<_>>()
                    .join(", "),
                project,
                item,
            }
        })
        .collect();
    busiest(&mut sessions, |x| (x.cpu, x.mem, &x.project));
    let total = of("node_processes_total");
    HostNow {
        devices: devices(sensors),
        pods: pod_rows,
        processes_total: total.first().and_then(|s| s.value),
        inventory: !inventory.is_empty(),
        services,
        containers,
        processes,
        sessions,
        unread: BTreeMap::new(),
    }
}

/// Bytes as a reader says them: `2.5G`, `340M`, `12K`.
pub fn bytes(b: f64) -> String {
    const UNITS: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut v = b.max(0.0);
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if v < 10.0 && u > 0 {
        format!("{v:.1}{}", UNITS[u])
    } else {
        format!("{v:.0}{}", UNITS[u])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn s(v: serde_json::Value) -> Series {
        let mut labels = BTreeMap::new();
        let mut value = None;
        for (k, x) in v.as_object().unwrap() {
            if k == "v" {
                value = x.as_str().and_then(|t| t.parse().ok());
            } else {
                labels.insert(k.clone(), x.as_str().unwrap().to_string());
            }
        }
        Series {
            labels,
            value,
            points: vec![],
        }
    }

    /// The workstation's hwmon as Prometheus had it on 2026-11-14: k10temp labelled, four
    /// spd5118 DIMMs with no label, two amdgpus, a GPU fan.
    fn workstation_hwmon() -> Vec<Series> {
        let t = |chip: &str, sensor: &str, v: &str| {
            s(
                json!({"__name__": "node_hwmon_temp_celsius", "chip": chip, "sensor": sensor, "v": v}),
            )
        };
        let name = |chip: &str, n: &str| {
            s(json!({"__name__": "node_hwmon_chip_names", "chip": chip, "chip_name": n, "v": "1"}))
        };
        let label = |chip: &str, sensor: &str, l: &str| {
            s(
                json!({"__name__": "node_hwmon_sensor_label", "chip": chip, "sensor": sensor, "label": l, "v": "1"}),
            )
        };
        let k10 = "pci0000:00_0000:00:18_3";
        let gpu = "0000:02:00_0_0000:03:00_0";
        vec![
            t(k10, "temp4", "82.1"),
            t(k10, "temp1", "96.4"),
            t(k10, "temp3", "97.1"),
            label(k10, "temp1", "Tctl"),
            label(k10, "temp3", "Tccd1"),
            label(k10, "temp4", "Tccd2"),
            name(k10, "k10temp"),
            t("i2c_24_24_0051", "temp1", "56"),
            t("i2c_24_24_0050", "temp1", "54"),
            name("i2c_24_24_0050", "spd5118"),
            name("i2c_24_24_0051", "spd5118"),
            t(gpu, "temp1", "52"),
            label(gpu, "temp1", "edge"),
            name(gpu, "amdgpu"),
            s(json!({"__name__": "node_hwmon_fan_rpm", "chip": gpu, "sensor": "fan1", "v": "616"})),
            t("nvme_nvme0", "temp1", "51.85"),
            name("nvme_nvme0", "nvme"),
            t("thermal_thermal_zone0", "temp1", "40"),
            name("thermal_thermal_zone0", "iwlwifi_1"),
            name("power_supply_hidpp_battery_0", "hidpp_battery_0"),
            t("platform_coretemp_0", "temp1", "NaN"),
        ]
    }

    #[test]
    fn devices_name_their_kind_number_their_twins_and_keep_sensor_order() {
        let d = devices(&workstation_hwmon());
        let names: Vec<&str> = d.iter().map(|x| x.device.as_str()).collect();
        assert_eq!(
            names,
            ["cpu", "ram 1", "ram 2", "gpu", "nvme", "wifi"],
            "no empty chip"
        );
        assert_eq!(d[0].readings(), "Tctl 96C  Tccd1 97C  Tccd2 82C");
        assert_eq!(d[0].hottest, Some(97.1));
        assert!(d[0].in_state("hot"));
        assert_eq!(d[1].readings(), "temp1 54C", "the DIMM at 0x50 is ram 1");
        assert_eq!(d[3].readings(), "edge 52C  fan1 616rpm");
        assert!(!d[3].in_state("hot"));
    }

    #[test]
    fn pods_join_their_cpu_and_memory_busiest_first() {
        let pod = |ns: &str, p: &str| s(json!({"namespace": ns, "pod": p, "v": "1"}));
        let val = |ns: &str, p: &str, v: &str| s(json!({"namespace": ns, "pod": p, "v": v}));
        let h = build(
            &[],
            &[],
            &[
                pod("frigate", "frigate-0"),
                pod("ai", "litellm-1"),
                pod("ai", "idle"),
            ],
            &[
                val("frigate", "frigate-0", "0.7"),
                val("ai", "litellm-1", "0.05"),
                val("ai", "idle", "NaN"),
            ],
            &[
                val("frigate", "frigate-0", "2684354560"),
                val("ai", "litellm-1", "1e8"),
            ],
        );
        let names: Vec<&str> = h.pods.iter().map(|p| p.pod.as_str()).collect();
        assert_eq!(names, ["frigate-0", "litellm-1", "idle"]);
        assert_eq!(bytes(h.pods[0].mem.unwrap()), "2.5G");
        assert_eq!(
            h.pods[2].cpu, None,
            "a pod cadvisor has no finite sample for reads as unknown, not busiest"
        );
        assert!(
            !h.inventory,
            "no node_inventory.prom: services and processes are unknown"
        );
    }

    #[test]
    fn inventory_reads_processes_containers_and_services() {
        let m = |n: &str, l: serde_json::Value, v: &str| {
            let mut o = l.as_object().unwrap().clone();
            o.insert("__name__".into(), json!(n));
            o.insert("v".into(), json!(v));
            s(serde_json::Value::Object(o))
        };
        let inv = vec![
            m("node_process_cpu_cores", json!({"comm": "Unity"}), "3.5"),
            m(
                "node_process_resident_bytes",
                json!({"comm": "Unity"}),
                "8e9",
            ),
            m("node_process_count", json!({"comm": "Unity"}), "2"),
            m(
                "node_process_resident_bytes",
                json!({"comm": "postgres"}),
                "4e8",
            ),
            m("node_processes_total", json!({}), "612"),
            m(
                "node_service_running",
                json!({"unit": "nfs-server.service"}),
                "1",
            ),
            m(
                "node_service_running",
                json!({"unit": "tailscaled.service"}),
                "1",
            ),
            m(
                "node_docker_container_cpu_cores",
                json!({"name": "mailpit", "image": "axllent/mailpit"}),
                "0.01",
            ),
            m(
                "node_docker_container_memory_bytes",
                json!({"name": "mailpit", "image": "axllent/mailpit"}),
                "3e7",
            ),
        ];
        let h = build(&[], &inv, &[], &[], &[]);
        assert!(h.inventory);
        assert_eq!(h.services, ["nfs-server", "tailscaled"]);
        assert_eq!(h.processes_total, Some(612.0));
        assert_eq!(h.processes[0].name, "Unity");
        assert_eq!(h.processes[0].count, Some(2.0));
        assert_eq!(h.processes[1].cpu, None, "in the top by memory only");
        assert_eq!(h.containers[0].image, "axllent/mailpit");
        assert_eq!(bytes(h.containers[0].mem.unwrap()), "29M");
        let only_docker = build(&[], &inv[7..], &[], &[], &[]);
        assert!(
            only_docker.inventory,
            "any collector series means it is collected"
        );
    }

    #[test]
    fn inventory_reads_each_agent_session_with_its_test_runs() {
        let m = |n: &str, l: serde_json::Value, v: &str| {
            let mut o = l.as_object().unwrap().clone();
            o.insert("__name__".into(), json!(n));
            o.insert("v".into(), json!(v));
            s(serde_json::Value::Object(o))
        };
        let a = json!({"scope": "agent-dotfiles-ar\\x2d1-10.scope", "project": "dotfiles", "item": "ar-1"});
        let b = json!({"scope": "agent-notes--11.scope", "project": "notes", "item": ""});
        let with = |l: &serde_json::Value, comm: &str| {
            let mut o = l.as_object().unwrap().clone();
            o.insert("comm".into(), json!(comm));
            serde_json::Value::Object(o)
        };
        let inv = vec![
            m("node_agent_scope_cpu_cores", a.clone(), "2.5"),
            m("node_agent_scope_resident_bytes", a.clone(), "2e9"),
            m("node_agent_scope_test_cpu_cores", with(&a, "Unity"), "0.4"),
            m("node_agent_scope_test_cpu_cores", with(&a, "bats"), "1.2"),
            m("node_agent_scope_resident_bytes", b.clone(), "5e8"),
        ];
        let h = build(&[], &inv, &[], &[], &[]);
        assert!(h.inventory);
        assert_eq!(h.sessions.len(), 2);
        assert_eq!(h.sessions[0].project, "dotfiles");
        assert_eq!(h.sessions[0].item, "ar-1");
        assert_eq!(h.sessions[0].cpu, Some(2.5));
        assert_eq!(h.sessions[0].tests, "bats 1.20, Unity 0.40");
        assert_eq!(
            (h.sessions[1].item.as_str(), h.sessions[1].cpu),
            ("", None),
            "a hand start on its first reading: memory, no cpu yet"
        );
        assert_eq!(h.sessions[1].mem, Some(5e8));
    }

    #[test]
    fn queries_match_every_name_and_refuse_a_bad_one() {
        let q = queries(&["workstation".into(), "cachyos-x8664-main".into()]).unwrap();
        assert!(q[0].1.contains(r#"host=~"workstation|cachyos-x8664-main""#));
        assert!(q[2].1.contains(r#"node=~"workstation|cachyos-x8664-main""#));
        assert!(queries(&[r#"a"}"#.into()]).is_err());
    }

    #[test]
    fn the_web_page_mirrors_hot_c() {
        let js =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../agent-web/static/infra.js");
        let js = std::fs::read_to_string(js).unwrap();
        assert!(
            js.contains(&format!("const HOT_C = {HOT_C:.0};")),
            "agent-web/static/infra.js no longer mirrors HOT_C"
        );
    }

    #[test]
    fn bytes_read_short() {
        assert_eq!(bytes(512.0), "512B");
        assert_eq!(bytes(1536.0), "1.5K");
        assert_eq!(bytes(1.7 * 1024.0 * 1024.0 * 1024.0), "1.7G");
        assert_eq!(bytes(300.0 * 1024.0 * 1024.0), "300M");
    }
}
