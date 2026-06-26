import SwiftUI

@main
struct SkimApp: App {
    @State private var viewModel: ReaderViewModel
    @State private var ideas: IdeasViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // One local SQLite store, shared by the reader (read records, resume), the
        // comprehension service, and the Ideas scratchpad. Opened once at launch;
        // `nil` if it fails, in which case all three run without persistence.
        let store = AppStore.open()
        let settings = AISettings()
        let service = ComprehensionService(
            store: store,
            keyStore: KeychainAPIKeyStore(),
            provider: OpenAIComprehensionProvider(),
            settings: settings)
        _viewModel = State(initialValue: ReaderViewModel(store: store, comprehension: service))
        _ideas = State(initialValue: IdeasViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, ideas: ideas)
                // Dev shortcut: `SKIM_SAMPLE` (set in the Xcode scheme or the
                // launch env) preloads sample prose instead of the clipboard, so
                // the reading surface can be opened without a copy step.
                .task {
                    if let sample = ProcessInfo.processInfo.environment["SKIM_SAMPLE"],
                       !sample.isEmpty {
                        viewModel.load(sample)
                    }
                }
                // The single delivery hook for inbound URLs — iOS routes cold
                // launch, already-running, and foreground-from-open all through
                // here. A `.txt` file opened into Skim (Shortcut / Action Button
                // / Share Sheet / Files) arrives as a file URL and carries the
                // full text; a `skim://read` deep link arrives by scheme.
                .onOpenURL { url in
                    if url.isFileURL {
                        viewModel.handleFileURL(url)
                    } else {
                        viewModel.handleDeepLink(url)
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
