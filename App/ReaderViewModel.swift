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

    /// True while a finger is dragging the progress scrubber. Playback is held the
    /// whole time; the view reads this to show the position readout/handle.
    private(set) var isScrubbing = false

    /// Whether playback was actually running (cruise or held) when the current
    /// scrub began — so releasing the scrubber resumes only if it was already On.
    private var scrubWasPlaying = false

    /// The quarter (0…4) the scrub last passed, so the 25/50/75% haptics fire once
    /// each per sweep instead of buzzing continuously.
    private var scrubQuarter = -1

    private var playbackTask: Task<Void, Never>?
    private let haptics = Haptics()

    /// The local persistence store, shared with the Ideas panel. `nil` only if it
    /// failed to open — every store call is optional so reading never depends on it.
    let store: SkimStore?

    /// The `read_items.id` of the record backing the current session, set when a
    /// read is recorded on load. Lets a jotted idea point back at this read, and
    /// drives position autosave. `nil` with nothing loaded.
    private(set) var currentReadId: String?

    /// Whether cruise should resume when a covering overlay (the Ideas panel) is
    /// dismissed — true only if we were actively cruising when it opened.
    private var resumeCruiseAfterOverlay = false

    init(store: SkimStore? = nil) {
        self.store = store
    }

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

    /// A URL delivered by a `skim://read?url=…` deep link, awaiting the user's
    /// choice on the fallback card. v1 doesn't extract article text, so the URL
    /// is parked here (the reader is left untouched) and `ContentView` shows
    /// `LinkFallbackView` while it's set. `nil` when no link is pending.
    private(set) var pendingLink: String?

    // MARK: Derived state

    var currentToken: ReadingToken? {
        tokens.indices.contains(currentIndex) ? tokens[currentIndex] : nil
    }

    var progress: Double {
        guard !tokens.isEmpty else { return 0 }
        return Double(currentIndex) / Double(tokens.count)
    }

    var hasText: Bool { !tokens.isEmpty }

    /// Number of words in the loaded text — the one clean metric the end-of-read
    /// review shows.
    var wordCount: Int { tokens.count }

    /// The whole text reassembled from its tokens (paragraphs preserved) for the
    /// end-of-read review's scroll view. Clean reading prose — Markdown is already
    /// stripped at tokenize time.
    var reviewText: String { ReadingContext.fullText(tokens) }

    /// Reader context for an idea jotted right now: which read, the position, the
    /// speed, and a short phrase around the active word. Empty when nothing's
    /// loaded. Lets "word jitters here" be tied back to the exact spot later.
    var ideaCapture: IdeaCapture {
        guard hasText else { return IdeaCapture() }
        let w = ReadingContext.window(tokens: tokens, index: currentIndex, before: 4, after: 4)
        let snippet = [w.before, w.current, w.after]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return IdeaCapture(readId: currentReadId,
                           tokenIndex: currentIndex,
                           wpm: wpm,
                           snippet: snippet.isEmpty ? nil : snippet)
    }

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

    /// Route an inbound `skim://read` deep link. Text loads straight into the
    /// reader (armed in `.ready`, no autoplay); a URL is parked on the fallback
    /// card. Invalid/empty links are ignored so they never disturb a current
    /// read or crash. The link is authoritative over the clipboard: we bank the
    /// current pasteboard change count up front so the foreground re-read can't
    /// clobber the link or trigger iOS's paste prompt (resolves the cold-launch
    /// race between `onOpenURL` and `scenePhase == .active`, in either order).
    func handleDeepLink(_ url: URL) {
        lastPasteboardChange = UIPasteboard.general.changeCount
        switch DeepLinkParser.parse(url) {
        case .text(let text):
            pendingLink = nil
            loadAndCruise(text, at: .imported)
        case .url(let link):
            pendingLink = link
        case nil:
            break
        }
    }

    /// The deep-link "just start reading" path: load text, set the speed, and
    /// hand straight off to hands-free cruise — no `.ready` pause, no thumb start.
    /// Text arriving from a Shortcut, the Share Sheet, or the Action Button streams
    /// on arrival at `band`. Reuses `load` + `enterCruise` so the start logic isn't
    /// duplicated, and leaves normal manual paste/input (which routes through
    /// `load` alone, arming `.ready`) untouched. Empty text never reaches here —
    /// the parser rejects it — but we guard so a non-`.ready` load is a quiet no-op.
    private func loadAndCruise(_ text: String, at band: SpeedBand) {
        load(text)
        guard state == .ready else { return }
        self.band = band
        enterCruise()
    }

    /// Route an inbound *file* URL — a `.txt` opened into Skim from a Shortcut,
    /// the Action Button, the Share Sheet, or the Files app. This is the path for
    /// large text: the file carries the whole document (no URL truncation) and we
    /// read it directly, so the pasteboard is never touched. Reads UTF-8, trims,
    /// and quietly ignores an empty/unreadable file (no paste screen, no error),
    /// then loads straight into hands-free cruise at the brisk import speed — no
    /// `.ready` pause, preserving the selected hand and current UI. Like the deep
    /// link, the file is authoritative over the clipboard, so we bank the change
    /// count up front to neutralize the cold-launch foreground re-read race.
    func handleFileURL(_ url: URL) {
        lastPasteboardChange = UIPasteboard.general.changeCount
        guard let text = Self.readImportedText(from: url) else { return }
        pendingLink = nil
        loadAndCruise(text, at: .imported)
    }

    /// Read a `.txt` file's contents as sanitized text, or `nil` if it can't be
    /// read or is empty. Wraps the security-scoped-resource dance for files
    /// opened in place (a no-op for files iOS already copied into our Inbox), and
    /// decodes leniently as UTF-8 so a stray byte never rejects the whole file.
    private static func readImportedText(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImportedText.sanitize(String(decoding: data, as: UTF8.self))
    }

    /// The reader dismissed the fallback card without opening the link — drop it
    /// and fall back to whatever was showing before (paste screen if idle).
    func dismissLink() {
        pendingLink = nil
    }

    /// "Copy Link" on the fallback card: put the URL on the pasteboard and
    /// re-bank the change count so the link we just copied doesn't loop back as
    /// readable clipboard text on the next foreground.
    func copyLink() {
        guard let link = pendingLink else { return }
        UIPasteboard.general.string = link
        lastPasteboardChange = UIPasteboard.general.changeCount
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

    /// "Read Again" from the end-of-read review: jump back to the top and start
    /// streaming hands-free at the brisk import speed — explicit imported text
    /// earns an immediate On start. The reading hand and UI style are untouched.
    /// Re-entrant: each tap cancels any running loop first, so repeated taps can't
    /// stack playback tasks. A no-op with nothing loaded.
    func readAgain() {
        guard hasText else { return }
        cancelPlayback()
        isScrubbing = false
        currentIndex = 0
        band = .imported
        mode = .cruise
        state = .cruisePlaying
        haptics.tick(.start)
        startPlayback()
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

    // MARK: Scrubbing (drag the progress bar to seek)

    /// A finger touched down on the progress scrubber. Pause immediately and
    /// remember whether we were actually reading, so release can resume only if so.
    /// Speed, reading hand, and mode are all left untouched — scrubbing only moves
    /// the *position*. A no-op with no text, on the idle/completed screens, or if a
    /// scrub is somehow already in flight.
    func beginScrub() {
        guard hasText, !isScrubbing,
              state == .ready || state == .paused ||
              state == .precisionHeld || state == .cruisePlaying else { return }
        scrubWasPlaying = (state == .precisionHeld || state == .cruisePlaying)
        cancelPlayback()
        isScrubbing = true
        state = .paused
        scrubQuarter = Int(progress * 4)
        haptics.prepare()
    }

    /// Map a 0…1 drag position to a token and preview it live. The active word and
    /// the context paragraph both read off `currentIndex`, so updating it here
    /// updates the whole preview. A soft tick marks each quarter crossed (bounded
    /// to three per sweep, so a fast drag never buzzes). Clamped to valid indices,
    /// so dragging to either extreme is always safe.
    func scrub(toProgress p: Double) {
        guard isScrubbing, !tokens.isEmpty else { return }
        let clamped = min(max(0, p), 1)
        let target = min(tokens.count - 1, max(0, Int((clamped * Double(tokens.count - 1)).rounded())))

        let quarter = min(3, Int(clamped * 4))
        if quarter != scrubQuarter {
            if quarter > 0 { haptics.tick(.scrubTick) }
            scrubQuarter = quarter
        }

        guard target != currentIndex else { return }
        currentIndex = target
    }

    /// The finger lifted off the scrubber. We've already landed on the selected
    /// token; resume reading only if it was On before the scrub, otherwise stay at
    /// rest. The end of the text counts as completed so a scrub-to-the-end finishes
    /// cleanly into the review screen rather than playing one trailing word.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubQuarter = -1
        guard scrubWasPlaying else { return }
        if currentIndex >= tokens.count - 1 {
            finish()
        } else {
            mode = .cruise
            state = .cruisePlaying
            startPlayback()
        }
    }

    // MARK: Overlay pause/resume (Ideas panel)

    /// A covering panel (Ideas) is opening over the reader. If we were cruising,
    /// pause — reading shouldn't advance behind a sheet — and remember to resume on
    /// dismiss. A held thumb has already lifted to tap, so only cruise needs this.
    /// Silent (no pause haptic): opening a scratchpad isn't a reading gesture.
    func overlayPresented() {
        resumeCruiseAfterOverlay = (state == .cruisePlaying)
        if state == .cruisePlaying {
            cancelPlayback()
            mode = .precisionHeld
            state = .paused
        }
    }

    /// The panel closed. Resume hands-free reading only if it was On when the panel
    /// opened; otherwise stay at rest exactly where it was — opening Ideas never
    /// loses your place or starts playback on its own.
    func overlayDismissed() {
        let shouldResume = resumeCruiseAfterOverlay
        resumeCruiseAfterOverlay = false
        if shouldResume { enterCruise() }
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
