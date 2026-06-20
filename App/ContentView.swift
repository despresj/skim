import SwiftUI

/// Routes between the paste screen (no text) and the reading surface.
struct ContentView: View {
    let viewModel: ReaderViewModel
    let ideas: IdeasViewModel

    var body: some View {
        Group {
            if viewModel.pendingLink != nil {
                LinkFallbackView(viewModel: viewModel)
            } else if let resume = viewModel.pendingResume, viewModel.state == .idle {
                ResumeView(viewModel: viewModel, candidate: resume)
            } else if viewModel.state == .idle {
                PasteView(viewModel: viewModel)
            } else if viewModel.state == .completed {
                ReviewView(viewModel: viewModel)
            } else {
                ReadingView(viewModel: viewModel, ideas: ideas)
            }
        }
        // Keep the reading screen lit while engaged with the thumb.
        .persistentSystemOverlays(.hidden)
    }
}
