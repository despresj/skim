import SwiftUI

/// The Ideas scratchpad: a calm sheet for jotting improvement ideas, bugs, and
/// friction noticed while actually reading. Same warm reading-by-lamplight
/// surface as the rest of Skim — input at the top so a thought lands in one tap
/// and a keystroke, the running list of open ideas below, newest first. Not a
/// project tool: add, glance, check off, or swipe away. Private and local.
struct IdeasView: View {
    let ideas: IdeasViewModel
    /// Pulled fresh at save time so an idea captures the exact reading position,
    /// speed, and surrounding words live when it was written.
    let capture: () -> IdeaCapture

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                header
                inputRow
                Divider().overlay(Color.readingBorder)
                list
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground { ReadingCanvas() }
        .onAppear {
            ideas.reload()
            // Open ready to capture — the whole point is speed.
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Ideas")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingAccent)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: Input — top, autofocused, instant

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("Add idea…", text: $draft, axis: .vertical)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(Color.readingForeground)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.done)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSave ? Color.readingAccent : Color.readingMuted.opacity(0.5))
            }
            .disabled(!canSave)
            .animation(.easeOut(duration: 0.15), value: canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.readingSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.readingBorder, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Save the bullet (with live reader context) and clear the field, keeping
    /// focus so several ideas can be jotted in a row. Empty drafts are ignored.
    private func submit() {
        if ideas.add(draft, capture: capture()) {
            draft = ""
            inputFocused = true
        }
    }

    // MARK: List of open ideas

    @ViewBuilder
    private var list: some View {
        if ideas.ideas.isEmpty {
            emptyState
        } else {
            List {
                ForEach(ideas.ideas) { idea in
                    IdeaRow(idea: idea) { ideas.markDone(idea) }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.readingBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { ideas.delete(idea) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "lightbulb")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.readingMuted)
            Text("No ideas yet")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text("Jot a friction point or improvement\nas you notice it.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.readingMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One idea bullet: a tappable check-circle to mark it done, the text, and a small
/// muted timestamp. Swipe the row to delete (set up by the list).
private struct IdeaRow: View {
    let idea: ImprovementIdea
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.readingMuted)
            }
            .buttonStyle(.plain)
            // Nudge the circle onto the text's first line.
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(idea.text)
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text(idea.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
