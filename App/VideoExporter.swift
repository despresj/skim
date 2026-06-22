import AVFoundation
import CoreGraphics
import UIKit

/// Renders pasted text into a Skim-native vertical MP4 — a clean reading video, not
/// a screen recording of the app. It reuses the real reading core end to end: the
/// `Tokenizer` for words + rhythm, `Pacing`/`ExportTimeline` for frame timing, and
/// `ORP` + `PivotFitSolver` (via `FrameRenderer`) for the locked, never-clipping
/// pivot word.
///
/// All heavy work runs off the main actor (a nonisolated `static` method), driving
/// an `AVAssetWriter` through a manual, back-pressure-aware frame loop.
enum VideoExporter {
    enum ExportError: LocalizedError {
        case tooFewWords(Int)
        case writerSetupFailed
        case pixelBufferUnavailable
        case appendFailed
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case let .tooFewWords(n):
                return "Need at least \(ExportSpec.minimumTokens) words to make a video (got \(n))."
            case .writerSetupFailed:      return "Couldn't start the video writer."
            case .pixelBufferUnavailable: return "Ran out of frame buffers."
            case .appendFailed:           return "A frame failed to encode."
            case let .writerFailed(m):    return "Export failed: \(m)"
            }
        }
    }

    /// Render `text` under `settings` to an MP4 and return its temp-dir URL.
    /// `onProgress` reports 0…1 from a background context — the caller hops to main.
    static func export(
        text: String,
        settings: ExportSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let tokens = Tokenizer.tokenize(text)
        guard tokens.count >= ExportSpec.minimumTokens else {
            throw ExportError.tooFewWords(tokens.count)
        }

        let timeline = settings.timeline(for: tokens)
        let outW = settings.videoSize.width
        let outH = settings.videoSize.height

        // Fresh temp file; AVAssetWriter refuses to overwrite.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skim-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw ExportError.writerSetupFailed
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: outW >= 1080 ? 10_000_000 : 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: settings.videoFps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: bufferAttrs)

        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferUnavailable }

        let renderer = FrameRenderer(
            width: outW, height: outH,
            title: settings.trimmedTitle,
            sourceCredit: settings.sourceCredit.trimmingCharacters(in: .whitespacesAndNewlines),
            endCardText: settings.endCardText,
            showProgressBar: settings.includeProgressBar,
            showWatermark: settings.includeWatermark)

        let totalFrames = max(1, timeline.totalFrames)
        let fps = Int32(timeline.fps)

        // Render the pixels for each *distinct* phase exactly once into a scratch
        // buffer (a word held for six frames is laid out once), then memcpy that into
        // a fresh per-frame buffer to append. The scratch buffer is never handed to
        // the writer, so the encoder — which may still be reading earlier frames
        // asynchronously — never shares a buffer with our drawing. Every appended
        // buffer is distinct and appended exactly once.
        var cachedPhase: ExportPhase?
        var scratch: CVPixelBuffer?

        do {
        var frame = 0
        while frame < totalFrames {
            try Task.checkCancellation()
            // Back-pressure: yield until the writer can take more, never blocking main.
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                }
                try await Task.sleep(nanoseconds: 4_000_000)
            }

            let phase = timeline.phase(atFrame: frame)
            if phase != cachedPhase || scratch == nil {
                let fresh = try makeBuffer(pool: pool)
                renderInto(fresh, renderer: renderer, phase: phase, tokens: tokens)
                scratch = fresh
                cachedPhase = phase
            }

            let buffer = try makeBuffer(pool: pool)
            copyPixels(from: scratch!, to: buffer)

            let time = CMTime(value: Int64(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ExportError.appendFailed
            }

            frame += 1
            if frame % 12 == 0 || frame == totalFrames {
                onProgress(Double(frame) / Double(totalFrames))
            }
        }

        input.markAsFinished()
        await writer.finishWritingAsync()
        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        onProgress(1)
        return url
        } catch {
            // Cancelled or failed mid-render: abort the writer, which discards the
            // partial output file, so no truncated MP4 is ever left behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Draw one frame into a pixel buffer: wrap it in a CG context, flip to UIKit's
    /// top-left origin, and hand off to the shared `FrameRenderer`.
    private static func renderInto(
        _ buffer: CVPixelBuffer, renderer: FrameRenderer, phase: ExportPhase, tokens: [ReadingToken]
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return }

        ctx.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(buffer)))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        renderer.drawContents(
            phase: phase,
            word: phase.wordText(tokens: tokens),
            progress: phase.readingProgress(tokenCount: tokens.count))
        UIGraphicsPopContext()
    }

    /// Copy raw pixels between two same-pool buffers, row by row so any row padding
    /// is honored (buffers from one pool share a layout, but this stays correct even
    /// if they didn't).
    private static func copyPixels(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }

        let srcRow = CVPixelBufferGetBytesPerRow(src)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        let height = CVPixelBufferGetHeight(dst)
        if srcRow == dstRow {
            memcpy(dstBase, srcBase, srcRow * height)
        } else {
            let rowBytes = min(srcRow, dstRow)
            for y in 0..<height {
                memcpy(dstBase + y * dstRow, srcBase + y * srcRow, rowBytes)
            }
        }
    }

    private static func makeBuffer(pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else {
            throw ExportError.pixelBufferUnavailable
        }
        return buffer
    }
}

extension AVAssetWriter {
    /// `finishWriting`'s completion handler wrapped for `await`.
    func finishWritingAsync() async {
        await withCheckedContinuation { continuation in
            self.finishWriting { continuation.resume() }
        }
    }
}
