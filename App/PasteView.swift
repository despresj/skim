import SwiftUI

/// The calm empty state — shown only when nothing is loaded (a cold launch with
/// an empty clipboard, or after tapping "back" in the reader to go read something
/// else). Skim is clipboard-first: there's no form to fill in. Copy text anywhere
/// and it's waiting the moment you switch in; this screen just says so. The single
/// quiet "Check Clipboard" button covers the rare case where iOS withholds the
/// copied text until you explicitly ask for it.
struct PasteView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 12) {
                    Text("Skim")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(Color.readingMuted)

                    Text("Copy text, then open Skim")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                        .multilineTextAlignment(.center)

                    Text("Skim reads whatever text is on your clipboard.")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                        .multilineTextAlignment(.center)
                }

                // Quiet manual fallback. The real flow is automatic, so this is
                // deliberately small and outlined — never the headline action.
                Button("Check Clipboard") {
                    viewModel.pasteFromClipboard()
                }
                .buttonStyle(SecondaryPillStyle())
                .fixedSize(horizontal: true, vertical: false)

                Spacer()

                HandPicker(viewModel: viewModel)
            }
            .padding(28)
        }
    }
}

/// Sets which hand drives the thumb rail. Mirrors the whole reading surface —
/// rail, raised word, and speed control — to the chosen side. Set once; persists.
private struct HandPicker: View {
    let viewModel: ReaderViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Reading hand")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingMuted)
            Spacer()
            HStack(spacing: 4) {
                segment(title: "Left", isLeft: true)
                segment(title: "Right", isLeft: false)
            }
            .padding(3)
            .background(Color.readingSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        }
    }

    private func segment(title: String, isLeft: Bool) -> some View {
        let selected = viewModel.isLeftHanded == isLeft
        return Button {
            viewModel.isLeftHanded = isLeft
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.readingOnAccent : Color.readingMuted)
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background {
                    if selected { Capsule().fill(Color.readingAccent) }
                }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
