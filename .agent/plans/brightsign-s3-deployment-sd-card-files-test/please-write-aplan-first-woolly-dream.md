# Plan: BrightSign Deployment Pipeline (CI/CD)

## Context

The `brightsign-app-deployment-setup-test` repo has a working local build script (`build.sh`) but no CI/CD. Deploying requires manually running the script and uploading to S3. This plan wires up GitHub Actions so pushing to `main` automatically builds and deploys — completing the pipeline.

### How the full system works (important for understanding scope)

There are **two separate concerns** that are often confused:

**1. Device provisioning (SD card — already set up)**
- `SD_Card_Setup_Files/setup.json` contains `partnerUrl` → S3 zip URL — this IS BrightSign's "App URL Setup"
- On first boot: `autorun.brs` (setup) → reads `setup.json` → hands off to `provisionScript.brs` → downloads `autorun.zip` from S3 → reboots into the app
- This is a one-time bootstrapping step. **No changes needed here.**

**2. Deployment pipeline (what this plan adds)**
- `build.sh` produces `dist/autorun.zip` + `dist/version.txt` but nothing uploads them automatically
- GitHub Actions fills this gap: push to `main` → build → upload to S3

**App URL Setup does NOT eliminate the need for GitHub Actions.** App URL is how the *device* knows where to pull from. GitHub Actions is how the *zip gets onto S3* in the first place. They are complementary.

### Update model
- **Initial content**: Device bootstraps via `partnerUrl` in setup.json (one-time SD card provisioning)
- **Updates**: `S3_content/autorun.brs` polls `version.txt` every 30 min; if version differs, downloads new zip and hot-reloads the HTML widget — no reboot required

---

## Already Implemented (previous session)

| File | Change |
|------|--------|
| `.github/workflows/deploy.yml` | Created — triggers on push to `main`, runs `build.sh`, uploads both files to S3 |
| `build.sh` | Changed `ZIP_PASSWORD="test"` → `ZIP_PASSWORD="${ZIP_PASSWORD:-test}"` |

---

## What Still Needs to Be Done

### GitHub Secrets (manual step — cannot be automated)

Set these in the repo: **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user key with `s3:PutObject` on `brightsign-app-hosting-test` |
| `AWS_SECRET_ACCESS_KEY` | Matching secret |
| `ZIP_PASSWORD` | Optional — omit to keep using `"test"` |

The IAM user needs this minimum policy:
```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject"],
  "Resource": "arn:aws:s3:::brightsign-app-hosting-test/*"
}
```

---

## Critical Files (for reference)

| File | Status |
|------|--------|
| `.github/workflows/deploy.yml` | Done |
| `build.sh` | Done |
| `SD_Card_Setup_Files/setup.json` | Already correct — `partnerUrl` points to S3 |
| `S3_content/autorun.brs` | Already correct — OTA poll loop handles updates |

---

## Verification

1. Add GitHub Secrets
2. Push any change to `main` → check repo **Actions** tab → workflow goes green
3. Confirm: `aws s3 ls s3://brightsign-app-hosting-test/` — `version.txt` timestamp matches deploy time
4. Device picks up update within 30 min (or reboot to force it)
