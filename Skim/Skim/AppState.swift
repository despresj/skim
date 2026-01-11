import SwiftUI
import Combine

// MARK: - Keyboard Shortcuts

struct AppKeyboardShortcut: Codable, Equatable {
    var key: String
    var useCommand: Bool
    var useShift: Bool
    var useOption: Bool

    var displayString: String {
        var parts: [String] = []
        if useCommand { parts.append("⌘") }
        if useOption { parts.append("⌥") }
        if useShift { parts.append("⇧") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    static let loadAndPlay = AppKeyboardShortcut(key: "l", useCommand: true, useShift: false, useOption: false)
    static let loadClipboard = AppKeyboardShortcut(key: "v", useCommand: true, useShift: false, useOption: false)
    static let playPause = AppKeyboardShortcut(key: " ", useCommand: false, useShift: false, useOption: false)
    static let speedUp = AppKeyboardShortcut(key: "=", useCommand: true, useShift: false, useOption: false)
    static let slowDown = AppKeyboardShortcut(key: "-", useCommand: true, useShift: false, useOption: false)
}

struct ShortcutSettings: Codable {
    var loadAndPlay: AppKeyboardShortcut
    var loadClipboard: AppKeyboardShortcut
    var playPause: AppKeyboardShortcut
    var speedUp: AppKeyboardShortcut
    var slowDown: AppKeyboardShortcut

    static let defaults = ShortcutSettings(
        loadAndPlay: .loadAndPlay,
        loadClipboard: .loadClipboard,
        playPause: .playPause,
        speedUp: .speedUp,
        slowDown: .slowDown
    )
}

// MARK: - Recent Texts

struct RecentText: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let preview: String
    let wordCount: Int
    let date: Date
    let text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.wordCount = text.split(separator: " ").count
        self.date = Date()

        // Generate title from first few words
        let words = text.split(separator: " ").prefix(5)
        self.title = words.joined(separator: " ") + (words.count >= 5 ? "…" : "")

        // Preview is first ~100 chars
        let previewEnd = text.index(text.startIndex, offsetBy: min(100, text.count))
        self.preview = String(text[..<previewEnd]).replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Reader State Machine

enum ReaderState {
    case empty      // No text loaded
    case ready      // Text loaded, at start, not playing
    case playing    // Actively displaying words
    case paused     // Was playing, now stopped
    case finished   // Reached end of text
}

// MARK: - Speed Presets

enum SpeedPreset: UInt32, CaseIterable {
    case slow = 200
    case normal = 300
    case fast = 450
    case veryFast = 600
    case speed = 800
    case insane = 1000

    var label: String {
        switch self {
        case .slow: return "Slow (200)"
        case .normal: return "Normal (300)"
        case .fast: return "Fast (450)"
        case .veryFast: return "Very Fast (600)"
        case .speed: return "Speed (800)"
        case .insane: return "Insane (1000)"
        }
    }
}

// MARK: - Punctuation Pause Presets

enum PunctuationPreset: String, CaseIterable, Codable {
    case off = "off"
    case light = "light"
    case normal = "normal"
    case heavy = "heavy"

    var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        }
    }

    var description: String {
        switch self {
        case .off: return "No pauses at punctuation"
        case .light: return "Brief pauses at sentence ends"
        case .normal: return "Natural reading rhythm"
        case .heavy: return "Extended pauses for comprehension"
        }
    }

    var multiplier: Float {
        switch self {
        case .off: return 0.0 // Will disable pauses entirely
        case .light: return 0.6
        case .normal: return 1.0
        case .heavy: return 1.5
        }
    }

    var enablesPauses: Bool {
        self != .off
    }
}

// MARK: - Speed Zone (Comprehension Safety - Research-Based)

enum SpeedZone {
    case safe       // 200-350 WPM - Research-supported optimal comprehension
    case caution    // 350-450 WPM - Mild comprehension reduction
    case risky      // 450+ WPM - Significant comprehension loss

    static func forWPM(_ wpm: UInt32) -> SpeedZone {
        switch wpm {
        case 0...350: return .safe
        case 351...450: return .caution
        default: return .risky
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .caution: return .yellow
        case .risky: return .red
        }
    }

    var label: String {
        switch self {
        case .safe: return "Optimal"
        case .caution: return "Fast"
        case .risky: return "Speed"
        }
    }

    var description: String {
        switch self {
        case .safe: return "Best comprehension"
        case .caution: return "Some comprehension loss"
        case .risky: return "Skimming mode"
        }
    }
}

// MARK: - Session Statistics

struct ReadingSession {
    var startTime: Date = Date()
    var wordsRead: Int = 0
    var activeReadingSeconds: Double = 0
    var lastActiveTime: Date?

    var averageWPM: Int {
        guard activeReadingSeconds > 10 else { return 0 }
        return Int(Double(wordsRead) / (activeReadingSeconds / 60.0))
    }

    var formattedDuration: String {
        let minutes = Int(activeReadingSeconds) / 60
        let seconds = Int(activeReadingSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var shouldSuggestBreak: Bool {
        activeReadingSeconds >= 20 * 60 // 20 minutes
    }
}

struct LifetimeStats: Codable {
    var totalWordsRead: Int = 0
    var totalReadingSeconds: Double = 0
    var sessionsCompleted: Int = 0
    var textsCompleted: Int = 0

    var formattedTotalTime: String {
        let hours = Int(totalReadingSeconds) / 3600
        let minutes = (Int(totalReadingSeconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

// MARK: - Position Recovery

struct RecoverablePosition: Codable {
    let text: String
    let title: String
    let wordIndex: UInt32
    let wordCount: UInt32
    let timestamp: Date
    let wpm: UInt32

    var isValid: Bool {
        // Consider positions older than 24 hours as stale
        Date().timeIntervalSince(timestamp) < 86400
    }

    var progressPercent: Int {
        guard wordCount > 0 else { return 0 }
        return Int((Float(wordIndex) / Float(wordCount)) * 100)
    }

    var summary: String {
        let remaining = wordCount - wordIndex
        return "\(title) • \(progressPercent)% • \(remaining) words left"
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    private var reader: Skim

    // Core state
    @Published var currentWord: WordToken?
    @Published var isPlaying: Bool = false
    @Published var progress: Float = 0
    @Published var hasText: Bool = false
    @Published var wordCount: UInt32 = 0

    // Window
    @Published var windowWidth: CGFloat = 1800
    @Published var windowHeight: CGFloat = 1100

    // Review trail (last N words for context recovery)
    @Published var showReviewTrail: Bool = true {
        didSet { UserDefaults.standard.set(showReviewTrail, forKey: "showReviewTrail") }
    }
    @Published var reviewTrailLength: Int = 4
    @Published private(set) var recentWords: [String] = []

    // Display settings
    @Published var fontScale: Double = 1.0 {
        didSet { UserDefaults.standard.set(fontScale, forKey: "fontScale") }
    }
    @Published var reducedMotion: Bool = false {
        didSet { UserDefaults.standard.set(reducedMotion, forKey: "reducedMotion") }
    }

    // Playback settings
    @Published var wpm: UInt32 = 400 {
        didSet {
            updateConfig()
            saveAppConfig()
        }
    }
    @Published var punctuationPreset: PunctuationPreset = .normal {
        didSet {
            updateConfig()
            savePunctuationPreset()
        }
    }

    @Published var interWordDelayMs: UInt32 = 10 {
        didSet { saveAppConfig() }
    }

    @Published var shortcuts: ShortcutSettings = .defaults {
        didSet { saveShortcuts() }
    }

    @Published var recentTexts: [RecentText] = []
    @Published var currentTextTitle: String = ""

    // Session tracking
    @Published var currentSession: ReadingSession = ReadingSession()
    @Published var lifetimeStats: LifetimeStats = LifetimeStats()
    @Published var showBreakReminder: Bool = false
    @Published var breakReminderDismissed: Bool = false

    // Position preservation for crash recovery
    private var currentTextForRecovery: String?
    @Published var hasRecoverablePosition: Bool = false
    @Published var recoverablePositionInfo: String = ""

    // Context overlay ("Where Am I?")
    @Published var showContextOverlay: Bool = false

    private var playbackTask: Task<Void, Never>?
    private var wasPlayingBeforeScrub: Bool = false
    private var sessionTimer: Timer?
    private var positionSaveTimer: Timer?

    // MARK: - Computed State

    var state: ReaderState {
        if !hasText {
            return .empty
        }
        if isPlaying {
            return .playing
        }
        if let word = currentWord {
            if word.index == 0 && progress == 0 {
                return .ready
            }
            if word.index >= wordCount - 1 {
                return .finished
            }
        }
        return .paused
    }

    var currentIndex: UInt32 {
        currentWord?.index ?? 0
    }

    var canGoBack: Bool {
        hasText && currentIndex > 0
    }

    var canGoForward: Bool {
        hasText && currentIndex < wordCount - 1
    }

    var formattedPosition: String {
        guard hasText else { return "" }
        let current = currentIndex + 1
        return "\(current) / \(wordCount)"
    }

    var primaryActionLabel: String {
        switch state {
        case .empty: return "Paste from Clipboard"
        case .ready: return "Start Reading"
        case .playing: return "Pause"
        case .paused: return "Resume"
        case .finished: return "Read Again"
        }
    }

    var speedZone: SpeedZone {
        SpeedZone.forWPM(wpm)
    }

    var estimatedTimeRemaining: String {
        guard hasText, wordCount > 0, wpm > 0 else { return "" }
        let remainingWords = Int(wordCount) - Int(currentIndex)
        let minutes = Double(remainingWords) / Double(wpm)
        if minutes < 1 {
            return "< 1 min left"
        }
        return "\(Int(ceil(minutes))) min left"
    }

    // MARK: - Init

    init() {
        self.reader = Skim()
        loadAppConfig()
        loadShortcuts()
        loadRecentTexts()
        loadDisplaySettings()
        loadPunctuationPreset()
        loadLifetimeStats()
        checkForRecoverablePosition()
        updateConfig()
        startPositionAutoSave()
    }

    deinit {
        positionSaveTimer?.invalidate()
        sessionTimer?.invalidate()
    }

    private func loadLifetimeStats() {
        if let data = UserDefaults.standard.data(forKey: "lifetimeStats"),
           let stats = try? JSONDecoder().decode(LifetimeStats.self, from: data) {
            self.lifetimeStats = stats
        }
    }

    private func saveLifetimeStats() {
        if let data = try? JSONEncoder().encode(lifetimeStats) {
            UserDefaults.standard.set(data, forKey: "lifetimeStats")
        }
    }

    private func loadDisplaySettings() {
        if UserDefaults.standard.object(forKey: "showReviewTrail") != nil {
            showReviewTrail = UserDefaults.standard.bool(forKey: "showReviewTrail")
        }
        if UserDefaults.standard.object(forKey: "fontScale") != nil {
            fontScale = UserDefaults.standard.double(forKey: "fontScale")
        }
        if UserDefaults.standard.object(forKey: "reducedMotion") != nil {
            reducedMotion = UserDefaults.standard.bool(forKey: "reducedMotion")
        }
    }

    // MARK: - Position Recovery

    private func startPositionAutoSave() {
        // Save position every 5 seconds during active reading
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveCurrentPosition()
            }
        }
    }

    private func saveCurrentPosition() {
        guard hasText, let text = currentTextForRecovery, wordCount > 0 else { return }
        // Only save if we've made some progress
        guard currentIndex > 0 else { return }

        let position = RecoverablePosition(
            text: text,
            title: currentTextTitle,
            wordIndex: currentIndex,
            wordCount: wordCount,
            timestamp: Date(),
            wpm: wpm
        )

        if let data = try? JSONEncoder().encode(position) {
            UserDefaults.standard.set(data, forKey: "recoverablePosition")
        }
    }

    private func checkForRecoverablePosition() {
        guard let data = UserDefaults.standard.data(forKey: "recoverablePosition"),
              let position = try? JSONDecoder().decode(RecoverablePosition.self, from: data),
              position.isValid else {
            clearRecoverablePosition()
            return
        }

        hasRecoverablePosition = true
        recoverablePositionInfo = position.summary
    }

    func recoverPosition() {
        guard let data = UserDefaults.standard.data(forKey: "recoverablePosition"),
              let position = try? JSONDecoder().decode(RecoverablePosition.self, from: data) else {
            return
        }

        // Load the text
        loadText(position.text, addToRecent: false)
        currentTextTitle = position.title

        // Seek to saved position
        if let word = reader.seek_to(position.wordIndex) {
            currentWord = word
            progress = reader.get_progress_percent()
        }

        // Restore WPM if different
        if position.wpm != wpm {
            wpm = position.wpm
        }

        clearRecoverablePosition()
    }

    func dismissRecoverablePosition() {
        clearRecoverablePosition()
    }

    private func clearRecoverablePosition() {
        hasRecoverablePosition = false
        recoverablePositionInfo = ""
        UserDefaults.standard.removeObject(forKey: "recoverablePosition")
    }

    private func loadShortcuts() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let shortcuts = try? JSONDecoder().decode(ShortcutSettings.self, from: data) {
            self.shortcuts = shortcuts
        }
    }

    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: "shortcuts")
        }
    }

    private func loadRecentTexts() {
        if let data = UserDefaults.standard.data(forKey: "recentTexts"),
           let texts = try? JSONDecoder().decode([RecentText].self, from: data) {
            self.recentTexts = texts
        }
    }

    private func saveRecentTexts() {
        // Keep only last 10
        let textsToSave = Array(recentTexts.prefix(10))
        if let data = try? JSONEncoder().encode(textsToSave) {
            UserDefaults.standard.set(data, forKey: "recentTexts")
        }
    }

    private func addToRecentTexts(_ text: String) {
        let recent = RecentText(text: text)
        // Remove duplicates (same text content)
        recentTexts.removeAll { $0.text == text }
        // Add to front
        recentTexts.insert(recent, at: 0)
        // Trim to 10
        if recentTexts.count > 10 {
            recentTexts = Array(recentTexts.prefix(10))
        }
        currentTextTitle = recent.title
        saveRecentTexts()
    }

    private func loadAppConfig() {
        let config = load_config()
        windowWidth = CGFloat(config.window_width)
        windowHeight = CGFloat(config.window_height)
        wpm = config.wpm
        interWordDelayMs = config.inter_word_delay_ms
    }

    private func saveAppConfig() {
        let config = AppConfig(
            window_width: UInt32(windowWidth),
            window_height: UInt32(windowHeight),
            wpm: wpm,
            inter_word_delay_ms: interWordDelayMs
        )
        _ = save_config(config)
    }

    // MARK: - Loading

    func loadText(_ text: String, addToRecent: Bool = true) {
        guard !text.isEmpty else { return }
        pause()
        reader.load_text(text)
        wordCount = reader.get_word_count()
        hasText = wordCount > 0
        currentWord = reader.get_current_word()
        progress = 0
        recentWords = [] // Clear review trail
        currentTextForRecovery = text // Store for position recovery
        if addToRecent && hasText {
            addToRecentTexts(text)
        }
    }

    func loadFromClipboard() {
        guard let text = reader.read_clipboard() else { return }
        loadText(text.toString())
    }

    func loadFromFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        loadText(text)
    }

    func loadFromRecent(_ recent: RecentText) {
        loadText(recent.text, addToRecent: false)
        // Move to front of recents
        recentTexts.removeAll { $0.id == recent.id }
        recentTexts.insert(recent, at: 0)
        currentTextTitle = recent.title
        saveRecentTexts()
    }

    func clearRecentTexts() {
        recentTexts.removeAll()
        saveRecentTexts()
    }

    func loadAndPlay() {
        loadFromClipboard()
        play()
    }

    func loadSampleText() {
        let sampleText = """
        Speed reading is a collection of methods for increasing reading speed without substantially reducing comprehension. The most common techniques include minimizing subvocalization, using a pointer or pacer, and expanding peripheral vision to take in more words at once.

        Research suggests that average reading speed is around 200-250 words per minute, while trained speed readers can achieve 400-700 words per minute with good comprehension. However, claims of reading thousands of words per minute typically come with significant comprehension trade-offs.

        The key to effective speed reading is finding the optimal balance between speed and understanding for your specific purpose. For casual reading or skimming, higher speeds work well. For complex material requiring deep understanding, slower speeds with active engagement produce better results.

        This sample text contains approximately 120 words and should take about 20-30 seconds to read at a comfortable pace. Use it to calibrate your preferred reading speed and get familiar with the controls.

        Try adjusting the speed with Cmd+Plus and Cmd+Minus, or use the preset shortcuts: Cmd+1 for comfortable reading, Cmd+2 for brisk reading, and Cmd+3 for fast skimming. Press Space to pause and resume at any time.
        """
        loadText(sampleText, addToRecent: false)
        currentTextTitle = "Sample Text"
    }

    func rewindSeconds(_ seconds: Double) {
        guard hasText, wpm > 0 else { return }
        let wordsPerSecond = Double(wpm) / 60.0
        let wordsToRewind = max(Int(wordsPerSecond * seconds), 5)
        replayLastWords(wordsToRewind)
    }

    func getContextWords(count: Int = 20) -> [String] {
        guard hasText else { return [] }
        var words: [String] = []
        let startIdx = max(0, Int(currentIndex) - count)
        let endIdx = Int(currentIndex)

        for i in startIdx..<endIdx {
            if let word = reader.seek_to(UInt32(i)) {
                words.append(word.text.toString())
            }
        }

        // Restore position
        _ = reader.seek_to(currentIndex)
        return words
    }

    // MARK: - Playback Control

    func play() {
        guard hasText, !isPlaying else { return }

        // If finished, restart
        if state == .finished {
            restart()
        }

        isPlaying = true
        startSessionTimer()
        schedulePlayback()
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        stopSessionTimer()
    }

    private func startSessionTimer() {
        currentSession.lastActiveTime = Date()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSessionTime()
            }
        }
    }

    private func stopSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        if let lastActive = currentSession.lastActiveTime {
            currentSession.activeReadingSeconds += Date().timeIntervalSince(lastActive)
            currentSession.lastActiveTime = nil
        }
        // Update lifetime stats
        lifetimeStats.totalReadingSeconds = currentSession.activeReadingSeconds
        saveLifetimeStats()
    }

    private func updateSessionTime() {
        guard isPlaying, let lastActive = currentSession.lastActiveTime else { return }
        let elapsed = Date().timeIntervalSince(lastActive)
        currentSession.activeReadingSeconds += elapsed
        currentSession.lastActiveTime = Date()

        // Check for break reminder (every 20 minutes)
        if currentSession.shouldSuggestBreak && !breakReminderDismissed {
            showBreakReminder = true
        }
    }

    func dismissBreakReminder() {
        showBreakReminder = false
        breakReminderDismissed = true
    }

    func takeBreak() {
        pause()
        showBreakReminder = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func primaryAction() {
        switch state {
        case .empty:
            loadFromClipboard()
        case .ready, .paused:
            play()
        case .playing:
            pause()
        case .finished:
            restart()
            play()
        }
    }

    func restart() {
        pause()
        reader.reset()
        currentWord = reader.get_current_word()
        progress = 0
        recentWords = []
        // Reset session for new reading
        currentSession = ReadingSession()
        breakReminderDismissed = false
    }

    // MARK: - Replay (Regression Support - Research Shows This Is Critical)

    /// Replay the last N words for comprehension recovery
    func replayLastWords(_ count: Int = 5) {
        guard hasText, currentIndex > 0 else { return }
        let wasPlaying = isPlaying
        pause()

        // Go back N words or to start
        let targetIndex = max(0, Int(currentIndex) - count)
        seek(to: UInt32(targetIndex))
        recentWords = [] // Clear trail since we're reviewing

        // Resume if was playing
        if wasPlaying {
            play()
        }
    }

    /// Replay current sentence from the beginning
    func replaySentence() {
        guard hasText, wordCount > 0 else { return }
        let wasPlaying = isPlaying
        pause()

        var idx = Int(currentIndex)

        // Find start of current sentence (after previous . ! ?)
        while idx > 0 {
            idx -= 1
            if let word = reader.seek_to(UInt32(idx)) {
                let text = word.text.toString()
                if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
                    // Found end of previous sentence, start from next word
                    seek(to: UInt32(idx + 1))
                    recentWords = []
                    if wasPlaying { play() }
                    return
                }
            }
        }

        // No sentence boundary found, go to start
        seek(to: 0)
        recentWords = []
        if wasPlaying { play() }
    }

    // MARK: - Navigation

    func skipBack() {
        guard canGoBack else { return }
        if let word = reader.go_back() {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    func skipForward() {
        guard canGoForward else { return }
        if let word = reader.advance() {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    func jumpToStart() {
        pause()
        reader.reset()
        currentWord = reader.get_current_word()
        progress = 0
    }

    func jumpToEnd() {
        guard wordCount > 0 else { return }
        pause()
        if let word = reader.seek_to(wordCount - 1) {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    func seek(to index: UInt32) {
        if let word = reader.seek_to(index) {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    // Sentence navigation - jump to previous/next sentence boundary
    func previousSentence() {
        guard hasText, wordCount > 0, let current = currentWord else { return }
        var idx = Int(current.index)

        // Skip back past current word
        if idx > 0 { idx -= 1 }

        // Find previous sentence end (. ! ?)
        while idx > 0 {
            if let word = reader.seek_to(UInt32(idx)) {
                let text = word.text.toString()
                if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
                    // Found end of previous sentence, go to start of next (current) sentence
                    let nextIdx = idx + 1
                    if nextIdx < Int(wordCount) {
                        seek(to: UInt32(nextIdx))
                    } else {
                        seek(to: UInt32(idx))
                    }
                    return
                }
            }
            idx -= 1
        }

        // No sentence boundary found, go to start
        seek(to: 0)
    }

    func nextSentence() {
        guard hasText, wordCount > 0, let current = currentWord else { return }
        var idx = Int(current.index)
        let lastIndex = Int(wordCount) - 1

        // Find next sentence end
        while idx < lastIndex {
            if let word = reader.seek_to(UInt32(idx)) {
                let text = word.text.toString()
                if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
                    // Found end of sentence, go to start of next
                    let nextIdx = idx + 1
                    if nextIdx < Int(wordCount) {
                        seek(to: UInt32(nextIdx))
                        return
                    }
                }
            }
            idx += 1
        }

        // No more sentences, go to end
        if wordCount > 0 {
            seek(to: wordCount - 1)
        }
    }

    // MARK: - Scrubbing

    func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    func scrub(to progress: Float) {
        guard wordCount > 0 else { return }
        let maxIndex = wordCount - 1
        let index = UInt32(Float(maxIndex) * progress)
        seek(to: index)
    }

    func endScrubbing() {
        // Optionally resume playback
        // if wasPlayingBeforeScrub { play() }
    }

    // MARK: - Speed Control

    func speedUp() {
        if wpm < 1000 {
            wpm = min(1000, wpm + 50)
        }
    }

    func slowDown() {
        if wpm > 100 {
            wpm = max(100, wpm - 50)
        }
    }

    func setPreset(_ preset: SpeedPreset) {
        wpm = preset.rawValue
    }

    // MARK: - Private

    private func schedulePlayback() {
        guard let word = currentWord, isPlaying else { return }

        // Word display time + inter-word pause
        let delayMs = word.display_time_ms + interWordDelayMs
        playbackTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            advanceToNextWord()
        }
    }

    private func advanceToNextWord() {
        // Add current word to review trail before advancing
        if showReviewTrail, let word = currentWord {
            let wordText = word.text.toString()
            recentWords.append(wordText)
            if recentWords.count > reviewTrailLength {
                recentWords.removeFirst()
            }
        }

        // Track words read
        currentSession.wordsRead += 1
        lifetimeStats.totalWordsRead += 1

        if let next = reader.advance() {
            currentWord = next
            progress = reader.get_progress_percent()
            schedulePlayback()
        } else {
            // Finished - stop and record completion
            isPlaying = false
            playbackTask = nil
            stopSessionTimer()
            lifetimeStats.textsCompleted += 1
            lifetimeStats.sessionsCompleted += 1
            saveLifetimeStats()

            // Clear recovery position - user successfully finished
            clearRecoverablePosition()

            // Keep at end for "finished" state display
            // Don't reset automatically - let user see they finished
        }
    }

    private func updateConfig() {
        let config = PlaybackConfig(
            wpm: wpm,
            pause_on_punctuation: punctuationPreset.enablesPauses,
            punctuation_multiplier: punctuationPreset.multiplier
        )
        reader.set_config(config)
    }

    private func savePunctuationPreset() {
        UserDefaults.standard.set(punctuationPreset.rawValue, forKey: "punctuationPreset")
    }

    private func loadPunctuationPreset() {
        if let rawValue = UserDefaults.standard.string(forKey: "punctuationPreset"),
           let preset = PunctuationPreset(rawValue: rawValue) {
            punctuationPreset = preset
        }
    }
}

// Shared holder for app state access from NSView
class AppStateHolder {
    static let shared = AppStateHolder()
    var appState: AppState?
}
