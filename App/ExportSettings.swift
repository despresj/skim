import Foundation

/// Everything that shapes an export, with creator-friendly defaults so the happy
/// path — paste → Export MP4 → Share — never requires opening settings. MP4 is the
/// business; GIF is a small, clearly-secondary preview mode. A plain value type, so
/// it crosses to the background renderer as `Sendable` for free.
struct ExportSettings: Equatable, Sendable {
    enum Format: Equatable, Sendable { case mp4, gif }

    /// Output dimensions (always 9:16 vertical). Stored as a pair so MP4 and GIF can
    /// share the size machinery while offering different menus.
    enum Dimensions: Equatable, Sendable {
        case p1080  // 1080×1920
        case p720   // 720×1280
        case p540   // 540×960

        var width: Int {
            switch self {
            case .p1080: return 1080
            case .p720:  return 720
            case .p540:  return 540
            }
        }
        var height: Int {
            switch self {
            case .p1080: return 1920
            case .p720:  return 1280
            case .p540:  return 960
            }
        }
        var label: String { "\(width)×\(height)" }
    }

    // MARK: Format
    var format: Format = .mp4

    // MARK: MP4
    var videoSize: Dimensions = .p1080
    var videoFps: Int = 30
    var includeTitleCard = true
    var includeEndCard = true
    var includeProgressBar = true
    var includeWatermark = true

    // MARK: GIF (secondary — short previews only)
    var gifSize: Dimensions = .p720
    var gifFps: Int = 12
    /// Cap the GIF to the first N seconds of the read — GIFs are for previews.
    var gifDurationCap: Double = 6
    var gifWatermark = true

    // MARK: Reading
    /// Words per minute. Seeded from the user's default cruising speed (never a
    /// hardcoded 400) by whoever builds the settings.
    var wpm: Int

    // MARK: Branding
    var title = ""
    var sourceCredit = ""
    var endCardText = ExportSettings.defaultEndCardText

    static let defaultEndCardText = "Read anything\nlike this with Skim"

    // MARK: Derived

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasTitle: Bool { !trimmedTitle.isEmpty }

    /// Output pixel size for the active format.
    var outputWidth: Int { format == .mp4 ? videoSize.width : gifSize.width }
    var outputHeight: Int { format == .mp4 ? videoSize.height : gifSize.height }
    var outputFps: Int { format == .mp4 ? videoFps : gifFps }

    /// Whether a title card actually renders: MP4 only, toggled on, and a title set.
    var rendersTitleCard: Bool { format == .mp4 && includeTitleCard && hasTitle }
    /// Whether an end card actually renders: MP4 only, toggled on. GIFs carry no cards.
    var rendersEndCard: Bool { format == .mp4 && includeEndCard }

    /// The pacing-driven timeline for these settings. Card durations collapse to
    /// zero when a card won't render, so the estimate and the render always agree.
    func timeline(for tokens: [ReadingToken]) -> ExportTimeline {
        ExportTimeline(
            tokens: tokens,
            wpm: wpm,
            fps: outputFps,
            titleDuration: rendersTitleCard ? ExportSpec.titleCardDuration : 0,
            endDuration: rendersEndCard ? ExportSpec.endCardDuration : 0)
    }

    /// Seconds the exported file will actually play. MP4 is the whole timeline; GIF
    /// is clipped to its duration cap (and never carries cards).
    func outputDuration(for tokens: [ReadingToken]) -> Double {
        let tl = timeline(for: tokens)
        switch format {
        case .mp4: return tl.totalDuration
        case .gif: return min(tl.readingDuration, gifDurationCap)
        }
    }

    /// The "Estimated video: 1:42" string for the current settings + text.
    func estimateLabel(for tokens: [ReadingToken]) -> String {
        ExportSpec.formatted(outputDuration(for: tokens))
    }

    /// A soft, non-blocking warning to surface beneath the estimate, or nil.
    func warning(for tokens: [ReadingToken]) -> String? {
        let tl = timeline(for: tokens)
        switch format {
        case .mp4:
            // Over three minutes, the render takes a noticeable while.
            if tl.totalDuration > 180 { return "This export may take a while." }
            return nil
        case .gif:
            // The read is longer than the clip — make clear the GIF is just a taste.
            if tl.readingDuration > gifDurationCap {
                return "GIFs are best for short previews. Use MP4 for full reads."
            }
            return nil
        }
    }
}

extension ExportPhase {
    /// The word to draw for a reading frame (empty for cards).
    func wordText(tokens: [ReadingToken]) -> String {
        if case let .reading(i) = self, tokens.indices.contains(i) { return tokens[i].text }
        return ""
    }

    /// Reading progress 0…1 for the bottom bar, derived from token position so it's
    /// constant within a held word (keeps the per-phase frame cache exact).
    func readingProgress(tokenCount: Int) -> Double {
        guard case let .reading(i) = self, tokenCount > 0 else { return 0 }
        return Double(i + 1) / Double(tokenCount)
    }
}
