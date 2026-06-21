import Foundation

/// The resolved layout for one ORP-anchored active word: the font size to render it
/// at, and a horizontal shift (points, +right) to nudge the whole word by. For a
/// normal word both are the no-op (`baseFontSize`, `0`) and the pivot stays locked;
/// only a word that would clip the safe margins reduces size — and only one that
/// still won't fit at the minimum size gets shifted.
public struct PivotFit: Equatable, Sendable {
    public let fontSize: Double
    public let shift: Double

    public init(fontSize: Double, shift: Double) {
        self.fontSize = fontSize
        self.shift = shift
    }
}

/// Decides how to keep the ORP-anchored active word inside the screen's horizontal
/// safe margins without sacrificing focal stability. The pivot letter's center is
/// locked at `anchorX`; `before` flows left and `after` flows right. A long word
/// (e.g. "recommendation") would otherwise spill off the leading edge / past the
/// trailing margin.
///
/// The fallback hierarchy, deterministic and jitter-free:
///   1. Keep the ORP pivot fixed at full size whenever the word already fits.
///   2. If it would clip, reduce the font size (down to `minFontSize`) — the pivot
///      stays fixed, the word just renders smaller.
///   3. If it still clips at the minimum size, shift the whole word the *minimum*
///      amount needed to bring an edge in-bounds (revealing the start first).
///
/// Widths are supplied measured at `baseFontSize`; glyph widths scale ~linearly
/// with point size, so the solver scales them rather than re-measuring. Pure and
/// UI-free so `CoreChecks` can pin the rule down; the view owns the measuring.
public enum PivotFitSolver {
    public static func solve(
        beforeWidth: Double,
        pivotWidth: Double,
        afterWidth: Double,
        anchorX: Double,
        totalWidth: Double,
        leftMargin: Double,
        rightMargin: Double,
        baseFontSize: Double,
        minFontSize: Double
    ) -> PivotFit {
        // Distance from the locked pivot center to each edge of the word, at base size.
        let leftExtent = beforeWidth + pivotWidth / 2
        let rightExtent = pivotWidth / 2 + afterWidth

        // Room available on each side of the anchor before hitting a margin.
        let leftRoom = max(0, anchorX - leftMargin)
        let rightRoom = max(0, (totalWidth - rightMargin) - anchorX)

        // Largest size (≤ base) at which both edges sit inside the margins with the
        // pivot fixed at anchorX.
        var size = baseFontSize
        if leftExtent > 0 { size = min(size, baseFontSize * leftRoom / leftExtent) }
        if rightExtent > 0 { size = min(size, baseFontSize * rightRoom / rightExtent) }

        // Already fits at full size: normal word, nothing to do.
        if size >= baseFontSize { return PivotFit(fontSize: baseFontSize, shift: 0) }

        // Shrinks just enough to fit with the pivot still fixed — no shift.
        if size >= minFontSize { return PivotFit(fontSize: size, shift: 0) }

        // Won't fit even at the floor size: clamp to the minimum and shift the whole
        // word the least amount that brings an edge back inside the margins. Prefer
        // revealing the start of the word (left edge) since reading runs left→right.
        let scale = minFontSize / baseFontSize
        let leftEdge = anchorX - leftExtent * scale
        let rightEdge = anchorX + rightExtent * scale
        var shift = 0.0
        if leftEdge < leftMargin {
            shift = leftMargin - leftEdge
        } else if rightEdge > totalWidth - rightMargin {
            shift = (totalWidth - rightMargin) - rightEdge
        }
        return PivotFit(fontSize: minFontSize, shift: shift)
    }
}
