import SwiftUI

/// The comprehension-check surface: a calm, one-question-at-a-time flow that ends
/// in a score and a gentle speed suggestion. Never punitive; a question can be
/// flagged "this seems off" so a bad item doesn't read as the reader's failure.
struct ComprehensionCheckView: View {
    @State var model: ComprehensionCheckViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ReadingCanvas()
            content.padding(24)
        }
        .presentationBackground { ReadingCanvas() }
        .task { if case .idle = model.phase { await model.start() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .generating: generating
        case .needsConsent:
            ComprehensionConsentView(
                onContinue: { Task { await model.acceptConsent() } },
                onCancel: { dismiss() })
        case .answering: answering
        case .complete: complete
        case .missingKey: message("Add an OpenAI API key to use comprehension checks.", primary: "Open Settings")
        case .failed(let e): message(e.userMessage, primary: "Try again")
        }
    }

    private var generating: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Color.readingAccent)
            Text("Building your check…")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text("Looking for the main thread, not trivia.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(Color.readingMuted)
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryPillStyle()).padding(.top, 8)
        }
    }

    @ViewBuilder private var answering: some View {
        if let q = model.currentQuestion, let check = model.check {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(model.currentIndex + 1) of \(check.questions.count)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                Text(q.question)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                ForEach(ChoiceKey.allCases, id: \.self) { key in
                    choiceButton(key, q: q)
                }
                if model.revealed { feedback(q) }
                Spacer(minLength: 0)
                if model.revealed {
                    Button(model.isLastQuestion ? "See result" : "Next") { model.next() }
                        .buttonStyle(PrimaryPillStyle())
                }
            }
        }
    }

    private func choiceButton(_ key: ChoiceKey, q: ComprehensionQuestion) -> some View {
        let chosen = model.selected[q.id]
        let isChosen = chosen == key
        let isCorrect = q.correctChoice == key
        let tint: Color = !model.revealed ? Color.readingSurface
            : isCorrect ? Color.green.opacity(0.25)
            : isChosen ? Color.red.opacity(0.20) : Color.readingSurface
        return Button { model.select(key) } label: {
            HStack {
                Text(q.choices.text(for: key))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(12)
            .background(tint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.revealed)
    }

    private func feedback(_ q: ComprehensionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selected[q.id] == q.correctChoice ? "Correct." : "Not quite.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text(q.explanation).font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.readingMuted)
            Text("From the passage: \u{201C}\(q.supportingQuote)\u{201D}")
                .font(.system(size: 13, design: .rounded)).italic()
                .foregroundStyle(Color.readingMuted)
            Button("This seems off") { model.flagCurrentDisputed() }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingAccent)
                .disabled(q.disputed)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var complete: some View {
        if let r = model.result {
            VStack(spacing: 16) {
                Text("\(r.correct) / \(r.scored)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readingForeground).monospacedDigit()
                Text(r.headline).font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text(r.guidance).font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.readingMuted).multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    if model.canGenerateMore {
                        Button("Generate more") { Task { await model.generateMore() } }
                            .buttonStyle(SecondaryPillStyle())
                    }
                    Button("Done") { dismiss() }.buttonStyle(PrimaryPillStyle())
                }
                .padding(.top, 8)
            }
        }
    }

    private func message(_ text: String, primary: String) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.system(size: 15, design: .rounded))
                .foregroundStyle(Color.readingForeground).multilineTextAlignment(.center)
            Button(primary) {
                if case .failed = model.phase { Task { await model.retry() } } else { dismiss() }
            }.buttonStyle(PrimaryPillStyle())
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryPillStyle())
        }
    }
}
