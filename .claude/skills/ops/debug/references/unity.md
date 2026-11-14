# Unity reference

Engine facts for the `debug` spine in any Unity repo. The repo's own scripts (its test runner, run slots, MCP editors, crash pipeline) are in its adapter doc; this file holds only what is true of Unity itself. Perf, hitches and memory growth: `game-eval`. Quest devices: `hz-vr-debug`.

## Where the evidence is

| Log | Linux | macOS | Windows |
|---|---|---|---|
| Editor | `~/.config/unity3d/Editor.log` | `~/Library/Logs/Unity/Editor.log` | `%LOCALAPPDATA%\Unity\Editor\Editor.log` |
| Player | `~/.config/unity3d/<Company>/<Product>/Player.log` | `~/Library/Logs/<Company>/<Product>/Player.log` | `%USERPROFILE%\AppData\LocalLow\<Company>\<Product>\Player.log` |

- `Editor-prev.log` (the previous session) and `upm.log` (Package Manager) sit beside `Editor.log`. Android and iOS players have no log file: use `adb logcat` or Xcode.
- A batch run gets its own `-logFile <path>`; `-logFile -` sends the log to stdout (checked on Linux, where our batch runs are). A run that shares the default `Editor.log` mixes with the human's editor.
- `Application.consoleLogPath` gives the path at runtime.

## Success signals that lie

- An exit code is not a result. A batch exception exits 1, but compile errors are not documented as an exit code: grep the run's log for `error CS`. A test run is proved by its NUnit results XML; no results file means the tests did not run, whatever the exit code.
- `-quit` with `-runTests` quits before the tests finish. Never combine them.
- A batch run against a project another editor holds open fails (`Temp/UnityLockfile`).
- Batchmode skips the API Updater unless `-accept-apiupdate` is passed, so a package bump can compile in the editor and fail in batch.
- `LogAssert.ignoreFailingMessages = true` stops an unexpected error log from failing the test, so it hides real bugs. Expect the specific message with `LogAssert.Expect` instead.

## Bug classes to check first

Walk this list at step 5, before a novel theory; each is a common cause with a known signature.

- **Domain reload off** (Enter Play Mode settings): statics and static event subscribers survive between Play sessions. Reset them in a `[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]` method. Signature: works on the first Play, wrong on the second.
- **Destroyed is not null.** `==` on a `UnityEngine.Object` reports a destroyed object as null; `?.`, `??`, `is null` and a reference held as an interface do not, so they pass a dead object along. Signature: `MissingReferenceException`, or code that runs on an object already gone.
- **Execution order.** `Awake` and `OnEnable` run together per object, `Start` before its first `Update`; the order across objects is undefined unless Script Execution Order sets it. Signature: depends on scene load order or on which object was created first.
- **Lifetime of async work.** A coroutine stops when its GameObject is deactivated or destroyed (not when the component is merely disabled); an `async` method keeps running after its object is destroyed unless it observes `destroyCancellationToken`. Signature: errors right after a scene change or despawn.
- **Serialization.** A renamed serialized field silently loses its data without `[FormerlySerializedAs]`; a prefab override or a missing script reference wins over code defaults. Signature: the value in the Inspector is not the value in code.
- **Editor and player differ.** Code under `#if UNITY_EDITOR`, IL2CPP managed code stripping (types reached only by reflection need `link.xml` or `[Preserve]`), and platform defines. Signature: fine in Play mode, broken in a build.
- **Assets.** A missing or duplicated `.meta` GUID, an asmdef reference that does not resolve, an asset not yet reimported. Signature: a reference goes missing after a merge or a clone.
- **Frame and time.** Logic in `Update` that should be in `FixedUpdate` (or the reverse), unscaled time while paused, frame-rate dependent movement. Signature: changes with fps or on a slow machine.
- **Multiplayer.** A code path that runs only on the server, only on a client, or twice on a host (server and client in one process); ownership and authority; tick or spawn order. Signature: works for the host, wrong for a remote client, or wrong only under latency.

## Reproduce

- Pure logic: an EditMode test. Lifecycle, physics, scenes, networking: a PlayMode test that loads the smallest scene that fails.
- Seed every random source the repro touches, and bound every wait with a timeout whose failure message says what it was waiting for.

## Instrument

- One marker per bug (`DBG-<slug>`) in `Debug.Log` calls at component boundaries; grep it out at step 7.
- Stack traces per log type: `Application.SetStackTraceLogType` (Full is costly, set it only while debugging).
- `Debug.unityLogger.logEnabled = false` still evaluates the arguments. A hot-path log goes through a `[Conditional("SYMBOL")]` wrapper, which removes the call and its allocations.
- Debugger: the editor must be in Debug code optimization; a player needs Development Build plus Script Debugging, and Wait For Managed Debugger to catch startup. A breakpoint freezes the editor, so never attach to the human's editor.
- Render bugs: the Frame Debugger. Memory growth: two Memory Profiler snapshots compared (that is `game-eval` territory).

## Native crashes

- Keep the symbols of every shipped build (Android: Player Settings, Symbols, zip); a crash without its build's symbols cannot be read.
- Match the crash's ABI to the symbol directory, then `ndk-stack -sym <symbols/ABI> -dump <tombstone or logcat>`, or `llvm-addr2line -f -C -e libil2cpp.so <address>` for one frame.
- `adb logcat -s Unity DEBUG AndroidRuntime`: Unity's log, the native backtrace and Java crashes.
