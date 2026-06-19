import SwiftUI

@main
struct SkimApp: App {
    @State private var viewModel = ReaderViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        // Grab the clipboard on launch and every time the app comes forward,
        // so whatever you just copied is waiting for you the moment you switch in.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.loadClipboard()
            } else {
                // Leaving the foreground: stop advancing through unseen text.
                viewModel.pauseForBackground()
            }
        }
    }
}
