# CLAUDE.md — session handoff

Read this first. `README.md` has the full narrative history (every bug found and fixed, with source citations) — this file is the short "what's the state right now, what do I do next" pointer into it. Update this file at the end of any session that changes the architecture, not just README.

## Current goal (as of 2026-09-07)

The vscode-reh-web pivot (switching the app's server payload from `HeCPDF/code-server`
to building `vscode-reh-web` straight from official `microsoft/vscode` source) is
**confirmed working end to end in the Simulator** — see README's "CONFIRMED
(2026-09-06/09-07)" block under the vscode-reh-web pivot section for the real evidence
(log excerpts, screenshots). This was the open item at the top of this file as of
2026-09-02; it's done. Read that README block before doing anything else this session —
don't re-run the verification steps below, they're already done and evidence-backed.

The earlier "real Electron desktop bundle in WKWebView" pivot
(`NativeWorkbenchExperimentView.swift`) is **abandoned for good** — iOS
cannot host a real Electron/Chromium main process, full stop, not a
tooling gap. See README's "Electron-desktop pivot ... is abandoned" section
before ever reconsidering that direction. Its CI hook (`NativeWorkbenchUITests`,
`-UITestOpenNativeWorkbench`) still runs in `simulator-test.yml` and will keep
showing "Native bundle not found" — expected, not a regression, not worth
investigating again.

## Where things actually stand — CHECK THIS FIRST

Confirmed this session (2026-09-24), each checked directly rather than trusted from a
green checkmark. This session found and fixed several real, previously-undiscovered
bugs via the full `vscode-reh-web-build.yml` → `build.yml` → `simulator-test.yml` loop,
downloading and actually reading the `simulator-test-results` artifact each time:

1. **Agent-host `spawn EPERM` fix (`ios-agenthost-no-fork.diff`, already written by a
   prior session) had a real `tsc` compile error**, caught by a genuine
   `vscode-reh-web-build.yml` failure (run `35966340204`): `WorkerClient`'s env-building
   code was typed `Record<string, unknown>`, which `removeDangerousEnvVariables()`
   rejects, and even fixed, `worker_threads.WorkerOptions.env` requires
   `Record<string, string>` (no `undefined` values) — stricter than
   `child_process.ForkOptions.env`. Fixed in commit `b8933e5` (build a
   `rawEnv: IProcessEnvironment` first, then filter out `undefined`-valued keys before
   passing to `new Worker(...)`) — confirmed via a clean `vscode-reh-web-build.yml` run
   (`35967663473`).
2. **The extension host Worker OOMs and restarts on every single boot — a real,
   previously-undocumented bug, found by actually reading `node-stdio.log`, not
   trusting a green checkmark.** `NodeRuntimeController.swift` starts the main process
   with `--max-old-space-size=256` (chosen for the main thread's own footprint), and
   `extensionHostConnection.ts`'s iOS `worker_threads` branch was blindly re-deriving
   the extension host Worker's own `resourceLimits.maxOldGenerationSizeMb` from that
   same inherited `256`, starving the extension host of memory it actually needs (it
   normally runs unconstrained as a real forked process on desktop). Root-caused and
   fixed in `vscode-patches/ios-exthost-worker-heap.diff` (three commits,
   `854c06e`→`24c572e`→`1b967f1`, each re-verified against a fresh `simulator-test.yml`
   run before moving on — see that patch file's own comments for the full evidence
   trail). **Net result, confirmed via a `repeat=2` `simulator-test.yml` run
   (`35979036132`, 4 total app launches): every launch AFTER the very first one now
   starts the extension host cleanly with zero OOM, 0/2 in that run (previously 100%
   crash-and-restart on every boot).**
3. **Root cause of the remaining first-launch-only OOM found (2026-09-24, later same
   day): it's a real nodejs-mobile platform limitation, not a config/sizing problem.**
   Added temporary heap-stats instrumentation directly to `bootstrap-fork.ts` (logging
   `v8.getHeapStatistics()` every second inside the extension host Worker specifically;
   see `ios-exthost-worker-heap.diff`'s own "UPDATE 4" comment for the full patch
   history — three failed compile attempts along the way, each a real `tsc` error
   caught by CI and fixed properly rather than guessed around, including discovering
   this codebase's own deliberately-opaque `Timeout` type in
   `src/typings/base-common.d.ts`). The captured log
   (`simulator-test.yml` run `36031623694`) shows the smoking gun directly:
   ```
   [iOS-DIAG heap] ... v8UsedHeap=82.6MB v8TotalHeap=116.1MB v8HeapLimit=304.0MB
   ```
   Despite `resourceLimits.maxOldGenerationSizeMb` being requested at `2048`, V8's own
   self-reported effective ceiling for that exact Worker was only **~304MB** —
   explaining precisely why raising the requested value from 512→1024→2048 made zero
   further difference to the cold-launch crash (all three get silently clamped to the
   same ~304MB platform ceiling; only the *original* 256MB was ever small enough to
   actually be the value in effect). This is very likely a bug in how this nodejs-mobile
   build wires (or fails to wire) `worker_threads.Worker`'s `resourceLimits` through to
   the underlying V8 isolate — a runtime/native-binding issue, not fixable from vscode's
   own TypeScript source, same category as the already-documented no-real-pty and
   `-fno-exceptions`/gyp-cache limitations. The log also shows a genuine ~35-second gap
   with zero diagnostic output (event loop fully blocked) between an 82.6MB reading and
   the eventual crash — something synchronous and heavy runs during that window on a
   cold launch specifically, but it is **not** the main process's own "Started
   initializing default profile extensions" step (that already completed 29 seconds
   *before* this exthost Worker was even launched — the "leading suspect" from the
   `854c06e`/`24c572e`/`1b967f1` commits' own comments was wrong, now corrected). The
   real cause of that blocking window (leading guess: first-time built-in-extension
   activation/compilation) is still open — see "Next session's first move" below. The
   diagnostic instrumentation itself has been removed (`vscode-patches/
   ios-exthost-heap-diagnostic.diff` reverted) now that it answered the question it was
   added to answer; its findings live on in `ios-exthost-worker-heap.diff`'s own
   comments. The same ~304MB clamping almost certainly also affects the agent host's
   own `WorkerClient` (`ipc.cp.ts`), which requests the same 2048MB and hasn't been
   separately verified — see `ios-agenthost-no-fork.diff`'s own "UPDATE 2" comment.
4. `ServerAgentHostManager: agent host failed to start Error: spawn EPERM` (item 1
   above) — the underlying fix predates this session (root-caused 2026-09-07); this
   session only fixed its compile error and confirmed the fixed version still applies
   and compiles cleanly across the whole 31-patch series.
5. **`@vscode/deviceid`'s `require("uuid")` ESM incompatibility — a real,
   non-iOS-specific upstream bug**, found in the same log-reading pass as item 2.
   `@vscode/deviceid@0.1.5` (the version actually locked in vscode's own
   `package-lock.json` at the pinned commit — not `0.1.1`, an earlier session's stale
   assumption) depends on `uuid@^14.0.0`, which is ESM-only, but its own compiled
   `devdeviceid.js` still does a plain CommonJS `require("uuid")` — broken on any
   platform the moment `getDeviceId()` is called, not iOS-specific. Fixed in
   `scripts/trim-vscode-reh-web.sh` (commit `f95031c`, same pattern as the existing
   crypto-global shim there: moved the import into a dynamic `await import("uuid")`
   inside the already-`async` function). Verified functionally (ran the patched file
   against a real local `uuid@14.0.0` install) and via CI (`ERR_REQUIRE_ESM` is gone
   from both pre- and post-UI-test logs in verification run `35984721126`).

**Next session's first move**: there is no pending/unverified build right now (HEAD is
the commit that reverted the diagnostic patch and documented the ~304MB finding —
check `git log -1` for the exact SHA; `vscode-reh-web-build.yml`/`build.yml`/
`simulator-test.yml` were all last confirmed green on the commit just before that
doc-only one). Pick a next concrete task from README's "Not done yet" list. In rough
order of CI-actionability (things that don't require a physical iPad or a Mac dev
environment):
1. **The first-launch-only extension host OOM's remaining ~35-second blocking window**
   (see item 3 above) — the heap-ceiling half of this is now understood (a ~304MB
   nodejs-mobile platform clamp on `worker_threads.Worker`'s `resourceLimits`, not
   fixable from vscode's own source), but WHAT specifically runs synchronously for ~35
   seconds on a cold launch and drives usage past that ~304MB ceiling is still unknown
   (confirmed NOT the main process's "default profile extensions" step, which finishes
   well before the exthost Worker even starts). Next step: re-add a scoped version of
   the reverted heap-stats instrumentation (or add timestamps around specific
   suspected culprits — likely candidates: `typescript-language-features`' TS compiler
   cold-load, or another built-in extension's first activation) to find out what
   actually runs during that silent window, rather than guessing. A real fix would
   most likely mean deferring or lightening that one-time work, since the ~304MB
   ceiling itself can't be raised from here.
2. Separately, verify whether the agent host's own `WorkerClient` hits the same
   ~304MB ceiling in practice (not yet directly observed, since no CI test exercises
   the agent host's actual chat/agent functionality) — lower priority than item 1 since
   it's not yet a confirmed problem, just a suspected one by analogy.
3. `experiment-sqlite3-ios.yml`'s stuck gyp-cache investigation (see README's "Not done
   yet" — real root cause found for `-fno-exceptions`/`-fno-rtti`, fix still elusive;
   five attempts at the `common.gypi`/`binding.gyp` source level have failed
   identically — next step is finding gyp's actual config cache location, not another
   attempt at the same two files).
4. Dynamic native menu bar / `nativeHost` channel work (README's "Not yet done" under
   the menu-bridge section) — a materially larger undertaking, comparable in scope to
   the JIT/TXM work, not a quick follow-on patch.

Real-device-only items (JIT/TXM, background audio keep-alive, real sandboxing
differences) can't progress without a physical iPad in this pipeline — don't attempt to
simulate confidence on those; say plainly they're unverified if asked.

## Architecture facts worth knowing before touching this again

- `vscode-patches/series` lists the curated ~28-patch subset kept from
  `HeCPDF/code-server`'s own `patches/` (28, not the fork's full ~29 — see
  README for exactly which ones were dropped and why: only
  `getting-started.diff`, `app-name.diff`, `logout.diff` are genuinely
  Coder-branding-specific; `copilot.diff` looked droppable but is actually
  required build plumbing — `compile-copilot-extension-full-build` — not
  branding, and was re-added).
- Applying the series isn't a plain `patch -p3 < each-file` loop — dropping
  those Coder-only patches shifted context in a handful of shared blocks
  (`serverEnvironmentService.ts`'s CLI option list,
  `webClientServer.ts`'s `productConfiguration` object, `product.ts`'s
  `IProductConfiguration` interface). `scripts/vscode-patch-fixups.mjs`
  inserts the handful of lines those dropped patches would have added, by
  unique-string anchor, called at three specific points in the apply
  sequence — see `.github/workflows/vscode-reh-web-build.yml`'s "Apply
  curated patch series" step for the exact order. If you ever add or
  remove a patch from the series, re-verify the whole apply sequence
  locally against a fresh `microsoft/vscode` checkout before pushing (see
  README for how this was done — clone at the pinned commit, apply in
  order, check for `.rej` files) rather than trusting CI to tell you.
- `NodeRuntimeController.swift` launches `server-main.js` directly (found
  by filename search under `Resources/vscode-server`, not a hardcoded
  path) with vscode's own native CLI flags — not code-server's. See
  README's "vscode-reh-web pivot" section for the exact flag mapping.
- Pinned vscode commit: `08d4889f9ec4a1685d257b9b95de036c8e1ce1e5` (same
  one used by the now-abandoned Electron experiment, kept for
  consistency — a real, already-verified-buildable commit, not a guess).
- A successful `vscode-reh-web-build.yml` run is itself a real `tsc` pass over every
  patch in the series (the gulp task it runs compiles TypeScript for real) — no need to
  set up a separate local vscode build environment just to re-verify a patch applies
  and type-checks; a green build IS that verification now.

## Known, permanent ceilings — not bugs, don't try to "fix" these

Discussed explicitly with the user; worth restating so a future session
doesn't burn time on them:

- **No *real* pty-backed terminal.** `node-pty` needs a real kernel pty
  (`/dev/ptmx`); iOS denies that to third-party sandboxed apps, same as it
  denies `fork()`. No known workaround short of jailbreak for that specific
  mechanism — but see README's corrected "no integrated terminal" section:
  [Pyto](https://github.com/ColdGrub1384/Pyto) proves a terminal-*styled*
  UI (`hterm`) driving in-process, statically-linked command
  implementations (`ios_system`, ~150 commands compiled into the app, no
  `fork()`/`exec()` anywhere) is real and shipping without jailbreak. Not
  a full shell (no arbitrary binaries, no job control), but a genuine,
  unexplored path — not a flat ceiling. Worth investigating before ruling
  a terminal out again.
- **No native process spawning**, so most debug adapters (anything that
  spawns a debuggee as a child process) won't work. Only in-process/pure-JS
  debug adapters will.
- **`worker_threads.Worker`'s `resourceLimits.maxOldGenerationSizeMb` appears to be
  silently clamped to ~304MB on this nodejs-mobile build, regardless of what's
  requested — found 2026-09-24, confirmed via direct `v8.getHeapStatistics()`
  instrumentation, not guessed.** Requesting 512MB, 1024MB, or 2048MB all produced the
  exact same real ~304MB ceiling (`v8HeapLimit=304.0MB` self-reported by the isolate);
  only a request *smaller* than ~304MB (the original, buggy 256MB) was ever actually
  honored as requested. This is very likely a bug in how this nodejs-mobile build wires
  (or fails to wire) `resourceLimits` through to the underlying V8 isolate at Worker
  creation — a runtime/native-binding issue, not something fixable by changing the
  requested number from vscode's own TypeScript source. See
  `vscode-patches/ios-exthost-worker-heap.diff`'s "UPDATE 4" comment for the full
  evidence. Don't spend time raising these numbers further without new evidence the
  underlying clamp itself has changed.
- **Full-text search (Find in Files, Cmd+Shift+F) is very likely completely
  broken, not just degraded — found 2026-09-24, not yet observed failing in
  a real run, but structurally certain.** `ripgrepTextSearchEngine.ts`
  (`src/vs/workbench/services/search/node/`) is vscode's *only* text-search
  engine — there is no pure-JS fallback file alongside it — and it works
  by `cp.spawn()`-ing a real, separately-compiled `rg` binary
  (`ripgrepFileSearch.ts:22`). Unlike the extension host and agent host
  (both fixable by swapping the *launch* mechanism to `worker_threads`,
  since the thing being launched was Node/JS code all along), ripgrep is a
  compiled Rust binary, not JavaScript — there is no worker_threads
  equivalent for "run a different program," and cross-compiling ripgrep
  for iOS-arm64 would not help either, since the sandbox denies spawning
  *any* new process at all to third-party apps, regardless of the target
  binary's platform or architecture. The only path that could work at all
  mirrors what README's corrected terminal section already found for
  Pyto/ios_system: embed ripgrep's actual search logic as a statically
  linked native Node addon or a WASM build, called via a function call
  instead of a subprocess — a materially large, unattempted project, not a
  patch. Same root cause and same fix-shape as `agentHostWorkspaceFiles.ts`'s
  own `cp.spawn(resolvedRgDiskPath, ...)` (the AI agent's separate
  workspace-file-listing tool) and `agentHostGitService.ts`'s
  `cp.execFile('git', ...)` calls (real `git` binary, same "external
  compiled binary" problem, not `fork()`-of-Node-code) — all three are the
  same class of gap, none of them fixable by the worker_threads trick that
  already worked for the extension host and agent host's own IPC.
- **JIT is disabled on real device** (`--jitless`), only enabled in
  Simulator — see README's "JIT: currently disabled" section for the real
  fix this would need (a V8 memory-allocator patch verifiable only on a
  real iOS 26+/TXM device).
- **Marketplace is open-vsx, not Microsoft's official one** — Microsoft's
  Marketplace ToS restricts access to official Microsoft-badged builds;
  every non-official vscode-web deployment (this one, VSCodium, Gitpod,
  code-server itself) has the same constraint. Not fixable by more
  engineering.
- **App Store distribution feasibility is unresolved and risky.** Bundling
  a general-purpose code-execution/extension-host environment inside an
  iOS app sits close to territory Apple's review guidelines restrict. This
  has not been investigated or resolved — worth doing before investing
  much more, if wide distribution (not just personal sideloading) is a
  goal.

## Task list state

Tasks #1–#17 are done (see `TaskList` if the harness surfaces them). Task
#18, "Minimize Local/Remote settings-split UX artifact," is **partially
done** (the label formatter, `ios-remote-label.diff`) and **deliberately
not pursued further** — removing the split itself would mean re-plumbing
how vscode-web's client discovers its backend, a risk category this
project decided not to take on. Leave it at "label fixed, split itself
inherent and left alone" unless a future session gets an explicit ask to
revisit that specific tradeoff. Task #19, "Verify agent-host, ptyHost,
deviceid fixes via full CI loop," is **done** for the compile-error and
warm-launch fixes described above; the first-launch-only exthost OOM
finding it surfaced along the way is tracked as its own open item (see
"Next session's first move" above), not part of #19 itself.
