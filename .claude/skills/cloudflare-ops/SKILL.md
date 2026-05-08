---
name: cloudflare-ops
description: Cloudflare DNS, tunnel, and zone operations via the REST API v4. Use when the user asks to manage DNS records, check tunnel health, purge cache, or inspect zone settings for kennethblack.me, blacknbrownstudios.com, binks.chat, or kblack.dev.
---

# cloudflare-ops

Manage Cloudflare resources via `curl` against the [REST API v4](https://developers.cloudflare.com/api/) with `jq` for parsing. No CLI tools to install.

## Prerequisites

| Env var | Required | Purpose |
|---------|----------|---------|
| `CLOUDFLARE_API_TOKEN` | Yes | Bearer token — needs DNS:Edit, Zone:Read, Account:Cloudflare Tunnel:Read |
| `CLOUDFLARE_ACCOUNT_ID` | For tunnel/account ops | Account ID that owns tunnels |

```bash
# Verify token
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .
```

### Known zones

| Domain | Purpose | Tunnel-routed |
|--------|---------|---------------|
| `kennethblack.me` | Portfolio | Yes |
| `blacknbrownstudios.com` | BNB Studios | Yes |
| `binks.chat` | Binks AI chat | Yes |
| `kblack.dev` | Dev site | Yes |

### Infrastructure context

- **Tunnel:** `public-sites-homelab` — runs as `cloudflared-public-sites` deployment in `apps` namespace on home-k3s
- **Terraform source of truth:** `~/dev/bnb/platform/infra/public-sites-tunnel/main.tf`
- **Cert-manager:** `letsencrypt-dns` ClusterIssuer with Cloudflare DNS01 solver — depends on `_acme-challenge` TXT records
- **Private services:** `*.kblab.me` resolved via local AdGuard DNS — NOT Cloudflare-managed

## Zones

```bash
# List all zones
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?per_page=50" | jq '.result[] | {id, name, status}'

# Get zone ID for a domain
ZONE_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=kennethblack.me" | jq -r '.result[0].id')

# Zone details
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID" \
  | jq '.result | {name, status, plan: .plan.name, name_servers}'
```

## DNS records

### List and filter

```bash
# All records for a zone
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
  | jq '.result[] | {id, type, name, content, proxied, ttl}'

# Filter by type
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME" \
  | jq '.result[] | {id, name, content, proxied}'

# Filter by name
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=www.kennethblack.me" \
  | jq '.result[]'

# Find tunnel-routed records
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?content=cfargotunnel.com" \
  | jq '.result[] | {id, name, content}'
```

### Create

```bash
# A record
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -d '{
    "type": "A",
    "name": "subdomain",
    "content": "192.168.1.100",
    "ttl": 3600,
    "proxied": false,
    "comment": "reason for this record"
  }' | jq .

# CNAME record (tunnel-routed — must be proxied, ttl auto)
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -d '{
    "type": "CNAME",
    "name": "app",
    "content": "<tunnel-id>.cfargotunnel.com",
    "ttl": 1,
    "proxied": true,
    "comment": "Routed via public-sites-homelab tunnel"
  }' | jq .

# TXT record
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -d '{
    "type": "TXT",
    "name": "@",
    "content": "v=spf1 -all",
    "ttl": 3600
  }' | jq .

# MX record
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -d '{
    "type": "MX",
    "name": "@",
    "content": "mail.example.com",
    "priority": 10,
    "ttl": 3600
  }' | jq .
```

### Update

```bash
# Full update (PUT — replaces all fields)
RECORD_ID="<record-id>"
curl -s -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -d '{
    "type": "A",
    "name": "subdomain",
    "content": "192.168.1.200",
    "ttl": 3600,
    "proxied": false,
    "comment": "updated IP"
  }' | jq .

# Partial update (PATCH — only send fields to change)
curl -s -X PATCH \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -d '{"content": "192.168.1.200", "comment": "updated IP"}' | jq .
```

### Delete

```bash
curl -s -X DELETE \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" | jq .
```

## Tunnels

```bash
# List tunnels
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  | jq '.result[] | {id, name, status, created_at}'

# Tunnel details and connection status
TUNNEL_ID="<tunnel-id>"
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" \
  | jq '.result | {id, name, status, connections: [.connections[] | {connector_id, is_pending_reconnect, origin_ip, colo_name}]}'

# Tunnel ingress config
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  | jq '.result.config.ingress'

# Quick health check
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" \
  | jq '.result.status'
```

### K3s-side diagnostics

```bash
# Pod status
kubectl get pods -n apps -l app=cloudflared-public-sites

# Recent logs
kubectl logs -n apps -l app=cloudflared-public-sites --tail=50

# Restart if needed
kubectl rollout restart -n apps deployment/cloudflared-public-sites
```

## Cache

```bash
# Purge everything (use sparingly)
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/purge_cache" \
  -d '{"purge_everything": true}' | jq .

# Purge specific URLs
curl -s -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/purge_cache" \
  -d '{"files": ["https://kennethblack.me/", "https://kennethblack.me/index.html"]}' | jq .
```

## Zone settings

```bash
# List all settings
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings" \
  | jq '.result[] | {id, value}'

# Check SSL/TLS mode
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" | jq '.result.value'

# Update a setting
curl -s -X PATCH \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/always_use_https" \
  -d '{"value": "on"}' | jq .
```

## Safety rules

### DNS record protection

- **NEVER delete or modify CNAME records pointing to `*.cfargotunnel.com`** without explicit user confirmation — these are tunnel ingress records. Removing them breaks public site routing.
- **NEVER delete or modify `_acme-challenge` TXT records** — cert-manager uses these for DNS01 validation. Deleting them breaks TLS certificate renewal.
- **Tunnel CNAMEs must be `proxied: true` and `ttl: 1` (auto).** An unproxied tunnel CNAME exposes the tunnel ID and won't route traffic.
- **Before creating a CNAME at the zone apex (`@`)**, verify no conflicting A/AAAA records exist.
- **Always include a `comment` field** when creating or updating records.

### Terraform-managed resources

- Root and www DNS records for all four zones are **managed by Terraform** in `~/dev/bnb/platform/infra/public-sites-tunnel/main.tf`. Modifying these via API causes state drift — prefer `terraform apply`.
- Tunnel configuration is also Terraform-managed — **do not modify tunnel config via the API**.
- For **new subdomains** not in Terraform, the API is fine — note it in the comment for future import traceability.

### General

- **Always GET before PUT/DELETE.** Show the user what exists before mutating.
- **Confirm destructive operations** (DELETE, purge_everything, disabling proxy) with the user.
- **`*.kblab.me` is local AdGuard DNS**, not Cloudflare-managed. Do not attempt API calls for that domain.
- Check `jq '.success'` in responses. If `false`, show `.errors` and `.messages` before retrying.

## Tips

- Zone-ID lookup one-liner:
  ```bash
  curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    | jq -r '.result[] | "\(.name) \(.id)"'
  ```
- Paginate large record sets with `?page=2&per_page=100`. Check total: `jq '.result_info | {page, total_pages}'`
- **522 debugging flow:** check tunnel status via API → check `cloudflared-public-sites` pod logs → verify upstream service (`traefik.kube-system.svc.cluster.local:80`) reachable from within the cluster
- **New tunnel-routed subdomain checklist:**
  1. Add ingress rule in Terraform (`main.tf`)
  2. `terraform apply`
  3. Create CNAME DNS record (proxied, ttl auto) pointing to `<tunnel-id>.cfargotunnel.com`
  4. Create or update Kubernetes Ingress for Traefik to route the Host header
  5. Optionally add cert-manager TLS annotation (`cert-manager.io/cluster-issuer: letsencrypt-dns`)
