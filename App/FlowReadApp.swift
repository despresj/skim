import SwiftUI

@main
struct FlowReadApp: App {
    @State private var viewModel = ReaderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear { viewModel.loadClipboard() }
        }
    }
}
