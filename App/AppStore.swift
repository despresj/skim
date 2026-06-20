import Foundation

/// Opens Skim's one local database. Boring on purpose: a single SQLite file in
/// Application Support, no server, no accounts, no sync. Returns `nil` if the
/// store can't be opened — the app still runs, just without persistence — so a
/// disk hiccup never blocks reading.
enum AppStore {
    static func open() -> SkimStore? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true) else { return nil }
        let url = dir.appendingPathComponent("skim.sqlite")
        return try? SkimStore(path: url.path)
    }
}
