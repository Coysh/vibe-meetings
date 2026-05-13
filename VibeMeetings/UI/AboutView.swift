import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("vibe-meetings")
                .font(.title.bold())

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                Text("This entire app is vibecoded. The developer is a PHP web developer who has never written Swift. Claude wrote every line of native macOS code — the audio pipeline, Core Audio tap, WhisperKit integration, the lot. If it works, that's the vibes. If it breaks, also the vibes.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Text("Records, transcribes, and summarises meetings 100% locally on your Mac. System audio and microphone are captured as separate streams, transcribed on-device via WhisperKit, and summarised by your own Ollama instance or OpenAI. No data ever leaves your Mac unless you opt in to OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Open Source Packages")
                    .font(.caption.bold())

                packageRow("WhisperKit", by: "Argmax", url: "https://github.com/argmaxinc/WhisperKit")
                packageRow("Sparkle", by: "Sparkle Project", url: "https://github.com/sparkle-project/Sparkle")
                packageRow("Swift Transformers", by: "Hugging Face", url: "https://github.com/huggingface/swift-transformers")
                packageRow("Swift Argument Parser", by: "Apple", url: "https://github.com/apple/swift-argument-parser")
                packageRow("Swift Crypto", by: "Apple", url: "https://github.com/apple/swift-crypto")
                packageRow("Swift Collections", by: "Apple", url: "https://github.com/apple/swift-collections")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Text("© 2026")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 420, height: 560)
    }

    @ViewBuilder
    private func packageRow(_ name: String, by author: String, url: String) -> some View {
        HStack(spacing: 4) {
            if let link = URL(string: url) {
                Link(name, destination: link)
                    .font(.caption)
            } else {
                Text(name)
                    .font(.caption)
            }
            Text("by \(author)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
