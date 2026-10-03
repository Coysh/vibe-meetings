import SwiftUI

/// First-run setup, shown once as a sheet over the main window: what the app
/// does, then each permission and download — explained before it is asked for.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stepIndex = 0

    private struct Step {
        let symbol: String
        let title: String
        let isRequired: Bool
    }

    private let steps: [Step] = [
        Step(symbol: "waveform", title: "Welcome to Vibe Meetings", isRequired: false),
        Step(symbol: "mic", title: "Your microphone", isRequired: true),
        Step(symbol: "speaker.wave.2", title: "The other people on the call", isRequired: true),
        Step(symbol: "arrow.down.circle", title: "Transcription model", isRequired: false),
        Step(symbol: "bell", title: "Calendar & notifications", isRequired: false),
        Step(symbol: "sparkles", title: "Summaries", isRequired: false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= stepIndex ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(height: 4)
                }
            }
            .padding([.horizontal, .top], 24)
            .accessibilityElement()
            .accessibilityLabel("Step \(stepIndex + 1) of \(steps.count)")

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: steps[stepIndex].symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(steps[stepIndex].title)
                    .font(.title2.bold())
                content
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()

            HStack {
                Button("Skip setup") { finish() }
                    .buttonStyle(.link)
                    .help("You can run setup again from Settings")
                Spacer()
                if stepIndex > 0 {
                    Button("Back") { stepIndex -= 1 }
                }
                if stepIndex < steps.count - 1 {
                    Button("Continue") { stepIndex += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start using Vibe Meetings") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch stepIndex {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text("Record your meetings, get a transcript, and a written summary — all processed on your Mac.")
                Label("Your voice and everyone else's, kept separate", systemImage: "person.2")
                Label("Starts from a calendar event, a notification or the menu bar", systemImage: "menubar.rectangle")
                Label("Nothing leaves your Mac unless you choose OpenAI for summaries", systemImage: "lock.shield")
                Text("A few quick steps first, so recording works the first time.")
                    .foregroundStyle(.secondary)
            }
        case 1: MicrophoneAccessStep()
        case 2: SystemAudioAccessStep()
        case 3: TranscriptionModelStep()
        case 4: CalendarAndNotificationsStep()
        default: SummaryEngineStep()
        }
    }

    private func finish() {
        env.hasCompletedOnboarding = true
    }
}
