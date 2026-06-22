import CoreGraphics
import UIKit

/// Draws one export frame's contents in UIKit (top-left) coordinates. It owns the
/// export's visual identity — the reader's fixed warm-dark palette, the gold ORP
/// pivot, the title/end cards, the optional progress bar and "SKIM" watermark — but
/// no timing: it's handed a resolved phase/word/progress and renders it.
///
/// Layout is authored at the 1080-wide canvas and uniformly scaled by `scale`, so
/// the same renderer serves 1080×1920 MP4, 720×1280 MP4/GIF, and 540×960 GIF
/// without re-tuning. Callers establish the drawing context (a flipped CG context
/// over a pixel buffer for MP4, or a `UIGraphicsImageRenderer` for GIF) and push it
/// before calling `drawContents`. Used on a single background thread, so it needs
/// no concurrency annotations.
struct FrameRenderer {
    let width: CGFloat
    let height: CGFloat
    let title: String
    let sourceCredit: String
    let endCardText: String
    let showProgressBar: Bool
    let showWatermark: Bool

    init(
        width: Int,
        height: Int,
        title: String = "",
        sourceCredit: String = "",
        endCardText: String = "",
        showProgressBar: Bool = true,
        showWatermark: Bool = true
    ) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        self.title = title
        self.sourceCredit = sourceCredit
        self.endCardText = endCardText
        self.showProgressBar = showProgressBar
        self.showWatermark = showWatermark
    }

    /// Uniform scale from the 1080-wide reference canvas.
    private var scale: CGFloat { width / 1080 }

    // The reader's dark palette, fixed for the export (the video isn't system-aware).
    private let bg = UIColor(red: 0.067, green: 0.063, blue: 0.051, alpha: 1)
    private let bgGlow = UIColor(red: 0.161, green: 0.141, blue: 0.110, alpha: 1)
    private let fg = UIColor(red: 0.961, green: 0.949, blue: 0.929, alpha: 1)
    private let muted = UIColor(red: 0.604, green: 0.584, blue: 0.549, alpha: 1)
    private let accent = UIColor(red: 0.980, green: 0.761, blue: 0.420, alpha: 1)

    // Word layout @1080, scaled up from the reader's 52/30pt @ ~390pt-wide screen.
    private var wordBaseSize: CGFloat { 150 * scale }
    private var wordMinSize: CGFloat { 88 * scale }
    private var sideMargin: CGFloat { 80 * scale }
    /// Pivot locked at horizontal center for a clean, centered RSVP look on video.
    private var anchorX: CGFloat { width / 2 }
    /// Word's vertical center — riding a little above the middle, like the reader.
    private var wordCenterY: CGFloat { height * 0.42 }

    /// Draw the frame. Assumes a UIKit-oriented graphics context is already current
    /// (pushed by the caller).
    func drawContents(phase: ExportPhase, word: String, progress: Double) {
        drawBackground()
        switch phase {
        case .title:
            drawTitleCard()
        case .reading:
            drawWord(word)
            if showProgressBar { drawProgressBar(progress) }
            if showWatermark { drawWatermark(alpha: 0.16, y: 130 * scale) }
        case .end:
            drawEndCard()
        }
    }

    // MARK: Background

    private func drawBackground() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        bg.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))

        // A soft warm glow pooled at the top settling into the deep base — the
        // reader's `ReadingCanvas`, top-lit.
        let colors = [bgGlow.cgColor, bg.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: width / 2, y: 0),
                end: CGPoint(x: width / 2, y: height * 0.62),
                options: [])
            ctx.restoreGState()
        }
    }

    // MARK: Reading word (locked ORP pivot, never clipping)

    private func drawWord(_ word: String) {
        guard !word.isEmpty else { return }
        let parts = ORP.split(word)

        // Solve size + shift at base size, exactly as the live reader does: a long
        // word shrinks (pivot fixed) and only shifts in as a last resort.
        let fit = PivotFitSolver.solve(
            beforeWidth: Double(measure(parts.before, wordBaseSize)),
            pivotWidth: Double(measure(parts.pivot, wordBaseSize)),
            afterWidth: Double(measure(parts.after, wordBaseSize)),
            anchorX: Double(anchorX),
            totalWidth: Double(width),
            leftMargin: Double(sideMargin),
            rightMargin: Double(sideMargin),
            baseFontSize: Double(wordBaseSize),
            minFontSize: Double(wordMinSize))
        let size = CGFloat(fit.fontSize)
        let font = roundedFont(size, .semibold)

        // Re-measure at the resolved size so the pivot's center lands exactly on the
        // (possibly shifted) anchor.
        let beforeW = measure(parts.before, size)
        let pivotW = measure(parts.pivot, size)
        let pivotCenterX = anchorX + CGFloat(fit.shift)
        let pivotLeftX = pivotCenterX - pivotW / 2
        let beforeX = pivotLeftX - beforeW
        let afterX = pivotLeftX + pivotW
        let topY = wordCenterY - font.lineHeight / 2

        drawRun(parts.before, at: CGPoint(x: beforeX, y: topY), font: font, color: fg)
        drawRun(parts.pivot, at: CGPoint(x: pivotLeftX, y: topY), font: font, color: accent)
        drawRun(parts.after, at: CGPoint(x: afterX, y: topY), font: font, color: fg)
    }

    private func drawRun(_ s: String, at point: CGPoint, font: UIFont, color: UIColor) {
        guard !s.isEmpty else { return }
        (s as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawProgressBar(_ progress: Double) {
        let barWidth = width - sideMargin * 2
        let barHeight = 10 * scale
        let y = height - 150 * scale
        let track = CGRect(x: sideMargin, y: y, width: barWidth, height: barHeight)
        UIColor(white: 1, alpha: 0.09).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: barHeight / 2).fill()

        let fillW = max(0, min(1, CGFloat(progress))) * barWidth
        if fillW > 0 {
            let fill = CGRect(x: sideMargin, y: y, width: fillW, height: barHeight)
            accent.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: barHeight / 2).fill()
        }
    }

    // MARK: Cards

    private func drawTitleCard() {
        let hasCredit = !sourceCredit.isEmpty
        let titleCenterY = hasCredit ? height * 0.38 : height * 0.40
        drawCentered(title, font: roundedFont(92 * scale, .bold), color: fg,
                     centerY: titleCenterY, maxWidth: width - sideMargin * 2, lineSpacing: 8 * scale)
        if hasCredit {
            drawCentered(sourceCredit, font: roundedFont(34 * scale, .medium), color: muted,
                         centerY: titleCenterY + 150 * scale, maxWidth: width - sideMargin * 2,
                         lineSpacing: 4 * scale)
        }
        if showWatermark { drawWatermark(alpha: 0.6, y: height - 220 * scale) }
    }

    private func drawEndCard() {
        let text = endCardText.isEmpty ? "Read anything\nlike this with Skim" : endCardText
        drawCentered(text, font: roundedFont(78 * scale, .bold), color: fg,
                     centerY: height * 0.42, maxWidth: width - sideMargin * 2, lineSpacing: 12 * scale)
        if showWatermark { drawWatermark(alpha: 0.75, y: height * 0.42 + 210 * scale) }
    }

    /// The "SKIM" wordmark — letter-spaced, in the warm accent — the subtle
    /// branding/watermark across cards and (faintly) the reading frames.
    private func drawWatermark(alpha: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(34 * scale, .semibold),
            .foregroundColor: accent.withAlphaComponent(alpha),
            .kern: 10 * scale,
        ]
        let s = "SKIM" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: (width - size.width) / 2, y: y), withAttributes: attrs)
    }

    // MARK: Text helpers

    private func drawCentered(_ s: String, font: UIFont, color: UIColor,
                              centerY: CGFloat, maxWidth: CGFloat, lineSpacing: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = lineSpacing
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        let ns = s as NSString
        let bounding = ns.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil)
        let rect = CGRect(x: (width - maxWidth) / 2, y: centerY - bounding.height / 2,
                          width: maxWidth, height: bounding.height)
        ns.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
    }

    /// Width of a run in the active word's font (kern 0, matching how it's drawn).
    private func measure(_ s: String, _ size: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return ceil((s as NSString).size(withAttributes: [.font: roundedFont(size, .semibold)]).width)
    }

    /// The rounded system font matching the reader's `.rounded` design.
    private func roundedFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: size)
    }
}
