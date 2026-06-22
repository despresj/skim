import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Renders pasted text into a short looping GIF preview — the secondary, advanced
/// export. Deliberately bounded: no audio, no title/end cards, and clipped to the
/// settings' duration cap, because a GIF is a taste of the read, not the read. It
/// shares the exact reading identity with the MP4 path via `FrameRenderer`.
enum GIFExporter {
    enum ExportError: LocalizedError {
        case tooFewWords(Int)
        case destinationFailed

        var errorDescription: String? {
            switch self {
            case let .tooFewWords(n):
                return "Need at least \(ExportSpec.minimumTokens) words to make a GIF (got \(n))."
            case .destinationFailed:
                return "Couldn't create the GIF file."
            }
        }
    }

    static func export(
        text: String,
        settings: ExportSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let tokens = Tokenizer.tokenize(text)
        guard tokens.count >= ExportSpec.minimumTokens else {
            throw ExportError.tooFewWords(tokens.count)
        }

        let timeline = settings.timeline(for: tokens)   // no cards for GIF
        let fps = max(1, settings.gifFps)
        let cappedSeconds = min(timeline.readingDuration, settings.gifDurationCap)
        let frameCount = max(1, Int((cappedSeconds * Double(fps)).rounded()))
        let delay = 1.0 / Double(fps)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skim-\(Int(Date().timeIntervalSince1970)).gif")
        try? FileManager.default.removeItem(at: url)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.destinationFailed
        }

        // Loop forever.
        let fileProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)

        let frameProps = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay,
        ]] as CFDictionary

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let imageRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: settings.gifSize.width, height: settings.gifSize.height),
            format: format)
        let renderer = FrameRenderer(
            width: settings.gifSize.width, height: settings.gifSize.height,
            showProgressBar: settings.includeProgressBar,
            showWatermark: settings.gifWatermark)

        // Reuse the rendered image across the frames a word spans.
        var cachedPhase: ExportPhase?
        var cachedImage: CGImage?

        do {
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let phase = timeline.phase(atFrame: frame)
            let cg: CGImage
            if phase == cachedPhase, let cached = cachedImage {
                cg = cached
            } else {
                let image = imageRenderer.image { _ in
                    renderer.drawContents(
                        phase: phase,
                        word: phase.wordText(tokens: tokens),
                        progress: phase.readingProgress(tokenCount: tokens.count))
                }
                guard let made = image.cgImage else { continue }
                cg = made
                cachedPhase = phase
                cachedImage = made
            }
            CGImageDestinationAddImage(dest, cg, frameProps)

            if frame % 6 == 0 || frame == frameCount - 1 {
                onProgress(Double(frame + 1) / Double(frameCount))
            }
        }

        guard CGImageDestinationFinalize(dest) else { throw ExportError.destinationFailed }
        onProgress(1)
        return url
        } catch {
            // Cancelled or failed mid-render: drop the partial GIF.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
