# Casual RSVP Reader iPhone App Spec

## Working Name

**Skim**  
A clipboard-first iPhone reading app that turns copied text into a calm, one-thumb, high-flow reading experience.

---

## Product Statement

The app lets a user copy any text, open the app, and immediately read it through a polished Rapid Serial Visual Presentation (RSVP) interface. The experience should feel casual, natural, and physical: hold to read, release to pause, slide to adjust speed, flick to replay what was missed.

This is not primarily a “speed-reading app.” It is a **casual flow-reading app**.

North star:

> I copied something. My phone now reads it to my eyes.

---

## Target User

A user who casually reads articles, notes, emails, essays, pasted text, and long messages on an iPhone and wants a frictionless way to consume text without scrolling, scanning, or managing heavy UI.

Primary use cases:

- Reading copied articles
- Reading long messages or notes
- Reading while lounging one-handed
- Quickly consuming saved text
- Replaying missed thoughts without losing flow

Non-primary v1 use cases:

- Deep PDF reading
- Annotating academic papers
- Library management
- Cloud sync
- AI summarization
- Account-based workflows

---

## Core Problem Statements and Hand-in-Glove Fits

### 1. Problem: “I want to read something without setting anything up.”

Bad fit:

- Open app
- Choose document
- Paste text
- Hit load
- Choose speed
- Hit play

Hand-in-glove fit:

- User copies text
- Opens app
- Clipboard text is already loaded
- First word or phrase is waiting
- User holds thumb to begin

Default behavior:

```text
Open app → read clipboard → tokenize → ready to read
```

---

### 2. Problem: “I don’t want to manage controls while reading.”

Bad fit:

- Visible play button
- Pause button
- WPM slider
- Toolbar
- Settings icon
- Tab bar

Hand-in-glove fit:

The reading screen is sacred.

```text
Center: current word / phrase
Bottom: subtle progress line
Right side: invisible thumb control surface
Everything else: hidden
```

The app should feel controlled, not configured.

---

### 3. Problem: “Sometimes I miss a word and lose the thread.”

Bad fit:

- Back button moves one word
- Back button moves an arbitrary five seconds
- User has to think about indexes or time

Hand-in-glove fit:

The primary recovery action should match the user’s thought:

> Wait, what did that say?

Controls:

```text
Flick left: replay current sentence or phrase
Long flick left: replay previous sentence
Pause: reveal surrounding context
```

Semantic replay is more natural than time-based rewind.

---

### 4. Problem: “I want it to feel relaxing, not like a test.”

Bad fit:

- Aggressive WPM display
- Gamified stats
- Constant metrics
- Red alert colors
- Performance pressure

Hand-in-glove fit:

- Soft default speed
- Calm typography
- Minimal visual chrome
- Gentle haptics
- Hidden stats
- Phrase chunks by default

Default casual speed:

```text
275–325 WPM
```

---

### 5. Problem: “I want to control speed naturally.”

Bad fit:

- Tiny WPM slider
- Exact speed numbers as the main control
- Jittery continuous drag

Hand-in-glove fit:

Use speed bands.

```text
Slow: 225 WPM
Cruise: 300 WPM
Fast: 400 WPM
Sprint: 525 WPM
Blast: 650 WPM
```

User should feel:

```text
slower / faster
```

Not:

```text
set speed to 387 WPM
```

---

### 6. Problem: “I don’t want to hold my thumb forever.”

Bad fit:

- Hold-to-read only
- Constant physical engagement required

Hand-in-glove fit:

Support two modes:

```text
Precision mode:
  Hold = read
  Release = pause

Cruise mode:
  Double tap = autoplay
  Tap = pause
```

Precision mode is for dense material. Cruise mode is for lounging.

---

### 7. Problem: “I’m reading on my phone in real life.”

Real life means:

- Couch
- Bed
- One hand
- Tired eyes
- Interruptions
- Baby crying
- Walking around the house
- Half-attention reading

Bad fit:

- Top-corner controls
- Two-handed interactions
- Small buttons
- Precision gestures

Hand-in-glove fit:

- Large invisible right-thumb zone
- One-handed interaction
- No required top controls
- No required bottom tabs
- Haptics confirm actions

---

### 8. Problem: “I want to casually read different kinds of text.”

Bad fit:

- One-word mode for everything
- Robotic pacing
- No punctuation rhythm

Hand-in-glove fit:

Use smart chunking and pacing.

Examples:

```text
Casual article: phrase chunks
Dense text: shorter chunks
Bullets/lists: slower pacing
Comma: small pause
Period: larger pause
Paragraph break: breath
```

The app should read with rhythm.

---

### 9. Problem: “I want to stop and re-enter without getting lost.”

Bad fit:

- Pause freezes one isolated word

Hand-in-glove fit:

Pause reveals local context.

Reading state:

```text
acquisition
```

Paused state:

```text
... during the NielsenIQ acquisition, the data pipeline ...
```

This helps the user re-anchor immediately.

---

### 10. Problem: “I don’t want to fiddle with imports.”

Bad fit:

- Library-first
- File-picker-first
- Account-first

Hand-in-glove fit:

Input priority:

```text
1. Clipboard
2. iOS Share Sheet
3. Recent reads
4. Manual paste
5. Files/PDF later
```

For v1, clipboard-first is enough.

---

## Core UX Principles

### 1. Reading Surface Is Sacred

The reading screen should contain almost nothing.

Allowed during active reading:

- Current word or phrase
- Tiny progress line
- Temporary speed overlay
- Temporary haptic-confirmed state changes

Avoid during active reading:

- Buttons
- Toolbars
- Sliders
- Menus
- Permanent WPM display
- Tabs
- Notifications

---

### 2. Physical Metaphors Beat Abstract Controls

Every gesture should map to a body-level metaphor.

```text
Hold = engage engine
Release = brake
Slide up/down = throttle
Flick left = rewind/replay
Flick right = skip
Double tap = autopilot
Long press = menu
```

The user should not need to remember commands. The controls should feel obvious after one use.

---

### 3. Recovery Is More Important Than Speed

RSVP fails when the user loses comprehension and cannot recover instantly.

The app must make recovery effortless.

Primary recovery:

```text
Flick left → replay current sentence
```

Secondary recovery:

```text
Long flick left → replay previous sentence
```

Tertiary recovery:

```text
Pause → show local context
```

---

### 4. Casual Defaults Matter

Default settings should favor comfort over maximum speed.

Recommended defaults:

```text
Mode: phrase chunks
Speed: 300 WPM
Theme: system-aware dark/cream
Control: right-hand thumb surface
Replay: current sentence
Progress: subtle bottom line
Haptics: enabled
```

---

### 5. The Simulator Lies

Gesture feel must be tested on a real iPhone.

Test positions:

- Standing one-handed
- Sitting on couch
- In bed
- Walking slowly
- Tired eyes
- Thumb low on screen
- Thumb high on screen
- Dense text
- Casual article

---

## Interaction Model

### Screen Zones

```text
Full screen:
  Reading canvas

Center:
  Current word or phrase

Bottom:
  Subtle progress bar

Right 35–40%:
  Invisible thumb control surface
```

The right thumb zone should extend low enough to be comfortable for one-handed use and tall enough to support vertical speed movement.

---

## Control Mapping

### Precision Mode

Default for newly loaded text.

```text
Hold right thumb: play
Release: pause
Slide up while holding: faster speed band
Slide down while holding: slower speed band
Flick left: replay current sentence
Long flick left: replay previous sentence
Flick right: skip current sentence
Double tap: enter cruise autoplay
Long press: open command/settings sheet
```

### Cruise Mode

For relaxed reading without holding.

```text
Double tap: start sticky autoplay
Tap: pause
Vertical drag: adjust speed band
Flick left: replay current sentence
Flick right: skip current sentence
Long press: command/settings sheet
```

### Pause State

When paused, show:

- Current word or phrase large
- Surrounding context faintly
- Optional subtle time/progress info

Example:

```text
... during the acquisition, the data pipeline changed ...
```

The paused screen should help the user re-enter without opening a menu.

---

## Haptic Feedback

Use haptics as invisible UI confirmation.

Recommended haptic map:

```text
Start reading: light tick
Pause: soft tick
Speed band change: tiny tick
Replay sentence: medium bump
Skip sentence: medium-light bump
Cruise mode enabled: two light ticks
End of text: heavier finish
Invalid gesture: no haptic or very soft error
```

Haptics should be subtle. The goal is confidence, not noise.

---

## Visual Design

### Reading State

Characteristics:

- No chrome
- Large centered word/phrase
- Calm background
- Stable baseline
- Minimal layout shift
- Optional subtle ORP anchor
- Tiny bottom progress line

### Pause State

Characteristics:

- Current word remains primary
- Local context appears faintly
- Controls remain hidden unless user lingers
- Context display fades in quickly

### Temporary Overlays

Examples:

```text
Cruise · 300 WPM
Fast · 400 WPM
Replay sentence
Paused
```

Overlays should fade quickly and never compete with reading.

---

## Typography

Recommended direction:

- Large type
- High legibility
- Stable positioning
- Slightly increased tracking
- Avoid cheap-looking red anchor letters
- Use accent color or weight for ORP anchor if implemented

Potential styles:

```text
Font size: 48–64 pt depending on phrase length
Weight: semibold
Design: rounded or default system
Line limit: 1–2 depending on phrase mode
Minimum scale factor: enabled
```

---

## Reading Units

The app should support multiple display modes.

### v1 Required

```text
Word mode
Simple phrase mode
```

### Later

```text
Natural phrase chunking
Sentence-aware pacing
Paragraph-aware pacing
Dense-text mode
```

Default should be phrase mode for casual use.

---

## Token Model

Each reading token should include enough metadata to support pacing, replay, and context.

```swift
struct ReadingToken: Identifiable {
    let id = UUID()
    let text: String
    let delayMultiplier: Double
    let sentenceIndex: Int
    let paragraphIndex: Int
    let tokenIndex: Int
}
```

Optional later fields:

```swift
let originalRange: Range<String.Index>
let isSentenceStart: Bool
let isSentenceEnd: Bool
let isParagraphBreak: Bool
let chunkType: ChunkType
```

---

## Pacing Rules

Base delay:

```text
secondsPerToken = 60 / WPM
```

Delay multipliers:

```text
Normal token: 1.0x
Comma/semicolon/colon: 1.3–1.5x
Period/question/exclamation: 1.8–2.2x
Paragraph break: 2.5–3.0x
Long word: 1.1–1.2x
Dense phrase: 1.2–1.4x
```

The goal is rhythm, not raw speed.

---

## Speed Bands

Recommended default bands:

```text
Slow: 225 WPM
Cruise: 300 WPM
Fast: 400 WPM
Sprint: 525 WPM
Blast: 650 WPM
```

Advanced setting later:

```text
Custom bands
Max WPM cap
Default mode per text type
```

---

## MVP Scope

### Must Have

```text
Clipboard auto-load
Manual paste fallback
Word/phrase display
Hold-to-read
Release-to-pause
Double-tap cruise mode
Vertical speed bands
Flick left replay current sentence
Flick right skip current sentence
Pause context
Subtle progress bar
Haptics
Dark mode support
```

### Should Have

```text
Recent clipboard sessions
Basic settings sheet
Left-handed mode
WPM default setting
Phrase vs word mode toggle
```

### Could Have Later

```text
Share Sheet extension
PDF text extraction
Safari article extraction
AI cleanup/summarization
Saved library
Cloud sync
Reading history
Custom themes
Advanced natural-language chunking
```

### Explicitly Out of Scope for v1

```text
Accounts
Subscriptions
Social features
Heavy analytics
Full document library
Complex onboarding
AI features
PDF-first workflow
OCR
```

---

## First-Run Experience

Keep onboarding tiny.

Suggested first-run overlay:

```text
Hold to read
Slide up/down for speed
Flick left to replay
Double tap for cruise
```

After the user completes a few gestures, hide the overlay permanently unless reopened from settings.

---

## Empty Clipboard State

If no clipboard text exists:

Display a calm paste screen.

Primary action:

```text
Paste Text
```

Secondary actions:

```text
Open Recent
How it works
```

Do not force account creation or setup.

---

## Error and Edge States

### Clipboard Has No Text

Show paste screen.

### Clipboard Text Is Very Short

Load anyway.

### Clipboard Text Is Huge

Tokenize in background if needed. Show ready state quickly.

### User Reaches End

- Stop reading
- Haptic finish
- Show completion state
- Options: reread, new clipboard, recent

### User Copies New Text While App Is Open

Potential behavior:

```text
Small prompt: New clipboard text found. Load it?
```

Do not interrupt active reading.

---

## Implementation Notes

### Suggested Stack

```text
SwiftUI
Observable view model
Task-based playback loop or TimelineView
UIPasteboard for clipboard
UIImpactFeedbackGenerator for haptics
UserDefaults or SwiftData for recent sessions
NaturalLanguage later for better chunking
```

### Playback Loop

Use a task that advances token index according to current speed and token delay multiplier.

Speed changes should take effect immediately or on the next token.

### Gesture State Machine

Treat gestures as a state machine, not scattered callbacks.

Suggested states:

```text
idle
armed
readingHeld
paused
cruisePlaying
speedAdjusting
replaying
settingsOpen
completed
```

This prevents gesture ambiguity.

---

## Suggested View Model Responsibilities

```text
Load clipboard
Tokenize text
Track current token index
Track sentence/paragraph index
Manage play/pause/cruise state
Handle speed band changes
Replay current sentence
Skip current sentence
Expose pause context
Expose progress
Trigger haptic events
Persist recent sessions
```

---

## Suggested Data Types

```swift
enum ReadingMode {
    case precisionHeld
    case cruise
}

enum SpeedBand: Double, CaseIterable {
    case slow = 225
    case cruise = 300
    case fast = 400
    case sprint = 525
    case blast = 650
}

enum ReaderState {
    case idle
    case ready
    case readingHeld
    case paused
    case cruisePlaying
    case completed
}
```

---

## Quality Bar

This app succeeds if:

```text
A user can copy text, open the app, and start reading in under 2 seconds.
The user can pause without thinking.
The user can recover missed meaning instantly.
The user can adjust speed without looking.
The reading screen feels calm, not busy.
The controls feel physical and trustworthy.
```

This app fails if:

```text
The user has to manage buttons.
The user loses their place when pausing.
The user accidentally triggers gestures.
Speed control feels jittery.
The app feels like a productivity chore.
The interface makes RSVP feel stressful.
```

---

## v1 Build Order

### Pass 1: Reading Core

```text
Create SwiftUI project
Clipboard load
Tokenize text
Display current word/phrase
Manual paste fallback
```

### Pass 2: Playback

```text
Implement play/pause
Implement WPM timing
Implement punctuation delay multipliers
Implement end-of-text state
```

### Pass 3: Thumb Controls

```text
Invisible right thumb zone
Hold-to-read
Release-to-pause
Vertical speed bands
Haptics
```

### Pass 4: Recovery

```text
Sentence indexing
Flick left replay current sentence
Flick right skip sentence
Pause context display
```

### Pass 5: Polish

```text
Cruise mode
First-run overlay
Subtle progress bar
Settings sheet
Recent sessions
Left-handed mode
```

---

## Final Hand-in-Glove Flow

```text
I copy something.
I open the app.
It is already loaded.
I hold my thumb.
It starts reading.
I slide up if it feels too slow.
I slide down if it feels too fast.
I let go when I need a breath.
It shows me the surrounding context.
I flick left when I miss the thought.
It replays the sentence.
I double tap when I want it to cruise.
I leave when I’m done.
```

That is the product.

---

## Core Design Rule

Do not build a generic speed-reading app.

Build a calm, clipboard-first, one-thumb reading instrument.
