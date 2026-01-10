import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Word display
            WordDisplayView(word: appState.currentWord)
                .frame(height: 60)

            // Progress
            ProgressView(value: Double(appState.progress))
                .progressViewStyle(.linear)

            // Word count
            if appState.hasText {
                Text("\(appState.currentWord?.index ?? 0 + 1) / \(appState.wordCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Controls
            ControlsView()

            Divider()

            // Actions
            HStack {
                Button("Load Clipboard") {
                    appState.loadFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command])

                Spacer()

                Text("\(appState.wpm) WPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 500, height: 300)
    }
}

struct WordDisplayView: View {
    let word: WordToken?

    var body: some View {
        Text(word?.text.toString() ?? "Copy text and press play")
            .font(.system(size: 32, weight: .medium, design: .rounded))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(word != nil ? .primary : .secondary)
            .frame(maxWidth: .infinity)
    }
}

struct ControlsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 24) {
            // Restart
            Button(action: appState.restart) {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasText)

            // Skip back
            Button(action: appState.skipBack) {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasText || appState.currentWord?.index == 0)

            // Play/Pause
            Button(action: appState.toggle) {
                Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasText)
            .keyboardShortcut(.space, modifiers: [])

            // Skip forward
            Button(action: appState.skipForward) {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasText || appState.isPlaying)

            // Speed controls
            HStack(spacing: 8) {
                Button("-") {
                    if appState.wpm > 100 {
                        appState.wpm -= 50
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("-", modifiers: [.command])

                Button("+") {
                    if appState.wpm < 800 {
                        appState.wpm += 50
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("=", modifiers: [.command])
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
