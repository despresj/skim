import SwiftUI

/// The calm entry surface — shown when nothing is loaded (a cold launch with an
/// empty clipboard, or after backing out of the reader to read something else).
///
/// Skim is clipboard-first and immediate: copied text is picked up automatically
/// the moment you switch in (see `ReaderViewModel.loadClipboard`), dropping you
/// straight into the reader with no button to press. This screen is the fallback
/// for when there's nothing on the clipboard yet — so it leads with the one thing
/// it needs: a place to put text. Type or paste into the field and, after a short
/// settle, Skim begins on its own. No "Start Reading", no hero "Paste" button; the
/// field *is* the door. A quiet "Use clipboard" link covers the rare case where
/// iOS withheld the copied text from the automatic read.
struct PasteView: View {
    let viewModel: ReaderViewModel

    /// What the user has typed or pasted. When it settles into usable text, the
    /// reader loads it automatically (see the debounce in `.task` below).
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                // Content rides above center — a confident, premium upper third
                // rather than a debug screen floating in dead space.
                Spacer(minLength: 24)

                header

                inputField
                    .padding(.top, 28)

                useClipboard
                    .padding(.top, 14)

                // Twice the slack below the content as above pins it high.
                Spacer(minLength: 24)
                Spacer(minLength: 24)

                settingsTray
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
        // Debounced auto-start: each keystroke/paste restarts this task, so we
        // only commit once the text has settled (~400ms). Pasted articles clear
        // the threshold instantly and begin a beat later; it never feels jumpy.
        .task(id: draft) {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            viewModel.load(draft)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            Text("Skim")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(4)
                .foregroundStyle(Color.readingMuted)

            Text("Read faster without losing the thread.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Text("Paste text or copy something before opening Skim. We’ll take it from there.")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(Color.readingMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Input

    /// The hero. A soft, generous text well — the obvious thing to act on. Typing
    /// or pasting here is the whole interaction; there's no submit.
    private var inputField: some View {
        TextEditor(text: $draft)
            .focused($fieldFocused)
            .font(.system(size: 18, weight: .regular, design: .rounded))
            .foregroundStyle(Color.readingForeground)
            .tint(Color.readingAccent)
            .scrollContentBackground(.hidden)
            // A fixed launch-pad height — short enough to read as "drop text and
            // go", not an editor slab. TextEditor is greedy, so this caps it
            // outright; longer pastes simply scroll within.
            .frame(height: 150)
            .padding(16)
            .background(Color.readingSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(fieldFocused ? Color.readingAccent.opacity(0.5) : Color.readingBorder,
                            lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                // TextEditor has no native placeholder; align this to where its
                // text actually begins (outer padding + the editor's own inset).
                if draft.isEmpty {
                    Text("Paste anything here…")
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                        .padding(.leading, 21)
                        .padding(.top, 24)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.18), value: fieldFocused)
    }

    /// Quiet fallback for when iOS withheld the clipboard from the automatic read
    /// — deliberately a plain muted link, never a hero button.
    private var useClipboard: some View {
        Button("Use clipboard") {
            viewModel.pasteFromClipboard()
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(Color.readingMuted)
        .buttonStyle(.plain)
    }

    // MARK: Settings tray

    /// A calm bottom tray for set-once preferences, sitting under a hairline so it
    /// reads as settings rather than part of the entry flow.
    private var settingsTray: some View {
        HandPicker(viewModel: viewModel)
            .padding(.top, 18)
            .padding(.horizontal, 4)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.readingBorder)
                    .frame(height: 1)
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
                .font(.system(size: 15, weight: .medium, design: .rounded))
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
