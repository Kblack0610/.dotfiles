---
name: k8s-ops
description: Kubernetes cluster operations via kubectl, helm, and related tools. Use when the user asks about kubectl commands, k8s resources, pods, deployments, namespaces, services, ingresses, logs, scaling, port-forwarding, or anything related to the home-k3s, do-nyc3-placemyparents-k8s-prod, or k3d-local clusters.
---

# k8s-ops

Manage Kubernetes clusters via `kubectl` with `kubectx`/`kubens` for context switching and `k9s` for interactive debugging. Shell aliases and wrappers are defined in `~/.k8s-rc` (sourced by `~/.commonrc`).

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `kubectl` | Yes | Cluster operations |
| `kubectx` / `kubens` | Yes | Context and namespace switching |
| `helm` | For chart ops | Helm chart install/upgrade/rollback |
| `k9s` | Optional | Interactive cluster UI |
| `stern` | Optional | Multi-pod log tailing |
| `jq` | Recommended | JSON parsing for `-o json` output |

```bash
# Verify cluster connectivity
kubectl --context home-k3s cluster-info
kubectl --context do-nyc3-placemyparents-k8s-prod cluster-info
kubectl --context k3d-local cluster-info
```

## Cluster topology

| Context name | Type | Purpose | API endpoint |
|---|---|---|---|
| `home-k3s` | k3s (bare-metal) | Primary home cluster — runs all self-hosted services | `192.168.1.20:6443` |
| `do-nyc3-placemyparents-k8s-prod` | DOKS (DigitalOcean) | Production for PlaceMyParents app | DO-managed |
| `k3d-local` | k3d (Docker) | Local dev cluster, traefik disabled, ports 8080->80 / 8443->443 | localhost |

**Default behavior:** never assume a cluster. Always confirm or specify `--context` before operating. The CLAUDE.md rule "identify target environment before answering" applies here.

### home-k3s namespace map

| Category | Namespaces |
|---|---|
| Smart home / Media | `home-assistant`, `jellyfin`, `prowlarr`, `radarr`, `sonarr`, `qbittorrent` |
| Productivity | `actual-budget`, `orcaslicer`, `immich` |
| Networking / DNS | `adguard-home`, `headscale` |
| Security | `crowdsec` |
| Infrastructure | `apps` (cloudflared), `registry`, `forgejo`, `cert-manager`, `flux-system` |
| Monitoring / AI | `monitoring` (grafana, prometheus), `ai-gateway` (litellm) |
| Dev / Projects | `black-dev`, `bnb-studios`, `portfolio`, `nas`, `history-time`, `gatus`, `openclaw`, `comfyui` |
| GPU | `nvidia-device-plugin` |
| System | `kube-system`, `kube-public`, `kube-node-lease` |

## Shell aliases reference

Defined in `~/.k8s-rc` — use these for brevity in interactive shells:

```
k=kubectl  kx=kubectx  kn=kubens  kgp=get pods  kgd=get deployments
kgs=get services  kga=get all  kaf=apply -f  kdf=delete -f
kdp=describe pod  kl=logs -f  kex=exec -it
k9home / k9do / k9local = k9s with --context
```

## Common operations

### Status and health

```bash
# Cluster-wide overview
kubectl --context home-k3s get nodes -o wide
kubectl --context home-k3s get pods -A --field-selector=status.phase!=Running

# Namespace overview
kubectl --context home-k3s get all -n <namespace>

# Quick status via infra-dash (checks 7 core services)
infra-collect && infra-dash
infra-json | jq '.locations.k3s.services[] | {name, status}'

# Resource usage (requires metrics-server)
kubectl --context home-k3s top nodes
kubectl --context home-k3s top pods -n <namespace>
```

### Logs

```bash
# Single pod
kubectl --context home-k3s logs -n <ns> deploy/<name> --tail=100

# Follow logs
kubectl --context home-k3s logs -n <ns> deploy/<name> -f --tail=50

# Previous container (after crash)
kubectl --context home-k3s logs -n <ns> <pod-name> --previous

# Multi-pod with stern
stern --context home-k3s -n <ns> <label-or-pod-query> --tail=100
```

### Restart

```bash
# Rolling restart (zero-downtime for deployments with >1 replica)
kubectl --context home-k3s rollout restart -n <ns> deployment/<name>

# Watch rollout progress
kubectl --context home-k3s rollout status -n <ns> deployment/<name>

# Rollback to previous revision
kubectl --context home-k3s rollout undo -n <ns> deployment/<name>
```

### Exec into pods

```bash
# Generic exec
kubectl --context home-k3s exec -it -n <ns> deploy/<name> -- /bin/sh

# Debug with netshoot (ephemeral container)
kubectl --context home-k3s debug -it -n <ns> <pod-name> \
  --image=nicolaka/netshoot --target=<container-name> -- /bin/bash
```

### Pod exec wrappers (home-k3s)

These shell functions are in `~/.k8s-rc` — they auto-target home-k3s:

```bash
headscale users list           # -> exec into headscale pod
cscli decisions list           # -> exec into crowdsec-lapi pod
openclaw --help                # -> exec into openclaw pod
immich-psql                    # -> psql into immich-postgres pod
```

### Scale

```bash
kubectl --context home-k3s scale -n <ns> deployment/<name> --replicas=<n>

# Scale to zero (maintenance)
kubectl --context home-k3s scale -n <ns> deployment/<name> --replicas=0

# Scale back up
kubectl --context home-k3s scale -n <ns> deployment/<name> --replicas=1
```

### Apply and delete

```bash
# Apply manifests
kubectl --context home-k3s apply -f <file-or-dir>

# Dry-run first
kubectl --context home-k3s apply -f <file> --dry-run=server

# Delete (always get first — see safety rules)
kubectl --context home-k3s get -n <ns> <resource-type> <name> -o yaml
kubectl --context home-k3s delete -n <ns> <resource-type> <name>
```

### Describe and inspect

```bash
kubectl --context home-k3s describe -n <ns> pod/<name>
kubectl --context home-k3s get -n <ns> <resource> <name> -o yaml

# Decode secrets
kubectl --context home-k3s get secret -n <ns> <name> -o json \
  | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'

# List ingresses
kubectl --context home-k3s get ingress -A
```

### Port-forward

```bash
kubectl --context home-k3s port-forward -n <ns> svc/<name> <local>:<remote>

# Examples
kubectl --context home-k3s port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl --context home-k3s port-forward -n home-assistant svc/home-assistant 8123:8123
```

### Helm

```bash
# List releases
helm --kube-context home-k3s list -A

# Show values for a release
helm --kube-context home-k3s get values <release> -n <ns>

# Upgrade with values
helm --kube-context home-k3s upgrade <release> <chart> -n <ns> -f values.yaml

# Rollback
helm --kube-context home-k3s rollback <release> <revision> -n <ns>

# History
helm --kube-context home-k3s history <release> -n <ns>
```

## Safety rules

### Context discipline

- **Always specify `--context`** (or `--kube-context` for helm) on destructive operations: `delete`, `scale`, `apply`, `rollout restart`, `drain`, `cordon`. A wrong-context delete on production is unrecoverable.
- **Never run `kubectl delete namespace`** without explicit user confirmation — this cascades to all resources in the namespace.
- **Never modify resources in `kube-system`** without confirmation — breaking CoreDNS, metrics-server, or traefik takes down the cluster.

### Flux-managed resources

- home-k3s uses **Flux CD** (`flux-system` namespace). Before modifying a resource, check for Flux labels:
  ```bash
  kubectl --context home-k3s get deploy/<name> -n <ns> -o jsonpath='{.metadata.labels}' | jq .
  ```
  Look for `app.kubernetes.io/managed-by: Helm` with `helm.toolkit.fluxcd.io` annotations. Manual changes to Flux-managed resources **will be reverted** on the next reconciliation.
- To make permanent changes to Flux-managed resources, edit the source manifests/HelmRelease and let Flux reconcile.
- Force reconciliation: `kubectl --context home-k3s annotate --overwrite -n <ns> helmrelease/<name> reconcile.fluxcd.io/requestedAt="$(date +%s)"`

### General

- **Always GET before DELETE.** Show the user what exists before mutating.
- **Confirm destructive operations** (delete, scale-to-zero, drain, cordon) with the user.
- **Dry-run first** for apply operations when the manifest is new or unfamiliar: `--dry-run=server`.
- **Do not port-forward to production (DO cluster)** without explicit user intent.

## Debugging flows

### CrashLoopBackOff

```bash
kubectl --context home-k3s describe pod -n <ns> <pod>    # check Events section
kubectl --context home-k3s logs -n <ns> <pod> --previous  # last crash output
# Common causes: wrong image tag, missing configmap/secret, OOM, app error
```

### ImagePullBackOff

```bash
kubectl --context home-k3s describe pod -n <ns> <pod>     # look for "Failed to pull image"
# Common causes: typo in image name, private registry auth, registry down
# For home registry: kubectl --context home-k3s get deploy -n registry
```

### Pending pods

```bash
kubectl --context home-k3s describe pod -n <ns> <pod>     # check Events for scheduling failures
kubectl --context home-k3s get nodes -o wide               # node capacity
kubectl --context home-k3s describe node <node>            # resource pressure, taints
# Common causes: insufficient CPU/memory, PVC not bound, node taint, GPU not available
```

### OOMKilled

```bash
kubectl --context home-k3s get pod -n <ns> <pod> -o jsonpath='{.status.containerStatuses[*].lastState}'
kubectl --context home-k3s top pod -n <ns> <pod>
# Fix: increase memory limits in the deployment spec or HelmRelease values
```

### Service not reachable

```bash
kubectl --context home-k3s get endpoints -n <ns> <svc>    # endpoints empty = selector mismatch
kubectl --context home-k3s get ingress -n <ns>             # check ingress rules
kubectl --context home-k3s describe ingress -n <ns> <name> # TLS and routing
# Test from inside cluster:
kubectl --context home-k3s run tmp-curl --rm -it --image=curlimages/curl -- \
  curl -sv http://<svc>.<ns>.svc.cluster.local:<port>
```

## Integration with other tools

- **infra-dash**: `infra-collect && infra-dash` for a quick terminal dashboard of the 7 monitored home-k3s services. Use `infra-json` for structured JSON output.
- **k9s**: `k9home` / `k9do` / `k9local` shortcuts. Plugins: `Shift-L` (stern), `Shift-X` (decode secret), `Shift-R` (restart), `Shift-D` (debug netshoot). Hotkeys: `Shift-1..0` for resource navigation.
- **stern**: `stern --context home-k3s -n <ns> .` to tail all pods in a namespace.
- **Cluster setup wizard**: `k8s-setup` alias runs `~/.local/src/installation_scripts/linux/k8s-clusters-setup.sh`.

## Tips

- All namespaces with non-running pods: `kubectl --context home-k3s get pods -A --field-selector=status.phase!=Running`
- Watch a resource: `kubectl --context home-k3s get pods -n <ns> -w`
- Events sorted by time: `kubectl --context home-k3s get events -A --sort-by=.lastTimestamp | tail -20`
- Resource consumption across all namespaces: `kubectl --context home-k3s top pods -A --sort-by=memory | head -20`
- List all images in use: `kubectl --context home-k3s get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u`
- Flux status overview: `kubectl --context home-k3s get helmreleases -A`
- Check cert-manager certs: `kubectl --context home-k3s get certificates -A`
