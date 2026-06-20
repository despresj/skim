import Foundation

/// A validated, decoded `skim://read` deep link. The pure result of parsing an
/// inbound URL — UI-free so it can be exercised by `CoreChecks` without Xcode.
public enum DeepLink: Equatable {
    /// Ready-to-read text payload (already trimmed and length-capped).
    case text(String)
    /// A URL payload. v1 does not extract article text — the app surfaces this
    /// on a calm fallback card rather than reading the raw link.
    case url(String)
}

/// Parses inbound `skim://read?text=…` / `skim://read?url=…` deep links.
///
/// Rules: scheme must be `skim` and host `read`; `text` wins over `url` when
/// both are present; values are trimmed and empty input is rejected (`nil`);
/// `text` is capped at `maxTextLength`. Never throws — malformed input is `nil`.
public enum DeepLinkParser {
    /// Largest `text` payload accepted; longer input is truncated so tokenizing
    /// a pathological paste can't stall the UI.
    public static let maxTextLength = 100_000

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "skim",
              url.host?.lowercased() == "read",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }

        // `text` is authoritative over `url` when a link carries both.
        if let raw = items.first(where: { $0.name == "text" })?.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(String(trimmed.prefix(maxTextLength)))
        }
        if let raw = items.first(where: { $0.name == "url" })?.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .url(trimmed)
        }
        return nil
    }
}
