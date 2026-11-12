//! A ClusterIP-only service (Loki, VictoriaMetrics), read through the API server's service proxy
//! (`kubectl get --raw`) with the kube credentials already on this machine: no ingress and no
//! token. Which cluster, and which service, are board settings (`CC_KUBE_CONTEXT` and the
//! service's own `ns/name:port` setting), so no cluster is assumed.

use crate::jobs::log::run;
use crate::prom::required;

/// A guard on the API server call.
const REQUEST_TIMEOUT: &str = "--request-timeout=10s";

/// A namespace, Job or service name: a DNS-1123 label, so it cannot break out of a query.
pub fn label(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `namespace/name:port` as its three parts.
pub fn service(s: &str) -> Option<(&str, &str, u16)> {
    let (ns, rest) = s.split_once('/')?;
    let (name, port) = rest.split_once(':')?;
    let port = port.parse().ok()?;
    (label(ns) && label(name)).then_some((ns, name, port))
}

/// `s` as one URL query value.
pub fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The API server path to `path` (`/loki/api/v1/...`) on service `svc`.
pub fn path(svc: (&str, &str, u16), path: &str) -> String {
    format!(
        "/api/v1/namespaces/{}/services/{}:{}/proxy{path}",
        svc.0, svc.1, svc.2
    )
}

/// The body of `GET <path>` on the service the board setting `setting` names.
pub fn get(setting: &str, p: &str) -> Result<String, String> {
    let ctx = required("CC_KUBE_CONTEXT")?;
    let svc = required(setting)?;
    let svc = service(&svc).ok_or_else(|| format!("{setting} is not namespace/name:port"))?;
    run(
        "kubectl",
        &["--context", &ctx, REQUEST_TIMEOUT, "get", "--raw", &path(svc, p)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_that_could_change_the_query_is_refused() {
        for bad in ["", "a\"}", "A", "-a", "a-", "a b", "a/b", &"a".repeat(64)] {
            assert!(!label(bad), "{bad:?}");
        }
        assert!(label("actual-budget-backup-29895060"));
        assert_eq!(
            service("monitoring/loki:3100"),
            Some(("monitoring", "loki", 3100))
        );
        assert_eq!(service("monitoring/loki"), None);
        assert_eq!(service("Mon/loki:3100"), None);
        assert_eq!(
            path(("monitoring", "victoria-metrics", 8428), "/api/v1/query?query=up"),
            "/api/v1/namespaces/monitoring/services/victoria-metrics:8428/proxy/api/v1/query?query=up"
        );
    }
}
