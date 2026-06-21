import Foundation
import SQLite3

// SQLite hands back a sentinel destructor (`SQLITE_TRANSIENT`) telling it to copy
// bound text rather than borrow our buffer — without this, a Swift `String`'s
// transient UTF-8 pointer would dangle the moment the bind call returns. Not
// surfaced by the SQLite module map, so we reconstruct the documented value.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Models

/// Lifecycle of one captured improvement idea. Defaults to `open`; the panel only
/// shows `open` ideas, so marking `done`/`dismissed` quietly clears it from view
/// without deleting the record.
public enum IdeaStatus: String, Sendable, CaseIterable {
    case open, done, dismissed
}

/// One improvement idea jotted while reading — a private local scratchpad bullet,
/// not feedback or analytics. `text`, `createdAt`, and `status` are the minimum;
/// the rest is best-effort reader context captured at the moment of writing, so a
/// future reread of the idea can recall *what* in the reader provoked it.
public struct ImprovementIdea: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var status: IdeaStatus
    /// The read this idea was captured during, if any (`read_items.id`).
    public var sourceReadId: String?
    /// Token position in that read when the idea was jotted.
    public var tokenIndex: Int?
    /// Reading speed (wpm) at capture — e.g. "gauge too bright at 650".
    public var wpm: Int?
    /// A short phrase around the active word at capture, for "what was on screen".
    public var contextSnippet: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        status: IdeaStatus = .open,
        sourceReadId: String? = nil,
        tokenIndex: Int? = nil,
        wpm: Int? = nil,
        contextSnippet: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.sourceReadId = sourceReadId
        self.tokenIndex = tokenIndex
        self.wpm = wpm
        self.contextSnippet = contextSnippet
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Where a read came from, so recents can show provenance and the resume logic can
/// reason about it. Raw values match the on-disk `source` column.
public enum ReadSource: String, Sendable {
    case file, shortcut, manual
    case shareSheet = "share_sheet"
    case deepLink = "deep_link"
}

/// Lifecycle of a read record. `active` = in progress / resumable; `completed` =
/// finished to the end; `archived` reserved for a later "hide from recents".
public enum ReadStatus: String, Sendable {
    case active, completed, archived
}

/// A durable record of one thing read: the full body plus enough metadata to
/// resume it (last position, speed, hand) and list it under recents. The body is
/// stored inline — fine for the 5k–100k-char clipboard/article chunks Skim takes;
/// bodies would move to files only if Skim ever ingests whole books.
public struct ReadItem: Identifiable, Equatable, Sendable {
    public let id: String
    /// First few words / heading, for the recents list. `nil` until derived.
    public var title: String?
    public var body: String
    public var source: ReadSource
    /// Original file path for a `.txt` import, if any.
    public var sourcePath: String?
    /// Stable content hash, so the same text can be recognized on re-import.
    public var textHash: String?
    public var wordCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var lastTokenIndex: Int
    public var lastWpm: Int
    /// "right" / "left" — the hand the read was last driven with.
    public var readingHand: String
    public var status: ReadStatus

    public init(
        id: String = UUID().uuidString,
        title: String? = nil,
        body: String,
        source: ReadSource,
        sourcePath: String? = nil,
        textHash: String? = nil,
        wordCount: Int,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastTokenIndex: Int = 0,
        lastWpm: Int = 400,
        readingHand: String = "right",
        status: ReadStatus = .active
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.source = source
        self.sourcePath = sourcePath
        self.textHash = textHash
        self.wordCount = wordCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastTokenIndex = lastTokenIndex
        self.lastWpm = lastWpm
        self.readingHand = readingHand
        self.status = status
    }

    /// A short, stable title from the body's first words — what shows in recents.
    /// Strips whitespace runs and caps at `maxWords`, adding an ellipsis only when
    /// the body actually runs longer. Empty/whitespace text yields `"Untitled"`.
    public static func deriveTitle(from body: String, maxWords: Int = 10) -> String {
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return "Untitled" }
        let head = words.prefix(maxWords).joined(separator: " ")
        return words.count > maxWords ? head + "…" : head
    }
}

/// A deterministic, run-stable content hash (64-bit FNV-1a, hex). Swift's built-in
/// `Hasher` is seeded per-process so it can't recognize the same text across
/// launches; this can, which is what re-import detection needs.
public enum TextHash {
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Store

public enum SkimStoreError: Error, Equatable {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
}

/// The app's local persistence: a single SQLite database holding read records and
/// improvement ideas. No server, no accounts, no sync — just a boring durable
/// store so Skim remembers what you were reading, where you stopped, and the ideas
/// you jotted. Foundation + SQLite only (no UI), so `CoreChecks` can exercise the
/// whole thing on macOS.
///
/// Not `Sendable` and not thread-safe: it wraps a raw connection meant to be
/// touched from one place. The app owns it from the `@MainActor` view model; tests
/// drive it synchronously. Open once and keep it.
public final class SkimStore {
    private var db: OpaquePointer?
    /// ISO-8601 with fractional seconds — the on-disk format for every timestamp,
    /// so dates sort correctly as plain TEXT and round-trip without locale drift.
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Open (creating if needed) the database at `path`, then run migrations. Pass
    /// `":memory:"` for an ephemeral store (tests). Throws if the file can't be
    /// opened or the schema can't be created.
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SkimStoreError.open(message)
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS read_items (
            id TEXT PRIMARY KEY,
            title TEXT,
            body TEXT NOT NULL,
            source TEXT NOT NULL,
            source_path TEXT,
            text_hash TEXT,
            word_count INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT,
            last_token_index INTEGER NOT NULL DEFAULT 0,
            last_wpm INTEGER NOT NULL DEFAULT 400,
            reading_hand TEXT NOT NULL DEFAULT 'right',
            status TEXT NOT NULL DEFAULT 'active'
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_read_items_updated ON read_items(updated_at DESC);")

        try exec("""
        CREATE TABLE IF NOT EXISTS improvement_ideas (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'open',
            source_read_id TEXT,
            token_index INTEGER,
            wpm INTEGER,
            context_snippet TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ideas_created ON improvement_ideas(created_at DESC);")
    }

    // MARK: Ideas

    /// Save a new idea. Newest-first ordering is by `created_at`, so the caller
    /// just stamps `createdAt`/`updatedAt` at capture time.
    public func insertIdea(_ idea: ImprovementIdea) throws {
        let sql = """
        INSERT INTO improvement_ideas
          (id, text, status, source_read_id, token_index, wpm, context_snippet, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try run(sql) { stmt in
            bindText(stmt, 1, idea.id)
            bindText(stmt, 2, idea.text)
            bindText(stmt, 3, idea.status.rawValue)
            bindText(stmt, 4, idea.sourceReadId)
            bindInt(stmt, 5, idea.tokenIndex)
            bindInt(stmt, 6, idea.wpm)
            bindText(stmt, 7, idea.contextSnippet)
            bindText(stmt, 8, iso.string(from: idea.createdAt))
            bindText(stmt, 9, iso.string(from: idea.updatedAt))
        }
    }

    /// Ideas, newest first. Pass a `status` to filter (the panel asks for `.open`);
    /// pass `nil` for every idea regardless of status.
    public func ideas(status: IdeaStatus? = .open) throws -> [ImprovementIdea] {
        let base = """
        SELECT id, text, status, source_read_id, token_index, wpm, context_snippet, created_at, updated_at
        FROM improvement_ideas
        """
        let sql = (status == nil ? base : base + " WHERE status = ?")
            + " ORDER BY created_at DESC;"
        var out: [ImprovementIdea] = []
        try query(sql, bind: { stmt in
            if let status { bindText(stmt, 1, status.rawValue) }
        }, each: { stmt in
            out.append(ImprovementIdea(
                id: text(stmt, 0) ?? "",
                text: text(stmt, 1) ?? "",
                status: IdeaStatus(rawValue: text(stmt, 2) ?? "open") ?? .open,
                sourceReadId: text(stmt, 3),
                tokenIndex: int(stmt, 4),
                wpm: int(stmt, 5),
                contextSnippet: text(stmt, 6),
                createdAt: date(stmt, 7),
                updatedAt: date(stmt, 8)
            ))
        })
        return out
    }

    /// Replace an idea's text (the panel's inline edit) and bump `updated_at`. The
    /// caller trims; an empty string is the caller's to reject before getting here.
    public func updateIdeaText(id: String, text: String, updatedAt: Date) throws {
        try run("UPDATE improvement_ideas SET text = ?, updated_at = ? WHERE id = ?;") { stmt in
            bindText(stmt, 1, text)
            bindText(stmt, 2, iso.string(from: updatedAt))
            bindText(stmt, 3, id)
        }
    }

    /// Flip an idea's status (open → done / dismissed) and bump `updated_at`.
    public func updateIdeaStatus(id: String, status: IdeaStatus, updatedAt: Date) throws {
        try run("UPDATE improvement_ideas SET status = ?, updated_at = ? WHERE id = ?;") { stmt in
            bindText(stmt, 1, status.rawValue)
            bindText(stmt, 2, iso.string(from: updatedAt))
            bindText(stmt, 3, id)
        }
    }

    /// Permanently remove an idea (the panel's swipe-delete).
    public func deleteIdea(id: String) throws {
        try run("DELETE FROM improvement_ideas WHERE id = ?;") { bindText($0, 1, id) }
    }

    // MARK: Read items

    /// Insert or replace a read record by id. Used to create the record at import
    /// and to persist coarse changes; fine-grained position updates go through
    /// `updatePosition`.
    public func upsertReadItem(_ item: ReadItem) throws {
        let sql = """
        INSERT INTO read_items
          (id, title, body, source, source_path, text_hash, word_count,
           created_at, updated_at, completed_at, last_token_index, last_wpm,
           reading_hand, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title,
          body = excluded.body,
          source = excluded.source,
          source_path = excluded.source_path,
          text_hash = excluded.text_hash,
          word_count = excluded.word_count,
          updated_at = excluded.updated_at,
          completed_at = excluded.completed_at,
          last_token_index = excluded.last_token_index,
          last_wpm = excluded.last_wpm,
          reading_hand = excluded.reading_hand,
          status = excluded.status;
        """
        try run(sql) { stmt in
            bindText(stmt, 1, item.id)
            bindText(stmt, 2, item.title)
            bindText(stmt, 3, item.body)
            bindText(stmt, 4, item.source.rawValue)
            bindText(stmt, 5, item.sourcePath)
            bindText(stmt, 6, item.textHash)
            bindInt(stmt, 7, item.wordCount)
            bindText(stmt, 8, iso.string(from: item.createdAt))
            bindText(stmt, 9, iso.string(from: item.updatedAt))
            bindText(stmt, 10, item.completedAt.map { iso.string(from: $0) })
            bindInt(stmt, 11, item.lastTokenIndex)
            bindInt(stmt, 12, item.lastWpm)
            bindText(stmt, 13, item.readingHand)
            bindText(stmt, 14, item.status.rawValue)
        }
    }

    /// The cheap, hot-path write: update just the resume cursor (position, speed,
    /// hand) and `updated_at`. Called on pause, scrub-release, background, and
    /// periodically while reading — so it touches only the columns that move.
    public func updatePosition(
        id: String,
        tokenIndex: Int,
        wpm: Int,
        readingHand: String,
        updatedAt: Date
    ) throws {
        let sql = """
        UPDATE read_items
        SET last_token_index = ?, last_wpm = ?, reading_hand = ?, updated_at = ?
        WHERE id = ?;
        """
        try run(sql) { stmt in
            bindInt(stmt, 1, tokenIndex)
            bindInt(stmt, 2, wpm)
            bindText(stmt, 3, readingHand)
            bindText(stmt, 4, iso.string(from: updatedAt))
            bindText(stmt, 5, id)
        }
    }

    /// Mark a read finished: status `completed`, stamp `completed_at`, and land the
    /// cursor on the final token.
    public func markCompleted(id: String, tokenIndex: Int, completedAt: Date) throws {
        let sql = """
        UPDATE read_items
        SET status = 'completed', completed_at = ?, last_token_index = ?, updated_at = ?
        WHERE id = ?;
        """
        try run(sql) { stmt in
            bindText(stmt, 1, iso.string(from: completedAt))
            bindInt(stmt, 2, tokenIndex)
            bindText(stmt, 3, iso.string(from: completedAt))
            bindText(stmt, 4, id)
        }
    }

    /// The most recent still-`active` read, or `nil` if none — the candidate the
    /// launch screen offers to resume.
    public func mostRecentActive() throws -> ReadItem? {
        try readItems("WHERE status = 'active' ORDER BY updated_at DESC LIMIT 1;").first
    }

    /// The `limit` most recently touched reads, newest first, for the recents list.
    public func recentReads(limit: Int) throws -> [ReadItem] {
        try readItems("ORDER BY updated_at DESC LIMIT \(max(0, limit));")
    }

    /// One read by id (e.g. resuming a chosen recent), or `nil` if absent.
    public func readItem(id: String) throws -> ReadItem? {
        var found: ReadItem?
        try query("\(readItemSelect) WHERE id = ? LIMIT 1;", bind: { bindText($0, 1, id) },
                  each: { found = Self.readItem(from: $0, iso: self.iso) })
        return found
    }

    /// Rename a read (the recents inline edit) and bump `updated_at`. A `nil` title
    /// clears it back to "Untitled" at display time; the caller trims and decides.
    public func updateReadTitle(id: String, title: String?, updatedAt: Date) throws {
        try run("UPDATE read_items SET title = ?, updated_at = ? WHERE id = ?;") { stmt in
            bindText(stmt, 1, title)
            bindText(stmt, 2, iso.string(from: updatedAt))
            bindText(stmt, 3, id)
        }
    }

    /// Forget a read entirely (recents swipe-delete).
    public func deleteReadItem(id: String) throws {
        try run("DELETE FROM read_items WHERE id = ?;") { bindText($0, 1, id) }
    }

    private let readItemSelect = """
    SELECT id, title, body, source, source_path, text_hash, word_count,
           created_at, updated_at, completed_at, last_token_index, last_wpm,
           reading_hand, status
    FROM read_items
    """

    private func readItems(_ tail: String) throws -> [ReadItem] {
        var out: [ReadItem] = []
        try query("\(readItemSelect) \(tail)", bind: { _ in }, each: { out.append(Self.readItem(from: $0, iso: self.iso)) })
        return out
    }

    private static func readItem(from stmt: OpaquePointer?, iso: ISO8601DateFormatter) -> ReadItem {
        ReadItem(
            id: columnText(stmt, 0) ?? "",
            title: columnText(stmt, 1),
            body: columnText(stmt, 2) ?? "",
            source: ReadSource(rawValue: columnText(stmt, 3) ?? "manual") ?? .manual,
            sourcePath: columnText(stmt, 4),
            textHash: columnText(stmt, 5),
            wordCount: Int(sqlite3_column_int64(stmt, 6)),
            createdAt: iso.date(from: columnText(stmt, 7) ?? "") ?? Date(timeIntervalSince1970: 0),
            updatedAt: iso.date(from: columnText(stmt, 8) ?? "") ?? Date(timeIntervalSince1970: 0),
            completedAt: columnText(stmt, 9).flatMap { iso.date(from: $0) },
            lastTokenIndex: Int(sqlite3_column_int64(stmt, 10)),
            lastWpm: Int(sqlite3_column_int64(stmt, 11)),
            readingHand: columnText(stmt, 12) ?? "right",
            status: ReadStatus(rawValue: columnText(stmt, 13) ?? "active") ?? .active
        )
    }

    // MARK: SQLite plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SkimStoreError.exec(message)
        }
    }

    /// Prepare a statement, let `bind` set its parameters, run it to completion
    /// (one step), and finalize — for INSERT/UPDATE/DELETE.
    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SkimStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SkimStoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Prepare a SELECT, bind it, and call `each` once per result row.
    private func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void,
        each: (OpaquePointer?) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SkimStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    // MARK: Bind / read helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, idx, Int64(value)) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? { Self.columnText(stmt, col) }
    private func int(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, col))
    }
    private func date(_ stmt: OpaquePointer?, _ col: Int32) -> Date {
        iso.date(from: Self.columnText(stmt, col) ?? "") ?? Date(timeIntervalSince1970: 0)
    }

    private static func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
