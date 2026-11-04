# The manual walk

Use this when the walk signs off a tree before it merges or ships. Automated green is a precondition for it, never a substitute: a table can pass an overflow sweep on `min-w-max` while every toggle sits off-screen, because the sweep asserts the document fits the viewport and cannot tell "laid out correctly" from "pushed somewhere you cannot see".

The app's own preview or dev doc owns its specifics: the stack command, the seeded logins, the mail catcher and the test-only reset and seed routes. Read it first; do not keep a second copy of those here.

## Order of operations

1. Check the app's preview lock if it has one. A local stack is often machine-global (ports, one shared database container); if another worktree holds it, stop and name the holder. Do not race it.
2. Start the preview stack the app's doc names.
3. Reset first, authenticate second, never the reverse. A test reset route usually clears shared auth, so a reset after login logs you out mid-walk without saying so.
4. Walk. Then take a static gallery if the app has one and it helps the write-up.

## Surfaces

### Web, at 390 and 1280, measured in the DOM

Use the seeded login for each role the flow touches. Anything email-shaped (verification, password reset) is read from the local mail catcher, never a real inbox.

Measure, do not eyeball. A scaled screenshot lies:

```js
// overflow
document.documentElement.scrollWidth > window.innerWidth
// an element that claims to fit
const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
```

Per bug: its reproduction steps. Per role: the primary journey end to end. Anything that cannot be checked by hand gets `n/a - <why>`, never a blank: an unverifiable item must read as a visible decision, not an omission.

### Mobile, on the emulator

A web preview stack usually does not start the mobile app; start it separately with the app's own command (it should set up `adb reverse` for the API ports). Drive it with the `adb-ops` skill. The emulator is another exclusive resource: run `adb devices` before assuming it is free. Cover web and mobile parity for anything the sheet flags as a parity item.

### Consumer apps, only when the diff touches shared packages

In a monorepo, shared packages are the cross-app blast radius. Take the list of affected apps from CI's change-detection outputs rather than a hand-kept list, which is a second thing to drift. Skip this entirely when the diff touches no shared package; it is a real expansion of the walk and should not run speculatively.

## Test routes

When the app exposes test-only reset and seed routes, they must be mounted only outside production and guarded a second time at the router. A 200 from the test health route is the go/no-go signal that test mode is live. Know what reset deletes (typically only seeded test-domain accounts) before you run it against a shared database.
