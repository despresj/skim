import SwiftUI

/// Routes between the paste screen (no text) and the reading surface.
struct ContentView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        Group {
            if viewModel.state == .idle {
                PasteView(viewModel: viewModel)
            } else {
                ReadingView(viewModel: viewModel)
            }
        }
        // Keep the reading screen lit while engaged with the thumb.
        .persistentSystemOverlays(.hidden)
    }
}
