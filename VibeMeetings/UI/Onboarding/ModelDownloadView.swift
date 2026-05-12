import SwiftUI
import VMCore
import VMTranscription

struct ModelDownloadView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var models: [TranscriptionModelInfo] = []
    @State private var loading = false
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcription model", systemImage: "arrow.down.circle").font(.title3.bold())

            if models.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                ForEach(models, id: \.id) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.displayName + (m.recommended ? "  (recommended)" : ""))
                            Text(byteCount(m.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if m.isDownloaded {
                            Label("Downloaded", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Download") {
                                Task { await downloadModel(id: m.id) }
                            }
                            .disabled(loading)
                        }
                    }
                }

                if loading {
                    ProgressView(value: progress)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .padding()
        .task { await refresh() }
    }

    private func refresh() async {
        models = (try? await env.activeTranscriptionEngine.availableModels()) ?? []
    }

    private func downloadModel(id: String) async {
        loading = true
        defer { loading = false }
        do {
            try await env.activeTranscriptionEngine.loadModel(id: id) { p in
                Task { @MainActor in
                    progress = p
                }
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
