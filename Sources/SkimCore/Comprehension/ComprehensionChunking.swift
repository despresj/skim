import Foundation

/// Picks what text to send the model. Short reads go whole; long reads are
/// sampled into a handful of paragraph-aligned excerpts spread across the
/// document, so questions still span beginning-to-end without paying to send
/// (or upload) tens of thousands of words. Whole paragraphs are taken, so no
/// excerpt ends mid-sentence.
public enum ComprehensionChunking {
    public static let fullTextWordLimit = 4000
    public static let targetChunkWords = 600
    public static let sampleCount = 5
    private static let elision = "\n\n[…]\n\n"

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func sampleForGeneration(_ text: String) -> String {
        guard wordCount(text) > fullTextWordLimit else { return text }

        let paragraphs = splitParagraphs(text)
        guard paragraphs.count > 1 else {
            // One enormous paragraph: fall back to sentence boundaries.
            return firstSentences(text, targetWords: targetChunkWords)
        }

        // Anchor paragraph indices evenly across the document.
        let anchors = (0..<sampleCount).map { i -> Int in
            guard sampleCount > 1 else { return 0 }
            let frac = Double(i) / Double(sampleCount - 1)        // 0, .25, .5, .75, 1
            return min(paragraphs.count - 1, Int((Double(paragraphs.count - 1) * frac).rounded()))
        }

        var usedIndices = Set<Int>()
        var chunks: [String] = []
        for anchor in anchors {
            var idx = anchor
            // Don't re-emit a paragraph already pulled into a prior chunk.
            while idx < paragraphs.count && usedIndices.contains(idx) { idx += 1 }
            guard idx < paragraphs.count else { continue }
            var words = 0
            var taken: [String] = []
            while idx < paragraphs.count, !usedIndices.contains(idx), words < targetChunkWords {
                taken.append(paragraphs[idx])
                words += wordCount(paragraphs[idx])
                usedIndices.insert(idx)
                idx += 1
            }
            if !taken.isEmpty { chunks.append(taken.joined(separator: "\n\n")) }
        }
        return chunks.joined(separator: elision)
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: { $0.isEmpty })
            .map { $0.joined(separator: " ") }
    }

    /// Take whole sentences from the front until ~targetWords (single-paragraph fallback).
    private static func firstSentences(_ text: String, targetWords: Int) -> String {
        var taken: [String] = []
        var words = 0
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                taken.append(current)
                words += wordCount(current)
                current = ""
                if words >= targetWords { break }
            }
        }
        if words < targetWords, !current.trimmingCharacters(in: .whitespaces).isEmpty {
            taken.append(current)
        }
        return taken.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
