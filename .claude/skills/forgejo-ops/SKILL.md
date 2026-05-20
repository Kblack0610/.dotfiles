---
name: forgejo-ops
description: Forgejo Git forge operations — user/repo management, Actions runners, container/package registry, mirroring, and backups on the home-k3s cluster at git.kblab.me. Use when the user asks about Forgejo admin, CI/CD workflows, container image pushes, repo mirroring, or runner management.
---

# forgejo-ops

Manage the self-hosted Forgejo instance at `git.kblab.me` running in the `forgejo` namespace on `home-k3s`. Forgejo v14.0.4 with Actions, Packages, Container Registry, and Mirroring enabled.

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `kubectl` | Yes | Exec into Forgejo pod for admin CLI |
| `docker` | For registry ops | Push/pull container images |
| `curl` / `jq` | For API ops | REST API calls |
| `sops` | For secret changes | Encrypt runner tokens |

## Forgejo admin CLI

All admin commands run via `kubectl exec` as the `git` user:

```bash
# Base command pattern
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- su-exec git forgejo <command>
```

### User management

```bash
# List users
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- su-exec git forgejo admin user list

# Create admin user
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- \
  su-exec git forgejo admin user create \
  --username <name> --email <email> --password <pass> --admin --must-change-password

# Change password
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- \
  su-exec git forgejo admin user change-password --username <name> --password <new>

# Delete user (destructive — confirm first)
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- \
  su-exec git forgejo admin user delete --username <name>
```

### Runner management

```bash
# Generate instance-level runner registration token
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- \
  su-exec git forgejo forgejo-cli actions generate-runner-token

# Check runner status
kubectl --context home-k3s logs -n forgejo deploy/forgejo-runner -c runner --tail=20

# Restart runner (picks up new config)
kubectl --context home-k3s delete pod -n forgejo -l app.kubernetes.io/name=forgejo-runner
```

## REST API

Base URL: `https://git.kblab.me/api/v1`

Auth: create an access token in Forgejo UI (Settings → Applications → Generate Token),
then pass as header: `-H "Authorization: token <TOKEN>"`

### Repo operations

```bash
TOKEN="<your-token>"
API="https://git.kblab.me/api/v1"

# List repos for authenticated user
curl -s -H "Authorization: token $TOKEN" "$API/user/repos" | jq '.[].full_name'

# Create a repo
curl -s -X POST -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-repo","private":true,"auto_init":true}' \
  "$API/user/repos" | jq .full_name

# Delete a repo (destructive — confirm first)
curl -s -X DELETE -H "Authorization: token $TOKEN" \
  "$API/repos/<owner>/<repo>"
```

### Mirror management

```bash
# Create push mirror (offsite DR to gitlab.com)
curl -s -X POST -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "remote_address": "https://gitlab.com/<user>/<repo>.git",
    "remote_username": "<gitlab-user>",
    "remote_password": "<gitlab-token>",
    "interval": "10m0s",
    "sync_on_commit": true
  }' "$API/repos/<owner>/<repo>/push_mirrors" | jq .

# List push mirrors
curl -s -H "Authorization: token $TOKEN" \
  "$API/repos/<owner>/<repo>/push_mirrors" | jq .

# Trigger mirror sync
curl -s -X POST -H "Authorization: token $TOKEN" \
  "$API/repos/<owner>/<repo>/push_mirrors/sync"
```

### Container Registry

```bash
# Login
docker login git.kblab.me -u <username> -p <token>

# Tag and push
docker tag myimage:latest git.kblab.me/<owner>/myimage:latest
docker push git.kblab.me/<owner>/myimage:latest

# List packages via API
curl -s -H "Authorization: token $TOKEN" \
  "$API/packages/<owner>?type=container" | jq '.[].name'

# Delete a package version
curl -s -X DELETE -H "Authorization: token $TOKEN" \
  "$API/packages/<owner>/container/<image>/<version>"
```

### Package Registry

```bash
# PyPI push
twine upload --repository-url https://git.kblab.me/api/packages/<owner>/pypi \
  -u <username> -p <token> dist/*

# npm publish
npm publish --registry=https://git.kblab.me/api/packages/<owner>/npm/

# Generic package upload
curl -s -X PUT -H "Authorization: token $TOKEN" \
  --upload-file myfile.tar.gz \
  "$API/packages/<owner>/generic/<package>/<version>/myfile.tar.gz"
```

### Actions / Workflows

```bash
# List workflow runs for a repo
curl -s -H "Authorization: token $TOKEN" \
  "$API/repos/<owner>/<repo>/actions/runs" | jq '.workflow_runs[] | {id, status, conclusion}'

# View run logs
curl -s -H "Authorization: token $TOKEN" \
  "$API/repos/<owner>/<repo>/actions/runs/<run_id>/logs"
```

## Backup

```bash
# Check backup schedule and recent jobs
kubectl --context home-k3s get cronjob -n forgejo
kubectl --context home-k3s get jobs -n forgejo --sort-by=.metadata.creationTimestamp | tail -5

# Manual backup trigger
kubectl --context home-k3s create job --from=cronjob/forgejo-backup forgejo-backup-manual -n forgejo

# Verify backup contents
kubectl --context home-k3s exec -n forgejo deploy/forgejo -- ls -lah /var/backups/forgejo/
```

## Config changes

Forgejo reads `app.ini` from `/data/gitea/conf/app.ini` on the PVC. The configmap
is mounted at `/etc/gitea/app.ini` and an init container copies it on pod start.

To apply config changes:

1. Edit `apps/forgejo/configmap.yaml` in git
2. Commit and push
3. `flux reconcile kustomization apps --with-source --context home-k3s`
4. **Delete the pod** — subPath mounts don't auto-update:
   ```bash
   kubectl --context home-k3s delete pod -n forgejo -l app.kubernetes.io/name=forgejo
   ```
5. Verify: `kubectl --context home-k3s logs -n forgejo deploy/forgejo --tail=20`

## Safety rules

- **Never delete repos or users** without explicit user confirmation.
- **Config changes require pod restart.** The subPath configmap mount is snapshot
  at pod creation. Changing the configmap alone does nothing — you must delete the pod.
- **Runner token is instance-level.** Regenerating it invalidates the existing runner
  registration. Only regenerate if the runner secret is compromised.
- **home-config changes go through Flux.** Never `kubectl apply` Forgejo manifests
  directly — edit in git, push, let Flux reconcile.
- **Don't run Forgejo CLI as root.** Always use `su-exec git forgejo ...` — Forgejo
  v14 refuses to start as root.

## Debugging

### Forgejo won't start

```bash
kubectl --context home-k3s logs -n forgejo deploy/forgejo --previous --tail=30
kubectl --context home-k3s describe pod -n forgejo -l app.kubernetes.io/name=forgejo
```

Common causes:
- **"address already in use" on port 22**: `START_SSH_SERVER` is true — must be false
- **"permission denied" on app.ini**: init container missing `chmod 664 && chown 1000:1000`
- **Install page after upgrade**: config not seeded to PVC path (init container issue)
- **OOM during migration**: bump memory limit temporarily in deployment

### Runner not picking up jobs

```bash
kubectl --context home-k3s logs -n forgejo deploy/forgejo-runner -c runner --tail=30
kubectl --context home-k3s logs -n forgejo deploy/forgejo-runner -c dind --tail=10
```

Common causes:
- Runner not registered (check for "Runner registered successfully" in logs)
- DinD sidecar not ready (check dind container logs)
- Workflow labels don't match runner labels (`docker`, `linux-amd64`)

## Quick reference

| What | Where |
|------|-------|
| Web UI | `https://git.kblab.me` |
| API | `https://git.kblab.me/api/v1` |
| Container Registry | `docker login git.kblab.me` |
| Swagger docs | `https://git.kblab.me/api/swagger` |
| Admin panel | `https://git.kblab.me/-/admin` |
| Manifests | `apps/forgejo/` in home-config repo |
| Config | `apps/forgejo/configmap.yaml` |
| Runner | `thinkcentre` node, `forgejo` namespace |
| Backups | `/var/backups/forgejo/` in Forgejo pod, daily at 03:00 |
