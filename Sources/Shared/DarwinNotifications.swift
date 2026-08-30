import Foundation

/// Darwin notification NodeRuntimeExtension posts when it has written an
/// ExtensionHostLaunchRequest into the shared App Group container and needs
/// the app to start ExtensionHostRuntime (extensions can't launch each other
/// directly — only the containing app can call `startVPNTunnel()`).
///
/// Darwin notifications cross process boundaries without an App Group
/// entitlement check, but iOS does NOT guarantee delivery to a suspended
/// app — this only reliably fires while the app is foreground or has just
/// backgrounded. That gap is unresolved; see README.md.
let exthostLaunchRequestNotificationName = "com.hecpdf.ipadvscode.exthost-launch-requested" as CFString
