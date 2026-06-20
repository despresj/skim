import Foundation
import Observation

/// The reader context captured alongside an idea, so a thought jotted mid-read
/// ("gauge too bright at this speed") can later be tied back to what was actually
/// on screen. All fields are best-effort — an idea added with nothing loaded just
/// carries empties.
struct IdeaCapture {
    var readId: String?
    var tokenIndex: Int?
    var wpm: Int?
    var snippet: String?
}

/// Owns the Ideas scratchpad: the list of open ideas and the add/done/delete
/// actions, backed by the shared `SkimStore`. Kept separate from the reader so the
/// reading surface stays focused; the panel reads this, the reader supplies only
/// the capture context. Degrades to a quiet no-op list if the store failed to open.
@MainActor
@Observable
final class IdeasViewModel {
    private(set) var ideas: [ImprovementIdea] = []

    private let store: SkimStore?

    init(store: SkimStore?) {
        self.store = store
    }

    /// Pull the open ideas (newest first) from the store. Cheap; called whenever
    /// the panel appears and after every mutation so the list always matches disk.
    func reload() {
        ideas = (try? store?.ideas(status: .open)) ?? []
    }

    /// Save a quick bullet, attaching whatever reader context was live at capture.
    /// Empty/whitespace text is ignored — empty ideas never save. Instant: writes
    /// then reloads. Returns whether anything was saved (so the field can clear).
    @discardableResult
    func add(_ text: String, capture: IdeaCapture) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store else { return false }
        let now = Date()
        let idea = ImprovementIdea(
            text: trimmed,
            sourceReadId: capture.readId,
            tokenIndex: capture.tokenIndex,
            wpm: capture.wpm,
            contextSnippet: capture.snippet,
            createdAt: now,
            updatedAt: now
        )
        try? store.insertIdea(idea)
        reload()
        return true
    }

    /// Mark an idea done — it drops out of the open list (kept on disk, not deleted).
    func markDone(_ idea: ImprovementIdea) {
        try? store?.updateIdeaStatus(id: idea.id, status: .done, updatedAt: Date())
        reload()
    }

    /// Permanently remove an idea (swipe-delete).
    func delete(_ idea: ImprovementIdea) {
        try? store?.deleteIdea(id: idea.id)
        reload()
    }
}
