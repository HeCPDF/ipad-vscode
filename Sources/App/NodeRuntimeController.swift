import Foundation
import NodeMobile
import os

/// Owns code-server's Node runtime, running in-process (this is the App's
/// own process — not a NEPacketTunnelProvider extension). The real Node
/// extension host runs in-process too, inside code-server's own Node
/// instance via `worker_threads`, patched in the code-server fork's
/// `patches/ios-exthost-no-fork.diff` — nothing on the Swift side launches
/// it.
///
/// This replaces an earlier design using two NEPacketTunnelProvider
/// extensions purely as a way to get long-lived, independently-launchable
/// background processes. That needed
/// `com.apple.developer.networking.networkextension`, which Apple
/// restricts to paid Apple Developer Program accounts — a free/Personal
/// Team signing identity gets denied at runtime
/// (`NEVPNErrorDomain Code=5, "permission denied"`) no matter what the
/// entitlements file declares, confirmed against a real signed IPA.
/// Background persistence now instead comes from `AudioKeepAlive` (a
/// silent, looping `AVAudioSession(.playback)`), which needs no special
/// entitlement. See README.md for the full account of this switch.
@MainActor
final class NodeRuntimeController: ObservableObject {
    static let shared = NodeRuntimeController()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "com.hecpdf.ipadvscode", category: "noderuntime")
    private var started = false
    /// Every folder authorized this session, kept alive for the process's
    /// lifetime (not just the most recent one) — multi-root workspaces
    /// (CodeWorkspaceFile) need more than one simultaneously-accessible
    /// external folder, and there's no signal here for "VSCode is truly
    /// done with this folder" that would make it safe to release earlier.
    private var accessedSecurityScopedWorkspaces: [URL] = []

    private init() {}

    /// Starts the audio keep-alive and code-server's Node runtime. Safe to
    /// call more than once (e.g. scenePhase changes) — only the first call
    /// does anything.
    func start() async {
        guard !started else { return }
        started = true

        redirectStderrToFile()
        configureHomeEnvironment()
        AudioKeepAlive.shared.start()
        startNodeRuntime()
        // No IPC round trip to wait on anymore (everything is in-process) —
        // mark running once the background thread has been kicked off, the
        // same coarse-grained timing the previous NetworkExtension-based
        // implementation used (it also didn't wait for the HTTP server to
        // actually start accepting connections before reporting success).
        isRunning = true
    }

    /// Authorizes a folder picked via `UIDocumentPickerViewController` and
    /// returns its resolved path for `?folder=`/`?workspace=`. Trivial now
    /// that everything runs in one process — no more bookmark hand-off to a
    /// separate extension's sandbox.
    ///
    /// Also persists the bookmark (`WorkspaceSelection.store`) so
    /// `startNodeRuntime()`'s own `resolveBookmark` call can pre-authorize
    /// this same folder's security scope on the next launch, before
    /// code-server's own last-opened-folder mechanism tries to reopen it.
    /// Last authorized wins if more than one folder is authorized in a
    /// session (e.g. Add Folder to Workspace) — there's only one bookmark
    /// slot; extending this to remember every folder in a multi-root
    /// workspace is future work, not something this fixes.
    func authorizeWorkspace(_ url: URL) async throws -> String {
        guard url.startAccessingSecurityScopedResource() else {
            throw NodeRuntimeError.workspaceAuthorizationFailed("startAccessingSecurityScopedResource failed")
        }
        if !accessedSecurityScopedWorkspaces.contains(where: { $0.path == url.path }) {
            accessedSecurityScopedWorkspaces.append(url)
        }
        WorkspaceSelection.store(url: url, in: RuntimeConfig.privateStorageURL)
        return url.path
    }

    /// The actual, confirmed root cause of the real-device white-screen
    /// crash (obtained from node-stdio.log after making it retrievable via
    /// the Files app — see RuntimeConfig.diagnosticsURL/redirectStderrToFile
    /// below), which is why the sysdiagnose showed nothing amfid/codesign/
    /// JIT-related and why the crash reproduced identically with and
    /// without --jitless: code-server's very first startup step is
    /// `fs.mkdir(path.dirname(configPath), { recursive: true })` for
    /// `~/.config/code-server/config.yaml` (readConfigFile in
    /// src/node/cli.ts), and on a real device `os.homedir()`/`$HOME`
    /// resolves to this app's own Data container *root*
    /// (`/private/var/mobile/Containers/Data/Application/<uuid>/`) — which
    /// the iOS sandbox does not allow creating new directories in directly;
    /// only specific pre-existing subdirectories (Documents, Library, tmp)
    /// are actually writable. The `mkdir` throws `EPERM`, uncaught, and
    /// Node's default handler calls `process.exit(1)` — killing this whole
    /// embedded-in-process host app in well under a second, before UIKit
    /// renders a frame. (Simulator never hit this: Xcode's simulated
    /// container root is a plain, permissive directory under the Mac's own
    /// filesystem, not a real iOS sandbox boundary.)
    ///
    /// code-server derives its config/data/runtime paths from `xdg-basedir`
    /// / `env-paths` (see the real, cloned source's `src/node/util.ts`
    /// `getEnvPaths()`), which both honor the standard `XDG_*` environment
    /// variables ahead of any home-directory-derived default — and other
    /// code (cert generation, the extension host's own shell-environment
    /// resolution, anything calling `os.homedir()` directly) falls back to
    /// `$HOME` itself. Repointing both at somewhere actually writable
    /// (inside `RuntimeConfig.privateStorageURL`, already proven writable —
    /// the workspace bookmark lives there) fixes the whole class of "some
    /// library wants to create a dotfile under the home directory" failures
    /// in one place, rather than chasing down and passing a separate CLI
    /// flag for every individual consumer (`--user-data-dir` alone would
    /// have left `paths.config`'s own module-level `getEnvPaths()` call,
    /// evaluated once at import time before any CLI flag is parsed,
    /// pointed at the same broken path).
    private func configureHomeEnvironment() {
        let homeURL = RuntimeConfig.privateStorageURL.appendingPathComponent("home", isDirectory: true)
        let subdirs = [".config", ".local/share", ".cache", ".xdg-runtime"]
        try? FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        for subdir in subdirs {
            try? FileManager.default.createDirectory(
                at: homeURL.appendingPathComponent(subdir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        setenv("HOME", homeURL.path, 1)
        setenv("XDG_CONFIG_HOME", homeURL.appendingPathComponent(".config").path, 1)
        setenv("XDG_DATA_HOME", homeURL.appendingPathComponent(".local/share").path, 1)
        setenv("XDG_CACHE_HOME", homeURL.appendingPathComponent(".cache").path, 1)
        configureShortXdgRuntimeDir(homeURL.appendingPathComponent(".xdg-runtime"))
    }

    /// Fixes a real, confirmed bug found via an actual Simulator
    /// node-stdio.log (not guessed): every extension host connection
    /// failed with `Failed to start extension host process` /
    /// `listen EADDRINUSE`, on the very first attempt in a freshly
    /// created container -- a real collision was ruled out (a fresh
    /// UUID-suffixed name every time), and the real cause turned out to
    /// be Unix domain socket path length. `createRandomIPCHandle()`
    /// (vscode's own `vs/base/parts/ipc/node/ipc.net.ts`) builds
    /// `join(XDG_RUNTIME_DIR, "vscode-ipc-<uuid>.sock")`, which under
    /// this app's real container path came out to **270 characters** on
    /// Simulator (~194 estimated on a real device) -- both far past
    /// Darwin's `sockaddr_un.sun_path` limit of 104 bytes (103 usable +
    /// NUL). vscode's own code has length-safety logic for exactly this
    /// (truncating the random suffix via `safeIpcPathLengths`), but it
    /// wasn't taking effect for this embedded, non-`darwin`-reporting
    /// Node build for reasons not fully root-caused here (a `Platform`
    /// enum keying mismatch upstream in `vs/base/common/platform.ts`
    /// remains the leading hypothesis, but wasn't confirmed against the
    /// exact server-main.js bundle actually running) -- rather than
    /// depend on that, this sidesteps the length limit at the source:
    /// the app's own container path is unavoidably long (the `.../
    /// Containers/Data/Application/<uuid>/` prefix alone is already most
    /// of the 103-byte budget), so no absolute path under it can
    /// reliably stay short enough. `chdir()`ing this process into
    /// `.xdg-runtime` and exporting `XDG_RUNTIME_DIR="."` makes
    /// `createRandomIPCHandle()`'s `join(...)` produce a short
    /// *relative* path instead (`vscode-ipc-<uuid>.sock`, ~52 bytes) --
    /// the kernel resolves a relative `bind()` path against this
    /// process's actual (unrestricted-length) working directory, so the
    /// only string that has to fit in `sun_path` is the relative part.
    ///
    /// A process-wide `chdir()` is a real, deliberately-considered
    /// tradeoff: vscode's own file/workspace handling operates on
    /// absolute paths/URIs throughout, not `process.cwd()`-relative
    /// ones, so this isn't expected to affect anything else -- but
    /// stated plainly since it's a global side effect on the whole
    /// process, not a narrowly-scoped fix.
    private func configureShortXdgRuntimeDir(_ xdgRuntimeURL: URL) {
        guard FileManager.default.changeCurrentDirectoryPath(xdgRuntimeURL.path) else {
            // Fall back to the long absolute path rather than silently
            // running with an unset XDG_RUNTIME_DIR -- reproduces the
            // known EADDRINUSE bug above, but that's still better than
            // extension-host IPC having no runtime dir configured at all.
            setenv("XDG_RUNTIME_DIR", xdgRuntimeURL.path, 1)
            return
        }
        setenv("XDG_RUNTIME_DIR", ".", 1)
    }

    /// Node's own uncaught-exception handling prints to raw C stderr and
    /// then calls `process.exit()` — which, since Node is embedded as a
    /// library here rather than a real child process, terminates this
    /// entire host app, not just "the Node part". Confirmed on a real
    /// device via sysdiagnose, not assumed: a sideloaded launch's WKWebView
    /// fails to connect to 127.0.0.1:\(RuntimeConfig.loopbackPort) (-1004,
    /// server never came up / already gone), and ~100ms later launchd logs
    /// the whole host process as "exited due to exit(1)" -- a clean
    /// voluntary exit, not a signal, which is exactly why it leaves no
    /// .ips crash report and bounces to the home screen in well under a
    /// second. That output never reaches Xcode/CI either: `simctl
    /// launch`'s `--stdout`/`--stderr` capture flags are denied outright by
    /// this environment's `simctl` (`FBSOpenApplicationServiceErrorDomain`
    /// / `SBMainWorkspace`, reproduced repeatedly — a real tooling
    /// limitation, not our bug), and unified logging (`os.Logger`) only
    /// sees log calls that go through it, not raw stdio. Redirecting the
    /// C-level stderr/stdout streams to a file *inside this app's own
    /// sandbox* survives the process exiting, since it's a real file on
    /// disk — CI can pull it out afterward via `simctl get_app_container`,
    /// and on a real device it lands in RuntimeConfig.diagnosticsURL
    /// (Documents/Diagnostics, exposed to the Files app) specifically so it
    /// can be retrieved with nothing but the iPad itself: the crash is too
    /// fast (well under the time UIKit needs to show a single frame) for
    /// any on-screen log viewer to ever get a chance to run.
    private func redirectStderrToFile() {
        let logURL = RuntimeConfig.diagnosticsURL.appendingPathComponent("node-stdio.log")
        freopen(logURL.path, "w", stdout)
        freopen(logURL.path, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    /// `node_start` runs Node's event loop and does not return in normal
    /// operation, so it must never be called on the main thread.
    ///
    /// This launches code-server's real, unmodified entry point (the only
    /// things scripts/trim-code-server.sh removes are node-pty — a real iOS
    /// sandbox hard-wall, see that script — and node_modules/.bin symlinks,
    /// a Windows IPA-tooling compatibility fix unrelated to iOS) rather
    /// than the toy placeholder server. `--auth none` is a local default,
    /// not a feature removal: this process is unreachable from outside the
    /// device (127.0.0.1 loopback only, nothing forwards the port
    /// externally), so there is no one to authenticate against.
    ///
    /// No workspace path is passed on the command line — code-server
    /// starts with no folder open (its own "Editor Evolved" welcome page,
    /// matching real VSCode/code-server behavior) or reopens whatever it
    /// last had open via its own settings, exactly like the desktop app.
    ///
    /// If a workspace bookmark already exists (a folder picked in a
    /// previous session), it's still resolved and authorized here at
    /// startup — not to pass on the command line, but so the security
    /// scope is already active in case code-server's own last-opened-folder
    /// mechanism tries to reopen it.
    ///
    /// Not yet verified at runtime (no device/simulator in this pipeline)
    /// beyond what CI's Simulator smoke test covers — this is the entry
    /// point the real server SHOULD be started with per `src/node/cli.ts`,
    /// not something that has been observed to boot on a real device.
    private func startNodeRuntime() {
        let bundledEntry = Bundle.main.bundlePath + "/code-server/out/node/entry.js"
        let placeholderEntry = Bundle.main.path(forResource: "server", ofType: "js") ?? "server.js"
        let entryScript = FileManager.default.fileExists(atPath: bundledEntry) ? bundledEntry : placeholderEntry

        if let bookmarked = WorkspaceSelection.resolveBookmark(in: RuntimeConfig.privateStorageURL) {
            if bookmarked.startAccessingSecurityScopedResource() {
                accessedSecurityScopedWorkspaces.append(bookmarked)
            } else {
                log.error("startAccessingSecurityScopedResource failed for the previously-picked workspace folder")
            }
        }

        var arguments = [
            "node",
            "--max-old-space-size=256",
            entryScript,
        ]
        #if !targetEnvironment(simulator)
        // iOS denies third-party processes the ability to mark memory
        // pages executable at runtime (no dynamic-codesigning
        // entitlement -- Apple grants that only in narrow cases, not to
        // a free/Personal Team signing identity) unless the process is
        // CS_DEBUGGED (a live debugger attached), and per README.md's
        // "JIT: currently disabled" section, iOS 26+/TXM devices need
        // more than that (a live breakpoint-based allocation protocol, a
        // separate, not-yet-built V8 patch) -- so on a real device,
        // --jitless is still the safe default absent that patch. This
        // was never what caused the earlier white-screen crash (see
        // configureHomeEnvironment()'s doc comment) -- a real
        // sysdiagnose showed no amfid/codesign/JIT involvement, and the
        // crash reproduced identically with --jitless removed entirely.
        //
        // Simulator has none of these restrictions at all (Xcode's
        // simulated container is a plain, permissive process on the
        // Mac's own kernel, not a real iOS sandbox boundary -- same
        // reason configureHomeEnvironment()'s EPERM bug never reproduced
        // there) -- forcing --jitless there too would only make
        // Simulator-based verification less representative of what real
        // JIT-enabled V8 actually does, for no real benefit, so it's
        // conditional on a real device build instead of unconditional.
        arguments.insert("--jitless", at: 1)
        #else
        // Real bug found via an actual Simulator node-stdio.log (not
        // guessed): every extension host connection hit
        // "ReferenceError: WebAssembly is not defined" (from
        // @vscode/proxy-agent -> undici -> its own bundled
        // node:internal/deps/undici's lazy llhttp-via-WASM loader),
        // crashing the Worker even after the File/crypto polyfills
        // fixed the two bugs before it.
        //
        // Root cause, traced all the way to source rather than
        // guessed: nodejs-mobile's own iOS build script
        // (tools/ios_framework_prepare.sh, HeCPDF/nodejs-mobile fork)
        // passes `--v8-options=--jitless` to `configure` for every iOS
        // target -- device AND both Simulator archs alike. That becomes
        // node.gyp's `node_v8_options` variable, compiled in as the
        // `NODE_V8_OPTIONS` macro, applied via
        // `V8::SetFlagsFromString(NODE_V8_OPTIONS, ...)` in
        // `InitializeNodeWithArgs` (src/node.cc) *before*
        // `V8::SetFlagsFromCommandLine()` runs -- node.cc's own comment
        // there says this ordering is deliberate specifically so a
        // baked-in default flag CAN be overridden by passing its
        // negation on the actual CLI. And V8 itself documents exactly
        // why this manifests as a missing WebAssembly global:
        // `deps/v8/src/flags/flag-definitions.h` states outright
        // "--jitless also implies --no-expose-wasm, see
        // InitializeOncePerProcessImpl" -- jitless mode doesn't just
        // skip Turbofan/Sparkplug, it turns off exposing `WebAssembly`
        // entirely, since even baseline Wasm compilation needs some
        // code generation jitless mode refuses to do.
        //
        // So this app's own `--jitless`/no-`--jitless` choice above
        // (added for the *now-superseded* white-screen-crash
        // hypothesis, and left in as the real-device default) was
        // never actually the deciding factor on Simulator -- jitless
        // was already unconditionally baked into the binary itself,
        // regardless of what this Swift code passed on argv. Since V8
        // applies its own CLI-parsed flags after the baked-in
        // defaults, passing the negation explicitly here (a standard
        // V8 boolean-flag negation, confirmed accepted by
        // `deps/v8/src/flags/flags.cc`'s own `--no<flag>`/`--no-<flag>`
        // parsing) overrides jitless back off, restoring real JIT for
        // Simulator-based verification, without needing to rebuild
        // nodejs-mobile itself just to drop the build script's own
        // default.
        //
        // A second real bug found via re-verifying THIS fix in
        // Simulator: turning jitless off also brings `expose_wasm`
        // back to its own separate true default (flag-definitions.h:
        // `DEFINE_BOOL(expose_wasm, true, ...)`), and on this embedded
        // V8 build, actually using WebAssembly is fatal to the whole
        // process, not just one extension host Worker --
        // node-stdio.log captured a hard `node::Abort()` with `FATAL
        // ERROR: WasmCodeManager::Commit: Cannot make pre-reserved
        // region writable Allocation failed - process out of memory`,
        // the moment something (the same undici/llhttp WASM module
        // that used to just throw "WebAssembly is not defined")
        // actually tried to compile and run. That's strictly worse for
        // "no major bugs" than the contained, per-connection error it
        // replaced -- a full process abort kills the whole app, not
        // just one extension host connection attempt. `expose_wasm`
        // and `jitless` are independent flags (only a one-way
        // `DEFINE_NEG_IMPLICATION(jitless, ...)`-style default, not a
        // hard link), so `--no-expose-wasm` here keeps WebAssembly off
        // on its own while leaving real JIT for everything else
        // enabled -- deliberately reverting to the already-diagnosed,
        // contained "WebAssembly is not defined" extension-host-Worker
        // failure rather than shipping a fatal whole-process crash.
        // Whether nodejs-mobile's embedded V8 build can support
        // WebAssembly's memory-protection-toggling at all (a real
        // investigation, not attempted here) is now a separate,
        // explicitly-deferred gap, not a silently-accepted one.
        //
        // The real device path is left alone here (see the `--jitless`
        // branch above): whether to also stop baking
        // `--v8-options=--jitless` into the *device* build, now that
        // the JIT26/TXM `OS::SetPermissions` patch exists to gate real
        // allocation attempts, is a separate, higher-risk decision this
        // project isn't making blind on a device it can't test on.
        arguments.insert(contentsOf: ["--no-jitless", "--no-expose-wasm"], at: 1)
        #endif
        if entryScript == bundledEntry {
            arguments += [
                "--auth", "none",
                "--bind-addr", "127.0.0.1:\(RuntimeConfig.loopbackPort)",
                "--disable-telemetry",
                "--disable-update-check",
                // vscode's own resolveShellEnv() (server-main.js) spawns a
                // real shell (SHELL env var, falling back to os.userInfo()
                // .shell, falling back to a hardcoded "sh") to capture the
                // user's interactive-shell environment -- used by the
                // extension host, the pty host (integrated terminal), and
                // the agent host starter alike. iOS denies spawning
                // arbitrary child processes to third-party apps outright
                // (the same sandbox wall as cp.fork() elsewhere in this
                // project), so that spawn always fails with ENOENT,
                // confirmed via a real captured node-stdio.log: "Unable to
                // resolve your shell environment: A system error occurred
                // (spawn sh ENOENT)" -- which was taking the real extension
                // host down with it ("Failed to start extension host
                // process"), not just degrading gracefully.
                // force-disable-user-env is vscode's own server CLI flag
                // for skipping this step entirely (checked first, before
                // any spawn is attempted) -- code-server has no dedicated
                // flag for it, so pass it through via its existing
                // --vscode-option escape hatch (parseVscodeOptions in
                // src/node/cli.ts) rather than patching code-server itself.
                "--vscode-option", "force-disable-user-env",
                // Real bug found via the Simulator screenshot this
                // project's own bug-hunting captures (launch-*.png): the
                // Welcome page's big heading read "code-server" -- not a
                // rendering glitch, just code-server's own real, unmodified
                // upstream branding, since nothing here was overriding it.
                // Traced to source: gettingStarted.ts's
                // `$('h1.product-name.caption', {}, this.productService.nameLong)`
                // (the Welcome page's H1) reads `productService.nameLong`,
                // which code-server's own `app-name.diff` patch already
                // wires up to a `--app-name` CLI flag (setting
                // `nameShort`/`nameLong` in the per-request product
                // configuration `webClientServer.ts` injects into the web
                // client's bootstrap) -- that patch was already in this
                // project's patch series, just never actually invoked from
                // here. Matches the app's own project name (project.yml's
                // `name: iPadVSCode`), not left as the implementation
                // detail ("code-server") a user shouldn't need to know
                // about.
                "--app-name", "iPad VSCode",
            ]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if entryScript == bundledEntry {
                // Picked up by the ios-exthost-no-fork.diff patch in
                // extensionHostConnection.ts: runs the extension host in a
                // worker_threads.Worker within this same process instead of
                // cp.fork()'ing it — no shared-container TMPDIR hand-off
                // needed anymore, since there's only one process now.
                setenv("IPADVSCODE_NO_FORK", "1", 1)
            }
            var cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            cArgs.withUnsafeMutableBufferPointer { buffer in
                _ = node_start(Int32(buffer.count), buffer.baseAddress)
            }
        }
    }
}

enum NodeRuntimeError: Error {
    case workspaceAuthorizationFailed(String)
}
