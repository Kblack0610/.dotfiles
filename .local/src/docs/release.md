# How a release works

This page is the one home for release doctrine across every repo that ships: games and apps, desktop, Steam, Google Play, the App Store and TestFlight, and the web on the clusters. Each rule is one line: the rule, why, and the repo or doc that proved it. A repo's release doc holds only its own mechanics (its workflows, scripts, app ids and tag pattern) and links here for the rest. It never restates a rule from this page. Console click paths, the store accounts and where each store secret comes from live in the studio's store page, `~/.notes/lab/bnb/practices/release/stores.md`. Which stage reaches which channel is `stages.md`, and the CI gates a release reads are `ci.md`.

## What a release is held to

- A release is graded on one thing: the right commit, built clean, is live where it was meant to go, with proof and a way back. Why: feature-work checks (tests, review, a PR) say nothing about what players have (the `release` skill).
- Build once, from a tag, on the hosts the repo names. Never build a release from a worktree, a local checkout or an untagged commit. Why: a build nobody can trace to a commit cannot be rebuilt or blamed (playground `builds-and-releases.md`, `BUILD_INFO.txt`).
- Every channel ships the same artifact the gate passed: a promotion moves a build, and nothing is rebuilt for each store. Why: a rebuild is a new untested binary (playground Steam and Forgejo ship one zip; platform promotes the same image tag).
- A tag ships only when its commit has a green full run of the repo's whole suite; a merge gate's affected subset does not count. Why: rc3 and rc4 shipped with no run and rc6 on a red one while this rule was only text (playground `release-gate.sh`). An extended suite that sits outside the nightly core, such as the playground's Multi, is not part of the gate until it passes its re-admission bar.
- Shipping past a red takes a written reason, and the reason ships with the build (`RELEASE_UNTESTED`, `--untested`), so a red release shows on its page and is never silent. Why: an override without a record hides the risk from whoever installs it (playground `UNTESTED.txt`).
- Everything that can fail after the build is checked before it: the signing identity, the store login, the target branch or track, the artifact store and the tag. A release whose environment is broken fails within minutes, and the error names the cause. Why: v0.5.3 built for hours and then failed every Mac job on signing (plan ucp-2709 P1 and P2; playground `mac-sign.sh --check`).
- Artifacts are asserted before upload: the right game, tag, commit and platform set, and the executable present. Why: a depot from the wrong build uploads without complaint, and only a player finds out (playground `scripts/steam/stage.sh`).
- A green workflow is not live. Live is the store's own record showing the build (the Steam BuildID on the branch, the Play track's release, the processed TestFlight build, the App Store version, the running image in the cluster) plus a launch on a real client. Why: every Android release from v1.6.0 to v1.8.0 uploaded as a draft and reached no one while CI was green (platform `MOBILE_CICD.md`).
- A tester track is not the public: internal or TestFlight green says nothing about production or the App Store. Each public step is proved on its own. Why: platform releases built and verified for months while the public apps stayed behind (`MOBILE_CICD.md`, "Did it reach the public").
- The rollback is named before the upload, and the BuildID or version being replaced is recorded. Why: a way back worked out during a bad release is slower and riskier than one written down before it (the `release` skill).
- A rerun never sets an older build live unless it says it is a rollback. Why: a retried old run can quietly downgrade a branch (playground `steam.yml` newest-wins step).
- Each upload records a deployment (a GitHub Deployment per target, or the cluster manifest commit), and a drift check compares cut, desired and live. Why: production stayed on v1.9.0 for about 40 hours after a cut with nothing reporting it (platform `release-drift.yml`).
- For an online game, the server must accept the client's protocol before the client ships. Why: a client that cannot reach its server is broken on install (the `release` skill).
- Main keeps moving through a cut. The tag fixes what builds, so nothing pauses and late work rides the next release. Cut at the newest commit with a green full run, which may trail the tip. Why: a cut reserves its build lane and leaves the codebase open, and a paused main stalls every session on the repo (the `release` skill; ucp-2709 P1).

## Tags and versions

- The release tag is the authorization. One push of it starts everything downstream, and any retry re-reads it, so a failed run needs no new approval. Why: per-attempt approvals cost a human signature on every retry and ate about 12 releases (platform `RELEASE_APPROVAL.md`).
- A release tag is never moved or deleted. A bad tag gets a new one, and the repo's tag ruleset enforces it. Why: a moved tag makes the build no longer match its record (platform ruleset "Release tags - human only"; playground rulesets `v* tags immutable` and `v* tag creation`, #2934).
- Who may push a release tag follows where it lands. A tag whose push reaches the public with no later gate is the owner's. A tag that reaches only private channels (Steam `development` and `beta`, Play internal and closed testing, TestFlight internal) is the agent's, and the public step is taken separately (the table below). Each repo's ruleset enforces its half. Why: the one-way door belongs to the human, and everything before it is reversible. Today, platform's release tags are the owner's (`deploy.sh ship`, ruleset "Release tags - human only"), and the playground's `ship.sh` tags are the agent's.
- Each repo has one tag pattern, enforced by its trigger regex or staging script: platform `<app>-v<major>.<minor>.<patch>`; playground `v<version>` for the playground and `v<version>-<game><n>` for a game. A tag outside the pattern builds nothing. Why: a loose pattern either builds by accident or silently does not (platform `TAG_BASED_DEPLOYMENTS.md`).
- Versions are plain semver bumps: patch for a routine drop, minor for a batch, major for a break or a forced update. No release-candidate tags (`-rcN`). A build meant only for your own devices takes a suffix the updater never offers. Why: the updater offers only plain versions, so a candidate train leaves every plain install with nothing to take (playground `launcher.md`).
- The version string and the store build number come from one source and rise together. A build number is never reused or lowered. Why: Play refuses a reused `versionCode`, and Apple refuses a reused build number (platform `app.json`; playground uses the commit count).

## Who takes the public step

| Channel | Private steps | The public step | Who |
|---|---|---|---|
| Steam | `development`, `beta`, `none` through `SetLive` in the build script | Set the build live on `default` in Steamworks > SteamPipe > Builds. Valve refuses a scripted `default`, so it is a click | the agent, through `store-console`, as its own queued item, once the build was verified on `beta`, after checking whether the app is publicly released and recording the BuildID it replaces (standing permission, 2026-11-06) |
| Google Play | internal and closed testing | Promote to production. With Managed publishing on, a Publish click follows | the person, or the owner's tag where the workflow promotes (platform) |
| App Store | TestFlight | Submit for review, then release. Apple's review is human and takes 24 to 48 hours or more | the person, or the owner's tag where the workflow submits (platform, opt-in) |
| Web (prod cluster) | the preview on every merge | Push the release tag | the owner |

Every console step and its click path is in the studio's store page.

## Stores

### Steam

- Branches: `development` is alpha, `beta` is beta, `default` is prod (`stages.md`). `none` uploads without setting anything live.
- A branch must exist before anything sets it live, and a new app has no branch list until `default` has a build. So the first upload uses `none`, and that BuildID goes live on `default` by hand. Why: `SetLive` to a missing branch fails the commit after a good upload.
- On "Failed to commit build", read the partner builds page before anything else: the upload usually worked and only `SetLive` failed. Never retry blind.
- Uploads log in as a dedicated build account with a saved login (`config.vdf`) held as a secret, on a hosted runner. The login is never on a pool host or the agent machine. Why: a second copy of the login drifts (the `release` skill).
- Rollback: set the previous BuildID live on the branch. On a beta branch, `ISteamApps/SetAppBuildLive` does this with the publisher key. On `default` it is a click.

### Google Play

- Tracks: internal (up to 100 testers), closed, then production. A new app's first release is uploaded by hand, because the API refuses it.
- Upload with `status: completed`. Then read the track back through the API, because a draft reports success and is never released.
- Play App Signing holds the app key, and the repo holds only the upload key. The service account can release to the testing tracks only; production is the person's.
- A new personal developer account must run a closed test (12 testers for 14 days) before production.
- Rollback: Play cannot go back to a lower `versionCode`. Halt a staged rollout, or ship the old code under a higher `versionCode`.

### App Store and TestFlight

- The App Store Connect API key (the `.p8`) signs and uploads. No Apple ID password is stored.
- A processed TestFlight build is not the App Store. The public version needs review and a release, each proved on its own.
- `ITSAppUsesNonExemptEncryption` in `Info.plist` answers export compliance for every build.
- Before submitting, run the review checklist against production (platform `IOS_SUBMISSION_CHECKLIST.md`): the demo account, sign-in providers and App Review Information.
- A rerun skips a build number App Store Connect already has, rather than re-uploading it (ucp-2709 P11).
- Rollback: none. Pause a phased release, or ship a fixed build through expedited review.

### Mac signing and notarization

- Sign with an Apple-issued Developer ID Application identity, never ad hoc or self-signed, for anything that leaves the build host. Why: an ad-hoc signature changes every build, and macOS drops grants such as Local Network Allow that are tied to the signature (playground `platform-builds.md`, TN3179).
- The identity lives in its own keychain, and every `codesign` names it with `--keychain`. Why: a rewritten keychain search list failed every v0.5.3 Mac job (playground #2928).
- The signing check is the Mac job's first step: unlock, find the identity, and sign and verify a scratch binary. Why: the one build Mac is busy for hours, so a light preflight cannot reach it in time (ucp-2709 P2).
- A release adds the hardened runtime, a secure timestamp and its entitlements, notarizes with `notarytool`, staples, and asks Gatekeeper (`spctl`). Anything but Accepted fails the build, with Apple's log in the job output.
- The certificate's expiry date is recorded beside the identity, and its renewal steps are in the repo's signing doc.

### Web on the clusters

- Each merge to the dev branch deploys the preview. A tag builds the images and opens a manifest PR, and GitOps reconciles production from the branch it watches. Platform `TAG_BASED_DEPLOYMENTS.md` has the flow.
- The preview gate runs against the live preview before any tag. Why: a red preview then costs no merge into `main`.
- Rollback: revert the manifest's image tag by PR on the watched branch. Pushing to the dev branch does not roll back production.

## Secrets

- Each store key is set once, as an org secret shared by every repo that uploads, with its value from rbw or SOPS. A repo copy of the same name is deleted. Why: two copies drift, and nobody knows which one signed a build (the studio's store page, Secrets).
- Release secrets are readable only from a release-tag ref (environments with a `v*` deployment policy), so a dispatch from a branch cannot reach them. Why: any writer could otherwise dispatch a run that holds the store and signing keys (playground #2934, ucp-2709 P10).
- A signing keystore or key file written for a build is deleted right after the step that used it.
- GitHub never shows a secret again, so each one's source is written down where its inventory lives: the studio's store page for store keys, and a repo's Steam doc for its Steam login.

## Per-repo release docs

| Repo | Its release docs | Skills |
|---|---|---|
| unity-core-playground | `docs/operations/builds-and-releases.md` (the flow), `steam.md`, `play-store.md`, `stores.md` (the order for a new game), `platform-builds.md` (Mac signing) | `release`, `store-console`, `tester-access` |
| platform | `docs/deployment/RELEASE_APPROVAL.md` (the gate), `TAG_BASED_DEPLOYMENTS.md` (web and cluster), `MOBILE_CICD.md` (mobile), `IOS_SUBMISSION_CHECKLIST.md` | its release skill, `mobile-store-metadata`, `store-console` |
| studio, every app and game | `~/.notes/lab/bnb/practices/release/stores.md`: console steps, accounts, store secrets | `store-console` |

A repo that ships and has no row here has no release path yet: write its release doc first, then add the row.
