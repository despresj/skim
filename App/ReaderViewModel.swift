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

    /// Bumped whenever the reader settles somewhere the paused Threadline should
    /// recenter on: entering pause, and each scrub step while paused. The viewport
    /// keys its auto-center off this, so a manual scroll (which never bumps it) is
    /// never yanked back, but the next pause/scrub recenters cleanly on the active
    /// word. A monotonic counter, not the index, so re-renders don't recenter.
    private(set) var contextRecenterTick = 0
    private func bumpRecenter() { contextRecenterTick += 1 }

    /// The reader asked to re-center the paused context on the active word (tapped
    /// the "back to word" locator). Only meaningful while paused — the context is
    /// hidden otherwise. Drives `contextRecenterTick`, the one recenter signal.
    func recenterContext() {
        guard state == .paused else { return }
        bumpRecenter()
    }

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

    /// The user's configured default *cruising* speed, in words-per-minute — the
    /// raw stored preference set in Settings. Every explicit "read this now" path
    /// accelerates toward this (resolved through `defaultCruisingBand`), and a fresh
    /// manual read opens here; the live vertical slide still moves speed freely
    /// within a read. Persisted. Defaults to the calm `cruise` band (currently 400),
    /// but 400 is just today's default — change this and every auto-start follows.
    var defaultWpm: Int = UserDefaults.standard.object(forKey: "skim.defaultWpm") as? Int
        ?? SpeedBand.cruise.wpm {
        didSet {
            UserDefaults.standard.set(defaultWpm, forKey: "skim.defaultWpm")
            // The "time at default" estimates are speed-relative, so a changed
            // default speed invalidates every cached one.
            readTimeCache.removeAll()
        }
    }

    /// Whether a freshly loaded manual read begins streaming hands-free immediately
    /// (cruise) instead of waiting at `.ready` for a thumb. Imports always cruise;
    /// this controls the clipboard/paste path. Persisted. Off by default — the calm
    /// default is to wait for the thumb.
    var startInCruise: Bool = UserDefaults.standard.bool(forKey: "skim.startInCruise") {
        didSet { UserDefaults.standard.set(startInCruise, forKey: "skim.startInCruise") }
    }

    /// The configured default cruising speed resolved to a real, in-range detent —
    /// the single source of truth every auto-start ramp accelerates toward, and the
    /// band a fresh manual read opens at. Clamps a stored preference that's somehow
    /// out of range back onto the speed grid (see `SpeedBand.nearest`), so no call
    /// site has to. Not a hardcoded constant: changing the Settings speed moves the
    /// ramp target everywhere at once.
    private var defaultCruisingBand: SpeedBand { SpeedBand.nearest(to: defaultWpm) }

    /// The default cruising speed as whole WPM — what the ramp call sites pass as
    /// their target.
    private var defaultCruisingWpm: Int { defaultCruisingBand.wpm }

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

    /// A running auto-start speed ramp (gentle acceleration up to cruising speed).
    /// Lives independently of the playback loop, which simply reads the live `band`
    /// each word — so the ramp just nudges `band` along its curve and the pacing,
    /// gauge, and warm colors all follow. Cancelled the instant the user takes
    /// manual control (speed change, pause, scrub). `nil` when no ramp is in flight.
    private var rampTask: Task<Void, Never>?

    /// While a ramp is live, the speed it's climbing toward. Persistence uses this
    /// instead of the transient ramping band, so pausing or saving mid-ramp banks
    /// the *intended* cruising speed as the read's resume speed — never the slow
    /// opening WPM. `nil` when not ramping.
    private var rampTargetWpm: Int?

    private let haptics = Haptics()

    /// In-memory memo of formatted "time at default" estimates, keyed by
    /// `ReadItem.id`, so a list of recent reads doesn't re-tokenize each body every
    /// time a card re-renders. Deliberately *not* observed — it's a pure render-time
    /// cache, never UI state — and cleared whenever `defaultWpm` changes, since the
    /// estimate is speed-relative.
    @ObservationIgnored private var readTimeCache: [String: String] = [:]

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
        // Open at the user's preferred default speed so a cold start agrees with the
        // Settings choice rather than the hardcoded cruise constant.
        band = defaultCruisingBand
    }

    /// The text currently loaded into the reader, so re-grabbing the clipboard
    /// on every foreground only reloads when the copied text actually changed —
    /// a brief switch away and back never resets your place.
    private var loadedText: String?

    /// Pasteboard generation we last inspected. Comparing change counts is
    /// prompt-free; only reading the contents triggers iOS's "Allow Paste". So we
    /// read — and risk the prompt — only when something was copied since we last
    /// looked. Returning to the app without copying never prompts. Persisted so a
    /// cold launch can tell "nothing new was copied since last time" (→ offer
    /// resume) from "fresh text is waiting" (→ clipboard-first auto-load).
    private var lastPasteboardChange: Int {
        get { UserDefaults.standard.object(forKey: "skim.lastPasteboardChange") as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: "skim.lastPasteboardChange") }
    }

    /// A resumable past read offered on the entry screen when there's no fresh
    /// clipboard text to open. Drives `ResumeView` (resume candidate + recents).
    /// `nil` whenever a read is loaded or there's nothing to resume.
    private(set) var pendingResume: ReadItem?

    /// The recent reads backing the library list. Observable so swipe-deletes and
    /// resumes update the list live; refreshed whenever `ResumeView` appears.
    private(set) var recents: [ReadItem] = []

    /// True when the New Text (paste) screen was opened *from* Reads — so it can
    /// show a "‹ Reads" back button that actually leads somewhere. Reads is the
    /// home/root: New Text is a create-flow reached from it, and `returnToReads()`
    /// goes back. False on a cold launch with no library (New Text is then the only
    /// screen, with nothing behind it) and cleared the moment a read loads.
    private(set) var canReturnToReads = false

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

    // MARK: Reading-mode semantics — Pause and Cruise are modes; Hold is the clutch
    //
    // The engine keeps a fine-grained `ReaderState` machine (idle/ready/precisionHeld/
    // paused/cruisePlaying/completed) because gestures and persistence lean on it. But
    // the *UI* only ever needs to know one of three things — am I parked, am I driving
    // by myself, or am I temporarily reading because a finger is down — so every view
    // reads these derived flags instead of switching on the raw state. That keeps a
    // contradictory combination (context visible while words advance, "Cruise" while
    // merely holding, pause chrome during a hold) impossible to express.

    /// Temporarily reading because the thumb is held — the clutch, not a mode. Maps
    /// to the engine's `precisionHeld`; never a peer of paused/cruise in the UI.
    var isHoldingToRead: Bool { state == .precisionHeld }

    /// Driving hands-free.
    var isCruising: Bool { state == .cruisePlaying }

    /// Parked: stopped and not holding — the calm orientation surface (the pre-start
    /// `ready` and a mid-read `paused` are the same chrome: stopped, inspectable).
    var isParked: Bool { state == .ready || state == .paused }

    /// Words are advancing — by cruise autopilot or under a held thumb.
    var isActivelyReading: Bool { isCruising || isHoldingToRead }

    /// The pause context map shows only while parked with text — never mid-read.
    var shouldShowContext: Bool { hasText && isParked }

    /// Pause chrome (left utility rail, back button) shows only while parked.
    var shouldShowPauseChrome: Bool { hasText && isParked }

    /// Number of words in the loaded text — the one clean metric the end-of-read
    /// review shows.
    var wordCount: Int { tokens.count }

    /// The whole text reassembled from its tokens (paragraphs preserved) for the
    /// end-of-read review's scroll view. Clean reading prose — Markdown is already
    /// stripped at tokenize time.
    var reviewText: String { ReadingContext.fullText(tokens) }

    /// The current read's stored title, for prefilling an export's title card.
    /// `nil` when nothing is loaded or no saved record backs the session.
    var currentTitle: String? {
        guard let store, let id = currentReadId, let item = try? store.readItem(id: id) else { return nil }
        return item.title
    }

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

    // MARK: Read-time estimate ("time at default")

    /// A compact estimated reading time for arbitrary text — the paste draft —
    /// computed with Skim's real pacing (clause/sentence/paragraph/long-word
    /// multipliers) at the configured default cruising speed, never a hardcoded
    /// WPM. Returns `nil` for empty/whitespace text so the caller can hide the
    /// label rather than show "0:00".
    func readTimeEstimate(forText text: String) -> String? {
        let tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return nil }
        return ReadTimeEstimate.compact(
            ReadTimeEstimate.seconds(tokens: tokens, wpm: defaultCruisingWpm))
    }

    /// The same estimate for a stored read, memoized by id so the resume/recents
    /// surfaces don't re-tokenize a body on every render. `nil` if the body
    /// tokenizes to nothing.
    func readTimeEstimate(for item: ReadItem) -> String? {
        if let cached = readTimeCache[item.id] { return cached }
        guard let estimate = readTimeEstimate(forText: item.body) else { return nil }
        readTimeCache[item.id] = estimate
        return estimate
    }

    // MARK: Speed control

    /// Set the band by index along the slide track, clamped to the available
    /// range. Fires a haptic tick on each *actual* change so a speed shift is
    /// felt, not just seen. The playback loop reads `band` each tick, so a new
    /// speed takes effect on the very next word.
    func setBandIndex(_ index: Int) {
        // Manual speed input always wins: a deliberate slide cancels the auto-start
        // ramp so it can't keep climbing past where the user just parked the speed.
        cancelRamp()
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
        // never shows the paste prompt just for coming back to the app. With
        // nothing loaded, this is the "no new input" case: offer to resume the most
        // recent read (falling back to the paste screen if there's nothing to resume).
        guard change != lastPasteboardChange else {
            if !hasText { offerResumeOrIdle() }
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
            loadAndCruise(text, source: .deepLink)
        case .url(let link):
            pendingLink = link
        case nil:
            break
        }
    }

    /// The deep-link "just start reading" path: load text and hand straight off to
    /// hands-free cruise — no `.ready` pause, no thumb start. Text arriving from a
    /// Shortcut, the Share Sheet, or the Action Button opens at the *configured
    /// default cruising speed* (not the 300-wpm floor, and not a fixed import speed).
    /// Reuses `load` + `startReadingWithRamp` so the start logic isn't duplicated, and
    /// leaves normal manual paste/input (which routes through `load` alone, arming
    /// `.ready`) untouched. Empty text never reaches here — the parser rejects it —
    /// but we guard so a non-`.ready` load is a quiet no-op.
    private func loadAndCruise(_ text: String, source: ReadSource, sourcePath: String? = nil) {
        load(text, source: source, sourcePath: sourcePath)
        guard state == .ready else { return }
        // Open straight at the user's default cruising speed (banked onto the record),
        // so the read — and the gauge — start where they should, not at the floor.
        startReadingWithRamp(targetWpm: defaultCruisingWpm)
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
        loadAndCruise(text, source: .file, sourcePath: url.path)
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

    /// Tokenize freshly loaded text, arm the reader at the first word, and record a
    /// durable `read_items` row so the read can be resumed and listed under recents.
    /// `source` notes where the text came from (manual paste, file, deep link, …).
    func load(_ text: String, source: ReadSource = .manual, sourcePath: String? = nil) {
        cancelPlayback()
        loadedText = text
        tokens = Tokenizer.tokenize(text)
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
        hasPendingClipboard = false
        pendingResume = nil
        canReturnToReads = false
        // A fresh manual read opens at the user's default cruising speed; imports
        // set their own band via `loadAndCruise` after this returns.
        if source == .manual { band = defaultCruisingBand }
        recordLoadedRead(text, source: source, sourcePath: sourcePath)
        // Honor the "start in cruise" preference for manual loads — open hands-free
        // at the default cruising speed (same entry path as imports). An empty load
        // stays idle.
        if source == .manual, startInCruise, state == .ready {
            startReadingWithRamp(targetWpm: defaultCruisingWpm)
        }
    }

    /// Create the persistent record for freshly loaded text and adopt its id as the
    /// current read. Empty text (or a missing store) records nothing and clears the
    /// id — so empty/failed imports never leave a row behind.
    private func recordLoadedRead(_ text: String, source: ReadSource, sourcePath: String?) {
        guard let store, !tokens.isEmpty else { currentReadId = nil; return }
        let now = Date()
        let item = ReadItem(
            title: ReadItem.deriveTitle(from: text),
            body: text,
            source: source,
            sourcePath: sourcePath,
            textHash: TextHash.of(text),
            wordCount: tokens.count,
            createdAt: now,
            updatedAt: now,
            lastTokenIndex: 0,
            lastWpm: persistedWpm,
            readingHand: handString,
            status: .active
        )
        try? store.upsertReadItem(item)
        currentReadId = item.id
    }

    func restart() {
        cancelPlayback()
        currentIndex = 0
        state = tokens.isEmpty ? .idle : .ready
    }

    /// "Read Again" from the end-of-read review: jump back to the top and start
    /// streaming hands-free — explicit imported text earns an immediate On start.
    /// Like the imports, it opens at the user's default cruising speed. The reading
    /// hand and UI style are untouched. Re-entrant: each tap cancels any running
    /// loop/ramp first, so repeated taps can't stack playback tasks. A no-op with
    /// nothing loaded.
    func readAgain() {
        guard hasText else { return }
        cancelPlayback()
        isScrubbing = false
        currentIndex = 0
        state = .ready
        reactivateRead()
        startReadingWithRamp(targetWpm: defaultCruisingWpm)
    }

    /// Flip a finished read back to `active` at the top, so a "Read Again" leaves it
    /// resumable again rather than stranded as completed. A no-op without a record.
    private func reactivateRead() {
        guard let store, let id = currentReadId, var item = try? store.readItem(id: id) else { return }
        item.status = .active
        item.completedAt = nil
        item.lastTokenIndex = 0
        item.lastWpm = persistedWpm
        item.updatedAt = Date()
        try? store.upsertReadItem(item)
    }

    /// When the user *starts reading* a read that's reopened from a completed state
    /// (a finished item tapped in Recents, opened at index 0 by `resume`), flip it
    /// back to an active session at the beginning. Reading start — not the mere
    /// reopen — is the moment a completed read becomes "in progress" again, so the
    /// completion history survives a peek but a real re-read tracks from 0. Detected
    /// from the persisted status, which is `completed` only in exactly this case
    /// (a finished read finishes into `.completed`, never `.ready`/`.paused`), so the
    /// current index is always 0 here. A no-op for any normal active read.
    private func reactivateIfCompleted() {
        guard let store, let id = currentReadId,
              let item = try? store.readItem(id: id), item.status == .completed else { return }
        reactivateRead()
    }

    /// Drop the loaded text and return to the calm empty state. Backs the reader's
    /// "back" chevron — Skim is clipboard-first, so this means "read something
    /// else," handing off to whatever you copy next.
    func clearText() {
        cancelPlayback()
        // The read stays on disk (resumable); we just let go of it here.
        saveProgress()
        tokens = []
        loadedText = nil
        currentIndex = 0
        currentReadId = nil
        state = .idle
        hasPendingClipboard = false
        canReturnToReads = false
        // Back out to the library if there's anything to resume, else the paste
        // screen — so recents stay reachable, not just offered at cold launch.
        refreshPendingResume()
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
        guard !tokens.isEmpty else { return }
        let from = currentIndex
        currentIndex = ReadingNavigation.jumpTarget(
            from: currentIndex, by: -navigationJumpWords, count: tokens.count)
        emitNavFlash(.back, moved: from - currentIndex)
        haptics.tick(.rewind)
        restartPlaybackIfPlaying()
        if state == .paused { bumpRecenter() }
    }

    /// Flick right: jump ahead a fixed step. Clamped at the last word.
    func forward12Words() {
        guard !tokens.isEmpty else { return }
        let from = currentIndex
        currentIndex = ReadingNavigation.jumpTarget(
            from: currentIndex, by: navigationJumpWords, count: tokens.count)
        emitNavFlash(.forward, moved: currentIndex - from)
        haptics.tick(.forward)
        restartPlaybackIfPlaying()
        if state == .paused { bumpRecenter() }
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
        bumpRecenter()
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
        bumpRecenter()
    }

    /// The finger lifted off the scrubber. We've already landed on the selected
    /// token; resume reading only if it was On before the scrub, otherwise stay at
    /// rest. The end of the text counts as completed so a scrub-to-the-end finishes
    /// cleanly into the review screen rather than playing one trailing word.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubQuarter = -1
        // The cursor moved — persist the new spot whether or not we resume.
        saveProgress()
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
            saveProgress()
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

    // MARK: Auto-start ramp (gentle acceleration)

    /// Shared auto-start for every explicit "read this now" path: arm the already
    /// loaded text in hands-free On mode at the configured cruising speed.
    ///
    /// By default a read *opens at `targetWpm`* (the user's default cruising speed) —
    /// no slow ramp from the floor — so every entry point (clipboard cruise, deep
    /// link, file import, "Read Again") starts at the speed the gauge should show,
    /// not at the 300-wpm minimum. A gentle slow-start is still available by passing
    /// an explicit `fromWpm` below the target, in which case the band begins there
    /// and smoothly accelerates to `targetWpm` over `duration` seconds.
    ///
    /// Requires text armed at `.ready` (a no-op otherwise). Any manual speed change,
    /// pause, or scrub cancels a running ramp and leaves the user in control at
    /// whatever speed they chose; a rewind/forward flick keeps ramping underneath.
    private func startReadingWithRamp(targetWpm: Int,
                                      fromWpm: Int? = nil,
                                      duration: Double = 2.0) {
        guard state == .ready else { return }
        cancelRamp()

        // Resolve both ends onto real, in-range detents. `nearest` clamps a target
        // that's somehow out of range (preference too high/low) safely to the
        // max/floor, so no call site can push the ramp off the speed grid. With no
        // explicit floor, `from` resolves to the target itself, so the read opens at
        // the cruising speed and `isClimbing` is false (no ramp). The floor is never
        // above the target, so a floor-level target is correctly a no-op too.
        let target = SpeedBand.nearest(to: targetWpm)
        let from = SpeedBand.nearest(to: min(fromWpm ?? target.wpm, target.wpm))
        let ramp = SpeedRamp(fromWPM: from.wpm, toWPM: target.wpm, duration: duration)

        // Remember the destination so a save banks the cruising speed (matters only
        // for an opt-in slow-start, where `from` < `target`). Open at `from` — which
        // is the target itself in the default no-ramp case — then hand off.
        rampTargetWpm = target.wpm
        band = from
        // Bank the intended speed onto the record up front (persistedWpm == target),
        // so even an immediate pause resumes at the cruising speed, not the floor.
        saveProgress()
        enterCruise()

        // Nothing to climb (already at/above target, or zero duration): land exactly
        // on target and skip the animation.
        guard ramp.isClimbing else {
            band = target
            cancelRamp()
            return
        }

        // Sample the smoothstep curve on a fine cadence; `band(at:)` snaps each
        // sample to a real detent, so we only actually move the band a handful of
        // times — exactly when the gauge should tick up — without robotic stepping.
        rampTask = Task { @MainActor [weak self] in
            let dt = 0.04
            var elapsed = 0.0
            while !Task.isCancelled, elapsed < duration {
                try? await Task.sleep(for: .seconds(dt))
                if Task.isCancelled { return }
                guard let self else { return }
                elapsed += dt
                let next = ramp.band(at: elapsed)
                if next != self.band { self.band = next }
            }
            guard let self, !Task.isCancelled else { return }
            // Settle exactly on the target band and clear the ramp.
            self.band = target
            self.cancelRamp()
        }
    }

    /// Cancel any in-flight auto-start ramp and clear its target. Idempotent — safe
    /// to call from the playback-stop and manual-speed paths whether or not a ramp
    /// is actually running.
    private func cancelRamp() {
        rampTask?.cancel()
        rampTask = nil
        rampTargetWpm = nil
    }

    // MARK: Cruise (hands-free autoplay)

    /// Double-tap the canvas to hand off: playback continues from the current
    /// word without a held thumb. Enterable from `ready` (start fresh) or
    /// `paused` (resume where you stopped).
    func enterCruise() {
        guard state == .paused || state == .ready else { return }
        reactivateIfCompleted()
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
        bumpRecenter()
        saveProgress()
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
        reactivateIfCompleted()
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
        bumpRecenter()
        saveProgress()
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
        // Leaving the foreground is a natural save point — bank the position now.
        saveProgress()
    }

    // MARK: Persistence & resume

    /// The current reading hand as the stored string ("left" / "right").
    private var handString: String { isLeftHanded ? "left" : "right" }

    /// The speed to persist as the read's resume cursor. While an auto-start ramp is
    /// climbing this is the ramp's *target* (the intended cruising speed), not the
    /// transient ramping band — so a pause or checkpoint mid-ramp never banks the
    /// slow opening WPM as the session's resume speed. Otherwise it's the live band.
    private var persistedWpm: Int { rampTargetWpm ?? wpm }

    /// Persist the resume cursor (position, speed, hand) for the current read. The
    /// hot path — called on every pause, scrub-release, background, and periodic
    /// checkpoint. A cheap single-row UPDATE; a no-op without a record or store.
    private func saveProgress() {
        guard let store, let id = currentReadId, !tokens.isEmpty else { return }
        try? store.updatePosition(id: id, tokenIndex: currentIndex, wpm: persistedWpm,
                                  readingHand: handString, updatedAt: Date())
    }

    /// The "no fresh clipboard" entry decision: offer the most recent resumable
    /// read if there is one, otherwise drop to the calm paste screen.
    private func offerResumeOrIdle() {
        refreshPendingResume()
        if pendingResume == nil { state = .idle }
    }

    /// Re-read the resume candidate from the store. Sets `pendingResume` to the most
    /// recent active read, or `nil` if there's nothing to resume.
    private func refreshPendingResume() {
        pendingResume = (try? store?.mostRecentActive()) ?? nil
    }

    /// Reload the library list from the store (newest-touched first). Called when
    /// `ResumeView` appears and after a delete, so the displayed list tracks disk.
    func refreshRecents() {
        recents = (try? store?.recentReads(limit: 20)) ?? []
    }

    /// Open a stored read: restore its body, speed, and reading hand, and arm the
    /// reader. Where it opens depends on whether the read is *finished*:
    ///
    /// - **Unfinished** → resume from the saved token (existing behavior). The touch
    ///   is banked so the read floats to the top of recents.
    /// - **Finished** → reopen at the *beginning* ("read again"), not the end screen
    ///   — tapping a completed item almost always means "read this again," not "show
    ///   me the finish line." The completed record is left untouched on open (so the
    ///   history isn't erased just by peeking); it reactivates from 0 only once the
    ///   user actually starts reading again (see `reactivateIfCompleted`).
    ///
    /// Normally a deliberate resume waits for the thumb or a double-tap, but the
    /// global "start in cruise" preference applies to every entry into reading, so
    /// when it's on a resume streams hands-free too. Reuses the existing record (no
    /// duplicates). A no-op if the body has gone empty.
    func resume(_ item: ReadItem) {
        cancelPlayback()
        let toks = Tokenizer.tokenize(item.body)
        guard !toks.isEmpty else { return }
        pendingResume = nil
        hasPendingClipboard = false
        canReturnToReads = false
        loadedText = item.body
        tokens = toks
        currentReadId = item.id
        let finished = item.status == .completed || item.completedAt != nil
            || item.lastTokenIndex >= toks.count - 1
        // Finished reads reopen at the top; unfinished resume from their saved spot.
        currentIndex = finished ? 0 : min(max(0, item.lastTokenIndex), toks.count - 1)
        band = SpeedBand(wpm: item.lastWpm)
        isLeftHanded = (item.readingHand == "left")
        state = .ready
        // Unfinished: bank the touch so the read floats to the top of recents.
        // Finished: leave the completed record exactly as-is until the user actually
        // starts reading again, so merely reopening never rewrites its position or
        // erases the completion.
        if !finished { saveProgress() }
        if startInCruise { enterCruise() }
    }

    /// Dismiss the resume/library screen to read something new — drops to the New
    /// Text (paste) surface (and its clipboard pickup), leaving stored reads
    /// untouched on disk. We came *from* Reads, so New Text can offer a way back.
    func dismissResume() {
        pendingResume = nil
        state = .idle
        canReturnToReads = true
    }

    /// Back out of the New Text create screen to the Reads home. Re-offers the most
    /// recent resumable read, which routes `ContentView` back to the library. Only
    /// invoked when `canReturnToReads` is set (we got here from Reads), so the
    /// candidate is still on disk and the return always lands somewhere.
    func returnToReads() {
        refreshPendingResume()
        canReturnToReads = false
    }

    /// Rename a stored read from the library. Empty/whitespace falls back to a
    /// title derived from the body, so a read never ends up blank. Refloats nothing
    /// on its own beyond the `updated_at` bump the rename writes.
    func renameRead(_ item: ReadItem, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? ReadItem.deriveTitle(from: item.body) : trimmed
        try? store?.updateReadTitle(id: item.id, title: newTitle, updatedAt: Date())
        refreshRecents()
        // Keep the resume candidate's title in sync if it was the one renamed.
        if pendingResume?.id == item.id { refreshPendingResume() }
    }

    /// Forget a read entirely from the library. If it was the resume candidate,
    /// the next-most-recent takes its place (or the paste screen, if none remain).
    func deleteRead(_ item: ReadItem) {
        try? store?.deleteReadItem(id: item.id)
        refreshRecents()
        if pendingResume?.id == item.id { offerResumeOrIdle() }
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
            // Periodic checkpoint (~every 50 words ≈ 5–8s while cruising) so a crash
            // or force-quit mid-read never loses more than a few seconds of position.
            if currentIndex % 50 == 0 { saveProgress() }
        } else {
            finish()
        }
    }

    private func finish() {
        cancelPlayback()
        state = .completed
        haptics.tick(.finish)
        if let store, let id = currentReadId, !tokens.isEmpty {
            try? store.markCompleted(id: id, tokenIndex: tokens.count - 1, completedAt: Date())
        }
    }

    private func cancelPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        // Stopping the engine (pause, scrub, background, finish, new load) always
        // ends any auto-start ramp too — it only makes sense while reading forward.
        // Restart-in-place after a flick uses `startPlayback` directly, not this, so
        // a flick leaves the ramp climbing.
        cancelRamp()
    }
}
