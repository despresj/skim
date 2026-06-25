import SwiftUI

/// The calm end-of-read screen. Reaching the final word shouldn't dump you on a
/// lone stranded word — it settles here: a quiet "Done", the full text back in a
/// readable scroll so you can review or reread by eye, and two thumb-range
/// actions. No celebration, no score; the same warm, dim reading-by-lamplight
/// surface as everywhere else.
struct ReviewView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.horizontal, 28)

                fullText
                    .padding(.top, 18)

                actions
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: Header — a soft title and one clean metric line

    private var header: some View {
        VStack(spacing: 8) {
            Text("Done")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text(metaLine)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingMuted)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    /// Word count plus an honest read-time estimate at the speed it finished on —
    /// the only metadata clean enough to show without clutter.
    private var metaLine: String {
        let words = viewModel.wordCount
        let minutes = max(1, Int((Double(words) / Double(viewModel.wpm)).rounded()))
        return "\(words.formatted()) words  ·  ~\(minutes) min"
    }

    // MARK: Full text — readable, scrollable, paragraphs intact

    private var fullText: some View {
        ScrollView {
            Text(viewModel.reviewText)
                .font(.system(size: 19, weight: .regular, design: .rounded))
                .foregroundStyle(Color.readingForeground.opacity(0.92))
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
        // Dissolve the top edge so the prose melts up toward the header instead of
        // cutting hard across the scroll.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.045),
                    .init(color: .black, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Actions — two large thumb-range buttons

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.readAgain()
            } label: {
                Label("Read Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(PrimaryPillStyle())

            Button {
                viewModel.openRecents()
            } label: {
                Label("Back to Recents", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(SecondaryPillStyle())
        }
        // Lift off the home indicator so the buttons sit in clean thumb range.
        .padding(.bottom, 8)
    }
}
