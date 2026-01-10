import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    private var reader: SpeedReader

    @Published var currentWord: WordToken?
    @Published var isPlaying: Bool = false
    @Published var progress: Float = 0
    @Published var hasText: Bool = false
    @Published var wordCount: UInt32 = 0

    @Published var wpm: UInt32 = 300 {
        didSet { updateConfig() }
    }
    @Published var pauseOnPunctuation: Bool = true {
        didSet { updateConfig() }
    }

    private var playbackTask: Task<Void, Never>?

    init() {
        self.reader = SpeedReader()
        updateConfig()
    }

    func loadFromClipboard() {
        guard let text = reader.read_clipboard() else { return }
        reader.load_text(text.toString())
        wordCount = reader.get_word_count()
        hasText = wordCount > 0
        currentWord = reader.get_current_word()
        progress = 0
    }

    func play() {
        guard hasText, !isPlaying else { return }
        isPlaying = true
        schedulePlayback()
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func restart() {
        pause()
        reader.reset()
        currentWord = reader.get_current_word()
        progress = 0
    }

    func skipBack() {
        if let word = reader.go_back() {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    func skipForward() {
        if let word = reader.advance() {
            currentWord = word
            progress = reader.get_progress_percent()
        }
    }

    private func schedulePlayback() {
        guard let word = currentWord, isPlaying else { return }

        let delayMs = word.display_time_ms
        playbackTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
             advanceToNextWord()
        }
    }

    private func advanceToNextWord() {
        if let next = reader.advance() {
            currentWord = next
            progress = reader.get_progress_percent()
            schedulePlayback()
        } else {
            isPlaying = false
            playbackTask = nil
        }
    }

    private func updateConfig() {
        let config = PlaybackConfig(
            wpm: wpm,
            pause_on_punctuation: pauseOnPunctuation,
            punctuation_multiplier: 1.5
        )
        reader.set_config(config)
    }
}
