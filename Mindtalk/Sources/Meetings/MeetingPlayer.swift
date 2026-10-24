import AppKit
import AVFoundation
import Combine

/// Plays a meeting's recording from a moment — to hear what was really said.
@MainActor
final class MeetingPlayer: ObservableObject {
    static let shared = MeetingPlayer()

    @Published private(set) var meeting: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    /// 1×, 1.5× or 2× — meetings are often heard back faster.
    @Published private(set) var rate: Float = 1

    private var player: AVAudioPlayer?
    private var ticker: AnyCancellable?

    /// Plays `id`'s recording from a little before `seconds`.
    func play(_ id: UUID, from seconds: Double) {
        // A meeting being recorded has the microphone: nothing plays into it.
        // (No beep either: it could play into a Bluetooth headset and cost its mic.)
        guard !MeetingSession.shared.isRecording else { return }
        if meeting != id || player == nil {
            stop()
            guard let p = try? AVAudioPlayer(contentsOf: MeetingStore.audioURL(for: id)) else { return }
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            player = p
            meeting = id
            duration = p.duration
        }
        guard let player else { return }
        player.currentTime = max(0, seconds - 0.4)
        player.play()
        isPlaying = true
        tick()
        ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            ticker = nil          // paused: nothing to follow
        } else {
            guard !MeetingSession.shared.isRecording else { return }
            player.play()
            ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        }
        tick()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        tick()
    }

    func skip(_ seconds: Double) { seek(to: time + seconds) }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        ticker = nil
        meeting = nil
        isPlaying = false
        time = 0
    }

    private func tick() {
        guard let player else { return }
        time = player.currentTime
        isPlaying = player.isPlaying
        // Played to the end (the player goes back to 0:00 by itself then). Paused and
        // skipped back to 0:00 by hand, the bar stays.
        if ticker != nil, !player.isPlaying, player.currentTime <= 0.01 || player.currentTime >= player.duration - 0.05 { stop() }
    }
}
