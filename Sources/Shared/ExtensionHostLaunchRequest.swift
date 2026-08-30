import Foundation

/// The hand-off contract between NodeRuntimeExtension (which would normally
/// call `cp.fork()` to start the extension host, and can't) and
/// ExtensionHostRuntime (the process iOS launches instead). Written by the
/// former into the shared App Group container, read by the latter.
///
/// This mirrors the args/env `extensionHostConnection.ts` passes to
/// `cp.fork(FileAccess.asFileUri('bootstrap-fork').fsPath, args, opts)` on
/// every other platform — see project.yml's ExtensionHostRuntime comment
/// and README.md for why a real fork isn't available here.
struct ExtensionHostLaunchRequest: Codable {
    static let fileName = "exthost-launch-request.json"

    /// Absolute path to bootstrap-fork.js inside the shared vscode payload.
    let bootstrapForkPath: String
    /// e.g. ["--type=extensionHost", "--transformURIs", "--useHostProxy=false"]
    let args: [String]
    /// Includes whatever `writeExtHostConnection` set (the pipe name/socket
    /// marker) plus the rest of the environment `buildUserEnvironment`
    /// constructed.
    let env: [String: String]
}
