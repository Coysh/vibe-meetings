import AVFoundation
import SwiftUI

/// Plays a meeting's audio. The file is opened as soon as the view appears, so
/// the duration and scrubber are there before the first press of Play.
struct AudioPlaybackView: View {
    let audioURL: URL?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playbackError: String?
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?

    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var speed: Double = 1

    private static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 12) {
            if audioURL != nil {
                if let error = playbackError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { currentTime }, set: { currentTime = $0; isSeeking = true }),
                        in: 0...max(duration, 1),
                        onEditingChanged: { editing in
                            if !editing {
                                player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                                isSeeking = false
                            }
                        }
                    )
                    .disabled(duration == 0)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")

                    HStack {
                        Text(formatTime(currentTime))
                        Spacer()
                        Text(duration > 0 ? formatTime(duration) : "–:––")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Button { skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .buttonStyle(.bordered)
                        .disabled(player == nil)
                        .help("Back 15 seconds")
                        .accessibilityLabel("Back 15 seconds")

                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player == nil)
                    .help(isPlaying ? "Pause (Space)" : "Play (Space)")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")

                    Button { skip(by: 15) } label: { Image(systemName: "goforward.15") }
                        .buttonStyle(.bordered)
                        .disabled(player == nil)
                        .help("Forward 15 seconds")
                        .accessibilityLabel("Forward 15 seconds")

                    Menu {
                        ForEach(Self.speeds, id: \.self) { s in
                            Button {
                                setSpeed(s)
                            } label: {
                                if s == speed { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                            }
                        }
                    } label: {
                        Text(speedLabel(speed)).monospacedDigit()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Playback speed")
                    .accessibilityLabel("Playback speed")
                }
            } else {
                ContentUnavailableView(
                    "No audio",
                    systemImage: "waveform.slash",
                    description: Text("This meeting has no audio recording.")
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: audioURL) { await prepare() }
        .onDisappear { teardown() }
    }

    // MARK: - Setup

    private func prepare() async {
        teardown()
        guard let url = audioURL else { return }
        playbackError = nil
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [self] _ in
            MainActor.assumeIsolated { isPlaying = false }
        }
        // 10 Hz for a smooth scrubber.
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [self] time in
            MainActor.assumeIsolated {
                guard !isSeeking else { return }
                currentTime = time.seconds
            }
        }
        player = p

        do {
            let loaded = try await item.asset.load(.duration, .isPlayable)
            guard loaded.1 else { throw CocoaError(.fileReadCorruptFile) }
            if loaded.0.isNumeric { duration = loaded.0.seconds }
        } catch {
            playbackError = "This audio file can't be played (\(error.localizedDescription))."
            player = nil
        }
    }

    // MARK: - Transport

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.defaultRate = Float(speed)
            player.play()
        }
        isPlaying.toggle()
    }

    private func skip(by seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, min(currentTime + seconds, duration)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
    }

    private func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        player?.defaultRate = Float(newSpeed)
        if isPlaying { player?.rate = Float(newSpeed) }
    }

    private func teardown() {
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }

    // MARK: - Formatting

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
