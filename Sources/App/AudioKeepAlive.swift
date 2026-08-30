import AVFoundation
import os

/// Keeps the app process alive indefinitely in the background by playing a
/// silent, looping audio clip through an active `AVAudioSession(.playback)`
/// — the one background mode that needs no special entitlement and works
/// on a free/Personal Team signing identity, unlike NEPacketTunnelProvider
/// (which Apple restricts to paid Apple Developer Program accounts — see
/// README.md for the architecture switch this is part of).
///
/// This is the same well-precedented technique other iOS dev-tool apps are
/// understood to use to keep a background server reachable (e.g. Pyto
/// running Python's `http.server`, reachable from Safari while
/// backgrounded). Apple's App Store review rejects apps that declare
/// `UIBackgroundModes: audio` without genuine audio playback — irrelevant
/// here since this app is sideload-only and never submitted for review.
///
/// Real limitations, stated plainly rather than glossed over:
///  - An audio interruption (phone call, another app taking audio focus,
///    the user stopping playback from Control Center) can suspend the
///    session; this does not automatically resume it. Not handled here.
///  - This is not an Apple-guaranteed persistence mechanism the way
///    NetworkExtension's process model was — it relies on how iOS
///    currently treats active audio sessions, which Apple could tighten in
///    a future OS version. Investigated and rejected alternatives
///    (`BGProcessingTask`, `BGContinuedProcessingTask`) don't support
///    open-ended background execution at all — see README.md.
@MainActor
final class AudioKeepAlive {
    static let shared = AudioKeepAlive()

    private let log = Logger(subsystem: "com.hecpdf.ipadvscode", category: "audiokeepalive")
    private var player: AVAudioPlayer?

    private init() {}

    /// Safe to call more than once — only the first call does anything.
    ///
    /// Failures here (a missing resource, or `AVAudioSession` activation
    /// being denied — the Simulator's audio session support is known to be
    /// limited, and interruptions can deny it on a real device too) are
    /// logged, not fatal: this is a background-persistence *enhancement*,
    /// not something the app's core foreground editing functionality
    /// depends on, so it must not crash the app if it fails. An earlier
    /// revision used `assertionFailure` here, which is a real trap in
    /// Debug builds — exactly the kind of build CI's Simulator smoke test
    /// runs — and did in fact crash the app on launch in CI.
    func start() {
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            log.error("silence.wav missing from app bundle — see Resources/ and project.yml")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            log.error("AudioKeepAlive failed to start: \(String(describing: error), privacy: .public)")
        }
    }
}
