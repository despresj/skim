import SwiftUI

@main
struct SpeedReaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Speed Reader", systemImage: "text.word.spacing") {
            ContentView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
