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

                ProgressBar(fraction: ReadProgress.fraction(candidate))

                HStack(spacing: 6) {
                    Text(ReadProgress.subtitle(candidate))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
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
                Button { viewModel.resume(item) } label: {
                    RecentRow(item: item)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.readingBorder)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { viewModel.deleteRead(item) } label: {
                        Label("Delete", systemImage: "trash")
                    }
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

/// One recent read in the list: title, then a muted progress + source line.
private struct RecentRow: View {
    let item: ReadItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? "Untitled")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .lineLimit(1)
                Text(ReadProgress.subtitle(item))
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

    /// "42% · 1,920 words · Pasted" — completed reads read as "Finished".
    static func subtitle(_ item: ReadItem) -> String {
        let words = "\(item.wordCount.formatted()) words"
        let origin = sourceLabel(item.source)
        if item.status == .completed {
            return "Finished  ·  \(words)  ·  \(origin)"
        }
        let pct = Int((fraction(item) * 100).rounded())
        return "\(pct)%  ·  \(words)  ·  \(origin)"
    }

    private static func sourceLabel(_ source: ReadSource) -> String {
        switch source {
        case .file:       return "File"
        case .shortcut:   return "Shortcut"
        case .shareSheet: return "Shared"
        case .deepLink:   return "Link"
        case .manual:     return "Pasted"
        }
    }
}
