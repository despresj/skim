import SwiftUI

/// Calm empty state, shown when the clipboard has no text. No accounts, no setup.
struct PasteView: View {
    let viewModel: ReaderViewModel
    @State private var draft = ""

    var body: some View {
        ZStack {
            Color.readingBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Copy text, then read it here")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .multilineTextAlignment(.center)

                Button {
                    viewModel.loadClipboard()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.headline)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.readingForeground)

                // Manual paste / type fallback.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .scrollContentBackground(.hidden)
                        .frame(height: 160)
                        .padding(8)
                        .background(Color.readingForeground.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 12))
                    if draft.isEmpty {
                        Text("…or paste / type here")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                Button("Start reading") {
                    viewModel.load(draft)
                }
                .buttonStyle(.bordered)
                .tint(Color.readingForeground)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(28)
        }
    }
}
