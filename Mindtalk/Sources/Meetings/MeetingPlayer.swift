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

    private var player: AVAudioPlayer?
    private var ticker: AnyCancellable?

    /// Plays `id`'s recording from a little before `seconds`.
    func play(_ id: UUID, from seconds: Double) {
        if meeting != id || player == nil {
            stop()
            guard let p = try? AVAudioPlayer(contentsOf: MeetingStore.audioURL(for: id)) else { return }
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
        if player.isPlaying { player.pause() } else { player.play() }
        tick()
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
        if !player.isPlaying, player.currentTime <= 0.01 || player.currentTime >= player.duration - 0.05 { stop() }
    }
}
