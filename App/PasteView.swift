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
    @State private var showingSettings = false

    /// Compact "time at default" estimate for the current draft, recomputed when the
    /// text settles. `nil` (pill hidden) until there's enough text to be meaningful.
    @State private var estimate: String?

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

                estimatePill
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
        // Reads is home; New Text is a create-flow reached from it. When we arrived
        // here from Reads, a "‹ Reads" button (the word, not a bare chevron, so the
        // model is learnable) sits in the natural back slot, top-left — and the gear
        // moves to the top-right so it never squats on the way back. On a cold launch
        // with no library, there's nothing behind New Text, so the button is absent.
        .overlay(alignment: .topLeading) {
            if viewModel.canReturnToReads {
                backToReads
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            SettingsGear { showingSettings = true }
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        // Keep the read-time estimate in step with the field. Synchronous and once
        // per actual edit (not per render), so the pill updates as you type/paste.
        .onChange(of: draft, initial: true) {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            estimate = trimmed.count >= 2 ? viewModel.readTimeEstimate(forText: draft) : nil
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

    // MARK: Back to Reads

    /// The escape hatch to home. Labelled "Reads" (not a lone chevron) so the user
    /// learns the mental model — Reads is where your reading life lives; this screen
    /// is just how a new read is born. Same quiet surface/hairline family as the gear.
    private var backToReads: some View {
        Button { viewModel.returnToReads() } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text("Reads")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color.readingMuted)
            .padding(.leading, 11)
            .padding(.trailing, 15)
            .frame(height: 40)
            .background(Color.readingSurface.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Reads")
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

    // MARK: Read-time estimate pill

    /// A small, quiet pill that answers "how long will this take?" the moment there's
    /// text to read — sitting in the calm bottom band the reading-hand picker used to
    /// occupy (that's a set-once preference, so it lives in Settings now, not on the
    /// launcher). Time, not word count, is the user-facing unit: a muted "Estimated
    /// read" label with the time itself in the warm accent. Premium and unobtrusive —
    /// never debug metadata — and absent entirely until the field has usable text.
    @ViewBuilder
    private var estimatePill: some View {
        if let estimate {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.readingMuted)
                (
                    Text("Estimated read  ·  ").foregroundColor(Color.readingMuted)
                    + Text(estimate).foregroundColor(Color.readingAccent)
                )
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.readingSurface.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: estimate)
        }
    }
}
