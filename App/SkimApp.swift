import SwiftUI

@main
struct SkimApp: App {
    @State private var viewModel = ReaderViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                // Dev shortcut: `SKIM_SAMPLE` (set in the Xcode scheme or the
                // launch env) preloads sample prose instead of the clipboard, so
                // the reading surface can be opened without a copy step.
                .task {
                    if let sample = ProcessInfo.processInfo.environment["SKIM_SAMPLE"],
                       !sample.isEmpty {
                        viewModel.load(sample)
                    }
                }
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
