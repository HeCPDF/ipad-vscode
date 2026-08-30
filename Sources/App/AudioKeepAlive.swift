import AVFoundation

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

    private var player: AVAudioPlayer?

    private init() {}

    /// Safe to call more than once — only the first call does anything.
    func start() {
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            assertionFailure("silence.wav missing from app bundle — see Resources/ and project.yml")
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
            assertionFailure("AudioKeepAlive failed to start: \(error)")
        }
    }
}
