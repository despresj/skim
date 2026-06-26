import SwiftUI

/// The calm end-of-read screen. Reaching the final word shouldn't dump you on a
/// lone stranded word — it settles here: a quiet "Done", the full text back in a
/// readable scroll so you can review or reread by eye, and two thumb-range
/// actions. No celebration, no score; the same warm, dim reading-by-lamplight
/// surface as everywhere else.
struct ReviewView: View {
    let viewModel: ReaderViewModel

    @State private var showingCheck = false

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

    // MARK: Comprehension — an optional, de-emphasized affordance

    /// The check sits above the navigation actions but never wears the filled amber
    /// primary style — finishing a read is the moment; verifying the thread is an
    /// offer. Shown only when a check is possible for this read.
    @ViewBuilder
    private var comprehensionRow: some View {
        if let info = comprehensionAffordance {
            Button {
                showingCheck = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.readingAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Check understanding")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.readingForeground)
                        if let subtitle = checkSubtitle(for: info.status, readId: info.readId,
                                                        service: info.service) {
                            Text(subtitle)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.readingMuted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(ComprehensionPillStyle())
        }
    }

    /// Resolves the service/read/status once, returning `nil` when no check applies
    /// (AI off, too short, or no service) so the row simply doesn't render.
    private var comprehensionAffordance: (service: ComprehensionService, readId: String,
                                          status: ComprehensionStatus)? {
        guard let service = viewModel.comprehension, let readId = viewModel.currentReadId else { return nil }
        let status = service.status(forReadId: readId)
        guard status != .unavailable,
              QuestionPlan.initialQuestionCount(wordCount: viewModel.wordCount) > 0 else { return nil }
        return (service, readId, status)
    }

    /// The quiet context line under the label: generating / ready / not-yet count.
    /// Uses the real generated count when available, else the planned count.
    private func checkSubtitle(for status: ComprehensionStatus, readId: String,
                               service: ComprehensionService) -> String? {
        switch status {
        case .generating:
            return "Building check…"
        case .ready:
            let n = service.questionCount(forReadId: readId)
            return n <= 1 ? "1 question" : "\(n) questions ready"
        case .notStarted:
            let n = QuestionPlan.initialQuestionCount(wordCount: viewModel.wordCount)
            return n <= 1 ? "1 question" : "\(n) questions"
        case .answered:
            return "Reviewed"
        case .failed, .unavailable:
            return nil
        }
    }

    // MARK: Actions — two large thumb-range buttons

    private var actions: some View {
        VStack(spacing: 12) {
            comprehensionRow

            Button {
                viewModel.readAgain()
            } label: {
                Label("Read Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SecondaryPillStyle())

            Button {
                viewModel.openRecents()
            } label: {
                Label("Back to Recents", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(SecondaryPillStyle())
        }
        // Lift off the home indicator so the buttons sit in clean thumb range.
        .padding(.bottom, 8)
        .sheet(isPresented: $showingCheck) {
            if let service = viewModel.comprehension, let readId = viewModel.currentReadId {
                ComprehensionCheckView(
                    model: ComprehensionCheckViewModel(
                        service: service, settings: service.settingsForUI,
                        readId: readId, text: viewModel.reviewText, title: viewModel.currentTitle,
                        wordCount: viewModel.wordCount))
            }
        }
    }
}
