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

    /// Current reading speed. Adjusted live by sliding the thumb vertically
    /// during a hold (see `setBandIndex`).
    private(set) var band: SpeedBand = .cruise

    /// How playback is currently driven. Flips to `.cruise` on hands-free
    /// autoplay and back to `.precisionHeld` when the thumb takes over again.
    private(set) var mode: ReadingMode = .precisionHeld

    /// All bands ordered slow → fast, for the vertical slide control.
    let bands: [SpeedBand] = SpeedBand.allCases.sorted { $0.rawValue < $1.rawValue }

    /// Which hand drives the thumb rail. Mirrors the control surface, the word's
    /// offset, and the speed rail to the chosen side. Persisted so it's set once.
    var isLeftHanded: Bool = UserDefaults.standard.bool(forKey: "skim.isLeftHanded") {
        didSet { UserDefaults.standard.set(isLeftHanded, forKey: "skim.isLeftHanded") }
    }

    private var playbackTask: Task<Void, Never>?
    private let haptics = Haptics()

    /// The text currently loaded into the reader, so re-grabbing the clipboard
    /// on every foreground only reloads when the copied text actually changed —
    /// a brief switch away and back never resets your place.
    private var loadedText: String?

    /// Pasteboard generation we last inspected. Comparing change counts is
    /// prompt-free; only reading the contents triggers iOS's "Allow Paste". So we
    /// read — and risk the prompt — only when something was copied since we last
    /// looked. Returning to the app without copying never prompts.
    private var lastPasteboardChange = -1

    /// Set when something new was copied while a read was already loaded. Rather
    /// than silently swapping the text out from under you (and losing your place),
    /// the view surfaces a gentle "New text — read it?" chip and waits. Detected
    /// from the prompt-free change count alone, so the clipboard contents are only
    /// ever read once you opt in by tapping the chip.
    private(set) var hasPendingClipboard = false

    // MARK: Derived state

    var currentToken: ReadingToken? {
        tokens.indices.contains(currentIndex) ? tokens[currentIndex] : nil
    }

    var progress: Double {
        guard !tokens.isEmpty else { return 0 }
        return Double(currentIndex) / Double(tokens.count)
    }

    var hasText: Bool { !tokens.isEmpty }

    /// Position of the current band within `bands` (0 = slowest).
    var bandIndex: Int { bands.firstIndex(of: band) ?? 0 }

    /// Whole-number words-per-minute for the current band.
    var wpm: Int { Int(band.rawValue) }

    /// Reading "temperature" of the current band, 0 (calm/slow) → 1 (warm/fast).
    /// Drives the speed-responsive amber accents on the reading surface — the
    /// background glow, dial, pivot letter, and progress bar all warm as you
    /// throttle up. Updates reactively whenever the band changes.
    var speedWarmth: Double { band.warmth }

    // MARK: Speed control

    /// Set the band by index along the slide track, clamped to the available
    /// range. Fires a haptic tick on each *actual* change so a speed shift is
    /// felt, not just seen. The playback loop reads `band` each tick, so a new
    /// speed takes effect on the very next word.
    func setBandIndex(_ index: Int) {
        let clamped = max(0, min(bands.count - 1, index))
        let newBand = bands[clamped]
        guard newBand != band else { return }
        band = newBand
        haptics.tick(.bandChange)
    }

    // MARK: Loading

    /// Grab the clipboard on launch and on every return to the foreground, so
    /// freshly copied text is picked up instantly. Reloads only when the copied
    /// text differs from what's already loaded — returning with the same
    /// clipboard never interrupts an in-progress read. Empty clipboard with
    /// nothing loaded → paste screen.
    func loadClipboard() {
        let change = UIPasteboard.general.changeCount
        // Nothing copied since we last looked → don't touch the contents, so iOS
        // never shows the paste prompt just for coming back to the app.
        guard change != lastPasteboardChange else {
            if !hasText { state = .idle }
            return
        }
        lastPasteboardChange = change
        // Something new was copied. If a read is already loaded, don't yank it
        // away — raise the "new text" chip and let the reader decide. We hold off
        // on reading the contents (and the paste prompt that comes with it) until
        // they tap it. With nothing loaded yet, there's nothing to protect, so
        // load straight away.
        if hasText {
            hasPendingClipboard = true
        } else {
            readPasteboard()
        }
    }

    /// The reader tapped "New text — read it?": now read the freshly copied
    /// contents (this is the opt-in that may surface the paste prompt) and load
    /// them, replacing the current session and starting from the top.
    func loadPendingClipboard() {
        hasPendingClipboard = false
        let previous = loadedText
        readPasteboard()
        // Confirm with a soft tick only if the read actually swapped in new text
        // (a non-text or empty copy leaves the current read untouched).
        if loadedText != previous { haptics.tick(.newText) }
    }

    /// The reader dismissed the chip — keep reading what's loaded. The change
    /// count is already banked, so the same copy never nags again.
    func dismissPendingClipboard() {
        hasPendingClipboard = false
    }

    /// Explicit "Check Clipboard" tap — always reads the current contents, even
    /// when the change count hasn't moved, so the manual fallback can recover text
    /// that iOS withheld from the automatic foreground read.
    func pasteFromClipboard() {
        lastPasteboardChange = UIPasteboard.general.changeCount
        readPasteboard()
    }

    private func readPasteboard() {
        if let text = UIPasteboard.general.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard text != loadedText else { return }
            load(text)
        } else if !hasText {
            state = .idle
        }
    }

    /// Tokenize freshly loaded text and arm the reader at the first word.
    func load(_ text: String) {
        cancelPlayback()
        loadedText = text
        tokens = Tokenizer.tokenize(text)
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
        hasPendingClipboard = false
    }

    func restart() {
        cancelPlayback()
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
    }

    /// Drop the loaded text and return to the calm empty state. Backs the reader's
    /// "back" chevron — Skim is clipboard-first, so this means "read something
    /// else," handing off to whatever you copy next.
    func clearText() {
        cancelPlayback()
        tokens = []
        loadedText = nil
        currentIndex = 0
        state = .idle
        hasPendingClipboard = false
    }

    // MARK: Navigation (rail flicks)

    /// How far a horizontal rail flick jumps. A fixed, predictable step — no
    /// WPM-scaled or sentence-relative math, so "back a bit" / "ahead a bit"
    /// always means the same distance.
    let navigationJumpWords = 12

    /// A transient confirmation of the last flick jump, for the view to flash and
    /// fade. `seq` bumps on every jump so two identical flicks in a row still
    /// re-trigger the animation; the view keys its fade off it.
    struct NavFlash: Equatable {
        enum Direction { case back, forward }
        let direction: Direction
        /// Words actually moved (≥ 1) — honest at the edges, where a flick near
        /// the start/end travels fewer than `navigationJumpWords`.
        let words: Int
        let seq: Int
    }

    /// The most recent flick jump. `nil` until the first jump of a session.
    private(set) var navFlash: NavFlash?
    private var navFlashSeq = 0

    /// Flick left: jump back a fixed step. Clamped at the start. Never changes
    /// the reader's state, so a flick while paused stays paused, while reading
    /// keeps reading, and while cruising keeps cruising.
    func rewind12Words() {
        let from = currentIndex
        currentIndex = max(0, currentIndex - navigationJumpWords)
        emitNavFlash(.back, moved: from - currentIndex)
        haptics.tick(.rewind)
        restartPlaybackIfPlaying()
    }

    /// Flick right: jump ahead a fixed step. Clamped at the last word.
    func forward12Words() {
        guard !tokens.isEmpty else { return }
        let from = currentIndex
        currentIndex = min(tokens.count - 1, currentIndex + navigationJumpWords)
        emitNavFlash(.forward, moved: currentIndex - from)
        haptics.tick(.forward)
        restartPlaybackIfPlaying()
    }

    /// Publish a flick confirmation. A jump that moved nothing (already pinned at
    /// an edge) shows no label — the edge haptic alone marks the boundary, and a
    /// "0 words" flash would only clutter the sacred surface.
    private func emitNavFlash(_ direction: NavFlash.Direction, moved: Int) {
        guard moved > 0 else { return }
        navFlashSeq += 1
        navFlash = NavFlash(direction: direction, words: moved, seq: navFlashSeq)
    }

    /// After a jump, if the engine is running, restart the pacing loop so the
    /// landed-on word gets a full beat instead of the leftover of the current
    /// sleep. A no-op when paused/ready, so a flick there never starts playback.
    private func restartPlaybackIfPlaying() {
        if state == .precisionHeld || state == .cruisePlaying { startPlayback() }
    }

    // MARK: Cruise (hands-free autoplay)

    /// Double-tap the canvas to hand off: playback continues from the current
    /// word without a held thumb. Enterable from `ready` (start fresh) or
    /// `paused` (resume where you stopped).
    func enterCruise() {
        guard state == .paused || state == .ready else { return }
        mode = .cruise
        state = .cruisePlaying
        haptics.tick(.cruiseOn)
        startPlayback()
    }

    /// Single-tap (canvas or rail) to take the wheel back: stop autoplay and
    /// settle into the paused context view.
    func pauseCruise() {
        guard state == .cruisePlaying else { return }
        cancelPlayback()
        mode = .precisionHeld
        state = .paused
        haptics.tick(.pause)
    }

    /// One double-tap, the same gesture both ways: hand off to cruise from a
    /// resting state, or take the wheel back while cruising. The view fires this
    /// from anywhere on the surface — canvas *or* thumb rail — so cruise is never
    /// hidden behind which patch of screen you happened to tap. A no-op mid-hold
    /// or when finished, where there's nothing to hand off.
    func toggleCruise() {
        switch state {
        case .ready, .paused: enterCruise()
        case .cruisePlaying: pauseCruise()
        default: break
        }
    }

    // MARK: Hold-to-read (precision mode)

    /// Idempotent: the drag gesture fires `onChanged` repeatedly; only the first
    /// call from a resumable state actually starts the engine.
    func startHolding() {
        guard state == .ready || state == .paused else { return }
        mode = .precisionHeld
        state = .precisionHeld
        haptics.prepare()
        haptics.tick(.start)
        startPlayback()
    }

    func stopHolding() {
        guard state == .precisionHeld else { return }
        cancelPlayback()
        state = .paused
        haptics.tick(.pause)
    }

    /// Halt playback when the app leaves the foreground (call, notification, app
    /// switch) so it never advances through text you can't see. A fresh hold
    /// resumes. Also a safety net if a drag is cancelled without an `onEnded`.
    func pauseForBackground() {
        guard state == .precisionHeld || state == .cruisePlaying else { return }
        cancelPlayback()
        mode = .precisionHeld
        state = .paused
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
