import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingShortcut: ShortcutAction?
    @State private var showingTomlEditor = false

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

            Section("Punctuation Pauses") {
                Picker("Preset", selection: $appState.punctuationPreset) {
                    ForEach(PunctuationPreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.punctuationPreset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show review trail", isOn: $appState.showReviewTrail)

                HStack {
                    Text("Font scale")
                    Slider(
                        value: $appState.fontScale,
                        in: 0.5...2.0,
                        step: 0.1
                    )
                    Text(String(format: "%.1fx", appState.fontScale))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.green)
                        Text("All text is processed locally on your Mac")
                    }
                    .font(.callout)

                    Text("Your reading data never leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Recent Texts", role: .destructive) {
                    appState.clearRecentTexts()
                }
            }

            Section("Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 8) {
                    editableShortcutRow("Play/Pause", action: .playPause, shortcut: appState.shortcuts.playPause)
                    editableShortcutRow("Load Clipboard", action: .loadClipboard, shortcut: appState.shortcuts.loadClipboard)
                    editableShortcutRow("Load & Play", action: .loadAndPlay, shortcut: appState.shortcuts.loadAndPlay)
                    editableShortcutRow("Speed Up", action: .speedUp, shortcut: appState.shortcuts.speedUp)
                    editableShortcutRow("Slow Down", action: .slowDown, shortcut: appState.shortcuts.slowDown)
                }

                Button("Reset to Defaults") {
                    appState.shortcuts = .defaults
                }
                .font(.caption)
            }

            Section("Advanced") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Config File")
                        if let path = get_config_path()?.toString() {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button("Edit TOML") {
                        showingTomlEditor = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 650)
        .sheet(item: $editingShortcut) { action in
            ShortcutRecorderView(
                action: action,
                currentShortcut: shortcut(for: action),
                onSave: { newShortcut in
                    updateShortcut(action: action, shortcut: newShortcut)
                    editingShortcut = nil
                },
                onCancel: { editingShortcut = nil }
            )
        }
        .sheet(isPresented: $showingTomlEditor) {
            TomlEditorView(appState: appState)
        }
    }

    private func editableShortcutRow(_ label: String, action: ShortcutAction, shortcut: AppKeyboardShortcut) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button(shortcut.displayString) {
                editingShortcut = action
            }
            .buttonStyle(.bordered)
            .font(.system(.body, design: .monospaced))
        }
    }

    private func shortcut(for action: ShortcutAction) -> AppKeyboardShortcut {
        switch action {
        case .playPause: return appState.shortcuts.playPause
        case .loadClipboard: return appState.shortcuts.loadClipboard
        case .loadAndPlay: return appState.shortcuts.loadAndPlay
        case .speedUp: return appState.shortcuts.speedUp
        case .slowDown: return appState.shortcuts.slowDown
        }
    }

    private func updateShortcut(action: ShortcutAction, shortcut: AppKeyboardShortcut) {
        var shortcuts = appState.shortcuts
        switch action {
        case .playPause: shortcuts.playPause = shortcut
        case .loadClipboard: shortcuts.loadClipboard = shortcut
        case .loadAndPlay: shortcuts.loadAndPlay = shortcut
        case .speedUp: shortcuts.speedUp = shortcut
        case .slowDown: shortcuts.slowDown = shortcut
        }
        appState.shortcuts = shortcuts
    }
}

enum ShortcutAction: String, Identifiable {
    case playPause, loadClipboard, loadAndPlay, speedUp, slowDown
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playPause: return "Play/Pause"
        case .loadClipboard: return "Load Clipboard"
        case .loadAndPlay: return "Load & Play"
        case .speedUp: return "Speed Up"
        case .slowDown: return "Slow Down"
        }
    }
}

struct ShortcutRecorderView: View {
    let action: ShortcutAction
    let currentShortcut: AppKeyboardShortcut
    let onSave: (AppKeyboardShortcut) -> Void
    let onCancel: () -> Void

    @State private var key: String
    @State private var useCommand: Bool
    @State private var useShift: Bool
    @State private var useOption: Bool
    @State private var isRecording = false

    init(action: ShortcutAction, currentShortcut: AppKeyboardShortcut, onSave: @escaping (AppKeyboardShortcut) -> Void, onCancel: @escaping () -> Void) {
        self.action = action
        self.currentShortcut = currentShortcut
        self.onSave = onSave
        self.onCancel = onCancel
        _key = State(initialValue: currentShortcut.key)
        _useCommand = State(initialValue: currentShortcut.useCommand)
        _useShift = State(initialValue: currentShortcut.useShift)
        _useOption = State(initialValue: currentShortcut.useOption)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Shortcut: \(action.displayName)")
                .font(.headline)

            // Current shortcut display
            Text(previewShortcut.displayString)
                .font(.system(size: 24, design: .monospaced))
                .padding()
                .frame(minWidth: 100)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

            // Modifier toggles
            HStack(spacing: 16) {
                Toggle("⌘", isOn: $useCommand)
                    .toggleStyle(.button)
                Toggle("⌥", isOn: $useOption)
                    .toggleStyle(.button)
                Toggle("⇧", isOn: $useShift)
                    .toggleStyle(.button)
            }

            // Key input
            HStack {
                Text("Key:")
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onChange(of: key) { _, newValue in
                        if newValue.count > 1 {
                            key = String(newValue.suffix(1))
                        }
                    }
            }

            Text("Enter a single character (e.g., L, V, Space)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Button("Save") {
                    onSave(previewShortcut)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(key.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    private var previewShortcut: AppKeyboardShortcut {
        AppKeyboardShortcut(key: key.isEmpty ? " " : key, useCommand: useCommand, useShift: useShift, useOption: useOption)
    }
}

struct TomlEditorView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tomlContent: String = ""
    @State private var errorMessage: String?
    @State private var hasChanges = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Config (TOML)")
                    .font(.headline)
                Spacer()
                if let path = get_config_path()?.toString() {
                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
            .padding()

            Divider()

            // Editor
            TextEditor(text: $tomlContent)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .onChange(of: tomlContent) { _, _ in
                    hasChanges = true
                    errorMessage = nil
                }

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Reload") {
                    loadToml()
                }

                Button("Save") {
                    saveToml()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding()
        }
        .frame(width: 450, height: 400)
        .onAppear {
            loadToml()
        }
    }

    private func loadToml() {
        if let content = read_config_toml()?.toString() {
            tomlContent = content
        } else {
            // Default template if no config exists
            tomlContent = """
            # SpeedReader Configuration

            [window]
            width = 500
            height = 300

            [playback]
            wpm = 300
            """
        }
        hasChanges = false
        errorMessage = nil
    }

    private func saveToml() {
        if write_config_toml(tomlContent) {
            hasChanges = false
            errorMessage = nil
            // Reload config in app state
            let config = load_config()
            appState.windowWidth = CGFloat(config.window_width)
            appState.windowHeight = CGFloat(config.window_height)
            appState.wpm = config.wpm
        } else {
            errorMessage = "Failed to save config file"
        }
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(AppState())
}
#endif
