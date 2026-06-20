import SwiftUI

/// The calm landing for a `skim://read?url=…` deep link. v1 can't extract
/// article text yet, so rather than pretend — RSVP-ing a raw URL would feel
/// broken — Skim acknowledges the link and offers to open it. This view is the
/// seam where real article extraction drops in later (a "Read it" action).
struct LinkFallbackView: View {
    let viewModel: ReaderViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 14) {
                    Text("Link received")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)

                    Text(viewModel.pendingLink ?? "")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.readingSurface,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.readingBorder, lineWidth: 1)
                        )

                    Text("Article extraction coming soon.")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                }

                Spacer(minLength: 24)
                Spacer(minLength: 24)

                actions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    /// Thumb-range actions: open the link (primary), copy it (quiet), or back
    /// out to the paste screen. Kept low on the surface, within reach.
    private var actions: some View {
        VStack(spacing: 12) {
            Button("Open Link") {
                if let link = viewModel.pendingLink, let url = URL(string: link) {
                    openURL(url)
                }
                viewModel.dismissLink()
            }
            .buttonStyle(PrimaryPillStyle())

            Button("Copy Link") {
                viewModel.copyLink()
            }
            .buttonStyle(SecondaryPillStyle())

            Button("Not now") {
                viewModel.dismissLink()
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.readingMuted)
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}
