import Foundation
import Observation
import UIKit

/// Owns the reading session: clipboard loading, tokenization, the playback loop,
/// and the reader state machine. The view layer only reads this and forwards
/// gesture intent (`startHolding` / `stopHolding`).
@MainActor
@Observable
final class ReaderViewModel {
    private(set) var tokens: [ReadingToken] = []
    private(set) var currentIndex = 0
    private(set) var state: ReaderState = .idle

    /// Speed is fixed to the default band in this slice; vertical-slide control
    /// arrives in the next pass. The hooks (`band`, haptics) are already here.
    var band: SpeedBand = .cruise
    let mode: ReadingMode = .precisionHeld

    private var playbackTask: Task<Void, Never>?
    private let haptics = Haptics()

    // MARK: Derived state

    var currentToken: ReadingToken? {
        tokens.indices.contains(currentIndex) ? tokens[currentIndex] : nil
    }

    var progress: Double {
        guard !tokens.isEmpty else { return 0 }
        return Double(currentIndex) / Double(tokens.count)
    }

    var hasText: Bool { !tokens.isEmpty }

    // MARK: Loading

    /// Auto-load from the clipboard on launch. Empty clipboard → paste screen.
    func loadClipboard() {
        if let text = UIPasteboard.general.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            load(text)
        } else if !hasText {
            state = .idle
        }
    }

    /// Manual paste / typed fallback.
    func load(_ text: String) {
        cancelPlayback()
        tokens = Tokenizer.tokenize(text)
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
    }

    func restart() {
        cancelPlayback()
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
    }

    // MARK: Hold-to-read (precision mode)

    /// Idempotent: the drag gesture fires `onChanged` repeatedly; only the first
    /// call from a resumable state actually starts the engine.
    func startHolding() {
        guard state == .ready || state == .paused else { return }
        state = .readingHeld
        haptics.tick(.start)
        startPlayback()
    }

    func stopHolding() {
        guard state == .readingHeld else { return }
        cancelPlayback()
        state = .paused
        haptics.tick(.pause)
    }

    // MARK: Playback loop

    private func startPlayback() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let token = self.currentToken else { self.finish(); return }
                let seconds = Pacing.secondsPerToken(band: self.band, multiplier: token.delayMultiplier)
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                self.advance()
            }
        }
    }

    private func advance() {
        if currentIndex < tokens.count - 1 {
            currentIndex += 1
        } else {
            finish()
        }
    }

    private func finish() {
        cancelPlayback()
        state = .completed
        haptics.tick(.finish)
    }

    private func cancelPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
    }
}
