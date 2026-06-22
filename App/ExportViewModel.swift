import SwiftUI

/// Drives the Export Questions sheet for the current read: the fixed read text, the
/// `ExportSettings`, the live estimate, and the render lifecycle. The only stateful
/// object here — the sheet forwards edits and reads derived values, mirroring how
/// `ReaderViewModel` owns the reader. The text is the read's own prose (never edited
/// in this sheet), tokenized once up front so the estimate and validation stay cheap.
@MainActor
@Observable
final class ExportViewModel: Identifiable {
    /// Stable identity so the Export sheet can be presented via `.sheet(item:)`.
    nonisolated let id = UUID()

    /// The read's text, fixed for the lifetime of the sheet.
    let text: String

    var settings: ExportSettings

    /// Where the render is in its lifecycle.
    enum Phase: Equatable {
        case idle
        case rendering(Double)
        case done(URL)
        case failed(String)
    }
    var phase: Phase = .idle

    let tokens: [ReadingToken]
    private var renderTask: Task<Void, Never>?

    /// Build for the current read: its prose, a prefilled title (from the read's
    /// saved title, blank if none), and the reader's current WPM as the export speed.
    init(text: String, title: String, wpm: Int) {
        self.text = text
        self.tokens = Tokenizer.tokenize(text)
        var settings = ExportSettings(wpm: wpm)
        settings.title = title
        // Title card defaults on only when there's a title to show; with a blank
        // title it starts off, and the user can enable it explicitly.
        settings.includeTitleCard = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.settings = settings
    }

    // MARK: Derived

    var tokenCount: Int { tokens.count }

    var isRendering: Bool {
        if case .rendering = phase { return true }
        return false
    }

    /// Export is offered only with enough real words and when not mid-render.
    var canExport: Bool {
        tokens.count >= ExportSpec.minimumTokens && !isRendering
    }

    var estimateLabel: String { settings.estimateLabel(for: tokens) }
    var warning: String? { settings.warning(for: tokens) }

    /// The primary button's verb, reflecting the chosen format.
    var exportButtonTitle: String {
        settings.format == .mp4 ? "Export MP4" : "Export GIF Preview"
    }

    // MARK: WPM stepping (uses the real speed grid)

    func slower() { settings.wpm = SpeedBand.nearest(to: settings.wpm).slower().wpm }
    func faster() { settings.wpm = SpeedBand.nearest(to: settings.wpm).faster().wpm }
    var bandLabel: String { SpeedBand.nearest(to: settings.wpm).label }

    // MARK: Render

    func export() {
        guard canExport else { return }
        phase = .rendering(0)

        let settings = self.settings
        let text = self.text

        // Progress hops back to the main actor; only applies while still rendering.
        let onProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                if case .rendering = self.phase { self.phase = .rendering(p) }
            }
        }

        renderTask = Task {
            do {
                let url: URL
                switch settings.format {
                case .mp4:
                    url = try await VideoExporter.export(text: text, settings: settings, onProgress: onProgress)
                case .gif:
                    url = try await GIFExporter.export(text: text, settings: settings, onProgress: onProgress)
                }
                self.phase = .done(url)
            } catch is CancellationError {
                // Cancelled by the user; `cancelExport` already restored .idle.
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stop an in-flight render. The exporter discards its partial temp file when the
    /// task is cancelled, so nothing is left on disk.
    func cancelExport() {
        renderTask?.cancel()
        renderTask = nil
        phase = .idle
    }
}
