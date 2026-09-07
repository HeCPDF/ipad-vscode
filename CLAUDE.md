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

Confirmed this session (2026-09-07), each checked directly rather than trusted from a
green checkmark:
- `vscode-reh-web-build.yml` run `33641059792` (pending as of the 2026-09-02 handoff) —
  **succeeded**.
- `build.yml` run `34043104925` (2026-09-06, triggered by someone/something between
  sessions, not recorded anywhere before now) — **succeeded**.
- `simulator-test.yml` run `34043323244` (2026-09-06) — **succeeded**, and its
  `simulator-test-results` artifact was downloaded and actually read:
  `node-stdio-1-pre/post-uitest.log` show the server binding, the extension host Worker
  launching and staying up, and zero occurrences of every previously-fatal error
  signature this project has ever hit. `uitest-screenshot-1-2.png`/`-8.png` show the
  real vscode "Code - OSS" welcome page and Chat panel actually rendered in the
  WKWebView. Only expected/already-documented errors remain (`spdlog` dlopen,
  `deviceid` unsupported-platform, `ptyHost`/`spawn sh ENOENT` — no real shell on iOS).
- A fresh `build.yml` run was also triggered this session (`34087240816`) as a
  redundant double-check before the pre-existing 09-06 run was found — it **also
  succeeded**, reproducing the same result. No new commit was needed for either rebuild;
  `main-yyjpt0`'s HEAD (`6a240d7`) hasn't changed.

**Next session's first move**: there is no pending/unverified build right now. Pick a
next concrete task from README's "Not done yet" list. In rough order of
CI-actionability (things that don't require a physical iPad or a Mac dev environment):
1. `ServerAgentHostManager: agent host failed to start Error: spawn EPERM` — **root
   cause located this session** (2026-09-07), not yet fixed. It's vscode's built-in AI
   chat/agent host ("Build with Agent" panel), not the extension host:
   `nodeAgentHostStarter.ts` → `ipc.cp.ts`'s `Client` does a real, unconditional
   `child_process.fork()` with no `_canSendSocket`-style escape hatch, and that file's
   `Client`/`Server` pair talk over `process.send`/`process.on('message')`, which a
   `worker_threads.Worker` doesn't have (only `parentPort.postMessage`) — so fixing this
   needs both sides of the protocol patched in lockstep, not just the launch call. See
   README's "Located (2026-09-07)" block (in the "extension host still doesn't
   actually start" section) for the full read of all three source files and why a
   patch should be scoped to `nodeAgentHostStarter.ts`'s call site specifically rather
   than `ipc.cp.ts` generally (that file is shared with the file watcher and pty host,
   both already broken here for unrelated reasons). Not attempted: no CI test exercises
   the agent host at all, so a patch here can only be verified by "does the build still
   compile," not by real behavior — decide deliberately whether that's good enough
   before writing it, rather than shipping it blind.
2. `experiment-sqlite3-ios.yml`'s stuck gyp-cache investigation (see README's "Not done
   yet" — real root cause found for `-fno-exceptions`/`-fno-rtti`, fix still elusive;
   five attempts at the `common.gypi`/`binding.gyp` source level have failed
   identically — next step is finding gyp's actual config cache location, not another
   attempt at the same two files).
3. Dynamic native menu bar / `nativeHost` channel work (README's "Not yet done" under
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
revisit that specific tradeoff.
