import SwiftUI

@main
struct SkimApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    AppStateHolder.shared.appState = appState
                    centerWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // File menu additions
            CommandGroup(after: .newItem) {
                Button("Open File...") {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Load Sample Text") {
                    appState.loadSampleText()
                }
                .keyboardShortcut("t", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(appState.recentTexts) { recent in
                        Button(recent.title) {
                            appState.loadFromRecent(recent)
                        }
                    }

                    if !appState.recentTexts.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            appState.clearRecentTexts()
                        }
                    }
                }
                .disabled(appState.recentTexts.isEmpty)
            }

            // Replace Edit menu paste
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    appState.loadFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Paste and Play") {
                    appState.loadAndPlay()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            // Playback Menu
            CommandMenu("Playback") {
                Button(appState.isPlaying ? "Pause" : "Play") {
                    appState.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(appState.state == .empty)

                Divider()

                Button("Previous Word") {
                    appState.skipBack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!appState.canGoBack)

                Button("Next Word") {
                    appState.skipForward()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!appState.canGoForward)

                Divider()

                Button("Previous Sentence") {
                    appState.previousSentence()
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(!appState.canGoBack)

                Button("Next Sentence") {
                    appState.nextSentence()
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(!appState.canGoForward)

                Divider()

                Button("Jump to Start") {
                    appState.jumpToStart()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(appState.state == .empty)

                Button("Jump to End") {
                    appState.jumpToEnd()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(appState.state == .empty)

                Divider()

                Button("Rewind 5 Seconds") {
                    appState.rewindSeconds(5.0)
                }
                .keyboardShortcut("r", modifiers: [])
                .disabled(appState.state == .empty)

                Button("Replay Sentence") {
                    appState.previousSentence()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.state == .empty)

                Divider()

                Button("Restart") {
                    appState.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.state == .empty)
            }

            // Speed Menu
            CommandMenu("Speed") {
                Button("Faster") {
                    appState.speedUp()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Slower") {
                    appState.slowDown()
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Comfortable (350 WPM)") {
                    appState.wpm = 350
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Brisk (450 WPM)") {
                    appState.wpm = 450
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Fast (600 WPM)") {
                    appState.wpm = 600
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                ForEach(SpeedPreset.allCases, id: \.rawValue) { preset in
                    Button(preset.label) {
                        appState.setPreset(preset)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private func centerWindow() {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.center()
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.loadFromFile(url)
        }
    }
}
