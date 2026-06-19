import Foundation

/// Where the reader is in its lifecycle. Modeled as an explicit state machine
/// to keep gesture handling unambiguous.
public enum ReaderState: Sendable {
    case idle          // no text loaded — show paste screen
    case ready         // text loaded, waiting for the first hold
    case precisionHeld // actively advancing while the thumb is held
    case paused        // thumb released mid-read
    case cruisePlaying // hands-free autoplay (entered by double-tapping the canvas)
    case completed     // reached the end of the text
}

/// How the user drives playback. v1 ships `precisionHeld`; `cruise` is wired
/// for a later slice.
public enum ReadingMode: Sendable {
    case precisionHeld // hold to read, release to pause
    case cruise        // double-tap autoplay, tap to pause
}
