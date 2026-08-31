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

    /// Node's own uncaught-exception handling prints to raw C stderr and
    /// then calls `process.exit()` — which, since Node is embedded as a
    /// library here rather than a real child process, terminates this
    /// entire host app, not just "the Node part". That output never
    /// reaches Xcode/CI: `simctl launch`'s `--stdout`/`--stderr` capture
    /// flags are denied outright by this environment's `simctl`
    /// (`FBSOpenApplicationServiceErrorDomain` / `SBMainWorkspace`,
    /// reproduced repeatedly — a real tooling limitation, not our bug),
    /// and unified logging (`os.Logger`) only sees log calls that go
    /// through it, not raw stdio. Redirecting the C-level stderr/stdout
    /// streams to a file *inside this app's own sandbox* survives the
    /// process exiting, since it's a real file on disk — CI can pull it
    /// out afterward via `simctl get_app_container` even though the
    /// process that wrote it is gone.
    private func redirectStderrToFile() {
        let logURL = RuntimeConfig.privateStorageURL.appendingPathComponent("node-stdio.log")
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
            // iOS denies third-party processes the ability to mark memory
            // pages executable at runtime (no dynamic-codesigning
            // entitlement -- Apple grants that only in narrow cases, not
            // to a free/Personal Team signing identity) unless the
            // process is CS_DEBUGGED (a live debugger attached). V8's
            // default JIT compiles and then executes machine code from
            // freshly-allocated pages, which needs exactly that. Confirmed
            // as the real cause of a reported crash, not assumed: a
            // normally-sideloaded build white-screens and is killed
            // moments after launch on a real device, while the same build
            // run indirectly inside LiveContainer (which arranges JIT
            // access for its guest apps) works -- and CI's Simulator,
            // which doesn't enforce this restriction on real iOS hardware
            // at all, was never able to catch this since it isn't real
            // codesigning enforcement. --jitless runs V8 in pure
            // interpreter mode (no executable-page allocation at all), at
            // a real performance cost, but works under a plain signing
            // identity with no debugger attached and no special
            // entitlement -- the actual sideload story for this app.
            "--jitless",
            "--max-old-space-size=256",
            entryScript,
        ]
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
