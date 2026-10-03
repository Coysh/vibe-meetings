import SwiftUI
import VMCore
import VMTranscription

/// Onboarding step: download the speech-to-text model, so the first recording
/// doesn't have to. Shows real progress, and a clear error if it fails.
struct TranscriptionModelStep: View {
    @Environment(AppEnvironment.self) private var env
    @State private var models: [TranscriptionModelInfo] = []
    @State private var loadError: String?
    @State private var downloadingID: String?
    @State private var progress: Double = 0
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription runs entirely on your Mac using a speech model. Bigger models are more accurate but take longer to download and use more memory.")
                .foregroundStyle(.secondary)

            if let loadError {
                Label("Couldn't list the models: \(loadError)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await refresh() } }
            } else if models.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                ForEach(models, id: \.id) { model in
                    row(model)
                }
                if let downloadError {
                    Text(downloadError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { await refresh() }
    }

    private func row(_ model: TranscriptionModelInfo) -> some View {
        let selected = env.selectedModelId == model.id
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName.capitalized + (model.recommended ? "  · recommended" : ""))
                Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingID == model.id {
                ProgressView(value: progress).frame(width: 110)
                Text("\(Int(progress * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if model.isDownloaded {
                if selected {
                    Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button("Use this") { env.selectTranscriptionModel(model.id) }
                }
            } else {
                Button("Download") { Task { await download(model.id) } }
                    .disabled(downloadingID != nil)
            }
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func refresh() async {
        do {
            models = try await env.activeTranscriptionEngine.availableModels()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func download(_ id: String) async {
        downloadingID = id
        progress = 0
        downloadError = nil
        defer { downloadingID = nil }
        do {
            try await env.activeTranscriptionEngine.loadModel(id: id) { p in
                Task { @MainActor in progress = p }
            }
            await refresh()
            env.selectTranscriptionModel(id)
        } catch {
            downloadError = "Download failed: \(error.localizedDescription)"
        }
    }
}
