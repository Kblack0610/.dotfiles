# Plan: BrightSign App URL OTA deployment for swas webviewer

## Context

The reference repo `GiganticPlayground/brightsign-app-deployment-setup-test` proves out the full BrightSign "App URL" deployment loop end-to-end against a test S3 bucket:

1. **First boot**: SD card with `autorun.brs` + `setup.json` (setupType `partnerApplication`) provisions the device with BSN.cloud and points `partnerUrl` at an S3-hosted `autorun.zip`.
2. **Runtime**: the unpacked `autorun.brs` opens an `roHtmlWidget` on `file:///index.html`, polls `version.txt` on S3 every 30 minutes, and on version change downloads + unpacks `autorun.zip` and hot-reloads the widget (no reboot).

swas/client/webviewer already produces per-receiver Vite bundles (`dist/<type>/<receiver>/`) configured for `file://` (IIFE format, `base: "./"`). It produces the HTML payload but is missing the BrightSign runtime wrapper, per-receiver S3 layout, video externalization, SD card provisioning bundle, and the upload tooling. The untracked `client/webviewer/autorun-node-html.zip` is the half-done artifact — HTML payload only, no `autorun.brs`/`autozip.brs`.

This plan turns the swas webviewer into a production-deployable BrightSign app across all 7 `brightSignPlayer` receivers, using the test repo's mechanism as the proven reference, with two important deltas: (1) per-receiver S3 paths, (2) videos hosted externally and referenced by URL so OTA payloads stay small.

**Scope**: 7 `brightSignPlayer` receivers — `signatureWall`, `signatureWall12ft`, `fireTV43Inch`, `fireTV65Inch`, `connectedEntertainmentEchoSpeakers`, `signatureWallEchoSpeaker`, `pacmanGame`. Echo Show players use a different runtime and are out of scope.

## Gap analysis — what is missing

Inventory of current vs. needed state:

| Concern | Current state in swas | Needed |
|---|---|---|
| HTML/JS payload per receiver | ✅ `client/webviewer/dist/brightSignPlayer/<r>/` (IIFE, `base: "./"`, file://-safe) | reuse as-is |
| BrightScript runtime (`autorun.brs`) | ❌ none | parameterized version per receiver |
| Bootstrap unpacker (`autozip.brs`) | ❌ none | copied from test repo |
| Password-protected `autorun.zip` | ❌ `autorun-node-html.zip` exists but is HTML-only, wrong shape | build script that bundles HTML + autorun.brs + autozip.brs per receiver |
| `version.txt` for OTA polling | ❌ none | timestamp written next to each `autorun.zip` |
| Per-receiver S3 layout | ❌ none | `s3://<bucket>/<receiver>/{autorun.zip,version.txt}` |
| Video hosting (1.8 GB in `public/videos/`) | ❌ embedded in bundle | external S3 path, referenced by env-driven base URL |
| SD card provisioning bundle | ❌ none | per-receiver dir generated from a templated `setup.json` |
| BSN.cloud credentials | ❌ test repo has `AustinTestBSNCloud` only | swas account + registration token in `.env.brightsign` |
| S3 upload tooling | ❌ none (no AWS SDK in webviewer deps) | `@aws-sdk/client-s3` deploy script |
| Secret management | ❌ none for BrightSign | `.env.brightsign` (gitignored) — zip password, AWS creds, BSN token, dwsPassword blob |
| Documentation / runbook | ❌ none | `client/webviewer/brightsign/README.md` |

## Proposed architecture

### Code layout — new `client/webviewer/brightsign/` subdir

```
client/webviewer/brightsign/
├── runtime/                                # files bundled INTO autorun.zip
│   ├── autorun.brs                         # parameterized OTA loop (reads receiver name from a local config)
│   └── autozip.brs                         # bootstrap unpacker (copied from test repo S3_content/)
│
├── sd-card-setup/                          # template files for SD card provisioning
│   ├── autorun.brs                         # provisioning script (copied from test repo SD_Card_Setup_Files/)
│   ├── autozip.brs
│   ├── autoplugins.brs
│   ├── featureMinRevs.json
│   ├── local-sync.json
│   ├── pending-autorun.brs
│   ├── provisionScript.brs
│   ├── setupCommon.brs
│   ├── setupNetworkDiagnostics.brs
│   ├── setup.template.json                 # placeholders: {{RECEIVER}}, {{BSN_ACCOUNT}}, {{BSN_TOKEN}}, {{BSN_DWS_PASSWORD}}, {{S3_BASE}}
│   └── pool/                               # copied verbatim from test repo
│
├── scripts/
│   ├── build-receiver.js                   # one receiver: vite build → assemble autorun.zip + version.txt
│   ├── build-all.js                        # iterate over all 7 brightSignPlayer receivers
│   ├── deploy-receiver.js                  # one receiver: upload autorun.zip + version.txt to s3://<bucket>/<receiver>/
│   ├── deploy-all.js                       # iterate all
│   ├── generate-sd-card.js                 # produce per-receiver SD card dir with rendered setup.json
│   └── lib/
│       ├── receivers.js                    # load receivers.config.json, filter type === "brightSignPlayer"
│       └── env.js                          # load + validate .env.brightsign
│
├── .env.brightsign.example                 # documents required vars
├── README.md                               # runbook
└── dist/                                   # gitignored build output
    └── <receiver>/
        ├── autorun.zip
        └── version.txt
```

### S3 layout — one bucket, per-receiver prefix

```
s3://swas-brightsign/                       # production bucket name TBD by user at deploy time
├── signatureWall/
│   ├── autorun.zip
│   └── version.txt
├── signatureWall12ft/
│   ├── autorun.zip
│   └── version.txt
├── fireTV43Inch/ …                         # 7 receiver prefixes total
└── videos/                                 # external video assets, uploaded separately
    ├── signatureWallSignatureWall-attract-loop.mp4
    └── …
```

Each receiver's `setup.json` and `autorun.brs` point at its own `<receiver>/` prefix, so each device only fetches its own slice.

### `autorun.brs` parameterization

Test repo's `S3_content/autorun.brs` hardcodes `s3Base` and uses a single `version.txt`/`autorun.zip` pair. Two changes for swas:

1. **Receiver discriminator**: at SD-card provisioning time, write a `receiver.txt` (single line: receiver name) into the SD card root. The runtime reads it on boot and composes URLs as `s3Base + receiverName + "/version.txt"`.
2. **S3 base URL** stays a build-time constant baked into `autorun.brs` (same for all receivers) — the only per-receiver difference is the receiver name file.

Everything else (timer, hot reload, `roBrightPackage` unpack flow, storage path discovery) stays identical to the test repo — that loop is the proven part.

### Video externalization

Files in `client/webviewer/src/` reference videos via the `attractorVideo`/`attractorVideoProximity` fields in `receivers.config.json:11` (e.g. `videos/signatureWallSignatureWall-attract-loop.mp4`). To externalize:

1. Add `VITE_VIDEO_BASE_URL` env var (default `./` for dev). When set during the BrightSign build (e.g. `https://swas-brightsign.s3.us-west-2.amazonaws.com/`), the resolver prefixes video paths with it.
2. The single component that loads videos resolves the path through a small helper (`getVideoUrl(name)` → `${baseUrl}${name}`).
3. Videos are uploaded to S3 once with `aws s3 sync public/videos/ s3://swas-brightsign/videos/`; they're versioned by filename so cache invalidation is implicit.
4. Result: `autorun.zip` per receiver drops to a few MB (HTML + IIFE bundle + small static assets), so the 30-min OTA loop downloads ~MB not ~GB.

The local `public/videos/` directory stays in place for dev — Vite serves it under `./videos/` exactly as today, no behavior change for `pnpm dev`.

### Deploy flow per receiver

```
pnpm bs:build --receiver=signatureWall
  └─ vite build with VITE_RECEIVER=signatureWall + VITE_VIDEO_BASE_URL=https://...
  └─ copy dist/brightSignPlayer/signatureWall/* + runtime/autorun.brs + runtime/autozip.brs into staging
  └─ zip -P <ZIP_PASSWORD> dist/signatureWall/autorun.zip ./*
  └─ date -u +%Y%m%d-%H%M%S > dist/signatureWall/version.txt

pnpm bs:deploy --receiver=signatureWall
  └─ s3 putObject autorun.zip → s3://<bucket>/signatureWall/autorun.zip
  └─ s3 putObject version.txt → s3://<bucket>/signatureWall/version.txt (LAST — ordering guarantees devices never see a new version.txt pointing at a stale zip)

pnpm bs:build:all && pnpm bs:deploy:all      # iterate over the 7 receivers
```

Devices pick up the change within 30 minutes (or on next reboot).

### SD card generation (first-boot provisioning)

```
pnpm bs:sdcard --receiver=signatureWall
  └─ copy sd-card-setup/* into out/<receiver>/
  └─ render setup.template.json with {{RECEIVER}}, {{BSN_ACCOUNT}}, {{BSN_TOKEN}}, {{BSN_DWS_PASSWORD}}, {{S3_BASE}} from .env.brightsign
  └─ write out/<receiver>/receiver.txt
  └─ tell operator: copy contents of out/<receiver>/ to a freshly-formatted SD card
```

This only needs to run once per physical device; subsequent updates flow purely through OTA.

## Files to create

- `client/webviewer/brightsign/runtime/autorun.brs` — based on `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test/S3_content/autorun.brs:1`, modified to read `receiver.txt` and compose per-receiver URLs
- `client/webviewer/brightsign/runtime/autozip.brs` — copy of `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test/S3_content/autozip.brs:1`
- `client/webviewer/brightsign/sd-card-setup/*` — copies of all files under `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test/SD_Card_Setup_Files/`
- `client/webviewer/brightsign/sd-card-setup/setup.template.json` — derived from `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test/SD_Card_Setup_Files/setup.json:1` with template placeholders for `account`, `bsnRegistrationToken`, `dwsPassword`, `partnerUrl`
- `client/webviewer/brightsign/scripts/lib/receivers.js` — loads `receivers.config.json`, filters `type === "brightSignPlayer"`
- `client/webviewer/brightsign/scripts/lib/env.js` — dotenv loader + required-var validation
- `client/webviewer/brightsign/scripts/build-receiver.js`
- `client/webviewer/brightsign/scripts/build-all.js`
- `client/webviewer/brightsign/scripts/deploy-receiver.js` (uses `@aws-sdk/client-s3`)
- `client/webviewer/brightsign/scripts/deploy-all.js`
- `client/webviewer/brightsign/scripts/generate-sd-card.js`
- `client/webviewer/brightsign/.env.brightsign.example`
- `client/webviewer/brightsign/README.md` (runbook: how to add a receiver, how to rotate creds, how to provision new hardware)

## Files to modify

- `client/webviewer/package.json:6` — add scripts `bs:build`, `bs:build:all`, `bs:deploy`, `bs:deploy:all`, `bs:sdcard`; add deps `@aws-sdk/client-s3`, `dotenv`, `archiver` (or shell out to `zip -P`)
- `client/webviewer/src/...` — the component(s) that consume `receivers.config.json`'s `attractorVideo`/`attractorVideoProximity` fields. Wrap path resolution in a `getVideoUrl()` helper that prefixes with `import.meta.env.VITE_VIDEO_BASE_URL ?? './'`. Confirm exact files during implementation by `grep -rn attractorVideo client/webviewer/src`
- `client/webviewer/.gitignore` — add `brightsign/dist/`, `brightsign/.env.brightsign`, `brightsign/sd-card-out/`
- `client/webviewer/vite.config.ts:1` — no change required; `VITE_VIDEO_BASE_URL` flows through automatically via `loadEnv`

## Files to delete (cleanup half-done state)

- `client/webviewer/autorun-node-html.zip` — superseded by per-receiver `dist/brightsign/<r>/autorun.zip`
- `client/controller/pacmanController.zip` — confirm with user; likely stale build artifact unrelated to deployment

## Secrets — `.env.brightsign` (gitignored)

```
# AWS
AWS_REGION=us-west-2
AWS_PROFILE=swas-deploy            # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
S3_BUCKET=swas-brightsign

# Zip
ZIP_PASSWORD=<strong-secret>       # replaces test repo's "test"

# BSN.cloud (per-environment)
BSN_ACCOUNT=<swas-bsn-account-name>
BSN_REGISTRATION_TOKEN=<token-from-bsn.cloud>
BSN_DWS_PASSWORD=<encrypted-blob-from-brightauthor-connected>

# Optional override
VIDEO_BASE_URL=https://swas-brightsign.s3.us-west-2.amazonaws.com/videos/
```

`.env.brightsign.example` documents these variables with placeholder values and a comment pointing at where each one comes from.

## Verification

End-to-end checks at each step:

1. **Build (no S3, no hardware needed)** — `pnpm bs:build --receiver=signatureWall` then `unzip -P <pw> -l dist/signatureWall/autorun.zip` shows `autorun.brs`, `autozip.brs`, `index.html`, `index.js`, `assets/*`. Confirm `version.txt` is a timestamp string. Repeat for all 7 receivers via `bs:build:all`.
2. **Video URL rewrite** — open `dist/signatureWall/index.html` and grep the bundled JS for the configured `VITE_VIDEO_BASE_URL`; should not contain any bare `./videos/` references.
3. **S3 dry-run** — `pnpm bs:deploy --receiver=signatureWall --dry-run` lists the two `PutObject` calls with correct keys (`signatureWall/autorun.zip`, `signatureWall/version.txt`); verify upload order (zip BEFORE version.txt).
4. **One-time video sync** — `aws s3 sync client/webviewer/public/videos/ s3://<bucket>/videos/ --dryrun` lists expected uploads.
5. **Live deploy** — push to S3, then `curl https://<bucket>.s3.<region>.amazonaws.com/signatureWall/version.txt` returns the timestamp string and `curl -I .../signatureWall/autorun.zip` is a 200.
6. **Hardware POC** — generate `pnpm bs:sdcard --receiver=signatureWall` against a real BSN.cloud test account, provision a physical signatureWall player, confirm boot and HTML widget renders the swas webviewer.
7. **OTA loop** — change a visible string in the app, `pnpm bs:build --receiver=signatureWall && pnpm bs:deploy --receiver=signatureWall`, wait ≤30 min (or reboot), confirm the player hot-reloads to the new content with no manual intervention.

## Out of scope (deferred)

- Echo Show / VegaOS deployment — different runtime, different plan
- CI/CD automation — manual deploys until the flow is stable, then move to GitHub Actions
- Multi-environment buckets (dev vs prod) — single bucket for now; add `<env>/<receiver>/` prefixing later if needed
- BSN.cloud account/token provisioning — user supplies real values; this plan only templates the wiring
- Cleanup of `controller/pacmanController.zip` — confirm with user before deleting

## Open values that must be filled in at execution time

| Value | Source |
|---|---|
| Production S3 bucket name | User (mentioned "we have access to s3 buckets") |
| AWS region | User |
| BSN.cloud account name | User (replace `AustinTestBSNCloud`) |
| BSN registration token | BSN.cloud console |
| `dwsPassword` encrypted blob | BrightAuthor:connected export |
| Zip password | User-chosen strong secret |
| Video base URL | Derived from bucket name + region (or CloudFront, if used) |
