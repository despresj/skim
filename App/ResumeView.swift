import SwiftUI

/// The "welcome back" entry surface, shown on launch when nothing fresh was
/// copied and there's a read to pick up. Leads with the last read — one tap to
/// continue exactly where you stopped — with the rest of your recent reads listed
/// below to jump back into, and a quiet way out to read something new. Same warm
/// reading-by-lamplight surface as everywhere else; this is a calm shelf, not a
/// file manager.
struct ResumeView: View {
    let viewModel: ReaderViewModel
    let candidate: ReadItem

    /// The read currently being renamed (drives the rename alert), plus its working title.
    @State private var renaming: ReadItem?
    @State private var renameDraft = ""
    @State private var showingSettings = false

    /// Recent reads other than the hero candidate (which already has its own card).
    private var others: [ReadItem] {
        viewModel.recents.filter { $0.id != candidate.id }
    }

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                header
                    .padding(.top, 28)
                    .padding(.horizontal, 28)

                resumeCard
                    .padding(.top, 20)
                    .padding(.horizontal, 24)

                if others.isEmpty {
                    Spacer()
                } else {
                    recentsHeader
                        .padding(.top, 28)
                        .padding(.horizontal, 30)
                    recentsList
                }

                newTextButton
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { viewModel.refreshRecents() }
        .overlay(alignment: .topLeading) {
            SettingsGear { showingSettings = true }
                .padding(.leading, 16)
                .padding(.top, 8)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert("Rename read", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let item = renaming { viewModel.renameRead(item, title: renameDraft) }
                renaming = nil
            }
        }
    }

    /// Open the rename alert for a read, seeded with its current title.
    private func beginRename(_ item: ReadItem) {
        renameDraft = item.title ?? ""
        renaming = item
    }

    /// The hero card's metadata line — "7% · 1:42 · File" — built as one mixed-color
    /// `Text` so the estimated read time can ride the warm accent (time is the
    /// prominent metric) while progress and source stay quiet. The estimate is
    /// memoized in the view model, so this stays cheap across re-renders.
    private func resumeMetadata(_ item: ReadItem) -> Text {
        let muted = Color.readingMuted
        let sep = Text("  ·  ").foregroundColor(muted)
        let lead = item.status == .completed
            ? Text("Finished").foregroundColor(muted)
            : Text("\(Int((ReadProgress.fraction(item) * 100).rounded()))%")
                .foregroundColor(Color.readingForeground)
        var line = lead
        if let estimate = viewModel.readTimeEstimate(for: item) {
            line = line + sep + Text(estimate).foregroundColor(Color.readingAccent)
        }
        return line + sep + Text(ReadProgress.sourceLabel(item.source)).foregroundColor(muted)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("WELCOME BACK")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(3)
                .foregroundStyle(Color.readingMuted)
            Text("Pick up where you left off")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Resume hero card

    private var resumeCard: some View {
        Button { viewModel.resume(candidate) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Text(candidate.title ?? "Untitled")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // Leave room for the corner delete button on the title's line.
                    .padding(.leading, 34)

                ProgressBar(fraction: ReadProgress.fraction(candidate))

                HStack(spacing: 6) {
                    resumeMetadata(candidate)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Spacer()
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingAccent)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color.readingSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // A separate tap target so the hero (the single most-recent read) is
        // deletable too — a permanent, no-retention delete, same as the list.
        .overlay(alignment: .topLeading) {
            ArmedDeleteButton { viewModel.deleteRead(candidate) }
                .padding(10)
        }
    }

    // MARK: Recents

    private var recentsHeader: some View {
        HStack {
            Text("Recent")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingMuted)
            Spacer()
        }
    }

    private var recentsList: some View {
        List {
            ForEach(others) { item in
                HStack(spacing: 4) {
                    ArmedDeleteButton { viewModel.deleteRead(item) }

                    Button { viewModel.resume(item) } label: {
                        RecentRow(item: item, estimate: viewModel.readTimeEstimate(for: item))
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.readingBorder)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { viewModel.deleteRead(item) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { beginRename(item) } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.readingAccent)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: New text

    private var newTextButton: some View {
        Button { viewModel.dismissResume() } label: {
            Label("New text", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(SecondaryPillStyle())
    }
}

/// One recent read in the list: title, then a muted "progress · time · source"
/// line. Time replaces word count as the at-a-glance unit.
private struct RecentRow: View {
    let item: ReadItem
    /// Memoized "time at default" estimate, passed in from the parent (which owns
    /// the view model and its cache). `nil` drops the time segment cleanly.
    let estimate: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? "Untitled")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .lineLimit(1)
                Text(ReadProgress.subtitle(item, estimate: estimate))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
            }
            Spacer(minLength: 8)
            Image(systemName: item.status == .completed ? "checkmark.circle" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.status == .completed ? Color.readingAccent : Color.readingMuted)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A two-tap hard-delete button, pinned to the leading edge. The first tap *arms*
/// it — the trash flares red — and a second tap within three seconds permanently
/// forgets the read. If no second tap comes, the red fades out over those three
/// seconds and the deletion disarms on its own, so a stray tap never deletes.
private struct ArmedDeleteButton: View {
    let onDelete: () -> Void

    @State private var armed = false
    /// Drives the visible red flare separately from `armed` so the color can fade
    /// over three seconds while the armed window stays live until it lapses.
    @State private var showRed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Button(role: .destructive) { tap() } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(showRed ? Color.red : Color.readingMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { disarmTask?.cancel() }
    }

    private func tap() {
        if armed {
            // Confirmed within the window: delete for good.
            disarm()
            onDelete()
            return
        }
        // First tap: arm + flare red instantly, then fade the red away over three
        // seconds. When the fade lapses, the deletion disarms itself.
        armed = true
        showRed = true
        withAnimation(.linear(duration: 3)) { showRed = false }
        disarmTask?.cancel()
        disarmTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { armed = false }
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        armed = false
        showRed = false
    }
}

/// A slim progress line for the resume card, in the warm accent.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.readingBorder)
                Capsule().fill(Color.readingAccent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// Shared read-position formatting for the resume card and recent rows.
enum ReadProgress {
    static func fraction(_ item: ReadItem) -> Double {
        guard item.wordCount > 1 else { return item.status == .completed ? 1 : 0 }
        return Double(item.lastTokenIndex) / Double(item.wordCount - 1)
    }

    /// "7% · 1:42 · File" — progress first, then the estimated read time at the
    /// configured speed, then the source. Completed reads lead with "Finished".
    /// Word count is gone from the visible metadata; time is the user-facing unit.
    /// The `estimate` is supplied by the caller (it depends on the default speed and
    /// is memoized in the view model); when absent the time segment is simply omitted.
    static func subtitle(_ item: ReadItem, estimate: String?) -> String {
        let lead = item.status == .completed
            ? "Finished"
            : "\(Int((fraction(item) * 100).rounded()))%"
        return [lead, estimate, sourceLabel(item.source)]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    static func sourceLabel(_ source: ReadSource) -> String {
        switch source {
        case .file:       return "File"
        case .shortcut:   return "Shortcut"
        case .shareSheet: return "Shared"
        case .deepLink:   return "Link"
        case .manual:     return "Pasted"
        }
    }
}
