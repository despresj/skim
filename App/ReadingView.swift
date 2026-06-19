import SwiftUI

/// The sacred reading surface. Almost nothing on screen: the current word,
/// a tiny progress line, and an invisible right-thumb control zone.
struct ReadingView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.readingBackground.ignoresSafeArea()

                centerContent

                VStack {
                    Spacer()
                    ProgressLine(progress: viewModel.progress)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }

                // Invisible right-thumb control surface (~38% width, full height).
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Color.clear
                        .frame(width: geo.size.width * 0.38)
                        .contentShape(Rectangle())
                        .gesture(holdGesture)
                }
            }
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if viewModel.state == .completed {
            CompletionView(viewModel: viewModel)
        } else {
            Text(viewModel.currentToken?.text ?? "")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(Color.readingForeground)
                .padding(.horizontal, 24)
                // Hold the baseline steady; no per-word animation/jitter.
                .animation(nil, value: viewModel.currentIndex)
        }
    }

    /// Continuous press: hold to read, release to pause.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in viewModel.startHolding() }
            .onEnded { _ in viewModel.stopHolding() }
    }
}

/// Subtle bottom progress line.
private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.readingForeground.opacity(0.08))
                Capsule()
                    .fill(Color.readingForeground.opacity(0.35))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 2)
    }
}

/// Shown at the end of the text.
private struct CompletionView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        VStack(spacing: 22) {
            Text("Done")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Button {
                viewModel.restart()
            } label: {
                Label("Read again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .tint(Color.readingForeground)
        }
    }
}
