import Foundation

/// A single unit shown on the reading surface, carrying enough metadata to
/// support pacing and (later) semantic replay and context.
public struct ReadingToken: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// Scales the base per-token delay. 1.0 is a normal word; punctuation and
    /// paragraph breaks push it higher so the reading gains rhythm.
    public let delayMultiplier: Double
    public let sentenceIndex: Int
    public let paragraphIndex: Int
    public let tokenIndex: Int

    public init(
        id: UUID = UUID(),
        text: String,
        delayMultiplier: Double,
        sentenceIndex: Int,
        paragraphIndex: Int,
        tokenIndex: Int
    ) {
        self.id = id
        self.text = text
        self.delayMultiplier = delayMultiplier
        self.sentenceIndex = sentenceIndex
        self.paragraphIndex = paragraphIndex
        self.tokenIndex = tokenIndex
    }
}
