import SwiftUI
import AVFoundation

struct AudioPlaybackView: View {
    let audioURL: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 16) {
            if let audioURL {
                Text(audioURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                Button(isPlaying ? "Pause" : "Play") {
                    toggle(audioURL)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No audio for this meeting.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ url: URL) {
        if player == nil { player = AVPlayer(url: url) }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }
}
