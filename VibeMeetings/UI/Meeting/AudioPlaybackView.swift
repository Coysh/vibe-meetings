import SwiftUI
import AVFoundation

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

    var body: some View {
        VStack(spacing: 12) {
            if let audioURL {
                Text(audioURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = playbackError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Scrubber
                if duration > 0 {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? currentTime : currentTime },
                                set: { newValue in
                                    isSeeking = true
                                    currentTime = newValue
                                }
                            ),
                            in: 0...max(duration, 1),
                            onEditingChanged: { editing in
                                if !editing {
                                    let target = CMTime(seconds: currentTime, preferredTimescale: 600)
                                    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                                    isSeeking = false
                                }
                            }
                        )

                        HStack {
                            Text(formatTime(currentTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTime(duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                // Transport controls
                HStack(spacing: 12) {
                    Button {
                        skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .buttonStyle(.bordered)
                    .disabled(player == nil)

                    Button {
                        toggle(audioURL)
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                    }
                    .buttonStyle(.bordered)
                    .disabled(player == nil)

                    if player != nil {
                        Button {
                            stop()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("No audio for this meeting.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            stop()
        }
    }

    // MARK: - Transport

    private func toggle(_ url: URL) {
        playbackError = nil
        if player == nil {
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)

            // Observe end of playback.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [self] _ in
                MainActor.assumeIsolated {
                    isPlaying = false
                }
            }

            // Periodic time observer at 10 Hz for smooth scrubber.
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
                MainActor.assumeIsolated {
                    guard !isSeeking else { return }
                    currentTime = time.seconds
                }
            }

            // Load duration asynchronously.
            Task { @MainActor in
                do {
                    let dur = try await item.asset.load(.duration)
                    if dur.isNumeric {
                        duration = dur.seconds
                    }
                } catch {
                    // Duration unavailable — scrubber stays hidden.
                }

                // Check for load errors.
                try? await Task.sleep(for: .milliseconds(200))
                if item.status == .failed, let err = item.error {
                    playbackError = "Cannot play audio: \(err.localizedDescription)"
                    isPlaying = false
                }
            }

            player = p
        }

        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }

    private func skip(by seconds: Double) {
        guard let player else { return }
        let target = CMTime(
            seconds: max(0, min(currentTime + seconds, duration)),
            preferredTimescale: 600
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
    }

    private func stop() {
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        player?.pause()
        player?.seek(to: .zero)
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
