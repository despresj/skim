import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Reading Speed") {
                VStack(alignment: .leading, spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { Double(appState.wpm) },
                            set: { appState.wpm = UInt32($0) }
                        ),
                        in: 100...800,
                        step: 25
                    ) {
                        Text("Words per minute")
                    }

                    HStack {
                        Text("100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(appState.wpm) WPM")
                            .font(.headline)
                            .monospacedDigit()
                        Spacer()
                        Text("800")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Pause on punctuation", isOn: $appState.pauseOnPunctuation)
            }

            Section("Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow("Play/Pause", shortcut: "Space")
                    shortcutRow("Load Clipboard", shortcut: "⌘V")
                    shortcutRow("Speed Up", shortcut: "⌘+")
                    shortcutRow("Slow Down", shortcut: "⌘-")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 300)
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
