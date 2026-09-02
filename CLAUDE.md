# CLAUDE.md — session handoff

Read this first. `README.md` has the full narrative history (every bug found and fixed, with source citations) — this file is the short "what's the state right now, what do I do next" pointer into it. Update this file at the end of any session that changes the architecture, not just README.

## Current goal (as of 2026-09-02)

Switch the app's server payload from `HeCPDF/code-server` (Coder's fork) to
building `vscode-reh-web` straight from official `microsoft/vscode` source,
keep the existing nodejs-mobile-in-process architecture, minimize
remote-authority UI traces (Settings editor's "Remote" tab, status bar).

The earlier "real Electron desktop bundle in WKWebView" pivot
(`NativeWorkbenchExperimentView.swift`) is **abandoned for good** — iOS
cannot host a real Electron/Chromium main process, full stop, not a
tooling gap. See README's "Electron-desktop pivot ... is abandoned" section
before ever reconsidering that direction.

## Where things actually stand — CHECK THIS FIRST

The last thing done this session was pushing a fix for a real crash found
via actual Simulator evidence, and triggering a rebuild. **That rebuild's
result was never observed** — the session was stopped by the user before
it finished. Next session's first move should be:

1. Check `vscode-reh-web-build.yml` run `33641059792`
   (https://github.com/HeCPDF/ipad-vscode/actions/runs/33641059792) — was
   still `in_progress` as of 2026-09-02T14:26:34Z, ~9 min into a build that
   normally takes ~12-13 min. Check whether it succeeded or failed.
   - If it failed: pull the job logs, diagnose for real (don't guess),
     fix, commit, push. This is a normal vscode gulp build off official
     source at a pinned commit — code-server's own CI builds the same
     target successfully, so a failure here is almost certainly this
     project's own patch/script issue, not upstream.
   - If it succeeded: continue to step 2.
2. Trigger `build.yml` (`workflow_dispatch`, branch `main-yyjpt0`) to
   compile the full app against the new artifact.
3. `workflow_run` auto-triggering of `simulator-test.yml` from `build.yml`
   **does not actually work on this branch** (confirmed empirically —
   23+ historical runs were all manual `workflow_dispatch`, likely because
   the trigger definition needs to live on the repo's default branch,
   which isn't `main-yyjpt0`). After `build.yml` finishes, manually
   trigger `simulator-test.yml` yourself with `workflow_dispatch`, passing
   `run_id: "<the build.yml run id>"`.
4. Once `simulator-test.yml` completes, **download and actually read the
   `simulator-test-results` artifact** — don't trust a green checkmark.
   `node-stdio-1-pre-uitest.log` / `node-stdio-1-post-uitest.log` are
   where `NodeRuntimeController`'s Node process output lands; that's where
   you'll see whether `server-main.js` actually started and bound to the
   loopback port, or crashed again. The `uitest-screenshot-1-*.png` series
   shows what the WKWebView actually rendered.

## What's already fixed and verified this session (don't redo)

- `vscode-reh-web-build.yml` run 4 (`33593159098`) succeeded and its
  artifact was **directly downloaded and inspected**: `out/server-main.js`
  present, `product.json` confirmed stock `"Code - OSS"` identity (no
  rebrand — the user explicitly asked for vscode's own real identity, not
  a custom "iPad VSCode" name), `node-pty` removed, zero `"coder"` strings
  anywhere.
- `build.yml` run `33594091357` compiled the full app successfully against
  that artifact (both device and Simulator targets) — `NodeRuntimeController.swift`'s
  new code compiles clean.
- `simulator-test.yml` run `33594380400` actually ran the app in Simulator
  and **crashed** — real evidence pulled from the artifact's
  `node-stdio-1-pre-uitest.log`: `ReferenceError: require is not defined
  in ES module scope`. Root cause: vscode's `server-main.js` ships as an
  ES module (`"type": "module"` in its `package.json`), but
  `scripts/trim-vscode-reh-web.sh`'s crypto polyfill shim (copied from
  `trim-code-server.sh`, which targets a CommonJS file) used
  `require("crypto")`. Fixed in commit `73cdff1`:
  `(await import("node:crypto")).webcrypto` instead — valid at the top of
  an ES module via top-level await. Verified the syntax locally with a
  throwaway Node script before pushing (see commit message).
- `ios-remote-label.diff` (commit `d0c972b`) registers a `LabelService`
  formatter so the Settings editor's Remote tab and the status-bar remote
  indicator show "This iPad" instead of the raw `127.0.0.1:8482` loopback
  string. This is a label-only fix — it does **not**, and by design
  *cannot*, remove the Settings editor's User/Remote split itself (that's
  gated on `remoteAuthority` being set at all, which vscode-web's own
  `workbench.ts` does unconditionally for every web connection — not
  something a patch should touch; see README for why this was a
  deliberate stop-here decision, same risk judgment that ended the
  Electron path). **Not yet verified in a real Simulator run** — no
  screenshot has ever shown the Settings editor open with this build.

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

## Known, permanent ceilings — not bugs, don't try to "fix" these

Discussed explicitly with the user; worth restating so a future session
doesn't burn time on them:

- **No integrated terminal.** `node-pty` needs a real kernel pty
  (`/dev/ptmx`); iOS denies that to third-party sandboxed apps, same as it
  denies `fork()`. No known workaround short of jailbreak.
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
