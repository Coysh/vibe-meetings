import SwiftUI
import AVFoundation

struct AudioPlaybackView: View {
    let audioURL: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playbackError: String?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 16) {
            if let audioURL {
                Text(audioURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if let error = playbackError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                HStack(spacing: 12) {
                    Button(isPlaying ? "Pause" : "Play") {
                        toggle(audioURL)
                    }
                    .buttonStyle(.borderedProminent)
                    if player != nil {
                        Button("Stop") {
                            stop()
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

    private func toggle(_ url: URL) {
        playbackError = nil
        if player == nil {
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            // Observe when playback reaches the end.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                isPlaying = false
            }
            // Observe item status to catch load errors.
            Task { @MainActor in
                // Give AVPlayer a moment to evaluate the item.
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

    private func stop() {
        player?.pause()
        player?.seek(to: .zero)
        player = nil
        isPlaying = false
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }
}
