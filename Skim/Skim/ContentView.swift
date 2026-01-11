import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragOver = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Reader Surface (center - takes all available space)
                ReaderSurface()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Transport Bar (bottom)
                TransportBar()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
            }

            // Break reminder overlay
            if appState.showBreakReminder {
                BreakReminderOverlay()
            }
        }
        .frame(width: appState.windowWidth, height: appState.windowHeight)
        .overlay(dragOverlay)
        .onDrop(of: [.text, .plainText, .fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .background(KeyboardHandler())
        .toolbar {
            AppToolbar()
        }
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragOver {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.1))
                .padding(8)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Try plain text first
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            appState.loadText(text)
                        }
                    } else if let text = item as? String {
                        Task { @MainActor in
                            appState.loadText(text)
                        }
                    }
                }
                return true
            }

            // Try file URL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            appState.loadFromFile(url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - Toolbar

struct AppToolbar: ToolbarContent {
    @EnvironmentObject var appState: AppState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Paste button
            Button {
                appState.loadFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste text from clipboard (⌘V)")

            // Recent texts menu
            if !appState.recentTexts.isEmpty {
                Menu {
                    ForEach(appState.recentTexts) { recent in
                        Button {
                            appState.loadFromRecent(recent)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(recent.title)
                                Text("\(recent.wordCount) words")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    Button("Clear Recent Texts", role: .destructive) {
                        appState.clearRecentTexts()
                    }
                } label: {
                    Label("Recent", systemImage: "clock")
                }
                .help("Recent texts")
            }

            Divider()

            // Speed control with zone indicator
            HStack(spacing: 8) {
                Button {
                    appState.slowDown()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Slower (⌘-)")

                Menu {
                    // Speed zone info at top
                    Section {
                        Label(appState.speedZone.description, systemImage: "brain.head.profile")
                    }

                    Divider()

                    ForEach(SpeedPreset.allCases, id: \.rawValue) { preset in
                        Button(preset.label) {
                            appState.setPreset(preset)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        // Speed zone indicator dot
                        Circle()
                            .fill(appState.speedZone.color)
                            .frame(width: 8, height: 8)

                        Text("\(appState.wpm)")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                .help("\(appState.speedZone.label): \(appState.speedZone.description)")

                Button {
                    appState.speedUp()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Faster (⌘+)")
            }

            // Session time (when reading)
            if appState.hasText && appState.currentSession.activeReadingSeconds > 0 {
                Divider()

                Text(appState.currentSession.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Reading time this session")
            }
        }
    }
}

// MARK: - Reader Surface

struct ReaderSurface: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            if appState.state == .empty {
                EmptyStateView()
            } else {
                WordDisplayView(word: appState.currentWord)
            }

            // Context overlay (shown when holding H)
            if appState.showContextOverlay {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                ContextOverlayView(contextWords: appState.getContextWords())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 32) {
            // Recovery banner if available
            if appState.hasRecoverablePosition {
                RecoveryBanner()
            }

            Image(systemName: "text.word.spacing")
                .font(.system(size: 80))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("Skim")
                    .font(.system(size: 48, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Read faster without losing your place")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }

            // Primary actions
            HStack(spacing: 16) {
                Button {
                    appState.loadFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.title3)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    openFilePicker()
                } label: {
                    Label("Open", systemImage: "folder")
                        .font(.title3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    appState.loadSampleText()
                } label: {
                    Label("Sample", systemImage: "text.alignleft")
                        .font(.title3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Recent texts menu
            if !appState.recentTexts.isEmpty {
                Menu {
                    ForEach(appState.recentTexts) { recent in
                        Button(recent.title) {
                            appState.loadFromRecent(recent)
                        }
                    }
                } label: {
                    Label("Recent", systemImage: "clock")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Keyboard hints
            VStack(spacing: 4) {
                Text("⌘V paste  •  ⌘⇧V paste & play  •  ⌘T sample")
                    .font(.caption)
                    .foregroundStyle(.quaternary)

                // Privacy statement
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("Text stays on your Mac")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(48)
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.loadFromFile(url)
        }
    }
}

// MARK: - Recovery Banner

struct RecoveryBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Resume Reading")
                    .font(.headline)
                Text(appState.recoverablePositionInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Resume") {
                appState.recoverPosition()
            }
            .buttonStyle(.borderedProminent)

            Button {
                appState.dismissRecoverablePosition()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.blue.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal, 32)
    }
}

// MARK: - Context Overlay ("Where Am I?")

struct ContextOverlayView: View {
    @EnvironmentObject var appState: AppState
    let contextWords: [String]

    var body: some View {
        VStack(spacing: 24) {
            Text("Where Am I?")
                .font(.headline)
                .foregroundStyle(.secondary)

            // Context text
            Text(contextWords.joined(separator: " "))
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
                .padding(.horizontal, 48)

            // Current word indicator (always reserve space to prevent jump)
            HStack {
                Image(systemName: "arrowtriangle.right.fill")
                    .foregroundStyle(Color.accentColor)
                Text(appState.currentWord?.text.toString() ?? " ")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.accentColor)
            }
            .opacity(appState.currentWord != nil ? 1 : 0)

            // Hints
            Text("Release H to continue  •  R to rewind")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 20)
    }
}

// MARK: - Word Display

struct WordDisplayView: View {
    let word: WordToken?
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 24) {
                // Title / source indicator
                if !appState.currentTextTitle.isEmpty {
                    Text(appState.currentTextTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // State indicator
                if appState.state == .finished {
                    Text("Finished")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Review trail (last N words for context)
                if appState.showReviewTrail && !appState.recentWords.isEmpty {
                    ReviewTrailView(words: appState.recentWords, fontScale: CGFloat(appState.fontScale))
                }

                // ORP-aligned word display
                ORPWordView(
                    text: word?.text.toString() ?? "",
                    containerWidth: geometry.size.width,
                    fontScale: CGFloat(appState.fontScale)
                )
                .contextMenu {
                    if let wordText = word?.text.toString() {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(wordText, forType: .string)
                        } label: {
                            Label("Copy Word", systemImage: "doc.on.doc")
                        }
                    }

                    Divider()

                    Button {
                        appState.restart()
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }

                    Divider()

                    Menu("Speed") {
                        ForEach(SpeedPreset.allCases, id: \.rawValue) { preset in
                            Button(preset.label) {
                                appState.setPreset(preset)
                            }
                        }
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Review Trail View

struct ReviewTrailView: View {
    let words: [String]
    var fontScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .foregroundStyle(.tertiary)
                    .opacity(opacity(for: index))
            }
        }
        .font(.system(size: 24 * fontScale, weight: .regular, design: .monospaced))
    }

    private func opacity(for index: Int) -> Double {
        // Fade from older to newer: older words are more faded
        let position = Double(index) / max(Double(words.count - 1), 1)
        return 0.3 + (position * 0.4) // Range from 0.3 to 0.7
    }
}

// MARK: - ORP (Optimal Recognition Point) Word View
// Research shows ORP is ~35% from start, NOT center (50%)
// Reference: Spritz research, Microsoft Reading Technologies

struct ORPWordView: View {
    let text: String
    let containerWidth: CGFloat
    var fontScale: CGFloat = 1.0

    private var fontSize: CGFloat { 100 * fontScale }

    // Calculate the focal point index (ORP) - Research-based positioning
    // ORP is approximately 35% from the start, not the center
    private var focalIndex: Int {
        guard !text.isEmpty else { return 0 }
        let length = text.count
        switch length {
        case 1: return 0           // Single char: focus on it
        case 2...3: return 0       // 2-3 chars: first char
        case 4...5: return 1       // 4-5 chars: second char
        case 6...7: return 2       // 6-7 chars: third char
        case 8...9: return 2       // 8-9 chars: third char
        case 10...13: return 3     // 10-13 chars: fourth char
        default: return min(4, length - 1) // 14+: fifth char max
        }
    }

    // Split word into three parts
    private var beforeFocal: String {
        guard !text.isEmpty else { return "" }
        return String(text.prefix(focalIndex))
    }

    private var focalChar: String {
        guard !text.isEmpty else { return "" }
        let idx = text.index(text.startIndex, offsetBy: focalIndex)
        return String(text[idx])
    }

    private var afterFocal: String {
        guard !text.isEmpty, focalIndex + 1 < text.count else { return "" }
        let startIdx = text.index(text.startIndex, offsetBy: focalIndex + 1)
        return String(text[startIdx...])
    }

    var body: some View {
        ZStack {
            // Focal point marker (subtle vertical guide)
            FocalPointMarker(scale: fontScale)

            // The word with calculated offset to anchor focal char at center
            HStack(spacing: 0) {
                Text(beforeFocal)
                    .foregroundStyle(.primary)
                Text(focalChar)
                    .foregroundStyle(Color.accentColor)
                Text(afterFocal)
                    .foregroundStyle(.primary)
            }
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .offset(x: calculateOffset())
        }
        .frame(width: containerWidth, height: fontSize * 1.4)
        .clipped()
    }

    private func calculateOffset() -> CGFloat {
        guard !text.isEmpty else { return 0 }

        // Measure character width for monospace font
        let charWidth = measureCharWidth()

        // Calculate where the focal point currently sits in the word
        // (distance from left edge of word to center of focal char)
        let focalCenterInWord = CGFloat(focalIndex) * charWidth + charWidth / 2

        // Target position is the center of the container
        let targetX = containerWidth / 2

        // Offset needed to move focal char to center
        // We need to shift the word so that focalCenterInWord aligns with targetX
        // The word's left edge starts at (containerWidth - wordWidth) / 2 when centered
        // But we want custom positioning, so we calculate from left edge at 0
        let wordWidth = CGFloat(text.count) * charWidth
        let wordLeftEdgeWhenCentered = (containerWidth - wordWidth) / 2

        // Current focal position when word is centered
        let currentFocalX = wordLeftEdgeWhenCentered + focalCenterInWord

        // Offset to move focal to exact center
        return targetX - currentFocalX
    }

    private func measureCharWidth() -> CGFloat {
        let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let attributes = [NSAttributedString.Key.font: nsFont]
        return "W".size(withAttributes: attributes).width
    }
}

// MARK: - Focal Point Marker

struct FocalPointMarker: View {
    var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Top marker
            Rectangle()
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 2 * scale, height: 16 * scale)

            Spacer()

            // Bottom marker
            Rectangle()
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 2 * scale, height: 16 * scale)
        }
        .frame(height: 140 * scale)
    }
}

// MARK: - Transport Bar

struct TransportBar: View {
    @EnvironmentObject var appState: AppState
    @State private var sliderValue: Float = 0
    @State private var isDragging: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            // Timeline slider with time estimate
            HStack(spacing: 16) {
                Text(appState.formattedPosition)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isDragging ? sliderValue : appState.progress },
                        set: { newValue in
                            sliderValue = newValue
                            appState.scrub(to: newValue)
                        }
                    ),
                    in: 0...1
                ) { editing in
                    if editing {
                        isDragging = true
                        appState.beginScrubbing()
                    } else {
                        isDragging = false
                        appState.endScrubbing()
                    }
                }
                .disabled(appState.state == .empty)

                // Time remaining estimate
                if !appState.estimatedTimeRemaining.isEmpty {
                    Text(appState.estimatedTimeRemaining)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 100, alignment: .trailing)
                }
            }

            // Transport controls
            HStack(spacing: 40) {
                // Replay last 5 words (regression support)
                Button {
                    appState.replayLastWords(5)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canGoBack)
                .help("Replay last 5 words (R)")

                // Jump to start
                Button(action: appState.jumpToStart) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(appState.state == .empty)
                .help("Jump to start (⌘←)")

                // Previous sentence
                Button(action: appState.previousSentence) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canGoBack)
                .help("Previous sentence (⌥←)")

                // Previous word
                Button(action: appState.skipBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canGoBack)
                .help("Previous word (←)")

                // Play/Pause
                Button(action: appState.primaryAction) {
                    Image(systemName: playPauseIcon)
                        .font(.system(size: 72))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(appState.primaryActionLabel + " (Space)")

                // Next word
                Button(action: appState.skipForward) {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canGoForward)
                .help("Next word (→)")

                // Next sentence
                Button(action: appState.nextSentence) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canGoForward)
                .help("Next sentence (⌥→)")

                // Jump to end
                Button(action: appState.jumpToEnd) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(appState.state == .empty)
                .help("Jump to end (⌘→)")
            }
        }
    }

    private var playPauseIcon: String {
        switch appState.state {
        case .empty:
            return "play.circle"
        case .ready:
            return "play.circle.fill"
        case .playing:
            return "pause.circle.fill"
        case .paused:
            return "play.circle.fill"
        case .finished:
            return "arrow.counterclockwise.circle.fill"
        }
    }
}

// MARK: - Keyboard Handler

struct KeyboardHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {}
}

class KeyboardView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let appState = AppStateHolder.shared.appState else {
            super.keyDown(with: event)
            return
        }

        // Ignore key repeat for context overlay
        if event.isARepeat && event.keyCode == 4 { return }

        let key = event.keyCode
        let hasCmd = event.modifierFlags.contains(.command)
        let hasOpt = event.modifierFlags.contains(.option)

        switch (key, hasCmd, hasOpt) {
        // Arrow keys
        case (123, false, false): // Left arrow
            appState.skipBack()
        case (124, false, false): // Right arrow
            appState.skipForward()
        case (123, false, true): // Option + Left
            appState.previousSentence()
        case (124, false, true): // Option + Right
            appState.nextSentence()
        case (123, true, false): // Cmd + Left
            appState.jumpToStart()
        case (124, true, false): // Cmd + Right
            appState.jumpToEnd()

        // Speed
        case (24, true, false): // Cmd + =
            appState.speedUp()
        case (27, true, false): // Cmd + -
            appState.slowDown()

        // Paste
        case (9, true, false): // Cmd + V
            appState.loadFromClipboard()

        // Rewind (R key - critical for comprehension)
        case (15, false, false): // R key
            appState.rewindSeconds(5.0)
        case (15, true, false): // Cmd + R - previous sentence
            appState.previousSentence()

        // Context overlay (H key - hold to see context)
        case (4, false, false): // H key
            appState.showContextOverlay = true

        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let appState = AppStateHolder.shared.appState else {
            super.keyUp(with: event)
            return
        }

        // Hide context overlay when H key is released
        if event.keyCode == 4 { // H key
            appState.showContextOverlay = false
        }
    }
}

// MARK: - Break Reminder Overlay

struct BreakReminderOverlay: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Reminder card
            VStack(spacing: 24) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Time for a Break!")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("You've been reading for \(appState.currentSession.formattedDuration).\nResearch shows breaks every 20 minutes reduce eye strain and improve retention.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)

                // Stats
                HStack(spacing: 32) {
                    VStack {
                        Text("\(appState.currentSession.wordsRead)")
                            .font(.title2.monospacedDigit())
                            .fontWeight(.semibold)
                        Text("words read")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if appState.currentSession.averageWPM > 0 {
                        VStack {
                            Text("\(appState.currentSession.averageWPM)")
                                .font(.title2.monospacedDigit())
                                .fontWeight(.semibold)
                            Text("avg WPM")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 16) {
                    Button("Take a Break") {
                        appState.takeBreak()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Continue Reading") {
                        appState.dismissBreakReminder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(AppState())
}
#endif
